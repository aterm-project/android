//! PostgreSQL Vault deletion lifecycle and durable external object cleanup.
//!
//! The queue and deletion ledger intentionally outlive the rows removed by a
//! Vault cascade. Provider I/O is never performed while holding a database
//! transaction; queue claims use leases so multiple service nodes can drain
//! work safely.

use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, auth, auth::AuthUser, object_store::ObjectStore};

type HmacSha256 = Hmac<Sha256>;

const PURGE_BATCH_SIZE: i64 = 100;
const RETENTION_BATCH_SIZE: i64 = 1_000;
const DELETE_QUEUE_LEASE_SECONDS: i64 = 10 * 60;
const DELETE_QUEUE_MAX_RETRY_SECONDS: i64 = 86_400;

#[derive(Clone)]
pub(crate) struct PgVaultDeletionRepository {
    pool: PgPool,
}

impl PgVaultDeletionRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Returns the active account username used by the shared login limiter.
    pub(crate) async fn username_for_user(&self, user_id: &str) -> Result<String, ApiError> {
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1 AND status='active'")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)
    }

    /// Verifies a client-derived verifier against PostgreSQL credentials and
    /// returns the PHC snapshot for an in-transaction recheck by the caller.
    pub(crate) async fn verify_login_verifier(
        &self,
        user_id: &str,
        verifier: &str,
    ) -> Result<String, ApiError> {
        let encoded: Option<String> = sqlx::query_scalar(
            "SELECT c.login_verifier_hash FROM auth_credentials c \
             JOIN users u ON u.user_id=c.user_id \
             WHERE c.user_id=$1 AND u.status='active'",
        )
        .bind(user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let encoded = encoded.ok_or_else(ApiError::reauth_required)?;
        auth::check_password_hash(verifier, &encoded).map_err(map_step_up_error)?;
        Ok(encoded)
    }

    /// Begins or idempotently inspects the Owner-requested deletion grace.
    /// Locks follow session → account/credential → device → Vault → member →
    /// deletion request, matching the shared PG lifecycle ordering.
    pub(crate) async fn delete_vault(
        &self,
        user: &AuthUser,
        vault_id: &str,
        verified_hash: &str,
        grace_seconds: i64,
        audit_key: &[u8; 32],
    ) -> Result<Value, ApiError> {
        let actor_hash = deletion_actor_hash(audit_key, user)?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let (status, role) =
            validate_lifecycle_owner_tx(&mut tx, user, vault_id, verified_hash).await?;

        let (requested_at, purge_after) = if status == "active" {
            let db_now = database_epoch_tx(&mut tx).await?;
            let requested_at = db_now;
            let purge_after = db_now.saturating_add(grace_seconds);
            sqlx::query(
                "INSERT INTO vault_deletion_requests \
                 (vault_id,requested_at,purge_after,actor_hash) VALUES($1,$2,$3,$4)",
            )
            .bind(vault_id)
            .bind(requested_at)
            .bind(purge_after)
            .bind(actor_hash)
            .execute(&mut *tx)
            .await
            .map_err(|error| {
                if error
                    .as_database_error()
                    .is_some_and(|database_error| database_error.is_unique_violation())
                {
                    ApiError::conflict(
                        "VAULT_DELETION_PENDING",
                        "vault deletion is already pending",
                    )
                } else {
                    ApiError::internal(error)
                }
            })?;
            let changed = sqlx::query(
                "UPDATE vaults SET state='deleting' \
                 WHERE vault_id=$1 AND owner_user_id=$2 AND state='active'",
            )
            .bind(vault_id)
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if changed.rows_affected() != 1 {
                return Err(ApiError::conflict(
                    "VAULT_DELETION_TRANSITION_CONFLICT",
                    "vault lifecycle changed; retry the request",
                ));
            }
            record_vault_event(
                &mut tx,
                vault_id,
                Some(&user.user_id),
                Some(&user.device_id),
                "vault.deletion_requested",
                "vault",
                Some(vault_id),
                "api",
                requested_at,
            )
            .await?;
            (requested_at, purge_after)
        } else if status == "deleting" {
            let pending = self
                .lock_pending_request(&mut tx, vault_id)
                .await?
                .ok_or_else(|| {
                    ApiError::internal("deleting vault has no pending deletion request")
                })?;
            (pending.1, pending.2)
        } else {
            return Err(ApiError::not_found());
        };

        let db_now = database_epoch_tx(&mut tx).await?;

        tx.commit().await.map_err(ApiError::internal)?;
        Ok(vault_lifecycle_dto(
            vault_id,
            &role,
            "deleting",
            Some(requested_at),
            Some(purge_after),
            db_now,
        ))
    }

    /// Cancels a pending deletion only before its original purge deadline.
    /// Repeated cancellation while active is an idempotent no-op.
    pub(crate) async fn cancel_vault_deletion(
        &self,
        user: &AuthUser,
        vault_id: &str,
        verified_hash: &str,
    ) -> Result<Value, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let (status, role) =
            validate_lifecycle_owner_tx(&mut tx, user, vault_id, verified_hash).await?;
        if status == "active" {
            let db_now = database_epoch_tx(&mut tx).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(vault_lifecycle_dto(
                vault_id, &role, "active", None, None, db_now,
            ));
        }
        if status != "deleting" {
            return Err(ApiError::not_found());
        }

        let pending = self
            .lock_pending_request(&mut tx, vault_id)
            .await?
            .ok_or_else(|| ApiError::internal("deleting vault has no pending deletion request"))?;
        let (request_id, _, _) = pending;
        // The conditional write samples database time after both the Vault and
        // request rows are locked. That is the authoritative deadline check.
        let cancelled_at = sqlx::query_scalar::<_, i64>(
            "WITH db_clock AS MATERIALIZED (\
                 SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch\
             ) \
             UPDATE vault_deletion_requests r SET cancelled_at=db_clock.now_epoch \
             FROM db_clock \
             WHERE r.request_id=$1 AND r.cancelled_at IS NULL AND r.purged_at IS NULL \
               AND r.purge_after>db_clock.now_epoch \
             RETURNING r.cancelled_at",
        )
        .bind(request_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(cancelled_at) = cancelled_at else {
            return Err(vault_deletion_window_expired());
        };
        let restored =
            sqlx::query("UPDATE vaults SET state='active' WHERE vault_id=$1 AND state='deleting'")
                .bind(vault_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if restored.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "VAULT_DELETION_TRANSITION_CONFLICT",
                "vault lifecycle changed; retry the request",
            ));
        }
        record_vault_event(
            &mut tx,
            vault_id,
            Some(&user.user_id),
            Some(&user.device_id),
            "vault.deletion_cancelled",
            "vault",
            Some(vault_id),
            "api",
            cancelled_at,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(vault_lifecycle_dto(
            vault_id,
            &role,
            "active",
            None,
            None,
            cancelled_at,
        ))
    }

    async fn lock_pending_request(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        vault_id: &str,
    ) -> Result<Option<(i64, i64, i64)>, ApiError> {
        sqlx::query_as(
            "SELECT request_id,requested_at,purge_after FROM vault_deletion_requests \
             WHERE vault_id=$1 AND cancelled_at IS NULL AND purged_at IS NULL \
             ORDER BY request_id DESC LIMIT 1 FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)
    }

    /// Processes at most one bounded batch of due deletion requests. The
    /// request scan is only a candidate list; each candidate is rechecked
    /// after locking the Vault first, then its request row. This serializes
    /// with cancel and sync operations across all service nodes.
    pub(crate) async fn purge_due_vault_deletions(
        &self,
        _now_epoch: i64,
        retention_days: i64,
    ) -> Result<(), ApiError> {
        let due = sqlx::query(
            "WITH db_clock AS MATERIALIZED (\
                 SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch\
             ) \
             SELECT r.request_id,r.vault_id FROM vault_deletion_requests r \
             CROSS JOIN db_clock \
             WHERE r.cancelled_at IS NULL AND r.purged_at IS NULL \
               AND r.purge_after<=db_clock.now_epoch \
             ORDER BY r.purge_after,r.request_id LIMIT $1",
        )
        .bind(PURGE_BATCH_SIZE)
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;

        for candidate in due {
            let request_id: i64 = candidate
                .try_get("request_id")
                .map_err(ApiError::internal)?;
            let vault_id: String = candidate.try_get("vault_id").map_err(ApiError::internal)?;
            let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

            // Lock order is Vault → request for maintenance. API lifecycle
            // transactions use session → account → device → Vault → member →
            // request, so both paths serialize on the Vault before its ledger.
            let vault_state: Option<String> =
                sqlx::query_scalar("SELECT state FROM vaults WHERE vault_id=$1 FOR UPDATE")
                    .bind(&vault_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            let request = sqlx::query(
                "SELECT cancelled_at,purged_at FROM vault_deletion_requests \
                 WHERE request_id=$1 AND vault_id=$2 FOR UPDATE",
            )
            .bind(request_id)
            .bind(&vault_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let Some(request) = request else {
                tx.commit().await.map_err(ApiError::internal)?;
                continue;
            };
            let cancelled_at: Option<i64> = request
                .try_get("cancelled_at")
                .map_err(ApiError::internal)?;
            let purged_at: Option<i64> =
                request.try_get("purged_at").map_err(ApiError::internal)?;
            if cancelled_at.is_some() || purged_at.is_some() {
                tx.commit().await.map_err(ApiError::internal)?;
                continue;
            }
            match vault_state.as_deref() {
                Some("deleting") => {
                    let Some(purged_at) = mark_request_purged_if_due(&mut tx, request_id).await?
                    else {
                        tx.commit().await.map_err(ApiError::internal)?;
                        continue;
                    };
                    queue_external_objects_for_vault(&mut tx, &vault_id).await?;
                    let deleted =
                        sqlx::query("DELETE FROM vaults WHERE vault_id=$1 AND state='deleting'")
                            .bind(&vault_id)
                            .execute(&mut *tx)
                            .await
                            .map_err(ApiError::internal)?;
                    if deleted.rows_affected() != 1 {
                        return Err(ApiError::internal(
                            "due Vault deletion did not remove its deleting Vault",
                        ));
                    }
                    // Finish all domain writes before acquiring audit_events'
                    // RowExclusive lock. A first-page reader can be waiting
                    // for SHARE while other writers finish their domain work.
                    sqlx::query(
                        "UPDATE audit_events SET actor_user_id=NULL,actor_device_id=NULL \
                         WHERE scope_type='vault' AND scope_id=$1",
                    )
                    .bind(&vault_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                    record_vault_event(
                        &mut tx,
                        &vault_id,
                        None,
                        None,
                        "vault.purged",
                        "vault",
                        Some(&vault_id),
                        "maintenance",
                        purged_at,
                    )
                    .await?;
                }
                None => {
                    // Finish the retained request marker if an old operator
                    // or binary already removed the Vault. This mirrors the
                    // SQLite idempotent recovery path and emits no new event.
                    if mark_request_purged_if_due(&mut tx, request_id)
                        .await?
                        .is_none()
                    {
                        tx.commit().await.map_err(ApiError::internal)?;
                        continue;
                    }
                }
                Some("active") => {
                    return Err(ApiError::internal(
                        "pending deletion request references an active Vault",
                    ));
                }
                Some(_) => {
                    return Err(ApiError::internal(
                        "Vault has an unsupported lifecycle state",
                    ));
                }
            }
            tx.commit().await.map_err(ApiError::internal)?;
        }

        let retention_seconds = retention_days.saturating_mul(86_400);
        sqlx::query(
            "WITH db_clock AS MATERIALIZED (\
                 SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch\
             ), stale AS (\
                 SELECT r.request_id FROM vault_deletion_requests r \
                 CROSS JOIN db_clock \
                 WHERE (r.cancelled_at IS NOT NULL OR r.purged_at IS NOT NULL) \
                   AND COALESCE(r.purged_at,r.cancelled_at)<db_clock.now_epoch-$1 \
                 ORDER BY COALESCE(r.purged_at,r.cancelled_at),r.request_id \
                 LIMIT $2 FOR UPDATE OF r SKIP LOCKED\
             ) \
             DELETE FROM vault_deletion_requests r USING stale \
             WHERE r.request_id=stale.request_id",
        )
        .bind(retention_seconds)
        .bind(RETENTION_BATCH_SIZE)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        // The SQLite maintenance pass prunes the audit table in this same
        // retention cycle; preserve that behavior for the PG lifecycle worker.
        // This runs frequently on every node, so bound work per pass and let
        // the occurred_at index make the next pass resume efficiently.
        sqlx::query(
            "WITH db_clock AS MATERIALIZED (\
                 SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch\
             ), stale AS (\
                 SELECT a.event_id FROM audit_events a \
                 CROSS JOIN db_clock \
                 WHERE a.occurred_at<db_clock.now_epoch-$1 \
                 ORDER BY a.occurred_at,a.event_id \
                 LIMIT $2 FOR UPDATE OF a SKIP LOCKED\
             ) \
             DELETE FROM audit_events a USING stale \
             WHERE a.event_id=stale.event_id",
        )
        .bind(retention_seconds)
        .bind(RETENTION_BATCH_SIZE)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    /// Drains a bounded batch from the shared durable external-delete queue.
    /// Claims are short transactions; object storage calls run without a DB
    /// transaction and are finalized only by the matching lease owner.
    pub(crate) async fn drain_object_delete_queue(
        &self,
        object_store: &ObjectStore,
        _now_epoch: i64,
        limit: i64,
    ) -> Result<(), ApiError> {
        let batch_lease = Uuid::new_v4();
        let mut claim_tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let claimed = sqlx::query(
            r#"
            WITH db_clock AS MATERIALIZED (
                SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch
            ), due AS (
                SELECT q.queue_id,c.now_epoch
                FROM object_delete_queue q
                CROSS JOIN db_clock c
                WHERE q.state IN ('pending','retry_wait')
                  AND q.next_attempt_at<=c.now_epoch
                  AND (q.lease_until IS NULL OR q.lease_until<=c.now_epoch)
                  AND NOT EXISTS(
                      SELECT 1 FROM backup_object_pins p
                      WHERE p.storage_store_id=q.storage_store_id
                        AND p.storage_key=q.storage_key
                        AND p.expires_at>clock_timestamp()
                  )
                ORDER BY q.next_attempt_at,q.created_at,q.queue_id
                LIMIT $1 FOR UPDATE OF q SKIP LOCKED
            )
            UPDATE object_delete_queue q SET lease_id=$2,
                lease_until=due.now_epoch+$3
            FROM due
            WHERE q.queue_id=due.queue_id
            RETURNING q.queue_id,q.storage_backend,q.storage_key,q.storage_store_id,
                      q.expected_size,q.expected_sha256,q.attempt_count
            "#,
        )
        .bind(limit.clamp(1, 100))
        .bind(batch_lease)
        .bind(DELETE_QUEUE_LEASE_SECONDS)
        .fetch_all(&mut *claim_tx)
        .await
        .map_err(ApiError::internal)?;
        claim_tx.commit().await.map_err(ApiError::internal)?;

        for row in claimed {
            let queue_id: String = row.try_get("queue_id").map_err(ApiError::internal)?;
            let storage_backend: String =
                row.try_get("storage_backend").map_err(ApiError::internal)?;
            let storage_key: String = row.try_get("storage_key").map_err(ApiError::internal)?;
            let storage_store_id: String = row
                .try_get("storage_store_id")
                .map_err(ApiError::internal)?;
            let expected_size: i64 = row.try_get("expected_size").map_err(ApiError::internal)?;
            let expected_sha256: String =
                row.try_get("expected_sha256").map_err(ApiError::internal)?;
            let attempt_count: i64 = row.try_get("attempt_count").map_err(ApiError::internal)?;

            if self
                .object_key_is_still_catalogued(&storage_store_id, &storage_key)
                .await?
            {
                // A different Vault may still own this exact provider key.
                // Keep the intent retryable and never issue a destructive
                // provider call while any catalogue row names the key.
                self.release_queue_for_retry(
                    &queue_id,
                    batch_lease,
                    attempt_count,
                    "integrity_mismatch",
                )
                .await?;
                continue;
            }

            // The claim statement can race a pin commit because it locks the
            // queue row, not the catalogue row. Recheck against a fresh
            // statement snapshot before provider I/O and return a newly
            // protected intent to the queue without charging a retry.
            if self
                .object_key_has_active_backup_pin(&storage_store_id, &storage_key)
                .await?
            {
                self.release_queue_for_active_pin(&queue_id, batch_lease)
                    .await?;
                continue;
            }

            // A backend/store mismatch is a transient operator configuration
            // problem: retain the intent and retry after the correct backend
            // is configured. Never send a filesystem key to S3 (or vice versa).
            if object_store.backend_name() != storage_backend
                || object_store.store_id() != Some(storage_store_id.as_str())
            {
                self.release_queue_for_retry(
                    &queue_id,
                    batch_lease,
                    attempt_count,
                    "remote_unavailable",
                )
                .await?;
                continue;
            }

            match object_store
                .delete_object(&storage_key, expected_size, &expected_sha256)
                .await
            {
                Ok(()) => {
                    self.finish_successful_delete(
                        &queue_id,
                        batch_lease,
                        &storage_store_id,
                        &storage_key,
                    )
                    .await?;
                }
                Err(crate::object_store::ObjectStoreError::IntegrityMismatch) => {
                    self.quarantine_queue_item(&queue_id, batch_lease).await?;
                }
                Err(crate::object_store::ObjectStoreError::Unavailable)
                | Err(crate::object_store::ObjectStoreError::ImmutableConflict) => {
                    self.release_queue_for_retry(
                        &queue_id,
                        batch_lease,
                        attempt_count,
                        "remote_unavailable",
                    )
                    .await?;
                }
            }
        }
        Ok(())
    }

    async fn object_key_is_still_catalogued(
        &self,
        storage_store_id: &str,
        storage_key: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM blob_objects \
             WHERE storage_store_id=$1 AND storage_key=$2)",
        )
        .bind(storage_store_id)
        .bind(storage_key)
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    async fn object_key_has_active_backup_pin(
        &self,
        storage_store_id: &str,
        storage_key: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM backup_object_pins \
             WHERE storage_store_id=$1 AND storage_key=$2 \
               AND expires_at>clock_timestamp())",
        )
        .bind(storage_store_id)
        .bind(storage_key)
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    async fn release_queue_for_active_pin(
        &self,
        queue_id: &str,
        lease_id: Uuid,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE object_delete_queue \
             SET lease_id=NULL,lease_until=NULL \
             WHERE queue_id=$1 AND lease_id=$2",
        )
        .bind(queue_id)
        .bind(lease_id)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn release_queue_for_retry(
        &self,
        queue_id: &str,
        lease_id: Uuid,
        attempt_count: i64,
        category: &str,
    ) -> Result<(), ApiError> {
        let delay = 1_i64
            .checked_shl(attempt_count.clamp(0, 16) as u32)
            .unwrap_or(DELETE_QUEUE_MAX_RETRY_SECONDS)
            .min(DELETE_QUEUE_MAX_RETRY_SECONDS);
        sqlx::query(
            "UPDATE object_delete_queue SET state='retry_wait',attempt_count=attempt_count+1,\
                 next_attempt_at=floor(extract(epoch FROM clock_timestamp()))::BIGINT+$1,\
                 last_failure_category=$2,lease_id=NULL,lease_until=NULL \
             WHERE queue_id=$3 AND lease_id=$4",
        )
        .bind(delay)
        .bind(category)
        .bind(queue_id)
        .bind(lease_id)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn quarantine_queue_item(&self, queue_id: &str, lease_id: Uuid) -> Result<(), ApiError> {
        sqlx::query(
            "UPDATE object_delete_queue SET state='quarantined',attempt_count=attempt_count+1,\
                 next_attempt_at=floor(extract(epoch FROM clock_timestamp()))::BIGINT,\
                 last_failure_category='integrity_mismatch',lease_id=NULL,lease_until=NULL \
             WHERE queue_id=$1 AND lease_id=$2",
        )
        .bind(queue_id)
        .bind(lease_id)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn finish_successful_delete(
        &self,
        queue_id: &str,
        lease_id: Uuid,
        storage_store_id: &str,
        storage_key: &str,
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let claimed = sqlx::query_scalar::<_, String>(
            "SELECT queue_id FROM object_delete_queue \
             WHERE queue_id=$1 AND lease_id=$2 FOR UPDATE",
        )
        .bind(queue_id)
        .bind(lease_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if claimed.is_none() {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(());
        }
        let still_catalogued: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM blob_objects \
             WHERE storage_store_id=$1 AND storage_key=$2)",
        )
        .bind(storage_store_id)
        .bind(storage_key)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if still_catalogued {
            // A catalogue row appeared while provider I/O was in progress.
            // The provider deletion already succeeded, so preserve evidence
            // for operator repair rather than dropping the conflicting row.
            sqlx::query(
                "UPDATE object_delete_queue SET state='quarantined',attempt_count=attempt_count+1,\
                     next_attempt_at=floor(extract(epoch FROM clock_timestamp()))::BIGINT,\
                     last_failure_category='integrity_mismatch',lease_id=NULL,lease_until=NULL \
                 WHERE queue_id=$1 AND lease_id=$2",
            )
            .bind(queue_id)
            .bind(lease_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        } else {
            sqlx::query("DELETE FROM object_delete_queue WHERE queue_id=$1 AND lease_id=$2")
                .bind(queue_id)
                .bind(lease_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        tx.commit().await.map_err(ApiError::internal)
    }
}

async fn validate_lifecycle_owner_tx(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
    verified_hash: &str,
) -> Result<(String, String), ApiError> {
    let session = sqlx::query(
        "SELECT revoked_at,access_expires_at>clock_timestamp() AS unexpired \
         FROM sessions WHERE session_id=$1 AND user_id=$2 AND device_id=$3 \
           AND access_hash=$4 FOR SHARE",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    if session
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_some()
        || !session
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }

    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let current_hash: Option<String> = sqlx::query_scalar(
        "SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1 FOR SHARE",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if current_hash.as_deref() != Some(verified_hash) {
        return Err(ApiError::reauth_required());
    }

    let device_status: Option<String> = sqlx::query_scalar(
        "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "current device is not active",
        ));
    }

    let vault = sqlx::query("SELECT owner_user_id,state FROM vaults WHERE vault_id=$1 FOR UPDATE")
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let owner_user_id: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
    let vault_state: String = vault.try_get("state").map_err(ApiError::internal)?;

    let member = sqlx::query(
        "SELECT role,state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR UPDATE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let role: String = member.try_get("role").map_err(ApiError::internal)?;
    let member_state: String = member.try_get("state").map_err(ApiError::internal)?;
    if owner_user_id != user.user_id || role != "owner" || member_state != "active" {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "active Owner membership is required",
        ));
    }
    Ok((vault_state, role))
}

async fn database_epoch_tx(tx: &mut Transaction<'_, Postgres>) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)
}

/// Marks a locked pending request purged only if its deadline has passed on
/// the database clock. Returning the timestamp makes the audit event use the
/// exact same instant as the irreversible ledger transition.
async fn mark_request_purged_if_due(
    tx: &mut Transaction<'_, Postgres>,
    request_id: i64,
) -> Result<Option<i64>, ApiError> {
    sqlx::query_scalar::<_, i64>(
        "WITH db_clock AS MATERIALIZED (\
             SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now_epoch\
         ) \
         UPDATE vault_deletion_requests r SET purged_at=db_clock.now_epoch \
         FROM db_clock \
         WHERE r.request_id=$1 AND r.cancelled_at IS NULL AND r.purged_at IS NULL \
           AND r.purge_after<=db_clock.now_epoch \
         RETURNING r.purged_at",
    )
    .bind(request_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn queue_external_objects_for_vault(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<(), ApiError> {
    let objects = sqlx::query(
        "SELECT storage_backend,storage_key,storage_store_id,size,sha256 \
         FROM blob_objects WHERE vault_id=$1 AND storage_backend IN ('s3','filesystem') \
         ORDER BY storage_store_id,storage_key,object_id FOR UPDATE",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for object in objects {
        let storage_backend: String = object
            .try_get("storage_backend")
            .map_err(ApiError::internal)?;
        let storage_key: Option<String> =
            object.try_get("storage_key").map_err(ApiError::internal)?;
        let storage_store_id: Option<String> = object
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        let expected_size: i64 = object.try_get("size").map_err(ApiError::internal)?;
        let digest: String = object.try_get("sha256").map_err(ApiError::internal)?;
        let storage_key = storage_key
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("external object storage key is missing"))?;
        let storage_store_id = storage_store_id
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("external object storage identity is missing"))?;
        if !matches!(storage_backend.as_str(), "s3" | "filesystem")
            || expected_size <= 0
            || digest.len() != 64
            || !digest.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(ApiError::internal(
                "external object deletion metadata is invalid",
            ));
        }
        let digest = digest.to_ascii_lowercase();
        sqlx::query(
            "INSERT INTO object_delete_queue \
             (queue_id,storage_backend,storage_key,storage_store_id,expected_size,\
              expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at) \
             VALUES($1,$2,$3,$4,$5,$6,'pending',0, \
                    floor(extract(epoch FROM clock_timestamp()))::BIGINT,NULL,CURRENT_TIMESTAMP) \
             ON CONFLICT(storage_store_id,storage_key) DO NOTHING",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&storage_backend)
        .bind(&storage_key)
        .bind(&storage_store_id)
        .bind(expected_size)
        .bind(&digest)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let existing = sqlx::query(
            "SELECT storage_backend,expected_size,expected_sha256 FROM object_delete_queue \
             WHERE storage_store_id=$1 AND storage_key=$2",
        )
        .bind(&storage_store_id)
        .bind(&storage_key)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("external object deletion intent was not persisted"))?;
        let existing_backend: String = existing
            .try_get("storage_backend")
            .map_err(ApiError::internal)?;
        let existing_size: i64 = existing
            .try_get("expected_size")
            .map_err(ApiError::internal)?;
        let existing_digest: String = existing
            .try_get("expected_sha256")
            .map_err(ApiError::internal)?;
        if existing_backend != storage_backend
            || existing_size != expected_size
            || existing_digest != digest
        {
            return Err(ApiError::internal(
                "external object key has conflicting integrity metadata",
            ));
        }
    }
    Ok(())
}

async fn record_vault_event(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    actor_user_id: Option<&str>,
    actor_device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: &str,
    occurred_at: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,\
             resource_type,resource_id,result,occurred_at,source) \
         VALUES('vault',$1,$2,$3,$4,$5,$6,'success',$7,$8)",
    )
    .bind(vault_id)
    .bind(actor_user_id)
    .bind(actor_device_id)
    .bind(action)
    .bind(resource_type)
    .bind(resource_id)
    .bind(occurred_at)
    .bind(source)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn deletion_actor_hash(key: &[u8; 32], user: &AuthUser) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(b"atermius/vault-deletion-audit/v1\0");
    mac.update(user.user_id.as_bytes());
    mac.update(b"\0");
    mac.update(user.device_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn map_step_up_error(error: ApiError) -> ApiError {
    if error.status == StatusCode::UNAUTHORIZED {
        ApiError::reauth_required()
    } else {
        error
    }
}

fn vault_deletion_window_expired() -> ApiError {
    ApiError::gone(
        "VAULT_DELETION_WINDOW_EXPIRED",
        "vault deletion can no longer be cancelled",
    )
}

fn unix_epoch_rfc3339(value: Option<i64>) -> Option<String> {
    value.and_then(|seconds| {
        DateTime::<Utc>::from_timestamp(seconds, 0)
            .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    })
}

fn vault_lifecycle_dto(
    vault_id: &str,
    role: &str,
    status: &str,
    requested_at: Option<i64>,
    purge_after: Option<i64>,
    now_epoch: i64,
) -> Value {
    let deleting = status == "deleting";
    json!({
        "vault_id": vault_id,
        "role": role,
        "status": status,
        "requested_at": unix_epoch_rfc3339(requested_at),
        "purge_after": unix_epoch_rfc3339(purge_after),
        "can_cancel": deleting && role == "owner" && purge_after.is_some_and(|deadline| deadline > now_epoch),
        "can_write": !deleting && role != "viewer"
    })
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        time::Duration,
    };

    use futures_util::FutureExt;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};

    use super::*;

    const TEST_SCHEMA: &str = r#"
        CREATE TABLE vaults (
            vault_id TEXT PRIMARY KEY,
            state TEXT NOT NULL,
            owner_user_id TEXT
        );
        CREATE TABLE vault_deletion_requests (
            request_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            vault_id TEXT NOT NULL,
            requested_at BIGINT NOT NULL,
            purge_after BIGINT NOT NULL,
            actor_hash TEXT,
            cancelled_at BIGINT,
            purged_at BIGINT,
            CHECK (purge_after > requested_at),
            CHECK (cancelled_at IS NULL OR purged_at IS NULL)
        );
        CREATE TABLE blob_objects (
            object_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
            storage_backend TEXT NOT NULL,
            storage_key TEXT,
            storage_store_id TEXT,
            size BIGINT NOT NULL,
            sha256 TEXT NOT NULL
        );
        CREATE TABLE object_delete_queue (
            queue_id TEXT PRIMARY KEY,
            storage_backend TEXT NOT NULL,
            storage_key TEXT NOT NULL,
            storage_store_id TEXT NOT NULL,
            expected_size BIGINT NOT NULL,
            expected_sha256 TEXT NOT NULL,
            state TEXT NOT NULL,
            attempt_count BIGINT NOT NULL,
            next_attempt_at BIGINT NOT NULL,
            last_failure_category TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE (storage_store_id, storage_key)
        );
        CREATE TABLE audit_events (
            event_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
            scope_type TEXT NOT NULL,
            scope_id TEXT NOT NULL,
            actor_user_id TEXT,
            actor_device_id TEXT,
            action TEXT NOT NULL,
            resource_type TEXT NOT NULL,
            resource_id TEXT,
            result TEXT NOT NULL,
            occurred_at BIGINT NOT NULL,
            source TEXT NOT NULL
        );
    "#;

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    struct SchemaCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl SchemaCleanupGuard {
        fn new(admin_pool: PgPool, schema: String) -> Self {
            Self {
                admin_pool,
                schema,
                armed: true,
            }
        }

        async fn cleanup(&mut self) {
            if self.armed {
                drop_schema(&self.admin_pool, &self.schema).await;
                self.armed = false;
            }
        }

        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for SchemaCleanupGuard {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move { drop_schema(&admin_pool, &schema).await });
            }
        }
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL Vault deletion tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL tests outside an explicitly disposable database"
            );
            let admin_pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect to disposable PostgreSQL test database");
            let schema = format!("atermius_pg_vault_deletion_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            let mut cleanup_guard = SchemaCleanupGuard::new(admin_pool.clone(), schema.clone());
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect to isolated PostgreSQL schema");
                sqlx::raw_sql(TEST_SCHEMA)
                    .execute(&pool)
                    .await
                    .expect("create isolated Vault deletion test tables");
                pool
            })
            .catch_unwind()
            .await;
            match setup {
                Ok(pool) => {
                    cleanup_guard.disarm();
                    Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    }
                }
                Err(payload) => {
                    cleanup_guard.cleanup().await;
                    resume_unwind(payload)
                }
            }
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            drop_schema(&self.admin_pool, &self.schema).await;
            self.cleaned = true;
            self.admin_pool.close().await;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move { drop_schema(&admin_pool, &schema).await });
            }
        }
    }

    async fn drop_schema(admin_pool: &PgPool, schema: &str) {
        sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
            .execute(admin_pool)
            .await
            .expect("drop isolated Vault deletion test schema");
    }

    async fn database_epoch(pool: &PgPool) -> i64 {
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(pool)
            .await
            .unwrap()
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn purge_and_retention_use_database_time_and_keep_external_delete_intent_durable() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let before = database_epoch(pool).await;
        sqlx::query("INSERT INTO vaults(vault_id,state,owner_user_id) VALUES('due-vault','deleting','owner')")
            .execute(pool)
            .await
            .unwrap();
        let request_id: i64 = sqlx::query_scalar(
            "INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) \
             VALUES('due-vault',$1,$2,$3) RETURNING request_id",
        )
        .bind(before - 120)
        .bind(before - 60)
        .bind("a".repeat(64))
        .fetch_one(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,storage_backend,storage_key,storage_store_id,size,sha256) \
             VALUES('due-vault','filesystem','immutable/key','shared-store',5,$1)",
        )
        .bind("b".repeat(64))
        .execute(pool)
        .await
        .unwrap();

        let stale_request_id: i64 = sqlx::query_scalar(
            "INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,purged_at) \
             VALUES('old-terminal',$1,$2,$3) RETURNING request_id",
        )
        .bind(before - 8 * 86_400)
        .bind(before - 7 * 86_400)
        .bind(before - 7 * 86_400)
        .fetch_one(pool)
        .await
        .unwrap();
        let retained_request_id: i64 = sqlx::query_scalar(
            "INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,purged_at) \
             VALUES('recent-terminal',$1,$2,$3) RETURNING request_id",
        )
        .bind(before - 7_200)
        .bind(before - 3_600)
        .bind(before - 3_600)
        .fetch_one(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) \
             VALUES('user','old','old.event','test','success',$1,'api'), \
                    ('user','recent','recent.event','test','success',$2,'api')",
        )
        .bind(before - 7 * 86_400)
        .bind(before - 3_600)
        .execute(pool)
        .await
        .unwrap();

        let repository = PgVaultDeletionRepository::new(pool.clone());
        // A deliberately skewed node clock must not control either eligibility
        // or the timestamps/cutoffs used by this maintenance pass.
        repository
            .purge_due_vault_deletions(i64::MIN, 1)
            .await
            .unwrap();
        let after = database_epoch(pool).await;
        let (purged_at, audit_at): (i64, i64) = sqlx::query_as(
            "SELECT r.purged_at,a.occurred_at FROM vault_deletion_requests r \
             JOIN audit_events a ON a.action='vault.purged' AND a.scope_id='due-vault' \
             WHERE r.request_id=$1",
        )
        .bind(request_id)
        .fetch_one(pool)
        .await
        .unwrap();
        assert!((before..=after).contains(&purged_at));
        assert_eq!(purged_at, audit_at, "purge and audit share DB timestamp");

        let external_delete_intents: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id='shared-store' AND storage_key='immutable/key'",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(
            external_delete_intents, 1,
            "object deletion remains durable"
        );
        let vault_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM vaults WHERE vault_id='due-vault'")
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(vault_count, 0, "due Vault is irreversibly removed");

        let stale_request_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM vault_deletion_requests WHERE request_id=$1")
                .bind(stale_request_id)
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(
            stale_request_count, 0,
            "DB-time retention prunes old requests"
        );
        let retained_request_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM vault_deletion_requests WHERE request_id=$1")
                .bind(retained_request_id)
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(
            retained_request_count, 1,
            "DB-time retention keeps recent requests"
        );
        let retained_audit_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE scope_id='recent'")
                .fetch_one(pool)
                .await
                .unwrap();
        let stale_audit_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM audit_events WHERE scope_id='old'")
                .fetch_one(pool)
                .await
                .unwrap();
        assert_eq!(
            retained_audit_count, 1,
            "DB-time retention keeps recent audit"
        );
        assert_eq!(stale_audit_count, 0, "DB-time retention prunes old audit");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn purge_rechecks_deadline_after_waiting_for_vault_lock() {
        let database = TestDatabase::create().await;
        let pool = &database.pool;
        let before = database_epoch(pool).await;
        sqlx::query("INSERT INTO vaults(vault_id,state) VALUES('racing-vault','deleting')")
            .execute(pool)
            .await
            .unwrap();
        let request_id: i64 = sqlx::query_scalar(
            "INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) \
             VALUES('racing-vault',$1,$2,$3) RETURNING request_id",
        )
        .bind(before - 120)
        .bind(before - 60)
        .bind("c".repeat(64))
        .fetch_one(pool)
        .await
        .unwrap();

        // Hold the Vault first, exactly as the lifecycle lock order requires.
        // The purge worker can collect a due candidate but must wait before it
        // locks that request row.
        let mut blocker = pool.begin().await.unwrap();
        sqlx::query("SELECT vault_id FROM vaults WHERE vault_id='racing-vault' FOR UPDATE")
            .fetch_one(&mut *blocker)
            .await
            .unwrap();
        let repository = PgVaultDeletionRepository::new(pool.clone());
        let worker =
            tokio::spawn(async move { repository.purge_due_vault_deletions(i64::MAX, 30).await });
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            let waiting: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM pg_stat_activity \
                 WHERE wait_event_type='Lock' \
                   AND query LIKE '%SELECT state FROM vaults WHERE vault_id=$1 FOR UPDATE%')",
            )
            .fetch_one(pool)
            .await
            .unwrap();
            if waiting {
                break;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "purge worker did not reach the locked Vault"
            );
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        let advanced_deadline = database_epoch(pool).await + 300;
        sqlx::query("UPDATE vault_deletion_requests SET purge_after=$1 WHERE request_id=$2")
            .bind(advanced_deadline)
            .bind(request_id)
            .execute(&mut *blocker)
            .await
            .unwrap();
        blocker.commit().await.unwrap();
        worker.await.unwrap().unwrap();

        let (state, purge_after, purged_at): (String, i64, Option<i64>) = sqlx::query_as(
            "SELECT v.state,r.purge_after,r.purged_at FROM vaults v \
             JOIN vault_deletion_requests r ON r.vault_id=v.vault_id \
             WHERE v.vault_id='racing-vault'",
        )
        .fetch_one(pool)
        .await
        .unwrap();
        assert_eq!(state, "deleting");
        assert_eq!(purge_after, advanced_deadline);
        assert_eq!(purged_at, None, "in-lock DB-time recheck preserves Vault");
        database.cleanup().await;
    }
}

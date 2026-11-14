//! PostgreSQL account deletion lifecycle.
//!
//! Account/device/Vault state is fenced in the common order
//! session → account → credential → device → Vault → membership → request.
//! Purge and cancellation are transactional; external object bytes are never
//! touched here, only handed to the durable `object_delete_queue`.

use axum::http::StatusCode;
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, auth, auth::AuthUser, pg_notifications::notify_sync_wake};

type HmacSha256 = Hmac<Sha256>;

const PURGE_BATCH_SIZE: i64 = 50;
const RETENTION_BATCH_SIZE: i64 = 1_000;

#[derive(Clone)]
pub(crate) struct PgAccountDeletionRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
    actor_hash_key: [u8; 32],
    dummy_login_verifier_hash: String,
}

impl PgAccountDeletionRepository {
    pub(crate) fn new(
        pool: PgPool,
        audit_scope_key: [u8; 32],
        actor_hash_key: [u8; 32],
        dummy_login_verifier_hash: String,
    ) -> Self {
        Self {
            pool,
            audit_scope_key,
            actor_hash_key,
            dummy_login_verifier_hash,
        }
    }

    /// Returns the active account username for the shared Login rate limiter.
    pub(crate) async fn username_for_user(&self, user_id: &str) -> Result<String, ApiError> {
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1 AND status='active'")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)
    }

    /// Verifies a client-derived login verifier and returns the PHC snapshot
    /// that `delete_account` rechecks after acquiring lifecycle locks.
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
        auth::check_password_hash(verifier, &encoded).map_err(map_reauth_error)?;
        Ok(encoded)
    }

    /// Schedules the grace period and atomically fences the current account,
    /// all existing sessions, and all currently active devices.
    pub(crate) async fn delete_account(
        &self,
        user: &AuthUser,
        verified_hash: &str,
        grace_seconds: i64,
    ) -> Result<Value, ApiError> {
        if grace_seconds <= 0 {
            return Err(ApiError::internal(
                "account deletion grace period must be positive",
            ));
        }
        let request_id = Uuid::new_v4().to_string();
        let actor_hash = deletion_actor_hash(&self.actor_hash_key, user)?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let sessions = lock_user_sessions_tx(&mut tx, &user.user_id).await?;
        validate_actor_session(&sessions, user)?;

        let status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let Some(status) = status else {
            return Err(ApiError::unauthorized());
        };

        let current_hash: Option<String> = sqlx::query_scalar(
            "SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1 FOR SHARE",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if current_hash.as_deref() != Some(verified_hash) {
            return Err(ApiError::reauth_required());
        }

        let devices = lock_user_devices_tx(&mut tx, &user.user_id).await?;
        let mut actor_device = None;
        for device in &devices {
            let device_id: String = device.try_get("device_id").map_err(ApiError::internal)?;
            if device_id == user.device_id {
                actor_device = Some(device);
                break;
            }
        }
        let actor_device = actor_device
            .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "current device is not active"))?;
        if actor_device
            .try_get::<String, _>("status")
            .map_err(ApiError::internal)?
            != "active"
        {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "current device is not active",
            ));
        }

        if status == "deleting" {
            let pending = sqlx::query(
                "SELECT request_id,requested_at,purge_after FROM account_deletion_requests \
                 WHERE user_id=$1 AND cancelled_at IS NULL AND purged_at IS NULL \
                 ORDER BY requested_at DESC,request_id DESC LIMIT 1 FOR UPDATE",
            )
            .bind(&user.user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("deleting account has no pending request"))?;
            let pending_id: String = pending.try_get("request_id").map_err(ApiError::internal)?;
            let device_request: Option<String> = actor_device
                .try_get("account_deletion_request_id")
                .map_err(ApiError::internal)?;
            if device_request.as_deref() != Some(pending_id.as_str()) {
                return Err(ApiError::unauthorized());
            }
            let requested_at: i64 = pending
                .try_get("requested_at")
                .map_err(ApiError::internal)?;
            let deadline: i64 = pending.try_get("purge_after").map_err(ApiError::internal)?;
            let now = database_epoch_now_tx(&mut tx).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(account_deletion_dto(
                "deleting",
                Some(requested_at),
                Some(deadline),
                now,
            ));
        }
        if status != "active" {
            return Err(ApiError::unauthorized());
        }

        let (vaults, memberships) =
            lock_account_vaults_and_memberships_tx(&mut tx, &user.user_id).await?;
        reject_owned_shared_vault(&vaults, &memberships, &user.user_id)?;

        let now = database_epoch_now_tx(&mut tx).await?;
        let purge_after = now.saturating_add(grace_seconds);

        sqlx::query(
            "INSERT INTO account_deletion_requests \
             (request_id,user_id,requested_at,purge_after,actor_hash) VALUES($1,$2,$3,$4,$5)",
        )
        .bind(&request_id)
        .bind(&user.user_id)
        .bind(now)
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
                    "ACCOUNT_DELETION_PENDING",
                    "account deletion is already pending",
                )
            } else {
                ApiError::internal(error)
            }
        })?;

        sqlx::query(
            "UPDATE devices SET status='revoked',revoked_at=$1,account_deletion_request_id=$2 \
             WHERE user_id=$3 AND status='active'",
        )
        .bind(DateTime::<Utc>::from_timestamp(now, 0).ok_or_else(|| {
            ApiError::internal("account deletion timestamp is outside the supported range")
        })?)
        .bind(&request_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE sessions SET revoked_at=$1 WHERE user_id=$2 AND revoked_at IS NULL")
            .bind(DateTime::<Utc>::from_timestamp(now, 0).ok_or_else(|| {
                ApiError::internal("account deletion timestamp is outside the supported range")
            })?)
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let updated =
            sqlx::query("UPDATE users SET status='deleting' WHERE user_id=$1 AND status='active'")
                .bind(&user.user_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "ACCOUNT_DELETION_TRANSITION_CONFLICT",
                "account lifecycle changed; retry the request",
            ));
        }
        record_account_event(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            "account.deletion_requested",
            "api",
            now,
        )
        .await?;
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;

        Ok(account_deletion_dto(
            "deleting",
            Some(now),
            Some(purge_after),
            now,
        ))
    }

    /// Cancels a request without creating a new session. This endpoint is
    /// intentionally usable after scheduling revoked every existing session.
    pub(crate) async fn cancel_account_deletion(
        &self,
        username: &str,
        login_verifier: &str,
    ) -> Result<Value, ApiError> {
        let username = auth::normalized_username(username)?;
        let identity = sqlx::query(
            "SELECT u.user_id,u.status,c.login_verifier_hash \
             FROM users u JOIN auth_credentials c USING(user_id) \
             WHERE u.username=$1 AND u.status IN ('active','deleting')",
        )
        .bind(&username)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let Some(identity) = identity else {
            let _ = auth::check_password_hash(login_verifier, &self.dummy_login_verifier_hash);
            return Err(ApiError::reauth_required());
        };
        let verifier_snapshot: String = identity
            .try_get("login_verifier_hash")
            .map_err(ApiError::internal)?;
        auth::check_password_hash(login_verifier, &verifier_snapshot).map_err(map_reauth_error)?;
        let user_id: String = identity.try_get("user_id").map_err(ApiError::internal)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let Some(status) = status else {
            return Err(ApiError::reauth_required());
        };
        let current_hash: Option<String> = sqlx::query_scalar(
            "SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1 FOR SHARE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if current_hash.as_deref() != Some(verifier_snapshot.as_str()) {
            return Err(ApiError::reauth_required());
        }
        if status == "active" {
            let now = database_epoch_now_tx(&mut tx).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(account_deletion_dto("active", None, None, now));
        }
        if status != "deleting" {
            return Err(ApiError::reauth_required());
        }

        // No session is restored. Device rows are locked before the retained
        // request, matching the lifecycle write order used by scheduling.
        let _devices = lock_user_devices_tx(&mut tx, &user_id).await?;
        let pending = sqlx::query(
            "SELECT request_id,purge_after FROM account_deletion_requests \
             WHERE user_id=$1 AND cancelled_at IS NULL AND purged_at IS NULL \
             ORDER BY requested_at DESC,request_id DESC LIMIT 1 FOR UPDATE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("deleting account has no pending request"))?;
        let request_id: String = pending.try_get("request_id").map_err(ApiError::internal)?;
        let purge_after: i64 = pending.try_get("purge_after").map_err(ApiError::internal)?;
        // The request row is locked before this timestamp is read, so a
        // cancellation racing the purge worker is decided against PostgreSQL
        // time while holding the same row lock the worker must acquire.
        let now = database_epoch_now_tx(&mut tx).await?;
        if now >= purge_after {
            return Err(account_deletion_window_expired());
        }
        let cancelled = sqlx::query(
            "UPDATE account_deletion_requests SET cancelled_at=$1,user_id=NULL \
             WHERE request_id=$2 AND user_id=$3 AND cancelled_at IS NULL \
               AND purged_at IS NULL AND purge_after>$1",
        )
        .bind(now)
        .bind(&request_id)
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if cancelled.rows_affected() != 1 {
            return Err(account_deletion_window_expired());
        }
        let restored =
            sqlx::query("UPDATE users SET status='active' WHERE user_id=$1 AND status='deleting'")
                .bind(&user_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if restored.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "ACCOUNT_DELETION_TRANSITION_CONFLICT",
                "account lifecycle changed; retry the request",
            ));
        }
        sqlx::query(
            "UPDATE devices SET status='active',revoked_at=NULL,account_deletion_request_id=NULL \
             WHERE user_id=$1 AND account_deletion_request_id=$2 AND status='revoked'",
        )
        .bind(&user_id)
        .bind(&request_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        record_account_event(
            &mut tx,
            &self.audit_scope_key,
            &user_id,
            None,
            "account.deletion_cancelled",
            "api",
            now,
        )
        .await?;
        // Cancellation restores account/device status but deliberately does
        // not restore sessions. Wake peers so sockets left over from a missed
        // deletion wake still recheck the revoked session and fail closed.
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(account_deletion_dto("active", None, None, now))
    }

    /// Purges at most one bounded batch of accounts, then prunes bounded
    /// retention batches. Provider object deletion is deferred to the shared
    /// durable object queue.
    pub(crate) async fn purge_due_account_deletions(
        &self,
        _now_epoch: i64,
        retention_days: i64,
    ) -> Result<(), ApiError> {
        let due = sqlx::query(
            "SELECT request_id,user_id FROM account_deletion_requests \
             WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL \
               AND purge_after<=floor(extract(epoch FROM clock_timestamp()))::BIGINT \
             ORDER BY purge_after,request_id LIMIT $1",
        )
        .bind(PURGE_BATCH_SIZE)
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;

        for candidate in due {
            let request_id: String = candidate
                .try_get("request_id")
                .map_err(ApiError::internal)?;
            let user_id: String = candidate.try_get("user_id").map_err(ApiError::internal)?;
            self.purge_one_account(&request_id, &user_id).await?;
        }

        let database_now: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&self.pool)
                .await
                .map_err(ApiError::internal)?;
        let cutoff = database_now.saturating_sub(retention_days.saturating_mul(86_400));
        sqlx::query(
            "WITH stale AS (\
                 SELECT request_id FROM account_deletion_requests \
                 WHERE (cancelled_at IS NOT NULL OR purged_at IS NOT NULL) \
                   AND COALESCE(purged_at,cancelled_at)<$1 \
                 ORDER BY COALESCE(purged_at,cancelled_at),request_id \
                 LIMIT $2 FOR UPDATE SKIP LOCKED\
             ) DELETE FROM account_deletion_requests r USING stale \
               WHERE r.request_id=stale.request_id",
        )
        .bind(cutoff)
        .bind(RETENTION_BATCH_SIZE)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "WITH stale AS (\
                 SELECT event_id FROM audit_events WHERE occurred_at<$1 \
                 ORDER BY occurred_at,event_id LIMIT $2 FOR UPDATE SKIP LOCKED\
             ) DELETE FROM audit_events a USING stale WHERE a.event_id=stale.event_id",
        )
        .bind(cutoff)
        .bind(RETENTION_BATCH_SIZE)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn purge_one_account(&self, request_id: &str, user_id: &str) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        let sessions = lock_user_sessions_tx(&mut tx, user_id).await?;
        let status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let _: Option<String> = sqlx::query_scalar(
            "SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1 FOR UPDATE",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let devices = lock_user_devices_tx(&mut tx, user_id).await?;
        let device_ids: Vec<String> = devices
            .iter()
            .map(|row| row.try_get("device_id").map_err(ApiError::internal))
            .collect::<Result<_, _>>()?;
        let session_ids: Vec<String> = sessions
            .iter()
            .map(|row| row.try_get("session_id").map_err(ApiError::internal))
            .collect::<Result<_, _>>()?;
        let family_ids: Vec<String> = sessions
            .iter()
            .map(|row| row.try_get("family_id").map_err(ApiError::internal))
            .collect::<Result<_, _>>()?;
        let (vaults, memberships) =
            lock_account_vaults_and_memberships_tx(&mut tx, user_id).await?;

        // Candidate lists are intentionally unlocked. Two workers may pick the
        // same candidate, or cancellation may win while this worker waits for
        // the account row. Recheck the request only after the normal lifecycle
        // locks so a stale candidate exits cleanly without inverting lock order.
        let pending = sqlx::query(
            "SELECT purge_after FROM account_deletion_requests \
             WHERE request_id=$1 AND user_id=$2 AND cancelled_at IS NULL AND purged_at IS NULL \
             FOR UPDATE",
        )
        .bind(request_id)
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(pending) = pending else {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(());
        };
        // Read the comparison and all resulting purge/audit timestamps from
        // the database after the request row has been locked. Never trust a
        // scheduler node's clock for irreversible deletion.
        let now_epoch = database_epoch_now_tx(&mut tx).await?;
        if status.as_deref() != Some("deleting") {
            return Err(ApiError::internal(
                "pending account deletion references a missing or non-deleting account",
            ));
        }
        reject_owned_shared_vault(&vaults, &memberships, user_id).map_err(|_| {
            ApiError::internal("pending account deletion unexpectedly owns a shared Vault")
        })?;
        let purge_after: i64 = pending.try_get("purge_after").map_err(ApiError::internal)?;
        if purge_after > now_epoch {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(());
        }

        let mut owned_vault_ids: Vec<String> = Vec::new();
        for vault in &vaults {
            let owner: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
            if owner == user_id {
                owned_vault_ids.push(vault.try_get("vault_id").map_err(ApiError::internal)?);
            }
        }

        // Requests are unlinked before deleting owned Vault rows. The retained
        // deletion ledger remains valid after those rows cascade away.
        if !owned_vault_ids.is_empty() {
            sqlx::query(
                "UPDATE vault_deletion_requests SET purged_at=$1 \
                 WHERE vault_id=ANY($2) AND cancelled_at IS NULL AND purged_at IS NULL",
            )
            .bind(now_epoch)
            .bind(&owned_vault_ids)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        archive_shared_device_keys(&mut tx, user_id, now_epoch).await?;

        // `pg_vault_deletion` currently keeps this helper module-private. This
        // handoff uses the same queue identity, catalogue safety, and
        // integrity rules so the existing queue worker can consume it.
        for vault_id in &owned_vault_ids {
            queue_external_objects_for_vault_tx(&mut tx, vault_id, now_epoch).await?;
        }
        if !owned_vault_ids.is_empty() {
            sqlx::query("DELETE FROM vaults WHERE owner_user_id=$1")
                .bind(user_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }

        // Explicitly remove rows that have no account FK or whose scope is
        // requester/actor based. Device capability and MFA rows use schema
        // cascades when devices/users vanish; push endpoints are removed below.
        sqlx::query("DELETE FROM snapshots WHERE requested_by=$1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "DELETE FROM invitations WHERE created_by=$1 OR accepted_by=$1 OR recipient_user_id=$1",
        )
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_invitations WHERE consumed_user_id=$1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        // PG deliberately retains refresh_history and shared-Vault receipt
        // ledgers as replay/idempotency evidence; unlike SQLite, those rows
        // are not account-private and have no account/device FK.
        sqlx::query("DELETE FROM notification_push_endpoints WHERE user_id=$1")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        let finalized = sqlx::query(
            "UPDATE account_deletion_requests SET user_id=NULL,purged_at=$1 \
             WHERE request_id=$2 AND user_id=$3 AND cancelled_at IS NULL AND purged_at IS NULL",
        )
        .bind(now_epoch)
        .bind(request_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if finalized.rows_affected() != 1 {
            return Err(ApiError::internal(
                "account deletion audit transition was not applied",
            ));
        }
        let deleted = sqlx::query("DELETE FROM users WHERE user_id=$1 AND status='deleting'")
            .bind(user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if deleted.rows_affected() != 1 {
            return Err(ApiError::internal(
                "due account deletion did not remove its account",
            ));
        }
        // All account, Vault, request, and dependent-row writes are complete.
        // Only now acquire audit_events' RowExclusive lock: a pending first-
        // page SHARE lock must never meet a writer that still needs domain rows.
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, user_id)?;
        // Before account identity fields are scrubbed, migrate the exact legacy
        // logout shape written with a raw account scope. Do not broaden this
        // to any other raw-scope events.
        sqlx::query(
            "UPDATE audit_events SET scope_id=$1 \
             WHERE scope_type='account' AND scope_id=$2 \
               AND action='auth.logout_succeeded' AND actor_user_id=$2",
        )
        .bind(&scope_id)
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "UPDATE audit_events SET actor_user_id=NULL,actor_device_id=NULL \
             WHERE actor_user_id=$1 OR actor_device_id=ANY($2)",
        )
        .bind(user_id)
        .bind(&device_ids)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !device_ids.is_empty() {
            sqlx::query(
                "UPDATE audit_events SET resource_id=NULL \
                 WHERE resource_type='device' AND resource_id=ANY($1)",
            )
            .bind(&device_ids)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        if !session_ids.is_empty() {
            sqlx::query(
                "UPDATE audit_events SET resource_id=NULL \
                 WHERE resource_type='session' AND resource_id=ANY($1)",
            )
            .bind(&session_ids)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        if !family_ids.is_empty() {
            sqlx::query(
                "UPDATE audit_events SET resource_id=NULL \
                 WHERE resource_type='session_family' AND resource_id=ANY($1)",
            )
            .bind(&family_ids)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        sqlx::query(
            "UPDATE audit_events SET resource_id=NULL \
             WHERE resource_id=$1 AND resource_type IN ('account','account_recovery','membership')",
        )
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        // Keep the anonymous purge audit as the final audit write. Its scope
        // is HMAC-keyed; the raw user ID never reaches persisted audit scope.
        sqlx::query(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source) \
             VALUES('account',$1,NULL,NULL,'account.purged','account',NULL,'success',$2,'maintenance')",
        )
        .bind(scope_id)
        .bind(now_epoch)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)
    }
}

async fn lock_user_sessions_tx(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<Vec<sqlx::postgres::PgRow>, ApiError> {
    sqlx::query(
        "SELECT session_id,device_id,family_id,access_hash,revoked_at, \
                access_expires_at>CURRENT_TIMESTAMP AS unexpired \
         FROM sessions WHERE user_id=$1 ORDER BY session_id FOR UPDATE",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn database_epoch_now_tx(tx: &mut Transaction<'_, Postgres>) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)
}

fn validate_actor_session(
    sessions: &[sqlx::postgres::PgRow],
    user: &AuthUser,
) -> Result<(), ApiError> {
    let actor = sessions
        .iter()
        .find(|row| {
            row.try_get::<String, _>("session_id")
                .is_ok_and(|id| id == user.session_id)
        })
        .ok_or_else(ApiError::unauthorized)?;
    if actor
        .try_get::<String, _>("device_id")
        .map_err(ApiError::internal)?
        != user.device_id
        || actor
            .try_get::<String, _>("access_hash")
            .map_err(ApiError::internal)?
            != user.access_hash
        || actor
            .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
            .map_err(ApiError::internal)?
            .is_some()
        || !actor
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

async fn lock_user_devices_tx(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<Vec<sqlx::postgres::PgRow>, ApiError> {
    sqlx::query(
        "SELECT device_id,status,signing_public_key,encryption_public_key, \
                account_deletion_request_id \
         FROM devices WHERE user_id=$1 ORDER BY device_id FOR UPDATE",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn lock_account_vaults_and_memberships_tx(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<(Vec<sqlx::postgres::PgRow>, Vec<sqlx::postgres::PgRow>), ApiError> {
    let vaults = sqlx::query(
        "SELECT v.vault_id,v.owner_user_id,v.state \
         FROM vaults v \
         WHERE v.owner_user_id=$1 OR v.vault_id IN (\
             SELECT vm.vault_id FROM vault_members vm WHERE vm.user_id=$1) \
         ORDER BY v.vault_id FOR UPDATE OF v",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let vault_ids: Vec<String> = vaults
        .iter()
        .map(|row| row.try_get("vault_id").map_err(ApiError::internal))
        .collect::<Result<_, _>>()?;
    let memberships = if vault_ids.is_empty() {
        Vec::new()
    } else {
        sqlx::query(
            "SELECT vault_id,user_id,role,state FROM vault_members \
             WHERE vault_id=ANY($1) ORDER BY vault_id,user_id FOR UPDATE",
        )
        .bind(&vault_ids)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?
    };
    Ok((vaults, memberships))
}

fn reject_owned_shared_vault(
    vaults: &[sqlx::postgres::PgRow],
    memberships: &[sqlx::postgres::PgRow],
    user_id: &str,
) -> Result<(), ApiError> {
    for vault in vaults {
        let owner: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
        if owner != user_id {
            continue;
        }
        let vault_id: String = vault.try_get("vault_id").map_err(ApiError::internal)?;
        let mut has_other_member = false;
        for member in memberships {
            let member_vault: String = member.try_get("vault_id").map_err(ApiError::internal)?;
            let member_user: String = member.try_get("user_id").map_err(ApiError::internal)?;
            let state: String = member.try_get("state").map_err(ApiError::internal)?;
            if member_vault == vault_id
                && member_user != user_id
                && matches!(state.as_str(), "active" | "invited")
            {
                has_other_member = true;
                break;
            }
        }
        if has_other_member {
            return Err(ApiError::conflict(
                "ACCOUNT_OWNS_SHARED_VAULT",
                "remove other members from owned shared vaults before deleting this account",
            ));
        }
    }
    Ok(())
}

async fn archive_shared_device_keys(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    now_epoch: i64,
) -> Result<(), ApiError> {
    let archived_at = DateTime::<Utc>::from_timestamp(now_epoch, 0)
        .ok_or_else(|| ApiError::internal("archive timestamp is outside the supported range"))?;
    sqlx::query(
        "INSERT INTO vault_device_archives(\
             vault_id,user_id,device_id,signing_public_key,encryption_public_key,archived_at\
         ) \
         SELECT DISTINCT vm.vault_id,d.user_id,d.device_id,d.signing_public_key,\
                d.encryption_public_key,$1 \
         FROM vault_members vm \
         JOIN vaults v ON v.vault_id=vm.vault_id \
         JOIN devices d ON d.user_id=vm.user_id \
         WHERE vm.user_id=$2 AND v.owner_user_id<>$2 AND (\
             EXISTS(SELECT 1 FROM record_versions rv \
                    WHERE rv.vault_id=vm.vault_id AND rv.device_id=d.device_id) OR \
             EXISTS(SELECT 1 FROM conflicts c \
                    WHERE c.vault_id=vm.vault_id AND c.device_id=d.device_id) OR \
             EXISTS(SELECT 1 FROM membership_manifests mm \
                    WHERE mm.vault_id=vm.vault_id AND mm.signer_device_id=d.device_id) OR \
             EXISTS(SELECT 1 FROM vault_key_envelopes ke \
                    WHERE ke.vault_id=vm.vault_id \
                      AND (ke.signer_device_id=d.device_id OR ke.recipient_device_id=d.device_id))\
         ) ON CONFLICT(vault_id,device_id) DO NOTHING",
    )
    .bind(archived_at)
    .bind(user_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

/// Hands off every external object in one owned Vault using the same durable
/// queue contract consumed by `PgVaultDeletionRepository`.
async fn queue_external_objects_for_vault_tx(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    _now_epoch: i64,
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
        let backend: String = object
            .try_get("storage_backend")
            .map_err(ApiError::internal)?;
        let key: Option<String> = object.try_get("storage_key").map_err(ApiError::internal)?;
        let store_id: Option<String> = object
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        let size: i64 = object.try_get("size").map_err(ApiError::internal)?;
        let digest: String = object.try_get("sha256").map_err(ApiError::internal)?;
        let key = key
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("external object storage key is missing"))?;
        let store_id = store_id
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("external object storage identity is missing"))?;
        if !matches!(backend.as_str(), "s3" | "filesystem")
            || size <= 0
            || digest.len() != 64
            || !digest.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(ApiError::internal(
                "external object deletion metadata is invalid",
            ));
        }
        let digest = digest.to_ascii_lowercase();
        sqlx::query(
            "INSERT INTO object_delete_queue(\
                 queue_id,storage_backend,storage_key,storage_store_id,expected_size,\
                 expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at\
             ) VALUES($1,$2,$3,$4,$5,$6,'pending',0, \
                      floor(extract(epoch FROM clock_timestamp()))::BIGINT,NULL,CURRENT_TIMESTAMP) \
             ON CONFLICT(storage_store_id,storage_key) DO NOTHING",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&backend)
        .bind(&key)
        .bind(&store_id)
        .bind(size)
        .bind(&digest)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let existing = sqlx::query(
            "SELECT storage_backend,expected_size,expected_sha256 \
             FROM object_delete_queue WHERE storage_store_id=$1 AND storage_key=$2",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("external object deletion intent was not persisted"))?;
        if existing
            .try_get::<String, _>("storage_backend")
            .map_err(ApiError::internal)?
            != backend
            || existing
                .try_get::<i64, _>("expected_size")
                .map_err(ApiError::internal)?
                != size
            || existing
                .try_get::<String, _>("expected_sha256")
                .map_err(ApiError::internal)?
                != digest
        {
            return Err(ApiError::internal(
                "external object key has conflicting integrity metadata",
            ));
        }
    }
    Ok(())
}

async fn record_account_event(
    tx: &mut Transaction<'_, Postgres>,
    audit_scope_key: &[u8; 32],
    user_id: &str,
    device_id: Option<&str>,
    action: &str,
    source: &str,
    now_epoch: i64,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::account_scope_id(audit_scope_key, user_id)?;
    sqlx::query(
        "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action, \
         resource_type,resource_id,result,occurred_at,source) \
         VALUES('account',$1,$2,$3,$4,'account',NULL,'success',$5,$6)",
    )
    .bind(scope_id)
    .bind(user_id)
    .bind(device_id)
    .bind(action)
    .bind(now_epoch)
    .bind(source)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn deletion_actor_hash(key: &[u8; 32], user: &AuthUser) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(b"atermius/account-deletion-audit/v1\0");
    mac.update(user.user_id.as_bytes());
    mac.update(b"\0");
    mac.update(user.device_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn account_deletion_dto(
    status: &str,
    requested_at: Option<i64>,
    purge_after: Option<i64>,
    now_epoch: i64,
) -> Value {
    let deleting = status == "deleting";
    json!({
        "status": status,
        "requested_at": epoch_rfc3339(requested_at),
        "purge_after": epoch_rfc3339(purge_after),
        "can_cancel": deleting && purge_after.is_some_and(|deadline| deadline > now_epoch),
    })
}

fn epoch_rfc3339(value: Option<i64>) -> Option<String> {
    value.and_then(|seconds| {
        DateTime::<Utc>::from_timestamp(seconds, 0)
            .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    })
}

fn map_reauth_error(error: ApiError) -> ApiError {
    if error.status == StatusCode::UNAUTHORIZED {
        ApiError::reauth_required()
    } else {
        error
    }
}

fn account_deletion_window_expired() -> ApiError {
    ApiError::gone(
        "ACCOUNT_DELETION_WINDOW_EXPIRED",
        "account deletion can no longer be cancelled",
    )
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use sqlx::{postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::PgAccountDeletionRepository;

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn purge_eligibility_and_retention_use_database_time() {
        let url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ignored PostgreSQL account-deletion test requires ATERMIUS_TEST_PG_URL");
        let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "refusing PostgreSQL tests outside an explicitly disposable database"
        );

        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone())
            .await
            .expect("connect disposable PostgreSQL test database");
        let schema = format!("atermius_pg_account_deletion_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .expect("create isolated account-deletion test schema");
        let pool_options = options.options([("search_path", format!("\"{schema}\""))]);
        let pool = PgPoolOptions::new()
            .max_connections(4)
            .connect_with(pool_options)
            .await
            .expect("connect isolated account-deletion schema");
        sqlx::raw_sql(
            "CREATE TABLE account_deletion_requests(\
                 request_id TEXT PRIMARY KEY,user_id TEXT,cancelled_at BIGINT,purged_at BIGINT,\
                 purge_after BIGINT NOT NULL\
             );\
             CREATE TABLE audit_events(event_id BIGSERIAL PRIMARY KEY,occurred_at BIGINT NOT NULL);",
        )
        .execute(&pool)
        .await
        .expect("create minimal retention tables");

        let repository = PgAccountDeletionRepository::new(
            pool.clone(),
            [0x11; 32],
            [0x22; 32],
            "unused-test-verifier".to_owned(),
        );
        let database_now: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&pool)
                .await
                .expect("read PostgreSQL clock");

        // A wildly fast maintenance-node clock must not make this future
        // request eligible. If the candidate is selected, the deliberately
        // minimal schema causes purge_one_account to fail immediately.
        sqlx::query(
            "INSERT INTO account_deletion_requests(request_id,user_id,purge_after) \
             VALUES('future-request','user-1',$1)",
        )
        .bind(database_now.saturating_add(86_400))
        .execute(&pool)
        .await
        .expect("insert future deletion request");
        repository
            .purge_due_account_deletions(i64::MAX, 1)
            .await
            .expect("future request must not be purged using node time");

        // Conversely, retention should use PostgreSQL time even when the
        // maintenance node reports the minimum possible epoch. Old rows are
        // removed, while a recent row is retained in both ledgers.
        sqlx::query(
            "INSERT INTO account_deletion_requests \
             (request_id,user_id,cancelled_at,purge_after) VALUES \
             ('stale-request',NULL,$1,0),('recent-request',NULL,$2,0)",
        )
        .bind(database_now.saturating_sub(2 * 86_400))
        .bind(database_now.saturating_add(3_600))
        .execute(&pool)
        .await
        .expect("insert request retention fixtures");
        sqlx::query("INSERT INTO audit_events(occurred_at) VALUES($1),($2)")
            .bind(database_now.saturating_sub(2 * 86_400))
            .bind(database_now.saturating_add(3_600))
            .execute(&pool)
            .await
            .expect("insert audit retention fixtures");
        repository
            .purge_due_account_deletions(i64::MIN, 1)
            .await
            .expect("retention cleanup should complete");

        let request_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM account_deletion_requests WHERE request_id IN \
             ('future-request','stale-request','recent-request')",
        )
        .fetch_one(&pool)
        .await
        .expect("count retained deletion requests");
        assert_eq!(
            request_rows, 2,
            "old request should be pruned, recent and future kept"
        );
        let stale_request_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM account_deletion_requests WHERE request_id='stale-request'",
        )
        .fetch_one(&pool)
        .await
        .expect("check stale request retention");
        assert_eq!(stale_request_rows, 0);
        let event_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events")
            .fetch_one(&pool)
            .await
            .expect("count retained audit events");
        assert_eq!(event_rows, 1, "only the recent audit event should remain");

        pool.close().await;
        sqlx::query(&format!("DROP SCHEMA \"{schema}\" CASCADE"))
            .execute(&admin_pool)
            .await
            .expect("drop isolated account-deletion test schema");
        admin_pool.close().await;
    }
}

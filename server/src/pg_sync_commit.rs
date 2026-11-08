//! PostgreSQL implementation of the `PushCommit` transaction boundary.
//!
//! This is a production-buildable commit adapter. It is selected only by the
//! explicitly configured restricted PostgreSQL sync-core runtime.
//! `migrations/postgres/0001_sync_commit_core.sql` defines the bounded base
//! schema; `0030_record_redactions.sql` adds the compatibility and permanently
//! reserved record-ID gates this adapter enforces. It owns principal/Vault
//! fences, replay, CAS, sequence allocation, immutable versions, heads/graveyard,
//! events, receipts, object-reference/GC metadata, audit, and the notification
//! enqueue. It does not implement event/history/conflict reads, object upload
//! or deletion workers, registration/refresh/Vault lifecycle transactions,
//! notification delivery, admin jobs, backup, or HA/failover.
//!
//! Lock order in this adapter is session → user → device → Vault → membership
//! → Vault counter → current record head → referenced object. Existing
//! Account/device/Vault lifecycle routes remain outside this PostgreSQL
//! runtime; they are blocked while restricted sync-core mode is active.

use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{
    ApiError,
    auth::AuthUser,
    now_rfc3339,
    pg_notifications::notify_sync_wake,
    pg_record_redaction::{reject_redacted_record_tx, require_redaction_client_for_vault_tx},
    sync::{CommitResult, ensure_envelope_readable},
    sync_repository::{PushCommit, RepositoryFuture, SyncCommitRepository},
};

#[cfg(test)]
struct CommitAuthorizationGate {
    authorized: tokio::sync::Notify,
    resume: tokio::sync::Notify,
}

#[cfg(test)]
impl CommitAuthorizationGate {
    fn new() -> Self {
        Self {
            authorized: tokio::sync::Notify::new(),
            resume: tokio::sync::Notify::new(),
        }
    }

    async fn pause_after_authorization(&self) {
        self.authorized.notify_one();
        self.resume.notified().await;
    }

    async fn wait_until_authorized(&self) {
        self.authorized.notified().await;
    }

    fn resume(&self) {
        self.resume.notify_one();
    }
}

pub(crate) struct PgSyncCommitRepository {
    pool: PgPool,
    #[cfg(test)]
    after_authorization_gate: Option<std::sync::Arc<CommitAuthorizationGate>>,
}

impl PgSyncCommitRepository {
    /// Creates a commit-only adapter over a pool whose search path has already
    /// been provisioned with `migrations/postgres/0001_sync_commit_core.sql`.
    /// Production startup constructs it through `PgSyncRepository`.
    pub(crate) fn new(pool: PgPool) -> Self {
        Self {
            pool,
            #[cfg(test)]
            after_authorization_gate: None,
        }
    }

    #[cfg(test)]
    fn with_authorization_gate(
        pool: PgPool,
        gate: std::sync::Arc<CommitAuthorizationGate>,
    ) -> Self {
        Self {
            pool,
            after_authorization_gate: Some(gate),
        }
    }

    async fn commit(&self, command: PushCommit) -> Result<Value, ApiError> {
        let PushCommit {
            user,
            vault_id,
            device_id,
            batch_id,
            request_digest,
            operations,
            restore_retention_days,
        } = command;

        if device_id != user.device_id {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "request device does not match session device",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let (active_epoch, membership_version) =
            authorize_and_lock_vault(&mut tx, &user, &vault_id).await?;

        // Deterministically pause only unit-test repositories after the push
        // owns its principal, Vault, and membership locks. This is compiled
        // out of production builds and lets race tests establish both lock
        // orderings without timing sleeps.
        #[cfg(test)]
        if let Some(gate) = &self.after_authorization_gate {
            gate.pause_after_authorization().await;
        }

        // Reject same-ID creates/restores and stale exact retries before any
        // replay receipt can make the operation appear writable again.
        for operation in &operations {
            reject_redacted_record_tx(&mut tx, &vault_id, &operation.record_id).await?;
        }

        if operations
            .iter()
            .any(|operation| operation.record_schema >= 2)
        {
            require_v2_capability_support(&mut tx, &vault_id).await?;
            sqlx::query(
                "UPDATE vaults SET required_record_schema=2 WHERE vault_id=$1 AND required_record_schema<2",
            )
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        // The counter exists for every active Vault and is also the per-Vault
        // serialization point. It protects absent-head creates, replay
        // checks, CAS, and contiguous sequence allocation from concurrent
        // PostgreSQL writers.
        let counter_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM vault_counters WHERE vault_id=$1)")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if !counter_exists {
            return Err(ApiError::internal("Vault sync counter is missing"));
        }
        sqlx::query("SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1 FOR UPDATE")
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        if let Some(row) = sqlx::query(
            "SELECT request_digest,response_json FROM batch_receipts WHERE vault_id=$1 AND device_id=$2 AND batch_id=$3",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&batch_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        {
            if row.get::<String, _>("request_digest") != request_digest {
                return Err(ApiError::conflict(
                    "IDEMPOTENCY_KEY_REUSED",
                    "batch id was reused with a different request",
                ));
            }
            let stored: String = row.get("response_json");
            let mut response: Value = serde_json::from_str(&stored).map_err(ApiError::internal)?;
            if let Some(results) = response.get_mut("results").and_then(Value::as_array_mut) {
                for result in results {
                    result["already_committed"] = Value::Bool(true);
                }
            }
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(response);
        }

        let mut results = Vec::with_capacity(operations.len());
        let mut newly_committed = 0usize;
        for operation in operations {
            let envelope_text =
                serde_json::to_string(&operation.env).map_err(ApiError::internal)?;
            let operation_digest = crate::sha256_hex(&crate::jcs(&operation.env)?);

            if let Some(row) = sqlx::query(
                "SELECT request_digest,revision_id,commit_seq FROM op_receipts WHERE vault_id=$1 AND op_id=$2",
            )
            .bind(&vault_id)
            .bind(&operation.op_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            {
                if row.get::<String, _>("request_digest") != operation_digest {
                    return Err(ApiError::conflict(
                        "IDEMPOTENCY_KEY_REUSED",
                        "operation id was reused with different content",
                    ));
                }
                results.push(CommitResult {
                    op_id: operation.op_id,
                    revision_id: row.get("revision_id"),
                    commit_seq: row.get::<i64, _>("commit_seq").to_string(),
                    already_committed: true,
                });
                continue;
            }

            if let Some(prior_digest) = sqlx::query_scalar::<_, String>(
                "SELECT request_digest FROM op_receipts WHERE vault_id=$1 AND device_id=$2 AND device_seq=$3",
            )
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&operation.device_seq)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            {
                if prior_digest != operation_digest {
                    return Err(ApiError::conflict(
                        "IDEMPOTENCY_KEY_REUSED",
                        "device sequence was reused with different content",
                    ));
                }
            }

            if operation.key_epoch != active_epoch {
                return Err(ApiError::conflict(
                    "KEY_EPOCH_OUTDATED",
                    "record was encrypted for an inactive key epoch",
                ));
            }
            if operation.membership_version != membership_version {
                return Err(ApiError::conflict(
                    "MEMBERSHIP_VERSION_CONFLICT",
                    "record was encrypted for an outdated membership version",
                ));
            }

            let head = sqlx::query(
                "SELECT revision_id,deleted FROM record_heads WHERE vault_id=$1 AND record_id=$2 FOR UPDATE",
            )
            .bind(&vault_id)
            .bind(&operation.record_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let grave: Option<String> = sqlx::query_scalar(
                "SELECT deleted_revision FROM record_graveyard WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&operation.record_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let current = head.as_ref().map(|row| {
                (
                    row.get::<String, _>("revision_id"),
                    row.get::<bool, _>("deleted"),
                )
            });

            match (
                operation.operation.as_str(),
                current.as_ref(),
                operation.base.as_deref(),
                grave.as_deref(),
            ) {
                ("create", None, None, None) => {}
                ("create", _, _, Some(_)) => {
                    return Err(ApiError::conflict(
                        "RECORD_TOMBSTONED",
                        "record id is permanently reserved by a tombstone",
                    ));
                }
                ("create", Some(_), _, _) => {
                    return Err(revision_conflict(
                        &mut tx,
                        &vault_id,
                        &operation.record_id,
                        head.as_ref(),
                        user.declares_record_schema2,
                    )
                    .await?);
                }
                ("restore", Some((revision, true)), Some(base), _) if revision == base => {}
                ("restore", _, _, _) => {
                    return Err(ApiError::conflict(
                        "RECORD_TOMBSTONED",
                        "restore must match the current tombstone revision",
                    ));
                }
                ("update" | "delete", Some((revision, false)), Some(base), _)
                    if revision == base => {}
                ("update" | "delete", Some((_, true)), _, _) => {
                    return Err(ApiError::conflict(
                        "RECORD_TOMBSTONED",
                        "record is deleted; use an explicit restore",
                    ));
                }
                ("update" | "delete", _, _, Some(_)) => {
                    return Err(ApiError::conflict(
                        "RECORD_TOMBSTONED",
                        "record id is permanently reserved by a tombstone",
                    ));
                }
                _ => {
                    return Err(revision_conflict(
                        &mut tx,
                        &vault_id,
                        &operation.record_id,
                        head.as_ref(),
                        user.declares_record_schema2,
                    )
                    .await?);
                }
            }

            if operation.operation == "restore" {
                let restore_until: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
                    "SELECT restore_until FROM record_versions WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3 AND operation='delete'",
                )
                .bind(&vault_id)
                .bind(&operation.record_id)
                .bind(current.as_ref().map(|(revision, _)| revision))
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                let now: chrono::DateTime<chrono::Utc> =
                    sqlx::query_scalar("SELECT clock_timestamp()")
                        .fetch_one(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                let Some(restore_until) = restore_until else {
                    return Err(ApiError::internal(
                        "current tombstone restore deadline is missing",
                    ));
                };
                if crate::sync::restore_deadline_elapsed(now, restore_until) {
                    return Err(crate::sync::record_restore_expired(
                        restore_retention_days,
                        Some(&restore_until.to_rfc3339()),
                    ));
                }
            }

            // Revision reads are addressed by Vault + revision ID, so the ID
            // must be unique across records within this Vault.
            let revision_exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_versions WHERE vault_id=$1 AND revision_id=$2)",
            )
            .bind(&vault_id)
            .bind(&operation.revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if revision_exists {
                return Err(ApiError::conflict(
                    "REVISION_EXISTS",
                    "revision identifier has already been used",
                ));
            }

            persist_object_references(
                &mut tx,
                &vault_id,
                &operation.revision_id,
                &operation.object_refs,
            )
            .await?;

            let commit_seq: i64 = sqlx::query_scalar(
                "UPDATE vault_counters SET last_committed_seq=last_committed_seq+1 WHERE vault_id=$1 RETURNING last_committed_seq",
            )
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let deleted = operation.operation == "delete";
            let created_at: chrono::DateTime<chrono::Utc> = if deleted {
                sqlx::query_scalar("SELECT clock_timestamp()")
                    .fetch_one(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?
            } else {
                chrono::DateTime::parse_from_rfc3339(&now_rfc3339())
                    .map_err(ApiError::internal)?
                    .with_timezone(&chrono::Utc)
            };
            let restore_until =
                deleted.then(|| created_at + chrono::Duration::days(restore_retention_days));
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at,restore_until) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)")
                .bind(&vault_id)
                .bind(&operation.record_id)
                .bind(&operation.revision_id)
                .bind(&operation.base)
                .bind(&envelope_text)
                .bind(&operation_digest)
                .bind(commit_seq)
                .bind(&device_id)
                .bind(&operation.operation)
                .bind(&created_at)
                .bind(restore_until)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES($1,$2,$3,$4,$5) ON CONFLICT(vault_id,record_id) DO UPDATE SET revision_id=EXCLUDED.revision_id,deleted=EXCLUDED.deleted,commit_seq=EXCLUDED.commit_seq")
                .bind(&vault_id)
                .bind(&operation.record_id)
                .bind(&operation.revision_id)
                .bind(deleted)
                .bind(commit_seq)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            if operation.operation == "delete" {
                sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq,auto_purge_enabled,auto_purge_revision) VALUES($1,$2,$3,$4,FALSE,0) ON CONFLICT(vault_id,record_id) DO UPDATE SET deleted_revision=EXCLUDED.deleted_revision,deleted_seq=EXCLUDED.deleted_seq,auto_purge_enabled=FALSE,auto_purge_revision=0")
                    .bind(&vault_id)
                    .bind(&operation.record_id)
                    .bind(&operation.revision_id)
                    .bind(commit_seq)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            if operation.operation == "restore" {
                sqlx::query("DELETE FROM record_graveyard WHERE vault_id=$1 AND record_id=$2")
                    .bind(&vault_id)
                    .bind(&operation.record_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES($1,$2,$3,$4,$5,$6,$7)")
                .bind(&vault_id)
                .bind(commit_seq)
                .bind(&operation.operation)
                .bind(&operation.record_id)
                .bind(&operation.revision_id)
                .bind(&envelope_text)
                .bind(&created_at)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) VALUES($1,$2,$3,$4,$5,$6,$7,$8)")
                .bind(&vault_id)
                .bind(&operation.op_id)
                .bind(&device_id)
                .bind(&operation.device_seq)
                .bind(&operation_digest)
                .bind(&operation.record_id)
                .bind(&operation.revision_id)
                .bind(commit_seq)
                .execute(&mut *tx)
                .await
                .map_err(map_receipt_insert_error)?;

            newly_committed += 1;
            results.push(CommitResult {
                op_id: operation.op_id,
                revision_id: operation.revision_id,
                commit_seq: commit_seq.to_string(),
                already_committed: false,
            });
        }

        if newly_committed > 0 {
            enqueue_sync_available(&mut tx, &vault_id, &device_id).await?;
        }

        let response = json!({"batch_id":batch_id,"results":results});
        let response_json = serde_json::to_string(&response).map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES($1,$2,$3,$4,$5)")
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&batch_id)
            .bind(&request_digest)
            .bind(response_json)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if newly_committed > 0 {
            // Audit INSERT must be the last database write. First-page audit
            // readers take a table SHARE lock; this ordering prevents a wait
            // cycle through the batch-receipt unique key.
            record_vault_commit_audit(&mut tx, &vault_id, &user).await?;
            notify_sync_wake(&mut tx).await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }
}

impl SyncCommitRepository for PgSyncCommitRepository {
    fn commit_batch(&self, command: PushCommit) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.commit(command))
    }
}

async fn authorize_and_lock_vault(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(i64, i64), ApiError> {
    crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(tx, user)
        .await?;

    let vault = sqlx::query(
        "SELECT state,active_epoch,membership_version FROM vaults WHERE vault_id=$1 FOR UPDATE",
    )
    .bind(vault_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(vault) = vault else {
        return Err(ApiError::not_found());
    };
    let state: String = vault.get("state");
    if state == "deleting" {
        return Err(ApiError::vault_deletion_pending());
    }
    if state != "active" {
        return Err(ApiError::not_found());
    }
    let active_epoch: i64 = vault.get("active_epoch");
    let membership_version: i64 = vault.get("membership_version");

    let membership = sqlx::query(
        "SELECT role,state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(membership) = membership else {
        return Err(ApiError::not_found());
    };
    if membership.get::<String, _>("state") != "active" {
        return Err(ApiError::not_found());
    }
    let role: String = membership.get("role");
    if role == "viewer" {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    if role != "owner" && role != "editor" {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    require_redaction_client_for_vault_tx(tx, vault_id, user).await?;
    Ok((active_epoch, membership_version))
}

async fn require_v2_capability_support(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<(), ApiError> {
    let incompatible: bool = sqlx::query_scalar(
        r#"SELECT EXISTS(
            SELECT 1 FROM vault_members vm
            JOIN devices d ON d.user_id=vm.user_id AND d.status='active'
            LEFT JOIN device_capability_reports r ON r.device_id=d.device_id AND r.user_id=d.user_id
            WHERE vm.vault_id=$1 AND vm.state='active'
              AND (r.device_id IS NULL OR r.max_record_schema<2
                OR r.max_attachment_bytes<1073741824
                OR NOT (r.host_attachment_manifest_versions @> '[2]'::jsonb))
        )"#,
    )
    .bind(vault_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if incompatible {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "all active devices of active vault members must support schema 2, attachment manifest v2, and 1 GiB attachments",
        ));
    }
    Ok(())
}

async fn revision_conflict(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    record_id: &str,
    head: Option<&sqlx::postgres::PgRow>,
    declares_record_schema2: bool,
) -> Result<ApiError, ApiError> {
    let mut details = json!({});
    if let Some(row) = head {
        let revision: String = row.get("revision_id");
        let deleted: bool = row.get("deleted");
        let envelope: Option<String> = sqlx::query_scalar(
            "SELECT envelope FROM record_versions WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(&revision)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let current_envelope =
            envelope.and_then(|value| serde_json::from_str::<Value>(&value).ok());
        if let Some(envelope) = current_envelope.as_ref() {
            ensure_envelope_readable(declares_record_schema2, envelope)?;
        }
        details = json!({
            "current_revision_id":revision,
            "deleted":deleted,
            "current_envelope":current_envelope
        });
    }
    Ok(
        ApiError::conflict("REVISION_CONFLICT", "record changed on another device")
            .with_details(details),
    )
}

async fn persist_object_references(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    revision_id: &str,
    object_refs: &[String],
) -> Result<(), ApiError> {
    if object_refs.is_empty() {
        return Ok(());
    }
    let unique: std::collections::BTreeSet<&str> = object_refs.iter().map(String::as_str).collect();
    if unique.len() != object_refs.len() {
        return Err(ApiError::conflict(
            "OBJECT_REFERENCE_UNAVAILABLE",
            "one or more referenced objects are unavailable",
        ));
    }
    for object_id in unique {
        let available: Option<bool> = sqlx::query_scalar(
            "SELECT storage_state='available' FROM blob_objects WHERE vault_id=$1 AND object_id=$2 FOR UPDATE",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if available != Some(true) {
            return Err(ApiError::conflict(
                "OBJECT_REFERENCE_UNAVAILABLE",
                "one or more referenced objects are unavailable",
            ));
        }
        sqlx::query(
            "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES($1,$2,$3) ON CONFLICT(vault_id,revision_id,object_id) DO NOTHING",
        )
        .bind(vault_id)
        .bind(revision_id)
        .bind(object_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE blob_objects SET gc_after=NULL WHERE vault_id=$1 AND object_id=$2")
            .bind(vault_id)
            .bind(object_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

pub(crate) async fn enqueue_sync_available(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    source_device_id: &str,
) -> Result<(), ApiError> {
    let now = chrono::Utc::now().timestamp();
    sqlx::query("INSERT INTO notification_push_outbox(endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at,lease_id,lease_until,dead_lettered,updated_at) SELECT e.endpoint_id,1,0,0,$1,NULL,NULL,FALSE,$1 FROM notification_push_endpoints e JOIN devices d ON d.device_id=e.device_id JOIN users u ON u.user_id=e.user_id JOIN vault_members vm ON vm.user_id=e.user_id JOIN vaults v ON v.vault_id=vm.vault_id WHERE vm.vault_id=$2 AND vm.state='active' AND v.state='active' AND d.status='active' AND u.status='active' AND d.device_id!=$3 ON CONFLICT(endpoint_id) DO UPDATE SET requested_seq=notification_push_outbox.requested_seq+1,attempt_count=0,next_attempt_at=LEAST(notification_push_outbox.next_attempt_at,EXCLUDED.next_attempt_at),dead_lettered=FALSE,updated_at=EXCLUDED.updated_at")
        .bind(now)
        .bind(vault_id)
        .bind(source_device_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn record_vault_commit_audit(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    user: &AuthUser,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('vault',$1,$2,$3,'vault.sync_batch_committed','sync_batch',NULL,'success',$4,'api')")
        .bind(vault_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(chrono::Utc::now().timestamp())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

fn map_receipt_insert_error(error: sqlx::Error) -> ApiError {
    if let sqlx::Error::Database(database) = &error
        && database.code().as_deref() == Some("23505")
    {
        return ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "operation or device sequence is already committed",
        );
    }
    ApiError::internal(error)
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        time::Duration,
    };

    use futures_util::FutureExt;
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgListener, PgPoolOptions},
    };
    use uuid::Uuid;

    use super::*;
    use crate::sync::VerifiedOperation;

    const MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const RETENTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const SNAPSHOT_MIGRATION: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );
    const USER: &str = "pg-commit-user";
    const DEVICE: &str = "pg-commit-device";
    const SESSION: &str = "pg-commit-session";
    const VAULT: &str = "pg-commit-vault";
    const ACCESS_HASH: &str = "pg-commit-access-hash";

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    /// Armed immediately after schema creation so failures while connecting,
    /// migrating, or seeding cannot strand the isolated test schema.
    struct SchemaSetupCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl SchemaSetupCleanupGuard {
        fn new(admin_pool: PgPool, schema: String) -> Self {
            Self {
                admin_pool,
                schema,
                armed: true,
            }
        }

        async fn cleanup(&mut self) {
            if !self.armed {
                return;
            }
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated schema after fixture setup failure");
            self.armed = false;
        }

        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for SchemaSetupCleanupGuard {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL commit adapter tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL tests outside an explicitly disposable database"
            );
            assert!(!matches!(
                database.as_str(),
                "postgres" | "template0" | "template1"
            ));
            let admin_pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect PostgreSQL disposable test database");
            let schema = format!("atermius_pg_commit_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            let mut setup_guard = SchemaSetupCleanupGuard::new(admin_pool.clone(), schema.clone());
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect isolated PostgreSQL search path");
                sqlx::raw_sql(MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply bounded PostgreSQL commit schema");
                for migration in [RETENTION_MIGRATION, CONFLICT_MIGRATION, SNAPSHOT_MIGRATION] {
                    sqlx::raw_sql(migration)
                        .execute(&pool)
                        .await
                        .expect("apply PostgreSQL record-redaction prerequisites");
                }
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema (\
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
                )
                .execute(&pool)
                .await
                .expect("create PostgreSQL schema-version fixture");
                sqlx::raw_sql(REDACTION_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL record-redaction schema");
                sqlx::raw_sql(REDACTED_CONFLICT_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL redacted-conflict compatibility schema");
                seed(&pool).await;
                pool
            })
            .catch_unwind()
            .await;
            match setup {
                Ok(pool) => {
                    let database = Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    };
                    setup_guard.disarm();
                    database
                }
                Err(payload) => {
                    setup_guard.cleanup().await;
                    resume_unwind(payload)
                }
            }
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL test schema");
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
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    async fn seed(pool: &PgPool) {
        sqlx::query(
            "INSERT INTO users(user_id,username,status) VALUES($1,'pg-commit-user','active')",
        )
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) VALUES($1,$2,'test','active')",
        )
        .bind(DEVICE)
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,'pg-commit-refresh-hash',CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
            .bind(SESSION)
            .bind(USER)
            .bind(DEVICE)
            .bind(ACCESS_HASH)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) VALUES($1,$2,'active',1,1)")
            .bind(VAULT)
            .bind(USER)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
        )
        .bind(VAULT)
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES($1,0)")
            .bind(VAULT)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,size,sha256,gc_after) VALUES($1,'object-a',1,repeat('a',64),1),($1,'object-b',1,repeat('b',64),1)")
            .bind(VAULT)
            .execute(pool)
        .await
        .unwrap();
    }

    async fn configure_actor_as_editor(pool: &PgPool) {
        sqlx::query(
            "INSERT INTO users(user_id,username,status) \
             VALUES('pg-commit-race-owner','pg-commit-race-owner','active')",
        )
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("UPDATE vaults SET owner_user_id='pg-commit-race-owner' WHERE vault_id=$1")
            .bind(VAULT)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_members SET role='editor' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT)
            .bind(USER)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) \
             VALUES($1,'pg-commit-race-owner','owner','active')",
        )
        .bind(VAULT)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn lock_vault_for_membership_change(tx: &mut Transaction<'_, Postgres>) {
        sqlx::query(
            "SELECT state,active_epoch,membership_version FROM vaults \
             WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(VAULT)
        .fetch_one(&mut **tx)
        .await
        .unwrap();
    }

    async fn downgrade_actor_to_viewer(tx: &mut Transaction<'_, Postgres>) {
        sqlx::query("UPDATE vault_members SET role='viewer' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT)
            .bind(USER)
            .execute(&mut **tx)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE vaults SET active_epoch=active_epoch+1, \
                 membership_version=membership_version+1 WHERE vault_id=$1",
        )
        .bind(VAULT)
        .execute(&mut **tx)
        .await
        .unwrap();
    }

    fn actor() -> AuthUser {
        AuthUser {
            user_id: USER.to_owned(),
            device_id: DEVICE.to_owned(),
            session_id: SESSION.to_owned(),
            access_hash: ACCESS_HASH.to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        }
    }

    fn operation(
        op_id: &str,
        seq: &str,
        record: &str,
        revision: &str,
        base: Option<&str>,
        kind: &str,
    ) -> VerifiedOperation {
        let header = json!({
            "record_id":record,
            "revision_id":revision,
            "op_id":op_id,
            "record_schema":1,
            "device_seq":seq,
            "key_epoch":"1",
            "membership_version":"1",
            "operation":kind,
            "base_revision_id":base,
            "object_refs":[]
        });
        VerifiedOperation {
            record_id: record.to_owned(),
            revision_id: revision.to_owned(),
            op_id: op_id.to_owned(),
            record_schema: 1,
            device_seq: seq.to_owned(),
            key_epoch: 1,
            membership_version: 1,
            operation: kind.to_owned(),
            base: base.map(str::to_owned),
            object_refs: Vec::new(),
            env: crate::sync::Envelope {
                header,
                nonce: "AA".to_owned(),
                ciphertext: "AA".to_owned(),
                signature: "test-only-verified-envelope".to_owned(),
            },
        }
    }

    fn with_object_ref(mut operation: VerifiedOperation, object_id: &str) -> VerifiedOperation {
        operation.object_refs.push(object_id.to_owned());
        operation.env.header["object_refs"] = json!(operation.object_refs);
        operation
    }

    fn commit(batch_id: &str, operations: Vec<VerifiedOperation>) -> PushCommit {
        PushCommit {
            user: actor(),
            vault_id: VAULT.to_owned(),
            device_id: DEVICE.to_owned(),
            batch_id: batch_id.to_owned(),
            request_digest: format!("request-{batch_id}"),
            operations,
            restore_retention_days: 30,
        }
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_allocates_contiguous_sequences_under_concurrency() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        let mut tasks = Vec::new();
        for index in 0..12 {
            let repository = PgSyncCommitRepository::new(database.pool.clone());
            tasks.push(tokio::spawn(async move {
                repository
                    .commit_batch(commit(
                        &format!("batch-{index}"),
                        vec![operation(
                            &format!("op-{index}"),
                            &(index + 1).to_string(),
                            &format!("record-{index}"),
                            &format!("revision-{index}"),
                            None,
                            "create",
                        )],
                    ))
                    .await
            }));
        }
        for task in tasks {
            task.await.unwrap().unwrap();
        }
        let seqs: Vec<i64> = sqlx::query_scalar(
            "SELECT commit_seq FROM record_versions WHERE vault_id=$1 ORDER BY commit_seq",
        )
        .bind(VAULT)
        .fetch_all(&database.pool)
        .await
        .unwrap();
        assert_eq!(seqs, (1..=12).collect::<Vec<_>>());
        database.cleanup().await;
        drop(repository);
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_replays_lost_ack_exactly_without_duplicate_effects() {
        let database = TestDatabase::create().await;
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES('pg-notify-user','pg-notify-user','active')")
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,status) VALUES('pg-notify-device','pg-notify-user','test','active')")
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,'pg-notify-user','viewer','active')")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO notification_push_endpoints(endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at) VALUES('pg-notify-endpoint','pg-notify-device','pg-notify-user','apns',repeat('c',64),repeat('x',80),0,0)")
            .execute(&database.pool)
            .await
            .unwrap();
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        let first_command = commit(
            "lost-ack-batch",
            vec![with_object_ref(
                operation("lost-ack-op", "1", "record", "revision", None, "create"),
                "object-a",
            )],
        );
        let first = repository.commit_batch(first_command).await.unwrap();
        let replay = repository
            .commit_batch(commit(
                "lost-ack-batch",
                vec![with_object_ref(
                    operation("lost-ack-op", "1", "record", "revision", None, "create"),
                    "object-a",
                )],
            ))
            .await
            .unwrap();
        assert_eq!(first["batch_id"], replay["batch_id"]);
        assert_eq!(first["results"][0]["op_id"], replay["results"][0]["op_id"]);
        assert_eq!(
            first["results"][0]["revision_id"],
            replay["results"][0]["revision_id"]
        );
        assert_eq!(
            first["results"][0]["commit_seq"],
            replay["results"][0]["commit_seq"]
        );
        assert_eq!(replay["results"][0]["already_committed"], true);
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM change_events").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM audit_events").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM object_references").await,
            1
        );
        let gc_after: Option<i64> =
            sqlx::query_scalar("SELECT gc_after FROM blob_objects WHERE object_id='object-a'")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(gc_after, None);
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='pg-notify-endpoint'"
            )
            .await,
            1
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL redaction acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_rejects_redacted_record_before_replay_or_any_write() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        let record_id = "record-reserved-by-redaction";
        let deleted_revision_id = "deleted-revision";
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,1)")
            .bind(VAULT)
            .bind(record_id)
            .bind(deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=2 WHERE vault_id=$1")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,1,2)")
            .bind(Uuid::new_v4().to_string())
            .bind(VAULT)
            .bind(record_id)
            .bind(deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();

        let mut legacy = commit(
            "legacy-redacted-record-batch",
            vec![operation(
                "legacy-redacted-record-op",
                "1",
                record_id,
                "legacy-revision",
                None,
                "create",
            )],
        );
        legacy.user.declares_sync_redaction_v1 = false;
        let legacy_error = repository.commit(legacy).await.unwrap_err();
        assert_eq!(
            legacy_error.status,
            axum::http::StatusCode::UPGRADE_REQUIRED
        );
        assert_eq!(
            legacy_error.body.code,
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        let error = repository
            .commit(commit(
                "redacted-record-batch",
                vec![operation(
                    "redacted-record-op",
                    "1",
                    record_id,
                    "new-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(error.body.code, "RECORD_REDACTED");
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM batch_receipts")
                .fetch_one(&database.pool)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM record_versions")
                .fetch_one(&database.pool)
                .await
                .unwrap(),
            0
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_rejects_revision_id_reuse_across_records_in_one_vault() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "revision-owner-batch",
                vec![operation(
                    "revision-owner-op",
                    "1",
                    "first-record",
                    "vault-global-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();

        let error = repository
            .commit_batch(commit(
                "revision-reuse-batch",
                vec![operation(
                    "revision-reuse-op",
                    "2",
                    "second-record",
                    "vault-global-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap_err();
        assert_eq!(error.body.code, "REVISION_EXISTS");
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters"
            )
            .await,
            1
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL role parity acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_accepts_editor_members() {
        let database = TestDatabase::create().await;
        sqlx::query("UPDATE vault_members SET role='editor' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT)
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        let result = PgSyncCommitRepository::new(database.pool.clone())
            .commit_batch(commit(
                "editor-batch",
                vec![operation(
                    "editor-op",
                    "1",
                    "editor-record",
                    "editor-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        assert_eq!(result["results"][0]["commit_seq"], "1");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL membership/push race acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_wins_when_editor_push_is_authorized_before_membership_downgrade() {
        let database = TestDatabase::create().await;
        configure_actor_as_editor(&database.pool).await;

        let gate = std::sync::Arc::new(CommitAuthorizationGate::new());
        let repository =
            PgSyncCommitRepository::with_authorization_gate(database.pool.clone(), gate.clone());
        let push = tokio::spawn(async move {
            repository
                .commit_batch(commit(
                    "push-first-batch",
                    vec![operation(
                        "push-first-op",
                        "1",
                        "push-first-record",
                        "push-first-revision",
                        None,
                        "create",
                    )],
                ))
                .await
        });
        tokio::time::timeout(Duration::from_secs(10), gate.wait_until_authorized())
            .await
            .expect("push should acquire its authorization locks before pausing");

        let downgrade = {
            let pool = database.pool.clone();
            tokio::spawn(async move {
                let mut tx = pool.begin().await.unwrap();
                lock_vault_for_membership_change(&mut tx).await;
                downgrade_actor_to_viewer(&mut tx).await;
                tx.commit().await.unwrap();
            })
        };
        wait_for_vault_lock_wait(&database.pool).await;

        gate.resume();
        let response = push.await.unwrap().unwrap();
        downgrade.await.unwrap();

        assert_eq!(response["results"][0]["commit_seq"], "1");
        let role: String =
            sqlx::query_scalar("SELECT role FROM vault_members WHERE vault_id=$1 AND user_id=$2")
                .bind(VAULT)
                .bind(USER)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(role, "viewer");
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM batch_receipts").await,
            1
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters"
            )
            .await,
            1
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT active_epoch FROM vaults WHERE vault_id='pg-commit-vault'"
            )
            .await,
            2
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT membership_version FROM vaults WHERE vault_id='pg-commit-vault'"
            )
            .await,
            2
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL membership/push race acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_rejects_editor_push_when_membership_downgrade_serializes_first() {
        let database = TestDatabase::create().await;
        configure_actor_as_editor(&database.pool).await;

        let mut downgrade = database.pool.begin().await.unwrap();
        lock_vault_for_membership_change(&mut downgrade).await;
        downgrade_actor_to_viewer(&mut downgrade).await;

        let push = {
            let pool = database.pool.clone();
            tokio::spawn(async move {
                PgSyncCommitRepository::new(pool)
                    .commit_batch(commit(
                        "downgrade-first-batch",
                        vec![operation(
                            "downgrade-first-op",
                            "1",
                            "downgrade-first-record",
                            "downgrade-first-revision",
                            None,
                            "create",
                        )],
                    ))
                    .await
            })
        };
        wait_for_vault_lock_wait(&database.pool).await;
        downgrade.commit().await.unwrap();

        let error = push.await.unwrap().unwrap_err();
        assert_eq!(error.body.code, "VAULT_READ_ONLY");
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            0
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM batch_receipts").await,
            0
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters"
            )
            .await,
            0
        );
        let role: String =
            sqlx::query_scalar("SELECT role FROM vault_members WHERE vault_id=$1 AND user_id=$2")
                .bind(VAULT)
                .bind(USER)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(role, "viewer");
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT active_epoch FROM vaults WHERE vault_id='pg-commit-vault'"
            )
            .await,
            2
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT membership_version FROM vaults WHERE vault_id='pg-commit-vault'"
            )
            .await,
            2
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL tombstone acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_persists_delete_graveyard_and_explicit_restore() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "create-batch",
                vec![operation(
                    "create-op",
                    "1",
                    "record",
                    "revision-1",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        repository
            .commit_batch(commit(
                "delete-batch",
                vec![operation(
                    "delete-op",
                    "2",
                    "record",
                    "revision-2",
                    Some("revision-1"),
                    "delete",
                )],
            ))
            .await
            .unwrap();
        let deleted_revision: String = sqlx::query_scalar(
            "SELECT deleted_revision FROM record_graveyard WHERE vault_id=$1 AND record_id='record'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(deleted_revision, "revision-2");
        let deleted: bool = sqlx::query_scalar(
            "SELECT deleted FROM record_heads WHERE vault_id=$1 AND record_id='record'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(deleted);

        repository
            .commit_batch(commit(
                "restore-batch",
                vec![operation(
                    "restore-op",
                    "3",
                    "record",
                    "revision-3",
                    Some("revision-2"),
                    "restore",
                )],
            ))
            .await
            .unwrap();
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT count(*) FROM record_graveyard WHERE vault_id='pg-commit-vault' AND record_id='record'"
            )
            .await,
            0
        );
        let deleted: bool = sqlx::query_scalar(
            "SELECT deleted FROM record_heads WHERE vault_id=$1 AND record_id='record'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(!deleted);
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id='pg-commit-vault'"
            )
            .await,
            3
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL restore deadline acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_rejects_restore_after_the_retention_window_atomically() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "short-policy-create-batch",
                vec![operation(
                    "short-policy-create-op",
                    "1",
                    "short-policy-record",
                    "short-policy-revision-1",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        let pg_time_before_delete: chrono::DateTime<chrono::Utc> =
            sqlx::query_scalar("SELECT clock_timestamp()")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        repository
            .commit_batch(commit(
                "short-policy-delete-batch",
                vec![operation(
                    "short-policy-delete-op",
                    "2",
                    "short-policy-record",
                    "short-policy-revision-2",
                    Some("short-policy-revision-1"),
                    "delete",
                )],
            ))
            .await
            .unwrap();
        let (delete_created_at, delete_restore_until): (
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
        ) = sqlx::query_as(
            "SELECT created_at,restore_until FROM record_versions WHERE vault_id=$1 \
             AND record_id='short-policy-record' AND revision_id='short-policy-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        let pg_time_after_delete: chrono::DateTime<chrono::Utc> =
            sqlx::query_scalar("SELECT clock_timestamp()")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert!(delete_created_at >= pg_time_before_delete);
        assert!(delete_created_at <= pg_time_after_delete);
        assert_eq!(
            delete_restore_until,
            delete_created_at + chrono::Duration::days(30),
            "stored restore deadline is derived from the same PostgreSQL timestamp as created_at"
        );
        sqlx::query(
            "UPDATE record_versions SET created_at=clock_timestamp()-interval '29 days', \
             restore_until=clock_timestamp()+interval '1 day' \
             WHERE vault_id=$1 AND record_id='short-policy-record' \
               AND revision_id='short-policy-revision-2'",
        )
        .bind(VAULT)
        .execute(&database.pool)
        .await
        .unwrap();
        let (aged_delete_at, fixed_deadline, db_now): (
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
        ) = sqlx::query_as(
            "SELECT created_at,restore_until,clock_timestamp() FROM record_versions WHERE vault_id=$1 \
             AND record_id='short-policy-record' AND revision_id='short-policy-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(aged_delete_at + chrono::Duration::days(1) < db_now);
        assert!(db_now < fixed_deadline);
        let mut short_policy_restore = commit(
            "short-policy-restore-batch",
            vec![operation(
                "short-policy-restore-op",
                "3",
                "short-policy-record",
                "short-policy-revision-3",
                Some("short-policy-revision-2"),
                "restore",
            )],
        );
        short_policy_restore.restore_retention_days = 1;
        repository
            .commit_batch(short_policy_restore)
            .await
            .expect("short current retention cannot shorten the stored deadline");

        repository
            .commit_batch(commit(
                "expired-create-batch",
                vec![operation(
                    "expired-create-op",
                    "4",
                    "expired-record",
                    "expired-revision-1",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        repository
            .commit_batch(commit(
                "expired-delete-batch",
                vec![operation(
                    "expired-delete-op",
                    "5",
                    "expired-record",
                    "expired-revision-2",
                    Some("expired-revision-1"),
                    "delete",
                )],
            ))
            .await
            .unwrap();
        sqlx::query(
            "UPDATE record_versions SET restore_until=clock_timestamp()-interval '1 second' \
             WHERE vault_id=$1 AND record_id='expired-record' AND revision_id='expired-revision-2'",
        )
        .bind(VAULT)
        .execute(&database.pool)
        .await
        .unwrap();
        let persisted_deadline: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
            "SELECT restore_until FROM record_versions WHERE vault_id=$1 \
             AND record_id='expired-record' AND revision_id='expired-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();

        async fn state(pool: &PgPool) -> (String, bool, i64, String, i64, i64, [i64; 6]) {
            let head: (String, bool, i64) = sqlx::query_as(
                "SELECT revision_id,deleted,commit_seq FROM record_heads WHERE vault_id=$1 AND record_id='expired-record'",
            )
            .bind(VAULT)
            .fetch_one(pool)
            .await
            .unwrap();
            let grave: (String, i64) = sqlx::query_as(
                "SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=$1 AND record_id='expired-record'",
            )
            .bind(VAULT)
            .fetch_one(pool)
            .await
            .unwrap();
            let counter: i64 = sqlx::query_scalar(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1",
            )
            .bind(VAULT)
            .fetch_one(pool)
            .await
            .unwrap();
            let counts = [
                "SELECT count(*) FROM record_versions WHERE vault_id=$1 AND record_id='expired-record'",
                "SELECT count(*) FROM change_events WHERE vault_id=$1 AND record_id='expired-record'",
                "SELECT count(*) FROM op_receipts WHERE vault_id=$1 AND record_id='expired-record'",
                "SELECT count(*) FROM batch_receipts WHERE vault_id=$1",
                "SELECT count(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1",
                "SELECT count(*) FROM notification_push_outbox WHERE endpoint_id IN \
                 (SELECT endpoint_id FROM notification_push_endpoints WHERE user_id=$1)",
            ];
            let mut values = [0; 6];
            for (index, query) in counts.iter().enumerate() {
                values[index] = sqlx::query_scalar::<_, i64>(query)
                    .bind(if index == 5 { USER } else { VAULT })
                    .fetch_one(pool)
                    .await
                    .unwrap();
            }
            (head.0, head.1, head.2, grave.0, grave.1, counter, values)
        }

        let before = state(&database.pool).await;
        let mut expired_restore = commit(
            "expired-restore-batch",
            vec![operation(
                "expired-restore-op",
                "6",
                "expired-record",
                "expired-revision-3",
                Some("expired-revision-2"),
                "restore",
            )],
        );
        // A longer current setting must not extend a deadline that was
        // persisted when the record was deleted.
        expired_restore.restore_retention_days = 3650;
        let error = repository.commit_batch(expired_restore).await.unwrap_err();
        assert_eq!(error.status.as_u16(), 409);
        assert_eq!(error.body.code, "RECORD_RESTORE_EXPIRED");
        assert_eq!(
            error.body.details.as_ref().unwrap()["recovery"],
            "create_new_record"
        );
        assert_eq!(
            error.body.details.as_ref().unwrap()["restore_retention_days"],
            3650
        );
        assert_eq!(
            error.body.details.as_ref().unwrap()["restore_until"],
            persisted_deadline.to_rfc3339()
        );
        assert_eq!(state(&database.pool).await, before);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_concurrent_restores_use_persisted_deadline_and_exact_tombstone_cas() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "concurrent-deadline-create",
                vec![operation(
                    "concurrent-deadline-create-op",
                    "1",
                    "concurrent-deadline-record",
                    "concurrent-deadline-revision-1",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        repository
            .commit_batch(commit(
                "concurrent-deadline-delete",
                vec![operation(
                    "concurrent-deadline-delete-op",
                    "2",
                    "concurrent-deadline-record",
                    "concurrent-deadline-revision-2",
                    Some("concurrent-deadline-revision-1"),
                    "delete",
                )],
            ))
            .await
            .unwrap();

        let (deadline, database_now): (
            chrono::DateTime<chrono::Utc>,
            chrono::DateTime<chrono::Utc>,
        ) = sqlx::query_as(
            "SELECT restore_until,clock_timestamp() FROM record_versions WHERE vault_id=$1 \
             AND record_id='concurrent-deadline-record' AND revision_id='concurrent-deadline-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(deadline > database_now);

        let created_at: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
            "SELECT created_at FROM record_versions WHERE vault_id=$1 \
             AND record_id='concurrent-deadline-record' AND revision_id='concurrent-deadline-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        sqlx::query(
            "UPDATE record_versions SET restore_until=NULL WHERE vault_id=$1 \
             AND record_id='concurrent-deadline-record' AND revision_id='concurrent-deadline-revision-2'",
        )
        .bind(VAULT)
        .execute(&database.pool)
        .await
        .unwrap();
        crate::pg_sync_runtime::backfill_postgres_restore_deadlines(&database.pool, 30)
            .await
            .unwrap();
        let backfilled_deadline: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
            "SELECT restore_until FROM record_versions WHERE vault_id=$1 \
             AND record_id='concurrent-deadline-record' AND revision_id='concurrent-deadline-revision-2'",
        )
        .bind(VAULT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(backfilled_deadline, created_at + chrono::Duration::days(30));

        let restore = |batch_id: &str, op_id: &str, device_seq: &str| {
            let mut command = commit(
                batch_id,
                vec![operation(
                    op_id,
                    device_seq,
                    "concurrent-deadline-record",
                    &format!("revision-{op_id}"),
                    Some("concurrent-deadline-revision-2"),
                    "restore",
                )],
            );
            command.restore_retention_days = if device_seq == "3" { 1 } else { 3650 };
            command
        };
        let first_repository = PgSyncCommitRepository::new(database.pool.clone());
        let second_repository = PgSyncCommitRepository::new(database.pool.clone());
        let first = first_repository.commit_batch(restore(
            "concurrent-deadline-restore-a",
            "concurrent-deadline-restore-op-a",
            "3",
        ));
        let second = second_repository.commit_batch(restore(
            "concurrent-deadline-restore-b",
            "concurrent-deadline-restore-op-b",
            "4",
        ));
        let (first, second) = tokio::join!(first, second);
        assert_ne!(first.is_ok(), second.is_ok());
        let losing_restore = first.err().or_else(|| second.err()).unwrap();
        assert_eq!(losing_restore.body.code, "RECORD_TOMBSTONED");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_stale_cas_rolls_back_earlier_batch_writes_and_side_effects() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "seed-head",
                vec![operation(
                    "seed-op", "1", "record", "head-r1", None, "create",
                )],
            ))
            .await
            .unwrap();
        let mut first = operation(
            "batch-first-op",
            "2",
            "new-record",
            "new-r1",
            None,
            "create",
        );
        first = with_object_ref(first, "object-a");
        let result = repository
            .commit_batch(commit(
                "stale-cas-batch",
                vec![
                    first,
                    operation(
                        "stale-op",
                        "3",
                        "record",
                        "head-r2",
                        Some("stale-base"),
                        "update",
                    ),
                ],
            ))
            .await;
        assert_eq!(result.unwrap_err().body.code, "REVISION_CONFLICT");
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM change_events").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM op_receipts").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM batch_receipts").await,
            1
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters"
            )
            .await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM object_references").await,
            0
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM audit_events").await,
            1
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT count(*) FROM notification_push_outbox"
            )
            .await,
            0
        );
        let gc_after: Option<i64> =
            sqlx::query_scalar("SELECT gc_after FROM blob_objects WHERE object_id='object-a'")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(gc_after, Some(1));
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL migration acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_migration_allows_account_and_device_purge_without_losing_shared_history() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        repository
            .commit_batch(commit(
                "history-survival-batch",
                vec![operation(
                    "history-survival-op",
                    "1",
                    "record",
                    "revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();

        // A shared Vault belongs to another account. Deleting the contributor's
        // device/account must not have restrictive FKs from historical signer
        // IDs, nor cascade immutable history that remains visible in the Vault.
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES('pg-commit-owner','other-owner','active')")
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,'pg-commit-owner','owner','active')")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vaults SET owner_user_id='pg-commit-owner' WHERE vault_id=$1")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("DELETE FROM devices WHERE device_id=$1")
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM op_receipts").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM batch_receipts").await,
            1
        );
        sqlx::query("DELETE FROM users WHERE user_id=$1")
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_heads").await,
            1
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM change_events").await,
            1
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL commit adapter acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_commit_adapter_orders_session_revocation_after_an_inflight_write() {
        let database = TestDatabase::create().await;
        let repository = PgSyncCommitRepository::new(database.pool.clone());
        let mut revoke = database.pool.begin().await.unwrap();
        sqlx::query("UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP WHERE session_id=$1")
            .bind(SESSION)
            .execute(&mut *revoke)
            .await
            .unwrap();
        let writer = {
            let pool = database.pool.clone();
            tokio::spawn(async move {
                PgSyncCommitRepository::new(pool)
                    .commit_batch(commit(
                        "revoke-race-batch",
                        vec![operation(
                            "revoke-race-op",
                            "1",
                            "record",
                            "revision",
                            None,
                            "create",
                        )],
                    ))
                    .await
            })
        };
        wait_for_session_lock_wait(&database.pool).await;
        revoke.commit().await.unwrap();
        let result = writer.await.unwrap();
        assert_eq!(result.unwrap_err().body.code, "AUTH_REQUIRED");
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM record_versions").await,
            0
        );
        assert_eq!(
            scalar(&database.pool, "SELECT count(*) FROM batch_receipts").await,
            0
        );
        database.cleanup().await;
        drop(repository);
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL notification acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_notifications_are_empty_commit_only_and_suppressed_for_replay() {
        let database = TestDatabase::create().await;
        let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
        listener.listen("atermius_sync_wake_v1").await.unwrap();
        let repository = PgSyncCommitRepository::new(database.pool.clone());

        repository
            .commit_batch(commit(
                "notify-batch",
                vec![operation(
                    "notify-op",
                    "1",
                    "notify-record",
                    "notify-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        let notification = tokio::time::timeout(Duration::from_secs(2), listener.recv())
            .await
            .expect("committed sync write should notify promptly")
            .unwrap();
        assert_eq!(notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(notification.payload(), "");

        // A transaction that queues the same fixed notification and rolls
        // back must not wake any listener.
        let mut tx = database.pool.begin().await.unwrap();
        notify_sync_wake(&mut tx).await.unwrap();
        tx.rollback().await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "rolled-back notification must not be delivered"
        );

        // The failed second operation aborts a transaction after its first
        // record write, so neither that partial write nor a wake may escape.
        let mut invalid = operation(
            "notify-invalid-op",
            "3",
            "notify-invalid-record",
            "notify-invalid-revision",
            None,
            "create",
        );
        invalid.key_epoch = 99;
        invalid.env.header["key_epoch"] = json!("99");
        assert!(
            repository
                .commit_batch(commit(
                    "notify-rolled-back-batch",
                    vec![
                        operation(
                            "notify-partial-op",
                            "2",
                            "notify-partial-record",
                            "notify-partial-revision",
                            None,
                            "create",
                        ),
                        invalid,
                    ],
                ))
                .await
                .is_err()
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "failed sync transaction must not publish a wake"
        );

        // Exact receipt replay must not advance the sequence or send a wake.
        repository
            .commit_batch(commit(
                "notify-batch",
                vec![operation(
                    "notify-op",
                    "1",
                    "notify-record",
                    "notify-revision",
                    None,
                    "create",
                )],
            ))
            .await
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "idempotent receipt replay must not publish a wake"
        );
        assert_eq!(
            scalar(
                &database.pool,
                "SELECT last_committed_seq FROM vault_counters"
            )
            .await,
            1
        );
        drop(listener);
        database.cleanup().await;
    }

    async fn scalar(pool: &PgPool, query: &str) -> i64 {
        sqlx::query_scalar(query).fetch_one(pool).await.unwrap()
    }

    async fn wait_for_session_lock_wait(pool: &PgPool) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let waiting: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%FROM sessions%FOR SHARE%')",
                )
                .fetch_one(pool)
                .await
                .unwrap();
                if waiting {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("writer should block behind the uncommitted session revocation");
    }

    async fn wait_for_vault_lock_wait(pool: &PgPool) {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let waiting: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM pg_stat_activity \
                     WHERE datname=current_database() AND wait_event_type='Lock' \
                       AND query LIKE '%FROM vaults%FOR UPDATE%')",
                )
                .fetch_one(pool)
                .await
                .unwrap();
                if waiting {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("concurrent membership update and push should serialize on the Vault row");
    }
}

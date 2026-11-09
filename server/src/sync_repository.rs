//! Backend-owned transactions for Vault sync reads and writes.
//!
//! The sync service verifies and canonicalizes incoming signed envelopes
//! before calling this boundary. A backend owns the complete authorization,
//! receipt, CAS, sequence, and persistence transaction so its native locking
//! semantics stay local to its adapter.

use std::{future::Future, pin::Pin};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey};
use futures_util::TryStreamExt;
use serde_json::{Value, json};
use sqlx::{QueryBuilder, Row, Sqlite, SqlitePool, sqlite::SqliteRow};
use uuid::Uuid;

use crate::{
    ApiError,
    auth::AuthUser,
    now_rfc3339,
    sync::{
        CommitResult, HistoryBounds, HistoryKind, MAX_SYNC_SNAPSHOT_RESPONSE_BYTES,
        SYNC_SNAPSHOT_METADATA_RESERVE_BYTES, SyncPageBudget, VerifiedOperation, cursor_is_expired,
        encode_cursor_with_key, ensure_envelope_readable, ensure_sync_page_response_fits,
        ensure_sync_snapshot_response_fits, foreign_generation_history_cursor_claim,
        history_cursor, parse_cursor_with_key, parse_history_cursor, parse_snapshot_page_cursor,
        snapshot_page_cursor, sync_page_item_too_large, sync_snapshot_payload_too_large,
    },
};

pub(crate) struct ChangesPageCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) raw_cursor: Option<String>,
    pub(crate) limit: i64,
    pub(crate) cursor_key: [u8; 32],
    pub(crate) generation: String,
    #[cfg(test)]
    pub(crate) test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
}

pub(crate) struct ResolveConflictCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) conflict_id: String,
    pub(crate) resolved_revision_id: String,
}

pub(crate) struct ConflictChangesPageCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) after_seq: i64,
    pub(crate) after_seq_wire: String,
    pub(crate) limit: i64,
    pub(crate) server_generation: Option<String>,
    pub(crate) generation: String,
    #[cfg(test)]
    pub(crate) test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
}

pub(crate) struct HistoryPageCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) snapshot_id: String,
    pub(crate) kind: HistoryKind,
    pub(crate) raw_cursor: Option<String>,
    pub(crate) limit: i64,
    pub(crate) generation: String,
    pub(crate) cursor_key: [u8; 32],
}

pub(crate) struct ReadSnapshotCommand {
    pub(crate) user: AuthUser,
    pub(crate) snapshot_id: String,
    pub(crate) generation: String,
    pub(crate) cursor_key: [u8; 32],
    pub(crate) page: Option<SnapshotPageRequest>,
}

pub(crate) struct SnapshotPageRequest {
    pub(crate) limit: i64,
    pub(crate) page_cursor: Option<String>,
}

pub(crate) struct ReadRevisionCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) revision_id: String,
}

pub(crate) struct CreateSnapshotCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) generation: String,
    pub(crate) cursor_key: [u8; 32],
}

pub(crate) struct CreateConflictCommand {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) device_id: String,
    pub(crate) conflict_id: String,
    pub(crate) request_digest: String,
    pub(crate) envelope_json: String,
    pub(crate) operation: VerifiedOperation,
}

pub(crate) struct PushCommit {
    pub(crate) user: AuthUser,
    pub(crate) vault_id: String,
    pub(crate) device_id: String,
    pub(crate) batch_id: String,
    pub(crate) request_digest: String,
    pub(crate) operations: Vec<VerifiedOperation>,
    pub(crate) restore_retention_days: i64,
}

pub(crate) type RepositoryFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// Commit-only capability for a backend that owns the complete signed push
/// transaction. Keeping this separate lets an engine expose a real commit
/// adapter without pretending that it implements the read and conflict-feed
/// repository surface.
pub(crate) trait SyncCommitRepository: Send + Sync {
    fn commit_batch(&self, command: PushCommit) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

/// Backend-owned transaction boundaries for the complete Vault sync API.
/// Implementors must keep each read page's authorization and cursor bounds in
/// one snapshot, and each write operation's principal fence, replay checks,
/// sequence allocation, events, references, audit, and outbox in one commit.
pub(crate) trait SyncRepository: SyncCommitRepository + Send + Sync {
    fn active_device_signing_key(
        &self,
        user_id: String,
        device_id: String,
    ) -> RepositoryFuture<'_, Result<Option<String>, ApiError>>;

    /// Reads one bounded changes page from a single logical snapshot. The
    /// active session/device, Vault membership, high-watermark, retention
    /// floor and ordered event rows must agree on that snapshot. Implementors
    /// on databases whose default isolation is statement-scoped (including
    /// PostgreSQL READ COMMITTED) must select a transaction isolation level or
    /// query shape that preserves this contract. The returned cursor may
    /// advance only through events actually included in the response.
    fn read_changes_page(
        &self,
        command: ChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Reads one bounded conflict feed page from a single snapshot. The
    /// authorization recheck, high watermark and event prefix must describe
    /// the same database view, so concurrent create/resolve writes are either
    /// wholly before or wholly after the returned page.
    fn read_conflict_changes_page(
        &self,
        command: ConflictChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Reads a bounded revision or conflict history page at the paired
    /// watermarks stored in its snapshot. Authorization, snapshot validity,
    /// cursor verification, the streamed event rows and the response cursor
    /// all belong to one transaction.
    fn read_history_page(
        &self,
        command: HistoryPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Loads an existing snapshot while preserving the read-versus-purge
    /// ordering and rechecking principal and Vault access in the transaction.
    fn read_snapshot(
        &self,
        command: ReadSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Reads one immutable revision only after checking Vault access and the
    /// request-bound session/device inside the same SQLite transaction. The
    /// adapter's Vault writer fence also orders this read against final purge.
    fn read_revision(
        &self,
        command: ReadRevisionCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Captures the record and conflict watermarks, verifies that every
    /// current head points to its committed immutable revision, persists the
    /// manifest and returns its cursor in one Vault write transaction.
    fn create_snapshot(
        &self,
        command: CreateSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Resolves one conflict with the current-head check, replay handling,
    /// shared conflict sequence and audit event inside the same write
    /// transaction as the resolution update.
    fn resolve_conflict(
        &self,
        command: ResolveConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    /// Stores a verified branch, including the shared conflict sequence and
    /// any object references, with idempotency and the capability fence in
    /// one write transaction.
    fn create_conflict(
        &self,
        command: CreateConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct SqliteSyncRepository {
    pool: SqlitePool,
    instance: crate::InstanceInfo,
    signing_key: std::sync::Arc<SigningKey>,
}

#[derive(Clone)]
struct RedactionStatement {
    redaction_id: String,
    vault_id: String,
    record_id: String,
    deleted_revision_id: String,
    deleted_seq: i64,
    redaction_seq: i64,
}

impl SqliteSyncRepository {
    pub(crate) fn new(
        pool: SqlitePool,
        instance: crate::InstanceInfo,
        signing_key: std::sync::Arc<SigningKey>,
    ) -> Self {
        Self {
            pool,
            instance,
            signing_key,
        }
    }

    fn redaction_proof(&self, statement: &RedactionStatement) -> Result<Value, ApiError> {
        for id in [
            &self.instance.instance_id,
            &self.instance.server_space_id,
            &statement.vault_id,
            &statement.record_id,
            &statement.deleted_revision_id,
            &statement.redaction_id,
        ] {
            let parsed = Uuid::parse_str(id).map_err(ApiError::internal)?;
            if parsed.to_string() != *id {
                return Err(ApiError::internal("redaction identifier is not canonical"));
            }
        }
        if statement.deleted_seq <= 0 || statement.redaction_seq <= statement.deleted_seq {
            return Err(ApiError::internal("redaction sequence is invalid"));
        }
        let current_public_key =
            URL_SAFE_NO_PAD.encode(self.signing_key.verifying_key().as_bytes());
        if current_public_key != self.instance.signing_public_key {
            return Err(ApiError::internal(
                "instance signing identity does not match the active signing key",
            ));
        }
        let mut unsigned = json!({
            "format": "atermius-record-redaction-proof-v1",
            "redaction_id": statement.redaction_id,
            "instance_id": self.instance.instance_id,
            "server_space_id": self.instance.server_space_id,
            "vault_id": statement.vault_id,
            "record_id": statement.record_id,
            "deleted_revision_id": statement.deleted_revision_id,
            "deleted_seq": statement.deleted_seq.to_string(),
            "redaction_seq": statement.redaction_seq.to_string(),
            "signing_public_key": self.instance.signing_public_key,
        });
        let signature = self.signing_key.sign(&crate::jcs(&unsigned)?);
        unsigned["signature"] = json!(URL_SAFE_NO_PAD.encode(signature.to_bytes()));
        Ok(unsigned)
    }

    fn redaction_from_join_row(row: &SqliteRow) -> Result<Option<RedactionStatement>, ApiError> {
        let Some(redaction_id) = row
            .try_get::<Option<String>, _>("rr_redaction_id")
            .map_err(ApiError::internal)?
        else {
            return Ok(None);
        };
        Ok(Some(RedactionStatement {
            redaction_id,
            vault_id: row
                .try_get::<Option<String>, _>("rr_vault_id")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
            record_id: row
                .try_get::<Option<String>, _>("rr_record_id")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
            deleted_revision_id: row
                .try_get::<Option<String>, _>("rr_deleted_revision_id")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
            deleted_seq: row
                .try_get::<Option<i64>, _>("rr_deleted_seq")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
            redaction_seq: row
                .try_get::<Option<i64>, _>("rr_redaction_seq")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("redaction statement is incomplete"))?,
        }))
    }

    fn redaction_from_row(row: &SqliteRow) -> Result<RedactionStatement, ApiError> {
        Ok(RedactionStatement {
            redaction_id: row.try_get("redaction_id").map_err(ApiError::internal)?,
            vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
            record_id: row.try_get("record_id").map_err(ApiError::internal)?,
            deleted_revision_id: row
                .try_get("deleted_revision_id")
                .map_err(ApiError::internal)?,
            deleted_seq: row.try_get("deleted_seq").map_err(ApiError::internal)?,
            redaction_seq: row.try_get("redaction_seq").map_err(ApiError::internal)?,
        })
    }

    fn graveyard_snapshot_item(&self, statement: &RedactionStatement) -> Result<Value, ApiError> {
        Ok(json!({
            "kind": "graveyard",
            "record_id": statement.record_id,
            "deleted_revision_id": statement.deleted_revision_id,
            "deleted_seq": statement.deleted_seq.to_string(),
            "redaction": self.redaction_proof(statement)?,
        }))
    }

    fn materialize_snapshot_item(&self, row: &SqliteRow) -> Result<Value, ApiError> {
        let item_json: String = row.try_get("item_json").map_err(ApiError::internal)?;
        let item = serde_json::from_str::<Value>(&item_json).map_err(ApiError::internal)?;
        if let Some(statement) = Self::redaction_from_join_row(row)? {
            return self.graveyard_snapshot_item(&statement);
        }
        if item.get("kind").and_then(Value::as_str) == Some("graveyard") {
            return Err(ApiError::internal(
                "snapshot graveyard item has no redaction statement",
            ));
        }
        Ok(item)
    }

    fn redaction_columns(alias: &str) -> String {
        format!(
            "{alias}.redaction_id AS rr_redaction_id,{alias}.vault_id AS rr_vault_id,\
             {alias}.record_id AS rr_record_id,{alias}.deleted_revision_id AS rr_deleted_revision_id,\
             {alias}.deleted_seq AS rr_deleted_seq,{alias}.redaction_seq AS rr_redaction_seq"
        )
    }

    async fn reject_redacted_record_tx(
        tx: &mut sqlx::Transaction<'_, Sqlite>,
        vault_id: &str,
        record_id: &str,
    ) -> Result<(), ApiError> {
        let redacted: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=? AND record_id=?)",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if redacted {
            return Err(ApiError::conflict(
                "RECORD_REDACTED",
                "record ID is permanently reserved by a redaction",
            ));
        }
        Ok(())
    }

    async fn commit_batch_sqlite(&self, command: PushCommit) -> Result<Value, ApiError> {
        let PushCommit {
            user,
            vault_id,
            device_id,
            batch_id,
            request_digest,
            operations,
            restore_retention_days,
        } = command;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        // SQLite serializes writers database-wide. Reserve that writer before
        // reading heads so CAS and sequence allocation have one order.
        sqlx::query(
            "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
        )
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let (_, active_epoch, membership_version) =
            crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
        // Reject every operation in the batch before receipt replay. A stale
        // exact retry must not be acknowledged as writable after its record
        // has been permanently redacted.
        for item in &operations {
            Self::reject_redacted_record_tx(&mut tx, &vault_id, &item.record_id).await?;
        }
        if operations.iter().any(|item| item.record_schema >= 2) {
            if !crate::device_capabilities::all_active_vault_devices_support_v2_tx(
                &mut tx, &vault_id,
            )
            .await?
            {
                return Err(ApiError::conflict(
                    "VAULT_CLIENT_CAPABILITY_REQUIRED",
                    "all active devices of active vault members must support schema 2, attachment manifest v2, and 1 GiB attachments",
                ));
            }
            sqlx::query("UPDATE vaults SET required_record_schema=2 WHERE vault_id=? AND required_record_schema<2")
                .bind(&vault_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }

        if let Some((old_digest, response)) = sqlx::query_as::<_, (String, String)>(
            "SELECT request_digest,response_json FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&batch_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        {
            if old_digest != request_digest {
                return Err(ApiError::conflict(
                    "IDEMPOTENCY_KEY_REUSED",
                    "batch id was reused with a different request",
                ));
            }
            tx.commit().await.map_err(ApiError::internal)?;
            let mut value: Value =
                serde_json::from_str(&response).map_err(ApiError::internal)?;
            if let Some(results) = value.get_mut("results").and_then(Value::as_array_mut) {
                for result in results {
                    result["already_committed"] = Value::Bool(true);
                }
            }
            return Ok(value);
        }

        let mut results = Vec::new();
        let mut newly_committed = 0usize;
        for item in operations {
            let envelope_text = serde_json::to_string(&item.env).map_err(ApiError::internal)?;
            let operation_digest = crate::sha256_hex(&crate::jcs(&item.env)?);

            if let Some(row) = sqlx::query(
                "SELECT request_digest,revision_id,commit_seq FROM op_receipts WHERE vault_id=? AND op_id=?",
            )
            .bind(&vault_id)
            .bind(&item.op_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            {
                let previous: String = row.get("request_digest");
                if previous != operation_digest {
                    return Err(ApiError::conflict(
                        "IDEMPOTENCY_KEY_REUSED",
                        "operation id was reused with different content",
                    ));
                }
                results.push(CommitResult {
                    op_id: item.op_id,
                    revision_id: row.get("revision_id"),
                    commit_seq: row.get::<i64, _>("commit_seq").to_string(),
                    already_committed: true,
                });
                continue;
            }

            if let Some(row) = sqlx::query(
                "SELECT request_digest FROM op_receipts WHERE vault_id=? AND device_id=? AND device_seq=?",
            )
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&item.device_seq)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            {
                let prior: String = row.get("request_digest");
                if prior != operation_digest {
                    return Err(ApiError::conflict(
                        "IDEMPOTENCY_KEY_REUSED",
                        "device sequence was reused with different content",
                    ));
                }
            }

            if item.key_epoch != active_epoch {
                return Err(ApiError::conflict(
                    "KEY_EPOCH_OUTDATED",
                    "record was encrypted for an inactive key epoch",
                ));
            }
            if item.membership_version != membership_version {
                return Err(ApiError::conflict(
                    "MEMBERSHIP_VERSION_CONFLICT",
                    "record was encrypted for an outdated membership version",
                ));
            }

            let head = sqlx::query(
                "SELECT revision_id,deleted FROM record_heads WHERE vault_id=? AND record_id=?",
            )
            .bind(&vault_id)
            .bind(&item.record_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let grave: Option<String> = sqlx::query_scalar(
                "SELECT deleted_revision FROM record_graveyard WHERE vault_id=? AND record_id=?",
            )
            .bind(&vault_id)
            .bind(&item.record_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let current = head.as_ref().map(|row| {
                (
                    row.get::<String, _>("revision_id"),
                    row.get::<i64, _>("deleted") != 0,
                )
            });

            match (
                item.operation.as_str(),
                current.as_ref(),
                item.base.as_deref(),
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
                        &item.record_id,
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
                        &item.record_id,
                        head.as_ref(),
                        user.declares_record_schema2,
                    )
                    .await?);
                }
            }

            if item.operation == "restore" {
                let restore_until: Option<String> = sqlx::query_scalar(
                    "SELECT restore_until FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=? AND operation='delete'",
                )
                .bind(&vault_id)
                .bind(&item.record_id)
                .bind(current.as_ref().map(|(revision, _)| revision))
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                let Some(restore_until) = restore_until else {
                    return Err(ApiError::internal(
                        "current tombstone restore deadline is missing",
                    ));
                };
                let restore_until = chrono::DateTime::parse_from_rfc3339(&restore_until)
                    .map_err(ApiError::internal)?
                    .with_timezone(&chrono::Utc);
                if crate::sync::restore_deadline_elapsed(chrono::Utc::now(), restore_until) {
                    return Err(crate::sync::record_restore_expired(
                        restore_retention_days,
                        Some(&restore_until.to_rfc3339()),
                    ));
                }
            }

            // Revision IDs are addressed by Vault + revision ID in the read
            // API, so they must be unique across the entire Vault. Keeping
            // this business check distinct ensures a commit sequence UNIQUE
            // failure still signals an internal sequence-integrity error.
            let revision_exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_versions WHERE vault_id=? AND revision_id=?)",
            )
            .bind(&vault_id)
            .bind(&item.revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if revision_exists {
                return Err(ApiError::conflict(
                    "REVISION_EXISTS",
                    "revision identifier has already been used",
                ));
            }

            persist_object_references_tx(&mut tx, &vault_id, &item.revision_id, &item.object_refs)
                .await?;
            let sequence: i64 = sqlx::query_scalar(
                "UPDATE vault_counters SET last_committed_seq=last_committed_seq+1 WHERE vault_id=? RETURNING last_committed_seq",
            )
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let deleted = (item.operation == "delete") as i64;
            let created_at = now_rfc3339();
            let restore_until = if item.operation == "delete" {
                let deleted_at = chrono::DateTime::parse_from_rfc3339(&created_at)
                    .map_err(ApiError::internal)?
                    .with_timezone(&chrono::Utc);
                Some((deleted_at + chrono::Duration::days(restore_retention_days)).to_rfc3339())
            } else {
                None
            };
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at,restore_until) VALUES(?,?,?,?,?,?,?,?,?,?,?)")
                .bind(&vault_id)
                .bind(&item.record_id)
                .bind(&item.revision_id)
                .bind(&item.base)
                .bind(&envelope_text)
                .bind(&operation_digest)
                .bind(sequence)
                .bind(&device_id)
                .bind(&item.operation)
                .bind(&created_at)
                .bind(&restore_until)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,?,?) ON CONFLICT(vault_id,record_id) DO UPDATE SET revision_id=excluded.revision_id,deleted=excluded.deleted,commit_seq=excluded.commit_seq")
                .bind(&vault_id)
                .bind(&item.record_id)
                .bind(&item.revision_id)
                .bind(deleted)
                .bind(sequence)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            if item.operation == "delete" {
                sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq,auto_purge_enabled,auto_purge_revision) VALUES(?,?,?, ?,0,0) ON CONFLICT(vault_id,record_id) DO UPDATE SET deleted_revision=excluded.deleted_revision,deleted_seq=excluded.deleted_seq,auto_purge_enabled=0,auto_purge_revision=0")
                    .bind(&vault_id)
                    .bind(&item.record_id)
                    .bind(&item.revision_id)
                    .bind(sequence)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            if item.operation == "restore" {
                sqlx::query("DELETE FROM record_graveyard WHERE vault_id=? AND record_id=?")
                    .bind(&vault_id)
                    .bind(&item.record_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,?,?,?,?,?,?)")
                .bind(&vault_id)
                .bind(sequence)
                .bind(&item.operation)
                .bind(&item.record_id)
                .bind(&item.revision_id)
                .bind(&envelope_text)
                .bind(&created_at)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) VALUES(?,?,?,?,?,?,?,?)")
                .bind(&vault_id)
                .bind(&item.op_id)
                .bind(&device_id)
                .bind(&item.device_seq)
                .bind(&operation_digest)
                .bind(&item.record_id)
                .bind(&item.revision_id)
                .bind(sequence)
                .execute(&mut *tx)
                .await
                .map_err(|error| {
                    unique_violation_or_internal(
                        error,
                        "IDEMPOTENCY_KEY_REUSED",
                        "operation or device sequence is already committed",
                    )
                })?;
            newly_committed += 1;
            results.push(CommitResult {
                op_id: item.op_id,
                revision_id: item.revision_id,
                commit_seq: sequence.to_string(),
                already_committed: false,
            });
        }

        if newly_committed > 0 {
            crate::mobile_push::enqueue_sync_available_tx(
                &mut tx,
                &vault_id,
                &device_id,
                chrono::Utc::now().timestamp(),
            )
            .await?;
            crate::audit::record_vault_event_tx(
                &mut tx,
                &vault_id,
                Some(&user.user_id),
                Some(&user.device_id),
                "vault.sync_batch_committed",
                "sync_batch",
                None,
                crate::audit::AuditSource::Api,
                chrono::Utc::now().timestamp(),
            )
            .await?;
        }

        let response = json!({"batch_id":batch_id,"results":results});
        sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES(?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&batch_id)
            .bind(&request_digest)
            .bind(response.to_string())
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    async fn read_changes_page_sqlite(
        &self,
        command: ChangesPageCommand,
    ) -> Result<Value, ApiError> {
        #[cfg(test)]
        let test_pause = command.test_pause.clone();
        let ChangesPageCommand {
            user,
            vault_id,
            raw_cursor,
            limit,
            cursor_key,
            generation,
            ..
        } = command;
        // Keep the storage boundary safe if another internal caller is added;
        // SQLite treats LIMIT -1 as unbounded.
        let limit = limit.clamp(1, 500);

        // Keep authorization, sequence bounds, retention floor and page rows
        // in one SQLite snapshot. Otherwise compaction can delete an event
        // prefix after the floor check but before the page query, letting the
        // cursor jump past events that were never returned.
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_active_session_device_read_tx(&mut tx, &user).await?;
        let member: Option<i64> = sqlx::query_scalar(
            "SELECT 1 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active'",
        )
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if member.is_none() {
            return Err(ApiError::not_found());
        }
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &vault_id,
            user.declares_sync_redaction_v1,
        )
        .await?;
        // Parse after membership so malformed and recovery-only cursors do
        // not reveal anything about a Vault the caller cannot read.
        let after = match raw_cursor {
            Some(cursor) => parse_cursor_with_key(&cursor_key, &generation, &vault_id, &cursor)?,
            None => 0,
        };
        let high: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if after > high {
            return Err(ApiError::gone(
                "CURSOR_EXPIRED",
                "cursor points beyond the current history",
            ));
        }
        let minimum_available: i64 =
            sqlx::query_scalar("SELECT minimum_available_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if cursor_is_expired(after, minimum_available) {
            return Err(ApiError::gone(
                "CURSOR_EXPIRED",
                "change history before this cursor has expired; create a fresh snapshot",
            )
            .with_details(json!({"recovery":"create_snapshot","preserve_local_outbox":true})));
        }
        // Deterministically exercise a read snapshot while retention commits a
        // newer floor and deletes the old prefix. Production calls never
        // install this gate.
        #[cfg(test)]
        if let Some(pause) = test_pause.as_ref() {
            pause.pause().await;
        }
        let redaction_columns = Self::redaction_columns("rr");
        let rows_sql = format!(
            "SELECT ce.commit_seq,ce.event_type,ce.record_id,ce.revision_id,ce.envelope,{redaction_columns} \
             FROM change_events ce LEFT JOIN record_redactions rr \
               ON rr.vault_id=ce.vault_id AND rr.record_id=ce.record_id \
             WHERE ce.vault_id=? AND ce.commit_seq>? AND ce.commit_seq<=? \
             ORDER BY ce.commit_seq LIMIT ?"
        );
        let mut rows = sqlx::query(&rows_sql)
            .bind(&vault_id)
            .bind(after)
            .bind(high)
            .bind(limit + 1)
            .fetch(&mut *tx);
        let mut events = Vec::new();
        let mut budget = SyncPageBudget::default();
        let mut has_more = false;
        let mut last_seq = after;
        while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
            if events.len() >= limit as usize {
                has_more = true;
                break;
            }
            let statement = Self::redaction_from_join_row(&row)?;
            let event = if let Some(statement) = statement.as_ref() {
                json!({
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "event_type": "record_redacted",
                    "record_id": row.get::<String, _>("record_id"),
                    "redaction": self.redaction_proof(statement)?,
                })
            } else {
                let event = json!({
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "event_type": row.get::<String, _>("event_type"),
                    "record_id": row.get::<String, _>("record_id"),
                    "revision_id": row.get::<String, _>("revision_id"),
                    "envelope": serde_json::from_str::<Value>(&row.get::<String, _>("envelope"))
                        .map_err(ApiError::internal)?,
                });
                ensure_envelope_readable(user.declares_record_schema2, &event["envelope"])?;
                event
            };
            if !budget.try_add(&event)? {
                if events.is_empty() {
                    return Err(sync_page_item_too_large());
                }
                has_more = true;
                break;
            }
            last_seq = row.get("commit_seq");
            events.push(event);
        }
        drop(rows);
        let response = json!({
            "events": events,
            "next_cursor": encode_cursor_with_key(&cursor_key, &generation, &vault_id, last_seq)?,
            "has_more": has_more,
            "server_generation": generation,
        });
        ensure_sync_page_response_fits(&response)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    async fn read_conflict_changes_page_sqlite(
        &self,
        command: ConflictChangesPageCommand,
    ) -> Result<Value, ApiError> {
        #[cfg(test)]
        let test_pause = command.test_pause.clone();
        let ConflictChangesPageCommand {
            user,
            vault_id,
            after_seq,
            after_seq_wire,
            limit,
            server_generation,
            generation,
            ..
        } = command;
        let limit = limit.clamp(1, 500);
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_active_session_device_read_tx(&mut tx, &user).await?;
        crate::require_vault_read_snapshot_tx(&mut tx, &user.user_id, &vault_id).await?;
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &vault_id,
            user.declares_sync_redaction_v1,
        )
        .await?;

        if server_generation
            .as_deref()
            .is_some_and(|checkpoint| checkpoint != generation)
        {
            return Err(ApiError::gone(
                "CONFLICT_FEED_GENERATION_CHANGED",
                "conflict feed checkpoint belongs to another server generation",
            )
            .with_details(json!({
                "server_generation": server_generation,
                "current_generation": generation,
                "recovery": "restart_from_zero",
            })));
        }

        let high_watermark: i64 =
            sqlx::query_scalar("SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if after_seq > high_watermark {
            return Err(ApiError::gone(
                "CONFLICT_FEED_SEQUENCE_AHEAD",
                "after_seq is beyond the current conflict feed high watermark",
            )
            .with_details(json!({"recovery":"restart_from_zero"})));
        }

        #[cfg(test)]
        if let Some(pause) = test_pause.as_ref() {
            pause.pause().await;
        }

        let redaction_columns = Self::redaction_columns("rr");
        let rows_sql = format!(
            "SELECT feed.seq,feed.event_type,feed.conflict_id,feed.record_id,feed.base_revision_id,\
                    feed.resolved_revision_id,feed.created_at,feed.envelope,{redaction_columns} \
             FROM (\
               SELECT vault_id,conflict_seq AS seq,'created' AS event_type,conflict_id,record_id,base_revision_id,\
                      NULL AS resolved_revision_id,created_at,envelope \
               FROM conflicts WHERE vault_id=? AND conflict_seq>? AND conflict_seq<=? \
               UNION ALL \
               SELECT vault_id,resolution_seq AS seq,'resolved' AS event_type,conflict_id,record_id,base_revision_id,\
                      resolved_revision_id,resolution_at AS created_at,NULL AS envelope \
               FROM conflicts WHERE vault_id=? AND resolution_seq>? AND resolution_seq<=? \
             ) feed LEFT JOIN record_redactions rr ON rr.vault_id=feed.vault_id AND rr.record_id=feed.record_id \
             ORDER BY feed.seq ASC LIMIT ?"
        );
        let mut rows = sqlx::query(&rows_sql)
            .bind(&vault_id)
            .bind(after_seq)
            .bind(high_watermark)
            .bind(&vault_id)
            .bind(after_seq)
            .bind(high_watermark)
            .bind(limit + 1)
            .fetch(&mut *tx);
        let mut events = Vec::new();
        let mut budget = SyncPageBudget::default();
        let mut has_more = false;
        let mut next_after_seq = after_seq;
        while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
            if events.len() >= limit as usize {
                has_more = true;
                break;
            }
            let event_type: String = row.get("event_type");
            let is_created = event_type == "created";
            let statement = Self::redaction_from_join_row(&row)?;
            let event = if let Some(statement) = statement.as_ref() {
                json!({
                    "seq": row.get::<i64, _>("seq").to_string(),
                    "type": "redacted",
                    "conflict_id": row.get::<String, _>("conflict_id"),
                    "record_id": row.get::<String, _>("record_id"),
                    "redaction": self.redaction_proof(statement)?,
                })
            } else {
                let mut event = json!({
                    "seq": row.get::<i64, _>("seq").to_string(),
                    "type": event_type,
                    "conflict_id": row.get::<String, _>("conflict_id"),
                    "record_id": row.get::<String, _>("record_id"),
                    "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                    "resolved_revision_id": row.get::<Option<String>, _>("resolved_revision_id"),
                    "created_at": row.get::<String, _>("created_at"),
                });
                if is_created {
                    let encoded: String = row.get("envelope");
                    let envelope =
                        serde_json::from_str::<Value>(&encoded).map_err(ApiError::internal)?;
                    ensure_envelope_readable(user.declares_record_schema2, &envelope)?;
                    event["envelope"] = envelope;
                }
                event
            };
            if !budget.try_add(&event)? {
                if events.is_empty() {
                    return Err(sync_page_item_too_large());
                }
                has_more = true;
                break;
            }
            next_after_seq = row.get("seq");
            events.push(event);
        }
        drop(rows);
        let response = json!({
            "vault_id": vault_id,
            "after_seq": after_seq_wire,
            "high_watermark": high_watermark.to_string(),
            "events": events,
            "next_after_seq": next_after_seq.to_string(),
            "has_more": has_more,
            "server_generation": generation,
        });
        ensure_sync_page_response_fits(&response)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    async fn read_history_page_sqlite(
        &self,
        command: HistoryPageCommand,
    ) -> Result<Value, ApiError> {
        let HistoryPageCommand {
            user,
            vault_id,
            snapshot_id,
            kind,
            raw_cursor,
            limit,
            generation,
            cursor_key,
        } = command;
        let limit = limit.clamp(1, 500);
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        // Match the established history boundary: take the Vault writer fence
        // before checking the request-bound session, then read its snapshot
        // row and all page data under the same lock. Final purge and membership
        // transitions are therefore ordered with the response.
        crate::require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
        crate::require_active_session_device_read_tx(&mut tx, &user).await?;
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &vault_id,
            user.declares_sync_redaction_v1,
        )
        .await?;
        let row = sqlx::query(
            "SELECT high_watermark,conflict_high_watermark,expires_at,server_generation,redacted_at FROM snapshots WHERE snapshot_id=? AND vault_id=?",
        )
        .bind(&snapshot_id)
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(row) = row else {
            if raw_cursor.as_deref().is_some_and(|cursor| {
                foreign_generation_history_cursor_claim(
                    cursor,
                    kind,
                    &vault_id,
                    &snapshot_id,
                    &generation,
                )
            }) {
                return Err(ApiError::gone(
                    "HISTORY_CURSOR_EXPIRED",
                    "history cursor belongs to a previous server generation; create a new snapshot",
                )
                .with_details(json!({"recovery":"create_new_snapshot"})));
            }
            return Err(ApiError::not_found());
        };
        let snapshot_high: i64 = row.get("high_watermark");
        let post_snapshot_redaction: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=? AND redaction_seq>?)",
        )
        .bind(&vault_id)
        .bind(snapshot_high)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if row.get::<Option<String>, _>("redacted_at").is_some() || post_snapshot_redaction {
            return Err(ApiError::gone(
                "SNAPSHOT_REDACTED",
                "snapshot was invalidated because it contains a redacted record",
            ));
        }
        let expires_at: String = row.get("expires_at");
        let expired = chrono::DateTime::parse_from_rfc3339(&expires_at)
            .map_or(true, |time| time <= chrono::Utc::now());
        let snapshot_generation: String = row.get("server_generation");
        if expired || snapshot_generation != generation {
            return Err(ApiError::gone(
                "SNAPSHOT_EXPIRED",
                "history snapshot has expired or belongs to a previous server generation",
            ));
        }
        let conflicts: Option<i64> = row.get("conflict_high_watermark");
        let Some(conflicts) = conflicts else {
            return Err(ApiError::conflict(
                "HISTORY_SNAPSHOT_INCOMPLETE",
                "create a new snapshot to read a consistent history export",
            )
            .with_details(json!({"recovery":"create_new_snapshot"})));
        };
        let bounds = HistoryBounds {
            revisions: row.get("high_watermark"),
            conflicts,
        };
        // Bounds and Vault authorization are established before cursor parsing
        // so recovery and malformed-cursor errors do not disclose snapshot
        // state to a caller without access.
        let after = match raw_cursor.as_deref() {
            Some(value) => parse_history_cursor(
                &cursor_key,
                &generation,
                kind,
                &vault_id,
                &snapshot_id,
                bounds,
                value,
            )?,
            None => 0,
        };

        match kind {
            HistoryKind::Revisions => {
                let redaction_columns = Self::redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT v.record_id,v.revision_id,v.base_revision_id,v.commit_seq,v.operation,v.created_at,v.restore_until,v.envelope, \
                            g.auto_purge_enabled AS auto_purge_enabled,g.auto_purge_revision AS auto_purge_revision,{redaction_columns} \
                     FROM record_versions v LEFT JOIN record_redactions rr \
                       ON rr.vault_id=v.vault_id AND rr.record_id=v.record_id \
                     LEFT JOIN record_graveyard g ON g.vault_id=v.vault_id AND g.record_id=v.record_id \
                       AND g.deleted_revision=v.revision_id AND g.deleted_seq=v.commit_seq \
                     WHERE v.vault_id=? AND v.commit_seq>? AND v.commit_seq<=? \
                     ORDER BY v.commit_seq ASC LIMIT ?"
                );
                let mut rows = sqlx::query(&rows_sql)
                    .bind(&vault_id)
                    .bind(after)
                    .bind(bounds.revisions)
                    .bind(limit + 1)
                    .fetch(&mut *tx);
                let mut revisions = Vec::new();
                let mut budget = SyncPageBudget::default();
                let mut has_more = false;
                let mut next_after = after;
                while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
                    if revisions.len() >= limit as usize {
                        has_more = true;
                        break;
                    }
                    let operation: String = row.get("operation");
                    let statement = Self::redaction_from_join_row(&row)?;
                    let event = if let Some(statement) = statement.as_ref() {
                        json!({
                            "record_id": row.get::<String, _>("record_id"),
                            "revision_id": row.get::<String, _>("revision_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                            "operation": "redacted",
                            "deleted": operation == "delete",
                            "created_at": row.get::<String, _>("created_at"),
                            "restore_until": Value::Null,
                            "envelope": Value::Null,
                            "redaction": self.redaction_proof(statement)?,
                        })
                    } else {
                        let restore_until: Option<String> = row.get("restore_until");
                        if operation == "delete" && restore_until.is_none() {
                            return Err(ApiError::internal(
                                "delete revision restore deadline is missing",
                            ));
                        }
                        let mut event = json!({
                            "record_id": row.get::<String, _>("record_id"),
                            "revision_id": row.get::<String, _>("revision_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                            "operation": operation,
                            "deleted": operation == "delete",
                            "created_at": row.get::<String, _>("created_at"),
                            "restore_until": restore_until,
                            "envelope": serde_json::from_str::<Value>(&row.get::<String, _>("envelope"))
                                .map_err(ApiError::internal)?,
                        });
                        if operation == "delete" {
                            let auto_purge_enabled: Option<i64> = row
                                .try_get("auto_purge_enabled")
                                .map_err(ApiError::internal)?;
                            let auto_purge_revision: Option<i64> = row
                                .try_get("auto_purge_revision")
                                .map_err(ApiError::internal)?;
                            event["auto_purge_enabled"] =
                                json!(auto_purge_enabled.unwrap_or(0) != 0);
                            event["auto_purge_revision"] =
                                json!(auto_purge_revision.unwrap_or(0).to_string());
                        }
                        ensure_envelope_readable(user.declares_record_schema2, &event["envelope"])?;
                        event
                    };
                    if !budget.try_add(&event)? {
                        if revisions.is_empty() {
                            return Err(sync_page_item_too_large());
                        }
                        has_more = true;
                        break;
                    }
                    next_after = row.get("commit_seq");
                    revisions.push(event);
                }
                drop(rows);
                let next_cursor = if has_more {
                    Some(history_cursor(
                        &generation,
                        &cursor_key,
                        kind,
                        &vault_id,
                        &snapshot_id,
                        bounds,
                        next_after,
                    )?)
                } else {
                    None
                };
                let response = json!({
                    "snapshot_id": snapshot_id,
                    "vault_id": vault_id,
                    "high_watermark": bounds.revisions.to_string(),
                    "conflict_high_watermark": bounds.conflicts.to_string(),
                    "revisions": revisions,
                    "next_cursor": next_cursor,
                    "has_more": has_more,
                    "server_generation": generation,
                });
                ensure_sync_page_response_fits(&response)?;
                tx.commit().await.map_err(ApiError::internal)?;
                Ok(response)
            }
            HistoryKind::Conflicts => {
                let redaction_columns = Self::redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT c.conflict_id,c.conflict_seq,c.record_id,c.base_revision_id,c.resolved_revision_id,c.resolution_seq,c.created_at,c.envelope,{redaction_columns} \
                     FROM conflicts c LEFT JOIN record_redactions rr \
                       ON rr.vault_id=c.vault_id AND rr.record_id=c.record_id \
                     WHERE c.vault_id=? AND c.conflict_seq>? AND c.conflict_seq<=? \
                     ORDER BY c.conflict_seq ASC LIMIT ?"
                );
                let mut rows = sqlx::query(&rows_sql)
                    .bind(&vault_id)
                    .bind(after)
                    .bind(bounds.conflicts)
                    .bind(limit + 1)
                    .fetch(&mut *tx);
                let mut conflicts_page = Vec::new();
                let mut budget = SyncPageBudget::default();
                let mut has_more = false;
                let mut next_after = after;
                while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
                    if conflicts_page.len() >= limit as usize {
                        has_more = true;
                        break;
                    }
                    let resolution_seq: Option<i64> = row.get("resolution_seq");
                    let resolved_by_watermark =
                        resolution_seq.is_some_and(|seq| seq <= bounds.conflicts);
                    let statement = Self::redaction_from_join_row(&row)?;
                    let event = if let Some(statement) = statement.as_ref() {
                        json!({
                            "conflict_id": row.get::<String, _>("conflict_id"),
                            "conflict_seq": row.get::<i64, _>("conflict_seq").to_string(),
                            "record_id": row.get::<String, _>("record_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "resolved_revision_id": Value::Null,
                            "resolution_seq": if resolved_by_watermark { resolution_seq.map(|seq| seq.to_string()) } else { None },
                            "created_at": row.get::<String, _>("created_at"),
                            "envelope": Value::Null,
                            "redaction": self.redaction_proof(statement)?,
                        })
                    } else {
                        let event = json!({
                            "conflict_id": row.get::<String, _>("conflict_id"),
                            "conflict_seq": row.get::<i64, _>("conflict_seq").to_string(),
                            "record_id": row.get::<String, _>("record_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "resolved_revision_id": if resolved_by_watermark { row.get::<Option<String>, _>("resolved_revision_id") } else { None },
                            "resolution_seq": if resolved_by_watermark { resolution_seq.map(|seq| seq.to_string()) } else { None },
                            "created_at": row.get::<String, _>("created_at"),
                            "envelope": serde_json::from_str::<Value>(&row.get::<String, _>("envelope"))
                                .map_err(ApiError::internal)?,
                        });
                        ensure_envelope_readable(user.declares_record_schema2, &event["envelope"])?;
                        event
                    };
                    if !budget.try_add(&event)? {
                        if conflicts_page.is_empty() {
                            return Err(sync_page_item_too_large());
                        }
                        has_more = true;
                        break;
                    }
                    next_after = row.get("conflict_seq");
                    conflicts_page.push(event);
                }
                drop(rows);
                let next_cursor = if has_more {
                    Some(history_cursor(
                        &generation,
                        &cursor_key,
                        kind,
                        &vault_id,
                        &snapshot_id,
                        bounds,
                        next_after,
                    )?)
                } else {
                    None
                };
                let response = json!({
                    "snapshot_id": snapshot_id,
                    "vault_id": vault_id,
                    "high_watermark": bounds.revisions.to_string(),
                    "conflict_high_watermark": bounds.conflicts.to_string(),
                    "conflicts": conflicts_page,
                    "next_cursor": next_cursor,
                    "has_more": has_more,
                    "server_generation": generation,
                });
                ensure_sync_page_response_fits(&response)?;
                tx.commit().await.map_err(ApiError::internal)?;
                Ok(response)
            }
        }
    }

    async fn read_revision_sqlite(&self, command: ReadRevisionCommand) -> Result<Value, ApiError> {
        let ReadRevisionCommand {
            user,
            vault_id,
            revision_id,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
        crate::require_active_session_device_read_tx(&mut tx, &user).await?;
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &vault_id,
            user.declares_sync_redaction_v1,
        )
        .await?;
        let redaction_columns = Self::redaction_columns("rr");
        let mut rows = sqlx::query(&format!(
            "SELECT v.envelope,v.record_id,v.digest,v.commit_seq,{redaction_columns} \
             FROM record_versions v LEFT JOIN record_redactions rr \
               ON rr.vault_id=v.vault_id AND rr.record_id=v.record_id \
             WHERE v.vault_id=? AND v.revision_id=? LIMIT 2"
        ))
        .bind(&vault_id)
        .bind(&revision_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        // Revision IDs are not unique across records in legacy storage. Always
        // consult the durable redaction index before returning a live payload:
        // a scrubbed record and a different live record may share the ID.
        let redaction_columns = Self::redaction_columns("rr");
        let mut redacted_rows = sqlx::query(&format!(
            "SELECT {redaction_columns} \
             FROM record_redacted_revisions ri JOIN record_redactions rr \
               ON rr.vault_id=ri.vault_id AND rr.record_id=ri.record_id \
             WHERE ri.vault_id=? AND ri.revision_id=? LIMIT 2"
        ))
        .bind(&vault_id)
        .bind(&revision_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        if rows.len() > 1 {
            return Err(ApiError::internal(
                "revision identifier is ambiguous within this Vault",
            ));
        }
        if redacted_rows.len() > 1 {
            return Err(ApiError::internal(
                "redacted revision identifier is ambiguous within this Vault",
            ));
        }

        let version_row = rows.pop();
        if let Some(indexed_row) = redacted_rows.pop() {
            let statement = Self::redaction_from_join_row(&indexed_row)?
                .ok_or_else(|| ApiError::internal("redacted revision mapping is incomplete"))?;
            if version_row
                .as_ref()
                .is_some_and(|row| row.get::<String, _>("record_id") != statement.record_id)
            {
                return Err(ApiError::internal(
                    "revision identifier is ambiguous between live and redacted records",
                ));
            }
            let proof = self.redaction_proof(&statement)?;
            return Err(ApiError::gone(
                "RECORD_REDACTED",
                "the requested revision belongs to a redacted record",
            )
            .with_details(json!({"redaction":proof})));
        }

        let Some(row) = version_row else {
            let row = sqlx::query(
                "SELECT redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq \
                 FROM record_redactions WHERE vault_id=? AND deleted_revision_id=?",
            )
            .bind(&vault_id)
            .bind(&revision_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
            let proof = self.redaction_proof(&Self::redaction_from_row(&row)?)?;
            return Err(ApiError::gone(
                "RECORD_REDACTED",
                "the requested revision belongs to a redacted record",
            )
            .with_details(json!({"redaction":proof})));
        };
        if let Some(statement) = Self::redaction_from_join_row(&row)? {
            let proof = self.redaction_proof(&statement)?;
            return Err(ApiError::gone(
                "RECORD_REDACTED",
                "the requested revision belongs to a redacted record",
            )
            .with_details(json!({"redaction":proof})));
        }
        let envelope = serde_json::from_str::<Value>(&row.get::<String, _>("envelope"))
            .map_err(ApiError::internal)?;
        ensure_envelope_readable(user.declares_record_schema2, &envelope)?;
        let response = json!({
            "record_id": row.get::<String, _>("record_id"),
            "envelope": envelope,
            "digest": row.get::<String, _>("digest"),
            "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
        });
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    async fn read_snapshot_sqlite(&self, command: ReadSnapshotCommand) -> Result<Value, ApiError> {
        let ReadSnapshotCommand {
            user,
            snapshot_id,
            generation,
            cursor_key,
            page,
        } = command;
        // Snapshot IDs are globally unique and immutable. This lookup only
        // discovers the Vault needed for the transactional authorization
        // fence; the row is read again under that fence before any data is
        // returned.
        let snapshot_vault: String =
            sqlx::query_scalar("SELECT vault_id FROM snapshots WHERE snapshot_id=?")
                .bind(&snapshot_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(ApiError::internal)?
                .ok_or_else(ApiError::not_found)?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        // The no-op write lock is intentional: snapshot reads during the
        // Vault deletion grace period must be ordered before final purge.
        crate::require_vault_read_tx(&mut tx, &user.user_id, &snapshot_vault).await?;
        crate::require_active_session_device_read_tx(&mut tx, &user).await?;
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &snapshot_vault,
            user.declares_sync_redaction_v1,
        )
        .await?;
        let row = sqlx::query(
            "SELECT snapshot_id,vault_id,high_watermark,conflict_high_watermark,snapshot_item_count,snapshot_manifest_format,expires_at,server_generation,redacted_at FROM snapshots WHERE snapshot_id=? AND vault_id=?",
        )
        .bind(&snapshot_id)
        .bind(&snapshot_vault)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let snapshot_high: i64 = row.get("high_watermark");
        let post_snapshot_redaction: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=? AND redaction_seq>?)",
        )
        .bind(&snapshot_vault)
        .bind(snapshot_high)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if row.get::<Option<String>, _>("redacted_at").is_some() || post_snapshot_redaction {
            return Err(ApiError::gone(
                "SNAPSHOT_REDACTED",
                "snapshot was invalidated because it contains a redacted record",
            ));
        }
        let snapshot_generation: String = row.get("server_generation");
        if snapshot_generation != generation {
            return Err(ApiError::gone(
                "SNAPSHOT_EXPIRED",
                "snapshot belongs to a previous server generation",
            )
            .with_details(json!({"recovery":"create_snapshot","preserve_local_outbox":true})));
        }
        let expiry: String = row.get("expires_at");
        if chrono::DateTime::parse_from_rfc3339(&expiry)
            .map_or(true, |date| date <= chrono::Utc::now())
        {
            return Err(ApiError::gone("SNAPSHOT_EXPIRED", "snapshot has expired")
                .with_details(json!({"recovery":"create_snapshot","preserve_local_outbox":true})));
        }
        let high_watermark: i64 = row.get("high_watermark");
        let conflict_high_watermark: Option<i64> = row.get("conflict_high_watermark");
        let snapshot_item_count: i64 = row.get("snapshot_item_count");
        let snapshot_format: String = row.get("snapshot_manifest_format");
        if !matches!(snapshot_format.as_str(), "legacy" | "inline" | "paged") {
            return Err(ApiError::internal("snapshot manifest format is invalid"));
        }
        let mut response = json!({
            "snapshot_id": row.get::<String, _>("snapshot_id"),
            "server_generation": generation,
            "high_watermark": high_watermark.to_string(),
            "conflict_high_watermark": conflict_high_watermark.map(|value| value.to_string()),
            "item_count": snapshot_item_count,
            "next_cursor": encode_cursor_with_key(
                &cursor_key,
                &generation,
                &snapshot_vault,
                high_watermark,
            )?,
            "expires_at": expiry,
        });
        if let Some(page) = page {
            if !(1..=500).contains(&page.limit) {
                return Err(ApiError::bad_request(
                    "INVALID_LIMIT",
                    "snapshot page limit must be from 1 to 500",
                ));
            }
            let after_record_id = page
                .page_cursor
                .as_deref()
                .map(|cursor| {
                    parse_snapshot_page_cursor(
                        &generation,
                        &cursor_key,
                        &snapshot_vault,
                        &snapshot_id,
                        cursor,
                    )
                })
                .transpose()?;
            // snapshot_item_count is committed with the immutable item rows.
            // Use it to choose the legacy fallback without recounting the full
            // snapshot on every page. Validate the physical count once, when a
            // caller reaches the final page, so a complete traversal still
            // fails closed if the stored item set is inconsistent.
            let stored_item_count: i64 = row.get("snapshot_item_count");
            let mut manifest = Vec::new();
            let mut budget = SyncPageBudget::default();
            let mut has_more = false;
            let mut last_record_id = None;
            if stored_item_count == 0 {
                // A legacy empty snapshot or a pre-backfill malformed row can
                // have no keyset items. Do not load this payload until after
                // snapshot redaction, generation, and expiry gates pass.
                let (raw, manifest_len): (String, i64) = sqlx::query_as(
                    "SELECT manifest_json,length(CAST(manifest_json AS BLOB)) FROM snapshots WHERE snapshot_id=? AND vault_id=?",
                )
                .bind(&snapshot_id)
                .bind(&snapshot_vault)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                if manifest_len < 0 || manifest_len as usize > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES {
                    return Err(sync_snapshot_payload_too_large());
                }
                let fallback = serde_json::from_str::<Value>(&raw).map_err(ApiError::internal)?;
                let values = fallback.as_array().ok_or_else(|| {
                    ApiError::internal("stored snapshot manifest is not an array")
                })?;
                if let Some(after) = after_record_id.as_deref() {
                    let found = values
                        .iter()
                        .any(|item| item.get("record_id").and_then(Value::as_str) == Some(after));
                    if !found {
                        return Err(ApiError::bad_request(
                            "INVALID_CURSOR",
                            "snapshot page cursor is invalid",
                        ));
                    }
                }
                for item in values.iter().filter(|item| {
                    after_record_id.as_deref().is_none_or(|after| {
                        item.get("record_id")
                            .and_then(Value::as_str)
                            .is_some_and(|record_id| record_id > after)
                    })
                }) {
                    if manifest.len() >= page.limit as usize {
                        has_more = true;
                        break;
                    }
                    if let Some(envelope) = item.get("envelope") {
                        ensure_envelope_readable(user.declares_record_schema2, envelope)?;
                    }
                    if !budget.try_add(item)? {
                        if manifest.is_empty() {
                            return Err(sync_page_item_too_large());
                        }
                        has_more = true;
                        break;
                    }
                    last_record_id = item
                        .get("record_id")
                        .and_then(Value::as_str)
                        .map(str::to_owned);
                    manifest.push(item.clone());
                }
            } else {
                let redaction_columns = Self::redaction_columns("rr");
                let mut sql = format!(
                    "SELECT si.record_id,si.item_json,{redaction_columns} \
                     FROM snapshot_items si JOIN snapshots si_vault ON si_vault.snapshot_id=si.snapshot_id \
                     LEFT JOIN record_redactions rr \
                       ON rr.vault_id=si_vault.vault_id AND rr.record_id=si.record_id \
                     WHERE si.snapshot_id=?"
                );
                if after_record_id.is_some() {
                    sql.push_str(" AND si.record_id COLLATE BINARY>?");
                }
                sql.push_str(" ORDER BY si.record_id COLLATE BINARY LIMIT ?");
                let mut query = sqlx::query(&sql).bind(&snapshot_id);
                if let Some(after) = after_record_id.as_deref() {
                    query = query.bind(after);
                }
                let mut rows = query.bind(page.limit + 1).fetch(&mut *tx);
                while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
                    if manifest.len() >= page.limit as usize {
                        has_more = true;
                        break;
                    }
                    let record_id: String = row.get("record_id");
                    let item = self.materialize_snapshot_item(&row)?;
                    if let Some(envelope) = item.get("envelope") {
                        ensure_envelope_readable(user.declares_record_schema2, envelope)?;
                    }
                    if !budget.try_add(&item)? {
                        if manifest.is_empty() {
                            return Err(sync_page_item_too_large());
                        }
                        has_more = true;
                        break;
                    }
                    last_record_id = Some(record_id);
                    manifest.push(item);
                }
                drop(rows);
            }
            if !has_more {
                let actual_item_count: i64 =
                    sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=?")
                        .bind(&snapshot_id)
                        .fetch_one(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                if actual_item_count != stored_item_count {
                    return Err(ApiError::internal(
                        "snapshot item count does not match its manifest",
                    ));
                }
            }
            let next_page_cursor = if has_more {
                Some(snapshot_page_cursor(
                    &generation,
                    &cursor_key,
                    &snapshot_vault,
                    &snapshot_id,
                    last_record_id.as_deref().ok_or_else(|| {
                        ApiError::internal("snapshot page continuation has no last key")
                    })?,
                )?)
            } else {
                None
            };
            response["manifest"] = json!(manifest);
            response["has_more"] = json!(has_more);
            response["next_page_cursor"] = json!(next_page_cursor);
            ensure_sync_page_response_fits(&response)?;
        } else {
            let (item_count, item_bytes): (i64, i64) = sqlx::query_as(
                "SELECT COUNT(*),COALESCE(SUM(length(CAST(item_json AS BLOB))),0) FROM snapshot_items WHERE snapshot_id=?",
            )
            .bind(&snapshot_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if item_count != snapshot_item_count {
                return Err(ApiError::internal(
                    "snapshot item count does not match its manifest",
                ));
            }
            if item_count == 0 {
                let (raw, manifest_len): (String, i64) = sqlx::query_as(
                    "SELECT manifest_json,length(CAST(manifest_json AS BLOB)) FROM snapshots WHERE snapshot_id=? AND vault_id=?",
                )
                .bind(&snapshot_id)
                .bind(&snapshot_vault)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                if manifest_len < 0 || manifest_len as usize > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES {
                    return Err(sync_snapshot_payload_too_large());
                }
                response["manifest"] =
                    serde_json::from_str::<Value>(&raw).map_err(ApiError::internal)?;
            } else {
                let manifest_len = item_bytes
                    .saturating_add(item_count.saturating_sub(1))
                    .saturating_add(2);
                if item_bytes < 0
                    || manifest_len as usize
                        > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
                            .saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES)
                {
                    return Err(sync_snapshot_payload_too_large());
                }
                let redaction_columns = Self::redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT si.item_json,{redaction_columns} \
                     FROM snapshot_items si JOIN snapshots s ON s.snapshot_id=si.snapshot_id \
                     LEFT JOIN record_redactions rr ON rr.vault_id=s.vault_id AND rr.record_id=si.record_id \
                     WHERE si.snapshot_id=? ORDER BY si.record_id"
                );
                let mut rows = sqlx::query(&rows_sql).bind(&snapshot_id).fetch(&mut *tx);
                let mut manifest = Vec::new();
                while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
                    let item = self.materialize_snapshot_item(&row)?;
                    if let Some(envelope) = item.get("envelope") {
                        ensure_envelope_readable(user.declares_record_schema2, envelope)?;
                    }
                    manifest.push(item);
                }
                drop(rows);
                response["manifest"] = json!(manifest);
            }
            ensure_sync_snapshot_response_fits(&response)?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    async fn create_snapshot_sqlite(
        &self,
        command: CreateSnapshotCommand,
    ) -> Result<Value, ApiError> {
        let CreateSnapshotCommand {
            user,
            vault_id,
            generation,
            cursor_key,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_active_session_device_tx(&mut tx, &user).await?;
        crate::require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
        crate::require_redaction_client_for_vault_tx(
            &mut tx,
            &vault_id,
            user.declares_sync_redaction_v1,
        )
        .await?;
        sqlx::query(
            "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
        )
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let high: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let conflict_high: i64 =
            sqlx::query_scalar("SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let inconsistent_heads: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads h LEFT JOIN record_versions v ON v.vault_id=h.vault_id AND v.record_id=h.record_id AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq WHERE h.vault_id=? AND (h.commit_seq<=0 OR h.commit_seq>? OR v.revision_id IS NULL)",
        )
        .bind(&vault_id)
        .bind(high)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if inconsistent_heads != 0 {
            return Err(ApiError::internal(
                "current record head does not match its committed revision sequence",
            ));
        }
        let snapshot_id = uuid::Uuid::new_v4().to_string();
        let expires_at = (chrono::Utc::now() + chrono::Duration::hours(24)).to_rfc3339();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation,conflict_high_watermark) VALUES(?,?,?,?, '[]',?,?,?,?)")
            .bind(&snapshot_id)
            .bind(&vault_id)
            .bind(&user.user_id)
            .bind(high)
            .bind(&expires_at)
            .bind(now_rfc3339())
            .bind(&generation)
            .bind(conflict_high)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let mut manifest = Vec::new();
        let mut manifest_item_bytes = 0usize;
        let mut legacy_fits = true;
        let mut item_count = 0i64;
        let mut last_record_id: Option<String> = None;
        loop {
            let redaction_columns = Self::redaction_columns("rr");
            let mut sql = format!(
                "SELECT manifest.record_id,manifest.kind,manifest.revision_id,manifest.deleted,\
                        manifest.commit_seq,manifest.envelope,{redaction_columns} \
                 FROM (\
                   SELECT h.record_id,'head' AS kind,h.revision_id,h.deleted,h.commit_seq,v.envelope,\
                          NULL AS redaction_id,NULL AS vault_id,NULL AS redacted_record_id,\
                          NULL AS deleted_revision_id,NULL AS deleted_seq,NULL AS redaction_seq \
                   FROM record_heads h JOIN record_versions v \
                     ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                    AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
                   WHERE h.vault_id=? AND h.commit_seq<=? \
                     AND NOT EXISTS(SELECT 1 FROM record_redactions red \
                       WHERE red.vault_id=h.vault_id AND red.record_id=h.record_id) \
                   UNION ALL \
                   SELECT red.record_id,'graveyard' AS kind,red.deleted_revision_id,1,red.deleted_seq,NULL,\
                          red.redaction_id,red.vault_id,red.record_id,red.deleted_revision_id,\
                          red.deleted_seq,red.redaction_seq \
                   FROM record_redactions red WHERE red.vault_id=?\
                 ) manifest LEFT JOIN record_redactions rr \
                   ON rr.redaction_id=manifest.redaction_id \
                 WHERE 1=1"
            );
            if last_record_id.is_some() {
                sql.push_str(" AND manifest.record_id COLLATE BINARY>?");
            }
            sql.push_str(" ORDER BY manifest.record_id COLLATE BINARY LIMIT 1");
            let mut query = sqlx::query(&sql).bind(&vault_id).bind(high).bind(&vault_id);
            if let Some(last) = last_record_id.as_deref() {
                query = query.bind(last);
            }
            let Some(row) = query
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
            else {
                break;
            };
            let record_id: String = row.get("record_id");
            let kind: String = row.get("kind");
            let item = if kind == "graveyard" {
                let statement = Self::redaction_from_join_row(&row)?
                    .ok_or_else(|| ApiError::internal("snapshot graveyard row is incomplete"))?;
                json!({
                    "kind": "graveyard",
                    "record_id": statement.record_id,
                    "deleted_revision_id": statement.deleted_revision_id,
                    "deleted_seq": statement.deleted_seq.to_string(),
                })
            } else {
                let envelope = serde_json::from_str::<Value>(&row.get::<String, _>("envelope"))
                    .map_err(ApiError::internal)?;
                ensure_envelope_readable(user.declares_record_schema2, &envelope)?;
                json!({
                    "kind": "head",
                    "record_id": row.get::<String, _>("record_id"),
                    "revision_id": row.get::<String, _>("revision_id"),
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "deleted": row.get::<i64, _>("deleted") != 0,
                    "envelope": envelope,
                })
            };
            let item_json = serde_json::to_string(&item).map_err(ApiError::internal)?;
            let item_bytes = item_json.len();
            let page_item_budget = MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
                .saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES);
            if item_bytes > page_item_budget {
                return Err(sync_snapshot_payload_too_large());
            }
            sqlx::query(
                "INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES(?,?,?)",
            )
            .bind(&snapshot_id)
            .bind(&record_id)
            .bind(&item_json)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            item_count = item_count.saturating_add(1);
            let separator_bytes = usize::from(!manifest.is_empty());
            manifest_item_bytes = manifest_item_bytes
                .saturating_add(separator_bytes)
                .saturating_add(item_bytes);
            let manifest_budget = MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
                .saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES + 2);
            if legacy_fits && manifest_item_bytes <= manifest_budget {
                manifest.push(item);
            } else if legacy_fits {
                legacy_fits = false;
                manifest.clear();
            }
            last_record_id = Some(record_id);
        }
        if legacy_fits {
            let manifest_json = serde_json::to_string(&manifest).map_err(ApiError::internal)?;
            sqlx::query("UPDATE snapshots SET manifest_json=?,snapshot_item_count=?,snapshot_manifest_format='inline' WHERE snapshot_id=?")
                .bind(manifest_json)
                .bind(item_count)
                .bind(&snapshot_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        } else {
            sqlx::query("UPDATE snapshots SET snapshot_item_count=?,snapshot_manifest_format='paged' WHERE snapshot_id=?")
                .bind(item_count)
                .bind(&snapshot_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
        // Preserve the route's original commit-before-cursor order. If cursor
        // encoding ever fails, the snapshot remains committed and the client
        // can retry with a fresh snapshot request.
        let next_cursor = encode_cursor_with_key(&cursor_key, &generation, &vault_id, high)?;
        Ok(json!({
            "snapshot_id": snapshot_id,
            "high_watermark": high.to_string(),
            "conflict_high_watermark": conflict_high.to_string(),
            "item_count": item_count,
            "next_cursor": next_cursor,
            "expires_at": expires_at,
        }))
    }

    async fn resolve_conflict_sqlite(
        &self,
        command: ResolveConflictCommand,
    ) -> Result<Value, ApiError> {
        let ResolveConflictCommand {
            user,
            vault_id,
            conflict_id,
            resolved_revision_id,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
        let row = sqlx::query(
            "SELECT record_id,resolved_revision_id,resolution_seq FROM conflicts WHERE conflict_id=? AND vault_id=?",
        )
        .bind(&conflict_id)
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let record: String = row.get("record_id");
        Self::reject_redacted_record_tx(&mut tx, &vault_id, &record).await?;
        let existing_revision = row.get::<Option<String>, _>("resolved_revision_id");
        if crate::sync::conflict_resolution_retry(
            existing_revision.as_deref(),
            &resolved_revision_id,
        )? {
            // A replay remains confirmable even after the main head advances.
            let resolution_seq: i64 = row
                .try_get::<Option<i64>, _>("resolution_seq")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("resolved conflict is missing its sequence"))?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "status": "resolved",
                "resolved_revision_id": existing_revision,
                "resolution_seq": resolution_seq.to_string(),
                "already_resolved": true,
            }));
        }

        let head: Option<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if head.as_deref() != Some(&resolved_revision_id) {
            return Err(ApiError::conflict(
                "REVISION_CONFLICT",
                "resolution must point to the current main revision",
            ));
        }
        let version: Option<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&record)
        .bind(&resolved_revision_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if version.is_none() {
            return Err(ApiError::not_found());
        }
        let resolution_seq: i64 = sqlx::query_scalar(
            "UPDATE vault_counters SET last_conflict_seq=last_conflict_seq+1 WHERE vault_id=? RETURNING last_conflict_seq",
        )
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let resolved = sqlx::query("UPDATE conflicts SET resolved_revision_id=?,resolution_seq=?,resolution_at=? WHERE conflict_id=? AND vault_id=? AND resolved_revision_id IS NULL")
            .bind(&resolved_revision_id)
            .bind(resolution_seq)
            .bind(crate::now_rfc3339())
            .bind(&conflict_id)
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if resolved.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "CONFLICT_ALREADY_RESOLVED",
                "conflict was already resolved",
            ));
        }
        crate::audit::record_vault_event_tx(
            &mut tx,
            &vault_id,
            Some(&user.user_id),
            Some(&user.device_id),
            "vault.conflict_resolved",
            "conflict",
            Some(&conflict_id),
            crate::audit::AuditSource::Api,
            chrono::Utc::now().timestamp(),
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "resolved",
            "resolved_revision_id": resolved_revision_id,
            "resolution_seq": resolution_seq.to_string(),
            "already_resolved": false,
        }))
    }

    async fn create_conflict_sqlite(
        &self,
        command: CreateConflictCommand,
    ) -> Result<Value, ApiError> {
        let CreateConflictCommand {
            user,
            vault_id,
            device_id,
            conflict_id,
            request_digest,
            envelope_json,
            operation,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
        Self::reject_redacted_record_tx(&mut tx, &vault_id, &operation.record_id).await?;
        let existing = sqlx::query(
            "SELECT conflict_id,digest FROM conflicts WHERE vault_id=? AND device_id=? AND op_id=?",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&operation.op_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .map(|row| {
            (
                row.get::<String, _>("conflict_id"),
                row.get::<String, _>("digest"),
            )
        });
        if let Some(existing_id) =
            crate::sync::conflict_idempotency_retry(existing, &request_digest)?
        {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "conflict_id": existing_id,
                "record_id": operation.record_id,
                "revision_id": operation.revision_id,
                "status": "stored",
            }));
        }

        // Return a verified, same-device replay before checking whether the
        // Vault's current roster still advertises schema v2. Capability
        // reports can expire or be invalidated after the original commit; an
        // exact retry has no new write effect and must remain idempotent.
        if operation.record_schema >= 2 {
            if !crate::device_capabilities::all_active_vault_devices_support_v2_tx(
                &mut tx, &vault_id,
            )
            .await?
            {
                return Err(ApiError::conflict(
                    "VAULT_CLIENT_CAPABILITY_REQUIRED",
                    "all active devices of active vault members must support schema 2, attachment manifest v2, and 1 GiB attachments",
                ));
            }
            sqlx::query("UPDATE vaults SET required_record_schema=2 WHERE vault_id=? AND required_record_schema<2")
                .bind(&vault_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }

        let conflict_seq: i64 = sqlx::query_scalar(
            "UPDATE vault_counters SET last_conflict_seq=last_conflict_seq+1 WHERE vault_id=? RETURNING last_conflict_seq",
        )
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        persist_object_references_tx(
            &mut tx,
            &vault_id,
            &operation.revision_id,
            &operation.object_refs,
        )
        .await?;
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES(?,?,?,?,?,?,?,?,?,?)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(&operation.record_id)
            .bind(&operation.base)
            .bind(&envelope_json)
            .bind(&request_digest)
            .bind(&device_id)
            .bind(now_rfc3339())
            .bind(conflict_seq)
            .bind(&operation.op_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "conflict_id": conflict_id,
            "record_id": operation.record_id,
            "revision_id": operation.revision_id,
            "status": "stored",
        }))
    }
}

impl SyncCommitRepository for SqliteSyncRepository {
    fn commit_batch(&self, command: PushCommit) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.commit_batch_sqlite(command))
    }
}

impl SyncRepository for SqliteSyncRepository {
    fn active_device_signing_key(
        &self,
        user_id: String,
        device_id: String,
    ) -> RepositoryFuture<'_, Result<Option<String>, ApiError>> {
        Box::pin(async move {
            sqlx::query_scalar(
                "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
            )
            .bind(device_id)
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)
        })
    }

    fn read_changes_page(
        &self,
        command: ChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_changes_page_sqlite(command))
    }

    fn read_conflict_changes_page(
        &self,
        command: ConflictChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_conflict_changes_page_sqlite(command))
    }

    fn read_history_page(
        &self,
        command: HistoryPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_history_page_sqlite(command))
    }

    fn read_snapshot(
        &self,
        command: ReadSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_snapshot_sqlite(command))
    }

    fn read_revision(
        &self,
        command: ReadRevisionCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_revision_sqlite(command))
    }

    fn create_snapshot(
        &self,
        command: CreateSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.create_snapshot_sqlite(command))
    }

    fn resolve_conflict(
        &self,
        command: ResolveConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.resolve_conflict_sqlite(command))
    }

    fn create_conflict(
        &self,
        command: CreateConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.create_conflict_sqlite(command))
    }
}

fn unique_violation_or_internal(
    error: sqlx::Error,
    conflict_code: &str,
    conflict_message: &str,
) -> ApiError {
    if error
        .as_database_error()
        .is_some_and(|database_error| database_error.is_unique_violation())
    {
        ApiError::conflict(conflict_code, conflict_message)
    } else {
        ApiError::internal(error)
    }
}

/// Stores references only to complete objects in the same transaction as the
/// record revision. SQLite's writer lock orders this check against object GC.
pub(crate) async fn persist_object_references_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    vault_id: &str,
    revision_id: &str,
    object_refs: &[String],
) -> Result<(), ApiError> {
    if object_refs.is_empty() {
        return Ok(());
    }
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(vault_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::conflict(
            "OBJECT_REFERENCE_UNAVAILABLE",
            "one or more referenced objects are unavailable",
        ));
    }

    for chunk in object_refs.chunks(900) {
        let mut query =
            QueryBuilder::<Sqlite>::new("SELECT object_id FROM blob_objects WHERE vault_id = ");
        query
            .push_bind(vault_id)
            .push(" AND storage_state='available' AND object_id IN (");
        let mut separated = query.separated(",");
        for object_id in chunk {
            separated.push_bind(object_id);
        }
        query.push(")");
        let rows = query
            .build()
            .fetch_all(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
        if rows.len() != chunk.len() {
            return Err(ApiError::conflict(
                "OBJECT_REFERENCE_UNAVAILABLE",
                "one or more referenced objects are unavailable",
            ));
        }
    }

    for chunk in object_refs.chunks(250) {
        let mut query = QueryBuilder::<Sqlite>::new(
            "INSERT INTO object_references(vault_id,revision_id,object_id) ",
        );
        query.push_values(chunk, |mut row, object_id| {
            row.push_bind(vault_id)
                .push_bind(revision_id)
                .push_bind(object_id);
        });
        query.push(" ON CONFLICT(vault_id,revision_id,object_id) DO NOTHING");
        query
            .build()
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }

    for chunk in object_refs.chunks(900) {
        let mut query =
            QueryBuilder::<Sqlite>::new("UPDATE blob_objects SET gc_after=NULL WHERE vault_id=");
        query.push_bind(vault_id).push(" AND object_id IN (");
        let mut separated = query.separated(",");
        for object_id in chunk {
            separated.push_bind(object_id);
        }
        query.push(")");
        query
            .build()
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

async fn revision_conflict(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    vault: &str,
    record_id: &str,
    head: Option<&sqlx::sqlite::SqliteRow>,
    declares_record_schema2: bool,
) -> Result<ApiError, ApiError> {
    let mut details = json!({});
    if let Some(row) = head {
        let revision: String = row.get("revision_id");
        let deleted = row.get::<i64, _>("deleted") != 0;
        let envelope: Option<String> = sqlx::query_scalar(
            "SELECT envelope FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(vault)
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
        details = json!({"current_revision_id":revision,"deleted":deleted,"current_envelope":current_envelope});
    }
    Ok(
        ApiError::conflict("REVISION_CONFLICT", "record changed on another device")
            .with_details(details),
    )
}

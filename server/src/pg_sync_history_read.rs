//! PostgreSQL implementation of immutable revision and snapshot-bound history
//! reads. This bounded capability is composed into `PgSyncRepository` for the
//! restricted PostgreSQL sync runtime.
//!
//! The adapter expects the PostgreSQL sync-core, retention, conflict-feed,
//! snapshots, and record-redaction schemas. Snapshot bounds are immutable
//! checkpoints; both watermarks are always read together and bound into every
//! continuation cursor. Redaction proofs are signed with the current shared
//! instance key when each response is materialized.

use futures_util::TryStreamExt;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};

use crate::{
    ApiError,
    auth::AuthUser,
    pg_record_redaction::{
        PgRedactionProofSigner, record_redacted_error, redaction_columns, redaction_from_join_row,
        require_redaction_client_for_vault_tx,
    },
    sync::{
        HistoryBounds, HistoryKind, SyncPageBudget, ensure_envelope_readable,
        ensure_sync_page_response_fits, foreign_generation_history_cursor_claim, history_cursor,
        parse_history_cursor, sync_page_item_too_large,
    },
    sync_repository::{HistoryPageCommand, ReadRevisionCommand, RepositoryFuture},
};

/// Separate capability for the PostgreSQL snapshot history reads. It does not
/// claim to implement write, snapshot creation, or the rest of `SyncRepository`.
pub(crate) trait SyncHistoryReadRepository: Send + Sync {
    fn read_history_page(
        &self,
        command: HistoryPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    fn read_revision(
        &self,
        command: ReadRevisionCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct PgSyncHistoryReadRepository {
    pool: PgPool,
    proof_signer: Option<PgRedactionProofSigner>,
}

impl PgSyncHistoryReadRepository {
    /// Expects the bounded PostgreSQL sync schema, including the `snapshots`
    /// table created by the later snapshots migration.
    pub(crate) fn new(pool: PgPool) -> Self {
        Self {
            pool,
            proof_signer: None,
        }
    }

    pub(crate) fn with_signer(pool: PgPool, proof_signer: PgRedactionProofSigner) -> Self {
        Self {
            pool,
            proof_signer: Some(proof_signer),
        }
    }

    async fn read_history_page(&self, command: HistoryPageCommand) -> Result<Value, ApiError> {
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
        // A history response combines authorization, snapshot metadata, and
        // multiple event rows. They must all come from one MVCC snapshot.
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        // Preserve SQLite's error ordering: active account, Vault membership,
        // then the request-bound session/device fence. Cursor parsing follows
        // these checks so a caller without access cannot probe snapshot state.
        require_active_account_read(&mut tx, &user.user_id).await?;
        require_vault_membership_read(&mut tx, &user.user_id, &vault_id).await?;
        require_active_session_device_read(&mut tx, &user).await?;
        require_redaction_client_for_vault_tx(&mut tx, &vault_id, &user).await?;

        let row = sqlx::query(
            "SELECT high_watermark,conflict_high_watermark,\
                    expires_at<=CURRENT_TIMESTAMP AS expired,server_generation,redacted_at \
             FROM snapshots WHERE snapshot_id=$1 AND vault_id=$2",
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
            "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=$1 AND redaction_seq>$2)",
        )
        .bind(&vault_id)
        .bind(snapshot_high)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let redacted_at: Option<chrono::DateTime<chrono::Utc>> = row.get("redacted_at");
        if redacted_at.is_some() || post_snapshot_redaction {
            return Err(ApiError::gone(
                "SNAPSHOT_REDACTED",
                "snapshot was invalidated because it contains a redacted record",
            ));
        }

        let snapshot_generation: String = row.get("server_generation");
        if row.get::<bool, _>("expired") || snapshot_generation != generation {
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
                let redaction_columns = redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT v.record_id,v.revision_id,v.base_revision_id,v.commit_seq,v.operation,\
                            to_char(v.created_at AT TIME ZONE 'UTC',\
                                    'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS created_at,\
                            CASE WHEN v.restore_until IS NULL THEN NULL ELSE \
                              to_char(v.restore_until AT TIME ZONE 'UTC',\
                                      'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') END AS restore_until,\
                            v.envelope,g.auto_purge_enabled AS auto_purge_enabled,\
                            g.auto_purge_revision AS auto_purge_revision,{redaction_columns} \
                     FROM record_versions v LEFT JOIN record_redactions rr \
                       ON rr.vault_id=v.vault_id AND rr.record_id=v.record_id \
                     LEFT JOIN record_graveyard g ON g.vault_id=v.vault_id AND g.record_id=v.record_id \
                       AND g.deleted_revision=v.revision_id AND g.deleted_seq=v.commit_seq \
                     WHERE v.vault_id=$1 AND v.commit_seq>$2 AND v.commit_seq<=$3 \
                     ORDER BY v.commit_seq ASC LIMIT $4"
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
                    let event = if let Some(statement) = redaction_from_join_row(&row)? {
                        let signer = self.proof_signer.as_ref().ok_or_else(|| {
                            ApiError::internal("redaction proof signer is unavailable")
                        })?;
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
                            "redaction": signer.proof(&statement)?,
                        })
                    } else {
                        let restore_until: Option<String> = row.get("restore_until");
                        if operation == "delete" && restore_until.is_none() {
                            return Err(ApiError::internal(
                                "delete revision restore deadline is missing",
                            ));
                        }
                        let encoded: Option<String> = row.get("envelope");
                        let encoded = encoded.ok_or_else(|| {
                            ApiError::internal("unredacted revision is missing its envelope")
                        })?;
                        let mut event = json!({
                            "record_id": row.get::<String, _>("record_id"),
                            "revision_id": row.get::<String, _>("revision_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                            "operation": operation,
                            "deleted": operation == "delete",
                            "created_at": row.get::<String, _>("created_at"),
                            "restore_until": restore_until,
                            "envelope": serde_json::from_str::<Value>(&encoded)
                                .map_err(ApiError::internal)?,
                        });
                        if operation == "delete" {
                            let auto_purge_enabled: Option<bool> = row
                                .try_get("auto_purge_enabled")
                                .map_err(ApiError::internal)?;
                            let auto_purge_revision: Option<i64> = row
                                .try_get("auto_purge_revision")
                                .map_err(ApiError::internal)?;
                            event["auto_purge_enabled"] =
                                json!(auto_purge_enabled.unwrap_or(false));
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
                let redaction_columns = redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT c.conflict_id,c.conflict_seq,c.record_id,c.base_revision_id,\
                            resolved_revision_id,resolution_seq,\
                            to_char(c.created_at AT TIME ZONE 'UTC',\
                                    'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS created_at,\
                            c.envelope,{redaction_columns} \
                     FROM conflicts c LEFT JOIN record_redactions rr \
                       ON rr.vault_id=c.vault_id AND rr.record_id=c.record_id \
                     WHERE c.vault_id=$1 AND c.conflict_seq>$2 AND c.conflict_seq<=$3 \
                     ORDER BY c.conflict_seq ASC LIMIT $4"
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
                    let event = if let Some(statement) = redaction_from_join_row(&row)? {
                        let signer = self.proof_signer.as_ref().ok_or_else(|| {
                            ApiError::internal("redaction proof signer is unavailable")
                        })?;
                        json!({
                            "conflict_id": row.get::<String, _>("conflict_id"),
                            "conflict_seq": row.get::<i64, _>("conflict_seq").to_string(),
                            "record_id": row.get::<String, _>("record_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "resolved_revision_id": Value::Null,
                            "resolution_seq": if resolved_by_watermark {
                                resolution_seq.map(|seq| seq.to_string())
                            } else { None },
                            "created_at": row.get::<String, _>("created_at"),
                            "envelope": Value::Null,
                            "redaction": signer.proof(&statement)?,
                        })
                    } else {
                        let encoded: Option<String> = row.get("envelope");
                        let encoded = encoded.ok_or_else(|| {
                            ApiError::internal("unredacted conflict is missing its envelope")
                        })?;
                        let event = json!({
                            "conflict_id": row.get::<String, _>("conflict_id"),
                            "conflict_seq": row.get::<i64, _>("conflict_seq").to_string(),
                            "record_id": row.get::<String, _>("record_id"),
                            "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                            "resolved_revision_id": if resolved_by_watermark {
                                row.get::<Option<String>, _>("resolved_revision_id")
                            } else { None },
                            "resolution_seq": if resolved_by_watermark {
                                resolution_seq.map(|seq| seq.to_string())
                            } else { None },
                            "created_at": row.get::<String, _>("created_at"),
                            "envelope": serde_json::from_str::<Value>(&encoded)
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

    async fn read_revision(&self, command: ReadRevisionCommand) -> Result<Value, ApiError> {
        let ReadRevisionCommand {
            user,
            vault_id,
            revision_id,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        require_active_account_read(&mut tx, &user.user_id).await?;
        require_vault_membership_read(&mut tx, &user.user_id, &vault_id).await?;
        require_active_session_device_read(&mut tx, &user).await?;
        require_redaction_client_for_vault_tx(&mut tx, &vault_id, &user).await?;

        let revision_redaction_columns = redaction_columns("rr");
        let rows_sql = format!(
            "SELECT v.envelope,v.record_id,v.digest,v.commit_seq,{revision_redaction_columns} \
             FROM record_versions v LEFT JOIN record_redactions rr \
               ON rr.vault_id=v.vault_id AND rr.record_id=v.record_id \
             WHERE v.vault_id=$1 AND v.revision_id=$2 LIMIT 2"
        );
        let mut rows = sqlx::query(&rows_sql)
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
        let version_row = rows.pop();

        // Legacy data can assign the same revision ID to multiple records.
        // Consult the durable redacted ID map before returning any live row,
        // including after a future purge removes record_versions payloads.
        let redacted_revision_columns = redaction_columns("rr");
        let redacted_sql = format!(
            "SELECT ri.record_id,{redacted_revision_columns} \
             FROM record_redacted_revisions ri JOIN record_redactions rr \
               ON rr.vault_id=ri.vault_id AND rr.record_id=ri.record_id \
             WHERE ri.vault_id=$1 AND ri.revision_id=$2 LIMIT 2"
        );
        let mut redacted_rows = sqlx::query(&redacted_sql)
            .bind(&vault_id)
            .bind(&revision_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if redacted_rows.len() > 1 {
            return Err(ApiError::internal(
                "redacted revision identifier is ambiguous within this Vault",
            ));
        }
        if let Some(redacted_row) = redacted_rows.pop() {
            let statement = redaction_from_join_row(&redacted_row)?
                .ok_or_else(|| ApiError::internal("redacted revision mapping is incomplete"))?;
            if version_row
                .as_ref()
                .is_some_and(|row| row.get::<String, _>("record_id") != statement.record_id)
            {
                return Err(ApiError::internal(
                    "revision identifier is ambiguous between live and redacted records",
                ));
            }
            let signer = self
                .proof_signer
                .as_ref()
                .ok_or_else(|| ApiError::internal("redaction proof signer is unavailable"))?;
            return Err(record_redacted_error(signer, &statement)?);
        }

        let row = version_row.ok_or_else(ApiError::not_found)?;
        if let Some(statement) = redaction_from_join_row(&row)? {
            let signer = self
                .proof_signer
                .as_ref()
                .ok_or_else(|| ApiError::internal("redaction proof signer is unavailable"))?;
            return Err(record_redacted_error(signer, &statement)?);
        }
        let encoded: Option<String> = row.get("envelope");
        let encoded = encoded.ok_or_else(|| ApiError::internal("revision envelope is missing"))?;
        let envelope = serde_json::from_str::<Value>(&encoded).map_err(ApiError::internal)?;
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
}

impl SyncHistoryReadRepository for PgSyncHistoryReadRepository {
    fn read_history_page(
        &self,
        command: HistoryPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(PgSyncHistoryReadRepository::read_history_page(
            self, command,
        ))
    }

    fn read_revision(
        &self,
        command: ReadRevisionCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(PgSyncHistoryReadRepository::read_revision(self, command))
    }
}

async fn require_active_account_read(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: &str,
) -> Result<(), ApiError> {
    let status: Option<String> = sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

async fn require_vault_membership_read(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user_id: &str,
    vault_id: &str,
) -> Result<(), ApiError> {
    let member: Option<i32> = sqlx::query_scalar(
        "SELECT 1 FROM vaults v \
         JOIN vault_members vm ON vm.vault_id=v.vault_id \
         WHERE v.vault_id=$1 AND vm.user_id=$2 AND vm.state='active'",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if member.is_none() {
        return Err(ApiError::not_found());
    }
    Ok(())
}

async fn require_active_session_device_read(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT s.revoked_at IS NOT NULL AS revoked,\
                s.access_expires_at>CURRENT_TIMESTAMP AS unexpired,\
                u.status AS account_status,d.status AS device_status \
         FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Err(ApiError::unauthorized());
    };
    if row.get::<bool, _>("revoked")
        || !row.get::<bool, _>("unexpired")
        || row.get::<String, _>("account_status") != "active"
    {
        return Err(ApiError::unauthorized());
    }
    if row.get::<String, _>("device_status") != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{str::FromStr, sync::Arc};

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::SigningKey;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const RETENTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const SNAPSHOT_PAGES_MIGRATION: &str =
        include_str!("../migrations/postgres/0008_sync_snapshot_pages.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );
    const USER_ID: &str = "pg-history-user";
    const DEVICE_ID: &str = "pg-history-device";
    const SESSION_ID: &str = "pg-history-session";
    const VAULT_ID: &str = "e950523f-c2bd-42fb-a66c-d9c87d86d331";
    const SNAPSHOT_ID: &str = "99f831c6-3b6b-4cfe-b003-82f131ff4876";
    const GENERATION: &str = "4bcf11d5-99ed-49f3-8012-6f1d706edc91";
    const OLD_GENERATION: &str = "8bcf11d5-99ed-49f3-8012-6f1d706edc91";
    const ACCESS_HASH: &str = "pg-history-access-hash";
    const CURSOR_KEY: [u8; 32] = [0x61; 32];

    /// Covers the interval after schema creation and before a test database
    /// owns the schema. Explicit async cleanup is used for expected setup
    /// failures; Drop remains a best-effort fallback for unexpected panics.
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

        fn disarm(&mut self) {
            self.armed = false;
        }

        async fn cleanup(mut self) {
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
    }

    impl Drop for SchemaCleanupGuard {
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

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL history tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database_name = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database_name.starts_with("atermius_test")
                    || database_name.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL tests outside an explicitly disposable database"
            );
            assert!(!matches!(
                database_name.as_str(),
                "postgres" | "template0" | "template1"
            ));

            let admin_pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect PostgreSQL disposable test database");
            let schema = format!("atermius_pg_history_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            // This guard is installed immediately after CREATE SCHEMA, before
            // opening the isolated pool, so connection failures also clean up.
            let mut setup_guard = SchemaCleanupGuard::new(admin_pool.clone(), schema.clone());
            let pool = match PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
            {
                Ok(pool) => pool,
                Err(error) => {
                    setup_guard.cleanup().await;
                    panic!("connect isolated PostgreSQL search path: {error}");
                }
            };
            let setup_result: Result<(), sqlx::Error> = async {
                sqlx::raw_sql(CORE_MIGRATION).execute(&pool).await?;
                sqlx::raw_sql(RETENTION_MIGRATION).execute(&pool).await?;
                sqlx::raw_sql(CONFLICT_MIGRATION).execute(&pool).await?;
                // This history slice keeps a nullable watermark column so it
                // can test legacy/incomplete snapshots that production 0007
                // no longer creates. The remaining page shape is production
                // migration 0008.
                sqlx::raw_sql(
                    "CREATE TABLE snapshots (\
                    snapshot_id TEXT PRIMARY KEY,\
                    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,\
                    requested_by TEXT NOT NULL REFERENCES users(user_id),\
                    high_watermark BIGINT NOT NULL,\
                    conflict_high_watermark BIGINT,\
                    manifest_json TEXT NOT NULL,\
                    expires_at TIMESTAMPTZ NOT NULL,\
                    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,\
                    server_generation TEXT NOT NULL\
                    )",
                )
                .execute(&pool)
                .await?;
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema (\
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
                )
                .execute(&pool)
                .await?;
                sqlx::raw_sql(SNAPSHOT_PAGES_MIGRATION)
                    .execute(&pool)
                    .await?;
                sqlx::raw_sql(REDACTION_MIGRATION).execute(&pool).await?;
                sqlx::raw_sql(REDACTED_CONFLICT_MIGRATION)
                    .execute(&pool)
                    .await?;
                seed(&pool).await?;
                Ok(())
            }
            .await;
            if let Err(error) = setup_result {
                pool.close().await;
                setup_guard.cleanup().await;
                panic!("initialize PostgreSQL history fixture: {error}");
            }
            let database = Self {
                pool,
                admin_pool,
                schema,
                cleaned: false,
            };
            // TestDatabase's own Drop guard now owns cleanup for the remainder
            // of the test, so disarm the temporary setup guard only after all
            // migrations and seed rows have succeeded.
            setup_guard.disarm();
            database
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
            let remains: bool =
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)")
                    .bind(&self.schema)
                    .fetch_one(&self.admin_pool)
                    .await
                    .expect("verify isolated PostgreSQL test schema cleanup");
            assert!(
                !remains,
                "isolated PostgreSQL test schema remains after cleanup"
            );
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

    async fn seed(pool: &PgPool) -> Result<(), sqlx::Error> {
        sqlx::query(
            "INSERT INTO users(user_id,username,status) VALUES($1,'pg-history-user','active')",
        )
        .bind(USER_ID)
        .execute(pool)
        .await?;
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) VALUES($1,$2,'history-reader','active')",
        )
        .bind(DEVICE_ID)
        .bind(USER_ID)
        .execute(pool)
        .await?;
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,'pg-history-refresh-hash',CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
            .bind(SESSION_ID)
            .bind(USER_ID)
            .bind(DEVICE_ID)
            .bind(ACCESS_HASH)
            .execute(pool)
            .await?;
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) VALUES($1,$2,'active',1,1)",
        )
        .bind(VAULT_ID)
        .bind(USER_ID)
        .execute(pool)
        .await?;
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
        )
        .bind(VAULT_ID)
        .bind(USER_ID)
        .execute(pool)
        .await?;
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,minimum_available_seq,last_conflict_seq) VALUES($1,0,1,0)")
            .bind(VAULT_ID)
            .execute(pool)
            .await?;
        Ok(())
    }

    async fn insert_snapshot(
        pool: &PgPool,
        snapshot_id: &str,
        revision_watermark: i64,
        conflict_watermark: Option<i64>,
        generation: &str,
        expires_at: chrono::DateTime<chrono::Utc>,
    ) {
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark,manifest_json,expires_at,server_generation) VALUES($1,$2,$3,$4,$5,'[]',$6,$7)")
            .bind(snapshot_id)
            .bind(VAULT_ID)
            .bind(USER_ID)
            .bind(revision_watermark)
            .bind(conflict_watermark)
            .bind(expires_at)
            .bind(generation)
            .execute(pool)
            .await
            .unwrap();
    }

    async fn insert_revision(
        pool: &PgPool,
        seq: i64,
        revision_id: &str,
        operation: &str,
        envelope: &str,
    ) {
        let record_id = format!("record-{revision_id}");
        let digest = crate::sha256_hex(envelope.as_bytes());
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at,restore_until) VALUES($1,$2,$3,NULL,$4,$5,$6,$7,$8,CURRENT_TIMESTAMP,CASE WHEN $8='delete' THEN CURRENT_TIMESTAMP+INTERVAL '30 days' ELSE NULL END)")
            .bind(VAULT_ID)
            .bind(record_id)
            .bind(revision_id)
            .bind(envelope)
            .bind(digest)
            .bind(seq)
            .bind(DEVICE_ID)
            .bind(operation)
            .execute(pool)
            .await
            .unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL redaction acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_redaction_direct_revision_keeps_proof_after_payload_removal_and_invalidates_history()
     {
        let database = TestDatabase::create().await;
        let repository =
            PgSyncHistoryReadRepository::with_signer(database.pool.clone(), proof_signer());
        let record_id = Uuid::new_v4().to_string();
        let first_revision = Uuid::new_v4().to_string();
        let deleted_revision = Uuid::new_v4().to_string();
        let redaction_id = Uuid::new_v4().to_string();
        let snapshot_id = Uuid::new_v4().to_string();
        for (seq, revision_id, operation) in [
            (1_i64, first_revision.as_str(), "create"),
            (2_i64, deleted_revision.as_str(), "delete"),
        ] {
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES($1,$2,$3,NULL,'{\"header\":{\"record_schema\":1},\"ciphertext\":\"private\"}','digest',$4,$5,$6,CURRENT_TIMESTAMP)")
                .bind(VAULT_ID)
                .bind(&record_id)
                .bind(revision_id)
                .bind(seq)
                .bind(DEVICE_ID)
                .bind(operation)
                .execute(&database.pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,2)")
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,2,3)")
            .bind(&redaction_id)
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&database.pool)
            .await
            .unwrap();
        insert_snapshot(
            &database.pool,
            &snapshot_id,
            2,
            Some(0),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        sqlx::query("UPDATE snapshots SET manifest_json='not-json' WHERE snapshot_id=$1")
            .bind(&snapshot_id)
            .execute(&database.pool)
            .await
            .unwrap();

        let revision_error = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: first_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(revision_error.status, axum::http::StatusCode::GONE);
        assert_eq!(revision_error.body.code, "RECORD_REDACTED");
        let proof = revision_error.body.details.unwrap()["redaction"].clone();
        assert_eq!(proof["redaction_id"], redaction_id);
        assert_eq!(proof["record_id"], record_id);

        let history_error = repository
            .read_history_page(page_command(
                actor(),
                &snapshot_id,
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(history_error.status, axum::http::StatusCode::GONE);
        assert_eq!(history_error.body.code, "SNAPSHOT_REDACTED");

        // Simulate the later payload-scrub transaction. The direct-ID map is
        // immutable metadata and still returns the signed proof afterwards.
        sqlx::query("DELETE FROM record_versions WHERE vault_id=$1 AND record_id=$2")
            .bind(VAULT_ID)
            .bind(&record_id)
            .execute(&database.pool)
            .await
            .unwrap();
        let payloadless_error = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: first_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(payloadless_error.body.code, "RECORD_REDACTED");
        assert_eq!(payloadless_error.body.details.unwrap()["redaction"], proof);

        // A legacy duplicate that points to a different live record fails
        // closed rather than returning the redacted record's proof or payload.
        let other_record = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES($1,$2,$3,NULL,'{\"header\":{\"record_schema\":1},\"ciphertext\":\"collision\"}','digest',4,$4,'create',CURRENT_TIMESTAMP)")
            .bind(VAULT_ID)
            .bind(other_record)
            .bind(&first_revision)
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let ambiguous_error = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: first_revision,
            })
            .await
            .unwrap_err();
        assert_eq!(
            ambiguous_error.status,
            axum::http::StatusCode::INTERNAL_SERVER_ERROR
        );

        let mut legacy_client = actor();
        legacy_client.declares_sync_redaction_v1 = false;
        let legacy_error = repository
            .read_revision(ReadRevisionCommand {
                user: legacy_client,
                vault_id: VAULT_ID.to_owned(),
                revision_id: deleted_revision,
            })
            .await
            .unwrap_err();
        assert_eq!(
            legacy_error.status,
            axum::http::StatusCode::UPGRADE_REQUIRED
        );
        assert_eq!(
            legacy_error.body.code,
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        database.cleanup().await;
    }

    async fn insert_conflict(
        pool: &PgPool,
        conflict_id: &str,
        seq: i64,
        resolution: Option<(i64, &str)>,
        envelope: &str,
    ) {
        let record_id = format!("record-{conflict_id}");
        let digest = crate::sha256_hex(envelope.as_bytes());
        let (resolution_seq, resolved_revision) = resolution
            .map(|(seq, revision)| (Some(seq), Some(revision)))
            .unwrap_or((None, None));
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq,resolved_revision_id,resolution_seq,resolution_at) VALUES($1,$2,$3,'base-revision',$4,$5,$6,CURRENT_TIMESTAMP,$7,$8,$9,CASE WHEN $9::BIGINT IS NULL THEN NULL ELSE CURRENT_TIMESTAMP END)")
            .bind(conflict_id)
            .bind(VAULT_ID)
            .bind(record_id)
            .bind(envelope)
            .bind(digest)
            .bind(DEVICE_ID)
            .bind(seq)
            .bind(resolved_revision)
            .bind(resolution_seq)
            .execute(pool)
            .await
            .unwrap();
    }

    fn actor() -> AuthUser {
        AuthUser {
            user_id: USER_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: SESSION_ID.to_owned(),
            access_hash: ACCESS_HASH.to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        }
    }

    fn proof_signer() -> PgRedactionProofSigner {
        let key = Arc::new(SigningKey::from_bytes(&[0x71; 32]));
        let instance = crate::InstanceInfo {
            instance_id: "3a25ea6e-53f5-47b6-9d82-97c43acb8a0b".to_owned(),
            server_space_id: "60fa13ac-45b6-449a-a980-b83d77a0f5b0".to_owned(),
            generation: GENERATION.to_owned(),
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
            signing_key_transitions: Vec::new(),
        };
        PgRedactionProofSigner::new(instance, key)
    }

    fn page_command(
        user: AuthUser,
        snapshot_id: &str,
        kind: HistoryKind,
        raw_cursor: Option<String>,
        limit: i64,
    ) -> HistoryPageCommand {
        HistoryPageCommand {
            user,
            vault_id: VAULT_ID.to_owned(),
            snapshot_id: snapshot_id.to_owned(),
            kind,
            raw_cursor,
            limit,
            generation: GENERATION.to_owned(),
            cursor_key: CURSOR_KEY,
        }
    }

    fn history_after(
        snapshot: &str,
        kind: HistoryKind,
        bounds: HistoryBounds,
        after: i64,
    ) -> String {
        history_cursor(
            GENERATION,
            &CURSOR_KEY,
            kind,
            VAULT_ID,
            snapshot,
            bounds,
            after,
        )
        .unwrap()
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL history acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_history_pages_replay_prefixes_and_mask_conflict_resolution_after_watermark() {
        let database = TestDatabase::create().await;
        let repository = PgSyncHistoryReadRepository::new(database.pool.clone());
        let envelope1 = r#"{"header":{"record_schema":1},"ciphertext":"revision-one"}"#;
        let envelope2 = r#"{"header":{"record_schema":1},"ciphertext":"revision-two"}"#;
        let envelope3 = r#"{"header":{"record_schema":1},"ciphertext":"revision-three"}"#;
        insert_revision(&database.pool, 1, "revision-one", "create", envelope1).await;
        insert_revision(&database.pool, 2, "revision-two", "update", envelope2).await;
        insert_revision(&database.pool, 3, "revision-three", "delete", envelope3).await;
        let persisted_restore_until: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(
            "SELECT restore_until FROM record_versions WHERE vault_id=$1 \
             AND record_id=$2 AND revision_id='revision-three'",
        )
        .bind(VAULT_ID)
        .bind("record-revision-three")
        .fetch_one(&database.pool)
        .await
        .unwrap();
        let first_conflict = Uuid::new_v4().to_string();
        let second_conflict = Uuid::new_v4().to_string();
        let conflict_envelope = r#"{"header":{"record_schema":1},"ciphertext":"conflict-branch"}"#;
        insert_conflict(
            &database.pool,
            &first_conflict,
            1,
            Some((3, "resolved-revision")),
            conflict_envelope,
        )
        .await;
        insert_conflict(&database.pool, &second_conflict, 2, None, conflict_envelope).await;
        insert_snapshot(
            &database.pool,
            SNAPSHOT_ID,
            3,
            Some(2),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        let visible_snapshot = Uuid::new_v4().to_string();
        insert_snapshot(
            &database.pool,
            &visible_snapshot,
            3,
            Some(3),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;

        let first = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                None,
                1,
            ))
            .await
            .unwrap();
        assert_eq!(first["snapshot_id"], SNAPSHOT_ID);
        assert_eq!(first["vault_id"], VAULT_ID);
        assert_eq!(first["high_watermark"], "3");
        assert_eq!(first["conflict_high_watermark"], "2");
        assert_eq!(first["revisions"].as_array().unwrap().len(), 1);
        assert_eq!(first["revisions"][0]["commit_seq"], "1");
        assert_eq!(first["revisions"][0]["deleted"], false);
        assert_eq!(first["revisions"][0]["restore_until"], Value::Null);
        assert_eq!(first["has_more"], true);
        let revision_cursor = first["next_cursor"].as_str().unwrap().to_owned();
        assert_eq!(
            parse_history_cursor(
                &CURSOR_KEY,
                GENERATION,
                HistoryKind::Revisions,
                VAULT_ID,
                SNAPSHOT_ID,
                HistoryBounds {
                    revisions: 3,
                    conflicts: 2,
                },
                &revision_cursor,
            )
            .unwrap(),
            1
        );
        let replay = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                None,
                1,
            ))
            .await
            .unwrap();
        assert_eq!(replay, first);
        let later = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                Some(revision_cursor),
                10,
            ))
            .await
            .unwrap();
        assert_eq!(
            later["revisions"]
                .as_array()
                .unwrap()
                .iter()
                .map(|item| item["commit_seq"].as_str().unwrap())
                .collect::<Vec<_>>(),
            ["2", "3"]
        );
        assert_eq!(later["revisions"][1]["deleted"], true);
        assert_eq!(later["revisions"][0]["restore_until"], Value::Null);
        assert_eq!(
            later["revisions"][1]["restore_until"],
            persisted_restore_until.to_rfc3339_opts(chrono::SecondsFormat::Micros, true)
        );
        assert_eq!(later["next_cursor"], Value::Null);
        assert_eq!(later["has_more"], false);

        let conflict_first = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Conflicts,
                None,
                1,
            ))
            .await
            .unwrap();
        let conflict_replay = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Conflicts,
                None,
                1,
            ))
            .await
            .unwrap();
        assert_eq!(conflict_replay, conflict_first);
        let masked = &conflict_first["conflicts"][0];
        assert_eq!(masked["conflict_seq"], "1");
        assert_eq!(masked["conflict_id"], first_conflict);
        assert_eq!(masked["resolved_revision_id"], Value::Null);
        assert_eq!(masked["resolution_seq"], Value::Null);
        assert_eq!(conflict_first["has_more"], true);
        let conflict_cursor = conflict_first["next_cursor"].as_str().unwrap().to_owned();
        let conflict_later = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Conflicts,
                Some(conflict_cursor),
                1,
            ))
            .await
            .unwrap();
        assert_eq!(conflict_later["conflicts"][0]["conflict_seq"], "2");
        assert_eq!(
            conflict_later["conflicts"][0]["conflict_id"],
            second_conflict
        );
        assert_eq!(conflict_later["has_more"], false);

        let visible = repository
            .read_history_page(page_command(
                actor(),
                &visible_snapshot,
                HistoryKind::Conflicts,
                None,
                1,
            ))
            .await
            .unwrap();
        assert_eq!(
            visible["conflicts"][0]["resolved_revision_id"],
            "resolved-revision"
        );
        assert_eq!(visible["conflicts"][0]["resolution_seq"], "3");

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL history error acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_history_rejects_bad_cursors_and_snapshot_states_with_sqlite_contract_errors() {
        let database = TestDatabase::create().await;
        let repository = PgSyncHistoryReadRepository::new(database.pool.clone());
        insert_snapshot(
            &database.pool,
            SNAPSHOT_ID,
            0,
            Some(0),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        let expired_id = Uuid::new_v4().to_string();
        insert_snapshot(
            &database.pool,
            &expired_id,
            0,
            Some(0),
            GENERATION,
            chrono::Utc::now() - chrono::Duration::minutes(1),
        )
        .await;
        let incomplete_id = Uuid::new_v4().to_string();
        insert_snapshot(
            &database.pool,
            &incomplete_id,
            0,
            None,
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        let stale_generation_id = Uuid::new_v4().to_string();
        insert_snapshot(
            &database.pool,
            &stale_generation_id,
            0,
            Some(0),
            OLD_GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;

        let malformed = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                Some("not-a-valid-history-cursor".to_owned()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(malformed.status, axum::http::StatusCode::BAD_REQUEST);
        assert_eq!(malformed.body.code, "INVALID_CURSOR");

        let stale_cursor = history_cursor(
            OLD_GENERATION,
            &CURSOR_KEY,
            HistoryKind::Revisions,
            VAULT_ID,
            SNAPSHOT_ID,
            HistoryBounds {
                revisions: 0,
                conflicts: 0,
            },
            0,
        )
        .unwrap();
        let foreign = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                Some(stale_cursor.clone()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(foreign.status, axum::http::StatusCode::GONE);
        assert_eq!(foreign.body.code, "HISTORY_CURSOR_EXPIRED");

        let missing = repository
            .read_history_page(page_command(
                actor(),
                "b64d3e65-d613-4244-a8e1-f17d2a6dc5b6",
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(missing.status, axum::http::StatusCode::NOT_FOUND);
        let missing_with_foreign = repository
            .read_history_page(page_command(
                actor(),
                "b64d3e65-d613-4244-a8e1-f17d2a6dc5b6",
                HistoryKind::Revisions,
                Some(
                    history_cursor(
                        OLD_GENERATION,
                        &CURSOR_KEY,
                        HistoryKind::Revisions,
                        VAULT_ID,
                        "b64d3e65-d613-4244-a8e1-f17d2a6dc5b6",
                        HistoryBounds {
                            revisions: 0,
                            conflicts: 0,
                        },
                        0,
                    )
                    .unwrap(),
                ),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(missing_with_foreign.status, axum::http::StatusCode::GONE);
        assert_eq!(missing_with_foreign.body.code, "HISTORY_CURSOR_EXPIRED");

        let expired = repository
            .read_history_page(page_command(
                actor(),
                &expired_id,
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(expired.status, axum::http::StatusCode::GONE);
        assert_eq!(expired.body.code, "SNAPSHOT_EXPIRED");
        let stale_snapshot = repository
            .read_history_page(page_command(
                actor(),
                &stale_generation_id,
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(stale_snapshot.status, axum::http::StatusCode::GONE);
        assert_eq!(stale_snapshot.body.code, "SNAPSHOT_EXPIRED");

        let incomplete = repository
            .read_history_page(page_command(
                actor(),
                &incomplete_id,
                HistoryKind::Conflicts,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(incomplete.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(incomplete.body.code, "HISTORY_SNAPSHOT_INCOMPLETE");
        assert_eq!(
            incomplete.body.details.unwrap()["recovery"],
            "create_new_snapshot"
        );

        // A failed history read drops its transaction and leaves the pool
        // usable before the explicit isolated-schema cleanup.
        let ready: i32 = sqlx::query_scalar("SELECT 1")
            .fetch_one(&database.pool)
            .await
            .expect("pool remains usable after history errors");
        assert_eq!(ready, 1);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL history bounds acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_history_enforces_schema_capability_and_serialized_event_budget() {
        let database = TestDatabase::create().await;
        let repository = PgSyncHistoryReadRepository::new(database.pool.clone());
        let schema2 = r#"{"header":{"record_schema":2},"ciphertext":"schema-two"}"#;
        insert_revision(&database.pool, 1, "schema-two-revision", "create", schema2).await;
        let oversized = format!(
            r#"{{"header":{{"record_schema":1}},"ciphertext":"{}"}}"#,
            "x".repeat(4 * 1024 * 1024)
        );
        insert_revision(
            &database.pool,
            2,
            "oversized-revision",
            "update",
            &oversized,
        )
        .await;
        insert_snapshot(
            &database.pool,
            SNAPSHOT_ID,
            2,
            Some(0),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;

        let unsupported = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(unsupported.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(unsupported.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");

        let mut capable = actor();
        capable.declares_record_schema2 = true;
        let first = repository
            .read_history_page(page_command(
                capable.clone(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                None,
                1,
            ))
            .await
            .unwrap();
        assert_eq!(first["revisions"].as_array().unwrap().len(), 1);
        assert_eq!(first["revisions"][0]["commit_seq"], "1");
        let after_first = history_after(
            SNAPSHOT_ID,
            HistoryKind::Revisions,
            HistoryBounds {
                revisions: 2,
                conflicts: 0,
            },
            1,
        );
        let too_large = repository
            .read_history_page(page_command(
                capable,
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                Some(after_first),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(too_large.status, axum::http::StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(too_large.body.code, "PAYLOAD_TOO_LARGE");

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL revision-read authorization acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_revision_read_returns_the_stored_envelope_and_checks_all_read_fences() {
        let database = TestDatabase::create().await;
        let repository = PgSyncHistoryReadRepository::new(database.pool.clone());
        let opaque_envelope = r#"{"header":{"record_schema":1,"future":"keep"},"nonce":"n","ciphertext":"cipher","signature":"sig","extra":{"opaque":true}}"#;
        insert_revision(
            &database.pool,
            1,
            "opaque-revision",
            "create",
            opaque_envelope,
        )
        .await;
        let expected_envelope: Value = serde_json::from_str(opaque_envelope).unwrap();
        let revision = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: "opaque-revision".to_owned(),
            })
            .await
            .unwrap();
        assert_eq!(revision["record_id"], "record-opaque-revision");
        assert_eq!(revision["envelope"], expected_envelope);
        assert_eq!(revision["commit_seq"], "1");
        assert_eq!(
            revision["digest"],
            crate::sha256_hex(opaque_envelope.as_bytes())
        );

        // Existing legacy duplicates are possible because the historical
        // primary key included record_id. Never return an arbitrary row from
        // this Vault + revision ID lookup.
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES($1,'another-record',$2,NULL,$3,$4,2,$5,'create',CURRENT_TIMESTAMP)")
            .bind(VAULT_ID)
            .bind("opaque-revision")
            .bind(opaque_envelope)
            .bind(crate::sha256_hex(opaque_envelope.as_bytes()))
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let ambiguous_revision = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: "opaque-revision".to_owned(),
            })
            .await
            .unwrap_err();
        assert_eq!(
            ambiguous_revision.status,
            axum::http::StatusCode::INTERNAL_SERVER_ERROR
        );
        assert_eq!(ambiguous_revision.body.code, "INTERNAL");

        let mut wrong_session = actor();
        wrong_session.access_hash = "mismatched-access-hash".to_owned();
        let rejected_session = repository
            .read_revision(ReadRevisionCommand {
                user: wrong_session,
                vault_id: VAULT_ID.to_owned(),
                revision_id: "opaque-revision".to_owned(),
            })
            .await
            .unwrap_err();
        assert_eq!(
            rejected_session.status,
            axum::http::StatusCode::UNAUTHORIZED
        );

        insert_snapshot(
            &database.pool,
            SNAPSHOT_ID,
            1,
            Some(0),
            GENERATION,
            chrono::Utc::now() + chrono::Duration::hours(1),
        )
        .await;
        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let rejected_device = repository
            .read_history_page(page_command(
                actor(),
                SNAPSHOT_ID,
                HistoryKind::Revisions,
                None,
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(rejected_device.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(rejected_device.body.code, "DEVICE_REVOKED");
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT_ID)
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let rejected_member = repository
            .read_revision(ReadRevisionCommand {
                user: actor(),
                vault_id: VAULT_ID.to_owned(),
                revision_id: "opaque-revision".to_owned(),
            })
            .await
            .unwrap_err();
        assert_eq!(rejected_member.status, axum::http::StatusCode::NOT_FOUND);

        database.cleanup().await;
    }
}

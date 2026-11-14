//! PostgreSQL snapshot create/read capability for Vault sync.
//!
//! This bounded capability is composed into `PgSyncRepository` for the
//! restricted PostgreSQL sync runtime. It expects the PostgreSQL sync-core
//! schema, retention/conflict feed and replay migrations, and the snapshot
//! migration in the pool search path.

use futures_util::TryStreamExt;
use serde_json::{Value, json};
use sqlx::{PgPool, Row, Transaction, postgres::PgRow};

use crate::{
    ApiError,
    auth::AuthUser,
    pg_record_redaction::{
        PgRedactionProofSigner, redaction_columns, redaction_from_join_row,
        require_redaction_client_for_vault_tx,
    },
    sync::{
        MAX_SYNC_SNAPSHOT_RESPONSE_BYTES, SYNC_SNAPSHOT_METADATA_RESERVE_BYTES, SyncPageBudget,
        encode_cursor_with_key, ensure_envelope_readable, parse_snapshot_page_cursor,
        snapshot_page_cursor, sync_page_item_too_large,
    },
    sync_repository::{CreateSnapshotCommand, ReadSnapshotCommand, RepositoryFuture},
};

/// Narrow capability for creating and reading immutable Vault snapshots.
pub(crate) trait SyncSnapshotsRepository: Send + Sync {
    fn create_snapshot(
        &self,
        command: CreateSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    fn read_snapshot(
        &self,
        command: ReadSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct PgSyncSnapshotsRepository {
    pool: PgPool,
    proof_signer: Option<PgRedactionProofSigner>,
}

impl PgSyncSnapshotsRepository {
    /// Expects a pool whose search path includes PostgreSQL migrations
    /// `0001`, `0002`, `0005`, `0006`, `0007`, and `0008`.
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

    fn materialize_snapshot_item(&self, row: &PgRow) -> Result<Value, ApiError> {
        let item_json: String = row.get("item_json");
        let item = serde_json::from_str::<Value>(&item_json).map_err(ApiError::internal)?;
        if let Some(statement) = redaction_from_join_row(row)? {
            let signer = self
                .proof_signer
                .as_ref()
                .ok_or_else(|| ApiError::internal("redaction proof signer is unavailable"))?;
            return signer.graveyard_item(&statement);
        }
        if item.get("kind").and_then(Value::as_str) == Some("graveyard") {
            return Err(ApiError::internal(
                "snapshot graveyard item has no redaction statement",
            ));
        }
        Ok(item)
    }

    async fn create(&self, command: CreateSnapshotCommand) -> Result<Value, ApiError> {
        let CreateSnapshotCommand {
            user,
            vault_id,
            generation,
            cursor_key,
        } = command;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        recheck_active_principal(&mut tx, &user).await?;
        lock_readable_vault(&mut tx, &user, &vault_id).await?;
        require_redaction_client_for_vault_tx(&mut tx, &vault_id, &user).await?;

        // Push commits serialize on this counter row; conflict writers must
        // use the same row while changing last_conflict_seq. Taking the row
        // lock before reading either watermark makes the manifest and both
        // high-watermarks one atomic Vault snapshot.
        let counters = sqlx::query(
            "SELECT last_committed_seq,last_conflict_seq FROM vault_counters WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("Vault sync counter is missing"))?;
        let high_watermark: i64 = counters.get("last_committed_seq");
        let conflict_high_watermark: i64 = counters.get("last_conflict_seq");

        let inconsistent_heads: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads h \
             LEFT JOIN record_versions v \
               ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
              AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
             WHERE h.vault_id=$1 \
               AND NOT EXISTS(SELECT 1 FROM record_redactions r \
                   WHERE r.vault_id=h.vault_id AND r.record_id=h.record_id) \
               AND (h.commit_seq<=0 OR h.commit_seq>$2 OR v.revision_id IS NULL OR v.envelope IS NULL)",
        )
        .bind(&vault_id)
        .bind(high_watermark)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if inconsistent_heads != 0 {
            return Err(ApiError::internal(
                "current record head does not match its committed revision sequence",
            ));
        }

        // JSON can expand control bytes in either identifier to six-byte
        // `\u00xx` escapes. Preflight the worst serialized identifier size
        // before SQLx transfers a large row into process memory.
        let oversized_head: bool = sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM record_heads h \
                 JOIN record_versions v \
                   ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                  AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
                 WHERE h.vault_id=$1 AND h.commit_seq<=$2 \
                   AND NOT EXISTS(SELECT 1 FROM record_redactions r \
                       WHERE r.vault_id=h.vault_id AND r.record_id=h.record_id) \
                   AND octet_length(h.record_id)::BIGINT * 6 \
                     + octet_length(h.revision_id)::BIGINT * 6 \
                     + octet_length(v.envelope)::BIGINT > $3 \
             )",
        )
        .bind(&vault_id)
        .bind(high_watermark)
        .bind(MAX_SYNC_SNAPSHOT_RESPONSE_BYTES as i64)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if oversized_head {
            return Err(snapshot_payload_too_large());
        }

        let snapshot_id = uuid::Uuid::new_v4().to_string();
        let created_at =
            chrono::DateTime::from_timestamp_micros(chrono::Utc::now().timestamp_micros())
                .ok_or_else(|| ApiError::internal("snapshot creation timestamp is out of range"))?;
        let expires_at = created_at + chrono::Duration::hours(24);
        let expires_at_wire = expires_at.to_rfc3339_opts(chrono::SecondsFormat::Micros, true);
        sqlx::query(
            "INSERT INTO snapshots( \
                 snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark, \
                 manifest_json,expires_at,created_at,server_generation \
             ) VALUES($1,$2,$3,$4,$5,'[]',$6,$7,$8)",
        )
        .bind(&snapshot_id)
        .bind(&vault_id)
        .bind(&user.user_id)
        .bind(high_watermark)
        .bind(conflict_high_watermark)
        .bind(expires_at)
        .bind(created_at)
        .bind(&generation)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut manifest = Vec::new();
        let mut manifest_budget = SnapshotManifestBudget::default();
        let mut item_count = 0i64;
        let mut legacy_fits = true;
        let mut last_record_id: Option<String> = None;
        loop {
            let rr_columns = redaction_columns("rr");
            let mut sql = format!(
                "SELECT manifest.record_id,manifest.kind,manifest.revision_id,manifest.deleted,\
                        manifest.commit_seq,manifest.envelope,{rr_columns} \
                 FROM (\
                   SELECT h.record_id,'head'::TEXT AS kind,h.revision_id,h.deleted,h.commit_seq,v.envelope,\
                          NULL::TEXT AS redaction_id,NULL::TEXT AS vault_id,\
                          NULL::TEXT AS redacted_record_id,NULL::TEXT AS deleted_revision_id,\
                          NULL::BIGINT AS deleted_seq,NULL::BIGINT AS redaction_seq \
                   FROM record_heads h JOIN record_versions v \
                     ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                    AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
                   WHERE h.vault_id=$1 AND h.commit_seq<=$2 \
                     AND NOT EXISTS(SELECT 1 FROM record_redactions red \
                       WHERE red.vault_id=h.vault_id AND red.record_id=h.record_id) \
                   UNION ALL \
                   SELECT red.record_id,'graveyard'::TEXT AS kind,red.deleted_revision_id,TRUE,\
                          red.deleted_seq,NULL::TEXT,red.redaction_id,red.vault_id,red.record_id,\
                          red.deleted_revision_id,red.deleted_seq,red.redaction_seq \
                   FROM record_redactions red WHERE red.vault_id=$1\
                 ) manifest LEFT JOIN record_redactions rr \
                   ON rr.redaction_id=manifest.redaction_id \
                 WHERE 1=1"
            );
            if last_record_id.is_some() {
                sql.push_str(" AND manifest.record_id COLLATE \"C\" > $3");
            }
            let record_limit_param = if last_record_id.is_some() { "$4" } else { "$3" };
            sql.push_str(" ORDER BY manifest.record_id COLLATE \"C\" LIMIT ");
            sql.push_str(record_limit_param);
            let mut query = sqlx::query(&sql).bind(&vault_id).bind(high_watermark);
            if let Some(last) = last_record_id.as_deref() {
                query = query.bind(last);
            }
            let Some(row) = query
                .bind(1i64)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
            else {
                break;
            };
            let record_id: String = row.get("record_id");
            let kind: String = row.get("kind");
            let item = if kind == "graveyard" {
                let statement = redaction_from_join_row(&row)?
                    .ok_or_else(|| ApiError::internal("snapshot graveyard row is incomplete"))?;
                // Snapshot storage contains only stable metadata. The current
                // instance key is applied when the page is serialized.
                json!({
                    "kind": "graveyard",
                    "record_id": statement.record_id,
                    "deleted_revision_id": statement.deleted_revision_id,
                    "deleted_seq": statement.deleted_seq.to_string(),
                })
            } else {
                let encoded: Option<String> = row.get("envelope");
                let encoded = encoded
                    .ok_or_else(|| ApiError::internal("snapshot head is missing its envelope"))?;
                let envelope =
                    serde_json::from_str::<Value>(&encoded).map_err(ApiError::internal)?;
                ensure_envelope_readable(user.declares_record_schema2, &envelope)?;
                json!({
                    "kind": "head",
                    "record_id": row.get::<String, _>("record_id"),
                    "revision_id": row.get::<String, _>("revision_id"),
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "deleted": row.get::<bool, _>("deleted"),
                    "envelope": envelope,
                })
            };
            let item_json = serde_json::to_string(&item).map_err(ApiError::internal)?;
            let page_item_budget = MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
                .saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES);
            if item_json.len() > page_item_budget {
                return Err(snapshot_payload_too_large());
            }
            sqlx::query(
                "INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES($1,$2,$3)",
            )
            .bind(&snapshot_id)
            .bind(&record_id)
            .bind(&item_json)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            item_count = item_count.saturating_add(1);
            if legacy_fits && manifest_budget.try_add(&item)? {
                manifest.push(item);
            } else if legacy_fits {
                legacy_fits = false;
                manifest.clear();
            }
            last_record_id = Some(record_id);
        }

        if legacy_fits {
            let manifest_json = serde_json::to_string(&manifest).map_err(ApiError::internal)?;
            sqlx::query(
                "UPDATE snapshots SET manifest_json=$2,snapshot_item_count=$3, \
                        snapshot_manifest_format='inline' WHERE snapshot_id=$1",
            )
            .bind(&snapshot_id)
            .bind(manifest_json)
            .bind(item_count)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        } else {
            sqlx::query(
                "UPDATE snapshots SET snapshot_item_count=$2, \
                        snapshot_manifest_format='paged' WHERE snapshot_id=$1",
            )
            .bind(&snapshot_id)
            .bind(item_count)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        tx.commit().await.map_err(ApiError::internal)?;

        // Preserve the SQLite route's commit-before-cursor behavior. An
        // encoding error must not roll back or hide the committed snapshot.
        let next_cursor =
            encode_cursor_with_key(&cursor_key, &generation, &vault_id, high_watermark)?;
        let response = json!({
            "snapshot_id": snapshot_id,
            "high_watermark": high_watermark.to_string(),
            "conflict_high_watermark": conflict_high_watermark.to_string(),
            "item_count": item_count,
            "next_cursor": next_cursor,
            "expires_at": expires_at_wire,
        });
        ensure_snapshot_response_fits(&response)?;
        Ok(response)
    }

    async fn read(&self, command: ReadSnapshotCommand) -> Result<Value, ApiError> {
        let ReadSnapshotCommand {
            user,
            snapshot_id,
            generation,
            cursor_key,
            page,
        } = command;

        // Discover the immutable Vault binding first, then repeat the
        // snapshot read after all authorization and deletion fences are held.
        let snapshot_vault: String =
            sqlx::query_scalar("SELECT vault_id FROM snapshots WHERE snapshot_id=$1")
                .bind(&snapshot_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(ApiError::internal)?
                .ok_or_else(ApiError::not_found)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        recheck_active_principal(&mut tx, &user).await?;
        lock_readable_vault(&mut tx, &user, &snapshot_vault).await?;
        require_redaction_client_for_vault_tx(&mut tx, &snapshot_vault, &user).await?;
        let row = sqlx::query(
            "SELECT snapshot_id,vault_id,high_watermark,conflict_high_watermark, \
                    snapshot_item_count,snapshot_manifest_format,redacted_at, \
                    expires_at,server_generation,expires_at <= clock_timestamp() AS expired \
             FROM snapshots WHERE snapshot_id=$1 AND vault_id=$2 FOR SHARE",
        )
        .bind(&snapshot_id)
        .bind(&snapshot_vault)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;

        let redacted_at: Option<chrono::DateTime<chrono::Utc>> = row.get("redacted_at");
        let high_watermark: i64 = row.get("high_watermark");
        let post_snapshot_redaction: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=$1 AND redaction_seq>$2)",
        )
        .bind(&snapshot_vault)
        .bind(high_watermark)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if redacted_at.is_some() || post_snapshot_redaction {
            return Err(ApiError::gone(
                "SNAPSHOT_REDACTED",
                "snapshot was invalidated because it contains a redacted record",
            )
            .with_details(json!({
                "recovery":"create_snapshot",
                "preserve_local_outbox":true
            })));
        }

        let snapshot_generation: String = row.get("server_generation");
        if snapshot_generation != generation {
            return Err(ApiError::gone(
                "SNAPSHOT_EXPIRED",
                "snapshot belongs to a previous server generation",
            )
            .with_details(json!({
                "recovery":"create_snapshot",
                "preserve_local_outbox":true
            })));
        }
        let expiry: chrono::DateTime<chrono::Utc> = row.get("expires_at");
        if row.get::<bool, _>("expired") {
            return Err(
                ApiError::gone("SNAPSHOT_EXPIRED", "snapshot has expired").with_details(json!({
                    "recovery":"create_snapshot",
                    "preserve_local_outbox":true
                })),
            );
        }

        let conflict_high_watermark: i64 = row.get("conflict_high_watermark");
        let stored_item_count: i64 = row.get("snapshot_item_count");
        // Only fetch the inline manifest after the redacted marker and
        // post-snapshot ledger fence above have been checked.
        let payload = sqlx::query(
            "SELECT manifest_json,octet_length(manifest_json)::BIGINT AS manifest_bytes \
             FROM snapshots WHERE snapshot_id=$1 AND vault_id=$2",
        )
        .bind(&snapshot_id)
        .bind(&snapshot_vault)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let manifest_json: String = payload.get("manifest_json");
        let stored_manifest_bytes: i64 = payload.get("manifest_bytes");
        if stored_manifest_bytes < 0
            || stored_manifest_bytes > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES as i64
        {
            return Err(snapshot_payload_too_large());
        }
        let snapshot_format: String = row.get("snapshot_manifest_format");
        if !matches!(snapshot_format.as_str(), "legacy" | "inline" | "paged") {
            return Err(ApiError::internal("snapshot manifest format is invalid"));
        }
        let mut response = json!({
            "snapshot_id": row.get::<String, _>("snapshot_id"),
            "server_generation": generation,
            "high_watermark": high_watermark.to_string(),
            "conflict_high_watermark": conflict_high_watermark.to_string(),
            "item_count": stored_item_count,
            "next_cursor": encode_cursor_with_key(
                &cursor_key,
                &generation,
                &snapshot_vault,
                high_watermark,
            )?,
            "expires_at": expiry.to_rfc3339_opts(chrono::SecondsFormat::Micros, true),
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
            let rr_columns = redaction_columns("rr");
            let mut sql = format!(
                "SELECT si.record_id,si.item_json,{rr_columns} \
                 FROM snapshot_items si JOIN snapshots s ON s.snapshot_id=si.snapshot_id \
                 LEFT JOIN record_redactions rr ON rr.vault_id=s.vault_id AND rr.record_id=si.record_id \
                 WHERE si.snapshot_id=$1"
            );
            if after_record_id.is_some() {
                sql.push_str(" AND si.record_id COLLATE \"C\" > $2");
            }
            let limit_param = if after_record_id.is_some() {
                "$3"
            } else {
                "$2"
            };
            sql.push_str(" ORDER BY si.record_id COLLATE \"C\" LIMIT ");
            sql.push_str(limit_param);
            let mut query = sqlx::query(&sql).bind(&snapshot_id);
            if let Some(after) = after_record_id.as_deref() {
                query = query.bind(after);
            }
            let mut rows = query.bind(page.limit + 1).fetch(&mut *tx);
            let mut manifest = Vec::new();
            let mut budget = SyncPageBudget::default();
            let mut has_more = false;
            let mut last_record_id = None;
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
            // The committed item count is immutable with the snapshot. Avoid
            // rescanning every item table on each page; verify the count once
            // when the caller reaches the terminal page.
            if !has_more {
                let actual_item_count: i64 =
                    sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=$1")
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
            ensure_snapshot_response_fits(&response)?;
        } else {
            let actual_item_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=$1")
                    .bind(&snapshot_id)
                    .fetch_one(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            if actual_item_count != stored_item_count {
                return Err(ApiError::internal(
                    "snapshot item count does not match its manifest",
                ));
            }
            if actual_item_count == 0 {
                if stored_manifest_bytes < 0
                    || stored_manifest_bytes > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES as i64
                {
                    return Err(snapshot_payload_too_large());
                }
                response["manifest"] =
                    serde_json::from_str::<Value>(&manifest_json).map_err(ApiError::internal)?;
                if let Some(items) = response["manifest"].as_array() {
                    for item in items {
                        if let Some(envelope) = item.get("envelope") {
                            ensure_envelope_readable(user.declares_record_schema2, envelope)?;
                        }
                    }
                }
                ensure_snapshot_response_fits(&response)?;
            } else {
                let item_bytes: i64 = sqlx::query_scalar(
                    "SELECT COALESCE(SUM(octet_length(item_json)),0)::BIGINT FROM snapshot_items WHERE snapshot_id=$1",
                )
                .bind(&snapshot_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                let manifest_len = item_bytes
                    .saturating_add(actual_item_count.saturating_sub(1))
                    .saturating_add(2);
                if item_bytes < 0
                    || manifest_len as usize
                        > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
                            .saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES)
                {
                    return Err(snapshot_payload_too_large());
                }
                let rr_columns = redaction_columns("rr");
                let rows_sql = format!(
                    "SELECT si.item_json,{rr_columns} \
                     FROM snapshot_items si JOIN snapshots s ON s.snapshot_id=si.snapshot_id \
                     LEFT JOIN record_redactions rr ON rr.vault_id=s.vault_id AND rr.record_id=si.record_id \
                     WHERE si.snapshot_id=$1 ORDER BY si.record_id COLLATE \"C\""
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
                ensure_snapshot_response_fits(&response)?;
            }
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }
}

impl SyncSnapshotsRepository for PgSyncSnapshotsRepository {
    fn create_snapshot(
        &self,
        command: CreateSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.create(command))
    }

    fn read_snapshot(
        &self,
        command: ReadSnapshotCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read(command))
    }
}

/// Rechecks and locks the HTTP principal rows in the same order used by the
/// PostgreSQL sync commit adapter. Revocation/account/device changes therefore
/// serialize before or after a snapshot operation.
async fn recheck_active_principal(
    tx: &mut Transaction<'_, sqlx::Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(tx, user).await
}

/// Mirrors SQLite's no-op Vault write fence, then requires an active member.
/// Deleting Vaults stay readable during their grace period; the row lock orders
/// snapshot reads/writes against a final purge transaction.
async fn lock_readable_vault(
    tx: &mut Transaction<'_, sqlx::Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    let vault = sqlx::query("SELECT state FROM vaults WHERE vault_id=$1 FOR UPDATE")
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    // State is intentionally not filtered here: SQLite's read fence permits
    // reads during the deletion grace period, with the lock ordering this
    // operation against the final purge.
    let _state: String = vault.get("state");

    let membership =
        sqlx::query("SELECT state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE")
            .bind(vault_id)
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if membership.is_none_or(|row| row.get::<String, _>("state") != "active") {
        return Err(ApiError::not_found());
    }
    Ok(())
}

fn snapshot_payload_too_large() -> ApiError {
    ApiError::too_large("snapshot manifest exceeds the maximum serialized response size")
        .with_details(json!({
            "max_response_bytes": MAX_SYNC_SNAPSHOT_RESPONSE_BYTES,
            "recovery": "contact_server_operator",
        }))
}

/// Enforces the bound on the final JSON body, including snapshot metadata and
/// cursor fields, rather than counting only the stored manifest column.
fn ensure_snapshot_response_fits(response: &Value) -> Result<(), ApiError> {
    let serialized_len = serde_json::to_vec(response)
        .map_err(ApiError::internal)?
        .len();
    if serialized_len > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES {
        return Err(snapshot_payload_too_large());
    }
    Ok(())
}

#[derive(Default)]
struct SnapshotManifestBudget {
    item_bytes: usize,
    item_count: usize,
}

impl SnapshotManifestBudget {
    /// Keeps the stored array below the full response cap with the shared
    /// space reserved for snapshot metadata, cursor and JSON wrapper.
    fn try_add(&mut self, item: &Value) -> Result<bool, ApiError> {
        let item_bytes = serde_json::to_vec(item).map_err(ApiError::internal)?.len();
        let separator_bytes = if self.item_count > 0 { 1 } else { 0 };
        let next = self
            .item_bytes
            .saturating_add(separator_bytes)
            .saturating_add(item_bytes);
        let manifest_budget =
            MAX_SYNC_SNAPSHOT_RESPONSE_BYTES.saturating_sub(SYNC_SNAPSHOT_METADATA_RESERVE_BYTES);
        if next > manifest_budget {
            return Ok(false);
        }
        self.item_bytes = next;
        self.item_count += 1;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use std::{str::FromStr, sync::Arc, time::Duration};

    use axum::http::StatusCode;
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::SigningKey;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;
    use crate::sync::parse_cursor_with_key;
    use crate::sync_repository::SnapshotPageRequest;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const RETENTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const SNAPSHOT_MIGRATION: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
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

    const USER_ID: &str = "pg-snapshot-user";
    const DEVICE_ID: &str = "pg-snapshot-device";
    const SESSION_ID: &str = "pg-snapshot-session";
    const ACCESS_HASH: &str = "pg-snapshot-access-hash";
    const VAULT_ID: &str = "e950523f-c2bd-42fb-a66c-d9c87d86d331";
    const GENERATION: &str = "4bcf11d5-99ed-49f3-8012-6f1d706edc91";
    const CURSOR_KEY: [u8; 32] = [0x5a; 32];

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema_cleanup: SchemaCleanupGuard,
    }

    /// Armed as soon as CREATE SCHEMA succeeds, so a pool, migration, or seed
    /// panic during fixture construction cannot strand an isolated schema.
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

        async fn cleanup(&mut self) -> Result<(), sqlx::Error> {
            if self.armed {
                sqlx::query(&format!(
                    "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                    self.schema
                ))
                .execute(&self.admin_pool)
                .await?;
                self.disarm();
            }
            Ok(())
        }
    }

    impl TestDatabase {
        async fn create() -> Self {
            let (options, admin_pool) = disposable_admin_pool().await;
            let schema = format!("atermius_pg_snapshots_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL snapshot schema");
            let mut schema_cleanup = SchemaCleanupGuard::new(admin_pool.clone(), schema.clone());
            let pool = match PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
            {
                Ok(pool) => pool,
                Err(error) => {
                    schema_cleanup
                        .cleanup()
                        .await
                        .expect("cleanup schema after isolated-pool setup failure");
                    panic!("connect isolated PostgreSQL search path: {error}");
                }
            };
            for migration in [
                CORE_MIGRATION,
                RETENTION_MIGRATION,
                CONFLICT_MIGRATION,
                SNAPSHOT_MIGRATION,
                SNAPSHOT_PAGES_MIGRATION,
            ] {
                if let Err(error) = sqlx::raw_sql(migration).execute(&pool).await {
                    pool.close().await;
                    schema_cleanup
                        .cleanup()
                        .await
                        .expect("cleanup schema after migration setup failure");
                    panic!("apply PostgreSQL snapshot prerequisite migration: {error}");
                }
            }
            if let Err(error) = sqlx::raw_sql(
                "CREATE TABLE atermius_instance_schema (\
                    singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                    schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                 ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
            )
            .execute(&pool)
            .await
            {
                pool.close().await;
                schema_cleanup
                    .cleanup()
                    .await
                    .expect("cleanup schema after version fixture setup failure");
                panic!("create PostgreSQL schema-version fixture: {error}");
            }
            if let Err(error) = sqlx::raw_sql(REDACTION_MIGRATION).execute(&pool).await {
                pool.close().await;
                schema_cleanup
                    .cleanup()
                    .await
                    .expect("cleanup schema after redaction migration failure");
                panic!("apply PostgreSQL record-redaction migration: {error}");
            }
            if let Err(error) = sqlx::raw_sql(REDACTED_CONFLICT_MIGRATION)
                .execute(&pool)
                .await
            {
                pool.close().await;
                schema_cleanup
                    .cleanup()
                    .await
                    .expect("cleanup schema after redacted-conflict migration failure");
                panic!("apply PostgreSQL redacted-conflict migration: {error}");
            }
            if let Err(error) = seed(&pool).await {
                pool.close().await;
                schema_cleanup
                    .cleanup()
                    .await
                    .expect("cleanup schema after seed setup failure");
                panic!("seed PostgreSQL snapshot fixture: {error}");
            }
            // Ownership of the armed guard transfers to TestDatabase only
            // after the schema, all migrations, and seed rows are complete.
            Self {
                pool,
                admin_pool,
                schema_cleanup,
            }
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            self.schema_cleanup
                .cleanup()
                .await
                .expect("drop isolated PostgreSQL snapshot schema");
            self.admin_pool.close().await;
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

    async fn disposable_admin_pool() -> (PgConnectOptions, PgPool) {
        let url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ignored PostgreSQL snapshot tests require ATERMIUS_TEST_PG_URL");
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
            .expect("connect disposable PostgreSQL test database");
        (options, admin_pool)
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn setup_failure_drops_the_armed_schema_guard() {
        let (_, admin_pool) = disposable_admin_pool().await;
        let schema = format!(
            "atermius_pg_snapshot_setup_failure_{}",
            Uuid::new_v4().simple()
        );
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .expect("create schema before the simulated setup failure");
        let mut guard = SchemaCleanupGuard::new(admin_pool.clone(), schema.clone());

        // Model a migration/setup error after the schema exists but before
        // TestDatabase has been constructed and can own cleanup itself.
        let setup_error = sqlx::raw_sql("CREATE TABLE intentionally_broken (")
            .execute(&admin_pool)
            .await;
        assert!(setup_error.is_err());
        guard
            .cleanup()
            .await
            .expect("cleanup schema after simulated setup failure");
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)")
                .bind(&schema)
                .fetch_one(&admin_pool)
                .await
                .unwrap();
        admin_pool.close().await;
        assert!(!exists, "setup failure left an isolated schema behind");
    }

    fn auth_user() -> AuthUser {
        AuthUser {
            user_id: USER_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: SESSION_ID.to_owned(),
            access_hash: ACCESS_HASH.to_owned(),
            declares_record_schema2: true,
            declares_sync_redaction_v1: true,
        }
    }

    fn proof_signer() -> PgRedactionProofSigner {
        let key = Arc::new(SigningKey::from_bytes(&[0x62; 32]));
        let instance = crate::InstanceInfo {
            instance_id: "3a25ea6e-53f5-47b6-9d82-97c43acb8a0b".to_owned(),
            server_space_id: "60fa13ac-45b6-449a-a980-b83d77a0f5b0".to_owned(),
            generation: GENERATION.to_owned(),
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
            signing_key_transitions: Vec::new(),
        };
        PgRedactionProofSigner::new(instance, key)
    }

    fn create_command(user: AuthUser) -> CreateSnapshotCommand {
        CreateSnapshotCommand {
            user,
            vault_id: VAULT_ID.to_owned(),
            generation: GENERATION.to_owned(),
            cursor_key: CURSOR_KEY,
        }
    }

    fn read_command(user: AuthUser, snapshot_id: &str) -> ReadSnapshotCommand {
        ReadSnapshotCommand {
            user,
            snapshot_id: snapshot_id.to_owned(),
            generation: GENERATION.to_owned(),
            cursor_key: CURSOR_KEY,
            page: None,
        }
    }

    async fn seed(pool: &PgPool) -> Result<(), sqlx::Error> {
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(USER_ID)
            .bind(format!("snapshot-{}", Uuid::new_v4()))
            .execute(pool)
            .await?;
        sqlx::query("INSERT INTO devices(device_id,user_id,status) VALUES($1,$2,'active')")
            .bind(DEVICE_ID)
            .bind(USER_ID)
            .execute(pool)
            .await?;
        sqlx::query(
            "INSERT INTO sessions( \
                 session_id,user_id,device_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at \
             ) VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP+INTERVAL '1 hour', \
                      CURRENT_TIMESTAMP+INTERVAL '1 day')",
        )
        .bind(SESSION_ID)
        .bind(USER_ID)
        .bind(DEVICE_ID)
        .bind(ACCESS_HASH)
        .bind(format!("refresh-{}", Uuid::new_v4()))
        .execute(pool)
        .await?;
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state) VALUES($1,$2,'active')")
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
        sqlx::query(
            "INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) \
             VALUES($1,0,0)",
        )
        .bind(VAULT_ID)
        .execute(pool)
        .await?;
        Ok(())
    }

    async fn insert_head(
        pool: &PgPool,
        record_id: &str,
        revision_id: &str,
        sequence: i64,
        deleted: bool,
        envelope: &str,
    ) {
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at \
             ) VALUES($1,$2,$3,$4,'digest',$5,$6,$7,CURRENT_TIMESTAMP)",
        )
        .bind(VAULT_ID)
        .bind(record_id)
        .bind(revision_id)
        .bind(envelope)
        .bind(sequence)
        .bind(DEVICE_ID)
        .bind(if deleted { "delete" } else { "create" })
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES($1,$2,$3,$4,$5)",
        )
        .bind(VAULT_ID)
        .bind(record_id)
        .bind(revision_id)
        .bind(deleted)
        .bind(sequence)
        .execute(pool)
        .await
        .unwrap();
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn empty_snapshot_roundtrips_and_cursor_is_generation_bound() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        assert_eq!(created["high_watermark"], "0");
        assert_eq!(created["conflict_high_watermark"], "0");
        let expires_at =
            chrono::DateTime::parse_from_rfc3339(created["expires_at"].as_str().unwrap()).unwrap();
        let remaining = expires_at.with_timezone(&chrono::Utc) - chrono::Utc::now();
        assert!(remaining <= chrono::Duration::hours(24));
        assert!(remaining > chrono::Duration::hours(23));

        let cursor = created["next_cursor"].as_str().unwrap();
        assert_eq!(
            parse_cursor_with_key(&CURSOR_KEY, GENERATION, VAULT_ID, cursor).unwrap(),
            0
        );
        assert!(
            parse_cursor_with_key(
                &CURSOR_KEY,
                "9a72d65c-9f1f-4c19-bf34-dc53c63bb95a",
                VAULT_ID,
                cursor,
            )
            .is_err()
        );

        let snapshot_id = created["snapshot_id"].as_str().unwrap();
        let read = repository
            .read(read_command(auth_user(), snapshot_id))
            .await
            .unwrap();
        assert_eq!(read["manifest"], json!([]));
        assert_eq!(read["high_watermark"], "0");
        assert_eq!(read["conflict_high_watermark"], "0");
        assert_eq!(read["next_cursor"], cursor);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn redacted_snapshot_manifest_contains_only_currently_signed_graveyard_metadata() {
        let database = TestDatabase::create().await;
        let repository =
            PgSyncSnapshotsRepository::with_signer(database.pool.clone(), proof_signer());
        let record_id = Uuid::new_v4().to_string();
        let deleted_revision_id = Uuid::new_v4().to_string();
        let redaction_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,2)")
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&deleted_revision_id)
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
            .bind(&deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();

        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        assert_eq!(created["item_count"], 1);
        let mut read = read_command(auth_user(), created["snapshot_id"].as_str().unwrap());
        read.page = Some(crate::sync_repository::SnapshotPageRequest {
            limit: 10,
            page_cursor: None,
        });
        let result = repository.read(read).await.unwrap();
        let items = result["manifest"].as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["kind"], "graveyard");
        assert_eq!(items[0]["record_id"], record_id);
        assert_eq!(items[0]["deleted_revision_id"], deleted_revision_id);
        assert_eq!(items[0]["deleted_seq"], "2");
        assert_eq!(items[0]["redaction"]["redaction_id"], redaction_id);
        assert!(items[0].get("envelope").is_none());
        assert!(items[0].get("revision_id").is_none());
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn multi_record_snapshot_preserves_deleted_heads_and_paired_watermarks() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        insert_head(
            &database.pool,
            "active-record",
            "active-revision",
            2,
            false,
            r#"{"ciphertext":"active"}"#,
        )
        .await;
        insert_head(
            &database.pool,
            "deleted-record",
            "deleted-revision",
            5,
            true,
            r#"{"ciphertext":"deleted-tombstone"}"#,
        )
        .await;
        sqlx::query(
            "UPDATE vault_counters SET last_committed_seq=8,last_conflict_seq=3 WHERE vault_id=$1",
        )
        .bind(VAULT_ID)
        .execute(&database.pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,conflict_seq) \
             VALUES('snapshot-conflict',$1,'conflict-record','{\"ciphertext\":\"conflict\"}', \
                    'digest',$2,3)",
        )
        .bind(VAULT_ID)
        .bind(DEVICE_ID)
        .execute(&database.pool)
        .await
        .unwrap();

        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        assert_eq!(created["high_watermark"], "8");
        assert_eq!(created["conflict_high_watermark"], "3");
        let read = repository
            .read(read_command(
                auth_user(),
                created["snapshot_id"].as_str().unwrap(),
            ))
            .await
            .unwrap();
        let manifest = read["manifest"].as_array().unwrap();
        assert_eq!(manifest.len(), 2);
        assert_eq!(manifest[0]["record_id"], "active-record");
        assert_eq!(manifest[0]["commit_seq"], "2");
        assert_eq!(manifest[0]["deleted"], false);
        assert_eq!(manifest[1]["record_id"], "deleted-record");
        assert_eq!(manifest[1]["commit_seq"], "5");
        assert_eq!(manifest[1]["deleted"], true);
        assert_eq!(read["conflict_high_watermark"], "3");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn create_rejects_single_oversized_head_before_storing_snapshot() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let envelope = json!({
            "ciphertext": "x".repeat(MAX_SYNC_SNAPSHOT_RESPONSE_BYTES),
        })
        .to_string();
        insert_head(
            &database.pool,
            "oversized-record",
            "oversized-revision",
            1,
            false,
            &envelope,
        )
        .await;
        sqlx::query("UPDATE vault_counters SET last_committed_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        let error = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(error.body.code, "PAYLOAD_TOO_LARGE");
        assert_eq!(
            error.body.details.as_ref().unwrap()["max_response_bytes"],
            MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
        );
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM snapshots")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn large_snapshot_pages_from_immutable_items_and_legacy_read_stays_bounded() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let envelope = json!({
            "ciphertext": "x".repeat(
                MAX_SYNC_SNAPSHOT_RESPONSE_BYTES / 2 + SYNC_SNAPSHOT_METADATA_RESERVE_BYTES,
            ),
        })
        .to_string();
        insert_head(
            &database.pool,
            "aggregate-a",
            "aggregate-revision-a",
            1,
            false,
            &envelope,
        )
        .await;
        insert_head(
            &database.pool,
            "aggregate-b",
            "aggregate-revision-b",
            2,
            false,
            &envelope,
        )
        .await;
        insert_head(
            &database.pool,
            "aggregate-c",
            "aggregate-revision-c",
            3,
            false,
            &envelope,
        )
        .await;
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = created["snapshot_id"].as_str().unwrap();
        let stored_count: i64 =
            sqlx::query_scalar("SELECT snapshot_item_count FROM snapshots WHERE snapshot_id=$1")
                .bind(snapshot_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(stored_count, 3);
        let legacy = repository
            .read(read_command(auth_user(), snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(legacy.status, StatusCode::PAYLOAD_TOO_LARGE);

        let first = repository
            .read(ReadSnapshotCommand {
                page: Some(SnapshotPageRequest {
                    limit: 1,
                    page_cursor: None,
                }),
                ..read_command(auth_user(), snapshot_id)
            })
            .await
            .unwrap();
        assert_eq!(first["server_generation"], GENERATION);
        assert_eq!(first["manifest"].as_array().unwrap().len(), 1);
        assert_eq!(first["manifest"][0]["record_id"], "aggregate-a");
        assert_eq!(first["has_more"], true);
        let second = repository
            .read(ReadSnapshotCommand {
                page: Some(SnapshotPageRequest {
                    limit: 1,
                    page_cursor: Some(first["next_page_cursor"].as_str().unwrap().to_owned()),
                }),
                ..read_command(auth_user(), snapshot_id)
            })
            .await
            .unwrap();
        assert_eq!(second["server_generation"], GENERATION);
        assert_eq!(second["manifest"].as_array().unwrap().len(), 1);
        assert_eq!(second["manifest"][0]["record_id"], "aggregate-b");
        assert_eq!(second["has_more"], true);
        let third = repository
            .read(ReadSnapshotCommand {
                page: Some(SnapshotPageRequest {
                    limit: 1,
                    page_cursor: Some(second["next_page_cursor"].as_str().unwrap().to_owned()),
                }),
                ..read_command(auth_user(), snapshot_id)
            })
            .await
            .unwrap();
        assert_eq!(third["server_generation"], GENERATION);
        assert_eq!(third["manifest"].as_array().unwrap().len(), 1);
        assert_eq!(third["manifest"][0]["record_id"], "aggregate-c");
        assert_eq!(third["has_more"], false);
        assert_eq!(third["next_page_cursor"], Value::Null);

        // The first page must not recount the entire immutable item set. A
        // terminal page still checks the committed item_count and rejects a
        // corrupt/missing row before traversal can complete.
        sqlx::query("DELETE FROM snapshot_items WHERE snapshot_id=$1 AND record_id='aggregate-c'")
            .bind(snapshot_id)
            .execute(&database.pool)
            .await
            .unwrap();
        let integrity_first = repository
            .read(ReadSnapshotCommand {
                page: Some(SnapshotPageRequest {
                    limit: 1,
                    page_cursor: None,
                }),
                ..read_command(auth_user(), snapshot_id)
            })
            .await
            .unwrap();
        assert_eq!(integrity_first["item_count"], 3);
        assert_eq!(integrity_first["has_more"], true);
        let integrity_terminal = repository
            .read(ReadSnapshotCommand {
                page: Some(SnapshotPageRequest {
                    limit: 1,
                    page_cursor: Some(
                        integrity_first["next_page_cursor"]
                            .as_str()
                            .unwrap()
                            .to_owned(),
                    ),
                }),
                ..read_command(auth_user(), snapshot_id)
            })
            .await
            .unwrap_err();
        assert_eq!(integrity_terminal.status, StatusCode::INTERNAL_SERVER_ERROR);

        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM snapshots")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(count, 1);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn read_rejects_wrapper_overflow_when_manifest_alone_fits() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = created["snapshot_id"].as_str().unwrap();

        // Leave only 32 bytes for all response metadata, which is too little
        // even though the stored manifest itself is within the byte limit.
        let target_len = MAX_SYNC_SNAPSHOT_RESPONSE_BYTES - 32;
        let empty_manifest = json!([{"padding": ""}]);
        let empty_len = serde_json::to_vec(&empty_manifest).unwrap().len();
        let manifest = json!([{
            "padding": "x".repeat(target_len - empty_len),
        }]);
        let manifest_json = serde_json::to_string(&manifest).unwrap();
        assert_eq!(manifest_json.len(), target_len);
        sqlx::query("UPDATE snapshots SET manifest_json=$2 WHERE snapshot_id=$1")
            .bind(snapshot_id)
            .bind(&manifest_json)
            .execute(&database.pool)
            .await
            .unwrap();

        let error = repository
            .read(read_command(auth_user(), snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(error.body.code, "PAYLOAD_TOO_LARGE");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn read_rejects_stored_manifest_over_limit() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = created["snapshot_id"].as_str().unwrap();
        let oversized_manifest =
            format!("[\"{}\"]", "x".repeat(MAX_SYNC_SNAPSHOT_RESPONSE_BYTES + 1));
        sqlx::query("UPDATE snapshots SET manifest_json=$2 WHERE snapshot_id=$1")
            .bind(snapshot_id)
            .bind(oversized_manifest)
            .execute(&database.pool)
            .await
            .unwrap();

        let error = repository
            .read(read_command(auth_user(), snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::PAYLOAD_TOO_LARGE);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn requested_by_account_delete_cascades_snapshot() {
        let database = TestDatabase::create().await;
        let requester_id = format!("snapshot-requester-{}", Uuid::new_v4());
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(&requester_id)
            .bind(format!("snapshot-requester-{}", Uuid::new_v4()))
            .execute(&database.pool)
            .await
            .unwrap();
        let snapshot_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO snapshots( \
                 snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark, \
                 manifest_json,expires_at,created_at,server_generation \
             ) VALUES($1,$2,$3,0,0,'[]',CURRENT_TIMESTAMP+INTERVAL '24 hours', \
                      CURRENT_TIMESTAMP,$4)",
        )
        .bind(&snapshot_id)
        .bind(VAULT_ID)
        .bind(&requester_id)
        .bind(GENERATION)
        .execute(&database.pool)
        .await
        .unwrap();

        sqlx::query("DELETE FROM users WHERE user_id=$1")
            .bind(&requester_id)
            .execute(&database.pool)
            .await
            .unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM snapshots WHERE snapshot_id=$1")
            .bind(snapshot_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn read_rejects_old_generation_and_expired_snapshot() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = created["snapshot_id"].as_str().unwrap();

        let old_generation = repository
            .read(ReadSnapshotCommand {
                user: auth_user(),
                snapshot_id: snapshot_id.to_owned(),
                generation: "9a72d65c-9f1f-4c19-bf34-dc53c63bb95a".to_owned(),
                cursor_key: CURSOR_KEY,
                page: None,
            })
            .await
            .unwrap_err();
        assert_eq!(old_generation.status, StatusCode::GONE);
        assert_eq!(old_generation.body.code, "SNAPSHOT_EXPIRED");

        sqlx::query("UPDATE snapshots SET expires_at=CURRENT_TIMESTAMP-INTERVAL '1 second' WHERE snapshot_id=$1")
            .bind(snapshot_id)
            .execute(&database.pool)
            .await
            .unwrap();
        let expired = repository
            .read(read_command(auth_user(), snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(expired.status, StatusCode::GONE);
        assert_eq!(expired.body.code, "SNAPSHOT_EXPIRED");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn invalid_current_head_is_rejected_without_persisting_snapshot() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES($1,'broken-record','missing-revision',FALSE,1)",
        )
        .bind(VAULT_ID)
        .execute(&database.pool)
        .await
        .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        let error = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(error.body.code, "INTERNAL");
        let stored: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM snapshots")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        assert_eq!(stored, 0);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn create_and_read_recheck_session_account_device_and_membership() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        let snapshot = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = snapshot["snapshot_id"].as_str().unwrap().to_owned();

        sqlx::query("UPDATE users SET status='disabled' WHERE user_id=$1")
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let disabled = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(disabled.status, StatusCode::UNAUTHORIZED);
        let disabled_read = repository
            .read(read_command(auth_user(), &snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(disabled_read.status, StatusCode::UNAUTHORIZED);
        sqlx::query("UPDATE users SET status='active' WHERE user_id=$1")
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let revoked_device = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(revoked_device.status, StatusCode::FORBIDDEN);
        let revoked_device_read = repository
            .read(read_command(auth_user(), &snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(revoked_device_read.status, StatusCode::FORBIDDEN);
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP WHERE session_id=$1")
            .bind(SESSION_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let revoked_session = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(revoked_session.status, StatusCode::UNAUTHORIZED);
        let revoked_session_read = repository
            .read(read_command(auth_user(), &snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(revoked_session_read.status, StatusCode::UNAUTHORIZED);
        sqlx::query("UPDATE sessions SET revoked_at=NULL WHERE session_id=$1")
            .bind(SESSION_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT_ID)
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let not_member = repository
            .create(create_command(auth_user()))
            .await
            .unwrap_err();
        assert_eq!(not_member.status, StatusCode::NOT_FOUND);
        let read_not_member = repository
            .read(read_command(auth_user(), &snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(read_not_member.status, StatusCode::NOT_FOUND);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn concurrent_revision_and_conflict_write_share_one_snapshot_fence() {
        let database = TestDatabase::create().await;
        let repository = std::sync::Arc::new(PgSyncSnapshotsRepository::new(database.pool.clone()));

        let mut writer = database.pool.begin().await.unwrap();
        sqlx::query("SELECT state FROM vaults WHERE vault_id=$1 FOR UPDATE")
            .bind(VAULT_ID)
            .fetch_one(&mut *writer)
            .await
            .unwrap();
        sqlx::query(
            "SELECT last_committed_seq,last_conflict_seq FROM vault_counters \
             WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(VAULT_ID)
        .fetch_one(&mut *writer)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at \
             ) VALUES($1,'racing-record','racing-revision','{\"ciphertext\":\"racing\"}', \
                      'digest',1,$2,'create',CURRENT_TIMESTAMP)",
        )
        .bind(VAULT_ID)
        .bind(DEVICE_ID)
        .execute(&mut *writer)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES($1,'racing-record','racing-revision',FALSE,1)",
        )
        .bind(VAULT_ID)
        .execute(&mut *writer)
        .await
        .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();

        let repository_for_snapshot = repository.clone();
        let snapshot_task = tokio::spawn(async move {
            repository_for_snapshot
                .create(create_command(auth_user()))
                .await
        });
        tokio::time::sleep(Duration::from_millis(75)).await;
        assert!(
            !snapshot_task.is_finished(),
            "snapshot must wait behind the Vault writer fence"
        );

        sqlx::query(
            "INSERT INTO conflicts( \
                 conflict_id,vault_id,record_id,envelope,digest,device_id,conflict_seq \
             ) VALUES('racing-conflict',$1,'racing-conflict-record', \
                      '{\"ciphertext\":\"conflict\"}','digest',$2,1)",
        )
        .bind(VAULT_ID)
        .bind(DEVICE_ID)
        .execute(&mut *writer)
        .await
        .unwrap();
        sqlx::query("UPDATE vault_counters SET last_conflict_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        writer.commit().await.unwrap();

        let created = snapshot_task.await.unwrap().unwrap();
        assert_eq!(created["high_watermark"], "1");
        assert_eq!(created["conflict_high_watermark"], "1");
        let read = repository
            .read(read_command(
                auth_user(),
                created["snapshot_id"].as_str().unwrap(),
            ))
            .await
            .unwrap();
        assert_eq!(read["manifest"][0]["record_id"], "racing-record");
        assert_eq!(read["high_watermark"], "1");
        assert_eq!(read["conflict_high_watermark"], "1");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable database"]
    async fn opaque_manifest_schema_gate_is_applied_on_create_and_read() {
        let database = TestDatabase::create().await;
        let repository = PgSyncSnapshotsRepository::new(database.pool.clone());
        insert_head(
            &database.pool,
            "schema-two-record",
            "schema-two-revision",
            1,
            false,
            r#"{"header":{"record_schema":2},"ciphertext":"opaque"}"#,
        )
        .await;
        sqlx::query("UPDATE vault_counters SET last_committed_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        let legacy_reader = AuthUser {
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
            ..auth_user()
        };
        let create_error = repository
            .create(create_command(legacy_reader.clone()))
            .await
            .unwrap_err();
        assert_eq!(create_error.status, StatusCode::CONFLICT);
        assert_eq!(create_error.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");

        let created = repository
            .create(create_command(auth_user()))
            .await
            .unwrap();
        let snapshot_id = created["snapshot_id"].as_str().unwrap();
        let read_error = repository
            .read(read_command(legacy_reader, snapshot_id))
            .await
            .unwrap_err();
        assert_eq!(read_error.status, StatusCode::CONFLICT);
        assert_eq!(read_error.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");
        database.cleanup().await;
    }
}

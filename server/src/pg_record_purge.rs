//! PostgreSQL owner initiated and internally maintained tombstone purge.
//!
//! This is a transactional writer only. It preserves sequence and receipt
//! rows, invalidates persisted snapshots before erasing payloads, and marks
//! unreferenced objects for the existing delayed collector. It does not run
//! automatic redaction collection.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{
    ApiError,
    auth::AuthUser,
    pg_record_redaction::{PgRedactionProofSigner, RedactionStatement},
    record_purge_actor::RecordPurgeActor,
};

#[derive(Clone)]
pub(crate) struct PgRecordPurgeRepository {
    pool: PgPool,
    signer: PgRedactionProofSigner,
}

impl PgRecordPurgeRepository {
    pub(crate) fn new(pool: PgPool, signer: PgRedactionProofSigner) -> Self {
        Self { pool, signer }
    }

    pub(crate) async fn purge(
        &self,
        user: &AuthUser,
        vault_id: &str,
        record_id: &str,
        expected_deleted_revision_id: &str,
        expected_deleted_seq: &str,
        object_gc_grace_seconds: i64,
    ) -> Result<Value, ApiError> {
        self.purge_as(
            RecordPurgeActor::Owner(user),
            vault_id,
            record_id,
            expected_deleted_revision_id,
            expected_deleted_seq,
            object_gc_grace_seconds,
        )
        .await
    }

    pub(crate) async fn set_auto_purge_policy(
        &self,
        user: &AuthUser,
        vault_id: &str,
        record_id: &str,
        expected_deleted_revision_id: &str,
        expected_deleted_seq: &str,
        expected_policy_revision: &str,
        enabled: bool,
    ) -> Result<Value, ApiError> {
        if !crate::is_canonical_uuid(vault_id)
            || !crate::is_canonical_uuid(record_id)
            || !crate::is_canonical_uuid(expected_deleted_revision_id)
        {
            return Err(ApiError::bad_request(
                "INVALID_AUTO_PURGE_POLICY",
                "Vault, record, and deleted revision IDs must be lowercase canonical UUIDs",
            ));
        }
        let expected_deleted_seq =
            crate::record_purge::parse_positive_sequence(expected_deleted_seq)?;
        let expected_policy_revision =
            crate::record_purge::parse_nonnegative_revision(expected_policy_revision)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let (owner_user_id, role) = lock_purge_writer_fence(&mut tx, user, vault_id).await?;
        if role != "owner" || owner_user_id != user.user_id {
            return Err(ApiError::forbidden(
                "VAULT_OWNER_REQUIRED",
                "only the active Vault owner can change automatic purge consent",
            ));
        }
        crate::pg_record_redaction::require_redaction_client_for_vault_tx(&mut tx, vault_id, user)
            .await?;

        let row = sqlx::query(
            "SELECT g.auto_purge_enabled,g.auto_purge_revision,h.revision_id,h.commit_seq, \
                    h.deleted,v.operation,v.restore_until, \
                    EXISTS(SELECT 1 FROM record_redactions rr WHERE rr.vault_id=g.vault_id \
                           AND rr.record_id=g.record_id) AS is_redacted \
             FROM record_graveyard g \
             JOIN record_heads h ON h.vault_id=g.vault_id AND h.record_id=g.record_id \
             JOIN record_versions v ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                                   AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
             WHERE g.vault_id=$1 AND g.record_id=$2 AND g.deleted_revision=$3 AND g.deleted_seq=$4 \
             FOR UPDATE OF g,h,v",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(expected_deleted_revision_id)
        .bind(expected_deleted_seq)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| {
            ApiError::conflict(
                "RECORD_TOMBSTONE_CHANGED",
                "the current tombstone no longer matches this automatic purge request",
            )
        })?;
        let current_revision: String = row.try_get("revision_id").map_err(ApiError::internal)?;
        let current_seq: i64 = row.try_get("commit_seq").map_err(ApiError::internal)?;
        let deleted: bool = row.try_get("deleted").map_err(ApiError::internal)?;
        let operation: String = row.try_get("operation").map_err(ApiError::internal)?;
        let restore_until: Option<DateTime<Utc>> =
            row.try_get("restore_until").map_err(ApiError::internal)?;
        let is_redacted: bool = row.try_get("is_redacted").map_err(ApiError::internal)?;
        if current_revision != expected_deleted_revision_id
            || current_seq != expected_deleted_seq
            || !deleted
            || operation != "delete"
            || restore_until.is_none()
            || is_redacted
        {
            return Err(ApiError::conflict(
                "RECORD_TOMBSTONE_CHANGED",
                "automatic purge consent applies only to the exact current retained tombstone",
            ));
        }
        let current_enabled: bool = row
            .try_get("auto_purge_enabled")
            .map_err(ApiError::internal)?;
        let current_policy_revision: i64 = row
            .try_get("auto_purge_revision")
            .map_err(ApiError::internal)?;
        if current_policy_revision != expected_policy_revision {
            return Err(ApiError::conflict(
                "RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT",
                "automatic purge consent changed since it was read",
            )
            .with_details(json!({"policy_revision":current_policy_revision.to_string()})));
        }

        let next_policy_revision = if current_enabled == enabled {
            current_policy_revision
        } else {
            let next = current_policy_revision.checked_add(1).ok_or_else(|| {
                ApiError::conflict(
                    "RECORD_AUTO_PURGE_POLICY_REVISION_EXHAUSTED",
                    "automatic purge consent revision cannot be advanced",
                )
            })?;
            let updated = sqlx::query(
                "UPDATE record_graveyard SET auto_purge_enabled=$1,auto_purge_revision=$2 \
                 WHERE vault_id=$3 AND record_id=$4 AND deleted_revision=$5 AND deleted_seq=$6 \
                   AND auto_purge_revision=$7",
            )
            .bind(enabled)
            .bind(next)
            .bind(vault_id)
            .bind(record_id)
            .bind(expected_deleted_revision_id)
            .bind(expected_deleted_seq)
            .bind(current_policy_revision)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if updated.rows_affected() != 1 {
                return Err(ApiError::conflict(
                    "RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT",
                    "automatic purge consent changed since it was read",
                ));
            }
            sqlx::query(
                "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action, \
                     resource_type,resource_id,result,occurred_at,source) \
                 VALUES('vault',$1,$2,$3,'vault.record_auto_purge_opt_in_changed', \
                        'record_auto_purge_policy',$4,'success',floor(extract(epoch from clock_timestamp()))::bigint,'api')",
            )
            .bind(vault_id)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(record_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            next
        };
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "vault_id":vault_id,
            "record_id":record_id,
            "deleted_revision_id":expected_deleted_revision_id,
            "deleted_seq":expected_deleted_seq.to_string(),
            "enabled":enabled,
            "policy_revision":next_policy_revision.to_string(),
        }))
    }

    /// Internal maintenance entry point. It intentionally has no synthesized
    /// owner/device identity; the exact persistent per-record opt-in policy
    /// and restore deadline are checked in the same transaction as this purge.
    pub(crate) async fn purge_for_maintenance(
        &self,
        vault_id: &str,
        record_id: &str,
        expected_deleted_revision_id: &str,
        expected_deleted_seq: &str,
        object_gc_grace_seconds: i64,
    ) -> Result<Value, ApiError> {
        self.purge_as(
            RecordPurgeActor::Maintenance,
            vault_id,
            record_id,
            expected_deleted_revision_id,
            expected_deleted_seq,
            object_gc_grace_seconds,
        )
        .await
    }

    async fn purge_as(
        &self,
        actor: RecordPurgeActor<'_>,
        vault_id: &str,
        record_id: &str,
        expected_deleted_revision_id: &str,
        expected_deleted_seq: &str,
        object_gc_grace_seconds: i64,
    ) -> Result<Value, ApiError> {
        if !crate::is_canonical_uuid(vault_id)
            || !crate::is_canonical_uuid(record_id)
            || !crate::is_canonical_uuid(expected_deleted_revision_id)
        {
            return Err(ApiError::bad_request(
                "INVALID_PURGE_REQUEST",
                "Vault, record, and deleted revision IDs must be lowercase canonical UUIDs",
            ));
        }
        let expected_deleted_seq =
            crate::record_purge::parse_positive_sequence(expected_deleted_seq)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let (owner_user_id, owner_role) = match actor {
            RecordPurgeActor::Owner(user) => {
                let (owner_user_id, role) =
                    lock_purge_writer_fence(&mut tx, user, vault_id).await?;
                (owner_user_id, Some((user, role)))
            }
            RecordPurgeActor::Maintenance => (
                lock_maintenance_writer_fence(&mut tx, vault_id).await?,
                None,
            ),
        };
        if let Some((user, role)) = owner_role
            && (role != "owner" || owner_user_id != user.user_id)
        {
            return Err(ApiError::forbidden(
                "VAULT_OWNER_REQUIRED",
                "only the active Vault owner can permanently purge a record",
            ));
        }

        // A lost-ACK retry is read-only and remains available if a device
        // report is later revoked. The route still requires the exact marker.
        if let Some(row) = sqlx::query(
            "SELECT redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq \
             FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        {
            let statement = statement_from_row(&row)?;
            if statement.deleted_revision_id != expected_deleted_revision_id
                || statement.deleted_seq != expected_deleted_seq
            {
                return Err(ApiError::conflict(
                    "RECORD_REDACTION_ID_MISMATCH",
                    "record is already purged with a different tombstone statement",
                ));
            }
            let proof = self.signer.proof(&statement)?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "status":"purged",
                "already_purged":true,
                "redaction":proof,
            }));
        }

        if matches!(actor, RecordPurgeActor::Maintenance) {
            let opted_in: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2 AND deleted_revision=$3 AND deleted_seq=$4 \
                   AND auto_purge_enabled=TRUE)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(expected_deleted_revision_id)
            .bind(expected_deleted_seq)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if !opted_in {
                return Err(ApiError::conflict(
                    "RECORD_AUTO_PURGE_NOT_ENABLED",
                    "the exact current tombstone has not been opted in for automatic purge",
                ));
            }
        }

        // Both actors must validate every active device's current signed
        // report before a new purge. Exact lost-ACK retries above remain
        // read-only and return the existing proof even if a report was later
        // invalidated.
        if !every_active_vault_device_supports_redaction_v1_tx(&mut tx, vault_id).await? {
            return Err(capability_required());
        }

        let current = sqlx::query(
            "SELECT h.revision_id,h.commit_seq,h.deleted,v.operation,v.restore_until, \
                    g.deleted_revision,g.deleted_seq \
             FROM record_heads h \
             JOIN record_graveyard g ON g.vault_id=h.vault_id AND g.record_id=h.record_id \
             JOIN record_versions v ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                                   AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
             WHERE h.vault_id=$1 AND h.record_id=$2 \
             FOR UPDATE OF h,g,v",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| {
            ApiError::conflict(
                "RECORD_NOT_PURGEABLE",
                "record does not have a current retained tombstone",
            )
        })?;
        let current_revision: String =
            current.try_get("revision_id").map_err(ApiError::internal)?;
        let current_seq: i64 = current.try_get("commit_seq").map_err(ApiError::internal)?;
        let grave_revision: String = current
            .try_get("deleted_revision")
            .map_err(ApiError::internal)?;
        let grave_seq: i64 = current.try_get("deleted_seq").map_err(ApiError::internal)?;
        let is_deleted: bool = current.try_get("deleted").map_err(ApiError::internal)?;
        let operation: String = current.try_get("operation").map_err(ApiError::internal)?;
        if !is_deleted
            || operation != "delete"
            || current_revision != expected_deleted_revision_id
            || grave_revision != expected_deleted_revision_id
            || current_seq != expected_deleted_seq
            || grave_seq != expected_deleted_seq
        {
            return Err(ApiError::conflict(
                "RECORD_DELETE_CHANGED",
                "the current deleted head no longer matches the requested tombstone",
            ));
        }

        let restore_until: Option<DateTime<Utc>> = current
            .try_get("restore_until")
            .map_err(ApiError::internal)?;
        let restore_until = restore_until
            .ok_or_else(|| ApiError::internal("current tombstone restore deadline is missing"))?;
        let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if !crate::sync::restore_deadline_elapsed(now, restore_until) {
            return Err(ApiError::conflict(
                "RECORD_PURGE_NOT_DUE",
                "the record restore period has not ended",
            )
            .with_details(json!({"restore_until":restore_until.to_rfc3339()})));
        }

        let unresolved: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM conflicts WHERE vault_id=$1 AND record_id=$2 \
             AND resolved_revision_id IS NULL",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if unresolved != 0 {
            return Err(ApiError::conflict(
                "RECORD_HAS_UNRESOLVED_CONFLICTS",
                "resolve or discard every conflict branch before permanently purging this record",
            ));
        }

        let version_rows = sqlx::query(
            "SELECT revision_id FROM record_versions WHERE vault_id=$1 AND record_id=$2 \
             ORDER BY revision_id",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut revision_ids = BTreeSet::new();
        for row in &version_rows {
            revision_ids.insert(
                row.try_get::<String, _>("revision_id")
                    .map_err(ApiError::internal)?,
            );
        }
        revision_ids.insert(expected_deleted_revision_id.to_owned());

        // Conflict object references use the attempted revision ID. Parse and
        // validate these IDs before any retained envelope is overwritten.
        let conflict_rows = sqlx::query(
            "SELECT conflict_id,envelope FROM conflicts WHERE vault_id=$1 AND record_id=$2 \
             ORDER BY conflict_id",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut conflict_revision_ids = BTreeSet::new();
        for row in &conflict_rows {
            let raw: Option<String> = row.try_get("envelope").map_err(ApiError::internal)?;
            let Some(raw) = raw else {
                return Err(reference_ambiguity());
            };
            let envelope: Value = serde_json::from_str(&raw).map_err(|_| reference_ambiguity())?;
            let revision_id = envelope
                .get("header")
                .and_then(|header| header.get("revision_id"))
                .and_then(Value::as_str)
                .filter(|value| crate::is_canonical_uuid(value))
                .ok_or_else(reference_ambiguity)?;
            conflict_revision_ids.insert(revision_id.to_owned());
        }
        revision_ids.extend(conflict_revision_ids.iter().cloned());

        // A conflict may retain a revision reference through its payload,
        // base_revision_id, or resolved_revision_id. Parse retained rows in
        // Rust so malformed legacy JSON fails closed instead of making a SQL
        // cast abort with an unrelated internal error.
        let foreign_conflict_rows = sqlx::query(
            "SELECT base_revision_id,resolved_revision_id,envelope FROM conflicts \
             WHERE vault_id=$1 AND record_id<>$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut foreign_conflict_revision_ids = BTreeSet::new();
        for row in &foreign_conflict_rows {
            if let Some(base_revision_id) = row
                .try_get::<Option<String>, _>("base_revision_id")
                .map_err(ApiError::internal)?
            {
                foreign_conflict_revision_ids.insert(base_revision_id);
            }
            if let Some(resolved_revision_id) = row
                .try_get::<Option<String>, _>("resolved_revision_id")
                .map_err(ApiError::internal)?
            {
                foreign_conflict_revision_ids.insert(resolved_revision_id);
            }
            let envelope: Option<String> = row.try_get("envelope").map_err(ApiError::internal)?;
            let Some(envelope) = envelope else {
                return Err(reference_ambiguity());
            };
            let envelope: Value =
                serde_json::from_str(&envelope).map_err(|_| reference_ambiguity())?;
            if let Some(revision_id) = envelope
                .get("header")
                .and_then(|header| header.get("revision_id"))
                .and_then(Value::as_str)
            {
                foreign_conflict_revision_ids.insert(revision_id.to_owned());
            }
        }

        // References are keyed by (Vault, revision ID), not record ID. A
        // duplicate legacy revision or conflict ID makes ownership
        // ambiguous, so reject before deleting any reference.
        for revision_id in &revision_ids {
            let foreign_version: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_versions \
                 WHERE vault_id=$1 AND record_id<>$3 \
                   AND (revision_id=$2 OR base_revision_id=$2))",
            )
            .bind(vault_id)
            .bind(revision_id)
            .bind(record_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let foreign_redaction: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_redacted_revisions \
                 WHERE vault_id=$1 AND revision_id=$2 AND record_id<>$3) \
                 OR EXISTS(SELECT 1 FROM record_redactions \
                 WHERE vault_id=$1 AND deleted_revision_id=$2 AND record_id<>$3)",
            )
            .bind(vault_id)
            .bind(revision_id)
            .bind(record_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let foreign_conflict = foreign_conflict_revision_ids.contains(revision_id);
            let foreign_change: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM change_events \
                 WHERE vault_id=$1 AND record_id<>$2 AND revision_id=$3)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let foreign_head: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_heads \
                 WHERE vault_id=$1 AND record_id<>$2 AND revision_id=$3)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let foreign_graveyard: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id<>$2 AND deleted_revision=$3)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let foreign_receipt: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM op_receipts \
                 WHERE vault_id=$1 AND record_id<>$2 AND revision_id=$3)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if foreign_version
                || foreign_redaction
                || foreign_conflict
                || foreign_change
                || foreign_head
                || foreign_graveyard
                || foreign_receipt
            {
                return Err(reference_ambiguity());
            }
        }

        // Lock the shared counter before allocating the one new event
        // position. All sync writers hold the Vault and counter fences too.
        sqlx::query("SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1 FOR UPDATE")
            .bind(vault_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("Vault sequence counter is missing"))?;
        let redaction_seq: i64 = sqlx::query_scalar(
            "UPDATE vault_counters SET last_committed_seq=last_committed_seq+1 \
             WHERE vault_id=$1 RETURNING last_committed_seq",
        )
        .bind(vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if redaction_seq <= expected_deleted_seq {
            return Err(ApiError::internal(
                "redaction sequence does not follow the deleted revision",
            ));
        }

        let redaction_id = uuid::Uuid::new_v4().to_string();
        let inserted_redaction = sqlx::query(
            "INSERT INTO record_redactions( \
                 redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at \
             ) VALUES($1,$2,$3,$4,$5,$6,$7)",
        )
        .bind(&redaction_id)
        .bind(vault_id)
        .bind(record_id)
        .bind(expected_deleted_revision_id)
        .bind(expected_deleted_seq)
        .bind(redaction_seq)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if inserted_redaction.rows_affected() != 1 {
            return Err(ApiError::internal(
                "redaction statement insert count changed",
            ));
        }
        if !conflict_revision_ids.is_empty() {
            let conflict_revision_ids: Vec<String> = conflict_revision_ids.into_iter().collect();
            sqlx::query(
                "INSERT INTO record_redacted_revisions(vault_id,record_id,revision_id) \
                 SELECT $1,$2,ids.revision_id FROM unnest($3::text[]) AS ids(revision_id) \
                 ON CONFLICT DO NOTHING",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(&conflict_revision_ids)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        let indexed_revision_ids: BTreeSet<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_redacted_revisions WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .into_iter()
        .collect();
        if indexed_revision_ids != revision_ids {
            return Err(ApiError::internal(
                "redacted revision index does not match the retained record history",
            ));
        }

        // Invalidate and erase every persisted snapshot before payload
        // scrubbing. Snapshot readers hold FOR SHARE on each snapshot row;
        // this UPDATE waits for a complete old page or makes it return 410.
        let snapshot_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM snapshots WHERE vault_id=$1")
                .bind(vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let snapshot_items_before: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM snapshot_items i JOIN snapshots s ON s.snapshot_id=i.snapshot_id \
             WHERE s.vault_id=$1",
        )
        .bind(vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let invalidated_snapshots = sqlx::query(
            "UPDATE snapshots SET redacted_at=$1,manifest_json='[]',snapshot_item_count=0, \
                    snapshot_manifest_format='expired' WHERE vault_id=$2",
        )
        .bind(now)
        .bind(vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if invalidated_snapshots.rows_affected() != snapshot_count as u64 {
            return Err(ApiError::internal("snapshot invalidation count changed"));
        }
        let erased_snapshot_items = sqlx::query(
            "DELETE FROM snapshot_items WHERE snapshot_id IN \
             (SELECT snapshot_id FROM snapshots WHERE vault_id=$1)",
        )
        .bind(vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if erased_snapshot_items.rows_affected() != snapshot_items_before as u64 {
            return Err(ApiError::internal("snapshot page erasure count changed"));
        }

        let scrubbed_versions = sqlx::query(
            "UPDATE record_versions SET base_revision_id=NULL,envelope='{}',digest='',device_id='' \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if scrubbed_versions.rows_affected() != version_rows.len() as u64 {
            return Err(ApiError::internal("record revision scrub count changed"));
        }
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let scrubbed_events = sqlx::query(
            "UPDATE change_events SET event_type='redacted',revision_id='',envelope='{}' \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if scrubbed_events.rows_affected() != event_count as u64 {
            return Err(ApiError::internal(
                "record change event scrub count changed",
            ));
        }
        let scrubbed_conflicts = sqlx::query(
            "UPDATE conflicts SET base_revision_id=NULL,envelope='{}',digest='',device_id='', \
                    resolved_revision_id=NULL,op_id=NULL WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(vault_id)
        .bind(record_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if scrubbed_conflicts.rows_affected() != conflict_rows.len() as u64 {
            return Err(ApiError::internal("record conflict scrub count changed"));
        }

        let revision_ids: Vec<String> = revision_ids.into_iter().collect();
        let object_ids: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT object_id FROM object_references WHERE vault_id=$1 \
             AND revision_id=ANY($2::text[]) ORDER BY object_id",
        )
        .bind(vault_id)
        .bind(&revision_ids)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let references_before: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=$1 AND revision_id=ANY($2::text[])",
        )
        .bind(vault_id)
        .bind(&revision_ids)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let deleted_references = sqlx::query(
            "DELETE FROM object_references WHERE vault_id=$1 AND revision_id=ANY($2::text[])",
        )
        .bind(vault_id)
        .bind(&revision_ids)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if deleted_references.rows_affected() != references_before as u64 {
            return Err(ApiError::internal("record object reference count changed"));
        }

        // Lock blob rows in stable object-ID order. A collector may finish an
        // already-due object first, or this transaction may move it into the
        // normal grace window; neither path can delete a still-referenced
        // attachment. Completed upload retries are revoked only when the
        // final Vault reference is gone.
        if !object_ids.is_empty() {
            let blob_rows = sqlx::query(
                "SELECT object_id FROM blob_objects WHERE vault_id=$1 AND object_id=ANY($2::text[]) \
                 ORDER BY object_id FOR UPDATE",
            )
            .bind(vault_id)
            .bind(&object_ids)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if blob_rows.len() != object_ids.len() {
                return Err(ApiError::internal("record object catalogue row is missing"));
            }
        }
        let gc_now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let gc_after = gc_now
            .timestamp()
            .saturating_add(object_gc_grace_seconds.max(0));
        for object_id in &object_ids {
            sqlx::query(
                "UPDATE blob_objects SET gc_after=$1 WHERE vault_id=$2 AND object_id=$3 \
                 AND storage_state='available' \
                 AND NOT EXISTS(SELECT 1 FROM object_references r \
                     WHERE r.vault_id=blob_objects.vault_id AND r.object_id=blob_objects.object_id)",
            )
            .bind(gc_after)
            .bind(vault_id)
            .bind(object_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query(
                "UPDATE uploads SET state='collected' WHERE vault_id=$1 AND object_id=$2 \
                 AND state='completed' \
                 AND NOT EXISTS(SELECT 1 FROM object_references r \
                     WHERE r.vault_id=uploads.vault_id AND r.object_id=uploads.object_id)",
            )
            .bind(vault_id)
            .bind(object_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        let deleted_head = sqlx::query(
            "DELETE FROM record_heads WHERE vault_id=$1 AND record_id=$2 \
             AND revision_id=$3 AND commit_seq=$4 AND deleted=TRUE",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(expected_deleted_revision_id)
        .bind(expected_deleted_seq)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if deleted_head.rows_affected() != 1 {
            return Err(ApiError::internal(
                "current tombstone head changed during purge",
            ));
        }
        sqlx::query(
            "UPDATE record_graveyard SET auto_purge_enabled=FALSE, \
                 auto_purge_revision=auto_purge_revision + CASE WHEN auto_purge_enabled THEN 1 ELSE 0 END \
             WHERE vault_id=$1 AND record_id=$2 AND deleted_revision=$3 AND deleted_seq=$4",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(expected_deleted_revision_id)
        .bind(expected_deleted_seq)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let appended_marker = sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES($1,$2,'record_redacted',$3,'','{}',$4)",
        )
        .bind(vault_id)
        .bind(redaction_seq)
        .bind(record_id)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if appended_marker.rows_affected() != 1 {
            return Err(ApiError::internal("redaction event insert count changed"));
        }
        match actor {
            RecordPurgeActor::Owner(user) => {
                crate::pg_sync_commit::enqueue_sync_available(&mut tx, vault_id, &user.device_id)
                    .await?;
            }
            RecordPurgeActor::Maintenance => {
                enqueue_all_sync_available(&mut tx, vault_id).await?;
            }
        }

        let (actor_user_id, actor_device_id, audit_source) = match actor {
            RecordPurgeActor::Owner(user) => (
                Some(user.user_id.as_str()),
                Some(user.device_id.as_str()),
                "api",
            ),
            RecordPurgeActor::Maintenance => (None, None, "maintenance"),
        };
        sqlx::query(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source) \
             VALUES('vault',$1,$2,$3,'vault.record_purged','record',$4,'success',$5,$6)",
        )
        .bind(vault_id)
        .bind(actor_user_id)
        .bind(actor_device_id)
        .bind(record_id)
        .bind(now.timestamp())
        .bind(audit_source)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        crate::pg_notifications::notify_sync_wake(&mut tx).await?;

        let statement = RedactionStatement {
            redaction_id,
            vault_id: vault_id.to_owned(),
            record_id: record_id.to_owned(),
            deleted_revision_id: expected_deleted_revision_id.to_owned(),
            deleted_seq: expected_deleted_seq,
            redaction_seq,
        };
        let proof = self.signer.proof(&statement)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status":"purged",
            "already_purged":false,
            "redaction":proof,
        }))
    }
}

/// The owner path rechecks the authenticated principal, takes the common
/// member/device/Vault fence, then locks and checks the owner's membership.
async fn lock_purge_writer_fence(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(String, String), ApiError> {
    crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(tx, user)
        .await?;

    let owner_user_id = lock_member_device_vault_fence(tx, vault_id).await?;
    let membership = sqlx::query(
        "SELECT role,state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    if membership
        .try_get::<String, _>("state")
        .map_err(ApiError::internal)?
        != "active"
    {
        return Err(ApiError::not_found());
    }
    let role: String = membership.try_get("role").map_err(ApiError::internal)?;
    if !matches!(role.as_str(), "owner" | "editor") {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    Ok((owner_user_id, role))
}

/// Maintenance omits the authenticated-principal and owner-role checks only.
/// It retains the complete database writer fence and signed capability report
/// validation. No production caller is wired until persistent per-record
/// opt-in is checked atomically with this transaction.
async fn lock_maintenance_writer_fence(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<String, ApiError> {
    lock_member_device_vault_fence(tx, vault_id).await
}

/// Locks every active member account and device in stable order, then the
/// Vault, then rechecks and share-locks the active membership/device set.
/// Account locks before Vault prevent concurrent enrollment from installing
/// an unexamined device; device locks serialize report updates and revocation.
/// A changed member/device set fails closed so retry observes the full set.
async fn lock_member_device_vault_fence(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<String, ApiError> {
    let candidate_users: Vec<String> = sqlx::query_scalar(
        "SELECT vm.user_id FROM vault_members vm JOIN users u ON u.user_id=vm.user_id \
         WHERE vm.vault_id=$1 AND vm.state='active' AND u.status='active' \
         ORDER BY vm.user_id",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if candidate_users.is_empty() {
        return Err(ApiError::not_found());
    }

    for member_user_id in &candidate_users {
        let status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(member_user_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
        if status.as_deref() != Some("active") {
            return Err(capability_required());
        }
    }
    let candidate_devices = sqlx::query(
        "SELECT d.user_id,d.device_id FROM devices d \
         WHERE d.user_id=ANY($1::text[]) AND d.status='active' \
         ORDER BY d.user_id,d.device_id",
    )
    .bind(&candidate_users)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut candidate_device_ids = Vec::with_capacity(candidate_devices.len());
    for row in &candidate_devices {
        let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
        let status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE user_id=$1 AND device_id=$2 FOR SHARE",
        )
        .bind(&user_id)
        .bind(&device_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if status.as_deref() != Some("active") {
            return Err(capability_required());
        }
        candidate_device_ids.push((user_id, device_id));
    }

    let vault = sqlx::query("SELECT state,owner_user_id FROM vaults WHERE vault_id=$1 FOR UPDATE")
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let owner_user_id: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
    match vault
        .try_get::<String, _>("state")
        .map_err(ApiError::internal)?
        .as_str()
    {
        "active" => {}
        "deleting" => return Err(ApiError::vault_deletion_pending()),
        _ => return Err(ApiError::not_found()),
    }

    let current_users: Vec<String> = sqlx::query_scalar(
        "SELECT vm.user_id FROM vault_members vm JOIN users u ON u.user_id=vm.user_id \
         WHERE vm.vault_id=$1 AND vm.state='active' AND u.status='active' \
         ORDER BY vm.user_id FOR SHARE OF vm",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if current_users != candidate_users {
        return Err(capability_required());
    }
    let current_devices = sqlx::query(
        "SELECT d.user_id,d.device_id FROM vault_members vm \
         JOIN users u ON u.user_id=vm.user_id JOIN devices d ON d.user_id=vm.user_id \
         WHERE vm.vault_id=$1 AND vm.state='active' AND u.status='active' AND d.status='active' \
         ORDER BY d.user_id,d.device_id",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .into_iter()
    .map(|row| {
        Ok::<_, ApiError>((
            row.try_get::<String, _>("user_id")
                .map_err(ApiError::internal)?,
            row.try_get::<String, _>("device_id")
                .map_err(ApiError::internal)?,
        ))
    })
    .collect::<Result<Vec<_>, _>>()?;
    if current_devices != candidate_device_ids {
        return Err(capability_required());
    }

    Ok(owner_user_id)
}

/// Maintenance cannot exclude an authenticated source device, so enqueue a
/// durable hint for every currently active endpoint in this Vault. The
/// writer fence is held and this statement is part of the purge transaction.
async fn enqueue_all_sync_available(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<(), ApiError> {
    let now = chrono::Utc::now().timestamp();
    sqlx::query(
        "INSERT INTO notification_push_outbox( \
             endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at,lease_id, \
             lease_until,dead_lettered,updated_at \
         ) SELECT e.endpoint_id,1,0,0,$1,NULL,NULL,FALSE,$1 \
           FROM notification_push_endpoints e \
           JOIN devices d ON d.device_id=e.device_id \
           JOIN users u ON u.user_id=e.user_id \
           JOIN vault_members vm ON vm.user_id=e.user_id \
           JOIN vaults v ON v.vault_id=vm.vault_id \
          WHERE vm.vault_id=$2 AND vm.state='active' AND v.state='active' \
            AND d.status='active' AND u.status='active' \
         ON CONFLICT(endpoint_id) DO UPDATE SET \
             requested_seq=notification_push_outbox.requested_seq+1, \
             attempt_count=0, \
             next_attempt_at=LEAST(notification_push_outbox.next_attempt_at,EXCLUDED.next_attempt_at), \
             dead_lettered=FALSE,updated_at=EXCLUDED.updated_at",
    )
    .bind(now)
    .bind(vault_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn every_active_vault_device_supports_redaction_v1_tx(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<bool, ApiError> {
    let devices = sqlx::query(
        "SELECT u.user_id,d.device_id,d.signing_public_key \
         FROM vault_members vm JOIN users u ON u.user_id=vm.user_id \
         JOIN devices d ON d.user_id=u.user_id AND d.status='active' \
         WHERE vm.vault_id=$1 AND vm.state='active' AND u.status='active' \
         ORDER BY u.user_id,d.device_id",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if devices.is_empty() {
        return Ok(false);
    }
    for row in devices {
        let account_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
        let signing_public_key: String = row
            .try_get("signing_public_key")
            .map_err(ApiError::internal)?;
        let report = sqlx::query(
            "SELECT revision,sync_redaction_version,signature,invalidated_at \
             FROM device_redaction_capability_reports \
             WHERE device_id=$1 AND account_id=$2 FOR SHARE",
        )
        .bind(&device_id)
        .bind(&account_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(report) = report else {
            return Ok(false);
        };
        let invalidated_at: Option<DateTime<Utc>> = report
            .try_get("invalidated_at")
            .map_err(ApiError::internal)?;
        if invalidated_at.is_some() {
            return Ok(false);
        }
        let report = crate::redaction_capabilities::RedactionCapabilityReport {
            format: crate::redaction_capabilities::REPORT_FORMAT.to_owned(),
            account_id: account_id.clone(),
            device_id: device_id.clone(),
            revision: report.try_get("revision").map_err(ApiError::internal)?,
            sync_redaction_version: report
                .try_get("sync_redaction_version")
                .map_err(ApiError::internal)?,
            signature: report.try_get("signature").map_err(ApiError::internal)?,
        };
        if crate::redaction_capabilities::validate_report(
            &report,
            &account_id,
            &device_id,
            &signing_public_key,
        )
        .is_err()
        {
            return Ok(false);
        }
    }
    Ok(true)
}

fn capability_required() -> ApiError {
    ApiError::conflict(
        "VAULT_REDACTION_CAPABILITY_REQUIRED",
        "every active device of every active Vault member must have a valid redaction v1 report",
    )
}

fn reference_ambiguity() -> ApiError {
    ApiError::conflict(
        "REDACTION_REFERENCE_AMBIGUOUS",
        "legacy revision or attachment ownership is ambiguous; record was not purged",
    )
}

fn statement_from_row(row: &sqlx::postgres::PgRow) -> Result<RedactionStatement, ApiError> {
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

#[cfg(test)]
mod tests {
    use std::{
        fs,
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        sync::Arc,
        time::Duration,
    };

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey, Verifier};
    use futures_util::FutureExt;
    use serde_json::json;
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgListener, PgPoolOptions},
    };
    use uuid::Uuid;

    use super::*;

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL purge test requires ATERMIUS_TEST_PG_URL");
            let parsed = url::Url::parse(&url).expect("valid PostgreSQL test URL");
            assert!(
                matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "::1")),
                "refusing non-loopback PostgreSQL test host"
            );
            let database = parsed.path().trim_start_matches('/');
            assert!(
                database.starts_with("atermius_test_"),
                "refusing database outside the disposable atermius_test_* namespace"
            );
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let admin_pool = PgPoolOptions::new()
                .max_connections(3)
                .connect_with(options.clone())
                .await
                .expect("connect to disposable PostgreSQL database");
            let schema = format!("atermius_pg_record_purge_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated purge test schema");
            let pool = PgPoolOptions::new()
                .max_connections(12)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
                .expect("connect to isolated purge test schema");
            let migration_dir =
                std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
            let mut migrations = fs::read_dir(&migration_dir)
                .expect("read PostgreSQL migrations")
                .map(|entry| entry.expect("read migration entry").path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "sql"))
                .collect::<Vec<_>>();
            migrations.sort();
            assert!(!migrations.is_empty(), "PostgreSQL migrations are present");
            for migration in migrations {
                let sql = fs::read_to_string(&migration).expect("read PostgreSQL migration");
                sqlx::raw_sql(&sql)
                    .execute(&pool)
                    .await
                    .unwrap_or_else(|error| {
                        panic!(
                            "apply PostgreSQL migration {}: {error}",
                            migration.display()
                        )
                    });
            }
            Self {
                pool,
                admin_pool,
                schema,
                cleaned: false,
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
            .expect("drop isolated purge test schema");
            self.admin_pool.close().await;
            self.cleaned = true;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let pool = self.pool.clone();
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    pool.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                });
            }
        }
    }

    async fn with_database<F, Fut>(run: F)
    where
        F: FnOnce(TestDatabase) -> Fut,
        Fut: std::future::Future<Output = ()>,
    {
        let database = TestDatabase::create().await;
        let result = AssertUnwindSafe(run(database)).catch_unwind().await;
        if let Err(payload) = result {
            resume_unwind(payload);
        }
    }

    fn report_signature(key: &SigningKey, user_id: &str, device_id: &str) -> String {
        let payload = json!({
            "format": crate::redaction_capabilities::REPORT_FORMAT,
            "account_id": user_id,
            "device_id": device_id,
            "revision": 1,
            "sync_redaction_version": 1,
        });
        URL_SAFE_NO_PAD.encode(key.sign(&crate::jcs(&payload).unwrap()).to_bytes())
    }

    fn signer(key: Arc<SigningKey>, published_key: String) -> PgRedactionProofSigner {
        PgRedactionProofSigner::new(
            crate::InstanceInfo {
                instance_id: Uuid::new_v4().to_string(),
                server_space_id: Uuid::new_v4().to_string(),
                generation: Uuid::new_v4().to_string(),
                signing_public_key: published_key,
                signing_key_transitions: Vec::new(),
            },
            key,
        )
    }

    pub(super) async fn seed_purge_fixture(pool: &PgPool) -> (String, String, String, Vec<String>) {
        let vault_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let deleted_revision_id = Uuid::new_v4().to_string();
        let owner_id = Uuid::new_v4().to_string();
        let member_id = Uuid::new_v4().to_string();
        let owner_device_id = Uuid::new_v4().to_string();
        let member_device_id = Uuid::new_v4().to_string();
        let owner_key = SigningKey::from_bytes(&[0x21; 32]);
        let member_key = SigningKey::from_bytes(&[0x22; 32]);

        for (user_id, username) in [(&owner_id, "purge-owner"), (&member_id, "purge-member")] {
            sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
                .bind(user_id)
                .bind(format!("{username}-{}@example.test", Uuid::new_v4()))
                .execute(pool)
                .await
                .unwrap();
        }
        for (user_id, device_id, key) in [
            (&owner_id, &owner_device_id, &owner_key),
            (&member_id, &member_device_id, &member_key),
        ] {
            let signing_public_key = URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes());
            sqlx::query(
                "INSERT INTO devices(device_id,user_id,name,signing_public_key,status) \
                 VALUES($1,$2,'maintenance purge test',$3,'active')",
            )
            .bind(device_id)
            .bind(user_id)
            .bind(signing_public_key)
            .execute(pool)
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO device_redaction_capability_reports( \
                     device_id,account_id,revision,sync_redaction_version,signature \
                 ) VALUES($1,$2,1,1,$3)",
            )
            .bind(device_id)
            .bind(user_id)
            .bind(report_signature(key, user_id, device_id))
            .execute(pool)
            .await
            .unwrap();
        }
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state) VALUES($1,$2,'active')")
            .bind(&vault_id)
            .bind(&owner_id)
            .execute(pool)
            .await
            .unwrap();
        for (user_id, role) in [(&owner_id, "owner"), (&member_id, "editor")] {
            sqlx::query(
                "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,$3,'active')",
            )
            .bind(&vault_id)
            .bind(user_id)
            .bind(role)
            .execute(pool)
            .await
            .unwrap();
        }
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES($1,2)")
            .bind(&vault_id)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES($1,$2,$3,NULL,'{}','delete-digest',2,'historical-device','delete', \
                      clock_timestamp()-interval '40 days',clock_timestamp()-interval '1 second')",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES($1,$2,$3,TRUE,2)",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
             VALUES($1,$2,$3,2)",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES($1,2,'record_deleted',$2,$3,'{}',clock_timestamp()-interval '40 days')",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(pool)
        .await
        .unwrap();

        let snapshot_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark, \
                 conflict_high_watermark,manifest_json,expires_at,server_generation, \
                 snapshot_item_count,snapshot_manifest_format) \
             VALUES($1,$2,$3,2,0,$4,clock_timestamp()+interval '1 day',$5,1,'paged')",
        )
        .bind(&snapshot_id)
        .bind(&vault_id)
        .bind(&owner_id)
        .bind(json!([{"record_id":record_id}]).to_string())
        .bind(Uuid::new_v4().to_string())
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES($1,$2,$3)")
            .bind(snapshot_id)
            .bind(&record_id)
            .bind(json!({"record_id":record_id}).to_string())
            .execute(pool)
            .await
            .unwrap();

        let endpoint_ids = vec![
            "maintenance-purge-owner-endpoint".to_owned(),
            "maintenance-purge-member-endpoint".to_owned(),
        ];
        for (index, (endpoint_id, device_id, user_id)) in [
            (&endpoint_ids[0], &owner_device_id, &owner_id),
            (&endpoint_ids[1], &member_device_id, &member_id),
        ]
        .into_iter()
        .enumerate()
        {
            sqlx::query(
                "INSERT INTO notification_push_endpoints( \
                     endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at \
                 ) VALUES($1,$2,$3,'apns',$4,repeat('x',80),0,0)",
            )
            .bind(endpoint_id)
            .bind(device_id)
            .bind(user_id)
            .bind(format!("{}", char::from(b'a' + index as u8).to_string().repeat(64)))
            .execute(pool)
            .await
            .unwrap();
        }

        (vault_id, record_id, deleted_revision_id, endpoint_ids)
    }

    async fn owner_auth_actor(pool: &PgPool, vault_id: &str) -> crate::auth::AuthUser {
        let row = sqlx::query(
            "SELECT vm.user_id,d.device_id FROM vault_members vm \
             JOIN devices d ON d.user_id=vm.user_id \
             WHERE vm.vault_id=$1 AND vm.role='owner' AND vm.state='active' \
             ORDER BY d.device_id LIMIT 1",
        )
        .bind(vault_id)
        .fetch_one(pool)
        .await
        .unwrap();
        let user_id: String = row.try_get("user_id").unwrap();
        let device_id: String = row.try_get("device_id").unwrap();
        let session_id = Uuid::new_v4().to_string();
        let token = format!("auto-purge-race-{}", Uuid::new_v4());
        let access_hash = crate::sha256_hex(token.as_bytes());
        sqlx::query(
            "INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at) \
             VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+interval '1 hour', \
                    clock_timestamp()+interval '1 day')",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(&access_hash)
        .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
        .execute(pool)
        .await
        .unwrap();
        crate::auth::AuthUser {
            user_id,
            device_id,
            session_id,
            access_hash,
            declares_record_schema2: true,
            declares_sync_redaction_v1: true,
        }
    }

    #[tokio::test]
    #[ignore = "direct PostgreSQL maintenance purge acceptance; run with the disposable PG test script"]
    async fn pg_maintenance_purge_uses_null_audit_identity_all_endpoint_outbox_and_retry_contract()
    {
        with_database(|database| async move {
            let (vault_id, record_id, deleted_revision_id, endpoint_ids) =
                seed_purge_fixture(&database.pool).await;
            let valid_key = Arc::new(SigningKey::from_bytes(&[0x31; 32]));
            let valid_public_key = URL_SAFE_NO_PAD.encode(valid_key.verifying_key().as_bytes());
            let invalid_signer = PgRecordPurgeRepository::new(
                database.pool.clone(),
                signer(valid_key.clone(), URL_SAFE_NO_PAD.encode([0x99; 32])),
            );
            let valid_repository = PgRecordPurgeRepository::new(
                database.pool.clone(),
                signer(valid_key.clone(), valid_public_key),
            );
            let actor_rows = sqlx::query(
                "SELECT vm.user_id,vm.role,d.device_id FROM vault_members vm \
                 JOIN devices d ON d.user_id=vm.user_id WHERE vm.vault_id=$1 \
                 ORDER BY vm.role DESC",
            )
            .bind(&vault_id)
            .fetch_all(&database.pool)
            .await
            .unwrap();
            let mut actors = std::collections::BTreeMap::new();
            for row in actor_rows {
                let user_id: String = row.try_get("user_id").unwrap();
                let device_id: String = row.try_get("device_id").unwrap();
                let role: String = row.try_get("role").unwrap();
                let session_id = Uuid::new_v4().to_string();
                let token = format!("auto-purge-policy-{role}-{}", Uuid::new_v4());
                let access_hash = crate::sha256_hex(token.as_bytes());
                sqlx::query(
                    "INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
                         access_expires_at,refresh_expires_at) \
                     VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+interval '1 hour', \
                            clock_timestamp()+interval '1 day')",
                )
                .bind(&session_id)
                .bind(&user_id)
                .bind(&device_id)
                .bind(Uuid::new_v4().to_string())
                .bind(&access_hash)
                .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
                .execute(&database.pool)
                .await
                .unwrap();
                actors.insert(
                    role,
                    crate::auth::AuthUser {
                        user_id,
                        device_id,
                        session_id,
                        access_hash,
                        declares_record_schema2: true,
                        declares_sync_redaction_v1: true,
                    },
                );
            }
            let owner_actor = actors.get("owner").unwrap();
            let editor_actor = actors.get("editor").unwrap();
            let initial_policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(initial_policy, (false, 0));
            let editor_write = valid_repository
                .set_auto_purge_policy(
                    editor_actor,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "0",
                    true,
                )
                .await
                .unwrap_err();
            assert_eq!(editor_write.body.code, "VAULT_OWNER_REQUIRED");
            let enabled = valid_repository
                .set_auto_purge_policy(
                    owner_actor,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "0",
                    true,
                )
                .await
                .unwrap();
            assert_eq!(enabled["enabled"], true);
            assert_eq!(enabled["policy_revision"], "1");
            let no_op = valid_repository
                .set_auto_purge_policy(
                    owner_actor,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "1",
                    true,
                )
                .await
                .unwrap();
            assert_eq!(no_op["policy_revision"], "1");
            let stale = valid_repository
                .set_auto_purge_policy(
                    owner_actor,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "0",
                    false,
                )
                .await
                .unwrap_err();
            assert_eq!(
                stale.body.code,
                "RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT"
            );
            let disabled = valid_repository
                .set_auto_purge_policy(
                    owner_actor,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "1",
                    false,
                )
                .await
                .unwrap();
            assert_eq!(disabled["enabled"], false);
            assert_eq!(disabled["policy_revision"], "2");
            let policy_audit_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                 AND action='vault.record_auto_purge_opt_in_changed' AND resource_id=$2 \
                 AND source='api' AND actor_user_id=$3 AND actor_device_id=$4",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&owner_actor.user_id)
            .bind(&owner_actor.device_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(policy_audit_count, 2);
            let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
            listener.listen("atermius_sync_wake_v1").await.unwrap();

            let default_off = valid_repository
                .purge_for_maintenance(
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    60,
                )
                .await
                .unwrap_err();
            assert_eq!(default_off.body.code, "RECORD_AUTO_PURGE_NOT_ENABLED");
            let default_policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(default_policy, (false, 2));
            sqlx::query(
                "UPDATE record_graveyard SET auto_purge_enabled=TRUE,auto_purge_revision=3 \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .execute(&database.pool)
            .await
            .unwrap();

            // A new maintenance purge must still require a current report
            // from every active endpoint before changing any persisted row.
            sqlx::query(
                "UPDATE device_redaction_capability_reports SET invalidated_at=clock_timestamp() \
                 WHERE account_id=(SELECT owner_user_id FROM vaults WHERE vault_id=$1)",
            )
            .bind(&vault_id)
            .execute(&database.pool)
            .await
            .unwrap();
            let missing_report = valid_repository
                .purge_for_maintenance(
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    60,
                )
                .await
                .unwrap_err();
            assert_eq!(missing_report.body.code, "VAULT_REDACTION_CAPABILITY_REQUIRED");
            sqlx::query(
                "UPDATE device_redaction_capability_reports SET invalidated_at=NULL WHERE account_id=( \
                     SELECT owner_user_id FROM vaults WHERE vault_id=$1)",
            )
            .bind(&vault_id)
            .execute(&database.pool)
            .await
            .unwrap();

            // Proof signing is deliberately made to fail after outbox, audit,
            // and pg_notify have run. The transaction must roll all of them
            // back, and PostgreSQL must not publish the queued notification.
            let failed = invalid_signer
                .purge_for_maintenance(
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    60,
                )
                .await
                .unwrap_err();
            assert_eq!(failed.body.code, "INTERNAL");
            let redactions: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            let counter: i64 = sqlx::query_scalar(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            let audit_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                 AND action='vault.record_purged' AND source='maintenance'",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            let outbox_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=ANY($1::text[])",
            )
            .bind(&endpoint_ids)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            let snapshot_redacted: Option<chrono::DateTime<Utc>> = sqlx::query_scalar(
                "SELECT redacted_at FROM snapshots WHERE vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!((redactions, counter, audit_count, outbox_count), (0, 2, 0, 0));
            assert_eq!(snapshot_redacted, None);
            let rollback_policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(rollback_policy, (true, 3));
            assert!(tokio::time::timeout(Duration::from_millis(150), listener.recv())
                .await
                .is_err());

            let success = valid_repository
                .purge_for_maintenance(
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    60,
                )
                .await
                .unwrap();
            assert_eq!(success["status"], "purged");
            assert_eq!(success["already_purged"], false);
            let consumed_policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(consumed_policy, (false, 4));
            let notification = listener.recv().await.unwrap();
            assert_eq!(notification.channel(), "atermius_sync_wake_v1");
            assert_eq!(notification.payload(), "");

            let audit: (Option<String>, Option<String>, String, String, String, Option<String>, String) =
                sqlx::query_as(
                    "SELECT actor_user_id,actor_device_id,source,action,resource_type,resource_id,result \
                     FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                       AND action='vault.record_purged' AND source='maintenance'",
                )
                .bind(&vault_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
            assert_eq!(
                audit,
                (
                    None,
                    None,
                    "maintenance".to_owned(),
                    "vault.record_purged".to_owned(),
                    "record".to_owned(),
                    Some(record_id.clone()),
                    "success".to_owned(),
                )
            );

            let queued: Vec<(String, i64)> = sqlx::query_as(
                "SELECT endpoint_id,requested_seq FROM notification_push_outbox \
                 WHERE endpoint_id=ANY($1::text[]) ORDER BY endpoint_id",
            )
            .bind(&endpoint_ids)
            .fetch_all(&database.pool)
            .await
            .unwrap();
            let mut expected_queued = endpoint_ids
                .iter()
                .cloned()
                .map(|id| (id, 1))
                .collect::<Vec<_>>();
            expected_queued.sort();
            assert_eq!(queued, expected_queued);
            let redacted_snapshot: (Option<chrono::DateTime<Utc>>, String, i64, String) =
                sqlx::query_as(
                    "SELECT redacted_at,manifest_json,snapshot_item_count,snapshot_manifest_format \
                     FROM snapshots WHERE vault_id=$1",
                )
                .bind(&vault_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
            assert!(redacted_snapshot.0.is_some());
            assert_eq!(
                (redacted_snapshot.1, redacted_snapshot.2, redacted_snapshot.3),
                ("[]".to_owned(), 0, "expired".to_owned())
            );
            let snapshot_items: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM snapshot_items i JOIN snapshots s USING(snapshot_id) WHERE s.vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(snapshot_items, 0);

            // A lost-ACK retry remains read-only even after a report is
            // invalidated; it returns the immutable proof and does not bump
            // the sequence, create a second audit, or enqueue duplicate work.
            sqlx::query(
                "UPDATE device_redaction_capability_reports SET invalidated_at=clock_timestamp() \
                 WHERE account_id=(SELECT owner_user_id FROM vaults WHERE vault_id=$1)",
            )
            .bind(&vault_id)
            .execute(&database.pool)
            .await
            .unwrap();
            let retry = valid_repository
                .purge_for_maintenance(
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    60,
                )
                .await
                .unwrap();
            assert_eq!(retry["already_purged"], true);
            assert_eq!(retry["redaction"], success["redaction"]);
            let retry_state: (i64, i64, i64) = sqlx::query_as(
                "SELECT (SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1), \
                        (SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                          AND action='vault.record_purged' AND source='maintenance'), \
                        (SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1)",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(retry_state, (3, 1, 1));
            let queued_after_retry: Vec<(String, i64)> = sqlx::query_as(
                "SELECT endpoint_id,requested_seq FROM notification_push_outbox \
                 WHERE endpoint_id=ANY($1::text[]) ORDER BY endpoint_id",
            )
            .bind(&endpoint_ids)
            .fetch_all(&database.pool)
            .await
            .unwrap();
            assert_eq!(queued_after_retry, queued);
            assert!(tokio::time::timeout(Duration::from_millis(150), listener.recv())
                .await
                .is_err(), "exact retry must not publish another PostgreSQL wake");

            drop(listener);
            database.cleanup().await;
        })
        .await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_uses_real_maintenance_purge_and_exact_proof_retry() {
        with_database(|database| async move {
            let (vault_id, record_id, deleted_revision_id, endpoint_ids) =
                seed_purge_fixture(&database.pool).await;
            sqlx::query(
                "UPDATE record_graveyard SET auto_purge_enabled=TRUE,auto_purge_revision=1 \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .execute(&database.pool)
            .await
            .unwrap();

            // Fail only the terminal checkpoint, after the real purge route
            // has committed. This exercises the durable pending identity and
            // the exact redaction receipt retry after a lost checkpoint ACK.
            sqlx::raw_sql(
                "CREATE FUNCTION fail_auto_purge_terminal_checkpoint() RETURNS trigger \
                 LANGUAGE plpgsql AS $$ \
                 BEGIN \
                   IF OLD.pending_record_id IS NOT NULL AND NEW.pending_record_id IS NULL \
                      AND NEW.after_record_id=OLD.pending_record_id THEN \
                     RAISE EXCEPTION 'test-only terminal checkpoint failure'; \
                   END IF; \
                   RETURN NEW; \
                 END $$; \
                 CREATE TRIGGER fail_auto_purge_terminal_checkpoint \
                 BEFORE UPDATE ON record_auto_purge_vault_cursors \
                 FOR EACH ROW EXECUTE FUNCTION fail_auto_purge_terminal_checkpoint();",
            )
            .execute(&database.pool)
            .await
            .unwrap();

            let signing_key = Arc::new(SigningKey::from_bytes(&[0x41; 32]));
            let published_key = URL_SAFE_NO_PAD.encode(signing_key.verifying_key().as_bytes());
            let purge = PgRecordPurgeRepository::new(
                database.pool.clone(),
                signer(signing_key.clone(), published_key),
            );
            let scan = crate::pg_record_auto_purge_scan::PgRecordAutoPurgeScanRepository::new(
                database.pool.clone(),
                purge.clone(),
            );
            let failed = scan.scan_batch(1, 1, 60, 60).await.unwrap_err();
            assert_eq!(failed.body.code, "INTERNAL");

            let failed_checkpoint: (
                Option<String>,
                Option<String>,
                Option<i64>,
                String,
                i64,
            ) = sqlx::query_as(
                "SELECT c.after_record_id,c.pending_record_id,c.pending_deleted_seq, \
                        s.last_scan_status,s.last_scan_candidates \
                 FROM record_auto_purge_vault_cursors c \
                 JOIN record_auto_purge_scan_control s ON s.singleton=1 WHERE c.vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(failed_checkpoint.0, None);
            assert_eq!(failed_checkpoint.1.as_deref(), Some(record_id.as_str()));
            assert_eq!(failed_checkpoint.2, Some(2));
            assert_eq!(failed_checkpoint.3, "failed");
            assert_eq!(failed_checkpoint.4, 0);

            let committed_redactions: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(committed_redactions, 1, "purge committed before checkpoint failure");

            sqlx::raw_sql(
                "DROP TRIGGER fail_auto_purge_terminal_checkpoint ON record_auto_purge_vault_cursors; \
                 DROP FUNCTION fail_auto_purge_terminal_checkpoint();",
            )
            .execute(&database.pool)
            .await
            .unwrap();
            let report = scan
                .scan_batch(1, 1, 60, 60)
                .await
                .expect("restart retry uses the real idempotent maintenance purge route");
            assert!(report.acquired);
            assert!(!report.fenced);
            assert_eq!(report.counters.candidates, 1);
            assert_eq!(report.counters.purged, 1);
            assert_eq!(report.counters.stale_or_withdrawn, 0);

            let consumed_policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(consumed_policy, (false, 2));

            let redaction: (String, String, String, i64, i64) = sqlx::query_as(
                "SELECT redaction_id,deleted_revision_id,record_id,deleted_seq,redaction_seq \
                 FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(redaction.1, deleted_revision_id);
            assert_eq!(redaction.2, record_id);
            assert_eq!((redaction.3, redaction.4), (2, 3));
            let redacted_revision_ids: Vec<String> = sqlx::query_scalar(
                "SELECT revision_id FROM record_redacted_revisions \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_all(&database.pool)
            .await
            .unwrap();
            assert_eq!(redacted_revision_ids, vec![deleted_revision_id.clone()]);

            let scrubbed_version: (Option<String>, String, String, String) = sqlx::query_as(
                "SELECT base_revision_id,envelope,digest,device_id FROM record_versions \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(scrubbed_version, (None, "{}".into(), String::new(), String::new()));
            let events: (i64, i64) = sqlx::query_as(
                "SELECT COUNT(*) FILTER (WHERE event_type='redacted' AND revision_id='' AND envelope='{}'), \
                        COUNT(*) FILTER (WHERE event_type='record_redacted' AND revision_id='' AND envelope='{}') \
                 FROM change_events WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(events, (1, 1));

            let snapshot: (Option<chrono::DateTime<Utc>>, String, i64, String) = sqlx::query_as(
                "SELECT redacted_at,manifest_json,snapshot_item_count,snapshot_manifest_format \
                 FROM snapshots WHERE vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert!(snapshot.0.is_some());
            assert_eq!((snapshot.1.as_str(), snapshot.2, snapshot.3.as_str()), ("[]", 0, "expired"));
            let remaining_snapshot_items: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM snapshot_items i JOIN snapshots s USING(snapshot_id) \
                 WHERE s.vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(remaining_snapshot_items, 0);

            let audit: (Option<String>, Option<String>, i64) = sqlx::query_as(
                "SELECT actor_user_id,actor_device_id,COUNT(*) FROM audit_events \
                 WHERE scope_type='vault' AND scope_id=$1 AND action='vault.record_purged' \
                   AND source='maintenance' GROUP BY actor_user_id,actor_device_id",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(audit, (None, None, 1));
            let queued: Vec<(String, i64)> = sqlx::query_as(
                "SELECT endpoint_id,requested_seq FROM notification_push_outbox \
                 WHERE endpoint_id=ANY($1::text[]) ORDER BY endpoint_id",
            )
            .bind(&endpoint_ids)
            .fetch_all(&database.pool)
            .await
            .unwrap();
            let mut expected_queued = endpoint_ids
                .iter()
                .cloned()
                .map(|endpoint_id| (endpoint_id, 1))
                .collect::<Vec<_>>();
            expected_queued.sort();
            assert_eq!(queued, expected_queued);

            let cursor: (Option<String>, Option<String>) = sqlx::query_as(
                "SELECT after_record_id,pending_record_id FROM record_auto_purge_vault_cursors \
                 WHERE vault_id=$1",
            )
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(cursor, (Some(record_id.clone()), None));

            // The exact immutable tombstone receipt remains retryable after
            // the scanner consumed opt-in and a capability report was later
            // invalidated. It returns the same signed proof without a second
            // sequence, audit, redaction, or outbox increment.
            sqlx::query(
                "UPDATE device_redaction_capability_reports SET invalidated_at=clock_timestamp() \
                 WHERE account_id=(SELECT owner_user_id FROM vaults WHERE vault_id=$1)",
            )
            .bind(&vault_id)
            .execute(&database.pool)
            .await
            .unwrap();
            let retry = purge
                .purge_for_maintenance(&vault_id, &record_id, &deleted_revision_id, "2", 60)
                .await
                .unwrap();
            assert_eq!(retry["already_purged"], true);
            let proof = retry["redaction"].clone();
            assert_eq!(proof["format"], "atermius-record-redaction-proof-v1");
            assert_eq!(proof["redaction_id"], redaction.0);
            assert_eq!(proof["vault_id"], vault_id);
            assert_eq!(proof["record_id"], record_id);
            assert_eq!(proof["deleted_revision_id"], deleted_revision_id);
            assert_eq!(proof["deleted_seq"], "2");
            assert_eq!(proof["redaction_seq"], "3");
            let signature_bytes = URL_SAFE_NO_PAD
                .decode(proof["signature"].as_str().unwrap())
                .unwrap();
            let signature = ed25519_dalek::Signature::from_slice(&signature_bytes).unwrap();
            let mut unsigned = proof.clone();
            unsigned.as_object_mut().unwrap().remove("signature");
            signing_key
                .verifying_key()
                .verify(&crate::jcs(&unsigned).unwrap(), &signature)
                .unwrap();

            let retry_state: (i64, i64, i64, i64, i64) = sqlx::query_as(
                "SELECT (SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1), \
                        (SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2), \
                        (SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                          AND action='vault.record_purged' AND source='maintenance'), \
                        (SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=ANY($3::text[])), \
                        (SELECT COALESCE(SUM(requested_seq),0)::BIGINT FROM notification_push_outbox \
                          WHERE endpoint_id=ANY($3::text[]))",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&endpoint_ids)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(retry_state, (3, 1, 1, 2, 2));
            database.cleanup().await;
        })
        .await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_serializes_with_owner_opt_out() {
        with_database(|database| async move {
            let (vault_id, record_id, deleted_revision_id, _) =
                seed_purge_fixture(&database.pool).await;
            sqlx::query(
                "UPDATE record_graveyard SET auto_purge_enabled=TRUE,auto_purge_revision=1 \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .execute(&database.pool)
            .await
            .unwrap();
            let owner = owner_auth_actor(&database.pool, &vault_id).await;
            let key = Arc::new(SigningKey::from_bytes(&[0x51; 32]));
            let purge = PgRecordPurgeRepository::new(
                database.pool.clone(),
                signer(
                    key.clone(),
                    URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
                ),
            );
            let scan = crate::pg_record_auto_purge_scan::PgRecordAutoPurgeScanRepository::new(
                database.pool.clone(),
                purge.clone(),
            );

            let pending_channel = format!("auto_purge_pending_{}", Uuid::new_v4().simple());
            let notify_trigger = format!(
                "CREATE FUNCTION notify_auto_purge_pending_test() RETURNS trigger \
                 LANGUAGE plpgsql AS $$ \
                 BEGIN \
                   IF OLD.pending_record_id IS NULL AND NEW.pending_record_id IS NOT NULL THEN \
                     PERFORM pg_notify('{pending_channel}', 'staged'); \
                   END IF; \
                   RETURN NEW; \
                 END $$; \
                 CREATE TRIGGER notify_auto_purge_pending_test \
                 AFTER UPDATE OF pending_record_id ON record_auto_purge_vault_cursors \
                 FOR EACH ROW EXECUTE FUNCTION notify_auto_purge_pending_test();"
            );
            sqlx::raw_sql(&notify_trigger)
                .execute(&database.pool)
                .await
                .unwrap();
            let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
            listener.listen(&pending_channel).await.unwrap();

            // The owner policy writer and scanner share the purge writer
            // fence. Whichever commits first determines the only valid result.
            let scan_task = tokio::spawn(async move { scan.scan_batch(1, 1, 60, 60).await });
            let pending_notice = tokio::time::timeout(Duration::from_secs(10), listener.recv())
                .await
                .expect("scanner persists its pending candidate")
                .expect("receive pending candidate notification");
            assert_eq!(pending_notice.channel(), pending_channel);
            assert_eq!(pending_notice.payload(), "staged");
            let opt_out_result = purge
                .set_auto_purge_policy(
                    &owner,
                    &vault_id,
                    &record_id,
                    &deleted_revision_id,
                    "2",
                    "1",
                    false,
                )
                .await;
            let scan_report = scan_task
                .await
                .expect("scanner task completes")
                .expect("the bounded scan resolves the candidate");
            assert!(scan_report.acquired);
            assert!(!scan_report.fenced);
            assert_eq!(scan_report.counters.candidates, 1);

            let redaction_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            let policy: (bool, i64) = sqlx::query_as(
                "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
                 WHERE vault_id=$1 AND record_id=$2",
            )
            .bind(&vault_id)
            .bind(&record_id)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(policy, (false, 2));

            match opt_out_result {
                Ok(_) => {
                    // Withdrawal won the shared writer fence first; the
                    // scanner observes stale consent and writes no redaction.
                    assert_eq!(scan_report.counters.purged, 0);
                    assert_eq!(scan_report.counters.stale_or_withdrawn, 1);
                    assert_eq!(redaction_count, 0);
                }
                Err(error) => {
                    // Purge won first and removed the live head, so an owner
                    // cannot subsequently withdraw that already-consumed opt-in.
                    assert_eq!(error.body.code, "RECORD_TOMBSTONE_CHANGED");
                    assert_eq!(scan_report.counters.purged, 1);
                    assert_eq!(scan_report.counters.stale_or_withdrawn, 0);
                    assert_eq!(redaction_count, 1);
                }
            }
            drop(listener);
            database.cleanup().await;
        })
        .await;
    }
}

#[cfg(test)]
pub(crate) async fn seed_purge_fixture_for_auto_purge_scan_test(
    pool: &PgPool,
) -> (String, String, String, Vec<String>) {
    tests::seed_purge_fixture(pool).await
}

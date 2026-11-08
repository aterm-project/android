//! Owner and guarded Maintenance initiated permanent record purge for the
//! SQLite sync backend.
//!
//! The operation keeps ordered sync/history metadata and the compact graveyard
//! reservation while replacing every retained record payload with a redacted
//! marker. Object bytes are only made eligible for the existing delayed
//! collector after their final reference is removed.

use std::collections::BTreeSet;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::Signer;
use serde_json::{Value, json};
use sqlx::Row;

use crate::{
    ApiError, AppState, InstanceMaintenanceGuard, auth::AuthUser, jcs, now_rfc3339,
    record_purge_actor::RecordPurgeActor,
};

pub(crate) fn parse_positive_sequence(value: &str) -> Result<i64, ApiError> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err(ApiError::bad_request(
            "INVALID_PURGE_REQUEST",
            "expected deleted sequence must be a canonical positive decimal string",
        ));
    }
    value
        .parse::<i64>()
        .ok()
        .filter(|seq| *seq > 0)
        .ok_or_else(|| {
            ApiError::bad_request(
                "INVALID_PURGE_REQUEST",
                "expected deleted sequence is outside the supported range",
            )
        })
}

pub(crate) fn parse_nonnegative_revision(value: &str) -> Result<i64, ApiError> {
    if value.is_empty()
        || !value.bytes().all(|byte| byte.is_ascii_digit())
        || (value.len() > 1 && value.starts_with('0'))
    {
        return Err(ApiError::bad_request(
            "INVALID_AUTO_PURGE_POLICY",
            "expected policy revision must be a canonical non-negative decimal string",
        ));
    }
    value.parse::<i64>().map_err(|_| {
        ApiError::bad_request(
            "INVALID_AUTO_PURGE_POLICY",
            "expected policy revision is outside the supported range",
        )
    })
}

/// Persists an Owner's consent for one exact current tombstone. The revision
/// compare-and-set and audit row share the same Vault writer fence.
pub(crate) async fn set_record_auto_purge_sqlite(
    state: &AppState,
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
    let expected_deleted_seq = parse_positive_sequence(expected_deleted_seq)?;
    let expected_policy_revision = parse_nonnegative_revision(expected_policy_revision)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

    // Reserve SQLite's single writer before checking actor, exact tombstone,
    // and policy revision. This serializes opt-out with Maintenance purge.
    let fence = sqlx::query(
        "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
    )
    .bind(vault_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if fence.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, user, vault_id).await?;
    let owner_user_id: String =
        sqlx::query_scalar("SELECT owner_user_id FROM vaults WHERE vault_id=?")
            .bind(vault_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
    if role != "owner" || owner_user_id != user.user_id {
        return Err(ApiError::forbidden(
            "VAULT_OWNER_REQUIRED",
            "only the active Vault owner can change automatic purge consent",
        ));
    }

    let row = sqlx::query(
        "SELECT g.auto_purge_enabled,g.auto_purge_revision,h.revision_id,h.commit_seq, \
                h.deleted,v.operation,v.restore_until, \
                EXISTS(SELECT 1 FROM record_redactions rr WHERE rr.vault_id=g.vault_id \
                       AND rr.record_id=g.record_id) AS is_redacted \
         FROM record_graveyard g \
         JOIN record_heads h ON h.vault_id=g.vault_id AND h.record_id=g.record_id \
         JOIN record_versions v ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                               AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
         WHERE g.vault_id=? AND g.record_id=? AND g.deleted_revision=? AND g.deleted_seq=?",
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
    let restore_until: Option<String> = row.try_get("restore_until").map_err(ApiError::internal)?;
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
        .try_get::<i64, _>("auto_purge_enabled")
        .map_err(ApiError::internal)?
        != 0;
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
            "UPDATE record_graveyard SET auto_purge_enabled=?,auto_purge_revision=? \
             WHERE vault_id=? AND record_id=? AND deleted_revision=? AND deleted_seq=? \
               AND auto_purge_revision=?",
        )
        .bind(i64::from(enabled))
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
        crate::audit::record_vault_event_tx(
            &mut tx,
            vault_id,
            Some(&user.user_id),
            Some(&user.device_id),
            "vault.record_auto_purge_opt_in_changed",
            "record_auto_purge_policy",
            Some(record_id),
            crate::audit::AuditSource::Api,
            chrono::Utc::now().timestamp(),
        )
        .await?;
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

pub(crate) async fn purge_record_sqlite(
    state: &AppState,
    user: &AuthUser,
    vault_id: &str,
    record_id: &str,
    expected_deleted_revision_id: &str,
    expected_deleted_seq: &str,
) -> Result<Value, ApiError> {
    purge_record_sqlite_actor(
        state,
        RecordPurgeActor::Owner(user),
        vault_id,
        record_id,
        expected_deleted_revision_id,
        expected_deleted_seq,
    )
    .await
}

/// Executes an explicitly requested maintenance purge while the caller owns
/// the matching instance's maintenance/backup exclusion guard. There is
/// currently no automatic caller; any future worker must supply the exact
/// current tombstone and pass its persisted per-record opt-in below.
#[allow(dead_code)] // Deliberately unwired until persistent explicit opt-in is implemented.
pub(crate) async fn purge_record_sqlite_maintenance(
    state: &AppState,
    guard: &InstanceMaintenanceGuard<'_>,
    vault_id: &str,
    record_id: &str,
    expected_deleted_revision_id: &str,
    expected_deleted_seq: &str,
) -> Result<Value, ApiError> {
    if !guard.belongs_to(state) {
        return Err(ApiError::internal(
            "maintenance purge guard does not match the target instance",
        ));
    }
    purge_record_sqlite_actor(
        state,
        RecordPurgeActor::Maintenance,
        vault_id,
        record_id,
        expected_deleted_revision_id,
        expected_deleted_seq,
    )
    .await
}

async fn purge_record_sqlite_actor(
    state: &AppState,
    actor: RecordPurgeActor<'_>,
    vault_id: &str,
    record_id: &str,
    expected_deleted_revision_id: &str,
    expected_deleted_seq: &str,
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
    let expected_deleted_seq = parse_positive_sequence(expected_deleted_seq)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Acquire SQLite's single-writer fence before reading capability reports,
    // membership, the current head, or purge state. A transaction that only
    // read first could race a report invalidation or restore from a newer
    // writer and then fail late with SQLITE_BUSY_SNAPSHOT instead of having a
    // clear serial order.
    let fence = sqlx::query(
        "UPDATE vault_counters SET last_committed_seq=last_committed_seq WHERE vault_id=?",
    )
    .bind(vault_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if fence.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    match actor {
        RecordPurgeActor::Owner(user) => {
            let (role, _, _) =
                crate::require_authenticated_vault_write_tx(&mut tx, user, vault_id).await?;
            let owner_user_id: String =
                sqlx::query_scalar("SELECT owner_user_id FROM vaults WHERE vault_id=?")
                    .bind(vault_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?
                    .ok_or_else(ApiError::not_found)?;
            if role != "owner" || owner_user_id != user.user_id {
                return Err(ApiError::forbidden(
                    "VAULT_OWNER_REQUIRED",
                    "only the active Vault owner can permanently purge a record",
                ));
            }
        }
        RecordPurgeActor::Maintenance => {
            let vault_state: Option<String> =
                sqlx::query_scalar("SELECT state FROM vaults WHERE vault_id=?")
                    .bind(vault_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            match vault_state.as_deref() {
                Some("active") => {}
                Some("deleting") => return Err(ApiError::vault_deletion_pending()),
                Some(_) => return Err(ApiError::not_found()),
                None => return Err(ApiError::not_found()),
            }
        }
    }

    // A retry after a lost acknowledgement is read-only and returns the same
    // immutable statement, even if another device's report was later revoked.
    if let Some(row) = sqlx::query(
        "SELECT redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq \
         FROM record_redactions WHERE vault_id=? AND record_id=?",
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
        let proof = signed_proof(state, &statement)?;
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
             WHERE vault_id=? AND record_id=? AND deleted_revision=? AND deleted_seq=? \
               AND auto_purge_enabled=1)",
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

    if !crate::redaction_capabilities::every_active_vault_device_supports_redaction_v1_tx(
        &mut tx, vault_id,
    )
    .await?
    {
        return Err(ApiError::conflict(
            "VAULT_REDACTION_CAPABILITY_REQUIRED",
            "every active device of every active Vault member must have a valid redaction v1 report",
        ));
    }

    let current = sqlx::query(
        "SELECT h.revision_id,h.commit_seq,h.deleted,v.operation,v.restore_until,\
                g.deleted_revision,g.deleted_seq \
         FROM record_heads h \
         JOIN record_graveyard g ON g.vault_id=h.vault_id AND g.record_id=h.record_id \
         JOIN record_versions v ON v.vault_id=h.vault_id AND v.record_id=h.record_id \
                               AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
         WHERE h.vault_id=? AND h.record_id=?",
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
    let current_revision: String = current.try_get("revision_id").map_err(ApiError::internal)?;
    let current_seq: i64 = current.try_get("commit_seq").map_err(ApiError::internal)?;
    let grave_revision: String = current
        .try_get("deleted_revision")
        .map_err(ApiError::internal)?;
    let grave_seq: i64 = current.try_get("deleted_seq").map_err(ApiError::internal)?;
    if current
        .try_get::<i64, _>("deleted")
        .map_err(ApiError::internal)?
        != 1
        || current
            .try_get::<String, _>("operation")
            .map_err(ApiError::internal)?
            != "delete"
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

    let restore_until: Option<String> = current
        .try_get("restore_until")
        .map_err(ApiError::internal)?;
    let restore_until = restore_until
        .as_deref()
        .ok_or_else(|| ApiError::internal("current tombstone restore deadline is missing"))?;
    let restore_until = chrono::DateTime::parse_from_rfc3339(restore_until)
        .map_err(ApiError::internal)?
        .with_timezone(&chrono::Utc);
    let now = chrono::Utc::now();
    if !crate::sync::restore_deadline_elapsed(now, restore_until) {
        return Err(ApiError::conflict(
            "RECORD_PURGE_NOT_DUE",
            "the record restore period has not ended",
        )
        .with_details(json!({"restore_until":restore_until.to_rfc3339()})));
    }

    let unresolved: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM conflicts WHERE vault_id=? AND record_id=? AND resolved_revision_id IS NULL",
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

    let mut revision_ids = BTreeSet::new();
    let version_rows = sqlx::query(
        "SELECT revision_id FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY revision_id",
    )
    .bind(vault_id)
    .bind(record_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for row in &version_rows {
        revision_ids.insert(
            row.try_get::<String, _>("revision_id")
                .map_err(ApiError::internal)?,
        );
    }
    revision_ids.insert(expected_deleted_revision_id.to_owned());

    // Conflict branch object references use the attempted revision ID as the
    // reference key. Recover and validate those IDs before scrubbing envelopes.
    let conflict_rows = sqlx::query(
        "SELECT conflict_id,envelope FROM conflicts WHERE vault_id=? AND record_id=? ORDER BY conflict_id",
    )
    .bind(vault_id)
    .bind(record_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut conflict_revision_ids = BTreeSet::new();
    for row in &conflict_rows {
        let raw: String = row.try_get("envelope").map_err(ApiError::internal)?;
        let envelope: Value = serde_json::from_str(&raw).map_err(ApiError::internal)?;
        let revision_id = envelope
            .get("header")
            .and_then(|header| header.get("revision_id"))
            .and_then(Value::as_str)
            .filter(|value| crate::is_canonical_uuid(value))
            .ok_or_else(reference_ambiguity)?;
        conflict_revision_ids.insert(revision_id.to_owned());
    }
    revision_ids.extend(conflict_revision_ids.iter().cloned());

    // object_references is keyed by Vault and revision ID, without a record
    // owner column. Never infer that a colliding legacy ID belongs only to the
    // record being purged. Check all retained rows that can still identify a
    // revision's record, including legacy feed/head/graveyard/receipt metadata;
    // older databases may have a useful reference after a version row was lost.
    for revision_id in &revision_ids {
        let foreign_owner: bool = sqlx::query_scalar(
            "SELECT \
               EXISTS(SELECT 1 FROM record_versions WHERE vault_id=?1 AND record_id<>?2 \
                      AND (revision_id=?3 OR base_revision_id=?3)) \
               OR EXISTS(SELECT 1 FROM record_heads WHERE vault_id=?1 AND record_id<>?2 \
                         AND revision_id=?3) \
               OR EXISTS(SELECT 1 FROM record_graveyard WHERE vault_id=?1 AND record_id<>?2 \
                         AND deleted_revision=?3) \
               OR EXISTS(SELECT 1 FROM change_events WHERE vault_id=?1 AND record_id<>?2 \
                         AND revision_id=?3) \
               OR EXISTS(SELECT 1 FROM conflicts WHERE vault_id=?1 AND record_id<>?2 \
                         AND (json_extract(envelope,'$.header.revision_id')=?3 \
                              OR base_revision_id=?3 OR resolved_revision_id=?3)) \
               OR EXISTS(SELECT 1 FROM record_redacted_revisions \
                         WHERE vault_id=?1 AND record_id<>?2 AND revision_id=?3) \
               OR EXISTS(SELECT 1 FROM record_redactions \
                         WHERE vault_id=?1 AND record_id<>?2 AND deleted_revision_id=?3) \
               OR EXISTS(SELECT 1 FROM op_receipts WHERE vault_id=?1 AND record_id<>?2 \
                         AND revision_id=?3)",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(revision_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if foreign_owner {
            return Err(reference_ambiguity());
        }
    }

    let redaction_id = uuid::Uuid::new_v4().to_string();
    let redaction_seq: i64 = sqlx::query_scalar(
        "UPDATE vault_counters SET last_committed_seq=last_committed_seq+1 \
         WHERE vault_id=? RETURNING last_committed_seq",
    )
    .bind(vault_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("Vault sequence counter is missing"))?;
    if redaction_seq <= expected_deleted_seq {
        return Err(ApiError::internal(
            "redaction sequence does not follow the deleted revision",
        ));
    }
    let inserted_redaction = sqlx::query(
        "INSERT INTO record_redactions(\
             redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at\
         ) VALUES(?,?,?,?,?,?,?)",
    )
    .bind(&redaction_id)
    .bind(vault_id)
    .bind(record_id)
    .bind(expected_deleted_revision_id)
    .bind(expected_deleted_seq)
    .bind(redaction_seq)
    .bind(now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if inserted_redaction.rows_affected() != 1 {
        return Err(ApiError::internal(
            "redaction statement insert count changed",
        ));
    }
    for revision_id in &conflict_revision_ids {
        sqlx::query(
            "INSERT OR IGNORE INTO record_redacted_revisions(vault_id,record_id,revision_id) VALUES(?,?,?)",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(revision_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }

    let indexed_revision_ids: BTreeSet<String> = sqlx::query_scalar(
        "SELECT revision_id FROM record_redacted_revisions WHERE vault_id=? AND record_id=?",
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

    // Invalidate and erase every persisted materialized snapshot before any
    // history or head envelope is scrubbed. Readers share the Vault writer
    // fence and therefore observe either the old complete view or this 410.
    let snapshot_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM snapshots WHERE vault_id=?")
        .bind(vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let snapshot_items_before: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM snapshot_items i JOIN snapshots s ON s.snapshot_id=i.snapshot_id WHERE s.vault_id=?",
    )
    .bind(vault_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let invalidated_snapshots = sqlx::query(
        "UPDATE snapshots SET redacted_at=?,manifest_json='[]',snapshot_item_count=0,\
                snapshot_manifest_format='expired' WHERE vault_id=?",
    )
    .bind(now_rfc3339())
    .bind(vault_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if invalidated_snapshots.rows_affected() != snapshot_count as u64 {
        return Err(ApiError::internal("snapshot invalidation count changed"));
    }
    let erased_snapshot_items = sqlx::query(
        "DELETE FROM snapshot_items WHERE snapshot_id IN \
         (SELECT snapshot_id FROM snapshots WHERE vault_id=?)",
    )
    .bind(vault_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if erased_snapshot_items.rows_affected() != snapshot_items_before as u64 {
        return Err(ApiError::internal("snapshot page erasure count changed"));
    }

    let version_count = version_rows.len() as u64;
    let scrubbed_versions = sqlx::query(
        "UPDATE record_versions SET base_revision_id=NULL,envelope='{}',digest='',\
                device_id='' WHERE vault_id=? AND record_id=?",
    )
    .bind(vault_id)
    .bind(record_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if scrubbed_versions.rows_affected() != version_count {
        return Err(ApiError::internal("record revision scrub count changed"));
    }
    let event_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?")
            .bind(vault_id)
            .bind(record_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let scrubbed_events = sqlx::query(
        "UPDATE change_events SET event_type='redacted',revision_id='',envelope='{}' \
         WHERE vault_id=? AND record_id=?",
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
        "UPDATE conflicts SET base_revision_id=NULL,envelope='{}',digest='',device_id='',\
                resolved_revision_id=NULL,op_id=NULL WHERE vault_id=? AND record_id=?",
    )
    .bind(vault_id)
    .bind(record_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if scrubbed_conflicts.rows_affected() != conflict_rows.len() as u64 {
        return Err(ApiError::internal("record conflict scrub count changed"));
    }

    let object_ids: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT object_id FROM object_references WHERE vault_id=? \
         AND revision_id IN (SELECT revision_id FROM record_redacted_revisions \
                             WHERE vault_id=? AND record_id=?) ORDER BY object_id",
    )
    .bind(vault_id)
    .bind(vault_id)
    .bind(record_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let references_before: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM object_references WHERE vault_id=? \
         AND revision_id IN (SELECT revision_id FROM record_redacted_revisions \
                             WHERE vault_id=? AND record_id=?)",
    )
    .bind(vault_id)
    .bind(vault_id)
    .bind(record_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let deleted_references = sqlx::query(
        "DELETE FROM object_references WHERE vault_id=? \
         AND revision_id IN (SELECT revision_id FROM record_redacted_revisions \
                             WHERE vault_id=? AND record_id=?)",
    )
    .bind(vault_id)
    .bind(vault_id)
    .bind(record_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if deleted_references.rows_affected() != references_before as u64 {
        return Err(ApiError::internal("record object reference count changed"));
    }
    let gc_after = chrono::Utc::now()
        .timestamp()
        .saturating_add(state.config.object_gc_grace_seconds);
    for object_id in object_ids {
        sqlx::query(
            "UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id=? \
             AND storage_state='available' \
             AND NOT EXISTS(SELECT 1 FROM object_references r \
                            WHERE r.vault_id=blob_objects.vault_id \
                              AND r.object_id=blob_objects.object_id)",
        )
        .bind(gc_after)
        .bind(vault_id)
        .bind(&object_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        // A completed upload receipt is also a narrowly scoped object read
        // grant for retrying sync before a live revision reference exists.
        // Revoke that grant when purge removes the final reference; the bytes
        // remain available only to the delayed collector, not to object GET.
        sqlx::query(
            "UPDATE uploads SET state='collected' WHERE vault_id=? AND object_id=? \
             AND state='completed' \
             AND NOT EXISTS(SELECT 1 FROM object_references r \
                            WHERE r.vault_id=uploads.vault_id AND r.object_id=uploads.object_id)",
        )
        .bind(vault_id)
        .bind(&object_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }

    let deleted_head = sqlx::query("DELETE FROM record_heads WHERE vault_id=? AND record_id=? AND revision_id=? AND commit_seq=? AND deleted=1")
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
        "UPDATE record_graveyard SET auto_purge_enabled=0, \
             auto_purge_revision=auto_purge_revision + CASE WHEN auto_purge_enabled=1 THEN 1 ELSE 0 END \
         WHERE vault_id=? AND record_id=? AND deleted_revision=? AND deleted_seq=?",
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
         VALUES(?,?,'record_redacted',?,'','{}',?)",
    )
    .bind(vault_id)
    .bind(redaction_seq)
    .bind(record_id)
    .bind(now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if appended_marker.rows_affected() != 1 {
        return Err(ApiError::internal("redaction event insert count changed"));
    }
    let (actor_user_id, actor_device_id, audit_source) = match actor {
        RecordPurgeActor::Owner(user) => (
            Some(user.user_id.as_str()),
            Some(user.device_id.as_str()),
            crate::audit::AuditSource::Api,
        ),
        RecordPurgeActor::Maintenance => (None, None, crate::audit::AuditSource::Maintenance),
    };
    let push_now = chrono::Utc::now().timestamp();
    match actor_device_id {
        Some(source_device_id) => {
            crate::mobile_push::enqueue_sync_available_tx(
                &mut tx,
                vault_id,
                source_device_id,
                push_now,
            )
            .await?;
        }
        None => {
            crate::mobile_push::enqueue_sync_available_all_tx(&mut tx, vault_id, push_now).await?;
        }
    }
    crate::audit::record_vault_event_tx(
        &mut tx,
        vault_id,
        actor_user_id,
        actor_device_id,
        "vault.record_purged",
        "record",
        Some(record_id),
        audit_source,
        chrono::Utc::now().timestamp(),
    )
    .await?;

    let statement = RedactionStatement {
        redaction_id,
        vault_id: vault_id.to_owned(),
        record_id: record_id.to_owned(),
        deleted_revision_id: expected_deleted_revision_id.to_owned(),
        deleted_seq: expected_deleted_seq,
        redaction_seq,
    };
    let proof = signed_proof(state, &statement)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "status":"purged",
        "already_purged":false,
        "redaction":proof,
    }))
}

fn reference_ambiguity() -> ApiError {
    ApiError::conflict(
        "REDACTION_REFERENCE_AMBIGUOUS",
        "legacy revision or attachment ownership is ambiguous; record was not purged",
    )
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

fn statement_from_row(row: &sqlx::sqlite::SqliteRow) -> Result<RedactionStatement, ApiError> {
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

fn signed_proof(state: &AppState, statement: &RedactionStatement) -> Result<Value, ApiError> {
    for id in [
        &state.instance.instance_id,
        &state.instance.server_space_id,
        &statement.redaction_id,
        &statement.vault_id,
        &statement.record_id,
        &statement.deleted_revision_id,
    ] {
        if !crate::is_canonical_uuid(id) {
            return Err(ApiError::internal(
                "redaction proof contains a noncanonical identifier",
            ));
        }
    }
    if statement.deleted_seq <= 0 || statement.redaction_seq <= statement.deleted_seq {
        return Err(ApiError::internal("redaction proof sequence is invalid"));
    }
    let public = URL_SAFE_NO_PAD.encode(state.signing_key.verifying_key().as_bytes());
    if public != state.instance.signing_public_key {
        return Err(ApiError::internal(
            "instance signing identity does not match the active signing key",
        ));
    }
    let mut proof = json!({
        "format":"atermius-record-redaction-proof-v1",
        "redaction_id":statement.redaction_id,
        "instance_id":state.instance.instance_id,
        "server_space_id":state.instance.server_space_id,
        "vault_id":statement.vault_id,
        "record_id":statement.record_id,
        "deleted_revision_id":statement.deleted_revision_id,
        "deleted_seq":statement.deleted_seq.to_string(),
        "redaction_seq":statement.redaction_seq.to_string(),
        "signing_public_key":state.instance.signing_public_key,
    });
    let signature = state.signing_key.sign(&jcs(&proof)?);
    proof["signature"] = json!(URL_SAFE_NO_PAD.encode(signature.to_bytes()));
    Ok(proof)
}

#[cfg(test)]
mod tests {
    use super::parse_positive_sequence;

    #[test]
    fn purge_sequence_requires_canonical_positive_i64_decimal() {
        assert_eq!(parse_positive_sequence("1").unwrap(), 1);
        assert_eq!(
            parse_positive_sequence("9223372036854775807").unwrap(),
            i64::MAX
        );
        for invalid in [
            "",
            "0",
            "00",
            "01",
            "+1",
            "-1",
            " 1",
            "1 ",
            "9223372036854775808",
        ] {
            assert!(
                parse_positive_sequence(invalid).is_err(),
                "accepted {invalid:?}"
            );
        }
    }
}

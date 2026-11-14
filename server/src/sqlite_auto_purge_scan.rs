//! Persistent bounded scan cursors for opt-in SQLite record purging.
//!
//! The Maintenance path holds the matching instance guard for the full scan.
//! Scan state contains only cursor identifiers and aggregate outcome counts;
//! it never stores candidate payloads or errors.

use std::collections::HashSet;

use chrono::{DateTime, SecondsFormat, Utc};
use sqlx::{QueryBuilder, Row, Sqlite};
use uuid::Uuid;

use crate::{ApiError, AppState, InstanceMaintenanceGuard};

/// Bump only when the persisted cursor interpretation changes incompatibly.
/// This is an algorithm generation, not the server process generation.
const SCAN_SERVER_GENERATION: i64 = 1;
const LEASE_SECONDS: i64 = 60 * 60;
const MAX_VAULTS_PER_SCAN: usize = 128;
const MAX_CANDIDATES_PER_SCAN: usize = 1024;
const MAX_CANDIDATES_PER_VAULT: usize = 64;

#[derive(Debug, Clone, Copy)]
pub(crate) struct RecordAutoPurgeScanLimits {
    /// Maximum distinct Vaults visited in one bounded pass.
    pub(crate) max_vaults: usize,
    /// Maximum tombstones attempted across the pass.
    pub(crate) max_candidates: usize,
    /// Maximum consecutive tombstones processed from one Vault before the
    /// round-robin cursor yields to the next Vault.
    pub(crate) max_candidates_per_vault: usize,
}

impl Default for RecordAutoPurgeScanLimits {
    fn default() -> Self {
        Self {
            max_vaults: 32,
            max_candidates: 128,
            max_candidates_per_vault: 4,
        }
    }
}

impl RecordAutoPurgeScanLimits {
    fn validate(self) -> Result<Self, ApiError> {
        if !(1..=MAX_VAULTS_PER_SCAN).contains(&self.max_vaults)
            || !(1..=MAX_CANDIDATES_PER_SCAN).contains(&self.max_candidates)
            || !(1..=MAX_CANDIDATES_PER_VAULT).contains(&self.max_candidates_per_vault)
        {
            return Err(ApiError::bad_request(
                "INVALID_AUTO_PURGE_SCAN_LIMIT",
                "automatic purge scan limits are outside the supported bounds",
            ));
        }
        Ok(self)
    }
}

/// Aggregate-only view of one bounded scan. No Vault, record, or error
/// identifier is returned here.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct RecordAutoPurgeScanSummary {
    pub(crate) candidates: i64,
    pub(crate) purged: i64,
    pub(crate) not_due: i64,
    pub(crate) capability_blocked: i64,
    pub(crate) conflict_blocked: i64,
    pub(crate) reference_blocked: i64,
    pub(crate) stale_or_withdrawn: i64,
}

impl RecordAutoPurgeScanSummary {
    fn record(&mut self, outcome: CandidateOutcome) {
        self.candidates = self.candidates.saturating_add(1);
        match outcome {
            CandidateOutcome::Purged => self.purged = self.purged.saturating_add(1),
            CandidateOutcome::NotDue => self.not_due = self.not_due.saturating_add(1),
            CandidateOutcome::CapabilityBlocked => {
                self.capability_blocked = self.capability_blocked.saturating_add(1)
            }
            CandidateOutcome::ConflictBlocked => {
                self.conflict_blocked = self.conflict_blocked.saturating_add(1)
            }
            CandidateOutcome::ReferenceBlocked => {
                self.reference_blocked = self.reference_blocked.saturating_add(1)
            }
            CandidateOutcome::StaleOrWithdrawn => {
                self.stale_or_withdrawn = self.stale_or_withdrawn.saturating_add(1)
            }
        }
    }

    fn record_transient_attempt(&mut self) {
        self.candidates = self.candidates.saturating_add(1);
    }
}

#[derive(Debug, Clone)]
struct Candidate {
    vault_id: String,
    record_id: String,
    deleted_revision_id: String,
    deleted_seq: i64,
}

#[derive(Debug, Clone, Copy)]
enum CandidateOutcome {
    Purged,
    NotDue,
    CapabilityBlocked,
    ConflictBlocked,
    ReferenceBlocked,
    StaleOrWithdrawn,
}

#[derive(Debug, Clone)]
struct VaultCursor {
    after_record_id: Option<String>,
    high_water_record_id: Option<String>,
    pending_candidate: Option<Candidate>,
}

/// Runs one bounded SQLite automatic-purge scan while Maintenance holds the
/// matching instance guard.
pub(crate) async fn run_record_auto_purge_scan_sqlite(
    state: &AppState,
    guard: &InstanceMaintenanceGuard<'_>,
    limits: RecordAutoPurgeScanLimits,
) -> Result<RecordAutoPurgeScanSummary, ApiError> {
    if !guard.belongs_to(state) {
        return Err(ApiError::internal(
            "automatic purge scan guard does not match the target instance",
        ));
    }
    let limits = limits.validate()?;
    let lease_token = Uuid::new_v4().to_string();
    let mut cursor_revision = claim_scan_lease(state, &lease_token).await?;
    let mut counts = RecordAutoPurgeScanSummary::default();
    let mut visited_vaults = HashSet::new();
    let mut candidates_attempted = 0_usize;
    let mut vaults_visited = 0_usize;

    while vaults_visited < limits.max_vaults && candidates_attempted < limits.max_candidates {
        let after_vault_id = match read_after_vault_id(state).await {
            Ok(after_vault_id) => after_vault_id,
            Err(_) => {
                fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                return Err(scan_failed());
            }
        };
        let next_vault =
            match next_vault_id(state, after_vault_id.as_deref(), &visited_vaults).await {
                Ok(next_vault) => next_vault,
                Err(_) => {
                    fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                    return Err(scan_failed());
                }
            };
        let Some(vault_id) = next_vault else {
            break;
        };
        if !crate::is_canonical_uuid(&vault_id) {
            counts.record_transient_attempt();
            fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
            return Err(scan_failed());
        }
        visited_vaults.insert(vault_id.clone());
        vaults_visited += 1;

        let mut cursor = match load_or_initialize_vault_cursor(
            state,
            &lease_token,
            &mut cursor_revision,
            &vault_id,
            after_vault_id.as_deref(),
            &counts,
        )
        .await
        {
            Ok(cursor) => cursor,
            Err(_) => {
                fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                return Err(scan_failed());
            }
        };
        let mut vault_candidates = 0_usize;

        while vault_candidates < limits.max_candidates_per_vault
            && candidates_attempted < limits.max_candidates
        {
            let candidate = match next_candidate(state, &vault_id, &cursor).await {
                Ok(candidate) => candidate,
                Err(_) => {
                    fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                    return Err(scan_failed());
                }
            };
            let Some(candidate) = candidate else {
                // Reaching the high-water mark closes this Vault's current
                // sweep. A later pass captures a fresh high-water mark.
                if checkpoint_vault_cursor(
                    state,
                    &lease_token,
                    &mut cursor_revision,
                    &vault_id,
                    &VaultCursor {
                        after_record_id: None,
                        high_water_record_id: None,
                        pending_candidate: None,
                    },
                    Some(&vault_id),
                    &counts,
                )
                .await
                .is_err()
                {
                    fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                    return Err(scan_failed());
                }
                break;
            };

            if !crate::is_canonical_uuid(&candidate.record_id)
                || !crate::is_canonical_uuid(&candidate.deleted_revision_id)
                || candidate.deleted_seq <= 0
            {
                let mut attempted = counts.clone();
                attempted.record_transient_attempt();
                fail_scan(state, &lease_token, &mut cursor_revision, &attempted).await?;
                return Err(scan_failed());
            }

            if cursor.pending_candidate.as_ref().is_none_or(|pending| {
                pending.record_id != candidate.record_id
                    || pending.deleted_revision_id != candidate.deleted_revision_id
                    || pending.deleted_seq != candidate.deleted_seq
            }) {
                let mut pending_cursor = cursor.clone();
                pending_cursor.pending_candidate = Some(candidate.clone());
                if checkpoint_vault_cursor(
                    state,
                    &lease_token,
                    &mut cursor_revision,
                    &vault_id,
                    &pending_cursor,
                    after_vault_id.as_deref(),
                    &counts,
                )
                .await
                .is_err()
                {
                    fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
                    return Err(scan_failed());
                }
                cursor = pending_cursor;
            }

            let outcome = match process_candidate_sqlite(state, guard, &candidate).await {
                Ok(outcome) => outcome,
                Err(_) => {
                    let mut attempted = counts.clone();
                    attempted.record_transient_attempt();
                    fail_scan(state, &lease_token, &mut cursor_revision, &attempted).await?;
                    return Err(scan_failed());
                }
            };
            let mut next_counts = counts.clone();
            next_counts.record(outcome);
            let next_cursor = VaultCursor {
                after_record_id: Some(candidate.record_id.clone()),
                high_water_record_id: cursor.high_water_record_id.clone(),
                pending_candidate: None,
            };
            if checkpoint_vault_cursor(
                state,
                &lease_token,
                &mut cursor_revision,
                &vault_id,
                &next_cursor,
                Some(&vault_id),
                &next_counts,
            )
            .await
            .is_err()
            {
                let mut attempted = counts.clone();
                attempted.record_transient_attempt();
                fail_scan(state, &lease_token, &mut cursor_revision, &attempted).await?;
                return Err(scan_failed());
            }

            counts = next_counts;
            cursor = next_cursor;
            candidates_attempted += 1;
            vault_candidates += 1;
        }
    }

    if finish_scan(
        state,
        &lease_token,
        &mut cursor_revision,
        &counts,
        "completed",
    )
    .await
    .is_err()
    {
        fail_scan(state, &lease_token, &mut cursor_revision, &counts).await?;
        return Err(scan_failed());
    }
    Ok(counts)
}

fn scan_failed() -> ApiError {
    ApiError::internal("automatic purge scan stopped before its current cursor was checkpointed")
}

async fn claim_scan_lease(state: &AppState, lease_token: &str) -> Result<i64, ApiError> {
    let now = Utc::now();
    let now_text = timestamp(now);
    let expires_text = timestamp(now + chrono::Duration::seconds(LEASE_SECONDS));
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT after_vault_id,server_generation,cursor_revision,lease_token,lease_expires_at \
         FROM record_auto_purge_scan_control WHERE singleton=1",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("automatic purge scan control row is missing"))?;
    let after_vault_id: Option<String> =
        row.try_get("after_vault_id").map_err(ApiError::internal)?;
    let generation: i64 = row
        .try_get("server_generation")
        .map_err(ApiError::internal)?;
    let revision: i64 = row.try_get("cursor_revision").map_err(ApiError::internal)?;
    let existing_token: Option<String> = row.try_get("lease_token").map_err(ApiError::internal)?;
    let existing_expiry: Option<String> = row
        .try_get("lease_expires_at")
        .map_err(ApiError::internal)?;
    if let (Some(_), Some(expiry)) = (&existing_token, &existing_expiry) {
        let expiry = DateTime::parse_from_rfc3339(expiry)
            .map_err(|_| ApiError::internal("automatic purge scan lease is malformed"))?
            .with_timezone(&Utc);
        if expiry > now {
            return Err(ApiError::conflict(
                "AUTO_PURGE_SCAN_LEASE_ACTIVE",
                "an automatic purge scan lease is already active",
            ));
        }
    } else if existing_token.is_some() || existing_expiry.is_some() {
        return Err(ApiError::internal(
            "automatic purge scan lease is incomplete",
        ));
    }
    let next_revision = revision
        .checked_add(1)
        .ok_or_else(|| ApiError::internal("automatic purge scan cursor revision is exhausted"))?;
    if generation != SCAN_SERVER_GENERATION {
        sqlx::query("DELETE FROM record_auto_purge_vault_cursors")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    let reset_after_vault = if generation == SCAN_SERVER_GENERATION {
        after_vault_id
    } else {
        None
    };
    if reset_after_vault
        .as_deref()
        .is_some_and(|vault_id| !crate::is_canonical_uuid(vault_id))
    {
        return Err(ApiError::internal(
            "automatic purge scan cursor is malformed",
        ));
    }
    let updated = sqlx::query(
        "UPDATE record_auto_purge_scan_control SET after_vault_id=?,server_generation=?, \
             cursor_revision=?,lease_token=?,lease_expires_at=?,last_scan_status='running', \
             last_scan_started_at=?,last_scan_finished_at=NULL,last_scan_candidates=0, \
             last_scan_purged=0,last_scan_not_due=0,last_scan_capability_blocked=0, \
             last_scan_conflict_blocked=0,last_scan_reference_blocked=0, \
             last_scan_stale_or_withdrawn=0 WHERE singleton=1 AND cursor_revision=?",
    )
    .bind(&reset_after_vault)
    .bind(SCAN_SERVER_GENERATION)
    .bind(next_revision)
    .bind(lease_token)
    .bind(expires_text)
    .bind(now_text)
    .bind(revision)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "AUTO_PURGE_SCAN_CURSOR_CHANGED",
            "automatic purge scan lease changed while it was being claimed",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(next_revision)
}

async fn read_after_vault_id(state: &AppState) -> Result<Option<String>, ApiError> {
    let value: Option<String> = sqlx::query_scalar(
        "SELECT after_vault_id FROM record_auto_purge_scan_control WHERE singleton=1",
    )
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?
    .flatten();
    if value
        .as_deref()
        .is_some_and(|vault_id| !crate::is_canonical_uuid(vault_id))
    {
        return Err(ApiError::internal(
            "automatic purge scan cursor is malformed",
        ));
    }
    Ok(value)
}

async fn next_vault_id(
    state: &AppState,
    after_vault_id: Option<&str>,
    visited: &HashSet<String>,
) -> Result<Option<String>, ApiError> {
    if let Some(vault_id) = next_vault_id_from(state, after_vault_id, visited).await? {
        return Ok(Some(vault_id));
    }
    if after_vault_id.is_some() {
        return next_vault_id_from(state, None, visited).await;
    }
    Ok(None)
}

async fn next_vault_id_from(
    state: &AppState,
    after_vault_id: Option<&str>,
    visited: &HashSet<String>,
) -> Result<Option<String>, ApiError> {
    let mut query = QueryBuilder::<Sqlite>::new(
        "SELECT v.vault_id FROM vaults v WHERE v.state='active' \
         AND (EXISTS(SELECT 1 FROM record_graveyard g WHERE g.vault_id=v.vault_id \
                    AND g.auto_purge_enabled=1) \
              OR EXISTS(SELECT 1 FROM record_auto_purge_vault_cursors c \
                        WHERE c.vault_id=v.vault_id AND \
                              (c.high_water_record_id IS NOT NULL OR c.pending_record_id IS NOT NULL)))",
    );
    if let Some(after_vault_id) = after_vault_id {
        query
            .push(" AND v.vault_id COLLATE BINARY > ")
            .push_bind(after_vault_id);
    }
    if !visited.is_empty() {
        query.push(" AND v.vault_id NOT IN (");
        let mut separated = query.separated(",");
        for vault_id in visited {
            separated.push_bind(vault_id);
        }
        separated.push_unseparated(")");
    }
    query.push(" ORDER BY v.vault_id COLLATE BINARY LIMIT 1");
    let row = query
        .build()
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    row.map(|row| row.try_get("vault_id").map_err(ApiError::internal))
        .transpose()
}

async fn load_or_initialize_vault_cursor(
    state: &AppState,
    lease_token: &str,
    cursor_revision: &mut i64,
    vault_id: &str,
    after_vault_id: Option<&str>,
    counts: &RecordAutoPurgeScanSummary,
) -> Result<VaultCursor, ApiError> {
    let row = sqlx::query(
        "SELECT after_record_id,high_water_record_id,pending_record_id, \
                pending_deleted_revision_id,pending_deleted_seq,server_generation \
         FROM record_auto_purge_vault_cursors WHERE vault_id=?",
    )
    .bind(vault_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    if let Some(row) = row {
        let after_record_id: Option<String> =
            row.try_get("after_record_id").map_err(ApiError::internal)?;
        let high_water_record_id: Option<String> = row
            .try_get("high_water_record_id")
            .map_err(ApiError::internal)?;
        let pending_record_id: Option<String> = row
            .try_get("pending_record_id")
            .map_err(ApiError::internal)?;
        let pending_deleted_revision_id: Option<String> = row
            .try_get("pending_deleted_revision_id")
            .map_err(ApiError::internal)?;
        let pending_deleted_seq: Option<i64> = row
            .try_get("pending_deleted_seq")
            .map_err(ApiError::internal)?;
        let pending_candidate = match (
            pending_record_id,
            pending_deleted_revision_id,
            pending_deleted_seq,
        ) {
            (Some(record_id), Some(deleted_revision_id), Some(deleted_seq)) => Some(Candidate {
                vault_id: vault_id.to_owned(),
                record_id,
                deleted_revision_id,
                deleted_seq,
            }),
            (None, None, None) => None,
            _ => {
                return Err(ApiError::internal(
                    "automatic purge pending cursor is malformed",
                ));
            }
        };
        let generation: i64 = row
            .try_get("server_generation")
            .map_err(ApiError::internal)?;
        if generation == SCAN_SERVER_GENERATION
            && (high_water_record_id.is_some() || pending_candidate.is_some())
        {
            if after_record_id
                .as_deref()
                .is_some_and(|id| !crate::is_canonical_uuid(id))
                || high_water_record_id
                    .as_deref()
                    .is_some_and(|id| !crate::is_canonical_uuid(id))
                || pending_candidate.as_ref().is_some_and(|candidate| {
                    !crate::is_canonical_uuid(&candidate.record_id)
                        || !crate::is_canonical_uuid(&candidate.deleted_revision_id)
                        || candidate.deleted_seq <= 0
                        || high_water_record_id
                            .as_deref()
                            .is_none_or(|high| candidate.record_id.as_str() > high)
                        || after_record_id
                            .as_deref()
                            .is_some_and(|after| candidate.record_id.as_str() <= after)
                })
            {
                return Err(ApiError::internal(
                    "automatic purge record cursor is malformed",
                ));
            }
            return Ok(VaultCursor {
                after_record_id,
                high_water_record_id,
                pending_candidate,
            });
        }
    }

    let high_water_record_id: Option<String> = sqlx::query_scalar(
        "SELECT record_id FROM record_graveyard WHERE vault_id=? AND auto_purge_enabled=1 \
         ORDER BY record_id COLLATE BINARY DESC LIMIT 1",
    )
    .bind(vault_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    if high_water_record_id
        .as_deref()
        .is_some_and(|id| !crate::is_canonical_uuid(id))
    {
        return Err(ApiError::internal(
            "automatic purge high-water mark is malformed",
        ));
    }
    let cursor = VaultCursor {
        after_record_id: None,
        high_water_record_id,
        pending_candidate: None,
    };
    checkpoint_vault_cursor(
        state,
        lease_token,
        cursor_revision,
        vault_id,
        &cursor,
        after_vault_id,
        counts,
    )
    .await?;
    Ok(cursor)
}

async fn next_candidate(
    state: &AppState,
    vault_id: &str,
    cursor: &VaultCursor,
) -> Result<Option<Candidate>, ApiError> {
    if let Some(pending_candidate) = cursor.pending_candidate.as_ref() {
        return Ok(Some(pending_candidate.clone()));
    }
    let Some(high_water_record_id) = cursor.high_water_record_id.as_deref() else {
        return Ok(None);
    };
    let row = if let Some(after_record_id) = cursor.after_record_id.as_deref() {
        sqlx::query(
            "SELECT record_id,deleted_revision,deleted_seq FROM record_graveyard \
             WHERE vault_id=? AND auto_purge_enabled=1 AND record_id COLLATE BINARY > ? \
               AND record_id COLLATE BINARY <= ? \
             ORDER BY record_id COLLATE BINARY LIMIT 1",
        )
        .bind(vault_id)
        .bind(after_record_id)
        .bind(high_water_record_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
    } else {
        sqlx::query(
            "SELECT record_id,deleted_revision,deleted_seq FROM record_graveyard \
             WHERE vault_id=? AND auto_purge_enabled=1 AND record_id COLLATE BINARY <= ? \
             ORDER BY record_id COLLATE BINARY LIMIT 1",
        )
        .bind(vault_id)
        .bind(high_water_record_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
    };
    row.map(|row| {
        Ok(Candidate {
            vault_id: vault_id.to_owned(),
            record_id: row.try_get("record_id").map_err(ApiError::internal)?,
            deleted_revision_id: row
                .try_get("deleted_revision")
                .map_err(ApiError::internal)?,
            deleted_seq: row.try_get("deleted_seq").map_err(ApiError::internal)?,
        })
    })
    .transpose()
}

async fn process_candidate_sqlite(
    state: &AppState,
    guard: &InstanceMaintenanceGuard<'_>,
    candidate: &Candidate,
) -> Result<CandidateOutcome, ApiError> {
    if !guard.belongs_to(state) {
        return Err(ApiError::internal(
            "automatic purge scan guard does not match the target instance",
        ));
    }
    match crate::record_purge::purge_record_sqlite_maintenance(
        state,
        guard,
        &candidate.vault_id,
        &candidate.record_id,
        &candidate.deleted_revision_id,
        &candidate.deleted_seq.to_string(),
    )
    .await
    {
        Ok(_) => Ok(CandidateOutcome::Purged),
        Err(error) => match error.body.code.as_str() {
            "RECORD_PURGE_NOT_DUE" => Ok(CandidateOutcome::NotDue),
            "VAULT_REDACTION_CAPABILITY_REQUIRED" => Ok(CandidateOutcome::CapabilityBlocked),
            "RECORD_HAS_UNRESOLVED_CONFLICTS" => Ok(CandidateOutcome::ConflictBlocked),
            "REDACTION_REFERENCE_AMBIGUOUS" => Ok(CandidateOutcome::ReferenceBlocked),
            "RECORD_AUTO_PURGE_NOT_ENABLED"
            | "RECORD_NOT_PURGEABLE"
            | "RECORD_DELETE_CHANGED"
            | "VAULT_DELETION_PENDING"
            | "NOT_FOUND" => Ok(CandidateOutcome::StaleOrWithdrawn),
            _ => Err(error),
        },
    }
}

async fn checkpoint_vault_cursor(
    state: &AppState,
    lease_token: &str,
    cursor_revision: &mut i64,
    vault_id: &str,
    cursor: &VaultCursor,
    after_vault_id: Option<&str>,
    counts: &RecordAutoPurgeScanSummary,
) -> Result<(), ApiError> {
    let now = Utc::now();
    let now_text = timestamp(now);
    let expires_text = timestamp(now + chrono::Duration::seconds(LEASE_SECONDS));
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO record_auto_purge_vault_cursors( \
             vault_id,after_record_id,high_water_record_id,pending_record_id, \
             pending_deleted_revision_id,pending_deleted_seq,server_generation,updated_at \
         ) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(vault_id) DO UPDATE SET \
             after_record_id=excluded.after_record_id, \
             high_water_record_id=excluded.high_water_record_id, \
             pending_record_id=excluded.pending_record_id, \
             pending_deleted_revision_id=excluded.pending_deleted_revision_id, \
             pending_deleted_seq=excluded.pending_deleted_seq, \
             server_generation=excluded.server_generation,updated_at=excluded.updated_at",
    )
    .bind(vault_id)
    .bind(&cursor.after_record_id)
    .bind(&cursor.high_water_record_id)
    .bind(
        cursor
            .pending_candidate
            .as_ref()
            .map(|candidate| candidate.record_id.as_str()),
    )
    .bind(
        cursor
            .pending_candidate
            .as_ref()
            .map(|candidate| candidate.deleted_revision_id.as_str()),
    )
    .bind(
        cursor
            .pending_candidate
            .as_ref()
            .map(|candidate| candidate.deleted_seq),
    )
    .bind(SCAN_SERVER_GENERATION)
    .bind(&now_text)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let updated = sqlx::query(
        "UPDATE record_auto_purge_scan_control SET after_vault_id=?, \
             cursor_revision=cursor_revision+1,lease_expires_at=?, \
             last_scan_candidates=?,last_scan_purged=?,last_scan_not_due=?, \
             last_scan_capability_blocked=?,last_scan_conflict_blocked=?, \
             last_scan_reference_blocked=?,last_scan_stale_or_withdrawn=? \
         WHERE singleton=1 AND lease_token=? AND cursor_revision=? \
           AND julianday(lease_expires_at)>julianday(?) AND last_scan_status='running'",
    )
    .bind(after_vault_id)
    .bind(expires_text)
    .bind(counts.candidates)
    .bind(counts.purged)
    .bind(counts.not_due)
    .bind(counts.capability_blocked)
    .bind(counts.conflict_blocked)
    .bind(counts.reference_blocked)
    .bind(counts.stale_or_withdrawn)
    .bind(lease_token)
    .bind(*cursor_revision)
    .bind(now_text)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "AUTO_PURGE_SCAN_LEASE_LOST",
            "automatic purge scan lease changed before its cursor checkpoint",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    *cursor_revision = cursor_revision.saturating_add(1);
    Ok(())
}

async fn finish_scan(
    state: &AppState,
    lease_token: &str,
    cursor_revision: &mut i64,
    counts: &RecordAutoPurgeScanSummary,
    status: &str,
) -> Result<(), ApiError> {
    finalize_scan(state, lease_token, cursor_revision, counts, status, true).await
}

async fn fail_scan(
    state: &AppState,
    lease_token: &str,
    cursor_revision: &mut i64,
    counts: &RecordAutoPurgeScanSummary,
) -> Result<(), ApiError> {
    // The matching process/inter-instance guard remains held, so the token is
    // sufficient to release an expired lease after a long failed operation.
    finalize_scan(state, lease_token, cursor_revision, counts, "failed", false).await
}

async fn finalize_scan(
    state: &AppState,
    lease_token: &str,
    cursor_revision: &mut i64,
    counts: &RecordAutoPurgeScanSummary,
    status: &str,
    require_unexpired: bool,
) -> Result<(), ApiError> {
    let now_text = timestamp(Utc::now());
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let lease_check = if require_unexpired {
        " AND julianday(lease_expires_at)>julianday(?)"
    } else {
        ""
    };
    let query = format!(
        "UPDATE record_auto_purge_scan_control SET last_scan_status=?,last_scan_finished_at=?, \
             lease_token=NULL,lease_expires_at=NULL,cursor_revision=cursor_revision+1, \
             last_scan_candidates=?,last_scan_purged=?,last_scan_not_due=?, \
             last_scan_capability_blocked=?,last_scan_conflict_blocked=?, \
             last_scan_reference_blocked=?,last_scan_stale_or_withdrawn=? \
         WHERE singleton=1 AND lease_token=? AND cursor_revision=?{lease_check}"
    );
    let mut update = sqlx::query(&query)
        .bind(status)
        .bind(&now_text)
        .bind(counts.candidates)
        .bind(counts.purged)
        .bind(counts.not_due)
        .bind(counts.capability_blocked)
        .bind(counts.conflict_blocked)
        .bind(counts.reference_blocked)
        .bind(counts.stale_or_withdrawn)
        .bind(lease_token)
        .bind(*cursor_revision);
    if require_unexpired {
        update = update.bind(&now_text);
    }
    let updated = update.execute(&mut *tx).await.map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "AUTO_PURGE_SCAN_LEASE_LOST",
            "automatic purge scan lease changed before the scan could be finalized",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    *cursor_revision = cursor_revision.saturating_add(1);
    Ok(())
}

fn timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use std::{path::PathBuf, sync::Arc};

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey};
    use sqlx::Row;
    use uuid::Uuid;

    use super::{RecordAutoPurgeScanLimits, run_record_auto_purge_scan_sqlite};
    use crate::{Config, open_state};

    fn test_config(data_dir: PathBuf) -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: None,
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 7 * 24 * 60 * 60,
            admin_usernames: Vec::new(),
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn open_test_state(label: &str) -> (crate::AppState, PathBuf) {
        let dir = std::env::temp_dir().join(format!("atermius-scan-{label}-{}", Uuid::new_v4()));
        let url = format!("sqlite://{}/scan.db?mode=rwc", dir.display());
        let state = open_state(&url, test_config(dir.clone())).await.unwrap();
        (state, dir)
    }

    async fn insert_vault(state: &crate::AppState, vault_id: &str) {
        let user_id = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("user-{}", Uuid::new_v4()))
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,created_at) VALUES(?,?,'active',?)",
        )
        .bind(vault_id)
        .bind(user_id)
        .bind(now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,0)")
            .bind(vault_id)
            .execute(&state.db)
            .await
            .unwrap();
    }

    async fn insert_tombstone(
        state: &crate::AppState,
        vault_id: &str,
        record_id: &str,
        deleted_revision: &str,
        enabled: bool,
        deleted_seq: i64,
    ) {
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq,auto_purge_enabled,auto_purge_revision) VALUES(?,?,?,?,?,?)")
            .bind(vault_id)
            .bind(record_id)
            .bind(deleted_revision)
            .bind(deleted_seq)
            .bind(i64::from(enabled))
            .bind(i64::from(enabled))
            .execute(&state.db)
            .await
            .unwrap();
    }

    fn scan_limits(
        vaults: usize,
        candidates: usize,
        per_vault: usize,
    ) -> RecordAutoPurgeScanLimits {
        RecordAutoPurgeScanLimits {
            max_vaults: vaults,
            max_candidates: candidates,
            max_candidates_per_vault: per_vault,
        }
    }

    async fn run_scan(
        state: &crate::AppState,
        limits: RecordAutoPurgeScanLimits,
    ) -> super::RecordAutoPurgeScanSummary {
        let guard = crate::acquire_instance_maintenance_lock(state)
            .await
            .unwrap();
        run_record_auto_purge_scan_sqlite(state, &guard, limits)
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn bounded_round_robin_visits_each_vault_before_returning_to_a_large_vault() {
        let (state, dir) = open_test_state("fairness").await;
        let vault_a = "00000000-0000-0000-0000-000000000001";
        let vault_b = "00000000-0000-0000-0000-000000000002";
        insert_vault(&state, vault_a).await;
        insert_vault(&state, vault_b).await;
        let revision = "10000000-0000-0000-0000-000000000001";
        for id in 1..=5 {
            let record = format!("20000000-0000-0000-0000-{id:012x}");
            insert_tombstone(&state, vault_a, &record, revision, true, id).await;
        }
        let b_record = "30000000-0000-0000-0000-000000000001";
        insert_tombstone(&state, vault_b, b_record, revision, true, 1).await;

        let first = run_scan(&state, scan_limits(2, 2, 1)).await;
        assert_eq!(first.candidates, 2);
        assert_eq!(first.capability_blocked, 2);
        let after_a: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault_a)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let after_b: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault_b)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after_a, "20000000-0000-0000-0000-000000000001");
        assert_eq!(after_b, b_record);

        let second = run_scan(&state, scan_limits(2, 2, 1)).await;
        // A is the only Vault with another candidate. B's next visit closes
        // its already-exhausted high-water sweep, so it consumes a Vault
        // visit but no candidate quota.
        assert_eq!(second.candidates, 1);
        assert_eq!(second.capability_blocked, 1);
        let after_a: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault_a)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after_a, "20000000-0000-0000-0000-000000000002");
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn blocked_candidate_is_a_terminal_result_for_this_sweep_and_cursor_moves_on() {
        let (state, dir) = open_test_state("blocked-progress").await;
        let vault = "00000000-0000-0000-0000-000000000010";
        insert_vault(&state, vault).await;
        for id in 1..=2 {
            insert_tombstone(
                &state,
                vault,
                &format!("20000000-0000-0000-0000-{id:012x}"),
                "10000000-0000-0000-0000-000000000010",
                true,
                id,
            )
            .await;
        }
        let first = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(first.capability_blocked, 1);
        let first_cursor: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(first_cursor, "20000000-0000-0000-0000-000000000001");

        let second = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(second.capability_blocked, 1);
        let second_cursor: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(second_cursor, "20000000-0000-0000-0000-000000000002");
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn selected_candidates_recheck_opt_out_and_restore_before_maintenance_purge() {
        let (state, dir) = open_test_state("selection-race").await;
        let vault = "00000000-0000-0000-0000-000000000015";
        let opted_out_record = "20000000-0000-0000-0000-000000000015";
        let restored_record = "20000000-0000-0000-0000-000000000016";
        let revision = "10000000-0000-0000-0000-000000000015";
        insert_vault(&state, vault).await;
        insert_tombstone(&state, vault, opted_out_record, revision, true, 1).await;
        insert_tombstone(&state, vault, restored_record, revision, true, 2).await;

        // The cursor staging update is after next_candidate selected the row
        // and before process_candidate_sqlite invokes the real maintenance
        // purge. Mutate one candidate's consent and remove the other's
        // tombstone at that exact boundary to exercise the race deterministically.
        sqlx::query(&format!(
            "CREATE TRIGGER mutate_candidate_after_selection \
             AFTER UPDATE ON record_auto_purge_vault_cursors \
             WHEN NEW.pending_record_id IS NOT NULL BEGIN \
               UPDATE record_graveyard SET auto_purge_enabled=0, \
                 auto_purge_revision=auto_purge_revision+1 \
               WHERE vault_id=NEW.vault_id AND record_id='{opted_out_record}' \
                 AND NEW.pending_record_id='{opted_out_record}'; \
               DELETE FROM record_graveyard \
               WHERE vault_id=NEW.vault_id AND record_id='{restored_record}' \
                 AND NEW.pending_record_id='{restored_record}'; \
             END"
        ))
        .execute(&state.db)
        .await
        .unwrap();

        let result = run_scan(&state, scan_limits(1, 2, 2)).await;
        assert_eq!(result.candidates, 2);
        assert_eq!(result.stale_or_withdrawn, 2);
        assert_eq!(result.purged, 0);
        let opted_out: i64 = sqlx::query_scalar(
            "SELECT auto_purge_enabled FROM record_graveyard WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(opted_out_record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(opted_out, 0);
        let restored_exists: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_graveyard WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(restored_record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(restored_exists, 0);
        let redactions: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_redactions WHERE vault_id=?")
                .bind(vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(redactions, 0);
        let cursor: (Option<String>, Option<String>) = sqlx::query_as(
            "SELECT after_record_id,pending_record_id \
             FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(cursor, (Some(restored_record.to_owned()), None));
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn keyset_high_water_excludes_later_rows_until_the_next_sweep_then_wraps() {
        let (state, dir) = open_test_state("high-water").await;
        let vault = "00000000-0000-0000-0000-000000000020";
        insert_vault(&state, vault).await;
        for id in [1, 3] {
            insert_tombstone(
                &state,
                vault,
                &format!("20000000-0000-0000-0000-{id:012x}"),
                "10000000-0000-0000-0000-000000000020",
                true,
                id,
            )
            .await;
        }
        let first = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(first.candidates, 1);
        let high_water: String = sqlx::query_scalar(
            "SELECT high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(high_water, "20000000-0000-0000-0000-000000000003");
        insert_tombstone(
            &state,
            vault,
            "20000000-0000-0000-0000-000000000004",
            "10000000-0000-0000-0000-000000000020",
            true,
            4,
        )
        .await;

        let second = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(second.candidates, 1);
        let after_second: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after_second, high_water);

        let close_sweep = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(close_sweep.candidates, 0);
        let closed: (Option<String>, Option<String>) = sqlx::query_as(
            "SELECT after_record_id,high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(closed, (None, None));

        let wrapped = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(wrapped.candidates, 1);
        let after_wrap: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after_wrap, "20000000-0000-0000-0000-000000000001");
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn cursor_survives_state_restart_with_the_same_keyset_position() {
        let (state, dir) = open_test_state("restart-cursor").await;
        let vault = "00000000-0000-0000-0000-000000000030";
        insert_vault(&state, vault).await;
        for id in 1..=2 {
            insert_tombstone(
                &state,
                vault,
                &format!("20000000-0000-0000-0000-{id:012x}"),
                "10000000-0000-0000-0000-000000000030",
                true,
                id,
            )
            .await;
        }
        let first = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(first.capability_blocked, 1);
        drop(state);

        let url = format!("sqlite://{}/scan.db?mode=rwc", dir.display());
        let reopened = open_state(&url, test_config(dir.clone())).await.unwrap();
        // The first keyset position persisted through process restart; the
        // reopened state resumes at the next canonical record ID.
        let after_restart = run_scan(&reopened, scan_limits(1, 1, 1)).await;
        assert_eq!(after_restart.capability_blocked, 1);
        let after_id: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&reopened.db)
        .await
        .unwrap();
        assert_eq!(after_id, "20000000-0000-0000-0000-000000000002");
        let wrap = run_scan(&reopened, scan_limits(1, 1, 1)).await;
        assert_eq!(wrap.candidates, 0);
        let diagnostics = sqlx::query(
            "SELECT last_scan_status,last_scan_candidates,last_scan_purged, \
                    last_scan_not_due,last_scan_capability_blocked,last_scan_conflict_blocked, \
                    last_scan_reference_blocked,last_scan_stale_or_withdrawn \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&reopened.db)
        .await
        .unwrap();
        let status: String = diagnostics.try_get("last_scan_status").unwrap();
        let candidates: i64 = diagnostics.try_get("last_scan_candidates").unwrap();
        assert_eq!(status, "completed");
        assert_eq!(candidates, 0);
        drop(reopened);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn withdrawn_or_restored_exact_candidate_is_classified_as_stale() {
        let (state, dir) = open_test_state("withdrawn-stale").await;
        let vault = "00000000-0000-0000-0000-000000000035";
        let opted_out_record = "20000000-0000-0000-0000-000000000035";
        let restored_record = "20000000-0000-0000-0000-000000000036";
        let revision = "10000000-0000-0000-0000-000000000035";
        insert_vault(&state, vault).await;
        insert_tombstone(&state, vault, opted_out_record, revision, true, 1).await;
        insert_tombstone(&state, vault, restored_record, revision, true, 2).await;
        let guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();

        sqlx::query("UPDATE record_graveyard SET auto_purge_enabled=0,auto_purge_revision=auto_purge_revision+1 WHERE vault_id=? AND record_id=?")
            .bind(vault)
            .bind(opted_out_record)
            .execute(&state.db)
            .await
            .unwrap();
        let opted_out = super::Candidate {
            vault_id: vault.to_owned(),
            record_id: opted_out_record.to_owned(),
            deleted_revision_id: revision.to_owned(),
            deleted_seq: 1,
        };
        assert!(matches!(
            super::process_candidate_sqlite(&state, &guard, &opted_out)
                .await
                .unwrap(),
            super::CandidateOutcome::StaleOrWithdrawn
        ));

        sqlx::query("DELETE FROM record_graveyard WHERE vault_id=? AND record_id=?")
            .bind(vault)
            .bind(restored_record)
            .execute(&state.db)
            .await
            .unwrap();
        let restored = super::Candidate {
            vault_id: vault.to_owned(),
            record_id: restored_record.to_owned(),
            deleted_revision_id: revision.to_owned(),
            deleted_seq: 2,
        };
        assert!(matches!(
            super::process_candidate_sqlite(&state, &guard, &restored)
                .await
                .unwrap(),
            super::CandidateOutcome::StaleOrWithdrawn
        ));
        drop(guard);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn restored_candidate_is_skipped_and_next_keyset_candidate_still_advances() {
        let (state, dir) = open_test_state("restore-stale").await;
        let vault = "00000000-0000-0000-0000-000000000040";
        insert_vault(&state, vault).await;
        for id in 1..=2 {
            insert_tombstone(
                &state,
                vault,
                &format!("20000000-0000-0000-0000-{id:012x}"),
                "10000000-0000-0000-0000-000000000040",
                true,
                id,
            )
            .await;
        }
        let first = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(first.capability_blocked, 1);
        sqlx::query("DELETE FROM record_graveyard WHERE vault_id=? AND record_id=?")
            .bind(vault)
            .bind("20000000-0000-0000-0000-000000000001")
            .execute(&state.db)
            .await
            .unwrap();
        let second = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(second.capability_blocked, 1);
        let after: String = sqlx::query_scalar(
            "SELECT after_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(after, "20000000-0000-0000-0000-000000000002");
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn exact_purge_replay_is_counted_as_success_without_requiring_opt_in_again() {
        let (state, dir) = open_test_state("purge-replay").await;
        let vault = "00000000-0000-0000-0000-000000000050";
        insert_vault(&state, vault).await;
        let record = "20000000-0000-0000-0000-000000000050";
        let revision = "10000000-0000-0000-0000-000000000050";
        insert_tombstone(&state, vault, record, revision, true, 1).await;
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,1,2,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(vault)
            .bind(record)
            .bind(revision)
            .bind(crate::now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let result = run_scan(&state, scan_limits(1, 1, 1)).await;
        assert_eq!(result.candidates, 1);
        assert_eq!(result.purged, 1);
        let redactions: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_redactions WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(redactions, 1);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn scanner_completes_a_first_time_purge_through_the_maintenance_service() {
        let (state, dir) = open_test_state("maintenance-purge").await;
        let vault = "00000000-0000-0000-0000-000000000052";
        let user = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let record = "20000000-0000-0000-0000-000000000052";
        let revision = "10000000-0000-0000-0000-000000000052";
        let now = crate::now_rfc3339();
        let signing_key = SigningKey::from_bytes(&[52; 32]);
        let signing_public_key = URL_SAFE_NO_PAD.encode(signing_key.verifying_key().as_bytes());
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind(format!("maintenance-{}", Uuid::new_v4()))
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,created_at) \
             VALUES(?,?,'active',?)",
        )
        .bind(vault)
        .bind(&user)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(vault)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key, \
                 encryption_public_key,created_at) VALUES(?,?,?,?,'test-encryption-key',?)",
        )
        .bind(&device)
        .bind(&user)
        .bind("scanner maintenance test")
        .bind(&signing_public_key)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        let report = serde_json::json!({
            "format": crate::redaction_capabilities::REPORT_FORMAT,
            "account_id": user,
            "device_id": device,
            "revision": 1,
            "sync_redaction_version": 1,
        });
        let signature =
            URL_SAFE_NO_PAD.encode(signing_key.sign(&crate::jcs(&report).unwrap()).to_bytes());
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,user_id,revision,sync_redaction_version,signature,updated_at \
             ) VALUES(?,?,1,1,?,?)",
        )
        .bind(&device)
        .bind(&user)
        .bind(signature)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) \
             VALUES(?,3,0)",
        )
        .bind(vault)
        .execute(&state.db)
        .await
        .unwrap();

        let deleted_at = (chrono::Utc::now() - chrono::Duration::days(60)).to_rfc3339();
        let restore_until = (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
        let envelope = serde_json::json!({"header":{"revision_id":revision}}).to_string();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES(?,?,?,NULL,?,'maintenance-scan-test',1,?,'delete',?,?)",
        )
        .bind(vault)
        .bind(record)
        .bind(revision)
        .bind(&envelope)
        .bind(&device)
        .bind(&deleted_at)
        .bind(&restore_until)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES(?,?,?,1,1)",
        )
        .bind(vault)
        .bind(record)
        .bind(revision)
        .execute(&state.db)
        .await
        .unwrap();
        insert_tombstone(&state, vault, record, revision, true, 1).await;
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id, \
                 envelope,created_at) VALUES(?,1,'delete',?,?,?,?)",
        )
        .bind(vault)
        .bind(record)
        .bind(revision)
        .bind(&envelope)
        .bind(&deleted_at)
        .execute(&state.db)
        .await
        .unwrap();

        let not_due_record = "20000000-0000-0000-0000-000000000053";
        let not_due_revision = "10000000-0000-0000-0000-000000000053";
        let not_due_envelope =
            serde_json::json!({"header":{"revision_id":not_due_revision}}).to_string();
        let not_due_created_at = chrono::Utc::now().to_rfc3339();
        let not_due_restore_until = (chrono::Utc::now() + chrono::Duration::days(30)).to_rfc3339();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES(?,?,?,NULL,?,'maintenance-scan-not-due',2,?,'delete',?,?)",
        )
        .bind(vault)
        .bind(not_due_record)
        .bind(not_due_revision)
        .bind(&not_due_envelope)
        .bind(&device)
        .bind(&not_due_created_at)
        .bind(&not_due_restore_until)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES(?,?,?,1,2)",
        )
        .bind(vault)
        .bind(not_due_record)
        .bind(not_due_revision)
        .execute(&state.db)
        .await
        .unwrap();
        insert_tombstone(&state, vault, not_due_record, not_due_revision, true, 2).await;
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id, \
                 envelope,created_at) VALUES(?,2,'delete',?,?,?,?)",
        )
        .bind(vault)
        .bind(not_due_record)
        .bind(not_due_revision)
        .bind(&not_due_envelope)
        .bind(&not_due_created_at)
        .execute(&state.db)
        .await
        .unwrap();

        let unconsented_record = "20000000-0000-0000-0000-000000000054";
        let unconsented_revision = "10000000-0000-0000-0000-000000000054";
        let unconsented_envelope =
            serde_json::json!({"header":{"revision_id":unconsented_revision}}).to_string();
        let unconsented_deleted_at = (chrono::Utc::now() - chrono::Duration::days(60)).to_rfc3339();
        let unconsented_restore_until =
            (chrono::Utc::now() - chrono::Duration::days(30)).to_rfc3339();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES(?,?,?,NULL,?,'maintenance-scan-no-consent',3,?,'delete',?,?)",
        )
        .bind(vault)
        .bind(unconsented_record)
        .bind(unconsented_revision)
        .bind(&unconsented_envelope)
        .bind(&device)
        .bind(&unconsented_deleted_at)
        .bind(&unconsented_restore_until)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES(?,?,?,1,3)",
        )
        .bind(vault)
        .bind(unconsented_record)
        .bind(unconsented_revision)
        .execute(&state.db)
        .await
        .unwrap();
        insert_tombstone(
            &state,
            vault,
            unconsented_record,
            unconsented_revision,
            false,
            3,
        )
        .await;
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id, \
                 envelope,created_at) VALUES(?,3,'delete',?,?,?,?)",
        )
        .bind(vault)
        .bind(unconsented_record)
        .bind(unconsented_revision)
        .bind(&unconsented_envelope)
        .bind(&unconsented_deleted_at)
        .execute(&state.db)
        .await
        .unwrap();

        crate::run_maintenance(&state).await.unwrap();
        let redaction: (String, String, String, i64, i64) = sqlx::query_as(
            "SELECT redaction_id,record_id,deleted_revision_id,deleted_seq,redaction_seq \
             FROM record_redactions WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(redaction.1, record);
        assert_eq!(redaction.2, revision);
        assert_eq!((redaction.3, redaction.4), (1, 4));
        let redacted_head_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(redacted_head_count, 0);
        let consent: (i64, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=? AND record_id=?",
        )
        .bind(vault)
        .bind(record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(consent, (0, 2));

        let not_due_state: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?), \
                    (SELECT auto_purge_enabled FROM record_graveyard WHERE vault_id=? AND record_id=?)",
        )
        .bind(vault)
        .bind(not_due_record)
        .bind(vault)
        .bind(not_due_record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(not_due_state, (1, 1));
        let unconsented_state: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?), \
                    (SELECT auto_purge_enabled FROM record_graveyard WHERE vault_id=? AND record_id=?)",
        )
        .bind(vault)
        .bind(unconsented_record)
        .bind(vault)
        .bind(unconsented_record)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(unconsented_state, (1, 0));

        let sequence_after_first_pass: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        crate::run_maintenance(&state).await.unwrap();
        let sequence_after_repeat: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(sequence_after_repeat, sequence_after_first_pass);
        let redaction_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_redactions WHERE vault_id=?")
                .bind(vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(redaction_count, 1);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn pending_identity_replays_a_committed_purge_after_checkpoint_failure() {
        let (state, dir) = open_test_state("pending-replay").await;
        let vault = "00000000-0000-0000-0000-000000000055";
        let record = "20000000-0000-0000-0000-000000000055";
        let revision = "10000000-0000-0000-0000-000000000055";
        insert_vault(&state, vault).await;
        insert_tombstone(&state, vault, record, revision, true, 1).await;
        // Model a purge transaction that committed its immutable redaction
        // proof but lost the cursor checkpoint/acknowledgement.
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,1,2,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(vault)
            .bind(record)
            .bind(revision)
            .bind(crate::now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(&format!(
            "CREATE TRIGGER reject_terminal_scan_checkpoint BEFORE UPDATE ON record_auto_purge_vault_cursors \
             WHEN NEW.after_record_id='{record}' AND NEW.pending_record_id IS NULL \
             BEGIN SELECT RAISE(ABORT,'injected post-purge checkpoint failure'); END"
        ))
        .execute(&state.db)
        .await
        .unwrap();

        let guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();
        let failed = run_record_auto_purge_scan_sqlite(&state, &guard, scan_limits(1, 1, 1))
            .await
            .unwrap_err();
        assert_eq!(failed.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        let pending: (Option<String>, Option<String>, Option<i64>) = sqlx::query_as(
            "SELECT pending_record_id,pending_deleted_revision_id,pending_deleted_seq \
             FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            pending,
            (Some(record.to_owned()), Some(revision.to_owned()), Some(1))
        );
        sqlx::query("DROP TRIGGER reject_terminal_scan_checkpoint")
            .execute(&state.db)
            .await
            .unwrap();
        // The original purge consumes consent. The pending tuple remains
        // eligible for an exact idempotent redaction replay.
        sqlx::query("UPDATE record_graveyard SET auto_purge_enabled=0,auto_purge_revision=auto_purge_revision+1 WHERE vault_id=? AND record_id=?")
            .bind(vault)
            .bind(record)
            .execute(&state.db)
            .await
            .unwrap();
        let replay = run_record_auto_purge_scan_sqlite(&state, &guard, scan_limits(1, 1, 1))
            .await
            .unwrap();
        assert_eq!(replay.purged, 1);
        let cursor: (Option<String>, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT after_record_id,pending_record_id,pending_deleted_revision_id \
             FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(cursor.0.as_deref(), Some(record));
        assert_eq!(cursor.1, None);
        assert_eq!(cursor.2, None);
        drop(guard);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn pending_stage_failure_marks_failed_without_counting_an_unattempted_candidate() {
        let (state, dir) = open_test_state("failure-checkpoint").await;
        let vault = "00000000-0000-0000-0000-000000000060";
        insert_vault(&state, vault).await;
        let record = "20000000-0000-0000-0000-000000000060";
        insert_tombstone(
            &state,
            vault,
            record,
            "10000000-0000-0000-0000-000000000060",
            true,
            1,
        )
        .await;
        sqlx::query("CREATE TRIGGER reject_scan_cursor_checkpoint BEFORE UPDATE ON record_auto_purge_vault_cursors BEGIN SELECT RAISE(ABORT,'injected scan checkpoint failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        let guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();
        let error = run_record_auto_purge_scan_sqlite(&state, &guard, scan_limits(1, 1, 1))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        let control = sqlx::query(
            "SELECT last_scan_status,last_scan_candidates,lease_token,lease_expires_at \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        let status: String = control.try_get("last_scan_status").unwrap();
        let attempted: i64 = control.try_get("last_scan_candidates").unwrap();
        let token: Option<String> = control.try_get("lease_token").unwrap();
        let expiry: Option<String> = control.try_get("lease_expires_at").unwrap();
        assert_eq!(status, "failed");
        // The injected cursor trigger rejects durable pending staging, so the
        // purge writer was never called and no candidate attempt is recorded.
        assert_eq!(attempted, 0);
        assert!(token.is_none() && expiry.is_none());
        let cursor: (Option<String>, Option<String>) = sqlx::query_as(
            "SELECT after_record_id,high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(cursor.0, None);
        assert_eq!(cursor.1, Some(record.to_owned()));
        drop(guard);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn injected_purge_writer_failure_marks_failed_and_keeps_current_record() {
        let (state, dir) = open_test_state("purge-transient").await;
        let vault = "00000000-0000-0000-0000-000000000070";
        let record = "20000000-0000-0000-0000-000000000070";
        insert_vault(&state, vault).await;
        insert_tombstone(
            &state,
            vault,
            record,
            "10000000-0000-0000-0000-000000000070",
            true,
            1,
        )
        .await;
        sqlx::query("CREATE TRIGGER reject_purge_writer BEFORE UPDATE ON vault_counters BEGIN SELECT RAISE(ABORT,'injected transient purge failure'); END")
            .execute(&state.db)
            .await
            .unwrap();

        let guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();
        let error = run_record_auto_purge_scan_sqlite(&state, &guard, scan_limits(1, 1, 1))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        let control = sqlx::query(
            "SELECT last_scan_status,last_scan_candidates,last_scan_capability_blocked \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            control.try_get::<String, _>("last_scan_status").unwrap(),
            "failed"
        );
        assert_eq!(
            control.try_get::<i64, _>("last_scan_candidates").unwrap(),
            1
        );
        assert_eq!(
            control
                .try_get::<i64, _>("last_scan_capability_blocked")
                .unwrap(),
            0
        );
        let cursor: (Option<String>, Option<String>) = sqlx::query_as(
            "SELECT after_record_id,high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=?",
        )
        .bind(vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(cursor.0, None);
        assert_eq!(cursor.1, Some(record.to_owned()));
        drop(guard);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[tokio::test]
    async fn wrong_instance_guard_is_rejected_before_scan_state_is_touched() {
        let (state, dir) = open_test_state("wrong-guard").await;
        let guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();
        let mut other_state = state.clone();
        let mut config = (*state.config).clone();
        config.data_dir = dir.join("other-instance");
        other_state.config = Arc::new(config);
        let error = run_record_auto_purge_scan_sqlite(
            &other_state,
            &guard,
            RecordAutoPurgeScanLimits::default(),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        let status: String = sqlx::query_scalar(
            "SELECT last_scan_status FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(status, "never");
        drop(guard);
        drop(state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn scanner_cannot_acquire_the_guard_while_restore_owns_it() {
        let (restore_state, dir) = open_test_state("restore-scan-guard").await;
        let vault = "00000000-0000-0000-0000-000000000080";
        insert_vault(&restore_state, vault).await;
        insert_tombstone(
            &restore_state,
            vault,
            "20000000-0000-0000-0000-000000000080",
            "10000000-0000-0000-0000-000000000080",
            true,
            1,
        )
        .await;

        // Online restore staging acquires this same guard. A separately
        // opened AppState models its scanner worker and exercises the shared
        // interprocess maintenance.lock, rather than only the local Mutex.
        let scanner_url = format!("sqlite://{}/scan.db?mode=rwc", dir.display());
        let scanner_state = crate::open_state(&scanner_url, test_config(dir.clone()))
            .await
            .unwrap();
        let restore_guard = crate::acquire_instance_maintenance_lock(&restore_state)
            .await
            .unwrap();
        let before: (String, i64, Option<String>, Option<String>, i64, i64) = sqlx::query_as(
            "SELECT last_scan_status,cursor_revision,after_vault_id,lease_token, \
                    last_scan_candidates,last_scan_purged \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&restore_state.db)
        .await
        .unwrap();
        let cursors_before: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                .fetch_one(&restore_state.db)
                .await
                .unwrap();

        let contention = match crate::acquire_instance_maintenance_lock(&scanner_state).await {
            Err(error) => error,
            Ok(scanner_guard) => {
                drop(scanner_guard);
                panic!("scanner acquired the maintenance guard while restore held it");
            }
        };
        assert_eq!(contention.body.code, "MAINTENANCE_ALREADY_RUNNING");
        let after: (String, i64, Option<String>, Option<String>, i64, i64) = sqlx::query_as(
            "SELECT last_scan_status,cursor_revision,after_vault_id,lease_token, \
                    last_scan_candidates,last_scan_purged \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&restore_state.db)
        .await
        .unwrap();
        let cursors_after: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                .fetch_one(&restore_state.db)
                .await
                .unwrap();
        assert_eq!(after, before);
        assert_eq!(cursors_after, cursors_before);
        assert_eq!(cursors_after, 0);

        drop(restore_guard);
        drop(scanner_state);
        drop(restore_state);
        let _ = tokio::fs::remove_dir_all(dir).await;
    }
}

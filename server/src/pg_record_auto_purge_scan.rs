//! Bounded PostgreSQL automatic tombstone scanner state.
//!
//! Maintenance invokes this scanner with fixed quotas. It persists fair Vault
//! and per-Vault keyset checkpoints. Each purge and checkpoint is a separate
//! transaction: the existing idempotent maintenance purge route is the only
//! safe way to retry a lost ACK.

use std::{future::Future, pin::Pin};

use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, pg_record_purge::PgRecordPurgeRepository};

const SCAN_SERVER_GENERATION: i64 = 1;
const MAX_VAULT_QUOTA: i64 = 256;
const MAX_PER_VAULT_QUOTA: i64 = 256;

#[derive(Clone)]
pub(crate) struct PgRecordAutoPurgeScanRepository {
    pool: PgPool,
    purge: PgRecordPurgeRepository,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct PgRecordAutoPurgeScanCounters {
    pub(crate) candidates: i64,
    pub(crate) purged: i64,
    pub(crate) not_due: i64,
    pub(crate) capability_blocked: i64,
    pub(crate) conflict_blocked: i64,
    pub(crate) reference_blocked: i64,
    pub(crate) stale_or_withdrawn: i64,
}

/// Aggregate-only result. It deliberately contains no Vault or record IDs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PgRecordAutoPurgeScanReport {
    pub(crate) acquired: bool,
    pub(crate) fenced: bool,
    pub(crate) counters: PgRecordAutoPurgeScanCounters,
}

#[derive(Clone, Debug)]
struct ScanClaim {
    token: String,
    revision: i64,
    lease_seconds: i64,
}

#[derive(Clone, Debug)]
struct VaultCursor {
    after_record_id: Option<String>,
    high_water_record_id: Option<String>,
    pending: Option<ScanCandidate>,
}

#[derive(Clone, Debug)]
struct ScanCandidate {
    vault_id: String,
    record_id: String,
    deleted_revision_id: String,
    deleted_seq: i64,
    policy_revision: i64,
}

#[derive(Clone, Copy, Debug)]
enum TerminalBucket {
    Purged,
    NotDue,
    CapabilityBlocked,
    ConflictBlocked,
    ReferenceBlocked,
    StaleOrWithdrawn,
}

type ProcessFuture =
    Pin<Box<dyn Future<Output = Result<TerminalBucket, ApiError>> + Send + 'static>>;

impl PgRecordAutoPurgeScanRepository {
    pub(crate) fn new(pool: PgPool, purge: PgRecordPurgeRepository) -> Self {
        Self { pool, purge }
    }

    /// Runs one bounded pass. `vault_quota` is the maximum number of Vaults
    /// considered; `per_vault_quota` is the maximum number of records visited
    /// in each Vault. Callers should use a stable positive algorithm
    /// generation (currently 1), not a process boot ID, so restarts resume the
    /// same high-water/keyset cursor.
    pub(crate) async fn scan_batch(
        &self,
        vault_quota: i64,
        per_vault_quota: i64,
        lease_seconds: i64,
        object_gc_grace_seconds: i64,
    ) -> Result<PgRecordAutoPurgeScanReport, ApiError> {
        let purge = self.purge.clone();
        self.scan_batch_with(
            vault_quota,
            per_vault_quota,
            lease_seconds,
            move |candidate| {
                let purge = purge.clone();
                Box::pin(async move {
                    match purge
                        .purge_for_maintenance(
                            &candidate.vault_id,
                            &candidate.record_id,
                            &candidate.deleted_revision_id,
                            &candidate.deleted_seq.to_string(),
                            object_gc_grace_seconds,
                        )
                        .await
                    {
                        Ok(_) => Ok(TerminalBucket::Purged),
                        Err(error) => terminal_bucket(error),
                    }
                })
            },
        )
        .await
    }

    async fn scan_batch_with<F>(
        &self,
        vault_quota: i64,
        per_vault_quota: i64,
        lease_seconds: i64,
        mut process: F,
    ) -> Result<PgRecordAutoPurgeScanReport, ApiError>
    where
        F: FnMut(ScanCandidate) -> ProcessFuture,
    {
        if !(1..=MAX_VAULT_QUOTA).contains(&vault_quota)
            || !(1..=MAX_PER_VAULT_QUOTA).contains(&per_vault_quota)
            || !(1..=300).contains(&lease_seconds)
        {
            return Err(ApiError::bad_request(
                "INVALID_AUTO_PURGE_SCAN_BOUNDS",
                "automatic purge scan bounds are outside the supported range",
            ));
        }

        let Some(claim) = self.claim(lease_seconds).await? else {
            return Ok(PgRecordAutoPurgeScanReport {
                acquired: false,
                fenced: false,
                counters: self.read_counters().await?,
            });
        };

        let result = self
            .run_claimed_pass(&claim, vault_quota, per_vault_quota, &mut process)
            .await;
        match result {
            Ok(fenced) => {
                let fenced = if fenced {
                    true
                } else {
                    !self.finish_claim(&claim, false).await?
                };
                Ok(PgRecordAutoPurgeScanReport {
                    acquired: true,
                    fenced,
                    counters: self.read_counters().await?,
                })
            }
            Err(_) => {
                // Never persist a raw database/signing error, record ID, or
                // tombstone identity in scan diagnostics.
                let _ = self.finish_claim(&claim, true).await;
                Err(ApiError::internal("automatic purge scan failed"))
            }
        }
    }

    async fn run_claimed_pass<F>(
        &self,
        claim: &ScanClaim,
        vault_quota: i64,
        per_vault_quota: i64,
        process: &mut F,
    ) -> Result<bool, ApiError>
    where
        F: FnMut(ScanCandidate) -> ProcessFuture,
    {
        let Some(vault_ids) = self.select_vaults(claim, vault_quota).await? else {
            return Ok(true);
        };

        for vault_id in vault_ids {
            let Some(cursor) = self.prepare_vault_cursor(claim, &vault_id).await? else {
                return Ok(true);
            };
            let mut cursor = cursor;
            let mut terminal_count = 0_i64;
            if let Some(pending) = cursor.pending.take() {
                if !self.renew_claim(claim).await? {
                    return Ok(true);
                }
                // A pending identity is retried through the idempotent purge
                // route even if purge already consumed its opt-in flag.
                let bucket = match process(pending.clone()).await {
                    Ok(bucket) => bucket,
                    Err(_) => {
                        self.fail_candidate_attempt(claim).await?;
                        return Err(ApiError::internal("automatic purge scan failed"));
                    }
                };
                if !self.checkpoint_candidate(claim, &pending, bucket).await? {
                    return Ok(true);
                }
                cursor.after_record_id = Some(pending.record_id);
                terminal_count = 1;
            }
            let remaining_quota = per_vault_quota - terminal_count;
            if remaining_quota == 0 {
                continue;
            }
            let candidates = self
                .read_candidates(&vault_id, &cursor, remaining_quota)
                .await?;

            for candidate in &candidates {
                if !self.renew_claim(claim).await? {
                    return Ok(true);
                }
                let bucket = if !self.candidate_policy_is_current(candidate).await? {
                    TerminalBucket::StaleOrWithdrawn
                } else if !self.set_pending_candidate(claim, candidate).await? {
                    return Ok(true);
                } else {
                    match process(candidate.clone()).await {
                        Ok(bucket) => bucket,
                        Err(_) => {
                            self.fail_candidate_attempt(claim).await?;
                            return Err(ApiError::internal("automatic purge scan failed"));
                        }
                    }
                };
                if !self.checkpoint_candidate(claim, candidate, bucket).await? {
                    return Ok(true);
                }
            }

            // A short page means this fixed high-water pass is exhausted.
            // Clearing it happens only after all returned rows reached a
            // terminal result and were checkpointed above.
            if candidates.len() < remaining_quota as usize {
                if !self.finish_vault_cursor(claim, &vault_id).await? {
                    return Ok(true);
                }
            }
        }
        Ok(false)
    }

    async fn claim(&self, lease_seconds: i64) -> Result<Option<ScanClaim>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let row = sqlx::query(
            "SELECT cursor_revision,lease_token,lease_expires_at, \
                    clock_timestamp() AS now FROM record_auto_purge_scan_control \
             WHERE singleton=1 FOR UPDATE",
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let old_revision: i64 = row.try_get("cursor_revision").map_err(ApiError::internal)?;
        let old_token: Option<String> = row.try_get("lease_token").map_err(ApiError::internal)?;
        let old_expiry: Option<chrono::DateTime<chrono::Utc>> = row
            .try_get("lease_expires_at")
            .map_err(ApiError::internal)?;
        let now: chrono::DateTime<chrono::Utc> = row.try_get("now").map_err(ApiError::internal)?;
        if old_token.is_some() && old_expiry.is_some_and(|expires| expires > now) {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(None);
        }
        let revision = old_revision.checked_add(1).ok_or_else(|| {
            ApiError::internal("automatic purge scan fencing revision is exhausted")
        })?;
        let token = Uuid::new_v4().to_string();
        let cursor_update = sqlx::query(
            "UPDATE record_auto_purge_scan_control SET \
                 after_vault_id=CASE WHEN server_generation=$1 THEN after_vault_id ELSE NULL END, \
                 server_generation=$1,cursor_revision=$2,lease_token=$3, \
                 lease_expires_at=clock_timestamp()+make_interval(secs=>$4::double precision), \
                 last_scan_status='running',last_scan_started_at=clock_timestamp(), \
                 last_scan_finished_at=NULL,last_scan_candidates=0,last_scan_purged=0, \
                 last_scan_not_due=0,last_scan_capability_blocked=0, \
                 last_scan_conflict_blocked=0,last_scan_reference_blocked=0, \
                 last_scan_stale_or_withdrawn=0 WHERE singleton=1",
        )
        .bind(SCAN_SERVER_GENERATION)
        .bind(revision)
        .bind(&token)
        .bind(lease_seconds)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if cursor_update.rows_affected() != 1 {
            return Err(ApiError::internal(
                "automatic purge scan control row is unavailable",
            ));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(Some(ScanClaim {
            token,
            revision,
            lease_seconds,
        }))
    }

    async fn select_vaults(
        &self,
        claim: &ScanClaim,
        vault_quota: i64,
    ) -> Result<Option<Vec<String>>, ApiError> {
        let after_vault_row: Option<Option<String>> = sqlx::query_scalar::<_, Option<String>>(
            "SELECT after_vault_id FROM record_auto_purge_scan_control \
             WHERE singleton=1 AND lease_token=$1 AND cursor_revision=$2 \
               AND lease_expires_at>clock_timestamp()",
        )
        .bind(&claim.token)
        .bind(claim.revision)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let after_vault_id = after_vault_row.unwrap_or(None);
        if !self.renew_claim(claim).await? {
            return Ok(None);
        }

        let after_rows = sqlx::query_scalar::<_, String>(
            "SELECT v.vault_id FROM vaults v \
             WHERE v.state='active' AND ($1::text IS NULL OR v.vault_id COLLATE \"C\" > $1::text COLLATE \"C\") \
               AND (EXISTS(SELECT 1 FROM record_graveyard g WHERE g.vault_id=v.vault_id AND g.auto_purge_enabled=TRUE) \
                    OR EXISTS(SELECT 1 FROM record_auto_purge_vault_cursors c \
                              WHERE c.vault_id=v.vault_id \
                                AND (c.high_water_record_id IS NOT NULL OR c.pending_record_id IS NOT NULL))) \
             ORDER BY v.vault_id COLLATE \"C\" LIMIT $2",
        )
        .bind(&after_vault_id)
        .bind(vault_quota)
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let mut vault_ids = after_rows;
        if vault_ids.len() < vault_quota as usize
            && let Some(after_vault_id) = after_vault_id
        {
            let remaining = vault_quota as usize - vault_ids.len();
            let wrap_rows = sqlx::query_scalar::<_, String>(
                "SELECT v.vault_id FROM vaults v \
                 WHERE v.state='active' AND v.vault_id COLLATE \"C\" <= $1::text COLLATE \"C\" \
                   AND (EXISTS(SELECT 1 FROM record_graveyard g WHERE g.vault_id=v.vault_id AND g.auto_purge_enabled=TRUE) \
                        OR EXISTS(SELECT 1 FROM record_auto_purge_vault_cursors c \
                                  WHERE c.vault_id=v.vault_id \
                                    AND (c.high_water_record_id IS NOT NULL OR c.pending_record_id IS NOT NULL))) \
                 ORDER BY v.vault_id COLLATE \"C\" LIMIT $2",
            )
            .bind(after_vault_id)
            .bind(remaining as i64)
            .fetch_all(&self.pool)
            .await
            .map_err(ApiError::internal)?;
            vault_ids.extend(wrap_rows);
        }
        Ok(Some(vault_ids))
    }

    async fn prepare_vault_cursor(
        &self,
        claim: &ScanClaim,
        vault_id: &str,
    ) -> Result<Option<VaultCursor>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        if !renew_claim_tx(&mut tx, claim).await? {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(None);
        }
        let row = sqlx::query(
            "SELECT after_record_id,high_water_record_id,pending_record_id, \
                    pending_deleted_revision_id,pending_deleted_seq,server_generation \
             FROM record_auto_purge_vault_cursors WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let existing = row
            .map(|row| {
                Ok::<_, ApiError>(VaultCursor {
                    after_record_id: row.try_get("after_record_id").map_err(ApiError::internal)?,
                    high_water_record_id: row
                        .try_get("high_water_record_id")
                        .map_err(ApiError::internal)?,
                    pending: match row
                        .try_get::<Option<String>, _>("pending_record_id")
                        .map_err(ApiError::internal)?
                    {
                        Some(record_id) => Some(ScanCandidate {
                            vault_id: vault_id.to_owned(),
                            record_id,
                            deleted_revision_id: row
                                .try_get("pending_deleted_revision_id")
                                .map_err(ApiError::internal)?,
                            deleted_seq: row
                                .try_get("pending_deleted_seq")
                                .map_err(ApiError::internal)?,
                            // A pending identity is already authorized for
                            // retry; its opt-in may have been consumed by a
                            // successful purge before the checkpoint.
                            policy_revision: 0,
                        }),
                        None => None,
                    },
                })
            })
            .transpose()?;
        let generation_matches = sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM record_auto_purge_vault_cursors \
             WHERE vault_id=$1 AND server_generation=$2)",
        )
        .bind(vault_id)
        .bind(SCAN_SERVER_GENERATION)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !generation_matches
            && existing
                .as_ref()
                .is_some_and(|cursor| cursor.pending.is_some())
        {
            // A pending exact identity may represent a committed purge whose
            // checkpoint was lost. Preserve it across algorithm generations
            // so the idempotent proof path gets its retry.
            sqlx::query(
                "UPDATE record_auto_purge_vault_cursors SET server_generation=$1, \
                     updated_at=clock_timestamp() WHERE vault_id=$2",
            )
            .bind(SCAN_SERVER_GENERATION)
            .bind(vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(existing);
        }
        let cursor = if generation_matches
            && let Some(existing) = existing
            && (existing.high_water_record_id.is_some() || existing.pending.is_some())
        {
            existing
        } else {
            let high_water_record_id: Option<String> = sqlx::query_scalar(
                "SELECT record_id FROM record_graveyard \
                 WHERE vault_id COLLATE \"C\"=$1::text COLLATE \"C\" AND auto_purge_enabled=TRUE \
                 ORDER BY record_id COLLATE \"C\" DESC LIMIT 1",
            )
            .bind(vault_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query(
                "INSERT INTO record_auto_purge_vault_cursors( \
                     vault_id,after_record_id,high_water_record_id,pending_record_id, \
                     pending_deleted_revision_id,pending_deleted_seq,server_generation,updated_at \
                 ) VALUES($1,NULL,$2,NULL,NULL,NULL,$3,clock_timestamp()) \
                 ON CONFLICT(vault_id) DO UPDATE SET after_record_id=NULL, \
                     high_water_record_id=EXCLUDED.high_water_record_id, \
                     pending_record_id=NULL,pending_deleted_revision_id=NULL,pending_deleted_seq=NULL, \
                     server_generation=EXCLUDED.server_generation,updated_at=EXCLUDED.updated_at",
            )
            .bind(vault_id)
            .bind(&high_water_record_id)
            .bind(SCAN_SERVER_GENERATION)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            VaultCursor {
                after_record_id: None,
                high_water_record_id,
                pending: None,
            }
        };
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(Some(cursor))
    }

    async fn read_candidates(
        &self,
        vault_id: &str,
        cursor: &VaultCursor,
        limit: i64,
    ) -> Result<Vec<ScanCandidate>, ApiError> {
        let Some(high_water_record_id) = &cursor.high_water_record_id else {
            return Ok(Vec::new());
        };
        let rows = sqlx::query(
            "SELECT vault_id,record_id,deleted_revision,deleted_seq,auto_purge_revision \
             FROM record_graveyard WHERE vault_id COLLATE \"C\"=$1::text COLLATE \"C\" \
               AND auto_purge_enabled=TRUE \
               AND ($2::text IS NULL OR record_id COLLATE \"C\" > $2::text COLLATE \"C\") \
               AND record_id COLLATE \"C\" <= $3::text COLLATE \"C\" \
             ORDER BY vault_id COLLATE \"C\",record_id COLLATE \"C\" LIMIT $4",
        )
        .bind(vault_id)
        .bind(&cursor.after_record_id)
        .bind(high_water_record_id)
        .bind(limit)
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        rows.iter()
            .map(|row| {
                Ok(ScanCandidate {
                    vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
                    record_id: row.try_get("record_id").map_err(ApiError::internal)?,
                    deleted_revision_id: row
                        .try_get("deleted_revision")
                        .map_err(ApiError::internal)?,
                    deleted_seq: row.try_get("deleted_seq").map_err(ApiError::internal)?,
                    policy_revision: row
                        .try_get("auto_purge_revision")
                        .map_err(ApiError::internal)?,
                })
            })
            .collect()
    }

    async fn candidate_policy_is_current(
        &self,
        candidate: &ScanCandidate,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_graveyard \
             WHERE vault_id=$1 AND record_id=$2 AND deleted_revision=$3 AND deleted_seq=$4 \
               AND auto_purge_enabled=TRUE AND auto_purge_revision=$5)",
        )
        .bind(&candidate.vault_id)
        .bind(&candidate.record_id)
        .bind(&candidate.deleted_revision_id)
        .bind(candidate.deleted_seq)
        .bind(candidate.policy_revision)
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    async fn set_pending_candidate(
        &self,
        claim: &ScanClaim,
        candidate: &ScanCandidate,
    ) -> Result<bool, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        if !renew_claim_tx(&mut tx, claim).await? {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(false);
        }
        let result = sqlx::query(
            "UPDATE record_auto_purge_vault_cursors SET pending_record_id=$1, \
                 pending_deleted_revision_id=$2,pending_deleted_seq=$3,updated_at=clock_timestamp() \
             WHERE vault_id=$4 AND server_generation=$5 \
               AND high_water_record_id IS NOT NULL AND pending_record_id IS NULL \
               AND (after_record_id IS NULL OR $1::text COLLATE \"C\" > after_record_id COLLATE \"C\") \
               AND $1::text COLLATE \"C\" <= high_water_record_id COLLATE \"C\"",
        )
        .bind(&candidate.record_id)
        .bind(&candidate.deleted_revision_id)
        .bind(candidate.deleted_seq)
        .bind(&candidate.vault_id)
        .bind(SCAN_SERVER_GENERATION)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if result.rows_affected() != 1 {
            return Err(ApiError::internal(
                "automatic purge pending identity changed",
            ));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(true)
    }

    async fn checkpoint_candidate(
        &self,
        claim: &ScanClaim,
        candidate: &ScanCandidate,
        bucket: TerminalBucket,
    ) -> Result<bool, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        if !renew_claim_tx(&mut tx, claim).await? {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(false);
        }
        let cursor_update = sqlx::query(
            "UPDATE record_auto_purge_vault_cursors SET after_record_id=$1, \
                 pending_record_id=NULL,pending_deleted_revision_id=NULL,pending_deleted_seq=NULL, \
                 updated_at=clock_timestamp() \
             WHERE vault_id=$2 AND server_generation=$3 \
               AND high_water_record_id IS NOT NULL \
               AND ($1::text IS NULL OR $1::text COLLATE \"C\" <= high_water_record_id COLLATE \"C\") \
               AND (pending_record_id IS NULL OR (pending_record_id=$1 \
                    AND pending_deleted_revision_id=$4 AND pending_deleted_seq=$5))",
        )
        .bind(&candidate.record_id)
        .bind(&candidate.vault_id)
        .bind(SCAN_SERVER_GENERATION)
        .bind(&candidate.deleted_revision_id)
        .bind(candidate.deleted_seq)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if cursor_update.rows_affected() != 1 {
            return Err(ApiError::internal("automatic purge scan cursor changed"));
        }
        let counter_column = match bucket {
            TerminalBucket::Purged => "last_scan_purged",
            TerminalBucket::NotDue => "last_scan_not_due",
            TerminalBucket::CapabilityBlocked => "last_scan_capability_blocked",
            TerminalBucket::ConflictBlocked => "last_scan_conflict_blocked",
            TerminalBucket::ReferenceBlocked => "last_scan_reference_blocked",
            TerminalBucket::StaleOrWithdrawn => "last_scan_stale_or_withdrawn",
        };
        // `counter_column` comes only from this closed enum, never from data.
        let sql = format!(
            "UPDATE record_auto_purge_scan_control SET after_vault_id=$1, \
                 last_scan_candidates=last_scan_candidates+1,{counter_column}={counter_column}+1 \
             WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
               AND lease_expires_at>clock_timestamp()"
        );
        let control_update = sqlx::query(&sql)
            .bind(&candidate.vault_id)
            .bind(&claim.token)
            .bind(claim.revision)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if control_update.rows_affected() != 1 {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(false);
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(true)
    }

    async fn finish_vault_cursor(
        &self,
        claim: &ScanClaim,
        vault_id: &str,
    ) -> Result<bool, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        if !renew_claim_tx(&mut tx, claim).await? {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Ok(false);
        }
        let cursor_update = sqlx::query(
            "UPDATE record_auto_purge_vault_cursors SET after_record_id=NULL, \
                 high_water_record_id=NULL,updated_at=clock_timestamp() \
             WHERE vault_id=$1 AND server_generation=$2 AND pending_record_id IS NULL",
        )
        .bind(vault_id)
        .bind(SCAN_SERVER_GENERATION)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if cursor_update.rows_affected() != 1 {
            return Err(ApiError::internal(
                "automatic purge scan cannot finish a Vault with a pending identity",
            ));
        }
        sqlx::query(
            "UPDATE record_auto_purge_scan_control SET after_vault_id=$1 \
             WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
               AND lease_expires_at>clock_timestamp()",
        )
        .bind(vault_id)
        .bind(&claim.token)
        .bind(claim.revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(true)
    }

    async fn renew_claim(&self, claim: &ScanClaim) -> Result<bool, ApiError> {
        let result = sqlx::query(
            "UPDATE record_auto_purge_scan_control SET \
                 lease_expires_at=clock_timestamp()+make_interval(secs=>$1::double precision) \
             WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
               AND server_generation=$4 AND lease_expires_at>clock_timestamp()",
        )
        .bind(claim.lease_seconds)
        .bind(&claim.token)
        .bind(claim.revision)
        .bind(SCAN_SERVER_GENERATION)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(result.rows_affected() == 1)
    }

    async fn finish_claim(&self, claim: &ScanClaim, failed: bool) -> Result<bool, ApiError> {
        let status = if failed { "failed" } else { "completed" };
        // Failure finalization may happen just after lease expiry. The token
        // and revision still fence it from a replacement claim; success must
        // retain the live-lease condition.
        let sql = if failed {
            "UPDATE record_auto_purge_scan_control SET last_scan_status=$1, \
                 last_scan_finished_at=clock_timestamp(),lease_token=NULL,lease_expires_at=NULL \
             WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
               AND server_generation=$4"
        } else {
            "UPDATE record_auto_purge_scan_control SET last_scan_status=$1, \
                 last_scan_finished_at=clock_timestamp(),lease_token=NULL,lease_expires_at=NULL \
             WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
               AND server_generation=$4 AND lease_expires_at>clock_timestamp()"
        };
        let result = sqlx::query(sql)
            .bind(status)
            .bind(&claim.token)
            .bind(claim.revision)
            .bind(SCAN_SERVER_GENERATION)
            .execute(&self.pool)
            .await
            .map_err(ApiError::internal)?;
        Ok(result.rows_affected() == 1)
    }

    /// A purge attempt that returns an unknown/transient error has no terminal
    /// bucket, but it still counts as a candidate attempt. Persist the count
    /// and failed status together while the claim token and revision fence the
    /// update; the pending identity remains available for the next pass.
    async fn fail_candidate_attempt(&self, claim: &ScanClaim) -> Result<(), ApiError> {
        let result = sqlx::query(
            "UPDATE record_auto_purge_scan_control SET \
                 last_scan_candidates=last_scan_candidates+1,last_scan_status='failed', \
                 last_scan_finished_at=clock_timestamp(),lease_token=NULL,lease_expires_at=NULL \
             WHERE singleton=1 AND lease_token=$1 AND cursor_revision=$2 \
               AND server_generation=$3",
        )
        .bind(&claim.token)
        .bind(claim.revision)
        .bind(SCAN_SERVER_GENERATION)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        if result.rows_affected() != 1 {
            return Err(ApiError::internal("automatic purge scan claim was fenced"));
        }
        Ok(())
    }

    async fn read_counters(&self) -> Result<PgRecordAutoPurgeScanCounters, ApiError> {
        let row = sqlx::query(
            "SELECT last_scan_candidates,last_scan_purged,last_scan_not_due, \
                    last_scan_capability_blocked,last_scan_conflict_blocked, \
                    last_scan_reference_blocked,last_scan_stale_or_withdrawn \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(PgRecordAutoPurgeScanCounters {
            candidates: row
                .try_get("last_scan_candidates")
                .map_err(ApiError::internal)?,
            purged: row
                .try_get("last_scan_purged")
                .map_err(ApiError::internal)?,
            not_due: row
                .try_get("last_scan_not_due")
                .map_err(ApiError::internal)?,
            capability_blocked: row
                .try_get("last_scan_capability_blocked")
                .map_err(ApiError::internal)?,
            conflict_blocked: row
                .try_get("last_scan_conflict_blocked")
                .map_err(ApiError::internal)?,
            reference_blocked: row
                .try_get("last_scan_reference_blocked")
                .map_err(ApiError::internal)?,
            stale_or_withdrawn: row
                .try_get("last_scan_stale_or_withdrawn")
                .map_err(ApiError::internal)?,
        })
    }
}

async fn renew_claim_tx(
    tx: &mut Transaction<'_, Postgres>,
    claim: &ScanClaim,
) -> Result<bool, ApiError> {
    let result = sqlx::query(
        "UPDATE record_auto_purge_scan_control SET \
             lease_expires_at=clock_timestamp()+make_interval(secs=>$1::double precision) \
         WHERE singleton=1 AND lease_token=$2 AND cursor_revision=$3 \
           AND server_generation=$4 AND lease_expires_at>clock_timestamp()",
    )
    .bind(claim.lease_seconds)
    .bind(&claim.token)
    .bind(claim.revision)
    .bind(SCAN_SERVER_GENERATION)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(result.rows_affected() == 1)
}

fn terminal_bucket(error: ApiError) -> Result<TerminalBucket, ApiError> {
    match error.body.code.as_str() {
        "RECORD_PURGE_NOT_DUE" => Ok(TerminalBucket::NotDue),
        "VAULT_REDACTION_CAPABILITY_REQUIRED" => Ok(TerminalBucket::CapabilityBlocked),
        "RECORD_HAS_UNRESOLVED_CONFLICTS" => Ok(TerminalBucket::ConflictBlocked),
        "REDACTION_REFERENCE_AMBIGUOUS" => Ok(TerminalBucket::ReferenceBlocked),
        "RECORD_AUTO_PURGE_NOT_ENABLED"
        | "RECORD_NOT_PURGEABLE"
        | "RECORD_DELETE_CHANGED"
        | "RECORD_TOMBSTONE_CHANGED"
        | "VAULT_DELETION_PENDING"
        | "NOT_FOUND" => Ok(TerminalBucket::StaleOrWithdrawn),
        _ => Err(ApiError::internal("automatic purge candidate failed")),
    }
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashSet,
        fs,
        str::FromStr,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::SigningKey;
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgPoolOptions},
    };
    use tokio::sync::Notify;

    use super::*;

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        options: PgConnectOptions,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            Self::create_with_schema(false).await
        }

        async fn create_full() -> Self {
            Self::create_with_schema(true).await
        }

        async fn create_with_schema(full_purge_schema: bool) -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL scan test requires ATERMIUS_TEST_PG_URL");
            let parsed = url::Url::parse(&url).expect("valid PostgreSQL test URL");
            assert!(
                matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "::1")),
                "refusing non-loopback PostgreSQL test host"
            );
            assert!(
                parsed
                    .path()
                    .trim_start_matches('/')
                    .starts_with("atermius_test_"),
                "refusing database outside the disposable atermius_test_* namespace"
            );
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let admin_pool = PgPoolOptions::new()
                .max_connections(3)
                .connect_with(options.clone())
                .await
                .expect("connect disposable PostgreSQL database");
            let schema = format!("atermius_pg_auto_purge_scan_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated scan schema");
            let pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(
                    options
                        .clone()
                        .options([("search_path", format!("\"{schema}\""))]),
                )
                .await
                .expect("connect isolated scan schema");
            if full_purge_schema {
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
            } else {
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema( \
                         singleton SMALLINT PRIMARY KEY, schema_version INTEGER NOT NULL); \
                     INSERT INTO atermius_instance_schema VALUES(1,33); \
                     CREATE TABLE vaults(vault_id TEXT PRIMARY KEY,state TEXT NOT NULL); \
                     CREATE TABLE record_graveyard( \
                         vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE, \
                         record_id TEXT NOT NULL,deleted_revision TEXT NOT NULL,deleted_seq BIGINT NOT NULL, \
                         auto_purge_enabled BOOLEAN NOT NULL DEFAULT FALSE, \
                         auto_purge_revision BIGINT NOT NULL DEFAULT 0, \
                         PRIMARY KEY(vault_id,record_id));",
                )
                .execute(&pool)
                .await
                .expect("create minimal scan fixture schema");
                sqlx::raw_sql(include_str!(
                    "../migrations/postgres/0034_record_auto_purge_scan.sql"
                ))
                .execute(&pool)
                .await
                .expect("apply scanner migration");
            }
            Self {
                pool,
                admin_pool,
                options,
                schema,
                cleaned: false,
            }
        }

        async fn peer_pool(&self) -> PgPool {
            PgPoolOptions::new()
                .max_connections(5)
                .connect_with(
                    self.options
                        .clone()
                        .options([("search_path", format!("\"{}\"", self.schema))]),
                )
                .await
                .expect("connect peer to isolated scan schema")
        }

        async fn add_vault(&self, vault_id: &str) {
            sqlx::query("INSERT INTO vaults(vault_id,state) VALUES($1,'active')")
                .bind(vault_id)
                .execute(&self.pool)
                .await
                .expect("insert scan Vault");
        }

        async fn add_candidate(&self, vault_id: &str, record_id: &str, seq: i64) {
            sqlx::query(
                "INSERT INTO record_graveyard( \
                     vault_id,record_id,deleted_revision,deleted_seq,auto_purge_enabled,auto_purge_revision \
                 ) VALUES($1,$2,$3,$4,TRUE,0)",
            )
            .bind(vault_id)
            .bind(record_id)
            .bind(uuid_text(10_000 + seq as u128))
            .bind(seq)
            .execute(&self.pool)
            .await
            .expect("insert opted-in scan candidate");
        }

        fn repository(&self, pool: PgPool) -> PgRecordAutoPurgeScanRepository {
            let key = Arc::new(SigningKey::from_bytes(&[41; 32]));
            let signer = crate::pg_record_redaction::PgRedactionProofSigner::new(
                crate::InstanceInfo {
                    instance_id: uuid_text(1),
                    server_space_id: uuid_text(2),
                    generation: "test".into(),
                    signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
                    signing_key_transitions: Vec::new(),
                },
                key,
            );
            let purge = PgRecordPurgeRepository::new(pool.clone(), signer);
            PgRecordAutoPurgeScanRepository::new(pool, purge)
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated scan schema");
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

    fn uuid_text(value: u128) -> String {
        Uuid::from_u128(value).to_string()
    }

    fn candidate_error(code: &'static str) -> ApiError {
        ApiError::conflict(code, "fixture blocker")
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_fair_round_robin_and_fixed_high_water() {
        let database = TestDatabase::create().await;
        let vault_a = uuid_text(100);
        let vault_b = uuid_text(200);
        database.add_vault(&vault_a).await;
        database.add_vault(&vault_b).await;
        for (vault, seq) in [
            (&vault_a, 1_i64),
            (&vault_a, 2_i64),
            (&vault_a, 3_i64),
            (&vault_b, 4_i64),
            (&vault_b, 5_i64),
        ] {
            database
                .add_candidate(vault, &uuid_text(1_000 + seq as u128), seq)
                .await;
        }
        let repository = database.repository(database.pool.clone());
        let seen = Arc::new(Mutex::new(Vec::new()));
        for _ in 0..3 {
            let seen_for_call = Arc::clone(&seen);
            let report = repository
                .scan_batch_with(1, 1, 60, move |candidate| {
                    let seen = Arc::clone(&seen_for_call);
                    let vault_id = candidate.vault_id.clone();
                    let record_id = candidate.record_id.clone();
                    Box::pin(async move {
                        seen.lock().expect("seen lock").push((vault_id, record_id));
                        Ok(TerminalBucket::Purged)
                    })
                })
                .await
                .expect("bounded scan batch");
            assert!(report.acquired);
            assert!(!report.fenced);
            assert_eq!(report.counters.candidates, 1);
        }
        let seen = seen.lock().expect("seen lock").clone();
        assert_eq!(seen[0].0, vault_a);
        assert_eq!(seen[1].0, vault_b);
        assert_eq!(seen[2].0, vault_a);
        assert_eq!(seen[0].1, uuid_text(1_001));
        assert_eq!(seen[2].1, uuid_text(1_002));

        // The captured high-water key is stable for Vault A's current pass.
        let high_water: Option<String> = sqlx::query_scalar(
            "SELECT high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=$1",
        )
        .bind(&vault_a)
        .fetch_one(&database.pool)
        .await
        .expect("read persisted Vault high-water");
        assert_eq!(high_water.as_deref(), Some(uuid_text(1_003).as_str()));
        database
            .add_candidate(&vault_a, &uuid_text(1_004), 99)
            .await;
        assert_eq!(
            sqlx::query_scalar::<_, Option<String>>(
                "SELECT high_water_record_id FROM record_auto_purge_vault_cursors WHERE vault_id=$1"
            )
            .bind(&vault_a)
            .fetch_one(&database.pool)
            .await
            .expect("read unchanged high-water"),
            high_water
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_aggregate_blocker_buckets_and_stale_opt_out_have_no_ids() {
        let database = TestDatabase::create().await;
        let vault = uuid_text(300);
        database.add_vault(&vault).await;
        for seq in 1_i64..=6 {
            database
                .add_candidate(&vault, &uuid_text(2_000 + seq as u128), seq)
                .await;
        }
        let repository = database.repository(database.pool.clone());
        let pool = database.pool.clone();
        let report = repository
            .scan_batch_with(1, 10, 60, move |candidate| {
                let pool = pool.clone();
                let record_id = candidate.record_id.clone();
                let vault_id = candidate.vault_id.clone();
                    let seq = candidate.deleted_seq;
                    Box::pin(async move {
                        match seq {
                        1 => Ok(TerminalBucket::Purged),
                        2 => terminal_bucket(candidate_error("RECORD_PURGE_NOT_DUE")),
                        3 => terminal_bucket(candidate_error("VAULT_REDACTION_CAPABILITY_REQUIRED")),
                        4 => terminal_bucket(candidate_error("RECORD_HAS_UNRESOLVED_CONFLICTS")),
                        5 => terminal_bucket(candidate_error("REDACTION_REFERENCE_AMBIGUOUS")),
                        6 => {
                            sqlx::query(
                                "UPDATE record_graveyard SET auto_purge_enabled=FALSE,auto_purge_revision=1 \
                                 WHERE vault_id=$1 AND record_id=$2",
                            )
                            .bind(&vault_id)
                            .bind(&record_id)
                            .execute(&pool)
                            .await
                            .expect("withdraw test candidate consent");
                            terminal_bucket(candidate_error("RECORD_AUTO_PURGE_NOT_ENABLED"))
                        }
                        _ => unreachable!(),
                    }
                })
            })
            .await
            .expect("blocked candidates produce terminal aggregate buckets");
        assert_eq!(report.counters.candidates, 6);
        assert_eq!(report.counters.purged, 1);
        assert_eq!(report.counters.not_due, 1);
        assert_eq!(report.counters.capability_blocked, 1);
        assert_eq!(report.counters.conflict_blocked, 1);
        assert_eq!(report.counters.reference_blocked, 1);
        assert_eq!(report.counters.stale_or_withdrawn, 1);
        let diagnostics = format!("{report:?}");
        assert!(!diagnostics.contains(&vault));
        for seq in 1_i64..=6 {
            assert!(!diagnostics.contains(&uuid_text(2_000 + seq as u128)));
        }
        let control_columns: Vec<String> = sqlx::query_scalar(
            "SELECT column_name FROM information_schema.columns \
             WHERE table_schema=current_schema() AND table_name='record_auto_purge_scan_control'",
        )
        .fetch_all(&database.pool)
        .await
        .expect("inspect aggregate diagnostic schema");
        assert!(
            !control_columns
                .iter()
                .any(|column| column.contains("record_id"))
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_pending_failure_retry_is_persistent_across_restart() {
        let database = TestDatabase::create().await;
        let vault = uuid_text(400);
        let record = uuid_text(3_001);
        database.add_vault(&vault).await;
        database.add_candidate(&vault, &record, 1).await;
        let repository = database.repository(database.pool.clone());
        let side_effects = Arc::new(Mutex::new(HashSet::new()));
        let attempts = Arc::new(Mutex::new(Vec::new()));
        let first_effects = Arc::clone(&side_effects);
        let first_attempts = Arc::clone(&attempts);
        let pool = database.pool.clone();
        let failed = repository
            .scan_batch_with(1, 1, 60, move |candidate| {
                let effects = Arc::clone(&first_effects);
                let attempts = Arc::clone(&first_attempts);
                let pool = pool.clone();
                let key = (
                    candidate.vault_id.clone(),
                    candidate.record_id.clone(),
                    candidate.deleted_revision_id.clone(),
                    candidate.deleted_seq,
                );
                Box::pin(async move {
                    attempts.lock().expect("attempt lock").push(key.clone());
                    effects.lock().expect("effect lock").insert(key.clone());
                    // Model the existing purge route committing its proof and
                    // consuming opt-in, then losing the ACK before checkpoint.
                    sqlx::query(
                        "UPDATE record_graveyard SET auto_purge_enabled=FALSE,auto_purge_revision=1 \
                         WHERE vault_id=$1 AND record_id=$2",
                    )
                    .bind(&key.0)
                    .bind(&key.1)
                    .execute(&pool)
                    .await
                    .expect("consume consent in simulated committed purge");
                    Err(ApiError::internal("simulated lost purge ACK"))
                })
            })
            .await;
        assert!(failed.is_err());
        let pending: (
            Option<String>,
            Option<String>,
            Option<i64>,
            Option<String>,
            i64,
        ) = sqlx::query_as(
            "SELECT c.after_record_id,c.pending_record_id,c.pending_deleted_seq, \
                        s.last_scan_status,s.last_scan_candidates \
                 FROM record_auto_purge_vault_cursors c \
                 JOIN record_auto_purge_scan_control s ON s.singleton=1 WHERE c.vault_id=$1",
        )
        .bind(&vault)
        .fetch_one(&database.pool)
        .await
        .expect("read durable pending candidate after failure");
        assert_eq!(pending.0, None);
        assert_eq!(pending.1.as_deref(), Some(record.as_str()));
        assert_eq!(pending.2, Some(1));
        assert_eq!(pending.3.as_deref(), Some("failed"));
        assert_eq!(pending.4, 1, "transient purge attempt is counted");

        // A newly constructed repository and a separate pool model restart.
        let peer = database.peer_pool().await;
        let restarted = database.repository(peer.clone());
        let retry_effects = Arc::clone(&side_effects);
        let retry_attempts = Arc::clone(&attempts);
        let report = restarted
            .scan_batch_with(1, 1, 60, move |candidate| {
                let effects = Arc::clone(&retry_effects);
                let attempts = Arc::clone(&retry_attempts);
                let key = (
                    candidate.vault_id.clone(),
                    candidate.record_id.clone(),
                    candidate.deleted_revision_id.clone(),
                    candidate.deleted_seq,
                );
                Box::pin(async move {
                    attempts.lock().expect("attempt lock").push(key.clone());
                    assert!(effects.lock().expect("effect lock").contains(&key));
                    Ok(TerminalBucket::Purged)
                })
            })
            .await
            .expect("retry pending through idempotent route");
        assert_eq!(report.counters.candidates, 1);
        assert_eq!(report.counters.purged, 1);
        let attempts = attempts.lock().expect("attempt lock");
        assert_eq!(attempts.len(), 2);
        assert_eq!(attempts[0], attempts[1]);
        drop(attempts);
        let cleared: (Option<String>, Option<String>, Option<i64>) = sqlx::query_as(
            "SELECT after_record_id,pending_record_id,pending_deleted_seq \
             FROM record_auto_purge_vault_cursors WHERE vault_id=$1",
        )
        .bind(&vault)
        .fetch_one(&database.pool)
        .await
        .expect("read terminal retry checkpoint");
        assert_eq!(cleared, (Some(record), None, None));
        peer.close().await;
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_fences_expired_worker_across_pools() {
        let database = TestDatabase::create().await;
        let vault = uuid_text(500);
        let record = uuid_text(4_001);
        database.add_vault(&vault).await;
        database.add_candidate(&vault, &record, 1).await;
        let peer = database.peer_pool().await;
        let first_repository = database.repository(database.pool.clone());
        let second_repository = database.repository(peer.clone());
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let attempts = Arc::new(AtomicUsize::new(0));
        let committed = Arc::new(Mutex::new(HashSet::new()));
        let first_entered = Arc::clone(&entered);
        let first_release = Arc::clone(&release);
        let first_attempts = Arc::clone(&attempts);
        let first_committed = Arc::clone(&committed);
        let first = tokio::spawn(async move {
            first_repository
                .scan_batch_with(1, 1, 30, move |candidate| {
                    let entered = Arc::clone(&first_entered);
                    let release = Arc::clone(&first_release);
                    let attempts = Arc::clone(&first_attempts);
                    let committed = Arc::clone(&first_committed);
                    let key = (
                        candidate.vault_id.clone(),
                        candidate.record_id.clone(),
                        candidate.deleted_revision_id.clone(),
                        candidate.deleted_seq,
                    );
                    Box::pin(async move {
                        let previous = attempts.fetch_add(1, Ordering::SeqCst);
                        committed.lock().expect("effect lock").insert(key);
                        if previous == 0 {
                            entered.notify_one();
                            release.notified().await;
                        }
                        Ok(TerminalBucket::Purged)
                    })
                })
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(10), entered.notified())
            .await
            .expect("first worker reached purge after persisting pending identity");
        sqlx::query(
            "UPDATE record_auto_purge_scan_control SET lease_expires_at=clock_timestamp()-interval '1 second' \
             WHERE singleton=1",
        )
        .execute(&peer)
        .await
        .expect("expire first worker lease");
        let second_attempts = Arc::clone(&attempts);
        let second_committed = Arc::clone(&committed);
        let second = second_repository
            .scan_batch_with(1, 1, 30, move |candidate| {
                let attempts = Arc::clone(&second_attempts);
                let committed = Arc::clone(&second_committed);
                let key = (
                    candidate.vault_id.clone(),
                    candidate.record_id.clone(),
                    candidate.deleted_revision_id.clone(),
                    candidate.deleted_seq,
                );
                Box::pin(async move {
                    attempts.fetch_add(1, Ordering::SeqCst);
                    assert!(committed.lock().expect("effect lock").contains(&key));
                    Ok(TerminalBucket::Purged)
                })
            })
            .await
            .expect("second pool takes expired lease and retries pending identity");
        assert!(second.acquired);
        assert_eq!(second.counters.purged, 1);
        release.notify_one();
        let first = first
            .await
            .expect("first scanner task")
            .expect("first scan result");
        assert!(first.fenced);
        assert_eq!(attempts.load(Ordering::SeqCst), 2);
        let (revision, after_record_id, pending_record_id, status): (i64, Option<String>, Option<String>, String) =
            sqlx::query_as(
                "SELECT s.cursor_revision,c.after_record_id,c.pending_record_id,s.last_scan_status \
                 FROM record_auto_purge_scan_control s JOIN record_auto_purge_vault_cursors c ON c.vault_id=$1 \
                 WHERE s.singleton=1",
            )
            .bind(&vault)
            .fetch_one(&peer)
            .await
            .expect("inspect fenced cursor");
        assert!(revision >= 2);
        assert_eq!(after_record_id.as_deref(), Some(record.as_str()));
        assert_eq!(pending_record_id, None);
        assert_eq!(status, "completed");
        peer.close().await;
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable PostgreSQL database"]
    async fn pg_auto_purge_scan_restore_reset_fences_pending_callback() {
        let database = TestDatabase::create_full().await;
        let (vault_id, record_id, deleted_revision_id, endpoint_ids) =
            crate::pg_record_purge::seed_purge_fixture_for_auto_purge_scan_test(&database.pool)
                .await;
        sqlx::query(
            "UPDATE record_graveyard SET auto_purge_enabled=TRUE,auto_purge_revision=1 \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .execute(&database.pool)
        .await
        .expect("enable consent for the pending tombstone");

        let repository = database.repository(database.pool.clone());
        let purge = repository.purge.clone();
        let entered = Arc::new(Notify::new());
        let release = Arc::new(Notify::new());
        let callback_entered = Arc::clone(&entered);
        let callback_release = Arc::clone(&release);
        let scan_task = tokio::spawn(async move {
            repository
                .scan_batch_with(1, 1, 60, move |candidate| {
                    let entered = Arc::clone(&callback_entered);
                    let release = Arc::clone(&callback_release);
                    let purge = purge.clone();
                    Box::pin(async move {
                        // scan_batch_with invokes this only after it committed
                        // the exact pending tombstone tuple.
                        entered.notify_one();
                        release.notified().await;
                        match purge
                            .purge_for_maintenance(
                                &candidate.vault_id,
                                &candidate.record_id,
                                &candidate.deleted_revision_id,
                                &candidate.deleted_seq.to_string(),
                                60,
                            )
                            .await
                        {
                            Ok(_) => Ok(TerminalBucket::Purged),
                            Err(error) => terminal_bucket(error),
                        }
                    })
                })
                .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(10), entered.notified())
            .await
            .expect("scanner pauses inside purge callback after pending commit");

        let pending: (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i64>,
        ) = sqlx::query_as(
            "SELECT after_record_id,pending_record_id,pending_deleted_revision_id,pending_deleted_seq \
             FROM record_auto_purge_vault_cursors WHERE vault_id=$1",
        )
        .bind(&vault_id)
        .fetch_one(&database.pool)
        .await
        .expect("read durable pending tuple before restore reset");
        assert_eq!(pending.0, None);
        assert_eq!(pending.1.as_deref(), Some(record_id.as_str()));
        assert_eq!(pending.2.as_deref(), Some(deleted_revision_id.as_str()));
        assert_eq!(pending.3, Some(2));

        let (old_revision, old_token, old_status, old_candidates): (
            i64,
            Option<String>,
            String,
            i64,
        ) = sqlx::query_as(
            "SELECT cursor_revision,lease_token,last_scan_status,last_scan_candidates \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&database.pool)
        .await
        .expect("read active scan lease before reset");
        assert!(old_token.is_some());
        assert_eq!(old_status, "running");
        assert_eq!(old_candidates, 0);

        // This is the same schema-parameterized helper called by the actual
        // archive restore path. It withdraws opt-in, deletes cursors and bumps
        // the control revision to fence the sleeping worker.
        sqlx::raw_sql(
            "CREATE FUNCTION fail_auto_purge_restore_cursor_delete() RETURNS trigger \
             LANGUAGE plpgsql AS $$ \
             BEGIN \
               RAISE EXCEPTION 'test-only restore cursor reset failure'; \
               RETURN OLD; \
             END $$; \
             CREATE TRIGGER fail_auto_purge_restore_cursor_delete \
             BEFORE DELETE ON record_auto_purge_vault_cursors \
             FOR EACH ROW EXECUTE FUNCTION fail_auto_purge_restore_cursor_delete();",
        )
        .execute(&database.pool)
        .await
        .expect("install atomic reset rollback fault");
        let rejected_reset = crate::backup::reset_postgres_auto_purge_after_restore(
            &database.pool,
            &database.schema,
        )
        .await
        .expect_err("injected cursor delete fault aborts the reset transaction");
        assert_eq!(rejected_reset.body.code, "BACKUP_SCHEMA_UNSUPPORTED");
        let rolled_back_control: (i64, Option<String>, String, i64) = sqlx::query_as(
            "SELECT cursor_revision,lease_token,last_scan_status,last_scan_candidates \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&database.pool)
        .await
        .expect("read scanner control after rejected reset");
        assert_eq!(
            rolled_back_control,
            (old_revision, old_token.clone(), "running".into(), 0)
        );
        let rolled_back_consent: (bool, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&database.pool)
        .await
        .expect("read consent after rejected reset");
        assert_eq!(rolled_back_consent, (true, 1));
        let rolled_back_pending: (
            Option<String>,
            Option<String>,
            Option<String>,
            Option<i64>,
        ) = sqlx::query_as(
            "SELECT after_record_id,pending_record_id,pending_deleted_revision_id,pending_deleted_seq \
             FROM record_auto_purge_vault_cursors WHERE vault_id=$1",
        )
        .bind(&vault_id)
        .fetch_one(&database.pool)
        .await
        .expect("read pending cursor after rejected reset");
        assert_eq!(rolled_back_pending, pending);
        sqlx::raw_sql(
            "DROP TRIGGER fail_auto_purge_restore_cursor_delete ON record_auto_purge_vault_cursors; \
             DROP FUNCTION fail_auto_purge_restore_cursor_delete();",
        )
        .execute(&database.pool)
        .await
        .expect("remove atomic reset rollback fault");

        crate::backup::reset_postgres_auto_purge_after_restore(&database.pool, &database.schema)
            .await
            .expect("production restore reset fences the scanner");

        let expected_revision = old_revision + 1;
        let reset_control: bool = sqlx::query_scalar(
            "SELECT after_vault_id IS NULL AND server_generation=1 \
                   AND cursor_revision=$1 AND lease_token IS NULL AND lease_expires_at IS NULL \
                   AND last_scan_status='never' AND last_scan_started_at IS NULL \
                   AND last_scan_finished_at IS NULL AND last_scan_candidates=0 \
                   AND last_scan_purged=0 AND last_scan_not_due=0 \
                   AND last_scan_capability_blocked=0 AND last_scan_conflict_blocked=0 \
                   AND last_scan_reference_blocked=0 AND last_scan_stale_or_withdrawn=0 \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .bind(expected_revision)
        .fetch_one(&database.pool)
        .await
        .expect("read reset scanner control");
        assert!(reset_control);
        let consent: (bool, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&database.pool)
        .await
        .expect("read restore-reset consent");
        assert_eq!(consent, (false, 2));
        let reset_cursor_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                .fetch_one(&database.pool)
                .await
                .expect("count cleared scanner cursors");
        assert_eq!(reset_cursor_count, 0);

        release.notify_one();
        let stale_scan = scan_task
            .await
            .expect("stale scan task completes")
            .expect("stale callback is terminal but fenced");
        assert!(stale_scan.acquired);
        assert!(stale_scan.fenced);
        assert_eq!(
            stale_scan.counters,
            PgRecordAutoPurgeScanCounters::default()
        );

        let final_control: (i64, Option<String>, String, i64, i64) = sqlx::query_as(
            "SELECT cursor_revision,lease_token,last_scan_status,last_scan_candidates,last_scan_purged \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&database.pool)
        .await
        .expect("read control after stale callback resumes");
        assert_eq!(
            final_control,
            (expected_revision, None, "never".into(), 0, 0)
        );
        let final_cursor_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                .fetch_one(&database.pool)
                .await
                .expect("read cursors after stale callback resumes");
        assert_eq!(final_cursor_count, 0);
        let final_consent: (bool, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=$1 AND record_id=$2",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&database.pool)
        .await
        .expect("read consent after stale callback resumes");
        assert_eq!(final_consent, (false, 2));
        let final_side_effects: (i64, i64, i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2), \
                    (SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id=ANY($3::text[])), \
                    (SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=$1 \
                      AND action='vault.record_purged' AND source='maintenance'), \
                    (SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1)",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&endpoint_ids)
        .fetch_one(&database.pool)
        .await
        .expect("check stale callback created no purge side effects");
        assert_eq!(final_side_effects, (0, 0, 0, 2));

        database.cleanup().await;
    }
}

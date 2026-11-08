//! Shared PostgreSQL persistence for encrypted instance-backup replication.
//!
//! This module records and reads durable outbox state and fences shared
//! worker claims. Provider configuration and credentials remain node-local
//! configuration, and the external transfer worker is implemented separately.

use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, is_canonical_uuid};

const CLAIM_LEASE_SECONDS: i64 = 5 * 60;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgBackupReplicationAttempt {
    pub(crate) archive_id: String,
    pub(crate) state: &'static str,
    pub(crate) attempted_at: DateTime<Utc>,
    pub(crate) completed_at: Option<DateTime<Utc>>,
    pub(crate) archive_bytes: Option<i64>,
    pub(crate) failure_category: Option<&'static str>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgBackupReplicationSnapshot {
    pub(crate) pending_count: i64,
    pub(crate) latest_attempt: Option<PgBackupReplicationAttempt>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgBackupReplicationClaim {
    pub(crate) archive_id: String,
    pub(crate) origin: String,
    pub(crate) attempt_count: i64,
    pub(crate) archive_bytes: Option<i64>,
    pub(crate) archive_sha256: Option<String>,
    pub(crate) multipart_upload_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgBackupReplicaArchive {
    pub(crate) archive_id: String,
    pub(crate) origin: String,
    pub(crate) created_at: DateTime<Utc>,
    pub(crate) archive_bytes: i64,
    pub(crate) archive_sha256: String,
}

#[derive(Clone)]
pub(crate) struct PgBackupReplicationRepository {
    pool: PgPool,
}

impl PgBackupReplicationRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Lists only completed replicas whose archive identity and immutable
    /// metadata still match the successful shared backup job that produced
    /// them. This keeps incomplete or inconsistent rows out of restore UI.
    pub(crate) async fn list_restore_archives(
        &self,
    ) -> Result<Vec<PgBackupReplicaArchive>, ApiError> {
        let rows = sqlx::query(&format!(
            "SELECT replication.archive_id,replication.origin,replication.created_at, \
                    replication.archive_bytes,replication.archive_sha256 \
             {RESTORE_ARCHIVE_MATCHING_JOB_FROM} \
             ORDER BY replication.created_at DESC,replication.archive_id DESC"
        ))
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        rows.into_iter().map(decode_restore_archive).collect()
    }

    /// Looks up one completed replica by its exact canonical archive ID and
    /// applies the same successful-job and metadata consistency checks as
    /// the restore catalog.
    pub(crate) async fn restore_archive_metadata(
        &self,
        archive_id: &str,
    ) -> Result<Option<PgBackupReplicaArchive>, ApiError> {
        validate_archive_id(archive_id)?;
        let row = sqlx::query(&format!(
            "SELECT replication.archive_id,replication.origin,replication.created_at, \
                    replication.archive_bytes,replication.archive_sha256 \
             {RESTORE_ARCHIVE_MATCHING_JOB_FROM} \
               AND replication.archive_id=$1"
        ))
        .bind(archive_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        row.map(decode_restore_archive).transpose()
    }

    /// Inserts the durable reconciliation row before the archive snapshot is
    /// taken. A repeated call for the same archive and origin is idempotent.
    pub(crate) async fn register_archive_before_snapshot(
        &self,
        archive_id: &str,
        origin: &str,
    ) -> Result<(), ApiError> {
        validate_identity(archive_id, origin)?;
        let inserted: Option<String> = sqlx::query_scalar(
            "INSERT INTO instance_backup_replications(archive_id,origin,created_at,status,attempt_count) \
             VALUES($1,$2,clock_timestamp(),'pending_archive',0) \
             ON CONFLICT(archive_id) DO NOTHING RETURNING origin",
        )
        .bind(archive_id)
        .bind(origin)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        if inserted.as_deref() == Some(origin) {
            return Ok(());
        }

        let existing: Option<String> = sqlx::query_scalar(
            "SELECT origin FROM instance_backup_replications WHERE archive_id=$1",
        )
        .bind(archive_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        if existing.as_deref() == Some(origin) {
            Ok(())
        } else {
            Err(ApiError::internal(
                "PostgreSQL backup replication archive identity conflicts with its existing row",
            ))
        }
    }

    /// Publishes the exact archive size and digest after the archive exists.
    /// Retrying with the same identity is safe and does not reset worker state.
    pub(crate) async fn archive_created(
        &self,
        archive_id: &str,
        archive_bytes: u64,
        archive_sha256: &str,
    ) -> Result<(), ApiError> {
        validate_archive_id(archive_id)?;
        let archive_bytes = i64::try_from(archive_bytes).map_err(ApiError::internal)?;
        if archive_bytes <= 0 || !is_lower_sha256(archive_sha256) {
            return Err(ApiError::internal(
                "PostgreSQL backup replication archive metadata is invalid",
            ));
        }

        let changed = sqlx::query(
            "UPDATE instance_backup_replications SET status='pending',archive_bytes=$2, \
                archive_sha256=$3,next_attempt_at=clock_timestamp(),completed_at=NULL, \
                failure_category=NULL \
             WHERE archive_id=$1 AND status IN ('pending_archive','interrupted')",
        )
        .bind(archive_id)
        .bind(archive_bytes)
        .bind(archive_sha256)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() == 1 {
            return Ok(());
        }

        let existing = sqlx::query(
            "SELECT archive_bytes,archive_sha256 FROM instance_backup_replications \
             WHERE archive_id=$1",
        )
        .bind(archive_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let Some(existing) = existing else {
            return Err(ApiError::internal(
                "PostgreSQL backup replication outbox row is missing",
            ));
        };
        let existing_bytes: Option<i64> = existing
            .try_get("archive_bytes")
            .map_err(ApiError::internal)?;
        let existing_sha256: Option<String> = existing
            .try_get("archive_sha256")
            .map_err(ApiError::internal)?;
        if existing_bytes == Some(archive_bytes)
            && existing_sha256.as_deref() == Some(archive_sha256)
        {
            Ok(())
        } else {
            Err(ApiError::internal(
                "PostgreSQL backup replication outbox row could not be updated",
            ))
        }
    }

    /// Marks a pre-snapshot failure with a fixed category. Repeated failure
    /// reporting for the same row is idempotent.
    pub(crate) async fn archive_creation_failed(&self, archive_id: &str) -> Result<(), ApiError> {
        validate_archive_id(archive_id)?;
        let changed = sqlx::query(
            "UPDATE instance_backup_replications SET status='failed', \
                failure_category='archive_unavailable',completed_at=clock_timestamp(), \
                next_attempt_at=NULL \
             WHERE archive_id=$1 AND status='pending_archive'",
        )
        .bind(archive_id)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() == 1 {
            return Ok(());
        }

        let existing: Option<(String, Option<String>)> = sqlx::query_as(
            "SELECT status,failure_category FROM instance_backup_replications WHERE archive_id=$1",
        )
        .bind(archive_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        match existing {
            Some((status, Some(failure)))
                if status == "failed" && failure == "archive_unavailable" =>
            {
                Ok(())
            }
            _ => Err(ApiError::internal(
                "PostgreSQL backup replication archive failure could not be recorded",
            )),
        }
    }

    /// Claims one due row across all serving nodes. The database advisory
    /// transaction lock serializes claims while the partial unique index
    /// remains the durable one-running invariant. `pending_archive` is left
    /// for the producer to finish or fail; before claiming another row, use
    /// its shared job record to recover a producer that died after publishing
    /// archive metadata but before updating the outbox.
    pub(crate) async fn claim_due(&self) -> Result<Option<PgBackupReplicationClaim>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let got_claim_lock: bool = sqlx::query_scalar(
            "SELECT pg_try_advisory_xact_lock( \
                 hashtextextended('atermius:backup-replication-claim:'||current_schema(),0))",
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !got_claim_lock {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(None);
        }

        reconcile_pending_archives(&mut tx).await?;

        // A crashed/paused worker loses authority as soon as its database
        // lease expires. Preserve a multipart ID so the next generation can
        // clean up the exact remote key before retrying.
        sqlx::query(
            "UPDATE instance_backup_replications \
             SET status='interrupted',next_attempt_at=clock_timestamp(),started_at=NULL, \
                 completed_at=NULL,failure_category='remote_unavailable',lease_expires_at=NULL \
             WHERE status='running' AND lease_expires_at<=clock_timestamp()",
        )
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let row = sqlx::query(
            "WITH claim_clock AS MATERIALIZED (SELECT clock_timestamp() AS now), \
             candidate AS MATERIALIZED ( \
                 SELECT archive_id FROM instance_backup_replications \
                 WHERE status IN ('pending','retry_wait','interrupted') \
                   AND next_attempt_at<=clock_timestamp() \
                 ORDER BY next_attempt_at,created_at,archive_id \
                 LIMIT 1 FOR UPDATE SKIP LOCKED \
             ) \
             UPDATE instance_backup_replications AS replication \
             SET status='running',attempt_count=replication.attempt_count+1, \
                 started_at=claim_clock.now,last_attempt_at=claim_clock.now, \
                 next_attempt_at=NULL,completed_at=NULL,failure_category=NULL, \
                 lease_expires_at=claim_clock.now+make_interval(secs=>$1::double precision) \
             FROM candidate,claim_clock \
             WHERE replication.archive_id=candidate.archive_id \
             RETURNING replication.archive_id,replication.origin,replication.attempt_count, \
                       replication.archive_bytes,replication.archive_sha256, \
                       replication.multipart_upload_id",
        )
        .bind(CLAIM_LEASE_SECONDS)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let claim = if let Some(row) = row {
            let claim = PgBackupReplicationClaim {
                archive_id: row.try_get("archive_id").map_err(ApiError::internal)?,
                origin: row.try_get("origin").map_err(ApiError::internal)?,
                attempt_count: row.try_get("attempt_count").map_err(ApiError::internal)?,
                archive_bytes: row.try_get("archive_bytes").map_err(ApiError::internal)?,
                archive_sha256: row.try_get("archive_sha256").map_err(ApiError::internal)?,
                multipart_upload_id: row
                    .try_get("multipart_upload_id")
                    .map_err(ApiError::internal)?,
            };
            validate_identity(&claim.archive_id, &claim.origin)?;
            Some(claim)
        } else {
            None
        };
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(claim)
    }

    /// Extends a live claim using PostgreSQL time. A worker cannot renew after
    /// expiry, even if no replacement worker has reclaimed the row yet.
    pub(crate) async fn renew_claim(
        &self,
        archive_id: &str,
        attempt_count: i64,
    ) -> Result<bool, ApiError> {
        validate_archive_id(archive_id)?;
        let changed = sqlx::query(
            "UPDATE instance_backup_replications \
             SET lease_expires_at=clock_timestamp()+make_interval(secs=>$3::double precision) \
             WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
               AND lease_expires_at>clock_timestamp()",
        )
        .bind(archive_id)
        .bind(attempt_count)
        .bind(CLAIM_LEASE_SECONDS)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(changed.rows_affected() == 1)
    }

    /// Records or clears a multipart upload ID only while this claim's lease
    /// is live. The fencing generation prevents stale retries from replacing
    /// a newer upload's recovery metadata.
    pub(crate) async fn persist_upload_id(
        &self,
        archive_id: &str,
        attempt_count: i64,
        upload_id: Option<&str>,
    ) -> Result<bool, ApiError> {
        validate_archive_id(archive_id)?;
        if upload_id.is_some_and(|value| {
            value.is_empty() || value.len() > 8192 || value.chars().any(char::is_control)
        }) {
            return Err(ApiError::internal(
                "PostgreSQL backup replication multipart state is invalid",
            ));
        }
        let changed = sqlx::query(
            "UPDATE instance_backup_replications SET multipart_upload_id=$3 \
             WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
               AND lease_expires_at>clock_timestamp()",
        )
        .bind(archive_id)
        .bind(attempt_count)
        .bind(upload_id)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(changed.rows_affected() == 1)
    }

    /// Publishes immutable archive metadata for a live generation. Existing
    /// metadata may be repeated exactly but cannot be replaced with different
    /// bytes or a different digest.
    pub(crate) async fn persist_archive_metadata(
        &self,
        archive_id: &str,
        attempt_count: i64,
        archive_bytes: u64,
        archive_sha256: &str,
    ) -> Result<bool, ApiError> {
        validate_archive_id(archive_id)?;
        let archive_bytes = i64::try_from(archive_bytes).map_err(ApiError::internal)?;
        if archive_bytes <= 0 || !is_lower_sha256(archive_sha256) {
            return Err(ApiError::internal(
                "PostgreSQL backup replication archive metadata is invalid",
            ));
        }
        let changed = sqlx::query(
            "UPDATE instance_backup_replications \
             SET archive_bytes=$3,archive_sha256=$4 \
             WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
               AND lease_expires_at>clock_timestamp() \
               AND (archive_bytes IS NULL OR archive_bytes=$3) \
               AND (archive_sha256 IS NULL OR archive_sha256=$4)",
        )
        .bind(archive_id)
        .bind(attempt_count)
        .bind(archive_bytes)
        .bind(archive_sha256)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(changed.rows_affected() == 1)
    }

    /// Completes only the current, unexpired fencing generation.
    pub(crate) async fn persist_success(
        &self,
        archive_id: &str,
        attempt_count: i64,
    ) -> Result<bool, ApiError> {
        validate_archive_id(archive_id)?;
        let changed = sqlx::query(
            "UPDATE instance_backup_replications SET status='succeeded', \
                 completed_at=clock_timestamp(),failure_category=NULL,next_attempt_at=NULL, \
                 multipart_upload_id=NULL,started_at=NULL,lease_expires_at=NULL \
             WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
               AND lease_expires_at>clock_timestamp()",
        )
        .bind(archive_id)
        .bind(attempt_count)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(changed.rows_affected() == 1)
    }

    /// Persists retry or terminal failure for the live generation. Retry
    /// timing is based on the caller's capped exponential delay; every exit
    /// from `running` clears the lease so the partial unique index is free.
    pub(crate) async fn persist_failure(
        &self,
        archive_id: &str,
        attempt_count: i64,
        category: &str,
        retryable: bool,
        delay_seconds: i64,
    ) -> Result<bool, ApiError> {
        validate_archive_id(archive_id)?;
        safe_failure_category(category)?;
        if retryable && !(1..=6 * 60 * 60).contains(&delay_seconds) {
            return Err(ApiError::internal(
                "PostgreSQL backup replication retry delay is invalid",
            ));
        }
        let changed = if retryable {
            sqlx::query(
                "UPDATE instance_backup_replications SET status='retry_wait', \
                     failure_category=$3, \
                     next_attempt_at=clock_timestamp()+make_interval(secs=>$4::double precision), \
                     completed_at=NULL,started_at=NULL,lease_expires_at=NULL \
                 WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
                   AND lease_expires_at>clock_timestamp()",
            )
            .bind(archive_id)
            .bind(attempt_count)
            .bind(category)
            .bind(delay_seconds)
            .execute(&self.pool)
            .await
        } else {
            sqlx::query(
                "UPDATE instance_backup_replications SET status='failed', \
                     failure_category=$3,completed_at=clock_timestamp(),next_attempt_at=NULL, \
                     started_at=NULL,lease_expires_at=NULL \
                 WHERE archive_id=$1 AND status='running' AND attempt_count=$2 \
                   AND lease_expires_at>clock_timestamp()",
            )
            .bind(archive_id)
            .bind(attempt_count)
            .bind(category)
            .execute(&self.pool)
            .await
        }
        .map_err(ApiError::internal)?;
        Ok(changed.rows_affected() == 1)
    }

    /// Reads one shared aggregate snapshot. The method accepts a caller-owned
    /// transaction so a future admin route can combine it with authorization.
    pub(crate) async fn snapshot_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
    ) -> Result<PgBackupReplicationSnapshot, ApiError> {
        let row = sqlx::query(
            "SELECT pending.pending_count,latest.archive_id,latest.status, \
                    latest.last_attempt_at,latest.completed_at,latest.archive_bytes, \
                    latest.failure_category \
             FROM (SELECT COUNT(*)::BIGINT AS pending_count \
                   FROM instance_backup_replications \
                   WHERE status IN ('pending_archive','pending','running','retry_wait','interrupted')) pending \
             LEFT JOIN LATERAL ( \
               SELECT archive_id,status,last_attempt_at,completed_at,archive_bytes,failure_category \
               FROM instance_backup_replications WHERE last_attempt_at IS NOT NULL \
               ORDER BY last_attempt_at DESC,archive_id DESC LIMIT 1 \
             ) latest ON TRUE",
        )
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;

        let pending_count: i64 = row.try_get("pending_count").map_err(ApiError::internal)?;
        let archive_id: Option<String> = row.try_get("archive_id").map_err(ApiError::internal)?;
        let latest_attempt = if let Some(archive_id) = archive_id {
            let state: String = row.try_get("status").map_err(ApiError::internal)?;
            let attempted_at: DateTime<Utc> =
                row.try_get("last_attempt_at").map_err(ApiError::internal)?;
            let completed_at: Option<DateTime<Utc>> =
                row.try_get("completed_at").map_err(ApiError::internal)?;
            let archive_bytes: Option<i64> =
                row.try_get("archive_bytes").map_err(ApiError::internal)?;
            let failure: Option<String> = row
                .try_get("failure_category")
                .map_err(ApiError::internal)?;
            Some(PgBackupReplicationAttempt {
                archive_id,
                state: safe_state_name(&state)?,
                attempted_at,
                completed_at,
                archive_bytes,
                failure_category: failure.as_deref().map(safe_failure_category).transpose()?,
            })
        } else {
            None
        };

        Ok(PgBackupReplicationSnapshot {
            pending_count,
            latest_attempt,
        })
    }

    pub(crate) async fn snapshot(&self) -> Result<PgBackupReplicationSnapshot, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let snapshot = self.snapshot_tx(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(snapshot)
    }
}

const RESTORE_ARCHIVE_MATCHING_JOB_FROM: &str = "FROM instance_backup_replications AS replication \
     JOIN instance_admin_jobs AS job \
       ON job.job_id=replication.archive_id \
      AND job.archive_id=replication.archive_id \
      AND job.action='backup' \
      AND job.status='succeeded' \
      AND job.result_code='completed' \
      AND job.request_origin=replication.origin \
      AND job.archive_bytes=replication.archive_bytes \
      AND job.archive_sha256=replication.archive_sha256 \
     WHERE replication.status='succeeded' \
       AND replication.archive_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' \
       AND replication.origin IN ('manual','scheduled') \
       AND replication.archive_bytes>0 \
       AND replication.archive_sha256 ~ '^[0-9a-f]{64}$'";

fn decode_restore_archive(row: sqlx::postgres::PgRow) -> Result<PgBackupReplicaArchive, ApiError> {
    let archive_id: String = row.try_get("archive_id").map_err(ApiError::internal)?;
    let origin: String = row.try_get("origin").map_err(ApiError::internal)?;
    let created_at: DateTime<Utc> = row.try_get("created_at").map_err(ApiError::internal)?;
    let archive_bytes: i64 = row.try_get("archive_bytes").map_err(ApiError::internal)?;
    let archive_sha256: String = row.try_get("archive_sha256").map_err(ApiError::internal)?;
    if !valid_restore_archive_fields(&archive_id, &origin, archive_bytes, &archive_sha256) {
        return Err(ApiError::internal(
            "PostgreSQL restore archive metadata is invalid",
        ));
    }
    Ok(PgBackupReplicaArchive {
        archive_id,
        origin,
        created_at,
        archive_bytes,
        archive_sha256,
    })
}

fn valid_restore_archive_fields(
    archive_id: &str,
    origin: &str,
    archive_bytes: i64,
    archive_sha256: &str,
) -> bool {
    is_canonical_uuid(archive_id)
        && matches!(origin, "manual" | "scheduled")
        && archive_bytes > 0
        && is_lower_sha256(archive_sha256)
}

/// Reconciles pre-snapshot outbox rows against the shared producer ledger.
/// This runs after the claim gate is held and uses one statement snapshot so
/// active producer jobs cannot be observed inconsistently across reads.
async fn reconcile_pending_archives(tx: &mut Transaction<'_, Postgres>) -> Result<(), ApiError> {
    sqlx::query(
        "WITH reconciliation_clock AS MATERIALIZED ( \
             SELECT clock_timestamp() AS now \
         ), pending AS MATERIALIZED ( \
             SELECT replication.archive_id,replication.origin, \
                    (job.action='backup' AND job.status='succeeded' \
                     AND job.result_code='completed' \
                     AND job.archive_id=replication.archive_id \
                     AND job.request_origin=replication.origin \
                     AND job.archive_bytes>0 \
                     AND job.archive_sha256 ~ '^[0-9a-f]{64}$' \
                     AND job.archive_timestamp IS NOT NULL \
                     AND job.archive_timestamp ~ '^[0-9]{8}T[0-9]{6}\\.[0-9]{3}Z$') \
                        AS archive_complete, \
                    job.archive_bytes,job.archive_sha256 \
             FROM instance_backup_replications AS replication \
             LEFT JOIN instance_admin_jobs AS job ON job.job_id=replication.archive_id \
             WHERE replication.status='pending_archive' \
               AND NOT COALESCE(job.action='backup' AND job.status IN ('queued','running'),FALSE) \
             FOR UPDATE OF replication SKIP LOCKED \
         ) \
         UPDATE instance_backup_replications AS replication \
         SET status=CASE WHEN pending.archive_complete IS TRUE THEN 'pending' ELSE 'failed' END, \
             archive_bytes=CASE WHEN pending.archive_complete IS TRUE \
                                THEN pending.archive_bytes ELSE NULL END, \
             archive_sha256=CASE WHEN pending.archive_complete IS TRUE \
                                 THEN pending.archive_sha256 ELSE NULL END, \
             next_attempt_at=CASE WHEN pending.archive_complete IS TRUE \
                                  THEN reconciliation_clock.now ELSE NULL END, \
             completed_at=CASE WHEN pending.archive_complete IS TRUE \
                               THEN NULL ELSE reconciliation_clock.now END, \
             failure_category=CASE WHEN pending.archive_complete IS TRUE \
                                   THEN NULL ELSE 'archive_unavailable' END, \
             started_at=NULL,lease_expires_at=NULL \
         FROM pending,reconciliation_clock \
         WHERE replication.archive_id=pending.archive_id \
           AND replication.status='pending_archive'",
    )
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn validate_identity(archive_id: &str, origin: &str) -> Result<(), ApiError> {
    validate_archive_id(archive_id)?;
    if !matches!(origin, "manual" | "scheduled") {
        return Err(ApiError::internal(
            "PostgreSQL backup replication source identity is invalid",
        ));
    }
    Ok(())
}

fn validate_archive_id(archive_id: &str) -> Result<(), ApiError> {
    if is_canonical_uuid(archive_id) {
        Ok(())
    } else {
        Err(ApiError::internal(
            "PostgreSQL backup replication archive identity is invalid",
        ))
    }
}

fn is_lower_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn safe_state_name(state: &str) -> Result<&'static str, ApiError> {
    match state {
        "pending_archive" => Ok("pending_archive"),
        "pending" => Ok("pending"),
        "running" => Ok("running"),
        "retry_wait" => Ok("retry_wait"),
        "succeeded" => Ok("succeeded"),
        "interrupted" => Ok("interrupted"),
        "failed" => Ok("failed"),
        _ => Err(ApiError::internal(
            "PostgreSQL backup replication state is invalid",
        )),
    }
}

fn safe_failure_category(value: &str) -> Result<&'static str, ApiError> {
    match value {
        "archive_unavailable" => Ok("archive_unavailable"),
        "credentials_invalid" => Ok("credentials_invalid"),
        "remote_unavailable" => Ok("remote_unavailable"),
        "remote_integrity_mismatch" => Ok("remote_integrity_mismatch"),
        "replication_failed" => Ok("replication_failed"),
        _ => Err(ApiError::internal(
            "PostgreSQL backup replication failure category is invalid",
        )),
    }
}

#[cfg(test)]
mod tests {
    use std::{panic::AssertUnwindSafe, str::FromStr};

    use futures_util::FutureExt;
    use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    #[test]
    fn archive_identity_and_digest_validation_are_bounded() {
        assert!(validate_identity(&Uuid::new_v4().to_string(), "manual").is_ok());
        assert!(validate_identity(&Uuid::new_v4().to_string(), "scheduled").is_ok());
        assert!(validate_identity("not-an-archive-id", "manual").is_err());
        assert!(validate_identity(&Uuid::new_v4().to_string(), "other").is_err());
        assert!(is_lower_sha256(&"a".repeat(64)));
        assert!(!is_lower_sha256(&"A".repeat(64)));
        assert!(!is_lower_sha256("short"));
        assert!(valid_restore_archive_fields(
            &Uuid::new_v4().to_string(),
            "manual",
            1,
            &"a".repeat(64),
        ));
        assert!(!valid_restore_archive_fields(
            "not-an-archive-id",
            "manual",
            1,
            &"a".repeat(64),
        ));
        assert!(!valid_restore_archive_fields(
            &Uuid::new_v4().to_string(),
            "other",
            1,
            &"a".repeat(64),
        ));
        assert!(!valid_restore_archive_fields(
            &Uuid::new_v4().to_string(),
            "manual",
            0,
            &"a".repeat(64),
        ));
        assert!(!valid_restore_archive_fields(
            &Uuid::new_v4().to_string(),
            "manual",
            1,
            &"A".repeat(64),
        ));
    }

    struct TestDatabase {
        pool_a: PgPool,
        pool_b: PgPool,
        admin_pool: PgPool,
        schema: String,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL backup replication test requires ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing PostgreSQL tests outside an explicitly disposable database"
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
            let schema = format!("atermius_pg_backup_replication_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL backup replication schema");
            let pool_options = options.options([("search_path", format!("\"{schema}\""))]);
            let pool_a = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(pool_options.clone())
                .await
                .expect("connect first isolated PostgreSQL node");
            let pool_b = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(pool_options)
                .await
                .expect("connect second isolated PostgreSQL node");
            sqlx::raw_sql(
                "CREATE TABLE instance_admin_jobs ( \
                   job_id TEXT PRIMARY KEY, action TEXT NOT NULL, status TEXT NOT NULL, \
                   result_code TEXT, request_origin TEXT NOT NULL, archive_id TEXT, \
                   archive_bytes BIGINT, archive_sha256 TEXT, archive_timestamp TEXT \
                 ); \
                 CREATE TABLE atermius_instance_schema ( \
                   singleton SMALLINT PRIMARY KEY CHECK(singleton=1), \
                   schema_version INTEGER NOT NULL \
                 ); \
                 INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,35)",
            )
            .execute(&pool_a)
            .await
            .expect("create isolated schema marker");
            sqlx::raw_sql(include_str!(
                "../migrations/postgres/0036_instance_backup_replications.sql"
            ))
            .execute(&pool_a)
            .await
            .expect("apply PostgreSQL backup replication migration");
            sqlx::raw_sql(include_str!(
                "../migrations/postgres/0037_instance_backup_replication_leases.sql"
            ))
            .execute(&pool_a)
            .await
            .expect("apply PostgreSQL backup replication lease migration");
            Self {
                pool_a,
                pool_b,
                admin_pool,
                schema,
            }
        }

        async fn cleanup(self) {
            self.pool_a.close().await;
            self.pool_b.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL backup replication schema");
            self.admin_pool.close().await;
        }
    }

    async fn insert_backup_job(
        pool: &PgPool,
        job_id: &str,
        status: &str,
        result_code: Option<&str>,
        origin: &str,
        archive_id: Option<&str>,
        archive_bytes: Option<i64>,
        archive_sha256: Option<&str>,
        archive_timestamp: Option<&str>,
    ) {
        sqlx::query(
            "INSERT INTO instance_admin_jobs( \
                 job_id,action,status,result_code,request_origin,archive_id, \
                 archive_bytes,archive_sha256,archive_timestamp \
             ) VALUES($1,'backup',$2,$3,$4,$5,$6,$7,$8)",
        )
        .bind(job_id)
        .bind(status)
        .bind(result_code)
        .bind(origin)
        .bind(archive_id)
        .bind(archive_bytes)
        .bind(archive_sha256)
        .bind(archive_timestamp)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn read_outbox_state(
        pool: &PgPool,
        archive_id: &str,
    ) -> (
        String,
        i64,
        Option<i64>,
        Option<String>,
        Option<String>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
    ) {
        sqlx::query_as(
            "SELECT status,attempt_count,archive_bytes,archive_sha256,failure_category, \
                    completed_at,lease_expires_at,next_attempt_at \
             FROM instance_backup_replications WHERE archive_id=$1",
        )
        .bind(archive_id)
        .fetch_one(pool)
        .await
        .unwrap()
    }

    async fn create_succeeded_replica_with_job(
        database: &TestDatabase,
        repository: &PgBackupReplicationRepository,
        archive_id: &str,
        job_id: &str,
    ) {
        let digest = "a".repeat(64);
        insert_backup_job(
            &database.pool_a,
            job_id,
            "succeeded",
            Some("completed"),
            "manual",
            Some(archive_id),
            Some(123),
            Some(&digest),
            Some("20261012T120000.123Z"),
        )
        .await;
        repository
            .register_archive_before_snapshot(archive_id, "manual")
            .await
            .unwrap();
        repository
            .archive_created(archive_id, 123, &digest)
            .await
            .unwrap();
        let claim = repository.claim_due().await.unwrap().unwrap();
        assert_eq!(claim.archive_id, archive_id);
        assert!(
            repository
                .persist_success(archive_id, claim.attempt_count)
                .await
                .unwrap()
        );
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL backup replication claim acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_backup_replication_claims_are_shared_fenced_and_retryable() {
        let database = TestDatabase::create().await;
        let repository_a = PgBackupReplicationRepository::new(database.pool_a.clone());
        let repository_b = PgBackupReplicationRepository::new(database.pool_b.clone());
        let result = AssertUnwindSafe(async {
            let archive_id = Uuid::new_v4().to_string();
            let digest = "a".repeat(64);
            repository_a
                .register_archive_before_snapshot(&archive_id, "manual")
                .await
                .unwrap();
            repository_a
                .archive_created(&archive_id, 123, &digest)
                .await
                .unwrap();

            // A competing transaction holding the shared claim gate makes a
            // second node return no work without touching the unique index.
            let mut held_gate = database.pool_a.begin().await.unwrap();
            sqlx::query(
                "SELECT pg_advisory_xact_lock( \
                     hashtextextended('atermius:backup-replication-claim:'||current_schema(),0))",
            )
            .execute(&mut *held_gate)
            .await
            .unwrap();
            assert!(repository_b.claim_due().await.unwrap().is_none());
            held_gate.rollback().await.unwrap();

            let first = repository_a.claim_due().await.unwrap().unwrap();
            assert_eq!(first.archive_id, archive_id);
            assert_eq!(first.origin, "manual");
            assert_eq!(first.attempt_count, 1);
            assert_eq!(first.archive_bytes, Some(123));
            assert_eq!(first.archive_sha256.as_deref(), Some(digest.as_str()));
            let lease_is_five_minutes_and_live: bool = sqlx::query_scalar(
                "SELECT lease_expires_at>clock_timestamp() \
                     AND lease_expires_at<=clock_timestamp()+INTERVAL '5 minutes' \
                 FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert!(lease_is_five_minutes_and_live);
            assert!(repository_b.claim_due().await.unwrap().is_none());
            assert!(!repository_b.renew_claim(&archive_id, 0).await.unwrap());
            assert!(
                repository_b
                    .renew_claim(&archive_id, first.attempt_count)
                    .await
                    .unwrap()
            );
            assert!(
                repository_a
                    .persist_upload_id(&archive_id, first.attempt_count, Some("multipart-1"))
                    .await
                    .unwrap()
            );
            assert!(
                repository_a
                    .persist_archive_metadata(&archive_id, first.attempt_count, 123, &digest)
                    .await
                    .unwrap()
            );
            assert!(
                repository_a
                    .persist_failure(
                        &archive_id,
                        first.attempt_count,
                        "remote_unavailable",
                        true,
                        15,
                    )
                    .await
                    .unwrap()
            );

            let retry_wait_is_exact_and_unleased: bool = sqlx::query_scalar(
                "SELECT status='retry_wait' AND failure_category='remote_unavailable' \
                     AND next_attempt_at>clock_timestamp()+INTERVAL '14 seconds' \
                     AND next_attempt_at<=clock_timestamp()+INTERVAL '15 seconds' \
                     AND started_at IS NULL AND lease_expires_at IS NULL \
                 FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert!(retry_wait_is_exact_and_unleased);
            assert!(repository_b.claim_due().await.unwrap().is_none());

            sqlx::query(
                "UPDATE instance_backup_replications \
                 SET next_attempt_at=clock_timestamp()-INTERVAL '1 second' \
                 WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
            let second = repository_b.claim_due().await.unwrap().unwrap();
            assert_eq!(second.attempt_count, 2);
            assert_eq!(second.multipart_upload_id.as_deref(), Some("multipart-1"));

            sqlx::query(
                "UPDATE instance_backup_replications \
                 SET lease_expires_at=clock_timestamp()-INTERVAL '1 second' \
                 WHERE archive_id=$1 AND attempt_count=$2",
            )
            .bind(&archive_id)
            .bind(second.attempt_count)
            .execute(&database.pool_a)
            .await
            .unwrap();
            assert!(
                !repository_a
                    .renew_claim(&archive_id, second.attempt_count)
                    .await
                    .unwrap()
            );
            assert!(
                !repository_a
                    .persist_upload_id(&archive_id, second.attempt_count, Some("stale-upload"))
                    .await
                    .unwrap()
            );
            assert!(
                !repository_a
                    .persist_archive_metadata(&archive_id, second.attempt_count, 123, &digest)
                    .await
                    .unwrap()
            );
            assert!(
                !repository_a
                    .persist_success(&archive_id, second.attempt_count)
                    .await
                    .unwrap()
            );
            assert!(
                !repository_a
                    .persist_failure(
                        &archive_id,
                        second.attempt_count,
                        "remote_unavailable",
                        true,
                        15,
                    )
                    .await
                    .unwrap()
            );

            let third = repository_a.claim_due().await.unwrap().unwrap();
            assert_eq!(third.attempt_count, 3);
            assert_eq!(third.multipart_upload_id.as_deref(), Some("multipart-1"));
            assert!(
                !repository_b
                    .persist_success(&archive_id, first.attempt_count)
                    .await
                    .unwrap()
            );
            assert!(
                repository_b
                    .persist_success(&archive_id, third.attempt_count)
                    .await
                    .unwrap()
            );
            let success_is_unleased: bool = sqlx::query_scalar(
                "SELECT status='succeeded' AND completed_at IS NOT NULL \
                     AND lease_expires_at IS NULL AND started_at IS NULL \
                     AND multipart_upload_id IS NULL \
                 FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert!(success_is_unleased);

            let failed_archive_id = Uuid::new_v4().to_string();
            repository_a
                .register_archive_before_snapshot(&failed_archive_id, "scheduled")
                .await
                .unwrap();
            repository_a
                .archive_created(&failed_archive_id, 456, &"b".repeat(64))
                .await
                .unwrap();
            let failed_claim = repository_b.claim_due().await.unwrap().unwrap();
            assert_eq!(failed_claim.archive_id, failed_archive_id);
            assert!(
                repository_b
                    .persist_failure(
                        &failed_archive_id,
                        failed_claim.attempt_count,
                        "credentials_invalid",
                        false,
                        0,
                    )
                    .await
                    .unwrap()
            );
            let terminal_is_unleased: bool = sqlx::query_scalar(
                "SELECT status='failed' AND completed_at IS NOT NULL \
                     AND next_attempt_at IS NULL AND lease_expires_at IS NULL \
                     AND started_at IS NULL \
                 FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&failed_archive_id)
            .fetch_one(&database.pool_a)
            .await
            .unwrap();
            assert!(terminal_is_unleased);
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        result.unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL backup replication repository acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_backup_replication_outbox_is_shared_idempotent_and_provider_secret_free() {
        let database = TestDatabase::create().await;
        let repository_a = PgBackupReplicationRepository::new(database.pool_a.clone());
        let repository_b = PgBackupReplicationRepository::new(database.pool_b.clone());
        let result = AssertUnwindSafe(async {
            let marker: i64 = sqlx::query_scalar(
                "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
            )
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(marker, 37);

            let archive_id = Uuid::new_v4().to_string();
            repository_a
                .register_archive_before_snapshot(&archive_id, "manual")
                .await
                .unwrap();
            let created_at: DateTime<Utc> = sqlx::query_scalar(
                "SELECT created_at FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            repository_b
                .register_archive_before_snapshot(&archive_id, "manual")
                .await
                .unwrap();
            assert!(
                repository_b
                    .register_archive_before_snapshot(&archive_id, "scheduled")
                    .await
                    .is_err()
            );
            assert_eq!(
                sqlx::query_scalar::<_, DateTime<Utc>>(
                    "SELECT created_at FROM instance_backup_replications WHERE archive_id=$1",
                )
                .bind(&archive_id)
                .fetch_one(&database.pool_a)
                .await
                .unwrap(),
                created_at,
                "same-origin insert retry must not rewrite the original row"
            );
            assert_eq!(repository_b.snapshot().await.unwrap().pending_count, 1);

            let digest = "a".repeat(64);
            repository_a
                .archive_created(&archive_id, 123, &digest)
                .await
                .unwrap();
            let next_attempt_at: DateTime<Utc> = sqlx::query_scalar(
                "SELECT next_attempt_at FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            repository_b
                .archive_created(&archive_id, 123, &digest)
                .await
                .unwrap();
            assert_eq!(
                sqlx::query_scalar::<_, DateTime<Utc>>(
                    "SELECT next_attempt_at FROM instance_backup_replications WHERE archive_id=$1",
                )
                .bind(&archive_id)
                .fetch_one(&database.pool_a)
                .await
                .unwrap(),
                next_attempt_at,
                "same-digest retry must not reset a published outbox transition"
            );
            assert!(
                repository_a
                    .archive_created(&archive_id, 124, &digest)
                    .await
                    .is_err()
            );
            assert!(
                repository_a
                    .archive_created(&archive_id, 123, &"b".repeat(64))
                    .await
                    .is_err()
            );
            let row: (String, i64, String) = sqlx::query_as(
                "SELECT status,archive_bytes,archive_sha256 \
                 FROM instance_backup_replications WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(row, ("pending".into(), 123, digest));

            sqlx::query(
                "UPDATE instance_backup_replications SET last_attempt_at=clock_timestamp(), \
                    started_at=clock_timestamp() WHERE archive_id=$1",
            )
            .bind(&archive_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
            let status = repository_b.snapshot().await.unwrap();
            assert_eq!(status.pending_count, 1);
            let attempt = status
                .latest_attempt
                .expect("shared attempt row is visible");
            assert_eq!(attempt.archive_id, archive_id);
            assert_eq!(attempt.state, "pending");
            assert_eq!(attempt.archive_bytes, Some(123));
            assert_eq!(attempt.failure_category, None);

            let failed_archive_id = Uuid::new_v4().to_string();
            repository_a
                .register_archive_before_snapshot(&failed_archive_id, "scheduled")
                .await
                .unwrap();
            repository_b
                .archive_creation_failed(&failed_archive_id)
                .await
                .unwrap();
            repository_a
                .archive_creation_failed(&failed_archive_id)
                .await
                .unwrap();
            let failure: (String, String, Option<DateTime<Utc>>) = sqlx::query_as(
                "SELECT status,failure_category,completed_at FROM instance_backup_replications \
                 WHERE archive_id=$1",
            )
            .bind(&failed_archive_id)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(failure.0, "failed");
            assert_eq!(failure.1, "archive_unavailable");
            assert!(failure.2.is_some());

            let columns: Vec<String> = sqlx::query_scalar(
                "SELECT column_name FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name='instance_backup_replications' \
                 ORDER BY ordinal_position",
            )
            .fetch_all(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(
                columns,
                vec![
                    "archive_id".to_owned(),
                    "origin".to_owned(),
                    "created_at".to_owned(),
                    "status".to_owned(),
                    "archive_bytes".to_owned(),
                    "archive_sha256".to_owned(),
                    "attempt_count".to_owned(),
                    "next_attempt_at".to_owned(),
                    "started_at".to_owned(),
                    "last_attempt_at".to_owned(),
                    "completed_at".to_owned(),
                    "failure_category".to_owned(),
                    "multipart_upload_id".to_owned(),
                    "lease_expires_at".to_owned(),
                ]
            );
            assert!(columns.iter().all(|column| {
                !["secret", "credential", "endpoint", "bucket", "region"]
                    .iter()
                    .any(|forbidden| column.contains(forbidden))
            }));
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        result.unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL backup replication reconciliation acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_backup_replication_reconciles_pending_archive_from_shared_jobs() {
        let database = TestDatabase::create().await;
        let repository_a = PgBackupReplicationRepository::new(database.pool_a.clone());
        let repository_b = PgBackupReplicationRepository::new(database.pool_b.clone());
        let result = AssertUnwindSafe(async {
            let queued_id = Uuid::new_v4().to_string();
            let running_id = Uuid::new_v4().to_string();
            let complete_id = Uuid::new_v4().to_string();
            let failed_id = Uuid::new_v4().to_string();
            let interrupted_id = Uuid::new_v4().to_string();
            let missing_job_id = Uuid::new_v4().to_string();
            let incomplete_id = Uuid::new_v4().to_string();
            let digest = "c".repeat(64);
            let timestamp = "20261012T120000.123Z";

            for (archive_id, origin) in [
                (&queued_id, "manual"),
                (&running_id, "manual"),
                (&complete_id, "scheduled"),
                (&failed_id, "manual"),
                (&interrupted_id, "manual"),
                (&missing_job_id, "manual"),
                (&incomplete_id, "manual"),
            ] {
                repository_a
                    .register_archive_before_snapshot(archive_id, origin)
                    .await
                    .unwrap();
            }

            insert_backup_job(
                &database.pool_a,
                &queued_id,
                "queued",
                None,
                "manual",
                Some(&queued_id),
                None,
                None,
                None,
            )
            .await;
            insert_backup_job(
                &database.pool_a,
                &running_id,
                "running",
                None,
                "manual",
                Some(&running_id),
                None,
                None,
                None,
            )
            .await;
            insert_backup_job(
                &database.pool_a,
                &complete_id,
                "succeeded",
                Some("completed"),
                "scheduled",
                Some(&complete_id),
                Some(321),
                Some(&digest),
                Some(timestamp),
            )
            .await;
            insert_backup_job(
                &database.pool_a,
                &failed_id,
                "failed",
                Some("backup_failed"),
                "manual",
                Some(&failed_id),
                None,
                None,
                None,
            )
            .await;
            insert_backup_job(
                &database.pool_a,
                &interrupted_id,
                "interrupted",
                Some("interrupted"),
                "manual",
                Some(&interrupted_id),
                None,
                None,
                None,
            )
            .await;
            insert_backup_job(
                &database.pool_a,
                &incomplete_id,
                "succeeded",
                Some("completed"),
                "manual",
                Some(&incomplete_id),
                None,
                Some(&digest),
                Some(timestamp),
            )
            .await;

            // A finished producer is recovered and claimed with its exact
            // archive metadata; active producers remain untouched.
            let recovered = repository_a.claim_due().await.unwrap().unwrap();
            assert_eq!(recovered.archive_id, complete_id);
            assert_eq!(recovered.origin, "scheduled");
            assert_eq!(recovered.archive_bytes, Some(321));
            assert_eq!(recovered.archive_sha256.as_deref(), Some(digest.as_str()));
            for active_id in [&queued_id, &running_id] {
                let state = read_outbox_state(&database.pool_b, active_id).await;
                assert_eq!(state.0, "pending_archive");
                assert_eq!(state.1, 0);
                assert_eq!(state.2, None);
                assert_eq!(state.3, None);
                assert_eq!(state.4, None);
                assert_eq!(state.5, None);
                assert_eq!(state.6, None);
            }

            // Terminal producer failure, interrupted production, a missing
            // parent job, and incomplete archive metadata all become the
            // same fixed, terminal no-archive outcome visible from another pool.
            let mut terminal_completed_at = Vec::new();
            for failed_id in [&failed_id, &interrupted_id, &missing_job_id, &incomplete_id] {
                let state = read_outbox_state(&database.pool_b, failed_id).await;
                assert_eq!(state.0, "failed");
                assert_eq!(state.1, 0);
                assert_eq!(state.2, None);
                assert_eq!(state.3, None);
                assert_eq!(state.4.as_deref(), Some("archive_unavailable"));
                assert!(state.5.is_some());
                assert_eq!(state.6, None);
                assert_eq!(state.7, None);
                terminal_completed_at.push(state.5.unwrap());
            }

            // Re-running reconciliation is idempotent and cannot claim an
            // active producer or rewrite terminal completion timestamps.
            assert!(repository_b.claim_due().await.unwrap().is_none());
            for (index, failed_id) in [&failed_id, &interrupted_id, &missing_job_id, &incomplete_id]
                .iter()
                .enumerate()
            {
                let state = read_outbox_state(&database.pool_a, failed_id).await;
                assert_eq!(state.5.as_ref(), Some(&terminal_completed_at[index]));
            }

            // Once a queued producer completes, another pool can reconcile
            // and claim it. A running producer that later fails is finalized.
            assert!(
                repository_b
                    .persist_success(&complete_id, recovered.attempt_count)
                    .await
                    .unwrap()
            );
            sqlx::query(
                "UPDATE instance_admin_jobs SET status='succeeded',result_code='completed', \
                     archive_bytes=456,archive_sha256=$2,archive_timestamp=$3 \
                 WHERE job_id=$1",
            )
            .bind(&queued_id)
            .bind(&digest)
            .bind(timestamp)
            .execute(&database.pool_a)
            .await
            .unwrap();
            let queued_recovered = repository_b.claim_due().await.unwrap().unwrap();
            assert_eq!(queued_recovered.archive_id, queued_id);
            assert_eq!(queued_recovered.archive_bytes, Some(456));
            assert_eq!(
                queued_recovered.archive_sha256.as_deref(),
                Some(digest.as_str())
            );
            assert!(
                repository_a
                    .persist_success(&queued_recovered.archive_id, queued_recovered.attempt_count)
                    .await
                    .unwrap()
            );

            sqlx::query(
                "UPDATE instance_admin_jobs SET status='failed',result_code='backup_failed' \
                 WHERE job_id=$1",
            )
            .bind(&running_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
            assert!(repository_a.claim_due().await.unwrap().is_none());
            let running_failed = read_outbox_state(&database.pool_b, &running_id).await;
            assert_eq!(running_failed.0, "failed");
            assert_eq!(running_failed.4.as_deref(), Some("archive_unavailable"));
            assert!(running_failed.5.is_some());
            assert_eq!(running_failed.6, None);
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        result.unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL replica restore catalog acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_replica_restore_catalog_requires_matching_succeeded_backup_job() {
        let database = TestDatabase::create().await;
        let repository_a = PgBackupReplicationRepository::new(database.pool_a.clone());
        let repository_b = PgBackupReplicationRepository::new(database.pool_b.clone());
        let result = AssertUnwindSafe(async {
            let valid_id = Uuid::new_v4().to_string();
            create_succeeded_replica_with_job(&database, &repository_a, &valid_id, &valid_id)
                .await;

            let mismatched_job_id_archive = Uuid::new_v4().to_string();
            let mismatched_job_id = Uuid::new_v4().to_string();
            create_succeeded_replica_with_job(
                &database,
                &repository_a,
                &mismatched_job_id_archive,
                &mismatched_job_id,
            )
            .await;

            let mut mismatched_rows = Vec::new();
            for mismatch in ["archive_id", "origin", "bytes", "digest", "action", "status", "result"] {
                let archive_id = Uuid::new_v4().to_string();
                create_succeeded_replica_with_job(
                    &database,
                    &repository_a,
                    &archive_id,
                    &archive_id,
                )
                .await;
                let update = match mismatch {
                    "archive_id" => "UPDATE instance_admin_jobs SET archive_id=$2 WHERE job_id=$1",
                    "origin" => "UPDATE instance_admin_jobs SET request_origin='scheduled' WHERE job_id=$1",
                    "bytes" => "UPDATE instance_admin_jobs SET archive_bytes=archive_bytes+1 WHERE job_id=$1",
                    "digest" => "UPDATE instance_admin_jobs SET archive_sha256=$2 WHERE job_id=$1",
                    "action" => "UPDATE instance_admin_jobs SET action='restore' WHERE job_id=$1",
                    "status" => "UPDATE instance_admin_jobs SET status='failed',result_code='backup_failed' WHERE job_id=$1",
                    "result" => "UPDATE instance_admin_jobs SET result_code='backup_failed' WHERE job_id=$1",
                    _ => unreachable!(),
                };
                let mut query = sqlx::query(update).bind(&archive_id);
                if mismatch == "archive_id" {
                    query = query.bind(Uuid::new_v4().to_string());
                } else if mismatch == "digest" {
                    query = query.bind("b".repeat(64));
                }
                query.execute(&database.pool_a).await.unwrap();
                mismatched_rows.push(archive_id);
            }

            let missing_job_archive_id = Uuid::new_v4().to_string();
            repository_a
                .register_archive_before_snapshot(&missing_job_archive_id, "manual")
                .await
                .unwrap();
            repository_a
                .archive_created(&missing_job_archive_id, 123, &"a".repeat(64))
                .await
                .unwrap();
            let missing_job_claim = repository_a.claim_due().await.unwrap().unwrap();
            assert_eq!(missing_job_claim.archive_id, missing_job_archive_id);
            assert!(repository_a
                .persist_success(&missing_job_archive_id, missing_job_claim.attempt_count)
                .await
                .unwrap());

            let listed = repository_b.list_restore_archives().await.unwrap();
            assert_eq!(listed.len(), 1);
            let archive = &listed[0];
            assert_eq!(archive.archive_id, valid_id);
            assert_eq!(archive.origin, "manual");
            assert_eq!(archive.archive_bytes, 123);
            assert_eq!(archive.archive_sha256, "a".repeat(64));
            assert!(archive.created_at <= Utc::now());

            assert_eq!(
                repository_b
                    .restore_archive_metadata(&valid_id)
                    .await
                    .unwrap()
                    .as_ref(),
                Some(archive),
            );
            for archive_id in mismatched_rows
                .iter()
                .chain([&mismatched_job_id_archive, &missing_job_archive_id])
            {
                assert!(repository_b
                    .restore_archive_metadata(archive_id)
                    .await
                    .unwrap()
                    .is_none());
            }
            assert!(repository_b
                .restore_archive_metadata(&Uuid::new_v4().to_string())
                .await
                .unwrap()
                .is_none());
            assert!(repository_b
                .restore_archive_metadata("not-a-canonical-uuid")
                .await
                .is_err());
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        result.unwrap();
    }
}

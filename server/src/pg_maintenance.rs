//! Bounded PostgreSQL retention maintenance for the restricted shared runtime.
//!
//! This module only compacts the ordered sync event stream, retires expired
//! snapshot payloads while preserving snapshot tombstones for HTTP 410, prunes
//! bounded notification and Relay state, and delegates auth bucket cleanup to
//! the rate-limit repository. Every pass is
//! safe to run concurrently on multiple nodes and from the operator CLI.

use chrono::{DateTime, Duration, Utc};
use sqlx::{PgPool, Row};

use crate::{ApiError, pg_rate_limit::PgAuthRateLimitRepository};

const VAULTS_PER_PASS: i64 = 32;
const EVENTS_PER_VAULT_PER_PASS: i64 = 500;
const SNAPSHOTS_PER_VAULT_PER_PASS: i64 = 8;
const SNAPSHOT_ITEMS_PER_PASS: i64 = 1_000;
const NOTIFICATION_TICKETS_PER_PASS: i64 = 1_000;
const RELAY_ROWS_PER_PASS: i64 = 1_000;

#[derive(Clone)]
pub(crate) struct PgMaintenanceRepository {
    pool: PgPool,
}

impl PgMaintenanceRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Runs one bounded, idempotent retention pass. Database row locks are the
    /// cross-node coordinator; no node-local SQLite or file lock participates.
    pub(crate) async fn run_one_pass(
        &self,
        history_retention_days: i64,
        rate_limits: &PgAuthRateLimitRepository,
    ) -> Result<(), ApiError> {
        if !(1..=3650).contains(&history_retention_days) {
            return Err(ApiError::internal("invalid PostgreSQL history retention"));
        }
        if let Err(error) = self.compact_expired_history(history_retention_days).await {
            tracing::error!("PostgreSQL history and snapshot retention pass failed");
            return Err(error);
        }
        if let Err(error) = crate::pg_presence::PgPresenceRepository::new(self.pool.clone())
            .cleanup(10_000)
            .await
        {
            tracing::error!("PostgreSQL Vault presence cleanup pass failed");
            return Err(error);
        }
        if let Err(error) = self.prune_expired_notification_tickets().await {
            tracing::error!("PostgreSQL notification-ticket retention pass failed");
            return Err(error);
        }
        if let Err(error) = self.prune_expired_relay_state().await {
            tracing::error!("PostgreSQL Relay retention pass failed");
            return Err(error);
        }
        if let Err(error) = rate_limits.prune_expired().await {
            tracing::error!("PostgreSQL authentication bucket retention pass failed");
            return Err(error);
        }
        Ok(())
    }

    async fn compact_expired_history(&self, retention_days: i64) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let cutoff = now - Duration::days(retention_days);

        // Lock only a bounded number of counters in a stable order. Concurrent
        // maintenance processes skip counters already claimed by another pass.
        let vaults = sqlx::query(
            "SELECT c.vault_id,c.minimum_available_seq, \
                 LEAST(\
                     COALESCE((SELECT e.created_at FROM change_events e \
                               WHERE e.vault_id=c.vault_id \
                                 AND e.commit_seq=c.minimum_available_seq \
                                 AND e.created_at < $1), 'infinity'::timestamptz), \
                     COALESCE((SELECT s.expires_at FROM snapshots s \
                               WHERE s.vault_id=c.vault_id AND s.expires_at <= $2 \
                                 AND (s.snapshot_manifest_format <> 'expired' \
                                      OR s.snapshot_item_count > 0 \
                                      OR EXISTS (SELECT 1 FROM snapshot_items i \
                                                 WHERE i.snapshot_id=s.snapshot_id)) \
                               ORDER BY s.expires_at,s.snapshot_id LIMIT 1), \
                              'infinity'::timestamptz)\
                 ) AS due_since \
             FROM vault_counters c \
             WHERE EXISTS (SELECT 1 FROM change_events e \
                           WHERE e.vault_id=c.vault_id \
                             AND e.commit_seq=c.minimum_available_seq \
                             AND e.created_at < $1) \
                OR EXISTS (SELECT 1 FROM snapshots s \
                           WHERE s.vault_id=c.vault_id AND s.expires_at <= $2 \
                             AND (s.snapshot_manifest_format <> 'expired' \
                                  OR s.snapshot_item_count > 0 \
                                  OR EXISTS (SELECT 1 FROM snapshot_items i \
                                             WHERE i.snapshot_id=s.snapshot_id))) \
             ORDER BY due_since,c.vault_id LIMIT $3 FOR UPDATE OF c SKIP LOCKED",
        )
        .bind(cutoff)
        .bind(now)
        .bind(VAULTS_PER_PASS)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        for vault in &vaults {
            let vault_id: String = vault.try_get("vault_id").map_err(ApiError::internal)?;
            let minimum_available_seq: i64 = vault
                .try_get("minimum_available_seq")
                .map_err(ApiError::internal)?;
            let events = sqlx::query(
                "SELECT commit_seq,created_at FROM change_events \
                 WHERE vault_id=$1 AND commit_seq >= $2 \
                 ORDER BY commit_seq LIMIT $3",
            )
            .bind(&vault_id)
            .bind(minimum_available_seq)
            .bind(EVENTS_PER_VAULT_PER_PASS)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

            let sequenced_events = events
                .iter()
                .map(|row| {
                    Ok((
                        row.try_get::<i64, _>("commit_seq")
                            .map_err(ApiError::internal)?,
                        row.try_get::<DateTime<Utc>, _>("created_at")
                            .map_err(ApiError::internal)?,
                    ))
                })
                .collect::<Result<Vec<_>, ApiError>>()?;
            let Some(new_floor) =
                contiguous_expired_prefix(minimum_available_seq, &sequenced_events, cutoff)
            else {
                continue;
            };

            // A committed sequence is retained only if both the floor and its
            // exact contiguous prefix deletion commit together. The counter
            // lock fences sync writers; MVCC readers see the old or new pair.
            let advanced = sqlx::query(
                "UPDATE vault_counters SET minimum_available_seq=$2 \
                 WHERE vault_id=$1 AND minimum_available_seq=$3",
            )
            .bind(&vault_id)
            .bind(new_floor)
            .bind(minimum_available_seq)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if advanced.rows_affected() != 1 {
                return Err(ApiError::internal(
                    "PostgreSQL history floor changed unexpectedly",
                ));
            }
            let deleted = sqlx::query(
                "DELETE FROM change_events WHERE vault_id=$1 \
                 AND commit_seq >= $2 AND commit_seq < $3",
            )
            .bind(&vault_id)
            .bind(minimum_available_seq)
            .bind(new_floor)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if deleted.rows_affected() != (new_floor - minimum_available_seq) as u64 {
                return Err(ApiError::internal(
                    "PostgreSQL history prefix was not contiguous",
                ));
            }
        }

        self.prune_expired_snapshot_payloads(&mut tx, now, &vaults)
            .await?;

        tx.commit().await.map_err(ApiError::internal)
    }

    async fn prune_expired_notification_tickets(&self) -> Result<(), ApiError> {
        // Tickets count toward the issuance-rate limit for a full minute even
        // though they can authenticate only for 30 seconds. Delete only rows
        // older than that full window, in a bounded SKIP LOCKED batch, so a
        // cleanup pass never changes a still-live rate-limit decision.
        sqlx::query(
            "WITH cutoff AS ( \
                 SELECT clock_timestamp()-INTERVAL '60 seconds' AS value \
             ), expired AS ( \
                 SELECT t.ticket_hash FROM notification_tickets t CROSS JOIN cutoff c \
                 WHERE t.created_at <= c.value \
                 ORDER BY t.created_at,t.ticket_hash LIMIT $1 \
                 FOR UPDATE OF t SKIP LOCKED \
             ) \
             DELETE FROM notification_tickets t USING expired e \
             WHERE t.ticket_hash=e.ticket_hash",
        )
        .bind(NOTIFICATION_TICKETS_PER_PASS)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn prune_expired_relay_state(&self) -> Result<(), ApiError> {
        // Retain tickets for the full 60-second issuance window even though
        // they can authenticate only for 30 seconds. Connection leases are
        // short lived and self-renewed by active WebSocket session checks.
        sqlx::query(
            "WITH expired AS ( \
                 SELECT ticket_hash FROM relay_tickets \
                 WHERE created_at<=clock_timestamp()-INTERVAL '60 seconds' \
                 ORDER BY created_at,ticket_hash LIMIT $1 FOR UPDATE SKIP LOCKED \
             ) DELETE FROM relay_tickets t USING expired e WHERE t.ticket_hash=e.ticket_hash",
        )
        .bind(RELAY_ROWS_PER_PASS)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "WITH expired AS ( \
                 SELECT connection_id FROM relay_connection_leases \
                 WHERE lease_expires_at<=clock_timestamp() \
                 ORDER BY lease_expires_at,connection_id LIMIT $1 FOR UPDATE SKIP LOCKED \
             ) DELETE FROM relay_connection_leases l USING expired e WHERE l.connection_id=e.connection_id",
        )
        .bind(RELAY_ROWS_PER_PASS)
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn prune_expired_snapshot_payloads(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        now: DateTime<Utc>,
        vaults: &[sqlx::postgres::PgRow],
    ) -> Result<(), ApiError> {
        let mut pending_snapshot_ids = Vec::new();
        for vault in vaults {
            let vault_id: String = vault.try_get("vault_id").map_err(ApiError::internal)?;

            // Existing snapshots(vault_id, expires_at) index bounds each
            // Vault's expiry claim. Keep item_count as a compact progress
            // marker until every child row is removed; format='expired' and
            // the empty manifest immediately protect the payload and preserve
            // the parent for a stable 410 response.
            sqlx::query(
                "WITH expired AS (\
                     SELECT snapshot_id FROM snapshots \
                     WHERE vault_id=$1 AND expires_at <= $2 \
                       AND snapshot_manifest_format <> 'expired' \
                     ORDER BY expires_at,snapshot_id LIMIT $3 \
                     FOR UPDATE SKIP LOCKED\
                 ) \
                 UPDATE snapshots s SET manifest_json='[]', \
                     snapshot_manifest_format='expired' \
                 FROM expired WHERE s.snapshot_id=expired.snapshot_id",
            )
            .bind(&vault_id)
            .bind(now)
            .bind(SNAPSHOTS_PER_VAULT_PER_PASS)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;

            let pending = sqlx::query(
                "SELECT snapshot_id FROM snapshots \
                 WHERE vault_id=$1 AND expires_at <= $2 \
                   AND snapshot_manifest_format='expired' \
                   AND (snapshot_item_count > 0 OR EXISTS (\
                       SELECT 1 FROM snapshot_items i \
                       WHERE i.snapshot_id=snapshots.snapshot_id)) \
                 ORDER BY expires_at,snapshot_id LIMIT $3 \
                 FOR UPDATE SKIP LOCKED",
            )
            .bind(&vault_id)
            .bind(now)
            .bind(SNAPSHOTS_PER_VAULT_PER_PASS)
            .fetch_all(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
            for snapshot in pending {
                pending_snapshot_ids.push(
                    snapshot
                        .try_get::<String, _>("snapshot_id")
                        .map_err(ApiError::internal)?,
                );
            }
        }

        if pending_snapshot_ids.is_empty() {
            return Ok(());
        }

        // Child rows are independently bounded so one large snapshot cannot
        // turn a routine pass into an unbounded delete transaction. The parent
        // rows are locked above, which serializes this with snapshot readers.
        sqlx::query(
            "WITH expired_items AS (\
                 SELECT snapshot_id,record_id FROM snapshot_items \
                 WHERE snapshot_id = ANY($1::TEXT[]) \
                 ORDER BY snapshot_id,record_id COLLATE \"C\" \
                 LIMIT $2 FOR UPDATE SKIP LOCKED\
             ) \
             DELETE FROM snapshot_items i USING expired_items e \
             WHERE i.snapshot_id=e.snapshot_id AND i.record_id=e.record_id",
        )
        .bind(&pending_snapshot_ids)
        .bind(SNAPSHOT_ITEMS_PER_PASS)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;

        // The count is only used as a bounded cleanup marker for expired
        // manifests. Finalize parents whose last child row was just removed.
        sqlx::query(
            "UPDATE snapshots s SET snapshot_item_count=0 \
             WHERE s.snapshot_id = ANY($1::TEXT[]) AND s.snapshot_item_count > 0 \
               AND NOT EXISTS (SELECT 1 FROM snapshot_items i \
                               WHERE i.snapshot_id=s.snapshot_id)",
        )
        .bind(&pending_snapshot_ids)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;

        Ok(())
    }
}

/// Returns the floor after the oldest expired contiguous prefix, or `None`
/// when the first event is absent, recent, or does not match the stored floor.
fn contiguous_expired_prefix(
    minimum_available_seq: i64,
    events: &[(i64, DateTime<Utc>)],
    cutoff: DateTime<Utc>,
) -> Option<i64> {
    let mut next = minimum_available_seq;
    for (sequence, created_at) in events.iter().take(EVENTS_PER_VAULT_PER_PASS as usize) {
        if *sequence != next || *created_at >= cutoff {
            break;
        }
        let Some(advanced) = next.checked_add(1) else {
            break;
        };
        next = advanced;
    }
    (next > minimum_available_seq).then_some(next)
}

#[cfg(test)]
mod tests {
    use chrono::{Duration, Utc};

    use super::contiguous_expired_prefix;

    #[test]
    fn history_retention_never_skips_a_recent_or_missing_sequence() {
        let cutoff = Utc::now();
        let old = cutoff - Duration::days(2);
        let recent = cutoff + Duration::seconds(1);

        assert_eq!(
            contiguous_expired_prefix(1, &[(1, old), (2, recent), (3, old)], cutoff),
            Some(2)
        );
        assert_eq!(
            contiguous_expired_prefix(1, &[(1, recent), (2, old)], cutoff),
            None
        );
        assert_eq!(contiguous_expired_prefix(2, &[(3, old)], cutoff), None);
        assert_eq!(
            contiguous_expired_prefix(4, &[(4, old), (5, old)], cutoff),
            Some(6)
        );
    }
}

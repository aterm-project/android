//! PostgreSQL-backed, short-lived Vault presence leases.
//!
//! Presence is shared operational state only. It does not enter encrypted
//! record history or audit feeds and every lease is checked against live
//! account, device, session and Vault membership state when read.

use std::collections::HashMap;

use axum::Json;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth::AuthUser};

const PRESENCE_TTL_SECONDS: i64 = 90;
const MIN_HEARTBEAT_INTERVAL_MILLIS: i64 = 5_000;
const MAX_LIVE_LEASES_PER_USER_VAULT: i64 = 8;
const MAX_LIVE_LEASES_INSTANCE_WIDE: i64 = 100_000;
const PRESENCE_CAPACITY_LOCK_NAMESPACE: i32 = 1_096_041_810; // "ATER"
const PRESENCE_CAPACITY_LOCK_KEY: i32 = 1_347_568_979; // "PRES"

#[derive(Clone)]
pub(crate) struct PgPresenceRepository {
    pool: PgPool,
}

impl PgPresenceRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub(crate) async fn heartbeat(
        &self,
        user: &AuthUser,
        vault_id: &str,
    ) -> Result<Json<Value>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_session_device_membership(&mut tx, user, vault_id).await?;

        let gate = sqlx::query(
            "INSERT INTO vault_presence_heartbeat_limits(vault_id,session_id,last_heartbeat_at) \
             VALUES($1,$2,clock_timestamp()) \
             ON CONFLICT(vault_id,session_id) DO UPDATE SET \
               last_heartbeat_at=EXCLUDED.last_heartbeat_at \
             WHERE vault_presence_heartbeat_limits.last_heartbeat_at <= \
               clock_timestamp() - ($3::double precision * INTERVAL '1 millisecond') \
             RETURNING 1",
        )
        .bind(vault_id)
        .bind(&user.session_id)
        .bind(MIN_HEARTBEAT_INTERVAL_MILLIS as f64)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if gate.is_none() {
            tx.rollback().await.map_err(ApiError::internal)?;
            return Err(ApiError::presence_heartbeat_rate_limited());
        }

        let already_leased = has_live_lease(&mut tx, vault_id, &user.session_id).await?;
        if !already_leased {
            // Serialize only first-lease admission across nodes. Normal
            // renewals stay independent; the second check handles another
            // request for this same session which was waiting on the lock.
            sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
                .bind(PRESENCE_CAPACITY_LOCK_NAMESPACE)
                .bind(PRESENCE_CAPACITY_LOCK_KEY)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            if !has_live_lease(&mut tx, vault_id, &user.session_id).await? {
                let user_vault_leases =
                    count_live_leases(&mut tx, Some(vault_id), Some(&user.user_id)).await?;
                let instance_leases = count_live_leases(&mut tx, None, None).await?;
                if user_vault_leases >= MAX_LIVE_LEASES_PER_USER_VAULT
                    || instance_leases >= MAX_LIVE_LEASES_INSTANCE_WIDE
                {
                    // Preserve the write gate on capacity rejection so a
                    // client cannot bypass it with an immediate retry.
                    tx.commit().await.map_err(ApiError::internal)?;
                    return Err(ApiError::conflict(
                        "PRESENCE_LEASE_LIMIT",
                        "temporary presence lease capacity is full",
                    ));
                }
            }
        }

        let (last_seen_at, expires_at): (DateTime<Utc>, DateTime<Utc>) = sqlx::query_as(
            "SELECT clock_timestamp(), \
               clock_timestamp() + ($1::double precision * INTERVAL '1 second')",
        )
        .bind(PRESENCE_TTL_SECONDS as f64)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO vault_presence(vault_id,user_id,device_id,session_id,last_seen_at,expires_at) \
             VALUES($1,$2,$3,$4,$5,$6) \
             ON CONFLICT(vault_id,session_id) DO UPDATE SET \
               user_id=EXCLUDED.user_id,device_id=EXCLUDED.device_id, \
               last_seen_at=EXCLUDED.last_seen_at,expires_at=EXCLUDED.expires_at",
        )
        .bind(vault_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.session_id)
        .bind(last_seen_at)
        .bind(expires_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;

        Ok(Json(json!({
            "expires_at": expires_at.to_rfc3339(),
            "ttl_seconds": PRESENCE_TTL_SECONDS,
        })))
    }

    pub(crate) async fn list(
        &self,
        user: &AuthUser,
        vault_id: &str,
    ) -> Result<Json<Value>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        require_active_session_device_read(&mut tx, user).await?;
        require_active_membership(&mut tx, user, vault_id).await?;
        let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let rows = sqlx::query(
            "SELECT p.user_id,p.device_id,p.last_seen_at \
             FROM vault_presence p \
             JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
             JOIN users u ON u.user_id=p.user_id \
             JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
             JOIN sessions s ON s.session_id=p.session_id \
               AND s.user_id=p.user_id AND s.device_id=p.device_id \
             WHERE p.vault_id=$1 AND p.expires_at>$2 \
               AND vm.state='active' AND u.status='active' AND d.status='active' \
               AND s.revoked_at IS NULL AND s.access_expires_at>$2",
        )
        .bind(vault_id)
        .bind(now)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut devices: HashMap<(String, String), DateTime<Utc>> = HashMap::new();
        for row in rows {
            let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
            let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
            let last_seen_at: DateTime<Utc> =
                row.try_get("last_seen_at").map_err(ApiError::internal)?;
            let key = (user_id, device_id);
            if devices
                .get(&key)
                .is_none_or(|existing| last_seen_at > *existing)
            {
                devices.insert(key, last_seen_at);
            }
        }
        tx.commit().await.map_err(ApiError::internal)?;

        let mut entries = devices
            .into_iter()
            .map(|((user_id, device_id), last_seen_at)| {
                json!({
                    "user_id": user_id,
                    "device_id": device_id,
                    "last_seen_at": last_seen_at.to_rfc3339(),
                })
            })
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| {
            left["user_id"]
                .as_str()
                .cmp(&right["user_id"].as_str())
                .then_with(|| left["device_id"].as_str().cmp(&right["device_id"].as_str()))
        });
        Ok(Json(json!({
            "devices": entries,
            "ttl_seconds": PRESENCE_TTL_SECONDS,
        })))
    }

    /// Removes a bounded batch of expired or no-longer-authorized leases and
    /// heartbeat gates. List reads apply their own live-state filters.
    pub(crate) async fn cleanup(&self, batch_limit: i64) -> Result<(), ApiError> {
        if !(1..=10_000).contains(&batch_limit) {
            return Err(ApiError::internal(
                "invalid PostgreSQL presence cleanup batch",
            ));
        }
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query(
            "WITH due AS ( \
               SELECT p.vault_id,p.session_id FROM vault_presence p \
               WHERE p.expires_at<=clock_timestamp() \
                  OR NOT EXISTS (SELECT 1 FROM sessions s \
                     WHERE s.session_id=p.session_id AND s.user_id=p.user_id \
                       AND s.device_id=p.device_id AND s.revoked_at IS NULL \
                       AND s.access_expires_at>clock_timestamp()) \
                  OR NOT EXISTS (SELECT 1 FROM devices d \
                     WHERE d.device_id=p.device_id AND d.user_id=p.user_id AND d.status='active') \
                  OR NOT EXISTS (SELECT 1 FROM users u \
                     WHERE u.user_id=p.user_id AND u.status='active') \
                  OR NOT EXISTS (SELECT 1 FROM vault_members vm \
                     WHERE vm.vault_id=p.vault_id AND vm.user_id=p.user_id AND vm.state='active') \
               ORDER BY p.expires_at,p.vault_id,p.session_id \
               LIMIT $1 FOR UPDATE OF p SKIP LOCKED \
             ) DELETE FROM vault_presence p USING due \
               WHERE p.vault_id=due.vault_id AND p.session_id=due.session_id",
        )
        .bind(batch_limit)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "WITH due AS ( \
               SELECT h.vault_id,h.session_id FROM vault_presence_heartbeat_limits h \
               WHERE h.last_heartbeat_at<=clock_timestamp() - INTERVAL '5 seconds' \
                  OR NOT EXISTS (SELECT 1 FROM sessions s \
                     WHERE s.session_id=h.session_id AND s.revoked_at IS NULL) \
               ORDER BY h.last_heartbeat_at,h.vault_id,h.session_id \
               LIMIT $1 FOR UPDATE OF h SKIP LOCKED \
             ) DELETE FROM vault_presence_heartbeat_limits h USING due \
               WHERE h.vault_id=due.vault_id AND h.session_id=due.session_id",
        )
        .bind(batch_limit)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)
    }
}

async fn has_live_lease(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    session_id: &str,
) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM vault_presence \
         WHERE vault_id=$1 AND session_id=$2 AND expires_at>clock_timestamp())",
    )
    .bind(vault_id)
    .bind(session_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn count_live_leases(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: Option<&str>,
    user_id: Option<&str>,
) -> Result<i64, ApiError> {
    let count: Result<i64, sqlx::Error> =
        if let (Some(vault_id), Some(user_id)) = (vault_id, user_id) {
            sqlx::query_scalar(
                "SELECT COUNT(*) FROM vault_presence p \
             JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
             JOIN users u ON u.user_id=p.user_id \
             JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
             JOIN sessions s ON s.session_id=p.session_id \
               AND s.user_id=p.user_id AND s.device_id=p.device_id \
             WHERE p.vault_id=$1 AND p.user_id=$2 AND p.expires_at>clock_timestamp() \
               AND vm.state='active' AND u.status='active' AND d.status='active' \
               AND s.revoked_at IS NULL AND s.access_expires_at>clock_timestamp()",
            )
            .bind(vault_id)
            .bind(user_id)
            .fetch_one(&mut **tx)
            .await
        } else {
            sqlx::query_scalar(
                "SELECT COUNT(*) FROM vault_presence p \
             JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
             JOIN users u ON u.user_id=p.user_id \
             JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
             JOIN sessions s ON s.session_id=p.session_id \
               AND s.user_id=p.user_id AND s.device_id=p.device_id \
             WHERE p.expires_at>clock_timestamp() AND vm.state='active' \
               AND u.status='active' AND d.status='active' \
               AND s.revoked_at IS NULL AND s.access_expires_at>clock_timestamp()",
            )
            .fetch_one(&mut **tx)
            .await
        };
    count.map_err(ApiError::internal)
}

async fn lock_active_session_device_membership(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    let session = sqlx::query(
        "SELECT revoked_at,access_expires_at>clock_timestamp() AS unexpired \
         FROM sessions WHERE session_id=$1 AND user_id=$2 AND device_id=$3 \
           AND access_hash=$4 FOR SHARE",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    if session
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_some()
        || !session
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let device_status: Option<String> = sqlx::query_scalar(
        "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    let member_state: Option<String> = sqlx::query_scalar(
        "SELECT state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if member_state.as_deref() != Some("active") {
        return Err(ApiError::not_found());
    }
    Ok(())
}

async fn require_active_session_device_read(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT s.revoked_at IS NOT NULL AS revoked, \
           s.access_expires_at>clock_timestamp() AS unexpired, \
           u.status AS account_status,d.status AS device_status \
         FROM sessions s JOIN users u ON u.user_id=s.user_id \
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
    if row
        .try_get::<bool, _>("revoked")
        .map_err(ApiError::internal)?
        || !row
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
        || row
            .try_get::<String, _>("account_status")
            .map_err(ApiError::internal)?
            != "active"
    {
        return Err(ApiError::unauthorized());
    }
    if row
        .try_get::<String, _>("device_status")
        .map_err(ApiError::internal)?
        != "active"
    {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

async fn require_active_membership(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM vaults v \
         JOIN vault_members vm ON vm.vault_id=v.vault_id \
         JOIN users u ON u.user_id=vm.user_id \
         WHERE v.vault_id=$1 AND vm.user_id=$2 \
           AND vm.state='active' AND u.status='active')",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if active {
        Ok(())
    } else {
        Err(ApiError::not_found())
    }
}

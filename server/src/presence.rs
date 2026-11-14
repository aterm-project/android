//! Short-lived, Vault-scoped device presence leases.
//!
//! Presence is operational state only. It never enters encrypted record
//! history or the audit log, and each row expires after a fixed short TTL.

use axum::{
    Json,
    body::Bytes,
    extract::{Path, State},
    http::HeaderMap,
};
use chrono::{DateTime, Duration, Utc};
use serde_json::{Value, json};
use sqlx::Row;
use std::collections::HashMap;

use crate::{ApiError, AppState, auth::AuthUser};

/// Clients renew at 30 seconds; a missed app wake or network gap therefore
/// removes the device from the online list within at most 90 seconds.
pub(crate) const PRESENCE_TTL_SECONDS: i64 = 90;
const MIN_HEARTBEAT_INTERVAL_MILLIS: i64 = 5_000;
const MAX_LIVE_LEASES_PER_USER_VAULT: i64 = 8;
const MAX_LIVE_LEASES_INSTANCE_WIDE: i64 = 100_000;

pub async fn heartbeat(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    body: Bytes,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if !body.is_empty() {
        return Err(ApiError::bad_request(
            "PRESENCE_BODY_NOT_ALLOWED",
            "presence heartbeat does not accept a request body",
        ));
    }
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        return crate::pg_presence::PgPresenceRepository::new(pool.clone())
            .heartbeat(&user, &vault_id)
            .await;
    }

    // The session/device recheck takes SQLite's writer reservation first. The
    // membership check and lease upsert are ordered with logout, refresh,
    // device revocation, membership revocation, and Vault deletion.
    let now = Utc::now();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    require_active_membership(&mut tx, &user, &vault_id).await?;

    let heartbeat_gate = sqlx::query(
        "INSERT INTO vault_presence_heartbeat_limits(vault_id,session_id,last_heartbeat_at) \
         VALUES(?,?,?) \
         ON CONFLICT(vault_id,session_id) DO UPDATE SET \
           last_heartbeat_at=excluded.last_heartbeat_at \
         WHERE vault_presence_heartbeat_limits.last_heartbeat_at<=?",
    )
    .bind(&vault_id)
    .bind(&user.session_id)
    .bind(now.timestamp_millis())
    .bind(
        now.timestamp_millis()
            .saturating_sub(MIN_HEARTBEAT_INTERVAL_MILLIS),
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if heartbeat_gate.rows_affected() == 0 {
        tx.rollback().await.map_err(ApiError::internal)?;
        return Err(ApiError::presence_heartbeat_rate_limited());
    }

    let now_text = now.to_rfc3339();
    let already_leased: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM vault_presence \
         WHERE vault_id=? AND session_id=? AND expires_at>?",
    )
    .bind(&vault_id)
    .bind(&user.session_id)
    .bind(now.timestamp())
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if already_leased == 0 {
        let user_vault_leases: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) \
             FROM vault_presence p \
             JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
             JOIN users u ON u.user_id=p.user_id \
             JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
             JOIN sessions s ON s.session_id=p.session_id \
                 AND s.user_id=p.user_id AND s.device_id=p.device_id \
             WHERE p.vault_id=? AND p.user_id=? AND p.expires_at>? \
               AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active' AND d.status='active' \
               AND s.revoked_at IS NULL AND s.access_expires_at>?",
        )
        .bind(&vault_id)
        .bind(&user.user_id)
        .bind(now.timestamp())
        .bind(&now_text)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let instance_leases: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) \
             FROM vault_presence p \
             JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
             JOIN users u ON u.user_id=p.user_id \
             JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
             JOIN sessions s ON s.session_id=p.session_id \
                 AND s.user_id=p.user_id AND s.device_id=p.device_id \
             WHERE p.expires_at>? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') \
               AND u.status='active' AND d.status='active' \
               AND s.revoked_at IS NULL AND s.access_expires_at>?",
        )
        .bind(now.timestamp())
        .bind(&now_text)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if user_vault_leases >= MAX_LIVE_LEASES_PER_USER_VAULT
            || instance_leases >= MAX_LIVE_LEASES_INSTANCE_WIDE
        {
            // Commit the rate gate even when capacity rejects this new lease,
            // so repeated overflow requests cannot bypass the write bound.
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::conflict(
                "PRESENCE_LEASE_LIMIT",
                "temporary presence lease capacity is full",
            ));
        }
    }

    let last_seen_at = now.to_rfc3339();
    let expires_at = now + Duration::seconds(PRESENCE_TTL_SECONDS);
    sqlx::query(
        "INSERT INTO vault_presence(vault_id,user_id,device_id,session_id,last_seen_at,expires_at) \
         VALUES(?,?,?,?,?,?) \
         ON CONFLICT(vault_id,session_id) DO UPDATE SET \
           user_id=excluded.user_id,device_id=excluded.device_id, \
           last_seen_at=excluded.last_seen_at,expires_at=excluded.expires_at",
    )
    .bind(&vault_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.session_id)
    .bind(&last_seen_at)
    .bind(expires_at.timestamp())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "expires_at": expires_at.to_rfc3339(),
        "ttl_seconds": PRESENCE_TTL_SECONDS,
    })))
}

/// Reclaims expired or no-longer-authorized operational rows during the
/// existing hourly/startup maintenance pass. List reads always apply the TTL
/// predicate independently and never wait for this physical cleanup.
pub(crate) async fn cleanup(state: &AppState, now_epoch: i64) -> Result<(), ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query(
        "DELETE FROM vault_presence AS p \
         WHERE p.expires_at<=? \
            OR NOT EXISTS ( \
               SELECT 1 FROM sessions s \
               WHERE s.session_id=p.session_id AND s.user_id=p.user_id \
                 AND s.device_id=p.device_id AND s.revoked_at IS NULL \
            ) \
            OR NOT EXISTS ( \
               SELECT 1 FROM devices d \
               WHERE d.device_id=p.device_id AND d.user_id=p.user_id \
                 AND d.status='active' \
            ) \
            OR NOT EXISTS ( \
               SELECT 1 FROM users u \
               WHERE u.user_id=p.user_id AND u.status='active' \
            ) \
            OR NOT EXISTS ( \
               SELECT 1 FROM vault_members vm \
               WHERE vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
                 AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') \
            )",
    )
    .bind(now_epoch)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    sqlx::query(
        "DELETE FROM vault_presence_heartbeat_limits \
         WHERE last_heartbeat_at<=? OR NOT EXISTS ( \
             SELECT 1 FROM sessions s \
             WHERE s.session_id=vault_presence_heartbeat_limits.session_id \
               AND s.revoked_at IS NULL \
         )",
    )
    // Maintenance timestamps are seconds; the rate gate stores milliseconds.
    .bind(
        now_epoch
            .saturating_mul(1_000)
            .saturating_sub(MIN_HEARTBEAT_INTERVAL_MILLIS),
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)
}

pub async fn list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        return crate::pg_presence::PgPresenceRepository::new(pool.clone())
            .list(&user, &vault_id)
            .await;
    }
    // Both checks and the lease read share one read snapshot. No member or
    // device principal is accepted from the caller.
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::require_vault_read_snapshot_tx(&mut tx, &user.user_id, &vault_id).await?;

    let now = Utc::now();
    let rows = sqlx::query(
        "SELECT p.user_id,p.device_id,p.last_seen_at,s.access_expires_at \
         FROM vault_presence p \
         JOIN vault_members vm ON vm.vault_id=p.vault_id AND vm.user_id=p.user_id \
         JOIN users u ON u.user_id=p.user_id \
         JOIN devices d ON d.device_id=p.device_id AND d.user_id=p.user_id \
         JOIN sessions s ON s.session_id=p.session_id \
             AND s.user_id=p.user_id AND s.device_id=p.device_id \
         WHERE p.vault_id=? AND p.expires_at>? \
           AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active' AND d.status='active' \
           AND s.revoked_at IS NULL",
    )
    .bind(&vault_id)
    .bind(now.timestamp())
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    // A device can have more than one active session (for example, parallel
    // profiles). Keep each session's lease independent in storage, but return
    // one minimal row per currently-online member device.
    let mut devices: HashMap<(String, String), (DateTime<Utc>, String)> = HashMap::new();
    for row in rows {
        let session_expiry: String = row.get("access_expires_at");
        if DateTime::parse_from_rfc3339(&session_expiry)
            .map(|expiry| expiry.with_timezone(&Utc) <= now)
            .unwrap_or(true)
        {
            continue;
        }
        let Some(last_seen) = DateTime::parse_from_rfc3339(&row.get::<String, _>("last_seen_at"))
            .ok()
            .map(|value| value.with_timezone(&Utc))
        else {
            continue;
        };
        let user_id: String = row.get("user_id");
        let device_id: String = row.get("device_id");
        let key = (user_id, device_id);
        let formatted = last_seen.to_rfc3339();
        if devices
            .get(&key)
            .is_none_or(|(existing, _)| last_seen > *existing)
        {
            devices.insert(key, (last_seen, formatted));
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;

    let mut entries = devices
        .into_iter()
        .map(|((user_id, device_id), (_, last_seen_at))| {
            json!({
                "user_id": user_id,
                "device_id": device_id,
                "last_seen_at": last_seen_at,
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

async fn require_active_membership(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    let active: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM vaults v \
         JOIN vault_members vm ON vm.vault_id=v.vault_id \
         JOIN users u ON u.user_id=vm.user_id \
         WHERE v.vault_id=? AND vm.user_id=? \
           AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active'",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if active.is_some() {
        Ok(())
    } else {
        Err(ApiError::not_found())
    }
}

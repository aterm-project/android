//! PostgreSQL-backed, aggregate-only instance administrator overview.
//!
//! This read exposes the same small operational DTO as SQLite and never
//! includes account identity, Vault names, or encrypted client data.

use axum::Json;
use chrono::{SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::Row;

use crate::{ApiError, AppState, auth::AuthUser};

pub(crate) async fn overview(state: &AppState, user: &AuthUser) -> Result<Json<Value>, ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL runtime pool is unavailable"))?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(
        &mut tx,
        state,
        user,
        &state.config.admin_usernames,
    )
    .await?;

    let (generated_at,): (chrono::DateTime<Utc>,) = sqlx::query_as("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let relay = crate::pg_relay::overview_tx(&mut tx, state).await?;
    let counts = sqlx::query(
        "SELECT \
         (SELECT COUNT(*) FROM users) AS accounts_total, \
         (SELECT COUNT(*) FROM users WHERE status='active') AS accounts_active, \
         (SELECT COUNT(*) FROM users WHERE status='deleting') AS accounts_deleting, \
         (SELECT COUNT(*) FROM users WHERE status='disabled') AS accounts_disabled, \
         (SELECT COUNT(*) FROM devices d JOIN users u ON u.user_id=d.user_id \
          WHERE d.status='active' AND u.status='active') AS devices_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='active') AS vaults_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='deleting') AS vaults_deleting, \
         (SELECT COALESCE(SUM(size),0)::BIGINT FROM blob_objects) AS stored_bytes, \
         (SELECT COALESCE(SUM(expected_size),0)::BIGINT FROM uploads \
          WHERE state='open' AND expires_at>$1) AS reserved_upload_bytes, \
         (SELECT COALESCE(SUM(quota_bytes),0)::BIGINT FROM vaults \
          WHERE state IN ('active','deleting')) AS vault_quota_bytes",
    )
    .bind(&generated_at)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let response = json!({
        "instance": {
            "instance_id": state.instance.instance_id.clone(),
            "server_space_id": state.instance.server_space_id.clone(),
            "generation": state.instance.generation.clone(),
            "protocol_version": 1,
        },
        "counts": {
            "accounts_total": counts.get::<i64, _>("accounts_total"),
            "accounts_active": counts.get::<i64, _>("accounts_active"),
            "accounts_deleting": counts.get::<i64, _>("accounts_deleting"),
            "accounts_disabled": counts.get::<i64, _>("accounts_disabled"),
            "devices_active": counts.get::<i64, _>("devices_active"),
            "vaults_active": counts.get::<i64, _>("vaults_active"),
            "vaults_deleting": counts.get::<i64, _>("vaults_deleting"),
            "stored_bytes": counts.get::<i64, _>("stored_bytes"),
            "reserved_upload_bytes": counts.get::<i64, _>("reserved_upload_bytes"),
            "vault_quota_bytes": counts.get::<i64, _>("vault_quota_bytes"),
        },
        "relay": relay,
        // Node-local SQLite store only; PostgreSQL relies on storage-level
        // encryption (see docs/runbooks/database-encryption.md).
        "database_encryption": state.database_encryption.as_str(),
        "generated_at": generated_at.to_rfc3339_opts(SecondsFormat::Millis, true),
    });
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

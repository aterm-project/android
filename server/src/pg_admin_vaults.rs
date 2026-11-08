//! PostgreSQL instance-admin Vault inventory and quota management.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction};

use crate::{ApiError, AppState, auth::AuthUser};

const PAGE_LIMIT_MAX: i64 = 100;
const PAGE_OFFSET_MAX: i64 = 1_000_000;

pub(crate) async fn list_vaults(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    limit: i64,
    offset: i64,
) -> Result<Value, ApiError> {
    validate_page(limit, offset)?;
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let total: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM vaults WHERE state IN ('active','deleting')")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT v.vault_id,v.owner_user_id,u.username AS owner_username,v.state, \
         COALESCE((SELECT SUM(b.size) FROM blob_objects b WHERE b.vault_id=v.vault_id),0)::text AS stored_bytes, \
         COALESCE((SELECT SUM(up.expected_size) FROM uploads up WHERE up.vault_id=v.vault_id \
                   AND up.state IN ('open','completing') AND up.expires_at>$1),0)::text AS reserved_upload_bytes, \
         v.quota_bytes,v.created_at \
         FROM vaults v JOIN users u ON u.user_id=v.owner_user_id \
         WHERE v.state IN ('active','deleting') \
         ORDER BY v.created_at DESC,v.vault_id ASC LIMIT $2 OFFSET $3",
    )
    .bind(now)
    .bind(limit)
    .bind(offset)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let vaults = rows
        .into_iter()
        .map(|row| {
            let created_at: DateTime<Utc> = row.try_get("created_at").map_err(ApiError::internal)?;
            Ok(json!({
                "vault_id": row.try_get::<String, _>("vault_id").map_err(ApiError::internal)?,
                "owner_user_id": row.try_get::<String, _>("owner_user_id").map_err(ApiError::internal)?,
                "owner_username": row.try_get::<String, _>("owner_username").map_err(ApiError::internal)?,
                "state": row.try_get::<String, _>("state").map_err(ApiError::internal)?,
                "stored_bytes": bounded_usage(&row, "stored_bytes")?,
                "reserved_upload_bytes": bounded_usage(&row, "reserved_upload_bytes")?,
                "quota_bytes": row.try_get::<i64, _>("quota_bytes").map_err(ApiError::internal)?,
                "created_at": format_timestamp(created_at),
            }))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({"vaults": vaults, "total": total, "limit": limit, "offset": offset}))
}

pub(crate) async fn update_vault_quota(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    vault_id: &str,
    requested_quota_bytes: i64,
) -> Result<Value, ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;

    // Object upload initialization, completion, and collection use the same
    // Vault row lock before changing reservation or blob usage. Holding it
    // through the quota check prevents a concurrent reservation from making
    // the new limit smaller than committed plus in-flight storage.
    let vault = sqlx::query("SELECT state,quota_bytes FROM vaults WHERE vault_id=$1 FOR UPDATE")
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let state_name: String = vault.try_get("state").map_err(ApiError::internal)?;
    if state_name != "active" {
        return Err(ApiError::conflict(
            "VAULT_NOT_ACTIVE",
            "quota can only be changed for an active vault",
        ));
    }

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let usage = sqlx::query(
        "SELECT \
           COALESCE((SELECT SUM(size) FROM blob_objects WHERE vault_id=$1),0)::text AS stored_bytes, \
           COALESCE((SELECT SUM(expected_size) FROM uploads WHERE vault_id=$1 \
                     AND state IN ('open','completing') AND expires_at>$2),0)::text AS reserved_upload_bytes",
    )
    .bind(vault_id)
    .bind(now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let stored_bytes = bounded_usage(&usage, "stored_bytes")?;
    let reserved_upload_bytes = bounded_usage(&usage, "reserved_upload_bytes")?;
    let used_bytes = stored_bytes.saturating_add(reserved_upload_bytes);
    if requested_quota_bytes < used_bytes {
        return Err(ApiError::conflict(
            "QUOTA_BELOW_USAGE",
            "quota_bytes cannot be lower than completed and reserved storage",
        )
        .with_details(json!({
            "stored_bytes": stored_bytes,
            "reserved_upload_bytes": reserved_upload_bytes,
            "used_bytes": used_bytes,
            "requested_quota_bytes": requested_quota_bytes,
        })));
    }

    let previous_quota: i64 = vault.try_get("quota_bytes").map_err(ApiError::internal)?;
    if previous_quota != requested_quota_bytes {
        let updated =
            sqlx::query("UPDATE vaults SET quota_bytes=$2 WHERE vault_id=$1 AND state='active'")
                .bind(vault_id)
                .bind(requested_quota_bytes)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "VAULT_NOT_ACTIVE",
                "quota can only be changed for an active vault",
            ));
        }
    }

    record_vault_quota_event_tx(&mut tx, state, user, vault_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "vault_id": vault_id,
        "quota_bytes": requested_quota_bytes,
        "stored_bytes": stored_bytes,
        "reserved_upload_bytes": reserved_upload_bytes,
        "updated_at": format_timestamp(now),
    }))
}

async fn record_vault_quota_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    actor: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = crate::audit::instance_resource_id(&state.cursor_key, "vault", vault_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type, \
             resource_id,result,occurred_at,source \
         ) VALUES('instance',$1,$2,$3,'admin.vault_quota_set','vault',$4,'success',$5,'api')",
    )
    .bind(scope_id)
    .bind(&actor.user_id)
    .bind(&actor.device_id)
    .bind(resource_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn bounded_usage(row: &sqlx::postgres::PgRow, column: &str) -> Result<i64, ApiError> {
    let value: String = row.try_get(column).map_err(ApiError::internal)?;
    let parsed = value
        .parse::<i128>()
        .map_err(|_| ApiError::internal("Vault storage usage is malformed"))?;
    i64::try_from(parsed)
        .map_err(|_| ApiError::internal("Vault storage usage exceeds the API integer range"))
}

fn validate_page(limit: i64, offset: i64) -> Result<(), ApiError> {
    if !(1..=PAGE_LIMIT_MAX).contains(&limit) || !(0..=PAGE_OFFSET_MAX).contains(&offset) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "Vault pagination is outside the supported range",
        ));
    }
    Ok(())
}

fn pg_pool(state: &AppState) -> Result<&sqlx::PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL runtime pool is unavailable"))
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use super::validate_page;

    #[test]
    fn pagination_is_bounded() {
        assert!(validate_page(1, 0).is_ok());
        assert!(validate_page(100, 1_000_000).is_ok());
        assert!(validate_page(0, 0).is_err());
        assert!(validate_page(101, 0).is_err());
        assert!(validate_page(1, -1).is_err());
        assert!(validate_page(1, 1_000_001).is_err());
    }
}

//! PostgreSQL instance-admin account/session lists and lifecycle operations.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction};

use crate::{ApiError, AppState, auth::AuthUser, pg_notifications::notify_sync_wake};

const PAGE_LIMIT_MAX: i64 = 100;
const PAGE_OFFSET_MAX: i64 = 1_000_000;
const ADMIN_ACCOUNT_WRITE_LOCK_NAMESPACE: i32 = 0x4154_4144;

pub(crate) async fn list_accounts(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    limit: i64,
    offset: i64,
) -> Result<Value, ApiError> {
    validate_page(limit, offset)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    begin_admin_read(&mut tx, state, user, admin_usernames).await?;

    let (now,): (DateTime<Utc>,) = sqlx::query_as("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT u.user_id,u.username,u.status,u.created_at, \
         (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.user_id AND d.status='active') AS active_device_count, \
         (SELECT COUNT(*) FROM sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL \
          AND s.refresh_expires_at>$1 AND u.status='active' \
          AND EXISTS(SELECT 1 FROM devices sd WHERE sd.device_id=s.device_id AND sd.status='active')) \
          AS active_session_count \
         FROM users u ORDER BY u.created_at DESC,u.user_id ASC LIMIT $2 OFFSET $3",
    )
    .bind(now)
    .bind(limit)
    .bind(offset)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let accounts = rows
        .into_iter()
        .map(|row| {
            let created_at: DateTime<Utc> = row.get("created_at");
            json!({
                "user_id": row.get::<String, _>("user_id"),
                "username": row.get::<String, _>("username"),
                "status": row.get::<String, _>("status"),
                "created_at": format_timestamp(created_at),
                "active_device_count": row.get::<i64, _>("active_device_count"),
                "active_session_count": row.get::<i64, _>("active_session_count"),
            })
        })
        .collect::<Vec<_>>();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({"accounts": accounts, "total": total, "limit": limit, "offset": offset}))
}

pub(crate) async fn list_account_sessions(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    user_id: &str,
    limit: i64,
    offset: i64,
) -> Result<Value, ApiError> {
    validate_page(limit, offset)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    begin_admin_read(&mut tx, state, user, admin_usernames).await?;

    let account_exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$1)")
            .bind(user_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if !account_exists {
        return Err(ApiError::not_found());
    }
    let (now,): (DateTime<Utc>,) = sqlx::query_as("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions WHERE user_id=$1")
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT s.session_id,s.device_id,d.name AS device_name,s.created_at, \
         s.access_expires_at,s.refresh_expires_at,s.revoked_at, \
         d.status AS device_status,u.status AS account_status \
         FROM sessions s JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         JOIN users u ON u.user_id=s.user_id WHERE s.user_id=$1 \
         ORDER BY s.created_at DESC,s.session_id ASC LIMIT $2 OFFSET $3",
    )
    .bind(user_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let sessions = rows
        .into_iter()
        .map(|row| {
            let created_at: DateTime<Utc> = row.get("created_at");
            let access_expires_at: DateTime<Utc> = row.get("access_expires_at");
            let refresh_expires_at: DateTime<Utc> = row.get("refresh_expires_at");
            let revoked_at: Option<DateTime<Utc>> = row.get("revoked_at");
            let device_status: String = row.get("device_status");
            let account_status: String = row.get("account_status");
            let active = revoked_at.is_none()
                && refresh_expires_at > now
                && device_status == "active"
                && account_status == "active";
            json!({
                "session_id": row.get::<String, _>("session_id"),
                "device_id": row.get::<String, _>("device_id"),
                "device_name": row.get::<String, _>("device_name"),
                "created_at": format_timestamp(created_at),
                "access_expires_at": format_timestamp(access_expires_at),
                "refresh_expires_at": format_timestamp(refresh_expires_at),
                "revoked_at": revoked_at.map(format_timestamp),
                "active": active,
            })
        })
        .collect::<Vec<_>>();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({"sessions": sessions, "total": total, "limit": limit, "offset": offset}))
}

pub(crate) async fn update_account_status(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    target_user_id: &str,
    desired_status: &str,
) -> Result<Value, ApiError> {
    if !matches!(desired_status, "active" | "disabled") {
        return Err(ApiError::bad_request(
            "INVALID_ACCOUNT_STATUS",
            "status must be 'active' or 'disabled'",
        ));
    }
    reject_self_target(user, target_user_id)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    begin_admin_write(&mut tx, state, user, admin_usernames).await?;
    crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, target_user_id).await?;
    lock_target_sessions(&mut tx, target_user_id).await?;
    let target: Option<(String, String)> =
        sqlx::query_as("SELECT status,username FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(target_user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let Some((current_status, target_username)) = target else {
        return Err(ApiError::not_found());
    };
    if current_status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "a deleting account cannot be changed by instance administration",
        ));
    }
    if !matches!(current_status.as_str(), "active" | "disabled") {
        return Err(ApiError::conflict(
            "ACCOUNT_STATUS_UNSUPPORTED",
            "account status cannot be changed by instance administration",
        ));
    }
    let changed = current_status != desired_status;
    if changed
        && desired_status == "disabled"
        && state.config.is_instance_admin(&target_username)
        && active_admin_count_tx(&mut tx, state).await? <= 1
    {
        return Err(ApiError::conflict(
            "LAST_INSTANCE_ADMIN",
            "the last active instance administrator cannot be disabled",
        ));
    }
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let revoked_sessions = if changed && desired_status == "disabled" {
        sqlx::query("UPDATE sessions SET revoked_at=$1 WHERE user_id=$2 AND revoked_at IS NULL")
            .bind(now)
            .bind(target_user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .rows_affected()
    } else {
        0
    };
    if changed {
        let updated = sqlx::query("UPDATE users SET status=$1 WHERE user_id=$2 AND status=$3")
            .bind(desired_status)
            .bind(target_user_id)
            .bind(&current_status)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "ACCOUNT_STATUS_TRANSITION_CONFLICT",
                "account lifecycle changed; retry the request",
            ));
        }
        let action = if desired_status == "active" {
            "admin.account_enabled"
        } else {
            "admin.account_disabled"
        };
        record_admin_account_event_tx(&mut tx, state, user, action, target_user_id).await?;
        // A status transition changes the authorization snapshot for every
        // live socket bound to this account. Queue the instance-wide wake in
        // the same transaction so peers revalidate only after commit.
        notify_sync_wake(&mut tx).await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "account_id": target_user_id,
        "status": desired_status,
        "revoked_sessions": revoked_sessions,
        "changed": changed,
        "updated_at": format_timestamp(now),
    }))
}

pub(crate) async fn revoke_account_sessions(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    target_user_id: &str,
) -> Result<Value, ApiError> {
    reject_self_target(user, target_user_id)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    begin_admin_write(&mut tx, state, user, admin_usernames).await?;
    crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, target_user_id).await?;
    lock_target_sessions(&mut tx, target_user_id).await?;
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(target_user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let Some(status) = status else {
        return Err(ApiError::not_found());
    };
    if status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "sessions for a deleting account are already revoked",
        ));
    }
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let revoked_sessions =
        sqlx::query("UPDATE sessions SET revoked_at=$1 WHERE user_id=$2 AND revoked_at IS NULL")
            .bind(now)
            .bind(target_user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .rows_affected();
    if revoked_sessions > 0 {
        record_admin_account_event_tx(
            &mut tx,
            state,
            user,
            "admin.account_sessions_revoked",
            target_user_id,
        )
        .await?;
        notify_sync_wake(&mut tx).await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "account_id": target_user_id,
        "revoked_sessions": revoked_sessions,
        "updated_at": format_timestamp(now),
    }))
}

pub(crate) async fn revoke_account_session(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    target_user_id: &str,
    target_session_id: &str,
) -> Result<Value, ApiError> {
    reject_self_target(user, target_user_id)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    begin_admin_write(&mut tx, state, user, admin_usernames).await?;
    crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, target_user_id).await?;
    let sessions = lock_target_sessions(&mut tx, target_user_id).await?;
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(target_user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let Some(status) = status else {
        return Err(ApiError::not_found());
    };
    if status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "sessions for a deleting account are already revoked",
        ));
    }
    let target_session = sessions.iter().find(|row| {
        row.try_get::<String, _>("session_id")
            .is_ok_and(|session_id| session_id == target_session_id)
    });
    let Some(target_session) = target_session else {
        return Err(ApiError::not_found());
    };
    let already_revoked: Option<DateTime<Utc>> = target_session
        .try_get("revoked_at")
        .map_err(ApiError::internal)?;
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let changed = if already_revoked.is_none() {
        sqlx::query(
            "UPDATE sessions SET revoked_at=$1 WHERE session_id=$2 AND user_id=$3 AND revoked_at IS NULL",
        )
        .bind(now)
        .bind(target_session_id)
        .bind(target_user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected()
            == 1
    } else {
        false
    };
    if changed {
        record_admin_account_event_tx(
            &mut tx,
            state,
            user,
            "admin.account_session_revoked",
            target_user_id,
        )
        .await?;
        notify_sync_wake(&mut tx).await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "account_id": target_user_id,
        "session_id": target_session_id,
        "revoked": true,
        "changed": changed,
        "updated_at": format_timestamp(now),
    }))
}

async fn begin_admin_write(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<(), ApiError> {
    // Serialize admin account writes so concurrent disables cannot each
    // observe the other administrator as the last remaining admin.
    sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
        .bind(ADMIN_ACCOUNT_WRITE_LOCK_NAMESPACE)
        .bind(1_i32)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(tx, state, user, admin_usernames).await
}

async fn lock_target_sessions(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<Vec<sqlx::postgres::PgRow>, ApiError> {
    sqlx::query(
        "SELECT session_id,revoked_at FROM sessions WHERE user_id=$1 ORDER BY session_id FOR UPDATE",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn active_admin_count_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
) -> Result<usize, ApiError> {
    let usernames: Vec<String> = sqlx::query_scalar(
        "SELECT username FROM users WHERE status='active' ORDER BY user_id FOR SHARE",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(usernames
        .iter()
        .filter(|username| state.config.is_instance_admin(username))
        .count())
}

async fn record_admin_account_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    actor: &AuthUser,
    action: &str,
    target_user_id: &str,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id =
        crate::audit::instance_resource_id(&state.cursor_key, "account", target_user_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type, \
             resource_id,result,occurred_at,source \
         ) VALUES('instance',$1,$2,$3,$4,'account',$5,'success',$6,'api')",
    )
    .bind(scope_id)
    .bind(&actor.user_id)
    .bind(&actor.device_id)
    .bind(action)
    .bind(resource_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn reject_self_target(user: &AuthUser, target_user_id: &str) -> Result<(), ApiError> {
    if user.user_id == target_user_id {
        return Err(ApiError::conflict(
            "ADMIN_SELF_TARGET",
            "instance administrators cannot change their own account or sessions",
        ));
    }
    Ok(())
}

async fn begin_admin_read(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<(), ApiError> {
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(tx, state, user, admin_usernames).await
}

fn validate_page(limit: i64, offset: i64) -> Result<(), ApiError> {
    if !(1..=PAGE_LIMIT_MAX).contains(&limit) || !(0..=PAGE_OFFSET_MAX).contains(&offset) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "account pagination is outside the supported range",
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
    use super::{format_timestamp, validate_page};
    use chrono::{TimeZone, Utc};

    #[test]
    fn pagination_matches_bounded_admin_contract() {
        assert!(validate_page(1, 0).is_ok());
        assert!(validate_page(100, 1_000_000).is_ok());
        assert!(validate_page(0, 0).is_err());
        assert!(validate_page(101, 0).is_err());
        assert!(validate_page(1, -1).is_err());
        assert!(validate_page(1, 1_000_001).is_err());
    }

    #[test]
    fn timestamps_match_rfc3339_millisecond_wire_format() {
        let timestamp = Utc.with_ymd_and_hms(2026, 10, 9, 12, 13, 14).unwrap();
        assert_eq!(format_timestamp(timestamp), "2026-10-09T12:13:14.000Z");
    }
}

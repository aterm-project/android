//! PostgreSQL instance-admin account invitation management.
//!
//! Invitation mutations share the singleton `instance_meta` row lock with
//! registration and CLI invitation issuance. This makes consume, revoke, and
//! reissue mutually ordered across service nodes while the admin session and
//! allowlist are revalidated in the same transaction.

use chrono::{DateTime, Duration, SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, AppState, auth, auth::AuthUser};

const PAGE_LIMIT_MAX: i64 = 100;
const PAGE_OFFSET_MAX: i64 = 1_000_000;

pub(crate) async fn list_account_invitations(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    limit: i64,
    offset: i64,
) -> Result<Value, ApiError> {
    validate_page(limit, offset)?;
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_invitations")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT invitation_id,username,created_at,expires_at,consumed_at,revoked_at \
         FROM account_invitations \
         ORDER BY created_at DESC,invitation_id DESC LIMIT $1 OFFSET $2",
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let invitations = rows
        .into_iter()
        .map(|row| invitation_dto(&row, now))
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "invitations": invitations,
        "total": total,
        "limit": limit,
        "offset": offset,
    }))
}

pub(crate) async fn create_account_invitation(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    username: &str,
    lifetime_seconds: i64,
) -> Result<Value, ApiError> {
    if !(auth::ACCOUNT_INVITATION_MIN_SECONDS..=auth::ACCOUNT_INVITATION_MAX_SECONDS)
        .contains(&lifetime_seconds)
    {
        return Err(ApiError::bad_request(
            "INVALID_INVITATION_TTL",
            "account invitation lifetime must be between 60 and 2592000 seconds",
        ));
    }

    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    let metadata = lock_instance_meta(&mut tx).await?;
    let setup_consumed_at: Option<DateTime<Utc>> = metadata
        .try_get("setup_consumed_at")
        .map_err(ApiError::internal)?;
    let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if users == 0 || setup_consumed_at.is_none() {
        return Err(ApiError::conflict(
            "SETUP_REQUIRED",
            "complete initial bootstrap before issuing account invitations",
        ));
    }

    let username_exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE username=$1)")
            .bind(username)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if username_exists {
        return Err(ApiError::conflict(
            "USERNAME_TAKEN",
            "an account with this username already exists",
        ));
    }

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let expires_at = now + Duration::seconds(lifetime_seconds);
    let superseded = sqlx::query(
        "UPDATE account_invitations SET revoked_at=$1 \
         WHERE username=$2 AND consumed_at IS NULL AND revoked_at IS NULL \
           AND expires_at>$1 RETURNING invitation_id",
    )
    .bind(now)
    .bind(username)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let superseded_ids = superseded
        .into_iter()
        .map(|row| row.try_get::<String, _>("invitation_id"))
        .collect::<Result<Vec<_>, _>>()
        .map_err(ApiError::internal)?;

    let token = auth::random_token();
    let token_hash = crate::sha256_hex(token.as_bytes());
    let invitation_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO account_invitations(invitation_id,token_hash,username,created_at,expires_at) \
         VALUES($1,$2,$3,$4,$5)",
    )
    .bind(&invitation_id)
    .bind(token_hash)
    .bind(username)
    .bind(now)
    .bind(expires_at)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    // Audit writes are deliberately last: the audit first-page reader takes
    // a table SHARE lock, so no domain row may be locked after the first event.
    for superseded_id in superseded_ids {
        record_invitation_event_tx(
            &mut tx,
            state,
            user,
            "instance.account_invitation_revoked",
            &superseded_id,
        )
        .await?;
    }
    record_invitation_event_tx(
        &mut tx,
        state,
        user,
        "instance.account_invitation_issued",
        &invitation_id,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;

    Ok(json!({
        "invitation": {
            "invitation_id": invitation_id,
            "username": username,
            "created_at": format_timestamp(now),
            "expires_at": format_timestamp(expires_at),
            "token": token,
        }
    }))
}

pub(crate) async fn revoke_account_invitation(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    invitation_id: &str,
) -> Result<Value, ApiError> {
    let mut tx = pg_pool(state)?.begin().await.map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    let _metadata = lock_instance_meta(&mut tx).await?;
    let row = sqlx::query(
        "SELECT expires_at,consumed_at,revoked_at FROM account_invitations \
         WHERE invitation_id=$1 FOR UPDATE",
    )
    .bind(invitation_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let expires_at: DateTime<Utc> = row.try_get("expires_at").map_err(ApiError::internal)?;
    let consumed_at: Option<DateTime<Utc>> =
        row.try_get("consumed_at").map_err(ApiError::internal)?;
    let revoked_at: Option<DateTime<Utc>> =
        row.try_get("revoked_at").map_err(ApiError::internal)?;
    if let Some(revoked_at) = revoked_at {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(json!({
            "invitation_id": invitation_id,
            "status": "revoked",
            "revoked_at": format_timestamp(revoked_at),
        }));
    }

    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if consumed_at.is_some() || expires_at <= now {
        return Err(ApiError::conflict(
            "ACCOUNT_INVITATION_NOT_PENDING",
            "only a pending account invitation can be revoked",
        ));
    }
    let updated = sqlx::query(
        "UPDATE account_invitations SET revoked_at=$1 \
         WHERE invitation_id=$2 AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>$1",
    )
    .bind(now)
    .bind(invitation_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "ACCOUNT_INVITATION_NOT_PENDING",
            "only a pending account invitation can be revoked",
        ));
    }
    record_invitation_event_tx(
        &mut tx,
        state,
        user,
        "instance.account_invitation_revoked",
        invitation_id,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({
        "invitation_id": invitation_id,
        "status": "revoked",
        "revoked_at": format_timestamp(now),
    }))
}

async fn lock_instance_meta(
    tx: &mut Transaction<'_, Postgres>,
) -> Result<sqlx::postgres::PgRow, ApiError> {
    sqlx::query("SELECT setup_consumed_at FROM instance_meta WHERE id=1 FOR UPDATE")
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("PostgreSQL instance metadata is missing"))
}

async fn record_invitation_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user: &AuthUser,
    action: &str,
    invitation_id: &str,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id =
        crate::audit::instance_resource_id(&state.cursor_key, "account_invitation", invitation_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type, \
             resource_id,result,occurred_at,source \
         ) VALUES('instance',$1,$2,$3,$4,'account_invitation',$5,'success',$6,'api')",
    )
    .bind(scope_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(action)
    .bind(resource_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn invitation_dto(row: &sqlx::postgres::PgRow, now: DateTime<Utc>) -> Result<Value, ApiError> {
    let invitation_id: String = row.try_get("invitation_id").map_err(ApiError::internal)?;
    let username: String = row.try_get("username").map_err(ApiError::internal)?;
    let created_at: DateTime<Utc> = row.try_get("created_at").map_err(ApiError::internal)?;
    let expires_at: DateTime<Utc> = row.try_get("expires_at").map_err(ApiError::internal)?;
    let consumed_at: Option<DateTime<Utc>> =
        row.try_get("consumed_at").map_err(ApiError::internal)?;
    let revoked_at: Option<DateTime<Utc>> =
        row.try_get("revoked_at").map_err(ApiError::internal)?;
    let status = if consumed_at.is_some() {
        "consumed"
    } else if revoked_at.is_some() {
        "revoked"
    } else if expires_at <= now {
        "expired"
    } else {
        "pending"
    };
    Ok(json!({
        "invitation_id": invitation_id,
        "username": username,
        "created_at": format_timestamp(created_at),
        "expires_at": format_timestamp(expires_at),
        "status": status,
    }))
}

fn validate_page(limit: i64, offset: i64) -> Result<(), ApiError> {
    if !(1..=PAGE_LIMIT_MAX).contains(&limit) || !(0..=PAGE_OFFSET_MAX).contains(&offset) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "account invitation pagination is outside the supported range",
        ));
    }
    Ok(())
}

fn pg_pool(state: &AppState) -> Result<&PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL admin invitation repository is unavailable"))
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::Millis, true)
}

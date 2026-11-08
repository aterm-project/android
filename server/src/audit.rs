use crate::{ApiError, AppState, admin, auth, current_user};
use axum::{
    Json,
    extract::{Query, State},
    http::HeaderMap,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, Sqlite};

type HmacSha256 = Hmac<Sha256>;
const DEFAULT_PAGE_SIZE: u32 = 100;
const MAX_PAGE_SIZE: u32 = 200;
const CURSOR_DOMAIN: &[u8] = b"atermius/audit-cursor/v1\0";
const ACCOUNT_SCOPE_DOMAIN: &[u8] = b"atermius/audit-account-scope/v1\0";
const ADMIN_AUDIT_REQUESTER_DOMAIN: &[u8] = b"atermius/audit-admin-requester-scope/v1\0";
const INSTANCE_SCOPE_DOMAIN: &[u8] = b"atermius/audit-instance-scope/v1\0";
const INSTANCE_RESOURCE_DOMAIN: &[u8] = b"atermius/audit-instance-resource/v1\0";

#[derive(Debug, Clone, Deserialize)]
pub struct AuditQuery {
    pub cursor: Option<String>,
    pub limit: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub(crate) struct AuditCursor {
    pub(crate) version: u8,
    pub(crate) requester_scope: String,
    pub(crate) server_generation: String,
    pub(crate) high_watermark: i64,
    pub(crate) after_event_id: i64,
}

#[derive(Debug, Clone, Copy)]
pub(crate) enum AuditSource {
    Api,
    Maintenance,
}

#[derive(Debug, Clone, Copy)]
enum AuditResult {
    Success,
    Failure,
}

impl AuditResult {
    fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Failure => "failure",
        }
    }
}

impl AuditSource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Api => "api",
            Self::Maintenance => "maintenance",
        }
    }
}

pub(crate) async fn record_account_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    account_id: &str,
    actor_device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: AuditSource,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = account_scope_id(&state.cursor_key, account_id)?;
    record_event_tx(
        tx,
        "account",
        &scope_id,
        Some(account_id),
        actor_device_id,
        action,
        resource_type,
        resource_id,
        source,
        occurred_at,
        AuditResult::Success,
    )
    .await
}

pub(crate) async fn record_account_failure_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    account_id: &str,
    actor_device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: AuditSource,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = account_scope_id(&state.cursor_key, account_id)?;
    record_event_tx(
        tx,
        "account",
        &scope_id,
        Some(account_id),
        actor_device_id,
        action,
        resource_type,
        resource_id,
        source,
        occurred_at,
        AuditResult::Failure,
    )
    .await
}

/// Records an attributable failed login without storing the submitted username,
/// verifier, or device ID. Only an account HMAC scope is retained; failed
/// attempts never claim an actor because the request has not authenticated.
pub(crate) async fn record_failed_login_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    account_id: &str,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = account_scope_id(&state.cursor_key, account_id)?;
    record_event_tx(
        tx,
        "account",
        &scope_id,
        None,
        None,
        "auth.login_failed",
        "account",
        None,
        AuditSource::Api,
        occurred_at,
        AuditResult::Failure,
    )
    .await
}

/// Records an account-scoped authentication failure without attributing the
/// request to an actor. The account identifier is used only to derive the
/// keyed scope; it is never stored in actor or resource fields.
pub(crate) async fn record_unattributed_account_failure_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    account_id: &str,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: AuditSource,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = account_scope_id(&state.cursor_key, account_id)?;
    record_event_tx(
        tx,
        "account",
        &scope_id,
        None,
        None,
        action,
        resource_type,
        resource_id,
        source,
        occurred_at,
        AuditResult::Failure,
    )
    .await
}

pub(crate) async fn record_vault_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    vault_id: &str,
    actor_user_id: Option<&str>,
    actor_device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: AuditSource,
    occurred_at: i64,
) -> Result<(), ApiError> {
    record_event_tx(
        tx,
        "vault",
        vault_id,
        actor_user_id,
        actor_device_id,
        action,
        resource_type,
        resource_id,
        source,
        occurred_at,
        AuditResult::Success,
    )
    .await
}

/// Records a maintenance action against the installation itself. Instance
/// events are excluded from the user-facing account audit API.
pub(crate) async fn record_instance_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = resource_id
        .map(|id| instance_resource_id(&state.cursor_key, resource_type, id))
        .transpose()?;
    record_event_tx(
        tx,
        "instance",
        &scope_id,
        None,
        None,
        action,
        resource_type,
        resource_id.as_deref(),
        AuditSource::Maintenance,
        occurred_at,
        AuditResult::Success,
    )
    .await
}

/// Records an authenticated instance-admin operation. Instance scope and
/// resource identifiers are HMACed so the audit row is attributable without
/// storing raw Vault identifiers. Unlike maintenance events this retains the
/// authenticated actor user and device IDs.
pub(crate) async fn record_instance_admin_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    actor_user_id: &str,
    actor_device_id: &str,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    occurred_at: i64,
) -> Result<(), ApiError> {
    record_instance_admin_event_with_result_tx(
        tx,
        state,
        actor_user_id,
        actor_device_id,
        action,
        resource_type,
        resource_id,
        occurred_at,
        AuditResult::Success,
    )
    .await
}

/// Records a PostgreSQL-backed instance-admin operation in the same shared
/// transaction as its state change. Instance scope and resource identifiers
/// are HMACed, while authenticated actor identifiers remain attributable.
pub(crate) async fn record_instance_admin_event_pg_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    state: &AppState,
    actor: &auth::AuthUser,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
) -> Result<(), ApiError> {
    let scope_id = instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = resource_id
        .map(|id| instance_resource_id(&state.cursor_key, resource_type, id))
        .transpose()?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events(\
            scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,\
            result,occurred_at,source\
         ) VALUES('instance',$1,$2,$3,$4,$5,$6,'success',$7,'api')",
    )
    .bind(scope_id)
    .bind(&actor.user_id)
    .bind(&actor.device_id)
    .bind(action)
    .bind(resource_type)
    .bind(resource_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn record_instance_admin_failure_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    actor_user_id: &str,
    actor_device_id: &str,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    occurred_at: i64,
) -> Result<(), ApiError> {
    record_instance_admin_event_with_result_tx(
        tx,
        state,
        actor_user_id,
        actor_device_id,
        action,
        resource_type,
        resource_id,
        occurred_at,
        AuditResult::Failure,
    )
    .await
}

async fn record_instance_admin_event_with_result_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    state: &AppState,
    actor_user_id: &str,
    actor_device_id: &str,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    occurred_at: i64,
    result: AuditResult,
) -> Result<(), ApiError> {
    let scope_id = instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = resource_id
        .map(|id| instance_resource_id(&state.cursor_key, resource_type, id))
        .transpose()?;
    record_event_tx(
        tx,
        "instance",
        &scope_id,
        Some(actor_user_id),
        Some(actor_device_id),
        action,
        resource_type,
        resource_id.as_deref(),
        AuditSource::Api,
        occurred_at,
        result,
    )
    .await
}

async fn record_event_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    scope_type: &str,
    scope_id: &str,
    actor_user_id: Option<&str>,
    actor_device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    source: AuditSource,
    occurred_at: i64,
    result: AuditResult,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES(?,?,?,?,?,?,?,?,?,?)")
        .bind(scope_type)
        .bind(scope_id)
        .bind(actor_user_id)
        .bind(actor_device_id)
        .bind(action)
        .bind(resource_type)
        .bind(resource_id)
        .bind(result.as_str())
        .bind(occurred_at)
        .bind(source.as_str())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) fn account_scope_id(key: &[u8; 32], user_id: &str) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(ACCOUNT_SCOPE_DOMAIN);
    mac.update(user_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn instance_scope_id(key: &[u8; 32], instance_id: &str) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(INSTANCE_SCOPE_DOMAIN);
    mac.update(instance_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn instance_resource_id(
    key: &[u8; 32],
    resource_type: &str,
    resource_id: &str,
) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(INSTANCE_RESOURCE_DOMAIN);
    mac.update(resource_type.as_bytes());
    mac.update(&[0]);
    mac.update(resource_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn encode_cursor(key: &[u8; 32], cursor: &AuditCursor) -> Result<String, ApiError> {
    let payload = serde_jcs::to_vec(cursor).map_err(ApiError::internal)?;
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(CURSOR_DOMAIN);
    mac.update(&payload);
    let signature = mac.finalize().into_bytes();
    Ok(format!(
        "{}.{}",
        URL_SAFE_NO_PAD.encode(payload),
        URL_SAFE_NO_PAD.encode(signature)
    ))
}

pub(crate) fn decode_cursor(
    key: &[u8; 32],
    value: &str,
    requester_scope: &str,
    generation: &str,
) -> Result<AuditCursor, ApiError> {
    if value.len() > 2048 {
        return Err(invalid_audit_cursor());
    }
    let (payload, signature) = value
        .split_once('.')
        .filter(|(_, signature)| !signature.contains('.'))
        .ok_or_else(invalid_audit_cursor)?;
    let payload = URL_SAFE_NO_PAD
        .decode(payload)
        .map_err(|_| invalid_audit_cursor())?;
    let signature = URL_SAFE_NO_PAD
        .decode(signature)
        .map_err(|_| invalid_audit_cursor())?;
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(CURSOR_DOMAIN);
    mac.update(&payload);
    mac.verify_slice(&signature)
        .map_err(|_| invalid_audit_cursor())?;
    let cursor: AuditCursor =
        serde_json::from_slice(&payload).map_err(|_| invalid_audit_cursor())?;
    if cursor.version != 1
        || cursor.requester_scope != requester_scope
        || cursor.high_watermark < 0
        || cursor.after_event_id < 0
        || cursor.after_event_id > cursor.high_watermark
    {
        return Err(invalid_audit_cursor());
    }
    if cursor.server_generation != generation {
        return Err(ApiError::gone(
            "AUDIT_CURSOR_EXPIRED",
            "audit cursor belongs to an earlier server generation",
        ));
    }
    Ok(cursor)
}

fn invalid_audit_cursor() -> ApiError {
    ApiError::bad_request(
        "INVALID_AUDIT_CURSOR",
        "audit cursor is invalid or belongs to another caller",
    )
}

pub async fn list_audit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuditQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    let limit = match query.limit {
        None => DEFAULT_PAGE_SIZE,
        Some(raw) => raw.parse::<u32>().map_err(|_| {
            ApiError::bad_request("INVALID_LIMIT", "audit limit must be an integer")
        })?,
    };
    if !(1..=MAX_PAGE_SIZE).contains(&limit) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "audit limit must be between 1 and 200",
        ));
    }
    let requester_scope = account_scope_id(&state.cursor_key, &user.user_id)?;
    let first_page = query.cursor.is_none();
    let mut cursor = match query.cursor {
        Some(value) => decode_cursor(
            &state.cursor_key,
            &value,
            &requester_scope,
            &state.instance.generation,
        )?,
        None => AuditCursor {
            version: 1,
            requester_scope: requester_scope.clone(),
            server_generation: state.instance.generation.clone(),
            high_watermark: 0,
            after_event_id: 0,
        },
    };
    let page_limit = i64::from(limit) + 1;
    let (high_watermark, page_rows) = if let Some(pool) = state.pg_sync_pool.as_ref() {
        let page = crate::pg_audit::list_page(
            pool,
            first_page,
            cursor.after_event_id,
            cursor.high_watermark,
            &requester_scope,
            &user.user_id,
            page_limit,
        )
        .await?;
        let events = page
            .events
            .into_iter()
            .map(|event| Ok((event.event_id, event.into_json()?)))
            .collect::<Result<Vec<_>, ApiError>>()?;
        (page.high_watermark, events)
    } else {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        if first_page {
            cursor.high_watermark =
                sqlx::query_scalar("SELECT COALESCE(MAX(event_id),0) FROM audit_events")
                    .fetch_one(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
        }
        let rows = sqlx::query("SELECT e.event_id,e.scope_type,e.scope_id,e.actor_user_id,e.actor_device_id,e.action,e.resource_type,e.resource_id,e.result,e.occurred_at,e.source FROM audit_events e WHERE e.event_id>? AND e.event_id<=? AND ((e.scope_type='account' AND e.scope_id=?) OR (e.scope_type='vault' AND EXISTS(SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id WHERE vm.vault_id=e.scope_id AND vm.user_id=? AND vm.state='active' AND vm.role IN ('owner','editor') AND v.state IN ('active','deleting')))) ORDER BY e.event_id LIMIT ?")
            .bind(cursor.after_event_id)
            .bind(cursor.high_watermark)
            .bind(&requester_scope)
            .bind(&user.user_id)
            .bind(page_limit)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        let events = rows
            .into_iter()
            .map(|row| {
                let event_id: i64 = row.get("event_id");
                let occurred_at: i64 = row.get("occurred_at");
                let occurred_at = DateTime::<Utc>::from_timestamp(occurred_at, 0)
                    .ok_or_else(|| ApiError::internal("audit timestamp is invalid"))?
                    .to_rfc3339();
                let scope_type: String = row.get("scope_type");
                let scope_id: String = row.get("scope_id");
                let event = json!({
                    "event_id": event_id.to_string(),
                    "scope": scope_type,
                    "vault_id": if scope_type == "vault" { Value::String(scope_id) } else { Value::Null },
                    "actor_user_id": row.get::<Option<String>, _>("actor_user_id"),
                    "actor_device_id": row.get::<Option<String>, _>("actor_device_id"),
                    "action": row.get::<String, _>("action"),
                    "resource_type": row.get::<String, _>("resource_type"),
                    "resource_id": row.get::<Option<String>, _>("resource_id"),
                    "result": row.get::<String, _>("result"),
                    "occurred_at": occurred_at,
                    "source": row.get::<String, _>("source"),
                });
                Ok((event_id, event))
            })
            .collect::<Result<Vec<_>, ApiError>>()?;
        (cursor.high_watermark, events)
    };
    cursor.high_watermark = high_watermark;
    let has_more = page_rows.len() > limit as usize;
    let page_rows = page_rows
        .into_iter()
        .take(limit as usize)
        .collect::<Vec<_>>();
    let events = page_rows
        .iter()
        .map(|(_, event)| event.clone())
        .collect::<Vec<_>>();
    let next_cursor = if has_more {
        let after_event_id = page_rows
            .last()
            .map(|(event_id, _)| *event_id)
            .unwrap_or(cursor.after_event_id);
        Some(encode_cursor(
            &state.cursor_key,
            &AuditCursor {
                after_event_id,
                ..cursor
            },
        )?)
    } else {
        None
    };
    Ok(Json(json!({
        "events": events,
        "next_cursor": next_cursor,
        "has_more": has_more,
    })))
}

/// Lists only installation-scope audit events for an allowlisted instance
/// administrator. The cursor is account- and generation-bound and takes its
/// high-water mark from the instance scope only.
pub async fn list_instance_admin_audit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AuditQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_audit_limit(query.limit, MAX_PAGE_SIZE)?;
    let requester_scope = admin_audit_requester_scope_id(&state.cursor_key, &user.user_id)?;
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        return Ok(Json(
            crate::pg_audit::list_instance_admin_page(
                pool,
                &user,
                &state.config.admin_usernames,
                query.cursor.as_deref(),
                i64::from(limit) + 1,
                &state.cursor_key,
                &requester_scope,
                &state.instance.generation,
            )
            .await?,
        ));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let cursor = match query.cursor {
        Some(value) => decode_cursor(
            &state.cursor_key,
            &value,
            &requester_scope,
            &state.instance.generation,
        )?,
        None => AuditCursor {
            version: 1,
            requester_scope: requester_scope.clone(),
            server_generation: state.instance.generation.clone(),
            high_watermark: sqlx::query_scalar(
                "SELECT COALESCE(MAX(event_id),0) FROM audit_events WHERE scope_type='instance'",
            )
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?,
            after_event_id: 0,
        },
    };
    let rows = sqlx::query(
        "SELECT event_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source \
         FROM audit_events INDEXED BY idx_audit_events_instance_event_id \
         WHERE scope_type='instance' AND event_id>? AND event_id<=? \
         ORDER BY event_id LIMIT ?",
    )
    .bind(cursor.after_event_id)
    .bind(cursor.high_watermark)
    .bind(i64::from(limit) + 1)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    let has_more = rows.len() > limit as usize;
    let page_rows = rows.into_iter().take(limit as usize).collect::<Vec<_>>();
    let mut events = Vec::with_capacity(page_rows.len());
    for row in &page_rows {
        let occurred_at: i64 = row.get("occurred_at");
        let occurred_at = DateTime::<Utc>::from_timestamp(occurred_at, 0)
            .ok_or_else(|| ApiError::internal("audit timestamp is invalid"))?
            .to_rfc3339();
        events.push(json!({
            "event_id": row.get::<i64, _>("event_id").to_string(),
            "scope": "instance",
            "actor_user_id": row.get::<Option<String>, _>("actor_user_id"),
            "actor_device_id": row.get::<Option<String>, _>("actor_device_id"),
            "action": row.get::<String, _>("action"),
            "resource_type": row.get::<String, _>("resource_type"),
            "resource_id": row.get::<Option<String>, _>("resource_id"),
            "result": row.get::<String, _>("result"),
            "occurred_at": occurred_at,
            "source": row.get::<String, _>("source"),
        }));
    }
    let next_cursor = if has_more {
        let after_event_id = page_rows
            .last()
            .map(|row| row.get::<i64, _>("event_id"))
            .unwrap_or(cursor.after_event_id);
        Some(encode_cursor(
            &state.cursor_key,
            &AuditCursor {
                after_event_id,
                ..cursor
            },
        )?)
    } else {
        None
    };
    Ok(Json(json!({
        "events": events,
        "next_cursor": next_cursor,
        "has_more": has_more,
    })))
}

pub(crate) fn parse_audit_limit(raw: Option<String>, maximum: u32) -> Result<u32, ApiError> {
    let limit = match raw {
        None => DEFAULT_PAGE_SIZE,
        Some(value) => value.parse::<u32>().map_err(|_| {
            ApiError::bad_request("INVALID_LIMIT", "audit limit must be an integer")
        })?,
    };
    if !(1..=maximum).contains(&limit) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "audit limit is outside the supported range",
        ));
    }
    Ok(limit)
}

pub(crate) fn admin_audit_requester_scope_id(
    key: &[u8; 32],
    user_id: &str,
) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(ADMIN_AUDIT_REQUESTER_DOMAIN);
    mac.update(user_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) async fn prune_expired_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    cutoff_epoch: i64,
) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM audit_events WHERE occurred_at<?")
        .bind(cutoff_epoch)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AuthRateLimits, Config, open_state, secure_file::create_private_data_dir, sha256_hex,
    };
    use axum::http::HeaderValue;
    use chrono::Duration;
    use sqlx::Row;
    use std::path::PathBuf;
    use uuid::Uuid;

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
            auth_rate_limits: AuthRateLimits::default(),
        }
    }

    async fn test_state() -> AppState {
        let dir = std::env::temp_dir().join(format!("atermius-audit-{}", Uuid::new_v4()));
        create_private_data_dir(&dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", dir.display());
        open_state(&database, test_config(dir)).await.unwrap()
    }

    async fn close_state(state: &AppState) {
        let path = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(path).await.unwrap();
    }

    async fn seed_account(state: &AppState, label: &str) -> (String, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("audit-access-{}", Uuid::new_v4());
        let now = Utc::now();
        let created = now.to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{label}-{}@example.test", Uuid::new_v4()))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'audit-test','sign','encrypt',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'audit-family',?,?,?, ?,?)")
            .bind(session_id)
            .bind(&user_id)
            .bind(device_id)
            .bind(sha256_hex(access.as_bytes()))
            .bind(format!("audit-refresh-{}", Uuid::new_v4()))
            .bind((now + Duration::minutes(10)).to_rfc3339())
            .bind((now + Duration::days(30)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        (user_id, access)
    }

    fn authorization(access: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access}")).unwrap(),
        );
        headers
    }

    async fn audit_page(
        state: &AppState,
        access: &str,
        cursor: Option<String>,
        limit: Option<&str>,
    ) -> Result<Json<Value>, ApiError> {
        list_audit(
            State(state.clone()),
            authorization(access),
            Query(AuditQuery {
                cursor,
                limit: limit.map(str::to_owned),
            }),
        )
        .await
    }

    async fn admin_audit_page(
        state: &AppState,
        access: &str,
        cursor: Option<String>,
        limit: Option<&str>,
    ) -> Result<Json<Value>, ApiError> {
        list_instance_admin_audit(
            State(state.clone()),
            authorization(access),
            Query(AuditQuery {
                cursor,
                limit: limit.map(str::to_owned),
            }),
        )
        .await
    }

    async fn add_member(state: &AppState, vault: &str, user: &str, role: &str) {
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,?,'active',?)")
            .bind(vault)
            .bind(user)
            .bind(role)
            .bind(Utc::now().to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
    }

    #[test]
    fn audit_cursor_is_signed_and_binds_requester_generation_and_high_watermark() {
        let key = [0x42; 32];
        let original = AuditCursor {
            version: 1,
            requester_scope: "account-a-hmac".into(),
            server_generation: "generation-a".into(),
            high_watermark: 91,
            after_event_id: 40,
        };
        let token = encode_cursor(&key, &original).unwrap();
        assert_eq!(
            decode_cursor(&key, &token, "account-a-hmac", "generation-a").unwrap(),
            original
        );
        assert_eq!(
            decode_cursor(&key, &token, "account-b-hmac", "generation-a")
                .unwrap_err()
                .body
                .code,
            "INVALID_AUDIT_CURSOR"
        );
        assert_eq!(
            decode_cursor(&key, &token, "account-a-hmac", "generation-b")
                .unwrap_err()
                .body
                .code,
            "AUDIT_CURSOR_EXPIRED"
        );
        assert_eq!(
            decode_cursor(&key, &format!("{token}x"), "account-a-hmac", "generation-a")
                .unwrap_err()
                .body
                .code,
            "INVALID_AUDIT_CURSOR"
        );
    }

    #[test]
    fn admin_audit_requester_scope_is_separate_from_account_audit_scope() {
        let key = [0x24; 32];
        let admin_scope = admin_audit_requester_scope_id(&key, "user-id").unwrap();
        assert_ne!(admin_scope, "user-id");
        assert_eq!(
            admin_scope,
            admin_audit_requester_scope_id(&key, "user-id").unwrap()
        );
        assert_ne!(admin_scope, account_scope_id(&key, "user-id").unwrap());
        assert_ne!(
            admin_scope,
            admin_audit_requester_scope_id(&[0x25; 32], "user-id").unwrap()
        );
    }

    #[test]
    fn account_scope_is_domain_separated_and_does_not_reveal_user_id() {
        let key = [0x19; 32];
        let scope = account_scope_id(&key, "user-id").unwrap();
        assert_ne!(scope, "user-id");
        assert_eq!(scope, account_scope_id(&key, "user-id").unwrap());
        assert_ne!(scope, account_scope_id(&[0x20; 32], "user-id").unwrap());
    }

    #[test]
    fn instance_scope_is_domain_separated_and_does_not_reveal_instance_id() {
        let key = [0x19; 32];
        let scope = instance_scope_id(&key, "instance-id").unwrap();
        assert_ne!(scope, "instance-id");
        assert_eq!(scope, instance_scope_id(&key, "instance-id").unwrap());
        assert_ne!(
            scope,
            instance_scope_id(&[0x20; 32], "instance-id").unwrap()
        );
        assert_ne!(scope, account_scope_id(&key, "instance-id").unwrap());
    }

    #[test]
    fn instance_resource_id_is_keyed_and_bound_to_its_resource_type() {
        let key = [0x19; 32];
        let id = instance_resource_id(&key, "account_invitation", "invitation-id").unwrap();
        assert_eq!(id.len(), 64);
        assert_ne!(id, "invitation-id");
        assert_ne!(
            id,
            instance_resource_id(&[0x20; 32], "account_invitation", "invitation-id").unwrap()
        );
        assert_ne!(
            id,
            instance_resource_id(&key, "other_resource", "invitation-id").unwrap()
        );
    }

    #[tokio::test]
    async fn failed_login_event_is_account_scoped_and_has_no_unverified_actor() {
        let state = test_state().await;
        let (user_id, _) = seed_account(&state, "login-failure").await;
        let mut tx = state.db.begin().await.unwrap();
        record_failed_login_tx(&mut tx, &state, &user_id, 1234)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let row = sqlx::query("SELECT scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source FROM audit_events")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(row.get::<String, _>("scope_type"), "account");
        assert_eq!(
            row.get::<String, _>("scope_id"),
            account_scope_id(&state.cursor_key, &user_id).unwrap()
        );
        assert_ne!(row.get::<String, _>("scope_id"), user_id);
        assert_eq!(row.get::<Option<String>, _>("actor_user_id"), None);
        assert_eq!(row.get::<Option<String>, _>("actor_device_id"), None);
        assert_eq!(row.get::<String, _>("action"), "auth.login_failed");
        assert_eq!(row.get::<String, _>("resource_type"), "account");
        assert_eq!(row.get::<Option<String>, _>("resource_id"), None);
        assert_eq!(row.get::<String, _>("result"), "failure");
        assert_eq!(row.get::<String, _>("source"), "api");
        close_state(&state).await;
    }

    #[tokio::test]
    async fn audit_pages_bind_requester_and_high_watermark_and_filter_current_roles() {
        let state = test_state().await;
        let (owner_id, owner_access) = seed_account(&state, "owner").await;
        let (editor_id, editor_access) = seed_account(&state, "editor").await;
        let (viewer_id, viewer_access) = seed_account(&state, "viewer").await;
        let (foreign_id, _) = seed_account(&state, "foreign").await;
        let (_outsider_id, outsider_access) = seed_account(&state, "outsider").await;
        let vault_id = Uuid::new_v4().to_string();
        let foreign_vault_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        for (vault, owner) in [(&vault_id, &owner_id), (&foreign_vault_id, &foreign_id)] {
            sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
                .bind(vault)
                .bind(owner)
                .bind(&now)
                .execute(&state.db)
                .await
                .unwrap();
        }
        add_member(&state, &vault_id, &owner_id, "owner").await;
        add_member(&state, &vault_id, &editor_id, "editor").await;
        add_member(&state, &vault_id, &viewer_id, "viewer").await;
        add_member(&state, &foreign_vault_id, &foreign_id, "owner").await;

        let mut tx = state.db.begin().await.unwrap();
        record_account_event_tx(
            &mut tx,
            &state,
            &owner_id,
            Some("owner-device"),
            "device.registered",
            "device",
            Some("owner-device"),
            AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await
        .unwrap();
        record_vault_event_tx(
            &mut tx,
            &vault_id,
            Some(&owner_id),
            Some("owner-device"),
            "vault.key_rotated",
            "vault",
            Some(&vault_id),
            AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await
        .unwrap();
        record_vault_event_tx(
            &mut tx,
            &foreign_vault_id,
            Some(&foreign_id),
            Some("foreign-device"),
            "vault.key_rotated",
            "vault",
            Some(&foreign_vault_id),
            AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await
        .unwrap();
        record_instance_event_tx(
            &mut tx,
            &state,
            "instance.audit_test",
            "instance_resource",
            Some("opaque-instance-resource-id"),
            Utc::now().timestamp(),
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();

        let stored_scope: String = sqlx::query_scalar(
            "SELECT scope_id FROM audit_events WHERE scope_type='account' LIMIT 1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_ne!(
            stored_scope, owner_id,
            "account scope must not store raw account ID"
        );
        let Json(owner_events) = audit_page(&state, &owner_access, None, Some("20"))
            .await
            .unwrap();
        assert!(
            owner_events["events"]
                .as_array()
                .unwrap()
                .iter()
                .all(|event| event["scope"] != "instance")
        );
        let Json(first) = audit_page(&state, &owner_access, None, Some("1"))
            .await
            .unwrap();
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["events"][0]["scope"], "account");
        assert_eq!(first["has_more"], true);
        let owner_cursor = first["next_cursor"].as_str().unwrap().to_owned();

        // This event is newer than the high watermark captured by page one.
        let mut tx = state.db.begin().await.unwrap();
        record_vault_event_tx(
            &mut tx,
            &vault_id,
            Some(&owner_id),
            Some("owner-device"),
            "vault.invitation_created",
            "invitation",
            Some("opaque-invitation-id"),
            AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();

        let Json(second) = audit_page(&state, &owner_access, Some(owner_cursor.clone()), Some("1"))
            .await
            .unwrap();
        assert_eq!(second["events"].as_array().unwrap().len(), 1);
        assert_eq!(second["events"][0]["scope"], "vault");
        assert_eq!(second["events"][0]["vault_id"], vault_id);
        assert_eq!(second["has_more"], false);
        assert_eq!(
            audit_page(&state, &editor_access, Some(owner_cursor), Some("1"))
                .await
                .unwrap_err()
                .body
                .code,
            "INVALID_AUDIT_CURSOR",
            "a cursor cannot be transferred to another account"
        );

        let Json(editor_page) = audit_page(&state, &editor_access, None, Some("20"))
            .await
            .unwrap();
        assert!(
            editor_page["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| { event["scope"] == "vault" && event["vault_id"] == vault_id })
        );
        assert!(
            editor_page["events"]
                .as_array()
                .unwrap()
                .iter()
                .all(|event| {
                    event["vault_id"] != foreign_vault_id && event["scope"] == "vault"
                })
        );
        let editor_cursor = audit_page(&state, &editor_access, None, Some("1"))
            .await
            .unwrap()["next_cursor"]
            .as_str()
            .unwrap()
            .to_owned();
        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
            .bind(&vault_id)
            .bind(&editor_id)
            .execute(&state.db)
            .await
            .unwrap();
        let Json(editor_after_revocation) =
            audit_page(&state, &editor_access, Some(editor_cursor), Some("20"))
                .await
                .unwrap();
        assert!(
            editor_after_revocation["events"]
                .as_array()
                .unwrap()
                .is_empty()
        );

        let Json(viewer_page) = audit_page(&state, &viewer_access, None, Some("20"))
            .await
            .unwrap();
        assert!(viewer_page["events"].as_array().unwrap().is_empty());
        let Json(outsider_page) = audit_page(&state, &outsider_access, None, Some("20"))
            .await
            .unwrap();
        assert!(outsider_page["events"].as_array().unwrap().is_empty());
        assert_eq!(
            audit_page(&state, &owner_access, None, Some("0"))
                .await
                .unwrap_err()
                .body
                .code,
            "INVALID_LIMIT"
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn instance_admin_audit_authorizes_filters_and_keeps_a_stable_private_page() {
        let mut state = test_state().await;
        let (admin_id, admin_access) = seed_account(&state, "audit-admin").await;
        let (second_admin_id, second_admin_access) = seed_account(&state, "audit-admin-two").await;
        let (outsider_id, outsider_access) = seed_account(&state, "audit-outsider").await;
        let admin_username = "audit-admin@example.test";
        let second_admin_username = "audit-admin-two@example.test";
        sqlx::query("UPDATE users SET username=? WHERE user_id=?")
            .bind(admin_username)
            .bind(&admin_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE users SET username=? WHERE user_id=?")
            .bind(second_admin_username)
            .bind(&second_admin_id)
            .execute(&state.db)
            .await
            .unwrap();
        std::sync::Arc::get_mut(&mut state.config)
            .expect("test state config is unique")
            .admin_usernames = vec![admin_username.into(), second_admin_username.into()];

        assert_eq!(
            list_instance_admin_audit(
                State(state.clone()),
                HeaderMap::new(),
                Query(AuditQuery {
                    cursor: None,
                    limit: None,
                }),
            )
            .await
            .unwrap_err()
            .body
            .code,
            "AUTH_REQUIRED"
        );
        assert_eq!(
            admin_audit_page(&state, &outsider_access, None, None)
                .await
                .unwrap_err()
                .body
                .code,
            "INSTANCE_ADMIN_REQUIRED"
        );
        for invalid_limit in ["0", "201"] {
            assert_eq!(
                admin_audit_page(&state, &admin_access, None, Some(invalid_limit))
                    .await
                    .unwrap_err()
                    .body
                    .code,
                "INVALID_LIMIT"
            );
        }

        let raw_vault_id = Uuid::new_v4().to_string();
        let now = Utc::now().timestamp();
        let mut tx = state.db.begin().await.unwrap();
        record_instance_admin_event_tx(
            &mut tx,
            &state,
            &admin_id,
            "admin-device-id",
            "admin.vault_quota_set",
            "vault",
            Some(&raw_vault_id),
            now,
        )
        .await
        .unwrap();
        record_instance_event_tx(
            &mut tx,
            &state,
            "instance.audit_test",
            "instance_resource",
            Some("maintenance-resource-id"),
            now,
        )
        .await
        .unwrap();
        record_account_event_tx(
            &mut tx,
            &state,
            &admin_id,
            Some("admin-device-id"),
            "audit.account_scope_sentinel",
            "account",
            Some(&admin_id),
            AuditSource::Api,
            now,
        )
        .await
        .unwrap();
        record_vault_event_tx(
            &mut tx,
            &raw_vault_id,
            Some(&admin_id),
            Some("admin-device-id"),
            "audit.vault_scope_sentinel",
            "vault",
            Some(&raw_vault_id),
            AuditSource::Api,
            now,
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();

        let Json(first) = admin_audit_page(&state, &admin_access, None, Some("1"))
            .await
            .unwrap();
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["has_more"], true);
        assert_eq!(first["events"][0]["scope"], "instance");
        let cursor = first["next_cursor"].as_str().unwrap().to_owned();
        assert_eq!(
            admin_audit_page(
                &state,
                &second_admin_access,
                Some(cursor.clone()),
                Some("1")
            )
            .await
            .unwrap_err()
            .body
            .code,
            "INVALID_AUDIT_CURSOR"
        );

        let mut rotated_state = state.clone();
        std::sync::Arc::make_mut(&mut rotated_state.instance).generation =
            "rotated-generation".into();
        assert_eq!(
            admin_audit_page(
                &rotated_state,
                &admin_access,
                Some(cursor.clone()),
                Some("1")
            )
            .await
            .unwrap_err()
            .body
            .code,
            "AUDIT_CURSOR_EXPIRED"
        );

        let mut tx = state.db.begin().await.unwrap();
        record_instance_event_tx(
            &mut tx,
            &state,
            "instance.audit_test_late",
            "instance_resource",
            Some("late-resource-id"),
            now + 1,
        )
        .await
        .unwrap();
        tx.commit().await.unwrap();

        let Json(second) = admin_audit_page(&state, &admin_access, Some(cursor), Some("1"))
            .await
            .unwrap();
        assert_eq!(second["events"].as_array().unwrap().len(), 1);
        assert_eq!(second["events"][0]["action"], "instance.audit_test");
        assert_eq!(second["has_more"], false);
        let combined = format!("{}{}", first, second);
        assert!(!combined.contains(&raw_vault_id));
        assert!(!combined.contains("audit.account_scope_sentinel"));
        assert!(!combined.contains("audit.vault_scope_sentinel"));
        assert!(!combined.contains("instance.audit_test_late"));

        let admin_event = sqlx::query("SELECT scope_type,actor_user_id,actor_device_id,action,resource_id,result,source FROM audit_events WHERE action='admin.vault_quota_set'")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(admin_event.get::<String, _>("scope_type"), "instance");
        assert_eq!(admin_event.get::<String, _>("actor_user_id"), admin_id);
        assert_eq!(
            admin_event.get::<String, _>("actor_device_id"),
            "admin-device-id"
        );
        let resource_id: String = admin_event.get("resource_id");
        assert_eq!(resource_id.len(), 64);
        assert_ne!(resource_id, raw_vault_id);
        assert_eq!(admin_event.get::<String, _>("result"), "success");
        assert_eq!(admin_event.get::<String, _>("source"), "api");
        assert_ne!(outsider_id, admin_id);

        drop(rotated_state);
        std::sync::Arc::get_mut(&mut state.config)
            .expect("no request state clones remain")
            .admin_usernames = vec![second_admin_username.into()];
        assert_eq!(
            admin_audit_page(&state, &admin_access, None, None)
                .await
                .unwrap_err()
                .body
                .code,
            "INSTANCE_ADMIN_REQUIRED",
            "the current allowlist is rechecked for every page request"
        );
        std::sync::Arc::get_mut(&mut state.config)
            .expect("no request state clones remain")
            .admin_usernames = vec![admin_username.into(), second_admin_username.into()];

        sqlx::query("UPDATE sessions SET revoked_at=? WHERE user_id=?")
            .bind(Utc::now().to_rfc3339())
            .bind(&second_admin_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert_eq!(
            admin_audit_page(&state, &second_admin_access, None, None)
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED",
            "a previously allowlisted administrator still needs a live session"
        );

        sqlx::query("UPDATE devices SET status='revoked' WHERE user_id=?")
            .bind(&admin_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert_eq!(
            admin_audit_page(&state, &admin_access, None, None)
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED",
            "a previously allowlisted administrator still needs an active device"
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn audit_retention_prunes_only_expired_metadata() {
        let state = test_state().await;
        let now = Utc::now().timestamp();
        sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','old-scope','old.action','account','success',?,'api'),('account','fresh-scope','fresh.action','account','success',?,'api')")
            .bind(now - 10_000)
            .bind(now - 10)
            .execute(&state.db)
            .await
            .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        prune_expired_tx(&mut tx, now - 100).await.unwrap();
        tx.commit().await.unwrap();
        let rows = sqlx::query("SELECT action FROM audit_events ORDER BY event_id")
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].get::<String, _>("action"), "fresh.action");
        close_state(&state).await;
    }
}

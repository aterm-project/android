use crate::{ApiError, AppState, auth::AuthUser, current_user, sha256_hex};
use axum::{
    Json,
    extract::{State, ws::WebSocketUpgrade},
    http::{HeaderMap, StatusCode, header::ORIGIN},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::Row;
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    sync::OwnedSemaphorePermit,
    time::{MissedTickBehavior, interval, timeout},
};

pub(crate) const MAX_GLOBAL_CONNECTIONS: usize = 256;
pub(crate) const MAX_GLOBAL_POLL_QUERIES: usize = 32;
const MAX_CONNECTIONS_PER_USER: usize = 8;
const MAX_CONNECTIONS_PER_SESSION: usize = 4;
const MAX_VAULTS_PER_CONNECTION: usize = 4096;
const MAX_OUTSTANDING_TICKETS: i64 = 100_000;
const MAX_TICKETS_PER_USER_PER_MINUTE: i64 = 30;
const MAX_TICKETS_PER_SESSION_PER_MINUTE: i64 = 10;
const TICKET_TTL_SECONDS: i64 = 30;
const TICKET_RATE_WINDOW_SECONDS: i64 = 60;
const FIRST_FRAME_TIMEOUT: Duration = Duration::from_secs(10);
const OUTBOUND_SEND_TIMEOUT: Duration = Duration::from_secs(1);
const POLL_INTERVAL: Duration = Duration::from_secs(2);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const FIRST_FRAME_MAX_BYTES: usize = 2048;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthenticateFrame {
    #[serde(rename = "type")]
    kind: String,
    ticket: String,
}

#[derive(Debug, Clone)]
struct SessionBinding {
    user_id: String,
    device_id: String,
    session_id: String,
    server_generation: String,
    session_access_expires_at: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WatchedVault {
    commit_seq: i64,
    conflict_seq: i64,
    role: String,
    state: String,
}

struct NotificationConnectionGuard {
    state: Arc<AppState>,
    user_key: String,
    session_key: String,
}

impl Drop for NotificationConnectionGuard {
    fn drop(&mut self) {
        if let Ok(mut counts) = self.state.notification_connections.lock() {
            decrement_count(&mut counts, &self.user_key);
            decrement_count(&mut counts, &self.session_key);
        }
    }
}

fn decrement_count(counts: &mut HashMap<String, usize>, key: &str) {
    if let Some(count) = counts.get_mut(key) {
        *count = count.saturating_sub(1);
        if *count == 0 {
            counts.remove(key);
        }
    }
}

fn connection_key(scope: &str, id: &str) -> String {
    format!("{scope}:{id}")
}

fn acquire_user_session_connection(
    state: Arc<AppState>,
    user_id: &str,
    session_id: &str,
) -> Option<NotificationConnectionGuard> {
    let user_key = connection_key("user", user_id);
    let session_key = connection_key("session", session_id);
    let mut counts = state.notification_connections.lock().ok()?;
    if counts.get(&user_key).copied().unwrap_or(0) >= MAX_CONNECTIONS_PER_USER
        || counts.get(&session_key).copied().unwrap_or(0) >= MAX_CONNECTIONS_PER_SESSION
    {
        return None;
    }
    *counts.entry(user_key.clone()).or_default() += 1;
    *counts.entry(session_key.clone()).or_default() += 1;
    drop(counts);
    Some(NotificationConnectionGuard {
        state,
        user_key,
        session_key,
    })
}

fn is_origin_allowed(expected: &str, headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(ORIGIN).iter();
    matches!(
        (values.next(), values.next()),
        (Some(value), None) if value.to_str().ok() == Some(expected)
    )
}

fn is_valid_ticket(ticket: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(ticket)
        .is_ok_and(|bytes| bytes.len() == 32)
}

/// Issues a short-lived WebSocket-only credential. The normal bearer token
/// remains in the HTTPS request header and is never put into the WebSocket URL.
pub async fn create_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_notifications::create_ticket(State(state), headers).await;
    }
    if state.config.public_origin.is_none() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "NOTIFICATIONS_DISABLED",
            "notifications require a configured public origin",
        ));
    }
    let user = current_user(&state, &headers).await?;
    let (ticket, expires_at, expires_in_seconds) = issue_ticket(&state, &user).await?;
    Ok(Json(json!({
        "ticket": ticket,
        "expires_at": expires_at,
        "expires_in_seconds": expires_in_seconds,
    })))
}

async fn issue_ticket(
    state: &AppState,
    user: &AuthUser,
) -> Result<(String, String, i64), ApiError> {
    let now = Utc::now().timestamp();
    let cutoff = now - TICKET_RATE_WINDOW_SECONDS;
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = URL_SAFE_NO_PAD.encode(raw);
    let ticket_hash = sha256_hex(ticket.as_bytes());
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

    // This no-op update obtains SQLite's writer serialization before ticket
    // rate checks and binds the ticket to the session expiry atomically.
    sqlx::query("UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=?")
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let session = sqlx::query("SELECT s.access_expires_at FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.access_hash=? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active'")
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
    let session_access_expires_at: String = session.get("access_expires_at");
    let session_expiry = DateTime::parse_from_rfc3339(&session_access_expires_at)
        .map_err(ApiError::internal)?
        .timestamp();
    if session_expiry <= now {
        return Err(ApiError::unauthorized());
    }

    sqlx::query("DELETE FROM notification_tickets WHERE created_at<=?")
        .bind(cutoff)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

    let (user_count, user_oldest): (i64, Option<i64>) = sqlx::query_as(
        "SELECT COUNT(*),MIN(created_at) FROM notification_tickets WHERE user_id=? AND created_at>?",
    )
    .bind(&user.user_id)
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if user_count >= MAX_TICKETS_PER_USER_PER_MINUTE {
        return Err(ticket_rate_limit_error(user_oldest, now));
    }
    let (session_count, session_oldest): (i64, Option<i64>) = sqlx::query_as(
        "SELECT COUNT(*),MIN(created_at) FROM notification_tickets WHERE session_id=? AND created_at>?",
    )
    .bind(&user.session_id)
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if session_count >= MAX_TICKETS_PER_SESSION_PER_MINUTE {
        return Err(ticket_rate_limit_error(session_oldest, now));
    }
    let row_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM notification_tickets")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if row_count >= MAX_OUTSTANDING_TICKETS {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "NOTIFICATIONS_BUSY",
            "notification ticket capacity is temporarily full",
        ));
    }

    let expires_at_epoch = now.saturating_add(TICKET_TTL_SECONDS).min(session_expiry);
    let expires_in_seconds = expires_at_epoch - now;
    let expires_at = DateTime::<Utc>::from_timestamp(expires_at_epoch, 0)
        .ok_or_else(|| ApiError::internal("notification ticket expiry is invalid"))?
        .to_rfc3339();
    sqlx::query("INSERT INTO notification_tickets(ticket_hash,user_id,device_id,session_id,server_generation,session_access_expires_at,created_at,expires_at,consumed_at) VALUES(?,?,?,?,?,?,?,?,NULL)")
        .bind(ticket_hash)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.session_id)
        .bind(&state.instance.generation)
        .bind(&session_access_expires_at)
        .bind(now)
        .bind(expires_at_epoch)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((ticket, expires_at, expires_in_seconds))
}

fn ticket_rate_limit_error(oldest: Option<i64>, now: i64) -> ApiError {
    let retry_after = oldest
        .map(|oldest| oldest + TICKET_RATE_WINDOW_SECONDS - now)
        .unwrap_or(1)
        .max(1) as u64;
    let mut error = ApiError::new(
        StatusCode::TOO_MANY_REQUESTS,
        "NOTIFICATION_TICKET_RATE_LIMITED",
        "notification ticket issuance rate exceeded",
    );
    error.retry_after_secs = Some(retry_after);
    error
}

/// Browser WebSocket endpoint. Authentication happens in its first frame,
/// after exact-origin validation and before any subscription query is opened.
pub async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_notifications::connect(State(state), headers, ws).await;
    }
    let Some(expected_origin) = state.config.public_origin.as_deref() else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "NOTIFICATIONS_DISABLED",
            "notifications require a configured public origin",
        ));
    };
    if !is_origin_allowed(expected_origin, &headers) {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let global_permit = state
        .notification_connection_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "NOTIFICATIONS_BUSY",
                "notification connection capacity is temporarily full",
            )
        })?;
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(FIRST_FRAME_MAX_BYTES)
        .max_frame_size(FIRST_FRAME_MAX_BYTES)
        .on_upgrade(move |socket| async move {
            notification_socket(socket, state, global_permit).await;
        })
        .into_response())
}

async fn notification_socket(
    mut socket: axum::extract::ws::WebSocket,
    state: Arc<AppState>,
    _global_permit: OwnedSemaphorePermit,
) {
    let ticket = match timeout(FIRST_FRAME_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(axum::extract::ws::Message::Text(text))))
            if text.len() <= FIRST_FRAME_MAX_BYTES =>
        {
            match serde_json::from_str::<AuthenticateFrame>(&text) {
                Ok(frame) if frame.kind == "authenticate" && is_valid_ticket(&frame.ticket) => {
                    frame.ticket
                }
                _ => {
                    send_error_and_close(&mut socket, "AUTH_REQUIRED", 4001).await;
                    return;
                }
            }
        }
        _ => {
            send_error_and_close(&mut socket, "AUTH_REQUIRED", 4001).await;
            return;
        }
    };
    let Some(binding) = consume_ticket(&state, &ticket).await.unwrap_or(None) else {
        send_error_and_close(&mut socket, "AUTH_REQUIRED", 4001).await;
        return;
    };
    let Some(_user_session_guard) =
        acquire_user_session_connection(state.clone(), &binding.user_id, &binding.session_id)
    else {
        send_error_and_close(&mut socket, "NOTIFICATIONS_BUSY", 4008).await;
        return;
    };
    let Some(query_permit) = state
        .notification_query_slots
        .clone()
        .try_acquire_owned()
        .ok()
    else {
        send_error_and_close(&mut socket, "NOTIFICATIONS_BUSY", 1011).await;
        return;
    };
    let mut watched = match query_notification_snapshot(&state, &binding).await {
        Ok(Some(snapshot)) => snapshot,
        Ok(None) => {
            send_error_and_close(&mut socket, "AUTH_REQUIRED", 4001).await;
            return;
        }
        Err(error) => {
            send_query_error_and_close(&mut socket, error).await;
            return;
        }
    };
    drop(query_permit);
    if !send_json(&mut socket, ready_frame(&binding.server_generation, true)).await {
        return;
    }

    let mut poll = interval(POLL_INTERVAL);
    poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
    poll.tick().await;
    let mut heartbeat = interval(HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Skip);
    heartbeat.tick().await;

    'connection: loop {
        tokio::select! {
            message = socket.recv() => {
                match message {
                    Some(Ok(axum::extract::ws::Message::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(axum::extract::ws::Message::Ping(payload))) => {
                        if !send_message(&mut socket, axum::extract::ws::Message::Pong(payload)).await {
                            break 'connection;
                        }
                    }
                    Some(Ok(axum::extract::ws::Message::Pong(_))) => {}
                    Some(Ok(_)) => {
                        send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                        break;
                    }
                }
            }
            _ = poll.tick() => {
                let Ok(query_permit) = state.notification_query_slots.clone().try_acquire_owned() else {
                    continue;
                };
                let next = query_notification_snapshot(&state, &binding).await;
                drop(query_permit);
                let next = match next {
                    Ok(Some(snapshot)) => snapshot,
                    Ok(None) => {
                        send_error_and_close(&mut socket, "AUTH_REQUIRED", 4001).await;
                        break;
                    }
                    Err(error) => {
                        send_query_error_and_close(&mut socket, error).await;
                        break;
                    }
                };
                if watched.keys().collect::<std::collections::HashSet<_>>()
                    != next.keys().collect::<std::collections::HashSet<_>>()
                    || watched.iter().any(|(vault_id, previous)| {
                        next.get(vault_id).is_some_and(|current| {
                            current.role != previous.role || current.state != previous.state
                        })
                    })
                {
                    if !send_json(&mut socket, sync_required_frame(None, None)).await {
                        break 'connection;
                    }
                }
                for (vault_id, current) in &next {
                    if let Some(previous) = watched.get(vault_id) {
                        if current.commit_seq > previous.commit_seq
                            && !send_json(
                                &mut socket,
                                sync_required_frame(Some(vault_id), Some(current.commit_seq)),
                            )
                            .await
                        {
                            break 'connection;
                        }
                        if current.conflict_seq > previous.conflict_seq
                            && !send_json(
                                &mut socket,
                                conflict_sync_required_frame(vault_id, current.conflict_seq),
                            )
                            .await
                        {
                            break 'connection;
                        }
                    }
                }
                watched = next;
            }
            _ = heartbeat.tick() => {
                if !send_message(
                    &mut socket,
                    axum::extract::ws::Message::Ping(Vec::new().into()),
                ).await {
                    break 'connection;
                }
            }
        }
    }
}

async fn consume_ticket(
    state: &AppState,
    ticket: &str,
) -> Result<Option<SessionBinding>, ApiError> {
    if !is_valid_ticket(ticket) {
        return Ok(None);
    }
    let now = Utc::now();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let row = sqlx::query("UPDATE notification_tickets SET consumed_at=? WHERE ticket_hash=? AND consumed_at IS NULL AND expires_at>? RETURNING user_id,device_id,session_id,server_generation,session_access_expires_at")
        .bind(now.timestamp())
        .bind(sha256_hex(ticket.as_bytes()))
        .bind(now.timestamp())
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let binding = SessionBinding {
        user_id: row.get("user_id"),
        device_id: row.get("device_id"),
        session_id: row.get("session_id"),
        server_generation: row.get("server_generation"),
        session_access_expires_at: row.get("session_access_expires_at"),
    };
    let session = sqlx::query("SELECT s.access_expires_at,s.revoked_at,u.status AS account_status,d.status AS device_status FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=?")
        .bind(&binding.session_id)
        .bind(&binding.user_id)
        .bind(&binding.device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let Some(session) = session else {
        return Ok(None);
    };
    let access_expires_at: String = session.get("access_expires_at");
    let valid = session.get::<Option<String>, _>("revoked_at").is_none()
        && session.get::<String, _>("account_status") == "active"
        && session.get::<String, _>("device_status") == "active"
        && access_expires_at == binding.session_access_expires_at
        && session_is_unexpired(&access_expires_at, now);
    if binding.server_generation != state.instance.generation || !valid {
        return Ok(None);
    }
    Ok(Some(binding))
}

async fn query_notification_snapshot(
    state: &AppState,
    binding: &SessionBinding,
) -> Result<Option<HashMap<String, WatchedVault>>, ApiError> {
    let now = Utc::now();
    let rows = sqlx::query("SELECT s.access_expires_at,s.revoked_at,u.status AS account_status,d.status AS device_status,v.vault_id,COALESCE(vc.last_committed_seq,0) AS commit_seq,COALESCE(vc.last_conflict_seq,0) AS conflict_seq,vm.role,v.state AS vault_state FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id LEFT JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' LEFT JOIN vaults v ON v.vault_id=vm.vault_id AND v.state IN ('active','deleting') LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? ORDER BY v.vault_id LIMIT ?")
        .bind(&binding.session_id)
        .bind(&binding.user_id)
        .bind(&binding.device_id)
        .bind((MAX_VAULTS_PER_CONNECTION + 1) as i64)
        .fetch_all(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let Some(first) = rows.first() else {
        return Ok(None);
    };
    let access_expires_at: String = first.get("access_expires_at");
    let valid = first.get::<Option<String>, _>("revoked_at").is_none()
        && first.get::<String, _>("account_status") == "active"
        && first.get::<String, _>("device_status") == "active"
        && access_expires_at == binding.session_access_expires_at
        && binding.server_generation == state.instance.generation
        && session_is_unexpired(&access_expires_at, now);
    if !valid {
        return Ok(None);
    }
    let mut watched = HashMap::new();
    for row in rows {
        let Some(vault_id) = row.get::<Option<String>, _>("vault_id") else {
            continue;
        };
        watched.insert(
            vault_id,
            WatchedVault {
                commit_seq: row.get("commit_seq"),
                conflict_seq: row.get("conflict_seq"),
                role: row.get("role"),
                state: row.get("vault_state"),
            },
        );
    }
    if watched.len() > MAX_VAULTS_PER_CONNECTION {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "NOTIFICATIONS_LIMIT",
            "notification subscription exceeds the per-connection limit",
        ));
    }
    Ok(Some(watched))
}

fn session_is_unexpired(value: &str, now: DateTime<Utc>) -> bool {
    DateTime::parse_from_rfc3339(value).is_ok_and(|expiry| expiry > now)
}

fn ready_frame(server_generation: &str, sync_required: bool) -> Value {
    json!({
        "type": "ready",
        "server_generation": server_generation,
        "sync_required": sync_required,
        "heartbeat_seconds": HEARTBEAT_INTERVAL.as_secs(),
        "poll_interval_seconds": POLL_INTERVAL.as_secs(),
    })
}

fn sync_required_frame(vault_id: Option<&str>, commit_seq: Option<i64>) -> Value {
    json!({
        "type": "sync_required",
        "vault_id": vault_id,
        "commit_seq": commit_seq.map(|seq| seq.to_string()),
    })
}

fn conflict_sync_required_frame(vault_id: &str, conflict_seq: i64) -> Value {
    json!({
        "type": "sync_required",
        "vault_id": vault_id,
        "conflict_seq": conflict_seq.to_string(),
    })
}

async fn bounded_send<F, E>(future: F, send_timeout: Duration) -> bool
where
    F: std::future::Future<Output = Result<(), E>>,
{
    matches!(timeout(send_timeout, future).await, Ok(Ok(())))
}

async fn send_message(
    socket: &mut axum::extract::ws::WebSocket,
    message: axum::extract::ws::Message,
) -> bool {
    // Every failed or timed out send is followed by dropping this socket; a
    // partially-written WebSocket sink is never reused after cancellation.
    bounded_send(socket.send(message), OUTBOUND_SEND_TIMEOUT).await
}

async fn send_json(socket: &mut axum::extract::ws::WebSocket, value: Value) -> bool {
    send_message(
        socket,
        axum::extract::ws::Message::Text(value.to_string().into()),
    )
    .await
}

async fn send_close(socket: &mut axum::extract::ws::WebSocket, code: u16, reason: &str) -> bool {
    send_message(
        socket,
        axum::extract::ws::Message::Close(Some(axum::extract::ws::CloseFrame {
            code,
            reason: reason.into(),
        })),
    )
    .await
}

async fn send_error_and_close(
    socket: &mut axum::extract::ws::WebSocket,
    code: &str,
    close_code: u16,
) {
    if send_json(socket, json!({"type":"error","code":code})).await {
        let _ = send_close(socket, close_code, code).await;
    }
}

async fn send_query_error_and_close(socket: &mut axum::extract::ws::WebSocket, error: ApiError) {
    match error.body.code.as_str() {
        "NOTIFICATIONS_LIMIT" => {
            send_error_and_close(socket, "NOTIFICATIONS_LIMIT", 1008).await;
        }
        "NOTIFICATIONS_BUSY" => {
            send_error_and_close(socket, "NOTIFICATIONS_BUSY", 1011).await;
        }
        _ => send_error_and_close(socket, "INTERNAL", 1011).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthRateLimits, Config, now_rfc3339, open_state};
    use axum::http::HeaderValue;
    use chrono::Duration as ChronoDuration;
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
            public_origin: Some("https://app.example.test".into()),
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
        let dir = std::env::temp_dir().join(format!("atermius-notifications-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", dir.display());
        open_state(&database, test_config(dir)).await.unwrap()
    }

    async fn close_state(state: &AppState) {
        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    async fn seed_session(state: &AppState) -> (AuthUser, String, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("test-access-{}", Uuid::new_v4());
        let now = Utc::now();
        let created = now.to_rfc3339();
        let expiry = (now + ChronoDuration::minutes(10)).to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{}@example.test", Uuid::new_v4()))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'test','sign','encrypt',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'family',?,?,?,? ,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(sha256_hex(access.as_bytes()))
            .bind(format!("refresh-{}", Uuid::new_v4()))
            .bind(&expiry)
            .bind((now + ChronoDuration::days(30)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        (
            AuthUser {
                user_id: user_id.clone(),
                device_id: device_id.clone(),
                session_id: session_id.clone(),
                access_hash: sha256_hex(access.as_bytes()),
                declares_record_schema2: false,
                declares_sync_redaction_v1: true,
            },
            access,
            user_id,
        )
    }

    #[test]
    fn origin_requires_exact_configured_origin_and_ticket_has_canonical_length() {
        let mut headers = HeaderMap::new();
        headers.insert(ORIGIN, HeaderValue::from_static("https://app.example.test"));
        assert!(is_origin_allowed("https://app.example.test", &headers));
        assert!(!is_origin_allowed("https://other.example.test", &headers));
        headers.remove(ORIGIN);
        assert!(!is_origin_allowed("https://app.example.test", &headers));
        assert!(is_valid_ticket(&URL_SAFE_NO_PAD.encode([7_u8; 32])));
        assert!(!is_valid_ticket("not-a-ticket"));
    }

    #[test]
    fn notification_frames_have_only_invalidation_metadata() {
        let ready = ready_frame("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", true);
        assert_eq!(ready["type"], "ready");
        assert_eq!(ready["sync_required"], true);
        assert_eq!(ready["heartbeat_seconds"], 30);
        assert_eq!(ready["poll_interval_seconds"], 2);
        assert_eq!(ready.as_object().unwrap().len(), 5);
        let event = sync_required_frame(
            Some("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"),
            Some(9_007_199_254_740_993),
        );
        assert_eq!(
            event,
            json!({
                "type":"sync_required",
                "vault_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "commit_seq":"9007199254740993",
            })
        );
        assert!(event.get("envelope").is_none());
        let conflict = conflict_sync_required_frame(
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            9_007_199_254_740_994,
        );
        assert_eq!(
            conflict,
            json!({
                "type":"sync_required",
                "vault_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "conflict_seq":"9007199254740994",
            })
        );
        let membership = sync_required_frame(None, None);
        assert_eq!(
            membership,
            json!({
                "type":"sync_required",
                "vault_id":null,
                "commit_seq":null,
            })
        );
    }

    #[tokio::test]
    async fn outbound_send_timeout_cancels_the_pending_write() {
        use std::sync::{
            Arc,
            atomic::{AtomicBool, Ordering},
        };

        struct DropFlag(Arc<AtomicBool>);
        impl Drop for DropFlag {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }

        let dropped = Arc::new(AtomicBool::new(false));
        let guard = DropFlag(dropped.clone());
        let pending_write = async move {
            let _guard = guard;
            std::future::pending::<Result<(), ()>>().await
        };
        let result = tokio::time::timeout(
            Duration::from_secs(1),
            bounded_send(pending_write, Duration::from_millis(10)),
        )
        .await;

        assert!(matches!(result, Ok(false)));
        assert!(dropped.load(Ordering::SeqCst));
        assert!(bounded_send(async { Ok::<(), ()>(()) }, Duration::from_millis(10)).await);
        assert!(!bounded_send(async { Err::<(), _>(()) }, Duration::from_millis(10)).await);
    }

    #[tokio::test]
    async fn ticket_is_single_use_and_bound_to_session_expiry() {
        let state = test_state().await;
        let (user, _, user_id) = seed_session(&state).await;
        let (ticket, _, _) = issue_ticket(&state, &user).await.unwrap();
        assert!(consume_ticket(&state, &ticket).await.unwrap().is_some());
        assert!(consume_ticket(&state, &ticket).await.unwrap().is_none());

        let (next_ticket, _, _) = issue_ticket(&state, &user).await.unwrap();
        sqlx::query("UPDATE sessions SET access_expires_at=? WHERE session_id=?")
            .bind((Utc::now() + ChronoDuration::minutes(20)).to_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &next_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let ticket_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_tickets WHERE user_id=? AND consumed_at IS NOT NULL",
        )
        .bind(&user_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(ticket_rows, 2);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn ticket_consumption_is_atomic_under_concurrent_replay() {
        let state = test_state().await;
        let (user, _, _) = seed_session(&state).await;
        let (ticket, _, _) = issue_ticket(&state, &user).await.unwrap();
        let (first, second) = tokio::join!(
            consume_ticket(&state, &ticket),
            consume_ticket(&state, &ticket)
        );
        let successes = [first.unwrap(), second.unwrap()]
            .into_iter()
            .filter(Option::is_some)
            .count();
        assert_eq!(successes, 1);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn session_device_account_and_membership_are_rechecked_each_poll() {
        let state = test_state().await;
        let (user, _, _) = seed_session(&state).await;
        let (ticket, _, _) = issue_ticket(&state, &user).await.unwrap();
        let binding = consume_ticket(&state, &ticket).await.unwrap().unwrap();
        let now = now_rfc3339();
        let vault = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&user.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,1,3)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        let initial = query_notification_snapshot(&state, &binding)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(initial.get(&vault).unwrap().commit_seq, 1);
        assert_eq!(initial.get(&vault).unwrap().conflict_seq, 3);
        sqlx::query("UPDATE vault_counters SET last_conflict_seq=4 WHERE vault_id=?")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        let after_conflict = query_notification_snapshot(&state, &binding)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(after_conflict.get(&vault).unwrap().conflict_seq, 4);

        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
            .bind(&vault)
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        let after_membership_removal = query_notification_snapshot(&state, &binding)
            .await
            .unwrap()
            .unwrap();
        assert!(!after_membership_removal.contains_key(&vault));

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            query_notification_snapshot(&state, &binding)
                .await
                .unwrap()
                .is_none()
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn issuance_keeps_independent_tabs_but_rate_limits_spam() {
        let state = test_state().await;
        let (user, _, user_id) = seed_session(&state).await;
        let mut tickets = Vec::new();
        for _ in 0..MAX_TICKETS_PER_SESSION_PER_MINUTE {
            tickets.push(issue_ticket(&state, &user).await.unwrap().0);
        }
        assert!(tickets.windows(2).all(|pair| pair[0] != pair[1]));
        let error = issue_ticket(&state, &user).await.unwrap_err();
        assert_eq!(error.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(error.body.code, "NOTIFICATION_TICKET_RATE_LIMITED");
        assert!(error.retry_after_secs.is_some());
        assert!(consume_ticket(&state, &tickets[0]).await.unwrap().is_some());
        assert!(consume_ticket(&state, &tickets[1]).await.unwrap().is_some());
        let live_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM notification_tickets WHERE user_id=? AND created_at>?",
        )
        .bind(user_id)
        .bind(Utc::now().timestamp() - TICKET_RATE_WINDOW_SECONDS)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(live_rows, MAX_TICKETS_PER_SESSION_PER_MINUTE);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn active_notification_connection_caps_apply_per_user_session_and_instance() {
        let state = test_state().await;
        let (user, _, _) = seed_session(&state).await;
        let state = Arc::new(state);
        let mut guards = Vec::new();
        for _ in 0..MAX_CONNECTIONS_PER_SESSION {
            guards.push(
                acquire_user_session_connection(state.clone(), &user.user_id, &user.session_id)
                    .unwrap(),
            );
        }
        assert!(
            acquire_user_session_connection(state.clone(), &user.user_id, &user.session_id)
                .is_none()
        );
        drop(guards);
        assert!(
            acquire_user_session_connection(state.clone(), &user.user_id, &user.session_id)
                .is_some()
        );
        close_state(&state).await;
    }
}

//! PostgreSQL-backed, metadata-only WebSocket sync notifications.
//!
//! Tickets and watched Vault sequence numbers live in the shared PG schema so
//! a ticket issued by one server process can be consumed by another. This
//! module never reads record envelopes or object payloads; clients use the
//! normal authenticated `/changes` endpoint after receiving an invalidation.

use crate::{ApiError, AppState, auth::AuthUser, current_user, sha256_hex};
use axum::{
    Json,
    extract::{State, ws::WebSocketUpgrade},
    http::{HeaderMap, StatusCode, header::ORIGIN},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction, postgres::PgListener};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    sync::{OwnedSemaphorePermit, watch},
    task::JoinHandle,
    time::{MissedTickBehavior, interval, sleep, timeout},
};

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
const PG_SYNC_WAKE_CHANNEL: &str = "atermius_sync_wake_v1";
const PG_LISTENER_STARTUP_TIMEOUT: Duration = Duration::from_secs(1);
const PG_LISTENER_INITIAL_RETRY: Duration = Duration::from_millis(250);
const PG_LISTENER_MAX_RETRY: Duration = Duration::from_secs(5);

/// Process-local fanout for committed PostgreSQL sync invalidations. The
/// payload is deliberately empty; each socket re-reads its authorized snapshot
/// before it sends any metadata to a client.
#[derive(Clone)]
pub(crate) struct PgNotificationHub {
    wake: watch::Sender<()>,
}

impl Default for PgNotificationHub {
    fn default() -> Self {
        let (wake, _) = watch::channel(());
        Self { wake }
    }
}

impl PgNotificationHub {
    fn subscribe(&self) -> watch::Receiver<()> {
        self.wake.subscribe()
    }

    fn wake(&self) {
        // A watch channel coalesces bursts while ensuring every live socket
        // sees a changed version, with no bounded-broadcast lag window.
        self.wake.send_replace(());
    }
}

/// Owns the per-node PostgreSQL LISTEN connection. Startup makes one bounded
/// attempt; failures retain WebSocket polling and retry with bounded backoff.
pub(crate) struct PgNotificationListener {
    shutdown: watch::Sender<bool>,
    task: Option<JoinHandle<()>>,
}

impl PgNotificationListener {
    pub(crate) async fn start(pool: PgPool, hub: PgNotificationHub) -> Self {
        // Try LISTEN before binding when PostgreSQL is immediately available,
        // but do not make the sync API depend on this optional wake channel.
        // Sockets keep their 2s snapshot poll while the background task retries.
        let initial_listener = match timeout(
            PG_LISTENER_STARTUP_TIMEOUT,
            connect_pg_listener(&pool),
        )
        .await
        {
            Ok(Ok(listener)) => Some(listener),
            Ok(Err(error)) => {
                tracing::warn!(error = %error, "initial PostgreSQL notification LISTEN failed; retaining polling fallback");
                None
            }
            Err(_) => {
                tracing::warn!(
                    timeout_ms = PG_LISTENER_STARTUP_TIMEOUT.as_millis() as u64,
                    "initial PostgreSQL notification LISTEN timed out; retaining polling fallback"
                );
                None
            }
        };
        if initial_listener.is_some() {
            // The server has not bound yet, but keep activation semantics the
            // same for immediate and delayed LISTEN setup.
            hub.wake();
        }
        let (shutdown, shutdown_rx) = watch::channel(false);
        let task = tokio::spawn(run_pg_listener(pool, initial_listener, hub, shutdown_rx));
        Self {
            shutdown,
            task: Some(task),
        }
    }

    pub(crate) async fn shutdown(mut self) {
        let _ = self.shutdown.send(true);
        if let Some(task) = self.task.take()
            && let Err(error) = task.await
        {
            tracing::warn!(error = %error, "PostgreSQL notification listener task did not stop cleanly");
        }
    }
}

impl Drop for PgNotificationListener {
    fn drop(&mut self) {
        let _ = self.shutdown.send(true);
    }
}

async fn run_pg_listener(
    pool: PgPool,
    initial_listener: Option<PgListener>,
    hub: PgNotificationHub,
    mut shutdown: watch::Receiver<bool>,
) {
    let mut listener = initial_listener;
    loop {
        if listener.is_none() {
            let Some(reconnected) = reconnect_pg_listener(&pool, &mut shutdown).await else {
                return;
            };
            listener = Some(reconnected);
            // This also covers the first successful LISTEN when startup could
            // not connect in time. Sockets re-read shared state and recover
            // commits that landed while only polling was available.
            hub.wake();
        }

        let notification = tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return;
                }
                continue;
            }
            notification = listener
                .as_mut()
                .expect("listener is populated before entering its receive loop")
                .try_recv() => notification,
        };
        match notification {
            Ok(Some(_notification)) => hub.wake(),
            Ok(None) => {
                tracing::warn!("PostgreSQL notification listener disconnected; reconnecting");
                listener = None;
            }
            Err(error) => {
                tracing::warn!(error = %error, "PostgreSQL notification listener disconnected; reconnecting");
                listener = None;
            }
        }
    }
}

async fn connect_pg_listener(pool: &PgPool) -> Result<PgListener, sqlx::Error> {
    let mut listener = PgListener::connect_with(pool).await?;
    // `recv()` transparently reconnects and hides the disconnect. Keep
    // reconnect explicit so missed commits trigger a local snapshot wake.
    listener.eager_reconnect(false);
    listener.listen(PG_SYNC_WAKE_CHANNEL).await?;
    Ok(listener)
}

async fn reconnect_pg_listener(
    pool: &PgPool,
    shutdown: &mut watch::Receiver<bool>,
) -> Option<PgListener> {
    let mut retry = PG_LISTENER_INITIAL_RETRY;
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return None;
                }
            }
            _ = sleep(retry) => {}
        }

        let connected = tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return None;
                }
                continue;
            }
            result = connect_pg_listener(pool) => result,
        };
        match connected {
            Ok(listener) => return Some(listener),
            Err(error) => {
                tracing::warn!(error = %error, "PostgreSQL notification listener reconnect or LISTEN restore failed");
                retry = (retry * 2).min(PG_LISTENER_MAX_RETRY);
            }
        }
    }
}

/// Queues a fixed, empty-payload invalidation inside the caller's transaction.
/// PostgreSQL publishes it only if that transaction commits.
pub(crate) async fn notify_sync_wake(tx: &mut Transaction<'_, Postgres>) -> Result<(), ApiError> {
    sqlx::query("SELECT pg_notify('atermius_sync_wake_v1', '')")
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

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
    session_access_expires_at: DateTime<Utc>,
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

/// Issues a short-lived credential that is usable only in the first WebSocket
/// authentication frame. It is never stored in PostgreSQL or placed in a URL.
pub(crate) async fn create_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    if state.config.public_origin.is_none() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "NOTIFICATIONS_DISABLED",
            "notifications require a configured public origin",
        ));
    }
    let user = current_user(&state, &headers).await?;
    let pool = pg_pool(&state)?;
    let (ticket, expires_at, expires_in_seconds) = issue_ticket(pool, &state, &user).await?;
    Ok(Json(json!({
        "ticket": ticket,
        "expires_at": expires_at,
        "expires_in_seconds": expires_in_seconds,
    })))
}

async fn issue_ticket(
    pool: &PgPool,
    state: &AppState,
    user: &AuthUser,
) -> Result<(String, String, i64), ApiError> {
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = URL_SAFE_NO_PAD.encode(raw);
    let ticket_hash = sha256_hex(ticket.as_bytes());

    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    // Serializing issuance keeps per-user/session rate limits and the global
    // outstanding-ticket bound correct across all PG-backed server nodes.
    sqlx::query(
        "SELECT pg_advisory_xact_lock(hashtextextended('atermius:notification-ticket-issuance', 0))",
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let session = sqlx::query(
        "SELECT s.access_expires_at, clock_timestamp() AS db_now \
         FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 \
           AND s.access_hash=$4 AND s.revoked_at IS NULL \
           AND s.access_expires_at>clock_timestamp() \
           AND u.status='active' AND d.status='active' \
         FOR SHARE OF s",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    let session_expiry: DateTime<Utc> = session
        .try_get("access_expires_at")
        .map_err(ApiError::internal)?;
    let db_now: DateTime<Utc> = session.try_get("db_now").map_err(ApiError::internal)?;
    let expires_at = session_expiry.min(db_now + ChronoDuration::seconds(TICKET_TTL_SECONDS));
    if expires_at <= db_now {
        return Err(ApiError::unauthorized());
    }

    let rate_cutoff = db_now - ChronoDuration::seconds(TICKET_RATE_WINDOW_SECONDS);
    let (user_count, user_oldest): (i64, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT COUNT(*)::BIGINT, MIN(created_at) FROM notification_tickets \
         WHERE user_id=$1 AND created_at>$2",
    )
    .bind(&user.user_id)
    .bind(rate_cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if user_count >= MAX_TICKETS_PER_USER_PER_MINUTE {
        return Err(ticket_rate_limit_error(user_oldest, db_now));
    }

    let (session_count, session_oldest): (i64, Option<DateTime<Utc>>) = sqlx::query_as(
        "SELECT COUNT(*)::BIGINT, MIN(created_at) FROM notification_tickets \
         WHERE session_id=$1 AND created_at>$2",
    )
    .bind(&user.session_id)
    .bind(rate_cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if session_count >= MAX_TICKETS_PER_SESSION_PER_MINUTE {
        return Err(ticket_rate_limit_error(session_oldest, db_now));
    }

    let row_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM notification_tickets \
         WHERE consumed_at IS NULL AND expires_at>$1",
    )
    .bind(db_now)
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

    sqlx::query(
        "INSERT INTO notification_tickets( \
           ticket_hash,user_id,device_id,session_id,server_generation, \
           session_access_expires_at,created_at,expires_at,consumed_at \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,NULL)",
    )
    .bind(ticket_hash)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.session_id)
    .bind(&state.instance.generation)
    .bind(session_expiry)
    .bind(db_now)
    .bind(expires_at)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    let expires_in_seconds = (expires_at.timestamp() - db_now.timestamp()).max(0);
    Ok((ticket, expires_at.to_rfc3339(), expires_in_seconds))
}

fn ticket_rate_limit_error(oldest: Option<DateTime<Utc>>, now: DateTime<Utc>) -> ApiError {
    let retry_after = oldest
        .map(|oldest| oldest.timestamp() + TICKET_RATE_WINDOW_SECONDS - now.timestamp())
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

/// Browser WebSocket endpoint. Origin is checked before upgrading; ticket
/// authentication is performed by the first frame before any subscription
/// query runs.
pub(crate) async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
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
    // Subscribe before the first read so a commit between subscription setup
    // and the initial snapshot cannot be lost. If it races with the read, the
    // extra refresh is harmless because frames are derived from the snapshot.
    let mut wake = state.pg_notification_hub.subscribe();
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
    let mut wake_open = true;

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
                if !refresh_notification_snapshot(&mut socket, &state, &binding, &mut watched).await {
                    break;
                }
            }
            changed = wake.changed(), if wake_open => {
                if changed.is_err() {
                    // The polling path remains active if the local hub is
                    // ever closed during shutdown or test teardown.
                    wake_open = false;
                } else if !refresh_notification_snapshot(&mut socket, &state, &binding, &mut watched).await {
                    break;
                }
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

async fn refresh_notification_snapshot(
    socket: &mut axum::extract::ws::WebSocket,
    state: &AppState,
    binding: &SessionBinding,
    watched: &mut HashMap<String, WatchedVault>,
) -> bool {
    let Ok(query_permit) = state.notification_query_slots.clone().try_acquire_owned() else {
        // The next 2s poll or a coalesced wake will retry. Authorization is
        // always rechecked before any metadata frame is sent.
        return true;
    };
    let next = query_notification_snapshot(state, binding).await;
    drop(query_permit);
    let next = match next {
        Ok(Some(snapshot)) => snapshot,
        Ok(None) => {
            send_error_and_close(socket, "AUTH_REQUIRED", 4001).await;
            return false;
        }
        Err(error) => {
            send_query_error_and_close(socket, error).await;
            return false;
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
        if !send_json(socket, sync_required_frame(None, None)).await {
            return false;
        }
    }
    for (vault_id, current) in &next {
        if let Some(previous) = watched.get(vault_id) {
            if current.commit_seq > previous.commit_seq
                && !send_json(
                    socket,
                    sync_required_frame(Some(vault_id), Some(current.commit_seq)),
                )
                .await
            {
                return false;
            }
            if current.conflict_seq > previous.conflict_seq
                && !send_json(
                    socket,
                    conflict_sync_required_frame(vault_id, current.conflict_seq),
                )
                .await
            {
                return false;
            }
        }
    }
    *watched = next;
    true
}

async fn consume_ticket(
    state: &AppState,
    ticket: &str,
) -> Result<Option<SessionBinding>, ApiError> {
    if !is_valid_ticket(ticket) {
        return Ok(None);
    }
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    let row = sqlx::query(
        "UPDATE notification_tickets \
         SET consumed_at=clock_timestamp() \
         WHERE ticket_hash=$1 AND consumed_at IS NULL \
           AND expires_at>clock_timestamp() \
         RETURNING user_id,device_id,session_id,server_generation,session_access_expires_at",
    )
    .bind(sha256_hex(ticket.as_bytes()))
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let binding = SessionBinding {
        user_id: row.try_get("user_id").map_err(ApiError::internal)?,
        device_id: row.try_get("device_id").map_err(ApiError::internal)?,
        session_id: row.try_get("session_id").map_err(ApiError::internal)?,
        server_generation: row
            .try_get("server_generation")
            .map_err(ApiError::internal)?,
        session_access_expires_at: row
            .try_get("session_access_expires_at")
            .map_err(ApiError::internal)?,
    };
    let session = sqlx::query(
        "SELECT s.access_expires_at,s.revoked_at,u.status AS account_status, \
                d.status AS device_status,clock_timestamp() AS db_now \
         FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3",
    )
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
    let access_expires_at: DateTime<Utc> = session
        .try_get("access_expires_at")
        .map_err(ApiError::internal)?;
    let db_now: DateTime<Utc> = session.try_get("db_now").map_err(ApiError::internal)?;
    let valid = session
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_none()
        && session
            .try_get::<String, _>("account_status")
            .map_err(ApiError::internal)?
            == "active"
        && session
            .try_get::<String, _>("device_status")
            .map_err(ApiError::internal)?
            == "active"
        && access_expires_at == binding.session_access_expires_at
        && access_expires_at > db_now;
    if binding.server_generation != state.instance.generation || !valid {
        return Ok(None);
    }
    Ok(Some(binding))
}

async fn query_notification_snapshot(
    state: &AppState,
    binding: &SessionBinding,
) -> Result<Option<HashMap<String, WatchedVault>>, ApiError> {
    let pool = pg_pool(state)?;
    let rows = sqlx::query(
        "SELECT s.access_expires_at,s.revoked_at,u.status AS account_status, \
                d.status AS device_status,clock_timestamp() AS db_now, \
                v.vault_id,COALESCE(vc.last_committed_seq,0)::BIGINT AS commit_seq, \
                COALESCE(vc.last_conflict_seq,0)::BIGINT AS conflict_seq, \
                vm.role,v.state AS vault_state \
         FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         LEFT JOIN vault_members vm ON vm.user_id=u.user_id AND vm.state='active' \
         LEFT JOIN vaults v ON v.vault_id=vm.vault_id AND v.state IN ('active','deleting') \
         LEFT JOIN vault_counters vc ON vc.vault_id=v.vault_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 \
         ORDER BY v.vault_id LIMIT $4",
    )
    .bind(&binding.session_id)
    .bind(&binding.user_id)
    .bind(&binding.device_id)
    .bind((MAX_VAULTS_PER_CONNECTION + 1) as i64)
    .fetch_all(pool)
    .await
    .map_err(ApiError::internal)?;
    let Some(first) = rows.first() else {
        return Ok(None);
    };
    let access_expires_at: DateTime<Utc> = first
        .try_get("access_expires_at")
        .map_err(ApiError::internal)?;
    let db_now: DateTime<Utc> = first.try_get("db_now").map_err(ApiError::internal)?;
    let valid = first
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_none()
        && first
            .try_get::<String, _>("account_status")
            .map_err(ApiError::internal)?
            == "active"
        && first
            .try_get::<String, _>("device_status")
            .map_err(ApiError::internal)?
            == "active"
        && access_expires_at == binding.session_access_expires_at
        && binding.server_generation == state.instance.generation
        && access_expires_at > db_now;
    if !valid {
        return Ok(None);
    }

    let mut watched = HashMap::new();
    for row in rows {
        let Some(vault_id) = row
            .try_get::<Option<String>, _>("vault_id")
            .map_err(ApiError::internal)?
        else {
            continue;
        };
        watched.insert(
            vault_id,
            WatchedVault {
                commit_seq: row.try_get("commit_seq").map_err(ApiError::internal)?,
                conflict_seq: row.try_get("conflict_seq").map_err(ApiError::internal)?,
                role: row.try_get("role").map_err(ApiError::internal)?,
                state: row.try_get("vault_state").map_err(ApiError::internal)?,
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
    // A timed-out send is followed by dropping the socket; a partially written
    // sink is never reused after cancellation.
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

fn pg_pool(state: &AppState) -> Result<&PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL notification repository is unavailable"))
}

#[cfg(test)]
mod tests {
    use std::{str::FromStr, time::Duration};

    use super::{
        PgNotificationHub, PgNotificationListener, URL_SAFE_NO_PAD, conflict_sync_required_frame,
        is_origin_allowed, is_valid_ticket, ready_frame, sync_required_frame,
    };
    use axum::http::{HeaderMap, HeaderValue, header::ORIGIN};
    use base64::Engine as _;
    use serde_json::json;
    use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
    use uuid::Uuid;

    #[test]
    fn websocket_frames_carry_only_sync_invalidation_metadata() {
        assert_eq!(
            ready_frame("generation-a", true),
            json!({
                "type": "ready",
                "server_generation": "generation-a",
                "sync_required": true,
                "heartbeat_seconds": 30,
                "poll_interval_seconds": 2,
            })
        );
        assert_eq!(
            sync_required_frame(Some("vault-a"), Some(41)),
            json!({
                "type": "sync_required",
                "vault_id": "vault-a",
                "commit_seq": "41",
            })
        );
        assert_eq!(
            conflict_sync_required_frame("vault-a", 9),
            json!({
                "type": "sync_required",
                "vault_id": "vault-a",
                "conflict_seq": "9",
            })
        );
    }

    #[test]
    fn websocket_origin_and_ticket_parsing_are_strict() {
        let mut headers = HeaderMap::new();
        headers.insert(ORIGIN, HeaderValue::from_static("https://terminal.example"));
        assert!(is_origin_allowed("https://terminal.example", &headers));
        assert!(!is_origin_allowed("https://attacker.example", &headers));
        headers.append(ORIGIN, HeaderValue::from_static("https://terminal.example"));
        assert!(!is_origin_allowed("https://terminal.example", &headers));

        let valid = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        assert!(is_valid_ticket(&valid));
        assert!(!is_valid_ticket("not-a-ticket"));
        assert!(!is_valid_ticket(&URL_SAFE_NO_PAD.encode([7_u8; 31])));
    }

    #[tokio::test]
    async fn local_wake_hub_coalesces_wakes_without_losing_subscribers() {
        let hub = PgNotificationHub::default();
        let mut before_commit = hub.subscribe();
        hub.wake();
        hub.wake();
        assert!(before_commit.changed().await.is_ok());
        before_commit.borrow_and_update();

        let mut after_commit = hub.subscribe();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(10), after_commit.changed())
                .await
                .is_err()
        );

        hub.wake();
        assert!(before_commit.changed().await.is_ok());
        assert!(after_commit.changed().await.is_ok());
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL listener reconnect acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_listener_reconnects_and_wakes_after_restoring_listen() {
        let url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ignored listener reconnect test requires ATERMIUS_TEST_PG_URL");
        let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "refusing to run PostgreSQL tests outside an explicitly disposable database"
        );
        assert!(!matches!(
            database.as_str(),
            "postgres" | "template0" | "template1"
        ));

        let application_name = format!("atermius-listener-test-{}", Uuid::new_v4());
        let listener_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone().application_name(&application_name))
            .await
            .unwrap();
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options)
            .await
            .unwrap();
        let hub = PgNotificationHub::default();
        let mut wake = hub.subscribe();
        let listener = PgNotificationListener::start(listener_pool.clone(), hub).await;

        let old_pid = tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(pid) = sqlx::query_scalar::<_, i32>(
                    "SELECT pid FROM pg_stat_activity WHERE datname=current_database() AND application_name=$1 AND pid<>pg_backend_pid() AND query ILIKE 'LISTEN %' ORDER BY backend_start DESC LIMIT 1",
                )
                .bind(&application_name)
                .fetch_optional(&admin_pool)
                .await
                .unwrap()
                {
                    return pid;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("listener should establish LISTEN before disconnect coverage");
        tokio::time::timeout(Duration::from_secs(5), wake.changed())
            .await
            .expect("initial LISTEN activation should wake local snapshots")
            .unwrap();
        // Mark the activation wake as observed so the next one proves
        // disconnect recovery, including when initial setup was delayed.
        wake.borrow_and_update();
        let terminated: bool = sqlx::query_scalar("SELECT pg_terminate_backend($1)")
            .bind(old_pid)
            .fetch_one(&admin_pool)
            .await
            .unwrap();
        assert!(terminated, "test should terminate the listener connection");
        tokio::time::timeout(Duration::from_secs(10), wake.changed())
            .await
            .expect("listener reconnect should wake local snapshots")
            .unwrap();

        // A post-reconnect notification proves the listener reissued LISTEN,
        // not just that the reconnect path emitted its recovery wake.
        sqlx::query("SELECT pg_notify('atermius_sync_wake_v1', '')")
            .execute(&admin_pool)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), wake.changed())
            .await
            .expect("listener should receive notifications after reconnect")
            .unwrap();

        listener.shutdown().await;
        listener_pool.close().await;
        admin_pool.close().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL listener startup fallback acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_listener_startup_recovers_after_pool_is_temporarily_unavailable() {
        let url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ignored listener startup test requires ATERMIUS_TEST_PG_URL");
        let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "refusing to run PostgreSQL tests outside an explicitly disposable database"
        );
        assert!(!matches!(
            database.as_str(),
            "postgres" | "template0" | "template1"
        ));

        let application_name = format!("atermius-listener-startup-test-{}", Uuid::new_v4());
        let listener_pool = PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options.clone().application_name(&application_name))
            .await
            .unwrap();
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options)
            .await
            .unwrap();
        // Occupy the listener pool's only slot so the bounded initial attempt
        // cannot establish LISTEN. The runtime still starts, then the task
        // retries once the slot is available.
        let held_connection = listener_pool.acquire().await.unwrap();
        let hub = PgNotificationHub::default();
        let mut wake = hub.subscribe();
        let listener = PgNotificationListener::start(listener_pool.clone(), hub).await;
        assert!(
            tokio::time::timeout(Duration::from_millis(100), wake.changed())
                .await
                .is_err(),
            "listener must not report active before PostgreSQL LISTEN succeeds"
        );

        drop(held_connection);
        tokio::time::timeout(Duration::from_secs(5), wake.changed())
            .await
            .expect("delayed initial LISTEN should wake local snapshots")
            .unwrap();

        // A post-activation notification proves the delayed path registered
        // LISTEN instead of merely waking sockets after a pool retry.
        sqlx::query("SELECT pg_notify('atermius_sync_wake_v1', '')")
            .execute(&admin_pool)
            .await
            .unwrap();
        tokio::time::timeout(Duration::from_secs(2), wake.changed())
            .await
            .expect("listener should receive notifications after delayed activation")
            .unwrap();

        listener.shutdown().await;
        listener_pool.close().await;
        admin_pool.close().await;
    }
}

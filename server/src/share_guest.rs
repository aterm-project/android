//! Guest auth domain: deliberate redemption, guest session cookie, one-use
//! connection tickets and the `/gateway/v1/connect` WebSocket.
//!
//! Guest routes never accept a Bearer token, and Bearer routes never read the
//! guest cookie. Every write requires the exact configured Origin, the
//! `X-Atermius-Guest: v1` header and `application/json`.
use std::{
    net::SocketAddr,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use axum::{
    Json,
    extract::{
        ConnectInfo, State,
        ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::{Instant, timeout},
};

use crate::{
    ApiError, AppState, cloud,
    share_links::{Link, LinkStatus, TargetRow, TargetState},
};

pub(crate) const GUEST_COOKIE: &str = "__Host-atermius-guest";
pub(crate) const GUEST_HEADER: &str = "x-atermius-guest";
const TICKET_TTL: i64 = 30;
const MAX_CONNECTIONS_PER_SESSION: i64 = 2;
const MAX_CONNECTION_SECONDS: i64 = 2 * 60 * 60;
// Revocation budget (documented bound 3 s; worst case here 2.5 s):
//   poll interval 1 s + bounded authorization check 1 s (fails closed)
//   + upstream drop (non-blocking) + guest close frame 500 ms.
// Broadcast wake-ups skip the poll wait.
const RECHECK_INTERVAL: Duration = Duration::from_secs(1);
const SETUP_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_GATEWAY_BYTES: u64 = 1024 * 1024 * 1024;
/// Bound for any single authorization recheck; a slow check fails closed.
const RECHECK_TIMEOUT: Duration = Duration::from_secs(1);
/// Bound for the close frame to a guest that may have stopped reading.
const CLOSE_TIMEOUT: Duration = Duration::from_millis(500);

// Close codes (documented in docs/cloud-collaboration-design/IMPLEMENTATION-ADR.md).
pub(crate) const CLOSE_PROTOCOL: u16 = 4400;
pub(crate) const CLOSE_AUTH: u16 = 4401;
pub(crate) const CLOSE_REVOKED: u16 = 4403;
pub(crate) const CLOSE_EXPIRED: u16 = 4408;
pub(crate) const CLOSE_LIMIT: u16 = 4429;
pub(crate) const CLOSE_TARGET: u16 = 4502;

fn not_found() -> ApiError {
    crate::share_links::unavailable()
}

/// Exactly one well-formed guest cookie, or none.
pub(crate) fn guest_cookie(headers: &HeaderMap) -> Option<String> {
    let mut found = None;
    for value in headers.get_all(header::COOKIE) {
        let text = value.to_str().ok()?;
        for part in text.split(';') {
            let part = part.trim();
            if let Some(token) = part.strip_prefix(GUEST_COOKIE).and_then(|rest| rest.strip_prefix('=')) {
                if found.is_some() || !cloud::is_token(token) {
                    return None;
                }
                found = Some(token.to_owned());
            }
        }
    }
    found
}

/// Enforces the guest auth domain on every guest HTTP request.
pub(crate) fn guest_guard(state: &AppState, headers: &HeaderMap, write: bool) -> Result<(), ApiError> {
    if !cloud::share_links_ready(state) {
        // Indistinguishable from an unknown link to avoid probing.
        return Err(not_found());
    }
    if headers.contains_key(header::AUTHORIZATION) {
        return Err(ApiError::bad_request(
            "GUEST_AUTH_DOMAIN",
            "guest routes do not accept account credentials",
        ));
    }
    let origin_present = headers.contains_key(header::ORIGIN);
    if (write || origin_present) && !cloud::exact_origin(state, headers) {
        return Err(ApiError::forbidden("GUEST_ORIGIN_DENIED", "request origin is not allowed"));
    }
    if headers
        .get("sec-fetch-site")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|site| site != "same-origin" && site != "none")
    {
        return Err(ApiError::forbidden("GUEST_ORIGIN_DENIED", "cross-site guest request"));
    }
    if headers.get(GUEST_HEADER).and_then(|v| v.to_str().ok()) != Some("v1") {
        return Err(ApiError::forbidden("GUEST_HEADER_REQUIRED", "guest marker header is required"));
    }
    if write {
        let content_type = headers
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let essence = content_type.split(';').next().unwrap_or("").trim();
        if !essence.eq_ignore_ascii_case("application/json") {
            return Err(ApiError::new(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "GUEST_CONTENT_TYPE",
                "guest requests must be application/json",
            ));
        }
    }
    Ok(())
}

fn cookie_header(token: &str, max_age: i64) -> HeaderValue {
    HeaderValue::from_str(&format!(
        "{GUEST_COOKIE}={token}; Max-Age={}; Path=/; Secure; HttpOnly; SameSite=Strict",
        max_age.max(0)
    ))
    .expect("cookie value is ASCII")
}

fn clear_cookie_header() -> HeaderValue {
    HeaderValue::from_static("__Host-atermius-guest=; Max-Age=0; Path=/; Secure; HttpOnly; SameSite=Strict")
}

fn rate_limited(retry: u64) -> ApiError {
    ApiError::new(StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED", "too many requests; try again later")
        .with_retry_after(retry)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RedeemRequest {
    slug: String,
    redeem_token: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EmptyRequest {}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectionRequest {
    /// The link address the guest page is showing; must be the cookie's link.
    slug: String,
    target_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionQuery {
    slug: String,
}

struct GuestSession {
    guest_session_id: String,
    link_id: String,
    secret_version: i64,
    expires: i64,
    last_seen: i64,
    revoked: Option<i64>,
}

async fn load_session_by_cookie_tx(
    tx: &mut Transaction<'_, Sqlite>,
    cookie: &str,
) -> Result<Option<GuestSession>, ApiError> {
    let row = sqlx::query(
        "SELECT guest_session_id,link_id,secret_version,expires_epoch,last_seen_epoch,revoked_epoch FROM share_guest_sessions WHERE cookie_hash=?",
    )
    .bind(cloud::token_hash(cookie))
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(row.map(|row| GuestSession {
        guest_session_id: row.get("guest_session_id"),
        link_id: row.get("link_id"),
        secret_version: row.get("secret_version"),
        expires: row.get("expires_epoch"),
        last_seen: row.get("last_seen_epoch"),
        revoked: row.get("revoked_epoch"),
    }))
}

impl GuestSession {
    fn live(&self, now: i64) -> bool {
        self.revoked.is_none() && now < self.expires && now - self.last_seen < cloud::GUEST_IDLE_SECONDS
    }
}

fn guest_view(link: &Link, session: &GuestSession, targets: &[TargetRow]) -> Value {
    json!({
        "link_id": link.link_id,
        "slug": link.slug,
        "secret_version": link.secret_version,
        "display_envelope": link.display_envelope,
        "valid_from": cloud::epoch_rfc3339(link.valid_from),
        "expires_at": cloud::epoch_rfc3339(link.expires),
        "session_expires_at": cloud::epoch_rfc3339(session.expires),
        "idle_timeout_seconds": cloud::GUEST_IDLE_SECONDS,
        "permissions": link.perms,
        "max_concurrent": link.max_concurrent,
        "targets": targets.iter().map(|t| json!({
            "target_id": t.target_id,
            "protocol": t.protocol,
            "available": matches!(t.state, TargetState::Ready),
        })).collect::<Vec<_>>(),
    })
}

pub async fn redeem(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(req): Json<RedeemRequest>,
) -> Result<Response, ApiError> {
    guest_guard(&state, &headers, true)?;
    let now = cloud::now_epoch();
    let ip = peer.ip();
    let fail_key = format!("redeem_fail:{ip}");
    state
        .cloud
        .rate
        .blocked(&fail_key, 5, 60, now)
        .map_err(rate_limited)?;
    let per_minute = state.cloud.config.redeem_ip_per_minute;
    state.cloud.rate.check(&format!("redeem:{ip}"), per_minute, 60, now).map_err(rate_limited)?;
    state.cloud.rate.check(&format!("redeem_h:{ip}"), per_minute * 6, 3600, now).map_err(rate_limited)?;
    state.cloud.rate.check("redeem_all", 600, 60, now).map_err(rate_limited)?;
    let failure = |state: &AppState| {
        // Unknown slugs/secrets only count toward rate limits; no per-attempt
        // audit rows are written (log amplification) and no slug is locked.
        state.cloud.rate.record(&fail_key, now);
        not_found()
    };
    let Ok(slug) = crate::share_links::normalize_slug(&req.slug) else {
        return Err(failure(&state));
    };
    if !cloud::is_token(&req.redeem_token) {
        return Err(failure(&state));
    }
    let presented_hash = cloud::token_hash(&req.redeem_token);
    let old_cookie = guest_cookie(&headers);

    let mut tx = cloud::begin_write(&state.db).await?;
    let link_id: Option<String> = sqlx::query_scalar("SELECT link_id FROM share_links WHERE slug=?")
        .bind(&slug)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(link_id) = link_id else {
        return Err(failure(&state));
    };
    let Some(link) = crate::share_links::load_link_tx(&mut tx, &link_id).await? else {
        return Err(failure(&state));
    };
    if !ct_eq(link.redeem_token_hash.as_bytes(), presented_hash.as_bytes())
        || link.status(now) == LinkStatus::Revoked
    {
        return Err(failure(&state));
    }
    // Secret verified: precise reasons may now be disclosed.
    if let Some(error) = link.status(now).guest_error(&link) {
        cloud::audit_tx(
            &mut tx,
            cloud::AuditEntry::vault(&link.vault_id, "share_link.redeem_denied")
                .link(&link.link_id)
                .result("failure")
                .detail(format!("code={} ip={}", error.body.code, cloud::ip_prefix(ip))),
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(error);
    }
    // Atomic, race-free redemption against max_redemptions and the window.
    let consumed = sqlx::query(
        "UPDATE share_links SET redemptions=redemptions+1 WHERE link_id=? AND state='active' AND redeem_token_hash=? AND valid_from_epoch<=? AND expires_epoch>? AND (max_redemptions IS NULL OR redemptions<max_redemptions)",
    )
    .bind(&link.link_id)
    .bind(&presented_hash)
    .bind(now)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if consumed.rows_affected() != 1 {
        cloud::audit_tx(
            &mut tx,
            cloud::AuditEntry::vault(&link.vault_id, "share_link.redeem_denied")
                .link(&link.link_id)
                .result("failure")
                .detail(format!("code=SHARE_LINK_EXHAUSTED ip={}", cloud::ip_prefix(ip))),
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::gone("SHARE_LINK_EXHAUSTED", "this link has already been used"));
    }
    // One guest session per browser: redeeming replaces the previous one.
    if let Some(old) = old_cookie.as_deref() {
        if let Some(previous) = load_session_by_cookie_tx(&mut tx, old).await? {
            sqlx::query(
                "UPDATE share_guest_sessions SET revoked_epoch=?,end_reason='replaced' WHERE guest_session_id=? AND revoked_epoch IS NULL",
            )
            .bind(now)
            .bind(&previous.guest_session_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            state
                .cloud
                .notify(cloud::RevocationEvent::GuestSession(previous.guest_session_id));
        }
    }
    let cookie = cloud::random_token();
    let guest_session_id = uuid::Uuid::new_v4().to_string();
    let expires = (now + link.session_lifetime).min(link.expires);
    sqlx::query(
        "INSERT INTO share_guest_sessions(guest_session_id,link_id,cookie_hash,secret_version,created_epoch,expires_epoch,last_seen_epoch,ip_prefix,ua_family) VALUES(?,?,?,?,?,?,?,?,?)",
    )
    .bind(&guest_session_id)
    .bind(&link.link_id)
    .bind(cloud::token_hash(&cookie))
    .bind(link.secret_version)
    .bind(now)
    .bind(expires)
    .bind(now)
    .bind(cloud::ip_prefix(ip))
    .bind(cloud::ua_family(&headers))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&link.vault_id, "share_link.redeemed")
            .link(&link.link_id)
            .guest(&guest_session_id)
            .detail(format!("ip={} ua={}", cloud::ip_prefix(ip), cloud::ua_family(&headers))),
        now,
    )
    .await?;
    let targets = crate::share_links::load_targets_tx(&mut tx, &state, &link.link_id).await?;
    let session = GuestSession {
        guest_session_id,
        link_id: link.link_id.clone(),
        secret_version: link.secret_version,
        expires,
        last_seen: now,
        revoked: None,
    };
    let body = guest_view(&link, &session, &targets);
    tx.commit().await.map_err(ApiError::internal)?;
    let mut response = (StatusCode::OK, Json(body)).into_response();
    response
        .headers_mut()
        .insert(header::SET_COOKIE, cookie_header(&cookie, expires - now));
    Ok(response)
}

/// Resolves the guest session for a request and checks it with the link.
/// Resolves the guest session for a request, bound to the link address the
/// page is showing. A cookie for link A never authorizes anything under the
/// address of link B (or an unknown address): that is reported exactly like
/// an unknown link, before any status of A is revealed.
async fn current_guest_tx(
    tx: &mut Transaction<'_, Sqlite>,
    headers: &HeaderMap,
    slug: &str,
    now: i64,
) -> Result<(GuestSession, Link), ApiError> {
    let Ok(slug) = crate::share_links::normalize_slug(slug) else {
        return Err(not_found());
    };
    let Some(cookie) = guest_cookie(headers) else {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_REQUIRED", "redeem the link first"));
    };
    let Some(session) = load_session_by_cookie_tx(tx, &cookie).await? else {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_REQUIRED", "redeem the link first"));
    };
    if !session.live(now) {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_ENDED", "this guest session has ended"));
    }
    let Some(link) = crate::share_links::load_link_tx(tx, &session.link_id).await? else {
        return Err(not_found());
    };
    if link.slug != slug {
        return Err(not_found());
    }
    if link.secret_version != session.secret_version {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_ENDED", "this guest session has ended"));
    }
    if let Some(error) = link.status(now).guest_error(&link) {
        return Err(error);
    }
    Ok((session, link))
}

pub async fn session(
    State(state): State<AppState>,
    headers: HeaderMap,
    query: Result<axum::extract::Query<SessionQuery>, axum::extract::rejection::QueryRejection>,
) -> Result<Json<Value>, ApiError> {
    guest_guard(&state, &headers, false)?;
    let Ok(axum::extract::Query(query)) = query else {
        return Err(not_found());
    };
    let now = cloud::now_epoch();
    let mut tx = cloud::begin_write(&state.db).await?;
    let (session, link) = current_guest_tx(&mut tx, &headers, &query.slug, now).await?;
    sqlx::query("UPDATE share_guest_sessions SET last_seen_epoch=? WHERE guest_session_id=?")
        .bind(now)
        .bind(&session.guest_session_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let targets = crate::share_links::load_targets_tx(&mut tx, &state, &link.link_id).await?;
    let body = guest_view(&link, &session, &targets);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(body))
}

pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(_): Json<EmptyRequest>,
) -> Result<Response, ApiError> {
    guest_guard(&state, &headers, true)?;
    let now = cloud::now_epoch();
    if let Some(cookie) = guest_cookie(&headers) {
        let mut tx = cloud::begin_write(&state.db).await?;
        if let Some(session) = load_session_by_cookie_tx(&mut tx, &cookie).await? {
            sqlx::query(
                "UPDATE share_guest_sessions SET revoked_epoch=?,end_reason='guest_logout' WHERE guest_session_id=? AND revoked_epoch IS NULL",
            )
            .bind(now)
            .bind(&session.guest_session_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            state
                .cloud
                .notify(cloud::RevocationEvent::GuestSession(session.guest_session_id));
        }
    }
    let mut response = (StatusCode::OK, Json(json!({"ended": true}))).into_response();
    response.headers_mut().insert(header::SET_COOKIE, clear_cookie_header());
    Ok(response)
}

/// Why a connection (new or established) is not authorized.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Denied {
    Revoked(&'static str),
    Expired(&'static str),
    NotYetValid,
    Stale,
    Exhausted,
    Concurrency,
    Missing,
}

impl Denied {
    fn http(self) -> ApiError {
        match self {
            Self::Revoked(reason) => ApiError::forbidden("SHARE_ACCESS_REVOKED", "access was revoked")
                .with_details(json!({"reason": reason})),
            Self::Expired(_) => ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_ENDED", "this guest session has ended"),
            Self::NotYetValid => ApiError::forbidden("SHARE_LINK_NOT_YET_VALID", "this link is not valid yet"),
            Self::Stale => ApiError::conflict("CAPSULE_STALE", "the owner changed this Host; ask them to refresh the share"),
            Self::Exhausted => ApiError::gone("SHARE_LINK_EXHAUSTED", "no connection attempts are left on this link"),
            Self::Concurrency => ApiError::new(StatusCode::TOO_MANY_REQUESTS, "SHARE_CONCURRENCY_LIMIT", "too many active connections for this link"),
            Self::Missing => not_found(),
        }
    }

    pub(crate) fn close(self) -> (u16, &'static str) {
        match self {
            Self::Revoked(reason) => (CLOSE_REVOKED, reason),
            Self::Expired(reason) => (CLOSE_EXPIRED, reason),
            Self::NotYetValid => (CLOSE_REVOKED, "not_yet_valid"),
            Self::Stale => (CLOSE_TARGET, "capsule_stale"),
            Self::Exhausted => (CLOSE_LIMIT, "exhausted"),
            Self::Concurrency => (CLOSE_LIMIT, "concurrency"),
            Self::Missing => (CLOSE_REVOKED, "target_unavailable"),
        }
    }
}

pub(crate) struct Authorized {
    pub(crate) link: Link,
    pub(crate) target: TargetRow,
    pub(crate) session_expires: i64,
}

/// The single authorization predicate for tickets, WebSocket consumption and
/// the 2-second recheck of established connections.
pub(crate) async fn authorize_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    guest_session_id: &str,
    target_id: &str,
    expected: Option<(i64, i64)>,
    now: i64,
    established: bool,
) -> Result<Authorized, Denied> {
    let row = sqlx::query(
        "SELECT link_id,secret_version,expires_epoch,last_seen_epoch,revoked_epoch,end_reason FROM share_guest_sessions WHERE guest_session_id=?",
    )
    .bind(guest_session_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(|_| Denied::Revoked("check_failed"))?
    .ok_or(Denied::Missing)?;
    let revoked: Option<i64> = row.get("revoked_epoch");
    if revoked.is_some() {
        return Err(Denied::Revoked("guest_session_ended"));
    }
    let session_expires: i64 = row.get("expires_epoch");
    if now >= session_expires {
        return Err(Denied::Expired("session_expired"));
    }
    if !established && now - row.get::<i64, _>("last_seen_epoch") >= cloud::GUEST_IDLE_SECONDS {
        return Err(Denied::Expired("session_idle"));
    }
    let link_id: String = row.get("link_id");
    let link = crate::share_links::load_link_tx(tx, &link_id)
        .await
        .map_err(|_| Denied::Revoked("check_failed"))?
        .ok_or(Denied::Missing)?;
    match link.status(now) {
        LinkStatus::Active => {}
        LinkStatus::Revoked => return Err(Denied::Revoked("link_revoked")),
        LinkStatus::Paused => return Err(Denied::Revoked("link_paused")),
        LinkStatus::Suspended(reason) => return Err(Denied::Revoked(reason)),
        LinkStatus::Expired => return Err(Denied::Expired("link_expired")),
        LinkStatus::NotYetValid => return Err(Denied::NotYetValid),
    }
    if row.get::<i64, _>("secret_version") != link.secret_version {
        return Err(Denied::Revoked("secret_rotated"));
    }
    if let Some((authz_revision, secret_version)) = expected
        && (authz_revision != link.authz_revision || secret_version != link.secret_version)
    {
        return Err(Denied::Revoked("policy_changed"));
    }
    let targets = crate::share_links::load_targets_tx(tx, state, &link.link_id)
        .await
        .map_err(|_| Denied::Revoked("check_failed"))?;
    let target = targets
        .into_iter()
        .find(|t| t.target_id == target_id)
        .ok_or(Denied::Missing)?;
    match target.state {
        TargetState::Ready => {}
        // An edited Host keeps already-negotiated sessions; new ones need a
        // fresh capsule from the owner.
        TargetState::HostChanged if established => {}
        TargetState::HostChanged => return Err(Denied::Stale),
        TargetState::HostDeleted => return Err(Denied::Revoked("host_deleted")),
        TargetState::KeyRetired => return Err(Denied::Revoked("gateway_key_retired")),
        TargetState::Revoked => return Err(Denied::Revoked("target_unavailable")),
        TargetState::SealerRevoked => return Err(Denied::Revoked("sealer_authority_lost")),
    }
    if !crate::share_gateway::protocol_allowed(state, &target.protocol) || !cloud::share_links_ready(state) {
        return Err(Denied::Revoked("policy_disabled"));
    }
    Ok(Authorized {
        link,
        target,
        session_expires,
    })
}

async fn live_connection_counts_tx(
    tx: &mut Transaction<'_, Sqlite>,
    link_id: &str,
    guest_session_id: &str,
    now: i64,
) -> Result<(i64, i64), ApiError> {
    sqlx::query_as(
        "SELECT (SELECT COUNT(*) FROM share_gateway_connections WHERE link_id=? AND ended_epoch IS NULL AND heartbeat_epoch>?),(SELECT COUNT(*) FROM share_gateway_connections WHERE guest_session_id=? AND ended_epoch IS NULL AND heartbeat_epoch>?)",
    )
    .bind(link_id)
    .bind(now - 60)
    .bind(guest_session_id)
    .bind(now - 60)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

pub async fn create_connection(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<ConnectionRequest>,
) -> Result<Json<Value>, ApiError> {
    guest_guard(&state, &headers, true)?;
    if !crate::is_canonical_uuid(&req.target_id) {
        return Err(not_found());
    }
    let now = cloud::now_epoch();
    // Read phase: authorize and learn the pinned target without holding the
    // SQLite writer during DNS resolution.
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (session, link) = current_guest_tx(&mut tx, &headers, &req.slug, now).await?;
    state
        .cloud
        .rate
        .check(&format!("ticket:{}", session.guest_session_id), 20, 60, now)
        .map_err(rate_limited)?;
    let auth = authorize_tx(&mut tx, &state, &session.guest_session_id, &req.target_id, None, now, false)
        .await
        .map_err(Denied::http)?;
    tx.commit().await.map_err(ApiError::internal)?;
    crate::share_gateway::resolve_target(
        &state,
        &link.owner_user_id,
        &auth.target.capsule.protocol,
        &auth.target.capsule.target_host,
        auth.target.capsule.target_port,
    )
    .await?;

    let mut tx = cloud::begin_write(&state.db).await?;
    let auth = authorize_tx(&mut tx, &state, &session.guest_session_id, &req.target_id, None, now, false)
        .await
        .map_err(Denied::http)?;
    // Cheap early refusals only. Issuing a ticket charges nothing: the
    // connection is counted against max_connections when the gateway admits
    // it (see `consume_ticket`), so a refused attempt never uses one up.
    if auth.link.connections_exhausted() {
        return Err(Denied::Exhausted.http());
    }
    let (link_live, session_live) =
        live_connection_counts_tx(&mut tx, &auth.link.link_id, &session.guest_session_id, now).await?;
    if link_live >= auth.link.max_concurrent || session_live >= MAX_CONNECTIONS_PER_SESSION {
        return Err(Denied::Concurrency.http());
    }
    let ticket = cloud::random_token();
    let expires = (now + TICKET_TTL).min(auth.session_expires).min(auth.link.expires);
    sqlx::query(
        "INSERT INTO share_gateway_tickets(ticket_hash,guest_session_id,link_id,target_id,authz_revision,secret_version,created_epoch,expires_epoch) VALUES(?,?,?,?,?,?,?,?)",
    )
    .bind(cloud::token_hash(&ticket))
    .bind(&session.guest_session_id)
    .bind(&auth.link.link_id)
    .bind(&req.target_id)
    .bind(auth.link.authz_revision)
    .bind(auth.link.secret_version)
    .bind(now)
    .bind(expires)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM share_gateway_tickets WHERE expires_epoch<?")
        .bind(now - 3600)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("UPDATE share_guest_sessions SET last_seen_epoch=? WHERE guest_session_id=?")
        .bind(now)
        .bind(&session.guest_session_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "ticket": ticket,
        "expires_at": cloud::epoch_rfc3339(expires),
        "connect_path": "/gateway/v1/connect",
    })))
}

fn ct_eq(left: &[u8], right: &[u8]) -> bool {
    left.len() == right.len() && left.iter().zip(right).fold(0_u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

pub async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<Response, ApiError> {
    if !cloud::share_links_ready(&state) {
        return Err(cloud::sharing_disabled());
    }
    if headers.contains_key(header::AUTHORIZATION) {
        return Err(ApiError::bad_request("GUEST_AUTH_DOMAIN", "guest gateway does not accept account credentials"));
    }
    // Guests are always browsers; Origin must be present and exact.
    if !cloud::exact_origin(&state, &headers) {
        return Err(ApiError::forbidden("ORIGIN_DENIED", "websocket origin is not allowed"));
    }
    let Some(cookie) = guest_cookie(&headers) else {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_REQUIRED", "redeem the link first"));
    };
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let session = load_session_by_cookie_tx(&mut tx, &cookie).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    let Some(session) = session.filter(|s| s.live(cloud::now_epoch())) else {
        return Err(ApiError::new(StatusCode::UNAUTHORIZED, "GUEST_SESSION_REQUIRED", "redeem the link first"));
    };
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(96 * 1024)
        .max_frame_size(96 * 1024)
        .on_upgrade(move |socket| gateway_socket(socket, state, session.guest_session_id))
        .into_response())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthenticateFrame {
    #[serde(rename = "type")]
    kind: String,
    ticket: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OpenFrame {
    #[serde(rename = "type")]
    kind: String,
    width: u16,
    height: u16,
}

async fn close(socket: &mut WebSocket, code: u16, reason: &'static str) {
    let _ = timeout(
        CLOSE_TIMEOUT,
        socket.send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        }))),
    )
    .await;
}

struct Consumed {
    connection_id: String,
    link: Link,
    target: TargetRow,
    session_expires: i64,
    /// Instance-wide guest connection slot, held for the connection's life.
    _slot: tokio::sync::OwnedSemaphorePermit,
}

/// Admits a gateway connection for a one-use ticket (G14).
///
/// Order: instance slot → (one write transaction) ticket lookup → current
/// authorization → link/session concurrency → atomic `max_connections`
/// charge → ticket consumption → connection row. Instance-capacity and
/// concurrency refusals leave the ticket unconsumed and the counter
/// unchanged (the guest may retry with the same ticket until it expires).
/// Authorization denials and an exhausted link burn the ticket. Once
/// admitted, the attempt counts even if the remote target, guacd or remote
/// authentication later fails.
async fn consume_ticket(
    state: &AppState,
    guest_session_id: &str,
    ticket: &str,
) -> Result<Consumed, (u16, &'static str)> {
    if !cloud::is_token(ticket) {
        return Err((CLOSE_AUTH, "invalid_ticket"));
    }
    fn fail<E>(_: E) -> (u16, &'static str) {
        (CLOSE_AUTH, "ticket_check_failed")
    }
    let Ok(slot) = state.cloud.guest_connection_slots.clone().try_acquire_owned() else {
        return Err((CLOSE_LIMIT, "instance_capacity"));
    };
    let now = cloud::now_epoch();
    let ticket_hash = cloud::token_hash(ticket);
    // Serializes admissions: the concurrency count, the charge and the
    // consumption below cannot interleave with another admission.
    let mut tx = cloud::begin_write(&state.db).await.map_err(fail)?;
    let row = sqlx::query(
        "SELECT link_id,target_id,authz_revision,secret_version FROM share_gateway_tickets WHERE ticket_hash=? AND consumed_epoch IS NULL AND expires_epoch>? AND guest_session_id=?",
    )
    .bind(&ticket_hash)
    .bind(now)
    .bind(guest_session_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(fail)?;
    let Some(row) = row else {
        return Err((CLOSE_AUTH, "invalid_ticket"));
    };
    async fn burn(tx: &mut Transaction<'_, Sqlite>, ticket_hash: &str, now: i64) -> Result<u64, sqlx::Error> {
        sqlx::query("UPDATE share_gateway_tickets SET consumed_epoch=? WHERE ticket_hash=? AND consumed_epoch IS NULL")
            .bind(now)
            .bind(ticket_hash)
            .execute(&mut **tx)
            .await
            .map(|done| done.rows_affected())
    }
    let target_id: String = row.get("target_id");
    let expected = (row.get::<i64, _>("authz_revision"), row.get::<i64, _>("secret_version"));
    let auth = match authorize_tx(&mut tx, state, guest_session_id, &target_id, Some(expected), now, false).await {
        Ok(auth) => auth,
        Err(denied) => {
            burn(&mut tx, &ticket_hash, now).await.map_err(fail)?;
            tx.commit().await.map_err(fail)?;
            return Err(denied.close());
        }
    };
    let (link_live, session_live) = live_connection_counts_tx(&mut tx, &auth.link.link_id, guest_session_id, now)
        .await
        .map_err(fail)?;
    if link_live >= auth.link.max_concurrent || session_live >= MAX_CONNECTIONS_PER_SESSION {
        // Rolled back: the ticket stays usable and nothing is charged.
        return Err(Denied::Concurrency.close());
    }
    let charged = sqlx::query(
        "UPDATE share_links SET connections=connections+1 WHERE link_id=? AND (max_connections IS NULL OR connections<max_connections)",
    )
    .bind(&auth.link.link_id)
    .execute(&mut *tx)
    .await
    .map_err(fail)?;
    if charged.rows_affected() != 1 {
        burn(&mut tx, &ticket_hash, now).await.map_err(fail)?;
        tx.commit().await.map_err(fail)?;
        return Err(Denied::Exhausted.close());
    }
    if burn(&mut tx, &ticket_hash, now).await.map_err(fail)? != 1 {
        return Err((CLOSE_AUTH, "invalid_ticket"));
    }
    let connection_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO share_gateway_connections(connection_id,link_id,guest_session_id,target_id,protocol,started_epoch,heartbeat_epoch) VALUES(?,?,?,?,?,?,?)",
    )
    .bind(&connection_id)
    .bind(&auth.link.link_id)
    .bind(guest_session_id)
    .bind(&target_id)
    .bind(&auth.target.protocol)
    .bind(now)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(fail)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&auth.link.vault_id, "gateway.connection_started")
            .link(&auth.link.link_id)
            .guest(guest_session_id)
            .connection(&connection_id)
            .detail(format!("protocol={} target_id={target_id}", auth.target.protocol)),
        now,
    )
    .await
    .map_err(fail)?;
    tx.commit().await.map_err(fail)?;
    Ok(Consumed {
        connection_id,
        link: auth.link,
        target: auth.target,
        session_expires: auth.session_expires,
        _slot: slot,
    })
}

async fn finish_connection(
    state: &AppState,
    consumed: &Consumed,
    guest_session_id: &str,
    reason: &str,
    bytes: (u64, u64),
) {
    let now = cloud::now_epoch();
    let result = async {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        sqlx::query(
            "UPDATE share_gateway_connections SET ended_epoch=?,end_reason=?,bytes_to_guest=?,bytes_from_guest=? WHERE connection_id=? AND ended_epoch IS NULL",
        )
        .bind(now)
        .bind(reason)
        .bind(bytes.0 as i64)
        .bind(bytes.1 as i64)
        .bind(&consumed.connection_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        cloud::audit_tx(
            &mut tx,
            cloud::AuditEntry::vault(&consumed.link.vault_id, "gateway.connection_ended")
                .link(&consumed.link.link_id)
                .guest(guest_session_id)
                .connection(&consumed.connection_id)
                .detail(format!("reason={reason} bytes_to_guest={} bytes_from_guest={}", bytes.0, bytes.1)),
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)
    }
    .await;
    if result.is_err() {
        tracing::warn!(event = "gateway_connection_finish_failed");
    }
}

/// Re-runs the authorization predicate for an established connection and
/// renews its heartbeat in the same transaction.
async fn recheck(
    state: &AppState,
    consumed: &Consumed,
    guest_session_id: &str,
    bytes: (u64, u64),
) -> Result<(), (u16, &'static str)> {
    #[cfg(test)]
    {
        let delay = state.cloud.test_recheck_delay();
        if !delay.is_zero() {
            tokio::time::sleep(delay).await;
        }
    }
    let now = cloud::now_epoch();
    fn fail<E>(_: E) -> (u16, &'static str) {
        (CLOSE_REVOKED, "check_failed")
    }
    let mut tx = state.db.begin().await.map_err(fail)?;
    let renewed = sqlx::query(
        "UPDATE share_gateway_connections SET heartbeat_epoch=?,bytes_to_guest=?,bytes_from_guest=? WHERE connection_id=? AND ended_epoch IS NULL",
    )
    .bind(now)
    .bind(bytes.0 as i64)
    .bind(bytes.1 as i64)
    .bind(&consumed.connection_id)
    .execute(&mut *tx)
    .await
    .map_err(fail)?;
    if renewed.rows_affected() != 1 {
        return Err((CLOSE_REVOKED, "connection_ended"));
    }
    sqlx::query("UPDATE share_guest_sessions SET last_seen_epoch=? WHERE guest_session_id=? AND revoked_epoch IS NULL")
        .bind(now)
        .bind(guest_session_id)
        .execute(&mut *tx)
        .await
        .map_err(fail)?;
    let result = authorize_tx(
        &mut tx,
        state,
        guest_session_id,
        &consumed.target.target_id,
        Some((consumed.link.authz_revision, consumed.link.secret_version)),
        now,
        true,
    )
    .await;
    tx.commit().await.map_err(fail)?;
    result.map(|_| ()).map_err(Denied::close)
}

fn event_matches(event: &cloud::RevocationEvent, link_id: &str, guest_session_id: &str) -> bool {
    match event {
        cloud::RevocationEvent::Link(id) => id == link_id,
        cloud::RevocationEvent::GuestSession(id) => id == guest_session_id,
    }
}

async fn gateway_socket(mut socket: WebSocket, state: Arc<AppState>, guest_session_id: String) {
    let mut revocations = state.cloud.revocations.subscribe();
    let ticket = match timeout(SETUP_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str::<AuthenticateFrame>(&text) {
            Ok(frame) if frame.kind == "authenticate" => frame.ticket,
            _ => return close(&mut socket, CLOSE_AUTH, "authenticate_required").await,
        },
        _ => return close(&mut socket, CLOSE_AUTH, "authenticate_required").await,
    };
    // Holds the instance slot (inside `consumed`) until the connection ends.
    let consumed = match consume_ticket(&state, &guest_session_id, &ticket).await {
        Ok(consumed) => consumed,
        Err((code, reason)) => return close(&mut socket, code, reason).await,
    };
    let started = cloud::now_epoch();
    let deadline_epoch = consumed
        .session_expires
        .min(consumed.link.expires)
        .min(started + MAX_CONNECTION_SECONDS);
    let authenticated = json!({
        "type": "authenticated",
        "connection_id": consumed.connection_id,
        "expires_at": cloud::epoch_rfc3339(deadline_epoch),
        "idle_timeout_seconds": cloud::GUEST_IDLE_SECONDS,
        "protocol": consumed.target.protocol,
        "permissions": consumed.link.perms,
    });
    if socket.send(Message::Text(authenticated.to_string().into())).await.is_err() {
        finish_connection(&state, &consumed, &guest_session_id, "client_gone", (0, 0)).await;
        return;
    }
    let (code, reason, bytes) = run_connection(&mut socket, &state, &consumed, &guest_session_id, deadline_epoch, &mut revocations).await;
    // Close the guest first (bounded even if the guest stopped reading), then
    // record the end of the connection.
    close(&mut socket, code, reason).await;
    finish_connection(&state, &consumed, &guest_session_id, reason, bytes).await;
}

/// Byte counters and input activity shared between the data pump and the
/// authorization watchdog, which run as two futures in the same task.
struct Meter {
    to_guest: AtomicU64,
    from_guest: AtomicU64,
    started: Instant,
    /// Milliseconds after `started` of the last guest input.
    last_input_ms: AtomicU64,
}

impl Meter {
    fn new() -> Self {
        Self {
            to_guest: AtomicU64::new(0),
            from_guest: AtomicU64::new(0),
            started: Instant::now(),
            last_input_ms: AtomicU64::new(0),
        }
    }
    fn bytes(&self) -> (u64, u64) {
        (self.to_guest.load(Ordering::Relaxed), self.from_guest.load(Ordering::Relaxed))
    }
    fn add_to_guest(&self, n: usize) -> u64 {
        self.to_guest.fetch_add(n as u64, Ordering::Relaxed) + n as u64
    }
    fn add_from_guest(&self, n: usize) -> u64 {
        self.last_input_ms.store(self.started.elapsed().as_millis() as u64, Ordering::Relaxed);
        self.from_guest.fetch_add(n as u64, Ordering::Relaxed) + n as u64
    }
    fn idle_for(&self) -> Duration {
        self.started
            .elapsed()
            .saturating_sub(Duration::from_millis(self.last_input_ms.load(Ordering::Relaxed)))
    }
}

/// Authorization watchdog. It never touches the guest socket or guacd
/// stream, so it keeps running while either is blocked: every 2 s and on
/// every relevant broadcast it re-evaluates the full authorization predicate
/// (bounded by RECHECK_TIMEOUT, failing closed), and it enforces the absolute
/// deadline and, once connected, the idle timeout. Whichever of watchdog and
/// I/O finishes first wins; the loser (including a pending blocked write) is
/// dropped.
async fn watchdog(
    state: &AppState,
    consumed: &Consumed,
    guest_session_id: &str,
    deadline: Instant,
    revocations: &mut tokio::sync::broadcast::Receiver<cloud::RevocationEvent>,
    meter: &Meter,
    enforce_idle: bool,
) -> (u16, &'static str) {
    let mut ticker = tokio::time::interval(RECHECK_INTERVAL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    ticker.tick().await;
    let idle = Duration::from_secs(cloud::GUEST_IDLE_SECONDS as u64);
    let check = || async {
        match timeout(RECHECK_TIMEOUT, recheck(state, consumed, guest_session_id, meter.bytes())).await {
            Ok(result) => result,
            Err(_) => Err((CLOSE_REVOKED, "check_timeout")),
        }
    };
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => return (CLOSE_EXPIRED, "expired"),
            _ = ticker.tick() => {
                if enforce_idle && meter.idle_for() > idle {
                    return (CLOSE_EXPIRED, "idle");
                }
                if let Err(reason) = check().await {
                    return reason;
                }
            }
            event = revocations.recv() => {
                let relevant = match event {
                    Ok(event) => event_matches(&event, &consumed.link.link_id, guest_session_id),
                    // Lagged: recheck to be safe.
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => true,
                    Err(_) => false,
                };
                if relevant && let Err(reason) = check().await {
                    return reason;
                }
            }
        }
    }
}

async fn revoke_mismatched_capsule(state: &AppState, consumed: &Consumed) {
    let capsule = &consumed.target.capsule;
    let now = cloud::now_epoch();
    let result = async {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        sqlx::query("UPDATE share_host_capsules SET state='revoked' WHERE vault_id=? AND host_record_id=?")
            .bind(&capsule.vault_id)
            .bind(&capsule.host_record_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        cloud::audit_tx(
            &mut tx,
            cloud::AuditEntry::vault(&capsule.vault_id, "host.capsule_mismatch")
                .link(&consumed.link.link_id)
                .result("failure")
                .detail(format!("host_record_id={}", capsule.host_record_id)),
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)
    }
    .await;
    if result.is_err() {
        tracing::warn!(event = "capsule_mismatch_revoke_failed");
    }
}

/// Everything up to a completed guacd handshake. Runs raced against the
/// watchdog, so a revocation during DNS, host-key discovery or a stalled
/// guacd handshake cancels it (and zeroizes the unsealed capsule on drop).
async fn setup_connection(
    socket: &mut WebSocket,
    state: &AppState,
    consumed: &Consumed,
    guest_session_id: &str,
    meter: &Meter,
) -> Result<TcpStream, (u16, &'static str)> {
    let open = match timeout(SETUP_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str::<OpenFrame>(&text) {
            Ok(frame) if frame.kind == "open" && (1..=8192).contains(&frame.width) && (1..=8192).contains(&frame.height) => frame,
            _ => return Err((CLOSE_PROTOCOL, "open_invalid")),
        },
        _ => return Err((CLOSE_PROTOCOL, "open_required")),
    };
    let capsule = &consumed.target.capsule;
    // Resolve again at connect time and pin the checked address.
    let ip = crate::share_gateway::resolve_target(
        state,
        &consumed.link.owner_user_id,
        &capsule.protocol,
        &capsule.target_host,
        capsule.target_port,
    )
    .await
    .map_err(|_| (CLOSE_TARGET, "target_denied"))?;
    let inner = match crate::share_gateway::unseal_capsule(state, capsule) {
        Ok(inner) => inner,
        Err(crate::share_gateway::UnsealError::Mismatch) => {
            revoke_mismatched_capsule(state, consumed).await;
            return Err((CLOSE_TARGET, "capsule_mismatch"));
        }
        Err(_) => return Err((CLOSE_TARGET, "capsule_unavailable")),
    };
    let known_host = if inner_protocol_is_ssh(capsule) {
        match crate::share_gateway::pinned_ssh_known_host(
            ip,
            capsule.target_port,
            inner_ssh_algorithm(&inner),
            capsule.host_identity.as_deref().unwrap_or(""),
        )
        .await
        {
            Ok(line) => Some(line),
            Err(()) => {
                cloud::audit(
                    state,
                    cloud::AuditEntry::vault(&capsule.vault_id, "gateway.host_key_rejected")
                        .link(&consumed.link.link_id)
                        .connection(&consumed.connection_id)
                        .result("failure"),
                    cloud::now_epoch(),
                )
                .await;
                return Err((CLOSE_TARGET, "host_key_rejected"));
            }
        }
    } else {
        None
    };
    // Authorization is re-evaluated immediately before credentials are sent.
    match timeout(RECHECK_TIMEOUT, recheck(state, consumed, guest_session_id, meter.bytes())).await {
        Ok(Ok(())) => {}
        Ok(Err(reason)) => return Err(reason),
        Err(_) => return Err((CLOSE_REVOKED, "check_timeout")),
    }
    let Some(guacd) = state.config.guacd_address.clone() else {
        return Err((CLOSE_TARGET, "gateway_unavailable"));
    };
    let mut tcp = match timeout(SETUP_TIMEOUT, TcpStream::connect(guacd)).await {
        Ok(Ok(stream)) => stream,
        _ => return Err((CLOSE_TARGET, "gateway_unavailable")),
    };
    let size = crate::share_gateway::clamp_display(state, &inner, open.width, open.height);
    let handshake = timeout(
        SETUP_TIMEOUT,
        crate::share_gateway::gateway_handshake(
            &mut tcp,
            &inner,
            ip,
            capsule.target_port,
            consumed.link.perms,
            size,
            known_host.as_deref(),
        ),
    )
    .await;
    drop(inner);
    if !matches!(handshake, Ok(Ok(()))) {
        return Err((CLOSE_TARGET, "gateway_handshake_failed"));
    }
    Ok(tcp)
}

async fn run_connection(
    socket: &mut WebSocket,
    state: &AppState,
    consumed: &Consumed,
    guest_session_id: &str,
    deadline_epoch: i64,
    revocations: &mut tokio::sync::broadcast::Receiver<cloud::RevocationEvent>,
) -> (u16, &'static str, (u64, u64)) {
    let meter = Meter::new();
    let deadline = Instant::now() + Duration::from_secs((deadline_epoch - cloud::now_epoch()).max(0) as u64);
    let tcp = tokio::select! {
        result = setup_connection(socket, state, consumed, guest_session_id, &meter) => match result {
            Ok(tcp) => tcp,
            Err((code, reason)) => return (code, reason, meter.bytes()),
        },
        (code, reason) = watchdog(state, consumed, guest_session_id, deadline, revocations, &meter, false) => {
            return (code, reason, meter.bytes());
        }
    };
    let (mut tcp_rx, mut tcp_tx) = tcp.into_split();
    let outcome = {
        let pump = pump(socket, &mut tcp_rx, &mut tcp_tx, state, consumed, deadline, deadline_epoch, &meter);
        tokio::select! {
            outcome = pump => outcome,
            outcome = watchdog(state, consumed, guest_session_id, deadline, revocations, &meter, true) => outcome,
        }
    };
    // Terminate the upstream promptly: a non-blocking best-effort
    // disconnect (never awaited on a full socket), then drop both halves.
    let _ = tcp_tx.try_write(crate::desktop::encode(&["disconnect"]).as_bytes());
    drop(tcp_tx);
    drop(tcp_rx);
    (outcome.0, outcome.1, meter.bytes())
}

/// Bidirectional data pump with permission filters. All socket operations
/// may block; cancellation is provided by the watchdog in `run_connection`.
#[allow(clippy::too_many_arguments)]
async fn pump(
    socket: &mut WebSocket,
    tcp_rx: &mut tokio::net::tcp::OwnedReadHalf,
    tcp_tx: &mut tokio::net::tcp::OwnedWriteHalf,
    state: &AppState,
    consumed: &Consumed,
    deadline: Instant,
    deadline_epoch: i64,
    meter: &Meter,
) -> (u16, &'static str) {
    let max = (state.cloud.config.max_display_width, state.cloud.config.max_display_height);
    let mut input = crate::share_gateway::InputFilter::new(consumed.link.perms, max);
    let mut output = crate::share_gateway::OutputFilter::new(consumed.link.perms.clipboard_from_remote);
    let mut buf = vec![0_u8; 16 * 1024];
    let warn_at = deadline.checked_sub(Duration::from_secs(300));
    let mut warned = warn_at.is_none();
    loop {
        // Always yield periodically so the watchdog runs even when both
        // directions are continuously ready.
        tokio::task::consume_budget().await;
        tokio::select! {
            _ = async { tokio::time::sleep_until(warn_at.unwrap()).await }, if !warned => {
                warned = true;
                let notice = json!({"type":"notice","code":"SESSION_EXPIRING","at":cloud::epoch_rfc3339(deadline_epoch)});
                if socket.send(Message::Text(notice.to_string().into())).await.is_err() {
                    return (CLOSE_PROTOCOL, "client_gone");
                }
            }
            inbound = socket.recv() => match inbound {
                Some(Ok(Message::Binary(bytes))) => {
                    let total = meter.add_from_guest(bytes.len());
                    let Some(allowed) = input.filter(&bytes) else {
                        return (CLOSE_PROTOCOL, "instruction_denied");
                    };
                    if total > MAX_GATEWAY_BYTES {
                        return (CLOSE_LIMIT, "byte_budget");
                    }
                    if !allowed.is_empty() && tcp_tx.write_all(&allowed).await.is_err() {
                        return (CLOSE_TARGET, "gateway_write_failed");
                    }
                }
                Some(Ok(Message::Ping(payload))) => {
                    if socket.send(Message::Pong(payload)).await.is_err() {
                        return (CLOSE_PROTOCOL, "client_gone");
                    }
                }
                Some(Ok(Message::Pong(_))) => {}
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return (1000, "client_closed"),
                // Text frames after setup (and anything else) are violations.
                Some(Ok(_)) => return (CLOSE_PROTOCOL, "unexpected_frame"),
            },
            read = tcp_rx.read(&mut buf) => match read {
                Ok(0) | Err(_) => return (1000, "remote_closed"),
                Ok(count) => {
                    let Ok(allowed) = output.push(&buf[..count]) else {
                        return (CLOSE_TARGET, "gateway_stream_invalid");
                    };
                    if meter.add_to_guest(allowed.len()) > MAX_GATEWAY_BYTES {
                        return (CLOSE_LIMIT, "byte_budget");
                    }
                    if !allowed.is_empty() && socket.send(Message::Binary(allowed.into())).await.is_err() {
                        return (CLOSE_PROTOCOL, "client_gone");
                    }
                }
            },
        }
    }
}

fn inner_protocol_is_ssh(capsule: &crate::share_gateway::CapsuleRow) -> bool {
    capsule.protocol == "ssh"
}

fn inner_ssh_algorithm(inner: &crate::share_gateway::CapsuleInner) -> &str {
    inner.ssh_host_key_algorithm()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guest_cookie_parser_requires_one_canonical_value() {
        let token = cloud::random_token();
        let mut headers = HeaderMap::new();
        headers.insert(header::COOKIE, format!("a=b; {GUEST_COOKIE}={token}").parse().unwrap());
        assert_eq!(guest_cookie(&headers).as_deref(), Some(token.as_str()));
        headers.insert(header::COOKIE, format!("{GUEST_COOKIE}={token}; {GUEST_COOKIE}={token}").parse().unwrap());
        assert_eq!(guest_cookie(&headers), None, "duplicate cookies are refused");
        headers.insert(header::COOKIE, format!("{GUEST_COOKIE}=short").parse().unwrap());
        assert_eq!(guest_cookie(&headers), None);
    }

    #[test]
    fn cookie_attributes_are_host_only_secure_http_only_strict() {
        let value = cookie_header("abc", 120).to_str().unwrap().to_owned();
        assert!(value.starts_with("__Host-atermius-guest=abc;"));
        for attribute in ["Max-Age=120", "Path=/", "Secure", "HttpOnly", "SameSite=Strict"] {
            assert!(value.contains(attribute), "{attribute}");
        }
        assert!(!value.to_ascii_lowercase().contains("domain"));
    }

    #[test]
    fn close_codes_follow_the_documented_contract() {
        assert_eq!(Denied::Revoked("link_revoked").close().0, 4403);
        assert_eq!(Denied::Expired("link_expired").close().0, 4408);
        assert_eq!(Denied::Concurrency.close().0, 4429);
        assert_eq!(Denied::Stale.close().0, 4502);
    }
}

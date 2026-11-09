//! Temporary share links: owner management (create/list/update/revoke/
//! rotate/activity/terminate) and the shared authorization evaluation used by
//! guest redemption, ticket issuance, WebSocket consumption and rechecks.
use axum::{
    Json,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction, sqlite::SqliteRow};
use unicode_normalization::UnicodeNormalization;

use crate::{ApiError, AppState, cloud, share_gateway::Permissions};

pub(crate) const MAX_TARGETS_PER_LINK: usize = 8;
const MAX_ACTIVE_LINKS_PER_VAULT: i64 = 200;
const MAX_ACTIVE_LINKS_PER_USER: i64 = 500;
const MAX_DISPLAY_ENVELOPE_CHARS: usize = 12 * 1024;
const SLUG_COOLDOWN_SECONDS: i64 = 7 * 24 * 60 * 60;
const LINK_RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const RESERVED_SLUGS: &[&str] = &[
    "admin", "api", "app", "assets", "auth", "canvaskit", "gateway", "guest", "health", "help",
    "join", "login", "logout", "new", "relay", "root", "s", "settings", "share", "static",
    "support", "www", "desktop", "collaboration", "index", "favicon", "manifest",
];

/// `SELECT` fragment for one link with a live check that its creator is still
/// the active owner of an active Vault. Every evaluation reuses it.
pub(crate) const LINK_SELECT: &str = "SELECT l.link_id,l.vault_id,l.owner_user_id,l.slug,l.slug_custom,l.redeem_token_hash,l.secret_version,l.display_envelope,l.state,l.suspend_reason,l.valid_from_epoch,l.expires_epoch,l.max_redemptions,l.redemptions,l.max_connections,l.connections,l.max_concurrent,l.session_lifetime_seconds,l.clipboard_to_remote,l.clipboard_from_remote,l.view_only,l.authz_revision,l.revision,l.request_digest,l.created_epoch,l.updated_epoch,l.revoked_epoch, \
     EXISTS(SELECT 1 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=l.vault_id AND v.state='active' AND vm.user_id=l.owner_user_id AND vm.role='owner' AND vm.state='active' AND u.status='active') AS owner_ok \
     FROM share_links l";

#[derive(Debug, Clone)]
pub(crate) struct Link {
    pub(crate) link_id: String,
    pub(crate) vault_id: String,
    pub(crate) owner_user_id: String,
    pub(crate) slug: String,
    pub(crate) slug_custom: bool,
    pub(crate) redeem_token_hash: String,
    pub(crate) secret_version: i64,
    pub(crate) display_envelope: String,
    pub(crate) state: String,
    pub(crate) suspend_reason: Option<String>,
    pub(crate) valid_from: i64,
    pub(crate) expires: i64,
    pub(crate) max_redemptions: Option<i64>,
    pub(crate) redemptions: i64,
    pub(crate) max_connections: Option<i64>,
    pub(crate) connections: i64,
    pub(crate) max_concurrent: i64,
    pub(crate) session_lifetime: i64,
    pub(crate) perms: Permissions,
    pub(crate) authz_revision: i64,
    pub(crate) revision: i64,
    pub(crate) request_digest: String,
    pub(crate) created: i64,
    pub(crate) owner_ok: bool,
}

impl Link {
    pub(crate) fn from_row(row: &SqliteRow) -> Self {
        Self {
            link_id: row.get("link_id"),
            vault_id: row.get("vault_id"),
            owner_user_id: row.get("owner_user_id"),
            slug: row.get("slug"),
            slug_custom: row.get::<i64, _>("slug_custom") == 1,
            redeem_token_hash: row.get("redeem_token_hash"),
            secret_version: row.get("secret_version"),
            display_envelope: row.get("display_envelope"),
            state: row.get("state"),
            suspend_reason: row.get("suspend_reason"),
            valid_from: row.get("valid_from_epoch"),
            expires: row.get("expires_epoch"),
            max_redemptions: row.get("max_redemptions"),
            redemptions: row.get("redemptions"),
            max_connections: row.get("max_connections"),
            connections: row.get("connections"),
            max_concurrent: row.get("max_concurrent"),
            session_lifetime: row.get("session_lifetime_seconds"),
            perms: Permissions {
                clipboard_to_remote: row.get::<i64, _>("clipboard_to_remote") == 1,
                clipboard_from_remote: row.get::<i64, _>("clipboard_from_remote") == 1,
                view_only: row.get::<i64, _>("view_only") == 1,
            },
            authz_revision: row.get("authz_revision"),
            revision: row.get("revision"),
            request_digest: row.get("request_digest"),
            created: row.get("created_epoch"),
            owner_ok: row.get::<i64, _>("owner_ok") == 1,
        }
    }

    /// Externally visible status. Order matters: revocation and suspension
    /// dominate time, which dominates counters.
    pub(crate) fn status(&self, now: i64) -> LinkStatus {
        if self.state == "revoked" {
            LinkStatus::Revoked
        } else if !self.owner_ok {
            LinkStatus::Suspended("creator_lost_access")
        } else if self.state == "suspended" {
            LinkStatus::Suspended("suspended")
        } else if self.state == "paused" {
            LinkStatus::Paused
        } else if now >= self.expires {
            LinkStatus::Expired
        } else if now < self.valid_from {
            LinkStatus::NotYetValid
        } else {
            LinkStatus::Active
        }
    }

    #[cfg(test)]
    pub(crate) fn redemptions_exhausted(&self) -> bool {
        self.max_redemptions.is_some_and(|max| self.redemptions >= max)
    }

    pub(crate) fn connections_exhausted(&self) -> bool {
        self.max_connections.is_some_and(|max| self.connections >= max)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LinkStatus {
    Active,
    NotYetValid,
    Expired,
    Paused,
    Suspended(&'static str),
    Revoked,
}

impl LinkStatus {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::NotYetValid => "not_yet_valid",
            Self::Expired => "expired",
            Self::Paused => "paused",
            Self::Suspended(_) => "suspended",
            Self::Revoked => "revoked",
        }
    }

    /// Guest-facing error for a link whose secret was already verified.
    pub(crate) fn guest_error(self, link: &Link) -> Option<ApiError> {
        match self {
            Self::Active => None,
            Self::Revoked => Some(unavailable()),
            Self::NotYetValid => Some(
                ApiError::forbidden("SHARE_LINK_NOT_YET_VALID", "this link is not valid yet")
                    .with_details(json!({"valid_from": cloud::epoch_rfc3339(link.valid_from)})),
            ),
            Self::Expired => Some(ApiError::gone("SHARE_LINK_EXPIRED", "this link has expired")),
            Self::Paused => Some(
                ApiError::forbidden("SHARE_LINK_SUSPENDED", "this link is paused by its owner")
                    .with_details(json!({"reason": "paused"})),
            ),
            Self::Suspended(reason) => Some(
                ApiError::forbidden("SHARE_LINK_SUSPENDED", "this link is suspended")
                    .with_details(json!({"reason": reason})),
            ),
        }
    }
}

pub(crate) fn unavailable() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "SHARE_LINK_UNAVAILABLE",
        "this link is not available",
    )
}

pub(crate) async fn load_link_tx(
    tx: &mut Transaction<'_, Sqlite>,
    link_id: &str,
) -> Result<Option<Link>, ApiError> {
    let row = sqlx::query(&format!("{LINK_SELECT} WHERE l.link_id=?"))
        .bind(link_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(row.as_ref().map(Link::from_row))
}

/// Capsule freshness for one link target, evaluated against the current Host
/// head and active gateway key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TargetState {
    Ready,
    HostChanged,
    HostDeleted,
    KeyRetired,
    Revoked,
    SealerRevoked,
}

impl TargetState {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::HostChanged => "stale_host_revision",
            Self::HostDeleted => "host_deleted",
            Self::KeyRetired => "stale_gateway_key",
            Self::Revoked => "revoked",
            Self::SealerRevoked => "sealer_authority_lost",
        }
    }
}

pub(crate) struct TargetRow {
    pub(crate) target_id: String,
    pub(crate) host_record_id: String,
    pub(crate) protocol: String,
    pub(crate) state: TargetState,
    pub(crate) capsule: crate::share_gateway::CapsuleRow,
}

pub(crate) async fn load_targets_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    link_id: &str,
) -> Result<Vec<TargetRow>, ApiError> {
    let active_key = state
        .cloud
        .gateway
        .as_ref()
        .map(|key| key.key_id.clone())
        .unwrap_or_default();
    let rows = sqlx::query(
        "SELECT t.target_id,t.host_record_id,c.vault_id,c.host_revision_id,c.gateway_key_id,c.protocol,c.target_host,c.target_port,c.header_json,c.sealed,c.state AS capsule_state,h.revision_id AS head_revision,h.deleted AS head_deleted,EXISTS(SELECT 1 FROM devices d JOIN users u ON u.user_id=d.user_id JOIN vault_members vm ON vm.user_id=d.user_id JOIN vaults v ON v.vault_id=vm.vault_id WHERE d.device_id=c.sealer_device_id AND d.user_id=c.sealer_user_id AND d.status='active' AND u.status='active' AND vm.vault_id=c.vault_id AND vm.state='active' AND vm.role='owner' AND v.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id)) AS sealer_ok \
         FROM share_link_targets t JOIN share_host_capsules c ON c.vault_id=t.vault_id AND c.host_record_id=t.host_record_id \
         LEFT JOIN record_heads h ON h.vault_id=c.vault_id AND h.record_id=c.host_record_id \
         WHERE t.link_id=? ORDER BY t.position",
    )
    .bind(link_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut targets = Vec::with_capacity(rows.len());
    for row in rows {
        let head_revision: Option<String> = row.get("head_revision");
        let head_deleted: Option<i64> = row.get("head_deleted");
        let capsule_state: String = row.get("capsule_state");
        let host_revision_id: String = row.get("host_revision_id");
        let gateway_key_id: String = row.get("gateway_key_id");
        // The sealing device must still be active and belong to the active
        // user who sealed it, and that user must still be the Vault owner.
        let sealer_ok = row.get::<i64, _>("sealer_ok") == 1;
        let target_state = if capsule_state != "active" {
            TargetState::Revoked
        } else if !sealer_ok {
            TargetState::SealerRevoked
        } else if head_revision.is_none() || head_deleted.unwrap_or(1) != 0 {
            TargetState::HostDeleted
        } else if gateway_key_id != active_key {
            TargetState::KeyRetired
        } else if head_revision.as_deref() != Some(host_revision_id.as_str()) {
            TargetState::HostChanged
        } else {
            TargetState::Ready
        };
        let header: crate::share_gateway::CapsuleHeader =
            serde_json::from_str(&row.get::<String, _>("header_json")).map_err(ApiError::internal)?;
        let port: i64 = row.get("target_port");
        targets.push(TargetRow {
            target_id: row.get("target_id"),
            host_record_id: row.get("host_record_id"),
            protocol: row.get("protocol"),
            state: target_state,
            capsule: crate::share_gateway::CapsuleRow {
                vault_id: row.get("vault_id"),
                host_record_id: row.get("host_record_id"),
                host_revision_id,
                gateway_key_id,
                protocol: row.get("protocol"),
                target_host: row.get("target_host"),
                target_port: u16::try_from(port).map_err(ApiError::internal)?,
                host_identity: header.host_identity,
                sealed: row.get("sealed"),
            },
        });
    }
    Ok(targets)
}

/// Revokes a link: state, revision bump, outstanding tickets deleted, guest
/// sessions ended. Callers notify the broadcast after commit.
pub(crate) async fn revoke_link_tx(
    tx: &mut Transaction<'_, Sqlite>,
    link_id: &str,
    now: i64,
    reason: &str,
) -> Result<bool, ApiError> {
    let updated = sqlx::query(
        "UPDATE share_links SET state='revoked',revoked_epoch=?,authz_revision=authz_revision+1,revision=revision+1,updated_epoch=? WHERE link_id=? AND state<>'revoked'",
    )
    .bind(now)
    .bind(now)
    .bind(link_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    end_link_sessions_tx(tx, link_id, now, reason).await?;
    Ok(updated.rows_affected() == 1)
}

async fn end_link_sessions_tx(
    tx: &mut Transaction<'_, Sqlite>,
    link_id: &str,
    now: i64,
    reason: &str,
) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM share_gateway_tickets WHERE link_id=? AND consumed_epoch IS NULL")
        .bind(link_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(
        "UPDATE share_guest_sessions SET revoked_epoch=?,end_reason=? WHERE link_id=? AND revoked_epoch IS NULL",
    )
    .bind(now)
    .bind(reason)
    .bind(link_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

/// Distinguishes an absent field (`None`) from an explicit JSON `null`
/// (`Some(None)`), so "unlimited" must be chosen deliberately.
fn explicit_option<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Option<i64>>, D::Error> {
    Option::<i64>::deserialize(deserializer).map(Some)
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct TargetRequest {
    target_id: String,
    host_record_id: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct CreateLinkRequest {
    link_id: String,
    #[serde(default)]
    slug: Option<String>,
    redeem_token: String,
    display_envelope: String,
    #[serde(default)]
    valid_from: Option<String>,
    #[serde(default)]
    expires_at: Option<String>,
    #[serde(default, deserialize_with = "explicit_option")]
    max_redemptions: Option<Option<i64>>,
    #[serde(default, deserialize_with = "explicit_option")]
    max_connections: Option<Option<i64>>,
    #[serde(default)]
    max_concurrent: Option<i64>,
    #[serde(default)]
    session_lifetime_seconds: Option<i64>,
    #[serde(default)]
    clipboard_to_remote: bool,
    #[serde(default)]
    clipboard_from_remote: bool,
    #[serde(default)]
    view_only: bool,
    targets: Vec<TargetRequest>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateLinkRequest {
    expected_revision: i64,
    #[serde(default)]
    state: Option<String>,
    #[serde(default)]
    valid_from: Option<String>,
    #[serde(default)]
    expires_at: Option<String>,
    #[serde(default, deserialize_with = "explicit_option")]
    max_redemptions: Option<Option<i64>>,
    #[serde(default, deserialize_with = "explicit_option")]
    max_connections: Option<Option<i64>>,
    #[serde(default)]
    max_concurrent: Option<i64>,
    #[serde(default)]
    clipboard_to_remote: Option<bool>,
    #[serde(default)]
    clipboard_from_remote: Option<bool>,
    #[serde(default)]
    view_only: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RotateRequest {
    expected_revision: i64,
    redeem_token: String,
    display_envelope: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RevokeRequest {
    #[serde(default)]
    expected_revision: Option<i64>,
}

// ---------------------------------------------------------------------------
// Validation helpers
// ---------------------------------------------------------------------------

pub(crate) fn normalize_slug(raw: &str) -> Result<String, ApiError> {
    let invalid = || {
        ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "SLUG_INVALID",
            "use 3–48 lowercase letters, digits or inner hyphens",
        )
    };
    if raw.len() > 192 {
        return Err(invalid());
    }
    let slug = raw.nfkc().collect::<String>().to_lowercase();
    let bytes = slug.as_bytes();
    let valid = (3..=48).contains(&bytes.len())
        && bytes.iter().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-')
        && bytes.first().is_some_and(|b| *b != b'-')
        && bytes.last().is_some_and(|b| *b != b'-')
        && !slug.contains("--");
    if !valid || RESERVED_SLUGS.contains(&slug.as_str()) {
        return Err(invalid());
    }
    Ok(slug)
}

fn random_slug() -> String {
    use rand::Rng;
    const ALPHABET: &[u8] = b"abcdefghijkmnpqrstuvwxyz23456789";
    let mut rng = rand::thread_rng();
    (0..12)
        .map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char)
        .collect()
}

async fn slug_available_tx(
    tx: &mut Transaction<'_, Sqlite>,
    slug: &str,
    now: i64,
) -> Result<bool, ApiError> {
    let taken: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM share_links WHERE slug=?) OR EXISTS(SELECT 1 FROM share_slug_reservations WHERE slug=? AND released_epoch>?)",
    )
    .bind(slug)
    .bind(slug)
    .bind(now - SLUG_COOLDOWN_SECONDS)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(!taken)
}

/// Removes links retained past the audit window and reserves their slugs.
async fn purge_old_links_tx(tx: &mut Transaction<'_, Sqlite>, now: i64) -> Result<(), ApiError> {
    let cutoff = now - LINK_RETENTION_SECONDS;
    sqlx::query(
        "INSERT INTO share_slug_reservations(slug,released_epoch) SELECT slug,? FROM share_links WHERE (revoked_epoch IS NOT NULL AND revoked_epoch<?) OR expires_epoch<? \
         ON CONFLICT(slug) DO UPDATE SET released_epoch=excluded.released_epoch",
    )
    .bind(now)
    .bind(cutoff)
    .bind(cutoff)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM share_links WHERE (revoked_epoch IS NOT NULL AND revoked_epoch<?) OR expires_epoch<?")
        .bind(cutoff)
        .bind(cutoff)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM share_slug_reservations WHERE released_epoch<?")
        .bind(now - SLUG_COOLDOWN_SECONDS)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

fn invalid_link(message: &str) -> ApiError {
    ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "SHARE_LINK_INVALID", message)
}

fn validate_envelope(value: &str) -> Result<(), ApiError> {
    if value.is_empty()
        || value.len() > MAX_DISPLAY_ENVELOPE_CHARS
        || !value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
    {
        return Err(invalid_link("display envelope must be a bounded opaque base64url string"));
    }
    Ok(())
}

fn validate_counter(value: Option<i64>, max: i64, field: &str) -> Result<Option<i64>, ApiError> {
    match value {
        Some(v) if !(1..=max).contains(&v) => Err(invalid_link(&format!("{field} is out of range"))),
        other => Ok(other),
    }
}

struct Window {
    valid_from: i64,
    expires: i64,
}

fn validate_window(
    state: &AppState,
    valid_from: Option<&str>,
    expires_at: Option<&str>,
    created: i64,
    now: i64,
    default_from: i64,
) -> Result<Window, ApiError> {
    let valid_from = match valid_from {
        Some(text) => cloud::parse_rfc3339_epoch(text).ok_or_else(|| invalid_link("valid_from must be RFC 3339"))?,
        None => default_from,
    };
    let expires = match expires_at {
        Some(text) => cloud::parse_rfc3339_epoch(text).ok_or_else(|| invalid_link("expires_at must be RFC 3339"))?,
        None => valid_from.max(now) + cloud::DEFAULT_LINK_LIFETIME_SECONDS,
    };
    if valid_from < created - 60 || valid_from > now + 365 * 24 * 60 * 60 {
        return Err(invalid_link("valid_from is outside the allowed range"));
    }
    if expires <= valid_from || expires <= now {
        return Err(invalid_link("expires_at must be after valid_from and in the future"));
    }
    if expires - created > state.cloud.config.max_link_lifetime_seconds {
        return Err(invalid_link("link lifetime exceeds the instance maximum").with_details(
            json!({"max_lifetime_seconds": state.cloud.config.max_link_lifetime_seconds}),
        ));
    }
    Ok(Window { valid_from, expires })
}

async fn require_owner_write_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &crate::auth::AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(vault_id) {
        return Err(ApiError::not_found());
    }
    let (role, _, _) = crate::require_authenticated_vault_write_tx(tx, user, vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    Ok(())
}

/// Loads a link that must belong to `vault_id`; any mismatch is a 404 so a
/// link ID of another Vault cannot be substituted into this path.
async fn link_in_vault_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    link_id: &str,
) -> Result<Link, ApiError> {
    match load_link_tx(tx, link_id).await? {
        Some(link) if link.vault_id == vault_id => Ok(link),
        _ => Err(ApiError::not_found()),
    }
}

async fn active_counts_tx(
    tx: &mut Transaction<'_, Sqlite>,
    link_id: &str,
    now: i64,
) -> Result<(i64, i64), ApiError> {
    let sessions: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM share_guest_sessions WHERE link_id=? AND revoked_epoch IS NULL AND expires_epoch>?",
    )
    .bind(link_id)
    .bind(now)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let connections: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM share_gateway_connections WHERE link_id=? AND ended_epoch IS NULL AND heartbeat_epoch>?",
    )
    .bind(link_id)
    .bind(now - 60)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok((sessions, connections))
}

async fn link_json_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    link: &Link,
    now: i64,
) -> Result<Value, ApiError> {
    let targets = load_targets_tx(tx, state, &link.link_id).await?;
    let (active_sessions, active_connections) = active_counts_tx(tx, &link.link_id, now).await?;
    let status = link.status(now);
    Ok(json!({
        "link_id": link.link_id,
        "vault_id": link.vault_id,
        "slug": link.slug,
        "slug_custom": link.slug_custom,
        "path": format!("/s/{}", link.slug),
        "status": status.as_str(),
        "suspend_reason": match status { LinkStatus::Suspended(reason) => Some(reason.to_owned()), _ => link.suspend_reason.clone() },
        "valid_from": cloud::epoch_rfc3339(link.valid_from),
        "expires_at": cloud::epoch_rfc3339(link.expires),
        "max_redemptions": link.max_redemptions,
        "redemptions": link.redemptions,
        "max_connections": link.max_connections,
        "connections": link.connections,
        "max_concurrent": link.max_concurrent,
        "session_lifetime_seconds": link.session_lifetime,
        "permissions": link.perms,
        "secret_version": link.secret_version,
        "revision": link.revision,
        "created_at": cloud::epoch_rfc3339(link.created),
        "active_sessions": active_sessions,
        "active_connections": active_connections,
        "display_envelope": link.display_envelope,
        "targets": targets.iter().map(|t| json!({
            "target_id": t.target_id,
            "host_record_id": t.host_record_id,
            "protocol": t.protocol,
            "status": t.state.as_str(),
        })).collect::<Vec<_>>(),
    }))
}

fn require_ready(state: &AppState) -> Result<(), ApiError> {
    if cloud::share_links_ready(state) {
        Ok(())
    } else {
        Err(cloud::sharing_disabled())
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

pub async fn create_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Json(req): Json<CreateLinkRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !crate::is_canonical_uuid(&req.link_id) {
        return Err(invalid_link("link_id must be a canonical UUID"));
    }
    if !cloud::is_token(&req.redeem_token) {
        return Err(invalid_link("redeem_token must be 32 random bytes in base64url"));
    }
    validate_envelope(&req.display_envelope)?;
    if req.targets.is_empty() || req.targets.len() > MAX_TARGETS_PER_LINK {
        return Err(invalid_link("a link needs between 1 and 8 targets"));
    }
    let mut seen = std::collections::HashSet::new();
    for target in &req.targets {
        if !crate::is_canonical_uuid(&target.target_id)
            || !crate::is_canonical_uuid(&target.host_record_id)
            || !seen.insert(target.host_record_id.clone())
            || !seen.insert(target.target_id.clone())
        {
            return Err(invalid_link("targets must be distinct canonical UUIDs"));
        }
    }
    let max_redemptions = validate_counter(req.max_redemptions.unwrap_or(Some(1)), 1000, "max_redemptions")?;
    let max_connections = validate_counter(req.max_connections.unwrap_or(None), 100_000, "max_connections")?;
    let max_concurrent = req.max_concurrent.unwrap_or(1);
    if !(1..=10).contains(&max_concurrent) {
        return Err(invalid_link("max_concurrent must be between 1 and 10"));
    }
    let session_lifetime = req
        .session_lifetime_seconds
        .unwrap_or(cloud::DEFAULT_GUEST_SESSION_SECONDS);
    if !(300..=cloud::MAX_GUEST_SESSION_SECONDS).contains(&session_lifetime) {
        return Err(invalid_link("session_lifetime_seconds must be between 300 and 43200"));
    }
    let digest = crate::sha256_hex(&crate::jcs(&req)?);
    let now = cloud::now_epoch();
    let window = validate_window(
        &state,
        req.valid_from.as_deref(),
        req.expires_at.as_deref(),
        now,
        now,
        now,
    )?;
    let requested_slug = req.slug.as_deref().map(normalize_slug).transpose()?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_owner_write_tx(&mut tx, &user, &vault_id).await?;
    if let Some(existing) = load_link_tx(&mut tx, &req.link_id).await? {
        // Idempotent replay of the same request returns the original link.
        if existing.vault_id == vault_id
            && existing.owner_user_id == user.user_id
            && existing.request_digest == digest
        {
            let body = link_json_tx(&mut tx, &state, &existing, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok((StatusCode::OK, Json(body)));
        }
        return Err(ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "this link_id was already used for a different request",
        ));
    }
    purge_old_links_tx(&mut tx, now).await?;
    let (vault_links, user_links): (i64, i64) = sqlx::query_as(
        "SELECT (SELECT COUNT(*) FROM share_links WHERE vault_id=? AND state IN ('active','paused','suspended') AND expires_epoch>?),(SELECT COUNT(*) FROM share_links WHERE owner_user_id=? AND state IN ('active','paused','suspended') AND expires_epoch>?)",
    )
    .bind(&vault_id)
    .bind(now)
    .bind(&user.user_id)
    .bind(now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if vault_links >= MAX_ACTIVE_LINKS_PER_VAULT || user_links >= MAX_ACTIVE_LINKS_PER_USER {
        return Err(ApiError::conflict("SHARE_LINK_LIMIT", "too many active links"));
    }
    let (slug, custom) = match requested_slug {
        Some(slug) => {
            if !slug_available_tx(&mut tx, &slug, now).await? {
                return Err(ApiError::conflict("SLUG_TAKEN", "this link address is not available"));
            }
            (slug, true)
        }
        None => {
            let mut chosen = None;
            for _ in 0..8 {
                let candidate = random_slug();
                if slug_available_tx(&mut tx, &candidate, now).await? {
                    chosen = Some(candidate);
                    break;
                }
            }
            (chosen.ok_or_else(|| ApiError::internal("random slug space exhausted"))?, false)
        }
    };
    sqlx::query(
        "INSERT INTO share_links(link_id,vault_id,owner_user_id,slug,slug_custom,redeem_token_hash,secret_version,display_envelope,state,valid_from_epoch,expires_epoch,max_redemptions,max_connections,max_concurrent,session_lifetime_seconds,clipboard_to_remote,clipboard_from_remote,view_only,request_digest,created_epoch,updated_epoch) \
         VALUES(?,?,?,?,?,?,1,?,'active',?,?,?,?,?,?,?,?,?,?,?,?)",
    )
    .bind(&req.link_id)
    .bind(&vault_id)
    .bind(&user.user_id)
    .bind(&slug)
    .bind(i64::from(custom))
    .bind(cloud::token_hash(&req.redeem_token))
    .bind(&req.display_envelope)
    .bind(window.valid_from)
    .bind(window.expires)
    .bind(max_redemptions)
    .bind(max_connections)
    .bind(max_concurrent)
    .bind(session_lifetime)
    .bind(i64::from(req.clipboard_to_remote))
    .bind(i64::from(req.clipboard_from_remote))
    .bind(i64::from(req.view_only))
    .bind(&digest)
    .bind(now)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for (position, target) in req.targets.iter().enumerate() {
        // The composite foreign key requires a capsule for this Host in this
        // Vault; a Host ID from another Vault therefore cannot be inserted.
        let capsule: Option<String> = sqlx::query_scalar(
            "SELECT capsule_id FROM share_host_capsules WHERE vault_id=? AND host_record_id=?",
        )
        .bind(&vault_id)
        .bind(&target.host_record_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if capsule.is_none() {
            return Err(ApiError::not_found());
        }
        sqlx::query(
            "INSERT INTO share_link_targets(link_id,vault_id,target_id,host_record_id,position) VALUES(?,?,?,?,?)",
        )
        .bind(&req.link_id)
        .bind(&vault_id)
        .bind(&target.target_id)
        .bind(&target.host_record_id)
        .bind(position as i64)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }
    let link = load_link_tx(&mut tx, &req.link_id)
        .await?
        .ok_or_else(|| ApiError::internal("inserted link missing"))?;
    let body = link_json_tx(&mut tx, &state, &link, now).await?;
    if body["targets"]
        .as_array()
        .is_some_and(|targets| targets.iter().any(|t| t["status"] != "ready"))
    {
        return Err(ApiError::conflict(
            "CAPSULE_STALE",
            "a target Host changed or its gateway capsule is stale; reseal it first",
        ));
    }
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "share_link.created")
            .link(&req.link_id)
            .actor(&user.user_id)
            .detail(format!(
                "targets={} max_redemptions={} view_only={} clipboard_to_remote={} clipboard_from_remote={} custom_slug={custom}",
                req.targets.len(),
                max_redemptions.map_or("unlimited".to_owned(), |v| v.to_string()),
                req.view_only,
                req.clipboard_to_remote,
                req.clipboard_from_remote
            )),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(body)))
}

pub async fn list_links(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let rows = sqlx::query(&format!(
        "{LINK_SELECT} WHERE l.vault_id=? ORDER BY l.created_epoch DESC LIMIT 500"
    ))
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut links = Vec::with_capacity(rows.len());
    for row in &rows {
        links.push(link_json_tx(&mut tx, &state, &Link::from_row(row), now).await?);
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"links": links})))
}

pub async fn get_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let link = link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    let body = link_json_tx(&mut tx, &state, &link, now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(body))
}

pub async fn update_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id)): Path<(String, String)>,
    Json(req): Json<UpdateLinkRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_owner_write_tx(&mut tx, &user, &vault_id).await?;
    let link = link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    if link.revision != req.expected_revision {
        return Err(ApiError::conflict("SHARE_LINK_REVISION_CONFLICT", "the link changed; reload it"));
    }
    if matches!(link.state.as_str(), "revoked" | "suspended") {
        return Err(ApiError::conflict("SHARE_LINK_NOT_EDITABLE", "revoked or suspended links cannot be edited"));
    }
    let new_state = match req.state.as_deref() {
        None => link.state.clone(),
        Some(value @ ("active" | "paused")) => value.to_owned(),
        Some(_) => return Err(invalid_link("state must be active or paused")),
    };
    let window = validate_window(
        &state,
        req.valid_from.as_deref().or(Some(&cloud::epoch_rfc3339(link.valid_from))),
        req.expires_at.as_deref().or(Some(&cloud::epoch_rfc3339(link.expires))),
        link.created,
        now,
        link.valid_from,
    )?;
    let max_redemptions = match req.max_redemptions {
        Some(value) => validate_counter(value, 1000, "max_redemptions")?,
        None => link.max_redemptions,
    };
    let max_connections = match req.max_connections {
        Some(value) => validate_counter(value, 100_000, "max_connections")?,
        None => link.max_connections,
    };
    let max_concurrent = req.max_concurrent.unwrap_or(link.max_concurrent);
    if !(1..=10).contains(&max_concurrent) {
        return Err(invalid_link("max_concurrent must be between 1 and 10"));
    }
    let perms = Permissions {
        clipboard_to_remote: req.clipboard_to_remote.unwrap_or(link.perms.clipboard_to_remote),
        clipboard_from_remote: req.clipboard_from_remote.unwrap_or(link.perms.clipboard_from_remote),
        view_only: req.view_only.unwrap_or(link.perms.view_only),
    };
    // Any narrowing advances authz_revision, which closes active sockets.
    let lower = |new: Option<i64>, old: Option<i64>| match (new, old) {
        (Some(n), Some(o)) => n < o,
        (Some(_), None) => true,
        _ => false,
    };
    let mut changed = Vec::new();
    let mut narrowed = false;
    if new_state != link.state {
        changed.push("state");
        narrowed |= new_state == "paused";
    }
    if window.valid_from != link.valid_from {
        changed.push("valid_from");
        narrowed |= window.valid_from > link.valid_from;
    }
    if window.expires != link.expires {
        changed.push("expires_at");
        narrowed |= window.expires < link.expires;
    }
    if max_redemptions != link.max_redemptions {
        changed.push("max_redemptions");
    }
    if max_connections != link.max_connections {
        changed.push("max_connections");
        narrowed |= lower(max_connections, link.max_connections);
    }
    if max_concurrent != link.max_concurrent {
        changed.push("max_concurrent");
        narrowed |= max_concurrent < link.max_concurrent;
    }
    if perms != link.perms {
        changed.push("permissions");
        narrowed |= (!perms.clipboard_to_remote && link.perms.clipboard_to_remote)
            || (!perms.clipboard_from_remote && link.perms.clipboard_from_remote)
            || (perms.view_only && !link.perms.view_only);
    }
    sqlx::query(
        "UPDATE share_links SET state=?,valid_from_epoch=?,expires_epoch=?,max_redemptions=?,max_connections=?,max_concurrent=?,clipboard_to_remote=?,clipboard_from_remote=?,view_only=?,authz_revision=authz_revision+?,revision=revision+1,updated_epoch=? WHERE link_id=?",
    )
    .bind(&new_state)
    .bind(window.valid_from)
    .bind(window.expires)
    .bind(max_redemptions)
    .bind(max_connections)
    .bind(max_concurrent)
    .bind(i64::from(perms.clipboard_to_remote))
    .bind(i64::from(perms.clipboard_from_remote))
    .bind(i64::from(perms.view_only))
    .bind(i64::from(narrowed))
    .bind(now)
    .bind(&link_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "share_link.updated")
            .link(&link_id)
            .actor(&user.user_id)
            .detail(format!("changed={} narrowed={narrowed}", changed.join(","))),
        now,
    )
    .await?;
    let updated = load_link_tx(&mut tx, &link_id).await?.ok_or_else(ApiError::not_found)?;
    let body = link_json_tx(&mut tx, &state, &updated, now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    if narrowed {
        state.cloud.notify(cloud::RevocationEvent::Link(link_id));
    }
    Ok(Json(body))
}

pub async fn revoke_link(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id)): Path<(String, String)>,
    Json(req): Json<RevokeRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_owner_write_tx(&mut tx, &user, &vault_id).await?;
    let link = link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    if req.expected_revision.is_some_and(|expected| expected != link.revision) {
        return Err(ApiError::conflict("SHARE_LINK_REVISION_CONFLICT", "the link changed; reload it"));
    }
    revoke_link_tx(&mut tx, &link_id, now, "link_revoked").await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "share_link.revoked")
            .link(&link_id)
            .actor(&user.user_id),
        now,
    )
    .await?;
    let updated = load_link_tx(&mut tx, &link_id).await?.ok_or_else(ApiError::not_found)?;
    let body = link_json_tx(&mut tx, &state, &updated, now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    state.cloud.notify(cloud::RevocationEvent::Link(link_id));
    Ok(Json(body))
}

pub async fn rotate_secret(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id)): Path<(String, String)>,
    Json(req): Json<RotateRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !cloud::is_token(&req.redeem_token) {
        return Err(invalid_link("redeem_token must be 32 random bytes in base64url"));
    }
    validate_envelope(&req.display_envelope)?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_owner_write_tx(&mut tx, &user, &vault_id).await?;
    let link = link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    if link.revision != req.expected_revision {
        return Err(ApiError::conflict("SHARE_LINK_REVISION_CONFLICT", "the link changed; reload it"));
    }
    if link.state == "revoked" {
        return Err(ApiError::conflict("SHARE_LINK_NOT_EDITABLE", "revoked links cannot be rotated"));
    }
    let new_hash = cloud::token_hash(&req.redeem_token);
    if new_hash == link.redeem_token_hash {
        return Err(invalid_link("a rotated link needs a new secret"));
    }
    sqlx::query(
        "UPDATE share_links SET redeem_token_hash=?,display_envelope=?,secret_version=secret_version+1,authz_revision=authz_revision+1,revision=revision+1,redemptions=0,updated_epoch=? WHERE link_id=?",
    )
    .bind(&new_hash)
    .bind(&req.display_envelope)
    .bind(now)
    .bind(&link_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    end_link_sessions_tx(&mut tx, &link_id, now, "secret_rotated").await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "share_link.secret_rotated")
            .link(&link_id)
            .actor(&user.user_id),
        now,
    )
    .await?;
    let updated = load_link_tx(&mut tx, &link_id).await?.ok_or_else(ApiError::not_found)?;
    let body = link_json_tx(&mut tx, &state, &updated, now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    state.cloud.notify(cloud::RevocationEvent::Link(link_id));
    Ok(Json(body))
}

pub async fn activity(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    let sessions = sqlx::query(
        "SELECT s.guest_session_id,s.created_epoch,s.expires_epoch,s.last_seen_epoch,s.revoked_epoch,s.end_reason,s.ip_prefix,s.ua_family,s.secret_version,(SELECT COUNT(*) FROM share_gateway_connections c WHERE c.guest_session_id=s.guest_session_id AND c.ended_epoch IS NULL AND c.heartbeat_epoch>?) AS live FROM share_guest_sessions s WHERE s.link_id=? ORDER BY s.created_epoch DESC LIMIT 200",
    )
    .bind(now - 60)
    .bind(&link_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let connections = sqlx::query(
        "SELECT connection_id,guest_session_id,target_id,protocol,started_epoch,heartbeat_epoch,ended_epoch,end_reason,bytes_to_guest,bytes_from_guest FROM share_gateway_connections WHERE link_id=? ORDER BY started_epoch DESC LIMIT 200",
    )
    .bind(&link_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let events = sqlx::query(
        "SELECT event_id,action,result,detail,guest_session_id,connection_id,occurred_epoch FROM cloud_audit_events WHERE scope_type='vault' AND scope_id=? AND link_id=? ORDER BY event_id DESC LIMIT 200",
    )
    .bind(&vault_id)
    .bind(&link_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let opt_time = |value: Option<i64>| value.map(cloud::epoch_rfc3339);
    Ok(Json(json!({
        "sessions": sessions.iter().map(|row| {
            let revoked: Option<i64> = row.get("revoked_epoch");
            let expires: i64 = row.get("expires_epoch");
            json!({
                "guest_session_id": row.get::<String, _>("guest_session_id"),
                "created_at": cloud::epoch_rfc3339(row.get("created_epoch")),
                "expires_at": cloud::epoch_rfc3339(expires),
                "last_seen_at": cloud::epoch_rfc3339(row.get("last_seen_epoch")),
                "ended_at": opt_time(revoked),
                "end_reason": row.get::<Option<String>, _>("end_reason"),
                "active": revoked.is_none() && expires > now,
                "ip_prefix": row.get::<Option<String>, _>("ip_prefix"),
                "ua_family": row.get::<Option<String>, _>("ua_family"),
                "live_connections": row.get::<i64, _>("live"),
            })
        }).collect::<Vec<_>>(),
        "connections": connections.iter().map(|row| json!({
            "connection_id": row.get::<String, _>("connection_id"),
            "guest_session_id": row.get::<String, _>("guest_session_id"),
            "target_id": row.get::<String, _>("target_id"),
            "protocol": row.get::<String, _>("protocol"),
            "started_at": cloud::epoch_rfc3339(row.get("started_epoch")),
            "ended_at": opt_time(row.get("ended_epoch")),
            "end_reason": row.get::<Option<String>, _>("end_reason"),
            "bytes_to_guest": row.get::<i64, _>("bytes_to_guest"),
            "bytes_from_guest": row.get::<i64, _>("bytes_from_guest"),
        })).collect::<Vec<_>>(),
        "events": events.iter().map(|row| json!({
            "event_id": row.get::<i64, _>("event_id"),
            "action": row.get::<String, _>("action"),
            "result": row.get::<String, _>("result"),
            "detail": row.get::<Option<String>, _>("detail"),
            "guest_session_id": row.get::<Option<String>, _>("guest_session_id"),
            "connection_id": row.get::<Option<String>, _>("connection_id"),
            "occurred_at": cloud::epoch_rfc3339(row.get("occurred_epoch")),
        })).collect::<Vec<_>>(),
    })))
}

pub async fn terminate_guest_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, link_id, guest_session_id)): Path<(String, String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_owner_write_tx(&mut tx, &user, &vault_id).await?;
    link_in_vault_tx(&mut tx, &vault_id, &link_id).await?;
    let updated = sqlx::query(
        "UPDATE share_guest_sessions SET revoked_epoch=?,end_reason='terminated_by_owner' WHERE guest_session_id=? AND link_id=? AND revoked_epoch IS NULL",
    )
    .bind(now)
    .bind(&guest_session_id)
    .bind(&link_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() == 0 {
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM share_guest_sessions WHERE guest_session_id=? AND link_id=?)",
        )
        .bind(&guest_session_id)
        .bind(&link_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !exists {
            return Err(ApiError::not_found());
        }
    }
    sqlx::query("DELETE FROM share_gateway_tickets WHERE guest_session_id=? AND consumed_epoch IS NULL")
        .bind(&guest_session_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "guest_session.terminated")
            .link(&link_id)
            .guest(&guest_session_id)
            .actor(&user.user_id),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    state
        .cloud
        .notify(cloud::RevocationEvent::GuestSession(guest_session_id));
    Ok(Json(json!({"terminated": true})))
}

pub async fn slug_availability(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(slug): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let normalized = normalize_slug(&slug)?;
    if let Err(retry) = state
        .cloud
        .rate
        .check(&format!("slug:{}", user.user_id), 60, 60, cloud::now_epoch())
    {
        return Err(ApiError::new(StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED", "too many requests")
            .with_retry_after(retry));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    let available = slug_available_tx(&mut tx, &normalized, cloud::now_epoch()).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"slug": normalized, "available": available})))
}

/// All links created by the caller across Vaults where they are still owner.
pub async fn list_my_links(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    let rows = sqlx::query(&format!(
        "{LINK_SELECT} WHERE l.owner_user_id=? AND EXISTS(SELECT 1 FROM vault_members vm WHERE vm.vault_id=l.vault_id AND vm.user_id=l.owner_user_id AND vm.state='active' AND vm.role='owner') ORDER BY l.created_epoch DESC LIMIT 500"
    ))
    .bind(&user.user_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut links = Vec::with_capacity(rows.len());
    for row in &rows {
        links.push(link_json_tx(&mut tx, &state, &Link::from_row(row), now).await?);
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"links": links})))
}

/// Metadata-only sharing/organization audit for a Vault owner.
pub async fn vault_audit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let rows = sqlx::query(
        "SELECT event_id,action,result,detail,link_id,guest_session_id,connection_id,actor_user_id,occurred_epoch FROM cloud_audit_events WHERE scope_type='vault' AND scope_id=? ORDER BY event_id DESC LIMIT 500",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"events": rows.iter().map(|row| json!({
        "event_id": row.get::<i64, _>("event_id"),
        "action": row.get::<String, _>("action"),
        "result": row.get::<String, _>("result"),
        "detail": row.get::<Option<String>, _>("detail"),
        "link_id": row.get::<Option<String>, _>("link_id"),
        "guest_session_id": row.get::<Option<String>, _>("guest_session_id"),
        "connection_id": row.get::<Option<String>, _>("connection_id"),
        "actor_user_id": row.get::<Option<String>, _>("actor_user_id"),
        "occurred_at": cloud::epoch_rfc3339(row.get("occurred_epoch")),
    })).collect::<Vec<_>>()})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_normalized_bounded_and_reserved_words_rejected() {
        assert_eq!(normalize_slug("Team-Demo").unwrap(), "team-demo");
        assert_eq!(normalize_slug("ＡＢＣ１").unwrap(), "abc1");
        for bad in ["ab", "-abc", "abc-", "a--b", "api", "join", "a b", "ä-x", &"a".repeat(49), "a.b"] {
            assert!(normalize_slug(bad).is_err(), "{bad}");
        }
        let random = random_slug();
        assert_eq!(normalize_slug(&random).unwrap(), random);
    }

    fn link(now: i64) -> Link {
        Link {
            link_id: "l".into(),
            vault_id: "v".into(),
            owner_user_id: "u".into(),
            slug: "s".into(),
            slug_custom: false,
            redeem_token_hash: "h".into(),
            secret_version: 1,
            display_envelope: "e".into(),
            state: "active".into(),
            suspend_reason: None,
            valid_from: now - 10,
            expires: now + 10,
            max_redemptions: Some(1),
            redemptions: 0,
            max_connections: None,
            connections: 0,
            max_concurrent: 1,
            session_lifetime: 7200,
            perms: Permissions { clipboard_to_remote: false, clipboard_from_remote: false, view_only: false },
            authz_revision: 1,
            revision: 1,
            request_digest: "d".into(),
            created: now - 10,
            owner_ok: true,
        }
    }

    #[test]
    fn link_status_uses_half_open_window_and_precedence() {
        let now = 1_000_000;
        let mut l = link(now);
        assert_eq!(l.status(now), LinkStatus::Active);
        l.expires = now;
        assert_eq!(l.status(now), LinkStatus::Expired, "expires_at is exclusive");
        l.expires = now + 10;
        l.valid_from = now;
        assert_eq!(l.status(now), LinkStatus::Active, "valid_from is inclusive");
        assert_eq!(l.status(now - 1), LinkStatus::NotYetValid);
        l.state = "paused".into();
        assert_eq!(l.status(now), LinkStatus::Paused);
        l.owner_ok = false;
        assert_eq!(l.status(now), LinkStatus::Suspended("creator_lost_access"));
        l.state = "revoked".into();
        assert_eq!(l.status(now), LinkStatus::Revoked);
        let mut counted = link(now);
        counted.redemptions = 1;
        assert!(counted.redemptions_exhausted());
        counted.max_redemptions = None;
        assert!(!counted.redemptions_exhausted());
    }
}

//! Trusted share gateway: gateway X25519 key, sealed Host capsules, target
//! policy (DNS re-resolution + address pinning), SSH host-key pinning and the
//! guacd handshake used by guest connections.
//!
//! Trust model (stated plainly, also in the owner UI): the holder of the
//! gateway private key file can open every stored capsule. Capsules protect
//! Host login data against database/backup disclosure only. This is NOT
//! zero-knowledge and NOT end-to-end encryption for guests.
use std::{
    future::Future,
    io,
    net::IpAddr,
    path::Path,
    pin::Pin,
    time::Duration,
};

use axum::{
    Json,
    extract::{Path as AxumPath, State},
    http::{HeaderMap, StatusCode},
};
use base64::{
    Engine as _,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use ed25519_dalek::Signer;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Digest;
use sqlx::{Row, SqlitePool};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};
use zeroize::{Zeroize, Zeroizing};

use crate::{ApiError, AppState, cloud};

pub(crate) const CAPSULE_FORMAT: &str = "atermius-gateway-capsule-v1";
pub(crate) const CAPSULE_INNER_FORMAT: &str = "atermius-gateway-capsule-inner-v1";
const GATEWAY_KEY_FORMAT: &str = "atermius-share-gateway-key-v1";
const MAX_SEALED_BYTES: usize = 300 * 1024;
const DNS_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_DNS_ANSWERS: usize = 32;
const SSH_PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(10);

/// The loaded gateway key. The secret key never leaves this process and is
/// never written to the database, logs or backups.
pub(crate) struct GatewayKey {
    pub(crate) key_id: String,
    secret: crypto_box::SecretKey,
    pub(crate) public_key: String,
    pub(crate) signed_payload: String,
    pub(crate) signature: String,
}

impl std::fmt::Debug for GatewayKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("GatewayKey")
            .field("key_id", &self.key_id)
            .field("public_key", &self.public_key)
            .finish_non_exhaustive()
    }
}

#[derive(Serialize)]
struct GatewayKeyPayload<'a> {
    format: &'static str,
    instance_id: &'a str,
    key_id: &'a str,
    public_key: &'a str,
    created_at: &'a str,
}

fn path_is_within(child: &Path, parent: &Path) -> bool {
    let parent = std::fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf());
    let child_parent = child
        .parent()
        .and_then(|p| std::fs::canonicalize(p).ok())
        .unwrap_or_else(|| child.to_path_buf());
    child_parent.starts_with(&parent)
}

impl GatewayKey {
    pub(crate) async fn load_or_create(
        db: &SqlitePool,
        path: &Path,
        data_dir: &Path,
        signing_key: &ed25519_dalek::SigningKey,
        instance_id: &str,
    ) -> Result<Self, ApiError> {
        if path_is_within(path, data_dir) {
            return Err(ApiError::internal(
                "ATERMIUS_SHARE_GATEWAY_KEY_FILE must be outside ATERMIUS_DATA_DIR so backups never contain it",
            ));
        }
        let raw = Zeroizing::new(crate::secure_file::read_or_create_private_key(path)?);
        let secret = crypto_box::SecretKey::from_bytes(*raw);
        let public_key = URL_SAFE_NO_PAD.encode(secret.public_key().as_bytes());
        Self::register(db, secret, public_key, signing_key, instance_id).await
    }

    #[cfg(test)]
    pub(crate) async fn for_tests(
        db: &SqlitePool,
        signing_key: &ed25519_dalek::SigningKey,
        instance_id: &str,
    ) -> Self {
        let secret = crypto_box::SecretKey::generate(&mut rand::rngs::OsRng);
        let public_key = URL_SAFE_NO_PAD.encode(secret.public_key().as_bytes());
        Self::register(db, secret, public_key, signing_key, instance_id)
            .await
            .unwrap()
    }

    async fn register(
        db: &SqlitePool,
        secret: crypto_box::SecretKey,
        public_key: String,
        signing_key: &ed25519_dalek::SigningKey,
        instance_id: &str,
    ) -> Result<Self, ApiError> {
        let mut tx = db.begin().await.map_err(ApiError::internal)?;
        let existing = sqlx::query(
            "SELECT key_id,signed_payload,signature,state FROM share_gateway_keys WHERE public_key=?",
        )
        .bind(&public_key)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let now = crate::now_rfc3339();
        let (key_id, signed_payload, signature) = if let Some(row) = existing {
            if row.get::<String, _>("state") != "active" {
                // A retired key file must not silently come back into use.
                return Err(ApiError::internal(
                    "configured share gateway key was retired; provide a new key file",
                ));
            }
            (row.get("key_id"), row.get("signed_payload"), row.get("signature"))
        } else {
            let key_id = uuid::Uuid::new_v4().to_string();
            let payload = crate::jcs(&GatewayKeyPayload {
                format: GATEWAY_KEY_FORMAT,
                instance_id,
                key_id: &key_id,
                public_key: &public_key,
                created_at: &now,
            })?;
            let signature = URL_SAFE_NO_PAD.encode(signing_key.sign(&payload).to_bytes());
            let payload = String::from_utf8(payload).map_err(ApiError::internal)?;
            sqlx::query(
                "INSERT INTO share_gateway_keys(key_id,public_key,signed_payload,signature,state,created_at) VALUES(?,?,?,?,'active',?)",
            )
            .bind(&key_id)
            .bind(&public_key)
            .bind(&payload)
            .bind(&signature)
            .bind(&now)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            (key_id, payload, signature)
        };
        // Exactly one active key: capsules sealed to any other key are stale.
        sqlx::query(
            "UPDATE share_gateway_keys SET state='retired',retired_at=? WHERE state='active' AND key_id<>?",
        )
        .bind(&now)
        .bind(&key_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(Self {
            key_id,
            secret,
            public_key,
            signed_payload,
            signature,
        })
    }

    #[cfg(test)]
    pub(crate) fn from_secret_for_tests(secret: [u8; 32], key_id: &str) -> Self {
        let secret = crypto_box::SecretKey::from_bytes(secret);
        let public_key = URL_SAFE_NO_PAD.encode(secret.public_key().as_bytes());
        Self {
            key_id: key_id.to_owned(),
            secret,
            public_key,
            signed_payload: String::new(),
            signature: String::new(),
        }
    }

    fn unseal(&self, sealed: &[u8]) -> Option<Zeroizing<Vec<u8>>> {
        self.secret.unseal(sealed).ok().map(Zeroizing::new)
    }

    #[cfg(test)]
    pub(crate) fn seal_for_tests(&self, plaintext: &[u8]) -> Vec<u8> {
        self.secret
            .public_key()
            .seal(&mut rand::rngs::OsRng, plaintext)
            .unwrap()
    }
}

/// Public, unauthenticated: clients verify the instance signature against
/// their pinned instance key before sealing anything to this key.
pub async fn keys(State(state): State<AppState>) -> Result<Json<Value>, ApiError> {
    if !cloud::share_links_ready(&state) {
        return Err(cloud::sharing_disabled());
    }
    let Some(key) = state.cloud.gateway.as_ref() else {
        return Err(cloud::sharing_disabled());
    };
    Ok(Json(json!({
        "keys": [{
            "key_id": key.key_id,
            "public_key": key.public_key,
            "signed_payload": key.signed_payload,
            "signature": key.signature,
            "state": "active",
        }]
    })))
}

// ---------------------------------------------------------------------------
// Target policy
// ---------------------------------------------------------------------------

pub(crate) type ResolveFuture<'a> = Pin<Box<dyn Future<Output = io::Result<Vec<IpAddr>>> + Send + 'a>>;

pub(crate) trait ShareResolver: Send + Sync {
    fn resolve<'a>(&'a self, hostname: &'a str, port: u16) -> ResolveFuture<'a>;
}

pub(crate) struct SystemShareResolver;

impl ShareResolver for SystemShareResolver {
    fn resolve<'a>(&'a self, hostname: &'a str, port: u16) -> ResolveFuture<'a> {
        Box::pin(crate::relay::lookup_host_all(hostname, port, MAX_DNS_ANSWERS))
    }
}

fn target_denied() -> ApiError {
    ApiError::forbidden(
        "TARGET_DENIED",
        "target is outside the instance sharing policy",
    )
}

pub(crate) fn protocol_allowed(state: &AppState, protocol: &str) -> bool {
    match protocol {
        "ssh" | "rdp" => true,
        "vnc" => state.cloud.config.vnc_enabled,
        _ => false,
    }
}

/// Static per-address check: forbidden special-purpose addresses, explicit
/// deny CIDRs, the operator allow-list and allowed ports.
pub(crate) fn address_allowed(state: &AppState, ip: IpAddr, port: u16) -> bool {
    let cloud = &state.cloud.config;
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(ip),
        other => other,
    };
    port != 0
        && cloud.allow_ports.contains(&port)
        && !crate::relay::is_forbidden_ip(ip)
        && !cloud.deny_cidrs.iter().any(|network| network.contains(&ip))
        && cloud.allow_cidrs.iter().any(|network| network.contains(&ip))
}

/// Resolves the owner-selected target again and pins one checked address.
/// Every DNS answer is inspected: if any answer is forbidden or explicitly
/// denied the whole name is rejected (rebinding/mixed answers), otherwise the
/// first allowed answer is used. The guacd `hostname` is always this literal.
pub(crate) async fn resolve_target(
    state: &AppState,
    owner_user_id: &str,
    protocol: &str,
    target_host: &str,
    target_port: u16,
) -> Result<IpAddr, ApiError> {
    if !protocol_allowed(state, protocol) {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "HOST_SHARE_UNSUPPORTED",
            "this Host protocol cannot be shared on this server",
        )
        .with_details(json!({"reason": "protocol"})));
    }
    if target_port == 0 || !state.cloud.config.allow_ports.contains(&target_port) {
        return Err(target_denied());
    }
    let answers = if let Ok(ip) = target_host.parse::<IpAddr>() {
        vec![ip]
    } else {
        let hostname = crate::relay::normalize_dns_hostname(target_host)?;
        let answers = timeout(
            DNS_TIMEOUT,
            state.cloud.resolver.resolve(&hostname, target_port),
        )
        .await
        .map_err(|_| resolution_failed())?
        .map_err(|_| resolution_failed())?;
        if answers.is_empty() || answers.len() > MAX_DNS_ANSWERS {
            return Err(resolution_failed());
        }
        answers
    };
    let cloud = &state.cloud.config;
    if answers.iter().any(|ip| {
        let ip = match ip {
            IpAddr::V6(v6) => v6.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(*ip),
            other => *other,
        };
        crate::relay::is_forbidden_ip(ip) || cloud.deny_cidrs.iter().any(|n| n.contains(&ip))
    }) {
        return Err(target_denied());
    }
    let selected = answers
        .into_iter()
        .find(|ip| address_allowed(state, *ip, target_port))
        .ok_or_else(target_denied)?;
    // The owner's own Relay restrictions (user/group policy) also bound what
    // they may expose through the gateway when Relay is configured.
    if crate::relay::relay_available(state) {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        let policy = crate::relay::effective_policy_for_user_tx(&mut tx, state, owner_user_id).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        if !crate::relay::effective_target_allowed(&policy, selected, target_port) {
            return Err(target_denied());
        }
    }
    Ok(selected)
}

fn resolution_failed() -> ApiError {
    ApiError::new(
        StatusCode::BAD_GATEWAY,
        "TARGET_RESOLUTION_FAILED",
        "target name could not be resolved",
    )
}

// ---------------------------------------------------------------------------
// Capsules
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct CapsuleHeader {
    pub format: String,
    pub vault_id: String,
    pub host_record_id: String,
    pub host_revision_id: String,
    pub gateway_key_id: String,
    pub protocol: String,
    pub target_host: String,
    pub target_port: u16,
    /// Public host identity pin: `SHA256:<b64>` SSH host-key fingerprint or
    /// 64-hex RDP certificate SHA-256. Required for SSH and RDP.
    #[serde(default)]
    pub host_identity: Option<String>,
    pub sealed_sha256: String,
    pub sealer_user_id: String,
    pub sealer_device_id: String,
    pub created_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
}

impl CapsuleHeader {
    fn signed_bytes(&self) -> Result<Vec<u8>, ApiError> {
        let mut unsigned = self.clone();
        unsigned.signature = None;
        crate::jcs(&unsigned)
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PutCapsuleRequest {
    header: CapsuleHeader,
    sealed: String,
    #[serde(default)]
    expected_revision: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CapsuleInner {
    format: String,
    vault_id: String,
    host_record_id: String,
    host_revision_id: String,
    gateway_key_id: String,
    record_kind: String,
    protocol: String,
    target_host: String,
    target_port: u16,
    #[serde(default)]
    username: String,
    #[serde(default)]
    password: Option<String>,
    #[serde(default)]
    private_key: Option<String>,
    #[serde(default)]
    passphrase: Option<String>,
    #[serde(default)]
    host_identity: Option<String>,
    #[serde(default)]
    ssh_host_key_algorithm: Option<String>,
    /// RDP transport security. Only certificate-verifying modes are allowed
    /// (`nla` default, or `tls`); `any`/`rdp` could downgrade to standard RDP
    /// security, which bypasses certificate pinning.
    #[serde(default)]
    rdp_security: Option<String>,
    #[serde(default)]
    display_mode: Option<String>,
    #[serde(default)]
    display_width: Option<u16>,
    #[serde(default)]
    display_height: Option<u16>,
}

impl CapsuleInner {
    pub(crate) fn ssh_host_key_algorithm(&self) -> &str {
        self.ssh_host_key_algorithm.as_deref().unwrap_or("")
    }
}

impl Drop for CapsuleInner {
    fn drop(&mut self) {
        self.username.zeroize();
        if let Some(value) = self.password.as_mut() {
            value.zeroize();
        }
        if let Some(value) = self.private_key.as_mut() {
            value.zeroize();
        }
        if let Some(value) = self.passphrase.as_mut() {
            value.zeroize();
        }
    }
}

fn valid_identity(protocol: &str, identity: Option<&str>) -> bool {
    match (protocol, identity) {
        ("ssh", Some(value)) => {
            value.len() == 50
                && value.starts_with("SHA256:")
                && STANDARD_NO_PAD_DECODE(&value[7..]).is_some_and(|b| b.len() == 32)
        }
        ("rdp", Some(value)) => value.len() == 64 && value.bytes().all(|b| b.is_ascii_hexdigit()),
        ("vnc", None) => true,
        _ => false,
    }
}

#[allow(non_snake_case)]
fn STANDARD_NO_PAD_DECODE(value: &str) -> Option<Vec<u8>> {
    base64::engine::general_purpose::STANDARD_NO_PAD.decode(value).ok()
}

fn host_key_required() -> ApiError {
    ApiError::new(
        StatusCode::UNPROCESSABLE_ENTITY,
        "HOST_KEY_REQUIRED",
        "SSH Hosts need a trusted host key and RDP Hosts a pinned certificate before sharing",
    )
}

fn validate_target_host(value: &str) -> Result<(), ApiError> {
    if value.parse::<IpAddr>().is_ok() && value.len() <= 45 {
        return Ok(());
    }
    crate::relay::normalize_dns_hostname(value).map(|_| ())
}

pub async fn put_capsule(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath((vault_id, host_id)): AxumPath<(String, String)>,
    Json(req): Json<PutCapsuleRequest>,
) -> Result<Json<Value>, ApiError> {
    if !cloud::share_links_ready(&state) {
        return Err(cloud::sharing_disabled());
    }
    let user = crate::current_user(&state, &headers).await?;
    let header = &req.header;
    if !crate::is_canonical_uuid(&vault_id) || !crate::is_canonical_uuid(&host_id) {
        return Err(ApiError::not_found());
    }
    if header.vault_id != vault_id || header.host_record_id != host_id {
        return Err(ApiError::bad_request(
            "CAPSULE_BINDING_MISMATCH",
            "capsule header does not match the request path",
        ));
    }
    let Some(gateway) = state.cloud.gateway.as_ref() else {
        return Err(cloud::sharing_disabled());
    };
    if header.format != CAPSULE_FORMAT
        || !crate::is_canonical_uuid(&header.host_revision_id)
        || header.sealer_user_id != user.user_id
        || header.sealer_device_id != user.device_id
        || header.created_at.len() > 40
        || cloud::parse_rfc3339_epoch(&header.created_at).is_none()
    {
        return Err(ApiError::invalid_envelope("capsule header is invalid"));
    }
    if header.gateway_key_id != gateway.key_id {
        return Err(ApiError::conflict(
            "GATEWAY_KEY_RETIRED",
            "the capsule was sealed to a gateway key that is not active",
        ));
    }
    if !protocol_allowed(&state, &header.protocol) {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "HOST_SHARE_UNSUPPORTED",
            "this Host protocol cannot be shared on this server",
        )
        .with_details(json!({"reason": "protocol"})));
    }
    if !valid_identity(&header.protocol, header.host_identity.as_deref()) {
        return Err(host_key_required());
    }
    validate_target_host(&header.target_host)?;
    let sealed = URL_SAFE_NO_PAD
        .decode(&req.sealed)
        .map_err(|_| ApiError::invalid_envelope("sealed capsule is not base64url"))?;
    if sealed.len() < 48 + 16 || sealed.len() > MAX_SEALED_BYTES {
        return Err(ApiError::too_large("sealed capsule size is outside the allowed range"));
    }
    let sealed_sha256 = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed));
    if sealed_sha256 != header.sealed_sha256 {
        return Err(ApiError::invalid_envelope("sealed capsule digest does not match its header"));
    }
    let Some(signature) = header.signature.as_deref() else {
        return Err(ApiError::invalid_envelope("capsule header is unsigned"));
    };
    let signing_key: Option<String> = sqlx::query_scalar(
        "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let signing_key = signing_key.ok_or_else(|| {
        ApiError::forbidden("DEVICE_REVOKED", "device is not active")
    })?;
    crate::auth::verify_key_signature(&signing_key, signature, &header.signed_bytes()?)?;
    // Policy + DNS outside the writer transaction (bounded by DNS_TIMEOUT).
    resolve_target(
        &state,
        &user.user_id,
        &header.protocol,
        &header.target_host,
        header.target_port,
    )
    .await?;

    let now = cloud::now_epoch();
    let now_text = cloud::epoch_rfc3339(now);
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    let head = sqlx::query_as::<_, (String, i64)>(
        "SELECT revision_id,deleted FROM record_heads WHERE vault_id=? AND record_id=?",
    )
    .bind(&vault_id)
    .bind(&host_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((revision_id, deleted)) = head else {
        return Err(ApiError::not_found());
    };
    if deleted != 0 {
        return Err(ApiError::not_found());
    }
    if revision_id != header.host_revision_id {
        return Err(ApiError::conflict(
            "HOST_REVISION_CHANGED",
            "the Host changed; synchronize and seal the current revision",
        ));
    }
    let existing: Option<(String, i64)> = sqlx::query_as(
        "SELECT capsule_id,revision FROM share_host_capsules WHERE vault_id=? AND host_record_id=?",
    )
    .bind(&vault_id)
    .bind(&host_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if let (Some(expected), Some((_, current))) = (req.expected_revision, existing.as_ref())
        && expected != *current
    {
        return Err(ApiError::conflict("CAPSULE_REVISION_CONFLICT", "capsule changed concurrently"));
    }
    let header_json = serde_json::to_string(header).map_err(ApiError::internal)?;
    let (capsule_id, revision) = match existing {
        Some((capsule_id, revision)) => {
            sqlx::query(
                "UPDATE share_host_capsules SET host_revision_id=?,gateway_key_id=?,protocol=?,target_host=?,target_port=?,header_json=?,sealed=?,sealed_sha256=?,sealer_user_id=?,sealer_device_id=?,state='active',revision=revision+1,updated_at=? WHERE capsule_id=?",
            )
            .bind(&header.host_revision_id)
            .bind(&header.gateway_key_id)
            .bind(&header.protocol)
            .bind(&header.target_host)
            .bind(i64::from(header.target_port))
            .bind(&header_json)
            .bind(&req.sealed)
            .bind(&sealed_sha256)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(&now_text)
            .bind(&capsule_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            (capsule_id, revision + 1)
        }
        None => {
            let capsule_id = uuid::Uuid::new_v4().to_string();
            sqlx::query(
                "INSERT INTO share_host_capsules(capsule_id,vault_id,host_record_id,host_revision_id,gateway_key_id,protocol,target_host,target_port,header_json,sealed,sealed_sha256,sealer_user_id,sealer_device_id,state,revision,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'active',1,?,?)",
            )
            .bind(&capsule_id)
            .bind(&vault_id)
            .bind(&host_id)
            .bind(&header.host_revision_id)
            .bind(&header.gateway_key_id)
            .bind(&header.protocol)
            .bind(&header.target_host)
            .bind(i64::from(header.target_port))
            .bind(&header_json)
            .bind(&req.sealed)
            .bind(&sealed_sha256)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(&now_text)
            .bind(&now_text)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            (capsule_id, 1)
        }
    };
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "host.capsule_set")
            .actor(&user.user_id)
            .detail(format!("protocol={} host_record_id={}", header.protocol, host_id)),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(capsule_json(
        &capsule_id,
        &host_id,
        &header.host_revision_id,
        &revision_id,
        &header.protocol,
        revision,
        "active",
        &header.gateway_key_id,
        &gateway.key_id,
    )))
}

#[allow(clippy::too_many_arguments)]
fn capsule_json(
    capsule_id: &str,
    host_id: &str,
    sealed_revision: &str,
    head_revision: &str,
    protocol: &str,
    revision: i64,
    state: &str,
    key_id: &str,
    active_key_id: &str,
) -> Value {
    let status = if state != "active" {
        "revoked"
    } else if key_id != active_key_id {
        "stale_gateway_key"
    } else if sealed_revision != head_revision {
        "stale_host_revision"
    } else {
        "active"
    };
    json!({
        "capsule_id": capsule_id,
        "host_record_id": host_id,
        "host_revision_id": sealed_revision,
        "protocol": protocol,
        "revision": revision,
        "status": status,
    })
}

/// Lists capsule metadata (never sealed bytes) for the Vault owner.
pub async fn list_capsules(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(vault_id): AxumPath<String>,
) -> Result<Json<Value>, ApiError> {
    if !cloud::share_links_ready(&state) {
        return Err(cloud::sharing_disabled());
    }
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let active_key = state.cloud.gateway.as_ref().map(|k| k.key_id.clone()).unwrap_or_default();
    let rows = sqlx::query(
        "SELECT c.capsule_id,c.host_record_id,c.host_revision_id,c.protocol,c.revision,c.state,c.gateway_key_id,COALESCE(h.revision_id,'') AS head_revision,COALESCE(h.deleted,1) AS deleted,EXISTS(SELECT 1 FROM devices d JOIN users u ON u.user_id=d.user_id JOIN vault_members vm ON vm.user_id=d.user_id WHERE d.device_id=c.sealer_device_id AND d.user_id=c.sealer_user_id AND d.status='active' AND u.status='active' AND vm.vault_id=c.vault_id AND vm.state='active' AND vm.role='owner') AS sealer_ok FROM share_host_capsules c LEFT JOIN record_heads h ON h.vault_id=c.vault_id AND h.record_id=c.host_record_id WHERE c.vault_id=? ORDER BY c.created_at",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let capsules = rows
        .iter()
        .map(|row| {
            let deleted: i64 = row.get("deleted");
            let mut value = capsule_json(
                &row.get::<String, _>("capsule_id"),
                &row.get::<String, _>("host_record_id"),
                &row.get::<String, _>("host_revision_id"),
                &row.get::<String, _>("head_revision"),
                &row.get::<String, _>("protocol"),
                row.get("revision"),
                &row.get::<String, _>("state"),
                &row.get::<String, _>("gateway_key_id"),
                &active_key,
            );
            if deleted != 0 {
                value["status"] = json!("host_deleted");
            } else if row.get::<i64, _>("sealer_ok") != 1 && value["status"] == "active" {
                // Honest owner view: the sealing device or its authority is gone.
                value["status"] = json!("sealer_authority_lost");
            }
            value
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({"capsules": capsules})))
}

/// Deleting a capsule removes gateway access for the Host: links targeting it
/// are revoked first (and their active sockets closed) in the same transaction.
pub async fn delete_capsule(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath((vault_id, host_id)): AxumPath<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    if !cloud::share_links_ready(&state) {
        return Err(cloud::sharing_disabled());
    }
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let link_ids: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT link_id FROM share_link_targets WHERE vault_id=? AND host_record_id=?",
    )
    .bind(&vault_id)
    .bind(&host_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for link_id in &link_ids {
        crate::share_links::revoke_link_tx(&mut tx, link_id, now, "capsule_deleted").await?;
    }
    let deleted = sqlx::query("DELETE FROM share_host_capsules WHERE vault_id=? AND host_record_id=?")
        .bind(&vault_id)
        .bind(&host_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if deleted.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "host.capsule_deleted")
            .actor(&user.user_id)
            .detail(format!("host_record_id={host_id} revoked_links={}", link_ids.len())),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    for link_id in link_ids {
        state.cloud.notify(cloud::RevocationEvent::Link(link_id));
    }
    Ok(Json(json!({"deleted": true})))
}

/// Vault owner check for cloud management reads. Unknown and foreign Vaults
/// are indistinguishable (404); non-owner members get a role error.
pub(crate) async fn require_owner_read_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    vault_id: &str,
) -> Result<(), ApiError> {
    let role: Option<String> = sqlx::query_scalar(
        "SELECT vm.role FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND u.status='active' AND v.state='active'",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    match role.as_deref() {
        None => Err(ApiError::not_found()),
        Some("owner") => Ok(()),
        Some(_) => Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required")),
    }
}

// ---------------------------------------------------------------------------
// Unsealing (gateway side, only while constructing a guacd connect)
// ---------------------------------------------------------------------------

pub(crate) struct CapsuleRow {
    pub(crate) vault_id: String,
    pub(crate) host_record_id: String,
    pub(crate) host_revision_id: String,
    pub(crate) gateway_key_id: String,
    pub(crate) protocol: String,
    pub(crate) target_host: String,
    pub(crate) target_port: u16,
    pub(crate) host_identity: Option<String>,
    pub(crate) sealed: String,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum UnsealError {
    Undecryptable,
    Mismatch,
    MissingIdentity,
}

pub(crate) fn unseal_capsule(state: &AppState, row: &CapsuleRow) -> Result<CapsuleInner, UnsealError> {
    let gateway = state.cloud.gateway.as_ref().ok_or(UnsealError::Undecryptable)?;
    if gateway.key_id != row.gateway_key_id {
        return Err(UnsealError::Undecryptable);
    }
    let sealed = URL_SAFE_NO_PAD
        .decode(&row.sealed)
        .map_err(|_| UnsealError::Undecryptable)?;
    let plaintext = gateway.unseal(&sealed).ok_or(UnsealError::Undecryptable)?;
    let inner: CapsuleInner =
        serde_json::from_slice(&plaintext).map_err(|_| UnsealError::Undecryptable)?;
    // Inner bindings must equal the authenticated outer header and DB row.
    // This prevents moving a valid capsule between Hosts or Vaults.
    if inner.format != CAPSULE_INNER_FORMAT
        || inner.record_kind != "host"
        || inner.vault_id != row.vault_id
        || inner.host_record_id != row.host_record_id
        || inner.host_revision_id != row.host_revision_id
        || inner.gateway_key_id != row.gateway_key_id
        || inner.protocol != row.protocol
        || inner.target_host != row.target_host
        || inner.target_port != row.target_port
        || inner.host_identity != row.host_identity
    {
        return Err(UnsealError::Mismatch);
    }
    if !matches!(inner.rdp_security.as_deref(), None | Some("nla") | Some("tls")) {
        return Err(UnsealError::Mismatch);
    }
    if !valid_identity(&inner.protocol, inner.host_identity.as_deref())
        || (inner.protocol == "ssh" && inner.ssh_host_key_algorithm.is_none())
    {
        return Err(UnsealError::MissingIdentity);
    }
    Ok(inner)
}

// ---------------------------------------------------------------------------
// SSH host key pinning (pre-authentication transport exchange)
// ---------------------------------------------------------------------------

fn ssh_blob_type(algorithm: &str) -> Option<&'static str> {
    match algorithm {
        "ssh-ed25519" => Some("ssh-ed25519"),
        "ssh-rsa" | "rsa-sha2-256" | "rsa-sha2-512" => Some("ssh-rsa"),
        "ecdsa-sha2-nistp256" => Some("ecdsa-sha2-nistp256"),
        "ecdsa-sha2-nistp384" => Some("ecdsa-sha2-nistp384"),
        "ecdsa-sha2-nistp521" => Some("ecdsa-sha2-nistp521"),
        _ => None,
    }
}

fn put_string(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&(value.len() as u32).to_be_bytes());
    out.extend_from_slice(value);
}

fn ssh_packet(payload: &[u8]) -> Vec<u8> {
    use rand::RngCore;
    let mut padding = 8 - ((5 + payload.len()) % 8);
    if padding < 4 {
        padding += 8;
    }
    let mut out = Vec::with_capacity(5 + payload.len() + padding);
    out.extend_from_slice(&((1 + payload.len() + padding) as u32).to_be_bytes());
    out.push(padding as u8);
    out.extend_from_slice(payload);
    let mut pad = vec![0_u8; padding];
    rand::thread_rng().fill_bytes(&mut pad);
    out.extend_from_slice(&pad);
    out
}

async fn read_ssh_packet<S: AsyncReadExt + Unpin>(stream: &mut S) -> io::Result<Vec<u8>> {
    let length = stream.read_u32().await? as usize;
    if !(5..=35_000).contains(&length) {
        return Err(io::Error::other("invalid SSH packet length"));
    }
    let mut packet = vec![0_u8; length];
    stream.read_exact(&mut packet).await?;
    let padding = packet[0] as usize;
    if padding < 4 || padding + 1 > length {
        return Err(io::Error::other("invalid SSH padding"));
    }
    packet.truncate(length - padding);
    packet.remove(0);
    Ok(packet)
}

fn take_string<'a>(input: &mut &'a [u8]) -> Option<&'a [u8]> {
    if input.len() < 4 {
        return None;
    }
    let length = u32::from_be_bytes(input[..4].try_into().ok()?) as usize;
    if input.len() < 4 + length {
        return None;
    }
    let (value, rest) = input[4..].split_at(length);
    *input = rest;
    Some(value)
}

/// Reads the target's public host-key blob for exactly `algorithm` using the
/// unauthenticated SSH transport prelude (RFC 4253 §7, RFC 8731). Nothing is
/// derived or decrypted: the caller only compares the blob's SHA-256 with the
/// owner-approved fingerprint and then hands guacd/libssh2 the exact key,
/// which performs the real host signature verification itself.
pub(crate) async fn fetch_ssh_host_key<S>(stream: &mut S, algorithm: &str) -> io::Result<Vec<u8>>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    use rand::RngCore;
    let blob_type = ssh_blob_type(algorithm).ok_or_else(|| io::Error::other("unsupported host key algorithm"))?;
    stream.write_all(b"SSH-2.0-AtermiusGateway_1.0\r\n").await?;
    // Server identification (other lines may precede it).
    let mut line = Vec::new();
    let mut lines = 0;
    loop {
        let byte = stream.read_u8().await?;
        line.push(byte);
        if line.len() > 255 {
            return Err(io::Error::other("SSH identification too long"));
        }
        if byte == b'\n' {
            if line.starts_with(b"SSH-2.0-") || line.starts_with(b"SSH-1.99-") {
                break;
            }
            lines += 1;
            if lines > 20 {
                return Err(io::Error::other("no SSH identification"));
            }
            line.clear();
        }
    }
    let mut kexinit = vec![20_u8];
    let mut cookie = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut cookie);
    kexinit.extend_from_slice(&cookie);
    // RSA host keys are discovered with SHA-2 signature algorithms only; the
    // SHA-1 `ssh-rsa` signature algorithm is never offered.
    let host_key_algorithms = match blob_type {
        "ssh-rsa" => "rsa-sha2-512,rsa-sha2-256",
        other => other,
    };
    for list in [
        "curve25519-sha256,curve25519-sha256@libssh.org".as_bytes(),
        host_key_algorithms.as_bytes(),
        b"aes128-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com",
        b"aes128-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com,chacha20-poly1305@openssh.com",
        b"hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com",
        b"hmac-sha2-256,hmac-sha2-512,hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com",
        b"none",
        b"none",
        b"",
        b"",
    ] {
        put_string(&mut kexinit, list);
    }
    kexinit.push(0);
    kexinit.extend_from_slice(&[0, 0, 0, 0]);
    stream.write_all(&ssh_packet(&kexinit)).await?;
    let ephemeral = crypto_box::SecretKey::generate(&mut rand::rngs::OsRng);
    let mut init = vec![30_u8];
    put_string(&mut init, ephemeral.public_key().as_bytes());
    stream.write_all(&ssh_packet(&init)).await?;
    for _ in 0..8 {
        let packet = read_ssh_packet(stream).await?;
        match packet.first() {
            Some(31) => {
                let mut rest = &packet[1..];
                let blob = take_string(&mut rest).ok_or_else(|| io::Error::other("bad KEX reply"))?;
                let mut blob_view = blob;
                let key_type = take_string(&mut blob_view).ok_or_else(|| io::Error::other("bad host key"))?;
                if key_type != blob_type.as_bytes() {
                    return Err(io::Error::other("unexpected host key type"));
                }
                return Ok(blob.to_vec());
            }
            Some(1) => return Err(io::Error::other("server disconnected")),
            Some(20) | Some(2) | Some(4) => continue,
            _ => continue,
        }
    }
    Err(io::Error::other("no KEX reply"))
}

pub(crate) fn ssh_fingerprint(blob: &[u8]) -> String {
    format!(
        "SHA256:{}",
        base64::engine::general_purpose::STANDARD_NO_PAD.encode(sha2::Sha256::digest(blob))
    )
}

pub(crate) fn known_hosts_line(ip: IpAddr, port: u16, blob: &[u8]) -> Option<String> {
    let mut view = blob;
    let key_type = std::str::from_utf8(take_string(&mut view)?).ok()?.to_owned();
    let host = if port == 22 {
        ip.to_string()
    } else {
        format!("[{ip}]:{port}")
    };
    Some(format!("{host} {key_type} {}", STANDARD.encode(blob)))
}

/// Connects to the pinned target, retrieves the host key and verifies it
/// against the owner-approved fingerprint. Returns the exact known_hosts line.
pub(crate) async fn pinned_ssh_known_host(
    ip: IpAddr,
    port: u16,
    algorithm: &str,
    fingerprint: &str,
) -> Result<String, ()> {
    let work = async {
        let mut stream = TcpStream::connect((ip, port)).await.map_err(|_| ())?;
        let blob = fetch_ssh_host_key(&mut stream, algorithm).await.map_err(|_| ())?;
        let observed = ssh_fingerprint(&blob);
        use subtle_eq::ct_eq;
        if !ct_eq(observed.as_bytes(), fingerprint.as_bytes()) {
            return Err(());
        }
        known_hosts_line(ip, port, &blob).ok_or(())
    };
    timeout(SSH_PREFLIGHT_TIMEOUT, work).await.map_err(|_| ())?
}

mod subtle_eq {
    pub(crate) fn ct_eq(left: &[u8], right: &[u8]) -> bool {
        if left.len() != right.len() {
            return false;
        }
        left.iter().zip(right).fold(0_u8, |acc, (a, b)| acc | (a ^ b)) == 0
    }
}

// ---------------------------------------------------------------------------
// guacd handshake for gateway connections
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
pub(crate) struct Permissions {
    pub(crate) clipboard_to_remote: bool,
    pub(crate) clipboard_from_remote: bool,
    pub(crate) view_only: bool,
}

pub(crate) fn clamp_display(state: &AppState, inner: &CapsuleInner, width: u16, height: u16) -> (u16, u16) {
    let max_w = state.cloud.config.max_display_width;
    let max_h = state.cloud.config.max_display_height;
    let (w, h) = match (inner.display_mode.as_deref(), inner.display_width, inner.display_height) {
        (Some("fixed"), Some(w), Some(h)) => (w, h),
        _ => (width, height),
    };
    clamp_size(w, h, max_w, max_h)
}

/// Clamps to [320×200, max] preserving aspect ratio when scaling down.
pub(crate) fn clamp_size(w: u16, h: u16, max_w: u16, max_h: u16) -> (u16, u16) {
    let (mut w, mut h) = (f64::from(w.max(1)), f64::from(h.max(1)));
    let scale = (f64::from(max_w) / w).min(f64::from(max_h) / h).min(1.0);
    w *= scale;
    h *= scale;
    ((w as u16).clamp(320, max_w), (h as u16).clamp(200, max_h))
}

/// Builds the guacd `connect` instruction from the unsealed capsule. Values
/// for unknown arguments are empty (guacd defaults, which keep drives,
/// printing, SFTP, recording, reverse connections and RemoteApp off).
/// Missing security-relevant arguments fail closed.
pub(crate) async fn gateway_handshake<S>(
    tcp: &mut S,
    inner: &CapsuleInner,
    ip: IpAddr,
    port: u16,
    perms: Permissions,
    size: (u16, u16),
    known_host: Option<&str>,
) -> Result<(), ()>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    let protocol = inner.protocol.as_str();
    if !matches!(protocol, "ssh" | "rdp" | "vnc")
        || inner.username.len() > 256
        || inner.username.contains('\0')
        || inner.password.as_deref().is_some_and(|p| p.len() > 65536 || p.contains('\0'))
        || inner.private_key.as_deref().is_some_and(|p| p.len() > 262_144 || p.contains('\0'))
        || inner.passphrase.as_deref().is_some_and(|p| p.len() > 16384 || p.contains('\0'))
    {
        return Err(());
    }
    if protocol == "ssh" && known_host.is_none() {
        return Err(());
    }
    tcp.write_all(crate::desktop::encode(&["select", protocol]).as_bytes())
        .await
        .map_err(|_| ())?;
    let mut buffer = Vec::new();
    let args = loop {
        buffer.push(tcp.read_u8().await.map_err(|_| ())?);
        if buffer.len() > 16384 {
            return Err(());
        }
        if let Some((values, _)) = crate::desktop::parse(&buffer)? {
            break values;
        }
    };
    if args.first().map(String::as_str) != Some("args") {
        return Err(());
    }
    let has = |name: &str| args.iter().skip(1).any(|arg| arg == name);
    // Restrictions that must be enforced by guacd itself (in addition to the
    // gateway's own instruction filters).
    if !has("disable-copy") || !has("disable-paste") || (perms.view_only && !has("read-only")) {
        return Err(());
    }
    if protocol == "ssh" && !has("host-key") {
        return Err(());
    }
    if protocol == "rdp" && (!has("cert-fingerprints") || !has("ignore-cert")) {
        return Err(());
    }
    let (width, height) = size;
    for fields in [
        vec!["size".to_owned(), width.to_string(), height.to_string(), "96".to_owned()],
        vec!["audio".to_owned()],
        vec!["video".to_owned()],
        vec!["image".to_owned(), "image/png".to_owned(), "image/jpeg".to_owned()],
    ] {
        tcp.write_all(crate::desktop::encode(&fields.iter().map(String::as_str).collect::<Vec<_>>()).as_bytes())
            .await
            .map_err(|_| ())?;
    }
    let bool_text = |value: bool| if value { "true" } else { "false" }.to_owned();
    let mut values = vec!["connect".to_owned()];
    for arg in &args[1..] {
        values.push(match arg.as_str() {
            v if v.starts_with("VERSION_") => "VERSION_1_0_0".to_owned(),
            "hostname" => ip.to_string(),
            "port" => port.to_string(),
            "username" => inner.username.clone(),
            "password" => inner.password.clone().unwrap_or_default(),
            "private-key" if protocol == "ssh" => inner.private_key.clone().unwrap_or_default(),
            "passphrase" if protocol == "ssh" => inner.passphrase.clone().unwrap_or_default(),
            "host-key" if protocol == "ssh" => known_host.unwrap_or_default().to_owned(),
            "cert-fingerprints" if protocol == "rdp" => inner
                .host_identity
                .as_deref()
                .map(|pin| {
                    format!(
                        "sha256:{}",
                        pin.to_ascii_lowercase()
                            .as_bytes()
                            .chunks(2)
                            .map(|b| std::str::from_utf8(b).unwrap_or(""))
                            .collect::<Vec<_>>()
                            .join(":")
                    )
                })
                .unwrap_or_default(),
            "ignore-cert" => "false".to_owned(),
            "security" if protocol == "rdp" => match inner.rdp_security.as_deref() {
                Some("tls") => "tls".to_owned(),
                _ => "nla".to_owned(),
            },
            "width" => width.to_string(),
            "height" => height.to_string(),
            "dpi" => "96".to_owned(),
            "resize-method" => "display-update".to_owned(),
            "disable-copy" => bool_text(!perms.clipboard_from_remote),
            "disable-paste" => bool_text(!perms.clipboard_to_remote),
            "read-only" => bool_text(perms.view_only),
            "disable-audio" | "disable-gfx" | "force-lossless" => "true".to_owned(),
            "disable-download" | "disable-upload" => "true".to_owned(),
            "enable-drive" | "enable-printing" | "enable-sftp" | "enable-audio-input"
            | "enable-touch" | "create-drive-path" | "create-recording-path"
            | "create-typescript-path" | "reverse-connect" | "wol-send-packet"
            | "enable-audio" => "false".to_owned(),
            _ => String::new(),
        });
    }
    let mut instruction = crate::desktop::encode(&values.iter().map(String::as_str).collect::<Vec<_>>());
    let result = tcp.write_all(instruction.as_bytes()).await.map_err(|_| ());
    instruction.zeroize();
    for value in &mut values {
        value.zeroize();
    }
    result
}

// ---------------------------------------------------------------------------
// Instruction filters
// ---------------------------------------------------------------------------

/// Concurrently open guest clipboard streams (a browser opens one per paste).
const MAX_GUEST_STREAMS: usize = 2;
/// Base64 characters of one clipboard paste (64 KiB decoded, as guacd's own
/// clipboard limit) and of all pastes on one connection.
const MAX_GUEST_STREAM_CHARS: usize = 87_384;
const MAX_GUEST_CLIPBOARD_CHARS_TOTAL: usize = 4 * 1024 * 1024;
/// Tracked guacd → guest streams that are being suppressed or metered.
const MAX_TRACKED_OUTPUT_STREAMS: usize = 64;
const MAX_OUTPUT_CLIPBOARD_CHARS: usize = 262_144;

#[derive(Clone, Copy, PartialEq, Eq)]
enum GuestStream {
    /// Forwarded clipboard stream with its accumulated base64 size.
    Forward(usize),
    /// Policy-suppressed clipboard stream (paste disabled or view-only); its
    /// blobs are consumed silently so the browser can finish the stream.
    Suppress,
}

/// Guest → guacd filter. Accepts only the existing desktop input whitelist,
/// then applies link permissions and clipboard stream lifecycle rules.
/// Returns re-encoded allowed instructions, or `None` for a protocol
/// violation (the socket is closed with 4400).
pub(crate) struct InputFilter {
    pub(crate) perms: Permissions,
    pub(crate) max: (u16, u16),
    last_sizes: std::collections::VecDeque<std::time::Instant>,
    streams: std::collections::HashMap<String, GuestStream>,
    clipboard_total: usize,
}

impl InputFilter {
    pub(crate) fn new(perms: Permissions, max: (u16, u16)) -> Self {
        Self {
            perms,
            max,
            last_sizes: Default::default(),
            streams: Default::default(),
            clipboard_total: 0,
        }
    }

    pub(crate) fn filter(&mut self, bytes: &[u8]) -> Option<Vec<u8>> {
        if !crate::desktop::valid_input(bytes) {
            return None;
        }
        let mut rest = bytes;
        let mut out = Vec::with_capacity(bytes.len());
        while !rest.is_empty() {
            let (values, count) = crate::desktop::parse(rest).ok()??;
            rest = &rest[count..];
            let opcode = values[0].as_str();
            let allowed = match opcode {
                "key" | "mouse" => !self.perms.view_only,
                "clipboard" => {
                    let stream = values[1].clone();
                    // Reusing an index that is still open is a violation.
                    if self.streams.contains_key(&stream) || self.streams.len() >= MAX_GUEST_STREAMS {
                        return None;
                    }
                    // View-only always wins over a conflicting paste policy.
                    let forward = self.perms.clipboard_to_remote && !self.perms.view_only;
                    self.streams.insert(stream, if forward { GuestStream::Forward(0) } else { GuestStream::Suppress });
                    forward
                }
                "blob" => match self.streams.get_mut(&values[1]) {
                    // Orphan, stale or unknown stream index.
                    None => return None,
                    Some(GuestStream::Suppress) => false,
                    Some(GuestStream::Forward(size)) => {
                        *size += values[2].len();
                        self.clipboard_total += values[2].len();
                        if *size > MAX_GUEST_STREAM_CHARS || self.clipboard_total > MAX_GUEST_CLIPBOARD_CHARS_TOTAL {
                            return None;
                        }
                        true
                    }
                },
                "end" => match self.streams.remove(&values[1]) {
                    None => return None,
                    Some(GuestStream::Suppress) => false,
                    Some(GuestStream::Forward(_)) => true,
                },
                "size" => {
                    let now = std::time::Instant::now();
                    while self
                        .last_sizes
                        .front()
                        .is_some_and(|t| now.duration_since(*t) > Duration::from_secs(1))
                    {
                        self.last_sizes.pop_front();
                    }
                    if self.last_sizes.len() >= 4 {
                        false
                    } else {
                        self.last_sizes.push_back(now);
                        let w: u16 = values[1].parse().unwrap_or(0);
                        let h: u16 = values[2].parse().unwrap_or(0);
                        let (w, h) = clamp_size(w, h, self.max.0, self.max.1);
                        out.extend_from_slice(
                            crate::desktop::encode(&["size", &w.to_string(), &h.to_string()]).as_bytes(),
                        );
                        continue;
                    }
                }
                _ => true,
            };
            if allowed {
                out.extend_from_slice(
                    crate::desktop::encode(&values.iter().map(String::as_str).collect::<Vec<_>>()).as_bytes(),
                );
            }
        }
        Some(out)
    }
}

/// Server-originated instructions that open (or re-open) a stream index.
const STREAM_OPENERS: &[&str] = &["img", "audio", "video", "file", "pipe", "clipboard", "argv", "body", "filesystem"];

#[derive(Clone, Copy, PartialEq, Eq)]
enum OutputStream {
    Drop,
    Clipboard(usize),
}

/// guacd → guest filter. Drops clipboard streams unless remote→guest copy is
/// allowed, and always drops file/pipe/argv streams and `required`
/// credential prompts. Stream state is per index: any opener re-binds the
/// index (so a reused index for an image is never suppressed), `end` frees
/// it, and tracked state is bounded in count and allowed clipboard size.
pub(crate) struct OutputFilter {
    allow_clipboard: bool,
    streams: std::collections::HashMap<String, OutputStream>,
    buffer: Vec<u8>,
}

impl OutputFilter {
    pub(crate) fn new(allow_clipboard: bool) -> Self {
        Self {
            allow_clipboard,
            streams: Default::default(),
            buffer: Vec::new(),
        }
    }

    /// Appends guacd bytes; returns complete allowed instructions.
    pub(crate) fn push(&mut self, bytes: &[u8]) -> Result<Vec<u8>, ()> {
        self.buffer.extend_from_slice(bytes);
        let mut out = Vec::with_capacity(self.buffer.len());
        let mut consumed = 0;
        loop {
            match crate::desktop::parse(&self.buffer[consumed..])? {
                None => break,
                Some((values, count)) => {
                    let start = consumed;
                    consumed += count;
                    let opcode = values[0].as_str();
                    let stream = values.get(1).cloned().unwrap_or_default();
                    let forward = if STREAM_OPENERS.contains(&opcode) {
                        self.streams.remove(&stream);
                        let tracked = match opcode {
                            "clipboard" if self.allow_clipboard => Some(OutputStream::Clipboard(0)),
                            "clipboard" | "file" | "pipe" | "argv" => Some(OutputStream::Drop),
                            _ => None,
                        };
                        match tracked {
                            Some(kind) => {
                                if self.streams.len() >= MAX_TRACKED_OUTPUT_STREAMS {
                                    return Err(());
                                }
                                self.streams.insert(stream, kind);
                                kind != OutputStream::Drop
                            }
                            None => true,
                        }
                    } else {
                        match opcode {
                            "required" => false,
                            "blob" => match self.streams.get_mut(&stream) {
                                Some(OutputStream::Drop) => false,
                                Some(OutputStream::Clipboard(size)) => {
                                    *size += values.get(2).map_or(0, String::len);
                                    if *size > MAX_OUTPUT_CLIPBOARD_CHARS {
                                        return Err(());
                                    }
                                    true
                                }
                                None => true,
                            },
                            "end" => !matches!(self.streams.remove(&stream), Some(OutputStream::Drop)),
                            _ => true,
                        }
                    };
                    if forward {
                        out.extend_from_slice(&self.buffer[start..consumed]);
                    }
                }
            }
        }
        self.buffer.drain(..consumed);
        if self.buffer.len() > 1024 * 1024 {
            return Err(());
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::desktop::encode;

    /// Cross-implementation vector shared with the Dart client test
    /// (apps/client/test/cloud_access_interop_test.dart): libsodium-sealed and
    /// Dart-sealed boxes open here; the Rust-sealed box opens in Dart; the
    /// Dart-built signed capsule verifies and unseals with server code.
    #[test]
    fn sealed_box_and_capsule_interop_vector() {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../protocol/test-vectors/share-gateway-v1.json");
        let mut vector: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let text = |v: &Value, k: &str| v[k].as_str().unwrap().to_owned();
        let bytes = |v: &Value, k: &str| URL_SAFE_NO_PAD.decode(v[k].as_str().unwrap()).unwrap();
        let secret: [u8; 32] = bytes(&vector, "gateway_secret_key").try_into().unwrap();
        let key = GatewayKey::from_secret_for_tests(secret, "11111111-1111-4111-8111-111111111111");
        assert_eq!(key.public_key, text(&vector, "gateway_public_key"));
        let message = bytes(&vector, "message");
        assert_eq!(&*key.unseal(&bytes(&vector, "libsodium_sealed")).unwrap(), &message);
        if std::env::var_os("ATERMIUS_WRITE_SHARE_VECTOR").is_some() {
            vector["rust_sealed"] = json!(URL_SAFE_NO_PAD.encode(key.seal_for_tests(&message)));
            std::fs::write(&path, serde_json::to_string_pretty(&vector).unwrap() + "\n").unwrap();
            return;
        }
        assert!(vector.get("rust_sealed").is_some(), "vector lacks the Rust-sealed box");
        let dart_sealed = vector.get("dart_sealed").expect("vector lacks the Dart-sealed box");
        assert_eq!(&*key.unseal(&URL_SAFE_NO_PAD.decode(dart_sealed.as_str().unwrap()).unwrap()).unwrap(), &message);
        // Dart-built capsule: device signature, digest binding and unseal.
        let capsule = &vector["dart_capsule"];
        let header: CapsuleHeader = serde_json::from_value(capsule["header"].clone()).unwrap();
        let signing = ed25519_dalek::SigningKey::from_bytes(&bytes(&vector, "device_signing_seed").try_into().unwrap());
        let public = URL_SAFE_NO_PAD.encode(signing.verifying_key().as_bytes());
        crate::auth::verify_key_signature(&public, header.signature.as_deref().unwrap(), &header.signed_bytes().unwrap()).unwrap();
        let sealed = URL_SAFE_NO_PAD.decode(capsule["sealed"].as_str().unwrap()).unwrap();
        assert_eq!(URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed)), header.sealed_sha256);
        let row = CapsuleRow {
            vault_id: header.vault_id.clone(),
            host_record_id: header.host_record_id.clone(),
            host_revision_id: header.host_revision_id.clone(),
            gateway_key_id: header.gateway_key_id.clone(),
            protocol: header.protocol.clone(),
            target_host: header.target_host.clone(),
            target_port: header.target_port,
            host_identity: header.host_identity.clone(),
            sealed: capsule["sealed"].as_str().unwrap().to_owned(),
        };
        let mut gateway = key;
        gateway.key_id = header.gateway_key_id.clone();
        let plaintext = gateway.unseal(&sealed).unwrap();
        let inner: CapsuleInner = serde_json::from_slice(&plaintext).unwrap();
        assert_eq!(inner.username, "fixture");
        assert_eq!(inner.ssh_host_key_algorithm(), "ssh-ed25519");
        assert_eq!(inner.host_record_id, row.host_record_id);
        // Tampering with a bound header field breaks the signature.
        let mut forged = header.clone();
        forged.target_port = 2223;
        assert!(crate::auth::verify_key_signature(&public, header.signature.as_deref().unwrap(), &forged.signed_bytes().unwrap()).is_err());
    }

    #[test]
    fn identity_pins_are_strict() {
        let fp = format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([7_u8; 32]));
        assert!(valid_identity("ssh", Some(&fp)));
        assert!(!valid_identity("ssh", None));
        assert!(!valid_identity("ssh", Some("SHA256:short")));
        assert!(valid_identity("rdp", Some(&"ab".repeat(32))));
        assert!(!valid_identity("rdp", Some("zz")));
        assert!(!valid_identity("rdp", None));
        assert!(valid_identity("vnc", None));
        assert!(!valid_identity("telnet", None));
    }

    #[test]
    fn display_is_clamped_to_policy_preserving_aspect() {
        assert_eq!(clamp_size(2560, 1440, 1920, 1200), (1920, 1080));
        assert_eq!(clamp_size(1280, 800, 1920, 1200), (1280, 800));
        assert_eq!(clamp_size(100, 50, 1920, 1200), (320, 200));
        assert_eq!(clamp_size(4096, 4096, 1920, 1200), (1200, 1200));
    }

    #[test]
    fn input_filter_enforces_view_only_and_clipboard_policy() {
        let mut filter = InputFilter::new(
            Permissions { clipboard_to_remote: false, clipboard_from_remote: false, view_only: false },
            (1920, 1200),
        );
        let key = encode(&["key", "65", "1"]);
        assert_eq!(filter.filter(key.as_bytes()).unwrap(), key.as_bytes());
        let clip = encode(&["clipboard", "0", "text/plain"]) + &encode(&["blob", "0", "aGk="]) + &encode(&["end", "0"]);
        assert!(filter.filter(clip.as_bytes()).unwrap().is_empty());
        for forbidden in ["select", "connect", "file", "put", "pipe", "argv"] {
            assert!(filter.filter(encode(&[forbidden, "x"]).as_bytes()).is_none(), "{forbidden}");
        }
        let resized = filter.filter(encode(&["size", "4000", "3000"]).as_bytes()).unwrap();
        assert_eq!(resized, encode(&["size", "1600", "1200"]).as_bytes());

        let mut view = InputFilter::new(
            Permissions { clipboard_to_remote: true, clipboard_from_remote: true, view_only: true },
            (1920, 1200),
        );
        assert!(view.filter(key.as_bytes()).unwrap().is_empty());
        assert!(view.filter(encode(&["mouse", "1", "1", "1"]).as_bytes()).unwrap().is_empty());
        let sync = encode(&["sync", "5"]);
        assert_eq!(view.filter(sync.as_bytes()).unwrap(), sync.as_bytes());

        let mut clip_ok = InputFilter::new(
            Permissions { clipboard_to_remote: true, clipboard_from_remote: false, view_only: false },
            (1920, 1200),
        );
        assert_eq!(clip_ok.filter(clip.as_bytes()).unwrap(), clip.as_bytes());
    }

    fn perms(paste: bool, copy: bool, view: bool) -> Permissions {
        Permissions { clipboard_to_remote: paste, clipboard_from_remote: copy, view_only: view }
    }

    #[test]
    fn input_clipboard_streams_have_a_strict_lifecycle_and_bounds() {
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        // Orphan blob/end (no open clipboard stream) are violations.
        assert!(filter.filter(encode(&["blob", "3", "aGk="]).as_bytes()).is_none());
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        assert!(filter.filter(encode(&["end", "3"]).as_bytes()).is_none());
        // Mismatched index.
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        assert!(filter.filter(encode(&["clipboard", "1", "text/plain"]).as_bytes()).is_some());
        assert!(filter.filter(encode(&["blob", "2", "aGk="]).as_bytes()).is_none());
        // Reusing an open index.
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        assert!(filter.filter(encode(&["clipboard", "1", "text/plain"]).as_bytes()).is_some());
        assert!(filter.filter(encode(&["clipboard", "1", "text/plain"]).as_bytes()).is_none());
        // Stale index after end.
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        let paste = encode(&["clipboard", "1", "text/plain"]) + &encode(&["blob", "1", "aGk="]) + &encode(&["end", "1"]);
        assert_eq!(filter.filter(paste.as_bytes()).unwrap(), paste.as_bytes());
        assert!(filter.filter(encode(&["blob", "1", "aGk="]).as_bytes()).is_none());
        // Index can be reused after a clean end.
        assert_eq!(filter.filter(paste.as_bytes()).unwrap(), paste.as_bytes());
        // Too many concurrently open streams.
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        for id in ["1", "2"] {
            assert!(filter.filter(encode(&["clipboard", id, "text/plain"]).as_bytes()).is_some());
        }
        assert!(filter.filter(encode(&["clipboard", "3", "text/plain"]).as_bytes()).is_none());
        // Per-stream cumulative overflow (each blob within the per-instruction limit).
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        assert!(filter.filter(encode(&["clipboard", "1", "text/plain"]).as_bytes()).is_some());
        let chunk = "A".repeat(40_000);
        assert!(filter.filter(encode(&["blob", "1", &chunk]).as_bytes()).is_some());
        assert!(filter.filter(encode(&["blob", "1", &chunk]).as_bytes()).is_some());
        assert!(filter.filter(encode(&["blob", "1", &chunk]).as_bytes()).is_none());
        // Connection-wide cumulative overflow across many small pastes.
        let mut filter = InputFilter::new(perms(true, false, false), (1920, 1200));
        let small = "B".repeat(40_000);
        let mut violated = false;
        for _ in 0..200 {
            let paste = encode(&["clipboard", "1", "text/plain"]) + &encode(&["blob", "1", &small]) + &encode(&["end", "1"]);
            if filter.filter(paste.as_bytes()).is_none() {
                violated = true;
                break;
            }
        }
        assert!(violated, "aggregate clipboard bytes are bounded");
        // Paste disabled or view-only: the stream is consumed silently, nothing forwarded.
        for p in [perms(false, true, false), perms(true, true, true)] {
            let mut filter = InputFilter::new(p, (1920, 1200));
            let paste = encode(&["clipboard", "1", "text/plain"]) + &encode(&["blob", "1", "c2VjcmV0"]) + &encode(&["end", "1"]);
            assert_eq!(filter.filter(paste.as_bytes()).unwrap(), b"");
            assert!(filter.filter(encode(&["blob", "1", "c2VjcmV0"]).as_bytes()).is_none());
        }
    }

    #[test]
    fn output_streams_rebind_on_reuse_and_are_bounded() {
        // A dropped clipboard stream index later reused by an image: image
        // blobs must flow (display not broken), clipboard blobs must not.
        let mut filter = OutputFilter::new(false);
        let text = String::from_utf8(
            filter
                .push((encode(&["clipboard", "4", "text/plain"]) + &encode(&["blob", "4", "c2VjcmV0"])
                    + &encode(&["img", "4", "14", "0", "image/png", "0", "0"]) + &encode(&["blob", "4", "cGl4"])
                    + &encode(&["end", "4"]) + &encode(&["blob", "4", "bGF0ZQ=="])).as_bytes())
                .unwrap(),
        )
        .unwrap();
        assert!(!text.contains("c2VjcmV0") && text.contains("cGl4") && text.contains("8.bGF0ZQ=="));
        // Bounded tracked state.
        let mut filter = OutputFilter::new(false);
        let mut flood = String::new();
        for id in 0..80 {
            flood += &encode(&["file", &id.to_string(), "application/octet-stream", "x"]);
        }
        assert!(filter.push(flood.as_bytes()).is_err());
        // Allowed clipboard copy is metered.
        let mut filter = OutputFilter::new(true);
        assert!(filter.push(encode(&["clipboard", "2", "text/plain"]).as_bytes()).is_ok());
        let big = "Q".repeat(200_000);
        assert!(filter.push(encode(&["blob", "2", &big]).as_bytes()).is_ok());
        assert!(filter.push(encode(&["blob", "2", &big]).as_bytes()).is_err());
    }

    #[test]
    fn size_instructions_are_rate_limited() {
        let mut filter = InputFilter::new(
            Permissions { clipboard_to_remote: false, clipboard_from_remote: false, view_only: false },
            (1920, 1200),
        );
        let size = encode(&["size", "800", "600"]);
        let mut forwarded = 0;
        for _ in 0..10 {
            if !filter.filter(size.as_bytes()).unwrap().is_empty() {
                forwarded += 1;
            }
        }
        assert_eq!(forwarded, 4);
    }

    #[test]
    fn output_filter_drops_clipboard_file_and_prompt_streams_across_fragments() {
        let mut filter = OutputFilter::new(false);
        let stream = encode(&["img", "1", "14", "0", "image/png", "0", "0"])
            + &encode(&["clipboard", "7", "text/plain"])
            + &encode(&["blob", "7", "c2VjcmV0"])
            + &encode(&["blob", "1", "cGl4"])
            + &encode(&["end", "7"])
            + &encode(&["file", "8", "application/octet-stream", "x"])
            + &encode(&["blob", "8", "eA=="])
            + &encode(&["required", "password"])
            + &encode(&["sync", "9"]);
        let mut out = Vec::new();
        for chunk in stream.as_bytes().chunks(5) {
            out.extend(filter.push(chunk).unwrap());
        }
        let text = String::from_utf8(out).unwrap();
        assert!(text.contains("3.img") && text.contains("4.sync") && text.contains("4.cGl4"));
        assert!(!text.contains("clipboard") && !text.contains("c2VjcmV0"));
        assert!(!text.contains("4.file") && !text.contains("eA==") && !text.contains("required"));

        let mut allow = OutputFilter::new(true);
        let clip = encode(&["clipboard", "7", "text/plain"]) + &encode(&["blob", "7", "aGk="]);
        assert_eq!(allow.push(clip.as_bytes()).unwrap(), clip.as_bytes());
    }

    #[test]
    fn known_hosts_lines_pin_the_checked_address() {
        let mut blob = Vec::new();
        put_string(&mut blob, b"ssh-ed25519");
        put_string(&mut blob, &[1_u8; 32]);
        let line22 = known_hosts_line("192.0.2.5".parse().unwrap(), 22, &blob).unwrap();
        assert!(line22.starts_with("192.0.2.5 ssh-ed25519 "));
        let line = known_hosts_line("2001:db8::5".parse().unwrap(), 2222, &blob).unwrap();
        assert!(line.starts_with("[2001:db8::5]:2222 ssh-ed25519 "));
        assert!(ssh_fingerprint(&blob).starts_with("SHA256:"));
        assert_eq!(ssh_fingerprint(&blob).len(), 50);
    }

    /// A scripted SSH server proves the prelude parser returns the advertised
    /// host key blob and rejects a key of another type.
    #[tokio::test]
    async fn ssh_prelude_reads_host_key_blob_and_checks_type() {
        for (offered, expect_ok) in [("ssh-ed25519", true), ("ssh-rsa", false)] {
            let (mut client, mut server) = tokio::io::duplex(65536);
            let offered = offered.to_owned();
            let server_task = tokio::spawn(async move {
                server.write_all(b"banner line\r\nSSH-2.0-Fixture\r\n").await.unwrap();
                let mut ident = Vec::new();
                loop {
                    let b = server.read_u8().await.unwrap();
                    ident.push(b);
                    if b == b'\n' {
                        break;
                    }
                }
                assert!(ident.starts_with(b"SSH-2.0-AtermiusGateway"));
                let kexinit = read_ssh_packet(&mut server).await.unwrap();
                assert_eq!(kexinit[0], 20);
                let init = read_ssh_packet(&mut server).await.unwrap();
                assert_eq!(init[0], 30);
                let mut server_kex = vec![20_u8];
                server_kex.extend_from_slice(&[0; 16]);
                for _ in 0..10 {
                    put_string(&mut server_kex, b"x");
                }
                server_kex.extend_from_slice(&[0, 0, 0, 0, 0]);
                server.write_all(&ssh_packet(&server_kex)).await.unwrap();
                let mut blob = Vec::new();
                put_string(&mut blob, offered.as_bytes());
                put_string(&mut blob, &[9_u8; 32]);
                let mut reply = vec![31_u8];
                put_string(&mut reply, &blob);
                put_string(&mut reply, &[1_u8; 32]);
                put_string(&mut reply, b"sig");
                server.write_all(&ssh_packet(&reply)).await.unwrap();
                blob
            });
            let result = fetch_ssh_host_key(&mut client, "ssh-ed25519").await;
            let blob = server_task.await.unwrap();
            if expect_ok {
                assert_eq!(result.unwrap(), blob);
            } else {
                assert!(result.is_err());
            }
        }
    }

    #[tokio::test]
    async fn guacd_handshake_fails_closed_without_required_args_and_pins_ip() {
        let inner = CapsuleInner {
            format: CAPSULE_INNER_FORMAT.into(),
            vault_id: "v".into(),
            host_record_id: "h".into(),
            host_revision_id: "r".into(),
            gateway_key_id: "k".into(),
            record_kind: "host".into(),
            protocol: "ssh".into(),
            target_host: "db.example".into(),
            target_port: 22,
            username: "deploy".into(),
            password: Some("SENTINEL-PASSWORD".into()),
            private_key: None,
            passphrase: None,
            host_identity: Some("SHA256:x".into()),
            ssh_host_key_algorithm: Some("ssh-ed25519".into()),
            rdp_security: None,
            display_mode: None,
            display_width: None,
            display_height: None,
        };
        let perms = Permissions { clipboard_to_remote: false, clipboard_from_remote: false, view_only: true };
        // guacd without disable-copy → refuse.
        let (mut gw, mut guacd) = tokio::io::duplex(65536);
        let peer = tokio::spawn(async move {
            let mut buf = vec![0_u8; 64];
            let _ = guacd.read(&mut buf).await;
            guacd
                .write_all(encode(&["args", "VERSION_1_5_0", "hostname", "port", "host-key", "read-only"]).as_bytes())
                .await
                .unwrap();
            let mut rest = Vec::new();
            let _ = guacd.read_to_end(&mut rest).await;
            rest
        });
        let ip: IpAddr = "192.0.2.10".parse().unwrap();
        assert!(gateway_handshake(&mut gw, &inner, ip, 22, perms, (1024, 768), Some("192.0.2.10 ssh-ed25519 AAAA")).await.is_err());
        drop(gw);
        assert!(peer.await.unwrap().is_empty());

        let (mut gw, mut guacd) = tokio::io::duplex(65536);
        let peer = tokio::spawn(async move {
            let mut select = vec![0_u8; 64];
            let n = guacd.read(&mut select).await.unwrap();
            assert_eq!(&select[..n], encode(&["select", "ssh"]).as_bytes());
            guacd
                .write_all(
                    encode(&[
                        "args", "VERSION_1_5_0", "hostname", "port", "username", "password",
                        "host-key", "enable-sftp", "disable-copy", "disable-paste", "read-only",
                        "recording-path",
                    ])
                    .as_bytes(),
                )
                .await
                .unwrap();
            let mut rest = Vec::new();
            let _ = guacd.read_to_end(&mut rest).await;
            String::from_utf8(rest).unwrap()
        });
        gateway_handshake(&mut gw, &inner, ip, 22, perms, (1024, 768), Some("192.0.2.10 ssh-ed25519 AAAA")).await.unwrap();
        drop(gw);
        let sent = peer.await.unwrap();
        let connect = sent.rsplit(';').nth(1).unwrap();
        assert!(connect.contains("10.192.0.2.10"), "hostname must be the pinned IP: {connect}");
        assert!(connect.contains("6.deploy") && connect.contains("17.SENTINEL-PASSWORD"));
        assert!(connect.contains("27.192.0.2.10 ssh-ed25519 AAAA"));
        // enable-sftp=false, disable-copy=true, disable-paste=true, read-only=true, recording-path empty
        assert!(connect.ends_with("5.false,4.true,4.true,4.true,0."), "{connect}");
        assert!(!connect.contains("db.example"));
    }
}

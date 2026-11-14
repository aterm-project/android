use crate::{ApiError, AppState, current_user, now_rfc3339, sha256_hex};
use axum::{
    Json,
    extract::{
        Path, State,
        rejection::JsonRejection,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode, header::ORIGIN},
    response::IntoResponse,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use chrono::{DateTime, Duration as ChronoDuration, Utc};
use futures_util::{SinkExt, StreamExt};
use hkdf::Hkdf;
use ipnet::IpNet;
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, Sqlite, Transaction};
use std::{
    collections::HashSet,
    future::Future,
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs},
    pin::Pin,
    sync::{Arc, LazyLock},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::{OwnedSemaphorePermit, Semaphore},
    time::{Instant, Interval, timeout},
};
use zeroize::Zeroizing;

pub(crate) const MAX_GLOBAL_RELAY_CONNECTIONS: usize = 256;
const MAX_RELAY_DURATION: Duration = Duration::from_secs(60 * 60);
const RELAY_CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const RELAY_IO_TIMEOUT: Duration = Duration::from_secs(30);
const RELAY_SESSION_CHECK_TIMEOUT: Duration = Duration::from_secs(5);
const RELAY_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_RELAY_BYTES: u64 = 1024 * 1024 * 1024;
const RELAY_POLL_SESSION_SECONDS: u64 = 2;
pub(crate) const TICKET_TTL_SECONDS: i64 = 30;
pub(crate) const TICKET_RATE_WINDOW_SECONDS: i64 = 60;
pub(crate) const MAX_TICKETS_PER_USER_PER_WINDOW: i64 = 20;
pub(crate) const MAX_RETAINED_TICKETS: i64 = 100_000;
const RELAY_DESTINATION_PREFIX: &str = "rtd1:";
const RELAY_DESTINATION_KDF_SALT: &[u8] = b"atermius/server-key-derivation/v1";
const RELAY_DESTINATION_KDF_INFO: &[u8] = b"atermius/relay-ticket-destination-encryption/v1";
const RELAY_DESTINATION_AAD_PREFIX: &[u8] = b"atermius/relay-ticket-destination/aad/v1\0";
const RELAY_DNS_LOOKUP_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_RELAY_DNS_ANSWERS: usize = 32;
const MAX_CONCURRENT_RELAY_DNS_LOOKUPS: usize = 32;
static RELAY_DNS_LOOKUP_SLOTS: LazyLock<Arc<Semaphore>> =
    LazyLock::new(|| Arc::new(Semaphore::new(MAX_CONCURRENT_RELAY_DNS_LOOKUPS)));
pub(crate) const MAX_RELAY_POLICY_CIDRS: usize = 256;
pub(crate) const MAX_RELAY_POLICY_PORTS: usize = 4096;
pub(crate) const MAX_RELAY_POLICY_CIDR_LENGTH: usize = 64;
const EC2_IPV6_METADATA: Ipv6Addr = Ipv6Addr::new(0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254);
const ALIBABA_IPV4_METADATA: Ipv4Addr = Ipv4Addr::new(100, 100, 100, 200);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RelayPolicy {
    pub(crate) enabled: bool,
    pub(crate) allow_cidrs: Vec<IpNet>,
    pub(crate) allow_ports: Vec<u16>,
}

#[derive(Debug, Clone)]
pub(crate) struct RelayPolicySnapshot {
    pub(crate) policy: RelayPolicy,
    pub(crate) revision: i64,
    pub(crate) updated_at: Option<String>,
}

#[derive(Debug, Clone)]
pub(crate) struct EffectiveRelayPolicy {
    pub(crate) enabled: bool,
    pub(crate) allow_cidrs: Vec<IpNet>,
    pub(crate) allow_ports: Vec<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayPolicyUpdateRequest {
    expected_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayUserPolicyUpdateRequest {
    expected_revision: i64,
    expected_instance_policy_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelayUserPolicyResetRequest {
    expected_revision: i64,
}

struct RelayConnectionGuard {
    state: Arc<AppState>,
    user_id: String,
    _global_permit: OwnedSemaphorePermit,
}

impl Drop for RelayConnectionGuard {
    fn drop(&mut self) {
        if let Ok(mut all) = self.state.relay_connections.lock()
            && let Some(count) = all.get_mut(&self.user_id)
        {
            *count = count.saturating_sub(1);
            if *count == 0 {
                all.remove(&self.user_id);
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TicketRequest {
    pub device_id: String,
    pub target_host: String,
    pub target_port: u16,
}

#[derive(Debug, Clone)]
pub(crate) struct RelayTarget {
    pub(crate) user_id: String,
    pub(crate) device_id: String,
    pub(crate) session_id: String,
    pub(crate) ip: IpAddr,
    pub(crate) port: u16,
    pub(crate) authorization_revision: i64,
    pub(crate) connection_id: Option<uuid::Uuid>,
}

pub(crate) fn is_forbidden_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => {
            v.is_loopback()
                || v.is_link_local()
                || v.is_unspecified()
                || v.is_multicast()
                || v.is_broadcast()
                || v == Ipv4Addr::new(169, 254, 169, 254)
                || v == ALIBABA_IPV4_METADATA
        }
        IpAddr::V6(v) => {
            v.is_loopback()
                || v.is_unicast_link_local()
                || v.is_unspecified()
                || v.is_multicast()
                || v == EC2_IPV6_METADATA
                || v.to_ipv4_mapped()
                    .is_some_and(|x| is_forbidden_ip(IpAddr::V4(x)))
        }
    }
}

fn is_allowed_ip(ip: IpAddr, allowlist: &[IpNet]) -> bool {
    !is_forbidden_ip(ip) && allowlist.iter().any(|network| network.contains(&ip))
}

fn is_allowed_target(ip: IpAddr, port: u16, allowlist: &[IpNet], allowed_ports: &[u16]) -> bool {
    port != 0 && is_allowed_ip(ip, allowlist) && allowed_ports.contains(&port)
}

pub(crate) fn effective_target_allowed(
    policy: &EffectiveRelayPolicy,
    ip: IpAddr,
    port: u16,
) -> bool {
    policy.enabled && is_allowed_target(ip, port, &policy.allow_cidrs, &policy.allow_ports)
}

pub(crate) fn relay_available(state: &AppState) -> bool {
    state.config.relay_enabled
        && state
            .config
            .public_origin
            .as_deref()
            .is_some_and(|origin| !origin.trim().is_empty())
        && !state.config.relay_allow_cidrs.is_empty()
        && !state.config.relay_allow_ports.is_empty()
}

pub(crate) fn deployment_cidrs(state: &AppState) -> Vec<IpNet> {
    let mut cidrs = state
        .config
        .relay_allow_cidrs
        .iter()
        .map(|network| network.trunc())
        .collect::<Vec<_>>();
    cidrs.sort_by_key(ToString::to_string);
    cidrs.dedup();
    cidrs
}

pub(crate) fn deployment_ports(state: &AppState) -> Vec<u16> {
    let mut ports = state.config.relay_allow_ports.clone();
    ports.sort_unstable();
    ports.dedup();
    ports
}

pub(crate) fn is_network_within(child: IpNet, parent: IpNet) -> bool {
    let network = child.network();
    let parent = parent.trunc();
    child.prefix_len() >= parent.prefix_len() && parent.contains(&network)
}

pub(crate) fn intersect_network(left: IpNet, right: IpNet) -> Option<IpNet> {
    if is_network_within(left, right) {
        Some(left)
    } else if is_network_within(right, left) {
        Some(right)
    } else {
        None
    }
}

pub(crate) fn normalize_networks(mut cidrs: Vec<IpNet>) -> Vec<IpNet> {
    cidrs.sort_by_key(ToString::to_string);
    cidrs.dedup();
    let mut result = Vec::new();
    for candidate in cidrs {
        if result
            .iter()
            .copied()
            .any(|existing| is_network_within(candidate, existing))
        {
            continue;
        }
        result.retain(|existing| !is_network_within(*existing, candidate));
        result.push(candidate);
    }
    result.sort_by_key(ToString::to_string);
    result
}

pub(crate) fn default_policy(state: &AppState) -> RelayPolicy {
    RelayPolicy {
        enabled: state.config.relay_enabled,
        allow_cidrs: deployment_cidrs(state),
        allow_ports: deployment_ports(state),
    }
}

pub(crate) async fn read_policy_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
) -> Result<RelayPolicySnapshot, ApiError> {
    let row = sqlx::query(
        "SELECT enabled,allow_cidrs,allow_ports,revision,updated_at \
         FROM instance_relay_policy WHERE policy_id=1",
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(RelayPolicySnapshot {
            policy: default_policy(state),
            revision: 0,
            updated_at: None,
        });
    };

    let enabled = row.get::<i64, _>("enabled") == 1;
    let cidr_json: String = row.get("allow_cidrs");
    let port_json: String = row.get("allow_ports");
    let cidr_strings: Vec<String> = serde_json::from_str(&cidr_json).map_err(ApiError::internal)?;
    let ports: Vec<u16> = serde_json::from_str(&port_json).map_err(ApiError::internal)?;
    let cidrs = parse_stored_cidrs(cidr_strings).map_err(ApiError::internal)?;
    validate_stored_ports(&ports).map_err(ApiError::internal)?;
    Ok(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled,
            allow_cidrs: cidrs,
            allow_ports: ports,
        },
        revision: row.get("revision"),
        updated_at: row.get("updated_at"),
    })
}

pub(crate) fn parse_stored_cidrs(values: Vec<String>) -> Result<Vec<IpNet>, &'static str> {
    if values.len() > MAX_RELAY_POLICY_CIDRS {
        return Err("stored relay CIDR count exceeds its limit");
    }
    let mut cidrs = Vec::with_capacity(values.len());
    let mut seen = HashSet::with_capacity(values.len());
    for value in values {
        if value.len() > MAX_RELAY_POLICY_CIDR_LENGTH {
            return Err("stored relay CIDR is too long");
        }
        let network = value
            .parse::<IpNet>()
            .map_err(|_| "stored relay CIDR is invalid")?;
        if network.to_string() != value || network.trunc() != network || !seen.insert(network) {
            return Err("stored relay CIDR is not canonical and unique");
        }
        cidrs.push(network);
    }
    cidrs.sort_by_key(ToString::to_string);
    Ok(cidrs)
}

pub(crate) fn validate_stored_ports(ports: &[u16]) -> Result<(), &'static str> {
    if ports.len() > MAX_RELAY_POLICY_PORTS
        || ports.contains(&0)
        || ports.iter().copied().collect::<HashSet<_>>().len() != ports.len()
    {
        return Err("stored relay ports are not bounded, nonzero, and unique");
    }
    Ok(())
}

pub(crate) async fn effective_policy_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
) -> Result<EffectiveRelayPolicy, ApiError> {
    let snapshot = read_policy_tx(tx, state).await?;
    let deployment_cidrs = deployment_cidrs(state);
    let allow_cidrs = normalize_networks(
        snapshot
            .policy
            .allow_cidrs
            .iter()
            .flat_map(|configured| {
                deployment_cidrs
                    .iter()
                    .filter_map(|ceiling| intersect_network(*configured, *ceiling))
            })
            .collect(),
    );
    let deployment_ports = deployment_ports(state);
    let allow_ports = snapshot
        .policy
        .allow_ports
        .iter()
        .copied()
        .filter(|port| deployment_ports.contains(port))
        .collect();
    Ok(EffectiveRelayPolicy {
        enabled: snapshot.policy.enabled && relay_available(state),
        allow_cidrs,
        allow_ports,
    })
}

async fn read_user_policy_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<Option<RelayPolicySnapshot>, ApiError> {
    let row = sqlx::query(
        "SELECT enabled,allow_cidrs,allow_ports,revision,updated_at \
         FROM user_relay_policies WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(None);
    };

    let cidr_json: String = row.get("allow_cidrs");
    let port_json: String = row.get("allow_ports");
    let cidr_strings: Vec<String> = serde_json::from_str(&cidr_json).map_err(ApiError::internal)?;
    let ports: Vec<u16> = serde_json::from_str(&port_json).map_err(ApiError::internal)?;
    Ok(Some(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled: row.get::<i64, _>("enabled") == 1,
            allow_cidrs: parse_stored_cidrs(cidr_strings).map_err(ApiError::internal)?,
            allow_ports: {
                validate_stored_ports(&ports).map_err(ApiError::internal)?;
                ports
            },
        },
        revision: row.get("revision"),
        updated_at: row.get("updated_at"),
    }))
}

async fn read_user_policy_version_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    policy: Option<&RelayPolicySnapshot>,
) -> Result<(i64, Option<String>), ApiError> {
    let row =
        sqlx::query("SELECT revision,updated_at FROM user_relay_policy_revisions WHERE user_id=?")
            .bind(user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;

    match (policy, row) {
        (Some(policy), Some(row)) => {
            let revision: i64 = row.get("revision");
            let updated_at: String = row.get("updated_at");
            if revision != policy.revision
                || policy.updated_at.as_deref() != Some(updated_at.as_str())
            {
                return Err(ApiError::internal(
                    "relay user policy version watermark does not match override row",
                ));
            }
            Ok((revision, Some(updated_at)))
        }
        (None, Some(row)) => Ok((row.get("revision"), row.get("updated_at"))),
        (Some(policy), None) => Ok((policy.revision, policy.updated_at.clone())),
        (None, None) => Ok((0, None)),
    }
}

async fn write_user_policy_version_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    revision: i64,
    updated_at: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO user_relay_policy_revisions(user_id,revision,updated_at) VALUES(?,?,?) \
         ON CONFLICT(user_id) DO UPDATE SET revision=excluded.revision,updated_at=excluded.updated_at",
    )
    .bind(user_id)
    .bind(revision)
    .bind(updated_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn effective_policy_for_user_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    user_id: &str,
) -> Result<EffectiveRelayPolicy, ApiError> {
    if state.pg_sync_pool.is_some() {
        return Err(ApiError::internal(
            "PostgreSQL Relay policy requires its shared repository",
        ));
    }
    let instance = effective_policy_tx(tx, state).await?;
    let mut effective = if let Some(user) = read_user_policy_tx(tx, user_id).await? {
        restrict_effective_policy(&instance, &user.policy)
    } else {
        instance
    };
    effective = crate::relay_groups::apply_group_restrictions_tx(tx, user_id, effective).await?;
    Ok(effective)
}

pub(crate) fn restrict_effective_policy(
    base: &EffectiveRelayPolicy,
    restriction: &RelayPolicy,
) -> EffectiveRelayPolicy {
    let allow_cidrs = normalize_networks(
        restriction
            .allow_cidrs
            .iter()
            .flat_map(|restricted| {
                base.allow_cidrs
                    .iter()
                    .filter_map(|allowed| intersect_network(*restricted, *allowed))
            })
            .collect(),
    );
    let allow_ports = restriction
        .allow_ports
        .iter()
        .copied()
        .filter(|port| base.allow_ports.contains(port))
        .collect();
    EffectiveRelayPolicy {
        enabled: base.enabled && restriction.enabled,
        allow_cidrs,
        allow_ports,
    }
}

pub(crate) fn parse_group_policy_fields(
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
) -> Result<RelayPolicy, ApiError> {
    parse_user_requested_policy(RelayUserPolicyUpdateRequest {
        expected_revision: 0,
        expected_instance_policy_revision: 0,
        enabled,
        allow_cidrs,
        allow_ports,
    })
}

fn admin_policy_json(state: &AppState, snapshot: RelayPolicySnapshot) -> Value {
    json!({
        "policy": {
            "enabled": snapshot.policy.enabled,
            "allow_cidrs": snapshot.policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "allow_ports": snapshot.policy.allow_ports,
        },
        "deployment_limits": {
            "relay_available": relay_available(state),
            "allow_cidrs": deployment_cidrs(state).iter().map(ToString::to_string).collect::<Vec<_>>(),
            "allow_ports": deployment_ports(state),
        },
        "max_connections_per_user": state.config.relay_max_connections_per_user,
        "revision": snapshot.revision,
        "updated_at": snapshot.updated_at,
    })
}

fn policy_selection_json(policy: &RelayPolicy) -> Value {
    json!({
        "enabled": policy.enabled,
        "allow_cidrs": policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "allow_ports": policy.allow_ports,
    })
}

fn effective_policy_json(policy: &EffectiveRelayPolicy) -> Value {
    json!({
        "enabled": policy.enabled,
        "allow_cidrs": policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "allow_ports": policy.allow_ports,
    })
}

fn admin_user_policy_json(
    user_id: &str,
    instance: RelayPolicySnapshot,
    user: Option<RelayPolicySnapshot>,
    effective: EffectiveRelayPolicy,
    revision: i64,
    updated_at: Option<String>,
) -> Value {
    let inherited = user.is_none();
    let selected = user
        .as_ref()
        .map(|snapshot| &snapshot.policy)
        .unwrap_or(&instance.policy);
    json!({
        "user_id": user_id,
        "inherited": inherited,
        "policy": policy_selection_json(selected),
        "effective_policy": effective_policy_json(&effective),
        "instance_policy_revision": instance.revision,
        "revision": revision,
        "updated_at": updated_at,
    })
}

async fn require_relay_policy_user_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<(), ApiError> {
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE user_id=?)")
        .bind(user_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if !exists {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "RELAY_USER_NOT_FOUND",
            "relay policy account does not exist",
        ));
    }
    Ok(())
}

pub async fn get_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let actor = crate::auth::authenticate(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_read_tx(&mut tx, &state, &actor).await?;
    require_relay_policy_user_tx(&mut tx, &user_id).await?;
    let instance = read_policy_tx(&mut tx, &state).await?;
    let user = read_user_policy_tx(&mut tx, &user_id).await?;
    let (revision, updated_at) =
        read_user_policy_version_tx(&mut tx, &user_id, user.as_ref()).await?;
    let effective = effective_policy_for_user_tx(&mut tx, &state, &user_id).await?;
    let response =
        admin_user_policy_json(&user_id, instance, user, effective, revision, updated_at);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn update_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<RelayUserPolicyUpdateRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let actor = crate::auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| invalid_user_policy_request())?;
    let expected_revision = request.expected_revision;
    let expected_instance_policy_revision = request.expected_instance_policy_revision;
    let candidate = parse_user_requested_policy(request)?;

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_write_tx(&mut tx, &state, &actor).await?;
    require_relay_policy_user_tx(&mut tx, &user_id).await?;
    let instance = read_policy_tx(&mut tx, &state).await?;
    if expected_instance_policy_revision != instance.revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "instance relay policy changed since it was read",
        ));
    }
    let current = read_user_policy_tx(&mut tx, &user_id).await?;
    let (current_revision, _) =
        read_user_policy_version_tx(&mut tx, &user_id, current.as_ref()).await?;
    if expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "relay user policy changed since it was read",
        ));
    }

    // A missing user row inherits the current instance policy. A PUT equal to
    // that inherited selection is therefore an idempotent no-op, not an
    // override row that could drift when the instance policy later changes.
    let inherited_selection = current
        .as_ref()
        .map(|snapshot| &snapshot.policy)
        .unwrap_or(&instance.policy);
    let changed = candidate != *inherited_selection;
    if changed {
        let instance_effective = effective_policy_tx(&mut tx, &state).await?;
        validate_user_policy_limits(&candidate, &instance_effective)?;
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay user policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        let cidrs = candidate
            .allow_cidrs
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let cidr_json = serde_json::to_string(&cidrs).map_err(ApiError::internal)?;
        let port_json =
            serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO user_relay_policies(user_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
             VALUES(?,?,?,?,?,?) \
             ON CONFLICT(user_id) DO UPDATE SET enabled=excluded.enabled,allow_cidrs=excluded.allow_cidrs, \
             allow_ports=excluded.allow_ports,revision=excluded.revision,updated_at=excluded.updated_at",
        )
        .bind(&user_id)
        .bind(candidate.enabled as i64)
        .bind(cidr_json)
        .bind(port_json)
        .bind(revision)
        .bind(&updated_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        write_user_policy_version_tx(&mut tx, &user_id, revision, &updated_at).await?;
        sqlx::query("DELETE FROM relay_tickets WHERE user_id=? AND consumed_at IS NULL")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &actor.user_id,
            &actor.device_id,
            "admin.relay_policy_updated",
            "relay_user_policy",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }

    let instance = read_policy_tx(&mut tx, &state).await?;
    let user = read_user_policy_tx(&mut tx, &user_id).await?;
    let (revision, updated_at) =
        read_user_policy_version_tx(&mut tx, &user_id, user.as_ref()).await?;
    let effective = effective_policy_for_user_tx(&mut tx, &state, &user_id).await?;
    let response =
        admin_user_policy_json(&user_id, instance, user, effective, revision, updated_at);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn reset_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<RelayUserPolicyResetRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let actor = crate::auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_RELAY_USER_POLICY_RESET_REQUEST",
            "body must contain only expected_revision",
        )
    })?;
    if request.expected_revision < 0 {
        return Err(ApiError::bad_request(
            "INVALID_RELAY_USER_POLICY_RESET_REQUEST",
            "expected_revision must be nonnegative",
        ));
    }

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_write_tx(&mut tx, &state, &actor).await?;
    require_relay_policy_user_tx(&mut tx, &user_id).await?;
    let current = read_user_policy_tx(&mut tx, &user_id).await?;
    let (current_revision, _) =
        read_user_policy_version_tx(&mut tx, &user_id, current.as_ref()).await?;
    if request.expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "relay user policy changed since it was read",
        ));
    }

    if current.is_some() {
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay user policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        sqlx::query("DELETE FROM user_relay_policies WHERE user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        write_user_policy_version_tx(&mut tx, &user_id, revision, &updated_at).await?;
        // Reset may expand or narrow the user's current effective policy as
        // the instance selection changes over time. Revoke all outstanding
        // tickets so none can outlive the policy state they were issued for.
        sqlx::query("DELETE FROM relay_tickets WHERE user_id=? AND consumed_at IS NULL")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &actor.user_id,
            &actor.device_id,
            "admin.relay_policy_updated",
            "relay_user_policy",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }

    let instance = read_policy_tx(&mut tx, &state).await?;
    let user = read_user_policy_tx(&mut tx, &user_id).await?;
    let (revision, updated_at) =
        read_user_policy_version_tx(&mut tx, &user_id, user.as_ref()).await?;
    let effective = effective_policy_for_user_tx(&mut tx, &state, &user_id).await?;
    let response =
        admin_user_policy_json(&user_id, instance, user, effective, revision, updated_at);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn get_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let snapshot = read_policy_tx(&mut tx, &state).await?;
    let response = admin_policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn update_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<RelayPolicyUpdateRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| invalid_policy_request())?;
    let expected_revision = request.expected_revision;
    let candidate = parse_requested_policy(request)?;

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let current = read_policy_tx(&mut tx, &state).await?;
    if expected_revision != current.revision {
        return Err(ApiError::conflict(
            "RELAY_POLICY_CONFLICT",
            "relay policy changed since it was read",
        ));
    }
    validate_policy_limits(&candidate, &state)?;

    let changed = candidate != current.policy;
    let snapshot = if changed {
        let revision = current
            .revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        let cidrs = candidate
            .allow_cidrs
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let cidr_json = serde_json::to_string(&cidrs).map_err(ApiError::internal)?;
        let port_json =
            serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        if current.revision == 0 {
            sqlx::query(
                "INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
                 VALUES(1,?,?,?,?,?)",
            )
            .bind(candidate.enabled as i64)
            .bind(cidr_json)
            .bind(port_json)
            .bind(revision)
            .bind(&updated_at)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        } else {
            sqlx::query(
                "UPDATE instance_relay_policy SET enabled=?,allow_cidrs=?,allow_ports=?,revision=?,updated_at=? \
                 WHERE policy_id=1 AND revision=?",
            )
            .bind(candidate.enabled as i64)
            .bind(cidr_json)
            .bind(port_json)
            .bind(revision)
            .bind(&updated_at)
            .bind(current.revision)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        sqlx::query("DELETE FROM relay_tickets WHERE consumed_at IS NULL")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "admin.relay_policy_updated",
            "relay_policy",
            None,
            chrono::Utc::now().timestamp(),
        )
        .await?;
        RelayPolicySnapshot {
            policy: candidate,
            revision,
            updated_at: Some(updated_at),
        }
    } else {
        current
    };
    let response = admin_policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

fn invalid_policy_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_RELAY_POLICY_REQUEST",
        "body must contain only expected_revision, enabled, allow_cidrs, and allow_ports with bounded canonical values",
    )
}

fn invalid_user_policy_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_RELAY_USER_POLICY_REQUEST",
        "body must contain only expected_revision, expected_instance_policy_revision, enabled, allow_cidrs, and allow_ports with bounded canonical values",
    )
}

fn parse_requested_policy(request: RelayPolicyUpdateRequest) -> Result<RelayPolicy, ApiError> {
    parse_policy_request(
        RelayUserPolicyUpdateRequest {
            expected_revision: request.expected_revision,
            expected_instance_policy_revision: 0,
            enabled: request.enabled,
            allow_cidrs: request.allow_cidrs,
            allow_ports: request.allow_ports,
        },
        invalid_policy_request,
    )
}

fn parse_user_requested_policy(
    request: RelayUserPolicyUpdateRequest,
) -> Result<RelayPolicy, ApiError> {
    if request.expected_instance_policy_revision < 0 {
        return Err(invalid_user_policy_request());
    }
    parse_policy_request(request, invalid_user_policy_request)
}

fn parse_policy_request(
    request: RelayUserPolicyUpdateRequest,
    invalid: fn() -> ApiError,
) -> Result<RelayPolicy, ApiError> {
    if request.expected_revision < 0
        || request.allow_cidrs.len() > MAX_RELAY_POLICY_CIDRS
        || request.allow_ports.len() > MAX_RELAY_POLICY_PORTS
    {
        return Err(invalid());
    }
    let mut cidrs = Vec::with_capacity(request.allow_cidrs.len());
    let mut seen_cidrs = HashSet::with_capacity(request.allow_cidrs.len());
    for value in request.allow_cidrs {
        if value.len() > MAX_RELAY_POLICY_CIDR_LENGTH {
            return Err(invalid());
        }
        let network = value.parse::<IpNet>().map_err(|_| invalid())?;
        if network.to_string() != value || network.trunc() != network || !seen_cidrs.insert(network)
        {
            return Err(invalid());
        }
        cidrs.push(network);
    }
    cidrs.sort_by_key(ToString::to_string);

    let mut ports = request.allow_ports;
    if ports.contains(&0) {
        return Err(invalid());
    }
    let original_len = ports.len();
    ports.sort_unstable();
    ports.dedup();
    if ports.len() != original_len {
        return Err(invalid());
    }
    Ok(RelayPolicy {
        enabled: request.enabled,
        allow_cidrs: cidrs,
        allow_ports: ports,
    })
}

pub(crate) fn validate_user_policy_limits(
    policy: &RelayPolicy,
    instance: &EffectiveRelayPolicy,
) -> Result<(), ApiError> {
    if policy.enabled && !instance.enabled {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_USER_POLICY_UNAVAILABLE",
            "user relay policy cannot be enabled while the instance relay policy is unavailable",
        ));
    }
    if policy.allow_cidrs.iter().any(|requested| {
        !instance
            .allow_cidrs
            .iter()
            .any(|ceiling| is_network_within(*requested, *ceiling))
    }) || policy
        .allow_ports
        .iter()
        .any(|port| !instance.allow_ports.contains(port))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_USER_POLICY_OUTSIDE_LIMITS",
            "user relay policy must be contained by the current instance policy",
        ));
    }
    Ok(())
}

fn validate_policy_limits(policy: &RelayPolicy, state: &AppState) -> Result<(), ApiError> {
    if policy.enabled && !relay_available(state) {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_POLICY_UNAVAILABLE",
            "relay cannot be enabled while deployment limits make it unavailable",
        ));
    }
    if policy.allow_cidrs.iter().any(|requested| {
        !state
            .config
            .relay_allow_cidrs
            .iter()
            .any(|ceiling| is_network_within(*requested, *ceiling))
    }) || policy
        .allow_ports
        .iter()
        .any(|port| !state.config.relay_allow_ports.contains(port))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_POLICY_OUTSIDE_LIMITS",
            "relay policy must be contained by deployment limits",
        ));
    }
    Ok(())
}

#[cfg(test)]
fn parse_target(
    target_host: &str,
    target_port: u16,
    allowlist: &[IpNet],
    allowed_ports: &[u16],
) -> Result<IpAddr, ApiError> {
    let ip = parse_ip_literal(target_host, target_port)?;
    if !is_allowed_target(ip, target_port, allowlist, allowed_ports) {
        return Err(ApiError::forbidden(
            "TARGET_DENIED",
            "target is outside the configured relay policy",
        ));
    }
    Ok(ip)
}

fn invalid_target() -> ApiError {
    ApiError::bad_request("INVALID_TARGET", "target address or port is invalid")
}

#[cfg(test)]
fn parse_ip_literal(target_host: &str, target_port: u16) -> Result<IpAddr, ApiError> {
    if target_port == 0 || target_host.is_empty() || target_host.len() > 45 {
        return Err(invalid_target());
    }
    target_host.parse::<IpAddr>().map_err(|_| invalid_target())
}

pub(crate) fn normalize_dns_hostname(target_host: &str) -> Result<String, ApiError> {
    if target_host.is_empty() || !target_host.is_ascii() || target_host.len() > 254 {
        return Err(invalid_target());
    }
    let without_root_dot = target_host.strip_suffix('.').unwrap_or(target_host);
    if without_root_dot.is_empty() || without_root_dot.len() > 253 {
        return Err(invalid_target());
    }
    let normalized = without_root_dot.to_ascii_lowercase();
    for label in normalized.split('.') {
        if label.is_empty()
            || label.len() > 63
            || label.starts_with('-')
            || label.ends_with('-')
            || !label
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        {
            return Err(invalid_target());
        }
    }

    // Host::parse applies the URL crate's IDNA validation to ASCII A-labels.
    // Numeric shorthand is parsed as an IP address by WHATWG URL rules and is
    // intentionally rejected here to avoid ambiguous legacy IPv4 forms.
    match url::Host::parse(&normalized).map_err(|_| invalid_target())? {
        url::Host::Domain(domain) if domain == normalized => Ok(normalized),
        _ => Err(invalid_target()),
    }
}

type RelayResolveFuture<'a> = Pin<Box<dyn Future<Output = io::Result<Vec<IpAddr>>> + Send + 'a>>;

trait RelayResolver: Send + Sync {
    fn resolve<'a>(
        &'a self,
        hostname: &'a str,
        port: u16,
        permit: OwnedSemaphorePermit,
    ) -> RelayResolveFuture<'a>;
}

struct SystemRelayResolver;

impl RelayResolver for SystemRelayResolver {
    fn resolve<'a>(
        &'a self,
        hostname: &'a str,
        port: u16,
        permit: OwnedSemaphorePermit,
    ) -> RelayResolveFuture<'a> {
        Box::pin(async move {
            // The trailing root dot prevents resolver search-domain expansion.
            let absolute_name = format!("{hostname}.");
            tokio::task::spawn_blocking(move || {
                // getaddrinfo resolves both A and AAAA in one call. Keep the
                // owned permit in the blocking worker: timing out the async
                // caller cannot cancel an already-running getaddrinfo call.
                let _permit = permit;
                let mut answers = Vec::with_capacity(MAX_RELAY_DNS_ANSWERS + 1);
                for address in (absolute_name.as_str(), port).to_socket_addrs()? {
                    answers.push(address.ip());
                    if answers.len() > MAX_RELAY_DNS_ANSWERS {
                        break;
                    }
                }
                Ok(answers)
            })
            .await
            .map_err(|_| io::Error::other("resolver worker failed"))?
        })
    }
}

/// Bounded system lookup shared with the share gateway. Uses the same global
/// DNS concurrency gate and root-dot absolute name as Relay ticket issuance.
pub(crate) async fn lookup_host_all(
    hostname: &str,
    port: u16,
    max_answers: usize,
) -> io::Result<Vec<IpAddr>> {
    let permit = RELAY_DNS_LOOKUP_SLOTS
        .clone()
        .try_acquire_owned()
        .map_err(|_| io::Error::other("resolver busy"))?;
    let mut answers = SystemRelayResolver.resolve(hostname, port, permit).await?;
    if answers.len() > max_answers {
        answers.truncate(max_answers + 1);
    }
    Ok(answers)
}

fn target_resolution_failed() -> ApiError {
    ApiError::new(
        StatusCode::BAD_GATEWAY,
        "TARGET_RESOLUTION_FAILED",
        "relay target name could not be resolved",
    )
}

fn target_denied() -> ApiError {
    ApiError::forbidden(
        "TARGET_DENIED",
        "target is outside the configured relay policy",
    )
}

async fn resolve_dns_target<R: RelayResolver>(
    hostname: &str,
    port: u16,
    policy: &EffectiveRelayPolicy,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<IpAddr, ApiError> {
    if port == 0 {
        return Err(invalid_target());
    }
    if !policy.enabled {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay is disabled by instance policy",
        ));
    }
    if !policy.allow_ports.contains(&port) {
        return Err(target_denied());
    }
    let permit = lookup_slots.clone().try_acquire_owned().map_err(|_| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay capacity is temporarily full",
        )
    })?;
    let answers = timeout(lookup_timeout, resolver.resolve(hostname, port, permit))
        .await
        .map_err(|_| target_resolution_failed())?
        .map_err(|_| target_resolution_failed())?;
    if answers.is_empty() || answers.len() > MAX_RELAY_DNS_ANSWERS {
        return Err(target_resolution_failed());
    }

    // Inspect every answer, retaining the first candidate permitted by the
    // exact CIDR and port policy. The selected address is what the ticket
    // encrypts, so the socket path never performs another DNS lookup.
    let mut selected = None;
    for address in answers {
        let allowed = is_allowed_target(address, port, &policy.allow_cidrs, &policy.allow_ports);
        if allowed && selected.is_none() {
            selected = Some(address);
        }
    }
    selected.ok_or_else(target_denied)
}

async fn effective_policy_for_user(
    state: &AppState,
    user_id: &str,
) -> Result<EffectiveRelayPolicy, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::effective_policy_for_user(state, user_id).await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let policy = effective_policy_for_user_tx(&mut tx, state, user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(policy)
}

async fn resolve_ticket_target<R: RelayResolver>(
    state: &AppState,
    user_id: &str,
    target_host: &str,
    target_port: u16,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<IpAddr, ApiError> {
    if target_port == 0 {
        return Err(invalid_target());
    }
    if let Ok(ip) = target_host.parse::<IpAddr>() {
        if target_host.len() > 45 {
            return Err(invalid_target());
        }
        return Ok(ip);
    }

    let hostname = normalize_dns_hostname(target_host)?;
    let policy = effective_policy_for_user(state, user_id).await?;
    resolve_dns_target(
        &hostname,
        target_port,
        &policy,
        resolver,
        lookup_slots,
        lookup_timeout,
    )
    .await
}

async fn create_ticket_with_resolver<R: RelayResolver>(
    state: &AppState,
    headers: &HeaderMap,
    req: TicketRequest,
    resolver: &R,
    lookup_slots: &Arc<Semaphore>,
    lookup_timeout: Duration,
) -> Result<Json<Value>, ApiError> {
    if !relay_available(state) {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay is disabled by instance policy",
        ));
    }
    let user = current_user(state, headers).await?;
    if req.device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "requested device does not match session",
        ));
    }
    if state.pg_sync_pool.is_some() {
        crate::pg_relay::ensure_active_device(state, &user.user_id, &req.device_id).await?;
    } else {
        crate::ensure_active_device(state, &user.user_id, &req.device_id).await?;
    }
    let ip = resolve_ticket_target(
        state,
        &user.user_id,
        &req.target_host,
        req.target_port,
        resolver,
        lookup_slots,
        lookup_timeout,
    )
    .await?;
    let (ticket, expires) = issue_ticket(
        state,
        &user.user_id,
        &user.device_id,
        &user.session_id,
        &user.access_hash,
        ip,
        req.target_port,
    )
    .await?;
    Ok(Json(
        json!({"ticket":ticket,"expires_at":expires,"connect_path":"/relay/v1/connect"}),
    ))
}

fn is_origin_allowed(expected: &str, headers: &HeaderMap) -> bool {
    let mut values = headers.get_all(ORIGIN).iter();
    matches!(
        (values.next(), values.next()),
        (Some(value), None) if value.to_str().ok() == Some(expected)
    )
}

pub(crate) fn is_valid_ticket(ticket: &str) -> bool {
    if ticket.len() != 43 {
        return false;
    }
    URL_SAFE_NO_PAD
        .decode(ticket)
        .is_ok_and(|bytes| bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == ticket)
}

fn relay_destination_key(state: &AppState) -> Result<Zeroizing<[u8; 32]>, ApiError> {
    let mut key = Zeroizing::new([0_u8; 32]);
    Hkdf::<Sha256>::new(Some(RELAY_DESTINATION_KDF_SALT), &state.auth_rate_key[..])
        .expand(RELAY_DESTINATION_KDF_INFO, &mut *key)
        .map_err(ApiError::internal)?;
    Ok(key)
}

fn relay_destination_aad(ticket_hash: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(RELAY_DESTINATION_AAD_PREFIX.len() + ticket_hash.len());
    aad.extend_from_slice(RELAY_DESTINATION_AAD_PREFIX);
    aad.extend_from_slice(ticket_hash.as_bytes());
    aad
}

pub(crate) fn encrypt_relay_destination(
    state: &AppState,
    ticket_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<String, ApiError> {
    let key = relay_destination_key(state)?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(ApiError::internal)?;
    let mut plaintext = Zeroizing::new(Vec::with_capacity(20));
    plaintext.push(1); // destination payload version
    match ip {
        IpAddr::V4(address) => {
            plaintext.push(4);
            plaintext.extend_from_slice(&address.octets());
        }
        IpAddr::V6(address) => {
            plaintext.push(6);
            plaintext.extend_from_slice(&address.octets());
        }
    }
    plaintext.extend_from_slice(&port.to_be_bytes());

    let mut nonce = [0_u8; 24];
    rand::thread_rng().fill_bytes(&mut nonce);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &plaintext,
                aad: &relay_destination_aad(ticket_hash),
            },
        )
        .map_err(ApiError::internal)?;
    let mut envelope = Vec::with_capacity(nonce.len() + ciphertext.len());
    envelope.extend_from_slice(&nonce);
    envelope.extend_from_slice(&ciphertext);
    Ok(format!(
        "{RELAY_DESTINATION_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(envelope)
    ))
}

pub(crate) fn decrypt_relay_destination(
    state: &AppState,
    ticket_hash: &str,
    envelope: &str,
) -> Result<(IpAddr, u16), ()> {
    let encoded = envelope.strip_prefix(RELAY_DESTINATION_PREFIX).ok_or(())?;
    let packed = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| ())?;
    if !(24 + 8 + 16..=24 + 20 + 16).contains(&packed.len())
        || URL_SAFE_NO_PAD.encode(&packed) != encoded
    {
        return Err(());
    }
    let key = relay_destination_key(state).map_err(|_| ())?;
    let cipher = XChaCha20Poly1305::new_from_slice(&key[..]).map_err(|_| ())?;
    let plaintext = Zeroizing::new(
        cipher
            .decrypt(
                XNonce::from_slice(&packed[..24]),
                Payload {
                    msg: &packed[24..],
                    aad: &relay_destination_aad(ticket_hash),
                },
            )
            .map_err(|_| ())?,
    );
    if plaintext.len() < 2 {
        return Err(());
    }
    let (ip, port_offset) = match (plaintext[0], plaintext[1]) {
        (1, 4) if plaintext.len() == 1 + 1 + 4 + 2 => (
            IpAddr::V4(Ipv4Addr::new(
                plaintext[2],
                plaintext[3],
                plaintext[4],
                plaintext[5],
            )),
            6,
        ),
        (1, 6) if plaintext.len() == 1 + 1 + 16 + 2 => {
            let mut octets = [0_u8; 16];
            octets.copy_from_slice(&plaintext[2..18]);
            (IpAddr::V6(Ipv6Addr::from(octets)), 18)
        }
        _ => return Err(()),
    };
    let port = u16::from_be_bytes([plaintext[port_offset], plaintext[port_offset + 1]]);
    if port == 0 {
        return Err(());
    }
    Ok((ip, port))
}

/// Invalidates pre-encryption relay tickets before serving requests. Old
/// plaintext destinations are erased from their SQLite pages and the WAL is
/// truncated; these short-lived tickets fail closed across the upgrade.
pub(crate) async fn clear_legacy_relay_ticket_destinations(
    db: &sqlx::SqlitePool,
) -> Result<(), ApiError> {
    let mut connection = db.acquire().await.map_err(ApiError::internal)?;
    sqlx::query("PRAGMA secure_delete=ON")
        .execute(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    let now = now_rfc3339();
    sqlx::query(
        "UPDATE relay_tickets SET consumed_at=COALESCE(consumed_at,?),target_ip='',target_port=0 \
         WHERE (target_ip NOT LIKE 'rtd1:%' OR target_port!=0) \
           AND (consumed_at IS NULL OR target_ip!='' OR target_port!=0)",
    )
    .bind(now)
    .execute(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    // Checkpoint even when the latest row values were already blank: WAL may
    // still contain an earlier plaintext frame from a ticket consumed by the
    // previous server version.
    let checkpoint = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_one(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    if checkpoint.get::<i64, _>("busy") != 0 {
        return Err(ApiError::internal(
            "legacy relay ticket cleanup WAL checkpoint was busy",
        ));
    }
    Ok(())
}

pub(crate) fn relay_rate_limit_error(oldest: Option<i64>, now: i64) -> ApiError {
    let retry_after = oldest
        .map(|created| created + TICKET_RATE_WINDOW_SECONDS - now)
        .unwrap_or(1)
        .max(1) as u64;
    let mut error = ApiError::new(
        StatusCode::TOO_MANY_REQUESTS,
        "RELAY_RATE_LIMITED",
        "relay ticket issuance rate exceeded",
    );
    error.retry_after_secs = Some(retry_after);
    error
}

pub async fn create_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TicketRequest>,
) -> Result<Json<Value>, ApiError> {
    create_ticket_with_resolver(
        &state,
        &headers,
        req,
        &SystemRelayResolver,
        &RELAY_DNS_LOOKUP_SLOTS,
        RELAY_DNS_LOOKUP_TIMEOUT,
    )
    .await
}

async fn issue_ticket(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    session_id: &str,
    access_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<(String, String), ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::issue_ticket(
            state,
            user_id,
            device_id,
            session_id,
            access_hash,
            ip,
            port,
        )
        .await;
    }
    let now = Utc::now();
    let now_epoch = now.timestamp();
    let cutoff = now_epoch.saturating_sub(TICKET_RATE_WINDOW_SECONDS);
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

    // Obtain SQLite writer serialization and bind the ticket to the exact
    // active session. This orders issuance against logout and account deletion.
    let session = sqlx::query("UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL RETURNING access_expires_at,refresh_expires_at")
        .bind(session_id)
        .bind(user_id)
        .bind(device_id)
        .bind(access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
    let session_access_expires_at: String = session.get("access_expires_at");
    let session_expiry = DateTime::parse_from_rfc3339(&session_access_expires_at)
        .map_err(ApiError::internal)?
        .with_timezone(&Utc);
    let session_refresh_expires_at: String = session.get("refresh_expires_at");
    let refresh_expiry = DateTime::parse_from_rfc3339(&session_refresh_expires_at)
        .map_err(ApiError::internal)?
        .with_timezone(&Utc);
    if session_expiry <= now || refresh_expiry <= now {
        return Err(ApiError::unauthorized());
    }
    crate::require_active_account_tx(&mut tx, user_id).await?;
    let active_device: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=? AND user_id=? AND status='active')",
    )
    .bind(device_id)
    .bind(user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if !active_device {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    let policy = effective_policy_for_user_tx(&mut tx, state, user_id).await?;
    if !policy.enabled {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay is disabled by instance policy",
        ));
    }
    if !is_allowed_target(ip, port, &policy.allow_cidrs, &policy.allow_ports) {
        return Err(ApiError::forbidden(
            "TARGET_DENIED",
            "target is outside the configured relay policy",
        ));
    }
    let authorization_revision =
        crate::relay_groups::user_authorization_revision_tx(&mut tx, user_id).await?;

    prune_tickets_tx(&mut tx, cutoff).await?;
    let (issued, oldest): (i64, Option<i64>) = sqlx::query_as(
        "SELECT COUNT(*),MIN(created_at) FROM relay_tickets WHERE user_id=? AND created_at>?",
    )
    .bind(user_id)
    .bind(cutoff)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if issued >= MAX_TICKETS_PER_USER_PER_WINDOW {
        // Persist the prune even though issuance is rejected. Otherwise a
        // rate-limited request can roll cleanup back and leave the global
        // ticket cap stuck until the next scheduled maintenance run.
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(relay_rate_limit_error(oldest, now_epoch));
    }
    let retained: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_tickets")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if retained >= MAX_RETAINED_TICKETS {
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay ticket capacity is temporarily full",
        ));
    }

    let requested_expiry = now + ChronoDuration::seconds(TICKET_TTL_SECONDS);
    let expires_at = requested_expiry.min(session_expiry).min(refresh_expiry);
    let expires = expires_at.to_rfc3339();
    let mut raw = [0; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = URL_SAFE_NO_PAD.encode(raw);
    let ticket_hash = sha256_hex(ticket.as_bytes());
    let encrypted_destination = encrypt_relay_destination(state, &ticket_hash, ip, port)?;
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at,authorization_revision) VALUES(?,?,?,?,?,?,?,?,?,?)")
        .bind(ticket_hash)
        .bind(user_id)
        .bind(device_id)
        .bind(encrypted_destination)
        .bind(0_i64)
        .bind(&expires)
        .bind(session_id)
        .bind(&session_access_expires_at)
        .bind(now_epoch)
        .bind(authorization_revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        state,
        user_id,
        Some(device_id),
        "relay.ticket_issued",
        "relay",
        None,
        crate::audit::AuditSource::Api,
        now_epoch,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((ticket, expires))
}

pub(crate) async fn prune_tickets_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    cutoff: i64,
) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM relay_tickets WHERE created_at<=?")
        .bind(cutoff)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    if !relay_available(&state) {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay is disabled by instance policy",
        ));
    }
    let Some(expected) = state.config.public_origin.as_deref() else {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay requires a configured browser origin",
        ));
    };
    if !is_origin_allowed(expected, &headers) {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(64 * 1024)
        .max_frame_size(64 * 1024)
        .on_upgrade(move |socket| relay_socket(socket, state, false)))
}

pub async fn connect_desktop(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    if !relay_available(&state) || state.config.guacd_address.is_none() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "DESKTOP_DISABLED",
            "remote desktop gateway is not configured",
        ));
    }
    // Browsers always send Origin. Native clients authenticate with the same
    // one-use first-frame ticket and need not impersonate a browser origin.
    if headers.contains_key(ORIGIN)
        && !is_origin_allowed(
            state.config.public_origin.as_deref().unwrap_or(""),
            &headers,
        )
    {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(96 * 1024)
        .max_frame_size(96 * 1024)
        .on_upgrade(move |socket| relay_socket(socket, state, true)))
}

async fn consume_ticket(state: &AppState, token: &str) -> Result<Option<RelayTarget>, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::consume_ticket(state, token).await;
    }
    if !is_valid_ticket(token) {
        return Ok(None);
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let ticket_hash = sha256_hex(token.as_bytes());
    let row = sqlx::query("UPDATE relay_tickets SET consumed_at=? WHERE ticket_hash=? AND consumed_at IS NULL AND expires_at>? AND session_id IS NOT NULL AND session_access_expires_at IS NOT NULL AND EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=relay_tickets.session_id AND s.user_id=relay_tickets.user_id AND s.device_id=relay_tickets.device_id AND s.access_expires_at=relay_tickets.session_access_expires_at AND s.access_expires_at>? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active') RETURNING user_id,device_id,session_id,target_ip,target_port,authorization_revision")
        .bind(&now_text)
        .bind(&ticket_hash)
        .bind(&now_text)
        .bind(&now_text)
        .bind(&now_text)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let encrypted_destination: String = row.get("target_ip");
    let target_port: i64 = row.get("target_port");
    let destination = if target_port == 0 {
        decrypt_relay_destination(state, &ticket_hash, &encrypted_destination).ok()
    } else {
        None
    };
    let user_id: String = row.get("user_id");
    let policy = effective_policy_for_user_tx(&mut tx, state, &user_id).await?;
    let current_authorization_revision =
        crate::relay_groups::user_authorization_revision_tx(&mut tx, &user_id).await?;
    let ticket_authorization_revision: i64 = row.get("authorization_revision");
    // Clear the bound destination as soon as the one-use ticket is consumed.
    sqlx::query("UPDATE relay_tickets SET target_ip='',target_port=0 WHERE ticket_hash=?")
        .bind(&ticket_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    let Some((ip, port)) = destination.filter(|(ip, port)| {
        ticket_authorization_revision == current_authorization_revision
            && effective_target_allowed(&policy, *ip, *port)
    }) else {
        return Ok(None);
    };
    Ok(Some(RelayTarget {
        user_id,
        device_id: row.get("device_id"),
        session_id: row.get("session_id"),
        ip,
        port,
        authorization_revision: ticket_authorization_revision,
        connection_id: None,
    }))
}

async fn relay_session_active(state: &AppState, target: &RelayTarget) -> bool {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::relay_session_active(state, target).await;
    }
    let now_text = now_rfc3339();
    let result = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .bind(now_text)
        .fetch_one(&state.db)
        .await;
    match result {
        Ok(active) => active,
        Err(_) => {
            tracing::warn!(event = "relay_session_state_check_failed");
            false
        }
    }
}

async fn relay_connection_active(state: &AppState, target: &RelayTarget) -> bool {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::relay_connection_active(state, target).await;
    }
    if !relay_session_active(state, target).await {
        return false;
    }
    let result = match state.db.begin().await {
        Ok(mut tx) => match effective_policy_for_user_tx(&mut tx, state, &target.user_id).await {
            Ok(policy) => {
                match crate::relay_groups::user_authorization_revision_tx(&mut tx, &target.user_id)
                    .await
                {
                    Ok(revision) => match tx.commit().await {
                        Ok(()) => Some((policy, revision)),
                        Err(_) => None,
                    },
                    Err(_) => None,
                }
            }
            Err(_) => None,
        },
        Err(_) => None,
    };
    match result {
        Some((policy, revision)) => {
            revision == target.authorization_revision
                && effective_target_allowed(&policy, target.ip, target.port)
        }
        None => {
            tracing::warn!(event = "relay_policy_state_check_failed");
            false
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RelayIoAbort {
    Deadline,
    SessionInactive,
    IoTimeout,
}

/// Keeps the session poll and absolute connection deadline live while a
/// backpressured socket write is pending. The pending write is retained across
/// active session checks and is dropped only when the connection must close.
async fn relay_io_with_guards<F, T>(
    future: F,
    state: &AppState,
    target: &RelayTarget,
    deadline_at: Instant,
    session_check: &mut Interval,
) -> Result<T, RelayIoAbort>
where
    F: Future<Output = T>,
{
    tokio::pin!(future);
    let deadline = tokio::time::sleep_until(deadline_at);
    tokio::pin!(deadline);
    let io_timeout = tokio::time::sleep(RELAY_IO_TIMEOUT);
    tokio::pin!(io_timeout);
    loop {
        tokio::select! {
            _ = &mut deadline => return Err(RelayIoAbort::Deadline),
            _ = &mut io_timeout => return Err(RelayIoAbort::IoTimeout),
            _ = session_check.tick() => {
                let active = tokio::time::timeout(
                    RELAY_SESSION_CHECK_TIMEOUT,
                    relay_connection_active(state, target),
                )
                .await
                .unwrap_or_else(|_| {
                    tracing::warn!(event = "relay_session_state_check_timed_out");
                    false
                });
                if !active {
                    tracing::warn!(event = "relay_connection_closed", reason = "session_inactive");
                    return Err(RelayIoAbort::SessionInactive);
                }
            }
            result = &mut future => return Ok(result),
        }
    }
}

/// Records a successful TCP connection before any SSH bytes are forwarded.
/// The writer lock orders this check with logout, device revocation and purge.
/// Access-token refresh keeps the session ID; it must not invalidate an SSH
/// transport whose short-lived ticket was already consumed. Once connected,
/// the refresh-token expiry is the session lifetime boundary: the access token
/// may briefly expire before the client receives its refresh hint.
async fn record_connected(
    state: &AppState,
    target: &RelayTarget,
    connection_id: uuid::Uuid,
) -> Result<bool, ApiError> {
    if state.pg_sync_pool.is_some() {
        return crate::pg_relay::record_connected(state, target, connection_id).await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let locked = sqlx::query("UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND revoked_at IS NULL")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() != 1 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let now = Utc::now();
    let now_text = now.to_rfc3339();
    let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.refresh_expires_at>? AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .bind(now_text)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if !active {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let authorization_revision =
        crate::relay_groups::user_authorization_revision_tx(&mut tx, &target.user_id).await?;
    if authorization_revision != target.authorization_revision {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let policy = effective_policy_for_user_tx(&mut tx, state, &target.user_id).await?;
    if !effective_target_allowed(&policy, target.ip, target.port) {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        state,
        &target.user_id,
        Some(&target.device_id),
        "relay.connected",
        "relay",
        None,
        crate::audit::AuditSource::Api,
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(true)
}

fn acquire_connection(state: Arc<AppState>, user_id: &str) -> Option<RelayConnectionGuard> {
    let global_permit = state
        .relay_connection_slots
        .clone()
        .try_acquire_owned()
        .ok()?;
    let mut connections = state.relay_connections.lock().ok()?;
    let count = connections.get(user_id).copied().unwrap_or_default();
    if count >= state.config.relay_max_connections_per_user {
        return None;
    }
    *connections.entry(user_id.to_owned()).or_default() += 1;
    drop(connections);
    Some(RelayConnectionGuard {
        state,
        user_id: user_id.to_owned(),
        _global_permit: global_permit,
    })
}

async fn send_close(socket: &mut WebSocket) {
    let _ = tokio::time::timeout(RELAY_SHUTDOWN_TIMEOUT, socket.send(Message::Close(None))).await;
}

async fn relay_socket(mut socket: WebSocket, state: Arc<AppState>, desktop: bool) {
    let token = match tokio::time::timeout(Duration::from_secs(10), socket.recv()).await {
        Ok(Some(Ok(Message::Text(value)))) => value.to_string(),
        Ok(Some(Ok(Message::Binary(value)))) => {
            String::from_utf8(value.to_vec()).unwrap_or_default()
        }
        _ => {
            send_close(&mut socket).await;
            return;
        }
    };
    if !is_valid_ticket(&token) {
        send_close(&mut socket).await;
        return;
    }
    let target = match consume_ticket(&state, &token).await {
        Ok(Some(target)) => target,
        _ => {
            send_close(&mut socket).await;
            return;
        }
    };
    let session_active = tokio::time::timeout(
        RELAY_SESSION_CHECK_TIMEOUT,
        relay_connection_active(&state, &target),
    )
    .await
    .unwrap_or_else(|_| {
        tracing::warn!(event = "relay_session_state_check_timed_out");
        false
    });
    if !session_active {
        tracing::warn!(
            event = "relay_connection_closed",
            reason = "session_inactive"
        );
        send_close(&mut socket).await;
        return;
    }
    let Some(guard) = acquire_connection(state.clone(), &target.user_id) else {
        send_close(&mut socket).await;
        return;
    };
    let destination = if desktop {
        let Some(address) = state.config.guacd_address.as_ref() else {
            return;
        };
        address.clone()
    } else {
        SocketAddr::new(target.ip, target.port).to_string()
    };
    let mut tcp =
        match tokio::time::timeout(RELAY_CONNECT_TIMEOUT, TcpStream::connect(destination)).await {
            Ok(Ok(stream)) => stream,
            Ok(Err(_)) | Err(_) => {
                send_close(&mut socket).await;
                drop(guard);
                return;
            }
        };
    if desktop {
        let setup = async {
            let Some(Ok(Message::Text(text))) = socket.recv().await else {
                return Err(());
            };
            let hello = serde_json::from_str::<crate::desktop::DesktopHello>(&text).map_err(|_| ());
            // Credentials are transient; never logged or persisted in tickets.
            drop(text);
            crate::desktop::handshake(&mut tcp, hello?, target.ip, target.port).await
        };
        if !matches!(timeout(RELAY_CONNECT_TIMEOUT, setup).await, Ok(Ok(()))) {
            send_close(&mut socket).await;
            return;
        }
    }
    let mut target = target;
    let connection_id = uuid::Uuid::new_v4();
    match record_connected(&state, &target, connection_id).await {
        Ok(true) => target.connection_id = Some(connection_id),
        _ => {
            send_close(&mut socket).await;
            drop(tcp);
            drop(guard);
            return;
        }
    }

    let (mut ws_tx, mut ws_rx) = socket.split();
    let (mut tcp_rx, mut tcp_tx) = tokio::io::split(tcp);
    let mut buf = vec![0_u8; 16 * 1024];
    let mut transferred = 0_u64;
    let deadline_at = Instant::now() + MAX_RELAY_DURATION;
    let mut session_check = tokio::time::interval(Duration::from_secs(RELAY_POLL_SESSION_SECONDS));
    session_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    session_check.tick().await;
    loop {
        tokio::select! {
            _ = tokio::time::sleep_until(deadline_at) => break,
            _ = session_check.tick() => {
                let active = tokio::time::timeout(
                    RELAY_SESSION_CHECK_TIMEOUT,
                    relay_connection_active(&state, &target),
                )
                .await
                .unwrap_or_else(|_| {
                    tracing::warn!(event = "relay_session_state_check_timed_out");
                    false
                });
                if !active {
                    tracing::warn!(event = "relay_connection_closed", reason = "session_inactive");
                    break;
                }
            },
            inbound = ws_rx.next() => match inbound {
                Some(Ok(Message::Binary(bytes))) => {
                    if desktop && !crate::desktop::valid_input(&bytes) { break; }
                    transferred = transferred.saturating_add(bytes.len() as u64);
                    if transferred > MAX_RELAY_BYTES {
                        break;
                    }
                    if !matches!(
                        relay_io_with_guards(
                            tcp_tx.write_all(&bytes),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Some(Ok(Message::Ping(payload))) => {
                    if !matches!(
                        relay_io_with_guards(
                            ws_tx.send(Message::Pong(payload)),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                Some(Ok(_)) => break,
            },
            read = tcp_rx.read(&mut buf) => match read {
                Ok(0) => {
                    let _ = tokio::time::timeout(
                        RELAY_SHUTDOWN_TIMEOUT,
                        ws_tx.send(Message::Close(None)),
                    )
                    .await;
                    break;
                }
                Ok(count) => {
                    transferred = transferred.saturating_add(count as u64);
                    if transferred > MAX_RELAY_BYTES {
                        break;
                    }
                    if !matches!(
                        relay_io_with_guards(
                            ws_tx.send(Message::Binary(axum::body::Bytes::copy_from_slice(&buf[..count]))),
                            &state,
                            &target,
                            deadline_at,
                            &mut session_check,
                        )
                        .await,
                        Ok(Ok(()))
                    ) {
                        break;
                    }
                }
                Err(_) => break,
            },
        }
    }
    let _ = tokio::time::timeout(RELAY_SHUTDOWN_TIMEOUT, tcp_tx.shutdown()).await;
    if state.pg_sync_pool.is_some()
        && let Some(connection_id) = target.connection_id
    {
        crate::pg_relay::release_connection_lease(&state, connection_id).await;
    }
    drop(guard);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        AuthRateLimits, Config, auth::AuthUser, open_state, secure_file::create_private_data_dir,
    };
    use axum::http::HeaderValue;
    use chrono::Duration as ChronoDuration;
    use std::{
        path::PathBuf,
        sync::{
            Mutex as StdMutex,
            atomic::{AtomicUsize, Ordering},
        },
    };
    use uuid::Uuid;

    #[derive(Clone)]
    enum FakeResolveResult {
        Answers(Vec<IpAddr>),
        Error,
        Pending,
    }

    struct FakeRelayResolver {
        expected_hostname: String,
        result: StdMutex<FakeResolveResult>,
        calls: AtomicUsize,
    }

    impl FakeRelayResolver {
        fn new(expected_hostname: &str, result: FakeResolveResult) -> Self {
            Self {
                expected_hostname: expected_hostname.to_owned(),
                result: StdMutex::new(result),
                calls: AtomicUsize::new(0),
            }
        }

        fn set_result(&self, result: FakeResolveResult) {
            *self.result.lock().unwrap() = result;
        }

        fn calls(&self) -> usize {
            self.calls.load(Ordering::SeqCst)
        }
    }

    impl RelayResolver for FakeRelayResolver {
        fn resolve<'a>(
            &'a self,
            hostname: &'a str,
            _port: u16,
            permit: OwnedSemaphorePermit,
        ) -> RelayResolveFuture<'a> {
            assert_eq!(hostname, self.expected_hostname);
            self.calls.fetch_add(1, Ordering::SeqCst);
            let result = self.result.lock().unwrap().clone();
            Box::pin(async move {
                let _permit = permit;
                match result {
                    FakeResolveResult::Answers(addresses) => Ok(addresses),
                    FakeResolveResult::Error => Err(io::Error::other("synthetic resolver error")),
                    FakeResolveResult::Pending => {
                        std::future::pending::<io::Result<Vec<IpAddr>>>().await
                    }
                }
            })
        }
    }

    struct BlockingFakeRelayResolver {
        started: Arc<tokio::sync::Notify>,
        finished: Arc<tokio::sync::Notify>,
        release: StdMutex<Option<std::sync::mpsc::Sender<()>>>,
    }

    impl BlockingFakeRelayResolver {
        fn new() -> Self {
            Self {
                started: Arc::new(tokio::sync::Notify::new()),
                finished: Arc::new(tokio::sync::Notify::new()),
                release: StdMutex::new(None),
            }
        }

        fn release(&self) {
            self.release
                .lock()
                .unwrap()
                .take()
                .unwrap()
                .send(())
                .unwrap();
        }
    }

    impl RelayResolver for BlockingFakeRelayResolver {
        fn resolve<'a>(
            &'a self,
            _hostname: &'a str,
            _port: u16,
            permit: OwnedSemaphorePermit,
        ) -> RelayResolveFuture<'a> {
            let (release, wait_for_release) = std::sync::mpsc::channel();
            *self.release.lock().unwrap() = Some(release);
            let started = self.started.clone();
            let finished = self.finished.clone();
            let worker = tokio::task::spawn_blocking(move || {
                let _permit = permit;
                started.notify_one();
                wait_for_release
                    .recv()
                    .map_err(|_| io::Error::other("test resolver release channel closed"))?;
                finished.notify_one();
                Ok(vec!["10.2.3.4".parse().unwrap()])
            });
            Box::pin(async move {
                worker
                    .await
                    .map_err(|_| io::Error::other("synthetic resolver worker failed"))?
            })
        }
    }

    fn test_dns_policy() -> EffectiveRelayPolicy {
        EffectiveRelayPolicy {
            enabled: true,
            allow_cidrs: vec!["10.0.0.0/8".parse().unwrap()],
            allow_ports: vec![22],
        }
    }

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
            relay_enabled: true,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: vec!["10.0.0.0/8".parse().unwrap()],
            relay_allow_ports: vec![22],
            relay_max_connections_per_user: 1,
            public_origin: Some("https://relay.example.test".to_owned()),
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
        let data_dir = std::env::temp_dir().join(format!("atermius-relay-{}", Uuid::new_v4()));
        create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        open_state(&database, test_config(data_dir)).await.unwrap()
    }

    async fn admin_test_state() -> AppState {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-relay-admin-{}", Uuid::new_v4()));
        create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let mut config = test_config(data_dir);
        config.admin_usernames = vec!["relay-admin@example.test".to_owned()];
        open_state(&database, config).await.unwrap()
    }

    async fn seed_admin_session(state: &AppState) -> (AuthUser, String) {
        let (user, access) = seed_session(state).await;
        sqlx::query("UPDATE users SET username='relay-admin@example.test' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        (user, access)
    }

    async fn close_state(state: &AppState) {
        let path = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(path).await.unwrap();
    }

    async fn seed_session(state: &AppState) -> (AuthUser, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("relay-access-{}", Uuid::new_v4());
        let now = Utc::now();
        let expires = (now + ChronoDuration::minutes(10)).to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("relay-{}@example.test", Uuid::new_v4()))
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'relay-test','sign','enc',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'relay-family',?,?,?,? ,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(sha256_hex(access.as_bytes()))
            .bind(format!("relay-refresh-{}", Uuid::new_v4()))
            .bind(&expires)
            .bind((now + ChronoDuration::days(30)).to_rfc3339())
            .bind(now.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        (
            AuthUser {
                user_id,
                device_id,
                session_id,
                access_hash: sha256_hex(access.as_bytes()),
                declares_record_schema2: false,
                declares_sync_redaction_v1: true,
            },
            access,
        )
    }

    fn auth_headers(access: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            axum::http::header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access}")).unwrap(),
        );
        headers
    }

    #[test]
    fn ip_literal_target_policy_rejects_special_addresses() {
        let allow_all_v4: Vec<IpNet> = vec!["0.0.0.0/0".parse().unwrap()];
        for value in [
            "127.0.0.1",
            "169.254.169.254",
            "100.100.100.200",
            "169.254.2.1",
            "255.255.255.255",
            "224.0.0.1",
        ] {
            let ip: IpAddr = value.parse().unwrap();
            assert!(is_forbidden_ip(ip), "{value} must be denied");
        }
        assert!(is_forbidden_ip("::1".parse().unwrap()));
        assert!(is_forbidden_ip("::ffff:127.0.0.1".parse().unwrap()));
        assert!(is_forbidden_ip("::ffff:100.100.100.200".parse().unwrap()));
        assert!(is_forbidden_ip(EC2_IPV6_METADATA.into()));
        assert_eq!(
            parse_target("10.4.5.6", 22, &["10.0.0.0/8".parse().unwrap()], &[22]).unwrap(),
            "10.4.5.6".parse::<IpAddr>().unwrap()
        );
        assert_eq!(
            parse_target(
                "100.100.100.200",
                80,
                &["100.100.100.200/32".parse().unwrap()],
                &[80]
            )
            .unwrap_err()
            .body
            .code,
            "TARGET_DENIED",
            "Alibaba metadata must be denied even inside an explicit CIDR"
        );
        assert_eq!(
            parse_target("10.4.5.6", 443, &["10.0.0.0/8".parse().unwrap()], &[22])
                .unwrap_err()
                .body
                .code,
            "TARGET_DENIED",
            "ports outside the explicit allowlist must be denied"
        );
        assert!(!is_allowed_ip("10.4.5.6".parse().unwrap(), &[]));
        assert_eq!(
            parse_target("10.4.5.6", 0, &["10.0.0.0/8".parse().unwrap()], &[22])
                .unwrap_err()
                .body
                .code,
            "INVALID_TARGET"
        );
        assert_eq!(
            parse_target(&"a".repeat(46), 22, &allow_all_v4, &[22])
                .unwrap_err()
                .body
                .code,
            "INVALID_TARGET"
        );
    }

    #[test]
    fn dns_hostnames_require_ascii_idna_alabels_and_normalize_root_and_case() {
        assert_eq!(
            normalize_dns_hostname("SSH.XN--BCHER-KVA.Example.").unwrap(),
            "ssh.xn--bcher-kva.example"
        );
        assert_eq!(
            normalize_dns_hostname("Host.Example.Test").unwrap(),
            "host.example.test"
        );
        for invalid in [
            "",
            "bücher.example",
            "bad..example",
            "-bad.example",
            "bad-.example",
            "bad_.example",
            "xn--.example",
            "127.1",
            "999.1.1.1",
            "a..",
        ] {
            assert!(
                normalize_dns_hostname(invalid).is_err(),
                "{invalid:?} must be rejected"
            );
        }
        let long_label = format!("{}.example", "a".repeat(64));
        assert!(normalize_dns_hostname(&long_label).is_err());
        let max_name = format!(
            "{}.{}.{}.{}",
            "a".repeat(63),
            "b".repeat(63),
            "c".repeat(63),
            "d".repeat(61)
        );
        assert_eq!(max_name.len(), 253);
        assert_eq!(normalize_dns_hostname(&max_name).unwrap(), max_name);
        let max_absolute_name = format!("{max_name}.");
        assert_eq!(max_absolute_name.len(), 254);
        assert_eq!(
            normalize_dns_hostname(&max_absolute_name).unwrap(),
            max_name
        );
        assert!(normalize_dns_hostname(&format!("{max_name}x")).is_err());
        let long_name = (0..4).map(|_| "a".repeat(63)).collect::<Vec<_>>().join(".");
        assert!(long_name.len() > 253);
        assert!(normalize_dns_hostname(&long_name).is_err());
    }

    #[tokio::test]
    async fn relay_dns_checks_policy_before_lookup_and_selects_first_allowed_answer() {
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "192.0.2.17".parse().unwrap(),
                "100.100.100.200".parse().unwrap(),
                "2001:db8::1".parse().unwrap(),
                "10.2.3.4".parse().unwrap(),
                "10.2.3.5".parse().unwrap(),
            ]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let selected = resolve_dns_target(
            "ssh.example.test",
            22,
            &test_dns_policy(),
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        assert_eq!(selected, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(resolver.calls(), 1);

        let denied_resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.4".parse().unwrap()]),
        );
        let denied = resolve_dns_target(
            "ssh.example.test",
            23,
            &test_dns_policy(),
            &denied_resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(denied.status, StatusCode::FORBIDDEN);
        assert_eq!(denied.body.code, "TARGET_DENIED");
        assert_eq!(denied_resolver.calls(), 0);

        let no_allowed_answer = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "192.0.2.17".parse().unwrap(),
                "169.254.169.254".parse().unwrap(),
                "100.100.100.200".parse().unwrap(),
            ]),
        );
        let denied = resolve_dns_target(
            "ssh.example.test",
            22,
            &test_dns_policy(),
            &no_allowed_answer,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(denied.status, StatusCode::FORBIDDEN);
        assert_eq!(denied.body.code, "TARGET_DENIED");
    }

    #[tokio::test]
    async fn relay_dns_failures_timeouts_and_answer_overflow_are_bounded() {
        let slots = Arc::new(Semaphore::new(1));
        let cases = [
            FakeResolveResult::Answers(Vec::new()),
            FakeResolveResult::Error,
            FakeResolveResult::Pending,
            FakeResolveResult::Answers(
                (1..=MAX_RELAY_DNS_ANSWERS + 1)
                    .map(|last| IpAddr::V4(Ipv4Addr::new(10, 2, 3, last as u8)))
                    .collect(),
            ),
        ];
        for (index, result) in cases.into_iter().enumerate() {
            let resolver = FakeRelayResolver::new("ssh.example.test", result);
            let error = resolve_dns_target(
                "ssh.example.test",
                22,
                &test_dns_policy(),
                &resolver,
                &slots,
                if index == 2 {
                    Duration::from_millis(5)
                } else {
                    Duration::from_secs(1)
                },
            )
            .await
            .unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_GATEWAY);
            assert_eq!(error.body.code, "TARGET_RESOLUTION_FAILED");
            assert!(!error.body.message.contains("ssh.example.test"));
            assert_eq!(resolver.calls(), 1);
        }
    }

    #[tokio::test]
    async fn relay_dns_concurrency_gate_rejects_without_starting_resolution() {
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.4".parse().unwrap()]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let _held = slots.clone().try_acquire_owned().unwrap();
        let error = resolve_dns_target(
            "ssh.example.test",
            22,
            &test_dns_policy(),
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.body.code, "RELAY_BUSY");
        assert_eq!(resolver.calls(), 0);
    }

    #[tokio::test]
    async fn timed_out_blocking_dns_keeps_its_concurrency_slot_until_worker_finishes() {
        let slots = Arc::new(Semaphore::new(1));
        let resolver = BlockingFakeRelayResolver::new();
        let error = resolve_dns_target(
            "ssh.example.test",
            22,
            &test_dns_policy(),
            &resolver,
            &slots,
            Duration::from_millis(1),
        )
        .await
        .unwrap_err();
        assert_eq!(error.body.code, "TARGET_RESOLUTION_FAILED");
        resolver.started.notified().await;
        assert_eq!(slots.available_permits(), 0);

        let second = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec!["10.2.3.8".parse().unwrap()]),
        );
        let busy = resolve_dns_target(
            "ssh.example.test",
            22,
            &test_dns_policy(),
            &second,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap_err();
        assert_eq!(busy.body.code, "RELAY_BUSY");
        assert_eq!(second.calls(), 0);

        let finished = resolver.finished.notified();
        resolver.release();
        finished.await;
        assert_eq!(slots.available_permits(), 1);
    }

    #[tokio::test]
    async fn consumed_dns_ticket_uses_the_original_selected_ip_without_resolving_again() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let resolver = FakeRelayResolver::new(
            "ssh.example.test",
            FakeResolveResult::Answers(vec![
                "192.0.2.17".parse().unwrap(),
                "10.2.3.4".parse().unwrap(),
            ]),
        );
        let slots = Arc::new(Semaphore::new(1));
        let Json(body) = create_ticket_with_resolver(
            &state,
            &auth_headers(&access),
            TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "SSH.Example.Test.".to_owned(),
                target_port: 22,
            },
            &resolver,
            &slots,
            Duration::from_secs(1),
        )
        .await
        .unwrap();
        let ticket = body["ticket"].as_str().unwrap();
        assert_eq!(resolver.calls(), 1);

        let (stored_destination, stored_port): (String, i64) =
            sqlx::query_as("SELECT target_ip,target_port FROM relay_tickets WHERE ticket_hash=?")
                .bind(sha256_hex(ticket.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(!stored_destination.contains("ssh.example.test"));
        assert_eq!(stored_port, 0);

        resolver.set_result(FakeResolveResult::Answers(vec![
            "10.9.8.7".parse().unwrap(),
        ]));
        let target = consume_ticket(&state, ticket).await.unwrap().unwrap();
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);
        assert_eq!(resolver.calls(), 1);
        close_state(&state).await;
    }

    #[test]
    fn relay_origin_requires_one_exact_header_and_ticket_is_canonical() {
        let expected = "https://relay.example.test";
        let mut headers = HeaderMap::new();
        headers.insert(ORIGIN, HeaderValue::from_static(expected));
        assert!(is_origin_allowed(expected, &headers));
        headers.append(ORIGIN, HeaderValue::from_static(expected));
        assert!(!is_origin_allowed(expected, &headers));
        headers.remove(ORIGIN);
        assert!(!is_origin_allowed(expected, &headers));

        let token = URL_SAFE_NO_PAD.encode([7_u8; 32]);
        assert!(is_valid_ticket(&token));
        assert!(!is_valid_ticket(&format!("{token}=")));
        assert!(!is_valid_ticket("not-a-ticket"));
    }

    #[tokio::test]
    async fn ticket_issue_is_session_bound_rate_limited_and_audited_without_target_data() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let request = || TicketRequest {
            device_id: user.device_id.clone(),
            target_host: "10.2.3.4".to_owned(),
            target_port: 22,
        };
        let Json(body) =
            create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
                .await
                .unwrap();
        let token = body["ticket"].as_str().unwrap();
        assert_eq!(body["connect_path"], "/relay/v1/connect");
        let ticket = sqlx::query("SELECT ticket_hash,user_id,device_id,session_id,target_ip,target_port,created_at FROM relay_tickets")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(
            ticket.get::<String, _>("ticket_hash"),
            sha256_hex(token.as_bytes())
        );
        assert_eq!(ticket.get::<String, _>("session_id"), user.session_id);
        let stored_destination: String = ticket.get("target_ip");
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(!stored_destination.contains("10.2.3.4"));
        assert_eq!(ticket.get::<i64, _>("target_port"), 0);

        let scope = crate::audit::account_scope_id(&state.cursor_key, &user.user_id).unwrap();
        let audit = sqlx::query("SELECT action,resource_type,resource_id,actor_user_id,actor_device_id FROM audit_events WHERE scope_type='account' AND scope_id=?")
            .bind(scope)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(audit.get::<String, _>("action"), "relay.ticket_issued");
        assert_eq!(audit.get::<String, _>("resource_type"), "relay");
        assert_eq!(audit.get::<Option<String>, _>("resource_id"), None);
        assert_eq!(
            audit.get::<Option<String>, _>("actor_user_id").as_deref(),
            Some(user.user_id.as_str())
        );
        assert_eq!(
            audit.get::<Option<String>, _>("actor_device_id").as_deref(),
            Some(user.device_id.as_str())
        );

        let target = consume_ticket(&state, token).await.unwrap().unwrap();
        assert_eq!(target.user_id, user.user_id);
        assert_eq!(target.session_id, user.session_id);
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);
        assert!(consume_ticket(&state, token).await.unwrap().is_none());
        let cleared: (String, i64) =
            sqlx::query_as("SELECT target_ip,target_port FROM relay_tickets")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(cleared, (String::new(), 0));

        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,created_at) VALUES('stale-throttle-row',?,?, '10.2.3.4',22,?,?)")
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(Utc::now().timestamp() - TICKET_RATE_WINDOW_SECONDS - 1)
            .execute(&state.db)
            .await
            .unwrap();
        for _ in 1..MAX_TICKETS_PER_USER_PER_WINDOW {
            let _ = create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
                .await
                .unwrap();
        }
        let limited = create_ticket(State(state.clone()), auth_headers(&access), Json(request()))
            .await
            .unwrap_err();
        assert_eq!(limited.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(limited.body.code, "RELAY_RATE_LIMITED");
        assert!(limited.retry_after_secs.is_some());
        let stale: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash='stale-throttle-row'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            stale, 0,
            "rate-limited attempts must commit stale-row cleanup"
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn encrypted_relay_ticket_destination_survives_server_restart() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let data_dir = state.config.data_dir.clone();
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let config = (*state.config).clone();
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let ticket = body["ticket"].as_str().unwrap().to_owned();
        let ticket_hash = sha256_hex(ticket.as_bytes());
        let stored_destination: String =
            sqlx::query_scalar("SELECT target_ip FROM relay_tickets WHERE ticket_hash=?")
                .bind(&ticket_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(stored_destination.starts_with(RELAY_DESTINATION_PREFIX));

        // Close only the pool. The owner-only auth-rate-limit secret and DB
        // remain in place, so the relay destination key stays stable.
        state.db.close().await;
        let restarted = open_state(&database_url, config).await.unwrap();

        let target = consume_ticket(&restarted, &ticket)
            .await
            .unwrap()
            .expect("outstanding ticket should remain usable after restart");
        assert_eq!(target.user_id, user.user_id);
        assert_eq!(target.device_id, user.device_id);
        assert_eq!(target.session_id, user.session_id);
        assert_eq!(target.ip, "10.2.3.4".parse::<IpAddr>().unwrap());
        assert_eq!(target.port, 22);

        let row: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(ticket_hash)
        .fetch_one(&restarted.db)
        .await
        .unwrap();
        assert!(row.0.is_some());
        assert_eq!((row.1.as_str(), row.2), ("", 0));
        close_state(&restarted).await;
    }

    #[tokio::test]
    async fn relay_ticket_destination_tampering_and_hash_swaps_fail_closed_and_clear() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let (first_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let (second_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let first_hash = sha256_hex(first_ticket.as_bytes());
        let second_hash = sha256_hex(second_ticket.as_bytes());
        let (first_envelope, second_envelope): (String, String) = sqlx::query_as(
            "SELECT target_ip,(SELECT target_ip FROM relay_tickets WHERE ticket_hash=?) \
             FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&second_hash)
        .bind(&first_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(first_envelope.starts_with(RELAY_DESTINATION_PREFIX));
        assert!(second_envelope.starts_with(RELAY_DESTINATION_PREFIX));

        // A ciphertext copied to a different ticket hash must fail AEAD
        // authentication and burn the claimed ticket without exposing a
        // destination or leaving encrypted metadata behind.
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(&second_envelope)
            .bind(&first_hash)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(&first_envelope)
            .bind(&second_hash)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &first_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let first_state: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&first_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(first_state.0.is_some());
        assert_eq!((first_state.1.as_str(), first_state.2), ("", 0));
        assert!(
            consume_ticket(&state, &second_ticket)
                .await
                .unwrap()
                .is_none()
        );

        let (tampered_ticket, _) = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.2.3.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let tampered_hash = sha256_hex(tampered_ticket.as_bytes());
        let mut tampered_envelope: String =
            sqlx::query_scalar("SELECT target_ip FROM relay_tickets WHERE ticket_hash=?")
                .bind(&tampered_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let encoded = tampered_envelope
            .strip_prefix(RELAY_DESTINATION_PREFIX)
            .unwrap();
        let mut packed = URL_SAFE_NO_PAD.decode(encoded).unwrap();
        let last = packed.last_mut().unwrap();
        *last ^= 0x80;
        tampered_envelope = format!(
            "{RELAY_DESTINATION_PREFIX}{}",
            URL_SAFE_NO_PAD.encode(packed)
        );
        sqlx::query("UPDATE relay_tickets SET target_ip=? WHERE ticket_hash=?")
            .bind(tampered_envelope)
            .bind(&tampered_hash)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &tampered_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let tampered_state: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(tampered_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(tampered_state.0.is_some());
        assert_eq!((tampered_state.1.as_str(), tampered_state.2), ("", 0));
        close_state(&state).await;
    }

    #[tokio::test]
    async fn legacy_plaintext_destinations_are_invalidated_and_scrubbed() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let session_access_expires_at: String =
            sqlx::query_scalar("SELECT access_expires_at FROM sessions WHERE session_id=?")
                .bind(&user.session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let marker = "198.51.100.237";
        let token = URL_SAFE_NO_PAD.encode([0xa7_u8; 32]);
        let ticket_hash = sha256_hex(token.as_bytes());
        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&ticket_hash)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(marker)
            .bind(2222_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(&session_access_expires_at)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();

        // Model the previous implementation's already-consumed row: its
        // current SQL values are blank, while an older WAL frame can still
        // retain the original destination until startup truncates the WAL.
        let consumed_marker = "198.51.100.238";
        let consumed_token = URL_SAFE_NO_PAD.encode([0xa8_u8; 32]);
        let consumed_hash = sha256_hex(consumed_token.as_bytes());
        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&consumed_hash)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(consumed_marker)
            .bind(2223_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(&session_access_expires_at)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE relay_tickets SET consumed_at=?,target_ip='',target_port=0 WHERE ticket_hash=?",
        )
        .bind(now_rfc3339())
        .bind(&consumed_hash)
        .execute(&state.db)
        .await
        .unwrap();

        clear_legacy_relay_ticket_destinations(&state.db)
            .await
            .unwrap();

        let ticket: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(ticket.0.is_some());
        assert_eq!((ticket.1.as_str(), ticket.2), ("", 0));
        assert!(consume_ticket(&state, &token).await.unwrap().is_none());
        let consumed_ticket: (Option<String>, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(&consumed_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(consumed_ticket.0.is_some());
        assert_eq!((consumed_ticket.1.as_str(), consumed_ticket.2), ("", 0));

        let database_path = state.config.data_dir.join("atermius.db");
        let database_bytes = std::fs::read(database_path).unwrap();
        for plaintext_marker in [marker, consumed_marker] {
            assert!(
                !database_bytes
                    .windows(plaintext_marker.len())
                    .any(|window| window == plaintext_marker.as_bytes())
            );
        }
        let wal_path = state.config.data_dir.join("atermius.db-wal");
        if wal_path.exists() {
            let wal_bytes = std::fs::read(wal_path).unwrap();
            for plaintext_marker in [marker, consumed_marker] {
                assert!(
                    !wal_bytes
                        .windows(plaintext_marker.len())
                        .any(|window| window == plaintext_marker.as_bytes())
                );
            }
        }
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_ticket_lifetime_is_bounded_by_refresh_expiry() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let refresh_expiry = (Utc::now() + ChronoDuration::seconds(20)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(&refresh_expiry)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();

        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        assert_eq!(body["expires_at"], refresh_expiry);
        let token = body["ticket"].as_str().unwrap();

        let expired_refresh = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(expired_refresh)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(consume_ticket(&state, token).await.unwrap().is_none());
        let expired_issue = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(expired_issue.status, StatusCode::UNAUTHORIZED);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn revoked_session_cannot_consume_relay_ticket() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let token = body["ticket"].as_str().unwrap().to_owned();
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(consume_ticket(&state, &token).await.unwrap().is_none());
        let consumed: Option<String> = sqlx::query_scalar("SELECT consumed_at FROM relay_tickets")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(consumed, None);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn concurrent_ticket_replay_has_one_winner_and_records_connection_without_target() {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let token = body["ticket"].as_str().unwrap().to_owned();
        let (first, second) = tokio::join!(
            consume_ticket(&state, &token),
            consume_ticket(&state, &token)
        );
        assert_eq!(
            usize::from(first.unwrap().is_some()) + usize::from(second.unwrap().is_some()),
            1
        );
        let target = sqlx::query(
            "SELECT user_id,device_id,session_id,target_ip,target_port FROM relay_tickets",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        let connection = RelayTarget {
            user_id: target.get("user_id"),
            device_id: target.get("device_id"),
            session_id: target.get("session_id"),
            ip: "10.2.3.4".parse().unwrap(),
            port: 22,
            authorization_revision: 0,

            connection_id: None,
        };
        assert!(
            record_connected(&state, &connection, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        let scope = crate::audit::account_scope_id(&state.cursor_key, &user.user_id).unwrap();
        let actions: Vec<String> = sqlx::query_scalar("SELECT action FROM audit_events WHERE scope_type='account' AND scope_id=? ORDER BY event_id")
            .bind(scope)
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert_eq!(
            actions,
            vec![
                "relay.ticket_issued".to_owned(),
                "relay.connected".to_owned()
            ]
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_connection_survives_access_expiry_and_refresh_but_not_session_expiry_or_revocation()
     {
        let state = test_state().await;
        let (user, access) = seed_session(&state).await;
        let Json(body) = create_ticket(
            State(state.clone()),
            auth_headers(&access),
            Json(TicketRequest {
                device_id: user.device_id.clone(),
                target_host: "10.2.3.4".to_owned(),
                target_port: 22,
            }),
        )
        .await
        .unwrap();
        let target = consume_ticket(&state, body["ticket"].as_str().unwrap())
            .await
            .unwrap()
            .expect("fresh ticket should bind to its active session");

        // A just-expired access token may precede the client's notification
        // refresh. That does not end an already-authorized SSH transport while
        // the session's refresh lifetime is still active.
        let expired_access = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET access_expires_at=? WHERE session_id=?")
            .bind(expired_access)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(relay_session_active(&state, &target).await);
        assert!(
            record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=?")
            .bind(&user.device_id)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("UPDATE users SET status='disabled' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );
        sqlx::query("UPDATE users SET status='active' WHERE user_id=?")
            .bind(&user.user_id)
            .execute(&state.db)
            .await
            .unwrap();

        // Refresh rotates bearer credentials and extends the same session.
        // An already-consumed one-use ticket stays attached to that session.
        let refreshed_expiry = (Utc::now() + ChronoDuration::minutes(20)).to_rfc3339();
        sqlx::query("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires_at=? WHERE session_id=?")
            .bind(sha256_hex(b"rotated access token"))
            .bind(sha256_hex(b"rotated refresh token"))
            .bind(refreshed_expiry)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();

        assert!(relay_session_active(&state, &target).await);
        assert!(
            record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        let expired_refresh = (Utc::now() - ChronoDuration::seconds(1)).to_rfc3339();
        sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
            .bind(expired_refresh)
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        assert!(
            !record_connected(&state, &target, uuid::Uuid::new_v4())
                .await
                .unwrap()
        );

        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        assert!(!relay_session_active(&state, &target).await);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn relay_connection_limits_cover_user_and_instance_and_release_on_drop() {
        let mut state = test_state().await;
        state.relay_connection_slots = Arc::new(tokio::sync::Semaphore::new(2));
        let state = Arc::new(state);
        let first = acquire_connection(state.clone(), "user-a").unwrap();
        assert!(acquire_connection(state.clone(), "user-a").is_none());
        let second = acquire_connection(state.clone(), "user-b").unwrap();
        assert!(acquire_connection(state.clone(), "user-c").is_none());
        drop(first);
        let third = acquire_connection(state.clone(), "user-c").unwrap();
        drop(second);
        drop(third);
        assert!(state.relay_connections.lock().unwrap().is_empty());
        assert_eq!(state.relay_connection_slots.available_permits(), 2);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn blocked_relay_write_keeps_session_revocation_live() {
        let state = Arc::new(test_state().await);
        let (user, _) = seed_session(&state).await;
        let target = RelayTarget {
            user_id: user.user_id.clone(),
            device_id: user.device_id.clone(),
            session_id: user.session_id.clone(),
            ip: "10.0.0.1".parse().unwrap(),
            port: 22,
            authorization_revision: 0,

            connection_id: None,
        };
        let task_state = state.clone();
        let task_target = target.clone();
        let pending_write = tokio::spawn(async move {
            let (mut writer, _reader) = tokio::io::duplex(1);
            let payload = vec![0x5a; 4096];
            let mut checks = tokio::time::interval(Duration::from_millis(10));
            checks.tick().await;
            relay_io_with_guards(
                writer.write_all(&payload),
                &task_state,
                &task_target,
                Instant::now() + Duration::from_secs(30),
                &mut checks,
            )
            .await
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
            .bind(now_rfc3339())
            .bind(&user.session_id)
            .execute(&state.db)
            .await
            .unwrap();
        let result = tokio::time::timeout(Duration::from_secs(1), pending_write)
            .await
            .expect("blocked write did not observe session revocation")
            .unwrap();
        assert!(matches!(result, Err(RelayIoAbort::SessionInactive)));
        close_state(&state).await;
    }

    #[tokio::test]
    async fn maintenance_prunes_old_relay_ticket_rows() {
        let state = test_state().await;
        let (user, _) = seed_session(&state).await;
        let now = Utc::now().timestamp();
        for (hash, age) in [("old-ticket", 120_i64), ("recent-ticket", 20_i64)] {
            sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,created_at) VALUES(?,?,?,?,?,?,?)")
                .bind(hash)
                .bind(&user.user_id)
                .bind(&user.device_id)
                .bind("10.2.3.4")
                .bind(22_i64)
                .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
                .bind(now - age)
                .execute(&state.db)
                .await
                .unwrap();
        }
        let mut tx = state.db.begin().await.unwrap();
        prune_tickets_tx(&mut tx, now - TICKET_RATE_WINDOW_SECONDS)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let remaining: Vec<String> =
            sqlx::query_scalar("SELECT ticket_hash FROM relay_tickets ORDER BY ticket_hash")
                .fetch_all(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining, ["recent-ticket"]);
        close_state(&state).await;
    }

    #[test]
    fn admin_relay_policy_body_is_exact_bounded_and_canonical() {
        let valid = r#"{"expected_revision":0,"enabled":false,"allow_cidrs":["10.1.0.0/16"],"allow_ports":[22,2222]}"#;
        let parsed: RelayPolicyUpdateRequest = serde_json::from_str(valid).unwrap();
        let policy = parse_requested_policy(parsed).unwrap();
        assert_eq!(
            policy.allow_cidrs,
            ["10.1.0.0/16".parse::<IpNet>().unwrap()]
        );
        assert_eq!(policy.allow_ports, [22, 2222]);

        for invalid in [
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":[],"allow_ports":[],"extra":true}"#,
            r#"{"expected_revision":0,"expected_revision":0,"enabled":true,"allow_cidrs":[],"allow_ports":[]}"#,
            r#"{"expected_revision":-1,"enabled":true,"allow_cidrs":[],"allow_ports":[]}"#,
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":["10.1.2.3/16"],"allow_ports":[]}"#,
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":["2001:DB8::/32"],"allow_ports":[]}"#,
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":["10.1.0.0/16","10.1.0.0/16"],"allow_ports":[]}"#,
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":[],"allow_ports":[22,22]}"#,
            r#"{"expected_revision":0,"enabled":true,"allow_cidrs":[],"allow_ports":[0]}"#,
        ] {
            let parsed = serde_json::from_str::<RelayPolicyUpdateRequest>(invalid);
            assert!(
                parsed.is_err()
                    || parsed.is_ok_and(|request| parse_requested_policy(request).is_err()),
                "invalid body must be rejected: {invalid}"
            );
        }

        let valid_user = r#"{"expected_revision":0,"expected_instance_policy_revision":0,"enabled":false,"allow_cidrs":[],"allow_ports":[]}"#;
        assert!(serde_json::from_str::<RelayUserPolicyUpdateRequest>(valid_user).is_ok());
        assert!(
            serde_json::from_str::<RelayUserPolicyUpdateRequest>(
                r#"{"expected_revision":0,"enabled":false,"allow_cidrs":[],"allow_ports":[]}"#
            )
            .is_err()
        );
        let negative_instance_revision: RelayUserPolicyUpdateRequest =
            serde_json::from_str(
                r#"{"expected_revision":0,"expected_instance_policy_revision":-1,"enabled":false,"allow_cidrs":[],"allow_ports":[]}"#,
            )
            .unwrap();
        assert!(parse_user_requested_policy(negative_instance_revision).is_err());
    }

    #[tokio::test]
    async fn admin_relay_policy_revision_audit_ticket_and_runtime_enforcement_are_atomic() {
        let state = admin_test_state().await;
        let (user, access) = seed_admin_session(&state).await;

        let Json(initial) = get_admin_policy(State(state.clone()), auth_headers(&access))
            .await
            .unwrap();
        assert_eq!(
            initial
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            [
                "deployment_limits",
                "max_connections_per_user",
                "policy",
                "revision",
                "updated_at"
            ]
        );
        assert_eq!(
            initial["policy"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["allow_cidrs", "allow_ports", "enabled"]
        );
        assert_eq!(
            initial["deployment_limits"]
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            ["allow_cidrs", "allow_ports", "relay_available"]
        );
        assert_eq!(initial["revision"], 0);
        assert_eq!(initial["updated_at"], Value::Null);
        assert_eq!(initial["policy"]["enabled"], true);
        assert_eq!(initial["policy"]["allow_cidrs"], json!(["10.0.0.0/8"]));
        assert_eq!(initial["deployment_limits"]["relay_available"], true);
        assert_eq!(initial["max_connections_per_user"], 1);

        let now = Utc::now();
        let session_expires: String =
            sqlx::query_scalar("SELECT access_expires_at FROM sessions WHERE session_id=?")
                .bind(&user.session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        for (hash, consumed_at) in [
            ("unused-before-policy-change", None),
            ("already-consumed", Some(now.to_rfc3339())),
        ] {
            sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,consumed_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)")
                .bind(hash)
                .bind(&user.user_id)
                .bind(&user.device_id)
                .bind("10.1.2.3")
                .bind(22_i64)
                .bind((now + ChronoDuration::seconds(30)).to_rfc3339())
                .bind(consumed_at)
                .bind(&user.session_id)
                .bind(&session_expires)
                .bind(now.timestamp())
                .execute(&state.db)
                .await
                .unwrap();
        }

        let first_request: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.0.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(changed) = update_admin_policy(
            State(state.clone()),
            auth_headers(&access),
            Ok(Json(first_request)),
        )
        .await
        .unwrap();
        assert_eq!(changed["revision"], 1);
        assert!(changed["updated_at"].as_str().is_some());
        assert_eq!(changed["policy"]["allow_cidrs"], json!(["10.0.0.0/16"]));
        let retained_tickets: Vec<String> =
            sqlx::query_scalar("SELECT ticket_hash FROM relay_tickets ORDER BY ticket_hash")
                .fetch_all(&state.db)
                .await
                .unwrap();
        assert_eq!(retained_tickets, ["already-consumed"]);

        let denied_issue = issue_ticket(
            &state,
            &user.user_id,
            &user.device_id,
            &user.session_id,
            &user.access_hash,
            "10.1.2.3".parse().unwrap(),
            22,
        )
        .await
        .err()
        .unwrap();
        assert_eq!(denied_issue.body.code, "TARGET_DENIED");

        let stale_ticket = URL_SAFE_NO_PAD.encode([0x31_u8; 32]);
        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(sha256_hex(stale_ticket.as_bytes()))
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind("10.1.2.3")
            .bind(22_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(&session_expires)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            consume_ticket(&state, &stale_ticket)
                .await
                .unwrap()
                .is_none()
        );
        let stale_consumed: (String, String, i64) = sqlx::query_as(
            "SELECT consumed_at,target_ip,target_port FROM relay_tickets WHERE ticket_hash=?",
        )
        .bind(sha256_hex(stale_ticket.as_bytes()))
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(stale_consumed.1, "");
        assert_eq!(stale_consumed.2, 0);

        let policy_audit: (i64, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT COUNT(*),MAX(actor_user_id),MAX(actor_device_id) FROM audit_events WHERE action='admin.relay_policy_updated'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            policy_audit,
            (1, Some(user.user_id.clone()), Some(user.device_id.clone()))
        );

        sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES('unused-before-noop',?,?,?,?,?,?,?,?)")
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind("10.0.1.3")
            .bind(22_i64)
            .bind((Utc::now() + ChronoDuration::seconds(30)).to_rfc3339())
            .bind(&user.session_id)
            .bind(session_expires)
            .bind(Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();
        let no_op_request: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 1,
            "enabled": true,
            "allow_cidrs": ["10.0.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(no_op) = update_admin_policy(
            State(state.clone()),
            auth_headers(&access),
            Ok(Json(no_op_request)),
        )
        .await
        .unwrap();
        assert_eq!(no_op["revision"], changed["revision"]);
        assert_eq!(no_op["updated_at"], changed["updated_at"]);
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.relay_policy_updated'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            audit_count, 1,
            "no-op policy PUT must not add audit history"
        );
        let no_op_ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash='unused-before-noop'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            no_op_ticket_count, 1,
            "no-op policy PUT must not clear tickets"
        );

        let stale_request: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.0.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let stale = update_admin_policy(
            State(state.clone()),
            auth_headers(&access),
            Ok(Json(stale_request)),
        )
        .await
        .err()
        .unwrap();
        assert_eq!(stale.status, StatusCode::CONFLICT);
        assert_eq!(stale.body.code, "RELAY_POLICY_CONFLICT");

        let blocked_target = RelayTarget {
            user_id: user.user_id.clone(),
            device_id: user.device_id.clone(),
            session_id: user.session_id.clone(),
            ip: "10.1.2.3".parse().unwrap(),
            port: 22,
            authorization_revision: 0,

            connection_id: None,
        };
        let allowed_target = RelayTarget {
            ip: "10.0.1.3".parse().unwrap(),
            ..blocked_target.clone()
        };
        assert!(!relay_connection_active(&state, &blocked_target).await);
        assert!(relay_connection_active(&state, &allowed_target).await);

        let disable_request: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 1,
            "enabled": false,
            "allow_cidrs": ["10.0.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(disabled) = update_admin_policy(
            State(state.clone()),
            auth_headers(&access),
            Ok(Json(disable_request)),
        )
        .await
        .unwrap();
        assert_eq!(disabled["revision"], 2);
        assert!(!relay_connection_active(&state, &allowed_target).await);

        let (data_dir, config) = (state.config.data_dir.clone(), (*state.config).clone());
        state.db.close().await;
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let restarted = open_state(&database, config).await.unwrap();
        let Json(persisted) = get_admin_policy(State(restarted.clone()), auth_headers(&access))
            .await
            .unwrap();
        assert_eq!(persisted["revision"], 2);
        assert_eq!(persisted["policy"]["enabled"], false);
        close_state(&restarted).await;
    }

    #[tokio::test]
    async fn user_relay_policy_isolated_cas_revocation_and_reset_inherits_instance() {
        let state = admin_test_state().await;
        let (admin, admin_access) = seed_admin_session(&state).await;
        let (member, _) = seed_session(&state).await;

        let Json(inherited) = get_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
        )
        .await
        .unwrap();
        assert_eq!(inherited["inherited"], true);
        assert_eq!(inherited["revision"], 0);
        assert_eq!(inherited["policy"]["allow_cidrs"], json!(["10.0.0.0/8"]));
        assert_eq!(inherited["effective_policy"]["allow_ports"], json!([22]));

        let (member_ticket, _) = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.3".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let admin_ticket = issue_ticket(
            &state,
            &admin.user_id,
            &admin.device_id,
            &admin.session_id,
            &admin.access_hash,
            "10.1.2.3".parse().unwrap(),
            22,
        )
        .await
        .unwrap()
        .0;

        let set_user_policy: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(restricted) = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(set_user_policy)),
        )
        .await
        .unwrap();
        assert_eq!(restricted["revision"], 1);
        assert_eq!(restricted["inherited"], false);
        assert_eq!(
            restricted["effective_policy"]["allow_cidrs"],
            json!(["10.1.0.0/16"])
        );
        assert!(
            consume_ticket(&state, &member_ticket)
                .await
                .unwrap()
                .is_none()
        );
        assert!(
            consume_ticket(&state, &admin_ticket)
                .await
                .unwrap()
                .is_some()
        );

        let (same_policy_ticket, _) = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let unchanged_user_policy: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 1,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(unchanged) = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(unchanged_user_policy)),
        )
        .await
        .unwrap();
        assert_eq!(unchanged["revision"], restricted["revision"]);
        assert_eq!(unchanged["updated_at"], restricted["updated_at"]);
        assert!(
            consume_ticket(&state, &same_policy_ticket)
                .await
                .unwrap()
                .is_some()
        );

        let old_target = RelayTarget {
            user_id: member.user_id.clone(),
            device_id: member.device_id.clone(),
            session_id: member.session_id.clone(),
            ip: "10.1.2.3".parse().unwrap(),
            port: 22,
            authorization_revision: 0,

            connection_id: None,
        };
        let other_user_target = RelayTarget {
            user_id: admin.user_id.clone(),
            device_id: admin.device_id.clone(),
            session_id: admin.session_id.clone(),
            ..old_target.clone()
        };
        assert!(relay_connection_active(&state, &old_target).await);
        assert!(relay_connection_active(&state, &other_user_target).await);
        assert_eq!(
            issue_ticket(
                &state,
                &member.user_id,
                &member.device_id,
                &member.session_id,
                &member.access_hash,
                "10.2.2.3".parse().unwrap(),
                22,
            )
            .await
            .unwrap_err()
            .body
            .code,
            "TARGET_DENIED"
        );

        let stale: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let conflict = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(stale)),
        )
        .await
        .unwrap_err();
        assert_eq!(conflict.status, StatusCode::CONFLICT);
        assert_eq!(conflict.body.code, "RELAY_USER_POLICY_CONFLICT");

        let replacement_ticket = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.5".parse().unwrap(),
            22,
        )
        .await
        .unwrap()
        .0;
        let narrow_user_policy: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 1,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.2.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(narrowed) = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(narrow_user_policy)),
        )
        .await
        .unwrap();
        assert_eq!(narrowed["revision"], 2);
        assert!(!relay_connection_active(&state, &old_target).await);
        assert!(relay_connection_active(&state, &other_user_target).await);
        assert!(
            consume_ticket(&state, &replacement_ticket)
                .await
                .unwrap()
                .is_none()
        );

        let reset_request: RelayUserPolicyResetRequest = serde_json::from_value(json!({
            "expected_revision": 2
        }))
        .unwrap();
        let Json(reset) = reset_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(reset_request)),
        )
        .await
        .unwrap();
        assert_eq!(reset["inherited"], true);
        assert_eq!(reset["revision"], 3);
        assert_eq!(
            reset["effective_policy"]["allow_cidrs"],
            json!(["10.0.0.0/8"])
        );
        assert!(relay_connection_active(&state, &old_target).await);
        let remaining_user_rows: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(remaining_user_rows, 0);

        let stale_after_reset: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let stale_after_reset = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(stale_after_reset)),
        )
        .await
        .unwrap_err();
        assert_eq!(stale_after_reset.status, StatusCode::CONFLICT);
        assert_eq!(stale_after_reset.body.code, "RELAY_USER_POLICY_CONFLICT");

        let inherited_noop: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 3,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.0.0.0/8"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(inherited_noop) = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(inherited_noop)),
        )
        .await
        .unwrap();
        assert_eq!(inherited_noop["inherited"], true);
        assert_eq!(inherited_noop["revision"], 3);
        let override_rows: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(override_rows, 0);

        let reset_again: RelayUserPolicyResetRequest = serde_json::from_value(json!({
            "expected_revision": 3
        }))
        .unwrap();
        let Json(no_op_reset) = reset_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(reset_again)),
        )
        .await
        .unwrap();
        assert_eq!(no_op_reset["inherited"], true);
        assert_eq!(no_op_reset["revision"], 3);

        let global_update: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.3.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let _ = update_admin_policy(
            State(state.clone()),
            auth_headers(&admin_access),
            Ok(Json(global_update)),
        )
        .await
        .unwrap();
        let Json(following_instance) = get_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
        )
        .await
        .unwrap();
        assert_eq!(following_instance["inherited"], true);
        assert_eq!(
            following_instance["effective_policy"]["allow_cidrs"],
            json!(["10.3.0.0/16"])
        );
        assert!(
            issue_ticket(
                &state,
                &member.user_id,
                &member.device_id,
                &member.session_id,
                &member.access_hash,
                "10.3.1.1".parse().unwrap(),
                22,
            )
            .await
            .is_ok()
        );
        assert!(
            issue_ticket(
                &state,
                &member.user_id,
                &member.device_id,
                &member.session_id,
                &member.access_hash,
                "10.1.2.3".parse().unwrap(),
                22,
            )
            .await
            .is_err()
        );

        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.relay_policy_updated' AND resource_type='relay_user_policy'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            audit_count, 3,
            "two changed user PUTs and reset are audited; idempotent reset is not"
        );
        let raw_resource_ids: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.relay_policy_updated' AND resource_type='relay_user_policy' AND resource_id=?",
        )
        .bind(&member.user_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            raw_resource_ids, 0,
            "user account ID must not be stored in audit resource_id"
        );

        assert!(
            serde_json::from_value::<TicketRequest>(json!({
                "device_id": member.device_id,
                "target_host": "10.3.1.1",
                "target_port": 22,
                "user_id": admin.user_id
            }))
            .is_err()
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn user_relay_policy_put_requires_atomic_instance_revision_cas() {
        let state = admin_test_state().await;
        let (_admin, admin_access) = seed_admin_session(&state).await;
        let (member, _) = seed_session(&state).await;

        let Json(initial_instance) =
            get_admin_policy(State(state.clone()), auth_headers(&admin_access))
                .await
                .unwrap();
        let Json(initial_user) = get_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
        )
        .await
        .unwrap();
        assert_eq!(initial_instance["revision"], 0);
        assert_eq!(initial_user["revision"], 0);
        assert_eq!(initial_user["instance_policy_revision"], 0);
        assert_eq!(initial_user["inherited"], true);

        let narrowed_instance: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": initial_instance["revision"],
            "enabled": true,
            "allow_cidrs": ["10.0.0.0/9"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(narrowed_instance) = update_admin_policy(
            State(state.clone()),
            auth_headers(&admin_access),
            Ok(Json(narrowed_instance)),
        )
        .await
        .unwrap();
        assert_eq!(narrowed_instance["revision"], 1);

        let (ticket, _) = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.3".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let ticket_hash = sha256_hex(ticket.as_bytes());

        let stale_instance_request: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": initial_user["revision"],
            "expected_instance_policy_revision": initial_user["instance_policy_revision"],
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let stale = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(stale_instance_request)),
        )
        .await
        .unwrap_err();
        assert_eq!(stale.status, StatusCode::CONFLICT);
        assert_eq!(stale.body.code, "RELAY_USER_POLICY_CONFLICT");

        let override_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let watermark_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policy_revisions WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
        )
        .bind(&ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let user_audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.relay_policy_updated' AND resource_type='relay_user_policy'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(override_count, 0, "stale instance CAS leaked an override");
        assert_eq!(
            watermark_count, 0,
            "stale instance CAS advanced the watermark"
        );
        assert_eq!(
            ticket_count, 1,
            "stale instance CAS revoked an unused ticket"
        );
        assert_eq!(
            user_audit_count, 0,
            "stale instance CAS wrote an audit event"
        );

        let Json(current_user) = get_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
        )
        .await
        .unwrap();
        assert_eq!(current_user["revision"], initial_user["revision"]);
        assert_eq!(
            current_user["instance_policy_revision"],
            narrowed_instance["revision"]
        );
        let retry: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": current_user["revision"],
            "expected_instance_policy_revision": current_user["instance_policy_revision"],
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(saved) = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(retry)),
        )
        .await
        .unwrap();
        assert_eq!(saved["inherited"], false);
        assert_eq!(saved["revision"], 1);
        assert_eq!(
            saved["instance_policy_revision"],
            narrowed_instance["revision"]
        );

        let final_ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
        )
        .bind(&ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let final_user_audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.relay_policy_updated' AND resource_type='relay_user_policy'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(final_ticket_count, 0);
        assert_eq!(final_user_audit_count, 1);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn user_relay_policy_put_and_reset_roll_back_when_audit_insert_fails() {
        let state = admin_test_state().await;
        let (_admin, admin_access) = seed_admin_session(&state).await;
        let (member, _) = seed_session(&state).await;

        let (put_ticket, _) = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.3".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let put_ticket_hash = sha256_hex(put_ticket.as_bytes());
        sqlx::query(
            "CREATE TRIGGER reject_relay_user_policy_audit BEFORE INSERT ON audit_events \
             WHEN NEW.action='admin.relay_policy_updated' AND NEW.resource_type='relay_user_policy' \
             BEGIN SELECT RAISE(ABORT,'injected relay user policy audit failure'); END",
        )
        .execute(&state.db)
        .await
        .unwrap();

        let put_request: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let put_error = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(put_request)),
        )
        .await
        .unwrap_err();
        assert_eq!(put_error.status, StatusCode::INTERNAL_SERVER_ERROR);

        let put_override_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policies WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let put_revision_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policy_revisions WHERE user_id=?")
                .bind(&member.user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let put_ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
        )
        .bind(&put_ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            put_override_count, 0,
            "failed user PUT leaked the override row"
        );
        assert_eq!(
            put_revision_count, 0,
            "failed user PUT leaked its CAS watermark"
        );
        assert_eq!(
            put_ticket_count, 1,
            "failed user PUT deleted its unused ticket"
        );

        sqlx::query("DROP TRIGGER reject_relay_user_policy_audit")
            .execute(&state.db)
            .await
            .unwrap();
        let accepted_request: RelayUserPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "expected_instance_policy_revision": 0,
            "enabled": true,
            "allow_cidrs": ["10.1.0.0/16"],
            "allow_ports": [22]
        }))
        .unwrap();
        let _ = update_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(accepted_request)),
        )
        .await
        .unwrap();
        let successful_put_ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
        )
        .bind(&put_ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(successful_put_ticket_count, 0);

        let (reset_ticket, _) = issue_ticket(
            &state,
            &member.user_id,
            &member.device_id,
            &member.session_id,
            &member.access_hash,
            "10.1.2.4".parse().unwrap(),
            22,
        )
        .await
        .unwrap();
        let reset_ticket_hash = sha256_hex(reset_ticket.as_bytes());
        sqlx::query(
            "CREATE TRIGGER reject_relay_user_policy_audit BEFORE INSERT ON audit_events \
             WHEN NEW.action='admin.relay_policy_updated' AND NEW.resource_type='relay_user_policy' \
             BEGIN SELECT RAISE(ABORT,'injected relay user policy audit failure'); END",
        )
        .execute(&state.db)
        .await
        .unwrap();

        let reset_request: RelayUserPolicyResetRequest = serde_json::from_value(json!({
            "expected_revision": 1
        }))
        .unwrap();
        let reset_error = reset_admin_user_policy(
            State(state.clone()),
            Path(member.user_id.clone()),
            auth_headers(&admin_access),
            Ok(Json(reset_request)),
        )
        .await
        .unwrap_err();
        assert_eq!(reset_error.status, StatusCode::INTERNAL_SERVER_ERROR);

        let (
            override_enabled,
            override_cidrs,
            override_ports,
            override_revision,
            watermark_revision,
        ): (
            Option<i64>,
            Option<String>,
            Option<String>,
            Option<i64>,
            Option<i64>,
        ) = sqlx::query_as(
            "SELECT (SELECT enabled FROM user_relay_policies WHERE user_id=?), \
                    (SELECT allow_cidrs FROM user_relay_policies WHERE user_id=?), \
                    (SELECT allow_ports FROM user_relay_policies WHERE user_id=?), \
                    (SELECT revision FROM user_relay_policies WHERE user_id=?), \
                    (SELECT revision FROM user_relay_policy_revisions WHERE user_id=?)",
        )
        .bind(&member.user_id)
        .bind(&member.user_id)
        .bind(&member.user_id)
        .bind(&member.user_id)
        .bind(&member.user_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let reset_ticket_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM relay_tickets WHERE ticket_hash=? AND consumed_at IS NULL",
        )
        .bind(&reset_ticket_hash)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(override_enabled, Some(1));
        assert_eq!(override_cidrs.as_deref(), Some("[\"10.1.0.0/16\"]"));
        assert_eq!(override_ports.as_deref(), Some("[22]"));
        assert_eq!(
            override_revision,
            Some(1),
            "failed reset deleted the policy override"
        );
        assert_eq!(
            watermark_revision,
            Some(1),
            "failed reset advanced the CAS watermark"
        );
        assert_eq!(
            reset_ticket_count, 1,
            "failed reset deleted its unused ticket"
        );

        sqlx::query("DROP TRIGGER reject_relay_user_policy_audit")
            .execute(&state.db)
            .await
            .unwrap();
        close_state(&state).await;
    }

    #[tokio::test]
    async fn noncanonical_persisted_relay_cidr_fails_closed() {
        let state = test_state().await;
        sqlx::query(
            "INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES(1,1,'[\"10.1.2.3/16\"]','[22]',1,?)",
        )
        .bind(now_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        assert!(read_policy_tx(&mut tx, &state).await.is_err());
        drop(tx);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn deployment_host_bits_are_normalized_in_defaults_and_limits() {
        let state = test_state().await;
        let mut config = (*state.config).clone();
        config.relay_allow_cidrs = vec!["172.19.0.1/24".parse().unwrap()];
        let state = AppState {
            config: Arc::new(config),
            ..state
        };
        let mut tx = state.db.begin().await.unwrap();
        let snapshot = read_policy_tx(&mut tx, &state).await.unwrap();
        assert_eq!(
            snapshot.policy.allow_cidrs,
            ["172.19.0.0/24".parse::<IpNet>().unwrap()]
        );
        let response = admin_policy_json(&state, snapshot);
        assert_eq!(response["policy"]["allow_cidrs"], json!(["172.19.0.0/24"]));
        assert_eq!(
            response["deployment_limits"]["allow_cidrs"],
            json!(["172.19.0.0/24"])
        );
        drop(tx);
        close_state(&state).await;
    }

    #[tokio::test]
    async fn admin_relay_policy_rejects_wider_cidr_and_enabling_when_deployment_unavailable() {
        let state = admin_test_state().await;
        let (_user, access) = seed_admin_session(&state).await;
        let wider: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": false,
            "allow_cidrs": ["10.0.0.0/7"],
            "allow_ports": [22]
        }))
        .unwrap();
        let outside =
            update_admin_policy(State(state.clone()), auth_headers(&access), Ok(Json(wider)))
                .await
                .err()
                .unwrap();
        assert_eq!(outside.status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(outside.body.code, "RELAY_POLICY_OUTSIDE_LIMITS");

        let wider_port: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": false,
            "allow_cidrs": ["10.0.0.0/8"],
            "allow_ports": [23]
        }))
        .unwrap();
        let outside = update_admin_policy(
            State(state.clone()),
            auth_headers(&access),
            Ok(Json(wider_port)),
        )
        .await
        .err()
        .unwrap();
        assert_eq!(outside.status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(outside.body.code, "RELAY_POLICY_OUTSIDE_LIMITS");

        let mut config = test_config(state.config.data_dir.clone());
        config.relay_enabled = false;
        assert_eq!(
            validate_policy_limits(
                &RelayPolicy {
                    enabled: true,
                    allow_cidrs: vec!["10.0.0.0/8".parse().unwrap()],
                    allow_ports: vec![22],
                },
                &AppState {
                    config: Arc::new(config),
                    ..state.clone()
                },
            )
            .err()
            .unwrap()
            .body
            .code,
            "RELAY_POLICY_UNAVAILABLE"
        );
        close_state(&state).await;
    }

    #[tokio::test]
    async fn blocked_relay_write_closes_after_durable_policy_is_disabled() {
        let state = Arc::new(admin_test_state().await);
        let (user, access) = seed_admin_session(&state).await;
        let target = RelayTarget {
            user_id: user.user_id,
            device_id: user.device_id,
            session_id: user.session_id,
            ip: "10.0.0.1".parse().unwrap(),
            port: 22,
            authorization_revision: 0,

            connection_id: None,
        };
        let task_state = state.clone();
        let task_target = target.clone();
        let pending_write = tokio::spawn(async move {
            let (mut writer, _reader) = tokio::io::duplex(1);
            let payload = vec![0x5a; 4096];
            let mut checks = tokio::time::interval(Duration::from_millis(10));
            checks.tick().await;
            relay_io_with_guards(
                writer.write_all(&payload),
                &task_state,
                &task_target,
                Instant::now() + Duration::from_secs(30),
                &mut checks,
            )
            .await
        });

        let disable: RelayPolicyUpdateRequest = serde_json::from_value(json!({
            "expected_revision": 0,
            "enabled": false,
            "allow_cidrs": ["10.0.0.0/8"],
            "allow_ports": [22]
        }))
        .unwrap();
        let Json(_) = update_admin_policy(
            State(state.as_ref().clone()),
            auth_headers(&access),
            Ok(Json(disable)),
        )
        .await
        .unwrap();

        let result = tokio::time::timeout(Duration::from_secs(1), pending_write)
            .await
            .expect("blocked write did not observe relay policy change")
            .unwrap();
        assert!(matches!(result, Err(RelayIoAbort::SessionInactive)));
        close_state(&state).await;
    }
}

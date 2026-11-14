//! Memory-only, ciphertext-only Web terminal observer rooms.
//!
//! A session's SSH connection and plaintext stay on the host. This module
//! authenticates active Vault devices, verifies the host's signed keyboxes
//! and frames, and forwards bounded ciphertext to explicitly named observers.

use crate::{
    ApiError, AppState, auth::AuthUser, current_user, jcs, require_active_collaboration_session_tx,
    require_active_session_device_tx, require_vault_read_tx, sha256_hex,
};
use axum::{
    Json,
    extract::{Path, State, ws::WebSocketUpgrade},
    http::{HeaderMap, StatusCode, header::ORIGIN},
    response::IntoResponse,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use futures_util::SinkExt;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    sync::{OwnedSemaphorePermit, mpsc, watch},
    time::{MissedTickBehavior, interval, timeout},
};
use uuid::Uuid;

const PROTOCOL_VERSION_V1: u8 = 1;
const PROTOCOL_VERSION_V2: u8 = 2;
const MAX_OBSERVERS: usize = 8;
const MAX_ROOMS: usize = 64;
const MAX_PENDING_TICKETS: usize = 1024;
const MAX_TICKETS_PER_USER_PER_MINUTE: usize = 30;
const TICKET_TTL_SECONDS: i64 = 30;
const SESSION_TTL_SECONDS: i64 = 15 * 60;
const MAX_GLOBAL_CONNECTIONS: usize = 128;
const MAX_CONNECTIONS_PER_USER: usize = 8;
const MAX_WS_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_SESSION_TOTAL_BYTES: usize = 256 * 1024 * 1024;
const MAX_CIPHERTEXT_BYTES: usize = 16 * 1024 + 16;
const MAX_CONTROLLER_CIPHERTEXT_BYTES: usize = 8 * 1024 + 16;
const MAX_SAFE_SEQUENCE: u64 = 9_007_199_254_740_991;
const MAX_SESSION_FRAMES_PER_SECOND: u32 = 256;
const MAX_SESSION_BYTES_PER_SECOND: usize = 4 * 1024 * 1024;
const MAX_CONTROLLER_FRAMES_PER_SECOND: u32 = 128;
const MAX_CONTROLLER_BYTES_PER_SECOND: usize = 64 * 1024;
const CONTROLLER_LEASE_TTL_SECONDS: i64 = 5 * 60;
const OBSERVER_QUEUE_FRAMES: usize = 32;
// The host receives input frames from the separate controller socket. Allow
// four controller rate windows to absorb one-second boundary bursts and
// short browser scheduling stalls before the fail-closed slow-host path is
// reached. Per-controller byte/frame rate limits still bound queued payloads.
const HOST_INPUT_QUEUE_FRAMES: usize = 4 * MAX_CONTROLLER_FRAMES_PER_SECOND as usize;
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
const SEND_TIMEOUT: Duration = Duration::from_secs(1);
const RECHECK_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone, Default)]
pub(crate) struct CollaborationState {
    inner: Arc<Mutex<Registry>>,
}

#[derive(Default)]
struct Registry {
    rooms: HashMap<String, Room>,
    tickets: HashMap<String, TicketRecord>,
    tickets_by_user: HashMap<String, (i64, usize)>,
    total_connections: usize,
    connections_by_user: HashMap<String, usize>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
struct Target {
    user_id: String,
    device_id: String,
}

struct Room {
    session_id: String,
    vault_id: String,
    membership_version: i64,
    host_user_id: String,
    host_device_id: String,
    host_signing_public_key: String,
    protocol_version: u8,
    expires_epoch: i64,
    keyboxes: HashMap<Target, Keybox>,
    latest_resize: HashMap<Target, TerminalFrame>,
    host_connection: Option<ConnectionRef>,
    observer_connections: HashMap<Target, ConnectionRef>,
    control_epoch: i64,
    controller_lease: Option<ControllerLease>,
    last_sequences: HashMap<(Target, String), u64>,
    rate_window_started: i64,
    rate_frames: u32,
    rate_bytes: usize,
    total_bytes: usize,
}

#[derive(Clone)]
struct ControllerLease {
    controller: Target,
    lease_id: String,
    control_epoch: i64,
    expires_at: String,
    expires_epoch: i64,
    keybox: ControlKeybox,
    signing_public_key: String,
    connection: Option<ConnectionRef>,
    last_sequence: u64,
    rate_window_started: i64,
    rate_frames: u32,
    rate_bytes: usize,
}

#[derive(Clone)]
struct ConnectionRef {
    id: String,
    outbound: mpsc::Sender<String>,
    close: watch::Sender<CloseSignal>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CloseSignal {
    None,
    SessionEnded,
    ControlRevoked,
    ControlExpired,
}

impl CloseSignal {
    fn frame(self) -> Option<(u16, &'static str)> {
        match self {
            Self::None => None,
            Self::SessionEnded => Some((1000, "SESSION_ENDED")),
            Self::ControlRevoked => Some((4003, "CONTROL_REVOKED")),
            Self::ControlExpired => Some((4003, "CONTROL_EXPIRED")),
        }
    }
}

#[derive(Clone)]
struct TicketRecord {
    session_id: String,
    vault_id: String,
    role: ConnectionRole,
    user_id: String,
    device_id: String,
    auth_session_id: String,
    access_hash: String,
    server_generation: String,
    expires_epoch: i64,
    control_lease_id: Option<String>,
    control_epoch: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConnectionRole {
    Host,
    Observer,
    Controller,
}

impl ConnectionRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Host => "host",
            Self::Observer => "observer",
            Self::Controller => "controller",
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateSessionRequest {
    protocol_version: u8,
    session_id: String,
    expires_at: String,
    observers: Vec<ObserverGrant>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ObserverGrant {
    user_id: String,
    device_id: String,
    keybox: Keybox,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Keybox {
    format: String,
    session_id: String,
    vault_id: String,
    membership_version: i64,
    host_user_id: String,
    host_device_id: String,
    observer_user_id: String,
    observer_device_id: String,
    role: String,
    epoch: i64,
    expires_at: String,
    sealed_secret: String,
    signature: String,
}

#[derive(Serialize)]
struct UnsignedKeybox<'a> {
    format: &'a str,
    session_id: &'a str,
    vault_id: &'a str,
    membership_version: i64,
    host_user_id: &'a str,
    host_device_id: &'a str,
    observer_user_id: &'a str,
    observer_device_id: &'a str,
    role: &'a str,
    epoch: i64,
    expires_at: &'a str,
    sealed_secret: &'a str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ControllerLeaseCreateRequest {
    controller_user_id: String,
    controller_device_id: String,
    lease_id: String,
    control_epoch: i64,
    expires_at: String,
    keybox: ControlKeybox,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ControlKeybox {
    format: String,
    session_id: String,
    vault_id: String,
    membership_version: i64,
    host_user_id: String,
    host_device_id: String,
    controller_user_id: String,
    controller_device_id: String,
    lease_id: String,
    control_epoch: i64,
    purpose: String,
    expires_at: String,
    sealed_secret: String,
    signature: String,
}

#[derive(Serialize)]
struct UnsignedControlKeybox<'a> {
    format: &'a str,
    session_id: &'a str,
    vault_id: &'a str,
    membership_version: i64,
    host_user_id: &'a str,
    host_device_id: &'a str,
    controller_user_id: &'a str,
    controller_device_id: &'a str,
    lease_id: &'a str,
    control_epoch: i64,
    purpose: &'a str,
    expires_at: &'a str,
    sealed_secret: &'a str,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthenticateFrame {
    #[serde(rename = "type")]
    kind: String,
    ticket: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HostApplicationFrame {
    #[serde(rename = "type")]
    kind: String,
    frame: TerminalFrame,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ControllerApplicationFrame {
    #[serde(rename = "type")]
    kind: String,
    frame: TerminalInputFrame,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct TerminalFrame {
    format: String,
    session_id: String,
    vault_id: String,
    membership_version: i64,
    host_user_id: String,
    host_device_id: String,
    recipient_user_id: String,
    recipient_device_id: String,
    role: String,
    epoch: i64,
    sequence: u64,
    kind: String,
    nonce: String,
    ciphertext: String,
    signature: String,
}

#[derive(Serialize)]
struct UnsignedFrame<'a> {
    format: &'a str,
    session_id: &'a str,
    vault_id: &'a str,
    membership_version: i64,
    host_user_id: &'a str,
    host_device_id: &'a str,
    recipient_user_id: &'a str,
    recipient_device_id: &'a str,
    role: &'a str,
    epoch: i64,
    sequence: u64,
    kind: &'a str,
    nonce: &'a str,
    ciphertext: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct TerminalInputFrame {
    format: String,
    session_id: String,
    vault_id: String,
    membership_version: i64,
    host_user_id: String,
    host_device_id: String,
    controller_user_id: String,
    controller_device_id: String,
    lease_id: String,
    control_epoch: i64,
    sequence: u64,
    nonce: String,
    ciphertext: String,
    signature: String,
}

#[derive(Serialize)]
struct UnsignedInputFrame<'a> {
    format: &'a str,
    session_id: &'a str,
    vault_id: &'a str,
    membership_version: i64,
    host_user_id: &'a str,
    host_device_id: &'a str,
    controller_user_id: &'a str,
    controller_device_id: &'a str,
    lease_id: &'a str,
    control_epoch: i64,
    sequence: u64,
    nonce: &'a str,
    ciphertext: &'a str,
}

#[derive(Clone)]
struct AuthorizedTicket {
    record: TicketRecord,
    target: Option<Target>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Revalidation {
    Valid,
    ParticipantInvalid,
    VaultMembershipChanged,
    ControllerLeaseInvalid,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HostFrameAuthorization {
    Forwarded,
    PrincipalInvalid,
    VaultMembershipChanged,
    FrameRejected,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ControllerFrameAuthorization {
    Forwarded,
    PrincipalInvalid,
    VaultMembershipChanged,
    LeaseInvalid,
    FrameRejected,
}

impl Revalidation {
    fn close_room(self, role: ConnectionRole) -> bool {
        self == Self::VaultMembershipChanged || role == ConnectionRole::Host
    }
}

struct ActiveConnectionGuard {
    manager: CollaborationState,
    session_id: String,
    connection_id: String,
    role: ConnectionRole,
    user_id: String,
    target: Option<Target>,
}

impl Drop for ActiveConnectionGuard {
    fn drop(&mut self) {
        self.manager.disconnect(
            &self.session_id,
            &self.connection_id,
            self.role,
            &self.user_id,
            self.target.as_ref(),
        );
    }
}

impl CollaborationState {
    fn install_room_and_host_ticket(
        &self,
        room: Room,
        host: &AuthUser,
        generation: &str,
        session_expires_epoch: i64,
    ) -> Result<String, ApiError> {
        let raw_ticket = random_ticket();
        let now = Utc::now().timestamp();
        let ticket_hash = sha256_hex(raw_ticket.as_bytes());
        let expires_epoch = now
            .saturating_add(TICKET_TTL_SECONDS)
            .min(room.expires_epoch)
            .min(session_expires_epoch);
        if expires_epoch <= now {
            return Err(ApiError::bad_request(
                "INVALID_TERMINAL_SESSION_EXPIRY",
                "terminal session expiry is too close",
            ));
        }
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        registry
            .tickets
            .retain(|_, ticket| ticket.expires_epoch > now);
        prune_expired_rooms_locked(&mut registry, now);
        if registry.rooms.len() >= MAX_ROOMS || registry.tickets.len() >= MAX_PENDING_TICKETS {
            return Err(collaboration_busy());
        }
        if registry.rooms.contains_key(&room.session_id) {
            return Err(ApiError::conflict(
                "TERMINAL_SESSION_EXISTS",
                "terminal session identifier is already in use",
            ));
        }
        check_and_count_ticket(&mut registry, &host.user_id, now)?;
        registry.tickets.insert(
            ticket_hash,
            TicketRecord {
                session_id: room.session_id.clone(),
                vault_id: room.vault_id.clone(),
                role: ConnectionRole::Host,
                user_id: host.user_id.clone(),
                device_id: host.device_id.clone(),
                auth_session_id: host.session_id.clone(),
                access_hash: host.access_hash.clone(),
                server_generation: generation.to_owned(),
                expires_epoch,
                control_lease_id: None,
                control_epoch: None,
            },
        );
        let session_id = room.session_id.clone();
        registry.rooms.insert(session_id, room);
        Ok(raw_ticket)
    }

    fn issue_observer_ticket(
        &self,
        room_id: &str,
        user: &AuthUser,
        generation: &str,
        session_expires_epoch: i64,
    ) -> Result<(String, Keybox, String), ApiError> {
        let raw_ticket = random_ticket();
        let now = Utc::now().timestamp();
        let ticket_hash = sha256_hex(raw_ticket.as_bytes());
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        registry
            .tickets
            .retain(|_, ticket| ticket.expires_epoch > now);
        if registry.tickets.len() >= MAX_PENDING_TICKETS {
            return Err(collaboration_busy());
        }
        let (vault_id, target, keybox) = {
            let room = registry
                .rooms
                .get(room_id)
                .ok_or_else(ApiError::not_found)?;
            let target = Target {
                user_id: user.user_id.clone(),
                device_id: user.device_id.clone(),
            };
            if room.expires_epoch <= now {
                return Err(ApiError::gone(
                    "TERMINAL_SESSION_EXPIRED",
                    "terminal session has expired",
                ));
            }
            if room.keyboxes.get(&target).is_none() {
                return Err(ApiError::not_found());
            }
            (
                room.vault_id.clone(),
                target.clone(),
                room.keyboxes
                    .get(&target)
                    .cloned()
                    .ok_or_else(ApiError::not_found)?,
            )
        };
        let room = registry
            .rooms
            .get(room_id)
            .ok_or_else(ApiError::not_found)?;
        let expires_epoch = now
            .saturating_add(TICKET_TTL_SECONDS)
            .min(room.expires_epoch)
            .min(session_expires_epoch);
        if expires_epoch <= now {
            return Err(ApiError::gone(
                "TERMINAL_SESSION_EXPIRED",
                "terminal session has expired",
            ));
        }
        let ticket_expires_at = DateTime::<Utc>::from_timestamp(expires_epoch, 0)
            .ok_or_else(|| ApiError::internal("terminal ticket expiry is invalid"))?
            .to_rfc3339();
        check_and_count_ticket(&mut registry, &user.user_id, now)?;
        registry.tickets.insert(
            ticket_hash,
            TicketRecord {
                session_id: room_id.to_owned(),
                vault_id,
                role: ConnectionRole::Observer,
                user_id: target.user_id,
                device_id: target.device_id,
                auth_session_id: user.session_id.clone(),
                access_hash: user.access_hash.clone(),
                server_generation: generation.to_owned(),
                expires_epoch,
                control_lease_id: None,
                control_epoch: None,
            },
        );
        Ok((raw_ticket, keybox, ticket_expires_at))
    }

    fn grant_controller_lease(
        &self,
        session_id: &str,
        mut lease: ControllerLease,
    ) -> Result<bool, ApiError> {
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        let now = Utc::now().timestamp();
        let expired_lease_id = registry
            .rooms
            .get(session_id)
            .and_then(|room| room.controller_lease.as_ref())
            .filter(|active| active.expires_epoch <= now)
            .map(|active| active.lease_id.clone());
        if let Some(expired_lease_id) = expired_lease_id {
            let _ = end_controller_lease_locked(
                &mut registry,
                session_id,
                Some(&expired_lease_id),
                "expired",
                CloseSignal::ControlExpired,
            );
        }
        let room = registry
            .rooms
            .get_mut(session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.protocol_version != PROTOCOL_VERSION_V2 || room.expires_epoch <= now {
            return Err(ApiError::conflict(
                "TERMINAL_CONTROLLER_LEASE_UNAVAILABLE",
                "controller leases require an active protocol v2 session",
            ));
        }
        if let Some(active) = room.controller_lease.as_ref() {
            let identical = active.controller == lease.controller
                && active.lease_id == lease.lease_id
                && active.control_epoch == lease.control_epoch
                && active.expires_at == lease.expires_at
                && active.keybox == lease.keybox;
            if identical && active.expires_epoch > now {
                return Ok(false);
            }
            return Err(ApiError::conflict(
                "TERMINAL_CONTROLLER_LEASE_ACTIVE",
                "a controller lease is already active",
            ));
        }
        if lease.control_epoch != room.control_epoch.saturating_add(1) {
            return Err(ApiError::conflict(
                "TERMINAL_CONTROLLER_EPOCH_INVALID",
                "controller epoch must increase by exactly one",
            ));
        }
        lease.connection = None;
        room.control_epoch = lease.control_epoch;
        room.controller_lease = Some(lease);
        Ok(true)
    }

    fn notify_controller_granted(&self, session_id: &str, lease_id: &str) {
        let Ok(mut registry) = self.inner.lock() else {
            return;
        };
        let slow = {
            let Some(room) = registry.rooms.get_mut(session_id) else {
                return;
            };
            let Some(lease) = room
                .controller_lease
                .as_ref()
                .filter(|lease| lease.lease_id == lease_id)
            else {
                return;
            };
            let controller = lease.controller.clone();
            let event = controller_granted_event(room, lease);
            let observer_send_failed = room
                .observer_connections
                .get(&controller)
                .is_some_and(|observer| observer.outbound.try_send(event).is_err());
            let slow = observer_send_failed
                .then(|| room.observer_connections.remove(&controller))
                .flatten();
            slow.map(|connection| (controller, connection))
        };
        if let Some((controller, slow)) = slow {
            let _ = slow.close.send(CloseSignal::SessionEnded);
            revoke_controller_for_observer_disconnect(&mut registry, session_id, &controller);
        }
    }

    fn issue_controller_ticket(
        &self,
        session_id: &str,
        user: &AuthUser,
        generation: &str,
        session_expires_epoch: i64,
    ) -> Result<(String, ControllerLease, String), ApiError> {
        let raw_ticket = random_ticket();
        let now = Utc::now().timestamp();
        let ticket_hash = sha256_hex(raw_ticket.as_bytes());
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        let expired_lease_id = registry
            .rooms
            .get(session_id)
            .and_then(|room| room.controller_lease.as_ref())
            .filter(|lease| lease.expires_epoch <= now)
            .map(|lease| lease.lease_id.clone());
        if let Some(expired_lease_id) = expired_lease_id {
            let _ = end_controller_lease_locked(
                &mut registry,
                session_id,
                Some(&expired_lease_id),
                "expired",
                CloseSignal::ControlExpired,
            );
        }
        registry
            .tickets
            .retain(|_, ticket| ticket.expires_epoch > now);
        if registry.tickets.len() >= MAX_PENDING_TICKETS {
            return Err(collaboration_busy());
        }
        let target = Target {
            user_id: user.user_id.clone(),
            device_id: user.device_id.clone(),
        };
        let (lease, vault_id, expires_epoch) = {
            let room = registry
                .rooms
                .get(session_id)
                .ok_or_else(ApiError::not_found)?;
            let lease = room
                .controller_lease
                .as_ref()
                .ok_or_else(|| ApiError::not_found())?;
            if room.protocol_version != PROTOCOL_VERSION_V2
                || lease.controller != target
                || lease.expires_epoch <= now
                || lease.connection.is_some()
                || !room.keyboxes.contains_key(&target)
            {
                return Err(ApiError::not_found());
            }
            let ticket_expires = now
                .saturating_add(TICKET_TTL_SECONDS)
                .min(lease.expires_epoch)
                .min(room.expires_epoch)
                .min(session_expires_epoch);
            if ticket_expires <= now {
                return Err(ApiError::gone(
                    "TERMINAL_CONTROLLER_LEASE_EXPIRED",
                    "controller lease has expired",
                ));
            }
            (lease.clone(), room.vault_id.clone(), ticket_expires)
        };
        let expires_at = DateTime::<Utc>::from_timestamp(expires_epoch, 0)
            .ok_or_else(|| ApiError::internal("controller ticket expiry is invalid"))?
            .to_rfc3339();
        check_and_count_ticket(&mut registry, &user.user_id, now)?;
        registry.tickets.insert(
            ticket_hash,
            TicketRecord {
                session_id: session_id.to_owned(),
                vault_id,
                role: ConnectionRole::Controller,
                user_id: user.user_id.clone(),
                device_id: user.device_id.clone(),
                auth_session_id: user.session_id.clone(),
                access_hash: user.access_hash.clone(),
                server_generation: generation.to_owned(),
                expires_epoch,
                control_lease_id: Some(lease.lease_id.clone()),
                control_epoch: Some(lease.control_epoch),
            },
        );
        Ok((raw_ticket, lease, expires_at))
    }

    fn revoke_controller_lease(&self, session_id: &str) -> Result<(), ApiError> {
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        let now = Utc::now().timestamp();
        if let Some(expired_lease_id) = registry
            .rooms
            .get(session_id)
            .and_then(|room| room.controller_lease.as_ref())
            .filter(|lease| lease.expires_epoch <= now)
            .map(|lease| lease.lease_id.clone())
        {
            let _ = end_controller_lease_locked(
                &mut registry,
                session_id,
                Some(&expired_lease_id),
                "expired",
                CloseSignal::ControlExpired,
            );
            return Err(ApiError::not_found());
        }
        let room = registry
            .rooms
            .get(session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.protocol_version != PROTOCOL_VERSION_V2 {
            return Err(ApiError::not_found());
        }
        let lease_id = room
            .controller_lease
            .as_ref()
            .map(|lease| lease.lease_id.clone())
            .ok_or_else(ApiError::not_found)?;
        end_controller_lease_locked(
            &mut registry,
            session_id,
            Some(&lease_id),
            "revoked",
            CloseSignal::ControlRevoked,
        )
        .ok_or_else(ApiError::not_found)?;
        Ok(())
    }

    fn end_controller_lease(
        &self,
        session_id: &str,
        lease_id: &str,
        reason: &'static str,
        close_signal: CloseSignal,
    ) {
        if let Ok(mut registry) = self.inner.lock() {
            let _ = end_controller_lease_locked(
                &mut registry,
                session_id,
                Some(lease_id),
                reason,
                close_signal,
            );
        }
    }

    fn expire_controller_lease(&self, session_id: &str, lease_id: &str) {
        if let Ok(mut registry) = self.inner.lock() {
            let expired = registry
                .rooms
                .get(session_id)
                .and_then(|room| room.controller_lease.as_ref())
                .is_some_and(|lease| {
                    lease.lease_id == lease_id && lease.expires_epoch <= Utc::now().timestamp()
                });
            if expired {
                let _ = end_controller_lease_locked(
                    &mut registry,
                    session_id,
                    Some(lease_id),
                    "expired",
                    CloseSignal::ControlExpired,
                );
            }
        }
    }

    fn consume_ticket_memory(&self, ticket: &str, generation: &str) -> Option<AuthorizedTicket> {
        if !is_canonical_ticket(ticket) {
            return None;
        }
        let hash = sha256_hex(ticket.as_bytes());
        let mut registry = self.inner.lock().ok()?;
        let record = registry.tickets.remove(&hash)?;
        if let Some(lease_id) = registry
            .rooms
            .get(&record.session_id)
            .and_then(|room| room.controller_lease.as_ref())
            .filter(|lease| lease.expires_epoch <= Utc::now().timestamp())
            .map(|lease| lease.lease_id.clone())
        {
            let _ = end_controller_lease_locked(
                &mut registry,
                &record.session_id,
                Some(&lease_id),
                "expired",
                CloseSignal::ControlExpired,
            );
        }
        if record.expires_epoch <= Utc::now().timestamp() || record.server_generation != generation
        {
            return None;
        }
        let room = registry.rooms.get(&record.session_id)?;
        if room.vault_id != record.vault_id || room.expires_epoch <= Utc::now().timestamp() {
            return None;
        }
        let target = match record.role {
            ConnectionRole::Host
                if room.host_user_id == record.user_id
                    && room.host_device_id == record.device_id =>
            {
                None
            }
            ConnectionRole::Observer => {
                let target = Target {
                    user_id: record.user_id.clone(),
                    device_id: record.device_id.clone(),
                };
                Some(room.keyboxes.contains_key(&target).then_some(target)?)
            }
            ConnectionRole::Controller => {
                let target = Target {
                    user_id: record.user_id.clone(),
                    device_id: record.device_id.clone(),
                };
                let lease = room.controller_lease.as_ref()?;
                if lease.expires_epoch <= Utc::now().timestamp()
                    || lease.connection.is_some()
                    || lease.controller != target
                    || record.control_lease_id.as_deref() != Some(lease.lease_id.as_str())
                    || record.control_epoch != Some(lease.control_epoch)
                {
                    return None;
                }
                Some(target)
            }
            _ => return None,
        };
        Some(AuthorizedTicket { record, target })
    }

    fn cancel_ticket(&self, ticket: &str) {
        if let Ok(mut registry) = self.inner.lock() {
            registry.tickets.remove(&sha256_hex(ticket.as_bytes()));
        }
    }

    fn admit_connection(
        &self,
        authorized: &AuthorizedTicket,
        outbound: mpsc::Sender<String>,
        close: watch::Sender<CloseSignal>,
    ) -> Option<(String, ActiveConnectionGuard)> {
        let mut registry = self.inner.lock().ok()?;
        if registry.total_connections >= MAX_GLOBAL_CONNECTIONS
            || registry
                .connections_by_user
                .get(&authorized.record.user_id)
                .copied()
                .unwrap_or(0)
                >= MAX_CONNECTIONS_PER_USER
        {
            return None;
        }
        let room = registry.rooms.get_mut(&authorized.record.session_id)?;
        if room.expires_epoch <= Utc::now().timestamp() {
            return None;
        }
        if authorized.record.role == ConnectionRole::Observer {
            let target = authorized.target.as_ref()?;
            if let Some(resize) = room.latest_resize.get(target) {
                outbound
                    .try_send(serialize_frame_message(resize).ok()?)
                    .ok()?;
            }
            if room.protocol_version == PROTOCOL_VERSION_V2
                && let Some(lease) = room.controller_lease.as_ref().filter(|lease| {
                    lease.controller == *target && lease.expires_epoch > Utc::now().timestamp()
                })
            {
                outbound
                    .try_send(controller_granted_event(room, lease))
                    .ok()?;
            }
        }
        let connection_id = Uuid::new_v4().to_string();
        let conn = ConnectionRef {
            id: connection_id.clone(),
            outbound,
            close,
        };
        match authorized.record.role {
            ConnectionRole::Host => {
                if room.host_connection.is_some() {
                    return None;
                }
                room.host_connection = Some(conn);
            }
            ConnectionRole::Observer => {
                let target = authorized.target.as_ref()?;
                if room.observer_connections.contains_key(target)
                    || room.observer_connections.len() >= MAX_OBSERVERS
                {
                    return None;
                }
                room.observer_connections.insert(target.clone(), conn);
            }
            ConnectionRole::Controller => {
                let target = authorized.target.as_ref()?;
                let lease = room.controller_lease.as_mut()?;
                if room.protocol_version != PROTOCOL_VERSION_V2
                    || lease.expires_epoch <= Utc::now().timestamp()
                    || lease.controller != *target
                    || authorized.record.control_lease_id.as_deref()
                        != Some(lease.lease_id.as_str())
                    || authorized.record.control_epoch != Some(lease.control_epoch)
                    || lease.connection.is_some()
                {
                    return None;
                }
                lease.connection = Some(conn);
            }
        }
        registry.total_connections += 1;
        *registry
            .connections_by_user
            .entry(authorized.record.user_id.clone())
            .or_default() += 1;
        let session_id = authorized.record.session_id.clone();
        let guard = ActiveConnectionGuard {
            manager: self.clone(),
            session_id: session_id.clone(),
            connection_id: connection_id.clone(),
            role: authorized.record.role,
            user_id: authorized.record.user_id.clone(),
            target: authorized.target.clone(),
        };
        Some((connection_id, guard))
    }

    fn disconnect(
        &self,
        session_id: &str,
        connection_id: &str,
        role: ConnectionRole,
        user_id: &str,
        target: Option<&Target>,
    ) {
        let mut registry = match self.inner.lock() {
            Ok(registry) => registry,
            Err(_) => return,
        };
        let mut remove_room = false;
        let mut lease_to_end = None;
        let mut observer_disconnected = false;
        if let Some(room) = registry.rooms.get_mut(session_id) {
            match role {
                ConnectionRole::Host => {
                    if room
                        .host_connection
                        .as_ref()
                        .is_some_and(|connection| connection.id == connection_id)
                    {
                        remove_room = true;
                    }
                }
                ConnectionRole::Observer => {
                    if let Some(target) = target
                        && room
                            .observer_connections
                            .get(target)
                            .is_some_and(|connection| connection.id == connection_id)
                    {
                        room.observer_connections.remove(target);
                        observer_disconnected = true;
                    }
                }
                ConnectionRole::Controller => {
                    if room
                        .controller_lease
                        .as_ref()
                        .and_then(|lease| lease.connection.as_ref())
                        .is_some_and(|connection| connection.id == connection_id)
                    {
                        lease_to_end = room
                            .controller_lease
                            .as_ref()
                            .map(|lease| lease.lease_id.clone());
                    }
                }
            }
        }
        if let Some(lease_id) = lease_to_end.as_deref() {
            let _ = end_controller_lease_locked(
                &mut registry,
                session_id,
                Some(lease_id),
                "controller_disconnected",
                CloseSignal::ControlRevoked,
            );
        }
        if observer_disconnected && let Some(target) = target {
            revoke_controller_for_observer_disconnect(&mut registry, session_id, target);
        }
        if remove_room {
            close_room_locked(&mut registry, session_id);
        }
        registry.total_connections = registry.total_connections.saturating_sub(1);
        if let Some(count) = registry.connections_by_user.get_mut(user_id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                registry.connections_by_user.remove(user_id);
            }
        }
    }

    fn close_room(&self, session_id: &str) {
        if let Ok(mut registry) = self.inner.lock() {
            close_room_locked(&mut registry, session_id);
        }
    }

    fn route_frame(&self, session_id: &str, frame: &TerminalFrame) -> Result<(), ApiError> {
        let mut registry = self.inner.lock().map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get_mut(session_id)
            .ok_or_else(ApiError::not_found)?;
        validate_frame_context(room, frame)?;
        let target = Target {
            user_id: frame.recipient_user_id.clone(),
            device_id: frame.recipient_device_id.clone(),
        };
        let sequence_key = (target.clone(), frame.kind.clone());
        let expected_next = room
            .last_sequences
            .get(&sequence_key)
            .map(|sequence| sequence.checked_add(1))
            .unwrap_or(Some(frame.sequence));
        if expected_next != Some(frame.sequence)
            || frame.sequence == 0
            || frame.sequence > MAX_SAFE_SEQUENCE
        {
            return Err(ApiError::bad_request(
                "TERMINAL_FRAME_REPLAY",
                "terminal frame sequence is invalid",
            ));
        }
        let now = Utc::now().timestamp();
        if now != room.rate_window_started {
            room.rate_window_started = now;
            room.rate_frames = 0;
            room.rate_bytes = 0;
        }
        let frame_bytes = frame.ciphertext.len();
        if room.rate_frames >= MAX_SESSION_FRAMES_PER_SECOND
            || room.rate_bytes.saturating_add(frame_bytes) > MAX_SESSION_BYTES_PER_SECOND
            || room.total_bytes.saturating_add(frame_bytes) > MAX_SESSION_TOTAL_BYTES
        {
            return Err(ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "TERMINAL_FRAME_RATE_LIMITED",
                "terminal frame rate exceeded",
            ));
        }
        let unsigned = UnsignedFrame {
            format: &frame.format,
            session_id: &frame.session_id,
            vault_id: &frame.vault_id,
            membership_version: frame.membership_version,
            host_user_id: &frame.host_user_id,
            host_device_id: &frame.host_device_id,
            recipient_user_id: &frame.recipient_user_id,
            recipient_device_id: &frame.recipient_device_id,
            role: &frame.role,
            epoch: frame.epoch,
            sequence: frame.sequence,
            kind: &frame.kind,
            nonce: &frame.nonce,
            ciphertext: &frame.ciphertext,
        };
        let signature_payload = jcs(&unsigned)?;
        crate::auth::verify_key_signature(
            &room.host_signing_public_key,
            &frame.signature,
            &signature_payload,
        )?;
        let wrapped = serialize_frame_message(frame).map_err(ApiError::internal)?;
        if frame.kind == "resize" {
            room.latest_resize.insert(target.clone(), frame.clone());
        }
        room.last_sequences.insert(sequence_key, frame.sequence);
        room.rate_frames += 1;
        room.rate_bytes = room.rate_bytes.saturating_add(frame_bytes);
        room.total_bytes = room.total_bytes.saturating_add(frame_bytes);
        let mut observer_disconnected = false;
        if let Some(connection) = room.observer_connections.get(&target) {
            if connection.outbound.try_send(wrapped).is_err() {
                if let Some(slow) = room.observer_connections.remove(&target) {
                    let _ = slow.close.send(CloseSignal::SessionEnded);
                    observer_disconnected = true;
                }
            }
        }
        if observer_disconnected {
            revoke_controller_for_observer_disconnect(&mut registry, session_id, &target);
        }
        Ok(())
    }

    fn route_controller_frame_memory(
        &self,
        session_id: &str,
        target: &Target,
        frame: &TerminalInputFrame,
    ) -> ControllerFrameAuthorization {
        let Ok(mut registry) = self.inner.lock() else {
            return ControllerFrameAuthorization::PrincipalInvalid;
        };
        let Some(room) = registry.rooms.get_mut(session_id) else {
            return ControllerFrameAuthorization::LeaseInvalid;
        };
        if room.protocol_version != PROTOCOL_VERSION_V2 {
            return ControllerFrameAuthorization::LeaseInvalid;
        }
        let Some(lease) = room.controller_lease.as_mut() else {
            return ControllerFrameAuthorization::LeaseInvalid;
        };
        let ciphertext = canonical_base64(&frame.ciphertext, None);
        if lease.expires_epoch <= Utc::now().timestamp()
            || lease.controller != *target
            || frame.format != "atermius-terminal-input-frame-v2"
            || frame.session_id != room.session_id
            || frame.vault_id != room.vault_id
            || frame.membership_version != room.membership_version
            || frame.host_user_id != room.host_user_id
            || frame.host_device_id != room.host_device_id
            || frame.controller_user_id != target.user_id
            || frame.controller_device_id != target.device_id
            || frame.lease_id != lease.lease_id
            || frame.control_epoch != lease.control_epoch
            || frame.sequence == 0
            || frame.sequence > MAX_SAFE_SEQUENCE
            || lease.last_sequence.checked_add(1) != Some(frame.sequence)
            || canonical_base64(&frame.signature, Some(64)).is_none()
            || canonical_base64(&frame.nonce, Some(24)).is_none()
            || ciphertext.as_ref().is_none_or(|bytes| {
                bytes.len() < 16 || bytes.len() > MAX_CONTROLLER_CIPHERTEXT_BYTES
            })
        {
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason = "frame_validation"
            );
            return ControllerFrameAuthorization::FrameRejected;
        }
        let unsigned = UnsignedInputFrame {
            format: &frame.format,
            session_id: &frame.session_id,
            vault_id: &frame.vault_id,
            membership_version: frame.membership_version,
            host_user_id: &frame.host_user_id,
            host_device_id: &frame.host_device_id,
            controller_user_id: &frame.controller_user_id,
            controller_device_id: &frame.controller_device_id,
            lease_id: &frame.lease_id,
            control_epoch: frame.control_epoch,
            sequence: frame.sequence,
            nonce: &frame.nonce,
            ciphertext: &frame.ciphertext,
        };
        let Ok(signature_payload) = jcs(&unsigned) else {
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason = "signature_payload"
            );
            return ControllerFrameAuthorization::FrameRejected;
        };
        if crate::auth::verify_key_signature(
            &lease.signing_public_key,
            &frame.signature,
            &signature_payload,
        )
        .is_err()
        {
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason = "signature_validation"
            );
            return ControllerFrameAuthorization::FrameRejected;
        }
        let now = Utc::now().timestamp();
        if now != lease.rate_window_started {
            lease.rate_window_started = now;
            lease.rate_frames = 0;
            lease.rate_bytes = 0;
        }
        let frame_bytes = ciphertext.as_ref().map_or(0, Vec::len);
        if lease.rate_frames >= MAX_CONTROLLER_FRAMES_PER_SECOND
            || lease.rate_bytes.saturating_add(frame_bytes) > MAX_CONTROLLER_BYTES_PER_SECOND
        {
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason = "rate_limit"
            );
            return ControllerFrameAuthorization::FrameRejected;
        }
        let Some(host) = room.host_connection.as_ref() else {
            return ControllerFrameAuthorization::LeaseInvalid;
        };
        let Ok(wrapped) = serialize_input_message(frame) else {
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason = "serialization"
            );
            return ControllerFrameAuthorization::FrameRejected;
        };
        if let Err(error) = host.outbound.try_send(wrapped) {
            let reason = match error {
                tokio::sync::mpsc::error::TrySendError::Full(_) => "host_queue_full",
                tokio::sync::mpsc::error::TrySendError::Closed(_) => "host_queue_closed",
            };
            tracing::warn!(
                event = "terminal_controller_frame_rejected",
                reason,
                queue_capacity = HOST_INPUT_QUEUE_FRAMES
            );
            return ControllerFrameAuthorization::FrameRejected;
        }
        lease.last_sequence = frame.sequence;
        lease.rate_frames += 1;
        lease.rate_bytes = lease.rate_bytes.saturating_add(frame_bytes);
        ControllerFrameAuthorization::Forwarded
    }
}

fn end_controller_lease_locked(
    registry: &mut Registry,
    session_id: &str,
    expected_lease_id: Option<&str>,
    reason: &'static str,
    close_signal: CloseSignal,
) -> Option<ControllerLease> {
    let lease = {
        let room = registry.rooms.get_mut(session_id)?;
        if expected_lease_id.is_some_and(|expected| {
            room.controller_lease
                .as_ref()
                .is_none_or(|lease| lease.lease_id != expected)
        }) {
            return None;
        }
        room.controller_lease.take()?
    };
    registry.tickets.retain(|_, ticket| {
        ticket.session_id != session_id
            || ticket.control_lease_id.as_deref() != Some(lease.lease_id.as_str())
    });
    if let Some(room) = registry.rooms.get(session_id)
        && let Some(host) = room.host_connection.as_ref()
    {
        let event = json!({
            "type": "controller_lease_ended",
            "lease_id": lease.lease_id,
            "reason": reason,
        })
        .to_string();
        let _ = host.outbound.try_send(event);
    }
    if let Some(room) = registry.rooms.get(session_id)
        && room.protocol_version == PROTOCOL_VERSION_V2
        && let Some(observer) = room.observer_connections.get(&lease.controller)
    {
        let event = json!({
            "type": "controller_lease_ended",
            "lease_id": lease.lease_id,
            "reason": reason,
        })
        .to_string();
        let _ = observer.outbound.try_send(event);
    }
    if let Some(connection) = lease.connection.as_ref() {
        let _ = connection.close.send(close_signal);
    }
    Some(lease)
}

fn revoke_controller_for_observer_disconnect(
    registry: &mut Registry,
    session_id: &str,
    target: &Target,
) {
    let lease_id = registry
        .rooms
        .get(session_id)
        .and_then(|room| room.controller_lease.as_ref())
        .filter(|lease| lease.controller == *target)
        .map(|lease| lease.lease_id.clone());
    if let Some(lease_id) = lease_id {
        let _ = end_controller_lease_locked(
            registry,
            session_id,
            Some(&lease_id),
            "observer_disconnected",
            CloseSignal::ControlRevoked,
        );
    }
}

fn controller_granted_event(room: &Room, lease: &ControllerLease) -> String {
    json!({
        "type": "controller_lease_granted",
        "session_id": room.session_id,
        "lease_id": lease.lease_id,
        "control_epoch": lease.control_epoch,
        "expires_at": lease.expires_at,
    })
    .to_string()
}

fn serialize_frame_message(frame: &TerminalFrame) -> Result<String, serde_json::Error> {
    serde_json::to_string(&json!({
        "type": "frame",
        "frame": frame,
    }))
}

fn serialize_input_message(frame: &TerminalInputFrame) -> Result<String, serde_json::Error> {
    serde_json::to_string(&json!({
        "type": "input",
        "frame": frame,
    }))
}

fn close_room_locked(registry: &mut Registry, session_id: &str) {
    if let Some(room) = registry.rooms.remove(session_id) {
        if let Some(host) = room.host_connection {
            let _ = host.close.send(CloseSignal::SessionEnded);
        }
        for observer in room.observer_connections.into_values() {
            let _ = observer.close.send(CloseSignal::SessionEnded);
        }
        if let Some(connection) = room.controller_lease.and_then(|lease| lease.connection) {
            let _ = connection.close.send(CloseSignal::SessionEnded);
        }
    }
    registry
        .tickets
        .retain(|_, ticket| ticket.session_id != session_id);
}

fn prune_expired_rooms_locked(registry: &mut Registry, now: i64) {
    let expired = registry
        .rooms
        .iter()
        .filter(|(_, room)| room.expires_epoch <= now)
        .map(|(session_id, _)| session_id.clone())
        .collect::<Vec<_>>();
    for session_id in expired {
        close_room_locked(registry, &session_id);
    }
}

fn check_and_count_ticket(
    registry: &mut Registry,
    user_id: &str,
    now: i64,
) -> Result<(), ApiError> {
    registry
        .tickets_by_user
        .retain(|_, (window_start, _)| now.saturating_sub(*window_start) < 60);
    let entry = registry
        .tickets_by_user
        .entry(user_id.to_owned())
        .or_insert((now, 0));
    if now.saturating_sub(entry.0) >= 60 {
        *entry = (now, 0);
    }
    if entry.1 >= MAX_TICKETS_PER_USER_PER_MINUTE {
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "TERMINAL_TICKET_RATE_LIMITED",
            "terminal session ticket rate exceeded",
        ));
    }
    entry.1 += 1;
    Ok(())
}

fn random_ticket() -> String {
    let mut bytes = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn is_canonical_ticket(ticket: &str) -> bool {
    URL_SAFE_NO_PAD
        .decode(ticket)
        .is_ok_and(|bytes| bytes.len() == 32 && URL_SAFE_NO_PAD.encode(bytes) == ticket)
}

fn is_enabled(state: &AppState) -> bool {
    state.config.terminal_collaboration_enabled && state.config.public_origin.is_some()
}

fn require_enabled(state: &AppState) -> Result<(), ApiError> {
    if is_enabled(state) {
        Ok(())
    } else {
        Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "TERMINAL_COLLABORATION_DISABLED",
            "terminal collaboration is not enabled",
        ))
    }
}

fn collaboration_busy() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "TERMINAL_COLLABORATION_BUSY",
        "terminal collaboration capacity is temporarily full",
    )
}

fn canonical_base64(value: &str, expected: Option<usize>) -> Option<Vec<u8>> {
    let decoded = URL_SAFE_NO_PAD.decode(value).ok()?;
    if URL_SAFE_NO_PAD.encode(&decoded) != value
        || expected.is_some_and(|length| decoded.len() != length)
    {
        return None;
    }
    Some(decoded)
}

fn unsigned_keybox(keybox: &Keybox) -> UnsignedKeybox<'_> {
    UnsignedKeybox {
        format: &keybox.format,
        session_id: &keybox.session_id,
        vault_id: &keybox.vault_id,
        membership_version: keybox.membership_version,
        host_user_id: &keybox.host_user_id,
        host_device_id: &keybox.host_device_id,
        observer_user_id: &keybox.observer_user_id,
        observer_device_id: &keybox.observer_device_id,
        role: &keybox.role,
        epoch: keybox.epoch,
        expires_at: &keybox.expires_at,
        sealed_secret: &keybox.sealed_secret,
    }
}

fn unsigned_control_keybox(keybox: &ControlKeybox) -> UnsignedControlKeybox<'_> {
    UnsignedControlKeybox {
        format: &keybox.format,
        session_id: &keybox.session_id,
        vault_id: &keybox.vault_id,
        membership_version: keybox.membership_version,
        host_user_id: &keybox.host_user_id,
        host_device_id: &keybox.host_device_id,
        controller_user_id: &keybox.controller_user_id,
        controller_device_id: &keybox.controller_device_id,
        lease_id: &keybox.lease_id,
        control_epoch: keybox.control_epoch,
        purpose: &keybox.purpose,
        expires_at: &keybox.expires_at,
        sealed_secret: &keybox.sealed_secret,
    }
}

fn validate_controller_expiry(expires_at: &str, room_expiry: i64) -> Result<i64, ApiError> {
    let expiry = DateTime::parse_from_rfc3339(expires_at).map_err(|_| {
        ApiError::bad_request(
            "INVALID_TERMINAL_CONTROLLER_LEASE",
            "controller lease expiry must be a UTC RFC3339 timestamp",
        )
    })?;
    let now = Utc::now();
    if !expires_at.ends_with('Z')
        || expiry.offset().local_minus_utc() != 0
        || expiry.timestamp_subsec_nanos() != 0
        || expiry <= now
        || expiry.timestamp() <= now.timestamp()
        || expiry.timestamp() <= now.timestamp()
        || expiry > now + chrono::Duration::seconds(CONTROLLER_LEASE_TTL_SECONDS)
        || expiry.timestamp() > room_expiry
    {
        return Err(ApiError::bad_request(
            "INVALID_TERMINAL_CONTROLLER_LEASE",
            "controller lease expiry must be within five minutes and before session expiry",
        ));
    }
    Ok(expiry.timestamp())
}

fn validate_control_keybox(
    keybox: &ControlKeybox,
    request: &ControllerLeaseCreateRequest,
    room: &Room,
    host_signing_public_key: &str,
) -> Result<(), ApiError> {
    if keybox.format != "atermius-terminal-control-keybox-v2"
        || keybox.session_id != room.session_id
        || keybox.vault_id != room.vault_id
        || keybox.membership_version != room.membership_version
        || keybox.host_user_id != room.host_user_id
        || keybox.host_device_id != room.host_device_id
        || keybox.controller_user_id != request.controller_user_id
        || keybox.controller_device_id != request.controller_device_id
        || keybox.lease_id != request.lease_id
        || keybox.control_epoch != request.control_epoch
        || keybox.purpose != "input"
        || keybox.expires_at != request.expires_at
        || canonical_base64(&keybox.sealed_secret, Some(80)).is_none()
        || canonical_base64(&keybox.signature, Some(64)).is_none()
    {
        return Err(ApiError::invalid_envelope(
            "terminal controller keybox context or encoding is invalid",
        ));
    }
    crate::auth::verify_key_signature(
        host_signing_public_key,
        &keybox.signature,
        &jcs(&unsigned_control_keybox(keybox))?,
    )
}

fn validate_session_expiry(
    expires_at: &str,
) -> Result<(DateTime<chrono::FixedOffset>, i64), ApiError> {
    let expiry = DateTime::parse_from_rfc3339(expires_at).map_err(|_| {
        ApiError::bad_request(
            "INVALID_TERMINAL_SESSION_EXPIRY",
            "terminal session expiry must be a UTC RFC3339 timestamp",
        )
    })?;
    let now = Utc::now();
    if !expires_at.ends_with('Z')
        || expiry.offset().local_minus_utc() != 0
        || expiry <= now
        || expiry > now + chrono::Duration::seconds(SESSION_TTL_SECONDS)
    {
        return Err(ApiError::bad_request(
            "INVALID_TERMINAL_SESSION_EXPIRY",
            "terminal session expiry must be within 15 minutes",
        ));
    }
    Ok((expiry, expiry.timestamp()))
}

fn validate_keybox_context(
    keybox: &Keybox,
    vault_id: &str,
    session_id: &str,
    membership_version: i64,
    host: &AuthUser,
    target: &Target,
    expires_at: &str,
    signing_public_key: &str,
) -> Result<(), ApiError> {
    if keybox.format != "atermius-terminal-keybox-v1"
        || keybox.session_id != session_id
        || keybox.vault_id != vault_id
        || keybox.membership_version != membership_version
        || keybox.host_user_id != host.user_id
        || keybox.host_device_id != host.device_id
        || keybox.observer_user_id != target.user_id
        || keybox.observer_device_id != target.device_id
        || keybox.role != "observer"
        || keybox.epoch != 1
        || keybox.expires_at != expires_at
        || canonical_base64(&keybox.sealed_secret, Some(80)).is_none()
        || canonical_base64(&keybox.signature, Some(64)).is_none()
    {
        return Err(ApiError::invalid_envelope(
            "terminal keybox context or encoding is invalid",
        ));
    }
    crate::auth::verify_key_signature(
        signing_public_key,
        &keybox.signature,
        &jcs(&unsigned_keybox(keybox))?,
    )
}

/// Creates a host-owned room after serializing session/device/Vault membership
/// and keybox validation behind SQLite's writer lock. Neither keyboxes nor
/// terminal frames are written to the database or audit log.
pub(crate) async fn create_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Json(request): Json<CreateSessionRequest>,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    let host = current_user(&state, &headers).await?;
    if !crate::is_canonical_uuid(&vault_id)
        || !matches!(
            request.protocol_version,
            PROTOCOL_VERSION_V1 | PROTOCOL_VERSION_V2
        )
        || !crate::is_canonical_uuid(&request.session_id)
        || request.observers.is_empty()
        || request.observers.len() > MAX_OBSERVERS
    {
        return Err(ApiError::invalid_envelope(
            "terminal session request is invalid",
        ));
    }
    let (_, expires_epoch) = validate_session_expiry(&request.expires_at)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &host).await?;
    let session_expiry: String = sqlx::query_scalar(
        "SELECT access_expires_at FROM sessions WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL",
    )
    .bind(&host.session_id)
    .bind(&host.user_id)
    .bind(&host.device_id)
    .bind(&host.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    let session_expires_epoch = DateTime::parse_from_rfc3339(&session_expiry)
        .map_err(ApiError::internal)?
        .timestamp();
    let (_, _, membership_version, vault_state) =
        require_vault_read_tx(&mut tx, &host.user_id, &vault_id).await?;
    if vault_state != "active" {
        return Err(ApiError::vault_deletion_pending());
    }
    let signer: Option<(String, String)> = sqlx::query_as(
        "SELECT signing_public_key,status FROM devices WHERE device_id=? AND user_id=?",
    )
    .bind(&host.device_id)
    .bind(&host.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((signing_public_key, status)) = signer else {
        return Err(ApiError::unauthorized());
    };
    if status != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    let mut keyboxes = HashMap::new();
    for grant in &request.observers {
        let target = Target {
            user_id: grant.user_id.clone(),
            device_id: grant.device_id.clone(),
        };
        if !crate::is_canonical_uuid(&target.user_id)
            || !crate::is_canonical_uuid(&target.device_id)
            || target.device_id == host.device_id
            || keyboxes.contains_key(&target)
        {
            return Err(ApiError::invalid_envelope(
                "terminal observer target is invalid or duplicated",
            ));
        }
        let active: Option<i64> = sqlx::query_scalar(
            "SELECT 1 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id JOIN devices d ON d.user_id=u.user_id WHERE v.vault_id=? AND v.state='active' AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active' AND d.device_id=? AND d.status='active'",
        )
        .bind(&vault_id)
        .bind(&target.user_id)
        .bind(&target.device_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if active.is_none() {
            return Err(ApiError::forbidden(
                "TERMINAL_OBSERVER_NOT_AUTHORIZED",
                "observer device is not an active Vault member device",
            ));
        }
        let keybox = &grant.keybox;
        if keybox.session_id != request.session_id || keybox.expires_at != request.expires_at {
            return Err(ApiError::invalid_envelope(
                "terminal keybox does not match the requested session",
            ));
        }
        validate_keybox_context(
            keybox,
            &vault_id,
            &request.session_id,
            membership_version,
            &host,
            &target,
            &request.expires_at,
            &signing_public_key,
        )?;
        keyboxes.insert(target, keybox.clone());
    }
    let room = Room {
        session_id: request.session_id.clone(),
        vault_id,
        membership_version,
        host_user_id: host.user_id.clone(),
        host_device_id: host.device_id.clone(),
        host_signing_public_key: signing_public_key,
        protocol_version: request.protocol_version,
        expires_epoch,
        keyboxes,
        latest_resize: HashMap::new(),
        host_connection: None,
        observer_connections: HashMap::new(),
        control_epoch: 0,
        controller_lease: None,
        last_sequences: HashMap::new(),
        rate_window_started: Utc::now().timestamp(),
        rate_frames: 0,
        rate_bytes: 0,
        total_bytes: 0,
    };
    let host_ticket = state.collaboration.install_room_and_host_ticket(
        room,
        &host,
        &state.instance.generation,
        session_expires_epoch,
    )?;
    if let Err(error) = tx.commit().await {
        state.collaboration.close_room(&request.session_id);
        return Err(ApiError::internal(error));
    }
    let manager = state.collaboration.clone();
    let session_id = request.session_id.clone();
    tokio::spawn(async move {
        let delay = expires_epoch.saturating_sub(Utc::now().timestamp()).max(0) as u64;
        tokio::time::sleep(Duration::from_secs(delay)).await;
        manager.close_room(&session_id);
    });
    Ok(Json(json!({
        "session_id": request.session_id,
        "expires_at": request.expires_at,
        "host_ticket": host_ticket,
        "connect_path": "/collaboration/v1/connect",
    })))
}

/// Issues a one-use ticket only to an explicitly listed target device.
pub(crate) async fn issue_observer_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, session_id)): Path<(String, String)>,
    body: axum::body::Bytes,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    if !body.is_empty() {
        return Err(ApiError::bad_request(
            "TERMINAL_TICKET_BODY_NOT_ALLOWED",
            "observer ticket requests do not accept a body",
        ));
    }
    if !crate::is_canonical_uuid(&vault_id) || !crate::is_canonical_uuid(&session_id) {
        return Err(ApiError::not_found());
    }
    let user = current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &user).await?;
    let session_expiry: String = sqlx::query_scalar(
        "SELECT access_expires_at FROM sessions WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    let session_expires_epoch = DateTime::parse_from_rfc3339(&session_expiry)
        .map_err(ApiError::internal)?
        .timestamp();
    let (_, _, membership_version, vault_state) =
        require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    if vault_state != "active" {
        return Err(ApiError::not_found());
    }
    let active_device: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM users u JOIN devices d ON d.user_id=u.user_id WHERE u.user_id=? AND u.status='active' AND d.device_id=? AND d.status='active'",
    )
    .bind(&user.user_id)
    .bind(&user.device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if active_device.is_none() {
        return Err(ApiError::unauthorized());
    }
    let target = Target {
        user_id: user.user_id.clone(),
        device_id: user.device_id.clone(),
    };
    {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.vault_id != vault_id
            || room.membership_version != membership_version
            || room.expires_epoch <= Utc::now().timestamp()
            || !room.keyboxes.contains_key(&target)
        {
            return Err(ApiError::not_found());
        }
    }
    let (ticket, keybox, expires_at) = state.collaboration.issue_observer_ticket(
        &session_id,
        &user,
        &state.instance.generation,
        session_expires_epoch,
    )?;
    if let Err(error) = tx.commit().await {
        state.collaboration.cancel_ticket(&ticket);
        return Err(ApiError::internal(error));
    }
    Ok(Json(json!({
        "ticket": ticket,
        "role": "observer",
        "keybox": keybox,
        "ticket_expires_at": expires_at,
        "connect_path": "/collaboration/v1/connect",
    })))
}

/// Grants the exact approved observer device a short-lived input lease. The
/// lease and its signed control keybox remain process-memory-only.
pub(crate) async fn grant_controller_lease(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, session_id)): Path<(String, String)>,
    Json(request): Json<ControllerLeaseCreateRequest>,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    if !crate::is_canonical_uuid(&vault_id)
        || !crate::is_canonical_uuid(&session_id)
        || !crate::is_canonical_uuid(&request.controller_user_id)
        || !crate::is_canonical_uuid(&request.controller_device_id)
        || !crate::is_canonical_uuid(&request.lease_id)
        || request.control_epoch <= 0
    {
        return Err(ApiError::invalid_envelope(
            "terminal controller lease request is invalid",
        ));
    }
    let host = current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &host).await?;
    let (_, _, membership_version, vault_state) =
        require_vault_read_tx(&mut tx, &host.user_id, &vault_id).await?;
    if vault_state != "active" {
        return Err(ApiError::vault_deletion_pending());
    }
    let target = Target {
        user_id: request.controller_user_id.clone(),
        device_id: request.controller_device_id.clone(),
    };
    let controller_signing_public_key: Option<String> = sqlx::query_scalar(
        "SELECT d.signing_public_key FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id JOIN devices d ON d.user_id=u.user_id WHERE v.vault_id=? AND v.state='active' AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active' AND d.device_id=? AND d.status='active'",
    )
    .bind(&vault_id)
    .bind(&target.user_id)
    .bind(&target.device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let controller_signing_public_key = controller_signing_public_key.ok_or_else(|| {
        ApiError::forbidden(
            "TERMINAL_OBSERVER_NOT_AUTHORIZED",
            "controller device is not an active approved Vault member device",
        )
    })?;
    let host_signing_public_key: Option<String> = sqlx::query_scalar(
        "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&host.device_id)
    .bind(&host.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let host_signing_public_key = host_signing_public_key.ok_or_else(ApiError::unauthorized)?;
    let now = Utc::now().timestamp();
    let (room_expiry, cached_host_key) = {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.vault_id != vault_id
            || room.membership_version != membership_version
            || room.host_user_id != host.user_id
            || room.host_device_id != host.device_id
            || room.protocol_version != PROTOCOL_VERSION_V2
            || !room.keyboxes.contains_key(&target)
            || room.expires_epoch <= now
            || room.host_signing_public_key != host_signing_public_key
        {
            return Err(ApiError::not_found());
        }
        (room.expires_epoch, room.host_signing_public_key.clone())
    };
    let expires_epoch = validate_controller_expiry(&request.expires_at, room_expiry)?;
    {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        validate_control_keybox(&request.keybox, &request, room, &cached_host_key)?;
    }
    let lease = ControllerLease {
        controller: target,
        lease_id: request.lease_id.clone(),
        control_epoch: request.control_epoch,
        expires_at: request.expires_at.clone(),
        expires_epoch,
        keybox: request.keybox.clone(),
        signing_public_key: controller_signing_public_key,
        connection: None,
        last_sequence: 0,
        rate_window_started: now,
        rate_frames: 0,
        rate_bytes: 0,
    };
    let newly_granted = state
        .collaboration
        .grant_controller_lease(&session_id, lease)?;
    if let Err(error) = tx.commit().await {
        state.collaboration.close_room(&session_id);
        return Err(ApiError::internal(error));
    }
    if newly_granted {
        state
            .collaboration
            .notify_controller_granted(&session_id, &request.lease_id);
    }
    if newly_granted {
        let manager = state.collaboration.clone();
        let timer_session_id = session_id.clone();
        let timer_lease_id = request.lease_id.clone();
        tokio::spawn(async move {
            let delay = expires_epoch.saturating_sub(Utc::now().timestamp()).max(0) as u64;
            tokio::time::sleep(Duration::from_secs(delay)).await;
            manager.expire_controller_lease(&timer_session_id, &timer_lease_id);
        });
    }
    Ok(Json(json!({
        "lease_id": request.lease_id,
        "control_epoch": request.control_epoch,
        "expires_at": request.expires_at,
    })))
}

/// Issues a one-use controller input ticket to the exact device named by the
/// active lease. The existing observer socket remains the output channel.
pub(crate) async fn issue_controller_ticket(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, session_id)): Path<(String, String)>,
    body: axum::body::Bytes,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    if !body.is_empty() {
        return Err(ApiError::bad_request(
            "TERMINAL_TICKET_BODY_NOT_ALLOWED",
            "controller ticket requests do not accept a body",
        ));
    }
    if !crate::is_canonical_uuid(&vault_id) || !crate::is_canonical_uuid(&session_id) {
        return Err(ApiError::not_found());
    }
    let user = current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &user).await?;
    let session_expiry: String = sqlx::query_scalar(
        "SELECT access_expires_at FROM sessions WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    let session_expires_epoch = DateTime::parse_from_rfc3339(&session_expiry)
        .map_err(ApiError::internal)?
        .timestamp();
    let (_, _, membership_version, vault_state) =
        require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    if vault_state != "active" {
        return Err(ApiError::not_found());
    }
    {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        let target = Target {
            user_id: user.user_id.clone(),
            device_id: user.device_id.clone(),
        };
        if room.vault_id != vault_id
            || room.membership_version != membership_version
            || room.protocol_version != PROTOCOL_VERSION_V2
            || room.expires_epoch <= Utc::now().timestamp()
            || !room.keyboxes.contains_key(&target)
        {
            return Err(ApiError::not_found());
        }
    }
    let (ticket, lease, ticket_expires_at) = state.collaboration.issue_controller_ticket(
        &session_id,
        &user,
        &state.instance.generation,
        session_expires_epoch,
    )?;
    if let Err(error) = tx.commit().await {
        state.collaboration.cancel_ticket(&ticket);
        return Err(ApiError::internal(error));
    }
    Ok(Json(json!({
        "ticket": ticket,
        "role": "controller",
        "lease_id": lease.lease_id,
        "control_epoch": lease.control_epoch,
        "control_keybox": lease.keybox,
        "ticket_expires_at": ticket_expires_at,
        "connect_path": "/collaboration/v1/connect",
    })))
}

/// Revokes an active v2 lease without stopping its host SSH/session socket.
pub(crate) async fn revoke_controller_lease(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, session_id)): Path<(String, String)>,
    body: axum::body::Bytes,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    if !body.is_empty() {
        return Err(ApiError::bad_request(
            "TERMINAL_LEASE_BODY_NOT_ALLOWED",
            "controller lease revocation does not accept a body",
        ));
    }
    if !crate::is_canonical_uuid(&vault_id) || !crate::is_canonical_uuid(&session_id) {
        return Err(ApiError::not_found());
    }
    let host = current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &host).await?;
    let (_, _, _, vault_state) = require_vault_read_tx(&mut tx, &host.user_id, &vault_id).await?;
    if vault_state != "active" {
        return Err(ApiError::not_found());
    }
    {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.vault_id != vault_id
            || room.host_user_id != host.user_id
            || room.host_device_id != host.device_id
            || room.protocol_version != PROTOCOL_VERSION_V2
        {
            return Err(ApiError::not_found());
        }
    }
    state.collaboration.revoke_controller_lease(&session_id)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({ "status": "revoked" })))
}

/// Stops an in-memory session and signals every connected participant.
pub(crate) async fn stop_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, session_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_enabled(&state)?;
    let user = current_user(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_active_session_device_tx(&mut tx, &user).await?;
    require_vault_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    {
        let registry = state
            .collaboration
            .inner
            .lock()
            .map_err(ApiError::internal)?;
        let room = registry
            .rooms
            .get(&session_id)
            .ok_or_else(ApiError::not_found)?;
        if room.vault_id != vault_id
            || room.host_user_id != user.user_id
            || room.host_device_id != user.device_id
        {
            return Err(ApiError::not_found());
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;
    state.collaboration.close_room(&session_id);
    Ok(Json(json!({ "status": "stopped" })))
}

/// Upgrades only same-origin sockets. Credentials are accepted in the first
/// text frame and immediately consumed from the process-local hash map.
pub(crate) async fn connect(
    State(state): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    require_enabled(&state)?;
    let expected_origin = state.config.public_origin.as_deref().ok_or_else(|| {
        ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "TERMINAL_COLLABORATION_DISABLED",
            "terminal collaboration requires a configured public origin",
        )
    })?;
    if !is_origin_allowed(expected_origin, &headers) {
        return Err(ApiError::forbidden(
            "ORIGIN_DENIED",
            "websocket origin is not allowed",
        ));
    }
    let permit = state
        .notification_connection_slots
        .clone()
        .try_acquire_owned()
        .map_err(|_| collaboration_busy())?;
    let state = Arc::new(state);
    Ok(ws
        .max_message_size(MAX_WS_MESSAGE_BYTES)
        .max_frame_size(MAX_WS_MESSAGE_BYTES)
        .on_upgrade(move |socket| async move {
            collaboration_socket(socket, state, permit).await;
        }))
}

fn is_origin_allowed(expected: &str, headers: &HeaderMap) -> bool {
    let mut origins = headers.get_all(ORIGIN).iter();
    matches!((origins.next(), origins.next()), (Some(origin), None) if origin.to_str().ok() == Some(expected))
}

async fn collaboration_socket(
    mut socket: axum::extract::ws::WebSocket,
    state: Arc<AppState>,
    _permit: OwnedSemaphorePermit,
) {
    let ticket = match timeout(AUTH_TIMEOUT, socket.recv()).await {
        Ok(Some(Ok(axum::extract::ws::Message::Text(text))))
            if text.len() <= MAX_WS_MESSAGE_BYTES =>
        {
            match serde_json::from_str::<AuthenticateFrame>(&text) {
                Ok(frame) if frame.kind == "authenticate" && is_canonical_ticket(&frame.ticket) => {
                    frame.ticket
                }
                _ => {
                    send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
                    return;
                }
            }
        }
        _ => {
            send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
            return;
        }
    };
    let Some(authorized) = state
        .collaboration
        .consume_ticket_memory(&ticket, &state.instance.generation)
    else {
        send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
        return;
    };
    match revalidate_authorized(&state, &authorized).await {
        Revalidation::Valid => {}
        failure => {
            if failure.close_room(authorized.record.role) {
                state
                    .collaboration
                    .close_room(&authorized.record.session_id);
            } else if authorized.record.role == ConnectionRole::Controller
                && failure == Revalidation::ParticipantInvalid
                && let Some(lease_id) = authorized.record.control_lease_id.as_deref()
            {
                state.collaboration.end_controller_lease(
                    &authorized.record.session_id,
                    lease_id,
                    "controller_disconnected",
                    CloseSignal::ControlRevoked,
                );
            }
            send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
            return;
        }
    }
    let outbound_capacity = if authorized.record.role == ConnectionRole::Host {
        HOST_INPUT_QUEUE_FRAMES
    } else {
        OBSERVER_QUEUE_FRAMES
    };
    let (outbound_tx, mut outbound_rx) = mpsc::channel(outbound_capacity);
    let (close_tx, mut close_rx) = watch::channel(CloseSignal::None);
    let Some((_connection_id, _guard)) =
        state
            .collaboration
            .admit_connection(&authorized, outbound_tx, close_tx)
    else {
        send_close(&mut socket, 4008, "TERMINAL_COLLABORATION_BUSY").await;
        return;
    };
    let ack = if authorized.record.role == ConnectionRole::Controller {
        json!({
            "type": "authenticated",
            "role": "controller",
            "session_id": authorized.record.session_id,
            "lease_id": authorized.record.control_lease_id,
            "control_epoch": authorized.record.control_epoch,
        })
    } else {
        json!({
            "type": "authenticated",
            "role": authorized.record.role.as_str(),
            "session_id": authorized.record.session_id,
        })
    };
    if !send_json(&mut socket, &ack).await {
        return;
    }
    let initial_close_signal = *close_rx.borrow();
    if initial_close_signal != CloseSignal::None {
        // The room can close after the acknowledgement but before this task
        // enters its select loop. Preserve an explicit close frame in that
        // narrow window too.
        send_close_signal(&mut socket, initial_close_signal).await;
        return;
    }
    let mut recheck = interval(RECHECK_INTERVAL);
    recheck.set_missed_tick_behavior(MissedTickBehavior::Skip);
    recheck.tick().await;
    loop {
        tokio::select! {
            _ = close_rx.changed() => {
                let signal = *close_rx.borrow_and_update();
                send_close_signal(&mut socket, signal).await;
                break;
            }
            message = socket.recv() => {
                match message {
                    Some(Ok(axum::extract::ws::Message::Close(_frame))) => {
                        // Tungstenite queues an exact echo of the received
                        // frame while reading it. Flush that queued response
                        // before dropping the socket to complete the close
                        // handshake instead of sending a second Close frame.
                        let _ = timeout(SEND_TIMEOUT, socket.flush()).await;
                        break;
                    }
                    None | Some(Err(_)) => break,
                    Some(Ok(axum::extract::ws::Message::Ping(data))) => {
                        if timeout(SEND_TIMEOUT, socket.send(axum::extract::ws::Message::Pong(data))).await.is_err() { break; }
                    }
                    Some(Ok(axum::extract::ws::Message::Pong(_))) => {}
                    Some(Ok(axum::extract::ws::Message::Text(text)))
                        if authorized.record.role == ConnectionRole::Host =>
                    {
                        if text.len() > MAX_WS_MESSAGE_BYTES {
                            send_close(&mut socket, 1009, "MESSAGE_TOO_LARGE").await;
                            state.collaboration.close_room(&authorized.record.session_id);
                            break;
                        }
                        let Ok(application) = serde_json::from_str::<HostApplicationFrame>(&text) else {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            state.collaboration.close_room(&authorized.record.session_id);
                            break;
                        };
                        if application.kind != "frame"
                            || route_host_frame(&state, &authorized, &application.frame).await
                                != HostFrameAuthorization::Forwarded
                        {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            state.collaboration.close_room(&authorized.record.session_id);
                            break;
                        }
                    }
                    Some(Ok(axum::extract::ws::Message::Text(text)))
                        if authorized.record.role == ConnectionRole::Controller =>
                    {
                        if text.len() > MAX_WS_MESSAGE_BYTES {
                            send_close(&mut socket, 1009, "MESSAGE_TOO_LARGE").await;
                            break;
                        }
                        let Ok(application) = serde_json::from_str::<ControllerApplicationFrame>(&text) else {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            break;
                        };
                        if application.kind != "input" {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            break;
                        }
                        match route_controller_frame(&state, &authorized, &application.frame).await {
                            ControllerFrameAuthorization::Forwarded => {}
                            ControllerFrameAuthorization::PrincipalInvalid => {
                                send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
                                break;
                            }
                            ControllerFrameAuthorization::VaultMembershipChanged => {
                                state.collaboration.close_room(&authorized.record.session_id);
                                send_close(&mut socket, 1000, "SESSION_ENDED").await;
                                break;
                            }
                            ControllerFrameAuthorization::LeaseInvalid => {
                                state.collaboration.expire_controller_lease(
                                    &authorized.record.session_id,
                                    authorized.record.control_lease_id.as_deref().unwrap_or_default(),
                                );
                                send_close(&mut socket, 4003, "CONTROL_REVOKED").await;
                                break;
                            }
                            ControllerFrameAuthorization::FrameRejected => {
                                send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                                break;
                            }
                        }
                    }
                    Some(Ok(_)) => {
                        // Observer devices are strictly receive-only. Any application data is a protocol violation.
                        if authorized.record.role == ConnectionRole::Observer {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            break;
                        }
                        if authorized.record.role == ConnectionRole::Controller {
                            send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                            break;
                        }
                        send_close(&mut socket, 1008, "PROTOCOL_ERROR").await;
                        state.collaboration.close_room(&authorized.record.session_id);
                        break;
                    }
                }
            }
            outbound = outbound_rx.recv() => {
                let Some(json) = outbound else {
                    // Closing a room drops both the outbound sender and sets
                    // close_rx; either select branch may win the race.
                    let signal = *close_rx.borrow();
                    if signal == CloseSignal::None {
                        send_close(&mut socket, 1000, "SESSION_ENDED").await;
                    } else {
                        send_close_signal(&mut socket, signal).await;
                    }
                    break;
                };
                let signal = *close_rx.borrow();
                if signal != CloseSignal::None {
                    send_close_signal(&mut socket, signal).await;
                    break;
                }
                if timeout(SEND_TIMEOUT, socket.send(axum::extract::ws::Message::Text(json.into()))).await.is_err() {
                    break;
                }
            }
            _ = recheck.tick() => {
                if authorized.record.role == ConnectionRole::Controller
                    && let Some(lease_id) = authorized.record.control_lease_id.as_deref()
                {
                    state.collaboration.expire_controller_lease(
                        &authorized.record.session_id,
                        lease_id,
                    );
                }
                let revalidation = revalidate_connected_session(&state, &authorized).await;
                if revalidation != Revalidation::Valid {
                    match revalidation {
                        Revalidation::Valid => unreachable!("valid revalidation is handled above"),
                        Revalidation::ParticipantInvalid => {
                            if authorized.record.role == ConnectionRole::Host {
                                state.collaboration.close_room(&authorized.record.session_id);
                            }
                            send_close(&mut socket, 4001, "AUTH_REQUIRED").await;
                        }
                        Revalidation::VaultMembershipChanged => {
                            state.collaboration.close_room(&authorized.record.session_id);
                            send_close(&mut socket, 1000, "SESSION_ENDED").await;
                        }
                        Revalidation::ControllerLeaseInvalid => {
                            let signal = *close_rx.borrow();
                            if signal == CloseSignal::None {
                                send_close(&mut socket, 4003, "CONTROL_REVOKED").await;
                            } else {
                                send_close_signal(&mut socket, signal).await;
                            }
                        }
                    }
                    break;
                }
            }
        }
    }
}

async fn revalidate_authorized(state: &AppState, authorized: &AuthorizedTicket) -> Revalidation {
    let mut tx = match state.db.begin().await {
        Ok(tx) => tx,
        Err(_) => return Revalidation::ParticipantInvalid,
    };
    if require_active_session_device_tx(&mut tx, &auth_user_from_ticket(&authorized.record))
        .await
        .is_err()
    {
        return Revalidation::ParticipantInvalid;
    }
    let access_expiry: Option<String> = sqlx::query_scalar(
        "SELECT access_expires_at FROM sessions WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? AND revoked_at IS NULL",
    )
    .bind(&authorized.record.auth_session_id)
    .bind(&authorized.record.user_id)
    .bind(&authorized.record.device_id)
    .bind(&authorized.record.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .ok()
    .flatten();
    if access_expiry.is_none() {
        return Revalidation::ParticipantInvalid;
    }
    let revalidation = revalidate_vault_and_room(state, authorized, &mut tx).await;
    if tx.commit().await.is_err() {
        return Revalidation::ParticipantInvalid;
    }
    revalidation
}

/// Once the one-use WebSocket ticket has authenticated a connection, bind it
/// to its original login session and device instead of the bearer token hash.
/// Refresh rotates that hash but leaves the login session intact.
async fn revalidate_connected_session(
    state: &AppState,
    authorized: &AuthorizedTicket,
) -> Revalidation {
    let mut tx = match state.db.begin().await {
        Ok(tx) => tx,
        Err(_) => return Revalidation::ParticipantInvalid,
    };
    if require_active_collaboration_session_tx(
        &mut tx,
        &authorized.record.auth_session_id,
        &authorized.record.user_id,
        &authorized.record.device_id,
    )
    .await
    .is_err()
    {
        return Revalidation::ParticipantInvalid;
    }
    let revalidation = revalidate_vault_and_room(state, authorized, &mut tx).await;
    if tx.commit().await.is_err() {
        return Revalidation::ParticipantInvalid;
    }
    revalidation
}

async fn revalidate_vault_and_room(
    state: &AppState,
    authorized: &AuthorizedTicket,
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
) -> Revalidation {
    let Ok((_, _, membership_version, vault_state)) =
        require_vault_read_tx(tx, &authorized.record.user_id, &authorized.record.vault_id).await
    else {
        return Revalidation::VaultMembershipChanged;
    };
    if vault_state != "active" {
        return Revalidation::VaultMembershipChanged;
    }
    let room_revalidation = state
        .collaboration
        .inner
        .lock()
        .ok()
        .and_then(|registry| {
            registry
                .rooms
                .get(&authorized.record.session_id)
                .map(|room| {
                    if room.membership_version != membership_version
                        || room.vault_id != authorized.record.vault_id
                        || room.expires_epoch <= Utc::now().timestamp()
                    {
                        return Revalidation::VaultMembershipChanged;
                    }
                    match authorized.record.role {
                        ConnectionRole::Host
                            if room.host_user_id == authorized.record.user_id
                                && room.host_device_id == authorized.record.device_id =>
                        {
                            Revalidation::Valid
                        }
                        ConnectionRole::Observer
                            if authorized
                                .target
                                .as_ref()
                                .is_some_and(|target| room.keyboxes.contains_key(target)) =>
                        {
                            Revalidation::Valid
                        }
                        ConnectionRole::Controller => {
                            if authorized.target.as_ref().is_some_and(|target| {
                                room.protocol_version == PROTOCOL_VERSION_V2
                                    && room.controller_lease.as_ref().is_some_and(|lease| {
                                        lease.controller == *target
                                            && lease.expires_epoch > Utc::now().timestamp()
                                            && authorized.record.control_lease_id.as_deref()
                                                == Some(lease.lease_id.as_str())
                                            && authorized.record.control_epoch
                                                == Some(lease.control_epoch)
                                    })
                            }) {
                                Revalidation::Valid
                            } else {
                                Revalidation::ControllerLeaseInvalid
                            }
                        }
                        _ => Revalidation::VaultMembershipChanged,
                    }
                })
        })
        .unwrap_or(Revalidation::VaultMembershipChanged);
    room_revalidation
}

/// Linearizes each host frame with device/session and Vault membership writes.
/// The ciphertext is validated and queued synchronously while SQLite's writer
/// reservation is still held, so a concurrent revocation is ordered either
/// before the frame (which is rejected) or after its enqueue.
async fn route_host_frame(
    state: &AppState,
    authorized: &AuthorizedTicket,
    frame: &TerminalFrame,
) -> HostFrameAuthorization {
    let mut tx = match state.db.begin().await {
        Ok(tx) => tx,
        Err(_) => return HostFrameAuthorization::PrincipalInvalid,
    };
    if require_active_collaboration_session_tx(
        &mut tx,
        &authorized.record.auth_session_id,
        &authorized.record.user_id,
        &authorized.record.device_id,
    )
    .await
    .is_err()
    {
        return HostFrameAuthorization::PrincipalInvalid;
    }
    let membership = require_vault_read_tx(
        &mut tx,
        &authorized.record.user_id,
        &authorized.record.vault_id,
    )
    .await;
    let Ok((_, _, membership_version, vault_state)) = membership else {
        return HostFrameAuthorization::VaultMembershipChanged;
    };
    if vault_state != "active" {
        return HostFrameAuthorization::VaultMembershipChanged;
    }
    let room_is_current = state
        .collaboration
        .inner
        .lock()
        .ok()
        .and_then(|registry| {
            registry
                .rooms
                .get(&authorized.record.session_id)
                .map(|room| {
                    room.membership_version == membership_version
                        && room.host_user_id == authorized.record.user_id
                        && room.host_device_id == authorized.record.device_id
                        && room.expires_epoch > Utc::now().timestamp()
                })
        })
        .unwrap_or(false);
    if !room_is_current {
        return HostFrameAuthorization::VaultMembershipChanged;
    }
    if state
        .collaboration
        .route_frame(&authorized.record.session_id, frame)
        .is_err()
    {
        return HostFrameAuthorization::FrameRejected;
    }
    if tx.commit().await.is_err() {
        return HostFrameAuthorization::PrincipalInvalid;
    }
    HostFrameAuthorization::Forwarded
}

async fn route_controller_frame(
    state: &AppState,
    authorized: &AuthorizedTicket,
    frame: &TerminalInputFrame,
) -> ControllerFrameAuthorization {
    let mut tx = match state.db.begin().await {
        Ok(tx) => tx,
        Err(_) => return ControllerFrameAuthorization::PrincipalInvalid,
    };
    if require_active_collaboration_session_tx(
        &mut tx,
        &authorized.record.auth_session_id,
        &authorized.record.user_id,
        &authorized.record.device_id,
    )
    .await
    .is_err()
    {
        return ControllerFrameAuthorization::PrincipalInvalid;
    }
    let membership = require_vault_read_tx(
        &mut tx,
        &authorized.record.user_id,
        &authorized.record.vault_id,
    )
    .await;
    let Ok((_, _, membership_version, vault_state)) = membership else {
        return ControllerFrameAuthorization::VaultMembershipChanged;
    };
    if vault_state != "active" {
        return ControllerFrameAuthorization::VaultMembershipChanged;
    }
    let room_matches = state
        .collaboration
        .inner
        .lock()
        .ok()
        .and_then(|registry| {
            registry
                .rooms
                .get(&authorized.record.session_id)
                .map(|room| {
                    room.protocol_version == PROTOCOL_VERSION_V2
                        && room.membership_version == membership_version
                        && room.vault_id == authorized.record.vault_id
                        && room.expires_epoch > Utc::now().timestamp()
                        && room.controller_lease.as_ref().is_some_and(|lease| {
                            lease.controller.user_id == authorized.record.user_id
                                && lease.controller.device_id == authorized.record.device_id
                                && authorized.record.control_lease_id.as_deref()
                                    == Some(lease.lease_id.as_str())
                                && authorized.record.control_epoch == Some(lease.control_epoch)
                                && lease.expires_epoch > Utc::now().timestamp()
                        })
                })
        })
        .unwrap_or(false);
    if !room_matches {
        return ControllerFrameAuthorization::LeaseInvalid;
    }
    let target = Target {
        user_id: authorized.record.user_id.clone(),
        device_id: authorized.record.device_id.clone(),
    };
    let routed = state.collaboration.route_controller_frame_memory(
        &authorized.record.session_id,
        &target,
        frame,
    );
    if routed != ControllerFrameAuthorization::Forwarded {
        return routed;
    }
    if tx.commit().await.is_err() {
        return ControllerFrameAuthorization::PrincipalInvalid;
    }
    ControllerFrameAuthorization::Forwarded
}

fn auth_user_from_ticket(ticket: &TicketRecord) -> AuthUser {
    AuthUser {
        user_id: ticket.user_id.clone(),
        device_id: ticket.device_id.clone(),
        session_id: ticket.auth_session_id.clone(),
        access_hash: ticket.access_hash.clone(),
        declares_record_schema2: true,
        declares_sync_redaction_v1: true,
    }
}

fn validate_frame_context(room: &Room, frame: &TerminalFrame) -> Result<(), ApiError> {
    if frame.format != "atermius-terminal-frame-v1"
        || frame.session_id != room.session_id
        || frame.vault_id != room.vault_id
        || frame.membership_version != room.membership_version
        || frame.host_user_id != room.host_user_id
        || frame.host_device_id != room.host_device_id
        || frame.role != "observer"
        || frame.epoch != 1
        || !matches!(frame.kind.as_str(), "output" | "resize")
        || frame.sequence == 0
        || frame.sequence > MAX_SAFE_SEQUENCE
        || canonical_base64(&frame.signature, Some(64)).is_none()
        || canonical_base64(&frame.nonce, Some(24)).is_none()
        || canonical_base64(&frame.ciphertext, None)
            .is_none_or(|bytes| bytes.len() < 16 || bytes.len() > MAX_CIPHERTEXT_BYTES)
    {
        return Err(ApiError::invalid_envelope(
            "terminal frame context or size is invalid",
        ));
    }
    let recipient = Target {
        user_id: frame.recipient_user_id.clone(),
        device_id: frame.recipient_device_id.clone(),
    };
    if !room.keyboxes.contains_key(&recipient) {
        return Err(ApiError::forbidden(
            "TERMINAL_OBSERVER_NOT_AUTHORIZED",
            "terminal frame recipient is not approved",
        ));
    }
    Ok(())
}

async fn send_json(socket: &mut axum::extract::ws::WebSocket, value: &Value) -> bool {
    let Ok(encoded) = serde_json::to_string(value) else {
        return false;
    };
    timeout(
        SEND_TIMEOUT,
        socket.send(axum::extract::ws::Message::Text(encoded.into())),
    )
    .await
    .is_ok_and(|result| result.is_ok())
}

async fn send_close(socket: &mut axum::extract::ws::WebSocket, code: u16, reason: &str) {
    use axum::extract::ws::CloseFrame;
    let _ = timeout(
        SEND_TIMEOUT,
        socket.send(axum::extract::ws::Message::Close(Some(CloseFrame {
            code,
            reason: reason.into(),
        }))),
    )
    .await;
}

async fn send_close_signal(socket: &mut axum::extract::ws::WebSocket, signal: CloseSignal) {
    if let Some((code, reason)) = signal.frame() {
        send_close(socket, code, reason).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthRateLimits, BackupReplicationEnv, Config, open_state, secure_file};
    use axum::http::header::AUTHORIZATION;
    use chrono::SecondsFormat;
    use ed25519_dalek::Signer;
    use std::path::PathBuf;

    struct Identity {
        user_id: String,
        device_id: String,
        access_token: String,
        signing: ed25519_dalek::SigningKey,
    }

    struct Fixture {
        state: AppState,
        vault_id: String,
        host: Identity,
        observer: Identity,
        stranger: Identity,
    }

    fn test_config(data_dir: PathBuf, enabled: bool) -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            database_key_file: None,
            backup_retention_count: None,
            data_dir,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: enabled,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: Some("https://app.example.test".to_owned()),
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

    async fn fixture(enabled: bool) -> Fixture {
        let data_dir = std::env::temp_dir().join(format!("atermius-collab-{}", Uuid::new_v4()));
        secure_file::create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = open_state(&database, test_config(data_dir, enabled))
            .await
            .unwrap();
        let host = seed_identity(&state, "host").await;
        let observer = seed_identity(&state, "observer").await;
        let stranger = seed_identity(&state, "stranger").await;
        let vault_id = Uuid::new_v4().to_string();
        let now = Utc::now().to_rfc3339();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,membership_version,created_at) VALUES(?,?,5,?)")
            .bind(&vault_id)
            .bind(&host.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&host.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
            .bind(&vault_id)
            .bind(&observer.user_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        Fixture {
            state,
            vault_id,
            host,
            observer,
            stranger,
        }
    }

    async fn seed_identity(state: &AppState, label: &str) -> Identity {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access_token = format!("access-token-{}-{}", label, Uuid::new_v4());
        let signing = ed25519_dalek::SigningKey::from_bytes(&[label.as_bytes()[0]; 32]);
        let public_key = URL_SAFE_NO_PAD.encode(signing.verifying_key().to_bytes());
        let now = Utc::now();
        let created = now.to_rfc3339();
        let access_expiry = (now + chrono::Duration::minutes(10)).to_rfc3339();
        let refresh_expiry = (now + chrono::Duration::days(30)).to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{label}-{}@example.test", Uuid::new_v4()))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,'dGVzdA',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(label)
            .bind(&public_key)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(sha256_hex(access_token.as_bytes()))
            .bind(Uuid::new_v4().to_string())
            .bind(access_expiry)
            .bind(refresh_expiry)
            .bind(created)
            .execute(&state.db)
            .await
            .unwrap();
        Identity {
            user_id,
            device_id,
            access_token,
            signing,
        }
    }

    fn headers(identity: &Identity) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            AUTHORIZATION,
            format!("Bearer {}", identity.access_token).parse().unwrap(),
        );
        headers.insert("x-atermius-capability-marker", "v2".parse().unwrap());
        headers
    }

    fn make_request(fixture: &Fixture) -> (String, CreateSessionRequest, Keybox) {
        let session_id = Uuid::new_v4().to_string();
        let expires_at =
            (Utc::now() + chrono::Duration::minutes(5)).to_rfc3339_opts(SecondsFormat::Secs, true);
        let target = Target {
            user_id: fixture.observer.user_id.clone(),
            device_id: fixture.observer.device_id.clone(),
        };
        let mut keybox = Keybox {
            format: "atermius-terminal-keybox-v1".to_owned(),
            session_id: session_id.clone(),
            vault_id: fixture.vault_id.clone(),
            membership_version: 5,
            host_user_id: fixture.host.user_id.clone(),
            host_device_id: fixture.host.device_id.clone(),
            observer_user_id: target.user_id.clone(),
            observer_device_id: target.device_id.clone(),
            role: "observer".to_owned(),
            epoch: 1,
            expires_at: expires_at.clone(),
            sealed_secret: URL_SAFE_NO_PAD.encode([0x5a; 80]),
            signature: String::new(),
        };
        let signature = fixture
            .host
            .signing
            .sign(&jcs(&unsigned_keybox(&keybox)).unwrap());
        keybox.signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
        (
            session_id.clone(),
            CreateSessionRequest {
                protocol_version: 1,
                session_id,
                expires_at,
                observers: vec![ObserverGrant {
                    user_id: target.user_id,
                    device_id: target.device_id,
                    keybox: keybox.clone(),
                }],
            },
            keybox,
        )
    }

    async fn create(fixture: &Fixture, request: CreateSessionRequest) -> Result<Value, ApiError> {
        create_session(
            State(fixture.state.clone()),
            headers(&fixture.host),
            Path(fixture.vault_id.clone()),
            Json(request),
        )
        .await
        .map(|Json(value)| value)
    }

    async fn close_fixture(fixture: Fixture) {
        let directory = fixture.state.config.data_dir.clone();
        fixture.state.db.close().await;
        let _ = tokio::fs::remove_dir_all(directory).await;
    }

    #[tokio::test]
    async fn feature_is_opt_in_and_requires_public_origin() {
        let mut fixture = fixture(false).await;
        let (_, request, _) = make_request(&fixture);
        let error = create(&fixture, request).await.unwrap_err();
        assert_eq!(error.body.code, "TERMINAL_COLLABORATION_DISABLED");
        fixture.state.config = Arc::new(Config {
            public_origin: None,
            terminal_collaboration_enabled: true,
            ..(*fixture.state.config).clone()
        });
        let (_, request, _) = make_request(&fixture);
        let error = create(&fixture, request).await.unwrap_err();
        assert_eq!(error.body.code, "TERMINAL_COLLABORATION_DISABLED");
        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn create_verifies_explicit_active_device_grant_and_signature() {
        let fixture = fixture(true).await;
        let (session_id, request, _) = make_request(&fixture);
        let response = create(&fixture, request).await.unwrap();
        assert_eq!(response["session_id"], session_id);
        assert_eq!(response["connect_path"], "/collaboration/v1/connect");
        assert_eq!(response["host_ticket"].as_str().unwrap().len(), 43);

        let (_, mut forged, _) = make_request(&fixture);
        forged.observers[0].keybox.sealed_secret = URL_SAFE_NO_PAD.encode([0x11; 80]);
        let error = create(&fixture, forged).await.unwrap_err();
        assert_eq!(error.body.code, "INVALID_ENVELOPE");

        let (_, mut nonmember, _) = make_request(&fixture);
        nonmember.observers[0].user_id = fixture.stranger.user_id.clone();
        nonmember.observers[0].keybox.observer_user_id = fixture.stranger.user_id.clone();
        let unsigned = unsigned_keybox(&nonmember.observers[0].keybox);
        nonmember.observers[0].keybox.signature = URL_SAFE_NO_PAD.encode(
            fixture
                .host
                .signing
                .sign(&jcs(&unsigned).unwrap())
                .to_bytes(),
        );
        let error = create(&fixture, nonmember).await.unwrap_err();
        assert_eq!(error.body.code, "TERMINAL_OBSERVER_NOT_AUTHORIZED");

        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn active_socket_survives_access_hash_rotation_and_host_frames_remain_valid() {
        let fixture = fixture(true).await;
        let (session_id, request, _) = make_request(&fixture);
        let response = create(&fixture, request).await.unwrap();
        let host_ticket = response["host_ticket"].as_str().unwrap();
        let authorized = fixture
            .state
            .collaboration
            .consume_ticket_memory(host_ticket, &fixture.state.instance.generation)
            .unwrap();
        assert_eq!(
            revalidate_authorized(&fixture.state, &authorized).await,
            Revalidation::Valid,
            "ticket authentication must still use its original access token"
        );
        let (outbound, _outbound_rx) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (close, _close_rx) = watch::channel(CloseSignal::None);
        let (_, guard) = fixture
            .state
            .collaboration
            .admit_connection(&authorized, outbound, close)
            .unwrap();

        let rotated_access_hash = sha256_hex(b"refreshed access token hash");
        sqlx::query("UPDATE sessions SET access_hash=? WHERE session_id=?")
            .bind(&rotated_access_hash)
            .bind(&authorized.record.auth_session_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();

        assert_eq!(
            revalidate_authorized(&fixture.state, &authorized).await,
            Revalidation::ParticipantInvalid,
            "a newly consumed ticket must remain bound to its issued access hash"
        );
        assert_eq!(
            revalidate_connected_session(&fixture.state, &authorized).await,
            Revalidation::Valid,
            "an admitted socket is bound to the same active login session, not its rotated access hash"
        );

        let target = Target {
            user_id: fixture.observer.user_id.clone(),
            device_id: fixture.observer.device_id.clone(),
        };
        let mut frame = sample_frame(&fixture.host.signing, &target, 1, &[0x55; 32]);
        frame.session_id = session_id.clone();
        frame.vault_id = fixture.vault_id.clone();
        frame.membership_version = 5;
        frame.host_user_id = fixture.host.user_id.clone();
        frame.host_device_id = fixture.host.device_id.clone();
        sign_frame(&fixture.host.signing, &mut frame);
        assert_eq!(
            route_host_frame(&fixture.state, &authorized, &frame).await,
            HostFrameAuthorization::Forwarded,
            "host frame authorization must use the same identity-bound session check"
        );

        let observer_ticket_response = issue_observer_ticket(
            State(fixture.state.clone()),
            headers(&fixture.observer),
            Path((fixture.vault_id.clone(), session_id)),
            axum::body::Bytes::new(),
        )
        .await
        .unwrap()
        .0;
        let observer_authorized = fixture
            .state
            .collaboration
            .consume_ticket_memory(
                observer_ticket_response["ticket"].as_str().unwrap(),
                &fixture.state.instance.generation,
            )
            .unwrap();
        assert_eq!(
            revalidate_authorized(&fixture.state, &observer_authorized).await,
            Revalidation::Valid
        );
        let (observer_outbound, _observer_outbound_rx) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (observer_close, _observer_close_rx) = watch::channel(CloseSignal::None);
        let (_, observer_guard) = fixture
            .state
            .collaboration
            .admit_connection(&observer_authorized, observer_outbound, observer_close)
            .unwrap();
        let rotated_observer_access_hash = sha256_hex(b"refreshed observer access token hash");
        sqlx::query("UPDATE sessions SET access_hash=? WHERE session_id=?")
            .bind(rotated_observer_access_hash)
            .bind(&observer_authorized.record.auth_session_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();
        assert_eq!(
            revalidate_connected_session(&fixture.state, &observer_authorized).await,
            Revalidation::Valid,
            "an approved observer socket must also survive access-token rotation"
        );

        drop(observer_guard);
        drop(guard);
        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn active_socket_revalidation_fails_closed_for_revoked_or_expired_identity() {
        for invalidation in [
            "revoked",
            "refresh_expired",
            "account_inactive",
            "device_revoked",
        ] {
            let fixture = fixture(true).await;
            let (_, request, _) = make_request(&fixture);
            let response = create(&fixture, request).await.unwrap();
            let authorized = fixture
                .state
                .collaboration
                .consume_ticket_memory(
                    response["host_ticket"].as_str().unwrap(),
                    &fixture.state.instance.generation,
                )
                .unwrap();
            assert_eq!(
                revalidate_authorized(&fixture.state, &authorized).await,
                Revalidation::Valid
            );

            match invalidation {
                "revoked" => {
                    sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
                        .bind(Utc::now().to_rfc3339())
                        .bind(&authorized.record.auth_session_id)
                        .execute(&fixture.state.db)
                        .await
                        .unwrap();
                }
                "refresh_expired" => {
                    let expired = (Utc::now() - chrono::Duration::seconds(1)).to_rfc3339();
                    sqlx::query("UPDATE sessions SET refresh_expires_at=? WHERE session_id=?")
                        .bind(expired)
                        .bind(&authorized.record.auth_session_id)
                        .execute(&fixture.state.db)
                        .await
                        .unwrap();
                }
                "account_inactive" => {
                    sqlx::query("UPDATE users SET status='disabled' WHERE user_id=?")
                        .bind(&authorized.record.user_id)
                        .execute(&fixture.state.db)
                        .await
                        .unwrap();
                }
                "device_revoked" => {
                    sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
                        .bind(&authorized.record.device_id)
                        .execute(&fixture.state.db)
                        .await
                        .unwrap();
                }
                _ => unreachable!(),
            }

            assert_eq!(
                revalidate_connected_session(&fixture.state, &authorized).await,
                Revalidation::ParticipantInvalid,
                "live socket must close after {invalidation}"
            );
            close_fixture(fixture).await;
        }
    }

    #[tokio::test]
    async fn keyboxes_and_tickets_are_ephemeral_and_audit_silent() {
        let fixture = fixture(true).await;
        let before_audits: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events")
            .fetch_one(&fixture.state.db)
            .await
            .unwrap();
        let (_, request, keybox) = make_request(&fixture);
        let response = create(&fixture, request).await.unwrap();
        let session_id = response["session_id"].as_str().unwrap();
        let host_ticket = response["host_ticket"].as_str().unwrap();
        assert!(is_canonical_ticket(host_ticket));
        let after_audits: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events")
            .fetch_one(&fixture.state.db)
            .await
            .unwrap();
        assert_eq!(before_audits, after_audits);
        let collaboration_tables: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name LIKE '%terminal%'",
        )
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(collaboration_tables, 0);

        let ticket_response = issue_observer_ticket(
            State(fixture.state.clone()),
            headers(&fixture.observer),
            Path((fixture.vault_id.clone(), session_id.to_owned())),
            axum::body::Bytes::new(),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(ticket_response["role"], "observer");
        assert_eq!(
            ticket_response["keybox"],
            serde_json::to_value(keybox).unwrap()
        );
        assert!(ticket_response["ticket_expires_at"].is_string());
        assert!(ticket_response.get("expires_at").is_none());
        let observer_ticket = ticket_response["ticket"].as_str().unwrap();
        assert!(
            fixture
                .state
                .collaboration
                .consume_ticket_memory(observer_ticket, &fixture.state.instance.generation)
                .is_some()
        );
        assert!(
            fixture
                .state
                .collaboration
                .consume_ticket_memory(observer_ticket, &fixture.state.instance.generation)
                .is_none()
        );
        assert!(
            fixture
                .state
                .collaboration
                .consume_ticket_memory(host_ticket, &fixture.state.instance.generation)
                .is_some()
        );
        assert!(
            fixture
                .state
                .collaboration
                .consume_ticket_memory(host_ticket, &fixture.state.instance.generation)
                .is_none()
        );

        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn vault_membership_change_rejects_ticket_and_ends_room() {
        let fixture = fixture(true).await;
        let (session_id, request, _) = make_request(&fixture);
        create(&fixture, request).await.unwrap();
        let ticket_response = issue_observer_ticket(
            State(fixture.state.clone()),
            headers(&fixture.observer),
            Path((fixture.vault_id.clone(), session_id.clone())),
            axum::body::Bytes::new(),
        )
        .await
        .unwrap()
        .0;
        let ticket = ticket_response["ticket"].as_str().unwrap().to_owned();
        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
            .bind(&fixture.vault_id)
            .bind(&fixture.observer.user_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE vaults SET membership_version=membership_version+1 WHERE vault_id=?")
            .bind(&fixture.vault_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();
        let authorized = fixture
            .state
            .collaboration
            .consume_ticket_memory(&ticket, &fixture.state.instance.generation)
            .unwrap();
        let state = revalidate_authorized(&fixture.state, &authorized).await;
        assert_eq!(state, Revalidation::VaultMembershipChanged);
        if state.close_room(authorized.record.role) {
            fixture
                .state
                .collaboration
                .close_room(&authorized.record.session_id);
        }
        assert!(
            !fixture
                .state
                .collaboration
                .inner
                .lock()
                .unwrap()
                .rooms
                .contains_key(&session_id)
        );
        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn revoked_observer_session_cannot_end_host_room() {
        let fixture = fixture(true).await;
        let (session_id, request, _) = make_request(&fixture);
        create(&fixture, request).await.unwrap();
        let response = issue_observer_ticket(
            State(fixture.state.clone()),
            headers(&fixture.observer),
            Path((fixture.vault_id.clone(), session_id.clone())),
            axum::body::Bytes::new(),
        )
        .await
        .unwrap()
        .0;
        let ticket = response["ticket"].as_str().unwrap().to_owned();
        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
            .bind(&fixture.observer.device_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();
        let authorized = fixture
            .state
            .collaboration
            .consume_ticket_memory(&ticket, &fixture.state.instance.generation)
            .unwrap();
        let failure = revalidate_authorized(&fixture.state, &authorized).await;
        assert_eq!(failure, Revalidation::ParticipantInvalid);
        assert!(!failure.close_room(ConnectionRole::Observer));
        assert!(
            fixture
                .state
                .collaboration
                .inner
                .lock()
                .unwrap()
                .rooms
                .contains_key(&session_id)
        );
        close_fixture(fixture).await;
    }

    #[tokio::test]
    async fn host_disconnect_removes_room_and_all_pending_tickets() {
        let fixture = fixture(true).await;
        let (session_id, request, _) = make_request(&fixture);
        let response = create(&fixture, request).await.unwrap();
        let host_ticket = response["host_ticket"].as_str().unwrap();
        let authorized = fixture
            .state
            .collaboration
            .consume_ticket_memory(host_ticket, &fixture.state.instance.generation)
            .unwrap();
        assert_eq!(
            revalidate_authorized(&fixture.state, &authorized).await,
            Revalidation::Valid
        );
        let (outbound, _receiver) = mpsc::channel(1);
        let (close, _close_receiver) = watch::channel(CloseSignal::None);
        let (_, guard) = fixture
            .state
            .collaboration
            .admit_connection(&authorized, outbound, close)
            .unwrap();
        assert!(
            fixture
                .state
                .collaboration
                .inner
                .lock()
                .unwrap()
                .rooms
                .contains_key(&session_id)
        );
        drop(guard);
        let registry = fixture.state.collaboration.inner.lock().unwrap();
        assert!(!registry.rooms.contains_key(&session_id));
        assert!(
            !registry
                .tickets
                .values()
                .any(|ticket| ticket.session_id == session_id)
        );
        drop(registry);
        close_fixture(fixture).await;
    }

    fn sample_keybox(target: &Target) -> Keybox {
        Keybox {
            format: "atermius-terminal-keybox-v1".to_owned(),
            session_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            vault_id: "00000000-0000-4000-8000-000000000002".to_owned(),
            membership_version: 5,
            host_user_id: "00000000-0000-4000-8000-000000000003".to_owned(),
            host_device_id: "00000000-0000-4000-8000-000000000004".to_owned(),
            observer_user_id: target.user_id.clone(),
            observer_device_id: target.device_id.clone(),
            role: "observer".to_owned(),
            epoch: 1,
            expires_at: (Utc::now() + chrono::Duration::minutes(5)).to_rfc3339(),
            sealed_secret: URL_SAFE_NO_PAD.encode([0; 80]),
            signature: URL_SAFE_NO_PAD.encode([0; 64]),
        }
    }

    fn sample_frame(
        signing: &ed25519_dalek::SigningKey,
        target: &Target,
        sequence: u64,
        ciphertext: &[u8],
    ) -> TerminalFrame {
        let mut frame = TerminalFrame {
            format: "atermius-terminal-frame-v1".to_owned(),
            session_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            vault_id: "00000000-0000-4000-8000-000000000002".to_owned(),
            membership_version: 5,
            host_user_id: "00000000-0000-4000-8000-000000000003".to_owned(),
            host_device_id: "00000000-0000-4000-8000-000000000004".to_owned(),
            recipient_user_id: target.user_id.clone(),
            recipient_device_id: target.device_id.clone(),
            role: "observer".to_owned(),
            epoch: 1,
            sequence,
            kind: "output".to_owned(),
            nonce: URL_SAFE_NO_PAD.encode([0x24; 24]),
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext),
            signature: String::new(),
        };
        sign_frame(signing, &mut frame);
        frame
    }

    fn sign_frame(signing: &ed25519_dalek::SigningKey, frame: &mut TerminalFrame) {
        let unsigned = UnsignedFrame {
            format: &frame.format,
            session_id: &frame.session_id,
            vault_id: &frame.vault_id,
            membership_version: frame.membership_version,
            host_user_id: &frame.host_user_id,
            host_device_id: &frame.host_device_id,
            recipient_user_id: &frame.recipient_user_id,
            recipient_device_id: &frame.recipient_device_id,
            role: &frame.role,
            epoch: frame.epoch,
            sequence: frame.sequence,
            kind: &frame.kind,
            nonce: &frame.nonce,
            ciphertext: &frame.ciphertext,
        };
        frame.signature = URL_SAFE_NO_PAD.encode(signing.sign(&jcs(&unsigned).unwrap()).to_bytes());
    }

    fn sample_room(signing: &ed25519_dalek::SigningKey, target: &Target) -> Room {
        let mut keyboxes = HashMap::new();
        keyboxes.insert(target.clone(), sample_keybox(target));
        Room {
            session_id: "00000000-0000-4000-8000-000000000001".to_owned(),
            vault_id: "00000000-0000-4000-8000-000000000002".to_owned(),
            membership_version: 5,
            host_user_id: "00000000-0000-4000-8000-000000000003".to_owned(),
            host_device_id: "00000000-0000-4000-8000-000000000004".to_owned(),
            host_signing_public_key: URL_SAFE_NO_PAD.encode(signing.verifying_key().to_bytes()),
            protocol_version: PROTOCOL_VERSION_V1,
            expires_epoch: Utc::now().timestamp() + 60,
            keyboxes,
            latest_resize: HashMap::new(),
            host_connection: None,
            observer_connections: HashMap::new(),
            control_epoch: 0,
            controller_lease: None,
            last_sequences: HashMap::new(),
            rate_window_started: Utc::now().timestamp(),
            rate_frames: 0,
            rate_bytes: 0,
            total_bytes: 0,
        }
    }

    fn sample_input_frame(
        signing: &ed25519_dalek::SigningKey,
        room: &Room,
        target: &Target,
        lease_id: &str,
        control_epoch: i64,
        sequence: u64,
        ciphertext_bytes: &[u8],
    ) -> TerminalInputFrame {
        let mut frame = TerminalInputFrame {
            format: "atermius-terminal-input-frame-v2".to_owned(),
            session_id: room.session_id.clone(),
            vault_id: room.vault_id.clone(),
            membership_version: room.membership_version,
            host_user_id: room.host_user_id.clone(),
            host_device_id: room.host_device_id.clone(),
            controller_user_id: target.user_id.clone(),
            controller_device_id: target.device_id.clone(),
            lease_id: lease_id.to_owned(),
            control_epoch,
            sequence,
            nonce: URL_SAFE_NO_PAD.encode([0x44; 24]),
            ciphertext: URL_SAFE_NO_PAD.encode(ciphertext_bytes),
            signature: String::new(),
        };
        let unsigned = UnsignedInputFrame {
            format: &frame.format,
            session_id: &frame.session_id,
            vault_id: &frame.vault_id,
            membership_version: frame.membership_version,
            host_user_id: &frame.host_user_id,
            host_device_id: &frame.host_device_id,
            controller_user_id: &frame.controller_user_id,
            controller_device_id: &frame.controller_device_id,
            lease_id: &frame.lease_id,
            control_epoch: frame.control_epoch,
            sequence: frame.sequence,
            nonce: &frame.nonce,
            ciphertext: &frame.ciphertext,
        };
        frame.signature = URL_SAFE_NO_PAD.encode(signing.sign(&jcs(&unsigned).unwrap()).to_bytes());
        frame
    }

    #[tokio::test]
    async fn controller_input_checks_signature_sequence_size_and_forwards_opaque_ciphertext() {
        let host_signing = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let controller_signing = ed25519_dalek::SigningKey::from_bytes(&[0x55; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let mut room = sample_room(&host_signing, &target);
        room.protocol_version = PROTOCOL_VERSION_V2;
        room.control_epoch = 1;
        let lease_id = "00000000-0000-4000-8000-000000000007".to_owned();
        let (host_outbound, mut host_received) = mpsc::channel(4);
        room.host_connection = Some(ConnectionRef {
            id: "host-controller-test".to_owned(),
            outbound: host_outbound,
            close: watch::channel(CloseSignal::None).0,
        });
        room.controller_lease = Some(ControllerLease {
            controller: target.clone(),
            lease_id: lease_id.clone(),
            control_epoch: 1,
            expires_at: (Utc::now() + chrono::Duration::seconds(60)).to_rfc3339(),
            expires_epoch: Utc::now().timestamp() + 60,
            keybox: ControlKeybox {
                format: "atermius-terminal-control-keybox-v2".to_owned(),
                session_id: room.session_id.clone(),
                vault_id: room.vault_id.clone(),
                membership_version: room.membership_version,
                host_user_id: room.host_user_id.clone(),
                host_device_id: room.host_device_id.clone(),
                controller_user_id: target.user_id.clone(),
                controller_device_id: target.device_id.clone(),
                lease_id: lease_id.clone(),
                control_epoch: 1,
                purpose: "input".to_owned(),
                expires_at: (Utc::now() + chrono::Duration::seconds(60)).to_rfc3339(),
                sealed_secret: URL_SAFE_NO_PAD.encode([0x5a; 80]),
                signature: URL_SAFE_NO_PAD.encode([0x6a; 64]),
            },
            signing_public_key: URL_SAFE_NO_PAD
                .encode(controller_signing.verifying_key().to_bytes()),
            connection: None,
            last_sequence: 0,
            rate_window_started: Utc::now().timestamp(),
            rate_frames: 0,
            rate_bytes: 0,
        });
        let room_id = room.session_id.clone();
        let manager = CollaborationState::default();
        manager
            .inner
            .lock()
            .unwrap()
            .rooms
            .insert(room_id.clone(), room);

        let initial = {
            let registry = manager.inner.lock().unwrap();
            sample_input_frame(
                &controller_signing,
                registry.rooms.get(&room_id).unwrap(),
                &target,
                &lease_id,
                1,
                1,
                &[0xa1; 16],
            )
        };
        assert_eq!(
            manager.route_controller_frame_memory(&room_id, &target, &initial),
            ControllerFrameAuthorization::Forwarded
        );
        let forwarded: Value = serde_json::from_str(&host_received.recv().await.unwrap()).unwrap();
        assert_eq!(forwarded["frame"]["ciphertext"], initial.ciphertext);
        assert_eq!(forwarded["frame"]["nonce"], initial.nonce);
        assert_eq!(
            manager.route_controller_frame_memory(&room_id, &target, &initial),
            ControllerFrameAuthorization::FrameRejected,
            "replayed input sequence is rejected"
        );

        let max_sized = {
            let registry = manager.inner.lock().unwrap();
            sample_input_frame(
                &controller_signing,
                registry.rooms.get(&room_id).unwrap(),
                &target,
                &lease_id,
                1,
                2,
                &vec![0xb2; MAX_CONTROLLER_CIPHERTEXT_BYTES],
            )
        };
        assert_eq!(
            manager.route_controller_frame_memory(&room_id, &target, &max_sized),
            ControllerFrameAuthorization::Forwarded,
            "the 8 KiB plaintext plus tag ceiling is accepted"
        );
        let _ = host_received.recv().await.unwrap();

        let oversized = {
            let registry = manager.inner.lock().unwrap();
            sample_input_frame(
                &controller_signing,
                registry.rooms.get(&room_id).unwrap(),
                &target,
                &lease_id,
                1,
                3,
                &vec![0xc3; MAX_CONTROLLER_CIPHERTEXT_BYTES + 1],
            )
        };
        assert_eq!(
            manager.route_controller_frame_memory(&room_id, &target, &oversized),
            ControllerFrameAuthorization::FrameRejected,
            "ciphertext over the per-frame limit is rejected"
        );
        let mut forged = {
            let registry = manager.inner.lock().unwrap();
            sample_input_frame(
                &controller_signing,
                registry.rooms.get(&room_id).unwrap(),
                &target,
                &lease_id,
                1,
                3,
                &[0xd4; 32],
            )
        };
        forged.ciphertext = URL_SAFE_NO_PAD.encode([0xe5; 32]);
        assert_eq!(
            manager.route_controller_frame_memory(&room_id, &target, &forged),
            ControllerFrameAuthorization::FrameRejected,
            "altered ciphertext fails the registered device signature"
        );
        assert!(host_received.try_recv().is_err());
    }

    #[test]
    fn expired_rooms_are_closed_and_release_room_capacity() {
        let signer = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let manager = CollaborationState::default();
        let now = Utc::now().timestamp();
        let mut host_closed = None;
        let mut observer_closed = None;
        {
            let mut registry = manager.inner.lock().unwrap();
            for index in 0..MAX_ROOMS {
                let mut room = sample_room(&signer, &target);
                room.session_id = Uuid::new_v4().to_string();
                room.expires_epoch = now - 1;
                if index == 0 {
                    let (host_tx, host_rx) = watch::channel(CloseSignal::None);
                    let (observer_tx, observer_rx) = watch::channel(CloseSignal::None);
                    room.host_connection = Some(ConnectionRef {
                        id: "host-connection".to_owned(),
                        outbound: mpsc::channel(1).0,
                        close: host_tx,
                    });
                    room.observer_connections.insert(
                        target.clone(),
                        ConnectionRef {
                            id: "observer-connection".to_owned(),
                            outbound: mpsc::channel(1).0,
                            close: observer_tx,
                        },
                    );
                    host_closed = Some(host_rx);
                    observer_closed = Some(observer_rx);
                }
                registry.tickets.insert(
                    format!("pending-{index}"),
                    TicketRecord {
                        session_id: room.session_id.clone(),
                        vault_id: room.vault_id.clone(),
                        role: ConnectionRole::Observer,
                        user_id: target.user_id.clone(),
                        device_id: target.device_id.clone(),
                        auth_session_id: "test-session".to_owned(),
                        access_hash: "test-hash".to_owned(),
                        server_generation: "test-generation".to_owned(),
                        expires_epoch: now + TICKET_TTL_SECONDS,
                        control_lease_id: None,
                        control_epoch: None,
                    },
                );
                registry.rooms.insert(room.session_id.clone(), room);
            }
        }

        let mut new_room = sample_room(&signer, &target);
        new_room.session_id = Uuid::new_v4().to_string();
        new_room.expires_epoch = now + SESSION_TTL_SECONDS;
        let host = AuthUser {
            user_id: new_room.host_user_id.clone(),
            device_id: new_room.host_device_id.clone(),
            session_id: "active-session".to_owned(),
            access_hash: "active-access-hash".to_owned(),
            declares_record_schema2: true,
            declares_sync_redaction_v1: true,
        };

        manager
            .install_room_and_host_ticket(new_room, &host, "generation", now + 60)
            .unwrap();

        let registry = manager.inner.lock().unwrap();
        assert_eq!(registry.rooms.len(), 1);
        assert_eq!(registry.tickets.len(), 1);
        assert!(
            registry
                .tickets
                .values()
                .all(|ticket| ticket.session_id == registry.rooms.keys().next().unwrap().as_str())
        );
        assert_eq!(*host_closed.unwrap().borrow(), CloseSignal::SessionEnded);
        assert_eq!(
            *observer_closed.unwrap().borrow(),
            CloseSignal::SessionEnded
        );
    }

    #[test]
    fn observer_disconnect_revokes_control_lease_and_rejoin_gets_no_old_grant() {
        let host_signing = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let manager = CollaborationState::default();
        let mut room = sample_room(&host_signing, &target);
        room.protocol_version = PROTOCOL_VERSION_V2;
        room.control_epoch = 1;
        let session_id = room.session_id.clone();
        let lease_id = "00000000-0000-4000-8000-000000000007".to_owned();
        let (host_outbound, mut host_messages) = mpsc::channel(4);
        room.host_connection = Some(ConnectionRef {
            id: "host-connection".to_owned(),
            outbound: host_outbound,
            close: watch::channel(CloseSignal::None).0,
        });
        let (observer_outbound, _) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        room.observer_connections.insert(
            target.clone(),
            ConnectionRef {
                id: "observer-connection".to_owned(),
                outbound: observer_outbound,
                close: watch::channel(CloseSignal::None).0,
            },
        );
        let (controller_outbound, _) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (controller_close, controller_close_rx) = watch::channel(CloseSignal::None);
        room.controller_lease = Some(ControllerLease {
            controller: target.clone(),
            lease_id: lease_id.clone(),
            control_epoch: 1,
            expires_at: (Utc::now() + chrono::Duration::seconds(60)).to_rfc3339(),
            expires_epoch: Utc::now().timestamp() + 60,
            keybox: ControlKeybox {
                format: "atermius-terminal-control-keybox-v2".to_owned(),
                session_id: room.session_id.clone(),
                vault_id: room.vault_id.clone(),
                membership_version: room.membership_version,
                host_user_id: room.host_user_id.clone(),
                host_device_id: room.host_device_id.clone(),
                controller_user_id: target.user_id.clone(),
                controller_device_id: target.device_id.clone(),
                lease_id: lease_id.clone(),
                control_epoch: 1,
                purpose: "input".to_owned(),
                expires_at: (Utc::now() + chrono::Duration::seconds(60)).to_rfc3339(),
                sealed_secret: URL_SAFE_NO_PAD.encode([0x5a; 80]),
                signature: URL_SAFE_NO_PAD.encode([0x6a; 64]),
            },
            signing_public_key: URL_SAFE_NO_PAD.encode(
                ed25519_dalek::SigningKey::from_bytes(&[0x44; 32])
                    .verifying_key()
                    .to_bytes(),
            ),
            connection: Some(ConnectionRef {
                id: "controller-connection".to_owned(),
                outbound: controller_outbound,
                close: controller_close,
            }),
            last_sequence: 0,
            rate_window_started: Utc::now().timestamp(),
            rate_frames: 0,
            rate_bytes: 0,
        });
        manager
            .inner
            .lock()
            .unwrap()
            .rooms
            .insert(session_id.clone(), room);

        manager.disconnect(
            &session_id,
            "observer-connection",
            ConnectionRole::Observer,
            &target.user_id,
            Some(&target),
        );

        assert_eq!(*controller_close_rx.borrow(), CloseSignal::ControlRevoked);
        let ended = host_messages.try_recv().unwrap();
        let ended: serde_json::Value = serde_json::from_str(&ended).unwrap();
        assert_eq!(ended["type"], "controller_lease_ended");
        assert_eq!(ended["lease_id"], lease_id);
        assert_eq!(ended["reason"], "observer_disconnected");
        {
            let registry = manager.inner.lock().unwrap();
            let room = registry.rooms.get(&session_id).unwrap();
            assert!(!room.observer_connections.contains_key(&target));
            assert!(room.controller_lease.is_none());
        }

        let authorized = AuthorizedTicket {
            record: TicketRecord {
                session_id: session_id.clone(),
                vault_id: "00000000-0000-4000-8000-000000000002".to_owned(),
                role: ConnectionRole::Observer,
                user_id: target.user_id.clone(),
                device_id: target.device_id.clone(),
                auth_session_id: "observer-auth-session".to_owned(),
                access_hash: "observer-access-hash".to_owned(),
                server_generation: "test-generation".to_owned(),
                expires_epoch: Utc::now().timestamp() + TICKET_TTL_SECONDS,
                control_lease_id: None,
                control_epoch: None,
            },
            target: Some(target.clone()),
        };
        let (rejoin_outbound, mut rejoin_messages) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (rejoin_close, _) = watch::channel(CloseSignal::None);
        let (_, rejoin_guard) = manager
            .admit_connection(&authorized, rejoin_outbound, rejoin_close)
            .unwrap();
        assert!(rejoin_messages.try_recv().is_err());
        drop(rejoin_guard);
    }

    #[tokio::test]
    async fn frame_signature_nonce_and_ciphertext_are_preserved_and_replay_is_rejected() {
        let signer = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let manager = CollaborationState::default();
        let mut room = sample_room(&signer, &target);
        let (outbound, mut received) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (close, _close_receiver) = watch::channel(CloseSignal::None);
        room.observer_connections.insert(
            target.clone(),
            ConnectionRef {
                id: Uuid::new_v4().to_string(),
                outbound,
                close,
            },
        );
        manager
            .inner
            .lock()
            .unwrap()
            .rooms
            .insert(room.session_id.clone(), room);
        let frame = sample_frame(&signer, &target, 7, &[0xa5; 24]);
        manager.route_frame(&frame.session_id, &frame).unwrap();
        let forwarded: Value = serde_json::from_str(&received.recv().await.unwrap()).unwrap();
        assert_eq!(forwarded["frame"]["ciphertext"], frame.ciphertext);
        assert_eq!(forwarded["frame"]["nonce"], frame.nonce);
        let replay = manager.route_frame(&frame.session_id, &frame).unwrap_err();
        assert_eq!(replay.body.code, "TERMINAL_FRAME_REPLAY");
    }

    #[tokio::test]
    async fn late_observer_gets_only_latest_resize_before_live_frames() {
        let signer = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let manager = CollaborationState::default();
        let room_id = "00000000-0000-4000-8000-000000000001".to_owned();
        manager
            .inner
            .lock()
            .unwrap()
            .rooms
            .insert(room_id.clone(), sample_room(&signer, &target));

        let mut resize = sample_frame(&signer, &target, 11, &[0x12; 40]);
        resize.kind = "resize".to_owned();
        sign_frame(&signer, &mut resize);
        manager.route_frame(&room_id, &resize).unwrap();
        assert!(
            manager
                .inner
                .lock()
                .unwrap()
                .rooms
                .get(&room_id)
                .unwrap()
                .latest_resize
                .contains_key(&target)
        );

        let authorized = AuthorizedTicket {
            record: TicketRecord {
                session_id: room_id.clone(),
                vault_id: "00000000-0000-4000-8000-000000000002".to_owned(),
                role: ConnectionRole::Observer,
                user_id: target.user_id.clone(),
                device_id: target.device_id.clone(),
                auth_session_id: "00000000-0000-4000-8000-000000000007".to_owned(),
                access_hash: "test-hash".to_owned(),
                server_generation: "generation".to_owned(),
                expires_epoch: Utc::now().timestamp() + 30,
                control_lease_id: None,
                control_epoch: None,
            },
            target: Some(target.clone()),
        };
        let (outbound, mut received) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (close, _close_receiver) = watch::channel(CloseSignal::None);
        let (_, _guard) = manager
            .admit_connection(&authorized, outbound, close)
            .unwrap();

        let live_output = sample_frame(&signer, &target, 1, &[0x77; 40]);
        manager.route_frame(&room_id, &live_output).unwrap();
        let initial: Value = serde_json::from_str(&received.recv().await.unwrap()).unwrap();
        let next: Value = serde_json::from_str(&received.recv().await.unwrap()).unwrap();
        assert_eq!(initial["frame"]["kind"], "resize");
        assert_eq!(initial["frame"]["sequence"], 11);
        assert_eq!(next["frame"]["kind"], "output");
        assert_eq!(next["frame"]["ciphertext"], live_output.ciphertext);
    }

    #[test]
    fn oversized_or_malformed_encrypted_frame_is_rejected() {
        let signer = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let room = sample_room(&signer, &target);
        let oversized = sample_frame(&signer, &target, 1, &vec![0; MAX_CIPHERTEXT_BYTES + 1]);
        assert_eq!(
            validate_frame_context(&room, &oversized)
                .unwrap_err()
                .body
                .code,
            "INVALID_ENVELOPE"
        );
        let mut malformed_nonce = sample_frame(&signer, &target, 1, &[0; 16]);
        malformed_nonce.nonce = "not-base64".to_owned();
        assert_eq!(
            validate_frame_context(&room, &malformed_nonce)
                .unwrap_err()
                .body
                .code,
            "INVALID_ENVELOPE"
        );
    }

    #[tokio::test]
    async fn bounded_slow_observer_is_removed_without_blocking_host() {
        let signer = ed25519_dalek::SigningKey::from_bytes(&[0x33; 32]);
        let target = Target {
            user_id: "00000000-0000-4000-8000-000000000005".to_owned(),
            device_id: "00000000-0000-4000-8000-000000000006".to_owned(),
        };
        let manager = CollaborationState::default();
        let mut room = sample_room(&signer, &target);
        let (outbound, _received) = mpsc::channel(OBSERVER_QUEUE_FRAMES);
        let (close, mut closed) = watch::channel(CloseSignal::None);
        room.observer_connections.insert(
            target.clone(),
            ConnectionRef {
                id: Uuid::new_v4().to_string(),
                outbound,
                close,
            },
        );
        manager
            .inner
            .lock()
            .unwrap()
            .rooms
            .insert(room.session_id.clone(), room);
        for sequence in 1..=(OBSERVER_QUEUE_FRAMES as u64 + 1) {
            let frame = sample_frame(&signer, &target, sequence, &[0xa5; 24]);
            manager.route_frame(&frame.session_id, &frame).unwrap();
        }
        closed.changed().await.unwrap();
        assert_eq!(*closed.borrow(), CloseSignal::SessionEnded);
        assert!(
            manager
                .inner
                .lock()
                .unwrap()
                .rooms
                .get("00000000-0000-4000-8000-000000000001")
                .unwrap()
                .observer_connections
                .is_empty()
        );
    }
}

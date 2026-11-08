use crate::{
    ApiError, AppState,
    auth::{self, AuthUser, DeviceInput, InitialKeyEnvelope, InitialVault},
    jcs, now_rfc3339, sha256_hex,
};
use axum::{
    Json,
    extract::{ConnectInfo, Path, Query, State},
    http::HeaderMap,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Duration, SecondsFormat, Utc};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Digest;
use sqlx::{Row, Sqlite, Transaction};
use std::net::SocketAddr;
use uuid::Uuid;

type HmacSha256 = Hmac<sha2::Sha256>;

#[derive(Deserialize)]
pub struct VaultDeletionRequest {
    pub login_verifier: String,
}

#[derive(Deserialize)]
pub struct ManifestInput {
    pub membership_version: i64,
    #[serde(default)]
    pub previous_digest: Option<String>,
    pub manifest: Value,
    pub signature: String,
}
#[derive(Deserialize)]
pub struct KeyEnvelopeInput {
    pub recipient_device_id: String,
    pub key_epoch: Value,
    pub membership_version: Value,
    pub envelope: Value,
    pub signature: String,
    pub signer_device_id: String,
}
#[derive(Deserialize)]
pub struct CreateVaultRequest {
    pub vault_id: String,
    pub name_envelope: Value,
    pub key_envelope: InitialKeyEnvelope,
    pub membership: auth::InitialMembership,
    #[serde(default)]
    pub key_epoch: Option<Value>,
    #[serde(default)]
    pub membership_version: Option<Value>,
}
#[derive(Deserialize)]
pub struct InvitationRequest {
    pub role: String,
    pub recipient_device_id: String,
    pub recipient_encryption_public_key: String,
    pub key_envelope: InitialKeyEnvelope,
    pub membership: ManifestInput,
    #[serde(default)]
    pub expires_in_seconds: Option<i64>,
}
#[derive(Deserialize)]
pub struct RotateRequest {
    pub new_epoch: i64,
    pub membership: ManifestInput,
    pub key_envelopes: Vec<KeyEnvelopeInput>,
}
#[derive(Deserialize)]
pub struct OwnershipTransferRequest {
    pub new_owner_user_id: String,
    pub new_epoch: i64,
    pub membership: ManifestInput,
    pub key_envelopes: Vec<KeyEnvelopeInput>,
}
#[derive(Deserialize)]
pub struct FromQuery {
    pub from: Option<i64>,
}

#[derive(Deserialize)]
pub struct AcceptInvitation {
    pub token: String,
}

pub(crate) fn invitation_lifetime_seconds(requested: Option<i64>) -> Result<i64, ApiError> {
    let value = requested.unwrap_or(7 * 24 * 3600);
    if !(60..=30 * 24 * 3600).contains(&value) {
        return Err(ApiError::bad_request(
            "INVALID_INVITATION_TTL",
            "vault invitation lifetime must be between 60 and 2592000 seconds",
        ));
    }
    Ok(value)
}

async fn active_vault_membership_count_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<i64, ApiError> {
    sqlx::query_scalar(
        "SELECT COUNT(DISTINCT vm.vault_id) FROM vault_members vm \
         JOIN vaults v ON v.vault_id=vm.vault_id \
         WHERE vm.user_id=? AND vm.state='active' AND v.state IN ('active','deleting')",
    )
    .bind(user_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn ensure_user_vault_capacity_tx(
    state: &AppState,
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<(), ApiError> {
    if active_vault_membership_count_tx(tx, user_id).await?
        >= state.vault_limits.max_vaults_per_user
    {
        return Err(ApiError::conflict(
            "USER_VAULT_LIMIT_REACHED",
            "account has reached its Vault limit",
        ));
    }
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum InvitationStatus {
    Pending,
    Expired,
    Stale,
    ReissueRequired,
}

impl InvitationStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Expired => "expired",
            Self::Stale => "stale",
            Self::ReissueRequired => "reissue_required",
        }
    }
}

fn invitation_status(
    issuance_order: Option<i64>,
    created_at: Option<&str>,
    expires_at: Option<&str>,
    key_envelope: Option<&str>,
    recipient_device_status: Option<&str>,
    active_epoch: i64,
    membership_version: i64,
    now: DateTime<Utc>,
) -> InvitationStatus {
    // Legacy invitations have no issuance order, so their relative order and
    // usable expiry cannot be established safely. A revoked or missing target
    // device likewise cannot accept the bound token.
    if issuance_order.is_none() {
        return InvitationStatus::ReissueRequired;
    }
    let Some(created_at) = created_at else {
        return InvitationStatus::ReissueRequired;
    };
    if recipient_device_status != Some("active") {
        return InvitationStatus::ReissueRequired;
    };
    let Some(expires_at) = expires_at.and_then(|value| DateTime::parse_from_rfc3339(value).ok())
    else {
        return InvitationStatus::ReissueRequired;
    };
    // Expiry takes precedence over stale epoch/version metadata.
    if expires_at <= now {
        return InvitationStatus::Expired;
    }
    if DateTime::parse_from_rfc3339(created_at).is_err() {
        return InvitationStatus::ReissueRequired;
    }
    let Some(key_envelope) =
        key_envelope.and_then(|value| serde_json::from_str::<Value>(value).ok())
    else {
        return InvitationStatus::ReissueRequired;
    };
    let Some(key_epoch) = key_envelope.get("key_epoch").and_then(Value::as_i64) else {
        return InvitationStatus::ReissueRequired;
    };
    let Some(invitation_membership_version) = key_envelope
        .get("membership_version")
        .and_then(Value::as_i64)
    else {
        return InvitationStatus::ReissueRequired;
    };
    if key_epoch != active_epoch || invitation_membership_version != membership_version {
        return InvitationStatus::Stale;
    }
    InvitationStatus::Pending
}

/// An invitation adds exactly one access grant to the signed membership chain.
/// Existing DB `invited` entries are represented as `active` grants in the
/// owner-signed manifest, but remain non-authorized until their token is used.
pub(crate) fn validate_invitation_membership(
    manifest_members: &[Value],
    current_members: &[(String, String, String)],
    recipient_user: &str,
    granted_role: &str,
) -> Result<(), ApiError> {
    let mut signed = std::collections::HashMap::with_capacity(manifest_members.len());
    for member in manifest_members {
        let id = member
            .get("user_id")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("membership member id is invalid"))?;
        let role = member
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("membership role is invalid"))?;
        let state = member
            .get("state")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("membership state is invalid"))?;
        if signed.insert(id, (role, state)).is_some() {
            return Err(ApiError::invalid_envelope(
                "membership manifest contains a duplicate member",
            ));
        }
    }

    let mut recipient_present = false;
    for (user_id, role, state) in current_members {
        let grant = signed.get(user_id.as_str()).ok_or_else(|| {
            ApiError::invalid_envelope("invitation manifest cannot omit an existing member")
        })?;
        if user_id == recipient_user {
            if state == "active" {
                return Err(ApiError::conflict(
                    "RECIPIENT_ALREADY_MEMBER",
                    "an active member should approve a new device instead",
                ));
            }
            if grant.0 != granted_role || grant.1 != "active" {
                return Err(ApiError::invalid_envelope(
                    "invitation grant must keep its role and mark the recipient active",
                ));
            }
            recipient_present = true;
            continue;
        }

        // Pending invitation rows already have an owner-signed active grant;
        // only token acceptance is still missing from the server ACL state.
        let expected_state = match state.as_str() {
            "active" | "invited" => "active",
            "revoked" => "revoked",
            _ => {
                return Err(ApiError::internal(
                    "database contains an invalid vault membership state",
                ));
            }
        };
        if grant.0 != role || grant.1 != expected_state {
            return Err(ApiError::invalid_envelope(
                "invitation manifest cannot change another member's role or state",
            ));
        }
    }

    if !recipient_present {
        let grant = signed.get(recipient_user).ok_or_else(|| {
            ApiError::invalid_envelope("invitation manifest does not grant the recipient")
        })?;
        if grant.0 != granted_role || grant.1 != "active" {
            return Err(ApiError::invalid_envelope(
                "invitation grant must mark the recipient active with the granted role",
            ));
        }
    }

    if signed.keys().any(|user_id| {
        *user_id != recipient_user
            && !current_members
                .iter()
                .any(|(current_id, _, _)| current_id == *user_id)
    }) {
        return Err(ApiError::invalid_envelope(
            "invitation manifest cannot add another member",
        ));
    }
    Ok(())
}

pub(crate) fn rotated_acl_state(
    current_state: &str,
    signed_state: &str,
) -> Result<&'static str, ()> {
    match (current_state, signed_state) {
        ("active", "active") => Ok("active"),
        ("active", "revoked") => Ok("revoked"),
        ("invited", "active") => Ok("invited"),
        ("invited", "revoked") => Ok("revoked"),
        ("revoked", "revoked") => Ok("revoked"),
        _ => Err(()),
    }
}

fn validate_owner_transfer_member_transition(
    current_owner: &str,
    new_owner: &str,
    current_roles: &std::collections::HashMap<String, String>,
    current_states: &std::collections::HashMap<String, String>,
    desired: &std::collections::HashMap<String, (String, String)>,
) -> Result<(), ApiError> {
    let target_role = current_roles.get(new_owner).map(String::as_str);
    let target_state = current_states.get(new_owner).map(String::as_str);
    if !matches!(target_role, Some("editor" | "viewer")) || target_state != Some("active") {
        return Err(ApiError::conflict(
            "OWNER_TRANSFER_TARGET_INVALID",
            "new owner must be an existing active editor or viewer",
        ));
    }
    if current_roles.get(current_owner).map(String::as_str) != Some("owner")
        || current_states.get(current_owner).map(String::as_str) != Some("active")
    {
        return Err(ApiError::invalid_envelope(
            "ownership transfer source is not the active owner",
        ));
    }
    if current_roles.len() != desired.len() || current_states.len() != desired.len() {
        return Err(ApiError::invalid_envelope(
            "ownership transfer must describe every existing member",
        ));
    }
    for (member_id, current_role) in current_roles {
        let current_state = current_states
            .get(member_id)
            .map(String::as_str)
            .unwrap_or_default();
        let (expected_role, expected_state) = if member_id == current_owner {
            ("editor", "active")
        } else if member_id == new_owner {
            ("owner", "active")
        } else {
            let signed_state = match current_state {
                "active" | "invited" => "active",
                "revoked" => "revoked",
                _ => {
                    return Err(ApiError::internal(
                        "database contains an invalid vault membership state",
                    ));
                }
            };
            (current_role.as_str(), signed_state)
        };
        let Some((desired_role, desired_state)) = desired.get(member_id) else {
            return Err(ApiError::invalid_envelope(
                "ownership transfer omitted an existing member",
            ));
        };
        if desired_role != expected_role || desired_state != expected_state {
            return Err(ApiError::invalid_envelope(
                "ownership transfer cannot include unrelated role, invitation or revocation changes",
            ));
        }
    }
    Ok(())
}

async fn signer_public(state: &AppState, user: &AuthUser) -> Result<String, ApiError> {
    sqlx::query_scalar("SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'").bind(&user.device_id).bind(&user.user_id).fetch_optional(&state.db).await.map_err(ApiError::internal)?.ok_or_else(||ApiError::forbidden("DEVICE_REVOKED","device is not active"))
}
async fn signed_manifest(
    state: &AppState,
    user: &AuthUser,
    vault_id: &str,
    input: &ManifestInput,
    transfer_to: Option<&str>,
) -> Result<(String, String), ApiError> {
    if input.membership_version < 1
        || !input.manifest.is_object()
        || input.manifest.to_string().len() > 256 * 1024
    {
        return Err(ApiError::bad_request(
            "INVALID_MEMBERSHIP_MANIFEST",
            "membership manifest is invalid",
        ));
    }
    let Some((role,owner_id))=sqlx::query_as::<_,(String,String)>("SELECT vm.role,v.owner_user_id FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id WHERE vm.vault_id=? AND vm.user_id=? AND vm.state='active'").bind(vault_id).bind(&user.user_id).fetch_optional(&state.db).await.map_err(ApiError::internal)? else{return Err(ApiError::not_found());};
    if role != "owner" || owner_id != user.user_id {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "only the active vault owner may change membership",
        ));
    }
    if input
        .manifest
        .get("signer_device_id")
        .and_then(Value::as_str)
        != Some(&user.device_id)
    {
        return Err(ApiError::invalid_envelope(
            "membership manifest signer does not match the authenticated device",
        ));
    }
    let members = input
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .filter(|members| !members.is_empty() && members.len() <= 1000)
        .ok_or_else(|| ApiError::invalid_envelope("membership manifest member list is invalid"))?;
    let mut ids = std::collections::HashSet::new();
    let mut active_owner_id: Option<&str> = None;
    for member in members {
        let id = member
            .get("user_id")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                ApiError::invalid_envelope("membership manifest member id is invalid")
            })?;
        let member_role = member
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("membership manifest role is invalid"))?;
        let status = member
            .get("state")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("membership manifest state is invalid"))?;
        if !crate::is_canonical_uuid(id)
            || !ids.insert(id)
            || !["owner", "editor", "viewer"].contains(&member_role)
            || !["active", "invited", "revoked"].contains(&status)
        {
            return Err(ApiError::invalid_envelope(
                "membership manifest contains an invalid or duplicate member",
            ));
        }
        if member_role == "owner" && status == "active" {
            if active_owner_id.replace(id).is_some() {
                return Err(ApiError::invalid_envelope(
                    "membership manifest must keep exactly one active owner",
                ));
            }
        }
    }
    if active_owner_id != Some(transfer_to.unwrap_or(owner_id.as_str())) {
        return Err(ApiError::invalid_envelope(
            "membership manifest owner does not match the authorized owner transition",
        ));
    }
    match transfer_to {
        Some(new_owner_id) => {
            if !crate::is_canonical_uuid(new_owner_id) || new_owner_id == owner_id {
                return Err(ApiError::bad_request(
                    "INVALID_OWNER_TRANSFER",
                    "new owner must be a different canonical user ID",
                ));
            }
            let transfer = input
                .manifest
                .get("ownership_transfer")
                .and_then(Value::as_object)
                .filter(|fields| {
                    fields.len() == 2
                        && fields.contains_key("from_user_id")
                        && fields.contains_key("to_user_id")
                })
                .ok_or_else(|| {
                    ApiError::invalid_envelope(
                        "ownership transfer must be included in the signed membership manifest",
                    )
                })?;
            if transfer.get("from_user_id").and_then(Value::as_str) != Some(&owner_id)
                || transfer.get("to_user_id").and_then(Value::as_str) != Some(new_owner_id)
            {
                return Err(ApiError::invalid_envelope(
                    "signed ownership transfer does not match the authenticated owner and target",
                ));
            }
            let members = input
                .manifest
                .get("members")
                .and_then(Value::as_array)
                .ok_or_else(|| {
                    ApiError::invalid_envelope("membership manifest member list is invalid")
                })?;
            let former_owner = members
                .iter()
                .find(|member| member.get("user_id").and_then(Value::as_str) == Some(&owner_id));
            let new_owner = members
                .iter()
                .find(|member| member.get("user_id").and_then(Value::as_str) == Some(new_owner_id));
            if former_owner
                .and_then(|member| member.get("role"))
                .and_then(Value::as_str)
                != Some("editor")
                || former_owner
                    .and_then(|member| member.get("state"))
                    .and_then(Value::as_str)
                    != Some("active")
                || new_owner
                    .and_then(|member| member.get("role"))
                    .and_then(Value::as_str)
                    != Some("owner")
                || new_owner
                    .and_then(|member| member.get("state"))
                    .and_then(Value::as_str)
                    != Some("active")
            {
                return Err(ApiError::invalid_envelope(
                    "ownership transfer must keep the former owner active as editor and make the target the active owner",
                ));
            }
        }
        None => {
            if input.manifest.get("ownership_transfer").is_some() {
                return Err(ApiError::invalid_envelope(
                    "ownership transfer requires the dedicated transfer endpoint",
                ));
            }
        }
    }
    let payload = json!({"vault_id":vault_id,"membership_version":input.membership_version,"previous_digest":input.previous_digest,"manifest":input.manifest});
    let bytes = jcs(&payload)?;
    auth::verify_key_signature(&signer_public(state, user).await?, &input.signature, &bytes)?;
    let digest = sha256_hex(&bytes);
    let full = auth::serialize_signed_membership_record(
        vault_id,
        Value::from(input.membership_version),
        input
            .previous_digest
            .clone()
            .map(Value::String)
            .unwrap_or(Value::Null),
        &input.manifest,
        &input.signature,
    )?;
    Ok((digest, full))
}
async fn persist_manifest(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    user: &AuthUser,
    input: &ManifestInput,
    digest: &str,
    full: &str,
) -> Result<(), ApiError> {
    let display_name_envelope = input
        .manifest
        .get("display_name_envelope")
        .map(auth::validate_display_name_envelope)
        .transpose()?;
    let row = sqlx::query("SELECT membership_version FROM vaults WHERE vault_id=?")
        .bind(vault_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let current: i64 = row.get("membership_version");
    if input.membership_version != current + 1 {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "membership version must advance by one",
        ));
    }
    let prev:Option<String>=sqlx::query_scalar("SELECT digest FROM membership_manifests WHERE vault_id=? ORDER BY membership_version DESC LIMIT 1").bind(vault_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    if input.previous_digest != prev {
        return Err(ApiError::conflict(
            "MEMBERSHIP_CHAIN_CONFLICT",
            "previous membership digest does not match",
        ));
    }
    sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,?,?,?,?,?,?,?)").bind(vault_id).bind(input.membership_version).bind(&input.previous_digest).bind(full).bind(digest).bind(&user.device_id).bind(&input.signature).bind(now_rfc3339()).execute(&mut **tx).await.map_err(ApiError::internal)?;
    if let Some(envelope) = display_name_envelope {
        sqlx::query("UPDATE vaults SET membership_version=?,name_envelope=? WHERE vault_id=?")
            .bind(input.membership_version)
            .bind(envelope)
            .bind(vault_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    } else {
        sqlx::query("UPDATE vaults SET membership_version=? WHERE vault_id=?")
            .bind(input.membership_version)
            .bind(vault_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

fn unix_epoch_rfc3339(value: Option<i64>) -> Option<String> {
    value.and_then(|seconds| {
        DateTime::<Utc>::from_timestamp(seconds, 0)
            .map(|date| date.to_rfc3339_opts(SecondsFormat::Secs, true))
    })
}

fn vault_lifecycle_dto(
    vault_id: &str,
    role: &str,
    status: &str,
    requested_at: Option<i64>,
    purge_after: Option<i64>,
) -> Value {
    let deleting = status == "deleting";
    json!({
        "vault_id":vault_id,
        "role":role,
        "status":status,
        "requested_at":unix_epoch_rfc3339(requested_at),
        "purge_after":unix_epoch_rfc3339(purge_after),
        "can_cancel":deleting && role == "owner" && purge_after.is_some_and(|deadline| deadline > Utc::now().timestamp()),
        "can_write":!deleting && role != "viewer"
    })
}

async fn verify_deletion_step_up(
    state: &AppState,
    user: &AuthUser,
    verifier: &str,
    peer: SocketAddr,
) -> Result<String, ApiError> {
    let username = if let Some(repository) = state.pg_vault_deletion.as_ref() {
        repository.username_for_user(&user.user_id).await?
    } else {
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=? AND status='active'")
            .bind(&user.user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)?
    };
    let limited = auth::consume_auth_rate_limit(
        state,
        crate::rate_limit::AuthOperation::Login,
        &username,
        Some(peer.ip()),
    )
    .await?;
    if let Some(seconds) = limited {
        return Err(ApiError::rate_limited(seconds));
    }
    if let Some(repository) = state.pg_vault_deletion.as_ref() {
        return repository
            .verify_login_verifier(&user.user_id, verifier)
            .await;
    }
    auth::verify_login_verifier_for_user(state, &user.user_id, verifier).await
}

async fn validate_lifecycle_owner_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &AuthUser,
    vault_id: &str,
    verified_hash: &str,
) -> Result<(String, String), ApiError> {
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(vault_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let row = sqlx::query(
        "SELECT v.owner_user_id,v.state,vm.role,vm.state AS member_state FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE v.vault_id=? AND vm.user_id=?",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    if row.get::<String, _>("owner_user_id") != user.user_id
        || row.get::<String, _>("role") != "owner"
        || row.get::<String, _>("member_state") != "active"
    {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "active Owner membership is required",
        ));
    }

    let user_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if user_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let device_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM devices WHERE device_id=? AND user_id=?")
            .bind(&user.device_id)
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "current device is not active",
        ));
    }
    let session = sqlx::query_as::<_, (Option<String>, String)>(
        "SELECT revoked_at,access_expires_at FROM sessions WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=?",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((revoked_at, expires_at)) = session else {
        return Err(ApiError::unauthorized());
    };
    if revoked_at.is_some()
        || DateTime::parse_from_rfc3339(&expires_at).map_or(true, |expiry| expiry <= Utc::now())
    {
        return Err(ApiError::unauthorized());
    }
    let current_hash: Option<String> =
        sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=?")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if current_hash.as_deref() != Some(verified_hash) {
        return Err(ApiError::reauth_required());
    }
    let status: String = row.get("state");
    Ok((status, row.get("role")))
}

fn deletion_actor_hash(state: &AppState, user: &AuthUser) -> Result<String, ApiError> {
    let mut mac =
        HmacSha256::new_from_slice(state.auth_rate_key.as_ref()).map_err(ApiError::internal)?;
    mac.update(b"atermius/vault-deletion-audit/v1\0");
    mac.update(user.user_id.as_bytes());
    mac.update(b"\0");
    mac.update(user.device_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub async fn list_vaults(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_reads.as_ref() {
        return Ok(Json(repository.list_vaults(&user).await?));
    }
    let rows = sqlx::query(
        "SELECT v.vault_id,vm.role,v.active_epoch,v.membership_version,v.required_record_schema,v.name_envelope,v.state,dr.requested_at,dr.purge_after FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id LEFT JOIN vault_deletion_requests dr ON dr.vault_id=v.vault_id AND dr.cancelled_at IS NULL AND dr.purged_at IS NULL WHERE vm.user_id=? AND vm.state='active' AND v.state IN ('active','deleting') ORDER BY v.created_at",
    )
    .bind(&user.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let mut vaults = Vec::new();
    for r in rows {
        let id: String = r.get("vault_id");
        let role: String = r.get("role");
        let status: String = r.get("state");
        let requested_at: Option<i64> = r.get("requested_at");
        let purge_after: Option<i64> = r.get("purge_after");
        let ers=sqlx::query("SELECT epoch,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version FROM vault_key_envelopes WHERE vault_id=? AND recipient_device_id=? ORDER BY epoch DESC").bind(&id).bind(&user.device_id).fetch_all(&state.db).await.map_err(ApiError::internal)?;
        let mut entry = vault_lifecycle_dto(&id, &role, &status, requested_at, purge_after);
        entry["active_key_epoch"] = json!(r.get::<i64, _>("active_epoch"));
        entry["membership_version"] = json!(r.get::<i64, _>("membership_version"));
        entry["required_record_schema"] = json!(r.get::<i64, _>("required_record_schema"));
        entry["name_envelope"] = r
            .get::<Option<String>, _>("name_envelope")
            .and_then(|value| serde_json::from_str::<Value>(&value).ok())
            .unwrap_or(Value::Null);
        entry["key_envelopes"] = json!(ers.into_iter().map(|e|json!({"key_epoch":e.get::<i64,_>("epoch"),"recipient_device_id":e.get::<String,_>("recipient_device_id"),"envelope":serde_json::from_str::<Value>(&e.get::<String,_>("envelope")).unwrap_or(Value::Null),"signature":e.get::<String,_>("envelope_signature"),"signer_device_id":e.get::<String,_>("signer_device_id"),"membership_version":e.get::<i64,_>("membership_version")})).collect::<Vec<_>>());
        vaults.push(entry);
    }
    Ok(Json(json!({"vaults":vaults})))
}

pub async fn create_vault(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateVaultRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(repository.create_vault(&user, req).await?));
    }
    let initial = InitialVault {
        vault_id: req.vault_id,
        name_envelope: req.name_envelope,
        key_epoch: req
            .key_epoch
            .unwrap_or_else(|| req.key_envelope.key_epoch.clone()),
        membership_version: req
            .membership_version
            .unwrap_or_else(|| req.membership.membership_version.clone()),
        key_envelope: req.key_envelope,
        membership: req.membership,
    };
    let vault_id = initial.vault_id.clone();
    let device_row=sqlx::query("SELECT name,signing_public_key,encryption_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'").bind(&user.device_id).bind(&user.user_id).fetch_optional(&state.db).await.map_err(ApiError::internal)?.ok_or_else(||ApiError::forbidden("DEVICE_REVOKED","device is not active"))?;
    let device = DeviceInput {
        device_id: user.device_id.clone(),
        name: device_row.get("name"),
        signing_public_key: device_row.get("signing_public_key"),
        encryption_public_key: device_row.get("encryption_public_key"),
        signature: String::new(),
    };
    let (name, digest, full) = auth::validate_initial_vault(&initial, &user.user_id, &device)?;
    let now = now_rfc3339();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    ensure_user_vault_capacity_tx(&state, &mut tx, &user.user_id).await?;
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,name_envelope,membership_version,created_at) VALUES(?,?,?,?,?)").bind(&vault_id).bind(&user.user_id).bind(name).bind(1_i64).bind(&now).execute(&mut *tx).await.map_err(|_|ApiError::conflict("VAULT_EXISTS","vault identifier already exists"))?;
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,added_at) VALUES(?,?,'owner',?)")
        .bind(&vault_id)
        .bind(&user.user_id)
        .bind(&now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,0)")
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,1,?,?,?,?,?,1)").bind(&vault_id).bind(&user.user_id).bind(&user.device_id).bind(initial.key_envelope.envelope.to_string()).bind(&initial.key_envelope.signature).bind(&user.device_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    let signature = initial.membership.signature.as_str();
    sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,1,NULL,?,?,?,?,?)").bind(&vault_id).bind(full).bind(digest).bind(&user.device_id).bind(signature).bind(&now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault_id,
        Some(&user.user_id),
        Some(&user.device_id),
        "vault.created",
        "vault",
        Some(&vault_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"vault_id":vault_id,"role":"owner","active_key_epoch":1,"membership_version":1}),
    ))
}

async fn member_rows_in_read_snapshot(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
) -> Result<Vec<sqlx::sqlite::SqliteRow>, ApiError> {
    sqlx::query(
        "SELECT vm.user_id,u.username,vm.role,vm.state,vm.added_at, \
         v.active_epoch,v.membership_version, \
         invitation.issuance_order AS invitation_issuance_order, \
         invitation.created_at AS invitation_created_at, \
         invitation.expires_at AS invitation_expires_at, \
         invitation.key_envelope AS invitation_key_envelope, \
         invitation_device.status AS invitation_recipient_device_status \
         FROM vault_members vm \
         JOIN users u USING(user_id) \
         JOIN vaults v ON v.vault_id=vm.vault_id \
         LEFT JOIN invitations invitation ON invitation.invitation_id=( \
             SELECT candidate.invitation_id FROM invitations candidate \
             WHERE candidate.vault_id=vm.vault_id \
               AND candidate.recipient_user_id=vm.user_id \
               AND vm.state='invited' \
               AND candidate.accepted_at IS NULL \
             ORDER BY candidate.issuance_order DESC,candidate.created_at DESC,candidate.invitation_id DESC \
             LIMIT 1 \
         ) \
         LEFT JOIN devices invitation_device \
           ON invitation_device.device_id=invitation.recipient_device_id \
          AND invitation_device.user_id=vm.user_id \
         WHERE vm.vault_id=? ORDER BY vm.added_at",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

pub async fn list_members(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_reads.as_ref() {
        return Ok(Json(repository.vault_members(&user, &vault_id).await?));
    }
    // Bind the session, membership check, and roster read to one SQLite
    // snapshot. Otherwise a membership revocation between the standalone
    // authorization query and the roster query could still return the list.
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::require_vault_read_snapshot_tx(&mut tx, &user.user_id, &vault_id).await?;
    let rows = member_rows_in_read_snapshot(&mut tx, &vault_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    let now = Utc::now();
    let members = rows
        .into_iter()
        .map(|row| {
            let state_value: String = row.get("state");
            let invitation = if state_value == "invited" {
                let issuance_order: Option<i64> = row.get("invitation_issuance_order");
                let created_at: Option<String> = row.get("invitation_created_at");
                let stored_expires_at: Option<String> = row.get("invitation_expires_at");
                let key_envelope: Option<String> = row.get("invitation_key_envelope");
                let recipient_device_status: Option<String> =
                    row.get("invitation_recipient_device_status");
                let status = invitation_status(
                    issuance_order,
                    created_at.as_deref(),
                    stored_expires_at.as_deref(),
                    key_envelope.as_deref(),
                    recipient_device_status.as_deref(),
                    row.get("active_epoch"),
                    row.get("membership_version"),
                    now,
                );
                let expires_at = if issuance_order.is_some()
                    && created_at.is_some()
                    && recipient_device_status.as_deref() == Some("active")
                {
                    stored_expires_at
                } else {
                    None
                };
                json!({"status":status.as_str(),"expires_at":expires_at})
            } else {
                Value::Null
            };
            json!({
                "user_id":row.get::<String,_>("user_id"),
                "username":row.get::<String,_>("username"),
                "role":row.get::<String,_>("role"),
                "state":state_value,
                "added_at":row.get::<String,_>("added_at"),
                "invitation":invitation,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({"members":members})))
}

/// Public signing/encryption keys scoped to a vault's current and historical members.
/// This enables recipients to validate owner signatures without exposing account-wide data.
pub async fn vault_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    crate::require_vault(&state, &user.user_id, &vault_id, false).await?;
    if let Some(repository) = state.pg_account_reads.as_ref() {
        return Ok(Json(repository.vault_devices(&user, &vault_id).await?));
    }
    let rows = sqlx::query(
        "SELECT DISTINCT d.device_id,d.user_id,d.name,d.signing_public_key,\
                d.encryption_public_key,d.status,d.created_at,\
                vm.state AS membership_status,\
                r.revision AS cap_revision,r.user_id AS cap_account_id,\
                r.device_id AS cap_device_id,r.max_record_schema AS cap_max_record_schema,\
                r.host_attachment_manifest_versions AS cap_attachment_versions,\
                r.max_attachment_bytes AS cap_max_attachment_bytes,r.signature AS cap_signature,\
                rr.revision AS redaction_cap_revision,\
                rr.user_id AS redaction_cap_account_id,\
                rr.device_id AS redaction_cap_device_id,\
                rr.sync_redaction_version AS redaction_cap_version,\
                rr.signature AS redaction_cap_signature,\
                rr.invalidated_at AS redaction_cap_invalidated_at \
         FROM vault_members vm \
         JOIN users u ON u.user_id=vm.user_id \
         JOIN devices d ON d.user_id=vm.user_id \
         LEFT JOIN device_capability_reports r \
           ON r.device_id=d.device_id AND r.user_id=d.user_id \
              AND vm.state='active' AND d.status='active' \
         LEFT JOIN device_redaction_capability_reports rr \
           ON rr.device_id=d.device_id AND rr.user_id=d.user_id \
              AND vm.state='active' AND d.status='active' \
         WHERE vm.vault_id=? \
         UNION ALL \
         SELECT a.device_id,a.user_id,'Archived device' AS name,\
                a.signing_public_key,a.encryption_public_key,\
                'archived' AS status,a.archived_at AS created_at,\
                'archived' AS membership_status,\
                NULL AS cap_revision,NULL AS cap_account_id,NULL AS cap_device_id,\
                NULL AS cap_max_record_schema,NULL AS cap_attachment_versions,\
                NULL AS cap_max_attachment_bytes,NULL AS cap_signature,\
                NULL AS redaction_cap_revision,NULL AS redaction_cap_account_id,\
                NULL AS redaction_cap_device_id,NULL AS redaction_cap_version,\
                NULL AS redaction_cap_signature,NULL AS redaction_cap_invalidated_at \
         FROM vault_device_archives a \
         WHERE a.vault_id=? AND NOT EXISTS (\
             SELECT 1 FROM devices d WHERE d.device_id=a.device_id\
         ) \
         ORDER BY created_at,device_id",
    )
    .bind(&vault_id)
    .bind(&vault_id)
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let devices = rows
        .into_iter()
        .map(|row| {
            Ok(json!({
                "device_id": row.get::<String, _>("device_id"),
                "user_id": row.get::<String, _>("user_id"),
                "name": row.get::<String, _>("name"),
                "signing_public_key": row.get::<String, _>("signing_public_key"),
                "encryption_public_key": row.get::<String, _>("encryption_public_key"),
                "status": row.get::<String, _>("status"),
                "membership_status": row.get::<String, _>("membership_status"),
                "created_at": row.get::<String, _>("created_at"),
                "capability_report": crate::device_capabilities::report_from_row(&row),
                "redaction_capability_report": redaction_capability_report_from_sqlite_row(&row)?,
            }))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    Ok(Json(json!({"devices":devices})))
}

fn redaction_capability_report_from_sqlite_row(
    row: &sqlx::sqlite::SqliteRow,
) -> Result<Value, ApiError> {
    let Some(revision) = row
        .try_get::<Option<i64>, _>("redaction_cap_revision")
        .map_err(ApiError::internal)?
    else {
        return Ok(Value::Null);
    };
    let account_id = row
        .try_get::<Option<String>, _>("redaction_cap_account_id")
        .map_err(ApiError::internal)?;
    let device_id = row
        .try_get::<Option<String>, _>("redaction_cap_device_id")
        .map_err(ApiError::internal)?;
    let version = row
        .try_get::<Option<i64>, _>("redaction_cap_version")
        .map_err(ApiError::internal)?;
    let signature = row
        .try_get::<Option<String>, _>("redaction_cap_signature")
        .map_err(ApiError::internal)?;
    let invalidated_at = row
        .try_get::<Option<String>, _>("redaction_cap_invalidated_at")
        .map_err(ApiError::internal)?;
    let (Some(account_id), Some(device_id), Some(version), Some(signature)) =
        (account_id, device_id, version, signature)
    else {
        return Ok(Value::Null);
    };
    Ok(json!({
        "format": crate::redaction_capabilities::REPORT_FORMAT,
        "account_id": account_id,
        "device_id": device_id,
        "revision": revision,
        "sync_redaction_version": version,
        "signature": signature,
        "invalidated_at": invalidated_at,
    }))
}

pub async fn create_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Json(req): Json<InvitationRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(
            repository
                .create_vault_invitation(&user, &vault_id, req)
                .await?,
        ));
    }
    let (role, epoch, version) =
        crate::require_vault(&state, &user.user_id, &vault_id, true).await?;
    if role != "owner" {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "owner role is required",
        ));
    }
    if !["editor", "viewer"].contains(&req.role.as_str()) {
        return Err(ApiError::bad_request(
            "INVALID_ROLE",
            "invitation role must be editor or viewer",
        ));
    }
    let target = sqlx::query_as::<_, (String, String)>(
        "SELECT user_id,encryption_public_key FROM devices WHERE device_id=? AND status='active'",
    )
    .bind(&req.recipient_device_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let (recipient_user, recipient_public_key) = target;
    if req.recipient_encryption_public_key != recipient_public_key {
        return Err(ApiError::invalid_envelope(
            "recipient encryption key does not match the registered device",
        ));
    }
    let recipient_key_bytes = URL_SAFE_NO_PAD
        .decode(&recipient_public_key)
        .map_err(|_| ApiError::internal("registered device encryption key is invalid"))?;
    if recipient_key_bytes.len() != 32 {
        return Err(ApiError::internal(
            "registered device encryption key has an invalid size",
        ));
    }
    let recipient_fingerprint = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&recipient_key_bytes));
    let life = invitation_lifetime_seconds(req.expires_in_seconds)?;
    let mut b = [0; 32];
    rand::thread_rng().fill_bytes(&mut b);
    let token = URL_SAFE_NO_PAD.encode(b);
    let token_hash = sha256_hex(token.as_bytes());
    if req.key_envelope.recipient_device_id != req.recipient_device_id
        || auth::as_counter(&req.key_envelope.key_epoch) != Some(epoch)
        || auth::as_counter(&req.key_envelope.membership_version)
            != Some(req.membership.membership_version)
    {
        return Err(ApiError::invalid_envelope(
            "invitation key envelope context is invalid",
        ));
    }
    if req.key_envelope.key_epoch.as_i64() != Some(epoch)
        || req.key_envelope.membership_version.as_i64() != Some(req.membership.membership_version)
        || req
            .membership
            .manifest
            .get("key_epoch")
            .and_then(Value::as_i64)
            != Some(epoch)
    {
        return Err(ApiError::invalid_envelope(
            "invitation epoch fields must be JSON integers and match the active epoch",
        ));
    }
    let invited = req
        .membership
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .and_then(|members| {
            members
                .iter()
                .find(|m| m.get("user_id").and_then(Value::as_str) == Some(&recipient_user))
        });
    if invited.is_none_or(|m| {
        m.get("role").and_then(Value::as_str) != Some(&req.role)
            || m.get("state").and_then(Value::as_str) != Some("active")
            || m.get("encryption_key_fingerprint").and_then(Value::as_str)
                != Some(&recipient_fingerprint)
    }) {
        return Err(ApiError::invalid_envelope(
            "membership grant must list the registered recipient key fingerprint, active state and granted role",
        ));
    }
    let key_payload = json!({"vault_id":vault_id,"recipient_device_id":req.recipient_device_id,"key_epoch":req.key_envelope.key_epoch,"membership_version":req.key_envelope.membership_version,"envelope":req.key_envelope.envelope});
    let owner_public = signer_public(&state, &user).await?;
    auth::verify_key_signature(
        &owner_public,
        &req.key_envelope.signature,
        &jcs(&key_payload)?,
    )?;
    let key = serde_json::to_string(&req.key_envelope).map_err(ApiError::internal)?;
    let (digest, full) = signed_manifest(&state, &user, &vault_id, &req.membership, None).await?;
    if req.membership.membership_version != version + 1 {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "membership version must advance by one",
        ));
    }
    let now = Utc::now();
    let expiry = (now + Duration::seconds(life)).to_rfc3339();
    let id = Uuid::new_v4().to_string();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Acquire SQLite's single writer reservation before checking the ACL and
    // writing the new manifest, so concurrent invites cannot validate against
    // the same membership version and both commit.
    let (tx_role, tx_epoch, tx_version) =
        crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if tx_role != "owner" {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "owner role is required",
        ));
    }
    if req.key_envelope.key_epoch.as_i64() != Some(tx_epoch)
        || req.membership.membership_version != tx_version + 1
    {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "vault epoch or membership changed; retry with a current signed manifest",
        ));
    }
    let issuance_order: i64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(issuance_order),0)+1 FROM invitations \
         WHERE vault_id=? AND recipient_user_id=?",
    )
    .bind(&vault_id)
    .bind(&recipient_user)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let created_at = Utc::now().to_rfc3339();
    let target_still_active: Option<String> = sqlx::query_scalar(
        "SELECT encryption_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&req.recipient_device_id)
    .bind(&recipient_user)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if target_still_active.as_deref() != Some(recipient_public_key.as_str()) {
        return Err(ApiError::not_found());
    }
    let current_members = sqlx::query_as::<_, (String, String, String)>(
        "SELECT user_id,role,state FROM vault_members WHERE vault_id=?",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let manifest_members = req
        .membership
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .ok_or_else(|| ApiError::invalid_envelope("membership manifest member list is invalid"))?;
    validate_invitation_membership(
        manifest_members,
        &current_members,
        &recipient_user,
        &req.role,
    )?;
    let recipient_already_counted = current_members.iter().any(|(member_id, _, state)| {
        member_id == &recipient_user && matches!(state.as_str(), "active" | "invited")
    });
    let counted_members = current_members
        .iter()
        .filter(|(_, _, state)| matches!(state.as_str(), "active" | "invited"))
        .count();
    if !recipient_already_counted
        && counted_members >= state.vault_limits.max_members_per_vault as usize
    {
        return Err(ApiError::conflict(
            "VAULT_MEMBER_LIMIT_REACHED",
            "vault has reached its member limit",
        ));
    }
    persist_manifest(&mut tx, &vault_id, &user, &req.membership, &digest, &full).await?;
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,?,'invited',?) ON CONFLICT(vault_id,user_id) DO UPDATE SET role=excluded.role,state='invited'").bind(&vault_id).bind(&recipient_user).bind(&req.role).bind(now.to_rfc3339()).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(vault_id,epoch,recipient_device_id) DO UPDATE SET envelope=excluded.envelope,envelope_signature=excluded.envelope_signature,signer_device_id=excluded.signer_device_id,membership_version=excluded.membership_version").bind(&vault_id).bind(epoch).bind(&recipient_user).bind(&req.recipient_device_id).bind(req.key_envelope.envelope.to_string()).bind(&req.key_envelope.signature).bind(&user.device_id).bind(req.membership.membership_version).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,recipient_device_id,signer_device_id,created_by,expires_at,created_at,issuance_order) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)").bind(&id).bind(&vault_id).bind(token_hash).bind(&req.role).bind(key).bind(&recipient_user).bind(&req.recipient_device_id).bind(&user.device_id).bind(&user.user_id).bind(&expiry).bind(&created_at).bind(issuance_order).execute(&mut *tx).await.map_err(ApiError::internal)?;
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault_id,
        Some(&user.user_id),
        Some(&user.device_id),
        "vault.invitation_created",
        "invitation",
        Some(&id),
        crate::audit::AuditSource::Api,
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"invitation_id":id,"token":token,"vault_id":vault_id,"role":req.role,"expires_at":expiry,"membership_version":req.membership.membership_version}),
    ))
}

async fn consume_invitation_tx(
    tx: &mut Transaction<'_, Sqlite>,
    invitation_id: &str,
    user_id: &str,
    now: &str,
) -> Result<(), ApiError> {
    let consumed = sqlx::query(
        "UPDATE invitations SET accepted_by=?,accepted_at=? \
         WHERE invitation_id=? AND accepted_at IS NULL AND expires_at>?",
    )
    .bind(user_id)
    .bind(now)
    .bind(invitation_id)
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if consumed.rows_affected() == 1 {
        return Ok(());
    }

    // Re-read the row so an expiry boundary crossed after the first check is
    // reported as expired rather than as a replay. The surrounding vault
    // write transaction keeps acceptance serialized with revocation/rotation.
    let row = sqlx::query("SELECT accepted_at,expires_at FROM invitations WHERE invitation_id=?")
        .bind(invitation_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    if row.get::<Option<String>, _>("accepted_at").is_some() {
        return Err(ApiError::conflict(
            "INVITATION_USED",
            "invitation has already been accepted",
        ));
    }
    let expires_at: String = row.get("expires_at");
    if DateTime::parse_from_rfc3339(&expires_at).map_or(true, |expiry| expiry <= Utc::now()) {
        return Err(ApiError::gone(
            "INVITATION_EXPIRED",
            "invitation has expired",
        ));
    }
    Err(ApiError::conflict(
        "INVITATION_USED",
        "invitation has already been accepted",
    ))
}

pub async fn accept_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AcceptInvitation>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(
            repository.accept_vault_invitation(&user, request).await?,
        ));
    }
    let hash = sha256_hex(request.token.as_bytes());
    let vault_hint: String =
        sqlx::query_scalar("SELECT vault_id FROM invitations WHERE token_hash=?")
            .bind(&hash)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(&vault_hint)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let row=sqlx::query("SELECT invitation_id,vault_id,role,key_envelope,recipient_user_id,recipient_device_id,signer_device_id,expires_at,accepted_at FROM invitations WHERE token_hash=? AND vault_id=?").bind(hash).bind(&vault_hint).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?.ok_or_else(ApiError::not_found)?;
    let id: String = row.get("invitation_id");
    let vault: String = row.get("vault_id");
    let role: String = row.get("role");
    let envelope: String = row.get("key_envelope");
    let recipient_user: Option<String> = row.get("recipient_user_id");
    let recipient_device: Option<String> = row.get("recipient_device_id");
    let signer_device: Option<String> = row.get("signer_device_id");
    let expires: String = row.get("expires_at");
    let accepted: Option<String> = row.get("accepted_at");
    if recipient_user.as_deref() != Some(&user.user_id)
        || recipient_device.as_deref() != Some(&user.device_id)
    {
        return Err(ApiError::forbidden(
            "INVITATION_RECIPIENT_MISMATCH",
            "invitation is addressed to another device",
        ));
    }
    if accepted.is_some() {
        return Err(ApiError::conflict(
            "INVITATION_USED",
            "invitation has already been accepted",
        ));
    }
    if chrono::DateTime::parse_from_rfc3339(&expires).map_or(true, |d| d <= Utc::now()) {
        return Err(ApiError::gone(
            "INVITATION_EXPIRED",
            "invitation has expired",
        ));
    }
    let vault_row =
        sqlx::query("SELECT active_epoch,membership_version,state,required_record_schema FROM vaults WHERE vault_id=?")
            .bind(&vault)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
    let epoch: i64 = vault_row.get("active_epoch");
    let version: i64 = vault_row.get("membership_version");
    if vault_row.get::<String, _>("state") != "active" {
        return Err(ApiError::vault_deletion_pending());
    }
    ensure_user_vault_capacity_tx(&state, &mut tx, &user.user_id).await?;
    if vault_row.get::<i64, _>("required_record_schema") >= 2
        && !crate::device_capabilities::all_active_user_devices_support_v2_tx(
            &mut tx,
            &user.user_id,
        )
        .await?
    {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "all active recipient devices must support schema 2, attachment manifest v2, and 1 GiB attachments",
        ));
    }
    let key: InitialKeyEnvelope = serde_json::from_str(&envelope).map_err(ApiError::internal)?;
    if key.recipient_device_id != user.device_id
        || key.key_epoch.as_i64() != Some(epoch)
        || key.membership_version.as_i64() != Some(version)
    {
        return Err(ApiError::conflict(
            "INVITATION_STALE",
            "vault key or membership changed; request an updated invitation",
        ));
    }
    let now = now_rfc3339();
    let membership=sqlx::query("UPDATE vault_members SET state='active',role=? WHERE vault_id=? AND user_id=? AND state='invited'").bind(&role).bind(&vault).bind(&user.user_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if membership.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "INVITATION_STALE",
            "invitation is no longer pending",
        ));
    }
    let signer_device =
        signer_device.ok_or_else(|| ApiError::internal("missing invitation signer"))?;
    sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(vault_id,epoch,recipient_device_id) DO UPDATE SET envelope=excluded.envelope,envelope_signature=excluded.envelope_signature,signer_device_id=excluded.signer_device_id,membership_version=excluded.membership_version").bind(&vault).bind(epoch).bind(&user.user_id).bind(&user.device_id).bind(key.envelope.to_string()).bind(key.signature).bind(signer_device).bind(version).execute(&mut *tx).await.map_err(ApiError::internal)?;
    consume_invitation_tx(&mut tx, &id, &user.user_id, &now).await?;
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault,
        Some(&user.user_id),
        Some(&user.device_id),
        "vault.invitation_accepted",
        "invitation",
        Some(&id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"invitation_id":id,"vault_id":vault,"role":role,"status":"accepted","membership_version":version}),
    ))
}

pub async fn membership(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Query(query): Query<FromQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    crate::require_vault(&state, &user.user_id, &vault, false).await?;
    let from = query.from.unwrap_or(0).max(0);
    if let Some(repository) = state.pg_account_reads.as_ref() {
        return Ok(Json(repository.membership(&user, &vault, from).await?));
    }
    let rows=sqlx::query("SELECT membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at FROM membership_manifests WHERE vault_id=? AND membership_version>? ORDER BY membership_version").bind(&vault).bind(from).fetch_all(&state.db).await.map_err(ApiError::internal)?;
    let manifests = rows
        .into_iter()
        .map(|row| {
            let version = row.get::<i64, _>("membership_version");
            let previous_digest = row.get::<Option<String>, _>("previous_digest");
            let stored_json = row.get::<String, _>("manifest_json");
            let signature = row.get::<String, _>("signature");
            let manifest_record = membership_record_from_storage(
                &vault,
                version,
                previous_digest.as_deref(),
                &stored_json,
                &signature,
            )?;
            Ok::<Value, ApiError>(json!({
                "membership_version": version,
                "previous_digest": previous_digest,
                "manifest": manifest_record,
                "digest": row.get::<String, _>("digest"),
                "signer_device_id": row.get::<String, _>("signer_device_id"),
                "signature": signature,
                "created_at": row.get::<String, _>("created_at"),
            }))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    Ok(Json(json!({"manifests":manifests})))
}

fn membership_record_from_storage(
    vault_id: &str,
    membership_version: i64,
    previous_digest: Option<&str>,
    stored_json: &str,
    signature: &str,
) -> Result<Value, ApiError> {
    let stored: Value = serde_json::from_str(stored_json).map_err(ApiError::internal)?;
    let manifest = stored
        .get("manifest")
        .ok_or_else(|| ApiError::internal("stored membership manifest is missing its payload"))?;
    auth::signed_membership_record_value(
        vault_id,
        Value::from(membership_version),
        previous_digest
            .map(|digest| Value::String(digest.to_owned()))
            .unwrap_or(Value::Null),
        manifest,
        signature,
    )
}

pub async fn rotate_key(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Json(req): Json<RotateRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(repository.rotate_vault_key(&user, &vault, req).await?));
    }
    rotate_key_request(state, user, vault, req, None).await
}

pub async fn transfer_ownership(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Json(req): Json<OwnershipTransferRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    let transfer_to = req.new_owner_user_id.clone();
    let rotation = RotateRequest {
        new_epoch: req.new_epoch,
        membership: req.membership,
        key_envelopes: req.key_envelopes,
    };
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(
            repository
                .transfer_vault_ownership(&user, &vault, transfer_to, rotation)
                .await?,
        ));
    }
    rotate_key_request(state, user, vault, rotation, Some(transfer_to)).await
}

async fn rotate_key_request(
    state: AppState,
    user: AuthUser,
    vault: String,
    req: RotateRequest,
    transfer_to: Option<String>,
) -> Result<Json<Value>, ApiError> {
    if transfer_to
        .as_deref()
        .is_some_and(|target| !crate::is_canonical_uuid(target) || target == user.user_id)
    {
        return Err(ApiError::bad_request(
            "INVALID_OWNER_TRANSFER",
            "new owner must be a different canonical user ID",
        ));
    }
    let (role, epoch, version) = crate::require_vault(&state, &user.user_id, &vault, true).await?;
    if role != "owner" {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "owner role is required",
        ));
    }
    if req.new_epoch != epoch + 1 {
        return Err(ApiError::conflict(
            "KEY_EPOCH_OUTDATED",
            "key epoch must advance by one",
        ));
    }
    if req.key_envelopes.is_empty() || req.key_envelopes.len() > 1000 {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "key envelope list is invalid",
        ));
    }
    let owner = user.user_id.clone();
    let (digest, full) = signed_manifest(
        &state,
        &user,
        &vault,
        &req.membership,
        transfer_to.as_deref(),
    )
    .await?;
    if req.membership.membership_version != version + 1 {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "membership version must advance by one",
        ));
    }
    if req
        .membership
        .manifest
        .get("key_epoch")
        .and_then(Value::as_i64)
        != Some(req.new_epoch)
    {
        return Err(ApiError::invalid_envelope(
            "rotation membership manifest key epoch does not match the requested epoch",
        ));
    }
    let display_name_envelope = req
        .membership
        .manifest
        .get("display_name_envelope")
        .ok_or_else(|| {
            ApiError::invalid_envelope(
                "rotation membership must include a display name envelope for the new epoch",
            )
        })?;
    auth::validate_display_name_envelope(display_name_envelope)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (tx_role, tx_epoch, tx_version) =
        crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault).await?;
    if tx_role != "owner" {
        return Err(ApiError::forbidden(
            "VAULT_ROLE_REQUIRED",
            "owner role is required",
        ));
    }
    if req.new_epoch != tx_epoch + 1 || req.membership.membership_version != tx_version + 1 {
        return Err(ApiError::conflict(
            "KEY_EPOCH_OUTDATED",
            "vault epoch or membership changed; retry with a current signed manifest",
        ));
    }
    let current_rows = sqlx::query("SELECT user_id,role,state FROM vault_members WHERE vault_id=?")
        .bind(&vault)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let current_states: std::collections::HashMap<String, String> = current_rows
        .iter()
        .map(|r| (r.get("user_id"), r.get("state")))
        .collect();
    let current_roles: std::collections::HashMap<String, String> = current_rows
        .iter()
        .map(|r| (r.get("user_id"), r.get("role")))
        .collect();
    let current_users: std::collections::HashSet<String> = current_states.keys().cloned().collect();
    let members = req
        .membership
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .ok_or_else(|| ApiError::invalid_envelope("rotation membership member list is invalid"))?;
    let mut desired = std::collections::HashMap::<String, (String, String)>::new();
    for m in members {
        let id = m
            .get("user_id")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member id is invalid"))?
            .to_owned();
        let member_role = m
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member role is invalid"))?
            .to_owned();
        let member_state = m
            .get("state")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member state is invalid"))?
            .to_owned();
        if desired.insert(id, (member_role, member_state)).is_some() {
            return Err(ApiError::invalid_envelope(
                "rotation membership contains duplicate users",
            ));
        }
    }
    if current_users != desired.keys().cloned().collect() {
        return Err(ApiError::invalid_envelope(
            "rotation must describe every existing member; add new accounts through invitations first",
        ));
    }
    if let Some(new_owner_id) = transfer_to.as_deref() {
        validate_owner_transfer_member_transition(
            &owner,
            new_owner_id,
            &current_roles,
            &current_states,
            &desired,
        )?;
    }
    let mut membership_audit_changes = Vec::new();
    for (member_id, (next_role, next_state)) in &desired {
        let current_state = current_states
            .get(member_id)
            .map(String::as_str)
            .unwrap_or_default();
        // A pending database grant remains pending through key rotation. Its
        // old token becomes stale; a fresh invitation is required. Revoked
        // users also need a fresh invitation before access can return.
        let next_acl_state = rotated_acl_state(current_state, next_state).map_err(|_| {
            ApiError::invalid_envelope(
                "rotation cannot grant or reactivate membership outside the invitation flow",
            )
        })?;
        let current_role = current_roles.get(member_id).map(String::as_str);
        // A target that becomes revoked gets one revocation event, even if its
        // role also changes in the same signed membership rotation.
        let action = if current_state != "revoked" && next_acl_state == "revoked" {
            Some("vault.member_revoked")
        } else if current_role != Some(next_role.as_str()) {
            Some("vault.member_role_changed")
        } else {
            None
        };
        if let Some(action) = action {
            membership_audit_changes.push((member_id, action));
        }
    }
    let mut recipient_users = std::collections::HashMap::<String, String>::new();
    for (member_id, (_, status)) in &desired {
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
                .bind(member_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.is_none()
            || (*status == "active" && account_status.as_deref() != Some("active"))
        {
            return Err(ApiError::invalid_envelope(
                "active membership references an unavailable account",
            ));
        }
        if status == "active" {
            let devices =
                sqlx::query("SELECT device_id FROM devices WHERE user_id=? AND status='active'")
                    .bind(member_id)
                    .fetch_all(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            for device in devices {
                recipient_users.insert(device.get("device_id"), member_id.clone());
            }
        }
    }
    if recipient_users.is_empty() || recipient_users.len() > 1000 {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "active member device set is empty or exceeds the rotation limit",
        ));
    }
    if let Some(new_owner_id) = transfer_to.as_deref()
        && !recipient_users
            .values()
            .any(|member_id| member_id == new_owner_id)
    {
        return Err(ApiError::conflict(
            "OWNER_TRANSFER_TARGET_INVALID",
            "new owner must have at least one active device to receive the rotated key",
        ));
    }
    let expected: std::collections::HashSet<String> = recipient_users.keys().cloned().collect();
    let supplied: std::collections::HashSet<String> = req
        .key_envelopes
        .iter()
        .map(|e| e.recipient_device_id.clone())
        .collect();
    if supplied.len() != req.key_envelopes.len() || supplied != expected {
        return Err(ApiError::invalid_envelope(
            "rotation must include exactly one key envelope for every active device in the signed membership manifest",
        ));
    }
    let mut validated = Vec::with_capacity(req.key_envelopes.len());
    for item in req.key_envelopes {
        let Some(member) = recipient_users.get(&item.recipient_device_id).cloned() else {
            return Err(ApiError::bad_request(
                "INVALID_KEY_RECIPIENT",
                "key envelope recipient is not an active member device",
            ));
        };
        if !crate::is_canonical_uuid(&item.recipient_device_id)
            || item.key_epoch.as_i64() != Some(req.new_epoch)
            || item.membership_version.as_i64() != Some(req.membership.membership_version)
            || !item.envelope.is_object()
            || item.envelope.to_string().len() > 64 * 1024
        {
            return Err(ApiError::invalid_envelope(
                "rotation key envelope context is invalid",
            ));
        }
        let signer=sqlx::query("SELECT d.user_id,d.signing_public_key,d.status,vm.role FROM devices d JOIN vault_members vm ON vm.user_id=d.user_id WHERE d.device_id=? AND vm.vault_id=? AND vm.state='active'").bind(&item.signer_device_id).bind(&vault).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?.ok_or_else(||ApiError::forbidden("VAULT_ROLE_REQUIRED","key envelope signer is not a vault member"))?;
        if signer.get::<String, _>("user_id") != owner
            || signer.get::<String, _>("status") != "active"
            || signer.get::<String, _>("role") != "owner"
        {
            return Err(ApiError::forbidden(
                "VAULT_ROLE_REQUIRED",
                "only an owner device can sign a rotation key envelope",
            ));
        }
        let signed = json!({"vault_id":vault,"recipient_device_id":item.recipient_device_id,"key_epoch":item.key_epoch,"membership_version":item.membership_version,"envelope":item.envelope});
        auth::verify_key_signature(
            &signer.get::<String, _>("signing_public_key"),
            &item.signature,
            &jcs(&signed)?,
        )?;
        validated.push((item, member));
    }
    persist_manifest(&mut tx, &vault, &user, &req.membership, &digest, &full).await?;
    for (member_id, (member_role, member_state)) in &desired {
        let current_state = current_states
            .get(member_id)
            .map(String::as_str)
            .unwrap_or_default();
        let acl_state = rotated_acl_state(current_state, member_state)
            .map_err(|_| ApiError::internal("validated rotation state transition changed"))?;
        sqlx::query("UPDATE vault_members SET role=?,state=? WHERE vault_id=? AND user_id=?")
            .bind(member_role)
            .bind(acl_state)
            .bind(&vault)
            .bind(member_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    if let Some(new_owner_id) = transfer_to.as_deref() {
        let changed = sqlx::query(
            "UPDATE vaults SET active_epoch=?,owner_user_id=? WHERE vault_id=? AND owner_user_id=?",
        )
        .bind(req.new_epoch)
        .bind(new_owner_id)
        .bind(&vault)
        .bind(&owner)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "OWNER_TRANSFER_STALE",
                "vault ownership changed; refresh the signed membership before retrying",
            ));
        }
    } else {
        sqlx::query("UPDATE vaults SET active_epoch=? WHERE vault_id=?")
            .bind(req.new_epoch)
            .bind(&vault)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    for (item, member) in validated {
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?)").bind(&vault).bind(req.new_epoch).bind(member).bind(item.recipient_device_id).bind(item.envelope.to_string()).bind(item.signature).bind(item.signer_device_id).bind(req.membership.membership_version).execute(&mut *tx).await.map_err(ApiError::internal)?;
    }
    for (member_id, action) in membership_audit_changes {
        crate::audit::record_vault_event_tx(
            &mut tx,
            &vault,
            Some(&user.user_id),
            Some(&user.device_id),
            action,
            "membership",
            Some(member_id),
            crate::audit::AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await?;
    }
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault,
        Some(&user.user_id),
        Some(&user.device_id),
        "vault.key_rotated",
        "vault",
        Some(&vault),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    if let Some(new_owner_id) = transfer_to.as_deref() {
        crate::audit::record_vault_event_tx(
            &mut tx,
            &vault,
            Some(&user.user_id),
            Some(&user.device_id),
            "vault.ownership_transferred",
            "membership",
            Some(new_owner_id),
            crate::audit::AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await?;
    }
    let resulting_owner = transfer_to.as_deref().unwrap_or(&owner);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"vault_id":vault,"owner_user_id":resulting_owner,"active_key_epoch":req.new_epoch,"membership_version":req.membership.membership_version,"status":"active"}),
    ))
}

pub async fn delete_vault(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path(vault): Path<String>,
    Json(request): Json<VaultDeletionRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    let verified_hash =
        verify_deletion_step_up(&state, &user, &request.login_verifier, peer).await?;
    if let Some(repository) = state.pg_vault_deletion.as_ref() {
        return Ok(Json(
            repository
                .delete_vault(
                    &user,
                    &vault,
                    &verified_hash,
                    state.config.vault_deletion_grace_seconds,
                    state.auth_rate_key.as_ref(),
                )
                .await?,
        ));
    }
    let now = Utc::now().timestamp();
    let actor_hash = deletion_actor_hash(&state, &user)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (status, role) =
        validate_lifecycle_owner_tx(&mut tx, &user, &vault, &verified_hash).await?;
    let (requested_at, purge_after) = if status == "active" {
        let requested_at = now;
        let purge_after = now.saturating_add(state.config.vault_deletion_grace_seconds);
        sqlx::query("INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,?)")
            .bind(&vault)
            .bind(requested_at)
            .bind(purge_after)
            .bind(actor_hash)
            .execute(&mut *tx)
            .await
            .map_err(|error| {
                if error
                    .as_database_error()
                    .is_some_and(|database_error| database_error.is_unique_violation())
                {
                    ApiError::conflict(
                        "VAULT_DELETION_PENDING",
                        "vault deletion is already pending",
                    )
                } else {
                    ApiError::internal(error)
                }
            })?;
        let changed =
            sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=? AND state='active'")
                .bind(&vault)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "VAULT_DELETION_TRANSITION_CONFLICT",
                "vault lifecycle changed; retry the request",
            ));
        }
        crate::audit::record_vault_event_tx(
            &mut tx,
            &vault,
            Some(&user.user_id),
            Some(&user.device_id),
            "vault.deletion_requested",
            "vault",
            Some(&vault),
            crate::audit::AuditSource::Api,
            now,
        )
        .await?;
        (requested_at, purge_after)
    } else if status == "deleting" {
        sqlx::query_as::<_, (i64, i64)>("SELECT requested_at,purge_after FROM vault_deletion_requests WHERE vault_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
            .bind(&vault)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("deleting vault has no pending deletion request"))?
    } else {
        return Err(ApiError::not_found());
    };
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(vault_lifecycle_dto(
        &vault,
        &role,
        "deleting",
        Some(requested_at),
        Some(purge_after),
    )))
}

pub async fn cancel_vault_deletion(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Path(vault): Path<String>,
    Json(request): Json<VaultDeletionRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    let verified_hash =
        verify_deletion_step_up(&state, &user, &request.login_verifier, peer).await?;
    if let Some(repository) = state.pg_vault_deletion.as_ref() {
        return Ok(Json(
            repository
                .cancel_vault_deletion(&user, &vault, &verified_hash)
                .await?,
        ));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (status, role) =
        validate_lifecycle_owner_tx(&mut tx, &user, &vault, &verified_hash).await?;
    if status == "active" {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(vault_lifecycle_dto(
            &vault, &role, "active", None, None,
        )));
    }
    if status != "deleting" {
        return Err(ApiError::not_found());
    }
    let pending = sqlx::query_as::<_, (i64, i64)>(
        "SELECT request_id,purge_after FROM vault_deletion_requests WHERE vault_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
    )
    .bind(&vault)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("deleting vault has no pending deletion request"))?;
    let (request_id, purge_after) = pending;
    let now = Utc::now().timestamp();
    if now >= purge_after {
        return Err(ApiError::gone(
            "VAULT_DELETION_WINDOW_EXPIRED",
            "vault deletion can no longer be cancelled",
        ));
    }
    let canceled = sqlx::query("UPDATE vault_deletion_requests SET cancelled_at=? WHERE request_id=? AND cancelled_at IS NULL AND purged_at IS NULL AND purge_after>?")
        .bind(now)
        .bind(request_id)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if canceled.rows_affected() != 1 {
        return Err(ApiError::gone(
            "VAULT_DELETION_WINDOW_EXPIRED",
            "vault deletion can no longer be cancelled",
        ));
    }
    let restored =
        sqlx::query("UPDATE vaults SET state='active' WHERE vault_id=? AND state='deleting'")
            .bind(&vault)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if restored.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "VAULT_DELETION_TRANSITION_CONFLICT",
            "vault lifecycle changed; retry the request",
        ));
    }
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault,
        Some(&user.user_id),
        Some(&user.device_id),
        "vault.deletion_cancelled",
        "vault",
        Some(&vault),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(vault_lifecycle_dto(
        &vault, &role, "active", None, None,
    )))
}

/// Finalizes due vault deletions under SQLite's writer lock. Deletion audit
/// records intentionally outlive the cascading vault delete and are pruned
/// only after their own retention period.
pub(crate) async fn purge_due_vault_deletions(
    state: &AppState,
    now_epoch: i64,
) -> Result<(), ApiError> {
    #[cfg(test)]
    {
        purge_due_vault_deletions_inner(state, now_epoch, None).await
    }
    #[cfg(not(test))]
    {
        purge_due_vault_deletions_inner(state, now_epoch).await
    }
}

async fn purge_due_vault_deletions_inner(
    state: &AppState,
    now_epoch: i64,
    #[cfg(test)] test_hooks: Option<&crate::recovery::RecoveryPurgeTestHooks>,
) -> Result<(), ApiError> {
    let due = sqlx::query_as::<_, (i64, String)>(
        "SELECT request_id,vault_id FROM vault_deletion_requests WHERE cancelled_at IS NULL AND purged_at IS NULL AND purge_after<=? ORDER BY purge_after,request_id",
    )
    .bind(now_epoch)
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;

    for (request_id, vault_id) in due {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

        #[cfg(test)]
        if let Some(gate) =
            test_hooks.and_then(|hooks| hooks.purge_before_writer_reservation.as_ref())
        {
            gate.pause().await;
        }

        let locked = sqlx::query("UPDATE vault_deletion_requests SET request_id=request_id WHERE request_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
            .bind(request_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if locked.rows_affected() == 0 {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        }
        let pending: Option<i64> = sqlx::query_scalar(
            "SELECT purge_after FROM vault_deletion_requests WHERE request_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
        )
        .bind(request_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(purge_after) = pending else {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        };
        if purge_after > now_epoch {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        }

        #[cfg(test)]
        if let Some(gate) = test_hooks.and_then(|hooks| hooks.purge_writer_reserved.as_ref()) {
            gate.pause().await;
        }

        let vault_state: Option<String> =
            sqlx::query_scalar("SELECT state FROM vaults WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        match vault_state.as_deref() {
            Some("deleting") => {
                sqlx::query("UPDATE vault_deletion_requests SET purged_at=? WHERE request_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
                    .bind(now_epoch)
                    .bind(request_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                crate::audit::record_vault_event_tx(
                    &mut tx,
                    &vault_id,
                    None,
                    None,
                    "vault.purged",
                    "vault",
                    Some(&vault_id),
                    crate::audit::AuditSource::Maintenance,
                    now_epoch,
                )
                .await?;
                // The vault's audit rows outlive the vault itself, but their
                // actor identifiers must not outlive the membership directory.
                sqlx::query("UPDATE audit_events SET actor_user_id=NULL,actor_device_id=NULL WHERE scope_type='vault' AND scope_id=?")
                    .bind(&vault_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                state
                    .object_store
                    .queue_completing_uploads_for_vault_tx(
                        &mut tx,
                        &state.instance.instance_id,
                        &vault_id,
                        now_epoch,
                    )
                    .await?;
                let external_objects = sqlx::query(
                    "SELECT storage_backend,storage_key,storage_store_id,size,sha256 FROM blob_objects WHERE vault_id=? AND storage_backend IN ('s3','filesystem')",
                )
                .bind(&vault_id)
                .fetch_all(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                for object in external_objects {
                    let key: String = object.get("storage_key");
                    let storage_backend: String = object.get("storage_backend");
                    let store_id: String = object.get("storage_store_id");
                    let size: i64 = object.get("size");
                    let digest: String = object.get("sha256");
                    crate::object_store::ObjectStore::queue_external_delete_tx(
                        &mut tx,
                        &storage_backend,
                        &store_id,
                        &key,
                        size,
                        &digest,
                        now_epoch,
                    )
                    .await?;
                }
                let deleted =
                    sqlx::query("DELETE FROM vaults WHERE vault_id=? AND state='deleting'")
                        .bind(&vault_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                if deleted.rows_affected() != 1 {
                    return Err(ApiError::internal(
                        "due vault deletion did not remove its deleting vault",
                    ));
                }
            }
            None => {
                // A prior operator or old binary may already have removed the
                // vault. Complete the retained audit marker idempotently.
                sqlx::query("UPDATE vault_deletion_requests SET purged_at=? WHERE request_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
                    .bind(now_epoch)
                    .bind(request_id)
                    .execute(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            Some("active") => {
                // Never purge an active vault because of a stale or corrupted
                // request row; leave it pending for operator investigation.
                return Err(ApiError::internal(
                    "pending deletion request references an active vault",
                ));
            }
            Some(_) => {
                return Err(ApiError::internal(
                    "vault has an unsupported lifecycle state",
                ));
            }
        }
        tx.commit().await.map_err(ApiError::internal)?;
    }

    let audit_cutoff = now_epoch.saturating_sub(state.config.audit_retention_days * 86_400);
    sqlx::query("DELETE FROM vault_deletion_requests WHERE (cancelled_at IS NOT NULL AND cancelled_at<?) OR (purged_at IS NOT NULL AND purged_at<?)")
        .bind(audit_cutoff)
        .bind(audit_cutoff)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
pub(crate) async fn purge_due_vault_deletions_with_test_hooks(
    state: &AppState,
    now_epoch: i64,
    hooks: &crate::recovery::RecoveryPurgeTestHooks,
) -> Result<(), ApiError> {
    purge_due_vault_deletions_inner(state, now_epoch, Some(hooks)).await
}

#[cfg(test)]
mod tests {
    use super::{
        InvitationStatus, consume_invitation_tx, invitation_lifetime_seconds, invitation_status,
        membership_record_from_storage, purge_due_vault_deletions, rotated_acl_state,
        validate_invitation_membership, validate_owner_transfer_member_transition,
        verify_deletion_step_up,
    };
    use crate::{
        AuthRateLimits, Config,
        auth::{self, AuthUser},
        now_rfc3339, open_state,
    };
    use axum::{
        extract::{Path, State},
        http::{HeaderMap, HeaderValue, StatusCode, header},
        response::IntoResponse,
    };
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use chrono::{DateTime, Duration, Utc};
    use serde_json::{Value, json};
    use sqlx::Row;
    use std::{borrow::Cow, net::SocketAddr, path::PathBuf};
    use uuid::Uuid;

    const OWNER: &str = "11111111-1111-4111-8111-111111111111";
    const EDITOR: &str = "22222222-2222-4222-8222-222222222222";
    const VAULT: &str = "33333333-3333-4333-8333-333333333333";

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

    async fn test_state(label: &str) -> crate::AppState {
        let data_dir = std::env::temp_dir().join(format!("atermius-{label}-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        open_state(&database_url, test_config(data_dir))
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn member_roster_and_authorization_share_one_read_snapshot() {
        let state = test_state("member-roster-read-snapshot").await;
        let owner = Uuid::new_v4().to_string();
        let reader = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let session = Uuid::new_v4().to_string();
        let created_at = now_rfc3339();
        let access_hash = crate::sha256_hex(b"member-roster-test-access");
        for (user_id, username) in [
            (&owner, "roster-owner@example.test"),
            (&reader, "roster-reader@example.test"),
        ] {
            sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
                .bind(user_id)
                .bind(username)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&owner)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        for (user_id, role) in [(&owner, "owner"), (&reader, "editor")] {
            sqlx::query(
                "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,?,'active',?)",
            )
            .bind(&vault)
            .bind(user_id)
            .bind(role)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        }
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'reader','sign','box',?)")
            .bind(&device)
            .bind(&reader)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session)
            .bind(&reader)
            .bind(&device)
            .bind(Uuid::new_v4().to_string())
            .bind(&access_hash)
            .bind(crate::sha256_hex(b"member-roster-test-refresh"))
            .bind((Utc::now() + Duration::hours(1)).to_rfc3339())
            .bind((Utc::now() + Duration::days(1)).to_rfc3339())
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        let user = AuthUser {
            user_id: reader.clone(),
            device_id: device.clone(),
            session_id: session,
            access_hash,
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let mut read_tx = state.db.begin().await.unwrap();
        crate::require_active_session_device_read_tx(&mut read_tx, &user)
            .await
            .unwrap();
        crate::require_vault_read_snapshot_tx(&mut read_tx, &reader, &vault)
            .await
            .unwrap();

        // This represents a concurrent Owner revocation after the request's
        // authorization snapshot was established but before the roster query.
        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=? AND user_id=?")
            .bind(&vault)
            .bind(&reader)
            .execute(&state.db)
            .await
            .unwrap();

        let rows = super::member_rows_in_read_snapshot(&mut read_tx, &vault)
            .await
            .unwrap();
        let reader_row = rows
            .iter()
            .find(|row| row.get::<String, _>("user_id") == reader)
            .unwrap();
        assert_eq!(reader_row.get::<String, _>("state"), "active");
        assert_eq!(rows.len(), 2);
        read_tx.commit().await.unwrap();

        // A request whose authorization snapshot starts after the revocation
        // must not read the roster.
        let mut after_revoke_tx = state.db.begin().await.unwrap();
        crate::require_active_session_device_read_tx(&mut after_revoke_tx, &user)
            .await
            .unwrap();
        let denied = crate::require_vault_read_snapshot_tx(&mut after_revoke_tx, &reader, &vault)
            .await
            .unwrap_err();
        assert_eq!(denied.status, StatusCode::NOT_FOUND);
        drop(after_revoke_tx);

        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn vault_devices_project_redaction_reports_only_for_active_live_members() {
        let state = test_state("vault-device-redaction-report").await;
        let owner = Uuid::new_v4().to_string();
        let active = Uuid::new_v4().to_string();
        let invalidated = Uuid::new_v4().to_string();
        let inactive = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let owner_device = Uuid::new_v4().to_string();
        let active_device = Uuid::new_v4().to_string();
        let invalidated_device = Uuid::new_v4().to_string();
        let inactive_device = Uuid::new_v4().to_string();
        let archived_device = Uuid::new_v4().to_string();
        let session = Uuid::new_v4().to_string();
        let token = format!("vault-device-redaction-{}", Uuid::new_v4());
        let access_hash = crate::sha256_hex(token.as_bytes());
        let created_at = now_rfc3339();

        for (account_id, username) in [
            (&owner, "redaction-owner@example.test"),
            (&active, "redaction-active@example.test"),
            (&invalidated, "redaction-invalidated@example.test"),
            (&inactive, "redaction-inactive@example.test"),
        ] {
            sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
                .bind(account_id)
                .bind(username)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&owner)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        for (account_id, role, membership_state) in [
            (&owner, "owner", "active"),
            (&active, "editor", "active"),
            (&invalidated, "editor", "active"),
            (&inactive, "editor", "revoked"),
        ] {
            sqlx::query(
                "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,?,?,?)",
            )
            .bind(&vault)
            .bind(account_id)
            .bind(role)
            .bind(membership_state)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        }
        for (account_id, device_id, name) in [
            (&owner, &owner_device, "owner"),
            (&active, &active_device, "active report"),
            (&invalidated, &invalidated_device, "invalidated report"),
            (&inactive, &inactive_device, "inactive membership report"),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,'sign','box',?)")
                .bind(device_id)
                .bind(account_id)
                .bind(name)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session)
            .bind(&owner)
            .bind(&owner_device)
            .bind(Uuid::new_v4().to_string())
            .bind(&access_hash)
            .bind(crate::sha256_hex(b"vault-device-redaction-refresh"))
            .bind((Utc::now() + Duration::hours(1)).to_rfc3339())
            .bind((Utc::now() + Duration::days(1)).to_rfc3339())
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        for (account_id, device_id, revision, signature, invalidated_at) in [
            (&active, &active_device, 3_i64, "active-signature", None),
            (
                &invalidated,
                &invalidated_device,
                7_i64,
                "invalidated-signature",
                Some("2025-01-02T03:04:05Z"),
            ),
            (
                &inactive,
                &inactive_device,
                9_i64,
                "inactive-signature",
                None,
            ),
        ] {
            sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,user_id,revision,sync_redaction_version,signature,updated_at,invalidated_at) VALUES(?,?,?,1,?,?,?)")
                .bind(device_id)
                .bind(account_id)
                .bind(revision)
                .bind(signature)
                .bind(&created_at)
                .bind(invalidated_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vault_device_archives(vault_id,user_id,device_id,signing_public_key,encryption_public_key,archived_at) VALUES(?,?,?,'archive-sign','archive-box',?)")
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .bind(&archived_device)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let axum::Json(body) =
            super::vault_devices(State(state.clone()), headers, Path(vault.clone()))
                .await
                .unwrap();
        let devices = body["devices"].as_array().unwrap();
        let find_device = |device_id: &str| {
            devices
                .iter()
                .find(|device| device["device_id"] == device_id)
                .unwrap()
        };
        assert_eq!(
            find_device(&active_device)["redaction_capability_report"],
            json!({
                "format": crate::redaction_capabilities::REPORT_FORMAT,
                "account_id": active,
                "device_id": active_device,
                "revision": 3,
                "sync_redaction_version": 1,
                "signature": "active-signature",
                "invalidated_at": null,
            })
        );
        assert_eq!(
            find_device(&invalidated_device)["redaction_capability_report"]["invalidated_at"],
            "2025-01-02T03:04:05Z"
        );
        assert_eq!(
            find_device(&inactive_device)["redaction_capability_report"],
            Value::Null
        );
        assert_eq!(
            find_device(&archived_device)["redaction_capability_report"],
            Value::Null
        );
        assert_eq!(find_device(&active_device)["membership_status"], "active");
        assert_eq!(
            find_device(&inactive_device)["membership_status"],
            "revoked"
        );

        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn invitation_manifest_adds_active_signed_grant_without_changing_acl() {
        let members = vec![
            json!({"user_id": OWNER, "role":"owner", "state":"active"}),
            json!({"user_id": EDITOR, "role":"editor", "state":"active"}),
        ];
        let current = vec![(OWNER.into(), "owner".into(), "active".into())];
        assert!(validate_invitation_membership(&members, &current, EDITOR, "editor").is_ok());
    }

    #[test]
    fn display_name_envelope_has_bounded_v1_shape() {
        let valid = json!({
            "version": 1,
            "nonce": URL_SAFE_NO_PAD.encode([7_u8; 24]),
            "ciphertext": URL_SAFE_NO_PAD.encode([9_u8; 16]),
        });
        assert!(auth::validate_display_name_envelope(&valid).is_ok());

        let wrong_version = json!({
            "version": 2,
            "nonce": URL_SAFE_NO_PAD.encode([7_u8; 24]),
            "ciphertext": URL_SAFE_NO_PAD.encode([9_u8; 16]),
        });
        assert!(auth::validate_display_name_envelope(&wrong_version).is_err());

        let short_nonce = json!({
            "version": 1,
            "nonce": URL_SAFE_NO_PAD.encode([7_u8; 23]),
            "ciphertext": URL_SAFE_NO_PAD.encode([9_u8; 16]),
        });
        assert!(auth::validate_display_name_envelope(&short_nonce).is_err());

        let short_ciphertext = json!({
            "version": 1,
            "nonce": URL_SAFE_NO_PAD.encode([7_u8; 24]),
            "ciphertext": URL_SAFE_NO_PAD.encode([9_u8; 15]),
        });
        assert!(auth::validate_display_name_envelope(&short_ciphertext).is_err());

        let extended = json!({
            "version": 1,
            "nonce": URL_SAFE_NO_PAD.encode([7_u8; 24]),
            "ciphertext": URL_SAFE_NO_PAD.encode([9_u8; 16]),
            "key_epoch": 2,
        });
        assert!(auth::validate_display_name_envelope(&extended).is_err());
    }

    #[test]
    fn invitation_manifest_preserves_existing_members_and_pending_grants() {
        let viewer = "44444444-4444-4444-8444-444444444444";
        let members = vec![
            json!({"user_id": OWNER, "role":"owner", "state":"active"}),
            json!({"user_id": EDITOR, "role":"editor", "state":"active"}),
            json!({"user_id": viewer, "role":"viewer", "state":"active"}),
        ];
        let current = vec![
            (OWNER.into(), "owner".into(), "active".into()),
            (EDITOR.into(), "editor".into(), "invited".into()),
        ];
        assert!(validate_invitation_membership(&members, &current, viewer, "viewer").is_ok());

        let altered = vec![
            json!({"user_id": OWNER, "role":"owner", "state":"active"}),
            json!({"user_id": EDITOR, "role":"viewer", "state":"active"}),
            json!({"user_id": viewer, "role":"viewer", "state":"active"}),
        ];
        assert!(validate_invitation_membership(&altered, &current, viewer, "viewer").is_err());
    }

    #[test]
    fn active_member_must_enroll_another_device_instead_of_accepting_invite() {
        let members = vec![json!({
            "user_id": OWNER,
            "role":"owner",
            "state":"active"
        })];
        let current = vec![(OWNER.into(), "owner".into(), "active".into())];
        assert!(validate_invitation_membership(&members, &current, OWNER, "editor").is_err());
    }

    #[test]
    fn membership_response_normalizes_legacy_storage_with_vault_context() {
        let payload = json!({
            "key_epoch": 1,
            "members": [{"user_id": OWNER, "role": "owner", "state": "active"}],
            "signer_device_id": "44444444-4444-4444-8444-444444444444",
        });
        let legacy = json!({
            "membership_version": 1,
            "previous_digest": null,
            "manifest": payload,
            "signature": "signed-by-owner",
        })
        .to_string();

        let response =
            membership_record_from_storage(VAULT, 1, None, &legacy, "signed-by-owner").unwrap();
        assert_eq!(
            response,
            json!({
                "vault_id": VAULT,
                "membership_version": 1,
                "previous_digest": null,
                "manifest": payload,
                "signature": "signed-by-owner",
            })
        );
    }

    #[test]
    fn key_rotation_keeps_pending_invites_pending_and_blocks_reactivation() {
        assert_eq!(rotated_acl_state("invited", "active"), Ok("invited"));
        assert_eq!(rotated_acl_state("invited", "revoked"), Ok("revoked"));
        assert_eq!(rotated_acl_state("revoked", "active"), Err(()));
        assert_eq!(rotated_acl_state("active", "revoked"), Ok("revoked"));
    }

    #[test]
    fn owner_transfer_requires_active_target_and_no_other_membership_changes() {
        let current_roles = std::collections::HashMap::from([
            (OWNER.to_owned(), "owner".to_owned()),
            (EDITOR.to_owned(), "editor".to_owned()),
            (
                "44444444-4444-4444-8444-444444444444".to_owned(),
                "viewer".to_owned(),
            ),
        ]);
        let current_states = std::collections::HashMap::from([
            (OWNER.to_owned(), "active".to_owned()),
            (EDITOR.to_owned(), "active".to_owned()),
            (
                "44444444-4444-4444-8444-444444444444".to_owned(),
                "invited".to_owned(),
            ),
        ]);
        let valid = std::collections::HashMap::from([
            (OWNER.to_owned(), ("editor".to_owned(), "active".to_owned())),
            (EDITOR.to_owned(), ("owner".to_owned(), "active".to_owned())),
            (
                "44444444-4444-4444-8444-444444444444".to_owned(),
                ("viewer".to_owned(), "active".to_owned()),
            ),
        ]);
        assert!(
            validate_owner_transfer_member_transition(
                OWNER,
                EDITOR,
                &current_roles,
                &current_states,
                &valid,
            )
            .is_ok()
        );

        let pending_target = "44444444-4444-4444-8444-444444444444";
        let invalid_pending = std::collections::HashMap::from([
            (OWNER.to_owned(), ("editor".to_owned(), "active".to_owned())),
            (
                EDITOR.to_owned(),
                ("editor".to_owned(), "active".to_owned()),
            ),
            (
                pending_target.to_owned(),
                ("owner".to_owned(), "active".to_owned()),
            ),
        ]);
        assert!(
            validate_owner_transfer_member_transition(
                OWNER,
                pending_target,
                &current_roles,
                &current_states,
                &invalid_pending,
            )
            .is_err()
        );

        let mut unrelated_change = valid;
        unrelated_change.insert(
            pending_target.to_owned(),
            ("editor".to_owned(), "active".to_owned()),
        );
        assert!(
            validate_owner_transfer_member_transition(
                OWNER,
                EDITOR,
                &current_roles,
                &current_states,
                &unrelated_change,
            )
            .is_err()
        );
    }

    #[test]
    fn vault_invitation_ttl_is_explicitly_bounded() {
        assert_eq!(invitation_lifetime_seconds(None).unwrap(), 7 * 24 * 3600);
        assert_eq!(invitation_lifetime_seconds(Some(60)).unwrap(), 60);
        assert_eq!(
            invitation_lifetime_seconds(Some(30 * 24 * 3600)).unwrap(),
            30 * 24 * 3600
        );
        assert!(invitation_lifetime_seconds(Some(59)).is_err());
        assert!(invitation_lifetime_seconds(Some(30 * 24 * 3600 + 1)).is_err());
    }

    #[test]
    fn invitation_status_is_fail_closed_and_expiry_precedes_staleness() {
        let now = DateTime::parse_from_rfc3339("2026-10-01T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc);
        let created_at = "2026-10-01T11:00:00Z";
        let future_expiry = "2026-10-02T12:00:00Z";
        let expired_at = "2026-10-01T11:59:59Z";
        let current_envelope = json!({"key_epoch": 4, "membership_version": 12}).to_string();
        let stale_epoch = json!({"key_epoch": 3, "membership_version": 12}).to_string();
        let stale_version = json!({"key_epoch": 4, "membership_version": 11}).to_string();

        assert_eq!(
            invitation_status(
                Some(4),
                Some(created_at),
                Some(future_expiry),
                Some(&current_envelope),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::Pending
        );
        assert_eq!(
            invitation_status(
                Some(4),
                Some(created_at),
                Some(expired_at),
                Some(&stale_epoch),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::Expired,
            "expiry must take precedence over stale epoch/version context"
        );
        assert_eq!(
            invitation_status(
                Some(4),
                Some(created_at),
                Some(future_expiry),
                Some(&stale_epoch),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::Stale
        );
        assert_eq!(
            invitation_status(
                Some(4),
                Some(created_at),
                Some(future_expiry),
                Some(&stale_version),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::Stale
        );
        assert_eq!(
            invitation_status(
                None,
                Some(created_at),
                Some(expired_at),
                Some(&current_envelope),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::ReissueRequired,
            "historical rows without an issuance order must not be treated as current"
        );
        assert_eq!(
            invitation_status(None, None, None, None, None, 4, 12, now),
            InvitationStatus::ReissueRequired,
            "an invited ACL without an invitation row needs reissue"
        );
        for recipient_device_status in [None, Some("revoked"), Some("missing")] {
            assert_eq!(
                invitation_status(
                    Some(5),
                    Some(created_at),
                    Some(future_expiry),
                    Some(&current_envelope),
                    recipient_device_status,
                    4,
                    12,
                    now,
                ),
                InvitationStatus::ReissueRequired,
                "an invitation bound to a non-active or missing device needs reissue"
            );
        }
        assert_eq!(
            invitation_status(
                Some(5),
                Some(created_at),
                Some("invalid-expiry"),
                Some(&current_envelope),
                Some("active"),
                4,
                12,
                now,
            ),
            InvitationStatus::ReissueRequired
        );
    }

    #[tokio::test]
    async fn invitation_created_at_migration_preserves_history_as_unknown() {
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        let all = sqlx::migrate!("./migrations");
        let before_created_at = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version < 24)
                    .cloned()
                    .collect(),
            ),
            ..sqlx::migrate::Migrator::DEFAULT
        };
        before_created_at.run(&pool).await.unwrap();

        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('invite-owner','owner@example.test',?)")
            .bind(&now)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('invite-recipient','recipient@example.test',?)")
            .bind(&now)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('invite-vault','invite-owner',?)")
            .bind(&now)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,created_by,expires_at) VALUES('legacy-invite','invite-vault','legacy-token-hash','editor','{}','invite-recipient','invite-owner',?)")
            .bind(&now)
            .execute(&pool)
            .await
            .unwrap();

        let created_at_migration = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version == 24)
                    .cloned()
                    .collect(),
            ),
            ignore_missing: true,
            ..sqlx::migrate::Migrator::DEFAULT
        };
        created_at_migration.run(&pool).await.unwrap();

        let legacy_created_at: Option<String> = sqlx::query_scalar(
            "SELECT created_at FROM invitations WHERE invitation_id='legacy-invite'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(
            legacy_created_at, None,
            "migration must not guess issuance time"
        );
        let legacy_issuance_order: Option<i64> = sqlx::query_scalar(
            "SELECT issuance_order FROM invitations WHERE invitation_id='legacy-invite'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(
            legacy_issuance_order, None,
            "legacy order must remain unknown"
        );
        let index_sql: String = sqlx::query_scalar(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_invitation_pending_recipient_order'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert!(index_sql.contains("recipient_user_id"));
        assert!(index_sql.contains("issuance_order DESC"));
        assert!(index_sql.contains("created_at DESC"));
        assert!(index_sql.contains("accepted_at IS NULL"));

        let new_created_at = "2026-10-01T12:00:00+00:00";
        let first_issuance_order: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(issuance_order),0)+1 FROM invitations WHERE vault_id='invite-vault' AND recipient_user_id='invite-recipient'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(first_issuance_order, 1);
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,created_by,expires_at,created_at,issuance_order) VALUES('new-invite','invite-vault','new-token-hash','editor','{}','invite-recipient','invite-owner',?,?,?)")
            .bind(&now)
            .bind(new_created_at)
            .bind(first_issuance_order)
            .execute(&pool)
            .await
            .unwrap();
        let second_issuance_order: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(issuance_order),0)+1 FROM invitations WHERE vault_id='invite-vault' AND recipient_user_id='invite-recipient'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(second_issuance_order, 2);
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,created_by,expires_at,created_at,issuance_order) VALUES('newest-invite','invite-vault','newest-token-hash','editor','{}','invite-recipient','invite-owner',?,?,?)")
            .bind(&now)
            .bind(new_created_at)
            .bind(second_issuance_order)
            .execute(&pool)
            .await
            .unwrap();
        let newest_id: String = sqlx::query_scalar(
            "SELECT invitation_id FROM invitations WHERE vault_id='invite-vault' AND recipient_user_id='invite-recipient' AND accepted_at IS NULL ORDER BY issuance_order DESC,created_at DESC,invitation_id DESC LIMIT 1",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(newest_id, "newest-invite");
        pool.close().await;
    }

    #[tokio::test]
    async fn invitation_consumption_rechecks_expiry_in_the_atomic_update() {
        let state = test_state("invitation-expiry-race").await;
        let owner = Uuid::new_v4().to_string();
        let recipient = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let invitation = Uuid::new_v4().to_string();
        let created_at = now_rfc3339();
        let expires_at = (Utc::now() + Duration::minutes(2)).to_rfc3339();
        for (user_id, username) in [
            (&owner, "invitation-owner@example.test"),
            (&recipient, "invitation-recipient@example.test"),
        ] {
            sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
                .bind(user_id)
                .bind(username)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&owner)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,created_by,expires_at) VALUES(?,?,'fixture-token-hash','editor','{}',?,?,?)")
            .bind(&invitation)
            .bind(&vault)
            .bind(&recipient)
            .bind(&owner)
            .bind(&expires_at)
            .execute(&state.db)
            .await
            .unwrap();

        let mut tx = state.db.begin().await.unwrap();
        // Model the expiry boundary passing after accept_invitation's initial
        // read/check but before its final token-consumption write.
        sqlx::query(
            "UPDATE invitations SET expires_at='2000-01-01T00:00:00+00:00' WHERE invitation_id=?",
        )
        .bind(&invitation)
        .execute(&mut *tx)
        .await
        .unwrap();
        let error = consume_invitation_tx(&mut tx, &invitation, &recipient, &now_rfc3339())
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::GONE);
        assert_eq!(error.body.code, "INVITATION_EXPIRED");
        tx.rollback().await.unwrap();

        let (accepted_at, persisted_expiry): (Option<String>, String) =
            sqlx::query_as("SELECT accepted_at,expires_at FROM invitations WHERE invitation_id=?")
                .bind(&invitation)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(accepted_at.is_none());
        assert_eq!(persisted_expiry, expires_at);

        let data_dir = state.config.data_dir.clone();
        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn deleting_vault_allows_export_reads_but_rejects_transactional_writes() {
        let state = test_state("vault-delete-acl").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind("owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,created_at) VALUES(?,?,'deleting',?)",
        )
        .bind(&vault)
        .bind(&user)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();

        let mut write_tx = state.db.begin().await.unwrap();
        let write_error = crate::require_vault_write_tx(&mut write_tx, &user, &vault)
            .await
            .unwrap_err();
        assert_eq!(write_error.status, StatusCode::CONFLICT);
        assert_eq!(write_error.body.code, "VAULT_DELETION_PENDING");
        drop(write_tx);

        let mut read_tx = state.db.begin().await.unwrap();
        let (role, _, _, status) = crate::require_vault_read_tx(&mut read_tx, &user, &vault)
            .await
            .unwrap();
        assert_eq!(role, "owner");
        assert_eq!(status, "deleting");
        read_tx.commit().await.unwrap();
    }

    #[tokio::test]
    async fn due_purge_cascades_ciphertext_but_keeps_only_anonymous_audit() {
        let state = test_state("vault-delete-purge").await;
        let user = Uuid::new_v4().to_string();
        let foreign_user = Uuid::new_v4().to_string();
        let foreign_vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let record = Uuid::new_v4().to_string();
        let revision = Uuid::new_v4().to_string();
        let snapshot = Uuid::new_v4().to_string();
        let conflict = Uuid::new_v4().to_string();
        let upload = Uuid::new_v4().to_string();
        let object = Uuid::new_v4().to_string();
        let invite = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        let now_epoch = chrono::Utc::now().timestamp();

        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind("purge-owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&foreign_user)
            .bind("foreign-owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&foreign_vault)
            .bind(&foreign_user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&foreign_vault)
            .bind(&foreign_user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'owner','sign','box',?)")
            .bind(&device)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,created_at) VALUES(?,?,'deleting',?)",
        )
        .bind(&vault)
        .bind(&user)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,1)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,1,?,?, '{}','sig',?,1)")
            .bind(&vault)
            .bind(&user)
            .bind(&device)
            .bind(&device)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,NULL,'{}','digest',1,?,'create',?)")
            .bind(&vault)
            .bind(&record)
            .bind(&revision)
            .bind(&device)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,1)")
            .bind(&vault)
            .bind(&record)
            .bind(&revision)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,1,'create',?,?,'{}',?)")
            .bind(&vault)
            .bind(&record)
            .bind(&revision)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) VALUES(?,? ,?,'1','digest',?,?,1)")
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .bind(&device)
            .bind(&record)
            .bind(&revision)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES(?,?,?,'digest','{}')")
            .bind(&vault)
            .bind(&device)
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,1)")
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation) VALUES(?,?,?,1,'[]',?,?,?)")
            .bind(&snapshot)
            .bind(&vault)
            .bind(&user)
            .bind(&now)
            .bind(&now)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at) VALUES(?,?,?,NULL,'{}','digest',?,?)")
            .bind(&conflict)
            .bind(&vault)
            .bind(&record)
            .bind(&device)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?, ?,1,'hash',1048576,'open',?,?)")
            .bind(&upload)
            .bind(&vault)
            .bind(&user)
            .bind(&object)
            .bind(&now)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'01','hash')")
            .bind(&upload)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,'opaque',6,'digest',?)")
            .bind(&vault)
            .bind(&object)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&revision)
            .bind(&object)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id,recipient_device_id,signer_device_id,created_by,expires_at) VALUES(?,?,'token-hash','editor','{}',?,?,?, ?,?)")
            .bind(&invite)
            .bind(&vault)
            .bind(&user)
            .bind(&device)
            .bind(&device)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,1,'{}','digest',?,'sig',?)")
            .bind(&vault)
            .bind(&device)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,'anonymous-hash')")
            .bind(&vault)
            .bind(now_epoch - 60)
            .bind(now_epoch)
            .execute(&state.db)
            .await
            .unwrap();
        let mut audit_tx = state.db.begin().await.unwrap();
        crate::audit::record_vault_event_tx(
            &mut audit_tx,
            &vault,
            Some(&user),
            Some(&device),
            "vault.deletion_requested",
            "vault",
            Some(&vault),
            crate::audit::AuditSource::Api,
            now_epoch - 60,
        )
        .await
        .unwrap();
        audit_tx.commit().await.unwrap();

        // The retention worker must leave pending entries alone even when
        // their request timestamp is old, while expiring old terminal audit.
        sqlx::query("INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after) VALUES('pending-old-audit',?,?)")
            .bind(now_epoch - 400 * 86_400)
            .bind(now_epoch + 60)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,cancelled_at) VALUES('expired-audit',?,?,?)")
            .bind(now_epoch - 400 * 86_400)
            .bind(now_epoch - 399 * 86_400)
            .bind(now_epoch - 398 * 86_400)
            .execute(&state.db)
            .await
            .unwrap();

        purge_due_vault_deletions(&state, now_epoch).await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM vaults WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        let purged_access = crate::require_vault(&state, &user, &vault, false)
            .await
            .unwrap_err();
        let unrelated_access = crate::require_vault(&state, &user, &foreign_vault, false)
            .await
            .unwrap_err();
        let absent_access =
            crate::require_vault(&state, &user, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", false)
                .await
                .unwrap_err();
        assert_eq!(purged_access.status, StatusCode::NOT_FOUND);
        assert_eq!(purged_access.body.code, "NOT_FOUND");
        assert_eq!(purged_access.body.code, unrelated_access.body.code);
        assert_eq!(unrelated_access.body.code, absent_access.body.code);
        sqlx::query("DELETE FROM vaults WHERE vault_id=?")
            .bind(&foreign_vault)
            .execute(&state.db)
            .await
            .unwrap();
        for table in [
            "vault_members",
            "vault_key_envelopes",
            "vault_counters",
            "record_heads",
            "record_versions",
            "change_events",
            "op_receipts",
            "batch_receipts",
            "record_graveyard",
            "snapshots",
            "conflicts",
            "uploads",
            "upload_chunks",
            "blob_objects",
            "object_references",
            "invitations",
            "membership_manifests",
        ] {
            let count: i64 = sqlx::query(&format!("SELECT COUNT(*) AS count FROM {table}"))
                .fetch_one(&state.db)
                .await
                .unwrap()
                .get("count");
            assert_eq!(count, 0, "vault child rows remain in {table}");
        }
        let audit = sqlx::query(
            "SELECT purged_at,actor_hash FROM vault_deletion_requests WHERE vault_id=?",
        )
        .bind(&vault)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit.get::<Option<i64>, _>("purged_at"), Some(now_epoch));
        assert_eq!(
            audit.get::<Option<String>, _>("actor_hash").as_deref(),
            Some("anonymous-hash")
        );
        let retained_events = sqlx::query(
            "SELECT action,actor_user_id,actor_device_id FROM audit_events WHERE scope_type='vault' AND scope_id=? ORDER BY event_id",
        )
        .bind(&vault)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(retained_events.len(), 2);
        assert!(retained_events.iter().all(|row| {
            row.get::<Option<String>, _>("actor_user_id").is_none()
                && row.get::<Option<String>, _>("actor_device_id").is_none()
        }));
        assert_eq!(
            retained_events[0].get::<String, _>("action"),
            "vault.deletion_requested"
        );
        assert_eq!(
            retained_events[1].get::<String, _>("action"),
            "vault.purged"
        );
        let pending: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM vault_deletion_requests WHERE vault_id='pending-old-audit' AND cancelled_at IS NULL AND purged_at IS NULL",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            pending, 1,
            "audit retention must not remove pending requests"
        );
        let expired: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM vault_deletion_requests WHERE vault_id='expired-audit'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            expired, 0,
            "terminal audit must expire after configured retention"
        );

        purge_due_vault_deletions(&state, now_epoch + 1)
            .await
            .unwrap();
        let purged_again: Option<i64> =
            sqlx::query_scalar("SELECT purged_at FROM vault_deletion_requests WHERE vault_id=?")
                .bind(&vault)
                .fetch_optional(&state.db)
                .await
                .unwrap();
        assert_eq!(
            purged_again,
            Some(now_epoch),
            "repeat maintenance is idempotent"
        );
    }

    #[tokio::test]
    async fn vault_purge_preserves_s3_completing_upload_delete_intent_until_grace_expires() {
        let mut state = test_state("vault-delete-s3-completing-upload").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let object = Uuid::new_v4().to_string();
        let upload = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        let now_epoch = chrono::Utc::now().timestamp();

        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind("s3-purge-owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,created_at) VALUES(?,?,'deleting',?)",
        )
        .bind(&vault)
        .bind(&user)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO vault_deletion_requests(vault_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,'purge-test')",
        )
        .bind(&vault)
        .bind(now_epoch - 1)
        .bind(now_epoch)
        .execute(&state.db)
        .await
        .unwrap();

        let fixture = crate::object_store::test_support::S3Fixture::start().await;
        let store = fixture.store();
        let (key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object, &upload)
            .unwrap();
        let bytes = b"encrypted S3 object from an in-flight completion";
        let digest = crate::sha256_hex(bytes);
        let size = bytes.len() as i64;
        store
            .put_immutable(&key, bytes, size, &digest)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at,storage_backend,storage_store_id) VALUES(?,?,?,?,?,?,1048576,'completing',?,?, 's3',?)",
        )
        .bind(&upload)
        .bind(&vault)
        .bind(&user)
        .bind(&object)
        .bind(size)
        .bind(&digest)
        .bind(&now)
        .bind(&now)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        state.object_store = store;

        let grace_deadline = now_epoch + 90_000;
        purge_due_vault_deletions(&state, now_epoch).await.unwrap();

        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM vaults WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0,
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM uploads WHERE upload_id=?")
                .bind(&upload)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0,
        );
        let queued: (String, String, String, i64, String, String, i64) = sqlx::query_as(
            "SELECT storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,state,next_attempt_at FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            queued,
            (
                "s3".to_owned(),
                key.clone(),
                store_id.clone(),
                size,
                digest.clone(),
                "pending".to_owned(),
                grace_deadline,
            ),
        );
        assert_eq!(
            state
                .object_store
                .read_object(&key, size, &digest, None)
                .await
                .unwrap(),
            bytes,
            "purge must preserve the provider object until the completion grace expires",
        );

        state
            .object_store
            .drain_delete_queue(&state.db, grace_deadline - 1, 100)
            .await
            .unwrap();
        assert!(
            state
                .object_store
                .read_object(&key, size, &digest, None)
                .await
                .is_ok()
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
            )
            .bind(&store_id)
            .bind(&key)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            1,
            "the future delete intent must remain durable before its deadline",
        );

        state
            .object_store
            .drain_delete_queue(&state.db, grace_deadline, 100)
            .await
            .unwrap();
        assert!(
            state
                .object_store
                .read_object(&key, size, &digest, None)
                .await
                .is_err()
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
            )
            .bind(&store_id)
            .bind(&key)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0,
            "successful provider deletion must retire its durable intent",
        );
        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(state.config.data_dir.clone()).await;
    }

    #[tokio::test]
    async fn failed_lifecycle_step_up_consumes_login_budget_before_argon2() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-vault-delete-step-up-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let mut config = test_config(data_dir);
        config.auth_rate_limits.login_user_limit = 1;
        let state = open_state(&database_url, config).await.unwrap();
        let user_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind("step-up@example.test")
            .bind(crate::now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let user = AuthUser {
            user_id,
            device_id: Uuid::new_v4().to_string(),
            session_id: Uuid::new_v4().to_string(),
            access_hash: String::new(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let peer: SocketAddr = "192.0.2.99:8443".parse().unwrap();

        let first = verify_deletion_step_up(&state, &user, "malformed", peer)
            .await
            .unwrap_err();
        assert_eq!(first.status, StatusCode::UNAUTHORIZED);
        assert_eq!(first.body.code, "REAUTH_REQUIRED");

        let second = verify_deletion_step_up(&state, &user, "malformed", peer)
            .await
            .unwrap_err();
        assert_eq!(second.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(second.body.code, "RATE_LIMITED");
        assert!(second.retry_after_secs.is_some());
        let response = second.into_response();
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
        assert!(
            response
                .headers()
                .contains_key(axum::http::header::RETRY_AFTER)
        );
    }
}

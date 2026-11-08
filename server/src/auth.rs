use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};
use axum::{
    Json,
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{FromRow, Row, Sqlite, Transaction};
use std::net::SocketAddr;
use uuid::Uuid;

use crate::{ApiError, AppState, ensure_active_device, jcs, now_rfc3339, sha256_hex};

pub(crate) const MAX_ACTIVE_DEVICES_PER_ACCOUNT: i64 = 20;
const MAX_DEVICE_VAULT_ENVELOPES: usize = 1000;

const ACCESS_TTL_SECONDS: i64 = 600;
const REFRESH_TTL_DAYS: i64 = 30;
type HmacSha256 = Hmac<Sha256>;

#[derive(Clone)]
pub(crate) struct AuthUser {
    pub user_id: String,
    pub device_id: String,
    pub session_id: String,
    /// Hash of the bearer token used for this request. Keeping the hash lets
    /// writer transactions reject requests superseded by refresh rotation.
    pub access_hash: String,
    /// A transport-level current-client declaration. This is only a read
    /// compatibility hint; v2 writes still require the signed device report.
    pub declares_record_schema2: bool,
    /// Whether the request carries the independent redaction protocol marker.
    /// Sync write transactions recheck this marker under their persistence
    /// fence so an auth result captured before report publication cannot race.
    pub declares_sync_redaction_v1: bool,
}

impl std::fmt::Debug for AuthUser {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AuthUser")
            .field("user_id", &self.user_id)
            .field("device_id", &self.device_id)
            .field("session_id", &self.session_id)
            .field("declares_record_schema2", &self.declares_record_schema2)
            .field(
                "declares_sync_redaction_v1",
                &self.declares_sync_redaction_v1,
            )
            .field("access_hash", &"[REDACTED]")
            .finish()
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct KdfParams {
    pub id: String,
    pub salt: String,
    pub mem_kib: u32,
    pub iterations: u32,
    pub parallelism: u32,
    pub version: u32,
}

#[derive(Deserialize, Serialize)]
pub struct DeviceInput {
    pub device_id: String,
    #[serde(default = "default_device_name")]
    pub name: String,
    pub signing_public_key: String,
    pub encryption_public_key: String,
    pub signature: String,
}
fn default_device_name() -> String {
    "device".into()
}

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub account_id: String,
    pub username: String,
    pub bootstrap_token: Option<String>,
    pub instance_invitation_token: Option<String>,
    pub kdf: KdfParams,
    pub login_verifier: String,
    pub account_key_envelope: Value,
    pub device: DeviceInput,
    pub initial_vault: InitialVault,
}

#[derive(Deserialize)]
pub struct InitialVault {
    pub vault_id: String,
    pub name_envelope: Value,
    pub key_epoch: Value,
    pub membership_version: Value,
    pub key_envelope: InitialKeyEnvelope,
    pub membership: InitialMembership,
}

#[derive(Deserialize, Serialize)]
pub struct InitialMembership {
    pub membership_version: Value,
    pub previous_digest: Value,
    pub manifest: Value,
    pub signature: String,
}

/// The persisted representation shared by bootstrap and later signed
/// membership-chain entries. The JCS signature payload is deliberately
/// separate: it omits `signature`, while this stored record includes it.
#[derive(Serialize)]
struct SignedMembershipRecord<'a> {
    vault_id: &'a str,
    membership_version: Value,
    previous_digest: Value,
    manifest: &'a Value,
    signature: &'a str,
}

pub(crate) fn serialize_signed_membership_record(
    vault_id: &str,
    membership_version: Value,
    previous_digest: Value,
    manifest: &Value,
    signature: &str,
) -> Result<String, ApiError> {
    Ok(signed_membership_record_value(
        vault_id,
        membership_version,
        previous_digest,
        manifest,
        signature,
    )?
    .to_string())
}

pub(crate) fn signed_membership_record_value(
    vault_id: &str,
    membership_version: Value,
    previous_digest: Value,
    manifest: &Value,
    signature: &str,
) -> Result<Value, ApiError> {
    let record = SignedMembershipRecord {
        vault_id,
        membership_version,
        previous_digest,
        manifest,
        signature,
    };
    serde_json::to_value(record).map_err(ApiError::internal)
}

#[derive(Deserialize, Serialize)]
pub struct InitialKeyEnvelope {
    pub recipient_device_id: String,
    pub key_epoch: Value,
    pub membership_version: Value,
    pub envelope: Value,
    pub signature: String,
}

#[derive(Serialize)]
pub struct SessionResponse {
    pub account_id: String,
    pub access_token: String,
    pub expires_in: i64,
    pub refresh_token: String,
    pub device_id: String,
    pub vaults: Vec<Value>,
}

pub(crate) fn normalized_username(s: &str) -> Result<String, ApiError> {
    let n = s.trim().to_lowercase();
    if n.is_empty() || n.len() > 320 || !n.contains('@') || n.chars().any(char::is_control) {
        return Err(ApiError::bad_request(
            "INVALID_USERNAME",
            "username is invalid",
        ));
    }
    Ok(n)
}

pub(crate) const ACCOUNT_INVITATION_MIN_SECONDS: i64 = 60;
pub(crate) const ACCOUNT_INVITATION_MAX_SECONDS: i64 = 30 * 24 * 60 * 60;
pub(crate) const ACCOUNT_INVITATION_DEFAULT_SECONDS: i64 = 7 * 24 * 60 * 60;
const ACCOUNT_INVITATION_PRUNE_BATCH_SIZE: i64 = 500;
pub(crate) const ACCOUNT_INVITATION_PRUNE_BATCHES_PER_MAINTENANCE: usize = 4;

/// Removes terminal invitation credentials after the configured audit
/// retention horizon. Audit events are separate records and are pruned by the
/// normal audit retention path. Pending invitations and recent terminal rows
/// remain available to the admin history endpoint.
pub(crate) async fn prune_account_invitations(
    state: &AppState,
    now_epoch: i64,
    max_batches: usize,
) -> Result<(), ApiError> {
    let retention_seconds = state.config.audit_retention_days.saturating_mul(86_400);
    let cutoff_epoch = now_epoch.saturating_sub(retention_seconds);
    let cutoff = chrono::DateTime::<Utc>::from_timestamp(cutoff_epoch, 0)
        .ok_or_else(|| ApiError::internal("account invitation retention cutoff is invalid"))?
        .to_rfc3339();

    for _ in 0..max_batches {
        let deleted = sqlx::query(
            "DELETE FROM account_invitations WHERE rowid IN (\
                SELECT rowid FROM account_invitations \
                WHERE (consumed_at IS NOT NULL AND consumed_at < ?) \
                   OR (revoked_at IS NOT NULL AND revoked_at < ?) \
                   OR (consumed_at IS NULL AND revoked_at IS NULL AND expires_at < ?) \
                LIMIT ?\
            )",
        )
        .bind(&cutoff)
        .bind(&cutoff)
        .bind(&cutoff)
        .bind(ACCOUNT_INVITATION_PRUNE_BATCH_SIZE)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();

        if deleted < ACCOUNT_INVITATION_PRUNE_BATCH_SIZE as u64 {
            break;
        }
    }
    Ok(())
}

/// Mints an account-enrollment credential for local operator use. Only the
/// token hash is persisted; the bearer token is returned once to the CLI.
pub async fn create_account_invitation(
    state: &AppState,
    raw_username: &str,
    expires_in_seconds: Option<i64>,
) -> Result<(String, String, String), ApiError> {
    let username = normalized_username(raw_username)?;
    let lifetime = expires_in_seconds.unwrap_or(ACCOUNT_INVITATION_DEFAULT_SECONDS);
    if !(ACCOUNT_INVITATION_MIN_SECONDS..=ACCOUNT_INVITATION_MAX_SECONDS).contains(&lifetime) {
        return Err(ApiError::bad_request(
            "INVALID_INVITATION_TTL",
            "account invitation lifetime must be between 60 and 2592000 seconds",
        ));
    }
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return repository.issue_invitation(&username, lifetime).await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let setup_consumed: Option<String> =
        sqlx::query_scalar("SELECT setup_consumed_at FROM instance_meta WHERE id=1")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if user_count == 0 || setup_consumed.is_none() {
        return Err(ApiError::conflict(
            "SETUP_REQUIRED",
            "complete initial bootstrap before issuing account invitations",
        ));
    }
    let username_exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM users WHERE username=?")
        .bind(&username)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if username_exists.is_some() {
        return Err(ApiError::conflict(
            "USERNAME_TAKEN",
            "an account with this username already exists",
        ));
    }

    let now = Utc::now();
    let created_at = now.to_rfc3339();
    let expires_at = (now + Duration::seconds(lifetime)).to_rfc3339();
    // Reissuing for the same normalized username supersedes every old pending
    // invitation, avoiding an unbounded set of credentials that can never be
    // used after the first one creates that account.
    let superseded = sqlx::query("UPDATE account_invitations SET revoked_at=? WHERE username=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>? RETURNING invitation_id")
        .bind(&created_at)
        .bind(&username)
        .bind(&created_at)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    for row in superseded {
        let old_invitation_id: String = row.get("invitation_id");
        crate::audit::record_instance_event_tx(
            &mut tx,
            state,
            "instance.account_invitation_revoked",
            "account_invitation",
            Some(&old_invitation_id),
            now.timestamp(),
        )
        .await?;
    }
    let token = random_token();
    let token_hash = sha256_hex(token.as_bytes());
    let invitation_id = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO account_invitations(invitation_id,token_hash,username,created_at,expires_at) VALUES(?,?,?,?,?)")
        .bind(&invitation_id)
        .bind(token_hash)
        .bind(&username)
        .bind(&created_at)
        .bind(&expires_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_instance_event_tx(
        &mut tx,
        state,
        "instance.account_invitation_issued",
        "account_invitation",
        Some(&invitation_id),
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((token, username, expires_at))
}

pub(crate) fn random_token() -> String {
    let mut bytes = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

fn account_invitation_invalid() -> ApiError {
    ApiError::new(
        axum::http::StatusCode::UNAUTHORIZED,
        "ACCOUNT_INVITATION_INVALID",
        "account invitation is invalid",
    )
}

fn decode_b64(value: &str, expected: usize, what: &str) -> Result<Vec<u8>, ApiError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ApiError::bad_request("INVALID_CREDENTIAL", what))?;
    if bytes.len() != expected {
        return Err(ApiError::bad_request("INVALID_CREDENTIAL", what));
    }
    Ok(bytes)
}

pub(crate) fn validate_kdf(kdf: &KdfParams) -> Result<(), ApiError> {
    if kdf.id != "argon2id13"
        || kdf.version != 1
        || !(65_536..=262_144).contains(&kdf.mem_kib)
        || !(3..=10).contains(&kdf.iterations)
        || !(1..=8).contains(&kdf.parallelism)
    {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_KDF",
            "KDF parameters are outside supported bounds",
        ));
    }
    let salt = decode_b64(&kdf.salt, 16, "KDF salt must be 16 bytes")?;
    if salt.iter().all(|b| *b == 0) {
        return Err(ApiError::bad_request("INVALID_KDF", "KDF salt is invalid"));
    }
    Ok(())
}

pub(crate) fn verify_key_signature(
    public_b64: &str,
    signature_b64: &str,
    payload: &[u8],
) -> Result<(), ApiError> {
    let public = decode_b64(public_b64, 32, "device signing key is invalid")?;
    let key = VerifyingKey::from_bytes(
        public
            .as_slice()
            .try_into()
            .map_err(|_| ApiError::invalid_envelope("device key is invalid"))?,
    )
    .map_err(|_| ApiError::invalid_envelope("device key is invalid"))?;
    let sig_bytes = URL_SAFE_NO_PAD
        .decode(signature_b64)
        .map_err(|_| ApiError::invalid_envelope("device proof is invalid"))?;
    let signature = Signature::from_slice(&sig_bytes)
        .map_err(|_| ApiError::invalid_envelope("device proof is invalid"))?;
    key.verify(payload, &signature)
        .map_err(|_| ApiError::invalid_envelope("device proof signature is invalid"))
}

fn device_proof_payload(
    account_id: &str,
    device_id: &str,
    signing_public_key: &str,
    encryption_public_key: &str,
) -> Value {
    json!({"account_id":account_id,"device_id":device_id,"encryption_public_key":encryption_public_key,"signing_public_key":signing_public_key})
}

pub(crate) fn validate_device(
    device: &DeviceInput,
    account_id: &str,
    signer_public: &str,
) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(&device.device_id) {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE",
            "device_id must be a lowercase canonical UUID",
        ));
    }
    if device.name.trim().is_empty()
        || device.name.len() > 128
        || device.name.chars().any(char::is_control)
    {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE",
            "device name is invalid",
        ));
    }
    decode_b64(
        &device.signing_public_key,
        32,
        "device signing key must be 32 bytes",
    )?;
    decode_b64(
        &device.encryption_public_key,
        32,
        "device encryption key must be 32 bytes",
    )?;
    let payload = jcs(&device_proof_payload(
        account_id,
        &device.device_id,
        &device.signing_public_key,
        &device.encryption_public_key,
    ))?;
    verify_key_signature(signer_public, &device.signature, &payload)
}

pub(crate) fn as_counter(value: &Value) -> Option<i64> {
    value
        .as_str()
        .and_then(|s| s.parse().ok())
        .or_else(|| value.as_i64())
}

/// Validates the client-encrypted Vault display name envelope used by the
/// initial registration and later membership/epoch updates. The server cannot
/// decrypt it, but keeps the shape and size bounded consistently everywhere.
pub(crate) fn validate_display_name_envelope(envelope: &Value) -> Result<String, ApiError> {
    let Some(object) = envelope.as_object() else {
        return Err(ApiError::invalid_envelope(
            "display name envelope must be an object",
        ));
    };
    if object.len() != 3
        || !object.contains_key("version")
        || !object.contains_key("nonce")
        || !object.contains_key("ciphertext")
        || envelope.to_string().len() > 64 * 1024
        || envelope.get("version").and_then(Value::as_i64) != Some(1)
    {
        return Err(ApiError::invalid_envelope(
            "display name envelope has an unsupported version or shape",
        ));
    }
    let nonce = envelope
        .get("nonce")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("display name envelope is incomplete"))?;
    let ciphertext = envelope
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("display name envelope is incomplete"))?;
    let nonce_bytes = URL_SAFE_NO_PAD
        .decode(nonce)
        .map_err(|_| ApiError::invalid_envelope("display name envelope nonce is invalid"))?;
    let ciphertext_bytes = URL_SAFE_NO_PAD
        .decode(ciphertext)
        .map_err(|_| ApiError::invalid_envelope("display name envelope ciphertext is invalid"))?;
    if nonce_bytes.len() != 24 || !(16..=48 * 1024).contains(&ciphertext_bytes.len()) {
        return Err(ApiError::invalid_envelope(
            "display name envelope nonce or ciphertext length is invalid",
        ));
    }
    serde_json::to_string(envelope).map_err(ApiError::internal)
}

pub(crate) fn validate_initial_vault(
    initial: &InitialVault,
    account_id: &str,
    device: &DeviceInput,
) -> Result<(String, String, String), ApiError> {
    if !crate::is_canonical_uuid(&initial.vault_id) {
        return Err(ApiError::bad_request(
            "INVALID_VAULT_ID",
            "initial vault id must be a lowercase canonical UUID",
        ));
    }
    if initial.key_epoch.as_i64() != Some(1) || initial.membership_version.as_i64() != Some(1) {
        return Err(ApiError::invalid_envelope(
            "initial vault must have epoch one and membership version one",
        ));
    }
    let membership = &initial.membership;
    let manifest = &membership.manifest;
    if membership.membership_version.as_i64() != Some(1)
        || !membership.previous_digest.is_null()
        || manifest.get("key_epoch").and_then(Value::as_i64) != Some(1)
        || manifest.get("signer_device_id").and_then(Value::as_str) != Some(&device.device_id)
    {
        return Err(ApiError::invalid_envelope(
            "initial membership manifest context is invalid",
        ));
    }
    if let Some(display_name_envelope) = manifest.get("display_name_envelope") {
        if display_name_envelope != &initial.name_envelope {
            return Err(ApiError::invalid_envelope(
                "initial membership display name envelope must match the top-level envelope",
            ));
        }
    }
    let name = validate_display_name_envelope(&initial.name_envelope)?;
    let members = manifest
        .get("members")
        .and_then(Value::as_array)
        .filter(|m| m.len() == 1)
        .ok_or_else(|| {
            ApiError::invalid_envelope("initial membership manifest must contain only its owner")
        })?;
    let owner = members
        .iter()
        .find(|m| {
            m.get("role").and_then(Value::as_str) == Some("owner")
                && m.get("state").and_then(Value::as_str) == Some("active")
        })
        .ok_or_else(|| {
            ApiError::invalid_envelope("initial membership manifest must contain an active owner")
        })?;
    if owner.get("user_id").and_then(Value::as_str) != Some(account_id) {
        return Err(ApiError::invalid_envelope(
            "initial owner id does not match account id",
        ));
    }
    let encryption_bytes = URL_SAFE_NO_PAD
        .decode(&device.encryption_public_key)
        .map_err(|_| ApiError::invalid_envelope("device encryption key is invalid"))?;
    let fingerprint = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&encryption_bytes));
    if owner
        .get("encryption_key_fingerprint")
        .and_then(Value::as_str)
        != Some(&fingerprint)
    {
        return Err(ApiError::invalid_envelope(
            "initial owner encryption key fingerprint does not match device",
        ));
    }
    let payload = json!({"vault_id":initial.vault_id,"membership_version":membership.membership_version,"previous_digest":membership.previous_digest,"manifest":membership.manifest});
    verify_key_signature(
        &device.signing_public_key,
        &membership.signature,
        &jcs(&payload)?,
    )?;
    let digest = sha256_hex(&jcs(&payload)?);

    let key = &initial.key_envelope;
    if key.recipient_device_id != device.device_id
        || key.key_epoch.as_i64() != Some(1)
        || key.membership_version.as_i64() != Some(1)
        || !key.envelope.is_object()
    {
        return Err(ApiError::invalid_envelope(
            "initial key envelope context is invalid",
        ));
    }
    let key_payload = json!({"vault_id":initial.vault_id,"recipient_device_id":key.recipient_device_id,"key_epoch":key.key_epoch,"membership_version":key.membership_version,"envelope":key.envelope});
    verify_key_signature(
        &device.signing_public_key,
        &key.signature,
        &jcs(&key_payload)?,
    )?;
    if key.envelope.to_string().len() > 64 * 1024 {
        return Err(ApiError::invalid_envelope(
            "initial key envelope is too large",
        ));
    }
    Ok((
        name,
        digest,
        serialize_signed_membership_record(
            &initial.vault_id,
            membership.membership_version.clone(),
            membership.previous_digest.clone(),
            &membership.manifest,
            &membership.signature,
        )?,
    ))
}

pub(crate) fn password_hash(verifier: &str) -> Result<(String, String), ApiError> {
    let raw = decode_b64(verifier, 32, "login_verifier must be 32 bytes")?;
    let mut salt_bytes = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut salt_bytes);
    let salt =
        argon2::password_hash::SaltString::encode_b64(&salt_bytes).map_err(ApiError::internal)?;
    let phc = Argon2::default()
        .hash_password(&raw, &salt)
        .map_err(ApiError::internal)?
        .to_string();
    Ok((phc, salt.to_string()))
}

pub(crate) fn check_password_hash(verifier: &str, encoded: &str) -> Result<(), ApiError> {
    let raw = URL_SAFE_NO_PAD
        .decode(verifier)
        .map_err(|_| ApiError::unauthorized())?;
    if raw.len() != 32 {
        return Err(ApiError::unauthorized());
    }
    let hash = PasswordHash::new(encoded).map_err(ApiError::internal)?;
    Argon2::default()
        .verify_password(&raw, &hash)
        .map_err(|_| ApiError::unauthorized())
}

/// Verifies a client-derived login verifier for a sensitive operation and
/// returns the PHC hash snapshot so the caller can ensure credentials did not
/// change before its write transaction commits.
pub(crate) async fn verify_login_verifier_for_user(
    state: &AppState,
    user_id: &str,
    verifier: &str,
) -> Result<String, ApiError> {
    let encoded: Option<String> = sqlx::query_scalar(
        "SELECT c.login_verifier_hash FROM auth_credentials c JOIN users u USING(user_id) WHERE c.user_id=? AND u.status='active'",
    )
    .bind(user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let encoded = encoded.ok_or_else(ApiError::reauth_required)?;
    let raw = URL_SAFE_NO_PAD
        .decode(verifier)
        .map_err(|_| ApiError::reauth_required())?;
    if raw.len() != 32 {
        return Err(ApiError::reauth_required());
    }
    let password_hash = PasswordHash::new(&encoded).map_err(ApiError::internal)?;
    Argon2::default()
        .verify_password(&raw, &password_hash)
        .map_err(|_| ApiError::reauth_required())?;
    Ok(encoded)
}

fn ensure_envelope(env: &Value) -> Result<String, ApiError> {
    if !env.is_object() || env.to_string().len() > 64 * 1024 {
        return Err(ApiError::invalid_envelope(
            "account key envelope is invalid",
        ));
    }
    if env.get("version").and_then(Value::as_i64) != Some(1) {
        return Err(ApiError::invalid_envelope(
            "account key envelope version is unsupported",
        ));
    }
    let nonce = env
        .get("nonce")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("account key envelope is incomplete"))?;
    let ciphertext = env
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("account key envelope is incomplete"))?;
    if URL_SAFE_NO_PAD
        .decode(nonce)
        .map_or(true, |n| n.len() != 24)
        || URL_SAFE_NO_PAD
            .decode(ciphertext)
            .map_or(true, |c| c.len() < 16)
    {
        return Err(ApiError::invalid_envelope(
            "account key envelope encoding is invalid",
        ));
    }
    Ok(env.to_string())
}

#[derive(Deserialize)]
pub struct PreloginRequest {
    pub username: String,
}

/// Charges the shared authentication limiter selected by the runtime. The
/// PostgreSQL branch commits its own transaction; the default branch keeps
/// the existing SQLite transaction and behavior.
pub(crate) async fn consume_auth_rate_limit(
    state: &AppState,
    operation: crate::rate_limit::AuthOperation,
    username: &str,
    peer: Option<std::net::IpAddr>,
) -> Result<Option<u64>, ApiError> {
    if let Some(repository) = state.pg_auth_rate_limits.as_ref() {
        return repository.consume(operation, username, peer).await;
    }
    let mut transaction = state.db.begin().await.map_err(ApiError::internal)?;
    let retry_after =
        crate::rate_limit::consume(state, &mut transaction, operation, username, peer).await?;
    transaction.commit().await.map_err(ApiError::internal)?;
    Ok(retry_after)
}

pub async fn prelogin(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<PreloginRequest>,
) -> Result<Json<Value>, ApiError> {
    let username = normalized_username(&request.username)?;
    let retry_after = consume_auth_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::Prelogin,
        &username,
        Some(peer.ip()),
    )
    .await?;
    if let Some(seconds) = retry_after {
        return Err(ApiError::rate_limited(seconds));
    }
    if let Some(repository) = state.pg_auth_lifecycle.as_ref() {
        if let Some((account_id, kdf)) = repository.prelogin_user(&username).await? {
            let kdf: Value = serde_json::from_str(&kdf).map_err(ApiError::internal)?;
            return Ok(Json(
                json!({"account_id":account_id,"kdf":kdf,"auth_scheme":"argon2id-verifier-v1"}),
            ));
        }
        let (account_id, salt) = prelogin_decoy(&state.auth_rate_key, &username)?;
        return Ok(Json(
            json!({"account_id":account_id,"kdf":{"id":"argon2id13","salt":salt,"mem_kib":65536,"iterations":3,"parallelism":1,"version":1},"auth_scheme":"argon2id-verifier-v1"}),
        ));
    }
    // A deleting account must still receive its real KDF parameters so it can
    // prove its verifier to the sessionless cancellation flow. Login itself
    // remains gated to active accounts below.
    let row = sqlx::query("SELECT user_id, kdf_json FROM users JOIN auth_credentials USING(user_id) WHERE username=? AND status IN ('active','deleting')")
        .bind(&username).fetch_optional(&state.db).await.map_err(ApiError::internal)?;
    if let Some(row) = row {
        let account_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let kdf: String = row.try_get("kdf_json").map_err(ApiError::internal)?;
        let kdf: Value = serde_json::from_str(&kdf).map_err(ApiError::internal)?;
        Ok(Json(
            json!({"account_id":account_id,"kdf":kdf,"auth_scheme":"argon2id-verifier-v1"}),
        ))
    } else {
        let (account_id, salt) = prelogin_decoy(&state.auth_rate_key, &username)?;
        Ok(Json(
            json!({"account_id":account_id,"kdf":{"id":"argon2id13","salt":salt,"mem_kib":65536,"iterations":3,"parallelism":1,"version":1},"auth_scheme":"argon2id-verifier-v1"}),
        ))
    }
}

fn prelogin_decoy(key: &[u8; 32], username: &str) -> Result<(String, String), ApiError> {
    crate::pg_auth_lifecycle::prelogin_decoy(key, username)
}

pub(crate) fn dummy_login_verifier_hash() -> Result<String, ApiError> {
    let mut salt_bytes = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut salt_bytes);
    let salt =
        argon2::password_hash::SaltString::encode_b64(&salt_bytes).map_err(ApiError::internal)?;
    Argon2::default()
        .hash_password(&[0_u8; 32], &salt)
        .map(|hash| hash.to_string())
        .map_err(ApiError::internal)
}

pub async fn register(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<RegisterRequest>,
) -> Result<Json<SessionResponse>, ApiError> {
    let username = normalized_username(&request.username)?;
    let retry_after = consume_auth_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::Register,
        &username,
        Some(peer.ip()),
    )
    .await?;
    if let Some(seconds) = retry_after {
        return Err(ApiError::rate_limited(seconds));
    }
    validate_kdf(&request.kdf)?;
    let account_envelope = ensure_envelope(&request.account_key_envelope)?;
    if !crate::is_canonical_uuid(&request.account_id) {
        return Err(ApiError::bad_request(
            "INVALID_ACCOUNT_ID",
            "account_id must be a lowercase canonical UUID",
        ));
    }
    validate_device(
        &request.device,
        &request.account_id,
        &request.device.signing_public_key,
    )?;
    let (vault_name, manifest_digest, manifest_json) =
        validate_initial_vault(&request.initial_vault, &request.account_id, &request.device)?;
    let kdf_json = serde_json::to_string(&json!({"id":request.kdf.id,"salt":request.kdf.salt,"mem_kib":request.kdf.mem_kib,"iterations":request.kdf.iterations,"parallelism":request.kdf.parallelism,"version":request.kdf.version})).map_err(ApiError::internal)?;

    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        let registered = repository
            .register(crate::pg_account_onboarding::PgRegistrationInput {
                username: &username,
                account_id: &request.account_id,
                bootstrap_token: request.bootstrap_token.as_deref(),
                instance_invitation_token: request.instance_invitation_token.as_deref(),
                kdf_json: &kdf_json,
                login_verifier: &request.login_verifier,
                account_key_envelope: &account_envelope,
                device: &request.device,
                initial_vault: &request.initial_vault,
                vault_name: &vault_name,
                manifest_digest: &manifest_digest,
                manifest_json: &manifest_json,
            })
            .await?;
        return Ok(Json(SessionResponse {
            account_id: registered.account_id,
            access_token: registered.access_token,
            expires_in: registered.expires_in,
            refresh_token: registered.refresh_token,
            device_id: registered.device_id,
            vaults: vec![json!({
                "vault_id": registered.vault_id,
                "role": "owner",
                "active_key_epoch": 1,
                "membership_version": 1,
            })],
        }));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Serialize registrations before examining setup state or a one-time
    // invitation, preventing two concurrent requests from consuming one token.
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let account_invitation_id: Option<String>;
    let mut bootstrap_token_hash: Option<String> = None;
    if user_count == 0 {
        if request.instance_invitation_token.is_some() {
            return Err(ApiError::bad_request(
                "INVALID_ENROLLMENT_CREDENTIAL",
                "initial bootstrap uses bootstrap_token",
            ));
        }
        let expected: Option<String> =
            sqlx::query_scalar("SELECT bootstrap_token_hash FROM instance_meta WHERE id=1")
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let expected = expected.ok_or_else(ApiError::unauthorized)?;
        let provided = request
            .bootstrap_token
            .as_deref()
            .map(|s| sha256_hex(s.as_bytes()));
        if provided.as_deref() != Some(expected.as_str()) {
            return Err(ApiError::unauthorized());
        }
        bootstrap_token_hash = Some(expected);
        account_invitation_id = None;
    } else {
        if request.bootstrap_token.is_some() {
            return Err(ApiError::bad_request(
                "INVALID_ENROLLMENT_CREDENTIAL",
                "bootstrap_token is only valid for the first account",
            ));
        }
        let Some(token) = request.instance_invitation_token.as_deref() else {
            return Err(ApiError::forbidden(
                "ACCOUNT_INVITATION_REQUIRED",
                "account registration requires an operator-issued invitation",
            ));
        };
        let token_hash = sha256_hex(token.as_bytes());
        let invite = sqlx::query("SELECT invitation_id,username,expires_at,consumed_at,revoked_at FROM account_invitations WHERE token_hash=?")
            .bind(token_hash)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let Some(invite) = invite else {
            return Err(account_invitation_invalid());
        };
        let invite_username: String = invite.get("username");
        let expires_at: String = invite.get("expires_at");
        let consumed_at: Option<String> = invite.get("consumed_at");
        let revoked_at: Option<String> = invite.get("revoked_at");
        let valid_until = chrono::DateTime::parse_from_rfc3339(&expires_at)
            .map(|value| value > Utc::now())
            .unwrap_or(false);
        if invite_username != username
            || consumed_at.is_some()
            || revoked_at.is_some()
            || !valid_until
        {
            return Err(account_invitation_invalid());
        }
        account_invitation_id = Some(invite.get("invitation_id"));
    }
    let exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM users WHERE username=?")
        .bind(&username)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if exists.is_some() {
        return Err(ApiError::conflict(
            "USERNAME_TAKEN",
            "account identifier is already registered",
        ));
    }

    let user_id = request.account_id.clone();
    let vault_id = request.initial_vault.vault_id.clone();
    let account_id_exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if account_id_exists.is_some() {
        return Err(ApiError::conflict(
            "ACCOUNT_ID_TAKEN",
            "account identifier is already registered",
        ));
    }
    let vault_id_exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM vaults WHERE vault_id=?")
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if vault_id_exists.is_some() {
        return Err(ApiError::conflict(
            "VAULT_EXISTS",
            "vault identifier is already registered",
        ));
    }
    if let Some(expected) = bootstrap_token_hash {
        let consumed=sqlx::query("UPDATE instance_meta SET bootstrap_token_hash=NULL,setup_consumed_at=? WHERE id=1 AND setup_consumed_at IS NULL AND bootstrap_token_hash=?")
            .bind(now_rfc3339()).bind(expected).execute(&mut *tx).await.map_err(ApiError::internal)?;
        if consumed.rows_affected() != 1 {
            return Err(ApiError::unauthorized());
        }
    }
    // Argon2 runs only after the bootstrap/account invitation, normalized
    // username, and client-generated identifiers have passed their checks.
    // Keep it inside the serialized transaction so invitation consumption and
    // account creation remain one atomic operation.
    let (verifier_hash, verifier_salt) = password_hash(&request.login_verifier)?;
    let now = now_rfc3339();
    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
        .bind(&user_id)
        .bind(&username)
        .bind(&now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO auth_credentials(user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope) VALUES(?,?,?,?,?)")
        .bind(&user_id).bind(&verifier_hash).bind(&verifier_salt).bind(&kdf_json).bind(account_envelope).execute(&mut *tx).await.map_err(ApiError::internal)?;
    insert_device(&mut tx, &request.device, &user_id, &now).await?;
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,name_envelope,active_epoch,membership_version,created_at) VALUES(?,?,?,1,1,?)").bind(&vault_id).bind(&user_id).bind(vault_name).bind(&now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,added_at) VALUES(?,?,'owner',?)")
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,0)")
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let ke = &request.initial_vault.key_envelope;
    sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,1,?,?,?,?,?,1)")
        .bind(&vault_id).bind(&user_id).bind(&ke.recipient_device_id).bind(ke.envelope.to_string()).bind(&ke.signature).bind(&request.device.device_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    let mm = &request.initial_vault.membership;
    sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,previous_digest,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,1,NULL,?,?,?,?,?)")
        .bind(&vault_id).bind(manifest_json).bind(manifest_digest).bind(&request.device.device_id).bind(&mm.signature).bind(&now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    let session = insert_session(&mut tx, &user_id, &request.device.device_id).await?;
    if let Some(invitation_id) = account_invitation_id {
        let consumed = sqlx::query("UPDATE account_invitations SET consumed_at=?,consumed_user_id=? WHERE invitation_id=? AND username=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>?")
            .bind(&now)
            .bind(&user_id)
            .bind(invitation_id)
            .bind(&username)
            .bind(&now)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if consumed.rows_affected() != 1 {
            return Err(account_invitation_invalid());
        }
    }
    let audit_epoch = Utc::now().timestamp();
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user_id,
        Some(&request.device.device_id),
        "account.created",
        "account",
        Some(&user_id),
        crate::audit::AuditSource::Api,
        audit_epoch,
    )
    .await?;
    crate::audit::record_vault_event_tx(
        &mut tx,
        &vault_id,
        Some(&user_id),
        Some(&request.device.device_id),
        "vault.created",
        "vault",
        Some(&vault_id),
        crate::audit::AuditSource::Api,
        audit_epoch,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(SessionResponse {
        account_id: user_id,
        access_token: session.access_token,
        expires_in: session.expires_in,
        refresh_token: session.refresh_token,
        device_id: request.device.device_id,
        vaults: vec![
            json!({"vault_id":vault_id,"role":"owner","active_key_epoch":1,"membership_version":1}),
        ],
    }))
}

async fn insert_device(
    tx: &mut Transaction<'_, Sqlite>,
    device: &DeviceInput,
    user_id: &str,
    now: &str,
) -> Result<(), ApiError> {
    ensure_active_device_capacity_tx(tx, user_id).await?;
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
        .bind(&device.device_id).bind(user_id).bind(&device.name).bind(&device.signing_public_key).bind(&device.encryption_public_key).bind(now)
        .execute(&mut **tx).await.map_err(|_| ApiError::conflict("DEVICE_EXISTS", "device identifier is already registered"))?;
    Ok(())
}

/// Reserves the SQLite writer before counting active devices so concurrent
/// enrollments cannot both consume the final available slot. Revoked devices
/// deliberately do not count toward the account limit.
pub(crate) async fn ensure_active_device_capacity_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<(), ApiError> {
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=? AND status='active'")
        .bind(user_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() != 1 {
        return Err(ApiError::unauthorized());
    }
    let active: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE user_id=? AND status='active'")
            .bind(user_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if active >= MAX_ACTIVE_DEVICES_PER_ACCOUNT {
        return Err(ApiError::conflict(
            "ACTIVE_DEVICE_LIMIT_REACHED",
            "account already has the maximum number of active devices",
        ));
    }
    Ok(())
}

#[derive(Serialize)]
pub(crate) struct Tokens {
    pub(crate) access_token: String,
    pub(crate) expires_in: i64,
    pub(crate) refresh_token: String,
}

pub(crate) async fn insert_session(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    device_id: &str,
) -> Result<Tokens, ApiError> {
    let session_id = Uuid::new_v4().to_string();
    let family_id = Uuid::new_v4().to_string();
    let access = random_token();
    let refresh = random_token();
    let now = Utc::now();
    let access_exp = (now + Duration::seconds(ACCESS_TTL_SECONDS)).to_rfc3339();
    let refresh_exp = (now + Duration::days(REFRESH_TTL_DAYS)).to_rfc3339();
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
        .bind(session_id).bind(user_id).bind(device_id).bind(family_id).bind(sha256_hex(access.as_bytes())).bind(sha256_hex(refresh.as_bytes())).bind(access_exp).bind(refresh_exp).bind(now.to_rfc3339())
        .execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(Tokens {
        access_token: access,
        expires_in: ACCESS_TTL_SECONDS,
        refresh_token: refresh,
    })
}

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub login_verifier: String,
    pub device_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PasswordChangeRequest {
    pub operation_id: String,
    pub current_login_verifier: String,
    pub new_kdf: KdfParams,
    pub new_login_verifier: String,
    pub account_key_envelope: Value,
}

pub(crate) fn validate_password_change_operation_id(operation_id: &str) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(operation_id) {
        return Err(ApiError::bad_request(
            "INVALID_PASSWORD_CHANGE_OPERATION_ID",
            "operation_id must be a lowercase canonical UUID",
        ));
    }
    Ok(())
}

pub(crate) fn password_change_request_digest(
    key: &[u8; 32],
    user_id: &str,
    session_id: &str,
    request: &PasswordChangeRequest,
) -> Result<String, ApiError> {
    let payload = json!({
        "user_id": user_id,
        "session_id": session_id,
        "operation_id": request.operation_id,
        "current_login_verifier": request.current_login_verifier,
        "new_kdf": {
            "id": request.new_kdf.id,
            "salt": request.new_kdf.salt,
            "mem_kib": request.new_kdf.mem_kib,
            "iterations": request.new_kdf.iterations,
            "parallelism": request.new_kdf.parallelism,
            "version": request.new_kdf.version,
        },
        "new_login_verifier": request.new_login_verifier,
        "account_key_envelope": request.account_key_envelope,
    });
    let canonical = serde_jcs::to_vec(&payload).map_err(ApiError::internal)?;
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(b"atermius/password-change-idempotency/v1\0");
    mac.update(&canonical);
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub(crate) fn ensure_rewrapped_account_envelope(envelope: &Value) -> Result<String, ApiError> {
    let Some(fields) = envelope.as_object() else {
        return Err(ApiError::invalid_envelope(
            "account key envelope must contain only version, nonce and ciphertext",
        ));
    };
    if fields.len() != 3
        || !fields.contains_key("version")
        || !fields.contains_key("nonce")
        || !fields.contains_key("ciphertext")
    {
        return Err(ApiError::invalid_envelope(
            "account key envelope must contain only version, nonce and ciphertext",
        ));
    }
    ensure_envelope(envelope)
}

async fn consume_password_change_attempt(
    state: &AppState,
    user_id: &str,
    peer: SocketAddr,
) -> Result<(), ApiError> {
    let username: Option<String> =
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=? AND status='active'")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?;
    let username = username.ok_or_else(ApiError::unauthorized)?;
    let username = normalized_username(&username)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let retry_after = crate::rate_limit::consume(
        state,
        &mut tx,
        crate::rate_limit::AuthOperation::Login,
        &username,
        Some(peer.ip()),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    if let Some(seconds) = retry_after {
        return Err(ApiError::rate_limited(seconds));
    }
    Ok(())
}

async fn lock_password_change_session(
    tx: &mut Transaction<'_, Sqlite>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    crate::require_active_session_device_tx(tx, user)
        .await
        .map_err(|error| {
            if error.body.code == "DEVICE_REVOKED" {
                ApiError::unauthorized()
            } else {
                error
            }
        })
}

async fn password_change_receipt(
    tx: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    operation_id: &str,
    request_digest: &str,
) -> Result<Option<i64>, ApiError> {
    let receipt = sqlx::query(
        "SELECT operation_id,request_digest,credential_version FROM password_change_receipts WHERE session_id=?",
    )
    .bind(session_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(receipt) = receipt else {
        return Ok(None);
    };
    let stored_operation_id: String = receipt.get("operation_id");
    if stored_operation_id != operation_id {
        return Ok(None);
    }
    let stored_digest: String = receipt.get("request_digest");
    if stored_digest != request_digest {
        return Err(ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "password-change operation ID was reused with different content",
        ));
    }
    Ok(Some(receipt.get("credential_version")))
}

fn password_change_response(
    operation_id: &str,
    credential_version: i64,
    already_applied: bool,
) -> Json<Value> {
    Json(json!({
        "status": "changed",
        "operation_id": operation_id,
        "credential_version": credential_version,
        "session_preserved": true,
        "other_sessions_revoked": true,
        "already_applied": already_applied,
    }))
}

pub async fn change_password(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<PasswordChangeRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_auth_lifecycle.as_ref() {
        return repository
            .change_password(&state, &user, peer, request)
            .await
            .map(|response| Json(response));
    }
    consume_password_change_attempt(&state, &user.user_id, peer).await?;
    validate_password_change_operation_id(&request.operation_id)?;
    let request_digest = password_change_request_digest(
        state.auth_rate_key.as_ref(),
        &user.user_id,
        &user.session_id,
        &request,
    )?;

    // Resolve a response-loss retry before checking the old verifier, which
    // became obsolete as part of the successful first attempt.
    let mut retry_tx = state.db.begin().await.map_err(ApiError::internal)?;
    lock_password_change_session(&mut retry_tx, &user).await?;
    if let Some(version) = password_change_receipt(
        &mut retry_tx,
        &user.session_id,
        &request.operation_id,
        &request_digest,
    )
    .await?
    {
        retry_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(password_change_response(
            &request.operation_id,
            version,
            true,
        ));
    }
    retry_tx.commit().await.map_err(ApiError::internal)?;

    let current_hash = match verify_login_verifier_for_user(
        &state,
        &user.user_id,
        &request.current_login_verifier,
    )
    .await
    {
        Ok(hash) => hash,
        Err(error) => {
            if error.body.code == "REAUTH_REQUIRED" {
                record_password_change_failure_best_effort(&state, &user).await;
            }
            return Err(error);
        }
    };
    validate_kdf(&request.new_kdf)?;
    let account_key_envelope = ensure_rewrapped_account_envelope(&request.account_key_envelope)?;
    let (new_verifier_hash, new_verifier_salt) = password_hash(&request.new_login_verifier)?;
    let new_kdf_json = serde_json::to_string(&json!({
        "id": request.new_kdf.id,
        "salt": request.new_kdf.salt,
        "mem_kib": request.new_kdf.mem_kib,
        "iterations": request.new_kdf.iterations,
        "parallelism": request.new_kdf.parallelism,
        "version": request.new_kdf.version,
    }))
    .map_err(ApiError::internal)?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    lock_password_change_session(&mut tx, &user).await?;
    if let Some(version) = password_change_receipt(
        &mut tx,
        &user.session_id,
        &request.operation_id,
        &request_digest,
    )
    .await?
    {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(password_change_response(
            &request.operation_id,
            version,
            true,
        ));
    }

    let credentials: Option<(String, i64)> = sqlx::query_as(
        "SELECT login_verifier_hash,credential_version FROM auth_credentials WHERE user_id=?",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((stored_hash, credential_version)) = credentials else {
        return Err(ApiError::unauthorized());
    };
    if stored_hash != current_hash {
        return Err(ApiError::reauth_required());
    }
    let new_version = credential_version
        .checked_add(1)
        .ok_or_else(|| ApiError::internal("credential version overflow"))?;
    let now = Utc::now().timestamp();
    let updated = sqlx::query("UPDATE auth_credentials SET login_verifier_hash=?,verifier_salt=?,kdf_json=?,account_key_envelope=?,credential_version=? WHERE user_id=? AND credential_version=?")
        .bind(new_verifier_hash)
        .bind(new_verifier_salt)
        .bind(new_kdf_json)
        .bind(account_key_envelope)
        .bind(new_version)
        .bind(&user.user_id)
        .bind(credential_version)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::reauth_required());
    }
    sqlx::query(
        "UPDATE sessions SET revoked_at=? WHERE user_id=? AND session_id<>? AND revoked_at IS NULL",
    )
    .bind(now_rfc3339())
    .bind(&user.user_id)
    .bind(&user.session_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO password_change_receipts(session_id,operation_id,request_digest,credential_version,created_at) VALUES(?,?,?,?,?) ON CONFLICT(session_id) DO UPDATE SET operation_id=excluded.operation_id,request_digest=excluded.request_digest,credential_version=excluded.credential_version,created_at=excluded.created_at")
        .bind(&user.session_id)
        .bind(&request.operation_id)
        .bind(&request_digest)
        .bind(new_version)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.password_changed",
        "account",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;

    Ok(password_change_response(
        &request.operation_id,
        new_version,
        false,
    ))
}

pub async fn login(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<LoginRequest>,
) -> Result<Response, ApiError> {
    let username = normalized_username(&request.username)?;
    let retry_after = consume_auth_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::Login,
        &username,
        Some(peer.ip()),
    )
    .await?;
    if let Some(seconds) = retry_after {
        return Err(ApiError::rate_limited(seconds));
    }
    if let Some(repository) = state.pg_auth_lifecycle.as_ref() {
        return match repository
            .login_password(
                &username,
                &request.login_verifier,
                &request.device_id,
                &state.dummy_login_verifier_hash,
            )
            .await?
        {
            crate::pg_auth_lifecycle::PgPasswordLoginOutcome::Session(response) => {
                Ok(Json(response).into_response())
            }
            crate::pg_auth_lifecycle::PgPasswordLoginOutcome::MfaChallenge {
                challenge_id,
                expires_at,
            } => Ok((
                StatusCode::ACCEPTED,
                Json(json!({
                    "mfa_required": true,
                    "challenge_id": challenge_id,
                    "expires_at": expires_at,
                    "methods": ["totp", "recovery_code"]
                })),
            )
                .into_response()),
        };
    }
    let row = sqlx::query("SELECT u.user_id,c.login_verifier_hash FROM users u JOIN auth_credentials c USING(user_id) WHERE u.username=? AND u.status='active'")
        .bind(username).fetch_optional(&state.db).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        // Keep the nonexistent-account path close to a real wrong-password
        // path by performing the same Argon2 verifier check and a no-op audit
        // transaction. No input-derived scope or event is persisted.
        let _ = check_password_hash(&request.login_verifier, &state.dummy_login_verifier_hash);
        record_login_failure_outcome_best_effort(&state, None).await;
        return Err(ApiError::unauthorized());
    };
    let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
    let verifier_hash: String = row
        .try_get("login_verifier_hash")
        .map_err(ApiError::internal)?;
    if let Err(error) = check_password_hash(&request.login_verifier, &verifier_hash) {
        if error.status == axum::http::StatusCode::UNAUTHORIZED {
            record_login_failure_outcome_best_effort(&state, Some(&user_id)).await;
        }
        return Err(error);
    }
    if let Err(error) = ensure_active_device(&state, &user_id, &request.device_id).await {
        if error.body.code == "DEVICE_REVOKED" {
            record_login_failure_outcome_best_effort(&state, Some(&user_id)).await;
        }
        return Err(error);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Serialize account disable with session creation. The first credential
    // check happens before Argon2 and remains useful for timing consistency;
    // recheck the account, verifier, and device after obtaining SQLite's
    // writer reservation so a login cannot create a live session after an
    // administrator has disabled the account or a password change committed.
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() != 1 {
        return Err(ApiError::unauthorized());
    }
    let current = sqlx::query(
        "SELECT u.status,c.login_verifier_hash,c.credential_version,d.status AS device_status, \
         m.enabled_at,m.totp_seed_envelope \
         FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
         JOIN devices d ON d.user_id=u.user_id \
         LEFT JOIN auth_mfa m ON m.user_id=u.user_id \
         WHERE u.user_id=? AND d.device_id=?",
    )
    .bind(&user_id)
    .bind(&request.device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(current) = current else {
        return Err(ApiError::unauthorized());
    };
    let account_status: String = current.try_get("status").map_err(ApiError::internal)?;
    let current_verifier_hash: String = current
        .try_get("login_verifier_hash")
        .map_err(ApiError::internal)?;
    let device_status: String = current
        .try_get("device_status")
        .map_err(ApiError::internal)?;
    let credential_version: i64 = current
        .try_get("credential_version")
        .map_err(ApiError::internal)?;
    let mfa_enabled: bool = current
        .try_get::<Option<i64>, _>("enabled_at")
        .map_err(ApiError::internal)?
        .is_some()
        && current
            .try_get::<Option<String>, _>("totp_seed_envelope")
            .map_err(ApiError::internal)?
            .is_some();
    if account_status != "active" || current_verifier_hash != verifier_hash {
        return Err(ApiError::unauthorized());
    }
    if device_status != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    if mfa_enabled {
        // The second-factor challenge remains usable without the seed key so a
        // recovery code can restore access during an operator key-file outage.
        // TOTP verification and enrollment still fail closed without that key.
        let now = Utc::now().timestamp();
        let (challenge_id, expires_at) = crate::mfa::create_login_challenge_tx(
            &mut tx,
            &user_id,
            &request.device_id,
            credential_version,
            now,
        )
        .await?;
        crate::audit::record_account_event_tx(
            &mut tx,
            &state,
            &user_id,
            Some(&request.device_id),
            "auth.mfa_login_challenge_created",
            "account",
            Some(&user_id),
            crate::audit::AuditSource::Api,
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok((
            StatusCode::ACCEPTED,
            Json(json!({
                "mfa_required": true,
                "challenge_id": challenge_id,
                "expires_at": expires_at,
                "methods": ["totp", "recovery_code"]
            })),
        )
            .into_response());
    }
    let tokens = insert_session(&mut tx, &user_id, &request.device_id).await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user_id,
        Some(&request.device_id),
        "auth.login_succeeded",
        "account",
        Some(&user_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(session_response(&state, user_id, request.device_id, tokens).await?).into_response())
}

pub(crate) async fn session_response(
    state: &crate::AppState,
    user_id: String,
    device_id: String,
    tokens: Tokens,
) -> Result<SessionResponse, ApiError> {
    let vault_rows = sqlx::query("SELECT v.vault_id,vm.role,v.active_epoch,v.membership_version,v.name_envelope FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE vm.user_id=? AND vm.state='active' AND v.state='active'")
        .bind(&user_id).fetch_all(&state.db).await.map_err(ApiError::internal)?;
    let vaults = vault_rows
        .into_iter()
        .map(|row| {
            let name_envelope = row
                .get::<Option<String>, _>("name_envelope")
                .map(|value| serde_json::from_str::<Value>(&value).map_err(ApiError::internal))
                .transpose()?;
            Ok(json!({
                "vault_id": row.get::<String, _>("vault_id"),
                "role": row.get::<String, _>("role"),
                "active_key_epoch": row.get::<i64, _>("active_epoch"),
                "membership_version": row.get::<i64, _>("membership_version"),
                "name_envelope": name_envelope,
            }))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    Ok(SessionResponse {
        account_id: user_id,
        access_token: tokens.access_token,
        expires_in: tokens.expires_in,
        refresh_token: tokens.refresh_token,
        device_id,
        vaults,
    })
}

/// Failed-login auditing must not change the public authentication response or
/// turn an otherwise ordinary failure into an account-existence oracle. The
/// unattributable path takes the same writer transaction but writes no event.
/// If audit work fails, emit only a fixed warning without input or SQL details.
async fn record_login_failure_outcome_best_effort(state: &AppState, user_id: Option<&str>) {
    let Ok(mut tx) = state.db.begin().await else {
        tracing::warn!(
            event = "auth_login_failure_audit_write_failed",
            "failed-login audit could not be persisted"
        );
        return;
    };
    let write_result = match user_id {
        Some(user_id) => {
            crate::audit::record_failed_login_tx(&mut tx, state, user_id, Utc::now().timestamp())
                .await
                .map_err(|_| ())
        }
        None => sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
            .execute(&mut *tx)
            .await
            .map(|_| ())
            .map_err(|_| ()),
    };
    if write_result.is_err() {
        let _ = tx.rollback().await;
        tracing::warn!(
            event = "auth_login_failure_audit_write_failed",
            "failed-login audit could not be persisted"
        );
        return;
    }
    if tx.commit().await.is_err() {
        tracing::warn!(
            event = "auth_login_failure_audit_write_failed",
            "failed-login audit could not be persisted"
        );
    }
}

async fn record_password_change_failure_best_effort(state: &AppState, user: &AuthUser) {
    let Ok(mut tx) = state.db.begin().await else {
        tracing::warn!(
            event = "auth_password_change_failure_audit_write_failed",
            "failed password-change audit could not be persisted"
        );
        return;
    };
    let written = crate::audit::record_account_failure_event_tx(
        &mut tx,
        state,
        &user.user_id,
        Some(&user.device_id),
        "auth.password_change_failed",
        "account",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await;
    if written.is_err() {
        let _ = tx.rollback().await;
        tracing::warn!(
            event = "auth_password_change_failure_audit_write_failed",
            "failed password-change audit could not be persisted"
        );
        return;
    }
    if tx.commit().await.is_err() {
        tracing::warn!(
            event = "auth_password_change_failure_audit_write_failed",
            "failed password-change audit could not be persisted"
        );
    }
}

#[derive(Deserialize)]
pub struct RefreshRequest {
    pub refresh_token: String,
}

#[derive(FromRow)]
struct RefreshRow {
    session_id: String,
    user_id: String,
    device_id: String,
    family_id: String,
    refresh_expires_at: String,
    revoked_at: Option<String>,
}

pub async fn refresh(
    State(state): State<AppState>,
    Json(request): Json<RefreshRequest>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = state.pg_auth_lifecycle.as_ref() {
        let tokens = repository.refresh_token(&request.refresh_token).await?;
        return Ok(Json(
            serde_json::to_value(tokens).map_err(ApiError::internal)?,
        ));
    }
    let old_hash = sha256_hex(request.refresh_token.as_bytes());
    // Resolve an existing session outside the write transaction so valid
    // refreshes can lock the owning account before examining the session.
    // This orders rotation with administrator disable without taking SQLite's
    // writer reservation for unknown tokens.
    let session_user_id_hint: Option<String> =
        sqlx::query_scalar("SELECT user_id FROM sessions WHERE refresh_hash=?")
            .bind(&old_hash)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?;
    // A consumed token is absent from sessions but still identifies its
    // account through refresh_history. Resolve that hint before beginning a
    // deferred transaction so replay handlers serialize before their fresh
    // history read instead of racing to upgrade concurrent readers to writers.
    let history_user_id_hint: Option<String> =
        sqlx::query_scalar("SELECT user_id FROM refresh_history WHERE refresh_hash=?")
            .bind(&old_hash)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?;
    let user_id_hint = session_user_id_hint.or(history_user_id_hint);
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    if let Some(user_id) = user_id_hint {
        let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if locked.rows_affected() != 1 {
            return Err(ApiError::unauthorized());
        }
        let account_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if account_status != "active" {
            return Err(ApiError::unauthorized());
        }
    }
    let row = sqlx::query_as::<_, RefreshRow>("SELECT session_id,user_id,device_id,family_id,refresh_expires_at,revoked_at FROM sessions WHERE refresh_hash=?")
        .bind(&old_hash).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        let history: Option<(String, String)> =
            sqlx::query_as("SELECT family_id,user_id FROM refresh_history WHERE refresh_hash=?")
                .bind(&old_hash)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if let Some((family, account_id)) = history {
            let revoked = sqlx::query(
                "UPDATE sessions SET revoked_at=? WHERE family_id=? AND revoked_at IS NULL",
            )
            .bind(now_rfc3339())
            .bind(&family)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if revoked.rows_affected() > 0
                && crate::audit::record_unattributed_account_failure_tx(
                    &mut tx,
                    &state,
                    &account_id,
                    "auth.refresh_reuse_detected",
                    "session_family",
                    Some(&family),
                    crate::audit::AuditSource::Api,
                    Utc::now().timestamp(),
                )
                .await
                .is_err()
            {
                // Session-family revocation is the security boundary. Keep the
                // transaction and 401 response fail-secure if its optional
                // audit row cannot be persisted.
                tracing::warn!(
                    event = "auth_refresh_reuse_audit_write_failed",
                    "refresh-token replay revocation could not be audited"
                );
            }
            tx.commit().await.map_err(ApiError::internal)?;
        }
        return Err(ApiError::unauthorized());
    };
    if row.revoked_at.is_some()
        || chrono::DateTime::parse_from_rfc3339(&row.refresh_expires_at)
            .map_or(true, |d| d <= Utc::now())
    {
        return Err(ApiError::unauthorized());
    }
    let statuses: Option<(String, String)> = sqlx::query_as(
        "SELECT u.status,d.status FROM users u JOIN devices d ON d.user_id=u.user_id \
         WHERE u.user_id=? AND d.device_id=?",
    )
    .bind(&row.user_id)
    .bind(&row.device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((account_status, device_status)) = statuses else {
        return Err(ApiError::unauthorized());
    };
    if account_status != "active" {
        return Err(ApiError::unauthorized());
    }
    if device_status != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    let access = random_token();
    let refresh = random_token();
    let now = Utc::now();
    let access_exp = (now + Duration::seconds(ACCESS_TTL_SECONDS)).to_rfc3339();
    let refresh_exp = (now + Duration::days(REFRESH_TTL_DAYS)).to_rfc3339();
    sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES(?,?,?,?,?)")
        .bind(old_hash).bind(&row.family_id).bind(&row.user_id).bind(&row.device_id).bind(now.to_rfc3339()).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE sessions SET access_hash=?,refresh_hash=?,access_expires_at=?,refresh_expires_at=? WHERE session_id=?")
        .bind(sha256_hex(access.as_bytes())).bind(sha256_hex(refresh.as_bytes())).bind(access_exp).bind(refresh_exp).bind(row.session_id)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account_id": row.user_id,
        "device_id": row.device_id,
        "access_token": access,
        "expires_in": ACCESS_TTL_SECONDS,
        "refresh_token": refresh,
    })))
}

#[derive(FromRow)]
struct SessionUserRow {
    user_id: String,
    device_id: String,
    session_id: String,
    access_expires_at: String,
    revoked_at: Option<String>,
}

pub(crate) async fn authenticate(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<AuthUser, ApiError> {
    let token = bearer_token(headers)?;
    if let Some(pg_auth) = state.pg_sync_auth.as_ref() {
        return pg_auth
            .authenticate_token_with_markers(
                token,
                declares_record_schema2(headers),
                declares_sync_redaction_v1(headers),
            )
            .await;
    }
    if token.len() < 32 || token.len() > 128 {
        return Err(ApiError::unauthorized());
    }
    let access_hash = sha256_hex(token.as_bytes());
    let row = sqlx::query_as::<_, SessionUserRow>("SELECT s.user_id,s.device_id,s.session_id,s.access_expires_at,s.revoked_at FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.access_hash=? AND u.status='active' AND d.status='active'")
        .bind(&access_hash).fetch_optional(&state.db).await.map_err(ApiError::internal)?.ok_or_else(ApiError::unauthorized)?;
    if row.revoked_at.is_some()
        || chrono::DateTime::parse_from_rfc3339(&row.access_expires_at)
            .map_or(true, |d| d <= Utc::now())
    {
        return Err(ApiError::unauthorized());
    }
    let user = AuthUser {
        user_id: row.user_id,
        device_id: row.device_id,
        session_id: row.session_id,
        access_hash,
        declares_record_schema2: declares_record_schema2(headers),
        declares_sync_redaction_v1: declares_sync_redaction_v1(headers),
    };
    let lose_v2 = !user.declares_record_schema2
        && crate::device_capabilities::has_v2_report(&state.db, &user.user_id, &user.device_id)
            .await?;
    let lose_redaction = !declares_sync_redaction_v1(headers)
        && sqlx::query_scalar::<_, bool>(
            "SELECT EXISTS(SELECT 1 FROM device_redaction_capability_reports WHERE device_id=? AND user_id=? AND invalidated_at IS NULL)",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(ApiError::internal)?;
    if lose_v2 || lose_redaction {
        // This is the auth-time fast path for reports that already exist.
        // Session-bound write transactions also recheck inside their own fence
        // to cover a request authenticated just before first publication.
        // Offline rollback cannot be detected until this device contacts us.
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        sqlx::query("UPDATE devices SET status=status WHERE device_id=? AND user_id=?")
            .bind(&user.device_id)
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::require_active_session_device_tx(&mut tx, &user).await?;
        if lose_v2 {
            crate::device_capabilities::delete_v2_report_for_device_tx(
                &mut tx,
                &user.user_id,
                &user.device_id,
            )
            .await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
    }
    Ok(user)
}

pub(crate) fn bearer_token(headers: &HeaderMap) -> Result<&str, ApiError> {
    let header = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .ok_or_else(ApiError::unauthorized)?;
    header
        .strip_prefix("Bearer ")
        .ok_or_else(ApiError::unauthorized)
}

pub(crate) fn declares_record_schema2(headers: &HeaderMap) -> bool {
    let mut values = headers.get_all("x-atermius-capability-marker").iter();
    matches!((values.next(), values.next()), (Some(value), None) if value.as_bytes() == b"v2")
}

/// Independent transport declaration for the permanent-redaction wire
/// protocol. Keep this separate from the record-schema marker so older
/// clients and strict v2 report signatures remain compatible.
pub(crate) fn declares_sync_redaction_v1(headers: &HeaderMap) -> bool {
    let mut values = headers.get_all("x-atermius-redaction-marker").iter();
    matches!((values.next(), values.next()), (Some(value), None) if value.as_bytes() == b"v1")
}

pub async fn logout(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_sync_user(&state, &headers).await?;
    if let Some(pg_auth) = state.pg_sync_auth.as_ref() {
        pg_auth
            .revoke_authenticated_session(&user, state.cursor_key.as_ref())
            .await?;
        return Ok(Json(json!({"status":"logged_out"})));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    sqlx::query("UPDATE sessions SET revoked_at=? WHERE session_id=?")
        .bind(now_rfc3339())
        .bind(&user.session_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.logout_succeeded",
        "session",
        Some(&user.session_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"status":"logged_out"})))
}

pub async fn me(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_account_reads.as_ref() {
        let username = repository.username(&user.user_id).await?;
        let instance_admin = state.config.is_instance_admin(&username);
        let recovery_status = if let Some(recovery) = crate::pg_account_recovery::from_state(&state)
        {
            recovery.profile_status(&state, &user.user_id).await?
        } else {
            "disabled"
        };
        return Ok(Json(
            repository
                .me(
                    &user,
                    instance_admin,
                    state.config.registration_open,
                    recovery_status,
                )
                .await?,
        ));
    }
    let username: String = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(&user.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let (account_key_envelope, version): (String, i64) = sqlx::query_as(
        "SELECT account_key_envelope,credential_version FROM auth_credentials WHERE user_id=?",
    )
    .bind(&user.user_id)
    .fetch_one(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let recovery_status = crate::recovery::profile_status(&state, &user.user_id).await?;
    let instance_admin = state.config.is_instance_admin(&username);
    Ok(Json(
        json!({"account_id":user.user_id,"username":username,"device_id":user.device_id,"account_key_envelope":serde_json::from_str::<Value>(&account_key_envelope).unwrap_or(Value::Null),"account_key_envelope_version":version,"recovery_status":recovery_status,"policy":{"registration_open":state.config.registration_open,"instance_admin":instance_admin}}),
    ))
}

#[derive(Deserialize)]
pub struct AddDeviceRequest {
    pub device: DeviceInput,
    pub approver_device_id: String,
    pub certificate_signature: String,
    #[serde(default)]
    pub vault_key_envelopes: Vec<DeviceVaultEnvelope>,
    #[serde(default)]
    pub capability_report: Option<crate::device_capabilities::DeviceCapabilityReport>,
}

#[derive(Deserialize, Serialize)]
pub struct DeviceVaultEnvelope {
    pub vault_id: String,
    pub recipient_device_id: String,
    pub key_epoch: Value,
    pub membership_version: Value,
    pub envelope: Value,
    pub signature: String,
}

pub async fn register_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<AddDeviceRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(repository.register_device(&user, &request).await?));
    }
    if request.approver_device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "approver device does not match current session",
        ));
    }
    let signer: Option<String> = sqlx::query_scalar("SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'").bind(&request.approver_device_id).bind(&user.user_id).fetch_optional(&state.db).await.map_err(ApiError::internal)?;
    let signer = signer
        .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "approving device is unavailable"))?;
    let device = &request.device;
    validate_device(device, &user.user_id, &device.signing_public_key)?;
    if let Some(report) = request.capability_report.as_ref() {
        crate::device_capabilities::validate_report(
            report,
            &user.user_id,
            &device.device_id,
            &device.signing_public_key,
        )?;
    }
    let certificate_payload = jcs(
        &json!({"account_id":user.user_id,"approver_device_id":request.approver_device_id,"device":device}),
    )?;
    verify_key_signature(
        &signer,
        &request.certificate_signature,
        &certificate_payload,
    )?;
    if request.vault_key_envelopes.len() > MAX_DEVICE_VAULT_ENVELOPES {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "too many vault key envelopes",
        ));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let now = now_rfc3339();
    // Serialize device enrollment against vault deletion. A new device must
    // receive every key available to the approving device for active vaults;
    // silently omitting a vault in its deletion grace would leave the key set
    // incomplete and complicate export/recovery.
    sqlx::query(
        "UPDATE vaults SET state=state WHERE vault_id IN (SELECT vault_id FROM vault_members WHERE user_id=? AND state='active')",
    )
    .bind(&user.user_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let deleting_vault: Option<String> = sqlx::query_scalar(
        "SELECT v.vault_id FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE vm.user_id=? AND vm.state='active' AND v.state='deleting' LIMIT 1",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if deleting_vault.is_some() {
        return Err(ApiError::vault_deletion_pending());
    }
    let active_vault_rows=sqlx::query("SELECT v.vault_id,v.active_epoch,v.membership_version FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE vm.user_id=? AND vm.state='active' AND v.state='active' ORDER BY v.vault_id")
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let mut active_vault_contexts =
        std::collections::HashMap::with_capacity(active_vault_rows.len());
    for row in active_vault_rows {
        let vault_id: String = row.get("vault_id");
        let active_epoch: i64 = row.get("active_epoch");
        let membership_version: i64 = row.get("membership_version");
        if active_epoch <= 0 || membership_version <= 0 {
            return Err(ApiError::invalid_envelope(
                "active vault key context is incomplete",
            ));
        }
        active_vault_contexts.insert(vault_id, (active_epoch, membership_version));
    }
    let has_v2_floor: i64 = sqlx::query_scalar(
        r#"SELECT EXISTS(SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id
         WHERE vm.user_id=? AND vm.state='active' AND v.required_record_schema>=2)"#,
    )
    .bind(&user.user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if has_v2_floor != 0
        && request
            .capability_report
            .as_ref()
            .is_none_or(|report| !report.supports_v2())
    {
        return Err(ApiError::conflict(
            "DEVICE_CAPABILITY_REQUIRED",
            "active vault memberships require schema 2, attachment manifest v2, and 1 GiB attachment support",
        ));
    }
    insert_device(&mut tx, device, &user.user_id, &now).await?;
    if let Some(report) = request.capability_report.as_ref() {
        crate::device_capabilities::insert_report_tx(&mut tx, report, &now).await?;
    }
    let source_rows=sqlx::query("SELECT e.vault_id,e.epoch,e.membership_version FROM vault_key_envelopes e JOIN vault_members vm ON vm.vault_id=e.vault_id AND vm.user_id=e.recipient_user_id JOIN vaults v ON v.vault_id=e.vault_id WHERE e.recipient_user_id=? AND e.recipient_device_id=? AND vm.state='active' AND v.state='active' ORDER BY e.vault_id,e.epoch,e.membership_version LIMIT 1001")
        .bind(&user.user_id).bind(&request.approver_device_id).fetch_all(&mut *tx).await.map_err(ApiError::internal)?;
    if source_rows.len() > MAX_DEVICE_VAULT_ENVELOPES {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "too many vault key envelopes",
        ));
    }
    let expected: std::collections::HashSet<(String, i64, i64)> = source_rows
        .iter()
        .map(|r| {
            Ok::<_, ApiError>((
                r.try_get("vault_id").map_err(ApiError::internal)?,
                r.try_get("epoch").map_err(ApiError::internal)?,
                r.try_get("membership_version")
                    .map_err(ApiError::internal)?,
            ))
        })
        .collect::<Result<_, ApiError>>()?;
    let source_vault_ids = expected
        .iter()
        .map(|(vault_id, _, _)| vault_id.clone())
        .collect::<std::collections::HashSet<_>>();
    let active_vault_ids = active_vault_contexts
        .keys()
        .cloned()
        .collect::<std::collections::HashSet<_>>();
    if source_vault_ids != active_vault_ids {
        return Err(ApiError::invalid_envelope(
            "approving device must have a key envelope for every active vault",
        ));
    }
    let mut source_epochs = std::collections::HashMap::<String, Vec<i64>>::new();
    for (vault_id, epoch, membership_version) in &expected {
        let Some((active_epoch, current_membership_version)) = active_vault_contexts.get(vault_id)
        else {
            return Err(ApiError::invalid_envelope(
                "approving device key envelope references an inactive vault",
            ));
        };
        if *epoch <= 0
            || *membership_version <= 0
            || membership_version > current_membership_version
        {
            return Err(ApiError::invalid_envelope(
                "approving device key envelope context is invalid",
            ));
        }
        if *epoch > *active_epoch {
            return Err(ApiError::invalid_envelope(
                "approving device key envelope is from a future key epoch",
            ));
        }
        source_epochs
            .entry(vault_id.clone())
            .or_default()
            .push(*epoch);
    }
    for (vault_id, (active_epoch, _)) in &active_vault_contexts {
        let Some(epochs) = source_epochs.get_mut(vault_id) else {
            return Err(ApiError::invalid_envelope(
                "approving device is missing a vault key epoch",
            ));
        };
        epochs.sort_unstable();
        let expected_epoch_count = usize::try_from(*active_epoch).map_err(ApiError::internal)?;
        if expected_epoch_count > MAX_DEVICE_VAULT_ENVELOPES
            || epochs.len() != expected_epoch_count
            || epochs
                .iter()
                .enumerate()
                .any(|(index, epoch)| *epoch != index as i64 + 1)
        {
            return Err(ApiError::invalid_envelope(
                "approving device must have every historical and active vault key epoch",
            ));
        }
    }
    let mut supplied = std::collections::HashSet::new();
    for e in &request.vault_key_envelopes {
        if !crate::is_canonical_uuid(&e.vault_id)
            || !e.key_epoch.is_i64()
            || !e.membership_version.is_i64()
        {
            return Err(ApiError::invalid_envelope(
                "vault key envelope context is invalid",
            ));
        }
        let epoch = as_counter(&e.key_epoch)
            .ok_or_else(|| ApiError::invalid_envelope("vault key epoch is invalid"))?;
        let membership = as_counter(&e.membership_version)
            .ok_or_else(|| ApiError::invalid_envelope("vault membership version is invalid"))?;
        supplied.insert((e.vault_id.clone(), epoch, membership));
    }
    if supplied.len() != request.vault_key_envelopes.len() || supplied != expected {
        return Err(ApiError::invalid_envelope(
            "new device envelopes must match the approver's complete vault, epoch, and membership set",
        ));
    }
    for key in &request.vault_key_envelopes {
        if key.recipient_device_id != device.device_id || key.envelope.to_string().len() > 64 * 1024
        {
            return Err(ApiError::invalid_envelope(
                "vault key envelope target or size is invalid",
            ));
        }
        let epoch = as_counter(&key.key_epoch)
            .ok_or_else(|| ApiError::invalid_envelope("vault key epoch is invalid"))?;
        let membership = as_counter(&key.membership_version)
            .ok_or_else(|| ApiError::invalid_envelope("vault membership version is invalid"))?;
        let signer_row=sqlx::query("SELECT d.user_id,d.signing_public_key,d.status FROM devices d JOIN vault_members vm ON vm.user_id=d.user_id JOIN vaults v ON v.vault_id=vm.vault_id WHERE d.device_id=? AND vm.vault_id=? AND vm.state='active' AND v.state='active'")
            .bind(&request.approver_device_id).bind(&key.vault_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?.ok_or_else(||ApiError::forbidden("VAULT_ACCESS_REVOKED","approver no longer has access to this vault"))?;
        let signer_status: String = signer_row.get("status");
        let signer_pub: String = signer_row.get("signing_public_key");
        if signer_status != "active" {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "approver device is revoked",
            ));
        }
        let payload = json!({"vault_id":key.vault_id,"recipient_device_id":key.recipient_device_id,"key_epoch":key.key_epoch,"membership_version":key.membership_version,"envelope":key.envelope});
        verify_key_signature(&signer_pub, &key.signature, &jcs(&payload)?)?;
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?)")
            .bind(&key.vault_id).bind(epoch).bind(&user.user_id).bind(&device.device_id).bind(key.envelope.to_string()).bind(&key.signature).bind(&request.approver_device_id).bind(membership).execute(&mut *tx).await.map_err(|_|ApiError::conflict("KEY_ENVELOPE_EXISTS","key envelope already exists for this device"))?;
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "device.registered",
        "device",
        Some(&device.device_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"device_id":device.device_id,"status":"active","vault_key_envelope_count":request.vault_key_envelopes.len()}),
    ))
}

pub async fn list_devices(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_account_reads.as_ref() {
        return Ok(Json(repository.list_devices(&user).await?));
    }
    let rows=sqlx::query("SELECT d.device_id,d.name,d.signing_public_key,d.encryption_public_key,d.status,d.created_at,d.revoked_at,r.revision AS cap_revision,r.user_id AS cap_account_id,r.device_id AS cap_device_id,r.max_record_schema AS cap_max_record_schema,r.host_attachment_manifest_versions AS cap_attachment_versions,r.max_attachment_bytes AS cap_max_attachment_bytes,r.signature AS cap_signature FROM devices d LEFT JOIN device_capability_reports r ON r.device_id=d.device_id AND r.user_id=d.user_id WHERE d.user_id=? ORDER BY d.created_at").bind(&user.user_id).fetch_all(&state.db).await.map_err(ApiError::internal)?;
    let devices:Vec<Value>=rows.into_iter().map(|r|json!({"device_id":r.get::<String,_>("device_id"),"user_id":user.user_id,"name":r.get::<String,_>("name"),"signing_public_key":r.get::<String,_>("signing_public_key"),"encryption_public_key":r.get::<String,_>("encryption_public_key"),"status":r.get::<String,_>("status"),"created_at":r.get::<String,_>("created_at"),"revoked_at":r.get::<Option<String>,_>("revoked_at"),"capability_report":crate::device_capabilities::report_from_row(&r)})).collect();
    Ok(Json(json!({"devices":devices})))
}

pub async fn revoke_device(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(repository.revoke_device(&user, &id).await?));
    }
    let now = now_rfc3339();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let result=sqlx::query("UPDATE devices SET status='revoked',revoked_at=? WHERE device_id=? AND user_id=? AND status='active'").bind(&now).bind(&id).bind(&user.user_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if result.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    sqlx::query("UPDATE sessions SET revoked_at=? WHERE device_id=? AND revoked_at IS NULL")
        .bind(&now)
        .bind(&id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "device.revoked",
        "device",
        Some(&id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"device_id":id,"status":"revoked"})))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        Router,
        body::Body,
        http::{Request, StatusCode, header},
        routing::post,
    };
    use ed25519_dalek::{Signer, SigningKey};
    use http_body_util::BodyExt;
    use sha2::{Digest, Sha256};
    use tower::ServiceExt;

    #[test]
    fn authenticated_principal_debug_redacts_access_hash() {
        let principal = AuthUser {
            user_id: "user-id".into(),
            device_id: "device-id".into(),
            session_id: "session-id".into(),
            access_hash: "request-bound-token-digest".into(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let debug = format!("{principal:?}");
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("request-bound-token-digest"));
    }

    #[tokio::test]
    async fn unmarked_write_fence_invalidates_report_published_after_authentication() {
        let (state, data_dir, access_token) = device_enrollment_state().await;
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            axum::http::HeaderValue::from_str(&format!("Bearer {access_token}")).unwrap(),
        );

        // This is the stale principal captured by an in-flight request before
        // the first capability report has committed.
        let user = authenticate(&state, &headers).await.unwrap();
        assert!(!user.declares_sync_redaction_v1);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM device_redaction_capability_reports WHERE device_id=?",
            )
            .bind(&user.device_id)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0
        );

        // Model another request publishing revision 7 after the stale auth
        // read, then let the delayed request enter its real session/device
        // write fence. The fence must re-read the report despite that auth
        // result and retain its revision as an invalidated watermark.
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,user_id,revision,sync_redaction_version,signature,updated_at \
             ) VALUES(?,?,7,1,'signed-report',?)",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(now_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();

        let mut tx = state.db.begin().await.unwrap();
        crate::require_active_session_device_tx(&mut tx, &user)
            .await
            .unwrap();
        sqlx::query("UPDATE devices SET name=name WHERE device_id=? AND user_id=?")
            .bind(&user.device_id)
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let row = sqlx::query(
            "SELECT revision,invalidated_at FROM device_redaction_capability_reports \
             WHERE device_id=? AND user_id=?",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(row.get::<i64, _>("revision"), 7);
        assert!(row.get::<Option<String>, _>("invalidated_at").is_some());

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[test]
    fn capability_marker_requires_one_exact_canonical_v2_value() {
        let mut headers = HeaderMap::new();
        assert!(!declares_record_schema2(&headers));
        headers.insert(
            "x-atermius-capability-marker",
            axum::http::HeaderValue::from_static("v2"),
        );
        assert!(declares_record_schema2(&headers));
        headers.insert(
            "x-atermius-capability-marker",
            axum::http::HeaderValue::from_static("V2"),
        );
        assert!(!declares_record_schema2(&headers));
        headers.remove("x-atermius-capability-marker");
        headers.append(
            "x-atermius-capability-marker",
            axum::http::HeaderValue::from_static("v2"),
        );
        headers.append(
            "x-atermius-capability-marker",
            axum::http::HeaderValue::from_static("v2"),
        );
        assert!(!declares_record_schema2(&headers));
    }

    #[test]
    fn redaction_marker_is_independent_and_requires_one_exact_value() {
        let mut headers = HeaderMap::new();
        assert!(!declares_sync_redaction_v1(&headers));
        headers.insert(
            "x-atermius-redaction-marker",
            axum::http::HeaderValue::from_static("v1"),
        );
        assert!(declares_sync_redaction_v1(&headers));
        headers.insert(
            "x-atermius-redaction-marker",
            axum::http::HeaderValue::from_static("V1"),
        );
        assert!(!declares_sync_redaction_v1(&headers));
        headers.remove("x-atermius-redaction-marker");
        headers.append(
            "x-atermius-redaction-marker",
            axum::http::HeaderValue::from_static("v1"),
        );
        headers.append(
            "x-atermius-redaction-marker",
            axum::http::HeaderValue::from_static("v1"),
        );
        assert!(!declares_sync_redaction_v1(&headers));
        assert!(!declares_record_schema2(&headers));
    }

    fn sign_json(key: &SigningKey, value: &Value) -> String {
        URL_SAFE_NO_PAD.encode(key.sign(&serde_jcs::to_vec(value).unwrap()).to_bytes())
    }

    async fn device_enrollment_state() -> (crate::AppState, std::path::PathBuf, String) {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-device-enrollment-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let config = crate::Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: data_dir.clone(),
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        };
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();

        let account_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".to_owned();
        let approver_device_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        let vault_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
        let approver_key = SigningKey::from_bytes(&[7_u8; 32]);
        let approver_signing_key = URL_SAFE_NO_PAD.encode(approver_key.verifying_key().as_bytes());
        let approver_encryption_key = URL_SAFE_NO_PAD.encode([9_u8; 32]);
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&account_id)
            .bind("device-enrollment@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
            .bind(approver_device_id)
            .bind(&account_id)
            .bind("approver")
            .bind(approver_signing_key)
            .bind(approver_encryption_key)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        let tokens = insert_session(&mut tx, &account_id, approver_device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,active_epoch,membership_version,created_at) VALUES(?,?,2,1,?)")
            .bind(vault_id)
            .bind(&account_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(vault_id)
            .bind(&account_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        insert_approver_vault_epoch(&state, vault_id, &account_id, approver_device_id, 1).await;
        (state, data_dir, tokens.access_token)
    }

    async fn insert_approver_vault_epoch(
        state: &crate::AppState,
        vault_id: &str,
        account_id: &str,
        approver_device_id: &str,
        epoch: i64,
    ) {
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,1)")
            .bind(vault_id)
            .bind(epoch)
            .bind(account_id)
            .bind(approver_device_id)
            .bind("{}")
            .bind("source-signature")
            .bind(approver_device_id)
            .execute(&state.db)
            .await
            .unwrap();
    }

    fn signed_device_enrollment(
        account_id: &str,
        approver_device_id: &str,
        vault_id: &str,
        approver_key: &SigningKey,
        target_device_id: &str,
        epochs: &[i64],
    ) -> Value {
        let target_key = SigningKey::from_bytes(&[11_u8; 32]);
        let signing_public_key = URL_SAFE_NO_PAD.encode(target_key.verifying_key().as_bytes());
        let encryption_public_key = URL_SAFE_NO_PAD.encode([13_u8; 32]);
        let device_proof = device_proof_payload(
            account_id,
            target_device_id,
            &signing_public_key,
            &encryption_public_key,
        );
        let device = json!({
            "device_id": target_device_id,
            "name": "new device",
            "signing_public_key": signing_public_key,
            "encryption_public_key": encryption_public_key,
            "signature": sign_json(&target_key, &device_proof),
        });
        let certificate_payload = json!({
            "account_id": account_id,
            "approver_device_id": approver_device_id,
            "device": device,
        });
        let vault_key_envelopes = epochs
            .iter()
            .map(|epoch| {
                let envelope = json!({
                    "version": 1,
                    "suite": "crypto_box_seal",
                    "ciphertext": URL_SAFE_NO_PAD.encode([*epoch as u8; 48]),
                });
                let key_payload = json!({
                    "vault_id": vault_id,
                    "recipient_device_id": target_device_id,
                    "key_epoch": epoch,
                    "membership_version": 1,
                    "envelope": envelope,
                });
                json!({
                    "vault_id": vault_id,
                    "recipient_device_id": target_device_id,
                    "key_epoch": epoch,
                    "membership_version": 1,
                    "envelope": envelope,
                    "signature": sign_json(approver_key, &key_payload),
                })
            })
            .collect::<Vec<_>>();
        json!({
            "device": device,
            "approver_device_id": approver_device_id,
            "certificate_signature": sign_json(approver_key, &certificate_payload),
            "vault_key_envelopes": vault_key_envelopes,
        })
    }

    async fn post_device_enrollment(
        app: &Router,
        access_token: &str,
        body: Value,
    ) -> (StatusCode, Value) {
        let response = app
            .clone()
            .oneshot(
                Request::post("/api/v1/devices")
                    .header(header::AUTHORIZATION, format!("Bearer {access_token}"))
                    .header(header::CONTENT_TYPE, "application/json")
                    .body(Body::from(serde_json::to_vec(&body).unwrap()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let body = response.into_body().collect().await.unwrap().to_bytes();
        (status, serde_json::from_slice(&body).unwrap())
    }

    #[tokio::test]
    async fn device_enrollment_rejects_missing_historical_epoch_then_accepts_complete_set() {
        let (state, data_dir, access_token) = device_enrollment_state().await;
        let app = Router::new()
            .route("/api/v1/devices", post(register_device))
            .with_state(state.clone());
        let account_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        let approver_device_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        let vault_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc";
        let target_device_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
        let approver_key = SigningKey::from_bytes(&[7_u8; 32]);

        let incomplete = signed_device_enrollment(
            account_id,
            approver_device_id,
            vault_id,
            &approver_key,
            target_device_id,
            &[1],
        );
        let (status, body) = post_device_enrollment(&app, &access_token, incomplete).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
        assert_eq!(body["error"]["code"], "INVALID_ENVELOPE");
        let target_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id=?")
                .bind(target_device_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            target_count, 0,
            "rejected enrollment must roll back the device row"
        );

        let other_account_id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(other_account_id)
            .bind("other-owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        // Simulate a malformed SQLite row that points at the approving
        // device while claiming another account as its recipient. This row
        // must not count as the missing epoch for the current account.
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,2,?,?,?,?,?,1)")
            .bind(vault_id)
            .bind(other_account_id)
            .bind(approver_device_id)
            .bind("{}")
            .bind("malformed-owner-signature")
            .bind(approver_device_id)
            .execute(&state.db)
            .await
            .unwrap();
        let mismatched_owner = signed_device_enrollment(
            account_id,
            approver_device_id,
            vault_id,
            &approver_key,
            target_device_id,
            &[1, 2],
        );
        let (status, body) = post_device_enrollment(&app, &access_token, mismatched_owner).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{body}");
        assert_eq!(body["error"]["code"], "INVALID_ENVELOPE");
        let target_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id=?")
                .bind(target_device_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            target_count, 0,
            "an envelope owned by another account must not authorize enrollment"
        );
        sqlx::query("DELETE FROM vault_key_envelopes WHERE vault_id=? AND epoch=2 AND recipient_device_id=?")
            .bind(vault_id)
            .bind(approver_device_id)
            .execute(&state.db)
            .await
            .unwrap();

        insert_approver_vault_epoch(&state, vault_id, account_id, approver_device_id, 2).await;
        let complete = signed_device_enrollment(
            account_id,
            approver_device_id,
            vault_id,
            &approver_key,
            target_device_id,
            &[1, 2],
        );
        let (status, body) = post_device_enrollment(&app, &access_token, complete).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        assert_eq!(body["vault_key_envelope_count"], 2);
        let target_envelope_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_device_id=?",
        )
        .bind(target_device_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(target_envelope_count, 2);

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    fn valid_vault() -> (String, DeviceInput, InitialVault) {
        let account_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa".to_owned();
        let device_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".to_owned();
        let key = SigningKey::from_bytes(&[7_u8; 32]);
        let signing_public_key = URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes());
        let encryption_public_key = URL_SAFE_NO_PAD.encode([9_u8; 32]);
        let fingerprint = URL_SAFE_NO_PAD.encode(Sha256::digest(
            URL_SAFE_NO_PAD.decode(&encryption_public_key).unwrap(),
        ));
        let device = DeviceInput {
            name: "test device".into(),
            device_id: device_id.clone(),
            signing_public_key,
            encryption_public_key,
            signature: String::new(),
        };
        let vault_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc".to_owned();
        let manifest = json!({"key_epoch":1,"members":[{"user_id":account_id,"role":"owner","state":"active","encryption_key_fingerprint":fingerprint}],"signer_device_id":device_id});
        let membership_payload = json!({"vault_id":vault_id,"membership_version":1,"previous_digest":null,"manifest":manifest});
        let membership = InitialMembership {
            membership_version: Value::from(1),
            previous_digest: Value::Null,
            manifest,
            signature: sign_json(&key, &membership_payload),
        };
        let envelope = json!({"version":1,"suite":"crypto_box_seal","ciphertext":URL_SAFE_NO_PAD.encode([5_u8;48])});
        let key_payload = json!({"vault_id":vault_id,"recipient_device_id":device_id,"key_epoch":1,"membership_version":1,"envelope":envelope});
        let key_envelope = InitialKeyEnvelope {
            recipient_device_id: device_id,
            key_epoch: Value::from(1),
            membership_version: Value::from(1),
            envelope,
            signature: sign_json(&key, &key_payload),
        };
        let initial = InitialVault {
            vault_id,
            name_envelope: json!({"version":1,"nonce":URL_SAFE_NO_PAD.encode([3_u8;24]),"ciphertext":URL_SAFE_NO_PAD.encode([4_u8;32])}),
            key_epoch: Value::from(1),
            membership_version: Value::from(1),
            key_envelope,
            membership,
        };
        (account_id, device, initial)
    }

    #[test]
    fn initial_vault_accepts_owner_signed_jcs_envelopes() {
        let (account, device, vault) = valid_vault();
        assert!(validate_initial_vault(&vault, &account, &device).is_ok());
    }

    #[test]
    fn initial_membership_storage_matches_signed_chain_record_without_changing_digest() {
        let (account, device, vault) = valid_vault();
        let (_, digest, stored_json) = validate_initial_vault(&vault, &account, &device).unwrap();
        let membership = &vault.membership;
        let signed_payload = json!({
            "vault_id": vault.vault_id,
            "membership_version": membership.membership_version,
            "previous_digest": membership.previous_digest,
            "manifest": membership.manifest,
        });
        assert_eq!(digest, sha256_hex(&jcs(&signed_payload).unwrap()));

        let stored: Value = serde_json::from_str(&stored_json).unwrap();
        assert_eq!(
            stored,
            json!({
                "vault_id": vault.vault_id,
                "membership_version": membership.membership_version,
                "previous_digest": membership.previous_digest,
                "manifest": membership.manifest,
                "signature": membership.signature,
            })
        );
        assert_eq!(stored["signature"], membership.signature);
    }

    #[test]
    fn initial_vault_rejects_extra_member_and_tampered_key_envelope() {
        let (account, device, mut vault) = valid_vault();
        vault.membership.manifest["members"].as_array_mut().unwrap().push(json!({"user_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","role":"viewer","state":"active","encryption_key_fingerprint":"not-used"}));
        assert!(validate_initial_vault(&vault, &account, &device).is_err());

        let (account, device, mut vault) = valid_vault();
        vault.key_envelope.envelope["ciphertext"] =
            Value::String(URL_SAFE_NO_PAD.encode([8_u8; 48]));
        assert!(validate_initial_vault(&vault, &account, &device).is_err());
    }

    #[test]
    fn initial_vault_rejects_noncanonical_display_name_envelope_but_accepts_legacy_manifest() {
        let (account, device, mut vault) = valid_vault();
        // `valid_vault` models a legacy signed manifest without the optional
        // display_name_envelope member. That path remains accepted.
        assert!(validate_initial_vault(&vault, &account, &device).is_ok());

        vault.name_envelope["unexpected"] = Value::Bool(true);
        assert!(validate_initial_vault(&vault, &account, &device).is_err());
    }

    #[test]
    fn initial_vault_accepts_matching_owner_signed_display_name_envelope() {
        let (account, device, mut vault) = valid_vault();
        let key = SigningKey::from_bytes(&[7_u8; 32]);
        vault.membership.manifest["display_name_envelope"] = vault.name_envelope.clone();
        let signed_payload = json!({
            "vault_id": vault.vault_id,
            "membership_version": vault.membership.membership_version,
            "previous_digest": vault.membership.previous_digest,
            "manifest": vault.membership.manifest,
        });
        vault.membership.signature = sign_json(&key, &signed_payload);

        assert!(validate_initial_vault(&vault, &account, &device).is_ok());

        vault.name_envelope["ciphertext"] = Value::String(URL_SAFE_NO_PAD.encode([8_u8; 32]));
        assert!(validate_initial_vault(&vault, &account, &device).is_err());
    }

    fn valid_password_change_json() -> Value {
        json!({
            "operation_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "current_login_verifier": URL_SAFE_NO_PAD.encode([1_u8; 32]),
            "new_kdf": {
                "id": "argon2id13",
                "salt": URL_SAFE_NO_PAD.encode([2_u8; 16]),
                "mem_kib": 65_536,
                "iterations": 3,
                "parallelism": 1,
                "version": 1,
            },
            "new_login_verifier": URL_SAFE_NO_PAD.encode([3_u8; 32]),
            "account_key_envelope": {
                "version": 1,
                "nonce": URL_SAFE_NO_PAD.encode([4_u8; 24]),
                "ciphertext": URL_SAFE_NO_PAD.encode([5_u8; 48]),
            },
        })
    }

    #[test]
    fn password_change_schema_and_operation_id_are_strict() {
        let valid = valid_password_change_json();
        let request: PasswordChangeRequest = serde_json::from_value(valid.clone()).unwrap();
        validate_password_change_operation_id(&request.operation_id).unwrap();
        validate_kdf(&request.new_kdf).unwrap();
        ensure_rewrapped_account_envelope(&request.account_key_envelope).unwrap();

        let mut extra_request_field = valid.clone();
        extra_request_field["unexpected"] = Value::Bool(true);
        assert!(serde_json::from_value::<PasswordChangeRequest>(extra_request_field).is_err());

        let mut extra_kdf_field = valid.clone();
        extra_kdf_field["new_kdf"]["unexpected"] = Value::Bool(true);
        assert!(serde_json::from_value::<PasswordChangeRequest>(extra_kdf_field).is_err());

        let mut invalid_envelope = valid.clone();
        invalid_envelope["account_key_envelope"]["extra"] = Value::String("ignored".into());
        let invalid_envelope: PasswordChangeRequest =
            serde_json::from_value(invalid_envelope).unwrap();
        assert!(ensure_rewrapped_account_envelope(&invalid_envelope.account_key_envelope).is_err());

        assert_eq!(
            validate_password_change_operation_id("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
                .unwrap_err()
                .body
                .code,
            "INVALID_PASSWORD_CHANGE_OPERATION_ID"
        );
    }

    #[test]
    fn password_change_retry_digest_is_keyed_and_binds_the_request() {
        let request: PasswordChangeRequest =
            serde_json::from_value(valid_password_change_json()).unwrap();
        let digest = password_change_request_digest(
            &[6_u8; 32],
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            &request,
        )
        .unwrap();
        assert_eq!(digest.len(), 64);
        assert_ne!(
            digest,
            password_change_request_digest(
                &[7_u8; 32],
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                &request,
            )
            .unwrap()
        );

        let mut changed = valid_password_change_json();
        changed["new_login_verifier"] = Value::String(URL_SAFE_NO_PAD.encode([8_u8; 32]));
        let changed: PasswordChangeRequest = serde_json::from_value(changed).unwrap();
        assert_ne!(
            digest,
            password_change_request_digest(
                &[6_u8; 32],
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                &changed,
            )
            .unwrap()
        );
    }

    #[test]
    fn register_kdf_enforces_client_minimum_and_bounds() {
        let salt = URL_SAFE_NO_PAD.encode([1_u8; 16]);
        let minimum = KdfParams {
            id: "argon2id13".into(),
            salt: salt.clone(),
            mem_kib: 65_536,
            iterations: 3,
            parallelism: 1,
            version: 1,
        };
        assert!(validate_kdf(&minimum).is_ok());
        let weak = KdfParams {
            mem_kib: 65_535,
            ..minimum
        };
        assert!(validate_kdf(&weak).is_err());
    }

    #[test]
    fn unknown_prelogin_decoy_values_are_stable_and_well_formed() {
        let key = [0x5a; 32];
        let first_username = normalized_username(" Missing@Example.TEST ").unwrap();
        let second_username = normalized_username("missing@example.test").unwrap();
        assert_eq!(first_username, second_username);
        let first = prelogin_decoy(&key, &first_username).unwrap();
        let second = prelogin_decoy(&key, &second_username).unwrap();
        let other = prelogin_decoy(&key, "another@example.test").unwrap();
        assert_eq!(first, second);
        assert_ne!(first, other);
        assert_eq!(Uuid::parse_str(&first.0).unwrap().to_string(), first.0);
        assert_eq!(URL_SAFE_NO_PAD.decode(&first.1).unwrap().len(), 16);
    }

    #[test]
    fn dummy_login_verifier_uses_the_regular_argon2_phc_format() {
        let verifier = URL_SAFE_NO_PAD.encode([0_u8; 32]);
        let dummy_hash = dummy_login_verifier_hash().unwrap();
        assert!(check_password_hash(&verifier, &dummy_hash).is_ok());
        assert!(check_password_hash(&URL_SAFE_NO_PAD.encode([1_u8; 32]), &dummy_hash).is_err());
    }

    #[tokio::test]
    async fn refresh_reuse_audit_is_once_and_fail_secure() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-refresh-reuse-audit-{}", Uuid::new_v4()));
        let config = crate::Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: data_dir.clone(),
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        };
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();
        crate::create_bootstrap_token(&state).await.unwrap();

        let (user_id, device, _) = valid_vault();
        let username = "refresh-reuse-audit@example.test";
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(username)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        insert_device(&mut tx, &device, &user_id, &now)
            .await
            .unwrap();
        let active_tokens = insert_session(&mut tx, &user_id, &device.device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let session_id: String =
            sqlx::query_scalar("SELECT session_id FROM sessions WHERE access_hash=?")
                .bind(sha256_hex(active_tokens.access_token.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let family_id: String =
            sqlx::query_scalar("SELECT family_id FROM sessions WHERE session_id=?")
                .bind(&session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let reused_token = "old-refresh-token-must-not-be-persisted";
        sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES(?,?,?,?,?)")
            .bind(sha256_hex(reused_token.as_bytes()))
            .bind(&family_id)
            .bind(&user_id)
            .bind(&device.device_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let another_consumed_token = "second-consumed-token-same-family";
        sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES(?,?,?,?,?)")
            .bind(sha256_hex(another_consumed_token.as_bytes()))
            .bind(&family_id)
            .bind(&user_id)
            .bind(&device.device_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();

        let unknown = refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: "unknown-refresh-token".to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(unknown.body.code, "AUTH_REQUIRED");
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(event_count, 0, "unknown refresh tokens must not be audited");

        let replay = refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: reused_token.to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(replay.body.code, "AUTH_REQUIRED");
        let revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=?")
                .bind(&session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(
            revoked_at.is_some(),
            "refresh reuse must revoke the active family"
        );

        let event = sqlx::query(
            "SELECT scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(event.get::<String, _>("scope_type"), "account");
        assert_eq!(
            event.get::<String, _>("scope_id"),
            crate::audit::account_scope_id(&state.cursor_key, &user_id).unwrap()
        );
        assert_ne!(event.get::<String, _>("scope_id"), user_id);
        assert_eq!(event.get::<Option<String>, _>("actor_user_id"), None);
        assert_eq!(event.get::<Option<String>, _>("actor_device_id"), None);
        assert_eq!(
            event.get::<String, _>("action"),
            "auth.refresh_reuse_detected"
        );
        assert_eq!(event.get::<String, _>("resource_type"), "session_family");
        assert_eq!(
            event.get::<Option<String>, _>("resource_id").as_deref(),
            Some(family_id.as_str())
        );
        assert_eq!(event.get::<String, _>("result"), "failure");
        assert_eq!(event.get::<String, _>("source"), "api");
        let persisted_event = format!(
            "{} {} {} {} {} {}",
            event.get::<String, _>("scope_id"),
            event
                .get::<Option<String>, _>("actor_user_id")
                .unwrap_or_default(),
            event
                .get::<Option<String>, _>("actor_device_id")
                .unwrap_or_default(),
            event.get::<String, _>("action"),
            event.get::<String, _>("resource_type"),
            event
                .get::<Option<String>, _>("resource_id")
                .unwrap_or_default(),
        );
        assert!(!persisted_event.contains(username));
        assert!(!persisted_event.contains(&user_id));
        assert!(!persisted_event.contains(&device.device_id));
        assert!(!persisted_event.contains(reused_token));

        let repeated = refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: reused_token.to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(repeated.body.code, "AUTH_REQUIRED");
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            event_count, 1,
            "replaying a revoked family must not duplicate the event"
        );

        let second_same_family_replay = refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: another_consumed_token.to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(second_same_family_replay.body.code, "AUTH_REQUIRED");
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            event_count, 1,
            "distinct consumed tokens from one family must emit only one event"
        );

        let mut tx = state.db.begin().await.unwrap();
        let second_tokens = insert_session(&mut tx, &user_id, &device.device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let second_session_id: String =
            sqlx::query_scalar("SELECT session_id FROM sessions WHERE access_hash=?")
                .bind(sha256_hex(second_tokens.access_token.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let second_family_id: String =
            sqlx::query_scalar("SELECT family_id FROM sessions WHERE session_id=?")
                .bind(&second_session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let concurrent_reused_token = "concurrent-old-refresh-token";
        sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES(?,?,?,?,?)")
            .bind(sha256_hex(concurrent_reused_token.as_bytes()))
            .bind(&second_family_id)
            .bind(&user_id)
            .bind(&device.device_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();

        let left_state = state.clone();
        let left_token = concurrent_reused_token.to_owned();
        let left = tokio::spawn(async move {
            refresh(
                State(left_state),
                Json(RefreshRequest {
                    refresh_token: left_token,
                }),
            )
            .await
        });
        let right_state = state.clone();
        let right_token = concurrent_reused_token.to_owned();
        let right = tokio::spawn(async move {
            refresh(
                State(right_state),
                Json(RefreshRequest {
                    refresh_token: right_token,
                }),
            )
            .await
        });
        let (left, right) = tokio::join!(left, right);
        let left = left.unwrap().unwrap_err();
        let right = right.unwrap().unwrap_err();
        assert_eq!(left.body.code, "AUTH_REQUIRED");
        assert_eq!(right.body.code, "AUTH_REQUIRED");
        let second_revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=?")
                .bind(&second_session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(
            second_revoked_at.is_some(),
            "both concurrent requests must leave the family revoked"
        );
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            event_count, 2,
            "concurrent replay must persist exactly one event for its family"
        );

        let mut tx = state.db.begin().await.unwrap();
        let third_tokens = insert_session(&mut tx, &user_id, &device.device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let third_session_id: String =
            sqlx::query_scalar("SELECT session_id FROM sessions WHERE access_hash=?")
                .bind(sha256_hex(third_tokens.access_token.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let third_family_id: String =
            sqlx::query_scalar("SELECT family_id FROM sessions WHERE session_id=?")
                .bind(&third_session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let third_reused_token = "third-old-refresh-token";
        sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES(?,?,?,?,?)")
            .bind(sha256_hex(third_reused_token.as_bytes()))
            .bind(&third_family_id)
            .bind(&user_id)
            .bind(&device.device_id)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("CREATE TRIGGER reject_refresh_reuse_audit BEFORE INSERT ON audit_events WHEN NEW.action='auth.refresh_reuse_detected' BEGIN SELECT RAISE(ABORT,'injected audit failure'); END")
            .execute(&state.db)
            .await
            .unwrap();

        let rejected = refresh(
            State(state.clone()),
            Json(RefreshRequest {
                refresh_token: third_reused_token.to_owned(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(rejected.body.code, "AUTH_REQUIRED");
        let third_revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=?")
                .bind(&third_session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(
            third_revoked_at.is_some(),
            "audit failure must not restore or preserve a replayed refresh family"
        );
        let event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            event_count, 2,
            "a rejected audit insert must leave no partial row"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn logout_audit_is_atomic_with_session_revocation() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-logout-audit-{}", Uuid::new_v4()));
        let config = crate::Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: data_dir.clone(),
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        };
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();
        crate::create_bootstrap_token(&state).await.unwrap();

        let (user_id, device, _) = valid_vault();
        let username = "logout-audit@example.test";
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(username)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        insert_device(&mut tx, &device, &user_id, &now)
            .await
            .unwrap();
        let tokens = insert_session(&mut tx, &user_id, &device.device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let session_id: String =
            sqlx::query_scalar("SELECT session_id FROM sessions WHERE access_hash=?")
                .bind(sha256_hex(tokens.access_token.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let authorization = |access_token: &str| {
            let mut headers = HeaderMap::new();
            headers.insert(
                axum::http::header::AUTHORIZATION,
                format!("Bearer {access_token}").parse().unwrap(),
            );
            headers
        };

        assert!(
            logout(State(state.clone()), HeaderMap::new())
                .await
                .is_err()
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.logout_succeeded'"
            )
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0,
            "unauthenticated logout attempts must not be audited"
        );

        let response = logout(State(state.clone()), authorization(&tokens.access_token))
            .await
            .unwrap();
        assert_eq!(response.0["status"], "logged_out");
        let event = sqlx::query(
            "SELECT scope_type,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source FROM audit_events WHERE action='auth.logout_succeeded'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(event.get::<String, _>("scope_type"), "account");
        assert_eq!(
            event.get::<Option<String>, _>("actor_user_id").as_deref(),
            Some(user_id.as_str())
        );
        assert_eq!(
            event.get::<Option<String>, _>("actor_device_id").as_deref(),
            Some(device.device_id.as_str())
        );
        assert_eq!(event.get::<String, _>("action"), "auth.logout_succeeded");
        assert_eq!(event.get::<String, _>("resource_type"), "session");
        assert_eq!(
            event.get::<Option<String>, _>("resource_id").as_deref(),
            Some(session_id.as_str())
        );
        assert_eq!(event.get::<String, _>("result"), "success");
        assert_eq!(event.get::<String, _>("source"), "api");
        let persisted_audit = format!(
            "{} {} {} {} {}",
            event.get::<String, _>("action"),
            event
                .get::<Option<String>, _>("actor_user_id")
                .unwrap_or_default(),
            event
                .get::<Option<String>, _>("actor_device_id")
                .unwrap_or_default(),
            event.get::<String, _>("resource_type"),
            event
                .get::<Option<String>, _>("resource_id")
                .unwrap_or_default(),
        );
        assert!(!persisted_audit.contains(username));
        assert!(!persisted_audit.contains(&tokens.access_token));
        assert!(!persisted_audit.contains(&tokens.refresh_token));
        let revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=?")
                .bind(&session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(
            revoked_at.is_some(),
            "logout must revoke the session in the audited transaction"
        );

        let mut tx = state.db.begin().await.unwrap();
        let retry_tokens = insert_session(&mut tx, &user_id, &device.device_id)
            .await
            .unwrap();
        tx.commit().await.unwrap();
        let retry_session_id: String =
            sqlx::query_scalar("SELECT session_id FROM sessions WHERE access_hash=?")
                .bind(sha256_hex(retry_tokens.access_token.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        sqlx::query("CREATE TRIGGER reject_logout_audit BEFORE INSERT ON audit_events WHEN NEW.action='auth.logout_succeeded' BEGIN SELECT RAISE(ABORT,'injected audit failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        assert!(
            logout(
                State(state.clone()),
                authorization(&retry_tokens.access_token)
            )
            .await
            .is_err(),
            "an audit failure must fail the logout request"
        );
        let retry_revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=?")
                .bind(&retry_session_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(
            retry_revoked_at.is_none(),
            "audit failure must roll back session revocation"
        );
        let logout_event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.logout_succeeded'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            logout_event_count, 1,
            "failed audit insertion must not leave a row"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn invitation_history_pruning_is_bounded_and_preserves_recent_or_pending_rows() {
        let data_dir = std::env::temp_dir().join(format!(
            "atermius-account-invite-prune-test-{}",
            Uuid::new_v4()
        ));
        let config = crate::Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: data_dir.clone(),
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        };
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();
        let now_epoch = 1_800_000_000;
        let cutoff_epoch = now_epoch - 365 * 86_400;
        let timestamp = |epoch| {
            chrono::DateTime::<Utc>::from_timestamp(epoch, 0)
                .unwrap()
                .to_rfc3339()
        };
        let cutoff = timestamp(cutoff_epoch);
        let old = timestamp(cutoff_epoch - 1);
        let recent = timestamp(cutoff_epoch + 1);
        let future = timestamp(now_epoch + 3600);
        let created_at = timestamp(now_epoch - 3 * 365 * 86_400);
        let mut tx = state.db.begin().await.unwrap();

        for index in 0..1001 {
            let invitation_id = format!("prune-old-{index:04}");
            let token_hash = format!("prune-token-hash-{index:04}");
            let (expires_at, consumed_at, revoked_at) = match index % 3 {
                0 => (future.as_str(), Some(old.as_str()), None),
                1 => (future.as_str(), None, Some(old.as_str())),
                _ => (old.as_str(), None, None),
            };
            sqlx::query(
                "INSERT INTO account_invitations(\
                    invitation_id,token_hash,username,created_at,expires_at,consumed_at,revoked_at\
                ) VALUES(?,?,?,?,?,?,?)",
            )
            .bind(invitation_id)
            .bind(token_hash)
            .bind(format!("old-{index}@example.test"))
            .bind(&created_at)
            .bind(expires_at)
            .bind(consumed_at)
            .bind(revoked_at)
            .execute(&mut *tx)
            .await
            .unwrap();
        }

        let retained = [
            ("consumed-boundary", &future, Some(&cutoff), None),
            ("consumed-recent", &future, Some(&recent), None),
            ("revoked-boundary", &future, None, Some(&cutoff)),
            ("revoked-recent", &future, None, Some(&recent)),
            ("expired-boundary", &cutoff, None, None),
            ("expired-recent", &recent, None, None),
            ("pending-unexpired", &future, None, None),
        ];
        for (invitation_id, expires_at, consumed_at, revoked_at) in retained {
            sqlx::query(
                "INSERT INTO account_invitations(\
                    invitation_id,token_hash,username,created_at,expires_at,consumed_at,revoked_at\
                ) VALUES(?,?,?,?,?,?,?)",
            )
            .bind(invitation_id)
            .bind(format!("hash-{invitation_id}"))
            .bind(format!("{invitation_id}@example.test"))
            .bind(&created_at)
            .bind(expires_at)
            .bind(consumed_at.cloned())
            .bind(revoked_at.cloned())
            .execute(&mut *tx)
            .await
            .unwrap();
        }
        sqlx::query(
            "INSERT INTO audit_events(\
                scope_type,scope_id,action,resource_type,result,occurred_at,source\
            ) VALUES('instance','test-instance','instance.account_invitation_issued',\
                'account_invitation','success',?,'maintenance')",
        )
        .bind(now_epoch)
        .execute(&mut *tx)
        .await
        .unwrap();
        tx.commit().await.unwrap();

        prune_account_invitations(&state, now_epoch, 1)
            .await
            .unwrap();
        let stale_after_first: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM account_invitations WHERE \
                (consumed_at IS NOT NULL AND consumed_at < ?) OR \
                (revoked_at IS NOT NULL AND revoked_at < ?) OR \
                (consumed_at IS NULL AND revoked_at IS NULL AND expires_at < ?)",
        )
        .bind(&cutoff)
        .bind(&cutoff)
        .bind(&cutoff)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(stale_after_first, 501, "one call is capped at 500 rows");

        prune_account_invitations(&state, now_epoch, 4)
            .await
            .unwrap();
        let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_invitations")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(remaining, 7, "a later maintenance pass drains the backlog");
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='instance.account_invitation_issued'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 1, "invitation pruning preserves audit events");
        for invitation_id in [
            "consumed-boundary",
            "consumed-recent",
            "revoked-boundary",
            "revoked-recent",
            "expired-boundary",
            "expired-recent",
            "pending-unexpired",
        ] {
            let exists: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM account_invitations WHERE invitation_id=?",
            )
            .bind(invitation_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            assert_eq!(exists, 1, "retention boundary removed {invitation_id}");
        }

        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn account_invitation_is_normalized_hashed_and_reissued_tokens_are_revoked() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-account-invite-test-{}", Uuid::new_v4()));
        let config = crate::Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: data_dir.clone(),
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        };
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();
        crate::create_bootstrap_token(&state).await.unwrap();
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
            .bind("owner@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE instance_meta SET setup_consumed_at=? WHERE id=1")
            .bind(now)
            .execute(&state.db)
            .await
            .unwrap();

        let (first, normalized, _) =
            create_account_invitation(&state, "  New.User@Example.TEST  ", Some(3600))
                .await
                .unwrap();
        assert_eq!(normalized, "new.user@example.test");
        let second = create_account_invitation(&state, "new.user@example.test", None)
            .await
            .unwrap()
            .0;
        assert_ne!(first, second);
        let first_hash = sha256_hex(first.as_bytes());
        let second_hash = sha256_hex(second.as_bytes());
        let first_row =
            sqlx::query("SELECT token_hash,revoked_at FROM account_invitations WHERE token_hash=?")
                .bind(first_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(first_row.get::<Option<String>, _>("revoked_at").is_some());
        assert_eq!(
            first_row.get::<String, _>("token_hash"),
            sha256_hex(first.as_bytes())
        );
        let second_revoked: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM account_invitations WHERE token_hash=?")
                .bind(second_hash)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(second_revoked.is_none());
        let issued_events = sqlx::query("SELECT scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source FROM audit_events WHERE action='instance.account_invitation_issued' ORDER BY event_id")
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert_eq!(issued_events.len(), 2);
        let first_invitation_id: String =
            sqlx::query_scalar("SELECT invitation_id FROM account_invitations WHERE token_hash=?")
                .bind(sha256_hex(first.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let second_invitation_id: String =
            sqlx::query_scalar("SELECT invitation_id FROM account_invitations WHERE token_hash=?")
                .bind(sha256_hex(second.as_bytes()))
                .fetch_one(&state.db)
                .await
                .unwrap();
        let revoked_events = sqlx::query("SELECT scope_type,actor_user_id,actor_device_id,action,resource_type,resource_id,result,source FROM audit_events WHERE action='instance.account_invitation_revoked'")
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert_eq!(revoked_events.len(), 1);
        assert_eq!(revoked_events[0].get::<String, _>("scope_type"), "instance");
        assert_eq!(
            revoked_events[0].get::<Option<String>, _>("actor_user_id"),
            None
        );
        assert_eq!(
            revoked_events[0].get::<Option<String>, _>("actor_device_id"),
            None
        );
        assert_eq!(
            revoked_events[0].get::<String, _>("action"),
            "instance.account_invitation_revoked"
        );
        assert_eq!(
            revoked_events[0].get::<String, _>("resource_type"),
            "account_invitation"
        );
        let revoked_resource_id = revoked_events[0]
            .get::<Option<String>, _>("resource_id")
            .unwrap();
        assert_eq!(revoked_resource_id.len(), 64);
        assert_ne!(revoked_resource_id, first_invitation_id);
        assert_eq!(revoked_events[0].get::<String, _>("result"), "success");
        assert_eq!(revoked_events[0].get::<String, _>("source"), "maintenance");
        for (row, expected_id) in issued_events
            .iter()
            .zip([first_invitation_id.as_str(), second_invitation_id.as_str()])
        {
            assert_eq!(row.get::<String, _>("scope_type"), "instance");
            assert_eq!(row.get::<String, _>("scope_id").len(), 64);
            assert_eq!(row.get::<Option<String>, _>("actor_user_id"), None);
            assert_eq!(row.get::<Option<String>, _>("actor_device_id"), None);
            assert_eq!(
                row.get::<String, _>("action"),
                "instance.account_invitation_issued"
            );
            assert_eq!(row.get::<String, _>("resource_type"), "account_invitation");
            let resource_id = row.get::<Option<String>, _>("resource_id").unwrap();
            assert_eq!(resource_id.len(), 64);
            assert_ne!(resource_id, expected_id);
            assert_eq!(row.get::<String, _>("result"), "success");
            assert_eq!(row.get::<String, _>("source"), "maintenance");
            let audit_fields = [
                row.get::<String, _>("scope_type"),
                row.get::<String, _>("scope_id"),
                row.get::<Option<String>, _>("actor_user_id")
                    .unwrap_or_default(),
                row.get::<Option<String>, _>("actor_device_id")
                    .unwrap_or_default(),
                row.get::<String, _>("action"),
                row.get::<String, _>("resource_type"),
                row.get::<Option<String>, _>("resource_id")
                    .unwrap_or_default(),
                row.get::<String, _>("result"),
                row.get::<String, _>("source"),
            ];
            let serialized = audit_fields.join(" ");
            assert!(!serialized.contains("new.user@example.test"));
            assert!(!serialized.contains(&first));
            assert!(!serialized.contains(&second));
            assert!(!serialized.contains(&sha256_hex(first.as_bytes())));
            assert!(!serialized.contains(&sha256_hex(second.as_bytes())));
            assert!(!serialized.contains(expected_id));
        }
        assert!(
            create_account_invitation(&state, "new.user@example.test", Some(59))
                .await
                .is_err()
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }
}

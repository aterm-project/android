//! Client-encrypted account recovery.
//!
//! This module never decrypts a recovery envelope or Vault key. It validates
//! detached signatures and public context, then atomically stores opaque boxes.

use std::collections::{BTreeMap, BTreeSet};

use axum::{
    Json,
    extract::{ConnectInfo, State},
    http::HeaderMap,
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::Utc;
use ed25519_dalek::VerifyingKey;
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, SqliteConnection, Transaction};
use std::net::SocketAddr;
use uuid::Uuid;

use crate::{ApiError, AppState, auth::AuthUser};

type HmacSha256 = Hmac<Sha256>;
pub(crate) const RECOVERY_PROTOCOL: &str = "atermius-account-recovery-v1";
pub(crate) const DESCRIPTOR_PROTOCOL: &str = "atermius-account-recovery-descriptor-v1";
pub(crate) const INSPECT_PROTOCOL: &str = "atermius-account-recovery-inspect-v1";
const COMPLETE_TTL_SECONDS: i64 = 5 * 60;
const RECOVERY_CHALLENGE_PRUNE_BATCH_SIZE: i64 = 500;
pub(crate) const RECOVERY_CHALLENGE_PRUNE_BATCHES_PER_MAINTENANCE: usize = 4;
pub(crate) const MAX_KEY_ENVELOPES: usize = 1000;
pub(crate) const MAX_ENVELOPE_BYTES: usize = 64 * 1024;

/// Transaction gates used only by deterministic tests for Recovery/purge
/// serialization. They are passed to the same internal handlers that serve
/// production requests; normal route calls never install gates.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct RecoveryPurgeTestHooks {
    pub(crate) completion_after_preflight: Option<std::sync::Arc<TestPause>>,
    pub(crate) completion_writer_reserved: Option<std::sync::Arc<TestPause>>,
    pub(crate) purge_before_writer_reservation: Option<std::sync::Arc<TestPause>>,
    pub(crate) purge_writer_reserved: Option<std::sync::Arc<TestPause>>,
}

#[cfg(test)]
pub(crate) struct TestPause {
    reached_tx: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    reached_rx: std::sync::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
    release_tx: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    release_rx: std::sync::Mutex<Option<tokio::sync::oneshot::Receiver<()>>>,
}

#[cfg(test)]
impl TestPause {
    pub(crate) fn new() -> Self {
        let (reached_tx, reached_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = tokio::sync::oneshot::channel();
        Self {
            reached_tx: std::sync::Mutex::new(Some(reached_tx)),
            reached_rx: std::sync::Mutex::new(Some(reached_rx)),
            release_tx: std::sync::Mutex::new(Some(release_tx)),
            release_rx: std::sync::Mutex::new(Some(release_rx)),
        }
    }

    pub(crate) async fn wait_until_reached(&self) {
        let reached = self
            .reached_rx
            .lock()
            .expect("test gate mutex poisoned")
            .take()
            .expect("test gate can only be awaited once");
        reached.await.expect("test gate sender was dropped");
    }

    pub(crate) fn release(&self) {
        if let Some(release) = self
            .release_tx
            .lock()
            .expect("test gate mutex poisoned")
            .take()
        {
            let _ = release.send(());
        }
    }

    pub(crate) async fn pause(&self) {
        if let Some(reached) = self
            .reached_tx
            .lock()
            .expect("test gate mutex poisoned")
            .take()
        {
            let _ = reached.send(());
        }
        let release = self
            .release_rx
            .lock()
            .expect("test gate mutex poisoned")
            .take()
            .expect("test gate can only pause once");
        let _ = release.await;
    }
}

#[cfg(test)]
pub(crate) struct ReleasePauseOnDrop(std::sync::Arc<TestPause>);

#[cfg(test)]
impl ReleasePauseOnDrop {
    pub(crate) fn new(pause: std::sync::Arc<TestPause>) -> Self {
        Self(pause)
    }
}

#[cfg(test)]
impl Drop for ReleasePauseOnDrop {
    fn drop(&mut self) {
        self.0.release();
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecoveryKeyEnvelope {
    pub vault_id: String,
    pub key_epoch: i64,
    pub envelope: Value,
    pub uploader_device_id: String,
    #[serde(default)]
    pub envelope_sha256: Option<String>,
    pub recovery_signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConfigureRequest {
    pub operation_id: String,
    pub current_login_verifier: String,
    pub recovery_generation: i64,
    pub recovery_public_signing_key: String,
    pub recovery_public_encryption_key: String,
    pub recovery_envelope: Value,
    pub recovery_identity_envelope: Value,
    pub key_envelopes: Vec<RecoveryKeyEnvelope>,
    pub recovery_identity_proof_signature: String,
    pub proof_signature: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub previous_recovery_signature: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DisableRequest {
    pub operation_id: String,
    pub current_login_verifier: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UploadRequest {
    pub operation_id: String,
    pub recovery_generation: i64,
    pub recovery_descriptor_hash: String,
    pub key_envelopes: Vec<RecoveryKeyEnvelope>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartRequest {
    pub username: String,
}

/// Removes expired or consumed challenges in a bounded number of SQLite
/// delete batches. Each statement commits independently; a large backlog is
/// resumed by the next maintenance pass. The fixed cutoff keeps a pass
/// deterministic.
pub(crate) async fn prune_challenges(
    state: &AppState,
    now: i64,
    max_batches: usize,
) -> Result<(), ApiError> {
    for _ in 0..max_batches {
        let deleted = sqlx::query(
            "DELETE FROM account_recovery_challenges WHERE rowid IN (\
                SELECT rowid FROM account_recovery_challenges \
                WHERE expires_at<=? OR consumed_at IS NOT NULL \
                ORDER BY expires_at, challenge_id_hash LIMIT ?\
            )",
        )
        .bind(now)
        .bind(RECOVERY_CHALLENGE_PRUNE_BATCH_SIZE)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();

        if deleted < RECOVERY_CHALLENGE_PRUNE_BATCH_SIZE as u64 {
            break;
        }
    }
    Ok(())
}

async fn prune_challenges_in_transaction(
    tx: &mut Transaction<'_, sqlx::Sqlite>,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "DELETE FROM account_recovery_challenges WHERE rowid IN (\
            SELECT rowid FROM account_recovery_challenges \
            WHERE expires_at<=? OR consumed_at IS NOT NULL \
            ORDER BY expires_at, challenge_id_hash LIMIT ?\
        )",
    )
    .bind(now)
    .bind(RECOVERY_CHALLENGE_PRUNE_BATCH_SIZE)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InspectRequest {
    pub account_id: String,
    pub instance_id: String,
    pub server_space_id: String,
    pub recovery_generation: i64,
    pub challenge_id: String,
    pub challenge: String,
    pub recovery_signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CompletionDevice {
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CompletionVaultKeyEnvelope {
    pub vault_id: String,
    pub recipient_device_id: String,
    pub key_epoch: i64,
    pub membership_version: i64,
    pub envelope: Value,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NextRecovery {
    pub recovery_public_signing_key: String,
    pub recovery_public_encryption_key: String,
    pub recovery_envelope: Value,
    pub recovery_identity_envelope: Value,
    pub key_envelopes: Vec<RecoveryKeyEnvelope>,
    pub recovery_identity_proof_signature: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CompleteRequest {
    pub operation_id: String,
    pub account_id: String,
    pub instance_id: String,
    pub server_space_id: String,
    pub recovery_generation: i64,
    pub challenge_id: String,
    pub challenge: String,
    pub recovery_signature: String,
    pub new_kdf: crate::auth::KdfParams,
    pub new_login_verifier: String,
    pub account_key_envelope: Value,
    pub device: CompletionDevice,
    pub vault_key_envelopes: Vec<CompletionVaultKeyEnvelope>,
    pub next_recovery: NextRecovery,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Context {
    pub(crate) vault_id: String,
    pub(crate) key_epoch: i64,
    pub(crate) membership_version: i64,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct PresentContext {
    pub(crate) vault_id: String,
    pub(crate) key_epoch: i64,
    pub(crate) envelope: Value,
    pub(crate) envelope_sha256: String,
    pub(crate) recovery_signature: String,
    pub(crate) uploader_device_id: String,
}

#[derive(Debug, Clone)]
pub(crate) struct RecoveryDescriptor {
    pub(crate) generation: i64,
    pub(crate) public_signing_key: String,
    pub(crate) public_encryption_key: String,
    pub(crate) identity_envelope: String,
}

pub(crate) fn failed_recovery() -> ApiError {
    ApiError::new(
        axum::http::StatusCode::UNAUTHORIZED,
        "RECOVERY_FAILED",
        "account recovery could not be completed",
    )
}

pub(crate) fn stale_recovery() -> ApiError {
    ApiError::conflict(
        "RECOVERY_STALE",
        "the account Vault key context changed; refresh recovery data and retry",
    )
}

pub(crate) fn validate_operation_id(operation_id: &str) -> Result<(), ApiError> {
    if crate::is_canonical_uuid(operation_id) {
        Ok(())
    } else {
        Err(ApiError::bad_request(
            "INVALID_RECOVERY_OPERATION_ID",
            "operation_id must be a lowercase canonical UUID",
        ))
    }
}

pub(crate) fn decode_b64(value: &str, expected_len: Option<usize>) -> Result<Vec<u8>, ApiError> {
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ApiError::invalid_envelope("recovery envelope encoding is invalid"))?;
    if expected_len.is_some_and(|length| decoded.len() != length) {
        return Err(ApiError::invalid_envelope(
            "recovery envelope has an invalid byte length",
        ));
    }
    Ok(decoded)
}

pub(crate) fn validate_public_keys(signing: &str, encryption: &str) -> Result<(), ApiError> {
    let signing_raw = decode_b64(signing, Some(32))?;
    let encryption_raw = decode_b64(encryption, Some(32))?;
    let signing_bytes: [u8; 32] = signing_raw
        .as_slice()
        .try_into()
        .map_err(ApiError::internal)?;
    VerifyingKey::from_bytes(&signing_bytes)
        .map_err(|_| ApiError::invalid_envelope("Recovery signing public key is invalid"))?;
    if signing_raw == encryption_raw || encryption_raw.iter().all(|byte| *byte == 0) {
        return Err(ApiError::invalid_envelope(
            "Recovery signing and encryption keys must be distinct valid keys",
        ));
    }
    Ok(())
}

pub(crate) fn validate_opaque_envelope(value: &Value, label: &str) -> Result<String, ApiError> {
    let object = value.as_object().ok_or_else(|| {
        ApiError::invalid_envelope(&format!("{label} must be an opaque version-1 envelope"))
    })?;
    if object.len() != 4
        || value.get("version").and_then(Value::as_i64) != Some(1)
        || value.get("suite").and_then(Value::as_str) != Some("xchacha20-poly1305-ietf")
    {
        return Err(ApiError::invalid_envelope(&format!(
            "{label} must contain only version, suite, nonce and ciphertext"
        )));
    }
    let nonce = value
        .get("nonce")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope(&format!("{label} nonce is missing")))?;
    decode_b64(nonce, Some(24))?;
    let ciphertext = value
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope(&format!("{label} ciphertext is missing")))?;
    let raw = decode_b64(ciphertext, None)?;
    let padded_recovery_envelope =
        label == "recovery envelope" || label == "next recovery envelope";
    if raw.len() < 16
        || raw.len() > MAX_ENVELOPE_BYTES
        || (padded_recovery_envelope && raw.len() != 528)
    {
        return Err(ApiError::invalid_envelope(&format!(
            "{label} ciphertext size is invalid"
        )));
    }
    Ok(value.to_string())
}

pub(crate) fn recovery_box_bytes(envelope: &Value) -> Result<Vec<u8>, ApiError> {
    let object = envelope
        .as_object()
        .ok_or_else(|| ApiError::invalid_envelope("recovery key envelope is invalid"))?;
    if object.len() != 3
        || envelope.get("version").and_then(Value::as_i64) != Some(1)
        || envelope.get("suite").and_then(Value::as_str) != Some("crypto_box_seal")
    {
        return Err(ApiError::invalid_envelope(
            "recovery key envelope must contain only version, suite and ciphertext",
        ));
    }
    let ciphertext = envelope
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("recovery key envelope ciphertext is missing"))?;
    let raw = decode_b64(ciphertext, None)?;
    // crypto_box_seal output carries the 48-byte libsodium overhead.
    if raw.len() < 48 || raw.len() > MAX_ENVELOPE_BYTES {
        return Err(ApiError::invalid_envelope(
            "recovery key envelope size is invalid",
        ));
    }
    Ok(raw)
}

pub(crate) fn descriptor_hash(
    state: &AppState,
    account_id: &str,
    generation: i64,
    signing: &str,
    encryption: &str,
) -> Result<String, ApiError> {
    let payload = json!({
        "protocol": DESCRIPTOR_PROTOCOL,
        "account_id": account_id,
        "instance_id": state.instance.instance_id,
        "server_space_id": state.instance.server_space_id,
        "recovery_generation": generation,
        "recovery_public_signing_key": signing,
        "recovery_public_encryption_key": encryption,
    });
    Ok(crate::sha256_hex(&crate::jcs(&payload)?))
}

pub(crate) fn descriptor_hash_current(
    state: &AppState,
    account_id: &str,
    descriptor: &RecoveryDescriptor,
) -> Result<String, ApiError> {
    descriptor_hash(
        state,
        account_id,
        descriptor.generation,
        &descriptor.public_signing_key,
        &descriptor.public_encryption_key,
    )
}

pub(crate) fn recovery_box_payload(
    state: &AppState,
    account_id: &str,
    generation: i64,
    descriptor_hash: &str,
    vault_id: &str,
    key_epoch: i64,
    envelope: &Value,
    uploader_device_id: &str,
) -> Result<Value, ApiError> {
    let raw = recovery_box_bytes(envelope)?;
    Ok(json!({
        "protocol": RECOVERY_PROTOCOL,
        "account_id": account_id,
        "instance_id": state.instance.instance_id,
        "server_space_id": state.instance.server_space_id,
        "recovery_generation": generation,
        "recovery_descriptor_hash": descriptor_hash,
        "vault_id": vault_id,
        "key_epoch": key_epoch,
        "uploader_device_id": uploader_device_id,
        "envelope_sha256": crate::sha256_hex(&raw),
    }))
}

pub(crate) fn recovery_box_set(
    boxes: &[RecoveryKeyEnvelope],
) -> Result<BTreeMap<(String, i64), &RecoveryKeyEnvelope>, ApiError> {
    if boxes.len() > MAX_KEY_ENVELOPES {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "too many Recovery key envelopes",
        ));
    }
    let mut result = BTreeMap::new();
    for envelope in boxes {
        if !crate::is_canonical_uuid(&envelope.vault_id) || envelope.key_epoch <= 0 {
            return Err(ApiError::invalid_envelope(
                "recovery key envelope context is invalid",
            ));
        }
        recovery_box_bytes(&envelope.envelope)?;
        if result
            .insert((envelope.vault_id.clone(), envelope.key_epoch), envelope)
            .is_some()
        {
            return Err(ApiError::invalid_envelope(
                "recovery key envelope context is duplicated",
            ));
        }
    }
    Ok(result)
}

pub(crate) fn verify_recovery_boxes<'a>(
    state: &AppState,
    account_id: &str,
    generation: i64,
    signing_key: &str,
    encryption_key: &str,
    uploader_device_id: &str,
    boxes: &'a [RecoveryKeyEnvelope],
) -> Result<BTreeMap<(String, i64), &'a RecoveryKeyEnvelope>, ApiError> {
    validate_public_keys(signing_key, encryption_key)?;
    let descriptor = descriptor_hash(state, account_id, generation, signing_key, encryption_key)?;
    let set = recovery_box_set(boxes)?;
    for entry in set.values() {
        let payload = recovery_box_payload(
            state,
            account_id,
            generation,
            &descriptor,
            &entry.vault_id,
            entry.key_epoch,
            &entry.envelope,
            &entry.uploader_device_id,
        )?;
        if entry.uploader_device_id != uploader_device_id {
            return Err(ApiError::invalid_envelope(
                "recovery key envelope uploader does not match the authenticated device",
            ));
        }
        let actual_hash = crate::sha256_hex(&recovery_box_bytes(&entry.envelope)?);
        if entry
            .envelope_sha256
            .as_deref()
            .is_some_and(|hash| hash != actual_hash)
        {
            return Err(ApiError::invalid_envelope(
                "recovery key envelope ciphertext hash is invalid",
            ));
        }
        crate::auth::verify_key_signature(
            signing_key,
            &entry.recovery_signature,
            &crate::jcs(&payload)?,
        )?;
    }
    Ok(set)
}

pub(crate) fn request_digest<T: Serialize>(
    state: &AppState,
    user_id: &str,
    operation_id: &str,
    request: &T,
) -> Result<String, ApiError> {
    let body = crate::jcs(request)?;
    let mut mac =
        HmacSha256::new_from_slice(state.auth_rate_key.as_ref()).map_err(ApiError::internal)?;
    mac.update(b"atermius/account-recovery-idempotency/v1\0");
    mac.update(user_id.as_bytes());
    mac.update(b"\0");
    mac.update(operation_id.as_bytes());
    mac.update(b"\0");
    mac.update(&body);
    Ok(hex::encode(mac.finalize().into_bytes()))
}

async fn receipt(
    tx: &mut Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    operation_id: &str,
    digest: &str,
) -> Result<Option<Value>, ApiError> {
    let row = sqlx::query(
        "SELECT request_digest,response_json FROM account_recovery_receipts WHERE user_id=? AND operation_id=?",
    )
    .bind(user_id)
    .bind(operation_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else { return Ok(None) };
    let saved_digest: String = row.try_get("request_digest").map_err(ApiError::internal)?;
    if saved_digest != digest {
        return Err(ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "recovery operation ID was reused with different content",
        ));
    }
    let json: String = row.try_get("response_json").map_err(ApiError::internal)?;
    serde_json::from_str(&json)
        .map(Some)
        .map_err(ApiError::internal)
}

async fn save_receipt(
    tx: &mut Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    operation_id: &str,
    digest: &str,
    response: &Value,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO account_recovery_receipts(user_id,operation_id,request_digest,response_json,created_at) VALUES(?,?,?,?,?)")
        .bind(user_id)
        .bind(operation_id)
        .bind(digest)
        .bind(response.to_string())
        .bind(Utc::now().timestamp())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) fn retry_response(mut response: Value) -> Value {
    if let Some(object) = response.as_object_mut() {
        object.insert("already_applied".into(), Value::Bool(true));
    }
    response
}

async fn take_rate_limit(
    state: &AppState,
    operation: crate::rate_limit::AuthOperation,
    username: &str,
    peer: SocketAddr,
) -> Result<(), ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let limited =
        crate::rate_limit::consume(state, &mut tx, operation, username, Some(peer.ip())).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    if let Some(seconds) = limited {
        return Err(ApiError::rate_limited(seconds));
    }
    Ok(())
}

async fn take_authenticated_reauth_limit(
    state: &AppState,
    user_id: &str,
    peer: SocketAddr,
) -> Result<(), ApiError> {
    let username: String = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
    take_rate_limit(
        state,
        crate::rate_limit::AuthOperation::Login,
        &username,
        peer,
    )
    .await
}

async fn recovery_anonymous_rate_subject(
    state: &AppState,
    user_id: &str,
) -> Result<String, ApiError> {
    Ok(
        sqlx::query_scalar::<_, String>("SELECT username FROM users WHERE user_id=?")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?
            .unwrap_or_else(|| format!("unknown:{user_id}")),
    )
}

async fn account_recovery(
    conn: &mut SqliteConnection,
    user_id: &str,
) -> Result<Option<RecoveryDescriptor>, ApiError> {
    let row = sqlx::query("SELECT recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_identity_envelope FROM account_recovery WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    row.map(|row| {
        Ok(RecoveryDescriptor {
            generation: row
                .try_get("recovery_generation")
                .map_err(ApiError::internal)?,
            public_signing_key: row
                .try_get("recovery_public_signing_key")
                .map_err(ApiError::internal)?,
            public_encryption_key: row
                .try_get("recovery_public_encryption_key")
                .map_err(ApiError::internal)?,
            identity_envelope: row
                .try_get("recovery_identity_envelope")
                .map_err(ApiError::internal)?,
        })
    })
    .transpose()
}

async fn last_recovery_generation(
    conn: &mut SqliteConnection,
    user_id: &str,
) -> Result<i64, ApiError> {
    Ok(sqlx::query_scalar::<_, i64>(
        "SELECT last_generation FROM account_recovery_generation WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_optional(&mut *conn)
    .await
    .map_err(ApiError::internal)?
    .unwrap_or(0))
}

fn next_recovery_generation(last_generation: i64) -> Option<i64> {
    last_generation.checked_add(1).filter(|next| *next > 0)
}

async fn save_recovery_generation(
    conn: &mut SqliteConnection,
    user_id: &str,
    generation: i64,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO account_recovery_generation(user_id,last_generation) VALUES(?,?) ON CONFLICT(user_id) DO UPDATE SET last_generation=excluded.last_generation")
        .bind(user_id)
        .bind(generation)
        .execute(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn validate_membership_chain(
    conn: &mut SqliteConnection,
    vault_id: &str,
    expected_version: i64,
    active_user_id: &str,
) -> Result<BTreeMap<i64, i64>, ApiError> {
    let rows = sqlx::query("SELECT membership_version,previous_digest,manifest_json,digest,signer_device_id,signature FROM membership_manifests WHERE vault_id=? ORDER BY membership_version")
        .bind(vault_id)
        .fetch_all(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    if rows.len() != expected_version as usize || expected_version < 1 {
        return Err(ApiError::internal("membership history is incomplete"));
    }
    let mut previous: Option<String> = None;
    let mut active_version = 0;
    let mut active_key_versions = BTreeMap::<i64, i64>::new();
    for (index, row) in rows.iter().enumerate() {
        let version: i64 = row
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        if version != index as i64 + 1 {
            return Err(ApiError::internal("membership history version is invalid"));
        }
        let previous_digest: Option<String> =
            row.try_get("previous_digest").map_err(ApiError::internal)?;
        if previous_digest != previous {
            return Err(ApiError::internal(
                "membership history digest chain is invalid",
            ));
        }
        let stored: String = row.try_get("manifest_json").map_err(ApiError::internal)?;
        let record: Value = serde_json::from_str(&stored).map_err(ApiError::internal)?;
        let manifest = record
            .get("manifest")
            .cloned()
            .ok_or_else(|| ApiError::internal("membership history manifest is missing"))?;
        let sig: String = row.try_get("signature").map_err(ApiError::internal)?;
        let record_sig = record
            .get("signature")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::internal("membership history signature is missing"))?;
        if sig != record_sig
            || record.get("vault_id").and_then(Value::as_str) != Some(vault_id)
            || crate::auth::as_counter(record.get("membership_version").unwrap_or(&Value::Null))
                != Some(version)
        {
            return Err(ApiError::internal(
                "membership history record is inconsistent",
            ));
        }
        let record_previous = match record.get("previous_digest") {
            Some(Value::Null) | None => None,
            Some(Value::String(value)) => Some(value.clone()),
            _ => {
                return Err(ApiError::internal(
                    "membership history previous digest is invalid",
                ));
            }
        };
        if record_previous != previous_digest {
            return Err(ApiError::internal(
                "membership history previous digest is inconsistent",
            ));
        }
        let payload = json!({
            "vault_id": vault_id,
            "membership_version": version,
            "previous_digest": previous_digest,
            "manifest": manifest,
        });
        let payload_bytes = crate::jcs(&payload)?;
        let digest = crate::sha256_hex(&payload_bytes);
        let stored_digest: String = row.try_get("digest").map_err(ApiError::internal)?;
        if stored_digest != digest {
            return Err(ApiError::internal("membership history digest is invalid"));
        }
        let signer_id: String = row
            .try_get("signer_device_id")
            .map_err(ApiError::internal)?;
        let signer_key: Option<String> = sqlx::query_scalar(
            "SELECT signing_public_key FROM devices WHERE device_id=? UNION ALL SELECT signing_public_key FROM vault_device_archives WHERE vault_id=? AND device_id=? LIMIT 1",
        )
        .bind(&signer_id)
        .bind(vault_id)
        .bind(&signer_id)
        .fetch_optional(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
        let signer_key =
            signer_key.ok_or_else(|| ApiError::internal("membership signer key is unavailable"))?;
        crate::auth::verify_key_signature(&signer_key, &sig, &payload_bytes)
            .map_err(|_| ApiError::internal("membership history signature is invalid"))?;
        let members = manifest
            .get("members")
            .and_then(Value::as_array)
            .ok_or_else(|| ApiError::internal("membership history member list is invalid"))?;
        let user_is_active = members.iter().any(|member| {
            member.get("user_id").and_then(Value::as_str) == Some(active_user_id)
                && member.get("state").and_then(Value::as_str) == Some("active")
        });
        if user_is_active {
            active_version = version;
            if let Some(epoch) = manifest
                .get("key_epoch")
                .and_then(crate::auth::as_counter)
                .filter(|epoch| *epoch > 0)
            {
                active_key_versions.insert(epoch, version);
            }
        }
        previous = Some(digest);
    }
    if active_version != expected_version {
        return Err(ApiError::internal(
            "active vault member is absent from signed history",
        ));
    }
    Ok(active_key_versions)
}

async fn required_contexts(
    conn: &mut SqliteConnection,
    user_id: &str,
) -> Result<Vec<Context>, ApiError> {
    let vault_rows = sqlx::query("SELECT v.vault_id,v.active_epoch,v.membership_version FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND v.state IN ('active','deleting') ORDER BY v.vault_id")
        .bind(user_id)
        .fetch_all(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    let mut contexts = BTreeMap::<(String, i64), i64>::new();
    let mut membership_by_vault = BTreeMap::<String, BTreeMap<i64, i64>>::new();
    let mut active_epochs = BTreeMap::<String, i64>::new();
    for row in &vault_rows {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let active_epoch: i64 = row.try_get("active_epoch").map_err(ApiError::internal)?;
        let current_version: i64 = row
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let versions = validate_membership_chain(conn, &vault_id, current_version, user_id).await?;
        if versions.get(&active_epoch) != Some(&current_version) {
            return Err(ApiError::internal(
                "active Vault epoch lacks a current signed membership manifest",
            ));
        }
        active_epochs.insert(vault_id.clone(), active_epoch);
        membership_by_vault.insert(vault_id, versions);
    }
    let epochs = sqlx::query("SELECT DISTINCT e.vault_id,e.epoch FROM vault_key_envelopes e JOIN vaults v ON v.vault_id=e.vault_id JOIN vault_members vm ON vm.vault_id=e.vault_id AND vm.user_id=e.recipient_user_id WHERE e.recipient_user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND v.state IN ('active','deleting') ORDER BY e.vault_id,e.epoch")
        .bind(user_id)
        .fetch_all(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    for row in epochs {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let epoch: i64 = row.try_get("epoch").map_err(ApiError::internal)?;
        if epoch <= 0 {
            return Err(ApiError::internal("stored vault key epoch is invalid"));
        }
        let membership_version = *membership_by_vault
            .get(&vault_id)
            .and_then(|versions| versions.get(&epoch))
            .ok_or_else(|| {
                ApiError::internal(
                    "historical Vault epoch has no validated active membership manifest",
                )
            })?;
        contexts
            .entry((vault_id, epoch))
            .or_insert(membership_version);
    }
    for (vault_id, epoch) in active_epochs {
        let membership_version = *membership_by_vault
            .get(&vault_id)
            .and_then(|versions| versions.get(&epoch))
            .ok_or_else(|| {
                ApiError::internal("active Vault epoch has no validated membership version")
            })?;
        contexts
            .entry((vault_id, epoch))
            .or_insert(membership_version);
    }
    if contexts.len() > MAX_KEY_ENVELOPES {
        return Err(ApiError::conflict(
            "RECOVERY_CONTEXT_LIMIT",
            "account has too many Vault key contexts for recovery",
        ));
    }
    Ok(contexts
        .into_iter()
        .map(|((vault_id, key_epoch), membership_version)| Context {
            vault_id,
            key_epoch,
            membership_version,
        })
        .collect())
}

pub(crate) fn context_pairs(contexts: &[Context]) -> BTreeSet<(String, i64)> {
    contexts
        .iter()
        .map(|context| (context.vault_id.clone(), context.key_epoch))
        .collect()
}

async fn present_contexts(
    conn: &mut SqliteConnection,
    user_id: &str,
    generation: i64,
) -> Result<Vec<PresentContext>, ApiError> {
    let rows = sqlx::query("SELECT vault_id,key_epoch,envelope,recovery_signature,uploader_device_id FROM account_recovery_key_envelopes WHERE user_id=? AND recovery_generation=? ORDER BY vault_id,key_epoch")
        .bind(user_id)
        .bind(generation)
        .fetch_all(&mut *conn)
        .await
        .map_err(ApiError::internal)?;
    let mut result = Vec::with_capacity(rows.len());
    for row in rows {
        let envelope: Value = serde_json::from_str(
            &row.try_get::<String, _>("envelope")
                .map_err(ApiError::internal)?,
        )
        .map_err(ApiError::internal)?;
        let envelope_sha256 =
            crate::sha256_hex(&recovery_box_bytes(&envelope).map_err(ApiError::internal)?);
        result.push(PresentContext {
            vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
            key_epoch: row.try_get("key_epoch").map_err(ApiError::internal)?,
            envelope,
            envelope_sha256,
            recovery_signature: row
                .try_get("recovery_signature")
                .map_err(ApiError::internal)?,
            uploader_device_id: row
                .try_get("uploader_device_id")
                .map_err(ApiError::internal)?,
        });
    }
    Ok(result)
}

pub(crate) fn status(
    required: &[Context],
    present: &[PresentContext],
    enabled: bool,
) -> &'static str {
    if !enabled {
        return "disabled";
    }
    let required = context_pairs(required);
    let present: BTreeSet<(String, i64)> = present
        .iter()
        .map(|context| (context.vault_id.clone(), context.key_epoch))
        .collect();
    if required.is_subset(&present) {
        "current"
    } else {
        "stale"
    }
}

async fn recovery_status_for_user(
    state: &AppState,
    user_id: &str,
) -> Result<&'static str, ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let Some(recovery) = account_recovery(&mut *tx, user_id).await? else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok("disabled");
    };
    let required = required_contexts(&mut *tx, user_id).await?;
    let present = present_contexts(&mut *tx, user_id, recovery.generation).await?;
    let result = status(&required, &present, true);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(result)
}

pub(crate) async fn profile_status(
    state: &AppState,
    user_id: &str,
) -> Result<&'static str, ApiError> {
    recovery_status_for_user(state, user_id).await
}

pub(crate) fn json_from_db(value: &str, label: &str) -> Value {
    serde_json::from_str(value).unwrap_or_else(
        |_| json!({"version":1,"nonce":"","ciphertext":"" ,"invalid_server_value":label}),
    )
}

pub async fn contexts(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(repository.contexts(&state, &user).await?));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let recovery = account_recovery(&mut *tx, &user.user_id).await?;
    let last_generation = last_recovery_generation(&mut *tx, &user.user_id).await?;
    let required = required_contexts(&mut *tx, &user.user_id).await?;
    let (
        generation,
        identity_envelope,
        public_signing_key,
        public_encryption_key,
        descriptor_hash_value,
        present,
        recovery_status,
    ) = if let Some(descriptor) = recovery {
        if descriptor.generation != last_generation {
            return Err(ApiError::internal(
                "Recovery descriptor and generation counter are inconsistent",
            ));
        }
        let present = present_contexts(&mut *tx, &user.user_id, descriptor.generation).await?;
        let recovery_status = status(&required, &present, true);
        let descriptor_hash = descriptor_hash_current(&state, &user.user_id, &descriptor)?;
        (
            descriptor.generation,
            Some(json_from_db(
                &descriptor.identity_envelope,
                "identity envelope",
            )),
            Some(descriptor.public_signing_key),
            Some(descriptor.public_encryption_key),
            Some(descriptor_hash),
            present,
            recovery_status,
        )
    } else {
        (
            last_generation,
            None,
            None,
            None,
            None,
            Vec::new(),
            "disabled",
        )
    };
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "recovery_generation": generation,
        "recovery_identity_envelope": identity_envelope,
        "recovery_public_signing_key": public_signing_key,
        "recovery_public_encryption_key": public_encryption_key,
        "recovery_descriptor_hash": descriptor_hash_value,
        "required_contexts": required,
        "present_contexts": present,
        "recovery_status": recovery_status,
        "key_envelopes": present,
    })))
}

pub(crate) fn setup_device_payload(request: &ConfigureRequest) -> Result<Vec<u8>, ApiError> {
    let mut value = serde_json::to_value(request).map_err(ApiError::internal)?;
    let object = value
        .as_object_mut()
        .ok_or_else(|| ApiError::internal("setup request serialization failed"))?;
    object.remove("proof_signature");
    crate::jcs(&value)
}

pub(crate) fn rotation_old_payload(
    state: &AppState,
    user_id: &str,
    old: &RecoveryDescriptor,
    request: &ConfigureRequest,
) -> Result<Vec<u8>, ApiError> {
    crate::jcs(&json!({
        "protocol":"atermius-account-recovery-rotate-v1",
        "account_id":user_id,
        "instance_id":state.instance.instance_id,
        "server_space_id":state.instance.server_space_id,
        "old_recovery_generation":old.generation,
        "new_recovery_generation":request.recovery_generation,
        "old_recovery_descriptor_hash":descriptor_hash_current(state,user_id,old)?,
        "new_recovery_descriptor_hash":descriptor_hash(state,user_id,request.recovery_generation,&request.recovery_public_signing_key,&request.recovery_public_encryption_key)?,
    }))
}

pub(crate) fn recovery_identity_proof_payload(
    state: &AppState,
    account_id: &str,
    generation: i64,
    signing_key: &str,
    encryption_key: &str,
    recovery_envelope: &Value,
    identity_envelope: &Value,
) -> Result<Vec<u8>, ApiError> {
    crate::jcs(&json!({
        "protocol":"atermius-account-recovery-identity-v1",
        "account_id":account_id,
        "instance_id":state.instance.instance_id,
        "server_space_id":state.instance.server_space_id,
        "recovery_generation":generation,
        "recovery_descriptor_hash":descriptor_hash(state,account_id,generation,signing_key,encryption_key)?,
        "recovery_envelope_sha256":crate::sha256_hex(&crate::jcs(recovery_envelope)?),
        "recovery_identity_envelope_sha256":crate::sha256_hex(&crate::jcs(identity_envelope)?),
    }))
}

async fn verify_current_verifier(
    state: &AppState,
    user_id: &str,
    verifier: &str,
) -> Result<String, ApiError> {
    crate::auth::verify_login_verifier_for_user(state, user_id, verifier).await
}

async fn context_holding_device(
    tx: &mut Transaction<'_, sqlx::Sqlite>,
    user: &AuthUser,
    vault_id: &str,
    epoch: i64,
) -> Result<bool, ApiError> {
    let exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM vault_key_envelopes WHERE recipient_user_id=? AND recipient_device_id=? AND vault_id=? AND epoch=?")
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(vault_id)
        .bind(epoch)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(exists.is_some())
}

pub(crate) fn configure_response(
    generation: i64,
    recovery_status: &str,
    op_id: &str,
    already: bool,
) -> Value {
    json!({"status":"configured","operation_id":op_id,"recovery_generation":generation,"recovery_status":recovery_status,"already_applied":already})
}

pub async fn configure(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<ConfigureRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(
            repository.configure(&state, &user, peer, request).await?,
        ));
    }
    validate_operation_id(&request.operation_id)?;
    take_authenticated_reauth_limit(&state, &user.user_id, peer).await?;
    if request.key_envelopes.len() > MAX_KEY_ENVELOPES {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "too many Recovery key envelopes",
        ));
    }
    let digest = request_digest(&state, &user.user_id, &request.operation_id, &request)?;
    let mut retry_tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut retry_tx, &user).await?;
    if let Some(response) =
        receipt(&mut retry_tx, &user.user_id, &request.operation_id, &digest).await?
    {
        retry_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(response)));
    }
    retry_tx.commit().await.map_err(ApiError::internal)?;

    let verifier_snapshot =
        verify_current_verifier(&state, &user.user_id, &request.current_login_verifier).await?;
    if request.recovery_generation <= 0 {
        return Err(ApiError::bad_request(
            "INVALID_RECOVERY_GENERATION",
            "recovery_generation must be positive",
        ));
    }
    validate_public_keys(
        &request.recovery_public_signing_key,
        &request.recovery_public_encryption_key,
    )?;
    let recovery_envelope =
        validate_opaque_envelope(&request.recovery_envelope, "recovery envelope")?;
    let identity_envelope = validate_opaque_envelope(
        &request.recovery_identity_envelope,
        "recovery identity envelope",
    )?;
    crate::auth::verify_key_signature(
        &request.recovery_public_signing_key,
        &request.recovery_identity_proof_signature,
        &recovery_identity_proof_payload(
            &state,
            &user.user_id,
            request.recovery_generation,
            &request.recovery_public_signing_key,
            &request.recovery_public_encryption_key,
            &request.recovery_envelope,
            &request.recovery_identity_envelope,
        )?,
    )?;
    let submitted = verify_recovery_boxes(
        &state,
        &user.user_id,
        request.recovery_generation,
        &request.recovery_public_signing_key,
        &request.recovery_public_encryption_key,
        &user.device_id,
        &request.key_envelopes,
    )?;
    let signer: Option<String> = sqlx::query_scalar("SELECT signing_public_key FROM devices WHERE user_id=? AND device_id=? AND status='active'")
        .bind(&user.user_id)
        .bind(&user.device_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let signer = signer.ok_or_else(ApiError::unauthorized)?;
    crate::auth::verify_key_signature(
        &signer,
        &request.proof_signature,
        &setup_device_payload(&request)?,
    )?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    if let Some(response) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await? {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(response)));
    }
    let current_verifier: Option<String> =
        sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=?")
            .bind(&user.user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current_verifier.as_deref() != Some(&verifier_snapshot) {
        return Err(ApiError::reauth_required());
    }
    let existing = account_recovery(&mut *tx, &user.user_id).await?;
    let last_generation = last_recovery_generation(&mut *tx, &user.user_id).await?;
    if existing
        .as_ref()
        .is_some_and(|descriptor| descriptor.generation != last_generation)
    {
        return Err(ApiError::internal(
            "Recovery descriptor and generation counter are inconsistent",
        ));
    }
    let expected_generation = next_recovery_generation(last_generation).unwrap_or(i64::MAX);
    if request.recovery_generation != expected_generation {
        return Err(ApiError::conflict(
            "RECOVERY_GENERATION_CONFLICT",
            "Recovery generation changed; reload recovery state",
        ));
    }
    if let Some(old) = &existing {
        let signature = request
            .previous_recovery_signature
            .as_deref()
            .ok_or_else(|| {
                ApiError::forbidden(
                    "RECOVERY_ROTATION_PROOF_REQUIRED",
                    "rotating recovery requires the existing Recovery identity",
                )
            })?;
        crate::auth::verify_key_signature(
            &old.public_signing_key,
            signature,
            &rotation_old_payload(&state, &user.user_id, old, &request)?,
        )?;
    } else if request.previous_recovery_signature.is_some() {
        return Err(ApiError::bad_request(
            "UNEXPECTED_RECOVERY_PROOF",
            "initial setup cannot include an old Recovery proof",
        ));
    }
    // Account/vault state is serialized with membership changes and deletion.
    sqlx::query("UPDATE vaults SET state=state WHERE vault_id IN (SELECT vault_id FROM vault_members WHERE user_id=? AND state='active')")
        .bind(&user.user_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    let required = required_contexts(&mut tx, &user.user_id).await?;
    let required_pairs = context_pairs(&required);
    let submitted_pairs: BTreeSet<(String, i64)> = submitted.keys().cloned().collect();
    if !submitted_pairs.is_subset(&required_pairs) {
        return Err(ApiError::invalid_envelope(
            "Recovery key envelopes contain a context outside the active Vault set",
        ));
    }
    let existing_present = if let Some(old) = &existing {
        present_contexts(&mut tx, &user.user_id, old.generation).await?
    } else {
        Vec::new()
    };
    let previous_pairs: BTreeSet<(String, i64)> = existing_present
        .iter()
        .map(|item| (item.vault_id.clone(), item.key_epoch))
        .collect();
    if !previous_pairs.is_subset(&submitted_pairs) {
        return Err(ApiError::conflict(
            "RECOVERY_ROTATION_INCOMPLETE",
            "rotation must preserve all previously saved Vault key contexts",
        ));
    }
    for pair in &submitted_pairs {
        let was_present = previous_pairs.contains(pair);
        if !was_present && !context_holding_device(&mut tx, &user, &pair.0, pair.1).await? {
            return Err(ApiError::invalid_envelope(
                "setup may only include Vault keys held by this device or preserved from the prior recovery set",
            ));
        }
    }
    let now = Utc::now().timestamp();
    sqlx::query("INSERT INTO account_recovery(user_id,recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET recovery_generation=excluded.recovery_generation,recovery_public_signing_key=excluded.recovery_public_signing_key,recovery_public_encryption_key=excluded.recovery_public_encryption_key,recovery_envelope=excluded.recovery_envelope,recovery_identity_envelope=excluded.recovery_identity_envelope,updated_at=excluded.updated_at")
        .bind(&user.user_id).bind(request.recovery_generation).bind(&request.recovery_public_signing_key).bind(&request.recovery_public_encryption_key).bind(recovery_envelope).bind(identity_envelope).bind(now).bind(now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    for entry in &request.key_envelopes {
        sqlx::query("INSERT INTO account_recovery_key_envelopes(user_id,recovery_generation,vault_id,key_epoch,envelope,recovery_signature,uploader_device_id,created_at) VALUES(?,?,?,?,?,?,?,?)")
            .bind(&user.user_id).bind(request.recovery_generation).bind(&entry.vault_id).bind(entry.key_epoch).bind(entry.envelope.to_string()).bind(&entry.recovery_signature).bind(&entry.uploader_device_id).bind(now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    }
    save_recovery_generation(&mut tx, &user.user_id, request.recovery_generation).await?;
    let saved = present_contexts(&mut tx, &user.user_id, request.recovery_generation).await?;
    let recovery_status = status(&required, &saved, true);
    let response = configure_response(
        request.recovery_generation,
        recovery_status,
        &request.operation_id,
        false,
    );
    save_receipt(
        &mut tx,
        &user.user_id,
        &request.operation_id,
        &digest,
        &response,
    )
    .await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        if existing.is_some() {
            "auth.account_recovery_rotated"
        } else {
            "auth.account_recovery_enabled"
        },
        "account_recovery",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn disable(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<DisableRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(
            repository.disable(&state, &user, peer, request).await?,
        ));
    }
    validate_operation_id(&request.operation_id)?;
    take_authenticated_reauth_limit(&state, &user.user_id, peer).await?;
    let digest = request_digest(&state, &user.user_id, &request.operation_id, &request)?;
    let mut retry_tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut retry_tx, &user).await?;
    if let Some(response) =
        receipt(&mut retry_tx, &user.user_id, &request.operation_id, &digest).await?
    {
        retry_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(response)));
    }
    retry_tx.commit().await.map_err(ApiError::internal)?;
    let verifier_snapshot =
        verify_current_verifier(&state, &user.user_id, &request.current_login_verifier).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    if let Some(response) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await? {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(response)));
    }
    let current: Option<String> =
        sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=?")
            .bind(&user.user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current.as_deref() != Some(&verifier_snapshot) {
        return Err(ApiError::reauth_required());
    }
    sqlx::query("DELETE FROM account_recovery WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM account_recovery_challenges WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let response =
        json!({"status":"disabled","operation_id":request.operation_id,"already_applied":false});
    save_receipt(
        &mut tx,
        &user.user_id,
        &request.operation_id,
        &digest,
        &response,
    )
    .await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.account_recovery_disabled",
        "account_recovery",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn upload_key_envelopes(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<UploadRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(
            repository
                .upload_key_envelopes(&state, &user, request)
                .await?,
        ));
    }
    validate_operation_id(&request.operation_id)?;
    if request.recovery_generation <= 0 || request.key_envelopes.len() > MAX_KEY_ENVELOPES {
        return Err(ApiError::bad_request(
            "INVALID_KEY_ENVELOPES",
            "Recovery key envelope request is invalid",
        ));
    }
    let digest = request_digest(&state, &user.user_id, &request.operation_id, &request)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    if let Some(response) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await? {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(response)));
    }
    let descriptor = account_recovery(&mut tx, &user.user_id)
        .await?
        .ok_or_else(|| {
            ApiError::conflict(
                "RECOVERY_DISABLED",
                "online account recovery is not configured",
            )
        })?;
    if descriptor.generation != request.recovery_generation {
        return Err(stale_recovery());
    }
    let expected_descriptor_hash = descriptor_hash_current(&state, &user.user_id, &descriptor)?;
    if request.recovery_descriptor_hash != expected_descriptor_hash {
        return Err(stale_recovery());
    }
    let boxes = verify_recovery_boxes(
        &state,
        &user.user_id,
        descriptor.generation,
        &descriptor.public_signing_key,
        &descriptor.public_encryption_key,
        &user.device_id,
        &request.key_envelopes,
    )?;
    let required = required_contexts(&mut tx, &user.user_id).await?;
    let required_pairs = context_pairs(&required);
    for (vault_id, epoch) in boxes.keys() {
        if !required_pairs.contains(&(vault_id.clone(), *epoch)) {
            return Err(stale_recovery());
        }
        if !context_holding_device(&mut tx, &user, vault_id, *epoch).await? {
            return Err(ApiError::forbidden(
                "VAULT_KEY_UNAVAILABLE",
                "the current device does not hold this Vault key context",
            ));
        }
    }
    let now = Utc::now().timestamp();
    let mut inserted = 0usize;
    for entry in &request.key_envelopes {
        let existing: Option<(String, String, String)> = sqlx::query_as("SELECT envelope,recovery_signature,uploader_device_id FROM account_recovery_key_envelopes WHERE user_id=? AND recovery_generation=? AND vault_id=? AND key_epoch=?")
            .bind(&user.user_id).bind(descriptor.generation).bind(&entry.vault_id).bind(entry.key_epoch).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
        if let Some((saved_envelope, saved_signature, saved_uploader)) = existing {
            if saved_envelope != entry.envelope.to_string()
                || saved_signature != entry.recovery_signature
                || saved_uploader != entry.uploader_device_id
            {
                return Err(ApiError::conflict(
                    "RECOVERY_KEYBOX_CONFLICT",
                    "a different recovery box already exists for this Vault epoch",
                ));
            }
            continue;
        }
        let result = sqlx::query("INSERT INTO account_recovery_key_envelopes(user_id,recovery_generation,vault_id,key_epoch,envelope,recovery_signature,uploader_device_id,created_at) VALUES(?,?,?,?,?,?,?,?)")
            .bind(&user.user_id).bind(descriptor.generation).bind(&entry.vault_id).bind(entry.key_epoch).bind(entry.envelope.to_string()).bind(&entry.recovery_signature).bind(&entry.uploader_device_id).bind(now).execute(&mut *tx).await.map_err(ApiError::internal)?;
        inserted += result.rows_affected() as usize;
    }
    let present = present_contexts(&mut tx, &user.user_id, descriptor.generation).await?;
    let recovery_status = status(&required, &present, true);
    let response = json!({"status":"updated","operation_id":request.operation_id,"recovery_generation":descriptor.generation,"recovery_status":recovery_status,"inserted_count":inserted,"already_applied":false});
    save_receipt(
        &mut tx,
        &user.user_id,
        &request.operation_id,
        &digest,
        &response,
    )
    .await?;
    if inserted > 0 {
        crate::audit::record_account_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            Some(&user.device_id),
            "auth.account_recovery_key_envelopes_updated",
            "account_recovery",
            Some(&user.user_id),
            crate::audit::AuditSource::Api,
            now,
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

#[derive(Debug, Serialize)]
pub(crate) struct StartResponse {
    pub(crate) account_id: String,
    pub(crate) instance_id: String,
    pub(crate) server_space_id: String,
    pub(crate) recovery_generation: i64,
    pub(crate) challenge_id: String,
    pub(crate) challenge: String,
    pub(crate) expires_at: String,
    pub(crate) recovery_public_signing_key: String,
    pub(crate) recovery_public_encryption_key: String,
    pub(crate) recovery_descriptor_hash: String,
    pub(crate) recovery_envelope: Value,
}

pub(crate) fn decoy_material(
    state: &AppState,
    username: &str,
    purpose: &[u8],
    length: usize,
) -> Result<Vec<u8>, ApiError> {
    let mut output = Vec::with_capacity(length);
    let mut counter = 0_u32;
    while output.len() < length {
        let mut mac =
            HmacSha256::new_from_slice(state.auth_rate_key.as_ref()).map_err(ApiError::internal)?;
        mac.update(b"atermius/account-recovery-decoy/v1\0");
        mac.update(purpose);
        mac.update(b"\0");
        mac.update(username.as_bytes());
        mac.update(&counter.to_be_bytes());
        output.extend_from_slice(&mac.finalize().into_bytes());
        counter = counter
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("decoy material counter overflow"))?;
    }
    output.truncate(length);
    Ok(output)
}

pub(crate) fn decoy_id(state: &AppState, username: &str) -> Result<String, ApiError> {
    let mut bytes: [u8; 16] = decoy_material(state, username, b"account-id", 16)?
        .try_into()
        .map_err(|_| ApiError::internal("invalid decoy account ID length"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(Uuid::from_bytes(bytes).to_string())
}

pub(crate) fn decoy_recovery_envelope(state: &AppState, username: &str) -> Result<Value, ApiError> {
    let nonce = decoy_material(state, username, b"base-nonce", 24)?;
    let ciphertext = decoy_material(state, username, b"base-ciphertext", 528)?;
    Ok(
        json!({"version":1,"suite":"xchacha20-poly1305-ietf","nonce":URL_SAFE_NO_PAD.encode(nonce),"ciphertext":URL_SAFE_NO_PAD.encode(ciphertext)}),
    )
}

#[derive(Clone)]
pub(crate) struct DecoyStartMaterial {
    pub(crate) account_id: String,
    pub(crate) recovery_public_signing_key: String,
    pub(crate) recovery_public_encryption_key: String,
    pub(crate) recovery_descriptor_hash: String,
    pub(crate) recovery_envelope: Value,
}

pub(crate) fn decoy_start_material(
    state: &AppState,
    username: &str,
) -> Result<DecoyStartMaterial, ApiError> {
    let account_id = decoy_id(state, username)?;
    let signing_seed: [u8; 32] = decoy_material(state, username, b"signing-seed", 32)?
        .try_into()
        .map_err(|_| ApiError::internal("invalid decoy signing seed length"))?;
    let recovery_public_signing_key = URL_SAFE_NO_PAD.encode(
        ed25519_dalek::SigningKey::from_bytes(&signing_seed)
            .verifying_key()
            .to_bytes(),
    );
    let recovery_public_encryption_key =
        URL_SAFE_NO_PAD.encode(decoy_material(state, username, b"encryption-key", 32)?);
    let recovery_descriptor_hash = descriptor_hash(
        state,
        &account_id,
        1,
        &recovery_public_signing_key,
        &recovery_public_encryption_key,
    )?;
    let recovery_envelope = decoy_recovery_envelope(state, username)?;
    Ok(DecoyStartMaterial {
        account_id,
        recovery_public_signing_key,
        recovery_public_encryption_key,
        recovery_descriptor_hash,
        recovery_envelope,
    })
}

pub(crate) fn decode_or_dummy(value: String, dummy: &Value) -> Result<Value, ApiError> {
    let parsed = serde_json::from_str::<Value>(&value).ok();
    let valid = parsed.as_ref().is_some_and(|envelope| {
        envelope.as_object().is_some_and(|object| object.len() == 4)
            && envelope.get("version").and_then(Value::as_i64) == Some(1)
            && envelope.get("suite").and_then(Value::as_str) == Some("xchacha20-poly1305-ietf")
            && envelope
                .get("nonce")
                .and_then(Value::as_str)
                .and_then(|nonce| URL_SAFE_NO_PAD.decode(nonce).ok())
                .is_some_and(|nonce| nonce.len() == 24)
            && envelope
                .get("ciphertext")
                .and_then(Value::as_str)
                .and_then(|ciphertext| URL_SAFE_NO_PAD.decode(ciphertext).ok())
                .is_some_and(|ciphertext| ciphertext.len() == 528)
    });
    if valid {
        parsed.ok_or_else(|| ApiError::internal("recovery envelope parse failed"))
    } else {
        Ok(dummy.clone())
    }
}

pub async fn start(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<StartRequest>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(repository.start(&state, peer, request).await?));
    }
    let username = crate::auth::normalized_username(&request.username)?;
    take_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::RecoveryStart,
        &username,
        peer,
    )
    .await?;
    let row = sqlx::query("SELECT u.user_id,r.recovery_generation,r.recovery_public_signing_key,r.recovery_public_encryption_key,r.recovery_envelope FROM users u JOIN account_recovery r ON r.user_id=u.user_id WHERE u.username=? AND u.status='active'")
        .bind(&username).fetch_optional(&state.db).await.map_err(ApiError::internal)?;
    let challenge_id = Uuid::new_v4().to_string();
    let mut challenge_bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut challenge_bytes);
    let challenge = URL_SAFE_NO_PAD.encode(challenge_bytes);
    let challenge_id_hash = crate::sha256_hex(challenge_id.as_bytes());
    let challenge_hash = crate::sha256_hex(&challenge_bytes);
    // Derive the same bounded fallback public material for every request. The
    // configured-account path discards it; the decoy path returns it. This
    // keeps the decoy's keyed expansion and Ed25519 public-key derivation from
    // being exclusive to unknown or inactive usernames, without adding a
    // timing delay or persisting account-identifying data. It balances this
    // fallback work only; database and configured-envelope work still differ.
    let decoy = decoy_start_material(&state, &username)?;
    let (bound_user_id, generation, mut response) = if let Some(row) = row {
        let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let generation: i64 = row
            .try_get("recovery_generation")
            .map_err(ApiError::internal)?;
        let recovery_public_signing_key: String = row
            .try_get("recovery_public_signing_key")
            .map_err(ApiError::internal)?;
        let recovery_public_encryption_key: String = row
            .try_get("recovery_public_encryption_key")
            .map_err(ApiError::internal)?;
        let recovery_envelope: String = row
            .try_get("recovery_envelope")
            .map_err(ApiError::internal)?;
        let recovery_descriptor_hash = descriptor_hash(
            &state,
            &user_id,
            generation,
            &recovery_public_signing_key,
            &recovery_public_encryption_key,
        )?;
        let response = StartResponse {
            account_id: user_id.clone(),
            instance_id: state.instance.instance_id.clone(),
            server_space_id: state.instance.server_space_id.clone(),
            recovery_generation: generation,
            challenge_id,
            challenge,
            expires_at: String::new(),
            recovery_public_signing_key,
            recovery_public_encryption_key,
            recovery_descriptor_hash,
            recovery_envelope: decode_or_dummy(recovery_envelope, &decoy.recovery_envelope)?,
        };
        (Some(user_id), generation, response)
    } else {
        let response = StartResponse {
            account_id: decoy.account_id,
            instance_id: state.instance.instance_id.clone(),
            server_space_id: state.instance.server_space_id.clone(),
            recovery_generation: 1,
            challenge_id,
            challenge,
            expires_at: String::new(),
            recovery_public_signing_key: decoy.recovery_public_signing_key,
            recovery_public_encryption_key: decoy.recovery_public_encryption_key,
            recovery_descriptor_hash: decoy.recovery_descriptor_hash,
            recovery_envelope: decoy.recovery_envelope,
        };
        (None, 1, response)
    };
    // Persist the same opaque challenge record for configured and decoy
    // responses. Decoy rows deliberately have no user binding, so neither
    // inspect nor complete can validate them against an account.
    // Reserve SQLite's single writer before pruning and counting. Every start
    // therefore observes the previous insert before deciding whether a slot is
    // available. The same captured second drives cleanup, liveness, and the
    // challenge's expiry.
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let now = Utc::now().timestamp();
    prune_challenges_in_transaction(&mut tx, now).await?;
    let (live_count, next_expiry): (i64, Option<i64>) = sqlx::query_as(
        "SELECT COUNT(*),MIN(expires_at) FROM account_recovery_challenges \
         WHERE expires_at>? AND consumed_at IS NULL",
    )
    .bind(now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if live_count >= state.config.auth_rate_limits.max_active_recovery_challenges {
        let retry_after = next_expiry
            .unwrap_or_else(|| now.saturating_add(COMPLETE_TTL_SECONDS))
            .saturating_sub(now)
            .max(1) as u64;
        // Commit bounded cleanup even when full; no challenge is inserted.
        // The separate authentication-rate-limit transaction has already
        // committed and intentionally remains charged for this attempt.
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::rate_limited(retry_after));
    }
    let expires = now.saturating_add(COMPLETE_TTL_SECONDS);
    response.expires_at = chrono::DateTime::from_timestamp(expires, 0)
        .ok_or_else(|| ApiError::internal("challenge expiry is invalid"))?
        .to_rfc3339();
    sqlx::query("INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES(?,?,?,?,?)")
        .bind(challenge_id_hash)
        .bind(challenge_hash)
        .bind(bound_user_id)
        .bind(generation)
        .bind(expires)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        serde_json::to_value(response).map_err(ApiError::internal)?,
    ))
}

fn challenge_input(request: &InspectRequest) -> Result<[u8; 32], ApiError> {
    let bytes = decode_b64(&request.challenge, Some(32))?;
    bytes.as_slice().try_into().map_err(ApiError::internal)
}

fn recovery_challenge_is_live(expires_at: i64, now: i64) -> bool {
    expires_at > now
}

async fn valid_challenge(
    tx: &mut Transaction<'_, sqlx::Sqlite>,
    user_id: &str,
    generation: i64,
    challenge_id: &str,
    challenge: &[u8],
) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(challenge_id) {
        return Err(failed_recovery());
    }
    let challenge_id_hash = crate::sha256_hex(challenge_id.as_bytes());
    let challenge_hash = crate::sha256_hex(challenge);
    let row = sqlx::query("SELECT challenge_hash,user_id,recovery_generation,expires_at,consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=?")
        .bind(challenge_id_hash).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Err(failed_recovery());
    };
    let stored_hash: String = row.try_get("challenge_hash").map_err(ApiError::internal)?;
    let stored_user: Option<String> = row.try_get("user_id").map_err(ApiError::internal)?;
    let stored_gen: i64 = row
        .try_get("recovery_generation")
        .map_err(ApiError::internal)?;
    let expires: i64 = row.try_get("expires_at").map_err(ApiError::internal)?;
    let consumed: Option<i64> = row.try_get("consumed_at").map_err(ApiError::internal)?;
    if stored_hash != challenge_hash
        || stored_user.as_deref() != Some(user_id)
        || stored_gen != generation
        || !recovery_challenge_is_live(expires, Utc::now().timestamp())
        || consumed.is_some()
    {
        return Err(failed_recovery());
    }
    Ok(())
}

pub async fn inspect(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<InspectRequest>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(repository.inspect(&state, peer, request).await?));
    }
    let challenge = challenge_input(&request).map_err(|_| failed_recovery())?;
    if !crate::is_canonical_uuid(&request.account_id)
        || !crate::is_canonical_uuid(&request.challenge_id)
        || request.instance_id != state.instance.instance_id
        || request.server_space_id != state.instance.server_space_id
    {
        return Err(failed_recovery());
    }
    let subject = recovery_anonymous_rate_subject(&state, &request.account_id).await?;
    take_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::RecoveryStart,
        &subject,
        peer,
    )
    .await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let descriptor = account_recovery(&mut tx, &request.account_id)
        .await
        .map_err(|_| failed_recovery())?
        .ok_or_else(failed_recovery)?;
    if descriptor.generation != request.recovery_generation {
        return Err(failed_recovery());
    }
    let descriptor_hash = descriptor_hash_current(&state, &request.account_id, &descriptor)?;
    let payload = json!({
        "protocol": INSPECT_PROTOCOL,
        "account_id": request.account_id,
        "instance_id": request.instance_id,
        "server_space_id": request.server_space_id,
        "recovery_generation": request.recovery_generation,
        "challenge_id": request.challenge_id,
        "challenge": request.challenge,
        "recovery_descriptor_hash": descriptor_hash,
    });
    crate::auth::verify_key_signature(
        &descriptor.public_signing_key,
        &request.recovery_signature,
        &crate::jcs(&payload)?,
    )
    .map_err(|_| failed_recovery())?;
    valid_challenge(
        &mut tx,
        &request.account_id,
        descriptor.generation,
        &request.challenge_id,
        &challenge,
    )
    .await?;
    let required = required_contexts(&mut tx, &request.account_id).await?;
    let present = present_contexts(&mut tx, &request.account_id, descriptor.generation).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account_id":request.account_id,
        "recovery_generation":descriptor.generation,
        "recovery_descriptor_hash":descriptor_hash,
        "required_contexts":required,
        "present_contexts":present,
        "recovery_status":status(&required,&present,true),
    })))
}

pub(crate) fn complete_payload(request: &CompleteRequest) -> Result<Vec<u8>, ApiError> {
    let mut value = serde_json::to_value(request).map_err(ApiError::internal)?;
    value
        .as_object_mut()
        .ok_or_else(|| ApiError::internal("completion request serialization failed"))?
        .remove("recovery_signature");
    crate::jcs(&json!({"protocol":"atermius-account-recovery-complete-v1","request":value}))
}

pub(crate) fn complete_response(
    request: &CompleteRequest,
    credential_version: i64,
    already: bool,
) -> Value {
    json!({"status":"recovered","operation_id":request.operation_id,"credential_version":credential_version,"recovery_generation":request.recovery_generation + 1,"device_id":request.device.device_id,"already_applied":already})
}

pub(crate) fn canonical_completion_contexts(required: &[Context]) -> BTreeMap<(String, i64), i64> {
    required
        .iter()
        .map(|context| {
            (
                (context.vault_id.clone(), context.key_epoch),
                context.membership_version,
            )
        })
        .collect()
}

pub(crate) fn verify_completion_device(
    device: &CompletionDevice,
    account_id: &str,
) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(&device.device_id)
        || device.name.trim().is_empty()
        || device.name.len() > 128
        || device.name.chars().any(char::is_control)
    {
        return Err(failed_recovery());
    }
    let signing =
        decode_b64(&device.signing_public_key, Some(32)).map_err(|_| failed_recovery())?;
    VerifyingKey::from_bytes(
        signing
            .as_slice()
            .try_into()
            .map_err(|_| failed_recovery())?,
    )
    .map_err(|_| failed_recovery())?;
    let encryption =
        decode_b64(&device.encryption_public_key, Some(32)).map_err(|_| failed_recovery())?;
    if encryption.iter().all(|byte| *byte == 0) {
        return Err(failed_recovery());
    }
    let payload = json!({"account_id":account_id,"device_id":device.device_id,"encryption_public_key":device.encryption_public_key,"signing_public_key":device.signing_public_key});
    crate::auth::verify_key_signature(
        &device.signing_public_key,
        &device.signature,
        &crate::jcs(&payload)?,
    )
    .map_err(|_| failed_recovery())
}

pub(crate) fn completion_vault_envelope_set(
    request: &CompleteRequest,
    required: &BTreeMap<(String, i64), i64>,
) -> Result<(), ApiError> {
    if request.vault_key_envelopes.len() > MAX_KEY_ENVELOPES
        || request.vault_key_envelopes.len() != required.len()
    {
        return Err(stale_recovery());
    }
    let mut seen = BTreeSet::new();
    for key in &request.vault_key_envelopes {
        if !crate::is_canonical_uuid(&key.vault_id)
            || key.key_epoch <= 0
            || key.membership_version <= 0
            || key.recipient_device_id != request.device.device_id
            || key.envelope.to_string().len() > MAX_ENVELOPE_BYTES
        {
            return Err(failed_recovery());
        }
        let pair = (key.vault_id.clone(), key.key_epoch);
        if !seen.insert(pair.clone()) || required.get(&pair) != Some(&key.membership_version) {
            return Err(stale_recovery());
        }
        let payload = json!({"vault_id":key.vault_id,"recipient_device_id":key.recipient_device_id,"key_epoch":key.key_epoch,"membership_version":key.membership_version,"envelope":key.envelope});
        crate::auth::verify_key_signature(
            &request.device.signing_public_key,
            &key.signature,
            &crate::jcs(&payload)?,
        )
        .map_err(|_| failed_recovery())?;
    }
    if seen.len() != required.len() {
        return Err(stale_recovery());
    }
    Ok(())
}

async fn ensure_readable_source_key_envelopes(
    conn: &mut SqliteConnection,
    user_id: &str,
    required: &BTreeMap<(String, i64), i64>,
) -> Result<(), ApiError> {
    // Active epochs remain required contexts even if their last source row was
    // removed, so check the readable ciphertext rows independently while the
    // completion transaction still holds its writer reservation.
    let rows = sqlx::query(
        "SELECT e.vault_id,e.epoch,e.envelope FROM vault_key_envelopes e \
         JOIN devices d ON d.device_id=e.recipient_device_id \
         WHERE e.recipient_user_id=? AND d.user_id=?",
    )
    .bind(user_id)
    .bind(user_id)
    .fetch_all(&mut *conn)
    .await
    .map_err(ApiError::internal)?;

    let mut readable = BTreeSet::new();
    for row in rows {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let epoch: i64 = row.try_get("epoch").map_err(ApiError::internal)?;
        let envelope: String = row.try_get("envelope").map_err(ApiError::internal)?;
        if serde_json::from_str::<Value>(&envelope).is_ok_and(|value| value.is_object()) {
            readable.insert((vault_id, epoch));
        }
    }

    if required.keys().any(|context| !readable.contains(context)) {
        return Err(stale_recovery());
    }
    Ok(())
}

pub async fn complete(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<CompleteRequest>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = crate::pg_account_recovery::from_state(&state) {
        return Ok(Json(repository.complete(state, peer, request).await?));
    }
    #[cfg(test)]
    {
        complete_inner(state, peer, request, None).await
    }
    #[cfg(not(test))]
    {
        complete_inner(state, peer, request).await
    }
}

async fn complete_inner(
    state: AppState,
    peer: SocketAddr,
    request: CompleteRequest,
    #[cfg(test)] test_hooks: Option<&RecoveryPurgeTestHooks>,
) -> Result<Json<Value>, ApiError> {
    // The request embeds the public account ID because there is no username
    // field in the signed request. The rate-limit subject remains a keyed hash.
    validate_operation_id(&request.operation_id).map_err(|_| failed_recovery())?;
    if !crate::is_canonical_uuid(&request.account_id) {
        return Err(failed_recovery());
    }
    let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(&request.account_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let rate_subject = username.unwrap_or_else(|| format!("unknown:{}", request.account_id));
    take_rate_limit(
        &state,
        crate::rate_limit::AuthOperation::RecoveryComplete,
        &rate_subject,
        peer,
    )
    .await?;
    let digest = request_digest(&state, &request.account_id, &request.operation_id, &request)?;

    // Look up the opaque receipt before checking challenge consumption or the
    // now-old recovery generation: a response-loss retry follows revocation.
    let mut receipt_tx = state.db.begin().await.map_err(ApiError::internal)?;
    if let Some(saved) = receipt(
        &mut receipt_tx,
        &request.account_id,
        &request.operation_id,
        &digest,
    )
    .await?
    {
        receipt_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(saved)));
    }
    receipt_tx.commit().await.map_err(ApiError::internal)?;

    let challenge = decode_b64(&request.challenge, Some(32)).map_err(|_| failed_recovery())?;
    if request.instance_id != state.instance.instance_id
        || request.server_space_id != state.instance.server_space_id
        || !crate::is_canonical_uuid(&request.challenge_id)
    {
        return Err(failed_recovery());
    }
    let mut verify_tx = state.db.begin().await.map_err(ApiError::internal)?;
    let recovery = account_recovery(&mut verify_tx, &request.account_id)
        .await
        .map_err(|_| failed_recovery())?
        .ok_or_else(failed_recovery)?;
    if recovery.generation != request.recovery_generation {
        return Err(failed_recovery());
    }
    crate::auth::verify_key_signature(
        &recovery.public_signing_key,
        &request.recovery_signature,
        &complete_payload(&request)?,
    )
    .map_err(|_| failed_recovery())?;
    valid_challenge(
        &mut verify_tx,
        &request.account_id,
        recovery.generation,
        &request.challenge_id,
        &challenge,
    )
    .await?;
    let contexts_snapshot = required_contexts(&mut verify_tx, &request.account_id).await?;
    let required = canonical_completion_contexts(&contexts_snapshot);
    completion_vault_envelope_set(&request, &required)?;
    // The verifier hash and complete crypto structure are prepared before the
    // writer transaction. All account and keyset snapshots are rechecked below.
    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&request.account_id)
            .fetch_optional(&mut *verify_tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(failed_recovery());
    }
    validate_completion_device(&request.device, &request.account_id)?;
    crate::auth::validate_kdf(&request.new_kdf).map_err(|_| failed_recovery())?;
    let (new_verifier_hash, new_verifier_salt) =
        crate::auth::password_hash(&request.new_login_verifier).map_err(|_| failed_recovery())?;
    let new_account_key_envelope =
        crate::auth::ensure_rewrapped_account_envelope(&request.account_key_envelope)
            .map_err(|_| failed_recovery())?;
    let new_generation = request
        .recovery_generation
        .checked_add(1)
        .ok_or_else(failed_recovery)?;
    validate_public_keys(
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
    )
    .map_err(|_| failed_recovery())?;
    let next_recovery_envelope = validate_opaque_envelope(
        &request.next_recovery.recovery_envelope,
        "next recovery envelope",
    )
    .map_err(|_| failed_recovery())?;
    let next_identity_envelope = validate_opaque_envelope(
        &request.next_recovery.recovery_identity_envelope,
        "next recovery identity envelope",
    )
    .map_err(|_| failed_recovery())?;
    let next_boxes = verify_recovery_boxes(
        &state,
        &request.account_id,
        new_generation,
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
        &request.device.device_id,
        &request.next_recovery.key_envelopes,
    )
    .map_err(|_| failed_recovery())?;
    let next_pairs: BTreeSet<(String, i64)> = next_boxes.keys().cloned().collect();
    if next_pairs != required.keys().cloned().collect() {
        return Err(stale_recovery());
    }
    let next_self_proof = recovery_identity_proof_payload(
        &state,
        &request.account_id,
        new_generation,
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
        &request.next_recovery.recovery_envelope,
        &request.next_recovery.recovery_identity_envelope,
    )
    .map_err(|_| failed_recovery())?;
    crate::auth::verify_key_signature(
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_identity_proof_signature,
        &next_self_proof,
    )
    .map_err(|_| failed_recovery())?;
    verify_tx.commit().await.map_err(ApiError::internal)?;

    #[cfg(test)]
    if let Some(gate) = test_hooks.and_then(|hooks| hooks.completion_after_preflight.as_ref()) {
        gate.pause().await;
    }

    let kdf_json = serde_json::to_string(&json!({"id":request.new_kdf.id,"salt":request.new_kdf.salt,"mem_kib":request.new_kdf.mem_kib,"iterations":request.new_kdf.iterations,"parallelism":request.new_kdf.parallelism,"version":request.new_kdf.version})).map_err(ApiError::internal)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    // This also serializes against all vault membership, key rotation, device
    // enrollment and deletion paths which take the same row writer lock.
    sqlx::query("UPDATE vaults SET state=state WHERE vault_id IN (SELECT vault_id FROM vault_members WHERE user_id=? AND state='active')").bind(&request.account_id).execute(&mut *tx).await.map_err(ApiError::internal)?;

    #[cfg(test)]
    if let Some(gate) = test_hooks.and_then(|hooks| hooks.completion_writer_reserved.as_ref()) {
        gate.pause().await;
    }

    if let Some(saved) =
        receipt(&mut tx, &request.account_id, &request.operation_id, &digest).await?
    {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(retry_response(saved)));
    }
    let current_recovery = account_recovery(&mut tx, &request.account_id)
        .await
        .map_err(|_| failed_recovery())?
        .ok_or_else(failed_recovery)?;
    if current_recovery.generation != request.recovery_generation {
        return Err(failed_recovery());
    }
    let current_last_generation = last_recovery_generation(&mut tx, &request.account_id)
        .await
        .map_err(|_| failed_recovery())?;
    if current_last_generation != request.recovery_generation {
        return Err(failed_recovery());
    }
    valid_challenge(
        &mut tx,
        &request.account_id,
        current_recovery.generation,
        &request.challenge_id,
        &challenge,
    )
    .await?;
    crate::auth::verify_key_signature(
        &current_recovery.public_signing_key,
        &request.recovery_signature,
        &complete_payload(&request)?,
    )
    .map_err(|_| failed_recovery())?;
    let locked_required = required_contexts(&mut tx, &request.account_id).await?;
    let locked_set = canonical_completion_contexts(&locked_required);
    if locked_set != required {
        return Err(stale_recovery());
    }
    ensure_readable_source_key_envelopes(&mut tx, &request.account_id, &locked_set).await?;
    let active: Option<(String, i64)> = sqlx::query_as("SELECT u.status,c.credential_version FROM users u JOIN auth_credentials c ON c.user_id=u.user_id WHERE u.user_id=?")
        .bind(&request.account_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some((account_status, credential_version)) = active else {
        return Err(failed_recovery());
    };
    if account_status != "active" {
        return Err(failed_recovery());
    }
    let new_credential_version = credential_version
        .checked_add(1)
        .ok_or_else(|| ApiError::internal("credential version overflow"))?;
    let now_text = crate::now_rfc3339();
    // Recovery atomically replaces the trusted-device set. Revoke the old
    // active devices before checking the ordinary enrollment ceiling so an
    // account already at its limit can still recover. Any later failure rolls
    // this revocation back with the surrounding transaction.
    sqlx::query(
        "UPDATE devices SET status='revoked',revoked_at=? WHERE user_id=? AND status='active'",
    )
    .bind(&now_text)
    .bind(&request.account_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    crate::auth::ensure_active_device_capacity_tx(&mut tx, &request.account_id)
        .await
        .map_err(|_| failed_recovery())?;
    let device_insert = sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status,created_at) VALUES(?,?,?,?,?,'active',?)")
        .bind(&request.device.device_id).bind(&request.account_id).bind(&request.device.name).bind(&request.device.signing_public_key).bind(&request.device.encryption_public_key).bind(crate::now_rfc3339()).execute(&mut *tx).await;
    if device_insert.is_err() {
        return Err(failed_recovery());
    }
    for key in &request.vault_key_envelopes {
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES(?,?,?,?,?,?,?,?)")
            .bind(&key.vault_id).bind(key.key_epoch).bind(&request.account_id).bind(&request.device.device_id).bind(key.envelope.to_string()).bind(&key.signature).bind(&request.device.device_id).bind(key.membership_version).execute(&mut *tx).await.map_err(|_| failed_recovery())?;
    }
    sqlx::query("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL")
        .bind(&now_text)
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM relay_tickets WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM notification_tickets WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("UPDATE auth_credentials SET login_verifier_hash=?,verifier_salt=?,kdf_json=?,account_key_envelope=?,credential_version=? WHERE user_id=?")
        .bind(new_verifier_hash).bind(new_verifier_salt).bind(kdf_json).bind(new_account_key_envelope).bind(new_credential_version).bind(&request.account_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE account_recovery SET recovery_generation=?,recovery_public_signing_key=?,recovery_public_encryption_key=?,recovery_envelope=?,recovery_identity_envelope=?,updated_at=? WHERE user_id=?")
        .bind(new_generation).bind(&request.next_recovery.recovery_public_signing_key).bind(&request.next_recovery.recovery_public_encryption_key).bind(next_recovery_envelope).bind(next_identity_envelope).bind(Utc::now().timestamp()).bind(&request.account_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
    save_recovery_generation(&mut tx, &request.account_id, new_generation).await?;
    sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    for entry in &request.next_recovery.key_envelopes {
        sqlx::query("INSERT INTO account_recovery_key_envelopes(user_id,recovery_generation,vault_id,key_epoch,envelope,recovery_signature,uploader_device_id,created_at) VALUES(?,?,?,?,?,?,?,?)")
            .bind(&request.account_id).bind(new_generation).bind(&entry.vault_id).bind(entry.key_epoch).bind(entry.envelope.to_string()).bind(&entry.recovery_signature).bind(&entry.uploader_device_id).bind(Utc::now().timestamp()).execute(&mut *tx).await.map_err(ApiError::internal)?;
    }
    let challenge_id_hash = crate::sha256_hex(request.challenge_id.as_bytes());
    // The challenge was checked earlier in this writer transaction, before
    // the recovery/device/keybox updates. Recheck its deadline when consuming
    // it so a completion that crosses the five-minute boundary during those
    // writes cannot commit after the challenge has expired.
    let consumed_at = Utc::now().timestamp();
    let consumed = sqlx::query("UPDATE account_recovery_challenges SET consumed_at=? WHERE challenge_id_hash=? AND consumed_at IS NULL AND expires_at>?")
        .bind(consumed_at).bind(challenge_id_hash).bind(consumed_at).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if consumed.rows_affected() != 1 {
        return Err(failed_recovery());
    }
    let response = complete_response(&request, new_credential_version, false);
    save_receipt(
        &mut tx,
        &request.account_id,
        &request.operation_id,
        &digest,
        &response,
    )
    .await?;
    let enabled_mfa: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_mfa WHERE user_id=? AND enabled_at IS NOT NULL",
    )
    .bind(&request.account_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM auth_mfa_login_challenges WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    // Recovery rotates the account verifier and revokes every old device. Any
    // enrolled or pending TOTP seed and every recovery-code hash is invalidated
    // in this same transaction, so the recovered owner must enroll again.
    sqlx::query("DELETE FROM auth_mfa WHERE user_id=?")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if enabled_mfa > 0 {
        crate::audit::record_account_event_tx(
            &mut tx,
            &state,
            &request.account_id,
            Some(&request.device.device_id),
            "auth.mfa_reset_by_recovery",
            "account",
            Some(&request.account_id),
            crate::audit::AuditSource::Api,
            Utc::now().timestamp(),
        )
        .await?;
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &request.account_id,
        Some(&request.device.device_id),
        "auth.account_recovered",
        "account",
        Some(&request.account_id),
        crate::audit::AuditSource::Api,
        Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

#[cfg(test)]
pub(crate) async fn complete_with_test_hooks(
    state: AppState,
    peer: SocketAddr,
    request: CompleteRequest,
    hooks: std::sync::Arc<RecoveryPurgeTestHooks>,
) -> Result<Json<Value>, ApiError> {
    complete_inner(state, peer, request, Some(&hooks)).await
}

fn validate_completion_device(device: &CompletionDevice, account_id: &str) -> Result<(), ApiError> {
    verify_completion_device(device, account_id)
}

#[cfg(test)]
mod tests {
    use super::{next_recovery_generation, recovery_challenge_is_live};
    use serde_json::{Value, json};

    const SHARED_VECTOR: &str =
        include_str!("../../protocol/test-vectors/account-recovery-v1.json");

    #[test]
    fn recovery_generation_is_monotonic_and_fails_closed_on_overflow() {
        assert_eq!(next_recovery_generation(0), Some(1));
        assert_eq!(next_recovery_generation(1), Some(2));
        assert_eq!(next_recovery_generation(17), Some(18));
        assert_eq!(next_recovery_generation(i64::MAX), None);
        assert_eq!(next_recovery_generation(-1), None);
    }

    #[test]
    fn recovery_challenge_expiry_is_exclusive_at_the_boundary() {
        assert!(recovery_challenge_is_live(101, 100));
        assert!(!recovery_challenge_is_live(100, 100));
        assert!(!recovery_challenge_is_live(99, 100));
    }

    #[test]
    fn account_recovery_shared_vector_matches_descriptor_and_ed25519_contract() {
        let vector: Value = serde_json::from_str(SHARED_VECTOR).unwrap();
        let descriptor = json!({
            "protocol": "atermius-account-recovery-descriptor-v1",
            "account_id": vector["account_id"],
            "instance_id": vector["instance_id"],
            "server_space_id": vector["server_space_id"],
            "recovery_generation": vector["recovery_generation"],
            "recovery_public_signing_key": vector["signing_public_key_base64url"],
            "recovery_public_encryption_key": vector["encryption_public_key_base64url"],
        });
        let descriptor_bytes = crate::jcs(&descriptor).unwrap();
        assert_eq!(
            descriptor_bytes,
            vector["descriptor_jcs_utf8"].as_str().unwrap().as_bytes()
        );
        let descriptor_hash = crate::sha256_hex(&descriptor_bytes);
        assert_eq!(descriptor_hash, vector["descriptor_sha256"]);

        for (payload_field, signature_field) in [
            (
                "recovery_identity_proof_payload_jcs_utf8",
                "recovery_identity_proof_signature_base64url",
            ),
            (
                "keybox_signature_payload_jcs_utf8",
                "keybox_recovery_signature_base64url",
            ),
        ] {
            let payload: Value =
                serde_json::from_str(vector[payload_field].as_str().unwrap()).unwrap();
            let payload_bytes = crate::jcs(&payload).unwrap();
            assert_eq!(
                payload_bytes,
                vector[payload_field].as_str().unwrap().as_bytes()
            );
            crate::auth::verify_key_signature(
                vector["signing_public_key_base64url"].as_str().unwrap(),
                vector[signature_field].as_str().unwrap(),
                &payload_bytes,
            )
            .unwrap();
        }
    }
}

#[cfg(test)]
#[path = "recovery_purge_race_tests.rs"]
mod recovery_purge_race_tests;

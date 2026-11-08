use crate::{ApiError, AppState, current_sync_user, jcs, sha256_hex};
use axum::{
    Json,
    extract::{Path, Query, State},
    http::HeaderMap,
    middleware::Next,
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Sha256;
#[cfg(test)]
use sqlx::Row;
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;
const MAX_OPERATIONS: usize = 100;
const MAX_BATCH_BYTES: usize = 1024 * 1024;
const MAX_SYNC_CURSOR_BYTES: usize = 2048;
// Room for an opaque cursor plus snapshot/limit query parameters. This is
// enforced in route middleware before Axum's Query extractor allocates any
// pagination string.
const MAX_SYNC_QUERY_BYTES: usize = MAX_SYNC_CURSOR_BYTES + 64;
pub(crate) const MAX_OBJECT_REFS: usize = 1024;
/// Maximum serialized response size for sync/event pages (including the JSON
/// wrapper). A small fixed reserve is left for cursors, IDs and page metadata.
pub(crate) const MAX_SYNC_PAGE_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const SYNC_PAGE_METADATA_RESERVE_BYTES: usize = 4096;
/// Maximum serialized full snapshot response. The current API returns one
/// complete manifest, so it fails closed above the bounded response size.
pub(crate) const MAX_SYNC_SNAPSHOT_RESPONSE_BYTES: usize = MAX_SYNC_PAGE_RESPONSE_BYTES;
/// Space reserved for snapshot identifiers, watermarks, cursor and wrapper.
pub(crate) const SYNC_SNAPSHOT_METADATA_RESERVE_BYTES: usize = 4096;
const MAX_SYNC_SNAPSHOT_PAGE_CURSOR_BYTES: usize = 2048;

pub(crate) fn record_restore_expired(
    restore_retention_days: i64,
    restore_expires_at: Option<&str>,
) -> ApiError {
    ApiError::conflict(
        "RECORD_RESTORE_EXPIRED",
        "the record restore window has expired; create a new record with a new ID",
    )
    .with_details(json!({
        "recovery": "create_new_record",
        "restore_retention_days": restore_retention_days,
        "restore_until": restore_expires_at,
        "restore_expires_at": restore_expires_at,
    }))
}

pub(crate) fn restore_deadline_elapsed(
    now: chrono::DateTime<chrono::Utc>,
    restore_until: chrono::DateTime<chrono::Utc>,
) -> bool {
    now >= restore_until
}

pub(crate) fn sync_snapshot_payload_too_large() -> ApiError {
    ApiError::too_large("snapshot manifest exceeds the maximum serialized response size")
        .with_details(json!({
            "max_response_bytes": MAX_SYNC_SNAPSHOT_RESPONSE_BYTES,
            "recovery": "contact_server_operator",
        }))
}

pub(crate) fn ensure_sync_snapshot_response_fits(response: &Value) -> Result<(), ApiError> {
    let serialized_len = serde_json::to_vec(response)
        .map_err(ApiError::internal)?
        .len();
    if serialized_len > MAX_SYNC_SNAPSHOT_RESPONSE_BYTES {
        return Err(sync_snapshot_payload_too_large());
    }
    Ok(())
}

#[derive(Default)]
pub(crate) struct SyncPageBudget {
    event_bytes: usize,
    event_count: usize,
}

impl SyncPageBudget {
    /// Adds one serialized event if doing so leaves enough room for the fixed
    /// page wrapper. A rejected event does not change the budget, so callers
    /// can keep the cursor at the last event they actually returned.
    pub(crate) fn try_add(&mut self, event: &Value) -> Result<bool, ApiError> {
        let event_bytes = serde_json::to_vec(event).map_err(ApiError::internal)?.len();
        let separator_bytes = if self.event_count > 0 { 1 } else { 0 };
        let next = self
            .event_bytes
            .saturating_add(separator_bytes)
            .saturating_add(event_bytes);
        let event_budget =
            MAX_SYNC_PAGE_RESPONSE_BYTES.saturating_sub(SYNC_PAGE_METADATA_RESERVE_BYTES);
        if next > event_budget {
            return Ok(false);
        }
        self.event_bytes = next;
        self.event_count += 1;
        Ok(true)
    }
}

pub(crate) fn ensure_sync_page_response_fits(response: &Value) -> Result<(), ApiError> {
    let serialized_len = serde_json::to_vec(response)
        .map_err(ApiError::internal)?
        .len();
    if serialized_len > MAX_SYNC_PAGE_RESPONSE_BYTES {
        return Err(ApiError::internal(
            "sync page exceeded its reserved serialized response budget",
        ));
    }
    Ok(())
}

pub(crate) fn sync_page_item_too_large() -> ApiError {
    ApiError::too_large("one sync event exceeds the maximum serialized page size").with_details(
        json!({
            "max_response_bytes": MAX_SYNC_PAGE_RESPONSE_BYTES,
            "recovery": "contact_server_operator",
        }),
    )
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Envelope {
    pub header: Value,
    pub nonce: String,
    pub ciphertext: String,
    pub signature: String,
}
#[derive(Debug, Deserialize, Serialize)]
pub struct PushRequest {
    pub protocol_version: u32,
    pub server_generation: String,
    pub vault_id: String,
    pub device_id: String,
    pub batch_id: String,
    pub operations: Vec<Envelope>,
}
#[derive(Serialize)]
pub struct CommitResult {
    pub op_id: String,
    pub revision_id: String,
    pub commit_seq: String,
    pub already_committed: bool,
}
#[derive(Deserialize)]
pub struct ChangesQuery {
    pub cursor: Option<String>,
    pub limit: Option<u32>,
}
#[derive(Deserialize)]
pub struct HistoryQuery {
    pub snapshot_id: Option<String>,
    pub cursor: Option<String>,
    pub limit: Option<String>,
}
#[derive(Debug, Deserialize)]
pub struct ConflictChangesQuery {
    pub after_seq: Option<String>,
    pub limit: Option<String>,
    pub server_generation: Option<String>,
}
#[derive(Debug, Deserialize)]
pub struct SnapshotQuery {
    pub limit: Option<String>,
    pub page_cursor: Option<String>,
}
#[derive(Deserialize)]
pub struct ResolveConflict {
    pub resolved_revision_id: String,
}

pub(crate) fn conflict_resolution_retry(
    existing_revision_id: Option<&str>,
    requested_revision_id: &str,
) -> Result<bool, ApiError> {
    match existing_revision_id {
        None => Ok(false),
        Some(existing) if existing == requested_revision_id => Ok(true),
        Some(_) => Err(ApiError::conflict(
            "CONFLICT_ALREADY_RESOLVED",
            "conflict was already resolved",
        )),
    }
}

fn id_field(header: &Value, name: &str) -> Result<String, ApiError> {
    let s = header
        .get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::invalid_envelope("record envelope header is incomplete"))?;
    if s.len() > 128 || s.is_empty() {
        return Err(ApiError::invalid_envelope(
            "record envelope header is invalid",
        ));
    }
    Ok(s.to_owned())
}

/// Returns whether `value` is in the same canonical decimal form required by
/// the clients. Keeping the textual form canonical matters for device_seq:
/// its uniqueness receipt is stored as text, so accepting aliases such as
/// `"01"` would let one device reuse the logical sequence `1`.
fn is_canonical_decimal_counter(value: &str, allow_zero: bool) -> bool {
    !value.is_empty()
        && value.bytes().all(|byte| byte.is_ascii_digit())
        && (value == "0" || !value.starts_with('0'))
        && (allow_zero || value != "0")
}

fn parse_object_refs(header: &Value) -> Result<Vec<String>, ApiError> {
    let Some(value) = header.get("object_refs") else {
        return Ok(Vec::new());
    };
    let refs = value
        .as_array()
        .ok_or_else(|| ApiError::invalid_envelope("object_refs must be an array"))?;
    if refs.len() > MAX_OBJECT_REFS {
        return Err(ApiError::invalid_envelope(
            "object_refs exceeds the per-revision limit",
        ));
    }
    let mut result = Vec::with_capacity(refs.len());
    let mut previous: Option<&str> = None;
    for item in refs {
        let object_id = item.as_str().ok_or_else(|| {
            ApiError::invalid_envelope("object_refs entries must be UUID strings")
        })?;
        if !crate::is_canonical_uuid(object_id) || previous.is_some_and(|prior| prior >= object_id)
        {
            return Err(ApiError::invalid_envelope(
                "object_refs must be unique, strictly sorted canonical lowercase UUIDs",
            ));
        }
        result.push(object_id.to_owned());
        previous = Some(object_id);
    }
    Ok(result)
}

#[cfg(test)]
pub(crate) use crate::sync_repository::persist_object_references_tx;

fn verify_envelope(
    state: &AppState,
    public: &str,
    vault_id: &str,
    device_id: &str,
    env: &Envelope,
) -> Result<VerifiedOperation, ApiError> {
    if !env.header.is_object() || env.header.to_string().len() > 64 * 1024 {
        return Err(ApiError::invalid_envelope("record header is invalid"));
    }
    let object_refs = parse_object_refs(&env.header)?;
    let getnum = |name: &str| env.header.get(name).and_then(Value::as_u64);
    let Some(record_schema @ 1..=2) = getnum("record_schema") else {
        return Err(ApiError::invalid_envelope(
            "record wire version or schema is unsupported",
        ));
    };
    if getnum("wire_version") != Some(1) {
        return Err(ApiError::invalid_envelope(
            "record wire version is unsupported",
        ));
    }
    let header_vault = id_field(&env.header, "vault_id")?;
    let header_device = id_field(&env.header, "device_id")?;
    if header_vault != vault_id
        || header_device != device_id
        || id_field(&env.header, "server_space_id")? != state.instance.server_space_id
        || id_field(&env.header, "crypto_suite")? != "atermius-vault-v1"
    {
        return Err(ApiError::invalid_envelope(
            "record context does not match this request",
        ));
    }
    let record_id = id_field(&env.header, "record_id")?;
    let revision_id = id_field(&env.header, "revision_id")?;
    let op_id = id_field(&env.header, "op_id")?;
    for id in [&record_id, &revision_id, &op_id] {
        if !crate::is_canonical_uuid(id) {
            return Err(ApiError::invalid_envelope(
                "record identifiers must be lowercase canonical UUIDs",
            ));
        }
    }
    let device_seq = id_field(&env.header, "device_seq")?;
    if !is_canonical_decimal_counter(&device_seq, true) {
        return Err(ApiError::invalid_envelope(
            "device sequence must be a canonical decimal counter",
        ));
    }
    let _: u64 = device_seq
        .parse()
        .map_err(|_| ApiError::invalid_envelope("device sequence is out of range"))?;
    let key_epoch_text = id_field(&env.header, "key_epoch")?;
    if !is_canonical_decimal_counter(&key_epoch_text, false) {
        return Err(ApiError::invalid_envelope("key epoch is invalid"));
    }
    let key_epoch = key_epoch_text
        .parse::<i64>()
        .map_err(|_| ApiError::invalid_envelope("key epoch is invalid"))?;
    let membership_version_text = id_field(&env.header, "membership_version")?;
    if !is_canonical_decimal_counter(&membership_version_text, false) {
        return Err(ApiError::invalid_envelope("membership version is invalid"));
    }
    let membership_version = membership_version_text
        .parse::<i64>()
        .map_err(|_| ApiError::invalid_envelope("membership version is invalid"))?;
    let operation = id_field(&env.header, "operation")?;
    if !["create", "update", "delete", "restore"].contains(&operation.as_str()) {
        return Err(ApiError::invalid_envelope(
            "record operation is unsupported",
        ));
    }
    let base = env
        .header
        .get("base_revision_id")
        .and_then(Value::as_str)
        .map(str::to_owned);
    if env
        .header
        .get("base_revision_id")
        .is_some_and(|v| !v.is_null() && !v.is_string())
    {
        return Err(ApiError::invalid_envelope(
            "base revision identifier is invalid",
        ));
    }
    let nonce = URL_SAFE_NO_PAD
        .decode(&env.nonce)
        .map_err(|_| ApiError::invalid_envelope("record nonce is invalid"))?;
    let ciphertext = URL_SAFE_NO_PAD
        .decode(&env.ciphertext)
        .map_err(|_| ApiError::invalid_envelope("record ciphertext is invalid"))?;
    if nonce.len() != 24 || ciphertext.len() < 16 || ciphertext.len() > MAX_BATCH_BYTES {
        return Err(ApiError::invalid_envelope(
            "record nonce or ciphertext length is invalid",
        ));
    }
    let salt = id_field(&env.header, "kdf_salt")?;
    if URL_SAFE_NO_PAD.decode(salt).map_or(true, |b| b.len() != 32) {
        return Err(ApiError::invalid_envelope("record KDF salt is invalid"));
    }
    let signed = jcs(&json!({"header":env.header,"nonce":env.nonce,"ciphertext":env.ciphertext}))?;
    let pub_bytes = URL_SAFE_NO_PAD
        .decode(public)
        .map_err(|_| ApiError::invalid_envelope("device signing key is invalid"))?;
    let vk = VerifyingKey::from_bytes(
        pub_bytes
            .as_slice()
            .try_into()
            .map_err(|_| ApiError::invalid_envelope("device signing key is invalid"))?,
    )
    .map_err(|_| ApiError::invalid_envelope("device signing key is invalid"))?;
    let sig = URL_SAFE_NO_PAD
        .decode(&env.signature)
        .map_err(|_| ApiError::invalid_envelope("record signature is invalid"))?;
    let sig = Signature::from_slice(&sig)
        .map_err(|_| ApiError::invalid_envelope("record signature is invalid"))?;
    vk.verify(&signed, &sig)
        .map_err(|_| ApiError::invalid_envelope("record signature is invalid"))?;
    Ok(VerifiedOperation {
        record_id,
        revision_id,
        op_id,
        record_schema: record_schema as i64,
        device_seq,
        key_epoch,
        membership_version,
        operation,
        base,
        object_refs,
        env: env.clone(),
    })
}
#[derive(Clone)]
pub(crate) struct VerifiedOperation {
    pub(crate) record_id: String,
    pub(crate) revision_id: String,
    pub(crate) op_id: String,
    pub(crate) record_schema: i64,
    pub(crate) device_seq: String,
    pub(crate) key_epoch: i64,
    pub(crate) membership_version: i64,
    pub(crate) operation: String,
    pub(crate) base: Option<String>,
    pub(crate) object_refs: Vec<String>,
    pub(crate) env: Envelope,
}

#[cfg(test)]
fn cursor(state: &AppState, vault: &str, seq: i64) -> Result<String, ApiError> {
    encode_cursor_with_key(
        state.cursor_key.as_ref(),
        &state.instance.generation,
        vault,
        seq,
    )
}

pub(crate) fn encode_cursor_with_key(
    cursor_key: &[u8; 32],
    generation: &str,
    vault: &str,
    seq: i64,
) -> Result<String, ApiError> {
    let data = jcs(&json!({"v":1,"vault_id":vault,"seq":seq,"generation":generation}))?;
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(&data);
    let tag = mac.finalize().into_bytes();
    Ok(URL_SAFE_NO_PAD.encode([data, tag.to_vec()].concat()))
}
pub(crate) fn cursor_is_expired(after: i64, minimum_available: i64) -> bool {
    after < minimum_available.saturating_sub(1)
}

/// A physical restore can roll `instance-ed25519.key` and SQLite back
/// together. A client may then present a cursor issued after that backup,
/// signed under the newer key that the restored server no longer has. Its
/// MAC cannot be authenticated, so the generation claim is used only to ask
/// the client for a snapshot; it never authorizes a page, cursor position, or
/// write. Keep this fallback strict and bounded: only canonical cursors for
/// this Vault with a different canonical generation receive recovery status.
fn foreign_generation_cursor_claim(data: &[u8], vault: &str, generation: &str) -> bool {
    let Ok(value) = serde_json::from_slice::<Value>(data) else {
        return false;
    };
    let Ok(canonical) = jcs(&value) else {
        return false;
    };
    if canonical != data {
        return false;
    }
    let Some(fields) = value.as_object() else {
        return false;
    };
    if fields.len() != 4
        || value.get("v").and_then(Value::as_u64) != Some(1)
        || value.get("vault_id").and_then(Value::as_str) != Some(vault)
        || !crate::is_canonical_uuid(vault)
    {
        return false;
    }
    let Some(cursor_generation) = value.get("generation").and_then(Value::as_str) else {
        return false;
    };
    if !crate::is_canonical_uuid(cursor_generation) || cursor_generation == generation {
        return false;
    }
    value
        .get("seq")
        .and_then(Value::as_i64)
        .is_some_and(|seq| seq >= 0)
}

#[cfg(test)]
fn parse_cursor(state: &AppState, vault: &str, value: &str) -> Result<i64, ApiError> {
    parse_cursor_with_key(
        state.cursor_key.as_ref(),
        &state.instance.generation,
        vault,
        value,
    )
}

pub(crate) fn parse_cursor_with_key(
    cursor_key: &[u8; 32],
    generation: &str,
    vault: &str,
    value: &str,
) -> Result<i64, ApiError> {
    if value.len() > MAX_SYNC_CURSOR_BYTES {
        return Err(ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"));
    }
    let all = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"))?;
    if all.len() < 32 {
        return Err(ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"));
    }
    let split = all.len() - 32;
    let (data, tag) = all.split_at(split);
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(data);
    if mac.verify_slice(tag).is_err() {
        if foreign_generation_cursor_claim(data, vault, generation) {
            return Err(ApiError::gone(
                "CURSOR_EXPIRED",
                "cursor cannot be verified for the current server generation; create a fresh snapshot",
            )
            .with_details(json!({
                "recovery":"create_snapshot",
                "preserve_local_outbox":true
            })));
        }
        return Err(ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"));
    }
    let value: Value = serde_json::from_slice(data).map_err(ApiError::internal)?;
    if value.get("v").and_then(Value::as_u64) != Some(1)
        || value.get("vault_id").and_then(Value::as_str) != Some(vault)
    {
        return Err(ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"));
    }
    if value.get("generation").and_then(Value::as_str) != Some(generation) {
        return Err(ApiError::gone(
            "CURSOR_EXPIRED",
            "cursor belongs to an earlier server generation",
        )
        .with_details(json!({"recovery":"create_snapshot","preserve_local_outbox":true})));
    }
    value
        .get("seq")
        .and_then(Value::as_i64)
        .ok_or_else(|| ApiError::bad_request("INVALID_CURSOR", "cursor is invalid"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HistoryKind {
    Revisions,
    Conflicts,
}

impl HistoryKind {
    fn wire_name(self) -> &'static str {
        match self {
            Self::Revisions => "revisions",
            Self::Conflicts => "conflicts",
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub(crate) struct HistoryBounds {
    pub(crate) revisions: i64,
    pub(crate) conflicts: i64,
}

pub(crate) fn history_cursor(
    generation: &str,
    cursor_key: &[u8; 32],
    kind: HistoryKind,
    vault: &str,
    snapshot: &str,
    bounds: HistoryBounds,
    after: i64,
) -> Result<String, ApiError> {
    let data = jcs(&json!({
        "v": 1,
        "kind": kind.wire_name(),
        "vault_id": vault,
        "snapshot_id": snapshot,
        "generation": generation,
        "high_watermark": bounds.revisions.to_string(),
        "conflict_high_watermark": bounds.conflicts.to_string(),
        "after": after.to_string(),
    }))?;
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(b"atermius/history-cursor/v1\0");
    mac.update(&data);
    let tag = mac.finalize().into_bytes();
    Ok(URL_SAFE_NO_PAD.encode([data, tag.to_vec()].concat()))
}

pub(crate) fn snapshot_page_cursor(
    generation: &str,
    cursor_key: &[u8; 32],
    vault: &str,
    snapshot: &str,
    after_record_id: &str,
) -> Result<String, ApiError> {
    let data = jcs(&json!({
        "v": 1,
        "vault_id": vault,
        "snapshot_id": snapshot,
        "generation": generation,
        "after_record_id": after_record_id,
    }))?;
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(b"atermius/snapshot-page-cursor/v1\0");
    mac.update(&data);
    let tag = mac.finalize().into_bytes();
    Ok(URL_SAFE_NO_PAD.encode([data, tag.to_vec()].concat()))
}

pub(crate) fn parse_snapshot_page_cursor(
    generation: &str,
    cursor_key: &[u8; 32],
    vault: &str,
    snapshot: &str,
    encoded: &str,
) -> Result<String, ApiError> {
    let invalid = || ApiError::bad_request("INVALID_CURSOR", "snapshot page cursor is invalid");
    if encoded.is_empty() || encoded.len() > MAX_SYNC_SNAPSHOT_PAGE_CURSOR_BYTES {
        return Err(invalid());
    }
    let all = URL_SAFE_NO_PAD.decode(encoded).map_err(|_| invalid())?;
    if all.len() < 33 || URL_SAFE_NO_PAD.encode(&all) != encoded {
        return Err(invalid());
    }
    let split = all.len() - 32;
    let (data, tag) = all.split_at(split);
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(b"atermius/snapshot-page-cursor/v1\0");
    mac.update(data);
    mac.verify_slice(tag).map_err(|_| invalid())?;
    let value: Value = serde_json::from_slice(data).map_err(|_| invalid())?;
    if jcs(&value).map_err(|_| invalid())? != data {
        return Err(invalid());
    }
    let Some(fields) = value.as_object() else {
        return Err(invalid());
    };
    if fields.len() != 5
        || ![
            "v",
            "vault_id",
            "snapshot_id",
            "generation",
            "after_record_id",
        ]
        .iter()
        .all(|field| fields.contains_key(*field))
        || value.get("v").and_then(Value::as_u64) != Some(1)
        || value.get("vault_id").and_then(Value::as_str) != Some(vault)
        || value.get("snapshot_id").and_then(Value::as_str) != Some(snapshot)
        || value.get("generation").and_then(Value::as_str) != Some(generation)
    {
        return Err(invalid());
    }
    let after = value
        .get("after_record_id")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty() && value.len() <= 256)
        .ok_or_else(invalid)?;
    Ok(after.to_owned())
}

/// A physical restore can remove a snapshot row together with the newer key
/// that signed its history cursor. After Vault access is checked, a strictly
/// typed foreign-generation claim may tell the client to create a new
/// snapshot. The claim is only a recovery hint: none of its watermarks or
/// position are used to read history.
pub(crate) fn foreign_generation_history_cursor_claim(
    encoded: &str,
    kind: HistoryKind,
    vault: &str,
    snapshot: &str,
    generation: &str,
) -> bool {
    if encoded.len() > MAX_SYNC_CURSOR_BYTES {
        return false;
    }
    let Ok(all) = URL_SAFE_NO_PAD.decode(encoded) else {
        return false;
    };
    if all.len() < 33 || URL_SAFE_NO_PAD.encode(&all) != encoded {
        return false;
    }
    let data = &all[..all.len() - 32];
    let Ok(value) = serde_json::from_slice::<Value>(data) else {
        return false;
    };
    let Ok(canonical) = jcs(&value) else {
        return false;
    };
    if canonical != data {
        return false;
    }
    let Some(fields) = value.as_object() else {
        return false;
    };
    let expected_fields = [
        "after",
        "conflict_high_watermark",
        "generation",
        "high_watermark",
        "kind",
        "snapshot_id",
        "v",
        "vault_id",
    ];
    if fields.len() != expected_fields.len()
        || expected_fields
            .iter()
            .any(|field| !fields.contains_key(*field))
        || value.get("v").and_then(Value::as_u64) != Some(1)
        || value.get("kind").and_then(Value::as_str) != Some(kind.wire_name())
        || value.get("vault_id").and_then(Value::as_str) != Some(vault)
        || !crate::is_canonical_uuid(vault)
        || value.get("snapshot_id").and_then(Value::as_str) != Some(snapshot)
        || !crate::is_canonical_uuid(snapshot)
    {
        return false;
    }
    let is_canonical_sequence = |field: &str| {
        value
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(|sequence| {
                !sequence.is_empty()
                    && sequence.bytes().all(|byte| byte.is_ascii_digit())
                    && !(sequence.len() > 1 && sequence.starts_with('0'))
                    && sequence.parse::<i64>().is_ok()
            })
    };
    if !is_canonical_sequence("after")
        || !is_canonical_sequence("high_watermark")
        || !is_canonical_sequence("conflict_high_watermark")
    {
        return false;
    }
    let Some(cursor_generation) = value.get("generation").and_then(Value::as_str) else {
        return false;
    };
    crate::is_canonical_uuid(cursor_generation) && cursor_generation != generation
}

pub(crate) fn parse_history_cursor(
    cursor_key: &[u8; 32],
    generation: &str,
    kind: HistoryKind,
    vault: &str,
    snapshot: &str,
    bounds: HistoryBounds,
    value: &str,
) -> Result<i64, ApiError> {
    let invalid = || ApiError::bad_request("INVALID_CURSOR", "history cursor is invalid");
    let all = URL_SAFE_NO_PAD.decode(value).map_err(|_| invalid())?;
    if all.len() < 33 {
        return Err(invalid());
    }
    let split = all.len() - 32;
    let (data, tag) = all.split_at(split);
    let mut mac = HmacSha256::new_from_slice(cursor_key).map_err(ApiError::internal)?;
    mac.update(b"atermius/history-cursor/v1\0");
    mac.update(data);
    mac.verify_slice(tag).map_err(|_| invalid())?;
    let value: Value = serde_json::from_slice(data).map_err(|_| invalid())?;
    let revision_watermark = bounds.revisions.to_string();
    let conflict_watermark = bounds.conflicts.to_string();
    if value.get("v").and_then(Value::as_u64) != Some(1)
        || value.get("kind").and_then(Value::as_str) != Some(kind.wire_name())
        || value.get("vault_id").and_then(Value::as_str) != Some(vault)
        || value.get("snapshot_id").and_then(Value::as_str) != Some(snapshot)
        || value.get("high_watermark").and_then(Value::as_str) != Some(revision_watermark.as_str())
        || value.get("conflict_high_watermark").and_then(Value::as_str)
            != Some(conflict_watermark.as_str())
    {
        return Err(invalid());
    }
    if value.get("generation").and_then(Value::as_str) != Some(generation) {
        return Err(ApiError::gone(
            "HISTORY_CURSOR_EXPIRED",
            "history cursor belongs to a previous server generation",
        )
        .with_details(json!({"recovery":"create_new_snapshot"})));
    }
    let after = value
        .get("after")
        .and_then(Value::as_str)
        .and_then(|s| s.parse::<i64>().ok())
        .ok_or_else(invalid)?;
    let high = match kind {
        HistoryKind::Revisions => bounds.revisions,
        HistoryKind::Conflicts => bounds.conflicts,
    };
    if after < 0 || after > high {
        return Err(invalid());
    }
    Ok(after)
}

fn parse_history_limit(limit: Option<&str>) -> Result<i64, ApiError> {
    let limit = match limit {
        Some(value) => value.parse::<i64>().map_err(|_| {
            ApiError::bad_request("INVALID_LIMIT", "history page limit must be from 1 to 500")
        })?,
        None => 500,
    };
    if !(1..=500).contains(&limit) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "history page limit must be from 1 to 500",
        ));
    }
    Ok(limit)
}

#[derive(Debug)]
struct ParsedConflictChangesQuery {
    after_seq: i64,
    after_seq_wire: String,
    limit: i64,
    server_generation: Option<String>,
}

fn parse_conflict_changes_query(
    query: ConflictChangesQuery,
) -> Result<ParsedConflictChangesQuery, ApiError> {
    let has_after_seq = query.after_seq.is_some();
    let after_seq_wire = query.after_seq.unwrap_or_else(|| "0".to_owned());
    if after_seq_wire.is_empty()
        || !after_seq_wire.bytes().all(|byte| byte.is_ascii_digit())
        || (after_seq_wire.len() > 1 && after_seq_wire.starts_with('0'))
    {
        return Err(ApiError::bad_request(
            "INVALID_AFTER_SEQ",
            "after_seq must be a canonical non-negative decimal string",
        ));
    }
    let after_seq = after_seq_wire.parse::<i64>().map_err(|_| {
        ApiError::bad_request(
            "INVALID_AFTER_SEQ",
            "after_seq must be a canonical non-negative decimal string",
        )
    })?;
    let limit = match query.limit.as_deref() {
        Some(value) => parse_history_limit(Some(value))?,
        None => 100,
    };
    if has_after_seq && query.server_generation.is_none() {
        return Err(ApiError::bad_request(
            "SERVER_GENERATION_REQUIRED",
            "server_generation is required when continuing from an after_seq checkpoint",
        ));
    }
    if query
        .server_generation
        .as_deref()
        .is_some_and(|generation| !crate::is_canonical_uuid(generation))
    {
        return Err(ApiError::bad_request(
            "INVALID_SERVER_GENERATION",
            "server_generation must be a lowercase canonical UUID",
        ));
    }
    Ok(ParsedConflictChangesQuery {
        after_seq,
        after_seq_wire,
        limit,
        server_generation: query.server_generation,
    })
}

fn required_history_snapshot_id(value: Option<&str>) -> Result<&str, ApiError> {
    value
        .filter(|snapshot_id| crate::is_canonical_uuid(snapshot_id))
        .ok_or_else(|| {
            ApiError::bad_request(
                "INVALID_SNAPSHOT_ID",
                "snapshot_id must be a lowercase canonical UUID",
            )
        })
}

pub async fn push(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(path_vault): Path<String>,
    Json(req): Json<PushRequest>,
) -> Result<Json<Value>, ApiError> {
    #[cfg(test)]
    {
        push_inner(state, headers, path_vault, req, None).await
    }
    #[cfg(not(test))]
    {
        push_inner(state, headers, path_vault, req).await
    }
}

async fn push_inner(
    state: AppState,
    headers: HeaderMap,
    path_vault: String,
    req: PushRequest,
    #[cfg(test)] test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    if req.vault_id != path_vault {
        return Err(ApiError::bad_request(
            "VAULT_MISMATCH",
            "vault id does not match route",
        ));
    }
    if req.device_id != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "request device does not match session device",
        ));
    }
    if req.protocol_version != 1 {
        return Err(ApiError::new(
            axum::http::StatusCode::UPGRADE_REQUIRED,
            "UPGRADE_REQUIRED",
            "protocol version is unsupported",
        ));
    }
    if req.server_generation != state.instance.generation {
        return Err(ApiError::gone(
            "SERVER_GENERATION_CHANGED",
            "server generation changed; create a fresh snapshot",
        ));
    }
    if !crate::is_canonical_uuid(&req.batch_id) {
        return Err(ApiError::bad_request(
            "INVALID_BATCH_ID",
            "batch_id must be a lowercase canonical UUID",
        ));
    }
    if req.operations.is_empty() || req.operations.len() > MAX_OPERATIONS {
        return Err(ApiError::bad_request(
            "INVALID_BATCH",
            "batch must contain 1 to 100 operations",
        ));
    }
    let digest = sha256_hex(&jcs(&req)?);
    if jcs(&req)?.len() > MAX_BATCH_BYTES {
        return Err(ApiError::too_large("sync batch exceeds 1 MiB"));
    }
    let public = state
        .sync_repository
        .active_device_signing_key(user.user_id.clone(), user.device_id.clone())
        .await?
        .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
    let mut checked = Vec::with_capacity(req.operations.len());
    let mut opids = std::collections::HashSet::new();
    let mut recids = std::collections::HashSet::new();
    for env in &req.operations {
        let item = verify_envelope(&state, &public, &path_vault, &req.device_id, env)?;
        if !opids.insert(item.op_id.clone()) || !recids.insert(item.record_id.clone()) {
            return Err(ApiError::bad_request(
                "INVALID_BATCH",
                "batch may contain each operation and record only once",
            ));
        }
        checked.push(item);
    }
    // Reuse the Recovery/purge test gate to pause a real push request after
    // bearer, vault, device, generation, and signature preflight but before
    // it asks SQLite for the writer reservation. This seam is test-only and
    // normal router calls never install a gate.
    #[cfg(test)]
    if let Some(gate) = test_pause.as_ref() {
        gate.pause().await;
    }
    let response = state
        .sync_repository
        .commit_batch(crate::sync_repository::PushCommit {
            user,
            vault_id: path_vault,
            device_id: req.device_id,
            batch_id: req.batch_id,
            request_digest: digest,
            operations: checked,
            restore_retention_days: state.config.record_restore_retention_days,
        })
        .await?;
    Ok(Json(response))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PurgeRecordRequest {
    pub expected_deleted_revision_id: String,
    pub expected_deleted_seq: String,
}

/// Permanently removes one expired tombstone from active server state. The
/// request names the exact tombstone revision and sequence so stale recycle
/// bin actions cannot purge a later delete/restore cycle.
pub async fn purge_record(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault, record)): Path<(String, String)>,
    Json(request): Json<PurgeRecordRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    if !user.declares_sync_redaction_v1 {
        return Err(ApiError::bad_request(
            "INVALID_REDACTION_MARKER",
            "exactly one X-Atermius-Redaction-Marker: v1 header is required",
        ));
    }
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        let signer = crate::pg_record_redaction::PgRedactionProofSigner::new(
            (*state.instance).clone(),
            state.signing_key.clone(),
        );
        let repository = crate::pg_record_purge::PgRecordPurgeRepository::new(pool.clone(), signer);
        let response = repository
            .purge(
                &user,
                &vault,
                &record,
                &request.expected_deleted_revision_id,
                &request.expected_deleted_seq,
                state.config.object_gc_grace_seconds,
            )
            .await?;
        return Ok(Json(response));
    }
    let response = crate::record_purge::purge_record_sqlite(
        &state,
        &user,
        &vault,
        &record,
        &request.expected_deleted_revision_id,
        &request.expected_deleted_seq,
    )
    .await?;
    Ok(Json(response))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateAutomaticPurgeRequest {
    pub expected_deleted_revision_id: String,
    pub expected_deleted_seq: String,
    pub expected_policy_revision: String,
    pub enabled: bool,
}

pub async fn update_automatic_purge_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault, record)): Path<(String, String)>,
    Json(request): Json<UpdateAutomaticPurgeRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    let response = if let Some(pool) = state.pg_sync_pool.as_ref() {
        let signer = crate::pg_record_redaction::PgRedactionProofSigner::new(
            (*state.instance).clone(),
            state.signing_key.clone(),
        );
        crate::pg_record_purge::PgRecordPurgeRepository::new(pool.clone(), signer)
            .set_auto_purge_policy(
                &user,
                &vault,
                &record,
                &request.expected_deleted_revision_id,
                &request.expected_deleted_seq,
                &request.expected_policy_revision,
                request.enabled,
            )
            .await?
    } else {
        crate::record_purge::set_record_auto_purge_sqlite(
            &state,
            &user,
            &vault,
            &record,
            &request.expected_deleted_revision_id,
            &request.expected_deleted_seq,
            &request.expected_policy_revision,
            request.enabled,
        )
        .await?
    };
    Ok(Json(response))
}

pub(crate) fn ensure_envelope_readable(
    declares_record_schema2: bool,
    envelope: &Value,
) -> Result<(), ApiError> {
    let schema = envelope
        .get("header")
        .and_then(|header| header.get("record_schema"))
        .and_then(Value::as_i64);
    if !declares_record_schema2 && schema.is_some_and(|schema| schema >= 2) {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "this client has not declared support for the stored record schema",
        ));
    }
    Ok(())
}

pub async fn changes(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Query(q): Query<ChangesQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    changes_for_user(&state, &user, &vault, q).await
}

pub async fn guard_sync_query_length(request: axum::extract::Request, next: Next) -> Response {
    if request
        .uri()
        .query()
        .is_some_and(|query| query.len() > MAX_SYNC_QUERY_BYTES)
    {
        return ApiError::bad_request("INVALID_CURSOR", "cursor is invalid").into_response();
    }
    next.run(request).await
}

async fn changes_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    vault: &str,
    q: ChangesQuery,
) -> Result<Json<Value>, ApiError> {
    let limit = q.limit.unwrap_or(500).clamp(1, 500) as i64;
    let response = state
        .sync_repository
        .read_changes_page(crate::sync_repository::ChangesPageCommand {
            user: user.clone(),
            vault_id: vault.to_owned(),
            raw_cursor: q.cursor,
            limit,
            cursor_key: *state.cursor_key,
            generation: state.instance.generation.clone(),
            #[cfg(test)]
            test_pause: None,
        })
        .await?;
    Ok(Json(response))
}

pub async fn create_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    let response = state
        .sync_repository
        .create_snapshot(crate::sync_repository::CreateSnapshotCommand {
            user,
            vault_id: vault,
            generation: state.instance.generation.clone(),
            cursor_key: *state.cursor_key,
        })
        .await?;
    Ok(Json(response))
}
pub async fn get_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Query(query): Query<SnapshotQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    get_snapshot_for_user(&state, &user, &id, query).await
}

async fn get_snapshot_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    id: &str,
    query: SnapshotQuery,
) -> Result<Json<Value>, ApiError> {
    let page = match (query.limit.as_deref(), query.page_cursor) {
        (None, None) => None,
        (limit, page_cursor) => {
            let limit = match limit {
                Some(value)
                    if !value.is_empty()
                        && value.bytes().all(|byte| byte.is_ascii_digit())
                        && !(value.len() > 1 && value.starts_with('0')) =>
                {
                    value.parse::<i64>().map_err(|_| {
                        ApiError::bad_request(
                            "INVALID_LIMIT",
                            "snapshot page limit must be from 1 to 500",
                        )
                    })?
                }
                Some(_) => {
                    return Err(ApiError::bad_request(
                        "INVALID_LIMIT",
                        "snapshot page limit must be from 1 to 500",
                    ));
                }
                None => 100,
            };
            if !(1..=500).contains(&limit) {
                return Err(ApiError::bad_request(
                    "INVALID_LIMIT",
                    "snapshot page limit must be from 1 to 500",
                ));
            }
            Some(crate::sync_repository::SnapshotPageRequest { limit, page_cursor })
        }
    };
    let response = state
        .sync_repository
        .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
            user: user.clone(),
            snapshot_id: id.to_owned(),
            generation: state.instance.generation.clone(),
            cursor_key: *state.cursor_key,
            page,
        })
        .await?;
    Ok(Json(response))
}

pub async fn revision_history(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    history_page_for_user(&state, &user, &vault, query, HistoryKind::Revisions).await
}

pub async fn conflict_history(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    history_page_for_user(&state, &user, &vault, query, HistoryKind::Conflicts).await
}

async fn history_page_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    vault: &str,
    query: HistoryQuery,
    kind: HistoryKind,
) -> Result<Json<Value>, ApiError> {
    let snapshot_id = required_history_snapshot_id(query.snapshot_id.as_deref())?;
    let limit = parse_history_limit(query.limit.as_deref())?;
    let response = state
        .sync_repository
        .read_history_page(crate::sync_repository::HistoryPageCommand {
            user: user.clone(),
            vault_id: vault.to_owned(),
            snapshot_id: snapshot_id.to_owned(),
            kind,
            raw_cursor: query.cursor,
            limit,
            generation: state.instance.generation.clone(),
            cursor_key: *state.cursor_key,
        })
        .await?;
    Ok(Json(response))
}

/// Returns the append-only per-vault stream of conflict creation and first
/// successful resolution events. The high watermark and rows share one read
/// transaction, so pages are always a prefix of one coherent database view.
pub async fn conflict_changes(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Query(query): Query<ConflictChangesQuery>,
) -> Result<Json<Value>, ApiError> {
    let parsed = parse_conflict_changes_query(query)?;
    let user = current_sync_user(&state, &headers).await?;
    conflict_changes_for_user(&state, &user, &vault, parsed).await
}

async fn conflict_changes_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    vault: &str,
    parsed: ParsedConflictChangesQuery,
) -> Result<Json<Value>, ApiError> {
    let response = state
        .sync_repository
        .read_conflict_changes_page(crate::sync_repository::ConflictChangesPageCommand {
            user: user.clone(),
            vault_id: vault.to_owned(),
            after_seq: parsed.after_seq,
            after_seq_wire: parsed.after_seq_wire,
            limit: parsed.limit,
            server_generation: parsed.server_generation,
            generation: state.instance.generation.clone(),
            #[cfg(test)]
            test_pause: None,
        })
        .await?;
    Ok(Json(response))
}

/// Compacts a contiguous prefix of the ordered pull-event stream. Immutable
/// revisions, record heads, tombstones and the graveyard remain available for
/// snapshot rebuilds. The persisted sequence floor makes every cursor before
/// the retained prefix fail closed with CURSOR_EXPIRED.
pub async fn compact_expired_history(state: &AppState) -> Result<(), ApiError> {
    let now = Utc::now();
    crate::control::purge_due_vault_deletions(state, now.timestamp()).await?;
    crate::account::purge_due_account_deletions(state, now.timestamp()).await?;
    crate::presence::cleanup(state, now.timestamp()).await?;
    let now_text = now.to_rfc3339();
    let cutoff = (now - Duration::days(state.config.history_retention_days)).to_rfc3339();
    state
        .maintenance_repository
        .compact_history_events(cutoff)
        .await?;
    let now_epoch = now.timestamp();
    let audit_cutoff = now_epoch.saturating_sub(state.config.audit_retention_days * 86_400);
    state
        .maintenance_repository
        .compact_expired_payloads(crate::maintenance_repository::PayloadCleanupCommand {
            object_store: state.object_store.clone(),
            instance_id: state.instance.instance_id.clone(),
            now_text,
            now_epoch,
            audit_cutoff,
        })
        .await?;
    state
        .object_store
        .drain_delete_queue(&state.db, now_epoch, 100)
        .await?;
    crate::rate_limit::prune_expired(state, Utc::now().timestamp()).await?;
    Ok(())
}
pub async fn get_revision(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault, revision)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    get_revision_for_user(&state, &user, &vault, &revision).await
}

async fn get_revision_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    vault: &str,
    revision: &str,
) -> Result<Json<Value>, ApiError> {
    let response = state
        .sync_repository
        .read_revision(crate::sync_repository::ReadRevisionCommand {
            user: user.clone(),
            vault_id: vault.to_owned(),
            revision_id: revision.to_owned(),
        })
        .await?;
    Ok(Json(response))
}

#[derive(Deserialize)]
pub struct ConflictRequest {
    pub envelope: Envelope,
}

pub(crate) fn conflict_idempotency_retry(
    existing: Option<(String, String)>,
    request_digest: &str,
) -> Result<Option<String>, ApiError> {
    match existing {
        None => Ok(None),
        Some((conflict_id, stored_digest)) if stored_digest == request_digest => {
            Ok(Some(conflict_id))
        }
        Some(_) => Err(ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "conflict operation id was already used for different content",
        )),
    }
}

#[cfg(test)]
async fn conflict_idempotency_tx(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    vault: &str,
    device: &str,
    op_id: &str,
    request_digest: &str,
) -> Result<Option<String>, ApiError> {
    let existing = sqlx::query(
        "SELECT conflict_id,digest FROM conflicts WHERE vault_id=? AND device_id=? AND op_id=?",
    )
    .bind(vault)
    .bind(device)
    .bind(op_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .map(|row| {
        (
            row.get::<String, _>("conflict_id"),
            row.get::<String, _>("digest"),
        )
    });
    conflict_idempotency_retry(existing, request_digest)
}

pub async fn create_conflict(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Json(req): Json<ConflictRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    let env = &req.envelope;
    let did = id_field(&env.header, "device_id")?;
    if did != user.device_id {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "request device does not match session device",
        ));
    }
    let public = state
        .sync_repository
        .active_device_signing_key(user.user_id.clone(), did.clone())
        .await?
        .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
    let checked = verify_envelope(&state, &public, &vault, &did, env)?;
    let request_digest = sha256_hex(&jcs(env)?);
    let id = Uuid::new_v4().to_string();
    let text = serde_json::to_string(env).map_err(ApiError::internal)?;
    let response = state
        .sync_repository
        .create_conflict(crate::sync_repository::CreateConflictCommand {
            user,
            vault_id: vault,
            device_id: did,
            conflict_id: id,
            request_digest,
            envelope_json: text,
            operation: checked,
        })
        .await?;
    Ok(Json(response))
}
pub async fn resolve_conflict(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault, id)): Path<(String, String)>,
    Json(req): Json<ResolveConflict>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    let response = state
        .sync_repository
        .resolve_conflict(crate::sync_repository::ResolveConflictCommand {
            user,
            vault_id: vault,
            conflict_id: id,
            resolved_revision_id: req.resolved_revision_id,
        })
        .await?;
    Ok(Json(response))
}

#[cfg(test)]
mod tests {
    use super::{
        ChangesQuery, ConflictChangesQuery, Envelope, HistoryBounds, HistoryKind, HistoryQuery,
        HmacSha256, MAX_OBJECT_REFS, MAX_SYNC_CURSOR_BYTES, MAX_SYNC_PAGE_RESPONSE_BYTES,
        MAX_SYNC_SNAPSHOT_RESPONSE_BYTES, SYNC_PAGE_METADATA_RESERVE_BYTES,
        SYNC_SNAPSHOT_METADATA_RESERVE_BYTES, SnapshotQuery, SyncPageBudget, changes_for_user,
        compact_expired_history, conflict_changes_for_user, conflict_idempotency_retry,
        conflict_idempotency_tx, conflict_resolution_retry, create_snapshot, cursor_is_expired,
        ensure_sync_page_response_fits, foreign_generation_history_cursor_claim,
        get_revision_for_user, get_snapshot, get_snapshot_for_user, history_cursor,
        history_page_for_user, is_canonical_decimal_counter, parse_conflict_changes_query,
        parse_cursor, parse_history_cursor, parse_history_limit, parse_object_refs,
        persist_object_references_tx, push_inner, required_history_snapshot_id,
        sync_page_item_too_large, verify_envelope,
    };
    use crate::{Config, current_user, now_rfc3339, open_state};
    use axum::http::header::CONTENT_TYPE;
    use axum::{
        Json, Router,
        body::Body,
        extract::{Path, Query, State},
        http::{HeaderMap, Request, StatusCode, header::AUTHORIZATION},
        routing::{post, put},
    };
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
    use hmac::Mac;
    use serde_json::{Value, json};
    use sqlx::Row;
    use std::sync::Arc;
    use tower::ServiceExt;
    use uuid::Uuid;

    #[test]
    fn restore_deadline_equality_is_expired_and_purgeable() {
        let deadline = chrono::DateTime::parse_from_rfc3339("2026-10-12T12:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        assert!(!super::restore_deadline_elapsed(
            deadline - chrono::Duration::nanoseconds(1),
            deadline
        ));
        assert!(super::restore_deadline_elapsed(deadline, deadline));
        assert!(super::restore_deadline_elapsed(
            deadline + chrono::Duration::nanoseconds(1),
            deadline
        ));
    }

    fn encode_test_cursor(key: &[u8], vault_id: &str, generation: &str, seq: i64) -> String {
        let data = crate::jcs(&json!({
            "v": 1,
            "vault_id": vault_id,
            "seq": seq,
            "generation": generation,
        }))
        .unwrap();
        let mut mac = HmacSha256::new_from_slice(key).unwrap();
        mac.update(&data);
        URL_SAFE_NO_PAD.encode([data, mac.finalize().into_bytes().to_vec()].concat())
    }

    #[tokio::test]
    async fn foreign_generation_cursor_after_signing_key_rollback_requests_snapshot_only() {
        let (state, data_dir) = test_state("foreign-generation-cursor-rollback").await;
        let vault = Uuid::new_v4().to_string();
        let other_vault = Uuid::new_v4().to_string();
        let later_generation = Uuid::new_v4().to_string();
        let cursor_from_newer_signing_key =
            encode_test_cursor(&[0x5a; 32], &vault, &later_generation, 19);

        // After a physical backup restore, this MAC is from the newer
        // instance key and cannot be authenticated by the restored server.
        // Its strictly parsed generation claim can request recovery, but does
        // not authorize a cursor position or any database operation.
        let recovery = parse_cursor(&state, &vault, &cursor_from_newer_signing_key).unwrap_err();
        assert_eq!(recovery.status, StatusCode::GONE);
        assert_eq!(recovery.body.code, "CURSOR_EXPIRED");
        assert_eq!(
            recovery.body.details.unwrap(),
            json!({"recovery":"create_snapshot","preserve_local_outbox":true})
        );

        // A bad MAC claiming the current generation remains an invalid cursor.
        let same_generation_tampered =
            encode_test_cursor(&[0x5a; 32], &vault, &state.instance.generation, 19);
        let invalid = parse_cursor(&state, &vault, &same_generation_tampered).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        // A foreign-generation claim cannot cross Vault identity boundaries.
        let wrong_vault = encode_test_cursor(&[0x5a; 32], &other_vault, &later_generation, 19);
        let invalid = parse_cursor(&state, &vault, &wrong_vault).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        // A server-authenticated cursor from another Vault is a scope error,
        // not a snapshot-recovery signal for the requested Vault.
        let signed_wrong_vault = super::cursor(&state, &other_vault, 19).unwrap();
        let invalid = parse_cursor(&state, &vault, &signed_wrong_vault).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        let wrong_version_data = crate::jcs(&json!({
            "v": 2,
            "vault_id": vault,
            "seq": 19,
            "generation": state.instance.generation,
        }))
        .unwrap();
        let mut current_key_mac = HmacSha256::new_from_slice(state.cursor_key.as_ref()).unwrap();
        current_key_mac.update(&wrong_version_data);
        let signed_wrong_version = URL_SAFE_NO_PAD.encode(
            [
                wrong_version_data,
                current_key_mac.finalize().into_bytes().to_vec(),
            ]
            .concat(),
        );
        let invalid = parse_cursor(&state, &vault, &signed_wrong_version).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        // Non-canonical payloads do not enter the unauthenticated fallback.
        let noncanonical = format!(
            "{{\"seq\":19,\"v\":1,\"vault_id\":\"{vault}\",\"generation\":\"{later_generation}\"}}"
        );
        let mut mac = HmacSha256::new_from_slice(&[0x5a; 32]).unwrap();
        mac.update(noncanonical.as_bytes());
        let noncanonical = URL_SAFE_NO_PAD.encode(
            [
                noncanonical.as_bytes(),
                mac.finalize().into_bytes().as_slice(),
            ]
            .concat(),
        );
        let invalid = parse_cursor(&state, &vault, &noncanonical).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        let too_long = "A".repeat(MAX_SYNC_CURSOR_BYTES + 1);
        let invalid = parse_cursor(&state, &vault, &too_long).unwrap_err();
        assert_eq!(invalid.status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid.body.code, "INVALID_CURSOR");

        // Valid same-generation cursors still verify normally.
        let valid = super::cursor(&state, &vault, 3).unwrap();
        assert_eq!(parse_cursor(&state, &vault, &valid).unwrap(), 3);

        // Mutating only a current cursor's generation makes its bad-MAC 410
        // a recovery hint, not proof that the original cursor was genuine.
        let raw = URL_SAFE_NO_PAD.decode(valid).unwrap();
        let split = raw.len() - 32;
        let (data, tag) = raw.split_at(split);
        let mut payload: serde_json::Value = serde_json::from_slice(data).unwrap();
        payload["generation"] = json!(later_generation);
        let changed_generation_data = crate::jcs(&payload).unwrap();
        let changed_generation_claim =
            URL_SAFE_NO_PAD.encode([changed_generation_data, tag.to_vec()].concat());
        let hint = parse_cursor(&state, &vault, &changed_generation_claim).unwrap_err();
        assert_eq!(hint.status, StatusCode::GONE);
        assert_eq!(hint.body.code, "CURSOR_EXPIRED");

        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn sync_query_length_is_bounded_before_query_extraction() {
        let (state, data_dir) = test_state("sync-query-length-guard").await;
        let vault = Uuid::new_v4().to_string();
        let app = Router::new()
            .route(
                "/api/v1/vaults/{vault_id}/changes",
                axum::routing::get(super::changes)
                    .route_layer(axum::middleware::from_fn(super::guard_sync_query_length)),
            )
            .route(
                "/api/v1/vaults/{vault_id}/revisions",
                axum::routing::get(super::revision_history)
                    .route_layer(axum::middleware::from_fn(super::guard_sync_query_length)),
            )
            .route(
                "/api/v1/vaults/{vault_id}/conflicts",
                axum::routing::get(super::conflict_history)
                    .route_layer(axum::middleware::from_fn(super::guard_sync_query_length)),
            )
            .route(
                "/api/v1/vaults/{vault_id}/conflict-changes",
                axum::routing::get(super::conflict_changes)
                    .route_layer(axum::middleware::from_fn(super::guard_sync_query_length)),
            )
            .with_state(state.clone());

        let snapshot_id = Uuid::new_v4();
        let generation = Uuid::new_v4();
        let route_queries = [
            (
                "changes",
                format!(
                    "cursor={}&limit=500",
                    "A".repeat(super::MAX_SYNC_CURSOR_BYTES)
                ),
            ),
            (
                "revisions",
                format!("snapshot_id={snapshot_id}&limit=1&cursor="),
            ),
            (
                "conflicts",
                format!("snapshot_id={snapshot_id}&limit=1&cursor="),
            ),
            (
                "conflict-changes",
                format!("after_seq=0&server_generation={generation}&limit=1"),
            ),
        ];
        for (route, base_query) in route_queries {
            let pad_prefix = "&pad=";
            assert!(base_query.len() + pad_prefix.len() < super::MAX_SYNC_QUERY_BYTES);
            let exact_query = format!(
                "{base_query}{pad_prefix}{}",
                "x".repeat(super::MAX_SYNC_QUERY_BYTES - base_query.len() - pad_prefix.len())
            );
            assert_eq!(exact_query.len(), super::MAX_SYNC_QUERY_BYTES);
            let accepted_size = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(format!("/api/v1/vaults/{vault}/{route}?{exact_query}"))
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                accepted_size.status(),
                StatusCode::UNAUTHORIZED,
                "{route} must accept a {0}-byte query through the guard",
                super::MAX_SYNC_QUERY_BYTES
            );
            assert_eq!(
                response_json(accepted_size).await["error"]["code"],
                "AUTH_REQUIRED",
                "{route} did not proceed to the handler stage after the size check"
            );

            let oversized_query = format!("{exact_query}x");
            assert_eq!(oversized_query.len(), super::MAX_SYNC_QUERY_BYTES + 1);
            let rejected_size = app
                .clone()
                .oneshot(
                    Request::builder()
                        .uri(format!("/api/v1/vaults/{vault}/{route}?{oversized_query}"))
                        .body(Body::empty())
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                rejected_size.status(),
                StatusCode::BAD_REQUEST,
                "{route} must reject a {0}-byte query before extraction",
                super::MAX_SYNC_QUERY_BYTES + 1
            );
            assert_eq!(
                response_json(rejected_size).await["error"]["code"],
                "INVALID_CURSOR",
                "{route} did not use the fixed pre-extraction query error"
            );
        }

        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn old_reader_is_blocked_from_schema_two_envelopes() {
        let schema_one = json!({"header":{"record_schema":1}});
        let schema_two = json!({"header":{"record_schema":2}});
        assert!(super::ensure_envelope_readable(false, &schema_one).is_ok());
        let error = super::ensure_envelope_readable(false, &schema_two).unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");
        assert!(super::ensure_envelope_readable(true, &schema_two).is_ok());
    }

    #[test]
    fn serialized_sync_page_budget_keeps_a_prefix_and_reserves_wrapper_bytes() {
        assert_eq!(MAX_SYNC_PAGE_RESPONSE_BYTES, 4 * 1024 * 1024);
        let event_budget = MAX_SYNC_PAGE_RESPONSE_BYTES - SYNC_PAGE_METADATA_RESERVE_BYTES;
        let mut budget = SyncPageBudget::default();
        let first = json!({"seq":"1","payload":"small"});
        assert!(budget.try_add(&first).unwrap());
        let accepted_bytes = budget.event_bytes;
        let accepted_count = budget.event_count;

        // A rejected event leaves both counters untouched, so the page cursor
        // can remain at the last accepted sequence and the event is retried.
        let oversized = json!({
            "seq":"2",
            "payload":"x".repeat(MAX_SYNC_PAGE_RESPONSE_BYTES),
        });
        assert!(!budget.try_add(&oversized).unwrap());
        assert_eq!(budget.event_bytes, accepted_bytes);
        assert_eq!(budget.event_count, accepted_count);

        let empty_event = json!({"payload":""});
        let event_overhead = serde_json::to_vec(&empty_event).unwrap().len();
        let exact_budget_event = json!({"payload":"x".repeat(event_budget - event_overhead)});
        assert_eq!(
            serde_json::to_vec(&exact_budget_event).unwrap().len(),
            event_budget
        );
        let mut exact_budget = SyncPageBudget::default();
        assert!(exact_budget.try_add(&exact_budget_event).unwrap());

        let one_byte_over_budget_event = json!({
            "payload":"x".repeat(event_budget - event_overhead + 1),
        });
        let mut over_budget = SyncPageBudget::default();
        assert!(!over_budget.try_add(&one_byte_over_budget_event).unwrap());

        let first_event_too_large = json!({"seq":"1","payload":"x".repeat(event_budget)});
        let mut empty_budget = SyncPageBudget::default();
        assert!(!empty_budget.try_add(&first_event_too_large).unwrap());
        assert_eq!(empty_budget.event_count, 0);
        let too_large = sync_page_item_too_large();
        assert_eq!(too_large.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(too_large.body.code, "PAYLOAD_TOO_LARGE");
        assert_eq!(
            too_large.body.details.unwrap(),
            json!({
                "max_response_bytes": MAX_SYNC_PAGE_RESPONSE_BYTES,
                "recovery": "contact_server_operator",
            })
        );
    }

    #[test]
    fn exact_sync_response_guard_checks_the_complete_json_wrapper() {
        let response = json!({"events": [], "has_more": false});
        ensure_sync_page_response_fits(&response).unwrap();
        let empty_body = json!({"payload":""});
        let body_overhead = serde_json::to_vec(&empty_body).unwrap().len();
        let exact_limit =
            json!({"payload":"x".repeat(MAX_SYNC_PAGE_RESPONSE_BYTES - body_overhead)});
        assert_eq!(
            serde_json::to_vec(&exact_limit).unwrap().len(),
            MAX_SYNC_PAGE_RESPONSE_BYTES
        );
        ensure_sync_page_response_fits(&exact_limit).unwrap();

        let one_byte_over_limit = json!({
            "payload":"x".repeat(MAX_SYNC_PAGE_RESPONSE_BYTES - body_overhead + 1),
        });
        assert_eq!(
            serde_json::to_vec(&one_byte_over_limit).unwrap().len(),
            MAX_SYNC_PAGE_RESPONSE_BYTES + 1
        );
        assert!(ensure_sync_page_response_fits(&one_byte_over_limit).is_err());

        let too_large = json!({
            "events": ["x".repeat(MAX_SYNC_PAGE_RESPONSE_BYTES)],
            "has_more": false,
        });
        assert!(ensure_sync_page_response_fits(&too_large).is_err());
    }

    fn test_config(data_dir: std::path::PathBuf) -> Config {
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn test_state(label: &str) -> (crate::AppState, std::path::PathBuf) {
        let data_dir = std::env::temp_dir().join(format!("atermius-{label}-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        (state, data_dir)
    }

    #[tokio::test]
    async fn sqlite_restore_deadline_is_immutable_across_policy_changes_and_concurrent_writers() {
        let (state, data_dir) = test_state("sqlite-restore-deadline-immutable").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = Uuid::new_v4().to_string();
        let created_at = now_rfc3339();
        let token_hash = crate::sha256_hex(token.as_bytes());
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) \
             VALUES(?,?,'owner','active',?)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) \
             VALUES(?,?,'deadline-test','signing','encryption',?)",
        )
        .bind(&device_id)
        .bind(&user_id)
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) \
             VALUES(?,?,?,?,?,?,?,?,?)",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(&token_hash)
        .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
        .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
        .bind((chrono::Utc::now() + chrono::Duration::days(30)).to_rfc3339())
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id) VALUES(?)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        let user = crate::auth::AuthUser {
            user_id,
            device_id: device_id.clone(),
            session_id,
            access_hash: token_hash,
            declares_record_schema2: false,
            declares_sync_redaction_v1: false,
        };
        let make_operation =
            |record_id: &str,
             revision_id: &str,
             base: Option<&str>,
             operation: &str,
             sequence: &str| super::VerifiedOperation {
                record_id: record_id.to_owned(),
                revision_id: revision_id.to_owned(),
                op_id: Uuid::new_v4().to_string(),
                record_schema: 1,
                device_seq: sequence.to_owned(),
                key_epoch: 1,
                membership_version: 1,
                operation: operation.to_owned(),
                base: base.map(str::to_owned),
                object_refs: Vec::new(),
                env: Envelope {
                    header: json!({"record_schema":1}),
                    nonce: "n".to_owned(),
                    ciphertext: "ciphertext".to_owned(),
                    signature: "signature".to_owned(),
                },
            };
        let commit =
            |batch_id: &str, operation: super::VerifiedOperation, restore_retention_days: i64| {
                state
                    .sync_repository
                    .commit_batch(crate::sync_repository::PushCommit {
                        user: user.clone(),
                        vault_id: vault_id.clone(),
                        device_id: device_id.clone(),
                        batch_id: batch_id.to_owned(),
                        request_digest: format!("request-{batch_id}"),
                        operations: vec![operation],
                        restore_retention_days,
                    })
            };

        let restorable_record = Uuid::new_v4().to_string();
        let first_revision = Uuid::new_v4().to_string();
        let tombstone_revision = Uuid::new_v4().to_string();
        let restored_revision = Uuid::new_v4().to_string();
        commit(
            "deadline-create",
            make_operation(&restorable_record, &first_revision, None, "create", "1"),
            30,
        )
        .await
        .unwrap();
        commit(
            "deadline-delete",
            make_operation(
                &restorable_record,
                &tombstone_revision,
                Some(&first_revision),
                "delete",
                "2",
            ),
            30,
        )
        .await
        .unwrap();
        let (delete_created_at, stored_deadline): (String, Option<String>) = sqlx::query_as(
            "SELECT created_at,restore_until FROM record_versions \
             WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&restorable_record)
        .bind(&tombstone_revision)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let stored_deadline = chrono::DateTime::parse_from_rfc3339(
            stored_deadline
                .as_deref()
                .expect("delete deadline is stored"),
        )
        .unwrap()
        .with_timezone(&chrono::Utc);
        let expected_deadline = chrono::DateTime::parse_from_rfc3339(&delete_created_at)
            .unwrap()
            .with_timezone(&chrono::Utc)
            + chrono::Duration::days(30);
        assert_eq!(stored_deadline, expected_deadline);

        // Simulate a tombstone near the end of its original 30-day window.
        // The new one-day setting says this row would be expired under the
        // old created_at + current-policy calculation, but its stored deadline
        // remains one day in the future.
        let aged_delete_at = chrono::Utc::now() - chrono::Duration::days(29);
        let aged_restore_until = aged_delete_at + chrono::Duration::days(30);
        sqlx::query(
            "UPDATE record_versions SET created_at=?,restore_until=? \
             WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(aged_delete_at.to_rfc3339())
        .bind(aged_restore_until.to_rfc3339())
        .bind(&vault_id)
        .bind(&restorable_record)
        .bind(&tombstone_revision)
        .execute(&state.db)
        .await
        .unwrap();
        assert!(aged_delete_at + chrono::Duration::days(1) < chrono::Utc::now());
        assert!(chrono::Utc::now() < aged_restore_until);

        let snapshot = state
            .sync_repository
            .create_snapshot(crate::sync_repository::CreateSnapshotCommand {
                user: user.clone(),
                vault_id: vault_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        let history = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: snapshot["snapshot_id"].as_str().unwrap().to_owned(),
                kind: HistoryKind::Revisions,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        assert_eq!(
            history["revisions"][1]["restore_until"],
            aged_restore_until.to_rfc3339()
        );

        // A shorter setting after deletion must not shorten the already
        // advertised deadline. Restore and history use the same stored value.
        commit(
            "deadline-restore-shorter-policy",
            make_operation(
                &restorable_record,
                &restored_revision,
                Some(&tombstone_revision),
                "restore",
                "3",
            ),
            1,
        )
        .await
        .unwrap();

        let expired_record = Uuid::new_v4().to_string();
        let expired_live_revision = Uuid::new_v4().to_string();
        let expired_tombstone_revision = Uuid::new_v4().to_string();
        commit(
            "expired-deadline-create",
            make_operation(&expired_record, &expired_live_revision, None, "create", "4"),
            1,
        )
        .await
        .unwrap();
        commit(
            "expired-deadline-delete",
            make_operation(
                &expired_record,
                &expired_tombstone_revision,
                Some(&expired_live_revision),
                "delete",
                "5",
            ),
            1,
        )
        .await
        .unwrap();
        let past_deadline = (chrono::Utc::now() - chrono::Duration::seconds(1)).to_rfc3339();
        sqlx::query(
            "UPDATE record_versions SET restore_until=? WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&past_deadline)
        .bind(&vault_id)
        .bind(&expired_record)
        .bind(&expired_tombstone_revision)
        .execute(&state.db)
        .await
        .unwrap();
        let expired_restore = commit(
            "expired-deadline-restore-longer-policy",
            make_operation(
                &expired_record,
                &Uuid::new_v4().to_string(),
                Some(&expired_tombstone_revision),
                "restore",
                "6",
            ),
            3650,
        )
        .await
        .unwrap_err();
        assert_eq!(expired_restore.body.code, "RECORD_RESTORE_EXPIRED");
        assert_eq!(
            expired_restore.body.details.as_ref().unwrap()["restore_until"],
            past_deadline
        );
        assert_eq!(
            expired_restore.body.details.as_ref().unwrap()["restore_expires_at"],
            past_deadline
        );

        // Two concurrent restores with different current policy values still
        // serialize on the Vault writer fence; exactly one exact CAS wins.
        let concurrent_record = Uuid::new_v4().to_string();
        let concurrent_live_revision = Uuid::new_v4().to_string();
        let concurrent_tombstone_revision = Uuid::new_v4().to_string();
        commit(
            "concurrent-deadline-create",
            make_operation(
                &concurrent_record,
                &concurrent_live_revision,
                None,
                "create",
                "7",
            ),
            30,
        )
        .await
        .unwrap();
        commit(
            "concurrent-deadline-delete",
            make_operation(
                &concurrent_record,
                &concurrent_tombstone_revision,
                Some(&concurrent_live_revision),
                "delete",
                "8",
            ),
            30,
        )
        .await
        .unwrap();
        let first_restore = commit(
            "concurrent-restore-short-policy",
            make_operation(
                &concurrent_record,
                &Uuid::new_v4().to_string(),
                Some(&concurrent_tombstone_revision),
                "restore",
                "9",
            ),
            1,
        );
        let second_restore = commit(
            "concurrent-restore-long-policy",
            make_operation(
                &concurrent_record,
                &Uuid::new_v4().to_string(),
                Some(&concurrent_tombstone_revision),
                "restore",
                "10",
            ),
            3650,
        );
        let (first, second) = tokio::join!(first_restore, second_restore);
        assert_ne!(first.is_ok(), second.is_ok());
        let losing_restore = first.err().or_else(|| second.err()).unwrap();
        assert_eq!(losing_restore.body.code, "RECORD_TOMBSTONED");

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    async fn insert_user_and_vault(state: &crate::AppState, user: &str, vault: &str) {
        let created = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(user)
            .bind(format!("{user}@example.test"))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(vault)
            .bind(user)
            .bind(created)
            .execute(&state.db)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn reference_racing_external_gc_is_rejected_and_outbox_quarantines_inconsistent_ref() {
        let (mut state, data_dir) = test_state("object-s3-delete-reference-race").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let object = Uuid::new_v4().to_string();
        let upload = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;

        let fixture = crate::object_store::test_support::S3Fixture::start().await;
        let pause = Arc::new(crate::recovery::TestPause::new());
        let store = fixture.store_with_delete_pause(pause.clone());
        let (key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object, &upload)
            .unwrap();
        let bytes = b"race-safe external object";
        let digest = crate::sha256_hex(bytes);
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) \
             VALUES(?,?,X'',?,?,? ,?,'s3',?,?,'available')",
        )
        .bind(&vault)
        .bind(&object)
        .bind(bytes.len() as i64)
        .bind(&digest)
        .bind(now_rfc3339())
        .bind(chrono::Utc::now().timestamp() - 1)
        .bind(&key)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        state.object_store = store;

        let maintenance_state = state.clone();
        let maintenance =
            tokio::spawn(async move { compact_expired_history(&maintenance_state).await });
        pause.wait_until_reached().await;

        // The public sync helper takes the writer lock before checking state,
        // sees `deleting`, and never commits a new reference.
        let mut reference_tx = state.db.begin().await.unwrap();
        let result = persist_object_references_tx(
            &mut reference_tx,
            &vault,
            "race-revision",
            std::slice::from_ref(&object),
        )
        .await;
        assert_eq!(
            result.unwrap_err().body.code,
            "OBJECT_REFERENCE_UNAVAILABLE"
        );
        reference_tx.rollback().await.unwrap();

        // Simulate a legacy writer bypassing the availability check while
        // the provider DELETE has completed but catalogue finalization has
        // not. The worker must retain both row and tombstone in quarantine.
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault)
            .bind("legacy-racing-revision")
            .bind(&object)
            .execute(&state.db)
            .await
            .unwrap();
        pause.release();
        maintenance.await.unwrap().unwrap();

        let object_state: String = sqlx::query_scalar(
            "SELECT storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(object_state, "deleting");
        let queue_state: String = sqlx::query_scalar(
            "SELECT state FROM object_delete_queue WHERE storage_key=? AND storage_store_id=?",
        )
        .bind(&key)
        .bind(&store_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(queue_state, "quarantined");
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn reference_racing_filesystem_gc_is_rejected_and_outbox_quarantines_inconsistent_ref() {
        use std::os::unix::fs::PermissionsExt;

        let (mut state, data_dir) = test_state("object-filesystem-delete-reference-race").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let object = Uuid::new_v4().to_string();
        let upload = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;

        let object_root =
            std::env::temp_dir().join(format!("atermius-filesystem-race-{}", Uuid::new_v4()));
        std::fs::create_dir(&object_root).unwrap();
        std::fs::set_permissions(&object_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let pause = Arc::new(crate::recovery::TestPause::new());
        let store = crate::object_store::ObjectStore::filesystem_for_test_with_delete_pause(
            &object_root,
            pause.clone(),
        );
        let (key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object, &upload)
            .unwrap();
        let bytes = b"race-safe filesystem object";
        let digest = crate::sha256_hex(bytes);
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) \
             VALUES(?,?,X'',?,?,? ,?,'filesystem',?,?,'available')",
        )
        .bind(&vault)
        .bind(&object)
        .bind(bytes.len() as i64)
        .bind(&digest)
        .bind(now_rfc3339())
        .bind(chrono::Utc::now().timestamp() - 1)
        .bind(&key)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        state.object_store = store;

        let maintenance_state = state.clone();
        let maintenance =
            tokio::spawn(async move { compact_expired_history(&maintenance_state).await });
        pause.wait_until_reached().await;

        let mut reference_tx = state.db.begin().await.unwrap();
        let result = persist_object_references_tx(
            &mut reference_tx,
            &vault,
            "race-revision",
            std::slice::from_ref(&object),
        )
        .await;
        assert_eq!(
            result.unwrap_err().body.code,
            "OBJECT_REFERENCE_UNAVAILABLE"
        );
        reference_tx.rollback().await.unwrap();

        // Simulate a legacy writer bypassing the availability check after the
        // local unlink but before catalogue finalization; keep the outbox and
        // deleting catalogue row for operator repair.
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault)
            .bind("legacy-racing-revision")
            .bind(&object)
            .execute(&state.db)
            .await
            .unwrap();
        pause.release();
        maintenance.await.unwrap().unwrap();

        let object_state: String = sqlx::query_scalar(
            "SELECT storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(object_state, "deleting");
        let queue_state: String = sqlx::query_scalar(
            "SELECT state FROM object_delete_queue WHERE storage_key=? AND storage_store_id=?",
        )
        .bind(&key)
        .bind(&store_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(queue_state, "quarantined");
        let _ = std::fs::remove_dir_all(&object_root);
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn filesystem_delete_outbox_survives_transient_io_failure_and_retries() {
        use std::os::unix::fs::PermissionsExt;

        let (mut state, data_dir) = test_state("object-filesystem-delete-retry").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let object = Uuid::new_v4().to_string();
        let upload = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;

        let object_root =
            std::env::temp_dir().join(format!("atermius-filesystem-retry-{}", Uuid::new_v4()));
        std::fs::create_dir(&object_root).unwrap();
        std::fs::set_permissions(&object_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let store =
            crate::object_store::ObjectStore::filesystem_for_test_with_transient_delete_failure(
                &object_root,
            );
        let (key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object, &upload)
            .unwrap();
        let bytes = b"retryable filesystem object";
        let digest = crate::sha256_hex(bytes);
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) \
             VALUES(?,?,X'',?,?,? ,?,'filesystem',?,?,'available')",
        )
        .bind(&vault)
        .bind(&object)
        .bind(bytes.len() as i64)
        .bind(&digest)
        .bind(now_rfc3339())
        .bind(chrono::Utc::now().timestamp() - 1)
        .bind(&key)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        state.object_store = store;

        compact_expired_history(&state).await.unwrap();
        let retained: (String, String, i64) = sqlx::query_as(
            "SELECT b.storage_state,q.state,b.size FROM blob_objects b JOIN object_delete_queue q \
             ON q.storage_backend=b.storage_backend AND q.storage_key=b.storage_key AND q.storage_store_id=b.storage_store_id \
             WHERE b.vault_id=? AND b.object_id=?",
        )
        .bind(&vault)
        .bind(&object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            retained,
            (
                "deleting".to_owned(),
                "retry_wait".to_owned(),
                bytes.len() as i64
            )
        );

        sqlx::query("UPDATE object_delete_queue SET next_attempt_at=0 WHERE storage_key=?")
            .bind(&key)
            .execute(&state.db)
            .await
            .unwrap();
        state
            .object_store
            .drain_delete_queue(&state.db, chrono::Utc::now().timestamp(), 100)
            .await
            .unwrap();
        let remaining: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let queued: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_key=? AND storage_store_id=?",
        )
        .bind(&key)
        .bind(&store_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(remaining, 0);
        assert_eq!(queued, 0);
        assert!(!object_root.join(key).exists());

        let _ = std::fs::remove_dir_all(&object_root);
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn snapshot_manifest_contains_exact_committed_head_sequence() {
        let (state, data_dir) = test_state("snapshot-head-commit-seq").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = "a".repeat(64);
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user, &vault).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,12)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?, 'test','signing','encryption',?)")
            .bind(&device)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?, ?,?)")
            .bind(&session_id)
            .bind(&user)
            .bind(&device)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();

        let record_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,'{\"ciphertext\":true}','digest',7,?,'create',?)")
            .bind(&vault)
            .bind(&record_id)
            .bind(&revision_id)
            .bind(&device)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,7)")
            .bind(&vault)
            .bind(&record_id)
            .bind(&revision_id)
            .execute(&state.db)
            .await
            .unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        let created_snapshot =
            create_snapshot(State(state.clone()), headers.clone(), Path(vault.clone()))
                .await
                .unwrap()
                .0;
        let snapshot_id = created_snapshot["snapshot_id"].as_str().unwrap();
        let snapshot = get_snapshot(
            State(state.clone()),
            headers.clone(),
            Path(snapshot_id.to_owned()),
            Query(SnapshotQuery {
                limit: None,
                page_cursor: None,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(snapshot["high_watermark"], "12");
        assert_eq!(snapshot["manifest"][0]["record_id"], record_id);
        assert_eq!(snapshot["manifest"][0]["revision_id"], revision_id);
        assert_eq!(snapshot["manifest"][0]["commit_seq"], "7");

        // A multi-item manifest above the legacy full-response bound remains
        // bootstrappable through independently bounded, immutable pages.
        let page_envelope = json!({
            "ciphertext": "x".repeat(
                MAX_SYNC_SNAPSHOT_RESPONSE_BYTES / 2 + SYNC_SNAPSHOT_METADATA_RESERVE_BYTES,
            ),
        })
        .to_string();
        for (record_id, revision_id, sequence) in [
            ("large-page-a", "large-page-rev-a", 8i64),
            ("large-page-b", "large-page-rev-b", 10i64),
        ] {
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,?,?,?,?,'create',?)")
                .bind(&vault)
                .bind(record_id)
                .bind(revision_id)
                .bind(&page_envelope)
                .bind(crate::sha256_hex(page_envelope.as_bytes()))
                .bind(sequence)
                .bind(&device)
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,?)")
                .bind(&vault)
                .bind(record_id)
                .bind(revision_id)
                .bind(sequence)
                .execute(&state.db)
                .await
                .unwrap();
        }
        let paged_snapshot =
            create_snapshot(State(state.clone()), headers.clone(), Path(vault.clone()))
                .await
                .unwrap()
                .0;
        let paged_snapshot_id = paged_snapshot["snapshot_id"].as_str().unwrap();
        let stored_item_count: i64 =
            sqlx::query_scalar("SELECT snapshot_item_count FROM snapshots WHERE snapshot_id=?")
                .bind(paged_snapshot_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(stored_item_count, 3);
        let full_read = get_snapshot(
            State(state.clone()),
            headers.clone(),
            Path(paged_snapshot_id.to_owned()),
            Query(SnapshotQuery {
                limit: None,
                page_cursor: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(full_read.status, StatusCode::PAYLOAD_TOO_LARGE);

        let mut page_cursor = None;
        let mut paged_records = Vec::new();
        for page_index in 0..3 {
            let page = get_snapshot(
                State(state.clone()),
                headers.clone(),
                Path(paged_snapshot_id.to_owned()),
                Query(SnapshotQuery {
                    limit: Some("1".to_owned()),
                    page_cursor: page_cursor.clone(),
                }),
            )
            .await
            .unwrap()
            .0;
            let body_bytes = serde_json::to_vec(&page).unwrap().len();
            assert!(body_bytes <= MAX_SYNC_SNAPSHOT_RESPONSE_BYTES);
            assert_eq!(
                page["server_generation"].as_str(),
                Some(state.instance.generation.as_str())
            );
            assert_eq!(page["manifest"].as_array().unwrap().len(), 1);
            paged_records.push(
                page["manifest"][0]["record_id"]
                    .as_str()
                    .unwrap()
                    .to_owned(),
            );
            let has_more = page["has_more"].as_bool().unwrap();
            assert_eq!(has_more, page_index < 2);
            let next_page_cursor = page["next_page_cursor"].as_str().map(str::to_owned);
            if page_index == 0 {
                let token = next_page_cursor.as_deref().unwrap();
                let tampered = get_snapshot(
                    State(state.clone()),
                    headers.clone(),
                    Path(paged_snapshot_id.to_owned()),
                    Query(SnapshotQuery {
                        limit: Some("1".to_owned()),
                        page_cursor: Some(format!("{token}x")),
                    }),
                )
                .await
                .unwrap_err();
                assert_eq!(tampered.body.code, "INVALID_CURSOR");
                let wrong_snapshot = get_snapshot(
                    State(state.clone()),
                    headers.clone(),
                    Path(snapshot_id.to_owned()),
                    Query(SnapshotQuery {
                        limit: Some("1".to_owned()),
                        page_cursor: Some(token.to_owned()),
                    }),
                )
                .await
                .unwrap_err();
                assert_eq!(wrong_snapshot.body.code, "INVALID_CURSOR");
            }
            page_cursor = next_page_cursor;
            if has_more {
                assert!(page_cursor.is_some());
            } else {
                assert_eq!(page["next_page_cursor"], Value::Null);
            }
        }
        assert_eq!(paged_records.len(), 3);
        assert_ne!(paged_records[0], paged_records[1]);
        assert_ne!(paged_records[1], paged_records[2]);
        assert_ne!(paged_records[0], paged_records[2]);

        // Paged reads trust the immutable snapshot count until the terminal
        // page, then perform one integrity check rather than rescanning all
        // items on every page. A corrupt item set must therefore fail closed
        // before the client can complete its traversal.
        sqlx::query(
            "DELETE FROM snapshot_items WHERE snapshot_id=? AND record_id=(\
                SELECT MAX(record_id) FROM snapshot_items WHERE snapshot_id=?\
            )",
        )
        .bind(paged_snapshot_id)
        .bind(paged_snapshot_id)
        .execute(&state.db)
        .await
        .unwrap();
        let integrity_first = get_snapshot(
            State(state.clone()),
            headers.clone(),
            Path(paged_snapshot_id.to_owned()),
            Query(SnapshotQuery {
                limit: Some("1".to_owned()),
                page_cursor: None,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(integrity_first["item_count"], 3);
        assert_eq!(integrity_first["has_more"], true);
        let integrity_terminal = get_snapshot(
            State(state.clone()),
            headers.clone(),
            Path(paged_snapshot_id.to_owned()),
            Query(SnapshotQuery {
                limit: Some("1".to_owned()),
                page_cursor: Some(
                    integrity_first["next_page_cursor"]
                        .as_str()
                        .unwrap()
                        .to_owned(),
                ),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(integrity_terminal.status, StatusCode::INTERNAL_SERVER_ERROR);

        // Snapshot reads retain the full-manifest API, with a hard serialized
        // response cap. A single oversized item cannot fit even one page.
        let large_record_id = Uuid::new_v4().to_string();
        let large_revision_id = Uuid::new_v4().to_string();
        let large_envelope = json!({
            "ciphertext": "x".repeat(MAX_SYNC_SNAPSHOT_RESPONSE_BYTES),
        })
        .to_string();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,?,?,9,?,'create',?)")
            .bind(&vault)
            .bind(&large_record_id)
            .bind(&large_revision_id)
            .bind(&large_envelope)
            .bind(crate::sha256_hex(large_envelope.as_bytes()))
            .bind(&device)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,9)")
            .bind(&vault)
            .bind(&large_record_id)
            .bind(&large_revision_id)
            .execute(&state.db)
            .await
            .unwrap();
        let oversized_snapshot =
            create_snapshot(State(state.clone()), headers.clone(), Path(vault.clone()))
                .await
                .unwrap_err();
        assert_eq!(oversized_snapshot.status, StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(oversized_snapshot.body.code, "PAYLOAD_TOO_LARGE");
        assert_eq!(
            oversized_snapshot.body.details.as_ref().unwrap()["max_response_bytes"],
            MAX_SYNC_SNAPSHOT_RESPONSE_BYTES
        );
        assert_eq!(
            oversized_snapshot.body.details.as_ref().unwrap()["recovery"],
            "contact_server_operator"
        );
        let snapshot_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM snapshots WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(snapshot_count, 2, "oversized snapshot is not persisted");
        let oversized_stored_item = json!({
            "kind": "head",
            "record_id": record_id,
            "revision_id": revision_id,
            "commit_seq": "7",
            "deleted": false,
            "envelope": {"ciphertext": "x".repeat(MAX_SYNC_SNAPSHOT_RESPONSE_BYTES)},
        })
        .to_string();
        sqlx::query("UPDATE snapshot_items SET item_json=? WHERE snapshot_id=? AND record_id=?")
            .bind(oversized_stored_item)
            .bind(snapshot_id)
            .bind(&record_id)
            .execute(&state.db)
            .await
            .unwrap();
        let oversized_snapshot_read = get_snapshot(
            State(state.clone()),
            headers.clone(),
            Path(snapshot_id.to_owned()),
            Query(SnapshotQuery {
                limit: None,
                page_cursor: None,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(
            oversized_snapshot_read.status,
            StatusCode::PAYLOAD_TOO_LARGE
        );
        sqlx::query("UPDATE snapshots SET expires_at=? WHERE snapshot_id=?")
            .bind("2000-01-01T00:00:00Z")
            .bind(paged_snapshot_id)
            .execute(&state.db)
            .await
            .unwrap();
        compact_expired_history(&state).await.unwrap();
        let retained_snapshot: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM snapshots WHERE snapshot_id=?")
                .bind(paged_snapshot_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let retained_items: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=?")
                .bind(paged_snapshot_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(retained_snapshot, 1, "expired metadata stays for 410");
        assert_eq!(retained_items, 0, "expiry removes stored encrypted pages");
        sqlx::query("DELETE FROM record_heads WHERE vault_id=? AND record_id=?")
            .bind(&vault)
            .bind(&large_record_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("DELETE FROM record_versions WHERE vault_id=? AND record_id=?")
            .bind(&vault)
            .bind(&large_record_id)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("UPDATE record_heads SET commit_seq=8 WHERE vault_id=? AND record_id=?")
            .bind(&vault)
            .bind(&record_id)
            .execute(&state.db)
            .await
            .unwrap();
        let error = create_snapshot(State(state.clone()), headers.clone(), Path(vault.clone()))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(error.body.code, "INTERNAL");

        sqlx::query("UPDATE record_versions SET commit_seq=0 WHERE vault_id=? AND record_id=?")
            .bind(&vault)
            .bind(&record_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE record_heads SET commit_seq=0 WHERE vault_id=? AND record_id=?")
            .bind(&vault)
            .bind(&record_id)
            .execute(&state.db)
            .await
            .unwrap();
        let error = create_snapshot(State(state.clone()), headers, Path(vault))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(error.body.code, "INTERNAL");

        state.db.close().await;
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn revoked_preflight_session_cannot_enter_sync_writer_transaction() {
        let (state, data_dir) = test_state("revoked-preflight-write").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let writer_device_id = Uuid::new_v4().to_string();
        let revoker_device_id = Uuid::new_v4().to_string();
        let writer_session_id = Uuid::new_v4().to_string();
        let revoker_session_id = Uuid::new_v4().to_string();
        let writer_token = "w".repeat(64);
        let revoker_token = "r".repeat(64);
        let writer_refresh_token = format!("refresh-{}", Uuid::new_v4());
        let revoker_refresh_token = format!("refresh-{}", Uuid::new_v4());
        let created = now_rfc3339();

        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,0)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        let snapshot_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation,conflict_high_watermark) VALUES(?,?,?,0,?,?,?, ?,0)")
            .bind(&snapshot_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind(r#"[{"record_id":"protected","envelope":{"ciphertext":"snapshot-secret"}}]"#)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(r#"INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,'{"ciphertext":"revision-secret"}','digest',1,?,'create',?)"#)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&revision_id)
            .bind(&writer_device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'6f626a6563742d736563726574',13,'object-digest',?,NULL)")
            .bind(&vault_id)
            .bind(&object_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(&revision_id)
            .bind(&object_id)
            .execute(&state.db)
            .await
            .unwrap();
        for (device_id, name) in [
            (&writer_device_id, "writer"),
            (&revoker_device_id, "revoker"),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
                .bind(device_id)
                .bind(&user_id)
                .bind(name)
                .bind("test-signing-key")
                .bind("test-encryption-key")
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }
        for (device_id, session_id, token, refresh_token) in [
            (
                &writer_device_id,
                &writer_session_id,
                &writer_token,
                &writer_refresh_token,
            ),
            (
                &revoker_device_id,
                &revoker_session_id,
                &revoker_token,
                &revoker_refresh_token,
            ),
        ] {
            sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
                .bind(session_id)
                .bind(&user_id)
                .bind(device_id)
                .bind(Uuid::new_v4().to_string())
                .bind(crate::sha256_hex(token.as_bytes()))
                .bind(crate::sha256_hex(refresh_token.as_bytes()))
                .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
                .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }

        sqlx::query("UPDATE vault_counters SET last_committed_seq=1,last_conflict_seq=1,minimum_available_seq=0 WHERE vault_id=?")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope) VALUES(?,1,'create',?,?,?)")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&revision_id)
            .bind(r#"{"ciphertext":"changes-secret"}"#)
            .execute(&state.db)
            .await
            .unwrap();
        let conflict_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,resolved_revision_id,conflict_seq) VALUES(?,?,?,NULL,?,'digest',?,?,NULL,1)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(r#"{"ciphertext":"conflict-secret"}"#)
            .bind(&writer_device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();

        let authorization = |token: &str| {
            let mut headers = HeaderMap::new();
            headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
            headers
        };
        let writer_headers = authorization(&writer_token);
        // Model a request that passed its ordinary bearer, membership and
        // device preflight, then paused before acquiring its mutation lock.
        let writer = crate::auth::authenticate(&state, &writer_headers)
            .await
            .unwrap();
        crate::require_vault(&state, &user_id, &vault_id, true)
            .await
            .unwrap();
        crate::ensure_active_device(&state, &user_id, &writer_device_id)
            .await
            .unwrap();
        let before = sync_write_state(&state, &vault_id).await;

        let changes = changes_for_user(
            &state,
            &writer,
            &vault_id,
            ChangesQuery {
                cursor: None,
                limit: Some(500),
            },
        )
        .await
        .unwrap()
        .0;
        assert_eq!(
            changes["events"][0]["envelope"]["ciphertext"],
            "changes-secret"
        );
        let conflict_query = parse_conflict_changes_query(ConflictChangesQuery {
            after_seq: None,
            limit: None,
            server_generation: None,
        })
        .unwrap();
        let conflict_changes =
            conflict_changes_for_user(&state, &writer, &vault_id, conflict_query)
                .await
                .unwrap()
                .0;
        assert_eq!(
            conflict_changes["events"][0]["envelope"]["ciphertext"],
            "conflict-secret"
        );

        let snapshot = get_snapshot_for_user(
            &state,
            &writer,
            &snapshot_id,
            SnapshotQuery {
                limit: None,
                page_cursor: None,
            },
        )
        .await
        .unwrap()
        .0;
        assert_eq!(
            snapshot["manifest"][0]["envelope"]["ciphertext"],
            "snapshot-secret"
        );
        let revision = get_revision_for_user(&state, &writer, &vault_id, &revision_id)
            .await
            .unwrap()
            .0;
        assert_eq!(revision["envelope"]["ciphertext"], "revision-secret");
        let object_response = crate::objects::get_object_for_user(
            &state,
            &writer,
            &vault_id,
            &object_id,
            &HeaderMap::new(),
        )
        .await
        .unwrap();
        assert_eq!(object_response.status(), StatusCode::OK);

        // A refresh request can preserve session_id while replacing only the
        // bearer hash. The preflight principal must be bound to the old hash.
        let refresh_result = crate::auth::refresh(
            State(state.clone()),
            axum::Json(crate::auth::RefreshRequest {
                refresh_token: writer_refresh_token,
            }),
        )
        .await
        .unwrap();
        let axum::Json(refresh_response) = refresh_result;
        let mut stale_write_tx = state.db.begin().await.unwrap();
        let stale_error =
            crate::require_authenticated_vault_write_tx(&mut stale_write_tx, &writer, &vault_id)
                .await
                .unwrap_err();
        assert_eq!(stale_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(stale_error.body.code, "AUTH_REQUIRED");
        drop(stale_write_tx);
        let mut stale_read_tx = state.db.begin().await.unwrap();
        let stale_read_error =
            crate::require_active_session_device_read_tx(&mut stale_read_tx, &writer)
                .await
                .unwrap_err();
        assert_eq!(stale_read_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(stale_read_error.body.code, "AUTH_REQUIRED");
        drop(stale_read_tx);
        assert_eq!(sync_write_state(&state, &vault_id).await, before);

        let refreshed_token = refresh_response["access_token"].as_str().unwrap();
        let refreshed_headers = authorization(refreshed_token);
        let refreshed_writer = crate::auth::authenticate(&state, &refreshed_headers)
            .await
            .unwrap();
        crate::require_vault(&state, &user_id, &vault_id, true)
            .await
            .unwrap();
        crate::ensure_active_device(&state, &user_id, &writer_device_id)
            .await
            .unwrap();

        // Commit the real device-revoke handler while the previously
        // authenticated writer is paused outside its transaction.
        let revoked = crate::auth::revoke_device(
            State(state.clone()),
            authorization(&revoker_token),
            Path(writer_device_id.clone()),
        )
        .await;
        assert!(revoked.is_ok());

        // Resume the paused write at the transaction authorization gate.
        let mut write_tx = state.db.begin().await.unwrap();
        let error = crate::require_authenticated_vault_write_tx(
            &mut write_tx,
            &refreshed_writer,
            &vault_id,
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(error.body.code, "AUTH_REQUIRED");
        drop(write_tx);

        let after = sync_write_state(&state, &vault_id).await;
        assert_eq!(after, before);
        assert_eq!(after, (0, 0, 0, 1, 0, 1, 1));
        let revoked_device: String =
            sqlx::query_scalar("SELECT status FROM devices WHERE device_id=?")
                .bind(&writer_device_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(revoked_device, "revoked");

        // Both history list endpoints share this authorization boundary before
        // reading revision or conflict envelopes.
        let history_error = history_page_for_user(
            &state,
            &refreshed_writer,
            &vault_id,
            HistoryQuery {
                snapshot_id: Some(snapshot_id.clone()),
                cursor: None,
                limit: None,
            },
            HistoryKind::Revisions,
        )
        .await
        .unwrap_err();
        assert_eq!(history_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(history_error.body.code, "AUTH_REQUIRED");

        let parsed_conflict_query = parse_conflict_changes_query(ConflictChangesQuery {
            after_seq: None,
            limit: None,
            server_generation: None,
        })
        .unwrap();
        let conflict_error =
            conflict_changes_for_user(&state, &refreshed_writer, &vault_id, parsed_conflict_query)
                .await
                .unwrap_err();
        assert_eq!(conflict_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(conflict_error.body.code, "AUTH_REQUIRED");
        assert!(
            !serde_json::to_string(&conflict_error.body)
                .unwrap()
                .contains("conflict-secret")
        );

        let changes_error = changes_for_user(
            &state,
            &refreshed_writer,
            &vault_id,
            ChangesQuery {
                cursor: None,
                limit: Some(500),
            },
        )
        .await
        .unwrap_err();
        assert_eq!(changes_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(changes_error.body.code, "AUTH_REQUIRED");
        assert!(
            !serde_json::to_string(&changes_error.body)
                .unwrap()
                .contains("changes-secret")
        );

        // Exercise the post-authentication handler bodies with the principal
        // captured before revocation. These assertions prove the manifest,
        // revision envelope and object bytes are never returned after the
        // revocation transaction commits.
        let snapshot_error = get_snapshot_for_user(
            &state,
            &refreshed_writer,
            &snapshot_id,
            SnapshotQuery {
                limit: None,
                page_cursor: None,
            },
        )
        .await
        .unwrap_err();
        assert_eq!(snapshot_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(snapshot_error.body.code, "AUTH_REQUIRED");
        let snapshot_error_body = serde_json::to_string(&snapshot_error.body).unwrap();
        assert!(!snapshot_error_body.contains("snapshot-secret"));
        let revision_error =
            get_revision_for_user(&state, &refreshed_writer, &vault_id, &revision_id)
                .await
                .unwrap_err();
        assert_eq!(revision_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(revision_error.body.code, "AUTH_REQUIRED");
        let revision_error_body = serde_json::to_string(&revision_error.body).unwrap();
        assert!(!revision_error_body.contains("revision-secret"));
        let object_error = crate::objects::get_object_for_user(
            &state,
            &refreshed_writer,
            &vault_id,
            &object_id,
            &HeaderMap::new(),
        )
        .await
        .unwrap_err();
        assert_eq!(object_error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(object_error.body.code, "AUTH_REQUIRED");
        let object_error_body = serde_json::to_string(&object_error.body).unwrap();
        assert!(!object_error_body.contains("object-secret"));

        state.db.close().await;
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn real_push_route_rejects_preflight_credentials_refreshed_and_revoked_before_writer_reservation()
     {
        let (state, data_dir) = test_state("route-push-refresh-revoke-race").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let writer_device_id = Uuid::new_v4().to_string();
        let revoker_device_id = Uuid::new_v4().to_string();
        let writer_session_id = Uuid::new_v4().to_string();
        let revoker_session_id = Uuid::new_v4().to_string();
        let writer_token = format!("writer-{}", Uuid::new_v4());
        let writer_refresh_token = format!("writer-refresh-{}", Uuid::new_v4());
        let revoker_token = format!("revoker-{}", Uuid::new_v4());
        let revoker_refresh_token = format!("revoker-refresh-{}", Uuid::new_v4());
        let writer_key = SigningKey::from_bytes(&[37_u8; 32]);
        let revoker_key = SigningKey::from_bytes(&[38_u8; 32]);
        let created = now_rfc3339();

        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,1)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        for (device_id, name, key) in [
            (&writer_device_id, "writer", &writer_key),
            (&revoker_device_id, "revoker", &revoker_key),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
                .bind(device_id)
                .bind(&user_id)
                .bind(name)
                .bind(URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()))
                .bind(URL_SAFE_NO_PAD.encode([41_u8; 32]))
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }

        let access_expires = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        let refresh_expires = (chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339();
        for (device_id, session_id, token, refresh_token) in [
            (
                &writer_device_id,
                &writer_session_id,
                &writer_token,
                &writer_refresh_token,
            ),
            (
                &revoker_device_id,
                &revoker_session_id,
                &revoker_token,
                &revoker_refresh_token,
            ),
        ] {
            sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
                .bind(session_id)
                .bind(&user_id)
                .bind(device_id)
                .bind(Uuid::new_v4().to_string())
                .bind(crate::sha256_hex(token.as_bytes()))
                .bind(crate::sha256_hex(refresh_token.as_bytes()))
                .bind(&access_expires)
                .bind(&refresh_expires)
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }

        // Keep non-empty conflict and upload state in the baseline so the
        // denied route proves their counters and reservations stay untouched.
        let conflict_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,resolved_revision_id,conflict_seq) VALUES(?,?,?,NULL,'{\"ciphertext\":\"existing-conflict\"}','digest',?,?,NULL,1)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&writer_device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        let upload_id = Uuid::new_v4().to_string();
        let upload_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,3,'expected-hash',1048576,'open',?,?)")
            .bind(&upload_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&upload_object_id)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'010203','chunk-hash')")
            .bind(&upload_id)
            .execute(&state.db)
            .await
            .unwrap();

        let baseline = sync_write_state_for_route(&state, &vault_id).await;
        let refresh_gate = Arc::new(crate::recovery::TestPause::new());
        let _release_refresh_on_drop =
            crate::recovery::ReleasePauseOnDrop::new(refresh_gate.clone());
        let refresh_app = push_test_router(state.clone(), refresh_gate.clone());
        let refresh_race_request = json_post_request(
            &format!("/api/v1/vaults/{vault_id}/sync/push"),
            Some(&writer_token),
            signed_create_push(&state, &vault_id, &writer_device_id, &writer_key),
        );
        let refresh_race_app = refresh_app.clone();
        let refresh_race = tokio::spawn(async move {
            refresh_race_app
                .oneshot(refresh_race_request)
                .await
                .unwrap()
        });
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            refresh_gate.wait_until_reached(),
        )
        .await
        .expect("push route did not reach its post-preflight pause");

        // First prove rotation alone invalidates the bearer already captured
        // by the real push route.
        let refreshed = refresh_app
            .clone()
            .oneshot(json_post_request(
                "/api/v1/auth/refresh",
                None,
                json!({"refresh_token":writer_refresh_token}),
            ))
            .await
            .unwrap();
        assert_eq!(refreshed.status(), StatusCode::OK);
        let refreshed_body = response_json(refreshed).await;
        let refreshed_token = refreshed_body["access_token"]
            .as_str()
            .expect("refresh returned an access token")
            .to_owned();
        let rotated_hash: String =
            sqlx::query_scalar("SELECT access_hash FROM sessions WHERE session_id=? AND user_id=?")
                .bind(&writer_session_id)
                .bind(&user_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(rotated_hash, crate::sha256_hex(refreshed_token.as_bytes()));
        assert_ne!(rotated_hash, crate::sha256_hex(writer_token.as_bytes()));
        refresh_gate.release();
        let denied_after_refresh = refresh_race.await.unwrap();
        assert_eq!(denied_after_refresh.status(), StatusCode::UNAUTHORIZED);
        let denied_refresh_body = response_json(denied_after_refresh).await;
        assert_eq!(denied_refresh_body["error"]["code"], "AUTH_REQUIRED");
        assert_eq!(
            sync_write_state_for_route(&state, &vault_id).await,
            baseline
        );
        drop(refresh_app);

        // A second real push passes preflight using the rotated bearer. Device
        // revocation alone then invalidates it before the writer reservation.
        let revoke_gate = Arc::new(crate::recovery::TestPause::new());
        let _release_revoke_on_drop = crate::recovery::ReleasePauseOnDrop::new(revoke_gate.clone());
        let revoke_app = push_test_router(state.clone(), revoke_gate.clone());
        let revoke_race_request = json_post_request(
            &format!("/api/v1/vaults/{vault_id}/sync/push"),
            Some(&refreshed_token),
            signed_create_push(&state, &vault_id, &writer_device_id, &writer_key),
        );
        let revoke_race_app = revoke_app.clone();
        let revoke_race =
            tokio::spawn(
                async move { revoke_race_app.oneshot(revoke_race_request).await.unwrap() },
            );
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            revoke_gate.wait_until_reached(),
        )
        .await
        .expect("refreshed push did not reach its post-preflight pause");

        let revoke = revoke_app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/devices/{writer_device_id}/revoke"),
                Some(&revoker_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(revoke.status(), StatusCode::OK);
        let revoke_body = response_json(revoke).await;
        assert_eq!(revoke_body["status"], "revoked");
        let writer_device_status: String =
            sqlx::query_scalar("SELECT status FROM devices WHERE device_id=?")
                .bind(&writer_device_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(writer_device_status, "revoked");

        revoke_gate.release();
        let denied_push = revoke_race.await.unwrap();
        assert_eq!(denied_push.status(), StatusCode::UNAUTHORIZED);
        let denied_body = response_json(denied_push).await;
        assert_eq!(denied_body["error"]["code"], "AUTH_REQUIRED");
        assert_eq!(
            sync_write_state_for_route(&state, &vault_id).await,
            baseline
        );

        drop(revoke_app);
        state.db.close().await;
        let _ = std::fs::remove_dir_all(data_dir);
    }

    fn push_test_router(state: crate::AppState, gate: Arc<crate::recovery::TestPause>) -> Router {
        Router::new()
            .route(
                "/api/v1/vaults/{vault_id}/sync/push",
                post(
                    move |State(state): State<crate::AppState>,
                          headers: HeaderMap,
                          Path(vault): Path<String>,
                          Json(request): Json<super::PushRequest>| {
                        let gate = gate.clone();
                        async move { push_inner(state, headers, vault, request, Some(gate)).await }
                    },
                ),
            )
            .route("/api/v1/auth/refresh", post(crate::auth::refresh))
            .route(
                "/api/v1/devices/{id}/revoke",
                post(crate::auth::revoke_device),
            )
            .with_state(state)
    }

    fn signed_create_push(
        state: &crate::AppState,
        vault_id: &str,
        device_id: &str,
        signing_key: &SigningKey,
    ) -> serde_json::Value {
        signed_create_push_with_seq(state, vault_id, device_id, signing_key, "1")
    }

    fn signed_create_push_with_seq(
        state: &crate::AppState,
        vault_id: &str,
        device_id: &str,
        signing_key: &SigningKey,
        device_seq: &str,
    ) -> serde_json::Value {
        let header = json!({
            "wire_version": 1,
            "record_schema": 1,
            "vault_id": vault_id,
            "device_id": device_id,
            "server_space_id": state.instance.server_space_id,
            "crypto_suite": "atermius-vault-v1",
            "record_id": Uuid::new_v4().to_string(),
            "revision_id": Uuid::new_v4().to_string(),
            "op_id": Uuid::new_v4().to_string(),
            "device_seq": device_seq,
            "key_epoch": "1",
            "membership_version": "1",
            "operation": "create",
            "kdf_salt": URL_SAFE_NO_PAD.encode([42_u8; 32]),
        });
        let nonce = URL_SAFE_NO_PAD.encode([43_u8; 24]);
        let ciphertext = URL_SAFE_NO_PAD.encode([44_u8; 32]);
        let unsigned = json!({"header":header,"nonce":nonce,"ciphertext":ciphertext});
        let signature = signing_key.sign(&crate::jcs(&unsigned).unwrap());
        let mut envelope = unsigned;
        envelope["signature"] = json!(URL_SAFE_NO_PAD.encode(signature.to_bytes()));
        json!({
            "protocol_version": 1,
            "server_generation": state.instance.generation,
            "vault_id": vault_id,
            "device_id": device_id,
            "batch_id": Uuid::new_v4().to_string(),
            "operations": [envelope],
        })
    }

    fn flip_first_base64url(value: &str) -> String {
        let mut bytes = URL_SAFE_NO_PAD.decode(value).unwrap();
        bytes[0] ^= 1;
        URL_SAFE_NO_PAD.encode(bytes)
    }

    #[tokio::test]
    async fn shared_sync_vector_is_accepted_opaque_and_rejected_when_tampered() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../protocol/sync-fixtures/record-envelope-v1.json"
        ))
        .unwrap();
        let context = &fixture["context"];
        let vault_id = context["vault_id"].as_str().unwrap().to_owned();
        let device_id = context["device_id"].as_str().unwrap().to_owned();
        let server_space_id = context["server_space_id"].as_str().unwrap();
        let envelope_json = fixture["envelope"].clone();
        let seed: [u8; 32] = URL_SAFE_NO_PAD
            .decode(
                fixture["test_only"]["signing_seed_base64url"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap()
            .try_into()
            .unwrap();
        let signing_key = SigningKey::from_bytes(&seed);
        let public = URL_SAFE_NO_PAD.encode(signing_key.verifying_key().to_bytes());
        assert_eq!(
            public,
            fixture["test_only"]["signing_public_key_base64url"]
                .as_str()
                .unwrap()
        );
        let signed_payload = json!({
            "header": envelope_json["header"],
            "nonce": envelope_json["nonce"],
            "ciphertext": envelope_json["ciphertext"],
        });
        assert_eq!(
            crate::jcs(&signed_payload).unwrap(),
            fixture["signed_payload_jcs_utf8"]
                .as_str()
                .unwrap()
                .as_bytes()
        );

        let (mut state, data_dir) = test_state("shared-sync-record-vector").await;
        let mut instance = (*state.instance).clone();
        instance.server_space_id = server_space_id.to_owned();
        state.instance = Arc::new(instance);

        let verify = |candidate: &serde_json::Value| {
            let candidate: Envelope = serde_json::from_value(candidate.clone()).unwrap();
            verify_envelope(&state, &public, &vault_id, &device_id, &candidate)
        };
        let checked = verify(&envelope_json).expect("shared envelope should verify");
        assert_eq!(serde_json::to_value(checked.env).unwrap(), envelope_json);
        assert_eq!(
            crate::jcs(&envelope_json).unwrap(),
            fixture["envelope_jcs_utf8"].as_str().unwrap().as_bytes()
        );

        let mut tampered_header = envelope_json.clone();
        tampered_header["header"]["operation"] = json!("update");
        assert!(verify(&tampered_header).is_err());
        for field in ["nonce", "ciphertext", "signature"] {
            let mut tampered = envelope_json.clone();
            tampered[field] = json!(flip_first_base64url(tampered[field].as_str().unwrap()));
            assert!(verify(&tampered).is_err(), "tampered {field} was accepted");
        }

        let user_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = format!("sync-vector-{}", Uuid::new_v4());
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,0)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'sync-vector',?,?,?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&public)
            .bind(URL_SAFE_NO_PAD.encode([55_u8; 32]))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        let request = serde_json::from_value(json!({
            "protocol_version": 1,
            "server_generation": state.instance.generation,
            "vault_id": vault_id,
            "device_id": device_id,
            "batch_id": Uuid::new_v4().to_string(),
            "operations": [envelope_json],
        }))
        .unwrap();
        let accepted = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            request,
            None,
        )
        .await
        .expect("server push should accept the shared vector")
        .0;
        assert_eq!(accepted["results"][0]["already_committed"], false);

        let user = crate::auth::authenticate(&state, &headers).await.unwrap();
        let pulled = changes_for_user(
            &state,
            &user,
            &vault_id,
            ChangesQuery {
                cursor: None,
                limit: Some(10),
            },
        )
        .await
        .unwrap()
        .0;
        let returned_envelope = &pulled["events"][0]["envelope"];
        assert_eq!(returned_envelope, &fixture["envelope"]);
        assert_eq!(
            crate::jcs(returned_envelope).unwrap(),
            fixture["envelope_jcs_utf8"].as_str().unwrap().as_bytes()
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    fn resign_test_envelope(envelope: &mut serde_json::Value, signing_key: &SigningKey) {
        let unsigned = json!({
            "header": envelope["header"].clone(),
            "nonce": envelope["nonce"].clone(),
            "ciphertext": envelope["ciphertext"].clone(),
        });
        let signature = signing_key.sign(&crate::jcs(&unsigned).unwrap());
        envelope["signature"] = json!(URL_SAFE_NO_PAD.encode(signature.to_bytes()));
    }

    #[tokio::test]
    async fn signed_record_counters_match_client_canonical_format_and_bounds() {
        let (state, data_dir) = test_state("sync-canonical-counters").await;
        let vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let signing_key = SigningKey::from_bytes(&[37_u8; 32]);
        let public = URL_SAFE_NO_PAD.encode(signing_key.verifying_key().to_bytes());
        let request = signed_create_push_with_seq(&state, &vault, &device, &signing_key, "1");
        let original = request["operations"][0].clone();
        let verify = |value: &serde_json::Value| {
            let envelope = serde_json::from_value(value.clone()).unwrap();
            verify_envelope(&state, &public, &vault, &device, &envelope)
        };

        assert!(
            verify(&original).is_ok(),
            "the existing signed wire fixture stays valid"
        );

        for (field, value) in [
            ("device_seq", "01"),
            ("device_seq", "+1"),
            ("device_seq", "-1"),
            ("device_seq", "18446744073709551616"),
            ("key_epoch", "01"),
            ("key_epoch", "0"),
            ("key_epoch", "9223372036854775808"),
            ("membership_version", "01"),
            ("membership_version", "0"),
            ("membership_version", "9223372036854775808"),
        ] {
            let mut malformed = original.clone();
            malformed["header"][field] = json!(value);
            resign_test_envelope(&mut malformed, &signing_key);
            let error = verify(&malformed)
                .err()
                .expect("noncanonical signed counters must be rejected");
            assert_eq!(
                error.status,
                StatusCode::UNPROCESSABLE_ENTITY,
                "{field}={value}"
            );
            assert_eq!(error.body.code, "INVALID_ENVELOPE", "{field}={value}");
        }

        for (field, value) in [
            ("device_seq", u64::MAX.to_string()),
            ("key_epoch", i64::MAX.to_string()),
            ("membership_version", i64::MAX.to_string()),
        ] {
            let mut maximum = original.clone();
            maximum["header"][field] = json!(value);
            resign_test_envelope(&mut maximum, &signing_key);
            assert!(
                verify(&maximum).is_ok(),
                "maximum canonical {field} remains accepted"
            );
        }

        let mut zero_sequence = original;
        zero_sequence["header"]["device_seq"] = json!("0");
        resign_test_envelope(&mut zero_sequence, &signing_key);
        assert!(
            verify(&zero_sequence).is_ok(),
            "the client wire parser permits canonical zero"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn real_push_audits_only_new_commits_and_rolls_back_with_audit_failure() {
        let (state, data_dir) = test_state("push-audit-transaction").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = format!("push-audit-{}", Uuid::new_v4());
        let signing_key = SigningKey::from_bytes(&[54_u8; 32]);
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,0)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?, 'test',?,?,?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(URL_SAFE_NO_PAD.encode(signing_key.verifying_key().as_bytes()))
            .bind(URL_SAFE_NO_PAD.encode([55_u8; 32]))
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();

        // A second active member device receives durable generic sync hints.
        let recipient_device_id = Uuid::new_v4().to_string();
        let recipient_endpoint_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'notification-recipient','recipient-signing','recipient-encryption',?)")
            .bind(&recipient_device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO notification_push_endpoints(endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at) VALUES(?,?,?,'fcm_v1',?,?,?,?)")
            .bind(&recipient_endpoint_id)
            .bind(&recipient_device_id)
            .bind(&user_id)
            .bind("a".repeat(64))
            .bind(format!("npe1:{}", "opaque-test-envelope".repeat(8)))
            .bind(chrono::Utc::now().timestamp())
            .bind(chrono::Utc::now().timestamp())
            .execute(&state.db)
            .await
            .unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        let first_body = signed_create_push(&state, &vault_id, &device_id, &signing_key);
        let first_request = serde_json::from_value(first_body.clone()).unwrap();
        let response = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            first_request,
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(response["results"][0]["already_committed"], false);
        let requested_after_first: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(requested_after_first, 1);

        let audit_page = crate::audit::list_audit(
            State(state.clone()),
            headers.clone(),
            Query(crate::audit::AuditQuery {
                cursor: None,
                limit: None,
            }),
        )
        .await
        .unwrap()
        .0;
        let events = audit_page["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["scope"], "vault");
        assert_eq!(events[0]["vault_id"], vault_id);
        assert_eq!(events[0]["actor_user_id"], user_id);
        assert_eq!(events[0]["actor_device_id"], device_id);
        assert_eq!(events[0]["action"], "vault.sync_batch_committed");
        assert_eq!(events[0]["resource_type"], "sync_batch");
        assert!(events[0]["resource_id"].is_null());
        assert_eq!(events[0]["result"], "success");
        assert_eq!(events[0]["source"], "api");
        let event_json = events[0].to_string();
        for forbidden in [
            "record_id",
            "op_id",
            "revision_id",
            "ciphertext",
            "operation_count",
        ] {
            assert!(!event_json.contains(forbidden));
        }

        let exact_retry = serde_json::from_value(first_body.clone()).unwrap();
        let retry = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            exact_retry,
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(retry["results"][0]["already_committed"], true);
        let requested_after_exact_retry: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(requested_after_exact_retry, 1);

        let mut operation_retry_body = first_body.clone();
        operation_retry_body["batch_id"] = json!(Uuid::new_v4().to_string());
        let operation_retry = serde_json::from_value(operation_retry_body).unwrap();
        let retry = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            operation_retry,
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(retry["results"][0]["already_committed"], true);
        let requested_after_operation_retry: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(requested_after_operation_retry, 1);

        let mut two_new_body =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "2");
        let second_new_operation =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "3");
        two_new_body["operations"]
            .as_array_mut()
            .unwrap()
            .push(second_new_operation["operations"][0].clone());
        let two_new_request = serde_json::from_value(two_new_body).unwrap();
        let two_new_response = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            two_new_request,
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(two_new_response["results"].as_array().unwrap().len(), 2);
        assert!(
            two_new_response["results"]
                .as_array()
                .unwrap()
                .iter()
                .all(|result| result["already_committed"] == false)
        );
        let requested_after_two_operations: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            requested_after_two_operations, 2,
            "one batch with two new records creates one coalesced hint"
        );
        let audit_count_after_two_new: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='vault.sync_batch_committed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            audit_count_after_two_new, 2,
            "a batch with two new operations gets exactly one event"
        );

        let mixed_new_operation =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "4");
        let mut mixed_body = mixed_new_operation;
        mixed_body["batch_id"] = json!(Uuid::new_v4().to_string());
        mixed_body["operations"] = json!([
            first_body["operations"][0].clone(),
            mixed_body["operations"][0].clone(),
        ]);
        let mixed = serde_json::from_value(mixed_body).unwrap();
        let mixed_response = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            mixed,
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(mixed_response["results"][0]["already_committed"], true);
        assert_eq!(mixed_response["results"][1]["already_committed"], false);
        let requested_after_mixed: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(requested_after_mixed, 3);
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='vault.sync_batch_committed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 3, "one mixed batch gets one event");

        // A real revision-key collision is a business conflict. This check
        // must remain distinct from the commit-sequence UNIQUE constraint.
        let duplicate_revision_body =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "5");
        let duplicate_revision_envelope = &duplicate_revision_body["operations"][0];
        let duplicate_revision_id = duplicate_revision_envelope["header"]["revision_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let duplicate_revision_batch_id = duplicate_revision_body["batch_id"]
            .as_str()
            .unwrap()
            .to_owned();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,NULL,'{}',?,100,?,'create',?)")
            .bind(&vault_id)
            // A revision ID is fetched by Vault + revision ID, so even a
            // legacy row attached to another record must reserve that ID.
            .bind("legacy-other-record")
            .bind(&duplicate_revision_id)
            .bind("test-existing-revision")
            .bind(&device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        let duplicate_revision = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            serde_json::from_value(duplicate_revision_body).unwrap(),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(duplicate_revision.status, StatusCode::CONFLICT);
        assert_eq!(duplicate_revision.body.code, "REVISION_EXISTS");
        let duplicate_revision_receipt_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&duplicate_revision_batch_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(duplicate_revision_receipt_count, 0);
        // Legacy duplicates may already exist. Revision reads must fail
        // closed instead of returning whichever record SQLite happens to
        // yield first.
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,NULL,'{}',?,101,?,'create',?)")
            .bind(&vault_id)
            .bind("legacy-duplicate-record")
            .bind(&duplicate_revision_id)
            .bind("test-duplicate-revision")
            .bind(&device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        let revision_reader = current_user(&state, &headers).await.unwrap();
        let ambiguous_read =
            get_revision_for_user(&state, &revision_reader, &vault_id, &duplicate_revision_id)
                .await
                .unwrap_err();
        assert_eq!(ambiguous_read.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(ambiguous_read.body.code, "INTERNAL");
        sqlx::query("DELETE FROM record_versions WHERE vault_id=? AND revision_id=?")
            .bind(&vault_id)
            .bind(&duplicate_revision_id)
            .execute(&state.db)
            .await
            .unwrap();

        // A genuine UNIQUE(vault_id, commit_seq) failure signals a broken
        // sequence counter, so it must stay INTERNAL and roll back the batch.
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3 WHERE vault_id=?")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        let duplicate_sequence_body =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "5");
        let duplicate_sequence_record_id =
            duplicate_sequence_body["operations"][0]["header"]["record_id"]
                .as_str()
                .unwrap()
                .to_owned();
        let duplicate_sequence_op_id = duplicate_sequence_body["operations"][0]["header"]["op_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let duplicate_sequence_batch_id = duplicate_sequence_body["batch_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let duplicate_sequence = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            serde_json::from_value(duplicate_sequence_body).unwrap(),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(duplicate_sequence.status, StatusCode::INTERNAL_SERVER_ERROR);
        assert_eq!(duplicate_sequence.body.code, "INTERNAL");
        let rolled_back_sequence: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(rolled_back_sequence, 3);
        let duplicate_sequence_heads: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&duplicate_sequence_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let duplicate_sequence_versions: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&duplicate_sequence_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let duplicate_sequence_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&duplicate_sequence_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let duplicate_sequence_ops: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?")
                .bind(&vault_id)
                .bind(&duplicate_sequence_op_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let duplicate_sequence_batches: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&duplicate_sequence_batch_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(duplicate_sequence_heads, 0);
        assert_eq!(duplicate_sequence_versions, 0);
        assert_eq!(duplicate_sequence_events, 0);
        assert_eq!(duplicate_sequence_ops, 0);
        assert_eq!(duplicate_sequence_batches, 0);
        sqlx::query("UPDATE vault_counters SET last_committed_seq=4 WHERE vault_id=?")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        // An outbox failure must roll back every durable sync write. In
        // particular, a sync commit may never succeed without its hint row.
        sqlx::query("CREATE TRIGGER reject_sync_push_hint BEFORE INSERT ON notification_push_outbox BEGIN SELECT RAISE(ABORT,'injected push hint failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        let rejected_by_outbox_body =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "5");
        let rejected_by_outbox_record_id =
            rejected_by_outbox_body["operations"][0]["header"]["record_id"]
                .as_str()
                .unwrap()
                .to_owned();
        let rejected_by_outbox_op_id = rejected_by_outbox_body["operations"][0]["header"]["op_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let rejected_by_outbox_batch_id = rejected_by_outbox_body["batch_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let rejected_by_outbox = serde_json::from_value(rejected_by_outbox_body).unwrap();
        let outbox_error = push_inner(
            state.clone(),
            headers.clone(),
            vault_id.clone(),
            rejected_by_outbox,
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(outbox_error.status, StatusCode::INTERNAL_SERVER_ERROR);
        sqlx::query("DROP TRIGGER reject_sync_push_hint")
            .execute(&state.db)
            .await
            .unwrap();
        let outbox_requested_after_rejection: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id=?",
        )
        .bind(&recipient_endpoint_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(outbox_requested_after_rejection, 3);
        let failed_head_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&rejected_by_outbox_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_head_count, 0);
        let failed_version_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&rejected_by_outbox_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_version_count, 0);
        let failed_event_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&rejected_by_outbox_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_event_count, 0);
        let failed_receipt_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?")
                .bind(&vault_id)
                .bind(&rejected_by_outbox_op_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(failed_receipt_count, 0);
        let failed_batch_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&rejected_by_outbox_batch_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_batch_count, 0);

        // A non-unique database failure at either uniqueness-sensitive insert
        // is an internal error, and every earlier write in the batch rolls
        // back with it. Only an actual unique violation maps to the API's
        // revision/idempotency conflict codes.
        for (trigger_name, trigger_sql) in [
            (
                "reject_sync_record_version",
                "CREATE TRIGGER reject_sync_record_version BEFORE INSERT ON record_versions BEGIN SELECT RAISE(ABORT,'injected record version failure'); END",
            ),
            (
                "reject_sync_operation_receipt",
                "CREATE TRIGGER reject_sync_operation_receipt BEFORE INSERT ON op_receipts BEGIN SELECT RAISE(ABORT,'injected operation receipt failure'); END",
            ),
        ] {
            sqlx::query(trigger_sql).execute(&state.db).await.unwrap();
            let failed_body =
                signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "5");
            let failed_record_id = failed_body["operations"][0]["header"]["record_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let failed_op_id = failed_body["operations"][0]["header"]["op_id"]
                .as_str()
                .unwrap()
                .to_owned();
            let failed_batch_id = failed_body["batch_id"].as_str().unwrap().to_owned();
            let error = push_inner(
                state.clone(),
                headers.clone(),
                vault_id.clone(),
                serde_json::from_value(failed_body).unwrap(),
                None,
            )
            .await
            .unwrap_err();
            assert_eq!(
                error.status,
                StatusCode::INTERNAL_SERVER_ERROR,
                "{trigger_name}"
            );
            assert_eq!(error.body.code, "INTERNAL", "{trigger_name}");
            sqlx::query(&format!("DROP TRIGGER {trigger_name}"))
                .execute(&state.db)
                .await
                .unwrap();

            let committed_seq: i64 = sqlx::query_scalar(
                "SELECT last_committed_seq FROM vault_counters WHERE vault_id=?",
            )
            .bind(&vault_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            assert_eq!(committed_seq, 4, "{trigger_name} consumed no sequence");
            let failed_head_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
            )
            .bind(&vault_id)
            .bind(&failed_record_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            let failed_version_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM record_versions WHERE vault_id=? AND record_id=?",
            )
            .bind(&vault_id)
            .bind(&failed_record_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            let failed_event_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM change_events WHERE vault_id=? AND record_id=?",
            )
            .bind(&vault_id)
            .bind(&failed_record_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            let failed_op_receipt_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM op_receipts WHERE vault_id=? AND op_id=?")
                    .bind(&vault_id)
                    .bind(&failed_op_id)
                    .fetch_one(&state.db)
                    .await
                    .unwrap();
            let failed_batch_receipt_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM batch_receipts WHERE vault_id=? AND device_id=? AND batch_id=?",
            )
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&failed_batch_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
            assert_eq!(failed_head_count, 0, "{trigger_name} left no head");
            assert_eq!(failed_version_count, 0, "{trigger_name} left no version");
            assert_eq!(failed_event_count, 0, "{trigger_name} left no event");
            assert_eq!(
                failed_op_receipt_count, 0,
                "{trigger_name} left no operation receipt"
            );
            assert_eq!(
                failed_batch_receipt_count, 0,
                "{trigger_name} left no batch receipt"
            );
        }

        sqlx::query("CREATE TRIGGER reject_sync_batch_audit BEFORE INSERT ON audit_events WHEN NEW.action='vault.sync_batch_committed' BEGIN SELECT RAISE(ABORT,'injected audit failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        let rejected_body =
            signed_create_push_with_seq(&state, &vault_id, &device_id, &signing_key, "5");
        let rejected_record_id = rejected_body["operations"][0]["header"]["record_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let rejected = serde_json::from_value(rejected_body).unwrap();
        let error = push_inner(state.clone(), headers, vault_id.clone(), rejected, None)
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::INTERNAL_SERVER_ERROR);
        let committed_seq: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            committed_seq, 4,
            "audit failure rolled back sequence allocation"
        );
        let failed_record_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&rejected_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_record_count, 0, "failed push left no new head");
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='vault.sync_batch_committed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 3, "failed push left no audit event");

        state.db.close().await;
        let _ = std::fs::remove_dir_all(data_dir);
    }

    #[tokio::test]
    async fn concurrent_pushes_commit_contiguous_pages_replay_and_rollback_atomically() {
        let (state, data_dir) = test_state("concurrent-sync-prefix").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,0)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        let device_a = Uuid::new_v4().to_string();
        let device_b = Uuid::new_v4().to_string();
        let session_a = Uuid::new_v4().to_string();
        let session_b = Uuid::new_v4().to_string();
        let token_a = format!("sync-a-{}", Uuid::new_v4());
        let token_b = format!("sync-b-{}", Uuid::new_v4());
        let key_a = SigningKey::from_bytes(&[61_u8; 32]);
        let key_b = SigningKey::from_bytes(&[62_u8; 32]);
        for (device, session, token, signing_key, name) in [
            (&device_a, &session_a, &token_a, &key_a, "sync-a"),
            (&device_b, &session_b, &token_b, &key_b, "sync-b"),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
                .bind(device)
                .bind(&user_id)
                .bind(name)
                .bind(URL_SAFE_NO_PAD.encode(signing_key.verifying_key().as_bytes()))
                .bind(URL_SAFE_NO_PAD.encode([63_u8; 32]))
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
                .bind(session)
                .bind(&user_id)
                .bind(device)
                .bind(Uuid::new_v4().to_string())
                .bind(crate::sha256_hex(token.as_bytes()))
                .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
                .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
                .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }

        let authorization = |token: &str| {
            let mut headers = HeaderMap::new();
            headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
            headers
        };
        let headers_a = authorization(&token_a);
        let headers_b = authorization(&token_b);
        let request_a = signed_create_push_with_seq(&state, &vault_id, &device_a, &key_a, "1");
        let request_b = signed_create_push_with_seq(&state, &vault_id, &device_b, &key_b, "1");
        let retry_body_a = request_a.clone();
        let retry_body_b = request_b.clone();
        let gate_a = Arc::new(crate::recovery::TestPause::new());
        let gate_b = Arc::new(crate::recovery::TestPause::new());
        let push_a_state = state.clone();
        let push_a_vault = vault_id.clone();
        let push_a_gate = gate_a.clone();
        let push_a = tokio::spawn(async move {
            push_inner(
                push_a_state,
                headers_a,
                push_a_vault,
                serde_json::from_value(request_a).unwrap(),
                Some(push_a_gate),
            )
            .await
        });
        let push_b_state = state.clone();
        let push_b_vault = vault_id.clone();
        let push_b_gate = gate_b.clone();
        let push_b = tokio::spawn(async move {
            push_inner(
                push_b_state,
                headers_b,
                push_b_vault,
                serde_json::from_value(request_b).unwrap(),
                Some(push_b_gate),
            )
            .await
        });
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            tokio::join!(gate_a.wait_until_reached(), gate_b.wait_until_reached())
        })
        .await
        .expect("both pushes should complete preflight before writer reservation");
        gate_a.release();
        gate_b.release();
        let response_a = push_a.await.unwrap().unwrap().0;
        let response_b = push_b.await.unwrap().unwrap().0;
        let seq_a = response_a["results"][0]["commit_seq"]
            .as_str()
            .unwrap()
            .to_owned();
        let seq_b = response_b["results"][0]["commit_seq"]
            .as_str()
            .unwrap()
            .to_owned();
        let mut committed_sequences = [seq_a.as_str(), seq_b.as_str()];
        committed_sequences.sort_unstable();
        assert_eq!(committed_sequences, ["1", "2"]);

        let event_sequences: Vec<i64> = sqlx::query_scalar(
            "SELECT commit_seq FROM change_events WHERE vault_id=? ORDER BY commit_seq",
        )
        .bind(&vault_id)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(event_sequences, [1, 2]);
        let committed_seq: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(committed_seq, 2);

        let user = crate::auth::authenticate(&state, &authorization(&token_a))
            .await
            .unwrap();
        let first_page = changes_for_user(
            &state,
            &user,
            &vault_id,
            ChangesQuery {
                cursor: None,
                limit: Some(1),
            },
        )
        .await
        .unwrap()
        .0;
        assert_eq!(first_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(first_page["events"][0]["commit_seq"], "1");
        assert_eq!(first_page["has_more"], true);
        let first_cursor = first_page["next_cursor"].as_str().unwrap();
        assert_eq!(
            super::parse_cursor(&state, &vault_id, first_cursor).unwrap(),
            1
        );

        let second_page = changes_for_user(
            &state,
            &user,
            &vault_id,
            ChangesQuery {
                cursor: Some(first_cursor.to_owned()),
                limit: Some(1),
            },
        )
        .await
        .unwrap()
        .0;
        assert_eq!(second_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(second_page["events"][0]["commit_seq"], "2");
        assert_eq!(second_page["has_more"], false);
        let second_cursor = second_page["next_cursor"].as_str().unwrap();
        assert_eq!(
            super::parse_cursor(&state, &vault_id, second_cursor).unwrap(),
            2
        );

        let (mut replayed_body, replayed_token, original_seq) = if seq_a == "1" {
            (retry_body_a, &token_a, seq_a)
        } else {
            (retry_body_b, &token_b, seq_b)
        };
        replayed_body["batch_id"] = json!(Uuid::new_v4().to_string());
        let replayed = push_inner(
            state.clone(),
            authorization(replayed_token),
            vault_id.clone(),
            serde_json::from_value(replayed_body).unwrap(),
            None,
        )
        .await
        .unwrap()
        .0;
        assert_eq!(replayed["results"][0]["already_committed"], true);
        assert_eq!(replayed["results"][0]["commit_seq"], original_seq);
        let counts_after_replay = sync_write_state(&state, &vault_id).await;
        assert_eq!(counts_after_replay.0, 2, "replay adds no operation receipt");
        assert_eq!(
            counts_after_replay.1, 3,
            "replay records its new batch receipt"
        );
        assert_eq!(counts_after_replay.2, 2, "replay adds no head");
        assert_eq!(counts_after_replay.3, 2, "replay adds no change event");
        assert_eq!(
            counts_after_replay.5, 2,
            "replay does not advance the cursor high-watermark"
        );

        let mut atomic_body =
            signed_create_push_with_seq(&state, &vault_id, &device_a, &key_a, "2");
        let mut conflicting =
            signed_create_push_with_seq(&state, &vault_id, &device_a, &key_a, "3");
        let existing_record_id = sqlx::query_scalar::<_, String>(
            "SELECT record_id FROM record_heads WHERE vault_id=? ORDER BY record_id LIMIT 1",
        )
        .bind(&vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        conflicting["operations"][0]["header"]["record_id"] = json!(existing_record_id);
        resign_test_envelope(&mut conflicting["operations"][0], &key_a);
        atomic_body["operations"] = json!([
            atomic_body["operations"][0].clone(),
            conflicting["operations"][0].clone(),
        ]);
        let before_conflict = sync_write_state(&state, &vault_id).await;
        let versions_before: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_versions WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let audit_before: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='vault.sync_batch_committed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        let error = push_inner(
            state.clone(),
            authorization(&token_a),
            vault_id.clone(),
            serde_json::from_value(atomic_body).unwrap(),
            None,
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "REVISION_CONFLICT");
        assert_eq!(sync_write_state(&state, &vault_id).await, before_conflict);
        let versions_after: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_versions WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let audit_after: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='vault.sync_batch_committed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            versions_after, versions_before,
            "failed batch leaves no version"
        );
        assert_eq!(
            audit_after, audit_before,
            "failed batch leaves no commit audit"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    fn json_post_request(
        uri: &str,
        bearer: Option<&str>,
        body: serde_json::Value,
    ) -> Request<Body> {
        let mut builder = Request::builder()
            .method("POST")
            .uri(uri)
            .header(CONTENT_TYPE, "application/json");
        if let Some(token) = bearer {
            builder = builder.header(AUTHORIZATION, format!("Bearer {token}"));
        }
        builder
            .body(Body::from(serde_json::to_vec(&body).unwrap()))
            .unwrap()
    }

    async fn response_json(response: axum::response::Response) -> serde_json::Value {
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn sync_write_state_for_route(
        state: &crate::AppState,
        vault_id: &str,
    ) -> serde_json::Value {
        macro_rules! ordered_rows {
            ($query:literal) => {{
                sqlx::query_scalar::<_, String>($query)
                    .bind(vault_id)
                    .fetch_all(&state.db)
                    .await
                    .unwrap()
                    .into_iter()
                    .map(|row| serde_json::from_str::<serde_json::Value>(&row).unwrap())
                    .collect::<Vec<_>>()
            }};
        }

        let row = sqlx::query(
            "SELECT \
               (SELECT COUNT(*) FROM op_receipts WHERE vault_id=v.vault_id) AS op_receipts, \
               (SELECT COUNT(*) FROM batch_receipts WHERE vault_id=v.vault_id) AS batch_receipts, \
               (SELECT COUNT(*) FROM record_heads WHERE vault_id=v.vault_id) AS record_heads, \
               (SELECT COUNT(*) FROM record_versions WHERE vault_id=v.vault_id) AS record_versions, \
               (SELECT COUNT(*) FROM change_events WHERE vault_id=v.vault_id) AS change_events, \
               (SELECT COUNT(*) FROM uploads WHERE vault_id=v.vault_id) AS uploads, \
               (SELECT COUNT(*) FROM upload_chunks WHERE upload_id IN (SELECT upload_id FROM uploads WHERE vault_id=v.vault_id)) AS upload_chunks, \
               (SELECT COUNT(*) FROM conflicts WHERE vault_id=v.vault_id) AS conflicts, \
               (SELECT last_committed_seq FROM vault_counters WHERE vault_id=v.vault_id) AS last_committed_seq, \
               (SELECT last_conflict_seq FROM vault_counters WHERE vault_id=v.vault_id) AS last_conflict_seq, \
               v.active_epoch,v.membership_version \
             FROM vaults v WHERE v.vault_id=?",
        )
        .bind(vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let op_receipt_rows = ordered_rows!(
            "SELECT json_array(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) FROM op_receipts WHERE vault_id=? ORDER BY op_id,device_id,device_seq"
        );
        let batch_receipt_rows = ordered_rows!(
            "SELECT json_array(vault_id,device_id,batch_id,request_digest,response_json) FROM batch_receipts WHERE vault_id=? ORDER BY device_id,batch_id"
        );
        let head_rows = ordered_rows!(
            "SELECT json_array(vault_id,record_id,revision_id,deleted,commit_seq) FROM record_heads WHERE vault_id=? ORDER BY record_id"
        );
        let version_rows = ordered_rows!(
            "SELECT json_array(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) FROM record_versions WHERE vault_id=? ORDER BY record_id,revision_id"
        );
        let event_rows = ordered_rows!(
            "SELECT json_array(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) FROM change_events WHERE vault_id=? ORDER BY commit_seq"
        );
        let graveyard_rows = ordered_rows!(
            "SELECT json_array(vault_id,record_id,deleted_revision,deleted_seq) FROM record_graveyard WHERE vault_id=? ORDER BY record_id"
        );
        let object_reference_rows = ordered_rows!(
            "SELECT json_array(vault_id,revision_id,object_id) FROM object_references WHERE vault_id=? ORDER BY revision_id,object_id"
        );
        let blob_object_rows = ordered_rows!(
            "SELECT json_array(vault_id,object_id,hex(bytes),size,sha256,created_at,gc_after) FROM blob_objects WHERE vault_id=? ORDER BY object_id"
        );
        let upload_rows = sqlx::query(
            "SELECT upload_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at FROM uploads WHERE vault_id=? ORDER BY upload_id",
        )
        .bind(vault_id)
        .fetch_all(&state.db)
        .await
        .unwrap()
        .into_iter()
        .map(|row| {
            json!({
                "upload_id": row.get::<String, _>("upload_id"),
                "user_id": row.get::<String, _>("user_id"),
                "object_id": row.get::<String, _>("object_id"),
                "expected_size": row.get::<i64, _>("expected_size"),
                "expected_sha256": row.get::<String, _>("expected_sha256"),
                "chunk_size": row.get::<i64, _>("chunk_size"),
                "state": row.get::<String, _>("state"),
                "expires_at": row.get::<String, _>("expires_at"),
                "created_at": row.get::<String, _>("created_at"),
            })
        })
        .collect::<Vec<_>>();
        let upload_chunk_rows = sqlx::query(
            "SELECT c.upload_id,c.chunk_index,c.bytes,c.sha256 FROM upload_chunks c JOIN uploads u ON u.upload_id=c.upload_id WHERE u.vault_id=? ORDER BY c.upload_id,c.chunk_index",
        )
        .bind(vault_id)
        .fetch_all(&state.db)
        .await
        .unwrap()
        .into_iter()
        .map(|row| {
            json!({
                "upload_id": row.get::<String, _>("upload_id"),
                "chunk_index": row.get::<i64, _>("chunk_index"),
                "bytes": row.get::<Vec<u8>, _>("bytes"),
                "sha256": row.get::<String, _>("sha256"),
            })
        })
        .collect::<Vec<_>>();
        let conflict_rows = sqlx::query(
            "SELECT conflict_id,record_id,base_revision_id,envelope,digest,device_id,created_at,resolved_revision_id,conflict_seq FROM conflicts WHERE vault_id=? ORDER BY conflict_seq,conflict_id",
        )
        .bind(vault_id)
        .fetch_all(&state.db)
        .await
        .unwrap()
        .into_iter()
        .map(|row| {
            json!({
                "conflict_id": row.get::<String, _>("conflict_id"),
                "record_id": row.get::<String, _>("record_id"),
                "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                "envelope": row.get::<String, _>("envelope"),
                "digest": row.get::<String, _>("digest"),
                "device_id": row.get::<String, _>("device_id"),
                "created_at": row.get::<String, _>("created_at"),
                "resolved_revision_id": row.get::<Option<String>, _>("resolved_revision_id"),
                "conflict_seq": row.get::<i64, _>("conflict_seq"),
            })
        })
        .collect::<Vec<_>>();
        json!({
            "op_receipts": row.get::<i64, _>("op_receipts"),
            "batch_receipts": row.get::<i64, _>("batch_receipts"),
            "record_heads": row.get::<i64, _>("record_heads"),
            "record_versions": row.get::<i64, _>("record_versions"),
            "change_events": row.get::<i64, _>("change_events"),
            "uploads": row.get::<i64, _>("uploads"),
            "upload_chunks": row.get::<i64, _>("upload_chunks"),
            "conflicts": row.get::<i64, _>("conflicts"),
            "last_committed_seq": row.get::<i64, _>("last_committed_seq"),
            "last_conflict_seq": row.get::<i64, _>("last_conflict_seq"),
            "active_epoch": row.get::<i64, _>("active_epoch"),
            "membership_version": row.get::<i64, _>("membership_version"),
            "op_receipt_rows": op_receipt_rows,
            "batch_receipt_rows": batch_receipt_rows,
            "head_rows": head_rows,
            "version_rows": version_rows,
            "event_rows": event_rows,
            "graveyard_rows": graveyard_rows,
            "object_reference_rows": object_reference_rows,
            "blob_object_rows": blob_object_rows,
            "upload_rows": upload_rows,
            "upload_chunk_rows": upload_chunk_rows,
            "conflict_rows": conflict_rows,
        })
    }

    async fn sync_write_state(
        state: &crate::AppState,
        vault_id: &str,
    ) -> (i64, i64, i64, i64, i64, i64, i64) {
        sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM op_receipts WHERE vault_id=?) AS op_receipts, (SELECT COUNT(*) FROM batch_receipts WHERE vault_id=?) AS batch_receipts, (SELECT COUNT(*) FROM record_heads WHERE vault_id=?) AS heads, (SELECT COUNT(*) FROM change_events WHERE vault_id=?) AS events, (SELECT COUNT(*) FROM uploads WHERE vault_id=?) AS uploads, (SELECT last_committed_seq FROM vault_counters WHERE vault_id=?) AS commit_seq, (SELECT membership_version FROM vaults WHERE vault_id=?) AS membership_version",
        )
        .bind(vault_id)
        .bind(vault_id)
        .bind(vault_id)
        .bind(vault_id)
        .bind(vault_id)
        .bind(vault_id)
        .bind(vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap()
    }

    #[test]
    fn object_refs_must_be_optional_or_strictly_sorted_canonical_uuids() {
        assert!(parse_object_refs(&json!({})).unwrap().is_empty());
        assert!(
            parse_object_refs(&json!({"object_refs":[]}))
                .unwrap()
                .is_empty()
        );
        let sorted = vec![
            Uuid::from_u128(1).to_string(),
            Uuid::from_u128(2).to_string(),
        ];
        assert_eq!(
            parse_object_refs(&json!({"object_refs":sorted.clone()})).unwrap(),
            sorted
        );
        let exactly_max = (1..=1024)
            .map(|value| Uuid::from_u128(value).to_string())
            .collect::<Vec<_>>();
        let maximum_header = json!({"object_refs":exactly_max});
        assert!(maximum_header.to_string().len() < 64 * 1024);
        assert_eq!(parse_object_refs(&maximum_header).unwrap().len(), 1024);

        let invalid_headers = [
            json!({"object_refs":null}),
            json!({"object_refs":[1]}),
            json!({"object_refs":["not-a-uuid"]}),
            json!({"object_refs":["00000000-0000-0000-0000-000000000002","00000000-0000-0000-0000-000000000001"]}),
            json!({"object_refs":["00000000-0000-0000-0000-000000000001","00000000-0000-0000-0000-000000000001"]}),
            json!({"object_refs":["00000000-0000-0000-0000-00000000000A"]}),
        ];
        for header in invalid_headers {
            let error = parse_object_refs(&header).unwrap_err();
            assert_eq!(error.status, StatusCode::UNPROCESSABLE_ENTITY);
            assert_eq!(error.body.code, "INVALID_ENVELOPE");
        }

        let too_many = (1..=1025)
            .map(|value| Uuid::from_u128(value).to_string())
            .collect::<Vec<_>>();
        let error = parse_object_refs(&json!({"object_refs":too_many})).unwrap_err();
        assert_eq!(error.status, StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error.body.code, "INVALID_ENVELOPE");
    }

    fn next_test_value(state: &mut u64) -> u64 {
        // Fixed-seed xorshift keeps this property-style test reproducible and
        // avoids adding a test-only random generator dependency.
        *state ^= *state << 13;
        *state ^= *state >> 7;
        *state ^= *state << 17;
        *state
    }

    fn generated_object_refs_header(state: &mut u64) -> Value {
        match next_test_value(state) % 7 {
            0 => json!({"unrelated": next_test_value(state)}),
            1 => json!({"object_refs": null}),
            2 => json!({"object_refs": "not-an-array"}),
            kind @ 3..=5 => {
                let count = (next_test_value(state) % 12) as usize;
                let base = (next_test_value(state) as u128) & 0x0000_ffff_ffff_ffff;
                let mut ids = (0..count)
                    .map(|offset| Uuid::from_u128(base + offset as u128).to_string())
                    .collect::<Vec<_>>();
                match kind {
                    4 => ids.reverse(),
                    5 if !ids.is_empty() => ids.push(ids[0].clone()),
                    _ => {}
                }
                json!({"object_refs": ids})
            }
            _ => {
                let count = (next_test_value(state) % 20) as usize;
                let entries = (0..count)
                    .map(|_| match next_test_value(state) % 5 {
                        0 => json!(Uuid::from_u128(next_test_value(state) as u128).to_string()),
                        1 => json!(format!("not-a-uuid-{}", next_test_value(state))),
                        2 => json!(next_test_value(state)),
                        3 => Value::Null,
                        _ => json!(
                            Uuid::from_u128(next_test_value(state) as u128)
                                .to_string()
                                .to_uppercase()
                        ),
                    })
                    .collect::<Vec<_>>();
                json!({"object_refs": entries})
            }
        }
    }

    fn expected_object_refs(header: &Value) -> Option<Vec<String>> {
        let Some(value) = header.get("object_refs") else {
            return Some(Vec::new());
        };
        let refs = value.as_array()?;
        if refs.len() > MAX_OBJECT_REFS {
            return None;
        }
        let mut expected = Vec::with_capacity(refs.len());
        let mut previous: Option<&str> = None;
        for item in refs {
            let id = item.as_str()?;
            if !crate::is_canonical_uuid(id) || previous.is_some_and(|prior| prior >= id) {
                return None;
            }
            expected.push(id.to_owned());
            previous = Some(id);
        }
        Some(expected)
    }

    #[test]
    fn generated_sync_object_refs_headers_preserve_canonical_order_and_bounds() {
        let mut state = 0x4d59_5df4_d0f3_3173;
        for sample in 0..4096 {
            let header = generated_object_refs_header(&mut state);
            let expected = expected_object_refs(&header);
            let actual = parse_object_refs(&header);
            match (expected, actual) {
                (Some(expected), Ok(actual)) => assert_eq!(actual, expected, "sample {sample}"),
                (None, Err(error)) => {
                    assert_eq!(
                        error.status,
                        StatusCode::UNPROCESSABLE_ENTITY,
                        "sample {sample}"
                    );
                    assert_eq!(error.body.code, "INVALID_ENVELOPE", "sample {sample}");
                }
                (expected, actual) => panic!(
                    "sync object_refs parser disagreed with its generated invariant at sample {sample}: expected {expected:?}, actual {actual:?}"
                ),
            }
        }
    }

    #[test]
    fn generated_device_counters_accept_only_canonical_decimal_forms() {
        let mut state = 0xa076_1d64_78bd_642f;
        for counter in 0..10_000_u64 {
            let canonical = counter.to_string();
            assert!(is_canonical_decimal_counter(&canonical, true));
            assert_eq!(
                is_canonical_decimal_counter(&canonical, false),
                counter != 0
            );
            assert!(!is_canonical_decimal_counter(
                &format!("0{canonical}"),
                true
            ));
        }

        let alphabet = b"0123456789+- abcXYZ";
        for sample in 0..4096 {
            let length = (next_test_value(&mut state) % 48) as usize;
            let value = (0..length)
                .map(|_| alphabet[(next_test_value(&mut state) as usize) % alphabet.len()] as char)
                .collect::<String>();
            for allow_zero in [false, true] {
                if is_canonical_decimal_counter(&value, allow_zero) {
                    assert!(!value.is_empty(), "sample {sample}");
                    assert!(
                        value.bytes().all(|byte| byte.is_ascii_digit()),
                        "sample {sample}"
                    );
                    assert!(value == "0" || !value.starts_with('0'), "sample {sample}");
                    assert!(allow_zero || value != "0", "sample {sample}");
                }
            }
        }
    }

    #[test]
    fn generated_sync_page_events_never_overrun_or_mutate_budget_on_rejection() {
        let event_budget = MAX_SYNC_PAGE_RESPONSE_BYTES - SYNC_PAGE_METADATA_RESERVE_BYTES;
        let mut budget = SyncPageBudget::default();
        let mut state = 0xe703_7ed1_a0b4_28db;
        for sample in 0..128 {
            let size = (next_test_value(&mut state) % 128_000) as usize;
            let event = json!({"seq": sample.to_string(), "payload": "x".repeat(size)});
            let serialized_len = serde_json::to_vec(&event).unwrap().len();
            let separator = usize::from(budget.event_count > 0);
            let should_fit = budget
                .event_bytes
                .saturating_add(separator)
                .saturating_add(serialized_len)
                <= event_budget;
            let before = (budget.event_bytes, budget.event_count);
            let accepted = budget.try_add(&event).unwrap();
            assert_eq!(accepted, should_fit, "sample {sample}");
            if accepted {
                assert!(budget.event_bytes <= event_budget, "sample {sample}");
                assert_eq!(budget.event_count, before.1 + 1, "sample {sample}");
            } else {
                assert_eq!(
                    (budget.event_bytes, budget.event_count),
                    before,
                    "sample {sample}"
                );
            }
        }
    }

    #[test]
    fn conflict_changes_query_requires_canonical_sequence_and_generation_checkpoint() {
        let initial = parse_conflict_changes_query(ConflictChangesQuery {
            after_seq: None,
            limit: None,
            server_generation: None,
        })
        .unwrap();
        assert_eq!(initial.after_seq, 0);
        assert_eq!(initial.after_seq_wire, "0");
        assert_eq!(initial.limit, 100);

        let checkpoint_generation = Uuid::new_v4().to_string();
        let continuation = parse_conflict_changes_query(ConflictChangesQuery {
            after_seq: Some("9007199254740993".to_owned()),
            limit: Some("500".to_owned()),
            server_generation: Some(checkpoint_generation.clone()),
        })
        .unwrap();
        assert_eq!(continuation.after_seq_wire, "9007199254740993");
        assert_eq!(continuation.limit, 500);
        assert_eq!(continuation.server_generation, Some(checkpoint_generation));

        for invalid in ["", "00", "+1", "-1", " 1", "1x", "9223372036854775808"] {
            let error = parse_conflict_changes_query(ConflictChangesQuery {
                after_seq: Some(invalid.to_owned()),
                limit: None,
                server_generation: None,
            })
            .unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.body.code, "INVALID_AFTER_SEQ");
        }

        let missing_generation = parse_conflict_changes_query(ConflictChangesQuery {
            after_seq: Some("1".to_owned()),
            limit: None,
            server_generation: None,
        })
        .unwrap_err();
        assert_eq!(missing_generation.body.code, "SERVER_GENERATION_REQUIRED");
        let zero_checkpoint_missing_generation =
            parse_conflict_changes_query(ConflictChangesQuery {
                after_seq: Some("0".to_owned()),
                limit: None,
                server_generation: None,
            })
            .unwrap_err();
        assert_eq!(
            zero_checkpoint_missing_generation.body.code,
            "SERVER_GENERATION_REQUIRED"
        );

        for invalid_limit in ["0", "501", "many"] {
            let error = parse_conflict_changes_query(ConflictChangesQuery {
                after_seq: None,
                limit: Some(invalid_limit.to_owned()),
                server_generation: None,
            })
            .unwrap_err();
            assert_eq!(error.body.code, "INVALID_LIMIT");
        }
    }

    #[tokio::test]
    async fn object_refs_reject_missing_foreign_and_open_objects_atomically() {
        let (state, data_dir) = test_state("object-refs-atomic").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let other_vault = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&other_vault)
            .bind(&user)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        let foreign_object = Uuid::new_v4().to_string();
        let open_object = Uuid::new_v4().to_string();
        let missing_object = Uuid::new_v4().to_string();
        let past = chrono::Utc::now().timestamp() - 100;
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'01',1,'hash',?,?)")
            .bind(&other_vault)
            .bind(&foreign_object)
            .bind(now_rfc3339())
            .bind(past)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?, ?,1,'hash',1048576,'open',?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault)
            .bind(&user)
            .bind(&open_object)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        for (commit_seq, unavailable) in [
            (1_i64, foreign_object),
            (2_i64, open_object),
            (3_i64, missing_object),
        ] {
            let record_id = Uuid::new_v4().to_string();
            let revision_id = Uuid::new_v4().to_string();
            let op_id = Uuid::new_v4().to_string();
            let mut tx = state.db.begin().await.unwrap();
            // Mimic the record/event/head/receipt writes which must be rolled
            // back as a unit if reference validation fails.
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,'{}','digest',?,'device','create',?)")
                .bind(&vault)
                .bind(&record_id)
                .bind(&revision_id)
                .bind(commit_seq)
                .bind(now_rfc3339())
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,?)")
                .bind(&vault)
                .bind(&record_id)
                .bind(&revision_id)
                .bind(commit_seq)
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,?,'create',?,?,'{}',?)")
                .bind(&vault)
                .bind(commit_seq)
                .bind(&record_id)
                .bind(&revision_id)
                .bind(now_rfc3339())
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query("INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) VALUES(?,?,'device',?,'digest',?,?,?)")
                .bind(&vault)
                .bind(&op_id)
                .bind(commit_seq.to_string())
                .bind(&record_id)
                .bind(&revision_id)
                .bind(commit_seq)
                .execute(&mut *tx)
                .await
                .unwrap();
            sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES(?,'device',?,'digest','{}')")
                .bind(&vault)
                .bind(Uuid::new_v4().to_string())
                .execute(&mut *tx)
                .await
                .unwrap();

            let error = persist_object_references_tx(&mut tx, &vault, &revision_id, &[unavailable])
                .await
                .unwrap_err();
            assert_eq!(error.status, StatusCode::CONFLICT);
            assert_eq!(error.body.code, "OBJECT_REFERENCE_UNAVAILABLE");
            tx.rollback().await.unwrap();

            for table in [
                "record_versions",
                "record_heads",
                "change_events",
                "op_receipts",
                "batch_receipts",
                "object_references",
            ] {
                let count: i64 =
                    sqlx::query_scalar(&format!("SELECT COUNT(*) FROM {table} WHERE vault_id=?"))
                        .bind(&vault)
                        .fetch_one(&state.db)
                        .await
                        .unwrap();
                assert_eq!(count, 0, "failed object reference must roll back {table}");
            }
        }

        let available_object = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'01',1,'hash',?,?)")
            .bind(&vault)
            .bind(&available_object)
            .bind(now_rfc3339())
            .bind(past)
            .execute(&state.db)
            .await
            .unwrap();
        let conflict_id = Uuid::new_v4().to_string();
        let conflict_revision = Uuid::new_v4().to_string();
        let conflict_record = Uuid::new_v4().to_string();
        let mut tx = state.db.begin().await.unwrap();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at) VALUES(?,?,?,'{}','digest','device',?)")
            .bind(&conflict_id)
            .bind(&vault)
            .bind(&conflict_record)
            .bind(now_rfc3339())
            .execute(&mut *tx)
            .await
            .unwrap();
        let refs = vec![available_object.clone()];
        persist_object_references_tx(&mut tx, &vault, &conflict_revision, &refs)
            .await
            .unwrap();
        persist_object_references_tx(&mut tx, &vault, &conflict_revision, &refs)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let ref_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=? AND revision_id=?",
        )
        .bind(&vault)
        .bind(&conflict_revision)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(ref_count, 1, "reference insertion is idempotent");
        let gc_after: Option<i64> = sqlx::query_scalar(
            "SELECT gc_after FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&available_object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(gc_after, None, "a conflict reference cancels GC");

        compact_expired_history(&state).await.unwrap();
        let still_present: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&available_object)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(still_present, 1, "conflict-referenced objects are retained");

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn maintenance_sweeps_only_due_unreferenced_objects() {
        let (state, data_dir) = test_state("object-gc").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;
        let now_epoch = chrono::Utc::now().timestamp();
        let past = now_epoch - 1;
        let future = now_epoch + 3600;
        let due = Uuid::new_v4().to_string();
        let future_object = Uuid::new_v4().to_string();
        let legacy = Uuid::new_v4().to_string();
        let referenced = Uuid::new_v4().to_string();
        let due_upload = Uuid::new_v4().to_string();
        let future_upload = Uuid::new_v4().to_string();

        for (object_id, gc_after) in [
            (due.as_str(), Some(past)),
            (future_object.as_str(), Some(future)),
            (legacy.as_str(), None),
            (referenced.as_str(), Some(past)),
        ] {
            sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'010203',3,'hash',?,?)")
                .bind(&vault)
                .bind(object_id)
                .bind(now_rfc3339())
                .bind(gc_after)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .bind(&referenced)
            .execute(&state.db)
            .await
            .unwrap();

        for (upload, object_id) in [(&due_upload, &due), (&future_upload, &future_object)] {
            sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,3,'hash',1048576,'completed','2099-01-01T00:00:00+00:00',?)")
                .bind(upload)
                .bind(&vault)
                .bind(&user)
                .bind(object_id)
                .bind(now_rfc3339())
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'010203','hash')")
                .bind(upload)
                .execute(&state.db)
                .await
                .unwrap();
        }

        compact_expired_history(&state).await.unwrap();

        let retained: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id IN (?,?,?)",
        )
        .bind(&vault)
        .bind(&future_object)
        .bind(&legacy)
        .bind(&referenced)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            retained, 3,
            "future, legacy NULL, and referenced objects remain"
        );
        let due_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&due)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(due_count, 0, "due unreferenced objects are collected");
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&due_upload)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(upload_state, "collected");
        let due_chunks: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&due_upload)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(due_chunks, 0);
        let future_chunks: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&future_upload)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            future_chunks, 0,
            "terminal completed payloads are reclaimed"
        );
        let retained_quota: i64 =
            sqlx::query_scalar("SELECT COALESCE(SUM(size),0) FROM blob_objects WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            retained_quota, 9,
            "collected object bytes leave quota accounting"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn retained_cursor_floor_expires_only_positions_before_the_prefix() {
        assert!(!cursor_is_expired(0, 1));
        assert!(cursor_is_expired(0, 2));
        assert!(!cursor_is_expired(1, 2));
    }

    #[tokio::test]
    async fn changes_page_snapshot_survives_concurrent_retention_compaction() {
        let (state, data_dir) = test_state("changes-page-retention-snapshot").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = format!("changes-read-{}", Uuid::new_v4());
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'reader','test-signing-key','test-encryption-key',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,2,0)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        for (seq, event_created_at) in [
            (1_i64, "2000-01-01T00:00:00+00:00"),
            (2_i64, created.as_str()),
        ] {
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,?,'create',?,?,?,?)")
                .bind(&vault_id)
                .bind(seq)
                .bind(format!("record-{seq}"))
                .bind(format!("revision-{seq}"))
                .bind(r#"{"ciphertext":"opaque"}"#)
                .bind(event_created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }

        let user = crate::auth::AuthUser {
            user_id,
            device_id,
            session_id,
            access_hash: crate::sha256_hex(token.as_bytes()),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let pause = Arc::new(crate::recovery::TestPause::new());
        let _release_pause = crate::recovery::ReleasePauseOnDrop::new(pause.clone());
        let repository = state.sync_repository.clone();
        let command = crate::sync_repository::ChangesPageCommand {
            user: user.clone(),
            vault_id: vault_id.clone(),
            raw_cursor: None,
            limit: 1,
            cursor_key: *state.cursor_key,
            generation: state.instance.generation.clone(),
            test_pause: Some(pause.clone()),
        };
        let read = tokio::spawn(async move { repository.read_changes_page(command).await });
        if tokio::time::timeout(
            std::time::Duration::from_secs(5),
            pause.wait_until_reached(),
        )
        .await
        .is_err()
        {
            read.abort();
            match read.await {
                Ok(Ok(_)) => panic!("read finished without reaching its test pause"),
                Ok(Err(error)) => panic!("read failed before reaching its test pause: {error}"),
                Err(error) => panic!("read task failed before reaching its test pause: {error}"),
            }
        }

        compact_expired_history(&state).await.unwrap();
        let floor: i64 =
            sqlx::query_scalar("SELECT minimum_available_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(floor, 2, "compaction committed the newer retention floor");

        pause.release();
        let page = read.await.unwrap().unwrap();
        let events = page["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["commit_seq"], "1");
        assert_eq!(page["has_more"], true);
        let next_cursor = page["next_cursor"].as_str().unwrap();
        assert_eq!(parse_cursor(&state, &vault_id, next_cursor).unwrap(), 1);

        // The cursor records only the returned prefix. A new read sees the
        // committed retention floor and safely continues with sequence 2.
        let continued = state
            .sync_repository
            .read_changes_page(crate::sync_repository::ChangesPageCommand {
                user,
                vault_id: vault_id.clone(),
                raw_cursor: Some(next_cursor.to_owned()),
                limit: 1,
                cursor_key: *state.cursor_key,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        assert_eq!(continued["events"][0]["commit_seq"], "2");
        assert_eq!(continued["has_more"], false);

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn conflict_changes_page_keeps_high_watermark_and_rows_in_one_snapshot() {
        let (state, data_dir) = test_state("conflict-changes-page-snapshot").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let token = format!("conflict-read-{}", Uuid::new_v4());
        let created = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'reader','test-signing-key','test-encryption-key',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,1)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();
        let first_conflict_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,conflict_seq) VALUES(?,?,?,'{\"ciphertext\":\"first\"}','digest',?,?,1)")
            .bind(&first_conflict_id)
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&device_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();

        let user = crate::auth::AuthUser {
            user_id,
            device_id: device_id.clone(),
            session_id,
            access_hash: crate::sha256_hex(token.as_bytes()),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let pause = Arc::new(crate::recovery::TestPause::new());
        let _release_pause = crate::recovery::ReleasePauseOnDrop::new(pause.clone());
        let repository = state.sync_repository.clone();
        let command = crate::sync_repository::ConflictChangesPageCommand {
            user: user.clone(),
            vault_id: vault_id.clone(),
            after_seq: 0,
            after_seq_wire: "0".to_owned(),
            limit: 10,
            server_generation: None,
            generation: state.instance.generation.clone(),
            test_pause: Some(pause.clone()),
        };
        let read =
            tokio::spawn(async move { repository.read_conflict_changes_page(command).await });
        if tokio::time::timeout(
            std::time::Duration::from_secs(5),
            pause.wait_until_reached(),
        )
        .await
        .is_err()
        {
            read.abort();
            match read.await {
                Ok(Ok(_)) => panic!("read finished without reaching its test pause"),
                Ok(Err(error)) => panic!("read failed before reaching its test pause: {error}"),
                Err(error) => panic!("read task failed before reaching its test pause: {error}"),
            }
        }

        let second_conflict_id = Uuid::new_v4().to_string();
        let mut write = state.db.begin().await.unwrap();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,conflict_seq) VALUES(?,?,?,'{\"ciphertext\":\"second\"}','digest',?,?,2)")
            .bind(&second_conflict_id)
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&device_id)
            .bind(now_rfc3339())
            .execute(&mut *write)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_conflict_seq=2 WHERE vault_id=?")
            .bind(&vault_id)
            .execute(&mut *write)
            .await
            .unwrap();
        write.commit().await.unwrap();

        pause.release();
        let page = read.await.unwrap().unwrap();
        assert_eq!(page["high_watermark"], "1");
        assert_eq!(page["events"].as_array().unwrap().len(), 1);
        assert_eq!(page["events"][0]["conflict_id"], first_conflict_id);
        assert_eq!(page["next_after_seq"], "1");
        assert_eq!(page["has_more"], false);

        let continued = state
            .sync_repository
            .read_conflict_changes_page(crate::sync_repository::ConflictChangesPageCommand {
                user,
                vault_id: vault_id.clone(),
                after_seq: 1,
                after_seq_wire: "1".to_owned(),
                limit: 10,
                server_generation: Some(state.instance.generation.clone()),
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        assert_eq!(continued["high_watermark"], "2");
        assert_eq!(continued["events"].as_array().unwrap().len(), 1);
        assert_eq!(continued["events"][0]["seq"], "2");
        assert_eq!(continued["events"][0]["conflict_id"], second_conflict_id);

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn conflict_resolution_retry_is_idempotent_only_for_same_revision() {
        assert!(!conflict_resolution_retry(None, "revision-a").unwrap());
        assert!(conflict_resolution_retry(Some("revision-a"), "revision-a").unwrap());
        let error = conflict_resolution_retry(Some("revision-a"), "revision-b").unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "CONFLICT_ALREADY_RESOLVED");
    }

    #[test]
    fn conflict_idempotency_reuses_identical_jcs_digest_and_rejects_changed_content() {
        assert_eq!(conflict_idempotency_retry(None, "digest-a").unwrap(), None);
        assert_eq!(
            conflict_idempotency_retry(
                Some(("conflict-1".to_owned(), "digest-a".to_owned())),
                "digest-a",
            )
            .unwrap(),
            Some("conflict-1".to_owned())
        );
        let error = conflict_idempotency_retry(
            Some(("conflict-1".to_owned(), "digest-a".to_owned())),
            "digest-b",
        )
        .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "IDEMPOTENCY_KEY_REUSED");
    }

    #[tokio::test]
    async fn conflict_idempotency_lookup_is_scoped_and_has_no_write_side_effects() {
        let (state, data_dir) = test_state("conflict-idempotency").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let other_vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let op_id = Uuid::new_v4().to_string();
        let conflict_id = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&other_vault)
            .bind(&user)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,9),(?,0,0)")
            .bind(&vault)
            .bind(&other_vault)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES(?,?,?,'{}','digest-a',?,?,9,?)")
            .bind(&conflict_id)
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .bind(&device)
            .bind(now_rfc3339())
            .bind(&op_id)
            .execute(&state.db)
            .await
            .unwrap();

        let mut tx = state.db.begin().await.unwrap();
        let retry = conflict_idempotency_tx(&mut tx, &vault, &device, &op_id, "digest-a")
            .await
            .unwrap();
        assert_eq!(retry, Some(conflict_id.clone()));
        tx.commit().await.unwrap();

        let counter: i64 =
            sqlx::query_scalar("SELECT last_conflict_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            counter, 9,
            "an idempotent lookup must not allocate a sequence"
        );

        let mut tx = state.db.begin().await.unwrap();
        let error = conflict_idempotency_tx(&mut tx, &vault, &device, &op_id, "digest-b")
            .await
            .unwrap_err();
        assert_eq!(error.body.code, "IDEMPOTENCY_KEY_REUSED");
        tx.rollback().await.unwrap();

        let mut tx = state.db.begin().await.unwrap();
        assert_eq!(
            conflict_idempotency_tx(&mut tx, &other_vault, &device, &op_id, "digest-a")
                .await
                .unwrap(),
            None,
            "another vault must not see the existing receipt"
        );
        tx.rollback().await.unwrap();
        let refs: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM object_references WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(
            refs, 0,
            "an idempotent lookup must not duplicate references"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn history_page_limits_are_explicitly_bounded() {
        assert_eq!(parse_history_limit(None).unwrap(), 500);
        assert_eq!(parse_history_limit(Some("1")).unwrap(), 1);
        assert_eq!(parse_history_limit(Some("500")).unwrap(), 500);
        for invalid in [Some("0"), Some("501"), Some("-1"), Some("many")] {
            let error = parse_history_limit(invalid).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.body.code, "INVALID_LIMIT");
        }
    }

    #[test]
    fn history_snapshot_id_must_be_a_canonical_uuid() {
        let valid = Uuid::new_v4().to_string();
        assert_eq!(required_history_snapshot_id(Some(&valid)).unwrap(), valid);
        for invalid in [
            None,
            Some(""),
            Some("not-a-uuid"),
            Some("00000000-0000-0000-0000-00000000000A"),
        ] {
            let error = required_history_snapshot_id(invalid).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.body.code, "INVALID_SNAPSHOT_ID");
        }
    }

    #[tokio::test]
    async fn history_cursor_binds_route_snapshot_generation_and_paired_watermarks() {
        let (state, data_dir) = test_state("history-cursor").await;
        let bounds = HistoryBounds {
            revisions: 9_007_199_254_741_001,
            conflicts: 9_007_199_254_741_002,
        };
        let cursor = history_cursor(
            &state.instance.generation,
            &state.cursor_key,
            HistoryKind::Revisions,
            "vault-id",
            "snapshot-id",
            bounds,
            9_007_199_254_740_999,
        )
        .unwrap();
        assert_eq!(
            parse_history_cursor(
                &state.cursor_key,
                &state.instance.generation,
                HistoryKind::Revisions,
                "vault-id",
                "snapshot-id",
                bounds,
                &cursor,
            )
            .unwrap(),
            9_007_199_254_740_999
        );
        for (kind, vault, snapshot, cursor_bounds) in [
            (HistoryKind::Conflicts, "vault-id", "snapshot-id", bounds),
            (
                HistoryKind::Revisions,
                "another-vault",
                "snapshot-id",
                bounds,
            ),
            (
                HistoryKind::Revisions,
                "vault-id",
                "another-snapshot",
                bounds,
            ),
            (
                HistoryKind::Revisions,
                "vault-id",
                "snapshot-id",
                HistoryBounds {
                    revisions: bounds.revisions + 1,
                    conflicts: bounds.conflicts,
                },
            ),
        ] {
            let error = parse_history_cursor(
                &state.cursor_key,
                &state.instance.generation,
                kind,
                vault,
                snapshot,
                cursor_bounds,
                &cursor,
            )
            .unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.body.code, "INVALID_CURSOR");
        }

        let mut prior_generation = state.clone();
        let mut instance = (*state.instance).clone();
        instance.generation = Uuid::new_v4().to_string();
        prior_generation.instance = Arc::new(instance);
        let error = parse_history_cursor(
            &state.cursor_key,
            &prior_generation.instance.generation,
            HistoryKind::Revisions,
            "vault-id",
            "snapshot-id",
            bounds,
            &cursor,
        )
        .unwrap_err();
        assert_eq!(error.status, StatusCode::GONE);
        assert_eq!(error.body.code, "HISTORY_CURSOR_EXPIRED");

        drop(prior_generation);
        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[test]
    fn foreign_generation_history_cursor_claim_is_scoped_recovery_hint_only() {
        let vault = Uuid::new_v4().to_string();
        let snapshot = Uuid::new_v4().to_string();
        let current_generation = Uuid::new_v4().to_string();
        let cursor_generation = Uuid::new_v4().to_string();
        let data = crate::jcs(&json!({
            "v": 1,
            "kind": "revisions",
            "vault_id": vault,
            "snapshot_id": snapshot,
            "generation": cursor_generation,
            // These values are shape-checked but remain untrusted and are
            // never used as authorization or query bounds.
            "high_watermark": "1",
            "conflict_high_watermark": "2",
            "after": "3",
        }))
        .unwrap();
        let encoded = URL_SAFE_NO_PAD.encode([data, vec![0x5a; 32]].concat());

        assert!(foreign_generation_history_cursor_claim(
            &encoded,
            HistoryKind::Revisions,
            &vault,
            &snapshot,
            &current_generation,
        ));
        assert!(!foreign_generation_history_cursor_claim(
            &encoded,
            HistoryKind::Conflicts,
            &vault,
            &snapshot,
            &current_generation,
        ));
        assert!(!foreign_generation_history_cursor_claim(
            &encoded,
            HistoryKind::Revisions,
            &Uuid::new_v4().to_string(),
            &snapshot,
            &current_generation,
        ));
        assert!(!foreign_generation_history_cursor_claim(
            &encoded,
            HistoryKind::Revisions,
            &vault,
            &Uuid::new_v4().to_string(),
            &current_generation,
        ));

        let same_generation_data = crate::jcs(&json!({
            "v": 1,
            "kind": "revisions",
            "vault_id": vault,
            "snapshot_id": snapshot,
            "generation": current_generation,
            "high_watermark": "1",
            "conflict_high_watermark": "1",
            "after": "0",
        }))
        .unwrap();
        let same_generation =
            URL_SAFE_NO_PAD.encode([same_generation_data, vec![0x5a; 32]].concat());
        assert!(!foreign_generation_history_cursor_claim(
            &same_generation,
            HistoryKind::Revisions,
            &vault,
            &snapshot,
            &current_generation,
        ));
        assert!(!foreign_generation_history_cursor_claim(
            &"A".repeat(MAX_SYNC_CURSOR_BYTES + 1),
            HistoryKind::Revisions,
            &vault,
            &snapshot,
            &current_generation,
        ));

        let noncanonical_sequence_data = crate::jcs(&json!({
            "v": 1,
            "kind": "revisions",
            "vault_id": vault,
            "snapshot_id": snapshot,
            "generation": cursor_generation,
            "high_watermark": "01",
            "conflict_high_watermark": "2",
            "after": "3",
        }))
        .unwrap();
        let noncanonical_sequence =
            URL_SAFE_NO_PAD.encode([noncanonical_sequence_data, vec![0x5a; 32]].concat());
        assert!(!foreign_generation_history_cursor_claim(
            &noncanonical_sequence,
            HistoryKind::Revisions,
            &vault,
            &snapshot,
            &current_generation,
        ));
    }

    #[tokio::test]
    async fn maintenance_prunes_contiguous_event_prefix_and_expired_payloads() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-history-test-{}", Uuid::new_v4()));
        let config = Config {
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
        let state = open_state(&database_url, config).await.unwrap();
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let created = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind("history@example.test")
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,3)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();

        let timestamps = [
            "2000-01-01T00:00:00+00:00",
            "2099-01-01T00:00:00+00:00",
            "2000-01-01T00:00:00+00:00",
        ];
        for (index, created_at) in timestamps.iter().enumerate() {
            let seq = (index + 1) as i64;
            let record = Uuid::new_v4().to_string();
            let revision = Uuid::new_v4().to_string();
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,'{}','digest',?,'device','create',?)")
                .bind(&vault)
                .bind(&record)
                .bind(&revision)
                .bind(seq)
                .bind(created_at)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,?,'create',?,?,'{}',?)")
                .bind(&vault)
                .bind(seq)
                .bind(&record)
                .bind(&revision)
                .bind(created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,'graveyard-record','deleted-rev',3)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();

        let snapshot_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation) VALUES(?,?,?,3,'[{\"encrypted\":true}]','2000-01-01T00:00:00+00:00',?,?)")
            .bind(&snapshot_id)
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        let upload = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,'object',1,'hash',1048576,'open','2000-01-01T00:00:00+00:00',?)")
            .bind(&upload)
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'01','hash')")
            .bind(&upload)
            .execute(&state.db)
            .await
            .unwrap();

        compact_expired_history(&state).await.unwrap();

        let rows = sqlx::query(
            "SELECT commit_seq FROM change_events WHERE vault_id=? ORDER BY commit_seq",
        )
        .bind(&vault)
        .fetch_all(&state.db)
        .await
        .unwrap();
        let sequences = rows
            .iter()
            .map(|row| row.get::<i64, _>("commit_seq"))
            .collect::<Vec<_>>();
        assert_eq!(sequences, vec![2, 3]);
        let floor: i64 =
            sqlx::query_scalar("SELECT minimum_available_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(floor, 2);
        let revisions: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_versions WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(revisions, 3, "immutable revision history remains available");
        let graveyard: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_graveyard WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(graveyard, 1);
        let manifest: String =
            sqlx::query_scalar("SELECT manifest_json FROM snapshots WHERE snapshot_id=?")
                .bind(&snapshot_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(manifest, "[]");
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&upload)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(upload_state, "expired");
        let chunks: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&upload)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(chunks, 0);

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn maintenance_payload_bookkeeping_rolls_back_as_one_transaction() {
        let (state, data_dir) = test_state("maintenance-bookkeeping-rollback").await;
        let user = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        insert_user_and_vault(&state, &user, &vault).await;
        let created = now_rfc3339();
        let snapshot_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation) VALUES(?,?,?,0,'[{\"encrypted\":true}]','2000-01-01T00:00:00+00:00',?,?)")
            .bind(&snapshot_id)
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        let upload_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,'rollback-object',1,'hash',1048576,'open','2000-01-01T00:00:00+00:00',?)")
            .bind(&upload_id)
            .bind(&vault)
            .bind(&user)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'01','hash')")
            .bind(&upload_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account',?,'maintenance.fixture','fixture','success',1,'maintenance')")
            .bind(&user)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("CREATE TRIGGER reject_audit_retention_cleanup BEFORE DELETE ON audit_events BEGIN SELECT RAISE(ABORT,'injected maintenance cleanup failure'); END")
            .execute(&state.db)
            .await
            .unwrap();

        assert!(compact_expired_history(&state).await.is_err());

        let manifest: String =
            sqlx::query_scalar("SELECT manifest_json FROM snapshots WHERE snapshot_id=?")
                .bind(&snapshot_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(manifest, "[{\"encrypted\":true}]");
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(upload_state, "open");
        let chunk_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(chunk_count, 1);
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE scope_id=? AND action='maintenance.fixture'",
        )
        .bind(&user)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 1);

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn sqlite_redaction_read_projections_sign_proofs_and_fail_closed_for_old_snapshots() {
        let (state, data_dir) = test_state("sqlite-redaction-read-side").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let first_revision = Uuid::new_v4().to_string();
        let deleted_revision = Uuid::new_v4().to_string();
        let redaction_id = Uuid::new_v4().to_string();
        let conflict_id = Uuid::new_v4().to_string();
        let old_snapshot_id = Uuid::new_v4().to_string();
        let invalidated_snapshot_id = Uuid::new_v4().to_string();
        let token = format!("sqlite-redaction-read-{}", Uuid::new_v4());
        let created_at = now_rfc3339();
        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'reader','test-signing-key','test-encryption-key',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind((chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,3,2)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,2)")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        for (revision_id, operation, seq) in [
            (first_revision.as_str(), "create", 1_i64),
            (deleted_revision.as_str(), "delete", 2_i64),
        ] {
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,NULL,'{\"ciphertext\":\"must-not-leak\"}','digest',?,?,?,?)")
                .bind(&vault_id)
                .bind(&record_id)
                .bind(revision_id)
                .bind(seq)
                .bind(&device_id)
                .bind(operation)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope) VALUES(?,?,? ,?,?,'{\"ciphertext\":\"must-not-leak\"}')")
                .bind(&vault_id)
                .bind(seq)
                .bind(operation)
                .bind(&record_id)
                .bind(revision_id)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope) VALUES(?,3,'record_redacted',?,?,'null')")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&redaction_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,resolved_revision_id,conflict_seq,resolution_seq,resolution_at) VALUES(?,?,?,?, '{\"ciphertext\":\"conflict-must-not-leak\"}','digest',?,?,?,1,2,?)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&first_revision)
            .bind(&device_id)
            .bind(&created_at)
            .bind(&deleted_revision)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,2,3,?)")
            .bind(&redaction_id)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        let invalid_record_id = Uuid::new_v4().to_string();
        let invalid_revision_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,3)")
            .bind(&vault_id)
            .bind(&invalid_record_id)
            .bind(&invalid_revision_id)
            .execute(&state.db)
            .await
            .unwrap();
        let invalid_redaction = sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,3,3,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(&invalid_record_id)
            .bind(&invalid_revision_id)
            .bind(&created_at)
            .execute(&state.db)
            .await;
        assert!(
            invalid_redaction.is_err(),
            "redaction sequence must follow its deleted revision sequence"
        );

        // A snapshot captured before redaction is denied even if a writer
        // failed to persist the explicit invalidation timestamp.
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark,manifest_json,snapshot_item_count,snapshot_manifest_format,expires_at,created_at,server_generation) VALUES(?,?,?,2,2,'[]',1,'paged',?,?,?)")
            .bind(&old_snapshot_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created_at)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE snapshots SET manifest_json='not-json' WHERE snapshot_id=?")
            .bind(&old_snapshot_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES(?,?,?)")
            .bind(&old_snapshot_id)
            .bind(&record_id)
            .bind(json!({"kind":"head","record_id":record_id,"revision_id":deleted_revision,"envelope":{"ciphertext":"must-not-leak"}}).to_string())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark,manifest_json,snapshot_item_count,snapshot_manifest_format,expires_at,created_at,server_generation,redacted_at) VALUES(?,?,?,3,2,'[]',0,'inline',?,?,?,?)")
            .bind(&invalidated_snapshot_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created_at)
            .bind(&state.instance.generation)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        let capable_user = crate::auth::AuthUser {
            user_id: user_id.clone(),
            device_id: device_id.clone(),
            session_id: session_id.clone(),
            access_hash: crate::sha256_hex(token.as_bytes()),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let old_snapshot_error = state
            .sync_repository
            .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
                user: capable_user.clone(),
                snapshot_id: old_snapshot_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
                page: Some(crate::sync_repository::SnapshotPageRequest {
                    limit: 10,
                    page_cursor: None,
                }),
            })
            .await
            .unwrap_err();
        assert_eq!(old_snapshot_error.status, StatusCode::GONE);
        assert_eq!(old_snapshot_error.body.code, "SNAPSHOT_REDACTED");
        let old_history_error = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: old_snapshot_id,
                kind: HistoryKind::Revisions,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap_err();
        assert_eq!(old_history_error.status, StatusCode::GONE);
        assert_eq!(old_history_error.body.code, "SNAPSHOT_REDACTED");
        let invalidated_snapshot_error = state
            .sync_repository
            .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
                user: capable_user.clone(),
                snapshot_id: invalidated_snapshot_id,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
                page: None,
            })
            .await
            .unwrap_err();
        assert_eq!(invalidated_snapshot_error.status, StatusCode::GONE);
        assert_eq!(invalidated_snapshot_error.body.code, "SNAPSHOT_REDACTED");

        let created_snapshot = state
            .sync_repository
            .create_snapshot(crate::sync_repository::CreateSnapshotCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        let snapshot_id = created_snapshot["snapshot_id"].as_str().unwrap().to_owned();
        let snapshot = state
            .sync_repository
            .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
                user: capable_user.clone(),
                snapshot_id: snapshot_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
                page: None,
            })
            .await
            .unwrap();
        assert_eq!(snapshot["manifest"].as_array().unwrap().len(), 1);
        let graveyard = &snapshot["manifest"][0];
        assert_eq!(graveyard["kind"], "graveyard");
        assert_eq!(graveyard["record_id"], record_id);
        assert_eq!(graveyard["deleted_revision_id"], deleted_revision);
        assert_eq!(graveyard["deleted_seq"], "2");
        let proof = graveyard["redaction"].clone();
        assert_eq!(proof["redaction_id"], redaction_id);
        assert_redaction_proof_signature(&proof);

        let changes = state
            .sync_repository
            .read_changes_page(crate::sync_repository::ChangesPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                raw_cursor: None,
                limit: 10,
                cursor_key: *state.cursor_key,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        let events = changes["events"].as_array().unwrap();
        assert_eq!(events.len(), 3);
        for (index, event) in events.iter().enumerate() {
            assert_eq!(event["commit_seq"], (index + 1).to_string());
            assert_eq!(event["event_type"], "record_redacted");
            assert_eq!(event["record_id"], record_id);
            assert_eq!(event.as_object().unwrap().len(), 4);
            assert!(event.get("envelope").is_none());
            assert!(event.get("revision_id").is_none());
            assert_eq!(event["redaction"], proof);
        }

        let feed = state
            .sync_repository
            .read_conflict_changes_page(crate::sync_repository::ConflictChangesPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                after_seq: 0,
                after_seq_wire: "0".to_owned(),
                limit: 10,
                server_generation: None,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        let feed_events = feed["events"].as_array().unwrap();
        assert_eq!(feed_events.len(), 2);
        for (index, event) in feed_events.iter().enumerate() {
            assert_eq!(event["seq"], (index + 1).to_string());
            assert_eq!(event["type"], "redacted");
            assert_eq!(event["conflict_id"], conflict_id);
            assert_eq!(event["record_id"], record_id);
            assert_eq!(event.as_object().unwrap().len(), 5);
            assert!(event.get("envelope").is_none());
            assert!(event.get("resolved_revision_id").is_none());
            assert_eq!(event["redaction"], proof);
        }

        let revisions = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: snapshot_id.clone(),
                kind: HistoryKind::Revisions,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        for (index, revision) in revisions["revisions"]
            .as_array()
            .unwrap()
            .iter()
            .enumerate()
        {
            assert_eq!(revision["commit_seq"], (index + 1).to_string());
            assert_eq!(revision["operation"], "redacted");
            assert_eq!(revision["envelope"], Value::Null);
            assert_eq!(revision["restore_until"], Value::Null);
            assert_eq!(revision.as_object().unwrap().len(), 10);
            assert_eq!(revision["redaction"], proof);
        }

        let conflicts = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: snapshot_id.clone(),
                kind: HistoryKind::Conflicts,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        let conflict = &conflicts["conflicts"][0];
        assert_eq!(conflict["resolved_revision_id"], Value::Null);
        assert_eq!(conflict["envelope"], Value::Null);
        assert_eq!(conflict["redaction"], proof);
        assert_eq!(conflict.as_object().unwrap().len(), 9);

        let direct_revision_error = state
            .sync_repository
            .read_revision(crate::sync_repository::ReadRevisionCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                revision_id: first_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(direct_revision_error.status, StatusCode::GONE);
        assert_eq!(direct_revision_error.body.code, "RECORD_REDACTED");
        assert_eq!(
            direct_revision_error.body.details.unwrap()["redaction"],
            proof
        );

        let retained_mapping: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_redacted_revisions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&first_revision)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(retained_mapping, 1);
        sqlx::query(
            "DELETE FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&first_revision)
        .execute(&state.db)
        .await
        .unwrap();
        let payloadless_revision_error = state
            .sync_repository
            .read_revision(crate::sync_repository::ReadRevisionCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                revision_id: first_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(payloadless_revision_error.status, StatusCode::GONE);
        assert_eq!(payloadless_revision_error.body.code, "RECORD_REDACTED");
        assert_eq!(
            payloadless_revision_error.body.details.unwrap()["redaction"],
            proof
        );

        // Legacy storage permits a live record and a scrubbed record to have
        // the same revision ID. The durable index must take precedence over
        // returning the other record's still-present envelope.
        let live_duplicate_record_id = Uuid::new_v4().to_string();
        let live_duplicate_envelope = "{\"ciphertext\":\"live-duplicate-must-not-leak\"}";
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?,?,?,NULL,?,'digest',4,?,'create',?)")
            .bind(&vault_id)
            .bind(&live_duplicate_record_id)
            .bind(&first_revision)
            .bind(live_duplicate_envelope)
            .bind(&device_id)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        let ambiguous_redacted_revision_error = state
            .sync_repository
            .read_revision(crate::sync_repository::ReadRevisionCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                revision_id: first_revision,
            })
            .await
            .unwrap_err();
        assert_eq!(
            ambiguous_redacted_revision_error.status,
            StatusCode::INTERNAL_SERVER_ERROR
        );
        assert_eq!(ambiguous_redacted_revision_error.body.code, "INTERNAL");
        assert!(
            !ambiguous_redacted_revision_error
                .body
                .message
                .contains("live-duplicate-must-not-leak")
        );

        // Replays and all sync payload writes are rejected after redaction,
        // but the Vault-wide marker remains the first compatibility gate.
        let make_redacted_operation = |operation: &str| super::VerifiedOperation {
            record_id: record_id.clone(),
            revision_id: Uuid::new_v4().to_string(),
            op_id: Uuid::new_v4().to_string(),
            record_schema: 1,
            device_seq: "7".to_owned(),
            key_epoch: 1,
            membership_version: 1,
            operation: operation.to_owned(),
            base: (operation == "restore").then(|| deleted_revision.clone()),
            object_refs: Vec::new(),
            env: Envelope {
                header: json!({}),
                nonce: String::new(),
                ciphertext: String::new(),
                signature: String::new(),
            },
        };
        let replay_batch_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES(?,?,?,'redacted-replay','{\"results\":[]}')")
            .bind(&vault_id)
            .bind(&device_id)
            .bind(&replay_batch_id)
            .execute(&state.db)
            .await
            .unwrap();
        let markerless_push = state
            .sync_repository
            .commit_batch(crate::sync_repository::PushCommit {
                user: crate::auth::AuthUser {
                    declares_sync_redaction_v1: false,
                    ..capable_user.clone()
                },
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                batch_id: replay_batch_id.clone(),
                request_digest: "redacted-replay".to_owned(),
                operations: vec![make_redacted_operation("create")],
                restore_retention_days: 30,
            })
            .await
            .unwrap_err();
        assert_eq!(markerless_push.status, StatusCode::UPGRADE_REQUIRED);
        let markerless_push_create_error = state
            .sync_repository
            .commit_batch(crate::sync_repository::PushCommit {
                user: crate::auth::AuthUser {
                    declares_sync_redaction_v1: false,
                    ..capable_user.clone()
                },
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                batch_id: Uuid::new_v4().to_string(),
                request_digest: "markerless-create".to_owned(),
                operations: vec![make_redacted_operation("create")],
                restore_retention_days: 30,
            })
            .await
            .unwrap_err();
        assert_eq!(
            markerless_push_create_error.status,
            StatusCode::UPGRADE_REQUIRED
        );
        let capable_push_replay_error = state
            .sync_repository
            .commit_batch(crate::sync_repository::PushCommit {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                batch_id: replay_batch_id,
                request_digest: "redacted-replay".to_owned(),
                operations: vec![make_redacted_operation("create")],
                restore_retention_days: 30,
            })
            .await
            .unwrap_err();
        assert_eq!(capable_push_replay_error.status, StatusCode::CONFLICT);
        assert_eq!(capable_push_replay_error.body.code, "RECORD_REDACTED");
        let capable_restore_error = state
            .sync_repository
            .commit_batch(crate::sync_repository::PushCommit {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                batch_id: Uuid::new_v4().to_string(),
                request_digest: "redacted-restore".to_owned(),
                operations: vec![make_redacted_operation("restore")],
                restore_retention_days: 30,
            })
            .await
            .unwrap_err();
        assert_eq!(capable_restore_error.status, StatusCode::CONFLICT);
        assert_eq!(capable_restore_error.body.code, "RECORD_REDACTED");

        let replay_conflict_op = "redacted-conflict-op";
        sqlx::query("UPDATE conflicts SET op_id=?,digest='redacted-conflict-digest',device_id=? WHERE conflict_id=?")
            .bind(replay_conflict_op)
            .bind(&device_id)
            .bind(&conflict_id)
            .execute(&state.db)
            .await
            .unwrap();
        let make_redacted_conflict = |user| crate::sync_repository::CreateConflictCommand {
            user,
            vault_id: vault_id.clone(),
            device_id: device_id.clone(),
            conflict_id: Uuid::new_v4().to_string(),
            request_digest: "redacted-conflict-digest".to_owned(),
            envelope_json: "{\"ciphertext\":\"must-not-store\"}".to_owned(),
            operation: make_redacted_operation("create"),
        };
        let markerless_conflict_error = state
            .sync_repository
            .create_conflict(make_redacted_conflict(crate::auth::AuthUser {
                declares_sync_redaction_v1: false,
                ..capable_user.clone()
            }))
            .await
            .unwrap_err();
        assert_eq!(
            markerless_conflict_error.status,
            StatusCode::UPGRADE_REQUIRED
        );
        let conflict_replay_error = state
            .sync_repository
            .create_conflict(make_redacted_conflict(capable_user.clone()))
            .await
            .unwrap_err();
        assert_eq!(conflict_replay_error.status, StatusCode::CONFLICT);
        assert_eq!(conflict_replay_error.body.code, "RECORD_REDACTED");

        let markerless_resolve_error = state
            .sync_repository
            .resolve_conflict(crate::sync_repository::ResolveConflictCommand {
                user: crate::auth::AuthUser {
                    declares_sync_redaction_v1: false,
                    ..capable_user.clone()
                },
                vault_id: vault_id.clone(),
                conflict_id: conflict_id.clone(),
                resolved_revision_id: deleted_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(
            markerless_resolve_error.status,
            StatusCode::UPGRADE_REQUIRED
        );
        let resolve_replay_error = state
            .sync_repository
            .resolve_conflict(crate::sync_repository::ResolveConflictCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                conflict_id: conflict_id.clone(),
                resolved_revision_id: deleted_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(resolve_replay_error.status, StatusCode::CONFLICT);
        assert_eq!(resolve_replay_error.body.code, "RECORD_REDACTED");
        let unchanged_counters: (i64, i64) = sqlx::query_as(
            "SELECT last_committed_seq,last_conflict_seq FROM vault_counters WHERE vault_id=?",
        )
        .bind(&vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(unchanged_counters, (3, 2));
        let conflicts_after_redacted_writes: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM conflicts WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(conflicts_after_redacted_writes, 1);

        let legacy_user = crate::auth::AuthUser {
            declares_sync_redaction_v1: false,
            ..capable_user.clone()
        };
        let legacy_error = state
            .sync_repository
            .read_changes_page(crate::sync_repository::ChangesPageCommand {
                user: legacy_user,
                vault_id: vault_id.clone(),
                raw_cursor: None,
                limit: 10,
                cursor_key: *state.cursor_key,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap_err();
        assert_eq!(legacy_error.status, StatusCode::UPGRADE_REQUIRED);
        assert_eq!(
            legacy_error.body.code,
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        let mut legacy_user = capable_user.clone();
        legacy_user.declares_sync_redaction_v1 = false;
        let conflicts_before: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM conflicts WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let create_conflict_error = state
            .sync_repository
            .create_conflict(crate::sync_repository::CreateConflictCommand {
                user: legacy_user.clone(),
                vault_id: vault_id.clone(),
                device_id: device_id.clone(),
                conflict_id: Uuid::new_v4().to_string(),
                request_digest: "digest-new-conflict".to_owned(),
                envelope_json: "{}".to_owned(),
                operation: super::VerifiedOperation {
                    record_id: Uuid::new_v4().to_string(),
                    revision_id: Uuid::new_v4().to_string(),
                    op_id: Uuid::new_v4().to_string(),
                    record_schema: 1,
                    device_seq: "1".to_owned(),
                    key_epoch: 1,
                    membership_version: 1,
                    operation: "create".to_owned(),
                    base: None,
                    object_refs: Vec::new(),
                    env: Envelope {
                        header: json!({}),
                        nonce: String::new(),
                        ciphertext: String::new(),
                        signature: String::new(),
                    },
                },
            })
            .await
            .unwrap_err();
        assert_eq!(create_conflict_error.status, StatusCode::UPGRADE_REQUIRED);
        let resolve_conflict_error = state
            .sync_repository
            .resolve_conflict(crate::sync_repository::ResolveConflictCommand {
                user: legacy_user.clone(),
                vault_id: vault_id.clone(),
                conflict_id: conflict_id.clone(),
                resolved_revision_id: deleted_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(resolve_conflict_error.status, StatusCode::UPGRADE_REQUIRED);
        let conflicts_after: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM conflicts WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(conflicts_after, conflicts_before);

        let app = Router::new()
            .route(
                "/api/v1/vaults/{vault_id}/changes",
                axum::routing::get(super::changes),
            )
            .with_state(state.clone());
        let http_error = app
            .oneshot(
                Request::builder()
                    .uri(format!("/api/v1/vaults/{vault_id}/changes"))
                    .header(AUTHORIZATION, format!("Bearer {token}"))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(http_error.status(), StatusCode::UPGRADE_REQUIRED);
        let http_error_body: Value = serde_json::from_slice(
            &http_body_util::BodyExt::collect(http_error.into_body())
                .await
                .unwrap()
                .to_bytes(),
        )
        .unwrap();
        assert_eq!(
            http_error_body["error"]["code"],
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        drop(state);
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    #[tokio::test]
    async fn sqlite_owner_purge_scrubs_payloads_preserves_order_and_is_idempotent() {
        let (mut state, data_dir) = test_state("sqlite-record-purge").await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let unsupported_device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let live_record_id = Uuid::new_v4().to_string();
        let created_revision = Uuid::new_v4().to_string();
        let deleted_revision = Uuid::new_v4().to_string();
        let live_revision = Uuid::new_v4().to_string();
        let conflict_revision = Uuid::new_v4().to_string();
        let conflict_id = Uuid::new_v4().to_string();
        let old_snapshot_id = Uuid::new_v4().to_string();
        let shared_object_id = Uuid::new_v4().to_string();
        let collectible_object_id = Uuid::new_v4().to_string();
        let collectible_upload_id = Uuid::new_v4().to_string();
        let token = format!("record-purge-{}", Uuid::new_v4());
        let now = chrono::Utc::now();
        let created_at = now.to_rfc3339();
        let deleted_at = (now - chrono::Duration::days(40)).to_rfc3339();
        let owner_key = SigningKey::from_bytes(&[121; 32]);
        let unsupported_key = SigningKey::from_bytes(&[122; 32]);
        let signing_public = URL_SAFE_NO_PAD.encode(owner_key.verifying_key().as_bytes());
        let unsupported_public = URL_SAFE_NO_PAD.encode(unsupported_key.verifying_key().as_bytes());

        insert_user_and_vault(&state, &user_id, &vault_id).await;
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        for (device, public) in [
            (&device_id, &signing_public),
            (&unsupported_device_id, &unsupported_public),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'purge-test',?,'encryption-key',?)")
                .bind(device)
                .bind(&user_id)
                .bind(public)
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind(crate::sha256_hex(Uuid::new_v4().to_string().as_bytes()))
            .bind((now + chrono::Duration::hours(1)).to_rfc3339())
            .bind((now + chrono::Duration::days(1)).to_rfc3339())
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,3,2)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        let capability_payload = |device: &str| {
            json!({
                "format":crate::redaction_capabilities::REPORT_FORMAT,
                "account_id":user_id.clone(),
                "device_id":device,
                "revision":1,
                "sync_redaction_version":1,
            })
        };
        let owner_report = capability_payload(&device_id);
        let owner_signature = URL_SAFE_NO_PAD.encode(
            owner_key
                .sign(&crate::jcs(&owner_report).unwrap())
                .to_bytes(),
        );
        sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,user_id,revision,sync_redaction_version,signature,updated_at) VALUES(?,?,1,1,?,?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&owner_signature)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        // Seed the current tombstone, one still-live record, and a resolved
        // conflict branch. The shared object must remain reachable; objects
        // referenced only by this record must receive the ordinary GC grace.
        for (id, object_id) in [
            (&created_revision, &shared_object_id),
            (&deleted_revision, &collectible_object_id),
            (&live_revision, &shared_object_id),
            (&conflict_revision, &collectible_object_id),
        ] {
            sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,x'01',1,?,?) ON CONFLICT(vault_id,object_id) DO NOTHING")
                .bind(&vault_id)
                .bind(object_id)
                .bind(format!("digest-{object_id}"))
                .bind(&created_at)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query(
                "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)",
            )
            .bind(&vault_id)
            .bind(id)
            .bind(object_id)
            .execute(&state.db)
            .await
            .unwrap();
        }
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,1,?,1048576,'completed',?,?)")
            .bind(&collectible_upload_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&collectible_object_id)
            .bind("a".repeat(64))
            .bind((now + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,2)")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        for (record, revision, seq, operation, time) in [
            (&record_id, &created_revision, 1_i64, "create", &created_at),
            (&record_id, &deleted_revision, 2_i64, "delete", &deleted_at),
            (
                &live_record_id,
                &live_revision,
                3_i64,
                "create",
                &created_at,
            ),
        ] {
            let restore_until = if operation == "delete" {
                Some(
                    (chrono::DateTime::parse_from_rfc3339(time)
                        .unwrap()
                        .with_timezone(&chrono::Utc)
                        + chrono::Duration::days(30))
                    .to_rfc3339(),
                )
            } else {
                None
            };
            let envelope = json!({
                "header":{"revision_id":revision},"nonce":"n","ciphertext":"secret","signature":"s"
            });
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at,restore_until) VALUES(?,?,?,NULL,?,'digest',?,?,?,?,?)")
                .bind(&vault_id)
                .bind(record)
                .bind(revision)
                .bind(envelope.to_string())
                .bind(seq)
                .bind(&device_id)
                .bind(operation)
                .bind(time)
                .bind(restore_until)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES(?,?,?,?,?,?,?)")
                .bind(&vault_id)
                .bind(seq)
                .bind(operation)
                .bind(record)
                .bind(revision)
                .bind(envelope.to_string())
                .bind(time)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,1,2)")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,0,3)")
            .bind(&vault_id)
            .bind(&live_record_id)
            .bind(&live_revision)
            .execute(&state.db)
            .await
            .unwrap();
        let conflict_envelope = json!({
            "header":{"revision_id":conflict_revision,"op_id":Uuid::new_v4().to_string()},
            "nonce":"n","ciphertext":"conflict-secret","signature":"s"
        });
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,resolved_revision_id,conflict_seq,resolution_seq,resolution_at,op_id) VALUES(?,?,?,?,?,'digest',?,?,?,?,?,?,?)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&created_revision)
            .bind(conflict_envelope.to_string())
            .bind(&device_id)
            .bind(&created_at)
            .bind(&deleted_revision)
            .bind(1_i64)
            .bind(2_i64)
            .bind(&created_at)
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark,manifest_json,snapshot_item_count,snapshot_manifest_format,expires_at,created_at,server_generation) VALUES(?,?,?,3,2,?,1,'paged',?,?,?)")
            .bind(&old_snapshot_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind(json!([{"kind":"head","record_id":record_id,"envelope":{"ciphertext":"snapshot-secret"}}]).to_string())
            .bind((now + chrono::Duration::hours(1)).to_rfc3339())
            .bind(&created_at)
            .bind(&state.instance.generation)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES(?,?,?)")
            .bind(&old_snapshot_id)
            .bind(&record_id)
            .bind(json!({"kind":"head","record_id":record_id,"envelope":{"ciphertext":"snapshot-secret"}}).to_string())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) VALUES(?,?,?,'1','digest',?,?,2)")
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&device_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) VALUES(?,?,?,'digest','{}')")
            .bind(&vault_id)
            .bind(&device_id)
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();

        // Simulate an instance policy change after deletion. The test row
        // retains its original absolute deadline below.
        Arc::make_mut(&mut state.config).record_restore_retention_days = 1;
        let route = Router::new()
            .route(
                "/api/v1/vaults/{vault_id}/records/{record_id}/purge",
                post(super::purge_record),
            )
            .route(
                "/api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge",
                put(super::update_automatic_purge_policy),
            )
            .with_state(state.clone());
        let send_purge = |router: Router, revision_id: String, deleted_seq: String| {
            let body = json!({
                "expected_deleted_revision_id":revision_id,
                "expected_deleted_seq":deleted_seq,
            })
            .to_string();
            let token = token.clone();
            let vault_id = vault_id.clone();
            let record_id = record_id.clone();
            async move {
                router
                    .oneshot(
                        Request::builder()
                            .method("POST")
                            .uri(format!(
                                "/api/v1/vaults/{vault_id}/records/{record_id}/purge"
                            ))
                            .header(AUTHORIZATION, format!("Bearer {token}"))
                            .header("x-atermius-redaction-marker", "v1")
                            .header(CONTENT_TYPE, "application/json")
                            .body(Body::from(body))
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            }
        };

        let send_auto_purge = |router: Router, enabled: bool, policy_revision: String| {
            let token = token.clone();
            let vault_id = vault_id.clone();
            let record_id = record_id.clone();
            let deleted_revision = deleted_revision.clone();
            async move {
                router
                    .oneshot(
                        Request::builder()
                            .method("PUT")
                            .uri(format!(
                                "/api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge"
                            ))
                            .header(AUTHORIZATION, format!("Bearer {token}"))
                            .header("x-atermius-redaction-marker", "v1")
                            .header(CONTENT_TYPE, "application/json")
                            .body(Body::from(
                                json!({
                                    "expected_deleted_revision_id":deleted_revision,
                                    "expected_deleted_seq":"2",
                                    "expected_policy_revision":policy_revision,
                                    "enabled":enabled,
                                })
                                .to_string(),
                            ))
                            .unwrap(),
                    )
                    .await
                    .unwrap()
            }
        };

        let enabled = send_auto_purge(route.clone(), true, "0".to_owned()).await;
        assert_eq!(enabled.status(), StatusCode::OK);
        let enabled_body = response_json(enabled).await;
        assert_eq!(enabled_body["enabled"], true);
        assert_eq!(enabled_body["policy_revision"], "1");
        let no_op = send_auto_purge(route.clone(), true, "1".to_owned()).await;
        assert_eq!(no_op.status(), StatusCode::OK);
        assert_eq!(response_json(no_op).await["policy_revision"], "1");
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=? \
             AND action='vault.record_auto_purge_opt_in_changed' AND resource_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            audit_count, 1,
            "an unchanged policy must not duplicate audit"
        );
        let stale = send_auto_purge(route.clone(), false, "0".to_owned()).await;
        assert_eq!(stale.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(stale).await["error"]["code"],
            "RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT"
        );
        let disabled = send_auto_purge(route.clone(), false, "1".to_owned()).await;
        assert_eq!(disabled.status(), StatusCode::OK);
        let disabled_body = response_json(disabled).await;
        assert_eq!(disabled_body["enabled"], false);
        assert_eq!(disabled_body["policy_revision"], "2");
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=? \
             AND action='vault.record_auto_purge_opt_in_changed' AND resource_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 2, "both state transitions must be audited");

        // A currently active device without a verified report blocks purge.
        let incompatible =
            send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(incompatible.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(incompatible).await["error"]["code"],
            "VAULT_REDACTION_CAPABILITY_REQUIRED"
        );
        let unsupported_report = capability_payload(&unsupported_device_id);
        let unsupported_signature = URL_SAFE_NO_PAD.encode(
            unsupported_key
                .sign(&crate::jcs(&unsupported_report).unwrap())
                .to_bytes(),
        );
        sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,user_id,revision,sync_redaction_version,signature,updated_at) VALUES(?,?,1,1,?,?)")
            .bind(&unsupported_device_id)
            .bind(&user_id)
            .bind(&unsupported_signature)
            .bind(&created_at)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("UPDATE vault_members SET role='editor' WHERE vault_id=? AND user_id=?")
            .bind(&vault_id)
            .bind(&user_id)
            .execute(&state.db)
            .await
            .unwrap();
        let non_owner = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(non_owner.status(), StatusCode::FORBIDDEN);
        assert_eq!(
            response_json(non_owner).await["error"]["code"],
            "VAULT_OWNER_REQUIRED"
        );
        sqlx::query("UPDATE vault_members SET role='owner' WHERE vault_id=? AND user_id=?")
            .bind(&vault_id)
            .bind(&user_id)
            .execute(&state.db)
            .await
            .unwrap();

        let wrong_tombstone =
            send_purge(route.clone(), Uuid::new_v4().to_string(), "2".to_owned()).await;
        assert_eq!(wrong_tombstone.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(wrong_tombstone).await["error"]["code"],
            "RECORD_DELETE_CHANGED"
        );
        let sequence_after_wrong_tombstone: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(sequence_after_wrong_tombstone, 3);

        // The persisted absolute deadline remains authoritative for purge
        // eligibility even though the current policy is now one day.
        let future_restore_until = (now + chrono::Duration::days(30)).to_rfc3339();
        sqlx::query("UPDATE record_versions SET created_at=?,restore_until=? WHERE vault_id=? AND record_id=? AND revision_id=?")
            .bind(&created_at)
            .bind(&future_restore_until)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        let too_early = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(too_early.status(), StatusCode::CONFLICT);
        let too_early_body = response_json(too_early).await;
        assert_eq!(too_early_body["error"]["code"], "RECORD_PURGE_NOT_DUE");
        assert!(too_early_body["error"]["details"]["restore_until"].is_string());
        let expired_restore_until = (now - chrono::Duration::days(10)).to_rfc3339();
        sqlx::query("UPDATE record_versions SET created_at=?,restore_until=? WHERE vault_id=? AND record_id=? AND revision_id=?")
            .bind(&deleted_at)
            .bind(&expired_restore_until)
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();

        // A conflict branch remains user work even when the main head is a
        // tombstone. Resolve it explicitly before the purge is retried.
        sqlx::query("UPDATE conflicts SET resolved_revision_id=NULL,resolution_seq=NULL,resolution_at=NULL WHERE conflict_id=?")
            .bind(&conflict_id)
            .execute(&state.db)
            .await
            .unwrap();
        let unresolved = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(unresolved.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(unresolved).await["error"]["code"],
            "RECORD_HAS_UNRESOLVED_CONFLICTS"
        );
        sqlx::query("UPDATE conflicts SET resolved_revision_id=?,resolution_seq=2,resolution_at=? WHERE conflict_id=?")
            .bind(&deleted_revision)
            .bind(&created_at)
            .bind(&conflict_id)
            .execute(&state.db)
            .await
            .unwrap();

        // Legacy object references are keyed by revision ID without a record
        // owner. A colliding ID on another retained record must fail closed
        // before the purge allocates a sequence or removes any reference.
        let foreign_record_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest, \
                 commit_seq,device_id,operation,created_at \
             ) VALUES(?,?,?,NULL,'{}','foreign-digest',99,?,'create',?)",
        )
        .bind(&vault_id)
        .bind(&foreign_record_id)
        .bind(&created_revision)
        .bind(&device_id)
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
        let references_before_ambiguous: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM object_references WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let ambiguous = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(ambiguous.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(ambiguous).await["error"]["code"],
            "REDACTION_REFERENCE_AMBIGUOUS"
        );
        let sequence_after_ambiguous: i64 =
            sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(sequence_after_ambiguous, 3);
        let references_after_ambiguous: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM object_references WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(references_after_ambiguous, references_before_ambiguous);
        sqlx::query("DELETE FROM record_versions WHERE vault_id=? AND record_id=?")
            .bind(&vault_id)
            .bind(&foreign_record_id)
            .execute(&state.db)
            .await
            .unwrap();

        // Purge must wake other enrolled Vault devices through the durable
        // mobile push outbox, but must not enqueue a hint back to its source.
        for (endpoint_id, endpoint_device_id, token_hash) in [
            ("purge-source-endpoint", &device_id, "a".repeat(64)),
            (
                "purge-peer-endpoint",
                &unsupported_device_id,
                "b".repeat(64),
            ),
        ] {
            sqlx::query(
                "INSERT INTO notification_push_endpoints( \
                    endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at \
                 ) VALUES(?,?,?,'apns',?,?,?,?)",
            )
            .bind(endpoint_id)
            .bind(endpoint_device_id)
            .bind(&user_id)
            .bind(token_hash)
            .bind("x".repeat(80))
            .bind(now.timestamp())
            .bind(now.timestamp())
            .execute(&state.db)
            .await
            .unwrap();
        }

        let result = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(result.status(), StatusCode::OK);
        let result = response_json(result).await;
        assert_eq!(result["status"], "purged");
        assert_eq!(result["already_purged"], false);
        let proof = result["redaction"].clone();
        assert_eq!(proof["record_id"], record_id);
        assert_eq!(proof["deleted_revision_id"], deleted_revision);
        assert_eq!(proof["deleted_seq"], "2");
        assert_eq!(proof["redaction_seq"], "4");
        assert_redaction_proof_signature(&proof);

        let owner_purge_audit: (Option<String>, Option<String>, String, i64) = sqlx::query_as(
            "SELECT actor_user_id,actor_device_id,source,COUNT(*) \
             FROM audit_events WHERE scope_type='vault' AND scope_id=? \
               AND action='vault.record_purged' AND resource_id=? \
             GROUP BY actor_user_id,actor_device_id,source",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            owner_purge_audit,
            (
                Some(user_id.clone()),
                Some(device_id.clone()),
                "api".to_owned(),
                1,
            ),
            "Owner purge must write exactly one API audit row with the authenticated identity"
        );

        let source_push: Option<i64> = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-source-endpoint'",
        )
        .fetch_optional(&state.db)
        .await
        .unwrap();
        let peer_push: Option<i64> = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-peer-endpoint'",
        )
        .fetch_optional(&state.db)
        .await
        .unwrap();
        assert_eq!(source_push, None, "purge must exclude its source device");
        assert_eq!(
            peer_push,
            Some(1),
            "purge must durably wake the peer device"
        );

        let tombstone_head: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_heads WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(tombstone_head, 0);
        let graveyard: (String, i64) = sqlx::query_as(
            "SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(graveyard, (deleted_revision.clone(), 2));
        let scrubbed_revisions: Vec<(String, String, String)> = sqlx::query_as(
            "SELECT envelope,digest,operation FROM record_versions WHERE vault_id=? AND record_id=? ORDER BY commit_seq",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(scrubbed_revisions.len(), 2);
        assert!(
            scrubbed_revisions
                .iter()
                .all(|row| row.0 == "{}" && row.1.is_empty())
        );
        assert_eq!(scrubbed_revisions[0].2, "create");
        assert_eq!(scrubbed_revisions[1].2, "delete");
        let scrubbed_events: Vec<(i64, String, String)> = sqlx::query_as(
            "SELECT commit_seq,event_type,envelope FROM change_events WHERE vault_id=? AND record_id=? ORDER BY commit_seq",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(scrubbed_events.len(), 3);
        assert!(
            scrubbed_events[..2]
                .iter()
                .all(|row| row.1 == "redacted" && row.2 == "{}")
        );
        assert_eq!(scrubbed_events[2].1, "record_redacted");
        assert_eq!(scrubbed_events[2].2, "{}");
        let scrubbed_conflict: (String, Option<String>, Option<String>, String, String, Option<String>) = sqlx::query_as(
            "SELECT envelope,base_revision_id,resolved_revision_id,digest,device_id,op_id FROM conflicts WHERE conflict_id=?",
        )
        .bind(&conflict_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            scrubbed_conflict,
            (
                "{}".to_owned(),
                None,
                None,
                String::new(),
                String::new(),
                None
            )
        );

        let indexed_ids: Vec<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_redacted_revisions WHERE vault_id=? AND record_id=? ORDER BY revision_id",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_all(&state.db)
        .await
        .unwrap();
        assert_eq!(indexed_ids.len(), 3);
        assert!(indexed_ids.contains(&created_revision));
        assert!(indexed_ids.contains(&deleted_revision));
        assert!(indexed_ids.contains(&conflict_revision));
        let preserved_receipts: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM op_receipts WHERE vault_id=?),\
                    (SELECT COUNT(*) FROM batch_receipts WHERE vault_id=?)",
        )
        .bind(&vault_id)
        .bind(&vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(preserved_receipts, (1, 1));
        let object_state: (Option<i64>, Option<i64>, i64) = sqlx::query_as(
            "SELECT collectible.gc_after,shared.gc_after, \
                    (SELECT COUNT(*) FROM object_references WHERE vault_id=? AND object_id=?) \
             FROM blob_objects collectible JOIN blob_objects shared ON shared.vault_id=collectible.vault_id \
             WHERE collectible.vault_id=? AND collectible.object_id=? AND shared.object_id=?",
        )
        .bind(&vault_id)
        .bind(&shared_object_id)
        .bind(&vault_id)
        .bind(&collectible_object_id)
        .bind(&shared_object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(object_state.0.unwrap() > chrono::Utc::now().timestamp());
        assert_eq!(object_state.1, None);
        assert_eq!(object_state.2, 1);
        let revoked_upload_retries: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM uploads WHERE vault_id=? AND object_id=? AND state='collected'",
        )
        .bind(&vault_id)
        .bind(&collectible_object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(revoked_upload_retries, 1);
        let old_snapshot: (String, i64, String, Option<String>) = sqlx::query_as(
            "SELECT manifest_json,snapshot_item_count,snapshot_manifest_format,redacted_at FROM snapshots WHERE snapshot_id=?",
        )
        .bind(&old_snapshot_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(old_snapshot.0, "[]");
        assert_eq!(old_snapshot.1, 0);
        assert_eq!(old_snapshot.2, "expired");
        assert!(old_snapshot.3.is_some());
        let old_snapshot_error = state
            .sync_repository
            .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
                user: crate::auth::AuthUser {
                    user_id: user_id.clone(),
                    device_id: device_id.clone(),
                    session_id: session_id.clone(),
                    access_hash: crate::sha256_hex(token.as_bytes()),
                    declares_record_schema2: false,
                    declares_sync_redaction_v1: true,
                },
                snapshot_id: old_snapshot_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
                page: None,
            })
            .await
            .unwrap_err();
        assert_eq!(old_snapshot_error.status, StatusCode::GONE);
        assert_eq!(old_snapshot_error.body.code, "SNAPSHOT_REDACTED");

        let capable_user = crate::auth::AuthUser {
            user_id: user_id.clone(),
            device_id: device_id.clone(),
            session_id: session_id.clone(),
            access_hash: crate::sha256_hex(token.as_bytes()),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let unreferenced_object_error = crate::objects::get_object_for_user(
            &state,
            &capable_user,
            &vault_id,
            &collectible_object_id,
            &HeaderMap::new(),
        )
        .await
        .unwrap_err();
        assert_eq!(unreferenced_object_error.status, StatusCode::NOT_FOUND);
        let new_snapshot = state
            .sync_repository
            .create_snapshot(crate::sync_repository::CreateSnapshotCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        let new_snapshot_id = new_snapshot["snapshot_id"].as_str().unwrap().to_owned();
        let new_snapshot_view = state
            .sync_repository
            .read_snapshot(crate::sync_repository::ReadSnapshotCommand {
                user: capable_user.clone(),
                snapshot_id: new_snapshot_id.clone(),
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
                page: None,
            })
            .await
            .unwrap();
        assert_eq!(new_snapshot_view["item_count"], 2);
        let graveyard = new_snapshot_view["manifest"]
            .as_array()
            .unwrap()
            .iter()
            .find(|item| item["record_id"] == record_id)
            .unwrap();
        assert_eq!(graveyard["kind"], "graveyard");
        assert!(graveyard.get("envelope").is_none());
        assert_eq!(
            graveyard["redaction"]["redaction_id"],
            proof["redaction_id"]
        );
        let revision_history = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: new_snapshot_id.clone(),
                kind: HistoryKind::Revisions,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        assert_eq!(revision_history["revisions"][0]["operation"], "redacted");
        assert_eq!(revision_history["revisions"][0]["deleted"], false);
        assert_eq!(revision_history["revisions"][1]["operation"], "redacted");
        assert_eq!(revision_history["revisions"][1]["deleted"], true);
        assert!(revision_history["revisions"][1]["envelope"].is_null());
        let conflict_history = state
            .sync_repository
            .read_history_page(crate::sync_repository::HistoryPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                snapshot_id: new_snapshot_id,
                kind: HistoryKind::Conflicts,
                raw_cursor: None,
                limit: 10,
                generation: state.instance.generation.clone(),
                cursor_key: *state.cursor_key,
            })
            .await
            .unwrap();
        assert_eq!(conflict_history["conflicts"].as_array().unwrap().len(), 1);
        assert!(conflict_history["conflicts"][0]["envelope"].is_null());
        assert_eq!(
            conflict_history["conflicts"][0]["resolved_revision_id"],
            Value::Null
        );
        let changes = state
            .sync_repository
            .read_changes_page(crate::sync_repository::ChangesPageCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                raw_cursor: None,
                limit: 10,
                cursor_key: *state.cursor_key,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        assert_eq!(changes["events"].as_array().unwrap().len(), 4);
        assert_eq!(changes["events"][0]["event_type"], "record_redacted");
        assert_eq!(changes["events"][0]["commit_seq"], "1");
        assert_eq!(changes["events"][1]["event_type"], "record_redacted");
        assert_eq!(changes["events"][2]["event_type"], "create");
        assert_eq!(changes["events"][3]["event_type"], "record_redacted");
        assert_redaction_proof_signature(&changes["events"][3]["redaction"]);

        let revision_error = state
            .sync_repository
            .read_revision(crate::sync_repository::ReadRevisionCommand {
                user: capable_user.clone(),
                vault_id: vault_id.clone(),
                revision_id: created_revision.clone(),
            })
            .await
            .unwrap_err();
        assert_eq!(revision_error.status, StatusCode::GONE);
        assert_eq!(revision_error.body.code, "RECORD_REDACTED");
        assert!(revision_error.body.details.unwrap()["redaction"].is_object());

        let retry = send_purge(route.clone(), deleted_revision.clone(), "2".to_owned()).await;
        assert_eq!(retry.status(), StatusCode::OK);
        let retry = response_json(retry).await;
        assert_eq!(retry["already_purged"], true);
        assert_eq!(retry["redaction"]["redaction_id"], proof["redaction_id"]);
        let peer_push_after_retry: i64 = sqlx::query_scalar(
            "SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-peer-endpoint'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            peer_push_after_retry, 1,
            "idempotent purge retry must not enqueue a duplicate push"
        );

        // Purge itself requires the exact protocol marker, including an
        // idempotent lost-ACK retry. The missing marker also invalidates this
        // device's active support report at authentication time.
        let missing_marker = route
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!(
                        "/api/v1/vaults/{vault_id}/records/{record_id}/purge"
                    ))
                    .header(AUTHORIZATION, format!("Bearer {token}"))
                    .header(CONTENT_TYPE, "application/json")
                    .body(Body::from(
                        json!({
                            "expected_deleted_revision_id":deleted_revision,
                            "expected_deleted_seq":"2",
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(missing_marker.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            response_json(missing_marker).await["error"]["code"],
            "INVALID_REDACTION_MARKER"
        );

        // Move only the purge-created GC deadline into the past, then invoke
        // the production maintenance path. This proves the delayed collector
        // removes the now-unreferenced bytes without touching the shared
        // object or the durable redaction/tombstone evidence.
        let gc_now = chrono::Utc::now().timestamp();
        sqlx::query("UPDATE blob_objects SET gc_after=? WHERE vault_id=? AND object_id=?")
            .bind(gc_now.saturating_sub(1))
            .bind(&vault_id)
            .bind(&collectible_object_id)
            .execute(&state.db)
            .await
            .unwrap();
        compact_expired_history(&state).await.unwrap();

        let collected_bytes: Option<Vec<u8>> =
            sqlx::query_scalar("SELECT bytes FROM blob_objects WHERE vault_id=? AND object_id=?")
                .bind(&vault_id)
                .bind(&collectible_object_id)
                .fetch_optional(&state.db)
                .await
                .unwrap();
        assert!(
            collected_bytes.is_none(),
            "due purged object bytes must be collected"
        );
        let shared_bytes: Vec<u8> =
            sqlx::query_scalar("SELECT bytes FROM blob_objects WHERE vault_id=? AND object_id=?")
                .bind(&vault_id)
                .bind(&shared_object_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(shared_bytes, vec![1], "shared object bytes must remain");
        let references_after_gc: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM object_references WHERE vault_id=? AND object_id=?),\
                    (SELECT COUNT(*) FROM object_references WHERE vault_id=? AND object_id=?)",
        )
        .bind(&vault_id)
        .bind(&collectible_object_id)
        .bind(&vault_id)
        .bind(&shared_object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(references_after_gc, (0, 1));
        let retry_grant_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&collectible_upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(retry_grant_state, "collected");
        let mut retry_headers = HeaderMap::new();
        retry_headers.insert(AUTHORIZATION, format!("Bearer {token}").parse().unwrap());
        retry_headers.insert("x-atermius-redaction-marker", "v1".parse().unwrap());
        let revoked_retry = crate::objects::complete_upload(
            State(state.clone()),
            retry_headers,
            Path(collectible_upload_id.clone()),
        )
        .await
        .unwrap_err();
        assert_eq!(revoked_retry.status, StatusCode::GONE);
        assert_eq!(revoked_retry.body.code, "OBJECT_COLLECTED");

        let retained_graveyard: (String, i64) = sqlx::query_as(
            "SELECT deleted_revision,deleted_seq FROM record_graveyard WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(retained_graveyard, (deleted_revision.clone(), 2));
        let retained_redaction: (String, String, i64, i64) = sqlx::query_as(
            "SELECT redaction_id,deleted_revision_id,deleted_seq,redaction_seq \
             FROM record_redactions WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            retained_redaction,
            (
                proof["redaction_id"].as_str().unwrap().to_owned(),
                deleted_revision.clone(),
                2,
                4,
            )
        );
        let receipts_after_gc: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT COUNT(*) FROM op_receipts WHERE vault_id=?),\
                    (SELECT COUNT(*) FROM batch_receipts WHERE vault_id=?)",
        )
        .bind(&vault_id)
        .bind(&vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(receipts_after_gc, (1, 1));
        let expired_snapshot_after_gc: (String, i64, String, Option<String>, i64) =
            sqlx::query_as(
                "SELECT manifest_json,snapshot_item_count,snapshot_manifest_format,redacted_at,\
                        (SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=snapshots.snapshot_id) \
                 FROM snapshots WHERE snapshot_id=?",
            )
            .bind(&old_snapshot_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(
            expired_snapshot_after_gc.0, "[]",
            "redacted snapshot manifest must remain erased after GC"
        );
        assert_eq!(expired_snapshot_after_gc.1, 0);
        assert_eq!(expired_snapshot_after_gc.2, "expired");
        assert!(expired_snapshot_after_gc.3.is_some());
        assert_eq!(expired_snapshot_after_gc.4, 0);

        let changes_after_gc = state
            .sync_repository
            .read_changes_page(crate::sync_repository::ChangesPageCommand {
                user: capable_user,
                vault_id: vault_id.clone(),
                raw_cursor: None,
                limit: 10,
                cursor_key: *state.cursor_key,
                generation: state.instance.generation.clone(),
                test_pause: None,
            })
            .await
            .unwrap();
        let events_after_gc = changes_after_gc["events"].as_array().unwrap();
        assert_eq!(events_after_gc.len(), 4);
        assert_eq!(events_after_gc[3]["event_type"], "record_redacted");
        assert_eq!(
            events_after_gc[3]["redaction"]["redaction_id"],
            proof["redaction_id"]
        );
        assert_redaction_proof_signature(&events_after_gc[3]["redaction"]);

        // Exercise the guarded service actor against a second due tombstone.
        // It is deliberately not wired into run_maintenance; the stored
        // per-tombstone consent is still checked by the transaction itself.
        let maintenance_record_id = Uuid::new_v4().to_string();
        let maintenance_deleted_revision = Uuid::new_v4().to_string();
        let maintenance_deleted_seq: i64 =
            sqlx::query_scalar("SELECT last_committed_seq+1 FROM vault_counters WHERE vault_id=?")
                .bind(&vault_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let maintenance_deleted_at = (chrono::Utc::now() - chrono::Duration::days(40)).to_rfc3339();
        let maintenance_restore_until =
            (chrono::DateTime::parse_from_rfc3339(&maintenance_deleted_at)
                .unwrap()
                .with_timezone(&chrono::Utc)
                + chrono::Duration::days(30))
            .to_rfc3339();
        let maintenance_envelope = json!({
            "header":{"revision_id":maintenance_deleted_revision},
            "nonce":"maintenance-nonce",
            "ciphertext":"maintenance-secret",
            "signature":"maintenance-signature"
        });
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES(?,?,?,NULL,?,'maintenance-digest',?,?,'delete',?,?)",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .bind(&maintenance_deleted_revision)
        .bind(maintenance_envelope.to_string())
        .bind(maintenance_deleted_seq)
        .bind(&device_id)
        .bind(&maintenance_deleted_at)
        .bind(&maintenance_restore_until)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES(?,?,?,1,?)",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .bind(&maintenance_deleted_revision)
        .bind(maintenance_deleted_seq)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
             VALUES(?,?,?,?)",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .bind(&maintenance_deleted_revision)
        .bind(maintenance_deleted_seq)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES(?,?,'delete',?,?,?,?)",
        )
        .bind(&vault_id)
        .bind(maintenance_deleted_seq)
        .bind(&maintenance_record_id)
        .bind(&maintenance_deleted_revision)
        .bind(maintenance_envelope.to_string())
        .bind(&maintenance_deleted_at)
        .execute(&state.db)
        .await
        .unwrap();
        let maintenance_snapshot_id = Uuid::new_v4().to_string();
        let maintenance_snapshot_item = json!({
            "kind":"head",
            "record_id":maintenance_record_id,
            "envelope":maintenance_envelope
        });
        let maintenance_snapshot_manifest = json!([maintenance_snapshot_item]).to_string();
        let maintenance_snapshot_item_json = maintenance_snapshot_item.to_string();
        sqlx::query(
            "INSERT INTO snapshots( \
                 snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark, \
                 manifest_json,snapshot_item_count,snapshot_manifest_format,expires_at,created_at, \
                 server_generation \
             ) VALUES(?,?,?,?,0,?,1,'paged',?,?,?)",
        )
        .bind(&maintenance_snapshot_id)
        .bind(&vault_id)
        .bind(&user_id)
        .bind(maintenance_deleted_seq)
        .bind(&maintenance_snapshot_manifest)
        .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
        .bind(now_rfc3339())
        .bind(&state.instance.generation)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES(?,?,?)")
            .bind(&maintenance_snapshot_id)
            .bind(&maintenance_record_id)
            .bind(&maintenance_snapshot_item_json)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=? WHERE vault_id=?")
            .bind(maintenance_deleted_seq)
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        let maintenance_guard = crate::acquire_instance_maintenance_lock(&state)
            .await
            .unwrap();
        let maintenance_deleted_seq_text = maintenance_deleted_seq.to_string();
        let mut mismatched_state = state.clone();
        let mut mismatched_config = (*state.config).clone();
        mismatched_config.data_dir = data_dir.join("other-instance");
        mismatched_state.config = Arc::new(mismatched_config);
        let mismatched_guard = crate::record_purge::purge_record_sqlite_maintenance(
            &mismatched_state,
            &maintenance_guard,
            &vault_id,
            &maintenance_record_id,
            &maintenance_deleted_revision,
            &maintenance_deleted_seq_text,
        )
        .await
        .unwrap_err();
        assert_eq!(
            mismatched_guard.status,
            StatusCode::INTERNAL_SERVER_ERROR,
            "maintenance guard from another instance must fail before purge"
        );

        let not_opted_in = crate::record_purge::purge_record_sqlite_maintenance(
            &state,
            &maintenance_guard,
            &vault_id,
            &maintenance_record_id,
            &maintenance_deleted_revision,
            &maintenance_deleted_seq_text,
        )
        .await
        .unwrap_err();
        assert_eq!(not_opted_in.status, StatusCode::CONFLICT);
        assert_eq!(not_opted_in.body.code, "RECORD_AUTO_PURGE_NOT_ENABLED");
        let untouched: (i64, i64) = sqlx::query_as(
            "SELECT (SELECT last_committed_seq FROM vault_counters WHERE vault_id=?), \
                    (SELECT COUNT(*) FROM record_redactions WHERE vault_id=? AND record_id=?)",
        )
        .bind(&vault_id)
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(untouched, (maintenance_deleted_seq, 0));
        sqlx::query(
            "UPDATE record_graveyard SET auto_purge_enabled=1,auto_purge_revision=1 \
             WHERE vault_id=? AND record_id=? AND deleted_revision=? AND deleted_seq=?",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .bind(&maintenance_deleted_revision)
        .bind(maintenance_deleted_seq)
        .execute(&state.db)
        .await
        .unwrap();

        let missing_capability = crate::record_purge::purge_record_sqlite_maintenance(
            &state,
            &maintenance_guard,
            &vault_id,
            &maintenance_record_id,
            &maintenance_deleted_revision,
            &maintenance_deleted_seq_text,
        )
        .await
        .unwrap_err();
        assert_eq!(missing_capability.status, StatusCode::CONFLICT);
        assert_eq!(
            missing_capability.body.code, "VAULT_REDACTION_CAPABILITY_REQUIRED",
            "maintenance must enforce the same active-device capability gate"
        );

        // The Owner endpoint above intentionally invalidated its report when
        // a later retry omitted the redaction marker. Publish a newer signed
        // report for the successful Maintenance case; the service path still
        // rechecks the reports under its writer fence.
        let mut refreshed_owner_report = capability_payload(&device_id);
        refreshed_owner_report["revision"] = json!(2);
        let refreshed_owner_signature = URL_SAFE_NO_PAD.encode(
            owner_key
                .sign(&crate::jcs(&refreshed_owner_report).unwrap())
                .to_bytes(),
        );
        sqlx::query(
            "UPDATE device_redaction_capability_reports \
             SET revision=2,sync_redaction_version=1,signature=?,updated_at=?,invalidated_at=NULL \
             WHERE device_id=? AND user_id=?",
        )
        .bind(refreshed_owner_signature)
        .bind(now_rfc3339())
        .bind(&device_id)
        .bind(&user_id)
        .execute(&state.db)
        .await
        .unwrap();

        let maintenance_purge = || {
            crate::record_purge::purge_record_sqlite_maintenance(
                &state,
                &maintenance_guard,
                &vault_id,
                &maintenance_record_id,
                &maintenance_deleted_revision,
                &maintenance_deleted_seq_text,
            )
        };

        // Outbox failure occurs after all purge mutations in this transaction;
        // it must roll back the counter, redaction, and tombstone scrubbing.
        sqlx::query("CREATE TRIGGER reject_maintenance_purge_outbox BEFORE INSERT ON notification_push_outbox BEGIN SELECT RAISE(ABORT,'injected maintenance purge outbox failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        let outbox_error = maintenance_purge().await.unwrap_err();
        assert_eq!(outbox_error.status, StatusCode::INTERNAL_SERVER_ERROR);
        sqlx::query("DROP TRIGGER reject_maintenance_purge_outbox")
            .execute(&state.db)
            .await
            .unwrap();
        assert_failed_maintenance_purge_preserves_fixture(
            &state,
            &vault_id,
            &maintenance_record_id,
            &maintenance_deleted_revision,
            maintenance_deleted_seq,
            &maintenance_envelope.to_string(),
            &maintenance_snapshot_id,
            &maintenance_snapshot_manifest,
            &maintenance_snapshot_item_json,
        )
        .await;

        // Audit failure happens after outbox enqueue and must roll back both.
        sqlx::query("CREATE TRIGGER reject_maintenance_purge_audit BEFORE INSERT ON audit_events WHEN NEW.action='vault.record_purged' AND NEW.source='maintenance' BEGIN SELECT RAISE(ABORT,'injected maintenance purge audit failure'); END")
            .execute(&state.db)
            .await
            .unwrap();
        let audit_error = maintenance_purge().await.unwrap_err();
        assert_eq!(audit_error.status, StatusCode::INTERNAL_SERVER_ERROR);
        sqlx::query("DROP TRIGGER reject_maintenance_purge_audit")
            .execute(&state.db)
            .await
            .unwrap();
        assert_failed_maintenance_purge_preserves_fixture(
            &state,
            &vault_id,
            &maintenance_record_id,
            &maintenance_deleted_revision,
            maintenance_deleted_seq,
            &maintenance_envelope.to_string(),
            &maintenance_snapshot_id,
            &maintenance_snapshot_manifest,
            &maintenance_snapshot_item_json,
        )
        .await;

        let maintenance_result = maintenance_purge().await.unwrap();
        assert_eq!(maintenance_result["status"], "purged");
        assert_eq!(maintenance_result["already_purged"], false);
        let consumed_opt_in: (i64, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(consumed_opt_in, (0, 2));
        let maintenance_proof = maintenance_result["redaction"].clone();
        assert_eq!(
            maintenance_proof["redaction_seq"],
            (maintenance_deleted_seq + 1).to_string()
        );
        assert_redaction_proof_signature(&maintenance_proof);

        let maintenance_audit: (Option<String>, Option<String>, String, i64) = sqlx::query_as(
            "SELECT actor_user_id,actor_device_id,source,COUNT(*) \
                 FROM audit_events WHERE scope_type='vault' AND scope_id=? \
                   AND action='vault.record_purged' AND resource_id=? \
                 GROUP BY actor_user_id,actor_device_id,source",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(maintenance_audit, (None, None, "maintenance".to_owned(), 1));
        let maintenance_pushes: (Option<i64>, i64) = sqlx::query_as(
            "SELECT \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-source-endpoint'), \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-peer-endpoint')",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            maintenance_pushes,
            (Some(1), 2),
            "maintenance must wake both the source device endpoint and every peer endpoint"
        );

        let maintenance_retry = maintenance_purge().await.unwrap();
        assert_eq!(maintenance_retry["already_purged"], true);
        assert_eq!(
            maintenance_retry["redaction"]["redaction_id"],
            maintenance_proof["redaction_id"]
        );
        let retry_audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE scope_type='vault' AND scope_id=? \
             AND action='vault.record_purged' AND resource_id=? AND source='maintenance'",
        )
        .bind(&vault_id)
        .bind(&maintenance_record_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let retry_pushes: (i64, i64) = sqlx::query_as(
            "SELECT \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-source-endpoint'), \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-peer-endpoint')",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            retry_audit_count, 1,
            "retry must not duplicate its audit row"
        );
        assert_eq!(retry_pushes, (1, 2), "retry must not duplicate push hints");
        drop(maintenance_guard);

        state.db.close().await;
        let _ = tokio::fs::remove_dir_all(data_dir).await;
    }

    async fn assert_failed_maintenance_purge_preserves_fixture(
        state: &crate::AppState,
        vault_id: &str,
        record_id: &str,
        deleted_revision_id: &str,
        deleted_seq: i64,
        envelope: &str,
        snapshot_id: &str,
        snapshot_manifest: &str,
        snapshot_item_json: &str,
    ) {
        let purge_state: (
            i64,
            i64,
            String,
            String,
            String,
            String,
            String,
            i64,
            String,
            i64,
            i64,
            i64,
        ) = sqlx::query_as(
            "SELECT c.last_committed_seq, \
                    (SELECT COUNT(*) FROM record_heads WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT envelope FROM record_versions \
                     WHERE vault_id=?1 AND record_id=?2 AND revision_id=?3), \
                    (SELECT event_type FROM change_events \
                     WHERE vault_id=?1 AND record_id=?2 AND commit_seq=?4), \
                    (SELECT revision_id FROM change_events \
                     WHERE vault_id=?1 AND record_id=?2 AND commit_seq=?4), \
                    (SELECT envelope FROM change_events \
                     WHERE vault_id=?1 AND record_id=?2 AND commit_seq=?4), \
                    (SELECT deleted_revision FROM record_graveyard \
                     WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT deleted_seq FROM record_graveyard \
                     WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT CAST(auto_purge_enabled AS TEXT)||':'||CAST(auto_purge_revision AS TEXT) \
                     FROM record_graveyard WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT COUNT(*) FROM record_redacted_revisions \
                     WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT COUNT(*) FROM record_redactions \
                     WHERE vault_id=?1 AND record_id=?2), \
                    (SELECT COUNT(*) FROM audit_events \
                     WHERE scope_type='vault' AND scope_id=?1 \
                       AND action='vault.record_purged' AND resource_id=?2 \
                       AND source='maintenance') \
             FROM vault_counters c WHERE c.vault_id=?1",
        )
        .bind(vault_id)
        .bind(record_id)
        .bind(deleted_revision_id)
        .bind(deleted_seq)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            purge_state,
            (
                deleted_seq,
                1,
                envelope.to_owned(),
                "delete".to_owned(),
                deleted_revision_id.to_owned(),
                envelope.to_owned(),
                deleted_revision_id.to_owned(),
                deleted_seq,
                "1:1".to_owned(),
                0,
                0,
                0,
            ),
            "failed purge must preserve the tombstone, payloads, redaction index, and audit"
        );

        let snapshot_state: (String, i64, String, Option<String>, i64, Option<String>) =
            sqlx::query_as(
                "SELECT manifest_json,snapshot_item_count,snapshot_manifest_format,redacted_at, \
                        (SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=?), \
                        (SELECT item_json FROM snapshot_items WHERE snapshot_id=?) \
                 FROM snapshots WHERE snapshot_id=?",
            )
            .bind(snapshot_id)
            .bind(snapshot_id)
            .bind(snapshot_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(
            snapshot_state,
            (
                snapshot_manifest.to_owned(),
                1,
                "paged".to_owned(),
                None,
                1,
                Some(snapshot_item_json.to_owned()),
            ),
            "failed purge must preserve the active snapshot manifest and item"
        );

        let push_state: (Option<i64>, Option<i64>) = sqlx::query_as(
            "SELECT \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-source-endpoint'), \
                (SELECT requested_seq FROM notification_push_outbox WHERE endpoint_id='purge-peer-endpoint')",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(push_state, (None, Some(1)));
    }

    fn assert_redaction_proof_signature(proof: &Value) {
        let public_key: [u8; 32] = URL_SAFE_NO_PAD
            .decode(proof["signing_public_key"].as_str().unwrap())
            .unwrap()
            .try_into()
            .unwrap();
        let key = VerifyingKey::from_bytes(&public_key).unwrap();
        let signature = Signature::from_slice(
            &URL_SAFE_NO_PAD
                .decode(proof["signature"].as_str().unwrap())
                .unwrap(),
        )
        .unwrap();
        let mut unsigned = proof.clone();
        unsigned.as_object_mut().unwrap().remove("signature");
        key.verify(&crate::jcs(&unsigned).unwrap(), &signature)
            .unwrap();
    }
}

//! Credential visibility v1: an administrator-controlled, per-account choice
//! between zero-knowledge (`private`) and administrator-readable
//! (`admin_visible`) saved Host credentials.
//!
//! Trust model (stated plainly, also in docs/CREDENTIAL-VISIBILITY.md):
//!
//! * The server never decrypts anything here. An `admin_visible` account's
//!   own client seals each Vault key it holds to the instance escrow X25519
//!   public key and signs the deposit with its device key. The escrow private
//!   key exists only in administrator clients: wrapped under each
//!   administrator's account key and under one offline recovery code. The
//!   database therefore holds ciphertext, signatures and public keys only.
//! * `admin_visible` depends on the user's client depositing. A modified
//!   client can withhold deposits; administrators then see `pending`.
//! * Deposits for a Vault exist only while an active member of it is
//!   `admin_visible`. Switching an account to `private`, revoking a
//!   membership, restricting it to `none` and purging an account all delete,
//!   in the same transaction, the deposits that no remaining member needs.
//!   This cannot erase what an administrator already viewed or copied.
//! * Every served record page writes an instance audit event, and every
//!   active member of the Vault, and every account that authored a served
//!   record, is shown the read (coalesced per administrator, account and
//!   Vault). Listing an account's deposits writes an instance audit event.
//! * Before an owner shares a Vault, the owner's client can ask whether the
//!   recipient account is `admin_visible` (and warn), because the share makes
//!   the whole Vault readable by administrators.
//!
//! SQLite only. In the PostgreSQL sync-core runtime the routes are not
//! registered (the scope guard answers `PG_SYNC_SCOPE_LIMITED`), the
//! capability is not advertised and `/me` reports `credential_visibility:null`.

use axum::{
    Json, Router,
    extract::{Path, Query, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode},
    routing::{get, post, put},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::SecondsFormat;
use ed25519_dalek::{Signature, Signer, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::Digest;
use sqlx::{Row, Sqlite, Transaction};
use uuid::Uuid;

use crate::{ApiError, AppState, admin, audit, auth};

pub(crate) const ESCROW_KEY_FORMAT: &str = "atermius-credential-escrow-key-v1";
pub(crate) const ESCROW_KEY_CREATION_FORMAT: &str = "atermius-credential-escrow-key-creation-v1";
pub(crate) const ESCROW_DEPOSIT_FORMAT: &str = "atermius-credential-escrow-deposit-v1";
/// Format of the sealed plaintext. The server cannot open deposits; the
/// constant documents the contract and is used by tests and vectors.
#[cfg_attr(not(test), allow(dead_code))]
pub(crate) const ESCROW_SEALED_FORMAT: &str = "atermius-credential-escrow-v1";

/// `crypto_box_seal` adds a 32-byte ephemeral public key and a 16-byte tag.
const SEAL_OVERHEAD_BYTES: usize = 48;
const MAX_SEALED_BYTES: usize = 1024;
const WRAP_NONCE_BYTES: usize = 24;
/// A wrapped 32-byte X25519 secret key plus the 16-byte AEAD tag.
const WRAP_CIPHERTEXT_BYTES: usize = 48;
const RECOVERY_KDF_ID: &str = "argon2id13";
const RECOVERY_KDF_SALT_BYTES: usize = 16;
const RECOVERY_KDF_MEM_KIB: u32 = 65_536;
const RECOVERY_KDF_ITERATIONS: u32 = 3;
const RECOVERY_KDF_PARALLELISM: u32 = 1;
/// Bound on the `missing` list returned to one client; it re-reads status
/// after depositing, so later items are reported on the next call.
const MAX_MISSING_ITEMS: i64 = 500;
const ADMIN_VIEWS_RETURNED: i64 = 20;
const ADMIN_VIEWS_RETAINED: i64 = 200;
const ADMIN_VIEW_COALESCE_SECONDS: i64 = 10 * 60;
const DEFAULT_RECORD_PAGE: u32 = 200;
const MAX_RECORD_PAGE: u32 = 500;
/// Baseline per-administrator limit for escrowed record pages.
const RECORD_PAGES_PER_MINUTE: usize = 120;

/// `vm` must alias a `vault_members` row. Active membership uses the same
/// organization-restriction rule as ordinary Vault reads.
const ACTIVE_MEMBERSHIP: &str = "vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr \
     WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none')";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum CredentialVisibility {
    Private,
    AdminVisible,
}

impl CredentialVisibility {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Private => "private",
            Self::AdminVisible => "admin_visible",
        }
    }

    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "private" => Some(Self::Private),
            "admin_visible" => Some(Self::AdminVisible),
            _ => None,
        }
    }

    fn from_stored(value: &str) -> Result<Self, ApiError> {
        Self::parse(value)
            .ok_or_else(|| ApiError::internal("stored credential visibility is invalid"))
    }
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

fn escrow_invalid(message: &str) -> ApiError {
    ApiError::bad_request("CREDENTIAL_ESCROW_INVALID", message)
}

fn escrow_not_required() -> ApiError {
    ApiError::conflict(
        "CREDENTIAL_ESCROW_NOT_REQUIRED",
        "this account does not escrow credentials",
    )
}

fn escrow_key_mismatch() -> ApiError {
    ApiError::conflict(
        "CREDENTIAL_ESCROW_KEY_MISMATCH",
        "the escrow key is not the current escrow key",
    )
}

fn escrow_not_available() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "CREDENTIAL_ESCROW_NOT_AVAILABLE",
        "escrowed credentials are not available for this account and Vault",
    )
}

/// Fails closed when a credential-visibility option reaches the restricted
/// PostgreSQL runtime, matching the scope guard's error.
pub(crate) fn pg_unsupported() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "PG_SYNC_SCOPE_LIMITED",
        "this PostgreSQL sync-core runtime does not provide credential visibility",
    )
}

fn invalid_mode_request(field: &str) -> ApiError {
    ApiError::bad_request(
        "INVALID_CREDENTIAL_VISIBILITY",
        &format!("request body must contain only {field} 'private' or 'admin_visible'"),
    )
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/// Registered only for the SQLite runtime (see `crate::router`).
pub(crate) fn routes(app: Router<AppState>) -> Router<AppState> {
    app.route("/api/v1/credential-visibility", get(status))
        .route(
            "/api/v1/credential-visibility/escrow/{vault_id}/{key_epoch}",
            put(deposit),
        )
        .route(
            "/api/v1/credential-visibility/vaults/{vault_id}/recipients/{device_id}",
            get(share_recipient),
        )
        .route(
            "/api/v1/admin/credential-visibility",
            get(admin_policy).put(update_admin_policy),
        )
        .route(
            "/api/v1/admin/accounts/{user_id}/credential-visibility",
            put(update_account_mode),
        )
        .route(
            "/api/v1/admin/credential-escrow/key",
            post(create_escrow_key).delete(reset_escrow_key),
        )
        .route(
            "/api/v1/admin/credential-escrow/key/wrap",
            put(store_escrow_key_wrap),
        )
        .route(
            "/api/v1/admin/credential-escrow/accounts/{user_id}/vaults",
            get(account_escrow_vaults),
        )
        .route(
            "/api/v1/admin/credential-escrow/vaults/{vault_id}/records",
            get(escrowed_vault_records),
        )
}

// ---------------------------------------------------------------------------
// Shared SQL and state helpers
// ---------------------------------------------------------------------------

/// Rows of every `(vault, epoch)` the account at `user_expr` must escrow and
/// has not escrowed under the current key: active membership of an active
/// Vault, and a key envelope for that epoch addressed to one of the account's
/// active devices (so only epochs its devices can actually open).
fn missing_items_sql(select: &str, user_expr: &str) -> String {
    format!(
        "SELECT {select} FROM vault_key_envelopes ke \
         JOIN vaults v ON v.vault_id=ke.vault_id AND v.state='active' \
         JOIN vault_members vm ON vm.vault_id=ke.vault_id AND vm.user_id=ke.recipient_user_id \
         JOIN devices d ON d.device_id=ke.recipient_device_id AND d.user_id=ke.recipient_user_id \
           AND d.status='active' \
         WHERE ke.recipient_user_id={user_expr} AND {ACTIVE_MEMBERSHIP} \
           AND NOT EXISTS(SELECT 1 FROM credential_escrow_envelopes ce \
             JOIN credential_escrow_keys ck ON ck.key_id=ce.key_id \
             WHERE ce.vault_id=ke.vault_id AND ce.key_epoch=ke.epoch)"
    )
}

/// SQL expression yielding `not_required|no_key|pending|complete` for the
/// `users` row aliased as `user_alias`.
pub(crate) fn escrow_status_sql(user_alias: &str) -> String {
    format!(
        "CASE WHEN {user_alias}.credential_visibility<>'admin_visible' THEN 'not_required' \
         WHEN NOT EXISTS(SELECT 1 FROM credential_escrow_keys) THEN 'no_key' \
         WHEN EXISTS({}) THEN 'pending' ELSE 'complete' END",
        missing_items_sql("1", &format!("{user_alias}.user_id"))
    )
}

/// SQL boolean expression: the Vault at `vault_expr` has an active member
/// (membership `active`, not hidden by an organization `none` restriction)
/// whose account is `admin_visible`.
///
/// Escrow invariant: deposits for a Vault exist only while this holds. New
/// deposits require it (the depositor is such a member), and every change
/// that can make it false prunes in the same transaction through
/// [`prune_orphaned_escrow_tx`].
fn admin_visible_member_exists_sql(vault_expr: &str) -> String {
    format!(
        "EXISTS(SELECT 1 FROM vault_members avm JOIN users au ON au.user_id=avm.user_id \
         WHERE avm.vault_id={vault_expr} AND avm.state='active' \
           AND au.credential_visibility='admin_visible' \
           AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions acr \
             WHERE acr.vault_id=avm.vault_id AND acr.user_id=avm.user_id AND acr.max_role='none'))"
    )
}

/// SQL boolean expression: the Vault at `vault_expr` is administrator
/// visible (an escrow key exists and an active member is `admin_visible`).
pub(crate) fn vault_admin_visible_sql(vault_expr: &str) -> String {
    format!(
        "(EXISTS(SELECT 1 FROM credential_escrow_keys) AND {})",
        admin_visible_member_exists_sql(vault_expr)
    )
}

/// Enforces the escrow invariant for one Vault: when no active member is
/// `admin_visible` any more, every deposit of the Vault is deleted.
///
/// Must run in the same transaction as each change that can end the last such
/// membership: an account switched to `private`, a membership revoked by a
/// signed key rotation or ownership transfer, an organization restriction to
/// `none`, and account purge. Otherwise stale deposits would become readable
/// again as soon as any remaining member was made `admin_visible`, before
/// that member's own client had deposited.
pub(crate) async fn prune_orphaned_escrow_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
) -> Result<(), ApiError> {
    sqlx::query(&format!(
        "DELETE FROM credential_escrow_envelopes WHERE vault_id=? AND NOT {}",
        admin_visible_member_exists_sql("credential_escrow_envelopes.vault_id")
    ))
    .bind(vault_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

/// Vaults holding deposits that `user_id` belongs to (any membership state)
/// or deposited for. Callers collect them before an account change and prune
/// them afterwards, which also works after the account row and, by cascade,
/// its memberships are deleted.
pub(crate) async fn escrowed_vaults_of_account_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<Vec<String>, ApiError> {
    sqlx::query_scalar(
        "SELECT DISTINCT vault_id FROM credential_escrow_envelopes \
         WHERE vault_id IN (SELECT vault_id FROM vault_members WHERE user_id=?) \
            OR depositor_user_id=? ORDER BY vault_id",
    )
    .bind(user_id)
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

fn now_micros() -> String {
    chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Micros, true)
}

fn micros_ago(seconds: i64) -> String {
    (chrono::Utc::now() - chrono::Duration::seconds(seconds))
        .to_rfc3339_opts(SecondsFormat::Micros, true)
}

fn decode_exact(value: &str, expected: usize) -> Option<Vec<u8>> {
    URL_SAFE_NO_PAD
        .decode(value)
        .ok()
        .filter(|bytes| bytes.len() == expected)
}

fn verifying_key(public_b64: &str) -> Option<VerifyingKey> {
    let bytes: [u8; 32] = decode_exact(public_b64, 32)?.try_into().ok()?;
    VerifyingKey::from_bytes(&bytes).ok()
}

fn signature(signature_b64: &str) -> Option<Signature> {
    let bytes = decode_exact(signature_b64, 64)?;
    Signature::from_slice(&bytes).ok()
}

fn verify_device_signature(public_b64: &str, signature_b64: &str, payload: &[u8]) -> bool {
    match (verifying_key(public_b64), signature(signature_b64)) {
        (Some(key), Some(signature)) => key.verify_strict(payload, &signature).is_ok(),
        _ => false,
    }
}

/// The calling device's registered Ed25519 key, rechecked inside `tx`.
async fn active_device_signing_key_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &auth::AuthUser,
) -> Result<String, ApiError> {
    sqlx::query_scalar(
        "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))
}

async fn account_mode_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<Option<(CredentialVisibility, Option<String>)>, ApiError> {
    let row = sqlx::query(
        "SELECT credential_visibility,credential_visibility_changed_at FROM users WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    row.map(|row| {
        Ok((
            CredentialVisibility::from_stored(&row.get::<String, _>("credential_visibility"))?,
            row.get::<Option<String>, _>("credential_visibility_changed_at"),
        ))
    })
    .transpose()
}

pub(crate) async fn instance_default_tx(
    tx: &mut Transaction<'_, Sqlite>,
) -> Result<CredentialVisibility, ApiError> {
    let value: Option<String> =
        sqlx::query_scalar("SELECT default_visibility FROM instance_credential_policy WHERE id=1")
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    // The migration creates the row; a missing row fails closed to private.
    value
        .as_deref()
        .map(CredentialVisibility::from_stored)
        .transpose()
        .map(|mode| mode.unwrap_or(CredentialVisibility::Private))
}

/// Mode for a newly registered account: the invitation's explicit mode, or
/// the instance default (also used for the bootstrap account).
pub(crate) async fn mode_for_new_account_tx(
    tx: &mut Transaction<'_, Sqlite>,
    invitation_mode: Option<&str>,
) -> Result<CredentialVisibility, ApiError> {
    match invitation_mode {
        Some(value) => CredentialVisibility::from_stored(value),
        None => instance_default_tx(tx).await,
    }
}

/// `/me` policy value: `{mode, changed_at}`; null in PostgreSQL mode.
pub(crate) async fn me_policy(state: &AppState, user_id: &str) -> Result<Value, ApiError> {
    if state.pg_sync_only {
        return Ok(Value::Null);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let mode = account_mode_tx(&mut tx, user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    let (mode, changed_at) = mode.ok_or_else(ApiError::unauthorized)?;
    Ok(json!({"mode": mode.as_str(), "changed_at": changed_at}))
}

/// Instance default for the public `/instance` notice; None in PG mode.
pub(crate) async fn public_instance_default(
    state: &AppState,
) -> Result<Option<&'static str>, ApiError> {
    if state.pg_sync_only {
        return Ok(None);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let mode = instance_default_tx(&mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(mode.as_str()))
}

#[derive(Debug, Clone)]
struct EscrowKey {
    key_id: String,
    public_key: String,
    signed_payload: String,
    instance_signature: String,
    recovery_wrap: String,
    created_at: String,
}

#[derive(Serialize)]
struct EscrowKeyPayload<'a> {
    format: &'static str,
    instance_id: &'a str,
    key_id: &'a str,
    public_key: &'a str,
    created_at: &'a str,
}

#[derive(Serialize)]
struct EscrowKeyCreationPayload<'a> {
    format: &'static str,
    instance_id: &'a str,
    key_id: &'a str,
    public_key: &'a str,
    account_id: &'a str,
    device_id: &'a str,
}

#[derive(Serialize)]
struct EscrowDepositPayload<'a> {
    format: &'static str,
    instance_id: &'a str,
    key_id: &'a str,
    vault_id: &'a str,
    key_epoch: i64,
    sealed_sha256: &'a str,
}

pub(crate) fn escrow_key_signed_payload(
    instance_id: &str,
    key_id: &str,
    public_key: &str,
    created_at: &str,
) -> Result<String, ApiError> {
    String::from_utf8(crate::jcs(&EscrowKeyPayload {
        format: ESCROW_KEY_FORMAT,
        instance_id,
        key_id,
        public_key,
        created_at,
    })?)
    .map_err(ApiError::internal)
}

pub(crate) fn escrow_key_creation_bytes(
    instance_id: &str,
    key_id: &str,
    public_key: &str,
    account_id: &str,
    device_id: &str,
) -> Result<Vec<u8>, ApiError> {
    crate::jcs(&EscrowKeyCreationPayload {
        format: ESCROW_KEY_CREATION_FORMAT,
        instance_id,
        key_id,
        public_key,
        account_id,
        device_id,
    })
}

pub(crate) fn escrow_deposit_bytes(
    instance_id: &str,
    key_id: &str,
    vault_id: &str,
    key_epoch: i64,
    sealed_sha256: &str,
) -> Result<Vec<u8>, ApiError> {
    crate::jcs(&EscrowDepositPayload {
        format: ESCROW_DEPOSIT_FORMAT,
        instance_id,
        key_id,
        vault_id,
        key_epoch,
        sealed_sha256,
    })
}

async fn current_key_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
) -> Result<Option<EscrowKey>, ApiError> {
    let rows = sqlx::query(
        "SELECT key_id,public_key,signed_payload,instance_signature,recovery_wrap,created_at \
         FROM credential_escrow_keys LIMIT 2",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if rows.len() > 1 {
        return Err(ApiError::internal(
            "more than one credential escrow key is stored",
        ));
    }
    let Some(row) = rows.into_iter().next() else {
        return Ok(None);
    };
    let key = EscrowKey {
        key_id: row.get("key_id"),
        public_key: row.get("public_key"),
        signed_payload: row.get("signed_payload"),
        instance_signature: row.get("instance_signature"),
        recovery_wrap: row.get("recovery_wrap"),
        created_at: row.get("created_at"),
    };
    // The stored descriptor must bind exactly this row: a row whose columns
    // were swapped independently of the signed statement fails closed.
    let expected = escrow_key_signed_payload(
        &state.instance.instance_id,
        &key.key_id,
        &key.public_key,
        &key.created_at,
    )?;
    if expected != key.signed_payload {
        return Err(ApiError::internal(
            "stored credential escrow key binding is invalid",
        ));
    }
    Ok(Some(key))
}

/// The instance signature for the stored descriptor under the current
/// instance key. After an instance-key rotation the stored signature was
/// made by a previous key of this installation; it is then re-signed, but
/// only when a key from the verified transition chain signed it. A payload
/// no instance key ever signed fails closed.
fn current_instance_signature(state: &AppState, key: &EscrowKey) -> Result<String, ApiError> {
    let payload = key.signed_payload.as_bytes();
    let stored = signature(&key.instance_signature)
        .ok_or_else(|| ApiError::internal("stored credential escrow key signature is invalid"))?;
    if state
        .signing_key
        .verifying_key()
        .verify_strict(payload, &stored)
        .is_ok()
    {
        return Ok(key.instance_signature.clone());
    }
    let signed_by_previous_key = state
        .instance
        .signing_key_transitions
        .iter()
        .filter_map(|transition| verifying_key(&transition.from_public_key))
        .any(|previous| previous.verify_strict(payload, &stored).is_ok());
    if !signed_by_previous_key {
        return Err(ApiError::internal(
            "stored credential escrow key signature is invalid",
        ));
    }
    Ok(URL_SAFE_NO_PAD.encode(state.signing_key.sign(payload).to_bytes()))
}

fn descriptor(state: &AppState, key: &EscrowKey) -> Result<Value, ApiError> {
    Ok(json!({
        "key_id": key.key_id,
        "public_key": key.public_key,
        "signed_payload": key.signed_payload,
        "signature": current_instance_signature(state, key)?,
        "created_at": key.created_at,
    }))
}

fn stored_json(value: &str) -> Result<Value, ApiError> {
    serde_json::from_str(value).map_err(ApiError::internal)
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct AccountWrap {
    version: u32,
    nonce: String,
    ciphertext: String,
}

impl AccountWrap {
    pub(crate) fn validated_json(&self) -> Result<String, ApiError> {
        if self.version != 1
            || decode_exact(&self.nonce, WRAP_NONCE_BYTES).is_none()
            || decode_exact(&self.ciphertext, WRAP_CIPHERTEXT_BYTES).is_none()
        {
            return Err(escrow_invalid(
                "account_wrap must be version 1 with a 24-byte nonce and 48-byte ciphertext",
            ));
        }
        serde_json::to_string(self).map_err(ApiError::internal)
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RecoveryKdf {
    id: String,
    salt: String,
    mem_kib: u32,
    iterations: u32,
    parallelism: u32,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RecoveryWrap {
    version: u32,
    kdf: RecoveryKdf,
    nonce: String,
    ciphertext: String,
}

impl RecoveryWrap {
    pub(crate) fn validated_json(&self) -> Result<String, ApiError> {
        let salt = decode_exact(&self.kdf.salt, RECOVERY_KDF_SALT_BYTES);
        if self.version != 1
            || self.kdf.id != RECOVERY_KDF_ID
            || self.kdf.mem_kib != RECOVERY_KDF_MEM_KIB
            || self.kdf.iterations != RECOVERY_KDF_ITERATIONS
            || self.kdf.parallelism != RECOVERY_KDF_PARALLELISM
            || salt.is_none_or(|salt| salt.iter().all(|byte| *byte == 0))
            || decode_exact(&self.nonce, WRAP_NONCE_BYTES).is_none()
            || decode_exact(&self.ciphertext, WRAP_CIPHERTEXT_BYTES).is_none()
        {
            return Err(escrow_invalid(
                "recovery_wrap must be version 1 with the exact argon2id13 parameters, \
                 a 16-byte salt, a 24-byte nonce and a 48-byte ciphertext",
            ));
        }
        serde_json::to_string(self).map_err(ApiError::internal)
    }
}

fn validate_key_id(key_id: &str) -> Result<(), ApiError> {
    if crate::is_canonical_uuid(key_id) {
        Ok(())
    } else {
        Err(escrow_invalid("key_id must be a lowercase canonical UUID"))
    }
}

/// Canonical positive decimal epoch from a path segment.
fn parse_key_epoch(value: &str) -> Option<i64> {
    if value.is_empty()
        || value.len() > 18
        || value.starts_with('0')
        || !value.bytes().all(|byte| byte.is_ascii_digit())
    {
        return None;
    }
    value.parse::<i64>().ok().filter(|epoch| *epoch >= 1)
}

fn validate_admin_account_id(user_id: &str) -> Result<(), ApiError> {
    if crate::is_canonical_uuid(user_id) {
        Ok(())
    } else {
        Err(ApiError::bad_request(
            "INVALID_ACCOUNT_ID",
            "account id must use canonical lowercase UUID format",
        ))
    }
}

async fn require_admin_write(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(auth::AuthUser, Transaction<'static, Sqlite>), ApiError> {
    let user = auth::authenticate(state, headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, state, &user).await?;
    Ok((user, tx))
}

async fn require_admin_read(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(auth::AuthUser, Transaction<'static, Sqlite>), ApiError> {
    let user = auth::authenticate(state, headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_read_tx(&mut tx, state, &user).await?;
    Ok((user, tx))
}

async fn account_escrow_status_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<String, ApiError> {
    sqlx::query_scalar(&format!(
        "SELECT {} FROM users u WHERE u.user_id=?",
        escrow_status_sql("u")
    ))
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)
}

// ---------------------------------------------------------------------------
// User routes
// ---------------------------------------------------------------------------

/// `GET /api/v1/credential-visibility`
pub async fn status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    let (mode, changed_at) = account_mode_tx(&mut tx, &user.user_id)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    let key = current_key_tx(&mut tx, &state).await?;
    let missing = match (&key, mode) {
        (Some(_), CredentialVisibility::AdminVisible) => sqlx::query(&format!(
            "{} ORDER BY ke.vault_id,ke.epoch LIMIT ?",
            missing_items_sql("DISTINCT ke.vault_id,ke.epoch", "?")
        ))
        .bind(&user.user_id)
        .bind(MAX_MISSING_ITEMS)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .into_iter()
        .map(|row| {
            json!({
                "vault_id": row.get::<String, _>("vault_id"),
                "key_epoch": row.get::<i64, _>("epoch"),
            })
        })
        .collect::<Vec<_>>(),
        _ => Vec::new(),
    };
    let escrow_status = match (mode, &key) {
        (CredentialVisibility::Private, _) => "not_required",
        (CredentialVisibility::AdminVisible, None) => "no_key",
        (CredentialVisibility::AdminVisible, Some(_)) if missing.is_empty() => "complete",
        (CredentialVisibility::AdminVisible, Some(_)) => "pending",
    };
    let admin_views = sqlx::query(
        "SELECT v.viewed_at,u.username AS admin_username,v.vault_id FROM credential_admin_views v \
         LEFT JOIN users u ON u.user_id=v.admin_user_id WHERE v.target_user_id=? \
         ORDER BY v.viewed_at DESC,v.view_id DESC LIMIT ?",
    )
    .bind(&user.user_id)
    .bind(ADMIN_VIEWS_RETURNED)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .into_iter()
    .map(|row| {
        json!({
            "viewed_at": row.get::<String, _>("viewed_at"),
            "admin_username": row.get::<Option<String>, _>("admin_username"),
            "vault_id": row.get::<Option<String>, _>("vault_id"),
        })
    })
    .collect::<Vec<_>>();
    let escrow_key = key
        .as_ref()
        .map(|key| descriptor(&state, key))
        .transpose()?;
    // The Vaults `GET /api/v1/vaults` lists for this account with
    // `admin_visible: true`. A `private` account counts the shared Vaults
    // that other members made administrator visible, so its client never
    // claims that administrators cannot read anything.
    let admin_visible_vaults: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
         WHERE vm.user_id=? AND v.state IN ('active','deleting') AND {ACTIVE_MEMBERSHIP} AND {}",
        vault_admin_visible_sql("vm.vault_id")
    ))
    .bind(&user.user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "mode": mode.as_str(),
        "changed_at": changed_at,
        "escrow_status": escrow_status,
        "escrow_key": escrow_key,
        "missing": missing,
        "admin_views": admin_views,
        "admin_visible_vaults": admin_visible_vaults,
    })))
}

/// `GET /api/v1/credential-visibility/vaults/{vault_id}/recipients/{device_id}`
///
/// For the owner of an active Vault, before inviting or delivering a key to
/// the account behind an active device: whether that account is
/// `admin_visible` (administrators can then read the whole Vault once the
/// recipient joins and its client deposits) and whether the Vault already is
/// administrator visible. `recipient_admin_visible` ignores whether an
/// escrow key exists yet: one created later needs no further consent. The
/// owner learns the same fact from the Vault badge as soon as the recipient
/// joins; asking first lets the owner decide before sharing.
pub async fn share_recipient(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, device_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if !crate::is_canonical_uuid(&vault_id) || !crate::is_canonical_uuid(&device_id) {
        // Malformed IDs are indistinguishable from unknown ones.
        return Err(ApiError::not_found());
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let recipient_mode: Option<String> = sqlx::query_scalar(
        "SELECT u.credential_visibility FROM devices d JOIN users u ON u.user_id=d.user_id \
         WHERE d.device_id=? AND d.status='active'",
    )
    .bind(&device_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let recipient_mode = CredentialVisibility::from_stored(
        recipient_mode.as_deref().ok_or_else(ApiError::not_found)?,
    )?;
    let vault_admin_visible: bool =
        sqlx::query_scalar(&format!("SELECT {}", vault_admin_visible_sql("?")))
            .bind(&vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "recipient_admin_visible": recipient_mode == CredentialVisibility::AdminVisible,
        "vault_admin_visible": vault_admin_visible,
    })))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DepositRequest {
    key_id: String,
    sealed: String,
    signature: String,
}

/// `PUT /api/v1/credential-visibility/escrow/{vault_id}/{key_epoch}`
pub async fn deposit(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, key_epoch)): Path<(String, String)>,
    request: Result<Json<DepositRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if !crate::is_canonical_uuid(&vault_id) {
        // Keep malformed IDs indistinguishable from foreign Vaults.
        return Err(ApiError::not_found());
    }
    let key_epoch = parse_key_epoch(&key_epoch)
        .ok_or_else(|| escrow_invalid("key epoch must be a positive canonical integer"))?;
    let Json(request) = request.map_err(|_| {
        escrow_invalid("request body must contain exactly key_id, sealed and signature")
    })?;
    validate_key_id(&request.key_id)?;
    let sealed = URL_SAFE_NO_PAD
        .decode(&request.sealed)
        .map_err(|_| escrow_invalid("sealed must be canonical base64url without padding"))?;
    if sealed.len() <= SEAL_OVERHEAD_BYTES || sealed.len() > MAX_SEALED_BYTES {
        return Err(escrow_invalid("sealed size is outside the allowed range"));
    }
    let sealed_sha256 = URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed));
    let signed = escrow_deposit_bytes(
        &state.instance.instance_id,
        &request.key_id,
        &vault_id,
        key_epoch,
        &sealed_sha256,
    )?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let (mode, _) = account_mode_tx(&mut tx, &user.user_id)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    if mode != CredentialVisibility::AdminVisible {
        return Err(escrow_not_required());
    }
    let key = current_key_tx(&mut tx, &state).await?;
    if key.as_ref().is_none_or(|key| key.key_id != request.key_id) {
        return Err(escrow_key_mismatch());
    }
    let member: Option<i64> = sqlx::query_scalar(&format!(
        "SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
         WHERE vm.vault_id=? AND vm.user_id=? AND v.state='active' AND {ACTIVE_MEMBERSHIP}"
    ))
    .bind(&vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if member.is_none() {
        return Err(ApiError::not_found());
    }
    let delivered: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM vault_key_envelopes ke JOIN devices d \
           ON d.device_id=ke.recipient_device_id AND d.user_id=ke.recipient_user_id AND d.status='active' \
         WHERE ke.vault_id=? AND ke.epoch=? AND ke.recipient_user_id=?)",
    )
    .bind(&vault_id)
    .bind(key_epoch)
    .bind(&user.user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if !delivered {
        return Err(escrow_invalid(
            "this key epoch was not delivered to any active device of this account",
        ));
    }
    let signing_key = active_device_signing_key_tx(&mut tx, &user).await?;
    if !verify_device_signature(&signing_key, &request.signature, &signed) {
        return Err(escrow_invalid("deposit signature is invalid"));
    }
    let inserted = sqlx::query(
        "INSERT INTO credential_escrow_envelopes(vault_id,key_epoch,key_id,sealed,signature,\
         depositor_user_id,depositor_device_id,created_at) VALUES(?,?,?,?,?,?,?,?) \
         ON CONFLICT(vault_id,key_epoch,key_id) DO NOTHING",
    )
    .bind(&vault_id)
    .bind(key_epoch)
    .bind(&request.key_id)
    .bind(&request.sealed)
    .bind(&request.signature)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(crate::now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    if inserted.rows_affected() == 1 {
        Ok((StatusCode::CREATED, Json(json!({"status": "stored"}))))
    } else {
        Ok((StatusCode::OK, Json(json!({"status": "already_present"}))))
    }
}

// ---------------------------------------------------------------------------
// Administrator routes
// ---------------------------------------------------------------------------

async fn admin_policy_body(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    caller_user_id: &str,
) -> Result<Value, ApiError> {
    let default_mode = instance_default_tx(tx).await?;
    let key = current_key_tx(tx, state).await?;
    let caller_wrap = match key.as_ref() {
        Some(key) => sqlx::query_scalar::<_, String>(
            "SELECT wrap FROM credential_escrow_key_wraps WHERE key_id=? AND user_id=?",
        )
        .bind(&key.key_id)
        .bind(caller_user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .as_deref()
        .map(stored_json)
        .transpose()?,
        None => None,
    };
    let counts = sqlx::query(&format!(
        "SELECT \
         (SELECT COUNT(*) FROM users WHERE credential_visibility='admin_visible') AS admin_visible,\
         (SELECT COUNT(*) FROM users WHERE credential_visibility='private') AS private,\
         (SELECT COUNT(*) FROM users u WHERE ({})='pending') AS pending",
        escrow_status_sql("u")
    ))
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(json!({
        "default_mode": default_mode.as_str(),
        "escrow_key": key.as_ref().map(|key| descriptor(state, key)).transpose()?,
        "caller_wrap": caller_wrap,
        "recovery_wrap": key.as_ref().map(|key| stored_json(&key.recovery_wrap)).transpose()?,
        "counts": {
            "admin_visible": counts.get::<i64, _>("admin_visible"),
            "private": counts.get::<i64, _>("private"),
            "pending": counts.get::<i64, _>("pending"),
        },
    }))
}

/// `GET /api/v1/admin/credential-visibility`
pub async fn admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (user, mut tx) = require_admin_read(&state, &headers).await?;
    let body = admin_policy_body(&mut tx, &state, &user.user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(body))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateAdminPolicyRequest {
    default_mode: CredentialVisibility,
}

/// `PUT /api/v1/admin/credential-visibility`
pub async fn update_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<UpdateAdminPolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| invalid_mode_request("default_mode"))?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let current = instance_default_tx(&mut tx).await?;
    if current != request.default_mode {
        let now = chrono::Utc::now();
        sqlx::query(
            "INSERT INTO instance_credential_policy(id,default_visibility,updated_at,updated_by_user_id) \
             VALUES(1,?,?,?) ON CONFLICT(id) DO UPDATE SET default_visibility=excluded.default_visibility,\
             updated_at=excluded.updated_at,updated_by_user_id=excluded.updated_by_user_id",
        )
        .bind(request.default_mode.as_str())
        .bind(now.to_rfc3339_opts(SecondsFormat::Micros, true))
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "instance.credential_policy_changed",
            "instance_credential_policy",
            None,
            now.timestamp(),
        )
        .await?;
    }
    let body = admin_policy_body(&mut tx, &state, &user.user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(body))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateAccountModeRequest {
    mode: CredentialVisibility,
}

/// `PUT /api/v1/admin/accounts/{user_id}/credential-visibility`
pub async fn update_account_mode(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    request: Result<Json<UpdateAccountModeRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let actor = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| invalid_mode_request("mode"))?;
    validate_admin_account_id(&user_id)?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, &state, &actor).await?;
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let account_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let (current, mut changed_at) = account_mode_tx(&mut tx, &user_id)
        .await?
        .ok_or_else(ApiError::not_found)?;
    if current != request.mode {
        if request.mode == CredentialVisibility::AdminVisible && account_status == "deleting" {
            return Err(ApiError::conflict(
                "ACCOUNT_DELETING",
                "a deleting account cannot be made administrator visible",
            ));
        }
        let now = chrono::Utc::now();
        let stamp = now.to_rfc3339_opts(SecondsFormat::Micros, true);
        sqlx::query(
            "UPDATE users SET credential_visibility=?,credential_visibility_changed_at=? WHERE user_id=?",
        )
        .bind(request.mode.as_str())
        .bind(&stamp)
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if request.mode == CredentialVisibility::Private {
            // The account is already private in this transaction, so every
            // Vault it belongs to (or deposited for) loses its deposits
            // unless another active member is still admin_visible.
            for vault_id in escrowed_vaults_of_account_tx(&mut tx, &user_id).await? {
                prune_orphaned_escrow_tx(&mut tx, &vault_id).await?;
            }
        }
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &actor.user_id,
            &actor.device_id,
            "instance.credential_visibility_changed",
            "account",
            Some(&user_id),
            now.timestamp(),
        )
        .await?;
        audit::record_account_event_by_actor_tx(
            &mut tx,
            &state,
            &user_id,
            &actor.user_id,
            "account.credential_visibility_changed",
            "account",
            Some(&user_id),
            now.timestamp(),
        )
        .await?;
        changed_at = Some(stamp);
    }
    let escrow_status = account_escrow_status_tx(&mut tx, &user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "user_id": user_id,
        "mode": request.mode.as_str(),
        "changed_at": changed_at,
        "escrow_status": escrow_status,
    })))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateEscrowKeyRequest {
    key_id: String,
    public_key: String,
    creator_signature: String,
    account_wrap: AccountWrap,
    recovery_wrap: RecoveryWrap,
}

/// `POST /api/v1/admin/credential-escrow/key`
pub async fn create_escrow_key(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<CreateEscrowKeyRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        escrow_invalid(
            "request body must contain exactly key_id, public_key, creator_signature, \
             account_wrap and recovery_wrap",
        )
    })?;
    validate_key_id(&request.key_id)?;
    let public_key = decode_exact(&request.public_key, 32)
        .ok_or_else(|| escrow_invalid("public_key must be a base64url 32-byte X25519 key"))?;
    if public_key.iter().all(|byte| *byte == 0) {
        return Err(escrow_invalid("public_key is invalid"));
    }
    let account_wrap = request.account_wrap.validated_json()?;
    let recovery_wrap = request.recovery_wrap.validated_json()?;
    let creation = escrow_key_creation_bytes(
        &state.instance.instance_id,
        &request.key_id,
        &request.public_key,
        &user.user_id,
        &user.device_id,
    )?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let signing_key = active_device_signing_key_tx(&mut tx, &user).await?;
    if !verify_device_signature(&signing_key, &request.creator_signature, &creation) {
        return Err(escrow_invalid("creator_signature is invalid"));
    }
    if current_key_tx(&mut tx, &state).await?.is_some() {
        return Err(ApiError::conflict(
            "CREDENTIAL_ESCROW_KEY_EXISTS",
            "an escrow key already exists; reset it before creating another",
        ));
    }
    let now = chrono::Utc::now();
    let created_at = now.to_rfc3339_opts(SecondsFormat::Secs, true);
    let signed_payload = escrow_key_signed_payload(
        &state.instance.instance_id,
        &request.key_id,
        &request.public_key,
        &created_at,
    )?;
    let instance_signature =
        URL_SAFE_NO_PAD.encode(state.signing_key.sign(signed_payload.as_bytes()).to_bytes());
    sqlx::query(
        "INSERT INTO credential_escrow_keys(key_id,public_key,signed_payload,instance_signature,\
         creator_user_id,creator_device_id,creator_signature,recovery_wrap,created_at) \
         VALUES(?,?,?,?,?,?,?,?,?)",
    )
    .bind(&request.key_id)
    .bind(&request.public_key)
    .bind(&signed_payload)
    .bind(&instance_signature)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&request.creator_signature)
    .bind(&recovery_wrap)
    .bind(&created_at)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO credential_escrow_key_wraps(key_id,user_id,wrap,created_at) VALUES(?,?,?,?)",
    )
    .bind(&request.key_id)
    .bind(&user.user_id)
    .bind(&account_wrap)
    .bind(&created_at)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "instance.credential_escrow_key_created",
        "credential_escrow_key",
        Some(&request.key_id),
        now.timestamp(),
    )
    .await?;
    let key = current_key_tx(&mut tx, &state)
        .await?
        .ok_or_else(|| ApiError::internal("created escrow key is missing"))?;
    let escrow_key = descriptor(&state, &key)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(json!({"escrow_key": escrow_key}))))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StoreEscrowKeyWrapRequest {
    key_id: String,
    account_wrap: AccountWrap,
}

/// `PUT /api/v1/admin/credential-escrow/key/wrap` stores or replaces the
/// calling administrator's own wrap of the current escrow key.
pub async fn store_escrow_key_wrap(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<StoreEscrowKeyWrapRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request
        .map_err(|_| escrow_invalid("request body must contain exactly key_id and account_wrap"))?;
    validate_key_id(&request.key_id)?;
    let account_wrap = request.account_wrap.validated_json()?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let key = current_key_tx(&mut tx, &state).await?;
    if key.as_ref().is_none_or(|key| key.key_id != request.key_id) {
        return Err(escrow_key_mismatch());
    }
    let now = chrono::Utc::now();
    sqlx::query(
        "INSERT INTO credential_escrow_key_wraps(key_id,user_id,wrap,created_at) VALUES(?,?,?,?) \
         ON CONFLICT(key_id,user_id) DO UPDATE SET wrap=excluded.wrap,created_at=excluded.created_at",
    )
    .bind(&request.key_id)
    .bind(&user.user_id)
    .bind(&account_wrap)
    .bind(now.to_rfc3339_opts(SecondsFormat::Secs, true))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "instance.credential_escrow_key_wrap_stored",
        "credential_escrow_key",
        Some(&request.key_id),
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"status": "stored"})))
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResetEscrowKeyRequest {
    key_id: String,
    confirm: String,
}

/// `DELETE /api/v1/admin/credential-escrow/key` deletes the key, every
/// administrator wrap and every deposit (foreign-key cascade).
pub async fn reset_escrow_key(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<ResetEscrowKeyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request
        .map_err(|_| escrow_invalid("request body must contain exactly key_id and confirm"))?;
    validate_key_id(&request.key_id)?;
    if request.confirm != "reset" {
        return Err(escrow_invalid("confirm must be \"reset\""));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    admin::require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let key = current_key_tx(&mut tx, &state).await?;
    if key.as_ref().is_none_or(|key| key.key_id != request.key_id) {
        return Err(escrow_key_mismatch());
    }
    sqlx::query("DELETE FROM credential_escrow_keys WHERE key_id=?")
        .bind(&request.key_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "instance.credential_escrow_key_reset",
        "credential_escrow_key",
        Some(&request.key_id),
        chrono::Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"status": "reset"})))
}

/// `GET /api/v1/admin/credential-escrow/accounts/{user_id}/vaults`. Listing
/// sealed deposits is not itself a view of the account's credentials (reading
/// records is), but the deposits it releases open the Vault keys and Vault
/// names. So a listing that returns at least one deposit writes the instance
/// audit event `instance.credential_escrow_listed` (HMACed account ID) in the
/// same transaction.
pub async fn account_escrow_vaults(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let (admin_user, mut tx) = require_admin_write(&state, &headers).await?;
    validate_admin_account_id(&user_id)?;
    let account = sqlx::query("SELECT username,credential_visibility FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let mode =
        CredentialVisibility::from_stored(&account.get::<String, _>("credential_visibility"))?;
    let key = current_key_tx(&mut tx, &state).await?;
    let rows = sqlx::query(&format!(
        "SELECT v.vault_id,v.owner_user_id,v.name_envelope,v.active_epoch,\
         CASE WHEN vm.role='editor' AND EXISTS(SELECT 1 FROM cloud_member_restrictions rr \
           WHERE rr.vault_id=vm.vault_id AND rr.user_id=vm.user_id AND rr.max_role='viewer') \
           THEN 'viewer' ELSE vm.role END AS role \
         FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
         WHERE vm.user_id=? AND v.state='active' AND {ACTIVE_MEMBERSHIP} \
         ORDER BY v.created_at,v.vault_id"
    ))
    .bind(&user_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut vaults = Vec::with_capacity(rows.len());
    for row in rows {
        let vault_id: String = row.get("vault_id");
        // Deposits are offered only for an admin_visible account and only
        // under the current key; a private account's list carries none. A
        // purged depositor's key comes from the Vault-scoped device archive,
        // like the ordinary member device directory.
        let escrow = match (&key, mode) {
            (Some(key), CredentialVisibility::AdminVisible) => sqlx::query(
                "SELECT ce.key_epoch,ce.sealed,ce.signature,ce.depositor_device_id,\
                 COALESCE(d.signing_public_key,(SELECT a.signing_public_key FROM vault_device_archives a \
                   WHERE a.vault_id=ce.vault_id AND a.device_id=ce.depositor_device_id)) \
                   AS depositor_signing_public_key \
                 FROM credential_escrow_envelopes ce LEFT JOIN devices d ON d.device_id=ce.depositor_device_id \
                 WHERE ce.vault_id=? AND ce.key_id=? ORDER BY ce.key_epoch",
            )
            .bind(&vault_id)
            .bind(&key.key_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .into_iter()
            .map(|row| {
                json!({
                    "key_epoch": row.get::<i64, _>("key_epoch"),
                    "sealed": row.get::<String, _>("sealed"),
                    "signature": row.get::<String, _>("signature"),
                    "depositor_device_id": row.get::<Option<String>, _>("depositor_device_id"),
                    "depositor_signing_public_key":
                        row.get::<Option<String>, _>("depositor_signing_public_key"),
                })
            })
            .collect::<Vec<_>>(),
            _ => Vec::new(),
        };
        vaults.push(json!({
            "vault_id": vault_id,
            "role": row.get::<String, _>("role"),
            "owner_user_id": row.get::<String, _>("owner_user_id"),
            "name_envelope": row
                .get::<Option<String>, _>("name_envelope")
                .and_then(|value| serde_json::from_str::<Value>(&value).ok()),
            "active_epoch": row.get::<i64, _>("active_epoch"),
            "escrow": escrow,
        }));
    }
    let released = vaults.iter().any(|vault| {
        vault["escrow"]
            .as_array()
            .is_some_and(|escrow| !escrow.is_empty())
    });
    if released {
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &admin_user.user_id,
            &admin_user.device_id,
            "instance.credential_escrow_listed",
            "account",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account": {
            "user_id": user_id,
            "username": account.get::<String, _>("username"),
            "mode": mode.as_str(),
        },
        "vaults": vaults,
    })))
}

#[derive(Debug, Deserialize)]
pub struct EscrowedRecordsQuery {
    user_id: Option<String>,
    after: Option<String>,
    limit: Option<String>,
}

/// `GET /api/v1/admin/credential-escrow/vaults/{vault_id}/records`
///
/// Returns current, non-deleted, non-redacted record heads exactly as the
/// sync read path stores them. Each served page writes an instance audit
/// event and is a recorded view for every active member of the Vault and for
/// every account that authored a served record (see `record_admin_view_tx`).
pub async fn escrowed_vault_records(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Query(query): Query<EscrowedRecordsQuery>,
) -> Result<Json<Value>, ApiError> {
    let (admin_user, mut tx) = require_admin_write(&state, &headers).await?;
    if !crate::is_canonical_uuid(&vault_id) {
        return Err(ApiError::bad_request(
            "INVALID_VAULT_ID",
            "vault id must use canonical lowercase UUID format",
        ));
    }
    let target = query.user_id.as_deref().ok_or_else(|| {
        ApiError::bad_request("INVALID_ACCOUNT_ID", "user_id query parameter is required")
    })?;
    validate_admin_account_id(target)?;
    if let Some(after) = query.after.as_deref()
        && !crate::is_canonical_uuid(after)
    {
        return Err(ApiError::bad_request(
            "INVALID_CURSOR",
            "after must be a record ID from a previous page",
        ));
    }
    let limit = match query.limit.as_deref() {
        None => DEFAULT_RECORD_PAGE,
        Some(value) => value
            .parse::<u32>()
            .ok()
            .filter(|limit| (1..=MAX_RECORD_PAGE).contains(limit))
            .ok_or_else(|| {
                ApiError::bad_request("INVALID_LIMIT", "limit must be an integer from 1 to 500")
            })?,
    };
    state
        .cloud
        .rate
        .check(
            &format!("credential-escrow-records:{}", admin_user.user_id),
            RECORD_PAGES_PER_MINUTE,
            60,
            chrono::Utc::now().timestamp(),
        )
        .map_err(|retry| {
            ApiError::new(
                StatusCode::TOO_MANY_REQUESTS,
                "RATE_LIMITED",
                "too many requests; try again later",
            )
            .with_retry_after(retry)
        })?;

    let target_mode: Option<String> =
        sqlx::query_scalar("SELECT credential_visibility FROM users WHERE user_id=?")
            .bind(target)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if target_mode.as_deref() != Some(CredentialVisibility::AdminVisible.as_str()) {
        return Err(escrow_not_available());
    }
    let available: bool = sqlx::query_scalar(&format!(
        "SELECT EXISTS(SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
           WHERE vm.vault_id=? AND vm.user_id=? AND v.state='active' AND {ACTIVE_MEMBERSHIP}) \
         AND EXISTS(SELECT 1 FROM credential_escrow_envelopes ce \
           JOIN credential_escrow_keys ck ON ck.key_id=ce.key_id WHERE ce.vault_id=?)"
    ))
    .bind(&vault_id)
    .bind(target)
    .bind(&vault_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if !available {
        return Err(escrow_not_available());
    }
    // Same read-side gates as ordinary sync reads.
    crate::require_redaction_client_for_vault_tx(
        &mut tx,
        &vault_id,
        admin_user.declares_sync_redaction_v1,
    )
    .await?;
    let mut sql = String::from(
        "SELECT h.record_id,h.revision_id,v.envelope,v.device_id AS author_device_id,\
         COALESCE(d.signing_public_key,(SELECT a.signing_public_key FROM vault_device_archives a \
           WHERE a.vault_id=h.vault_id AND a.device_id=v.device_id)) AS author_signing_public_key \
         FROM record_heads h JOIN record_versions v ON v.vault_id=h.vault_id \
           AND v.record_id=h.record_id AND v.revision_id=h.revision_id AND v.commit_seq=h.commit_seq \
         LEFT JOIN devices d ON d.device_id=v.device_id \
         WHERE h.vault_id=? AND h.deleted=0 \
           AND NOT EXISTS(SELECT 1 FROM record_redactions red \
             WHERE red.vault_id=h.vault_id AND red.record_id=h.record_id)",
    );
    if query.after.is_some() {
        sql.push_str(" AND h.record_id COLLATE BINARY>?");
    }
    sql.push_str(" ORDER BY h.record_id COLLATE BINARY LIMIT ?");
    let mut rows_query = sqlx::query(&sql).bind(&vault_id);
    if let Some(after) = query.after.as_deref() {
        rows_query = rows_query.bind(after);
    }
    let rows = rows_query
        .bind(i64::from(limit) + 1)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let mut records = Vec::new();
    let mut budget = crate::sync::SyncPageBudget::default();
    let mut has_more = false;
    for row in rows {
        if records.len() >= limit as usize {
            has_more = true;
            break;
        }
        let envelope: Value =
            serde_json::from_str(&row.get::<String, _>("envelope")).map_err(ApiError::internal)?;
        crate::sync::ensure_envelope_readable(admin_user.declares_record_schema2, &envelope)?;
        let record = json!({
            "record_id": row.get::<String, _>("record_id"),
            "revision_id": row.get::<String, _>("revision_id"),
            "envelope": envelope,
            "author_device_id": row.get::<String, _>("author_device_id"),
            "author_signing_public_key": row.get::<Option<String>, _>("author_signing_public_key"),
        });
        if !budget.try_add(&record)? {
            if records.is_empty() {
                return Err(crate::sync::sync_page_item_too_large());
            }
            has_more = true;
            break;
        }
        records.push(record);
    }
    let next_after = if has_more {
        records
            .last()
            .and_then(|record| record["record_id"].as_str())
            .map(str::to_owned)
    } else {
        None
    };
    let authors = records
        .iter()
        .filter_map(|record| record["author_device_id"].as_str())
        .map(str::to_owned)
        .collect::<std::collections::BTreeSet<_>>();
    record_admin_view_tx(&mut tx, &state, &admin_user, target, &vault_id, &authors).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"records": records, "next_after": next_after})))
}

/// Records one served page of escrowed records.
///
/// * `instance.credential_escrow_viewed` is written for every page and is
///   never coalesced, so the administrator accountability log counts each
///   read.
/// * Every active member of the Vault is affected, not only the account the
///   administrator named: a shared Vault's records include other members'
///   entries. Each of them (including the target, and including `private`
///   members of a Vault that is administrator visible through another
///   member) gets a `credential_admin_views` row and an account-scope
///   `account.credential_viewed_by_admin` event. Those user-facing entries
///   are coalesced per (administrator, account, Vault) within ten minutes,
///   and the newest 200 view rows per account are kept.
/// * So is every still existing account that authored a served record
///   (`author_device_ids` of the page), even when its membership is now
///   hidden by an organization `none` restriction or revoked: the read
///   exposed what that account saved, and hiding is reversible. Authors are
///   resolved through `devices`, or the Vault's device archive for devices
///   of purged accounts (which have no account left to tell).
async fn record_admin_view_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    admin_user: &auth::AuthUser,
    target_user_id: &str,
    vault_id: &str,
    author_device_ids: &std::collections::BTreeSet<String>,
) -> Result<(), ApiError> {
    let occurred_at = chrono::Utc::now().timestamp();
    audit::record_instance_admin_event_tx(
        tx,
        state,
        &admin_user.user_id,
        &admin_user.device_id,
        "instance.credential_escrow_viewed",
        "account",
        Some(target_user_id),
        occurred_at,
    )
    .await?;
    let mut affected: Vec<String> = sqlx::query_scalar(&format!(
        "SELECT vm.user_id FROM vault_members vm WHERE vm.vault_id=? AND {ACTIVE_MEMBERSHIP} \
         ORDER BY vm.user_id"
    ))
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    // The caller's gate already proved the target is an active member in
    // this transaction; never let a missing row drop its own entry.
    if !affected.iter().any(|user_id| user_id == target_user_id) {
        affected.push(target_user_id.to_owned());
    }
    for device_id in author_device_ids {
        let author: Option<String> = sqlx::query_scalar(
            "SELECT u.user_id FROM users u WHERE u.user_id=COALESCE(\
               (SELECT d.user_id FROM devices d WHERE d.device_id=?),\
               (SELECT a.user_id FROM vault_device_archives a WHERE a.vault_id=? AND a.device_id=?))",
        )
        .bind(device_id)
        .bind(vault_id)
        .bind(device_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if let Some(author) = author
            && !affected.contains(&author)
        {
            affected.push(author);
        }
    }
    for user_id in &affected {
        record_member_view_tx(tx, state, admin_user, user_id, vault_id, occurred_at).await?;
    }
    Ok(())
}

/// The user-facing part of a recorded view for one affected account.
async fn record_member_view_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    admin_user: &auth::AuthUser,
    user_id: &str,
    vault_id: &str,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let recent: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM credential_admin_views WHERE target_user_id=? \
         AND admin_user_id=? AND vault_id=? AND viewed_at>=?)",
    )
    .bind(user_id)
    .bind(&admin_user.user_id)
    .bind(vault_id)
    .bind(micros_ago(ADMIN_VIEW_COALESCE_SECONDS))
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if recent {
        return Ok(());
    }
    sqlx::query(
        "INSERT INTO credential_admin_views(view_id,target_user_id,admin_user_id,vault_id,viewed_at) \
         VALUES(?,?,?,?,?)",
    )
    .bind(Uuid::new_v4().to_string())
    .bind(user_id)
    .bind(&admin_user.user_id)
    .bind(vault_id)
    .bind(now_micros())
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "DELETE FROM credential_admin_views WHERE target_user_id=? AND view_id NOT IN (\
           SELECT view_id FROM credential_admin_views WHERE target_user_id=? \
           ORDER BY viewed_at DESC,view_id DESC LIMIT ?)",
    )
    .bind(user_id)
    .bind(user_id)
    .bind(ADMIN_VIEWS_RETAINED)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    audit::record_account_event_by_actor_tx(
        tx,
        state,
        user_id,
        &admin_user.user_id,
        "account.credential_viewed_by_admin",
        "vault",
        Some(vault_id),
        occurred_at,
    )
    .await
}

/// Shared by the HTTP invitation route and the operator CLI.
pub(crate) fn parse_invitation_mode(
    value: Option<&str>,
) -> Result<Option<CredentialVisibility>, ApiError> {
    value
        .map(|value| {
            CredentialVisibility::parse(value).ok_or_else(|| {
                ApiError::bad_request(
                    "INVALID_CREDENTIAL_VISIBILITY",
                    "credential visibility must be 'private' or 'admin_visible'",
                )
            })
        })
        .transpose()
}

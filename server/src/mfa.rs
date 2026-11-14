use std::net::SocketAddr;

use axum::{
    Json,
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chacha20poly1305::{
    KeyInit, XChaCha20Poly1305, XNonce,
    aead::{Aead, Payload},
};
use chrono::{DateTime, SecondsFormat, Utc};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha1::Sha1;
use sha2::Sha256;
use sqlx::{Row, Sqlite, Transaction};
use uuid::Uuid;
use zeroize::{Zeroize, Zeroizing};

use crate::{ApiError, AppState, auth, rate_limit};

type HmacSha1 = Hmac<Sha1>;
type HmacSha256 = Hmac<Sha256>;

pub(crate) const TOTP_PERIOD_SECONDS: i64 = 30;
pub(crate) const RECOVERY_CODE_COUNT: usize = 10;
const TOTP_DIGITS: u32 = 6;
pub(crate) const TOTP_SETUP_TTL_SECONDS: i64 = 600;
pub(crate) const LOGIN_CHALLENGE_TTL_SECONDS: i64 = 300;
pub(crate) const MAX_LOGIN_CHALLENGE_ATTEMPTS: i64 = 5;
pub(crate) const MAX_OUTSTANDING_LOGIN_CHALLENGES: i64 = 5;
const MFA_SEED_DOMAIN: &[u8] = b"atermius/mfa-totp-seed/v1\0";
const RECOVERY_CODE_DOMAIN: &[u8] = b"atermius/mfa-recovery-code/v1\0";
const MFA_UNAVAILABLE_CODE: &str = "MFA_KEY_UNAVAILABLE";

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct SeedEnvelopeRotationCounts {
    pub(crate) active: u64,
    pub(crate) pending: u64,
}

#[derive(Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MfaStatus {
    pub(crate) enabled: bool,
    pub(crate) recovery_codes_remaining: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct StepUpRequest {
    pub(crate) current_login_verifier: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct ConfirmTotpRequest {
    pub(crate) current_login_verifier: String,
    pub(crate) totp_code: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct MfaLoginRequest {
    pub(crate) challenge_id: String,
    #[serde(default)]
    pub(crate) totp_code: Option<String>,
    #[serde(default)]
    pub(crate) recovery_code: Option<String>,
}

#[derive(Serialize)]
pub(super) struct SetupResponse {
    pub(crate) secret: String,
    pub(crate) provisioning_uri: String,
    pub(crate) expires_at: String,
}

#[derive(Serialize)]
pub(super) struct RecoveryCodesResponse {
    pub(crate) recovery_codes: Vec<String>,
}

#[derive(Serialize)]
pub(crate) struct RecoveryCodeRow {
    pub(crate) code_id: String,
    pub(crate) salt: String,
    pub(crate) code_hash: String,
    pub(crate) created_at: i64,
}

pub(crate) fn mfa_unavailable() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        MFA_UNAVAILABLE_CODE,
        "MFA is temporarily unavailable",
    )
}

pub(crate) fn encryption_key(state: &AppState) -> Result<&[u8; 32], ApiError> {
    state
        .mfa_encryption_key
        .as_deref()
        .ok_or_else(mfa_unavailable)
}

pub(super) async fn status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<MfaStatus>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_mfa.as_ref() {
        return repository.status(&user).await.map(Json);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, &user).await?;
    let enabled: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_mfa WHERE user_id=? AND enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL",
    )
    .bind(&user.user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let recovery_codes_remaining = if enabled == 0 {
        0
    } else {
        sqlx::query_scalar(
            "SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=? AND consumed_at IS NULL",
        )
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?
    };
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(MfaStatus {
        enabled: enabled == 1,
        recovery_codes_remaining,
    }))
}

pub(super) async fn setup_totp(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<StepUpRequest>,
) -> Result<Json<SetupResponse>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_mfa.as_ref() {
        return repository
            .setup_totp(&state, &user, peer, &request.current_login_verifier)
            .await
            .map(Json);
    }
    let key = encryption_key(&state)?;
    let (credential_hash, credential_version, username) =
        verify_step_up(&state, &user, peer, &request.current_login_verifier).await?;

    let mut seed = Zeroizing::new(vec![0_u8; 20]);
    rand::thread_rng().fill_bytes(&mut seed);
    let secret = base32_encode(&seed);
    let envelope = encrypt_seed(key, &user.user_id, &seed)?;
    let expires = Utc::now().timestamp() + TOTP_SETUP_TTL_SECONDS;
    let expires_at = timestamp_rfc3339(expires)?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    ensure_credential_snapshot(&mut tx, &user.user_id, &credential_hash, credential_version)
        .await?;
    let changed = sqlx::query(
        "INSERT INTO auth_mfa(user_id,pending_seed_envelope,pending_expires_at,pending_credential_version) \
         VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET \
         pending_seed_envelope=excluded.pending_seed_envelope, \
         pending_expires_at=excluded.pending_expires_at, \
         pending_credential_version=excluded.pending_credential_version \
         WHERE auth_mfa.enabled_at IS NULL AND auth_mfa.totp_seed_envelope IS NULL",
    )
    .bind(&user.user_id)
    .bind(envelope)
    .bind(expires)
    .bind(credential_version)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "MFA_ALREADY_ENABLED",
            "TOTP is already enabled for this account",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;

    let issuer = "Atermius";
    let label = format!(
        "{}:{}",
        percent_encode_component(issuer),
        percent_encode_component(&username)
    );
    let provisioning_uri = format!(
        "otpauth://totp/{label}?secret={secret}&issuer={}&algorithm=SHA1&digits=6&period=30",
        percent_encode_component(issuer),
    );
    Ok(Json(SetupResponse {
        secret,
        provisioning_uri,
        expires_at,
    }))
}

pub(super) async fn confirm_totp(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<ConfirmTotpRequest>,
) -> Result<Json<RecoveryCodesResponse>, ApiError> {
    validate_totp_code(&request.totp_code).map_err(|_| ApiError::reauth_required())?;
    let user = auth::authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_mfa.as_ref() {
        return repository
            .confirm_totp(
                &state,
                &user,
                peer,
                &request.current_login_verifier,
                &request.totp_code,
            )
            .await
            .map(Json);
    }
    let key = encryption_key(&state)?;
    let (credential_hash, credential_version, _) =
        verify_step_up(&state, &user, peer, &request.current_login_verifier).await?;
    let (codes, rows) = generate_recovery_codes();
    let now = Utc::now().timestamp();

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    ensure_credential_snapshot(&mut tx, &user.user_id, &credential_hash, credential_version)
        .await?;
    let pending: Option<(String, i64, i64)> = sqlx::query_as(
        "SELECT pending_seed_envelope,pending_expires_at,pending_credential_version \
         FROM auth_mfa WHERE user_id=? AND enabled_at IS NULL AND totp_seed_envelope IS NULL",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((envelope, expires_at, pending_version)) = pending else {
        return Err(ApiError::conflict(
            "MFA_SETUP_REQUIRED",
            "start a new TOTP setup before confirming",
        ));
    };
    if expires_at <= now || pending_version != credential_version {
        sqlx::query("DELETE FROM auth_mfa WHERE user_id=? AND enabled_at IS NULL")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::conflict(
            "MFA_SETUP_EXPIRED",
            "TOTP setup expired; start setup again",
        ));
    }
    let seed = decrypt_seed(key, &user.user_id, &envelope)?;
    let Some(step) = matching_totp_step(&seed, &request.totp_code, now) else {
        return Err(ApiError::reauth_required());
    };
    let enabled_at = Utc::now().timestamp();
    let changed = sqlx::query(
        "UPDATE auth_mfa SET totp_seed_envelope=pending_seed_envelope,enabled_at=?,last_totp_step=?, \
         pending_seed_envelope=NULL,pending_expires_at=NULL,pending_credential_version=NULL \
         WHERE user_id=? AND enabled_at IS NULL AND pending_seed_envelope=? \
         AND pending_expires_at>? AND pending_credential_version=?",
    )
    .bind(enabled_at)
    .bind(step)
    .bind(&user.user_id)
    .bind(&envelope)
    .bind(now)
    .bind(credential_version)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "MFA_SETUP_CHANGED",
            "TOTP setup changed; start again",
        ));
    }
    insert_recovery_codes(&mut tx, &user.user_id, &rows).await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.mfa_totp_enabled",
        "account",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        enabled_at,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(RecoveryCodesResponse {
        recovery_codes: codes,
    }))
}

pub(super) async fn rotate_recovery_codes(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<ConfirmTotpRequest>,
) -> Result<Json<RecoveryCodesResponse>, ApiError> {
    validate_totp_code(&request.totp_code).map_err(|_| ApiError::reauth_required())?;
    let user = auth::authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_mfa.as_ref() {
        return repository
            .rotate_recovery_codes(
                &state,
                &user,
                peer,
                &request.current_login_verifier,
                &request.totp_code,
            )
            .await
            .map(Json);
    }
    let key = encryption_key(&state)?;
    let (credential_hash, credential_version, _) =
        verify_step_up(&state, &user, peer, &request.current_login_verifier).await?;
    let (codes, rows) = generate_recovery_codes();
    let now = Utc::now().timestamp();

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    ensure_credential_snapshot(&mut tx, &user.user_id, &credential_hash, credential_version)
        .await?;
    let stored: Option<(String, i64)> = sqlx::query_as(
        "SELECT totp_seed_envelope,last_totp_step FROM auth_mfa \
         WHERE user_id=? AND enabled_at IS NOT NULL",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((envelope, last_step)) = stored else {
        return Err(ApiError::conflict("MFA_NOT_ENABLED", "TOTP is not enabled"));
    };
    let seed = decrypt_seed(key, &user.user_id, &envelope)?;
    let Some(step) = matching_totp_step(&seed, &request.totp_code, now) else {
        return Err(ApiError::reauth_required());
    };
    if !advance_totp_step(&mut tx, &user.user_id, last_step, step).await? {
        return Err(ApiError::reauth_required());
    }
    sqlx::query("DELETE FROM auth_mfa_recovery_codes WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    insert_recovery_codes(&mut tx, &user.user_id, &rows).await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.mfa_recovery_codes_rotated",
        "account",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(RecoveryCodesResponse {
        recovery_codes: codes,
    }))
}

pub(super) async fn disable_totp(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<ConfirmTotpRequest>,
) -> Result<Json<MfaStatus>, ApiError> {
    validate_totp_code(&request.totp_code).map_err(|_| ApiError::reauth_required())?;
    let user = auth::authenticate(&state, &headers).await?;
    if let Some(repository) = state.pg_mfa.as_ref() {
        return repository
            .disable_totp(
                &state,
                &user,
                peer,
                &request.current_login_verifier,
                &request.totp_code,
            )
            .await
            .map(Json);
    }
    let key = encryption_key(&state)?;
    let (credential_hash, credential_version, _) =
        verify_step_up(&state, &user, peer, &request.current_login_verifier).await?;
    let now = Utc::now().timestamp();

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    ensure_credential_snapshot(&mut tx, &user.user_id, &credential_hash, credential_version)
        .await?;
    let stored: Option<(String, i64)> = sqlx::query_as(
        "SELECT totp_seed_envelope,last_totp_step FROM auth_mfa \
         WHERE user_id=? AND enabled_at IS NOT NULL",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((envelope, last_step)) = stored else {
        return Err(ApiError::conflict("MFA_NOT_ENABLED", "TOTP is not enabled"));
    };
    let seed = decrypt_seed(key, &user.user_id, &envelope)?;
    let Some(step) = matching_totp_step(&seed, &request.totp_code, now) else {
        return Err(ApiError::reauth_required());
    };
    if !advance_totp_step(&mut tx, &user.user_id, last_step, step).await? {
        return Err(ApiError::reauth_required());
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "auth.mfa_totp_disabled",
        "account",
        Some(&user.user_id),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    sqlx::query("DELETE FROM auth_mfa WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(MfaStatus {
        enabled: false,
        recovery_codes_remaining: 0,
    }))
}

/// Completes a password-verified login challenge. Challenge consumption,
/// TOTP-step advancement or recovery-code consumption, session creation and
/// success audit are one SQLite writer transaction.
pub(super) async fn login(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<MfaLoginRequest>,
) -> Result<Response, ApiError> {
    if !crate::is_canonical_uuid(&request.challenge_id)
        || request.totp_code.is_some() == request.recovery_code.is_some()
    {
        return Err(ApiError::unauthorized());
    }
    if let Some(code) = &request.totp_code {
        validate_totp_code(code).map_err(|_| ApiError::unauthorized())?;
    }
    if let Some(code) = &request.recovery_code {
        normalize_recovery_code(code).map_err(|_| ApiError::unauthorized())?;
    }
    if let Some(repository) = state.pg_mfa.as_ref() {
        let session = repository
            .complete_login(
                &state,
                peer,
                &request.challenge_id,
                request.totp_code.as_deref(),
                request.recovery_code.as_deref(),
            )
            .await?;
        return Ok(Json(session).into_response());
    }
    let challenge_hash = crate::sha256_hex(request.challenge_id.as_bytes());
    let now = Utc::now().timestamp();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let challenge: Option<(String, String, i64, i64, Option<i64>, i64, String)> = sqlx::query_as(
        "SELECT c.user_id,c.device_id,c.credential_version,c.expires_at,c.consumed_at, \
         c.attempt_count,u.username FROM auth_mfa_login_challenges c \
         JOIN users u ON u.user_id=c.user_id WHERE c.challenge_id_hash=?",
    )
    .bind(&challenge_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((user_id, device_id, credential_version, expires_at, consumed_at, attempts, username)) =
        challenge
    else {
        return Err(ApiError::unauthorized());
    };
    if consumed_at.is_some() || expires_at <= now || attempts >= MAX_LOGIN_CHALLENGE_ATTEMPTS {
        return Err(ApiError::unauthorized());
    }
    let retry_after = rate_limit::consume(
        &state,
        &mut tx,
        rate_limit::AuthOperation::MfaLogin,
        &username,
        Some(peer.ip()),
    )
    .await?;
    if let Some(retry_after) = retry_after {
        // Persist the denied attempt as well. Dropping this transaction would
        // roll back the bucket increments and make the limit ineffective.
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::rate_limited(retry_after));
    }

    let current: Option<(
        String,
        i64,
        String,
        String,
        Option<String>,
        Option<i64>,
        Option<i64>,
    )> = sqlx::query_as(
        "SELECT u.status,c.credential_version,d.status,c.login_verifier_hash, \
             m.totp_seed_envelope,m.enabled_at,m.last_totp_step \
             FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
             JOIN devices d ON d.user_id=u.user_id AND d.device_id=? \
             JOIN auth_mfa m ON m.user_id=u.user_id \
             WHERE u.user_id=?",
    )
    .bind(&device_id)
    .bind(&user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((
        account_status,
        current_version,
        device_status,
        _verifier_hash,
        seed_envelope,
        enabled_at,
        last_step,
    )) = current
    else {
        consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::unauthorized());
    };
    if account_status != "active"
        || device_status != "active"
        || current_version != credential_version
        || enabled_at.is_none()
    {
        consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::unauthorized());
    }

    let mut factor_valid = false;
    if let Some(code) = request.totp_code.as_deref() {
        let key = encryption_key(&state)?;
        let seed_envelope =
            seed_envelope.ok_or_else(|| ApiError::internal("stored MFA seed is missing"))?;
        let seed = decrypt_seed(key, &user_id, &seed_envelope)?;
        if let Some(step) = matching_totp_step(&seed, code, now) {
            if let Some(last_step) = last_step
                && advance_totp_step(&mut tx, &user_id, last_step, step).await?
            {
                factor_valid = true;
            }
        }
    } else if let Some(code) = request.recovery_code.as_deref() {
        factor_valid = consume_recovery_code(&mut tx, &user_id, code, now).await?;
    }

    if !factor_valid {
        let next_attempt = attempts + 1;
        sqlx::query(
            "UPDATE auth_mfa_login_challenges SET attempt_count=?,consumed_at=CASE WHEN ?>=5 THEN ? ELSE consumed_at END \
             WHERE challenge_id_hash=? AND consumed_at IS NULL",
        )
        .bind(next_attempt)
        .bind(next_attempt)
        .bind(now)
        .bind(&challenge_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        crate::audit::record_failed_login_tx(&mut tx, &state, &user_id, now).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::unauthorized());
    }

    let consumed = sqlx::query(
        "UPDATE auth_mfa_login_challenges SET consumed_at=? WHERE challenge_id_hash=? \
         AND consumed_at IS NULL AND expires_at>? AND credential_version=?",
    )
    .bind(now)
    .bind(&challenge_hash)
    .bind(now)
    .bind(credential_version)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if consumed.rows_affected() != 1 {
        return Err(ApiError::unauthorized());
    }
    let tokens = auth::insert_session(&mut tx, &user_id, &device_id).await?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user_id,
        Some(&device_id),
        "auth.login_succeeded",
        "account",
        Some(&user_id),
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    let session = auth::session_response(&state, user_id, device_id, tokens).await?;
    Ok(Json(session).into_response())
}

/// Creates a short-lived, credential-version-bound challenge only after the
/// password and registered device have been verified and rechecked in the
/// writer transaction. No bearer or refresh token is issued here.
pub(crate) async fn create_login_challenge_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    device_id: &str,
    credential_version: i64,
    now: i64,
) -> Result<(String, String), ApiError> {
    sqlx::query(
        "DELETE FROM auth_mfa_login_challenges WHERE expires_at<=? OR consumed_at IS NOT NULL",
    )
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let outstanding: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_mfa_login_challenges WHERE user_id=? AND consumed_at IS NULL AND expires_at>?",
    )
    .bind(user_id)
    .bind(now)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if outstanding >= MAX_OUTSTANDING_LOGIN_CHALLENGES {
        return Err(ApiError::rate_limited(60));
    }
    let challenge_id = Uuid::new_v4().to_string();
    let challenge_hash = crate::sha256_hex(challenge_id.as_bytes());
    let expires_at = now + LOGIN_CHALLENGE_TTL_SECONDS;
    sqlx::query(
        "INSERT INTO auth_mfa_login_challenges(challenge_id_hash,user_id,device_id,credential_version,expires_at) VALUES(?,?,?,?,?)",
    )
    .bind(&challenge_hash)
    .bind(user_id)
    .bind(device_id)
    .bind(credential_version)
    .bind(expires_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok((challenge_id, timestamp_rfc3339(expires_at)?))
}

/// Invalidates MFA state that could otherwise be replayed after restoring an
/// older database snapshot. The seed remains enabled, but the replay marker is
/// moved forward, saved recovery codes are consumed, and any incomplete setup
/// or challenge from the snapshot is discarded. The caller includes this in
/// the same transaction that rotates the restored server generation/revokes
/// sessions.
pub(crate) async fn invalidate_after_restore_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    now: i64,
) -> Result<(), ApiError> {
    let current_step = now.div_euclid(TOTP_PERIOD_SECONDS);
    sqlx::query("DELETE FROM auth_mfa_login_challenges")
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM auth_mfa WHERE enabled_at IS NULL")
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(
        "UPDATE auth_mfa SET last_totp_step=MAX(last_totp_step,?), \
         pending_seed_envelope=NULL,pending_expires_at=NULL,pending_credential_version=NULL \
         WHERE enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL",
    )
    .bind(current_step)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("UPDATE auth_mfa_recovery_codes SET consumed_at=? WHERE consumed_at IS NULL")
        .bind(now)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;

    let enabled_users: Vec<String> = sqlx::query_scalar(
        "SELECT user_id FROM auth_mfa WHERE enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for user_id in enabled_users {
        crate::audit::record_account_event_tx(
            tx,
            state,
            &user_id,
            None,
            "auth.mfa_state_reset_by_restore",
            "account",
            Some(&user_id),
            crate::audit::AuditSource::Maintenance,
            now,
        )
        .await?;
    }
    Ok(())
}

async fn verify_step_up(
    state: &AppState,
    user: &auth::AuthUser,
    peer: SocketAddr,
    verifier: &str,
) -> Result<(String, i64, String), ApiError> {
    let username: String = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(&user.user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::reauth_required)?;
    let username = auth::normalized_username(&username)?;
    let mut rate_tx = state.db.begin().await.map_err(ApiError::internal)?;
    let retry_after = rate_limit::consume(
        state,
        &mut rate_tx,
        rate_limit::AuthOperation::Login,
        &username,
        Some(peer.ip()),
    )
    .await?;
    rate_tx.commit().await.map_err(ApiError::internal)?;
    if let Some(retry_after) = retry_after {
        return Err(ApiError::rate_limited(retry_after));
    }
    let credential_hash =
        auth::verify_login_verifier_for_user(state, &user.user_id, verifier).await?;
    let credential_version: i64 =
        sqlx::query_scalar("SELECT credential_version FROM auth_credentials WHERE user_id=?")
            .bind(&user.user_id)
            .fetch_one(&state.db)
            .await
            .map_err(ApiError::internal)?;
    Ok((credential_hash, credential_version, username))
}

async fn ensure_credential_snapshot(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    expected_hash: &str,
    expected_version: i64,
) -> Result<(), ApiError> {
    let current: Option<(String, i64)> = sqlx::query_as(
        "SELECT login_verifier_hash,credential_version FROM auth_credentials WHERE user_id=?",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    match current {
        Some((hash, version)) if hash == expected_hash && version == expected_version => Ok(()),
        _ => Err(ApiError::reauth_required()),
    }
}

async fn advance_totp_step(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    previous_step: i64,
    next_step: i64,
) -> Result<bool, ApiError> {
    if next_step <= previous_step {
        return Ok(false);
    }
    let update = sqlx::query(
        "UPDATE auth_mfa SET last_totp_step=? WHERE user_id=? AND enabled_at IS NOT NULL AND last_totp_step=? AND last_totp_step<?",
    )
    .bind(next_step)
    .bind(user_id)
    .bind(previous_step)
    .bind(next_step)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(update.rows_affected() == 1)
}

async fn consume_stale_challenge(
    tx: &mut Transaction<'_, Sqlite>,
    challenge_hash: &str,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query("UPDATE auth_mfa_login_challenges SET consumed_at=? WHERE challenge_id_hash=? AND consumed_at IS NULL")
        .bind(now)
        .bind(challenge_hash)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) fn generate_recovery_codes() -> (Vec<String>, Vec<RecoveryCodeRow>) {
    let now = Utc::now().timestamp();
    let mut plain = Vec::with_capacity(RECOVERY_CODE_COUNT);
    let mut rows = Vec::with_capacity(RECOVERY_CODE_COUNT);
    for _ in 0..RECOVERY_CODE_COUNT {
        let mut raw = [0_u8; 10];
        let mut salt = [0_u8; 16];
        rand::thread_rng().fill_bytes(&mut raw);
        rand::thread_rng().fill_bytes(&mut salt);
        let encoded = base32_encode(&raw);
        raw.zeroize();
        let code = format!(
            "{}-{}-{}-{}",
            &encoded[0..4],
            &encoded[4..8],
            &encoded[8..12],
            &encoded[12..16]
        );
        // Hash the canonical display-independent value so accepted lower-case
        // or separator-free input verifies to the same one-time code.
        let digest = recovery_code_digest(&salt, &encoded).expect("fixed HMAC key length is valid");
        plain.push(code);
        rows.push(RecoveryCodeRow {
            code_id: Uuid::new_v4().to_string(),
            salt: URL_SAFE_NO_PAD.encode(salt),
            code_hash: hex::encode(digest),
            created_at: now,
        });
        salt.zeroize();
    }
    (plain, rows)
}

async fn insert_recovery_codes(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    rows: &[RecoveryCodeRow],
) -> Result<(), ApiError> {
    for row in rows {
        sqlx::query(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at) VALUES(?,?,?,?,?)",
        )
        .bind(&row.code_id)
        .bind(user_id)
        .bind(&row.salt)
        .bind(&row.code_hash)
        .bind(row.created_at)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    }
    Ok(())
}

async fn consume_recovery_code(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    code: &str,
    now: i64,
) -> Result<bool, ApiError> {
    let normalized = match normalize_recovery_code(code) {
        Ok(code) => code,
        Err(()) => return Ok(false),
    };
    let rows = sqlx::query(
        "SELECT code_id,salt,code_hash FROM auth_mfa_recovery_codes WHERE user_id=? AND consumed_at IS NULL",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for row in rows {
        let code_id: String = row.try_get("code_id").map_err(ApiError::internal)?;
        let salt: String = row.try_get("salt").map_err(ApiError::internal)?;
        let stored_hash: String = row.try_get("code_hash").map_err(ApiError::internal)?;
        let Ok(salt) = decode_b64_exact(&salt, 16) else {
            return Err(ApiError::internal("stored MFA recovery salt is malformed"));
        };
        let Ok(stored_hash) = hex::decode(stored_hash) else {
            return Err(ApiError::internal("stored MFA recovery hash is malformed"));
        };
        if stored_hash.len() != 32 {
            return Err(ApiError::internal("stored MFA recovery hash is malformed"));
        }
        let valid = verify_recovery_code_digest(&salt, &normalized, &stored_hash);
        if valid {
            let consumed = sqlx::query(
                "UPDATE auth_mfa_recovery_codes SET consumed_at=? WHERE code_id=? AND user_id=? AND consumed_at IS NULL",
            )
            .bind(now)
            .bind(code_id)
            .bind(user_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
            return Ok(consumed.rows_affected() == 1);
        }
    }
    Ok(false)
}

fn recovery_code_digest(salt: &[u8], code: &str) -> Result<[u8; 32], ApiError> {
    let mut mac = <HmacSha256 as Mac>::new_from_slice(salt).map_err(ApiError::internal)?;
    mac.update(RECOVERY_CODE_DOMAIN);
    mac.update(code.as_bytes());
    Ok(mac.finalize().into_bytes().into())
}

pub(crate) fn verify_recovery_code_digest(salt: &[u8], code: &str, expected: &[u8]) -> bool {
    let Ok(mut mac) = <HmacSha256 as Mac>::new_from_slice(salt) else {
        return false;
    };
    mac.update(RECOVERY_CODE_DOMAIN);
    mac.update(code.as_bytes());
    mac.verify_slice(expected).is_ok()
}

pub(crate) fn normalize_recovery_code(code: &str) -> Result<String, ()> {
    if code.len() > 32 || !code.is_ascii() {
        return Err(());
    }
    let mut normalized = String::with_capacity(16);
    for byte in code.bytes() {
        if byte == b'-' {
            continue;
        }
        let upper = byte.to_ascii_uppercase();
        if !matches!(upper, b'A'..=b'Z' | b'2'..=b'7') {
            return Err(());
        }
        normalized.push(upper as char);
    }
    if normalized.len() != 16 {
        return Err(());
    }
    Ok(normalized)
}

pub(crate) fn validate_totp_code(code: &str) -> Result<(), ()> {
    if code.len() == 6 && code.bytes().all(|byte| byte.is_ascii_digit()) {
        Ok(())
    } else {
        Err(())
    }
}

pub(crate) fn matching_totp_step(secret: &[u8], code: &str, now: i64) -> Option<i64> {
    if validate_totp_code(code).is_err() || now < 0 {
        return None;
    }
    let current = now / TOTP_PERIOD_SECONDS;
    [
        current,
        current.saturating_sub(1),
        current.saturating_add(1),
    ]
    .into_iter()
    .find(|step| *step >= 0 && totp_code(secret, *step).as_deref() == Some(code))
}

fn totp_code(secret: &[u8], step: i64) -> Option<String> {
    let mut mac = <HmacSha1 as Mac>::new_from_slice(secret).ok()?;
    mac.update(&(step as u64).to_be_bytes());
    let digest = mac.finalize().into_bytes();
    let offset = (digest[19] & 0x0f) as usize;
    let binary = u32::from_be_bytes([
        digest[offset] & 0x7f,
        digest[offset + 1],
        digest[offset + 2],
        digest[offset + 3],
    ]);
    Some(format!("{:06}", binary % 10_u32.pow(TOTP_DIGITS)))
}

pub(crate) fn encrypt_seed(key: &[u8; 32], user_id: &str, seed: &[u8]) -> Result<String, ApiError> {
    if seed.len() != 20 {
        return Err(ApiError::internal("TOTP seed has invalid length"));
    }
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(ApiError::internal)?;
    let mut nonce = [0_u8; 24];
    rand::thread_rng().fill_bytes(&mut nonce);
    let aad = seed_aad(user_id);
    let ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: seed,
                aad: &aad,
            },
        )
        .map_err(ApiError::internal)?;
    let envelope = json!({
        "version": 1,
        "nonce": URL_SAFE_NO_PAD.encode(nonce),
        "ciphertext": URL_SAFE_NO_PAD.encode(ciphertext),
    });
    serde_json::to_string(&envelope).map_err(ApiError::internal)
}

pub(crate) fn reencrypt_seed_envelope(
    old_key: &[u8; 32],
    new_key: &[u8; 32],
    user_id: &str,
    envelope: &str,
) -> Result<String, ApiError> {
    let seed = decrypt_seed(old_key, user_id, envelope)?;
    encrypt_seed(new_key, user_id, &seed)
}

/// Re-encrypts only the active and pending seed envelope columns. The caller
/// owns an IMMEDIATE SQLite transaction so any malformed envelope, failed
/// compare-and-swap, or later commit error leaves every row unchanged.
pub(crate) async fn reencrypt_seed_envelopes(
    tx: &mut Transaction<'_, Sqlite>,
    old_key: &[u8; 32],
    new_key: &[u8; 32],
) -> Result<SeedEnvelopeRotationCounts, ApiError> {
    let rows = sqlx::query(
        "SELECT user_id,totp_seed_envelope,pending_seed_envelope FROM auth_mfa \
         WHERE totp_seed_envelope IS NOT NULL OR pending_seed_envelope IS NOT NULL \
         ORDER BY user_id",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut counts = SeedEnvelopeRotationCounts::default();

    for row in rows {
        let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let active: Option<String> = row
            .try_get("totp_seed_envelope")
            .map_err(ApiError::internal)?;
        let pending: Option<String> = row
            .try_get("pending_seed_envelope")
            .map_err(ApiError::internal)?;

        let rotated_active = active
            .as_deref()
            .map(|envelope| reencrypt_seed_envelope(old_key, new_key, &user_id, envelope))
            .transpose()?;
        let rotated_pending = pending
            .as_deref()
            .map(|envelope| reencrypt_seed_envelope(old_key, new_key, &user_id, envelope))
            .transpose()?;

        let changed = sqlx::query(
            "UPDATE auth_mfa SET totp_seed_envelope=?,pending_seed_envelope=? \
             WHERE user_id=? AND totp_seed_envelope IS ? AND pending_seed_envelope IS ?",
        )
        .bind(&rotated_active)
        .bind(&rotated_pending)
        .bind(&user_id)
        .bind(&active)
        .bind(&pending)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::internal(
                "MFA seed envelope changed during offline key rotation",
            ));
        }
        counts.active += u64::from(active.is_some());
        counts.pending += u64::from(pending.is_some());
    }

    Ok(counts)
}

pub(crate) fn decrypt_seed(
    key: &[u8; 32],
    user_id: &str,
    envelope: &str,
) -> Result<Zeroizing<Vec<u8>>, ApiError> {
    let value: Value = serde_json::from_str(envelope).map_err(ApiError::internal)?;
    let object = value
        .as_object()
        .filter(|object| object.len() == 3)
        .ok_or_else(|| ApiError::internal("stored MFA seed envelope is malformed"))?;
    if object.get("version").and_then(Value::as_i64) != Some(1) {
        return Err(ApiError::internal("stored MFA seed version is unsupported"));
    }
    let nonce_text = object
        .get("nonce")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::internal("stored MFA seed envelope is malformed"))?;
    let ciphertext_text = object
        .get("ciphertext")
        .and_then(Value::as_str)
        .ok_or_else(|| ApiError::internal("stored MFA seed envelope is malformed"))?;
    let nonce = decode_b64_exact(nonce_text, 24)
        .map_err(|_| ApiError::internal("stored MFA seed nonce is malformed"))?;
    let ciphertext = URL_SAFE_NO_PAD
        .decode(ciphertext_text)
        .map_err(ApiError::internal)?;
    if ciphertext.len() != 36 || URL_SAFE_NO_PAD.encode(&ciphertext) != ciphertext_text {
        return Err(ApiError::internal(
            "stored MFA seed ciphertext is malformed",
        ));
    }
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(ApiError::internal)?;
    let aad = seed_aad(user_id);
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &ciphertext,
                aad: &aad,
            },
        )
        .map_err(|_| ApiError::internal("stored MFA seed could not be decrypted"))?;
    if plaintext.len() != 20 {
        return Err(ApiError::internal("stored MFA seed has invalid length"));
    }
    Ok(Zeroizing::new(plaintext))
}

fn seed_aad(user_id: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(MFA_SEED_DOMAIN.len() + user_id.len());
    aad.extend_from_slice(MFA_SEED_DOMAIN);
    aad.extend_from_slice(user_id.as_bytes());
    aad
}

pub(crate) fn base32_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut output = String::with_capacity((bytes.len() * 8).div_ceil(5));
    let mut buffer = 0_u32;
    let mut bits = 0_u8;
    for byte in bytes {
        buffer = (buffer << 8) | u32::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            output.push(ALPHABET[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        output.push(ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    output
}

#[cfg(test)]
fn base32_decode(text: &str) -> Result<Vec<u8>, ()> {
    if text.is_empty() || !text.is_ascii() || text.len() > 64 {
        return Err(());
    }
    let mut output = Vec::with_capacity(text.len() * 5 / 8);
    let mut buffer = 0_u32;
    let mut bits = 0_u8;
    for byte in text.bytes() {
        let upper = byte.to_ascii_uppercase();
        let value = match upper {
            b'A'..=b'Z' => upper - b'A',
            b'2'..=b'7' => upper - b'2' + 26,
            _ => return Err(()),
        };
        buffer = (buffer << 5) | u32::from(value);
        bits += 5;
        if bits >= 8 {
            bits -= 8;
            output.push((buffer >> bits) as u8);
        }
    }
    if bits > 0 && buffer & ((1_u32 << bits) - 1) != 0 {
        return Err(());
    }
    if base32_encode(&output).as_bytes() != text.to_ascii_uppercase().as_bytes() {
        return Err(());
    }
    Ok(output)
}

pub(crate) fn percent_encode_component(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push_str(&format!("{byte:02X}"));
        }
    }
    encoded
}

fn decode_b64_exact(value: &str, length: usize) -> Result<Vec<u8>, ()> {
    let bytes = URL_SAFE_NO_PAD.decode(value).map_err(|_| ())?;
    if bytes.len() != length || URL_SAFE_NO_PAD.encode(&bytes) != value {
        return Err(());
    }
    Ok(bytes)
}

pub(crate) fn timestamp_rfc3339(timestamp: i64) -> Result<String, ApiError> {
    DateTime::from_timestamp(timestamp, 0)
        .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true))
        .ok_or_else(|| ApiError::internal("MFA timestamp is outside the supported range"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn totp_matches_rfc_6238_sha1_six_digit_vector() {
        let seed = b"12345678901234567890";
        assert_eq!(totp_code(seed, 1).as_deref(), Some("287082"));
        assert_eq!(matching_totp_step(seed, "287082", 59), Some(1));
        assert_eq!(matching_totp_step(seed, "287082", 60), Some(1));
        assert_eq!(matching_totp_step(seed, "287082", 120), None);
    }

    #[test]
    fn base32_roundtrips_seed_and_code_lengths() {
        let seed = [0x5a; 20];
        let encoded = base32_encode(&seed);
        assert_eq!(encoded.len(), 32);
        assert_eq!(base32_decode(&encoded).unwrap(), seed);
        assert_eq!(base32_encode(&[0xff; 10]).len(), 16);
        assert!(base32_decode("MZXW6YTB====").is_err());
    }

    #[test]
    fn seed_envelope_is_authenticated_to_account_context() {
        let key = [0x42; 32];
        let seed = [0x21; 20];
        let envelope = encrypt_seed(&key, "account-a", &seed).unwrap();
        assert_eq!(&*decrypt_seed(&key, "account-a", &envelope).unwrap(), &seed);
        assert!(decrypt_seed(&key, "account-b", &envelope).is_err());
        let mut value: Value = serde_json::from_str(&envelope).unwrap();
        value["ciphertext"] = json!(URL_SAFE_NO_PAD.encode([0_u8; 36]));
        assert!(decrypt_seed(&key, "account-a", &value.to_string()).is_err());
    }

    #[test]
    fn recovery_codes_normalize_and_hash_with_salt() {
        let code = "ABCD-EFGH-JKLM-NPQR";
        let normalized = normalize_recovery_code(code).unwrap();
        assert_eq!(normalized, "ABCDEFGHJKLMNPQR");
        assert_eq!(
            normalize_recovery_code(&code.to_lowercase()).unwrap(),
            normalized
        );
        assert!(normalize_recovery_code("ABCD-EFGH-JKLM-AAAA").is_ok());
        assert!(normalize_recovery_code("ABCD-EFGH-JKLM-NPQS").is_ok());
        assert!(normalize_recovery_code("ABCD EFGH JKLM NPQR").is_err());
        let salt = [7_u8; 16];
        let digest = recovery_code_digest(&salt, &normalized).unwrap();
        assert!(verify_recovery_code_digest(&salt, &normalized, &digest));
        assert!(verify_recovery_code_digest(
            &salt,
            &normalize_recovery_code(&code.to_lowercase()).unwrap(),
            &digest
        ));
        assert!(!verify_recovery_code_digest(
            &salt,
            "AAAAAAAAAAAAAAAA",
            &digest
        ));
    }

    #[test]
    fn provisioning_label_is_percent_encoded() {
        assert_eq!(
            percent_encode_component("person+dev@example.test"),
            "person%2Bdev%40example.test"
        );
    }
}

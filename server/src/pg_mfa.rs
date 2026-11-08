//! PostgreSQL-backed TOTP MFA lifecycle for the restricted shared runtime.
//!
//! Seed envelopes and recovery-code digests use the same format as SQLite.
//! Every authenticated write is fenced with the account lifecycle advisory
//! lock before the shared session/account/credential/device row order.

use std::net::SocketAddr;

use axum::http::StatusCode;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use rand::RngCore;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{ApiError, AppState, auth, mfa};

const MAX_CHALLENGE_PRUNE_BATCH: i64 = 500;

#[derive(Clone)]
pub(crate) struct PgMfaRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
}

impl PgMfaRepository {
    pub(crate) fn new(pool: PgPool, audit_scope_key: [u8; 32]) -> Self {
        Self {
            pool,
            audit_scope_key,
        }
    }

    pub(crate) async fn status(&self, user: &auth::AuthUser) -> Result<mfa::MfaStatus, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        crate::pg_auth_lifecycle::lock_active_principal_tx(&mut tx, user).await?;
        let enabled: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM auth_mfa WHERE user_id=$1 \
             AND enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL)",
        )
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let remaining = if enabled {
            sqlx::query_scalar(
                "SELECT COUNT(*) FROM auth_mfa_recovery_codes \
                 WHERE user_id=$1 AND consumed_at IS NULL",
            )
            .bind(&user.user_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?
        } else {
            0
        };
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(mfa::MfaStatus {
            enabled,
            recovery_codes_remaining: remaining,
        })
    }

    pub(crate) async fn setup_totp(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        verifier: &str,
    ) -> Result<mfa::SetupResponse, ApiError> {
        let key = mfa::encryption_key(state)?;
        let (verifier_hash, credential_version, username) =
            self.verify_step_up(state, user, peer, verifier).await?;
        let mut seed = Zeroizing::new(vec![0_u8; 20]);
        rand::thread_rng().fill_bytes(&mut seed);
        let secret = mfa::base32_encode(&seed);
        let envelope = mfa::encrypt_seed(key, &user.user_id, &seed)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let (current_hash, current_version) =
            crate::pg_auth_lifecycle::lock_active_principal_tx(&mut tx, user).await?;
        ensure_credential_snapshot(
            &current_hash,
            current_version,
            &verifier_hash,
            credential_version,
        )?;
        let now = database_now(&mut tx).await?;
        let expires_at = now.saturating_add(mfa::TOTP_SETUP_TTL_SECONDS);
        let changed = sqlx::query(
            "INSERT INTO auth_mfa( \
                 user_id,pending_seed_envelope,pending_expires_at,pending_credential_version \
             ) VALUES($1,$2,$3,$4) \
             ON CONFLICT(user_id) DO UPDATE SET \
                 pending_seed_envelope=EXCLUDED.pending_seed_envelope, \
                 pending_expires_at=EXCLUDED.pending_expires_at, \
                 pending_credential_version=EXCLUDED.pending_credential_version \
             WHERE auth_mfa.enabled_at IS NULL AND auth_mfa.totp_seed_envelope IS NULL",
        )
        .bind(&user.user_id)
        .bind(envelope)
        .bind(expires_at)
        .bind(current_version)
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
            mfa::percent_encode_component(issuer),
            mfa::percent_encode_component(&username)
        );
        let provisioning_uri = format!(
            "otpauth://totp/{label}?secret={secret}&issuer={}&algorithm=SHA1&digits=6&period=30",
            mfa::percent_encode_component(issuer),
        );
        Ok(mfa::SetupResponse {
            secret,
            provisioning_uri,
            expires_at: mfa::timestamp_rfc3339(expires_at)?,
        })
    }

    pub(crate) async fn confirm_totp(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        verifier: &str,
        totp_code: &str,
    ) -> Result<mfa::RecoveryCodesResponse, ApiError> {
        mfa::validate_totp_code(totp_code).map_err(|_| ApiError::reauth_required())?;
        let key = mfa::encryption_key(state)?;
        let (verifier_hash, credential_version, _) =
            self.verify_step_up(state, user, peer, verifier).await?;
        let (codes, mut rows) = mfa::generate_recovery_codes();

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let (current_hash, current_version) =
            crate::pg_auth_lifecycle::lock_active_principal_tx(&mut tx, user).await?;
        ensure_credential_snapshot(
            &current_hash,
            current_version,
            &verifier_hash,
            credential_version,
        )?;
        let now = database_now(&mut tx).await?;
        let pending = sqlx::query(
            "SELECT pending_seed_envelope,pending_expires_at,pending_credential_version \
             FROM auth_mfa WHERE user_id=$1 AND enabled_at IS NULL \
               AND totp_seed_envelope IS NULL FOR UPDATE",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(pending) = pending else {
            return Err(ApiError::conflict(
                "MFA_SETUP_REQUIRED",
                "start a new TOTP setup before confirming",
            ));
        };
        let envelope: Option<String> = pending
            .try_get("pending_seed_envelope")
            .map_err(ApiError::internal)?;
        let expires_at: Option<i64> = pending
            .try_get("pending_expires_at")
            .map_err(ApiError::internal)?;
        let pending_version: Option<i64> = pending
            .try_get("pending_credential_version")
            .map_err(ApiError::internal)?;
        let (Some(envelope), Some(expires_at), Some(pending_version)) =
            (envelope, expires_at, pending_version)
        else {
            return Err(ApiError::internal("stored MFA setup is incomplete"));
        };
        if expires_at <= now || pending_version != current_version {
            sqlx::query("DELETE FROM auth_mfa WHERE user_id=$1 AND enabled_at IS NULL")
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
        let seed = mfa::decrypt_seed(key, &user.user_id, &envelope)?;
        let Some(step) = mfa::matching_totp_step(&seed, totp_code, now) else {
            return Err(ApiError::reauth_required());
        };
        let changed = sqlx::query(
            "UPDATE auth_mfa SET totp_seed_envelope=pending_seed_envelope, \
                 enabled_at=$1,last_totp_step=$2,pending_seed_envelope=NULL, \
                 pending_expires_at=NULL,pending_credential_version=NULL \
             WHERE user_id=$3 AND enabled_at IS NULL AND pending_seed_envelope=$4 \
               AND pending_expires_at>$1 AND pending_credential_version=$5",
        )
        .bind(now)
        .bind(step)
        .bind(&user.user_id)
        .bind(&envelope)
        .bind(current_version)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "MFA_SETUP_CHANGED",
                "TOTP setup changed; start again",
            ));
        }
        for row in &mut rows {
            row.created_at = now;
        }
        insert_recovery_codes(&mut tx, &user.user_id, &rows).await?;
        record_account_event_tx(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            "auth.mfa_totp_enabled",
            "account",
            Some(&user.user_id),
            "success",
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(mfa::RecoveryCodesResponse {
            recovery_codes: codes,
        })
    }

    pub(crate) async fn rotate_recovery_codes(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        verifier: &str,
        totp_code: &str,
    ) -> Result<mfa::RecoveryCodesResponse, ApiError> {
        mfa::validate_totp_code(totp_code).map_err(|_| ApiError::reauth_required())?;
        let key = mfa::encryption_key(state)?;
        let (verifier_hash, credential_version, _) =
            self.verify_step_up(state, user, peer, verifier).await?;
        let (codes, mut rows) = mfa::generate_recovery_codes();

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let (current_hash, current_version) =
            crate::pg_auth_lifecycle::lock_active_principal_tx(&mut tx, user).await?;
        ensure_credential_snapshot(
            &current_hash,
            current_version,
            &verifier_hash,
            credential_version,
        )?;
        let now = database_now(&mut tx).await?;
        let stored = sqlx::query(
            "SELECT totp_seed_envelope,last_totp_step FROM auth_mfa \
             WHERE user_id=$1 AND enabled_at IS NOT NULL FOR UPDATE",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(stored) = stored else {
            return Err(ApiError::conflict("MFA_NOT_ENABLED", "TOTP is not enabled"));
        };
        let envelope: String = stored
            .try_get("totp_seed_envelope")
            .map_err(ApiError::internal)?;
        let last_step: i64 = stored
            .try_get("last_totp_step")
            .map_err(ApiError::internal)?;
        let seed = mfa::decrypt_seed(key, &user.user_id, &envelope)?;
        let Some(step) = mfa::matching_totp_step(&seed, totp_code, now) else {
            return Err(ApiError::reauth_required());
        };
        if !advance_totp_step(&mut tx, &user.user_id, last_step, step).await? {
            return Err(ApiError::reauth_required());
        }
        sqlx::query("DELETE FROM auth_mfa_recovery_codes WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        for row in &mut rows {
            row.created_at = now;
        }
        insert_recovery_codes(&mut tx, &user.user_id, &rows).await?;
        record_account_event_tx(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            "auth.mfa_recovery_codes_rotated",
            "account",
            Some(&user.user_id),
            "success",
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(mfa::RecoveryCodesResponse {
            recovery_codes: codes,
        })
    }

    pub(crate) async fn disable_totp(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        verifier: &str,
        totp_code: &str,
    ) -> Result<mfa::MfaStatus, ApiError> {
        mfa::validate_totp_code(totp_code).map_err(|_| ApiError::reauth_required())?;
        let key = mfa::encryption_key(state)?;
        let (verifier_hash, credential_version, _) =
            self.verify_step_up(state, user, peer, verifier).await?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let (current_hash, current_version) =
            crate::pg_auth_lifecycle::lock_active_principal_tx(&mut tx, user).await?;
        ensure_credential_snapshot(
            &current_hash,
            current_version,
            &verifier_hash,
            credential_version,
        )?;
        let now = database_now(&mut tx).await?;
        let stored = sqlx::query(
            "SELECT totp_seed_envelope,last_totp_step FROM auth_mfa \
             WHERE user_id=$1 AND enabled_at IS NOT NULL FOR UPDATE",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(stored) = stored else {
            return Err(ApiError::conflict("MFA_NOT_ENABLED", "TOTP is not enabled"));
        };
        let envelope: String = stored
            .try_get("totp_seed_envelope")
            .map_err(ApiError::internal)?;
        let last_step: i64 = stored
            .try_get("last_totp_step")
            .map_err(ApiError::internal)?;
        let seed = mfa::decrypt_seed(key, &user.user_id, &envelope)?;
        let Some(step) = mfa::matching_totp_step(&seed, totp_code, now) else {
            return Err(ApiError::reauth_required());
        };
        if !advance_totp_step(&mut tx, &user.user_id, last_step, step).await? {
            return Err(ApiError::reauth_required());
        }
        // The challenge FK cascades here. A challenge from this seed cannot
        // survive a disable→reenroll cycle for the same account.
        sqlx::query("DELETE FROM auth_mfa WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        // Delete the MFA/challenge rows before requesting the audit table
        // lock. A concurrent login may already be writing its challenge audit.
        record_account_event_tx(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            "auth.mfa_totp_disabled",
            "account",
            Some(&user.user_id),
            "success",
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(mfa::MfaStatus {
            enabled: false,
            recovery_codes_remaining: 0,
        })
    }

    pub(crate) async fn complete_login(
        &self,
        state: &AppState,
        peer: SocketAddr,
        challenge_id: &str,
        totp_code: Option<&str>,
        recovery_code: Option<&str>,
    ) -> Result<crate::pg_auth_lifecycle::PgLoginResponse, ApiError> {
        let challenge_hash = crate::sha256_hex(challenge_id.as_bytes());
        // This unlocked lookup is only a hint for the account advisory fence.
        // Every property is re-read under lock below.
        let user_hint = sqlx::query(
            "SELECT c.user_id,u.username FROM auth_mfa_login_challenges c \
             JOIN users u ON u.user_id=c.user_id WHERE c.challenge_id_hash=$1",
        )
        .bind(&challenge_hash)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let Some(user_hint) = user_hint else {
            // Unknown, expired-and-pruned, or concurrently deleted challenge
            // identifiers still consume a stable per-peer budget. This keeps
            // random challenge spraying bounded without charging a shared
            // global pseudo-account bucket or revealing whether a row exists.
            // Normalized account usernames always contain `@`, so this
            // internal sentinel cannot collide with an actual account while
            // remaining safe to HMAC through the shared PG limiter.
            let anonymous_bucket = format!("__unknown_mfa_challenge__:{}", peer.ip());
            if let Some(retry_after) = auth::consume_auth_rate_limit(
                state,
                crate::rate_limit::AuthOperation::MfaLogin,
                &anonymous_bucket,
                Some(peer.ip()),
            )
            .await?
            {
                return Err(ApiError::rate_limited(retry_after));
            }
            return Err(ApiError::unauthorized());
        };
        let user_id: String = user_hint.try_get("user_id").map_err(ApiError::internal)?;
        let username: String = user_hint.try_get("username").map_err(ApiError::internal)?;
        let username = auth::normalized_username(&username)?;
        // Charge the shared MFA login limiter in its own committed transaction
        // before taking the lifecycle/session row locks. This avoids holding
        // every main-pool connection while a second limiter transaction waits.
        if let Some(retry_after) = auth::consume_auth_rate_limit(
            state,
            crate::rate_limit::AuthOperation::MfaLogin,
            &username,
            Some(peer.ip()),
        )
        .await?
        {
            return Err(ApiError::rate_limited(retry_after));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user_id).await?;
        let challenge = sqlx::query(
            "SELECT user_id,device_id,credential_version,expires_at,attempt_count,consumed_at \
             FROM auth_mfa_login_challenges WHERE challenge_id_hash=$1 FOR UPDATE",
        )
        .bind(&challenge_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(challenge) = challenge else {
            return Err(ApiError::unauthorized());
        };
        let challenge_user: String = challenge.try_get("user_id").map_err(ApiError::internal)?;
        let device_id: String = challenge.try_get("device_id").map_err(ApiError::internal)?;
        let challenge_version: i64 = challenge
            .try_get("credential_version")
            .map_err(ApiError::internal)?;
        let expires_at: i64 = challenge
            .try_get("expires_at")
            .map_err(ApiError::internal)?;
        let attempts: i64 = challenge
            .try_get("attempt_count")
            .map_err(ApiError::internal)?;
        let consumed_at: Option<i64> = challenge
            .try_get("consumed_at")
            .map_err(ApiError::internal)?;
        if challenge_user != user_id
            || consumed_at.is_some()
            || attempts >= mfa::MAX_LOGIN_CHALLENGE_ATTEMPTS
        {
            return Err(ApiError::unauthorized());
        }
        let now = database_now(&mut tx).await?;
        if expires_at <= now {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        }

        let account = sqlx::query("SELECT status,username FROM users WHERE user_id=$1 FOR SHARE")
            .bind(&user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let Some(account) = account else {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        };
        let account_status: String = account.try_get("status").map_err(ApiError::internal)?;
        let current_username: String = account.try_get("username").map_err(ApiError::internal)?;
        if auth::normalized_username(&current_username)? != username {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        }
        let credential = sqlx::query(
            "SELECT credential_version FROM auth_credentials WHERE user_id=$1 FOR SHARE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(credential) = credential else {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        };
        let current_version: i64 = credential
            .try_get("credential_version")
            .map_err(ApiError::internal)?;
        let device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(&device_id)
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mfa_state = sqlx::query(
            "SELECT totp_seed_envelope,enabled_at,last_totp_step FROM auth_mfa \
             WHERE user_id=$1 FOR UPDATE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(mfa_state) = mfa_state else {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        };
        let enabled_at: Option<i64> = mfa_state
            .try_get("enabled_at")
            .map_err(ApiError::internal)?;
        if account_status != "active"
            || current_version != challenge_version
            || device_status.as_deref() != Some("active")
            || enabled_at.is_none()
        {
            consume_stale_challenge(&mut tx, &challenge_hash, now).await?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        }

        let factor_valid = if let Some(code) = totp_code {
            let key = mfa::encryption_key(state)?;
            let envelope: String = mfa_state
                .try_get::<Option<String>, _>("totp_seed_envelope")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("stored MFA seed is missing"))?;
            let previous_step: i64 = mfa_state
                .try_get::<Option<i64>, _>("last_totp_step")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("stored MFA TOTP step is missing"))?;
            let seed = mfa::decrypt_seed(key, &user_id, &envelope)?;
            if let Some(next_step) = mfa::matching_totp_step(&seed, code, now) {
                advance_totp_step(&mut tx, &user_id, previous_step, next_step).await?
            } else {
                false
            }
        } else if let Some(code) = recovery_code {
            consume_recovery_code(&mut tx, &user_id, code, now).await?
        } else {
            false
        };
        if !factor_valid {
            let failed = sqlx::query(
                "UPDATE auth_mfa_login_challenges SET attempt_count=attempt_count+1, \
                     consumed_at=CASE WHEN attempt_count+1 >= $1 THEN $2 ELSE consumed_at END \
                 WHERE challenge_id_hash=$3 AND consumed_at IS NULL \
                   AND expires_at>$2 AND attempt_count<$1",
            )
            .bind(mfa::MAX_LOGIN_CHALLENGE_ATTEMPTS)
            .bind(now)
            .bind(&challenge_hash)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if failed.rows_affected() != 1 {
                return Err(ApiError::unauthorized());
            }
            // Commit the failure counter before the best-effort audit. Audit
            // storage failure must not roll back either this counter or the
            // independently committed shared MFA rate-limit bucket.
            tx.commit().await.map_err(ApiError::internal)?;
            self.record_failed_login_best_effort(&user_id).await;
            return Err(ApiError::unauthorized());
        }

        let consumed = sqlx::query(
            "UPDATE auth_mfa_login_challenges SET consumed_at=$1 \
             WHERE challenge_id_hash=$2 AND consumed_at IS NULL \
               AND expires_at>$1 AND credential_version=$3 AND attempt_count<$4",
        )
        .bind(now)
        .bind(&challenge_hash)
        .bind(challenge_version)
        .bind(mfa::MAX_LOGIN_CHALLENGE_ATTEMPTS)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if consumed.rows_affected() != 1 {
            return Err(ApiError::unauthorized());
        }
        let login = state
            .pg_auth_lifecycle
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL auth lifecycle is unavailable"))?
            .create_login_session_tx(&mut tx, &user_id, &device_id, now)
            .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(login)
    }

    async fn verify_step_up(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        verifier: &str,
    ) -> Result<(String, i64, String), ApiError> {
        let credential = sqlx::query(
            "SELECT u.username,c.login_verifier_hash,c.credential_version \
             FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
             WHERE u.user_id=$1 AND u.status='active'",
        )
        .bind(&user.user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::reauth_required)?;
        let username: String = credential.try_get("username").map_err(ApiError::internal)?;
        let username = auth::normalized_username(&username)?;
        if let Some(retry_after) = auth::consume_auth_rate_limit(
            state,
            crate::rate_limit::AuthOperation::Login,
            &username,
            Some(peer.ip()),
        )
        .await?
        {
            return Err(ApiError::rate_limited(retry_after));
        }
        let verifier_hash: String = credential
            .try_get("login_verifier_hash")
            .map_err(ApiError::internal)?;
        auth::check_password_hash(verifier, &verifier_hash).map_err(|error| {
            if error.status == StatusCode::UNAUTHORIZED {
                ApiError::reauth_required()
            } else {
                error
            }
        })?;
        let credential_version: i64 = credential
            .try_get("credential_version")
            .map_err(ApiError::internal)?;
        Ok((verifier_hash, credential_version, username))
    }

    async fn record_failed_login_best_effort(&self, user_id: &str) {
        let result = async {
            let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
            let now = database_now(&mut tx).await?;
            record_account_event_tx(
                &mut tx,
                &self.audit_scope_key,
                user_id,
                None,
                "auth.login_failed",
                "account",
                None,
                "failure",
                now,
            )
            .await?;
            tx.commit().await.map_err(ApiError::internal)
        }
        .await;
        if result.is_err() {
            tracing::warn!(
                event = "auth_mfa_login_failure_audit_write_failed",
                "MFA login failure audit could not be persisted"
            );
        }
    }
}

/// Creates a credential-version-bound challenge after password login has
/// already rechecked the account, credential, device, and MFA rows under the
/// lifecycle fence. Only the SHA-256 challenge digest is stored. Expired and
/// consumed challenges are pruned opportunistically here in batches of at
/// most 500; there is no periodic MFA challenge-retention worker.
pub(crate) async fn create_login_challenge_tx(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    device_id: &str,
    credential_version: i64,
) -> Result<(String, String, i64), ApiError> {
    let now = database_now(tx).await?;
    sqlx::query(
        "WITH candidates AS ( \
            SELECT challenge_id_hash FROM auth_mfa_login_challenges \
            WHERE expires_at<=$1 OR consumed_at IS NOT NULL \
            ORDER BY expires_at,challenge_id_hash LIMIT $2 FOR UPDATE SKIP LOCKED \
         ) DELETE FROM auth_mfa_login_challenges c USING candidates x \
           WHERE c.challenge_id_hash=x.challenge_id_hash",
    )
    .bind(now)
    .bind(MAX_CHALLENGE_PRUNE_BATCH)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let outstanding: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_mfa_login_challenges \
         WHERE user_id=$1 AND consumed_at IS NULL AND expires_at>$2",
    )
    .bind(user_id)
    .bind(now)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if outstanding >= mfa::MAX_OUTSTANDING_LOGIN_CHALLENGES {
        return Err(ApiError::rate_limited(60));
    }
    let challenge_id = Uuid::new_v4().to_string();
    let challenge_hash = crate::sha256_hex(challenge_id.as_bytes());
    let expires_at = now.saturating_add(mfa::LOGIN_CHALLENGE_TTL_SECONDS);
    sqlx::query(
        "INSERT INTO auth_mfa_login_challenges( \
             challenge_id_hash,user_id,device_id,credential_version,expires_at \
         ) VALUES($1,$2,$3,$4,$5)",
    )
    .bind(&challenge_hash)
    .bind(user_id)
    .bind(device_id)
    .bind(credential_version)
    .bind(expires_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok((
        challenge_id,
        mfa::timestamp_rfc3339(expires_at)?,
        expires_at,
    ))
}

async fn database_now(tx: &mut Transaction<'_, Postgres>) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)
}

fn ensure_credential_snapshot(
    current_hash: &str,
    current_version: i64,
    expected_hash: &str,
    expected_version: i64,
) -> Result<(), ApiError> {
    if current_hash == expected_hash && current_version == expected_version {
        Ok(())
    } else {
        Err(ApiError::reauth_required())
    }
}

async fn advance_totp_step(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    previous_step: i64,
    next_step: i64,
) -> Result<bool, ApiError> {
    if next_step <= previous_step {
        return Ok(false);
    }
    let updated = sqlx::query(
        "UPDATE auth_mfa SET last_totp_step=$1 \
         WHERE user_id=$2 AND enabled_at IS NOT NULL \
           AND last_totp_step=$3 AND last_totp_step<$1",
    )
    .bind(next_step)
    .bind(user_id)
    .bind(previous_step)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(updated.rows_affected() == 1)
}

async fn insert_recovery_codes(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    rows: &[mfa::RecoveryCodeRow],
) -> Result<(), ApiError> {
    for row in rows {
        sqlx::query(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at) \
             VALUES($1,$2,$3,$4,$5)",
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
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    code: &str,
    now: i64,
) -> Result<bool, ApiError> {
    let normalized = match mfa::normalize_recovery_code(code) {
        Ok(code) => code,
        Err(()) => return Ok(false),
    };
    let rows = sqlx::query(
        "SELECT code_id,salt,code_hash FROM auth_mfa_recovery_codes \
         WHERE user_id=$1 AND consumed_at IS NULL ORDER BY code_id FOR UPDATE",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for row in rows {
        let code_id: String = row.try_get("code_id").map_err(ApiError::internal)?;
        let salt_text: String = row.try_get("salt").map_err(ApiError::internal)?;
        let hash_text: String = row.try_get("code_hash").map_err(ApiError::internal)?;
        let salt = URL_SAFE_NO_PAD
            .decode(&salt_text)
            .map_err(|_| ApiError::internal("stored MFA recovery salt is malformed"))?;
        if salt.len() != 16 || URL_SAFE_NO_PAD.encode(&salt) != salt_text {
            return Err(ApiError::internal("stored MFA recovery salt is malformed"));
        }
        let expected = hex::decode(&hash_text)
            .map_err(|_| ApiError::internal("stored MFA recovery hash is malformed"))?;
        if expected.len() != 32 || hex::encode(&expected) != hash_text {
            return Err(ApiError::internal("stored MFA recovery hash is malformed"));
        }
        if mfa::verify_recovery_code_digest(&salt, &normalized, &expected) {
            let consumed = sqlx::query(
                "UPDATE auth_mfa_recovery_codes SET consumed_at=$1 \
                 WHERE code_id=$2 AND user_id=$3 AND consumed_at IS NULL",
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

async fn consume_stale_challenge(
    tx: &mut Transaction<'_, Postgres>,
    challenge_hash: &str,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "UPDATE auth_mfa_login_challenges SET consumed_at=$1 \
         WHERE challenge_id_hash=$2 AND consumed_at IS NULL",
    )
    .bind(now)
    .bind(challenge_hash)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn record_account_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    audit_scope_key: &[u8; 32],
    user_id: &str,
    device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    result: &str,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::account_scope_id(audit_scope_key, user_id)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source \
         ) VALUES('account',$1,$2,$3,$4,$5,$6,$7,$8,'api')",
    )
    .bind(scope_id)
    .bind(if result == "failure" {
        None
    } else {
        Some(user_id)
    })
    .bind(device_id)
    .bind(action)
    .bind(resource_type)
    .bind(resource_id)
    .bind(result)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

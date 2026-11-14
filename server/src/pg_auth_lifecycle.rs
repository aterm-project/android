//! PostgreSQL authentication lifecycle operations for provisioned accounts.
//!
//! The adapter supports prelogin lookup, password/MFA challenge login,
//! refresh-token rotation, and session-preserving password change.

use std::collections::BTreeSet;
use std::net::SocketAddr;

use axum::http::StatusCode;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{Duration, Utc};
use hmac::{Hmac, Mac};
use serde::Serialize;
use serde_json::Value;
use sha2::Sha256;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, AppState, auth, pg_notifications::notify_sync_wake, sha256_hex};

const ACCESS_TTL_SECONDS: i64 = 600;
const REFRESH_TTL_DAYS: i64 = 30;
type HmacSha256 = Hmac<Sha256>;

const ACCOUNT_LIFECYCLE_LOCK_NAMESPACE: i32 = 0x4154_4552;

/// Serializes issuance of new sessions and refresh rotation with lifecycle
/// operations that revoke every session for the account. Hash collisions only
/// cause unrelated accounts to serialize; they cannot weaken authorization.
pub(crate) async fn lock_account_lifecycle(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<(), ApiError> {
    sqlx::query("SELECT pg_advisory_xact_lock($1, hashtext($2))")
        .bind(ACCOUNT_LIFECYCLE_LOCK_NAMESPACE)
        .bind(user_id)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

/// Builds the same deterministic unknown-account prelogin values as SQLite.
/// The caller must pass the normalized username and the shared auth-rate key.
pub(crate) fn prelogin_decoy(key: &[u8; 32], username: &str) -> Result<(String, String), ApiError> {
    let mut account_mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    account_mac.update(b"atermius/prelogin-decoy/v1\0account-id\0");
    account_mac.update(username.as_bytes());
    let account_bytes = account_mac.finalize().into_bytes();
    let mut account_id_bytes = [0_u8; 16];
    account_id_bytes.copy_from_slice(&account_bytes[..16]);
    account_id_bytes[6] = (account_id_bytes[6] & 0x0f) | 0x40;
    account_id_bytes[8] = (account_id_bytes[8] & 0x3f) | 0x80;

    let mut salt_mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    salt_mac.update(b"atermius/prelogin-decoy/v1\0kdf-salt\0");
    salt_mac.update(username.as_bytes());
    let salt_bytes = salt_mac.finalize().into_bytes();
    Ok((
        Uuid::from_bytes(account_id_bytes).to_string(),
        URL_SAFE_NO_PAD.encode(&salt_bytes[..16]),
    ))
}

#[derive(Clone)]
pub(crate) struct PgAuthLifecycleRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
}

#[derive(Debug, Serialize)]
pub(crate) struct PgAuthTokens {
    pub(crate) account_id: String,
    pub(crate) device_id: String,
    pub(crate) access_token: String,
    pub(crate) expires_in: i64,
    pub(crate) refresh_token: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct PgLoginVaultDescriptor {
    pub(crate) vault_id: String,
    pub(crate) role: String,
    pub(crate) active_key_epoch: i64,
    pub(crate) membership_version: i64,
    pub(crate) name_envelope: Option<Value>,
}

#[derive(Debug, Serialize)]
pub(crate) struct PgLoginResponse {
    pub(crate) account_id: String,
    pub(crate) access_token: String,
    pub(crate) expires_in: i64,
    pub(crate) refresh_token: String,
    pub(crate) device_id: String,
    pub(crate) vaults: Vec<PgLoginVaultDescriptor>,
}

#[derive(Debug)]
pub(crate) enum PgPasswordLoginOutcome {
    Session(PgLoginResponse),
    MfaChallenge {
        challenge_id: String,
        expires_at: String,
    },
}

impl PgAuthLifecycleRepository {
    pub(crate) fn new(pool: PgPool, audit_scope_key: [u8; 32]) -> Self {
        Self {
            pool,
            audit_scope_key,
        }
    }

    /// Changes the account verifier and encrypted account-key envelope while
    /// retaining the authenticated session. The account lifecycle fence is
    /// shared with login, refresh, Recovery completion, account deletion,
    /// and device revocation so a session cannot be issued or revoked between
    /// the final credential check and global session revocation.
    pub(crate) async fn change_password(
        &self,
        state: &AppState,
        user: &auth::AuthUser,
        peer: SocketAddr,
        request: auth::PasswordChangeRequest,
    ) -> Result<serde_json::Value, ApiError> {
        let username: Option<String> =
            sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1 AND status='active'")
                .bind(&user.user_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(ApiError::internal)?;
        let username = username.ok_or_else(ApiError::unauthorized)?;
        let username = auth::normalized_username(&username)?;
        if let Some(seconds) = auth::consume_auth_rate_limit(
            state,
            crate::rate_limit::AuthOperation::Login,
            &username,
            Some(peer.ip()),
        )
        .await?
        {
            return Err(ApiError::rate_limited(seconds));
        }

        auth::validate_password_change_operation_id(&request.operation_id)?;
        let request_digest = auth::password_change_request_digest(
            state.auth_rate_key.as_ref(),
            &user.user_id,
            &user.session_id,
            &request,
        )?;

        // A committed response-loss retry is resolved before the old verifier
        // is checked, because the successful first attempt replaced it.
        let mut retry_tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_account_lifecycle(&mut retry_tx, &user.user_id).await?;
        lock_active_principal_tx(&mut retry_tx, user).await?;
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

        let verifier_snapshot = match self
            .verify_password_change_verifier(user, &request.current_login_verifier)
            .await
        {
            Ok(snapshot) => snapshot,
            Err(error) => {
                if error.body.code == "REAUTH_REQUIRED" {
                    self.record_password_change_failure_best_effort(user).await;
                }
                return Err(error);
            }
        };
        auth::validate_kdf(&request.new_kdf)?;
        let account_key_envelope =
            auth::ensure_rewrapped_account_envelope(&request.account_key_envelope)?;
        let (new_verifier_hash, new_verifier_salt) =
            auth::password_hash(&request.new_login_verifier)?;
        let new_kdf_json = serde_json::to_string(&serde_json::json!({
            "id": request.new_kdf.id,
            "salt": request.new_kdf.salt,
            "mem_kib": request.new_kdf.mem_kib,
            "iterations": request.new_kdf.iterations,
            "parallelism": request.new_kdf.parallelism,
            "version": request.new_kdf.version,
        }))
        .map_err(ApiError::internal)?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_account_lifecycle(&mut tx, &user.user_id).await?;
        let (current_verifier_hash, credential_version) =
            lock_active_principal_tx(&mut tx, user).await?;
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
        if current_verifier_hash != verifier_snapshot {
            return Err(ApiError::reauth_required());
        }

        let new_version = credential_version
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("credential version overflow"))?;
        let updated = sqlx::query(
            "UPDATE auth_credentials SET login_verifier_hash=$1,verifier_salt=$2, \
                 kdf_json=$3,account_key_envelope=$4,credential_version=$5 \
             WHERE user_id=$6 AND credential_version=$7",
        )
        .bind(&new_verifier_hash)
        .bind(&new_verifier_salt)
        .bind(&new_kdf_json)
        .bind(&account_key_envelope)
        .bind(new_version)
        .bind(&user.user_id)
        .bind(credential_version)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::reauth_required());
        }

        // Credential-version checks make old MFA challenges unusable, but
        // leaving them outstanding would still consume the per-account
        // challenge cap after a password change. The shared lifecycle fence
        // ensures no login can create a challenge concurrently with cleanup.
        sqlx::query("DELETE FROM auth_mfa_login_challenges WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        let revoked_sessions = sqlx::query(
            "UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP \
             WHERE user_id=$1 AND session_id<>$2 AND revoked_at IS NULL",
        )
        .bind(&user.user_id)
        .bind(&user.session_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();
        let now = Utc::now().timestamp();
        sqlx::query(
            "INSERT INTO password_change_receipts( \
                 session_id,operation_id,request_digest,credential_version,created_at \
             ) VALUES($1,$2,$3,$4,$5) \
             ON CONFLICT(session_id) DO UPDATE SET \
                 operation_id=EXCLUDED.operation_id,request_digest=EXCLUDED.request_digest, \
                 credential_version=EXCLUDED.credential_version,created_at=EXCLUDED.created_at",
        )
        .bind(&user.session_id)
        .bind(&request.operation_id)
        .bind(&request_digest)
        .bind(new_version)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        self.record_password_change_event(&mut tx, user, "success", now)
            .await?;
        if revoked_sessions > 0 {
            // Keep the initiating session alive; peers revalidate and close
            // only sockets whose other session rows were revoked.
            notify_sync_wake(&mut tx).await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;

        Ok(password_change_response(
            &request.operation_id,
            new_version,
            false,
        ))
    }

    async fn verify_password_change_verifier(
        &self,
        user: &auth::AuthUser,
        verifier: &str,
    ) -> Result<String, ApiError> {
        let encoded: Option<String> = sqlx::query_scalar(
            "SELECT c.login_verifier_hash FROM auth_credentials c \
             JOIN users u ON u.user_id=c.user_id \
             WHERE c.user_id=$1 AND u.status='active'",
        )
        .bind(&user.user_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let encoded = encoded.ok_or_else(ApiError::reauth_required)?;
        auth::check_password_hash(verifier, &encoded).map_err(|error| {
            if error.status == StatusCode::UNAUTHORIZED {
                ApiError::reauth_required()
            } else {
                error
            }
        })?;
        Ok(encoded)
    }

    async fn record_password_change_event(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user: &auth::AuthUser,
        result: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, &user.user_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'auth.password_changed','account',$2,$4,$5,'api')",
        )
        .bind(scope_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(result)
        .bind(occurred_at)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn record_password_change_failure_best_effort(&self, user: &auth::AuthUser) {
        let Ok(mut tx) = self.pool.begin().await else {
            tracing::warn!(
                event = "auth_password_change_failure_audit_write_failed",
                "failed password-change audit could not be persisted"
            );
            return;
        };
        let scope_id = match crate::audit::account_scope_id(&self.audit_scope_key, &user.user_id) {
            Ok(scope_id) => scope_id,
            Err(_) => {
                let _ = tx.rollback().await;
                tracing::warn!(
                    event = "auth_password_change_failure_audit_write_failed",
                    "failed password-change audit could not be persisted"
                );
                return;
            }
        };
        let written = sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'auth.password_change_failed', \
                      'account',$2,'failure',$4,'api')",
        )
        .bind(scope_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(Utc::now().timestamp())
        .execute(&mut *tx)
        .await;
        if written.is_err() || tx.commit().await.is_err() {
            tracing::warn!(
                event = "auth_password_change_failure_audit_write_failed",
                "failed password-change audit could not be persisted"
            );
        }
    }

    /// Returns the account ID and KDF parameters used by the verifier flow.
    /// Deleting accounts remain eligible for prelogin so their clients can
    /// prove credentials to the cancellation path, matching SQLite behavior.
    pub(crate) async fn prelogin_user(
        &self,
        username: &str,
    ) -> Result<Option<(String, String)>, ApiError> {
        let username = crate::auth::normalized_username(username)?;
        let row = sqlx::query(
            "SELECT u.user_id,c.kdf_json \
             FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
             WHERE u.username=$1 AND u.status IN ('active','deleting')",
        )
        .bind(username)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        row.map(|row| {
            Ok((
                row.try_get("user_id").map_err(ApiError::internal)?,
                row.try_get("kdf_json").map_err(ApiError::internal)?,
            ))
        })
        .transpose()
    }

    /// Verifies the client-derived verifier and issues a session for an active
    /// provisioned account/device. Credential verification happens before
    /// taking row locks; the account and credential are then rechecked under
    /// lock before either issuing an MFA challenge or inserting a session.
    pub(crate) async fn login_password(
        &self,
        username: &str,
        login_verifier: &str,
        device_id: &str,
        dummy_login_verifier_hash: &str,
    ) -> Result<PgPasswordLoginOutcome, ApiError> {
        let username = crate::auth::normalized_username(username)?;
        let credential = sqlx::query(
            "SELECT u.user_id,c.login_verifier_hash,c.credential_version \
             FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
             WHERE u.username=$1 AND u.status='active'",
        )
        .bind(&username)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?;

        let Some(credential) = credential else {
            let _ = crate::auth::check_password_hash(login_verifier, dummy_login_verifier_hash);
            return Err(ApiError::unauthorized());
        };
        let user_id: String = credential.try_get("user_id").map_err(ApiError::internal)?;
        let verifier_hash: String = credential
            .try_get("login_verifier_hash")
            .map_err(ApiError::internal)?;
        let credential_version: i64 = credential
            .try_get("credential_version")
            .map_err(ApiError::internal)?;

        if let Err(error) = crate::auth::check_password_hash(login_verifier, &verifier_hash) {
            if error.status == StatusCode::UNAUTHORIZED {
                self.record_login_failure_best_effort(&user_id).await;
            }
            return Err(error);
        }

        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_account_lifecycle(&mut transaction, &user_id).await?;

        // New login has no extant session to lock. Lock account then device,
        // and re-read the verifier before session creation. Existing-session
        // operations below follow session -> account -> device.
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&user_id)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            transaction.rollback().await.map_err(ApiError::internal)?;
            self.record_login_failure_best_effort(&user_id).await;
            return Err(ApiError::unauthorized());
        }

        let current_credentials: Option<(String, i64)> = sqlx::query_as(
            "SELECT login_verifier_hash,credential_version \
             FROM auth_credentials WHERE user_id=$1 FOR SHARE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if current_credentials
            .as_ref()
            .map_or(true, |(hash, version)| {
                hash != &verifier_hash || *version != credential_version
            })
        {
            transaction.rollback().await.map_err(ApiError::internal)?;
            return Err(ApiError::unauthorized());
        }

        let device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(device_id)
        .bind(&user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if device_status.as_deref() != Some("active") {
            transaction.rollback().await.map_err(ApiError::internal)?;
            self.record_login_failure_best_effort(&user_id).await;
            if device_status.is_some() {
                return Err(ApiError::forbidden(
                    "DEVICE_REVOKED",
                    "device is not active",
                ));
            }
            return Err(ApiError::unauthorized());
        }

        // MFA state changes must take the account row FOR UPDATE before
        // updating/inserting this row. The account SHARE fence blocks that
        // writer even when the row does not exist yet; locking an extant row
        // also prevents an in-place disable from racing session issuance.
        let mfa_enabled: Option<bool> = sqlx::query_scalar(
            "SELECT (enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL) \
             FROM auth_mfa WHERE user_id=$1 FOR SHARE",
        )
        .bind(&user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if mfa_enabled.unwrap_or(false) {
            let (_, current_version) = current_credentials
                .ok_or_else(|| ApiError::internal("current credential row disappeared"))?;
            let (challenge_id, expires_at, expires_epoch) =
                crate::pg_mfa::create_login_challenge_tx(
                    &mut transaction,
                    &user_id,
                    device_id,
                    current_version,
                )
                .await?;
            self.record_mfa_challenge_created(
                &mut transaction,
                &user_id,
                device_id,
                expires_epoch.saturating_sub(crate::mfa::LOGIN_CHALLENGE_TTL_SECONDS),
            )
            .await?;
            transaction.commit().await.map_err(ApiError::internal)?;
            return Ok(PgPasswordLoginOutcome::MfaChallenge {
                challenge_id,
                expires_at,
            });
        }

        let response = self
            .create_login_session_tx(
                &mut transaction,
                &user_id,
                device_id,
                Utc::now().timestamp(),
            )
            .await?;
        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(PgPasswordLoginOutcome::Session(response))
    }

    /// Inserts a standard session, login success event, and current Vault
    /// projection into a caller-owned transaction. Password login and MFA
    /// completion share this path so they return identical AuthSession DTOs.
    pub(crate) async fn create_login_session_tx(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        user_id: &str,
        device_id: &str,
        occurred_at: i64,
    ) -> Result<PgLoginResponse, ApiError> {
        let session_id = Uuid::new_v4().to_string();
        let family_id = Uuid::new_v4().to_string();
        let access_token = crate::auth::random_token();
        let refresh_token = crate::auth::random_token();
        let now = Utc::now();
        sqlx::query(
            "INSERT INTO sessions( \
                 session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at,created_at \
             ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
        )
        .bind(&session_id)
        .bind(user_id)
        .bind(device_id)
        .bind(&family_id)
        .bind(sha256_hex(access_token.as_bytes()))
        .bind(sha256_hex(refresh_token.as_bytes()))
        .bind(now + Duration::seconds(ACCESS_TTL_SECONDS))
        .bind(now + Duration::days(REFRESH_TTL_DAYS))
        .bind(now)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        // The only follow-up read is an ordinary MVCC projection SELECT with
        // no row locks; it does not wait for domain writes after audit access.
        self.record_login_success(transaction, user_id, device_id, occurred_at)
            .await?;
        let vaults = Self::load_login_vaults(transaction, user_id).await?;
        Ok(PgLoginResponse {
            account_id: user_id.to_owned(),
            access_token,
            expires_in: ACCESS_TTL_SECONDS,
            refresh_token,
            device_id: device_id.to_owned(),
            vaults,
        })
    }

    async fn record_mfa_challenge_created(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        user_id: &str,
        device_id: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, user_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'auth.mfa_login_challenge_created', \
                      'account',$2,'success',$4,'api')",
        )
        .bind(scope_id)
        .bind(user_id)
        .bind(device_id)
        .bind(occurred_at)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    /// Rotates an active refresh token. A previously consumed token revokes
    /// every still-live session in its family and commits that revocation
    /// before attempting optional audit persistence.
    pub(crate) async fn refresh_token(&self, raw_token: &str) -> Result<PgAuthTokens, ApiError> {
        let old_hash = sha256_hex(raw_token.as_bytes());
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;

        // Discover the account without taking a session row lock, then take
        // the shared lifecycle fence before locking the refresh row. Recovery
        // takes the same fence before enumerating/revoking sessions, avoiding
        // a session/account lock cycle when a just-issued session is refreshed.
        let lifecycle_user_id: Option<String> = sqlx::query_scalar(
            "SELECT user_id FROM sessions WHERE refresh_hash=$1 \
             UNION ALL SELECT user_id FROM refresh_history WHERE refresh_hash=$1 LIMIT 1",
        )
        .bind(&old_hash)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if let Some(user_id) = lifecycle_user_id.as_deref() {
            lock_account_lifecycle(&mut transaction, user_id).await?;
        }

        // The row lock is the rotation linearization point. If another request
        // rotates this token while we wait, PostgreSQL rechecks the predicate
        // against the updated row and this lookup falls through to history.
        let current = sqlx::query(
            "SELECT session_id,user_id,device_id,family_id,refresh_expires_at,revoked_at \
             FROM sessions WHERE refresh_hash=$1 FOR UPDATE",
        )
        .bind(&old_hash)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;

        let Some(current) = current else {
            let reuse_audit = self
                .handle_refresh_reuse(&mut transaction, &old_hash)
                .await?;
            transaction.commit().await.map_err(ApiError::internal)?;
            if let Some((user_id, family_id)) = reuse_audit {
                self.record_refresh_reuse_best_effort(&user_id, &family_id)
                    .await;
            }
            return Err(ApiError::unauthorized());
        };

        if current
            .try_get::<Option<chrono::DateTime<Utc>>, _>("revoked_at")
            .map_err(ApiError::internal)?
            .is_some()
        {
            return Err(ApiError::unauthorized());
        }
        let expires_at: chrono::DateTime<Utc> = current
            .try_get("refresh_expires_at")
            .map_err(ApiError::internal)?;
        if expires_at <= Utc::now() {
            return Err(ApiError::unauthorized());
        }

        let session_id: String = current.try_get("session_id").map_err(ApiError::internal)?;
        let user_id: String = current.try_get("user_id").map_err(ApiError::internal)?;
        let device_id: String = current.try_get("device_id").map_err(ApiError::internal)?;
        let family_id: String = current.try_get("family_id").map_err(ApiError::internal)?;

        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&user_id)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(&device_id)
        .bind(&user_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if device_status.as_deref() != Some("active") {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }

        let access_token = crate::auth::random_token();
        let refresh_token = crate::auth::random_token();
        let now = Utc::now();
        let updated = sqlx::query(
            "UPDATE sessions SET access_hash=$1,refresh_hash=$2, \
                 access_expires_at=$3,refresh_expires_at=$4 \
             WHERE session_id=$5 AND refresh_hash=$6 AND revoked_at IS NULL",
        )
        .bind(sha256_hex(access_token.as_bytes()))
        .bind(sha256_hex(refresh_token.as_bytes()))
        .bind(now + Duration::seconds(ACCESS_TTL_SECONDS))
        .bind(now + Duration::days(REFRESH_TTL_DAYS))
        .bind(&session_id)
        .bind(&old_hash)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::unauthorized());
        }

        sqlx::query(
            "INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) \
             VALUES($1,$2,$3,$4,$5)",
        )
        .bind(&old_hash)
        .bind(&family_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;

        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(PgAuthTokens {
            account_id: user_id,
            device_id,
            access_token,
            expires_in: ACCESS_TTL_SECONDS,
            refresh_token,
        })
    }

    async fn handle_refresh_reuse(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        old_hash: &str,
    ) -> Result<Option<(String, String)>, ApiError> {
        let history =
            sqlx::query("SELECT family_id,user_id FROM refresh_history WHERE refresh_hash=$1")
                .bind(old_hash)
                .fetch_optional(&mut **transaction)
                .await
                .map_err(ApiError::internal)?;
        let Some(history) = history else {
            return Ok(None);
        };
        let family_id: String = history.try_get("family_id").map_err(ApiError::internal)?;
        let history_user_id: String = history.try_get("user_id").map_err(ApiError::internal)?;

        // Lock all currently live family sessions in stable order, then take
        // the account/device fences in the same order used by sync writes and
        // logout. A concurrent rotation therefore either finishes first and
        // is revoked here, or observes the revocation and fails.
        let live_sessions = sqlx::query(
            "SELECT session_id,user_id,device_id FROM sessions \
             WHERE family_id=$1 AND revoked_at IS NULL \
             ORDER BY session_id FOR UPDATE",
        )
        .bind(&family_id)
        .fetch_all(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        if live_sessions.is_empty() {
            return Ok(None);
        }

        let mut device_ids = BTreeSet::new();
        for session in &live_sessions {
            let session_user_id: String = session.try_get("user_id").map_err(ApiError::internal)?;
            if session_user_id != history_user_id {
                return Err(ApiError::internal(
                    "refresh family ownership is inconsistent",
                ));
            }
            device_ids.insert(
                session
                    .try_get::<String, _>("device_id")
                    .map_err(ApiError::internal)?,
            );
        }

        let account: Option<String> =
            sqlx::query_scalar("SELECT user_id FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&history_user_id)
                .fetch_optional(&mut **transaction)
                .await
                .map_err(ApiError::internal)?;
        if account.is_none() {
            return Ok(None);
        }
        for device_id in device_ids {
            let _: Option<String> = sqlx::query_scalar(
                "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
            )
            .bind(device_id)
            .bind(&history_user_id)
            .fetch_optional(&mut **transaction)
            .await
            .map_err(ApiError::internal)?;
        }

        let revoked = sqlx::query(
            "UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP \
             WHERE family_id=$1 AND revoked_at IS NULL",
        )
        .bind(&family_id)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        if revoked.rows_affected() > 0 {
            notify_sync_wake(transaction).await?;
            Ok(Some((history_user_id, family_id)))
        } else {
            Ok(None)
        }
    }

    async fn record_login_success(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        user_id: &str,
        device_id: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, user_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'auth.login_succeeded', \
                      'account',$2,'success',$4,'api')",
        )
        .bind(scope_id)
        .bind(user_id)
        .bind(device_id)
        .bind(occurred_at)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn load_login_vaults(
        transaction: &mut Transaction<'_, Postgres>,
        user_id: &str,
    ) -> Result<Vec<PgLoginVaultDescriptor>, ApiError> {
        let rows = sqlx::query(
            "SELECT v.vault_id,vm.role,v.active_epoch,v.membership_version, \
                    v.name_envelope::text AS name_envelope \
             FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' AND v.state='active' \
             ORDER BY v.vault_id",
        )
        .bind(user_id)
        .fetch_all(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;

        rows.into_iter()
            .map(|row| {
                let envelope_text: Option<String> =
                    row.try_get("name_envelope").map_err(ApiError::internal)?;
                let envelope = envelope_text
                    .map(|value| serde_json::from_str(&value).map_err(ApiError::internal))
                    .transpose()?;
                Ok(PgLoginVaultDescriptor {
                    vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
                    role: row.try_get("role").map_err(ApiError::internal)?,
                    active_key_epoch: row.try_get("active_epoch").map_err(ApiError::internal)?,
                    membership_version: row
                        .try_get("membership_version")
                        .map_err(ApiError::internal)?,
                    name_envelope: envelope,
                })
            })
            .collect()
    }

    async fn record_login_failure_best_effort(&self, user_id: &str) {
        let result = async {
            let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, user_id)?;
            sqlx::query(
                "INSERT INTO audit_events( \
                     scope_type,scope_id,actor_user_id,actor_device_id,action, \
                     resource_type,resource_id,result,occurred_at,source \
                 ) VALUES('account',$1,NULL,NULL,'auth.login_failed', \
                          'account',NULL,'failure',$2,'api')",
            )
            .bind(scope_id)
            .bind(Utc::now().timestamp())
            .execute(&self.pool)
            .await
            .map_err(ApiError::internal)?;
            Ok::<(), ApiError>(())
        }
        .await;
        if result.is_err() {
            tracing::warn!(
                event = "auth_login_failure_audit_write_failed",
                "failed-login audit could not be persisted"
            );
        }
    }

    async fn record_refresh_reuse_best_effort(&self, user_id: &str, family_id: &str) {
        let result = async {
            let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, user_id)?;
            sqlx::query(
                "INSERT INTO audit_events( \
                     scope_type,scope_id,actor_user_id,actor_device_id,action, \
                     resource_type,resource_id,result,occurred_at,source \
                 ) VALUES('account',$1,NULL,NULL,'auth.refresh_reuse_detected', \
                          'session_family',$2,'failure',$3,'api')",
            )
            .bind(scope_id)
            .bind(family_id)
            .bind(Utc::now().timestamp())
            .execute(&self.pool)
            .await
            .map_err(ApiError::internal)?;
            Ok::<(), ApiError>(())
        }
        .await;
        if result.is_err() {
            tracing::warn!(
                event = "auth_refresh_reuse_audit_write_failed",
                "refresh-token replay revocation could not be audited"
            );
        }
    }
}

/// Locks the current session set and the account rows using the shared
/// lifecycle row order: sessions, account, credentials, then devices. The
/// caller must first take `lock_account_lifecycle` so login/refresh and other
/// session-revocation flows cannot add a session while this set is checked.
pub(crate) async fn lock_active_principal_tx(
    transaction: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
) -> Result<(String, i64), ApiError> {
    let sessions = sqlx::query(
        "SELECT session_id,device_id,access_hash,access_expires_at>CURRENT_TIMESTAMP AS unexpired, \
                revoked_at \
         FROM sessions WHERE user_id=$1 ORDER BY session_id FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_all(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    let Some(session) = sessions.iter().find(|row| {
        row.try_get::<String, _>("session_id").ok().as_deref() == Some(user.session_id.as_str())
    }) else {
        return Err(ApiError::unauthorized());
    };
    let session_device: String = session.try_get("device_id").map_err(ApiError::internal)?;
    let access_hash: String = session.try_get("access_hash").map_err(ApiError::internal)?;
    let unexpired: bool = session.try_get("unexpired").map_err(ApiError::internal)?;
    let revoked_at: Option<chrono::DateTime<Utc>> =
        session.try_get("revoked_at").map_err(ApiError::internal)?;
    if session_device != user.device_id
        || access_hash != user.access_hash
        || !unexpired
        || revoked_at.is_some()
    {
        return Err(ApiError::unauthorized());
    }

    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(&user.user_id)
            .fetch_optional(&mut **transaction)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let credentials: Option<(String, i64)> = sqlx::query_as(
        "SELECT login_verifier_hash,credential_version FROM auth_credentials \
         WHERE user_id=$1 FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    let Some(credentials) = credentials else {
        return Err(ApiError::unauthorized());
    };

    let devices = sqlx::query(
        "SELECT device_id,status FROM devices WHERE user_id=$1 ORDER BY device_id FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_all(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    let current_device_active = devices.iter().any(|row| {
        row.try_get::<String, _>("device_id").ok().as_deref() == Some(user.device_id.as_str())
            && row.try_get::<String, _>("status").ok().as_deref() == Some("active")
    });
    if !current_device_active {
        // Authentication already succeeded before the lifecycle transition;
        // preserve the sensitive-operation behavior of the SQLite path.
        return Err(ApiError::unauthorized());
    }
    Ok(credentials)
}

async fn password_change_receipt(
    transaction: &mut Transaction<'_, Postgres>,
    session_id: &str,
    operation_id: &str,
    request_digest: &str,
) -> Result<Option<i64>, ApiError> {
    let receipt = sqlx::query(
        "SELECT operation_id,request_digest,credential_version \
         FROM password_change_receipts WHERE session_id=$1",
    )
    .bind(session_id)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    let Some(receipt) = receipt else {
        return Ok(None);
    };
    let stored_operation_id: String = receipt
        .try_get("operation_id")
        .map_err(ApiError::internal)?;
    if stored_operation_id != operation_id {
        return Ok(None);
    }
    let stored_digest: String = receipt
        .try_get("request_digest")
        .map_err(ApiError::internal)?;
    if stored_digest != request_digest {
        return Err(ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "password-change operation ID was reused with different content",
        ));
    }
    receipt
        .try_get("credential_version")
        .map(Some)
        .map_err(ApiError::internal)
}

fn password_change_response(
    operation_id: &str,
    credential_version: i64,
    already_applied: bool,
) -> serde_json::Value {
    serde_json::json!({
        "status": "changed",
        "operation_id": operation_id,
        "credential_version": credential_version,
        "session_preserved": true,
        "other_sessions_revoked": true,
        "already_applied": already_applied,
    })
}

#[cfg(test)]
mod tests {
    use std::{
        future::Future,
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
    };

    use futures_util::FutureExt;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const INSTANCE_MIGRATION: &str = include_str!("../migrations/postgres/0003_instance_meta.sql");
    const AUTH_MIGRATION: &str = include_str!("../migrations/postgres/0009_auth_lifecycle.sql");
    const TEST_DB_URL_ENV: &str = "ATERMIUS_TEST_PG_URL";
    const AUDIT_KEY: [u8; 32] = [0x91; 32];

    #[derive(Clone)]
    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var(TEST_DB_URL_ENV)
                .expect("ignored PostgreSQL auth tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing PostgreSQL tests outside an explicitly disposable database"
            );

            let admin_pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect PostgreSQL disposable test database");
            let schema = format!("atermius_pg_auth_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL auth schema");
            let pool_options = options.options([("search_path", format!("\"{schema}\""))]);
            let pool = PgPoolOptions::new()
                .max_connections(16)
                .connect_with(pool_options)
                .await
                .expect("connect isolated PostgreSQL auth schema");
            for migration in [CORE_MIGRATION, INSTANCE_MIGRATION, AUTH_MIGRATION] {
                if let Err(error) = sqlx::raw_sql(migration).execute(&pool).await {
                    pool.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                    panic!("apply isolated PostgreSQL auth migration: {error}");
                }
            }
            Self {
                pool,
                admin_pool,
                schema,
            }
        }

        async fn cleanup(self) {
            self.pool.close().await;
            let _ = sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await;
            self.admin_pool.close().await;
        }
    }

    async fn with_database<F, Fut>(run: F)
    where
        F: FnOnce(TestDatabase) -> Fut,
        Fut: Future<Output = ()>,
    {
        let database = TestDatabase::create().await;
        let result = AssertUnwindSafe(run(database.clone())).catch_unwind().await;
        database.cleanup().await;
        if let Err(payload) = result {
            resume_unwind(payload);
        }
    }

    async fn seed_session(pool: &PgPool, family_id: &str, refresh_token: &str) -> String {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(&user_id)
            .bind(format!("{}@example.test", Uuid::new_v4()))
            .execute(pool)
            .await
            .expect("insert test account");
        sqlx::query("INSERT INTO devices(device_id,user_id,status) VALUES($1,$2,'active')")
            .bind(&device_id)
            .bind(&user_id)
            .execute(pool)
            .await
            .expect("insert test device");
        sqlx::query(
            "INSERT INTO sessions( \
                 session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at \
             ) VALUES($1,$2,$3,$4,$5,$6,CURRENT_TIMESTAMP+INTERVAL '10 minutes', \
                      CURRENT_TIMESTAMP+INTERVAL '30 days')",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(family_id)
        .bind(sha256_hex(b"test-access-token-which-is-not-used"))
        .bind(sha256_hex(refresh_token.as_bytes()))
        .execute(pool)
        .await
        .expect("insert test session");
        user_id
    }

    async fn seed_consumed_token(
        pool: &PgPool,
        family_id: &str,
        user_id: &str,
        device_id: &str,
        refresh_token: &str,
    ) {
        sqlx::query(
            "INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) \
             VALUES($1,$2,$3,$4,CURRENT_TIMESTAMP)",
        )
        .bind(sha256_hex(refresh_token.as_bytes()))
        .bind(family_id)
        .bind(user_id)
        .bind(device_id)
        .execute(pool)
        .await
        .expect("insert consumed refresh hash");
    }

    async fn session_device(pool: &PgPool, user_id: &str) -> String {
        sqlx::query_scalar("SELECT device_id FROM devices WHERE user_id=$1")
            .bind(user_id)
            .fetch_one(pool)
            .await
            .expect("read test device")
    }

    async fn assert_family_revoked(pool: &PgPool, family_id: &str) {
        let active: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sessions WHERE family_id=$1 AND revoked_at IS NULL",
        )
        .bind(family_id)
        .fetch_one(pool)
        .await
        .expect("count live family sessions");
        assert_eq!(active, 0);
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL to name a disposable PostgreSQL database"]
    async fn refresh_replay_invalidates_old_token_and_revokes_the_family() {
        with_database(|database| async move {
            let old_token = crate::auth::random_token();
            let current_token = crate::auth::random_token();
            let family_id = Uuid::new_v4().to_string();
            let user_id = seed_session(&database.pool, &family_id, &current_token).await;
            let device_id = session_device(&database.pool, &user_id).await;
            seed_consumed_token(&database.pool, &family_id, &user_id, &device_id, &old_token).await;
            let repository = PgAuthLifecycleRepository::new(database.pool.clone(), AUDIT_KEY);

            let rotated = repository
                .refresh_token(&current_token)
                .await
                .expect("rotate active token");
            assert_ne!(rotated.refresh_token, current_token);

            assert!(repository.refresh_token(&current_token).await.is_err());
            assert_family_revoked(&database.pool, &family_id).await;
            assert!(
                repository
                    .refresh_token(&rotated.refresh_token)
                    .await
                    .is_err()
            );

            let history_count: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM refresh_history WHERE family_id=$1")
                    .bind(&family_id)
                    .fetch_one(&database.pool)
                    .await
                    .expect("count refresh history");
            assert_eq!(history_count, 2);
            let audit_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
            )
            .fetch_one(&database.pool)
            .await
            .expect("count replay audit events");
            assert_eq!(audit_count, 1);
        })
        .await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL to name a disposable PostgreSQL database"]
    async fn concurrent_rotation_and_replay_leave_no_live_family_session() {
        with_database(|database| async move {
            let consumed_token = crate::auth::random_token();
            let current_token = crate::auth::random_token();
            let family_id = Uuid::new_v4().to_string();
            let user_id = seed_session(&database.pool, &family_id, &current_token).await;
            let device_id = session_device(&database.pool, &user_id).await;
            seed_consumed_token(
                &database.pool,
                &family_id,
                &user_id,
                &device_id,
                &consumed_token,
            )
            .await;

            let repository = PgAuthLifecycleRepository::new(database.pool.clone(), AUDIT_KEY);
            let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(3));
            let rotate_repository = repository.clone();
            let rotate_barrier = barrier.clone();
            let rotate = tokio::spawn(async move {
                rotate_barrier.wait().await;
                rotate_repository.refresh_token(&current_token).await
            });
            let replay_repository = repository.clone();
            let replay_barrier = barrier.clone();
            let replay = tokio::spawn(async move {
                replay_barrier.wait().await;
                replay_repository.refresh_token(&consumed_token).await
            });
            barrier.wait().await;

            let rotate_result = rotate.await.expect("rotation task");
            let replay_result = replay.await.expect("replay task");
            assert_family_revoked(&database.pool, &family_id).await;
            if let Err(error) = &rotate_result {
                assert_eq!(error.status, StatusCode::UNAUTHORIZED);
            }
            if let Err(error) = &replay_result {
                assert_eq!(error.status, StatusCode::UNAUTHORIZED);
            }
            assert!(replay_result.is_err());

            if let Ok(tokens) = rotate_result {
                assert!(
                    repository
                        .refresh_token(&tokens.refresh_token)
                        .await
                        .is_err()
                );
            }
            let audit_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
            )
            .fetch_one(&database.pool)
            .await
            .expect("count replay audit events");
            assert_eq!(audit_count, 1);
        })
        .await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL to name a disposable PostgreSQL database"]
    async fn simultaneous_reuse_of_one_refresh_token_rotates_at_most_once_then_revokes() {
        with_database(|database| async move {
            let refresh_token = crate::auth::random_token();
            let family_id = Uuid::new_v4().to_string();
            seed_session(&database.pool, &family_id, &refresh_token).await;
            let repository = PgAuthLifecycleRepository::new(database.pool.clone(), AUDIT_KEY);
            let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(3));

            let first_repository = repository.clone();
            let first_barrier = barrier.clone();
            let first_token = refresh_token.clone();
            let first = tokio::spawn(async move {
                first_barrier.wait().await;
                first_repository.refresh_token(&first_token).await
            });
            let second_repository = repository.clone();
            let second_barrier = barrier.clone();
            let second_token = refresh_token.clone();
            let second = tokio::spawn(async move {
                second_barrier.wait().await;
                second_repository.refresh_token(&second_token).await
            });
            barrier.wait().await;

            let first_result = first.await.expect("first refresh task");
            let second_result = second.await.expect("second refresh task");
            assert_ne!(first_result.is_ok(), second_result.is_ok());
            assert_family_revoked(&database.pool, &family_id).await;
            let audit_count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.refresh_reuse_detected'",
            )
            .fetch_one(&database.pool)
            .await
            .expect("count replay audit events");
            assert_eq!(audit_count, 1);
        })
        .await;
    }
}

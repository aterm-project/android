//! PostgreSQL first-account bootstrap, operator invitations, and registration.
//!
//! Callers validate all client-controlled cryptographic inputs in `auth.rs`
//! before invoking this repository. This module owns the shared PostgreSQL
//! transaction, setup/invitation gates, inserts, session issuance, and audit
//! rows so every service node observes the same onboarding state.

use chrono::{Duration, Utc};
use serde_json::Value;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, auth};

const ACCESS_TTL_SECONDS: i64 = 600;
const REFRESH_TTL_DAYS: i64 = 30;
const INVITATION_MIN_SECONDS: i64 = 60;
const INVITATION_MAX_SECONDS: i64 = 2_592_000;
const INVITATION_PRUNE_BATCH_SIZE: i64 = 500;
const INVITATION_PRUNE_BATCHES_PER_PASS: usize = 4;

#[derive(Clone)]
pub(crate) struct PgAccountOnboardingRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
    instance_id: String,
    invitation_retention_seconds: i64,
    device_enrollment: crate::pg_device_enrollment::PgDeviceEnrollmentRepository,
    device_lifecycle: crate::pg_device_lifecycle::PgDeviceLifecycleRepository,
    vault_lifecycle: crate::pg_vault_lifecycle::PgVaultLifecycleRepository,
    vault_invitations: crate::pg_vault_invitations::PgVaultInvitationRepository,
    vault_rotation: crate::pg_vault_rotation::PgVaultRotationRepository,
}

/// Already validated registration fields. JSON values are serialized by
/// `auth.rs`; the PostgreSQL adapter casts those strings to JSONB at insert.
pub(crate) struct PgRegistrationInput<'a> {
    pub(crate) account_id: &'a str,
    pub(crate) username: &'a str,
    pub(crate) bootstrap_token: Option<&'a str>,
    pub(crate) instance_invitation_token: Option<&'a str>,
    pub(crate) kdf_json: &'a str,
    pub(crate) login_verifier: &'a str,
    pub(crate) account_key_envelope: &'a str,
    pub(crate) device: &'a auth::DeviceInput,
    pub(crate) initial_vault: &'a auth::InitialVault,
    /// JSON serialization returned by `auth::validate_initial_vault`.
    pub(crate) vault_name: &'a str,
    pub(crate) manifest_digest: &'a str,
    /// Serialized signed membership record returned by `auth::validate_initial_vault`.
    pub(crate) manifest_json: &'a str,
}

#[derive(Debug)]
pub(crate) struct PgRegisteredSession {
    pub(crate) account_id: String,
    pub(crate) device_id: String,
    pub(crate) access_token: String,
    pub(crate) expires_in: i64,
    pub(crate) refresh_token: String,
    pub(crate) vault_id: String,
}

impl PgAccountOnboardingRepository {
    pub(crate) fn new(
        pool: PgPool,
        audit_scope_key: [u8; 32],
        instance_id: String,
        invitation_retention_days: i64,
        max_vaults_per_user: i64,
        max_members_per_vault: i64,
    ) -> Self {
        Self {
            device_enrollment: crate::pg_device_enrollment::PgDeviceEnrollmentRepository::new(
                pool.clone(),
                audit_scope_key,
            ),
            device_lifecycle: crate::pg_device_lifecycle::PgDeviceLifecycleRepository::new(
                pool.clone(),
                audit_scope_key,
            ),
            vault_lifecycle: crate::pg_vault_lifecycle::PgVaultLifecycleRepository::new(
                pool.clone(),
                max_vaults_per_user,
            ),
            vault_invitations: crate::pg_vault_invitations::PgVaultInvitationRepository::new(
                pool.clone(),
                max_vaults_per_user,
                max_members_per_vault,
            ),
            vault_rotation: crate::pg_vault_rotation::PgVaultRotationRepository::new(pool.clone()),
            pool,
            audit_scope_key,
            instance_id,
            invitation_retention_seconds: invitation_retention_days.saturating_mul(86_400),
        }
    }

    /// Registers an additional device and its complete set of Vault key
    /// envelopes in the shared PostgreSQL transaction.
    pub(crate) async fn register_device(
        &self,
        user: &auth::AuthUser,
        request: &auth::AddDeviceRequest,
    ) -> Result<serde_json::Value, ApiError> {
        self.device_enrollment.register_device(user, request).await
    }

    /// Updates the current device's signed capability report in shared state.
    pub(crate) async fn put_device_capability_report(
        &self,
        user: &auth::AuthUser,
        report: &crate::device_capabilities::DeviceCapabilityReport,
    ) -> Result<serde_json::Value, ApiError> {
        self.device_lifecycle
            .put_capability_report(user, report)
            .await
    }

    /// Revokes one active device and all of its sessions atomically.
    pub(crate) async fn revoke_device(
        &self,
        user: &auth::AuthUser,
        target_device_id: &str,
    ) -> Result<serde_json::Value, ApiError> {
        self.device_lifecycle
            .revoke_device(user, target_device_id)
            .await
    }

    /// Creates a Vault and its first owner context in shared PostgreSQL state.
    pub(crate) async fn create_vault(
        &self,
        user: &auth::AuthUser,
        request: crate::control::CreateVaultRequest,
    ) -> Result<serde_json::Value, ApiError> {
        self.vault_lifecycle.create_vault(user, request).await
    }

    /// Issues a signed, device-bound invitation into shared PostgreSQL state.
    pub(crate) async fn create_vault_invitation(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        request: crate::control::InvitationRequest,
    ) -> Result<serde_json::Value, ApiError> {
        self.vault_invitations
            .create_invitation(user, vault_id, request)
            .await
    }

    /// Accepts a one-time PostgreSQL invitation addressed to this exact device.
    pub(crate) async fn accept_vault_invitation(
        &self,
        user: &auth::AuthUser,
        request: crate::control::AcceptInvitation,
    ) -> Result<serde_json::Value, ApiError> {
        self.vault_invitations
            .accept_invitation(user, request)
            .await
    }

    /// Rotates a Vault's active key epoch in shared PostgreSQL state.
    pub(crate) async fn rotate_vault_key(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        request: crate::control::RotateRequest,
    ) -> Result<serde_json::Value, ApiError> {
        self.vault_rotation
            .rotate_key(user, vault_id, request)
            .await
    }

    /// Rotates a Vault's active key epoch while atomically transferring its
    /// owner in shared PostgreSQL state.
    pub(crate) async fn transfer_vault_ownership(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        new_owner_user_id: String,
        request: crate::control::RotateRequest,
    ) -> Result<serde_json::Value, ApiError> {
        self.vault_rotation
            .transfer_ownership(user, vault_id, new_owner_user_id, request)
            .await
    }

    /// Prunes old terminal invitation credentials in bounded batches. Audit
    /// events live in their own retention-managed table, so deleting a token
    /// row does not erase its audit history.
    pub(crate) async fn prune_invitation_history(&self) -> Result<(), ApiError> {
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        self.prune_invitation_history_in(&mut transaction).await?;
        transaction.commit().await.map_err(ApiError::internal)
    }

    async fn prune_invitation_history_in(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
    ) -> Result<(), ApiError> {
        let cutoff = Utc::now() - Duration::seconds(self.invitation_retention_seconds);
        for _ in 0..INVITATION_PRUNE_BATCHES_PER_PASS {
            let deleted = sqlx::query(
                "WITH stale AS (\
                    SELECT invitation_id FROM account_invitations \
                    WHERE (consumed_at IS NOT NULL AND consumed_at < $1) \
                       OR (revoked_at IS NOT NULL AND revoked_at < $1) \
                       OR (consumed_at IS NULL AND revoked_at IS NULL AND expires_at < $1) \
                    ORDER BY created_at,invitation_id LIMIT $2 FOR UPDATE SKIP LOCKED\
                 ) DELETE FROM account_invitations AS invitation \
                   USING stale WHERE invitation.invitation_id=stale.invitation_id",
            )
            .bind(cutoff)
            .bind(INVITATION_PRUNE_BATCH_SIZE)
            .execute(&mut **transaction)
            .await
            .map_err(ApiError::internal)?
            .rows_affected();
            if deleted < INVITATION_PRUNE_BATCH_SIZE as u64 {
                break;
            }
        }
        Ok(())
    }

    /// Reports whether this installation still awaits its first account.
    pub(crate) async fn setup_required(&self) -> Result<bool, ApiError> {
        let row = sqlx::query(
            "SELECT m.setup_consumed_at, EXISTS(SELECT 1 FROM users) AS has_users \
             FROM instance_meta m WHERE m.id=1",
        )
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("PostgreSQL instance metadata is missing"))?;
        let consumed: Option<chrono::DateTime<Utc>> = row
            .try_get("setup_consumed_at")
            .map_err(ApiError::internal)?;
        let has_users: bool = row.try_get("has_users").map_err(ApiError::internal)?;
        Ok(!has_users && consumed.is_none())
    }

    /// Creates or replaces the one-time first-account bootstrap token. Only
    /// the SHA-256 hash is persisted, and concurrent service nodes serialize
    /// on the singleton instance metadata row.
    pub(crate) async fn create_bootstrap_token(&self) -> Result<String, ApiError> {
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        let metadata = lock_instance_meta(&mut transaction).await?;
        let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
        let consumed: Option<chrono::DateTime<Utc>> = metadata
            .try_get("setup_consumed_at")
            .map_err(ApiError::internal)?;
        if users > 0 || consumed.is_some() {
            return Err(ApiError::conflict(
                "SETUP_CLOSED",
                "initial setup has already been completed",
            ));
        }

        let token = auth::random_token();
        let token_hash = crate::sha256_hex(token.as_bytes());
        sqlx::query("UPDATE instance_meta SET bootstrap_token_hash=$1 WHERE id=1")
            .bind(token_hash)
            .execute(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(token)
    }

    /// Issues a username-bound operator invitation. Reissuing for a username
    /// revokes every still-live pending token in the same transaction.
    pub(crate) async fn issue_invitation(
        &self,
        raw_username: &str,
        lifetime_seconds: i64,
    ) -> Result<(String, String, String), ApiError> {
        let username = auth::normalized_username(raw_username)?;
        if !(INVITATION_MIN_SECONDS..=INVITATION_MAX_SECONDS).contains(&lifetime_seconds) {
            return Err(ApiError::bad_request(
                "INVALID_INVITATION_TTL",
                "account invitation lifetime must be between 60 and 2592000 seconds",
            ));
        }

        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        let metadata = lock_instance_meta(&mut transaction).await?;
        let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
        let consumed: Option<chrono::DateTime<Utc>> = metadata
            .try_get("setup_consumed_at")
            .map_err(ApiError::internal)?;
        if users == 0 || consumed.is_none() {
            return Err(ApiError::conflict(
                "SETUP_REQUIRED",
                "complete initial bootstrap before issuing account invitations",
            ));
        }

        self.prune_invitation_history_in(&mut transaction).await?;

        let username_exists: Option<i32> =
            sqlx::query_scalar("SELECT 1 FROM users WHERE username=$1")
                .bind(&username)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if username_exists.is_some() {
            return Err(ApiError::conflict(
                "USERNAME_TAKEN",
                "an account with this username already exists",
            ));
        }

        let now = Utc::now();
        let expires_at = now + Duration::seconds(lifetime_seconds);
        let superseded = sqlx::query(
            "UPDATE account_invitations SET revoked_at=$1 \
             WHERE username=$2 AND consumed_at IS NULL AND revoked_at IS NULL \
               AND expires_at>$1 RETURNING invitation_id",
        )
        .bind(now)
        .bind(&username)
        .fetch_all(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        let superseded_ids = superseded
            .into_iter()
            .map(|row| row.try_get::<String, _>("invitation_id"))
            .collect::<Result<Vec<_>, _>>()
            .map_err(ApiError::internal)?;

        let token = auth::random_token();
        let token_hash = crate::sha256_hex(token.as_bytes());
        let invitation_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO account_invitations( \
                 invitation_id,token_hash,username,created_at,expires_at \
             ) VALUES($1,$2,$3,$4,$5)",
        )
        .bind(&invitation_id)
        .bind(token_hash)
        .bind(&username)
        .bind(now)
        .bind(expires_at)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        // Append audit rows only after the invitation mutation is complete.
        // First-page audit readers temporarily hold SHARE on audit_events, so
        // a writer must not request another domain-row lock after its audit.
        for superseded_id in superseded_ids {
            self.record_instance_event(
                &mut transaction,
                "instance.account_invitation_revoked",
                "account_invitation",
                &superseded_id,
                now.timestamp(),
            )
            .await?;
        }
        self.record_instance_event(
            &mut transaction,
            "instance.account_invitation_issued",
            "account_invitation",
            &invitation_id,
            now.timestamp(),
        )
        .await?;
        transaction.commit().await.map_err(ApiError::internal)?;

        Ok((token, username, expires_at.to_rfc3339()))
    }

    /// Atomically consumes bootstrap/invitation state, creates the initial
    /// account/device/personal Vault, writes audit rows, and issues a session.
    pub(crate) async fn register(
        &self,
        input: PgRegistrationInput<'_>,
    ) -> Result<PgRegisteredSession, ApiError> {
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        let metadata = lock_instance_meta(&mut transaction).await?;
        let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;

        let mut bootstrap_token_hash_to_consume: Option<String> = None;
        let invitation_id: Option<String> = if user_count == 0 {
            if input.instance_invitation_token.is_some() {
                return Err(ApiError::bad_request(
                    "INVALID_ENROLLMENT_CREDENTIAL",
                    "initial bootstrap uses bootstrap_token",
                ));
            }
            let expected_hash: Option<String> = metadata
                .try_get("bootstrap_token_hash")
                .map_err(ApiError::internal)?;
            let consumed: Option<chrono::DateTime<Utc>> = metadata
                .try_get("setup_consumed_at")
                .map_err(ApiError::internal)?;
            let expected_hash = expected_hash.ok_or_else(ApiError::unauthorized)?;
            let provided_hash = input
                .bootstrap_token
                .map(|token| crate::sha256_hex(token.as_bytes()));
            if consumed.is_some() || provided_hash.as_deref() != Some(expected_hash.as_str()) {
                return Err(ApiError::unauthorized());
            }
            bootstrap_token_hash_to_consume = Some(expected_hash);
            None
        } else {
            if input.bootstrap_token.is_some() {
                return Err(ApiError::bad_request(
                    "INVALID_ENROLLMENT_CREDENTIAL",
                    "bootstrap_token is only valid for the first account",
                ));
            }
            let Some(token) = input.instance_invitation_token else {
                return Err(ApiError::forbidden(
                    "ACCOUNT_INVITATION_REQUIRED",
                    "account registration requires an operator-issued invitation",
                ));
            };
            let token_hash = crate::sha256_hex(token.as_bytes());
            let invite = sqlx::query(
                "SELECT invitation_id,username,expires_at,consumed_at,revoked_at \
                 FROM account_invitations WHERE token_hash=$1 FOR UPDATE",
            )
            .bind(token_hash)
            .fetch_optional(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
            let Some(invite) = invite else {
                return Err(account_invitation_invalid());
            };
            let invite_username: String = invite.try_get("username").map_err(ApiError::internal)?;
            let expires_at: chrono::DateTime<Utc> =
                invite.try_get("expires_at").map_err(ApiError::internal)?;
            let consumed_at: Option<chrono::DateTime<Utc>> =
                invite.try_get("consumed_at").map_err(ApiError::internal)?;
            let revoked_at: Option<chrono::DateTime<Utc>> =
                invite.try_get("revoked_at").map_err(ApiError::internal)?;
            if invite_username != input.username
                || consumed_at.is_some()
                || revoked_at.is_some()
                || expires_at <= Utc::now()
            {
                return Err(account_invitation_invalid());
            }
            Some(
                invite
                    .try_get("invitation_id")
                    .map_err(ApiError::internal)?,
            )
        };

        let username_exists: Option<i32> =
            sqlx::query_scalar("SELECT 1 FROM users WHERE username=$1")
                .bind(input.username)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if username_exists.is_some() {
            return Err(ApiError::conflict(
                "USERNAME_TAKEN",
                "account identifier is already registered",
            ));
        }
        let account_id_exists: Option<i32> =
            sqlx::query_scalar("SELECT 1 FROM users WHERE user_id=$1")
                .bind(input.account_id)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if account_id_exists.is_some() {
            return Err(ApiError::conflict(
                "ACCOUNT_ID_TAKEN",
                "account identifier is already registered",
            ));
        }
        let vault_id = &input.initial_vault.vault_id;
        let vault_exists: Option<i32> =
            sqlx::query_scalar("SELECT 1 FROM vaults WHERE vault_id=$1")
                .bind(vault_id)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if vault_exists.is_some() {
            return Err(ApiError::conflict(
                "VAULT_EXISTS",
                "vault identifier is already registered",
            ));
        }
        let device_exists: Option<i32> =
            sqlx::query_scalar("SELECT 1 FROM devices WHERE device_id=$1")
                .bind(&input.device.device_id)
                .fetch_optional(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        if device_exists.is_some() {
            return Err(ApiError::conflict(
                "DEVICE_EXISTS",
                "device identifier is already registered",
            ));
        }

        let now = Utc::now();
        if let Some(token_hash) = bootstrap_token_hash_to_consume {
            let consumed = sqlx::query(
                "UPDATE instance_meta SET bootstrap_token_hash=NULL,setup_consumed_at=$1 \
                 WHERE id=1 AND setup_consumed_at IS NULL AND bootstrap_token_hash=$2",
            )
            .bind(now)
            .bind(token_hash)
            .execute(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
            if consumed.rows_affected() != 1 {
                return Err(ApiError::unauthorized());
            }
        }

        // Match the SQLite flow: avoid expensive password hashing until the
        // one-time bootstrap/invitation credential has been checked while
        // holding the instance lock.
        let (verifier_hash, verifier_salt) = auth::password_hash(input.login_verifier)?;

        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES($1,$2,$3)")
            .bind(input.account_id)
            .bind(input.username)
            .bind(now)
            .execute(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO auth_credentials( \
                 user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope \
             ) VALUES($1,$2,$3,$4,$5)",
        )
        .bind(input.account_id)
        .bind(verifier_hash)
        .bind(verifier_salt)
        .bind(input.kdf_json)
        .bind(input.account_key_envelope)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO devices( \
                 device_id,user_id,name,signing_public_key,encryption_public_key,created_at \
             ) VALUES($1,$2,$3,$4,$5,$6)",
        )
        .bind(&input.device.device_id)
        .bind(input.account_id)
        .bind(&input.device.name)
        .bind(&input.device.signing_public_key)
        .bind(&input.device.encryption_public_key)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(|_| {
            ApiError::conflict("DEVICE_EXISTS", "device identifier is already registered")
        })?;

        let name_envelope: Value =
            serde_json::from_str(input.vault_name).map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO vaults( \
                 vault_id,owner_user_id,name_envelope,active_epoch,membership_version,created_at \
             ) VALUES($1,$2,$3::jsonb,1,1,$4)",
        )
        .bind(vault_id)
        .bind(input.account_id)
        .bind(serde_json::to_string(&name_envelope).map_err(ApiError::internal)?)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,added_at) \
             VALUES($1,$2,'owner',$3)",
        )
        .bind(vault_id)
        .bind(input.account_id)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES($1,0)")
            .bind(vault_id)
            .execute(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;

        let key = &input.initial_vault.key_envelope;
        let key_envelope_json = serde_json::to_string(&key.envelope).map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO vault_key_envelopes( \
                 vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                 envelope_signature,signer_device_id,membership_version \
             ) VALUES($1,1,$2,$3,$4::jsonb,$5,$6,1)",
        )
        .bind(vault_id)
        .bind(input.account_id)
        .bind(&key.recipient_device_id)
        .bind(key_envelope_json)
        .bind(&key.signature)
        .bind(&input.device.device_id)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;

        sqlx::query(
            "INSERT INTO membership_manifests( \
                 vault_id,membership_version,previous_digest,manifest_json,digest, \
                 signer_device_id,signature,created_at \
             ) VALUES($1,1,NULL,$2::jsonb,$3,$4,$5,$6)",
        )
        .bind(vault_id)
        .bind(input.manifest_json)
        .bind(input.manifest_digest)
        .bind(&input.device.device_id)
        .bind(&input.initial_vault.membership.signature)
        .bind(now)
        .execute(&mut *transaction)
        .await
        .map_err(ApiError::internal)?;

        let session = insert_session(
            &mut transaction,
            input.account_id,
            &input.device.device_id,
            now,
        )
        .await?;
        if let Some(invitation_id) = invitation_id {
            let consumed = sqlx::query(
                "UPDATE account_invitations SET consumed_at=clock_timestamp(),consumed_user_id=$1 \
                 WHERE invitation_id=$2 AND username=$3 AND consumed_at IS NULL \
                   AND revoked_at IS NULL AND expires_at>clock_timestamp()",
            )
            .bind(input.account_id)
            .bind(invitation_id)
            .bind(input.username)
            .execute(&mut *transaction)
            .await
            .map_err(ApiError::internal)?;
            if consumed.rows_affected() != 1 {
                return Err(account_invitation_invalid());
            }
        }

        self.record_account_created(
            &mut transaction,
            input.account_id,
            &input.device.device_id,
            now.timestamp(),
        )
        .await?;
        self.record_vault_created(
            &mut transaction,
            vault_id,
            input.account_id,
            &input.device.device_id,
            now.timestamp(),
        )
        .await?;
        transaction.commit().await.map_err(ApiError::internal)?;

        Ok(PgRegisteredSession {
            account_id: input.account_id.to_owned(),
            device_id: input.device.device_id.clone(),
            access_token: session.access_token,
            expires_in: session.expires_in,
            refresh_token: session.refresh_token,
            vault_id: vault_id.clone(),
        })
    }

    async fn record_instance_event(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        action: &str,
        resource_type: &str,
        resource_id: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::instance_scope_id(&self.audit_scope_key, &self.instance_id)?;
        let resource_id =
            crate::audit::instance_resource_id(&self.audit_scope_key, resource_type, resource_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('instance',$1,NULL,NULL,$2,$3,$4,'success',$5,'maintenance')",
        )
        .bind(scope_id)
        .bind(action)
        .bind(resource_type)
        .bind(resource_id)
        .bind(occurred_at)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn record_account_created(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        account_id: &str,
        device_id: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, account_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'account.created','account',$2,'success',$4,'api')",
        )
        .bind(scope_id)
        .bind(account_id)
        .bind(device_id)
        .bind(occurred_at)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }

    async fn record_vault_created(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        vault_id: &str,
        account_id: &str,
        device_id: &str,
        occurred_at: i64,
    ) -> Result<(), ApiError> {
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('vault',$1,$2,$3,'vault.created','vault',$1,'success',$4,'api')",
        )
        .bind(vault_id)
        .bind(account_id)
        .bind(device_id)
        .bind(occurred_at)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }
}

struct IssuedSession {
    access_token: String,
    expires_in: i64,
    refresh_token: String,
}

async fn lock_instance_meta(
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<sqlx::postgres::PgRow, ApiError> {
    sqlx::query(
        "SELECT bootstrap_token_hash,setup_consumed_at FROM instance_meta WHERE id=1 FOR UPDATE",
    )
    .fetch_optional(&mut **transaction)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("PostgreSQL instance metadata is missing"))
}

async fn insert_session(
    transaction: &mut Transaction<'_, Postgres>,
    account_id: &str,
    device_id: &str,
    now: chrono::DateTime<Utc>,
) -> Result<IssuedSession, ApiError> {
    let session_id = Uuid::new_v4().to_string();
    let family_id = Uuid::new_v4().to_string();
    let access_token = auth::random_token();
    let refresh_token = auth::random_token();
    let access_expires_at = now + Duration::seconds(ACCESS_TTL_SECONDS);
    let refresh_expires_at = now + Duration::days(REFRESH_TTL_DAYS);
    sqlx::query(
        "INSERT INTO sessions( \
             session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
             access_expires_at,refresh_expires_at,created_at \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)",
    )
    .bind(session_id)
    .bind(account_id)
    .bind(device_id)
    .bind(family_id)
    .bind(crate::sha256_hex(access_token.as_bytes()))
    .bind(crate::sha256_hex(refresh_token.as_bytes()))
    .bind(access_expires_at)
    .bind(refresh_expires_at)
    .bind(now)
    .execute(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    Ok(IssuedSession {
        access_token,
        expires_in: ACCESS_TTL_SECONDS,
        refresh_token,
    })
}

fn account_invitation_invalid() -> ApiError {
    ApiError::new(
        axum::http::StatusCode::UNAUTHORIZED,
        "ACCOUNT_INVITATION_INVALID",
        "account invitation is invalid",
    )
}

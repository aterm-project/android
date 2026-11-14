//! PostgreSQL implementation of the client-encrypted account Recovery API.
//!
//! The recovery secret, recovery codes, and decrypted Vault keys remain on the
//! client. PostgreSQL stores public verification keys, opaque envelopes,
//! challenge hashes, and response-loss receipts shared by every node.

use std::net::SocketAddr;

use axum::http::StatusCode;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{
    ApiError, AppState,
    auth::{self, AuthUser},
    pg_notifications::notify_sync_wake,
    pg_recovery_context as context,
    recovery::{
        self, CompleteRequest, ConfigureRequest, DisableRequest, InspectRequest,
        RecoveryKeyEnvelope, StartRequest, UploadRequest,
    },
};

const COMPLETE_TTL_SECONDS: i64 = 5 * 60;
const CHALLENGE_PRUNE_BATCH_SIZE: i64 = 500;
const CHALLENGE_PRUNE_BATCHES_PER_PASS: usize = 4;
const MAX_ACTIVE_DEVICES: i64 = auth::MAX_ACTIVE_DEVICES_PER_ACCOUNT;
// One shared transaction advisory lock protects the global active challenge
// cap across independent PostgreSQL pools and nodes.
const CHALLENGE_CAP_LOCK: i64 = 0x4154_4552_4d49_5553;

#[derive(Clone)]
pub(crate) struct PgAccountRecoveryRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
    max_active_challenges: i64,
}

impl PgAccountRecoveryRepository {
    pub(crate) fn new(pool: PgPool, audit_scope_key: [u8; 32], max_active_challenges: i64) -> Self {
        Self {
            pool,
            audit_scope_key,
            max_active_challenges,
        }
    }

    pub(crate) async fn username_for_user(&self, user_id: &str) -> Result<String, ApiError> {
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1 AND status='active'")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)
    }

    pub(crate) async fn profile_status(
        &self,
        _state: &AppState,
        user_id: &str,
    ) -> Result<&'static str, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        set_repeatable_read(&mut tx).await?;
        let Some(descriptor) = context::descriptor(&mut tx, user_id).await? else {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok("disabled");
        };
        let required = context::required_contexts(&mut tx, user_id).await?;
        let last = context::last_generation(&mut tx, user_id).await?;
        if descriptor.generation != last {
            return Err(ApiError::internal(
                "Recovery descriptor and generation counter are inconsistent",
            ));
        }
        let present = context::present_contexts(&mut tx, user_id, descriptor.generation).await?;
        let result = recovery::status(&required, &present, true);
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(result)
    }

    pub(crate) async fn contexts(
        &self,
        state: &AppState,
        user: &AuthUser,
    ) -> Result<Value, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;
        lock_user_vaults_and_memberships(&mut tx, &user.user_id).await?;
        let descriptor = context::descriptor(&mut tx, &user.user_id).await?;
        let last_generation = context::last_generation(&mut tx, &user.user_id).await?;
        let required = context::required_contexts(&mut tx, &user.user_id).await?;
        let (generation, identity, signing, encryption, descriptor_hash, present, recovery_status) =
            if let Some(descriptor) = descriptor {
                if descriptor.generation != last_generation {
                    return Err(ApiError::internal(
                        "Recovery descriptor and generation counter are inconsistent",
                    ));
                }
                let present =
                    context::present_contexts(&mut tx, &user.user_id, descriptor.generation)
                        .await?;
                let status = recovery::status(&required, &present, true);
                let hash = recovery::descriptor_hash_current(state, &user.user_id, &descriptor)?;
                (
                    descriptor.generation,
                    Some(recovery::json_from_db(
                        &descriptor.identity_envelope,
                        "identity envelope",
                    )),
                    Some(descriptor.public_signing_key),
                    Some(descriptor.public_encryption_key),
                    Some(hash),
                    present,
                    status,
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
        Ok(json!({
            "recovery_generation":generation,
            "recovery_identity_envelope":identity,
            "recovery_public_signing_key":signing,
            "recovery_public_encryption_key":encryption,
            "recovery_descriptor_hash":descriptor_hash,
            "required_contexts":required,
            "present_contexts":present,
            "recovery_status":recovery_status,
            "key_envelopes":present,
        }))
    }

    pub(crate) async fn configure(
        &self,
        state: &AppState,
        user: &AuthUser,
        peer: SocketAddr,
        request: ConfigureRequest,
    ) -> Result<Value, ApiError> {
        recovery::validate_operation_id(&request.operation_id)?;
        let username = auth::normalized_username(&self.username_for_user(&user.user_id).await?)?;
        self.charge(state, &username, OperationForRecovery::Login, peer)
            .await?;
        if request.key_envelopes.len() > recovery::MAX_KEY_ENVELOPES {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "too many Recovery key envelopes",
            ));
        }
        let digest =
            recovery::request_digest(state, &user.user_id, &request.operation_id, &request)?;
        let mut retry_tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut retry_tx, user).await?;
        if let Some(saved) =
            receipt(&mut retry_tx, &user.user_id, &request.operation_id, &digest).await?
        {
            retry_tx.commit().await.map_err(ApiError::internal)?;
            return Ok(recovery::retry_response(saved));
        }
        retry_tx.commit().await.map_err(ApiError::internal)?;

        let verifier_snapshot = self
            .verify_verifier(user, &request.current_login_verifier)
            .await?;
        if request.recovery_generation <= 0 {
            return Err(ApiError::bad_request(
                "INVALID_RECOVERY_GENERATION",
                "recovery_generation must be positive",
            ));
        }
        recovery::validate_public_keys(
            &request.recovery_public_signing_key,
            &request.recovery_public_encryption_key,
        )?;
        let recovery_envelope =
            recovery::validate_opaque_envelope(&request.recovery_envelope, "recovery envelope")?;
        let identity_envelope = recovery::validate_opaque_envelope(
            &request.recovery_identity_envelope,
            "recovery identity envelope",
        )?;
        auth::verify_key_signature(
            &request.recovery_public_signing_key,
            &request.recovery_identity_proof_signature,
            &recovery::recovery_identity_proof_payload(
                state,
                &user.user_id,
                request.recovery_generation,
                &request.recovery_public_signing_key,
                &request.recovery_public_encryption_key,
                &request.recovery_envelope,
                &request.recovery_identity_envelope,
            )?,
        )?;
        let submitted = recovery::verify_recovery_boxes(
            state,
            &user.user_id,
            request.recovery_generation,
            &request.recovery_public_signing_key,
            &request.recovery_public_encryption_key,
            &user.device_id,
            &request.key_envelopes,
        )?;
        let signer: String = sqlx::query_scalar("SELECT signing_public_key FROM devices WHERE user_id=$1 AND device_id=$2 AND status='active'")
            .bind(&user.user_id).bind(&user.device_id).fetch_optional(&self.pool).await.map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)?;
        auth::verify_key_signature(
            &signer,
            &request.proof_signature,
            &recovery::setup_device_payload(&request)?,
        )?;

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;
        if let Some(saved) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await?
        {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(recovery::retry_response(saved));
        }
        let current_verifier: String =
            sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1")
                .bind(&user.user_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if current_verifier != verifier_snapshot {
            return Err(ApiError::reauth_required());
        }
        let existing = context::descriptor(&mut tx, &user.user_id).await?;
        let last = context::last_generation(&mut tx, &user.user_id).await?;
        if existing
            .as_ref()
            .is_some_and(|descriptor| descriptor.generation != last)
        {
            return Err(ApiError::internal(
                "Recovery descriptor and generation counter are inconsistent",
            ));
        }
        let next_generation = last
            .checked_add(1)
            .filter(|next| *next > 0)
            .unwrap_or(i64::MAX);
        if request.recovery_generation != next_generation {
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
            auth::verify_key_signature(
                &old.public_signing_key,
                signature,
                &recovery::rotation_old_payload(state, &user.user_id, old, &request)?,
            )?;
        } else if request.previous_recovery_signature.is_some() {
            return Err(ApiError::bad_request(
                "UNEXPECTED_RECOVERY_PROOF",
                "initial setup cannot include an old Recovery proof",
            ));
        }
        lock_user_vaults_and_memberships(&mut tx, &user.user_id).await?;
        let required = context::required_contexts(&mut tx, &user.user_id).await?;
        let required_pairs = recovery::context_pairs(&required);
        let submitted_pairs: std::collections::BTreeSet<_> = submitted.keys().cloned().collect();
        if !submitted_pairs.is_subset(&required_pairs) {
            return Err(ApiError::invalid_envelope(
                "Recovery key envelopes contain a context outside the active Vault set",
            ));
        }
        let existing_present = if let Some(old) = &existing {
            context::present_contexts(&mut tx, &user.user_id, old.generation).await?
        } else {
            Vec::new()
        };
        let previous_pairs: std::collections::BTreeSet<_> = existing_present
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
            if !previous_pairs.contains(pair)
                && !context::context_holding_device(
                    &mut tx,
                    &user.user_id,
                    &user.device_id,
                    &pair.0,
                    pair.1,
                )
                .await?
            {
                return Err(ApiError::invalid_envelope(
                    "setup may only include Vault keys held by this device or preserved from the prior recovery set",
                ));
            }
        }
        let now = Utc::now().timestamp();
        sqlx::query("INSERT INTO account_recovery(user_id,recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope,created_at,updated_at) VALUES($1,$2,$3,$4,$5,$6,$7,$7) ON CONFLICT(user_id) DO UPDATE SET recovery_generation=EXCLUDED.recovery_generation,recovery_public_signing_key=EXCLUDED.recovery_public_signing_key,recovery_public_encryption_key=EXCLUDED.recovery_public_encryption_key,recovery_envelope=EXCLUDED.recovery_envelope,recovery_identity_envelope=EXCLUDED.recovery_identity_envelope,updated_at=EXCLUDED.updated_at")
            .bind(&user.user_id).bind(request.recovery_generation).bind(&request.recovery_public_signing_key).bind(&request.recovery_public_encryption_key).bind(recovery_envelope).bind(identity_envelope).bind(now)
            .execute(&mut *tx).await.map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_recovery_challenges WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        save_recovery_boxes(
            &mut tx,
            &user.user_id,
            request.recovery_generation,
            &request.key_envelopes,
            now,
        )
        .await?;
        context::save_generation(&mut tx, &user.user_id, request.recovery_generation).await?;
        let present =
            context::present_contexts(&mut tx, &user.user_id, request.recovery_generation).await?;
        let response = recovery::configure_response(
            request.recovery_generation,
            recovery::status(&required, &present, true),
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
        record_account_event(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            if existing.is_some() {
                "auth.account_recovery_rotated"
            } else {
                "auth.account_recovery_enabled"
            },
            "account_recovery",
            Some(&user.user_id),
            now,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    pub(crate) async fn disable(
        &self,
        state: &AppState,
        user: &AuthUser,
        peer: SocketAddr,
        request: DisableRequest,
    ) -> Result<Value, ApiError> {
        recovery::validate_operation_id(&request.operation_id)?;
        let username = self.username_for_user(&user.user_id).await?;
        self.charge(state, &username, OperationForRecovery::Login, peer)
            .await?;
        let digest =
            recovery::request_digest(state, &user.user_id, &request.operation_id, &request)?;
        let mut retry_tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut retry_tx, user).await?;
        if let Some(saved) =
            receipt(&mut retry_tx, &user.user_id, &request.operation_id, &digest).await?
        {
            retry_tx.commit().await.map_err(ApiError::internal)?;
            return Ok(recovery::retry_response(saved));
        }
        retry_tx.commit().await.map_err(ApiError::internal)?;
        let verifier_snapshot = self
            .verify_verifier(user, &request.current_login_verifier)
            .await?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;
        if let Some(saved) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await?
        {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(recovery::retry_response(saved));
        }
        let current: String =
            sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1")
                .bind(&user.user_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if current != verifier_snapshot {
            return Err(ApiError::reauth_required());
        }
        sqlx::query("DELETE FROM account_recovery WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_recovery_challenges WHERE user_id=$1")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let response = json!({"status":"disabled","operation_id":request.operation_id,"already_applied":false});
        save_receipt(
            &mut tx,
            &user.user_id,
            &request.operation_id,
            &digest,
            &response,
        )
        .await?;
        record_account_event(
            &mut tx,
            &self.audit_scope_key,
            &user.user_id,
            Some(&user.device_id),
            "auth.account_recovery_disabled",
            "account_recovery",
            Some(&user.user_id),
            Utc::now().timestamp(),
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    pub(crate) async fn upload_key_envelopes(
        &self,
        state: &AppState,
        user: &AuthUser,
        request: UploadRequest,
    ) -> Result<Value, ApiError> {
        recovery::validate_operation_id(&request.operation_id)?;
        if request.recovery_generation <= 0
            || request.key_envelopes.len() > recovery::MAX_KEY_ENVELOPES
        {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "Recovery key envelope request is invalid",
            ));
        }
        let digest =
            recovery::request_digest(state, &user.user_id, &request.operation_id, &request)?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;
        if let Some(saved) = receipt(&mut tx, &user.user_id, &request.operation_id, &digest).await?
        {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(recovery::retry_response(saved));
        }
        let descriptor = context::descriptor(&mut tx, &user.user_id)
            .await?
            .ok_or_else(|| {
                ApiError::conflict(
                    "RECOVERY_DISABLED",
                    "online account recovery is not configured",
                )
            })?;
        if descriptor.generation != request.recovery_generation {
            return Err(recovery::stale_recovery());
        }
        let expected = recovery::descriptor_hash_current(state, &user.user_id, &descriptor)?;
        if request.recovery_descriptor_hash != expected {
            return Err(recovery::stale_recovery());
        }
        let boxes = recovery::verify_recovery_boxes(
            state,
            &user.user_id,
            descriptor.generation,
            &descriptor.public_signing_key,
            &descriptor.public_encryption_key,
            &user.device_id,
            &request.key_envelopes,
        )?;
        lock_user_vaults_and_memberships(&mut tx, &user.user_id).await?;
        let required = context::required_contexts(&mut tx, &user.user_id).await?;
        let required_pairs = recovery::context_pairs(&required);
        for (vault_id, epoch) in boxes.keys() {
            if !required_pairs.contains(&(vault_id.clone(), *epoch)) {
                return Err(recovery::stale_recovery());
            }
            if !context::context_holding_device(
                &mut tx,
                &user.user_id,
                &user.device_id,
                vault_id,
                *epoch,
            )
            .await?
            {
                return Err(ApiError::forbidden(
                    "VAULT_KEY_UNAVAILABLE",
                    "the current device does not hold this Vault key context",
                ));
            }
        }
        let now = Utc::now().timestamp();
        let mut inserted = 0usize;
        for entry in &request.key_envelopes {
            let existing: Option<(String,String,String)> = sqlx::query_as("SELECT envelope,recovery_signature,uploader_device_id FROM account_recovery_key_envelopes WHERE user_id=$1 AND recovery_generation=$2 AND vault_id=$3 AND key_epoch=$4 FOR UPDATE")
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
            insert_recovery_box(&mut tx, &user.user_id, descriptor.generation, entry, now).await?;
            inserted += 1;
        }
        let present =
            context::present_contexts(&mut tx, &user.user_id, descriptor.generation).await?;
        let response = json!({"status":"updated","operation_id":request.operation_id,"recovery_generation":descriptor.generation,"recovery_status":recovery::status(&required,&present,true),"inserted_count":inserted,"already_applied":false});
        save_receipt(
            &mut tx,
            &user.user_id,
            &request.operation_id,
            &digest,
            &response,
        )
        .await?;
        if inserted > 0 {
            record_account_event(
                &mut tx,
                &self.audit_scope_key,
                &user.user_id,
                Some(&user.device_id),
                "auth.account_recovery_key_envelopes_updated",
                "account_recovery",
                Some(&user.user_id),
                now,
            )
            .await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }

    pub(crate) async fn start(
        &self,
        state: &AppState,
        peer: SocketAddr,
        request: StartRequest,
    ) -> Result<Value, ApiError> {
        let username = auth::normalized_username(&request.username)?;
        self.charge(state, &username, OperationForRecovery::RecoveryStart, peer)
            .await?;
        let row = sqlx::query("SELECT u.user_id,r.recovery_generation,r.recovery_public_signing_key,r.recovery_public_encryption_key,r.recovery_envelope FROM users u JOIN account_recovery r ON r.user_id=u.user_id WHERE u.username=$1 AND u.status='active'")
            .bind(&username).fetch_optional(&self.pool).await.map_err(ApiError::internal)?;
        let challenge_id = Uuid::new_v4().to_string();
        let mut challenge_bytes = [0u8; 32];
        rand::thread_rng().fill_bytes(&mut challenge_bytes);
        let challenge = URL_SAFE_NO_PAD.encode(challenge_bytes);
        let challenge_id_hash = crate::sha256_hex(challenge_id.as_bytes());
        let challenge_hash = crate::sha256_hex(&challenge_bytes);
        let decoy = recovery::decoy_start_material(state, &username)?;
        let (mut bound_user_id, mut generation, mut response) = if let Some(row) = row {
            let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
            let generation: i64 = row
                .try_get("recovery_generation")
                .map_err(ApiError::internal)?;
            let signing: String = row
                .try_get("recovery_public_signing_key")
                .map_err(ApiError::internal)?;
            let encryption: String = row
                .try_get("recovery_public_encryption_key")
                .map_err(ApiError::internal)?;
            let envelope: String = row
                .try_get("recovery_envelope")
                .map_err(ApiError::internal)?;
            let response = recovery::StartResponse {
                account_id: user_id.clone(),
                instance_id: state.instance.instance_id.clone(),
                server_space_id: state.instance.server_space_id.clone(),
                recovery_generation: generation,
                challenge_id,
                challenge,
                expires_at: String::new(),
                recovery_public_signing_key: signing.clone(),
                recovery_public_encryption_key: encryption.clone(),
                recovery_descriptor_hash: recovery::descriptor_hash(
                    state,
                    &user_id,
                    generation,
                    &signing,
                    &encryption,
                )?,
                recovery_envelope: recovery::decode_or_dummy(envelope, &decoy.recovery_envelope)?,
            };
            (Some(user_id), generation, response)
        } else {
            let response = recovery::StartResponse {
                account_id: decoy.account_id.clone(),
                instance_id: state.instance.instance_id.clone(),
                server_space_id: state.instance.server_space_id.clone(),
                recovery_generation: 1,
                challenge_id,
                challenge,
                expires_at: String::new(),
                recovery_public_signing_key: decoy.recovery_public_signing_key.clone(),
                recovery_public_encryption_key: decoy.recovery_public_encryption_key.clone(),
                recovery_descriptor_hash: decoy.recovery_descriptor_hash.clone(),
                recovery_envelope: decoy.recovery_envelope.clone(),
            };
            (None, 1, response)
        };
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query("SELECT pg_advisory_xact_lock($1)")
            .bind(CHALLENGE_CAP_LOCK)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if let Some(user_id) = bound_user_id.as_deref() {
            // Serialize anonymous challenge creation with descriptor disable or
            // rotation. If the descriptor changed after the initial response
            // lookup, return an indistinguishable decoy and store an unbound
            // challenge instead of reviving the stale generation.
            let current_generation: Option<i64> = sqlx::query_scalar(
                "SELECT recovery_generation FROM account_recovery WHERE user_id=$1 FOR SHARE",
            )
            .bind(user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if current_generation != Some(generation) {
                bound_user_id = None;
                generation = 1;
                response.account_id = decoy.account_id.clone();
                response.recovery_generation = generation;
                response.recovery_public_signing_key = decoy.recovery_public_signing_key.clone();
                response.recovery_public_encryption_key =
                    decoy.recovery_public_encryption_key.clone();
                response.recovery_descriptor_hash = decoy.recovery_descriptor_hash.clone();
                response.recovery_envelope = decoy.recovery_envelope.clone();
            }
        }
        prune_challenges_tx(&mut tx, Utc::now().timestamp(), 1).await?;
        let now = Utc::now().timestamp();
        let (count, earliest): (i64, Option<i64>) = sqlx::query_as("SELECT COUNT(*),MIN(expires_at) FROM account_recovery_challenges WHERE expires_at>$1 AND consumed_at IS NULL").bind(now).fetch_one(&mut *tx).await.map_err(ApiError::internal)?;
        if count >= self.max_active_challenges {
            let retry = earliest
                .unwrap_or(now.saturating_add(COMPLETE_TTL_SECONDS))
                .saturating_sub(now)
                .max(1) as u64;
            tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::rate_limited(retry));
        }
        let expires = now.saturating_add(COMPLETE_TTL_SECONDS);
        response.expires_at = DateTime::<Utc>::from_timestamp(expires, 0)
            .ok_or_else(|| ApiError::internal("challenge expiry is invalid"))?
            .to_rfc3339();
        sqlx::query("INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES($1,$2,$3,$4,$5)")
            .bind(challenge_id_hash).bind(challenge_hash).bind(bound_user_id).bind(generation).bind(expires).execute(&mut *tx).await.map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        serde_json::to_value(response).map_err(ApiError::internal)
    }

    pub(crate) async fn inspect(
        &self,
        state: &AppState,
        peer: SocketAddr,
        request: InspectRequest,
    ) -> Result<Value, ApiError> {
        let challenge = recovery::decode_b64(&request.challenge, Some(32))
            .map_err(|_| recovery::failed_recovery())?;
        if !crate::is_canonical_uuid(&request.account_id)
            || !crate::is_canonical_uuid(&request.challenge_id)
            || request.instance_id != state.instance.instance_id
            || request.server_space_id != state.instance.server_space_id
        {
            return Err(recovery::failed_recovery());
        }
        let subject =
            sqlx::query_scalar::<_, String>("SELECT username FROM users WHERE user_id=$1")
                .bind(&request.account_id)
                .fetch_optional(&self.pool)
                .await
                .map_err(ApiError::internal)?
                .unwrap_or_else(|| format!("unknown:{}", request.account_id));
        self.charge(state, &subject, OperationForRecovery::RecoveryStart, peer)
            .await?;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        set_repeatable_read(&mut tx).await?;
        let descriptor = context::descriptor(&mut tx, &request.account_id)
            .await
            .map_err(|_| recovery::failed_recovery())?
            .ok_or_else(recovery::failed_recovery)?;
        if descriptor.generation != request.recovery_generation {
            return Err(recovery::failed_recovery());
        }
        let descriptor_hash =
            recovery::descriptor_hash_current(state, &request.account_id, &descriptor)?;
        let payload = json!({"protocol":recovery::INSPECT_PROTOCOL,"account_id":request.account_id,"instance_id":request.instance_id,"server_space_id":request.server_space_id,"recovery_generation":request.recovery_generation,"challenge_id":request.challenge_id,"challenge":request.challenge,"recovery_descriptor_hash":descriptor_hash});
        auth::verify_key_signature(
            &descriptor.public_signing_key,
            &request.recovery_signature,
            &crate::jcs(&payload)?,
        )
        .map_err(|_| recovery::failed_recovery())?;
        valid_challenge(
            &mut tx,
            &request.account_id,
            descriptor.generation,
            &request.challenge_id,
            &challenge,
        )
        .await?;
        let required = context::required_contexts(&mut tx, &request.account_id).await?;
        let present =
            context::present_contexts(&mut tx, &request.account_id, descriptor.generation).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(
            json!({"account_id":request.account_id,"recovery_generation":descriptor.generation,"recovery_descriptor_hash":descriptor_hash,"required_contexts":required,"present_contexts":present,"recovery_status":recovery::status(&required,&present,true)}),
        )
    }

    pub(crate) async fn complete(
        &self,
        state: AppState,
        peer: SocketAddr,
        request: CompleteRequest,
    ) -> Result<Value, ApiError> {
        complete_inner(self, state, peer, request).await
    }

    async fn charge(
        &self,
        state: &AppState,
        username: &str,
        operation: OperationForRecovery,
        peer: SocketAddr,
    ) -> Result<(), ApiError> {
        let operation = match operation {
            OperationForRecovery::Login => crate::rate_limit::AuthOperation::Login,
            OperationForRecovery::RecoveryStart => crate::rate_limit::AuthOperation::RecoveryStart,
            OperationForRecovery::RecoveryComplete => {
                crate::rate_limit::AuthOperation::RecoveryComplete
            }
        };
        if let Some(seconds) =
            auth::consume_auth_rate_limit(state, operation, username, Some(peer.ip())).await?
        {
            return Err(ApiError::rate_limited(seconds));
        }
        Ok(())
    }

    async fn verify_verifier(&self, user: &AuthUser, verifier: &str) -> Result<String, ApiError> {
        let encoded: Option<String> = sqlx::query_scalar("SELECT c.login_verifier_hash FROM auth_credentials c JOIN users u ON u.user_id=c.user_id WHERE c.user_id=$1 AND u.status='active'").bind(&user.user_id).fetch_optional(&self.pool).await.map_err(ApiError::internal)?;
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

    pub(crate) async fn prune_challenges(&self, now: i64) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        prune_challenges_tx(&mut tx, now, CHALLENGE_PRUNE_BATCHES_PER_PASS).await?;
        tx.commit().await.map_err(ApiError::internal)
    }
}

pub(crate) fn from_state(state: &AppState) -> Option<PgAccountRecoveryRepository> {
    state.pg_sync_pool.as_ref().map(|pool| {
        PgAccountRecoveryRepository::new(
            pool.clone(),
            *state.cursor_key,
            state.config.auth_rate_limits.max_active_recovery_challenges,
        )
    })
}

#[derive(Clone, Copy)]
enum OperationForRecovery {
    Login,
    RecoveryStart,
    RecoveryComplete,
}

async fn lock_active_principal(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let sessions = sqlx::query(
        "SELECT session_id,device_id,access_hash,access_expires_at,revoked_at \
         FROM sessions WHERE user_id=$1 ORDER BY session_id FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let now = Utc::now();
    let current_session = sessions.iter().find(|row| {
        row.try_get::<String, _>("session_id").ok().as_deref() == Some(&user.session_id)
    });
    let Some(session) = current_session else {
        return Err(ApiError::unauthorized());
    };
    let access_hash: String = session.try_get("access_hash").map_err(ApiError::internal)?;
    let device_id: String = session.try_get("device_id").map_err(ApiError::internal)?;
    let expires_at: DateTime<Utc> = session
        .try_get("access_expires_at")
        .map_err(ApiError::internal)?;
    let revoked_at: Option<DateTime<Utc>> =
        session.try_get("revoked_at").map_err(ApiError::internal)?;
    if access_hash != user.access_hash
        || device_id != user.device_id
        || revoked_at.is_some()
        || expires_at <= now
    {
        return Err(ApiError::unauthorized());
    }

    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let credential: Option<String> = sqlx::query_scalar(
        "SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1 FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if credential.is_none() {
        return Err(ApiError::unauthorized());
    }
    let devices = sqlx::query(
        "SELECT device_id,status FROM devices WHERE user_id=$1 ORDER BY device_id FOR UPDATE",
    )
    .bind(&user.user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let active = devices.iter().any(|row| {
        row.try_get::<String, _>("device_id").ok().as_deref() == Some(&user.device_id)
            && row.try_get::<String, _>("status").ok().as_deref() == Some("active")
    });
    if !active {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

async fn set_repeatable_read(tx: &mut Transaction<'_, Postgres>) -> Result<(), ApiError> {
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn lock_user_vaults_and_memberships(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "SELECT v.vault_id FROM vaults v \
         JOIN vault_members vm ON vm.vault_id=v.vault_id \
         WHERE vm.user_id=$1 AND vm.state='active' \
         ORDER BY v.vault_id FOR UPDATE OF v",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "SELECT vault_id FROM vault_members WHERE user_id=$1 AND state='active' \
         ORDER BY vault_id FOR UPDATE",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn receipt(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    operation_id: &str,
    digest: &str,
) -> Result<Option<Value>, ApiError> {
    let row = sqlx::query(
        "SELECT request_digest,response_json FROM account_recovery_receipts \
         WHERE user_id=$1 AND operation_id=$2 FOR UPDATE",
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
    let response: String = row.try_get("response_json").map_err(ApiError::internal)?;
    serde_json::from_str(&response)
        .map(Some)
        .map_err(ApiError::internal)
}

async fn save_receipt(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    operation_id: &str,
    digest: &str,
    response: &Value,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO account_recovery_receipts(user_id,operation_id,request_digest,response_json,created_at) VALUES($1,$2,$3,$4,$5)")
        .bind(user_id).bind(operation_id).bind(digest).bind(response.to_string()).bind(Utc::now().timestamp())
        .execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn save_recovery_boxes(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    generation: i64,
    boxes: &[RecoveryKeyEnvelope],
    now: i64,
) -> Result<(), ApiError> {
    for entry in boxes {
        insert_recovery_box(tx, user_id, generation, entry, now).await?;
    }
    Ok(())
}

async fn insert_recovery_box(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    generation: i64,
    entry: &RecoveryKeyEnvelope,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO account_recovery_key_envelopes(user_id,recovery_generation,vault_id,key_epoch,envelope,recovery_signature,uploader_device_id,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8)")
        .bind(user_id).bind(generation).bind(&entry.vault_id).bind(entry.key_epoch).bind(entry.envelope.to_string())
        .bind(&entry.recovery_signature).bind(&entry.uploader_device_id).bind(now)
        .execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn valid_challenge(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    generation: i64,
    challenge_id: &str,
    challenge: &[u8],
) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(challenge_id) {
        return Err(recovery::failed_recovery());
    }
    let id_hash = crate::sha256_hex(challenge_id.as_bytes());
    let challenge_hash = crate::sha256_hex(challenge);
    let row = sqlx::query("SELECT challenge_hash,user_id,recovery_generation,expires_at,consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=$1")
        .bind(id_hash).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?
        .ok_or_else(recovery::failed_recovery)?;
    let stored_hash: String = row.try_get("challenge_hash").map_err(ApiError::internal)?;
    let stored_user: Option<String> = row.try_get("user_id").map_err(ApiError::internal)?;
    let stored_generation: i64 = row
        .try_get("recovery_generation")
        .map_err(ApiError::internal)?;
    let expires_at: i64 = row.try_get("expires_at").map_err(ApiError::internal)?;
    let consumed_at: Option<i64> = row.try_get("consumed_at").map_err(ApiError::internal)?;
    if stored_hash != challenge_hash
        || stored_user.as_deref() != Some(user_id)
        || stored_generation != generation
        || expires_at <= Utc::now().timestamp()
        || consumed_at.is_some()
    {
        return Err(recovery::failed_recovery());
    }
    Ok(())
}

async fn prune_challenges_tx(
    tx: &mut Transaction<'_, Postgres>,
    now: i64,
    max_batches: usize,
) -> Result<(), ApiError> {
    for _ in 0..max_batches {
        let deleted = sqlx::query(
            "WITH candidates AS ( \
                SELECT challenge_id_hash FROM account_recovery_challenges \
                WHERE expires_at<=$1 OR consumed_at IS NOT NULL \
                ORDER BY expires_at,challenge_id_hash LIMIT $2 FOR UPDATE SKIP LOCKED \
             ) DELETE FROM account_recovery_challenges c USING candidates x \
               WHERE c.challenge_id_hash=x.challenge_id_hash",
        )
        .bind(now)
        .bind(CHALLENGE_PRUNE_BATCH_SIZE)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();
        if deleted < CHALLENGE_PRUNE_BATCH_SIZE as u64 {
            break;
        }
    }
    Ok(())
}

async fn record_account_event(
    tx: &mut Transaction<'_, Postgres>,
    audit_scope_key: &[u8; 32],
    user_id: &str,
    device_id: Option<&str>,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
    occurred_at: i64,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::account_scope_id(audit_scope_key, user_id)?;
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('account',$1,$2,$3,$4,$5,$6,'success',$7,'api')")
        .bind(scope_id).bind(user_id).bind(device_id).bind(action).bind(resource_type).bind(resource_id).bind(occurred_at)
        .execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn complete_inner(
    repository: &PgAccountRecoveryRepository,
    state: AppState,
    peer: SocketAddr,
    request: CompleteRequest,
) -> Result<Value, ApiError> {
    recovery::validate_operation_id(&request.operation_id)
        .map_err(|_| recovery::failed_recovery())?;
    if !crate::is_canonical_uuid(&request.account_id) {
        return Err(recovery::failed_recovery());
    }
    let username: Option<String> =
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1")
            .bind(&request.account_id)
            .fetch_optional(&repository.pool)
            .await
            .map_err(ApiError::internal)?;
    let rate_subject = username.unwrap_or_else(|| format!("unknown:{}", request.account_id));
    repository
        .charge(
            &state,
            &rate_subject,
            OperationForRecovery::RecoveryComplete,
            peer,
        )
        .await?;
    let digest =
        recovery::request_digest(&state, &request.account_id, &request.operation_id, &request)?;

    // A completed response-loss retry remains valid after the original
    // challenge was consumed and every old session/device was revoked.
    let mut receipt_tx = repository.pool.begin().await.map_err(ApiError::internal)?;
    if let Some(saved) = receipt(
        &mut receipt_tx,
        &request.account_id,
        &request.operation_id,
        &digest,
    )
    .await?
    {
        receipt_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(recovery::retry_response(saved));
    }
    receipt_tx.commit().await.map_err(ApiError::internal)?;

    let challenge = recovery::decode_b64(&request.challenge, Some(32))
        .map_err(|_| recovery::failed_recovery())?;
    if request.instance_id != state.instance.instance_id
        || request.server_space_id != state.instance.server_space_id
        || !crate::is_canonical_uuid(&request.challenge_id)
    {
        return Err(recovery::failed_recovery());
    }

    // Verify all client proofs and do password KDF work before taking the
    // account lifecycle locks. The complete signed context is rechecked in
    // the final transaction before any state change is committed.
    let mut verify_tx = repository.pool.begin().await.map_err(ApiError::internal)?;
    set_repeatable_read(&mut verify_tx).await?;
    let recovery_descriptor = context::descriptor(&mut verify_tx, &request.account_id)
        .await
        .map_err(|_| recovery::failed_recovery())?
        .ok_or_else(recovery::failed_recovery)?;
    if recovery_descriptor.generation != request.recovery_generation {
        return Err(recovery::failed_recovery());
    }
    auth::verify_key_signature(
        &recovery_descriptor.public_signing_key,
        &request.recovery_signature,
        &recovery::complete_payload(&request)?,
    )
    .map_err(|_| recovery::failed_recovery())?;
    valid_challenge(
        &mut verify_tx,
        &request.account_id,
        recovery_descriptor.generation,
        &request.challenge_id,
        &challenge,
    )
    .await?;
    let context_snapshot = context::required_contexts(&mut verify_tx, &request.account_id).await?;
    let required = recovery::canonical_completion_contexts(&context_snapshot);
    recovery::completion_vault_envelope_set(&request, &required)?;
    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1")
            .bind(&request.account_id)
            .fetch_optional(&mut *verify_tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(recovery::failed_recovery());
    }
    recovery::verify_completion_device(&request.device, &request.account_id)?;
    auth::validate_kdf(&request.new_kdf).map_err(|_| recovery::failed_recovery())?;
    let (new_verifier_hash, new_verifier_salt) = auth::password_hash(&request.new_login_verifier)
        .map_err(|_| recovery::failed_recovery())?;
    let new_account_key_envelope =
        auth::ensure_rewrapped_account_envelope(&request.account_key_envelope)
            .map_err(|_| recovery::failed_recovery())?;
    let new_generation = request
        .recovery_generation
        .checked_add(1)
        .ok_or_else(recovery::failed_recovery)?;
    recovery::validate_public_keys(
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
    )
    .map_err(|_| recovery::failed_recovery())?;
    let next_recovery_envelope = recovery::validate_opaque_envelope(
        &request.next_recovery.recovery_envelope,
        "next recovery envelope",
    )
    .map_err(|_| recovery::failed_recovery())?;
    let next_identity_envelope = recovery::validate_opaque_envelope(
        &request.next_recovery.recovery_identity_envelope,
        "next recovery identity envelope",
    )
    .map_err(|_| recovery::failed_recovery())?;
    let next_boxes = recovery::verify_recovery_boxes(
        &state,
        &request.account_id,
        new_generation,
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
        &request.device.device_id,
        &request.next_recovery.key_envelopes,
    )
    .map_err(|_| recovery::failed_recovery())?;
    let next_pairs: std::collections::BTreeSet<_> = next_boxes.keys().cloned().collect();
    if next_pairs != required.keys().cloned().collect() {
        return Err(recovery::stale_recovery());
    }
    let next_identity_payload = recovery::recovery_identity_proof_payload(
        &state,
        &request.account_id,
        new_generation,
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_public_encryption_key,
        &request.next_recovery.recovery_envelope,
        &request.next_recovery.recovery_identity_envelope,
    )
    .map_err(|_| recovery::failed_recovery())?;
    auth::verify_key_signature(
        &request.next_recovery.recovery_public_signing_key,
        &request.next_recovery.recovery_identity_proof_signature,
        &next_identity_payload,
    )
    .map_err(|_| recovery::failed_recovery())?;
    verify_tx.commit().await.map_err(ApiError::internal)?;

    let now = Utc::now().timestamp();
    let now_dt = DateTime::<Utc>::from_timestamp(now, 0)
        .ok_or_else(|| ApiError::internal("recovery timestamp is outside the supported range"))?;
    let kdf_json = serde_json::to_string(&json!({"id":request.new_kdf.id,"salt":request.new_kdf.salt,"mem_kib":request.new_kdf.mem_kib,"iterations":request.new_kdf.iterations,"parallelism":request.new_kdf.parallelism,"version":request.new_kdf.version})).map_err(ApiError::internal)?;
    let mut tx = repository.pool.begin().await.map_err(ApiError::internal)?;

    // Fence new login/refresh activity before locking the extant session set.
    // Login and refresh take the same account-scoped transaction lock before
    // creating or locking a session, so a newly issued session cannot appear
    // between this scan and the global revocation update.
    crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &request.account_id).await?;
    // Then use the lifecycle row order: all sessions, account, credential,
    // devices, Vaults, memberships.
    let sessions = sqlx::query(
        "SELECT session_id FROM sessions WHERE user_id=$1 ORDER BY session_id FOR UPDATE",
    )
    .bind(&request.account_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let _ = sessions;
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(&request.account_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if status.as_deref() != Some("active") {
        return Err(recovery::failed_recovery());
    }
    let credential: Option<(String,i64)> = sqlx::query_as("SELECT login_verifier_hash,credential_version FROM auth_credentials WHERE user_id=$1 FOR UPDATE")
        .bind(&request.account_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some((old_verifier_hash, credential_version)) = credential else {
        return Err(recovery::failed_recovery());
    };
    let devices = sqlx::query(
        "SELECT device_id,status FROM devices WHERE user_id=$1 ORDER BY device_id FOR UPDATE",
    )
    .bind(&request.account_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let _ = devices;
    lock_user_vaults_and_memberships(&mut tx, &request.account_id).await?;
    if let Some(saved) =
        receipt(&mut tx, &request.account_id, &request.operation_id, &digest).await?
    {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(recovery::retry_response(saved));
    }
    let current_descriptor = context::descriptor(&mut tx, &request.account_id)
        .await
        .map_err(|_| recovery::failed_recovery())?
        .ok_or_else(recovery::failed_recovery)?;
    if current_descriptor.generation != request.recovery_generation {
        return Err(recovery::failed_recovery());
    }
    if context::last_generation(&mut tx, &request.account_id)
        .await
        .map_err(|_| recovery::failed_recovery())?
        != request.recovery_generation
    {
        return Err(recovery::failed_recovery());
    }
    valid_challenge(
        &mut tx,
        &request.account_id,
        current_descriptor.generation,
        &request.challenge_id,
        &challenge,
    )
    .await?;
    auth::verify_key_signature(
        &current_descriptor.public_signing_key,
        &request.recovery_signature,
        &recovery::complete_payload(&request)?,
    )
    .map_err(|_| recovery::failed_recovery())?;
    let locked_contexts = context::required_contexts(&mut tx, &request.account_id).await?;
    let locked_required = recovery::canonical_completion_contexts(&locked_contexts);
    if locked_required != required {
        return Err(recovery::stale_recovery());
    }
    context::ensure_readable_source_key_envelopes(&mut tx, &request.account_id, &locked_required)
        .await?;
    let current_credential_hash: String =
        sqlx::query_scalar("SELECT login_verifier_hash FROM auth_credentials WHERE user_id=$1")
            .bind(&request.account_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current_credential_hash != old_verifier_hash {
        return Err(recovery::failed_recovery());
    }
    let new_credential_version = credential_version
        .checked_add(1)
        .ok_or_else(|| ApiError::internal("credential version overflow"))?;

    sqlx::query(
        "UPDATE devices SET status='revoked',revoked_at=$1 WHERE user_id=$2 AND status='active'",
    )
    .bind(now_dt)
    .bind(&request.account_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let active_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE user_id=$1 AND status='active'")
            .bind(&request.account_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if active_count >= MAX_ACTIVE_DEVICES {
        return Err(ApiError::conflict(
            "ACTIVE_DEVICE_LIMIT_REACHED",
            "account already has the maximum number of active devices",
        ));
    }
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status,created_at) VALUES($1,$2,$3,$4,$5,'active',$6)")
        .bind(&request.device.device_id).bind(&request.account_id).bind(&request.device.name)
        .bind(&request.device.signing_public_key).bind(&request.device.encryption_public_key).bind(now_dt)
        .execute(&mut *tx).await.map_err(|_|recovery::failed_recovery())?;
    for key in &request.vault_key_envelopes {
        sqlx::query("INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id,envelope,envelope_signature,signer_device_id,membership_version) VALUES($1,$2,$3,$4,$5::jsonb,$6,$4,$7)")
            .bind(&key.vault_id).bind(key.key_epoch).bind(&request.account_id).bind(&request.device.device_id)
            .bind(key.envelope.to_string()).bind(&key.signature).bind(key.membership_version)
            .execute(&mut *tx).await.map_err(|_|recovery::failed_recovery())?;
    }
    sqlx::query("UPDATE sessions SET revoked_at=$1 WHERE user_id=$2 AND revoked_at IS NULL")
        .bind(now_dt)
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("UPDATE auth_credentials SET login_verifier_hash=$1,verifier_salt=$2,kdf_json=$3,account_key_envelope=$4,credential_version=$5 WHERE user_id=$6")
        .bind(new_verifier_hash).bind(new_verifier_salt).bind(kdf_json).bind(new_account_key_envelope).bind(new_credential_version).bind(&request.account_id)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE account_recovery SET recovery_generation=$1,recovery_public_signing_key=$2,recovery_public_encryption_key=$3,recovery_envelope=$4,recovery_identity_envelope=$5,updated_at=$6 WHERE user_id=$7")
        .bind(new_generation).bind(&request.next_recovery.recovery_public_signing_key).bind(&request.next_recovery.recovery_public_encryption_key)
        .bind(next_recovery_envelope).bind(next_identity_envelope).bind(now).bind(&request.account_id)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    context::save_generation(&mut tx, &request.account_id, new_generation).await?;
    sqlx::query("DELETE FROM account_recovery_key_envelopes WHERE user_id=$1")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    save_recovery_boxes(
        &mut tx,
        &request.account_id,
        new_generation,
        &request.next_recovery.key_envelopes,
        now,
    )
    .await?;
    let challenge_id_hash = crate::sha256_hex(request.challenge_id.as_bytes());
    // Use a fresh timestamp at consumption; the request may have spent most
    // of its five-minute challenge lifetime waiting on lifecycle locks.
    let consumed_at = Utc::now().timestamp();
    let consumed = sqlx::query("UPDATE account_recovery_challenges SET consumed_at=$1 WHERE challenge_id_hash=$2 AND consumed_at IS NULL AND expires_at>$1")
        .bind(consumed_at).bind(challenge_id_hash).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if consumed.rows_affected() != 1 {
        return Err(recovery::failed_recovery());
    }
    let response = recovery::complete_response(&request, new_credential_version, false);
    save_receipt(
        &mut tx,
        &request.account_id,
        &request.operation_id,
        &digest,
        &response,
    )
    .await?;
    let enabled_mfa: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_mfa WHERE user_id=$1 AND enabled_at IS NOT NULL",
    )
    .bind(&request.account_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM auth_mfa WHERE user_id=$1")
        .bind(&request.account_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if enabled_mfa > 0 {
        record_account_event(
            &mut tx,
            &repository.audit_scope_key,
            &request.account_id,
            Some(&request.device.device_id),
            "auth.mfa_reset_by_recovery",
            "account",
            Some(&request.account_id),
            now,
        )
        .await?;
    }
    record_account_event(
        &mut tx,
        &repository.audit_scope_key,
        &request.account_id,
        Some(&request.device.device_id),
        "auth.account_recovered",
        "account",
        Some(&request.account_id),
        now,
    )
    .await?;
    notify_sync_wake(&mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(response)
}

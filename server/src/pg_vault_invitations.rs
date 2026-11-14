//! PostgreSQL device-addressed Vault invitations.
//!
//! Invitation issuance and acceptance share membership, key-envelope, token,
//! and audit state with all PostgreSQL service nodes. The Vault row is the
//! membership-version serialization point; the recipient account row is the
//! cross-Vault capacity serialization point.

use std::collections::{HashMap, HashSet};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use rand::RngCore;
use serde_json::{Value, json};
use sha2::Digest;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{ApiError, auth, control, pg_notifications::notify_sync_wake};

const MAX_MANIFEST_BYTES: usize = 256 * 1024;
const MAX_ATTACHMENT_BYTES: i64 = 1024 * 1024 * 1024;

#[derive(Clone)]
pub(crate) struct PgVaultInvitationRepository {
    pool: PgPool,
    max_vaults_per_user: i64,
    max_members_per_vault: i64,
}

#[derive(Clone)]
struct LockedDevice {
    user_id: String,
    signing_public_key: String,
    encryption_public_key: String,
    status: String,
}

impl PgVaultInvitationRepository {
    pub(crate) fn new(pool: PgPool, max_vaults_per_user: i64, max_members_per_vault: i64) -> Self {
        Self {
            pool,
            max_vaults_per_user,
            max_members_per_vault,
        }
    }

    pub(crate) async fn create_invitation(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        request: control::InvitationRequest,
    ) -> Result<Value, ApiError> {
        if !["editor", "viewer"].contains(&request.role.as_str()) {
            return Err(ApiError::bad_request(
                "INVALID_ROLE",
                "invitation role must be editor or viewer",
            ));
        }
        let lifetime = control::invitation_lifetime_seconds(request.expires_in_seconds)?;
        if !request.key_envelope.envelope.is_object() {
            return Err(ApiError::invalid_envelope(
                "invitation key envelope is invalid",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_session(&mut tx, user).await?;

        // Device ownership is immutable, so this unlocked lookup only obtains
        // the account ID needed for deterministic account-lock ordering. The
        // target device and account are rechecked under lock below.
        let recipient_user_id: String =
            sqlx::query_scalar("SELECT user_id FROM devices WHERE device_id=$1")
                .bind(&request.recipient_device_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
                .ok_or_else(ApiError::not_found)?;

        let mut account_ids = vec![user.user_id.clone(), recipient_user_id.clone()];
        account_ids.sort();
        account_ids.dedup();
        let mut account_statuses = HashMap::with_capacity(account_ids.len());
        for account_id in &account_ids {
            let status: Option<String> =
                sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                    .bind(account_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            account_statuses.insert(account_id.clone(), status);
        }
        if account_statuses
            .get(&user.user_id)
            .and_then(Option::as_deref)
            != Some("active")
        {
            return Err(ApiError::unauthorized());
        }
        if account_statuses
            .get(&recipient_user_id)
            .and_then(Option::as_deref)
            != Some("active")
        {
            return Err(ApiError::not_found());
        }

        let mut device_ids = vec![user.device_id.clone(), request.recipient_device_id.clone()];
        device_ids.sort();
        device_ids.dedup();
        let mut devices = HashMap::with_capacity(device_ids.len());
        for device_id in &device_ids {
            let row = sqlx::query(
                "SELECT user_id,signing_public_key,encryption_public_key,status \
                 FROM devices WHERE device_id=$1 FOR SHARE",
            )
            .bind(device_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(|| {
                if device_id == &user.device_id {
                    ApiError::forbidden("DEVICE_REVOKED", "device is not active")
                } else {
                    ApiError::not_found()
                }
            })?;
            let device = LockedDevice {
                user_id: row.try_get("user_id").map_err(ApiError::internal)?,
                signing_public_key: row
                    .try_get("signing_public_key")
                    .map_err(ApiError::internal)?,
                encryption_public_key: row
                    .try_get("encryption_public_key")
                    .map_err(ApiError::internal)?,
                status: row.try_get("status").map_err(ApiError::internal)?,
            };
            devices.insert(device_id.clone(), device);
        }
        let signer = devices
            .get(&user.device_id)
            .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
        if signer.user_id != user.user_id || signer.status != "active" {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }
        let recipient = devices
            .get(&request.recipient_device_id)
            .ok_or_else(ApiError::not_found)?;
        if recipient.user_id != recipient_user_id || recipient.status != "active" {
            return Err(ApiError::not_found());
        }
        if request.recipient_encryption_public_key != recipient.encryption_public_key {
            return Err(ApiError::invalid_envelope(
                "recipient encryption key does not match the registered device",
            ));
        }
        let recipient_key_bytes = URL_SAFE_NO_PAD
            .decode(&recipient.encryption_public_key)
            .map_err(|_| ApiError::internal("registered device encryption key is invalid"))?;
        if recipient_key_bytes.len() != 32 {
            return Err(ApiError::internal(
                "registered device encryption key has an invalid size",
            ));
        }
        let recipient_fingerprint =
            URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&recipient_key_bytes));

        let vault = sqlx::query(
            "SELECT owner_user_id,active_epoch,membership_version,state \
             FROM vaults WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let owner_user_id: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
        let active_epoch: i64 = vault.try_get("active_epoch").map_err(ApiError::internal)?;
        let membership_version: i64 = vault
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let vault_state: String = vault.try_get("state").map_err(ApiError::internal)?;
        if vault_state != "active" {
            return Err(ApiError::vault_deletion_pending());
        }
        let current_member_rows = sqlx::query(
            "SELECT user_id,role,state FROM vault_members \
             WHERE vault_id=$1 ORDER BY user_id FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut current_members = Vec::with_capacity(current_member_rows.len());
        for row in current_member_rows {
            current_members.push((
                row.try_get("user_id").map_err(ApiError::internal)?,
                row.try_get("role").map_err(ApiError::internal)?,
                row.try_get("state").map_err(ApiError::internal)?,
            ));
        }
        let is_active_owner = current_members.iter().any(|(member_id, role, state)| {
            member_id == &user.user_id && role == "owner" && state == "active"
        });
        if owner_user_id != user.user_id || !is_active_owner {
            return Err(ApiError::forbidden(
                "VAULT_ROLE_REQUIRED",
                "owner role is required",
            ));
        }

        validate_invitation_manifest(
            vault_id,
            &user.device_id,
            &signer.signing_public_key,
            active_epoch,
            membership_version,
            &request,
            &current_members,
            &recipient_user_id,
            &recipient_fingerprint,
        )?;

        let recipient_already_counted = current_members.iter().any(|(member_id, _, state)| {
            member_id == &recipient_user_id && matches!(state.as_str(), "active" | "invited")
        });
        let counted_members = current_members
            .iter()
            .filter(|(_, _, state)| matches!(state.as_str(), "active" | "invited"))
            .count();
        if !recipient_already_counted && counted_members >= self.max_members_per_vault as usize {
            return Err(ApiError::conflict(
                "VAULT_MEMBER_LIMIT_REACHED",
                "vault has reached its member limit",
            ));
        }

        let previous_digest: Option<String> = sqlx::query_scalar(
            "SELECT digest FROM membership_manifests \
             WHERE vault_id=$1 ORDER BY membership_version DESC LIMIT 1",
        )
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if request.membership.previous_digest != previous_digest {
            return Err(ApiError::conflict(
                "MEMBERSHIP_CHAIN_CONFLICT",
                "previous membership digest does not match",
            ));
        }

        let (digest, manifest_json, name_envelope) = validate_signed_manifest(
            vault_id,
            &signer.signing_public_key,
            &owner_user_id,
            &request.membership,
        )?;
        let expires_at: DateTime<Utc> = sqlx::query_scalar(
            "SELECT clock_timestamp() + ($1::double precision * INTERVAL '1 second')",
        )
        .bind(lifetime as f64)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let created_at = sqlx::query_scalar::<_, DateTime<Utc>>("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let issuance_order: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(issuance_order),0)+1 FROM invitations \
             WHERE vault_id=$1 AND recipient_user_id=$2",
        )
        .bind(vault_id)
        .bind(&recipient_user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let invitation_id = Uuid::new_v4().to_string();
        let mut token_bytes = [0_u8; 32];
        rand::thread_rng().fill_bytes(&mut token_bytes);
        let token = URL_SAFE_NO_PAD.encode(token_bytes);
        let token_hash = crate::sha256_hex(token.as_bytes());
        let key_envelope_json =
            serde_json::to_string(&request.key_envelope).map_err(ApiError::internal)?;

        sqlx::query(
            "INSERT INTO membership_manifests( \
                 vault_id,membership_version,previous_digest,manifest_json,digest, \
                 signer_device_id,signature,created_at \
             ) VALUES($1,$2,$3,$4::jsonb,$5,$6,$7,$8)",
        )
        .bind(vault_id)
        .bind(request.membership.membership_version)
        .bind(&request.membership.previous_digest)
        .bind(&manifest_json)
        .bind(&digest)
        .bind(&user.device_id)
        .bind(&request.membership.signature)
        .bind(created_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if let Some(name_envelope) = name_envelope {
            sqlx::query(
                "UPDATE vaults SET membership_version=$1,name_envelope=$2::jsonb \
                 WHERE vault_id=$3",
            )
            .bind(request.membership.membership_version)
            .bind(name_envelope)
            .bind(vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        } else {
            sqlx::query("UPDATE vaults SET membership_version=$1 WHERE vault_id=$2")
                .bind(request.membership.membership_version)
                .bind(vault_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) \
             VALUES($1,$2,$3,'invited',$4) \
             ON CONFLICT(vault_id,user_id) DO UPDATE \
             SET role=EXCLUDED.role,state='invited',added_at=EXCLUDED.added_at",
        )
        .bind(vault_id)
        .bind(&recipient_user_id)
        .bind(&request.role)
        .bind(created_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO vault_key_envelopes( \
                 vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                 envelope_signature,signer_device_id,membership_version \
             ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8) \
             ON CONFLICT(vault_id,epoch,recipient_device_id) DO UPDATE SET \
                 recipient_user_id=EXCLUDED.recipient_user_id, \
                 envelope=EXCLUDED.envelope, \
                 envelope_signature=EXCLUDED.envelope_signature, \
                 signer_device_id=EXCLUDED.signer_device_id, \
                 membership_version=EXCLUDED.membership_version",
        )
        .bind(vault_id)
        .bind(active_epoch)
        .bind(&recipient_user_id)
        .bind(&request.recipient_device_id)
        .bind(serde_json::to_string(&request.key_envelope.envelope).map_err(ApiError::internal)?)
        .bind(&request.key_envelope.signature)
        .bind(&user.device_id)
        .bind(request.membership.membership_version)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO invitations( \
                 invitation_id,vault_id,token_hash,role,key_envelope,recipient_user_id, \
                 recipient_device_id,signer_device_id,created_by,expires_at,accepted_by, \
                 accepted_at,created_at,issuance_order \
             ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8,$9,$10,NULL,NULL,$11,$12)",
        )
        .bind(&invitation_id)
        .bind(vault_id)
        .bind(token_hash)
        .bind(&request.role)
        .bind(key_envelope_json)
        .bind(&recipient_user_id)
        .bind(&request.recipient_device_id)
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(expires_at)
        .bind(created_at)
        .bind(issuance_order)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        record_vault_invitation_audit(
            &mut tx,
            &user.user_id,
            &user.device_id,
            vault_id,
            "vault.invitation_created",
            &invitation_id,
            created_at.timestamp(),
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;

        Ok(json!({
            "invitation_id": invitation_id,
            "token": token,
            "vault_id": vault_id,
            "role": request.role,
            "expires_at": expires_at.to_rfc3339(),
            "membership_version": request.membership.membership_version,
        }))
    }

    pub(crate) async fn accept_invitation(
        &self,
        user: &auth::AuthUser,
        request: control::AcceptInvitation,
    ) -> Result<Value, ApiError> {
        if request.token.is_empty() || request.token.len() > 512 {
            return Err(ApiError::not_found());
        }
        let token_hash = crate::sha256_hex(request.token.as_bytes());
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_session(&mut tx, user).await?;

        let vault_hint: String =
            sqlx::query_scalar("SELECT vault_id FROM invitations WHERE token_hash=$1")
                .bind(&token_hash)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
                .ok_or_else(ApiError::not_found)?;

        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }
        let device =
            sqlx::query("SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE")
                .bind(&user.device_id)
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
        if device
            .try_get::<String, _>("status")
            .map_err(ApiError::internal)?
            != "active"
        {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }

        let vault = sqlx::query(
            "SELECT active_epoch,membership_version,state,required_record_schema \
             FROM vaults WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(&vault_hint)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let active_epoch: i64 = vault.try_get("active_epoch").map_err(ApiError::internal)?;
        let membership_version: i64 = vault
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let vault_state: String = vault.try_get("state").map_err(ApiError::internal)?;
        if vault_state != "active" {
            return Err(ApiError::vault_deletion_pending());
        }
        let required_record_schema: i16 = vault
            .try_get("required_record_schema")
            .map_err(ApiError::internal)?;

        let invitation = sqlx::query(
            "SELECT invitation_id,role,key_envelope::text AS key_envelope, \
                    recipient_user_id,recipient_device_id,signer_device_id, \
                    expires_at>clock_timestamp() AS unexpired,accepted_at \
             FROM invitations WHERE token_hash=$1 AND vault_id=$2 FOR UPDATE",
        )
        .bind(&token_hash)
        .bind(&vault_hint)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let invitation_id: String = invitation
            .try_get("invitation_id")
            .map_err(ApiError::internal)?;
        let role: String = invitation.try_get("role").map_err(ApiError::internal)?;
        let key_envelope_json: String = invitation
            .try_get("key_envelope")
            .map_err(ApiError::internal)?;
        let recipient_user_id: String = invitation
            .try_get("recipient_user_id")
            .map_err(ApiError::internal)?;
        let recipient_device_id: String = invitation
            .try_get("recipient_device_id")
            .map_err(ApiError::internal)?;
        let signer_device_id: String = invitation
            .try_get("signer_device_id")
            .map_err(ApiError::internal)?;
        let accepted_at: Option<DateTime<Utc>> = invitation
            .try_get("accepted_at")
            .map_err(ApiError::internal)?;
        let unexpired: bool = invitation
            .try_get("unexpired")
            .map_err(ApiError::internal)?;
        if recipient_user_id != user.user_id || recipient_device_id != user.device_id {
            return Err(ApiError::forbidden(
                "INVITATION_RECIPIENT_MISMATCH",
                "invitation is addressed to another device",
            ));
        }
        if accepted_at.is_some() {
            return Err(ApiError::conflict(
                "INVITATION_USED",
                "invitation has already been accepted",
            ));
        }
        if !unexpired {
            return Err(ApiError::gone(
                "INVITATION_EXPIRED",
                "invitation has expired",
            ));
        }

        let active_memberships: i64 = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT vm.vault_id) FROM vault_members vm \
             JOIN vaults v ON v.vault_id=vm.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' \
               AND v.state IN ('active','deleting')",
        )
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if active_memberships >= self.max_vaults_per_user {
            return Err(ApiError::conflict(
                "USER_VAULT_LIMIT_REACHED",
                "account has reached its Vault limit",
            ));
        }
        if required_record_schema >= 2 {
            require_v2_capability_support(&mut tx, &user.user_id).await?;
        }

        let key: auth::InitialKeyEnvelope =
            serde_json::from_str(&key_envelope_json).map_err(ApiError::internal)?;
        if key.recipient_device_id != user.device_id
            || key.key_epoch.as_i64() != Some(active_epoch)
            || key.membership_version.as_i64() != Some(membership_version)
        {
            return Err(ApiError::conflict(
                "INVITATION_STALE",
                "vault key or membership changed; request an updated invitation",
            ));
        }
        let member_state: Option<(String, String)> = sqlx::query_as(
            "SELECT role,state FROM vault_members \
             WHERE vault_id=$1 AND user_id=$2 FOR UPDATE",
        )
        .bind(&vault_hint)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if member_state
            .as_ref()
            .map(|(member_role, state)| (member_role.as_str(), state.as_str()))
            != Some((role.as_str(), "invited"))
        {
            return Err(ApiError::conflict(
                "INVITATION_STALE",
                "invitation is no longer pending",
            ));
        }

        let activated = sqlx::query(
            "UPDATE vault_members SET state='active',role=$3 \
             WHERE vault_id=$1 AND user_id=$2 AND state='invited'",
        )
        .bind(&vault_hint)
        .bind(&user.user_id)
        .bind(&role)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if activated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "INVITATION_STALE",
                "invitation is no longer pending",
            ));
        }
        sqlx::query(
            "INSERT INTO vault_key_envelopes( \
                 vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                 envelope_signature,signer_device_id,membership_version \
             ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8) \
             ON CONFLICT(vault_id,epoch,recipient_device_id) DO UPDATE SET \
                 recipient_user_id=EXCLUDED.recipient_user_id, \
                 envelope=EXCLUDED.envelope, \
                 envelope_signature=EXCLUDED.envelope_signature, \
                 signer_device_id=EXCLUDED.signer_device_id, \
                 membership_version=EXCLUDED.membership_version",
        )
        .bind(&vault_hint)
        .bind(active_epoch)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(serde_json::to_string(&key.envelope).map_err(ApiError::internal)?)
        .bind(&key.signature)
        .bind(&signer_device_id)
        .bind(membership_version)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let accepted_at: Option<DateTime<Utc>> = sqlx::query_scalar(
            "UPDATE invitations SET accepted_by=$1,accepted_at=clock_timestamp() \
             WHERE invitation_id=$2 AND accepted_at IS NULL \
               AND expires_at>clock_timestamp() RETURNING accepted_at",
        )
        .bind(&user.user_id)
        .bind(&invitation_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some(accepted_at) = accepted_at else {
            let (already_accepted, expired): (bool, bool) = sqlx::query_as(
                "SELECT accepted_at IS NOT NULL,expires_at<=clock_timestamp() \
                 FROM invitations WHERE invitation_id=$1",
            )
            .bind(&invitation_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if expired {
                return Err(ApiError::gone(
                    "INVITATION_EXPIRED",
                    "invitation has expired",
                ));
            }
            if already_accepted {
                return Err(ApiError::conflict(
                    "INVITATION_USED",
                    "invitation has already been accepted",
                ));
            }
            return Err(ApiError::conflict(
                "INVITATION_STALE",
                "invitation is no longer pending",
            ));
        };
        let occurred_at = accepted_at.timestamp();
        record_vault_invitation_audit(
            &mut tx,
            &user.user_id,
            &user.device_id,
            &vault_hint,
            "vault.invitation_accepted",
            &invitation_id,
            occurred_at,
        )
        .await?;
        // Acceptance changes the recipient's active Vault set. Prompt sockets
        // on other nodes to refresh their authorized notification snapshot.
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;

        Ok(json!({
            "invitation_id": invitation_id,
            "vault_id": vault_hint,
            "role": role,
            "status": "accepted",
            "membership_version": membership_version,
        }))
    }
}

fn validate_invitation_manifest(
    vault_id: &str,
    owner_device_id: &str,
    owner_signing_public_key: &str,
    active_epoch: i64,
    membership_version: i64,
    request: &control::InvitationRequest,
    current_members: &[(String, String, String)],
    recipient_user_id: &str,
    recipient_fingerprint: &str,
) -> Result<(), ApiError> {
    if request.key_envelope.recipient_device_id != request.recipient_device_id
        || request.key_envelope.key_epoch.as_i64() != Some(active_epoch)
        || request.key_envelope.membership_version.as_i64()
            != Some(request.membership.membership_version)
        || request
            .membership
            .manifest
            .get("key_epoch")
            .and_then(Value::as_i64)
            != Some(active_epoch)
    {
        return Err(ApiError::invalid_envelope(
            "invitation key envelope context is invalid",
        ));
    }
    let Some(expected_version) = membership_version.checked_add(1) else {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "membership version cannot advance further",
        ));
    };
    if request.membership.membership_version != expected_version {
        return Err(ApiError::conflict(
            "MEMBERSHIP_VERSION_CONFLICT",
            "membership version must advance by one",
        ));
    }
    if request
        .membership
        .manifest
        .get("signer_device_id")
        .and_then(Value::as_str)
        != Some(owner_device_id)
    {
        return Err(ApiError::invalid_envelope(
            "membership manifest signer does not match the authenticated device",
        ));
    }
    let manifest_members = request
        .membership
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .ok_or_else(|| ApiError::invalid_envelope("membership manifest member list is invalid"))?;
    let recipient = manifest_members
        .iter()
        .find(|member| member.get("user_id").and_then(Value::as_str) == Some(recipient_user_id))
        .ok_or_else(|| {
            ApiError::invalid_envelope("membership manifest does not grant recipient")
        })?;
    if recipient.get("role").and_then(Value::as_str) != Some(&request.role)
        || recipient.get("state").and_then(Value::as_str) != Some("active")
        || recipient
            .get("encryption_key_fingerprint")
            .and_then(Value::as_str)
            != Some(recipient_fingerprint)
    {
        return Err(ApiError::invalid_envelope(
            "membership grant must list the registered recipient key fingerprint, active state and granted role",
        ));
    }
    control::validate_invitation_membership(
        manifest_members,
        current_members,
        recipient_user_id,
        &request.role,
    )?;
    let key_payload = json!({
        "vault_id": vault_id,
        "recipient_device_id": request.recipient_device_id,
        "key_epoch": request.key_envelope.key_epoch,
        "membership_version": request.key_envelope.membership_version,
        "envelope": request.key_envelope.envelope,
    });
    let key_bytes = crate::jcs(&key_payload)?;
    auth::verify_key_signature(
        owner_signing_public_key,
        &request.key_envelope.signature,
        &key_bytes,
    )?;
    Ok(())
}

pub(crate) fn validate_signed_manifest(
    vault_id: &str,
    owner_signing_public_key: &str,
    owner_user_id: &str,
    input: &control::ManifestInput,
) -> Result<(String, String, Option<String>), ApiError> {
    validate_signed_manifest_inner(
        vault_id,
        owner_signing_public_key,
        owner_user_id,
        input,
        None,
    )
}

/// Validates the signed manifest used when the current owner transfers a
/// Vault to an existing member. The new owner is the sole active owner in the
/// manifest, while the current owner remains the authenticated signer.
pub(crate) fn validate_signed_transfer_manifest(
    vault_id: &str,
    owner_signing_public_key: &str,
    current_owner_user_id: &str,
    new_owner_user_id: &str,
    input: &control::ManifestInput,
) -> Result<(String, String, Option<String>), ApiError> {
    if !crate::is_canonical_uuid(new_owner_user_id) || new_owner_user_id == current_owner_user_id {
        return Err(ApiError::bad_request(
            "INVALID_OWNER_TRANSFER",
            "new owner must be a different canonical user ID",
        ));
    }
    validate_signed_manifest_inner(
        vault_id,
        owner_signing_public_key,
        new_owner_user_id,
        input,
        Some((current_owner_user_id, new_owner_user_id)),
    )
}

fn validate_signed_manifest_inner(
    vault_id: &str,
    owner_signing_public_key: &str,
    manifest_owner_user_id: &str,
    input: &control::ManifestInput,
    ownership_transfer: Option<(&str, &str)>,
) -> Result<(String, String, Option<String>), ApiError> {
    if input.membership_version < 1
        || !input.manifest.is_object()
        || input.manifest.to_string().len() > MAX_MANIFEST_BYTES
    {
        return Err(ApiError::bad_request(
            "INVALID_MEMBERSHIP_MANIFEST",
            "membership manifest is invalid",
        ));
    }
    let members = input
        .manifest
        .get("members")
        .and_then(Value::as_array)
        .filter(|members| !members.is_empty() && members.len() <= 1000)
        .ok_or_else(|| ApiError::invalid_envelope("membership manifest member list is invalid"))?;
    let mut ids = HashSet::with_capacity(members.len());
    let mut active_owner = None;
    for member in members {
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
        if !crate::is_canonical_uuid(id)
            || !ids.insert(id)
            || !["owner", "editor", "viewer"].contains(&role)
            || !["active", "invited", "revoked"].contains(&state)
        {
            return Err(ApiError::invalid_envelope(
                "membership manifest contains an invalid or duplicate member",
            ));
        }
        if role == "owner" && state == "active" {
            if active_owner.replace(id).is_some() {
                return Err(ApiError::invalid_envelope(
                    "membership manifest must keep exactly one active owner",
                ));
            }
        }
    }
    if active_owner != Some(manifest_owner_user_id) {
        return Err(ApiError::invalid_envelope(match ownership_transfer {
            Some(_) => "membership manifest owner does not match the authorized owner transition",
            None => "membership manifest owner does not match the authorized owner",
        }));
    }
    match ownership_transfer {
        None if input.manifest.get("ownership_transfer").is_some() => {
            return Err(ApiError::invalid_envelope(
                "membership manifest owner does not match the authorized owner",
            ));
        }
        Some((current_owner_user_id, new_owner_user_id)) => {
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
            if transfer.get("from_user_id").and_then(Value::as_str) != Some(current_owner_user_id)
                || transfer.get("to_user_id").and_then(Value::as_str) != Some(new_owner_user_id)
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
            let former_owner = members.iter().find(|member| {
                member.get("user_id").and_then(Value::as_str) == Some(current_owner_user_id)
            });
            let new_owner = members.iter().find(|member| {
                member.get("user_id").and_then(Value::as_str) == Some(new_owner_user_id)
            });
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
        None => {}
    }
    let name_envelope = input
        .manifest
        .get("display_name_envelope")
        .map(auth::validate_display_name_envelope)
        .transpose()?;
    let payload = json!({
        "vault_id": vault_id,
        "membership_version": input.membership_version,
        "previous_digest": input.previous_digest,
        "manifest": input.manifest,
    });
    let signed_bytes = crate::jcs(&payload)?;
    auth::verify_key_signature(owner_signing_public_key, &input.signature, &signed_bytes)?;
    let digest = crate::sha256_hex(&signed_bytes);
    let previous_digest = input
        .previous_digest
        .clone()
        .map(Value::String)
        .unwrap_or(Value::Null);
    let manifest_json = auth::serialize_signed_membership_record(
        vault_id,
        Value::from(input.membership_version),
        previous_digest,
        &input.manifest,
        &input.signature,
    )?;
    Ok((digest, manifest_json, name_envelope))
}

async fn lock_active_session(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT revoked_at,access_expires_at>clock_timestamp() AS unexpired \
         FROM sessions WHERE session_id=$1 AND user_id=$2 AND device_id=$3 \
           AND access_hash=$4 FOR SHARE",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    if row
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_some()
        || !row
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

async fn require_v2_capability_support(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
) -> Result<(), ApiError> {
    let unsupported: bool = sqlx::query_scalar(
        "SELECT EXISTS( \
            SELECT 1 FROM devices d \
            LEFT JOIN device_capability_reports r \
              ON r.device_id=d.device_id AND r.user_id=d.user_id \
            WHERE d.user_id=$1 AND d.status='active' \
              AND (r.device_id IS NULL OR r.max_record_schema<2 \
                   OR r.max_attachment_bytes<$2 \
                   OR NOT (r.host_attachment_manifest_versions @> '[2]'::jsonb)) \
         )",
    )
    .bind(user_id)
    .bind(MAX_ATTACHMENT_BYTES)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if unsupported {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "all active recipient devices must support schema 2, attachment manifest v2, and 1 GiB attachments",
        ));
    }
    Ok(())
}

async fn record_vault_invitation_audit(
    tx: &mut Transaction<'_, Postgres>,
    user_id: &str,
    device_id: &str,
    vault_id: &str,
    action: &str,
    invitation_id: &str,
    occurred_at: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source \
         ) VALUES('vault',$1,$2,$3,$4,'invitation',$5,'success',$6,'api')",
    )
    .bind(vault_id)
    .bind(user_id)
    .bind(device_id)
    .bind(action)
    .bind(invitation_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

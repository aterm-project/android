//! PostgreSQL-backed Vault key rotation.
//!
//! The Vault row serializes changes to the membership chain and key epoch.
//! Account and device rows are locked first so account disablement, device
//! revocation/enrollment, invitations, and rotations observe a stable target
//! set across PostgreSQL nodes.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use chrono::Utc;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth, control, pg_notifications::notify_sync_wake};

const MAX_ROTATION_MEMBERS: usize = 1000;
const MAX_ROTATION_ENVELOPES: usize = 1000;
const MAX_KEY_ENVELOPE_BYTES: usize = 64 * 1024;

#[derive(Clone)]
pub(crate) struct PgVaultRotationRepository {
    pool: PgPool,
}

#[derive(Clone)]
struct LockedDevice {
    user_id: String,
    signing_public_key: String,
    status: String,
}

#[derive(Clone)]
struct DesiredMember {
    role: String,
    signed_state: String,
}

impl PgVaultRotationRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Applies a normal owner-signed key rotation.
    pub(crate) async fn rotate_key(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        request: control::RotateRequest,
    ) -> Result<Value, ApiError> {
        self.rotate_key_request(user, vault_id, None, request).await
    }

    /// Rotates the key and transfers ownership to an existing active member.
    pub(crate) async fn transfer_ownership(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        new_owner_user_id: String,
        request: control::RotateRequest,
    ) -> Result<Value, ApiError> {
        self.rotate_key_request(user, vault_id, Some(new_owner_user_id), request)
            .await
    }

    async fn rotate_key_request(
        &self,
        user: &auth::AuthUser,
        vault_id: &str,
        transfer_to: Option<String>,
        request: control::RotateRequest,
    ) -> Result<Value, ApiError> {
        if transfer_to
            .as_deref()
            .is_some_and(|target| !crate::is_canonical_uuid(target) || target == user.user_id)
        {
            return Err(ApiError::bad_request(
                "INVALID_OWNER_TRANSFER",
                "new owner must be a different canonical user ID",
            ));
        }
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_session(&mut tx, user).await?;

        // Match the SQLite route's early authorization and stale-epoch errors.
        // This is an unlocked snapshot; all security-sensitive state is
        // rechecked after the ordered row locks below.
        let preflight = sqlx::query(
            "SELECT v.owner_user_id,v.active_epoch,v.membership_version,v.state,\
                    vm.role,u.status AS account_status \
             FROM vaults v \
             JOIN vault_members vm ON vm.vault_id=v.vault_id \
             JOIN users u ON u.user_id=vm.user_id \
             WHERE v.vault_id=$1 AND vm.user_id=$2 AND vm.state='active' \
               AND v.state IN ('active','deleting')",
        )
        .bind(vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;

        let account_status: String = preflight
            .try_get("account_status")
            .map_err(ApiError::internal)?;
        if account_status != "active" {
            return Err(ApiError::unauthorized());
        }
        let vault_state: String = preflight.try_get("state").map_err(ApiError::internal)?;
        if vault_state == "deleting" {
            return Err(ApiError::vault_deletion_pending());
        }
        let current_role: String = preflight.try_get("role").map_err(ApiError::internal)?;
        if current_role == "viewer" {
            return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
        }
        let owner_user_id: String = preflight
            .try_get("owner_user_id")
            .map_err(ApiError::internal)?;
        if current_role != "owner" || owner_user_id != user.user_id {
            return Err(ApiError::forbidden(
                "VAULT_ROLE_REQUIRED",
                "owner role is required",
            ));
        }

        let preflight_epoch: i64 = preflight
            .try_get("active_epoch")
            .map_err(ApiError::internal)?;
        let preflight_version: i64 = preflight
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        if preflight_epoch.checked_add(1) != Some(request.new_epoch) {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "key epoch must advance by one",
            ));
        }
        if request.key_envelopes.is_empty() || request.key_envelopes.len() > MAX_ROTATION_ENVELOPES
        {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "key envelope list is invalid",
            ));
        }

        let signer_public_key: Option<String> = sqlx::query_scalar(
            "SELECT signing_public_key FROM devices \
             WHERE device_id=$1 AND user_id=$2 AND status='active'",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let signer_public_key = signer_public_key
            .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
        if request
            .membership
            .manifest
            .get("signer_device_id")
            .and_then(Value::as_str)
            != Some(&user.device_id)
        {
            return Err(ApiError::invalid_envelope(
                "membership manifest signer does not match the authenticated device",
            ));
        }
        let (manifest_digest, manifest_json, name_envelope) =
            if let Some(new_owner_user_id) = transfer_to.as_deref() {
                crate::pg_vault_invitations::validate_signed_transfer_manifest(
                    vault_id,
                    &signer_public_key,
                    &user.user_id,
                    new_owner_user_id,
                    &request.membership,
                )?
            } else {
                crate::pg_vault_invitations::validate_signed_manifest(
                    vault_id,
                    &signer_public_key,
                    &user.user_id,
                    &request.membership,
                )?
            };
        if preflight_version.checked_add(1) != Some(request.membership.membership_version) {
            return Err(ApiError::conflict(
                "MEMBERSHIP_VERSION_CONFLICT",
                "membership version must advance by one",
            ));
        }
        if request
            .membership
            .manifest
            .get("key_epoch")
            .and_then(Value::as_i64)
            != Some(request.new_epoch)
        {
            return Err(ApiError::invalid_envelope(
                "rotation membership manifest key epoch does not match the requested epoch",
            ));
        }
        let display_name_envelope = request
            .membership
            .manifest
            .get("display_name_envelope")
            .ok_or_else(|| {
                ApiError::invalid_envelope(
                    "rotation membership must include a display name envelope for the new epoch",
                )
            })?;
        auth::validate_display_name_envelope(display_name_envelope)?;
        let name_envelope = name_envelope.ok_or_else(|| {
            ApiError::invalid_envelope(
                "rotation membership must include a display name envelope for the new epoch",
            )
        })?;

        let desired = parse_desired_members(&request.membership.manifest)?;

        // Read the current IDs without locking so all account rows can be
        // acquired in lexical order before device and Vault locks. Vault
        // version and member rows are compared again after the Vault lock.
        let preflight_member_rows =
            sqlx::query("SELECT user_id FROM vault_members WHERE vault_id=$1 ORDER BY user_id")
                .bind(vault_id)
                .fetch_all(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let preflight_member_ids: BTreeSet<String> = preflight_member_rows
            .iter()
            .map(|row| row.try_get("user_id").map_err(ApiError::internal))
            .collect::<Result<_, ApiError>>()?;
        if preflight_member_ids != desired.keys().cloned().collect::<BTreeSet<_>>() {
            return Err(ApiError::invalid_envelope(
                "rotation must describe every existing member; add new accounts through invitations first",
            ));
        }

        let mut account_ids = preflight_member_ids.clone();
        account_ids.extend(desired.keys().cloned());
        account_ids.insert(user.user_id.clone());
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

        // SQLite derives the target device set from signed `state == active`;
        // invited DB grants therefore remain invited in the ACL while their
        // old invitation becomes stale after this epoch advances.
        let mut candidate_recipient_users = BTreeMap::<String, String>::new();
        for (member_id, member) in &desired {
            if member.signed_state != "active" {
                continue;
            }
            if account_statuses.get(member_id).and_then(Option::as_deref) != Some("active") {
                return Err(ApiError::invalid_envelope(
                    "active membership references an unavailable account",
                ));
            }
            let rows = sqlx::query(
                "SELECT device_id FROM devices \
                 WHERE user_id=$1 AND status='active' ORDER BY device_id",
            )
            .bind(member_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            for row in rows {
                let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
                candidate_recipient_users.insert(device_id, member_id.clone());
            }
        }
        if candidate_recipient_users.is_empty()
            || candidate_recipient_users.len() > MAX_ROTATION_ENVELOPES
        {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "active member device set is empty or exceeds the rotation limit",
            ));
        }

        let mut device_ids: BTreeSet<String> = candidate_recipient_users.keys().cloned().collect();
        device_ids.insert(user.device_id.clone());
        device_ids.extend(
            request
                .key_envelopes
                .iter()
                .map(|envelope| envelope.signer_device_id.clone()),
        );
        let mut locked_devices = HashMap::with_capacity(device_ids.len());
        for device_id in &device_ids {
            let row = sqlx::query(
                "SELECT user_id,signing_public_key,status FROM devices \
                 WHERE device_id=$1 FOR SHARE",
            )
            .bind(device_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if let Some(row) = row {
                locked_devices.insert(
                    device_id.clone(),
                    LockedDevice {
                        user_id: row.try_get("user_id").map_err(ApiError::internal)?,
                        signing_public_key: row
                            .try_get("signing_public_key")
                            .map_err(ApiError::internal)?,
                        status: row.try_get("status").map_err(ApiError::internal)?,
                    },
                );
            }
        }
        let actor_device = locked_devices
            .get(&user.device_id)
            .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
        if actor_device.user_id != user.user_id || actor_device.status != "active" {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }
        if actor_device.signing_public_key != signer_public_key {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "owner signing device changed; retry the rotation",
            ));
        }

        let vault = sqlx::query(
            "SELECT owner_user_id,active_epoch,membership_version,state \
             FROM vaults WHERE vault_id=$1 FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let locked_owner_id: String = vault.try_get("owner_user_id").map_err(ApiError::internal)?;
        let locked_epoch: i64 = vault.try_get("active_epoch").map_err(ApiError::internal)?;
        let locked_version: i64 = vault
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let locked_vault_state: String = vault.try_get("state").map_err(ApiError::internal)?;
        if locked_vault_state == "deleting" {
            return Err(ApiError::vault_deletion_pending());
        }
        if locked_vault_state != "active" {
            return Err(ApiError::not_found());
        }
        if locked_owner_id != user.user_id {
            return Err(ApiError::forbidden(
                "VAULT_ROLE_REQUIRED",
                "owner role is required",
            ));
        }
        if locked_epoch != preflight_epoch
            || locked_version != preflight_version
            || locked_epoch.checked_add(1) != Some(request.new_epoch)
            || locked_version.checked_add(1) != Some(request.membership.membership_version)
        {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "vault epoch or membership changed; retry with a current signed manifest",
            ));
        }

        let current_rows = sqlx::query(
            "SELECT user_id,role,state FROM vault_members \
             WHERE vault_id=$1 ORDER BY user_id FOR UPDATE",
        )
        .bind(vault_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut current_members = BTreeMap::<String, (String, String)>::new();
        for row in current_rows {
            let member_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
            let role: String = row.try_get("role").map_err(ApiError::internal)?;
            let state: String = row.try_get("state").map_err(ApiError::internal)?;
            current_members.insert(member_id, (role, state));
        }
        if current_members.keys().cloned().collect::<BTreeSet<_>>() != preflight_member_ids {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "vault membership changed; retry with a current signed manifest",
            ));
        }
        if current_members
            .keys()
            .any(|member_id| !account_ids.contains(member_id))
        {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "vault membership changed; retry with a current signed manifest",
            ));
        }
        let Some((locked_actor_role, locked_actor_state)) = current_members.get(&user.user_id)
        else {
            return Err(ApiError::not_found());
        };
        if locked_actor_state != "active" {
            return Err(ApiError::not_found());
        }
        if locked_actor_role != "owner" {
            return Err(ApiError::forbidden(
                "VAULT_ROLE_REQUIRED",
                "owner role is required",
            ));
        }
        if current_members.keys().cloned().collect::<BTreeSet<_>>()
            != desired.keys().cloned().collect::<BTreeSet<_>>()
        {
            return Err(ApiError::invalid_envelope(
                "rotation must describe every existing member; add new accounts through invitations first",
            ));
        }
        if let Some(new_owner_user_id) = transfer_to.as_deref() {
            validate_owner_transfer_member_transition(
                &user.user_id,
                new_owner_user_id,
                &current_members,
                &desired,
            )?;
        }
        let mut membership_audit_changes = Vec::<(String, &'static str)>::new();
        let mut next_states = BTreeMap::<String, &'static str>::new();
        for (member_id, member) in &desired {
            let (current_role, current_state) = current_members
                .get(member_id)
                .ok_or_else(|| ApiError::internal("locked membership row disappeared"))?;
            let next_acl_state = control::rotated_acl_state(current_state, &member.signed_state)
                .map_err(|_| {
                    ApiError::invalid_envelope(
                        "rotation cannot grant or reactivate membership outside the invitation flow",
                    )
                })?;
            let action = if current_state != "revoked" && next_acl_state == "revoked" {
                Some("vault.member_revoked")
            } else if current_role != &member.role {
                Some("vault.member_role_changed")
            } else {
                None
            };
            if let Some(action) = action {
                membership_audit_changes.push((member_id.clone(), action));
            }
            next_states.insert(member_id.clone(), next_acl_state);
        }
        for (member_id, member) in &desired {
            if account_statuses.get(member_id).is_none_or(Option::is_none) {
                return Err(ApiError::invalid_envelope(
                    "active membership references an unavailable account",
                ));
            }
            if member.signed_state == "active"
                && account_statuses.get(member_id).and_then(Option::as_deref) != Some("active")
            {
                return Err(ApiError::invalid_envelope(
                    "active membership references an unavailable account",
                ));
            }
        }

        // Account locks freeze device enrollment/revocation. Still compare the
        // post-lock set to the candidate set so unexpected writers fail closed.
        let mut current_recipient_users = BTreeMap::<String, String>::new();
        for (member_id, member) in &desired {
            if member.signed_state != "active" {
                continue;
            }
            let rows = sqlx::query(
                "SELECT device_id FROM devices \
                 WHERE user_id=$1 AND status='active' ORDER BY device_id",
            )
            .bind(member_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            for row in rows {
                let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
                current_recipient_users.insert(device_id, member_id.clone());
            }
        }
        if current_recipient_users != candidate_recipient_users {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "active member devices changed; retry with current key envelopes",
            ));
        }
        for (device_id, member_id) in &current_recipient_users {
            let Some(device) = locked_devices.get(device_id) else {
                return Err(ApiError::conflict(
                    "KEY_EPOCH_OUTDATED",
                    "active member devices changed; retry with current key envelopes",
                ));
            };
            if device.user_id != *member_id || device.status != "active" {
                return Err(ApiError::conflict(
                    "KEY_EPOCH_OUTDATED",
                    "active member devices changed; retry with current key envelopes",
                ));
            }
        }
        if let Some(new_owner_user_id) = transfer_to.as_deref()
            && !current_recipient_users
                .values()
                .any(|member_id| member_id == new_owner_user_id)
        {
            return Err(ApiError::conflict(
                "OWNER_TRANSFER_TARGET_INVALID",
                "new owner must have at least one active device to receive the rotated key",
            ));
        }

        let expected_recipients: HashSet<String> =
            current_recipient_users.keys().cloned().collect();
        let supplied_recipients: HashSet<String> = request
            .key_envelopes
            .iter()
            .map(|envelope| envelope.recipient_device_id.clone())
            .collect();
        if supplied_recipients.len() != request.key_envelopes.len()
            || supplied_recipients != expected_recipients
        {
            return Err(ApiError::invalid_envelope(
                "rotation must include exactly one key envelope for every active device in the signed membership manifest",
            ));
        }

        let mut validated_envelopes = Vec::with_capacity(request.key_envelopes.len());
        for envelope in request.key_envelopes {
            if !crate::is_canonical_uuid(&envelope.recipient_device_id)
                || envelope.key_epoch.as_i64() != Some(request.new_epoch)
                || envelope.membership_version.as_i64()
                    != Some(request.membership.membership_version)
                || !envelope.envelope.is_object()
                || envelope.envelope.to_string().len() > MAX_KEY_ENVELOPE_BYTES
            {
                return Err(ApiError::invalid_envelope(
                    "rotation key envelope context is invalid",
                ));
            }
            let Some(recipient_user_id) = current_recipient_users
                .get(&envelope.recipient_device_id)
                .cloned()
            else {
                return Err(ApiError::bad_request(
                    "INVALID_KEY_RECIPIENT",
                    "key envelope recipient is not an active member device",
                ));
            };
            let Some(signer) = locked_devices.get(&envelope.signer_device_id) else {
                return Err(ApiError::forbidden(
                    "VAULT_ROLE_REQUIRED",
                    "key envelope signer is not a vault member",
                ));
            };
            if signer.user_id != user.user_id
                || signer.status != "active"
                || current_members
                    .get(&signer.user_id)
                    .map(|(_, state)| state.as_str())
                    != Some("active")
                || current_members
                    .get(&signer.user_id)
                    .map(|(role, _)| role.as_str())
                    != Some("owner")
            {
                return Err(ApiError::forbidden(
                    "VAULT_ROLE_REQUIRED",
                    "only an owner device can sign a rotation key envelope",
                ));
            }
            let signed = json!({
                "vault_id": vault_id,
                "recipient_device_id": envelope.recipient_device_id,
                "key_epoch": envelope.key_epoch,
                "membership_version": envelope.membership_version,
                "envelope": envelope.envelope,
            });
            auth::verify_key_signature(
                &signer.signing_public_key,
                &envelope.signature,
                &crate::jcs(&signed)?,
            )?;
            validated_envelopes.push((envelope, recipient_user_id));
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

        sqlx::query(
            "INSERT INTO membership_manifests( \
                 vault_id,membership_version,previous_digest,manifest_json,digest, \
                 signer_device_id,signature \
             ) VALUES($1,$2,$3,$4::jsonb,$5,$6,$7)",
        )
        .bind(vault_id)
        .bind(request.membership.membership_version)
        .bind(&request.membership.previous_digest)
        .bind(&manifest_json)
        .bind(&manifest_digest)
        .bind(&user.device_id)
        .bind(&request.membership.signature)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        for (member_id, member) in &desired {
            let next_state = next_states
                .get(member_id)
                .ok_or_else(|| ApiError::internal("validated ACL state is missing"))?;
            sqlx::query(
                "UPDATE vault_members SET role=$1,state=$2 \
                 WHERE vault_id=$3 AND user_id=$4",
            )
            .bind(&member.role)
            .bind(next_state)
            .bind(vault_id)
            .bind(member_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        let changed = if let Some(new_owner_user_id) = transfer_to.as_deref() {
            sqlx::query(
                "UPDATE vaults SET active_epoch=$1,membership_version=$2, \
                     name_envelope=$3::jsonb,owner_user_id=$4 \
                 WHERE vault_id=$5 AND owner_user_id=$6 \
                   AND active_epoch=$7 AND membership_version=$8",
            )
            .bind(request.new_epoch)
            .bind(request.membership.membership_version)
            .bind(&name_envelope)
            .bind(new_owner_user_id)
            .bind(vault_id)
            .bind(&user.user_id)
            .bind(locked_epoch)
            .bind(locked_version)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
        } else {
            sqlx::query(
                "UPDATE vaults SET active_epoch=$1,membership_version=$2,name_envelope=$3::jsonb \
                 WHERE vault_id=$4 AND owner_user_id=$5 AND active_epoch=$6 \
                   AND membership_version=$7",
            )
            .bind(request.new_epoch)
            .bind(request.membership.membership_version)
            .bind(&name_envelope)
            .bind(vault_id)
            .bind(&user.user_id)
            .bind(locked_epoch)
            .bind(locked_version)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
        };
        if changed.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "KEY_EPOCH_OUTDATED",
                "vault epoch or membership changed; retry with a current signed manifest",
            ));
        }

        for (envelope, recipient_user_id) in validated_envelopes {
            let envelope_json =
                serde_json::to_string(&envelope.envelope).map_err(ApiError::internal)?;
            sqlx::query(
                "INSERT INTO vault_key_envelopes( \
                     vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                     envelope_signature,signer_device_id,membership_version \
                 ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8)",
            )
            .bind(vault_id)
            .bind(request.new_epoch)
            .bind(recipient_user_id)
            .bind(&envelope.recipient_device_id)
            .bind(envelope_json)
            .bind(&envelope.signature)
            .bind(&envelope.signer_device_id)
            .bind(request.membership.membership_version)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        for (member_id, action) in membership_audit_changes {
            record_vault_rotation_audit(
                &mut tx,
                vault_id,
                user,
                action,
                "membership",
                Some(&member_id),
            )
            .await?;
        }
        record_vault_rotation_audit(
            &mut tx,
            vault_id,
            user,
            "vault.key_rotated",
            "vault",
            Some(vault_id),
        )
        .await?;
        if let Some(new_owner_user_id) = transfer_to.as_deref() {
            record_vault_rotation_audit(
                &mut tx,
                vault_id,
                user,
                "vault.ownership_transferred",
                "membership",
                Some(new_owner_user_id),
            )
            .await?;
        }

        // Membership roles/states and ownership are part of the notification
        // authorization snapshot. Wake sockets on every node in the same
        // transaction so they recheck ACLs as soon as this change commits.
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        let resulting_owner = transfer_to.as_deref().unwrap_or(&user.user_id);
        Ok(json!({
            "vault_id": vault_id,
            "owner_user_id": resulting_owner,
            "active_key_epoch": request.new_epoch,
            "membership_version": request.membership.membership_version,
            "status": "active",
        }))
    }
}

fn parse_desired_members(manifest: &Value) -> Result<BTreeMap<String, DesiredMember>, ApiError> {
    let members = manifest
        .get("members")
        .and_then(Value::as_array)
        .filter(|members| !members.is_empty() && members.len() <= MAX_ROTATION_MEMBERS)
        .ok_or_else(|| ApiError::invalid_envelope("rotation membership member list is invalid"))?;
    let mut desired = BTreeMap::new();
    for member in members {
        let user_id = member
            .get("user_id")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member id is invalid"))?
            .to_owned();
        let role = member
            .get("role")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member role is invalid"))?
            .to_owned();
        let signed_state = member
            .get("state")
            .and_then(Value::as_str)
            .ok_or_else(|| ApiError::invalid_envelope("rotation member state is invalid"))?
            .to_owned();
        if desired
            .insert(user_id, DesiredMember { role, signed_state })
            .is_some()
        {
            return Err(ApiError::invalid_envelope(
                "rotation membership contains duplicate users",
            ));
        }
    }
    Ok(desired)
}

fn validate_owner_transfer_member_transition(
    current_owner_user_id: &str,
    new_owner_user_id: &str,
    current_members: &BTreeMap<String, (String, String)>,
    desired: &BTreeMap<String, DesiredMember>,
) -> Result<(), ApiError> {
    let target = current_members.get(new_owner_user_id);
    if !matches!(
        target.map(|(role, state)| (role.as_str(), state.as_str())),
        Some(("editor" | "viewer", "active"))
    ) {
        return Err(ApiError::conflict(
            "OWNER_TRANSFER_TARGET_INVALID",
            "new owner must be an existing active editor or viewer",
        ));
    }
    if current_members
        .get(current_owner_user_id)
        .map(|(role, state)| (role.as_str(), state.as_str()))
        != Some(("owner", "active"))
    {
        return Err(ApiError::invalid_envelope(
            "ownership transfer source is not the active owner",
        ));
    }
    if current_members.len() != desired.len() {
        return Err(ApiError::invalid_envelope(
            "ownership transfer must describe every existing member",
        ));
    }

    for (member_id, (current_role, current_state)) in current_members {
        let (expected_role, expected_state) = if member_id == current_owner_user_id {
            ("editor", "active")
        } else if member_id == new_owner_user_id {
            ("owner", "active")
        } else {
            let signed_state = match current_state.as_str() {
                "active" | "invited" => "active",
                "revoked" => "revoked",
                _ => {
                    return Err(ApiError::internal(
                        "database contains an invalid vault membership state",
                    ));
                }
            };
            (current_role.as_str(), signed_state)
        };
        let Some(desired_member) = desired.get(member_id) else {
            return Err(ApiError::invalid_envelope(
                "ownership transfer omitted an existing member",
            ));
        };
        if desired_member.role != expected_role || desired_member.signed_state != expected_state {
            return Err(ApiError::invalid_envelope(
                "ownership transfer cannot include unrelated role, invitation or revocation changes",
            ));
        }
    }
    Ok(())
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
        .try_get::<Option<chrono::DateTime<Utc>>, _>("revoked_at")
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

async fn record_vault_rotation_audit(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    user: &auth::AuthUser,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source \
         ) VALUES('vault',$1,$2,$3,$4,$5,$6,'success',$7,'api')",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(action)
    .bind(resource_type)
    .bind(resource_id)
    .bind(Utc::now().timestamp())
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

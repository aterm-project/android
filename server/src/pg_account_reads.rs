//! PostgreSQL-backed account, device, and Vault read projections.
//!
//! The public handlers continue to own HTTP extraction and policy decisions;
//! this repository only maps the shared PostgreSQL rows to the API's existing
//! response DTOs. Each operation holds shared locks on the exact session,
//! account, and device represented by `AuthUser`. Vault reads additionally
//! require and hold an active membership row for that Vault.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth::AuthUser};

#[derive(Clone)]
pub(crate) struct PgAccountReadsRepository {
    pool: PgPool,
}

impl PgAccountReadsRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Returns the normalized username for the configured local admin lookup.
    pub(crate) async fn username(&self, user_id: &str) -> Result<String, ApiError> {
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1 AND status='active'")
            .bind(user_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::unauthorized)
    }

    pub(crate) async fn me(
        &self,
        user: &AuthUser,
        instance_admin: bool,
        registration_open: bool,
        recovery_status: &str,
    ) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        let row = sqlx::query(
            "SELECT u.username,c.account_key_envelope,c.credential_version \
             FROM users u JOIN auth_credentials c ON c.user_id=u.user_id \
             WHERE u.user_id=$1 AND u.status='active'",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;

        let account_key_envelope = parse_json_or_null(
            row.try_get::<String, _>("account_key_envelope")
                .map_err(ApiError::internal)?,
        );
        let result = json!({
            "account_id": user.user_id,
            "username": row.try_get::<String, _>("username").map_err(ApiError::internal)?,
            "device_id": user.device_id,
            "account_key_envelope": account_key_envelope,
            "account_key_envelope_version": row.try_get::<i64, _>("credential_version").map_err(ApiError::internal)?,
            "recovery_status": recovery_status,
            "policy": {
                "registration_open": registration_open,
                "instance_admin": instance_admin,
            },
        });
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(result)
    }

    pub(crate) async fn list_devices(&self, user: &AuthUser) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        let rows = sqlx::query(
            "SELECT d.device_id,d.name,d.signing_public_key,d.encryption_public_key,\
                    d.status,d.created_at,d.revoked_at,r.revision AS cap_revision,\
                    r.user_id AS cap_account_id,r.device_id AS cap_device_id,\
                    r.max_record_schema AS cap_max_record_schema,\
                    r.host_attachment_manifest_versions::text AS cap_attachment_versions,\
                    r.max_attachment_bytes AS cap_max_attachment_bytes,r.signature AS cap_signature \
             FROM devices d \
             LEFT JOIN device_capability_reports r ON r.device_id=d.device_id AND r.user_id=d.user_id \
             WHERE d.user_id=$1 \
             ORDER BY d.created_at,d.device_id",
        )
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut devices = Vec::with_capacity(rows.len());
        for row in rows {
            let capability_report = capability_report_from_row(&row)?;
            devices.push(json!({
                "device_id": row.try_get::<String, _>("device_id").map_err(ApiError::internal)?,
                "user_id": user.user_id,
                "name": row.try_get::<String, _>("name").map_err(ApiError::internal)?,
                "signing_public_key": row.try_get::<String, _>("signing_public_key").map_err(ApiError::internal)?,
                "encryption_public_key": row.try_get::<String, _>("encryption_public_key").map_err(ApiError::internal)?,
                "status": row.try_get::<String, _>("status").map_err(ApiError::internal)?,
                "created_at": format_timestamp(row.try_get("created_at").map_err(ApiError::internal)?),
                "revoked_at": row.try_get::<Option<DateTime<Utc>>, _>("revoked_at").map_err(ApiError::internal)?.map(format_timestamp),
                "capability_report": capability_report,
            }));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({"devices": devices}))
    }

    pub(crate) async fn list_vaults(&self, user: &AuthUser) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        let rows = sqlx::query(
            "SELECT v.vault_id \
             FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' \
               AND v.state IN ('active','deleting') \
             ORDER BY v.created_at,v.vault_id",
        )
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut vaults = Vec::with_capacity(rows.len());
        for row in rows {
            let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
            // Lifecycle writers and due purge lock Vault before membership
            // and deletion-request rows. Reacquire that same order here so a
            // deletion transition cannot race a stale owner cancellation DTO.
            self.require_active_vault_member(&mut tx, &user.user_id, &vault_id)
                .await?;
            let row = sqlx::query(
                "SELECT v.vault_id,vm.role,v.active_epoch,v.membership_version,\
                        v.required_record_schema,v.name_envelope::text AS name_envelope,v.state,\
                        dr.requested_at,dr.purge_after \
                 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id \
                 LEFT JOIN vault_deletion_requests dr ON dr.vault_id=v.vault_id \
                   AND dr.cancelled_at IS NULL AND dr.purged_at IS NULL \
                 WHERE v.vault_id=$1 AND vm.user_id=$2 AND vm.state='active' \
                   AND v.state IN ('active','deleting')",
            )
            .bind(&vault_id)
            .bind(&user.user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
            let role: String = row.try_get("role").map_err(ApiError::internal)?;
            let status: String = row.try_get("state").map_err(ApiError::internal)?;
            let requested_at: Option<i64> =
                row.try_get("requested_at").map_err(ApiError::internal)?;
            let purge_after: Option<i64> =
                row.try_get("purge_after").map_err(ApiError::internal)?;
            let envelopes = sqlx::query(
                "SELECT e.epoch,e.recipient_device_id,e.envelope::text AS envelope,\
                        e.envelope_signature,e.signer_device_id,e.membership_version \
                 FROM vault_key_envelopes e \
                 JOIN vault_members vm ON vm.vault_id=e.vault_id AND vm.user_id=e.recipient_user_id \
                 JOIN vaults v ON v.vault_id=e.vault_id \
                 WHERE e.vault_id=$1 AND e.recipient_user_id=$2 \
                   AND e.recipient_device_id=$3 AND vm.state='active' \
                   AND v.state IN ('active','deleting') \
                 ORDER BY e.epoch DESC",
            )
            .bind(&vault_id)
            .bind(&user.user_id)
            .bind(&user.device_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

            let key_envelopes = envelopes
                .into_iter()
                .map(|envelope| {
                    Ok::<Value, ApiError>(json!({
                        "key_epoch": envelope.try_get::<i64, _>("epoch").map_err(ApiError::internal)?,
                        "recipient_device_id": envelope.try_get::<String, _>("recipient_device_id").map_err(ApiError::internal)?,
                        "envelope": parse_json_or_null(envelope.try_get::<String, _>("envelope").map_err(ApiError::internal)?),
                        "signature": envelope.try_get::<String, _>("envelope_signature").map_err(ApiError::internal)?,
                        "signer_device_id": envelope.try_get::<String, _>("signer_device_id").map_err(ApiError::internal)?,
                        "membership_version": envelope.try_get::<i64, _>("membership_version").map_err(ApiError::internal)?,
                    }))
                })
                .collect::<Result<Vec<_>, ApiError>>()?;

            let deleting = status == "deleting";
            let can_cancel = deleting
                && role == "owner"
                && purge_after.is_some_and(|deadline| deadline > Utc::now().timestamp());
            vaults.push(json!({
                "vault_id": vault_id,
                "role": role,
                "status": status,
                "requested_at": requested_at.and_then(format_epoch_timestamp),
                "purge_after": purge_after.and_then(format_epoch_timestamp),
                "can_cancel": can_cancel,
                "can_write": !deleting && role != "viewer",
                "active_key_epoch": row.try_get::<i64, _>("active_epoch").map_err(ApiError::internal)?,
                "membership_version": row.try_get::<i64, _>("membership_version").map_err(ApiError::internal)?,
                "required_record_schema": row.try_get::<i16, _>("required_record_schema").map_err(ApiError::internal)?,
                "name_envelope": row.try_get::<Option<String>, _>("name_envelope").map_err(ApiError::internal)?.map(parse_json_or_null).unwrap_or(Value::Null),
                "key_envelopes": key_envelopes,
            }));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({"vaults": vaults}))
    }

    /// Returns the authorized Vault roster and the latest unaccepted,
    /// device-bound invitation for each invited member. Invitation status is
    /// derived from the current Vault epoch and membership version, matching
    /// the SQLite projection without exposing the token or key envelope.
    pub(crate) async fn vault_members(
        &self,
        user: &AuthUser,
        vault_id: &str,
    ) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        self.require_active_vault_member(&mut tx, &user.user_id, vault_id)
            .await?;

        let rows = sqlx::query(
            "SELECT vm.user_id,u.username,vm.role,vm.state,vm.added_at,\
                    v.active_epoch,v.membership_version,\
                    invitation.issuance_order AS invitation_issuance_order,\
                    invitation.created_at AS invitation_created_at,\
                    invitation.expires_at AS invitation_expires_at,\
                    invitation.key_envelope::text AS invitation_key_envelope,\
                    invitation_device.status AS invitation_recipient_device_status \
             FROM vault_members vm \
             JOIN users u ON u.user_id=vm.user_id \
             JOIN vaults v ON v.vault_id=vm.vault_id \
             LEFT JOIN invitations invitation ON invitation.invitation_id=( \
                 SELECT candidate.invitation_id FROM invitations candidate \
                 WHERE candidate.vault_id=vm.vault_id \
                   AND candidate.recipient_user_id=vm.user_id \
                   AND vm.state='invited' \
                   AND candidate.accepted_at IS NULL \
                 ORDER BY candidate.issuance_order DESC NULLS LAST,\
                          candidate.created_at DESC NULLS LAST,\
                          candidate.invitation_id DESC \
                 LIMIT 1 \
             ) \
             LEFT JOIN devices invitation_device \
               ON invitation_device.device_id=invitation.recipient_device_id \
              AND invitation_device.user_id=vm.user_id \
             WHERE vm.vault_id=$1 \
             ORDER BY vm.added_at,vm.user_id",
        )
        .bind(vault_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let now = Utc::now();
        let members = rows
            .into_iter()
            .map(|row| {
                let state: String = row.try_get("state").map_err(ApiError::internal)?;
                let invitation = if state == "invited" {
                    let issuance_order: Option<i64> = row
                        .try_get("invitation_issuance_order")
                        .map_err(ApiError::internal)?;
                    let created_at: Option<DateTime<Utc>> = row
                        .try_get("invitation_created_at")
                        .map_err(ApiError::internal)?;
                    let expires_at: Option<DateTime<Utc>> = row
                        .try_get("invitation_expires_at")
                        .map_err(ApiError::internal)?;
                    let key_envelope: Option<String> = row
                        .try_get("invitation_key_envelope")
                        .map_err(ApiError::internal)?;
                    let recipient_device_status: Option<String> = row
                        .try_get("invitation_recipient_device_status")
                        .map_err(ApiError::internal)?;
                    let active_epoch: i64 =
                        row.try_get("active_epoch").map_err(ApiError::internal)?;
                    let membership_version: i64 = row
                        .try_get("membership_version")
                        .map_err(ApiError::internal)?;
                    let status = vault_invitation_status(
                        issuance_order,
                        created_at.as_ref(),
                        expires_at.as_ref(),
                        key_envelope.as_deref(),
                        recipient_device_status.as_deref(),
                        active_epoch,
                        membership_version,
                        now,
                    );
                    let expires_at = if issuance_order.is_some()
                        && created_at.is_some()
                        && recipient_device_status.as_deref() == Some("active")
                    {
                        expires_at.map(format_timestamp)
                    } else {
                        None
                    };
                    json!({"status":status.as_str(),"expires_at":expires_at})
                } else {
                    Value::Null
                };

                Ok::<Value, ApiError>(json!({
                    "user_id": row.try_get::<String, _>("user_id").map_err(ApiError::internal)?,
                    "username": row.try_get::<String, _>("username").map_err(ApiError::internal)?,
                    "role": row.try_get::<String, _>("role").map_err(ApiError::internal)?,
                    "state": state,
                    "added_at": format_timestamp(row.try_get("added_at").map_err(ApiError::internal)?),
                    "invitation": invitation,
                }))
            })
            .collect::<Result<Vec<_>, ApiError>>()?;

        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({"members": members}))
    }

    pub(crate) async fn vault_devices(
        &self,
        user: &AuthUser,
        vault_id: &str,
    ) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        self.require_active_vault_member(&mut tx, &user.user_id, vault_id)
            .await?;

        let rows = sqlx::query(
            r#"
            WITH live_devices AS (
                SELECT DISTINCT d.device_id,d.user_id,d.name,d.signing_public_key,
                       d.encryption_public_key,d.status,d.created_at,vm.state AS membership_status,
                       r.revision AS cap_revision,r.user_id AS cap_account_id,
                       r.device_id AS cap_device_id,r.max_record_schema AS cap_max_record_schema,
                       r.host_attachment_manifest_versions::text AS cap_attachment_versions,
                       r.max_attachment_bytes AS cap_max_attachment_bytes,r.signature AS cap_signature,
                       rr.revision AS redaction_cap_revision,
                       rr.account_id AS redaction_cap_account_id,
                       rr.device_id AS redaction_cap_device_id,
                       rr.sync_redaction_version AS redaction_cap_version,
                       rr.signature AS redaction_cap_signature,
                       rr.invalidated_at AS redaction_cap_invalidated_at
                FROM vault_members self_vm
                JOIN vaults self_v ON self_v.vault_id=self_vm.vault_id
                JOIN vault_members vm ON vm.vault_id=self_vm.vault_id
                JOIN users u ON u.user_id=vm.user_id
                JOIN devices d ON d.user_id=vm.user_id
                LEFT JOIN device_capability_reports r ON r.device_id=d.device_id
                     AND r.user_id=d.user_id AND vm.state='active' AND d.status='active'
                LEFT JOIN device_redaction_capability_reports rr ON rr.device_id=d.device_id
                     AND rr.account_id=d.user_id AND vm.state='active' AND d.status='active'
                WHERE self_vm.vault_id=$1 AND self_vm.user_id=$2 AND self_vm.state='active'
                  AND self_v.state IN ('active','deleting')
            ), archived_devices AS (
                SELECT a.device_id,a.user_id,'Archived device'::TEXT AS name,
                       a.signing_public_key,a.encryption_public_key,'archived'::TEXT AS status,
                       a.archived_at AS created_at,'archived'::TEXT AS membership_status,
                       NULL::BIGINT AS cap_revision,NULL::TEXT AS cap_account_id,
                       NULL::TEXT AS cap_device_id,NULL::SMALLINT AS cap_max_record_schema,
                       NULL::TEXT AS cap_attachment_versions,NULL::BIGINT AS cap_max_attachment_bytes,
                       NULL::TEXT AS cap_signature,
                       NULL::BIGINT AS redaction_cap_revision,
                       NULL::TEXT AS redaction_cap_account_id,
                       NULL::TEXT AS redaction_cap_device_id,
                       NULL::BIGINT AS redaction_cap_version,
                       NULL::TEXT AS redaction_cap_signature,
                       NULL::TIMESTAMPTZ AS redaction_cap_invalidated_at
                FROM vault_device_archives a
                WHERE a.vault_id=$1 AND NOT EXISTS (
                    SELECT 1 FROM devices d WHERE d.device_id=a.device_id
                )
            )
            SELECT * FROM live_devices
            UNION ALL
            SELECT * FROM archived_devices
            ORDER BY created_at,device_id
            "#,
        )
        .bind(vault_id)
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut devices = Vec::with_capacity(rows.len());
        for row in rows {
            devices.push(json!({
                "device_id": row.try_get::<String, _>("device_id").map_err(ApiError::internal)?,
                "user_id": row.try_get::<String, _>("user_id").map_err(ApiError::internal)?,
                "name": row.try_get::<String, _>("name").map_err(ApiError::internal)?,
                "signing_public_key": row.try_get::<String, _>("signing_public_key").map_err(ApiError::internal)?,
                "encryption_public_key": row.try_get::<String, _>("encryption_public_key").map_err(ApiError::internal)?,
                "status": row.try_get::<String, _>("status").map_err(ApiError::internal)?,
                "membership_status": row.try_get::<String, _>("membership_status").map_err(ApiError::internal)?,
                "created_at": format_timestamp(row.try_get("created_at").map_err(ApiError::internal)?),
                "capability_report": capability_report_from_row(&row)?,
                "redaction_capability_report": redaction_capability_report_from_row(&row)?,
            }));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({"devices": devices}))
    }

    pub(crate) async fn membership(
        &self,
        user: &AuthUser,
        vault_id: &str,
        from: i64,
    ) -> Result<Value, ApiError> {
        let mut tx = self.begin_active_read(user).await?;
        self.require_active_vault_member(&mut tx, &user.user_id, vault_id)
            .await?;
        let rows = sqlx::query(
            "SELECT membership_version,previous_digest,manifest_json::text AS manifest_json,digest,\
                    signer_device_id,signature,created_at \
             FROM membership_manifests \
             WHERE vault_id=$1 AND membership_version>$2 \
               AND EXISTS (SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
                           WHERE vm.vault_id=$1 AND vm.user_id=$3 AND vm.state='active' \
                             AND v.state IN ('active','deleting')) \
             ORDER BY membership_version",
        )
        .bind(vault_id)
        .bind(from.max(0))
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let mut manifests = Vec::with_capacity(rows.len());
        for row in rows {
            let version: i64 = row
                .try_get("membership_version")
                .map_err(ApiError::internal)?;
            let previous_digest: Option<String> =
                row.try_get("previous_digest").map_err(ApiError::internal)?;
            let stored: String = row.try_get("manifest_json").map_err(ApiError::internal)?;
            let signature: String = row.try_get("signature").map_err(ApiError::internal)?;
            let stored_value: Value = serde_json::from_str(&stored).map_err(ApiError::internal)?;
            let manifest = stored_value.get("manifest").ok_or_else(|| {
                ApiError::internal("stored membership record is missing manifest")
            })?;
            let signed_record = crate::auth::signed_membership_record_value(
                vault_id,
                Value::from(version),
                previous_digest
                    .clone()
                    .map(Value::String)
                    .unwrap_or(Value::Null),
                manifest,
                &signature,
            )?;
            manifests.push(json!({
                "membership_version": version,
                "previous_digest": previous_digest,
                "manifest": signed_record,
                "digest": row.try_get::<String, _>("digest").map_err(ApiError::internal)?,
                "signer_device_id": row.try_get::<String, _>("signer_device_id").map_err(ApiError::internal)?,
                "signature": signature,
                "created_at": format_timestamp(row.try_get("created_at").map_err(ApiError::internal)?),
            }));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({"manifests": manifests}))
    }

    async fn begin_active_read(
        &self,
        user: &AuthUser,
    ) -> Result<Transaction<'_, Postgres>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let active_session: Option<String> = sqlx::query_scalar(
            "SELECT s.session_id FROM sessions s \
             JOIN users u ON u.user_id=s.user_id \
             JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
             WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4 \
               AND s.revoked_at IS NULL AND s.access_expires_at>CURRENT_TIMESTAMP \
               AND u.status='active' AND d.status='active' \
             FOR SHARE OF s,u,d",
        )
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if active_session.is_none() {
            return Err(ApiError::unauthorized());
        }
        Ok(tx)
    }

    async fn require_active_vault_member(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user_id: &str,
        vault_id: &str,
    ) -> Result<(), ApiError> {
        // Writers serialize Vault lifecycle and membership changes in this
        // order. Lock the Vault before its member row to keep reads from
        // inverting that order against an invitation/rotation transaction.
        let vault_state: Option<String> =
            sqlx::query_scalar("SELECT state FROM vaults WHERE vault_id=$1 FOR SHARE")
                .bind(vault_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
        if !matches!(vault_state.as_deref(), Some("active" | "deleting")) {
            return Err(ApiError::not_found());
        }
        let membership: Option<String> = sqlx::query_scalar(
            "SELECT role FROM vault_members \
             WHERE vault_id=$1 AND user_id=$2 AND state='active' FOR SHARE",
        )
        .bind(vault_id)
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        membership.map(|_| ()).ok_or_else(ApiError::not_found)
    }
}

fn parse_json_or_null(value: String) -> Value {
    serde_json::from_str(&value).unwrap_or(Value::Null)
}

fn format_timestamp(value: DateTime<Utc>) -> String {
    value.to_rfc3339_opts(SecondsFormat::AutoSi, true)
}

fn format_epoch_timestamp(value: i64) -> Option<String> {
    DateTime::<Utc>::from_timestamp(value, 0).map(format_timestamp)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum VaultInvitationStatus {
    Pending,
    Expired,
    Stale,
    ReissueRequired,
}

impl VaultInvitationStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Expired => "expired",
            Self::Stale => "stale",
            Self::ReissueRequired => "reissue_required",
        }
    }
}

fn vault_invitation_status(
    issuance_order: Option<i64>,
    created_at: Option<&DateTime<Utc>>,
    expires_at: Option<&DateTime<Utc>>,
    key_envelope: Option<&str>,
    recipient_device_status: Option<&str>,
    active_epoch: i64,
    membership_version: i64,
    now: DateTime<Utc>,
) -> VaultInvitationStatus {
    // Without a trustworthy order/timestamp or a live bound device, the
    // invitation cannot be accepted safely and must be reissued.
    if issuance_order.is_none() || created_at.is_none() || recipient_device_status != Some("active")
    {
        return VaultInvitationStatus::ReissueRequired;
    }
    let Some(expires_at) = expires_at else {
        return VaultInvitationStatus::ReissueRequired;
    };
    // As in SQLite, expiry takes precedence over stale epoch/version data.
    if expires_at <= &now {
        return VaultInvitationStatus::Expired;
    }
    let Some(key_envelope) =
        key_envelope.and_then(|value| serde_json::from_str::<Value>(value).ok())
    else {
        return VaultInvitationStatus::ReissueRequired;
    };
    let Some(key_epoch) = key_envelope.get("key_epoch").and_then(Value::as_i64) else {
        return VaultInvitationStatus::ReissueRequired;
    };
    let Some(invitation_membership_version) = key_envelope
        .get("membership_version")
        .and_then(Value::as_i64)
    else {
        return VaultInvitationStatus::ReissueRequired;
    };
    if key_epoch != active_epoch || invitation_membership_version != membership_version {
        return VaultInvitationStatus::Stale;
    }
    VaultInvitationStatus::Pending
}

fn capability_report_from_row(row: &sqlx::postgres::PgRow) -> Result<Value, ApiError> {
    let Some(revision) = row
        .try_get::<Option<i64>, _>("cap_revision")
        .map_err(ApiError::internal)?
    else {
        return Ok(Value::Null);
    };
    let account_id: Option<String> = row.try_get("cap_account_id").map_err(ApiError::internal)?;
    let device_id: Option<String> = row.try_get("cap_device_id").map_err(ApiError::internal)?;
    let max_record_schema: Option<i16> = row
        .try_get("cap_max_record_schema")
        .map_err(ApiError::internal)?;
    let attachment_versions: Option<String> = row
        .try_get("cap_attachment_versions")
        .map_err(ApiError::internal)?;
    let max_attachment_bytes: Option<i64> = row
        .try_get("cap_max_attachment_bytes")
        .map_err(ApiError::internal)?;
    let signature: Option<String> = row.try_get("cap_signature").map_err(ApiError::internal)?;
    let (
        Some(account_id),
        Some(device_id),
        Some(max_record_schema),
        Some(versions),
        Some(max_attachment_bytes),
        Some(signature),
    ) = (
        account_id,
        device_id,
        max_record_schema,
        attachment_versions,
        max_attachment_bytes,
        signature,
    )
    else {
        return Ok(Value::Null);
    };
    let Ok(versions) = serde_json::from_str::<Vec<i64>>(&versions) else {
        return Ok(Value::Null);
    };
    Ok(json!({
        "account_id": account_id,
        "device_id": device_id,
        "revision": revision,
        "max_record_schema": max_record_schema,
        "host_attachment_manifest_versions": versions,
        "max_attachment_bytes": max_attachment_bytes,
        "signature": signature,
    }))
}

fn redaction_capability_report_from_row(row: &sqlx::postgres::PgRow) -> Result<Value, ApiError> {
    let Some(revision) = row
        .try_get::<Option<i64>, _>("redaction_cap_revision")
        .map_err(ApiError::internal)?
    else {
        return Ok(Value::Null);
    };
    let account_id: Option<String> = row
        .try_get("redaction_cap_account_id")
        .map_err(ApiError::internal)?;
    let device_id: Option<String> = row
        .try_get("redaction_cap_device_id")
        .map_err(ApiError::internal)?;
    let version: Option<i64> = row
        .try_get("redaction_cap_version")
        .map_err(ApiError::internal)?;
    let signature: Option<String> = row
        .try_get("redaction_cap_signature")
        .map_err(ApiError::internal)?;
    let invalidated_at: Option<DateTime<Utc>> = row
        .try_get("redaction_cap_invalidated_at")
        .map_err(ApiError::internal)?;
    let (Some(account_id), Some(device_id), Some(version), Some(signature)) =
        (account_id, device_id, version, signature)
    else {
        return Ok(Value::Null);
    };
    Ok(json!({
        "format": crate::redaction_capabilities::REPORT_FORMAT,
        "account_id": account_id,
        "device_id": device_id,
        "revision": revision,
        "sync_redaction_version": version,
        "signature": signature,
        "invalidated_at": invalidated_at.map(format_timestamp),
    }))
}

//! PostgreSQL device revocation and signed capability-report updates.
//!
//! These are account-scoped lifecycle writes. They use the same shared
//! session/account/device/Vault rows as enrollment and sync authorization so
//! every node observes revocation and capability changes atomically.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{
    ApiError, auth, device_capabilities::DeviceCapabilityReport, pg_notifications::notify_sync_wake,
};

#[derive(Clone)]
pub(crate) struct PgDeviceLifecycleRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
}

impl PgDeviceLifecycleRepository {
    pub(crate) fn new(pool: PgPool, audit_scope_key: [u8; 32]) -> Self {
        Self {
            pool,
            audit_scope_key,
        }
    }

    pub(crate) async fn put_capability_report(
        &self,
        user: &auth::AuthUser,
        report: &DeviceCapabilityReport,
    ) -> Result<Value, ApiError> {
        if report.account_id != user.user_id || report.device_id != user.device_id {
            return Err(ApiError::bad_request(
                "INVALID_DEVICE_CAPABILITY_REPORT",
                "report must identify the current account and device",
            ));
        }
        if report.supports_v2() && !user.declares_record_schema2 {
            return Err(ApiError::conflict(
                "VAULT_CLIENT_CAPABILITY_REQUIRED",
                "a v2 capability report requires the current client to declare v2 support",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_live_session(&mut tx, user, false).await?;
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let device = sqlx::query(
            "SELECT status,signing_public_key FROM devices \
             WHERE device_id=$1 AND user_id=$2 FOR UPDATE",
        )
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
        // This authenticated write may have been dispatched from a request
        // whose auth read preceded first redaction-report publication. Recheck
        // under the device lifecycle transaction's device lock as well.
        crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(
            &mut tx, user,
        )
        .await?;
        let signing_public_key: String = device
            .try_get("signing_public_key")
            .map_err(ApiError::internal)?;
        crate::device_capabilities::validate_report(
            report,
            &user.user_id,
            &user.device_id,
            &signing_public_key,
        )?;

        let existing = sqlx::query(
            "SELECT revision,max_record_schema,host_attachment_manifest_versions::text \
                    AS host_attachment_manifest_versions,max_attachment_bytes,signature \
             FROM device_capability_reports WHERE device_id=$1 AND user_id=$2 FOR UPDATE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if let Some(row) = existing {
            let revision: i64 = row.try_get("revision").map_err(ApiError::internal)?;
            let max_record_schema: i16 = row
                .try_get("max_record_schema")
                .map_err(ApiError::internal)?;
            let versions_json: String = row
                .try_get("host_attachment_manifest_versions")
                .map_err(ApiError::internal)?;
            let max_attachment_bytes: i64 = row
                .try_get("max_attachment_bytes")
                .map_err(ApiError::internal)?;
            let signature: String = row.try_get("signature").map_err(ApiError::internal)?;
            if report.revision < revision {
                return Err(ApiError::conflict(
                    "DEVICE_CAPABILITY_REVISION_CONFLICT",
                    "device capability report revision is stale",
                ));
            }
            if report.revision == revision {
                let same_versions = serde_json::from_str::<Vec<i64>>(&versions_json)
                    .is_ok_and(|versions| versions == report.host_attachment_manifest_versions);
                if max_record_schema == report.max_record_schema as i16
                    && same_versions
                    && max_attachment_bytes == report.max_attachment_bytes
                    && signature == report.signature
                {
                    tx.commit().await.map_err(ApiError::internal)?;
                    return Ok(json!({
                        "status": "stored",
                        "already_applied": true,
                        "capability_report": report,
                    }));
                }
                return Err(ApiError::conflict(
                    "DEVICE_CAPABILITY_REVISION_CONFLICT",
                    "device capability report revision was reused with different content",
                ));
            }
        }

        if !report.supports_v2() {
            // This row lock orders a downgrade against concurrent schema-2
            // commits that raise the Vault floor. Lock every active membership
            // Vault in deterministic order, including Vaults whose floor is
            // still 1: a concurrent first schema-2 push must serialize here.
            let floors = sqlx::query(
                "SELECT v.vault_id,v.required_record_schema FROM vaults v \
                 JOIN vault_members vm ON vm.vault_id=v.vault_id \
                 WHERE vm.user_id=$1 AND vm.state='active' \
                 ORDER BY v.vault_id FOR SHARE OF v,vm",
            )
            .bind(&user.user_id)
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if floors.iter().any(|row| {
                row.try_get::<i16, _>("required_record_schema")
                    .is_ok_and(|schema| schema >= 2)
            }) {
                return Err(ApiError::conflict(
                    "DEVICE_CAPABILITY_REQUIRED",
                    "active vault memberships require schema 2, attachment manifest v2, and 1 GiB attachment support",
                ));
            }
        }

        let versions = serde_json::to_value(&report.host_attachment_manifest_versions)
            .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO device_capability_reports( \
                 device_id,user_id,revision,max_record_schema,host_attachment_manifest_versions, \
                 max_attachment_bytes,signature,updated_at \
             ) VALUES($1,$2,$3,$4,$5,$6,$7,CURRENT_TIMESTAMP) \
             ON CONFLICT(device_id) DO UPDATE SET user_id=excluded.user_id, \
                 revision=excluded.revision,max_record_schema=excluded.max_record_schema, \
                 host_attachment_manifest_versions=excluded.host_attachment_manifest_versions, \
                 max_attachment_bytes=excluded.max_attachment_bytes,signature=excluded.signature, \
                 updated_at=excluded.updated_at",
        )
        .bind(&report.device_id)
        .bind(&report.account_id)
        .bind(report.revision)
        .bind(report.max_record_schema)
        .bind(versions)
        .bind(report.max_attachment_bytes)
        .bind(&report.signature)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "stored",
            "already_applied": false,
            "capability_report": report,
        }))
    }

    pub(crate) async fn revoke_device(
        &self,
        user: &auth::AuthUser,
        target_device_id: &str,
    ) -> Result<Value, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        crate::pg_auth_lifecycle::lock_account_lifecycle(&mut tx, &user.user_id).await?;
        // Lock the acting session and every live target-device session in one
        // deterministic order before the account lock. The lifecycle fence
        // first serializes this revocation with login and refresh, then the
        // existing session→account→device→Vault order applies.
        lock_revocation_sessions(&mut tx, user, target_device_id).await?;
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let actor_device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if actor_device_status.as_deref() != Some("active") {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "current device is not active",
            ));
        }

        let target_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR UPDATE",
        )
        .bind(target_device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if target_status.as_deref() != Some("active") {
            return Err(ApiError::not_found());
        }

        sqlx::query(
            "SELECT v.vault_id FROM vaults v \
             JOIN vault_members vm ON vm.vault_id=v.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' \
               AND v.state IN ('active','deleting') \
             ORDER BY v.vault_id FOR UPDATE OF v,vm",
        )
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        let revoked_at = Utc::now();
        let changed = sqlx::query(
            "UPDATE devices SET status='revoked',revoked_at=$1 \
             WHERE device_id=$2 AND user_id=$3 AND status='active'",
        )
        .bind(revoked_at)
        .bind(target_device_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();
        if changed != 1 {
            return Err(ApiError::not_found());
        }
        // The SQLite lifecycle deletes endpoints when a device is explicitly
        // revoked. Keep the endpoint and its cascading outbox cleanup in this
        // transaction so no other node can claim it after revocation commits.
        sqlx::query(
            "DELETE FROM notification_push_endpoints \
             WHERE device_id=$1 AND user_id=$2",
        )
        .bind(target_device_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "UPDATE sessions SET revoked_at=$1 \
             WHERE user_id=$2 AND device_id=$3 AND revoked_at IS NULL",
        )
        .bind(revoked_at)
        .bind(&user.user_id)
        .bind(target_device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        self.record_device_revoked(&mut tx, user, target_device_id)
            .await?;
        // Revocation invalidates every session and notification socket bound
        // to this device, including sockets connected to peer nodes.
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "device_id": target_device_id,
            "status": "revoked",
        }))
    }

    async fn record_device_revoked(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user: &auth::AuthUser,
        device_id: &str,
    ) -> Result<(), ApiError> {
        let scope_id = crate::audit::account_scope_id(&self.audit_scope_key, &user.user_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'device.revoked','device',$4,'success',$5,'api')",
        )
        .bind(scope_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(device_id)
        .bind(Utc::now().timestamp())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        Ok(())
    }
}

async fn lock_live_session(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
    exclusive: bool,
) -> Result<(), ApiError> {
    let lock_clause = if exclusive { "FOR UPDATE" } else { "FOR SHARE" };
    let query = format!(
        "SELECT revoked_at,access_expires_at>CURRENT_TIMESTAMP AS unexpired \
         FROM sessions WHERE session_id=$1 AND user_id=$2 AND device_id=$3 \
           AND access_hash=$4 {lock_clause}"
    );
    let session = sqlx::query(&query)
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
    if session
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_some()
        || !session
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

async fn lock_revocation_sessions(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
    target_device_id: &str,
) -> Result<(), ApiError> {
    let rows = sqlx::query(
        "SELECT session_id,device_id,access_hash,revoked_at, \
                access_expires_at>CURRENT_TIMESTAMP AS unexpired \
         FROM sessions WHERE user_id=$1 \
           AND ((device_id=$2 AND revoked_at IS NULL) OR session_id=$3) \
         ORDER BY session_id FOR UPDATE",
    )
    .bind(&user.user_id)
    .bind(target_device_id)
    .bind(&user.session_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let actor = rows.iter().find(|row| {
        row.try_get::<String, _>("session_id")
            .is_ok_and(|id| id == user.session_id)
    });
    let Some(actor) = actor else {
        return Err(ApiError::unauthorized());
    };
    if actor
        .try_get::<String, _>("device_id")
        .map_err(ApiError::internal)?
        != user.device_id
        || actor
            .try_get::<String, _>("access_hash")
            .map_err(ApiError::internal)?
            != user.access_hash
        || actor
            .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
            .map_err(ApiError::internal)?
            .is_some()
        || !actor
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    Ok(())
}

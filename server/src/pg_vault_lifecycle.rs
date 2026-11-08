//! PostgreSQL Vault creation for the restricted shared-state runtime.

use chrono::Utc;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth, control::CreateVaultRequest};

#[derive(Clone)]
pub(crate) struct PgVaultLifecycleRepository {
    pool: PgPool,
    max_vaults_per_user: i64,
}

impl PgVaultLifecycleRepository {
    pub(crate) fn new(pool: PgPool, max_vaults_per_user: i64) -> Self {
        Self {
            pool,
            max_vaults_per_user,
        }
    }

    pub(crate) async fn create_vault(
        &self,
        user: &auth::AuthUser,
        request: CreateVaultRequest,
    ) -> Result<Value, ApiError> {
        let initial = auth::InitialVault {
            vault_id: request.vault_id,
            name_envelope: request.name_envelope,
            key_epoch: request
                .key_epoch
                .unwrap_or_else(|| request.key_envelope.key_epoch.clone()),
            membership_version: request
                .membership_version
                .unwrap_or_else(|| request.membership.membership_version.clone()),
            key_envelope: request.key_envelope,
            membership: request.membership,
        };

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_session(&mut tx, user).await?;
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let device = sqlx::query(
            "SELECT name,signing_public_key,encryption_public_key,status FROM devices \
             WHERE device_id=$1 AND user_id=$2 FOR SHARE",
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
        let device_input = auth::DeviceInput {
            device_id: user.device_id.clone(),
            name: device.try_get("name").map_err(ApiError::internal)?,
            signing_public_key: device
                .try_get("signing_public_key")
                .map_err(ApiError::internal)?,
            encryption_public_key: device
                .try_get("encryption_public_key")
                .map_err(ApiError::internal)?,
            signature: String::new(),
        };

        let (validated_name, manifest_digest, manifest_json) =
            auth::validate_initial_vault(&initial, &user.user_id, &device_input)?;
        let name_envelope: Value =
            serde_json::from_str(&validated_name).map_err(ApiError::internal)?;

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

        let vault_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM vaults WHERE vault_id=$1)")
                .bind(&initial.vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if vault_exists {
            return Err(ApiError::conflict(
                "VAULT_EXISTS",
                "vault identifier is already registered",
            ));
        }

        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,name_envelope,active_epoch, \
                 membership_version,created_at) \
             VALUES($1,$2,$3::jsonb,1,1,$4)",
        )
        .bind(&initial.vault_id)
        .bind(&user.user_id)
        .bind(serde_json::to_string(&name_envelope).map_err(ApiError::internal)?)
        .bind(Utc::now())
        .execute(&mut *tx)
        .await
        .map_err(|error| match error {
            sqlx::Error::Database(database) if database.is_unique_violation() => {
                ApiError::conflict("VAULT_EXISTS", "vault identifier is already registered")
            }
            other => ApiError::internal(other),
        })?;

        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,added_at) \
             VALUES($1,$2,'owner',CURRENT_TIMESTAMP)",
        )
        .bind(&initial.vault_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES($1,0)")
            .bind(&initial.vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        let key = &initial.key_envelope;
        sqlx::query(
            "INSERT INTO vault_key_envelopes( \
                 vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                 envelope_signature,signer_device_id,membership_version \
             ) VALUES($1,1,$2,$3,$4::jsonb,$5,$6,1)",
        )
        .bind(&initial.vault_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(serde_json::to_string(&key.envelope).map_err(ApiError::internal)?)
        .bind(&key.signature)
        .bind(&user.device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        sqlx::query(
            "INSERT INTO membership_manifests( \
                 vault_id,membership_version,previous_digest,manifest_json,digest, \
                 signer_device_id,signature,created_at \
             ) VALUES($1,1,NULL,$2::jsonb,$3,$4,$5,CURRENT_TIMESTAMP)",
        )
        .bind(&initial.vault_id)
        .bind(manifest_json)
        .bind(manifest_digest)
        .bind(&user.device_id)
        .bind(&initial.membership.signature)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        record_vault_created(&mut tx, user, &initial.vault_id).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "vault_id": initial.vault_id,
            "role": "owner",
            "active_key_epoch": 1,
            "membership_version": 1,
        }))
    }
}

async fn lock_active_session(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT revoked_at,access_expires_at>CURRENT_TIMESTAMP AS unexpired \
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

async fn record_vault_created(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source \
         ) VALUES('vault',$1,$2,$3,'vault.created','vault',$1,'success',$4,'api')",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(Utc::now().timestamp())
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

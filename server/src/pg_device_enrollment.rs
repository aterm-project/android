//! PostgreSQL second-device enrollment and Vault key-envelope distribution.
//!
//! The approval transaction shares account, session, device, Vault-membership,
//! envelope, capability-report, and audit state across server nodes.

use std::collections::{HashMap, HashSet};

use chrono::Utc;
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth, device_capabilities::DeviceCapabilityReport};

const MAX_DEVICE_VAULT_ENVELOPES: usize = 1000;

#[derive(Clone)]
pub(crate) struct PgDeviceEnrollmentRepository {
    pool: PgPool,
    audit_scope_key: [u8; 32],
}

impl PgDeviceEnrollmentRepository {
    pub(crate) fn new(pool: PgPool, audit_scope_key: [u8; 32]) -> Self {
        Self {
            pool,
            audit_scope_key,
        }
    }

    pub(crate) async fn register_device(
        &self,
        user: &auth::AuthUser,
        request: &auth::AddDeviceRequest,
    ) -> Result<Value, ApiError> {
        if request.approver_device_id != user.device_id {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "approver device does not match current session",
            ));
        }
        if request.vault_key_envelopes.len() > MAX_DEVICE_VAULT_ENVELOPES {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "too many vault key envelopes",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        self.lock_active_principal(&mut tx, user).await?;

        // Session-first ordering matches the shared PostgreSQL auth/write
        // fences. The account lock then makes the active-device limit atomic
        // across different approver sessions on different service nodes.
        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let approver = sqlx::query(
            "SELECT status,signing_public_key FROM devices \
             WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "approving device is unavailable"))?;
        if approver
            .try_get::<String, _>("status")
            .map_err(ApiError::internal)?
            != "active"
        {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "approving device is unavailable",
            ));
        }
        let approver_signing_key: String = approver
            .try_get("signing_public_key")
            .map_err(ApiError::internal)?;

        let device = &request.device;
        auth::validate_device(device, &user.user_id, &device.signing_public_key)?;
        if let Some(report) = request.capability_report.as_ref() {
            crate::device_capabilities::validate_report(
                report,
                &user.user_id,
                &device.device_id,
                &device.signing_public_key,
            )?;
        }
        let certificate_payload = crate::jcs(&json!({
            "account_id": user.user_id,
            "approver_device_id": request.approver_device_id,
            "device": device,
        }))?;
        auth::verify_key_signature(
            &approver_signing_key,
            &request.certificate_signature,
            &certificate_payload,
        )?;

        let active_vault_rows = sqlx::query(
            "SELECT v.vault_id,v.state,v.active_epoch,v.membership_version FROM vaults v \
             JOIN vault_members vm ON vm.vault_id=v.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' \
               AND v.state IN ('active','deleting') \
             ORDER BY v.vault_id FOR UPDATE OF v,vm",
        )
        .bind(&user.user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let mut active_vault_ids = HashSet::with_capacity(active_vault_rows.len());
        let mut active_vault_epochs = HashMap::with_capacity(active_vault_rows.len());
        for row in active_vault_rows {
            let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
            let state: String = row.try_get("state").map_err(ApiError::internal)?;
            if state == "deleting" {
                return Err(ApiError::vault_deletion_pending());
            }
            let active_epoch: i64 = row.try_get("active_epoch").map_err(ApiError::internal)?;
            let membership_version: i64 = row
                .try_get("membership_version")
                .map_err(ApiError::internal)?;
            if active_epoch <= 0 || membership_version <= 0 {
                return Err(ApiError::invalid_envelope(
                    "active vault key context is incomplete",
                ));
            }
            active_vault_epochs.insert(vault_id.clone(), (active_epoch, membership_version));
            active_vault_ids.insert(vault_id);
        }

        let active_devices: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE user_id=$1 AND status='active'")
                .bind(&user.user_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if active_devices >= auth::MAX_ACTIVE_DEVICES_PER_ACCOUNT {
            return Err(ApiError::conflict(
                "ACTIVE_DEVICE_LIMIT_REACHED",
                "account already has the maximum number of active devices",
            ));
        }

        let has_v2_floor: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM vault_members vm \
             JOIN vaults v ON v.vault_id=vm.vault_id \
             WHERE vm.user_id=$1 AND vm.state='active' AND v.required_record_schema>=2)",
        )
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if has_v2_floor
            && request
                .capability_report
                .as_ref()
                .is_none_or(|report| !report.supports_v2())
        {
            return Err(ApiError::conflict(
                "DEVICE_CAPABILITY_REQUIRED",
                "active vault memberships require schema 2, attachment manifest v2, and 1 GiB attachment support",
            ));
        }

        let source_rows = sqlx::query(
            "SELECT e.vault_id,e.epoch,e.membership_version \
             FROM vault_key_envelopes e \
             JOIN vault_members vm ON vm.vault_id=e.vault_id \
               AND vm.user_id=e.recipient_user_id \
             JOIN vaults v ON v.vault_id=e.vault_id \
             WHERE e.recipient_user_id=$1 AND e.recipient_device_id=$2 \
               AND vm.state='active' AND v.state='active' \
             ORDER BY e.vault_id,e.epoch,e.membership_version LIMIT 1001",
        )
        .bind(&user.user_id)
        .bind(&user.device_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if source_rows.len() > MAX_DEVICE_VAULT_ENVELOPES {
            return Err(ApiError::bad_request(
                "INVALID_KEY_ENVELOPES",
                "too many vault key envelopes",
            ));
        }
        let expected: HashSet<(String, i64, i64)> = source_rows
            .iter()
            .map(|row| {
                Ok::<_, ApiError>((
                    row.try_get("vault_id").map_err(ApiError::internal)?,
                    row.try_get("epoch").map_err(ApiError::internal)?,
                    row.try_get("membership_version")
                        .map_err(ApiError::internal)?,
                ))
            })
            .collect::<Result<_, _>>()?;
        let source_vault_ids = expected
            .iter()
            .map(|(vault_id, _, _)| vault_id.clone())
            .collect::<HashSet<_>>();
        if source_vault_ids != active_vault_ids {
            return Err(ApiError::invalid_envelope(
                "approving device must have a key envelope for every active vault",
            ));
        }
        let mut source_epochs = HashMap::<String, Vec<i64>>::new();
        for (vault_id, epoch, membership_version) in &expected {
            let Some((active_epoch, current_membership_version)) =
                active_vault_epochs.get(vault_id)
            else {
                return Err(ApiError::invalid_envelope(
                    "approving device key envelope references an inactive vault",
                ));
            };
            if *epoch <= 0
                || *membership_version <= 0
                || membership_version > current_membership_version
            {
                return Err(ApiError::invalid_envelope(
                    "approving device key envelope context is invalid",
                ));
            }
            let epochs = source_epochs.entry(vault_id.clone()).or_default();
            epochs.push(*epoch);
            if *epoch > *active_epoch {
                return Err(ApiError::invalid_envelope(
                    "approving device key envelope is from a future key epoch",
                ));
            }
        }
        for (vault_id, (active_epoch, _)) in &active_vault_epochs {
            let Some(epochs) = source_epochs.get_mut(vault_id) else {
                return Err(ApiError::invalid_envelope(
                    "approving device is missing a vault key epoch",
                ));
            };
            epochs.sort_unstable();
            if epochs.len() as i64 != *active_epoch
                || epochs
                    .iter()
                    .enumerate()
                    .any(|(index, epoch)| *epoch != index as i64 + 1)
            {
                return Err(ApiError::invalid_envelope(
                    "approving device must have every historical and active vault key epoch",
                ));
            }
        }

        let mut supplied = HashSet::with_capacity(request.vault_key_envelopes.len());
        for key in &request.vault_key_envelopes {
            if !key.key_epoch.is_i64() || !key.membership_version.is_i64() {
                return Err(ApiError::invalid_envelope(
                    "vault key envelope context is invalid",
                ));
            }
            let Some(epoch) = auth::as_counter(&key.key_epoch).filter(|value| *value > 0) else {
                return Err(ApiError::invalid_envelope("vault key epoch is invalid"));
            };
            let Some(membership_version) =
                auth::as_counter(&key.membership_version).filter(|value| *value > 0)
            else {
                return Err(ApiError::invalid_envelope(
                    "vault membership version is invalid",
                ));
            };
            if !crate::is_canonical_uuid(&key.vault_id) {
                return Err(ApiError::invalid_envelope(
                    "vault key envelope context is invalid",
                ));
            }
            supplied.insert((key.vault_id.clone(), epoch, membership_version));
        }
        if supplied.len() != request.vault_key_envelopes.len() || supplied != expected {
            return Err(ApiError::invalid_envelope(
                "new device envelopes must match the approver's complete vault, epoch, and membership set",
            ));
        }

        for key in &request.vault_key_envelopes {
            if key.recipient_device_id != device.device_id
                || !key.envelope.is_object()
                || key.envelope.to_string().len() > 64 * 1024
            {
                return Err(ApiError::invalid_envelope(
                    "vault key envelope target or size is invalid",
                ));
            }
            let payload = json!({
                "vault_id": key.vault_id,
                "recipient_device_id": key.recipient_device_id,
                "key_epoch": key.key_epoch,
                "membership_version": key.membership_version,
                "envelope": key.envelope,
            });
            auth::verify_key_signature(
                &approver_signing_key,
                &key.signature,
                &crate::jcs(&payload)?,
            )?;
        }

        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key, \
             encryption_public_key,status) VALUES($1,$2,$3,$4,$5,'active')",
        )
        .bind(&device.device_id)
        .bind(&user.user_id)
        .bind(&device.name)
        .bind(&device.signing_public_key)
        .bind(&device.encryption_public_key)
        .execute(&mut *tx)
        .await
        .map_err(|error| match error {
            sqlx::Error::Database(database) if database.is_unique_violation() => {
                ApiError::conflict("DEVICE_EXISTS", "device identifier is already registered")
            }
            other => ApiError::internal(other),
        })?;

        if let Some(report) = request.capability_report.as_ref() {
            insert_capability_report(&mut tx, report).await?;
        }
        for key in &request.vault_key_envelopes {
            let epoch = auth::as_counter(&key.key_epoch)
                .filter(|value| *value > 0)
                .ok_or_else(|| ApiError::invalid_envelope("vault key epoch is invalid"))?;
            let membership_version = auth::as_counter(&key.membership_version)
                .filter(|value| *value > 0)
                .ok_or_else(|| ApiError::invalid_envelope("vault membership version is invalid"))?;
            sqlx::query(
                "INSERT INTO vault_key_envelopes( \
                    vault_id,epoch,recipient_user_id,recipient_device_id,envelope, \
                    envelope_signature,signer_device_id,membership_version \
                 ) VALUES($1,$2,$3,$4,$5::jsonb,$6,$7,$8)",
            )
            .bind(&key.vault_id)
            .bind(epoch)
            .bind(&user.user_id)
            .bind(&device.device_id)
            .bind(serde_json::to_string(&key.envelope).map_err(ApiError::internal)?)
            .bind(&key.signature)
            .bind(&request.approver_device_id)
            .bind(membership_version)
            .execute(&mut *tx)
            .await
            .map_err(|error| match error {
                sqlx::Error::Database(database) if database.is_unique_violation() => {
                    ApiError::conflict(
                        "KEY_ENVELOPE_EXISTS",
                        "key envelope already exists for this device",
                    )
                }
                other => ApiError::internal(other),
            })?;
        }

        self.record_device_registered(&mut tx, user, &device.device_id)
            .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "device_id": device.device_id,
            "status": "active",
            "vault_key_envelope_count": request.vault_key_envelopes.len(),
        }))
    }

    async fn lock_active_principal(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        user: &auth::AuthUser,
    ) -> Result<(), ApiError> {
        let session = sqlx::query(
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
        if session
            .try_get::<Option<chrono::DateTime<Utc>>, _>("revoked_at")
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

    async fn record_device_registered(
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
             ) VALUES('account',$1,$2,$3,'device.registered','device',$4,'success',$5,'api')",
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

async fn insert_capability_report(
    tx: &mut Transaction<'_, Postgres>,
    report: &DeviceCapabilityReport,
) -> Result<(), ApiError> {
    let versions = serde_json::to_value(&report.host_attachment_manifest_versions)
        .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO device_capability_reports( \
             device_id,user_id,revision,max_record_schema,host_attachment_manifest_versions, \
             max_attachment_bytes,signature,updated_at \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,CURRENT_TIMESTAMP)",
    )
    .bind(&report.device_id)
    .bind(&report.account_id)
    .bind(report.revision)
    .bind(report.max_record_schema)
    .bind(versions)
    .bind(report.max_attachment_bytes)
    .bind(&report.signature)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey};
    use serde_json::{Value, json};
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const CORE: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const INSTANCE: &str = include_str!("../migrations/postgres/0003_instance_meta.sql");
    const AUTH: &str = include_str!("../migrations/postgres/0009_auth_lifecycle.sql");
    const ONBOARDING: &str = include_str!("../migrations/postgres/0010_account_onboarding.sql");

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL enrollment test requires ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing PostgreSQL tests outside an explicitly disposable database"
            );
            assert!(!matches!(
                database.as_str(),
                "postgres" | "template0" | "template1"
            ));

            let admin_pool = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(options.clone())
                .await
                .expect("connect to explicitly disposable PostgreSQL test database");
            let schema = format!("atermius_pg_enrollment_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL enrollment schema");
            let pool = match PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
            {
                Ok(pool) => pool,
                Err(error) => {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                    panic!("connect to isolated PostgreSQL enrollment schema: {error}");
                }
            };

            for migration in [CORE, INSTANCE, AUTH, ONBOARDING] {
                if let Err(error) = sqlx::raw_sql(migration).execute(&pool).await {
                    pool.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                    panic!("apply PostgreSQL enrollment schema: {error}");
                }
            }
            Self {
                pool,
                admin_pool,
                schema,
                cleaned: false,
            }
        }

        async fn cleanup(&mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL enrollment schema");
            self.admin_pool.close().await;
            self.cleaned = true;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let pool = self.pool.clone();
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    pool.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                });
            }
        }
    }

    fn sign_json(key: &SigningKey, value: &Value) -> String {
        let bytes = crate::jcs(value).expect("canonical JSON");
        URL_SAFE_NO_PAD.encode(key.sign(&bytes).to_bytes())
    }

    fn enrollment_request(
        user_id: &str,
        approver_device_id: &str,
        vault_id: &str,
        approver_key: &SigningKey,
        target_device_id: &str,
        epochs: &[i64],
    ) -> auth::AddDeviceRequest {
        let target_key = SigningKey::from_bytes(&[11; 32]);
        let signing_public_key = URL_SAFE_NO_PAD.encode(target_key.verifying_key().as_bytes());
        let encryption_public_key = URL_SAFE_NO_PAD.encode([13; 32]);
        let device_proof = json!({
            "account_id": user_id,
            "device_id": target_device_id,
            "encryption_public_key": encryption_public_key,
            "signing_public_key": signing_public_key,
        });
        let device = auth::DeviceInput {
            device_id: target_device_id.into(),
            name: "new device".into(),
            signing_public_key,
            encryption_public_key,
            signature: sign_json(&target_key, &device_proof),
        };
        let certificate_payload = json!({
            "account_id": user_id,
            "approver_device_id": approver_device_id,
            "device": serde_json::to_value(&device).expect("serialize device certificate"),
        });
        let vault_key_envelopes = epochs
            .iter()
            .map(|epoch| {
                let envelope = json!({
                    "version": 1,
                    "suite": "crypto_box_seal",
                    "ciphertext": URL_SAFE_NO_PAD.encode([*epoch as u8; 48]),
                });
                let key_payload = json!({
                    "vault_id": vault_id,
                    "recipient_device_id": target_device_id,
                    "key_epoch": epoch,
                    "membership_version": 1,
                    "envelope": envelope,
                });
                auth::DeviceVaultEnvelope {
                    vault_id: vault_id.into(),
                    recipient_device_id: target_device_id.into(),
                    key_epoch: json!(epoch),
                    membership_version: json!(1),
                    envelope,
                    signature: sign_json(approver_key, &key_payload),
                }
            })
            .collect();
        auth::AddDeviceRequest {
            device,
            approver_device_id: approver_device_id.into(),
            certificate_signature: sign_json(approver_key, &certificate_payload),
            vault_key_envelopes,
            capability_report: None,
        }
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL second-device enrollment acceptance; requires a disposable ATERMIUS_TEST_PG_URL"]
    async fn enrollment_rejects_missing_historical_epoch_then_accepts_complete_set() {
        let mut database = TestDatabase::create().await;
        let user_id = Uuid::new_v4().to_string();
        let approver_device_id = Uuid::new_v4().to_string();
        let target_device_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access_hash = "pg-enrollment-test-access-hash";
        let approver_key = SigningKey::from_bytes(&[7; 32]);
        let approver_signing_key = URL_SAFE_NO_PAD.encode(approver_key.verifying_key().as_bytes());
        let approver_encryption_key = URL_SAFE_NO_PAD.encode([17; 32]);

        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(&user_id)
            .bind(format!("{user_id}@example.test"))
            .execute(&database.pool)
            .await
            .expect("insert test account");
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status) \
             VALUES($1,$2,'approver',$3,$4,'active')",
        )
        .bind(&approver_device_id)
        .bind(&user_id)
        .bind(&approver_signing_key)
        .bind(&approver_encryption_key)
        .execute(&database.pool)
        .await
        .expect("insert approver device");
        sqlx::query(
            "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash, \
             access_expires_at,refresh_expires_at) \
             VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP + INTERVAL '1 hour', \
             CURRENT_TIMESTAMP + INTERVAL '30 days')",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&approver_device_id)
        .bind(access_hash)
        .bind(Uuid::new_v4().to_string())
        .execute(&database.pool)
        .await
        .expect("insert active approver session");
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) \
             VALUES($1,$2,'active',2,1)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .execute(&database.pool)
        .await
        .expect("insert active Vault at epoch two");
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) \
             VALUES($1,$2,'owner','active')",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .execute(&database.pool)
        .await
        .expect("insert active Vault membership");
        sqlx::query(
            "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id, \
             envelope,envelope_signature,signer_device_id,membership_version) \
             VALUES($1,2,$2,$3,'{}'::jsonb,'source-signature',$3,1)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&approver_device_id)
        .execute(&database.pool)
        .await
        .expect("insert current epoch without historical epoch one");

        let user = auth::AuthUser {
            user_id: user_id.clone(),
            device_id: approver_device_id.clone(),
            session_id,
            access_hash: access_hash.into(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let repository = PgDeviceEnrollmentRepository::new(database.pool.clone(), [0x91; 32]);
        let incomplete = enrollment_request(
            &user_id,
            &approver_device_id,
            &vault_id,
            &approver_key,
            &target_device_id,
            &[2],
        );
        let error = repository
            .register_device(&user, &incomplete)
            .await
            .expect_err("missing historical epoch must reject enrollment");
        assert_eq!(error.status, axum::http::StatusCode::UNPROCESSABLE_ENTITY);
        assert_eq!(error.body.code, "INVALID_ENVELOPE");
        let rejected_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id=$1 AND user_id=$2")
                .bind(&target_device_id)
                .bind(&user_id)
                .fetch_one(&database.pool)
                .await
                .expect("count rejected target device");
        assert_eq!(
            rejected_count, 0,
            "rejected registration leaves no device row"
        );

        sqlx::query(
            "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id, \
             envelope,envelope_signature,signer_device_id,membership_version) \
             VALUES($1,1,$2,$3,'{}'::jsonb,'source-signature',$3,1)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&approver_device_id)
        .execute(&database.pool)
        .await
        .expect("restore source device historical epoch one");
        let complete = enrollment_request(
            &user_id,
            &approver_device_id,
            &vault_id,
            &approver_key,
            &target_device_id,
            &[1, 2],
        );
        let result = repository
            .register_device(&user, &complete)
            .await
            .expect("complete historical epoch set registers the device");
        assert_eq!(result["device_id"], target_device_id);
        assert_eq!(result["vault_key_envelope_count"], 2);
        let inserted_envelopes: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM vault_key_envelopes \
             WHERE recipient_device_id=$1 AND recipient_user_id=$2",
        )
        .bind(&target_device_id)
        .bind(&user_id)
        .fetch_one(&database.pool)
        .await
        .expect("count target device Vault envelopes");
        assert_eq!(inserted_envelopes, 2);
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE actor_user_id=$1 \
             AND action='device.registered' AND resource_id=$2",
        )
        .bind(&user_id)
        .bind(&target_device_id)
        .fetch_one(&database.pool)
        .await
        .expect("count device registration audit");
        assert_eq!(audit_count, 1);

        database.cleanup().await;
    }
}

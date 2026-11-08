use crate::auth::AuthUser;
use crate::{ApiError, AppState, auth, current_user, jcs, now_rfc3339};
use axum::{Json, extract::State, http::HeaderMap};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};

const MAX_RECORD_SCHEMA: i64 = 2;
const MAX_ATTACHMENT_BYTES: i64 = 1024 * 1024 * 1024;
const SUPPORTED_ATTACHMENT_MANIFEST_VERSIONS: [i64; 2] = [1, 2];

/// A v1/missing transport marker invalidates only a stored report that asserts
/// the complete v2 reader capability. It never creates or upgrades a report.
pub(crate) async fn has_v2_report(
    db: &SqlitePool,
    account_id: &str,
    device_id: &str,
) -> Result<bool, ApiError> {
    let exists: i64 = sqlx::query_scalar(
        r#"SELECT EXISTS(SELECT 1 FROM device_capability_reports r
         WHERE r.device_id=? AND r.user_id=? AND r.max_record_schema>=2
           AND r.max_attachment_bytes>=1073741824
           AND EXISTS (SELECT 1 FROM json_each(r.host_attachment_manifest_versions)
                       WHERE type='integer' AND value=2))"#,
    )
    .bind(device_id)
    .bind(account_id)
    .fetch_one(db)
    .await
    .map_err(ApiError::internal)?;
    Ok(exists != 0)
}

pub(crate) async fn delete_v2_report_for_device_tx(
    tx: &mut Transaction<'_, Sqlite>,
    account_id: &str,
    device_id: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        r#"DELETE FROM device_capability_reports
         WHERE device_id=? AND user_id=? AND max_record_schema>=2
           AND max_attachment_bytes>=1073741824
           AND EXISTS (SELECT 1 FROM json_each(host_attachment_manifest_versions)
                       WHERE type='integer' AND value=2)"#,
    )
    .bind(device_id)
    .bind(account_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DeviceCapabilityReport {
    pub account_id: String,
    pub device_id: String,
    pub revision: i64,
    pub max_record_schema: i64,
    pub host_attachment_manifest_versions: Vec<i64>,
    pub max_attachment_bytes: i64,
    pub signature: String,
}

impl DeviceCapabilityReport {
    fn signed_payload(&self) -> Value {
        json!({
            "account_id": self.account_id,
            "device_id": self.device_id,
            "revision": self.revision,
            "max_record_schema": self.max_record_schema,
            "host_attachment_manifest_versions": self.host_attachment_manifest_versions,
            "max_attachment_bytes": self.max_attachment_bytes,
        })
    }

    pub(crate) fn supports_v2(&self) -> bool {
        self.max_record_schema >= 2
            && self.host_attachment_manifest_versions.contains(&2)
            && self.max_attachment_bytes >= MAX_ATTACHMENT_BYTES
    }
}

pub(crate) fn validate_report(
    report: &DeviceCapabilityReport,
    account_id: &str,
    device_id: &str,
    signing_public_key: &str,
) -> Result<(), ApiError> {
    if report.account_id != account_id
        || report.device_id != device_id
        || !crate::is_canonical_uuid(&report.account_id)
        || !crate::is_canonical_uuid(&report.device_id)
        || report.revision <= 0
        || !(1..=MAX_RECORD_SCHEMA).contains(&report.max_record_schema)
        || !(0..=MAX_ATTACHMENT_BYTES).contains(&report.max_attachment_bytes)
        || report.host_attachment_manifest_versions.is_empty()
        || report.host_attachment_manifest_versions.len()
            > SUPPORTED_ATTACHMENT_MANIFEST_VERSIONS.len()
        || report
            .host_attachment_manifest_versions
            .iter()
            .any(|version| !SUPPORTED_ATTACHMENT_MANIFEST_VERSIONS.contains(version))
        || report
            .host_attachment_manifest_versions
            .windows(2)
            .any(|pair| pair[0] >= pair[1])
    {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE_CAPABILITY_REPORT",
            "device capability report fields are invalid",
        ));
    }
    auth::verify_key_signature(
        signing_public_key,
        &report.signature,
        &jcs(&report.signed_payload())?,
    )
}

pub(crate) async fn insert_report_tx(
    tx: &mut Transaction<'_, Sqlite>,
    report: &DeviceCapabilityReport,
    now: &str,
) -> Result<(), ApiError> {
    let versions = serde_json::to_string(&report.host_attachment_manifest_versions)
        .map_err(ApiError::internal)?;
    sqlx::query(
        r#"INSERT INTO device_capability_reports(device_id,user_id,revision,max_record_schema,
         host_attachment_manifest_versions,max_attachment_bytes,signature,updated_at)
         VALUES(?,?,?,?,?,?,?,?)"#,
    )
    .bind(&report.device_id)
    .bind(&report.account_id)
    .bind(report.revision)
    .bind(report.max_record_schema)
    .bind(versions)
    .bind(report.max_attachment_bytes)
    .bind(&report.signature)
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

/// Returns false if any active device belonging to an active member is
/// missing a current verified report with both v2 capabilities. Reports are
/// verified when written, and this helper is called under the vault writer
/// reservation so membership, enrollment, reports, and the v2 commit serialize.
pub(crate) async fn all_active_vault_devices_support_v2_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
) -> Result<bool, ApiError> {
    let incompatible: i64 = sqlx::query_scalar(
        r#"SELECT EXISTS(
           SELECT 1 FROM vault_members vm
           JOIN devices d ON d.user_id=vm.user_id AND d.status='active'
           LEFT JOIN device_capability_reports r
             ON r.device_id=d.device_id AND r.user_id=d.user_id
           WHERE vm.vault_id=? AND vm.state='active'
             AND (r.device_id IS NULL OR r.max_record_schema<2
               OR r.max_attachment_bytes<1073741824
               OR NOT EXISTS (
                 SELECT 1 FROM json_each(r.host_attachment_manifest_versions)
                 WHERE type='integer' AND value=2
               ))
         )"#,
    )
    .bind(vault_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(incompatible == 0)
}

pub(crate) async fn all_active_user_devices_support_v2_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<bool, ApiError> {
    let incompatible: i64 = sqlx::query_scalar(
        r#"SELECT EXISTS(
           SELECT 1 FROM users u
           JOIN devices d ON d.user_id=u.user_id AND d.status='active'
           LEFT JOIN device_capability_reports r
             ON r.device_id=d.device_id AND r.user_id=d.user_id
           WHERE u.user_id=? AND u.status='active'
             AND (r.device_id IS NULL OR r.max_record_schema<2
               OR r.max_attachment_bytes<1073741824
               OR NOT EXISTS (
                 SELECT 1 FROM json_each(r.host_attachment_manifest_versions)
                 WHERE type='integer' AND value=2
               ))
         )"#,
    )
    .bind(user_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(incompatible == 0)
}

pub(crate) fn report_from_row(row: &sqlx::sqlite::SqliteRow) -> Value {
    let revision: Option<i64> = row.get("cap_revision");
    let (
        Some(revision),
        Some(account_id),
        Some(device_id),
        Some(max_schema),
        Some(versions_json),
        Some(max_attachment_bytes),
        Some(signature),
    ) = (
        revision,
        row.try_get::<Option<String>, _>("cap_account_id")
            .ok()
            .flatten(),
        row.try_get::<Option<String>, _>("cap_device_id")
            .ok()
            .flatten(),
        row.try_get::<Option<i64>, _>("cap_max_record_schema")
            .ok()
            .flatten(),
        row.try_get::<Option<String>, _>("cap_attachment_versions")
            .ok()
            .flatten(),
        row.try_get::<Option<i64>, _>("cap_max_attachment_bytes")
            .ok()
            .flatten(),
        row.try_get::<Option<String>, _>("cap_signature")
            .ok()
            .flatten(),
    )
    else {
        return Value::Null;
    };
    let Ok(versions) = serde_json::from_str::<Vec<i64>>(&versions_json) else {
        return Value::Null;
    };
    json!({
        "account_id": account_id,
        "device_id": device_id,
        "revision": revision,
        "max_record_schema": max_schema,
        "host_attachment_manifest_versions": versions,
        "max_attachment_bytes": max_attachment_bytes,
        "signature": signature,
    })
}

pub(crate) async fn ensure_report_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &AuthUser,
    report: &DeviceCapabilityReport,
) -> Result<bool, ApiError> {
    let row = sqlx::query(
        r#"SELECT revision,max_record_schema,host_attachment_manifest_versions,max_attachment_bytes,signature
         FROM device_capability_reports WHERE device_id=? AND user_id=?"#,
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if let Some(row) = row {
        let old_revision: i64 = row.get("revision");
        let old_schema: i64 = row.get("max_record_schema");
        let old_versions: String = row.get("host_attachment_manifest_versions");
        let old_max_attachment_bytes: i64 = row.get("max_attachment_bytes");
        let old_signature: String = row.get("signature");
        if report.revision < old_revision {
            return Err(ApiError::conflict(
                "DEVICE_CAPABILITY_REVISION_CONFLICT",
                "device capability report revision is stale",
            ));
        }
        if report.revision == old_revision {
            let same_versions = serde_json::from_str::<Vec<i64>>(&old_versions)
                .is_ok_and(|versions| versions == report.host_attachment_manifest_versions);
            if old_schema == report.max_record_schema
                && same_versions
                && old_max_attachment_bytes == report.max_attachment_bytes
                && old_signature == report.signature
            {
                return Ok(true);
            }
            return Err(ApiError::conflict(
                "DEVICE_CAPABILITY_REVISION_CONFLICT",
                "device capability report revision was reused with different content",
            ));
        }
    }
    Ok(false)
}

pub async fn put_device_capability_report(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(report): Json<DeviceCapabilityReport>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if report.account_id != user.user_id || report.device_id != user.device_id {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE_CAPABILITY_REPORT",
            "report must identify the current account and device",
        ));
    }
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return Ok(Json(
            repository
                .put_device_capability_report(&user, &report)
                .await?,
        ));
    }
    let public: String = sqlx::query_scalar(
        "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
    validate_report(&report, &user.user_id, &user.device_id, &public)?;
    if report.supports_v2() && !user.declares_record_schema2 {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "a v2 capability report requires the current client to declare v2 support",
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Take SQLite's writer reservation before checking the report revision or
    // vault floors. This serializes capability downgrades with v2 writes and
    // enrollment/acceptance transactions.
    sqlx::query("UPDATE devices SET status=status WHERE device_id=? AND user_id=?")
        .bind(&user.device_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let stored_public: Option<String> = sqlx::query_scalar(
        "SELECT signing_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if stored_public.as_deref() != Some(public.as_str()) {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    if ensure_report_tx(&mut tx, &user, &report).await? {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(
            json!({"status":"stored","already_applied":true,"capability_report":report}),
        ));
    }
    if !report.supports_v2() {
        let has_v2_floor: i64 = sqlx::query_scalar(
            r#"SELECT EXISTS(SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id
             WHERE vm.user_id=? AND vm.state='active' AND v.required_record_schema>=2)"#,
        )
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if has_v2_floor != 0 {
            return Err(ApiError::conflict(
                "DEVICE_CAPABILITY_REQUIRED",
                "active vault memberships require schema 2, attachment manifest v2, and 1 GiB attachment support",
            ));
        }
    }
    let versions = serde_json::to_string(&report.host_attachment_manifest_versions)
        .map_err(ApiError::internal)?;
    sqlx::query(
        r#"INSERT INTO device_capability_reports(device_id,user_id,revision,max_record_schema,
         host_attachment_manifest_versions,max_attachment_bytes,signature,updated_at) VALUES(?,?,?,?,?,?,?,?)
         ON CONFLICT(device_id) DO UPDATE SET user_id=excluded.user_id,revision=excluded.revision,
         max_record_schema=excluded.max_record_schema,
         host_attachment_manifest_versions=excluded.host_attachment_manifest_versions,
         max_attachment_bytes=excluded.max_attachment_bytes,
         signature=excluded.signature,updated_at=excluded.updated_at"#,
    )
    .bind(&report.device_id)
    .bind(&report.account_id)
    .bind(report.revision)
    .bind(report.max_record_schema)
    .bind(versions)
    .bind(report.max_attachment_bytes)
    .bind(&report.signature)
    .bind(now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"status":"stored","already_applied":false,"capability_report":report}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey};
    use sqlx::sqlite::SqlitePoolOptions;

    fn signed_report(
        account_id: &str,
        device_id: &str,
        signing_key: &SigningKey,
        max_attachment_bytes: i64,
    ) -> DeviceCapabilityReport {
        let mut report = DeviceCapabilityReport {
            account_id: account_id.to_owned(),
            device_id: device_id.to_owned(),
            revision: 1,
            max_record_schema: 2,
            host_attachment_manifest_versions: vec![1, 2],
            max_attachment_bytes,
            signature: String::new(),
        };
        report.signature = URL_SAFE_NO_PAD.encode(
            signing_key
                .sign(&jcs(&report.signed_payload()).unwrap())
                .to_bytes(),
        );
        report
    }

    #[test]
    fn report_signature_binds_fields_and_v2_requires_attachment_size() {
        let account = uuid::Uuid::from_u128(1).to_string();
        let device = uuid::Uuid::from_u128(2).to_string();
        let signing_key = SigningKey::from_bytes(&[19; 32]);
        let public = URL_SAFE_NO_PAD.encode(signing_key.verifying_key().as_bytes());
        let report = signed_report(&account, &device, &signing_key, MAX_ATTACHMENT_BYTES);
        validate_report(&report, &account, &device, &public).unwrap();
        assert!(report.supports_v2());

        let mut tampered = report.clone();
        tampered.max_attachment_bytes -= 1;
        assert_eq!(
            validate_report(&tampered, &account, &device, &public)
                .unwrap_err()
                .body
                .code,
            "INVALID_ENVELOPE"
        );
        let too_small = signed_report(&account, &device, &signing_key, MAX_ATTACHMENT_BYTES - 1);
        assert!(!too_small.supports_v2());

        let mut unsorted = report.clone();
        unsorted.host_attachment_manifest_versions = vec![2, 1];
        unsorted.signature = URL_SAFE_NO_PAD.encode(
            signing_key
                .sign(&jcs(&unsorted.signed_payload()).unwrap())
                .to_bytes(),
        );
        assert_eq!(
            validate_report(&unsorted, &account, &device, &public)
                .unwrap_err()
                .body
                .code,
            "INVALID_DEVICE_CAPABILITY_REPORT"
        );

        let mut unknown = serde_json::to_value(&report).unwrap();
        unknown["platform"] = json!("unknown");
        assert!(serde_json::from_value::<DeviceCapabilityReport>(unknown).is_err());
    }

    #[tokio::test]
    async fn v2_gate_requires_every_active_vault_reader_and_ignores_revoked_devices() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let created = now_rfc3339();
        let user_a = uuid::Uuid::from_u128(11).to_string();
        let user_b = uuid::Uuid::from_u128(12).to_string();
        let device_a = uuid::Uuid::from_u128(21).to_string();
        let device_b = uuid::Uuid::from_u128(22).to_string();
        let vault = uuid::Uuid::from_u128(31).to_string();
        for (user_id, username, device_id) in [
            (&user_a, "cap-a@example.test", &device_a),
            (&user_b, "cap-b@example.test", &device_b),
        ] {
            sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
                .bind(user_id)
                .bind(username)
                .bind(&created)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?, 'test','key','box',?)")
                .bind(device_id)
                .bind(user_id)
                .bind(&created)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&user_a)
            .bind(&created)
            .execute(&pool)
            .await
            .unwrap();
        for user_id in [&user_a, &user_b] {
            sqlx::query(
                "INSERT INTO vault_members(vault_id,user_id,role,added_at) VALUES(?,?,'editor',?)",
            )
            .bind(&vault)
            .bind(user_id)
            .bind(&created)
            .execute(&pool)
            .await
            .unwrap();
        }

        let mut tx = pool.begin().await.unwrap();
        assert!(
            !all_active_vault_devices_support_v2_tx(&mut tx, &vault)
                .await
                .unwrap()
        );
        tx.commit().await.unwrap();

        for (user_id, device_id) in [(&user_a, &device_a), (&user_b, &device_b)] {
            sqlx::query("INSERT INTO device_capability_reports(device_id,user_id,revision,max_record_schema,host_attachment_manifest_versions,max_attachment_bytes,signature,updated_at) VALUES(?,?,1,2,'[1,2]',1073741824,'signed',?)")
                .bind(device_id)
                .bind(user_id)
                .bind(&created)
                .execute(&pool)
                .await
                .unwrap();
        }
        let mut tx = pool.begin().await.unwrap();
        assert!(
            all_active_vault_devices_support_v2_tx(&mut tx, &vault)
                .await
                .unwrap()
        );
        assert!(
            all_active_user_devices_support_v2_tx(&mut tx, &user_b)
                .await
                .unwrap()
        );
        tx.commit().await.unwrap();

        sqlx::query(
            "UPDATE device_capability_reports SET max_attachment_bytes=268435456 WHERE device_id=?",
        )
        .bind(&device_b)
        .execute(&pool)
        .await
        .unwrap();
        let mut tx = pool.begin().await.unwrap();
        assert!(
            !all_active_vault_devices_support_v2_tx(&mut tx, &vault)
                .await
                .unwrap()
        );
        tx.commit().await.unwrap();

        sqlx::query("UPDATE devices SET status='revoked',revoked_at=? WHERE device_id=?")
            .bind(&created)
            .bind(&device_b)
            .execute(&pool)
            .await
            .unwrap();
        let mut tx = pool.begin().await.unwrap();
        assert!(
            all_active_vault_devices_support_v2_tx(&mut tx, &vault)
                .await
                .unwrap()
        );
        assert!(
            all_active_user_devices_support_v2_tx(&mut tx, &user_b)
                .await
                .unwrap()
        );
        tx.commit().await.unwrap();
    }
}

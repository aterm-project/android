//! Signed device declarations for the permanent record-redaction protocol.
//!
//! These reports are only a compatibility signal. They do not authorize
//! purging a record; purge must independently check active membership, owner
//! role, the current tombstone revision, and every active Vault device.

use axum::{Json, extract::State, http::HeaderMap};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction};

use crate::{ApiError, AppState, auth, current_sync_user, jcs, now_rfc3339};

pub(crate) const REPORT_FORMAT: &str = "atermius-sync-redaction-capability-v1";

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct RedactionCapabilityReport {
    pub format: String,
    pub account_id: String,
    pub device_id: String,
    pub revision: i64,
    pub sync_redaction_version: i64,
    pub signature: String,
}

impl RedactionCapabilityReport {
    fn signed_payload(&self) -> Value {
        json!({
            "format": self.format,
            "account_id": self.account_id,
            "device_id": self.device_id,
            "revision": self.revision,
            "sync_redaction_version": self.sync_redaction_version,
        })
    }
}

pub(crate) fn validate_report(
    report: &RedactionCapabilityReport,
    account_id: &str,
    device_id: &str,
    signing_public_key: &str,
) -> Result<(), ApiError> {
    if report.format != REPORT_FORMAT
        || report.account_id != account_id
        || report.device_id != device_id
        || !crate::is_canonical_uuid(&report.account_id)
        || !crate::is_canonical_uuid(&report.device_id)
        || !(1..=9_007_199_254_740_991).contains(&report.revision)
        || report.sync_redaction_version != 1
    {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT",
            "device redaction capability report fields are invalid",
        ));
    }
    auth::verify_key_signature(
        signing_public_key,
        &report.signature,
        &jcs(&report.signed_payload())?,
    )
    .map_err(|_| {
        ApiError::bad_request(
            "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT",
            "device redaction capability report signature is invalid",
        )
    })
}

/// Revalidates every active device report in a Vault while the caller holds
/// the Vault writer fence. A report is usable for purge only when it is still
/// active and its signature verifies against that device's current key.
pub(crate) async fn every_active_vault_device_supports_redaction_v1_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
) -> Result<bool, ApiError> {
    let rows = sqlx::query(
        "SELECT u.user_id,d.device_id,d.signing_public_key,r.revision,\
                r.sync_redaction_version,r.signature,r.invalidated_at \
         FROM vault_members vm \
         JOIN users u ON u.user_id=vm.user_id \
         JOIN devices d ON d.user_id=vm.user_id AND d.status='active' \
         LEFT JOIN device_redaction_capability_reports r \
           ON r.device_id=d.device_id AND r.user_id=u.user_id \
         WHERE vm.vault_id=? AND vm.state='active' AND u.status='active' \
         ORDER BY u.user_id,d.device_id",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    if rows.is_empty() {
        return Ok(false);
    }
    for row in rows {
        let revision = row
            .try_get::<Option<i64>, _>("revision")
            .map_err(ApiError::internal)?;
        let version = row
            .try_get::<Option<i64>, _>("sync_redaction_version")
            .map_err(ApiError::internal)?;
        let signature = row
            .try_get::<Option<String>, _>("signature")
            .map_err(ApiError::internal)?;
        let invalidated_at = row
            .try_get::<Option<String>, _>("invalidated_at")
            .map_err(ApiError::internal)?;
        let (Some(revision), Some(sync_redaction_version), Some(signature), None) =
            (revision, version, signature, invalidated_at)
        else {
            return Ok(false);
        };
        let report = RedactionCapabilityReport {
            format: REPORT_FORMAT.to_owned(),
            account_id: row.try_get("user_id").map_err(ApiError::internal)?,
            device_id: row.try_get("device_id").map_err(ApiError::internal)?,
            revision,
            sync_redaction_version,
            signature,
        };
        let public_key: String = row
            .try_get("signing_public_key")
            .map_err(ApiError::internal)?;
        if validate_report(&report, &report.account_id, &report.device_id, &public_key).is_err() {
            return Ok(false);
        }
    }
    Ok(true)
}

pub(crate) async fn put_device_redaction_capability_report(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(report): Json<RedactionCapabilityReport>,
) -> Result<Json<Value>, ApiError> {
    let user = current_sync_user(&state, &headers).await?;
    if !auth::declares_sync_redaction_v1(&headers) {
        return Err(ApiError::bad_request(
            "INVALID_REDACTION_MARKER",
            "exactly one X-Atermius-Redaction-Marker: v1 header is required",
        ));
    }
    if report.account_id != user.user_id || report.device_id != user.device_id {
        return Err(ApiError::bad_request(
            "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT",
            "report must identify the current account and device",
        ));
    }

    if let Some(pool) = state.pg_sync_pool.as_ref() {
        let public = sqlx::query_scalar::<_, String>(
            "SELECT d.signing_public_key FROM devices d JOIN users u ON u.user_id=d.user_id \
             WHERE d.user_id=$1 AND d.device_id=$2 AND d.status='active' AND u.status='active'",
        )
        .bind(&user.user_id)
        .bind(&user.device_id)
        .fetch_optional(pool)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::forbidden("DEVICE_REVOKED", "device is not active"))?;
        validate_report(&report, &user.user_id, &user.device_id, &public)?;
        let repository = state.pg_redaction_capabilities.as_ref().ok_or_else(|| {
            ApiError::internal("PostgreSQL redaction capability repository is unavailable")
        })?;
        return Ok(Json(repository.put(&user, &report).await?));
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

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Serialize report revisions with device revocation/session changes.
    sqlx::query("UPDATE devices SET status=status WHERE device_id=? AND user_id=?")
        .bind(&user.device_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let previous = sqlx::query(
        "SELECT revision,sync_redaction_version,signature,invalidated_at FROM device_redaction_capability_reports \
         WHERE device_id=? AND user_id=?",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if let Some(row) = previous {
        let old_revision: i64 = row.get("revision");
        let old_version: i64 = row.get("sync_redaction_version");
        let old_signature: String = row.get("signature");
        let invalidated_at: Option<String> = row.get("invalidated_at");
        if report.revision < old_revision {
            return Err(revision_conflict());
        }
        if report.revision == old_revision {
            if invalidated_at.is_none()
                && old_version == report.sync_redaction_version
                && old_signature == report.signature
            {
                tx.commit().await.map_err(ApiError::internal)?;
                return Ok(Json(json!({
                    "status":"stored",
                    "already_applied":true,
                    "redaction_capability_report":report,
                })));
            }
            return Err(revision_conflict());
        }
        sqlx::query(
            "UPDATE device_redaction_capability_reports SET revision=?,sync_redaction_version=?,signature=?,updated_at=?,invalidated_at=NULL \
             WHERE device_id=? AND user_id=?",
        )
        .bind(report.revision)
        .bind(report.sync_redaction_version)
        .bind(&report.signature)
        .bind(now_rfc3339())
        .bind(&user.device_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    } else {
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports(device_id,user_id,revision,sync_redaction_version,signature,updated_at) \
             VALUES(?,?,?,?,?,?)",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(report.revision)
        .bind(report.sync_redaction_version)
        .bind(&report.signature)
        .bind(now_rfc3339())
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "status":"stored",
        "already_applied":false,
        "redaction_capability_report":report,
    })))
}

fn revision_conflict() -> ApiError {
    ApiError::conflict(
        "DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT",
        "device redaction capability report revision is stale or was reused with different content",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::{Signer, SigningKey};
    use sqlx::sqlite::SqlitePoolOptions;
    use std::borrow::Cow;

    fn signed_report(
        account_id: &str,
        device_id: &str,
        key: &SigningKey,
    ) -> RedactionCapabilityReport {
        let mut report = RedactionCapabilityReport {
            format: REPORT_FORMAT.to_owned(),
            account_id: account_id.to_owned(),
            device_id: device_id.to_owned(),
            revision: 1,
            sync_redaction_version: 1,
            signature: String::new(),
        };
        report.signature =
            URL_SAFE_NO_PAD.encode(key.sign(&jcs(&report.signed_payload()).unwrap()).to_bytes());
        report
    }

    #[test]
    fn redaction_report_is_strict_and_signature_binds_version_and_revision() {
        let account = uuid::Uuid::from_u128(101).to_string();
        let device = uuid::Uuid::from_u128(102).to_string();
        let key = SigningKey::from_bytes(&[81; 32]);
        let public = URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes());
        let report = signed_report(&account, &device, &key);
        validate_report(&report, &account, &device, &public).unwrap();

        let mut changed_revision = report.clone();
        changed_revision.revision += 1;
        assert_eq!(
            validate_report(&changed_revision, &account, &device, &public)
                .unwrap_err()
                .body
                .code,
            "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT"
        );

        let mut changed_version = report.clone();
        changed_version.sync_redaction_version = 2;
        assert_eq!(
            validate_report(&changed_version, &account, &device, &public)
                .unwrap_err()
                .body
                .code,
            "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT"
        );

        let mut unknown = serde_json::to_value(&report).unwrap();
        unknown["future"] = json!(true);
        assert!(serde_json::from_value::<RedactionCapabilityReport>(unknown).is_err());
    }

    #[tokio::test]
    async fn sqlite_report_foreign_key_binds_device_to_owning_account() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        let all = sqlx::migrate!("./migrations");
        let before_composite_fk = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version < 46)
                    .cloned()
                    .collect(),
            ),
            ..sqlx::migrate::Migrator::DEFAULT
        };
        before_composite_fk.run(&pool).await.unwrap();

        let account_a = uuid::Uuid::from_u128(201).to_string();
        let account_b = uuid::Uuid::from_u128(202).to_string();
        let device_a = uuid::Uuid::from_u128(203).to_string();
        let created_at = now_rfc3339();
        for (account_id, username) in [
            (&account_a, "redaction-a@example.test"),
            (&account_b, "redaction-b@example.test"),
        ] {
            sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
                .bind(account_id)
                .bind(username)
                .bind(&created_at)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) \
             VALUES(?,?,'test','signing-key','encryption-key',?)",
        )
        .bind(&device_a)
        .bind(&account_a)
        .bind(&created_at)
        .execute(&pool)
        .await
        .unwrap();

        let invalidated_at = now_rfc3339();
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,user_id,revision,sync_redaction_version,signature,updated_at,invalidated_at \
             ) VALUES(?,?,9,1,'stored-signature',?,?)",
        )
        .bind(&device_a)
        .bind(&account_a)
        .bind(&created_at)
        .bind(&invalidated_at)
        .execute(&pool)
        .await
        .unwrap();

        let composite_fk_migration = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version == 46)
                    .cloned()
                    .collect(),
            ),
            ignore_missing: true,
            ..sqlx::migrate::Migrator::DEFAULT
        };
        composite_fk_migration.run(&pool).await.unwrap();
        let preserved = sqlx::query(
            "SELECT revision,signature,invalidated_at FROM device_redaction_capability_reports \
             WHERE device_id=? AND user_id=?",
        )
        .bind(&device_a)
        .bind(&account_a)
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(preserved.get::<i64, _>("revision"), 9);
        assert_eq!(preserved.get::<String, _>("signature"), "stored-signature");
        assert_eq!(
            preserved.get::<Option<String>, _>("invalidated_at"),
            Some(invalidated_at)
        );

        let invalid_cross_account_report = sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,user_id,revision,sync_redaction_version,signature,updated_at \
             ) VALUES(?,?,1,1,'signed-report',?)",
        )
        .bind(&device_a)
        .bind(&account_b)
        .bind(&created_at)
        .execute(&pool)
        .await;
        assert!(invalid_cross_account_report.is_err());
        pool.close().await;
    }

    #[tokio::test]
    async fn sqlite_record_redaction_migration_binds_proof_and_preserves_revision_index() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        let all = sqlx::migrate!("./migrations");
        let before_revision_index = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version < 48)
                    .cloned()
                    .collect(),
            ),
            ..sqlx::migrate::Migrator::DEFAULT
        };
        before_revision_index.run(&pool).await.unwrap();

        let created_at = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('redaction-owner','redaction-owner@example.test',?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('redaction-vault','redaction-owner',?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES('redaction-vault','redacted-record','deleted-revision',2)")
            .execute(&pool)
            .await
            .unwrap();
        for (revision, sequence) in [("old-revision", 1_i64), ("deleted-revision", 2_i64)] {
            sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES('redaction-vault','redacted-record',?,'{}','digest',?,'device','create',?)")
                .bind(revision)
                .bind(sequence)
                .bind(&created_at)
                .execute(&pool)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES('redaction-id','redaction-vault','redacted-record','deleted-revision',2,3,?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();

        let revision_index_migration = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version == 48)
                    .cloned()
                    .collect(),
            ),
            ignore_missing: true,
            ..sqlx::migrate::Migrator::DEFAULT
        };
        revision_index_migration.run(&pool).await.unwrap();
        // Reapplying the migration runner must be a no-op after version 48 is
        // recorded, without duplicating durable revision-index entries.
        revision_index_migration.run(&pool).await.unwrap();
        let mapped_revisions: Vec<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_redacted_revisions WHERE vault_id='redaction-vault' ORDER BY revision_id",
        )
        .fetch_all(&pool)
        .await
        .unwrap();
        assert_eq!(mapped_revisions, vec!["deleted-revision", "old-revision"]);

        assert!(sqlx::query("DELETE FROM record_graveyard WHERE vault_id='redaction-vault' AND record_id='redacted-record'")
            .execute(&pool)
            .await
            .is_err());
        assert!(sqlx::query("UPDATE record_graveyard SET deleted_seq=4 WHERE vault_id='redaction-vault' AND record_id='redacted-record'")
            .execute(&pool)
            .await
            .is_err());
        let wrong_tombstone = sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES('wrong-proof','redaction-vault','redacted-record','other-revision',2,4,?)")
            .bind(&created_at)
            .execute(&pool)
            .await;
        assert!(wrong_tombstone.is_err());

        // Vault/account deletion cascades private proof/index state together;
        // the restrictive record-level reference must not strand deletion.
        sqlx::query("DELETE FROM vaults WHERE vault_id='redaction-vault'")
            .execute(&pool)
            .await
            .unwrap();
        let redaction_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM record_redactions")
            .fetch_one(&pool)
            .await
            .unwrap();
        let revision_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_redacted_revisions")
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(redaction_count, 0);
        assert_eq!(revision_count, 0);
        pool.close().await;
    }

    #[tokio::test]
    async fn sqlite_record_redaction_migration_rejects_legacy_tombstone_mismatch() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        let all = sqlx::migrate!("./migrations");
        let before_revision_index = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version < 48)
                    .cloned()
                    .collect(),
            ),
            ..sqlx::migrate::Migrator::DEFAULT
        };
        before_revision_index.run(&pool).await.unwrap();
        let created_at = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('legacy-owner','legacy-owner@example.test',?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('legacy-vault','legacy-owner',?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES('legacy-vault','redacted-record','reserved-revision',2)")
            .execute(&pool)
            .await
            .unwrap();
        // This row was legal under the prior record-only FK, but cannot
        // authenticate a proof against the actual tombstone.
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES('legacy-redaction','legacy-vault','redacted-record','other-revision',1,3,?)")
            .bind(&created_at)
            .execute(&pool)
            .await
            .unwrap();

        let revision_index_migration = sqlx::migrate::Migrator {
            migrations: Cow::Owned(
                all.iter()
                    .filter(|migration| migration.version == 48)
                    .cloned()
                    .collect(),
            ),
            ignore_missing: true,
            ..sqlx::migrate::Migrator::DEFAULT
        };
        assert!(revision_index_migration.run(&pool).await.is_err());
        let preserved_bad_row: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM record_redactions WHERE redaction_id='legacy-redaction'",
        )
        .fetch_one(&pool)
        .await
        .unwrap();
        assert_eq!(
            preserved_bad_row, 1,
            "failed migration must roll back atomically"
        );
        pool.close().await;
    }
}

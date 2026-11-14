//! PostgreSQL persistence for the separately versioned sync-redaction client
//! capability. Signature verification is performed by the HTTP-facing
//! `redaction_capabilities` module before this repository is called. This
//! repository owns only the transactional session, account, device, and
//! monotonic-revision fences shared by all PostgreSQL service nodes.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{ApiError, auth, redaction_capabilities::RedactionCapabilityReport};

#[derive(Clone)]
pub(crate) struct PgRedactionCapabilityRepository {
    pool: PgPool,
}

impl PgRedactionCapabilityRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Stores a caller-verified signed report, rejecting revision rollback or
    /// revision reuse with different content. The device row lock also
    /// serializes first inserts, where there is not yet a report row to lock.
    pub(crate) async fn put(
        &self,
        user: &auth::AuthUser,
        report: &RedactionCapabilityReport,
    ) -> Result<Value, ApiError> {
        if report.account_id != user.user_id
            || report.device_id != user.device_id
            || !(1..=9_007_199_254_740_991).contains(&report.revision)
            || report.sync_redaction_version != 1
            || report.format != crate::redaction_capabilities::REPORT_FORMAT
        {
            return Err(ApiError::bad_request(
                "INVALID_DEVICE_REDACTION_CAPABILITY_REPORT",
                "report identity, revision, or sync redaction version is invalid",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_live_session(&mut tx, user).await?;

        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&user.user_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR UPDATE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if device_status.as_deref() != Some("active") {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }

        let existing = sqlx::query(
            "SELECT revision,sync_redaction_version,signature,invalidated_at \
             FROM device_redaction_capability_reports \
             WHERE device_id=$1 AND account_id=$2 FOR UPDATE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        if let Some(row) = existing {
            let current_revision: i64 = row.try_get("revision").map_err(ApiError::internal)?;
            let current_version: i64 = row
                .try_get("sync_redaction_version")
                .map_err(ApiError::internal)?;
            let current_signature: String = row.try_get("signature").map_err(ApiError::internal)?;
            let invalidated_at: Option<DateTime<Utc>> =
                row.try_get("invalidated_at").map_err(ApiError::internal)?;

            if report.revision < current_revision {
                return Err(ApiError::conflict(
                    "DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT",
                    "device redaction capability report revision is stale",
                ));
            }
            if report.revision == current_revision {
                if invalidated_at.is_none()
                    && report.sync_redaction_version == current_version
                    && report.signature == current_signature
                {
                    tx.commit().await.map_err(ApiError::internal)?;
                    return Ok(json!({
                        "status": "stored",
                        "already_applied": true,
                        "redaction_capability_report": report,
                    }));
                }
                return Err(ApiError::conflict(
                    "DEVICE_REDACTION_CAPABILITY_REVISION_CONFLICT",
                    "device redaction capability report revision was reused with different content",
                ));
            }
        }

        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,account_id,revision,sync_redaction_version,signature,updated_at \
             ) VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP) \
             ON CONFLICT(device_id) DO UPDATE SET \
                 account_id=EXCLUDED.account_id,revision=EXCLUDED.revision, \
                 sync_redaction_version=EXCLUDED.sync_redaction_version, \
                 invalidated_at=NULL, \
                 signature=EXCLUDED.signature,updated_at=EXCLUDED.updated_at",
        )
        .bind(&report.device_id)
        .bind(&report.account_id)
        .bind(report.revision)
        .bind(report.sync_redaction_version)
        .bind(&report.signature)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "stored",
            "already_applied": false,
            "redaction_capability_report": report,
        }))
    }
}

/// Keep the same lock order as PostgreSQL device lifecycle writes: session,
/// account, then device. The caller rechecks account/device state after the
/// session lock is held, so refresh rotation and revocation serialize here.
async fn lock_live_session(
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

#[cfg(test)]
mod tests {
    use std::str::FromStr;

    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const MIGRATIONS: [&str; 31] = [
        include_str!("../migrations/postgres/0001_sync_commit_core.sql"),
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql"),
        include_str!("../migrations/postgres/0003_instance_meta.sql"),
        include_str!("../migrations/postgres/0004_auth_rate_limits.sql"),
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql"),
        include_str!("../migrations/postgres/0006_sync_conflict_write.sql"),
        include_str!("../migrations/postgres/0007_sync_snapshots.sql"),
        include_str!("../migrations/postgres/0008_sync_snapshot_pages.sql"),
        include_str!("../migrations/postgres/0009_auth_lifecycle.sql"),
        include_str!("../migrations/postgres/0010_account_onboarding.sql"),
        include_str!("../migrations/postgres/0011_vault_invitations.sql"),
        include_str!("../migrations/postgres/0012_vault_deletion.sql"),
        include_str!("../migrations/postgres/0013_account_deletion.sql"),
        include_str!("../migrations/postgres/0014_account_recovery.sql"),
        include_str!("../migrations/postgres/0015_object_storage.sql"),
        include_str!("../migrations/postgres/0016_password_change_receipts.sql"),
        include_str!("../migrations/postgres/0017_postgres_totp_mfa.sql"),
        include_str!("../migrations/postgres/0018_audit_event_order.sql"),
        include_str!("../migrations/postgres/0019_mobile_push_outbox_due.sql"),
        include_str!("../migrations/postgres/0020_instance_audit_event_index.sql"),
        include_str!("../migrations/postgres/0021_vault_presence.sql"),
        include_str!("../migrations/postgres/0022_instance_admin_maintenance_jobs.sql"),
        include_str!("../migrations/postgres/0023_notification_tickets.sql"),
        include_str!("../migrations/postgres/0024_backup_object_pins.sql"),
        include_str!("../migrations/postgres/0025_instance_admin_backup_restore_jobs.sql"),
        include_str!("../migrations/postgres/0026_instance_backup_schedule.sql"),
        include_str!("../migrations/postgres/0027_shared_ssh_relay.sql"),
        include_str!("../migrations/postgres/0028_restore_stage_discard.sql"),
        include_str!("../migrations/postgres/0029_redaction_capability_reports.sql"),
        include_str!("../migrations/postgres/0030_record_redactions.sql"),
        concat!(
            include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
            include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
            include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
            include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
        ),
    ];

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PG capability test requires ATERMIUS_TEST_PG_URL");
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
                .expect("connect to disposable test database");
            let schema = format!("atermius_pg_redaction_caps_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated test schema");
            let pool = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                .await
                .expect("connect to isolated test schema");
            for (index, migration) in MIGRATIONS.iter().enumerate() {
                sqlx::raw_sql(migration)
                    .execute(&pool)
                    .await
                    .unwrap_or_else(|error| {
                        panic!("apply PostgreSQL migration {:04}: {error}", index + 1)
                    });
            }

            Self {
                pool,
                admin_pool,
                schema,
            }
        }

        async fn cleanup(self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated test schema");
            self.admin_pool.close().await;
        }
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL pointing at a disposable test database"]
    async fn put_is_idempotent_and_rejects_reused_or_stale_revisions() {
        let database = TestDatabase::create().await;
        sqlx::query(
            "INSERT INTO users(user_id,username,status) VALUES('account-1','test','active')",
        )
        .execute(&database.pool)
        .await
        .expect("seed user");
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,status) VALUES('device-1','account-1','active')",
        )
        .execute(&database.pool)
        .await
        .expect("seed device");
        sqlx::query(
            "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at) \
             VALUES('session-1','account-1','device-1','access-hash','refresh-hash',CURRENT_TIMESTAMP+INTERVAL '10 minutes')",
        )
        .execute(&database.pool)
        .await
        .expect("seed live session");

        let user = auth::AuthUser {
            user_id: "account-1".to_owned(),
            device_id: "device-1".to_owned(),
            session_id: "session-1".to_owned(),
            access_hash: "access-hash".to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        };
        let repository = PgRedactionCapabilityRepository::new(database.pool.clone());
        let report = |revision, signature: &str| RedactionCapabilityReport {
            format: "atermius-sync-redaction-capability-v1".to_owned(),
            account_id: "account-1".to_owned(),
            device_id: "device-1".to_owned(),
            revision,
            sync_redaction_version: 1,
            signature: signature.to_owned(),
        };

        let first = repository.put(&user, &report(1, "sig-1")).await.unwrap();
        assert_eq!(first["already_applied"], false);
        let retry = repository.put(&user, &report(1, "sig-1")).await.unwrap();
        assert_eq!(retry["already_applied"], true);
        assert!(
            repository
                .put(&user, &report(1, "different"))
                .await
                .is_err()
        );
        repository.put(&user, &report(2, "sig-2")).await.unwrap();
        assert!(repository.put(&user, &report(1, "sig-1")).await.is_err());

        let row = sqlx::query(
            "SELECT revision,sync_redaction_version,signature FROM device_redaction_capability_reports WHERE device_id='device-1'",
        )
        .fetch_one(&database.pool)
        .await
        .expect("read final report");
        assert_eq!(row.get::<i64, _>("revision"), 2);
        assert_eq!(row.get::<i64, _>("sync_redaction_version"), 1);
        assert_eq!(row.get::<String, _>("signature"), "sig-2");
        database.cleanup().await;
    }
}

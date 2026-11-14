//! Shared PostgreSQL metrics snapshot and Prometheus scrape-credential store.
//!
//! Snapshot data is aggregate-only, and credential mutations are caller-
//! transactional so handlers can commit state and audit records together.

use std::sync::Arc;

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use chrono::{DateTime, Utc};
use rand::RngCore;
use sqlx::{PgPool, Postgres, Row, Transaction};
use zeroize::{Zeroize, Zeroizing};

use crate::{ApiError, AppState, admin};

/// Fixed, aggregate-only metrics values for one shared PostgreSQL snapshot.
/// These fields map to a bounded set of metric names and labels; no database
/// identifiers or caller-controlled values are included.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct PgAdminMetricsSnapshot {
    pub(crate) accounts_active: i64,
    pub(crate) accounts_deleting: i64,
    pub(crate) accounts_disabled: i64,
    pub(crate) devices_active: i64,
    pub(crate) vaults_active: i64,
    pub(crate) vaults_deleting: i64,
    pub(crate) stored_bytes: i64,
    pub(crate) reserved_upload_bytes: i64,
    pub(crate) object_delete_pending: i64,
    pub(crate) object_delete_retry_wait: i64,
    pub(crate) object_delete_quarantined: i64,
    pub(crate) vault_quota_bytes: i64,
    pub(crate) relay_enabled: bool,
    pub(crate) backup_last_success_timestamp_seconds: i64,
}

/// Reads the fixed Prometheus aggregates using the caller's repeatable-read
/// transaction. The caller must set REPEATABLE READ before its first query.
/// Reservation expiry uses one database-clock sample, while successful
/// backup status comes from the shared job ledger rather than node-local disk.
pub(crate) async fn snapshot_tx(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<PgAdminMetricsSnapshot, ApiError> {
    let counts = sqlx::query(
        "WITH sampled_clock AS MATERIALIZED (SELECT clock_timestamp() AS now) \
         SELECT \
         (SELECT COUNT(*) FROM users WHERE status='active') AS accounts_active, \
         (SELECT COUNT(*) FROM users WHERE status='deleting') AS accounts_deleting, \
         (SELECT COUNT(*) FROM users WHERE status='disabled') AS accounts_disabled, \
         (SELECT COUNT(*) FROM devices d JOIN users u ON u.user_id=d.user_id \
          WHERE d.status='active' AND u.status='active') AS devices_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='active') AS vaults_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='deleting') AS vaults_deleting, \
         (SELECT COALESCE(SUM(size),0)::BIGINT FROM blob_objects) AS stored_bytes, \
         (SELECT COALESCE(SUM(expected_size),0)::BIGINT FROM uploads, sampled_clock \
          WHERE state='open' AND expires_at>sampled_clock.now) AS reserved_upload_bytes, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='pending') AS object_delete_pending, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='retry_wait') AS object_delete_retry_wait, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='quarantined') AS object_delete_quarantined, \
         (SELECT COALESCE(SUM(quota_bytes),0)::BIGINT FROM vaults \
          WHERE state IN ('active','deleting')) AS vault_quota_bytes, \
         (SELECT COALESCE(FLOOR(EXTRACT(EPOCH FROM MAX(finished_at)))::BIGINT,0)::BIGINT \
          FROM instance_admin_jobs \
          WHERE action='backup' AND status='succeeded' AND result_code='completed') \
          AS backup_last_success_timestamp_seconds \
         FROM sampled_clock",
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let relay = crate::pg_relay::overview_tx(tx, state).await?;
    let relay_enabled = relay
        .get("enabled")
        .and_then(serde_json::Value::as_bool)
        .ok_or_else(|| ApiError::internal("PostgreSQL Relay overview has invalid enabled field"))?;

    Ok(PgAdminMetricsSnapshot {
        accounts_active: counts.get("accounts_active"),
        accounts_deleting: counts.get("accounts_deleting"),
        accounts_disabled: counts.get("accounts_disabled"),
        devices_active: counts.get("devices_active"),
        vaults_active: counts.get("vaults_active"),
        vaults_deleting: counts.get("vaults_deleting"),
        stored_bytes: counts.get("stored_bytes"),
        reserved_upload_bytes: counts.get("reserved_upload_bytes"),
        object_delete_pending: counts.get("object_delete_pending"),
        object_delete_retry_wait: counts.get("object_delete_retry_wait"),
        object_delete_quarantined: counts.get("object_delete_quarantined"),
        vault_quota_bytes: counts.get("vault_quota_bytes"),
        relay_enabled,
        backup_last_success_timestamp_seconds: counts.get("backup_last_success_timestamp_seconds"),
    })
}

#[derive(Clone)]
pub(crate) struct PgAdminMetricsRepository {
    pool: PgPool,
    auth_rate_key: Arc<[u8; 32]>,
}

impl PgAdminMetricsRepository {
    pub(crate) fn new(pool: PgPool, auth_rate_key: Arc<[u8; 32]>) -> Self {
        Self {
            pool,
            auth_rate_key,
        }
    }

    /// Returns the shared credential's last update time, if it is active.
    pub(crate) async fn status(&self) -> Result<Option<DateTime<Utc>>, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let updated_at = self.status_tx(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(updated_at)
    }

    /// Reads status inside a caller-owned transaction.
    pub(crate) async fn status_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
    ) -> Result<Option<DateTime<Utc>>, ApiError> {
        let updated_at: Option<DateTime<Utc>> = sqlx::query_scalar(
            "SELECT updated_at FROM instance_metrics_credential WHERE credential_id=1",
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        Ok(updated_at)
    }

    /// Creates or rotates the one shared credential. The cleartext is returned
    /// once and only its keyed verifier is written to PostgreSQL.
    pub(crate) async fn rotate(&self) -> Result<(String, DateTime<Utc>), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let rotated = self.rotate_tx(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(rotated)
    }

    /// Rotates the credential inside a caller-owned transaction so an admin
    /// handler can commit the verifier and its audit event atomically.
    pub(crate) async fn rotate_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
    ) -> Result<(String, DateTime<Utc>), ApiError> {
        let mut credential_bytes = [0_u8; admin::METRICS_CREDENTIAL_BYTES];
        rand::rngs::OsRng.fill_bytes(&mut credential_bytes);
        let mut encoded = Zeroizing::new(URL_SAFE_NO_PAD.encode(credential_bytes));
        credential_bytes.zeroize();
        let mut credential = Zeroizing::new(format!(
            "{}{}",
            admin::METRICS_CREDENTIAL_PREFIX,
            encoded.as_str()
        ));
        encoded.zeroize();
        let verifier = admin::metrics_credential_verifier_for_key(
            self.auth_rate_key.as_ref(),
            credential.as_str(),
        )?;

        let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO instance_metrics_credential(credential_id,verifier,created_at,updated_at) \
             VALUES(1,$1,$2,$2) ON CONFLICT(credential_id) DO UPDATE SET \
             verifier=excluded.verifier,created_at=excluded.created_at,updated_at=excluded.updated_at",
        )
        .bind(verifier.as_slice())
        .bind(now)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;

        Ok((std::mem::take(&mut *credential), now))
    }

    /// Removes the active shared credential. Repeated revocation is a no-op.
    pub(crate) async fn revoke(&self) -> Result<bool, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let removed = self.revoke_tx(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(removed)
    }

    /// Revokes the credential inside a caller-owned transaction so a handler
    /// can commit the removal and its audit event atomically.
    pub(crate) async fn revoke_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
    ) -> Result<bool, ApiError> {
        let removed = sqlx::query("DELETE FROM instance_metrics_credential WHERE credential_id=1")
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?
            .rows_affected()
            > 0;
        Ok(removed)
    }

    /// Verifies a bearer token against the shared verifier without retaining
    /// or querying for cleartext credentials.
    pub(crate) async fn matches(&self, credential: &str) -> Result<bool, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let matches = self.matches_tx(&mut tx, credential).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(matches)
    }

    /// Verifies the scrape token inside a caller-owned transaction. A metrics
    /// handler can use this with `snapshot_tx` in one repeatable-read snapshot,
    /// so rotation or revocation cannot race credential acceptance and reads.
    pub(crate) async fn matches_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        credential: &str,
    ) -> Result<bool, ApiError> {
        if !admin::metrics_credential_token_is_valid(credential) {
            return Ok(false);
        }
        let Some(expected) = sqlx::query_scalar::<_, Vec<u8>>(
            "SELECT verifier FROM instance_metrics_credential WHERE credential_id=1",
        )
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        else {
            return Ok(false);
        };
        admin::metrics_credential_verifier_matches(
            self.auth_rate_key.as_ref(),
            credential,
            &expected,
        )
    }
}

#[cfg(test)]
mod tests {
    use std::{panic::AssertUnwindSafe, path::PathBuf, str::FromStr};

    use futures_util::FutureExt;
    use hmac::{Hmac, Mac};
    use ipnet::IpNet;
    use sha2::Sha256;
    use sqlx::postgres::{PgConnectOptions, PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    type HmacSha256 = Hmac<Sha256>;

    #[test]
    fn scrape_credential_encoding_and_verifier_match_the_existing_contract() {
        let key = [0x5a_u8; 32];
        let bytes = [0xa5_u8; admin::METRICS_CREDENTIAL_BYTES];
        let credential = format!(
            "{}{encoded}",
            admin::METRICS_CREDENTIAL_PREFIX,
            encoded = URL_SAFE_NO_PAD.encode(bytes),
        );
        assert_eq!(admin::METRICS_CREDENTIAL_PREFIX, "atm_");
        assert_eq!(
            credential.len(),
            admin::METRICS_CREDENTIAL_PREFIX.len() + 43
        );
        assert!(admin::metrics_credential_token_is_valid(&credential));
        assert!(!admin::metrics_credential_token_is_valid("atm_not-base64!"));
        assert!(!admin::metrics_credential_token_is_valid("other_prefix"));

        let expected = admin::metrics_credential_verifier_for_key(&key, &credential).unwrap();
        let mut canonical = HmacSha256::new_from_slice(&key).unwrap();
        canonical.update(b"atermius/admin-metrics-credential/v1\0");
        canonical.update(credential.as_bytes());
        let independently_computed: [u8; 32] = canonical.finalize().into_bytes().into();
        assert_eq!(expected, independently_computed);
        assert!(admin::metrics_credential_verifier_matches(&key, &credential, &expected,).unwrap());
        let mut wrong_verifier = expected;
        wrong_verifier[0] ^= 1;
        assert!(
            !admin::metrics_credential_verifier_matches(&key, &credential, &wrong_verifier,)
                .unwrap()
        );
        assert!(
            !admin::metrics_credential_verifier_matches(&[0x33_u8; 32], &credential, &expected,)
                .unwrap()
        );
    }

    struct TestDatabase {
        pool_a: PgPool,
        pool_b: PgPool,
        admin_pool: PgPool,
        schema: String,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL metrics test requires ATERMIUS_TEST_PG_URL");
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
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect PostgreSQL disposable test database");
            let schema = format!("atermius_pg_metrics_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL metrics schema");
            let pool_options = options.options([("search_path", format!("\"{schema}\""))]);
            let pool_a = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(pool_options.clone())
                .await
                .expect("connect first isolated PostgreSQL node");
            let pool_b = PgPoolOptions::new()
                .max_connections(4)
                .connect_with(pool_options)
                .await
                .expect("connect second isolated PostgreSQL node");
            sqlx::raw_sql(
                "CREATE TABLE atermius_instance_schema ( \
                   singleton SMALLINT PRIMARY KEY CHECK(singleton=1), \
                   schema_version INTEGER NOT NULL \
                 ); \
                 INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,34)",
            )
            .execute(&pool_a)
            .await
            .expect("create isolated schema marker");
            sqlx::raw_sql(include_str!(
                "../migrations/postgres/0035_instance_metrics_credential.sql"
            ))
            .execute(&pool_a)
            .await
            .expect("apply PostgreSQL metrics credential migration");
            Self {
                pool_a,
                pool_b,
                admin_pool,
                schema,
            }
        }

        async fn cleanup(self) {
            self.pool_a.close().await;
            self.pool_b.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL metrics schema");
            self.admin_pool.close().await;
        }
    }

    fn test_config(data_dir: PathBuf) -> crate::Config {
        crate::Config {
            data_dir,
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            registration_open: false,
            guacd_address: None,
            relay_enabled: true,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: vec!["127.0.0.1/32".parse::<IpNet>().unwrap()],
            relay_allow_ports: vec![22],
            relay_max_connections_per_user: 4,
            public_origin: Some("https://relay.example.test".to_owned()),
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 7 * 24 * 60 * 60,
            admin_usernames: Vec::new(),
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn sqlite_app_state() -> (crate::AppState, PathBuf) {
        let data_dir = std::env::temp_dir().join(format!("atermius-pg-metrics-{}", Uuid::new_v4()));
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database, test_config(data_dir.clone()))
            .await
            .expect("open local SQLite state for PostgreSQL metrics snapshot");
        (state, data_dir)
    }

    async fn create_snapshot_schema(pool: &PgPool) {
        sqlx::raw_sql(
            "CREATE TABLE users(user_id TEXT PRIMARY KEY,status TEXT NOT NULL); \
             CREATE TABLE devices(device_id TEXT PRIMARY KEY,user_id TEXT NOT NULL,status TEXT NOT NULL); \
             CREATE TABLE vaults(vault_id TEXT PRIMARY KEY,state TEXT NOT NULL,quota_bytes BIGINT NOT NULL); \
             CREATE TABLE blob_objects(object_id TEXT PRIMARY KEY,size BIGINT NOT NULL); \
             CREATE TABLE uploads(upload_id TEXT PRIMARY KEY,state TEXT NOT NULL,expected_size BIGINT NOT NULL,expires_at TIMESTAMPTZ NOT NULL); \
             CREATE TABLE object_delete_queue(queue_id TEXT PRIMARY KEY,state TEXT NOT NULL); \
             CREATE TABLE instance_admin_jobs( \
               job_id TEXT PRIMARY KEY,action TEXT NOT NULL,status TEXT NOT NULL, \
               result_code TEXT,finished_at TIMESTAMPTZ); \
             CREATE TABLE instance_relay_policy( \
               policy_id SMALLINT PRIMARY KEY,enabled BOOLEAN NOT NULL,allow_cidrs TEXT NOT NULL, \
               allow_ports TEXT NOT NULL,revision BIGINT NOT NULL,updated_at TIMESTAMPTZ NOT NULL); \
             INSERT INTO users(user_id,status) VALUES \
               ('user-active-1','active'),('user-active-2','active'), \
               ('user-deleting','deleting'),('user-disabled','disabled'); \
             INSERT INTO devices(device_id,user_id,status) VALUES \
               ('device-active-1','user-active-1','active'), \
               ('device-active-2','user-active-2','active'), \
               ('device-deleting-owner','user-deleting','active'), \
               ('device-disabled-owner','user-disabled','active'), \
               ('device-revoked','user-active-1','revoked'); \
             INSERT INTO vaults(vault_id,state,quota_bytes) VALUES \
               ('vault-active-1','active',100),('vault-active-2','active',200), \
               ('vault-deleting','deleting',300),('vault-inactive','deleted',900); \
             INSERT INTO blob_objects(object_id,size) VALUES \
               ('blob-1',50),('blob-2',75); \
             INSERT INTO uploads(upload_id,state,expected_size,expires_at) VALUES \
               ('upload-open-1','open',30,clock_timestamp()+INTERVAL '10 minutes'), \
               ('upload-open-2','open',20,clock_timestamp()+INTERVAL '10 minutes'), \
               ('upload-expired','open',900,clock_timestamp()-INTERVAL '1 second'), \
               ('upload-completing','completing',700,clock_timestamp()+INTERVAL '10 minutes'); \
             INSERT INTO object_delete_queue(queue_id,state) VALUES \
               ('delete-pending-1','pending'),('delete-pending-2','pending'), \
               ('delete-retry','retry_wait'),('delete-quarantine-1','quarantined'), \
               ('delete-quarantine-2','quarantined'),('delete-quarantine-3','quarantined'), \
               ('delete-completed','completed'); \
             INSERT INTO instance_admin_jobs(job_id,action,status,result_code,finished_at) VALUES \
               ('backup-old','backup','succeeded','completed','2026-08-01T12:00:00Z'), \
               ('backup-latest','backup','succeeded','completed','2026-08-05T12:34:56.987Z'), \
               ('backup-failed-later','backup','failed','backup_failed','2026-09-01T12:00:00Z'), \
               ('maintenance-later','maintenance','succeeded','completed','2026-10-01T12:00:00Z'), \
               ('restore-later','restore','succeeded','completed','2026-10-02T12:00:00Z'); \
             INSERT INTO instance_relay_policy( \
               policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
             VALUES(1,TRUE,'[\"127.0.0.1/32\"]','[22]',1,clock_timestamp());",
        )
        .execute(pool)
        .await
        .expect("seed isolated PostgreSQL metrics snapshot schema");
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL metrics credential acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_metrics_credential_is_shared_rotatable_revocable_and_verifier_only() {
        let database = TestDatabase::create().await;
        let result = AssertUnwindSafe(async {
            let key = Arc::new([0x5a_u8; 32]);
            let repo_a = PgAdminMetricsRepository::new(database.pool_a.clone(), key.clone());
            let repo_b = PgAdminMetricsRepository::new(database.pool_b.clone(), key.clone());
            let wrong_key_repo =
                PgAdminMetricsRepository::new(database.pool_b.clone(), Arc::new([0x33_u8; 32]));

            assert_eq!(repo_a.status().await.unwrap(), None);
            assert!(!repo_a.revoke().await.unwrap());

            let mut rolled_back_tx = database.pool_a.begin().await.unwrap();
            let (rolled_back_credential, _) = repo_a.rotate_tx(&mut rolled_back_tx).await.unwrap();
            assert!(!repo_b.matches(&rolled_back_credential).await.unwrap());
            rolled_back_tx.rollback().await.unwrap();
            assert_eq!(repo_b.status().await.unwrap(), None);

            let (first_credential, first_created_at) = repo_a.rotate().await.unwrap();
            assert!(admin::metrics_credential_token_is_valid(&first_credential));
            assert_eq!(
                repo_b.status().await.unwrap(),
                Some(first_created_at.clone())
            );
            assert!(repo_b.matches(&first_credential).await.unwrap());
            assert!(!repo_b.matches("atm_bad").await.unwrap());
            assert!(!wrong_key_repo.matches(&first_credential).await.unwrap());

            let stored: Vec<u8> = sqlx::query_scalar(
                "SELECT verifier FROM instance_metrics_credential WHERE credential_id=1",
            )
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            let expected =
                admin::metrics_credential_verifier_for_key(&key, &first_credential).unwrap();
            assert_eq!(stored, expected);
            assert_eq!(stored.len(), 32);
            assert_ne!(stored.as_slice(), first_credential.as_bytes());

            let columns: Vec<(String, String)> = sqlx::query_as(
                "SELECT column_name,data_type FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                 ORDER BY ordinal_position",
            )
            .fetch_all(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(
                columns,
                vec![
                    ("credential_id".into(), "smallint".into()),
                    ("verifier".into(), "bytea".into()),
                    ("created_at".into(), "timestamp with time zone".into()),
                    ("updated_at".into(), "timestamp with time zone".into()),
                ]
            );

            let (rotated_credential, rotated_at) = repo_b.rotate().await.unwrap();
            assert_ne!(rotated_credential, first_credential);
            assert!(rotated_at >= first_created_at);
            assert!(!repo_a.matches(&first_credential).await.unwrap());
            assert!(repo_a.matches(&rotated_credential).await.unwrap());
            assert_eq!(repo_a.status().await.unwrap(), Some(rotated_at));

            let mut credential_snapshot_tx = database.pool_a.begin().await.unwrap();
            sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                .execute(&mut *credential_snapshot_tx)
                .await
                .unwrap();
            assert!(
                repo_a
                    .matches_tx(&mut credential_snapshot_tx, &rotated_credential)
                    .await
                    .unwrap()
            );
            let (raced_credential, raced_at) = repo_b.rotate().await.unwrap();
            assert!(
                repo_a
                    .matches_tx(&mut credential_snapshot_tx, &rotated_credential)
                    .await
                    .unwrap()
            );
            assert!(
                !repo_a
                    .matches_tx(&mut credential_snapshot_tx, &raced_credential)
                    .await
                    .unwrap()
            );
            credential_snapshot_tx.commit().await.unwrap();
            assert!(!repo_a.matches(&rotated_credential).await.unwrap());
            assert!(repo_a.matches(&raced_credential).await.unwrap());
            assert_eq!(repo_a.status().await.unwrap(), Some(raced_at));

            assert!(repo_a.revoke().await.unwrap());
            assert!(!repo_b.revoke().await.unwrap());
            assert_eq!(repo_b.status().await.unwrap(), None);
            assert!(!repo_b.matches(&raced_credential).await.unwrap());

            let (revoke_rollback_credential, _) = repo_a.rotate().await.unwrap();
            let mut revoke_tx = database.pool_b.begin().await.unwrap();
            assert!(repo_b.revoke_tx(&mut revoke_tx).await.unwrap());
            assert!(repo_a.matches(&revoke_rollback_credential).await.unwrap());
            revoke_tx.rollback().await.unwrap();
            assert!(repo_a.matches(&revoke_rollback_credential).await.unwrap());

            let marker: i64 = sqlx::query_scalar(
                "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
            )
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(marker, 35);
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        result.unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL metrics snapshot acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_metrics_snapshot_uses_fixed_shared_aggregates_and_relay_policy() {
        let database = TestDatabase::create().await;
        create_snapshot_schema(&database.pool_a).await;
        let (mut state, data_dir) = sqlite_app_state().await;
        state.pg_sync_pool = Some(database.pool_a.clone());
        crate::record_backup_success(&data_dir, 1, 10)
            .expect("write a node-local backup timestamp that must not drive PG metrics");

        let result = AssertUnwindSafe(async {
            let mut tx = database.pool_a.begin().await.unwrap();
            sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
                .execute(&mut *tx)
                .await
                .expect("set repeatable-read snapshot transaction");
            let snapshot = snapshot_tx(&state, &mut tx).await.unwrap();
            tx.commit().await.unwrap();

            assert_eq!(
                snapshot,
                PgAdminMetricsSnapshot {
                    accounts_active: 2,
                    accounts_deleting: 1,
                    accounts_disabled: 1,
                    devices_active: 2,
                    vaults_active: 2,
                    vaults_deleting: 1,
                    stored_bytes: 125,
                    reserved_upload_bytes: 50,
                    object_delete_pending: 2,
                    object_delete_retry_wait: 1,
                    object_delete_quarantined: 3,
                    vault_quota_bytes: 600,
                    relay_enabled: true,
                    backup_last_success_timestamp_seconds: chrono::DateTime::parse_from_rfc3339(
                        "2026-08-05T12:34:56.987Z",
                    )
                    .unwrap()
                    .timestamp(),
                }
            );
        })
        .catch_unwind()
        .await;

        let path = state.config.data_dir.clone();
        state.db.close().await;
        tokio::fs::remove_dir_all(path)
            .await
            .expect("remove local SQLite metrics state fixture");
        database.cleanup().await;
        result.unwrap();
    }
}

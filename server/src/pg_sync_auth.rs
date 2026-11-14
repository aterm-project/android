//! PostgreSQL-backed authentication and device-key reads for sync paths.
//!
//! This capability deliberately does not create sessions or parse HTTP
//! headers. Callers pass the bearer token value after removing the exact
//! `Bearer ` scheme and pass the record-schema and independent redaction
//! transport markers as booleans. It derives the same SHA-256 access hash as
//! `auth::authenticate` and returns the production `AuthUser` principal shape.

use sqlx::{PgPool, Postgres, Row, Transaction, postgres::PgRow};

use crate::{ApiError, auth::AuthUser, pg_notifications::notify_sync_wake, sha256_hex};

const MIN_ACCESS_TOKEN_BYTES: usize = 32;
const MAX_ACCESS_TOKEN_BYTES: usize = 128;

#[derive(Clone)]
pub(crate) struct PgSyncAuthRepository {
    pool: PgPool,
}

impl PgSyncAuthRepository {
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    /// Validates a raw bearer token value (without the `Bearer ` prefix).
    ///
    /// Token byte bounds, the SHA-256 hash persisted in `sessions`, active
    /// user/device states, and session expiry/revocation match the existing
    /// SQLite `auth::authenticate` contract. The caller supplies the
    /// transport-level schema-2 marker because this capability is intentionally
    /// independent of HTTP header parsing.
    #[cfg(test)]
    pub(crate) async fn authenticate_token(
        &self,
        token: &str,
        declares_record_schema2: bool,
    ) -> Result<AuthUser, ApiError> {
        self.authenticate_token_with_markers(token, declares_record_schema2, false)
            .await
    }

    pub(crate) async fn authenticate_token_with_markers(
        &self,
        token: &str,
        declares_record_schema2: bool,
        declares_sync_redaction_v1: bool,
    ) -> Result<AuthUser, ApiError> {
        if !(MIN_ACCESS_TOKEN_BYTES..=MAX_ACCESS_TOKEN_BYTES).contains(&token.len()) {
            return Err(ApiError::unauthorized());
        }

        let access_hash = sha256_hex(token.as_bytes());
        // Fail closed if a corrupted/imported database contains duplicate
        // access hashes. The normal session writer uses random tokens, but the
        // bounded core schema intentionally does not impose a unique index.
        let rows = sqlx::query(
            "SELECT s.user_id,s.device_id,s.session_id FROM sessions s \
             JOIN users u ON u.user_id=s.user_id \
             JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
             WHERE s.access_hash=$1 AND s.revoked_at IS NULL \
               AND s.access_expires_at>CURRENT_TIMESTAMP \
               AND u.status='active' AND d.status='active' \
             LIMIT 2",
        )
        .bind(&access_hash)
        .fetch_all(&self.pool)
        .await
        .map_err(ApiError::internal)?;

        if rows.len() != 1 {
            return Err(ApiError::unauthorized());
        }
        let row: &PgRow = &rows[0];
        let user = AuthUser {
            user_id: row.try_get("user_id").map_err(ApiError::internal)?,
            device_id: row.try_get("device_id").map_err(ApiError::internal)?,
            session_id: row.try_get("session_id").map_err(ApiError::internal)?,
            access_hash,
            declares_record_schema2,
            declares_sync_redaction_v1,
        };

        // A missing/old marker invalidates a previously stored full schema-2
        // report. Keep ordinary authentication on the cheap read-only path;
        // sync transactions always recheck the redaction marker under their
        // own write fence, including when this early read sees no report.
        if !user.declares_record_schema2
            && self
                .has_v2_capability_report(&user.user_id, &user.device_id)
                .await?
        {
            self.delete_v2_capability_report(&user).await?;
        }
        if !declares_sync_redaction_v1
            && self
                .has_redaction_capability_report(&user.user_id, &user.device_id)
                .await?
        {
            self.invalidate_redaction_capability_report(&user).await?;
        }

        Ok(user)
    }

    /// Locks and rechecks the HTTP principal in the same transaction as a
    /// sync operation. The device lock serializes this report invalidation
    /// with first-report publication, even if authentication read no report.
    pub(crate) async fn recheck_active_principal_for_sync_tx(
        tx: &mut Transaction<'_, Postgres>,
        user: &AuthUser,
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
            .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("revoked_at")
            .map_err(ApiError::internal)?
            .is_some()
            || !session
                .try_get::<bool, _>("unexpired")
                .map_err(ApiError::internal)?
        {
            return Err(ApiError::unauthorized());
        }

        let account_status: Option<String> =
            sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
                .bind(&user.user_id)
                .fetch_optional(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
        if account_status.as_deref() != Some("active") {
            return Err(ApiError::unauthorized());
        }

        let device_status: Option<String> = sqlx::query_scalar(
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if device_status.as_deref() != Some("active") {
            return Err(ApiError::forbidden(
                "DEVICE_REVOKED",
                "device is not active",
            ));
        }

        if !user.declares_sync_redaction_v1 {
            sqlx::query(
                "UPDATE device_redaction_capability_reports SET invalidated_at=CURRENT_TIMESTAMP \
                 WHERE account_id=$1 AND device_id=$2 AND invalidated_at IS NULL",
            )
            .bind(&user.user_id)
            .bind(&user.device_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
        }
        Ok(())
    }

    /// Resolves a device key only when both the owning account and device are
    /// active in this same PostgreSQL database.
    pub(crate) async fn active_device_signing_key(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<Option<String>, ApiError> {
        sqlx::query_scalar(
            "SELECT d.signing_public_key FROM devices d \
             JOIN users u ON u.user_id=d.user_id \
             WHERE d.user_id=$1 AND d.device_id=$2 \
               AND u.status='active' AND d.status='active'",
        )
        .bind(user_id)
        .bind(device_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    /// Revokes the exact session represented by an already authenticated
    /// principal and writes the same account audit event as SQLite logout.
    /// Session-first locking matches sync commits, so logout orders cleanly
    /// against in-flight writes that hold a shared session lock.
    pub(crate) async fn revoke_authenticated_session(
        &self,
        user: &AuthUser,
        audit_scope_key: &[u8; 32],
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        let session = sqlx::query(
            "SELECT revoked_at,access_expires_at>CURRENT_TIMESTAMP AS unexpired \
             FROM sessions \
             WHERE session_id=$1 AND user_id=$2 AND device_id=$3 AND access_hash=$4 \
             FOR UPDATE",
        )
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
        if session
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("revoked_at")
            .is_some()
            || !session.get::<bool, _>("unexpired")
        {
            return Err(ApiError::unauthorized());
        }

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
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
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

        let updated = sqlx::query(
            "UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP \
             WHERE session_id=$1 AND user_id=$2 AND device_id=$3 AND access_hash=$4 \
               AND revoked_at IS NULL AND access_expires_at>CURRENT_TIMESTAMP",
        )
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::unauthorized());
        }

        // Session mutation is complete; leave audit_events as the final
        // database write so a pending first-page SHARE lock cannot form a
        // cycle with a transaction still waiting on this session row.
        let audit_scope = crate::audit::account_scope_id(audit_scope_key, &user.user_id)?;
        sqlx::query(
            "INSERT INTO audit_events( \
                 scope_type,scope_id,actor_user_id,actor_device_id,action, \
                 resource_type,resource_id,result,occurred_at,source \
             ) VALUES('account',$1,$2,$3,'auth.logout_succeeded', \
                      'session',$4,'success',$5,'api')",
        )
        .bind(audit_scope)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.session_id)
        .bind(chrono::Utc::now().timestamp())
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        // A logout invalidates every transport bound to this session. The
        // empty transactional wake prompts sockets on peer nodes to recheck.
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)
    }

    async fn has_v2_capability_report(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM device_capability_reports \
                 WHERE user_id=$1 AND device_id=$2 AND max_record_schema>=2 \
                   AND max_attachment_bytes>=1073741824 \
                   AND host_attachment_manifest_versions @> '[2]'::jsonb \
             )",
        )
        .bind(user_id)
        .bind(device_id)
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    async fn has_redaction_capability_report(
        &self,
        user_id: &str,
        device_id: &str,
    ) -> Result<bool, ApiError> {
        sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM device_redaction_capability_reports \
             WHERE account_id=$1 AND device_id=$2 AND invalidated_at IS NULL)",
        )
        .bind(user_id)
        .bind(device_id)
        .fetch_one(&self.pool)
        .await
        .map_err(ApiError::internal)
    }

    async fn invalidate_redaction_capability_report(
        &self,
        user: &AuthUser,
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let session = sqlx::query(
            "SELECT revoked_at,access_expires_at>CURRENT_TIMESTAMP AS unexpired \
             FROM sessions WHERE session_id=$1 AND user_id=$2 AND device_id=$3 \
               AND access_hash=$4 FOR UPDATE",
        )
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
        if session
            .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("revoked_at")
            .map_err(ApiError::internal)?
            .is_some()
            || !session
                .try_get::<bool, _>("unexpired")
                .map_err(ApiError::internal)?
        {
            return Err(ApiError::unauthorized());
        }
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
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
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
        sqlx::query(
            "UPDATE device_redaction_capability_reports SET invalidated_at=CURRENT_TIMESTAMP \
             WHERE account_id=$1 AND device_id=$2 AND invalidated_at IS NULL",
        )
        .bind(&user.user_id)
        .bind(&user.device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)
    }

    async fn delete_v2_capability_report(&self, user: &AuthUser) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;

        // Keep this lock order aligned with PG sync commits and logout:
        // session, account, device. The exclusive session lock fences this
        // capability downgrade against commits holding a shared session lock.
        let session = sqlx::query(
            "SELECT revoked_at,access_expires_at>CURRENT_TIMESTAMP AS unexpired \
             FROM sessions \
             WHERE session_id=$1 AND user_id=$2 AND device_id=$3 AND access_hash=$4 \
             FOR UPDATE",
        )
        .bind(&user.session_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(&user.access_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::unauthorized)?;
        if session
            .get::<Option<chrono::DateTime<chrono::Utc>>, _>("revoked_at")
            .is_some()
            || !session.get::<bool, _>("unexpired")
        {
            return Err(ApiError::unauthorized());
        }

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
            "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
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

        sqlx::query(
            "DELETE FROM device_capability_reports \
             WHERE user_id=$1 AND device_id=$2 AND max_record_schema>=2 \
               AND max_attachment_bytes>=1073741824 \
               AND host_attachment_manifest_versions @> '[2]'::jsonb",
        )
        .bind(&user.user_id)
        .bind(&user.device_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        tx.commit().await.map_err(ApiError::internal)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
    };

    use futures_util::FutureExt;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0029_redaction_capability_reports.sql");
    const USER_ID: &str = "pg-auth-user";
    const DEVICE_ID: &str = "pg-auth-device";
    const SESSION_ID: &str = "pg-auth-session";
    const ACCESS_TOKEN: &str = "0123456789abcdef0123456789abcdef";
    const SIGNING_KEY: &str = "test-device-signing-public-key";
    const AUDIT_SCOPE_KEY: [u8; 32] = [0x92; 32];

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    /// Armed immediately after schema creation so every later setup failure,
    /// including a panic in migration or fixture seeding, removes the schema.
    struct SchemaSetupCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl SchemaSetupCleanupGuard {
        fn new(admin_pool: PgPool, schema: String) -> Self {
            Self {
                admin_pool,
                schema,
                armed: true,
            }
        }

        async fn cleanup(&mut self) {
            if !self.armed {
                return;
            }
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated schema after fixture setup failure");
            self.armed = false;
        }

        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for SchemaSetupCleanupGuard {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL sync-auth tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL tests outside an explicitly disposable database"
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
            let schema = format!("atermius_pg_auth_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            let mut setup_guard = SchemaSetupCleanupGuard::new(admin_pool.clone(), schema.clone());
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect isolated PostgreSQL search path");
                sqlx::raw_sql(CORE_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply bounded PostgreSQL sync-core schema");
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema ( \
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1), \
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1) \
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,28)",
                )
                .execute(&pool)
                .await
                .expect("create PostgreSQL schema marker fixture");
                sqlx::raw_sql(REDACTION_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL redaction capability schema");
                seed(&pool).await;
                pool
            })
            .catch_unwind()
            .await;
            match setup {
                Ok(pool) => {
                    let database = Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    };
                    setup_guard.disarm();
                    database
                }
                Err(payload) => {
                    setup_guard.cleanup().await;
                    resume_unwind(payload)
                }
            }
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL test schema");
            self.cleaned = true;
            self.admin_pool.close().await;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    async fn seed(pool: &PgPool) {
        sqlx::query(
            "INSERT INTO users(user_id,username,status) VALUES($1,'pg-auth-user','active')",
        )
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,status) VALUES($1,$2,'test',$3,'active')")
            .bind(DEVICE_ID)
            .bind(USER_ID)
            .bind(SIGNING_KEY)
            .execute(pool)
            .await
            .unwrap();
        insert_session(
            pool,
            SESSION_ID,
            ACCESS_TOKEN,
            "CURRENT_TIMESTAMP+INTERVAL '1 hour'",
            None,
        )
        .await;
    }

    async fn insert_session(
        pool: &PgPool,
        session_id: &str,
        token: &str,
        expiry_sql: &str,
        revoked_at: Option<&str>,
    ) {
        // SQL fragments are test constants only; session values remain bound.
        let revoked = revoked_at.map_or("NULL", |value| value);
        sqlx::query(&format!(
            "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,revoked_at) \
             VALUES($1,$2,$3,$4,$5,{expiry_sql},CURRENT_TIMESTAMP+INTERVAL '1 day',{revoked})"
        ))
        .bind(session_id)
        .bind(USER_ID)
        .bind(DEVICE_ID)
        .bind(crate::sha256_hex(token.as_bytes()))
        .bind(format!("refresh-{session_id}"))
        .execute(pool)
        .await
        .unwrap();
    }

    async fn insert_capability_report(pool: &PgPool, max_schema: i16, versions: &str) {
        sqlx::query(
            "INSERT INTO device_capability_reports( \
                 device_id,user_id,revision,max_record_schema, \
                 host_attachment_manifest_versions,max_attachment_bytes,signature \
             ) VALUES($1,$2,1,$3,$4::jsonb,$5,'test-signature')",
        )
        .bind(DEVICE_ID)
        .bind(USER_ID)
        .bind(max_schema)
        .bind(versions)
        .bind(if max_schema >= 2 {
            1_073_741_824_i64
        } else {
            0
        })
        .execute(pool)
        .await
        .unwrap();
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_accepts_live_token_and_resolves_active_signing_key() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        let user = auth.authenticate_token(ACCESS_TOKEN, true).await.unwrap();
        assert_eq!(user.user_id, USER_ID);
        assert_eq!(user.device_id, DEVICE_ID);
        assert_eq!(user.session_id, SESSION_ID);
        assert_eq!(user.access_hash, crate::sha256_hex(ACCESS_TOKEN.as_bytes()));
        assert!(user.declares_record_schema2);
        assert_eq!(
            auth.active_device_signing_key(USER_ID, DEVICE_ID)
                .await
                .unwrap()
                .as_deref(),
            Some(SIGNING_KEY)
        );
        assert_eq!(
            auth.active_device_signing_key(USER_ID, "missing-device")
                .await
                .unwrap(),
            None
        );

        // An imported/corrupted database with the same access hash on two
        // sessions must not select an arbitrary principal.
        insert_session(
            &database.pool,
            "pg-auth-duplicate-session",
            ACCESS_TOKEN,
            "CURRENT_TIMESTAMP+INTERVAL '1 hour'",
            None,
        )
        .await;
        let error = auth
            .authenticate_token(ACCESS_TOKEN, false)
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::UNAUTHORIZED);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_rejects_missing_unknown_and_out_of_bounds_tokens() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        for token in ["", "too-short", &"x".repeat(129)] {
            let error = auth.authenticate_token(token, false).await.unwrap_err();
            assert_eq!(error.status, axum::http::StatusCode::UNAUTHORIZED);
        }
        let error = auth
            .authenticate_token("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", false)
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::UNAUTHORIZED);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_rejects_expired_and_revoked_sessions() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());
        let expired_token = "expired-token-0123456789abcdef0123";
        let revoked_token = "revoked-token-0123456789abcdef0123";
        insert_session(
            &database.pool,
            "pg-auth-expired-session",
            expired_token,
            "CURRENT_TIMESTAMP-INTERVAL '1 second'",
            None,
        )
        .await;
        insert_session(
            &database.pool,
            "pg-auth-revoked-session",
            revoked_token,
            "CURRENT_TIMESTAMP+INTERVAL '1 hour'",
            Some("CURRENT_TIMESTAMP"),
        )
        .await;

        for token in [expired_token, revoked_token] {
            let error = auth.authenticate_token(token, false).await.unwrap_err();
            assert_eq!(error.status, axum::http::StatusCode::UNAUTHORIZED);
        }

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_rejects_disabled_account_and_device() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        sqlx::query("UPDATE users SET status='disabled' WHERE user_id=$1")
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(auth.authenticate_token(ACCESS_TOKEN, false).await.is_err());
        assert_eq!(
            auth.active_device_signing_key(USER_ID, DEVICE_ID)
                .await
                .unwrap(),
            None
        );

        sqlx::query("UPDATE users SET status='active' WHERE user_id=$1")
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(auth.authenticate_token(ACCESS_TOKEN, false).await.is_err());
        assert_eq!(
            auth.active_device_signing_key(USER_ID, DEVICE_ID)
                .await
                .unwrap(),
            None
        );

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_logout_audit_is_atomic_and_replay_is_rejected() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        let user = auth.authenticate_token(ACCESS_TOKEN, false).await.unwrap();
        auth.revoke_authenticated_session(&user, &AUDIT_SCOPE_KEY)
            .await
            .unwrap();

        let revoked_at: Option<chrono::DateTime<chrono::Utc>> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id=$1")
                .bind(SESSION_ID)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert!(revoked_at.is_some());

        let event = sqlx::query(
            "SELECT scope_type,scope_id,actor_user_id,actor_device_id,action, \
                    resource_type,resource_id,result,source \
             FROM audit_events WHERE action='auth.logout_succeeded'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(event.get::<String, _>("scope_type"), "account");
        assert_eq!(
            event.get::<String, _>("scope_id"),
            crate::audit::account_scope_id(&AUDIT_SCOPE_KEY, USER_ID).unwrap()
        );
        assert_eq!(
            event.get::<Option<String>, _>("actor_user_id").as_deref(),
            Some(USER_ID)
        );
        assert_eq!(
            event.get::<Option<String>, _>("actor_device_id").as_deref(),
            Some(DEVICE_ID)
        );
        assert_eq!(event.get::<String, _>("resource_type"), "session");
        assert_eq!(
            event.get::<Option<String>, _>("resource_id").as_deref(),
            Some(SESSION_ID)
        );
        assert_eq!(event.get::<String, _>("result"), "success");
        assert_eq!(event.get::<String, _>("source"), "api");

        let replay = auth
            .revoke_authenticated_session(&user, &AUDIT_SCOPE_KEY)
            .await
            .unwrap_err();
        assert_eq!(replay.status, axum::http::StatusCode::UNAUTHORIZED);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.logout_succeeded'",
            )
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            1,
            "replaying a revoked principal must not append another logout audit event"
        );

        let rollback_token = "logout-rollback-token-0123456789ab";
        insert_session(
            &database.pool,
            "pg-auth-rollback-session",
            rollback_token,
            "CURRENT_TIMESTAMP+INTERVAL '1 hour'",
            None,
        )
        .await;
        let rollback_user = auth
            .authenticate_token(rollback_token, false)
            .await
            .unwrap();
        sqlx::query(
            "ALTER TABLE audit_events ADD CONSTRAINT reject_rollback_logout_audit \
             CHECK (resource_id IS DISTINCT FROM 'pg-auth-rollback-session')",
        )
        .execute(&database.pool)
        .await
        .unwrap();

        assert!(
            auth.revoke_authenticated_session(&rollback_user, &AUDIT_SCOPE_KEY)
                .await
                .is_err()
        );
        let rollback_revoked_at: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT revoked_at FROM sessions WHERE session_id='pg-auth-rollback-session'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(
            rollback_revoked_at.is_none(),
            "an audit insert failure must roll back session revocation"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM audit_events WHERE action='auth.logout_succeeded'",
            )
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            1,
            "a failed logout must not append an audit event"
        );

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_drops_v2_report_without_marker_but_retains_it_with_marker() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        insert_capability_report(&database.pool, 2, "[1,2]").await;
        let marked = auth.authenticate_token(ACCESS_TOKEN, true).await.unwrap();
        assert!(marked.declares_record_schema2);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM device_capability_reports WHERE device_id=$1",
            )
            .bind(DEVICE_ID)
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            1,
            "an explicit schema-2 marker retains the v2 capability report"
        );

        let unmarked = auth.authenticate_token(ACCESS_TOKEN, false).await.unwrap();
        assert!(!unmarked.declares_record_schema2);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM device_capability_reports WHERE device_id=$1",
            )
            .bind(DEVICE_ID)
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            0,
            "a missing marker invalidates the stored full v2 report"
        );

        // A partial/v1 report is not evidence of the complete v2 capability
        // and must survive authentication without a marker.
        insert_capability_report(&database.pool, 1, "[1]").await;
        auth.authenticate_token(ACCESS_TOKEN, false).await.unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM device_capability_reports WHERE device_id=$1",
            )
            .bind(DEVICE_ID)
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            1,
            "missing schema-2 marker leaves a non-v2 capability report untouched"
        );

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_auth_invalidates_redaction_report_without_erasing_revision_floor() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,account_id,revision,sync_redaction_version,signature \
             ) VALUES($1,$2,7,1,'signed-report')",
        )
        .bind(DEVICE_ID)
        .bind(USER_ID)
        .execute(&database.pool)
        .await
        .unwrap();

        auth.authenticate_token_with_markers(ACCESS_TOKEN, false, false)
            .await
            .unwrap();
        let row = sqlx::query(
            "SELECT revision,invalidated_at FROM device_redaction_capability_reports WHERE device_id=$1",
        )
        .bind(DEVICE_ID)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(row.get::<i64, _>("revision"), 7);
        assert!(
            row.get::<Option<chrono::DateTime<chrono::Utc>>, _>("invalidated_at")
                .is_some()
        );

        auth.authenticate_token_with_markers(ACCESS_TOKEN, false, true)
            .await
            .unwrap();
        let still_invalidated: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT invalidated_at FROM device_redaction_capability_reports WHERE device_id=$1",
        )
        .bind(DEVICE_ID)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(still_invalidated.is_some());
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL sync-auth acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_sync_write_fence_catches_report_published_after_authentication() {
        let database = TestDatabase::create().await;
        let auth = PgSyncAuthRepository::new(database.pool.clone());

        // Capture the old request principal while no redaction report exists.
        let delayed_request = auth
            .authenticate_token_with_markers(ACCESS_TOKEN, false, false)
            .await
            .unwrap();
        assert!(!delayed_request.declares_sync_redaction_v1);
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM device_redaction_capability_reports WHERE device_id=$1",
            )
            .bind(DEVICE_ID)
            .fetch_one(&database.pool)
            .await
            .unwrap(),
            0
        );

        // Another request publishes a report after the delayed request's auth
        // read. The sync write fence then takes the same session/account/device
        // locks as production commit paths and must invalidate in that txn.
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,account_id,revision,sync_redaction_version,signature \
             ) VALUES($1,$2,11,1,'signed-report')",
        )
        .bind(DEVICE_ID)
        .bind(USER_ID)
        .execute(&database.pool)
        .await
        .unwrap();

        let mut tx = database.pool.begin().await.unwrap();
        PgSyncAuthRepository::recheck_active_principal_for_sync_tx(&mut tx, &delayed_request)
            .await
            .unwrap();
        sqlx::query("UPDATE devices SET name=name WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&mut *tx)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let row = sqlx::query(
            "SELECT revision,invalidated_at FROM device_redaction_capability_reports WHERE device_id=$1",
        )
        .bind(DEVICE_ID)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(row.get::<i64, _>("revision"), 11);
        assert!(
            row.get::<Option<chrono::DateTime<chrono::Utc>>, _>("invalidated_at")
                .is_some()
        );
        database.cleanup().await;
    }
}

//! PostgreSQL-backed shared authentication rate limits.
//!
//! This capability mirrors the bounded SQLite limiter while storing counters
//! in the shared PostgreSQL database so independent service processes enforce
//! the same budgets. The restricted runtime selects it for prelogin and
//! password login; registration, recovery, and MFA routes remain unavailable.

use std::{
    net::IpAddr,
    sync::atomic::{AtomicI64, Ordering},
};

use hmac::{Hmac, Mac};
use sha2::Sha256;
use sqlx::{PgPool, Postgres, Transaction};

use crate::{ApiError, AuthRateLimits, rate_limit::AuthOperation};

type HmacSha256 = Hmac<Sha256>;

const MAX_COUNTER_VALUE: i64 = 1_000_000;
const MAX_RATE_LIMIT_BUCKETS: i64 = 100_000;
const MAX_PRUNE_BUCKET_ROWS: i64 = 1_000;
const CAPACITY_WARNING_INTERVAL_SECONDS: i64 = 60;
static LAST_CAPACITY_WARNING_UNIX: AtomicI64 = AtomicI64::new(0);

/// Owns the shared PostgreSQL counter store and the same instance-wide HMAC
/// key and rate-limit configuration used by the SQLite implementation.
#[derive(Clone)]
pub(crate) struct PgAuthRateLimitRepository {
    pool: PgPool,
    key: [u8; 32],
    limits: AuthRateLimits,
}

impl PgAuthRateLimitRepository {
    /// `key` must be provisioned identically on every service node. It is
    /// never stored in PostgreSQL. The pool must use a schema migrated with
    /// `migrations/postgres/0004_auth_rate_limits.sql`.
    pub(crate) fn new(pool: PgPool, key: [u8; 32], limits: AuthRateLimits) -> Self {
        Self { pool, key, limits }
    }

    /// Atomically consumes a user, user+peer, and (when the first two pass)
    /// peer-IP bucket. `username` must already be normalized. Missing peer
    /// addresses share the stable `unknown` IP bucket.
    pub(crate) async fn consume(
        &self,
        operation: AuthOperation,
        username: &str,
        peer: Option<IpAddr>,
    ) -> Result<Option<u64>, ApiError> {
        let now: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&self.pool)
                .await
                .map_err(ApiError::internal)?;
        self.consume_at(operation, username, peer, now).await
    }

    async fn consume_at(
        &self,
        operation: AuthOperation,
        username: &str,
        peer: Option<IpAddr>,
        now: i64,
    ) -> Result<Option<u64>, ApiError> {
        self.consume_at_with_capacity(operation, username, peer, now, MAX_RATE_LIMIT_BUCKETS)
            .await
    }

    async fn consume_at_with_capacity(
        &self,
        operation: AuthOperation,
        username: &str,
        peer: Option<IpAddr>,
        now: i64,
        max_buckets: i64,
    ) -> Result<Option<u64>, ApiError> {
        let window = self.limits.window_seconds;
        if window <= 0 {
            return Err(ApiError::internal(
                "invalid authentication rate-limit window",
            ));
        }
        let window_started = now.div_euclid(window) * window;
        let retry_after = window_started
            .saturating_add(window)
            .saturating_sub(now)
            .max(1) as u64;
        let endpoint = operation_label(operation);
        let (user_limit, pair_limit, ip_limit) = operation_limits(operation, &self.limits);
        let peer_text = peer
            .map(|address| address.to_string())
            .unwrap_or_else(|| "unknown".into());
        let ip_hash = subject_hash(&self.key, "ip", endpoint, &peer_text)?;

        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        // Serialize all capacity checks and counter updates across connections
        // and service processes. Every writer, including pruning, takes this
        // singleton lock before touching bucket rows, matching SQLite's writer
        // reservation and avoiding a check/insert race at the hard cap.
        lock_bucket_metadata(&mut transaction).await?;
        delete_expired_buckets(&mut transaction, window_started, MAX_PRUNE_BUCKET_ROWS).await?;

        let result: Result<Option<u64>, ApiError> = async {
            // A peer that already crossed the broad budget cannot allocate
            // user/pair rows by changing the submitted username.
            if bucket_attempts(&mut transaction, "ip", endpoint, &ip_hash, window_started)
                .await?
                .is_some_and(|attempts| attempts > ip_limit)
            {
                return Ok(Some(retry_after));
            }

            let Some(user_attempts) = bump_bucket(
                &mut transaction,
                "user",
                endpoint,
                &subject_hash(&self.key, "user", endpoint, username)?,
                window_started,
                max_buckets,
            )
            .await?
            else {
                return Ok(Some(retry_after));
            };
            if user_attempts > user_limit {
                return Ok(Some(retry_after));
            }

            let pair_subject = format!("{username}\0{peer_text}");
            let Some(pair_attempts) = bump_bucket(
                &mut transaction,
                "pair",
                endpoint,
                &subject_hash(&self.key, "pair", endpoint, &pair_subject)?,
                window_started,
                max_buckets,
            )
            .await?
            else {
                return Ok(Some(retry_after));
            };
            if pair_attempts > pair_limit {
                return Ok(Some(retry_after));
            }

            // Only account attempts that passed their narrower budgets spend
            // the shared proxy-IP allowance.
            let Some(ip_attempts) = bump_bucket(
                &mut transaction,
                "ip",
                endpoint,
                &ip_hash,
                window_started,
                max_buckets,
            )
            .await?
            else {
                return Ok(Some(retry_after));
            };
            if ip_attempts > ip_limit {
                return Ok(Some(retry_after));
            }

            Ok(None)
        }
        .await;

        // Limited attempts still commit counters and pruning, exactly as the
        // SQLite caller commits its transaction after receiving Some(retry).
        let result = result?;
        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(result)
    }

    /// Removes one bounded batch of counters that cannot participate in the
    /// current retention horizon. The metadata lock comes first, preserving
    /// the same order as request transactions and the database-wide bucket
    /// count triggers.
    pub(crate) async fn prune_expired(&self) -> Result<u64, ApiError> {
        if self.limits.window_seconds <= 0 {
            return Err(ApiError::internal(
                "invalid authentication rate-limit window",
            ));
        }
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_bucket_metadata(&mut transaction).await?;
        let now: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&mut *transaction)
                .await
                .map_err(ApiError::internal)?;
        let deleted = self
            .prune_expired_in_transaction(&mut transaction, now)
            .await?;
        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(deleted)
    }

    #[cfg(test)]
    async fn prune_expired_at(&self, now: i64) -> Result<u64, ApiError> {
        if self.limits.window_seconds <= 0 {
            return Err(ApiError::internal(
                "invalid authentication rate-limit window",
            ));
        }
        let mut transaction = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_bucket_metadata(&mut transaction).await?;
        let deleted = self
            .prune_expired_in_transaction(&mut transaction, now)
            .await?;
        transaction.commit().await.map_err(ApiError::internal)?;
        Ok(deleted)
    }

    async fn prune_expired_in_transaction(
        &self,
        transaction: &mut Transaction<'_, Postgres>,
        now: i64,
    ) -> Result<u64, ApiError> {
        let cutoff = now.saturating_sub(self.limits.window_seconds);
        delete_expired_buckets(transaction, cutoff, MAX_PRUNE_BUCKET_ROWS).await
    }
}

async fn delete_expired_buckets(
    transaction: &mut Transaction<'_, Postgres>,
    cutoff: i64,
    batch_size: i64,
) -> Result<u64, ApiError> {
    let deleted = sqlx::query(
        "WITH expired AS (\
             SELECT ctid FROM auth_rate_limits WHERE window_started < $1 \
             ORDER BY window_started,scope,endpoint,subject_hash LIMIT $2 \
             FOR UPDATE SKIP LOCKED\
         ) \
         DELETE FROM auth_rate_limits b USING expired e WHERE b.ctid=e.ctid",
    )
    .bind(cutoff)
    .bind(batch_size)
    .execute(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    Ok(deleted.rows_affected())
}

async fn lock_bucket_metadata(
    transaction: &mut Transaction<'_, Postgres>,
) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id = 1 FOR UPDATE")
        .fetch_one(&mut **transaction)
        .await
        .map_err(ApiError::internal)
}

async fn bucket_attempts(
    transaction: &mut Transaction<'_, Postgres>,
    scope: &str,
    endpoint: &str,
    subject_hash: &str,
    window_started: i64,
) -> Result<Option<i64>, ApiError> {
    sqlx::query_scalar(
        "SELECT attempts FROM auth_rate_limits \
         WHERE scope = $1 AND endpoint = $2 AND subject_hash = $3 AND window_started = $4",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(ApiError::internal)
}

async fn bump_bucket(
    transaction: &mut Transaction<'_, Postgres>,
    scope: &str,
    endpoint: &str,
    subject_hash: &str,
    window_started: i64,
    max_buckets: i64,
) -> Result<Option<i64>, ApiError> {
    let exists = bucket_attempts(transaction, scope, endpoint, subject_hash, window_started)
        .await?
        .is_some();
    if !exists {
        let bucket_count = lock_bucket_metadata(transaction).await?;
        if bucket_count >= max_buckets {
            log_capacity_exhausted(scope, endpoint, max_buckets);
            return Ok(None);
        }
    }

    sqlx::query(
        "INSERT INTO auth_rate_limits(scope, endpoint, subject_hash, window_started, attempts) \
         VALUES ($1, $2, $3, $4, 1) \
         ON CONFLICT(scope, endpoint, subject_hash, window_started) \
         DO UPDATE SET attempts = LEAST(auth_rate_limits.attempts + 1, $5)",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .bind(MAX_COUNTER_VALUE)
    .execute(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;

    sqlx::query_scalar(
        "SELECT attempts FROM auth_rate_limits \
         WHERE scope = $1 AND endpoint = $2 AND subject_hash = $3 AND window_started = $4",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .fetch_one(&mut **transaction)
    .await
    .map(Some)
    .map_err(ApiError::internal)
}

fn operation_label(operation: AuthOperation) -> &'static str {
    match operation {
        AuthOperation::Prelogin => "prelogin",
        AuthOperation::Login => "login",
        AuthOperation::MfaLogin => "mfa_login",
        AuthOperation::Register => "register",
        AuthOperation::RecoveryStart => "recovery_start",
        AuthOperation::RecoveryComplete => "recovery_complete",
    }
}

fn operation_limits(operation: AuthOperation, limits: &AuthRateLimits) -> (i64, i64, i64) {
    match operation {
        AuthOperation::Prelogin => (
            limits.prelogin_user_limit,
            limits.prelogin_pair_limit,
            limits.prelogin_ip_limit,
        ),
        AuthOperation::Login | AuthOperation::MfaLogin => (
            limits.login_user_limit,
            limits.login_pair_limit,
            limits.login_ip_limit,
        ),
        AuthOperation::Register => (
            limits.register_user_limit,
            limits.register_pair_limit,
            limits.register_ip_limit,
        ),
        AuthOperation::RecoveryStart => (
            limits.recovery_start_user_limit,
            limits.recovery_start_pair_limit,
            limits.recovery_start_ip_limit,
        ),
        AuthOperation::RecoveryComplete => (
            limits.recovery_complete_user_limit,
            limits.recovery_complete_pair_limit,
            limits.recovery_complete_ip_limit,
        ),
    }
}

fn subject_hash(
    key: &[u8; 32],
    scope: &str,
    endpoint: &str,
    subject: &str,
) -> Result<String, ApiError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(ApiError::internal)?;
    mac.update(b"atermius/auth-rate-limit/v1\0");
    mac.update(scope.as_bytes());
    mac.update(b"\0");
    mac.update(endpoint.as_bytes());
    mac.update(b"\0");
    mac.update(subject.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

fn log_capacity_exhausted(scope: &str, endpoint: &str, max_buckets: i64) {
    let now = chrono::Utc::now().timestamp();
    loop {
        let last = LAST_CAPACITY_WARNING_UNIX.load(Ordering::Relaxed);
        if last != 0 && now.saturating_sub(last) < CAPACITY_WARNING_INTERVAL_SECONDS {
            return;
        }
        if LAST_CAPACITY_WARNING_UNIX
            .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
        {
            tracing::warn!(
                event = "auth_rate_limit_capacity_exhausted",
                scope,
                endpoint,
                max_active_window_buckets = max_buckets,
                "authentication rate limiter reached its bounded bucket capacity"
            );
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{net::IpAddr, str::FromStr, sync::Arc};

    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const MIGRATION: &str = include_str!("../migrations/postgres/0004_auth_rate_limits.sql");
    const KEY: [u8; 32] = [0x4d; 32];
    const TEST_DB_URL_ENV: &str = "ATERMIUS_TEST_PG_URL";

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        options: PgConnectOptions,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var(TEST_DB_URL_ENV)
                .expect("ignored PostgreSQL rate-limit tests require ATERMIUS_TEST_PG_URL");
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
            let schema = format!("atermius_pg_rate_limit_{}", Uuid::new_v4().simple());
            if let Err(error) = sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
            {
                let cleanup = cleanup_failed_setup(admin_pool.clone(), None, &schema).await;
                admin_pool.close().await;
                panic_setup(
                    "create isolated PostgreSQL rate-limit schema",
                    error,
                    cleanup,
                );
            }
            let pool_options = options
                .clone()
                .options([("search_path", format!("\"{schema}\""))]);
            let pool =
                match connect_and_migrate(pool_options, &admin_pool, &schema, MIGRATION).await {
                    Ok(pool) => pool,
                    Err(error) => {
                        admin_pool.close().await;
                        panic!("{error}");
                    }
                };
            Self {
                pool,
                admin_pool,
                options,
                schema,
                cleaned: false,
            }
        }

        async fn second_pool(&self) -> PgPool {
            PgPoolOptions::new()
                .max_connections(8)
                .connect_with(
                    self.options
                        .clone()
                        .options([("search_path", format!("\"{}\"", self.schema))]),
                )
                .await
                .expect("connect second PostgreSQL pool to shared rate-limit schema")
        }

        async fn cleanup(mut self, extra_pools: Vec<PgPool>) {
            for pool in extra_pools {
                pool.close().await;
            }
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL rate-limit schema");
            let exists: bool = sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
                .bind(&self.schema)
                .fetch_one(&self.admin_pool)
                .await
                .expect("verify isolated schema cleanup");
            assert!(!exists, "isolated PostgreSQL schema remained after cleanup");
            self.cleaned = true;
            self.admin_pool.close().await;
        }
    }

    async fn cleanup_failed_setup(
        admin_pool: PgPool,
        app_pool: Option<PgPool>,
        schema: &str,
    ) -> Result<(), sqlx::Error> {
        if let Some(pool) = app_pool {
            pool.close().await;
        }
        sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
            .execute(&admin_pool)
            .await?;
        Ok(())
    }

    async fn connect_and_migrate(
        options: PgConnectOptions,
        admin_pool: &PgPool,
        schema: &str,
        migration: &str,
    ) -> Result<PgPool, String> {
        let pool = match PgPoolOptions::new()
            .max_connections(8)
            .connect_with(options)
            .await
        {
            Ok(pool) => pool,
            Err(error) => {
                let cleanup = cleanup_failed_setup(admin_pool.clone(), None, schema).await;
                return Err(setup_error(
                    "connect isolated PostgreSQL search path",
                    error,
                    cleanup,
                ));
            }
        };
        if let Err(error) = sqlx::raw_sql(migration).execute(&pool).await {
            let cleanup =
                cleanup_failed_setup(admin_pool.clone(), Some(pool.clone()), schema).await;
            return Err(setup_error(
                "apply PostgreSQL auth rate-limit migration",
                error,
                cleanup,
            ));
        }
        Ok(pool)
    }

    fn setup_error(
        action: &str,
        error: impl std::fmt::Display,
        cleanup: Result<(), sqlx::Error>,
    ) -> String {
        match cleanup {
            Ok(()) => format!("{action} failed; isolated schema cleanup completed: {error}"),
            Err(cleanup_error) => format!(
                "{action} failed: {error}; isolated schema cleanup also failed: {cleanup_error}"
            ),
        }
    }

    fn panic_setup(
        action: &str,
        error: impl std::fmt::Display,
        cleanup: Result<(), sqlx::Error>,
    ) -> ! {
        panic!("{}", setup_error(action, error, cleanup));
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

    fn limits() -> AuthRateLimits {
        let mut limits = AuthRateLimits::default();
        limits.window_seconds = 60;
        limits
    }

    fn repository(pool: PgPool, limits: AuthRateLimits) -> PgAuthRateLimitRepository {
        PgAuthRateLimitRepository::new(pool, KEY, limits)
    }

    fn ip(value: &str) -> Option<IpAddr> {
        Some(value.parse().unwrap())
    }

    #[tokio::test]
    #[ignore = "requires a disposable PostgreSQL database via ATERMIUS_TEST_PG_URL"]
    async fn cross_pool_attempts_share_atomic_user_limit_and_counter() {
        let database = TestDatabase::create().await;
        let second_pool = database.second_pool().await;
        let mut policy = limits();
        policy.prelogin_user_limit = 10;
        policy.prelogin_pair_limit = 1_000;
        policy.prelogin_ip_limit = 1_000;
        let first = Arc::new(repository(database.pool.clone(), policy.clone()));
        let second = Arc::new(repository(second_pool.clone(), policy));

        let workers = (0..32)
            .map(|index| {
                let repository = if index % 2 == 0 {
                    first.clone()
                } else {
                    second.clone()
                };
                tokio::spawn(async move {
                    repository
                        .consume_at(
                            AuthOperation::Prelogin,
                            "shared@example.test",
                            ip("192.0.2.9"),
                            1_800_000_000,
                        )
                        .await
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();
        let mut limited = 0;
        for worker in workers {
            if worker.await.unwrap().is_some() {
                limited += 1;
            }
        }
        assert_eq!(limited, 22);
        let attempts: i64 = sqlx::query_scalar(
            "SELECT attempts FROM auth_rate_limits WHERE scope='user' AND endpoint='prelogin'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(attempts, 32);
        let bucket_count: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(bucket_count, 3);

        database.cleanup(vec![second_pool]).await;
    }

    #[tokio::test]
    #[ignore = "requires a disposable PostgreSQL database via ATERMIUS_TEST_PG_URL"]
    async fn broad_ip_precheck_fixed_windows_and_hmac_storage_match_sqlite() {
        let database = TestDatabase::create().await;
        let mut policy = limits();
        policy.prelogin_ip_limit = 2;
        policy.prelogin_user_limit = 100;
        policy.prelogin_pair_limit = 100;
        let limiter = repository(database.pool.clone(), policy);
        for (index, username) in ["one@example.test", "two@example.test", "three@example.test"]
            .into_iter()
            .enumerate()
        {
            let result = limiter
                .consume_at(
                    AuthOperation::Prelogin,
                    username,
                    ip("198.51.100.8"),
                    1_800_000_000,
                )
                .await
                .unwrap();
            assert_eq!(result.is_some(), index == 2);
        }
        assert_eq!(
            limiter
                .consume_at(
                    AuthOperation::Prelogin,
                    "fresh@example.test",
                    ip("198.51.100.8"),
                    1_800_000_001,
                )
                .await
                .unwrap(),
            Some(59)
        );
        for scope in ["user", "pair"] {
            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM auth_rate_limits WHERE scope=$1 AND endpoint='prelogin'",
            )
            .bind(scope)
            .fetch_one(&database.pool)
            .await
            .unwrap();
            assert_eq!(
                count, 3,
                "unexpected {scope} bucket growth after IP precheck"
            );
        }
        let stored_hashes: Vec<String> = sqlx::query_scalar(
            "SELECT subject_hash FROM auth_rate_limits WHERE endpoint='prelogin'",
        )
        .fetch_all(&database.pool)
        .await
        .unwrap();
        assert!(stored_hashes.iter().all(|hash| hash.len() == 64));
        assert!(
            stored_hashes
                .iter()
                .all(|hash| !hash.contains("example") && !hash.contains("198.51.100.8"))
        );

        let mut new_window_policy = limits();
        new_window_policy.login_user_limit = 2;
        new_window_policy.login_pair_limit = 10;
        new_window_policy.login_ip_limit = 10;
        let login = repository(database.pool.clone(), new_window_policy);
        assert_eq!(
            login
                .consume_at(
                    AuthOperation::Login,
                    "window@example.test",
                    None,
                    1_800_000_000,
                )
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            login
                .consume_at(
                    AuthOperation::Login,
                    "window@example.test",
                    None,
                    1_800_000_001,
                )
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            login
                .consume_at(
                    AuthOperation::Login,
                    "window@example.test",
                    None,
                    1_800_000_002,
                )
                .await
                .unwrap(),
            Some(58)
        );
        assert_eq!(
            login
                .consume_at(
                    AuthOperation::Login,
                    "window@example.test",
                    None,
                    1_800_000_060,
                )
                .await
                .unwrap(),
            None
        );
        database.cleanup(Vec::new()).await;
    }

    #[tokio::test]
    #[ignore = "requires a disposable PostgreSQL database via ATERMIUS_TEST_PG_URL"]
    async fn capacity_counter_saturation_and_pruning_are_bounded() {
        let database = TestDatabase::create().await;
        let limiter = repository(database.pool.clone(), limits());
        let timestamp = 1_800_000_000;
        assert_eq!(
            limiter
                .consume_at_with_capacity(
                    AuthOperation::Prelogin,
                    "first@example.test",
                    ip("203.0.113.4"),
                    timestamp,
                    3,
                )
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            limiter
                .consume_at_with_capacity(
                    AuthOperation::Prelogin,
                    "second@example.test",
                    ip("203.0.113.4"),
                    timestamp,
                    3,
                )
                .await
                .unwrap(),
            Some(60)
        );
        let after_capacity: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(after_capacity, 3);

        let saturated_hash = subject_hash(&KEY, "user", "login", "saturated@example.test").unwrap();
        sqlx::query(
            "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) \
             VALUES('user','login',$1,$2,$3)",
        )
        .bind(&saturated_hash)
        .bind(timestamp)
        .bind(MAX_COUNTER_VALUE - 1)
        .execute(&database.pool)
        .await
        .unwrap();
        let mut transaction = database.pool.begin().await.unwrap();
        lock_bucket_metadata(&mut transaction).await.unwrap();
        assert_eq!(
            bump_bucket(
                &mut transaction,
                "user",
                "login",
                &saturated_hash,
                timestamp,
                MAX_RATE_LIMIT_BUCKETS,
            )
            .await
            .unwrap(),
            Some(MAX_COUNTER_VALUE)
        );
        assert_eq!(
            bump_bucket(
                &mut transaction,
                "user",
                "login",
                &saturated_hash,
                timestamp,
                MAX_RATE_LIMIT_BUCKETS,
            )
            .await
            .unwrap(),
            Some(MAX_COUNTER_VALUE)
        );
        transaction.commit().await.unwrap();

        // Seed two otherwise valid HMAC-shaped rows in adjacent windows to
        // exercise the strict maintenance cutoff boundary.
        let old_hash = "a".repeat(64);
        let boundary_hash = "b".repeat(64);
        for (hash, window) in [(&old_hash, timestamp), (&boundary_hash, timestamp + 60)] {
            sqlx::query(
                "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) \
                 VALUES('ip','register',$1,$2,1)",
            )
            .bind(hash)
            .bind(window)
            .execute(&database.pool)
            .await
            .unwrap();
        }
        limiter.prune_expired_at(timestamp + 120).await.unwrap();
        let retained: Vec<i64> = sqlx::query_scalar(
            "SELECT window_started FROM auth_rate_limits WHERE endpoint='register' ORDER BY window_started",
        )
        .fetch_all(&database.pool)
        .await
        .unwrap();
        assert_eq!(retained, vec![timestamp + 60]);
        let actual_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM auth_rate_limits")
            .fetch_one(&database.pool)
            .await
            .unwrap();
        let tracked_count: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(tracked_count, actual_count);
        database.cleanup(Vec::new()).await;
    }

    #[tokio::test]
    #[ignore = "requires a disposable PostgreSQL database via ATERMIUS_TEST_PG_URL"]
    async fn storage_failure_fails_closed() {
        let database = TestDatabase::create().await;
        let limiter = repository(database.pool.clone(), limits());
        sqlx::query("DROP TABLE auth_rate_limit_meta")
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(
            limiter
                .consume_at(
                    AuthOperation::Login,
                    "closed@example.test",
                    ip("192.0.2.20"),
                    1_800_000_000,
                )
                .await
                .is_err()
        );
        database.cleanup(Vec::new()).await;
    }

    #[tokio::test]
    #[ignore = "requires a disposable PostgreSQL database via ATERMIUS_TEST_PG_URL"]
    async fn failed_migration_setup_drops_its_isolated_schema() {
        let database = TestDatabase::create().await;
        let schema = format!("atermius_pg_rate_limit_failed_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&database.admin_pool)
            .await
            .unwrap();
        let options = database
            .options
            .clone()
            .options([("search_path", format!("\"{schema}\""))]);
        let failure = match connect_and_migrate(
            options,
            &database.admin_pool,
            &schema,
            "INVALID SQL",
        )
        .await
        {
            Err(error) => error,
            Ok(pool) => {
                pool.close().await;
                panic!("invalid migration unexpectedly succeeded");
            }
        };
        assert!(failure.contains("isolated schema cleanup completed"));
        let exists: bool = sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
            .bind(&schema)
            .fetch_one(&database.admin_pool)
            .await
            .unwrap();
        assert!(
            !exists,
            "schema created for failed migration was not removed"
        );
        database.cleanup(Vec::new()).await;
    }
}

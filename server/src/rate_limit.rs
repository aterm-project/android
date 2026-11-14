use std::net::IpAddr;
use std::sync::atomic::{AtomicI64, Ordering};

use hmac::{Hmac, Mac};
use sha2::Sha256;
use sqlx::{Row, Sqlite, Transaction};

use crate::{ApiError, AppState};

type HmacSha256 = Hmac<Sha256>;
const MAX_COUNTER_VALUE: i64 = 1_000_000;
const MAX_RATE_LIMIT_BUCKETS: i64 = 100_000;
const CAPACITY_WARNING_INTERVAL_SECONDS: i64 = 60;
static LAST_CAPACITY_WARNING_UNIX: AtomicI64 = AtomicI64::new(0);

#[derive(Debug, Clone, Copy)]
pub(crate) enum AuthOperation {
    Prelogin,
    Login,
    MfaLogin,
    Register,
    RecoveryStart,
    RecoveryComplete,
}

impl AuthOperation {
    fn label(self) -> &'static str {
        match self {
            Self::Prelogin => "prelogin",
            Self::Login => "login",
            Self::MfaLogin => "mfa_login",
            Self::Register => "register",
            Self::RecoveryStart => "recovery_start",
            Self::RecoveryComplete => "recovery_complete",
        }
    }

    fn limits(self, state: &AppState) -> (i64, i64, i64) {
        let limits = &state.config.auth_rate_limits;
        match self {
            Self::Prelogin => (
                limits.prelogin_user_limit,
                limits.prelogin_pair_limit,
                limits.prelogin_ip_limit,
            ),
            Self::Login => (
                limits.login_user_limit,
                limits.login_pair_limit,
                limits.login_ip_limit,
            ),
            Self::MfaLogin => (
                limits.login_user_limit,
                limits.login_pair_limit,
                limits.login_ip_limit,
            ),
            Self::Register => (
                limits.register_user_limit,
                limits.register_pair_limit,
                limits.register_ip_limit,
            ),
            Self::RecoveryStart => (
                limits.recovery_start_user_limit,
                limits.recovery_start_pair_limit,
                limits.recovery_start_ip_limit,
            ),
            Self::RecoveryComplete => (
                limits.recovery_complete_user_limit,
                limits.recovery_complete_pair_limit,
                limits.recovery_complete_ip_limit,
            ),
        }
    }
}

/// Atomically consumes an authentication attempt in a user bucket, a
/// user+peer pair bucket, and a broad peer-IP bucket. Returns the number of
/// seconds until the current fixed window expires when any bucket is over
/// limit. `username` must already be normalized. When no peer address is
/// available, the stable `unknown` peer bucket still applies.
pub(crate) async fn consume(
    state: &AppState,
    transaction: &mut Transaction<'_, Sqlite>,
    operation: AuthOperation,
    username: &str,
    peer: Option<IpAddr>,
) -> Result<Option<u64>, ApiError> {
    consume_at(
        state,
        transaction,
        operation,
        username,
        peer,
        chrono::Utc::now().timestamp(),
    )
    .await
}

async fn consume_at(
    state: &AppState,
    transaction: &mut Transaction<'_, Sqlite>,
    operation: AuthOperation,
    username: &str,
    peer: Option<IpAddr>,
    now: i64,
) -> Result<Option<u64>, ApiError> {
    let window = state.config.auth_rate_limits.window_seconds;
    let window_started = now.div_euclid(window) * window;
    let retry_after = (window_started + window - now).max(1) as u64;
    let endpoint = operation.label();
    let (user_limit, pair_limit, ip_limit) = operation.limits(state);
    let peer_text = peer
        .map(|address| address.to_string())
        .unwrap_or_else(|| "unknown".into());

    // Do not let a peer that has already crossed its broad budget allocate a
    // fresh user/pair row on every request by varying the username. Preserve
    // the attempt that first crosses the IP limit below, so its existing
    // response and counter semantics remain unchanged.
    let ip_hash = subject_hash(&state.auth_rate_key, "ip", endpoint, &peer_text)?;

    // SQLite transactions are deferred. Take the writer reservation before
    // reading counters so parallel attempts cannot all pass the same limit.
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM auth_rate_limits WHERE window_started<?")
        .bind(window_started)
        .execute(&mut **transaction)
        .await
        .map_err(ApiError::internal)?;
    if bucket_attempts(transaction, "ip", endpoint, &ip_hash, window_started)
        .await?
        .is_some_and(|attempts| attempts > ip_limit)
    {
        return Ok(Some(retry_after));
    }

    let user_hash = subject_hash(&state.auth_rate_key, "user", endpoint, username)?;
    let Some(user_attempts) = bump_bucket(
        transaction,
        "user",
        endpoint,
        &user_hash,
        window_started,
        MAX_RATE_LIMIT_BUCKETS,
    )
    .await?
    else {
        return Ok(Some(retry_after));
    };
    if user_attempts > user_limit {
        return Ok(Some(retry_after));
    }

    let pair_subject = format!("{username}\0{peer_text}");
    let pair_hash = subject_hash(&state.auth_rate_key, "pair", endpoint, &pair_subject)?;
    let Some(pair_attempts) = bump_bucket(
        transaction,
        "pair",
        endpoint,
        &pair_hash,
        window_started,
        MAX_RATE_LIMIT_BUCKETS,
    )
    .await?
    else {
        return Ok(Some(retry_after));
    };
    if pair_attempts > pair_limit {
        return Ok(Some(retry_after));
    }

    // Only attempts that pass the account and account+peer buckets consume
    // the shared IP budget. Otherwise one throttled username behind Caddy
    // could exhaust the proxy's broad bucket and block every other account.
    let Some(ip_attempts) = bump_bucket(
        transaction,
        "ip",
        endpoint,
        &ip_hash,
        window_started,
        MAX_RATE_LIMIT_BUCKETS,
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

async fn bucket_attempts(
    transaction: &mut Transaction<'_, Sqlite>,
    scope: &str,
    endpoint: &str,
    subject_hash: &str,
    window_started: i64,
) -> Result<Option<i64>, ApiError> {
    sqlx::query_scalar(
        "SELECT attempts FROM auth_rate_limits WHERE scope=? AND endpoint=? AND subject_hash=? AND window_started=?",
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
    transaction: &mut Transaction<'_, Sqlite>,
    scope: &str,
    endpoint: &str,
    subject_hash: &str,
    window_started: i64,
    max_buckets: i64,
) -> Result<Option<i64>, ApiError> {
    let exists: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM auth_rate_limits WHERE scope=? AND endpoint=? AND subject_hash=? AND window_started=?",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .fetch_optional(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    if exists.is_none() {
        let bucket_count: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&mut **transaction)
                .await
                .map_err(ApiError::internal)?;
        if bucket_count >= max_buckets {
            log_capacity_exhausted(scope, endpoint, max_buckets);
            return Ok(None);
        }
    }
    sqlx::query(
        "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) VALUES(?,?,?,?,1) \
         ON CONFLICT(scope,endpoint,subject_hash,window_started) DO UPDATE SET attempts=MIN(auth_rate_limits.attempts+1,?)",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .bind(MAX_COUNTER_VALUE)
    .execute(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT attempts FROM auth_rate_limits WHERE scope=? AND endpoint=? AND subject_hash=? AND window_started=?",
    )
    .bind(scope)
    .bind(endpoint)
    .bind(subject_hash)
    .bind(window_started)
    .fetch_one(&mut **transaction)
    .await
    .map_err(ApiError::internal)?;
    row.try_get("attempts")
        .map(Some)
        .map_err(ApiError::internal)
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

/// Removes counters that cannot participate in the current fixed window.
/// It runs as part of the recurring database maintenance pass.
pub(crate) async fn prune_expired(state: &AppState, now: i64) -> Result<(), ApiError> {
    let cutoff = now - state.config.auth_rate_limits.window_seconds;
    sqlx::query("DELETE FROM auth_rate_limits WHERE window_started<?")
        .bind(cutoff)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{net::IpAddr, path::PathBuf, sync::Arc};

    use axum::response::IntoResponse;
    use sqlx::Row;
    use uuid::Uuid;

    use crate::{
        AuthRateLimits, Config, open_state,
        rate_limit::{AuthOperation, MAX_RATE_LIMIT_BUCKETS, bump_bucket, consume_at},
    };

    fn config(path: PathBuf) -> Config {
        let mut limits = AuthRateLimits::default();
        limits.window_seconds = 60;
        limits.login_user_limit = 2;
        limits.login_pair_limit = 2;
        limits.login_ip_limit = 100;
        limits.prelogin_user_limit = 10;
        limits.prelogin_pair_limit = 100;
        limits.prelogin_ip_limit = 100;
        limits.register_user_limit = 2;
        limits.register_pair_limit = 100;
        limits.register_ip_limit = 100;
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir: path,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: None,
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
            auth_rate_limits: limits,
        }
    }

    async fn state() -> crate::AppState {
        let directory = std::env::temp_dir().join(format!("atermius-rate-test-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&directory).unwrap();
        let db = format!("sqlite://{}/rate.db?mode=rwc", directory.display());
        open_state(&db, config(directory)).await.unwrap()
    }

    async fn attempt(
        state: &crate::AppState,
        operation: AuthOperation,
        username: &str,
        peer: Option<IpAddr>,
        now: i64,
    ) -> Option<u64> {
        let mut transaction = state.db.begin().await.unwrap();
        let result = consume_at(state, &mut transaction, operation, username, peer, now)
            .await
            .unwrap();
        transaction.commit().await.unwrap();
        result
    }

    #[tokio::test]
    async fn normalized_user_limit_applies_across_addresses_and_missing_ip_is_limited() {
        let state = state().await;
        let ip1 = Some("192.0.2.1".parse().unwrap());
        let ip2 = Some("192.0.2.2".parse().unwrap());
        let now: i64 = 1_800_000_000;
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "person@example.test",
                ip1,
                now
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "person@example.test",
                ip1,
                now
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "person@example.test",
                ip2,
                now
            )
            .await,
            Some(60)
        );

        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "missing@example.test",
                None,
                now
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "missing@example.test",
                None,
                now
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "missing@example.test",
                None,
                now
            )
            .await,
            Some(60)
        );
    }

    #[tokio::test]
    async fn fixed_window_expires_and_registration_has_its_own_limiter() {
        let state = state().await;
        let peer = Some("198.51.100.14".parse().unwrap());
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Register,
                "invitee@example.test",
                peer,
                1_800_000_000
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Register,
                "invitee@example.test",
                peer,
                1_800_000_001
            )
            .await,
            None
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Register,
                "invitee@example.test",
                peer,
                1_800_000_002
            )
            .await,
            Some(58)
        );
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Register,
                "invitee@example.test",
                peer,
                1_800_000_060
            )
            .await,
            None
        );
    }

    #[tokio::test]
    async fn repeated_limited_username_does_not_spend_shared_proxy_ip_budget() {
        let mut state = state().await;
        Arc::get_mut(&mut state.config)
            .unwrap()
            .auth_rate_limits
            .login_ip_limit = 4;
        let peer = Some("198.51.100.27".parse().unwrap());
        let now = 1_800_000_000;
        for index in 0..20 {
            let result = attempt(
                &state,
                AuthOperation::Login,
                "abusive@example.test",
                peer,
                now,
            )
            .await;
            assert_eq!(result.is_some(), index >= 2);
        }
        for username in ["first@example.test", "second@example.test"] {
            assert_eq!(
                attempt(&state, AuthOperation::Login, username, peer, now).await,
                None
            );
        }
        assert_eq!(
            attempt(
                &state,
                AuthOperation::Login,
                "third@example.test",
                peer,
                now
            )
            .await,
            Some(60)
        );
        let attempts: i64 = sqlx::query_scalar(
            "SELECT attempts FROM auth_rate_limits WHERE scope='ip' AND endpoint='login'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(attempts, 5);
    }

    #[tokio::test]
    async fn already_limited_ip_cannot_allocate_buckets_with_fresh_usernames() {
        let mut state = state().await;
        Arc::get_mut(&mut state.config)
            .unwrap()
            .auth_rate_limits
            .prelogin_ip_limit = 2;
        let peer = Some("198.51.100.44".parse().unwrap());
        let now = 1_800_000_000;

        // Keep the first request that crosses the broad limit as a normal
        // counted attempt. Later attempts from that peer must be rejected
        // before attacker-chosen usernames allocate more user/pair rows.
        for index in 0..25 {
            let username = format!("fresh-{index}@example.test");
            let result = attempt(&state, AuthOperation::Prelogin, &username, peer, now).await;
            assert_eq!(result.is_some(), index >= 2);
        }

        for scope in ["user", "pair"] {
            let count: i64 = sqlx::query_scalar(
                "SELECT COUNT(*) FROM auth_rate_limits WHERE scope=? AND endpoint='prelogin'",
            )
            .bind(scope)
            .fetch_one(&state.db)
            .await
            .unwrap();
            assert_eq!(count, 3, "unexpected {scope} bucket growth");
        }
        let ip_attempts: i64 = sqlx::query_scalar(
            "SELECT attempts FROM auth_rate_limits WHERE scope='ip' AND endpoint='prelogin'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(ip_attempts, 3);
    }

    #[tokio::test]
    async fn concurrent_attempts_serialize_and_count_every_request() {
        let state = Arc::new(state().await);
        let peer = Some("203.0.113.7".parse().unwrap());
        let workers = (0..32)
            .map(|_| {
                let state = state.clone();
                tokio::spawn(async move {
                    attempt(
                        &state,
                        AuthOperation::Prelogin,
                        "race@example.test",
                        peer,
                        1_800_000_000,
                    )
                    .await
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
        let row = sqlx::query(
            "SELECT attempts FROM auth_rate_limits WHERE scope='user' AND endpoint='prelogin'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(row.get::<i64, _>("attempts"), 32);
    }

    #[tokio::test]
    async fn limiter_storage_has_a_hard_bucket_cap() {
        let state = state().await;
        let window = 1_800_000_000;
        let mut transaction = state.db.begin().await.unwrap();
        sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
            .execute(&mut *transaction)
            .await
            .unwrap();
        assert_eq!(
            bump_bucket(&mut transaction, "user", "login", "subject-a", window, 1,)
                .await
                .unwrap(),
            Some(1)
        );
        assert_eq!(
            bump_bucket(&mut transaction, "user", "login", "subject-b", window, 1,)
                .await
                .unwrap(),
            None
        );
        transaction.commit().await.unwrap();
        let count: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(count, 1);
    }

    #[tokio::test]
    async fn full_bucket_cap_returns_controlled_limit_and_prunes_expired_rows_first() {
        let state = state().await;
        let now: i64 = 1_800_000_000;
        let current_window = now.div_euclid(60) * 60;
        let expired_window = current_window - 60;

        // Simulate a full 100k-row active window without inserting 100k test
        // rows. The expired row is real and its trigger updates the counter.
        sqlx::query(
            "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) VALUES('user','prelogin',?, ?,1)",
        )
        .bind("expired-test-bucket")
        .bind(expired_window)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("UPDATE auth_rate_limit_meta SET bucket_count=? WHERE id=1")
            .bind(MAX_RATE_LIMIT_BUCKETS)
            .execute(&state.db)
            .await
            .unwrap();

        let peer = Some("203.0.113.92".parse().unwrap());
        let first = attempt(
            &state,
            AuthOperation::Login,
            "capped@example.test",
            peer,
            now,
        )
        .await;
        assert_eq!(first, Some(60));
        let stale_rows: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM auth_rate_limits WHERE window_started<?")
                .bind(current_window)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(stale_rows, 0);
        let count: i64 =
            sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(count, MAX_RATE_LIMIT_BUCKETS);

        // Existing buckets continue to count, but a missing pair bucket cannot
        // be allocated at capacity. The public error remains a generic 429.
        let second = attempt(
            &state,
            AuthOperation::Login,
            "capped@example.test",
            peer,
            now,
        )
        .await;
        assert_eq!(second, Some(60));
        let response = crate::ApiError::rate_limited(second.unwrap()).into_response();
        assert_eq!(response.status(), axum::http::StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(response.headers()[axum::http::header::RETRY_AFTER], "60");
        let body = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body = String::from_utf8(body.to_vec()).unwrap();
        assert!(body.contains("\"code\":\"RATE_LIMITED\""));
        assert!(!body.contains("SQLITE") && !body.contains("database"));
    }
}

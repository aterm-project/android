use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0031_adds_mfa_schema_and_preserves_auth_buckets() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create temporary SQLite database");
    apply(&pool, include_str!("../migrations/0001_initial.sql")).await;
    apply(
        &pool,
        include_str!("../migrations/0004_auth_rate_limits.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0021_account_recovery.sql"),
    )
    .await;

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('user','user@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert account");
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES('device','user','test','sign','box','now')")
        .execute(&pool)
        .await
        .expect("insert device");
    sqlx::query(
        "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) \
         VALUES('user','login','existing-hash',100,7)",
    )
    .execute(&pool)
    .await
    .expect("seed a prior authentication bucket");

    apply(&pool, include_str!("../migrations/0031_auth_totp_mfa.sql")).await;

    let preserved: i64 = sqlx::query_scalar(
        "SELECT attempts FROM auth_rate_limits WHERE scope='user' AND endpoint='login' AND subject_hash='existing-hash' AND window_started=100",
    )
    .fetch_one(&pool)
    .await
    .expect("read preserved bucket");
    assert_eq!(preserved, 7);
    let count_before: i64 =
        sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
            .fetch_one(&pool)
            .await
            .expect("read limiter capacity count");
    assert_eq!(count_before, 1);

    sqlx::query(
        "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) \
         VALUES('user','mfa_login','mfa-hash',100,1)",
    )
    .execute(&pool)
    .await
    .expect("insert MFA login bucket");
    let count_after: i64 =
        sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
            .fetch_one(&pool)
            .await
            .expect("read limiter count after MFA bucket");
    assert_eq!(count_after, 2);
    assert!(
        sqlx::query(
            "INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) \
             VALUES('user','unknown','bad-hash',100,1)",
        )
        .execute(&pool)
        .await
        .is_err(),
        "the endpoint check remains closed to unknown operations"
    );

    sqlx::query(
        "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step) \
         VALUES('user','encrypted-seed',100,3)",
    )
    .execute(&pool)
    .await
    .expect("insert encrypted active TOTP row");
    sqlx::query(
        "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at) \
         VALUES('code','user','1234567890123456789012',lower(hex(randomblob(32))),100)",
    )
    .execute(&pool)
    .await
    .expect("insert salted recovery digest");
    sqlx::query(
        "INSERT INTO auth_mfa_login_challenges \
         (challenge_id_hash,user_id,device_id,credential_version,expires_at) \
         VALUES(lower(hex(randomblob(32))),'user','device',1,200)",
    )
    .execute(&pool)
    .await
    .expect("insert credential-bound challenge");
    assert!(
        sqlx::query("UPDATE auth_mfa_login_challenges SET attempt_count=6 WHERE user_id='user'",)
            .execute(&pool)
            .await
            .is_err(),
        "challenge attempts stay bounded"
    );

    sqlx::query("DELETE FROM users WHERE user_id='user'")
        .execute(&pool)
        .await
        .expect("delete account");
    let remaining: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM auth_mfa_login_challenges WHERE user_id='user'")
            .fetch_one(&pool)
            .await
            .expect("read cascaded challenge rows");
    assert_eq!(remaining, 0);
}

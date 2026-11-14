use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0021_adds_recovery_tables_and_preserves_limiter_buckets() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            sqlx::sqlite::SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create temporary SQLite database");

    for migration in [
        include_str!("../migrations/0001_initial.sql"),
        include_str!("../migrations/0002_account_invitations.sql"),
        include_str!("../migrations/0003_sync_history_retention.sql"),
        include_str!("../migrations/0004_auth_rate_limits.sql"),
        include_str!("../migrations/0005_vault_deletion.sql"),
        include_str!("../migrations/0006_object_gc.sql"),
        include_str!("../migrations/0007_history_pagination.sql"),
        include_str!("../migrations/0008_conflict_idempotency.sql"),
        include_str!("../migrations/0009_account_deletion.sql"),
        include_str!("../migrations/0010_notifications.sql"),
        include_str!("../migrations/0011_audit_events.sql"),
        include_str!("../migrations/0012_relay_ticket_hardening.sql"),
        include_str!("../migrations/0013_audit_login_results.sql"),
        include_str!("../migrations/0014_password_change_receipts.sql"),
        include_str!("../migrations/0015_conflict_resolution_time.sql"),
        include_str!("../migrations/0016_instance_audit_scope.sql"),
        include_str!("../migrations/0017_instance_key_transitions.sql"),
        include_str!("../migrations/0018_instance_audit_event_order.sql"),
        include_str!("../migrations/0019_instance_admin_account_listing.sql"),
        include_str!("../migrations/0020_instance_admin_jobs.sql"),
    ] {
        apply(&pool, migration).await;
    }

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('user','user@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert recovery owner");

    let old_subject = "a".repeat(64);
    sqlx::query("INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) VALUES('user','login',?,100,3)")
        .bind(&old_subject)
        .execute(&pool)
        .await
        .expect("store a pre-existing limiter bucket");

    apply(
        &pool,
        include_str!("../migrations/0021_account_recovery.sql"),
    )
    .await;

    let retained: (String, i64) =
        sqlx::query_as("SELECT endpoint,attempts FROM auth_rate_limits WHERE subject_hash=?")
            .bind(&old_subject)
            .fetch_one(&pool)
            .await
            .expect("preserve pre-existing limiter bucket");
    assert_eq!(retained, ("login".to_owned(), 3));

    let inserted: (i64, i64) = sqlx::query_as(
        "SELECT bucket_count,(SELECT COUNT(*) FROM auth_rate_limits) FROM auth_rate_limit_meta WHERE id=1",
    )
    .fetch_one(&pool)
    .await
    .expect("read bounded limiter accounting");
    assert_eq!(
        inserted.0, inserted.1,
        "migration keeps trigger count accurate"
    );

    let recovery_endpoints: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM pragma_table_info('auth_rate_limits') WHERE name='endpoint'",
    )
    .fetch_one(&pool)
    .await
    .expect("inspect rebuilt limiter schema");
    assert_eq!(recovery_endpoints, 1);

    sqlx::query("INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) VALUES('pair','recovery_start',?,200,1),('ip','recovery_complete',?,200,1)")
        .bind("b".repeat(64))
        .bind("c".repeat(64))
        .execute(&pool)
        .await
        .expect("accept the new recovery limiter endpoints");

    let bucket_count: i64 =
        sqlx::query_scalar("SELECT bucket_count FROM auth_rate_limit_meta WHERE id=1")
            .fetch_one(&pool)
            .await
            .expect("read bucket count after insert");
    assert_eq!(bucket_count, 3);

    let invalid_endpoint = sqlx::query("INSERT INTO auth_rate_limits(scope,endpoint,subject_hash,window_started,attempts) VALUES('user','inspect',? ,200,1)")
        .bind("d".repeat(64))
        .execute(&pool)
        .await;
    assert!(
        invalid_endpoint.is_err(),
        "only explicitly listed endpoints are accepted"
    );

    sqlx::query("INSERT INTO account_recovery(user_id,recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope,created_at,updated_at) VALUES('user',1,'sign','box','{}','{}',100,100)")
        .execute(&pool)
        .await
        .expect("store opaque recovery configuration");
    sqlx::query("INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES(?,?, 'user',1,500)")
        .bind("e".repeat(64))
        .bind("f".repeat(64))
        .execute(&pool)
        .await
        .expect("store challenge hashes");
    sqlx::query("INSERT INTO account_recovery_receipts(user_id,operation_id,request_digest,response_json,created_at) VALUES('user','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',?,'{}',100)")
        .bind("0".repeat(64))
        .execute(&pool)
        .await
        .expect("store HMAC-only operation receipt");

    let invalid_hash = sqlx::query("INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES('not-hex',?,'user',1,500)")
        .bind("1".repeat(64))
        .execute(&pool)
        .await;
    assert!(
        invalid_hash.is_err(),
        "challenge table only accepts lower-case SHA-256 hex"
    );

    sqlx::query("DELETE FROM users WHERE user_id='user'")
        .execute(&pool)
        .await
        .expect("delete account");
    let recovery_rows: i64 = sqlx::query_scalar(
        "SELECT (SELECT COUNT(*) FROM account_recovery)+(SELECT COUNT(*) FROM account_recovery_challenges)+(SELECT COUNT(*) FROM account_recovery_receipts)",
    )
    .fetch_one(&pool)
    .await
    .expect("verify account-scoped rows cascade");
    assert_eq!(recovery_rows, 0);

    let table_sql: String = sqlx::query(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='account_recovery_receipts'",
    )
    .fetch_one(&pool)
    .await
    .expect("read receipt table definition")
    .try_get("sql")
    .expect("receipt schema SQL");
    assert!(table_sql.contains("PRIMARY KEY(user_id, operation_id)"));
}

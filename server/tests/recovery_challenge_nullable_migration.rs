use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

async fn apply_through_0022(pool: &sqlx::SqlitePool) {
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
        include_str!("../migrations/0021_account_recovery.sql"),
        include_str!("../migrations/0022_recovery_generation_counter.sql"),
    ] {
        apply(pool, migration).await;
    }
}

#[tokio::test]
async fn migration_0023_allows_decoy_challenges_and_preserves_account_challenge_semantics() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create temporary SQLite database");
    apply_through_0022(&pool).await;

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('owner','owner@example.test','now'),('deleted-owner','deleted@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert account owners");

    let preserved = (
        "a".repeat(64),
        "b".repeat(64),
        7_i64,
        900_i64,
        Some(321_i64),
    );
    sqlx::query(
        "INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at) VALUES(?,?, 'owner',?,?,?)",
    )
    .bind(&preserved.0)
    .bind(&preserved.1)
    .bind(preserved.2)
    .bind(preserved.3)
    .bind(preserved.4)
    .execute(&pool)
    .await
    .expect("insert pre-migration account challenge");
    sqlx::query(
        "INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES(?,?, 'deleted-owner',2,800)",
    )
    .bind("c".repeat(64))
    .bind("d".repeat(64))
    .execute(&pool)
    .await
    .expect("insert challenge for cascade owner");

    apply(
        &pool,
        include_str!("../migrations/0023_recovery_challenge_nullable_user.sql"),
    )
    .await;

    let retained: (String, String, Option<String>, i64, i64, Option<i64>) = sqlx::query_as(
        "SELECT challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=?",
    )
    .bind(&preserved.0)
    .fetch_one(&pool)
    .await
    .expect("read challenge after nullable-owner migration");
    assert_eq!(
        retained,
        (
            preserved.0.clone(),
            preserved.1.clone(),
            Some("owner".to_owned()),
            preserved.2,
            preserved.3,
            preserved.4,
        ),
        "migration preserves existing challenge hashes, owner, generation, expiry, and state"
    );

    let decoy_id_hash = "e".repeat(64);
    let decoy_value_hash = "f".repeat(64);
    sqlx::query(
        "INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES(?,?,NULL,3,1000)",
    )
    .bind(&decoy_id_hash)
    .bind(&decoy_value_hash)
    .execute(&pool)
    .await
    .expect("allow an unbound decoy challenge");
    let decoy: (String, String, Option<String>, i64, i64, Option<i64>) = sqlx::query_as(
        "SELECT challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at,consumed_at FROM account_recovery_challenges WHERE challenge_id_hash=?",
    )
    .bind(&decoy_id_hash)
    .fetch_one(&pool)
    .await
    .expect("read decoy challenge");
    assert_eq!(
        decoy,
        (decoy_id_hash.clone(), decoy_value_hash, None, 3, 1000, None,),
        "decoy challenge remains hash-only and has no account owner"
    );

    let missing_owner = sqlx::query(
        "INSERT INTO account_recovery_challenges(challenge_id_hash,challenge_hash,user_id,recovery_generation,expires_at) VALUES(?,?, 'missing-user',1,1000)",
    )
    .bind("1".repeat(64))
    .bind("2".repeat(64))
    .execute(&pool)
    .await;
    assert!(
        missing_owner.is_err(),
        "nullable owner must retain the users foreign key for non-null account challenges"
    );

    sqlx::query("DELETE FROM users WHERE user_id='deleted-owner'")
        .execute(&pool)
        .await
        .expect("delete challenge owner");
    let cascaded: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM account_recovery_challenges WHERE challenge_id_hash=?",
    )
    .bind("c".repeat(64))
    .fetch_one(&pool)
    .await
    .expect("inspect deleted account challenge");
    assert_eq!(cascaded, 0, "account-owned challenges still cascade");

    sqlx::query("DELETE FROM users WHERE user_id='owner'")
        .execute(&pool)
        .await
        .expect("delete second challenge owner");
    let remaining: Vec<(String, Option<String>)> = sqlx::query_as(
        "SELECT challenge_id_hash,user_id FROM account_recovery_challenges ORDER BY challenge_id_hash",
    )
    .fetch_all(&pool)
    .await
    .expect("inspect challenges after owner deletions");
    assert_eq!(
        remaining,
        vec![(decoy_id_hash, None)],
        "only the ownerless decoy challenge survives user deletion"
    );
}

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0022_backfills_and_preserves_generation_after_disable() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
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
        include_str!("../migrations/0021_account_recovery.sql"),
    ] {
        apply(&pool, migration).await;
    }

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('user','user@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert account");
    sqlx::query("INSERT INTO account_recovery(user_id,recovery_generation,recovery_public_signing_key,recovery_public_encryption_key,recovery_envelope,recovery_identity_envelope,created_at,updated_at) VALUES('user',4,'sign','box','{}','{}',100,100)")
        .execute(&pool)
        .await
        .expect("insert enabled descriptor before upgrade");

    apply(
        &pool,
        include_str!("../migrations/0022_recovery_generation_counter.sql"),
    )
    .await;

    let backfilled: i64 = sqlx::query_scalar(
        "SELECT last_generation FROM account_recovery_generation WHERE user_id='user'",
    )
    .fetch_one(&pool)
    .await
    .expect("backfill current generation");
    assert_eq!(backfilled, 4);

    sqlx::query("DELETE FROM account_recovery WHERE user_id='user'")
        .execute(&pool)
        .await
        .expect("disable Recovery descriptor");
    let after_disable: i64 = sqlx::query_scalar(
        "SELECT last_generation FROM account_recovery_generation WHERE user_id='user'",
    )
    .fetch_one(&pool)
    .await
    .expect("keep counter after disabling recovery");
    assert_eq!(after_disable, 4);

    let invalid = sqlx::query(
        "UPDATE account_recovery_generation SET last_generation=-1 WHERE user_id='user'",
    )
    .execute(&pool)
    .await;
    assert!(
        invalid.is_err(),
        "generation counter cannot move below zero"
    );

    sqlx::query("DELETE FROM users WHERE user_id='user'")
        .execute(&pool)
        .await
        .expect("delete account");
    let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_recovery_generation")
        .fetch_one(&pool)
        .await
        .expect("count account generation rows");
    assert_eq!(remaining, 0, "counter follows account lifetime");
}

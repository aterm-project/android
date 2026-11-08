use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0012_binds_new_relay_tickets_to_sessions_and_keeps_legacy_rows_fail_closed() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
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
    ] {
        apply(&pool, migration).await;
    }

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('user','user@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert ticket user");
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES('device','user','device','sign','enc','now')")
        .execute(&pool)
        .await
        .expect("insert ticket device");
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at) VALUES('legacy','user','device','10.0.0.1',22,'2099-01-01T00:00:00Z')")
        .execute(&pool)
        .await
        .expect("insert legacy ticket");

    apply(
        &pool,
        include_str!("../migrations/0012_relay_ticket_hardening.sql"),
    )
    .await;

    let legacy = sqlx::query("SELECT session_id,session_access_expires_at,created_at FROM relay_tickets WHERE ticket_hash='legacy'")
        .fetch_one(&pool)
        .await
        .expect("read legacy ticket after migration");
    assert_eq!(legacy.get::<Option<String>, _>("session_id"), None);
    assert_eq!(
        legacy.get::<Option<String>, _>("session_access_expires_at"),
        None
    );
    assert_eq!(legacy.get::<i64, _>("created_at"), 0);

    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,target_ip,target_port,expires_at,session_id,session_access_expires_at,created_at) VALUES('current','user','device','10.0.0.2',22,'2099-01-01T00:00:00Z','session','2099-01-01T00:00:00Z',1234)")
        .execute(&pool)
        .await
        .expect("insert session-bound ticket");
    let indexes: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_relay_tickets_expires','idx_relay_tickets_user_created')")
        .fetch_one(&pool)
        .await
        .expect("query relay indexes");
    assert_eq!(indexes, 2);
}

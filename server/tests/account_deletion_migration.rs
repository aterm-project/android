use sqlx::sqlite::SqlitePoolOptions;

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0009_adds_account_lifecycle_and_vault_scoped_key_archive() {
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
    ] {
        apply(&pool, migration).await;
    }

    apply(
        &pool,
        include_str!("../migrations/0009_account_deletion.sql"),
    )
    .await;

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('account-a','a@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("legacy user remains compatible");
    sqlx::query(
        "INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('vault-a','account-a','now')",
    )
    .execute(&pool)
    .await
    .expect("legacy vault remains compatible");
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES('device-a','account-a','device','sign-pub','enc-pub','now')")
        .execute(&pool)
        .await
        .expect("new nullable device marker is backward compatible");

    sqlx::query("INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) VALUES('request-a','account-a',10,20,'domain-separated-hmac')")
        .execute(&pool)
        .await
        .expect("pending deletion ledger has no user FK");
    sqlx::query("INSERT INTO vault_device_archives(vault_id,user_id,device_id,signing_public_key,encryption_public_key,archived_at) VALUES('vault-a','opaque-user-id','archived-device','sign-pub','enc-pub','now')")
        .execute(&pool)
        .await
        .expect("archive is scoped to a surviving vault, not account/device FKs");

    let foreign_keys = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&pool)
        .await
        .expect("foreign key check succeeds");
    assert!(foreign_keys.is_empty());

    let marker: Option<String> = sqlx::query_scalar(
        "SELECT account_deletion_request_id FROM devices WHERE device_id='device-a'",
    )
    .fetch_one(&pool)
    .await
    .expect("read new device marker");
    assert_eq!(marker, None);

    let archive_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM vault_device_archives WHERE vault_id='vault-a'")
            .fetch_one(&pool)
            .await
            .expect("archive row is retained");
    assert_eq!(archive_count, 1);
}

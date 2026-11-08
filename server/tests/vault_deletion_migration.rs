use sqlx::{Row, sqlite::SqlitePoolOptions};

#[tokio::test]
async fn migration_0005_backfills_legacy_deleting_vaults() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");

    sqlx::raw_sql(include_str!("../migrations/0001_initial.sql"))
        .execute(&pool)
        .await
        .expect("apply migration 0001");
    sqlx::raw_sql(include_str!("../migrations/0002_account_invitations.sql"))
        .execute(&pool)
        .await
        .expect("apply migration 0002");
    sqlx::raw_sql(include_str!(
        "../migrations/0003_sync_history_retention.sql"
    ))
    .execute(&pool)
    .await
    .expect("apply migration 0003");
    sqlx::raw_sql(include_str!("../migrations/0004_auth_rate_limits.sql"))
        .execute(&pool)
        .await
        .expect("apply migration 0004");

    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('owner','owner','now')")
        .execute(&pool)
        .await
        .expect("insert legacy vault owner");
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,created_at) VALUES('legacy-deleting','owner','deleting','now'),('legacy-active','owner','active','now')")
        .execute(&pool)
        .await
        .expect("insert legacy deleting and active vaults");

    let migration_started = chrono::Utc::now().timestamp();
    sqlx::raw_sql(include_str!("../migrations/0005_vault_deletion.sql"))
        .execute(&pool)
        .await
        .expect("apply migration 0005");
    let migration_finished = chrono::Utc::now().timestamp();

    let requests = sqlx::query(
        "SELECT vault_id,requested_at,purge_after,actor_hash FROM vault_deletion_requests ORDER BY vault_id",
    )
    .fetch_all(&pool)
    .await
    .expect("load backfilled deletion requests");
    assert_eq!(
        requests.len(),
        1,
        "only deleting legacy vaults are backfilled"
    );

    let request = &requests[0];
    assert_eq!(request.get::<String, _>("vault_id"), "legacy-deleting");
    let requested_at: i64 = request.get("requested_at");
    let purge_after: i64 = request.get("purge_after");
    let actor_hash: Option<String> = request.get("actor_hash");
    assert!(
        (migration_started - 1..=migration_finished + 1).contains(&requested_at),
        "requested_at {requested_at} should be close to migration epoch {migration_started}..={migration_finished}"
    );
    assert_eq!(purge_after - requested_at, 604_800);
    assert_eq!(actor_hash, None);

    let active_requests: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM vault_deletion_requests WHERE vault_id='legacy-active'",
    )
    .fetch_one(&pool)
    .await
    .expect("count requests for active vault");
    assert_eq!(active_requests, 0, "active vaults are not backfilled");
}

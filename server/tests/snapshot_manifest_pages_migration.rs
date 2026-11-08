use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply SQLite migration");
}

#[tokio::test]
async fn migration_0044_backfills_immutable_page_items_and_parent_delete_cascades() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    apply(&pool, include_str!("../migrations/0001_initial.sql")).await;
    apply(
        &pool,
        include_str!("../migrations/0003_sync_history_retention.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0007_history_pagination.sql"),
    )
    .await;

    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('owner','owner','now')")
        .execute(&pool)
        .await
        .expect("insert owner");
    sqlx::query(
        "INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('vault','owner','now')",
    )
    .execute(&pool)
    .await
    .expect("insert Vault");
    sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES('vault',2)")
        .execute(&pool)
        .await
        .expect("insert counters");
    sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation,conflict_high_watermark) VALUES('snapshot','vault','owner',2,?,'2099-01-01T00:00:00Z','now','generation',0)")
        .bind(r#"[{"record_id":"record-b","revision_id":"rev-b","deleted":false,"envelope":{"ciphertext":"b"}},{"record_id":"record-a","revision_id":"rev-a","deleted":true,"envelope":{"ciphertext":"a"}}]"#)
        .execute(&pool)
        .await
        .expect("insert legacy snapshot");

    apply(
        &pool,
        include_str!("../migrations/0044_snapshot_manifest_pages.sql"),
    )
    .await;

    let rows = sqlx::query(
        "SELECT record_id,item_json FROM snapshot_items WHERE snapshot_id='snapshot' ORDER BY record_id COLLATE BINARY",
    )
    .fetch_all(&pool)
    .await
    .expect("read migrated immutable items");
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].get::<String, _>("record_id"), "record-a");
    assert_eq!(rows[1].get::<String, _>("record_id"), "record-b");
    assert_eq!(
        rows[0]
            .get::<String, _>("item_json")
            .parse::<serde_json::Value>()
            .unwrap()["deleted"],
        true
    );
    let snapshot: (i64, String) = sqlx::query_as(
        "SELECT snapshot_item_count,snapshot_manifest_format FROM snapshots WHERE snapshot_id='snapshot'",
    )
    .fetch_one(&pool)
    .await
    .expect("read migrated snapshot metadata");
    assert_eq!(snapshot, (2, "legacy".to_owned()));

    sqlx::query("DELETE FROM snapshots WHERE snapshot_id='snapshot'")
        .execute(&pool)
        .await
        .expect("delete snapshot parent");
    let remaining: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id='snapshot'")
            .fetch_one(&pool)
            .await
            .expect("count cascaded items");
    assert_eq!(remaining, 0);
}

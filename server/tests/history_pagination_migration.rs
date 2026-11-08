use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0007_backfills_conflict_sequences_and_leaves_legacy_snapshot_unpaired() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    apply(&pool, include_str!("../migrations/0001_initial.sql")).await;
    apply(
        &pool,
        include_str!("../migrations/0002_account_invitations.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0003_sync_history_retention.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0004_auth_rate_limits.sql"),
    )
    .await;
    apply(&pool, include_str!("../migrations/0005_vault_deletion.sql")).await;
    apply(&pool, include_str!("../migrations/0006_object_gc.sql")).await;

    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES('owner','owner','now')")
        .execute(&pool)
        .await
        .expect("insert owner");
    sqlx::query(
        "INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES('vault','owner','now')",
    )
    .execute(&pool)
    .await
    .expect("insert vault");
    sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES('vault',0)")
        .execute(&pool)
        .await
        .expect("insert vault counters");

    sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,resolved_revision_id) VALUES('branch-c','vault','record-c','{}','digest','device','2025-02-01T00:00:00Z','rev-c'),('branch-b','vault','record-b','{}','digest','device','2025-02-01T00:00:00Z',NULL),('branch-a','vault','record-a','{}','digest','device','2025-01-01T00:00:00Z','rev-a')")
        .execute(&pool)
        .await
        .expect("insert old branch rows");
    sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at,server_generation) VALUES('old-snapshot','vault','owner',0,'[]','2099-01-01T00:00:00Z','now','generation')")
        .execute(&pool)
        .await
        .expect("insert pre-migration snapshot");

    apply(
        &pool,
        include_str!("../migrations/0007_history_pagination.sql"),
    )
    .await;

    let rows = sqlx::query(
        "SELECT conflict_id,conflict_seq,resolved_revision_id,resolution_seq FROM conflicts WHERE vault_id='vault' ORDER BY conflict_seq",
    )
    .fetch_all(&pool)
    .await
    .expect("read backfilled conflict rows");
    let mapped = rows
        .iter()
        .map(|row| {
            (
                row.get::<String, _>("conflict_id"),
                row.get::<i64, _>("conflict_seq"),
                row.get::<Option<String>, _>("resolved_revision_id"),
                row.get::<Option<i64>, _>("resolution_seq"),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        mapped[0],
        ("branch-a".to_owned(), 1, Some("rev-a".to_owned()), Some(4))
    );
    assert_eq!(mapped[1], ("branch-b".to_owned(), 2, None, None));
    assert_eq!(
        mapped[2],
        ("branch-c".to_owned(), 3, Some("rev-c".to_owned()), Some(5))
    );
    assert!(mapped.iter().all(|(_, branch_seq, _, resolution_seq)| {
        resolution_seq.is_none_or(|resolution| resolution > *branch_seq)
    }));

    let counter: i64 =
        sqlx::query_scalar("SELECT last_conflict_seq FROM vault_counters WHERE vault_id='vault'")
            .fetch_one(&pool)
            .await
            .expect("read sequence counter");
    assert_eq!(
        counter, 5,
        "counter includes all old branch and resolve events"
    );

    let legacy_watermark: Option<i64> = sqlx::query_scalar(
        "SELECT conflict_high_watermark FROM snapshots WHERE snapshot_id='old-snapshot'",
    )
    .fetch_one(&pool)
    .await
    .expect("read legacy snapshot conflict watermark");
    assert_eq!(
        legacy_watermark, None,
        "legacy snapshot cannot claim a paired boundary"
    );

    let next: i64 = sqlx::query_scalar(
        "UPDATE vault_counters SET last_conflict_seq=last_conflict_seq+1 WHERE vault_id='vault' RETURNING last_conflict_seq",
    )
    .fetch_one(&pool)
    .await
    .expect("allocate next conflict event");
    assert_eq!(next, 6, "new events follow all migrated history");
}

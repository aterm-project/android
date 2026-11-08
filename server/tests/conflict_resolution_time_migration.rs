use sqlx::{Row, sqlite::SqlitePoolOptions};

#[tokio::test]
async fn migration_0015_backfills_resolution_time_from_revision_then_branch() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    sqlx::raw_sql(include_str!("../migrations/0001_initial.sql"))
        .execute(&pool)
        .await
        .expect("apply initial schema");

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
    sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,resolved_revision_id) VALUES('from-revision','vault','record-a','{}','digest','device','2025-01-01T00:00:00Z','revision-a'),('fallback','vault','record-b','{}','digest','device','2025-02-01T00:00:00Z','missing-revision'),('unresolved','vault','record-c','{}','digest','device','2025-03-01T00:00:00Z',NULL)")
        .execute(&pool)
        .await
        .expect("insert legacy conflict rows");
    sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES('vault','record-a','revision-a','{}','digest',1,'device','update','2025-01-02T00:00:00Z')")
        .execute(&pool)
        .await
        .expect("insert resolved revision timestamp");

    sqlx::raw_sql(include_str!(
        "../migrations/0015_conflict_resolution_time.sql"
    ))
    .execute(&pool)
    .await
    .expect("apply conflict resolution time migration");

    let rows = sqlx::query("SELECT conflict_id,resolution_at FROM conflicts ORDER BY conflict_id")
        .fetch_all(&pool)
        .await
        .expect("read resolution timestamps");
    let timestamps = rows
        .iter()
        .map(|row| {
            (
                row.get::<String, _>("conflict_id"),
                row.get::<Option<String>, _>("resolution_at"),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        timestamps,
        vec![
            (
                "fallback".to_owned(),
                Some("2025-02-01T00:00:00Z".to_owned())
            ),
            (
                "from-revision".to_owned(),
                Some("2025-01-02T00:00:00Z".to_owned())
            ),
            ("unresolved".to_owned(), None),
        ]
    );
}

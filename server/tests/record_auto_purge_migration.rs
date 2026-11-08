use sqlx::{Row, sqlite::SqlitePoolOptions};

#[tokio::test]
async fn migration_0050_defaults_existing_and_new_tombstones_to_opted_out() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create in-memory SQLite database");
    sqlx::raw_sql(
        "CREATE TABLE record_graveyard(\
             vault_id TEXT NOT NULL,\
             record_id TEXT NOT NULL,\
             deleted_revision TEXT NOT NULL,\
             deleted_seq INTEGER NOT NULL CHECK(deleted_seq>0),\
             PRIMARY KEY(vault_id,record_id)\
         );\
         INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq)\
         VALUES('vault','legacy-record','legacy-revision',1);",
    )
    .execute(&pool)
    .await
    .expect("create pre-0050 graveyard schema and row");

    sqlx::raw_sql(include_str!(
        "../migrations/0050_record_auto_purge_opt_in.sql"
    ))
    .execute(&pool)
    .await
    .expect("apply automatic purge opt-in migration");

    let legacy: (i64, i64) = sqlx::query_as(
        "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
         WHERE vault_id='vault' AND record_id='legacy-record'",
    )
    .fetch_one(&pool)
    .await
    .expect("read migrated legacy policy");
    assert_eq!(legacy, (0, 0));

    sqlx::query(
        "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
         VALUES('vault','new-record','new-revision',2)",
    )
    .execute(&pool)
    .await
    .expect("new tombstone may omit optional policy columns");
    let new_row: (i64, i64) = sqlx::query_as(
        "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
         WHERE vault_id='vault' AND record_id='new-record'",
    )
    .fetch_one(&pool)
    .await
    .expect("read new policy defaults");
    assert_eq!(new_row, (0, 0));

    assert!(
        sqlx::query(
            "UPDATE record_graveyard SET auto_purge_enabled=2 \
             WHERE vault_id='vault' AND record_id='legacy-record'",
        )
        .execute(&pool)
        .await
        .is_err(),
        "SQLite boolean policy must remain constrained"
    );
    assert!(
        sqlx::query(
            "UPDATE record_graveyard SET auto_purge_revision=-1 \
             WHERE vault_id='vault' AND record_id='legacy-record'",
        )
        .execute(&pool)
        .await
        .is_err(),
        "policy revision must remain non-negative"
    );

    let index: String = sqlx::query(
        "SELECT sql FROM sqlite_master WHERE type='index' \
         AND name='idx_record_graveyard_auto_purge_candidates'",
    )
    .fetch_one(&pool)
    .await
    .expect("candidate index is present")
    .get("sql");
    assert!(index.contains("WHERE auto_purge_enabled = 1"));
}

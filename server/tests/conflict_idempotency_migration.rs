use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0008_preserves_legacy_duplicates_and_claims_one_canonical_op_id() {
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
        .expect("insert counters");

    let op_id = "00000000-0000-4000-8000-000000000001";
    let other_op_id = "00000000-0000-4000-8000-000000000002";
    let make_envelope = |operation: Option<&str>| match operation {
        Some(operation) => format!(r#"{{"header":{{"op_id":"{operation}"}}}}"#),
        None => r#"{"header":{}}"#.to_owned(),
    };
    let rows = [
        (
            "legacy-first",
            "device-a",
            Some(op_id),
            "2025-01-01T00:00:00Z",
            "same-jcs-digest",
        ),
        (
            "legacy-duplicate-same",
            "device-a",
            Some(op_id),
            "2025-01-02T00:00:00Z",
            "same-jcs-digest",
        ),
        (
            "legacy-duplicate-different",
            "device-a",
            Some(op_id),
            "2025-01-03T00:00:00Z",
            "different-digest",
        ),
        (
            "legacy-other-device",
            "device-b",
            Some(op_id),
            "2025-01-04T00:00:00Z",
            "other-device-digest",
        ),
        (
            "legacy-other-operation",
            "device-a",
            Some(other_op_id),
            "2025-01-05T00:00:00Z",
            "other-op-digest",
        ),
        (
            "legacy-no-op-id",
            "device-a",
            None,
            "2025-01-06T00:00:00Z",
            "no-op-digest",
        ),
    ];
    for (conflict_id, device, operation, created_at, digest) in rows {
        let envelope = make_envelope(operation);
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at) VALUES(?,'vault',? ,?,?,?,?)")
            .bind(conflict_id)
            .bind(format!("record-{conflict_id}"))
            .bind(envelope)
            .bind(digest)
            .bind(device)
            .bind(created_at)
            .execute(&pool)
            .await
            .expect("insert legacy conflict");
    }

    apply(
        &pool,
        include_str!("../migrations/0007_history_pagination.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0008_conflict_idempotency.sql"),
    )
    .await;

    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM conflicts WHERE vault_id='vault'")
        .fetch_one(&pool)
        .await
        .expect("count preserved branches");
    assert_eq!(
        count,
        rows.len() as i64,
        "migration retains duplicate history"
    );

    let migrated = sqlx::query("SELECT conflict_id,op_id FROM conflicts WHERE vault_id='vault'")
        .fetch_all(&pool)
        .await
        .expect("read migrated operation keys");
    let values = migrated
        .iter()
        .map(|row| {
            (
                row.get::<String, _>("conflict_id"),
                row.get::<Option<String>, _>("op_id"),
            )
        })
        .collect::<std::collections::HashMap<_, _>>();
    assert_eq!(values["legacy-first"].as_deref(), Some(op_id));
    assert_eq!(values["legacy-duplicate-same"], None);
    assert_eq!(values["legacy-duplicate-different"], None);
    assert_eq!(values["legacy-other-device"].as_deref(), Some(op_id));
    assert_eq!(
        values["legacy-other-operation"].as_deref(),
        Some(other_op_id)
    );
    assert_eq!(values["legacy-no-op-id"], None);

    let duplicate_insert = sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES('new-conflict','vault','record-new','{}','digest','device-a','now',99,?)")
        .bind(op_id)
        .execute(&pool)
        .await;
    assert!(
        duplicate_insert.is_err(),
        "the unique key prevents a second canonical receipt for the same vault/device/op_id"
    );
}

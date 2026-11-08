use sqlx::sqlite::SqlitePoolOptions;

#[tokio::test]
async fn migration_0030_creates_a_checked_singleton_policy_table_without_freezing_env_defaults() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply all schema migrations");

    let rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_relay_policy")
        .fetch_one(&pool)
        .await
        .expect("count policy rows");
    assert_eq!(
        rows, 0,
        "revision zero is derived from the current environment"
    );

    sqlx::query("INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES(1,1,'[\"10.0.0.0/8\"]','[22]',1,'2026-01-01T00:00:00Z')")
        .execute(&pool)
        .await
        .expect("insert durable policy");
    for invalid in [
        "INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES(2,1,'[]','[]',1,'now')",
        "INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES(1,2,'[]','[]',2,'now')",
        "UPDATE instance_relay_policy SET revision=0 WHERE policy_id=1",
    ] {
        assert!(sqlx::query(invalid).execute(&pool).await.is_err());
    }
}

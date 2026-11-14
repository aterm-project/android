use sqlx::sqlite::SqlitePoolOptions;

#[tokio::test]
async fn migration_0043_creates_separate_server_managed_group_acl_tables() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("create temporary SQLite database");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply all schema migrations");

    let migration: i64 =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE version=43")
            .fetch_one(&pool)
            .await
            .expect("find Relay access group migration");
    assert_eq!(migration, 43);

    sqlx::query(
        "INSERT INTO users(user_id,username,status,created_at) VALUES('user-1','member@example.test','active','2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert member account");
    sqlx::query(
        "INSERT INTO relay_access_groups(group_id,name,name_key,revision,created_at,updated_at) VALUES('group-1','Ops','ops',1,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert server-managed group");
    assert!(sqlx::query(
        "INSERT INTO relay_access_groups(group_id,name,name_key,revision,created_at,updated_at) VALUES('group-2','OPS','ops',1,'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .is_err());

    sqlx::query(
        "INSERT INTO relay_access_group_membership_revisions(group_id,revision) VALUES('group-1',0)",
    )
    .execute(&pool)
    .await
    .expect("insert independent membership CAS row");
    sqlx::query(
        "INSERT INTO relay_access_group_members(group_id,user_id,created_at) VALUES('group-1','user-1','2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert group member");
    sqlx::query(
        "INSERT INTO relay_access_group_relay_policies(group_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES('group-1',1,'[\"10.0.0.0/8\"]','[22]',1,'2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert explicit group policy");
    sqlx::query(
        "INSERT INTO relay_access_group_relay_policy_revisions(group_id,revision,updated_at) VALUES('group-1',1,'2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert policy CAS watermark");
    sqlx::query(
        "INSERT INTO relay_user_authorization_versions(user_id,revision) VALUES('user-1',1)",
    )
    .execute(&pool)
    .await
    .expect("insert private user authorization revision");

    let ticket_revision: i64 =
        sqlx::query_scalar("SELECT authorization_revision FROM relay_tickets LIMIT 1")
            .fetch_optional(&pool)
            .await
            .expect("read Relay ticket schema")
            .unwrap_or(0);
    assert_eq!(
        ticket_revision, 0,
        "legacy tickets default to revision zero"
    );

    sqlx::query("DELETE FROM users WHERE user_id='user-1'")
        .execute(&pool)
        .await
        .expect("delete member account");
    let remaining_members: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM relay_access_group_members WHERE user_id='user-1'",
    )
    .fetch_one(&pool)
    .await
    .expect("count members after account cascade");
    assert_eq!(remaining_members, 0);
    let remaining_authz_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM relay_user_authorization_versions WHERE user_id='user-1'",
    )
    .fetch_one(&pool)
    .await
    .expect("count auth revision rows after account cascade");
    assert_eq!(remaining_authz_rows, 0);

    sqlx::query("DELETE FROM relay_access_groups WHERE group_id='group-1'")
        .execute(&pool)
        .await
        .expect("delete server-managed group");
    for table in [
        "relay_access_group_members",
        "relay_access_group_membership_revisions",
        "relay_access_group_relay_policies",
        "relay_access_group_relay_policy_revisions",
    ] {
        let query = format!("SELECT COUNT(*) FROM {table} WHERE group_id='group-1'");
        let count: i64 = sqlx::query_scalar(&query)
            .fetch_one(&pool)
            .await
            .expect("count cascaded group rows");
        assert_eq!(count, 0, "foreign-key cascade for {table}");
    }
}

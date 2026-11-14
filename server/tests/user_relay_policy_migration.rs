use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

#[tokio::test]
async fn migration_0042_checks_policy_values_and_cascades_user_rows() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create temporary SQLite database");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply all schema migrations");

    let foreign_keys: i64 = sqlx::query_scalar("PRAGMA foreign_keys")
        .fetch_one(&pool)
        .await
        .expect("read foreign-key enforcement setting");
    assert_eq!(foreign_keys, 1);

    for (user_id, username) in [
        ("policy-user", "policy@example.test"),
        ("invalid-enabled-user", "invalid-enabled@example.test"),
    ] {
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(user_id)
            .bind(username)
            .bind("2026-01-01T00:00:00Z")
            .execute(&pool)
            .await
            .expect("insert policy test account");
    }

    let invalid_enabled = sqlx::query(
        "INSERT INTO user_relay_policies(user_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
         VALUES('invalid-enabled-user',2,'[]','[]',1,'2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await;
    assert!(
        invalid_enabled.is_err(),
        "enabled must be constrained to 0 or 1"
    );

    sqlx::query(
        "INSERT INTO user_relay_policies(user_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
         VALUES('policy-user',1,'[\"10.0.0.0/8\"]','[22]',1,'2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert valid user Relay policy");

    let invalid_policy_revision =
        sqlx::query("UPDATE user_relay_policies SET revision=0 WHERE user_id='policy-user'")
            .execute(&pool)
            .await;
    assert!(
        invalid_policy_revision.is_err(),
        "override revision must be positive"
    );
    let persisted_revision: i64 =
        sqlx::query_scalar("SELECT revision FROM user_relay_policies WHERE user_id='policy-user'")
            .fetch_one(&pool)
            .await
            .expect("read valid override revision");
    assert_eq!(persisted_revision, 1);

    sqlx::query(
        "INSERT INTO user_relay_policy_revisions(user_id,revision,updated_at) VALUES('policy-user',1,'2026-01-01T00:00:00Z')",
    )
    .execute(&pool)
    .await
    .expect("insert valid revision watermark");
    let invalid_watermark_revision = sqlx::query(
        "UPDATE user_relay_policy_revisions SET revision=0 WHERE user_id='policy-user'",
    )
    .execute(&pool)
    .await;
    assert!(
        invalid_watermark_revision.is_err(),
        "CAS watermark revision must be positive"
    );

    sqlx::query("DELETE FROM users WHERE user_id='policy-user'")
        .execute(&pool)
        .await
        .expect("delete policy owner");
    let override_rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM user_relay_policies WHERE user_id='policy-user'")
            .fetch_one(&pool)
            .await
            .expect("count cascaded override rows");
    let watermark_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM user_relay_policy_revisions WHERE user_id='policy-user'",
    )
    .fetch_one(&pool)
    .await
    .expect("count cascaded revision rows");
    assert_eq!(
        override_rows, 0,
        "account deletion must cascade its override"
    );
    assert_eq!(
        watermark_rows, 0,
        "account deletion must cascade its CAS watermark"
    );

    let violations = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&pool)
        .await
        .expect("foreign-key check succeeds");
    assert!(violations.is_empty());
}

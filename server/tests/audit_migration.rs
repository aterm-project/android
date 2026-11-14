use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0018_and_0019_preserve_audit_history_and_add_admin_indexes() {
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
        include_str!("../migrations/0009_account_deletion.sql"),
        include_str!("../migrations/0010_notifications.sql"),
        include_str!("../migrations/0011_audit_events.sql"),
    ] {
        apply(&pool, migration).await;
    }

    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','account-hmac','account.created','account','success',100,'api'),('vault','vault-id','vault.membership_changed','membership','success',101,'maintenance')")
        .execute(&pool)
        .await
        .expect("store only the declared audit metadata");

    let failure_before_upgrade = sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','account-hmac','auth.login_failed','account','failure',102,'api')")
        .execute(&pool)
        .await;
    assert!(
        failure_before_upgrade.is_err(),
        "0011 keeps its original constraint"
    );

    apply(
        &pool,
        include_str!("../migrations/0012_relay_ticket_hardening.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0013_audit_login_results.sql"),
    )
    .await;

    apply(
        &pool,
        include_str!("../migrations/0016_instance_audit_scope.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0018_instance_audit_event_order.sql"),
    )
    .await;
    apply(
        &pool,
        include_str!("../migrations/0019_instance_admin_account_listing.sql"),
    )
    .await;

    let historical: Vec<(i64, String, String)> =
        sqlx::query_as("SELECT event_id,action,result FROM audit_events ORDER BY event_id")
            .fetch_all(&pool)
            .await
            .expect("preserve existing successful events");
    assert_eq!(
        historical,
        vec![
            (1, "account.created".into(), "success".into()),
            (2, "vault.membership_changed".into(), "success".into()),
        ]
    );

    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','account-hmac','auth.login_failed','account','failure',102,'api')")
        .execute(&pool)
        .await
        .expect("store the fixed failed-login result");

    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('instance','instance-hmac','instance.account_invitation_issued','account_invitation','success',103,'maintenance')")
        .execute(&pool)
        .await
        .expect("store an operator event in its own scope");

    let event_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events")
        .fetch_one(&pool)
        .await
        .expect("count inserted events");
    assert_eq!(event_count, 4);

    let invalid_result = sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','scope','bad.result','account','unknown',103,'api')")
        .execute(&pool)
        .await;
    assert!(
        invalid_result.is_err(),
        "result must be one of the fixed values"
    );

    let invalid_scope = sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('global','scope','account.created','account','success',103,'maintenance')")
        .execute(&pool)
        .await;
    assert!(
        invalid_scope.is_err(),
        "only declared audit scopes are allowed"
    );

    let invalid_source = sqlx::query("INSERT INTO audit_events(scope_type,scope_id,action,resource_type,result,occurred_at,source) VALUES('account','scope','account.created','account','success',103,'external')")
        .execute(&pool)
        .await;
    assert!(invalid_source.is_err(), "source must be a fixed enum");

    let indexes: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_audit_events_scope_event','idx_audit_events_retention','idx_audit_events_actor','idx_audit_events_instance_event_id')",
    )
    .fetch_one(&pool)
    .await
    .expect("check audit indexes");
    assert_eq!(indexes, 4);

    let query_plan_rows = sqlx::query(
        "EXPLAIN QUERY PLAN SELECT event_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source FROM audit_events INDEXED BY idx_audit_events_instance_event_id WHERE scope_type='instance' AND event_id>? AND event_id<=? ORDER BY event_id LIMIT ?",
    )
    .bind(0_i64)
    .bind(10_i64)
    .bind(100_i64)
    .fetch_all(&pool)
    .await
    .expect("explain instance audit page query");
    let query_plan = query_plan_rows
        .iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("; ");
    assert!(
        query_plan.contains("idx_audit_events_instance_event_id"),
        "instance feed should seek and stream in event order using its partial index: {query_plan}"
    );

    let account_page_rows = sqlx::query(
        "EXPLAIN QUERY PLAN SELECT user_id FROM users ORDER BY created_at DESC,user_id ASC LIMIT 50",
    )
    .fetch_all(&pool)
    .await
    .expect("explain the ordered admin account page");
    let account_page_plan = account_page_rows
        .iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("; ");
    assert!(
        account_page_plan.contains("idx_users_admin_listing"),
        "admin account page should use its ordered index: {account_page_plan}"
    );

    let session_count_rows = sqlx::query(
        "EXPLAIN QUERY PLAN SELECT COUNT(*) FROM sessions WHERE user_id='user' AND revoked_at IS NULL AND refresh_expires_at>'2026-01-01T00:00:00+00:00'",
    )
    .fetch_all(&pool)
    .await
    .expect("explain the live admin session count");
    let session_count_plan = session_count_rows
        .iter()
        .map(|row| row.get::<String, _>("detail"))
        .collect::<Vec<_>>()
        .join("; ");
    assert!(
        session_count_plan.contains("idx_sessions_user_refresh_expiry"),
        "admin live-session count should use its partial index: {session_count_plan}"
    );
}

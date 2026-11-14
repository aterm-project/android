use sqlx::{Row, sqlite::SqlitePoolOptions};

async fn apply(pool: &sqlx::SqlitePool, migration: &str) {
    sqlx::raw_sql(migration)
        .execute(pool)
        .await
        .expect("apply schema migration");
}

#[tokio::test]
async fn migration_0014_adds_session_bound_non_secret_password_change_receipt() {
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
        include_str!("../migrations/0012_relay_ticket_hardening.sql"),
        include_str!("../migrations/0013_audit_login_results.sql"),
        include_str!("../migrations/0014_password_change_receipts.sql"),
    ] {
        apply(&pool, migration).await;
    }

    sqlx::query(
        "INSERT INTO users(user_id,username,created_at) VALUES('user','user@example.test','now')",
    )
    .execute(&pool)
    .await
    .expect("insert receipt owner");
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES('device','user','device','sign','enc','now')")
        .execute(&pool)
        .await
        .expect("insert receipt device");
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES('session','user','device','family','access','refresh','2099-01-01T00:00:00Z','2099-01-01T00:00:00Z','now')")
        .execute(&pool)
        .await
        .expect("insert receipt session");

    sqlx::query("INSERT INTO password_change_receipts(session_id,operation_id,request_digest,credential_version,created_at) VALUES('session','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',?,2,123)")
        .bind("a".repeat(64))
        .execute(&pool)
        .await
        .expect("store opaque retry receipt");
    let receipt = sqlx::query("SELECT operation_id,request_digest,credential_version,created_at FROM password_change_receipts WHERE session_id='session'")
        .fetch_one(&pool)
        .await
        .expect("read opaque receipt");
    assert_eq!(
        receipt.get::<String, _>("operation_id"),
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    );
    assert_eq!(receipt.get::<String, _>("request_digest").len(), 64);
    assert_eq!(receipt.get::<i64, _>("credential_version"), 2);
    assert_eq!(receipt.get::<i64, _>("created_at"), 123);

    let invalid_digest = sqlx::query("INSERT INTO password_change_receipts(session_id,operation_id,request_digest,credential_version,created_at) VALUES('session','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','not-a-digest',3,124)")
        .execute(&pool)
        .await;
    assert!(
        invalid_digest.is_err(),
        "receipt digests must be fixed lowercase hex"
    );

    sqlx::query("DELETE FROM sessions WHERE session_id='session'")
        .execute(&pool)
        .await
        .expect("remove session");
    let remaining: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM password_change_receipts")
        .fetch_one(&pool)
        .await
        .expect("count receipts after session purge");
    assert_eq!(
        remaining, 0,
        "receipt must cascade with the preserved session"
    );
}

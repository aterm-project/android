use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};

#[tokio::test]
async fn migration_0038_tracks_retryable_restore_stage_lifecycle() {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(
            SqliteConnectOptions::new()
                .filename(":memory:")
                .foreign_keys(true),
        )
        .await
        .expect("create temporary SQLite database");
    sqlx::raw_sql(
        "CREATE TABLE instance_admin_jobs(job_id TEXT PRIMARY KEY); \
         INSERT INTO instance_admin_jobs(job_id) VALUES \
           ('10000000-0000-4000-8000-000000000001'), \
           ('10000000-0000-4000-8000-000000000002'), \
           ('10000000-0000-4000-8000-000000000003');",
    )
    .execute(&pool)
    .await
    .expect("create the prior admin jobs table");

    sqlx::raw_sql(include_str!(
        "../migrations/0038_instance_admin_restore_stage_lifecycle.sql"
    ))
    .execute(&pool)
    .await
    .expect("apply restore-stage lifecycle migration");

    let generation = "20000000-0000-4000-8000-000000000001";
    sqlx::query(
        "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
         VALUES('10000000-0000-4000-8000-000000000001',?,'ready','now')",
    )
    .bind(generation)
    .execute(&pool)
    .await
    .expect("accept a verified ready stage");

    assert!(
        sqlx::query(
            "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
             VALUES('10000000-0000-4000-8000-000000000002','not-a-uuid','ready','now')",
        )
        .execute(&pool)
        .await
        .is_err(),
        "generation must be a canonical lowercase UUID"
    );
    assert!(
        sqlx::query(
            "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
             VALUES('10000000-0000-4000-8000-000000000002',?,'discarding','now')",
        )
        .bind(generation)
        .execute(&pool)
        .await
        .is_err(),
        "a durable discard marker requires its original actor and device"
    );
    assert!(
        sqlx::query(
            "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at,discard_requested_by_user_id,discard_requested_by_device_id,discarded_at) \
             VALUES('10000000-0000-4000-8000-000000000002',?,'discarded','now','user','device',NULL)",
        )
        .bind(generation)
        .execute(&pool)
        .await
        .is_err(),
        "discarded state requires its committed timestamp"
    );

    sqlx::query(
        "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at,discard_requested_by_user_id,discard_requested_by_device_id) \
         VALUES('10000000-0000-4000-8000-000000000002',?,'discarding','now','user','device')",
    )
    .bind(generation)
    .execute(&pool)
    .await
    .expect("persist a recoverable in-progress marker");
    sqlx::query(
        "UPDATE instance_admin_restore_stages SET status='discarded',discarded_at='later' \
         WHERE restore_job_id='10000000-0000-4000-8000-000000000002'",
    )
    .execute(&pool)
    .await
    .expect("finalize an in-progress discard");

    let orphan_before: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM instance_admin_restore_stages WHERE restore_job_id='10000000-0000-4000-8000-000000000003'",
    )
    .fetch_one(&pool)
    .await
    .expect("check untouched legacy restore jobs");
    assert_eq!(
        orphan_before, 0,
        "migration leaves legacy jobs for verified startup backfill"
    );
    sqlx::query(
        "DELETE FROM instance_admin_jobs WHERE job_id='10000000-0000-4000-8000-000000000001'",
    )
    .execute(&pool)
    .await
    .expect("delete parent restore job");
    let cascaded: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM instance_admin_restore_stages WHERE restore_job_id='10000000-0000-4000-8000-000000000001'",
    )
    .fetch_one(&pool)
    .await
    .expect("check lifecycle cascade");
    assert_eq!(cascaded, 0);
}

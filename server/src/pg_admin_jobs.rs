//! Shared PostgreSQL instance-admin job ledger and leased worker.
//!
//! The database stores only server-generated archive UUIDs and private digest
//! metadata. Filesystem paths, encryption-key paths, and restore target URLs
//! are resolved from operator configuration and never leave this module.

use std::time::Duration;

use axum::{
    Json,
    extract::rejection::JsonRejection,
    http::{HeaderMap, StatusCode},
};
use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use tokio::time::MissedTickBehavior;
use uuid::Uuid;

use crate::{ApiError, AppState, auth::AuthUser, backup_replication::ArchiveSource};

const PAGE_LIMIT_MAX: i64 = 100;
const WORKER_POLL_INTERVAL: Duration = Duration::from_secs(1);
const SCHEDULE_POLL_INTERVAL: Duration = Duration::from_secs(30);
const WORKER_LEASE: Duration = Duration::from_secs(5 * 60);
const WORKER_HEARTBEAT: Duration = Duration::from_secs(30);

struct ClaimedJob {
    job_id: String,
    worker_token: String,
    requested_by_user_id: Option<String>,
    requested_by_device_id: Option<String>,
    request_origin: String,
    action: String,
    archive_id: Option<String>,
    archive_source: Option<String>,
}

pub(crate) async fn get_backup_schedule(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<Value, ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    let response = backup_schedule_response(state, &mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(response)
}

pub(crate) async fn update_backup_schedule(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    interval_hours: Option<i64>,
) -> Result<Value, ApiError> {
    let pool = pg_pool(state)?;
    let mut precheck = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut precheck, state, user, admin_usernames).await?;
    precheck.commit().await.map_err(ApiError::internal)?;
    if interval_hours.is_some()
        && !crate::backup::postgres_admin_supported_actions(state)
            .await
            .contains(&"backup")
    {
        return Err(backup_not_configured_error());
    }

    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    lock_backup_schedule(&mut tx).await?;
    let current: Option<i32> = sqlx::query_scalar(
        "SELECT interval_hours FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if current.map(i64::from) != interval_hours {
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=$1, \
                 next_run_at=CASE WHEN $1::INTEGER IS NULL THEN NULL \
                     ELSE clock_timestamp() + ($1::INTEGER * INTERVAL '1 hour') END \
             WHERE schedule_id=1",
        )
        .bind(interval_hours.map(|hours| hours as i32))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }
    record_schedule_update_event_tx(&mut tx, state, user).await?;
    let response = backup_schedule_response(state, &mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(response)
}

async fn backup_schedule_response(
    state: &AppState,
    tx: &mut Transaction<'_, Postgres>,
) -> Result<Value, ApiError> {
    let schedule = sqlx::query(
        "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let interval_hours: Option<i32> = schedule
        .try_get("interval_hours")
        .map_err(ApiError::internal)?;
    let next_run_at: Option<DateTime<Utc>> = schedule
        .try_get("next_run_at")
        .map_err(ApiError::internal)?;
    if interval_hours.is_some() != next_run_at.is_some() {
        return Err(ApiError::internal(
            "PostgreSQL backup schedule state is inconsistent",
        ));
    }
    let last = sqlx::query(
        "SELECT job_id,scheduled_for,requested_at,started_at,finished_at,status,result_code,archive_timestamp,archive_bytes \
         FROM instance_admin_jobs WHERE action='backup' AND request_origin='scheduled' \
         ORDER BY scheduled_for DESC,job_id DESC LIMIT 1",
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .map(|row| {
        let job_id: String = row.try_get("job_id").map_err(ApiError::internal)?;
        let scheduled_for: DateTime<Utc> = row.try_get("scheduled_for").map_err(ApiError::internal)?;
        let requested_at: DateTime<Utc> = row.try_get("requested_at").map_err(ApiError::internal)?;
        let started_at: Option<DateTime<Utc>> = row.try_get("started_at").map_err(ApiError::internal)?;
        let finished_at: Option<DateTime<Utc>> = row.try_get("finished_at").map_err(ApiError::internal)?;
        let database_status: String = row.try_get("status").map_err(ApiError::internal)?;
        let result_code: Option<String> = row.try_get("result_code").map_err(ApiError::internal)?;
        let archive_timestamp: Option<String> = row.try_get("archive_timestamp").map_err(ApiError::internal)?;
        let stored_archive_bytes: Option<i64> = row.try_get("archive_bytes").map_err(ApiError::internal)?;
        let status = match database_status.as_str() {
            "queued" | "running" => "running",
            "succeeded" => "succeeded",
            "failed" => "failed",
            "interrupted" => "interrupted",
            _ => return Err(ApiError::internal("PostgreSQL scheduled backup state is invalid")),
        };
        let result_is_consistent = match database_status.as_str() {
            "queued" | "running" => result_code.is_none(),
            "succeeded" => result_code.as_deref() == Some("completed"),
            "failed" => result_code.as_deref() == Some("backup_failed"),
            "interrupted" => result_code.as_deref() == Some("interrupted"),
            _ => false,
        };
        if !result_is_consistent {
            return Err(ApiError::internal(
                "PostgreSQL scheduled backup result is inconsistent",
            ));
        }
        let (result_code, migration_version, archive_bytes) = match status {
            "running" => (None, None, None),
            "succeeded" => (
                Some("completed"),
                Some(crate::backup::PG_BACKUP_SCHEMA_VERSION),
                stored_archive_bytes,
            ),
            "failed" => (Some("backup_failed"), None, None),
            "interrupted" => (Some("interrupted"), None, None),
            _ => unreachable!(),
        };
        if status == "succeeded" && archive_timestamp.is_none() {
            return Err(ApiError::internal("PostgreSQL scheduled backup archive is incomplete"));
        }
        Ok(json!({
            "run_id": job_id,
            "scheduled_for": scheduled_for.to_rfc3339_opts(SecondsFormat::Millis, true),
            "started_at": started_at.unwrap_or(requested_at).to_rfc3339_opts(SecondsFormat::Millis, true),
            "finished_at": finished_at.map(|value| value.to_rfc3339_opts(SecondsFormat::Millis, true)),
            "status": status,
            "result_code": result_code,
            "archive_bytes": archive_bytes,
            "migration_version": migration_version,
        }))
    })
    .transpose()?;
    let backup_configured = crate::backup::postgres_admin_supported_actions(state)
        .await
        .contains(&"backup");
    Ok(json!({
        "operation": "backup_schedule",
        "backup_configured": backup_configured,
        "interval_hours": interval_hours,
        "next_run_at": next_run_at.map(|value| value.to_rfc3339_opts(SecondsFormat::Millis, true)),
        "last_run": last,
    }))
}

async fn record_schedule_update_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type, \
             resource_id,result,occurred_at,source \
         ) VALUES('instance',$1,$2,$3,'admin.backup_schedule_updated','backup_schedule',NULL,'success',$4,'api')",
    )
    .bind(scope_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(occurred_at)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn lock_backup_schedule(tx: &mut Transaction<'_, Postgres>) -> Result<(), ApiError> {
    sqlx::query("SELECT schedule_id FROM instance_backup_schedule WHERE schedule_id=1 FOR UPDATE")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn list_jobs(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    limit: i64,
    offset: i64,
) -> Result<Value, ApiError> {
    if !(1..=PAGE_LIMIT_MAX).contains(&limit) || !(0..=1_000_000).contains(&offset) {
        return Err(ApiError::bad_request(
            "INVALID_LIMIT",
            "job pagination is outside the supported range",
        ));
    }
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;

    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_admin_jobs")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT job_id,request_id,requested_by_user_id,action,archive_id,archive_source, \
                status,requested_at,started_at,finished_at,result_code,restore_stage_status \
         FROM instance_admin_jobs \
         ORDER BY requested_at DESC,job_id DESC LIMIT $1 OFFSET $2",
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let jobs = rows
        .iter()
        .map(|row| job_dto(row, Some(&user.user_id)))
        .collect::<Result<Vec<_>, _>>()?;
    tx.commit().await.map_err(ApiError::internal)?;
    let supported_actions = crate::backup::postgres_admin_supported_actions(state).await;
    Ok(json!({
        "jobs": jobs,
        "total": total,
        "supported_actions": supported_actions,
    }))
}

pub(crate) async fn backup_status(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<Value, ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    let row = sqlx::query(
        "SELECT job_id,status,finished_at,archive_timestamp \
         FROM instance_admin_jobs \
         WHERE action='backup' AND status IN ('succeeded','failed','interrupted') \
         ORDER BY finished_at DESC,job_id DESC LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let attempt = row
        .map(|row| {
            let job_id: String = row.try_get("job_id").map_err(ApiError::internal)?;
            let status: String = row.try_get("status").map_err(ApiError::internal)?;
            let finished_at: DateTime<Utc> =
                row.try_get("finished_at").map_err(ApiError::internal)?;
            let archive_timestamp: Option<String> = row
                .try_get("archive_timestamp")
                .map_err(ApiError::internal)?;
            if !matches!(status.as_str(), "succeeded" | "failed" | "interrupted") {
                return Err(ApiError::internal(
                    "PostgreSQL backup status row is not terminal",
                ));
            }
            let succeeded = status == "succeeded";
            let archive_bytes = if succeeded {
                archive_timestamp.as_deref().and_then(|timestamp| {
                    crate::backup::pg_backup_archive_bytes_for_status(
                        &state.config,
                        timestamp,
                        &job_id,
                    )
                })
            } else {
                None
            };
            Ok(json!({
                "attempted_at": finished_at.to_rfc3339_opts(SecondsFormat::Millis, true),
                "result": if succeeded { "succeeded" } else { "failed" },
                "migration_version": if succeeded {
                    Some(crate::backup::PG_BACKUP_SCHEMA_VERSION)
                } else {
                    None
                },
                "archive_bytes": archive_bytes,
                "failure_category": if succeeded { None::<&str> } else { Some("backup_failed") },
            }))
        })
        .transpose()?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(json!({"operation":"backup","last_attempt":attempt}))
}

pub(crate) async fn ensure_instance_admin(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<(), ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    tx.commit().await.map_err(ApiError::internal)
}

pub(crate) async fn discard_restore_stage(
    state: AppState,
    headers: HeaderMap,
    restore_job_id: String,
    request: Result<Json<crate::admin::DiscardRestoreStageRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::auth::authenticate(&state, &headers).await?;
    crate::admin::validate_restore_job_id(&restore_job_id)?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_RESTORE_STAGE_DISCARD_REQUEST",
            "request body must contain only a canonical request_id",
        )
    })?;
    crate::admin::validate_admin_job_request_id(&request.request_id)?;

    let pool = pg_pool(&state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, &state, &user, &state.config.admin_usernames).await?;
    let row = sqlx::query(
        "SELECT requested_by_user_id,action,status,result_code,restore_stage_status, \
                restore_stage_discarded_at,restore_stage_target_cleaned_at \
         FROM instance_admin_jobs WHERE job_id=$1 FOR UPDATE",
    )
    .bind(&restore_job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let requested_by: String = row
        .try_get("requested_by_user_id")
        .map_err(ApiError::internal)?;
    if requested_by != user.user_id
        || row
            .try_get::<String, _>("action")
            .map_err(ApiError::internal)?
            != "restore"
    {
        return Err(ApiError::not_found());
    }
    let job_status: String = row.try_get("status").map_err(ApiError::internal)?;
    let result_code: Option<String> = row.try_get("result_code").map_err(ApiError::internal)?;
    let stage_status: Option<String> = row
        .try_get("restore_stage_status")
        .map_err(ApiError::internal)?;
    let completed_job = job_status == "succeeded" && result_code.as_deref() == Some("completed");
    let interrupted_after_stage_ready = job_status == "interrupted"
        && result_code.as_deref() == Some("interrupted")
        && matches!(
            stage_status.as_deref(),
            Some("ready" | "discarding" | "discarded")
        );
    if !completed_job && !interrupted_after_stage_ready {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "the PostgreSQL restore stage is not ready to discard",
        ));
    }
    let completed_discard_at: Option<DateTime<Utc>> = row
        .try_get("restore_stage_discarded_at")
        .map_err(ApiError::internal)?;
    let target_cleaned_at: Option<DateTime<Utc>> = row
        .try_get("restore_stage_target_cleaned_at")
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    if stage_status.as_deref() == Some("discarded")
        && target_cleaned_at.is_some()
        && let Some(discarded_at) = completed_discard_at
    {
        return Ok(Json(json!({
            "restore_stage": {
                "restore_job_id": restore_job_id,
                "status": "discarded",
                "discarded_at": discarded_at.to_rfc3339_opts(SecondsFormat::Millis, true),
            }
        })));
    }

    let mut guard = match stage_status.as_deref() {
        Some("ready") => {
            // Strictly validate the complete receipt, object-store tree,
            // target-side marker, generation and database identity before
            // recording the first durable transition.
            let guard =
                crate::backup::prepare_pg_restore_stage_discard(&state, &restore_job_id, false)
                    .await?;
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            require_instance_admin_tx(&mut tx, &state, &user, &state.config.admin_usernames)
                .await?;
            let changed = sqlx::query(
                "UPDATE instance_admin_jobs SET restore_stage_status='discarding', \
                     restore_stage_discard_requested_by_user_id=$1, \
                     restore_stage_discard_requested_by_device_id=$2, \
                     restore_stage_discard_requested_at=clock_timestamp() \
                 WHERE job_id=$3 AND requested_by_user_id=$1 AND action='restore' \
                   AND ((status='succeeded' AND result_code='completed') \
                     OR (status='interrupted' AND result_code='interrupted')) \
                   AND restore_stage_status='ready'",
            )
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(&restore_job_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if changed.rows_affected() != 1 {
                return Err(ApiError::conflict(
                    "RESTORE_STAGE_DISCARD_IN_PROGRESS",
                    "the PostgreSQL restore stage changed while discard was starting",
                ));
            }
            tx.commit().await.map_err(ApiError::internal)?;
            guard
        }
        Some("discarding" | "discarded") => {
            crate::backup::prepare_pg_restore_stage_discard(&state, &restore_job_id, true).await?
        }
        _ => {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_NOT_READY",
                "the PostgreSQL restore stage is not ready to discard",
            ));
        }
    };

    guard
        .discard_stage_files(&state, &restore_job_id)
        .await
        .map_err(|_| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "RESTORE_STAGE_DISCARD_FAILED",
                "the prepared PostgreSQL restore copy could not be discarded; retry the request",
            )
        })?;
    guard.commit_application_cleanup().await?;
    let discarded_at = finish_pg_restore_stage_discard(&state, &restore_job_id).await?;
    guard.commit().await?;
    mark_pg_restore_target_cleanup_complete(&state, &restore_job_id).await?;
    Ok(Json(json!({
        "restore_stage": {
            "restore_job_id": restore_job_id,
            "status": "discarded",
            "discarded_at": discarded_at,
        }
    })))
}

async fn finish_pg_restore_stage_discard(
    state: &AppState,
    restore_job_id: &str,
) -> Result<String, ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT restore_stage_status,restore_stage_discard_requested_by_user_id, \
                restore_stage_discard_requested_by_device_id,restore_stage_discarded_at \
         FROM instance_admin_jobs WHERE job_id=$1 FOR UPDATE",
    )
    .bind(restore_job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("PostgreSQL restore stage lifecycle is missing"))?;
    let status: String = row
        .try_get("restore_stage_status")
        .map_err(ApiError::internal)?;
    if status == "discarded" {
        let timestamp: DateTime<Utc> = row
            .try_get::<Option<DateTime<Utc>>, _>("restore_stage_discarded_at")
            .map_err(ApiError::internal)?
            .ok_or_else(|| {
                ApiError::internal("discarded PostgreSQL restore stage has no timestamp")
            })?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(timestamp.to_rfc3339_opts(SecondsFormat::Millis, true));
    }
    if status != "discarding" {
        return Err(ApiError::internal(
            "PostgreSQL restore stage discard was not prepared",
        ));
    }
    let actor_user_id: String = row
        .try_get::<Option<String>, _>("restore_stage_discard_requested_by_user_id")
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("PostgreSQL restore discard actor is missing"))?;
    let actor_device_id: String = row
        .try_get::<Option<String>, _>("restore_stage_discard_requested_by_device_id")
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("PostgreSQL restore discard device is missing"))?;
    let discarded_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET restore_stage_status='discarded',restore_stage_discarded_at=$1 \
         WHERE job_id=$2 AND restore_stage_status='discarding' AND restore_stage_discarded_at IS NULL",
    )
    .bind(discarded_at)
    .bind(restore_job_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    if changed == 1 {
        record_job_event_tx(
            &mut tx,
            state,
            Some(actor_user_id),
            Some(actor_device_id),
            "api",
            "admin.restore_stage_discarded",
            restore_job_id.to_owned(),
            "success",
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(discarded_at.to_rfc3339_opts(SecondsFormat::Millis, true))
}

async fn mark_pg_restore_target_cleanup_complete(
    state: &AppState,
    restore_job_id: &str,
) -> Result<(), ApiError> {
    let pool = pg_pool(state)?;
    sqlx::query(
        "UPDATE instance_admin_jobs SET restore_stage_target_cleaned_at=COALESCE( \
             restore_stage_target_cleaned_at,clock_timestamp()), \
             restore_stage_discard_next_retry_at=NULL \
         WHERE job_id=$1 AND action='restore' AND restore_stage_status='discarded' \
           AND restore_stage_discarded_at IS NOT NULL",
    )
    .bind(restore_job_id)
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn create_maintenance_job(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    request_id: &str,
) -> Result<(StatusCode, Value), ApiError> {
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    lock_backup_schedule(&mut tx).await?;

    let job_id = Uuid::new_v4().to_string();
    let inserted = sqlx::query(
        "INSERT INTO instance_admin_jobs( \
             job_id,request_id,requested_by_user_id,requested_by_device_id,action,status \
         ) VALUES($1,$2,$3,$4,'maintenance','queued') \
         ON CONFLICT (request_id) DO NOTHING RETURNING \
             job_id,request_id,requested_by_user_id,action,archive_id,archive_source, \
             status,requested_at,started_at,finished_at,result_code,restore_stage_status",
    )
    .bind(&job_id)
    .bind(request_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .fetch_optional(&mut *tx)
    .await;

    let row = match inserted {
        Ok(Some(row)) => {
            record_job_event_tx(
                &mut tx,
                state,
                Some(user.user_id.clone()),
                Some(user.device_id.clone()),
                "api",
                audit_action("maintenance", JobEvent::Requested)?,
                job_id.clone(),
                "success",
            )
            .await?;
            row
        }
        Ok(None) => {
            let Some(existing) = select_job_by_request_id(&mut tx, request_id).await? else {
                return Err(ApiError::internal(
                    "PostgreSQL admin job idempotency row disappeared",
                ));
            };
            ensure_idempotent_replay(
                &existing,
                &user.user_id,
                &user.device_id,
                "maintenance",
                None,
                None,
            )?;
            existing
        }
        Err(error) if is_unique_violation(&error) => {
            return Err(active_job_conflict("maintenance"));
        }
        Err(error) => return Err(ApiError::internal(error)),
    };

    let job = job_dto(&row, Some(&user.user_id))?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::ACCEPTED, json!({"job": job})))
}

/// Enqueue a server backup or an isolated restore of a server-generated local
/// or replicated archive. Authentication is revalidated in each ledger transaction, and the
/// archive catalog is consulted outside a write transaction. A retry with the
/// same request ID returns the original job even if retention later removes
/// its source archive.
pub(crate) async fn create_action_job(
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
    request_id: &str,
    action: &str,
    archive_id: Option<&str>,
    archive_source: Option<ArchiveSource>,
) -> Result<(StatusCode, Value), ApiError> {
    if !matches!(action, "backup" | "restore") {
        return Err(ApiError::bad_request(
            "INVALID_JOB_REQUEST",
            "PostgreSQL action jobs support backup and restore",
        ));
    }
    match action {
        "backup" if archive_id.is_none() && archive_source.is_none() => {}
        "restore"
            if archive_id.is_some()
                && archive_source.is_some()
                && archive_id.is_some_and(is_canonical_uuid) => {}
        _ => {
            return Err(ApiError::bad_request(
                "INVALID_JOB_REQUEST",
                "PostgreSQL restore jobs require a canonical archive_id and valid archive_source",
            ));
        }
    }

    let pool = pg_pool(state)?;
    {
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
        if let Some(existing) = select_job_by_request_id(&mut tx, request_id).await? {
            ensure_idempotent_replay(
                &existing,
                &user.user_id,
                &user.device_id,
                action,
                archive_id,
                archive_source,
            )?;
            let job = job_dto(&existing, Some(&user.user_id))?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok((StatusCode::ACCEPTED, json!({"job": job})));
        }
        tx.commit().await.map_err(ApiError::internal)?;
    }

    let supported = crate::backup::postgres_admin_supported_actions(state).await;
    if !supported.contains(&action)
        || (action == "restore"
            && archive_source == Some(ArchiveSource::Replica)
            && !supported.contains(&"restore_replica"))
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "PG_ADMIN_ACTION_UNSUPPORTED",
            "the requested PostgreSQL instance-admin action is not configured and ready",
        ));
    }
    if action == "restore" {
        let settings = crate::backup::configured_backup_paths(&state.config)
            .map_err(|_| backup_not_configured_error())?;
        let archive_id = archive_id.expect("validated restore archive id");
        let archive_source = archive_source.expect("validated restore archive source");
        if !crate::backup::server_generated_restore_source_exists(
            state,
            archive_id,
            archive_source,
            &settings,
        )
        .await?
        {
            return Err(ApiError::conflict(
                "RESTORE_SOURCE_UNAVAILABLE",
                "the selected server backup is unavailable for restore",
            ));
        }
    }

    // Revalidate after the filesystem catalog lookup and resolve any concurrent
    // idempotent insert before performing the durable write.
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_tx(&mut tx, state, user, admin_usernames).await?;
    lock_backup_schedule(&mut tx).await?;
    if let Some(existing) = select_job_by_request_id(&mut tx, request_id).await? {
        ensure_idempotent_replay(
            &existing,
            &user.user_id,
            &user.device_id,
            action,
            archive_id,
            archive_source,
        )?;
        let job = job_dto(&existing, Some(&user.user_id))?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok((StatusCode::ACCEPTED, json!({"job": job})));
    }

    let job_id = Uuid::new_v4().to_string();
    let stored_archive_id = if action == "backup" {
        Some(job_id.as_str())
    } else {
        archive_id
    };
    let stored_archive_source = archive_source.map(ArchiveSource::as_str);
    let inserted = sqlx::query(
        "INSERT INTO instance_admin_jobs( \
             job_id,request_id,requested_by_user_id,requested_by_device_id,action, \
             archive_id,archive_source,status \
         ) VALUES($1,$2,$3,$4,$5,$6,$7,'queued') \
         ON CONFLICT (request_id) DO NOTHING RETURNING \
             job_id,request_id,requested_by_user_id,action,archive_id,archive_source, \
             status,requested_at,started_at,finished_at,result_code,restore_stage_status",
    )
    .bind(&job_id)
    .bind(request_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(action)
    .bind(stored_archive_id)
    .bind(stored_archive_source)
    .fetch_optional(&mut *tx)
    .await;

    let row = match inserted {
        Ok(Some(row)) => {
            record_job_event_tx(
                &mut tx,
                state,
                Some(user.user_id.clone()),
                Some(user.device_id.clone()),
                "api",
                audit_action(action, JobEvent::Requested)?,
                job_id.clone(),
                "success",
            )
            .await?;
            row
        }
        Ok(None) => {
            let Some(existing) = select_job_by_request_id(&mut tx, request_id).await? else {
                return Err(ApiError::internal(
                    "PostgreSQL admin job idempotency row disappeared",
                ));
            };
            ensure_idempotent_replay(
                &existing,
                &user.user_id,
                &user.device_id,
                action,
                archive_id,
                archive_source,
            )?;
            existing
        }
        Err(error) if is_unique_violation(&error) => {
            return Err(active_job_conflict(action));
        }
        Err(error) => return Err(ApiError::internal(error)),
    };

    let job = job_dto(&row, Some(&user.user_id))?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::ACCEPTED, json!({"job": job})))
}

async fn select_job_by_request_id(
    tx: &mut Transaction<'_, Postgres>,
    request_id: &str,
) -> Result<Option<sqlx::postgres::PgRow>, ApiError> {
    sqlx::query(
        "SELECT job_id,request_id,requested_by_user_id,requested_by_device_id,action, \
                archive_id,archive_source,status,requested_at,started_at,finished_at, \
                result_code,restore_stage_status \
         FROM instance_admin_jobs WHERE request_id=$1 FOR SHARE",
    )
    .bind(request_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

fn ensure_idempotent_replay(
    existing: &sqlx::postgres::PgRow,
    user_id: &str,
    device_id: &str,
    action: &str,
    archive_id: Option<&str>,
    archive_source: Option<ArchiveSource>,
) -> Result<(), ApiError> {
    let existing_action: String = existing.try_get("action").map_err(ApiError::internal)?;
    let existing_user: Option<String> = existing
        .try_get("requested_by_user_id")
        .map_err(ApiError::internal)?;
    let existing_device: Option<String> = existing
        .try_get("requested_by_device_id")
        .map_err(ApiError::internal)?;
    let existing_job_id: String = existing.try_get("job_id").map_err(ApiError::internal)?;
    let existing_archive_id: Option<String> =
        existing.try_get("archive_id").map_err(ApiError::internal)?;
    let existing_archive_source: Option<String> = existing
        .try_get("archive_source")
        .map_err(ApiError::internal)?;
    let backup_identity_matches =
        action == "backup" && existing_archive_id.as_deref() == Some(existing_job_id.as_str());
    let restore_identity_matches = action == "restore"
        && existing_archive_id.as_deref() == archive_id
        && existing_archive_source.as_deref() == archive_source.map(ArchiveSource::as_str);
    let matches = existing_action == action
        && existing_user.as_deref() == Some(user_id)
        && existing_device.as_deref() == Some(device_id)
        && (backup_identity_matches || restore_identity_matches || action == "maintenance");
    if matches {
        Ok(())
    } else {
        Err(ApiError::conflict(
            "JOB_REQUEST_ID_CONFLICT",
            "request_id is already associated with a different job request",
        ))
    }
}

fn active_job_conflict(action: &str) -> ApiError {
    match action {
        "maintenance" => ApiError::conflict(
            "MAINTENANCE_ALREADY_RUNNING",
            "an instance-admin job is already queued or running",
        ),
        "backup" => ApiError::conflict(
            "BACKUP_ALREADY_RUNNING",
            "an instance-admin job is already queued or running",
        ),
        "restore" => ApiError::conflict(
            "RESTORE_ALREADY_RUNNING",
            "an instance-admin job is already queued or running",
        ),
        _ => ApiError::conflict(
            "INSTANCE_ADMIN_JOB_ALREADY_RUNNING",
            "an instance-admin job is already queued or running",
        ),
    }
}

pub(crate) fn start_worker(state: AppState) {
    let schedule_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(WORKER_POLL_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            if let Err(error) = run_one_available(&state).await {
                tracing::warn!(
                    error_code = %error.body.code,
                    "PostgreSQL instance-admin job worker iteration failed"
                );
            }
        }
    });

    tokio::spawn(async move {
        let mut interval = tokio::time::interval(SCHEDULE_POLL_INTERVAL);
        interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            if let Err(error) = enqueue_due_scheduled_backup(&schedule_state).await {
                tracing::warn!(
                    error_code = %error.body.code,
                    "PostgreSQL scheduled-backup worker iteration failed"
                );
            }
        }
    });
}

async fn enqueue_due_scheduled_backup(state: &AppState) -> Result<bool, ApiError> {
    if !crate::backup::postgres_admin_supported_actions(state)
        .await
        .contains(&"backup")
    {
        return Ok(false);
    }
    let pool = pg_pool(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    let Some(schedule) = sqlx::query(
        "SELECT interval_hours,next_run_at FROM instance_backup_schedule \
         WHERE schedule_id=1 FOR UPDATE",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    else {
        return Err(ApiError::internal(
            "PostgreSQL backup schedule row is missing",
        ));
    };
    let interval_hours: Option<i32> = schedule
        .try_get("interval_hours")
        .map_err(ApiError::internal)?;
    let next_run_at: Option<DateTime<Utc>> = schedule
        .try_get("next_run_at")
        .map_err(ApiError::internal)?;
    let (Some(interval_hours), Some(scheduled_for)) = (interval_hours, next_run_at) else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    };
    let due: bool = sqlx::query_scalar("SELECT $1::TIMESTAMPTZ <= clock_timestamp()")
        .bind(scheduled_for)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if !due {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM instance_admin_jobs WHERE status IN ('queued','running'))",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if active {
        // Keep the slot due. Manual backup, restore, and maintenance share
        // this same schedule-row lock before inserting into the ledger.
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }

    let job_id = Uuid::new_v4().to_string();
    let request_id = Uuid::new_v4().to_string();
    sqlx::query(
        "UPDATE instance_backup_schedule SET \
             next_run_at=clock_timestamp() + ($1::INTEGER * INTERVAL '1 hour') \
         WHERE schedule_id=1",
    )
    .bind(interval_hours)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let inserted = sqlx::query(
        "INSERT INTO instance_admin_jobs( \
             job_id,request_id,requested_by_user_id,requested_by_device_id,action, \
             archive_id,request_origin,scheduled_for,status \
         ) VALUES($1,$2,NULL,NULL,'backup',$1,'scheduled',$3,'queued') \
         RETURNING job_id",
    )
    .bind(&job_id)
    .bind(&request_id)
    .bind(scheduled_for)
    .execute(&mut *tx)
    .await;
    if let Err(error) = inserted {
        tx.rollback().await.map_err(ApiError::internal)?;
        if is_unique_violation(&error) {
            return Ok(false);
        }
        return Err(ApiError::internal(error));
    }
    record_job_event_tx(
        &mut tx,
        state,
        None,
        None,
        "maintenance",
        audit_action("backup", JobEvent::Requested)?,
        job_id.clone(),
        "success",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(true)
}

pub(crate) async fn run_one_available(state: &AppState) -> Result<(), ApiError> {
    let Some(pool) = state.pg_sync_pool.as_ref() else {
        return Err(ApiError::internal("PostgreSQL runtime pool is unavailable"));
    };
    if let Err(error) = retry_one_restore_stage_discard(state).await {
        tracing::warn!(
            error_code = %error.body.code,
            "PostgreSQL restore-stage discard recovery will retry"
        );
    }
    let Some(claim) = claim_next(pool, state).await? else {
        return Ok(());
    };

    let operation = async {
        match claim.action.as_str() {
            "maintenance" => crate::run_maintenance(state).await,
            "backup" => crate::backup::run_configured_admin_backup(state, &claim.job_id).await,
            "restore" => match (claim.archive_id.as_deref(), claim.archive_source.as_deref()) {
                (Some(archive_id), Some("local" | "replica")) => {
                    let archive_source = if claim.archive_source.as_deref() == Some("replica") {
                        ArchiveSource::Replica
                    } else {
                        ArchiveSource::Local
                    };
                    crate::backup::run_configured_admin_restore_stage(
                        state,
                        &claim.job_id,
                        archive_id,
                        archive_source,
                    )
                    .await
                }
                _ => Err(ApiError::internal(
                    "PostgreSQL restore job has invalid archive metadata",
                )),
            },
            _ => Err(ApiError::internal("PostgreSQL admin job action is invalid")),
        }
    };
    tokio::pin!(operation);
    let mut heartbeat = tokio::time::interval(WORKER_HEARTBEAT);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Skip);
    let result = loop {
        tokio::select! {
            result = &mut operation => break result,
            _ = heartbeat.tick() => {
                match renew_claim(pool, &claim).await {
                    Ok(true) => {}
                    // Dropping the operation cancels the Rust future. The
                    // PostgreSQL snapshot subprocesses use kill-on-drop so a
                    // stale lease cannot continue writing a restore stage.
                    Ok(false) => return Ok(()),
                    Err(error) => {
                        tracing::warn!(
                            error_code = %error.body.code,
                            "PostgreSQL instance-admin job lease renewal failed; cancelling operation"
                        );
                        return Ok(());
                    }
                }
            }
        }
    };
    if let Err(error) = &result {
        tracing::warn!(
            error_code = %error.body.code,
            action = %claim.action,
            "PostgreSQL instance-admin job operation failed"
        );
    }
    finish_claim(pool, state, &claim, result.is_ok()).await
}

async fn retry_one_restore_stage_discard(state: &AppState) -> Result<(), ApiError> {
    let pool = pg_pool(state)?;
    let job_id: Option<String> = sqlx::query_scalar(
        "SELECT job_id FROM instance_admin_jobs \
         WHERE action='restore' AND status IN ('succeeded','interrupted') \
           AND restore_stage_status IN ('discarding','discarded') \
           AND restore_stage_target_cleaned_at IS NULL \
           AND (restore_stage_discard_next_retry_at IS NULL \
                OR restore_stage_discard_next_retry_at<=clock_timestamp()) \
         ORDER BY restore_stage_discard_requested_at,job_id LIMIT 1",
    )
    .fetch_optional(pool)
    .await
    .map_err(ApiError::internal)?;
    let Some(job_id) = job_id else {
        return Ok(());
    };
    let result = async {
        let mut guard =
            crate::backup::prepare_pg_restore_stage_discard(state, &job_id, true).await?;
        guard.discard_stage_files(state, &job_id).await?;
        guard.commit_application_cleanup().await?;
        finish_pg_restore_stage_discard(state, &job_id).await?;
        guard.commit().await?;
        mark_pg_restore_target_cleanup_complete(state, &job_id).await
    }
    .await;
    if result.is_err() {
        mark_pg_restore_discard_retry_backoff(state, &job_id).await?;
    }
    result
}

async fn mark_pg_restore_discard_retry_backoff(
    state: &AppState,
    restore_job_id: &str,
) -> Result<(), ApiError> {
    let pool = pg_pool(state)?;
    sqlx::query(
        "UPDATE instance_admin_jobs SET \
             restore_stage_discard_attempts=LEAST(restore_stage_discard_attempts+1,16), \
             restore_stage_discard_next_retry_at=clock_timestamp()+make_interval(secs => \
                 LEAST(3600,30*power(2,LEAST(restore_stage_discard_attempts,7)))::integer) \
         WHERE job_id=$1 AND restore_stage_status IN ('discarding','discarded') \
           AND restore_stage_target_cleaned_at IS NULL",
    )
    .bind(restore_job_id)
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

async fn claim_next(pool: &PgPool, state: &AppState) -> Result<Option<ClaimedJob>, ApiError> {
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    interrupt_expired_claims(&mut tx, state).await?;
    let candidate = sqlx::query(
        "SELECT job_id,requested_by_user_id,requested_by_device_id,request_origin,action,archive_id,archive_source \
         FROM instance_admin_jobs WHERE status='queued' \
         ORDER BY requested_at,job_id LIMIT 1 FOR UPDATE SKIP LOCKED",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(candidate) = candidate else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let job_id: String = candidate.try_get("job_id").map_err(ApiError::internal)?;
    let requester = ClaimedJob {
        job_id: job_id.clone(),
        worker_token: Uuid::new_v4().to_string(),
        requested_by_user_id: candidate
            .try_get("requested_by_user_id")
            .map_err(ApiError::internal)?,
        requested_by_device_id: candidate
            .try_get("requested_by_device_id")
            .map_err(ApiError::internal)?,
        request_origin: candidate
            .try_get("request_origin")
            .map_err(ApiError::internal)?,
        action: candidate.try_get("action").map_err(ApiError::internal)?,
        archive_id: candidate
            .try_get("archive_id")
            .map_err(ApiError::internal)?,
        archive_source: candidate
            .try_get("archive_source")
            .map_err(ApiError::internal)?,
    };
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET status='running',started_at=clock_timestamp(), \
             worker_token=$2,lease_expires_at=clock_timestamp()+$3::interval, \
             attempt_count=attempt_count+1 \
         WHERE job_id=$1 AND status='queued'",
    )
    .bind(&requester.job_id)
    .bind(&requester.worker_token)
    .bind(format!("{} seconds", WORKER_LEASE.as_secs()))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "PostgreSQL admin job claim transition was not applied",
        ));
    }
    record_job_event_tx(
        &mut tx,
        state,
        requester.requested_by_user_id.clone(),
        requester.requested_by_device_id.clone(),
        job_audit_source(&requester.request_origin)?,
        audit_action(&requester.action, JobEvent::Started)?,
        requester.job_id.clone(),
        "success",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(requester))
}

async fn interrupt_expired_claims(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
) -> Result<(), ApiError> {
    let expired = sqlx::query(
        "SELECT job_id,requested_by_user_id,requested_by_device_id,request_origin,action \
         FROM instance_admin_jobs \
         WHERE status='running' AND lease_expires_at <= clock_timestamp() \
         ORDER BY requested_at,job_id FOR UPDATE SKIP LOCKED",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for row in expired {
        let job_id: String = row.try_get("job_id").map_err(ApiError::internal)?;
        let user_id: Option<String> = row
            .try_get("requested_by_user_id")
            .map_err(ApiError::internal)?;
        let device_id: Option<String> = row
            .try_get("requested_by_device_id")
            .map_err(ApiError::internal)?;
        let request_origin: String = row.try_get("request_origin").map_err(ApiError::internal)?;
        let action: String = row.try_get("action").map_err(ApiError::internal)?;
        let changed = sqlx::query(
            "UPDATE instance_admin_jobs SET status='interrupted',finished_at=clock_timestamp(), \
                 result_code='interrupted',worker_token=NULL,lease_expires_at=NULL, \
                 restore_stage_status=CASE WHEN action='restore' AND restore_stage_status IS NULL \
                     THEN 'interrupted' ELSE restore_stage_status END \
             WHERE job_id=$1 AND status='running' AND lease_expires_at <= clock_timestamp()",
        )
        .bind(&job_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() == 1 {
            record_job_event_tx(
                tx,
                state,
                user_id,
                device_id,
                job_audit_source(&request_origin)?,
                audit_action(&action, JobEvent::Interrupted)?,
                job_id.clone(),
                "failure",
            )
            .await?;
        }
    }
    Ok(())
}

async fn renew_claim(pool: &PgPool, claim: &ClaimedJob) -> Result<bool, ApiError> {
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET lease_expires_at=clock_timestamp()+$3::interval \
         WHERE job_id=$1 AND status='running' AND worker_token=$2",
    )
    .bind(&claim.job_id)
    .bind(&claim.worker_token)
    .bind(format!("{} seconds", WORKER_LEASE.as_secs()))
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    Ok(changed.rows_affected() == 1)
}

async fn finish_claim(
    pool: &PgPool,
    state: &AppState,
    claim: &ClaimedJob,
    succeeded: bool,
) -> Result<(), ApiError> {
    let mut attempt = 0_u32;
    loop {
        match finish_claim_once(pool, state, claim, succeeded).await {
            Ok(()) => return Ok(()),
            Err(error) => {
                attempt = attempt.saturating_add(1);
                let delay = Duration::from_millis(
                    250_u64.saturating_mul(1_u64 << attempt.saturating_sub(1).min(7)),
                )
                .min(Duration::from_secs(30));
                tracing::error!(
                    error_code = %error.body.code,
                    attempt,
                    "PostgreSQL instance-admin terminal result is not durable; retrying"
                );
                tokio::time::sleep(delay).await;
            }
        }
    }
}

async fn finish_claim_once(
    pool: &PgPool,
    state: &AppState,
    claim: &ClaimedJob,
    succeeded: bool,
) -> Result<(), ApiError> {
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    let current = sqlx::query(
        "SELECT status,worker_token FROM instance_admin_jobs WHERE job_id=$1 FOR UPDATE",
    )
    .bind(&claim.job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(current) = current else {
        return Err(ApiError::internal("PostgreSQL admin job row disappeared"));
    };
    let status: String = current.try_get("status").map_err(ApiError::internal)?;
    let token: Option<String> = current
        .try_get("worker_token")
        .map_err(ApiError::internal)?;
    if matches!(status.as_str(), "succeeded" | "failed" | "interrupted")
        || token.as_deref() != Some(&claim.worker_token)
    {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(());
    }
    if status != "running" {
        return Err(ApiError::internal("PostgreSQL admin job is not running"));
    }
    let (next_status, result_code, stage, result) = if succeeded {
        ("succeeded", "completed", JobEvent::Completed, "success")
    } else {
        (
            "failed",
            failed_result_code(&claim.action)?,
            JobEvent::Failed,
            "failure",
        )
    };
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET status=$2,finished_at=clock_timestamp(), \
             result_code=$3,worker_token=NULL,lease_expires_at=NULL, \
             restore_stage_status=CASE WHEN action='restore' AND $2='failed' \
                     AND restore_stage_status IS NULL THEN 'failed' ELSE restore_stage_status END \
         WHERE job_id=$1 AND status='running' AND worker_token=$4",
    )
    .bind(&claim.job_id)
    .bind(next_status)
    .bind(result_code)
    .bind(&claim.worker_token)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "PostgreSQL admin job terminal transition was not applied",
        ));
    }
    record_job_event_tx(
        &mut tx,
        state,
        claim.requested_by_user_id.clone(),
        claim.requested_by_device_id.clone(),
        job_audit_source(&claim.request_origin)?,
        audit_action(&claim.action, stage)?,
        claim.job_id.clone(),
        result,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)
}

#[derive(Clone, Copy)]
enum JobEvent {
    Requested,
    Started,
    Completed,
    Failed,
    Interrupted,
}

fn audit_action(action: &str, event: JobEvent) -> Result<&'static str, ApiError> {
    let suffix = match event {
        JobEvent::Requested => "requested",
        JobEvent::Started => "started",
        JobEvent::Completed => "completed",
        JobEvent::Failed => "failed",
        JobEvent::Interrupted => "interrupted",
    };
    match (action, suffix) {
        ("maintenance", "requested") => Ok("admin.maintenance_requested"),
        ("maintenance", "started") => Ok("admin.maintenance_started"),
        ("maintenance", "completed") => Ok("admin.maintenance_completed"),
        ("maintenance", "failed") => Ok("admin.maintenance_failed"),
        ("maintenance", "interrupted") => Ok("admin.maintenance_interrupted"),
        ("backup", "requested") => Ok("admin.backup_requested"),
        ("backup", "started") => Ok("admin.backup_started"),
        ("backup", "completed") => Ok("admin.backup_completed"),
        ("backup", "failed") => Ok("admin.backup_failed"),
        ("backup", "interrupted") => Ok("admin.backup_interrupted"),
        ("restore", "requested") => Ok("admin.restore_requested"),
        ("restore", "started") => Ok("admin.restore_started"),
        ("restore", "completed") => Ok("admin.restore_completed"),
        ("restore", "failed") => Ok("admin.restore_failed"),
        ("restore", "interrupted") => Ok("admin.restore_interrupted"),
        _ => Err(ApiError::internal("PostgreSQL admin job action is invalid")),
    }
}

fn failed_result_code(action: &str) -> Result<&'static str, ApiError> {
    match action {
        "maintenance" => Ok("maintenance_failed"),
        "backup" => Ok("backup_failed"),
        "restore" => Ok("restore_failed"),
        _ => Err(ApiError::internal("PostgreSQL admin job action is invalid")),
    }
}

pub(crate) async fn require_instance_admin_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    user: &AuthUser,
    admin_usernames: &[String],
) -> Result<(), ApiError> {
    let username: Option<String> = sqlx::query_scalar(
        "SELECT u.username FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4 \
           AND s.revoked_at IS NULL AND s.access_expires_at>clock_timestamp() \
           AND u.status='active' AND d.status='active' \
         FOR SHARE OF s,u,d",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(username) = username else {
        return Err(ApiError::unauthorized());
    };
    if !admin_usernames
        .iter()
        .any(|configured| configured == &username)
    {
        return Err(ApiError::forbidden(
            "INSTANCE_ADMIN_REQUIRED",
            "this account is not configured for instance administration",
        ));
    }
    let _ = state;
    Ok(())
}

async fn record_job_event_tx(
    tx: &mut Transaction<'_, Postgres>,
    state: &AppState,
    actor_user_id: Option<String>,
    actor_device_id: Option<String>,
    source: &'static str,
    action: &'static str,
    job_id: String,
    result: &'static str,
) -> Result<(), ApiError> {
    let scope_id = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = crate::audit::instance_resource_id(&state.cursor_key, "admin_job", &job_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO audit_events( \
             scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type, \
             resource_id,result,occurred_at,source \
         ) VALUES('instance',$1,$2,$3,$4,'admin_job',$5,$6,$7,$8)",
    )
    .bind(scope_id)
    .bind(actor_user_id)
    .bind(actor_device_id)
    .bind(action)
    .bind(resource_id)
    .bind(result)
    .bind(occurred_at)
    .bind(source)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn job_audit_source(request_origin: &str) -> Result<&'static str, ApiError> {
    match request_origin {
        "manual" => Ok("api"),
        // The PG audit schema uses `maintenance` for system-generated events.
        // Scheduled rows intentionally carry no fabricated human actor.
        "scheduled" => Ok("maintenance"),
        _ => Err(ApiError::internal("PostgreSQL admin job origin is invalid")),
    }
}

fn job_dto(row: &sqlx::postgres::PgRow, viewer_user_id: Option<&str>) -> Result<Value, ApiError> {
    let format = |field: &str| -> Result<Option<String>, ApiError> {
        row.try_get::<Option<DateTime<Utc>>, _>(field)
            .map_err(ApiError::internal)
            .map(|value| {
                value.map(|timestamp| timestamp.to_rfc3339_opts(SecondsFormat::Millis, true))
            })
    };
    let action: String = row.try_get("action").map_err(ApiError::internal)?;
    let archive_id: Option<String> = row.try_get("archive_id").map_err(ApiError::internal)?;
    let archive_source: Option<String> =
        row.try_get("archive_source").map_err(ApiError::internal)?;
    let requested_by_user_id: Option<String> = row
        .try_get("requested_by_user_id")
        .map_err(ApiError::internal)?;
    let restore_stage_status: Option<String> = row
        .try_get("restore_stage_status")
        .map_err(ApiError::internal)?;
    Ok(json!({
        "job_id": row.try_get::<String, _>("job_id").map_err(ApiError::internal)?,
        "request_id": row.try_get::<String, _>("request_id").map_err(ApiError::internal)?,
        "action": action,
        "archive_id": archive_id,
        "archive_source": if action == "restore" { archive_source } else { None },
        "status": row.try_get::<String, _>("status").map_err(ApiError::internal)?,
        "requested_at": row.try_get::<DateTime<Utc>, _>("requested_at").map_err(ApiError::internal)?
            .to_rfc3339_opts(SecondsFormat::Millis, true),
        "started_at": format("started_at")?,
        "finished_at": format("finished_at")?,
        "result_code": row.try_get::<Option<String>, _>("result_code").map_err(ApiError::internal)?,
        "restore_stage_status": if action == "restore"
            && viewer_user_id == requested_by_user_id.as_deref()
        {
            restore_stage_status
        } else {
            None
        },
    }))
}

fn pg_pool(state: &AppState) -> Result<&PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL admin job repository is unavailable"))
}

fn is_canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|parsed| parsed.to_string() == value)
}

fn backup_not_configured_error() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "BACKUP_NOT_CONFIGURED",
        "server-side encrypted backup is not configured",
    )
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    error
        .as_database_error()
        .and_then(|database| database.code())
        .is_some_and(|code| code == "23505")
}

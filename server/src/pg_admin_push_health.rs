//! Aggregate-only mobile push queue snapshots for restricted PostgreSQL.

use axum::Json;
use serde_json::Value;
use sqlx::Row;

use crate::{
    ApiError, AppState,
    admin::{PushDeliveryCounts, PushHealthCounts, PushHealthWindow},
    auth::AuthUser,
};

pub(crate) async fn push_health(
    state: &AppState,
    user: &AuthUser,
) -> Result<Json<Value>, ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL runtime pool is unavailable"))?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(
        &mut tx,
        state,
        user,
        &state.config.admin_usernames,
    )
    .await?;

    // Capture one database timestamp and use it for both generated_at and all
    // scheduling/lease comparisons. Queue status is shared state: unlike the
    // workers' claim selection, this snapshot does not filter by local adapter
    // configuration or account/device lifecycle status.
    let rows = sqlx::query(
        "WITH db_clock AS ( \
             SELECT clock_timestamp() AS captured_at \
         ), provider_keys(provider,sort_order) AS (VALUES ('apns',0),('fcm_v1',1)), \
         endpoint_counts AS ( \
             SELECT provider,COUNT(*)::BIGINT AS registered_endpoints \
             FROM notification_push_endpoints GROUP BY provider \
         ), queue_counts AS ( \
             SELECT e.provider, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND NOT o.dead_lettered \
                              AND o.next_attempt_at<=floor(extract(epoch FROM c.captured_at))::BIGINT \
                              AND (o.lease_until IS NULL OR \
                                   o.lease_until<=floor(extract(epoch FROM c.captured_at))::BIGINT) \
                        THEN 1 ELSE 0 END)::BIGINT AS due, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND NOT o.dead_lettered \
                              AND o.lease_until>floor(extract(epoch FROM c.captured_at))::BIGINT \
                        THEN 1 ELSE 0 END)::BIGINT AS leased, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND NOT o.dead_lettered \
                              AND o.next_attempt_at>floor(extract(epoch FROM c.captured_at))::BIGINT \
                        THEN 1 ELSE 0 END)::BIGINT AS retry_waiting, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND o.dead_lettered \
                        THEN 1 ELSE 0 END)::BIGINT AS dead_lettered \
             FROM notification_push_outbox o \
             JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id \
             CROSS JOIN db_clock c GROUP BY e.provider \
         ) \
         SELECT to_char(c.captured_at AT TIME ZONE 'UTC', \
                        'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS generated_at, \
                to_char(date_trunc('day',c.captured_at AT TIME ZONE 'UTC') - interval '6 days', \
                        'YYYY-MM-DD') AS window_start_date, \
                to_char(c.captured_at AT TIME ZONE 'UTC','YYYY-MM-DD') AS window_end_date, \
                floor(extract(epoch FROM c.captured_at))::BIGINT AS now_epoch, \
                p.provider, \
                COALESCE(ec.registered_endpoints,0)::BIGINT AS registered_endpoints, \
                COALESCE(qc.due,0)::BIGINT AS due, \
                COALESCE(qc.retry_waiting,0)::BIGINT AS retry_waiting, \
                COALESCE(qc.leased,0)::BIGINT AS leased, \
                COALESCE(qc.dead_lettered,0)::BIGINT AS dead_lettered \
         FROM db_clock c CROSS JOIN provider_keys p \
         LEFT JOIN endpoint_counts ec ON ec.provider=p.provider \
         LEFT JOIN queue_counts qc ON qc.provider=p.provider \
         ORDER BY p.sort_order",
    )
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let generated_at = rows
        .first()
        .map(|row| row.get::<String, _>("generated_at"))
        .ok_or_else(|| ApiError::internal("push health provider snapshot is empty"))?;
    let first = rows
        .first()
        .expect("a fixed provider row is always present");
    let today_start_epoch = first.get::<i64, _>("now_epoch").div_euclid(86_400) * 86_400;
    let window_start_epoch = today_start_epoch - 6 * 86_400;
    let window = PushHealthWindow {
        start_date_utc: first
            .try_get("window_start_date")
            .map_err(ApiError::internal)?,
        end_date_utc: first
            .try_get("window_end_date")
            .map_err(ApiError::internal)?,
    };
    let mut apns = PushHealthCounts::default();
    let mut fcm_v1 = PushHealthCounts::default();
    for row in rows {
        let counts = PushHealthCounts {
            registered_endpoints: row
                .try_get("registered_endpoints")
                .map_err(ApiError::internal)?,
            due: row.try_get("due").map_err(ApiError::internal)?,
            retry_waiting: row.try_get("retry_waiting").map_err(ApiError::internal)?,
            leased: row.try_get("leased").map_err(ApiError::internal)?,
            dead_lettered: row.try_get("dead_lettered").map_err(ApiError::internal)?,
        };
        match row
            .try_get::<String, _>("provider")
            .map_err(ApiError::internal)?
            .as_str()
        {
            "apns" => apns = counts,
            "fcm_v1" => fcm_v1 = counts,
            _ => return Err(ApiError::internal("push health provider key is invalid")),
        }
    }
    let delivery_rows = sqlx::query(
        "SELECT provider,outcome,SUM(count)::BIGINT AS total \
         FROM notification_push_delivery_daily \
         WHERE day_start >= $1 AND day_start <= $2 GROUP BY provider,outcome",
    )
    .bind(window_start_epoch)
    .bind(today_start_epoch)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut apns_delivery = PushDeliveryCounts::default();
    let mut fcm_v1_delivery = PushDeliveryCounts::default();
    for row in delivery_rows {
        let provider = row
            .try_get::<String, _>("provider")
            .map_err(ApiError::internal)?;
        let outcome = row
            .try_get::<String, _>("outcome")
            .map_err(ApiError::internal)?;
        let counts = match provider.as_str() {
            "apns" => &mut apns_delivery,
            "fcm_v1" => &mut fcm_v1_delivery,
            _ => return Err(ApiError::internal("push health provider key is invalid")),
        };
        let total = row.try_get("total").map_err(ApiError::internal)?;
        match outcome.as_str() {
            "accepted" => counts.accepted = total,
            "invalid_token" => counts.invalid_token = total,
            "retryable_failure" => counts.retryable_failure = total,
            _ => return Err(ApiError::internal("push health outcome key is invalid")),
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(crate::admin::push_health_response(
        generated_at,
        window,
        apns,
        apns_delivery,
        fcm_v1,
        fcm_v1_delivery,
    ))
}

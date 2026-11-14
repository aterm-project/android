//! Instance-wide administration APIs.
//!
//! These handlers expose bounded account/Vault metadata and administrative
//! controls only. Credentials, private keys, encrypted names, record envelopes,
//! session token hashes, and object payloads are never returned.

use crate::{ApiError, AppState, audit, auth, now_rfc3339};
use axum::{
    Json,
    body::{Body, to_bytes},
    extract::{Path, Query, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, Sqlite, Transaction};
#[cfg(test)]
use std::{collections::HashMap, sync::Arc};
use std::{
    collections::HashSet,
    sync::{Mutex as StdMutex, OnceLock},
    time::Duration,
};
use uuid::Uuid;

const DEFAULT_VAULT_PAGE_SIZE: u32 = 50;
const MAX_VAULT_PAGE_SIZE: u32 = 100;
const MAX_VAULT_PAGE_OFFSET: u32 = 1_000_000;
const MAX_ADMIN_VAULT_QUOTA_BYTES: i64 = 1_i64 << 40;
const DEFAULT_ADMIN_ACCOUNT_PAGE_SIZE: u32 = 50;
const MAX_ADMIN_ACCOUNT_PAGE_SIZE: u32 = 100;
const DEFAULT_ADMIN_INVITATION_PAGE_SIZE: u32 = 50;
const MAX_ADMIN_INVITATION_PAGE_SIZE: u32 = 100;
const DEFAULT_ADMIN_JOB_PAGE_SIZE: u32 = 50;
const MAX_ADMIN_JOB_PAGE_SIZE: u32 = 100;
const MAX_ADMIN_JOB_PAGE_OFFSET: u32 = 1_000_000;
const MIN_BACKUP_INTERVAL_HOURS: i64 = 1;
const MAX_BACKUP_INTERVAL_HOURS: i64 = 720;
pub(crate) const METRICS_CREDENTIAL_PREFIX: &str = "atm_";
pub(crate) const METRICS_CREDENTIAL_BYTES: usize = 32;
const METRICS_CREDENTIAL_DOMAIN: &[u8] = b"atermius/admin-metrics-credential/v1\0";

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Deserialize)]
pub struct VaultListQuery {
    limit: Option<String>,
    offset: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateVaultQuotaRequest {
    quota_bytes: i64,
}

#[derive(Debug, Deserialize)]
pub struct AdminAccountListQuery {
    limit: Option<String>,
    offset: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct AdminAccountInvitationListQuery {
    limit: Option<String>,
    offset: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateAdminAccountInvitationRequest {
    username: String,
    #[serde(default, deserialize_with = "deserialize_account_invitation_ttl")]
    expires_in_seconds: Option<i64>,
    /// Optional explicit credential-visibility mode for the invited account;
    /// null or absent uses the instance default at registration.
    #[serde(default)]
    credential_visibility: Option<crate::credential_visibility::CredentialVisibility>,
}

fn deserialize_account_invitation_ttl<'de, D>(deserializer: D) -> Result<Option<i64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    i64::deserialize(deserializer).map(Some)
}

#[derive(Debug, Deserialize)]
pub struct AdminJobListQuery {
    limit: Option<String>,
    offset: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateAdminJobRequest {
    request_id: String,
    action: AdminJobAction,
    #[serde(default, deserialize_with = "deserialize_archive_id_field")]
    archive_id: ArchiveIdField,
    #[serde(default, deserialize_with = "deserialize_archive_source_field")]
    archive_source: ArchiveSourceField,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiscardRestoreStageRequest {
    pub(crate) request_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct BackupReplicationPreflightRequest {}

#[derive(Debug, Default)]
enum ArchiveIdField {
    #[default]
    Missing,
    Present(Option<String>),
}

#[derive(Debug, Default)]
enum ArchiveSourceField {
    #[default]
    Missing,
    Present(Option<String>),
}

fn deserialize_archive_id_field<'de, D>(deserializer: D) -> Result<ArchiveIdField, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(ArchiveIdField::Present)
}

fn deserialize_archive_source_field<'de, D>(deserializer: D) -> Result<ArchiveSourceField, D::Error>
where
    D: serde::Deserializer<'de>,
{
    Option::<String>::deserialize(deserializer).map(ArchiveSourceField::Present)
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum AdminJobAction {
    Maintenance,
    Backup,
    Restore,
}

impl AdminJobAction {
    fn as_str(self) -> &'static str {
        match self {
            Self::Maintenance => "maintenance",
            Self::Backup => "backup",
            Self::Restore => "restore",
        }
    }

    fn from_storage(value: &str) -> Result<Self, ApiError> {
        match value {
            "maintenance" => Ok(Self::Maintenance),
            "backup" => Ok(Self::Backup),
            "restore" => Ok(Self::Restore),
            _ => Err(ApiError::internal("stored admin job action is invalid")),
        }
    }

    fn event(self, stage: AdminJobAuditStage) -> &'static str {
        match (self, stage) {
            (Self::Maintenance, AdminJobAuditStage::Requested) => "admin.maintenance_requested",
            (Self::Maintenance, AdminJobAuditStage::Started) => "admin.maintenance_started",
            (Self::Maintenance, AdminJobAuditStage::Completed) => "admin.maintenance_completed",
            (Self::Maintenance, AdminJobAuditStage::Failed) => "admin.maintenance_failed",
            (Self::Maintenance, AdminJobAuditStage::Interrupted) => "admin.maintenance_interrupted",
            (Self::Backup, AdminJobAuditStage::Requested) => "admin.backup_requested",
            (Self::Backup, AdminJobAuditStage::Started) => "admin.backup_started",
            (Self::Backup, AdminJobAuditStage::Completed) => "admin.backup_completed",
            (Self::Backup, AdminJobAuditStage::Failed) => "admin.backup_failed",
            (Self::Backup, AdminJobAuditStage::Interrupted) => "admin.backup_interrupted",
            (Self::Restore, AdminJobAuditStage::Requested) => "admin.restore_requested",
            (Self::Restore, AdminJobAuditStage::Started) => "admin.restore_started",
            (Self::Restore, AdminJobAuditStage::Completed) => "admin.restore_completed",
            (Self::Restore, AdminJobAuditStage::Failed) => "admin.restore_failed",
            (Self::Restore, AdminJobAuditStage::Interrupted) => "admin.restore_interrupted",
        }
    }

    fn failed_result_code(self) -> &'static str {
        match self {
            Self::Maintenance => "maintenance_failed",
            Self::Backup => "backup_failed",
            Self::Restore => "restore_failed",
        }
    }
}

#[derive(Debug, Clone, Copy)]
enum AdminJobAuditStage {
    Requested,
    Started,
    Completed,
    Failed,
    Interrupted,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateAdminAccountStatusRequest {
    status: AdminAccountStatus,
}

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum AdminAccountStatus {
    Active,
    Disabled,
}

impl AdminAccountStatus {
    fn as_str(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Disabled => "disabled",
        }
    }
}

pub(crate) async fn require_instance_admin_read_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    crate::require_active_session_device_read_tx(tx, user).await?;
    require_allowlisted_admin_tx(tx, state, &user.user_id).await
}

pub(crate) async fn require_instance_admin_write_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    crate::require_active_session_device_tx(tx, user).await?;
    require_allowlisted_admin_tx(tx, state, &user.user_id).await
}

#[derive(Clone, Copy)]
struct AdminMetricsValues {
    accounts_active: i64,
    accounts_deleting: i64,
    accounts_disabled: i64,
    devices_active: i64,
    vaults_active: i64,
    vaults_deleting: i64,
    stored_bytes: i64,
    reserved_upload_bytes: i64,
    object_delete_pending: i64,
    object_delete_retry_wait: i64,
    object_delete_quarantined: i64,
    vault_quota_bytes: i64,
    relay_enabled: bool,
    backup_last_success_timestamp_seconds: i64,
}

fn prometheus_metrics_response(values: AdminMetricsValues) -> Response {
    let metrics = format!(
        "# HELP atermius_accounts Current account rows by lifecycle status.\n\
    # TYPE atermius_accounts gauge\n\
    atermius_accounts{{status=\"active\"}} {}\n\
    atermius_accounts{{status=\"deleting\"}} {}\n\
    atermius_accounts{{status=\"disabled\"}} {}\n\
    # HELP atermius_devices_active Active devices belonging to active accounts.\n\
    # TYPE atermius_devices_active gauge\n\
    atermius_devices_active {}\n\
    # HELP atermius_vaults Current Vault rows by lifecycle state.\n\
    # TYPE atermius_vaults gauge\n\
    atermius_vaults{{state=\"active\"}} {}\n\
    atermius_vaults{{state=\"deleting\"}} {}\n\
    # HELP atermius_blob_stored_bytes Completed blob payload bytes retained by the instance.\n\
    # TYPE atermius_blob_stored_bytes gauge\n\
    atermius_blob_stored_bytes {}\n\
    # HELP atermius_upload_reserved_bytes Expected bytes in open unexpired upload reservations.\n\
    # TYPE atermius_upload_reserved_bytes gauge\n\
    atermius_upload_reserved_bytes {}\n\
    # HELP atermius_object_delete_queue Durable external object deletions by fixed queue state.\n\
    # TYPE atermius_object_delete_queue gauge\n\
    atermius_object_delete_queue{{state=\"pending\"}} {}\n\
    atermius_object_delete_queue{{state=\"retry_wait\"}} {}\n\
    atermius_object_delete_queue{{state=\"quarantined\"}} {}\n\
    # HELP atermius_vault_quota_bytes Configured quota bytes for active and deleting Vaults.\n\
    # TYPE atermius_vault_quota_bytes gauge\n\
    atermius_vault_quota_bytes {}\n\
    # HELP atermius_ssh_relay_enabled Whether SSH Relay is currently enabled by effective policy.\n\
    # TYPE atermius_ssh_relay_enabled gauge\n\
    atermius_ssh_relay_enabled {}\n",
        values.accounts_active,
        values.accounts_deleting,
        values.accounts_disabled,
        values.devices_active,
        values.vaults_active,
        values.vaults_deleting,
        values.stored_bytes,
        values.reserved_upload_bytes,
        values.object_delete_pending,
        values.object_delete_retry_wait,
        values.object_delete_quarantined,
        values.vault_quota_bytes,
        if values.relay_enabled { 1 } else { 0 },
    );
    let push_result_counts = crate::mobile_push::push_send_result_metric_counts();
    let mut metrics = format!(
        "{metrics}# HELP atermius_mobile_push_send_results_total Provider adapter send results observed by this process. accepted means the adapter returned success, not device receipt or sync; counters are per-serving-node and reset on process restart.\n# TYPE atermius_mobile_push_send_results_total counter\n"
    );
    for (provider_index, provider) in ["apns", "fcm_v1"].into_iter().enumerate() {
        for (outcome_index, outcome) in ["accepted", "invalid_token", "retryable_failure"]
            .into_iter()
            .enumerate()
        {
            metrics.push_str(&format!(
                "atermius_mobile_push_send_results_total{{provider=\"{provider}\",outcome=\"{outcome}\"}} {}\n",
                push_result_counts[provider_index][outcome_index],
            ));
        }
    }
    let metrics = format!(
        "{metrics}# HELP atermius_backup_last_success_timestamp_seconds Unix timestamp of the most recently recorded successful encrypted backup creation; 0 means none is recorded. This does not indicate off-host replication or restore verification.\n# TYPE atermius_backup_last_success_timestamp_seconds gauge\natermius_backup_last_success_timestamp_seconds {}\n",
        values.backup_last_success_timestamp_seconds,
    );
    (
        StatusCode::OK,
        [
            (
                header::CONTENT_TYPE,
                "text/plain; version=0.0.4; charset=utf-8",
            ),
            (header::CACHE_CONTROL, "no-store"),
            (header::X_CONTENT_TYPE_OPTIONS, "nosniff"),
        ],
        metrics,
    )
        .into_response()
}

fn pg_metrics_repository(
    state: &AppState,
) -> Result<crate::pg_admin_metrics::PgAdminMetricsRepository, ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL metrics repository is unavailable"))?;
    Ok(crate::pg_admin_metrics::PgAdminMetricsRepository::new(
        pool.clone(),
        state.auth_rate_key.clone(),
    ))
}

async fn postgres_metrics(state: &AppState, headers: &HeaderMap) -> Result<Response, ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL metrics pool is unavailable"))?;
    let repository = pg_metrics_repository(state)?;
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

    let scrape_credential = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .filter(|token| metrics_credential_token_is_valid(token));
    let scrape_authorized = if let Some(credential) = scrape_credential {
        repository.matches_tx(&mut tx, credential).await?
    } else {
        false
    };

    if !scrape_authorized {
        let user = auth::authenticate(state, headers).await?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
    }
    let snapshot = crate::pg_admin_metrics::snapshot_tx(state, &mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;

    Ok(prometheus_metrics_response(AdminMetricsValues {
        accounts_active: snapshot.accounts_active,
        accounts_deleting: snapshot.accounts_deleting,
        accounts_disabled: snapshot.accounts_disabled,
        devices_active: snapshot.devices_active,
        vaults_active: snapshot.vaults_active,
        vaults_deleting: snapshot.vaults_deleting,
        stored_bytes: snapshot.stored_bytes,
        reserved_upload_bytes: snapshot.reserved_upload_bytes,
        object_delete_pending: snapshot.object_delete_pending,
        object_delete_retry_wait: snapshot.object_delete_retry_wait,
        object_delete_quarantined: snapshot.object_delete_quarantined,
        vault_quota_bytes: snapshot.vault_quota_bytes,
        relay_enabled: snapshot.relay_enabled,
        backup_last_success_timestamp_seconds: snapshot.backup_last_success_timestamp_seconds,
    }))
}

async fn require_allowlisted_admin_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    user_id: &str,
) -> Result<(), ApiError> {
    let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(username) = username else {
        return Err(ApiError::unauthorized());
    };
    if !state.config.is_instance_admin(&username) {
        return Err(ApiError::forbidden(
            "INSTANCE_ADMIN_REQUIRED",
            "this account is not configured for instance administration",
        ));
    }
    Ok(())
}

async fn precheck_instance_admin(state: &AppState, user_id: &str) -> Result<(), ApiError> {
    let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let Some(username) = username else {
        return Err(ApiError::unauthorized());
    };
    if !state.config.is_instance_admin(&username) {
        return Err(ApiError::forbidden(
            "INSTANCE_ADMIN_REQUIRED",
            "this account is not configured for instance administration",
        ));
    }
    Ok(())
}

pub async fn overview(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        return crate::pg_admin_overview::overview(&state, &user).await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let now = now_rfc3339();
    let counts = sqlx::query(
        "SELECT \
         (SELECT COUNT(*) FROM users) AS accounts_total, \
         (SELECT COUNT(*) FROM users WHERE status='active') AS accounts_active, \
         (SELECT COUNT(*) FROM users WHERE status='deleting') AS accounts_deleting, \
         (SELECT COUNT(*) FROM users WHERE status='disabled') AS accounts_disabled, \
         (SELECT COUNT(*) FROM devices d JOIN users u ON u.user_id=d.user_id \
          WHERE d.status='active' AND u.status='active') AS devices_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='active') AS vaults_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='deleting') AS vaults_deleting, \
         (SELECT COALESCE(SUM(size),0) FROM blob_objects) AS stored_bytes, \
         (SELECT COALESCE(SUM(expected_size),0) FROM uploads \
          WHERE state='open' AND expires_at>?) AS reserved_upload_bytes, \
         (SELECT COALESCE(SUM(quota_bytes),0) FROM vaults \
          WHERE state IN ('active','deleting')) AS vault_quota_bytes",
    )
    .bind(&now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let relay = crate::relay::effective_policy_tx(&mut tx, &state).await?;
    let response = json!({
        "instance": {
            "instance_id": state.instance.instance_id.clone(),
            "server_space_id": state.instance.server_space_id.clone(),
            "generation": state.instance.generation.clone(),
            "protocol_version": 1,
        },
        "counts": {
            "accounts_total": counts.get::<i64, _>("accounts_total"),
            "accounts_active": counts.get::<i64, _>("accounts_active"),
            "accounts_deleting": counts.get::<i64, _>("accounts_deleting"),
            "accounts_disabled": counts.get::<i64, _>("accounts_disabled"),
            "devices_active": counts.get::<i64, _>("devices_active"),
            "vaults_active": counts.get::<i64, _>("vaults_active"),
            "vaults_deleting": counts.get::<i64, _>("vaults_deleting"),
            "stored_bytes": counts.get::<i64, _>("stored_bytes"),
            "reserved_upload_bytes": counts.get::<i64, _>("reserved_upload_bytes"),
            "vault_quota_bytes": counts.get::<i64, _>("vault_quota_bytes"),
        },
        "relay": {
            "enabled": relay.enabled,
            "allow_cidrs": relay.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
            "allow_ports": relay.allow_ports,
            "max_connections_per_user": state.config.relay_max_connections_per_user,
        },
        "database_encryption": state.database_encryption.as_str(),
        "generated_at": now,
    });
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct PushHealthCounts {
    pub(crate) registered_endpoints: i64,
    pub(crate) due: i64,
    pub(crate) retry_waiting: i64,
    pub(crate) leased: i64,
    pub(crate) dead_lettered: i64,
}

#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct PushDeliveryCounts {
    pub(crate) accepted: i64,
    pub(crate) invalid_token: i64,
    pub(crate) retryable_failure: i64,
}

#[derive(Debug, Clone)]
pub(crate) struct PushHealthWindow {
    pub(crate) start_date_utc: String,
    pub(crate) end_date_utc: String,
}

pub(crate) fn push_health_response(
    generated_at: String,
    delivery_window: PushHealthWindow,
    apns: PushHealthCounts,
    apns_delivery: PushDeliveryCounts,
    fcm_v1: PushHealthCounts,
    fcm_v1_delivery: PushDeliveryCounts,
) -> Json<Value> {
    let configured = crate::mobile_push::configured_provider();
    let provider = |name: &'static str,
                    kind: crate::mobile_push::PushProviderKind,
                    counts: PushHealthCounts,
                    delivery: PushDeliveryCounts| {
        json!({
            "provider": name,
            "configured": configured.as_ref().is_some_and(|provider| provider.supports(kind)),
            "registered_endpoints": counts.registered_endpoints,
            "due": counts.due,
            "retry_waiting": counts.retry_waiting,
            "leased": counts.leased,
            "dead_lettered": counts.dead_lettered,
            "delivery_results": {
                "accepted": delivery.accepted,
                "invalid_token": delivery.invalid_token,
                "retryable_failure": delivery.retryable_failure,
            },
        })
    };
    Json(json!({
        "generated_at": generated_at,
        "delivery_window": {
            "days": 7,
            "start_date_utc": delivery_window.start_date_utc,
            "end_date_utc": delivery_window.end_date_utc,
        },
        "providers": [
            provider("apns", crate::mobile_push::PushProviderKind::Apns, apns, apns_delivery),
            provider("fcm_v1", crate::mobile_push::PushProviderKind::FcmV1, fcm_v1, fcm_v1_delivery),
        ],
    }))
}

/// Returns a privacy-safe snapshot of the durable mobile push queue and
/// recent daily provider outcomes. The provider readiness flag describes only
/// this process's loaded adapter; queue and outcome counts are shared database
/// state and do not depend on that flag.
pub async fn push_health(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        return crate::pg_admin_push_health::push_health(&state, &user).await;
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let rows = sqlx::query(
        "WITH db_clock AS ( \
             SELECT CAST(strftime('%s','now') AS INTEGER) AS now, \
                    strftime('%Y-%m-%dT%H:%M:%fZ','now') AS generated_at \
         ), provider_keys(provider,sort_order) AS (VALUES ('apns',0),('fcm_v1',1)), \
         endpoint_counts AS ( \
             SELECT provider,COUNT(*) AS registered_endpoints \
             FROM notification_push_endpoints GROUP BY provider \
         ), queue_counts AS ( \
             SELECT e.provider, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND o.dead_lettered=0 \
                              AND o.next_attempt_at<=c.now \
                              AND (o.lease_until IS NULL OR o.lease_until<=c.now) \
                        THEN 1 ELSE 0 END) AS due, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND o.dead_lettered=0 \
                              AND o.lease_until>c.now THEN 1 ELSE 0 END) AS leased, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND o.dead_lettered=0 \
                              AND o.next_attempt_at>c.now THEN 1 ELSE 0 END) AS retry_waiting, \
               SUM(CASE WHEN o.requested_seq>o.delivered_seq AND o.dead_lettered=1 \
                        THEN 1 ELSE 0 END) AS dead_lettered \
             FROM notification_push_outbox o \
             JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id \
             CROSS JOIN db_clock c GROUP BY e.provider \
         ) \
         SELECT c.generated_at, \
                strftime('%Y-%m-%d',((c.now/86400)-6)*86400,'unixepoch') AS window_start_date, \
                strftime('%Y-%m-%d',(c.now/86400)*86400,'unixepoch') AS window_end_date, \
                c.now AS now_epoch,p.provider, \
                COALESCE(ec.registered_endpoints,0) AS registered_endpoints, \
                COALESCE(qc.due,0) AS due, \
                COALESCE(qc.retry_waiting,0) AS retry_waiting, \
                COALESCE(qc.leased,0) AS leased, \
                COALESCE(qc.dead_lettered,0) AS dead_lettered \
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
    let window_start_epoch = (first.get::<i64, _>("now_epoch").div_euclid(86_400) - 6) * 86_400;
    let window = PushHealthWindow {
        start_date_utc: first.get("window_start_date"),
        end_date_utc: first.get("window_end_date"),
    };
    let mut apns = PushHealthCounts::default();
    let mut fcm_v1 = PushHealthCounts::default();
    for row in rows {
        let counts = PushHealthCounts {
            registered_endpoints: row.get("registered_endpoints"),
            due: row.get("due"),
            retry_waiting: row.get("retry_waiting"),
            leased: row.get("leased"),
            dead_lettered: row.get("dead_lettered"),
        };
        match row.get::<String, _>("provider").as_str() {
            "apns" => apns = counts,
            "fcm_v1" => fcm_v1 = counts,
            _ => return Err(ApiError::internal("push health provider key is invalid")),
        }
    }
    let delivery_rows = sqlx::query(
        "SELECT provider,outcome,SUM(count) AS total \
         FROM notification_push_delivery_daily \
         WHERE day_start>=? AND day_start<=? GROUP BY provider,outcome",
    )
    .bind(window_start_epoch)
    .bind(window_start_epoch + 6 * 86_400)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut apns_delivery = PushDeliveryCounts::default();
    let mut fcm_v1_delivery = PushDeliveryCounts::default();
    for row in delivery_rows {
        let provider = row.get::<String, _>("provider");
        let outcome = row.get::<String, _>("outcome");
        let counts = match provider.as_str() {
            "apns" => &mut apns_delivery,
            "fcm_v1" => &mut fcm_v1_delivery,
            _ => return Err(ApiError::internal("push health provider key is invalid")),
        };
        let total = row.get("total");
        match outcome.as_str() {
            "accepted" => counts.accepted = total,
            "invalid_token" => counts.invalid_token = total,
            "retryable_failure" => counts.retryable_failure = total,
            _ => return Err(ApiError::internal("push health outcome key is invalid")),
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(push_health_response(
        generated_at,
        window,
        apns,
        apns_delivery,
        fcm_v1,
        fcm_v1_delivery,
    ))
}

/// Prometheus text exposition for operators. This is deliberately restricted
/// to fixed, low-cardinality aggregate series. Access requires either the
/// existing active administrator session or the route-specific scrape token.
pub async fn metrics(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    if state.pg_sync_only {
        return postgres_metrics(&state, &headers).await;
    }
    // Keep the existing interactive-admin session path and allowlist check.
    // The separate scrape credential is recognized only by this handler.
    let scrape_credential = metrics_credential_matches(&state, &headers).await?;
    let user = if scrape_credential {
        None
    } else {
        Some(auth::authenticate(&state, &headers).await?)
    };
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    if let Some(user) = user {
        require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    }
    let now = now_rfc3339();
    let counts = sqlx::query(
        "SELECT \
         (SELECT COUNT(*) FROM users) AS accounts_total, \
         (SELECT COUNT(*) FROM users WHERE status='active') AS accounts_active, \
         (SELECT COUNT(*) FROM users WHERE status='deleting') AS accounts_deleting, \
         (SELECT COUNT(*) FROM users WHERE status='disabled') AS accounts_disabled, \
         (SELECT COUNT(*) FROM devices d JOIN users u ON u.user_id=d.user_id \
          WHERE d.status='active' AND u.status='active') AS devices_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='active') AS vaults_active, \
         (SELECT COUNT(*) FROM vaults WHERE state='deleting') AS vaults_deleting, \
         (SELECT COALESCE(SUM(size),0) FROM blob_objects) AS stored_bytes, \
         (SELECT COALESCE(SUM(expected_size),0) FROM uploads \
          WHERE state='open' AND expires_at>?) AS reserved_upload_bytes, \
         (SELECT COALESCE(SUM(quota_bytes),0) FROM vaults \
          WHERE state IN ('active','deleting')) AS vault_quota_bytes, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='pending') AS object_delete_pending, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='retry_wait') AS object_delete_retry_wait, \
         (SELECT COUNT(*) FROM object_delete_queue WHERE state='quarantined') AS object_delete_quarantined",
    )
    .bind(&now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let relay = crate::relay::effective_policy_tx(&mut tx, &state).await?;
    tx.commit().await.map_err(ApiError::internal)?;

    let value = |name: &str| counts.get::<i64, _>(name);
    let backup_last_success =
        crate::backup_status::last_success_timestamp_seconds(&state.config.data_dir)?.unwrap_or(0);
    Ok(prometheus_metrics_response(AdminMetricsValues {
        accounts_active: value("accounts_active"),
        accounts_deleting: value("accounts_deleting"),
        accounts_disabled: value("accounts_disabled"),
        devices_active: value("devices_active"),
        vaults_active: value("vaults_active"),
        vaults_deleting: value("vaults_deleting"),
        stored_bytes: value("stored_bytes"),
        reserved_upload_bytes: value("reserved_upload_bytes"),
        object_delete_pending: value("object_delete_pending"),
        object_delete_retry_wait: value("object_delete_retry_wait"),
        object_delete_quarantined: value("object_delete_quarantined"),
        vault_quota_bytes: value("vault_quota_bytes"),
        relay_enabled: relay.enabled,
        backup_last_success_timestamp_seconds: backup_last_success,
    }))
}

/// Returns scrape credential state without exposing its secret or verifier.
pub async fn metrics_credential_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL metrics pool is unavailable"))?;
        let repository = pg_metrics_repository(&state)?;
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            &state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
        let updated_at = repository.status_tx(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        let updated_at =
            updated_at.map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
        return Ok(Json(json!({
            "active": updated_at.is_some(),
            "updated_at": updated_at,
        })));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let row =
        sqlx::query("SELECT updated_at FROM instance_metrics_credential WHERE credential_id=1")
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let updated_at = row.map(|row| row.get::<String, _>("updated_at"));
    Ok(Json(json!({
        "active": updated_at.is_some(),
        "updated_at": updated_at,
    })))
}

/// Creates or rotates the scrape credential. The plaintext secret is returned
/// only by this response and can subsequently be supplied as an HTTP bearer
/// credential to GET /api/v1/admin/metrics.
pub async fn rotate_metrics_credential(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    require_empty_metrics_credential_body(body).await?;
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL metrics pool is unavailable"))?;
        let repository = pg_metrics_repository(&state)?;
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            &state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
        let (credential, created_at) = repository.rotate_tx(&mut tx).await?;
        audit::record_instance_admin_event_pg_tx(
            &mut tx,
            &state,
            &user,
            "admin.metrics_credential_rotated",
            "metrics_credential",
            None,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(json!({
            "credential": credential,
            "created_at": created_at
                .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        })));
    }
    let mut credential_bytes = [0_u8; METRICS_CREDENTIAL_BYTES];
    rand::rngs::OsRng.fill_bytes(&mut credential_bytes);
    let credential = format!(
        "{METRICS_CREDENTIAL_PREFIX}{}",
        URL_SAFE_NO_PAD.encode(credential_bytes)
    );
    credential_bytes.fill(0);
    let verifier = metrics_credential_verifier(&state, &credential)?;
    let now = now_rfc3339();

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    sqlx::query(
        "INSERT INTO instance_metrics_credential(credential_id,verifier,created_at,updated_at) \
         VALUES(1,?,?,?) ON CONFLICT(credential_id) DO UPDATE SET \
         verifier=excluded.verifier,created_at=excluded.created_at,updated_at=excluded.updated_at",
    )
    .bind(verifier.as_slice())
    .bind(&now)
    .bind(&now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "admin.metrics_credential_rotated",
        "metrics_credential",
        None,
        chrono::Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;

    Ok(Json(json!({
        "credential": credential,
        "created_at": now,
    })))
}

/// Revokes the current scrape credential. Repeating the operation is an
/// idempotent success and does not create duplicate audit events.
pub async fn revoke_metrics_credential(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Body,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    require_empty_metrics_credential_body(body).await?;
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL metrics pool is unavailable"))?;
        let repository = pg_metrics_repository(&state)?;
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            &state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
        let changed = repository.revoke_tx(&mut tx).await?;
        if changed {
            audit::record_instance_admin_event_pg_tx(
                &mut tx,
                &state,
                &user,
                "admin.metrics_credential_revoked",
                "metrics_credential",
                None,
            )
            .await?;
        }
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(json!({ "revoked": true })));
    }
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let changed = sqlx::query("DELETE FROM instance_metrics_credential WHERE credential_id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .rows_affected();
    if changed > 0 {
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "admin.metrics_credential_revoked",
            "metrics_credential",
            None,
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({ "revoked": true })))
}

async fn require_empty_metrics_credential_body(body: Body) -> Result<(), ApiError> {
    let bytes = to_bytes(body, 1).await.map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "request body must be empty",
        )
    })?;
    if !bytes.is_empty() {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "request body must be empty",
        ));
    }
    Ok(())
}

async fn metrics_credential_matches(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<bool, ApiError> {
    let Some(token) = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
    else {
        return Ok(false);
    };
    if !metrics_credential_token_is_valid(token) {
        return Ok(false);
    }
    let row = sqlx::query("SELECT verifier FROM instance_metrics_credential WHERE credential_id=1")
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(false);
    };
    let expected: Vec<u8> = row.get("verifier");
    metrics_credential_verifier_matches(state.auth_rate_key.as_ref(), token, &expected)
}

fn metrics_credential_verifier(state: &AppState, credential: &str) -> Result<[u8; 32], ApiError> {
    metrics_credential_verifier_for_key(state.auth_rate_key.as_ref(), credential)
}

/// Validates the canonical text encoding without returning or logging the
/// decoded bearer bytes. Shared with the PostgreSQL credential repository.
pub(crate) fn metrics_credential_token_is_valid(token: &str) -> bool {
    token.starts_with(METRICS_CREDENTIAL_PREFIX)
        && token.len() == METRICS_CREDENTIAL_PREFIX.len() + 43
        && URL_SAFE_NO_PAD
            .decode(&token[METRICS_CREDENTIAL_PREFIX.len()..])
            .is_ok()
}

/// Computes the server-keyed verifier for the established scrape token
/// domain. Shared with the PostgreSQL credential repository.
pub(crate) fn metrics_credential_verifier_for_key(
    auth_rate_key: &[u8; 32],
    credential: &str,
) -> Result<[u8; 32], ApiError> {
    let mut mac =
        HmacSha256::new_from_slice(auth_rate_key.as_slice()).map_err(ApiError::internal)?;
    mac.update(METRICS_CREDENTIAL_DOMAIN);
    mac.update(credential.as_bytes());
    Ok(mac.finalize().into_bytes().into())
}

/// Checks a stored verifier using HMAC's constant-time tag comparison.
pub(crate) fn metrics_credential_verifier_matches(
    auth_rate_key: &[u8; 32],
    credential: &str,
    expected: &[u8],
) -> Result<bool, ApiError> {
    let mut mac =
        HmacSha256::new_from_slice(auth_rate_key.as_slice()).map_err(ApiError::internal)?;
    mac.update(METRICS_CREDENTIAL_DOMAIN);
    mac.update(credential.as_bytes());
    Ok(mac.verify_slice(expected).is_ok())
}

pub async fn backup_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_jobs::backup_status(&state, &user, &state.config.admin_usernames)
                .await?,
        ));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let response = serde_json::to_value(crate::backup_status::read_status(&state.config.data_dir)?)
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn backup_replication_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        let pool = state.pg_sync_pool.as_ref().ok_or_else(|| {
            ApiError::internal("PostgreSQL backup replication pool is unavailable")
        })?;
        let repository =
            crate::pg_backup_replication::PgBackupReplicationRepository::new(pool.clone());
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            &state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
        let snapshot = repository.snapshot_tx(&mut tx).await?;
        let status = crate::backup_replication::status_from_pg(&state.config, snapshot);
        tx.commit().await.map_err(ApiError::internal)?;
        return serde_json::to_value(status)
            .map(Json)
            .map_err(ApiError::internal);
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    let status = crate::backup_replication::status(&state).await?;
    serde_json::to_value(status)
        .map(Json)
        .map_err(ApiError::internal)
}

pub(crate) async fn backup_replication_preflight(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<BackupReplicationPreflightRequest>, JsonRejection>,
) -> Result<Json<crate::backup_replication::ReplicaPreflightStatus>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(_request) = request.map_err(|_| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "INVALID_BACKUP_REPLICATION_PREFLIGHT_REQUEST",
            "request body must be an empty JSON object",
        )
    })?;

    // Complete the instance-admin check before starting provider network I/O;
    // the bucket request must never hold a database transaction open.
    if state.pg_sync_only {
        let pool = state.pg_sync_pool.as_ref().ok_or_else(|| {
            ApiError::internal("PostgreSQL backup replication pool is unavailable")
        })?;
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        crate::pg_admin_jobs::require_instance_admin_tx(
            &mut tx,
            &state,
            &user,
            &state.config.admin_usernames,
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
    } else {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        require_instance_admin_read_tx(&mut tx, &state, &user).await?;
        tx.commit().await.map_err(ApiError::internal)?;
    }

    crate::backup_replication::preflight_bucket_access(&state.config)
        .await
        .map(Json)
}

pub async fn get_backup_schedule(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_jobs::get_backup_schedule(&state, &user, &state.config.admin_usernames)
                .await?,
        ));
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let response = backup_schedule_response(&state, &mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub async fn update_backup_schedule(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<Value>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(body) = request.map_err(|_| invalid_backup_schedule_request())?;
    let interval_hours = parse_backup_schedule_request(&body)?;

    if state.pg_sync_only {
        let response = crate::pg_admin_jobs::update_backup_schedule(
            &state,
            &user,
            &state.config.admin_usernames,
            interval_hours,
        )
        .await?;
        return Ok(Json(response));
    }

    precheck_instance_admin(&state, &user.user_id).await?;
    if interval_hours.is_some() && crate::backup::configured_backup_paths(&state.config).is_err() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "BACKUP_NOT_CONFIGURED",
            "server-side encrypted backup is not configured",
        ));
    }

    // Do not await the process or OS lock while holding SQLite's writer. The
    // second authorization check below is performed after lock acquisition.
    let _maintenance_guard = crate::acquire_instance_maintenance_lock(&state).await?;
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    if interval_hours.is_some() && crate::backup::configured_backup_paths(&state.config).is_err() {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "BACKUP_NOT_CONFIGURED",
            "server-side encrypted backup is not configured",
        ));
    }
    let current: Option<i64> = sqlx::query_scalar(
        "SELECT interval_hours FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if current != interval_hours {
        let next_run_at = match interval_hours {
            Some(hours) => {
                let seconds = crate::backup::backup_interval_seconds(hours)?;
                Some(
                    chrono::Utc::now()
                        .timestamp()
                        .checked_add(seconds)
                        .ok_or_else(|| ApiError::internal("backup schedule due time overflowed"))?,
                )
            }
            None => None,
        };
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=?,next_run_at=? WHERE schedule_id=1",
        )
        .bind(interval_hours)
        .bind(next_run_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }
    // This event always has a real authenticated administrator and device.
    // Scheduled run records themselves use no fabricated actor identity.
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "admin.backup_schedule_updated",
        "backup_schedule",
        None,
        chrono::Utc::now().timestamp(),
    )
    .await?;
    let response = backup_schedule_response(&state, &mut tx).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

fn invalid_backup_schedule_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_BACKUP_SCHEDULE_REQUEST",
        "body must contain only interval_hours as an integer or null",
    )
}

fn parse_backup_schedule_request(body: &Value) -> Result<Option<i64>, ApiError> {
    let Some(object) = body.as_object() else {
        return Err(invalid_backup_schedule_request());
    };
    if object.len() != 1 {
        return Err(invalid_backup_schedule_request());
    }
    let Some(value) = object.get("interval_hours") else {
        return Err(invalid_backup_schedule_request());
    };
    let interval_hours = if value.is_null() {
        None
    } else {
        let Some(hours) = value.as_i64() else {
            return Err(invalid_backup_schedule_request());
        };
        if !(MIN_BACKUP_INTERVAL_HOURS..=MAX_BACKUP_INTERVAL_HOURS).contains(&hours) {
            return Err(ApiError::bad_request(
                "INVALID_BACKUP_INTERVAL",
                "interval_hours must be between 1 and 720",
            ));
        }
        Some(hours)
    };
    Ok(interval_hours)
}

async fn backup_schedule_response(
    state: &AppState,
    tx: &mut Transaction<'_, Sqlite>,
) -> Result<Value, ApiError> {
    let schedule = sqlx::query(
        "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let interval_hours: Option<i64> = schedule.get("interval_hours");
    let next_run_at: Option<i64> = schedule.get("next_run_at");
    if interval_hours.is_some() != next_run_at.is_some() {
        return Err(ApiError::internal("backup schedule state is inconsistent"));
    }
    let next_run_at = next_run_at.map(backup_schedule_timestamp).transpose()?;

    let last_run = sqlx::query(
        "SELECT run_id,scheduled_for,started_at,finished_at,status,result_code,\
         migration_version,archive_bytes FROM instance_scheduled_backup_runs \
         ORDER BY scheduled_for DESC,run_id DESC LIMIT 1",
    )
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .map(|row| {
        let scheduled_for: i64 = row.get("scheduled_for");
        let started_at: i64 = row.get("started_at");
        let finished_at: Option<i64> = row.get("finished_at");
        Ok(json!({
            "run_id": row.get::<String, _>("run_id"),
            "scheduled_for": backup_schedule_timestamp(scheduled_for)?,
            "started_at": backup_schedule_timestamp(started_at)?,
            "finished_at": finished_at.map(backup_schedule_timestamp).transpose()?,
            "status": row.get::<String, _>("status"),
            "result_code": row.get::<Option<String>, _>("result_code"),
            "migration_version": row.get::<Option<i64>, _>("migration_version"),
            "archive_bytes": row.get::<Option<i64>, _>("archive_bytes"),
        }))
    })
    .transpose()?;

    Ok(json!({
        "operation": "backup_schedule",
        "backup_configured": crate::backup::configured_backup_paths(&state.config).is_ok(),
        "interval_hours": interval_hours,
        "next_run_at": next_run_at,
        "last_run": last_run,
    }))
}

fn backup_schedule_timestamp(epoch_seconds: i64) -> Result<String, ApiError> {
    chrono::DateTime::<chrono::Utc>::from_timestamp(epoch_seconds, 0)
        .map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        .ok_or_else(|| ApiError::internal("backup schedule timestamp is invalid"))
}

pub async fn list_jobs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminJobListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_ADMIN_JOB_PAGE_SIZE,
        1,
        MAX_ADMIN_JOB_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_ADMIN_JOB_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_jobs::list_jobs(
                &state,
                &user,
                &state.config.admin_usernames,
                i64::from(limit),
                i64::from(offset),
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_admin_jobs")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT j.job_id,j.request_id,j.action,j.archive_id,j.archive_source,j.status, \
            j.requested_at,j.started_at,j.finished_at,j.result_code, \
            CASE WHEN j.requested_by_user_id=? AND j.action='restore' AND j.status='succeeded' \
                 THEN COALESCE(s.status,'unverified') ELSE NULL END AS restore_stage_status \
         FROM instance_admin_jobs j LEFT JOIN instance_admin_restore_stages s ON s.restore_job_id=j.job_id \
         ORDER BY j.requested_at DESC,j.job_id DESC LIMIT ? OFFSET ?",
    )
    .bind(&user.user_id)
    .bind(i64::from(limit))
    .bind(i64::from(offset))
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let jobs: Vec<Value> = rows.iter().map(admin_job_dto).collect();
    tx.commit().await.map_err(ApiError::internal)?;
    let mut supported_actions = vec![
        "maintenance",
        "backup",
        "restore",
        "backup_status",
        "backup_replication",
        "backup_schedule",
        "restore_stage_discard",
    ];
    if crate::backup_replication::settings_configured(&state.config) {
        supported_actions.push("restore_replica");
    }
    Ok(Json(json!({
        "jobs": jobs,
        "total": total,
        "supported_actions": supported_actions,
    })))
}

pub async fn list_restore_sources(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminJobListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_ADMIN_JOB_PAGE_SIZE,
        1,
        MAX_ADMIN_JOB_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_ADMIN_JOB_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;
    if state.pg_sync_only {
        crate::pg_admin_jobs::ensure_instance_admin(&state, &user, &state.config.admin_usernames)
            .await?;
    } else {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        require_instance_admin_read_tx(&mut tx, &state, &user).await?;
        tx.commit().await.map_err(ApiError::internal)?;
    }

    let settings = crate::backup::configured_backup_paths(&state.config)
        .map_err(|_| backup_not_configured_error())?;
    let sources =
        crate::backup::list_server_generated_restore_sources_with_settings(&state, &settings)
            .await?;
    let total = sources.len();
    let sources = sources
        .into_iter()
        .skip(offset as usize)
        .take(limit as usize)
        .map(|source| {
            json!({
                "archive_id": source.archive_id,
                "created_at": source.created_at,
                "archive_bytes": source.archive_bytes,
                "origin": source.origin,
                "source": source.source,
            })
        })
        .collect::<Vec<_>>();
    Ok(Json(json!({"sources": sources, "total": total})))
}

pub async fn discard_restore_stage(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(restore_job_id): Path<String>,
    request: Result<Json<DiscardRestoreStageRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    if state.pg_sync_only {
        return crate::pg_admin_jobs::discard_restore_stage(
            state,
            headers,
            restore_job_id,
            request,
        )
        .await;
    }
    let user = auth::authenticate(&state, &headers).await?;
    validate_restore_job_id(&restore_job_id)?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_RESTORE_STAGE_DISCARD_REQUEST",
            "request body must contain only a canonical request_id",
        )
    })?;
    let _request_id = validate_admin_job_request_id(&request.request_id)?;
    precheck_instance_admin(&state, &user.user_id).await?;

    let _maintenance_guard = crate::acquire_instance_maintenance_lock(&state).await?;
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let Some(job) = sqlx::query(
        "SELECT requested_by_user_id,action,archive_id,archive_source,archive_sha256,status,result_code \
         FROM instance_admin_jobs WHERE job_id=?",
    )
    .bind(&restore_job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    else {
        return Err(ApiError::not_found());
    };
    if job.get::<String, _>("requested_by_user_id") != user.user_id
        || job.get::<String, _>("action") != "restore"
    {
        return Err(ApiError::not_found());
    }
    if job.get::<String, _>("status") != "succeeded"
        || job.get::<Option<String>, _>("result_code").as_deref() != Some("completed")
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "the requested restore stage is not ready to discard",
        ));
    }
    let archive_id: String = job
        .get::<Option<String>, _>("archive_id")
        .ok_or_else(|| ApiError::internal("completed restore job has no archive id"))?;
    let archive_source = crate::backup_replication::ArchiveSource::parse(
        job.get::<String, _>("archive_source").as_str(),
    )?;
    let archive_sha256: String = job
        .get::<Option<String>, _>("archive_sha256")
        .ok_or_else(|| ApiError::internal("completed restore job has no archive digest"))?;

    let lifecycle = sqlx::query(
        "SELECT generation,status,discarded_at FROM instance_admin_restore_stages WHERE restore_job_id=?",
    )
    .bind(&restore_job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if let Some(row) = lifecycle.as_ref()
        && row.get::<String, _>("status") == "discarded"
    {
        let discarded_at: String = row
            .get::<Option<String>, _>("discarded_at")
            .ok_or_else(|| ApiError::internal("discarded restore stage has no timestamp"))?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(restore_stage_discard_receipt(
            &restore_job_id,
            &discarded_at,
        )));
    }

    crate::backup::configured_backup_paths(&state.config)
        .map_err(|_| backup_not_configured_error())?;
    let lifecycle_status = lifecycle.as_ref().map(|row| row.get::<String, _>("status"));
    let lifecycle_generation = lifecycle
        .as_ref()
        .map(|row| row.get::<String, _>("generation"));
    let is_resuming = lifecycle_status.as_deref() == Some("discarding");
    let generation = crate::backup::validate_admin_restore_stage_for_discard(
        &state,
        &restore_job_id,
        &archive_id,
        archive_source,
        &archive_sha256,
        lifecycle_generation.as_deref(),
        is_resuming,
    )
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the prepared restore copy cannot be safely discarded",
        )
    })?;
    if let Some(expected) = lifecycle_generation.as_deref()
        && generation != expected
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the prepared restore copy cannot be safely discarded",
        ));
    }

    match lifecycle_status.as_deref() {
        None => {
            sqlx::query(
                "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
                 VALUES(?,?,'ready',?)",
            )
            .bind(&restore_job_id)
            .bind(&generation)
            .bind(now_rfc3339())
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query(
                "UPDATE instance_admin_restore_stages SET status='discarding', \
                    discard_requested_by_user_id=?,discard_requested_by_device_id=? \
                 WHERE restore_job_id=? AND status='ready'",
            )
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(&restore_job_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        Some("ready") => {
            sqlx::query(
                "UPDATE instance_admin_restore_stages SET status='discarding', \
                    discard_requested_by_user_id=?,discard_requested_by_device_id=? \
                 WHERE restore_job_id=? AND status='ready'",
            )
            .bind(&user.user_id)
            .bind(&user.device_id)
            .bind(&restore_job_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        Some("discarding") => {}
        Some("discarded") => unreachable!("discarded stages returned above"),
        Some(_) => return Err(ApiError::internal("restore stage lifecycle is invalid")),
    }
    tx.commit().await.map_err(ApiError::internal)?;

    crate::backup::discard_admin_restore_stage_files(
        &state,
        &restore_job_id,
        &archive_id,
        archive_source,
        &archive_sha256,
        &generation,
    )
    .await
    .map_err(|_| {
        ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "RESTORE_STAGE_DISCARD_FAILED",
            "the prepared restore copy could not be discarded; retry the request",
        )
    })?;

    let committed_at = finish_restore_stage_discard(&state, &restore_job_id).await?;
    Ok(Json(restore_stage_discard_receipt(
        &restore_job_id,
        &committed_at,
    )))
}

async fn finish_restore_stage_discard(
    state: &AppState,
    restore_job_id: &str,
) -> Result<String, ApiError> {
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT status,discard_requested_by_user_id,discard_requested_by_device_id,discarded_at \
         FROM instance_admin_restore_stages WHERE restore_job_id=?",
    )
    .bind(restore_job_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("restore stage lifecycle is missing"))?;
    if row.get::<String, _>("status") == "discarded" {
        let discarded_at: String = row
            .get::<Option<String>, _>("discarded_at")
            .ok_or_else(|| ApiError::internal("discarded restore stage has no timestamp"))?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(discarded_at);
    }
    if row.get::<String, _>("status") != "discarding" {
        return Err(ApiError::internal("restore stage discard was not prepared"));
    }
    let actor_user_id: String = row
        .get::<Option<String>, _>("discard_requested_by_user_id")
        .ok_or_else(|| ApiError::internal("restore stage discard actor is missing"))?;
    let actor_device_id: String = row
        .get::<Option<String>, _>("discard_requested_by_device_id")
        .ok_or_else(|| ApiError::internal("restore stage discard device is missing"))?;
    let discarded_at = now_rfc3339();
    let changed = sqlx::query(
        "UPDATE instance_admin_restore_stages SET status='discarded',discarded_at=? \
         WHERE restore_job_id=? AND status='discarding'",
    )
    .bind(&discarded_at)
    .bind(restore_job_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    if changed == 1 {
        audit::record_instance_admin_event_tx(
            &mut tx,
            state,
            &actor_user_id,
            &actor_device_id,
            "admin.restore_stage_discarded",
            "admin_job",
            Some(restore_job_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(discarded_at)
}

fn restore_stage_discard_receipt(restore_job_id: &str, discarded_at: &str) -> Value {
    json!({
        "restore_stage": {
            "restore_job_id": restore_job_id,
            "status": "discarded",
            "discarded_at": discarded_at,
        }
    })
}

pub async fn create_job(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<CreateAdminJobRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_JOB_REQUEST",
            "request body must contain a canonical request_id and supported action",
        )
    })?;
    let request_id = validate_admin_job_request_id(&request.request_id)?;
    let action = request.action.as_str();
    let (archive_id, archive_source) =
        validate_action_archive(request.action, &request.archive_id, &request.archive_source)?;
    let stored_archive_source = archive_source
        .map(crate::backup_replication::ArchiveSource::as_str)
        .unwrap_or("local");

    if state.pg_sync_only {
        if request.action == AdminJobAction::Maintenance {
            let (status, body) = crate::pg_admin_jobs::create_maintenance_job(
                &state,
                &user,
                &state.config.admin_usernames,
                &request_id,
            )
            .await?;
            return Ok((status, Json(body)));
        }
        let (status, body) = crate::pg_admin_jobs::create_action_job(
            &state,
            &user,
            &state.config.admin_usernames,
            &request_id,
            action,
            archive_id.as_deref(),
            archive_source,
        )
        .await?;
        return Ok((status, Json(body)));
    }

    // Avoid acquiring SQLite's global writer for ordinary authenticated users,
    // then recheck account, device, session and allowlist under the writer.
    precheck_instance_admin(&state, &user.user_id).await?;

    // Preserve idempotent retries even if retention has since removed a
    // completed source, while keeping filesystem catalog work outside the
    // global SQLite writer transaction.
    let mut preflight_tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut preflight_tx, &state, &user).await?;
    let existing = sqlx::query(
        "SELECT j.job_id,j.request_id,j.action,j.archive_id,j.archive_source,j.status,j.requested_at, \
            j.started_at,j.finished_at,j.result_code,j.requested_by_user_id, \
            CASE WHEN j.action='restore' AND j.status='succeeded' \
                 THEN COALESCE(s.status,'unverified') ELSE NULL END AS restore_stage_status \
         FROM instance_admin_jobs j LEFT JOIN instance_admin_restore_stages s ON s.restore_job_id=j.job_id \
         WHERE j.request_id=?",
    )
    .bind(&request_id)
    .fetch_optional(&mut *preflight_tx)
    .await
    .map_err(ApiError::internal)?;
    if let Some(existing) = existing {
        if existing.get::<String, _>("requested_by_user_id") != user.user_id
            || existing.get::<String, _>("action") != action
            || existing.get::<Option<String>, _>("archive_id") != archive_id
            || existing.get::<String, _>("archive_source") != stored_archive_source
        {
            return Err(ApiError::conflict(
                "JOB_REQUEST_ID_CONFLICT",
                "request_id is already associated with a different job request",
            ));
        }
        let job = admin_job_dto(&existing);
        let queued = existing.get::<String, _>("status") == "queued";
        preflight_tx.commit().await.map_err(ApiError::internal)?;
        if queued {
            spawn_admin_job(state, job["job_id"].as_str().unwrap_or_default());
        }
        return Ok((StatusCode::ACCEPTED, Json(json!({"job": job}))));
    }
    preflight_tx.commit().await.map_err(ApiError::internal)?;

    if request.action == AdminJobAction::Restore {
        let settings = crate::backup::configured_backup_paths(&state.config)
            .map_err(|_| backup_not_configured_error())?;
        let archive_id = archive_id.as_deref().unwrap_or_default();
        let source = archive_source.ok_or_else(invalid_admin_job_request)?;
        if !crate::backup::server_generated_restore_source_exists(
            &state, archive_id, source, &settings,
        )
        .await?
        {
            return Err(ApiError::conflict(
                "RESTORE_SOURCE_UNAVAILABLE",
                "the selected server backup is unavailable for restore",
            ));
        }
    }

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;

    if let Some(existing) = sqlx::query(
        "SELECT j.job_id,j.request_id,j.action,j.archive_id,j.archive_source,j.status,j.requested_at, \
            j.started_at,j.finished_at,j.result_code,j.requested_by_user_id, \
            CASE WHEN j.action='restore' AND j.status='succeeded' \
                 THEN COALESCE(s.status,'unverified') ELSE NULL END AS restore_stage_status \
         FROM instance_admin_jobs j LEFT JOIN instance_admin_restore_stages s ON s.restore_job_id=j.job_id \
         WHERE j.request_id=?",
    )
    .bind(&request_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    {
        if existing.get::<String, _>("requested_by_user_id") != user.user_id
            || existing.get::<String, _>("action") != action
            || existing.get::<Option<String>, _>("archive_id") != archive_id
            || existing.get::<String, _>("archive_source") != stored_archive_source
        {
            return Err(ApiError::conflict(
                "JOB_REQUEST_ID_CONFLICT",
                "request_id is already associated with a different job request",
            ));
        }
        let job = admin_job_dto(&existing);
        let queued = existing.get::<String, _>("status") == "queued";
        tx.commit().await.map_err(ApiError::internal)?;
        if queued {
            spawn_admin_job(state, job["job_id"].as_str().unwrap_or_default());
        }
        return Ok((StatusCode::ACCEPTED, Json(json!({"job": job}))));
    }

    if request.action == AdminJobAction::Backup
        && crate::backup::configured_backup_paths(&state.config).is_err()
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "BACKUP_NOT_CONFIGURED",
            "server-side encrypted backup is not configured",
        ));
    }

    let already_active: Option<String> = sqlx::query_scalar(
        "SELECT job_id FROM instance_admin_jobs WHERE status IN ('queued','running') LIMIT 1",
    )
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if already_active.is_some() {
        return Err(ApiError::conflict(
            "MAINTENANCE_ALREADY_RUNNING",
            "an instance-admin job is already queued or running",
        ));
    }

    let job_id = Uuid::new_v4().to_string();
    let requested_at = now_rfc3339();
    let now_epoch = chrono::Utc::now().timestamp();
    sqlx::query(
        "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,requested_by_device_id,action,archive_id,archive_source,status,requested_at) \
         VALUES(?,?,?,?,?,?,?,'queued',?)",
    )
    .bind(&job_id)
    .bind(&request_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(action)
    .bind(&archive_id)
    .bind(stored_archive_source)
    .bind(&requested_at)
    .execute(&mut *tx)
    .await
    .map_err(|error| {
        if error
            .as_database_error()
            .is_some_and(|database_error| database_error.is_unique_violation())
        {
            ApiError::conflict(
                "MAINTENANCE_ALREADY_RUNNING",
                "an instance-admin job is already queued or running",
            )
        } else {
            ApiError::internal(error)
        }
    })?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        request.action.event(AdminJobAuditStage::Requested),
        "admin_job",
        Some(&job_id),
        now_epoch,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;

    let job = json!({
        "job_id": job_id,
        "request_id": request_id,
        "action": action,
        "status": "queued",
        "requested_at": requested_at,
        "started_at": Value::Null,
        "finished_at": Value::Null,
        "result_code": Value::Null,
        "archive_id": archive_id,
        "archive_source": archive_source.map(|source| source.as_str()),
        "restore_stage_status": Value::Null,
    });
    spawn_admin_job(state, &job_id);
    Ok((StatusCode::ACCEPTED, Json(json!({"job": job}))))
}

fn admin_job_dto(row: &sqlx::sqlite::SqliteRow) -> Value {
    json!({
        "job_id": row.get::<String, _>("job_id"),
        "request_id": row.get::<String, _>("request_id"),
        "action": row.get::<String, _>("action"),
        "archive_id": row.get::<Option<String>, _>("archive_id"),
        "archive_source": if row.get::<String, _>("action") == "restore" {
            Some(row.get::<String, _>("archive_source"))
        } else {
            None::<String>
        },
        "status": row.get::<String, _>("status"),
        "requested_at": row.get::<String, _>("requested_at"),
        "started_at": row.get::<Option<String>, _>("started_at"),
        "finished_at": row.get::<Option<String>, _>("finished_at"),
        "result_code": row.get::<Option<String>, _>("result_code"),
        "restore_stage_status": row
            .try_get::<Option<String>, _>("restore_stage_status")
            .unwrap_or(None),
    })
}

fn invalid_admin_job_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_JOB_REQUEST",
        "request body does not match a supported administrator job action",
    )
}

fn backup_not_configured_error() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "BACKUP_NOT_CONFIGURED",
        "server-side encrypted backup is not configured",
    )
}

fn validate_action_archive(
    action: AdminJobAction,
    archive_id: &ArchiveIdField,
    archive_source: &ArchiveSourceField,
) -> Result<
    (
        Option<String>,
        Option<crate::backup_replication::ArchiveSource>,
    ),
    ApiError,
> {
    match (action, archive_id, archive_source) {
        (
            AdminJobAction::Restore,
            ArchiveIdField::Present(Some(value)),
            ArchiveSourceField::Present(Some(source)),
        ) => Ok((
            Some(validate_admin_archive_id(value)?),
            Some(crate::backup_replication::ArchiveSource::parse(source)?),
        )),
        (AdminJobAction::Restore, ArchiveIdField::Missing | ArchiveIdField::Present(None), _)
        | (
            AdminJobAction::Restore,
            _,
            ArchiveSourceField::Missing | ArchiveSourceField::Present(None),
        ) => Err(invalid_admin_job_request()),
        (
            AdminJobAction::Maintenance | AdminJobAction::Backup,
            ArchiveIdField::Missing,
            ArchiveSourceField::Missing,
        ) => Ok((None, None)),
        _ => Err(invalid_admin_job_request()),
    }
}

pub(crate) fn validate_admin_job_request_id(request_id: &str) -> Result<String, ApiError> {
    let parsed = Uuid::parse_str(request_id).map_err(|_| {
        ApiError::bad_request(
            "INVALID_REQUEST_ID",
            "request_id must be a canonical lowercase UUID",
        )
    })?;
    if parsed.to_string() != request_id {
        return Err(ApiError::bad_request(
            "INVALID_REQUEST_ID",
            "request_id must be a canonical lowercase UUID",
        ));
    }
    Ok(request_id.to_owned())
}

pub(crate) fn validate_restore_job_id(job_id: &str) -> Result<String, ApiError> {
    let parsed = Uuid::parse_str(job_id).map_err(|_| {
        ApiError::bad_request("INVALID_RESTORE_JOB_ID", "restore job id is invalid")
    })?;
    if parsed.to_string() != job_id {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_JOB_ID",
            "restore job id must use canonical lowercase UUID format",
        ));
    }
    Ok(parsed.to_string())
}

fn validate_admin_archive_id(archive_id: &str) -> Result<String, ApiError> {
    let parsed = Uuid::parse_str(archive_id).map_err(|_| {
        ApiError::bad_request(
            "INVALID_ARCHIVE_ID",
            "archive_id must be a canonical lowercase UUID",
        )
    })?;
    if parsed.to_string() != archive_id {
        return Err(ApiError::bad_request(
            "INVALID_ARCHIVE_ID",
            "archive_id must be a canonical lowercase UUID",
        ));
    }
    Ok(archive_id.to_owned())
}

fn spawn_admin_job(state: AppState, job_id: &str) {
    let Some(worker_lease) = AdminJobWorkerLease::claim(job_id) else {
        return;
    };
    let job_id = job_id.to_owned();
    tokio::spawn(async move {
        let _worker_lease = worker_lease;
        execute_admin_job(state, job_id).await;
    });
}

static ACTIVE_ADMIN_MAINTENANCE_JOBS: OnceLock<StdMutex<HashSet<String>>> = OnceLock::new();

struct AdminJobWorkerLease {
    job_id: String,
}

impl AdminJobWorkerLease {
    fn claim(job_id: &str) -> Option<Self> {
        let active = ACTIVE_ADMIN_MAINTENANCE_JOBS.get_or_init(Default::default);
        let mut active = active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !active.insert(job_id.to_owned()) {
            return None;
        }
        Some(Self {
            job_id: job_id.to_owned(),
        })
    }
}

impl Drop for AdminJobWorkerLease {
    fn drop(&mut self) {
        let active = ACTIVE_ADMIN_MAINTENANCE_JOBS.get_or_init(Default::default);
        active
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .remove(&self.job_id);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum AdminJobFaultPoint {
    StartBegin,
    StartUpdate,
    StartAudit,
    StartCommitAck,
    TerminalBegin,
    TerminalUpdate,
    TerminalAudit,
    TerminalCommitAck,
}

#[derive(Clone, Default)]
struct AdminJobFaultInjector {
    #[cfg(test)]
    remaining: Arc<StdMutex<HashMap<AdminJobFaultPoint, usize>>>,
}

impl AdminJobFaultInjector {
    fn check(&self, point: AdminJobFaultPoint) -> Result<(), ApiError> {
        #[cfg(test)]
        {
            let mut remaining = self
                .remaining
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(count) = remaining.get_mut(&point) {
                if *count > 0 {
                    *count -= 1;
                    return Err(ApiError::internal("injected admin job persistence failure"));
                }
            }
        }
        #[cfg(not(test))]
        let _ = point;
        Ok(())
    }

    #[cfg(test)]
    fn failing(points: &[(AdminJobFaultPoint, usize)]) -> Self {
        Self {
            remaining: Arc::new(StdMutex::new(points.iter().copied().collect())),
        }
    }

    #[cfg(test)]
    fn has_remaining_failures(&self) -> bool {
        self.remaining
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .values()
            .all(|count| *count == 0)
    }
}

#[derive(Clone, Copy)]
struct AdminJobRetryPolicy {
    initial_delay: Duration,
    max_delay: Duration,
}

impl AdminJobRetryPolicy {
    const PRODUCTION: Self = Self {
        initial_delay: Duration::from_millis(250),
        max_delay: Duration::from_secs(30),
    };

    fn delay(self, attempt: u32) -> Duration {
        let initial_ms = self.initial_delay.as_millis().min(u64::MAX as u128) as u64;
        let max_ms = self.max_delay.as_millis().min(u64::MAX as u128) as u64;
        let multiplier = 1_u64 << attempt.saturating_sub(1).min(20);
        Duration::from_millis(initial_ms.saturating_mul(multiplier).min(max_ms))
    }
}

#[derive(Debug, Clone)]
struct AdminJobRequester {
    user_id: String,
    device_id: String,
    action: AdminJobAction,
    archive_id: Option<String>,
    archive_source: Option<crate::backup_replication::ArchiveSource>,
}

enum AdminJobStartState {
    Started(AdminJobRequester),
    NotQueued,
}

async fn execute_admin_job(state: AppState, job_id: String) {
    let faults = AdminJobFaultInjector::default();
    execute_admin_job_with_policy(&state, &job_id, &faults, AdminJobRetryPolicy::PRODUCTION).await;
}

async fn execute_admin_job_with_policy(
    state: &AppState,
    job_id: &str,
    faults: &AdminJobFaultInjector,
    policy: AdminJobRetryPolicy,
) {
    let Some(requester) = persist_admin_job_started(state, job_id, faults, policy).await else {
        return;
    };

    // Keep the operation result in memory while persistence is retried. A
    // completed maintenance or backup operation is never rerun merely because
    // its status/audit transaction had a transient failure.
    let succeeded = match requester.action {
        AdminJobAction::Maintenance => crate::run_maintenance(state).await.is_ok(),
        AdminJobAction::Backup => crate::backup::run_configured_admin_backup(state, job_id)
            .await
            .is_ok(),
        AdminJobAction::Restore => {
            match (requester.archive_id.as_deref(), requester.archive_source) {
                (Some(archive_id), Some(archive_source)) => {
                    crate::backup::run_configured_admin_restore_stage(
                        state,
                        job_id,
                        archive_id,
                        archive_source,
                    )
                    .await
                    .is_ok()
                }
                _ => false,
            }
        }
    };
    persist_admin_job_terminal(state, job_id, &requester, succeeded, faults, policy).await;
}

async fn persist_admin_job_started(
    state: &AppState,
    job_id: &str,
    faults: &AdminJobFaultInjector,
    policy: AdminJobRetryPolicy,
) -> Option<AdminJobRequester> {
    let mut attempt = 0_u32;
    loop {
        match mark_admin_job_running_once(state, job_id, faults).await {
            Ok(AdminJobStartState::Started(requester)) => return Some(requester),
            Ok(AdminJobStartState::NotQueued) => return None,
            Err(_) => {
                attempt = attempt.saturating_add(1);
                let delay = policy.delay(attempt);
                tracing::warn!(
                    job_id = %job_id,
                    stage = "start",
                    attempt,
                    retry_after_ms = delay.as_millis() as u64,
                    "instance-admin maintenance job persistence failed; retrying"
                );
                tokio::time::sleep(delay).await;
            }
        }
    }
}

async fn mark_admin_job_running_once(
    state: &AppState,
    job_id: &str,
    faults: &AdminJobFaultInjector,
) -> Result<AdminJobStartState, ApiError> {
    faults.check(AdminJobFaultPoint::StartBegin)?;
    let started_at = now_rfc3339();
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let existing = sqlx::query(
        "SELECT requested_by_user_id,requested_by_device_id,action,archive_id,archive_source,status FROM instance_admin_jobs WHERE job_id=?",
    )
    .bind(&job_id)
    .fetch_optional(&mut *tx)
    .await;
    let Some(existing) = existing.map_err(ApiError::internal)? else {
        return Ok(AdminJobStartState::NotQueued);
    };
    let action = AdminJobAction::from_storage(existing.get::<String, _>("action").as_str())?;
    let stored_archive_source: String = existing.get("archive_source");
    let archive_source = if action == AdminJobAction::Restore {
        Some(crate::backup_replication::ArchiveSource::parse(
            &stored_archive_source,
        )?)
    } else {
        None
    };
    let requester = AdminJobRequester {
        user_id: existing.get("requested_by_user_id"),
        device_id: existing.get("requested_by_device_id"),
        action,
        archive_id: existing.get("archive_id"),
        archive_source,
    };
    match existing.get::<String, _>("status").as_str() {
        // A prior commit may have succeeded even though the caller observed a
        // transient acknowledgement error. The worker lease ensures this
        // running row belongs to this in-process worker.
        "running" => return Ok(AdminJobStartState::Started(requester)),
        "queued" => {}
        _ => return Ok(AdminJobStartState::NotQueued),
    }
    faults.check(AdminJobFaultPoint::StartUpdate)?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET status='running',started_at=? WHERE job_id=? AND status='queued'",
    )
    .bind(&started_at)
    .bind(&job_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "admin job start transition was not applied",
        ));
    }
    faults.check(AdminJobFaultPoint::StartAudit)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        state,
        &requester.user_id,
        &requester.device_id,
        requester.action.event(AdminJobAuditStage::Started),
        "admin_job",
        Some(&job_id),
        chrono::Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    // Simulate a transient lost commit acknowledgement. Retrying must observe
    // running and must not add a duplicate start audit event.
    faults.check(AdminJobFaultPoint::StartCommitAck)?;
    Ok(AdminJobStartState::Started(requester))
}

async fn persist_admin_job_terminal(
    state: &AppState,
    job_id: &str,
    requester: &AdminJobRequester,
    succeeded: bool,
    faults: &AdminJobFaultInjector,
    policy: AdminJobRetryPolicy,
) {
    let mut attempt = 0_u32;
    loop {
        match persist_admin_job_terminal_once(state, job_id, requester, succeeded, faults).await {
            Ok(()) => return,
            Err(_) => {
                attempt = attempt.saturating_add(1);
                let delay = policy.delay(attempt);
                tracing::error!(
                    job_id = %job_id,
                    stage = "terminal",
                    attempt,
                    retry_after_ms = delay.as_millis() as u64,
                    "instance-admin maintenance result is not yet durable; retrying"
                );
                tokio::time::sleep(delay).await;
            }
        }
    }
}

async fn persist_admin_job_terminal_once(
    state: &AppState,
    job_id: &str,
    requester: &AdminJobRequester,
    succeeded: bool,
    faults: &AdminJobFaultInjector,
) -> Result<(), ApiError> {
    faults.check(AdminJobFaultPoint::TerminalBegin)?;
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let status = if succeeded { "succeeded" } else { "failed" };
    let result_code = if succeeded {
        "completed"
    } else {
        requester.action.failed_result_code()
    };
    let current_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
            .bind(job_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    match current_status.as_deref() {
        Some(current) if current == status => return Ok(()),
        Some("running") => {}
        Some("queued") => {
            return Err(ApiError::internal(
                "admin job returned to queued after cleanup started",
            ));
        }
        Some(_) => {
            return Err(ApiError::internal(
                "admin job reached a different terminal state than expected",
            ));
        }
        None => {
            return Err(ApiError::internal(
                "admin job row is missing at terminal persist",
            ));
        }
    }

    let finished_at = now_rfc3339();
    faults.check(AdminJobFaultPoint::TerminalUpdate)?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET status=?,finished_at=?,result_code=? WHERE job_id=? AND status='running'",
    )
    .bind(status)
    .bind(&finished_at)
    .bind(result_code)
    .bind(&job_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "admin job terminal transition was not applied",
        ));
    }
    faults.check(AdminJobFaultPoint::TerminalAudit)?;
    if succeeded {
        audit::record_instance_admin_event_tx(
            &mut tx,
            state,
            &requester.user_id,
            &requester.device_id,
            requester.action.event(AdminJobAuditStage::Completed),
            "admin_job",
            Some(job_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    } else {
        audit::record_instance_admin_failure_event_tx(
            &mut tx,
            state,
            &requester.user_id,
            &requester.device_id,
            requester.action.event(AdminJobAuditStage::Failed),
            "admin_job",
            Some(job_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    // Retrying after a lost acknowledgement reads the already-terminal row
    // above and exits without duplicating its audit event.
    faults.check(AdminJobFaultPoint::TerminalCommitAck)?;
    Ok(())
}

pub(crate) async fn recover_interrupted_jobs(state: &AppState) -> Result<(), ApiError> {
    let rows = sqlx::query(
        "SELECT job_id,requested_by_user_id,requested_by_device_id,action,archive_id,archive_source,archive_sha256 \
         FROM instance_admin_jobs WHERE status IN ('queued','running') ORDER BY requested_at,job_id",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let mut recoveries = Vec::with_capacity(rows.len());
    for row in rows {
        let action = AdminJobAction::from_storage(row.get::<String, _>("action").as_str())?;
        let job_id: String = row.get("job_id");
        let recovered_restore = if action == AdminJobAction::Restore {
            let archive_id: Option<String> = row.get("archive_id");
            let archive_id = archive_id
                .ok_or_else(|| ApiError::internal("running restore job has no selected archive"))?;
            let archive_sha256: Option<String> = row.get("archive_sha256");
            let archive_source = crate::backup_replication::ArchiveSource::parse(
                row.get::<String, _>("archive_source").as_str(),
            )?;
            // Staging is isolated from the active data directory. A missing
            // backup mount or an invalid stage must interrupt this job without
            // preventing the live service from starting. Reconciliation never
            // replays work; on any failure it leaves untrusted stage paths
            // untouched and records the restore as interrupted.
            match crate::backup::reconcile_admin_restore_stage(
                state,
                &job_id,
                &archive_id,
                archive_source,
                archive_sha256.as_deref(),
            )
            .await
            {
                Ok(recovered) => Some(recovered),
                Err(error) => {
                    tracing::warn!(
                        job_id = %job_id,
                        error_code = %error.body.code,
                        "restore stage could not be reconciled safely; marking interrupted"
                    );
                    Some(false)
                }
            }
        } else {
            None
        };
        recoveries.push((row, action, recovered_restore));
    }

    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let finished_at = now_rfc3339();
    for (row, action, recovered_restore) in recoveries {
        let job_id: String = row.get("job_id");
        let recovered = recovered_restore == Some(true);
        let (status, result_code) = if recovered {
            ("succeeded", "completed")
        } else {
            ("interrupted", "interrupted")
        };
        let changed = sqlx::query(
            "UPDATE instance_admin_jobs SET status=?,finished_at=?,result_code=? \
             WHERE job_id=? AND status IN ('queued','running')",
        )
        .bind(status)
        .bind(&finished_at)
        .bind(result_code)
        .bind(&job_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() == 1 {
            let user_id: String = row.get("requested_by_user_id");
            let device_id: String = row.get("requested_by_device_id");
            if recovered {
                audit::record_instance_admin_event_tx(
                    &mut tx,
                    state,
                    &user_id,
                    &device_id,
                    action.event(AdminJobAuditStage::Completed),
                    "admin_job",
                    Some(&job_id),
                    chrono::Utc::now().timestamp(),
                )
                .await?;
            } else {
                audit::record_instance_admin_failure_event_tx(
                    &mut tx,
                    state,
                    &user_id,
                    &device_id,
                    action.event(AdminJobAuditStage::Interrupted),
                    "admin_job",
                    Some(&job_id),
                    chrono::Utc::now().timestamp(),
                )
                .await?;
            }
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;
    recover_restore_stage_lifecycles(state).await
}

async fn recover_restore_stage_lifecycles(state: &AppState) -> Result<(), ApiError> {
    let pending = sqlx::query(
        "SELECT s.restore_job_id,s.generation,s.discard_requested_by_user_id, \
                s.discard_requested_by_device_id,j.requested_by_user_id,j.action, \
                j.archive_id,j.archive_source,j.archive_sha256,j.status,j.result_code \
         FROM instance_admin_restore_stages s \
         JOIN instance_admin_jobs j ON j.job_id=s.restore_job_id \
         WHERE s.status='discarding' ORDER BY s.ready_at,s.restore_job_id",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let legacy_ready = sqlx::query(
        "SELECT j.job_id,j.archive_id,j.archive_source,j.archive_sha256 \
         FROM instance_admin_jobs j LEFT JOIN instance_admin_restore_stages s \
           ON s.restore_job_id=j.job_id \
         WHERE j.action='restore' AND j.status='succeeded' AND s.restore_job_id IS NULL \
         ORDER BY j.requested_at,j.job_id",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    if pending.is_empty() && legacy_ready.is_empty() {
        return Ok(());
    }
    if crate::backup::configured_backup_paths(&state.config).is_err() {
        return Ok(());
    }
    let _maintenance_guard = match crate::acquire_instance_maintenance_lock(state).await {
        Ok(guard) => guard,
        Err(error) => {
            tracing::warn!(
                error_code = %error.body.code,
                "restore stage lifecycle reconciliation deferred because maintenance is locked"
            );
            return Ok(());
        }
    };

    for row in pending {
        let job_id: String = row.get("restore_job_id");
        let owner_id: String = row.get("requested_by_user_id");
        let discard_actor: Option<String> = row.get("discard_requested_by_user_id");
        let discard_device: Option<String> = row.get("discard_requested_by_device_id");
        let ready = row.get::<String, _>("action") == "restore"
            && row.get::<String, _>("status") == "succeeded"
            && row.get::<Option<String>, _>("result_code").as_deref() == Some("completed")
            && discard_actor.as_deref() == Some(owner_id.as_str())
            && discard_device.is_some();
        if !ready {
            tracing::warn!(
                job_id = %job_id,
                "restore stage discard lifecycle did not match its durable job; leaving it pending"
            );
            continue;
        }
        let Some(archive_id) = row.get::<Option<String>, _>("archive_id") else {
            continue;
        };
        let Some(archive_sha256) = row.get::<Option<String>, _>("archive_sha256") else {
            continue;
        };
        let archive_source = match crate::backup_replication::ArchiveSource::parse(
            row.get::<String, _>("archive_source").as_str(),
        ) {
            Ok(source) => source,
            Err(_) => continue,
        };
        let generation: String = row.get("generation");
        if let Err(error) = crate::backup::discard_admin_restore_stage_files(
            state,
            &job_id,
            &archive_id,
            archive_source,
            &archive_sha256,
            &generation,
        )
        .await
        {
            tracing::warn!(
                job_id = %job_id,
                error_code = %error.body.code,
                "restore stage discard recovery failed and remains retryable"
            );
            continue;
        }
        if let Err(error) = finish_restore_stage_discard(state, &job_id).await {
            tracing::warn!(
                job_id = %job_id,
                error_code = %error.body.code,
                "restore stage discard finalization failed and remains retryable"
            );
        }
    }

    for row in legacy_ready {
        let job_id: String = row.get("job_id");
        let Some(archive_id) = row.get::<Option<String>, _>("archive_id") else {
            continue;
        };
        let Some(archive_sha256) = row.get::<Option<String>, _>("archive_sha256") else {
            continue;
        };
        let archive_source = match crate::backup_replication::ArchiveSource::parse(
            row.get::<String, _>("archive_source").as_str(),
        ) {
            Ok(source) => source,
            Err(_) => continue,
        };
        if let Err(error) = crate::backup::backfill_admin_restore_stage_ready(
            state,
            &job_id,
            &archive_id,
            archive_source,
            &archive_sha256,
        )
        .await
        {
            tracing::warn!(
                job_id = %job_id,
                error_code = %error.body.code,
                "legacy restore stage could not be verified during lifecycle backfill"
            );
        }
    }
    Ok(())
}

pub async fn list_vaults(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<VaultListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_VAULT_PAGE_SIZE,
        1,
        MAX_VAULT_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_VAULT_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_vaults::list_vaults(
                &state,
                &user,
                &state.config.admin_usernames,
                i64::from(limit),
                i64::from(offset),
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let now = now_rfc3339();
    let total: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM vaults WHERE state IN ('active','deleting')")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT v.vault_id,v.owner_user_id,u.username AS owner_username,v.state,\
         COALESCE((SELECT SUM(b.size) FROM blob_objects b WHERE b.vault_id=v.vault_id),0) AS stored_bytes,\
         COALESCE((SELECT SUM(up.expected_size) FROM uploads up WHERE up.vault_id=v.vault_id \
                   AND up.state='open' AND up.expires_at>?),0) AS reserved_upload_bytes,\
         v.quota_bytes,v.created_at \
         FROM vaults v JOIN users u ON u.user_id=v.owner_user_id \
         WHERE v.state IN ('active','deleting') \
         ORDER BY v.created_at DESC,v.vault_id ASC LIMIT ? OFFSET ?",
    )
    .bind(&now)
    .bind(i64::from(limit))
    .bind(i64::from(offset))
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let vaults: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            json!({
                "vault_id": row.get::<String, _>("vault_id"),
                "owner_user_id": row.get::<String, _>("owner_user_id"),
                "owner_username": row.get::<String, _>("owner_username"),
                "state": row.get::<String, _>("state"),
                "stored_bytes": row.get::<i64, _>("stored_bytes"),
                "reserved_upload_bytes": row.get::<i64, _>("reserved_upload_bytes"),
                "quota_bytes": row.get::<i64, _>("quota_bytes"),
                "created_at": row.get::<String, _>("created_at"),
            })
        })
        .collect();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "vaults": vaults,
        "total": total,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn update_vault_quota(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    request: Result<Json<UpdateVaultQuotaRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_QUOTA",
            "request body must contain a valid quota_bytes integer",
        )
    })?;
    validate_vault_id(&vault_id)?;
    if !(1..=MAX_ADMIN_VAULT_QUOTA_BYTES).contains(&request.quota_bytes) {
        return Err(ApiError::bad_request(
            "INVALID_QUOTA",
            "quota_bytes must be between 1 byte and 1 TiB",
        ));
    }

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_vaults::update_vault_quota(
                &state,
                &user,
                &state.config.admin_usernames,
                &vault_id,
                request.quota_bytes,
            )
            .await?,
        ));
    }

    // Reject ordinary authenticated users before acquiring SQLite's global
    // writer. The allowlist is checked again together with the live session.
    precheck_instance_admin(&state, &user.user_id).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;

    // Acquire the SQLite writer before reading usage so quota decisions and
    // object reservations cannot race each other.
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let now = now_rfc3339();
    let row = sqlx::query(
        "SELECT v.state,v.quota_bytes,\
         COALESCE((SELECT SUM(b.size) FROM blob_objects b WHERE b.vault_id=v.vault_id),0) AS stored_bytes,\
         COALESCE((SELECT SUM(up.expected_size) FROM uploads up WHERE up.vault_id=v.vault_id \
                   AND up.state='open' AND up.expires_at>?),0) AS reserved_upload_bytes \
         FROM vaults v WHERE v.vault_id=?",
    )
    .bind(&now)
    .bind(&vault_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let vault_state: String = row.get("state");
    if vault_state != "active" {
        return Err(ApiError::conflict(
            "VAULT_NOT_ACTIVE",
            "quota can only be changed for an active vault",
        ));
    }
    let stored_bytes: i64 = row.get("stored_bytes");
    let reserved_upload_bytes: i64 = row.get("reserved_upload_bytes");
    let used_bytes = stored_bytes.saturating_add(reserved_upload_bytes);
    if request.quota_bytes < used_bytes {
        return Err(ApiError::conflict(
            "QUOTA_BELOW_USAGE",
            "quota_bytes cannot be lower than completed and reserved storage",
        )
        .with_details(json!({
            "stored_bytes": stored_bytes,
            "reserved_upload_bytes": reserved_upload_bytes,
            "used_bytes": used_bytes,
            "requested_quota_bytes": request.quota_bytes,
        })));
    }
    let previous_quota: i64 = row.get("quota_bytes");
    if previous_quota != request.quota_bytes {
        sqlx::query("UPDATE vaults SET quota_bytes=? WHERE vault_id=? AND state='active'")
            .bind(request.quota_bytes)
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "admin.vault_quota_set",
        "vault",
        Some(&vault_id),
        chrono::Utc::now().timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "vault_id": vault_id,
        "quota_bytes": request.quota_bytes,
        "stored_bytes": stored_bytes,
        "reserved_upload_bytes": reserved_upload_bytes,
        "updated_at": now,
    })))
}

pub async fn list_accounts(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminAccountListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_ADMIN_ACCOUNT_PAGE_SIZE,
        1,
        MAX_ADMIN_ACCOUNT_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_VAULT_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_accounts::list_accounts(
                &state,
                &user,
                &state.config.admin_usernames,
                i64::from(limit),
                i64::from(offset),
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let now = now_rfc3339();
    let rows = sqlx::query(&format!(
        "SELECT u.user_id,u.username,u.status,u.created_at,u.credential_visibility,\
         ({}) AS escrow_status,\
         (SELECT COUNT(*) FROM devices d WHERE d.user_id=u.user_id AND d.status='active') AS active_device_count,\
         (SELECT COUNT(*) FROM sessions s WHERE s.user_id=u.user_id AND s.revoked_at IS NULL AND s.refresh_expires_at>? \
          AND u.status='active' AND EXISTS(SELECT 1 FROM devices sd WHERE sd.device_id=s.device_id AND sd.status='active')) AS active_session_count \
         FROM users u ORDER BY u.created_at DESC,u.user_id ASC LIMIT ? OFFSET ?",
        crate::credential_visibility::escrow_status_sql("u")
    ))
    .bind(&now)
    .bind(i64::from(limit))
    .bind(i64::from(offset))
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let accounts: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            json!({
                "user_id": row.get::<String, _>("user_id"),
                "username": row.get::<String, _>("username"),
                "status": row.get::<String, _>("status"),
                "created_at": row.get::<String, _>("created_at"),
                "active_device_count": row.get::<i64, _>("active_device_count"),
                "active_session_count": row.get::<i64, _>("active_session_count"),
                "credential_visibility": row.get::<String, _>("credential_visibility"),
                "escrow_status": row.get::<String, _>("escrow_status"),
            })
        })
        .collect();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "accounts": accounts,
        "total": total,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn list_account_invitations(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<AdminAccountInvitationListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_ADMIN_INVITATION_PAGE_SIZE,
        1,
        MAX_ADMIN_INVITATION_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_ADMIN_JOB_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_invitations::list_account_invitations(
                &state,
                &user,
                &state.config.admin_usernames,
                i64::from(limit),
                i64::from(offset),
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM account_invitations")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT invitation_id,username,created_at,expires_at,consumed_at,revoked_at,credential_visibility \
         FROM account_invitations \
         ORDER BY created_at DESC,invitation_id DESC LIMIT ? OFFSET ?",
    )
    .bind(i64::from(limit))
    .bind(i64::from(offset))
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let now = chrono::Utc::now();
    let mut invitations = Vec::with_capacity(rows.len());
    for row in rows {
        let invitation_id: String = row.get("invitation_id");
        let username: String = row.get("username");
        let created_at: String = row.get("created_at");
        let expires_at: String = row.get("expires_at");
        let consumed_at: Option<String> = row.get("consumed_at");
        let revoked_at: Option<String> = row.get("revoked_at");
        let credential_visibility: Option<String> = row.get("credential_visibility");
        let status = account_invitation_status(
            &expires_at,
            consumed_at.as_deref(),
            revoked_at.as_deref(),
            now,
        )?;
        invitations.push(json!({
            "invitation_id": invitation_id,
            "username": username,
            "created_at": created_at,
            "expires_at": expires_at,
            "status": status,
            "credential_visibility": credential_visibility,
        }));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "invitations": invitations,
        "total": total,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn create_account_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<CreateAdminAccountInvitationRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_ACCOUNT_INVITATION",
            "request body must contain username, an optional integer expires_in_seconds and an \
             optional credential_visibility of private, admin_visible or null",
        )
    })?;
    let username = auth::normalized_username(&request.username)?;
    let lifetime = request
        .expires_in_seconds
        .unwrap_or(auth::ACCOUNT_INVITATION_DEFAULT_SECONDS);
    if !(auth::ACCOUNT_INVITATION_MIN_SECONDS..=auth::ACCOUNT_INVITATION_MAX_SECONDS)
        .contains(&lifetime)
    {
        return Err(ApiError::bad_request(
            "INVALID_INVITATION_TTL",
            "account invitation lifetime must be between 60 and 2592000 seconds",
        ));
    }

    if state.pg_sync_only {
        if request.credential_visibility.is_some() {
            return Err(crate::credential_visibility::pg_unsupported());
        }
        let body = crate::pg_admin_invitations::create_account_invitation(
            &state,
            &user,
            &state.config.admin_usernames,
            &username,
            lifetime,
        )
        .await?;
        return Ok((StatusCode::CREATED, Json(body)));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Acquire SQLite's writer reservation before rechecking the admin session,
    // device and allowlist in this transaction. This orders issuance and
    // superseding against registration, revoke and administrator revocation.
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;

    let user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let setup_consumed: Option<String> =
        sqlx::query_scalar("SELECT setup_consumed_at FROM instance_meta WHERE id=1")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if user_count == 0 || setup_consumed.is_none() {
        return Err(ApiError::conflict(
            "SETUP_REQUIRED",
            "complete initial bootstrap before issuing account invitations",
        ));
    }
    let username_exists: Option<i64> = sqlx::query_scalar("SELECT 1 FROM users WHERE username=?")
        .bind(&username)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if username_exists.is_some() {
        return Err(ApiError::conflict(
            "USERNAME_TAKEN",
            "an account with this username already exists",
        ));
    }

    let now = chrono::Utc::now();
    let created_at = now.to_rfc3339();
    let expires_at = (now + chrono::Duration::seconds(lifetime)).to_rfc3339();
    let superseded = sqlx::query(
        "UPDATE account_invitations SET revoked_at=? \
         WHERE username=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>? \
         RETURNING invitation_id",
    )
    .bind(&created_at)
    .bind(&username)
    .bind(&created_at)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for row in superseded {
        let old_invitation_id: String = row.get("invitation_id");
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "instance.account_invitation_revoked",
            "account_invitation",
            Some(&old_invitation_id),
            now.timestamp(),
        )
        .await?;
    }

    let token = auth::random_token();
    let token_hash = crate::sha256_hex(token.as_bytes());
    let invitation_id = Uuid::new_v4().to_string();
    let credential_visibility = request
        .credential_visibility
        .map(crate::credential_visibility::CredentialVisibility::as_str);
    sqlx::query(
        "INSERT INTO account_invitations(invitation_id,token_hash,username,created_at,expires_at,\
         credential_visibility) VALUES(?,?,?,?,?,?)",
    )
    .bind(&invitation_id)
    .bind(token_hash)
    .bind(&username)
    .bind(&created_at)
    .bind(&expires_at)
    .bind(credential_visibility)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "instance.account_invitation_issued",
        "account_invitation",
        Some(&invitation_id),
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "invitation": {
                "invitation_id": invitation_id,
                "username": username,
                "created_at": created_at,
                "expires_at": expires_at,
                "token": token,
                "credential_visibility": credential_visibility,
            }
        })),
    ))
}

pub async fn revoke_account_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(invitation_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    validate_admin_account_invitation_id(&invitation_id)?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_invitations::revoke_account_invitation(
                &state,
                &user,
                &state.config.admin_usernames,
                &invitation_id,
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE instance_meta SET id=id WHERE id=1")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    let row = sqlx::query(
        "SELECT expires_at,consumed_at,revoked_at FROM account_invitations WHERE invitation_id=?",
    )
    .bind(&invitation_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let expires_at: String = row.get("expires_at");
    let consumed_at: Option<String> = row.get("consumed_at");
    let revoked_at: Option<String> = row.get("revoked_at");
    let now = chrono::Utc::now();

    if let Some(revoked_at) = revoked_at {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(json!({
            "invitation_id": invitation_id,
            "status": "revoked",
            "revoked_at": revoked_at,
        })));
    }
    if account_invitation_status(&expires_at, consumed_at.as_deref(), None, now)? != "pending" {
        return Err(ApiError::conflict(
            "ACCOUNT_INVITATION_NOT_PENDING",
            "only a pending account invitation can be revoked",
        ));
    }

    let revoked_at = now.to_rfc3339();
    let updated = sqlx::query(
        "UPDATE account_invitations SET revoked_at=? \
         WHERE invitation_id=? AND consumed_at IS NULL AND revoked_at IS NULL AND expires_at>?",
    )
    .bind(&revoked_at)
    .bind(&invitation_id)
    .bind(&revoked_at)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "ACCOUNT_INVITATION_NOT_PENDING",
            "only a pending account invitation can be revoked",
        ));
    }
    audit::record_instance_admin_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        &user.device_id,
        "instance.account_invitation_revoked",
        "account_invitation",
        Some(&invitation_id),
        now.timestamp(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "invitation_id": invitation_id,
        "status": "revoked",
        "revoked_at": revoked_at,
    })))
}

fn account_invitation_status(
    expires_at: &str,
    consumed_at: Option<&str>,
    revoked_at: Option<&str>,
    now: chrono::DateTime<chrono::Utc>,
) -> Result<&'static str, ApiError> {
    if consumed_at.is_some() {
        return Ok("consumed");
    }
    if revoked_at.is_some() {
        return Ok("revoked");
    }
    let expires = chrono::DateTime::parse_from_rfc3339(expires_at)
        .map_err(|_| ApiError::internal("stored account invitation expiry is invalid"))?
        .with_timezone(&chrono::Utc);
    if expires <= now {
        Ok("expired")
    } else {
        Ok("pending")
    }
}

fn validate_admin_account_invitation_id(invitation_id: &str) -> Result<(), ApiError> {
    let parsed = Uuid::parse_str(invitation_id)
        .map_err(|_| ApiError::bad_request("INVALID_INVITATION_ID", "invitation id is invalid"))?;
    if parsed.to_string() != invitation_id {
        return Err(ApiError::bad_request(
            "INVALID_INVITATION_ID",
            "invitation id must use canonical lowercase UUID format",
        ));
    }
    Ok(())
}

pub async fn list_account_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    Query(query): Query<AdminAccountListQuery>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    validate_admin_user_id(&user_id)?;
    let limit = parse_page_number(
        query.limit.as_deref(),
        DEFAULT_ADMIN_ACCOUNT_PAGE_SIZE,
        1,
        MAX_ADMIN_ACCOUNT_PAGE_SIZE,
        "INVALID_LIMIT",
    )?;
    let offset = parse_page_number(
        query.offset.as_deref(),
        0,
        0,
        MAX_VAULT_PAGE_OFFSET,
        "INVALID_OFFSET",
    )?;

    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_accounts::list_account_sessions(
                &state,
                &user,
                &state.config.admin_usernames,
                &user_id,
                i64::from(limit),
                i64::from(offset),
            )
            .await?,
        ));
    }

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_read_tx(&mut tx, &state, &user).await?;
    let exists: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if exists == 0 {
        return Err(ApiError::not_found());
    }
    let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let now = now_rfc3339();
    let rows = sqlx::query(
        "SELECT s.session_id,s.device_id,d.name AS device_name,s.created_at,\
         s.access_expires_at,s.refresh_expires_at,s.revoked_at,d.status AS device_status,u.status AS account_status \
         FROM sessions s JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         JOIN users u ON u.user_id=s.user_id WHERE s.user_id=? \
         ORDER BY s.created_at DESC,s.session_id ASC LIMIT ? OFFSET ?",
    )
    .bind(&user_id)
    .bind(i64::from(limit))
    .bind(i64::from(offset))
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let sessions: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            let refresh_expires_at = row.get::<String, _>("refresh_expires_at");
            let revoked_at = row.get::<Option<String>, _>("revoked_at");
            let device_status = row.get::<String, _>("device_status");
            let account_status = row.get::<String, _>("account_status");
            let active = revoked_at.is_none()
                && refresh_expires_at > now
                && device_status == "active"
                && account_status == "active";
            json!({
                "session_id": row.get::<String, _>("session_id"),
                "device_id": row.get::<String, _>("device_id"),
                "device_name": row.get::<String, _>("device_name"),
                "created_at": row.get::<String, _>("created_at"),
                "access_expires_at": row.get::<String, _>("access_expires_at"),
                "refresh_expires_at": refresh_expires_at,
                "revoked_at": revoked_at,
                "active": active,
            })
        })
        .collect();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "sessions": sessions,
        "total": total,
        "limit": limit,
        "offset": offset,
    })))
}

pub async fn update_account_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
    request: Result<Json<UpdateAdminAccountStatusRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    let Json(request) = request.map_err(|_| {
        ApiError::bad_request(
            "INVALID_ACCOUNT_STATUS",
            "request body must contain status 'active' or 'disabled'",
        )
    })?;
    validate_admin_user_id(&user_id)?;
    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_accounts::update_account_status(
                &state,
                &user,
                &state.config.admin_usernames,
                &user_id,
                request.status.as_str(),
            )
            .await?,
        ));
    }
    precheck_instance_admin(&state, &user.user_id).await?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    reject_admin_self_target(&user.user_id, &user_id)?;

    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let (current_status, target_username): (String, String) =
        sqlx::query_as("SELECT status,username FROM users WHERE user_id=?")
            .bind(&user_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current_status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "a deleting account cannot be changed by instance administration",
        ));
    }
    if !matches!(current_status.as_str(), "active" | "disabled") {
        return Err(ApiError::conflict(
            "ACCOUNT_STATUS_UNSUPPORTED",
            "account status cannot be changed by instance administration",
        ));
    }

    let desired_status = request.status.as_str();
    let changed = current_status != desired_status;
    if changed
        && request.status == AdminAccountStatus::Disabled
        && state.config.is_instance_admin(&target_username)
    {
        ensure_not_last_active_instance_admin_tx(&mut tx, &state).await?;
    }
    let now = now_rfc3339();
    let revoked_sessions = if changed && request.status == AdminAccountStatus::Disabled {
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL")
            .bind(&now)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .rows_affected()
    } else {
        0
    };
    if changed {
        let updated = sqlx::query("UPDATE users SET status=? WHERE user_id=? AND status=?")
            .bind(desired_status)
            .bind(&user_id)
            .bind(&current_status)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "ACCOUNT_STATUS_TRANSITION_CONFLICT",
                "account lifecycle changed; retry the request",
            ));
        }
        let action = match request.status {
            AdminAccountStatus::Active => "admin.account_enabled",
            AdminAccountStatus::Disabled => "admin.account_disabled",
        };
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            action,
            "account",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account_id": user_id,
        "status": desired_status,
        "revoked_sessions": revoked_sessions,
        "changed": changed,
        "updated_at": now,
    })))
}

pub async fn revoke_account_sessions(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(user_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    validate_admin_user_id(&user_id)?;
    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_accounts::revoke_account_sessions(
                &state,
                &user,
                &state.config.admin_usernames,
                &user_id,
            )
            .await?,
        ));
    }
    precheck_instance_admin(&state, &user.user_id).await?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    reject_admin_self_target(&user.user_id, &user_id)?;

    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "sessions for a deleting account are already revoked",
        ));
    }

    let now = now_rfc3339();
    let revoked_sessions =
        sqlx::query("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL")
            .bind(&now)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .rows_affected();
    if revoked_sessions > 0 {
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "admin.account_sessions_revoked",
            "account",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account_id": user_id,
        "revoked_sessions": revoked_sessions,
        "updated_at": now,
    })))
}

pub async fn revoke_account_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((user_id, session_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    let user = auth::authenticate(&state, &headers).await?;
    validate_admin_user_id(&user_id)?;
    validate_admin_session_id(&session_id)?;
    if state.pg_sync_only {
        return Ok(Json(
            crate::pg_admin_accounts::revoke_account_session(
                &state,
                &user,
                &state.config.admin_usernames,
                &user_id,
                &session_id,
            )
            .await?,
        ));
    }
    precheck_instance_admin(&state, &user.user_id).await?;

    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    require_instance_admin_write_tx(&mut tx, &state, &user).await?;
    reject_admin_self_target(&user.user_id, &user_id)?;
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    let status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if status == "deleting" {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETING",
            "sessions for a deleting account are already revoked",
        ));
    }
    let session_exists: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM sessions WHERE session_id=? AND user_id=?")
            .bind(&session_id)
            .bind(&user_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if session_exists == 0 {
        return Err(ApiError::not_found());
    }
    let now = now_rfc3339();
    let changed = sqlx::query(
        "UPDATE sessions SET revoked_at=? WHERE session_id=? AND user_id=? AND revoked_at IS NULL",
    )
    .bind(&now)
    .bind(&session_id)
    .bind(&user_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected()
        == 1;
    if changed {
        audit::record_instance_admin_event_tx(
            &mut tx,
            &state,
            &user.user_id,
            &user.device_id,
            "admin.account_session_revoked",
            "account",
            Some(&user_id),
            chrono::Utc::now().timestamp(),
        )
        .await?;
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "account_id": user_id,
        "session_id": session_id,
        "revoked": true,
        "changed": changed,
        "updated_at": now,
    })))
}

fn reject_admin_self_target(actor_user_id: &str, target_user_id: &str) -> Result<(), ApiError> {
    if actor_user_id == target_user_id {
        return Err(ApiError::conflict(
            "ADMIN_SELF_TARGET",
            "instance administrators cannot change their own account or sessions",
        ));
    }
    Ok(())
}

async fn ensure_not_last_active_instance_admin_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
) -> Result<(), ApiError> {
    let active_usernames: Vec<String> =
        sqlx::query_scalar("SELECT username FROM users WHERE status='active'")
            .fetch_all(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    let active_admin_count = active_usernames
        .iter()
        .filter(|username| state.config.is_instance_admin(username))
        .count();
    if active_admin_count <= 1 {
        return Err(ApiError::conflict(
            "LAST_INSTANCE_ADMIN",
            "the last active instance administrator cannot be disabled",
        ));
    }
    Ok(())
}

fn validate_admin_user_id(user_id: &str) -> Result<(), ApiError> {
    let parsed = Uuid::parse_str(user_id)
        .map_err(|_| ApiError::bad_request("INVALID_ACCOUNT_ID", "account id is invalid"))?;
    if parsed.to_string() != user_id {
        return Err(ApiError::bad_request(
            "INVALID_ACCOUNT_ID",
            "account id must use canonical lowercase UUID format",
        ));
    }
    Ok(())
}

fn validate_admin_session_id(session_id: &str) -> Result<(), ApiError> {
    let parsed = Uuid::parse_str(session_id)
        .map_err(|_| ApiError::bad_request("INVALID_SESSION_ID", "session id is invalid"))?;
    if parsed.to_string() != session_id {
        return Err(ApiError::bad_request(
            "INVALID_SESSION_ID",
            "session id must use canonical lowercase UUID format",
        ));
    }
    Ok(())
}

fn parse_page_number(
    value: Option<&str>,
    default: u32,
    minimum: u32,
    maximum: u32,
    code: &str,
) -> Result<u32, ApiError> {
    let Some(value) = value else {
        return Ok(default);
    };
    let parsed = value
        .parse::<u32>()
        .map_err(|_| ApiError::bad_request(code, "pagination value is invalid"))?;
    if !(minimum..=maximum).contains(&parsed) {
        return Err(ApiError::bad_request(
            code,
            "pagination value is outside the supported range",
        ));
    }
    Ok(parsed)
}

fn validate_vault_id(vault_id: &str) -> Result<(), ApiError> {
    let parsed = Uuid::parse_str(vault_id)
        .map_err(|_| ApiError::bad_request("INVALID_VAULT_ID", "vault id is invalid"))?;
    if parsed.to_string() != vault_id {
        return Err(ApiError::bad_request(
            "INVALID_VAULT_ID",
            "vault id must use canonical lowercase UUID format",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod push_health_tests {
    use super::{PushDeliveryCounts, PushHealthCounts, PushHealthWindow, push_health_response};

    #[test]
    fn push_health_dto_is_fixed_and_configured_means_loaded_adapter_support() {
        let response = push_health_response(
            "2026-10-11T12:00:00.000Z".to_owned(),
            PushHealthWindow {
                start_date_utc: "2026-10-05".to_owned(),
                end_date_utc: "2026-10-11".to_owned(),
            },
            PushHealthCounts {
                registered_endpoints: 5,
                due: 2,
                retry_waiting: 1,
                leased: 1,
                dead_lettered: 1,
            },
            PushDeliveryCounts {
                accepted: 8,
                invalid_token: 1,
                retryable_failure: 2,
            },
            PushHealthCounts::default(),
            PushDeliveryCounts::default(),
        )
        .0;
        assert_eq!(response.as_object().unwrap().len(), 3);
        assert!(response.get("generated_at").is_some());
        assert_eq!(response["delivery_window"]["days"], 7);
        assert_eq!(response["delivery_window"]["start_date_utc"], "2026-10-05");
        assert_eq!(response["delivery_window"]["end_date_utc"], "2026-10-11");
        assert!(response.get("providers").is_some());
        assert_eq!(response["generated_at"], "2026-10-11T12:00:00.000Z");
        let providers = response["providers"].as_array().unwrap();
        assert_eq!(providers.len(), 2);
        assert_eq!(providers[0]["provider"], "apns");
        assert_eq!(providers[1]["provider"], "fcm_v1");
        assert_eq!(providers[0]["registered_endpoints"], 5);
        assert_eq!(providers[0]["due"], 2);
        assert_eq!(providers[0]["retry_waiting"], 1);
        assert_eq!(providers[0]["leased"], 1);
        assert_eq!(providers[0]["dead_lettered"], 1);
        assert_eq!(providers[0]["delivery_results"]["accepted"], 8);
        assert_eq!(providers[0]["delivery_results"]["invalid_token"], 1);
        assert_eq!(providers[0]["delivery_results"]["retryable_failure"], 2);
        for (row, kind) in providers.iter().zip([
            crate::mobile_push::PushProviderKind::Apns,
            crate::mobile_push::PushProviderKind::FcmV1,
        ]) {
            let expected_configured = crate::mobile_push::configured_provider()
                .as_ref()
                .is_some_and(|provider| provider.supports(kind));
            assert_eq!(row["configured"], expected_configured);
            assert_eq!(row.as_object().unwrap().len(), 8);
        }
    }
}

#[cfg(test)]
mod job_tests {
    use super::{
        AdminJobAction, AdminJobListQuery, ArchiveIdField, ArchiveSourceField,
        CreateAdminJobRequest, DiscardRestoreStageRequest, discard_restore_stage, list_jobs,
        validate_action_archive, validate_admin_job_request_id, validate_restore_job_id,
    };
    use crate::{AuthRateLimits, Config};
    use axum::{
        Json, Router,
        body::Body,
        extract::{Path, State},
        http::{HeaderMap, HeaderValue, Method, Request, StatusCode, header},
    };
    use http_body_util::BodyExt;
    use serde_json::Value;
    use sqlx::{Row, SqlitePool, sqlite::SqlitePoolOptions};
    #[cfg(unix)]
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    use std::{fs, io::Write, path::PathBuf, sync::Arc, time::Duration};
    use tower::ServiceExt;
    use uuid::Uuid;

    fn test_config(data_dir: PathBuf) -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
            database_key_file: None,
            backup_retention_count: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            data_dir,
            registration_open: false,
            guacd_address: None,
            relay_enabled: false,
            terminal_collaboration_enabled: false,
            relay_allow_cidrs: Vec::new(),
            relay_allow_ports: Vec::new(),
            relay_max_connections_per_user: 4,
            public_origin: None,
            web_dir: None,
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days: 90,
            record_restore_retention_days: 30,
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 7 * 24 * 60 * 60,
            admin_usernames: Vec::new(),
            auth_rate_limits: AuthRateLimits::default(),
        }
    }

    async fn insert_queued_job_action(
        pool: &SqlitePool,
        job_id: &str,
        request_id: &str,
        requested_at: &str,
        action: super::AdminJobAction,
    ) -> Result<super::AdminJobRequester, sqlx::Error> {
        let requester = super::AdminJobRequester {
            user_id: Uuid::new_v4().to_string(),
            device_id: Uuid::new_v4().to_string(),
            action,
            archive_id: (action == super::AdminJobAction::Restore)
                .then(|| Uuid::new_v4().to_string()),
            archive_source: (action == super::AdminJobAction::Restore)
                .then_some(crate::backup_replication::ArchiveSource::Local),
        };
        sqlx::query(
            "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,requested_by_device_id,action,archive_id,archive_source,status,requested_at) \
             VALUES(?,?,?,?,?,?,?,'queued',?)",
        )
        .bind(job_id)
        .bind(request_id)
        .bind(&requester.user_id)
        .bind(&requester.device_id)
        .bind(action.as_str())
        .bind(&requester.archive_id)
        .bind(requester.archive_source.map(|source| source.as_str()).unwrap_or("local"))
        .bind(requested_at)
        .execute(pool)
        .await?;
        Ok(requester)
    }

    async fn insert_queued_job(
        pool: &SqlitePool,
        job_id: &str,
        request_id: &str,
        requested_at: &str,
    ) -> Result<super::AdminJobRequester, sqlx::Error> {
        insert_queued_job_action(
            pool,
            job_id,
            request_id,
            requested_at,
            super::AdminJobAction::Maintenance,
        )
        .await
    }

    async fn test_state() -> (crate::AppState, PathBuf) {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-admin-job-worker-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        (state, data_dir)
    }

    async fn call_api(
        app: Router,
        method: Method,
        path: &str,
        bearer: Option<&str>,
    ) -> (StatusCode, Vec<u8>) {
        let mut request = Request::builder().method(method).uri(path);
        if let Some(bearer) = bearer {
            request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
        }
        let response = app
            .oneshot(request.body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        (status, body)
    }

    async fn call_api_with_body(
        app: Router,
        method: Method,
        path: &str,
        bearer: Option<&str>,
        body: &'static [u8],
    ) -> (StatusCode, Vec<u8>) {
        let mut request = Request::builder().method(method).uri(path);
        if let Some(bearer) = bearer {
            request = request.header(header::AUTHORIZATION, format!("Bearer {bearer}"));
        }
        let response = app
            .oneshot(request.body(Body::from(body)).unwrap())
            .await
            .unwrap();
        let status = response.status();
        let body = response
            .into_body()
            .collect()
            .await
            .unwrap()
            .to_bytes()
            .to_vec();
        (status, body)
    }

    fn response_json(body: &[u8]) -> Value {
        serde_json::from_slice(body).expect("API response should contain JSON")
    }

    #[tokio::test]
    async fn metrics_emits_object_delete_queue_counts_with_fixed_state_labels() {
        let (mut state, _data_dir) = test_state().await;
        Arc::make_mut(&mut state.config).admin_usernames =
            vec!["metrics-admin@example.test".to_owned()];
        let (_, _, admin_access) = seed_admin_session(&state, "metrics-admin@example.test").await;
        let app = crate::router(state.clone()).await;
        let (empty_status, empty_body) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&admin_access),
        )
        .await;
        assert_eq!(empty_status, StatusCode::OK);
        let empty_exposition = String::from_utf8(empty_body).unwrap();
        assert!(empty_exposition.contains("atermius_object_delete_queue{state=\"pending\"} 0\n"));
        assert!(
            empty_exposition.contains("atermius_object_delete_queue{state=\"retry_wait\"} 0\n")
        );
        assert!(
            empty_exposition.contains("atermius_object_delete_queue{state=\"quarantined\"} 0\n")
        );

        let fixtures = [
            ("pending", None, 0_i64, "pending-marker-one"),
            ("pending", None, 0_i64, "pending-marker-two"),
            (
                "retry_wait",
                Some("remote_unavailable"),
                1_i64,
                "retry-marker",
            ),
            (
                "quarantined",
                Some("integrity_mismatch"),
                2_i64,
                "quarantined-marker",
            ),
        ];
        let mut private_values = Vec::new();
        for (queue_state, failure_category, attempt_count, marker) in fixtures {
            let queue_id = Uuid::new_v4().to_string();
            let store_id = Uuid::new_v4().to_string();
            sqlx::query(
                "INSERT INTO object_delete_queue(\
                 queue_id,storage_backend,storage_key,storage_store_id,expected_size,\
                 expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at\
                 ) VALUES(?,'filesystem',?,?,1,? ,?,?,4102444800,?,'2099-01-01T00:00:00Z')",
            )
            .bind(&queue_id)
            .bind(marker)
            .bind(&store_id)
            .bind("a".repeat(64))
            .bind(queue_state)
            .bind(attempt_count)
            .bind(failure_category)
            .execute(&state.db)
            .await
            .unwrap();
            private_values.extend([queue_id, store_id, marker.to_owned()]);
        }

        for (provider, result) in [
            (
                crate::mobile_push::PushProviderKind::Apns,
                crate::mobile_push::PushSendResult::Accepted,
            ),
            (
                crate::mobile_push::PushProviderKind::Apns,
                crate::mobile_push::PushSendResult::InvalidToken,
            ),
            (
                crate::mobile_push::PushProviderKind::Apns,
                crate::mobile_push::PushSendResult::RetryableFailure,
            ),
            (
                crate::mobile_push::PushProviderKind::FcmV1,
                crate::mobile_push::PushSendResult::Accepted,
            ),
            (
                crate::mobile_push::PushProviderKind::FcmV1,
                crate::mobile_push::PushSendResult::InvalidToken,
            ),
            (
                crate::mobile_push::PushProviderKind::FcmV1,
                crate::mobile_push::PushSendResult::RetryableFailure,
            ),
        ] {
            crate::mobile_push::record_push_send_result(provider, result);
        }

        let (status, body) = call_api(
            app,
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let exposition = String::from_utf8(body).unwrap();
        assert!(exposition.contains("atermius_object_delete_queue{state=\"pending\"} 2\n"));
        assert!(exposition.contains("atermius_object_delete_queue{state=\"retry_wait\"} 1\n"));
        assert!(exposition.contains("atermius_object_delete_queue{state=\"quarantined\"} 1\n"));
        assert!(exposition.contains("# TYPE atermius_object_delete_queue gauge\n"));
        assert!(exposition.contains("# TYPE atermius_mobile_push_send_results_total counter\n"));
        assert!(exposition.contains("not device receipt or sync"));
        for provider in ["apns", "fcm_v1"] {
            for outcome in ["accepted", "invalid_token", "retryable_failure"] {
                let prefix = format!(
                    "atermius_mobile_push_send_results_total{{provider=\"{provider}\",outcome=\"{outcome}\"}} "
                );
                let sample = exposition
                    .lines()
                    .find(|line| line.starts_with(&prefix))
                    .expect("fixed push result sample should be present");
                assert!(sample.strip_prefix(&prefix).unwrap().parse::<u64>().is_ok());
            }
        }
        for private_value in private_values {
            assert!(!exposition.contains(&private_value));
        }
        assert!(!exposition.contains("provider-error-secret-marker"));
    }

    #[tokio::test]
    async fn metrics_emits_only_the_last_recorded_local_backup_success_timestamp() {
        let (mut state, _data_dir) = test_state().await;
        Arc::make_mut(&mut state.config).admin_usernames =
            vec!["metrics-admin@example.test".to_owned()];
        let (_, _, admin_access) = seed_admin_session(&state, "metrics-admin@example.test").await;
        let app = crate::router(state.clone()).await;

        let (empty_status, empty_body) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&admin_access),
        )
        .await;
        assert_eq!(empty_status, StatusCode::OK);
        let empty_exposition = String::from_utf8(empty_body).unwrap();
        assert!(empty_exposition.contains("atermius_backup_last_success_timestamp_seconds 0\n"));

        crate::backup_status::record_backup_success(
            &state.config.data_dir,
            987_654_321,
            987_654_321_987_654_321,
        )
        .unwrap();
        let expected_timestamp =
            crate::backup_status::last_success_timestamp_seconds(&state.config.data_dir)
                .unwrap()
                .unwrap();
        crate::backup_status::record_backup_failure(&state.config.data_dir).unwrap();

        let (status, body) = call_api(
            app,
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let exposition = String::from_utf8(body).unwrap();
        assert!(
            exposition.contains("# TYPE atermius_backup_last_success_timestamp_seconds gauge\n")
        );
        assert!(exposition.contains(&format!(
            "atermius_backup_last_success_timestamp_seconds {expected_timestamp}\n"
        )));
        assert!(!exposition.contains("987654321"));
        assert!(!exposition.contains("987654321987654321"));
        assert!(!exposition.contains("backup-status.json"));
    }

    #[tokio::test]
    async fn metrics_credential_is_scoped_rotatable_revocable_and_persistent() {
        let (mut state, data_dir) = test_state().await;
        Arc::make_mut(&mut state.config).admin_usernames =
            vec!["metrics-admin@example.test".to_owned()];
        let (_, _, admin_access) = seed_admin_session(&state, "metrics-admin@example.test").await;
        let (_, _, ordinary_access) =
            seed_admin_session(&state, "metrics-member@example.test").await;
        let app = crate::router(state.clone()).await;

        let (status, body) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let status_json = response_json(&body);
        assert_eq!(status_json["active"], false);
        assert!(status_json["updated_at"].is_null());

        let (status, _) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics-credential",
            Some(&ordinary_access),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let (status, _) = call_api(
            app.clone(),
            Method::POST,
            "/api/v1/admin/metrics-credential",
            Some(&ordinary_access),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);

        let (status, body) = call_api(
            app.clone(),
            Method::POST,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let issued = response_json(&body);
        assert_eq!(issued.as_object().unwrap().len(), 2);
        let first_credential = issued["credential"].as_str().unwrap().to_owned();
        assert!(first_credential.starts_with("atm_"));
        assert_eq!(first_credential.len(), 47);
        assert!(issued["created_at"].as_str().is_some());

        let stored_verifier: Vec<u8> = sqlx::query_scalar(
            "SELECT verifier FROM instance_metrics_credential WHERE credential_id=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(stored_verifier.len(), 32);
        assert_ne!(stored_verifier, first_credential.as_bytes());
        assert_eq!(
            stored_verifier,
            super::metrics_credential_verifier(&state, &first_credential)
                .unwrap()
                .to_vec()
        );

        let (status, body) = call_api_with_body(
            app.clone(),
            Method::POST,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
            b"{}",
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(response_json(&body)["error"]["code"], "INVALID_REQUEST");
        let (status, _) = call_api_with_body(
            app.clone(),
            Method::DELETE,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
            b"unexpected",
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, _) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&first_credential),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::OK,
            "rejected bodies must not change state"
        );

        let (status, body) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let status_text = String::from_utf8(body).unwrap();
        assert!(!status_text.contains(&first_credential));
        assert!(!status_text.contains(&hex::encode(&stored_verifier)));

        let (status, _) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&first_credential),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let (status, body) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/me",
            Some(&first_credential),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED, "{body:?}");
        let (status, _) = call_api(
            app.clone(),
            Method::GET,
            "/api/v1/admin/metrics-credential",
            Some(&first_credential),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        state.db.close().await;
        let mut restarted = crate::open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        Arc::make_mut(&mut restarted.config).admin_usernames =
            vec!["metrics-admin@example.test".to_owned()];
        let restarted_app = crate::router(restarted.clone()).await;
        let (status, _) = call_api(
            restarted_app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&first_credential),
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, body) = call_api(
            restarted_app.clone(),
            Method::POST,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let second_credential = response_json(&body)["credential"]
            .as_str()
            .unwrap()
            .to_owned();
        assert_ne!(first_credential, second_credential);
        let second_verifier: Vec<u8> = sqlx::query_scalar(
            "SELECT verifier FROM instance_metrics_credential WHERE credential_id=1",
        )
        .fetch_one(&restarted.db)
        .await
        .unwrap();
        let (status, _) = call_api(
            restarted_app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&first_credential),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) = call_api(
            restarted_app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&second_credential),
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (status, body) = call_api(
            restarted_app.clone(),
            Method::DELETE,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response_json(&body)["revoked"], true);
        let (status, _) = call_api(
            restarted_app.clone(),
            Method::GET,
            "/api/v1/admin/metrics",
            Some(&second_credential),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);

        let audit_rows = sqlx::query(
            "SELECT event_id,scope_type,scope_id,actor_user_id,actor_device_id,action, \
             resource_type,resource_id,result,occurred_at,source FROM audit_events \
             WHERE action IN ('admin.metrics_credential_rotated','admin.metrics_credential_revoked')",
        )
        .fetch_all(&restarted.db)
        .await
        .unwrap();
        assert_eq!(audit_rows.len(), 3);
        for row in &audit_rows {
            assert!(row.get::<Option<String>, _>("resource_id").is_none());
            let audit_fields = [
                row.get::<i64, _>("event_id").to_string(),
                row.get::<String, _>("scope_type"),
                row.get::<String, _>("scope_id"),
                row.get::<Option<String>, _>("actor_user_id")
                    .unwrap_or_default(),
                row.get::<Option<String>, _>("actor_device_id")
                    .unwrap_or_default(),
                row.get::<String, _>("action"),
                row.get::<String, _>("resource_type"),
                row.get::<String, _>("result"),
                row.get::<i64, _>("occurred_at").to_string(),
                row.get::<String, _>("source"),
            ]
            .join("|");
            assert!(!audit_fields.contains(&first_credential));
            assert!(!audit_fields.contains(&second_credential));
            assert!(!audit_fields.contains(&hex::encode(&stored_verifier)));
            assert!(!audit_fields.contains(&hex::encode(&second_verifier)));
        }
        let (status, body) = call_api(
            restarted_app,
            Method::GET,
            "/api/v1/admin/metrics-credential",
            Some(&admin_access),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(response_json(&body)["active"], false);

        restarted.db.close().await;
        fs::remove_dir_all(data_dir).unwrap();
    }

    struct RestoreDiscardFixture {
        state: crate::AppState,
        data_dir: PathBuf,
        archive_dir: PathBuf,
        archive_file: PathBuf,
        stage_dir: PathBuf,
        restore_job_id: String,
        archive_id: String,
        archive_sha256: String,
        owner_id: String,
        owner_device_id: String,
        owner_access: String,
        second_admin_access: String,
        member_access: String,
    }

    async fn seed_admin_session(
        state: &crate::AppState,
        username: &str,
    ) -> (String, String, String) {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("restore-discard-access-{}", Uuid::new_v4());
        let now = chrono::Utc::now();
        let created = now.to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(username)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'restore-discard-test','sign','encrypt',?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'restore-discard-family',?,?,?, ?,?)")
            .bind(session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(crate::sha256_hex(access.as_bytes()))
            .bind(format!("restore-discard-refresh-{}", Uuid::new_v4()))
            .bind((now + chrono::Duration::minutes(10)).to_rfc3339())
            .bind((now + chrono::Duration::days(30)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        (user_id, device_id, access)
    }

    fn bearer_headers(access: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {access}")).unwrap(),
        );
        headers
    }

    fn create_private_test_file(path: &PathBuf) -> fs::File {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        options.mode(0o600);
        options.open(path).unwrap()
    }

    fn assert_exact_restore_stage_files(stage_dir: &PathBuf) {
        let mut actual = fs::read_dir(stage_dir)
            .unwrap()
            .map(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .into_string()
                    .expect("stage entry names must be UTF-8")
            })
            .collect::<Vec<_>>();
        let mut expected = vec![
            ".atermius-restore-receipt.json".to_owned(),
            "atermius.db".to_owned(),
            "auth-rate-limit.key".to_owned(),
            "instance-ed25519.key".to_owned(),
        ];
        actual.sort();
        expected.sort();
        assert_eq!(actual, expected);
    }

    async fn restore_discard_fixture() -> RestoreDiscardFixture {
        let (mut state, data_dir) = test_state().await;
        let archive_dir = data_dir.with_file_name(format!(
            "{}-archives",
            data_dir.file_name().unwrap().to_string_lossy()
        ));
        crate::secure_file::create_private_data_dir(&archive_dir).unwrap();
        let key_file = archive_dir.join("backup.key");
        let _key = crate::secure_file::read_or_create_private_key(&key_file).unwrap();
        let source_root = "restore-discard-source-marker";
        let archive_id = Uuid::new_v4().to_string();
        let archive_file = archive_dir.join(format!("{archive_id}.atb"));
        let mut archive = create_private_test_file(&archive_file);
        archive.write_all(source_root.as_bytes()).unwrap();
        archive.sync_all().unwrap();
        drop(archive);
        {
            let config = Arc::make_mut(&mut state.config);
            config.backup_archive_dir = Some(archive_dir.clone());
            config.backup_key_file = Some(key_file);
            config.admin_usernames = vec![
                "restore-discard-owner@example.test".to_owned(),
                "restore-discard-second-admin@example.test".to_owned(),
            ];
        }
        let (owner_id, owner_device_id, owner_access) =
            seed_admin_session(&state, "restore-discard-owner@example.test").await;
        let (_, _, second_admin_access) =
            seed_admin_session(&state, "restore-discard-second-admin@example.test").await;
        let (_, _, member_access) =
            seed_admin_session(&state, "restore-discard-member@example.test").await;

        let restore_job_id = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let timestamp = crate::now_rfc3339();
        let archive_sha256 = "a".repeat(64);
        sqlx::query(
            "INSERT INTO instance_admin_jobs( \
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,archive_id, \
                archive_source,archive_sha256,status,requested_at,started_at,finished_at,result_code \
             ) VALUES(?,?,?,?,'restore',?, 'local',?,'succeeded',?,?,?,'completed')",
        )
        .bind(&restore_job_id)
        .bind(request_id)
        .bind(&owner_id)
        .bind(&owner_device_id)
        .bind(&archive_id)
        .bind(&archive_sha256)
        .bind(&timestamp)
        .bind(&timestamp)
        .bind(&timestamp)
        .execute(&state.db)
        .await
        .unwrap();

        let staging_root = archive_dir.join("restore-staging");
        crate::secure_file::create_private_data_dir(&staging_root).unwrap();
        let stage_dir = staging_root.join(format!("atermius-restore-{restore_job_id}"));
        crate::secure_file::create_private_data_dir(&stage_dir).unwrap();
        let stage_database = stage_dir.join("atermius.db");
        let mut stage_config = test_config(stage_dir.clone());
        stage_config.data_dir = stage_dir.clone();
        let stage_state = crate::open_state(
            &format!("sqlite://{}?mode=rwc", stage_database.display()),
            stage_config,
        )
        .await
        .unwrap();
        let generation = stage_state.instance.generation.clone();
        sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
            .fetch_all(&stage_state.db)
            .await
            .unwrap();
        stage_state.db.close().await;
        for sidecar in [
            stage_dir.join("atermius.db-wal"),
            stage_dir.join("atermius.db-shm"),
        ] {
            if sidecar.exists() {
                fs::remove_file(sidecar).unwrap();
            }
        }
        #[cfg(unix)]
        fs::set_permissions(&stage_database, fs::Permissions::from_mode(0o600)).unwrap();
        let receipt = serde_json::json!({
            "job_id": restore_job_id,
            "archive_id": archive_id,
            "archive_source": "local",
            "archive_sha256": archive_sha256,
            "generation": generation,
        });
        let mut receipt_file =
            create_private_test_file(&stage_dir.join(".atermius-restore-receipt.json"));
        receipt_file
            .write_all(&serde_json::to_vec(&receipt).unwrap())
            .unwrap();
        receipt_file.sync_all().unwrap();
        fs::File::open(&stage_dir).unwrap().sync_all().unwrap();
        sqlx::query(
            "INSERT INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
             VALUES(?,?,'ready',?)",
        )
        .bind(&restore_job_id)
        .bind(generation)
        .bind(timestamp)
        .execute(&state.db)
        .await
        .unwrap();

        RestoreDiscardFixture {
            state,
            data_dir,
            archive_dir,
            archive_file,
            stage_dir,
            restore_job_id,
            archive_id,
            archive_sha256,
            owner_id,
            owner_device_id,
            owner_access,
            second_admin_access,
            member_access,
        }
    }

    fn fast_retry_policy() -> super::AdminJobRetryPolicy {
        super::AdminJobRetryPolicy {
            initial_delay: Duration::from_millis(1),
            max_delay: Duration::from_millis(4),
        }
    }

    async fn discard_as(
        fixture: &RestoreDiscardFixture,
        access: &str,
        restore_job_id: &str,
        request_id: &str,
    ) -> Result<Json<Value>, crate::ApiError> {
        discard_restore_stage(
            State(fixture.state.clone()),
            bearer_headers(access),
            Path(restore_job_id.to_owned()),
            Ok(Json(DiscardRestoreStageRequest {
                request_id: request_id.to_owned(),
            })),
        )
        .await
    }

    async fn close_restore_discard_fixture(fixture: RestoreDiscardFixture) {
        fixture.state.db.close().await;
        fs::remove_dir_all(fixture.data_dir).unwrap();
        fs::remove_dir_all(fixture.archive_dir).unwrap();
    }

    #[test]
    fn restore_stage_discard_request_is_exact_and_uses_canonical_uuids() {
        let request_id = Uuid::new_v4().to_string();
        assert!(
            serde_json::from_value::<DiscardRestoreStageRequest>(serde_json::json!({
                "request_id": request_id,
            }))
            .is_ok()
        );
        assert!(
            serde_json::from_value::<DiscardRestoreStageRequest>(serde_json::json!({
                "request_id": Uuid::new_v4().to_string(),
                "path": "/tmp/anything",
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<DiscardRestoreStageRequest>(serde_json::json!({
                "request_id": 7,
            }))
            .is_err()
        );
        assert!(validate_admin_job_request_id(&request_id).is_ok());
        assert!(validate_admin_job_request_id(&request_id.to_uppercase()).is_err());
        assert!(validate_restore_job_id(&Uuid::new_v4().to_string()).is_ok());
        assert!(validate_restore_job_id(&Uuid::new_v4().to_string().to_uppercase()).is_err());
    }

    #[tokio::test]
    async fn legacy_restore_stage_backfill_verifies_without_touching_staging_siblings() {
        let fixture = restore_discard_fixture().await;
        let verified = crate::backup::validate_admin_restore_stage_for_discard(
            &fixture.state,
            &fixture.restore_job_id,
            &fixture.archive_id,
            crate::backup_replication::ArchiveSource::Local,
            &fixture.archive_sha256,
            None,
            false,
        )
        .await;
        assert!(
            verified.is_ok(),
            "the stage fixture must validate: {verified:?}"
        );
        assert_exact_restore_stage_files(&fixture.stage_dir);
        assert!(!fixture.stage_dir.join("atermius.db-wal").exists());
        assert!(!fixture.stage_dir.join("atermius.db-shm").exists());
        sqlx::query("DELETE FROM instance_admin_restore_stages WHERE restore_job_id=?")
            .bind(&fixture.restore_job_id)
            .execute(&fixture.state.db)
            .await
            .unwrap();

        let Json(before) = list_jobs(
            State(fixture.state.clone()),
            bearer_headers(&fixture.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(before["jobs"][0]["restore_stage_status"], "unverified");

        let staging_sibling = fixture.archive_dir.join("restore-staging").join(format!(
            "atermius-restore-{}.staging",
            fixture.restore_job_id
        ));
        crate::secure_file::create_private_data_dir(&staging_sibling).unwrap();
        let unknown_file = staging_sibling.join("operator-retained-file");
        fs::write(&unknown_file, b"keep untouched during legacy readback").unwrap();

        crate::admin::recover_interrupted_jobs(&fixture.state)
            .await
            .unwrap();

        let lifecycle_status: String = sqlx::query_scalar(
            "SELECT status FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&fixture.restore_job_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(lifecycle_status, "ready");
        assert_exact_restore_stage_files(&fixture.stage_dir);
        assert!(!fixture.stage_dir.join("atermius.db-wal").exists());
        assert!(!fixture.stage_dir.join("atermius.db-shm").exists());
        assert_eq!(
            fs::read(&unknown_file).unwrap(),
            b"keep untouched during legacy readback"
        );
        let Json(after) = list_jobs(
            State(fixture.state.clone()),
            bearer_headers(&fixture.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(after["jobs"][0]["restore_stage_status"], "ready");

        let Json(other_admin_view) = list_jobs(
            State(fixture.state.clone()),
            bearer_headers(&fixture.second_admin_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            other_admin_view["jobs"][0]["restore_stage_status"],
            Value::Null
        );
        close_restore_discard_fixture(fixture).await;

        let unverifiable = restore_discard_fixture().await;
        sqlx::query("DELETE FROM instance_admin_restore_stages WHERE restore_job_id=?")
            .bind(&unverifiable.restore_job_id)
            .execute(&unverifiable.state.db)
            .await
            .unwrap();
        fs::write(
            unverifiable
                .stage_dir
                .join(".atermius-restore-receipt.json"),
            b"{}",
        )
        .unwrap();
        crate::admin::recover_interrupted_jobs(&unverifiable.state)
            .await
            .unwrap();
        let lifecycle_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&unverifiable.restore_job_id)
        .fetch_one(&unverifiable.state.db)
        .await
        .unwrap();
        assert_eq!(lifecycle_count, 0);
        let Json(unverified_jobs) = list_jobs(
            State(unverifiable.state.clone()),
            bearer_headers(&unverifiable.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            unverified_jobs["jobs"][0]["restore_stage_status"],
            "unverified"
        );
        close_restore_discard_fixture(unverifiable).await;
    }

    #[tokio::test]
    async fn restore_stage_discard_authorizes_admin_and_original_job_owner() {
        let fixture = restore_discard_fixture().await;
        let request_id = Uuid::new_v4().to_string();

        let unauthenticated = discard_restore_stage(
            State(fixture.state.clone()),
            HeaderMap::new(),
            Path(fixture.restore_job_id.clone()),
            Ok(Json(DiscardRestoreStageRequest {
                request_id: request_id.clone(),
            })),
        )
        .await
        .unwrap_err();
        assert_eq!(unauthenticated.body.code, "AUTH_REQUIRED");

        let member = discard_as(
            &fixture,
            &fixture.member_access,
            &fixture.restore_job_id,
            &request_id,
        )
        .await
        .unwrap_err();
        assert_eq!(member.body.code, "INSTANCE_ADMIN_REQUIRED");

        let other_admin = discard_as(
            &fixture,
            &fixture.second_admin_access,
            &fixture.restore_job_id,
            &request_id,
        )
        .await
        .unwrap_err();
        assert_eq!(other_admin.body.code, "NOT_FOUND");

        let uppercase_job = discard_as(
            &fixture,
            &fixture.owner_access,
            &fixture.restore_job_id.to_uppercase(),
            &request_id,
        )
        .await
        .unwrap_err();
        assert_eq!(uppercase_job.body.code, "INVALID_RESTORE_JOB_ID");

        let uppercase_request = discard_as(
            &fixture,
            &fixture.owner_access,
            &fixture.restore_job_id,
            &request_id.to_uppercase(),
        )
        .await
        .unwrap_err();
        assert_eq!(uppercase_request.body.code, "INVALID_REQUEST_ID");
        assert!(fixture.stage_dir.exists());
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_stage_discarded'",
        )
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 0);
        close_restore_discard_fixture(fixture).await;
    }

    #[tokio::test]
    async fn restore_stage_discard_is_receipt_bound_atomic_and_idempotent() {
        let fixture = restore_discard_fixture().await;
        let live_generation = fixture.state.instance.generation.clone();
        let Json(before) = list_jobs(
            State(fixture.state.clone()),
            bearer_headers(&fixture.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(before["jobs"][0]["restore_stage_status"], "ready");
        assert_exact_restore_stage_files(&fixture.stage_dir);

        let first = discard_as(
            &fixture,
            &fixture.owner_access,
            &fixture.restore_job_id,
            &Uuid::new_v4().to_string(),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(first.as_object().unwrap().len(), 1);
        assert_eq!(first["restore_stage"].as_object().unwrap().len(), 3);
        assert_eq!(
            first["restore_stage"]["restore_job_id"],
            fixture.restore_job_id
        );
        assert_eq!(first["restore_stage"]["status"], "discarded");
        let discarded_at = first["restore_stage"]["discarded_at"].as_str().unwrap();
        chrono::DateTime::parse_from_rfc3339(discarded_at).unwrap();
        assert!(!fixture.stage_dir.exists());
        assert!(fixture.archive_file.exists());
        assert_eq!(
            fs::read(&fixture.archive_file).unwrap(),
            b"restore-discard-source-marker"
        );
        assert_eq!(fixture.state.instance.generation, live_generation);

        let Json(after) = list_jobs(
            State(fixture.state.clone()),
            bearer_headers(&fixture.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(after["jobs"][0]["restore_stage_status"], "discarded");

        for _ in 0..2 {
            let replay = discard_as(
                &fixture,
                &fixture.owner_access,
                &fixture.restore_job_id,
                &Uuid::new_v4().to_string(),
            )
            .await
            .unwrap()
            .0;
            assert_eq!(replay["restore_stage"]["discarded_at"], discarded_at);
            assert!(!replay.to_string().contains("restore-staging"));
        }
        let events = sqlx::query(
            "SELECT actor_user_id,actor_device_id,action,resource_type,resource_id,result,source \
             FROM audit_events WHERE action='admin.restore_stage_discarded'",
        )
        .fetch_all(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(
            events[0].get::<String, _>("actor_user_id"),
            fixture.owner_id
        );
        assert_eq!(
            events[0].get::<String, _>("actor_device_id"),
            fixture.owner_device_id
        );
        assert_eq!(events[0].get::<String, _>("resource_type"), "admin_job");
        assert_eq!(events[0].get::<String, _>("result"), "success");
        assert_eq!(events[0].get::<String, _>("source"), "api");
        let resource_id: String = events[0].get("resource_id");
        assert_ne!(resource_id, fixture.restore_job_id);
        assert_eq!(resource_id.len(), 64);
        assert!(resource_id.bytes().all(|byte| byte.is_ascii_hexdigit()));
        close_restore_discard_fixture(fixture).await;
    }

    #[tokio::test]
    async fn restore_stage_discard_rejects_and_preserves_preexisting_sqlite_sidecars() {
        let fixture = restore_discard_fixture().await;
        let sidecar_path = fixture.stage_dir.join("atermius.db-wal");
        let mut sidecar = create_private_test_file(&sidecar_path);
        sidecar.write_all(b"untrusted preexisting sidecar").unwrap();
        sidecar.sync_all().unwrap();
        drop(sidecar);

        let error = discard_as(
            &fixture,
            &fixture.owner_access,
            &fixture.restore_job_id,
            &Uuid::new_v4().to_string(),
        )
        .await
        .unwrap_err();
        assert_eq!(error.body.code, "RESTORE_STAGE_UNAVAILABLE");
        assert_eq!(
            fs::read(&sidecar_path).unwrap(),
            b"untrusted preexisting sidecar"
        );
        assert!(fixture.stage_dir.is_dir());
        let lifecycle_status: String = sqlx::query_scalar(
            "SELECT status FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&fixture.restore_job_id)
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(lifecycle_status, "ready");
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_stage_discarded'",
        )
        .fetch_one(&fixture.state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 0);
        close_restore_discard_fixture(fixture).await;
    }

    #[tokio::test]
    async fn restore_stage_discard_retries_partial_and_startup_crash_states() {
        let partial = restore_discard_fixture().await;
        sqlx::query(
            "UPDATE instance_admin_restore_stages SET status='discarding', \
                discard_requested_by_user_id=?,discard_requested_by_device_id=? \
             WHERE restore_job_id=?",
        )
        .bind(&partial.owner_id)
        .bind(&partial.owner_device_id)
        .bind(&partial.restore_job_id)
        .execute(&partial.state.db)
        .await
        .unwrap();
        let Json(discarding_jobs) = list_jobs(
            State(partial.state.clone()),
            bearer_headers(&partial.owner_access),
            axum::extract::Query(AdminJobListQuery {
                limit: None,
                offset: None,
            }),
        )
        .await
        .unwrap();
        assert_eq!(
            discarding_jobs["jobs"][0]["restore_stage_status"],
            "discarding"
        );
        fs::remove_file(partial.stage_dir.join("atermius.db")).unwrap();
        let partial_retry = discard_as(
            &partial,
            &partial.owner_access,
            &partial.restore_job_id,
            &Uuid::new_v4().to_string(),
        )
        .await
        .unwrap();
        assert_eq!(partial_retry.0["restore_stage"]["status"], "discarded");
        assert!(!partial.stage_dir.exists());
        let partial_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_stage_discarded'",
        )
        .fetch_one(&partial.state.db)
        .await
        .unwrap();
        assert_eq!(partial_events, 1);
        close_restore_discard_fixture(partial).await;

        let deferred = restore_discard_fixture().await;
        sqlx::query(
            "UPDATE instance_admin_restore_stages SET status='discarding', \
                discard_requested_by_user_id=?,discard_requested_by_device_id=? \
             WHERE restore_job_id=?",
        )
        .bind(&deferred.owner_id)
        .bind(&deferred.owner_device_id)
        .bind(&deferred.restore_job_id)
        .execute(&deferred.state.db)
        .await
        .unwrap();
        fs::write(
            deferred.stage_dir.join("unknown-retained-file"),
            b"must remain untouched",
        )
        .unwrap();
        crate::admin::recover_interrupted_jobs(&deferred.state)
            .await
            .unwrap();
        let pending_status: String = sqlx::query_scalar(
            "SELECT status FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&deferred.restore_job_id)
        .fetch_one(&deferred.state.db)
        .await
        .unwrap();
        assert_eq!(pending_status, "discarding");
        assert_eq!(
            fs::read(deferred.stage_dir.join("unknown-retained-file")).unwrap(),
            b"must remain untouched"
        );

        let second_database_url = format!(
            "sqlite://{}/atermius.db?mode=rwc",
            deferred.data_dir.display()
        );
        let second_state =
            crate::open_state(&second_database_url, (*deferred.state.config).clone())
                .await
                .unwrap();
        let held_lock = crate::acquire_instance_maintenance_lock(&deferred.state)
            .await
            .unwrap();
        crate::admin::recover_interrupted_jobs(&second_state)
            .await
            .unwrap();
        let still_pending: String = sqlx::query_scalar(
            "SELECT status FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&deferred.restore_job_id)
        .fetch_one(&second_state.db)
        .await
        .unwrap();
        assert_eq!(still_pending, "discarding");
        drop(held_lock);
        fs::remove_file(deferred.stage_dir.join("unknown-retained-file")).unwrap();
        crate::admin::recover_interrupted_jobs(&second_state)
            .await
            .unwrap();
        let completed: String = sqlx::query_scalar(
            "SELECT status FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&deferred.restore_job_id)
        .fetch_one(&second_state.db)
        .await
        .unwrap();
        assert_eq!(completed, "discarded");
        second_state.db.close().await;
        close_restore_discard_fixture(deferred).await;

        let crashed = restore_discard_fixture().await;
        sqlx::query(
            "UPDATE instance_admin_restore_stages SET status='discarding', \
                discard_requested_by_user_id=?,discard_requested_by_device_id=? \
             WHERE restore_job_id=?",
        )
        .bind(&crashed.owner_id)
        .bind(&crashed.owner_device_id)
        .bind(&crashed.restore_job_id)
        .execute(&crashed.state.db)
        .await
        .unwrap();
        // Models process death after the exact stage directory has been
        // removed and fsynced but before the final state/audit transaction.
        fs::remove_dir_all(&crashed.stage_dir).unwrap();
        crate::admin::recover_interrupted_jobs(&crashed.state)
            .await
            .unwrap();
        let state: (String, Option<String>) = sqlx::query_as(
            "SELECT status,discarded_at FROM instance_admin_restore_stages WHERE restore_job_id=?",
        )
        .bind(&crashed.restore_job_id)
        .fetch_one(&crashed.state.db)
        .await
        .unwrap();
        assert_eq!(state.0, "discarded");
        assert!(state.1.is_some());
        let crash_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_stage_discarded' \
             AND actor_user_id=? AND actor_device_id=?",
        )
        .bind(&crashed.owner_id)
        .bind(&crashed.owner_device_id)
        .fetch_one(&crashed.state.db)
        .await
        .unwrap();
        assert_eq!(crash_events, 1);
        crate::admin::recover_interrupted_jobs(&crashed.state)
            .await
            .unwrap();
        let repeated_crash_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_stage_discarded' \
             AND actor_user_id=? AND actor_device_id=?",
        )
        .bind(&crashed.owner_id)
        .bind(&crashed.owner_device_id)
        .fetch_one(&crashed.state.db)
        .await
        .unwrap();
        assert_eq!(repeated_crash_events, 1);
        close_restore_discard_fixture(crashed).await;
    }

    #[test]
    fn fixed_job_requests_are_exact_and_use_canonical_uuid() {
        let request_id = Uuid::new_v4().to_string();
        let parsed: CreateAdminJobRequest = serde_json::from_value(serde_json::json!({
            "request_id": request_id.clone(),
            "action": "maintenance"
        }))
        .unwrap();
        assert_eq!(parsed.action.as_str(), "maintenance");
        assert!(validate_admin_job_request_id(&parsed.request_id).is_ok());

        let backup: CreateAdminJobRequest = serde_json::from_value(serde_json::json!({
            "request_id": request_id.clone(),
            "action": "backup"
        }))
        .unwrap();
        assert_eq!(backup.action.as_str(), "backup");

        let archive_id = Uuid::new_v4().to_string();
        let restore: CreateAdminJobRequest = serde_json::from_value(serde_json::json!({
            "request_id": request_id.clone(),
            "action": "restore",
            "archive_id": archive_id,
            "archive_source": "local",
        }))
        .unwrap();
        assert_eq!(restore.action.as_str(), "restore");
        let super::ArchiveIdField::Present(Some(restore_archive_id)) = restore.archive_id else {
            panic!("restore archive id must be present");
        };
        assert!(super::validate_admin_archive_id(&restore_archive_id).is_ok());

        for malformed in [
            serde_json::json!({"request_id": request_id.clone(), "action": "maintenance", "path": "/tmp/out"}),
            serde_json::json!({"request_id": request_id.clone()}),
        ] {
            assert!(serde_json::from_value::<CreateAdminJobRequest>(malformed).is_err());
        }
        let restore_without_archive: CreateAdminJobRequest = serde_json::from_value(
            serde_json::json!({"request_id": request_id.clone(), "action": "restore"}),
        )
        .unwrap();
        assert!(
            validate_action_archive(
                restore_without_archive.action,
                &restore_without_archive.archive_id,
                &restore_without_archive.archive_source,
            )
            .is_err()
        );
        let restore_null_archive: CreateAdminJobRequest = serde_json::from_value(
            serde_json::json!({"request_id": request_id.clone(), "action": "restore", "archive_id": null, "archive_source": "local"}),
        )
        .unwrap();
        assert!(
            validate_action_archive(
                restore_null_archive.action,
                &restore_null_archive.archive_id,
                &restore_null_archive.archive_source,
            )
            .is_err()
        );
        assert!(
            validate_action_archive(
                AdminJobAction::Backup,
                &ArchiveIdField::Present(None),
                &ArchiveSourceField::Missing,
            )
            .is_err()
        );
        assert!(
            validate_action_archive(
                AdminJobAction::Restore,
                &ArchiveIdField::Present(Some(Uuid::new_v4().to_string())),
                &ArchiveSourceField::Missing,
            )
            .is_err()
        );
        let uppercase = request_id.to_uppercase();
        assert!(validate_admin_job_request_id(&uppercase).is_err());
    }

    #[tokio::test]
    async fn migration_allows_only_one_active_job_across_actions() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();

        let first_id = Uuid::new_v4().to_string();
        let first_request = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let second_request = Uuid::new_v4().to_string();
        let requested_at = crate::now_rfc3339();

        insert_queued_job(&pool, &first_id, &first_request, &requested_at)
            .await
            .unwrap();
        assert!(
            insert_queued_job_action(
                &pool,
                &second_id,
                &second_request,
                &requested_at,
                super::AdminJobAction::Backup,
            )
            .await
            .is_err()
        );
        sqlx::query(
            "UPDATE instance_admin_jobs SET status='succeeded',started_at=?,finished_at=?,result_code='completed' WHERE job_id=?",
        )
        .bind(&requested_at)
        .bind(&requested_at)
        .bind(&first_id)
        .execute(&pool)
        .await
        .unwrap();
        insert_queued_job_action(
            &pool,
            &second_id,
            &second_request,
            &requested_at,
            super::AdminJobAction::Backup,
        )
        .await
        .unwrap();
        pool.close().await;
    }

    #[tokio::test]
    async fn migration_constrains_restore_source_and_private_digest_fields() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!("./migrations").run(&pool).await.unwrap();
        let requested_at = crate::now_rfc3339();
        let invalid_restore_id = Uuid::new_v4().to_string();
        let invalid_restore_request = Uuid::new_v4().to_string();
        assert!(sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,requested_at
             ) VALUES(?,?,?,?,'restore','queued',?)",
        )
        .bind(&invalid_restore_id)
        .bind(&invalid_restore_request)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(&requested_at)
        .execute(&pool)
        .await
        .is_err());

        let restore_id = Uuid::new_v4().to_string();
        let restore_request = Uuid::new_v4().to_string();
        let archive_id = Uuid::new_v4().to_string();
        let requester = insert_queued_job_action(
            &pool,
            &restore_id,
            &restore_request,
            &requested_at,
            super::AdminJobAction::Restore,
        )
        .await
        .unwrap();
        sqlx::query("UPDATE instance_admin_jobs SET archive_id=? WHERE job_id=?")
            .bind(&archive_id)
            .bind(&restore_id)
            .execute(&pool)
            .await
            .unwrap();
        assert!(
            sqlx::query("UPDATE instance_admin_jobs SET archive_sha256='bad' WHERE job_id=?")
                .bind(&restore_id)
                .execute(&pool)
                .await
                .is_err()
        );

        let started_at = crate::now_rfc3339();
        sqlx::query(
            "UPDATE instance_admin_jobs SET status='running',started_at=?,archive_sha256=? WHERE job_id=?",
        )
        .bind(&started_at)
        .bind("a".repeat(64))
        .bind(&restore_id)
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "UPDATE instance_admin_jobs SET status='succeeded',finished_at=?,result_code='completed' WHERE job_id=?",
        )
        .bind(crate::now_rfc3339())
        .bind(&restore_id)
        .execute(&pool)
        .await
        .unwrap();
        assert_eq!(requester.action, super::AdminJobAction::Restore);
        pool.close().await;
    }

    #[tokio::test]
    async fn maintenance_pass_waits_for_the_shared_app_state_mutex() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-maintenance-lock-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        let guard = state.maintenance_lock.lock().await;
        let task_state = state.clone();
        let mut task = tokio::spawn(async move { crate::run_maintenance(&task_state).await });
        assert!(
            tokio::time::timeout(Duration::from_millis(20), &mut task)
                .await
                .is_err(),
            "manual maintenance must wait while another process-local pass owns the lock"
        );
        drop(guard);
        task.await.unwrap().unwrap();
        state.db.close().await;
        fs::remove_dir_all(data_dir).unwrap();
    }

    #[tokio::test]
    async fn start_persistence_retries_db_audit_and_lost_commit_ack_without_duplicate_audit() {
        use super::{AdminJobFaultInjector, AdminJobFaultPoint, persist_admin_job_started};

        let (state, data_dir) = test_state().await;
        let job_id = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let requested_at = crate::now_rfc3339();
        let requester = insert_queued_job(&state.db, &job_id, &request_id, &requested_at)
            .await
            .unwrap();
        let faults = AdminJobFaultInjector::failing(&[
            (AdminJobFaultPoint::StartBegin, 1),
            (AdminJobFaultPoint::StartUpdate, 1),
            (AdminJobFaultPoint::StartAudit, 1),
            (AdminJobFaultPoint::StartCommitAck, 1),
        ]);

        let started = persist_admin_job_started(&state, &job_id, &faults, fast_retry_policy())
            .await
            .expect("transient storage errors must not abandon the queued job");
        assert_eq!(started.user_id, requester.user_id);
        assert!(faults.has_remaining_failures());
        let status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(status, "running");
        let started_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.maintenance_started'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(started_events, 1, "retry must not duplicate start audit");

        state.db.close().await;
        fs::remove_dir_all(data_dir).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn backup_archive_is_not_recreated_when_terminal_persistence_retries() {
        use super::{
            AdminJobAction, AdminJobFaultInjector, AdminJobFaultPoint,
            execute_admin_job_with_policy,
        };
        use std::os::unix::fs::PermissionsExt;

        let root =
            std::env::temp_dir().join(format!("atermius-admin-backup-retry-{}", Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let data_dir = root.join("data");
        let archive_dir = root.join("archives");
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        fs::write(&key_file, [0x37_u8; 32]).unwrap();
        fs::set_permissions(&key_file, fs::Permissions::from_mode(0o600)).unwrap();
        let mut config = test_config(data_dir.clone());
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file);
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();

        let job_id = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let requested_at = crate::now_rfc3339();
        insert_queued_job_action(
            &state.db,
            &job_id,
            &request_id,
            &requested_at,
            AdminJobAction::Backup,
        )
        .await
        .unwrap();
        let faults = AdminJobFaultInjector::failing(&[
            (AdminJobFaultPoint::TerminalBegin, 1),
            (AdminJobFaultPoint::TerminalUpdate, 1),
            (AdminJobFaultPoint::TerminalAudit, 1),
            (AdminJobFaultPoint::TerminalCommitAck, 1),
        ]);

        execute_admin_job_with_policy(&state, &job_id, &faults, fast_retry_policy()).await;

        assert!(faults.has_remaining_failures());
        let terminal =
            sqlx::query("SELECT status,result_code FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(terminal.get::<String, _>("status"), "succeeded");
        assert_eq!(terminal.get::<String, _>("result_code"), "completed");
        assert_eq!(fs::read_dir(&archive_dir).unwrap().count(), 1);
        let completed_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.backup_completed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(completed_events, 1);

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn terminal_persistence_retries_db_audit_and_commit_then_records_failure_result() {
        use super::{
            AdminJobFaultInjector, AdminJobFaultPoint, persist_admin_job_started,
            persist_admin_job_terminal,
        };

        let (state, data_dir) = test_state().await;
        let job_id = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let requested_at = crate::now_rfc3339();
        let requester = insert_queued_job(&state.db, &job_id, &request_id, &requested_at)
            .await
            .unwrap();
        let no_faults = AdminJobFaultInjector::default();
        persist_admin_job_started(&state, &job_id, &no_faults, fast_retry_policy())
            .await
            .unwrap();

        let faults = AdminJobFaultInjector::failing(&[
            (AdminJobFaultPoint::TerminalBegin, 1),
            (AdminJobFaultPoint::TerminalUpdate, 1),
            (AdminJobFaultPoint::TerminalAudit, 1),
            (AdminJobFaultPoint::TerminalCommitAck, 1),
        ]);
        persist_admin_job_terminal(
            &state,
            &job_id,
            &requester,
            false,
            &faults,
            fast_retry_policy(),
        )
        .await;

        assert!(faults.has_remaining_failures());
        let row = sqlx::query("SELECT status,result_code FROM instance_admin_jobs WHERE job_id=?")
            .bind(&job_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(row.get::<String, _>("status"), "failed");
        assert_eq!(row.get::<String, _>("result_code"), "maintenance_failed");
        let failed_result: String = sqlx::query_scalar(
            "SELECT result FROM audit_events WHERE action='admin.maintenance_failed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_result, "failure");
        let failed_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.maintenance_failed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_events, 1, "retry must not duplicate failure audit");

        let backup_job_id = Uuid::new_v4().to_string();
        let backup_request_id = Uuid::new_v4().to_string();
        let backup_requester = insert_queued_job_action(
            &state.db,
            &backup_job_id,
            &backup_request_id,
            &requested_at,
            super::AdminJobAction::Backup,
        )
        .await
        .unwrap();
        persist_admin_job_started(&state, &backup_job_id, &no_faults, fast_retry_policy())
            .await
            .unwrap();
        persist_admin_job_terminal(
            &state,
            &backup_job_id,
            &backup_requester,
            false,
            &no_faults,
            fast_retry_policy(),
        )
        .await;
        let backup_row =
            sqlx::query("SELECT status,result_code FROM instance_admin_jobs WHERE job_id=?")
                .bind(&backup_job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(backup_row.get::<String, _>("status"), "failed");
        assert_eq!(backup_row.get::<String, _>("result_code"), "backup_failed");
        let backup_failure: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.backup_failed' AND result='failure'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(backup_failure, 1);

        let interrupted_id = Uuid::new_v4().to_string();
        let interrupted_request = Uuid::new_v4().to_string();
        let _ = insert_queued_job(
            &state.db,
            &interrupted_id,
            &interrupted_request,
            &requested_at,
        )
        .await
        .unwrap();
        sqlx::query("UPDATE instance_admin_jobs SET status='running',started_at=? WHERE job_id=?")
            .bind(&requested_at)
            .bind(&interrupted_id)
            .execute(&state.db)
            .await
            .unwrap();
        super::recover_interrupted_jobs(&state).await.unwrap();
        let interrupted_result: String = sqlx::query_scalar(
            "SELECT result FROM audit_events WHERE action='admin.maintenance_interrupted'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(interrupted_result, "failure");

        state.db.close().await;
        fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn backup_schedule_request_requires_one_nullable_bounded_interval() {
        assert_eq!(
            super::parse_backup_schedule_request(&serde_json::json!({"interval_hours": null}))
                .unwrap(),
            None
        );
        assert_eq!(
            super::parse_backup_schedule_request(&serde_json::json!({"interval_hours": 1}))
                .unwrap(),
            Some(1)
        );
        assert_eq!(
            super::parse_backup_schedule_request(&serde_json::json!({"interval_hours": 720}))
                .unwrap(),
            Some(720)
        );
        for body in [
            serde_json::json!({}),
            serde_json::json!({"interval_hours": 1, "unknown": true}),
            serde_json::json!({"interval_hours": "24"}),
            serde_json::json!({"interval_hours": 1.5}),
        ] {
            assert_eq!(
                super::parse_backup_schedule_request(&body)
                    .unwrap_err()
                    .body
                    .code,
                "INVALID_BACKUP_SCHEDULE_REQUEST"
            );
        }
        for hours in [0, 721, -1] {
            assert_eq!(
                super::parse_backup_schedule_request(&serde_json::json!({"interval_hours": hours}))
                    .unwrap_err()
                    .body
                    .code,
                "INVALID_BACKUP_INTERVAL"
            );
        }
    }

    #[tokio::test]
    async fn backup_schedule_response_exposes_private_config_boolean_and_durable_last_run() {
        let (state, data_dir) = test_state().await;
        let mut tx = state.db.begin().await.unwrap();
        let empty = super::backup_schedule_response(&state, &mut tx)
            .await
            .unwrap();
        assert_eq!(
            empty,
            serde_json::json!({
                "operation": "backup_schedule",
                "backup_configured": false,
                "interval_hours": null,
                "next_run_at": null,
                "last_run": null,
            })
        );
        tx.commit().await.unwrap();

        let run_id = Uuid::new_v4().to_string();
        let now = chrono::Utc::now().timestamp();
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=24,next_run_at=? WHERE schedule_id=1",
        )
        .bind(now + 86_400)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(\
             run_id,scheduled_for,started_at,finished_at,status,result_code,migration_version,archive_bytes\
             ) VALUES(?,?,?,?,'succeeded','completed',27,4096)",
        )
        .bind(&run_id)
        .bind(now - 1)
        .bind(now - 1)
        .bind(now)
        .execute(&state.db)
        .await
        .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        let configured = super::backup_schedule_response(&state, &mut tx)
            .await
            .unwrap();
        assert_eq!(configured["backup_configured"], false);
        assert_eq!(configured["interval_hours"], 24);
        assert!(configured["next_run_at"].as_str().is_some());
        assert_eq!(configured["last_run"]["run_id"], run_id);
        assert_eq!(configured["last_run"]["status"], "succeeded");
        assert_eq!(configured["last_run"]["archive_bytes"], 4096);
        assert_eq!(
            configured["last_run"]["scheduled_for"],
            super::backup_schedule_timestamp(now - 1).unwrap()
        );
        tx.commit().await.unwrap();
        state.db.close().await;
        fs::remove_dir_all(data_dir).unwrap();
    }

    #[test]
    fn account_invitation_request_is_strict_and_status_precedence_is_stable() {
        let request: super::CreateAdminAccountInvitationRequest =
            serde_json::from_value(serde_json::json!({
                "username": "person@example.test",
                "expires_in_seconds": 60,
            }))
            .unwrap();
        assert_eq!(request.username, "person@example.test");
        assert_eq!(request.expires_in_seconds, Some(60));
        let default_ttl: super::CreateAdminAccountInvitationRequest =
            serde_json::from_value(serde_json::json!({"username": "person@example.test"})).unwrap();
        assert_eq!(default_ttl.expires_in_seconds, None);
        for malformed in [
            serde_json::json!({"username": "person@example.test", "unknown": true}),
            serde_json::json!({"username": "person@example.test", "expires_in_seconds": "60"}),
            serde_json::json!({"username": "person@example.test", "expires_in_seconds": 60.5}),
            serde_json::json!({"username": "person@example.test", "expires_in_seconds": null}),
            serde_json::json!({"expires_in_seconds": 60}),
        ] {
            assert!(
                serde_json::from_value::<super::CreateAdminAccountInvitationRequest>(malformed)
                    .is_err()
            );
        }

        let now = chrono::DateTime::<chrono::Utc>::from_timestamp(1_800_000_000, 0).unwrap();
        let future = (now + chrono::Duration::seconds(60)).to_rfc3339();
        let past = (now - chrono::Duration::seconds(60)).to_rfc3339();
        assert_eq!(
            super::account_invitation_status(&future, None, None, now).unwrap(),
            "pending"
        );
        assert_eq!(
            super::account_invitation_status(&past, None, None, now).unwrap(),
            "expired"
        );
        assert_eq!(
            super::account_invitation_status(&future, Some("consumed"), None, now).unwrap(),
            "consumed"
        );
        assert_eq!(
            super::account_invitation_status(&past, None, Some("revoked"), now).unwrap(),
            "revoked"
        );
        assert_eq!(
            super::account_invitation_status(&future, Some("consumed"), Some("revoked"), now,)
                .unwrap(),
            "consumed"
        );
        assert!(super::account_invitation_status("invalid", None, None, now).is_err());
    }
}

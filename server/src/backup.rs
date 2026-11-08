//! Encrypted, versioned instance backup and fail-closed restore staging.
//!
//! The archive is deliberately a small framed format instead of tar/zip: it
//! has no archive-controlled paths and only accepts the fixed files below.

use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    process::Stdio,
    str::FromStr,
};

use base64::Engine;
use chacha20poly1305::{KeyInit, XChaCha20Poly1305, XNonce, aead::AeadInPlace};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{
    Connection, PgConnection, PgPool, Postgres, Row, SqlitePool, Transaction,
    postgres::{PgConnectOptions, PgPoolOptions},
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::{ApiError, AppState, AuthRateLimits, Config, acquire_runtime_lock, secure_file};

const MAGIC: &[u8; 16] = b"ATERMIUS-BACKUP\0";
const FORMAT_VERSION: u16 = 1;
const CHUNK_BYTES: usize = 1024 * 1024;
const AEAD_TAG_BYTES: usize = 16;
const MAX_MANIFEST_BYTES: usize = 64 * 1024;
pub(crate) const MAX_BACKUP_ARCHIVE_BYTES: u64 = 1 << 40;
const MAX_FILE_BYTES: u64 = MAX_BACKUP_ARCHIVE_BYTES;
const RUNTIME_POLICY_VERSION: u16 = 5;
const MANIFEST_AAD: &[u8] = b"atermius/instance-backup/manifest/v1\0";
const FILE_AAD: &[u8] = b"atermius/instance-backup/chunk/v1\0";
const ALLOWED_FILES: [&str; 3] = [
    "auth-rate-limit.key",
    "database.sqlite",
    "instance-ed25519.key",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BackupManifest {
    format_version: u16,
    app_version: String,
    created_at: String,
    database_engine: String,
    journal_mode: String,
    migration_version: i64,
    runtime_policy: RuntimePolicySummary,
    files: Vec<BackupFile>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RuntimePolicySummary {
    /// Zero identifies pre-runtime-policy-version archives. Such archives do
    /// not contain the complete policy set and require an explicit override.
    #[serde(default)]
    policy_version: u16,
    registration_open: bool,
    relay_enabled: bool,
    #[serde(default)]
    terminal_collaboration_enabled: bool,
    relay_allow_cidrs: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    relay_allow_ports: Vec<u16>,
    relay_max_connections_per_user: usize,
    #[serde(default)]
    public_origin: Option<String>,
    #[serde(default)]
    web_dir: Option<String>,
    max_object_bytes: i64,
    max_request_bytes: usize,
    history_retention_days: i64,
    #[serde(default = "default_record_restore_retention_days")]
    record_restore_retention_days: i64,
    vault_deletion_grace_seconds: i64,
    account_deletion_grace_seconds: i64,
    audit_retention_days: i64,
    object_gc_grace_seconds: i64,
    #[serde(default)]
    admin_usernames: Vec<String>,
    auth_rate_limits: AuthRateLimitsSummary,
}

fn default_record_restore_retention_days() -> i64 {
    30
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AuthRateLimitsSummary {
    window_seconds: i64,
    login_user_limit: i64,
    login_pair_limit: i64,
    login_ip_limit: i64,
    prelogin_user_limit: i64,
    prelogin_pair_limit: i64,
    prelogin_ip_limit: i64,
    register_user_limit: i64,
    register_pair_limit: i64,
    register_ip_limit: i64,
    #[serde(default)]
    recovery_start_user_limit: i64,
    #[serde(default)]
    recovery_start_pair_limit: i64,
    #[serde(default)]
    recovery_start_ip_limit: i64,
    #[serde(default)]
    recovery_complete_user_limit: i64,
    #[serde(default)]
    recovery_complete_pair_limit: i64,
    #[serde(default)]
    recovery_complete_ip_limit: i64,
    #[serde(default = "default_max_active_recovery_challenges")]
    max_active_recovery_challenges: i64,
}

fn default_max_active_recovery_challenges() -> i64 {
    crate::DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BackupFile {
    name: String,
    size: u64,
    sha256: String,
}

struct SourceFile {
    name: String,
    path: PathBuf,
}

pub(crate) const PG_BACKUP_SCHEMA_VERSION: i64 = 39;
const MIN_SUPPORTED_PG_ARCHIVE_SCHEMA_VERSION: i64 = 25;
const PG_BACKUP_SCHEDULE_MIGRATION: &str =
    include_str!("../migrations/postgres/0026_instance_backup_schedule.sql");
const PG_SHARED_RELAY_MIGRATION: &str =
    include_str!("../migrations/postgres/0027_shared_ssh_relay.sql");
const PG_RESTORE_STAGE_DISCARD_MIGRATION: &str =
    include_str!("../migrations/postgres/0028_restore_stage_discard.sql");
const PG_REDACTION_CAPABILITY_MIGRATION: &str =
    include_str!("../migrations/postgres/0029_redaction_capability_reports.sql");
const PG_RECORD_REDACTION_MIGRATION: &str =
    include_str!("../migrations/postgres/0030_record_redactions.sql");
const PG_REDACTED_CONFLICT_RESOLUTION_MIGRATION: &str =
    include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql");
const PG_RECORD_RESTORE_DEADLINES_MIGRATION: &str =
    include_str!("../migrations/postgres/0032_record_restore_deadlines.sql");
const PG_RECORD_AUTO_PURGE_MIGRATION: &str =
    include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql");
const PG_RECORD_AUTO_PURGE_SCAN_MIGRATION: &str =
    include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql");
const PG_ADMIN_METRICS_CREDENTIAL_MIGRATION: &str =
    include_str!("../migrations/postgres/0035_instance_metrics_credential.sql");
const PG_BACKUP_REPLICATION_MIGRATION: &str =
    include_str!("../migrations/postgres/0036_instance_backup_replications.sql");
const PG_BACKUP_REPLICATION_LEASE_MIGRATION: &str =
    include_str!("../migrations/postgres/0037_instance_backup_replication_leases.sql");
const PG_REPLICA_RESTORE_MIGRATION: &str =
    include_str!("../migrations/postgres/0038_replica_restore_sources.sql");
const PG_PUSH_DELIVERY_DAILY_MIGRATION: &str =
    include_str!("../migrations/postgres/0039_mobile_push_delivery_daily.sql");
const PG_RESTORE_CONTROL_SCHEMA: &str = "atermius_restore_control";
const PG_RESTORE_CONTROL_TABLE: &str = "stage_binding";

fn supported_pg_archive_schema_version(version: i64) -> bool {
    (MIN_SUPPORTED_PG_ARCHIVE_SCHEMA_VERSION..=PG_BACKUP_SCHEMA_VERSION).contains(&version)
}
const PG_BACKUP_PIN_LEASE_SECONDS: i64 = 60 * 60;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PgArchiveObject {
    vault_id: String,
    object_id: String,
    storage_backend: String,
    storage_key: String,
    storage_store_id: String,
    size: i64,
    sha256: String,
    archive_file: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PgArchiveMetadata {
    format_version: u16,
    schema: String,
    pg_dump_version: String,
    server_version_num: i32,
    object_store_id: String,
    objects: Vec<PgArchiveObject>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PgRestoreStageReceipt {
    format_version: u16,
    job_id: String,
    archive_id: String,
    archive_sha256: String,
    generation: String,
    schema: String,
    object_store_id: String,
    restored_objects: usize,
    binding_id: String,
    target_fingerprint: String,
    target_database_oid: i64,
    target_database_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PgRestoreStageBinding {
    pub(crate) binding_id: String,
    pub(crate) target_fingerprint: String,
    pub(crate) target_database_oid: i64,
    pub(crate) target_database_name: String,
    pub(crate) schema: String,
    pub(crate) object_store_id: String,
    pub(crate) restored_objects: i64,
}

struct PgBackupPinCleanup {
    repository: crate::pg_objects::PgObjectRepository,
    backup_id: String,
    released: bool,
}

impl PgBackupPinCleanup {
    async fn release(mut self) -> Result<(), ApiError> {
        self.repository.release_backup_pins(&self.backup_id).await?;
        self.released = true;
        Ok(())
    }
}

impl Drop for PgBackupPinCleanup {
    fn drop(&mut self) {
        if self.released {
            return;
        }
        let repository = self.repository.clone();
        let backup_id = self.backup_id.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                if repository.release_backup_pins(&backup_id).await.is_err() {
                    tracing::warn!("PostgreSQL backup pin cleanup deferred until lease expiry");
                }
            });
        }
    }
}

struct TempDirectory(PathBuf);

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoreResult {
    pub generation: String,
    pub accepted_runtime_policy_drift_fields: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupVerification {
    pub migration_version: i64,
    pub file_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BackupSummary {
    pub migration_version: i64,
    pub archive_bytes: u64,
    pub archive_sha256: String,
}

#[derive(Debug, Clone)]
pub(crate) struct ConfiguredBackupPaths {
    pub archive_dir: PathBuf,
    pub key_file: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct RestoreArchiveSource {
    pub archive_id: String,
    pub created_at: String,
    pub archive_bytes: u64,
    pub origin: &'static str,
    pub source: &'static str,
}

#[derive(Debug, Clone)]
struct RestoreArchiveCandidate {
    source: RestoreArchiveSource,
    expected_timestamp: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RestoreStageReceipt {
    job_id: String,
    archive_id: String,
    archive_source: String,
    archive_sha256: String,
    generation: String,
    /// Absent only on stages created before activation required a second
    /// runtime-policy check. Such stages remain readable for discard/recovery
    /// but cannot be installed by the offline activation CLI.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime_policy_sha256: Option<String>,
}

const RESTORE_STAGE_RECEIPT_FILE: &str = ".atermius-restore-receipt.json";
const RESTORE_STAGE_DATA_FILES: [&str; 3] =
    ["atermius.db", "auth-rate-limit.key", "instance-ed25519.key"];

#[derive(Debug, Clone, PartialEq, Eq)]
struct ScheduledBackupRunClaim {
    run_id: String,
    scheduled_for: i64,
    started_at: i64,
}

const MIN_BACKUP_INTERVAL_HOURS: i64 = 1;
const MAX_BACKUP_INTERVAL_HOURS: i64 = 720;
pub(crate) const SCHEDULED_BACKUP_POLL_SECONDS: u64 = 30;

pub(crate) fn backup_interval_seconds(interval_hours: i64) -> Result<i64, ApiError> {
    if !(MIN_BACKUP_INTERVAL_HOURS..=MAX_BACKUP_INTERVAL_HOURS).contains(&interval_hours) {
        return Err(ApiError::bad_request(
            "INVALID_BACKUP_INTERVAL",
            "interval_hours must be between 1 and 720",
        ));
    }
    interval_hours
        .checked_mul(60 * 60)
        .ok_or_else(|| ApiError::internal("backup schedule interval overflowed"))
}

fn next_scheduled_backup_due(
    scheduled_for: i64,
    interval_seconds: i64,
    now: i64,
) -> Result<i64, ApiError> {
    if interval_seconds <= 0 || now < scheduled_for {
        return Err(ApiError::internal("backup schedule due time is invalid"));
    }
    let elapsed = now - scheduled_for;
    let elapsed_intervals = elapsed / interval_seconds + 1;
    let advance = elapsed_intervals
        .checked_mul(interval_seconds)
        .ok_or_else(|| ApiError::internal("backup schedule due time overflowed"))?;
    scheduled_for
        .checked_add(advance)
        .ok_or_else(|| ApiError::internal("backup schedule due time overflowed"))
}

/// Resolves and validates the optional operator settings used by the
/// allowlisted backup job. All failures are returned as generic internal
/// errors; API callers map them to one fixed configuration response so paths
/// and filesystem details never cross the network boundary.
pub(crate) fn configured_backup_paths(config: &Config) -> Result<ConfiguredBackupPaths, ApiError> {
    config
        .validated_backup_retention_count()
        .map_err(ApiError::internal)?;
    let archive_dir = config
        .backup_archive_dir
        .as_deref()
        .ok_or_else(|| ApiError::internal("backup is not configured"))?;
    let key_file = config
        .backup_key_file
        .as_deref()
        .ok_or_else(|| ApiError::internal("backup is not configured"))?;

    secure_file::secure_existing_data_dir(&config.data_dir)?;
    let archive_dir = secure_owner_only_archive_dir(&config.data_dir, archive_dir)?;
    ensure_path_outside_data_dir(&config.data_dir, key_file)?;
    let _key = Zeroizing::new(secure_file::read_private_key(key_file)?);

    Ok(ConfiguredBackupPaths {
        archive_dir,
        key_file: key_file.to_path_buf(),
    })
}

fn restore_stage_archive_dir(config: &Config) -> Result<PathBuf, ApiError> {
    let archive_dir = config.backup_archive_dir.as_deref().ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage directory is not configured",
        )
    })?;
    secure_owner_only_archive_dir(&config.data_dir, archive_dir)
}

pub(crate) async fn list_server_generated_restore_sources_with_settings(
    state: &crate::AppState,
    settings: &ConfiguredBackupPaths,
) -> Result<Vec<RestoreArchiveSource>, ApiError> {
    let mut sources = resolved_server_generated_restore_sources_with_settings(state, settings)
        .await?
        .into_iter()
        .map(|(source, _)| source)
        .collect::<Vec<_>>();
    sources.extend(crate::backup_replication::list_replica_restore_sources(state).await?);
    sources.sort_by(|left, right| {
        restore_source_epoch(&right.created_at)
            .cmp(&restore_source_epoch(&left.created_at))
            .then_with(|| right.archive_id.cmp(&left.archive_id))
            .then_with(|| left.source.cmp(right.source))
    });
    Ok(sources)
}

pub(crate) async fn server_generated_restore_source_exists(
    state: &crate::AppState,
    archive_id: &str,
    source: crate::backup_replication::ArchiveSource,
    settings: &ConfiguredBackupPaths,
) -> Result<bool, ApiError> {
    match source {
        crate::backup_replication::ArchiveSource::Local => {
            let sources =
                resolved_server_generated_restore_sources_with_settings(state, settings).await?;
            Ok(sources
                .iter()
                .any(|(source, _)| source.archive_id == archive_id))
        }
        crate::backup_replication::ArchiveSource::Replica => Ok(
            crate::backup_replication::settings_configured(&state.config)
                && crate::backup_replication::replica_archive_metadata(state, archive_id)
                    .await?
                    .is_some(),
        ),
    }
}

pub(crate) async fn generated_archive_path_for_id(
    state: &crate::AppState,
    settings: &ConfiguredBackupPaths,
    archive_id: &str,
    origin: &str,
) -> Result<Option<PathBuf>, ApiError> {
    if !is_canonical_uuid(archive_id) || !matches!(origin, "manual" | "scheduled") {
        return Ok(None);
    }
    let sources = if state.pg_sync_only {
        // The replication outbox becomes claimable after the archive is
        // published but just before its parent admin job commits success.
        // Let that internal worker resolve the already-published file during
        // the narrow running-job handoff. User-facing restore catalogs keep
        // their succeeded-only filter below.
        resolved_pg_server_generated_restore_sources_with_active_job(state, settings, true).await?
    } else {
        resolved_server_generated_restore_sources_with_settings(state, settings).await?
    };
    Ok(sources
        .into_iter()
        .find(|(source, _)| source.archive_id == archive_id && source.origin == origin)
        .map(|(_, path)| path))
}

async fn resolved_server_generated_restore_sources_with_settings(
    state: &crate::AppState,
    settings: &ConfiguredBackupPaths,
) -> Result<Vec<(RestoreArchiveSource, PathBuf)>, ApiError> {
    if state.pg_sync_only {
        return resolved_pg_server_generated_restore_sources(state, settings).await;
    }
    let mut candidates: HashMap<String, Vec<RestoreArchiveCandidate>> = HashMap::new();

    let manual_rows = sqlx::query(
        "SELECT job_id,COALESCE(finished_at,started_at,requested_at) AS created_at,archive_timestamp \
         FROM instance_admin_jobs WHERE action='backup'",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    for row in manual_rows {
        let archive_id: String = row.get("job_id");
        if !is_canonical_uuid(&archive_id) {
            continue;
        }
        candidates
            .entry(archive_id.clone())
            .or_default()
            .push(RestoreArchiveCandidate {
                source: RestoreArchiveSource {
                    archive_id,
                    created_at: row.get("created_at"),
                    archive_bytes: 0,
                    origin: "manual",
                    source: "local",
                },
                expected_timestamp: row.get("archive_timestamp"),
            });
    }

    let scheduled_rows = sqlx::query(
        "SELECT run_id,COALESCE(finished_at,started_at,scheduled_for) AS created_at, \
                scheduled_for,archive_bytes FROM instance_scheduled_backup_runs",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    for row in scheduled_rows {
        let archive_id: String = row.get("run_id");
        if !is_canonical_uuid(&archive_id) {
            continue;
        }
        let scheduled_for: i64 = row.get("scheduled_for");
        let expected_timestamp = backup_archive_timestamp(scheduled_for)?;
        let created_at_epoch: i64 = row.get("created_at");
        let created_at = chrono::DateTime::<chrono::Utc>::from_timestamp(created_at_epoch, 0)
            .ok_or_else(|| ApiError::internal("scheduled backup timestamp is invalid"))?
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let persisted_bytes: Option<i64> = row.get("archive_bytes");
        candidates
            .entry(archive_id.clone())
            .or_default()
            .push(RestoreArchiveCandidate {
                source: RestoreArchiveSource {
                    archive_id,
                    created_at,
                    archive_bytes: persisted_bytes.unwrap_or_default().max(0) as u64,
                    origin: "scheduled",
                    source: "local",
                },
                expected_timestamp: Some(expected_timestamp),
            });
    }

    let mut matching_names: HashMap<String, Vec<(String, PathBuf, fs::Metadata)>> = HashMap::new();
    for entry in fs::read_dir(&settings.archive_dir).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Some((timestamp, archive_id)) = server_generated_backup_name(&file_name) else {
            continue;
        };
        if !candidates.contains_key(archive_id) {
            continue;
        }
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => metadata,
            _ => continue,
        };
        if validate_generated_archive_metadata(&metadata).is_err() || metadata.len() == 0 {
            continue;
        }
        matching_names
            .entry(archive_id.to_owned())
            .or_default()
            .push((timestamp.to_owned(), path, metadata));
    }

    let mut resolved = Vec::new();
    for (archive_id, candidates) in candidates {
        // A UUID collision across the two durable tables is ambiguous and is
        // deliberately excluded from the catalog.
        if candidates.len() != 1 {
            continue;
        }
        let candidate = &candidates[0];
        let names = matching_names.remove(&archive_id).unwrap_or_default();
        let name = if let Some(expected) = candidate.expected_timestamp.as_deref() {
            names
                .into_iter()
                .find(|(timestamp, _, _)| timestamp == expected)
        } else if names.len() == 1 {
            names.into_iter().next()
        } else {
            None
        };
        let Some((_, path, metadata)) = name else {
            continue;
        };
        let mut source = candidate.source.clone();
        if source.archive_bytes > 0 && source.archive_bytes != metadata.len() {
            continue;
        }
        source.archive_bytes = metadata.len();
        resolved.push((source, path));
    }
    resolved.sort_by(|left, right| {
        restore_source_epoch(&right.0.created_at)
            .cmp(&restore_source_epoch(&left.0.created_at))
            .then_with(|| right.0.archive_id.cmp(&left.0.archive_id))
    });
    Ok(resolved)
}

async fn resolved_pg_server_generated_restore_sources(
    state: &crate::AppState,
    settings: &ConfiguredBackupPaths,
) -> Result<Vec<(RestoreArchiveSource, PathBuf)>, ApiError> {
    resolved_pg_server_generated_restore_sources_with_active_job(state, settings, false).await
}

async fn resolved_pg_server_generated_restore_sources_with_active_job(
    state: &crate::AppState,
    settings: &ConfiguredBackupPaths,
    include_running_job: bool,
) -> Result<Vec<(RestoreArchiveSource, PathBuf)>, ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL backup runtime is unavailable"))?;
    let rows = sqlx::query(
        "SELECT job_id,request_origin,COALESCE(finished_at,started_at,requested_at) AS created_at, \
                archive_timestamp,archive_bytes \
         FROM instance_admin_jobs WHERE action='backup' \
           AND (status='succeeded' OR ($1 AND status='running')) \
           AND archive_timestamp IS NOT NULL ORDER BY requested_at DESC,job_id DESC",
    )
    .bind(include_running_job)
    .fetch_all(pool)
    .await
    .map_err(ApiError::internal)?;
    let mut candidates: HashMap<String, RestoreArchiveCandidate> = HashMap::new();
    for row in rows {
        let archive_id: String = row.get("job_id");
        let request_origin: String = row.get("request_origin");
        let timestamp: Option<String> = row.get("archive_timestamp");
        let persisted_archive_bytes: Option<i64> = row.get("archive_bytes");
        if !is_canonical_uuid(&archive_id) || timestamp.is_none() {
            continue;
        }
        let created_at: chrono::DateTime<chrono::Utc> = row.get("created_at");
        candidates.insert(
            archive_id.clone(),
            RestoreArchiveCandidate {
                source: RestoreArchiveSource {
                    archive_id: archive_id.clone(),
                    created_at: created_at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                    archive_bytes: persisted_archive_bytes.unwrap_or_default().max(0) as u64,
                    origin: if request_origin == "scheduled" {
                        "scheduled"
                    } else {
                        "manual"
                    },
                    source: "local",
                },
                expected_timestamp: timestamp,
            },
        );
    }

    let mut matches: HashMap<String, Vec<(String, PathBuf, fs::Metadata)>> = HashMap::new();
    for entry in fs::read_dir(&settings.archive_dir).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Some((timestamp, archive_id)) = server_generated_backup_name(&file_name) else {
            continue;
        };
        if !candidates.contains_key(archive_id) {
            continue;
        }
        let path = entry.path();
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => metadata,
            _ => continue,
        };
        if validate_generated_archive_metadata(&metadata).is_err() || metadata.len() == 0 {
            continue;
        }
        matches.entry(archive_id.to_owned()).or_default().push((
            timestamp.to_owned(),
            path,
            metadata,
        ));
    }

    let mut resolved = Vec::new();
    for (archive_id, candidate) in candidates {
        let names = matches.remove(&archive_id).unwrap_or_default();
        let Some((_, path, metadata)) = names.into_iter().find(|(timestamp, _, _)| {
            Some(timestamp.as_str()) == candidate.expected_timestamp.as_deref()
        }) else {
            continue;
        };
        let mut source = candidate.source;
        if source.archive_bytes > 0 && source.archive_bytes != metadata.len() {
            continue;
        }
        source.archive_bytes = metadata.len();
        resolved.push((source, path));
    }
    resolved.sort_by(|left, right| {
        restore_source_epoch(&right.0.created_at)
            .cmp(&restore_source_epoch(&left.0.created_at))
            .then_with(|| right.0.archive_id.cmp(&left.0.archive_id))
    });
    Ok(resolved)
}

fn is_canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|parsed| parsed.to_string() == value)
}

fn restore_source_epoch(value: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|timestamp| timestamp.timestamp_millis())
        .unwrap_or(i64::MIN)
}

fn backup_archive_timestamp(timestamp: i64) -> Result<String, ApiError> {
    chrono::DateTime::<chrono::Utc>::from_timestamp(timestamp, 0)
        .map(|value| value.format("%Y%m%dT%H%M%S%.3fZ").to_string())
        .ok_or_else(|| ApiError::internal("backup archive timestamp is invalid"))
}

/// Validates an enabled retention policy before the server starts listening.
/// Retention cannot be enabled without the same private archive and key
/// configuration required by server-triggered backups.
pub(crate) fn validate_backup_retention_configuration(config: &Config) -> Result<(), ApiError> {
    let retention_count = config
        .validated_backup_retention_count()
        .map_err(ApiError::internal)?;
    if retention_count.is_some() {
        configured_backup_paths(config)?;
    }
    Ok(())
}

/// Prunes old server-triggered archives. The caller must hold the shared
/// maintenance lock; CLI-created archives are excluded by requiring the
/// archive UUID to match a durable admin-job or scheduled-run row.
pub(crate) async fn prune_configured_admin_backups(
    state: &AppState,
    retention_count: usize,
) -> Result<(), ApiError> {
    if !(1..=crate::MAX_BACKUP_RETENTION_COUNT).contains(&retention_count) {
        return Err(ApiError::internal("backup retention count is invalid"));
    }
    let settings = configured_backup_paths(&state.config)?;
    let job_ids: HashSet<String> = if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL backup runtime is unavailable"))?;
        sqlx::query_scalar("SELECT job_id FROM instance_admin_jobs WHERE action='backup'")
            .fetch_all(pool)
            .await
            .map_err(ApiError::internal)?
            .into_iter()
            .collect()
    } else {
        sqlx::query_scalar(
            "SELECT job_id FROM instance_admin_jobs WHERE action='backup' \
             UNION SELECT run_id FROM instance_scheduled_backup_runs \
             UNION SELECT archive_id FROM instance_backup_replications WHERE status!='succeeded'",
        )
        .fetch_all(&state.db)
        .await
        .map_err(ApiError::internal)?
        .into_iter()
        .collect()
    };
    prune_server_generated_backups(&settings.archive_dir, retention_count, &job_ids)?;
    Ok(())
}

fn prune_server_generated_backups(
    archive_dir: &Path,
    retention_count: usize,
    backup_job_ids: &HashSet<String>,
) -> Result<usize, ApiError> {
    if !(1..=crate::MAX_BACKUP_RETENTION_COUNT).contains(&retention_count) {
        return Err(ApiError::internal("backup retention count is invalid"));
    }

    let mut archives = Vec::new();
    for entry in fs::read_dir(archive_dir).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let Some(file_name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        let Some((timestamp, job_id)) = server_generated_backup_name(&file_name) else {
            continue;
        };
        if !backup_job_ids.contains(job_id) {
            continue;
        }

        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(ApiError::internal)?;
        // A matching name is not enough: links and directories are never
        // candidates for deletion, even if an operator created them.
        if !metadata.file_type().is_file() {
            continue;
        }
        validate_generated_archive_metadata(&metadata).map_err(ApiError::internal)?;
        archives.push((timestamp.to_owned(), path));
    }

    // The archive name contains a fixed-width UTC timestamp, so lexical order
    // is chronological and independent of filesystem timestamp precision.
    archives.sort_by(|left, right| {
        right
            .0
            .cmp(&left.0)
            .then_with(|| right.1.file_name().cmp(&left.1.file_name()))
    });
    if archives.len() <= retention_count {
        return Ok(0);
    }

    let mut removed = 0;
    for (_, path) in archives.into_iter().skip(retention_count) {
        // Recheck immediately before unlinking so a replaced path is not
        // treated as the regular archive inspected during enumeration.
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(ApiError::internal(error)),
        };
        if !metadata.file_type().is_file() {
            continue;
        }
        validate_generated_archive_metadata(&metadata).map_err(ApiError::internal)?;
        fs::remove_file(&path).map_err(ApiError::internal)?;
        removed += 1;
    }
    if removed > 0 {
        File::open(archive_dir)
            .and_then(|directory| directory.sync_all())
            .map_err(ApiError::internal)?;
    }
    Ok(removed)
}

fn server_generated_backup_name(file_name: &str) -> Option<(&str, &str)> {
    let body = file_name
        .strip_prefix("atermius-backup-")?
        .strip_suffix(".atb")?;
    let (timestamp, job_id) = body.split_once('-')?;
    if timestamp.len() != 20
        || chrono::NaiveDateTime::parse_from_str(timestamp, "%Y%m%dT%H%M%S%.3fZ").is_err()
    {
        return None;
    }
    let parsed_job_id = Uuid::parse_str(job_id).ok()?;
    if parsed_job_id.to_string() != job_id {
        return None;
    }
    Some((timestamp, job_id))
}

/// Returns the size of one exact server-generated PostgreSQL backup, when the
/// private archive directory is still configured and the archive remains a
/// regular owner-only file. Status reads deliberately degrade to an unknown
/// size when the archive was moved or the local node cannot see shared storage.
pub(crate) fn pg_backup_archive_bytes_for_status(
    config: &Config,
    timestamp: &str,
    job_id: &str,
) -> Option<u64> {
    if !is_canonical_uuid(job_id)
        || timestamp.len() != 20
        || chrono::NaiveDateTime::parse_from_str(timestamp, "%Y%m%dT%H%M%S%.3fZ").is_err()
    {
        return None;
    }
    let settings = configured_backup_paths(config).ok()?;
    let file_name = format!("atermius-backup-{timestamp}-{job_id}.atb");
    let (parsed_timestamp, parsed_job_id) = server_generated_backup_name(&file_name)?;
    if parsed_timestamp != timestamp || parsed_job_id != job_id {
        return None;
    }
    let path = settings.archive_dir.join(file_name);
    let metadata = fs::symlink_metadata(path).ok()?;
    if !metadata.file_type().is_file()
        || metadata.len() == 0
        || validate_generated_archive_metadata(&metadata).is_err()
    {
        return None;
    }
    Some(metadata.len())
}

fn validate_generated_archive_metadata(metadata: &fs::Metadata) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o7777 != 0o600
            || metadata.nlink() != 1
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "server backup archive metadata is unsafe",
            ));
        }
    }
    Ok(())
}

fn secure_owner_only_archive_dir(data_dir: &Path, archive_dir: &Path) -> Result<PathBuf, ApiError> {
    let metadata = fs::symlink_metadata(archive_dir).map_err(ApiError::internal)?;
    if !metadata.file_type().is_dir() {
        return Err(ApiError::internal(
            "backup archive directory must be a real directory",
        ));
    }
    let canonical = fs::canonicalize(archive_dir).map_err(ApiError::internal)?;
    let canonical_data_dir = fs::canonicalize(data_dir).map_err(ApiError::internal)?;
    if canonical.starts_with(&canonical_data_dir) {
        return Err(ApiError::internal(
            "backup archive directory must be outside instance data",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let canonical_metadata = fs::metadata(&canonical).map_err(ApiError::internal)?;
        if canonical_metadata.uid() != unsafe { libc::geteuid() }
            || canonical_metadata.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ApiError::internal(
                "backup archive directory must be owned by the service user with mode 0700",
            ));
        }
        let mut ancestor = canonical.parent();
        while let Some(path) = ancestor {
            let metadata = fs::metadata(path).map_err(ApiError::internal)?;
            let mode = metadata.permissions().mode();
            if mode & 0o022 != 0 && mode & 0o1000 == 0 {
                return Err(ApiError::internal(
                    "backup archive directory has an unsafe writable ancestor",
                ));
            }
            ancestor = path.parent();
        }
    }
    Ok(canonical)
}

/// Creates a server-named encrypted archive for an admin job. The job ID is
/// unique and canonical, and neither it nor the generated path is returned to
/// the requester; operators discover archives through their configured dir.
/// Archive creation is the operation's success boundary. Sidecar metadata is
/// best effort after a valid archive exists: a sidecar I/O problem must not
/// turn an already-created archive into a reported backup failure that could
/// encourage an operator or client to retry and create another archive.
pub(crate) async fn run_configured_admin_backup(
    state: &crate::AppState,
    job_id: &str,
) -> Result<(), ApiError> {
    if state.pg_sync_only {
        return run_configured_pg_admin_backup(state, job_id).await;
    }
    #[cfg(test)]
    {
        run_configured_admin_backup_locked(state, job_id, None).await
    }
    #[cfg(not(test))]
    {
        run_configured_admin_backup_locked(state, job_id).await
    }
}

async fn run_configured_admin_backup_locked(
    state: &crate::AppState,
    job_id: &str,
    #[cfg(test)] after_outbox_registered: Option<std::sync::Arc<crate::recovery::TestPause>>,
) -> Result<(), ApiError> {
    // Keep the shared lock from before the pending outbox row is created until
    // its archive metadata is durable. The replication worker uses this same
    // lock while claiming work, so it cannot mistake an in-progress snapshot
    // for a permanently missing archive or claim the row between archive
    // publication and the outbox transition.
    let _operation_guard = match crate::acquire_instance_maintenance_lock(state).await {
        Ok(guard) => guard,
        Err(error) => {
            let _ = crate::backup_status::record_backup_failure(&state.config.data_dir);
            return Err(error);
        }
    };
    crate::backup_replication::register_archive_before_snapshot(state, job_id, "manual").await?;
    #[cfg(test)]
    if let Some(gate) = after_outbox_registered.as_ref() {
        gate.pause().await;
    }
    match run_configured_admin_backup_archive(state, job_id).await {
        Ok(summary) => {
            crate::backup_replication::archive_created(
                state,
                job_id,
                summary.archive_bytes,
                &summary.archive_sha256,
            )
            .await
        }
        Err(error) => {
            crate::backup_replication::archive_creation_failed(state, job_id).await?;
            Err(error)
        }
    }
}

async fn run_configured_admin_backup_archive(
    state: &crate::AppState,
    job_id: &str,
) -> Result<BackupSummary, ApiError> {
    if let Err(error) = configured_backup_paths(&state.config) {
        let _ = crate::backup_status::record_backup_failure(&state.config.data_dir);
        return Err(error);
    }
    // The caller holds the shared maintenance/backup lock for this entire
    // operation, including replication outbox metadata persistence.
    // Revalidate inside the lock because an operator may have replaced a key
    // or directory since job submission.
    let settings = match configured_backup_paths(&state.config) {
        Ok(settings) => settings,
        Err(error) => {
            let _ = crate::backup_status::record_backup_failure(&state.config.data_dir);
            return Err(error);
        }
    };
    let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ").to_string();
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET archive_timestamp=? \
         WHERE job_id=? AND action='backup' AND status='running' \
           AND (archive_timestamp IS NULL OR archive_timestamp=?)",
    )
    .bind(&timestamp)
    .bind(job_id)
    .bind(&timestamp)
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "admin backup archive timestamp could not be recorded",
        ));
    }
    let archive_path = settings
        .archive_dir
        .join(format!("atermius-backup-{timestamp}-{job_id}.atb"));
    let database_url = format!(
        "sqlite://{}/atermius.db?mode=rwc",
        state.config.data_dir.display()
    );
    let result = backup_instance(
        &state.config,
        &database_url,
        &archive_path,
        &settings.key_file,
    )
    .await;
    match result {
        Ok(summary) => {
            if crate::backup_status::record_backup_success(
                &state.config.data_dir,
                summary.migration_version,
                summary.archive_bytes,
            )
            .is_err()
            {
                tracing::warn!(
                    job_id = %job_id,
                    "encrypted admin backup was created but backup status metadata could not be updated"
                );
            }
            Ok(summary)
        }
        Err(error) => {
            let _ = crate::backup_status::record_backup_failure(&state.config.data_dir);
            Err(error)
        }
    }
}

/// Validates persistent scheduled-backup state before the server starts
/// listening. An enabled schedule without its private archive/key settings is
/// a startup error rather than a silently dormant schedule.
pub(crate) async fn validate_backup_schedule_configuration(
    state: &crate::AppState,
) -> Result<(), ApiError> {
    let schedule = sqlx::query(
        "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let interval_hours: Option<i64> = schedule.get("interval_hours");
    let next_run_at: Option<i64> = schedule.get("next_run_at");
    if interval_hours.is_some() != next_run_at.is_some() {
        return Err(ApiError::internal("backup schedule state is inconsistent"));
    }
    if let Some(interval_hours) = interval_hours {
        backup_interval_seconds(interval_hours).map_err(ApiError::internal)?;
        configured_backup_paths(&state.config)?;
    }
    Ok(())
}

/// Marks interrupted scheduled runs after a process restart. Scheduled runs
/// are deliberately never replayed: if the process stopped after publishing
/// an archive but before persisting its result, the claimed run ID remains
/// registered for retention and admin status stays explicitly interrupted
/// rather than creating another archive for the same slot.
pub(crate) async fn recover_interrupted_scheduled_backup_runs(
    state: &crate::AppState,
) -> Result<(), ApiError> {
    let now = chrono::Utc::now().timestamp();
    sqlx::query(
        "UPDATE instance_scheduled_backup_runs \
         SET status='interrupted',finished_at=?,result_code='interrupted' \
         WHERE status='running'",
    )
    .bind(now)
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

/// Claims at most one due schedule slot and writes its `running` row in the
/// same transaction that advances `next_run_at`. The process and OS
/// maintenance locks are acquired before the claim; if either lock is busy,
/// the due time remains unchanged and the next poll retries it.
pub(crate) async fn run_due_scheduled_backup(state: &crate::AppState) -> Result<bool, ApiError> {
    let _guard = match crate::acquire_instance_maintenance_lock(state).await {
        Ok(guard) => guard,
        Err(error) if error.body.code == "MAINTENANCE_ALREADY_RUNNING" => return Ok(false),
        Err(error) => return Err(error),
    };
    let Some(claim) = claim_due_scheduled_backup(state).await? else {
        return Ok(false);
    };

    let registration = crate::backup_replication::register_archive_before_snapshot(
        state,
        &claim.run_id,
        "scheduled",
    )
    .await;
    let outbox_registered = registration.is_ok();
    let outcome = match registration {
        Ok(()) => create_scheduled_backup_archive(state, &claim).await,
        Err(error) => Err(error),
    };
    match &outcome {
        Ok(summary) if outbox_registered => {
            crate::backup_replication::archive_created(
                state,
                &claim.run_id,
                summary.archive_bytes,
                &summary.archive_sha256,
            )
            .await?;
        }
        Err(_) if outbox_registered => {
            crate::backup_replication::archive_creation_failed(state, &claim.run_id).await?;
        }
        _ => {}
    }
    persist_scheduled_backup_result(state, &claim, &outcome).await?;
    match &outcome {
        Ok(summary) => {
            if crate::backup_status::record_backup_success(
                &state.config.data_dir,
                summary.migration_version,
                summary.archive_bytes,
            )
            .is_err()
            {
                tracing::warn!(
                    run_id = %claim.run_id,
                    "scheduled backup completed but backup status metadata could not be updated"
                );
            }
        }
        Err(_) => {
            if crate::backup_status::record_backup_failure(&state.config.data_dir).is_err() {
                tracing::warn!(
                    run_id = %claim.run_id,
                    "scheduled backup failed and backup status metadata could not be updated"
                );
            }
        }
    }
    if let Err(error) = outcome {
        return Err(error);
    }
    Ok(true)
}

async fn claim_due_scheduled_backup(
    state: &crate::AppState,
) -> Result<Option<ScheduledBackupRunClaim>, ApiError> {
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let schedule = sqlx::query(
        "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let interval_hours: Option<i64> = schedule.get("interval_hours");
    let scheduled_for: Option<i64> = schedule.get("next_run_at");
    let (interval_hours, scheduled_for) = match (interval_hours, scheduled_for) {
        (None, None) => {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(None);
        }
        (Some(interval_hours), Some(scheduled_for)) => (interval_hours, scheduled_for),
        _ => return Err(ApiError::internal("backup schedule state is inconsistent")),
    };
    let interval_seconds = backup_interval_seconds(interval_hours)?;
    let now = chrono::Utc::now().timestamp();
    if scheduled_for > now {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    }

    // Manual maintenance and backup requests share the same physical lock,
    // but this database check also avoids consuming a schedule slot when an
    // administrator job was already durably queued before this claim.
    let admin_job_active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM instance_admin_jobs WHERE status IN ('queued','running'))",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if admin_job_active {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    }

    let run_active: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM instance_scheduled_backup_runs WHERE status='running')",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if run_active {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    }

    let next_run_at = next_scheduled_backup_due(scheduled_for, interval_seconds, now)?;
    let run_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO instance_scheduled_backup_runs(run_id,scheduled_for,started_at,status) \
         VALUES(?,?,?,'running')",
    )
    .bind(&run_id)
    .bind(scheduled_for)
    .bind(now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let changed = sqlx::query(
        "UPDATE instance_backup_schedule SET next_run_at=? \
         WHERE schedule_id=1 AND interval_hours=? AND next_run_at=?",
    )
    .bind(next_run_at)
    .bind(interval_hours)
    .bind(scheduled_for)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "scheduled backup due time changed during claim",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(ScheduledBackupRunClaim {
        run_id,
        scheduled_for,
        started_at: now,
    }))
}

async fn create_scheduled_backup_archive(
    state: &crate::AppState,
    claim: &ScheduledBackupRunClaim,
) -> Result<BackupSummary, ApiError> {
    let settings = configured_backup_paths(&state.config)?;
    let timestamp = chrono::DateTime::<chrono::Utc>::from_timestamp(claim.scheduled_for, 0)
        .ok_or_else(|| ApiError::internal("scheduled backup timestamp is invalid"))?
        .format("%Y%m%dT%H%M%S%.3fZ");
    let archive_path = settings
        .archive_dir
        .join(format!("atermius-backup-{timestamp}-{}.atb", claim.run_id));
    let database_url = format!(
        "sqlite://{}/atermius.db?mode=rwc",
        state.config.data_dir.display()
    );
    backup_instance(
        &state.config,
        &database_url,
        &archive_path,
        &settings.key_file,
    )
    .await
}

async fn persist_scheduled_backup_result(
    state: &crate::AppState,
    claim: &ScheduledBackupRunClaim,
    outcome: &Result<BackupSummary, ApiError>,
) -> Result<(), ApiError> {
    let mut delay = std::time::Duration::from_secs(1);
    loop {
        let result = persist_scheduled_backup_result_once(state, claim, outcome).await;
        match result {
            Ok(()) => return Ok(()),
            Err(error) => {
                tracing::error!(
                    run_id = %claim.run_id,
                    retry_after_seconds = delay.as_secs(),
                    "scheduled backup result is not durable; retrying"
                );
                tokio::time::sleep(delay).await;
                delay = (delay * 2).min(std::time::Duration::from_secs(30));
                let _ = error;
            }
        }
    }
}

async fn persist_scheduled_backup_result_once(
    state: &crate::AppState,
    claim: &ScheduledBackupRunClaim,
    outcome: &Result<BackupSummary, ApiError>,
) -> Result<(), ApiError> {
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let finished_at = chrono::Utc::now().timestamp();
    let changed = match outcome {
        Ok(summary) => sqlx::query(
            "UPDATE instance_scheduled_backup_runs \
             SET status='succeeded',finished_at=?,result_code='completed',migration_version=?,archive_bytes=? \
             WHERE run_id=? AND scheduled_for=? AND started_at=? AND status='running'",
        )
        .bind(finished_at)
        .bind(summary.migration_version)
        .bind(i64::try_from(summary.archive_bytes).map_err(ApiError::internal)?)
        .bind(&claim.run_id)
        .bind(claim.scheduled_for)
        .bind(claim.started_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?,
        Err(_) => sqlx::query(
            "UPDATE instance_scheduled_backup_runs \
             SET status='failed',finished_at=?,result_code='backup_failed' \
             WHERE run_id=? AND scheduled_for=? AND started_at=? AND status='running'",
        )
        .bind(finished_at)
        .bind(&claim.run_id)
        .bind(claim.scheduled_for)
        .bind(claim.started_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?,
    };
    if changed.rows_affected() != 1 {
        let existing: Option<String> =
            sqlx::query_scalar("SELECT status FROM instance_scheduled_backup_runs WHERE run_id=?")
                .bind(&claim.run_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let expected_status = if outcome.is_ok() {
            "succeeded"
        } else {
            "failed"
        };
        if existing.as_deref() == Some(expected_status) {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(());
        }
        return Err(ApiError::internal(
            "scheduled backup result transition was not applied",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)
}

/// Authenticates and validates an archive without touching the active
/// instance, publishing a restore target, or running database migrations.
/// Extracted bytes live only in a private system-temporary directory that is
/// removed on success and on every error path.
pub async fn verify_instance_backup(
    data_dir: &Path,
    archive_path: &Path,
    backup_key_path: &Path,
) -> Result<BackupVerification, ApiError> {
    secure_file::secure_existing_data_dir(data_dir)?;
    ensure_path_outside_data_dir(data_dir, backup_key_path)?;
    ensure_path_outside_data_dir(data_dir, archive_path)?;

    let backup_key = Zeroizing::new(secure_file::read_private_key(backup_key_path)?);
    let archive = open_private_archive(archive_path).map_err(ApiError::internal)?;
    let temp_parent = std::env::temp_dir();
    ensure_path_outside_data_dir(
        data_dir,
        &temp_parent.join(".atermius-backup-verify-staging"),
    )?;
    let stage = create_private_temp_dir(&temp_parent, "atermius-backup-verify")?;
    let manifest =
        read_encrypted_archive(archive, &backup_key, &stage.0).map_err(ApiError::internal)?;

    for file_name in ["auth-rate-limit.key", "instance-ed25519.key"] {
        let _key = Zeroizing::new(secure_file::read_private_key(&stage.0.join(file_name))?);
    }
    if manifest.database_engine == "postgresql" {
        verify_postgres_archive_metadata(&manifest, &stage.0).await?;
        return Ok(BackupVerification {
            migration_version: manifest.migration_version,
            file_count: manifest.files.len(),
        });
    }
    if manifest.database_engine != "sqlite" {
        return Err(ApiError::bad_request(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "backup database engine is not supported by this server",
        ));
    }
    if manifest.migration_version > current_migration_version() {
        return Err(ApiError::bad_request(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "backup schema is newer than this server",
        ));
    }
    let database = stage.0.join("atermius.db");
    validate_sqlite_file(&database).await?;
    if sqlite_schema_version(&database).await? != manifest.migration_version {
        return Err(ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "backup migration version does not match its database",
        ));
    }

    Ok(BackupVerification {
        migration_version: manifest.migration_version,
        file_count: manifest.files.len(),
    })
}

async fn verify_postgres_archive_metadata(
    manifest: &BackupManifest,
    stage_dir: &Path,
) -> Result<(), ApiError> {
    if !supported_pg_archive_schema_version(manifest.migration_version) {
        return Err(ApiError::bad_request(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "PostgreSQL backup schema is not supported by this server",
        ));
    }
    let metadata_path = stage_dir.join("postgres-metadata.json");
    let metadata_bytes = fs::read(&metadata_path).map_err(ApiError::internal)?;
    if metadata_bytes.len() > MAX_MANIFEST_BYTES {
        return Err(ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup metadata is too large",
        ));
    }
    let metadata: PgArchiveMetadata = serde_json::from_slice(&metadata_bytes).map_err(|_| {
        ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup metadata is invalid",
        )
    })?;
    let canonical = serde_jcs::to_vec(&metadata).map_err(ApiError::internal)?;
    if canonical.as_slice() != metadata_bytes.as_slice()
        || metadata.format_version != 1
        || !valid_pg_schema_identifier(&metadata.schema)
        || metadata.object_store_id.is_empty()
        || metadata.object_store_id.len() > 512
        || metadata.object_store_id.contains(['\n', '\r', '\0'])
        || metadata.server_version_num <= 0
        || pg_tool_major(&metadata.pg_dump_version).is_err()
    {
        return Err(ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup metadata is invalid",
        ));
    }
    let archive_files = manifest
        .files
        .iter()
        .map(|entry| (entry.name.as_str(), entry))
        .collect::<HashMap<_, _>>();
    let mut object_ids = HashSet::new();
    for (index, object) in metadata.objects.iter().enumerate() {
        let expected_name = format!("object-{index:08}.blob");
        if object.archive_file != expected_name
            || !object_ids.insert((object.vault_id.as_str(), object.object_id.as_str()))
            || !matches!(object.storage_backend.as_str(), "s3" | "filesystem")
            || object.storage_key.is_empty()
            || object.storage_store_id != metadata.object_store_id
            || object.size <= 0
            || object.sha256.len() != 64
            || !object
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(ApiError::bad_request(
                "BACKUP_MANIFEST_INVALID",
                "PostgreSQL object manifest is invalid",
            ));
        }
        let Some(file) = archive_files.get(object.archive_file.as_str()) else {
            return Err(ApiError::bad_request(
                "BACKUP_MANIFEST_INVALID",
                "PostgreSQL object is missing from the archive",
            ));
        };
        if file.size != object.size as u64 || file.sha256 != object.sha256 {
            return Err(ApiError::bad_request(
                "BACKUP_MANIFEST_INVALID",
                "PostgreSQL object integrity metadata does not match",
            ));
        }
    }
    let object_file_count = manifest
        .files
        .iter()
        .filter(|file| is_pg_object_archive_name(&file.name))
        .count();
    if object_file_count != metadata.objects.len() {
        return Err(ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL object count does not match the archive",
        ));
    }
    let dump_path = stage_dir.join("postgres.dump");
    validate_pg_dump(&dump_path).await?;
    let restore_version = run_pg_tool_version("pg_restore").await?;
    if pg_tool_major(&restore_version)? < pg_tool_major(&metadata.pg_dump_version)? {
        return Err(ApiError::bad_request(
            "BACKUP_TOOL_UNSUPPORTED",
            "installed PostgreSQL restore tools are older than the archive format",
        ));
    }
    Ok(())
}

/// Writes a consistent, encrypted online SQLite backup without replacing an
/// existing archive. `ATERMIUS_DATA_DIR` must contain the service's default DB.
pub async fn backup_instance(
    config: &Config,
    database_url: &str,
    archive_path: &Path,
    backup_key_path: &Path,
) -> Result<BackupSummary, ApiError> {
    secure_file::secure_existing_data_dir(&config.data_dir)?;
    ensure_path_outside_data_dir(&config.data_dir, backup_key_path)?;
    ensure_path_outside_data_dir(&config.data_dir, archive_path)?;
    let expected_database_url = format!(
        "sqlite://{}/atermius.db?mode=rwc",
        config.data_dir.display()
    );
    if database_url != expected_database_url {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_DATABASE_URL",
            "backup supports only ATERMIUS_DATA_DIR/atermius.db",
        ));
    }
    let db_path = config.data_dir.join("atermius.db");
    if !fs::symlink_metadata(&db_path)
        .map(|metadata| metadata.file_type().is_file())
        .unwrap_or(false)
    {
        return Err(ApiError::bad_request(
            "BACKUP_DATABASE_MISSING",
            "the configured instance database is missing or is not a regular file",
        ));
    }
    let options = SqliteConnectOptions::from_str(database_url)
        .map_err(ApiError::internal)?
        .create_if_missing(false)
        .foreign_keys(true)
        .busy_timeout(std::time::Duration::from_secs(10));
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(ApiError::internal)?;
    let result = backup_instance_from_pool(&pool, config, archive_path, backup_key_path).await;
    pool.close().await;
    result
}

/// Creates an encrypted, consistent PostgreSQL instance archive. Unlike the
/// SQLite path, the database snapshot is a `pg_dump` exported snapshot and
/// external object bytes are copied only while their catalogue keys are
/// protected by the shared PG backup-pin table.
pub(crate) async fn run_configured_pg_admin_backup(
    state: &crate::AppState,
    job_id: &str,
) -> Result<(), ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL backup runtime is unavailable"))?;
    let runtime = crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env()?
        .ok_or_else(|| ApiError::internal("PostgreSQL backup runtime is unavailable"))?;
    let settings = configured_backup_paths(&state.config)?;
    let pg_objects = state
        .pg_objects
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL object repository is unavailable"))?;
    if !is_canonical_uuid(job_id) {
        return Err(ApiError::internal("PostgreSQL backup job ID is invalid"));
    }

    let (request_origin, scheduled_for): (String, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as(
            "SELECT request_origin,scheduled_for FROM instance_admin_jobs \
             WHERE job_id=$1 AND action='backup' AND status='running'",
        )
        .bind(job_id)
        .fetch_optional(pool)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("PostgreSQL backup job is unavailable"))?;
    if !matches!(request_origin.as_str(), "manual" | "scheduled") {
        return Err(ApiError::internal(
            "PostgreSQL backup job origin is invalid",
        ));
    }
    let replication_repository = crate::backup_replication::replication_requested(&state.config)
        .then(|| crate::pg_backup_replication::PgBackupReplicationRepository::new(pool.clone()));
    let timestamp = scheduled_for
        .unwrap_or_else(chrono::Utc::now)
        .format("%Y%m%dT%H%M%S%.3fZ")
        .to_string();
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET archive_id=$1,archive_timestamp=$2 \
         WHERE job_id=$1 AND action='backup' AND status='running' \
           AND (archive_timestamp IS NULL OR archive_timestamp=$2) \
           AND (archive_id IS NULL OR archive_id=$1)",
    )
    .bind(job_id)
    .bind(&timestamp)
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "PostgreSQL backup archive timestamp could not be recorded",
        ));
    }

    let archive_path = settings
        .archive_dir
        .join(format!("atermius-backup-{timestamp}-{job_id}.atb"));
    if archive_path.exists() {
        return Err(ApiError::conflict(
            "BACKUP_ARCHIVE_EXISTS",
            "a server backup with this job ID already exists",
        ));
    }
    if let Some(repository) = &replication_repository {
        repository
            .register_archive_before_snapshot(job_id, &request_origin)
            .await?;
    }
    let result = create_postgres_instance_backup(
        state,
        pool,
        pg_objects,
        &runtime,
        &settings,
        job_id,
        &archive_path,
    )
    .await;
    match result {
        Ok(summary) => {
            let recorded = sqlx::query(
                "UPDATE instance_admin_jobs SET archive_sha256=$2,archive_bytes=$3 \
                 WHERE job_id=$1 AND action='backup' AND status='running' \
                   AND archive_id=$1 AND archive_timestamp=$4 \
                   AND (archive_sha256 IS NULL OR archive_sha256=$2) \
                   AND (archive_bytes IS NULL OR archive_bytes=$3)",
            )
            .bind(job_id)
            .bind(&summary.archive_sha256)
            .bind(i64::try_from(summary.archive_bytes).map_err(ApiError::internal)?)
            .bind(&timestamp)
            .execute(pool)
            .await
            .map_err(ApiError::internal)?;
            if recorded.rows_affected() != 1 {
                return Err(ApiError::internal(
                    "PostgreSQL backup digest could not be recorded",
                ));
            }
            if let Some(repository) = &replication_repository {
                if let Err(error) = repository
                    .archive_created(job_id, summary.archive_bytes, &summary.archive_sha256)
                    .await
                {
                    // The local encrypted archive is already complete. Leave
                    // the pre-snapshot outbox row visible for reconciliation
                    // rather than reporting a failed backup and inviting a
                    // duplicate retry for an archive that already exists.
                    tracing::error!(
                        error_code = %error.body.code,
                        "PostgreSQL backup exists but its replication outbox metadata could not be published"
                    );
                }
            }
            if crate::backup_status::record_backup_success(
                &state.config.data_dir,
                summary.migration_version,
                summary.archive_bytes,
            )
            .is_err()
            {
                tracing::warn!(
                    job_id = %job_id,
                    "encrypted PostgreSQL backup was created but local status metadata could not be updated"
                );
            }
            Ok(())
        }
        Err(error) => {
            if let Some(repository) = &replication_repository {
                if let Err(replication_error) = repository.archive_creation_failed(job_id).await {
                    tracing::warn!(
                        error_code = %replication_error.body.code,
                        "PostgreSQL backup failure could not be recorded in its replication outbox"
                    );
                }
            }
            let _ = crate::backup_status::record_backup_failure(&state.config.data_dir);
            Err(error)
        }
    }
}

async fn create_postgres_instance_backup(
    state: &crate::AppState,
    pool: &PgPool,
    pg_objects: &crate::pg_objects::PgObjectRepository,
    runtime: &crate::pg_sync_runtime::PgSyncRuntimeConfig,
    settings: &ConfiguredBackupPaths,
    job_id: &str,
    archive_path: &Path,
) -> Result<BackupSummary, ApiError> {
    let mut phase = "prepare";
    let result = create_postgres_instance_backup_inner(
        state,
        pool,
        pg_objects,
        runtime,
        settings,
        job_id,
        archive_path,
        &mut phase,
    )
    .await;
    if let Err(error) = &result {
        tracing::warn!(
            phase,
            error_code = %error.body.code,
            "PostgreSQL instance backup failed"
        );
    }
    result
}

async fn create_postgres_instance_backup_inner(
    state: &crate::AppState,
    pool: &PgPool,
    pg_objects: &crate::pg_objects::PgObjectRepository,
    runtime: &crate::pg_sync_runtime::PgSyncRuntimeConfig,
    settings: &ConfiguredBackupPaths,
    job_id: &str,
    archive_path: &Path,
    phase: &mut &'static str,
) -> Result<BackupSummary, ApiError> {
    *phase = "read_backup_key";
    let backup_key = Zeroizing::new(secure_file::read_private_key(&settings.key_file)?);
    *phase = "create_private_work_dir";
    let work = create_private_temp_dir(&settings.archive_dir, "pg-backup")?;
    let dump_path = work.0.join("postgres.dump");
    let service_file = work.0.join("postgres-service.conf");
    *phase = "write_postgres_service_file";
    write_pg_service_config(&runtime.database_url, &service_file)?;

    *phase = "begin_snapshot_transaction";
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    // This migration marker also proves that the backup-pin and expanded job
    // schemas required by this archive format were applied before serving.
    *phase = "validate_postgres_schema_marker";
    let migration_version: i64 = sqlx::query_scalar(
        "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL backup schema readiness check failed"))?;
    if migration_version != PG_BACKUP_SCHEMA_VERSION {
        return Err(ApiError::internal(
            "PostgreSQL backup schema version is not supported by this server",
        ));
    }
    *phase = "read_postgres_server_version";
    let server_version_num: i32 =
        sqlx::query_scalar("SELECT current_setting('server_version_num')::integer")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    *phase = "export_snapshot_and_pin_objects";
    let snapshot_id: String = sqlx::query_scalar("SELECT pg_export_snapshot()")
        .fetch_one(&mut *tx)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL backup snapshot could not be exported"))?;
    let snapshot_objects =
        crate::pg_objects::pin_objects_for_backup_tx(&mut tx, job_id, PG_BACKUP_PIN_LEASE_SECONDS)
            .await?;

    *phase = "run_pg_dump";
    let pg_dump_version = run_pg_dump(
        &service_file,
        &runtime.schema,
        &snapshot_id,
        &dump_path,
        server_version_num,
        &mut tx,
        job_id,
    )
    .await?;
    *phase = "validate_pg_dump";
    validate_pg_dump(&dump_path).await?;
    *phase = "commit_snapshot_and_object_pins";
    tx.commit().await.map_err(ApiError::internal)?;
    let pin_cleanup = PgBackupPinCleanup {
        repository: pg_objects.clone(),
        backup_id: job_id.to_owned(),
        released: false,
    };

    let configured_store_id = state
        .object_store
        .store_id()
        .ok_or_else(|| ApiError::internal("PostgreSQL backup object store is unavailable"))?;
    let mut objects = Vec::with_capacity(snapshot_objects.len());
    let mut sources = Vec::with_capacity(snapshot_objects.len() + 4);
    *phase = "copy_and_verify_external_objects";
    for (index, object) in snapshot_objects.iter().enumerate() {
        if object.storage_store_id != configured_store_id
            || object.storage_backend != state.object_store.backend_name()
            || object.size <= 0
            || object.sha256.len() != 64
        {
            return Err(ApiError::internal(
                "PostgreSQL backup object catalogue does not match the configured store",
            ));
        }
        pg_objects
            .renew_backup_pins(job_id, PG_BACKUP_PIN_LEASE_SECONDS)
            .await?;
        let bytes = read_pinned_postgres_object(state, pg_objects, job_id, object).await?;
        let archive_file = format!("object-{index:08}.blob");
        let path = work.0.join(&archive_file);
        write_private_file(&path, &bytes)?;
        objects.push(PgArchiveObject {
            vault_id: object.vault_id.clone(),
            object_id: object.object_id.clone(),
            storage_backend: object.storage_backend.clone(),
            storage_key: object.storage_key.clone(),
            storage_store_id: object.storage_store_id.clone(),
            size: object.size,
            sha256: object.sha256.clone(),
            archive_file: archive_file.clone(),
        });
        sources.push(SourceFile {
            name: archive_file,
            path,
        });
    }
    *phase = "release_object_pins";
    pin_cleanup.release().await?;

    *phase = "build_archive_metadata";
    let object_store_id = state
        .object_store
        .store_id()
        .ok_or_else(|| ApiError::internal("PostgreSQL backup object store is unavailable"))?;
    let archive_metadata = PgArchiveMetadata {
        format_version: 1,
        schema: runtime.schema.clone(),
        pg_dump_version,
        server_version_num,
        object_store_id: object_store_id.to_owned(),
        objects,
    };
    let metadata_bytes = serde_jcs::to_vec(&archive_metadata).map_err(ApiError::internal)?;
    let metadata_path = work.0.join("postgres-metadata.json");
    write_private_file(&metadata_path, &metadata_bytes)?;

    let rate_limit_key = Zeroizing::new(secure_file::read_private_key(
        &runtime.auth_rate_limit_key_file,
    )?);
    if rate_limit_key.as_slice() != state.auth_rate_key.as_ref() {
        return Err(ApiError::internal(
            "PostgreSQL rate-limit key changed during backup",
        ));
    }
    let signing_key = Zeroizing::new(secure_file::read_private_key(
        &runtime.instance_signing_key_file,
    )?);
    let signing_key_loaded = state.signing_key.to_bytes();
    if signing_key.as_slice() != signing_key_loaded.as_slice() {
        return Err(ApiError::internal(
            "PostgreSQL instance signing key changed during backup",
        ));
    }
    let rate_key_path = work.0.join("auth-rate-limit.key");
    let signing_key_path = work.0.join("instance-ed25519.key");
    *phase = "write_archive_key_material";
    write_private_file(&rate_key_path, rate_limit_key.as_slice())?;
    write_private_file(&signing_key_path, signing_key.as_slice())?;
    sources.extend([
        SourceFile {
            name: "auth-rate-limit.key".to_owned(),
            path: rate_key_path,
        },
        SourceFile {
            name: "postgres-metadata.json".to_owned(),
            path: metadata_path,
        },
        SourceFile {
            name: "postgres.dump".to_owned(),
            path: dump_path,
        },
        SourceFile {
            name: "instance-ed25519.key".to_owned(),
            path: signing_key_path,
        },
    ]);
    sources.sort_by(|left, right| left.name.cmp(&right.name));
    *phase = "build_archive_manifest";
    let manifest = build_postgres_manifest(&sources, migration_version, &state.config)?;
    let (output, mut archive_file) = create_private_archive_temp(archive_path)?;
    *phase = "encrypt_archive";
    write_encrypted_archive(&mut archive_file, &backup_key, &manifest, &sources)
        .map_err(ApiError::internal)?;
    archive_file.sync_all().map_err(ApiError::internal)?;
    drop(archive_file);
    *phase = "publish_archive";
    fs::hard_link(&output.0, archive_path).map_err(ApiError::internal)?;
    drop(output);
    sync_parent(archive_path).map_err(ApiError::internal)?;
    let archive_bytes = fs::metadata(archive_path)
        .map_err(ApiError::internal)?
        .len();
    if archive_bytes == 0 || archive_bytes > MAX_BACKUP_ARCHIVE_BYTES {
        return Err(ApiError::internal(
            "generated PostgreSQL backup archive size is invalid",
        ));
    }
    *phase = "hash_published_archive";
    let (_, archive_sha256) = open_and_hash_generated_archive(archive_path)?;
    Ok(BackupSummary {
        migration_version,
        archive_bytes,
        archive_sha256,
    })
}

async fn run_configured_pg_admin_restore_stage(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
) -> Result<(), ApiError> {
    let mut phase = "validate_restore_source";
    let result = run_configured_pg_admin_restore_stage_inner(
        state,
        job_id,
        archive_id,
        archive_source,
        &mut phase,
    )
    .await;
    if let Err(error) = &result {
        tracing::warn!(
            job_id = %job_id,
            restore_phase = phase,
            error_code = %error.body.code,
            "PostgreSQL restore stage operation failed"
        );
    }
    result
}

async fn run_configured_pg_admin_restore_stage_inner(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    phase: &mut &'static str,
) -> Result<(), ApiError> {
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
    let runtime = crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env()?
        .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
    if runtime.schema == "public"
        || runtime.schema == "information_schema"
        || runtime.schema == PG_RESTORE_CONTROL_SCHEMA
        || runtime.schema.starts_with("pg_")
    {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "PostgreSQL restore staging requires a dedicated application schema",
        ));
    }
    *phase = "validate_isolated_target";
    let settings = configured_backup_paths(&state.config)?;
    let target_url = std::env::var("ATERMIUS_PG_RESTORE_TARGET_URL")
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ApiError::conflict(
                "RESTORE_TARGET_UNAVAILABLE",
                "an isolated PostgreSQL restore target is not configured",
            )
        })?;
    if !postgres_restore_target_ready(pool, &target_url).await {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable or not empty",
        ));
    }
    let target_identity = postgres_restore_target_identity(&target_url).await?;
    *phase = "resolve_archive_source";
    let staging_dir = ensure_restore_staging_dir(&settings.archive_dir)?;
    let target = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
    let temporary = staging_dir.join(format!("atermius-pg-restore-{job_id}.staging"));
    ensure_restore_stage_paths_absent(&target, &temporary)?;
    ensure_path_outside_data_dir(&state.config.data_dir, &target)?;
    let (archive_path, _remote_archive_guard) = match archive_source {
        crate::backup_replication::ArchiveSource::Local => {
            let path = resolved_pg_server_generated_restore_sources(state, &settings)
                .await?
                .into_iter()
                .find(|(source, _)| source.archive_id == archive_id && source.source == "local")
                .map(|(_, path)| path)
                .ok_or_else(|| {
                    ApiError::conflict(
                        "RESTORE_SOURCE_UNAVAILABLE",
                        "the selected PostgreSQL backup is unavailable for restore",
                    )
                })?;
            (path, None)
        }
        crate::backup_replication::ArchiveSource::Replica => {
            let source_path = staging_dir.join(format!("atermius-pg-restore-{job_id}.source.atb"));
            ensure_restore_source_path_absent(&source_path)?;
            ensure_path_outside_data_dir(&state.config.data_dir, &source_path)?;
            let Some((expected_bytes, expected_sha256)) =
                crate::backup_replication::replica_archive_metadata(state, archive_id).await?
            else {
                return Err(ApiError::conflict(
                    "RESTORE_SOURCE_UNAVAILABLE",
                    "the selected PostgreSQL backup is unavailable for restore",
                ));
            };
            let (downloaded, _, _) = crate::backup_replication::download_replica_archive(
                state,
                archive_id,
                &source_path,
                expected_bytes,
                &expected_sha256,
            )
            .await?;
            (downloaded.0.clone(), Some(downloaded))
        }
    };
    *phase = "prepare_stage_directory";
    create_private_dir(&temporary).map_err(ApiError::internal)?;
    let stage_guard = TempDirectory(temporary.clone());

    *phase = "decrypt_and_validate_archive";
    let backup_key = Zeroizing::new(secure_file::read_private_key(&settings.key_file)?);
    let (archive, archive_sha256) = open_and_hash_generated_archive(&archive_path)?;
    let manifest =
        read_encrypted_archive(archive, &backup_key, &temporary).map_err(ApiError::internal)?;
    drop(_remote_archive_guard);
    verify_postgres_archive_metadata(&manifest, &temporary).await?;
    let metadata_bytes =
        fs::read(temporary.join("postgres-metadata.json")).map_err(ApiError::internal)?;
    let metadata: PgArchiveMetadata = serde_json::from_slice(&metadata_bytes)
        .map_err(|_| ApiError::internal("PostgreSQL backup metadata is invalid"))?;
    if !supported_pg_archive_schema_version(manifest.migration_version)
        || metadata.schema != runtime.schema
        || !valid_pg_schema_identifier(&metadata.schema)
    {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "PostgreSQL backup schema differs from the configured instance schema",
        ));
    }
    let signing_key_bytes = Zeroizing::new(secure_file::read_private_key(
        &temporary.join("instance-ed25519.key"),
    )?);
    let auth_rate_key = Zeroizing::new(secure_file::read_private_key(
        &temporary.join("auth-rate-limit.key"),
    )?);
    if signing_key_bytes.len() != 32 || auth_rate_key.len() != 32 {
        return Err(ApiError::conflict(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup service keys are invalid",
        ));
    }
    *phase = "persist_archive_digest";
    persist_admin_restore_archive_digest(
        state,
        job_id,
        archive_id,
        archive_source,
        &archive_sha256,
    )
    .await?;

    *phase = "prepare_restore_object_storage";
    let object_root = temporary.join("object-store");
    create_private_dir(&object_root).map_err(ApiError::internal)?;
    *phase = "initialize_restore_object_store";
    let restore_store = crate::object_store::ObjectStore::restore_target_filesystem(&object_root)?;
    let restored_store_id = restore_store
        .store_id()
        .ok_or_else(|| ApiError::internal("PostgreSQL restore object store is unavailable"))?
        .to_owned();
    if restored_store_id == metadata.object_store_id {
        return Err(ApiError::internal(
            "PostgreSQL restore object store identity is not isolated",
        ));
    }
    let binding = PgRestoreStageBinding {
        binding_id: Uuid::new_v4().to_string(),
        target_fingerprint: pg_restore_target_fingerprint(&target_url),
        target_database_oid: target_identity.0,
        target_database_name: target_identity.1,
        schema: metadata.schema.clone(),
        object_store_id: restored_store_id.clone(),
        restored_objects: i64::try_from(metadata.objects.len())
            .map_err(|_| ApiError::internal("PostgreSQL restore object count is invalid"))?,
    };
    *phase = "persist_target_binding";
    persist_admin_restore_stage_binding(
        state,
        job_id,
        archive_id,
        archive_source,
        &archive_sha256,
        &binding,
    )
    .await?;
    *phase = "restore_object_bytes";
    for object in &metadata.objects {
        let object_path = temporary.join(&object.archive_file);
        let bytes = Zeroizing::new(fs::read(&object_path).map_err(ApiError::internal)?);
        if bytes.len() as i64 != object.size || hex::encode(Sha256::digest(&bytes)) != object.sha256
        {
            return Err(ApiError::conflict(
                "BACKUP_MANIFEST_INVALID",
                "PostgreSQL backup object integrity check failed",
            ));
        }
        restore_store
            .put_immutable(
                &object.storage_key,
                bytes.as_slice(),
                object.size,
                &object.sha256,
            )
            .await
            .map_err(crate::object_store::storage_api_error)?;
    }

    *phase = "write_restore_target_service_config";
    let target_service_file = temporary.join("postgres-restore-service.conf");
    write_pg_service_config(&target_url, &target_service_file)?;
    *phase = "connect_restore_target";
    *phase = "reconnect_restore_target";
    let target_pool = connect_postgres_target(&target_url).await?;
    let target_server_version: i32 =
        sqlx::query_scalar("SELECT current_setting('server_version_num')::integer")
            .fetch_one(&target_pool)
            .await
            .map_err(|_| {
                ApiError::conflict(
                    "RESTORE_TARGET_UNAVAILABLE",
                    "the isolated PostgreSQL restore target is unavailable",
                )
            })?;
    target_pool.close().await;
    *phase = "run_pg_restore";
    run_pg_restore(
        &target_service_file,
        &temporary.join("postgres.dump"),
        target_server_version,
        &metadata.pg_dump_version,
    )
    .await?;

    let target_pool = connect_postgres_target(&target_url).await?;
    *phase = "upgrade_restored_schema";
    upgrade_restored_postgres_archive(
        &target_pool,
        &metadata.schema,
        manifest.migration_version,
        manifest.runtime_policy.record_restore_retention_days,
    )
    .await?;
    *phase = "finalize_restored_database";
    let generation = finish_postgres_restore(
        &target_pool,
        job_id,
        archive_id,
        &archive_sha256,
        &metadata.schema,
        &metadata.objects,
        &restored_store_id,
        &signing_key_bytes[..],
        &binding,
    )
    .await?;
    target_pool.close().await;

    *phase = "publish_restore_stage";
    for file in manifest.files.iter().filter(|file| {
        file.name == "postgres.dump"
            || file.name == "postgres-metadata.json"
            || is_pg_object_archive_name(&file.name)
    }) {
        fs::remove_file(temporary.join(&file.name)).map_err(ApiError::internal)?;
    }
    fs::remove_file(&target_service_file).map_err(ApiError::internal)?;
    let receipt = PgRestoreStageReceipt {
        format_version: 1,
        job_id: job_id.to_owned(),
        archive_id: archive_id.to_owned(),
        archive_sha256: archive_sha256.clone(),
        generation: generation.clone(),
        schema: metadata.schema,
        object_store_id: restored_store_id,
        restored_objects: metadata.objects.len(),
        binding_id: binding.binding_id.clone(),
        target_fingerprint: binding.target_fingerprint.clone(),
        target_database_oid: binding.target_database_oid,
        target_database_name: binding.target_database_name.clone(),
    };
    let receipt_bytes = serde_jcs::to_vec(&receipt).map_err(ApiError::internal)?;
    write_private_file(
        &temporary.join("postgres-restore-receipt.json"),
        &receipt_bytes,
    )?;
    sync_directory(&temporary).map_err(ApiError::internal)?;
    publish_admin_restore_noreplace(&temporary, &target).map_err(ApiError::internal)?;
    std::mem::forget(stage_guard);
    if sync_directory(&staging_dir).is_err() {
        tracing::warn!(job_id = %job_id, "PostgreSQL restore stage published but staging directory sync failed");
    }
    *phase = "persist_ready_lifecycle";
    persist_pg_admin_restore_stage_ready(
        state,
        job_id,
        archive_id,
        archive_source,
        &receipt.archive_sha256,
        &generation,
        &binding,
    )
    .await
}

async fn upgrade_restored_postgres_archive(
    pool: &PgPool,
    schema: &str,
    archive_schema_version: i64,
    archived_restore_retention_days: i64,
) -> Result<(), ApiError> {
    if !valid_pg_schema_identifier(schema)
        || !supported_pg_archive_schema_version(archive_schema_version)
        || !(1..=3650).contains(&archived_restore_retention_days)
    {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "restored PostgreSQL schema version is not supported",
        ));
    }
    let quoted_schema = format!("\"{schema}\"");
    let marker_sql = format!(
        "SELECT schema_version::BIGINT FROM {quoted_schema}.atermius_instance_schema WHERE singleton=1"
    );
    let source_marker: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "restored PostgreSQL schema version is not supported",
            )
        })?;
    if source_marker != archive_schema_version {
        return Err(ApiError::conflict(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup manifest does not match its database schema",
        ));
    }
    if source_marker == MIN_SUPPORTED_PG_ARCHIVE_SCHEMA_VERSION {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_BACKUP_SCHEDULE_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_schedule: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "restored PostgreSQL schema version is not supported",
            )
        })?;
    if marker_after_schedule == 26 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_SHARED_RELAY_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_relay: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_relay == 27 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_RESTORE_STAGE_DISCARD_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_discard: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_discard == 28 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_REDACTION_CAPABILITY_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_capability: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_capability == 29 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_RECORD_REDACTION_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_redaction: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_redaction == 30 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_REDACTED_CONFLICT_RESOLUTION_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_conflict_resolution: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_conflict_resolution == 31 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_RECORD_RESTORE_DEADLINES_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_restore_deadlines: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_restore_deadlines == 32 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_RECORD_AUTO_PURGE_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_auto_purge: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_auto_purge == 33 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_RECORD_AUTO_PURGE_SCAN_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_auto_purge_scan: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_auto_purge_scan == 34 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_ADMIN_METRICS_CREDENTIAL_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_metrics_credential: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_metrics_credential == 35 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_BACKUP_REPLICATION_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_backup_replication: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_backup_replication == 36 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_BACKUP_REPLICATION_LEASE_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_replication_leases: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_replication_leases == 37 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_REPLICA_RESTORE_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let marker_after_replica_restore: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if marker_after_replica_restore == 38 {
        let migration = format!(
            "BEGIN; SET LOCAL search_path TO {quoted_schema}; {PG_PUSH_DELIVERY_DAILY_MIGRATION}; COMMIT;"
        );
        sqlx::raw_sql(&migration).execute(pool).await.map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    }
    let upgraded_marker: i64 = sqlx::query_scalar(&marker_sql)
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
    if upgraded_marker != PG_BACKUP_SCHEMA_VERSION {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "the restored PostgreSQL schema is not current",
        ));
    }
    let qualified_versions = format!("{quoted_schema}.record_versions");
    let backfill = format!(
        "UPDATE {qualified_versions} SET restore_until=created_at + make_interval(days => $1::INTEGER) \
         WHERE operation='delete' AND restore_until IS NULL"
    );
    sqlx::query(&backfill)
        .bind(archived_restore_retention_days as i32)
        .execute(pool)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "the restored PostgreSQL archive could not be upgraded safely",
            )
        })?;
    reset_postgres_auto_purge_after_restore(pool, schema).await?;
    Ok(())
}

/// Withdraw persisted automatic-purge consent and fence every scanner that
/// could have been running before an archive restore. This is shared with the
/// disposable PostgreSQL acceptance test so it exercises the production reset
/// transaction sequence against a live pending callback.
pub(crate) async fn reset_postgres_auto_purge_after_restore(
    pool: &PgPool,
    schema: &str,
) -> Result<(), ApiError> {
    if !valid_pg_schema_identifier(schema) {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "restored PostgreSQL schema name is not supported",
        ));
    }
    let quoted_schema = format!("\"{schema}\"");
    let qualified_scan_control = format!("{quoted_schema}.record_auto_purge_scan_control");
    let qualified_vault_cursors = format!("{quoted_schema}.record_auto_purge_vault_cursors");
    let mut tx = pool.begin().await.map_err(|_| {
        ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "automatic purge scan state could not be reset after archive restore",
        )
    })?;

    // Take the scanner's shared control row first, matching its checkpoint
    // lock order. Once this update commits, every previously claimed worker
    // fails token/revision fencing before it can write a Vault cursor.
    let reset_scan_control = sqlx::query(&format!(
        "UPDATE {qualified_scan_control} \
         SET after_vault_id=NULL,server_generation=1,cursor_revision=cursor_revision+1, \
             lease_token=NULL,lease_expires_at=NULL,last_scan_status='never', \
             last_scan_started_at=NULL,last_scan_finished_at=NULL, \
             last_scan_candidates=0,last_scan_purged=0,last_scan_not_due=0, \
             last_scan_capability_blocked=0,last_scan_conflict_blocked=0, \
             last_scan_reference_blocked=0,last_scan_stale_or_withdrawn=0 \
         WHERE singleton=1 AND cursor_revision < 9223372036854775807"
    ))
    .execute(&mut *tx)
    .await
    .map_err(|_| {
        ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "automatic purge scan state could not be reset after archive restore",
        )
    })?;
    if reset_scan_control.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "automatic purge scan state could not be safely fenced after archive restore",
        ));
    }

    let auto_purge_opt_out = format!(
        "UPDATE {quoted_schema}.record_graveyard \
         SET auto_purge_enabled=FALSE,auto_purge_revision=CASE \
           WHEN auto_purge_revision < 9223372036854775807 THEN auto_purge_revision+1 \
           ELSE auto_purge_revision END \
         WHERE auto_purge_enabled=TRUE"
    );
    sqlx::query(&auto_purge_opt_out)
        .execute(&mut *tx)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "automatic purge consent could not be reset after archive restore",
            )
        })?;
    sqlx::query(&format!("DELETE FROM {qualified_vault_cursors}"))
        .execute(&mut *tx)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "BACKUP_SCHEMA_UNSUPPORTED",
                "automatic purge scan cursors could not be reset after archive restore",
            )
        })?;
    tx.commit().await.map_err(|_| {
        ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "automatic purge scan state could not be reset after archive restore",
        )
    })?;
    Ok(())
}

async fn connect_postgres_target(database_url: &str) -> Result<PgPool, ApiError> {
    let options = PgConnectOptions::from_str(database_url).map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })?;
    tokio::time::timeout(
        std::time::Duration::from_secs(12),
        PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options),
    )
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })?
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })
}

fn pg_restore_target_fingerprint(database_url: &str) -> String {
    hex::encode(Sha256::digest(database_url.as_bytes()))
}

async fn postgres_restore_target_identity(database_url: &str) -> Result<(i64, String), ApiError> {
    let pool = connect_postgres_target(database_url).await?;
    let identity = sqlx::query(
        "SELECT current_database() AS database_name, \
                (SELECT oid::BIGINT FROM pg_database WHERE datname=current_database()) AS database_oid",
    )
    .fetch_one(&pool)
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target identity is unavailable",
        )
    })?;
    let database_name: String = identity
        .try_get("database_name")
        .map_err(ApiError::internal)?;
    let database_oid: i64 = identity
        .try_get("database_oid")
        .map_err(ApiError::internal)?;
    pool.close().await;
    if database_oid <= 0 || database_name.is_empty() || database_name.len() > 63 {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target identity is invalid",
        ));
    }
    Ok((database_oid, database_name))
}

async fn run_pg_restore(
    service_file: &Path,
    dump_path: &Path,
    target_server_version_num: i32,
    archive_dump_version: &str,
) -> Result<(), ApiError> {
    let version = run_pg_tool_version("pg_restore").await?;
    let restore_major = pg_tool_major(&version)?;
    let archive_major = pg_tool_major(archive_dump_version)?;
    let target_major = target_server_version_num / 10_000;
    if restore_major < archive_major || restore_major < target_major {
        return Err(ApiError::conflict(
            "BACKUP_TOOL_UNSUPPORTED",
            "installed PostgreSQL restore tools are older than the target database",
        ));
    }
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(6 * 60 * 60),
        tokio::process::Command::new("pg_restore")
            .arg("--exit-on-error")
            .arg("--single-transaction")
            .arg("--no-owner")
            .arg("--no-privileges")
            .arg("--dbname=service=atermius-backup")
            .arg(dump_path)
            .env("PGSERVICEFILE", service_file)
            .env_remove("PGPASSWORD")
            .env_remove("PGPASSFILE")
            .env_remove("PGHOST")
            .env_remove("PGPORT")
            .env_remove("PGDATABASE")
            .env_remove("PGUSER")
            .env_remove("PGSERVICE")
            .env_remove("PGOPTIONS")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .status(),
    )
    .await
    .map_err(|_| ApiError::internal("PostgreSQL restore timed out"))?
    .map_err(|_| ApiError::internal("pg_restore could not be started"))?;
    if !output.success() {
        return Err(ApiError::conflict(
            "POSTGRESQL_RESTORE_FAILED",
            "PostgreSQL backup could not be restored into the isolated target",
        ));
    }
    Ok(())
}

async fn finish_postgres_restore(
    pool: &PgPool,
    job_id: &str,
    archive_id: &str,
    archive_sha256: &str,
    schema: &str,
    objects: &[PgArchiveObject],
    target_store_id: &str,
    signing_key_bytes: &[u8],
    binding: &PgRestoreStageBinding,
) -> Result<String, ApiError> {
    if !valid_pg_schema_identifier(schema)
        || schema != binding.schema
        || signing_key_bytes.len() != 32
        || !is_canonical_uuid(job_id)
        || !is_canonical_uuid(archive_id)
        || !is_canonical_uuid(&binding.binding_id)
        || !is_canonical_uuid(target_store_id)
        || binding.object_store_id != target_store_id
        || binding.restored_objects < 0
        || binding.target_database_oid <= 0
        || binding.target_database_name.is_empty()
        || binding.target_fingerprint.len() != 64
    {
        return Err(ApiError::internal("PostgreSQL restore metadata is invalid"));
    }
    let key_bytes: [u8; 32] = signing_key_bytes
        .try_into()
        .map_err(|_| ApiError::internal("PostgreSQL signing key is invalid"))?;
    let signing_key = ed25519_dalek::SigningKey::from_bytes(&key_bytes);
    let expected_public_key = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(signing_key.verifying_key().as_bytes());
    let schema = format!("\"{schema}\"");
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let schema_version: i64 = sqlx::query_scalar(&format!(
        "SELECT schema_version::BIGINT FROM {schema}.atermius_instance_schema WHERE singleton=1"
    ))
    .fetch_one(&mut *tx)
    .await
    .map_err(|_| {
        ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "restored PostgreSQL schema version is not supported",
        )
    })?;
    if schema_version != PG_BACKUP_SCHEMA_VERSION {
        return Err(ApiError::conflict(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "restored PostgreSQL schema version is not supported",
        ));
    }
    let target_identity = sqlx::query(
        "SELECT current_database() AS database_name, \
                (SELECT oid::BIGINT FROM pg_database WHERE datname=current_database()) AS database_oid",
    )
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let target_database_name: String = target_identity
        .try_get("database_name")
        .map_err(ApiError::internal)?;
    let target_database_oid: i64 = target_identity
        .try_get("database_oid")
        .map_err(ApiError::internal)?;
    if target_database_name != binding.target_database_name
        || target_database_oid != binding.target_database_oid
    {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target identity changed",
        ));
    }
    let stored_public_key: String = sqlx::query_scalar(&format!(
        "SELECT signing_public_key FROM {schema}.instance_meta WHERE id=1"
    ))
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if stored_public_key != expected_public_key {
        return Err(ApiError::conflict(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup identity keys do not match",
        ));
    }
    let available_count: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) FROM {schema}.blob_objects WHERE storage_state='available'"
    ))
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if available_count != objects.len() as i64 {
        return Err(ApiError::conflict(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup object manifest does not match the database",
        ));
    }
    for object in objects {
        let updated = sqlx::query(&format!(
            "UPDATE {schema}.blob_objects \
             SET storage_backend='filesystem',storage_store_id=$3 \
             WHERE vault_id=$1 AND object_id=$2 AND storage_state='available' \
               AND storage_key=$4 AND size=$5 AND sha256=$6"
        ))
        .bind(&object.vault_id)
        .bind(&object.object_id)
        .bind(target_store_id)
        .bind(&object.storage_key)
        .bind(object.size)
        .bind(&object.sha256)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "BACKUP_MANIFEST_INVALID",
                "PostgreSQL backup object manifest does not match the database",
            ));
        }
        sqlx::query(&format!(
            "UPDATE {schema}.uploads SET storage_backend='filesystem',storage_store_id=$3,storage_key=$4 \
             WHERE vault_id=$1 AND object_id=$2 AND state='completed'"
        ))
        .bind(&object.vault_id)
        .bind(&object.object_id)
        .bind(target_store_id)
        .bind(&object.storage_key)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }

    let deleting_referenced: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*) FROM {schema}.blob_objects b WHERE b.storage_state='deleting' \
         AND EXISTS(SELECT 1 FROM {schema}.object_references r \
                    WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id)"
    ))
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if deleting_referenced != 0 {
        return Err(ApiError::conflict(
            "BACKUP_MANIFEST_INVALID",
            "PostgreSQL backup contains inconsistent object deletion state",
        ));
    }
    // Delete intents in a backup refer to the source object store. The
    // restore target is a fresh store and must never drain those old intents.
    sqlx::query(&format!("DELETE FROM {schema}.object_delete_queue"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "DELETE FROM {schema}.blob_objects WHERE storage_state='deleting'"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "DELETE FROM {schema}.uploads WHERE state IN ('open','completing')"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.uploads u SET state='collected' \
         WHERE state='completed' AND NOT EXISTS( \
             SELECT 1 FROM {schema}.blob_objects b \
             WHERE b.vault_id=u.vault_id AND b.object_id=u.object_id AND b.storage_state='available')"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    sqlx::query(&format!(
        "UPDATE {schema}.sessions SET revoked_at=COALESCE(revoked_at,clock_timestamp())"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!("DELETE FROM {schema}.notification_tickets"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(&format!("DELETE FROM {schema}.snapshots"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "DELETE FROM {schema}.vault_presence_heartbeat_limits"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!("DELETE FROM {schema}.vault_presence"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(&format!("DELETE FROM {schema}.notification_push_outbox"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

    let now_epoch: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query(&format!("DELETE FROM {schema}.auth_mfa_login_challenges"))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "DELETE FROM {schema}.auth_mfa WHERE enabled_at IS NULL"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.auth_mfa SET last_totp_step=GREATEST(last_totp_step,$1), \
         pending_seed_envelope=NULL,pending_expires_at=NULL,pending_credential_version=NULL \
         WHERE enabled_at IS NOT NULL AND totp_seed_envelope IS NOT NULL"
    ))
    .bind(now_epoch.div_euclid(30))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.auth_mfa_recovery_codes SET consumed_at=$1 WHERE consumed_at IS NULL"
    ))
    .bind(now_epoch)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.account_recovery_challenges SET consumed_at=COALESCE(consumed_at,$1) \
         WHERE consumed_at IS NULL"
    ))
    .bind(now_epoch)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.account_invitations SET revoked_at=COALESCE(revoked_at,clock_timestamp()) \
         WHERE consumed_at IS NULL AND revoked_at IS NULL"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.invitations SET expires_at=GREATEST(created_at + INTERVAL '1 microsecond', \
         clock_timestamp() - INTERVAL '1 second') WHERE accepted_at IS NULL AND expires_at>clock_timestamp()"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.account_deletion_requests SET cancelled_at=COALESCE(cancelled_at,$1) \
         WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL"
    ))
    .bind(now_epoch)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.devices SET account_deletion_request_id=NULL WHERE account_deletion_request_id IS NOT NULL"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.vault_deletion_requests SET cancelled_at=COALESCE(cancelled_at,$1) \
         WHERE cancelled_at IS NULL AND purged_at IS NULL"
    ))
    .bind(now_epoch)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "UPDATE {schema}.instance_admin_jobs SET status='interrupted',finished_at=clock_timestamp(), \
         result_code='interrupted',worker_token=NULL,lease_expires_at=NULL WHERE status IN ('queued','running')"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;

    let generation = Uuid::new_v4().to_string();
    let updated = sqlx::query(&format!(
        "UPDATE {schema}.instance_meta SET generation=$1 WHERE id=1 AND signing_public_key=$2"
    ))
    .bind(&generation)
    .bind(&expected_public_key)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::internal(
            "restored PostgreSQL instance identity could not be rotated",
        ));
    }
    sqlx::query(&format!("CREATE SCHEMA {PG_RESTORE_CONTROL_SCHEMA}"))
        .execute(&mut *tx)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_TARGET_UNAVAILABLE",
                "the isolated PostgreSQL restore target contains unexpected objects",
            )
        })?;
    sqlx::query(&format!(
        "CREATE TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} ( \
             singleton SMALLINT PRIMARY KEY CHECK (singleton=1), \
             binding_id UUID NOT NULL,job_id UUID NOT NULL,archive_id UUID NOT NULL, \
             archive_sha256 TEXT NOT NULL,generation UUID NOT NULL,schema_name TEXT NOT NULL, \
             object_store_id UUID NOT NULL,target_fingerprint TEXT NOT NULL, \
             target_database_oid BIGINT NOT NULL,target_database_name TEXT NOT NULL, \
             restored_objects BIGINT NOT NULL CHECK (restored_objects >= 0), \
             activated_at TIMESTAMPTZ,rollback_started_at TIMESTAMPTZ)"
    ))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(&format!(
        "INSERT INTO {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE}( \
             singleton,binding_id,job_id,archive_id,archive_sha256,generation,schema_name, \
             object_store_id,target_fingerprint,target_database_oid,target_database_name,restored_objects) \
         VALUES(1,$1::UUID,$2::UUID,$3::UUID,$4,$5::UUID,$6,$7::UUID,$8,$9,$10,$11)"
    ))
    .bind(&binding.binding_id)
    .bind(job_id)
    .bind(archive_id)
    .bind(archive_sha256)
    .bind(&generation)
    .bind(&binding.schema)
    .bind(&binding.object_store_id)
    .bind(&binding.target_fingerprint)
    .bind(binding.target_database_oid)
    .bind(&binding.target_database_name)
    .bind(binding.restored_objects)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(generation)
}

async fn read_pinned_postgres_object(
    state: &crate::AppState,
    pg_objects: &crate::pg_objects::PgObjectRepository,
    job_id: &str,
    object: &crate::pg_objects::PgBackupObject,
) -> Result<Zeroizing<Vec<u8>>, ApiError> {
    let read =
        state
            .object_store
            .read_object(&object.storage_key, object.size, &object.sha256, None);
    tokio::pin!(read);
    let mut renew = tokio::time::interval(std::time::Duration::from_secs(30));
    renew.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            result = &mut read => {
                let bytes = result.map_err(crate::object_store::storage_api_error)?;
                if bytes.len() as i64 != object.size
                    || hex::encode(Sha256::digest(&bytes)) != object.sha256
                {
                    return Err(ApiError::internal("PostgreSQL backup object integrity check failed"));
                }
                return Ok(Zeroizing::new(bytes));
            }
            _ = renew.tick() => {
                pg_objects.renew_backup_pins(job_id, PG_BACKUP_PIN_LEASE_SECONDS).await?;
            }
        }
    }
}

async fn run_pg_dump(
    service_file: &Path,
    schema: &str,
    snapshot_id: &str,
    dump_path: &Path,
    server_version_num: i32,
    transaction: &mut Transaction<'_, Postgres>,
    backup_id: &str,
) -> Result<String, ApiError> {
    if !valid_pg_schema_identifier(schema) {
        return Err(ApiError::internal("PostgreSQL backup schema is invalid"));
    }
    let version = run_pg_tool_version("pg_dump").await?;
    let tool_major = pg_tool_major(&version)?;
    let server_major = if server_version_num >= 100_000 {
        server_version_num / 10_000
    } else {
        server_version_num / 10_000
    };
    if tool_major < server_major {
        return Err(ApiError::internal(
            "installed pg_dump is older than the PostgreSQL server",
        ));
    }
    let mut command = tokio::process::Command::new("pg_dump");
    command
        .arg("--format=custom")
        .arg("--no-owner")
        .arg("--no-privileges")
        .arg("--schema")
        .arg(schema)
        .arg("--snapshot")
        .arg(snapshot_id)
        .arg("--file")
        .arg(dump_path)
        .arg("--dbname=service=atermius-backup")
        .env("PGSERVICEFILE", service_file)
        .env_remove("PGPASSWORD")
        .env_remove("PGPASSFILE")
        .env_remove("PGHOST")
        .env_remove("PGPORT")
        .env_remove("PGDATABASE")
        .env_remove("PGUSER")
        .env_remove("PGSERVICE")
        .env_remove("PGOPTIONS")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|_| ApiError::internal("pg_dump could not be started"))?;
    let result = tokio::time::timeout(std::time::Duration::from_secs(6 * 60 * 60), async {
        let mut renew = tokio::time::interval_at(
            tokio::time::Instant::now() + std::time::Duration::from_secs(60),
            std::time::Duration::from_secs(60),
        );
        renew.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                    status = child.wait() => {
                        break status.map_err(|_| ApiError::internal("pg_dump process failed"));
                    }
                    _ = renew.tick() => {
                    crate::pg_objects::renew_backup_pins_tx(
                        transaction,
                        backup_id,
                        PG_BACKUP_PIN_LEASE_SECONDS,
                    )
                    .await?;
                }
            }
        }
    })
    .await
    .map_err(|_| ApiError::internal("PostgreSQL backup dump timed out"))??;
    if !result.success() {
        return Err(ApiError::internal("PostgreSQL backup dump failed"));
    }
    set_private_file_mode(dump_path).map_err(ApiError::internal)?;
    Ok(version)
}

async fn run_pg_tool_version(program: &str) -> Result<String, ApiError> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::process::Command::new(program)
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| ApiError::internal("PostgreSQL client version query timed out"))?
    .map_err(|_| ApiError::internal("required PostgreSQL client tools are unavailable"))?;
    if !output.status.success() {
        return Err(ApiError::internal(
            "required PostgreSQL client tools are unavailable",
        ));
    }
    let value = String::from_utf8(output.stdout)
        .map_err(|_| ApiError::internal("PostgreSQL client version is invalid"))?;
    let value = value.trim();
    if value.len() > 128 || !value.starts_with("pg_") {
        return Err(ApiError::internal("PostgreSQL client version is invalid"));
    }
    Ok(value.to_owned())
}

/// Returns only fixed capability names for the PostgreSQL admin UI. Every
/// capability is backed by the same readiness checks enforced again when the
/// job runs; connection URLs, archive paths, and tool errors never enter the
/// response.
pub(crate) async fn postgres_admin_supported_actions(state: &AppState) -> Vec<&'static str> {
    let mut actions = vec!["maintenance"];
    if !state.pg_sync_only {
        return actions;
    }
    let Some(pool) = state.pg_sync_pool.as_ref() else {
        return actions;
    };
    let Ok(Some(runtime)) = crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env() else {
        return actions;
    };
    let schema_ready = sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM atermius_instance_schema WHERE singleton=1 AND schema_version=$1) \
         AND to_regclass($2) IS NOT NULL \
         AND to_regclass($3) IS NOT NULL \
         AND to_regclass($4) IS NOT NULL \
         AND to_regclass($5) IS NOT NULL \
         AND to_regclass($6) IS NOT NULL",
    )
    .bind(PG_BACKUP_SCHEMA_VERSION)
    .bind(format!("{}.backup_object_pins", runtime.schema))
    .bind(format!("{}.backup_object_pin_sets", runtime.schema))
    .bind(format!("{}.instance_backup_schedule", runtime.schema))
    .bind(format!("{}.instance_admin_jobs", runtime.schema))
    .bind(format!("{}.instance_backup_replications", runtime.schema))
    .fetch_one(pool)
    .await
    .unwrap_or(false);
    if !schema_ready {
        return actions;
    }
    // The shared ledger is sufficient for a safe status read even when this
    // node is not configured to create archives. Backup and restore remain
    // gated by the private storage/key settings below.
    actions.push("backup_status");
    // Replication status is backed by the shared PostgreSQL outbox and is
    // useful even when S3 is not configured; the response reports configured
    // as false without exposing node-local provider settings.
    actions.push("backup_replication");
    actions.push("backup_schedule");
    let target_url = std::env::var("ATERMIUS_PG_RESTORE_TARGET_URL")
        .ok()
        .filter(|value| !value.is_empty());
    if target_url.is_some() && restore_stage_archive_dir(&state.config).is_ok() {
        // Discard needs no backup key or dump/restore utilities.
        actions.push("restore_stage_discard");
    }
    let Ok(settings) = configured_backup_paths(&state.config) else {
        return actions;
    };
    let server_version_num: i32 =
        match sqlx::query_scalar("SELECT current_setting('server_version_num')::integer")
            .fetch_one(pool)
            .await
        {
            Ok(version) => version,
            Err(_) => return actions,
        };
    let Ok(dump_version) = run_pg_tool_version("pg_dump").await else {
        return actions;
    };
    let Ok(restore_version) = run_pg_tool_version("pg_restore").await else {
        return actions;
    };
    let (Ok(dump_major), Ok(restore_major)) = (
        pg_tool_major(&dump_version),
        pg_tool_major(&restore_version),
    ) else {
        return actions;
    };
    let server_major = server_version_num / 10_000;
    if dump_major < server_major || restore_major < dump_major {
        return actions;
    }

    actions.push("backup");
    if let Some(target_url) = target_url.filter(|_| {
        runtime.schema != "public"
            && runtime.schema != "information_schema"
            && runtime.schema != PG_RESTORE_CONTROL_SCHEMA
            && !runtime.schema.starts_with("pg_")
    }) && postgres_restore_target_ready(pool, &target_url).await
    {
        actions.push("restore");
        if crate::backup_replication::settings_configured(&state.config) {
            actions.push("restore_replica");
        }
    }
    // Keep the borrow/use explicit: resolving settings above also checks the
    // operator-owned archive directory and encryption key on every response.
    let _ = settings;
    actions
}

async fn postgres_restore_target_ready(source_pool: &PgPool, database_url: &str) -> bool {
    let Ok(options) = PgConnectOptions::from_str(database_url) else {
        return false;
    };
    let target_pool = match tokio::time::timeout(
        std::time::Duration::from_secs(3),
        PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options),
    )
    .await
    {
        Ok(Ok(pool)) => pool,
        _ => return false,
    };
    let result = async {
        let source_identity = sqlx::query(
            "SELECT current_database() AS database_name,inet_server_addr()::text AS server_address, \
                    inet_server_port() AS server_port,pg_postmaster_start_time() AS server_started",
        )
        .fetch_one(source_pool)
        .await
        .map_err(|_| ())?;
        let target_identity = sqlx::query(
            "SELECT current_database() AS database_name,inet_server_addr()::text AS server_address, \
                    inet_server_port() AS server_port,pg_postmaster_start_time() AS server_started, \
                    has_database_privilege(current_user,current_database(),'CREATE') AS can_create_database_objects, \
                    has_schema_privilege(current_user,'public','CREATE') AS can_create_public_objects, \
                    NOT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname NOT IN ('public','information_schema') AND nspname !~ '^pg_') \
                      AND NOT EXISTS(SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace \
                                     WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')) AS is_empty",
        )
        .fetch_one(&target_pool)
        .await
        .map_err(|_| ())?;
        let same_database = source_identity.try_get::<String, _>("database_name").map_err(|_| ())?
            == target_identity.try_get::<String, _>("database_name").map_err(|_| ())?
            && source_identity.try_get::<Option<String>, _>("server_address").map_err(|_| ())?
                == target_identity.try_get::<Option<String>, _>("server_address").map_err(|_| ())?
            && source_identity.try_get::<Option<i32>, _>("server_port").map_err(|_| ())?
                == target_identity.try_get::<Option<i32>, _>("server_port").map_err(|_| ())?
            && source_identity.try_get::<chrono::DateTime<chrono::Utc>, _>("server_started").map_err(|_| ())?
                == target_identity.try_get::<chrono::DateTime<chrono::Utc>, _>("server_started").map_err(|_| ())?;
        let can_create: bool = target_identity.try_get("can_create_database_objects").map_err(|_| ())?;
        let can_create_public: bool = target_identity.try_get("can_create_public_objects").map_err(|_| ())?;
        let is_empty: bool = target_identity.try_get("is_empty").map_err(|_| ())?;
        Ok::<bool, ()>(!same_database && can_create && can_create_public && is_empty)
    }
    .await;
    target_pool.close().await;
    result.unwrap_or(false)
}

fn pg_tool_major(version: &str) -> Result<i32, ApiError> {
    version
        .split_once(") ")
        .map(|(_, version)| version)
        .unwrap_or(version)
        .split_whitespace()
        .next()
        .and_then(|value| value.split('.').next())
        .and_then(|value| value.parse::<i32>().ok())
        .filter(|value| (9..=99).contains(value))
        .ok_or_else(|| ApiError::internal("PostgreSQL client version is invalid"))
}

fn valid_pg_schema_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 63
        && value.bytes().enumerate().all(|(index, byte)| {
            byte == b'_' || (byte.is_ascii_alphanumeric() && (index > 0 || !byte.is_ascii_digit()))
        })
}

async fn validate_pg_dump(dump_path: &Path) -> Result<(), ApiError> {
    let output = tokio::time::timeout(
        std::time::Duration::from_secs(10 * 60),
        tokio::process::Command::new("pg_restore")
            .arg("--list")
            .arg(dump_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .map_err(|_| ApiError::internal("PostgreSQL backup archive validation timed out"))?
    .map_err(|_| ApiError::internal("required PostgreSQL restore tools are unavailable"))?;
    if !output.status.success() {
        return Err(ApiError::internal("PostgreSQL backup dump is invalid"));
    }
    Ok(())
}

fn write_pg_service_config(database_url: &str, path: &Path) -> Result<(), ApiError> {
    let parsed = url::Url::parse(database_url)
        .map_err(|_| ApiError::internal("PostgreSQL backup connection settings are invalid"))?;
    if !matches!(parsed.scheme(), "postgres" | "postgresql") || parsed.fragment().is_some() {
        return Err(ApiError::internal(
            "PostgreSQL backup connection settings are invalid",
        ));
    }
    let database = percent_decode_url_component(parsed.path().trim_start_matches('/'))?;
    let username = percent_decode_url_component(parsed.username())?;
    if database.is_empty() {
        return Err(ApiError::internal(
            "PostgreSQL backup connection settings are invalid",
        ));
    }
    let mut values = std::collections::BTreeMap::new();
    // A hostless PostgreSQL URI intentionally selects libpq's default local
    // socket. Omit the field so pg_dump uses the same default as the service
    // connection rather than turning an empty host into an invalid value.
    if let Some(host) = parsed.host_str() {
        values.insert("host".to_owned(), host.to_owned());
    }
    values.insert("dbname".to_owned(), database);
    if !username.is_empty() {
        values.insert("user".to_owned(), username);
    }
    if let Some(port) = parsed.port() {
        values.insert("port".to_owned(), port.to_string());
    }
    if let Some(password) = parsed.password() {
        values.insert(
            "password".to_owned(),
            percent_decode_url_component(password)?,
        );
    }
    const ALLOWED_PARAMETERS: &[&str] = &[
        "application_name",
        "channel_binding",
        "connect_timeout",
        "gssencmode",
        "hostaddr",
        "keepalives",
        "keepalives_count",
        "keepalives_idle",
        "keepalives_interval",
        "options",
        "sslcert",
        "sslcrl",
        "sslcrldir",
        "sslkey",
        "sslmode",
        "sslrootcert",
        "target_session_attrs",
        "tcp_user_timeout",
    ];
    for (name, value) in parsed.query_pairs() {
        if !ALLOWED_PARAMETERS.contains(&name.as_ref()) {
            return Err(ApiError::internal(
                "PostgreSQL backup connection settings contain an unsupported option",
            ));
        }
        values.insert(name.into_owned(), value.into_owned());
    }
    let mut content = String::from("[atermius-backup]\n");
    for (name, value) in values {
        // libpq's service-file reader treats each line as a literal
        // `name=value` pair: unlike conninfo strings, single quotes and
        // backslashes do not escape service-file values. It also trims
        // trailing whitespace, so reject values that would be changed.
        if value.contains(['\n', '\r', '\0'])
            || value.chars().last().is_some_and(char::is_whitespace)
        {
            return Err(ApiError::internal(
                "PostgreSQL backup connection settings are invalid",
            ));
        }
        content.push_str(&name);
        content.push('=');
        content.push_str(&value);
        content.push('\n');
    }
    write_private_file(path, content.as_bytes())
}

fn percent_decode_url_component(value: &str) -> Result<String, ApiError> {
    let mut decoded = Vec::with_capacity(value.len());
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                return Err(ApiError::internal(
                    "PostgreSQL backup connection settings are invalid",
                ));
            }
            let high = (bytes[index + 1] as char).to_digit(16);
            let low = (bytes[index + 2] as char).to_digit(16);
            let (Some(high), Some(low)) = (high, low) else {
                return Err(ApiError::internal(
                    "PostgreSQL backup connection settings are invalid",
                ));
            };
            decoded.push(((high << 4) | low) as u8);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded)
        .map_err(|_| ApiError::internal("PostgreSQL backup connection settings are invalid"))
}

async fn backup_instance_from_pool(
    pool: &SqlitePool,
    config: &Config,
    archive_path: &Path,
    backup_key_path: &Path,
) -> Result<BackupSummary, ApiError> {
    let object_store = crate::object_store::ObjectStore::from_env(config)?;
    backup_instance_from_pool_with_object_store(
        pool,
        config,
        archive_path,
        backup_key_path,
        &object_store,
    )
    .await
}

async fn backup_instance_from_pool_with_object_store(
    pool: &SqlitePool,
    config: &Config,
    archive_path: &Path,
    backup_key_path: &Path,
    object_store: &crate::object_store::ObjectStore,
) -> Result<BackupSummary, ApiError> {
    let data_dir = &config.data_dir;
    secure_file::secure_existing_data_dir(data_dir)?;
    ensure_path_outside_data_dir(data_dir, backup_key_path)?;
    ensure_path_outside_data_dir(data_dir, archive_path)?;
    let backup_key = Zeroizing::new(secure_file::read_private_key(backup_key_path)?);
    let db_path = data_dir.join("atermius.db");
    if !fs::symlink_metadata(&db_path)
        .map(|metadata| metadata.file_type().is_file())
        .unwrap_or(false)
    {
        return Err(ApiError::internal(
            "the configured instance database is missing or is not a regular file",
        ));
    }

    let snapshot_dir = create_private_temp_dir(data_dir, "backup-snapshot")?;
    let snapshot = snapshot_dir.0.join("database.sqlite");
    let snapshot_name = snapshot.to_string_lossy().to_string();
    {
        // VACUUM INTO reads one SQLite snapshot. In WAL mode it includes all
        // committed WAL pages and does not copy a live .db file out of band.
        let mut connection = pool.acquire().await.map_err(ApiError::internal)?;
        sqlx::query("VACUUM INTO ?")
            .bind(snapshot_name)
            .execute(&mut *connection)
            .await
            .map_err(ApiError::internal)?;
    }
    set_private_file_mode(&snapshot).map_err(ApiError::internal)?;
    object_store.validate_catalogue(pool).await?;
    object_store
        .hydrate_for_backup(&sqlite_url(&snapshot))
        .await?;
    validate_sqlite_file(&snapshot).await?;

    let signing_key = Zeroizing::new(secure_file::read_private_key(
        &data_dir.join("instance-ed25519.key"),
    )?);
    write_private_file(&snapshot_dir.0.join("instance-ed25519.key"), &*signing_key)?;
    let auth_rate_key = Zeroizing::new(secure_file::read_private_key(
        &data_dir.join("auth-rate-limit.key"),
    )?);
    write_private_file(&snapshot_dir.0.join("auth-rate-limit.key"), &*auth_rate_key)?;

    let migration_version: Option<i64> =
        sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations WHERE success=1")
            .fetch_one(pool)
            .await
            .map_err(ApiError::internal)?;
    let migration_version = migration_version
        .ok_or_else(|| ApiError::internal("instance migration version is missing"))?;

    let source_files = ALLOWED_FILES
        .iter()
        .map(|name| SourceFile {
            name: (*name).to_owned(),
            path: snapshot_dir.0.join(name),
        })
        .collect::<Vec<_>>();
    let manifest = build_manifest(&source_files, migration_version, config)?;
    let (output, mut archive_file) = create_private_archive_temp(archive_path)?;
    write_encrypted_archive(&mut archive_file, &backup_key, &manifest, &source_files)
        .map_err(ApiError::internal)?;
    archive_file.sync_all().map_err(ApiError::internal)?;
    drop(archive_file);
    fs::hard_link(&output.0, archive_path).map_err(ApiError::internal)?;
    drop(output);
    sync_parent(archive_path).map_err(ApiError::internal)?;
    let archive_bytes = fs::metadata(archive_path)
        .map_err(ApiError::internal)?
        .len();
    if archive_bytes == 0 || archive_bytes > MAX_BACKUP_ARCHIVE_BYTES {
        return Err(ApiError::internal(
            "generated backup archive size is invalid",
        ));
    }
    let (_, archive_sha256) = open_and_hash_generated_archive(archive_path)?;
    Ok(BackupSummary {
        migration_version,
        archive_bytes,
        archive_sha256,
    })
}

/// Restores an archive into a new directory while preserving the active data
/// directory. The source directory lock enforces server-stopped operation;
/// the new directory is published only after migration, identity, integrity,
/// and foreign-key checks succeed.
pub async fn restore_instance_to_new_directory(
    config: Config,
    archive_path: &Path,
    backup_key_path: &Path,
    target_data_dir: &Path,
) -> Result<String, ApiError> {
    let result = restore_instance_with_runtime_policy_drift(
        config,
        archive_path,
        backup_key_path,
        target_data_dir,
        false,
    )
    .await?;
    Ok(result.generation)
}

/// Restores an instance only when the effective policy in the archive matches
/// the target process configuration, unless the operator explicitly accepts
/// policy drift. Returned drift contains field names only, never values.
pub async fn restore_instance_with_runtime_policy_drift(
    config: Config,
    archive_path: &Path,
    backup_key_path: &Path,
    target_data_dir: &Path,
    accept_runtime_policy_drift: bool,
) -> Result<RestoreResult, ApiError> {
    secure_file::secure_existing_data_dir(&config.data_dir)?;
    ensure_path_outside_data_dir(&config.data_dir, backup_key_path)?;
    ensure_path_outside_data_dir(&config.data_dir, archive_path)?;
    let source_dir = fs::canonicalize(&config.data_dir).map_err(ApiError::internal)?;
    if !source_dir.is_dir() {
        return Err(ApiError::bad_request(
            "INVALID_DATA_DIR",
            "the active data directory must already exist",
        ));
    }
    let _runtime_lock = acquire_runtime_lock(&source_dir)?;

    let backup_key = Zeroizing::new(secure_file::read_private_key(backup_key_path)?);
    let archive = open_private_archive(archive_path).map_err(ApiError::internal)?;
    let target = prepare_new_target_path(target_data_dir, &source_dir)?;
    let stage_path = target
        .parent()
        .unwrap()
        .join(format!(".atermius-restore-{}.staging", Uuid::new_v4()));
    let stage = TempDirectory(stage_path.clone());
    let (generation, runtime_policy_drift_fields) = restore_archive_into_private_stage(
        config,
        archive,
        &backup_key,
        &stage_path,
        accept_runtime_policy_drift,
    )
    .await?;

    publish_directory_noreplace(&stage_path, &target).map_err(ApiError::internal)?;
    std::mem::forget(stage);
    sync_directory(target.parent().unwrap()).map_err(ApiError::internal)?;
    Ok(RestoreResult {
        generation,
        accepted_runtime_policy_drift_fields: runtime_policy_drift_fields,
    })
}

async fn restore_archive_into_private_stage(
    mut config: Config,
    archive: File,
    backup_key: &[u8; 32],
    stage_path: &Path,
    accept_runtime_policy_drift: bool,
) -> Result<(String, Vec<String>), ApiError> {
    create_private_dir(stage_path).map_err(ApiError::internal)?;
    let manifest =
        read_encrypted_archive(archive, backup_key, stage_path).map_err(ApiError::internal)?;
    let runtime_policy_drift_fields =
        runtime_policy_drift_fields(&manifest.runtime_policy, &config)?;
    if !runtime_policy_drift_fields.is_empty() && !accept_runtime_policy_drift {
        return Err(runtime_policy_drift_error(&runtime_policy_drift_fields));
    }
    if manifest.migration_version > current_migration_version() {
        return Err(ApiError::bad_request(
            "BACKUP_SCHEMA_UNSUPPORTED",
            "backup schema is newer than this server",
        ));
    }
    let database_path = stage_path.join("atermius.db");
    validate_sqlite_file(&database_path).await?;
    if sqlite_schema_version(&database_path).await? != manifest.migration_version {
        return Err(ApiError::bad_request(
            "BACKUP_MANIFEST_INVALID",
            "backup migration version does not match its database",
        ));
    }

    config.data_dir = stage_path.to_path_buf();
    let state = crate::open_state_with_restore_policy(
        &sqlite_url(&database_path),
        config,
        manifest.runtime_policy.record_restore_retention_days,
    )
    .await?;
    let generation = Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let updated = sqlx::query("UPDATE instance_meta SET generation=? WHERE id=1")
        .bind(&generation)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::internal("restored instance metadata is missing"));
    }
    sqlx::query("UPDATE sessions SET revoked_at=COALESCE(revoked_at,?)")
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query(
        "UPDATE record_graveyard SET auto_purge_enabled=0, \
             auto_purge_revision=CASE WHEN auto_purge_revision < 9223372036854775807 \
                                      THEN auto_purge_revision+1 ELSE auto_purge_revision END \
         WHERE auto_purge_enabled=1",
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM record_auto_purge_vault_cursors")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let scan_control_reset = sqlx::query(
        "UPDATE record_auto_purge_scan_control \
         SET after_vault_id=NULL,server_generation=1,cursor_revision=cursor_revision+1, \
             lease_token=NULL,lease_expires_at=NULL,last_scan_status='never', \
             last_scan_started_at=NULL,last_scan_finished_at=NULL, \
             last_scan_candidates=0,last_scan_purged=0,last_scan_not_due=0, \
             last_scan_capability_blocked=0,last_scan_conflict_blocked=0, \
             last_scan_reference_blocked=0,last_scan_stale_or_withdrawn=0 \
         WHERE singleton=1 AND cursor_revision < 9223372036854775807",
    )
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if scan_control_reset.rows_affected() != 1 {
        return Err(ApiError::internal(
            "automatic purge scan state could not be safely fenced after archive restore",
        ));
    }
    crate::mfa::invalidate_after_restore_tx(&mut tx, &state, chrono::Utc::now().timestamp())
        .await?;
    tx.commit().await.map_err(ApiError::internal)?;

    validate_pool(&state).await?;
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_all(&state.db)
        .await
        .map_err(ApiError::internal)?;
    state.db.close().await;
    drop(state);
    remove_sqlite_sidecars(&database_path).map_err(ApiError::internal)?;
    validate_sqlite_file(&database_path).await?;
    sync_directory(stage_path).map_err(ApiError::internal)?;
    Ok((generation, runtime_policy_drift_fields))
}

/// Restores a verified generated archive into its fixed Web-requested staging
/// directory. This online-only path intentionally does not take the active
/// runtime lock: the server already owns that lock for its lifetime. The
/// caller holds the shared maintenance mutex and OS maintenance lock.
pub(crate) async fn run_configured_admin_restore_stage(
    state: &crate::AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
) -> Result<(), ApiError> {
    if !is_canonical_uuid(job_id) || !is_canonical_uuid(archive_id) {
        return Err(ApiError::internal("restore job identifiers are invalid"));
    }
    if state.pg_sync_only {
        return run_configured_pg_admin_restore_stage(state, job_id, archive_id, archive_source)
            .await;
    }
    let _maintenance_guard = crate::acquire_instance_maintenance_lock(state).await?;
    let settings = configured_backup_paths(&state.config)?;
    let staging_dir = ensure_restore_staging_dir(&settings.archive_dir)?;
    let target = staging_dir.join(format!("atermius-restore-{job_id}"));
    let temporary = staging_dir.join(format!("atermius-restore-{job_id}.staging"));
    ensure_restore_stage_paths_absent(&target, &temporary)?;
    ensure_path_outside_data_dir(&state.config.data_dir, &target)?;

    let backup_key = Zeroizing::new(secure_file::read_private_key(&settings.key_file)?);
    let runtime_policy_sha256 = runtime_policy_sha256(&state.config)?;
    let (archive_path, remote_archive) = match archive_source {
        crate::backup_replication::ArchiveSource::Local => {
            let sources =
                resolved_server_generated_restore_sources_with_settings(state, &settings).await?;
            let Some((_, archive_path)) = sources
                .into_iter()
                .find(|(source, _)| source.archive_id == archive_id && source.source == "local")
            else {
                return Err(ApiError::conflict(
                    "RESTORE_SOURCE_UNAVAILABLE",
                    "the selected server backup is unavailable for restore",
                ));
            };
            (archive_path, None)
        }
        crate::backup_replication::ArchiveSource::Replica => {
            let remote_path = staging_dir.join(format!("atermius-restore-{job_id}.source.atb"));
            ensure_restore_source_path_absent(&remote_path)?;
            let Some((expected_bytes, expected_sha256)) =
                crate::backup_replication::replica_archive_metadata(state, archive_id).await?
            else {
                return Err(ApiError::conflict(
                    "RESTORE_SOURCE_UNAVAILABLE",
                    "the selected server backup is unavailable for restore",
                ));
            };
            let (remote_archive, _, _) = crate::backup_replication::download_replica_archive(
                state,
                archive_id,
                &remote_path,
                expected_bytes,
                &expected_sha256,
            )
            .await?;
            verify_instance_backup(&state.config.data_dir, &remote_path, &settings.key_file)
                .await
                .map_err(|_| {
                    ApiError::conflict(
                        "RESTORE_SOURCE_UNAVAILABLE",
                        "the selected server backup is unavailable for restore",
                    )
                })?;
            (remote_path, Some(remote_archive))
        }
    };
    let (archive, archive_sha256) = open_and_hash_generated_archive(&archive_path)?;
    let stage = TempDirectory(temporary.clone());
    let (generation, drift_fields) = restore_archive_into_private_stage(
        (*state.config).clone(),
        archive,
        &backup_key,
        &temporary,
        false,
    )
    .await?;
    if !drift_fields.is_empty() {
        return Err(runtime_policy_drift_error(&drift_fields));
    }
    persist_admin_restore_archive_digest(
        state,
        job_id,
        archive_id,
        archive_source,
        &archive_sha256,
    )
    .await?;
    let receipt = RestoreStageReceipt {
        job_id: job_id.to_owned(),
        archive_id: archive_id.to_owned(),
        archive_source: archive_source.as_str().to_owned(),
        archive_sha256,
        generation: generation.clone(),
        runtime_policy_sha256: Some(runtime_policy_sha256),
    };
    write_restore_stage_receipt(&temporary, &receipt)?;
    sync_directory(&temporary).map_err(ApiError::internal)?;
    publish_admin_restore_noreplace(&temporary, &target).map_err(ApiError::internal)?;
    std::mem::forget(stage);
    // The staged database, receipt and directory are already fsynced. A
    // failed parent fsync is surfaced as a warning because the no-replace
    // publish succeeded and retrying would risk a second target.
    if sync_directory(&staging_dir).is_err() {
        tracing::warn!(job_id = %job_id, "restore stage published but staging directory sync failed");
    }
    persist_admin_restore_stage_ready(state, &receipt).await?;
    drop(remote_archive);
    Ok(())
}

/// Installs a completed Web-created restore stage into a new, offline data
/// directory. The active data directory is opened only read-only (including
/// its pre-existing runtime lock) and is never migrated or rewritten.
pub async fn install_configured_admin_restore_stage(
    config: Config,
    job_id: &str,
    target_data_dir: &Path,
) -> Result<String, ApiError> {
    if !cfg!(target_os = "linux") {
        return Err(ApiError::bad_request(
            "RESTORE_INSTALL_UNSUPPORTED",
            "restore stage installation requires Linux no-replace directory publication",
        ));
    }
    if !is_canonical_uuid(job_id) {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_JOB_ID",
            "restore job ID must be a canonical lowercase UUID",
        ));
    }

    secure_file::secure_existing_data_dir(&config.data_dir)?;
    let source_dir = fs::canonicalize(&config.data_dir).map_err(ApiError::internal)?;
    let _runtime_lock = acquire_existing_runtime_lock_read_only(&source_dir)?;
    reject_uncheckpointed_source_sidecars(&source_dir)?;
    let source_database = source_dir.join("atermius.db");
    validate_source_database_metadata(&source_database)?;

    let settings = configured_backup_paths(&config)?;
    let staging_dir =
        ensure_restore_staging_dir_if_present(&settings.archive_dir)?.ok_or_else(|| {
            ApiError::conflict("RESTORE_STAGE_UNAVAILABLE", "restore stage is unavailable")
        })?;
    let stage_dir = staging_dir.join(format!("atermius-restore-{job_id}"));
    ensure_path_outside_data_dir(&source_dir, &stage_dir)?;

    // The source-volume database is inspected through SQLite's immutable,
    // read-only mode. Its sidecars are checked above so this view cannot omit
    // committed job state held only in a WAL file.
    validate_sqlite_file(&source_database).await?;
    if sqlite_schema_version(&source_database).await? != current_migration_version() {
        return Err(ApiError::conflict(
            "RESTORE_SOURCE_SCHEMA_UNSUPPORTED",
            "the active database schema is not compatible with this installer",
        ));
    }
    let source_pool = open_immutable_read_only_database(&source_database).await?;
    let job = sqlx::query(
        "SELECT j.archive_id,j.archive_source,j.archive_sha256,j.status,j.result_code, \
                s.generation,s.status AS stage_status \
         FROM instance_admin_jobs j \
         JOIN instance_admin_restore_stages s ON s.restore_job_id=j.job_id \
         WHERE j.job_id=? AND j.action='restore'",
    )
    .bind(job_id)
    .fetch_optional(&source_pool)
    .await
    .map_err(ApiError::internal)?;
    source_pool.close().await;
    let Some(job) = job else {
        return Err(ApiError::not_found());
    };
    if job.get::<String, _>("status") != "succeeded"
        || job.get::<Option<String>, _>("result_code").as_deref() != Some("completed")
        || job.get::<String, _>("stage_status") != "ready"
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "only a completed, ready restore stage can be installed",
        ));
    }
    let archive_id = job
        .get::<Option<String>, _>("archive_id")
        .ok_or_else(|| ApiError::internal("completed restore job has no archive ID"))?;
    let archive_source: String = job.get("archive_source");
    if !matches!(archive_source.as_str(), "local" | "replica") {
        return Err(ApiError::internal("restore job source is invalid"));
    }
    let archive_sha256 = job
        .get::<Option<String>, _>("archive_sha256")
        .ok_or_else(|| ApiError::internal("completed restore job has no archive digest"))?;
    let generation: String = job.get("generation");
    if !is_canonical_uuid(&archive_id)
        || !is_sha256_hex(&archive_sha256)
        || !is_canonical_uuid(&generation)
    {
        return Err(ApiError::internal("restore job binding is invalid"));
    }

    let policy_sha256 = runtime_policy_sha256(&config)?;
    validate_admin_restore_stage_for_install(
        &stage_dir,
        job_id,
        &archive_id,
        &archive_source,
        &archive_sha256,
        &generation,
        &policy_sha256,
    )
    .await?;

    let target = prepare_new_target_path(target_data_dir, &source_dir)?;
    let archive_dir = fs::canonicalize(&settings.archive_dir).map_err(ApiError::internal)?;
    if target.starts_with(&archive_dir) || archive_dir.starts_with(&target) {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_PATH",
            "restore destination must be separate from the backup volume",
        ));
    }
    let parent = target.parent().ok_or_else(|| {
        ApiError::bad_request("INVALID_RESTORE_PATH", "restore destination is invalid")
    })?;
    let temporary = create_private_temp_dir(parent, "atermius-restore-install")?;

    for name in RESTORE_STAGE_DATA_FILES {
        copy_private_restore_stage_file(&stage_dir.join(name), &temporary.0.join(name))?;
    }
    sync_directory(&temporary.0).map_err(ApiError::internal)?;
    validate_installed_restore_payload(&temporary.0, &generation).await?;

    // No-replace publication is the commit point. The temporary directory is
    // on the target volume, so publication does not cross filesystem/device
    // boundaries. Errors before this point remove only the new-volume temp.
    publish_admin_restore_noreplace(&temporary.0, &target).map_err(ApiError::internal)?;
    std::mem::forget(temporary);
    map_published_parent_sync(sync_directory(parent))?;
    Ok(generation)
}

fn map_published_parent_sync(sync_result: io::Result<()>) -> Result<(), ApiError> {
    sync_result.map_err(|_| {
        ApiError::conflict(
            "RESTORE_PUBLISHED_DURABILITY_UNCERTAIN",
            "the restore target was published, but durability sync is uncertain; inspect the target before retrying",
        )
    })
}

async fn open_immutable_read_only_database(path: &Path) -> Result<SqlitePool, ApiError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .immutable(true)
        .foreign_keys(true);
    SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(ApiError::internal)
}

fn acquire_existing_runtime_lock_read_only(data_dir: &Path) -> Result<File, ApiError> {
    let path = data_dir.join("server.lock");
    let before = fs::symlink_metadata(&path).map_err(|_| {
        ApiError::conflict(
            "SERVER_LOCK_UNAVAILABLE",
            "an existing server lock is required; the source volume was not changed",
        )
    })?;
    validate_private_restore_file_metadata(&before)?;
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(&path).map_err(ApiError::internal)?;
    let opened = file.metadata().map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&opened)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.dev() != opened.dev() || before.ino() != opened.ino() {
            return Err(ApiError::conflict(
                "SERVER_LOCK_UNAVAILABLE",
                "the server lock changed while opening the source volume",
            ));
        }
    }
    file.try_lock().map_err(|_| {
        ApiError::conflict(
            "SERVER_RUNNING",
            "the source data directory is locked by a running server process",
        )
    })?;
    Ok(file)
}

fn reject_uncheckpointed_source_sidecars(data_dir: &Path) -> Result<(), ApiError> {
    let database = data_dir.join("atermius.db");
    for suffix in ["-wal", "-shm", "-journal"] {
        let path = PathBuf::from(format!("{}{suffix}", database.display()));
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                return Err(ApiError::conflict(
                    "RESTORE_SOURCE_NOT_QUIESCENT",
                    "the source database still has a SQLite WAL, SHM, or rollback-journal sidecar; checkpoint and fully close it before installation",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Ok(())
}

fn validate_source_database_metadata(path: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(path).map_err(ApiError::internal)?;
    if !metadata.file_type().is_file() {
        return Err(ApiError::internal("source database is not a regular file"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.nlink() != 1 {
            return Err(ApiError::internal("source database file is unsafe"));
        }
    }
    Ok(())
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

async fn validate_admin_restore_stage_for_install(
    stage_dir: &Path,
    job_id: &str,
    archive_id: &str,
    archive_source: &str,
    archive_sha256: &str,
    expected_generation: &str,
    expected_policy_sha256: &str,
) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(stage_dir).map_err(ApiError::internal)?;
    validate_private_directory_metadata(&metadata)?;
    let mut actual = fs::read_dir(stage_dir)
        .map_err(ApiError::internal)?
        .map(|entry| {
            entry
                .map_err(ApiError::internal)?
                .file_name()
                .into_string()
                .map_err(|_| {
                    ApiError::conflict(
                        "RESTORE_STAGE_UNAVAILABLE",
                        "restore stage contains an unknown file",
                    )
                })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let mut expected = RESTORE_STAGE_DATA_FILES
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    expected.push(RESTORE_STAGE_RECEIPT_FILE.to_owned());
    actual.sort();
    expected.sort();
    if actual != expected {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "restore stage contains missing or unknown files, including SQLite sidecars",
        ));
    }

    let receipt = read_restore_stage_receipt(stage_dir)?;
    if receipt.job_id != job_id
        || receipt.archive_id != archive_id
        || receipt.archive_source != archive_source
        || receipt.archive_sha256 != archive_sha256
        || receipt.generation != expected_generation
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "restore stage receipt does not match its durable restore job",
        ));
    }
    let Some(receipt_policy_sha256) = receipt.runtime_policy_sha256.as_deref() else {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_POLICY_UNVERIFIABLE",
            "this stage predates runtime-policy binding; prepare a new restore stage",
        ));
    };
    if receipt_policy_sha256 != expected_policy_sha256 {
        return Err(ApiError::conflict(
            "RUNTIME_POLICY_DRIFT",
            "the current runtime policy differs from the policy used to prepare this stage",
        ));
    }

    for name in RESTORE_STAGE_DATA_FILES {
        let path = stage_dir.join(name);
        let metadata = fs::symlink_metadata(&path).map_err(ApiError::internal)?;
        validate_private_restore_file_metadata(&metadata)?;
        if name != "atermius.db" {
            let _key = Zeroizing::new(secure_file::read_private_key(&path)?);
        }
    }
    let database = stage_dir.join("atermius.db");
    validate_private_restore_database(&database)?;
    validate_sqlite_file(&database).await?;
    if sqlite_schema_version(&database).await? != current_migration_version() {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_SCHEMA_UNSUPPORTED",
            "restore stage schema differs from the installer schema; prepare a new stage",
        ));
    }
    if sqlite_instance_generation(&database).await? != expected_generation {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "restore stage generation does not match its receipt",
        ));
    }
    Ok(())
}

fn copy_private_restore_stage_file(source: &Path, target: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(source).map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&metadata)?;
    let mut input = open_regular_file(source, true).map_err(ApiError::internal)?;
    let opened_metadata = input.metadata().map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&opened_metadata)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.dev() != opened_metadata.dev() || metadata.ino() != opened_metadata.ino() {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "restore stage changed while opening a file",
            ));
        }
    }
    let mut output = create_private_file(target).map_err(ApiError::internal)?;
    io::copy(&mut input, &mut output).map_err(ApiError::internal)?;
    output.sync_all().map_err(ApiError::internal)?;
    Ok(())
}

async fn validate_installed_restore_payload(
    target_dir: &Path,
    expected_generation: &str,
) -> Result<(), ApiError> {
    validate_private_directory_metadata(
        &fs::symlink_metadata(target_dir).map_err(ApiError::internal)?,
    )?;
    let mut actual = fs::read_dir(target_dir)
        .map_err(ApiError::internal)?
        .map(|entry| {
            entry
                .map_err(ApiError::internal)?
                .file_name()
                .into_string()
                .map_err(|_| ApiError::internal("installed restore contains an unknown file"))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let mut expected = RESTORE_STAGE_DATA_FILES
        .into_iter()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    actual.sort();
    expected.sort();
    if actual != expected {
        return Err(ApiError::internal("installed restore file set is invalid"));
    }
    for name in RESTORE_STAGE_DATA_FILES {
        let path = target_dir.join(name);
        let metadata = fs::symlink_metadata(&path).map_err(ApiError::internal)?;
        validate_private_restore_file_metadata(&metadata)?;
        if name != "atermius.db" {
            let _key = Zeroizing::new(secure_file::read_private_key(&path)?);
        }
    }
    let database = target_dir.join("atermius.db");
    validate_sqlite_file(&database).await?;
    if sqlite_schema_version(&database).await? != current_migration_version()
        || sqlite_instance_generation(&database).await? != expected_generation
    {
        return Err(ApiError::internal(
            "installed restore database does not match its stage",
        ));
    }
    Ok(())
}

/// Reconciles only the exact fixed target and temporary names for a durable
/// restore job. `true` means a valid published stage exists and the caller may
/// complete the job; `false` means no target exists and the exact temp tree was
/// safely removed, so the caller should mark the job interrupted without
/// replaying it.
pub(crate) async fn reconcile_admin_restore_stage(
    state: &crate::AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: Option<&str>,
) -> Result<bool, ApiError> {
    if !is_canonical_uuid(job_id) || !is_canonical_uuid(archive_id) {
        return Err(ApiError::internal("restore job identifiers are invalid"));
    }
    let settings = configured_backup_paths(&state.config)?;
    let staging_dir = match ensure_restore_staging_dir_if_present(&settings.archive_dir)? {
        Some(path) => path,
        None => return Ok(false),
    };
    let target = staging_dir.join(format!("atermius-restore-{job_id}"));
    let temporary = staging_dir.join(format!("atermius-restore-{job_id}.staging"));
    if archive_source == crate::backup_replication::ArchiveSource::Replica {
        cleanup_exact_restore_source_file(
            &staging_dir.join(format!("atermius-restore-{job_id}.source.atb")),
        )?;
    }
    match fs::symlink_metadata(&target) {
        Ok(metadata) => {
            validate_private_directory_metadata(&metadata)?;
            let receipt = read_restore_stage_receipt(&target)?;
            if receipt.job_id != job_id
                || receipt.archive_id != archive_id
                || receipt.archive_source != archive_source.as_str()
            {
                return Err(ApiError::internal(
                    "restore stage receipt does not match its durable job",
                ));
            }
            let Some(archive_sha256) = archive_sha256 else {
                return Err(ApiError::internal(
                    "published restore stage has no durable archive digest",
                ));
            };
            if receipt.archive_sha256 != archive_sha256 {
                return Err(ApiError::internal(
                    "restore stage receipt archive digest is invalid",
                ));
            }
            if !is_canonical_uuid(&receipt.generation) {
                return Err(ApiError::internal(
                    "restore stage receipt generation is invalid",
                ));
            }
            let database_path = target.join("atermius.db");
            validate_private_restore_database(&database_path)?;
            validate_sqlite_file(&database_path).await?;
            let generation = sqlite_instance_generation(&database_path).await?;
            if generation != receipt.generation {
                return Err(ApiError::internal(
                    "restore stage receipt generation does not match its database",
                ));
            }
            for file_name in ["auth-rate-limit.key", "instance-ed25519.key"] {
                let key_path = target.join(file_name);
                let metadata = fs::symlink_metadata(&key_path).map_err(ApiError::internal)?;
                validate_private_restore_file_metadata(&metadata)?;
                let _key = Zeroizing::new(secure_file::read_private_key(&key_path)?);
            }
            persist_admin_restore_stage_ready(
                state,
                &RestoreStageReceipt {
                    job_id: job_id.to_owned(),
                    archive_id: archive_id.to_owned(),
                    archive_source: archive_source.as_str().to_owned(),
                    archive_sha256: archive_sha256.to_owned(),
                    generation: generation.clone(),
                    runtime_policy_sha256: receipt.runtime_policy_sha256.clone(),
                },
            )
            .await?;
            cleanup_exact_restore_temporary(&temporary)?;
            Ok(true)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            cleanup_exact_restore_temporary(&temporary)?;
            Ok(false)
        }
        Err(error) => Err(ApiError::internal(error)),
    }
}

async fn persist_admin_restore_archive_digest(
    state: &crate::AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
) -> Result<(), ApiError> {
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
        let changed = sqlx::query(
            "UPDATE instance_admin_jobs SET archive_sha256=$1 \
             WHERE job_id=$2 AND action='restore' AND archive_id=$3 AND archive_source=$4 \
               AND status='running' AND (archive_sha256 IS NULL OR archive_sha256=$1)",
        )
        .bind(archive_sha256)
        .bind(job_id)
        .bind(archive_id)
        .bind(archive_source.as_str())
        .execute(pool)
        .await
        .map_err(ApiError::internal)?;
        if changed.rows_affected() != 1 {
            return Err(ApiError::internal(
                "restore archive digest could not be recorded",
            ));
        }
        return Ok(());
    }
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET archive_sha256=? \
         WHERE job_id=? AND action='restore' AND archive_id=? AND archive_source=? AND status='running' \
           AND (archive_sha256 IS NULL OR archive_sha256=?)",
    )
    .bind(archive_sha256)
    .bind(job_id)
    .bind(archive_id)
    .bind(archive_source.as_str())
    .bind(archive_sha256)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "restore archive digest could not be recorded",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)
}

async fn persist_admin_restore_stage_binding(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
    binding: &PgRestoreStageBinding,
) -> Result<(), ApiError> {
    if !state.pg_sync_only
        || !is_canonical_uuid(job_id)
        || !is_canonical_uuid(archive_id)
        || !is_canonical_uuid(&binding.binding_id)
        || !valid_pg_schema_identifier(&binding.schema)
        || !is_canonical_uuid(&binding.object_store_id)
        || binding.restored_objects < 0
        || binding.target_database_oid <= 0
        || binding.target_database_name.is_empty()
        || binding.target_database_name.len() > 63
        || binding.target_fingerprint.len() != 64
        || !binding
            .target_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        tracing::warn!(
            job_id = %job_id,
            failure = "binding_validation",
            "PostgreSQL restore target binding metadata rejected"
        );
        return Err(ApiError::internal(
            "PostgreSQL restore target binding is invalid",
        ));
    }
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET restore_stage_binding_id=$1::UUID, \
             restore_stage_target_fingerprint=$2,restore_stage_target_database_oid=$3, \
         restore_stage_target_database_name=$4,restore_stage_schema=$5, \
             restore_stage_object_store_id=$6,restore_stage_object_count=$7 \
         WHERE job_id=$8 AND action='restore' AND archive_id=$9 AND archive_source=$11 \
           AND archive_sha256=$10 AND status='running' AND restore_stage_status IS NULL \
           AND (restore_stage_binding_id IS NULL OR restore_stage_binding_id=$1::UUID) \
           AND (restore_stage_target_fingerprint IS NULL OR restore_stage_target_fingerprint=$2) \
           AND (restore_stage_target_database_oid IS NULL OR restore_stage_target_database_oid=$3) \
           AND (restore_stage_target_database_name IS NULL OR restore_stage_target_database_name=$4) \
           AND (restore_stage_schema IS NULL OR restore_stage_schema=$5) \
           AND (restore_stage_object_store_id IS NULL OR restore_stage_object_store_id=$6) \
           AND (restore_stage_object_count IS NULL OR restore_stage_object_count=$7)",
    )
    .bind(&binding.binding_id)
    .bind(&binding.target_fingerprint)
    .bind(binding.target_database_oid)
    .bind(&binding.target_database_name)
    .bind(&binding.schema)
    .bind(&binding.object_store_id)
    .bind(binding.restored_objects)
    .bind(job_id)
    .bind(archive_id)
    .bind(archive_sha256)
    .bind(archive_source.as_str())
    .execute(pool)
    .await
    .map_err(|error| {
        tracing::warn!(
            job_id = %job_id,
            failure = "binding_update_sql",
            sqlstate = error
                .as_database_error()
                .and_then(|database_error| database_error.code())
                .as_deref()
                .unwrap_or("none"),
            "PostgreSQL restore target binding update failed"
        );
        ApiError::internal(error)
    })?;
    if changed.rows_affected() != 1 {
        tracing::warn!(
            job_id = %job_id,
            failure = "binding_update_row_count",
            rows_affected = changed.rows_affected(),
            "PostgreSQL restore target binding update did not match one running restore"
        );
        return Err(ApiError::internal(
            "PostgreSQL restore target binding could not be recorded",
        ));
    }
    Ok(())
}

async fn persist_admin_restore_stage_ready(
    state: &AppState,
    receipt: &RestoreStageReceipt,
) -> Result<(), ApiError> {
    if state.pg_sync_only {
        return Err(ApiError::internal(
            "PostgreSQL restore stage requires a durable target binding",
        ));
    }
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let job_matches: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM instance_admin_jobs \
         WHERE job_id=? AND action='restore' AND archive_id=? AND archive_source=? \
           AND archive_sha256=? AND status IN ('running','succeeded')",
    )
    .bind(&receipt.job_id)
    .bind(&receipt.archive_id)
    .bind(&receipt.archive_source)
    .bind(&receipt.archive_sha256)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if job_matches != 1 {
        return Err(ApiError::internal(
            "restore stage receipt does not match its durable job",
        ));
    }

    sqlx::query(
        "INSERT OR IGNORE INTO instance_admin_restore_stages(restore_job_id,generation,status,ready_at) \
         VALUES(?,?,'ready',?)",
    )
    .bind(&receipt.job_id)
    .bind(&receipt.generation)
    .bind(crate::now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT generation,status FROM instance_admin_restore_stages WHERE restore_job_id=?",
    )
    .bind(&receipt.job_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if row.get::<String, _>("generation") != receipt.generation
        || row.get::<String, _>("status") != "ready"
    {
        return Err(ApiError::internal(
            "restore stage lifecycle does not match its published receipt",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)
}

async fn persist_pg_admin_restore_stage_ready(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
    generation: &str,
    binding: &PgRestoreStageBinding,
) -> Result<(), ApiError> {
    if !state.pg_sync_only || !is_canonical_uuid(generation) || binding.schema.is_empty() {
        return Err(ApiError::internal(
            "PostgreSQL restore stage metadata is invalid",
        ));
    }
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
    let changed = sqlx::query(
        "UPDATE instance_admin_jobs SET restore_stage_status='ready', \
            restore_stage_ready_at=COALESCE(restore_stage_ready_at,clock_timestamp()), \
            restore_stage_generation=$1 \
         WHERE job_id=$2 AND action='restore' AND archive_id=$3 AND archive_source=$12 \
           AND archive_sha256=$4 AND status IN ('running','succeeded') \
           AND (restore_stage_status IS NULL OR restore_stage_status='ready') \
           AND (restore_stage_generation IS NULL OR restore_stage_generation=$1) \
           AND restore_stage_binding_id=$5::UUID \
           AND restore_stage_target_fingerprint=$6 \
           AND restore_stage_target_database_oid=$7 \
           AND restore_stage_target_database_name=$8 \
           AND restore_stage_schema=$9 \
           AND restore_stage_object_store_id=$10 \
           AND restore_stage_object_count=$11",
    )
    .bind(generation)
    .bind(job_id)
    .bind(archive_id)
    .bind(archive_sha256)
    .bind(&binding.binding_id)
    .bind(&binding.target_fingerprint)
    .bind(binding.target_database_oid)
    .bind(&binding.target_database_name)
    .bind(&binding.schema)
    .bind(&binding.object_store_id)
    .bind(binding.restored_objects)
    .bind(archive_source.as_str())
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "PostgreSQL restore stage does not match its durable job",
        ));
    }
    Ok(())
}

/// Verifies an existing successful restore stage and records its lifecycle
/// without changing or cleaning any neighboring staging paths. Used only to
/// backfill lifecycle rows created after a stage was already published.
pub(crate) async fn backfill_admin_restore_stage_ready(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
) -> Result<(), ApiError> {
    let generation = validate_admin_restore_stage_for_discard(
        state,
        job_id,
        archive_id,
        archive_source,
        archive_sha256,
        None,
        false,
    )
    .await?;
    let settings = configured_backup_paths(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&settings.archive_dir)?
        .ok_or_else(|| ApiError::internal("restore staging directory is unavailable"))?;
    let stage_receipt =
        read_restore_stage_receipt(&staging_dir.join(format!("atermius-restore-{job_id}")))?;
    persist_admin_restore_stage_ready(
        state,
        &RestoreStageReceipt {
            job_id: job_id.to_owned(),
            archive_id: archive_id.to_owned(),
            archive_source: archive_source.as_str().to_owned(),
            archive_sha256: archive_sha256.to_owned(),
            generation,
            runtime_policy_sha256: stage_receipt.runtime_policy_sha256,
        },
    )
    .await
}

fn ensure_restore_staging_dir(archive_dir: &Path) -> Result<PathBuf, ApiError> {
    let path = archive_dir.join("restore-staging");
    match fs::symlink_metadata(&path) {
        Ok(metadata) => validate_private_directory_metadata(&metadata)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            create_private_dir(&path).map_err(ApiError::internal)?;
            let metadata = fs::symlink_metadata(&path).map_err(ApiError::internal)?;
            validate_private_directory_metadata(&metadata)?;
            sync_directory(archive_dir).map_err(ApiError::internal)?;
        }
        Err(error) => return Err(ApiError::internal(error)),
    }
    Ok(path)
}

fn ensure_restore_stage_paths_absent(target: &Path, temporary: &Path) -> Result<(), ApiError> {
    for path in [target, temporary] {
        match fs::symlink_metadata(path) {
            Ok(_) => {
                return Err(ApiError::conflict(
                    "RESTORE_STAGE_EXISTS",
                    "the restore staging target already exists",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Ok(())
}

fn ensure_restore_source_path_absent(path: &Path) -> Result<(), ApiError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Err(ApiError::conflict(
            "RESTORE_STAGE_EXISTS",
            "the restore staging target already exists",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn ensure_restore_staging_dir_if_present(archive_dir: &Path) -> Result<Option<PathBuf>, ApiError> {
    let path = archive_dir.join("restore-staging");
    match fs::symlink_metadata(&path) {
        Ok(metadata) => {
            validate_private_directory_metadata(&metadata)?;
            Ok(Some(path))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn validate_private_directory_metadata(metadata: &fs::Metadata) -> Result<(), ApiError> {
    if !metadata.file_type().is_dir() {
        return Err(ApiError::internal("restore staging directory is unsafe"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o7777 != 0o700
        {
            return Err(ApiError::internal("restore staging directory is unsafe"));
        }
    }
    Ok(())
}

fn cleanup_exact_restore_temporary(path: &Path) -> Result<(), ApiError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            validate_private_directory_metadata(&metadata)?;
            fs::remove_dir_all(path).map_err(ApiError::internal)?;
            if let Some(parent) = path.parent() {
                sync_directory(parent).map_err(ApiError::internal)?;
            }
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn cleanup_exact_restore_source_file(path: &Path) -> Result<(), ApiError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            validate_private_restore_file_metadata(&metadata)?;
            fs::remove_file(path).map_err(ApiError::internal)?;
            if let Some(parent) = path.parent() {
                sync_directory(parent).map_err(ApiError::internal)?;
            }
            Ok(())
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn write_restore_stage_receipt(
    stage_dir: &Path,
    receipt: &RestoreStageReceipt,
) -> Result<(), ApiError> {
    let path = stage_dir.join(RESTORE_STAGE_RECEIPT_FILE);
    let bytes = serde_json::to_vec(receipt).map_err(ApiError::internal)?;
    let mut file = create_private_file(&path).map_err(ApiError::internal)?;
    file.write_all(&bytes).map_err(ApiError::internal)?;
    file.sync_all().map_err(ApiError::internal)?;
    Ok(())
}

fn read_restore_stage_receipt(stage_dir: &Path) -> Result<RestoreStageReceipt, ApiError> {
    let path = stage_dir.join(RESTORE_STAGE_RECEIPT_FILE);
    let mut file = open_regular_file(&path, true).map_err(ApiError::internal)?;
    let metadata = file.metadata().map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&metadata)?;
    if metadata.len() > 2048 {
        return Err(ApiError::internal("restore stage receipt is invalid"));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes).map_err(ApiError::internal)?;
    let receipt: RestoreStageReceipt =
        serde_json::from_slice(&bytes).map_err(ApiError::internal)?;
    if !is_canonical_uuid(&receipt.job_id)
        || !is_canonical_uuid(&receipt.archive_id)
        || !matches!(receipt.archive_source.as_str(), "local" | "replica")
        || !is_canonical_uuid(&receipt.generation)
        || receipt.archive_sha256.len() != 64
        || !receipt
            .archive_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || receipt
            .runtime_policy_sha256
            .as_ref()
            .is_some_and(|digest| {
                digest.len() != 64
                    || !digest
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            })
    {
        return Err(ApiError::internal("restore stage receipt is invalid"));
    }
    Ok(receipt)
}

/// Validates a restore stage using its fixed job-derived path and returns the
/// generation recorded by the receipt. Partial contents are accepted only
/// after a durable discard marker has been written; the receipt is retained
/// until all three stage data files have been removed.
pub(crate) async fn validate_admin_restore_stage_for_discard(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
    expected_generation: Option<&str>,
    allow_partial: bool,
) -> Result<String, ApiError> {
    if !is_canonical_uuid(job_id) || !is_canonical_uuid(archive_id) {
        return Err(ApiError::internal("restore job identifiers are invalid"));
    }
    let settings = configured_backup_paths(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&settings.archive_dir)?
        .ok_or_else(|| ApiError::internal("restore staging directory is unavailable"))?;
    let target = staging_dir.join(format!("atermius-restore-{job_id}"));
    let metadata = match fs::symlink_metadata(&target) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => {
            let generation = expected_generation.ok_or_else(|| {
                ApiError::internal("restore stage generation is unavailable during discard")
            })?;
            return Ok(generation.to_owned());
        }
        Err(error) => return Err(ApiError::internal(error)),
    };
    validate_private_directory_metadata(&metadata)?;

    let mut present = HashSet::new();
    for entry in fs::read_dir(&target).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| ApiError::internal("restore stage contains an unknown entry"))?;
        if name != RESTORE_STAGE_RECEIPT_FILE && !RESTORE_STAGE_DATA_FILES.contains(&name.as_str())
        {
            return Err(ApiError::internal(
                "restore stage contains an unknown entry",
            ));
        }
        present.insert(name);
    }

    let receipt_present = present.contains(RESTORE_STAGE_RECEIPT_FILE);
    if !allow_partial
        && (!receipt_present
            || RESTORE_STAGE_DATA_FILES
                .iter()
                .any(|name| !present.contains(*name)))
    {
        return Err(ApiError::internal("restore stage contents are incomplete"));
    }

    let receipt = if receipt_present {
        let receipt = read_restore_stage_receipt(&target)?;
        if receipt.job_id != job_id
            || receipt.archive_id != archive_id
            || receipt.archive_source != archive_source.as_str()
            || receipt.archive_sha256 != archive_sha256
            || expected_generation.is_some_and(|generation| receipt.generation != generation)
        {
            return Err(ApiError::internal(
                "restore stage receipt does not match its durable job",
            ));
        }
        Some(receipt)
    } else {
        // Once the receipt is gone, only an empty exact target is a valid
        // interrupted final-removal state. Its generation is bound by the
        // durable `discarding` lifecycle row written after prior validation.
        if !allow_partial || !present.is_empty() {
            return Err(ApiError::internal("restore stage receipt is missing"));
        }
        None
    };

    for name in RESTORE_STAGE_DATA_FILES {
        let path = target.join(name);
        match fs::symlink_metadata(&path) {
            Ok(metadata) => {
                validate_private_restore_file_metadata(&metadata)?;
                if name == "atermius.db" {
                    validate_private_restore_database(&path)?;
                    validate_sqlite_file(&path).await?;
                    let generation = sqlite_instance_generation(&path).await?;
                    let expected = receipt
                        .as_ref()
                        .map(|receipt| receipt.generation.as_str())
                        .or(expected_generation)
                        .ok_or_else(|| {
                            ApiError::internal("restore stage generation is unavailable")
                        })?;
                    if generation != expected {
                        return Err(ApiError::internal(
                            "restore stage generation does not match its receipt",
                        ));
                    }
                } else {
                    let _key = Zeroizing::new(secure_file::read_private_key(&path)?);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }

    receipt
        .map(|receipt| receipt.generation)
        .or_else(|| expected_generation.map(str::to_owned))
        .ok_or_else(|| ApiError::internal("restore stage generation is unavailable"))
}

/// Removes only the three fixed archive payload files and receipt under the
/// exact job-derived target. The lifecycle must already be `discarding`.
pub(crate) async fn discard_admin_restore_stage_files(
    state: &AppState,
    job_id: &str,
    archive_id: &str,
    archive_source: crate::backup_replication::ArchiveSource,
    archive_sha256: &str,
    generation: &str,
) -> Result<(), ApiError> {
    validate_admin_restore_stage_for_discard(
        state,
        job_id,
        archive_id,
        archive_source,
        archive_sha256,
        Some(generation),
        true,
    )
    .await?;

    let settings = configured_backup_paths(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&settings.archive_dir)?
        .ok_or_else(|| ApiError::internal("restore staging directory is unavailable"))?;
    let target = staging_dir.join(format!("atermius-restore-{job_id}"));
    match fs::symlink_metadata(&target) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            sync_directory(&staging_dir).map_err(ApiError::internal)?;
            return Ok(());
        }
        Err(error) => return Err(ApiError::internal(error)),
        Ok(metadata) => validate_private_directory_metadata(&metadata)?,
    }

    for name in RESTORE_STAGE_DATA_FILES {
        remove_private_restore_stage_file(&target.join(name), true)?;
    }
    sync_directory(&target).map_err(ApiError::internal)?;
    remove_private_restore_stage_file(&target.join(RESTORE_STAGE_RECEIPT_FILE), true)?;
    sync_directory(&target).map_err(ApiError::internal)?;
    fs::remove_dir(&target).map_err(ApiError::internal)?;
    sync_directory(&staging_dir).map_err(ApiError::internal)?;
    Ok(())
}

fn remove_private_restore_stage_file(path: &Path, allow_missing: bool) -> Result<(), ApiError> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            validate_private_restore_file_metadata(&metadata)?;
            fs::remove_file(path).map_err(ApiError::internal)
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound && allow_missing => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

struct PgRestoreStageDiscardMetadata {
    status: String,
    archive_id: String,
    archive_sha256: String,
    generation: String,
    binding: PgRestoreStageBinding,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PgRestoreControlActivation {
    activation_supported: bool,
    rollback_fence_supported: bool,
    activated_at: Option<chrono::DateTime<chrono::Utc>>,
    rollback_started_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PgRestoreStageActivationResult {
    pub status: String,
    pub job_id: String,
    pub target_database_name: String,
    pub target_database_oid: i64,
    pub schema: String,
    pub generation: String,
    pub object_store_id: String,
    pub restored_objects: i64,
    pub activation_timestamp: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PgRestoreStageRollbackFenceResult {
    pub status: String,
    pub job_id: String,
    pub target_database_name: String,
    pub target_database_oid: i64,
    pub schema: String,
    pub generation: String,
    pub object_store_id: String,
    pub restored_objects: i64,
    pub rollback_timestamp: Option<String>,
}

struct PgRestoreStageTargetGuard {
    connection: Option<PgConnection>,
    lock_key: i64,
    metadata: PgRestoreStageDiscardMetadata,
    control: PgRestoreControlActivation,
}

impl PgRestoreStageTargetGuard {
    async fn commit(mut self) -> Result<(), ApiError> {
        let mut connection = self.connection.take().ok_or_else(|| {
            ApiError::internal("PostgreSQL restore-stage target lock is unavailable")
        })?;
        sqlx::query("COMMIT")
            .execute(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        let unlocked: bool = sqlx::query_scalar("SELECT pg_advisory_unlock($1)")
            .bind(self.lock_key)
            .fetch_one(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        if !unlocked {
            return Err(ApiError::internal(
                "PostgreSQL restore-stage target lock could not be released",
            ));
        }
        connection.close().await.map_err(ApiError::internal)
    }
}

/// Owns a target session lock across application-schema cleanup, source-ledger
/// finalization, and final control-marker removal.
pub(crate) struct PgRestoreStageDiscardGuard {
    connection: Option<PgConnection>,
    lock_key: i64,
    schema: String,
    control_schema_present: bool,
    app_schema_present: bool,
}

impl PgRestoreStageDiscardGuard {
    pub(crate) async fn discard_stage_files(
        &mut self,
        state: &AppState,
        job_id: &str,
    ) -> Result<(), ApiError> {
        let Some(connection) = self.connection.as_mut() else {
            tracing::warn!(
                job_id = %job_id,
                failure = "target_cleanup_connection_missing",
                "PostgreSQL restore target cleanup lost its locked connection"
            );
            return Err(ApiError::internal(
                "PostgreSQL restore discard lock is unavailable",
            ));
        };
        if self.app_schema_present {
            let quoted_schema = format!("\"{}\"", self.schema);
            // A non-empty schema requires CASCADE even when every contained
            // object belongs to this isolated stage. The preflight inventory
            // rejects dependencies whose objects live outside the schema.
            sqlx::query(&format!("DROP SCHEMA {quoted_schema} CASCADE"))
                .execute(&mut *connection)
                .await
                .map_err(|error| {
                    tracing::warn!(
                        job_id = %job_id,
                        failure = "drop_application_schema",
                        sqlstate = error
                            .as_database_error()
                            .and_then(|database_error| database_error.code())
                            .as_deref()
                            .unwrap_or("none"),
                        "PostgreSQL restore application schema cleanup failed"
                    );
                    ApiError::conflict(
                        "RESTORE_STAGE_UNAVAILABLE",
                        "the isolated PostgreSQL restore target contains dependent objects",
                    )
                })?;
            self.app_schema_present = false;
        }
        remove_pg_restore_stage_files(state, job_id).await
    }

    /// Commit removal of the restored application schema while retaining its
    /// target-side marker for crash recovery and target reservation.
    pub(crate) async fn commit_application_cleanup(&mut self) -> Result<(), ApiError> {
        let connection = self
            .connection
            .as_mut()
            .ok_or_else(|| ApiError::internal("PostgreSQL restore discard lock is unavailable"))?;
        sqlx::query("COMMIT")
            .execute(&mut *connection)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("BEGIN ISOLATION LEVEL SERIALIZABLE")
            .execute(&mut *connection)
            .await
            .map_err(ApiError::internal)?;
        Ok(())
    }

    pub(crate) async fn commit(mut self) -> Result<(), ApiError> {
        let mut connection = self
            .connection
            .take()
            .ok_or_else(|| ApiError::internal("PostgreSQL restore discard lock is unavailable"))?;
        if self.control_schema_present {
            sqlx::query(&format!(
                "DROP TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} RESTRICT"
            ))
            .execute(&mut connection)
            .await
            .map_err(|_| {
                ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "the isolated PostgreSQL restore target contains unexpected control dependencies",
                )
            })?;
            sqlx::query(&format!(
                "DROP SCHEMA {PG_RESTORE_CONTROL_SCHEMA} RESTRICT"
            ))
            .execute(&mut connection)
            .await
            .map_err(|_| {
                ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "the isolated PostgreSQL restore target contains unexpected control objects",
                )
            })?;
        }
        sqlx::query("COMMIT")
            .execute(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        let unlocked: bool = sqlx::query_scalar("SELECT pg_advisory_unlock($1)")
            .bind(self.lock_key)
            .fetch_one(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        if !unlocked {
            return Err(ApiError::internal(
                "PostgreSQL restore discard lock could not be released",
            ));
        }
        connection.close().await.map_err(ApiError::internal)
    }
}

/// Mark an already promoted PostgreSQL restore target as activated. This
/// command intentionally reads its job binding from the private stage receipt
/// so it remains usable after the coordinator switches the active PG URL to
/// the restored database and moves the staging URL elsewhere.
pub async fn activate_pg_restore_stage(
    state: &AppState,
    job_id: &str,
) -> Result<PgRestoreStageActivationResult, ApiError> {
    let mut target =
        prepare_pg_restore_stage_target(state, job_id, "RESTORE_STAGE_ACTIVATION_IN_PROGRESS")
            .await?;
    if !target.control.activation_supported || !target.control.rollback_fence_supported {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_ACTIVATION_UNSUPPORTED",
            "this legacy PostgreSQL restore marker cannot record activation safely",
        ));
    }
    if target.control.rollback_started_at.is_some() {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_ROLLBACK_FENCED",
            "the PostgreSQL restore stage has been fenced for rollback",
        ));
    }
    let already_activated = target.control.activated_at.is_some();
    let activated_at: chrono::DateTime<chrono::Utc> =
        sqlx::query_scalar(&format!(
            "UPDATE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} \
         SET activated_at=COALESCE(activated_at,clock_timestamp()) WHERE singleton=1 \
         RETURNING activated_at"
        ))
        .fetch_one(target.connection.as_mut().ok_or_else(|| {
            ApiError::internal("PostgreSQL restore-stage target lock is unavailable")
        })?)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the PostgreSQL restore target activation marker could not be persisted",
            )
        })?;
    let metadata = &target.metadata;
    let result = PgRestoreStageActivationResult {
        status: if already_activated {
            "already_activated".to_owned()
        } else {
            "activated".to_owned()
        },
        job_id: job_id.to_owned(),
        target_database_name: metadata.binding.target_database_name.clone(),
        target_database_oid: metadata.binding.target_database_oid,
        schema: metadata.binding.schema.clone(),
        generation: metadata.generation.clone(),
        object_store_id: metadata.binding.object_store_id.clone(),
        restored_objects: metadata.binding.restored_objects,
        activation_timestamp: activated_at.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
    };
    target.commit().await?;
    Ok(result)
}

pub async fn fence_pg_restore_stage_rollback(
    state: &AppState,
    job_id: &str,
) -> Result<PgRestoreStageRollbackFenceResult, ApiError> {
    let mut target =
        prepare_pg_restore_stage_target(state, job_id, "RESTORE_STAGE_ROLLBACK_FENCE_IN_PROGRESS")
            .await?;
    if !target.control.activation_supported || !target.control.rollback_fence_supported {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_ROLLBACK_FENCE_UNSUPPORTED",
            "this legacy PostgreSQL restore marker cannot record a rollback fence safely",
        ));
    }
    let status = if target.control.activated_at.is_some() {
        "activated"
    } else if target.control.rollback_started_at.is_some() {
        "already_fenced"
    } else {
        "fenced"
    };
    let rollback_started_at = match status {
        "fenced" => Some(
            sqlx::query_scalar(&format!(
                "UPDATE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} \
                 SET rollback_started_at=COALESCE(rollback_started_at,clock_timestamp()) \
                 WHERE singleton=1 RETURNING rollback_started_at"
            ))
            .fetch_one(target.connection.as_mut().ok_or_else(|| {
                ApiError::internal("PostgreSQL restore-stage target lock is unavailable")
            })?)
            .await
            .map_err(|_| {
                ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "the PostgreSQL restore target rollback fence could not be persisted",
                )
            })?,
        ),
        "already_fenced" => target.control.rollback_started_at,
        // An activated target is terminal for this operation. Keep the
        // coordinator's `activated` result timestamp null by contract.
        "activated" => None,
        _ => unreachable!("rollback fence status is selected above"),
    };
    let metadata = &target.metadata;
    let rollback_timestamp = rollback_started_at
        .map(|timestamp| timestamp.to_rfc3339_opts(chrono::SecondsFormat::Millis, true));
    let result = PgRestoreStageRollbackFenceResult {
        status: status.to_owned(),
        job_id: job_id.to_owned(),
        target_database_name: metadata.binding.target_database_name.clone(),
        target_database_oid: metadata.binding.target_database_oid,
        schema: metadata.binding.schema.clone(),
        generation: metadata.generation.clone(),
        object_store_id: metadata.binding.object_store_id.clone(),
        restored_objects: metadata.binding.restored_objects,
        rollback_timestamp,
    };
    target.commit().await?;
    Ok(result)
}

async fn prepare_pg_restore_stage_target(
    state: &AppState,
    job_id: &str,
    lock_conflict_code: &'static str,
) -> Result<PgRestoreStageTargetGuard, ApiError> {
    if !state.pg_sync_only || !crate::is_canonical_uuid(job_id) {
        return Err(ApiError::not_found());
    }
    let metadata = load_pg_restore_stage_activation_metadata(state, job_id)?;
    let runtime = crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env()?
        .ok_or_else(|| ApiError::not_found())?;
    if runtime.schema != metadata.binding.schema
        || pg_restore_target_fingerprint(&runtime.database_url)
            != metadata.binding.target_fingerprint
    {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the active PostgreSQL runtime does not match this restore stage",
        ));
    }

    let options = PgConnectOptions::from_str(&runtime.database_url)
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_TARGET_UNAVAILABLE",
                "the active PostgreSQL restore target is unavailable",
            )
        })?
        .options([("search_path", format!("\"{}\"", runtime.schema))]);
    let mut connection = tokio::time::timeout(
        std::time::Duration::from_secs(12),
        PgConnection::connect_with(&options),
    )
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the active PostgreSQL restore target is unavailable",
        )
    })?
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the active PostgreSQL restore target is unavailable",
        )
    })?;
    sqlx::query("BEGIN ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut connection)
        .await
        .map_err(ApiError::internal)?;
    let lock_key = pg_restore_discard_lock_key(&metadata.binding.binding_id)?;
    let lock_acquired: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock($1)")
        .bind(lock_key)
        .fetch_one(&mut connection)
        .await
        .map_err(ApiError::internal)?;
    if !lock_acquired {
        return Err(ApiError::conflict(
            lock_conflict_code,
            "another operation holds the PostgreSQL restore-stage target lock",
        ));
    }

    let target_identity = sqlx::query(
        "SELECT current_database() AS database_name, \
                (SELECT oid::BIGINT FROM pg_database WHERE datname=current_database()) AS database_oid",
    )
    .fetch_one(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    let database_name: String = target_identity
        .try_get("database_name")
        .map_err(ApiError::internal)?;
    let database_oid: i64 = target_identity
        .try_get("database_oid")
        .map_err(ApiError::internal)?;
    if database_name != metadata.binding.target_database_name
        || database_oid != metadata.binding.target_database_oid
    {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the active PostgreSQL restore database identity changed",
        ));
    }

    let custom_schemas: Vec<String> = sqlx::query_scalar(
        "SELECT nspname FROM pg_namespace \
         WHERE nspname NOT IN ('public','information_schema') AND nspname !~ '^pg_' \
         ORDER BY nspname",
    )
    .fetch_all(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    let app_schema_present = custom_schemas
        .iter()
        .any(|name| name == &metadata.binding.schema);
    let control_schema_present = custom_schemas
        .iter()
        .any(|name| name == PG_RESTORE_CONTROL_SCHEMA);
    if custom_schemas
        .iter()
        .any(|name| name != &metadata.binding.schema && name != PG_RESTORE_CONTROL_SCHEMA)
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the active PostgreSQL restore target contains unexpected schemas",
        ));
    }
    let public_relations: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::BIGINT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace \
         WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')",
    )
    .fetch_one(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    if public_relations != 0 || !app_schema_present || !control_schema_present {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the active PostgreSQL restore target does not match its durable stage",
        ));
    }

    let control = validate_pg_restore_control_schema(&mut connection, job_id, &metadata).await?;
    validate_pg_restored_application_schema(&mut connection, &metadata).await?;
    validate_pg_restore_stage_object_references(&mut connection, state, job_id, &metadata).await?;
    if pg_restore_schema_external_dependency_count(&mut connection, &metadata.binding.schema)
        .await?
        != 0
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the active PostgreSQL restore schema has dependent objects outside the stage",
        ));
    }
    validate_pg_restore_stage_files(state, job_id, &metadata, false)?;
    Ok(PgRestoreStageTargetGuard {
        connection: Some(connection),
        lock_key,
        metadata,
        control,
    })
}

pub(crate) async fn prepare_pg_restore_stage_discard(
    state: &AppState,
    job_id: &str,
    allow_partial: bool,
) -> Result<PgRestoreStageDiscardGuard, ApiError> {
    let metadata = load_pg_restore_stage_discard_metadata(state, job_id).await?;
    if !matches!(
        metadata.status.as_str(),
        "ready" | "discarding" | "discarded"
    ) || (!allow_partial && metadata.status != "ready")
        || (allow_partial && metadata.status == "ready")
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "the PostgreSQL restore stage is not ready to discard",
        ));
    }
    let target_url = std::env::var("ATERMIUS_PG_RESTORE_TARGET_URL")
        .ok()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            ApiError::conflict(
                "RESTORE_TARGET_UNAVAILABLE",
                "the isolated PostgreSQL restore target is not configured",
            )
        })?;
    if pg_restore_target_fingerprint(&target_url) != metadata.binding.target_fingerprint {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the configured PostgreSQL restore target does not match this stage",
        ));
    }
    let archive_dir = restore_stage_archive_dir(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&archive_dir)?;
    if let Some(staging_dir) = staging_dir.as_ref() {
        let stage_path = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
        ensure_path_outside_data_dir(&state.config.data_dir, &stage_path)?;
    }

    let options = PgConnectOptions::from_str(&target_url).map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })?;
    let mut connection = tokio::time::timeout(
        std::time::Duration::from_secs(12),
        PgConnection::connect_with(&options),
    )
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })?
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the isolated PostgreSQL restore target is unavailable",
        )
    })?;
    sqlx::query("BEGIN ISOLATION LEVEL SERIALIZABLE")
        .execute(&mut connection)
        .await
        .map_err(ApiError::internal)?;
    let lock_key = pg_restore_discard_lock_key(&metadata.binding.binding_id)?;
    let lock_acquired: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock($1)")
        .bind(lock_key)
        .fetch_one(&mut connection)
        .await
        .map_err(ApiError::internal)?;
    if !lock_acquired {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_DISCARD_IN_PROGRESS",
            "another server node is already discarding this PostgreSQL restore stage",
        ));
    }

    let target_identity = sqlx::query(
        "SELECT current_database() AS database_name, \
                (SELECT oid::BIGINT FROM pg_database WHERE datname=current_database()) AS database_oid",
    )
    .fetch_one(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    let database_name: String = target_identity
        .try_get("database_name")
        .map_err(ApiError::internal)?;
    let database_oid: i64 = target_identity
        .try_get("database_oid")
        .map_err(ApiError::internal)?;
    if database_name != metadata.binding.target_database_name
        || database_oid != metadata.binding.target_database_oid
    {
        return Err(ApiError::conflict(
            "RESTORE_TARGET_UNAVAILABLE",
            "the configured PostgreSQL restore database identity changed",
        ));
    }

    let custom_schemas: Vec<String> = sqlx::query_scalar(
        "SELECT nspname FROM pg_namespace \
         WHERE nspname NOT IN ('public','information_schema') AND nspname !~ '^pg_' \
         ORDER BY nspname",
    )
    .fetch_all(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    let app_schema_present = custom_schemas
        .iter()
        .any(|name| name == &metadata.binding.schema);
    let control_schema_present = custom_schemas
        .iter()
        .any(|name| name == PG_RESTORE_CONTROL_SCHEMA);
    if custom_schemas
        .iter()
        .any(|name| name != &metadata.binding.schema && name != PG_RESTORE_CONTROL_SCHEMA)
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore target contains unexpected schemas",
        ));
    }
    let public_relations: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::BIGINT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace \
         WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')",
    )
    .fetch_one(&mut connection)
    .await
    .map_err(ApiError::internal)?;
    if public_relations != 0 {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore target contains unexpected public objects",
        ));
    }

    if control_schema_present {
        let control =
            validate_pg_restore_control_schema(&mut connection, job_id, &metadata).await?;
        if control.activated_at.is_some() {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_ACTIVATED",
                "the PostgreSQL restore stage has been activated and cannot be discarded",
            ));
        }
    }
    if app_schema_present {
        if !control_schema_present {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the isolated PostgreSQL restore target binding marker is missing",
            ));
        }
        validate_pg_restored_application_schema(&mut connection, &metadata).await?;
        let external_dependents =
            pg_restore_schema_external_dependency_count(&mut connection, &metadata.binding.schema)
                .await?;
        if external_dependents != 0 {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the isolated PostgreSQL restore schema has dependent objects outside the stage",
            ));
        }
    } else if !allow_partial || !custom_schemas.is_empty() && !control_schema_present {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore target does not match its durable stage",
        ));
    }
    validate_pg_restore_stage_files(state, job_id, &metadata, allow_partial)?;

    Ok(PgRestoreStageDiscardGuard {
        connection: Some(connection),
        lock_key,
        schema: metadata.binding.schema,
        control_schema_present,
        app_schema_present,
    })
}

async fn pg_restore_schema_external_dependency_count(
    connection: &mut PgConnection,
    schema: &str,
) -> Result<i64, ApiError> {
    let row = sqlx::query(
        "WITH namespace_objects AS ( \
             SELECT classid,objid,objsubid FROM pg_depend \
             WHERE refclassid='pg_namespace'::regclass \
               AND refobjid=(SELECT oid FROM pg_namespace WHERE nspname=$1) \
         ), dependent_objects AS ( \
             SELECT DISTINCT d.classid,d.objid,d.objsubid FROM pg_depend d \
             JOIN namespace_objects o ON d.refclassid=o.classid AND d.refobjid=o.objid \
         ), identified AS ( \
             SELECT d.classid,d.objid,d.objsubid, \
                 CASE \
                   WHEN d.classid='pg_class'::regclass AND EXISTS ( \
                       SELECT 1 FROM pg_class c WHERE c.oid=d.objid AND c.relkind='t' \
                   ) THEN (SELECT n.nspname FROM pg_class toast \
                           JOIN pg_class owner ON owner.reltoastrelid=toast.oid \
                           JOIN pg_namespace n ON n.oid=owner.relnamespace \
                           WHERE toast.oid=d.objid) \
                   WHEN d.classid='pg_trigger'::regclass THEN ( \
                       SELECT n.nspname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid \
                       JOIN pg_namespace n ON n.oid=c.relnamespace WHERE t.oid=d.objid \
                   ) \
                   WHEN d.classid='pg_constraint'::regclass THEN ( \
                       SELECT COALESCE(nr.nspname,nc.nspname) FROM pg_constraint c \
                       LEFT JOIN pg_class r ON r.oid=c.conrelid \
                       LEFT JOIN pg_namespace nr ON nr.oid=r.relnamespace \
                       LEFT JOIN pg_namespace nc ON nc.oid=c.connamespace WHERE c.oid=d.objid \
                   ) \
                   WHEN d.classid='pg_rewrite'::regclass THEN ( \
                       SELECT n.nspname FROM pg_rewrite r JOIN pg_class c ON c.oid=r.ev_class \
                       JOIN pg_namespace n ON n.oid=c.relnamespace WHERE r.oid=d.objid \
                   ) \
                   WHEN d.classid='pg_attrdef'::regclass THEN ( \
                       SELECT n.nspname FROM pg_attrdef a JOIN pg_class c ON c.oid=a.adrelid \
                       JOIN pg_namespace n ON n.oid=c.relnamespace WHERE a.oid=d.objid \
                   ) \
                   WHEN d.classid='pg_policy'::regclass THEN ( \
                       SELECT n.nspname FROM pg_policy p JOIN pg_class c ON c.oid=p.polrelid \
                       JOIN pg_namespace n ON n.oid=c.relnamespace WHERE p.oid=d.objid \
                   ) \
                   ELSE x.schema \
                 END AS object_schema \
             FROM dependent_objects d \
             CROSS JOIN LATERAL pg_identify_object(d.classid,d.objid,d.objsubid) x \
         ) \
         SELECT COUNT(*) FILTER (WHERE object_schema IS DISTINCT FROM $1)::BIGINT AS external_count, \
                COALESCE(ARRAY_AGG(DISTINCT classid::regclass::TEXT || ':' || \
                    COALESCE(object_schema,'<unknown>')) \
                    FILTER (WHERE object_schema IS DISTINCT FROM $1),ARRAY[]::TEXT[]) AS external_classes \
         FROM identified",
    )
    .bind(schema)
    .fetch_one(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    let external_count: i64 = row.try_get("external_count").map_err(ApiError::internal)?;
    if external_count != 0 {
        let external_classes: Vec<String> = row
            .try_get("external_classes")
            .map_err(ApiError::internal)?;
        tracing::warn!(
            external_count,
            external_classes = ?external_classes,
            "PostgreSQL restore schema has dependent objects outside the stage"
        );
    }
    Ok(external_count)
}

fn pg_restore_discard_lock_key(binding_id: &str) -> Result<i64, ApiError> {
    let parsed = Uuid::parse_str(binding_id).map_err(ApiError::internal)?;
    if parsed.to_string() != binding_id {
        return Err(ApiError::internal(
            "PostgreSQL restore binding id is invalid",
        ));
    }
    let mut hasher = Sha256::new();
    hasher.update(b"atermius/pg-restore-stage-discard/v1\0");
    hasher.update(parsed.as_bytes());
    let digest = hasher.finalize();
    let bytes: [u8; 8] = digest[..8]
        .try_into()
        .map_err(|_| ApiError::internal("PostgreSQL restore lock key is invalid"))?;
    Ok(i64::from_be_bytes(bytes))
}

fn load_pg_restore_stage_activation_metadata(
    state: &AppState,
    job_id: &str,
) -> Result<PgRestoreStageDiscardMetadata, ApiError> {
    let archive_dir = restore_stage_archive_dir(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&archive_dir)?.ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage files are unavailable",
        )
    })?;
    let stage_dir = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
    ensure_path_outside_data_dir(&state.config.data_dir, &stage_dir)?;
    let stage_metadata = fs::symlink_metadata(&stage_dir).map_err(|_| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage files are unavailable",
        )
    })?;
    validate_private_directory_metadata(&stage_metadata)?;
    let receipt = read_pg_restore_stage_receipt(&stage_dir.join("postgres-restore-receipt.json"))?;
    if receipt.job_id != job_id {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore receipt does not match the requested job",
        ));
    }
    let restored_objects = i64::try_from(receipt.restored_objects).map_err(|_| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore receipt object count is invalid",
        )
    })?;
    let binding = PgRestoreStageBinding {
        binding_id: receipt.binding_id,
        target_fingerprint: receipt.target_fingerprint,
        target_database_oid: receipt.target_database_oid,
        target_database_name: receipt.target_database_name,
        schema: receipt.schema,
        object_store_id: receipt.object_store_id,
        restored_objects,
    };
    if receipt.format_version != 1
        || !is_canonical_uuid(&receipt.archive_id)
        || !is_canonical_uuid(&receipt.generation)
        || !is_canonical_uuid(&binding.binding_id)
        || !is_canonical_uuid(&binding.object_store_id)
        || !valid_pg_schema_identifier(&binding.schema)
        || binding.schema == PG_RESTORE_CONTROL_SCHEMA
        || binding.restored_objects < 0
        || binding.target_database_oid <= 0
        || binding.target_database_name.is_empty()
        || binding.target_database_name.len() > 63
        || binding.target_fingerprint.len() != 64
        || !binding
            .target_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || receipt.archive_sha256.len() != 64
        || !receipt
            .archive_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore receipt is invalid",
        ));
    }
    Ok(PgRestoreStageDiscardMetadata {
        status: "ready".to_owned(),
        archive_id: receipt.archive_id,
        archive_sha256: receipt.archive_sha256,
        generation: receipt.generation,
        binding,
    })
}

async fn load_pg_restore_stage_discard_metadata(
    state: &AppState,
    job_id: &str,
) -> Result<PgRestoreStageDiscardMetadata, ApiError> {
    if !state.pg_sync_only || !is_canonical_uuid(job_id) {
        return Err(ApiError::not_found());
    }
    let pool = state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL restore runtime is unavailable"))?;
    let row = sqlx::query(
        "SELECT action,status,result_code,archive_id,archive_source,archive_sha256, \
                restore_stage_status,restore_stage_generation,restore_stage_binding_id::TEXT AS binding_id, \
                restore_stage_target_fingerprint,restore_stage_target_database_oid, \
                restore_stage_target_database_name,restore_stage_schema,restore_stage_object_store_id, \
                restore_stage_object_count \
         FROM instance_admin_jobs WHERE job_id=$1",
    )
    .bind(job_id)
    .fetch_optional(pool)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let job_status: String = row.try_get("status").map_err(ApiError::internal)?;
    let result_code: Option<String> = row.try_get("result_code").map_err(ApiError::internal)?;
    let stage_status: Option<String> = row
        .try_get("restore_stage_status")
        .map_err(ApiError::internal)?;
    let restore_job_ready = (job_status == "succeeded"
        && result_code.as_deref() == Some("completed"))
        || (job_status == "interrupted"
            && result_code.as_deref() == Some("interrupted")
            && matches!(
                stage_status.as_deref(),
                Some("ready" | "discarding" | "discarded")
            ));
    let archive_source: Option<String> =
        row.try_get("archive_source").map_err(ApiError::internal)?;
    if row
        .try_get::<String, _>("action")
        .map_err(ApiError::internal)?
        != "restore"
        || !restore_job_ready
        || !matches!(archive_source.as_deref(), Some("local" | "replica"))
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "the PostgreSQL restore stage is not ready to discard",
        ));
    }
    let status: String = stage_status.ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_NOT_READY",
            "the PostgreSQL restore stage is not ready to discard",
        )
    })?;
    let archive_id: String = row
        .try_get::<Option<String>, _>("archive_id")
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("completed PostgreSQL restore job has no archive id"))?;
    let archive_sha256: String = row
        .try_get::<Option<String>, _>("archive_sha256")
        .map_err(ApiError::internal)?
        .ok_or_else(|| {
            ApiError::internal("completed PostgreSQL restore job has no archive digest")
        })?;
    let generation: String = row
        .try_get::<Option<String>, _>("restore_stage_generation")
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("completed PostgreSQL restore job has no generation"))?;
    let binding = PgRestoreStageBinding {
        binding_id: row
            .try_get::<Option<String>, _>("binding_id")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "this PostgreSQL restore stage predates target binding and cannot be discarded safely",
            ))?,
        target_fingerprint: row
            .try_get::<Option<String>, _>("restore_stage_target_fingerprint")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
        target_database_oid: row
            .try_get::<Option<i64>, _>("restore_stage_target_database_oid")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
        target_database_name: row
            .try_get::<Option<String>, _>("restore_stage_target_database_name")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
        schema: row
            .try_get::<Option<String>, _>("restore_stage_schema")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
        object_store_id: row
            .try_get::<Option<String>, _>("restore_stage_object_store_id")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
        restored_objects: row
            .try_get::<Option<i64>, _>("restore_stage_object_count")
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("PostgreSQL restore target binding is incomplete"))?,
    };
    if !is_canonical_uuid(&archive_id)
        || !is_canonical_uuid(&generation)
        || !is_canonical_uuid(&binding.binding_id)
        || !is_canonical_uuid(&binding.object_store_id)
        || !valid_pg_schema_identifier(&binding.schema)
        || binding.schema == PG_RESTORE_CONTROL_SCHEMA
        || binding.restored_objects < 0
        || binding.target_database_oid <= 0
        || binding.target_database_name.is_empty()
        || binding.target_database_name.len() > 63
        || binding.target_fingerprint.len() != 64
        || !binding
            .target_fingerprint
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || archive_sha256.len() != 64
        || !archive_sha256
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err(ApiError::internal(
            "PostgreSQL restore stage metadata is invalid",
        ));
    }
    Ok(PgRestoreStageDiscardMetadata {
        status,
        archive_id,
        archive_sha256,
        generation,
        binding,
    })
}

async fn validate_pg_restore_control_schema(
    connection: &mut PgConnection,
    job_id: &str,
    metadata: &PgRestoreStageDiscardMetadata,
) -> Result<PgRestoreControlActivation, ApiError> {
    let relations = sqlx::query(
        "SELECT c.relname,c.relkind::TEXT AS relkind \
         FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace \
         WHERE n.nspname=$1 AND c.relkind IN ('r','p','v','m','S','f','i','I') \
         ORDER BY c.relname",
    )
    .bind(PG_RESTORE_CONTROL_SCHEMA)
    .fetch_all(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    let expected_relations = relations.len() == 2
        && relations.iter().any(|row| {
            row.try_get::<String, _>("relname").ok().as_deref() == Some(PG_RESTORE_CONTROL_TABLE)
                && row.try_get::<String, _>("relkind").ok().as_deref() == Some("r")
        })
        && relations.iter().any(|row| {
            row.try_get::<String, _>("relname").ok().as_deref() == Some("stage_binding_pkey")
                && row.try_get::<String, _>("relkind").ok().as_deref() == Some("i")
        });
    if !expected_relations {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore target control marker is invalid",
        ));
    }
    let marker = sqlx::query(&format!(
        "SELECT binding_id::TEXT AS binding_id,job_id::TEXT AS job_id,archive_id::TEXT AS archive_id, \
                archive_sha256,generation::TEXT AS generation,schema_name,object_store_id::TEXT AS object_store_id, \
                target_fingerprint,target_database_oid,target_database_name,restored_objects \
         FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} WHERE singleton=1"
    ))
    .fetch_optional(&mut *connection)
    .await
    .map_err(|_| ApiError::conflict(
        "RESTORE_STAGE_UNAVAILABLE",
        "the isolated PostgreSQL restore target control marker is invalid",
    ))?
    .ok_or_else(|| ApiError::conflict(
        "RESTORE_STAGE_UNAVAILABLE",
        "the isolated PostgreSQL restore target control marker is missing",
    ))?;
    let matches = marker
        .try_get::<String, _>("binding_id")
        .map_err(ApiError::internal)?
        == metadata.binding.binding_id
        && marker
            .try_get::<String, _>("job_id")
            .map_err(ApiError::internal)?
            == job_id
        && marker
            .try_get::<String, _>("archive_id")
            .map_err(ApiError::internal)?
            == metadata.archive_id
        && marker
            .try_get::<String, _>("archive_sha256")
            .map_err(ApiError::internal)?
            == metadata.archive_sha256
        && marker
            .try_get::<String, _>("generation")
            .map_err(ApiError::internal)?
            == metadata.generation
        && marker
            .try_get::<String, _>("schema_name")
            .map_err(ApiError::internal)?
            == metadata.binding.schema
        && marker
            .try_get::<String, _>("object_store_id")
            .map_err(ApiError::internal)?
            == metadata.binding.object_store_id
        && marker
            .try_get::<String, _>("target_fingerprint")
            .map_err(ApiError::internal)?
            == metadata.binding.target_fingerprint
        && marker
            .try_get::<i64, _>("target_database_oid")
            .map_err(ApiError::internal)?
            == metadata.binding.target_database_oid
        && marker
            .try_get::<String, _>("target_database_name")
            .map_err(ApiError::internal)?
            == metadata.binding.target_database_name
        && marker
            .try_get::<i64, _>("restored_objects")
            .map_err(ApiError::internal)?
            == metadata.binding.restored_objects;
    let marker_count: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*)::BIGINT FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE}"
    ))
    .fetch_one(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    if !matches || marker_count != 1 {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore target control marker does not match its durable stage",
        ));
    }
    let marker_columns = sqlx::query(
        "SELECT a.attname, a.atttypid='timestamptz'::regtype AS timestamp_type, a.attnotnull \
         FROM pg_attribute a \
         WHERE a.attrelid=$1::regclass AND a.attname IN ('activated_at','rollback_started_at') \
           AND a.attnum>0 AND NOT a.attisdropped",
    )
    .bind(format!(
        "{PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE}"
    ))
    .fetch_all(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    let mut activation_supported = false;
    let mut rollback_fence_supported = false;
    for column in marker_columns {
        let name: String = column.try_get("attname").map_err(ApiError::internal)?;
        let timestamp_type: bool = column
            .try_get("timestamp_type")
            .map_err(ApiError::internal)?;
        let not_null: bool = column.try_get("attnotnull").map_err(ApiError::internal)?;
        if !timestamp_type || not_null {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the isolated PostgreSQL restore target control timestamp marker is invalid",
            ));
        }
        match name.as_str() {
            "activated_at" => activation_supported = true,
            "rollback_started_at" => rollback_fence_supported = true,
            _ => unreachable!("column query is restricted to known marker fields"),
        }
    }
    // Schema-28 markers may lack either column. Discard remains safe because
    // it reads any activation timestamp that exists; activating or fencing an
    // incomplete legacy marker fails closed in the caller.
    let activated_at: Option<chrono::DateTime<chrono::Utc>> = if activation_supported {
        sqlx::query_scalar(&format!(
            "SELECT activated_at FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} WHERE singleton=1"
        ))
        .fetch_one(&mut *connection)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the isolated PostgreSQL restore target activation marker is invalid",
            )
        })?
    } else {
        None
    };
    let rollback_started_at: Option<chrono::DateTime<chrono::Utc>> = if rollback_fence_supported {
        sqlx::query_scalar(&format!(
            "SELECT rollback_started_at FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} WHERE singleton=1"
        ))
        .fetch_one(&mut *connection)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the isolated PostgreSQL restore target rollback marker is invalid",
            )
        })?
    } else {
        None
    };
    Ok(PgRestoreControlActivation {
        activation_supported,
        rollback_fence_supported,
        activated_at,
        rollback_started_at,
    })
}

async fn validate_pg_restored_application_schema(
    connection: &mut PgConnection,
    metadata: &PgRestoreStageDiscardMetadata,
) -> Result<(), ApiError> {
    let schema = format!("\"{}\"", metadata.binding.schema);
    let schema_version: i64 = sqlx::query_scalar(&format!(
        "SELECT schema_version::BIGINT FROM {schema}.atermius_instance_schema WHERE singleton=1"
    ))
    .fetch_optional(&mut *connection)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore schema is unavailable",
        )
    })?;
    let generation: String = sqlx::query_scalar(&format!(
        "SELECT generation FROM {schema}.instance_meta WHERE id=1"
    ))
    .fetch_optional(&mut *connection)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore schema is unavailable",
        )
    })?;
    let object_stats = sqlx::query(&format!(
        "SELECT COUNT(*)::BIGINT AS total, \
                COUNT(*) FILTER (WHERE storage_state='available')::BIGINT AS available, \
                COUNT(DISTINCT storage_store_id) FILTER (WHERE storage_state='available')::BIGINT AS store_count, \
                MIN(storage_store_id) FILTER (WHERE storage_state='available') AS store_id \
         FROM {schema}.blob_objects"
    ))
    .fetch_one(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    let total: i64 = object_stats.try_get("total").map_err(ApiError::internal)?;
    let available: i64 = object_stats
        .try_get("available")
        .map_err(ApiError::internal)?;
    let store_count: i64 = object_stats
        .try_get("store_count")
        .map_err(ApiError::internal)?;
    let store_id: Option<String> = object_stats
        .try_get("store_id")
        .map_err(ApiError::internal)?;
    let objects_match = total == metadata.binding.restored_objects
        && available == metadata.binding.restored_objects
        && if metadata.binding.restored_objects == 0 {
            store_count == 0 && store_id.is_none()
        } else {
            store_count == 1 && store_id.as_deref() == Some(&metadata.binding.object_store_id)
        };
    if schema_version != PG_BACKUP_SCHEMA_VERSION
        || generation != metadata.generation
        || !objects_match
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the isolated PostgreSQL restore schema does not match its durable stage",
        ));
    }
    Ok(())
}

async fn validate_pg_restore_stage_object_references(
    connection: &mut PgConnection,
    state: &AppState,
    job_id: &str,
    metadata: &PgRestoreStageDiscardMetadata,
) -> Result<(), ApiError> {
    use futures_util::TryStreamExt;

    let schema = format!("\"{}\"", metadata.binding.schema);
    let instance_id: String = sqlx::query_scalar(&format!(
        "SELECT instance_id FROM {schema}.instance_meta WHERE id=1"
    ))
    .fetch_one(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    if !is_canonical_uuid(&instance_id) {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore instance identity is invalid",
        ));
    }
    let archive_dir = restore_stage_archive_dir(&state.config)?;
    let staging_dir = ensure_restore_staging_dir_if_present(&archive_dir)?.ok_or_else(|| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage files are unavailable",
        )
    })?;
    let stage_dir = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
    ensure_path_outside_data_dir(&state.config.data_dir, &stage_dir)?;
    validate_private_directory_metadata(&fs::symlink_metadata(&stage_dir).map_err(|_| {
        ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage files are unavailable",
        )
    })?)?;
    let object_store_root = stage_dir.join("object-store");
    let object_query = format!(
        "SELECT vault_id,object_id,size,sha256,storage_backend,storage_key,storage_store_id \
         FROM {schema}.blob_objects WHERE storage_state='available' ORDER BY vault_id,object_id"
    );
    let object_query = sqlx::query(&object_query);
    let mut object_rows = object_query.fetch(&mut *connection);
    let mut checked = 0_i64;
    while let Some(row) = object_rows.try_next().await.map_err(ApiError::internal)? {
        let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
        let object_id: String = row.try_get("object_id").map_err(ApiError::internal)?;
        let size: i64 = row.try_get("size").map_err(ApiError::internal)?;
        let sha256: String = row.try_get("sha256").map_err(ApiError::internal)?;
        let backend: String = row.try_get("storage_backend").map_err(ApiError::internal)?;
        let storage_key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
        let store_id: Option<String> = row
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        let Some(storage_key) = storage_key else {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object is missing its storage reference",
            ));
        };
        if !is_canonical_uuid(&vault_id)
            || !is_canonical_uuid(&object_id)
            || size < 0
            || !is_sha256_hex(&sha256)
            || backend != "filesystem"
            || store_id.as_deref() != Some(metadata.binding.object_store_id.as_str())
        {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object reference is invalid",
            ));
        }
        let key_parts: Vec<&str> = storage_key.split('/').collect();
        if key_parts.len() != 7
            || key_parts[0..3] != ["atermius", "objects", "v1"]
            || key_parts[3] != instance_id
            || key_parts[4] != vault_id
            || key_parts[5] != object_id
            || !is_canonical_uuid(key_parts[6])
        {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object path does not match its database reference",
            ));
        }
        let object_path = object_store_root.join(&storage_key);
        let mut object_file = open_regular_file(&object_path, true).map_err(|_| {
            ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object file is unavailable",
            )
        })?;
        let file_metadata = object_file.metadata().map_err(ApiError::internal)?;
        validate_private_restore_file_metadata(&file_metadata)?;
        if i64::try_from(file_metadata.len()).ok() != Some(size) {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object size does not match its database reference",
            ));
        }
        let mut hasher = Sha256::new();
        let mut total = 0_u64;
        let mut buffer = vec![0_u8; CHUNK_BYTES];
        loop {
            let bytes_read = object_file.read(&mut buffer).map_err(ApiError::internal)?;
            if bytes_read == 0 {
                break;
            }
            total = total.checked_add(bytes_read as u64).ok_or_else(|| {
                ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "a restored PostgreSQL object size is invalid",
                )
            })?;
            if total > MAX_FILE_BYTES {
                return Err(ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "a restored PostgreSQL object exceeds the supported size",
                ));
            }
            hasher.update(&buffer[..bytes_read]);
        }
        if total != size as u64 || hex::encode(hasher.finalize()) != sha256 {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "a restored PostgreSQL object does not match its database digest",
            ));
        }
        checked = checked.checked_add(1).ok_or_else(|| {
            ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the PostgreSQL restore object count is invalid",
            )
        })?;
    }
    drop(object_rows);
    let dangling_references: i64 = sqlx::query_scalar(&format!(
        "SELECT COUNT(*)::BIGINT FROM {schema}.object_references r \
         LEFT JOIN {schema}.blob_objects b ON b.vault_id=r.vault_id AND b.object_id=r.object_id \
         WHERE b.object_id IS NULL"
    ))
    .fetch_one(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    if checked != metadata.binding.restored_objects || dangling_references != 0 {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore object references do not match the staged files",
        ));
    }
    Ok(())
}

fn validate_pg_restore_stage_files(
    state: &AppState,
    job_id: &str,
    metadata: &PgRestoreStageDiscardMetadata,
    allow_partial: bool,
) -> Result<(), ApiError> {
    let archive_dir = restore_stage_archive_dir(&state.config)?;
    let Some(staging_dir) = ensure_restore_staging_dir_if_present(&archive_dir)? else {
        return if allow_partial {
            Ok(())
        } else {
            Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the PostgreSQL restore stage files are unavailable",
            ))
        };
    };
    let stage = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
    let stage_metadata = match fs::symlink_metadata(&stage) {
        Ok(value) => value,
        Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => return Ok(()),
        Err(error) => return Err(ApiError::internal(error)),
    };
    validate_private_directory_metadata(&stage_metadata)?;
    let mut present = HashSet::new();
    for entry in fs::read_dir(&stage).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let name = entry.file_name().into_string().map_err(|_| {
            ApiError::internal("PostgreSQL restore stage contains an unknown entry")
        })?;
        if !matches!(
            name.as_str(),
            "auth-rate-limit.key"
                | "instance-ed25519.key"
                | "object-store"
                | "postgres-restore-receipt.json"
        ) {
            return Err(ApiError::conflict(
                "RESTORE_STAGE_UNAVAILABLE",
                "the PostgreSQL restore stage contains unexpected files",
            ));
        }
        present.insert(name);
    }
    if !allow_partial
        && [
            "auth-rate-limit.key",
            "instance-ed25519.key",
            "object-store",
            "postgres-restore-receipt.json",
        ]
        .iter()
        .any(|name| !present.contains(*name))
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore stage is incomplete",
        ));
    }
    let receipt_path = stage.join("postgres-restore-receipt.json");
    let receipt = match fs::symlink_metadata(&receipt_path) {
        Ok(_) => Some(read_pg_restore_stage_receipt(&receipt_path)?),
        Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => None,
        Err(error) => return Err(ApiError::internal(error)),
    };
    if let Some(receipt) = receipt.as_ref()
        && (receipt.format_version != 1
            || receipt.job_id != job_id
            || receipt.archive_id != metadata.archive_id
            || receipt.archive_sha256 != metadata.archive_sha256
            || receipt.generation != metadata.generation
            || receipt.schema != metadata.binding.schema
            || receipt.object_store_id != metadata.binding.object_store_id
            || receipt.restored_objects as i64 != metadata.binding.restored_objects
            || receipt.binding_id != metadata.binding.binding_id
            || receipt.target_fingerprint != metadata.binding.target_fingerprint
            || receipt.target_database_oid != metadata.binding.target_database_oid
            || receipt.target_database_name != metadata.binding.target_database_name)
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore receipt does not match its durable target binding",
        ));
    }
    for name in ["auth-rate-limit.key", "instance-ed25519.key"] {
        let path = stage.join(name);
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                let key = Zeroizing::new(secure_file::read_private_key(&path)?);
                if key.len() != 32 {
                    return Err(ApiError::conflict(
                        "RESTORE_STAGE_UNAVAILABLE",
                        "the PostgreSQL restore stage service keys are invalid",
                    ));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    validate_pg_restore_object_store(
        &stage.join("object-store"),
        &metadata.binding.object_store_id,
        metadata.binding.restored_objects,
        allow_partial,
    )?;
    Ok(())
}

fn read_pg_restore_stage_receipt(path: &Path) -> Result<PgRestoreStageReceipt, ApiError> {
    let mut file = open_regular_file(path, true).map_err(ApiError::internal)?;
    let metadata = file.metadata().map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&metadata)?;
    if metadata.len() > 4096 {
        return Err(ApiError::internal(
            "PostgreSQL restore stage receipt is invalid",
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes).map_err(ApiError::internal)?;
    let receipt: PgRestoreStageReceipt =
        serde_json::from_slice(&bytes).map_err(ApiError::internal)?;
    if !is_canonical_uuid(&receipt.job_id)
        || !is_canonical_uuid(&receipt.archive_id)
        || !is_canonical_uuid(&receipt.generation)
        || !is_canonical_uuid(&receipt.binding_id)
        || !is_canonical_uuid(&receipt.object_store_id)
        || !valid_pg_schema_identifier(&receipt.schema)
        || receipt.archive_sha256.len() != 64
        || receipt.target_fingerprint.len() != 64
        || receipt.target_database_oid <= 0
        || receipt.target_database_name.is_empty()
        || receipt.target_database_name.len() > 63
    {
        return Err(ApiError::internal(
            "PostgreSQL restore stage receipt is invalid",
        ));
    }
    Ok(receipt)
}

fn validate_pg_restore_object_store(
    root: &Path,
    expected_store_id: &str,
    expected_objects: i64,
    allow_partial: bool,
) -> Result<(), ApiError> {
    let metadata = match fs::symlink_metadata(root) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound && allow_partial => return Ok(()),
        Err(error) => return Err(ApiError::internal(error)),
    };
    validate_private_directory_metadata(&metadata)?;
    let mut marker_present = false;
    let mut object_count = 0_i64;
    for entry in fs::read_dir(root).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let name = entry.file_name().into_string().map_err(|_| {
            ApiError::internal("PostgreSQL restore object store contains an unknown entry")
        })?;
        let path = entry.path();
        match name.as_str() {
            ".atermius-store-id" => {
                let mut file = open_regular_file(&path, true).map_err(ApiError::internal)?;
                let file_metadata = file.metadata().map_err(ApiError::internal)?;
                validate_private_restore_file_metadata(&file_metadata)?;
                if file_metadata.len() > 64 {
                    return Err(ApiError::internal(
                        "PostgreSQL restore object store identity is invalid",
                    ));
                }
                let mut bytes = String::new();
                file.read_to_string(&mut bytes)
                    .map_err(ApiError::internal)?;
                let value = bytes.strip_suffix('\n').ok_or_else(|| {
                    ApiError::internal("PostgreSQL restore object store identity is invalid")
                })?;
                if !is_canonical_uuid(value) || value != expected_store_id {
                    return Err(ApiError::conflict(
                        "RESTORE_STAGE_UNAVAILABLE",
                        "the PostgreSQL restore object store identity changed",
                    ));
                }
                marker_present = true;
            }
            "atermius" => validate_pg_restore_object_tree(&path, 1, &mut object_count)?,
            _ => {
                return Err(ApiError::conflict(
                    "RESTORE_STAGE_UNAVAILABLE",
                    "the PostgreSQL restore object store contains unexpected entries",
                ));
            }
        }
    }
    if (!allow_partial && !marker_present)
        || object_count > expected_objects
        || (!allow_partial && object_count != expected_objects)
    {
        return Err(ApiError::conflict(
            "RESTORE_STAGE_UNAVAILABLE",
            "the PostgreSQL restore object store is incomplete",
        ));
    }
    Ok(())
}

fn validate_pg_restore_object_tree(
    directory: &Path,
    depth: usize,
    object_count: &mut i64,
) -> Result<(), ApiError> {
    validate_private_directory_metadata(
        &fs::symlink_metadata(directory).map_err(ApiError::internal)?,
    )?;
    for entry in fs::read_dir(directory).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let name = entry.file_name().into_string().map_err(|_| {
            ApiError::internal("PostgreSQL restore object store contains an unknown entry")
        })?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(ApiError::internal)?;
        if depth == 1 {
            if name != "objects" || !metadata.file_type().is_dir() {
                return Err(ApiError::internal(
                    "PostgreSQL restore object store path is invalid",
                ));
            }
            validate_pg_restore_object_tree(&path, depth + 1, object_count)?;
        } else if depth == 2 {
            if name != "v1" || !metadata.file_type().is_dir() {
                return Err(ApiError::internal(
                    "PostgreSQL restore object store path is invalid",
                ));
            }
            validate_pg_restore_object_tree(&path, depth + 1, object_count)?;
        } else if depth <= 5 {
            if !is_canonical_uuid(&name) || !metadata.file_type().is_dir() {
                return Err(ApiError::internal(
                    "PostgreSQL restore object store path is invalid",
                ));
            }
            validate_pg_restore_object_tree(&path, depth + 1, object_count)?;
        } else if depth == 6 {
            if !is_canonical_uuid(&name) {
                return Err(ApiError::internal(
                    "PostgreSQL restore object store path is invalid",
                ));
            }
            validate_private_restore_file_metadata(&metadata)?;
            *object_count = object_count
                .checked_add(1)
                .ok_or_else(|| ApiError::internal("PostgreSQL restore object count is invalid"))?;
        } else {
            return Err(ApiError::internal(
                "PostgreSQL restore object store path is invalid",
            ));
        }
    }
    Ok(())
}

async fn remove_pg_restore_stage_files(state: &AppState, job_id: &str) -> Result<(), ApiError> {
    let mut cleanup_phase = "resolve_private_archive_directory";
    let result = remove_pg_restore_stage_files_inner(state, job_id, &mut cleanup_phase).await;
    if let Err(error) = &result {
        tracing::warn!(
            job_id = %job_id,
            cleanup_phase,
            error_code = %error.body.code,
            "PostgreSQL restore stage file cleanup failed"
        );
    }
    result
}

async fn remove_pg_restore_stage_files_inner(
    state: &AppState,
    job_id: &str,
    cleanup_phase: &mut &'static str,
) -> Result<(), ApiError> {
    let archive_dir = restore_stage_archive_dir(&state.config)?;
    let Some(staging_dir) = ensure_restore_staging_dir_if_present(&archive_dir)? else {
        return Ok(());
    };
    let stage = staging_dir.join(format!("atermius-pg-restore-{job_id}"));
    *cleanup_phase = "validate_stage_directory";
    match fs::symlink_metadata(&stage) {
        Ok(metadata) => validate_private_directory_metadata(&metadata)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            sync_directory(&staging_dir).map_err(ApiError::internal)?;
            return Ok(());
        }
        Err(error) => return Err(ApiError::internal(error)),
    }
    *cleanup_phase = "remove_stage_key_material";
    for name in ["auth-rate-limit.key", "instance-ed25519.key"] {
        remove_private_restore_stage_file(&stage.join(name), true)?;
    }
    *cleanup_phase = "remove_stage_object_store";
    let object_root = stage.join("object-store");
    match fs::symlink_metadata(&object_root) {
        Ok(metadata) => {
            validate_private_directory_metadata(&metadata)?;
            fs::remove_dir_all(&object_root).map_err(ApiError::internal)?;
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(ApiError::internal(error)),
    }
    *cleanup_phase = "sync_stage_after_object_removal";
    sync_directory(&stage).map_err(ApiError::internal)?;
    *cleanup_phase = "remove_stage_receipt";
    remove_private_restore_stage_file(&stage.join("postgres-restore-receipt.json"), true)?;
    *cleanup_phase = "sync_stage_after_receipt_removal";
    sync_directory(&stage).map_err(ApiError::internal)?;
    *cleanup_phase = "remove_stage_directory";
    fs::remove_dir(&stage).map_err(ApiError::internal)?;
    *cleanup_phase = "sync_staging_parent";
    sync_directory(&staging_dir).map_err(ApiError::internal)?;
    Ok(())
}

fn validate_private_restore_file_metadata(metadata: &fs::Metadata) -> Result<(), ApiError> {
    if !metadata.file_type().is_file() {
        return Err(ApiError::internal("restore stage file is unsafe"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o7777 != 0o600
            || metadata.nlink() != 1
        {
            return Err(ApiError::internal("restore stage file is unsafe"));
        }
    }
    Ok(())
}

fn validate_private_restore_database(path: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(path).map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&metadata)
}

async fn sqlite_instance_generation(path: &Path) -> Result<String, ApiError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .immutable(true)
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(ApiError::internal)?;
    let result = sqlx::query_scalar("SELECT generation FROM instance_meta WHERE id=1")
        .fetch_one(&pool)
        .await
        .map_err(ApiError::internal);
    pool.close().await;
    result
}

pub(crate) fn open_and_hash_generated_archive(path: &Path) -> Result<(File, String), ApiError> {
    let path_metadata = fs::symlink_metadata(path).map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&path_metadata)?;
    let file = open_private_archive(path).map_err(ApiError::internal)?;
    let opened_metadata = file.metadata().map_err(ApiError::internal)?;
    validate_private_restore_file_metadata(&opened_metadata)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if path_metadata.dev() != opened_metadata.dev()
            || path_metadata.ino() != opened_metadata.ino()
        {
            return Err(ApiError::internal("backup archive changed while opening"));
        }
    }
    let mut file = file;
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = file.read(&mut buffer).map_err(ApiError::internal)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    file.seek(SeekFrom::Start(0)).map_err(ApiError::internal)?;
    Ok((file, hex::encode(hasher.finalize())))
}

fn build_manifest(
    files: &[SourceFile],
    migration_version: i64,
    config: &Config,
) -> Result<BackupManifest, ApiError> {
    let mut entries = Vec::with_capacity(files.len());
    for file in files {
        let (size, sha256) = hash_file(&file.path).map_err(ApiError::internal)?;
        entries.push(BackupFile {
            name: file.name.to_owned(),
            size,
            sha256,
        });
    }
    Ok(BackupManifest {
        format_version: FORMAT_VERSION,
        app_version: env!("CARGO_PKG_VERSION").to_owned(),
        created_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        database_engine: "sqlite".to_owned(),
        journal_mode: "wal".to_owned(),
        migration_version,
        runtime_policy: runtime_policy_summary(config),
        files: entries,
    })
}

fn build_postgres_manifest(
    files: &[SourceFile],
    migration_version: i64,
    config: &Config,
) -> Result<BackupManifest, ApiError> {
    let mut manifest = build_manifest(files, migration_version, config)?;
    manifest.database_engine = "postgresql".to_owned();
    manifest.journal_mode = "consistent-snapshot".to_owned();
    Ok(manifest)
}

fn runtime_policy_summary(config: &Config) -> RuntimePolicySummary {
    let rates: &AuthRateLimits = &config.auth_rate_limits;
    let mut relay_allow_cidrs = config
        .relay_allow_cidrs
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    relay_allow_cidrs.sort();
    relay_allow_cidrs.dedup();
    let mut admin_usernames = config.admin_usernames.clone();
    admin_usernames.sort();
    admin_usernames.dedup();
    RuntimePolicySummary {
        policy_version: RUNTIME_POLICY_VERSION,
        registration_open: config.registration_open,
        relay_enabled: config.relay_enabled,
        terminal_collaboration_enabled: config.terminal_collaboration_enabled,
        relay_allow_cidrs,
        relay_allow_ports: config.relay_allow_ports.clone(),
        relay_max_connections_per_user: config.relay_max_connections_per_user,
        public_origin: config.public_origin.clone(),
        web_dir: config
            .web_dir
            .as_ref()
            .map(|path| path.to_string_lossy().into_owned()),
        max_object_bytes: config.max_object_bytes,
        max_request_bytes: config.max_request_bytes,
        history_retention_days: config.history_retention_days,
        record_restore_retention_days: config.record_restore_retention_days,
        vault_deletion_grace_seconds: config.vault_deletion_grace_seconds,
        account_deletion_grace_seconds: config.account_deletion_grace_seconds,
        audit_retention_days: config.audit_retention_days,
        object_gc_grace_seconds: config.object_gc_grace_seconds,
        admin_usernames,
        auth_rate_limits: AuthRateLimitsSummary {
            window_seconds: rates.window_seconds,
            login_user_limit: rates.login_user_limit,
            login_pair_limit: rates.login_pair_limit,
            login_ip_limit: rates.login_ip_limit,
            prelogin_user_limit: rates.prelogin_user_limit,
            prelogin_pair_limit: rates.prelogin_pair_limit,
            prelogin_ip_limit: rates.prelogin_ip_limit,
            register_user_limit: rates.register_user_limit,
            register_pair_limit: rates.register_pair_limit,
            register_ip_limit: rates.register_ip_limit,
            recovery_start_user_limit: rates.recovery_start_user_limit,
            recovery_start_pair_limit: rates.recovery_start_pair_limit,
            recovery_start_ip_limit: rates.recovery_start_ip_limit,
            recovery_complete_user_limit: rates.recovery_complete_user_limit,
            recovery_complete_pair_limit: rates.recovery_complete_pair_limit,
            recovery_complete_ip_limit: rates.recovery_complete_ip_limit,
            max_active_recovery_challenges: rates.max_active_recovery_challenges,
        },
    }
}

fn runtime_policy_sha256(config: &Config) -> Result<String, ApiError> {
    let canonical =
        serde_jcs::to_vec(&runtime_policy_summary(config)).map_err(ApiError::internal)?;
    Ok(hex::encode(Sha256::digest(canonical)))
}

fn runtime_policy_drift_fields(
    archived: &RuntimePolicySummary,
    target: &Config,
) -> Result<Vec<String>, ApiError> {
    if archived.policy_version > RUNTIME_POLICY_VERSION {
        return Err(ApiError::bad_request(
            "BACKUP_POLICY_UNSUPPORTED",
            "backup runtime policy version is newer than this server",
        ));
    }
    let current = runtime_policy_summary(target);
    let mut fields = Vec::new();
    if archived.policy_version != RUNTIME_POLICY_VERSION {
        fields.push("runtime_policy_version".to_owned());
    }
    macro_rules! compare_policy_field {
        ($field:ident) => {
            if archived.$field != current.$field {
                fields.push(stringify!($field).to_owned());
            }
        };
    }
    compare_policy_field!(registration_open);
    compare_policy_field!(relay_enabled);
    compare_policy_field!(terminal_collaboration_enabled);
    compare_policy_field!(relay_allow_cidrs);
    compare_policy_field!(relay_allow_ports);
    compare_policy_field!(relay_max_connections_per_user);
    compare_policy_field!(public_origin);
    compare_policy_field!(web_dir);
    compare_policy_field!(max_object_bytes);
    compare_policy_field!(max_request_bytes);
    compare_policy_field!(history_retention_days);
    compare_policy_field!(record_restore_retention_days);
    compare_policy_field!(vault_deletion_grace_seconds);
    compare_policy_field!(account_deletion_grace_seconds);
    compare_policy_field!(audit_retention_days);
    compare_policy_field!(object_gc_grace_seconds);
    compare_policy_field!(admin_usernames);
    compare_policy_field!(auth_rate_limits);
    Ok(fields)
}

fn runtime_policy_drift_error(fields: &[String]) -> ApiError {
    ApiError::conflict(
        "RUNTIME_POLICY_DRIFT",
        &format!(
            "backup policy differs from target configuration in fields: {}. Review the target policy or rerun restore with --accept-runtime-policy-drift",
            fields.join(", ")
        ),
    )
}

fn write_encrypted_archive(
    output: &mut impl Write,
    key: &[u8; 32],
    manifest: &BackupManifest,
    files: &[SourceFile],
) -> io::Result<()> {
    let manifest_bytes = Zeroizing::new(serde_jcs::to_vec(manifest).map_err(invalid_data)?);
    if manifest_bytes.len() > MAX_MANIFEST_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "backup manifest too large",
        ));
    }
    validate_manifest(manifest).map_err(invalid_data)?;
    let manifest_hash: [u8; 32] = Sha256::digest(&manifest_bytes).into();
    let mut nonce_prefix = [0_u8; 16];
    rand::thread_rng().fill_bytes(&mut nonce_prefix);
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(invalid_data)?;
    let mut encrypted_manifest = Zeroizing::new(manifest_bytes.to_vec());
    let manifest_nonce = nonce(&nonce_prefix, 0);
    cipher
        .encrypt_in_place(
            XNonce::from_slice(&manifest_nonce),
            MANIFEST_AAD,
            &mut *encrypted_manifest,
        )
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "backup encryption failed"))?;

    output.write_all(MAGIC)?;
    output.write_all(&FORMAT_VERSION.to_be_bytes())?;
    output.write_all(&nonce_prefix)?;
    let manifest_len = u32::try_from(encrypted_manifest.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "manifest length overflow"))?;
    output.write_all(&manifest_len.to_be_bytes())?;
    output.write_all(&encrypted_manifest)?;

    let mut sequence = 1_u64;
    for (file_index, source) in files.iter().enumerate() {
        let mut input = open_regular_file(&source.path, false)?;
        let file_size = manifest.files[file_index].size;
        let mut remaining = file_size;
        let mut chunk_index = 0_u64;
        while remaining > 0 {
            let chunk_len = remaining.min(CHUNK_BYTES as u64) as usize;
            let mut bytes = Zeroizing::new(vec![0_u8; chunk_len]);
            input.read_exact(&mut bytes)?;
            let aad = file_aad(
                &manifest_hash,
                file_index as u32,
                chunk_index,
                chunk_len as u32,
            );
            let chunk_nonce = nonce(&nonce_prefix, sequence);
            cipher
                .encrypt_in_place(XNonce::from_slice(&chunk_nonce), &aad, &mut *bytes)
                .map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidData, "backup encryption failed")
                })?;
            output.write_all(&bytes)?;
            sequence = sequence.checked_add(1).ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "too many backup chunks")
            })?;
            chunk_index += 1;
            remaining -= chunk_len as u64;
        }
        let mut extra = [0_u8; 1];
        if input.read(&mut extra)? != 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "backup source changed while being archived",
            ));
        }
    }
    Ok(())
}

fn read_encrypted_archive(
    mut input: File,
    key: &[u8; 32],
    stage_dir: &Path,
) -> io::Result<BackupManifest> {
    let metadata = input.metadata()?;
    let mut magic = [0_u8; 16];
    input.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err(invalid_data("unknown instance backup format"));
    }
    let version = read_u16(&mut input)?;
    if version != FORMAT_VERSION {
        return Err(invalid_data("unsupported instance backup format version"));
    }
    let mut nonce_prefix = [0_u8; 16];
    input.read_exact(&mut nonce_prefix)?;
    let manifest_cipher_len = read_u32(&mut input)? as usize;
    if !(AEAD_TAG_BYTES..=MAX_MANIFEST_BYTES + AEAD_TAG_BYTES).contains(&manifest_cipher_len) {
        return Err(invalid_data("invalid backup manifest length"));
    }
    let mut encrypted_manifest = Zeroizing::new(vec![0_u8; manifest_cipher_len]);
    input.read_exact(&mut encrypted_manifest)?;
    let cipher = XChaCha20Poly1305::new_from_slice(key).map_err(invalid_data)?;
    let manifest_nonce = nonce(&nonce_prefix, 0);
    cipher
        .decrypt_in_place(
            XNonce::from_slice(&manifest_nonce),
            MANIFEST_AAD,
            &mut *encrypted_manifest,
        )
        .map_err(|_| invalid_data("backup key or manifest authentication is invalid"))?;
    let manifest: BackupManifest = serde_json::from_slice(&encrypted_manifest)
        .map_err(|_| invalid_data("backup manifest is invalid"))?;
    let canonical_manifest = serde_jcs::to_vec(&manifest).map_err(invalid_data)?;
    if canonical_manifest.as_slice() != encrypted_manifest.as_slice() {
        return Err(invalid_data("backup manifest is not canonical JCS"));
    }
    validate_manifest(&manifest)?;
    let expected_len = archive_length(&manifest, manifest_cipher_len)?;
    if metadata.len() != expected_len {
        return Err(invalid_data(
            "backup archive is truncated or has trailing bytes",
        ));
    }
    let manifest_hash: [u8; 32] = Sha256::digest(&encrypted_manifest).into();

    let mut sequence = 1_u64;
    for (file_index, entry) in manifest.files.iter().enumerate() {
        let output_path = stage_dir.join(target_file_name(&entry.name)?);
        let mut output = create_private_file(&output_path)?;
        let mut remaining = entry.size;
        let mut chunk_index = 0_u64;
        let mut hasher = Sha256::new();
        while remaining > 0 {
            let chunk_len = remaining.min(CHUNK_BYTES as u64) as usize;
            let mut bytes = Zeroizing::new(vec![0_u8; chunk_len + AEAD_TAG_BYTES]);
            input.read_exact(&mut bytes)?;
            let aad = file_aad(
                &manifest_hash,
                file_index as u32,
                chunk_index,
                chunk_len as u32,
            );
            let chunk_nonce = nonce(&nonce_prefix, sequence);
            cipher
                .decrypt_in_place(XNonce::from_slice(&chunk_nonce), &aad, &mut *bytes)
                .map_err(|_| invalid_data("backup file authentication failed"))?;
            if bytes.len() != chunk_len {
                return Err(invalid_data("backup chunk has an invalid length"));
            }
            output.write_all(&bytes)?;
            hasher.update(&bytes);
            sequence = sequence
                .checked_add(1)
                .ok_or_else(|| invalid_data("too many backup chunks"))?;
            chunk_index += 1;
            remaining -= chunk_len as u64;
        }
        output.sync_all()?;
        if hex::encode(hasher.finalize()) != entry.sha256 {
            return Err(invalid_data("backup file SHA-256 does not match manifest"));
        }
    }
    let mut trailing = [0_u8; 1];
    if input.read(&mut trailing)? != 0 {
        return Err(invalid_data("backup archive has trailing data"));
    }
    Ok(manifest)
}

fn validate_manifest(manifest: &BackupManifest) -> io::Result<()> {
    if manifest.format_version != FORMAT_VERSION || manifest.migration_version < 0 {
        return Err(invalid_data("unsupported backup manifest metadata"));
    }
    let names = manifest
        .files
        .iter()
        .map(|entry| entry.name.as_str())
        .collect::<Vec<_>>();
    match (
        manifest.database_engine.as_str(),
        manifest.journal_mode.as_str(),
    ) {
        ("sqlite", "wal") if names == ALLOWED_FILES => {}
        ("postgresql", "consistent-snapshot") => {
            let required = [
                "auth-rate-limit.key",
                "postgres-metadata.json",
                "postgres.dump",
                "instance-ed25519.key",
            ];
            if required.iter().any(|name| !names.contains(name))
                || names
                    .iter()
                    .any(|name| !required.contains(name) && !is_pg_object_archive_name(name))
                || names
                    .iter()
                    .filter(|name| is_pg_object_archive_name(name))
                    .count()
                    != names.len().saturating_sub(required.len())
            {
                return Err(invalid_data("backup contains missing or unknown files"));
            }
            let objects = names
                .iter()
                .filter(|name| is_pg_object_archive_name(name))
                .copied()
                .collect::<Vec<_>>();
            if objects.windows(2).any(|pair| pair[0] >= pair[1]) {
                return Err(invalid_data(
                    "backup object files are not canonically ordered",
                ));
            }
        }
        _ => return Err(invalid_data("unsupported backup manifest metadata")),
    }
    let unique_names = names.iter().copied().collect::<HashSet<_>>();
    if unique_names.len() != names.len() {
        return Err(invalid_data("backup contains duplicate files"));
    }
    let mut total = 0_u64;
    for entry in &manifest.files {
        if entry.size > MAX_FILE_BYTES
            || entry.sha256.len() != 64
            || !entry
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err(invalid_data("backup file metadata is invalid"));
        }
        total = total
            .checked_add(entry.size)
            .ok_or_else(|| invalid_data("backup size overflow"))?;
    }
    if total > MAX_FILE_BYTES {
        return Err(invalid_data("backup is larger than the supported maximum"));
    }
    Ok(())
}

fn is_pg_object_archive_name(name: &str) -> bool {
    let Some(index) = name
        .strip_prefix("object-")
        .and_then(|name| name.strip_suffix(".blob"))
    else {
        return false;
    };
    index.len() == 8 && index.bytes().all(|byte| byte.is_ascii_digit())
}

fn archive_length(manifest: &BackupManifest, encrypted_manifest_len: usize) -> io::Result<u64> {
    let mut length = (MAGIC.len() + 2 + 16 + 4 + encrypted_manifest_len) as u64;
    for entry in &manifest.files {
        let chunks = entry.size.div_ceil(CHUNK_BYTES as u64);
        length = length
            .checked_add(entry.size)
            .and_then(|value| value.checked_add(chunks * AEAD_TAG_BYTES as u64))
            .ok_or_else(|| invalid_data("backup size overflow"))?;
    }
    Ok(length)
}

fn file_aad(manifest_hash: &[u8; 32], file_index: u32, chunk_index: u64, size: u32) -> Vec<u8> {
    let mut aad = Vec::with_capacity(FILE_AAD.len() + 32 + 4 + 8 + 4);
    aad.extend_from_slice(FILE_AAD);
    aad.extend_from_slice(manifest_hash);
    aad.extend_from_slice(&file_index.to_be_bytes());
    aad.extend_from_slice(&chunk_index.to_be_bytes());
    aad.extend_from_slice(&size.to_be_bytes());
    aad
}

fn nonce(prefix: &[u8; 16], sequence: u64) -> [u8; 24] {
    let mut nonce = [0_u8; 24];
    nonce[..16].copy_from_slice(prefix);
    nonce[16..].copy_from_slice(&sequence.to_be_bytes());
    nonce
}

fn target_file_name(name: &str) -> io::Result<&str> {
    match name {
        "auth-rate-limit.key" => Ok("auth-rate-limit.key"),
        "database.sqlite" => Ok("atermius.db"),
        "instance-ed25519.key" => Ok("instance-ed25519.key"),
        "postgres-metadata.json" | "postgres.dump" => Ok(name),
        _ if is_pg_object_archive_name(name) => Ok(name),
        _ => Err(invalid_data("unknown backup file")),
    }
}

fn open_private_archive(path: &Path) -> io::Result<File> {
    open_regular_file(path, true)
}

fn open_regular_file(path: &Path, require_private: bool) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Do not let a FIFO supplied as the archive path block the operator
        // CLI before the post-open regular-file check can reject it.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.file_type().is_file() {
        return Err(invalid_data("backup input must be a regular file"));
    }
    #[cfg(unix)]
    if require_private {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "backup archive must have owner-only permissions",
            ));
        }
    }
    Ok(file)
}

fn create_private_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options.open(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
    }
    Ok(file)
}

fn write_private_file(path: &Path, bytes: &[u8]) -> Result<(), ApiError> {
    let mut file = create_private_file(path).map_err(ApiError::internal)?;
    file.write_all(bytes).map_err(ApiError::internal)?;
    file.sync_all().map_err(ApiError::internal)?;
    Ok(())
}

fn create_private_dir(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700).create(path)?;
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
    }
    #[cfg(not(unix))]
    {
        fs::create_dir(path)
    }
}

fn create_private_temp_dir(parent: &Path, prefix: &str) -> Result<TempDirectory, ApiError> {
    for _ in 0..4 {
        let path = parent.join(format!(".{prefix}-{}", Uuid::new_v4()));
        match create_private_dir(&path) {
            Ok(()) => return Ok(TempDirectory(path)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Err(ApiError::internal(
        "could not allocate private backup staging directory",
    ))
}

/// Prevent recovery material from being stored under the instance volume.
/// Canonicalizing the existing parent closes relative-path and parent-symlink
/// escapes while leaving the final archive path free for atomic no-replace.
fn ensure_path_outside_data_dir(data_dir: &Path, path: &Path) -> Result<(), ApiError> {
    let canonical_data_dir = fs::canonicalize(data_dir).map_err(ApiError::internal)?;
    let file_name = path
        .file_name()
        .ok_or_else(|| ApiError::bad_request("INVALID_BACKUP_PATH", "backup path is invalid"))?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let canonical_parent = fs::canonicalize(parent).map_err(ApiError::internal)?;
    let resolved = canonical_parent.join(file_name);
    if resolved.starts_with(&canonical_data_dir) {
        return Err(ApiError::bad_request(
            "INVALID_BACKUP_PATH",
            "backup key and archive paths must be outside the instance data directory",
        ));
    }
    Ok(())
}

fn create_private_archive_temp(archive_path: &Path) -> Result<(TempFile, File), ApiError> {
    let parent = archive_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    for _ in 0..4 {
        let name = archive_path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| {
                ApiError::bad_request("INVALID_BACKUP_PATH", "archive path is invalid")
            })?;
        let temp = parent.join(format!(".{name}.{}.tmp", Uuid::new_v4()));
        match create_private_file(&temp) {
            Ok(file) => return Ok((TempFile(temp), file)),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Err(ApiError::internal(
        "could not allocate backup archive staging file",
    ))
}

fn set_private_file_mode(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

fn sync_parent(path: &Path) -> io::Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    File::open(parent)?.sync_all()
}

fn sync_directory(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}

fn prepare_new_target_path(target: &Path, source: &Path) -> Result<PathBuf, ApiError> {
    let Some(file_name) = target.file_name() else {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_PATH",
            "restore destination must name a new data directory",
        ));
    };
    if file_name == "." || file_name == ".." {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_PATH",
            "restore destination must name a new data directory",
        ));
    }
    let parent = target
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    // Requiring an existing destination parent avoids creating any path under
    // the active data directory before containment checks have run.
    let parent = fs::canonicalize(parent).map_err(ApiError::internal)?;
    let target = parent.join(file_name);
    match fs::symlink_metadata(&target) {
        Ok(_) => {
            return Err(ApiError::conflict(
                "RESTORE_TARGET_EXISTS",
                "restore destination must not already exist",
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(ApiError::internal(error)),
    }
    if target.starts_with(source) {
        return Err(ApiError::bad_request(
            "INVALID_RESTORE_PATH",
            "restore destination must be outside the active data directory",
        ));
    }
    validate_restore_target_parent(&parent)?;
    Ok(target)
}

/// The restore stage is created next to the requested destination before an
/// atomic no-replace publish. Reject writable ancestors that would let a
/// different local user replace the stage or destination path. Sticky shared
/// directories such as `/tmp` remain usable because their owners cannot rename
/// entries belonging to another UID.
fn validate_restore_target_parent(parent: &Path) -> Result<(), ApiError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        let mut ancestor = Some(parent);
        while let Some(directory) = ancestor {
            let metadata = fs::metadata(directory).map_err(ApiError::internal)?;
            if !metadata.is_dir() {
                return Err(ApiError::bad_request(
                    "INVALID_RESTORE_PATH",
                    "restore destination parent must be a directory",
                ));
            }
            let mode = metadata.permissions().mode();
            if mode & 0o022 != 0 && mode & 0o1000 == 0 {
                return Err(ApiError::bad_request(
                    "UNSAFE_RESTORE_PARENT",
                    "restore destination parent has a group/world-writable non-sticky ancestor",
                ));
            }
            ancestor = directory.parent();
        }
    }
    Ok(())
}

fn publish_directory_noreplace(source: &Path, target: &Path) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let source = CString::new(source.as_os_str().as_bytes())
            .map_err(|_| invalid_data("staging path contains a NUL byte"))?;
        let target = CString::new(target.as_os_str().as_bytes())
            .map_err(|_| invalid_data("restore path contains a NUL byte"))?;
        // SAFETY: both strings are NUL-terminated and AT_FDCWD asks the kernel
        // to resolve them from the process working directory.
        let result = unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                source.as_ptr(),
                libc::AT_FDCWD,
                target.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        if target.exists() {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "restore destination already exists",
            ));
        }
        fs::rename(source, target)
    }
}

fn publish_admin_restore_noreplace(source: &Path, target: &Path) -> io::Result<()> {
    #[cfg(target_os = "linux")]
    {
        publish_directory_noreplace(source, target)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (source, target);
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "online restore staging requires an atomic no-replace directory rename",
        ))
    }
}

async fn validate_pool(state: &AppState) -> Result<(), ApiError> {
    let integrity: String = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_one(&state.db)
        .await
        .map_err(ApiError::internal)?;
    if integrity != "ok" {
        return Err(ApiError::bad_request(
            "BACKUP_DATABASE_INVALID",
            "restored database failed SQLite integrity_check",
        ));
    }
    let foreign_keys = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(&state.db)
        .await
        .map_err(ApiError::internal)?;
    if !foreign_keys.is_empty() {
        return Err(ApiError::bad_request(
            "BACKUP_FOREIGN_KEY_FAILURE",
            "restored database has foreign-key violations",
        ));
    }
    Ok(())
}

async fn validate_sqlite_file(path: &Path) -> Result<(), ApiError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .immutable(true)
        .foreign_keys(true)
        .busy_timeout(std::time::Duration::from_secs(5));
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(ApiError::internal)?;
    let result = async {
        let integrity: String = sqlx::query_scalar("PRAGMA integrity_check")
            .fetch_one(&pool)
            .await
            .map_err(ApiError::internal)?;
        if integrity != "ok" {
            return Err(ApiError::bad_request(
                "BACKUP_DATABASE_INVALID",
                "backup database failed SQLite integrity_check",
            ));
        }
        let violations = sqlx::query("PRAGMA foreign_key_check")
            .fetch_all(&pool)
            .await
            .map_err(ApiError::internal)?;
        if !violations.is_empty() {
            return Err(ApiError::bad_request(
                "BACKUP_FOREIGN_KEY_FAILURE",
                "backup database has foreign-key violations",
            ));
        }
        let migration_table: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='_sqlx_migrations'",
        )
        .fetch_one(&pool)
        .await
        .map_err(ApiError::internal)?;
        if migration_table != 1 {
            return Err(ApiError::bad_request(
                "BACKUP_DATABASE_INVALID",
                "backup database has no SQLx migration history",
            ));
        }
        Ok(())
    }
    .await;
    pool.close().await;
    result
}

async fn sqlite_schema_version(path: &Path) -> Result<i64, ApiError> {
    let options = SqliteConnectOptions::new()
        .filename(path)
        .read_only(true)
        .immutable(true)
        .foreign_keys(true);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .map_err(ApiError::internal)?;
    let version = sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations WHERE success=1")
        .fetch_one(&pool)
        .await
        .map_err(ApiError::internal)?;
    pool.close().await;
    Ok(version)
}

fn current_migration_version() -> i64 {
    sqlx::migrate!("./migrations")
        .iter()
        .map(|migration| migration.version)
        .max()
        .unwrap_or(0)
}

fn sqlite_url(path: &Path) -> String {
    format!("sqlite://{}?mode=rwc", path.display())
}

fn remove_sqlite_sidecars(path: &Path) -> io::Result<()> {
    let path = path.as_os_str().to_string_lossy();
    for suffix in ["-wal", "-shm"] {
        match fs::remove_file(format!("{path}{suffix}")) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

fn hash_file(path: &Path) -> io::Result<(u64, String)> {
    let mut input = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut size = 0_u64;
    let mut buffer = vec![0_u8; CHUNK_BYTES];
    loop {
        let read = input.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        size = size
            .checked_add(read as u64)
            .ok_or_else(|| invalid_data("backup file size overflow"))?;
        if size > MAX_FILE_BYTES {
            return Err(invalid_data("backup file exceeds the size limit"));
        }
        hasher.update(&buffer[..read]);
    }
    Ok((size, hex::encode(hasher.finalize())))
}

fn read_u16(input: &mut impl Read) -> io::Result<u16> {
    let mut bytes = [0; 2];
    input.read_exact(&mut bytes)?;
    Ok(u16::from_be_bytes(bytes))
}

fn read_u32(input: &mut impl Read) -> io::Result<u32> {
    let mut bytes = [0; 4];
    input.read_exact(&mut bytes)?;
    Ok(u32::from_be_bytes(bytes))
}

fn invalid_data(message: impl std::fmt::Display) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
    };

    use serde_json::json;
    use sqlx::sqlite::SqlitePoolOptions;
    use uuid::Uuid;

    use crate::{AuthRateLimits, Config, open_state};

    use super::*;

    #[test]
    fn postgres_restore_accepts_only_current_and_explicitly_migratable_archive_versions() {
        assert!(supported_pg_archive_schema_version(25));
        assert!(supported_pg_archive_schema_version(26));
        assert!(supported_pg_archive_schema_version(27));
        assert!(supported_pg_archive_schema_version(28));
        assert!(supported_pg_archive_schema_version(29));
        assert!(supported_pg_archive_schema_version(30));
        assert!(supported_pg_archive_schema_version(31));
        assert!(supported_pg_archive_schema_version(32));
        assert!(supported_pg_archive_schema_version(33));
        assert!(supported_pg_archive_schema_version(34));
        assert!(supported_pg_archive_schema_version(35));
        assert!(supported_pg_archive_schema_version(36));
        assert!(supported_pg_archive_schema_version(37));
        assert!(supported_pg_archive_schema_version(38));
        assert!(supported_pg_archive_schema_version(39));
        assert!(!supported_pg_archive_schema_version(24));
        assert!(!supported_pg_archive_schema_version(40));
    }

    #[test]
    fn postgres_dump_service_config_preserves_hostless_socket_defaults() {
        let root = temp_root();
        let service_path = root.join("service.conf");
        write_pg_service_config("postgresql:///atermius_test_socket", &service_path).unwrap();
        let service = fs::read_to_string(&service_path).unwrap();
        assert_eq!(service, "[atermius-backup]\ndbname=atermius_test_socket\n");
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn postgres_restore_upgrades_schema_25_through_39_targets_with_bundled_migrations() {
        use std::str::FromStr;

        use sqlx::{Connection, PgConnection, postgres::PgConnectOptions, postgres::PgPoolOptions};

        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for PostgreSQL restore acceptance");
        let parsed_url = url::Url::parse(&database_url).unwrap();
        let database_name = parsed_url.path().trim_start_matches('/');
        assert!(
            database_name.starts_with("atermius_test")
                || database_name.starts_with("atermius_pg_test"),
            "PostgreSQL restore test requires an explicitly disposable database"
        );

        let options = PgConnectOptions::from_str(&database_url).unwrap();
        let mut migration_connection = PgConnection::connect_with(&options).await.unwrap();
        let migration_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
        for archive_version in [
            25_u32, 26_u32, 27_u32, 28_u32, 29_u32, 30_u32, 31_u32, 32_u32, 33_u32, 34_u32, 35_u32,
            36_u32, 37_u32, 38_u32,
        ] {
            let schema = format!(
                "atermius_restore_v{archive_version}_{}",
                Uuid::new_v4().simple()
            );
            let quoted_schema = format!("\"{schema}\"");
            sqlx::raw_sql(&format!("CREATE SCHEMA {quoted_schema}"))
                .execute(&mut migration_connection)
                .await
                .unwrap();
            sqlx::raw_sql(&format!("SET search_path TO {quoted_schema}"))
                .execute(&mut migration_connection)
                .await
                .unwrap();
            let pool = PgPoolOptions::new()
                .max_connections(1)
                .connect_with(
                    options
                        .clone()
                        .options([("search_path", format!("\"{schema}\""))]),
                )
                .await
                .unwrap();

            let mut migrations: Vec<_> = fs::read_dir(&migration_dir)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| {
                    path.extension().is_some_and(|extension| extension == "sql")
                        && path
                            .file_name()
                            .and_then(|name| name.to_str())
                            .and_then(|name| name.get(..4))
                            .and_then(|version| version.parse::<u32>().ok())
                            .is_some_and(|version| version <= archive_version)
                })
                .collect();
            migrations.sort();
            assert!(!migrations.is_empty());
            for migration in migrations {
                let sql = fs::read_to_string(migration).unwrap();
                sqlx::raw_sql(&sql)
                    .execute(&mut migration_connection)
                    .await
                    .unwrap();
            }

            let marker_before: i64 = sqlx::query_scalar(
                "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
            )
            .fetch_one(&mut migration_connection)
            .await
            .unwrap();
            assert_eq!(marker_before, archive_version as i64);

            let legacy_user = Uuid::new_v4().to_string();
            let legacy_vault = Uuid::new_v4().to_string();
            let legacy_record = Uuid::new_v4().to_string();
            let legacy_revision = Uuid::new_v4().to_string();
            let legacy_created_at =
                chrono::DateTime::parse_from_rfc3339("2025-01-02T03:04:05.123456Z")
                    .unwrap()
                    .with_timezone(&chrono::Utc);
            sqlx::query("INSERT INTO users(user_id,username) VALUES($1,$2)")
                .bind(&legacy_user)
                .bind(format!("{legacy_user}@example.test"))
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query("INSERT INTO vaults(vault_id,owner_user_id) VALUES($1,$2)")
                .bind(&legacy_vault)
                .bind(&legacy_user)
                .execute(&pool)
                .await
                .unwrap();
            sqlx::query(
                "INSERT INTO record_versions( \
                     vault_id,record_id,revision_id,base_revision_id,envelope,digest, \
                     commit_seq,device_id,operation,created_at \
                 ) VALUES($1,$2,$3,NULL,'{}','legacy-deadline',1,'legacy-device','delete',$4)",
            )
            .bind(&legacy_vault)
            .bind(&legacy_record)
            .bind(&legacy_revision)
            .bind(legacy_created_at)
            .execute(&pool)
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
                 VALUES($1,$2,$3,1)",
            )
            .bind(&legacy_vault)
            .bind(&legacy_record)
            .bind(&legacy_revision)
            .execute(&pool)
            .await
            .unwrap();
            if archive_version >= 33 {
                sqlx::query(
                    "UPDATE record_graveyard SET auto_purge_enabled=TRUE,auto_purge_revision=7 \
                     WHERE vault_id=$1 AND record_id=$2",
                )
                .bind(&legacy_vault)
                .bind(&legacy_record)
                .execute(&pool)
                .await
                .unwrap();
            }
            if archive_version >= 34 {
                sqlx::query(
                    "UPDATE record_auto_purge_scan_control SET \
                     after_vault_id=$1,server_generation=9,cursor_revision=41, \
                     lease_token='archived-stale-lease', \
                     lease_expires_at=clock_timestamp()+INTERVAL '1 hour', \
                     last_scan_status='failed',last_scan_started_at=clock_timestamp(), \
                     last_scan_finished_at=clock_timestamp(),last_scan_candidates=7, \
                     last_scan_purged=3,last_scan_not_due=2,last_scan_capability_blocked=1, \
                     last_scan_conflict_blocked=1,last_scan_reference_blocked=1, \
                     last_scan_stale_or_withdrawn=1 WHERE singleton=1",
                )
                .bind(&legacy_vault)
                .execute(&pool)
                .await
                .unwrap();
                sqlx::query(
                    "INSERT INTO record_auto_purge_vault_cursors( \
                         vault_id,after_record_id,high_water_record_id,pending_record_id, \
                         pending_deleted_revision_id,pending_deleted_seq,server_generation \
                     ) VALUES($1,NULL,$2,$2,$3,1,9)",
                )
                .bind(&legacy_vault)
                .bind(&legacy_record)
                .bind(&legacy_revision)
                .execute(&pool)
                .await
                .unwrap();
            }
            let legacy_running_replication_id = Uuid::new_v4().to_string();
            if archive_version == 36 {
                sqlx::query(
                    "INSERT INTO instance_backup_replications( \
                         archive_id,origin,created_at,status,attempt_count,started_at,last_attempt_at \
                     ) VALUES($1,'manual',clock_timestamp(),'running',3,clock_timestamp(),clock_timestamp())",
                )
                .bind(&legacy_running_replication_id)
                .execute(&pool)
                .await
                .unwrap();
            }

            upgrade_restored_postgres_archive(&pool, &schema, marker_before, 7)
                .await
                .unwrap();
            let deadline_matches_archived_policy: bool = sqlx::query_scalar(&format!(
                "SELECT restore_until=created_at + make_interval(days => 7) \
                 FROM {quoted_schema}.record_versions \
                 WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3"
            ))
            .bind(&legacy_vault)
            .bind(&legacy_record)
            .bind(&legacy_revision)
            .fetch_one(&pool)
            .await
            .unwrap();
            let tombstone_purge_disabled_by_default: bool = sqlx::query_scalar(&format!(
                "SELECT auto_purge_enabled=FALSE AND auto_purge_revision=$3 \
                 FROM {quoted_schema}.record_graveyard WHERE vault_id=$1 AND record_id=$2"
            ))
            .bind(&legacy_vault)
            .bind(&legacy_record)
            .bind(if archive_version >= 33 { 8_i64 } else { 0_i64 })
            .fetch_one(&pool)
            .await
            .unwrap();
            let scan_control_reset: bool = sqlx::query_scalar(
                "SELECT after_vault_id IS NULL AND server_generation=1 \
                   AND cursor_revision=CASE WHEN $1>=34 THEN 42 ELSE 1 END \
                   AND lease_token IS NULL AND lease_expires_at IS NULL \
                   AND last_scan_status='never' AND last_scan_started_at IS NULL \
                   AND last_scan_finished_at IS NULL AND last_scan_candidates=0 \
                   AND last_scan_purged=0 AND last_scan_not_due=0 \
                   AND last_scan_capability_blocked=0 AND last_scan_conflict_blocked=0 \
                   AND last_scan_reference_blocked=0 AND last_scan_stale_or_withdrawn=0 \
                 FROM record_auto_purge_scan_control WHERE singleton=1",
            )
            .bind(archive_version as i64)
            .fetch_one(&pool)
            .await
            .unwrap();
            let remaining_scan_cursors: i64 =
                sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            let marker_after: i64 = sqlx::query_scalar(&format!(
                "SELECT schema_version::BIGINT FROM {quoted_schema}.atermius_instance_schema WHERE singleton=1"
            ))
            .fetch_one(&pool)
            .await
            .unwrap();
            let interval_hours: Option<i32> = sqlx::query_scalar(&format!(
                "SELECT interval_hours FROM {quoted_schema}.instance_backup_schedule WHERE schedule_id=1"
            ))
            .fetch_one(&pool)
            .await
            .unwrap();
            let relay_ticket_table: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
                .bind(format!("{schema}.relay_tickets"))
                .fetch_one(&pool)
                .await
                .unwrap();
            let relay_lease_table: bool = sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
                .bind(format!("{schema}.relay_connection_leases"))
                .fetch_one(&pool)
                .await
                .unwrap();
            let record_redaction_table: bool =
                sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
                    .bind(format!("{schema}.record_redactions"))
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            let backup_replication_table: bool =
                sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
                    .bind(format!("{schema}.instance_backup_replications"))
                    .fetch_one(&pool)
                    .await
                    .unwrap();
            let legacy_replication_lease_recovered = if archive_version == 36 {
                sqlx::query_scalar::<_, bool>(
                    "SELECT status='interrupted' AND next_attempt_at IS NOT NULL \
                           AND started_at IS NULL AND failure_category='remote_unavailable' \
                           AND attempt_count=3 AND lease_expires_at IS NULL \
                     FROM instance_backup_replications WHERE archive_id=$1",
                )
                .bind(&legacy_running_replication_id)
                .fetch_one(&pool)
                .await
                .unwrap()
            } else {
                true
            };
            let redacted_conflict_check: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM pg_constraint \
                 WHERE conrelid=to_regclass($1) \
                   AND conname='conflicts_redacted_resolution_check' \
                   AND convalidated)",
            )
            .bind(format!("{schema}.conflicts"))
            .fetch_one(&pool)
            .await
            .unwrap();
            assert_eq!(marker_after, PG_BACKUP_SCHEMA_VERSION);
            assert!(deadline_matches_archived_policy);
            assert!(tombstone_purge_disabled_by_default);
            assert!(scan_control_reset);
            assert_eq!(remaining_scan_cursors, 0);
            assert_eq!(interval_hours, None);
            assert!(relay_ticket_table);
            assert!(relay_lease_table);
            assert!(record_redaction_table);
            assert!(backup_replication_table);
            assert!(legacy_replication_lease_recovered);
            assert!(redacted_conflict_check);

            sqlx::raw_sql(&format!("DROP SCHEMA IF EXISTS {quoted_schema} CASCADE"))
                .execute(&mut migration_connection)
                .await
                .unwrap();
            pool.close().await;
        }
        migration_connection.close().await.unwrap();
    }

    async fn run_postgres_encrypted_schema_25_archive(publish_for_http: bool) {
        use std::str::FromStr;

        use sqlx::{
            Connection, PgConnection,
            postgres::{PgConnectOptions, PgPoolOptions},
        };

        fn disposable_database_name(database_url: &str, variable: &str) -> String {
            let parsed = url::Url::parse(database_url)
                .unwrap_or_else(|_| panic!("{variable} must be a PostgreSQL URL"));
            assert!(
                matches!(parsed.scheme(), "postgres" | "postgresql"),
                "{variable} must use PostgreSQL"
            );
            let name = parsed.path().trim_start_matches('/');
            assert!(
                name.starts_with("atermius_test") || name.starts_with("atermius_pg_test"),
                "{variable} must name an explicitly disposable database"
            );
            assert!(!name.is_empty(), "{variable} must include a database name");
            name.to_owned()
        }

        let source_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for PostgreSQL restore acceptance");
        let archive_url = std::env::var("ATERMIUS_TEST_PG_V25_ARCHIVE_URL").expect(
            "ATERMIUS_TEST_PG_V25_ARCHIVE_URL is required for PostgreSQL restore acceptance",
        );
        let target_url = std::env::var("ATERMIUS_PG_RESTORE_TARGET_URL")
            .expect("ATERMIUS_PG_RESTORE_TARGET_URL is required for PostgreSQL restore acceptance");
        let schema = std::env::var("ATERMIUS_TEST_PG_SCHEMA")
            .expect("ATERMIUS_TEST_PG_SCHEMA is required for PostgreSQL restore acceptance");
        assert!(valid_pg_schema_identifier(&schema));
        let source_database = disposable_database_name(&source_url, "ATERMIUS_TEST_PG_URL");
        let archive_database =
            disposable_database_name(&archive_url, "ATERMIUS_TEST_PG_V25_ARCHIVE_URL");
        let target_database =
            disposable_database_name(&target_url, "ATERMIUS_PG_RESTORE_TARGET_URL");
        assert_ne!(source_database, archive_database);
        assert_ne!(source_database, target_database);
        assert_ne!(archive_database, target_database);

        let runtime = crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env()
            .expect("PostgreSQL runtime configuration must be valid")
            .expect("PostgreSQL runtime configuration must be enabled");
        assert_eq!(runtime.schema, schema);
        assert_eq!(
            disposable_database_name(&runtime.database_url, "ATERMIUS_SYNC_PG_URL"),
            source_database,
            "the runtime must use the designated live source database"
        );

        let configured_archive_dir = std::env::var_os("ATERMIUS_BACKUP_ARCHIVE_DIR")
            .map(PathBuf::from)
            .expect("ATERMIUS_BACKUP_ARCHIVE_DIR is required");
        let configured_key_file = std::env::var_os("ATERMIUS_BACKUP_KEY_FILE")
            .map(PathBuf::from)
            .expect("ATERMIUS_BACKUP_KEY_FILE is required");
        let object_root = std::env::var_os("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT")
            .map(PathBuf::from)
            .expect("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT is required");
        assert_eq!(
            std::env::var("ATERMIUS_OBJECT_STORE_BACKEND").as_deref(),
            Ok("filesystem"),
            "the acceptance requires the filesystem object store"
        );
        assert!(configured_archive_dir.is_dir());
        assert!(configured_key_file.is_file());
        assert!(object_root.is_dir());

        // PostgreSQL runtime mode validates a fully migrated shared schema;
        // unlike SQLite, open_state deliberately does not create or upgrade
        // the serving PostgreSQL schema. Prepare the disposable live source
        // here so the acceptance can exercise the real runtime and worker.
        let mut source_connection =
            PgConnection::connect_with(&PgConnectOptions::from_str(&source_url).unwrap())
                .await
                .expect("disposable live source database must be reachable");
        let source_schema_exists: bool =
            sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
                .bind(&schema)
                .fetch_one(&mut source_connection)
                .await
                .unwrap();
        if publish_for_http || source_schema_exists {
            assert!(
                source_schema_exists,
                "the pre-provisioned PostgreSQL fixture must provide an already-migrated live source schema"
            );
            source_connection.close().await.unwrap();
        } else {
            assert!(
                !source_schema_exists,
                "the designated live source database must not already contain the test schema"
            );
            sqlx::raw_sql(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&mut source_connection)
                .await
                .unwrap();
            source_connection.close().await.unwrap();
            let source_options = PgConnectOptions::from_str(&source_url)
                .unwrap()
                .options([("search_path", format!("\"{schema}\""))]);
            let mut source_migration_connection =
                PgConnection::connect_with(&source_options).await.unwrap();
            let migration_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
            let mut source_migrations: Vec<_> = fs::read_dir(&migration_dir)
                .unwrap()
                .map(|entry| entry.unwrap().path())
                .filter(|path| {
                    path.extension().is_some_and(|extension| extension == "sql")
                        && path
                            .file_name()
                            .and_then(|name| name.to_str())
                            .and_then(|name| name.get(..4))
                            .and_then(|version| version.parse::<u32>().ok())
                            .is_some_and(|version| version <= PG_BACKUP_SCHEMA_VERSION as u32)
                })
                .collect();
            source_migrations.sort();
            assert!(!source_migrations.is_empty());
            for migration in source_migrations {
                let sql = fs::read_to_string(migration).unwrap();
                sqlx::raw_sql(&sql)
                    .execute(&mut source_migration_connection)
                    .await
                    .unwrap();
            }
            source_migration_connection.close().await.unwrap();
        }

        let work = create_private_temp_dir(&std::env::temp_dir(), "atermius-pg-v25-restore-test")
            .expect("private PG restore test directory must be created");
        let data_dir = work.0.join("runtime-data");
        secure_file::create_private_data_dir(&data_dir).unwrap();
        let mut config = Config::from_env();
        config.data_dir = data_dir.clone();
        let config = config;
        let state = open_state(&sqlite_url(&data_dir.join("atermius.db")), config.clone())
            .await
            .expect("PG runtime state must open against the disposable source");
        assert!(state.pg_sync_only);
        assert_eq!(
            state.object_store.backend_name(),
            "filesystem",
            "the acceptance must use the configured filesystem object store"
        );
        let original_store_id = state
            .object_store
            .store_id()
            .expect("configured external object store must have an identity")
            .to_owned();
        let source_pool = state.pg_sync_pool.as_ref().unwrap();
        let source_marker: i64 = sqlx::query_scalar(
            "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
        )
        .fetch_one(source_pool)
        .await
        .unwrap();
        assert_eq!(source_marker, PG_BACKUP_SCHEMA_VERSION);
        assert!(postgres_restore_target_ready(source_pool, &target_url).await);

        let source_baseline: (String, String, i64, i64) = sqlx::query_as(
            "SELECT m.generation,m.signing_public_key, \
                    (SELECT COUNT(*) FROM sessions), \
                    (SELECT COUNT(*) FROM blob_objects) \
             FROM instance_meta m WHERE m.id=1",
        )
        .fetch_one(source_pool)
        .await
        .unwrap();
        let pg_options = PgConnectOptions::from_str(&archive_url).unwrap();
        let mut archive_connection = PgConnection::connect_with(&pg_options)
            .await
            .expect("marker-25 archive database must be reachable");
        let archive_database_actual: String = sqlx::query_scalar("SELECT current_database()")
            .fetch_one(&mut archive_connection)
            .await
            .unwrap();
        assert_eq!(archive_database_actual, archive_database);
        let schema_exists: bool = sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
            .bind(&schema)
            .fetch_one(&mut archive_connection)
            .await
            .unwrap();
        assert!(
            !schema_exists,
            "the designated marker-25 archive database must not already contain the test schema"
        );
        sqlx::raw_sql(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&mut archive_connection)
            .await
            .unwrap();
        sqlx::raw_sql(&format!("SET search_path TO \"{schema}\""))
            .execute(&mut archive_connection)
            .await
            .unwrap();

        let migration_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
        let mut migrations: Vec<_> = fs::read_dir(&migration_dir)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.extension().is_some_and(|extension| extension == "sql")
                    && path
                        .file_name()
                        .and_then(|name| name.to_str())
                        .and_then(|name| name.get(..4))
                        .and_then(|version| version.parse::<u32>().ok())
                        .is_some_and(|version| version <= 25)
            })
            .collect();
        migrations.sort();
        assert!(!migrations.is_empty());
        for migration in migrations {
            let sql = fs::read_to_string(migration).unwrap();
            sqlx::raw_sql(&sql)
                .execute(&mut archive_connection)
                .await
                .unwrap();
        }

        let old_generation = Uuid::new_v4().to_string();
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let object_id = Uuid::new_v4().to_string();
        let upload_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        let object_bytes = b"pg-schema-25-restore-object-bytes\0opaque";
        let object_sha256 = hex::encode(Sha256::digest(object_bytes));
        let object_key = format!(
            "atermius/objects/v1/{}/{vault_id}/{object_id}/{upload_id}",
            state.instance.instance_id
        );
        let archived_public_key = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(state.signing_key.verifying_key().as_bytes());
        let archive_store_id = original_store_id.clone();
        sqlx::query(
            "INSERT INTO instance_meta( \
                 id,instance_id,server_space_id,generation,signing_public_key \
             ) VALUES(1,$1,$2,$3,$4)",
        )
        .bind(&state.instance.instance_id)
        .bind(&state.instance.server_space_id)
        .bind(&old_generation)
        .bind(&archived_public_key)
        .execute(&mut archive_connection)
        .await
        .unwrap();
        sqlx::query("INSERT INTO users(user_id,username) VALUES($1,$2)")
            .bind(&user_id)
            .bind(format!("{user_id}@example.test"))
            .execute(&mut archive_connection)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id) VALUES($1,$2)")
            .bind(&device_id)
            .bind(&user_id)
            .execute(&mut archive_connection)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO sessions( \
                 session_id,user_id,device_id,family_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at \
             ) VALUES($1,$2,$3,$4,$5,$6,clock_timestamp()+INTERVAL '1 day', \
                     clock_timestamp()+INTERVAL '30 days')",
        )
        .bind(&session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .execute(&mut archive_connection)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id) VALUES($1,$2)")
            .bind(&vault_id)
            .bind(&user_id)
            .execute(&mut archive_connection)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects( \
                 vault_id,object_id,size,sha256,storage_backend,storage_key, \
                 storage_store_id,storage_state \
             ) VALUES($1,$2,$3,$4,'filesystem',$5,$6,'available')",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .bind(object_bytes.len() as i64)
        .bind(&object_sha256)
        .bind(&object_key)
        .bind(&archive_store_id)
        .execute(&mut archive_connection)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES($1,$2,$3)",
        )
        .bind(&vault_id)
        .bind(&revision_id)
        .bind(&object_id)
        .execute(&mut archive_connection)
        .await
        .unwrap();

        let archive_marker: i64 = sqlx::query_scalar(
            "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
        )
        .fetch_one(&mut archive_connection)
        .await
        .unwrap();
        assert_eq!(archive_marker, MIN_SUPPORTED_PG_ARCHIVE_SCHEMA_VERSION);
        let server_version_num: i32 =
            sqlx::query_scalar("SELECT current_setting('server_version_num')::integer")
                .fetch_one(&mut archive_connection)
                .await
                .unwrap();
        archive_connection.close().await.unwrap();

        let service_file = work.0.join("archive-source-service.conf");
        write_pg_service_config(&archive_url, &service_file).unwrap();
        let dump_path = work.0.join("postgres.dump");
        let dump_status = tokio::process::Command::new("pg_dump")
            .arg("--format=custom")
            .arg("--no-owner")
            .arg("--no-privileges")
            .arg("--schema")
            .arg(&schema)
            .arg("--file")
            .arg(&dump_path)
            .arg("--dbname=service=atermius-backup")
            .env("PGSERVICEFILE", &service_file)
            .env_remove("PGPASSWORD")
            .env_remove("PGPASSFILE")
            .env_remove("PGHOST")
            .env_remove("PGPORT")
            .env_remove("PGDATABASE")
            .env_remove("PGUSER")
            .env_remove("PGSERVICE")
            .env_remove("PGOPTIONS")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .expect("pg_dump must be installed");
        assert!(
            dump_status.success(),
            "pg_dump must create the v25 custom dump"
        );
        validate_pg_dump(&dump_path).await.unwrap();

        let signing_key_path = work.0.join("instance-ed25519.key");
        let rate_key_path = work.0.join("auth-rate-limit.key");
        write_private_file(&signing_key_path, &state.signing_key.to_bytes()).unwrap();
        let rate_key = Zeroizing::new(
            secure_file::read_private_key(&runtime.auth_rate_limit_key_file).unwrap(),
        );
        write_private_file(&rate_key_path, rate_key.as_ref()).unwrap();
        let object_path = work.0.join("object-00000000.blob");
        write_private_file(&object_path, object_bytes).unwrap();
        let pg_dump_version = run_pg_tool_version("pg_dump").await.unwrap();
        let metadata = PgArchiveMetadata {
            format_version: 1,
            schema: schema.clone(),
            pg_dump_version,
            server_version_num,
            object_store_id: archive_store_id.clone(),
            objects: vec![PgArchiveObject {
                vault_id: vault_id.clone(),
                object_id: object_id.clone(),
                storage_backend: "filesystem".to_owned(),
                storage_key: object_key.clone(),
                storage_store_id: archive_store_id,
                size: object_bytes.len() as i64,
                sha256: object_sha256.clone(),
                archive_file: "object-00000000.blob".to_owned(),
            }],
        };
        let metadata_path = work.0.join("postgres-metadata.json");
        write_private_file(&metadata_path, &serde_jcs::to_vec(&metadata).unwrap()).unwrap();
        let mut source_files = vec![
            SourceFile {
                name: "auth-rate-limit.key".to_owned(),
                path: rate_key_path,
            },
            SourceFile {
                name: "postgres-metadata.json".to_owned(),
                path: metadata_path,
            },
            SourceFile {
                name: "postgres.dump".to_owned(),
                path: dump_path,
            },
            SourceFile {
                name: "instance-ed25519.key".to_owned(),
                path: signing_key_path,
            },
            SourceFile {
                name: "object-00000000.blob".to_owned(),
                path: object_path,
            },
        ];
        source_files.sort_by(|left, right| left.name.cmp(&right.name));
        let manifest = build_postgres_manifest(&source_files, archive_marker, &config).unwrap();
        let backup_key =
            Zeroizing::new(secure_file::read_private_key(&configured_key_file).unwrap());
        let backup_id = Uuid::new_v4().to_string();
        let archive_timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ").to_string();
        let archive_path = configured_archive_dir.join(format!(
            "atermius-backup-{archive_timestamp}-{backup_id}.atb"
        ));
        let archive_guard = TempFile(archive_path.clone());
        let (temporary_archive, mut archive_file) =
            create_private_archive_temp(&archive_path).unwrap();
        write_encrypted_archive(&mut archive_file, &backup_key, &manifest, &source_files).unwrap();
        archive_file.sync_all().unwrap();
        drop(archive_file);
        fs::hard_link(&temporary_archive.0, &archive_path).unwrap();
        drop(temporary_archive);
        sync_parent(&archive_path).unwrap();
        let (archive_file, archive_sha256) =
            open_and_hash_generated_archive(&archive_path).unwrap();
        let verify_dir = work.0.join("verify-archive");
        create_private_dir(&verify_dir).unwrap();
        let archive_manifest =
            read_encrypted_archive(archive_file, &backup_key, &verify_dir).unwrap();
        assert_eq!(archive_manifest.migration_version, 25);
        verify_postgres_archive_metadata(&archive_manifest, &verify_dir)
            .await
            .unwrap();

        let active_jobs: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM instance_admin_jobs WHERE status IN ('queued','running')",
        )
        .fetch_one(source_pool)
        .await
        .unwrap();
        assert_eq!(
            active_jobs, 0,
            "the source schema must have no active admin job"
        );
        let actor_user_id = Uuid::new_v4().to_string();
        let actor_device_id = Uuid::new_v4().to_string();
        let backup_request_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO instance_admin_jobs( \
                 job_id,request_id,requested_by_user_id,requested_by_device_id,action, \
                 archive_id,archive_sha256,archive_timestamp,archive_bytes,status, \
                 requested_at,started_at,finished_at,result_code,request_origin \
             ) VALUES($1,$2,$3,$4,'backup',$1,$5,$6,$7,'succeeded', \
                      clock_timestamp(),clock_timestamp(),clock_timestamp(),'completed','manual')",
        )
        .bind(&backup_id)
        .bind(backup_request_id)
        .bind(&actor_user_id)
        .bind(&actor_device_id)
        .bind(&archive_sha256)
        .bind(&archive_timestamp)
        .bind(fs::metadata(&archive_path).unwrap().len() as i64)
        .execute(source_pool)
        .await
        .unwrap();
        if publish_for_http {
            let source_after: (String, String, i64, i64) = sqlx::query_as(
                "SELECT m.generation,m.signing_public_key, \
                        (SELECT COUNT(*) FROM sessions), \
                        (SELECT COUNT(*) FROM blob_objects) \
                 FROM instance_meta m WHERE m.id=1",
            )
            .fetch_one(source_pool)
            .await
            .unwrap();
            assert_eq!(
                source_after, source_baseline,
                "publishing the historical fixture must leave the live source unchanged"
            );
            assert!(archive_guard.0.exists());
            std::mem::forget(archive_guard);
            drop(state);
            println!("PG-V25-HTTP-FIXTURE archive_id={backup_id}");
            return;
        }
        let restore_job_id = Uuid::new_v4().to_string();
        let restore_request_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO instance_admin_jobs( \
                 job_id,request_id,requested_by_user_id,requested_by_device_id,action, \
                 archive_id,archive_source,status,request_origin \
             ) VALUES($1,$2,$3,$4,'restore',$5,'local','queued','manual')",
        )
        .bind(&restore_job_id)
        .bind(&restore_request_id)
        .bind(&actor_user_id)
        .bind(&actor_device_id)
        .bind(&backup_id)
        .execute(source_pool)
        .await
        .unwrap();

        crate::pg_admin_jobs::run_one_available(&state)
            .await
            .expect("PostgreSQL admin worker must process the marker-25 restore job");

        let restore_row = sqlx::query(
            "SELECT status,result_code,archive_id,archive_source,archive_sha256, \
                    restore_stage_status,restore_stage_generation \
             FROM instance_admin_jobs WHERE job_id=$1",
        )
        .bind(&restore_job_id)
        .fetch_one(source_pool)
        .await
        .unwrap();
        let status: String = restore_row.try_get("status").unwrap();
        let result_code: String = restore_row.try_get("result_code").unwrap();
        let restored_archive_id: String = restore_row.try_get("archive_id").unwrap();
        let restored_archive_source: String = restore_row.try_get("archive_source").unwrap();
        let restored_digest: String = restore_row.try_get("archive_sha256").unwrap();
        let stage_status: String = restore_row.try_get("restore_stage_status").unwrap();
        let stage_generation: String = restore_row.try_get("restore_stage_generation").unwrap();
        assert_eq!(status, "succeeded");
        assert_eq!(result_code, "completed");
        assert_eq!(restored_archive_id, backup_id);
        assert_eq!(restored_archive_source, "local");
        assert_eq!(restored_digest, archive_sha256);
        assert_eq!(stage_status, "ready");

        let stage_dir = configured_archive_dir
            .join("restore-staging")
            .join(format!("atermius-pg-restore-{restore_job_id}"));
        let stage_guard = TempDirectory(stage_dir.clone());
        assert!(
            stage_dir.is_dir(),
            "successful restore must publish its stage"
        );
        let receipt_bytes = fs::read(stage_dir.join("postgres-restore-receipt.json")).unwrap();
        let receipt: PgRestoreStageReceipt = serde_json::from_slice(&receipt_bytes).unwrap();
        assert_eq!(receipt.format_version, 1);
        assert_eq!(receipt.job_id, restore_job_id);
        assert_eq!(receipt.archive_id, backup_id);
        assert_eq!(receipt.archive_sha256, archive_sha256);
        assert_eq!(receipt.generation, stage_generation);
        assert_ne!(receipt.generation, old_generation);
        assert_eq!(receipt.schema, schema);
        assert_eq!(receipt.restored_objects, 1);
        assert_ne!(receipt.object_store_id, original_store_id);

        let target_options = PgConnectOptions::from_str(&target_url)
            .unwrap()
            .options([("search_path", format!("\"{schema}\""))]);
        let target_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(target_options)
            .await
            .expect("restored PostgreSQL target must be queryable");
        let target_marker: i64 = sqlx::query_scalar(
            "SELECT schema_version::BIGINT FROM atermius_instance_schema WHERE singleton=1",
        )
        .fetch_one(&target_pool)
        .await
        .unwrap();
        let target_schedule: (Option<i32>, Option<chrono::DateTime<chrono::Utc>>) = sqlx::query_as(
            "SELECT interval_hours,next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
        )
        .fetch_one(&target_pool)
        .await
        .unwrap();
        let target_identity: (String, String, String) = sqlx::query_as(
            "SELECT instance_id,generation,signing_public_key FROM instance_meta WHERE id=1",
        )
        .fetch_one(&target_pool)
        .await
        .unwrap();
        let archived_active_sessions: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM sessions WHERE revoked_at IS NULL")
                .fetch_one(&target_pool)
                .await
                .unwrap();
        let restored_object: (String, String, i64, String, String, String, String) =
            sqlx::query_as(
                "SELECT vault_id,object_id,size,sha256,storage_backend,storage_store_id,storage_key \
                 FROM blob_objects WHERE storage_state='available'",
            )
            .fetch_one(&target_pool)
            .await
            .unwrap();
        let restored_references: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_references WHERE vault_id=$1 AND object_id=$2",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .fetch_one(&target_pool)
        .await
        .unwrap();
        target_pool.close().await;

        assert_eq!(target_marker, PG_BACKUP_SCHEMA_VERSION);
        assert_eq!(target_schedule, (None, None));
        assert_eq!(target_identity.0, state.instance.instance_id);
        assert_eq!(target_identity.1, stage_generation);
        assert_eq!(target_identity.2, archived_public_key);
        assert_eq!(archived_active_sessions, 0);
        assert_eq!(restored_object.0, vault_id);
        assert_eq!(restored_object.1, object_id);
        assert_eq!(restored_object.2, object_bytes.len() as i64);
        assert_eq!(restored_object.3, object_sha256);
        assert_eq!(restored_object.4, "filesystem");
        assert_eq!(restored_object.5, receipt.object_store_id);
        assert_eq!(restored_object.6, object_key);
        assert_eq!(restored_references, 1);
        let restored_object_path = stage_dir
            .join("object-store")
            .join("atermius/objects/v1")
            .join(&state.instance.instance_id)
            .join(&vault_id)
            .join(&object_id)
            .join(&upload_id);
        assert_eq!(fs::read(&restored_object_path).unwrap(), object_bytes);
        for leftover in [
            "postgres.dump",
            "postgres-metadata.json",
            "object-00000000.blob",
        ] {
            assert!(
                !stage_dir.join(leftover).exists(),
                "published restore stage must remove extracted {leftover}"
            );
        }

        // Exercise the coordinator path after promotion: the active sync URL
        // points at the restored DB while the discard API's restore-target URL
        // remains independently configurable.
        let _active_sync_url = ScopedEnvOverride::set("ATERMIUS_SYNC_PG_URL", &target_url);
        let _restore_target_url =
            ScopedEnvOverride::set("ATERMIUS_PG_RESTORE_TARGET_URL", &target_url);
        let malformed = activate_pg_restore_stage(&state, "not-a-canonical-uuid")
            .await
            .unwrap_err();
        assert_eq!(malformed.body.code, "NOT_FOUND");
        let nonmatching_job = activate_pg_restore_stage(&state, &Uuid::new_v4().to_string())
            .await
            .unwrap_err();
        assert_eq!(nonmatching_job.body.code, "RESTORE_STAGE_UNAVAILABLE");
        let malformed_fence = fence_pg_restore_stage_rollback(&state, "not-a-canonical-uuid")
            .await
            .unwrap_err();
        assert_eq!(malformed_fence.body.code, "NOT_FOUND");
        let nonmatching_fence =
            fence_pg_restore_stage_rollback(&state, &Uuid::new_v4().to_string())
                .await
                .unwrap_err();
        assert_eq!(nonmatching_fence.body.code, "RESTORE_STAGE_UNAVAILABLE");

        let mut target_connection =
            PgConnection::connect_with(&PgConnectOptions::from_str(&target_url).unwrap())
                .await
                .unwrap();
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} DROP COLUMN activated_at"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} DROP COLUMN rollback_started_at"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        let legacy_discard_guard = prepare_pg_restore_stage_discard(&state, &restore_job_id, false)
            .await
            .unwrap();
        drop(legacy_discard_guard);
        let legacy_activation = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            legacy_activation.body.code,
            "RESTORE_STAGE_ACTIVATION_UNSUPPORTED"
        );
        let legacy_fence = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            legacy_fence.body.code,
            "RESTORE_STAGE_ROLLBACK_FENCE_UNSUPPORTED"
        );
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} ADD COLUMN activated_at TIMESTAMPTZ"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} ADD COLUMN rollback_started_at TIMESTAMPTZ"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} DROP COLUMN rollback_started_at"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        let missing_rollback_activation = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            missing_rollback_activation.body.code,
            "RESTORE_STAGE_ACTIVATION_UNSUPPORTED"
        );
        let missing_rollback_fence = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            missing_rollback_fence.body.code,
            "RESTORE_STAGE_ROLLBACK_FENCE_UNSUPPORTED"
        );
        let missing_rollback_discard =
            prepare_pg_restore_stage_discard(&state, &restore_job_id, false)
                .await
                .unwrap();
        drop(missing_rollback_discard);
        sqlx::query(&format!(
            "ALTER TABLE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} ADD COLUMN rollback_started_at TIMESTAMPTZ"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        let mismatched_job_id = Uuid::new_v4().to_string();
        sqlx::query(&format!(
            "UPDATE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} SET job_id=$1::UUID WHERE singleton=1"
        ))
        .bind(&mismatched_job_id)
        .execute(&mut target_connection)
        .await
        .unwrap();
        target_connection.close().await.unwrap();
        let mismatched_marker = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(mismatched_marker.body.code, "RESTORE_STAGE_UNAVAILABLE");

        let mut target_connection =
            PgConnection::connect_with(&PgConnectOptions::from_str(&target_url).unwrap())
                .await
                .unwrap();
        sqlx::query(&format!(
            "UPDATE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} SET job_id=$1::UUID WHERE singleton=1"
        ))
        .bind(&restore_job_id)
        .execute(&mut target_connection)
        .await
        .unwrap();
        let binding_lock_key = pg_restore_discard_lock_key(&receipt.binding_id).unwrap();
        sqlx::query("SELECT pg_advisory_lock($1)")
            .bind(binding_lock_key)
            .execute(&mut target_connection)
            .await
            .unwrap();
        let locked_activation = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            locked_activation.body.code,
            "RESTORE_STAGE_ACTIVATION_IN_PROGRESS"
        );
        let locked_fence = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(
            locked_fence.body.code,
            "RESTORE_STAGE_ROLLBACK_FENCE_IN_PROGRESS"
        );
        let _: bool = sqlx::query_scalar("SELECT pg_advisory_unlock($1)")
            .bind(binding_lock_key)
            .fetch_one(&mut target_connection)
            .await
            .unwrap();
        target_connection.close().await.unwrap();

        let fenced = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(fenced.status, "fenced");
        assert_eq!(fenced.rollback_timestamp.is_some(), true);
        assert_eq!(fenced.job_id, restore_job_id);
        assert_eq!(fenced.target_database_name, target_database);
        assert_eq!(fenced.target_database_oid, receipt.target_database_oid);
        assert_eq!(fenced.schema, schema);
        assert_eq!(fenced.generation, stage_generation);
        assert_eq!(fenced.object_store_id, receipt.object_store_id);
        assert_eq!(fenced.restored_objects, 1);
        let replayed_fence = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(replayed_fence.status, "already_fenced");
        assert_eq!(replayed_fence.rollback_timestamp, fenced.rollback_timestamp);
        let fenced_activation = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap_err();
        assert_eq!(fenced_activation.body.code, "RESTORE_STAGE_ROLLBACK_FENCED");

        // Test-only fixture reset: clear the durable rollback fence so this
        // same isolated target can continue testing activation semantics.
        let mut target_connection =
            PgConnection::connect_with(&PgConnectOptions::from_str(&target_url).unwrap())
                .await
                .unwrap();
        sqlx::query(&format!(
            "UPDATE {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} SET rollback_started_at=NULL WHERE singleton=1"
        ))
        .execute(&mut target_connection)
        .await
        .unwrap();
        target_connection.close().await.unwrap();

        let activated = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(activated.status, "activated");
        assert_eq!(activated.job_id, restore_job_id);
        assert_eq!(activated.target_database_name, target_database);
        assert_eq!(activated.target_database_oid, receipt.target_database_oid);
        assert_eq!(activated.schema, schema);
        assert_eq!(activated.generation, stage_generation);
        assert_eq!(activated.object_store_id, receipt.object_store_id);
        assert_eq!(activated.restored_objects, 1);
        let replayed = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(replayed.status, "already_activated");
        assert_eq!(
            replayed.activation_timestamp,
            activated.activation_timestamp
        );
        let activated_fence = fence_pg_restore_stage_rollback(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(activated_fence.status, "activated");
        assert_eq!(activated_fence.rollback_timestamp, None);

        let discard_error = prepare_pg_restore_stage_discard(&state, &restore_job_id, false)
            .await
            .err()
            .unwrap();
        assert_eq!(discard_error.body.code, "RESTORE_STAGE_ACTIVATED");
        let mut target_connection =
            PgConnection::connect_with(&PgConnectOptions::from_str(&target_url).unwrap())
                .await
                .unwrap();
        let marker_activation: chrono::DateTime<chrono::Utc> = sqlx::query_scalar(&format!(
            "SELECT activated_at FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} WHERE singleton=1"
        ))
        .fetch_one(&mut target_connection)
        .await
        .unwrap();
        let marker_rollback: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(&format!(
            "SELECT rollback_started_at FROM {PG_RESTORE_CONTROL_SCHEMA}.{PG_RESTORE_CONTROL_TABLE} WHERE singleton=1"
        ))
        .fetch_one(&mut target_connection)
        .await
        .unwrap();
        let target_schema_exists: bool =
            sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
                .bind(&schema)
                .fetch_one(&mut target_connection)
                .await
                .unwrap();
        let quoted_schema = format!("\"{schema}\"");
        let target_objects_after_discard_rejection: i64 = sqlx::query_scalar(&format!(
            "SELECT COUNT(*)::BIGINT FROM {quoted_schema}.blob_objects WHERE storage_state='available'"
        ))
        .fetch_one(&mut target_connection)
        .await
        .unwrap();
        assert!(target_schema_exists);
        assert_eq!(target_objects_after_discard_rejection, 1);
        assert_eq!(marker_rollback, None);
        assert_eq!(
            marker_activation.to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
            activated.activation_timestamp
        );
        target_connection.close().await.unwrap();
        assert_eq!(fs::read(&restored_object_path).unwrap(), object_bytes);
        assert!(stage_dir.is_dir());

        // Moving the staging URL to a third database after promotion does not
        // redirect activation away from the active runtime target.
        let _third_restore_target =
            ScopedEnvOverride::set("ATERMIUS_PG_RESTORE_TARGET_URL", &source_url);
        let replayed_after_target_url_move = activate_pg_restore_stage(&state, &restore_job_id)
            .await
            .unwrap();
        assert_eq!(replayed_after_target_url_move.status, "already_activated");
        assert_eq!(
            replayed_after_target_url_move.activation_timestamp,
            activated.activation_timestamp
        );

        let source_after: (String, String, i64, i64) = sqlx::query_as(
            "SELECT m.generation,m.signing_public_key, \
                    (SELECT COUNT(*) FROM sessions), \
                    (SELECT COUNT(*) FROM blob_objects) \
             FROM instance_meta m WHERE m.id=1",
        )
        .fetch_one(source_pool)
        .await
        .unwrap();
        assert_eq!(
            source_after, source_baseline,
            "restore must leave live source data unchanged"
        );
        assert!(archive_guard.0.exists());

        archive_connection = PgConnection::connect_with(&pg_options).await.unwrap();
        let quoted_schema = format!("\"{schema}\"");
        sqlx::raw_sql(&format!("DROP SCHEMA {quoted_schema} CASCADE"))
            .execute(&mut archive_connection)
            .await
            .unwrap();
        archive_connection.close().await.unwrap();
        drop(stage_guard);
        drop(archive_guard);
        drop(state);
        println!("PG-V25-RESTORE-01 passed");
    }

    #[tokio::test]
    #[ignore = "requires disposable PostgreSQL source, marker-25 archive, and isolated restore target URLs"]
    async fn postgres_restore_full_encrypted_schema_25_archive() {
        run_postgres_encrypted_schema_25_archive(false).await;
    }

    #[tokio::test]
    #[ignore = "requires disposable PostgreSQL source, marker-25 archive, and isolated restore target URLs"]
    async fn postgres_publish_encrypted_schema_25_archive_for_http_acceptance() {
        run_postgres_encrypted_schema_25_archive(true).await;
    }

    fn test_config(data_dir: PathBuf) -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            mfa_encryption_key_file: None,
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
            vault_deletion_grace_seconds: 604800,
            account_deletion_grace_seconds: 604800,
            audit_retention_days: 365,
            object_gc_grace_seconds: 604800,
            admin_usernames: Vec::new(),
            auth_rate_limits: AuthRateLimits::default(),
        }
    }

    #[test]
    fn stale_replica_restore_source_cleanup_accepts_only_private_regular_files() {
        let root = std::env::temp_dir().join(format!("atermius-restore-source-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let source = root.join("job.source.atb");
        fs::write(&source, b"encrypted archive bytes").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o600)).unwrap();
        cleanup_exact_restore_source_file(&source).unwrap();
        assert!(!source.exists());

        let target = root.join("target.atb");
        fs::write(&target, b"encrypted archive bytes").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        let link = root.join("job.source.atb");
        std::os::unix::fs::symlink(&target, &link).unwrap();
        assert!(cleanup_exact_restore_source_file(&link).is_err());
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn backup_runtime_policy_records_config_and_accepts_legacy_summaries() {
        let mut config = test_config(PathBuf::new());
        config.relay_allow_ports = vec![22, 2200];
        config.admin_usernames = vec!["Admin@example.test".to_owned()];
        config.public_origin = Some("https://sync.example.test".to_owned());
        config.web_dir = Some(PathBuf::from("/srv/atermius/web"));
        let summary = runtime_policy_summary(&config);
        let value = serde_json::to_value(&summary).unwrap();
        assert_eq!(summary.policy_version, RUNTIME_POLICY_VERSION);
        assert_eq!(
            value["auth_rate_limits"]["max_active_recovery_challenges"],
            crate::DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP
        );
        assert_eq!(value["relay_allow_ports"], serde_json::json!([22, 2200]));
        assert_eq!(
            value["admin_usernames"],
            serde_json::json!(["Admin@example.test"])
        );
        assert_eq!(value["public_origin"], "https://sync.example.test");
        assert_eq!(value["web_dir"], "/srv/atermius/web");

        config.relay_allow_ports.clear();
        let legacy_compatible = serde_json::to_value(runtime_policy_summary(&config)).unwrap();
        assert!(legacy_compatible.get("relay_allow_ports").is_none());
        let mut legacy_compatible = legacy_compatible;
        let legacy_object = legacy_compatible.as_object_mut().unwrap();
        legacy_object.remove("policy_version");
        legacy_object.remove("public_origin");
        legacy_object.remove("web_dir");
        legacy_object.remove("admin_usernames");
        legacy_object.remove("record_restore_retention_days");
        let parsed: RuntimePolicySummary = serde_json::from_value(legacy_compatible).unwrap();
        assert_eq!(parsed.policy_version, 0);
        assert!(parsed.relay_allow_ports.is_empty());
        assert!(parsed.admin_usernames.is_empty());
        assert!(parsed.public_origin.is_none());
        assert!(parsed.web_dir.is_none());
        assert_eq!(parsed.record_restore_retention_days, 30);
        let drift = runtime_policy_drift_fields(&parsed, &config).unwrap();
        assert!(drift.iter().any(|field| field == "runtime_policy_version"));

        let mut unknown_field = serde_json::to_value(runtime_policy_summary(&config)).unwrap();
        unknown_field["unexpected_policy"] = serde_json::json!(true);
        assert!(serde_json::from_value::<RuntimePolicySummary>(unknown_field).is_err());
    }

    #[test]
    fn runtime_policy_drift_lists_field_names_without_values() {
        let mut archived_config = test_config(PathBuf::new());
        archived_config.admin_usernames = vec!["secret-admin@example.test".to_owned()];
        archived_config.public_origin = Some("https://private-origin.example.test".to_owned());
        archived_config.relay_allow_cidrs = vec!["10.0.0.0/8".parse().unwrap()];
        archived_config.relay_allow_ports = vec![22];
        let archived = runtime_policy_summary(&archived_config);

        let mut target_config = archived_config.clone();
        target_config.registration_open = true;
        target_config.relay_enabled = true;
        target_config.relay_allow_cidrs = vec!["192.168.0.0/16".parse().unwrap()];
        target_config.relay_allow_ports = vec![2200];
        target_config.relay_max_connections_per_user = 8;
        target_config.public_origin = Some("https://target-origin.example.test".to_owned());
        target_config.web_dir = Some(PathBuf::from("/srv/target-web"));
        target_config.max_object_bytes += 1;
        target_config.max_request_bytes += 1;
        target_config.history_retention_days += 1;
        target_config.record_restore_retention_days += 1;
        target_config.vault_deletion_grace_seconds += 1;
        target_config.account_deletion_grace_seconds += 1;
        target_config.audit_retention_days += 1;
        target_config.object_gc_grace_seconds += 1;
        target_config.admin_usernames = vec!["target-admin@example.test".to_owned()];
        target_config.auth_rate_limits.login_user_limit += 1;
        target_config
            .auth_rate_limits
            .max_active_recovery_challenges += 1;

        let fields = runtime_policy_drift_fields(&archived, &target_config).unwrap();
        for expected in [
            "registration_open",
            "relay_enabled",
            "relay_allow_cidrs",
            "relay_allow_ports",
            "relay_max_connections_per_user",
            "public_origin",
            "web_dir",
            "max_object_bytes",
            "max_request_bytes",
            "history_retention_days",
            "record_restore_retention_days",
            "vault_deletion_grace_seconds",
            "account_deletion_grace_seconds",
            "audit_retention_days",
            "object_gc_grace_seconds",
            "admin_usernames",
            "auth_rate_limits",
        ] {
            assert!(
                fields.iter().any(|field| field == expected),
                "missing {expected}"
            );
        }
        let error = runtime_policy_drift_error(&fields).to_string();
        assert!(error.contains("admin_usernames"));
        assert!(error.contains("public_origin"));
        assert!(!error.contains("secret-admin@example.test"));
        assert!(!error.contains("private-origin.example.test"));
        assert!(!error.contains("target-admin@example.test"));
        assert!(!error.contains("target-origin.example.test"));
    }

    #[test]
    fn runtime_policy_drift_rejects_unknown_policy_versions() {
        let config = test_config(PathBuf::new());
        let mut archived = runtime_policy_summary(&config);
        archived.policy_version = RUNTIME_POLICY_VERSION + 1;
        let error = runtime_policy_drift_fields(&archived, &config).unwrap_err();
        assert_eq!(error.body.code, "BACKUP_POLICY_UNSUPPORTED");
    }

    async fn state_at(directory: &Path) -> AppState {
        secure_file::create_private_data_dir(directory).unwrap();
        open_state(
            &sqlite_url(&directory.join("atermius.db")),
            test_config(directory.to_owned()),
        )
        .await
        .unwrap()
    }

    #[tokio::test]
    async fn sqlite_archive_policy_freezes_legacy_delete_deadlines_during_restore() {
        let data_dir = std::env::temp_dir().join(format!(
            "atermius-sqlite-archive-deadline-{}",
            Uuid::new_v4()
        ));
        let state = state_at(&data_dir).await;
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        let created_at = chrono::DateTime::parse_from_rfc3339("2025-01-02T03:04:05.123456Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{user_id}@example.test"))
            .bind(created_at.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(&user_id)
            .bind(created_at.to_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id, \
                 operation,created_at \
             ) VALUES(?,?,?,'{}','legacy',1,'legacy-device','delete',?)",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&revision_id)
        .bind(created_at.to_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
        state.db.close().await;

        // The restore target's current policy is deliberately much longer;
        // legacy rows must be frozen using the archive's policy summary.
        let mut target_config = test_config(data_dir.clone());
        target_config.record_restore_retention_days = 3650;
        let restored = crate::open_state_with_restore_policy(
            &sqlite_url(&data_dir.join("atermius.db")),
            target_config,
            7,
        )
        .await
        .unwrap();
        let restore_until: String = sqlx::query_scalar(
            "SELECT restore_until FROM record_versions WHERE vault_id=? AND record_id=? AND revision_id=?",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&revision_id)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        let observed = chrono::DateTime::parse_from_rfc3339(&restore_until)
            .unwrap()
            .with_timezone(&chrono::Utc);
        assert_eq!(observed, created_at + chrono::Duration::days(7));

        restored.db.close().await;
        let _ = fs::remove_dir_all(&data_dir);
    }

    async fn sqlite_pool_readonly(path: &Path) -> sqlx::SqlitePool {
        let options = SqliteConnectOptions::new()
            .filename(path)
            .read_only(true)
            .immutable(true)
            .foreign_keys(true);
        SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap()
    }

    fn assert_exact_published_restore_stage_files(path: &Path) {
        let mut actual = fs::read_dir(path)
            .unwrap()
            .map(|entry| {
                entry
                    .unwrap()
                    .file_name()
                    .into_string()
                    .expect("restore stage entry name must be UTF-8")
            })
            .collect::<Vec<_>>();
        let mut expected = RESTORE_STAGE_DATA_FILES
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        expected.push(RESTORE_STAGE_RECEIPT_FILE.to_owned());
        actual.sort();
        expected.sort();
        assert_eq!(
            actual, expected,
            "published stage contains only fixed files"
        );
    }

    async fn state_with_backup_retention(
        data_dir: &Path,
        archive_dir: &Path,
        key_path: &Path,
        retention_count: Option<&str>,
    ) -> AppState {
        secure_file::create_private_data_dir(data_dir).unwrap();
        fs::create_dir(archive_dir).unwrap();
        fs::set_permissions(archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        write_backup_key(key_path);
        let mut config = test_config(data_dir.to_owned());
        config.backup_archive_dir = Some(archive_dir.to_owned());
        config.backup_key_file = Some(key_path.to_owned());
        config.backup_retention_count = retention_count.map(Into::into);
        open_state(&sqlite_url(&data_dir.join("atermius.db")), config)
            .await
            .unwrap()
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn postgres_running_backup_archive_is_visible_only_to_replication_resolver() {
        use std::str::FromStr;

        use sqlx::{postgres::PgConnectOptions, postgres::PgPoolOptions};

        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for the PostgreSQL archive resolver test");
        let options = PgConnectOptions::from_str(&database_url).unwrap();
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "archive resolver test requires an explicitly disposable PostgreSQL database"
        );
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone())
            .await
            .unwrap();
        let schema = format!("atermius_pg_backup_resolver_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .unwrap();
        let pg_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
            .await
            .unwrap();

        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let mut state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        state.pg_sync_only = true;
        state.pg_sync_pool = Some(pg_pool.clone());

        let result = async {
            sqlx::raw_sql(
                "CREATE TABLE instance_admin_jobs ( \
                   job_id TEXT PRIMARY KEY, action TEXT NOT NULL, status TEXT NOT NULL, \
                   request_origin TEXT NOT NULL, requested_at TIMESTAMPTZ NOT NULL, \
                   started_at TIMESTAMPTZ, finished_at TIMESTAMPTZ, \
                   archive_timestamp TEXT, archive_bytes BIGINT \
                 )",
            )
            .execute(&pg_pool)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()))?;
            let archive_id = Uuid::new_v4().to_string();
            let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ").to_string();
            let archive_path =
                archive_dir.join(format!("atermius-backup-{timestamp}-{archive_id}.atb"));
            fs::write(&archive_path, b"published encrypted archive bytes")?;
            fs::set_permissions(&archive_path, fs::Permissions::from_mode(0o600))?;
            let archive_bytes = fs::metadata(&archive_path)?.len() as i64;
            sqlx::query(
                "INSERT INTO instance_admin_jobs( \
                     job_id,action,status,request_origin,requested_at,started_at, \
                     archive_timestamp,archive_bytes \
                 ) VALUES($1,'backup','running','manual',clock_timestamp(), \
                          clock_timestamp(),$2,$3)",
            )
            .bind(&archive_id)
            .bind(&timestamp)
            .bind(archive_bytes)
            .execute(&pg_pool)
            .await
            .map_err(|error| std::io::Error::other(error.to_string()))?;

            let settings = configured_backup_paths(&state.config).map_err(|error| {
                std::io::Error::other(format!("backup settings rejected: {}", error.body.code))
            })?;
            let internal_path =
                generated_archive_path_for_id(&state, &settings, &archive_id, "manual")
                    .await
                    .map_err(|error| {
                        std::io::Error::other(format!(
                            "internal archive lookup failed: {}",
                            error.body.code
                        ))
                    })?;
            let public_sources =
                list_server_generated_restore_sources_with_settings(&state, &settings)
                    .await
                    .map_err(|error| {
                        std::io::Error::other(format!(
                            "public archive listing failed: {}",
                            error.body.code
                        ))
                    })?;
            Ok::<_, std::io::Error>((archive_path, internal_path, public_sources))
        }
        .await;

        state.db.close().await;
        pg_pool.close().await;
        sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
            .execute(&admin_pool)
            .await
            .unwrap();
        admin_pool.close().await;
        let _ = fs::remove_dir_all(&root);
        let (archive_path, internal_path, public_sources) = result.unwrap();
        assert_eq!(internal_path.as_deref(), Some(archive_path.as_path()));
        assert!(
            public_sources.is_empty(),
            "a running producer archive must not appear in the public restore catalog"
        );
    }

    async fn create_registered_backup(
        state: &AppState,
        archive_dir: &Path,
        key_path: &Path,
        archive_id: &str,
        config: &Config,
    ) -> (PathBuf, String) {
        let timestamp = chrono::Utc::now().format("%Y%m%dT%H%M%S%.3fZ").to_string();
        let archive_path =
            archive_dir.join(format!("atermius-backup-{timestamp}-{archive_id}.atb"));
        backup_instance(
            config,
            &sqlite_url(&config.data_dir.join("atermius.db")),
            &archive_path,
            key_path,
        )
        .await
        .unwrap();
        let created_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,
                archive_timestamp,status,requested_at,started_at,finished_at,result_code
             ) VALUES(?,?,?,?,? ,?,'succeeded',?, ?,?,'completed')",
        )
        .bind(archive_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind("backup")
        .bind(&timestamp)
        .bind(&created_at)
        .bind(&created_at)
        .bind(&created_at)
        .execute(&state.db)
        .await
        .unwrap();
        (archive_path, timestamp)
    }

    async fn insert_running_restore_job(state: &AppState, job_id: &str, archive_id: &str) {
        let now = crate::now_rfc3339();
        sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,archive_id,
                status,requested_at,started_at
             ) VALUES(?,?,?,?, 'restore',?,'running',?,?)",
        )
        .bind(job_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(archive_id)
        .bind(&now)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
    }

    struct ScopedEnvOverride {
        key: &'static str,
        original: Option<std::ffi::OsString>,
    }

    impl ScopedEnvOverride {
        fn set(key: &'static str, value: &str) -> Self {
            let original = std::env::var_os(key);
            // This opt-in acceptance is run with one Rust test thread because
            // it exercises multiple disposable database endpoints.
            unsafe { std::env::set_var(key, value) };
            Self { key, original }
        }
    }

    impl Drop for ScopedEnvOverride {
        fn drop(&mut self) {
            match self.original.as_ref() {
                Some(value) => unsafe { std::env::set_var(self.key, value) },
                None => unsafe { std::env::remove_var(self.key) },
            }
        }
    }

    struct ReadyRestoreInstallFixture {
        root: PathBuf,
        data_dir: PathBuf,
        archive_dir: PathBuf,
        config: Config,
        job_id: String,
        generation: String,
    }

    async fn ready_restore_install_fixture() -> ReadyRestoreInstallFixture {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        let _server_lock = crate::acquire_runtime_lock(&data_dir).unwrap();

        let archive_id = Uuid::new_v4().to_string();
        create_registered_backup(&state, &archive_dir, &key_path, &archive_id, &state.config).await;
        let job_id = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &job_id, &archive_id).await;
        run_configured_admin_restore_stage(
            &state,
            &job_id,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap();
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();

        let stage_dir = archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{job_id}"));
        let generation = read_restore_stage_receipt(&stage_dir).unwrap().generation;
        let status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(status, "succeeded");
        let config = (*state.config).clone();
        // Model an operator stopping the source cleanly and checkpointing the
        // WAL before invoking the read-only installer. The installer itself
        // never checkpoints or otherwise writes to this source volume.
        drop(_server_lock);
        checkpoint_and_close(&state).await;
        for suffix in ["-wal", "-shm"] {
            let sidecar = PathBuf::from(format!(
                "{}{}",
                data_dir.join("atermius.db").display(),
                suffix
            ));
            match fs::symlink_metadata(&sidecar) {
                Ok(metadata)
                    if metadata.file_type().is_file()
                        && (suffix == "-shm" || metadata.len() == 0) =>
                {
                    // A completed checkpoint plus a closed pool can leave an
                    // empty WAL or stale shared-memory index. This fixture
                    // models the operator's verified offline cleanup step.
                    fs::remove_file(sidecar).unwrap();
                }
                Ok(metadata) => panic!(
                    "fixture checkpoint left unsafe {suffix} sidecar ({} bytes)",
                    metadata.len()
                ),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => panic!("could not inspect fixture {suffix} sidecar: {error}"),
            }
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = PathBuf::from(format!(
                "{}{}",
                data_dir.join("atermius.db").display(),
                suffix
            ));
            if let Ok(metadata) = fs::symlink_metadata(&sidecar) {
                panic!(
                    "checkpointed, closed fixture still has SQLite sidecar {sidecar:?} ({})",
                    metadata.len()
                );
            }
        }

        ReadyRestoreInstallFixture {
            root,
            data_dir,
            archive_dir,
            config,
            job_id,
            generation,
        }
    }

    #[cfg(unix)]
    fn snapshot_directory(path: &Path) -> std::collections::BTreeMap<String, (Vec<u8>, u32)> {
        use std::os::unix::fs::PermissionsExt;

        fs::read_dir(path)
            .unwrap()
            .map(|entry| {
                let entry = entry.unwrap();
                let metadata = entry.metadata().unwrap();
                assert!(metadata.is_file());
                (
                    entry.file_name().into_string().unwrap(),
                    (
                        fs::read(entry.path()).unwrap(),
                        metadata.permissions().mode() & 0o7777,
                    ),
                )
            })
            .collect()
    }

    async fn fail_restore_job(state: &AppState, job_id: &str) {
        sqlx::query(
            "UPDATE instance_admin_jobs SET status='failed',finished_at=?,result_code='restore_failed' \
             WHERE job_id=? AND action='restore' AND status='running'",
        )
        .bind(crate::now_rfc3339())
        .bind(job_id)
        .execute(&state.db)
        .await
        .unwrap();
    }

    async fn insert_backup_source_row(state: &AppState, archive_id: &str, timestamp: Option<&str>) {
        let created_at = "2026-01-02T03:04:05.000Z";
        sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,
                archive_timestamp,status,requested_at,started_at,finished_at,result_code
             ) VALUES(?,?,?,?, 'backup',?,'succeeded',?, ?,?,'completed')",
        )
        .bind(archive_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(timestamp)
        .bind(created_at)
        .bind(created_at)
        .bind(created_at)
        .execute(&state.db)
        .await
        .unwrap();
    }

    async fn insert_backup_job(state: &AppState, job_id: &str) {
        sqlx::query(
            "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,requested_at,started_at,finished_at,result_code) \
             VALUES(?,?,? ,?,'backup','succeeded','2026-01-01T00:00:00.000Z','2026-01-01T00:00:00.000Z','2026-01-01T00:00:01.000Z','completed')",
        )
        .bind(job_id)
        .bind(Uuid::new_v4().to_string())
        .bind("retention-test-user")
        .bind("retention-test-device")
        .execute(&state.db)
        .await
        .unwrap();
    }

    fn retention_archive_name(timestamp: &str, job_id: &str) -> String {
        format!("atermius-backup-{timestamp}-{job_id}.atb")
    }

    fn write_retention_archive(archive_dir: &Path, timestamp: &str, job_id: &str) -> PathBuf {
        let path = archive_dir.join(retention_archive_name(timestamp, job_id));
        write_private_file(&path, b"fixture archive bytes").unwrap();
        path
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn backup_retention_is_disabled_when_count_is_unset() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        let old_id = Uuid::new_v4().to_string();
        let new_id = Uuid::new_v4().to_string();
        insert_backup_job(&state, &old_id).await;
        insert_backup_job(&state, &new_id).await;
        let old_archive = write_retention_archive(&archive_dir, "20260101T000000.000Z", &old_id);
        let new_archive = write_retention_archive(&archive_dir, "20260102T000000.000Z", &new_id);

        crate::run_maintenance(&state).await.unwrap();

        assert!(old_archive.is_file());
        assert!(new_archive.is_file());
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn restore_source_catalog_requires_durable_id_and_safe_exact_archive_file() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;

        let timestamp = "20260102T030405.000Z";
        let valid_id = Uuid::new_v4().to_string();
        let symlink_id = Uuid::new_v4().to_string();
        let hardlink_id = Uuid::new_v4().to_string();
        let scheduled_id = Uuid::new_v4().to_string();
        let unregistered_id = Uuid::new_v4().to_string();
        for archive_id in [&valid_id, &symlink_id, &hardlink_id] {
            insert_backup_source_row(&state, archive_id, Some(timestamp)).await;
        }
        let valid_path = archive_dir.join(format!("atermius-backup-{timestamp}-{valid_id}.atb"));
        write_private_file(&valid_path, b"private generated archive").unwrap();
        let scheduled_epoch = chrono::DateTime::parse_from_rfc3339("2026-01-02T03:04:05Z")
            .unwrap()
            .timestamp();
        let scheduled_path =
            archive_dir.join(format!("atermius-backup-{timestamp}-{scheduled_id}.atb"));
        write_private_file(&scheduled_path, b"scheduled archive").unwrap();
        sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(
                run_id,scheduled_for,started_at,finished_at,status,result_code,
                migration_version,archive_bytes
             ) VALUES(?,?,?,?,'succeeded','completed',?,?)",
        )
        .bind(&scheduled_id)
        .bind(scheduled_epoch)
        .bind(scheduled_epoch)
        .bind(scheduled_epoch + 1)
        .bind(current_migration_version())
        .bind(b"scheduled archive".len() as i64)
        .execute(&state.db)
        .await
        .unwrap();
        let symlink_path =
            archive_dir.join(format!("atermius-backup-{timestamp}-{symlink_id}.atb"));
        let symlink_target = root.join("symlink-target.atb");
        write_private_file(&symlink_target, b"not a catalog source").unwrap();
        symlink(&symlink_target, &symlink_path).unwrap();
        let hardlink_path =
            archive_dir.join(format!("atermius-backup-{timestamp}-{hardlink_id}.atb"));
        let hardlink_target = root.join("hardlink-target.atb");
        write_private_file(&hardlink_target, b"hard-linked archive").unwrap();
        fs::hard_link(&hardlink_target, &hardlink_path).unwrap();
        write_private_file(
            &archive_dir.join(format!("atermius-backup-{timestamp}-{unregistered_id}.atb")),
            b"unregistered file",
        )
        .unwrap();

        let settings = configured_backup_paths(&state.config).unwrap();
        let sources = list_server_generated_restore_sources_with_settings(&state, &settings)
            .await
            .unwrap();
        assert_eq!(sources.len(), 2);
        let manual_source = sources
            .iter()
            .find(|source| source.archive_id == valid_id)
            .unwrap();
        assert_eq!(manual_source.origin, "manual");
        assert_eq!(
            manual_source.archive_bytes,
            b"private generated archive".len() as u64
        );
        assert_eq!(manual_source.created_at, "2026-01-02T03:04:05.000Z");
        let scheduled_source = sources
            .iter()
            .find(|source| source.archive_id == scheduled_id)
            .unwrap();
        assert_eq!(scheduled_source.origin, "scheduled");
        assert_eq!(
            scheduled_source.archive_bytes,
            b"scheduled archive".len() as u64
        );
        assert!(
            !server_generated_restore_source_exists(
                &state,
                &symlink_id,
                crate::backup_replication::ArchiveSource::Local,
                &configured_backup_paths(&state.config).unwrap()
            )
            .await
            .unwrap()
        );

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn online_restore_stages_under_runtime_lock_preserves_live_data_and_recovers_once() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        let live_generation = state.instance.generation.clone();
        let user_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind("preserved@example.test")
            .bind(crate::now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let archive_id = Uuid::new_v4().to_string();
        let (archive_path, _) =
            create_registered_backup(&state, &archive_dir, &key_path, &archive_id, &state.config)
                .await;
        let job_id = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &job_id, &archive_id).await;

        let _runtime_lock = crate::acquire_runtime_lock(&data_dir).unwrap();
        run_configured_admin_restore_stage(
            &state,
            &job_id,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap();

        let target = archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{job_id}"));
        assert!(target.is_dir());
        assert_exact_published_restore_stage_files(&target);
        let receipt = read_restore_stage_receipt(&target).unwrap();
        assert_eq!(receipt.job_id, job_id);
        assert_eq!(receipt.archive_id, archive_id);
        assert_eq!(receipt.archive_sha256, hash_file(&archive_path).unwrap().1);
        let expected_policy_sha256 = runtime_policy_sha256(&state.config).unwrap();
        assert_eq!(
            receipt.runtime_policy_sha256.as_deref(),
            Some(expected_policy_sha256.as_str())
        );
        assert_ne!(receipt.generation, live_generation);
        let durable_digest: String =
            sqlx::query_scalar("SELECT archive_sha256 FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(durable_digest, receipt.archive_sha256);
        let stage_pool = sqlite_pool_readonly(&target.join("atermius.db")).await;
        let staged_user_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE user_id=?")
                .bind(&user_id)
                .fetch_one(&stage_pool)
                .await
                .unwrap();
        stage_pool.close().await;
        assert_exact_published_restore_stage_files(&target);
        assert_eq!(staged_user_count, 1);
        assert_eq!(state.instance.generation, live_generation);
        let live_user_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users WHERE user_id=?")
            .bind(&user_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(live_user_count, 1);

        let duplicate = run_configured_admin_restore_stage(
            &state,
            &job_id,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap_err();
        assert_eq!(duplicate.body.code, "RESTORE_STAGE_EXISTS");
        assert_eq!(
            read_restore_stage_receipt(&target).unwrap().archive_sha256,
            durable_digest
        );

        // Retention can prune the source after the maintenance lock is
        // released but before the completion row/audit is committed.
        fs::remove_file(&archive_path).unwrap();
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();
        assert_exact_published_restore_stage_files(&target);
        let status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(status, "succeeded");
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();
        let completed_audits: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_completed'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(completed_audits, 1);

        drop(_runtime_lock);
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn offline_install_copies_ready_stage_and_never_changes_source_volume() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = ready_restore_install_fixture().await;
        let target_parent = fixture.root.join("new-volume");
        fs::create_dir(&target_parent).unwrap();
        fs::set_permissions(&target_parent, fs::Permissions::from_mode(0o700)).unwrap();
        let target = target_parent.join("data");
        let stage_dir = fixture
            .archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{}", fixture.job_id));
        let source_before = snapshot_directory(&fixture.data_dir);
        let stage_before = snapshot_directory(&stage_dir);

        let generation = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap();

        assert_eq!(generation, fixture.generation);
        assert_eq!(snapshot_directory(&fixture.data_dir), source_before);
        assert_eq!(snapshot_directory(&stage_dir), stage_before);
        let mut installed = fs::read_dir(&target)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect::<Vec<_>>();
        let mut expected = RESTORE_STAGE_DATA_FILES
            .into_iter()
            .map(str::to_owned)
            .collect::<Vec<_>>();
        installed.sort();
        expected.sort();
        assert_eq!(installed, expected, "only the fixed payload is installed");
        for name in RESTORE_STAGE_DATA_FILES {
            assert_eq!(
                fs::metadata(target.join(name))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o700
        );
        validate_installed_restore_payload(&target, &fixture.generation)
            .await
            .unwrap();

        fs::remove_dir_all(fixture.root).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn offline_install_rejects_policy_drift_and_legacy_receipts_without_publication() {
        let fixture = ready_restore_install_fixture().await;
        let target_parent = fixture.root.join("new-volume");
        fs::create_dir(&target_parent).unwrap();
        let target = target_parent.join("data");
        let source_before = snapshot_directory(&fixture.data_dir);
        let stage_dir = fixture
            .archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{}", fixture.job_id));
        let stage_before = snapshot_directory(&stage_dir);

        let receipt_path = stage_dir.join(RESTORE_STAGE_RECEIPT_FILE);
        let original_receipt = fs::read(&receipt_path).unwrap();
        let mut mismatched_receipt: serde_json::Value =
            serde_json::from_slice(&original_receipt).unwrap();
        mismatched_receipt["archive_sha256"] = serde_json::Value::String("0".repeat(64));
        fs::write(
            &receipt_path,
            serde_json::to_vec(&mismatched_receipt).unwrap(),
        )
        .unwrap();
        let binding_mismatch = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(binding_mismatch.body.code, "RESTORE_STAGE_UNAVAILABLE");
        assert!(!target.exists());
        fs::write(&receipt_path, &original_receipt).unwrap();

        let mut changed_policy = fixture.config.clone();
        changed_policy.relay_enabled = true;
        let drift =
            install_configured_admin_restore_stage(changed_policy, &fixture.job_id, &target)
                .await
                .unwrap_err();
        assert_eq!(drift.body.code, "RUNTIME_POLICY_DRIFT");
        assert!(!target.exists());
        assert_eq!(snapshot_directory(&fixture.data_dir), source_before);
        assert_eq!(snapshot_directory(&stage_dir), stage_before);

        let mut legacy: serde_json::Value =
            serde_json::from_slice(&fs::read(&receipt_path).unwrap()).unwrap();
        legacy
            .as_object_mut()
            .unwrap()
            .remove("runtime_policy_sha256");
        fs::write(&receipt_path, serde_json::to_vec(&legacy).unwrap()).unwrap();
        let legacy_receipt = read_restore_stage_receipt(&stage_dir).unwrap();
        assert!(legacy_receipt.runtime_policy_sha256.is_none());
        let legacy = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(legacy.body.code, "RESTORE_STAGE_POLICY_UNVERIFIABLE");
        assert!(!target.exists());
        assert_eq!(snapshot_directory(&fixture.data_dir), source_before);

        fs::remove_dir_all(fixture.root).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn offline_install_requires_existing_private_unlocked_source_lock() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = ready_restore_install_fixture().await;
        let target_parent = fixture.root.join("new-volume");
        fs::create_dir(&target_parent).unwrap();
        let target = target_parent.join("data");
        let lock_path = fixture.data_dir.join("server.lock");
        let source_before = snapshot_directory(&fixture.data_dir);

        for (suffix, contents) in [
            ("-wal", &b"uncheckpointed source database state"[..]),
            ("-shm", &b""[..]),
            ("-journal", &b"rollback journal"[..]),
        ] {
            let sidecar = PathBuf::from(format!(
                "{}{}",
                fixture.data_dir.join("atermius.db").display(),
                suffix
            ));
            fs::write(&sidecar, contents).unwrap();
            let source_with_sidecar = snapshot_directory(&fixture.data_dir);
            let rejected = install_configured_admin_restore_stage(
                fixture.config.clone(),
                &fixture.job_id,
                &target,
            )
            .await
            .unwrap_err();
            assert_eq!(rejected.body.code, "RESTORE_SOURCE_NOT_QUIESCENT");
            assert_eq!(snapshot_directory(&fixture.data_dir), source_with_sidecar);
            assert!(!target.exists());
            fs::remove_file(sidecar).unwrap();
        }

        fs::remove_file(&lock_path).unwrap();
        let source_without_lock = snapshot_directory(&fixture.data_dir);
        let absent = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(absent.body.code, "SERVER_LOCK_UNAVAILABLE");
        assert!(!lock_path.exists(), "installer must not create the lock");
        assert_eq!(snapshot_directory(&fixture.data_dir), source_without_lock);
        assert!(!target.exists());

        fs::write(&lock_path, b"").unwrap();
        fs::set_permissions(&lock_path, fs::Permissions::from_mode(0o644)).unwrap();
        let invalid_lock_mode = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(invalid_lock_mode.body.code, "INTERNAL");
        assert_eq!(
            fs::metadata(&lock_path).unwrap().permissions().mode() & 0o777,
            0o644,
            "installer must not chmod an unsafe pre-existing lock"
        );

        fs::remove_file(&lock_path).unwrap();
        let _held_lock = crate::acquire_runtime_lock(&fixture.data_dir).unwrap();
        let source_while_locked = snapshot_directory(&fixture.data_dir);
        let locked = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(locked.body.code, "SERVER_RUNNING");
        assert_eq!(snapshot_directory(&fixture.data_dir), source_while_locked);
        assert!(!target.exists());
        drop(_held_lock);
        assert_ne!(source_before, source_without_lock);

        fs::remove_dir_all(fixture.root).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn offline_install_rejects_extra_stage_entries_and_existing_targets() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = ready_restore_install_fixture().await;
        let target_parent = fixture.root.join("new-volume");
        fs::create_dir(&target_parent).unwrap();
        let target = target_parent.join("data");
        let stage_dir = fixture
            .archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{}", fixture.job_id));

        let wal = stage_dir.join("atermius.db-wal");
        fs::write(&wal, b"unexpected sidecar").unwrap();
        fs::set_permissions(&wal, fs::Permissions::from_mode(0o600)).unwrap();
        let extra = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(extra.body.code, "RESTORE_STAGE_UNAVAILABLE");
        assert!(!target.exists());
        fs::remove_file(&wal).unwrap();

        fs::create_dir(&target).unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(target.join("sentinel"), b"preserve existing target").unwrap();
        let existing = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(existing.body.code, "RESTORE_TARGET_EXISTS");
        assert_eq!(
            fs::read(target.join("sentinel")).unwrap(),
            b"preserve existing target"
        );

        fs::remove_dir_all(fixture.root).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[tokio::test]
    async fn offline_install_rejects_corrupt_database_and_unsafe_key_permissions() {
        use std::os::unix::fs::PermissionsExt;

        let fixture = ready_restore_install_fixture().await;
        let target_parent = fixture.root.join("new-volume");
        fs::create_dir(&target_parent).unwrap();
        let target = target_parent.join("data");
        let stage_dir = fixture
            .archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{}", fixture.job_id));
        let source_before = snapshot_directory(&fixture.data_dir);

        let database = stage_dir.join("atermius.db");
        let database_bytes = fs::read(&database).unwrap();
        fs::write(&database, b"invalid sqlite database").unwrap();
        let corrupt = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(corrupt.body.code, "INTERNAL");
        assert!(!target.exists());
        fs::write(&database, &database_bytes).unwrap();

        let key = stage_dir.join("auth-rate-limit.key");
        fs::set_permissions(&key, fs::Permissions::from_mode(0o644)).unwrap();
        let unsafe_key = install_configured_admin_restore_stage(
            fixture.config.clone(),
            &fixture.job_id,
            &target,
        )
        .await
        .unwrap_err();
        assert_eq!(unsafe_key.body.code, "INTERNAL");
        assert!(!target.exists());
        assert_eq!(
            fs::metadata(&key).unwrap().permissions().mode() & 0o777,
            0o644,
            "installer must not repair permissions on the source stage"
        );
        assert_eq!(snapshot_directory(&fixture.data_dir), source_before);

        fs::remove_dir_all(fixture.root).unwrap();
    }

    #[test]
    fn post_publish_sync_failure_reports_target_published_and_inspect_before_retry() {
        assert!(map_published_parent_sync(Ok(())).is_ok());

        let error =
            map_published_parent_sync(Err(io::Error::other("injected fsync failure"))).unwrap_err();
        assert_eq!(error.body.code, "RESTORE_PUBLISHED_DURABILITY_UNCERTAIN");
        assert!(error.body.message.contains("target was published"));
        assert!(error.body.message.contains("durability sync is uncertain"));
        assert!(
            error
                .body
                .message
                .contains("inspect the target before retrying")
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn online_restore_rejects_invalid_source_policy_drift_and_maintenance_lock_contention() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;

        let missing_job = Uuid::new_v4().to_string();
        let missing_archive = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &missing_job, &missing_archive).await;
        let missing = run_configured_admin_restore_stage(
            &state,
            &missing_job,
            &missing_archive,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap_err();
        assert_eq!(missing.body.code, "RESTORE_SOURCE_UNAVAILABLE");
        assert!(
            !archive_dir
                .join("restore-staging")
                .join(format!("atermius-restore-{missing_job}"))
                .exists()
        );
        fail_restore_job(&state, &missing_job).await;

        let archive_id = Uuid::new_v4().to_string();
        let mut drifted_config = (*state.config).clone();
        drifted_config.relay_enabled = true;
        create_registered_backup(
            &state,
            &archive_dir,
            &key_path,
            &archive_id,
            &drifted_config,
        )
        .await;
        let drift_job = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &drift_job, &archive_id).await;
        let drift = run_configured_admin_restore_stage(
            &state,
            &drift_job,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap_err();
        assert_eq!(drift.body.code, "RUNTIME_POLICY_DRIFT");
        let drift_target = archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{drift_job}"));
        let drift_temporary = archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{drift_job}.staging"));
        assert!(!drift_target.exists());
        assert!(!drift_temporary.exists());
        let drift_digest: Option<String> =
            sqlx::query_scalar("SELECT archive_sha256 FROM instance_admin_jobs WHERE job_id=?")
                .bind(&drift_job)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(drift_digest.is_none());
        fail_restore_job(&state, &drift_job).await;

        let lock_job = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &lock_job, &archive_id).await;
        let maintenance_lock = crate::acquire_maintenance_run_lock(&data_dir).unwrap();
        let contention = run_configured_admin_restore_stage(
            &state,
            &lock_job,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap_err();
        assert_eq!(contention.body.code, "MAINTENANCE_ALREADY_RUNNING");
        drop(maintenance_lock);
        assert!(
            !archive_dir
                .join("restore-staging")
                .join(format!("atermius-restore-{lock_job}"))
                .exists()
        );
        fail_restore_job(&state, &lock_job).await;

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn restore_recovery_interrupts_absent_and_invalid_targets_without_blocking_live_data() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        let staging_dir = ensure_restore_staging_dir(&archive_dir).unwrap();

        let absent_job = Uuid::new_v4().to_string();
        let absent_archive = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &absent_job, &absent_archive).await;
        let temporary = staging_dir.join(format!("atermius-restore-{absent_job}.staging"));
        create_private_dir(&temporary).unwrap();
        write_private_file(&temporary.join("partial"), b"partial staged restore").unwrap();
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();
        assert!(!temporary.exists());
        let absent_status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&absent_job)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(absent_status, "interrupted");
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();
        let interrupted_events: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_interrupted'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(interrupted_events, 1);

        let invalid_job = Uuid::new_v4().to_string();
        let invalid_archive = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &invalid_job, &invalid_archive).await;
        let invalid_target = staging_dir.join(format!("atermius-restore-{invalid_job}"));
        create_private_dir(&invalid_target).unwrap();
        write_private_file(&invalid_target.join(RESTORE_STAGE_RECEIPT_FILE), b"{}").unwrap();
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();
        let invalid_status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&invalid_job)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(invalid_status, "interrupted");
        assert_eq!(
            fs::read(invalid_target.join(RESTORE_STAGE_RECEIPT_FILE)).unwrap(),
            b"{}",
            "untrusted restore output must remain untouched"
        );

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn restore_recovery_does_not_block_startup_when_optional_backup_config_is_unavailable() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;

        let job_id = Uuid::new_v4().to_string();
        let archive_id = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &job_id, &archive_id).await;
        let mut unavailable_config = (*state.config).clone();
        unavailable_config.backup_archive_dir = None;
        unavailable_config.backup_key_file = None;
        let startup_state = AppState {
            config: std::sync::Arc::new(unavailable_config),
            ..state.clone()
        };

        crate::admin::recover_interrupted_jobs(&startup_state)
            .await
            .unwrap();
        let status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(status, "interrupted");
        let audits: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='admin.restore_interrupted'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audits, 1);
        assert!(
            !archive_dir
                .join("restore-staging")
                .join(format!("atermius-restore-{job_id}"))
                .exists()
        );

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn restore_recovery_requires_private_archived_key_files() {
        use std::os::unix::fs::PermissionsExt;

        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state = state_with_backup_retention(&data_dir, &archive_dir, &key_path, None).await;
        let archive_id = Uuid::new_v4().to_string();
        let _ =
            create_registered_backup(&state, &archive_dir, &key_path, &archive_id, &state.config)
                .await;
        let job_id = Uuid::new_v4().to_string();
        insert_running_restore_job(&state, &job_id, &archive_id).await;
        run_configured_admin_restore_stage(
            &state,
            &job_id,
            &archive_id,
            crate::backup_replication::ArchiveSource::Local,
        )
        .await
        .unwrap();

        let target = archive_dir
            .join("restore-staging")
            .join(format!("atermius-restore-{job_id}"));
        let auth_key = target.join("auth-rate-limit.key");
        let key_bytes = fs::read(&auth_key).unwrap();
        fs::set_permissions(&auth_key, fs::Permissions::from_mode(0o644)).unwrap();
        crate::admin::recover_interrupted_jobs(&state)
            .await
            .unwrap();

        let status: String =
            sqlx::query_scalar("SELECT status FROM instance_admin_jobs WHERE job_id=?")
                .bind(&job_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(status, "interrupted");
        assert_eq!(fs::read(&auth_key).unwrap(), key_bytes);
        assert_eq!(
            fs::metadata(&auth_key).unwrap().permissions().mode() & 0o777,
            0o644,
            "untrusted staged key permissions must not be modified during recovery"
        );

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn backup_retention_keeps_newest_count_and_protects_cli_and_non_files() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state =
            state_with_backup_retention(&data_dir, &archive_dir, &key_path, Some("2")).await;
        let old_id = Uuid::new_v4().to_string();
        let middle_id = Uuid::new_v4().to_string();
        let newest_id = Uuid::new_v4().to_string();
        for job_id in [&old_id, &middle_id, &newest_id] {
            insert_backup_job(&state, job_id).await;
        }

        let oldest = write_retention_archive(&archive_dir, "20260101T000000.000Z", &old_id);
        let middle = write_retention_archive(&archive_dir, "20260102T000000.000Z", &middle_id);
        let newest = write_retention_archive(&archive_dir, "20260103T000000.000Z", &newest_id);

        // A CLI archive can use the server naming shape, but without a
        // durable admin-job UUID it is outside the retention set.
        let cli_id = Uuid::new_v4().to_string();
        let cli_archive = write_retention_archive(&archive_dir, "20260104T000000.000Z", &cli_id);
        let unrelated = archive_dir.join("operator-kept.atb");
        write_private_file(&unrelated, b"operator archive").unwrap();

        // Matching names do not make links or directories eligible.
        let symlink_target = root.join("symlink-target.atb");
        fs::write(&symlink_target, b"keep target").unwrap();
        let symlink_archive =
            archive_dir.join(retention_archive_name("20260105T000000.000Z", &old_id));
        symlink(&symlink_target, &symlink_archive).unwrap();
        let directory_archive =
            archive_dir.join(retention_archive_name("20260106T000000.000Z", &middle_id));
        fs::create_dir(&directory_archive).unwrap();

        crate::run_maintenance(&state).await.unwrap();

        assert!(!oldest.exists(), "oldest server backup should be pruned");
        assert!(middle.is_file());
        assert!(newest.is_file());
        assert!(cli_archive.is_file(), "CLI archive must not be pruned");
        assert!(unrelated.is_file(), "unrelated archive name must be kept");
        assert!(
            fs::symlink_metadata(&symlink_archive)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(fs::read(&symlink_target).unwrap(), b"keep target");
        assert!(directory_archive.is_dir());

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn malformed_backup_retention_config_fails_without_deleting_archives() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state =
            state_with_backup_retention(&data_dir, &archive_dir, &key_path, Some("0")).await;
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        insert_backup_job(&state, &first_id).await;
        insert_backup_job(&state, &second_id).await;
        let first = write_retention_archive(&archive_dir, "20260101T000000.000Z", &first_id);
        let second = write_retention_archive(&archive_dir, "20260102T000000.000Z", &second_id);

        let error = crate::run_maintenance(&state).await.unwrap_err();

        assert_eq!(error.body.code, "INTERNAL");
        assert!(first.is_file());
        assert!(second.is_file());
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    async fn checkpoint_and_close(state: &AppState) {
        let (busy, _log_frames, _checkpointed_frames): (i64, i64, i64) =
            sqlx::query_as("PRAGMA wal_checkpoint(TRUNCATE)")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(busy, 0, "test fixture database checkpoint was busy");
        state.db.close().await;
    }

    fn temp_root() -> PathBuf {
        let path = std::env::temp_dir().join(format!("atermius-backup-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        path
    }

    fn write_backup_key(path: &Path) -> [u8; 32] {
        let key = [0x51; 32];
        write_private_file(path, &key).unwrap();
        key
    }

    async fn seed_instance(state: &AppState) -> (String, String, String) {
        let user = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let generation = state.instance.generation.clone();
        let now = chrono::Utc::now().to_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user)
            .bind("backup@example.test")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?, ?, ?, ?)")
            .bind(&device)
            .bind(&user)
            .bind("backup device")
            .bind("signing-public")
            .bind("encryption-public")
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&user)
            .bind(&device)
            .bind(Uuid::new_v4().to_string())
            .bind("access-hash")
            .bind("refresh-hash")
            .bind(&now)
            .bind(&now)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version,quota_bytes,created_at) VALUES(?,?,'active',1,1,1073741824,?)")
            .bind(&vault)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)")
            .bind(&vault)
            .bind(&user)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,X'01020304',4,'sha','2026-01-01T00:00:00Z')")
            .bind(&vault)
            .bind(Uuid::new_v4().to_string())
            .execute(&state.db)
            .await
            .unwrap();
        (generation, user, vault)
    }

    #[tokio::test]
    async fn encrypted_backup_restore_preserves_objects_and_rotates_generation() {
        let root = temp_root();
        let source = root.join("active");
        let target = root.join("restored");
        let archive = root.join("instance.atb");
        let key_path = root.join("backup.key");
        write_backup_key(&key_path);
        let state = state_at(&source).await;
        let original_rate_key = Zeroizing::new(
            secure_file::read_private_key(&source.join("auth-rate-limit.key")).unwrap(),
        );
        let (old_generation, user, vault) = seed_instance(&state).await;
        let device_id: String = sqlx::query_scalar("SELECT device_id FROM devices WHERE user_id=?")
            .bind(&user)
            .fetch_one(&state.db)
            .await
            .unwrap();
        let old_totp_step = chrono::Utc::now().timestamp().div_euclid(30) - 10;
        let encrypted_seed = serde_json::json!({
            "version": 1,
            "nonce": "opaque-nonce",
            "ciphertext": "opaque-encrypted-seed",
        })
        .to_string();
        sqlx::query(
            "INSERT INTO auth_mfa(\
                user_id,totp_seed_envelope,enabled_at,last_totp_step,\
                pending_seed_envelope,pending_expires_at,pending_credential_version\
             ) VALUES(?,?,?,?,?,?,?)",
        )
        .bind(&user)
        .bind(&encrypted_seed)
        .bind(chrono::Utc::now().timestamp())
        .bind(old_totp_step)
        .bind("pending-encrypted-seed")
        .bind(chrono::Utc::now().timestamp() + 600)
        .bind(1_i64)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at) \
             VALUES(?,?,?,?,?)",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&user)
        .bind("ab".repeat(11))
        .bind("cd".repeat(32))
        .bind(chrono::Utc::now().timestamp())
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa_login_challenges \
             (challenge_id_hash,user_id,device_id,credential_version,expires_at) \
             VALUES(?,?,?,?,?)",
        )
        .bind("ef".repeat(32))
        .bind(&user)
        .bind(&device_id)
        .bind(1_i64)
        .bind(chrono::Utc::now().timestamp() + 300)
        .execute(&state.db)
        .await
        .unwrap();

        let pending_user = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&pending_user)
            .bind("pending-mfa@example.test")
            .bind(crate::now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa(user_id,pending_seed_envelope,pending_expires_at,pending_credential_version) \
             VALUES(?,?,?,?)",
        )
        .bind(&pending_user)
        .bind("pending-only-seed")
        .bind(chrono::Utc::now().timestamp() + 600)
        .bind(1_i64)
        .execute(&state.db)
        .await
        .unwrap();
        backup_instance_from_pool(&state.db, &state.config, &archive, &key_path)
            .await
            .unwrap();
        assert_eq!(
            fs::metadata(&archive).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let mut drifted_config = test_config(source.clone());
        drifted_config.admin_usernames = vec!["restore-drift@example.test".to_owned()];
        let rejected = restore_instance_with_runtime_policy_drift(
            drifted_config.clone(),
            &archive,
            &key_path,
            &target,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(rejected.body.code, "RUNTIME_POLICY_DRIFT");
        assert!(rejected.body.message.contains("admin_usernames"));
        assert!(!rejected.body.message.contains("restore-drift@example.test"));
        assert!(!target.exists());

        let result = restore_instance_with_runtime_policy_drift(
            drifted_config,
            &archive,
            &key_path,
            &target,
            true,
        )
        .await
        .unwrap();
        let generation = result.generation;
        assert_eq!(
            result.accepted_runtime_policy_drift_fields,
            vec!["admin_usernames".to_owned()]
        );
        assert_ne!(generation, old_generation);
        let source_generation: String =
            sqlx::query_scalar("SELECT generation FROM instance_meta WHERE id=1")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(source_generation, old_generation);
        let source_object: (Vec<u8>, i64) =
            sqlx::query_as("SELECT bytes,size FROM blob_objects WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(source_object, (vec![1, 2, 3, 4], 4));
        assert!(!target.join("database.sqlite").exists());
        assert_eq!(
            fs::metadata(&target).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            secure_file::read_private_key(&target.join("instance-ed25519.key"))
                .unwrap()
                .len(),
            32
        );
        assert_eq!(
            secure_file::read_private_key(&target.join("auth-rate-limit.key")).unwrap(),
            *original_rate_key
        );

        let restored = state_at(&target).await;
        assert_eq!(restored.instance.generation, generation);
        let stored_generation: String =
            sqlx::query_scalar("SELECT generation FROM instance_meta WHERE id=1")
                .fetch_one(&restored.db)
                .await
                .unwrap();
        assert_eq!(stored_generation, generation);
        let object: (Vec<u8>, i64) =
            sqlx::query_as("SELECT bytes,size FROM blob_objects WHERE vault_id=?")
                .bind(vault)
                .fetch_one(&restored.db)
                .await
                .unwrap();
        assert_eq!(object, (vec![1, 2, 3, 4], 4));
        let revoked: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE user_id=?")
                .bind(&user)
                .fetch_one(&restored.db)
                .await
                .unwrap();
        assert!(revoked.is_some());
        let (
            restored_seed,
            enabled_at,
            last_totp_step,
            pending_seed,
            pending_expiry,
            pending_version,
        ): (
            String,
            Option<i64>,
            i64,
            Option<String>,
            Option<i64>,
            Option<i64>,
        ) = sqlx::query_as(
            "SELECT totp_seed_envelope,enabled_at,last_totp_step,pending_seed_envelope, \
                 pending_expires_at,pending_credential_version FROM auth_mfa WHERE user_id=?",
        )
        .bind(&user)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(
            restored_seed, encrypted_seed,
            "keep the enrolled factor enabled"
        );
        assert!(enabled_at.is_some());
        assert!(last_totp_step > old_totp_step);
        assert!(
            last_totp_step >= chrono::Utc::now().timestamp().div_euclid(30) - 1,
            "restore advances the step marker to the current TOTP window"
        );
        assert_eq!(
            (pending_seed, pending_expiry, pending_version),
            (None, None, None)
        );
        let unused_codes: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM auth_mfa_recovery_codes WHERE user_id=? AND consumed_at IS NULL",
        )
        .bind(&user)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(
            unused_codes, 0,
            "saved recovery codes cannot be reactivated by rollback"
        );
        let remaining_challenges: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM auth_mfa_login_challenges WHERE user_id=?")
                .bind(&user)
                .fetch_one(&restored.db)
                .await
                .unwrap();
        assert_eq!(remaining_challenges, 0);
        let pending_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM auth_mfa WHERE user_id=?")
            .bind(&pending_user)
            .fetch_one(&restored.db)
            .await
            .unwrap();
        assert_eq!(
            pending_rows, 0,
            "discard pending enrollment from the snapshot"
        );
        let reset_audits: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='auth.mfa_state_reset_by_restore'",
        )
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(reset_audits, 1);
        assert!(
            sqlx::query("PRAGMA foreign_key_check")
                .fetch_all(&restored.db)
                .await
                .unwrap()
                .is_empty()
        );
        restored.db.close().await;
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn s3_object_backup_hydrates_self_contained_archive_and_fails_closed_on_damage() {
        let root = temp_root();
        let source = root.join("s3-active");
        let target = root.join("s3-restored");
        let archive = root.join("s3-instance.atb");
        let broken_archive = root.join("s3-broken.atb");
        let key_path = root.join("s3-backup.key");
        write_backup_key(&key_path);
        let state = state_at(&source).await;
        let (_, _, vault) = seed_instance(&state).await;
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq) VALUES(?,0)")
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        let auto_purge_record = Uuid::new_v4().to_string();
        let auto_purge_revision = Uuid::new_v4().to_string();
        let auto_purge_seq: i64 =
            sqlx::query_scalar("SELECT last_committed_seq+1 FROM vault_counters WHERE vault_id=?")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let auto_purge_created_at = chrono::Utc::now();
        let auto_purge_restore_until =
            (auto_purge_created_at + chrono::Duration::days(30)).to_rfc3339();
        let auto_purge_envelope = json!({"ciphertext":"archive-auto-purge-test"}).to_string();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=? WHERE vault_id=?")
            .bind(auto_purge_seq)
            .bind(&vault)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO record_versions( \
                 vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq, \
                 device_id,operation,created_at,restore_until \
             ) VALUES(?,?,?,NULL,?,'archive-auto-purge',?,'archive-device','delete',?,?)",
        )
        .bind(&vault)
        .bind(&auto_purge_record)
        .bind(&auto_purge_revision)
        .bind(&auto_purge_envelope)
        .bind(auto_purge_seq)
        .bind(auto_purge_created_at.to_rfc3339())
        .bind(&auto_purge_restore_until)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
             VALUES(?,?,?,1,?)",
        )
        .bind(&vault)
        .bind(&auto_purge_record)
        .bind(&auto_purge_revision)
        .bind(auto_purge_seq)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_graveyard( \
                 vault_id,record_id,deleted_revision,deleted_seq,auto_purge_enabled,auto_purge_revision \
             ) VALUES(?,?,?, ?,1,7)",
        )
        .bind(&vault)
        .bind(&auto_purge_record)
        .bind(&auto_purge_revision)
        .bind(auto_purge_seq)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "UPDATE record_auto_purge_scan_control SET \
             after_vault_id=?,server_generation=9,cursor_revision=41, \
             lease_token='archived-stale-lease',lease_expires_at='2099-01-01T00:00:00Z', \
             last_scan_status='failed',last_scan_started_at='2025-01-01T00:00:00Z', \
             last_scan_finished_at='2025-01-01T00:01:00Z',last_scan_candidates=7, \
             last_scan_purged=3,last_scan_not_due=2,last_scan_capability_blocked=1, \
             last_scan_conflict_blocked=1,last_scan_reference_blocked=1, \
             last_scan_stale_or_withdrawn=1 WHERE singleton=1",
        )
        .bind(&vault)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO record_auto_purge_vault_cursors( \
                 vault_id,after_record_id,high_water_record_id,pending_record_id, \
                 pending_deleted_revision_id,pending_deleted_seq,server_generation,updated_at \
             ) VALUES(?,NULL,?,?,?,?,9,'2025-01-01T00:00:00Z')",
        )
        .bind(&vault)
        .bind(&auto_purge_record)
        .bind(&auto_purge_record)
        .bind(&auto_purge_revision)
        .bind(auto_purge_seq)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES(?,?,'delete',?,?,?,?)",
        )
        .bind(&vault)
        .bind(auto_purge_seq)
        .bind(&auto_purge_record)
        .bind(&auto_purge_revision)
        .bind(&auto_purge_envelope)
        .bind(auto_purge_created_at.to_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
        let object_id: String =
            sqlx::query_scalar("SELECT object_id FROM blob_objects WHERE vault_id=? LIMIT 1")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let upload_id = Uuid::new_v4().to_string();
        let fixture = crate::object_store::test_support::S3Fixture::start().await;
        let store = fixture.store();
        let object_bytes = b"opaque encrypted user object";
        let digest = crate::sha256_hex(object_bytes);
        let (storage_key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object_id, &upload_id)
            .unwrap();
        store
            .put_immutable(
                &storage_key,
                object_bytes,
                object_bytes.len() as i64,
                &digest,
            )
            .await
            .unwrap();
        sqlx::query(
            "UPDATE blob_objects SET bytes=X'',size=?,sha256=?,storage_backend='s3',storage_key=?,storage_store_id=? WHERE vault_id=? AND object_id=?",
        )
        .bind(object_bytes.len() as i64)
        .bind(&digest)
        .bind(&storage_key)
        .bind(&store_id)
        .bind(&vault)
        .bind(&object_id)
        .execute(&state.db)
        .await
        .unwrap();

        fixture
            .overwrite(&storage_key, b"tampered encrypted object".to_vec(), &digest)
            .await;
        let damaged = backup_instance_from_pool_with_object_store(
            &state.db,
            &state.config,
            &broken_archive,
            &key_path,
            &store,
        )
        .await
        .unwrap_err();
        assert_eq!(damaged.body.code, "OBJECT_INTEGRITY_MISMATCH");
        assert!(!broken_archive.exists());
        let live: (Vec<u8>, String) = sqlx::query_as(
            "SELECT bytes,storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(live, (Vec::new(), "s3".to_owned()));

        fixture
            .overwrite(&storage_key, object_bytes.to_vec(), &digest)
            .await;
        backup_instance_from_pool_with_object_store(
            &state.db,
            &state.config,
            &archive,
            &key_path,
            &store,
        )
        .await
        .unwrap();
        restore_instance_to_new_directory(
            test_config(source.clone()),
            &archive,
            &key_path,
            &target,
        )
        .await
        .unwrap();
        let restored = state_at(&target).await;
        let restored_object: (Vec<u8>, String, Option<String>) = sqlx::query_as(
            "SELECT bytes,storage_backend,storage_key FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object_id)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(
            restored_object,
            (object_bytes.to_vec(), "sqlite".to_owned(), None)
        );
        let restored_auto_purge_policy: (i64, i64) = sqlx::query_as(
            "SELECT auto_purge_enabled,auto_purge_revision FROM record_graveyard \
             WHERE vault_id=? AND record_id=?",
        )
        .bind(&vault)
        .bind(&auto_purge_record)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(restored_auto_purge_policy, (0, 8));
        let restored_scan_control_reset: bool = sqlx::query_scalar(
            "SELECT after_vault_id IS NULL AND server_generation=1 AND cursor_revision=42 \
               AND lease_token IS NULL AND lease_expires_at IS NULL \
               AND last_scan_status='never' AND last_scan_started_at IS NULL \
               AND last_scan_finished_at IS NULL AND last_scan_candidates=0 \
               AND last_scan_purged=0 AND last_scan_not_due=0 \
               AND last_scan_capability_blocked=0 AND last_scan_conflict_blocked=0 \
               AND last_scan_reference_blocked=0 AND last_scan_stale_or_withdrawn=0 \
             FROM record_auto_purge_scan_control WHERE singleton=1",
        )
        .fetch_one(&restored.db)
        .await
        .unwrap();
        let restored_cursor_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM record_auto_purge_vault_cursors")
                .fetch_one(&restored.db)
                .await
                .unwrap();
        assert!(restored_scan_control_reset);
        assert_eq!(restored_cursor_count, 0);

        sqlx::query(
            "UPDATE blob_objects SET storage_state='deleting' WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object_id)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault)
            .bind("invalid-delete-state-revision")
            .bind(&object_id)
            .execute(&state.db)
            .await
            .unwrap();
        let invalid_delete_archive = root.join("s3-invalid-delete-state.atb");
        let invalid_delete = backup_instance_from_pool_with_object_store(
            &state.db,
            &state.config,
            &invalid_delete_archive,
            &key_path,
            &store,
        )
        .await
        .unwrap_err();
        assert_eq!(invalid_delete.body.code, "OBJECT_INTEGRITY_MISMATCH");
        assert!(!invalid_delete_archive.exists());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn filesystem_object_backup_hydrates_self_contained_archive_and_restores_offline() {
        use std::os::unix::fs::PermissionsExt;

        let root = temp_root();
        let source = root.join("filesystem-active");
        let target = root.join("filesystem-restored");
        let archive = root.join("filesystem-instance.atb");
        let damaged_archive = root.join("filesystem-damaged.atb");
        let key_path = root.join("filesystem-backup.key");
        let object_root = root.join("filesystem-objects");
        fs::create_dir(&object_root).unwrap();
        fs::set_permissions(&object_root, fs::Permissions::from_mode(0o700)).unwrap();
        write_backup_key(&key_path);
        let state = state_at(&source).await;
        let (_, _, vault) = seed_instance(&state).await;
        let object_id: String =
            sqlx::query_scalar("SELECT object_id FROM blob_objects WHERE vault_id=? LIMIT 1")
                .bind(&vault)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let upload_id = Uuid::new_v4().to_string();
        let store = crate::object_store::ObjectStore::filesystem_for_test(&object_root);
        let object_bytes = b"opaque encrypted filesystem object";
        let digest = crate::sha256_hex(object_bytes);
        let (storage_key, store_id) = store
            .object_key(&state.instance.instance_id, &vault, &object_id, &upload_id)
            .unwrap();
        store
            .put_immutable(
                &storage_key,
                object_bytes,
                object_bytes.len() as i64,
                &digest,
            )
            .await
            .unwrap();
        sqlx::query(
            "UPDATE blob_objects SET bytes=X'',size=?,sha256=?,storage_backend='filesystem',storage_key=?,storage_store_id=? WHERE vault_id=? AND object_id=?",
        )
        .bind(object_bytes.len() as i64)
        .bind(&digest)
        .bind(&storage_key)
        .bind(&store_id)
        .bind(&vault)
        .bind(&object_id)
        .execute(&state.db)
        .await
        .unwrap();

        fs::write(object_root.join(&storage_key), b"tampered object bytes").unwrap();
        let damaged = backup_instance_from_pool_with_object_store(
            &state.db,
            &state.config,
            &damaged_archive,
            &key_path,
            &store,
        )
        .await
        .unwrap_err();
        assert_eq!(damaged.body.code, "OBJECT_INTEGRITY_MISMATCH");
        assert!(!damaged_archive.exists());
        let live: (Vec<u8>, String) = sqlx::query_as(
            "SELECT bytes,storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(live, (Vec::new(), "filesystem".to_owned()));

        fs::write(object_root.join(&storage_key), object_bytes).unwrap();
        backup_instance_from_pool_with_object_store(
            &state.db,
            &state.config,
            &archive,
            &key_path,
            &store,
        )
        .await
        .unwrap();
        restore_instance_to_new_directory(
            test_config(source.clone()),
            &archive,
            &key_path,
            &target,
        )
        .await
        .unwrap();
        let restored = state_at(&target).await;
        let restored_object: (Vec<u8>, String, Option<String>) = sqlx::query_as(
            "SELECT bytes,storage_backend,storage_key FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault)
        .bind(&object_id)
        .fetch_one(&restored.db)
        .await
        .unwrap();
        assert_eq!(
            restored_object,
            (object_bytes.to_vec(), "sqlite".to_owned(), None)
        );
        restored.db.close().await;
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    fn custom_archive(
        archive: &Path,
        key: &[u8; 32],
        files: Vec<(String, Vec<u8>)>,
        corrupt_first_digest: bool,
    ) {
        custom_archive_with_runtime_policy(
            archive,
            key,
            files,
            corrupt_first_digest,
            9,
            runtime_policy_summary(&test_config(PathBuf::new())),
        );
    }

    fn custom_archive_with_runtime_policy(
        archive: &Path,
        key: &[u8; 32],
        files: Vec<(String, Vec<u8>)>,
        corrupt_first_digest: bool,
        migration_version: i64,
        runtime_policy: RuntimePolicySummary,
    ) {
        let mut manifest_files = Vec::new();
        for (index, (name, bytes)) in files.iter().enumerate() {
            let digest = if corrupt_first_digest && index == 0 {
                "00".repeat(32)
            } else {
                hex::encode(Sha256::digest(bytes))
            };
            manifest_files.push(BackupFile {
                name: name.clone(),
                size: bytes.len() as u64,
                sha256: digest,
            });
        }
        let manifest = BackupManifest {
            format_version: FORMAT_VERSION,
            app_version: env!("CARGO_PKG_VERSION").to_owned(),
            created_at: "2026-01-01T00:00:00Z".to_owned(),
            database_engine: "sqlite".to_owned(),
            journal_mode: "wal".to_owned(),
            migration_version,
            runtime_policy,
            files: manifest_files,
        };
        let manifest_bytes = serde_jcs::to_vec(&manifest).unwrap();
        let manifest_hash: [u8; 32] = Sha256::digest(&manifest_bytes).into();
        let mut prefix = [0; 16];
        rand::thread_rng().fill_bytes(&mut prefix);
        let cipher = XChaCha20Poly1305::new_from_slice(key).unwrap();
        let mut encrypted_manifest = manifest_bytes;
        cipher
            .encrypt_in_place(
                XNonce::from_slice(&nonce(&prefix, 0)),
                MANIFEST_AAD,
                &mut encrypted_manifest,
            )
            .unwrap();
        let mut file = create_private_file(archive).unwrap();
        file.write_all(MAGIC).unwrap();
        file.write_all(&FORMAT_VERSION.to_be_bytes()).unwrap();
        file.write_all(&prefix).unwrap();
        file.write_all(&(encrypted_manifest.len() as u32).to_be_bytes())
            .unwrap();
        file.write_all(&encrypted_manifest).unwrap();
        let mut sequence = 1_u64;
        for (file_index, (_, file_bytes)) in files.iter().enumerate() {
            for (chunk_index, chunk) in file_bytes.chunks(CHUNK_BYTES).enumerate() {
                let mut ciphertext = chunk.to_vec();
                let aad = file_aad(
                    &manifest_hash,
                    file_index as u32,
                    chunk_index as u64,
                    chunk.len() as u32,
                );
                cipher
                    .encrypt_in_place(
                        XNonce::from_slice(&nonce(&prefix, sequence)),
                        &aad,
                        &mut ciphertext,
                    )
                    .unwrap();
                file.write_all(&ciphertext).unwrap();
                sequence += 1;
            }
        }
        file.sync_all().unwrap();
    }

    #[tokio::test]
    async fn invalid_archives_never_create_or_mutate_restore_target() {
        let root = temp_root();
        let source = root.join("active");
        let state = state_at(&source).await;
        seed_instance(&state).await;
        checkpoint_and_close(&state).await;
        drop(state);
        let source_db_hash = hash_file(&source.join("atermius.db")).unwrap().1;
        let key_path = root.join("backup.key");
        let key = write_backup_key(&key_path);

        for case in ["checksum", "truncated", "unknown-file"] {
            let archive = root.join(format!("{case}.atb"));
            let valid_files = vec![
                ("auth-rate-limit.key".to_owned(), vec![0x51; 32]),
                (
                    "database.sqlite".to_owned(),
                    fs::read(source.join("atermius.db")).unwrap(),
                ),
                (
                    "instance-ed25519.key".to_owned(),
                    fs::read(source.join("instance-ed25519.key")).unwrap(),
                ),
            ];
            match case {
                "unknown-file" => custom_archive(
                    &archive,
                    &key,
                    vec![("unexpected.txt".to_owned(), b"no".to_vec())],
                    false,
                ),
                "checksum" => custom_archive(&archive, &key, valid_files, true),
                _ => custom_archive(&archive, &key, valid_files, false),
            }
            if case == "truncated" {
                let mut bytes = fs::read(&archive).unwrap();
                bytes.pop();
                fs::write(&archive, bytes).unwrap();
                set_private_file_mode(&archive).unwrap();
            }
            let target = root.join(format!("restore-{case}"));
            assert!(
                restore_instance_to_new_directory(
                    test_config(source.clone()),
                    &archive,
                    &key_path,
                    &target,
                )
                .await
                .is_err(),
                "{case} archive unexpectedly restored"
            );
            assert!(!target.exists(), "{case} archive published a target");
            assert_eq!(
                hash_file(&source.join("atermius.db")).unwrap().1,
                source_db_hash
            );
        }

        let valid_archive = root.join("valid-for-boundary-checks.atb");
        custom_archive(
            &valid_archive,
            &key,
            vec![
                (
                    "auth-rate-limit.key".to_owned(),
                    fs::read(source.join("auth-rate-limit.key")).unwrap(),
                ),
                (
                    "database.sqlite".to_owned(),
                    fs::read(source.join("atermius.db")).unwrap(),
                ),
                (
                    "instance-ed25519.key".to_owned(),
                    fs::read(source.join("instance-ed25519.key")).unwrap(),
                ),
            ],
            false,
        );

        let archive_inside_source = source.join("archive-inside-active-data.atb");
        fs::copy(&valid_archive, &archive_inside_source).unwrap();
        let contained_archive_target = root.join("restore-from-contained-archive");
        assert!(
            restore_instance_to_new_directory(
                test_config(source.clone()),
                &archive_inside_source,
                &key_path,
                &contained_archive_target,
            )
            .await
            .is_err(),
            "restore must reject archives inside the active data directory"
        );
        assert!(!contained_archive_target.exists());
        fs::remove_file(&archive_inside_source).unwrap();

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            let unsafe_parent = root.join("unsafe-restore-parent");
            fs::create_dir(&unsafe_parent).unwrap();
            fs::set_permissions(&unsafe_parent, fs::Permissions::from_mode(0o777)).unwrap();
            let unsafe_target = unsafe_parent.join("restore-target");
            assert!(
                restore_instance_to_new_directory(
                    test_config(source.clone()),
                    &valid_archive,
                    &key_path,
                    &unsafe_target,
                )
                .await
                .is_err(),
                "restore must reject a group/world-writable non-sticky target parent"
            );
            assert!(!unsafe_target.exists());
            assert_eq!(fs::read_dir(&unsafe_parent).unwrap().count(), 0);
        }

        let running_lock = acquire_runtime_lock(&source).unwrap();
        let running_target = root.join("restore-while-running");
        assert!(
            restore_instance_to_new_directory(
                test_config(source.clone()),
                &valid_archive,
                &key_path,
                &running_target,
            )
            .await
            .is_err(),
            "restore must fail while the current instance lock is held"
        );
        assert!(!running_target.exists());
        drop(running_lock);

        let wrong_key_path = root.join("wrong.key");
        write_private_file(&wrong_key_path, &[0x52; 32]).unwrap();
        let wrong_key_target = root.join("restore-wrong-key");
        assert!(
            restore_instance_to_new_directory(
                test_config(source.clone()),
                &valid_archive,
                &wrong_key_path,
                &wrong_key_target,
            )
            .await
            .is_err()
        );
        assert!(!wrong_key_target.exists());

        let existing_target = root.join("already-present");
        fs::create_dir(&existing_target).unwrap();
        let marker = existing_target.join("operator-data.txt");
        fs::write(&marker, b"keep existing target unchanged").unwrap();
        assert!(
            restore_instance_to_new_directory(
                test_config(source.clone()),
                &valid_archive,
                &key_path,
                &existing_target,
            )
            .await
            .is_err()
        );
        assert_eq!(fs::read(marker).unwrap(), b"keep existing target unchanged");
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn legacy_runtime_policy_archive_requires_explicit_override() {
        let root = temp_root();
        let source = root.join("active");
        let target = root.join("restored-legacy");
        let archive = root.join("legacy-policy.atb");
        let key_path = root.join("backup.key");
        let key = write_backup_key(&key_path);
        let state = state_at(&source).await;
        seed_instance(&state).await;
        let migration_version: i64 =
            sqlx::query_scalar("SELECT MAX(version) FROM _sqlx_migrations WHERE success=1")
                .fetch_one(&state.db)
                .await
                .unwrap();
        let mut legacy_policy = runtime_policy_summary(&state.config);
        legacy_policy.policy_version = 0;
        legacy_policy.admin_usernames.clear();
        legacy_policy.public_origin = None;
        legacy_policy.web_dir = None;
        checkpoint_and_close(&state).await;

        custom_archive_with_runtime_policy(
            &archive,
            &key,
            vec![
                (
                    "auth-rate-limit.key".to_owned(),
                    fs::read(source.join("auth-rate-limit.key")).unwrap(),
                ),
                (
                    "database.sqlite".to_owned(),
                    fs::read(source.join("atermius.db")).unwrap(),
                ),
                (
                    "instance-ed25519.key".to_owned(),
                    fs::read(source.join("instance-ed25519.key")).unwrap(),
                ),
            ],
            false,
            migration_version,
            legacy_policy,
        );

        let mut target_config = test_config(source.clone());
        target_config.admin_usernames = vec!["legacy-policy-review@example.test".to_owned()];
        let rejected = restore_instance_with_runtime_policy_drift(
            target_config.clone(),
            &archive,
            &key_path,
            &target,
            false,
        )
        .await
        .unwrap_err();
        assert_eq!(rejected.body.code, "RUNTIME_POLICY_DRIFT");
        assert!(rejected.body.message.contains("runtime_policy_version"));
        assert!(rejected.body.message.contains("admin_usernames"));
        assert!(
            !rejected
                .body
                .message
                .contains("legacy-policy-review@example.test")
        );
        assert!(!target.exists());

        let accepted = restore_instance_with_runtime_policy_drift(
            target_config,
            &archive,
            &key_path,
            &target,
            true,
        )
        .await
        .unwrap();
        assert_eq!(accepted.generation.len(), 36);
        assert_eq!(
            accepted.accepted_runtime_policy_drift_fields,
            vec![
                "runtime_policy_version".to_owned(),
                "admin_usernames".to_owned()
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn backup_key_and_archive_paths_cannot_escape_into_data_dir_aliases() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let data_dir = root.join("instance");
        secure_file::create_private_data_dir(&data_dir).unwrap();
        assert!(ensure_path_outside_data_dir(&data_dir, &data_dir.join("backup.key")).is_err());
        assert!(ensure_path_outside_data_dir(&data_dir, &data_dir.join("backup.atb")).is_err());

        let alias = root.join("instance-alias");
        symlink(&data_dir, &alias).unwrap();
        assert!(ensure_path_outside_data_dir(&data_dir, &alias.join("backup.key")).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn configured_admin_backup_requires_private_external_settings() {
        let root = temp_root();
        let data_dir = root.join("instance");
        let archive_dir = root.join("archives");
        secure_file::create_private_data_dir(&data_dir).unwrap();
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        write_backup_key(&key_file);
        let mut config = test_config(data_dir.clone());

        assert!(configured_backup_paths(&config).is_err());
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file.clone());
        let settings = configured_backup_paths(&config).unwrap();
        assert_eq!(settings.archive_dir, archive_dir.canonicalize().unwrap());
        assert_eq!(settings.key_file, key_file);

        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(configured_backup_paths(&config).is_err());
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();

        fs::set_permissions(&key_file, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(configured_backup_paths(&config).is_err());
        fs::set_permissions(&key_file, fs::Permissions::from_mode(0o600)).unwrap();

        let inside_dir = data_dir.join("inside");
        fs::create_dir(&inside_dir).unwrap();
        fs::set_permissions(&inside_dir, fs::Permissions::from_mode(0o700)).unwrap();
        config.backup_archive_dir = Some(inside_dir);
        assert!(configured_backup_paths(&config).is_err());
        config.backup_archive_dir = Some(archive_dir);

        let inside_key = data_dir.join("inside.key");
        write_backup_key(&inside_key);
        config.backup_key_file = Some(inside_key);
        assert!(configured_backup_paths(&config).is_err());
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn pg_backup_status_size_accepts_only_exact_private_regular_archive() {
        use std::os::unix::fs::symlink;

        let root = temp_root();
        let data_dir = root.join("instance");
        let archive_dir = root.join("archives");
        secure_file::create_private_data_dir(&data_dir).unwrap();
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        write_backup_key(&key_file);
        let mut config = test_config(data_dir);
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file);

        let timestamp = "20261010T050000.000Z";
        let job_id = Uuid::new_v4().to_string();
        let archive = archive_dir.join(format!("atermius-backup-{timestamp}-{job_id}.atb"));
        fs::write(&archive, b"safe archive bytes").unwrap();
        fs::set_permissions(&archive, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            pg_backup_archive_bytes_for_status(&config, timestamp, &job_id),
            Some(18)
        );
        assert_eq!(
            pg_backup_archive_bytes_for_status(&config, "../atermius.db", &job_id),
            None
        );
        assert_eq!(
            pg_backup_archive_bytes_for_status(&config, timestamp, &Uuid::new_v4().to_string()),
            None
        );

        let symlink_job_id = Uuid::new_v4().to_string();
        let symlink_path =
            archive_dir.join(format!("atermius-backup-{timestamp}-{symlink_job_id}.atb"));
        symlink(&archive, &symlink_path).unwrap();
        assert_eq!(
            pg_backup_archive_bytes_for_status(&config, timestamp, &symlink_job_id),
            None
        );
        fs::remove_file(archive).unwrap();
        fs::remove_file(symlink_path).unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn configured_admin_backup_shares_maintenance_lock_and_records_failure() {
        let root = temp_root();
        let source = root.join("active");
        let archive_dir = root.join("archives");
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        write_backup_key(&key_file);
        secure_file::create_private_data_dir(&source).unwrap();
        let mut config = test_config(source.clone());
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file);
        let state = open_state(&sqlite_url(&source.join("atermius.db")), config)
            .await
            .unwrap();

        let _maintenance_lock = crate::acquire_maintenance_run_lock(&source).unwrap();
        let error = run_configured_admin_backup(&state, &Uuid::new_v4().to_string())
            .await
            .unwrap_err();
        assert_eq!(error.body.code, "MAINTENANCE_ALREADY_RUNNING");
        assert_eq!(fs::read_dir(&archive_dir).unwrap().count(), 0);
        let status: serde_json::Value =
            serde_json::from_slice(&fs::read(source.join("backup-status.json")).unwrap()).unwrap();
        assert_eq!(status["result"], "failed");
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn configured_admin_backup_success_is_archive_success_even_if_sidecar_write_fails() {
        let root = temp_root();
        let source = root.join("active");
        let archive_dir = root.join("archives");
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        write_backup_key(&key_file);
        secure_file::create_private_data_dir(&source).unwrap();
        let mut config = test_config(source.clone());
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file.clone());
        let state = open_state(&sqlite_url(&source.join("atermius.db")), config)
            .await
            .unwrap();
        // Make only the status-sidecar target unwritable as a file. The archive
        // is the durable backup result and must not be retried or reported as
        // failed just because this secondary metadata update was unavailable.
        fs::create_dir(source.join("backup-status.json")).unwrap();

        let job_id = Uuid::new_v4().to_string();
        let requested_at = crate::now_rfc3339();
        sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,
                requested_at,started_at
             ) VALUES(?,?,?,?, 'backup','running',?,?)",
        )
        .bind(&job_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(&requested_at)
        .bind(&requested_at)
        .execute(&state.db)
        .await
        .unwrap();
        assert!(run_configured_admin_backup(&state, &job_id).await.is_ok());
        let archives: Vec<PathBuf> = fs::read_dir(&archive_dir)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect();
        assert_eq!(archives.len(), 1);
        assert!(
            archives[0]
                .file_name()
                .unwrap()
                .to_string_lossy()
                .contains(&job_id)
        );
        assert!(
            verify_instance_backup(&source, &archives[0], &key_file)
                .await
                .is_ok()
        );
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn manual_backup_holds_replication_claim_until_archive_metadata_is_persisted() {
        let root = temp_root();
        let source = root.join("active");
        let archive_dir = root.join("archives");
        fs::create_dir(&archive_dir).unwrap();
        fs::set_permissions(&archive_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let key_file = root.join("operator.key");
        write_backup_key(&key_file);
        let credentials_file = root.join("replica-credentials.json");
        fs::write(
            &credentials_file,
            br#"{"access_key_id":"fixture-access","secret_access_key":"fixture-secret"}"#,
        )
        .unwrap();
        fs::set_permissions(&credentials_file, fs::Permissions::from_mode(0o600)).unwrap();

        secure_file::create_private_data_dir(&source).unwrap();
        let mut config = test_config(source.clone());
        config.backup_archive_dir = Some(archive_dir.clone());
        config.backup_key_file = Some(key_file.clone());
        config.backup_replication_env = crate::BackupReplicationEnv {
            bucket: Some("fixture-bucket".into()),
            region: Some("us-east-1".into()),
            credentials_file: Some(credentials_file.clone().into_os_string()),
            endpoint_url: Some("http://127.0.0.1:9".into()),
            prefix: Some("fixture".into()),
        };
        let state = open_state(&sqlite_url(&source.join("atermius.db")), config)
            .await
            .unwrap();
        let job_id = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        sqlx::query(
            "INSERT INTO instance_admin_jobs(
                job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,
                requested_at,started_at
             ) VALUES(?,?,?,?, 'backup','running',?,?)",
        )
        .bind(&job_id)
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind(&now)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();

        let gate = std::sync::Arc::new(crate::recovery::TestPause::new());
        let _release_gate = crate::recovery::ReleasePauseOnDrop::new(gate.clone());
        let backup_state = state.clone();
        let backup_gate = gate.clone();
        let backup_job_id = job_id.clone();
        let backup_job = tokio::spawn(async move {
            run_configured_admin_backup_locked(&backup_state, &backup_job_id, Some(backup_gate))
                .await
        });
        gate.wait_until_reached().await;

        let registered_state: String = sqlx::query_scalar(
            "SELECT status FROM instance_backup_replications WHERE archive_id=?",
        )
        .bind(&job_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(registered_state, "pending_archive");

        // A worker iteration started while the backup is deliberately paused
        // after registration must block on the same shared maintenance lock.
        // Remove the credentials before releasing it so its post-backup claim
        // fails safely without contacting any network endpoint.
        fs::remove_file(&credentials_file).unwrap();
        let worker_state = state.clone();
        let mut worker =
            tokio::spawn(
                async move { crate::backup_replication::run_one_due(&worker_state).await },
            );
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(50), &mut worker)
                .await
                .is_err()
        );
        let attempts_while_paused: i64 = sqlx::query_scalar(
            "SELECT attempt_count FROM instance_backup_replications WHERE archive_id=?",
        )
        .bind(&job_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(attempts_while_paused, 0);

        gate.release();
        backup_job.await.unwrap().unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_secs(3), &mut worker)
                .await
                .expect("replication worker remained blocked after backup completion")
                .unwrap()
                .unwrap()
        );

        let (timestamp, status, attempts, recorded_bytes, recorded_sha256): (
            String,
            String,
            i64,
            i64,
            String,
        ) = sqlx::query_as(
            "SELECT j.archive_timestamp,r.status,r.attempt_count,r.archive_bytes,r.archive_sha256 \
             FROM instance_admin_jobs j JOIN instance_backup_replications r ON r.archive_id=j.job_id \
             WHERE j.job_id=?",
        )
        .bind(&job_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let archive_path = archive_dir.join(format!("atermius-backup-{timestamp}-{job_id}.atb"));
        let (archive_file, actual_sha256) = open_and_hash_generated_archive(&archive_path).unwrap();
        assert_eq!(status, "retry_wait");
        assert_eq!(attempts, 1);
        assert_eq!(
            recorded_bytes as u64,
            archive_file.metadata().unwrap().len()
        );
        assert_eq!(recorded_sha256, actual_sha256);

        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn failed_backup_does_not_leave_archive_temporary_files() {
        let root = temp_root();
        let source = root.join("active");
        let state = state_at(&source).await;
        seed_instance(&state).await;
        let key_path = root.join("backup.key");
        write_backup_key(&key_path);
        let archive = root.join("already-exists.atb");
        fs::write(&archive, b"existing archive must not be overwritten").unwrap();

        assert!(
            backup_instance_from_pool(&state.db, &state.config, &archive, &key_path)
                .await
                .is_err()
        );
        let temporary_files = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(".already-exists.atb.")
            })
            .count();
        assert_eq!(temporary_files, 0);
        assert_eq!(
            fs::read(&archive).unwrap(),
            b"existing archive must not be overwritten"
        );
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn online_snapshot_does_not_copy_uncommitted_wal_transaction() {
        let root = temp_root();
        let source = root.join("active");
        let state = state_at(&source).await;
        let key_path = root.join("backup.key");
        write_backup_key(&key_path);
        sqlx::query("CREATE TABLE backup_atomicity_probe(a INTEGER PRIMARY KEY,b INTEGER)")
            .execute(&state.db)
            .await
            .unwrap();
        let mut tx = state.db.begin().await.unwrap();
        sqlx::query("INSERT INTO backup_atomicity_probe(a,b) VALUES(1,2)")
            .execute(&mut *tx)
            .await
            .unwrap();
        let archive = root.join("during-wal-write.atb");
        backup_instance_from_pool(&state.db, &state.config, &archive, &key_path)
            .await
            .unwrap();
        tx.rollback().await.unwrap();

        let snapshot_dir = create_private_temp_dir(&root, "snapshot-test").unwrap();
        let manifest = read_encrypted_archive(
            open_private_archive(&archive).unwrap(),
            &[0x51; 32],
            &snapshot_dir.0,
        )
        .unwrap();
        assert_eq!(manifest.files.len(), ALLOWED_FILES.len());
        let snapshot = snapshot_dir.0.join("atermius.db");
        let options = SqliteConnectOptions::new()
            .filename(snapshot)
            .read_only(true);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM backup_atomicity_probe")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(count, 0);
        pool.close().await;
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn scheduled_backup_interval_is_strict_and_missed_slots_coalesce() {
        assert_eq!(backup_interval_seconds(1).unwrap(), 3_600);
        assert_eq!(backup_interval_seconds(720).unwrap(), 2_592_000);
        assert_eq!(
            backup_interval_seconds(0).unwrap_err().body.code,
            "INVALID_BACKUP_INTERVAL"
        );
        assert_eq!(
            backup_interval_seconds(721).unwrap_err().body.code,
            "INVALID_BACKUP_INTERVAL"
        );

        let interval = 3_600;
        let due = 1_000;
        assert_eq!(
            next_scheduled_backup_due(due, interval, due).unwrap(),
            4_600
        );
        // A long outage produces one immediate occurrence and advances to the
        // first future slot rather than replaying every missed period.
        assert_eq!(
            next_scheduled_backup_due(due, interval, 10_000).unwrap(),
            11_800
        );
    }

    #[tokio::test]
    async fn scheduled_backup_migration_enforces_singleton_cadence_and_unique_active_slot() {
        let root = temp_root();
        let data_dir = root.join("active");
        let state = state_at(&data_dir).await;
        let default_schedule = sqlx::query(
            "SELECT schedule_id,interval_hours,next_run_at FROM instance_backup_schedule",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(default_schedule.get::<i64, _>("schedule_id"), 1);
        assert_eq!(
            default_schedule.get::<Option<i64>, _>("interval_hours"),
            None
        );
        assert_eq!(default_schedule.get::<Option<i64>, _>("next_run_at"), None);
        assert!(sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=0,next_run_at=1 WHERE schedule_id=1",
        )
        .execute(&state.db)
        .await
        .is_err());
        assert!(sqlx::query(
            "INSERT INTO instance_backup_schedule(schedule_id,interval_hours,next_run_at) VALUES(2,1,1)",
        )
        .execute(&state.db)
        .await
        .is_err());

        let first_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(run_id,scheduled_for,started_at,status) \
             VALUES(?,100,100,'running')",
        )
        .bind(&first_id)
        .execute(&state.db)
        .await
        .unwrap();
        assert!(sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(run_id,scheduled_for,started_at,status) \
             VALUES(?,200,200,'running')",
        )
        .bind(Uuid::new_v4().to_string())
        .execute(&state.db)
        .await
        .is_err());
        sqlx::query(
            "UPDATE instance_scheduled_backup_runs SET status='interrupted',finished_at=101,result_code='interrupted' WHERE run_id=?",
        )
        .bind(&first_id)
        .execute(&state.db)
        .await
        .unwrap();
        assert!(sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(run_id,scheduled_for,started_at,status) \
             VALUES(?,100,200,'running')",
        )
        .bind(Uuid::new_v4().to_string())
        .execute(&state.db)
        .await
        .is_err());
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn scheduled_backup_claim_advances_once_and_does_not_consume_slot_while_admin_job_active()
    {
        let root = temp_root();
        let data_dir = root.join("active");
        let state = state_at(&data_dir).await;
        let now = chrono::Utc::now().timestamp();
        let due = now - 7_200;
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=1,next_run_at=? WHERE schedule_id=1",
        )
        .bind(due)
        .execute(&state.db)
        .await
        .unwrap();

        let claim = claim_due_scheduled_backup(&state).await.unwrap().unwrap();
        assert_eq!(claim.scheduled_for, due);
        let next_due: i64 = sqlx::query_scalar(
            "SELECT next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(next_due > now);
        assert!(claim_due_scheduled_backup(&state).await.unwrap().is_none());
        let run_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM instance_scheduled_backup_runs")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(run_count, 1);
        sqlx::query(
            "UPDATE instance_scheduled_backup_runs \
             SET status='interrupted',finished_at=?,result_code='interrupted' WHERE run_id=?",
        )
        .bind(now)
        .bind(&claim.run_id)
        .execute(&state.db)
        .await
        .unwrap();

        // Rewind to another due slot and prove a queued manual admin job leaves
        // the schedule untouched until the shared operation slot is available.
        let blocked_due = now - 3_600;
        sqlx::query("UPDATE instance_backup_schedule SET next_run_at=? WHERE schedule_id=1")
            .bind(blocked_due)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO instance_admin_jobs(job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,requested_at) \
             VALUES(?,?,? ,?,'maintenance','queued','2026-01-01T00:00:00.000Z')",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(Uuid::new_v4().to_string())
        .bind("scheduled-backup-test-user")
        .bind("scheduled-backup-test-device")
        .execute(&state.db)
        .await
        .unwrap();
        assert!(claim_due_scheduled_backup(&state).await.unwrap().is_none());
        let unchanged_due: i64 = sqlx::query_scalar(
            "SELECT next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(unchanged_due, blocked_due);
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn scheduled_backup_is_durable_single_shot_visible_and_retention_eligible() {
        let root = temp_root();
        let data_dir = root.join("active");
        let archive_dir = root.join("archives");
        let key_path = root.join("operator.key");
        let state =
            state_with_backup_retention(&data_dir, &archive_dir, &key_path, Some("1")).await;
        seed_instance(&state).await;
        let now = chrono::Utc::now().timestamp();
        let scheduled_for = now - 1;
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=1,next_run_at=? WHERE schedule_id=1",
        )
        .bind(scheduled_for)
        .execute(&state.db)
        .await
        .unwrap();

        assert!(run_due_scheduled_backup(&state).await.unwrap());
        assert!(!run_due_scheduled_backup(&state).await.unwrap());
        let run = sqlx::query(
            "SELECT run_id,scheduled_for,status,result_code,migration_version,archive_bytes \
             FROM instance_scheduled_backup_runs ORDER BY scheduled_for DESC LIMIT 1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        let run_id: String = run.get("run_id");
        assert_eq!(run.get::<String, _>("status"), "succeeded");
        assert_eq!(run.get::<String, _>("result_code"), "completed");
        assert!(run.get::<i64, _>("migration_version") >= 0);
        assert!(run.get::<i64, _>("archive_bytes") > 0);
        let timestamp = chrono::DateTime::<chrono::Utc>::from_timestamp(scheduled_for, 0)
            .unwrap()
            .format("%Y%m%dT%H%M%S%.3fZ")
            .to_string();
        let scheduled_archive = archive_dir.join(retention_archive_name(&timestamp, &run_id));
        assert!(scheduled_archive.is_file());
        let verification = verify_instance_backup(&data_dir, &scheduled_archive, &key_path)
            .await
            .unwrap();
        assert!(verification.file_count > 0);
        let status = crate::backup_status::read_status(&data_dir).unwrap();
        assert_eq!(
            serde_json::to_value(status).unwrap()["last_attempt"]["result"],
            "succeeded"
        );

        // A scheduled run ID is an eligible server archive. A later scheduled
        // archive survives while an older manual admin archive is pruned.
        let old_manual_id = Uuid::new_v4().to_string();
        insert_backup_job(&state, &old_manual_id).await;
        let old_manual_archive =
            write_retention_archive(&archive_dir, "20260101T000000.000Z", &old_manual_id);
        crate::run_maintenance(&state).await.unwrap();
        assert!(scheduled_archive.is_file());
        assert!(!old_manual_archive.exists());

        // A running run at restart becomes interrupted and is never replayed.
        let interrupted_id = Uuid::new_v4().to_string();
        let interrupted_due = now - 3_600;
        sqlx::query(
            "INSERT INTO instance_scheduled_backup_runs(run_id,scheduled_for,started_at,status) \
             VALUES(?,?,?,'running')",
        )
        .bind(&interrupted_id)
        .bind(interrupted_due)
        .bind(now - 10)
        .execute(&state.db)
        .await
        .unwrap();
        crate::backup::recover_interrupted_scheduled_backup_runs(&state)
            .await
            .unwrap();
        let interrupted_status: String =
            sqlx::query_scalar("SELECT status FROM instance_scheduled_backup_runs WHERE run_id=?")
                .bind(&interrupted_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(interrupted_status, "interrupted");
        assert!(!run_due_scheduled_backup(&state).await.unwrap());
        let run_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM instance_scheduled_backup_runs")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(run_count, 2);

        let sidecar = data_dir.join("backup-status.json");
        assert!(sidecar.is_file());
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn enabled_schedule_fails_closed_without_backup_paths_and_busy_lock_keeps_due_slot() {
        let root = temp_root();
        let data_dir = root.join("active");
        let state = state_at(&data_dir).await;
        let due = chrono::Utc::now().timestamp() - 1;
        sqlx::query(
            "UPDATE instance_backup_schedule SET interval_hours=1,next_run_at=? WHERE schedule_id=1",
        )
        .bind(due)
        .execute(&state.db)
        .await
        .unwrap();
        assert!(
            crate::backup::validate_backup_schedule_configuration(&state)
                .await
                .is_err()
        );

        let _external_lock = crate::acquire_maintenance_run_lock(&data_dir).unwrap();
        assert!(!run_due_scheduled_backup(&state).await.unwrap());
        let unchanged_due: i64 = sqlx::query_scalar(
            "SELECT next_run_at FROM instance_backup_schedule WHERE schedule_id=1",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(unchanged_due, due);
        let runs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_scheduled_backup_runs")
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(runs, 0);
        drop(_external_lock);
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }
}

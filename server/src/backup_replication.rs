//! Encrypted instance-archive replication to one operator-configured S3
//! compatible target. The module accepts no remote locations from HTTP input.

use std::{
    fs::{self, OpenOptions},
    io,
    path::{Path, PathBuf},
    time::Duration,
};

use aws_config::BehaviorVersion;
use aws_credential_types::Credentials;
use aws_sdk_s3::{
    Client,
    config::Region,
    error::ProvideErrorMetadata,
    types::{CompletedMultipartUpload, CompletedPart},
};
use aws_smithy_types::byte_stream::{ByteStream, Length};
use axum::http::StatusCode;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::Row;
use url::Url;
use uuid::Uuid;
use zeroize::Zeroize;

use crate::pg_backup_replication::PgBackupReplicationRepository;
use crate::{ApiError, AppState, Config};

const MAX_CREDENTIAL_FILE_BYTES: u64 = 8192;
const MAX_BUCKET_BYTES: usize = 63;
const MAX_PREFIX_BYTES: usize = 192;
const MAX_MULTIPART_PARTS: u64 = 9000;
// Keep a single request comfortably below the 5-minute request timeout on
// ordinary broadband links. Larger archives use bounded multipart parts.
const MAX_SINGLE_PUT_BYTES: u64 = 64 * 1024 * 1024;
const MIN_MULTIPART_BYTES: u64 = 64 * 1024 * 1024;
const MAX_MULTIPART_PART_BYTES: u64 = 128 * 1024 * 1024;
pub(crate) const REPLICATION_POLL_SECONDS: u64 = 15;
const MAX_RETRY_SECONDS: i64 = 6 * 60 * 60;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const PREFLIGHT_TIMEOUT: Duration = Duration::from_secs(15);
const MAX_TRANSFER_DURATION: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Debug, Clone)]
pub(crate) struct S3ReplicaSettings {
    bucket: String,
    region: String,
    credentials_file: PathBuf,
    endpoint_url: Option<String>,
    prefix: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ReplicationStatus {
    pub operation: &'static str,
    pub configured: bool,
    pub pending_count: i64,
    pub latest_attempt: Option<ReplicationAttemptDto>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ReplicationAttemptDto {
    pub archive_id: String,
    pub state: &'static str,
    pub attempted_at: String,
    pub completed_at: Option<String>,
    pub archive_bytes: Option<i64>,
    pub failure_category: Option<&'static str>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ReplicaPreflightStatus {
    pub check: &'static str,
    pub result: &'static str,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ArchiveSource {
    Local,
    Replica,
}

impl ArchiveSource {
    pub(crate) fn parse(value: &str) -> Result<Self, ApiError> {
        match value {
            "local" => Ok(Self::Local),
            "replica" => Ok(Self::Replica),
            _ => Err(ApiError::bad_request(
                "INVALID_JOB_REQUEST",
                "archive_source must be local or replica",
            )),
        }
    }

    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Replica => "replica",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CredentialsDocument {
    access_key_id: String,
    secret_access_key: String,
    #[serde(default)]
    session_token: Option<String>,
}

impl Drop for CredentialsDocument {
    fn drop(&mut self) {
        self.access_key_id.zeroize();
        self.secret_access_key.zeroize();
        if let Some(token) = &mut self.session_token {
            token.zeroize();
        }
    }
}

#[derive(Clone)]
struct S3Client {
    client: Client,
    bucket: String,
    prefix: Option<String>,
}

pub(crate) struct PrivateArchiveFile(pub(crate) PathBuf);

impl Drop for PrivateArchiveFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

pub(crate) fn configured_settings(config: &Config) -> Result<Option<S3ReplicaSettings>, ApiError> {
    let raw = &config.backup_replication_env;
    let core = [&raw.bucket, &raw.region, &raw.credentials_file];
    let supplied = core.iter().filter(|value| value.is_some()).count();
    let optional_supplied = raw.endpoint_url.is_some() || raw.prefix.is_some();
    if supplied == 0 && !optional_supplied {
        return Ok(None);
    }
    if supplied != core.len() {
        return Err(replication_not_configured());
    }
    crate::backup::configured_backup_paths(config).map_err(|_| replication_not_configured())?;

    let bucket = required_env_string(&raw.bucket, "bucket")?;
    let region = required_env_string(&raw.region, "region")?;
    let credentials_path = required_env_string(&raw.credentials_file, "credentials file")?;
    let endpoint_url = optional_env_string(&raw.endpoint_url, "endpoint URL")?;
    let prefix = optional_env_string(&raw.prefix, "prefix")?;
    validate_bucket(&bucket)?;
    validate_region(&region)?;
    if let Some(endpoint) = endpoint_url.as_deref() {
        validate_endpoint(endpoint)?;
    }
    if let Some(prefix) = prefix.as_deref() {
        validate_prefix(prefix)?;
    }
    let credentials_file = PathBuf::from(credentials_path);
    validate_secret_path(config, &credentials_file)?;
    Ok(Some(S3ReplicaSettings {
        bucket,
        region,
        credentials_file,
        endpoint_url,
        prefix,
    }))
}

pub(crate) fn validate_startup_configuration(config: &Config) -> Result<(), ApiError> {
    let Some(settings) = configured_settings(config)? else {
        return Ok(());
    };
    let _ = read_credentials(&settings.credentials_file)?;
    Ok(())
}

pub(crate) fn settings_configured(config: &Config) -> bool {
    configured_settings(config)
        .ok()
        .flatten()
        .is_some_and(|settings| read_credentials(&settings.credentials_file).is_ok())
}

/// Verify that the server-configured replica bucket responds to HeadBucket.
/// This checks bucket access only; it does not prove that object writes,
/// multipart uploads, restores, or other provider features will work.
pub(crate) async fn preflight_bucket_access(
    config: &Config,
) -> Result<ReplicaPreflightStatus, ApiError> {
    let settings = configured_settings(config)
        .ok()
        .flatten()
        .ok_or_else(replication_not_configured)?;
    let client = s3_client(&settings)
        .await
        .map_err(|_| replication_not_configured())?;

    let check = tokio::time::timeout(
        PREFLIGHT_TIMEOUT,
        client.client.head_bucket().bucket(&client.bucket).send(),
    )
    .await;
    match check {
        Ok(Ok(_)) => Ok(ReplicaPreflightStatus {
            check: "bucket_access",
            result: "passed",
        }),
        Ok(Err(_)) | Err(_) => Err(ApiError::new(
            StatusCode::BAD_GATEWAY,
            "BACKUP_REPLICATION_CHECK_FAILED",
            "configured backup bucket access could not be verified",
        )),
    }
}

pub(crate) fn replication_requested(config: &Config) -> bool {
    let env = &config.backup_replication_env;
    env.bucket.is_some()
        || env.region.is_some()
        || env.credentials_file.is_some()
        || env.endpoint_url.is_some()
        || env.prefix.is_some()
}

fn required_env_string(value: &Option<std::ffi::OsString>, name: &str) -> Result<String, ApiError> {
    let Some(value) = value else {
        return Err(replication_not_configured());
    };
    let value = value.to_str().ok_or_else(replication_not_configured)?;
    if value.is_empty()
        || value.trim() != value
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "BACKUP_REPLICATION_NOT_CONFIGURED",
            "encrypted backup replication configuration is invalid",
        ));
    }
    if value.len() > 1024 {
        return Err(replication_not_configured());
    }
    let _ = name;
    Ok(value.to_owned())
}

fn optional_env_string(
    value: &Option<std::ffi::OsString>,
    _name: &str,
) -> Result<Option<String>, ApiError> {
    value
        .as_ref()
        .map(|value| {
            let value = value.to_str().ok_or_else(replication_not_configured)?;
            if value.is_empty()
                || value.trim() != value
                || value.bytes().any(|byte| byte.is_ascii_control())
                || value.len() > 1024
            {
                return Err(replication_not_configured());
            }
            Ok(value.to_owned())
        })
        .transpose()
}

fn validate_bucket(bucket: &str) -> Result<(), ApiError> {
    if bucket.is_empty()
        || bucket.len() < 3
        || bucket.len() > MAX_BUCKET_BYTES
        || bucket.starts_with('.')
        || bucket.ends_with('.')
        || bucket.contains("..")
        || !bucket.as_bytes()[0].is_ascii_lowercase() && !bucket.as_bytes()[0].is_ascii_digit()
        || !bucket.as_bytes()[bucket.len() - 1].is_ascii_lowercase()
            && !bucket.as_bytes()[bucket.len() - 1].is_ascii_digit()
        || !bucket.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'.'
        })
        || bucket.parse::<std::net::IpAddr>().is_ok()
    {
        return Err(replication_not_configured());
    }
    Ok(())
}

fn validate_region(region: &str) -> Result<(), ApiError> {
    if region.is_empty()
        || region.len() > 64
        || !region
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        return Err(replication_not_configured());
    }
    Ok(())
}

fn validate_endpoint(endpoint: &str) -> Result<(), ApiError> {
    let parsed = Url::parse(endpoint).map_err(|_| replication_not_configured())?;
    if !matches!(parsed.scheme(), "https" | "http")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(replication_not_configured());
    }
    // Plain HTTP is supported only for an isolated loopback Mock S3 fixture.
    if parsed.scheme() == "http" {
        let loopback = match parsed.host() {
            Some(url::Host::Ipv4(address)) => address.is_loopback(),
            Some(url::Host::Ipv6(address)) => address.is_loopback(),
            Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
            None => false,
        };
        if !loopback {
            return Err(replication_not_configured());
        }
    }
    Ok(())
}

fn validate_prefix(prefix: &str) -> Result<(), ApiError> {
    if prefix.is_empty()
        || prefix.len() > MAX_PREFIX_BYTES
        || prefix.starts_with('/')
        || prefix.ends_with('/')
        || prefix.split('/').any(|part| {
            part.is_empty()
                || part == "."
                || part == ".."
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"-_.".contains(&byte))
        })
    {
        return Err(replication_not_configured());
    }
    Ok(())
}

fn validate_secret_path(config: &Config, path: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| replication_not_configured())?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(replication_not_configured());
    }
    let data_dir = fs::canonicalize(&config.data_dir).map_err(|_| replication_not_configured())?;
    let archive_dir = config
        .backup_archive_dir
        .as_deref()
        .ok_or_else(replication_not_configured)?;
    let archive_dir = fs::canonicalize(archive_dir).map_err(|_| replication_not_configured())?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let resolved = fs::canonicalize(parent)
        .map_err(|_| replication_not_configured())?
        .join(path.file_name().ok_or_else(replication_not_configured)?);
    if resolved.starts_with(data_dir) || resolved.starts_with(archive_dir) {
        return Err(replication_not_configured());
    }
    Ok(())
}

fn read_credentials(path: &Path) -> Result<CredentialsDocument, ApiError> {
    let bytes = crate::secure_file::read_private_secret_file(path, MAX_CREDENTIAL_FILE_BYTES)
        .map_err(|_| replication_not_configured())?;
    let mut credentials: CredentialsDocument =
        serde_json::from_slice(&bytes).map_err(|_| replication_not_configured())?;
    if credentials.access_key_id.is_empty()
        || credentials.secret_access_key.is_empty()
        || credentials.access_key_id.len() > 256
        || credentials.secret_access_key.len() > 2048
        || credentials
            .session_token
            .as_ref()
            .is_some_and(|token| token.is_empty() || token.len() > 4096)
    {
        credentials.access_key_id.zeroize();
        credentials.secret_access_key.zeroize();
        if let Some(token) = &mut credentials.session_token {
            token.zeroize();
        }
        return Err(replication_not_configured());
    }
    Ok(credentials)
}

fn replication_not_configured() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "BACKUP_REPLICATION_NOT_CONFIGURED",
        "encrypted backup replication is not configured",
    )
}

fn failure_category(value: &str) -> Option<&'static str> {
    match value {
        "archive_unavailable" => Some("archive_unavailable"),
        "credentials_invalid" => Some("credentials_invalid"),
        "remote_unavailable" => Some("remote_unavailable"),
        "remote_integrity_mismatch" => Some("remote_integrity_mismatch"),
        "replication_failed" => Some("replication_failed"),
        _ => None,
    }
}

fn credentials_error(code: Option<&str>) -> bool {
    matches!(
        code,
        Some(
            "InvalidAccessKeyId"
                | "SignatureDoesNotMatch"
                | "ExpiredToken"
                | "InvalidToken"
                | "AuthFailure"
        )
    )
}

fn state_name(value: &str) -> &'static str {
    match value {
        "pending_archive" => "pending_archive",
        "pending" => "pending",
        "running" => "running",
        "retry_wait" => "retry_wait",
        "succeeded" => "succeeded",
        "interrupted" => "interrupted",
        "failed" => "failed",
        _ => "failed",
    }
}

fn unix_to_timestamp(value: i64) -> Result<String, ApiError> {
    DateTime::<Utc>::from_timestamp(value, 0)
        .map(|time| time.to_rfc3339_opts(SecondsFormat::Millis, true))
        .ok_or_else(|| ApiError::internal("backup replication timestamp is invalid"))
}

pub(crate) async fn status(state: &AppState) -> Result<ReplicationStatus, ApiError> {
    let configured = settings_configured(&state.config);
    let pending_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM instance_backup_replications \
         WHERE status IN ('pending_archive','pending','running','retry_wait','interrupted')",
    )
    .fetch_one(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT archive_id,status,last_attempt_at,completed_at,archive_bytes,failure_category \
         FROM instance_backup_replications WHERE last_attempt_at IS NOT NULL \
         ORDER BY last_attempt_at DESC,archive_id DESC LIMIT 1",
    )
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let latest_attempt = row
        .map(|row| {
            let attempted_at: i64 = row.get("last_attempt_at");
            let completed_at: Option<i64> = row.get("completed_at");
            let failure: Option<String> = row.get("failure_category");
            Ok(ReplicationAttemptDto {
                archive_id: row.get("archive_id"),
                state: state_name(row.get::<String, _>("status").as_str()),
                attempted_at: unix_to_timestamp(attempted_at)?,
                completed_at: completed_at.map(unix_to_timestamp).transpose()?,
                archive_bytes: row.get("archive_bytes"),
                failure_category: failure.as_deref().and_then(failure_category),
            })
        })
        .transpose()?;
    Ok(ReplicationStatus {
        operation: "backup_replication",
        configured,
        pending_count,
        latest_attempt,
    })
}

pub(crate) fn status_from_pg(
    config: &Config,
    snapshot: crate::pg_backup_replication::PgBackupReplicationSnapshot,
) -> ReplicationStatus {
    let latest_attempt = snapshot
        .latest_attempt
        .map(|attempt| ReplicationAttemptDto {
            archive_id: attempt.archive_id,
            state: attempt.state,
            attempted_at: attempt
                .attempted_at
                .to_rfc3339_opts(SecondsFormat::Millis, true),
            completed_at: attempt
                .completed_at
                .map(|time| time.to_rfc3339_opts(SecondsFormat::Millis, true)),
            archive_bytes: attempt.archive_bytes,
            failure_category: attempt.failure_category,
        });
    ReplicationStatus {
        operation: "backup_replication",
        configured: settings_configured(config),
        pending_count: snapshot.pending_count,
        latest_attempt,
    }
}

pub(crate) async fn register_archive_before_snapshot(
    state: &AppState,
    archive_id: &str,
    origin: &str,
) -> Result<(), ApiError> {
    if !replication_requested(&state.config) {
        return Ok(());
    }
    if !matches!(origin, "manual" | "scheduled") || Uuid::parse_str(archive_id).is_err() {
        return Err(ApiError::internal(
            "backup replication source identity is invalid",
        ));
    }
    sqlx::query(
        "INSERT INTO instance_backup_replications(archive_id,origin,created_at,status,attempt_count) \
         VALUES(?,?,?,'pending_archive',0) ON CONFLICT(archive_id) DO NOTHING",
    )
    .bind(archive_id)
    .bind(origin)
    .bind(Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true))
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn archive_created(
    state: &AppState,
    archive_id: &str,
    archive_bytes: u64,
    archive_sha256: &str,
) -> Result<(), ApiError> {
    if !replication_requested(&state.config) {
        return Ok(());
    }
    let changed = sqlx::query(
        "UPDATE instance_backup_replications SET status='pending',archive_bytes=?, \
            archive_sha256=?,next_attempt_at=?,failure_category=NULL \
         WHERE archive_id=? AND status IN ('pending_archive','interrupted')",
    )
    .bind(i64::try_from(archive_bytes).map_err(ApiError::internal)?)
    .bind(archive_sha256)
    .bind(Utc::now().timestamp())
    .bind(archive_id)
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        let existing: Option<String> = sqlx::query_scalar(
            "SELECT archive_sha256 FROM instance_backup_replications WHERE archive_id=?",
        )
        .bind(archive_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
        if existing.as_deref() != Some(archive_sha256) {
            return Err(ApiError::internal(
                "backup replication outbox row could not be updated",
            ));
        }
    }
    Ok(())
}

pub(crate) async fn archive_creation_failed(
    state: &AppState,
    archive_id: &str,
) -> Result<(), ApiError> {
    if !replication_requested(&state.config) {
        return Ok(());
    }
    sqlx::query(
        "UPDATE instance_backup_replications SET status='failed',failure_category='archive_unavailable', \
            completed_at=?,next_attempt_at=NULL \
         WHERE archive_id=? AND status='pending_archive'",
    )
    .bind(Utc::now().timestamp())
    .bind(archive_id)
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn recover_interrupted(state: &AppState) -> Result<(), ApiError> {
    sqlx::query(
        "UPDATE instance_backup_replications SET status='interrupted',next_attempt_at=?, \
            started_at=NULL,failure_category='remote_unavailable' \
         WHERE status='running'",
    )
    .bind(Utc::now().timestamp())
    .execute(&state.db)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

#[derive(Debug, Clone)]
struct ReplicationClaim {
    archive_id: String,
    origin: String,
    attempt_count: i64,
    archive_bytes: Option<i64>,
    archive_sha256: Option<String>,
    multipart_upload_id: Option<String>,
}

#[derive(Clone, Copy)]
enum ReplicationPersistence<'a> {
    Sqlite(&'a AppState),
    Postgres(&'a PgBackupReplicationRepository),
}

impl ReplicationPersistence<'_> {
    async fn persist_upload_id(
        self,
        claim: &ReplicationClaim,
        upload_id: Option<&str>,
    ) -> Result<bool, ApiError> {
        match self {
            Self::Sqlite(state) => {
                let result = sqlx::query(
                    "UPDATE instance_backup_replications SET multipart_upload_id=? \
                     WHERE archive_id=? AND status='running' AND attempt_count=?",
                )
                .bind(upload_id)
                .bind(&claim.archive_id)
                .bind(claim.attempt_count)
                .execute(&state.db)
                .await
                .map_err(ApiError::internal)?;
                Ok(result.rows_affected() == 1)
            }
            Self::Postgres(repository) => {
                repository
                    .persist_upload_id(&claim.archive_id, claim.attempt_count, upload_id)
                    .await
            }
        }
    }

    async fn persist_archive_metadata(
        self,
        claim: &ReplicationClaim,
        archive_bytes: u64,
        sha256: &str,
    ) -> Result<bool, ApiError> {
        match self {
            Self::Sqlite(state) => {
                let archive_bytes = i64::try_from(archive_bytes).map_err(ApiError::internal)?;
                let result = sqlx::query(
                    "UPDATE instance_backup_replications SET archive_bytes=?,archive_sha256=? \
                     WHERE archive_id=? AND status='running' AND attempt_count=? \
                       AND (archive_bytes IS NULL OR archive_bytes=?) \
                       AND (archive_sha256 IS NULL OR archive_sha256=?)",
                )
                .bind(archive_bytes)
                .bind(sha256)
                .bind(&claim.archive_id)
                .bind(claim.attempt_count)
                .bind(archive_bytes)
                .bind(sha256)
                .execute(&state.db)
                .await
                .map_err(ApiError::internal)?;
                Ok(result.rows_affected() == 1)
            }
            Self::Postgres(repository) => {
                repository
                    .persist_archive_metadata(
                        &claim.archive_id,
                        claim.attempt_count,
                        archive_bytes,
                        sha256,
                    )
                    .await
            }
        }
    }

    async fn persist_success(self, claim: &ReplicationClaim) -> Result<bool, ApiError> {
        match self {
            Self::Sqlite(state) => {
                let result = sqlx::query(
                    "UPDATE instance_backup_replications SET status='succeeded',completed_at=?, \
                        failure_category=NULL,next_attempt_at=NULL,multipart_upload_id=NULL,started_at=NULL \
                     WHERE archive_id=? AND status='running' AND attempt_count=?",
                )
                .bind(Utc::now().timestamp())
                .bind(&claim.archive_id)
                .bind(claim.attempt_count)
                .execute(&state.db)
                .await
                .map_err(ApiError::internal)?;
                Ok(result.rows_affected() == 1)
            }
            Self::Postgres(repository) => {
                repository
                    .persist_success(&claim.archive_id, claim.attempt_count)
                    .await
            }
        }
    }

    async fn persist_failure(
        self,
        claim: &ReplicationClaim,
        category: &'static str,
        retryable: bool,
    ) -> Result<bool, ApiError> {
        let delay_seconds = retry_delay_seconds(claim.attempt_count);
        match self {
            Self::Sqlite(state) => {
                let now = Utc::now().timestamp();
                let result = if retryable {
                    sqlx::query(
                        "UPDATE instance_backup_replications SET status='retry_wait',failure_category=?, \
                            next_attempt_at=?,started_at=NULL \
                         WHERE archive_id=? AND status='running' AND attempt_count=?",
                    )
                    .bind(category)
                    .bind(now.saturating_add(delay_seconds))
                    .bind(&claim.archive_id)
                    .bind(claim.attempt_count)
                    .execute(&state.db)
                    .await
                } else {
                    sqlx::query(
                        "UPDATE instance_backup_replications SET status='failed',failure_category=?, \
                            completed_at=?,next_attempt_at=NULL,started_at=NULL \
                         WHERE archive_id=? AND status='running' AND attempt_count=?",
                    )
                    .bind(category)
                    .bind(now)
                    .bind(&claim.archive_id)
                    .bind(claim.attempt_count)
                    .execute(&state.db)
                    .await
                }
                .map_err(ApiError::internal)?;
                Ok(result.rows_affected() == 1)
            }
            Self::Postgres(repository) => {
                repository
                    .persist_failure(
                        &claim.archive_id,
                        claim.attempt_count,
                        category,
                        retryable,
                        delay_seconds,
                    )
                    .await
            }
        }
    }

    async fn renew_claim(self, claim: &ReplicationClaim) -> Result<bool, ApiError> {
        match self {
            Self::Sqlite(_) => Ok(true),
            Self::Postgres(repository) => {
                repository
                    .renew_claim(&claim.archive_id, claim.attempt_count)
                    .await
            }
        }
    }

    fn abort_all_multipart_uploads(self) -> bool {
        // Called before this generation creates its own multipart upload.
        // PostgreSQL leases guarantee any upload already present belongs to
        // an expired generation (or is an orphan from the create/persist gap).
        let _ = self;
        true
    }
}

fn retry_delay_seconds(attempt_count: i64) -> i64 {
    let exponent = attempt_count.clamp(1, 16) as u32 - 1;
    15_i64
        .saturating_mul(1_i64 << exponent)
        .min(MAX_RETRY_SECONDS)
}

async fn claim_due(state: &AppState) -> Result<Option<ReplicationClaim>, ApiError> {
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT archive_id,origin,attempt_count,archive_bytes,archive_sha256,multipart_upload_id \
         FROM instance_backup_replications WHERE \
           status IN ('pending_archive','pending','retry_wait','interrupted') \
           AND (next_attempt_at IS NULL OR next_attempt_at<=?) \
         ORDER BY COALESCE(next_attempt_at,0),created_at,archive_id LIMIT 1",
    )
    .bind(Utc::now().timestamp())
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let claim = ReplicationClaim {
        archive_id: row.get("archive_id"),
        origin: row.get("origin"),
        attempt_count: row.get::<i64, _>("attempt_count") + 1,
        archive_bytes: row.get("archive_bytes"),
        archive_sha256: row.get("archive_sha256"),
        multipart_upload_id: row.get("multipart_upload_id"),
    };
    let now = Utc::now().timestamp();
    let changed = sqlx::query(
        "UPDATE instance_backup_replications SET status='running',attempt_count=?, \
            started_at=?,last_attempt_at=?,next_attempt_at=NULL,failure_category=NULL \
         WHERE archive_id=? AND status IN ('pending_archive','pending','retry_wait','interrupted')",
    )
    .bind(claim.attempt_count)
    .bind(now)
    .bind(now)
    .bind(&claim.archive_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "backup replication claim was not applied",
        ));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(claim))
}

pub(crate) async fn run_one_due(state: &AppState) -> Result<bool, ApiError> {
    if !replication_requested(&state.config) {
        return Ok(false);
    }
    // The shared operation lock protects the durable claim. Once the row is
    // running, local retention protects its archive, so the potentially long
    // network transfer does not hold maintenance, backup, or restore hostage.
    let claim = {
        let _guard = match crate::acquire_instance_maintenance_lock(state).await {
            Ok(guard) => guard,
            Err(error) if error.body.code == "MAINTENANCE_ALREADY_RUNNING" => return Ok(false),
            Err(error) => return Err(error),
        };
        let Some(claim) = claim_due(state).await? else {
            return Ok(false);
        };
        claim
    };
    process_claim(state, ReplicationPersistence::Sqlite(state), &claim).await?;
    Ok(true)
}

pub(crate) async fn run_one_pg_due(
    state: &AppState,
    repository: &PgBackupReplicationRepository,
) -> Result<bool, ApiError> {
    if !replication_requested(&state.config) {
        return Ok(false);
    }
    let Some(pg_claim) = repository.claim_due().await? else {
        return Ok(false);
    };
    let claim = ReplicationClaim {
        archive_id: pg_claim.archive_id,
        origin: pg_claim.origin,
        attempt_count: pg_claim.attempt_count,
        archive_bytes: pg_claim.archive_bytes,
        archive_sha256: pg_claim.archive_sha256,
        multipart_upload_id: pg_claim.multipart_upload_id,
    };
    process_claim(state, ReplicationPersistence::Postgres(repository), &claim).await?;
    Ok(true)
}

async fn process_claim(
    state: &AppState,
    persistence: ReplicationPersistence<'_>,
    claim: &ReplicationClaim,
) -> Result<(), ApiError> {
    let result = match configured_settings(&state.config) {
        Ok(Some(settings)) => {
            match run_transfer_with_lease(state, persistence, &settings, claim).await? {
                Some(result) => result,
                None => return Ok(()),
            }
        }
        Ok(None) | Err(_) => Err(("credentials_invalid", true)),
    };
    match result {
        Ok(()) => {
            let _ = persistence.persist_success(claim).await?;
        }
        Err((category, retryable)) => {
            let _ = persistence
                .persist_failure(claim, category, retryable)
                .await?;
        }
    }
    Ok(())
}

async fn run_transfer_with_lease(
    state: &AppState,
    persistence: ReplicationPersistence<'_>,
    settings: &S3ReplicaSettings,
    claim: &ReplicationClaim,
) -> Result<Option<Result<(), (&'static str, bool)>>, ApiError> {
    if matches!(persistence, ReplicationPersistence::Sqlite(_)) {
        let result = tokio::time::timeout(
            MAX_TRANSFER_DURATION,
            replicate_claim(state, persistence, settings, claim),
        )
        .await
        .unwrap_or(Err(("remote_unavailable", true)));
        return Ok(Some(result));
    }

    if !persistence.renew_claim(claim).await? {
        return Ok(None);
    }

    let transfer = tokio::time::timeout(
        MAX_TRANSFER_DURATION,
        replicate_claim(state, persistence, settings, claim),
    );
    tokio::pin!(transfer);
    let mut renewal = tokio::time::interval(std::time::Duration::from_secs(30));
    renewal.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    renewal.tick().await;
    loop {
        tokio::select! {
            result = &mut transfer => {
                return Ok(Some(result.unwrap_or(Err(("remote_unavailable", true)))));
            }
            _ = renewal.tick() => {
                if !persistence.renew_claim(claim).await? {
                    // Drop the network future immediately when this generation
                    // no longer owns the database lease. Its persisted upload
                    // ID, if any, is cleaned by the next fenced claim.
                    return Ok(None);
                }
            }
        }
    }
}

pub(crate) async fn list_replica_restore_sources(
    state: &AppState,
) -> Result<Vec<crate::backup::RestoreArchiveSource>, ApiError> {
    if !settings_configured(&state.config) {
        return Ok(Vec::new());
    }
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL backup replication is unavailable"))?;
        let rows = crate::pg_backup_replication::PgBackupReplicationRepository::new(pool.clone())
            .list_restore_archives()
            .await?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| {
                Some(crate::backup::RestoreArchiveSource {
                    archive_id: row.archive_id,
                    created_at: row
                        .created_at
                        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
                    archive_bytes: u64::try_from(row.archive_bytes).ok()?,
                    origin: match row.origin.as_str() {
                        "manual" => "manual",
                        "scheduled" => "scheduled",
                        _ => return None,
                    },
                    source: "replica",
                })
            })
            .collect());
    }
    let rows = sqlx::query(
        "SELECT archive_id,origin,created_at,archive_bytes,archive_sha256 \
         FROM instance_backup_replications WHERE status='succeeded' \
         ORDER BY created_at DESC,archive_id DESC",
    )
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let mut sources = Vec::with_capacity(rows.len());
    for row in rows {
        let archive_id: String = row.get("archive_id");
        let origin: String = row.get("origin");
        let created_at: String = row.get("created_at");
        let archive_bytes: Option<i64> = row.get("archive_bytes");
        let archive_sha256: Option<String> = row.get("archive_sha256");
        if Uuid::parse_str(&archive_id).is_err()
            || Uuid::parse_str(&archive_id).is_ok_and(|value| value.to_string() != archive_id)
            || !matches!(origin.as_str(), "manual" | "scheduled")
            || DateTime::parse_from_rfc3339(&created_at).is_err()
            || archive_bytes.is_none_or(|bytes| bytes <= 0)
            || archive_sha256.as_deref().is_none_or(|sha256| {
                sha256.len() != 64
                    || !sha256
                        .bytes()
                        .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
            })
        {
            continue;
        }
        sources.push(crate::backup::RestoreArchiveSource {
            archive_id,
            created_at,
            archive_bytes: archive_bytes.unwrap_or_default() as u64,
            origin: if origin == "manual" {
                "manual"
            } else {
                "scheduled"
            },
            source: "replica",
        });
    }
    Ok(sources)
}

async fn s3_client(settings: &S3ReplicaSettings) -> Result<S3Client, &'static str> {
    let mut credentials =
        read_credentials(&settings.credentials_file).map_err(|_| "credentials_invalid")?;
    let provider = Credentials::new(
        credentials.access_key_id.clone(),
        credentials.secret_access_key.clone(),
        credentials.session_token.clone(),
        None,
        "atermius-backup-credentials-file",
    );
    credentials.access_key_id.zeroize();
    credentials.secret_access_key.zeroize();
    if let Some(token) = &mut credentials.session_token {
        token.zeroize();
    }

    // Build this S3 client without loading ambient environment/shared-profile
    // endpoint or credential settings. Only the validated server settings
    // below choose the destination, region, and static credentials.
    let mut builder = aws_sdk_s3::config::Builder::new()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new(settings.region.clone()))
        .credentials_provider(provider)
        // PutObject supplies SHA-256 explicitly. Multipart parts are verified
        // by hashing the completed remote object and validating its encrypted
        // archive, so avoid optional streaming checksum trailers that many
        // S3-compatible endpoints do not implement consistently.
        .request_checksum_calculation(aws_sdk_s3::config::RequestChecksumCalculation::WhenRequired)
        .force_path_style(true);
    if let Some(endpoint) = &settings.endpoint_url {
        builder = builder.endpoint_url(endpoint);
    }
    Ok(S3Client {
        client: Client::from_conf(builder.build()),
        bucket: settings.bucket.clone(),
        prefix: settings.prefix.clone(),
    })
}

fn object_key(
    prefix: Option<&str>,
    instance_id: &str,
    archive_id: &str,
) -> Result<String, &'static str> {
    let parsed = Uuid::parse_str(instance_id).map_err(|_| "replication_failed")?;
    if parsed.to_string() != instance_id {
        return Err("replication_failed");
    }
    let parsed = Uuid::parse_str(archive_id).map_err(|_| "replication_failed")?;
    if parsed.to_string() != archive_id {
        return Err("replication_failed");
    }
    let object = format!("atermius/v1/{instance_id}/{archive_id}.atb");
    Ok(prefix
        .map(|prefix| format!("{prefix}/{object}"))
        .unwrap_or(object))
}

#[derive(Debug, Clone)]
struct RemoteHead {
    bytes: u64,
    sha256: Option<String>,
}

async fn head_object(client: &S3Client, key: &str) -> Result<Option<RemoteHead>, &'static str> {
    let response = tokio::time::timeout(
        REQUEST_TIMEOUT,
        client
            .client
            .head_object()
            .bucket(&client.bucket)
            .key(key)
            .send(),
    )
    .await
    .map_err(|_| "remote_unavailable")?;
    match response {
        Ok(output) => {
            let bytes = output
                .content_length()
                .and_then(|value| u64::try_from(value).ok())
                .ok_or("remote_integrity_mismatch")?;
            let sha256 = output
                .metadata()
                .and_then(|metadata| metadata.get("atermius-sha256"))
                .cloned();
            Ok(Some(RemoteHead { bytes, sha256 }))
        }
        Err(error) => {
            let code = error
                .as_service_error()
                .and_then(|service_error| service_error.code());
            if matches!(code, Some("NoSuchKey" | "NotFound" | "404")) {
                Ok(None)
            } else {
                Err(if credentials_error(code) {
                    "credentials_invalid"
                } else {
                    "remote_unavailable"
                })
            }
        }
    }
}

fn create_private_download(path: &Path) -> io::Result<std::fs::File> {
    let mut options = OpenOptions::new();
    options.write(true).read(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    options.open(path)
}

async fn stream_object_to_private_file(
    client: &S3Client,
    key: &str,
    target: &Path,
    expected_bytes: Option<u64>,
    expected_sha256: Option<&str>,
) -> Result<(PrivateArchiveFile, u64, String), &'static str> {
    let output = tokio::time::timeout(
        REQUEST_TIMEOUT,
        client
            .client
            .get_object()
            .bucket(&client.bucket)
            .key(key)
            .send(),
    )
    .await
    .map_err(|_| "remote_unavailable")?
    .map_err(|_| "remote_unavailable")?;
    if let Some(length) = output.content_length() {
        let length = u64::try_from(length).map_err(|_| "remote_integrity_mismatch")?;
        if expected_bytes.is_some_and(|expected| expected != length) {
            return Err("remote_integrity_mismatch");
        }
    }

    let path = target.to_path_buf();
    let file = create_private_download(&path).map_err(|_| "replication_failed")?;
    let guard = PrivateArchiveFile(path);
    let mut output_file = tokio::fs::File::from_std(file);
    let mut stream = output.body;
    let mut hasher = Sha256::new();
    let mut total = 0_u64;
    let deadline = tokio::time::Instant::now() + MAX_TRANSFER_DURATION;
    loop {
        let chunk = tokio::time::timeout_at(
            deadline,
            tokio::time::timeout(REQUEST_TIMEOUT, stream.try_next()),
        )
        .await
        .map_err(|_| "remote_unavailable")?
        .map_err(|_| "remote_unavailable")?
        .map_err(|_| "remote_unavailable")?;
        let Some(chunk) = chunk else { break };
        total = total
            .checked_add(chunk.len() as u64)
            .ok_or("remote_integrity_mismatch")?;
        if total > crate::backup::MAX_BACKUP_ARCHIVE_BYTES
            || expected_bytes.is_some_and(|expected| total > expected)
        {
            return Err("remote_integrity_mismatch");
        }
        hasher.update(&chunk);
        tokio::io::AsyncWriteExt::write_all(&mut output_file, &chunk)
            .await
            .map_err(|_| "replication_failed")?;
    }
    if expected_bytes.is_some_and(|expected| expected != total) {
        return Err("remote_integrity_mismatch");
    }
    tokio::io::AsyncWriteExt::flush(&mut output_file)
        .await
        .map_err(|_| "replication_failed")?;
    output_file
        .sync_all()
        .await
        .map_err(|_| "replication_failed")?;
    drop(output_file);
    let sha256 = hex::encode(hasher.finalize());
    if expected_sha256.is_some_and(|expected| expected != sha256) {
        return Err("remote_integrity_mismatch");
    }
    Ok((guard, total, sha256))
}

async fn validate_existing_object(
    state: &AppState,
    client: &S3Client,
    key: &str,
    head: &RemoteHead,
    expected_bytes: Option<u64>,
    expected_sha256: Option<&str>,
) -> Result<(u64, String), (&'static str, bool)> {
    if expected_bytes.is_some_and(|expected| expected != head.bytes)
        || expected_sha256
            .zip(head.sha256.as_deref())
            .is_some_and(|(expected, actual)| expected != actual)
    {
        return Err(("remote_integrity_mismatch", false));
    }
    let settings = crate::backup::configured_backup_paths(&state.config)
        .map_err(|_| ("credentials_invalid", false))?;
    let temp_path = settings
        .archive_dir
        .join(format!(".replica-verify-{}.atb", Uuid::new_v4()));
    let (temp, bytes, sha256) = stream_object_to_private_file(
        client,
        key,
        &temp_path,
        Some(head.bytes),
        expected_sha256.or(head.sha256.as_deref()),
    )
    .await
    .map_err(|category| (category, category != "remote_integrity_mismatch"))?;
    if expected_bytes.is_some_and(|expected| expected != bytes)
        || expected_sha256.is_some_and(|expected| expected != sha256)
    {
        return Err(("remote_integrity_mismatch", false));
    }
    crate::backup::verify_instance_backup(&state.config.data_dir, &temp.0, &settings.key_file)
        .await
        .map_err(|_| ("remote_integrity_mismatch", false))?;
    Ok((bytes, sha256))
}

async fn abort_multipart(client: &S3Client, key: &str, upload_id: &str) -> Result<(), ()> {
    let response = tokio::time::timeout(
        REQUEST_TIMEOUT,
        client
            .client
            .abort_multipart_upload()
            .bucket(&client.bucket)
            .key(key)
            .upload_id(upload_id)
            .send(),
    )
    .await
    .map_err(|_| ())?;
    match response {
        Ok(_) => Ok(()),
        Err(error)
            if matches!(
                error.as_service_error().and_then(|service| service.code()),
                Some("NoSuchUpload" | "NoSuchKey" | "NotFound" | "404")
            ) =>
        {
            // A previous attempt may have completed the upload before it
            // lost its database lease. Treat an already-consumed upload ID
            // as cleaned; the caller verifies the final object by digest.
            Ok(())
        }
        Err(_) => Err(()),
    }
}

async fn abort_key_multipart_uploads(client: &S3Client, key: &str) -> Result<(), ()> {
    let mut key_marker: Option<String> = None;
    let mut upload_id_marker: Option<String> = None;
    loop {
        let mut request = client
            .client
            .list_multipart_uploads()
            .bucket(&client.bucket)
            .prefix(key)
            .max_uploads(1000);
        if let Some(marker) = key_marker.as_deref() {
            request = request.key_marker(marker);
        }
        if let Some(marker) = upload_id_marker.as_deref() {
            request = request.upload_id_marker(marker);
        }
        let response = tokio::time::timeout(REQUEST_TIMEOUT, request.send())
            .await
            .map_err(|_| ())?
            .map_err(|_| ())?;
        for upload in response.uploads() {
            if upload.key() == Some(key) {
                let upload_id = upload.upload_id().ok_or(())?;
                abort_multipart(client, key, upload_id).await?;
            }
        }
        if !response.is_truncated().unwrap_or(false) {
            return Ok(());
        }
        key_marker = response.next_key_marker().map(str::to_owned);
        upload_id_marker = response.next_upload_id_marker().map(str::to_owned);
        if key_marker.is_none() && upload_id_marker.is_none() {
            return Err(());
        }
    }
}

fn is_conditional_write_conflict(code: Option<&str>) -> bool {
    matches!(
        code,
        Some("PreconditionFailed" | "ConditionalRequestConflict")
    )
}

fn multipart_part_bytes(file_bytes: u64) -> u64 {
    let required = file_bytes.div_ceil(MAX_MULTIPART_PARTS);
    required
        .max(MIN_MULTIPART_BYTES)
        .min(MAX_MULTIPART_PART_BYTES)
}

async fn upload_archive(
    persistence: ReplicationPersistence<'_>,
    claim: &ReplicationClaim,
    client: &S3Client,
    key: &str,
    archive_path: &Path,
    archive_bytes: u64,
    archive_sha256: &str,
    previous_upload_id: Option<&str>,
) -> Result<(), (&'static str, bool)> {
    if let Some(upload_id) = previous_upload_id {
        if abort_multipart(client, key, upload_id).await.is_err() {
            return Err(("remote_unavailable", true));
        }
        persistence
            .persist_upload_id(claim, None)
            .await
            .map_err(|_| ("replication_failed", true))?
            .then_some(())
            .ok_or(("replication_failed", true))?;
    }

    if archive_bytes <= MAX_SINGLE_PUT_BYTES {
        let body = ByteStream::read_from()
            .path(archive_path)
            .length(Length::Exact(archive_bytes))
            .build()
            .await
            .map_err(|_| ("archive_unavailable", false))?;
        let digest = hex::decode(archive_sha256).map_err(|_| ("replication_failed", false))?;
        let response = tokio::time::timeout(
            REQUEST_TIMEOUT,
            client
                .client
                .put_object()
                .bucket(&client.bucket)
                .key(key)
                .content_length(
                    i64::try_from(archive_bytes).map_err(|_| ("archive_unavailable", false))?,
                )
                .checksum_sha256(STANDARD.encode(digest))
                .metadata("atermius-sha256", archive_sha256)
                .if_none_match("*")
                .body(body)
                .send(),
        )
        .await
        .map_err(|_| ("remote_unavailable", true))?;
        match response {
            Ok(_) => {}
            Err(error)
                if is_conditional_write_conflict(
                    error.as_service_error().and_then(|service| service.code()),
                ) =>
            {
                return Err(("object_exists", false));
            }
            Err(_) => return Err(("remote_unavailable", true)),
        }
        return Ok(());
    }

    let created = tokio::time::timeout(
        REQUEST_TIMEOUT,
        client
            .client
            .create_multipart_upload()
            .bucket(&client.bucket)
            .key(key)
            .metadata("atermius-sha256", archive_sha256)
            .send(),
    )
    .await
    .map_err(|_| ("remote_unavailable", true))?
    .map_err(|_| ("remote_unavailable", true))?;
    let upload_id = created
        .upload_id()
        .ok_or(("remote_unavailable", true))?
        .to_owned();
    let upload_id_saved = persistence
        .persist_upload_id(claim, Some(&upload_id))
        .await
        .map_err(|_| ("replication_failed", true))?;
    if !upload_id_saved {
        let _ = abort_multipart(client, key, &upload_id).await;
        return Err(("replication_failed", true));
    }

    let upload_result: Result<(), (&'static str, bool)> = async {
        let part_bytes = multipart_part_bytes(archive_bytes);
        let parts_count = archive_bytes.div_ceil(part_bytes);
        if parts_count > MAX_MULTIPART_PARTS {
            return Err(("replication_failed", false));
        }
        let mut completed = Vec::with_capacity(parts_count as usize);
        let mut offset = 0_u64;
        for part_index in 0..parts_count {
            let part_len = (archive_bytes - offset).min(part_bytes);
            let body = ByteStream::read_from()
                .path(archive_path)
                .offset(offset)
                .length(Length::Exact(part_len))
                .build()
                .await
                .map_err(|_| ("archive_unavailable", false))?;
            let content_length =
                i64::try_from(part_len).map_err(|_| ("archive_unavailable", false))?;
            let response = tokio::time::timeout(
                REQUEST_TIMEOUT,
                client
                    .client
                    .upload_part()
                    .bucket(&client.bucket)
                    .key(key)
                    .upload_id(&upload_id)
                    .part_number((part_index + 1) as i32)
                    .content_length(content_length)
                    .body(body)
                    .send(),
            )
            .await;
            let response = match response {
                Err(_) => {
                    tracing::warn!(
                        target: "atermius_server::backup_replication",
                        operation = "multipart_upload_part",
                        error_class = "request_timeout",
                        "encrypted archive replica request failed"
                    );
                    return Err(("remote_unavailable", true));
                }
                Ok(Err(error)) => {
                    let error_class = match &error {
                        aws_sdk_s3::error::SdkError::TimeoutError(_) => "sdk_timeout",
                        aws_sdk_s3::error::SdkError::ServiceError(_) => "service",
                        aws_sdk_s3::error::SdkError::ResponseError(_) => "response",
                        _ => "dispatch_or_construction",
                    };
                    tracing::warn!(
                        target: "atermius_server::backup_replication",
                        operation = "multipart_upload_part",
                        error_class,
                        "encrypted archive replica request failed"
                    );
                    return Err(("remote_unavailable", true));
                }
                Ok(Ok(response)) => response,
            };
            let etag = response
                .e_tag()
                .ok_or(("remote_unavailable", true))?
                .to_owned();
            completed.push(
                CompletedPart::builder()
                    .part_number((part_index + 1) as i32)
                    .e_tag(etag)
                    .build(),
            );
            offset += part_len;
        }
        let multipart = CompletedMultipartUpload::builder()
            .set_parts(Some(completed))
            .build();
        let completion = tokio::time::timeout(
            REQUEST_TIMEOUT,
            client
                .client
                .complete_multipart_upload()
                .bucket(&client.bucket)
                .key(key)
                .upload_id(&upload_id)
                .multipart_upload(multipart)
                .if_none_match("*")
                .send(),
        )
        .await
        .map_err(|_| ("remote_unavailable", true))?;
        match completion {
            Ok(_) => {}
            Err(error)
                if is_conditional_write_conflict(
                    error.as_service_error().and_then(|service| service.code()),
                ) =>
            {
                return Err(("object_exists", false));
            }
            Err(_) => return Err(("remote_unavailable", true)),
        }
        Ok(())
    }
    .await;
    match upload_result {
        Ok(()) => {
            persistence
                .persist_upload_id(claim, None)
                .await
                .map_err(|_| ("replication_failed", true))?
                .then_some(())
                .ok_or(("replication_failed", true))?;
            Ok(())
        }
        Err(error) => {
            if abort_multipart(client, key, &upload_id).await.is_ok() {
                let _ = persistence.persist_upload_id(claim, None).await;
            }
            Err(error)
        }
    }
}

async fn replicate_claim(
    state: &AppState,
    persistence: ReplicationPersistence<'_>,
    settings: &S3ReplicaSettings,
    claim: &ReplicationClaim,
) -> Result<(), (&'static str, bool)> {
    let client = s3_client(settings)
        .await
        .map_err(|_| ("credentials_invalid", true))?;
    let key = object_key(
        client.prefix.as_deref(),
        &state.instance.instance_id,
        &claim.archive_id,
    )
    .map_err(|category| (category, false))?;
    if let Some(upload_id) = claim.multipart_upload_id.as_deref() {
        if abort_multipart(&client, &key, upload_id).await.is_err() {
            return Err(("remote_unavailable", true));
        }
        let cleared = persistence
            .persist_upload_id(claim, None)
            .await
            .map_err(|_| ("replication_failed", true))?;
        if !cleared {
            return Err(("replication_failed", true));
        }
    }
    let backup_settings = crate::backup::configured_backup_paths(&state.config)
        .map_err(|_| ("credentials_invalid", false))?;
    let local_path = crate::backup::generated_archive_path_for_id(
        state,
        &backup_settings,
        &claim.archive_id,
        &claim.origin,
    )
    .await
    .map_err(|_| ("archive_unavailable", true))?;
    let local_metadata = match local_path.as_deref() {
        Some(path) => {
            let (file, sha256) = crate::backup::open_and_hash_generated_archive(path)
                .map_err(|_| ("archive_unavailable", true))?;
            let bytes = file
                .metadata()
                .map_err(|_| ("archive_unavailable", true))?
                .len();
            Some((path.to_path_buf(), bytes, sha256))
        }
        None => None,
    };
    if let Some((_, bytes, sha256)) = &local_metadata {
        if claim
            .archive_bytes
            .is_some_and(|expected| u64::try_from(expected).ok() != Some(*bytes))
            || claim
                .archive_sha256
                .as_deref()
                .is_some_and(|expected| expected != sha256)
        {
            return Err(("remote_integrity_mismatch", false));
        }
        persistence
            .persist_archive_metadata(claim, *bytes, sha256)
            .await
            .map_err(|_| ("replication_failed", true))?
            .then_some(())
            .ok_or(("replication_failed", true))?;
    }

    match head_object(&client, &key).await {
        Ok(Some(head)) => {
            let expected_bytes =
                local_metadata
                    .as_ref()
                    .map(|(_, bytes, _)| *bytes)
                    .or_else(|| {
                        claim
                            .archive_bytes
                            .and_then(|value| u64::try_from(value).ok())
                    });
            let expected_hash = local_metadata
                .as_ref()
                .map(|(_, _, hash)| hash.as_str())
                .or(claim.archive_sha256.as_deref());
            let (bytes, sha256) = validate_existing_object(
                state,
                &client,
                &key,
                &head,
                expected_bytes,
                expected_hash,
            )
            .await?;
            if persistence.abort_all_multipart_uploads() {
                abort_key_multipart_uploads(&client, &key)
                    .await
                    .map_err(|_| ("remote_unavailable", true))?;
            }
            persistence
                .persist_archive_metadata(claim, bytes, &sha256)
                .await
                .map_err(|_| ("replication_failed", true))?
                .then_some(())
                .ok_or(("replication_failed", true))?;
            return Ok(());
        }
        Ok(None) => {}
        Err(category) => return Err((category, category != "remote_integrity_mismatch")),
    }

    let Some((path, bytes, sha256)) = local_metadata else {
        let producer_still_running = match persistence {
            ReplicationPersistence::Sqlite(_) => false,
            ReplicationPersistence::Postgres(_) => {
                let Some(pool) = state.pg_sync_pool.as_ref() else {
                    return Err(("replication_failed", true));
                };
                match sqlx::query_scalar::<_, bool>(
                    "SELECT EXISTS(SELECT 1 FROM instance_admin_jobs \
                     WHERE job_id=$1 AND action='backup' AND status='running')",
                )
                .bind(&claim.archive_id)
                .fetch_one(pool)
                .await
                {
                    Ok(active) => active,
                    Err(_) => return Err(("replication_failed", true)),
                }
            }
        };
        // A PG backup publishes its archive metadata just before the parent
        // admin-job lease is marked succeeded. If shared storage is briefly
        // unavailable or the resolver observes that handoff, retry after the
        // producer terminates instead of permanently failing a valid copy.
        return Err(("archive_unavailable", producer_still_running));
    };
    if persistence.abort_all_multipart_uploads() {
        abort_key_multipart_uploads(&client, &key)
            .await
            .map_err(|_| ("remote_unavailable", true))?;
    }
    match upload_archive(
        persistence,
        claim,
        &client,
        &key,
        &path,
        bytes,
        &sha256,
        None,
    )
    .await
    {
        Ok(()) => {}
        Err(("object_exists", _)) => {
            let Some(head) = head_object(&client, &key)
                .await
                .map_err(|_| ("remote_unavailable", true))?
            else {
                return Err(("remote_unavailable", true));
            };
            let (existing_bytes, existing_sha256) =
                validate_existing_object(state, &client, &key, &head, Some(bytes), Some(&sha256))
                    .await?;
            if existing_bytes != bytes || existing_sha256 != sha256 {
                return Err(("remote_integrity_mismatch", false));
            }
            if persistence.abort_all_multipart_uploads() {
                abort_key_multipart_uploads(&client, &key)
                    .await
                    .map_err(|_| ("remote_unavailable", true))?;
            }
            persistence
                .persist_archive_metadata(claim, existing_bytes, &existing_sha256)
                .await
                .map_err(|_| ("replication_failed", true))?
                .then_some(())
                .ok_or(("replication_failed", true))?;
            return Ok(());
        }
        Err(error) => return Err(error),
    }
    let Some(head) = head_object(&client, &key)
        .await
        .map_err(|_| ("remote_unavailable", true))?
    else {
        return Err(("remote_unavailable", true));
    };
    let (_, verified_sha256) =
        validate_existing_object(state, &client, &key, &head, Some(bytes), Some(&sha256)).await?;
    if verified_sha256 != sha256 {
        return Err(("remote_integrity_mismatch", false));
    }
    Ok(())
}

pub(crate) async fn download_replica_archive(
    state: &AppState,
    archive_id: &str,
    target_path: &Path,
    expected_bytes: u64,
    expected_sha256: &str,
) -> Result<(PrivateArchiveFile, u64, String), ApiError> {
    let settings =
        configured_settings(&state.config)?.ok_or_else(|| replication_not_configured())?;
    let client = s3_client(&settings)
        .await
        .map_err(|_| replication_not_configured())?;
    let key = object_key(
        client.prefix.as_deref(),
        &state.instance.instance_id,
        archive_id,
    )
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_SOURCE_UNAVAILABLE",
            "the selected server backup is unavailable for restore",
        )
    })?;
    let head = head_object(&client, &key)
        .await
        .map_err(|_| {
            ApiError::conflict(
                "RESTORE_SOURCE_UNAVAILABLE",
                "the selected server backup is unavailable for restore",
            )
        })?
        .ok_or_else(|| {
            ApiError::conflict(
                "RESTORE_SOURCE_UNAVAILABLE",
                "the selected server backup is unavailable for restore",
            )
        })?;
    if head.bytes != expected_bytes
        || head
            .sha256
            .as_deref()
            .is_some_and(|digest| digest != expected_sha256)
    {
        return Err(ApiError::conflict(
            "RESTORE_SOURCE_UNAVAILABLE",
            "the selected server backup is unavailable for restore",
        ));
    }
    stream_object_to_private_file(
        &client,
        &key,
        target_path,
        Some(expected_bytes),
        Some(expected_sha256),
    )
    .await
    .map_err(|_| {
        ApiError::conflict(
            "RESTORE_SOURCE_UNAVAILABLE",
            "the selected server backup is unavailable for restore",
        )
    })
}

pub(crate) async fn replica_archive_metadata(
    state: &AppState,
    archive_id: &str,
) -> Result<Option<(u64, String)>, ApiError> {
    if state.pg_sync_only {
        let pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL backup replication is unavailable"))?;
        let metadata =
            crate::pg_backup_replication::PgBackupReplicationRepository::new(pool.clone())
                .restore_archive_metadata(archive_id)
                .await?;
        let Some(metadata) = metadata else {
            return Ok(None);
        };
        let Ok(archive_bytes) = u64::try_from(metadata.archive_bytes) else {
            return Ok(None);
        };
        return Ok(Some((archive_bytes, metadata.archive_sha256)));
    }
    let row = sqlx::query(
        "SELECT archive_bytes,archive_sha256 FROM instance_backup_replications \
         WHERE archive_id=? AND status='succeeded'",
    )
    .bind(archive_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(None);
    };
    let bytes: i64 = row.get("archive_bytes");
    let sha256: String = row.get("archive_sha256");
    if bytes <= 0
        || sha256.len() != 64
        || !sha256
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return Ok(None);
    }
    Ok(Some((bytes as u64, sha256)))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn mode(path: &Path, value: u32) {
        fs::set_permissions(path, fs::Permissions::from_mode(value)).unwrap();
    }

    async fn test_state() -> (AppState, PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!("atermius-replica-{}", Uuid::new_v4()));
        let data_dir = root.join("data");
        let archive_dir = root.join("archives");
        let credentials_file = root.join("s3-credentials.json");
        fs::create_dir_all(&root).unwrap();
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        fs::create_dir(&archive_dir).unwrap();
        mode(&archive_dir, 0o700);
        let key_file = root.join("backup.key");
        fs::write(&key_file, [3_u8; 32]).unwrap();
        mode(&key_file, 0o600);
        fs::write(
            &credentials_file,
            br#"{"access_key_id":"TEST_ACCESS_KEY","secret_access_key":"TEST_SECRET_KEY","session_token":null}"#,
        )
        .unwrap();
        mode(&credentials_file, 0o600);

        let mut config = Config::from_env();
        config.data_dir = data_dir.clone();
        config.backup_archive_dir = Some(archive_dir);
        config.backup_key_file = Some(key_file);
        config.backup_retention_count = None;
        config.backup_replication_env = crate::BackupReplicationEnv {
            bucket: Some("replica-test-bucket".into()),
            region: Some("us-east-1".into()),
            credentials_file: Some(credentials_file.into_os_string()),
            endpoint_url: Some("http://127.0.0.1:9000".into()),
            prefix: Some("fixture".into()),
        };
        let database_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let state = crate::open_state(&database_url, config).await.unwrap();
        (state, root, data_dir)
    }

    #[test]
    fn config_credentials_object_key_and_request_bounds_are_strict() {
        let root = std::env::temp_dir().join(format!("atermius-replica-config-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let data_dir = root.join("data");
        let archive_dir = root.join("archives");
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        fs::create_dir(&archive_dir).unwrap();
        mode(&archive_dir, 0o700);
        let backup_key = root.join("backup.key");
        fs::write(&backup_key, [4_u8; 32]).unwrap();
        mode(&backup_key, 0o600);
        let credential_file = root.join("credentials.json");
        fs::write(
            &credential_file,
            br#"{"access_key_id":"fixture-access","secret_access_key":"fixture-secret"}"#,
        )
        .unwrap();
        mode(&credential_file, 0o600);
        let mut config = Config::from_env();
        config.data_dir = data_dir.clone();
        config.backup_archive_dir = Some(archive_dir);
        config.backup_key_file = Some(backup_key);
        config.backup_retention_count = None;
        config.backup_replication_env = crate::BackupReplicationEnv {
            bucket: Some("fixture-bucket".into()),
            region: Some("us-west-2".into()),
            credentials_file: Some(credential_file.clone().into_os_string()),
            endpoint_url: None,
            prefix: None,
        };
        assert!(configured_settings(&config).unwrap().is_some());
        validate_startup_configuration(&config).unwrap();
        assert!(read_credentials(&credential_file).is_ok());
        fs::write(
            &credential_file,
            br#"{"access_key_id":"fixture-access","secret_access_key":"fixture-secret","extra":"rejected"}"#,
        )
        .unwrap();
        mode(&credential_file, 0o600);
        assert!(read_credentials(&credential_file).is_err());
        fs::write(
            &credential_file,
            br#"{"access_key_id":"fixture-access","secret_access_key":"fixture-secret"}"#,
        )
        .unwrap();
        mode(&credential_file, 0o600);

        let mut partial = config.clone();
        partial.backup_replication_env.credentials_file = None;
        assert!(configured_settings(&partial).is_err());
        let mut empty = config.clone();
        empty.backup_replication_env.bucket = Some("".into());
        assert!(configured_settings(&empty).is_err());
        let nested = data_dir.join("credentials.json");
        fs::write(&nested, br#"{"access_key_id":"a","secret_access_key":"b"}"#).unwrap();
        mode(&nested, 0o600);
        let mut inside_data = config.clone();
        inside_data.backup_replication_env.credentials_file = Some(nested.into_os_string());
        assert!(configured_settings(&inside_data).is_err());
        mode(&credential_file, 0o644);
        assert!(validate_startup_configuration(&config).is_err());

        assert!(validate_bucket("ab").is_err());
        assert!(validate_bucket("-foo").is_err());
        assert!(validate_bucket("foo-").is_err());
        assert!(validate_bucket("foo").is_ok());
        assert!(validate_bucket("UpperCaseBucket").is_err());
        assert!(validate_prefix("../escape").is_err());
        assert!(validate_endpoint("http://192.0.2.9:9000").is_err());
        assert!(validate_endpoint("http://127.0.0.1:9000").is_ok());
        assert!(validate_endpoint("https://s3.example.test").is_ok());

        let instance = Uuid::new_v4().to_string();
        let archive = Uuid::new_v4().to_string();
        let expected = format!("fixture/atermius/v1/{instance}/{archive}.atb");
        assert_eq!(
            object_key(Some("fixture"), &instance, &archive).unwrap(),
            expected
        );
        assert_eq!(
            object_key(Some("fixture"), &instance, &archive).unwrap(),
            expected
        );
        assert!(object_key(Some("fixture"), "bad", &archive).is_err());

        assert_eq!(MAX_SINGLE_PUT_BYTES, 64 * 1024 * 1024);
        assert_eq!(
            multipart_part_bytes(MAX_SINGLE_PUT_BYTES),
            MIN_MULTIPART_BYTES
        );
        assert_eq!(
            multipart_part_bytes(MAX_SINGLE_PUT_BYTES + 1),
            MIN_MULTIPART_BYTES
        );
        assert!(
            multipart_part_bytes(crate::backup::MAX_BACKUP_ARCHIVE_BYTES)
                <= MAX_MULTIPART_PART_BYTES
        );
        let part = multipart_part_bytes(crate::backup::MAX_BACKUP_ARCHIVE_BYTES);
        assert!(crate::backup::MAX_BACKUP_ARCHIVE_BYTES.div_ceil(part) <= MAX_MULTIPART_PARTS);
        assert!(is_conditional_write_conflict(Some("PreconditionFailed")));
        assert!(is_conditional_write_conflict(Some(
            "ConditionalRequestConflict"
        )));
        assert!(!is_conditional_write_conflict(Some("AccessDenied")));
        assert!(credentials_error(Some("InvalidAccessKeyId")));
        assert!(!credentials_error(Some("AccessDenied")));
        fs::remove_dir_all(root).unwrap();
    }

    #[tokio::test]
    async fn outbox_attempts_are_durable_and_status_count_excludes_failed_rows() {
        let (state, root, _) = test_state().await;
        let archive_id = Uuid::new_v4().to_string();
        register_archive_before_snapshot(&state, &archive_id, "manual")
            .await
            .unwrap();
        let initial: String = sqlx::query_scalar(
            "SELECT status FROM instance_backup_replications WHERE archive_id=?",
        )
        .bind(&archive_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(initial, "pending_archive");

        let hash = "a".repeat(64);
        archive_created(&state, &archive_id, 1234, &hash)
            .await
            .unwrap();
        let pending = status(&state).await.unwrap();
        assert!(pending.configured);
        assert_eq!(pending.pending_count, 1);
        assert!(pending.latest_attempt.is_none());
        let claim = claim_due(&state).await.unwrap().unwrap();
        assert_eq!(claim.attempt_count, 1);
        assert!(
            ReplicationPersistence::Sqlite(&state)
                .persist_failure(&claim, "remote_unavailable", true)
                .await
                .unwrap()
        );
        let retry = status(&state).await.unwrap();
        assert_eq!(retry.pending_count, 1);
        let attempt = retry.latest_attempt.clone().unwrap();
        assert_eq!(attempt.archive_id, archive_id);
        assert_eq!(attempt.state, "retry_wait");
        assert_eq!(attempt.failure_category, Some("remote_unavailable"));
        let serialized = serde_json::to_string(&retry).unwrap();
        assert!(!serialized.contains("replica-test-bucket"));
        assert!(!serialized.contains("s3-credentials.json"));
        assert!(!serialized.contains("TEST_ACCESS_KEY"));
        assert!(!serialized.contains("TEST_SECRET_KEY"));

        sqlx::query("UPDATE instance_backup_replications SET next_attempt_at=0 WHERE archive_id=?")
            .bind(&archive_id)
            .execute(&state.db)
            .await
            .unwrap();
        let second = claim_due(&state).await.unwrap().unwrap();
        assert_eq!(second.attempt_count, 2);
        assert!(
            ReplicationPersistence::Sqlite(&state)
                .persist_failure(&second, "remote_integrity_mismatch", false)
                .await
                .unwrap()
        );
        assert!(
            !ReplicationPersistence::Sqlite(&state)
                .persist_success(&claim)
                .await
                .unwrap()
        );
        let failed = status(&state).await.unwrap();
        assert_eq!(failed.pending_count, 0);
        assert_eq!(
            failed.latest_attempt.unwrap().failure_category,
            Some("remote_integrity_mismatch")
        );

        let failed_archive_id = Uuid::new_v4().to_string();
        register_archive_before_snapshot(&state, &failed_archive_id, "scheduled")
            .await
            .unwrap();
        archive_creation_failed(&state, &failed_archive_id)
            .await
            .unwrap();
        let failed_category: String = sqlx::query_scalar(
            "SELECT failure_category FROM instance_backup_replications WHERE archive_id=?",
        )
        .bind(&failed_archive_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(failed_category, "archive_unavailable");
        assert_eq!(status(&state).await.unwrap().pending_count, 0);
        state.db.close().await;
        fs::remove_dir_all(root).unwrap();
    }
}

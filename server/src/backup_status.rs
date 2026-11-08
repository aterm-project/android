//! Private, non-secret status for the last `backup` CLI or admin-job attempt.
//!
//! This file is deliberately not part of the encrypted archive manifest. A
//! restored data directory therefore starts with no local backup history.

use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::{ApiError, secure_file};

const STATUS_FILE: &str = "backup-status.json";
const MAX_STATUS_BYTES: u64 = 4096;
const STATUS_SCHEMA_VERSION: u8 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AttemptResult {
    Succeeded,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FailureCategory {
    BackupFailed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Sidecar {
    schema_version: u8,
    operation: String,
    attempted_at: String,
    result: AttemptResult,
    migration_version: Option<i64>,
    archive_bytes: Option<u64>,
    failure_category: Option<FailureCategory>,
    #[serde(default)]
    last_success_at: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BackupStatusAttempt {
    pub attempted_at: String,
    result: AttemptResult,
    pub migration_version: Option<i64>,
    pub archive_bytes: Option<u64>,
    failure_category: Option<FailureCategory>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct BackupStatusResponse {
    pub operation: &'static str,
    pub last_attempt: Option<BackupStatusAttempt>,
}

impl Sidecar {
    fn succeeded(migration_version: i64, archive_bytes: u64) -> Self {
        let attempted_at = Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true);
        Self {
            schema_version: STATUS_SCHEMA_VERSION,
            operation: "backup".to_owned(),
            attempted_at: attempted_at.clone(),
            result: AttemptResult::Succeeded,
            migration_version: Some(migration_version),
            archive_bytes: Some(archive_bytes),
            failure_category: None,
            last_success_at: Some(attempted_at),
        }
    }

    fn failed(last_success_at: Option<String>) -> Self {
        Self {
            schema_version: STATUS_SCHEMA_VERSION,
            operation: "backup".to_owned(),
            attempted_at: Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true),
            result: AttemptResult::Failed,
            migration_version: None,
            archive_bytes: None,
            failure_category: Some(FailureCategory::BackupFailed),
            last_success_at,
        }
    }

    fn validate(&self) -> std::io::Result<()> {
        let valid_timestamp = |value: &str| {
            DateTime::parse_from_rfc3339(value).is_ok_and(|timestamp| timestamp.timestamp() >= 0)
        };
        if !(1..=STATUS_SCHEMA_VERSION).contains(&self.schema_version)
            || self.operation != "backup"
            || !valid_timestamp(&self.attempted_at)
            || self
                .last_success_at
                .as_deref()
                .is_some_and(|value| !valid_timestamp(value))
        {
            return Err(invalid_status());
        }
        let attempt_is_valid = match self.result {
            AttemptResult::Succeeded
                if self.migration_version.is_some_and(|value| value >= 0)
                    && self.archive_bytes.is_some_and(|value| value > 0)
                    && self.failure_category.is_none() =>
            {
                true
            }
            AttemptResult::Failed
                if self.migration_version.is_none()
                    && self.archive_bytes.is_none()
                    && self.failure_category == Some(FailureCategory::BackupFailed) =>
            {
                true
            }
            _ => false,
        };
        if !attempt_is_valid {
            return Err(invalid_status());
        }
        match self.schema_version {
            1 if self.last_success_at.is_some() => Err(invalid_status()),
            1 => Ok(()),
            2 if self.result == AttemptResult::Succeeded
                && self.last_success_at.as_deref() != Some(self.attempted_at.as_str()) =>
            {
                Err(invalid_status())
            }
            2 => Ok(()),
            _ => Err(invalid_status()),
        }
    }

    fn migrate_legacy(mut self) -> Self {
        if self.schema_version == 1 {
            if self.result == AttemptResult::Succeeded {
                self.last_success_at = Some(self.attempted_at.clone());
            }
            self.schema_version = STATUS_SCHEMA_VERSION;
        }
        self
    }

    fn into_api(self) -> BackupStatusAttempt {
        BackupStatusAttempt {
            attempted_at: self.attempted_at,
            result: self.result,
            migration_version: self.migration_version,
            archive_bytes: self.archive_bytes,
            failure_category: self.failure_category,
        }
    }
}

pub fn record_backup_success(
    data_dir: &Path,
    migration_version: i64,
    archive_bytes: u64,
) -> Result<(), ApiError> {
    let sidecar = Sidecar::succeeded(migration_version, archive_bytes);
    write_sidecar(data_dir, &sidecar)
}

pub fn record_backup_failure(data_dir: &Path) -> Result<(), ApiError> {
    let last_success_at = read_sidecar(data_dir)?.and_then(|sidecar| sidecar.last_success_at);
    let sidecar = Sidecar::failed(last_success_at);
    write_sidecar(data_dir, &sidecar)
}

pub(crate) fn read_status(data_dir: &Path) -> Result<BackupStatusResponse, ApiError> {
    let sidecar = read_sidecar(data_dir)?;
    Ok(BackupStatusResponse {
        operation: "backup",
        last_attempt: sidecar.map(|sidecar| sidecar.into_api()),
    })
}

/// Returns the Unix timestamp of the most recently recorded successful local
/// archive creation. It deliberately says nothing about off-host replication
/// or restore verification.
pub(crate) fn last_success_timestamp_seconds(data_dir: &Path) -> Result<Option<i64>, ApiError> {
    read_sidecar(data_dir)?
        .and_then(|sidecar| sidecar.last_success_at)
        .map(|value| {
            DateTime::parse_from_rfc3339(&value)
                .map(|timestamp| timestamp.timestamp())
                .map_err(ApiError::internal)
        })
        .transpose()
}

fn read_sidecar(data_dir: &Path) -> Result<Option<Sidecar>, ApiError> {
    secure_file::secure_existing_data_dir(data_dir)?;
    let path = data_dir.join(STATUS_FILE);
    let file = match open_status_file(&path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(ApiError::internal(error)),
    };
    validate_owner_only_file(&file).map_err(ApiError::internal)?;
    let metadata = file.metadata().map_err(ApiError::internal)?;
    if metadata.len() == 0 || metadata.len() > MAX_STATUS_BYTES {
        return Err(ApiError::internal(invalid_status()));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_STATUS_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(ApiError::internal)?;
    if bytes.len() as u64 > MAX_STATUS_BYTES {
        return Err(ApiError::internal(invalid_status()));
    }
    let sidecar: Sidecar = serde_json::from_slice(&bytes).map_err(ApiError::internal)?;
    sidecar.validate().map_err(ApiError::internal)?;
    Ok(Some(sidecar.migrate_legacy()))
}

fn write_sidecar(data_dir: &Path, sidecar: &Sidecar) -> Result<(), ApiError> {
    secure_file::secure_existing_data_dir(data_dir)?;
    sidecar.validate().map_err(ApiError::internal)?;
    let bytes = serde_json::to_vec(sidecar).map_err(ApiError::internal)?;
    if bytes.len() as u64 > MAX_STATUS_BYTES {
        return Err(ApiError::internal(invalid_status()));
    }

    let target = data_dir.join(STATUS_FILE);
    match fs::symlink_metadata(&target) {
        Ok(metadata) => {
            if !metadata.file_type().is_file() {
                return Err(ApiError::internal(invalid_status()));
            }
            validate_metadata(&metadata).map_err(ApiError::internal)?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(ApiError::internal(error)),
    }

    for _ in 0..4 {
        let temporary = data_dir.join(format!(".{STATUS_FILE}.{}.tmp", Uuid::new_v4()));
        match create_private_temp(&temporary) {
            Ok(mut file) => {
                if let Err(error) = file.write_all(&bytes).and_then(|()| file.sync_all()) {
                    drop(file);
                    let _ = fs::remove_file(&temporary);
                    return Err(ApiError::internal(error));
                }
                drop(file);
                match fs::rename(&temporary, &target) {
                    Ok(()) => {
                        sync_parent(&target).map_err(ApiError::internal)?;
                        return Ok(());
                    }
                    Err(error) => {
                        let _ = fs::remove_file(&temporary);
                        return Err(ApiError::internal(error));
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Err(ApiError::internal(
        "could not allocate private backup status file",
    ))
}

fn create_private_temp(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
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
        if let Err(error) = file.set_permissions(fs::Permissions::from_mode(0o600)) {
            drop(file);
            let _ = fs::remove_file(path);
            return Err(error);
        }
    }
    Ok(file)
}

fn open_status_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    options.open(path)
}

#[cfg(unix)]
fn validate_owner_only_file(file: &File) -> std::io::Result<()> {
    validate_metadata(&file.metadata()?)
}

#[cfg(not(unix))]
fn validate_owner_only_file(_file: &File) -> std::io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_metadata(metadata: &std::fs::Metadata) -> std::io::Result<()> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    if metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o7777 != 0o600
    {
        return Err(invalid_status());
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_metadata(_metadata: &std::fs::Metadata) -> std::io::Result<()> {
    Ok(())
}

fn sync_parent(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        let parent = path.parent().unwrap_or_else(|| Path::new("."));
        return File::open(parent)?.sync_all();
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

fn invalid_status() -> std::io::Error {
    std::io::Error::new(
        std::io::ErrorKind::InvalidData,
        "backup status file is invalid",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn private_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("atermius-backup-status-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        path
    }

    #[test]
    fn status_is_missing_until_backup_attempt_is_recorded() {
        let dir = private_dir();
        assert_eq!(read_status(&dir).unwrap().last_attempt, None);
        assert_eq!(last_success_timestamp_seconds(&dir).unwrap(), None);
        record_backup_success(&dir, 23, 4096).unwrap();
        let status = read_status(&dir).unwrap();
        assert_eq!(status.operation, "backup");
        assert_eq!(status.last_attempt.unwrap().migration_version, Some(23));
        assert!(last_success_timestamp_seconds(&dir).unwrap().is_some());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn failed_attempt_preserves_the_previous_success_timestamp() {
        let dir = private_dir();
        record_backup_success(&dir, 23, 4096).unwrap();
        let last_success = last_success_timestamp_seconds(&dir).unwrap();
        assert!(last_success.is_some());

        record_backup_failure(&dir).unwrap();

        assert_eq!(last_success_timestamp_seconds(&dir).unwrap(), last_success);
        let status = read_status(&dir).unwrap().last_attempt.unwrap();
        assert_eq!(status.result, AttemptResult::Failed);
        assert_eq!(status.migration_version, None);
        assert_eq!(status.archive_bytes, None);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn legacy_success_timestamp_is_migrated_but_legacy_failure_is_unknown() {
        let dir = private_dir();
        let path = dir.join(STATUS_FILE);
        let legacy_success = serde_json::json!({
            "schema_version": 1,
            "operation": "backup",
            "attempted_at": "2020-01-02T03:04:05.000Z",
            "result": "succeeded",
            "migration_version": 23,
            "archive_bytes": 4096,
            "failure_category": null,
        });
        fs::write(&path, serde_json::to_vec(&legacy_success).unwrap()).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }
        assert_eq!(
            last_success_timestamp_seconds(&dir).unwrap(),
            Some(1_577_934_245)
        );
        record_backup_failure(&dir).unwrap();
        let migrated: Sidecar = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        assert_eq!(migrated.schema_version, STATUS_SCHEMA_VERSION);
        assert_eq!(
            migrated.last_success_at.as_deref(),
            Some("2020-01-02T03:04:05.000Z")
        );

        let legacy_failure = serde_json::json!({
            "schema_version": 1,
            "operation": "backup",
            "attempted_at": "2020-01-03T03:04:05.000Z",
            "result": "failed",
            "migration_version": null,
            "archive_bytes": null,
            "failure_category": "backup_failed",
        });
        fs::write(&path, serde_json::to_vec(&legacy_failure).unwrap()).unwrap();
        assert_eq!(last_success_timestamp_seconds(&dir).unwrap(), None);
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn fixed_failure_status_does_not_keep_backup_details() {
        let dir = private_dir();
        record_backup_failure(&dir).unwrap();
        let status = read_status(&dir).unwrap().last_attempt.unwrap();
        assert_eq!(status.result, AttemptResult::Failed);
        assert_eq!(status.migration_version, None);
        assert_eq!(status.archive_bytes, None);
        assert_eq!(status.failure_category, Some(FailureCategory::BackupFailed));
        assert_eq!(read_sidecar(&dir).unwrap().unwrap().last_success_at, None);
        fs::remove_dir_all(dir).unwrap();
    }
}

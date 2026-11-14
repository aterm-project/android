//! Optional server-side storage for client-encrypted attachment objects.
//!
//! This module is deliberately separate from `backup_replication`: object
//! storage is the authoritative byte source for selected object rows, while
//! backup replication stores complete encrypted instance archives.

use std::{
    ffi::OsString,
    fs,
    path::{Path, PathBuf},
    str::FromStr,
    time::Duration,
};

#[cfg(unix)]
use std::{
    ffi::CString,
    os::fd::{AsRawFd, FromRawFd, OwnedFd},
    os::unix::fs::MetadataExt,
    sync::Arc,
};

use aws_config::BehaviorVersion;
use aws_credential_types::Credentials;
use aws_sdk_s3::{Client, config::Region, error::ProvideErrorMetadata};
use aws_smithy_types::byte_stream::ByteStream;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::Utc;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use sqlx::{Row, Sqlite, SqlitePool, Transaction};
use url::Url;
use zeroize::Zeroize;

use crate::{ApiError, Config};

const MAX_CREDENTIAL_FILE_BYTES: u64 = 8192;
const MAX_OPAQUE_OBJECT_BYTES: u64 = 64 * 1024 * 1024;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5 * 60);
const MAX_TRANSFER_DURATION: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Clone)]
pub(crate) enum ObjectStore {
    Sqlite,
    Filesystem(FilesystemBackend),
    S3(S3Backend),
}

#[derive(Clone)]
pub(crate) struct FilesystemBackend {
    #[cfg(unix)]
    root: Arc<OwnedFd>,
    store_id: String,
    #[cfg(test)]
    delete_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
    #[cfg(test)]
    delete_fail_once: Option<std::sync::Arc<std::sync::atomic::AtomicBool>>,
}

#[derive(Clone)]
pub(crate) struct S3Backend {
    client: Client,
    bucket: String,
    prefix: Option<String>,
    store_id: String,
    #[cfg(test)]
    delete_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
}

#[derive(Debug, Clone, Default)]
struct ObjectStoreEnv {
    backend: Option<OsString>,
    bucket: Option<OsString>,
    region: Option<OsString>,
    credentials_file: Option<OsString>,
    endpoint_url: Option<OsString>,
    prefix: Option<OsString>,
    filesystem_root: Option<OsString>,
}

impl ObjectStoreEnv {
    fn from_env() -> Self {
        Self {
            backend: std::env::var_os("ATERMIUS_OBJECT_STORE_BACKEND"),
            bucket: std::env::var_os("ATERMIUS_OBJECT_STORE_S3_BUCKET"),
            region: std::env::var_os("ATERMIUS_OBJECT_STORE_S3_REGION"),
            credentials_file: std::env::var_os("ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_FILE"),
            endpoint_url: std::env::var_os("ATERMIUS_OBJECT_STORE_S3_ENDPOINT_URL"),
            prefix: std::env::var_os("ATERMIUS_OBJECT_STORE_S3_PREFIX"),
            filesystem_root: std::env::var_os("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT"),
        }
    }

    fn migration_target_from_env() -> Self {
        Self {
            backend: std::env::var_os("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND"),
            bucket: std::env::var_os("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_BUCKET"),
            region: std::env::var_os("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_REGION"),
            credentials_file: std::env::var_os(
                "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_CREDENTIALS_FILE",
            ),
            endpoint_url: std::env::var_os(
                "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_ENDPOINT_URL",
            ),
            prefix: std::env::var_os("ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX"),
            filesystem_root: std::env::var_os(
                "ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_FILESYSTEM_ROOT",
            ),
        }
    }
}

#[derive(Debug, Clone)]
struct S3Settings {
    bucket: String,
    region: String,
    credentials_file: PathBuf,
    endpoint_url: Option<String>,
    prefix: Option<String>,
    store_id: String,
}

#[derive(Debug, Clone)]
enum ObjectStoreSettings {
    Sqlite,
    Filesystem(PathBuf),
    S3(S3Settings),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ObjectStoreError {
    Unavailable,
    IntegrityMismatch,
    ImmutableConflict,
}

impl ObjectStore {
    pub(crate) fn from_env(config: &Config) -> Result<Self, ApiError> {
        Self::from_settings(&ObjectStoreEnv::from_env(), config, true)
    }

    pub(crate) fn migration_source_from_env(config: &Config) -> Result<Self, ApiError> {
        Self::from_settings(&ObjectStoreEnv::from_env(), config, false)
    }

    pub(crate) fn migration_target_from_env(
        config: &Config,
        create_filesystem_identity: bool,
    ) -> Result<Self, ApiError> {
        let raw = ObjectStoreEnv::migration_target_from_env();
        if raw.backend.is_none() {
            return Err(config_invalid());
        }
        Self::from_settings(&raw, config, create_filesystem_identity)
    }

    /// Opens the private, per-job filesystem store used by an isolated
    /// PostgreSQL restore stage. The caller creates a new mode-0700 directory
    /// below its private staging root; this constructor gives it a fresh
    /// store identity and never consults the live object-store environment.
    pub(crate) fn restore_target_filesystem(root: &Path) -> Result<Self, ApiError> {
        Ok(Self::Filesystem(make_filesystem_backend(
            root.to_path_buf(),
            true,
        )?))
    }

    fn from_settings(
        raw: &ObjectStoreEnv,
        config: &Config,
        create_filesystem_identity: bool,
    ) -> Result<Self, ApiError> {
        let settings = parse_settings(raw, config)?;
        match settings {
            ObjectStoreSettings::Sqlite => Ok(Self::Sqlite),
            ObjectStoreSettings::Filesystem(root) => Ok(Self::Filesystem(make_filesystem_backend(
                root,
                create_filesystem_identity,
            )?)),
            ObjectStoreSettings::S3(settings) => Ok(Self::S3(make_s3_backend(settings)?)),
        }
    }

    #[cfg(test)]
    pub(crate) fn s3_for_test(endpoint: &str, bucket: &str, region: &str) -> Self {
        Self::s3_for_test_with_prefix(endpoint, bucket, region, None)
    }

    #[cfg(test)]
    pub(crate) fn s3_for_test_with_prefix(
        endpoint: &str,
        bucket: &str,
        region: &str,
        prefix: Option<&str>,
    ) -> Self {
        let provider = Credentials::new(
            "test-access-key",
            "test-secret-key",
            None,
            None,
            "object-store-test-fixture",
        );
        let config = aws_sdk_s3::config::Builder::new()
            .behavior_version(BehaviorVersion::latest())
            .region(Region::new(region.to_owned()))
            .credentials_provider(provider)
            .force_path_style(true)
            .request_checksum_calculation(
                aws_sdk_s3::config::RequestChecksumCalculation::WhenRequired,
            )
            .endpoint_url(endpoint)
            .build();
        Self::S3(S3Backend {
            client: Client::from_conf(config),
            bucket: bucket.to_owned(),
            prefix: prefix.map(str::to_owned),
            store_id: object_store_id(bucket, region, Some(endpoint)),
            delete_pause: None,
        })
    }

    #[cfg(test)]
    pub(crate) fn s3_for_test_with_delete_pause(
        endpoint: &str,
        bucket: &str,
        region: &str,
        delete_pause: std::sync::Arc<crate::recovery::TestPause>,
    ) -> Self {
        let Self::S3(mut backend) = Self::s3_for_test(endpoint, bucket, region) else {
            unreachable!()
        };
        backend.delete_pause = Some(delete_pause);
        Self::S3(backend)
    }

    #[cfg(test)]
    pub(crate) fn filesystem_for_test(root: &Path) -> Self {
        Self::Filesystem(
            make_filesystem_backend(root.to_path_buf(), true)
                .expect("test filesystem object-store root should be secure"),
        )
    }

    #[cfg(test)]
    pub(crate) fn filesystem_for_test_with_delete_pause(
        root: &Path,
        delete_pause: std::sync::Arc<crate::recovery::TestPause>,
    ) -> Self {
        let Self::Filesystem(mut backend) = Self::filesystem_for_test(root) else {
            unreachable!()
        };
        backend.delete_pause = Some(delete_pause);
        Self::Filesystem(backend)
    }

    #[cfg(test)]
    pub(crate) fn filesystem_for_test_with_transient_delete_failure(root: &Path) -> Self {
        let Self::Filesystem(mut backend) = Self::filesystem_for_test(root) else {
            unreachable!()
        };
        backend.delete_fail_once = Some(std::sync::Arc::new(std::sync::atomic::AtomicBool::new(
            true,
        )));
        Self::Filesystem(backend)
    }

    pub(crate) fn is_external(&self) -> bool {
        !matches!(self, Self::Sqlite)
    }

    pub(crate) fn backend_name(&self) -> &'static str {
        match self {
            Self::Sqlite => "sqlite",
            Self::Filesystem(_) => "filesystem",
            Self::S3(_) => "s3",
        }
    }

    pub(crate) fn store_id(&self) -> Option<&str> {
        match self {
            Self::Sqlite => None,
            Self::Filesystem(backend) => Some(&backend.store_id),
            Self::S3(backend) => Some(&backend.store_id),
        }
    }

    /// The S3 prefix is a namespace within a bucket, not part of the store ID
    /// used by existing catalogue rows. Offline migration journals exact keys
    /// and checks this prefix independently on resume.
    pub(crate) fn s3_prefix(&self) -> Option<&str> {
        match self {
            Self::S3(backend) => backend.prefix.as_deref(),
            Self::Sqlite | Self::Filesystem(_) => None,
        }
    }

    pub(crate) fn matches_migration_target(
        &self,
        expected_backend: &str,
        expected_store_id: Option<&str>,
        expected_s3_prefix: Option<&str>,
    ) -> bool {
        let expected_s3_prefix = expected_s3_prefix.filter(|prefix| !prefix.is_empty());
        self.backend_name() == expected_backend
            && self.store_id() == expected_store_id
            && if expected_backend == "s3" {
                self.s3_prefix() == expected_s3_prefix
            } else {
                expected_s3_prefix.is_none()
            }
    }

    /// Refuse to start against S3 object metadata when the required backing
    /// store is missing or points at a different bucket/endpoint identity.
    /// This protects restore/cutover from silently presenting missing bytes.
    pub(crate) async fn validate_catalogue(&self, pool: &SqlitePool) -> Result<(), ApiError> {
        let incomplete_migrations: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_store_migration_jobs WHERE state='copying'",
        )
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
        if incomplete_migrations != 0 {
            return Err(ApiError::internal(
                "user object storage migration is incomplete",
            ));
        }
        let latest_completed_target = sqlx::query(
            "SELECT target_backend,target_store_id,target_s3_prefix FROM object_store_migration_jobs WHERE state='complete' ORDER BY rowid DESC LIMIT 1",
        )
        .fetch_optional(pool)
        .await
        .map_err(ApiError::internal)?;
        if let Some(row) = latest_completed_target {
            let backend: String = row.try_get("target_backend").map_err(ApiError::internal)?;
            let store_id: Option<String> =
                row.try_get("target_store_id").map_err(ApiError::internal)?;
            let s3_prefix: Option<String> = row
                .try_get("target_s3_prefix")
                .map_err(ApiError::internal)?;
            if !self.matches_migration_target(&backend, store_id.as_deref(), s3_prefix.as_deref()) {
                return Err(ApiError::internal(
                    "configured object storage does not match the latest migration target",
                ));
            }
        }
        self.validate_catalogue_contents(pool).await
    }

    /// Validate the configured store against the object catalogue while an
    /// offline migration job is deliberately in its non-serving copy phase.
    pub(crate) async fn validate_catalogue_contents(
        &self,
        pool: &SqlitePool,
    ) -> Result<(), ApiError> {
        let missing_keys: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE storage_backend IN ('s3','filesystem') AND storage_key IS NULL",
        )
        .fetch_one(pool)
        .await
        .map_err(ApiError::internal)?;
        if missing_keys != 0 {
            return Err(ApiError::internal("external object storage key is missing"));
        }
        let configured_backend = self.backend_name();
        let identities: Vec<(String, Option<String>)> = sqlx::query_as(
            "SELECT storage_backend,storage_store_id FROM blob_objects WHERE storage_backend IN ('s3','filesystem') \
             UNION SELECT storage_backend,storage_store_id FROM uploads WHERE storage_backend IN ('s3','filesystem') AND state IN ('open','completing') \
             UNION SELECT storage_backend,storage_store_id FROM object_delete_queue WHERE storage_backend IN ('s3','filesystem')",
        )
        .fetch_all(pool)
        .await
        .map_err(ApiError::internal)?;
        if !identities.is_empty() {
            let mut store_ids = std::collections::HashSet::new();
            for (backend, store_id) in identities {
                if backend != configured_backend {
                    return Err(ApiError::internal(
                        "configured object storage backend does not match stored object metadata",
                    ));
                }
                store_ids.insert(store_id.ok_or_else(|| {
                    ApiError::internal("external object storage identity is missing")
                })?);
            }
            if store_ids.len() != 1 {
                return Err(ApiError::internal(
                    "stored objects reference multiple object storage identities",
                ));
            }
            let expected = store_ids.drain().next().unwrap();
            if self.store_id() != Some(expected.as_str()) {
                return Err(ApiError::internal(
                    "configured object storage does not match stored object metadata",
                ));
            }
        }
        Ok(())
    }

    pub(crate) fn object_key(
        &self,
        instance_id: &str,
        vault_id: &str,
        object_id: &str,
        upload_id: &str,
    ) -> Result<(String, String), ObjectStoreError> {
        if !self.is_external() {
            return Err(ObjectStoreError::Unavailable);
        }
        for value in [instance_id, vault_id, object_id, upload_id] {
            let parsed =
                uuid::Uuid::parse_str(value).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
            if parsed.to_string() != value {
                return Err(ObjectStoreError::IntegrityMismatch);
            }
        }
        let key = format!("atermius/objects/v1/{instance_id}/{vault_id}/{object_id}/{upload_id}");
        let key = match self {
            Self::S3(backend) => backend
                .prefix
                .as_ref()
                .map(|prefix| format!("{prefix}/{key}"))
                .unwrap_or(key),
            Self::Filesystem(_) => key,
            Self::Sqlite => unreachable!(),
        };
        Ok((key, self.store_id().unwrap().to_owned()))
    }

    pub(crate) async fn put_immutable(
        &self,
        key: &str,
        bytes: &[u8],
        expected_size: i64,
        expected_sha256: &str,
    ) -> Result<(), ObjectStoreError> {
        if let Self::Filesystem(backend) = self {
            let size =
                i64::try_from(bytes.len()).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
            if size != expected_size || sha256_hex(bytes) != expected_sha256 {
                return Err(ObjectStoreError::IntegrityMismatch);
            }
            let backend = backend.clone();
            let key = key.to_owned();
            let bytes = bytes.to_vec();
            let digest = expected_sha256.to_owned();
            return tokio::task::spawn_blocking(move || {
                backend.put_immutable(&key, &bytes, &digest)
            })
            .await
            .map_err(|_| ObjectStoreError::Unavailable)?;
        }
        let Self::S3(backend) = self else {
            return Err(ObjectStoreError::Unavailable);
        };
        let size = i64::try_from(bytes.len()).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        if size != expected_size || sha256_hex(bytes) != expected_sha256 {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        let digest =
            hex::decode(expected_sha256).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        let body = ByteStream::from(bytes.to_vec());
        let put = tokio::time::timeout(
            REQUEST_TIMEOUT,
            backend
                .client
                .put_object()
                .bucket(&backend.bucket)
                .key(key)
                .content_length(size)
                .checksum_sha256(STANDARD.encode(digest))
                .metadata("atermius-sha256", expected_sha256)
                .if_none_match("*")
                .body(body)
                .send(),
        )
        .await;
        match put {
            Ok(Ok(_)) => {}
            // A conditional conflict or lost acknowledgement may mean a
            // previous attempt already stored this exact immutable object.
            // Re-read it and accept only byte-identical content.
            Ok(Err(_)) | Err(_) => {
                let Some((remote_size, remote_digest, _)) = head_object(backend, key).await? else {
                    return Err(ObjectStoreError::Unavailable);
                };
                if remote_size != size as u64 || remote_digest != expected_sha256 {
                    return Err(ObjectStoreError::ImmutableConflict);
                }
                let remote = get_object(backend, key, size as u64, expected_sha256, None).await?;
                if remote != bytes {
                    return Err(ObjectStoreError::IntegrityMismatch);
                }
                return Ok(());
            }
        }
        // The provider's acknowledgement is not the durable success boundary:
        // verify the completed object through a full GET before publishing its
        // SQLite catalogue row.
        let remote = get_object(backend, key, size as u64, expected_sha256, None).await?;
        if remote != bytes {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        Ok(())
    }

    pub(crate) async fn read_object(
        &self,
        key: &str,
        expected_size: i64,
        expected_sha256: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>, ObjectStoreError> {
        if let Self::Filesystem(backend) = self {
            let backend = backend.clone();
            let key = key.to_owned();
            let size =
                u64::try_from(expected_size).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
            let digest = expected_sha256.to_owned();
            return tokio::task::spawn_blocking(move || {
                backend.read_object(&key, size, &digest, range)
            })
            .await
            .map_err(|_| ObjectStoreError::Unavailable)?;
        }
        let Self::S3(backend) = self else {
            return Err(ObjectStoreError::Unavailable);
        };
        get_object(
            backend,
            key,
            u64::try_from(expected_size).map_err(|_| ObjectStoreError::IntegrityMismatch)?,
            expected_sha256,
            range,
        )
        .await
    }

    pub(crate) async fn delete_object(
        &self,
        key: &str,
        expected_size: i64,
        expected_sha256: &str,
    ) -> Result<(), ObjectStoreError> {
        if let Self::Filesystem(backend) = self {
            let backend = backend.clone();
            let key = key.to_owned();
            let size =
                u64::try_from(expected_size).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
            let digest = expected_sha256.to_owned();
            return tokio::task::spawn_blocking(move || backend.delete_object(&key, size, &digest))
                .await
                .map_err(|_| ObjectStoreError::Unavailable)?;
        }
        let Self::S3(backend) = self else {
            return Err(ObjectStoreError::Unavailable);
        };
        let Some((remote_size, remote_digest, remote_etag)) = head_object(backend, key).await?
        else {
            return Ok(());
        };
        let expected_size =
            u64::try_from(expected_size).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        if remote_size != expected_size || remote_digest != expected_sha256 {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        let result = tokio::time::timeout(
            REQUEST_TIMEOUT,
            backend
                .client
                .delete_object()
                .bucket(&backend.bucket)
                .key(key)
                .if_match(remote_etag)
                .send(),
        )
        .await
        .map_err(|_| ObjectStoreError::Unavailable)?;
        result.map_err(|error| {
            if error
                .as_service_error()
                .and_then(ProvideErrorMetadata::code)
                == Some("PreconditionFailed")
            {
                ObjectStoreError::IntegrityMismatch
            } else {
                ObjectStoreError::Unavailable
            }
        })?;
        Ok(())
    }

    /// Persist a deletion intent in the caller's transaction. The durable
    /// queue deliberately outlives the Vault/account rows that own the object.
    pub(crate) async fn queue_external_delete_tx(
        tx: &mut Transaction<'_, Sqlite>,
        storage_backend: &str,
        store_id: &str,
        key: &str,
        expected_size: i64,
        expected_sha256: &str,
        now_epoch: i64,
    ) -> Result<(), ApiError> {
        if !matches!(storage_backend, "s3" | "filesystem")
            || expected_size <= 0
            || expected_sha256.len() != 64
            || !expected_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(ApiError::internal(
                "external object deletion metadata is invalid",
            ));
        }
        sqlx::query(
            "INSERT INTO object_delete_queue(queue_id,storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at) \
             VALUES(?,?,?,?,?,?,'pending',0,?,NULL,?) ON CONFLICT(storage_store_id,storage_key) DO NOTHING",
        )
        .bind(uuid::Uuid::new_v4().to_string())
        .bind(storage_backend)
        .bind(key)
        .bind(store_id)
        .bind(expected_size)
        .bind(expected_sha256.to_ascii_lowercase())
        .bind(now_epoch)
        .bind(Utc::now().to_rfc3339())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let existing = sqlx::query(
            "SELECT storage_backend,expected_size,expected_sha256 FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(store_id)
        .bind(key)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("external object deletion intent was not persisted"))?;
        if existing.get::<String, _>("storage_backend") != storage_backend
            || existing.get::<i64, _>("expected_size") != expected_size
            || !existing
                .get::<String, _>("expected_sha256")
                .eq_ignore_ascii_case(expected_sha256)
        {
            return Err(ApiError::internal(
                "external object deletion key has conflicting integrity metadata",
            ));
        }
        Ok(())
    }

    /// Retire expired S3 completions only after recording a delayed delete
    /// intent. The delay exceeds the maximum single transfer window so an
    /// in-flight PUT/verification cannot finish after its tombstone was
    /// already acknowledged as deleted.
    pub(crate) async fn queue_expired_completions_tx(
        &self,
        tx: &mut Transaction<'_, Sqlite>,
        instance_id: &str,
        now_text: &str,
        now_epoch: i64,
    ) -> Result<(), ApiError> {
        if !self.is_external() {
            return Ok(());
        }
        let rows = sqlx::query(
            "SELECT upload_id,vault_id,object_id,expected_size,expected_sha256,storage_store_id,storage_backend \
             FROM uploads WHERE storage_backend IN ('s3','filesystem') AND state='completing' AND expires_at<=?",
        )
        .bind(now_text)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        let had_rows = !rows.is_empty();
        for row in rows {
            let upload_id: String = row.get("upload_id");
            let vault_id: String = row.get("vault_id");
            let object_id: String = row.get("object_id");
            let size: i64 = row.get("expected_size");
            let digest: String = row.get("expected_sha256");
            let storage_backend: String = row.get("storage_backend");
            if storage_backend != self.backend_name() {
                return Err(ApiError::internal(
                    "external upload backend does not match configuration",
                ));
            }
            let store_id: Option<String> = row.get("storage_store_id");
            let store_id = store_id
                .ok_or_else(|| ApiError::internal("external upload storage identity is missing"))?;
            let (key, generated_store_id) = self
                .object_key(instance_id, &vault_id, &object_id, &upload_id)
                .map_err(storage_api_error)?;
            if generated_store_id != store_id {
                return Err(ApiError::internal(
                    "external upload storage identity does not match configuration",
                ));
            }
            Self::queue_external_delete_tx(
                tx,
                &storage_backend,
                &store_id,
                &key,
                size,
                &digest,
                now_epoch.saturating_add(90_000),
            )
            .await?;
        }
        if had_rows {
            sqlx::query("UPDATE uploads SET state='expired' WHERE storage_backend=? AND state='completing' AND expires_at<=?")
                .bind(self.backend_name())
                .bind(now_text)
                .execute(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("DELETE FROM upload_chunks WHERE upload_id IN (SELECT upload_id FROM uploads WHERE storage_backend=? AND state='expired')")
                .bind(self.backend_name())
                .execute(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
        }
        Ok(())
    }

    /// Queue active external completions before a Vault cascade deletes their
    /// reservation rows. Only `completing` rows can have issued a PUT; pending
    /// intents are delayed past the bounded transfer window for crash safety.
    pub(crate) async fn queue_completing_uploads_for_vault_tx(
        &self,
        tx: &mut Transaction<'_, Sqlite>,
        instance_id: &str,
        vault_id: &str,
        now_epoch: i64,
    ) -> Result<(), ApiError> {
        if !self.is_external() {
            return Ok(());
        }
        let rows = sqlx::query(
            "SELECT upload_id,object_id,expected_size,expected_sha256,storage_store_id,storage_backend \
             FROM uploads WHERE vault_id=? AND storage_backend IN ('s3','filesystem') AND state='completing'",
        )
        .bind(vault_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            let upload_id: String = row.get("upload_id");
            let object_id: String = row.get("object_id");
            let size: i64 = row.get("expected_size");
            let digest: String = row.get("expected_sha256");
            let storage_backend: String = row.get("storage_backend");
            if storage_backend != self.backend_name() {
                return Err(ApiError::internal(
                    "external upload backend does not match configuration",
                ));
            }
            let store_id: Option<String> = row.get("storage_store_id");
            let store_id = store_id
                .ok_or_else(|| ApiError::internal("external upload storage identity is missing"))?;
            let (key, generated_store_id) = self
                .object_key(instance_id, vault_id, &object_id, &upload_id)
                .map_err(storage_api_error)?;
            if generated_store_id != store_id {
                return Err(ApiError::internal(
                    "external upload storage identity does not match configuration",
                ));
            }
            Self::queue_external_delete_tx(
                tx,
                &storage_backend,
                &store_id,
                &key,
                size,
                &digest,
                now_epoch.saturating_add(90_000),
            )
            .await?;
        }
        Ok(())
    }

    /// Drain a bounded batch of due delete intents. Provider I/O occurs with
    /// no SQLite transaction held; completion only removes rows after the
    /// provider confirms deletion and the catalogue is still unreferenced.
    pub(crate) async fn drain_delete_queue(
        &self,
        pool: &SqlitePool,
        now_epoch: i64,
        limit: i64,
    ) -> Result<(), ApiError> {
        if !self.is_external() {
            return Ok(());
        }
        let rows = sqlx::query(
            "SELECT queue_id,storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,attempt_count \
             FROM object_delete_queue WHERE state IN ('pending','retry_wait') AND next_attempt_at<=? \
             ORDER BY next_attempt_at,created_at,queue_id LIMIT ?",
        )
        .bind(now_epoch)
        .bind(limit.clamp(1, 100))
        .fetch_all(pool)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            let queue_id: String = row.get("queue_id");
            let storage_backend: String = row.get("storage_backend");
            let key: String = row.get("storage_key");
            let store_id: String = row.get("storage_store_id");
            let size: i64 = row.get("expected_size");
            let digest: String = row.get("expected_sha256");
            let attempt_count: i64 = row.get("attempt_count");
            let result = if storage_backend == self.backend_name()
                && self.store_id() == Some(store_id.as_str())
            {
                self.delete_object(&key, size, &digest).await
            } else {
                Err(ObjectStoreError::IntegrityMismatch)
            };
            match result {
                Ok(()) => {
                    #[cfg(test)]
                    if let Self::S3(backend) = self {
                        if let Some(pause) = backend.delete_pause.as_ref() {
                            pause.pause().await;
                        }
                    }
                    #[cfg(test)]
                    if let Self::Filesystem(backend) = self {
                        if let Some(pause) = backend.delete_pause.as_ref() {
                            pause.pause().await;
                        }
                    }
                    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
                    let current: Option<(String, String, String)> = sqlx::query_as(
                        "SELECT storage_backend,storage_key,storage_store_id FROM object_delete_queue WHERE queue_id=?",
                    )
                    .bind(&queue_id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
                    if current.as_ref().is_some_and(|value| {
                        value.0 == storage_backend && value.1 == key && value.2 == store_id
                    }) {
                        let locked = sqlx::query(
                            "UPDATE object_delete_queue SET attempt_count=attempt_count WHERE queue_id=?",
                        )
                        .bind(&queue_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                        if locked.rows_affected() != 1 {
                            tx.rollback().await.map_err(ApiError::internal)?;
                            continue;
                        }
                        let catalogue: (i64, Option<String>, i64) = sqlx::query_as(
                            "SELECT COUNT(*),MIN(storage_state),COALESCE(SUM(EXISTS(\
                             SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id)),0) \
                             FROM blob_objects b WHERE b.storage_backend=? AND b.storage_key=? AND b.storage_store_id=?",
                        )
                        .bind(&storage_backend)
                        .bind(&key)
                        .bind(&store_id)
                        .fetch_one(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                        let safe_to_retire = catalogue.0 == 0
                            || (catalogue.0 == 1
                                && catalogue.1.as_deref() == Some("deleting")
                                && catalogue.2 == 0);
                        if !safe_to_retire {
                            // The provider has already deleted the key, but a
                            // live/reachable catalogue entry appeared or its
                            // state is inconsistent. Preserve the durable
                            // evidence and fail closed for operator repair.
                            sqlx::query(
                                "UPDATE object_delete_queue SET state='quarantined',attempt_count=attempt_count+1,next_attempt_at=?,last_failure_category='integrity_mismatch' WHERE queue_id=?",
                            )
                            .bind(now_epoch)
                            .bind(&queue_id)
                            .execute(&mut *tx)
                            .await
                            .map_err(ApiError::internal)?;
                            tx.commit().await.map_err(ApiError::internal)?;
                            continue;
                        }
                        sqlx::query(
                            "UPDATE uploads SET state='collected' WHERE state='completed' AND EXISTS (\
                             SELECT 1 FROM blob_objects b WHERE b.vault_id=uploads.vault_id AND b.object_id=uploads.object_id \
                             AND b.storage_backend=? AND b.storage_key=? AND b.storage_store_id=? \
                             AND b.storage_state='deleting' AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id))",
                        )
                        .bind(&storage_backend)
                        .bind(&key)
                        .bind(&store_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                        let deleted = sqlx::query(
                            "DELETE FROM blob_objects WHERE storage_backend=? AND storage_state='deleting' AND storage_key=? AND storage_store_id=? \
                             AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=blob_objects.vault_id AND r.object_id=blob_objects.object_id)",
                        )
                        .bind(&storage_backend)
                        .bind(&key)
                        .bind(&store_id)
                        .execute(&mut *tx)
                        .await
                        .map_err(ApiError::internal)?;
                        if deleted.rows_affected() != catalogue.0 as u64 {
                            sqlx::query(
                                "UPDATE object_delete_queue SET state='quarantined',attempt_count=attempt_count+1,next_attempt_at=?,last_failure_category='integrity_mismatch' WHERE queue_id=?",
                            )
                            .bind(now_epoch)
                            .bind(&queue_id)
                            .execute(&mut *tx)
                            .await
                            .map_err(ApiError::internal)?;
                            tx.commit().await.map_err(ApiError::internal)?;
                            continue;
                        }
                        sqlx::query("DELETE FROM object_delete_queue WHERE queue_id=?")
                            .bind(&queue_id)
                            .execute(&mut *tx)
                            .await
                            .map_err(ApiError::internal)?;
                    }
                    tx.commit().await.map_err(ApiError::internal)?;
                }
                Err(error) => {
                    let quarantined = error == ObjectStoreError::IntegrityMismatch;
                    let next_attempt = if quarantined {
                        now_epoch
                    } else {
                        let delay = 1_i64
                            .checked_shl(attempt_count.clamp(0, 16) as u32)
                            .unwrap_or(86_400)
                            .min(86_400);
                        now_epoch.saturating_add(delay)
                    };
                    sqlx::query(
                        "UPDATE object_delete_queue SET state=?,attempt_count=attempt_count+1,next_attempt_at=?,last_failure_category=? WHERE queue_id=?",
                    )
                    .bind(if quarantined { "quarantined" } else { "retry_wait" })
                    .bind(next_attempt)
                    .bind(if quarantined { "integrity_mismatch" } else { "remote_unavailable" })
                    .bind(&queue_id)
                    .execute(pool)
                    .await
                    .map_err(ApiError::internal)?;
                }
            }
        }
        Ok(())
    }

    /// Download and validate an external object into a SQLite backup snapshot.
    /// The archive therefore remains self-contained and restores as a local
    /// SQLite-backed instance even when the original object store is unavailable.
    pub(crate) async fn hydrate_for_backup(&self, snapshot_url: &str) -> Result<(), ApiError> {
        if !self.is_external() {
            return Ok(());
        }
        let options = sqlx::sqlite::SqliteConnectOptions::from_str(snapshot_url)
            .map_err(ApiError::internal)?
            .foreign_keys(true);
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect_with(options)
            .await
            .map_err(ApiError::internal)?;
        // Objects already in the durable delete phase have no live reference;
        // exclude them from the logical backup snapshot. Their source outbox
        // must not be replayed by a restored copy.
        sqlx::query(
            "UPDATE uploads SET state='collected' WHERE state='completed' AND EXISTS (\
             SELECT 1 FROM blob_objects b WHERE b.vault_id=uploads.vault_id AND b.object_id=uploads.object_id \
             AND b.storage_backend IN ('s3','filesystem') AND b.storage_state='deleting' \
             AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id))",
        )
        .execute(&pool)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "DELETE FROM blob_objects WHERE storage_backend IN ('s3','filesystem') AND storage_state='deleting' \
             AND NOT EXISTS (SELECT 1 FROM object_references r WHERE r.vault_id=blob_objects.vault_id AND r.object_id=blob_objects.object_id)",
        )
        .execute(&pool)
        .await
        .map_err(ApiError::internal)?;
        let referenced_deleting: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE storage_backend IN ('s3','filesystem') AND storage_state='deleting'",
        )
        .fetch_one(&pool)
        .await
        .map_err(ApiError::internal)?;
        if referenced_deleting != 0 {
            pool.close().await;
            return Err(storage_api_error(ObjectStoreError::IntegrityMismatch));
        }
        let rows = sqlx::query(
            "SELECT vault_id,object_id,storage_key,storage_store_id,size,sha256,storage_backend FROM blob_objects \
             WHERE storage_backend IN ('s3','filesystem') AND storage_state='available' ORDER BY vault_id,object_id",
        )
        .fetch_all(&pool)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            use sqlx::Row;
            let vault: String = row.get("vault_id");
            let object: String = row.get("object_id");
            let key: String = row.get("storage_key");
            let store_id: String = row.get("storage_store_id");
            let size: i64 = row.get("size");
            let digest: String = row.get("sha256");
            if self.store_id() != Some(store_id.as_str()) {
                pool.close().await;
                return Err(ApiError::internal(
                    "configured object storage does not match backup metadata",
                ));
            }
            let bytes = self
                .read_object(&key, size, &digest, None)
                .await
                .map_err(storage_api_error)?;
            let row_backend: String = row.get("storage_backend");
            if row_backend != self.backend_name() {
                pool.close().await;
                return Err(ApiError::internal(
                    "configured object storage backend does not match backup metadata",
                ));
            }
            sqlx::query(
                "UPDATE blob_objects SET bytes=?,storage_backend='sqlite',storage_key=NULL,storage_store_id=NULL,storage_state='available' \
                 WHERE vault_id=? AND object_id=? AND storage_backend=?",
            )
            .bind(&bytes)
            .bind(&vault)
            .bind(&object)
            .bind(&row_backend)
            .execute(&pool)
            .await
                .map_err(ApiError::internal)?;
        }
        let remaining_external: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE storage_backend IN ('s3','filesystem')",
        )
        .fetch_one(&pool)
        .await
        .map_err(ApiError::internal)?;
        if remaining_external != 0 {
            pool.close().await;
            return Err(storage_api_error(ObjectStoreError::IntegrityMismatch));
        }
        // Pending provider deletions belong to the source deployment. Do not
        // replay them from a restored copy that shares the same bucket.
        sqlx::query("DELETE FROM object_delete_queue WHERE storage_backend IN ('s3','filesystem')")
            .execute(&pool)
            .await
            .map_err(ApiError::internal)?;
        // In-flight upload chunks are already in the snapshot database. Make
        // their resumed completion local so restore does not depend on a
        // possibly different S3 bucket or endpoint.
        sqlx::query(
            "UPDATE uploads SET state='open',storage_backend='sqlite',storage_store_id=NULL \
             WHERE state IN ('open','completing') AND storage_backend IN ('s3','filesystem')",
        )
        .execute(&pool)
        .await
        .map_err(ApiError::internal)?;
        // The archive snapshot is now a self-contained SQLite-backed instance.
        // Completed migration journals describe the source deployment's active
        // target and must not force a restored archive to reconfigure that
        // external store. These operational checkpoints are intentionally not
        // carried into the hydrated snapshot.
        sqlx::query("DELETE FROM object_store_migration_items")
            .execute(&pool)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM object_store_migration_jobs")
            .execute(&pool)
            .await
            .map_err(ApiError::internal)?;
        pool.close().await;
        Ok(())
    }
}

async fn head_object(
    backend: &S3Backend,
    key: &str,
) -> Result<Option<(u64, String, String)>, ObjectStoreError> {
    let response = tokio::time::timeout(
        REQUEST_TIMEOUT,
        backend
            .client
            .head_object()
            .bucket(&backend.bucket)
            .key(key)
            .send(),
    )
    .await
    .map_err(|_| ObjectStoreError::Unavailable)?;
    match response {
        Ok(head) => {
            let size = head
                .content_length()
                .and_then(|value| u64::try_from(value).ok())
                .ok_or(ObjectStoreError::IntegrityMismatch)?;
            let digest = head
                .metadata()
                .and_then(|metadata| metadata.get("atermius-sha256"))
                .cloned()
                .ok_or(ObjectStoreError::IntegrityMismatch)?;
            let etag = head
                .e_tag()
                .map(str::to_owned)
                .ok_or(ObjectStoreError::IntegrityMismatch)?;
            Ok(Some((size, digest, etag)))
        }
        Err(error) if is_missing(&error) => Ok(None),
        Err(_) => Err(ObjectStoreError::Unavailable),
    }
}

async fn get_object(
    backend: &S3Backend,
    key: &str,
    expected_size: u64,
    expected_sha256: &str,
    range: Option<(u64, u64)>,
) -> Result<Vec<u8>, ObjectStoreError> {
    if expected_size == 0 || expected_size > MAX_OPAQUE_OBJECT_BYTES {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    let mut request = backend.client.get_object().bucket(&backend.bucket).key(key);
    let expected_response_size = if let Some((start, end)) = range {
        let length = end
            .checked_sub(start)
            .and_then(|value| value.checked_add(1))
            .ok_or(ObjectStoreError::IntegrityMismatch)?;
        if end >= expected_size {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        request = request.range(format!("bytes={start}-{end}"));
        length
    } else {
        expected_size
    };
    let response = tokio::time::timeout(REQUEST_TIMEOUT, request.send())
        .await
        .map_err(|_| ObjectStoreError::Unavailable)?
        .map_err(|_| ObjectStoreError::Unavailable)?;
    if response
        .metadata()
        .and_then(|metadata| metadata.get("atermius-sha256"))
        .map(String::as_str)
        != Some(expected_sha256)
    {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    if response
        .content_length()
        .and_then(|value| u64::try_from(value).ok())
        != Some(expected_response_size)
    {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    if let Some((start, end)) = range {
        let expected_content_range = format!("bytes {start}-{end}/{expected_size}");
        if response.content_range() != Some(expected_content_range.as_str()) {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
    }
    let mut stream = response.body;
    let body = tokio::time::timeout(MAX_TRANSFER_DURATION, async {
        let capacity = usize::try_from(expected_response_size)
            .map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        let mut body = Vec::with_capacity(capacity);
        while let Some(chunk) = stream
            .try_next()
            .await
            .map_err(|_| ObjectStoreError::Unavailable)?
        {
            if body.len().saturating_add(chunk.len()) > capacity {
                return Err(ObjectStoreError::IntegrityMismatch);
            }
            body.extend_from_slice(&chunk);
        }
        Ok(body)
    })
    .await
    .map_err(|_| ObjectStoreError::Unavailable)??;
    if body.len() as u64 != expected_response_size {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    if range.is_none() && sha256_hex(&body) != expected_sha256 {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    Ok(body)
}

fn is_missing<E, R>(error: &aws_sdk_s3::error::SdkError<E, R>) -> bool
where
    E: ProvideErrorMetadata,
{
    matches!(
        error
            .as_service_error()
            .and_then(ProvideErrorMetadata::code),
        Some("NoSuchKey" | "NotFound" | "404")
    )
}

fn parse_settings(raw: &ObjectStoreEnv, config: &Config) -> Result<ObjectStoreSettings, ApiError> {
    let backend = match raw.backend.as_ref() {
        None => "sqlite",
        Some(value) => {
            let value = value.to_str().ok_or_else(config_invalid)?;
            if value.is_empty() || value.trim() != value {
                return Err(config_invalid());
            }
            value
        }
    };
    let any_s3 = raw.bucket.is_some()
        || raw.region.is_some()
        || raw.credentials_file.is_some()
        || raw.endpoint_url.is_some()
        || raw.prefix.is_some();
    let any_filesystem = raw.filesystem_root.is_some();
    match backend {
        "sqlite" if !any_s3 && !any_filesystem => Ok(ObjectStoreSettings::Sqlite),
        "sqlite" => Err(config_invalid()),
        "filesystem" if !any_s3 => {
            let root = required_string(&raw.filesystem_root)?;
            let root = PathBuf::from(root);
            let root = validate_filesystem_root(config, &root)?;
            Ok(ObjectStoreSettings::Filesystem(root))
        }
        "s3" if !any_filesystem => {
            let bucket = required_string(&raw.bucket)?;
            let region = required_string(&raw.region)?;
            let credentials_path = required_string(&raw.credentials_file)?;
            let endpoint_url = optional_string(&raw.endpoint_url)?;
            let prefix = optional_string(&raw.prefix)?;
            validate_bucket(&bucket)?;
            validate_region(&region)?;
            if let Some(endpoint) = endpoint_url.as_deref() {
                validate_endpoint(endpoint)?;
            }
            if let Some(prefix) = prefix.as_deref() {
                validate_prefix(prefix)?;
            }
            let credentials_file = PathBuf::from(credentials_path);
            validate_credentials_path(config, &credentials_file)?;
            let store_id = object_store_id(&bucket, &region, endpoint_url.as_deref());
            Ok(ObjectStoreSettings::S3(S3Settings {
                bucket,
                region,
                credentials_file,
                endpoint_url,
                prefix,
                store_id,
            }))
        }
        _ => Err(config_invalid()),
    }
}

fn validate_filesystem_root(config: &Config, root: &Path) -> Result<PathBuf, ApiError> {
    if !root.is_absolute()
        || root == Path::new("/")
        || root.components().any(|component| {
            matches!(
                component,
                std::path::Component::CurDir | std::path::Component::ParentDir
            )
        })
    {
        return Err(config_invalid());
    }
    let text = root.to_str().ok_or_else(config_invalid)?;
    if text.is_empty() || text.len() > 1024 || text.ends_with('/') && text != "/" {
        return Err(config_invalid());
    }
    // Check every component before canonicalization so a symlink in an
    // ancestor cannot silently redirect the configured storage root.
    let mut component_path = PathBuf::from("/");
    for component in root.components().skip(1) {
        let std::path::Component::Normal(name) = component else {
            return Err(config_invalid());
        };
        component_path.push(name);
        let metadata = fs::symlink_metadata(&component_path).map_err(|_| config_invalid())?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            return Err(config_invalid());
        }
    }
    let canonical = fs::canonicalize(root).map_err(|_| config_invalid())?;
    if canonical != root {
        return Err(config_invalid());
    }
    let data_dir = fs::canonicalize(&config.data_dir).map_err(|_| config_invalid())?;
    if canonical.starts_with(&data_dir) || data_dir.starts_with(&canonical) {
        return Err(config_invalid());
    }
    Ok(canonical)
}

fn make_s3_backend(settings: S3Settings) -> Result<S3Backend, ApiError> {
    let bytes = crate::secure_file::read_private_secret_file(
        &settings.credentials_file,
        MAX_CREDENTIAL_FILE_BYTES,
    )
    .map_err(|_| config_invalid())?;
    let mut credentials: CredentialsDocument =
        serde_json::from_slice(&bytes).map_err(|_| config_invalid())?;
    if credentials.access_key_id.is_empty()
        || credentials.secret_access_key.is_empty()
        || credentials.access_key_id.len() > 256
        || credentials.secret_access_key.len() > 2048
        || credentials
            .session_token
            .as_ref()
            .is_some_and(|token| token.is_empty() || token.len() > 4096)
    {
        return Err(config_invalid());
    }
    let provider = Credentials::new(
        credentials.access_key_id.clone(),
        credentials.secret_access_key.clone(),
        credentials.session_token.clone(),
        None,
        "atermius-object-store-credentials-file",
    );
    credentials.access_key_id.zeroize();
    credentials.secret_access_key.zeroize();
    if let Some(token) = &mut credentials.session_token {
        token.zeroize();
    }
    // Build from only the explicit private-file credentials and validated
    // region/endpoint. Never consult ambient profiles or endpoint variables.
    let mut builder = aws_sdk_s3::config::Builder::new()
        .behavior_version(BehaviorVersion::latest())
        .region(Region::new(settings.region))
        .credentials_provider(provider)
        .request_checksum_calculation(aws_sdk_s3::config::RequestChecksumCalculation::WhenRequired)
        .force_path_style(true);
    if let Some(endpoint) = settings.endpoint_url {
        builder = builder.endpoint_url(endpoint);
    }
    Ok(S3Backend {
        client: Client::from_conf(builder.build()),
        bucket: settings.bucket,
        prefix: settings.prefix,
        store_id: settings.store_id,
        #[cfg(test)]
        delete_pause: None,
    })
}

#[cfg(unix)]
fn make_filesystem_backend(
    root_path: PathBuf,
    create_store_identity: bool,
) -> Result<FilesystemBackend, ApiError> {
    let root = open_absolute_directory(&root_path).map_err(|_| config_invalid())?;
    let stat = fstat_fd(root.as_raw_fd()).map_err(|_| config_invalid())?;
    let owner = unsafe { libc::geteuid() };
    let mode = stat.st_mode & 0o777;
    if stat.st_uid != owner || mode & 0o077 != 0 || mode & 0o700 != 0o700 {
        return Err(config_invalid());
    }
    let store_id = if create_store_identity {
        load_or_create_store_id(root.as_raw_fd())
    } else {
        read_existing_store_id(root.as_raw_fd())
    }
    .map_err(|_| config_invalid())?;
    Ok(FilesystemBackend {
        root: Arc::new(root),
        store_id,
        #[cfg(test)]
        delete_pause: None,
        #[cfg(test)]
        delete_fail_once: None,
    })
}

#[cfg(not(unix))]
fn make_filesystem_backend(
    _root_path: PathBuf,
    _create_store_identity: bool,
) -> Result<FilesystemBackend, ApiError> {
    Err(config_invalid())
}

#[cfg(unix)]
fn open_absolute_directory(path: &Path) -> std::io::Result<OwnedFd> {
    let root_name = CString::new("/").expect("static path has no NUL");
    let root = unsafe {
        libc::open(
            root_name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if root < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut current = unsafe { OwnedFd::from_raw_fd(root) };
    for component in path.components().skip(1) {
        let std::path::Component::Normal(name) = component else {
            return Err(std::io::Error::from(std::io::ErrorKind::InvalidInput));
        };
        let name = CString::new(name.as_encoded_bytes())
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
        let fd = unsafe {
            libc::openat(
                current.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        current = unsafe { OwnedFd::from_raw_fd(fd) };
    }
    Ok(current)
}

#[cfg(unix)]
fn fstat_fd(fd: std::os::fd::RawFd) -> std::io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe { libc::fstat(fd, stat.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

#[cfg(unix)]
fn load_or_create_store_id(root_fd: std::os::fd::RawFd) -> std::io::Result<String> {
    const MARKER: &str = ".atermius-store-id";
    let marker = CString::new(MARKER).expect("static path has no NUL");
    let fd = unsafe {
        libc::openat(
            root_fd,
            marker.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd >= 0 {
        return read_store_id(fd);
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() != Some(libc::ENOENT) {
        return Err(error);
    }
    let id = uuid::Uuid::new_v4().to_string();
    let temporary_name = format!(".atermius-store-id-{}.tmp", uuid::Uuid::new_v4());
    let temporary = CString::new(temporary_name.as_str())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let temp_fd = unsafe {
        libc::openat(
            root_fd,
            temporary.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            0o600,
        )
    };
    if temp_fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    let mut file = unsafe { fs::File::from_raw_fd(temp_fd) };
    use std::io::Write as _;
    file.write_all(id.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    let linked = unsafe { libc::linkat(root_fd, temporary.as_ptr(), root_fd, marker.as_ptr(), 0) };
    let link_error = if linked == 0 {
        None
    } else {
        Some(std::io::Error::last_os_error())
    };
    unsafe {
        libc::unlinkat(root_fd, temporary.as_ptr(), 0);
    }
    if linked == 0 {
        if unsafe { libc::fsync(root_fd) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
        let fd = unsafe {
            libc::openat(
                root_fd,
                marker.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        return read_store_id(fd);
    }
    if link_error.as_ref().and_then(std::io::Error::raw_os_error) == Some(libc::EEXIST) {
        let fd = unsafe {
            libc::openat(
                root_fd,
                marker.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        return read_store_id(fd);
    }
    Err(link_error.expect("link failure has an OS error"))
}

#[cfg(unix)]
fn read_existing_store_id(root_fd: std::os::fd::RawFd) -> std::io::Result<String> {
    const MARKER: &str = ".atermius-store-id";
    let marker = CString::new(MARKER).expect("static path has no NUL");
    let fd = unsafe {
        libc::openat(
            root_fd,
            marker.as_ptr(),
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error());
    }
    read_store_id(fd)
}

#[cfg(unix)]
fn read_store_id(fd: std::os::fd::RawFd) -> std::io::Result<String> {
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    let stat = fstat_fd(owned.as_raw_fd())?;
    if stat.st_mode & libc::S_IFMT != libc::S_IFREG
        || stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & 0o777 != 0o600
        || stat.st_nlink != 1
        || stat.st_size < 1
        || stat.st_size > 64
    {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
    }
    let mut file = fs::File::from(owned);
    let mut bytes = Vec::with_capacity(stat.st_size as usize);
    use std::io::Read as _;
    file.read_to_end(&mut bytes)?;
    let text = std::str::from_utf8(&bytes)
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?
        .strip_suffix('\n')
        .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
    let parsed = uuid::Uuid::parse_str(text)
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
    if parsed.to_string() != text {
        return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
    }
    Ok(text.to_owned())
}

#[cfg(unix)]
impl FilesystemBackend {
    fn put_immutable(
        &self,
        key: &str,
        bytes: &[u8],
        expected_sha256: &str,
    ) -> Result<(), ObjectStoreError> {
        let (parent, basename) = self.open_key_parent(key, true)?;
        let temp_name = format!(".object-{}.tmp", uuid::Uuid::new_v4());
        let temp = c_name(&temp_name)?;
        let final_name = c_name(&basename)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                temp.as_ptr(),
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(classify_fs_error(std::io::Error::last_os_error()));
        }
        let mut file = unsafe { fs::File::from_raw_fd(fd) };
        use std::io::{Read as _, Seek as _, SeekFrom, Write as _};
        let write_result = (|| {
            file.write_all(bytes)?;
            file.sync_all()?;
            file.seek(SeekFrom::Start(0))?;
            let cap = bytes
                .len()
                .checked_add(1)
                .ok_or_else(|| std::io::Error::from(std::io::ErrorKind::InvalidData))?;
            let mut verified = Vec::with_capacity(cap);
            std::io::Read::by_ref(&mut file)
                .take(cap as u64)
                .read_to_end(&mut verified)?;
            if verified != bytes || sha256_hex(&verified) != expected_sha256 {
                return Err(std::io::Error::from(std::io::ErrorKind::InvalidData));
            }
            Ok(())
        })();
        drop(file);
        if let Err(error) = write_result {
            unsafe {
                libc::unlinkat(parent.as_raw_fd(), temp.as_ptr(), 0);
            }
            return Err(classify_fs_error(error));
        }
        let linked = unsafe {
            libc::linkat(
                parent.as_raw_fd(),
                temp.as_ptr(),
                parent.as_raw_fd(),
                final_name.as_ptr(),
                0,
            )
        };
        let link_error = (linked != 0).then(std::io::Error::last_os_error);
        let temp_unlinked = unsafe { libc::unlinkat(parent.as_raw_fd(), temp.as_ptr(), 0) } == 0;
        if linked == 0 {
            if !temp_unlinked {
                let rolled_back =
                    unsafe { libc::unlinkat(parent.as_raw_fd(), final_name.as_ptr(), 0) } == 0;
                unsafe {
                    libc::fsync(parent.as_raw_fd());
                }
                return Err(if rolled_back {
                    ObjectStoreError::Unavailable
                } else {
                    ObjectStoreError::IntegrityMismatch
                });
            }
            if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
                return Err(ObjectStoreError::Unavailable);
            }
            return Ok(());
        }
        if !temp_unlinked {
            return Err(ObjectStoreError::Unavailable);
        }
        let error = link_error.expect("link failure has an OS error");
        if error.raw_os_error() == Some(libc::EEXIST) {
            let existing = self.read_existing_file(key)?;
            if existing == bytes {
                if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
                    return Err(ObjectStoreError::Unavailable);
                }
                return Ok(());
            }
            return Err(ObjectStoreError::ImmutableConflict);
        }
        Err(classify_fs_error(error))
    }

    fn read_existing_file(&self, key: &str) -> Result<Vec<u8>, ObjectStoreError> {
        let (parent, basename) = self.open_key_parent(key, false)?;
        let name = c_name(&basename)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(classify_fs_error(std::io::Error::last_os_error()));
        }
        let file = unsafe { fs::File::from_raw_fd(fd) };
        let metadata = file.metadata().map_err(classify_fs_error)?;
        if !metadata.is_file()
            || metadata.nlink() != 1
            || metadata.len() == 0
            || metadata.len() > MAX_OPAQUE_OBJECT_BYTES
        {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        use std::io::Read as _;
        let cap =
            usize::try_from(metadata.len() + 1).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        let mut bytes = Vec::with_capacity(cap);
        file.take(cap as u64)
            .read_to_end(&mut bytes)
            .map_err(classify_fs_error)?;
        if bytes.len() as u64 != metadata.len() {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        Ok(bytes)
    }

    fn read_object(
        &self,
        key: &str,
        expected_size: u64,
        expected_sha256: &str,
        range: Option<(u64, u64)>,
    ) -> Result<Vec<u8>, ObjectStoreError> {
        if expected_size == 0 || expected_size > MAX_OPAQUE_OBJECT_BYTES {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        let (parent, basename) = self.open_key_parent(key, false)?;
        let name = c_name(&basename)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            return Err(classify_fs_error(std::io::Error::last_os_error()));
        }
        let mut file = unsafe { fs::File::from_raw_fd(fd) };
        let metadata = file.metadata().map_err(classify_fs_error)?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != expected_size {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        use std::io::{Read as _, Seek as _, SeekFrom};
        if let Some((start, end)) = range {
            if start > end || end >= expected_size {
                return Err(ObjectStoreError::IntegrityMismatch);
            }
            let len = usize::try_from(end - start + 1)
                .map_err(|_| ObjectStoreError::IntegrityMismatch)?;
            file.seek(SeekFrom::Start(start))
                .map_err(classify_fs_error)?;
            let mut bytes = vec![0; len];
            file.read_exact(&mut bytes).map_err(classify_fs_error)?;
            return Ok(bytes);
        }
        let cap = expected_size
            .checked_add(1)
            .and_then(|size| usize::try_from(size).ok())
            .ok_or(ObjectStoreError::IntegrityMismatch)?;
        let mut bytes = Vec::with_capacity(cap);
        file.take(cap as u64)
            .read_to_end(&mut bytes)
            .map_err(classify_fs_error)?;
        if bytes.len() as u64 != expected_size || sha256_hex(&bytes) != expected_sha256 {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        Ok(bytes)
    }

    fn delete_object(
        &self,
        key: &str,
        expected_size: u64,
        expected_sha256: &str,
    ) -> Result<(), ObjectStoreError> {
        #[cfg(test)]
        if self
            .delete_fail_once
            .as_ref()
            .is_some_and(|failure| failure.swap(false, std::sync::atomic::Ordering::SeqCst))
        {
            return Err(ObjectStoreError::Unavailable);
        }
        if expected_size == 0 || expected_size > MAX_OPAQUE_OBJECT_BYTES {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        let (parent, basename) = match self.open_key_parent(key, false) {
            Ok(parent) => parent,
            Err(error) => return Err(error),
        };
        let name = c_name(&basename)?;
        let fd = unsafe {
            libc::openat(
                parent.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK,
            )
        };
        if fd < 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENOENT) {
                return Ok(());
            }
            return Err(classify_fs_error(error));
        }
        let mut file = unsafe { fs::File::from_raw_fd(fd) };
        let metadata = file.metadata().map_err(classify_fs_error)?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.len() != expected_size {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        use std::io::Read as _;
        let cap = expected_size
            .checked_add(1)
            .and_then(|size| usize::try_from(size).ok())
            .ok_or(ObjectStoreError::IntegrityMismatch)?;
        let mut bytes = Vec::with_capacity(cap);
        file.by_ref()
            .take(cap as u64)
            .read_to_end(&mut bytes)
            .map_err(classify_fs_error)?;
        if bytes.len() as u64 != expected_size || sha256_hex(&bytes) != expected_sha256 {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        let opened_stat = fstat_fd(file.as_raw_fd()).map_err(classify_fs_error)?;
        let current_stat =
            fstatat_nofollow(parent.as_raw_fd(), &name).map_err(classify_fs_error)?;
        if opened_stat.st_dev != current_stat.st_dev
            || opened_stat.st_ino != current_stat.st_ino
            || current_stat.st_mode & libc::S_IFMT != libc::S_IFREG
        {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(classify_fs_error(std::io::Error::last_os_error()));
        }
        if unsafe { libc::fsync(parent.as_raw_fd()) } != 0 {
            return Err(ObjectStoreError::Unavailable);
        }
        Ok(())
    }

    fn open_key_parent(
        &self,
        key: &str,
        create: bool,
    ) -> Result<(OwnedFd, String), ObjectStoreError> {
        let parts = parse_object_key(key)?;
        let mut current = duplicate_fd(self.root.as_raw_fd())?;
        for part in &parts[..parts.len() - 1] {
            current = if create {
                open_or_create_child_dir(current.as_raw_fd(), part)?
            } else {
                open_child_dir(current.as_raw_fd(), part)?
            };
        }
        Ok((current, parts.last().unwrap().clone()))
    }
}

#[cfg(unix)]
fn parse_object_key(key: &str) -> Result<Vec<String>, ObjectStoreError> {
    let parts = key.split('/').collect::<Vec<_>>();
    if parts.len() != 7 || parts[..3] != ["atermius", "objects", "v1"] {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    let mut result = parts[..3]
        .iter()
        .map(|part| (*part).to_owned())
        .collect::<Vec<_>>();
    for part in &parts[3..] {
        let parsed =
            uuid::Uuid::parse_str(part).map_err(|_| ObjectStoreError::IntegrityMismatch)?;
        if parsed.to_string() != *part {
            return Err(ObjectStoreError::IntegrityMismatch);
        }
        result.push((*part).to_owned());
    }
    Ok(result)
}

#[cfg(unix)]
fn c_name(name: &str) -> Result<CString, ObjectStoreError> {
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    CString::new(name).map_err(|_| ObjectStoreError::IntegrityMismatch)
}

#[cfg(unix)]
fn duplicate_fd(fd: std::os::fd::RawFd) -> Result<OwnedFd, ObjectStoreError> {
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 0) };
    if duplicate < 0 {
        return Err(classify_fs_error(std::io::Error::last_os_error()));
    }
    Ok(unsafe { OwnedFd::from_raw_fd(duplicate) })
}

#[cfg(unix)]
fn open_child_dir(parent: std::os::fd::RawFd, name: &str) -> Result<OwnedFd, ObjectStoreError> {
    let name = c_name(name)?;
    let fd = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(classify_fs_error(std::io::Error::last_os_error()));
    }
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    let stat = fstat_fd(owned.as_raw_fd()).map_err(classify_fs_error)?;
    if stat.st_uid != unsafe { libc::geteuid() }
        || stat.st_mode & libc::S_IFMT != libc::S_IFDIR
        || stat.st_mode & 0o077 != 0
    {
        return Err(ObjectStoreError::IntegrityMismatch);
    }
    Ok(owned)
}

#[cfg(unix)]
fn open_or_create_child_dir(
    parent: std::os::fd::RawFd,
    name: &str,
) -> Result<OwnedFd, ObjectStoreError> {
    let name = c_name(name)?;
    let created = unsafe { libc::mkdirat(parent, name.as_ptr(), 0o700) } == 0;
    if !created {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() != Some(libc::EEXIST) {
            return Err(classify_fs_error(error));
        }
    }
    if created && unsafe { libc::fsync(parent) } != 0 {
        return Err(ObjectStoreError::Unavailable);
    }
    let fd = open_child_dir(parent, name.to_str().unwrap_or_default())?;
    if created && unsafe { libc::fchmod(fd.as_raw_fd(), 0o700) } != 0 {
        return Err(ObjectStoreError::Unavailable);
    }
    Ok(fd)
}

#[cfg(unix)]
fn fstatat_nofollow(parent: std::os::fd::RawFd, name: &CString) -> std::io::Result<libc::stat> {
    let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
    if unsafe {
        libc::fstatat(
            parent,
            name.as_ptr(),
            stat.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    } != 0
    {
        return Err(std::io::Error::last_os_error());
    }
    Ok(unsafe { stat.assume_init() })
}

#[cfg(unix)]
fn classify_fs_error(error: std::io::Error) -> ObjectStoreError {
    match error.raw_os_error() {
        Some(libc::ENOENT | libc::ELOOP | libc::ENOTDIR | libc::EISDIR) => {
            ObjectStoreError::IntegrityMismatch
        }
        _ => ObjectStoreError::Unavailable,
    }
}

fn required_string(value: &Option<OsString>) -> Result<String, ApiError> {
    let value = value.as_ref().ok_or_else(config_invalid)?;
    let value = value.to_str().ok_or_else(config_invalid)?;
    if value.is_empty()
        || value.trim() != value
        || value.len() > 1024
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(config_invalid());
    }
    Ok(value.to_owned())
}

fn optional_string(value: &Option<OsString>) -> Result<Option<String>, ApiError> {
    value
        .as_ref()
        .map(|value| {
            let value = value.to_str().ok_or_else(config_invalid)?;
            if value.is_empty()
                || value.trim() != value
                || value.len() > 1024
                || value.bytes().any(|byte| byte.is_ascii_control())
            {
                return Err(config_invalid());
            }
            Ok(value.to_owned())
        })
        .transpose()
}

fn validate_bucket(bucket: &str) -> Result<(), ApiError> {
    if bucket.len() < 3
        || bucket.len() > 63
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
        return Err(config_invalid());
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
        return Err(config_invalid());
    }
    Ok(())
}

fn validate_endpoint(endpoint: &str) -> Result<(), ApiError> {
    let parsed = Url::parse(endpoint).map_err(|_| config_invalid())?;
    if !matches!(parsed.scheme(), "https" | "http")
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err(config_invalid());
    }
    if parsed.scheme() == "http" {
        let loopback = match parsed.host() {
            Some(url::Host::Ipv4(address)) => address.is_loopback(),
            Some(url::Host::Ipv6(address)) => address.is_loopback(),
            Some(url::Host::Domain(domain)) => domain.eq_ignore_ascii_case("localhost"),
            None => false,
        };
        if !loopback {
            return Err(config_invalid());
        }
    }
    Ok(())
}

fn validate_prefix(prefix: &str) -> Result<(), ApiError> {
    if prefix.is_empty()
        || prefix.len() > 192
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
        return Err(config_invalid());
    }
    Ok(())
}

fn validate_credentials_path(config: &Config, path: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| config_invalid())?;
    if metadata.file_type().is_symlink() || !metadata.file_type().is_file() {
        return Err(config_invalid());
    }
    let data_dir = fs::canonicalize(&config.data_dir).map_err(|_| config_invalid())?;
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let resolved = fs::canonicalize(parent)
        .map_err(|_| config_invalid())?
        .join(path.file_name().ok_or_else(config_invalid)?);
    if resolved.starts_with(data_dir) {
        return Err(config_invalid());
    }
    Ok(())
}

fn object_store_id(bucket: &str, region: &str, endpoint: Option<&str>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"atermius/object-store-identity/v1\0");
    hasher.update(bucket.as_bytes());
    hasher.update([0]);
    hasher.update(region.as_bytes());
    hasher.update([0]);
    hasher.update(endpoint.unwrap_or("aws").as_bytes());
    hex::encode(hasher.finalize())
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn config_invalid() -> ApiError {
    ApiError::internal("object storage configuration is invalid")
}

pub(crate) fn storage_api_error(error: ObjectStoreError) -> ApiError {
    use axum::http::StatusCode;
    match error {
        ObjectStoreError::Unavailable => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "OBJECT_STORAGE_UNAVAILABLE",
            "object storage is temporarily unavailable",
        ),
        ObjectStoreError::IntegrityMismatch => ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "OBJECT_INTEGRITY_MISMATCH",
            "stored object failed integrity validation",
        ),
        ObjectStoreError::ImmutableConflict => ApiError::conflict(
            "OBJECT_EXISTS",
            "object id is immutable and already contains different bytes",
        ),
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::{collections::HashMap, sync::Arc};

    use axum::{
        Router,
        body::{Body, to_bytes},
        extract::State,
        http::{Method, Request, StatusCode, header},
        response::Response,
        routing::any,
    };
    use tokio::sync::Mutex;

    use super::{ObjectStore, sha256_hex};

    #[derive(Clone)]
    struct TestObject {
        bytes: Vec<u8>,
        digest: String,
        etag: String,
    }

    #[derive(Default)]
    struct FixtureState {
        objects: HashMap<String, TestObject>,
        request_shapes: Vec<(String, Vec<String>)>,
    }

    pub struct S3Fixture {
        pub endpoint: String,
        state: Arc<Mutex<FixtureState>>,
        _server: tokio::task::JoinHandle<()>,
    }

    impl S3Fixture {
        pub async fn start() -> Self {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let state = Arc::new(Mutex::new(FixtureState::default()));
            let app = Router::new()
                .fallback(any(handle_request))
                .with_state(state.clone());
            let server = tokio::spawn(async move {
                axum::serve(listener, app).await.unwrap();
            });
            Self {
                endpoint: format!("http://{address}"),
                state,
                _server: server,
            }
        }

        pub fn store(&self) -> ObjectStore {
            ObjectStore::s3_for_test(&self.endpoint, "test-bucket", "us-east-1")
        }

        pub fn store_with_delete_pause(
            &self,
            pause: std::sync::Arc<crate::recovery::TestPause>,
        ) -> ObjectStore {
            ObjectStore::s3_for_test_with_delete_pause(
                &self.endpoint,
                "test-bucket",
                "us-east-1",
                pause,
            )
        }

        pub async fn overwrite(&self, key: &str, bytes: Vec<u8>, advertised_digest: &str) {
            let etag = format!("\"{}\"", sha256_hex(&bytes));
            self.state.lock().await.objects.insert(
                format!("/test-bucket/{key}"),
                TestObject {
                    bytes,
                    digest: advertised_digest.to_owned(),
                    etag,
                },
            );
        }

        pub async fn request_shapes(&self) -> Vec<(String, Vec<String>)> {
            self.state.lock().await.request_shapes.clone()
        }
    }

    async fn handle_request(
        State(state): State<Arc<Mutex<FixtureState>>>,
        request: Request<Body>,
    ) -> Response {
        let method = request.method().clone();
        let path = request.uri().path().to_owned();
        let header_names = request
            .headers()
            .keys()
            .map(|name| name.as_str().to_owned())
            .collect::<Vec<_>>();
        let range_header = request.headers().get(header::RANGE).cloned();
        let if_match = request
            .headers()
            .get(header::IF_MATCH)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let if_none_match = request
            .headers()
            .get(header::IF_NONE_MATCH)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        let advertised_digest = request
            .headers()
            .get("x-amz-meta-atermius-sha256")
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        state
            .lock()
            .await
            .request_shapes
            .push((request.uri().to_string(), header_names));
        if !path.starts_with("/test-bucket/") {
            return response(StatusCode::NOT_FOUND, "");
        }
        let body = match to_bytes(request.into_body(), 64 * 1024 * 1024).await {
            Ok(body) => body.to_vec(),
            Err(_) => return response(StatusCode::BAD_REQUEST, ""),
        };
        let mut objects = state.lock().await;
        match method {
            Method::PUT => {
                let key = path;
                if if_none_match.as_deref() != Some("*") {
                    return response(StatusCode::PRECONDITION_FAILED, "");
                }
                if objects.objects.contains_key(&key) {
                    return response(StatusCode::PRECONDITION_FAILED, "");
                }
                let digest = sha256_hex(&body);
                if advertised_digest.as_deref() != Some(digest.as_str()) {
                    return response(StatusCode::BAD_REQUEST, "");
                }
                let etag = format!("\"{digest}\"");
                objects.objects.insert(
                    key,
                    TestObject {
                        bytes: body,
                        digest,
                        etag,
                    },
                );
                response(StatusCode::OK, "")
            }
            Method::HEAD => {
                let Some(object) = objects.objects.get(&path).cloned() else {
                    return response(StatusCode::NOT_FOUND, "");
                };
                let object_size = object.bytes.len();
                response_with_object(StatusCode::OK, object, Vec::new(), object_size, None)
            }
            Method::GET => {
                let Some(object) = objects.objects.get(&path).cloned() else {
                    return response(StatusCode::NOT_FOUND, "");
                };
                if let Some(range_header) = range_header {
                    let Ok(range_header) = range_header.to_str() else {
                        return response(StatusCode::BAD_REQUEST, "");
                    };
                    let Some((start, end)) = range_header
                        .strip_prefix("bytes=")
                        .and_then(|value| value.split_once('-'))
                        .and_then(|(start, end)| {
                            Some((start.parse::<usize>().ok()?, end.parse::<usize>().ok()?))
                        })
                    else {
                        return response(StatusCode::BAD_REQUEST, "");
                    };
                    if start > end || end >= object.bytes.len() {
                        return response(StatusCode::RANGE_NOT_SATISFIABLE, "");
                    }
                    let bytes = object.bytes[start..=end].to_vec();
                    let content_range = format!("bytes {start}-{end}/{}", object.bytes.len());
                    response_with_object(
                        StatusCode::PARTIAL_CONTENT,
                        object,
                        bytes,
                        end + 1 - start,
                        Some(content_range),
                    )
                } else {
                    let bytes = object.bytes.clone();
                    let length = bytes.len();
                    response_with_object(StatusCode::OK, object, bytes, length, None)
                }
            }
            Method::DELETE => {
                let Some(object) = objects.objects.get(&path) else {
                    return response(StatusCode::NOT_FOUND, "");
                };
                let matches = if_match.as_deref() == Some(object.etag.as_str());
                if !matches {
                    return response(StatusCode::PRECONDITION_FAILED, "");
                }
                objects.objects.remove(&path);
                response(StatusCode::NO_CONTENT, "")
            }
            _ => response(StatusCode::METHOD_NOT_ALLOWED, ""),
        }
    }

    fn response(status: StatusCode, body: &'static str) -> Response {
        Response::builder()
            .status(status)
            .body(Body::from(body))
            .unwrap()
    }

    fn response_with_object(
        status: StatusCode,
        object: TestObject,
        body: Vec<u8>,
        content_length: usize,
        content_range: Option<String>,
    ) -> Response {
        let mut builder = Response::builder()
            .status(status)
            .header(header::CONTENT_LENGTH, content_length)
            .header("x-amz-meta-atermius-sha256", object.digest)
            .header(header::ETAG, object.etag);
        if let Some(content_range) = content_range {
            builder = builder.header(header::CONTENT_RANGE, content_range);
        }
        builder.body(Body::from(body)).unwrap()
    }
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use super::{ObjectStore, ObjectStoreEnv, parse_settings};
    use crate::object_store::test_support::S3Fixture;
    use crate::{AuthRateLimits, Config};

    struct TestDir(std::path::PathBuf);

    impl TestDir {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .join(format!("atermius-object-store-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            }
            Self(path)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    async fn catalogue_validation_pool() -> sqlx::SqlitePool {
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE blob_objects(storage_backend TEXT,storage_key TEXT,storage_store_id TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("CREATE TABLE uploads(storage_backend TEXT,storage_store_id TEXT,state TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query("CREATE TABLE object_delete_queue(storage_backend TEXT,storage_store_id TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_jobs(migration_id TEXT PRIMARY KEY,target_backend TEXT,target_store_id TEXT,target_s3_prefix TEXT,state TEXT,updated_at TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        pool
    }

    fn config() -> Config {
        Config {
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            backup_retention_count: None,
            data_dir: std::env::temp_dir().join("atermius-object-store-config-test"),
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

    #[test]
    fn absent_backend_defaults_to_sqlite_and_partial_s3_config_fails_closed() {
        assert!(matches!(
            parse_settings(&ObjectStoreEnv::default(), &config()).unwrap(),
            super::ObjectStoreSettings::Sqlite
        ));
        let partial = ObjectStoreEnv {
            backend: Some(OsString::from("s3")),
            bucket: Some(OsString::from("vault-objects")),
            ..ObjectStoreEnv::default()
        };
        assert!(parse_settings(&partial, &config()).is_err());
        let stray = ObjectStoreEnv {
            prefix: Some(OsString::from("attachments")),
            ..ObjectStoreEnv::default()
        };
        assert!(parse_settings(&stray, &config()).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn filesystem_settings_reject_relative_symlink_and_data_directory_overlap() {
        use std::os::unix::fs::{PermissionsExt, symlink};

        let temp = TestDir::new();
        let data = temp.path().join("data");
        let root = temp.path().join("objects");
        std::fs::create_dir(&data).unwrap();
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut cfg = config();
        cfg.data_dir = data;
        let valid = ObjectStoreEnv {
            backend: Some(OsString::from("filesystem")),
            filesystem_root: Some(OsString::from(root.as_os_str())),
            ..ObjectStoreEnv::default()
        };
        assert!(matches!(
            parse_settings(&valid, &cfg).unwrap(),
            super::ObjectStoreSettings::Filesystem(_)
        ));
        let relative = ObjectStoreEnv {
            filesystem_root: Some(OsString::from("objects")),
            ..valid.clone()
        };
        assert!(parse_settings(&relative, &cfg).is_err());
        let overlap = ObjectStoreEnv {
            filesystem_root: Some(OsString::from(&cfg.data_dir)),
            ..valid.clone()
        };
        assert!(parse_settings(&overlap, &cfg).is_err());
        let alias = temp.path().join("objects-alias");
        symlink(&root, &alias).unwrap();
        let linked = ObjectStoreEnv {
            filesystem_root: Some(OsString::from(alias.as_os_str())),
            ..valid.clone()
        };
        assert!(parse_settings(&linked, &cfg).is_err());
        let shared = ObjectStoreEnv {
            filesystem_root: Some(OsString::from(root.as_os_str())),
            bucket: Some(OsString::from("stray")),
            ..valid
        };
        assert!(parse_settings(&shared, &cfg).is_err());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn filesystem_store_is_immutable_range_readable_and_integrity_checked() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TestDir::new();
        let root = temp.path().join("objects");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let store = super::ObjectStore::filesystem_for_test(&root);
        let instance = uuid::Uuid::new_v4().to_string();
        let vault = uuid::Uuid::new_v4().to_string();
        let object = uuid::Uuid::new_v4().to_string();
        let upload = uuid::Uuid::new_v4().to_string();
        let (key, store_id) = store
            .object_key(&instance, &vault, &object, &upload)
            .unwrap();
        assert_eq!(store.store_id(), Some(store_id.as_str()));
        assert_eq!(
            store.store_id(),
            super::ObjectStore::filesystem_for_test(&root).store_id()
        );
        let bytes = b"opaque encrypted filesystem object";
        let digest = super::sha256_hex(bytes);
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();
        assert_eq!(
            store
                .read_object(&key, bytes.len() as i64, &digest, Some((7, 15)))
                .await
                .unwrap(),
            &bytes[7..16]
        );
        assert_eq!(
            store
                .read_object(&key, bytes.len() as i64, &digest, None)
                .await
                .unwrap(),
            bytes
        );
        let different = b"different ciphertext bytes";
        assert_eq!(
            store
                .put_immutable(
                    &key,
                    different,
                    different.len() as i64,
                    &super::sha256_hex(different),
                )
                .await,
            Err(super::ObjectStoreError::ImmutableConflict)
        );
        std::fs::write(root.join(&key), b"damaged bytes").unwrap();
        assert_eq!(
            store
                .read_object(&key, bytes.len() as i64, &digest, None)
                .await,
            Err(super::ObjectStoreError::IntegrityMismatch)
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn filesystem_catalogue_identity_rejects_replaced_volume() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TestDir::new();
        let first_root = temp.path().join("first");
        let second_root = temp.path().join("second");
        std::fs::create_dir(&first_root).unwrap();
        std::fs::create_dir(&second_root).unwrap();
        for root in [&first_root, &second_root] {
            std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let first = super::ObjectStore::filesystem_for_test(&first_root);
        let reopened = super::ObjectStore::filesystem_for_test(&first_root);
        let replacement = super::ObjectStore::filesystem_for_test(&second_root);
        assert_eq!(first.store_id(), reopened.store_id());
        assert_ne!(first.store_id(), replacement.store_id());

        let pool = catalogue_validation_pool().await;
        let uuid = uuid::Uuid::new_v4().to_string();
        let key = format!("atermius/objects/v1/{uuid}/{uuid}/{uuid}/{uuid}");
        sqlx::query("INSERT INTO blob_objects VALUES('filesystem',?,?)")
            .bind(key)
            .bind(first.store_id())
            .execute(&pool)
            .await
            .unwrap();
        assert!(first.validate_catalogue(&pool).await.is_ok());
        assert!(reopened.validate_catalogue(&pool).await.is_ok());
        assert!(replacement.validate_catalogue(&pool).await.is_err());
        assert!(
            super::ObjectStore::Sqlite
                .validate_catalogue(&pool)
                .await
                .is_err()
        );
        pool.close().await;
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn latest_completed_sqlite_migration_target_is_enforced_for_empty_catalogue() {
        use std::os::unix::fs::PermissionsExt;

        let temp = TestDir::new();
        let root = temp.path().join("old-filesystem");
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let old_filesystem = ObjectStore::filesystem_for_test(&root);
        let pool = catalogue_validation_pool().await;

        sqlx::query(
            "INSERT INTO object_store_migration_jobs(migration_id,target_backend,target_store_id,target_s3_prefix,state,updated_at) VALUES('11111111-1111-4111-8111-111111111111','filesystem',?,NULL,'complete','2026-01-01T00:00:00Z')",
        )
        .bind(old_filesystem.store_id())
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO object_store_migration_jobs(migration_id,target_backend,target_store_id,target_s3_prefix,state,updated_at) VALUES('22222222-2222-4222-8222-222222222222','sqlite',NULL,NULL,'complete','2026-01-02T00:00:00Z')",
        )
        .execute(&pool)
        .await
        .unwrap();

        assert!(old_filesystem.validate_catalogue(&pool).await.is_err());
        assert!(ObjectStore::Sqlite.validate_catalogue(&pool).await.is_ok());
        pool.close().await;
    }

    #[tokio::test]
    async fn latest_completed_s3_target_prefix_is_enforced_for_empty_catalogue() {
        let pool = catalogue_validation_pool().await;
        let expected = ObjectStore::s3_for_test_with_prefix(
            "http://127.0.0.1:9000",
            "migration-bucket",
            "us-east-1",
            Some("current-prefix"),
        );
        let same_identity_wrong_prefix = ObjectStore::s3_for_test_with_prefix(
            "http://127.0.0.1:9000",
            "migration-bucket",
            "us-east-1",
            Some("other-prefix"),
        );
        let unprefixed =
            ObjectStore::s3_for_test("http://127.0.0.1:9000", "migration-bucket", "us-east-1");
        sqlx::query(
            "INSERT INTO object_store_migration_jobs(migration_id,target_backend,target_store_id,target_s3_prefix,state,updated_at) VALUES('33333333-3333-4333-8333-333333333333','s3',?,?,'complete','2026-01-01T00:00:00Z')",
        )
        .bind(expected.store_id())
        .bind(expected.s3_prefix())
        .execute(&pool)
        .await
        .unwrap();

        assert!(expected.validate_catalogue(&pool).await.is_ok());
        assert!(
            same_identity_wrong_prefix
                .validate_catalogue(&pool)
                .await
                .is_err()
        );
        assert!(unprefixed.matches_migration_target("s3", expected.store_id(), Some("")));
        assert!(!expected.matches_migration_target("s3", expected.store_id(), Some("")));
        pool.close().await;
    }

    #[tokio::test]
    async fn external_backup_hydration_removes_source_migration_journal_from_snapshot() {
        use sqlx::sqlite::SqlitePoolOptions;

        let temp = TestDir::new();
        let database = temp.path().join("snapshot.sqlite");
        let database_url = format!("sqlite://{}?mode=rwc", database.display());
        let fixture = S3Fixture::start().await;
        let store = fixture.store();
        let vault_id = "22222222-2222-4222-8222-222222222222";
        let object_id = "33333333-3333-4333-8333-333333333333";
        let migration_id = "44444444-4444-4444-8444-444444444444";
        let key = format!("atermius/objects/v1/{vault_id}/{vault_id}/{object_id}/{migration_id}");
        let bytes = b"encrypted-backup-payload";
        let digest = super::sha256_hex(bytes);
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect(&database_url)
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE blob_objects(vault_id TEXT,object_id TEXT,bytes BLOB,size INTEGER,sha256 TEXT,storage_backend TEXT,storage_key TEXT,storage_store_id TEXT,storage_state TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("CREATE TABLE object_references(vault_id TEXT,object_id TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE uploads(state TEXT,storage_backend TEXT,storage_store_id TEXT,vault_id TEXT,object_id TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("CREATE TABLE object_delete_queue(storage_backend TEXT,storage_store_id TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_jobs(migration_id TEXT PRIMARY KEY,target_backend TEXT,target_store_id TEXT,target_s3_prefix TEXT,state TEXT,updated_at TEXT)",
        )
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("CREATE TABLE object_store_migration_items(migration_id TEXT)")
            .execute(&pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,storage_backend,storage_key,storage_store_id,storage_state) VALUES(?,?,X'',?,?,'s3',?,?,'available')",
        )
        .bind(vault_id)
        .bind(object_id)
        .bind(bytes.len() as i64)
        .bind(&digest)
        .bind(&key)
        .bind(store.store_id())
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO object_store_migration_jobs(migration_id,target_backend,target_store_id,target_s3_prefix,state,updated_at) VALUES(?,'s3',?,NULL,'complete','2026-01-01T00:00:00Z')",
        )
        .bind(migration_id)
        .bind(store.store_id())
        .execute(&pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO object_store_migration_items(migration_id) VALUES(?)")
            .bind(migration_id)
            .execute(&pool)
            .await
            .unwrap();
        pool.close().await;

        fixture.overwrite(&key, bytes.to_vec(), &digest).await;
        store.hydrate_for_backup(&database_url).await.unwrap();

        let hydrated = SqlitePoolOptions::new()
            .max_connections(1)
            .connect(&database_url)
            .await
            .unwrap();
        let (stored_bytes, backend): (Vec<u8>, String) = sqlx::query_as(
            "SELECT bytes,storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_one(&hydrated)
        .await
        .unwrap();
        assert_eq!(stored_bytes, bytes);
        assert_eq!(backend, "sqlite");
        let jobs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM object_store_migration_jobs")
            .fetch_one(&hydrated)
            .await
            .unwrap();
        let items: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM object_store_migration_items")
            .fetch_one(&hydrated)
            .await
            .unwrap();
        assert_eq!((jobs, items), (0, 0));
        assert!(
            ObjectStore::Sqlite
                .validate_catalogue(&hydrated)
                .await
                .is_ok()
        );
        hydrated.close().await;
    }

    #[test]
    fn endpoint_rejects_remote_plain_http_and_credentials_in_url() {
        assert!(super::validate_endpoint("http://127.0.0.1:9000").is_ok());
        assert!(super::validate_endpoint("http://example.test").is_err());
        assert!(super::validate_endpoint("https://user:pass@example.test").is_err());
    }

    #[test]
    fn key_space_is_versioned_and_contains_only_canonical_opaque_ids() {
        let uuid = uuid::Uuid::new_v4().to_string();
        let key = format!("atermius/objects/v1/{uuid}/{uuid}/{uuid}");
        assert!(key.ends_with(&format!("/{uuid}/{uuid}/{uuid}")));
        assert!(super::validate_prefix("opaque-prefix/v1-objects").is_ok());
        assert!(super::validate_prefix("../escape").is_err());
    }

    #[tokio::test]
    async fn sdk_s3_put_read_range_and_conditional_delete_roundtrip() {
        let fixture = S3Fixture::start().await;
        let store = fixture.store();
        let bytes = b"opaque encrypted attachment payload";
        let digest = super::sha256_hex(bytes);
        store
            .put_immutable(
                "atermius/objects/v1/test",
                bytes,
                bytes.len() as i64,
                &digest,
            )
            .await
            .unwrap();
        assert_eq!(
            store
                .read_object(
                    "atermius/objects/v1/test",
                    bytes.len() as i64,
                    &digest,
                    Some((7, 15)),
                )
                .await
                .unwrap(),
            bytes[7..=15]
        );
        store
            .delete_object("atermius/objects/v1/test", bytes.len() as i64, &digest)
            .await
            .unwrap();
        let shapes = fixture.request_shapes().await;
        assert!(shapes.iter().any(|(uri, headers)| {
            uri.starts_with("/test-bucket/atermius/objects/v1/test")
                && headers.iter().any(|header| header == "authorization")
        }));
        assert!(shapes.iter().any(|(uri, headers)| {
            uri.contains("/test-bucket/atermius/objects/v1/test")
                && headers.iter().any(|header| header == "range")
        }));
        assert!(shapes.iter().any(|(uri, headers)| {
            uri.contains("/test-bucket/atermius/objects/v1/test")
                && headers.iter().any(|header| header == "if-match")
        }));
    }
}

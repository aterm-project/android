//! Offline, resumable user object backend migration.
//!
//! The server is deliberately excluded for the whole operation. Each target
//! object is written and verified before its catalogue row is switched. The
//! old copy is retained, so operators can resume forward or restore the
//! pre-migration archive without needing an in-place reverse migration.

use std::time::Duration;

use chrono::Utc;
use sha2::Digest;
use sqlx::{Row, SqlitePool};

use crate::{
    ApiError, Config, acquire_maintenance_run_lock, acquire_runtime_lock,
    object_store::{ObjectStore, ObjectStoreError},
    secure_file,
};

#[derive(Debug, Clone)]
struct MigrationJob {
    migration_id: String,
    source_backend: String,
    source_store_id: Option<String>,
    target_backend: String,
    target_store_id: Option<String>,
    target_s3_prefix: Option<String>,
    state: String,
    object_count: i64,
    reference_count: i64,
}

#[derive(Debug, Clone)]
struct MigrationItem {
    vault_id: String,
    object_id: String,
    source_backend: String,
    source_key: Option<String>,
    source_store_id: Option<String>,
    target_backend: String,
    target_key: Option<String>,
    target_store_id: Option<String>,
    expected_size: i64,
    expected_sha256: String,
    state: String,
}

#[derive(Debug, Clone)]
struct CatalogueObject {
    vault_id: String,
    object_id: String,
    size: i64,
    sha256: String,
    storage_backend: String,
    storage_key: Option<String>,
    storage_store_id: Option<String>,
    storage_state: String,
}

/// Moves every available encrypted object in the instance catalogue to the
/// configured migration target. The normal object-store environment describes
/// the source; `ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_*` describes the target.
/// The command is intentionally offline and takes the same process locks as
/// serving, maintenance, and backups before it opens SQLite or a target store.
pub async fn run_object_store_migration(
    config: &Config,
    database_url: &str,
    migration_id: &str,
) -> Result<u64, ApiError> {
    let parsed = uuid::Uuid::parse_str(migration_id).map_err(ApiError::internal)?;
    if parsed.to_string() != migration_id {
        return Err(ApiError::internal("migration ID is not a canonical UUID"));
    }

    secure_file::create_private_data_dir(&config.data_dir)?;
    let _runtime_lock = acquire_runtime_lock(&config.data_dir)?;
    let _maintenance_lock = acquire_maintenance_run_lock(&config.data_dir)?;

    let database_key = crate::database::DatabaseKey::configured(config)?;
    let options = crate::database::main_sqlite_options(database_url, database_key.as_ref())?
        .create_if_missing(false)
        .foreign_keys(true)
        .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
        .busy_timeout(Duration::from_secs(10));
    crate::database::startup_database_encryption(
        crate::database::detect_database_file(options.get_filename())?,
        database_key.as_ref(),
    )?;
    let db = crate::database::connect_keyed_pool(options, database_key.as_ref(), 1).await?;
    // Do not let SQLx migration DDL touch a corrupt or foreign-key-inconsistent
    // instance. Check again after applying the current schema for the journal.
    verify_sqlite_integrity(&db).await?;
    sqlx::migrate!("./migrations")
        .run(&db)
        .await
        .map_err(ApiError::internal)?;

    verify_sqlite_integrity(&db).await?;
    let existing = load_job(&db, migration_id).await?;
    let active_migration: Option<String> = sqlx::query_scalar(
        "SELECT migration_id FROM object_store_migration_jobs WHERE state='copying'",
    )
    .fetch_optional(&db)
    .await
    .map_err(ApiError::internal)?;
    if active_migration
        .as_deref()
        .is_some_and(|active_id| active_id != migration_id)
    {
        return Err(ApiError::internal(
            "another object storage migration is already incomplete",
        ));
    }
    if let Some(job) = existing.as_ref().filter(|job| job.state == "complete") {
        let target = ObjectStore::migration_target_from_env(config, false)?;
        ensure_target_store_matches(
            &target,
            &job.target_backend,
            job.target_store_id.as_deref(),
            job.target_s3_prefix.as_deref(),
        )?;
        let instance_id: String =
            sqlx::query_scalar("SELECT instance_id FROM instance_meta WHERE id=1")
                .fetch_one(&db)
                .await
                .map_err(ApiError::internal)?;
        validate_target_keys(
            &target,
            &load_items(&db, migration_id).await?,
            migration_id,
            &instance_id,
        )?;
        verify_completed_job(&db, &target, job).await?;
        return u64::try_from(job.object_count).map_err(ApiError::internal);
    }

    let source = ObjectStore::migration_source_from_env(config)?;
    let source_backend = source.backend_name().to_owned();
    let source_store_id = source.store_id().map(str::to_owned);
    if let Some(job) = &existing {
        ensure_store_matches(&source, &job.source_backend, job.source_store_id.as_deref())?;
    }
    let resumed_target = if let Some(job) = &existing {
        let target = ObjectStore::migration_target_from_env(config, false)?;
        ensure_target_store_matches(
            &target,
            &job.target_backend,
            job.target_store_id.as_deref(),
            job.target_s3_prefix.as_deref(),
        )?;
        Some(target)
    } else {
        None
    };

    reject_unsafe_catalogue_state(&db).await?;
    let expected_job = existing.as_ref();
    let catalog_objects = read_catalogue_objects(&db).await?;
    let reference_count = count_references(&db).await?;
    let instance_id: String =
        sqlx::query_scalar("SELECT instance_id FROM instance_meta WHERE id=1")
            .fetch_one(&db)
            .await
            .map_err(ApiError::internal)?;

    if let Some(job) = expected_job {
        ensure_job_configuration(job, &source, &catalog_objects)?;
        verify_resumable_catalogue(&db, job, &catalog_objects).await?;
        let items = load_items(&db, migration_id).await?;
        validate_target_keys(
            resumed_target
                .as_ref()
                .ok_or_else(|| ApiError::internal("migration target is missing"))?,
            &items,
            &job.migration_id,
            &instance_id,
        )?;
        verify_sources(&source, &db, &items).await?;
    } else {
        validate_new_source_catalogue(&source, &db, &catalog_objects).await?;
        verify_catalogue_sources(&source, &db, &catalog_objects).await?;
    }

    // A destination filesystem identity is created only after source metadata
    // and every source payload have passed preflight. On resume it must already
    // exist and match the persisted journal identity.
    let target = match resumed_target {
        Some(target) => target,
        None => ObjectStore::migration_target_from_env(config, true)?,
    };
    let target_backend = target.backend_name().to_owned();
    let target_store_id = target.store_id().map(str::to_owned);
    if source_backend == target_backend
        && source_store_id == target_store_id
        && source.s3_prefix() == target.s3_prefix()
    {
        return Err(ApiError::internal(
            "source and destination object store identities are the same",
        ));
    }
    if let Some(job) = expected_job {
        ensure_target_store_matches(
            &target,
            &job.target_backend,
            job.target_store_id.as_deref(),
            job.target_s3_prefix.as_deref(),
        )?;
    }

    let job = match existing {
        Some(job) => job,
        None => {
            let job = MigrationJob {
                migration_id: migration_id.to_owned(),
                source_backend,
                source_store_id,
                target_backend,
                target_store_id,
                target_s3_prefix: (target.backend_name() == "s3")
                    .then(|| target.s3_prefix().unwrap_or_default().to_owned()),
                state: "copying".to_owned(),
                object_count: i64::try_from(catalog_objects.len()).map_err(ApiError::internal)?,
                reference_count,
            };
            create_journal(&db, &job, &catalog_objects, &target, &instance_id).await?;
            job
        }
    };

    let items = load_items(&db, migration_id).await?;
    if items.len() as i64 != job.object_count {
        return Err(ApiError::internal(
            "object migration journal does not match its object count",
        ));
    }
    for item in &items {
        if item.state == "catalogue_switched" {
            verify_item_catalogue(&db, &job, item, true).await?;
            continue;
        }
        if item.state != "pending" {
            return Err(ApiError::internal(
                "object migration journal state is invalid",
            ));
        }
        verify_item_catalogue(&db, &job, item, false).await?;
        let bytes = read_item_source(&source, &db, item).await?;
        verify_payload(&bytes, item.expected_size, &item.expected_sha256)?;
        if target.is_external() {
            let key = item
                .target_key
                .as_deref()
                .ok_or_else(|| ApiError::internal("migration target key is missing"))?;
            target
                .put_immutable(key, &bytes, item.expected_size, &item.expected_sha256)
                .await
                .map_err(map_store_error)?;
            let copied = target
                .read_object(key, item.expected_size, &item.expected_sha256, None)
                .await
                .map_err(map_store_error)?;
            if copied != bytes {
                return Err(ApiError::internal(
                    "migration destination content did not match its source",
                ));
            }
        }
        switch_catalogue_item(&db, &job, item, &bytes).await?;
    }

    verify_copy_completion(&db, &target, &job, &items).await?;
    let updated = sqlx::query(
        "UPDATE object_store_migration_jobs SET state='complete',updated_at=? WHERE migration_id=? AND state='copying'",
    )
    .bind(Utc::now().to_rfc3339())
    .bind(migration_id)
    .execute(&db)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::internal(
            "object migration completion checkpoint could not be committed",
        ));
    }
    Ok(u64::try_from(job.object_count).map_err(ApiError::internal)?)
}

async fn verify_sqlite_integrity(db: &SqlitePool) -> Result<(), ApiError> {
    let integrity: Vec<String> = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_all(db)
        .await
        .map_err(ApiError::internal)?;
    if integrity.len() != 1 || integrity[0] != "ok" {
        return Err(ApiError::internal("SQLite integrity check failed"));
    }
    let foreign_keys = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(db)
        .await
        .map_err(ApiError::internal)?;
    if !foreign_keys.is_empty() {
        return Err(ApiError::internal("SQLite foreign key check failed"));
    }
    Ok(())
}

async fn reject_unsafe_catalogue_state(db: &SqlitePool) -> Result<(), ApiError> {
    let active_uploads: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM uploads WHERE state IN ('open','completing')")
            .fetch_one(db)
            .await
            .map_err(ApiError::internal)?;
    let deletes: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM object_delete_queue")
        .fetch_one(db)
        .await
        .map_err(ApiError::internal)?;
    let deleting: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM blob_objects WHERE storage_state='deleting'")
            .fetch_one(db)
            .await
            .map_err(ApiError::internal)?;
    let incomplete_jobs: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM object_store_migration_jobs WHERE state='copying'",
    )
    .fetch_one(db)
    .await
    .map_err(ApiError::internal)?;
    if active_uploads != 0 || deletes != 0 || deleting != 0 || incomplete_jobs > 1 {
        return Err(ApiError::internal(
            "object catalogue has active uploads, pending deletes, deleting objects, or another incomplete migration",
        ));
    }
    let duplicate_keys: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM (SELECT storage_backend,storage_store_id,storage_key FROM blob_objects WHERE storage_backend IN ('s3','filesystem') GROUP BY storage_backend,storage_store_id,storage_key HAVING COUNT(*)>1)",
    )
    .fetch_one(db)
    .await
    .map_err(ApiError::internal)?;
    if duplicate_keys != 0 {
        return Err(ApiError::internal(
            "object catalogue contains duplicate external object keys",
        ));
    }
    Ok(())
}

async fn read_catalogue_objects(db: &SqlitePool) -> Result<Vec<CatalogueObject>, ApiError> {
    let rows = sqlx::query(
        "SELECT vault_id,object_id,size,sha256,storage_backend,storage_key,storage_store_id,storage_state FROM blob_objects ORDER BY vault_id,object_id",
    )
    .fetch_all(db)
    .await
    .map_err(ApiError::internal)?;
    rows.into_iter()
        .map(|row| {
            let object = CatalogueObject {
                vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
                object_id: row.try_get("object_id").map_err(ApiError::internal)?,
                size: row.try_get("size").map_err(ApiError::internal)?,
                sha256: row.try_get("sha256").map_err(ApiError::internal)?,
                storage_backend: row.try_get("storage_backend").map_err(ApiError::internal)?,
                storage_key: row.try_get("storage_key").map_err(ApiError::internal)?,
                storage_store_id: row
                    .try_get("storage_store_id")
                    .map_err(ApiError::internal)?,
                storage_state: row.try_get("storage_state").map_err(ApiError::internal)?,
            };
            validate_catalogue_object(&object)?;
            Ok(object)
        })
        .collect()
}

fn validate_catalogue_object(object: &CatalogueObject) -> Result<(), ApiError> {
    if object.size <= 0
        || object.sha256.len() != 64
        || !object.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        || object.storage_state != "available"
    {
        return Err(ApiError::internal("object catalogue metadata is invalid"));
    }
    match object.storage_backend.as_str() {
        "sqlite" if object.storage_key.is_none() && object.storage_store_id.is_none() => {}
        "s3" | "filesystem"
            if object
                .storage_key
                .as_ref()
                .is_some_and(|key| !key.is_empty())
                && object
                    .storage_store_id
                    .as_ref()
                    .is_some_and(|id| !id.is_empty()) => {}
        _ => {
            return Err(ApiError::internal(
                "object catalogue storage identity is invalid",
            ));
        }
    }
    Ok(())
}

async fn count_references(db: &SqlitePool) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT COUNT(*) FROM object_references")
        .fetch_one(db)
        .await
        .map_err(ApiError::internal)
}

async fn validate_new_source_catalogue(
    source: &ObjectStore,
    db: &SqlitePool,
    objects: &[CatalogueObject],
) -> Result<(), ApiError> {
    source.validate_catalogue_contents(db).await?;
    for object in objects {
        if object.storage_backend != "sqlite" && object.storage_backend != source.backend_name() {
            return Err(ApiError::internal(
                "object catalogue contains an object outside the configured source store",
            ));
        }
        if object.storage_backend != "sqlite"
            && object.storage_store_id.as_deref() != source.store_id()
        {
            return Err(ApiError::internal(
                "configured source identity does not match object metadata",
            ));
        }
    }
    Ok(())
}

async fn verify_catalogue_sources(
    source: &ObjectStore,
    db: &SqlitePool,
    objects: &[CatalogueObject],
) -> Result<(), ApiError> {
    for object in objects {
        let bytes = read_catalogue_source(source, db, object).await?;
        verify_payload(&bytes, object.size, &object.sha256)?;
    }
    Ok(())
}

async fn read_catalogue_source(
    source: &ObjectStore,
    db: &SqlitePool,
    object: &CatalogueObject,
) -> Result<Vec<u8>, ApiError> {
    if object.storage_backend == "sqlite" {
        let row = sqlx::query("SELECT bytes FROM blob_objects WHERE vault_id=? AND object_id=?")
            .bind(&object.vault_id)
            .bind(&object.object_id)
            .fetch_optional(db)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(|| ApiError::internal("migration source catalogue row is missing"))?;
        return row.try_get("bytes").map_err(ApiError::internal);
    }
    source
        .read_object(
            object.storage_key.as_deref().unwrap_or_default(),
            object.size,
            &object.sha256,
            None,
        )
        .await
        .map_err(map_store_error)
}

async fn verify_sources(
    source: &ObjectStore,
    db: &SqlitePool,
    items: &[MigrationItem],
) -> Result<(), ApiError> {
    for item in items {
        if item.state == "catalogue_switched" {
            continue;
        }
        if item.state != "pending" {
            return Err(ApiError::internal(
                "object migration journal state is invalid",
            ));
        }
        let bytes = read_item_source(source, db, item).await?;
        verify_payload(&bytes, item.expected_size, &item.expected_sha256)?;
    }
    Ok(())
}

async fn read_item_source(
    source: &ObjectStore,
    db: &SqlitePool,
    item: &MigrationItem,
) -> Result<Vec<u8>, ApiError> {
    if item.source_backend == "sqlite" {
        let row = sqlx::query(
            "SELECT bytes,size,sha256,storage_backend,storage_key,storage_store_id,storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&item.vault_id)
        .bind(&item.object_id)
        .fetch_optional(db)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(|| ApiError::internal("migration source catalogue row is missing"))?;
        if row
            .try_get::<String, _>("storage_backend")
            .map_err(ApiError::internal)?
            != "sqlite"
            || row
                .try_get::<Option<String>, _>("storage_key")
                .map_err(ApiError::internal)?
                .is_some()
            || row
                .try_get::<Option<String>, _>("storage_store_id")
                .map_err(ApiError::internal)?
                .is_some()
            || row
                .try_get::<String, _>("storage_state")
                .map_err(ApiError::internal)?
                != "available"
            || row.try_get::<i64, _>("size").map_err(ApiError::internal)? != item.expected_size
            || row
                .try_get::<String, _>("sha256")
                .map_err(ApiError::internal)?
                != item.expected_sha256
        {
            return Err(ApiError::internal("migration source catalogue row changed"));
        }
        return row.try_get("bytes").map_err(ApiError::internal);
    }
    if source.backend_name() != item.source_backend
        || source.store_id() != item.source_store_id.as_deref()
    {
        return Err(ApiError::internal(
            "migration source store identity changed",
        ));
    }
    source
        .read_object(
            item.source_key.as_deref().unwrap_or_default(),
            item.expected_size,
            &item.expected_sha256,
            None,
        )
        .await
        .map_err(map_store_error)
}

fn verify_payload(bytes: &[u8], size: i64, digest: &str) -> Result<(), ApiError> {
    let actual_size = i64::try_from(bytes.len()).map_err(ApiError::internal)?;
    let actual_digest = hex::encode(sha2::Sha256::digest(bytes));
    if actual_size != size || !actual_digest.eq_ignore_ascii_case(digest) {
        return Err(ApiError::internal(
            "object bytes failed size or SHA-256 verification",
        ));
    }
    Ok(())
}

async fn load_job(db: &SqlitePool, migration_id: &str) -> Result<Option<MigrationJob>, ApiError> {
    let row = sqlx::query(
        "SELECT migration_id,source_backend,source_store_id,target_backend,target_store_id,target_s3_prefix,state,object_count,reference_count FROM object_store_migration_jobs WHERE migration_id=?",
    )
    .bind(migration_id)
    .fetch_optional(db)
    .await
    .map_err(ApiError::internal)?;
    row.map(|row| {
        Ok(MigrationJob {
            migration_id: row.try_get("migration_id").map_err(ApiError::internal)?,
            source_backend: row.try_get("source_backend").map_err(ApiError::internal)?,
            source_store_id: row.try_get("source_store_id").map_err(ApiError::internal)?,
            target_backend: row.try_get("target_backend").map_err(ApiError::internal)?,
            target_store_id: row.try_get("target_store_id").map_err(ApiError::internal)?,
            target_s3_prefix: row
                .try_get("target_s3_prefix")
                .map_err(ApiError::internal)?,
            state: row.try_get("state").map_err(ApiError::internal)?,
            object_count: row.try_get("object_count").map_err(ApiError::internal)?,
            reference_count: row.try_get("reference_count").map_err(ApiError::internal)?,
        })
    })
    .transpose()
}

async fn load_items(db: &SqlitePool, migration_id: &str) -> Result<Vec<MigrationItem>, ApiError> {
    let rows = sqlx::query(
        "SELECT vault_id,object_id,source_backend,source_key,source_store_id,target_backend,target_key,target_store_id,expected_size,expected_sha256,state FROM object_store_migration_items WHERE migration_id=? ORDER BY vault_id,object_id",
    )
    .bind(migration_id)
    .fetch_all(db)
    .await
    .map_err(ApiError::internal)?;
    rows.into_iter()
        .map(|row| {
            Ok(MigrationItem {
                vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
                object_id: row.try_get("object_id").map_err(ApiError::internal)?,
                source_backend: row.try_get("source_backend").map_err(ApiError::internal)?,
                source_key: row.try_get("source_key").map_err(ApiError::internal)?,
                source_store_id: row.try_get("source_store_id").map_err(ApiError::internal)?,
                target_backend: row.try_get("target_backend").map_err(ApiError::internal)?,
                target_key: row.try_get("target_key").map_err(ApiError::internal)?,
                target_store_id: row.try_get("target_store_id").map_err(ApiError::internal)?,
                expected_size: row.try_get("expected_size").map_err(ApiError::internal)?,
                expected_sha256: row.try_get("expected_sha256").map_err(ApiError::internal)?,
                state: row.try_get("state").map_err(ApiError::internal)?,
            })
        })
        .collect()
}

async fn create_journal(
    db: &SqlitePool,
    job: &MigrationJob,
    objects: &[CatalogueObject],
    target: &ObjectStore,
    instance_id: &str,
) -> Result<(), ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::internal)?;
    let now = Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO object_store_migration_jobs(migration_id,source_backend,source_store_id,target_backend,target_store_id,target_s3_prefix,state,object_count,reference_count,created_at,updated_at) VALUES(?,?,?,?,?,?,'copying',?,?,?,?)",
    )
    .bind(&job.migration_id)
    .bind(&job.source_backend)
    .bind(&job.source_store_id)
    .bind(&job.target_backend)
    .bind(&job.target_store_id)
    .bind(&job.target_s3_prefix)
    .bind(job.object_count)
    .bind(job.reference_count)
    .bind(&now)
    .bind(&now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for object in objects {
        let (target_key, target_store_id) = if target.is_external() {
            let (key, store_id) = target
                .object_key(
                    instance_id,
                    &object.vault_id,
                    &object.object_id,
                    &job.migration_id,
                )
                .map_err(|_| ApiError::internal("could not derive migration destination key"))?;
            (Some(key), Some(store_id))
        } else {
            (None, None)
        };
        sqlx::query(
            "INSERT INTO object_store_migration_items(migration_id,vault_id,object_id,source_backend,source_key,source_store_id,target_backend,target_key,target_store_id,expected_size,expected_sha256,state,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,'pending',?,?)",
        )
        .bind(&job.migration_id)
        .bind(&object.vault_id)
        .bind(&object.object_id)
        .bind(&object.storage_backend)
        .bind(&object.storage_key)
        .bind(&object.storage_store_id)
        .bind(&job.target_backend)
        .bind(&target_key)
        .bind(&target_store_id)
        .bind(object.size)
        .bind(&object.sha256)
        .bind(&now)
        .bind(&now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }
    tx.commit().await.map_err(ApiError::internal)
}

fn validate_target_keys(
    target: &ObjectStore,
    items: &[MigrationItem],
    migration_id: &str,
    instance_id: &str,
) -> Result<(), ApiError> {
    for item in items {
        let (expected_key, expected_store_id) = if target.is_external() {
            let (key, store_id) = target
                .object_key(instance_id, &item.vault_id, &item.object_id, migration_id)
                .map_err(|_| ApiError::internal("could not derive migration destination key"))?;
            (Some(key), Some(store_id))
        } else {
            (None, None)
        };
        if item.target_key != expected_key || item.target_store_id != expected_store_id {
            return Err(ApiError::internal(
                "migration destination prefix or identity does not match its journal",
            ));
        }
    }
    Ok(())
}

fn ensure_store_matches(
    store: &ObjectStore,
    expected_backend: &str,
    expected_store_id: Option<&str>,
) -> Result<(), ApiError> {
    if store.backend_name() != expected_backend || store.store_id() != expected_store_id {
        return Err(ApiError::internal(
            "configured object store does not match the migration journal",
        ));
    }
    Ok(())
}

fn ensure_target_store_matches(
    store: &ObjectStore,
    expected_backend: &str,
    expected_store_id: Option<&str>,
    expected_s3_prefix: Option<&str>,
) -> Result<(), ApiError> {
    // Keep source matching limited to backend/store identity. Target S3
    // namespaces need an additional exact-prefix comparison because prefixes
    // are not part of the persisted S3 store identity.
    if !store.matches_migration_target(expected_backend, expected_store_id, expected_s3_prefix) {
        return Err(ApiError::internal(
            "configured object storage does not match the migration target",
        ));
    }
    Ok(())
}

fn ensure_job_configuration(
    job: &MigrationJob,
    source: &ObjectStore,
    objects: &[CatalogueObject],
) -> Result<(), ApiError> {
    if job.state != "copying"
        || job.object_count != objects.len() as i64
        || source.backend_name() != job.source_backend
        || source.store_id() != job.source_store_id.as_deref()
    {
        return Err(ApiError::internal(
            "object migration source or catalogue no longer matches its journal",
        ));
    }
    for object in objects {
        let is_source = object.storage_backend == job.source_backend
            && object.storage_store_id == job.source_store_id;
        let is_target = object.storage_backend == job.target_backend
            && object.storage_store_id == job.target_store_id;
        let is_legacy_sqlite = object.storage_backend == "sqlite"
            && object.storage_key.is_none()
            && object.storage_store_id.is_none();
        if !is_source && !is_target && !is_legacy_sqlite {
            return Err(ApiError::internal(
                "object catalogue contains an unrelated backend during migration",
            ));
        }
    }
    Ok(())
}

async fn verify_resumable_catalogue(
    db: &SqlitePool,
    job: &MigrationJob,
    objects: &[CatalogueObject],
) -> Result<(), ApiError> {
    let items = load_items(db, &job.migration_id).await?;
    if items.len() as i64 != job.object_count {
        return Err(ApiError::internal("object migration journal is incomplete"));
    }
    for item in &items {
        let object = objects
            .iter()
            .find(|object| object.vault_id == item.vault_id && object.object_id == item.object_id)
            .ok_or_else(|| ApiError::internal("migration catalogue item is missing"))?;
        if object.size != item.expected_size || object.sha256 != item.expected_sha256 {
            return Err(ApiError::internal("migration object metadata changed"));
        }
        match item.state.as_str() {
            "pending" if object_matches_source(object, item) => {}
            "catalogue_switched" if object_matches_target(object, item) => {}
            _ => {
                return Err(ApiError::internal(
                    "migration catalogue state is inconsistent",
                ));
            }
        }
    }
    let references = count_references(db).await?;
    if references != job.reference_count {
        return Err(ApiError::internal(
            "object reference count changed during offline migration",
        ));
    }
    Ok(())
}

fn object_matches_source(object: &CatalogueObject, item: &MigrationItem) -> bool {
    object.storage_backend == item.source_backend
        && object.storage_key == item.source_key
        && object.storage_store_id == item.source_store_id
        && object.storage_state == "available"
}

fn object_matches_target(object: &CatalogueObject, item: &MigrationItem) -> bool {
    object.storage_backend == item.target_backend
        && object.storage_key == item.target_key
        && object.storage_store_id == item.target_store_id
        && object.storage_state == "available"
}

async fn verify_item_catalogue(
    db: &SqlitePool,
    job: &MigrationJob,
    item: &MigrationItem,
    target: bool,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT bytes,size,sha256,storage_backend,storage_key,storage_store_id,storage_state FROM blob_objects WHERE vault_id=? AND object_id=?",
    )
    .bind(&item.vault_id)
    .bind(&item.object_id)
    .fetch_optional(db)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("migration catalogue row is missing"))?;
    let backend: String = row.try_get("storage_backend").map_err(ApiError::internal)?;
    let key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
    let store_id: Option<String> = row
        .try_get("storage_store_id")
        .map_err(ApiError::internal)?;
    let expected_backend = if target {
        &item.target_backend
    } else {
        &item.source_backend
    };
    let expected_key = if target {
        &item.target_key
    } else {
        &item.source_key
    };
    let expected_store = if target {
        &item.target_store_id
    } else {
        &item.source_store_id
    };
    if backend != *expected_backend
        || key != *expected_key
        || store_id != *expected_store
        || row.try_get::<i64, _>("size").map_err(ApiError::internal)? != item.expected_size
        || row
            .try_get::<String, _>("sha256")
            .map_err(ApiError::internal)?
            != item.expected_sha256
        || row
            .try_get::<String, _>("storage_state")
            .map_err(ApiError::internal)?
            != "available"
        || (!target && backend != job.source_backend && backend != "sqlite")
    {
        return Err(ApiError::internal(
            "migration catalogue compare-and-swap failed",
        ));
    }
    Ok(())
}

async fn switch_catalogue_item(
    db: &SqlitePool,
    job: &MigrationJob,
    item: &MigrationItem,
    verified_bytes: &[u8],
) -> Result<(), ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::internal)?;
    let target_bytes: &[u8] = if item.target_backend == "sqlite" {
        verified_bytes
    } else {
        &[]
    };
    let changed = sqlx::query(
        "UPDATE blob_objects SET bytes=?,storage_backend=?,storage_key=?,storage_store_id=?,storage_state='available' WHERE vault_id=? AND object_id=? AND storage_backend=? AND storage_key IS ? AND storage_store_id IS ? AND size=? AND sha256=? AND storage_state='available' AND bytes=?",
    )
    .bind(target_bytes)
    .bind(&item.target_backend)
    .bind(&item.target_key)
    .bind(&item.target_store_id)
    .bind(&item.vault_id)
    .bind(&item.object_id)
    .bind(&item.source_backend)
    .bind(&item.source_key)
    .bind(&item.source_store_id)
    .bind(item.expected_size)
    .bind(&item.expected_sha256)
    .bind(if item.source_backend == "sqlite" {
        verified_bytes
    } else {
        &[]
    })
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if changed.rows_affected() != 1 {
        return Err(ApiError::internal(
            "object catalogue changed before destination cutover",
        ));
    }
    let now = Utc::now().to_rfc3339();
    let checkpoint = sqlx::query(
        "UPDATE object_store_migration_items SET state='catalogue_switched',updated_at=? WHERE migration_id=? AND vault_id=? AND object_id=? AND state='pending'",
    )
    .bind(&now)
    .bind(&job.migration_id)
    .bind(&item.vault_id)
    .bind(&item.object_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if checkpoint.rows_affected() != 1 {
        return Err(ApiError::internal(
            "migration item checkpoint was not committed",
        ));
    }
    sqlx::query("UPDATE object_store_migration_jobs SET updated_at=? WHERE migration_id=? AND state='copying'")
        .bind(now)
        .bind(&job.migration_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)
}

async fn verify_copy_completion(
    db: &SqlitePool,
    target: &ObjectStore,
    job: &MigrationJob,
    items: &[MigrationItem],
) -> Result<(), ApiError> {
    reject_unsafe_catalogue_state(db).await?;
    let current_objects = read_catalogue_objects(db).await?;
    if current_objects.len() as i64 != job.object_count
        || count_references(db).await? != job.reference_count
    {
        return Err(ApiError::internal(
            "object catalogue or reference count changed during migration",
        ));
    }
    for item in items {
        let current = current_objects
            .iter()
            .find(|object| object.vault_id == item.vault_id && object.object_id == item.object_id)
            .ok_or_else(|| ApiError::internal("migration destination catalogue row is missing"))?;
        if !object_matches_target(current, item) {
            return Err(ApiError::internal(
                "not all catalogue rows point at the migration destination",
            ));
        }
        let bytes = if item.target_backend == "sqlite" {
            read_catalogue_source(target, db, current).await?
        } else {
            target
                .read_object(
                    item.target_key.as_deref().unwrap_or_default(),
                    item.expected_size,
                    &item.expected_sha256,
                    None,
                )
                .await
                .map_err(map_store_error)?
        };
        verify_payload(&bytes, item.expected_size, &item.expected_sha256)?;
    }
    target.validate_catalogue_contents(db).await?;
    Ok(())
}

async fn verify_completed_job(
    db: &SqlitePool,
    target: &ObjectStore,
    job: &MigrationJob,
) -> Result<(), ApiError> {
    if job.state != "complete" {
        return Err(ApiError::internal("object migration is not complete"));
    }
    let items = load_items(db, &job.migration_id).await?;
    if items.len() as i64 != job.object_count || count_references(db).await? != job.reference_count
    {
        return Err(ApiError::internal(
            "completed migration journal is inconsistent",
        ));
    }
    let objects = read_catalogue_objects(db).await?;
    if objects.len() as i64 != job.object_count {
        return Err(ApiError::internal(
            "completed object catalogue is inconsistent",
        ));
    }
    for item in &items {
        if item.state != "catalogue_switched" {
            return Err(ApiError::internal("completed migration has pending items"));
        }
        let object = objects
            .iter()
            .find(|object| object.vault_id == item.vault_id && object.object_id == item.object_id)
            .ok_or_else(|| ApiError::internal("completed object is missing"))?;
        if !object_matches_target(object, item) {
            return Err(ApiError::internal(
                "completed object identity is inconsistent",
            ));
        }
        let bytes = if item.target_backend == "sqlite" {
            read_catalogue_source(target, db, object).await?
        } else {
            target
                .read_object(
                    item.target_key.as_deref().unwrap_or_default(),
                    item.expected_size,
                    &item.expected_sha256,
                    None,
                )
                .await
                .map_err(map_store_error)?
        };
        verify_payload(&bytes, item.expected_size, &item.expected_sha256)?;
    }
    target.validate_catalogue_contents(db).await
}

fn map_store_error(error: ObjectStoreError) -> ApiError {
    match error {
        ObjectStoreError::Unavailable => {
            ApiError::internal("configured object store is unavailable")
        }
        ObjectStoreError::IntegrityMismatch => {
            ApiError::internal("object store integrity verification failed")
        }
        ObjectStoreError::ImmutableConflict => {
            ApiError::internal("destination immutable object key conflicts with different content")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MigrationItem, MigrationJob, switch_catalogue_item, verify_payload};
    use sha2::Digest;
    use sqlx::{Row, SqlitePool, sqlite::SqlitePoolOptions};

    const TEST_BYTES: &[u8] = b"encrypted-payload-01";

    #[test]
    fn migration_payload_verification_checks_exact_size_and_digest() {
        let bytes = b"client encrypted attachment";
        let digest = hex::encode(sha2::Sha256::digest(bytes));
        verify_payload(bytes, bytes.len() as i64, &digest).unwrap();
        assert!(verify_payload(bytes, bytes.len() as i64 + 1, &digest).is_err());
        assert!(verify_payload(bytes, bytes.len() as i64, &"00".repeat(32)).is_err());
    }

    async fn migration_pool() -> SqlitePool {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE blob_objects(vault_id TEXT,object_id TEXT,bytes BLOB,size INTEGER,sha256 TEXT,created_at TEXT,gc_after INTEGER,storage_backend TEXT,storage_key TEXT,storage_store_id TEXT,storage_state TEXT,PRIMARY KEY(vault_id,object_id))",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE object_references(vault_id TEXT,revision_id TEXT,object_id TEXT,PRIMARY KEY(vault_id,revision_id,object_id))",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_jobs(migration_id TEXT PRIMARY KEY,source_backend TEXT,source_store_id TEXT,target_backend TEXT,target_store_id TEXT,target_s3_prefix TEXT,state TEXT,object_count INTEGER,reference_count INTEGER,created_at TEXT,updated_at TEXT)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_items(migration_id TEXT,vault_id TEXT,object_id TEXT,state TEXT,updated_at TEXT,PRIMARY KEY(migration_id,vault_id,object_id))",
        )
        .execute(&db)
        .await
        .unwrap();
        db
    }

    fn test_job() -> MigrationJob {
        MigrationJob {
            migration_id: "11111111-1111-4111-8111-111111111111".into(),
            source_backend: "sqlite".into(),
            source_store_id: None,
            target_backend: "filesystem".into(),
            target_store_id: Some("target-store".into()),
            target_s3_prefix: None,
            state: "copying".into(),
            object_count: 1,
            reference_count: 1,
        }
    }

    fn test_item(digest: &str) -> MigrationItem {
        MigrationItem {
            vault_id: "22222222-2222-4222-8222-222222222222".into(),
            object_id: "33333333-3333-4333-8333-333333333333".into(),
            source_backend: "sqlite".into(),
            source_key: None,
            source_store_id: None,
            target_backend: "filesystem".into(),
            target_key: Some("atermius/objects/v1/target".into()),
            target_store_id: Some("target-store".into()),
            expected_size: TEST_BYTES.len() as i64,
            expected_sha256: digest.to_owned(),
            state: "pending".into(),
        }
    }

    async fn seed_switch_rows(db: &SqlitePool, item: &MigrationItem, bytes: &[u8]) {
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) VALUES(?,?,?,?,?,'2026-01-01T00:00:00Z',123,'sqlite',NULL,NULL,'available')",
        )
        .bind(&item.vault_id)
        .bind(&item.object_id)
        .bind(bytes)
        .bind(item.expected_size)
        .bind(&item.expected_sha256)
        .execute(db)
        .await
        .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,'44444444-4444-4444-8444-444444444444',?)")
            .bind(&item.vault_id)
            .bind(&item.object_id)
            .execute(db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_store_migration_jobs(migration_id,target_s3_prefix,state,updated_at) VALUES(?,NULL,'copying','before')")
            .bind(&test_job().migration_id)
            .execute(db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_store_migration_items(migration_id,vault_id,object_id,state,updated_at) VALUES(?,?,?,'pending','before')")
            .bind(&test_job().migration_id)
            .bind(&item.vault_id)
            .bind(&item.object_id)
            .execute(db)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn catalogue_cutover_keeps_references_and_gc_metadata_in_same_checkpoint() {
        let db = migration_pool().await;
        let bytes = TEST_BYTES;
        let digest = hex::encode(sha2::Sha256::digest(bytes));
        let job = test_job();
        let item = test_item(&digest);
        seed_switch_rows(&db, &item, bytes).await;

        switch_catalogue_item(&db, &job, &item, bytes)
            .await
            .unwrap();

        let blob = sqlx::query("SELECT bytes,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state FROM blob_objects WHERE vault_id=? AND object_id=?")
            .bind(&item.vault_id)
            .bind(&item.object_id)
            .fetch_one(&db)
            .await
            .unwrap();
        assert!(blob.get::<Vec<u8>, _>("bytes").is_empty());
        assert_eq!(blob.get::<String, _>("created_at"), "2026-01-01T00:00:00Z");
        assert_eq!(blob.get::<i64, _>("gc_after"), 123);
        assert_eq!(blob.get::<String, _>("storage_backend"), "filesystem");
        assert_eq!(
            blob.get::<Option<String>, _>("storage_key"),
            item.target_key
        );
        assert_eq!(
            blob.get::<Option<String>, _>("storage_store_id"),
            item.target_store_id
        );
        assert_eq!(blob.get::<String, _>("storage_state"), "available");
        let refs: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM object_references")
            .fetch_one(&db)
            .await
            .unwrap();
        let item_state: String = sqlx::query_scalar(
            "SELECT state FROM object_store_migration_items WHERE migration_id=?",
        )
        .bind(&job.migration_id)
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(refs, 1);
        assert_eq!(item_state, "catalogue_switched");
    }

    #[tokio::test]
    async fn source_byte_compare_and_swap_refuses_changed_sqlite_content() {
        let db = migration_pool().await;
        let expected = TEST_BYTES;
        let changed = b"XXXXXXXXXXXXXXXXXXX";
        let digest = hex::encode(sha2::Sha256::digest(expected));
        let job = test_job();
        let item = test_item(&digest);
        seed_switch_rows(&db, &item, changed).await;

        assert!(
            switch_catalogue_item(&db, &job, &item, expected)
                .await
                .is_err()
        );
        let backend: String = sqlx::query_scalar(
            "SELECT storage_backend FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&item.vault_id)
        .bind(&item.object_id)
        .fetch_one(&db)
        .await
        .unwrap();
        let state: String = sqlx::query_scalar(
            "SELECT state FROM object_store_migration_items WHERE migration_id=?",
        )
        .bind(&job.migration_id)
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(backend, "sqlite");
        assert_eq!(state, "pending");
    }

    #[tokio::test]
    async fn migration_0037_backfills_proven_prefixes_and_marks_unknown_ones() {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query("CREATE TABLE instance_meta(id INTEGER PRIMARY KEY,instance_id TEXT NOT NULL)")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO instance_meta(id,instance_id) VALUES(1,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')")
            .execute(&db)
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_jobs(migration_id TEXT PRIMARY KEY,target_backend TEXT NOT NULL,target_store_id TEXT,state TEXT,object_count INTEGER,updated_at TEXT)",
        )
        .execute(&db)
        .await
        .unwrap();
        sqlx::query(
            "CREATE TABLE object_store_migration_items(migration_id TEXT,vault_id TEXT,object_id TEXT,target_key TEXT)",
        )
        .execute(&db)
        .await
        .unwrap();

        let known = "11111111-1111-4111-8111-111111111111";
        let no_prefix = "22222222-2222-4222-8222-222222222222";
        let empty = "33333333-3333-4333-8333-333333333333";
        let malformed = "44444444-4444-4444-8444-444444444444";
        let mixed = "55555555-5555-4555-8555-555555555555";
        let filesystem = "66666666-6666-4666-8666-666666666666";
        for (migration_id, backend, count) in [
            (known, "s3", 2),
            (no_prefix, "s3", 1),
            (empty, "s3", 0),
            (malformed, "s3", 1),
            (mixed, "s3", 2),
            (filesystem, "filesystem", 0),
        ] {
            sqlx::query(
                "INSERT INTO object_store_migration_jobs(migration_id,target_backend,target_store_id,state,object_count,updated_at) VALUES(?,?,?,'complete',?,'2026-01-01T00:00:00Z')",
            )
            .bind(migration_id)
            .bind(backend)
            .bind((backend == "s3").then_some("test-store"))
            .bind(count)
            .execute(&db)
            .await
            .unwrap();
        }

        let instance_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        let prefix = "team/atermius/objects/v1/archive";
        for (migration_id, vault_id, object_id, prefix) in [
            (
                known,
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
                Some(prefix),
            ),
            (
                known,
                "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
                Some(prefix),
            ),
            (
                no_prefix,
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "ffffffff-ffff-4fff-8fff-ffffffffffff",
                None,
            ),
            (
                malformed,
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "12121212-1212-4212-8212-121212121212",
                Some("known"),
            ),
            (
                mixed,
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "13131313-1313-4313-8313-131313131313",
                Some("prefix-a"),
            ),
            (
                mixed,
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "14141414-1414-4414-8414-141414141414",
                Some("prefix-b"),
            ),
        ] {
            let key = if migration_id == malformed {
                "malformed-key".to_owned()
            } else {
                let suffix = format!(
                    "atermius/objects/v1/{instance_id}/{vault_id}/{object_id}/{migration_id}"
                );
                prefix
                    .map(|prefix| format!("{prefix}/{suffix}"))
                    .unwrap_or(suffix)
            };
            sqlx::query(
                "INSERT INTO object_store_migration_items(migration_id,vault_id,object_id,target_key) VALUES(?,?,?,?)",
            )
            .bind(migration_id)
            .bind(vault_id)
            .bind(object_id)
            .bind(key)
            .execute(&db)
            .await
            .unwrap();
        }

        sqlx::raw_sql(include_str!(
            "../migrations/0037_object_store_migration_target_prefix.sql"
        ))
        .execute(&db)
        .await
        .unwrap();

        let stored_prefix: Option<String> = sqlx::query_scalar(
            "SELECT target_s3_prefix FROM object_store_migration_jobs WHERE migration_id=?",
        )
        .bind(known)
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(stored_prefix.as_deref(), Some(prefix));
        let stored_prefix: Option<String> = sqlx::query_scalar(
            "SELECT target_s3_prefix FROM object_store_migration_jobs WHERE migration_id=?",
        )
        .bind(no_prefix)
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(stored_prefix.as_deref(), Some(""));
        for migration_id in [empty, malformed, mixed] {
            let stored_prefix: Option<String> = sqlx::query_scalar(
                "SELECT target_s3_prefix FROM object_store_migration_jobs WHERE migration_id=?",
            )
            .bind(migration_id)
            .fetch_one(&db)
            .await
            .unwrap();
            assert_eq!(stored_prefix.as_deref(), Some("!legacy-s3-prefix-unknown!"));
        }
        let non_s3_prefix: Option<String> = sqlx::query_scalar(
            "SELECT target_s3_prefix FROM object_store_migration_jobs WHERE migration_id=?",
        )
        .bind(filesystem)
        .fetch_one(&db)
        .await
        .unwrap();
        assert_eq!(non_s3_prefix, None);
        db.close().await;
    }
}

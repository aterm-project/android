//! PostgreSQL reservations, object transfer, and shared object garbage collection.
//!
//! Ciphertext bytes live in the configured shared S3/filesystem store. This
//! module keeps authorization, quota, upload chunks, immutable catalogue
//! metadata, reference reachability, and deletion intents in PostgreSQL.
//! Provider I/O is always performed after the owning transaction is closed.

use axum::{
    body::Bytes,
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;

use crate::{
    ApiError, AppState,
    auth::AuthUser,
    object_store::{ObjectStore, ObjectStoreError},
    objects::{CHUNK_SIZE_BYTES, InitRequest},
    pg_record_redaction::require_redaction_client_for_vault_tx,
    sha256_hex,
};

const DELETE_GRACE_SECONDS: i64 = 90_000;
const GC_BATCH_MAX: i64 = 100;
const UPLOAD_PRUNE_BATCH_MAX: i64 = 500;
const BACKUP_PIN_MIN_LEASE_SECONDS: i64 = 30;
const BACKUP_PIN_MAX_LEASE_SECONDS: i64 = 3_600;
const BACKUP_PIN_CLEANUP_BATCH_MAX: i64 = 1_000;

/// An immutable external object selected from the same PostgreSQL snapshot
/// that owns its backup pin. The backup worker copies and verifies these bytes
/// only after the snapshot transaction has committed the pins.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PgBackupObject {
    pub(crate) vault_id: String,
    pub(crate) object_id: String,
    pub(crate) storage_backend: String,
    pub(crate) storage_key: String,
    pub(crate) storage_store_id: String,
    pub(crate) size: i64,
    pub(crate) sha256: String,
}

fn validate_backup_pin_request(backup_id: &str, lease_seconds: i64) -> Result<(), ApiError> {
    if !crate::is_canonical_uuid(backup_id) {
        return Err(ApiError::internal("backup object pin ID is invalid"));
    }
    if !(BACKUP_PIN_MIN_LEASE_SECONDS..=BACKUP_PIN_MAX_LEASE_SECONDS).contains(&lease_seconds) {
        return Err(ApiError::internal(
            "backup object pin lease is out of range",
        ));
    }
    Ok(())
}

/// Locks every available external blob row in the caller's stable snapshot,
/// inserts the matching store/key pins using PostgreSQL's clock, and returns
/// the exact catalogue rows from that snapshot. The caller must use a
/// REPEATABLE READ transaction, export/import its snapshot for the database
/// dump, and keep this transaction open until the dump has imported it. That
/// ordering makes the returned object manifest and dumped metadata identical.
pub(crate) async fn pin_objects_for_backup_tx(
    tx: &mut Transaction<'_, Postgres>,
    backup_id: &str,
    lease_seconds: i64,
) -> Result<Vec<PgBackupObject>, ApiError> {
    validate_backup_pin_request(backup_id, lease_seconds)?;
    let isolation: String = sqlx::query_scalar("SELECT current_setting('transaction_isolation')")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if isolation != "repeatable read" {
        return Err(ApiError::internal(
            "backup object pins require a REPEATABLE READ transaction",
        ));
    }

    let rows = sqlx::query(
        r#"
        WITH db_clock AS MATERIALIZED (
            SELECT clock_timestamp() AS now
        ), selected AS MATERIALIZED (
            SELECT b.vault_id,b.object_id,b.storage_backend,b.storage_key,
                   b.storage_store_id,b.size,b.sha256
            FROM blob_objects b
            WHERE b.storage_state='available'
            ORDER BY b.vault_id,b.object_id
            FOR SHARE OF b
        ), pinned AS (
            INSERT INTO backup_object_pins(backup_id,storage_store_id,storage_key,expires_at)
            SELECT $1,s.storage_store_id,s.storage_key,
                   c.now + ($2::double precision * INTERVAL '1 second')
            FROM selected s CROSS JOIN db_clock c
            WHERE s.storage_backend IN ('s3','filesystem')
              AND s.storage_store_id IS NOT NULL AND s.storage_store_id<>''
              AND s.storage_key IS NOT NULL AND s.storage_key<>''
            ON CONFLICT(backup_id,storage_store_id,storage_key)
            DO UPDATE SET expires_at=EXCLUDED.expires_at
            RETURNING storage_store_id,storage_key
        )
        SELECT s.vault_id,s.object_id,s.storage_backend,s.storage_key,
               s.storage_store_id,s.size,s.sha256,
               (p.storage_store_id IS NOT NULL) AS pinned
        FROM selected s
        LEFT JOIN pinned p ON p.storage_store_id=s.storage_store_id
                          AND p.storage_key=s.storage_key
        ORDER BY s.vault_id,s.object_id
        "#,
    )
    .bind(backup_id)
    .bind(lease_seconds)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let mut objects = Vec::with_capacity(rows.len());
    for row in rows {
        let pinned: bool = row.try_get("pinned").map_err(ApiError::internal)?;
        let backend: String = row.try_get("storage_backend").map_err(ApiError::internal)?;
        let storage_key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
        let storage_store_id: Option<String> = row
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        let storage_key = storage_key
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("backup object storage key is invalid"))?;
        let storage_store_id = storage_store_id
            .filter(|value| !value.is_empty())
            .ok_or_else(|| ApiError::internal("backup object storage identity is invalid"))?;
        if !pinned || !matches!(backend.as_str(), "s3" | "filesystem") {
            return Err(ApiError::internal(
                "available PostgreSQL backup object could not be pinned",
            ));
        }
        let size: i64 = row.try_get("size").map_err(ApiError::internal)?;
        let sha256: String = row.try_get("sha256").map_err(ApiError::internal)?;
        if size <= 0 || sha256.len() != 64 || !sha256.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return Err(ApiError::internal(
                "backup object integrity metadata is invalid",
            ));
        }
        objects.push(PgBackupObject {
            vault_id: row.try_get("vault_id").map_err(ApiError::internal)?,
            object_id: row.try_get("object_id").map_err(ApiError::internal)?,
            storage_backend: backend,
            storage_key,
            storage_store_id,
            size,
            sha256: sha256.to_ascii_lowercase(),
        });
    }
    let object_count = i64::try_from(objects.len())
        .map_err(|_| ApiError::internal("backup object count exceeds PostgreSQL limits"))?;
    sqlx::query(
        "INSERT INTO backup_object_pin_sets(backup_id,object_count,expires_at) \
         VALUES($1,$2,clock_timestamp()+($3::double precision * INTERVAL '1 second'))",
    )
    .bind(backup_id)
    .bind(object_count)
    .bind(lease_seconds)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(objects)
}

/// Renews an existing complete pin set inside its owning transaction. This is
/// used while a pg_dump snapshot transaction is still open; updating the
/// uncommitted rows there avoids a second connection blocking on its row
/// locks. The header detects expired rows even after bounded cleanup removed
/// some keys.
pub(crate) async fn renew_backup_pins_tx(
    tx: &mut Transaction<'_, Postgres>,
    backup_id: &str,
    lease_seconds: i64,
) -> Result<(), ApiError> {
    validate_backup_pin_request(backup_id, lease_seconds)?;
    let set = sqlx::query(
        "SELECT object_count,expires_at FROM backup_object_pin_sets \
         WHERE backup_id=$1 FOR UPDATE",
    )
    .bind(backup_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| {
        ApiError::conflict(
            "BACKUP_OBJECT_PINS_EXPIRED",
            "backup object pin set is missing; restart the backup",
        )
    })?;
    let expected_count: i64 = set.try_get("object_count").map_err(ApiError::internal)?;
    let set_expires_at: DateTime<Utc> = set.try_get("expires_at").map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT expires_at FROM backup_object_pins \
         WHERE backup_id=$1 ORDER BY storage_store_id,storage_key FOR UPDATE",
    )
    .bind(backup_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let db_now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if expected_count < 0
        || rows.len() as i64 != expected_count
        || set_expires_at <= db_now
        || rows.iter().any(|row| {
            row.try_get::<DateTime<Utc>, _>("expires_at")
                .map(|expires_at| expires_at <= db_now)
                .unwrap_or(true)
        })
    {
        return Err(ApiError::conflict(
            "BACKUP_OBJECT_PINS_EXPIRED",
            "backup object pin lease expired; restart the backup",
        ));
    }

    let renewed = sqlx::query(
        "UPDATE backup_object_pins \
         SET expires_at=clock_timestamp()+($2::double precision * INTERVAL '1 second') \
         WHERE backup_id=$1 AND expires_at>clock_timestamp()",
    )
    .bind(backup_id)
    .bind(lease_seconds)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    let set_renewed = sqlx::query(
        "UPDATE backup_object_pin_sets \
         SET expires_at=clock_timestamp()+($2::double precision * INTERVAL '1 second') \
         WHERE backup_id=$1 AND expires_at>clock_timestamp()",
    )
    .bind(backup_id)
    .bind(lease_seconds)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .rows_affected();
    if renewed != expected_count as u64 || set_renewed != 1 {
        return Err(ApiError::conflict(
            "BACKUP_OBJECT_PINS_EXPIRED",
            "backup object pin lease expired; restart the backup",
        ));
    }
    Ok(())
}

#[derive(Clone)]
pub(crate) struct PgObjectRepository {
    pool: PgPool,
    instance_id: String,
}

impl PgObjectRepository {
    pub(crate) fn new(pool: PgPool, instance_id: String) -> Self {
        Self { pool, instance_id }
    }

    /// Extends every still-live pin for one backup job. A job whose lease
    /// already expired cannot renew itself: GC may have removed its bytes, so
    /// the caller must fail that backup rather than silently continuing with a
    /// partial set.
    pub(crate) async fn renew_backup_pins(
        &self,
        backup_id: &str,
        lease_seconds: i64,
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        renew_backup_pins_tx(&mut tx, backup_id, lease_seconds).await?;
        tx.commit().await.map_err(ApiError::internal)
    }

    /// Releases all keys held by a completed, failed, or cancelled backup.
    pub(crate) async fn release_backup_pins(&self, backup_id: &str) -> Result<(), ApiError> {
        if !crate::is_canonical_uuid(backup_id) {
            return Err(ApiError::internal("backup object pin ID is invalid"));
        }
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let _ = sqlx::query_scalar::<_, String>(
            "SELECT backup_id FROM backup_object_pin_sets WHERE backup_id=$1 FOR UPDATE",
        )
        .bind(backup_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM backup_object_pins WHERE backup_id=$1")
            .bind(backup_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM backup_object_pin_sets WHERE backup_id=$1")
            .bind(backup_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)
    }

    /// Removes a bounded number of expired leases using PostgreSQL's clock.
    /// GC and the delete drainer also check expiry inline, so cleanup lag never
    /// turns an expired lease into a deletion blocker.
    pub(crate) async fn cleanup_expired_backup_pins(&self, limit: i64) -> Result<u64, ApiError> {
        let pins = sqlx::query(
            r#"
            WITH expired AS (
                SELECT backup_id,storage_store_id,storage_key
                FROM backup_object_pins
                WHERE expires_at<=clock_timestamp()
                ORDER BY expires_at,backup_id,storage_store_id,storage_key
                LIMIT $1 FOR UPDATE SKIP LOCKED
            )
            DELETE FROM backup_object_pins p USING expired e
            WHERE p.backup_id=e.backup_id
              AND p.storage_store_id=e.storage_store_id
              AND p.storage_key=e.storage_key
            "#,
        )
        .bind(limit.clamp(1, BACKUP_PIN_CLEANUP_BATCH_MAX))
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        let sets = sqlx::query(
            r#"
            WITH expired AS (
                SELECT backup_id
                FROM backup_object_pin_sets
                WHERE expires_at<=clock_timestamp()
                ORDER BY expires_at,backup_id
                LIMIT $1 FOR UPDATE SKIP LOCKED
            )
            DELETE FROM backup_object_pin_sets s USING expired e
            WHERE s.backup_id=e.backup_id
            "#,
        )
        .bind(limit.clamp(1, BACKUP_PIN_CLEANUP_BATCH_MAX))
        .execute(&self.pool)
        .await
        .map_err(ApiError::internal)?;
        Ok(pins.rows_affected() + sets.rows_affected())
    }

    /// PostgreSQL sync nodes need one shared object store. The default SQLite
    /// object backend is node-local, so starting a multi-node PG runtime with
    /// it would make uploads invisible to other nodes and is rejected here.
    pub(crate) async fn validate_schema(&self, object_store: &ObjectStore) -> Result<(), ApiError> {
        if !object_store.is_external() {
            return Err(ApiError::internal(
                "PostgreSQL sync mode requires a shared S3 or filesystem object store",
            ));
        }
        for table in ["uploads", "upload_chunks"] {
            let exists: Option<String> = sqlx::query_scalar("SELECT to_regclass($1)::text")
                .bind(table)
                .fetch_one(&self.pool)
                .await
                .map_err(|_| ApiError::internal("PostgreSQL object schema validation failed"))?;
            if exists.is_none() {
                return Err(ApiError::internal(
                    "PostgreSQL object schema is incomplete; apply migration 0015",
                ));
            }
        }
        let store_id = object_store.store_id().ok_or_else(|| {
            ApiError::internal("PostgreSQL sync mode requires a shared object-store identity")
        })?;
        let mismatched: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM blob_objects WHERE storage_backend NOT IN ('s3','filesystem') \
             OR storage_key IS NULL OR storage_key='' OR storage_store_id IS DISTINCT FROM $2 \
             OR storage_backend IS DISTINCT FROM $1)",
        )
        .bind(object_store.backend_name())
        .bind(store_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL object catalogue validation failed"))?;
        if mismatched {
            return Err(ApiError::internal(
                "configured shared object store does not match the PostgreSQL object catalogue",
            ));
        }
        let mismatched_upload: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM uploads WHERE state IN ('open','completing') \
             AND (storage_backend IS DISTINCT FROM $1 OR storage_store_id IS DISTINCT FROM $2 \
                  OR storage_key IS NULL OR storage_key=''))",
        )
        .bind(object_store.backend_name())
        .bind(store_id)
        .fetch_one(&self.pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL object reservation validation failed"))?;
        if mismatched_upload {
            return Err(ApiError::internal(
                "configured shared object store does not match an active PostgreSQL upload",
            ));
        }
        Ok(())
    }

    pub(crate) async fn init_upload(
        &self,
        state: &AppState,
        user: &AuthUser,
        vault_id: &str,
        request: InitRequest,
    ) -> Result<Value, ApiError> {
        if !crate::is_canonical_uuid(&request.object_id) {
            return Err(ApiError::bad_request(
                "INVALID_OBJECT_ID",
                "object_id must be a lowercase canonical UUID",
            ));
        }
        if request.size <= 0 || request.size > state.config.max_object_bytes {
            return Err(ApiError::too_large("object size exceeds configured limit"));
        }
        if request.sha256.len() != 64
            || !request.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(ApiError::bad_request(
                "INVALID_OBJECT_HASH",
                "sha256 must be a hexadecimal digest",
            ));
        }
        let storage_backend = state.object_store.backend_name();
        let storage_store_id = state.object_store.store_id().ok_or_else(|| {
            ApiError::internal("PostgreSQL sync mode has no shared object-store identity")
        })?;
        if !matches!(storage_backend, "s3" | "filesystem") {
            return Err(ApiError::internal(
                "PostgreSQL sync mode requires a shared object store",
            ));
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_vault_tx(&mut tx, user, vault_id, true).await?;
        self.expire_object_reservations_tx(
            &mut tx,
            vault_id,
            &request.object_id,
            DELETE_GRACE_SECONDS,
        )
        .await?;

        let object_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM blob_objects WHERE vault_id=$1 AND object_id=$2)",
        )
        .bind(vault_id)
        .bind(&request.object_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if object_exists {
            return Err(ApiError::conflict(
                "OBJECT_EXISTS",
                "object ids are immutable",
            ));
        }

        let digest = request.sha256.to_ascii_lowercase();
        let own_mismatch: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM uploads WHERE vault_id=$1 AND object_id=$2 AND user_id=$3 \
             AND state IN ('open','completing') AND expires_at>clock_timestamp() \
             AND (expected_size<>$4 OR expected_sha256<>$5))",
        )
        .bind(vault_id)
        .bind(&request.object_id)
        .bind(&user.user_id)
        .bind(request.size)
        .bind(&digest)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if own_mismatch {
            return Err(ApiError::conflict(
                "UPLOAD_RESERVATION_CONFLICT",
                "object id already has an open reservation with different content metadata",
            ));
        }

        let existing = sqlx::query(
            "SELECT u.upload_id,u.expires_at FROM uploads u \
             WHERE u.vault_id=$1 AND u.object_id=$2 AND u.user_id=$3 \
               AND u.state IN ('open','completing') AND u.expires_at>clock_timestamp() \
               AND u.expected_size=$4 AND u.expected_sha256=$5 \
             ORDER BY (SELECT COUNT(*) FROM upload_chunks c WHERE c.upload_id=u.upload_id) DESC, \
                      u.created_at,u.upload_id LIMIT 1",
        )
        .bind(vault_id)
        .bind(&request.object_id)
        .bind(&user.user_id)
        .bind(request.size)
        .bind(&digest)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if let Some(row) = existing {
            let upload_id: String = row.try_get("upload_id").map_err(ApiError::internal)?;
            let expires_at: DateTime<Utc> =
                row.try_get("expires_at").map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "upload_id": upload_id,
                "chunk_size": CHUNK_SIZE_BYTES,
                "expires_at": expires_at.to_rfc3339(),
            }));
        }

        let other_user_has_reservation: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM uploads WHERE vault_id=$1 AND object_id=$2 AND user_id<>$3 \
             AND state IN ('open','completing') AND expires_at>clock_timestamp())",
        )
        .bind(vault_id)
        .bind(&request.object_id)
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if other_user_has_reservation {
            return Err(ApiError::conflict(
                "UPLOAD_IN_PROGRESS",
                "object id already has an open upload reservation",
            ));
        }

        let quota_row = sqlx::query(
            "SELECT quota_bytes, \
               ((SELECT COALESCE(SUM(size),0) FROM blob_objects WHERE vault_id=$1) + \
                (SELECT COALESCE(SUM(expected_size),0) FROM uploads WHERE vault_id=$1 \
                 AND state IN ('open','completing') AND expires_at>clock_timestamp()))::text AS used \
             FROM vaults WHERE vault_id=$1",
        )
        .bind(vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let quota: i64 = quota_row
            .try_get("quota_bytes")
            .map_err(ApiError::internal)?;
        let used_text: String = quota_row.try_get("used").map_err(ApiError::internal)?;
        let used = used_text
            .parse::<i128>()
            .map_err(|_| ApiError::internal("vault object quota total is invalid"))?;
        if used.saturating_add(i128::from(request.size)) > i128::from(quota) {
            return Err(ApiError::new(
                StatusCode::INSUFFICIENT_STORAGE,
                "QUOTA_EXCEEDED",
                "vault storage quota is exceeded",
            ));
        }

        let upload_id = Uuid::new_v4().to_string();
        let (storage_key, generated_store_id) = state
            .object_store
            .object_key(&self.instance_id, vault_id, &request.object_id, &upload_id)
            .map_err(crate::object_store::storage_api_error)?;
        if generated_store_id != storage_store_id {
            return Err(ApiError::internal(
                "object-store identity changed during upload init",
            ));
        }
        let expires_at: DateTime<Utc> = sqlx::query_scalar(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256, \
             chunk_size,state,expires_at,created_at,storage_backend,storage_store_id,storage_key) \
             VALUES($1,$2,$3,$4,$5,$6,$7,'open',clock_timestamp() + INTERVAL '24 hours',clock_timestamp(),$8,$9,$10) \
             RETURNING expires_at",
        )
        .bind(&upload_id)
        .bind(vault_id)
        .bind(&user.user_id)
        .bind(&request.object_id)
        .bind(request.size)
        .bind(&digest)
        .bind(CHUNK_SIZE_BYTES as i64)
        .bind(storage_backend)
        .bind(storage_store_id)
        .bind(&storage_key)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "upload_id": upload_id,
            "chunk_size": CHUNK_SIZE_BYTES,
            "expires_at": expires_at.to_rfc3339(),
        }))
    }

    async fn expire_object_reservations_tx(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        vault_id: &str,
        object_id: &str,
        delete_delay_seconds: i64,
    ) -> Result<(), ApiError> {
        let rows = sqlx::query(
            "SELECT upload_id,storage_backend,storage_store_id,storage_key,expected_size,expected_sha256,state \
             FROM uploads WHERE vault_id=$1 AND object_id=$2 AND state IN ('open','completing') \
               AND expires_at<=clock_timestamp() FOR UPDATE",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            let state: String = row.try_get("state").map_err(ApiError::internal)?;
            if state == "completing" {
                enqueue_upload_delete_tx(tx, &row, delete_delay_seconds).await?;
            }
            let upload_id: String = row.try_get("upload_id").map_err(ApiError::internal)?;
            sqlx::query("UPDATE uploads SET state='expired' WHERE upload_id=$1")
                .bind(&upload_id)
                .execute(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("DELETE FROM upload_chunks WHERE upload_id=$1")
                .bind(upload_id)
                .execute(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
        }
        Ok(())
    }

    pub(crate) async fn put_chunk(
        &self,
        user: &AuthUser,
        upload_id: &str,
        index: i64,
        body: Bytes,
    ) -> Result<Value, ApiError> {
        if body.is_empty() || body.len() > CHUNK_SIZE_BYTES {
            return Err(ApiError::too_large(
                "chunk must contain between 1 byte and 1 MiB",
            ));
        }
        let owner = sqlx::query("SELECT vault_id,user_id FROM uploads WHERE upload_id=$1")
            .bind(upload_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
        let vault_id: String = owner.try_get("vault_id").map_err(ApiError::internal)?;
        let owner_user_id: String = owner.try_get("user_id").map_err(ApiError::internal)?;
        if owner_user_id != user.user_id {
            return Err(ApiError::not_found());
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_vault_tx(&mut tx, user, &vault_id, true).await?;
        let row = sqlx::query(
            "SELECT expected_size,chunk_size,state,expires_at>clock_timestamp() AS unexpired FROM uploads \
             WHERE upload_id=$1 AND vault_id=$2 AND user_id=$3 FOR UPDATE",
        )
        .bind(upload_id)
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let expected: i64 = row.try_get("expected_size").map_err(ApiError::internal)?;
        let chunk_size: i64 = row.try_get("chunk_size").map_err(ApiError::internal)?;
        let state: String = row.try_get("state").map_err(ApiError::internal)?;
        let unexpired: bool = row.try_get("unexpired").map_err(ApiError::internal)?;
        if state != "open" || !unexpired {
            return Err(ApiError::gone(
                "UPLOAD_EXPIRED",
                "upload is closed or expired",
            ));
        }
        let count = expected.saturating_add(chunk_size - 1) / chunk_size;
        if index < 0 || index >= count {
            return Err(ApiError::bad_request(
                "INVALID_CHUNK_INDEX",
                "chunk index is out of range",
            ));
        }
        let expected_len = if index == count - 1 {
            expected - index * chunk_size
        } else {
            chunk_size
        };
        if body.len() as i64 != expected_len {
            return Err(ApiError::bad_request(
                "INVALID_CHUNK_SIZE",
                "chunk length does not match its position",
            ));
        }
        let digest = sha256_hex(&body);
        if let Some(existing) =
            sqlx::query("SELECT sha256 FROM upload_chunks WHERE upload_id=$1 AND chunk_index=$2")
                .bind(upload_id)
                .bind(index)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
        {
            let old: String = existing.try_get("sha256").map_err(ApiError::internal)?;
            if old != digest {
                return Err(ApiError::conflict(
                    "CHUNK_IMMUTABLE",
                    "chunk index already contains different bytes",
                ));
            }
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "upload_id": upload_id,
                "index": index,
                "sha256": digest,
                "already_uploaded": true,
            }));
        }
        sqlx::query(
            "INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES($1,$2,$3,$4)",
        )
        .bind(upload_id)
        .bind(index)
        .bind(&body[..])
        .bind(&digest)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "upload_id": upload_id,
            "index": index,
            "sha256": digest,
            "already_uploaded": false,
        }))
    }

    pub(crate) async fn complete_upload(
        &self,
        state: &AppState,
        user: &AuthUser,
        upload_id: &str,
    ) -> Result<Value, ApiError> {
        let _permit = state
            .object_completion_slots
            .clone()
            .try_acquire_owned()
            .map_err(|_| {
                ApiError::new(
                    StatusCode::TOO_MANY_REQUESTS,
                    "RATE_LIMITED",
                    "another object completion is in progress",
                )
            })?;
        let owner = sqlx::query("SELECT vault_id,user_id FROM uploads WHERE upload_id=$1")
            .bind(upload_id)
            .fetch_optional(&self.pool)
            .await
            .map_err(ApiError::internal)?
            .ok_or_else(ApiError::not_found)?;
        let vault_id: String = owner.try_get("vault_id").map_err(ApiError::internal)?;
        let owner_user_id: String = owner.try_get("user_id").map_err(ApiError::internal)?;
        if owner_user_id != user.user_id {
            return Err(ApiError::not_found());
        }

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_vault_tx(&mut tx, user, &vault_id, true).await?;
        let upload = sqlx::query(
            "SELECT object_id,expected_size,expected_sha256,chunk_size,state, \
                    expires_at>clock_timestamp() AS unexpired, \
                    storage_backend,storage_store_id,storage_key \
             FROM uploads WHERE upload_id=$1 AND vault_id=$2 AND user_id=$3 FOR UPDATE",
        )
        .bind(upload_id)
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let object_id: String = upload.try_get("object_id").map_err(ApiError::internal)?;
        let expected_size: i64 = upload
            .try_get("expected_size")
            .map_err(ApiError::internal)?;
        let expected_sha256: String = upload
            .try_get("expected_sha256")
            .map_err(ApiError::internal)?;
        let chunk_size: i64 = upload.try_get("chunk_size").map_err(ApiError::internal)?;
        let upload_state: String = upload.try_get("state").map_err(ApiError::internal)?;
        let unexpired: bool = upload.try_get("unexpired").map_err(ApiError::internal)?;
        let storage_backend: String = upload
            .try_get("storage_backend")
            .map_err(ApiError::internal)?;
        let storage_store_id: String = upload
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        let storage_key: String = upload.try_get("storage_key").map_err(ApiError::internal)?;

        if upload_state == "collected" {
            return Err(ApiError::gone(
                "OBJECT_COLLECTED",
                "the completed object has been collected",
            ));
        }
        if upload_state == "completed" {
            let blob = sqlx::query(
                "SELECT size,sha256 FROM blob_objects WHERE vault_id=$1 AND object_id=$2",
            )
            .bind(&vault_id)
            .bind(&object_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let Some(blob) = blob else {
                return Err(ApiError::gone(
                    "OBJECT_COLLECTED",
                    "the completed object has been collected",
                ));
            };
            let size: i64 = blob.try_get("size").map_err(ApiError::internal)?;
            let digest: String = blob.try_get("sha256").map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "object_id": object_id,
                "size": size,
                "sha256": digest,
                "already_completed": true,
            }));
        }
        if !matches!(upload_state.as_str(), "open" | "completing") || !unexpired {
            return Err(ApiError::gone(
                "UPLOAD_EXPIRED",
                "upload is closed or expired",
            ));
        }
        let chunks = sqlx::query(
            "SELECT chunk_index,bytes,sha256 FROM upload_chunks WHERE upload_id=$1 ORDER BY chunk_index",
        )
        .bind(upload_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let chunk_count = expected_size.saturating_add(chunk_size - 1) / chunk_size;
        if chunks.len() as i64 != chunk_count {
            return Err(ApiError::conflict(
                "UPLOAD_INCOMPLETE",
                "upload has missing chunks",
            ));
        }
        let capacity = usize::try_from(expected_size).map_err(ApiError::internal)?;
        let mut assembled = Vec::with_capacity(capacity);
        let mut receipts = Vec::with_capacity(chunks.len());
        for (position, chunk) in chunks.iter().enumerate() {
            let index: i64 = chunk.try_get("chunk_index").map_err(ApiError::internal)?;
            if index != position as i64 {
                return Err(ApiError::conflict(
                    "UPLOAD_INCOMPLETE",
                    "upload has missing chunks",
                ));
            }
            let bytes: Vec<u8> = chunk.try_get("bytes").map_err(ApiError::internal)?;
            let digest: String = chunk.try_get("sha256").map_err(ApiError::internal)?;
            if sha256_hex(&bytes) != digest {
                return Err(ApiError::conflict(
                    "OBJECT_HASH_MISMATCH",
                    "stored chunk failed integrity check",
                ));
            }
            assembled.extend_from_slice(&bytes);
            receipts.push(json!({"index":index,"sha256":digest,"size":bytes.len()}));
        }
        if assembled.len() as i64 != expected_size || sha256_hex(&assembled) != expected_sha256 {
            return Err(ApiError::conflict(
                "OBJECT_HASH_MISMATCH",
                "assembled object does not match declared size or digest",
            ));
        }
        if storage_backend != state.object_store.backend_name()
            || state.object_store.store_id() != Some(storage_store_id.as_str())
        {
            return Err(crate::object_store::storage_api_error(
                ObjectStoreError::Unavailable,
            ));
        }
        if upload_state == "open" {
            sqlx::query(
                "UPDATE uploads SET state='completing' WHERE upload_id=$1 AND state='open'",
            )
            .bind(upload_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        // The durable `completing` row is the cross-node retry marker. Never
        // keep a PostgreSQL transaction open during upload/verification I/O.
        tx.commit().await.map_err(ApiError::internal)?;

        state
            .object_store
            .put_immutable(&storage_key, &assembled, expected_size, &expected_sha256)
            .await
            .map_err(crate::object_store::storage_api_error)?;

        let mut publish_tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let authorization = authorize_vault_tx(&mut publish_tx, user, &vault_id, true).await;
        if let Err(error) = authorization {
            enqueue_external_delete_tx(
                &mut publish_tx,
                &storage_backend,
                &storage_store_id,
                &storage_key,
                expected_size,
                &expected_sha256,
                DELETE_GRACE_SECONDS,
            )
            .await?;
            retire_upload_tx(&mut publish_tx, upload_id).await?;
            publish_tx.commit().await.map_err(ApiError::internal)?;
            return Err(error);
        }
        let current = sqlx::query(
            "SELECT state,expected_size,expected_sha256, \
                    expires_at>clock_timestamp() AS unexpired FROM uploads \
             WHERE upload_id=$1 AND vault_id=$2 AND user_id=$3 FOR UPDATE",
        )
        .bind(upload_id)
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *publish_tx)
        .await
        .map_err(ApiError::internal)?;
        let publishable = current.as_ref().is_some_and(|row| {
            let state = row.try_get::<String, _>("state").ok();
            let size = row.try_get::<i64, _>("expected_size").ok();
            let digest = row.try_get::<String, _>("expected_sha256").ok();
            let unexpired = row.try_get::<bool, _>("unexpired").ok();
            state.as_deref() == Some("completing")
                && size == Some(expected_size)
                && digest.as_deref() == Some(expected_sha256.as_str())
                && unexpired == Some(true)
        });
        if !publishable {
            if current.as_ref().is_some_and(|row| {
                row.try_get::<String, _>("state")
                    .is_ok_and(|value| value == "completed")
            }) {
                let blob = sqlx::query(
                    "SELECT size,sha256 FROM blob_objects WHERE vault_id=$1 AND object_id=$2",
                )
                .bind(&vault_id)
                .bind(&object_id)
                .fetch_optional(&mut *publish_tx)
                .await
                .map_err(ApiError::internal)?;
                if let Some(blob) = blob {
                    let size: i64 = blob.try_get("size").map_err(ApiError::internal)?;
                    let digest: String = blob.try_get("sha256").map_err(ApiError::internal)?;
                    publish_tx.commit().await.map_err(ApiError::internal)?;
                    return Ok(json!({
                        "object_id": object_id,
                        "size": size,
                        "sha256": digest,
                        "already_completed": true,
                    }));
                }
            }
            enqueue_external_delete_tx(
                &mut publish_tx,
                &storage_backend,
                &storage_store_id,
                &storage_key,
                expected_size,
                &expected_sha256,
                DELETE_GRACE_SECONDS,
            )
            .await?;
            if current.is_some() {
                retire_upload_tx(&mut publish_tx, upload_id).await?;
            }
            publish_tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::gone(
                "UPLOAD_EXPIRED",
                "upload is closed or expired",
            ));
        }

        let inserted = sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,size,sha256,storage_backend,storage_key, \
             storage_store_id,storage_state,gc_after,created_at) \
             VALUES($1,$2,$3,$4,$5,$6,$7,'available', \
                    floor(extract(epoch FROM clock_timestamp()))::BIGINT + $8,CURRENT_TIMESTAMP) \
             ON CONFLICT(vault_id,object_id) DO NOTHING",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .bind(expected_size)
        .bind(&expected_sha256)
        .bind(&storage_backend)
        .bind(&storage_key)
        .bind(&storage_store_id)
        .bind(state.config.object_gc_grace_seconds.max(0))
        .execute(&mut *publish_tx)
        .await;
        match inserted {
            Ok(result) if result.rows_affected() == 1 => {}
            Ok(_) => {
                let existing = sqlx::query(
                    "SELECT size,sha256,storage_backend,storage_key,storage_store_id,storage_state \
                     FROM blob_objects WHERE vault_id=$1 AND object_id=$2 FOR UPDATE",
                )
                .bind(&vault_id)
                .bind(&object_id)
                .fetch_optional(&mut *publish_tx)
                .await
                .map_err(ApiError::internal)?;
                let same = existing.as_ref().is_some_and(|row| {
                    row.try_get::<i64, _>("size").ok() == Some(expected_size)
                        && row
                            .try_get::<String, _>("sha256")
                            .is_ok_and(|v| v == expected_sha256)
                        && row
                            .try_get::<String, _>("storage_backend")
                            .is_ok_and(|v| v == storage_backend)
                        && row
                            .try_get::<String, _>("storage_key")
                            .is_ok_and(|v| v == storage_key)
                        && row
                            .try_get::<Option<String>, _>("storage_store_id")
                            .ok()
                            .flatten()
                            .as_deref()
                            == Some(storage_store_id.as_str())
                        && row
                            .try_get::<String, _>("storage_state")
                            .is_ok_and(|v| v == "available")
                });
                if !same {
                    enqueue_external_delete_tx(
                        &mut publish_tx,
                        &storage_backend,
                        &storage_store_id,
                        &storage_key,
                        expected_size,
                        &expected_sha256,
                        DELETE_GRACE_SECONDS,
                    )
                    .await?;
                    retire_upload_tx(&mut publish_tx, upload_id).await?;
                    publish_tx.commit().await.map_err(ApiError::internal)?;
                    return Err(ApiError::conflict(
                        "OBJECT_EXISTS",
                        "object id already exists",
                    ));
                }
            }
            Err(error)
                if error
                    .as_database_error()
                    .is_some_and(|database_error| database_error.is_unique_violation()) =>
            {
                // A different catalogue row already names this provider key.
                // Do not enqueue a delete intent for a key that is still live.
                retire_upload_tx(&mut publish_tx, upload_id).await?;
                publish_tx.commit().await.map_err(ApiError::internal)?;
                return Err(ApiError::conflict(
                    "OBJECT_EXISTS",
                    "object id already exists",
                ));
            }
            Err(error) => return Err(ApiError::internal(error)),
        }
        sqlx::query(
            "UPDATE uploads SET state='completed' WHERE upload_id=$1 AND state='completing'",
        )
        .bind(upload_id)
        .execute(&mut *publish_tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM upload_chunks WHERE upload_id=$1")
            .bind(upload_id)
            .execute(&mut *publish_tx)
            .await
            .map_err(ApiError::internal)?;
        publish_tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "object_id": object_id,
            "size": expected_size,
            "sha256": expected_sha256,
            "chunks": receipts,
        }))
    }

    pub(crate) async fn get_object(
        &self,
        state: &AppState,
        user: &AuthUser,
        vault_id: &str,
        object_id: &str,
        headers: &HeaderMap,
    ) -> Result<Response, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_vault_tx(&mut tx, user, vault_id, false).await?;
        let readable: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM object_references r \
                           WHERE r.vault_id=$1 AND r.object_id=$2) \
             OR EXISTS(SELECT 1 FROM uploads u JOIN blob_objects b \
                       ON b.vault_id=u.vault_id AND b.object_id=u.object_id \
                       WHERE u.vault_id=$1 AND u.object_id=$2 AND u.user_id=$3 \
                         AND u.state='completed' AND u.expires_at>clock_timestamp() \
                         AND b.storage_state='available')",
        )
        .bind(vault_id)
        .bind(object_id)
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !readable {
            return Err(ApiError::not_found());
        }
        let row = sqlx::query(
            "SELECT size,sha256,storage_backend,storage_key,storage_store_id,storage_state \
             FROM blob_objects WHERE vault_id=$1 AND object_id=$2",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let storage_state: String = row.try_get("storage_state").map_err(ApiError::internal)?;
        if storage_state != "available" {
            return Err(ApiError::not_found());
        }
        let size: i64 = row.try_get("size").map_err(ApiError::internal)?;
        let size_u64 = u64::try_from(size).map_err(ApiError::internal)?;
        let digest: String = row.try_get("sha256").map_err(ApiError::internal)?;
        let backend: String = row.try_get("storage_backend").map_err(ApiError::internal)?;
        let key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
        let store_id: Option<String> = row
            .try_get("storage_store_id")
            .map_err(ApiError::internal)?;
        if backend != state.object_store.backend_name()
            || key.as_deref().is_none_or(str::is_empty)
            || store_id.as_deref() != state.object_store.store_id()
        {
            return Err(crate::object_store::storage_api_error(
                ObjectStoreError::Unavailable,
            ));
        }
        let etag = format!("\"sha256-{digest}\"");
        let selected_range = crate::objects::byte_range_from_headers(headers, &etag, size_u64);
        let key = key
            .ok_or_else(|| crate::object_store::storage_api_error(ObjectStoreError::Unavailable))?;
        tx.commit().await.map_err(ApiError::internal)?;

        let bytes = match selected_range {
            Ok(range) => Some(
                state
                    .object_store
                    .read_object(&key, size, &digest, range)
                    .await
                    .map_err(crate::object_store::storage_api_error)?,
            ),
            Err(()) => None,
        };
        let (mut response, content_length) = match selected_range {
            Ok(Some((start, end))) => {
                let body =
                    bytes.ok_or_else(|| ApiError::internal("ranged object bytes are missing"))?;
                let mut response = (StatusCode::PARTIAL_CONTENT, body).into_response();
                response.headers_mut().insert(
                    header::CONTENT_RANGE,
                    HeaderValue::from_str(&format!("bytes {start}-{end}/{size_u64}"))
                        .map_err(ApiError::internal)?,
                );
                (response, end - start + 1)
            }
            Ok(None) => (
                (
                    StatusCode::OK,
                    bytes.ok_or_else(|| ApiError::internal("object bytes are missing"))?,
                )
                    .into_response(),
                size_u64,
            ),
            Err(()) => {
                let mut response = StatusCode::RANGE_NOT_SATISFIABLE.into_response();
                response.headers_mut().insert(
                    header::CONTENT_RANGE,
                    HeaderValue::from_str(&format!("bytes */{size_u64}"))
                        .map_err(ApiError::internal)?,
                );
                (response, 0)
            }
        };
        response.headers_mut().insert(
            header::CONTENT_TYPE,
            HeaderValue::from_static("application/octet-stream"),
        );
        response
            .headers_mut()
            .insert(header::ACCEPT_RANGES, HeaderValue::from_static("bytes"));
        response.headers_mut().insert(
            header::ETAG,
            HeaderValue::from_str(&etag).map_err(ApiError::internal)?,
        );
        response.headers_mut().insert(
            header::CONTENT_LENGTH,
            HeaderValue::from_str(&content_length.to_string()).map_err(ApiError::internal)?,
        );
        Ok(response)
    }

    /// Retires expired upload tickets with bounded SKIP LOCKED claims. A
    /// `completing` row has already committed its external PUT intent, so its
    /// exact immutable key is added to the durable delete queue with grace.
    pub(crate) async fn prune_expired_uploads(
        &self,
        _now_epoch: i64,
        limit: i64,
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        let rows = sqlx::query(
            "SELECT upload_id,storage_backend,storage_store_id,storage_key,expected_size,expected_sha256,state \
             FROM uploads WHERE state IN ('open','completing') AND expires_at<=clock_timestamp() \
             ORDER BY expires_at,upload_id LIMIT $1 FOR UPDATE SKIP LOCKED",
        )
        .bind(limit.clamp(1, UPLOAD_PRUNE_BATCH_MAX))
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            let upload_state: String = row.try_get("state").map_err(ApiError::internal)?;
            if upload_state == "completing" {
                enqueue_upload_delete_tx(&mut tx, &row, DELETE_GRACE_SECONDS).await?;
            }
            let upload_id: String = row.try_get("upload_id").map_err(ApiError::internal)?;
            sqlx::query("UPDATE uploads SET state='expired' WHERE upload_id=$1")
                .bind(&upload_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("DELETE FROM upload_chunks WHERE upload_id=$1")
                .bind(upload_id)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        tx.commit().await.map_err(ApiError::internal)
    }

    /// Collects a bounded set of due, unreferenced objects. Object row locks
    /// serialize with sync reference attachment: either the reference wins
    /// and GC skips it, or GC removes the catalogue row and later references
    /// fail as unavailable. The durable queue and catalogue removal commit
    /// together; provider deletion runs in the existing leased worker.
    pub(crate) async fn collect_due_objects(
        &self,
        _now_epoch: i64,
        limit: i64,
    ) -> Result<(), ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        // Read the database clock once so selection and catalogue retirement
        // use the same cross-node cutoff. A stale value can only defer GC.
        let db_now_epoch: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        let rows = sqlx::query(
            "SELECT b.vault_id,b.object_id,b.storage_backend,b.storage_key,b.storage_store_id,b.size,b.sha256 \
             FROM blob_objects b WHERE b.storage_state='available' AND b.gc_after IS NOT NULL \
               AND b.gc_after<=$1 AND b.storage_backend IN ('s3','filesystem') \
               AND NOT EXISTS(SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id) \
               AND NOT EXISTS(SELECT 1 FROM backup_object_pins p \
                              WHERE p.storage_store_id=b.storage_store_id \
                                AND p.storage_key=b.storage_key \
                                AND p.expires_at>clock_timestamp()) \
             ORDER BY b.gc_after,b.vault_id,b.object_id LIMIT $2 FOR UPDATE OF b SKIP LOCKED",
        )
        .bind(db_now_epoch)
        .bind(limit.clamp(1, GC_BATCH_MAX))
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        for row in rows {
            // The candidate SELECT can start before a backup commits its pin
            // and then acquire the row after that commit. Recheck with a
            // fresh READ COMMITTED statement snapshot before queuing provider
            // deletion, rather than trusting the candidate statement's older
            // snapshot. A currently held backup FOR SHARE lock is skipped by
            // the candidate query's SKIP LOCKED clause.
            let actively_pinned: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM backup_object_pins \
                 WHERE storage_store_id=$1 AND storage_key=$2 \
                   AND expires_at>clock_timestamp())",
            )
            .bind(
                row.try_get::<Option<String>, _>("storage_store_id")
                    .map_err(ApiError::internal)?,
            )
            .bind(
                row.try_get::<Option<String>, _>("storage_key")
                    .map_err(ApiError::internal)?,
            )
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if actively_pinned {
                continue;
            }
            let backend: String = row.try_get("storage_backend").map_err(ApiError::internal)?;
            let key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
            let store_id: Option<String> = row
                .try_get("storage_store_id")
                .map_err(ApiError::internal)?;
            let size: i64 = row.try_get("size").map_err(ApiError::internal)?;
            let digest: String = row.try_get("sha256").map_err(ApiError::internal)?;
            let key = key
                .filter(|value| !value.is_empty())
                .ok_or_else(|| ApiError::internal("external object storage key is missing"))?;
            let store_id = store_id
                .filter(|value| !value.is_empty())
                .ok_or_else(|| ApiError::internal("external object storage identity is missing"))?;
            if size <= 0
                || digest.len() != 64
                || !digest.bytes().all(|byte| byte.is_ascii_hexdigit())
            {
                return Err(ApiError::internal("external object metadata is invalid"));
            }
            enqueue_external_delete_tx(&mut tx, &backend, &store_id, &key, size, &digest, 0)
                .await?;
            let vault_id: String = row.try_get("vault_id").map_err(ApiError::internal)?;
            let object_id: String = row.try_get("object_id").map_err(ApiError::internal)?;
            sqlx::query(
                "UPDATE uploads SET state='collected' WHERE vault_id=$1 AND object_id=$2 AND state='completed'",
            )
            .bind(&vault_id)
            .bind(&object_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let deleted = sqlx::query(
                "DELETE FROM blob_objects b WHERE b.vault_id=$1 AND b.object_id=$2 \
                 AND b.storage_state='available' AND b.gc_after IS NOT NULL AND b.gc_after<=$3 \
                 AND NOT EXISTS(SELECT 1 FROM object_references r WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id) \
                 AND NOT EXISTS(SELECT 1 FROM backup_object_pins p \
                                WHERE p.storage_store_id=b.storage_store_id \
                                  AND p.storage_key=b.storage_key \
                                  AND p.expires_at>clock_timestamp())",
            )
            .bind(&vault_id)
            .bind(&object_id)
            .bind(db_now_epoch)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            if deleted.rows_affected() != 1 {
                return Err(ApiError::conflict(
                    "OBJECT_GC_CONFLICT",
                    "object reachability changed during garbage collection",
                ));
            }
        }
        tx.commit().await.map_err(ApiError::internal)
    }
}

async fn authorize_vault_tx(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
    write: bool,
) -> Result<(), ApiError> {
    let session = sqlx::query(
        "SELECT revoked_at,access_expires_at>clock_timestamp() AS unexpired FROM sessions \
         WHERE session_id=$1 AND user_id=$2 AND device_id=$3 AND access_hash=$4 FOR SHARE",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::unauthorized)?;
    if session
        .try_get::<Option<DateTime<Utc>>, _>("revoked_at")
        .map_err(ApiError::internal)?
        .is_some()
        || !session
            .try_get::<bool, _>("unexpired")
            .map_err(ApiError::internal)?
    {
        return Err(ApiError::unauthorized());
    }
    let account_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1 FOR SHARE")
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if account_status.as_deref() != Some("active") {
        return Err(ApiError::unauthorized());
    }
    let device_status: Option<String> = sqlx::query_scalar(
        "SELECT status FROM devices WHERE device_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    let lock_clause = if write { "FOR UPDATE" } else { "FOR SHARE" };
    let query = format!("SELECT state FROM vaults WHERE vault_id=$1 {lock_clause}");
    let vault_state: Option<String> = sqlx::query_scalar(&query)
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(vault_state) = vault_state else {
        return Err(ApiError::not_found());
    };
    if write && vault_state == "deleting" {
        return Err(ApiError::vault_deletion_pending());
    }
    if !matches!(vault_state.as_str(), "active" | "deleting") {
        return Err(ApiError::not_found());
    }
    let member = sqlx::query(
        "SELECT role,state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    if member
        .try_get::<String, _>("state")
        .map_err(ApiError::internal)?
        != "active"
    {
        return Err(ApiError::not_found());
    }
    if write {
        let role: String = member.try_get("role").map_err(ApiError::internal)?;
        if role != "owner" && role != "editor" {
            return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
        }
    }
    require_redaction_client_for_vault_tx(tx, vault_id, user).await?;
    Ok(())
}

async fn retire_upload_tx(
    tx: &mut Transaction<'_, Postgres>,
    upload_id: &str,
) -> Result<(), ApiError> {
    sqlx::query("UPDATE uploads SET state='expired' WHERE upload_id=$1 AND state='completing'")
        .bind(upload_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM upload_chunks WHERE upload_id=$1")
        .bind(upload_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn enqueue_upload_delete_tx(
    tx: &mut Transaction<'_, Postgres>,
    upload: &sqlx::postgres::PgRow,
    delay_seconds: i64,
) -> Result<(), ApiError> {
    let backend: String = upload
        .try_get("storage_backend")
        .map_err(ApiError::internal)?;
    let store_id: String = upload
        .try_get("storage_store_id")
        .map_err(ApiError::internal)?;
    let key: String = upload.try_get("storage_key").map_err(ApiError::internal)?;
    let size: i64 = upload
        .try_get("expected_size")
        .map_err(ApiError::internal)?;
    let digest: String = upload
        .try_get("expected_sha256")
        .map_err(ApiError::internal)?;
    enqueue_external_delete_tx(tx, &backend, &store_id, &key, size, &digest, delay_seconds).await
}

async fn enqueue_external_delete_tx(
    tx: &mut Transaction<'_, Postgres>,
    backend: &str,
    store_id: &str,
    key: &str,
    expected_size: i64,
    expected_sha256: &str,
    delay_seconds: i64,
) -> Result<(), ApiError> {
    if !matches!(backend, "s3" | "filesystem")
        || store_id.is_empty()
        || key.is_empty()
        || expected_size <= 0
        || expected_sha256.len() != 64
        || !expected_sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
    {
        return Err(ApiError::internal(
            "external object deletion metadata is invalid",
        ));
    }
    let digest = expected_sha256.to_ascii_lowercase();
    sqlx::query(
        "INSERT INTO object_delete_queue(queue_id,storage_backend,storage_key,storage_store_id, \
         expected_size,expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at) \
         VALUES($1,$2,$3,$4,$5,$6,'pending',0, \
                floor(extract(epoch FROM clock_timestamp()))::BIGINT + $7,NULL,CURRENT_TIMESTAMP) \
         ON CONFLICT(storage_store_id,storage_key) DO NOTHING",
    )
    .bind(Uuid::new_v4().to_string())
    .bind(backend)
    .bind(key)
    .bind(store_id)
    .bind(expected_size)
    .bind(&digest)
    .bind(delay_seconds.max(0))
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let existing = sqlx::query(
        "SELECT storage_backend,expected_size,expected_sha256 FROM object_delete_queue \
         WHERE storage_store_id=$1 AND storage_key=$2",
    )
    .bind(store_id)
    .bind(key)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("external object deletion intent was not persisted"))?;
    if existing
        .try_get::<String, _>("storage_backend")
        .map_err(ApiError::internal)?
        != backend
        || existing
            .try_get::<i64, _>("expected_size")
            .map_err(ApiError::internal)?
            != expected_size
        || existing
            .try_get::<String, _>("expected_sha256")
            .map_err(ApiError::internal)?
            != digest
    {
        return Err(ApiError::internal(
            "external object key has conflicting integrity metadata",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        time::Duration,
    };

    use futures_util::FutureExt;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const RETENTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const DELETE_MIGRATION: &str = include_str!("../migrations/postgres/0012_vault_deletion.sql");
    const OBJECT_MIGRATION: &str = include_str!("../migrations/postgres/0015_object_storage.sql");
    const PIN_MIGRATION: &str = include_str!("../migrations/postgres/0024_backup_object_pins.sql");
    const SNAPSHOT_MIGRATION: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    struct SchemaCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl Drop for SchemaCleanupGuard {
        fn drop(&mut self) {
            if !self.armed {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL object pin tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL object pin tests outside an explicitly disposable database"
            );
            assert!(!matches!(
                database.as_str(),
                "postgres" | "template0" | "template1"
            ));
            let admin_pool = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(options.clone())
                .await
                .expect("connect PostgreSQL disposable test database");
            let schema = format!("atermius_pg_object_pins_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL object pin schema");
            let mut cleanup = SchemaCleanupGuard {
                admin_pool: admin_pool.clone(),
                schema: schema.clone(),
                armed: true,
            };
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect isolated PostgreSQL object pin schema");
                for migration in [
                    CORE_MIGRATION,
                    RETENTION_MIGRATION,
                    CONFLICT_MIGRATION,
                    DELETE_MIGRATION,
                    OBJECT_MIGRATION,
                    PIN_MIGRATION,
                    SNAPSHOT_MIGRATION,
                ] {
                    sqlx::raw_sql(migration)
                        .execute(&pool)
                        .await
                        .expect("apply PostgreSQL object pin test migration");
                }
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema (\
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
                )
                .execute(&pool)
                .await
                .expect("create PostgreSQL schema-version fixture");
                sqlx::raw_sql(REDACTION_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL record-redaction schema");
                sqlx::raw_sql(REDACTED_CONFLICT_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL redacted-conflict compatibility schema");
                pool
            })
            .catch_unwind()
            .await;
            match setup {
                Ok(pool) => {
                    cleanup.armed = false;
                    Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    }
                }
                Err(payload) => resume_unwind(payload),
            }
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL object pin schema");
            self.cleaned = true;
            self.admin_pool.close().await;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                });
            }
        }
    }

    async fn seed_due_object(pool: &PgPool, backend: &str, store_id: &str, key: &str) -> String {
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username) VALUES($1,$2)")
            .bind(&user_id)
            .bind(format!("{}@example.test", Uuid::new_v4()))
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id) VALUES($1,$2)")
            .bind(&vault_id)
            .bind(user_id)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,size,sha256,storage_backend,storage_key,storage_store_id,storage_state,gc_after) \
             VALUES($1,$2,5,repeat('a',64),$3,$4,$5,'available',0)",
        )
        .bind(&vault_id)
        .bind(Uuid::new_v4().to_string())
        .bind(backend)
        .bind(key)
        .bind(store_id)
        .execute(pool)
        .await
        .unwrap();
        vault_id
    }

    fn test_object_key() -> String {
        format!(
            "atermius/objects/v1/{}/{}/{}/{}",
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4(),
            Uuid::new_v4()
        )
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL object pin concurrency acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn backup_pin_defers_gc_before_and_after_commit_and_expiry() {
        let database = TestDatabase::create().await;
        let store_id = format!("test-store-{}", Uuid::new_v4());
        let key = test_object_key();
        let vault_id = seed_due_object(&database.pool, "filesystem", &store_id, &key).await;
        let backup_id = Uuid::new_v4().to_string();
        let repository = PgObjectRepository::new(database.pool.clone(), "test-instance".into());

        let mut pin_tx = database.pool.begin().await.unwrap();
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            .execute(&mut *pin_tx)
            .await
            .unwrap();
        let objects = pin_objects_for_backup_tx(&mut pin_tx, &backup_id, 300)
            .await
            .unwrap();
        assert_eq!(objects.len(), 1);
        assert_eq!(objects[0].vault_id, vault_id);
        assert_eq!(objects[0].storage_key, key);
        renew_backup_pins_tx(&mut pin_tx, &backup_id, 300)
            .await
            .unwrap();

        // While the pin transaction holds FOR SHARE, SKIP LOCKED must defer
        // the row even though its pin record is not committed and visible yet.
        tokio::time::timeout(
            Duration::from_secs(5),
            repository.collect_due_objects(0, 20),
        )
        .await
        .expect("GC should skip a row locked by backup snapshot")
        .unwrap();
        pin_tx.commit().await.unwrap();
        // Once committed, the pin row itself remains the cross-node fence.
        repository.collect_due_objects(0, 20).await.unwrap();
        repository.renew_backup_pins(&backup_id, 300).await.unwrap();
        let catalogue_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM blob_objects WHERE vault_id=$1")
                .bind(&vault_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(catalogue_count, 1);

        sqlx::query(
            "UPDATE backup_object_pins SET expires_at=clock_timestamp()-INTERVAL '1 second' \
             WHERE backup_id=$1",
        )
        .bind(&backup_id)
        .execute(&database.pool)
        .await
        .unwrap();
        assert!(repository.renew_backup_pins(&backup_id, 300).await.is_err());
        repository.collect_due_objects(0, 20).await.unwrap();
        let catalogue_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM blob_objects WHERE vault_id=$1")
                .bind(&vault_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(catalogue_count, 0, "expired pins must not block object GC");
        assert_eq!(repository.cleanup_expired_backup_pins(1).await.unwrap(), 1);
        repository.release_backup_pins(&backup_id).await.unwrap();
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL object delete queue acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn external_delete_drainer_defers_live_pin_then_deletes_after_expiry() {
        let database = TestDatabase::create().await;
        let root = std::env::temp_dir().join(format!("atermius-pg-object-pin-{}", Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        let store = crate::object_store::ObjectStore::filesystem_for_test(&root);
        let store_id = store.store_id().unwrap().to_owned();
        let key = test_object_key();
        let object_bytes = b"bytes";
        let object_sha256 = crate::sha256_hex(object_bytes);
        store
            .put_immutable(
                &key,
                object_bytes,
                object_bytes.len() as i64,
                &object_sha256,
            )
            .await
            .unwrap();
        let queue_id = Uuid::new_v4().to_string();
        let backup_id = Uuid::new_v4().to_string();
        sqlx::query(
            "INSERT INTO object_delete_queue(queue_id,storage_backend,storage_key,storage_store_id,expected_size,expected_sha256,state,attempt_count,next_attempt_at) \
             VALUES($1,'filesystem',$2,$3,$4,$5,'pending',0,0)",
        )
        .bind(&queue_id)
        .bind(&key)
        .bind(&store_id)
        .bind(object_bytes.len() as i64)
        .bind(&object_sha256)
        .execute(&database.pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO backup_object_pins(backup_id,storage_store_id,storage_key,expires_at) \
             VALUES($1,$2,$3,clock_timestamp()+INTERVAL '5 minutes')",
        )
        .bind(&backup_id)
        .bind(&store_id)
        .bind(&key)
        .execute(&database.pool)
        .await
        .unwrap();

        let deletion =
            crate::pg_vault_deletion::PgVaultDeletionRepository::new(database.pool.clone());
        deletion
            .drain_object_delete_queue(&store, 0, 10)
            .await
            .unwrap();
        let queue_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE queue_id=$1 AND lease_id IS NULL",
        )
        .bind(&queue_id)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(
            queue_count, 1,
            "active object pin must defer physical deletion"
        );

        sqlx::query(
            "UPDATE backup_object_pins SET expires_at=clock_timestamp()-INTERVAL '1 second' \
             WHERE backup_id=$1",
        )
        .bind(&backup_id)
        .execute(&database.pool)
        .await
        .unwrap();
        deletion
            .drain_object_delete_queue(&store, 0, 10)
            .await
            .unwrap();
        let queue_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM object_delete_queue WHERE queue_id=$1")
                .bind(&queue_id)
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(
            queue_count, 0,
            "expired pins must not block physical deletion"
        );
        assert!(
            store
                .read_object(&key, object_bytes.len() as i64, &object_sha256, None)
                .await
                .is_err()
        );
        let repository = PgObjectRepository::new(database.pool.clone(), "test-instance".into());
        repository.release_backup_pins(&backup_id).await.unwrap();
        for _ in 0..3 {
            let expired_backup_id = Uuid::new_v4().to_string();
            let expired_key = test_object_key();
            sqlx::query(
                "INSERT INTO backup_object_pin_sets(backup_id,object_count,expires_at) \
                 VALUES($1,1,clock_timestamp()-INTERVAL '1 second')",
            )
            .bind(&expired_backup_id)
            .execute(&database.pool)
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO backup_object_pins(backup_id,storage_store_id,storage_key,expires_at) \
                 VALUES($1,$2,$3,clock_timestamp()-INTERVAL '1 second')",
            )
            .bind(expired_backup_id)
            .bind(&store_id)
            .bind(expired_key)
            .execute(&database.pool)
            .await
            .unwrap();
        }
        assert_eq!(repository.cleanup_expired_backup_pins(1).await.unwrap(), 2);
        let remaining_expired_pins: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM backup_object_pins")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        let remaining_expired_sets: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM backup_object_pin_sets")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(
            remaining_expired_pins, 2,
            "pin cleanup must honor its batch limit"
        );
        assert_eq!(
            remaining_expired_sets, 2,
            "pin-set cleanup must honor its batch limit"
        );
        drop(store);
        std::fs::remove_dir_all(&root).unwrap();
        database.cleanup().await;
    }
}

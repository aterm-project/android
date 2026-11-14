use crate::{ApiError, AppState, current_user, now_rfc3339, sha256_hex};
use axum::{
    Json,
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
};
use chrono::{Duration, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction};
use uuid::Uuid;
pub(crate) const CHUNK_SIZE_BYTES: usize = 1024 * 1024;
const CHUNK_SIZE: i64 = CHUNK_SIZE_BYTES as i64;

/// Parses exactly one supported byte range. Unknown units are ignored by the
/// caller; malformed byte ranges and unsatisfiable positions return 416.
fn parse_range_number(value: &str) -> Option<u64> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    value.parse().ok()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RangeParseError {
    UnsupportedUnit,
    Invalid,
}

fn parse_single_byte_range(value: &str, size: u64) -> Result<(u64, u64), RangeParseError> {
    let value = value.trim();
    let (unit, spec) = value.split_once('=').ok_or(RangeParseError::Invalid)?;
    if !unit.eq_ignore_ascii_case("bytes") {
        return Err(RangeParseError::UnsupportedUnit);
    }
    if spec.is_empty() || spec.contains(',') || size == 0 {
        return Err(RangeParseError::Invalid);
    }
    let (first, last) = spec.split_once('-').ok_or(RangeParseError::Invalid)?;
    if first.is_empty() {
        let suffix_len = parse_range_number(last).ok_or(RangeParseError::Invalid)?;
        if suffix_len == 0 {
            return Err(RangeParseError::Invalid);
        }
        let length = suffix_len.min(size);
        return Ok((size - length, size - 1));
    }

    let start = parse_range_number(first).ok_or(RangeParseError::Invalid)?;
    if start >= size {
        return Err(RangeParseError::Invalid);
    }
    let end = if last.is_empty() {
        size - 1
    } else {
        let requested_end = parse_range_number(last).ok_or(RangeParseError::Invalid)?;
        if requested_end < start {
            return Err(RangeParseError::Invalid);
        }
        requested_end.min(size - 1)
    };
    Ok((start, end))
}

fn if_range_matches(headers: &HeaderMap, etag: &str) -> bool {
    let values = headers.get_all(header::IF_RANGE);
    let mut iter = values.iter();
    match (iter.next(), iter.next()) {
        (None, _) => true,
        (Some(value), None) => value.to_str().is_ok_and(|value| value == etag),
        _ => false,
    }
}

pub(crate) fn byte_range_from_headers(
    headers: &HeaderMap,
    etag: &str,
    size: u64,
) -> Result<Option<(u64, u64)>, ()> {
    let values = headers.get_all(header::RANGE);
    let mut iter = values.iter();
    let Some(value) = iter.next() else {
        return Ok(None);
    };

    // If-Range with a stale/unsupported validator means the client wants the
    // full current representation; in that case Range is ignored per HTTP.
    if !if_range_matches(headers, etag) {
        return Ok(None);
    }
    if iter.next().is_some() {
        return Err(());
    }
    let value = value.to_str().map_err(|_| ())?;
    match parse_single_byte_range(value, size) {
        Ok(range) => Ok(Some(range)),
        Err(RangeParseError::UnsupportedUnit) => Ok(None),
        Err(RangeParseError::Invalid) => Err(()),
    }
}

#[derive(Deserialize)]
pub struct InitRequest {
    pub object_id: String,
    pub size: i64,
    pub sha256: String,
}

#[derive(Debug)]
struct UploadReservation {
    upload_id: String,
    expires_at: String,
}

/// Reuses the authenticated user's still-open reservation for an immutable
/// object. The caller must hold the vault writer lock before calling this so
/// the lookup, quota check, and insert are one serialized operation.
async fn reserve_upload_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    vault_id: &str,
    object_id: &str,
    size: i64,
    sha256: &str,
    now: &str,
    max_object_bytes: i64,
    storage_backend: &str,
    storage_store_id: Option<&str>,
) -> Result<UploadReservation, ApiError> {
    if size <= 0 || size > max_object_bytes {
        return Err(ApiError::too_large("object size exceeds configured limit"));
    }
    let existing: Option<String> =
        sqlx::query_scalar("SELECT object_id FROM blob_objects WHERE vault_id=? AND object_id=?")
            .bind(vault_id)
            .bind(object_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if existing.is_some() {
        return Err(ApiError::conflict(
            "OBJECT_EXISTS",
            "object ids are immutable",
        ));
    }

    let own_mismatch: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM uploads WHERE vault_id=? AND object_id=? AND user_id=? \
         AND state IN ('open','completing') AND expires_at>? AND (expected_size<>? OR lower(expected_sha256)<>?) \
         LIMIT 1",
    )
    .bind(vault_id)
    .bind(object_id)
    .bind(user_id)
    .bind(now)
    .bind(size)
    .bind(sha256)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if own_mismatch.is_some() {
        return Err(ApiError::conflict(
            "UPLOAD_RESERVATION_CONFLICT",
            "object id already has an open reservation with different content metadata",
        ));
    }

    let own_reservation = sqlx::query(
        "SELECT u.upload_id,u.expires_at FROM uploads u \
         WHERE u.vault_id=? AND u.object_id=? AND u.user_id=? AND u.state IN ('open','completing') \
         AND u.expires_at>? AND u.expected_size=? AND lower(u.expected_sha256)=? \
         ORDER BY (SELECT COUNT(*) FROM upload_chunks c WHERE c.upload_id=u.upload_id) DESC, \
         u.created_at,u.upload_id LIMIT 1",
    )
    .bind(vault_id)
    .bind(object_id)
    .bind(user_id)
    .bind(now)
    .bind(size)
    .bind(sha256)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if let Some(row) = own_reservation {
        // Legacy server versions could create duplicate active reservations.
        // Prefer the one with the most uploaded chunks to preserve progress;
        // new requests no longer add further duplicate reservations.
        return Ok(UploadReservation {
            upload_id: row.get("upload_id"),
            expires_at: row.get("expires_at"),
        });
    }

    let another_user_has_reservation: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM uploads WHERE vault_id=? AND object_id=? AND user_id<>? \
         AND state IN ('open','completing') AND expires_at>? LIMIT 1",
    )
    .bind(vault_id)
    .bind(object_id)
    .bind(user_id)
    .bind(now)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if another_user_has_reservation.is_some() {
        // Upload tickets are user-bound. Do not reveal or return another
        // member's ticket, and do not charge quota for a second reservation.
        return Err(ApiError::conflict(
            "UPLOAD_IN_PROGRESS",
            "object id already has an open upload reservation",
        ));
    }

    // Retire expired reservations for this object before creating a new one.
    // This immediately releases their chunk payloads instead of waiting for
    // the periodic maintenance pass.
    sqlx::query(
        "UPDATE uploads SET state='expired' WHERE vault_id=? AND object_id=? \
         AND state IN ('open','completing') AND expires_at<=?",
    )
    .bind(vault_id)
    .bind(object_id)
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "DELETE FROM upload_chunks WHERE upload_id IN (SELECT upload_id FROM uploads \
         WHERE vault_id=? AND object_id=? AND state='expired')",
    )
    .bind(vault_id)
    .bind(object_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;

    let row = sqlx::query(
        "SELECT v.quota_bytes,\
         (SELECT COALESCE(SUM(size),0) FROM blob_objects WHERE vault_id=v.vault_id)+\
         (SELECT COALESCE(SUM(expected_size),0) FROM uploads \
          WHERE vault_id=v.vault_id AND state IN ('open','completing') AND expires_at>?) AS used \
         FROM vaults v WHERE v.vault_id=? AND v.state='active'",
    )
    .bind(now)
    .bind(vault_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let quota: i64 = row.get("quota_bytes");
    let used: i64 = row.get("used");
    if used.saturating_add(size) > quota {
        return Err(ApiError::new(
            StatusCode::INSUFFICIENT_STORAGE,
            "QUOTA_EXCEEDED",
            "vault storage quota is exceeded",
        ));
    }

    let upload_id = Uuid::new_v4().to_string();
    let expires_at = (Utc::now() + Duration::hours(24)).to_rfc3339();
    sqlx::query(
        "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,\
         chunk_size,state,expires_at,created_at,storage_backend,storage_store_id) \
         VALUES(?,?,?,?,?,?,?,'open',?,?,?,?)",
    )
    .bind(&upload_id)
    .bind(vault_id)
    .bind(user_id)
    .bind(object_id)
    .bind(size)
    .bind(sha256)
    .bind(CHUNK_SIZE)
    .bind(&expires_at)
    .bind(now)
    .bind(storage_backend)
    .bind(storage_store_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(UploadReservation {
        upload_id,
        expires_at,
    })
}

pub async fn init_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault): Path<String>,
    Json(req): Json<InitRequest>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = state.pg_objects.as_ref() {
        let user = crate::current_sync_user(&state, &headers).await?;
        return repository
            .init_upload(&state, &user, &vault, req)
            .await
            .map(Json);
    }
    #[cfg(test)]
    {
        init_upload_inner(state, headers, vault, req, None).await
    }
    #[cfg(not(test))]
    {
        init_upload_inner(state, headers, vault, req).await
    }
}

async fn init_upload_inner(
    state: AppState,
    headers: HeaderMap,
    vault: String,
    req: InitRequest,
    #[cfg(test)] test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if !crate::is_canonical_uuid(&req.object_id) {
        return Err(ApiError::bad_request(
            "INVALID_OBJECT_ID",
            "object_id must be a lowercase canonical UUID",
        ));
    }
    if req.size <= 0 || req.size > state.config.max_object_bytes {
        return Err(ApiError::too_large("object size exceeds configured limit"));
    }
    if req.sha256.len() != 64 || !req.sha256.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(ApiError::bad_request(
            "INVALID_OBJECT_HASH",
            "sha256 must be a hexadecimal digest",
        ));
    }
    // init_upload normally performs its Vault/device authorization inside the
    // writer transaction. The route test injects those existing checks here
    // to model a request that completed preflight before a concurrent revoke;
    // normal route calls never install this test-only gate.
    #[cfg(test)]
    if let Some(gate) = test_pause.as_ref() {
        crate::require_vault(&state, &user.user_id, &vault, true).await?;
        crate::ensure_active_device(&state, &user.user_id, &user.device_id).await?;
        gate.pause().await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Acquire SQLite's writer reservation before reading quota so concurrent
    // initializations cannot over-reserve it or race a pending deletion.
    crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault).await?;
    let now = now_rfc3339();
    state
        .object_store
        .queue_expired_completions_tx(
            &mut tx,
            &state.instance.instance_id,
            &now,
            Utc::now().timestamp(),
        )
        .await?;
    let sha256 = req.sha256.to_ascii_lowercase();
    let storage_backend = state.object_store.backend_name();
    let reservation = reserve_upload_tx(
        &mut tx,
        &user.user_id,
        &vault,
        &req.object_id,
        req.size,
        &sha256,
        &now,
        state.config.max_object_bytes,
        storage_backend,
        state.object_store.store_id(),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"upload_id":reservation.upload_id,"chunk_size":CHUNK_SIZE,"expires_at":reservation.expires_at}),
    ))
}

pub async fn put_chunk(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((upload, index)): Path<(String, i64)>,
    body: Bytes,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = state.pg_objects.as_ref() {
        let user = crate::current_sync_user(&state, &headers).await?;
        return repository
            .put_chunk(&user, &upload, index, body)
            .await
            .map(Json);
    }
    #[cfg(test)]
    {
        put_chunk_inner(state, headers, upload, index, body, None).await
    }
    #[cfg(not(test))]
    {
        put_chunk_inner(state, headers, upload, index, body).await
    }
}

async fn put_chunk_inner(
    state: AppState,
    headers: HeaderMap,
    upload: String,
    index: i64,
    body: Bytes,
    #[cfg(test)] test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
) -> Result<Json<Value>, ApiError> {
    let user = current_user(&state, &headers).await?;
    if body.is_empty() || body.len() > CHUNK_SIZE as usize {
        return Err(ApiError::too_large(
            "chunk must contain between 1 byte and 1 MiB",
        ));
    }
    let owner_row = sqlx::query("SELECT vault_id,user_id FROM uploads WHERE upload_id=?")
        .bind(&upload)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let vault: String = owner_row.get("vault_id");
    if owner_row.get::<String, _>("user_id") != user.user_id {
        return Err(ApiError::not_found());
    }
    // Authentication and owner metadata were read before the writer lock.
    // Tests can pause here to revoke the device and prove the locked recheck
    // below rejects the stale principal. Production requests never install it.
    #[cfg(test)]
    if let Some(gate) = test_pause.as_ref() {
        gate.pause().await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault).await?;
    let row = sqlx::query("SELECT expected_size,chunk_size,state,expires_at FROM uploads WHERE upload_id=? AND vault_id=? AND user_id=?")
        .bind(&upload)
        .bind(&vault)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let expected: i64 = row.get("expected_size");
    let chunk_size: i64 = row.get("chunk_size");
    let status: String = row.get("state");
    let expires: String = row.get("expires_at");
    if status != "open"
        || chrono::DateTime::parse_from_rfc3339(&expires).map_or(true, |d| d <= Utc::now())
    {
        return Err(ApiError::gone(
            "UPLOAD_EXPIRED",
            "upload is closed or expired",
        ));
    }
    let count = (expected + chunk_size - 1) / chunk_size;
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
        sqlx::query("SELECT sha256 FROM upload_chunks WHERE upload_id=? AND chunk_index=?")
            .bind(&upload)
            .bind(index)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?
    {
        let old: String = existing.get("sha256");
        if old != digest {
            return Err(ApiError::conflict(
                "CHUNK_IMMUTABLE",
                "chunk index already contains different bytes",
            ));
        }
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(
            json!({"upload_id":upload,"index":index,"sha256":digest,"already_uploaded":true}),
        ));
    }
    sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,?,?,?)")
        .bind(&upload)
        .bind(index)
        .bind(&body[..])
        .bind(&digest)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"upload_id":upload,"index":index,"sha256":digest,"already_uploaded":false}),
    ))
}

pub async fn complete_upload(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(upload): Path<String>,
) -> Result<Json<Value>, ApiError> {
    if let Some(repository) = state.pg_objects.as_ref() {
        let user = crate::current_sync_user(&state, &headers).await?;
        return repository
            .complete_upload(&state, &user, &upload)
            .await
            .map(Json);
    }
    #[cfg(test)]
    {
        complete_upload_inner(state, headers, upload, None).await
    }
    #[cfg(not(test))]
    {
        complete_upload_inner(state, headers, upload).await
    }
}

async fn complete_upload_inner(
    state: AppState,
    headers: HeaderMap,
    upload: String,
    #[cfg(test)] test_pause: Option<std::sync::Arc<crate::recovery::TestPause>>,
) -> Result<Json<Value>, ApiError> {
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
    let user = current_user(&state, &headers).await?;
    let upload_owner = sqlx::query("SELECT vault_id,user_id FROM uploads WHERE upload_id=?")
        .bind(&upload)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let vault: String = upload_owner.get("vault_id");
    if upload_owner.get::<String, _>("user_id") != user.user_id {
        return Err(ApiError::not_found());
    }
    // Pause only after the actual bearer authentication and ownership lookup,
    // before `begin()`. The writer-transaction authorization remains the
    // production check and must observe a concurrent revoke.
    #[cfg(test)]
    if let Some(gate) = test_pause.as_ref() {
        gate.pause().await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(&vault)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault).await?;
    let row=sqlx::query("SELECT object_id,expected_size,expected_sha256,chunk_size,state,expires_at,storage_backend,storage_store_id FROM uploads WHERE upload_id=? AND vault_id=? AND user_id=?").bind(&upload).bind(&vault).bind(&user.user_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?.ok_or_else(ApiError::not_found)?;
    let object: String = row.get("object_id");
    let size: i64 = row.get("expected_size");
    let expected_sha: String = row.get("expected_sha256");
    let chunk_size: i64 = row.get("chunk_size");
    let status: String = row.get("state");
    let expires: String = row.get("expires_at");
    let storage_backend: String = row.get("storage_backend");
    let reservation_store_id: Option<String> = row.get("storage_store_id");
    if status == "collected" {
        return Err(ApiError::gone(
            "OBJECT_COLLECTED",
            "the completed object has been collected",
        ));
    }
    if status == "completed" {
        let Some(b) =
            sqlx::query("SELECT sha256,size FROM blob_objects WHERE vault_id=? AND object_id=?")
                .bind(&vault)
                .bind(&object)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?
        else {
            return Err(ApiError::gone(
                "OBJECT_COLLECTED",
                "the completed object has been collected",
            ));
        };
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(
            json!({"object_id":object,"size":b.get::<i64,_>("size"),"sha256":b.get::<String,_>("sha256"),"already_completed":true}),
        ));
    }
    if !matches!(status.as_str(), "open" | "completing")
        || (status == "completing" && storage_backend == "sqlite")
        || chrono::DateTime::parse_from_rfc3339(&expires).map_or(true, |d| d <= Utc::now())
    {
        return Err(ApiError::gone(
            "UPLOAD_EXPIRED",
            "upload is closed or expired",
        ));
    }
    let chunks = sqlx::query(
        "SELECT chunk_index,bytes,sha256 FROM upload_chunks WHERE upload_id=? ORDER BY chunk_index",
    )
    .bind(&upload)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let expected_count = ((size + chunk_size - 1) / chunk_size) as usize;
    if chunks.len() != expected_count {
        return Err(ApiError::conflict(
            "UPLOAD_INCOMPLETE",
            "upload has missing chunks",
        ));
    }
    let mut all = Vec::with_capacity(size as usize);
    let mut receipts = Vec::new();
    for (pos, c) in chunks.iter().enumerate() {
        let idx: i64 = c.get("chunk_index");
        if idx as usize != pos {
            return Err(ApiError::conflict(
                "UPLOAD_INCOMPLETE",
                "upload has missing chunks",
            ));
        }
        let bytes: Vec<u8> = c.get("bytes");
        let digest: String = c.get("sha256");
        if sha256_hex(&bytes) != digest {
            return Err(ApiError::conflict(
                "OBJECT_HASH_MISMATCH",
                "stored chunk failed integrity check",
            ));
        }
        all.extend_from_slice(&bytes);
        receipts.push(json!({"index":idx,"sha256":digest,"size":bytes.len()}));
    }
    if all.len() as i64 != size || sha256_hex(&all) != expected_sha {
        return Err(ApiError::conflict(
            "OBJECT_HASH_MISMATCH",
            "assembled object does not match declared size or digest",
        ));
    }
    let gc_after = Utc::now()
        .timestamp()
        .saturating_add(state.config.object_gc_grace_seconds);
    if storage_backend != "sqlite" {
        let Some(expected_store_id) = reservation_store_id.as_deref() else {
            return Err(ApiError::internal(
                "external upload storage identity is missing",
            ));
        };
        let (storage_key, generated_store_id) = state
            .object_store
            .object_key(&state.instance.instance_id, &vault, &object, &upload)
            .map_err(crate::object_store::storage_api_error)?;
        if generated_store_id != expected_store_id {
            return Err(ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "OBJECT_STORAGE_UNAVAILABLE",
                "object storage is temporarily unavailable",
            ));
        }
        if status == "open" {
            sqlx::query("UPDATE uploads SET state='completing' WHERE upload_id=? AND state='open'")
                .bind(&upload)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        // The `completing` row is a durable retry record. Never hold SQLite's
        // writer lock while transferring or verifying bytes with external storage.
        tx.commit().await.map_err(ApiError::internal)?;
        state
            .object_store
            .put_immutable(&storage_key, &all, size, &expected_sha)
            .await
            .map_err(crate::object_store::storage_api_error)?;

        let mut publish_tx = state.db.begin().await.map_err(ApiError::internal)?;
        let lock_result = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
            .bind(&vault)
            .execute(&mut *publish_tx)
            .await
            .map_err(ApiError::internal)?;
        let authorization = if lock_result.rows_affected() == 0 {
            Err(ApiError::not_found())
        } else {
            crate::require_authenticated_vault_write_tx(&mut publish_tx, &user, &vault).await
        };
        if let Err(error) = authorization {
            crate::object_store::ObjectStore::queue_external_delete_tx(
                &mut publish_tx,
                &storage_backend,
                expected_store_id,
                &storage_key,
                size,
                &expected_sha,
                Utc::now().timestamp(),
            )
            .await?;
            sqlx::query(
                "UPDATE uploads SET state='expired' WHERE upload_id=? AND state='completing'",
            )
            .bind(&upload)
            .execute(&mut *publish_tx)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query("DELETE FROM upload_chunks WHERE upload_id=?")
                .bind(&upload)
                .execute(&mut *publish_tx)
                .await
                .map_err(ApiError::internal)?;
            publish_tx.commit().await.map_err(ApiError::internal)?;
            return Err(error);
        }
        let current: Option<(String, i64, String, String)> = sqlx::query_as(
            "SELECT state,expected_size,expected_sha256,expires_at FROM uploads WHERE upload_id=? AND vault_id=? AND user_id=?",
        )
        .bind(&upload)
        .bind(&vault)
        .bind(&user.user_id)
        .fetch_optional(&mut *publish_tx)
        .await
        .map_err(ApiError::internal)?;
        let publishable = current.as_ref().is_some_and(|row| {
            row.0 == "completing"
                && row.1 == size
                && row.2.eq_ignore_ascii_case(&expected_sha)
                && chrono::DateTime::parse_from_rfc3339(&row.3)
                    .is_ok_and(|expires| expires > Utc::now())
        });
        if !publishable {
            crate::object_store::ObjectStore::queue_external_delete_tx(
                &mut publish_tx,
                &storage_backend,
                expected_store_id,
                &storage_key,
                size,
                &expected_sha,
                Utc::now().timestamp(),
            )
            .await?;
            if current.is_some() {
                sqlx::query(
                    "UPDATE uploads SET state='expired' WHERE upload_id=? AND state='completing'",
                )
                .bind(&upload)
                .execute(&mut *publish_tx)
                .await
                .map_err(ApiError::internal)?;
                sqlx::query("DELETE FROM upload_chunks WHERE upload_id=?")
                    .bind(&upload)
                    .execute(&mut *publish_tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
            publish_tx.commit().await.map_err(ApiError::internal)?;
            return Err(ApiError::gone(
                "UPLOAD_EXPIRED",
                "upload is closed or expired",
            ));
        }
        let insert = sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after,storage_backend,storage_key,storage_store_id,storage_state) \
             VALUES(?, ?, X'', ?, ?, ?, ?, ?, ?, ?, 'available')",
        )
        .bind(&vault)
        .bind(&object)
        .bind(size)
        .bind(&expected_sha)
        .bind(now_rfc3339())
        .bind(gc_after)
        .bind(&storage_backend)
        .bind(&storage_key)
        .bind(expected_store_id)
        .execute(&mut *publish_tx)
        .await;
        if let Err(error) = insert {
            let existing: Option<(i64, String, String, String, Option<String>)> = sqlx::query_as(
                "SELECT size,sha256,storage_key,storage_backend,storage_store_id FROM blob_objects WHERE vault_id=? AND object_id=?",
            )
            .bind(&vault)
            .bind(&object)
            .fetch_optional(&mut *publish_tx)
            .await
            .map_err(ApiError::internal)?;
            let Some(existing) = existing else {
                return Err(ApiError::internal(error));
            };
            if existing.0 != size
                || !existing.1.eq_ignore_ascii_case(&expected_sha)
                || existing.2 != storage_key
                || existing.3 != storage_backend
                || existing.4.as_deref() != Some(expected_store_id)
            {
                // This upload's unique S3 key is verified but cannot become
                // the immutable catalogue winner. Persist cleanup in the
                // same transaction before returning OBJECT_EXISTS.
                crate::object_store::ObjectStore::queue_external_delete_tx(
                    &mut publish_tx,
                    &storage_backend,
                    expected_store_id,
                    &storage_key,
                    size,
                    &expected_sha,
                    Utc::now().timestamp(),
                )
                .await?;
                sqlx::query(
                    "UPDATE uploads SET state='expired' WHERE upload_id=? AND state='completing'",
                )
                .bind(&upload)
                .execute(&mut *publish_tx)
                .await
                .map_err(ApiError::internal)?;
                sqlx::query("DELETE FROM upload_chunks WHERE upload_id=?")
                    .bind(&upload)
                    .execute(&mut *publish_tx)
                    .await
                    .map_err(ApiError::internal)?;
                publish_tx.commit().await.map_err(ApiError::internal)?;
                return Err(ApiError::conflict(
                    "OBJECT_EXISTS",
                    "object id already exists",
                ));
            }
        }
        sqlx::query(
            "UPDATE uploads SET state='completed' WHERE upload_id=? AND state='completing'",
        )
        .bind(&upload)
        .execute(&mut *publish_tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM upload_chunks WHERE upload_id=?")
            .bind(&upload)
            .execute(&mut *publish_tx)
            .await
            .map_err(ApiError::internal)?;
        publish_tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(
            json!({"object_id":object,"size":size,"sha256":expected_sha,"chunks":receipts}),
        ));
    }
    sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,?,?,?,?,?)").bind(&vault).bind(&object).bind(&all).bind(size).bind(&expected_sha).bind(now_rfc3339()).bind(gc_after).execute(&mut *tx).await.map_err(|_|ApiError::conflict("OBJECT_EXISTS","object id already exists"))?;
    sqlx::query("UPDATE uploads SET state='completed' WHERE upload_id=?")
        .bind(&upload)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM upload_chunks WHERE upload_id=?")
        .bind(&upload)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(
        json!({"object_id":object,"size":size,"sha256":expected_sha,"chunks":receipts}),
    ))
}

pub async fn get_object(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault, object)): Path<(String, String)>,
) -> Result<Response, ApiError> {
    let user = crate::current_sync_user(&state, &headers).await?;
    get_object_for_user(&state, &user, &vault, &object, &headers).await
}

pub(crate) async fn get_object_for_user(
    state: &AppState,
    user: &crate::auth::AuthUser,
    vault: &str,
    object: &str,
    headers: &HeaderMap,
) -> Result<Response, ApiError> {
    if let Some(repository) = state.pg_objects.as_ref() {
        return repository
            .get_object(state, user, vault, object, headers)
            .await;
    }
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    // Keep bearer/device authorization, Vault membership and the object read
    // in one read-only SQLite snapshot. Do not use the writer-locking read
    // helper here: downloads must not serialize with unrelated SQLite writes.
    crate::require_active_session_device_read_tx(&mut tx, user).await?;
    crate::require_vault_read_snapshot_tx(&mut tx, &user.user_id, vault).await?;
    crate::require_redaction_client_for_vault_tx(&mut tx, vault, user.declares_sync_redaction_v1)
        .await?;
    let now = now_rfc3339();
    let referenced_or_owned_retry: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM object_references r WHERE r.vault_id=? AND r.object_id=?) \
         OR EXISTS(SELECT 1 FROM uploads u JOIN blob_objects b \
           ON b.vault_id=u.vault_id AND b.object_id=u.object_id \
           WHERE u.vault_id=? AND u.object_id=? AND u.user_id=? AND u.state='completed' \
             AND u.expires_at>? AND b.storage_state='available')",
    )
    .bind(vault)
    .bind(object)
    .bind(vault)
    .bind(object)
    .bind(&user.user_id)
    .bind(now)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if !referenced_or_owned_retry {
        return Err(ApiError::not_found());
    }
    let row = sqlx::query(
        "SELECT length(bytes) AS byte_length,size,sha256,storage_backend,storage_key,storage_store_id,storage_state \
         FROM blob_objects WHERE vault_id=? AND object_id=?",
    )
    .bind(vault)
    .bind(object)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let storage_state: String = row.get("storage_state");
    if storage_state != "available" {
        return Err(ApiError::not_found());
    }
    let storage_backend: String = row.get("storage_backend");
    let size = match storage_backend.as_str() {
        // Preserve SQLite's prior behavior of deriving response size from the
        // payload itself, including for rows inserted by older versions.
        "sqlite" => {
            let byte_length: i64 = row.get("byte_length");
            u64::try_from(byte_length).map_err(ApiError::internal)?
        }
        "s3" | "filesystem" => {
            u64::try_from(row.get::<i64, _>("size")).map_err(ApiError::internal)?
        }
        _ => return Err(ApiError::internal("object storage backend is invalid")),
    };
    let digest: String = row.get("sha256");
    let etag = format!("\"sha256-{digest}\"");
    let selected_range = byte_range_from_headers(headers, &etag, size);
    // The SQLite backend reads only the requested BLOB slice. Remote storage
    // performs no network I/O until after the authorization/catalogue snapshot
    // has closed below.
    let bytes = if storage_backend == "sqlite" {
        match selected_range {
            Ok(Some((start, end))) => {
                Some(read_object_bytes_tx(&mut tx, vault, object, Some((start, end))).await?)
            }
            Ok(None) => Some(read_object_bytes_tx(&mut tx, vault, object, None).await?),
            Err(()) => None,
        }
    } else {
        None
    };
    let remote_key: Option<String> = row.try_get("storage_key").map_err(ApiError::internal)?;
    let remote_store_id: Option<String> = row
        .try_get("storage_store_id")
        .map_err(ApiError::internal)?;
    if storage_backend != "sqlite"
        && (storage_backend != state.object_store.backend_name()
            || remote_key.is_none()
            || remote_store_id.as_deref() != state.object_store.store_id())
    {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "OBJECT_STORAGE_UNAVAILABLE",
            "object storage is temporarily unavailable",
        ));
    }
    let remote_key = if storage_backend != "sqlite" {
        Some(remote_key.ok_or_else(|| {
            ApiError::new(
                StatusCode::SERVICE_UNAVAILABLE,
                "OBJECT_STORAGE_UNAVAILABLE",
                "object storage is temporarily unavailable",
            )
        })?)
    } else {
        None
    };
    // Release the SQLite snapshot before response construction and HTTP send.
    tx.commit().await.map_err(ApiError::internal)?;
    let bytes = if storage_backend != "sqlite" {
        match selected_range {
            Err(()) => None,
            Ok(range) => Some(
                state
                    .object_store
                    .read_object(
                        remote_key
                            .as_deref()
                            .expect("external object key checked above"),
                        i64::try_from(size).map_err(ApiError::internal)?,
                        &digest,
                        range,
                    )
                    .await
                    .map_err(crate::object_store::storage_api_error)?,
            ),
        }
    } else {
        bytes
    };
    let (mut response, content_length) = match selected_range {
        Ok(Some((start, end))) => {
            let partial =
                bytes.ok_or_else(|| ApiError::internal("ranged object bytes are missing"))?;
            let mut response = (StatusCode::PARTIAL_CONTENT, partial).into_response();
            let content_range = HeaderValue::from_str(&format!("bytes {start}-{end}/{size}"))
                .map_err(ApiError::internal)?;
            response
                .headers_mut()
                .insert(header::CONTENT_RANGE, content_range);
            (response, end - start + 1)
        }
        Ok(None) => (
            (
                StatusCode::OK,
                bytes.ok_or_else(|| ApiError::internal("object bytes are missing"))?,
            )
                .into_response(),
            size,
        ),
        Err(()) => {
            let mut response = StatusCode::RANGE_NOT_SATISFIABLE.into_response();
            let content_range =
                HeaderValue::from_str(&format!("bytes */{size}")).map_err(ApiError::internal)?;
            response
                .headers_mut()
                .insert(header::CONTENT_RANGE, content_range);
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
    let etag_header = HeaderValue::from_str(&etag).map_err(ApiError::internal)?;
    response.headers_mut().insert(header::ETAG, etag_header);
    let content_length =
        HeaderValue::from_str(&content_length.to_string()).map_err(ApiError::internal)?;
    response
        .headers_mut()
        .insert(header::CONTENT_LENGTH, content_length);
    Ok(response)
}

async fn read_object_bytes_tx(
    tx: &mut sqlx::Transaction<'_, Sqlite>,
    vault: &str,
    object: &str,
    range: Option<(u64, u64)>,
) -> Result<Vec<u8>, ApiError> {
    if let Some((start, end)) = range {
        // SQLite BLOB substr positions are one-based, unlike HTTP ranges.
        let sqlite_start = start
            .checked_add(1)
            .and_then(|value| i64::try_from(value).ok())
            .ok_or_else(|| ApiError::internal("object range start is invalid"))?;
        let length = end
            .checked_sub(start)
            .and_then(|value| value.checked_add(1))
            .and_then(|value| i64::try_from(value).ok())
            .ok_or_else(|| ApiError::internal("object range length is invalid"))?;
        sqlx::query_scalar(
            "SELECT substr(bytes,?,?) FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(sqlite_start)
        .bind(length)
        .bind(vault)
        .bind(object)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)
    } else {
        sqlx::query_scalar("SELECT bytes FROM blob_objects WHERE vault_id=? AND object_id=?")
            .bind(vault)
            .bind(object)
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)
    }
}

#[cfg(test)]
mod range_tests {
    use axum::http::{HeaderMap, HeaderValue, header};
    use sqlx::sqlite::SqlitePoolOptions;

    use super::{
        RangeParseError, byte_range_from_headers, if_range_matches, parse_single_byte_range,
        read_object_bytes_tx,
    };

    #[tokio::test]
    async fn ranged_blob_query_returns_only_the_requested_subslice() {
        let pool = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query(
            "CREATE TABLE blob_objects(vault_id TEXT,object_id TEXT,bytes BLOB,PRIMARY KEY(vault_id,object_id))",
        )
        .execute(&pool)
        .await
        .unwrap();
        let source = (0..2 * 1024 * 1024)
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes) VALUES('vault','object',?)",
        )
        .bind(&source[..])
        .execute(&pool)
        .await
        .unwrap();

        let start = 1024 * 1024 + 37;
        let end = start + 23;
        let mut tx = pool.begin().await.unwrap();
        let ranged =
            read_object_bytes_tx(&mut tx, "vault", "object", Some((start as u64, end as u64)))
                .await
                .unwrap();
        assert_eq!(ranged, source[start..=end]);
        assert_eq!(ranged.len(), end - start + 1);

        let full = read_object_bytes_tx(&mut tx, "vault", "object", None)
            .await
            .unwrap();
        assert_eq!(full, source);
        tx.commit().await.unwrap();
        pool.close().await;
    }

    #[test]
    fn parses_open_ended_closed_and_suffix_byte_ranges() {
        assert_eq!(parse_single_byte_range("bytes=2-5", 10), Ok((2, 5)));
        assert_eq!(parse_single_byte_range("bytes=7-", 10), Ok((7, 9)));
        assert_eq!(parse_single_byte_range("bytes=-3", 10), Ok((7, 9)));
        assert_eq!(parse_single_byte_range("bytes=-30", 10), Ok((0, 9)));
        assert_eq!(parse_single_byte_range("bytes=2-30", 10), Ok((2, 9)));
    }

    #[test]
    fn malformed_multiple_and_unsatisfiable_ranges_are_rejected() {
        for value in [
            "bytes=",
            "bytes=1-0",
            "bytes=10-",
            "bytes=-0",
            "bytes=0-1,4-5",
            "bytes=+1-2",
        ] {
            assert_eq!(
                parse_single_byte_range(value, 10),
                Err(RangeParseError::Invalid)
            );
        }
        assert_eq!(
            parse_single_byte_range("bytes=0-0", 0),
            Err(RangeParseError::Invalid)
        );
        assert_eq!(
            parse_single_byte_range("items=0-1", 10),
            Err(RangeParseError::UnsupportedUnit)
        );
        let mut unknown_unit = HeaderMap::new();
        unknown_unit.insert(header::RANGE, HeaderValue::from_static("items=0-1"));
        assert_eq!(
            byte_range_from_headers(&unknown_unit, "\"etag\"", 10),
            Ok(None)
        );
    }

    #[test]
    fn if_range_requires_exact_strong_etag_and_stale_validator_uses_full_body() {
        let etag = "\"sha256-deadbeef\"";
        let mut headers = HeaderMap::new();
        headers.insert(header::RANGE, HeaderValue::from_static("bytes=0-1"));
        assert_eq!(byte_range_from_headers(&headers, etag, 8), Ok(Some((0, 1))));

        headers.insert(header::IF_RANGE, HeaderValue::from_static(etag));
        assert!(if_range_matches(&headers, etag));
        assert_eq!(byte_range_from_headers(&headers, etag, 8), Ok(Some((0, 1))));

        headers.insert(
            header::IF_RANGE,
            HeaderValue::from_static("\"sha256-stale\""),
        );
        assert!(!if_range_matches(&headers, etag));
        assert_eq!(byte_range_from_headers(&headers, etag, 8), Ok(None));

        headers.insert(
            header::IF_RANGE,
            HeaderValue::from_static("W/\"sha256-deadbeef\""),
        );
        assert_eq!(byte_range_from_headers(&headers, etag, 8), Ok(None));
    }

    #[test]
    fn duplicate_header_instances_are_rejected_or_fall_back_safely() {
        let etag = "\"sha256-deadbeef\"";
        let mut ranges = HeaderMap::new();
        ranges.append(header::RANGE, HeaderValue::from_static("bytes=0-1"));
        ranges.append(header::RANGE, HeaderValue::from_static("bytes=2-3"));
        assert_eq!(byte_range_from_headers(&ranges, etag, 8), Err(()));

        let mut if_ranges = HeaderMap::new();
        if_ranges.insert(header::RANGE, HeaderValue::from_static("bytes=0-1"));
        if_ranges.append(header::IF_RANGE, HeaderValue::from_static(etag));
        if_ranges.append(
            header::IF_RANGE,
            HeaderValue::from_static("\"sha256-stale\""),
        );
        assert_eq!(byte_range_from_headers(&if_ranges, etag, 8), Ok(None));
    }
}

#[cfg(test)]
mod upload_init_tests {
    use super::*;
    use crate::{Config, open_state};
    use axum::{
        Router,
        body::Body,
        extract::{Path, State},
        http::{HeaderMap, Request, StatusCode, header::AUTHORIZATION, header::CONTENT_TYPE},
        routing::{post, put},
    };
    use serde_json::json;
    use std::path::PathBuf;
    use std::sync::Arc;
    use tower::ServiceExt;
    use uuid::Uuid;

    fn config(data_dir: PathBuf) -> Config {
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
            auth_rate_limits: crate::AuthRateLimits::default(),
        }
    }

    async fn test_state() -> (crate::AppState, PathBuf, String, String) {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-upload-init-{}", Uuid::new_v4()));
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = open_state(&database_url, config(data_dir.clone()))
            .await
            .unwrap();
        let user_id = Uuid::new_v4().to_string();
        let vault_id = Uuid::new_v4().to_string();
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(format!("{user_id}@example.test"))
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,quota_bytes,created_at) VALUES(?,?,1073741824,?)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?)",
        )
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        (state, data_dir, user_id, vault_id)
    }

    struct RevocationCredentials {
        writer_device_id: String,
        writer_token: String,
        revoker_token: String,
    }

    async fn seed_revocation_credentials(
        state: &crate::AppState,
        user_id: &str,
    ) -> RevocationCredentials {
        let writer_device_id = Uuid::new_v4().to_string();
        let revoker_device_id = Uuid::new_v4().to_string();
        let writer_token = format!("writer-{}", Uuid::new_v4());
        let revoker_token = format!("revoker-{}", Uuid::new_v4());
        let created = now_rfc3339();
        for (device_id, name) in [
            (&writer_device_id, "upload-writer"),
            (&revoker_device_id, "upload-revoker"),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
                .bind(device_id)
                .bind(user_id)
                .bind(name)
                .bind("test-signing-public")
                .bind("test-encryption-public")
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }
        let access_expires = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        let refresh_expires = (chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339();
        for (device_id, access) in [
            (&writer_device_id, &writer_token),
            (&revoker_device_id, &revoker_token),
        ] {
            sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
                .bind(Uuid::new_v4().to_string())
                .bind(user_id)
                .bind(device_id)
                .bind(Uuid::new_v4().to_string())
                .bind(crate::sha256_hex(access.as_bytes()))
                .bind(crate::sha256_hex(format!("refresh-{access}").as_bytes()))
                .bind(&access_expires)
                .bind(&refresh_expires)
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }
        RevocationCredentials {
            writer_device_id,
            writer_token,
            revoker_token,
        }
    }

    async fn seed_upload_for_route(
        state: &crate::AppState,
        user_id: &str,
        vault_id: &str,
        bytes: &[u8],
        include_chunk: bool,
    ) -> (String, String) {
        let upload_id = Uuid::new_v4().to_string();
        let object_id = Uuid::new_v4().to_string();
        let now = now_rfc3339();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,?,?,?,'open',?,?)")
            .bind(&upload_id)
            .bind(vault_id)
            .bind(user_id)
            .bind(&object_id)
            .bind(bytes.len() as i64)
            .bind(sha256_hex(bytes))
            .bind(CHUNK_SIZE)
            .bind((chrono::Utc::now() + chrono::Duration::hours(2)).to_rfc3339())
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        if include_chunk {
            sqlx::query(
                "INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,?,?)",
            )
            .bind(&upload_id)
            .bind(bytes)
            .bind(sha256_hex(bytes))
            .execute(&state.db)
            .await
            .unwrap();
        }
        (upload_id, object_id)
    }

    async fn seed_vault_write_counters(state: &crate::AppState, vault_id: &str) {
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq,minimum_available_seq) VALUES(?,11,4,2)")
            .bind(vault_id)
            .execute(&state.db)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn real_init_upload_route_rechecks_device_after_preflight_revoke_before_writer_reservation()
     {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        let writer_device_id = Uuid::new_v4().to_string();
        let revoker_device_id = Uuid::new_v4().to_string();
        let writer_session_id = Uuid::new_v4().to_string();
        let revoker_session_id = Uuid::new_v4().to_string();
        let writer_token = format!("writer-{}", Uuid::new_v4());
        let writer_refresh_token = format!("writer-refresh-{}", Uuid::new_v4());
        let revoker_token = format!("revoker-{}", Uuid::new_v4());
        let revoker_refresh_token = format!("revoker-refresh-{}", Uuid::new_v4());
        let created = now_rfc3339();

        for (device_id, name) in [
            (&writer_device_id, "upload-writer"),
            (&revoker_device_id, "upload-revoker"),
        ] {
            sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,?,?,?,?)")
                .bind(device_id)
                .bind(&user_id)
                .bind(name)
                .bind("test-signing-public")
                .bind("test-encryption-public")
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }
        let access_expires = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        let refresh_expires = (chrono::Utc::now() + chrono::Duration::days(1)).to_rfc3339();
        for (device_id, session_id, access, refresh) in [
            (
                &writer_device_id,
                &writer_session_id,
                &writer_token,
                &writer_refresh_token,
            ),
            (
                &revoker_device_id,
                &revoker_session_id,
                &revoker_token,
                &revoker_refresh_token,
            ),
        ] {
            sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
                .bind(session_id)
                .bind(&user_id)
                .bind(device_id)
                .bind(Uuid::new_v4().to_string())
                .bind(crate::sha256_hex(access.as_bytes()))
                .bind(crate::sha256_hex(refresh.as_bytes()))
                .bind(&access_expires)
                .bind(&refresh_expires)
                .bind(&created)
                .execute(&state.db)
                .await
                .unwrap();
        }

        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq,minimum_available_seq) VALUES(?,11,4,2)")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        // Seed non-empty reservation, chunk, object, and reference state so
        // the comparison checks exact preservation, not just empty counts.
        let existing_upload_id = Uuid::new_v4().to_string();
        let existing_upload_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,3,'existing-upload-hash',1048576,'open',?,?)")
            .bind(&existing_upload_id)
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&existing_upload_object_id)
            .bind((chrono::Utc::now() + chrono::Duration::hours(2)).to_rfc3339())
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'010203','existing-chunk-hash')")
            .bind(&existing_upload_id)
            .execute(&state.db)
            .await
            .unwrap();
        let existing_blob_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'09080706',4,'existing-blob-hash',?,9876543210)")
            .bind(&vault_id)
            .bind(&existing_blob_object_id)
            .bind(&created)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&existing_blob_object_id)
            .execute(&state.db)
            .await
            .unwrap();

        let baseline = upload_write_state(&state, &vault_id).await;
        let attempted_object_id = Uuid::new_v4().to_string();
        let gate = Arc::new(crate::recovery::TestPause::new());
        let _release_on_drop = crate::recovery::ReleasePauseOnDrop::new(gate.clone());
        let app = upload_revocation_test_router(state.clone(), Some(gate.clone()), None, None);
        let request = json_post_request(
            &format!("/api/v1/vaults/{vault_id}/uploads/init"),
            Some(&writer_token),
            json!({
                "object_id": attempted_object_id,
                "size": 13,
                "sha256": "a".repeat(64),
            }),
        );
        let upload_app = app.clone();
        let upload_request =
            tokio::spawn(async move { upload_app.oneshot(request).await.unwrap() });
        tokio::time::timeout(std::time::Duration::from_secs(5), gate.wait_until_reached())
            .await
            .expect("init upload route did not reach its test-only preflight pause");

        // Revoke the exact writer device through the existing authenticated
        // handler while the upload principal is paused before begin().
        let revoked = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/devices/{writer_device_id}/revoke"),
                Some(&revoker_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(revoked.status(), StatusCode::OK);
        let revoke_body = response_json(revoked).await;
        assert_eq!(revoke_body["status"], "revoked");

        gate.release();
        let denied_upload = upload_request.await.unwrap();
        assert_eq!(denied_upload.status(), StatusCode::UNAUTHORIZED);
        let denied_body = response_json(denied_upload).await;
        assert_eq!(denied_body["error"]["code"], "AUTH_REQUIRED");
        assert_eq!(upload_write_state(&state, &vault_id).await, baseline);
        let attempted_reservation: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM uploads WHERE vault_id=? AND object_id=?")
                .bind(&vault_id)
                .bind(&attempted_object_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(attempted_reservation, 0);

        drop(app);
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn real_put_chunk_route_rechecks_device_after_owner_preflight_revoke_before_writer_reservation()
     {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        seed_vault_write_counters(&state, &vault_id).await;
        let credentials = seed_revocation_credentials(&state, &user_id).await;
        let payload = b"chunk written after revoke";
        let (upload_id, _) =
            seed_upload_for_route(&state, &user_id, &vault_id, payload, false).await;
        let baseline = upload_write_state(&state, &vault_id).await;

        let gate = Arc::new(crate::recovery::TestPause::new());
        let _release_on_drop = crate::recovery::ReleasePauseOnDrop::new(gate.clone());
        let app = upload_revocation_test_router(state.clone(), None, Some(gate.clone()), None);
        let request = bytes_put_request(
            &format!("/api/v1/uploads/{upload_id}/chunks/0"),
            &credentials.writer_token,
            payload,
        );
        let upload_app = app.clone();
        let upload_request =
            tokio::spawn(async move { upload_app.oneshot(request).await.unwrap() });
        tokio::time::timeout(std::time::Duration::from_secs(5), gate.wait_until_reached())
            .await
            .expect("put_chunk route did not reach its owner-preflight pause");

        let revoked = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/devices/{}/revoke", credentials.writer_device_id),
                Some(&credentials.revoker_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(revoked.status(), StatusCode::OK);
        assert_eq!(response_json(revoked).await["status"], "revoked");

        gate.release();
        let denied_upload = upload_request.await.unwrap();
        assert_eq!(denied_upload.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(
            response_json(denied_upload).await["error"]["code"],
            "AUTH_REQUIRED"
        );
        assert_eq!(upload_write_state(&state, &vault_id).await, baseline);

        drop(app);
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn real_complete_upload_route_rechecks_device_after_owner_preflight_revoke_before_writer_reservation()
     {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        seed_vault_write_counters(&state, &vault_id).await;
        let credentials = seed_revocation_credentials(&state, &user_id).await;
        let payload = b"complete only while authorized";
        let (upload_id, object_id) =
            seed_upload_for_route(&state, &user_id, &vault_id, payload, true).await;
        let baseline = upload_write_state(&state, &vault_id).await;

        let gate = Arc::new(crate::recovery::TestPause::new());
        let _release_on_drop = crate::recovery::ReleasePauseOnDrop::new(gate.clone());
        let app = upload_revocation_test_router(state.clone(), None, None, Some(gate.clone()));
        let request = json_post_request(
            &format!("/api/v1/uploads/{upload_id}/complete"),
            Some(&credentials.writer_token),
            json!({}),
        );
        let upload_app = app.clone();
        let upload_request =
            tokio::spawn(async move { upload_app.oneshot(request).await.unwrap() });
        tokio::time::timeout(std::time::Duration::from_secs(5), gate.wait_until_reached())
            .await
            .expect("complete_upload route did not reach its owner-preflight pause");

        let revoked = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/devices/{}/revoke", credentials.writer_device_id),
                Some(&credentials.revoker_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(revoked.status(), StatusCode::OK);
        assert_eq!(response_json(revoked).await["status"], "revoked");

        gate.release();
        let denied_upload = upload_request.await.unwrap();
        assert_eq!(denied_upload.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(
            response_json(denied_upload).await["error"]["code"],
            "AUTH_REQUIRED"
        );
        assert_eq!(upload_write_state(&state, &vault_id).await, baseline);
        let object_exists: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=?",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(object_exists, 0);

        drop(app);
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn conflicting_second_s3_upload_queues_its_unique_key_for_cleanup() {
        let (mut state, data_dir, user_id, vault_id) = test_state().await;
        let credentials = seed_revocation_credentials(&state, &user_id).await;
        let fixture = crate::object_store::test_support::S3Fixture::start().await;
        let store = fixture.store();
        state.object_store = store.clone();

        let object_id = Uuid::new_v4().to_string();
        let first_upload_id = Uuid::new_v4().to_string();
        let first_bytes = b"first immutable attachment";
        let first_digest = sha256_hex(first_bytes);
        let (first_key, store_id) = store
            .object_key(
                &state.instance.instance_id,
                &vault_id,
                &object_id,
                &first_upload_id,
            )
            .unwrap();
        store
            .put_immutable(
                &first_key,
                first_bytes,
                first_bytes.len() as i64,
                &first_digest,
            )
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,storage_backend,storage_key,storage_store_id,storage_state) \
             VALUES(?,?,X'',?,?,?,'s3',?,?,'available')",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .bind(first_bytes.len() as i64)
        .bind(&first_digest)
        .bind(now_rfc3339())
        .bind(&first_key)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();

        let second_upload_id = Uuid::new_v4().to_string();
        let second_bytes = b"different second upload";
        let second_digest = sha256_hex(second_bytes);
        let (second_key, second_store_id) = store
            .object_key(
                &state.instance.instance_id,
                &vault_id,
                &object_id,
                &second_upload_id,
            )
            .unwrap();
        assert_eq!(second_store_id, store_id);
        let now = now_rfc3339();
        sqlx::query(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at,storage_backend,storage_store_id) \
             VALUES(?,?,?,?,?,?,?,'completing',?,?,'s3',?)",
        )
        .bind(&second_upload_id)
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&object_id)
        .bind(second_bytes.len() as i64)
        .bind(&second_digest)
        .bind(CHUNK_SIZE)
        .bind((chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339())
        .bind(&now)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,?,?)",
        )
        .bind(&second_upload_id)
        .bind(&second_bytes[..])
        .bind(&second_digest)
        .execute(&state.db)
        .await
        .unwrap();

        let app = upload_revocation_test_router(state.clone(), None, None, None);
        let response = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/uploads/{second_upload_id}/complete"),
                Some(&credentials.writer_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(
            response_json(response).await["error"]["code"],
            "OBJECT_EXISTS"
        );
        let second_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&second_upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(second_state, "expired");
        let queued: (String, i64) = sqlx::query_as(
            "SELECT storage_key,expected_size FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&second_key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(queued, (second_key.clone(), second_bytes.len() as i64));

        state
            .object_store
            .drain_delete_queue(&state.db, chrono::Utc::now().timestamp(), 10)
            .await
            .unwrap();
        let first_object_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM blob_objects WHERE vault_id=? AND object_id=? AND storage_key=?",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .bind(&first_key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(first_object_count, 1);
        let queue_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM object_delete_queue WHERE storage_key=?")
                .bind(&second_key)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(queue_count, 0);
        drop(app);
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn maintenance_atomically_retires_expired_s3_completion_before_delayed_delete() {
        let (mut state, data_dir, user_id, vault_id) = test_state().await;
        let fixture = crate::object_store::test_support::S3Fixture::start().await;
        let store = fixture.store();
        state.object_store = store.clone();

        let bytes = b"expired external upload completion";
        let digest = sha256_hex(bytes);
        let upload_id = Uuid::new_v4().to_string();
        let object_id = Uuid::new_v4().to_string();
        let (key, store_id) = store
            .object_key(
                &state.instance.instance_id,
                &vault_id,
                &object_id,
                &upload_id,
            )
            .unwrap();
        store
            .put_immutable(&key, bytes, bytes.len() as i64, &digest)
            .await
            .unwrap();

        let old = "2000-01-01T00:00:00+00:00";
        sqlx::query(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at,storage_backend,storage_store_id) \
             VALUES(?,?,?,?,?,?,?,'completing',?,?,'s3',?)",
        )
        .bind(&upload_id)
        .bind(&vault_id)
        .bind(&user_id)
        .bind(&object_id)
        .bind(bytes.len() as i64)
        .bind(&digest)
        .bind(CHUNK_SIZE)
        .bind(old)
        .bind(old)
        .bind(&store_id)
        .execute(&state.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,?,?)",
        )
        .bind(&upload_id)
        .bind(&bytes[..])
        .bind(&digest)
        .execute(&state.db)
        .await
        .unwrap();

        // Force the chunk cleanup statement to fail after the queue intent and
        // upload state update have run. All three writes must roll back as one
        // payload cleanup transaction.
        sqlx::query(&format!(
            "CREATE TRIGGER fail_expired_upload_chunk_cleanup BEFORE DELETE ON upload_chunks \
             WHEN OLD.upload_id='{upload_id}' BEGIN SELECT RAISE(ABORT,'test cleanup failure'); END"
        ))
        .execute(&state.db)
        .await
        .unwrap();
        let failed = crate::sync::compact_expired_history(&state).await;
        assert!(
            failed.is_err(),
            "injected cleanup failure should abort maintenance"
        );

        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let chunk_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let queue_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(upload_state, "completing");
        assert_eq!(chunk_count, 1);
        assert_eq!(queue_count, 0);
        assert_eq!(
            store
                .read_object(&key, bytes.len() as i64, &digest, None)
                .await
                .unwrap(),
            bytes
        );

        sqlx::query("DROP TRIGGER fail_expired_upload_chunk_cleanup")
            .execute(&state.db)
            .await
            .unwrap();
        let started_at = chrono::Utc::now().timestamp();
        crate::sync::compact_expired_history(&state).await.unwrap();
        let finished_at = chrono::Utc::now().timestamp();

        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let chunk_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        let queued: (String, String, i64) = sqlx::query_as(
            "SELECT state,storage_key,next_attempt_at FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(upload_state, "expired");
        assert_eq!(chunk_count, 0);
        assert_eq!(queued.0, "pending");
        assert_eq!(queued.1, key);
        assert!(queued.2 >= started_at.saturating_add(90_000));
        assert!(queued.2 <= finished_at.saturating_add(90_000));

        // Maintenance drains due work after commit. The delayed intent is not
        // due yet, and an explicit pre-deadline drain must leave it untouched.
        for drain_at in [finished_at, queued.2.saturating_sub(1)] {
            store
                .drain_delete_queue(&state.db, drain_at, 100)
                .await
                .unwrap();
            assert_eq!(
                store
                    .read_object(&key, bytes.len() as i64, &digest, None)
                    .await
                    .unwrap(),
                bytes
            );
        }
        let queue_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(queue_count, 1);

        store
            .drain_delete_queue(&state.db, queued.2, 100)
            .await
            .unwrap();
        assert!(
            store
                .read_object(&key, bytes.len() as i64, &digest, None)
                .await
                .is_err()
        );
        let queue_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=? AND storage_key=?",
        )
        .bind(&store_id)
        .bind(&key)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(queue_count, 0);

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    fn upload_revocation_test_router(
        state: crate::AppState,
        init_gate: Option<Arc<crate::recovery::TestPause>>,
        chunk_gate: Option<Arc<crate::recovery::TestPause>>,
        complete_gate: Option<Arc<crate::recovery::TestPause>>,
    ) -> Router {
        Router::new()
            .route(
                "/api/v1/vaults/{vault_id}/uploads/init",
                post(
                    move |State(state): State<crate::AppState>,
                          headers: HeaderMap,
                          Path(vault): Path<String>,
                          Json(request): Json<InitRequest>| {
                        let gate = init_gate.clone();
                        async move {
                            init_upload_inner(state, headers, vault, request, gate).await
                        }
                    },
                ),
            )
            .route(
                "/api/v1/uploads/{upload_id}/chunks/{index}",
                put(
                    move |State(state): State<crate::AppState>,
                          headers: HeaderMap,
                          Path((upload, index)): Path<(String, i64)>,
                          body: Bytes| {
                        let gate = chunk_gate.clone();
                        async move {
                            put_chunk_inner(state, headers, upload, index, body, gate).await
                        }
                    },
                ),
            )
            .route(
                "/api/v1/uploads/{upload_id}/complete",
                post(
                    move |State(state): State<crate::AppState>,
                          headers: HeaderMap,
                          Path(upload): Path<String>| {
                        let gate = complete_gate.clone();
                        async move { complete_upload_inner(state, headers, upload, gate).await }
                    },
                ),
            )
            .route(
                "/api/v1/vaults/{vault_id}/objects/{object_id}",
                axum::routing::get(super::get_object),
            )
            .route(
                "/api/v1/devices/{id}/revoke",
                post(crate::auth::revoke_device),
            )
            .with_state(state)
    }

    fn json_post_request(
        uri: &str,
        bearer: Option<&str>,
        body: serde_json::Value,
    ) -> Request<Body> {
        let mut builder = Request::builder()
            .method("POST")
            .uri(uri)
            .header(CONTENT_TYPE, "application/json");
        if let Some(token) = bearer {
            builder = builder.header(AUTHORIZATION, format!("Bearer {token}"));
        }
        builder
            .body(Body::from(serde_json::to_vec(&body).unwrap()))
            .unwrap()
    }

    fn bytes_put_request(uri: &str, bearer: &str, bytes: &[u8]) -> Request<Body> {
        Request::builder()
            .method("PUT")
            .uri(uri)
            .header(AUTHORIZATION, format!("Bearer {bearer}"))
            .body(Body::from(bytes.to_vec()))
            .unwrap()
    }

    fn get_request(uri: &str, bearer: &str) -> Request<Body> {
        Request::builder()
            .method("GET")
            .uri(uri)
            .header(AUTHORIZATION, format!("Bearer {bearer}"))
            .body(Body::empty())
            .unwrap()
    }

    fn redaction_capable_get_request(uri: &str, bearer: &str) -> Request<Body> {
        Request::builder()
            .method("GET")
            .uri(uri)
            .header(AUTHORIZATION, format!("Bearer {bearer}"))
            .header("X-Atermius-Redaction-Marker", "v1")
            .body(Body::empty())
            .unwrap()
    }

    async fn response_json(response: axum::response::Response) -> serde_json::Value {
        let bytes = http_body_util::BodyExt::collect(response.into_body())
            .await
            .unwrap()
            .to_bytes();
        serde_json::from_slice(&bytes).unwrap()
    }

    #[tokio::test]
    async fn redacted_vault_rejects_legacy_object_and_upload_routes_before_payload_mutation() {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        seed_vault_write_counters(&state, &vault_id).await;
        let credentials = seed_revocation_credentials(&state, &user_id).await;
        let record_id = Uuid::new_v4().to_string();
        let deleted_revision = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,?,?,2)")
            .bind(&vault_id)
            .bind(&record_id)
            .bind(&deleted_revision)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?,?,?,2,11,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(record_id)
            .bind(deleted_revision)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        let payload = b"legacy client cannot upload";
        let (upload_id, _) =
            seed_upload_for_route(&state, &user_id, &vault_id, payload, false).await;
        let object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&object_id)
            .bind(&b"ciphertext"[..])
            .bind(10_i64)
            .bind(sha256_hex(b"ciphertext"))
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let linked_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&linked_object_id)
            .bind(&b"linked-ciphertext"[..])
            .bind(17_i64)
            .bind(sha256_hex(b"linked-ciphertext"))
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(Uuid::new_v4().to_string())
            .bind(&linked_object_id)
            .execute(&state.db)
            .await
            .unwrap();

        // The client verifies an OBJECT_EXISTS retry after an upload completed
        // but before its signed record write linked the object. Permit only the
        // authenticated uploader, and only while the reservation and blob are
        // still available.
        let retry_object_id = Uuid::new_v4().to_string();
        let retry_expires = (chrono::Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&retry_object_id)
            .bind(&b"retry-ciphertext"[..])
            .bind(15_i64)
            .bind(sha256_hex(b"retry-ciphertext"))
            .bind(now_rfc3339())
            .bind(chrono::Utc::now().timestamp() + 3600)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,15,?,1048576,'completed',?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&retry_object_id)
            .bind(sha256_hex(b"retry-ciphertext"))
            .bind(&retry_expires)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        let collected_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&collected_object_id)
            .bind(&b"collected-ciphertext"[..])
            .bind(19_i64)
            .bind(sha256_hex(b"collected-ciphertext"))
            .bind(now_rfc3339())
            .bind(chrono::Utc::now().timestamp() + 3600)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,19,?,1048576,'collected',?,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&collected_object_id)
            .bind(sha256_hex(b"collected-ciphertext"))
            .bind(&retry_expires)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        let expired_object_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,?,?,?,?,?)")
            .bind(&vault_id)
            .bind(&expired_object_id)
            .bind(&b"expired-ciphertext"[..])
            .bind(18_i64)
            .bind(sha256_hex(b"expired-ciphertext"))
            .bind(now_rfc3339())
            .bind(chrono::Utc::now().timestamp() + 3600)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES(?,?,?,?,18,?,1048576,'completed','2000-01-01T00:00:00+00:00',?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&vault_id)
            .bind(&user_id)
            .bind(&expired_object_id)
            .bind(sha256_hex(b"expired-ciphertext"))
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();

        let foreign_user_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&foreign_user_id)
            .bind(format!("{foreign_user_id}@example.test"))
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
            .bind(&vault_id)
            .bind(&foreign_user_id)
            .bind(now_rfc3339())
            .execute(&state.db)
            .await
            .unwrap();
        let foreign_credentials = seed_revocation_credentials(&state, &foreign_user_id).await;

        let app = upload_revocation_test_router(state.clone(), None, None, None);
        let init_response = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/vaults/{vault_id}/uploads/init"),
                Some(&credentials.writer_token),
                json!({
                    "object_id": Uuid::new_v4().to_string(),
                    "size": payload.len(),
                    "sha256": sha256_hex(payload),
                }),
            ))
            .await
            .unwrap();
        assert_eq!(init_response.status(), StatusCode::UPGRADE_REQUIRED);
        assert_eq!(
            response_json(init_response).await["error"]["code"],
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        let chunk_response = app
            .clone()
            .oneshot(bytes_put_request(
                &format!("/api/v1/uploads/{upload_id}/chunks/0"),
                &credentials.writer_token,
                payload,
            ))
            .await
            .unwrap();
        assert_eq!(chunk_response.status(), StatusCode::UPGRADE_REQUIRED);
        assert_eq!(
            response_json(chunk_response).await["error"]["code"],
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );
        let chunk_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(chunk_count, 0);

        let complete_response = app
            .clone()
            .oneshot(json_post_request(
                &format!("/api/v1/uploads/{upload_id}/complete"),
                Some(&credentials.writer_token),
                json!({}),
            ))
            .await
            .unwrap();
        assert_eq!(complete_response.status(), StatusCode::UPGRADE_REQUIRED);
        assert_eq!(
            response_json(complete_response).await["error"]["code"],
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );
        let upload_state: String =
            sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
                .bind(&upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(upload_state, "open");

        let object_response = app
            .clone()
            .oneshot(get_request(
                &format!("/api/v1/vaults/{vault_id}/objects/{object_id}"),
                &credentials.writer_token,
            ))
            .await
            .unwrap();
        assert_eq!(object_response.status(), StatusCode::UPGRADE_REQUIRED);
        assert_eq!(
            response_json(object_response).await["error"]["code"],
            "CLIENT_REDACTION_CAPABILITY_REQUIRED"
        );

        let linked_response = app
            .clone()
            .oneshot(redaction_capable_get_request(
                &format!("/api/v1/vaults/{vault_id}/objects/{linked_object_id}"),
                &credentials.writer_token,
            ))
            .await
            .unwrap();
        assert_eq!(linked_response.status(), StatusCode::OK);

        let owner_retry_response = app
            .clone()
            .oneshot(redaction_capable_get_request(
                &format!("/api/v1/vaults/{vault_id}/objects/{retry_object_id}"),
                &credentials.writer_token,
            ))
            .await
            .unwrap();
        assert_eq!(owner_retry_response.status(), StatusCode::OK);

        let foreign_retry_response = app
            .clone()
            .oneshot(redaction_capable_get_request(
                &format!("/api/v1/vaults/{vault_id}/objects/{retry_object_id}"),
                &foreign_credentials.writer_token,
            ))
            .await
            .unwrap();
        assert_eq!(foreign_retry_response.status(), StatusCode::NOT_FOUND);

        for object_id in [&object_id, &collected_object_id, &expired_object_id] {
            let inaccessible = app
                .clone()
                .oneshot(redaction_capable_get_request(
                    &format!("/api/v1/vaults/{vault_id}/objects/{object_id}"),
                    &credentials.writer_token,
                ))
                .await
                .unwrap();
            assert_eq!(
                inaccessible.status(),
                StatusCode::NOT_FOUND,
                "an unreferenced object without a usable owner retry grant must be hidden"
            );
        }

        drop(app);
        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    async fn upload_write_state(state: &crate::AppState, vault_id: &str) -> serde_json::Value {
        macro_rules! ordered_rows {
            ($query:literal) => {{
                sqlx::query_scalar::<_, String>($query)
                    .bind(vault_id)
                    .fetch_all(&state.db)
                    .await
                    .unwrap()
                    .into_iter()
                    .map(|row| serde_json::from_str::<serde_json::Value>(&row).unwrap())
                    .collect::<Vec<_>>()
            }};
        }
        let counters = sqlx::query(
            "SELECT vc.last_committed_seq,vc.last_conflict_seq,vc.minimum_available_seq,v.active_epoch,v.membership_version,v.quota_bytes FROM vault_counters vc JOIN vaults v ON v.vault_id=vc.vault_id WHERE vc.vault_id=?",
        )
        .bind(vault_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        let upload_rows = ordered_rows!(
            "SELECT json_array(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) FROM uploads WHERE vault_id=? ORDER BY upload_id"
        );
        let chunk_rows = ordered_rows!(
            "SELECT json_array(u.vault_id,c.upload_id,c.chunk_index,hex(c.bytes),c.sha256) FROM upload_chunks c JOIN uploads u ON u.upload_id=c.upload_id WHERE u.vault_id=? ORDER BY c.upload_id,c.chunk_index"
        );
        let blob_rows = ordered_rows!(
            "SELECT json_array(vault_id,object_id,hex(bytes),size,sha256,created_at,gc_after) FROM blob_objects WHERE vault_id=? ORDER BY object_id"
        );
        let reference_rows = ordered_rows!(
            "SELECT json_array(vault_id,revision_id,object_id) FROM object_references WHERE vault_id=? ORDER BY revision_id,object_id"
        );
        json!({
            "uploads": upload_rows,
            "upload_chunks": chunk_rows,
            "blob_objects": blob_rows,
            "object_references": reference_rows,
            "last_committed_seq": counters.get::<i64, _>("last_committed_seq"),
            "last_conflict_seq": counters.get::<i64, _>("last_conflict_seq"),
            "minimum_available_seq": counters.get::<i64, _>("minimum_available_seq"),
            "active_epoch": counters.get::<i64, _>("active_epoch"),
            "membership_version": counters.get::<i64, _>("membership_version"),
            "quota_bytes": counters.get::<i64, _>("quota_bytes"),
        })
    }

    async fn reserve(
        state: &crate::AppState,
        user_id: &str,
        vault_id: &str,
        object_id: &str,
        size: i64,
        sha256: &str,
    ) -> Result<UploadReservation, ApiError> {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        crate::require_vault_write_tx(&mut tx, user_id, vault_id).await?;
        let result = reserve_upload_tx(
            &mut tx,
            user_id,
            vault_id,
            object_id,
            size,
            sha256,
            &now_rfc3339(),
            state.config.max_object_bytes,
            state.object_store.backend_name(),
            state.object_store.store_id(),
        )
        .await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(result)
    }

    #[tokio::test]
    async fn retry_after_lost_init_response_reuses_reservation_without_double_quota() {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        let object_id = Uuid::new_v4().to_string();
        sqlx::query("UPDATE vaults SET quota_bytes=64 WHERE vault_id=?")
            .bind(&vault_id)
            .execute(&state.db)
            .await
            .unwrap();

        let first = reserve(&state, &user_id, &vault_id, &object_id, 64, &"a".repeat(64))
            .await
            .unwrap();
        // Simulates the response being lost: the client repeats the same init.
        let retry = reserve(&state, &user_id, &vault_id, &object_id, 64, &"a".repeat(64))
            .await
            .unwrap();
        assert_eq!(retry.upload_id, first.upload_id);
        assert_eq!(retry.expires_at, first.expires_at);

        let upload_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM uploads WHERE vault_id=? AND object_id=? AND state='open'",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(upload_count, 1);

        let second_object_id = Uuid::new_v4().to_string();
        let error = reserve(
            &state,
            &user_id,
            &vault_id,
            &second_object_id,
            1,
            &"b".repeat(64),
        )
        .await
        .unwrap_err();
        assert_eq!(error.body.code, "QUOTA_EXCEEDED");

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn active_reservation_rejects_different_metadata_and_other_user_without_extra_rows() {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        let object_id = Uuid::new_v4().to_string();
        let first = reserve(&state, &user_id, &vault_id, &object_id, 10, &"c".repeat(64))
            .await
            .unwrap();
        let error = reserve(&state, &user_id, &vault_id, &object_id, 11, &"d".repeat(64))
            .await
            .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "UPLOAD_RESERVATION_CONFLICT");

        let other_user = Uuid::new_v4().to_string();
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&other_user)
            .bind(format!("{other_user}@example.test"))
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)",
        )
        .bind(&vault_id)
        .bind(&other_user)
        .bind(&now)
        .execute(&state.db)
        .await
        .unwrap();
        let error = reserve(
            &state,
            &other_user,
            &vault_id,
            &object_id,
            10,
            &"c".repeat(64),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "UPLOAD_IN_PROGRESS");

        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM uploads WHERE vault_id=? AND object_id=? AND state='open'",
        )
        .bind(&vault_id)
        .bind(&object_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(count, 1);
        assert_eq!(first.upload_id.len(), 36);

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }

    #[tokio::test]
    async fn expired_reservation_is_not_reused_and_completed_object_cannot_be_reinitialized() {
        let (state, data_dir, user_id, vault_id) = test_state().await;
        let object_id = Uuid::new_v4().to_string();
        let first = reserve(&state, &user_id, &vault_id, &object_id, 3, &"e".repeat(64))
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES(?,0,x'010203','chunk')")
            .bind(&first.upload_id)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE uploads SET expires_at='2000-01-01T00:00:00+00:00' WHERE upload_id=?")
            .bind(&first.upload_id)
            .execute(&state.db)
            .await
            .unwrap();

        let retry = reserve(&state, &user_id, &vault_id, &object_id, 3, &"e".repeat(64))
            .await
            .unwrap();
        assert_ne!(retry.upload_id, first.upload_id);
        let old_state: String = sqlx::query_scalar("SELECT state FROM uploads WHERE upload_id=?")
            .bind(&first.upload_id)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(old_state, "expired");
        let old_chunks: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM upload_chunks WHERE upload_id=?")
                .bind(&first.upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(old_chunks, 0);

        let completed_object_id = Uuid::new_v4().to_string();
        let completed = reserve(
            &state,
            &user_id,
            &vault_id,
            &completed_object_id,
            3,
            &"f".repeat(64),
        )
        .await
        .unwrap();
        let now = now_rfc3339();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at,gc_after) VALUES(?,?,x'010203',3,?,?,NULL)")
            .bind(&vault_id)
            .bind(&completed_object_id)
            .bind("f".repeat(64))
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("UPDATE uploads SET state='completed' WHERE upload_id=?")
            .bind(&completed.upload_id)
            .execute(&state.db)
            .await
            .unwrap();

        let error = reserve(
            &state,
            &user_id,
            &vault_id,
            &completed_object_id,
            3,
            &"f".repeat(64),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "OBJECT_EXISTS");
        let completed_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM uploads WHERE upload_id=?")
                .bind(&completed.upload_id)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(completed_count, 1);

        state.db.close().await;
        tokio::fs::remove_dir_all(data_dir).await.unwrap();
    }
}

use crate::{ApiError, AppState, auth, now_rfc3339};
use axum::{
    Json,
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
};
use chrono::Utc;
use hmac::{Hmac, Mac};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::Sha256;
use sqlx::{Row, Sqlite, Transaction};
use std::net::SocketAddr;
use uuid::Uuid;

type HmacSha256 = Hmac<Sha256>;

#[derive(Deserialize)]
pub struct DeleteAccountRequest {
    pub login_verifier: String,
}

#[derive(Deserialize)]
pub struct CancelAccountDeletionRequest {
    pub username: String,
    pub login_verifier: String,
}

fn account_deletion_dto(
    status: &str,
    requested_at: Option<i64>,
    purge_after: Option<i64>,
) -> Value {
    let deleting = status == "deleting";
    json!({
        "status": status,
        "requested_at": unix_epoch_rfc3339(requested_at),
        "purge_after": unix_epoch_rfc3339(purge_after),
        "can_cancel": deleting && purge_after.is_some_and(|deadline| deadline > Utc::now().timestamp()),
    })
}

fn unix_epoch_rfc3339(value: Option<i64>) -> Option<String> {
    value.and_then(|seconds| {
        chrono::DateTime::<Utc>::from_timestamp(seconds, 0)
            .map(|date| date.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    })
}

fn actor_hash(state: &AppState, user_id: &str, device_id: &str) -> Result<String, ApiError> {
    let mut mac =
        HmacSha256::new_from_slice(state.auth_rate_key.as_ref()).map_err(ApiError::internal)?;
    mac.update(b"atermius/account-deletion-audit/v1\0");
    mac.update(user_id.as_bytes());
    mac.update(b"\0");
    mac.update(device_id.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

async fn consume_login_attempt(
    state: &AppState,
    username: &str,
    peer: SocketAddr,
) -> Result<(), ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let limited = crate::rate_limit::consume(
        &state,
        &mut tx,
        crate::rate_limit::AuthOperation::Login,
        username,
        Some(peer.ip()),
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    if let Some(seconds) = limited {
        return Err(ApiError::rate_limited(seconds));
    }
    Ok(())
}

async fn verify_account_delete_step_up(
    state: &AppState,
    user_id: &str,
    verifier: &str,
    peer: SocketAddr,
) -> Result<String, ApiError> {
    let username: Option<String> =
        sqlx::query_scalar("SELECT username FROM users WHERE user_id=? AND status='active'")
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?;
    let username = username.ok_or_else(ApiError::unauthorized)?;
    consume_login_attempt(state, &username, peer).await?;
    match auth::verify_login_verifier_for_user(state, user_id, verifier).await {
        Ok(hash) => Ok(hash),
        Err(error) if error.status == StatusCode::UNAUTHORIZED => Err(ApiError::reauth_required()),
        Err(error) => Err(error),
    }
}

async fn owned_shared_vault_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<Option<String>, ApiError> {
    sqlx::query_scalar(
        "SELECT v.vault_id FROM vaults v JOIN vault_members other ON other.vault_id=v.vault_id AND other.user_id<>v.owner_user_id AND other.state IN ('active','invited') WHERE v.owner_user_id=? LIMIT 1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

pub async fn delete_account(
    State(state): State<AppState>,
    headers: HeaderMap,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<DeleteAccountRequest>,
) -> Result<Json<Value>, ApiError> {
    let user = crate::current_user(&state, &headers).await?;
    if let Some(repository) = state.pg_account_deletion.as_ref() {
        let username = repository.username_for_user(&user.user_id).await?;
        let limited = auth::consume_auth_rate_limit(
            &state,
            crate::rate_limit::AuthOperation::Login,
            &username,
            Some(peer.ip()),
        )
        .await?;
        if let Some(seconds) = limited {
            return Err(ApiError::rate_limited(seconds));
        }
        let verified_hash = repository
            .verify_login_verifier(&user.user_id, &request.login_verifier)
            .await?;
        let response = repository
            .delete_account(
                &user,
                &verified_hash,
                state.config.account_deletion_grace_seconds,
            )
            .await?;
        return Ok(Json(response));
    }
    let verified_hash =
        verify_account_delete_step_up(&state, &user.user_id, &request.login_verifier, peer).await?;
    let account_actor_hash = actor_hash(&state, &user.user_id, &user.device_id)?;
    let now = Utc::now().timestamp();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;

    // Reserve SQLite's sole writer before checking ownership or lifecycle.
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::unauthorized());
    }
    crate::require_active_session_device_tx(&mut tx, &user).await?;
    let account = sqlx::query(
        "SELECT status,(SELECT login_verifier_hash FROM auth_credentials WHERE user_id=users.user_id) AS verifier_hash FROM users WHERE user_id=?",
    )
    .bind(&user.user_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if account.get::<Option<String>, _>("verifier_hash").as_deref() != Some(&verified_hash) {
        return Err(ApiError::reauth_required());
    }
    let status: String = account.get("status");
    if status == "deleting" {
        let pending = sqlx::query_as::<_, (String, i64, i64)>(
            "SELECT request_id,requested_at,purge_after FROM account_deletion_requests WHERE user_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
        )
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some((request_id, requested_at, purge_after)) = pending else {
            return Err(ApiError::internal(
                "deleting account has no pending request",
            ));
        };
        let device_request: Option<String> = sqlx::query_scalar(
            "SELECT account_deletion_request_id FROM devices WHERE device_id=? AND user_id=?",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if device_request.as_deref() != Some(&request_id) {
            return Err(ApiError::unauthorized());
        }
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(account_deletion_dto(
            "deleting",
            Some(requested_at),
            Some(purge_after),
        )));
    }
    if status != "active" {
        return Err(ApiError::unauthorized());
    }
    if owned_shared_vault_tx(&mut tx, &user.user_id)
        .await?
        .is_some()
    {
        return Err(ApiError::conflict(
            "ACCOUNT_OWNS_SHARED_VAULT",
            "remove other members from owned shared vaults before deleting this account",
        ));
    }

    let request_id = Uuid::new_v4().to_string();
    let purge_after = now.saturating_add(state.config.account_deletion_grace_seconds);
    sqlx::query("INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,?,?)")
        .bind(&request_id)
        .bind(&user.user_id)
        .bind(now)
        .bind(purge_after)
        .bind(account_actor_hash)
        .execute(&mut *tx)
        .await
        .map_err(|error| {
            if is_unique_constraint(&error) {
                ApiError::conflict(
                    "ACCOUNT_DELETION_PENDING",
                    "account deletion is already pending",
                )
            } else {
                ApiError::internal(error)
            }
        })?;
    let now_text = now_rfc3339();
    sqlx::query("UPDATE devices SET status='revoked',revoked_at=?,account_deletion_request_id=? WHERE user_id=? AND status='active'")
        .bind(&now_text)
        .bind(&request_id)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("UPDATE sessions SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL")
        .bind(&now_text)
        .bind(&user.user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let updated =
        sqlx::query("UPDATE users SET status='deleting' WHERE user_id=? AND status='active'")
            .bind(&user.user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETION_TRANSITION_CONFLICT",
            "account lifecycle changed; retry the request",
        ));
    }
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user.user_id,
        Some(&user.device_id),
        "account.deletion_requested",
        "account",
        None,
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(account_deletion_dto(
        "deleting",
        Some(now),
        Some(purge_after),
    )))
}

fn is_unique_constraint(error: &sqlx::Error) -> bool {
    matches!(error, sqlx::Error::Database(db_error) if db_error.is_unique_violation())
}

pub async fn cancel_account_deletion(
    State(state): State<AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<CancelAccountDeletionRequest>,
) -> Result<Json<Value>, ApiError> {
    let username = auth::normalized_username(&request.username)?;
    if let Some(repository) = state.pg_account_deletion.as_ref() {
        let limited = auth::consume_auth_rate_limit(
            &state,
            crate::rate_limit::AuthOperation::Login,
            &username,
            Some(peer.ip()),
        )
        .await?;
        if let Some(seconds) = limited {
            return Err(ApiError::rate_limited(seconds));
        }
        let response = repository
            .cancel_account_deletion(&username, &request.login_verifier)
            .await?;
        return Ok(Json(response));
    }
    // The current access session has intentionally been revoked, so cancellation
    // proves the account verifier directly and returns no session.
    consume_login_attempt(&state, &username, peer).await?;
    let row = sqlx::query("SELECT u.user_id,u.status,c.login_verifier_hash FROM users u JOIN auth_credentials c USING(user_id) WHERE u.username=? AND u.status IN ('active','deleting')")
        .bind(&username)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = row else {
        let _ =
            auth::check_password_hash(&request.login_verifier, &state.dummy_login_verifier_hash);
        return Err(ApiError::reauth_required());
    };
    let verifier_hash: String = row.get("login_verifier_hash");
    if let Err(error) = auth::check_password_hash(&request.login_verifier, &verifier_hash) {
        return if error.status == StatusCode::UNAUTHORIZED {
            Err(ApiError::reauth_required())
        } else {
            Err(error)
        };
    }
    let user_id: String = row.get("user_id");
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let locked = sqlx::query("UPDATE users SET status=status WHERE user_id=?")
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::gone(
            "ACCOUNT_DELETION_WINDOW_EXPIRED",
            "account deletion has already completed",
        ));
    }
    let current_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if current_status == "active" {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(Json(account_deletion_dto("active", None, None)));
    }
    if current_status != "deleting" {
        return Err(ApiError::reauth_required());
    }
    let pending = sqlx::query_as::<_, (String, i64)>(
        "SELECT request_id,purge_after FROM account_deletion_requests WHERE user_id=? AND cancelled_at IS NULL AND purged_at IS NULL",
    )
    .bind(&user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("deleting account has no pending request"))?;
    let (request_id, purge_after) = pending;
    let now = Utc::now().timestamp();
    if now >= purge_after {
        return Err(ApiError::gone(
            "ACCOUNT_DELETION_WINDOW_EXPIRED",
            "account deletion can no longer be cancelled",
        ));
    }
    let cancelled = sqlx::query("UPDATE account_deletion_requests SET cancelled_at=?,user_id=NULL WHERE request_id=? AND user_id=? AND cancelled_at IS NULL AND purged_at IS NULL AND purge_after>?")
        .bind(now)
        .bind(&request_id)
        .bind(&user_id)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if cancelled.rows_affected() != 1 {
        return Err(ApiError::gone(
            "ACCOUNT_DELETION_WINDOW_EXPIRED",
            "account deletion can no longer be cancelled",
        ));
    }
    let restored =
        sqlx::query("UPDATE users SET status='active' WHERE user_id=? AND status='deleting'")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if restored.rows_affected() != 1 {
        return Err(ApiError::conflict(
            "ACCOUNT_DELETION_TRANSITION_CONFLICT",
            "account lifecycle changed; retry the request",
        ));
    }
    sqlx::query("UPDATE devices SET status='active',revoked_at=NULL,account_deletion_request_id=NULL WHERE user_id=? AND account_deletion_request_id=? AND status='revoked'")
        .bind(&user_id)
        .bind(&request_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    crate::audit::record_account_event_tx(
        &mut tx,
        &state,
        &user_id,
        None,
        "account.deletion_cancelled",
        "account",
        None,
        crate::audit::AuditSource::Api,
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(account_deletion_dto("active", None, None)))
}

/// Purge due accounts under SQLite writer serialization. Shared ciphertext
/// remains available; only the account's own vaults and private control-plane
/// rows are removed. Referenced public keys are copied into vault-scoped
/// archives before device rows disappear.
pub(crate) async fn purge_due_account_deletions(
    state: &AppState,
    now_epoch: i64,
) -> Result<(), ApiError> {
    let due = sqlx::query_as::<_, (String, String)>(
        "SELECT request_id,user_id FROM account_deletion_requests WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL AND purge_after<=? ORDER BY purge_after,request_id",
    )
    .bind(now_epoch)
    .fetch_all(&state.db)
    .await
    .map_err(ApiError::internal)?;
    for (request_id, candidate_user_id) in due {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        let locked = sqlx::query("UPDATE account_deletion_requests SET request_id=request_id WHERE request_id=? AND user_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
            .bind(&request_id)
            .bind(&candidate_user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if locked.rows_affected() == 0 {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        }
        let current = sqlx::query_as::<_, (String, i64)>(
            "SELECT user_id,purge_after FROM account_deletion_requests WHERE request_id=? AND user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL",
        )
        .bind(&request_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some((user_id, purge_after)) = current else {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        };
        if purge_after > now_epoch {
            tx.commit().await.map_err(ApiError::internal)?;
            continue;
        }
        let user_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM users WHERE user_id=? AND status='deleting')",
        )
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !user_exists {
            return Err(ApiError::internal(
                "pending account deletion references a non-deleting account",
            ));
        }
        if owned_shared_vault_tx(&mut tx, &user_id).await?.is_some() {
            return Err(ApiError::internal(
                "pending account deletion unexpectedly owns a shared vault",
            ));
        }

        crate::audit::record_account_event_tx(
            &mut tx,
            state,
            &user_id,
            None,
            "account.purged",
            "account",
            None,
            crate::audit::AuditSource::Maintenance,
            now_epoch,
        )
        .await?;
        sqlx::query("UPDATE audit_events SET actor_user_id=NULL,actor_device_id=NULL WHERE actor_user_id=? OR actor_device_id IN (SELECT device_id FROM devices WHERE user_id=?)")
            .bind(&user_id)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE audit_events SET resource_id=NULL WHERE resource_type='device' AND resource_id IN (SELECT device_id FROM devices WHERE user_id=?)")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE audit_events SET resource_id=NULL WHERE resource_type='session' AND resource_id IN (SELECT session_id FROM sessions WHERE user_id=?)")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE audit_events SET resource_id=NULL WHERE resource_type='session_family' AND resource_id IN (SELECT family_id FROM sessions WHERE user_id=?)")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE audit_events SET resource_id=NULL WHERE resource_id=? AND resource_type IN ('account','account_recovery','membership')")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        let archived_at = now_rfc3339();
        sqlx::query("INSERT OR IGNORE INTO vault_device_archives(vault_id,user_id,device_id,signing_public_key,encryption_public_key,archived_at) SELECT DISTINCT vm.vault_id,d.user_id,d.device_id,d.signing_public_key,d.encryption_public_key,? FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id JOIN devices d ON d.user_id=vm.user_id WHERE vm.user_id=? AND v.owner_user_id<>? AND (EXISTS(SELECT 1 FROM record_versions rv WHERE rv.vault_id=vm.vault_id AND rv.device_id=d.device_id) OR EXISTS(SELECT 1 FROM conflicts c WHERE c.vault_id=vm.vault_id AND c.device_id=d.device_id) OR EXISTS(SELECT 1 FROM membership_manifests mm WHERE mm.vault_id=vm.vault_id AND mm.signer_device_id=d.device_id) OR EXISTS(SELECT 1 FROM vault_key_envelopes ke WHERE ke.vault_id=vm.vault_id AND (ke.signer_device_id=d.device_id OR ke.recipient_device_id=d.device_id)))")
            .bind(&archived_at)
            .bind(&user_id)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        // owner_user_id, snapshots.requested_by and invitation actor/acceptor
        // FKs are restrictive, so remove those private references first.
        sqlx::query("UPDATE vault_deletion_requests SET purged_at=? WHERE vault_id IN (SELECT vault_id FROM vaults WHERE owner_user_id=?) AND cancelled_at IS NULL AND purged_at IS NULL")
            .bind(now_epoch)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let owned_vaults: Vec<String> =
            sqlx::query_scalar("SELECT vault_id FROM vaults WHERE owner_user_id=?")
                .bind(&user_id)
                .fetch_all(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        for vault_id in owned_vaults {
            state
                .object_store
                .queue_completing_uploads_for_vault_tx(
                    &mut tx,
                    &state.instance.instance_id,
                    &vault_id,
                    now_epoch,
                )
                .await?;
        }
        let external_objects = sqlx::query(
            "SELECT b.storage_backend,b.storage_key,b.storage_store_id,b.size,b.sha256 FROM blob_objects b \
             JOIN vaults v ON v.vault_id=b.vault_id WHERE v.owner_user_id=? AND b.storage_backend IN ('s3','filesystem')",
        )
        .bind(&user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        for object in external_objects {
            let key: String = object.get("storage_key");
            let storage_backend: String = object.get("storage_backend");
            let store_id: String = object.get("storage_store_id");
            let size: i64 = object.get("size");
            let digest: String = object.get("sha256");
            crate::object_store::ObjectStore::queue_external_delete_tx(
                &mut tx,
                &storage_backend,
                &store_id,
                &key,
                size,
                &digest,
                now_epoch,
            )
            .await?;
        }
        sqlx::query("DELETE FROM vaults WHERE owner_user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM snapshots WHERE requested_by=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "DELETE FROM invitations WHERE created_by=? OR accepted_by=? OR recipient_user_id=?",
        )
        .bind(&user_id)
        .bind(&user_id)
        .bind(&user_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM uploads WHERE user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM op_receipts WHERE device_id IN (SELECT device_id FROM devices WHERE user_id=?)")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM batch_receipts WHERE device_id IN (SELECT device_id FROM devices WHERE user_id=?)")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM refresh_history WHERE user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM account_invitations WHERE consumed_user_id=?")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let finalized = sqlx::query("UPDATE account_deletion_requests SET user_id=NULL,purged_at=? WHERE request_id=? AND user_id=? AND cancelled_at IS NULL AND purged_at IS NULL")
            .bind(now_epoch)
            .bind(&request_id)
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if finalized.rows_affected() != 1 {
            return Err(ApiError::internal(
                "account deletion audit transition was not applied",
            ));
        }
        let deleted = sqlx::query("DELETE FROM users WHERE user_id=? AND status='deleting'")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if deleted.rows_affected() != 1 {
            return Err(ApiError::internal(
                "due account deletion did not remove its account",
            ));
        }
        tx.commit().await.map_err(ApiError::internal)?;
    }

    let audit_cutoff = now_epoch.saturating_sub(state.config.audit_retention_days * 86_400);
    sqlx::query("DELETE FROM account_deletion_requests WHERE (cancelled_at IS NOT NULL AND cancelled_at<?) OR (purged_at IS NOT NULL AND purged_at<?)")
        .bind(audit_cutoff)
        .bind(audit_cutoff)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{AuthRateLimits, Config, open_state};
    use axum::http::{HeaderValue, StatusCode, header};
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use sqlx::Row;
    use std::path::PathBuf;

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
            vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
            account_deletion_grace_seconds: 7 * 24 * 60 * 60,
            audit_retention_days: 365,
            object_gc_grace_seconds: 7 * 24 * 60 * 60,
            admin_usernames: Vec::new(),
            auth_rate_limits: AuthRateLimits::default(),
        }
    }

    async fn test_state(label: &str) -> (AppState, PathBuf) {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-account-{label}-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database_url = format!("sqlite://{}/test.db?mode=rwc", data_dir.display());
        let state = open_state(&database_url, test_config(data_dir.clone()))
            .await
            .unwrap();
        (state, data_dir)
    }

    async fn insert_user(
        state: &AppState,
        user_id: &str,
        username: &str,
        status: &str,
        verifier_hash: &str,
        salt: &str,
    ) {
        let now = now_rfc3339();
        sqlx::query("INSERT INTO users(user_id,username,status,created_at) VALUES(?,?,?,?)")
            .bind(user_id)
            .bind(username)
            .bind(status)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO auth_credentials(user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope) VALUES(?,?,?,'{}','{}')")
            .bind(user_id)
            .bind(verifier_hash)
            .bind(salt)
            .execute(&state.db)
            .await
            .unwrap();
    }

    async fn insert_device(state: &AppState, user_id: &str, device_id: &str, status: &str) {
        let now = now_rfc3339();
        let revoked_at = (status == "revoked").then_some(now.as_str());
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status,created_at,revoked_at) VALUES(?,?,?,'signing-pub','encryption-pub',?,?,?)")
            .bind(device_id)
            .bind(user_id)
            .bind(format!("device {device_id}"))
            .bind(status)
            .bind(&now)
            .bind(revoked_at)
            .execute(&state.db)
            .await
            .unwrap();
    }

    fn verifier_and_hash() -> (String, String, String) {
        let verifier = URL_SAFE_NO_PAD.encode([0x37_u8; 32]);
        let (hash, salt) = auth::password_hash(&verifier).unwrap();
        (verifier, hash, salt)
    }

    fn peer() -> SocketAddr {
        "127.0.0.1:30123".parse().unwrap()
    }

    #[test]
    fn account_deletion_dto_reports_pending_and_active_shapes() {
        let requested_at = Utc::now().timestamp();
        let pending = account_deletion_dto(
            "deleting",
            Some(requested_at),
            Some(requested_at + 7 * 24 * 60 * 60),
        );
        assert_eq!(pending["status"], "deleting");
        assert_eq!(pending["can_cancel"], true);
        let active = account_deletion_dto("active", None, None);
        assert_eq!(active["requested_at"], Value::Null);
        assert_eq!(active["purge_after"], Value::Null);
        assert_eq!(active["can_cancel"], false);
    }

    #[tokio::test]
    async fn delete_account_blocks_a_sole_owner_of_a_shared_vault() {
        let (state, _dir) = test_state("owner-block").await;
        let (verifier, hash, salt) = verifier_and_hash();
        let owner = Uuid::new_v4().to_string();
        let member = Uuid::new_v4().to_string();
        let vault = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        insert_user(&state, &owner, "owner@example.test", "active", &hash, &salt).await;
        insert_user(
            &state,
            &member,
            "member@example.test",
            "active",
            &hash,
            &salt,
        )
        .await;
        insert_device(&state, &owner, &device, "active").await;
        let now = now_rfc3339();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault)
            .bind(&owner)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?),(?,?,'editor','active',?)")
            .bind(&vault).bind(&owner).bind(&now)
            .bind(&vault).bind(&member).bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let token = "a-valid-access-token-for-owner-0000000000000000";
        let expires = (Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES('owner-session',?,?, 'family',?,?,?,? ,?)")
            .bind(&owner)
            .bind(&device)
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind("refresh-hash-owner")
            .bind(&expires)
            .bind(&expires)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let error = delete_account(
            State(state.clone()),
            headers,
            ConnectInfo(peer()),
            Json(DeleteAccountRequest {
                login_verifier: verifier,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::CONFLICT);
        assert_eq!(error.body.code, "ACCOUNT_OWNS_SHARED_VAULT");
        let status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&owner)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(status, "active");
        let requests: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM account_deletion_requests WHERE user_id=?")
                .bind(&owner)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(requests, 0);
    }

    #[tokio::test]
    async fn deletion_revokes_every_session_and_only_active_devices() {
        let (state, _dir) = test_state("revoke-now").await;
        let (verifier, hash, salt) = verifier_and_hash();
        let user = Uuid::new_v4().to_string();
        let active_device = Uuid::new_v4().to_string();
        let prior_revoked_device = Uuid::new_v4().to_string();
        insert_user(&state, &user, "delete@example.test", "active", &hash, &salt).await;
        insert_device(&state, &user, &active_device, "active").await;
        insert_device(&state, &user, &prior_revoked_device, "revoked").await;
        let token = "active-account-session-token-0000000000000000";
        let now = now_rfc3339();
        let expires = (Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES('deleting-session',?,?, 'family',?,?,?,? ,?)")
            .bind(&user)
            .bind(&active_device)
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind("refresh-hash-delete")
            .bind(&expires)
            .bind(&expires)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let response = delete_account(
            State(state.clone()),
            headers.clone(),
            ConnectInfo(peer()),
            Json(DeleteAccountRequest {
                login_verifier: verifier,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(response["status"], "deleting");
        assert_eq!(response["can_cancel"], true);
        let account_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(account_status, "deleting");
        let active: (String, Option<String>) = sqlx::query_as(
            "SELECT status,account_deletion_request_id FROM devices WHERE device_id=?",
        )
        .bind(&active_device)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(active.0, "revoked");
        assert!(active.1.is_some());
        let prior_status: (String, Option<String>) = sqlx::query_as(
            "SELECT status,account_deletion_request_id FROM devices WHERE device_id=?",
        )
        .bind(&prior_revoked_device)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(prior_status.0, "revoked");
        assert_eq!(prior_status.1, None);
        let revoked_at: Option<String> = sqlx::query_scalar(
            "SELECT revoked_at FROM sessions WHERE session_id='deleting-session'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert!(revoked_at.is_some());
        let error = auth::authenticate(&state, &headers).await.unwrap_err();
        assert_eq!(error.status, StatusCode::UNAUTHORIZED);
        assert_eq!(error.body.code, "AUTH_REQUIRED");
    }

    #[tokio::test]
    async fn delete_account_audit_failure_rolls_back_schedule_and_revocations() {
        let (state, _dir) = test_state("delete-audit-rollback").await;
        let (verifier, hash, salt) = verifier_and_hash();
        let user = Uuid::new_v4().to_string();
        let active_device = Uuid::new_v4().to_string();
        let prior_revoked_device = Uuid::new_v4().to_string();
        insert_user(
            &state,
            &user,
            "rollback@example.test",
            "active",
            &hash,
            &salt,
        )
        .await;
        insert_device(&state, &user, &active_device, "active").await;
        insert_device(&state, &user, &prior_revoked_device, "revoked").await;
        let prior_device_revoked_at: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM devices WHERE device_id=?")
                .bind(&prior_revoked_device)
                .fetch_one(&state.db)
                .await
                .unwrap();

        let token = "active-delete-rollback-session-token-000000000000";
        let now = now_rfc3339();
        let expires = (Utc::now() + chrono::Duration::hours(1)).to_rfc3339();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES('rollback-active-session',?,?, 'active-family',?,?,?,? ,?)")
            .bind(&user)
            .bind(&active_device)
            .bind(crate::sha256_hex(token.as_bytes()))
            .bind("refresh-hash-active")
            .bind(&expires)
            .bind(&expires)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,revoked_at,created_at) VALUES('rollback-prior-session',?,?, 'old-family','old-access','old-refresh',?,?,?,?)")
            .bind(&user)
            .bind(&prior_revoked_device)
            .bind(&expires)
            .bind(&expires)
            .bind(&now)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();

        sqlx::query("CREATE TRIGGER reject_account_deletion_audit BEFORE INSERT ON audit_events WHEN NEW.action='account.deletion_requested' BEGIN SELECT RAISE(ABORT,'injected audit failure'); END")
            .execute(&state.db)
            .await
            .unwrap();

        let mut headers = HeaderMap::new();
        headers.insert(
            header::AUTHORIZATION,
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let error = delete_account(
            State(state.clone()),
            headers.clone(),
            ConnectInfo(peer()),
            Json(DeleteAccountRequest {
                login_verifier: verifier.clone(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::INTERNAL_SERVER_ERROR);

        let user_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(user_status, "active");
        let request_count: i64 =
            sqlx::query_scalar("SELECT COUNT(*) FROM account_deletion_requests WHERE user_id=?")
                .bind(&user)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(request_count, 0);

        let active_device_state: (String, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT status,revoked_at,account_deletion_request_id FROM devices WHERE device_id=?",
        )
        .bind(&active_device)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(active_device_state, ("active".into(), None, None));
        let prior_device_state: (String, Option<String>, Option<String>) = sqlx::query_as(
            "SELECT status,revoked_at,account_deletion_request_id FROM devices WHERE device_id=?",
        )
        .bind(&prior_revoked_device)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(
            prior_device_state,
            ("revoked".into(), prior_device_revoked_at, None)
        );

        let active_session_revoked_at: Option<String> = sqlx::query_scalar(
            "SELECT revoked_at FROM sessions WHERE session_id='rollback-active-session'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(active_session_revoked_at, None);
        let prior_session_revoked_at: Option<String> = sqlx::query_scalar(
            "SELECT revoked_at FROM sessions WHERE session_id='rollback-prior-session'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(prior_session_revoked_at.as_deref(), Some(now.as_str()));
        let audit_count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE action='account.deletion_requested'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit_count, 0);
        // The step-up rate-limit bucket is committed before the lifecycle transaction.

        sqlx::query("DROP TRIGGER reject_account_deletion_audit")
            .execute(&state.db)
            .await
            .unwrap();
        let retried = delete_account(
            State(state.clone()),
            headers,
            ConnectInfo(peer()),
            Json(DeleteAccountRequest {
                login_verifier: verifier,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(retried["status"], "deleting");
    }

    #[tokio::test]
    async fn sessionless_cancel_restores_only_marked_devices_and_keeps_sessions_revoked() {
        let (state, _dir) = test_state("cancel").await;
        let (verifier, hash, salt) = verifier_and_hash();
        let user = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let held = Uuid::new_v4().to_string();
        let old_revoked = Uuid::new_v4().to_string();
        insert_user(
            &state,
            &user,
            "cancel@example.test",
            "deleting",
            &hash,
            &salt,
        )
        .await;
        insert_device(&state, &user, &held, "revoked").await;
        insert_device(&state, &user, &old_revoked, "revoked").await;
        let now = now_rfc3339();
        sqlx::query("UPDATE devices SET account_deletion_request_id=? WHERE device_id=?")
            .bind(&request_id)
            .bind(&held)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,revoked_at,created_at) VALUES('cancel-session',?,?, 'family','access','refresh',?,?,?,?)")
            .bind(&user)
            .bind(&held)
            .bind(&now)
            .bind(&now)
            .bind(&now)
            .bind(&now)
            .execute(&state.db)
            .await
            .unwrap();
        let requested_at = Utc::now().timestamp();
        sqlx::query("INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,?,?)")
            .bind(&request_id)
            .bind(&user)
            .bind(requested_at)
            .bind(requested_at + 3600)
            .bind("opaque-hmac")
            .execute(&state.db)
            .await
            .unwrap();
        let response = cancel_account_deletion(
            State(state.clone()),
            ConnectInfo(peer()),
            Json(CancelAccountDeletionRequest {
                username: " CANCEL@example.test ".into(),
                login_verifier: verifier.clone(),
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(response["status"], "active");
        let user_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(user_status, "active");
        let device_rows = sqlx::query("SELECT device_id,status,account_deletion_request_id FROM devices WHERE user_id=? ORDER BY device_id")
            .bind(&user)
            .fetch_all(&state.db)
            .await
            .unwrap();
        for row in device_rows {
            if row.get::<String, _>("device_id") == held {
                assert_eq!(row.get::<String, _>("status"), "active");
            } else {
                assert_eq!(row.get::<String, _>("status"), "revoked");
            }
            assert_eq!(
                row.get::<Option<String>, _>("account_deletion_request_id"),
                None
            );
        }
        let session_revoked: Option<String> =
            sqlx::query_scalar("SELECT revoked_at FROM sessions WHERE session_id='cancel-session'")
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert!(session_revoked.is_some());
        let audit = sqlx::query(
            "SELECT user_id,cancelled_at,actor_hash FROM account_deletion_requests WHERE request_id=?",
        )
        .bind(&request_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit.get::<Option<String>, _>("user_id"), None);
        assert!(audit.get::<Option<i64>, _>("cancelled_at").is_some());
        assert_eq!(audit.get::<String, _>("actor_hash"), "opaque-hmac");
        // A repeated cancellation remains a safe no-op success.
        let repeated = cancel_account_deletion(
            State(state.clone()),
            ConnectInfo(peer()),
            Json(CancelAccountDeletionRequest {
                username: "cancel@example.test".into(),
                login_verifier: verifier,
            }),
        )
        .await
        .unwrap()
        .0;
        assert_eq!(repeated["status"], "active");
    }

    #[tokio::test]
    async fn expired_account_cancel_is_rejected_without_restoring_state() {
        let (state, _dir) = test_state("cancel-expired").await;
        let (verifier, hash, salt) = verifier_and_hash();
        let user = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        insert_user(
            &state,
            &user,
            "expired@example.test",
            "deleting",
            &hash,
            &salt,
        )
        .await;
        insert_device(&state, &user, &device, "revoked").await;
        sqlx::query("UPDATE devices SET account_deletion_request_id=? WHERE device_id=?")
            .bind(&request_id)
            .bind(&device)
            .execute(&state.db)
            .await
            .unwrap();
        let now = Utc::now().timestamp();
        sqlx::query("INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,?,'hash')")
            .bind(&request_id)
            .bind(&user)
            .bind(now - 7200)
            .bind(now - 1)
            .execute(&state.db)
            .await
            .unwrap();
        let error = cancel_account_deletion(
            State(state.clone()),
            ConnectInfo(peer()),
            Json(CancelAccountDeletionRequest {
                username: "expired@example.test".into(),
                login_verifier: verifier,
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(error.status, StatusCode::GONE);
        assert_eq!(error.body.code, "ACCOUNT_DELETION_WINDOW_EXPIRED");
        let user_status: String = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
            .bind(&user)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(user_status, "deleting");
        let device_status: String =
            sqlx::query_scalar("SELECT status FROM devices WHERE device_id=?")
                .bind(&device)
                .fetch_one(&state.db)
                .await
                .unwrap();
        assert_eq!(device_status, "revoked");
    }

    #[tokio::test]
    async fn purge_deletes_private_rows_but_preserves_shared_history_and_verification_keys() {
        let (state, _dir) = test_state("purge-shared").await;
        let (_verifier, hash, salt) = verifier_and_hash();
        let deleting = Uuid::new_v4().to_string();
        let other = Uuid::new_v4().to_string();
        let personal = Uuid::new_v4().to_string();
        let shared = Uuid::new_v4().to_string();
        let device = Uuid::new_v4().to_string();
        let other_device = Uuid::new_v4().to_string();
        let request_id = Uuid::new_v4().to_string();
        let now_text = now_rfc3339();
        insert_user(
            &state,
            &deleting,
            "purged@example.test",
            "deleting",
            &hash,
            &salt,
        )
        .await;
        insert_user(&state, &other, "other@example.test", "active", &hash, &salt).await;
        insert_device(&state, &deleting, &device, "revoked").await;
        insert_device(&state, &other, &other_device, "active").await;
        for (vault, owner) in [(&personal, &deleting), (&shared, &other)] {
            sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
                .bind(vault)
                .bind(owner)
                .bind(&now_text)
                .execute(&state.db)
                .await
                .unwrap();
            sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES(?,0,0)")
                .bind(vault)
                .execute(&state.db)
                .await
                .unwrap();
        }
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'owner','active',?),(?,?,'owner','active',?),(?,?,'editor','active',?)")
            .bind(&personal).bind(&deleting).bind(&now_text)
            .bind(&shared).bind(&other).bind(&now_text)
            .bind(&shared).bind(&deleting).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,bytes,size,sha256,created_at) VALUES(?,?,'personal',8,'hash',?),(?,?,'shared',6,'hash',?)")
            .bind(&personal).bind("personal-object").bind(&now_text)
            .bind(&shared).bind("shared-object").bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES(?, 'personal-record','personal-rev','private-cipher','hash',1,?,'create',?),(?, 'shared-record','shared-rev','shared-cipher','hash',1,?,'create',?)")
            .bind(&personal).bind(&device).bind(&now_text)
            .bind(&shared).bind(&device).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES(?,'personal-record','personal-deleted-rev',2)")
            .bind(&personal)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq,created_at) VALUES(?,?, 'personal-record','personal-deleted-rev',2,3,?)")
            .bind(Uuid::new_v4().to_string())
            .bind(&personal)
            .bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO membership_manifests(vault_id,membership_version,manifest_json,digest,signer_device_id,signature,created_at) VALUES(?,1,'{}','hash',?,'sig',?)")
            .bind(&shared)
            .bind(&device)
            .bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,manifest_json,expires_at,created_at) VALUES(?,?,?,0,'{}',?,?),(?,?,?,0,'{}',?,?)")
            .bind(Uuid::new_v4().to_string()).bind(&personal).bind(&deleting).bind(&now_text).bind(&now_text)
            .bind(Uuid::new_v4().to_string()).bind(&shared).bind(&deleting).bind(&now_text).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,chunk_size,state,expires_at,created_at) VALUES('upload',?,?, 'draft',4,'hash',4,'open',?,?)")
            .bind(&shared).bind(&deleting).bind(&now_text).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO upload_chunks(upload_id,chunk_index,bytes,sha256) VALUES('upload',0,'secret','hash')")
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO invitations(invitation_id,vault_id,token_hash,role,key_envelope,created_by,expires_at,accepted_by,accepted_at) VALUES('personal-invite',?,'token','editor','{}',?,?,?,?)")
            .bind(&personal).bind(&deleting).bind(&now_text).bind(&deleting).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO refresh_history(refresh_hash,family_id,user_id,device_id,consumed_at) VALUES('history-hash','family',?,?,?)")
            .bind(&deleting).bind(&device).bind(&now_text)
            .execute(&state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO account_invitations(invitation_id,token_hash,username,created_at,expires_at,consumed_at,consumed_user_id) VALUES('account-invite','token-account','purged@example.test',?,?,?,?)")
            .bind(&now_text).bind(&now_text).bind(&now_text).bind(&deleting)
            .execute(&state.db)
            .await
            .unwrap();
        let deadline = Utc::now().timestamp() - 1;
        sqlx::query("INSERT INTO account_deletion_requests(request_id,user_id,requested_at,purge_after,actor_hash) VALUES(?,?,?,?,'opaque-hmac')")
            .bind(&request_id)
            .bind(&deleting)
            .bind(deadline - 100)
            .bind(deadline)
            .execute(&state.db)
            .await
            .unwrap();

        let mut audit_tx = state.db.begin().await.unwrap();
        crate::audit::record_account_event_tx(
            &mut audit_tx,
            &state,
            &deleting,
            Some(&device),
            "device.registered",
            "device",
            Some(&device),
            crate::audit::AuditSource::Api,
            deadline - 100,
        )
        .await
        .unwrap();
        crate::audit::record_account_event_tx(
            &mut audit_tx,
            &state,
            &deleting,
            Some(&device),
            "account.created",
            "account",
            Some(&deleting),
            crate::audit::AuditSource::Api,
            deadline - 100,
        )
        .await
        .unwrap();
        crate::audit::record_account_event_tx(
            &mut audit_tx,
            &state,
            &deleting,
            Some(&device),
            "auth.account_recovery_enabled",
            "account_recovery",
            Some(&deleting),
            crate::audit::AuditSource::Api,
            deadline - 100,
        )
        .await
        .unwrap();
        crate::audit::record_vault_event_tx(
            &mut audit_tx,
            &shared,
            Some(&deleting),
            Some(&device),
            "vault.key_rotated",
            "vault",
            Some(&shared),
            crate::audit::AuditSource::Api,
            deadline - 100,
        )
        .await
        .unwrap();
        crate::audit::record_vault_event_tx(
            &mut audit_tx,
            &shared,
            Some(&deleting),
            Some(&device),
            "vault.invitation_accepted",
            "membership",
            Some(&deleting),
            crate::audit::AuditSource::Api,
            deadline - 100,
        )
        .await
        .unwrap();
        audit_tx.commit().await.unwrap();

        purge_due_account_deletions(&state, Utc::now().timestamp())
            .await
            .unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE user_id=?")
                .bind(&deleting)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM vaults WHERE vault_id=?")
                .bind(&personal)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM vaults WHERE vault_id=?")
                .bind(&shared)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM vault_members WHERE vault_id=? AND user_id=?"
            )
            .bind(&shared)
            .bind(&other)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            1
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM record_versions WHERE vault_id=?")
                .bind(&shared)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            1
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM record_versions WHERE vault_id=?")
                .bind(&personal)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM record_redactions WHERE vault_id=?")
                .bind(&personal)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0,
            "account deletion must cascade the Vault's redaction ledger"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM record_redacted_revisions WHERE vault_id=?"
            )
            .bind(&personal)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0,
            "account deletion must cascade durable redaction lookup rows"
        );
        let archived = sqlx::query("SELECT user_id,device_id,signing_public_key,encryption_public_key FROM vault_device_archives WHERE vault_id=?")
            .bind(&shared)
            .fetch_one(&state.db)
            .await
            .unwrap();
        assert_eq!(archived.get::<String, _>("user_id"), deleting);
        assert_eq!(archived.get::<String, _>("device_id"), device);
        assert_eq!(
            archived.get::<String, _>("signing_public_key"),
            "signing-pub"
        );
        assert_eq!(
            archived.get::<String, _>("encryption_public_key"),
            "encryption-pub"
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM uploads WHERE user_id=?")
                .bind(&deleting)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM refresh_history WHERE user_id=?")
                .bind(&deleting)
                .fetch_one(&state.db)
                .await
                .unwrap(),
            0
        );
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM account_invitations WHERE consumed_user_id=?"
            )
            .bind(&deleting)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0
        );
        let audit = sqlx::query(
            "SELECT user_id,purged_at,actor_hash FROM account_deletion_requests WHERE request_id=?",
        )
        .bind(&request_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(audit.get::<Option<String>, _>("user_id"), None);
        assert!(audit.get::<Option<i64>, _>("purged_at").is_some());
        assert_eq!(audit.get::<String, _>("actor_hash"), "opaque-hmac");
        let account_scope = crate::audit::account_scope_id(&state.cursor_key, &deleting).unwrap();
        let anonymized: Vec<(Option<String>, Option<String>, Option<String>)> =
            sqlx::query_as("SELECT actor_user_id,actor_device_id,resource_id FROM audit_events WHERE (scope_type='account' AND scope_id=?) OR (scope_type='vault' AND scope_id=?) ORDER BY event_id")
                .bind(&account_scope)
                .bind(&shared)
                .fetch_all(&state.db)
                .await
                .unwrap();
        assert_eq!(anonymized.len(), 6);
        assert!(
            anonymized
                .iter()
                .all(|(actor, device, _)| actor.is_none() && device.is_none())
        );
        assert!(anonymized.iter().all(|(_, _, resource)| {
            resource.as_deref() != Some(device.as_str())
                && resource.as_deref() != Some(deleting.as_str())
        }));
        let recovery_resource: Option<String> = sqlx::query_scalar(
            "SELECT resource_id FROM audit_events WHERE action='auth.account_recovery_enabled' AND resource_type='account_recovery'",
        )
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(recovery_resource, None);
        let retained_purge_event: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM audit_events WHERE scope_type='account' AND scope_id=? AND action='account.purged' AND actor_user_id IS NULL",
        )
        .bind(account_scope)
        .fetch_one(&state.db)
        .await
        .unwrap();
        assert_eq!(retained_purge_event, 1);
        let foreign_keys = sqlx::query("PRAGMA foreign_key_check")
            .fetch_all(&state.db)
            .await
            .unwrap();
        assert!(
            foreign_keys.is_empty(),
            "account purge must preserve SQLite FK integrity"
        );
        let other_access = crate::require_vault(&state, &other, &shared, false)
            .await
            .unwrap();
        assert_eq!(other_access.0, "owner");

        // Repeated maintenance has no second deletion side effects.
        purge_due_account_deletions(&state, Utc::now().timestamp() + 1)
            .await
            .unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM account_deletion_requests WHERE request_id=?",
            )
            .bind(&request_id)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            1
        );
        // Terminal audit follows the configured retention cutoff.
        let purged_at: i64 = sqlx::query_scalar(
            "SELECT purged_at FROM account_deletion_requests WHERE request_id=?",
        )
        .bind(&request_id)
        .fetch_one(&state.db)
        .await
        .unwrap();
        purge_due_account_deletions(
            &state,
            purged_at + state.config.audit_retention_days * 86_400 + 1,
        )
        .await
        .unwrap();
        assert_eq!(
            sqlx::query_scalar::<_, i64>(
                "SELECT COUNT(*) FROM account_deletion_requests WHERE request_id=?",
            )
            .bind(&request_id)
            .fetch_one(&state.db)
            .await
            .unwrap(),
            0
        );
    }
}

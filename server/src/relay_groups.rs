//! Server-managed Relay access groups.
//!
//! These groups are an instance-admin control plane, completely separate from
//! encrypted client-owned Vault records. Group policies only narrow the
//! instance and per-user Relay policy; all assigned group restrictions compose
//! by intersection.

use crate::{
    ApiError, AppState,
    auth::AuthUser,
    now_rfc3339,
    relay::{self, EffectiveRelayPolicy, RelayPolicy, RelayPolicySnapshot},
};
use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode},
};
use chrono::Utc;
use ipnet::IpNet;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{QueryBuilder, Row, Sqlite, Transaction};
use std::collections::BTreeSet;
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

const MAX_GROUPS: i64 = 1_000;
const MAX_GROUP_MEMBERS: usize = 1_000;
const MAX_NAME_CHARS: usize = 80;
const MAX_NAME_BYTES: usize = 320;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateGroupRequest {
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RenameGroupRequest {
    expected_revision: i64,
    name: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DeleteGroupRequest {
    expected_revision: i64,
    expected_membership_revision: i64,
    expected_policy_revision: i64,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReplaceMembersRequest {
    expected_revision: i64,
    user_ids: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateGroupPolicyRequest {
    expected_revision: i64,
    expected_instance_policy_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ResetGroupPolicyRequest {
    expected_revision: i64,
}

fn invalid_group_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_RELAY_GROUP_REQUEST",
        "request must contain only bounded, valid relay group fields",
    )
}

fn invalid_members_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_RELAY_GROUP_MEMBERS_REQUEST",
        "user_ids must be a bounded array of unique canonical account UUIDs",
    )
}

fn invalid_group_policy_request() -> ApiError {
    ApiError::bad_request(
        "INVALID_RELAY_GROUP_POLICY_REQUEST",
        "body must contain only bounded canonical Relay policy fields and nonnegative revisions",
    )
}

fn group_not_found() -> ApiError {
    ApiError::new(
        StatusCode::NOT_FOUND,
        "RELAY_GROUP_NOT_FOUND",
        "server-managed Relay access group does not exist",
    )
}

fn normalize_name(name: String) -> Result<(String, String), ApiError> {
    let name = name.trim().nfkc().collect::<String>();
    let count = name.chars().count();
    if count == 0
        || count > MAX_NAME_CHARS
        || name.len() > MAX_NAME_BYTES
        || name.chars().any(char::is_control)
    {
        return Err(invalid_group_request());
    }
    let name_key = name
        .nfkc()
        .flat_map(char::to_lowercase)
        .nfkc()
        .collect::<String>();
    Ok((name, name_key))
}

fn canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|uuid| uuid.to_string() == value)
}

fn canonical_group_id(value: &str) -> Result<(), ApiError> {
    if canonical_uuid(value) {
        Ok(())
    } else {
        Err(group_not_found())
    }
}

async fn begin_admin_read<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
) -> Result<(AuthUser, Transaction<'a, Sqlite>), ApiError> {
    let actor = crate::auth::authenticate(state, headers).await?;
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_read_tx(&mut tx, state, &actor).await?;
    Ok((actor, tx))
}

async fn begin_admin_write<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
) -> Result<(AuthUser, Transaction<'a, Sqlite>), ApiError> {
    let actor = crate::auth::authenticate(state, headers).await?;
    let mut tx = state
        .db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    crate::admin::require_instance_admin_write_tx(&mut tx, state, &actor).await?;
    Ok((actor, tx))
}

async fn require_group_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<(), ApiError> {
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM relay_access_groups WHERE group_id=?)")
            .bind(group_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if exists {
        Ok(())
    } else {
        Err(group_not_found())
    }
}

async fn current_group_revision_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT revision FROM relay_access_groups WHERE group_id=?")
        .bind(group_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(group_not_found)
}

async fn group_members_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<Vec<Value>, ApiError> {
    let rows = sqlx::query(
        "SELECT u.user_id,u.username FROM relay_access_group_members m \
         JOIN users u ON u.user_id=m.user_id WHERE m.group_id=? ORDER BY u.username,u.user_id",
    )
    .bind(group_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(rows
        .into_iter()
        .map(|row| {
            json!({
                "user_id": row.get::<String, _>("user_id"),
                "username": row.get::<String, _>("username"),
            })
        })
        .collect())
}

async fn read_group_policy_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<Option<RelayPolicySnapshot>, ApiError> {
    let row = sqlx::query(
        "SELECT enabled,allow_cidrs,allow_ports,revision,updated_at \
         FROM relay_access_group_relay_policies WHERE group_id=?",
    )
    .bind(group_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(None);
    };
    let cidr_json: String = row.get("allow_cidrs");
    let port_json: String = row.get("allow_ports");
    let cidrs: Vec<String> = serde_json::from_str(&cidr_json).map_err(ApiError::internal)?;
    let ports: Vec<u16> = serde_json::from_str(&port_json).map_err(ApiError::internal)?;
    let parsed_cidrs = relay::parse_stored_cidrs(cidrs).map_err(ApiError::internal)?;
    if ports.len() > relay::MAX_RELAY_POLICY_PORTS
        || ports.contains(&0)
        || ports.iter().copied().collect::<BTreeSet<_>>().len() != ports.len()
    {
        return Err(ApiError::internal("stored group Relay ports are invalid"));
    }
    Ok(Some(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled: row.get::<i64, _>("enabled") == 1,
            allow_cidrs: parsed_cidrs,
            allow_ports: ports,
        },
        revision: row.get("revision"),
        updated_at: row.get("updated_at"),
    }))
}

async fn read_group_policy_version_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
    policy: Option<&RelayPolicySnapshot>,
) -> Result<(i64, Option<String>), ApiError> {
    let row: Option<sqlx::sqlite::SqliteRow> = sqlx::query(
        "SELECT revision,updated_at FROM relay_access_group_relay_policy_revisions WHERE group_id=?",
    )
    .bind(group_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    match (policy, row) {
        (Some(policy), Some(row)) => {
            let revision: i64 = row.get("revision");
            let updated_at: String = row.get("updated_at");
            if revision != policy.revision || policy.updated_at.as_deref() != Some(&updated_at) {
                return Err(ApiError::internal(
                    "Relay group policy revision watermark mismatch",
                ));
            }
            Ok((revision, Some(updated_at)))
        }
        (None, Some(row)) => Ok((
            row.get::<i64, _>("revision"),
            Some(row.get::<String, _>("updated_at")),
        )),
        (Some(_), None) => Err(ApiError::internal(
            "Relay group policy revision watermark is missing",
        )),
        (None, None) => Ok((0, None)),
    }
}

pub(crate) async fn user_authorization_revision_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT revision FROM relay_user_authorization_versions WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)
        .map(|revision| revision.unwrap_or(0))
}

async fn bump_user_authorization_revision_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO relay_user_authorization_versions(user_id,revision) VALUES(?,1) \
         ON CONFLICT(user_id) DO UPDATE SET revision=revision+1",
    )
    .bind(user_id)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM relay_tickets WHERE user_id=? AND consumed_at IS NULL")
        .bind(user_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn group_user_ids_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<Vec<String>, ApiError> {
    sqlx::query_scalar(
        "SELECT user_id FROM relay_access_group_members WHERE group_id=? ORDER BY user_id",
    )
    .bind(group_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

fn policy_selection(policy: &RelayPolicy) -> Value {
    json!({
        "enabled": policy.enabled,
        "allow_cidrs": policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "allow_ports": policy.allow_ports,
    })
}

fn effective_policy_json(policy: &EffectiveRelayPolicy) -> Value {
    json!({
        "enabled": policy.enabled,
        "allow_cidrs": policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "allow_ports": policy.allow_ports,
    })
}

async fn group_policy_json_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    group_id: &str,
) -> Result<Value, ApiError> {
    let instance = relay::read_policy_tx(tx, state).await?;
    let instance_effective = relay::effective_policy_tx(tx, state).await?;
    let group_policy: Option<RelayPolicySnapshot> = read_group_policy_tx(tx, group_id).await?;
    let (revision, updated_at) =
        read_group_policy_version_tx(tx, group_id, group_policy.as_ref()).await?;
    let selected = group_policy
        .as_ref()
        .map(|snapshot| &snapshot.policy)
        .unwrap_or(&instance.policy);
    let effective = group_policy
        .as_ref()
        .map(|snapshot| relay::restrict_effective_policy(&instance_effective, &snapshot.policy))
        .unwrap_or(instance_effective);
    Ok(json!({
        "inherited": group_policy.is_none(),
        "revision": revision,
        "updated_at": updated_at,
        "instance_policy_revision": instance.revision,
        "policy": policy_selection(selected),
        "effective_policy": effective_policy_json(&effective),
    }))
}

async fn detail_tx(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    group_id: &str,
) -> Result<Value, ApiError> {
    let row = sqlx::query(
        "SELECT group_id,name,revision,created_at,updated_at FROM relay_access_groups WHERE group_id=?",
    )
    .bind(group_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(group_not_found)?;
    let membership_revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=?",
    )
    .bind(group_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("Relay group membership revision is missing"))?;
    Ok(json!({
        "group": {
            "group_id": row.get::<String,_>("group_id"),
            "name": row.get::<String,_>("name"),
            "revision": row.get::<i64,_>("revision"),
            "created_at": row.get::<String,_>("created_at"),
            "updated_at": row.get::<String,_>("updated_at"),
        },
        "members": {
            "revision": membership_revision,
            "items": group_members_tx(tx, group_id).await?,
        },
        "policy": group_policy_json_tx(tx, state, group_id).await?,
    }))
}

async fn audit_group_change(
    tx: &mut Transaction<'_, Sqlite>,
    state: &AppState,
    actor: &AuthUser,
    action: &str,
    group_id: &str,
) -> Result<(), ApiError> {
    crate::audit::record_instance_admin_event_tx(
        tx,
        state,
        &actor.user_id,
        &actor.device_id,
        action,
        "relay_access_group",
        Some(group_id),
        Utc::now().timestamp(),
    )
    .await
}

async fn bump_group_members_and_revoke_tx(
    tx: &mut Transaction<'_, Sqlite>,
    group_id: &str,
) -> Result<(), ApiError> {
    for user_id in group_user_ids_tx(tx, group_id).await? {
        bump_user_authorization_revision_tx(tx, &user_id).await?;
    }
    Ok(())
}

async fn policy_from_fields(request: UpdateGroupPolicyRequest) -> Result<RelayPolicy, ApiError> {
    if request.expected_revision < 0 || request.expected_instance_policy_revision < 0 {
        return Err(invalid_group_policy_request());
    }
    relay::parse_group_policy_fields(request.enabled, request.allow_cidrs, request.allow_ports)
        .map_err(|error| {
            // Keep group policy input errors scoped to this endpoint while
            // retaining the common canonical-CIDR and port validation.
            if error.body.code.starts_with("INVALID_RELAY_USER_POLICY") {
                invalid_group_policy_request()
            } else {
                error
            }
        })
}

pub(crate) async fn list(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (_actor, mut tx) = begin_admin_read(&state, &headers).await?;
    let rows = sqlx::query(
        "SELECT g.group_id,g.name,g.revision,g.updated_at,m.revision AS membership_revision, \
                COALESCE(pr.revision,0) AS policy_revision,COUNT(DISTINCT gm.user_id) AS member_count, \
                CASE WHEN p.group_id IS NULL THEN 1 ELSE 0 END AS policy_inherited \
         FROM relay_access_groups g \
         JOIN relay_access_group_membership_revisions m ON m.group_id=g.group_id \
         LEFT JOIN relay_access_group_members gm ON gm.group_id=g.group_id \
         LEFT JOIN relay_access_group_relay_policies p ON p.group_id=g.group_id \
         LEFT JOIN relay_access_group_relay_policy_revisions pr ON pr.group_id=g.group_id \
         GROUP BY g.group_id ORDER BY lower(g.name),g.group_id",
    )
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let groups = rows
        .into_iter()
        .map(|row| {
            json!({
                "group_id": row.get::<String,_>("group_id"),
                "name": row.get::<String,_>("name"),
                "revision": row.get::<i64,_>("revision"),
                "membership_revision": row.get::<i64,_>("membership_revision"),
                "policy_revision": row.get::<i64,_>("policy_revision"),
                "member_count": row.get::<i64,_>("member_count"),
                "policy_inherited": row.get::<i64,_>("policy_inherited") == 1,
                "updated_at": row.get::<String,_>("updated_at"),
            })
        })
        .collect::<Vec<_>>();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"groups":groups})))
}

pub(crate) async fn create(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<CreateGroupRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let Json(request) = request.map_err(|_| invalid_group_request())?;
    let (name, name_key) = normalize_name(request.name)?;
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_access_groups")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if count >= MAX_GROUPS {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_GROUP_CAPACITY_REACHED",
            "server-managed Relay group capacity is reached",
        ));
    }
    let duplicate: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM relay_access_groups WHERE name_key=?)")
            .bind(&name_key)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if duplicate {
        return Err(ApiError::conflict(
            "RELAY_GROUP_NAME_TAKEN",
            "a Relay access group with this name already exists",
        ));
    }
    let group_id = Uuid::new_v4().to_string();
    let now = now_rfc3339();
    sqlx::query(
        "INSERT INTO relay_access_groups(group_id,name,name_key,revision,created_at,updated_at) VALUES(?,?,?,1,?,?)",
    )
    .bind(&group_id)
    .bind(&name)
    .bind(&name_key)
    .bind(&now)
    .bind(&now)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO relay_access_group_membership_revisions(group_id,revision) VALUES(?,0)",
    )
    .bind(&group_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit_group_change(
        &mut tx,
        &state,
        &actor,
        "admin.relay_group_created",
        &group_id,
    )
    .await?;
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(response)))
}

pub(crate) async fn get(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let (_actor, mut tx) = begin_admin_read(&state, &headers).await?;
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn rename(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<RenameGroupRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_request())?;
    if request.expected_revision < 0 {
        return Err(invalid_group_request());
    }
    let (name, name_key) = normalize_name(request.name)?;
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    let revision = current_group_revision_tx(&mut tx, &group_id).await?;
    if revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_CONFLICT",
            "Relay access group changed since it was read",
        ));
    }
    let current: String =
        sqlx::query_scalar("SELECT name FROM relay_access_groups WHERE group_id=?")
            .bind(&group_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current != name {
        let duplicate: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM relay_access_groups WHERE name_key=? AND group_id<>?)",
        )
        .bind(&name_key)
        .bind(&group_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if duplicate {
            return Err(ApiError::conflict(
                "RELAY_GROUP_NAME_TAKEN",
                "a Relay access group with this name already exists",
            ));
        }
        let updated_at = now_rfc3339();
        sqlx::query(
            "UPDATE relay_access_groups SET name=?,name_key=?,revision=revision+1,updated_at=? WHERE group_id=? AND revision=?",
        )
        .bind(&name)
        .bind(&name_key)
        .bind(&updated_at)
        .bind(&group_id)
        .bind(revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        audit_group_change(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_renamed",
            &group_id,
        )
        .await?;
    }
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn delete(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<DeleteGroupRequest>, JsonRejection>,
) -> Result<StatusCode, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_request())?;
    if request.expected_revision < 0
        || request.expected_membership_revision < 0
        || request.expected_policy_revision < 0
    {
        return Err(invalid_group_request());
    }
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    let revision = current_group_revision_tx(&mut tx, &group_id).await?;
    if revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_CONFLICT",
            "Relay access group changed since it was read",
        ));
    }
    let membership_revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=?",
    )
    .bind(&group_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if membership_revision != request.expected_membership_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_MEMBERSHIP_CONFLICT",
            "Relay group membership changed since it was read",
        ));
    }
    let group_policy: Option<RelayPolicySnapshot> =
        read_group_policy_tx(&mut tx, &group_id).await?;
    let (policy_revision, _) =
        read_group_policy_version_tx(&mut tx, &group_id, group_policy.as_ref()).await?;
    if policy_revision != request.expected_policy_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "Relay group policy changed since it was read",
        ));
    }
    bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
    audit_group_change(
        &mut tx,
        &state,
        &actor,
        "admin.relay_group_deleted",
        &group_id,
    )
    .await?;
    sqlx::query("DELETE FROM relay_access_groups WHERE group_id=? AND revision=?")
        .bind(&group_id)
        .bind(revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn replace_members(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<ReplaceMembersRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_members_request())?;
    if request.expected_revision < 0 || request.user_ids.len() > MAX_GROUP_MEMBERS {
        return Err(invalid_members_request());
    }
    if request.user_ids.iter().any(|id| !canonical_uuid(id)) {
        return Err(invalid_members_request());
    }
    let submitted_count = request.user_ids.len();
    let target = request.user_ids.into_iter().collect::<BTreeSet<_>>();
    if target.len() != submitted_count {
        return Err(invalid_members_request());
    }
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    require_group_tx(&mut tx, &group_id).await?;
    let revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=?",
    )
    .bind(&group_id)
    .fetch_one(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_MEMBERSHIP_CONFLICT",
            "Relay group membership changed since it was read",
        ));
    }
    let existing = group_user_ids_tx(&mut tx, &group_id)
        .await?
        .into_iter()
        .collect::<BTreeSet<_>>();
    let additions = target
        .difference(&existing)
        .cloned()
        .collect::<BTreeSet<_>>();
    if !additions.is_empty() {
        let mut query = QueryBuilder::<Sqlite>::new(
            "SELECT user_id FROM users WHERE status='active' AND user_id IN (",
        );
        let mut separated = query.separated(",");
        for user_id in &additions {
            separated.push_bind(user_id);
        }
        query.push(")");
        let active = query
            .build_query_scalar::<String>()
            .fetch_all(&mut *tx)
            .await
            .map_err(ApiError::internal)?
            .into_iter()
            .collect::<BTreeSet<_>>();
        if active != additions {
            return Err(ApiError::bad_request(
                "INVALID_RELAY_GROUP_MEMBERS_REQUEST",
                "new group members must be existing active accounts",
            ));
        }
    }
    if existing != target {
        let affected = existing.union(&target).cloned().collect::<BTreeSet<_>>();
        let updated_at = now_rfc3339();
        sqlx::query(
            "UPDATE relay_access_group_membership_revisions SET revision=revision+1 WHERE group_id=? AND revision=?",
        )
        .bind(&group_id)
        .bind(revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=? WHERE group_id=?")
            .bind(&updated_at)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM relay_access_group_members WHERE group_id=?")
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        for user_id in &target {
            sqlx::query(
                "INSERT INTO relay_access_group_members(group_id,user_id,created_at) VALUES(?,?,?)",
            )
            .bind(&group_id)
            .bind(user_id)
            .bind(&updated_at)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
        for user_id in affected {
            bump_user_authorization_revision_tx(&mut tx, &user_id).await?;
        }
        audit_group_change(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_membership_updated",
            &group_id,
        )
        .await?;
    }
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn get_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let (_actor, mut tx) = begin_admin_read(&state, &headers).await?;
    require_group_tx(&mut tx, &group_id).await?;
    let response = group_policy_json_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn update_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<UpdateGroupPolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_policy_request())?;
    let expected_revision = request.expected_revision;
    let expected_instance_revision = request.expected_instance_policy_revision;
    let candidate = policy_from_fields(request).await?;
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    require_group_tx(&mut tx, &group_id).await?;
    let instance = relay::read_policy_tx(&mut tx, &state).await?;
    if instance.revision != expected_instance_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "instance Relay policy changed since it was read",
        ));
    }
    let current: Option<RelayPolicySnapshot> = read_group_policy_tx(&mut tx, &group_id).await?;
    let (current_revision, _) =
        read_group_policy_version_tx(&mut tx, &group_id, current.as_ref()).await?;
    if expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "Relay group policy changed since it was read",
        ));
    }
    let instance_effective = relay::effective_policy_tx(&mut tx, &state).await?;
    validate_group_policy_limits(&candidate, &instance_effective)?;
    let inherited_selection = current
        .as_ref()
        .map(|snapshot| &snapshot.policy)
        .unwrap_or(&instance.policy);
    if candidate != *inherited_selection {
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("Relay group policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        let cidrs = candidate
            .allow_cidrs
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        let cidr_json = serde_json::to_string(&cidrs).map_err(ApiError::internal)?;
        let port_json =
            serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO relay_access_group_relay_policies(group_id,enabled,allow_cidrs,allow_ports,revision,updated_at) \
             VALUES(?,?,?,?,?,?) ON CONFLICT(group_id) DO UPDATE SET enabled=excluded.enabled, \
             allow_cidrs=excluded.allow_cidrs,allow_ports=excluded.allow_ports,revision=excluded.revision,updated_at=excluded.updated_at",
        )
        .bind(&group_id)
        .bind(candidate.enabled as i64)
        .bind(cidr_json)
        .bind(port_json)
        .bind(revision)
        .bind(&updated_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO relay_access_group_relay_policy_revisions(group_id,revision,updated_at) VALUES(?,?,?) \
             ON CONFLICT(group_id) DO UPDATE SET revision=excluded.revision,updated_at=excluded.updated_at",
        )
        .bind(&group_id)
        .bind(revision)
        .bind(&updated_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=? WHERE group_id=?")
            .bind(&updated_at)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
        audit_group_change(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_policy_updated",
            &group_id,
        )
        .await?;
    }
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn reset_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<ResetGroupPolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_policy_request())?;
    if request.expected_revision < 0 {
        return Err(invalid_group_policy_request());
    }
    let (actor, mut tx) = begin_admin_write(&state, &headers).await?;
    require_group_tx(&mut tx, &group_id).await?;
    let current: Option<RelayPolicySnapshot> = read_group_policy_tx(&mut tx, &group_id).await?;
    let (current_revision, _) =
        read_group_policy_version_tx(&mut tx, &group_id, current.as_ref()).await?;
    if request.expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "Relay group policy changed since it was read",
        ));
    }
    if current.is_some() {
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("Relay group policy revision overflowed"))?;
        let updated_at = now_rfc3339();
        sqlx::query("DELETE FROM relay_access_group_relay_policies WHERE group_id=?")
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO relay_access_group_relay_policy_revisions(group_id,revision,updated_at) VALUES(?,?,?) \
             ON CONFLICT(group_id) DO UPDATE SET revision=excluded.revision,updated_at=excluded.updated_at",
        )
        .bind(&group_id)
        .bind(revision)
        .bind(&updated_at)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=? WHERE group_id=?")
            .bind(&updated_at)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
        audit_group_change(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_policy_reset",
            &group_id,
        )
        .await?;
    }
    let response = detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

fn validate_group_policy_limits(
    candidate: &RelayPolicy,
    instance: &EffectiveRelayPolicy,
) -> Result<(), ApiError> {
    if candidate.enabled && !instance.enabled {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_GROUP_POLICY_UNAVAILABLE",
            "group Relay policy cannot be enabled while the instance Relay policy is unavailable",
        ));
    }
    if candidate.allow_cidrs.iter().any(|requested| {
        !instance
            .allow_cidrs
            .iter()
            .any(|ceiling| network_within(*requested, *ceiling))
    }) || candidate
        .allow_ports
        .iter()
        .any(|port| !instance.allow_ports.contains(port))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_GROUP_POLICY_OUTSIDE_LIMITS",
            "group Relay policy must be contained by the current instance policy",
        ));
    }
    Ok(())
}

fn network_within(child: IpNet, parent: IpNet) -> bool {
    child.prefix_len() >= parent.prefix_len() && parent.trunc().contains(&child.network())
}

/// Applies every assigned group's explicit override. An inherited group has
/// the current instance policy, which is already included in `base`.
pub(crate) async fn apply_group_restrictions_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    mut base: EffectiveRelayPolicy,
) -> Result<EffectiveRelayPolicy, ApiError> {
    let rows = sqlx::query(
        "SELECT p.enabled,p.allow_cidrs,p.allow_ports FROM relay_access_group_members m \
         JOIN relay_access_group_relay_policies p ON p.group_id=m.group_id \
         WHERE m.user_id=? ORDER BY m.group_id",
    )
    .bind(user_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for row in rows {
        let cidr_json: String = row.get("allow_cidrs");
        let port_json: String = row.get("allow_ports");
        let cidrs: Vec<String> = serde_json::from_str(&cidr_json).map_err(ApiError::internal)?;
        let ports: Vec<u16> = serde_json::from_str(&port_json).map_err(ApiError::internal)?;
        if ports.len() > relay::MAX_RELAY_POLICY_PORTS
            || ports.contains(&0)
            || ports.iter().copied().collect::<BTreeSet<_>>().len() != ports.len()
        {
            return Err(ApiError::internal("stored group Relay ports are invalid"));
        }
        let restriction = RelayPolicy {
            enabled: row.get::<i64, _>("enabled") == 1,
            allow_cidrs: relay::parse_stored_cidrs(cidrs).map_err(ApiError::internal)?,
            allow_ports: ports,
        };
        base = relay::restrict_effective_policy(&base, &restriction);
    }
    Ok(base)
}

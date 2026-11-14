//! Organizations, teams, organization invitations, desired Vault grants and
//! owner-consented key distribution.
//!
//! Organization data is server-visible control metadata. A grant only states
//! *desired* membership. The Vault key reaches a grantee exclusively through
//! the existing device-targeted Vault invitation, which the key-holding
//! Vault owner's client creates after confirming the recipient device
//! fingerprint; the invitation token is then sealed to that device.
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    routing::{get, post, put},
};
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Row, Sqlite, Transaction};
use unicode_normalization::UnicodeNormalization;

use crate::{ApiError, AppState, auth::AuthUser, cloud};

const MAX_ORGS_PER_USER: i64 = 50;
const MAX_ORG_MEMBERS: i64 = 1000;
const MAX_TEAMS_PER_ORG: i64 = 200;
const DEFAULT_INVITATION_SECONDS: i64 = 7 * 24 * 60 * 60;
const MAX_INVITATION_SECONDS: i64 = 14 * 24 * 60 * 60;
const MAX_SEALED_TOKEN_CHARS: usize = 256;

pub(crate) fn routes() -> Router<AppState> {
    Router::new()
        .route("/api/v1/orgs", get(list_orgs).post(create_org))
        .route(
            "/api/v1/orgs/{org_id}",
            get(get_org).put(rename_org).delete(delete_org),
        )
        .route(
            "/api/v1/orgs/{org_id}/members/{user_id}",
            put(set_member_role).delete(remove_member),
        )
        .route(
            "/api/v1/orgs/{org_id}/invitations",
            get(list_invitations).post(create_invitation),
        )
        .route(
            "/api/v1/orgs/{org_id}/invitations/{invitation_id}/revoke",
            post(revoke_invitation),
        )
        .route("/api/v1/org-invitations/inspect", post(inspect_invitation))
        .route("/api/v1/org-invitations/accept", post(accept_invitation))
        .route("/api/v1/orgs/{org_id}/teams", post(create_team))
        .route(
            "/api/v1/orgs/{org_id}/teams/{team_id}",
            put(rename_team).delete(delete_team),
        )
        .route(
            "/api/v1/orgs/{org_id}/teams/{team_id}/members",
            put(replace_team_members),
        )
        .route(
            "/api/v1/vaults/{vault_id}/organization",
            put(attach_vault).delete(detach_vault),
        )
        .route("/api/v1/vaults/{vault_id}/grants", get(list_grants))
        .route(
            "/api/v1/vaults/{vault_id}/grants/{principal_type}/{principal_id}",
            put(set_grant).delete(remove_grant),
        )
        .route(
            "/api/v1/vaults/{vault_id}/key-distribution",
            get(key_distribution),
        )
        .route("/api/v1/vaults/{vault_id}/key-deliveries", post(create_delivery))
        .route(
            "/api/v1/vaults/{vault_id}/member-sources/{user_id}/make-direct",
            post(make_direct),
        )
        .route("/api/v1/cloud/device-card", put(publish_device_card))
        .route("/api/v1/cloud/key-deliveries", get(my_deliveries))
        .route(
            "/api/v1/cloud/key-deliveries/{delivery_id}/opened",
            post(mark_delivery_opened),
        )
}

fn require_ready(state: &AppState) -> Result<(), ApiError> {
    if cloud::organizations_ready(state) {
        Ok(())
    } else {
        Err(cloud::organizations_disabled())
    }
}

fn org_role_required() -> ApiError {
    ApiError::forbidden("ORG_ROLE_REQUIRED", "organization owner or admin role is required")
}

fn invalid(message: &str) -> ApiError {
    ApiError::new(StatusCode::UNPROCESSABLE_ENTITY, "ORG_REQUEST_INVALID", message)
}

fn normalize_name(raw: &str) -> Result<(String, String), ApiError> {
    let name = raw.nfkc().collect::<String>().trim().to_owned();
    if name.is_empty() || name.chars().count() > 80 || name.chars().any(char::is_control) {
        return Err(invalid("names must be 1–80 printable characters"));
    }
    let key = name.to_lowercase();
    Ok((name, key))
}

/// Opens a writer transaction bound to the caller's live session.
async fn write_tx<'a>(state: &'a AppState, user: &AuthUser) -> Result<Transaction<'a, Sqlite>, ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_tx(&mut tx, user).await?;
    Ok(tx)
}

async fn read_tx<'a>(state: &'a AppState, user: &AuthUser) -> Result<Transaction<'a, Sqlite>, ApiError> {
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    crate::require_active_session_device_read_tx(&mut tx, user).await?;
    Ok(tx)
}

/// Caller's role in `org_id`. Non-members get the same 404 as unknown IDs.
async fn org_role_tx(
    tx: &mut Transaction<'_, Sqlite>,
    org_id: &str,
    user_id: &str,
) -> Result<String, ApiError> {
    if !crate::is_canonical_uuid(org_id) {
        return Err(ApiError::not_found());
    }
    sqlx::query_scalar("SELECT role FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(org_id)
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)
}

fn is_manager(role: &str) -> bool {
    matches!(role, "owner" | "admin")
}

async fn bump_org_membership_tx(tx: &mut Transaction<'_, Sqlite>, org_id: &str) -> Result<(), ApiError> {
    sqlx::query("UPDATE cloud_organizations SET membership_revision=membership_revision+1 WHERE org_id=?")
        .bind(org_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

/// Grant changes in every Vault of an organization become visible to their
/// owners through `grants_revision`; pending invitations of users who are no
/// longer covered are cancelled immediately (they never received the key).
async fn reconcile_org_tx(tx: &mut Transaction<'_, Sqlite>, org_id: &str, now: i64) -> Result<(), ApiError> {
    sqlx::query("UPDATE cloud_vault_orgs SET grants_revision=grants_revision+1 WHERE org_id=?")
        .bind(org_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let vaults: Vec<String> = sqlx::query_scalar("SELECT vault_id FROM cloud_vault_orgs WHERE org_id=?")
        .bind(org_id)
        .fetch_all(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    for vault_id in vaults {
        reconcile_vault_tx(tx, &vault_id, now).await?;
    }
    Ok(())
}

/// Recomputes the effective (union) coverage of every grant-derived member of
/// `vault_id` and restricts access immediately where grants no longer cover
/// it. Direct members (no provenance row) are never touched. Called in the
/// same transaction as every organization, team, grant or attachment change.
pub(crate) async fn reconcile_vault_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    now: i64,
) -> Result<(), ApiError> {
    let desired = desired_members_tx(tx, vault_id).await?;
    let sourced: Vec<(String, String, String)> = sqlx::query_as(
        "SELECT s.user_id,vm.role,vm.state FROM cloud_vault_member_sources s JOIN vault_members vm ON vm.vault_id=s.vault_id AND vm.user_id=s.user_id WHERE s.vault_id=?",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for (user_id, signed_role, member_state) in sourced {
        let restriction = if !matches!(member_state.as_str(), "active" | "invited") || signed_role == "owner" {
            None
        } else {
            match desired.get(&user_id) {
                None => Some("none"),
                Some((role, _)) if role == "viewer" && signed_role == "editor" => Some("viewer"),
                Some(_) => None,
            }
        };
        match restriction {
            Some(max_role) => {
                sqlx::query(
                    "INSERT INTO cloud_member_restrictions(vault_id,user_id,max_role,updated_epoch) VALUES(?,?,?,?) \
                     ON CONFLICT(vault_id,user_id) DO UPDATE SET max_role=excluded.max_role,updated_epoch=excluded.updated_epoch",
                )
                .bind(vault_id)
                .bind(&user_id)
                .bind(max_role)
                .bind(now)
                .execute(&mut **tx)
                .await
                .map_err(ApiError::internal)?;
            }
            None => {
                sqlx::query("DELETE FROM cloud_member_restrictions WHERE vault_id=? AND user_id=?")
                    .bind(vault_id)
                    .bind(&user_id)
                    .execute(&mut **tx)
                    .await
                    .map_err(ApiError::internal)?;
            }
        }
    }
    // Credential visibility: a `none` restriction may hide the Vault's last
    // admin_visible member; its escrow deposits must not outlive that.
    crate::credential_visibility::prune_orphaned_escrow_tx(tx, vault_id).await?;
    cancel_uncovered_pending_tx(tx, vault_id, now).await
}

/// Users currently covered by a grant on `vault_id`, with the strongest role.
async fn desired_members_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
) -> Result<std::collections::BTreeMap<String, (String, Vec<String>)>, ApiError> {
    let rows = sqlx::query(
        "SELECT g.principal_id AS user_id,g.role,'user' AS via FROM cloud_vault_grants g JOIN cloud_org_members m ON m.org_id=g.org_id AND m.user_id=g.principal_id WHERE g.vault_id=? AND g.principal_type='user' \
         UNION ALL \
         SELECT tm.user_id,g.role,t.name AS via FROM cloud_vault_grants g JOIN cloud_teams t ON t.org_id=g.org_id AND t.team_id=g.principal_id JOIN cloud_team_members tm ON tm.team_id=t.team_id AND tm.org_id=t.org_id WHERE g.vault_id=? AND g.principal_type='team'",
    )
    .bind(vault_id)
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut desired: std::collections::BTreeMap<String, (String, Vec<String>)> = Default::default();
    for row in rows {
        let user_id: String = row.get("user_id");
        let role: String = row.get("role");
        let via: String = row.get("via");
        let entry = desired.entry(user_id).or_insert_with(|| (role.clone(), Vec::new()));
        if role == "editor" {
            entry.0 = "editor".into();
        }
        entry.1.push(via);
    }
    Ok(desired)
}

async fn cancel_uncovered_pending_tx(tx: &mut Transaction<'_, Sqlite>, vault_id: &str, now: i64) -> Result<(), ApiError> {
    let desired = desired_members_tx(tx, vault_id).await?;
    let pending: Vec<(String, String)> = sqlx::query_as(
        "SELECT d.delivery_id,d.recipient_user_id FROM cloud_key_deliveries d JOIN invitations i ON i.invitation_id=d.invitation_id WHERE d.vault_id=? AND i.accepted_at IS NULL",
    )
    .bind(vault_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    for (delivery_id, user_id) in pending {
        if desired.contains_key(&user_id) {
            continue;
        }
        // Expire the unaccepted invitation so the key envelope can no longer
        // be activated, and drop the sealed token.
        sqlx::query(
            "UPDATE invitations SET expires_at=? WHERE invitation_id=(SELECT invitation_id FROM cloud_key_deliveries WHERE delivery_id=?) AND accepted_at IS NULL",
        )
        .bind(
            chrono::DateTime::<chrono::Utc>::from_timestamp(now - 1, 0)
                .map(|t| t.to_rfc3339())
                .unwrap_or_default(),
        )
        .bind(&delivery_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM cloud_key_deliveries WHERE delivery_id=?")
            .bind(&delivery_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Organizations
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateOrgRequest {
    name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RenameRequest {
    name: String,
    expected_revision: i64,
}

pub async fn list_orgs(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = read_tx(&state, &user).await?;
    let rows = sqlx::query(
        "SELECT o.org_id,o.name,o.revision,m.role,(SELECT COUNT(*) FROM cloud_org_members x WHERE x.org_id=o.org_id) AS members FROM cloud_organizations o JOIN cloud_org_members m ON m.org_id=o.org_id WHERE m.user_id=? ORDER BY o.name_key",
    )
    .bind(&user.user_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let can_create = state.cloud.config.org_creation_any || is_instance_admin(&state, &user).await?;
    Ok(Json(json!({
        "can_create": can_create,
        "organizations": rows.iter().map(|row| json!({
            "org_id": row.get::<String, _>("org_id"),
            "name": row.get::<String, _>("name"),
            "revision": row.get::<i64, _>("revision"),
            "role": row.get::<String, _>("role"),
            "member_count": row.get::<i64, _>("members"),
        })).collect::<Vec<_>>(),
    })))
}

async fn is_instance_admin(state: &AppState, user: &AuthUser) -> Result<bool, ApiError> {
    let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
        .bind(&user.user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(username.is_some_and(|name| state.config.is_instance_admin(&name)))
}

pub async fn create_org(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<CreateOrgRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !state.cloud.config.org_creation_any && !is_instance_admin(&state, &user).await? {
        return Err(ApiError::forbidden(
            "ORG_CREATION_RESTRICTED",
            "only instance administrators can create organizations on this server",
        ));
    }
    let (name, key) = normalize_name(&req.name)?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    let owned: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_org_members WHERE user_id=?")
        .bind(&user.user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if owned >= MAX_ORGS_PER_USER {
        return Err(ApiError::conflict("ORG_LIMIT", "too many organizations"));
    }
    let org_id = uuid::Uuid::new_v4().to_string();
    let inserted = sqlx::query(
        "INSERT INTO cloud_organizations(org_id,name,name_key,created_by,created_at) VALUES(?,?,?,?,?) ON CONFLICT(name_key) DO NOTHING",
    )
    .bind(&org_id)
    .bind(&name)
    .bind(&key)
    .bind(&user.user_id)
    .bind(cloud::epoch_rfc3339(now))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if inserted.rows_affected() != 1 {
        return Err(ApiError::conflict("ORG_NAME_TAKEN", "an organization with this name exists"));
    }
    sqlx::query("INSERT INTO cloud_org_members(org_id,user_id,role,joined_at) VALUES(?,?,'owner',?)")
        .bind(&org_id)
        .bind(&user.user_id)
        .bind(cloud::epoch_rfc3339(now))
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    cloud::audit_tx(&mut tx, cloud::AuditEntry::org(&org_id, "org.created").actor(&user.user_id), now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(json!({"org_id": org_id, "name": name, "role": "owner", "revision": 1}))))
}

pub async fn get_org(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = read_tx(&state, &user).await?;
    let role = org_role_tx(&mut tx, &org_id, &user.user_id).await?;
    let org = sqlx::query("SELECT name,revision,membership_revision FROM cloud_organizations WHERE org_id=?")
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let members = sqlx::query(
        "SELECT m.user_id,u.username,m.role,m.joined_at FROM cloud_org_members m JOIN users u ON u.user_id=m.user_id WHERE m.org_id=? ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'admin' THEN 1 ELSE 2 END,u.username",
    )
    .bind(&org_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let teams = sqlx::query("SELECT team_id,name,revision FROM cloud_teams WHERE org_id=? ORDER BY name_key")
        .bind(&org_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let mut team_values = Vec::with_capacity(teams.len());
    for team in &teams {
        let team_id: String = team.get("team_id");
        let member_ids: Vec<String> = sqlx::query_scalar(
            "SELECT user_id FROM cloud_team_members WHERE org_id=? AND team_id=? ORDER BY user_id",
        )
        .bind(&org_id)
        .bind(&team_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        team_values.push(json!({
            "team_id": team_id,
            "name": team.get::<String, _>("name"),
            "revision": team.get::<i64, _>("revision"),
            "member_user_ids": member_ids,
        }));
    }
    let vaults = sqlx::query(
        "SELECT vo.vault_id,u.username AS owner_username,vo.grants_revision FROM cloud_vault_orgs vo JOIN vaults v ON v.vault_id=vo.vault_id JOIN users u ON u.user_id=v.owner_user_id WHERE vo.org_id=? ORDER BY vo.attached_at",
    )
    .bind(&org_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "org_id": org_id,
        "name": org.get::<String, _>("name"),
        "revision": org.get::<i64, _>("revision"),
        "membership_revision": org.get::<i64, _>("membership_revision"),
        "role": role,
        "members": members.iter().map(|row| json!({
            "user_id": row.get::<String, _>("user_id"),
            "username": row.get::<String, _>("username"),
            "role": row.get::<String, _>("role"),
            "joined_at": row.get::<String, _>("joined_at"),
        })).collect::<Vec<_>>(),
        "teams": team_values,
        "vaults": vaults.iter().map(|row| json!({
            "vault_id": row.get::<String, _>("vault_id"),
            "owner_username": row.get::<String, _>("owner_username"),
            "grants_revision": row.get::<i64, _>("grants_revision"),
        })).collect::<Vec<_>>(),
    })))
}

pub async fn rename_org(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
    Json(req): Json<RenameRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let (name, key) = normalize_name(&req.name)?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let updated = sqlx::query(
        "UPDATE cloud_organizations SET name=?,name_key=?,revision=revision+1 WHERE org_id=? AND revision=? AND NOT EXISTS(SELECT 1 FROM cloud_organizations o WHERE o.name_key=? AND o.org_id<>?)",
    )
    .bind(&name)
    .bind(&key)
    .bind(&org_id)
    .bind(req.expected_revision)
    .bind(&key)
    .bind(&org_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict("ORG_REVISION_CONFLICT", "organization changed or the name is taken"));
    }
    cloud::audit_tx(&mut tx, cloud::AuditEntry::org(&org_id, "org.renamed").actor(&user.user_id), now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"org_id": org_id, "name": name, "revision": req.expected_revision + 1})))
}

pub async fn delete_org(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = write_tx(&state, &user).await?;
    if org_role_tx(&mut tx, &org_id, &user.user_id).await? != "owner" {
        return Err(ApiError::forbidden("ORG_ROLE_REQUIRED", "organization owner role is required"));
    }
    let vaults: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_vault_orgs WHERE org_id=?")
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if vaults > 0 {
        return Err(ApiError::conflict(
            "ORG_HAS_VAULTS",
            "detach every Vault before deleting the organization",
        ));
    }
    sqlx::query("DELETE FROM cloud_organizations WHERE org_id=?")
        .bind(&org_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"deleted": true})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MemberRoleRequest {
    role: String,
}

pub async fn set_member_role(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, member_id)): Path<(String, String)>,
    Json(req): Json<MemberRoleRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !matches!(req.role.as_str(), "owner" | "admin" | "member") {
        return Err(invalid("role must be owner, admin or member"));
    }
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    let my_role = org_role_tx(&mut tx, &org_id, &user.user_id).await?;
    let target_role: String = sqlx::query_scalar("SELECT role FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(&org_id)
        .bind(&member_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    // Admins manage members/admins; only owners touch owner roles.
    let allowed = match my_role.as_str() {
        "owner" => true,
        "admin" => target_role != "owner" && req.role != "owner",
        _ => false,
    };
    if !allowed {
        return Err(org_role_required());
    }
    if target_role == "owner" && req.role != "owner" {
        let owners: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_org_members WHERE org_id=? AND role='owner'")
            .bind(&org_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if owners <= 1 {
            return Err(ApiError::conflict("ORG_LAST_OWNER", "an organization needs at least one owner"));
        }
    }
    sqlx::query("UPDATE cloud_org_members SET role=? WHERE org_id=? AND user_id=?")
        .bind(&req.role)
        .bind(&org_id)
        .bind(&member_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    bump_org_membership_tx(&mut tx, &org_id).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "org.member_role_changed")
            .actor(&user.user_id)
            .detail(format!("user_id={member_id} role={}", req.role)),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"user_id": member_id, "role": req.role})))
}

/// Removes a member (or the caller leaves). Their team memberships and user
/// grants go immediately; pending (unaccepted) Vault invitations are
/// cancelled; Vaults they own are detached; and Vault owners see the
/// grant-derived members that now need key rotation.
pub async fn remove_member(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, member_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    let my_role = org_role_tx(&mut tx, &org_id, &user.user_id).await?;
    let target_role: String = sqlx::query_scalar("SELECT role FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(&org_id)
        .bind(&member_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
    let leaving = member_id == user.user_id;
    let allowed = leaving
        || match my_role.as_str() {
            "owner" => true,
            "admin" => target_role != "owner",
            _ => false,
        };
    if !allowed {
        return Err(org_role_required());
    }
    if target_role == "owner" {
        let owners: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_org_members WHERE org_id=? AND role='owner'")
            .bind(&org_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if owners <= 1 {
            return Err(ApiError::conflict("ORG_LAST_OWNER", "an organization needs at least one owner"));
        }
    }
    // Vaults owned by the departing member leave the organization with them;
    // their grant-derived members lose coverage immediately.
    let leaving_vaults: Vec<String> = sqlx::query_scalar(
        "DELETE FROM cloud_vault_orgs WHERE org_id=? AND vault_id IN (SELECT vault_id FROM vaults WHERE owner_user_id=?) RETURNING vault_id",
    )
    .bind(&org_id)
    .bind(&member_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    for vault_id in &leaving_vaults {
        reconcile_vault_tx(&mut tx, vault_id, now).await?;
    }
    sqlx::query("DELETE FROM cloud_vault_grants WHERE org_id=? AND principal_type='user' AND principal_id=?")
        .bind(&org_id)
        .bind(&member_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("DELETE FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(&org_id)
        .bind(&member_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    bump_org_membership_tx(&mut tx, &org_id).await?;
    reconcile_org_tx(&mut tx, &org_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, if leaving { "org.member_left" } else { "org.member_removed" })
            .actor(&user.user_id)
            .detail(format!("user_id={member_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"removed": true})))
}

// ---------------------------------------------------------------------------
// Invitations
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateInvitationRequest {
    role: String,
    #[serde(default)]
    intended_username: Option<String>,
    #[serde(default)]
    team_id: Option<String>,
    #[serde(default)]
    expires_in_seconds: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TokenRequest {
    token: String,
}

pub async fn create_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
    Json(req): Json<CreateInvitationRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !matches!(req.role.as_str(), "admin" | "member") {
        return Err(invalid("invitation role must be admin or member"));
    }
    let lifetime = req.expires_in_seconds.unwrap_or(DEFAULT_INVITATION_SECONDS);
    if !(300..=MAX_INVITATION_SECONDS).contains(&lifetime) {
        return Err(invalid("invitation lifetime must be between 5 minutes and 14 days"));
    }
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let intended_user_id = match req.intended_username.as_deref() {
        Some(name) => {
            let normalized = crate::auth::normalized_username(name).map_err(|_| invalid("username is invalid"))?;
            Some(
                sqlx::query_scalar::<_, String>("SELECT user_id FROM users WHERE username=? AND status='active'")
                    .bind(normalized)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?
                    .ok_or_else(|| {
                        ApiError::new(
                            StatusCode::NOT_FOUND,
                            "ACCOUNT_NOT_FOUND",
                            "no active account has this username; ask an instance administrator for an account invitation first",
                        )
                    })?,
            )
        }
        None => None,
    };
    if let Some(team_id) = req.team_id.as_deref() {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM cloud_teams WHERE org_id=? AND team_id=?)")
            .bind(&org_id)
            .bind(team_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if !exists {
            return Err(ApiError::not_found());
        }
    }
    let token = cloud::random_token();
    let invitation_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO cloud_org_invitations(invitation_id,org_id,token_hash,role,intended_user_id,team_id,created_by,created_epoch,expires_epoch) VALUES(?,?,?,?,?,?,?,?,?)",
    )
    .bind(&invitation_id)
    .bind(&org_id)
    .bind(cloud::token_hash(&token))
    .bind(&req.role)
    .bind(&intended_user_id)
    .bind(&req.team_id)
    .bind(&user.user_id)
    .bind(now)
    .bind(now + lifetime)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "org.invitation_created")
            .actor(&user.user_id)
            .detail(format!("invitation_id={invitation_id} role={}", req.role)),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "invitation_id": invitation_id,
            "token": token,
            "join_path": "/join",
            "expires_at": cloud::epoch_rfc3339(now + lifetime),
            "role": req.role,
        })),
    ))
}

pub async fn list_invitations(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = read_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let rows = sqlx::query(
        "SELECT i.invitation_id,i.role,i.team_id,i.created_epoch,i.expires_epoch,i.consumed_epoch,i.revoked_epoch,iu.username AS intended,cu.username AS consumed FROM cloud_org_invitations i LEFT JOIN users iu ON iu.user_id=i.intended_user_id LEFT JOIN users cu ON cu.user_id=i.consumed_by WHERE i.org_id=? ORDER BY i.created_epoch DESC LIMIT 200",
    )
    .bind(&org_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"invitations": rows.iter().map(|row| {
        let consumed: Option<i64> = row.get("consumed_epoch");
        let revoked: Option<i64> = row.get("revoked_epoch");
        let expires: i64 = row.get("expires_epoch");
        let status = if revoked.is_some() { "revoked" } else if consumed.is_some() { "accepted" } else if expires <= now { "expired" } else { "pending" };
        json!({
            "invitation_id": row.get::<String, _>("invitation_id"),
            "role": row.get::<String, _>("role"),
            "team_id": row.get::<Option<String>, _>("team_id"),
            "intended_username": row.get::<Option<String>, _>("intended"),
            "accepted_by_username": row.get::<Option<String>, _>("consumed"),
            "created_at": cloud::epoch_rfc3339(row.get("created_epoch")),
            "expires_at": cloud::epoch_rfc3339(expires),
            "status": status,
        })
    }).collect::<Vec<_>>()})))
}

pub async fn revoke_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, invitation_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let updated = sqlx::query(
        "UPDATE cloud_org_invitations SET revoked_epoch=? WHERE invitation_id=? AND org_id=? AND consumed_epoch IS NULL AND revoked_epoch IS NULL",
    )
    .bind(now)
    .bind(&invitation_id)
    .bind(&org_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "org.invitation_revoked")
            .actor(&user.user_id)
            .detail(format!("invitation_id={invitation_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"revoked": true})))
}

fn invitation_unavailable() -> ApiError {
    ApiError::new(StatusCode::NOT_FOUND, "ORG_INVITATION_UNAVAILABLE", "this invitation is not available")
}

pub async fn inspect_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TokenRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !cloud::is_token(&req.token) {
        return Err(invitation_unavailable());
    }
    let now = cloud::now_epoch();
    state
        .cloud
        .rate
        .check(&format!("org_invite:{}", user.user_id), 30, 60, now)
        .map_err(|retry| ApiError::new(StatusCode::TOO_MANY_REQUESTS, "RATE_LIMITED", "too many requests").with_retry_after(retry))?;
    let mut tx = read_tx(&state, &user).await?;
    let row = sqlx::query(
        "SELECT i.org_id,o.name,i.role,i.expires_epoch,i.consumed_epoch,i.revoked_epoch,i.intended_user_id,u.username AS inviter FROM cloud_org_invitations i JOIN cloud_organizations o ON o.org_id=i.org_id JOIN users u ON u.user_id=i.created_by WHERE i.token_hash=?",
    )
    .bind(cloud::token_hash(&req.token))
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Err(invitation_unavailable());
    };
    let intended: Option<String> = row.get("intended_user_id");
    if row.get::<Option<i64>, _>("revoked_epoch").is_some()
        || row.get::<Option<i64>, _>("consumed_epoch").is_some()
        || row.get::<i64, _>("expires_epoch") <= now
        || intended.as_deref().is_some_and(|id| id != user.user_id)
    {
        return Err(invitation_unavailable());
    }
    Ok(Json(json!({
        "org_id": row.get::<String, _>("org_id"),
        "name": row.get::<String, _>("name"),
        "role": row.get::<String, _>("role"),
        "invited_by": row.get::<String, _>("inviter"),
        "expires_at": cloud::epoch_rfc3339(row.get("expires_epoch")),
    })))
}

pub async fn accept_invitation(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<TokenRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !cloud::is_token(&req.token) {
        return Err(invitation_unavailable());
    }
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    // Atomic one-use consumption bound to the intended account (if any).
    let row = sqlx::query(
        "UPDATE cloud_org_invitations SET consumed_epoch=?,consumed_by=? WHERE token_hash=? AND consumed_epoch IS NULL AND revoked_epoch IS NULL AND expires_epoch>? AND (intended_user_id IS NULL OR intended_user_id=?) RETURNING invitation_id,org_id,role,team_id",
    )
    .bind(now)
    .bind(&user.user_id)
    .bind(cloud::token_hash(&req.token))
    .bind(now)
    .bind(&user.user_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Err(invitation_unavailable());
    };
    let org_id: String = row.get("org_id");
    let role: String = row.get("role");
    let team_id: Option<String> = row.get("team_id");
    let members: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_org_members WHERE org_id=?")
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if members >= MAX_ORG_MEMBERS {
        return Err(ApiError::conflict("ORG_MEMBER_LIMIT", "organization member limit reached"));
    }
    let existing: Option<String> = sqlx::query_scalar("SELECT role FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(&org_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if existing.is_none() {
        sqlx::query("INSERT INTO cloud_org_members(org_id,user_id,role,joined_at) VALUES(?,?,?,?)")
            .bind(&org_id)
            .bind(&user.user_id)
            .bind(&role)
            .bind(cloud::epoch_rfc3339(now))
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    if let Some(team_id) = team_id.as_deref() {
        sqlx::query("INSERT OR IGNORE INTO cloud_team_members(org_id,team_id,user_id,added_at) VALUES(?,?,?,?)")
            .bind(&org_id)
            .bind(team_id)
            .bind(&user.user_id)
            .bind(cloud::epoch_rfc3339(now))
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    }
    bump_org_membership_tx(&mut tx, &org_id).await?;
    reconcile_org_tx(&mut tx, &org_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "org.invitation_accepted")
            .actor(&user.user_id)
            .detail(format!("invitation_id={} role={role}", row.get::<String, _>("invitation_id"))),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "org_id": org_id,
        "role": existing.unwrap_or(role),
        "joined": true,
        // Joining never grants a Vault key: Vault owners still have to
        // distribute keys to the new member's devices explicitly.
        "vault_keys_pending": true,
    })))
}

// ---------------------------------------------------------------------------
// Teams
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TeamMembersRequest {
    user_ids: Vec<String>,
    expected_revision: i64,
}

pub async fn create_team(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(org_id): Path<String>,
    Json(req): Json<CreateOrgRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let (name, key) = normalize_name(&req.name)?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let teams: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM cloud_teams WHERE org_id=?")
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if teams >= MAX_TEAMS_PER_ORG {
        return Err(ApiError::conflict("TEAM_LIMIT", "too many teams"));
    }
    let team_id = uuid::Uuid::new_v4().to_string();
    let inserted = sqlx::query(
        "INSERT INTO cloud_teams(org_id,team_id,name,name_key,created_at) VALUES(?,?,?,?,?) ON CONFLICT(org_id,name_key) DO NOTHING",
    )
    .bind(&org_id)
    .bind(&team_id)
    .bind(&name)
    .bind(&key)
    .bind(cloud::epoch_rfc3339(now))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if inserted.rows_affected() != 1 {
        return Err(ApiError::conflict("TEAM_NAME_TAKEN", "a team with this name exists"));
    }
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "team.created").actor(&user.user_id).detail(format!("team_id={team_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(json!({"team_id": team_id, "name": name, "revision": 1, "member_user_ids": []}))))
}

pub async fn rename_team(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, team_id)): Path<(String, String)>,
    Json(req): Json<RenameRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let (name, key) = normalize_name(&req.name)?;
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let updated = sqlx::query(
        "UPDATE cloud_teams SET name=?,name_key=?,revision=revision+1 WHERE org_id=? AND team_id=? AND revision=? AND NOT EXISTS(SELECT 1 FROM cloud_teams t WHERE t.org_id=? AND t.name_key=? AND t.team_id<>?)",
    )
    .bind(&name)
    .bind(&key)
    .bind(&org_id)
    .bind(&team_id)
    .bind(req.expected_revision)
    .bind(&org_id)
    .bind(&key)
    .bind(&team_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::conflict("TEAM_REVISION_CONFLICT", "team changed or the name is taken"));
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"team_id": team_id, "name": name, "revision": req.expected_revision + 1})))
}

pub async fn delete_team(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, team_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    sqlx::query("DELETE FROM cloud_vault_grants WHERE org_id=? AND principal_type='team' AND principal_id=?")
        .bind(&org_id)
        .bind(&team_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let deleted = sqlx::query("DELETE FROM cloud_teams WHERE org_id=? AND team_id=?")
        .bind(&org_id)
        .bind(&team_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if deleted.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    reconcile_org_tx(&mut tx, &org_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "team.deleted").actor(&user.user_id).detail(format!("team_id={team_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"deleted": true})))
}

pub async fn replace_team_members(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((org_id, team_id)): Path<(String, String)>,
    Json(req): Json<TeamMembersRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if req.user_ids.len() > MAX_ORG_MEMBERS as usize {
        return Err(invalid("too many team members"));
    }
    let mut ids = req.user_ids.clone();
    ids.sort();
    ids.dedup();
    if ids.len() != req.user_ids.len() || ids.iter().any(|id| !crate::is_canonical_uuid(id)) {
        return Err(invalid("team members must be distinct account IDs"));
    }
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    if !is_manager(&org_role_tx(&mut tx, &org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let updated = sqlx::query("UPDATE cloud_teams SET revision=revision+1 WHERE org_id=? AND team_id=? AND revision=?")
        .bind(&org_id)
        .bind(&team_id)
        .bind(req.expected_revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM cloud_teams WHERE org_id=? AND team_id=?)")
            .bind(&org_id)
            .bind(&team_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        return Err(if exists {
            ApiError::conflict("TEAM_REVISION_CONFLICT", "team changed; reload it")
        } else {
            ApiError::not_found()
        });
    }
    sqlx::query("DELETE FROM cloud_team_members WHERE org_id=? AND team_id=?")
        .bind(&org_id)
        .bind(&team_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    for member in &ids {
        // The composite foreign key rejects users that are not members of
        // this organization; surface it as a uniform 404.
        let inserted = sqlx::query("INSERT INTO cloud_team_members(org_id,team_id,user_id,added_at) VALUES(?,?,?,?)")
            .bind(&org_id)
            .bind(&team_id)
            .bind(member)
            .bind(cloud::epoch_rfc3339(now))
            .execute(&mut *tx)
            .await;
        if inserted.is_err() {
            return Err(ApiError::not_found());
        }
    }
    reconcile_org_tx(&mut tx, &org_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::org(&org_id, "team.members_replaced")
            .actor(&user.user_id)
            .detail(format!("team_id={team_id} members={}", ids.len())),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"team_id": team_id, "revision": req.expected_revision + 1, "member_user_ids": ids})))
}

// ---------------------------------------------------------------------------
// Vault attachment and grants
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AttachRequest {
    org_id: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GrantRequest {
    role: String,
    expected_grants_revision: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoveGrantRequest {
    expected_grants_revision: i64,
}

async fn vault_role_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    user_id: &str,
) -> Result<Option<String>, ApiError> {
    sqlx::query_scalar(
        "SELECT vm.role FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE v.vault_id=? AND v.state='active' AND vm.user_id=? AND vm.state='active'",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

/// Who may manage desired grants: the Vault owner, or an owner/admin of the
/// organization the Vault is attached to. Anyone else gets 404.
async fn grant_manager_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    user_id: &str,
) -> Result<(String, i64, bool), ApiError> {
    if !crate::is_canonical_uuid(vault_id) {
        return Err(ApiError::not_found());
    }
    let attachment: Option<(String, i64)> =
        sqlx::query_as("SELECT org_id,grants_revision FROM cloud_vault_orgs WHERE vault_id=?")
            .bind(vault_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    let vault_owner = vault_role_tx(tx, vault_id, user_id).await?.as_deref() == Some("owner");
    let Some((org_id, revision)) = attachment else {
        return Err(if vault_owner {
            ApiError::conflict("VAULT_NOT_IN_ORGANIZATION", "attach this Vault to an organization first")
        } else {
            ApiError::not_found()
        });
    };
    let org_role: Option<String> = sqlx::query_scalar("SELECT role FROM cloud_org_members WHERE org_id=? AND user_id=?")
        .bind(&org_id)
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let org_manager = org_role.as_deref().is_some_and(is_manager);
    if !vault_owner && !org_manager {
        return Err(ApiError::not_found());
    }
    Ok((org_id, revision, vault_owner))
}

pub async fn attach_vault(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Json(req): Json<AttachRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    if !is_manager(&org_role_tx(&mut tx, &req.org_id, &user.user_id).await?) {
        return Err(org_role_required());
    }
    let existing: Option<String> = sqlx::query_scalar("SELECT org_id FROM cloud_vault_orgs WHERE vault_id=?")
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    match existing {
        Some(org) if org == req.org_id => {}
        Some(_) => return Err(ApiError::conflict("VAULT_IN_OTHER_ORGANIZATION", "detach the Vault first")),
        None => {
            sqlx::query("INSERT INTO cloud_vault_orgs(vault_id,org_id,attached_by,attached_at) VALUES(?,?,?,?)")
                .bind(&vault_id)
                .bind(&req.org_id)
                .bind(&user.user_id)
                .bind(cloud::epoch_rfc3339(now))
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            cloud::audit_tx(&mut tx, cloud::AuditEntry::vault(&vault_id, "vault.attached_to_org").actor(&user.user_id).detail(format!("org_id={}", req.org_id)), now).await?;
            cloud::audit_tx(&mut tx, cloud::AuditEntry::org(&req.org_id, "org.vault_attached").actor(&user.user_id).detail(format!("vault_id={vault_id}")), now).await?;
        }
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"vault_id": vault_id, "org_id": req.org_id})))
}

pub async fn detach_vault(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    let deleted = sqlx::query("DELETE FROM cloud_vault_orgs WHERE vault_id=? RETURNING org_id")
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(row) = deleted else {
        return Err(ApiError::not_found());
    };
    reconcile_vault_tx(&mut tx, &vault_id, now).await?;
    let org_id: String = row.get("org_id");
    cloud::audit_tx(&mut tx, cloud::AuditEntry::vault(&vault_id, "vault.detached_from_org").actor(&user.user_id).detail(format!("org_id={org_id}")), now).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"detached": true})))
}

pub async fn list_grants(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = read_tx(&state, &user).await?;
    let (org_id, revision, vault_owner) = match grant_manager_tx(&mut tx, &vault_id, &user.user_id).await {
        Ok(value) => value,
        Err(error) if error.body.code == "VAULT_NOT_IN_ORGANIZATION" => {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(Json(json!({"vault_id": vault_id, "organization": null, "grants": []})));
        }
        Err(error) => return Err(error),
    };
    let org_name: String = sqlx::query_scalar("SELECT name FROM cloud_organizations WHERE org_id=?")
        .bind(&org_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let rows = sqlx::query(
        "SELECT g.principal_type,g.principal_id,g.role,COALESCE(u.username,t.name) AS name FROM cloud_vault_grants g LEFT JOIN users u ON g.principal_type='user' AND u.user_id=g.principal_id LEFT JOIN cloud_teams t ON g.principal_type='team' AND t.team_id=g.principal_id AND t.org_id=g.org_id WHERE g.vault_id=? ORDER BY g.principal_type,name",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({
        "vault_id": vault_id,
        "organization": {"org_id": org_id, "name": org_name},
        "grants_revision": revision,
        "caller_is_vault_owner": vault_owner,
        "grants": rows.iter().map(|row| json!({
            "principal_type": row.get::<String, _>("principal_type"),
            "principal_id": row.get::<String, _>("principal_id"),
            "role": row.get::<String, _>("role"),
            "name": row.get::<Option<String>, _>("name"),
        })).collect::<Vec<_>>(),
    })))
}

pub async fn set_grant(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, principal_type, principal_id)): Path<(String, String, String)>,
    Json(req): Json<GrantRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if !matches!(req.role.as_str(), "editor" | "viewer") {
        return Err(invalid("grant role must be editor or viewer"));
    }
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    let (org_id, revision, _) = grant_manager_tx(&mut tx, &vault_id, &user.user_id).await?;
    if revision != req.expected_grants_revision {
        return Err(ApiError::conflict("GRANTS_REVISION_CONFLICT", "grants changed; reload them"));
    }
    // The principal must belong to the Vault's organization; a team or user
    // of another organization is indistinguishable from an unknown ID.
    let valid_principal: bool = match principal_type.as_str() {
        "user" => sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM cloud_org_members WHERE org_id=? AND user_id=?)")
            .bind(&org_id)
            .bind(&principal_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?,
        "team" => sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM cloud_teams WHERE org_id=? AND team_id=?)")
            .bind(&org_id)
            .bind(&principal_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?,
        _ => false,
    };
    if !valid_principal {
        return Err(ApiError::not_found());
    }
    let owner: String = sqlx::query_scalar("SELECT owner_user_id FROM vaults WHERE vault_id=?")
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if principal_type == "user" && principal_id == owner {
        return Err(invalid("the Vault owner already has full access"));
    }
    sqlx::query(
        "INSERT INTO cloud_vault_grants(vault_id,org_id,principal_type,principal_id,role,granted_by,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?) \
         ON CONFLICT(vault_id,principal_type,principal_id) DO UPDATE SET role=excluded.role,granted_by=excluded.granted_by,updated_at=excluded.updated_at",
    )
    .bind(&vault_id)
    .bind(&org_id)
    .bind(&principal_type)
    .bind(&principal_id)
    .bind(&req.role)
    .bind(&user.user_id)
    .bind(cloud::epoch_rfc3339(now))
    .bind(cloud::epoch_rfc3339(now))
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query("UPDATE cloud_vault_orgs SET grants_revision=grants_revision+1 WHERE vault_id=?")
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    reconcile_vault_tx(&mut tx, &vault_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "vault.grant_set")
            .actor(&user.user_id)
            .detail(format!("principal={principal_type}:{principal_id} role={}", req.role)),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"grants_revision": revision + 1, "key_distribution": "pending_owner_confirmation"})))
}

pub async fn remove_grant(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, principal_type, principal_id)): Path<(String, String, String)>,
    Json(req): Json<RemoveGrantRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = write_tx(&state, &user).await?;
    let (_, revision, _) = grant_manager_tx(&mut tx, &vault_id, &user.user_id).await?;
    if revision != req.expected_grants_revision {
        return Err(ApiError::conflict("GRANTS_REVISION_CONFLICT", "grants changed; reload them"));
    }
    let deleted = sqlx::query("DELETE FROM cloud_vault_grants WHERE vault_id=? AND principal_type=? AND principal_id=?")
        .bind(&vault_id)
        .bind(&principal_type)
        .bind(&principal_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if deleted.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    sqlx::query("UPDATE cloud_vault_orgs SET grants_revision=grants_revision+1 WHERE vault_id=?")
        .bind(&vault_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    reconcile_vault_tx(&mut tx, &vault_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "vault.grant_removed")
            .actor(&user.user_id)
            .detail(format!("principal={principal_type}:{principal_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"grants_revision": revision + 1})))
}

// ---------------------------------------------------------------------------
// Key distribution
// ---------------------------------------------------------------------------

/// For the Vault owner only: who is desired but has no key yet, with their
/// published self-signed device cards, and which grant-derived members are
/// no longer covered (their removal requires the owner's key rotation).
pub async fn key_distribution(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = read_tx(&state, &user).await?;
    crate::share_gateway::require_owner_read_tx(&mut tx, &user.user_id, &vault_id).await?;
    let desired = desired_members_tx(&mut tx, &vault_id).await?;
    let members: std::collections::HashMap<String, (String, String)> = sqlx::query_as::<_, (String, String, String)>(
        "SELECT user_id,role,state FROM vault_members WHERE vault_id=?",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .into_iter()
    .map(|(id, role, state)| (id, (role, state)))
    .collect();
    let mut additions = Vec::new();
    for (user_id, (role, via)) in &desired {
        // Credential visibility: the owner's client warns before delivering a
        // key to an `admin_visible` account, because administrators can then
        // read the whole Vault.
        let account: Option<(String, String)> = sqlx::query_as(
            "SELECT username,credential_visibility FROM users WHERE user_id=? AND status='active'",
        )
        .bind(user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let Some((username, credential_visibility)) = account else {
            continue;
        };
        let current = members.get(user_id);
        let status = match current.map(|(_, state)| state.as_str()) {
            Some("active") => {
                if current.is_some_and(|(r, _)| r != role && r != "owner") {
                    "role_differs"
                } else {
                    continue;
                }
            }
            Some("invited") => {
                let delivered: bool = sqlx::query_scalar(
                    "SELECT EXISTS(SELECT 1 FROM cloud_key_deliveries d JOIN invitations i ON i.invitation_id=d.invitation_id WHERE d.vault_id=? AND d.recipient_user_id=? AND i.accepted_at IS NULL AND d.expires_epoch>?)",
                )
                .bind(&vault_id)
                .bind(user_id)
                .bind(now)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
                if delivered { "waiting_for_recipient" } else { "waiting_for_owner" }
            }
            _ => "waiting_for_owner",
        };
        let cards = sqlx::query(
            "SELECT c.device_id,c.card_json,c.published_at FROM cloud_device_cards c JOIN devices d ON d.device_id=c.device_id WHERE c.user_id=? AND d.status='active' ORDER BY c.published_at",
        )
        .bind(user_id)
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let status = if cards.is_empty() && status == "waiting_for_owner" { "waiting_for_device" } else { status };
        additions.push(json!({
            "user_id": user_id,
            "username": username,
            "desired_role": role,
            "via": via,
            "status": status,
            "admin_visible": credential_visibility == "admin_visible",
            "device_cards": cards.iter().map(|card| json!({
                "device_id": card.get::<String, _>("device_id"),
                "card": serde_json::from_str::<Value>(&card.get::<String, _>("card_json")).unwrap_or(Value::Null),
                "published_at": card.get::<String, _>("published_at"),
            })).collect::<Vec<_>>(),
        }));
    }
    let sourced: Vec<String> = sqlx::query_scalar(
        "SELECT s.user_id FROM cloud_vault_member_sources s JOIN vault_members vm ON vm.vault_id=s.vault_id AND vm.user_id=s.user_id WHERE s.vault_id=? AND vm.state IN ('active','invited')",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let mut removals = Vec::new();
    for user_id in sourced {
        if desired.contains_key(&user_id) {
            continue;
        }
        let username: Option<String> = sqlx::query_scalar("SELECT username FROM users WHERE user_id=?")
            .bind(&user_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        removals.push(json!({
            "user_id": user_id,
            "username": username,
            "state": members.get(&user_id).map(|(_, s)| s.clone()),
            // Access is already blocked by the server; the key-holder still
            // has to rotate the Vault key to remove the member cryptographically.
            "server_access": "blocked",
        }));
    }
    let downgrades: Vec<(String, Option<String>)> = sqlx::query_as(
        "SELECT r.user_id,u.username FROM cloud_member_restrictions r JOIN vault_members vm ON vm.vault_id=r.vault_id AND vm.user_id=r.user_id LEFT JOIN users u ON u.user_id=r.user_id WHERE r.vault_id=? AND r.max_role='viewer' AND vm.role='editor' AND vm.state='active'",
    )
    .bind(&vault_id)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    let rotation_required = !removals.is_empty();
    Ok(Json(json!({
        "vault_id": vault_id,
        "pending_additions": additions,
        "pending_removals": removals,
        "restricted_to_viewer": downgrades.iter().map(|(id, name)| json!({"user_id": id, "username": name})).collect::<Vec<_>>(),
        "rotation_required": rotation_required,
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeliveryRequest {
    invitation_id: String,
    recipient_device_id: String,
    sealed_token: String,
}

/// Records a Vault invitation token that the owner's client sealed to the
/// recipient device. Only for grantees; direct invitations stay out-of-band.
pub async fn create_delivery(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(vault_id): Path<String>,
    Json(req): Json<DeliveryRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    if req.sealed_token.is_empty()
        || req.sealed_token.len() > MAX_SEALED_TOKEN_CHARS
        || !req.sealed_token.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
    {
        return Err(invalid("sealed_token must be bounded base64url"));
    }
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    let invitation = sqlx::query(
        "SELECT recipient_user_id,recipient_device_id,created_by,expires_at,accepted_at FROM invitations WHERE invitation_id=? AND vault_id=?",
    )
    .bind(&req.invitation_id)
    .bind(&vault_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(ApiError::not_found)?;
    let recipient_user: Option<String> = invitation.get("recipient_user_id");
    let recipient_device: Option<String> = invitation.get("recipient_device_id");
    let created_by: String = invitation.get("created_by");
    let accepted: Option<String> = invitation.get("accepted_at");
    let expires = cloud::parse_rfc3339_epoch(&invitation.get::<String, _>("expires_at")).unwrap_or(0);
    if recipient_device.as_deref() != Some(req.recipient_device_id.as_str())
        || created_by != user.user_id
        || accepted.is_some()
        || expires <= now
    {
        return Err(ApiError::not_found());
    }
    let recipient_user = recipient_user.ok_or_else(ApiError::not_found)?;
    if !desired_members_tx(&mut tx, &vault_id).await?.contains_key(&recipient_user) {
        return Err(ApiError::forbidden(
            "GRANT_REQUIRED",
            "key deliveries are only for members with an organization grant",
        ));
    }
    let delivery_id = uuid::Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO cloud_key_deliveries(delivery_id,vault_id,invitation_id,recipient_user_id,recipient_device_id,sealed_token,created_by,created_epoch,expires_epoch) VALUES(?,?,?,?,?,?,?,?,?)",
    )
    .bind(&delivery_id)
    .bind(&vault_id)
    .bind(&req.invitation_id)
    .bind(&recipient_user)
    .bind(&req.recipient_device_id)
    .bind(&req.sealed_token)
    .bind(&user.user_id)
    .bind(now)
    .bind(expires)
    .execute(&mut *tx)
    .await
    .map_err(|_| ApiError::conflict("DELIVERY_EXISTS", "this invitation was already delivered"))?;
    sqlx::query("INSERT OR IGNORE INTO cloud_vault_member_sources(vault_id,user_id,created_epoch) VALUES(?,?,?)")
        .bind(&vault_id)
        .bind(&recipient_user)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    reconcile_vault_tx(&mut tx, &vault_id, now).await?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "vault.key_delivery_created")
            .actor(&user.user_id)
            .detail(format!("recipient_user_id={recipient_user} recipient_device_id={}", req.recipient_device_id)),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(json!({"delivery_id": delivery_id}))))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceCardRequest {
    card: Value,
}

/// Publishes the caller device's own signed share card (public keys only).
pub async fn publish_device_card(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<DeviceCardRequest>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let card = &req.card;
    let invalid_card = || ApiError::invalid_envelope("device card is invalid");
    if card.get("format").and_then(Value::as_str) != Some("atermius-vault-share-request-v1")
        || card.get("account_id").and_then(Value::as_str) != Some(user.user_id.as_str())
        || card.get("instance_id").and_then(Value::as_str) != Some(state.instance.instance_id.as_str())
    {
        return Err(invalid_card());
    }
    let device: crate::auth::DeviceInput =
        serde_json::from_value(card.get("device").cloned().ok_or_else(invalid_card)?).map_err(|_| invalid_card())?;
    if device.device_id != user.device_id {
        return Err(invalid_card());
    }
    let registered: Option<(String, String)> = sqlx::query_as(
        "SELECT signing_public_key,encryption_public_key FROM devices WHERE device_id=? AND user_id=? AND status='active'",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(ApiError::internal)?;
    let Some((signing, encryption)) = registered else {
        return Err(ApiError::forbidden("DEVICE_REVOKED", "device is not active"));
    };
    if device.signing_public_key != signing || device.encryption_public_key != encryption {
        return Err(invalid_card());
    }
    crate::auth::validate_device(&device, &user.user_id, &signing)?;
    let text = serde_json::to_string(card).map_err(ApiError::internal)?;
    if text.len() > 8192 {
        return Err(invalid_card());
    }
    let mut tx = write_tx(&state, &user).await?;
    sqlx::query(
        "INSERT INTO cloud_device_cards(device_id,user_id,card_json,published_at) VALUES(?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET card_json=excluded.card_json,published_at=excluded.published_at",
    )
    .bind(&user.device_id)
    .bind(&user.user_id)
    .bind(&text)
    .bind(crate::now_rfc3339())
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"published": true})))
}

pub async fn my_deliveries(State(state): State<AppState>, headers: HeaderMap) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = read_tx(&state, &user).await?;
    let rows = sqlx::query(
        "SELECT d.delivery_id,d.vault_id,d.invitation_id,d.sealed_token,d.expires_epoch,u.username AS owner FROM cloud_key_deliveries d JOIN invitations i ON i.invitation_id=d.invitation_id JOIN users u ON u.user_id=d.created_by WHERE d.recipient_user_id=? AND d.recipient_device_id=? AND d.opened_epoch IS NULL AND d.expires_epoch>? AND i.accepted_at IS NULL ORDER BY d.created_epoch",
    )
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(now)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"deliveries": rows.iter().map(|row| json!({
        "delivery_id": row.get::<String, _>("delivery_id"),
        "vault_id": row.get::<String, _>("vault_id"),
        "invitation_id": row.get::<String, _>("invitation_id"),
        "sealed_token": row.get::<String, _>("sealed_token"),
        "owner_username": row.get::<String, _>("owner"),
        "expires_at": cloud::epoch_rfc3339(row.get("expires_epoch")),
    })).collect::<Vec<_>>()})))
}

pub async fn mark_delivery_opened(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(delivery_id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let mut tx = write_tx(&state, &user).await?;
    let updated = sqlx::query(
        "UPDATE cloud_key_deliveries SET opened_epoch=?,sealed_token='' WHERE delivery_id=? AND recipient_user_id=? AND recipient_device_id=?",
    )
    .bind(cloud::now_epoch())
    .bind(&delivery_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"opened": true})))
}

/// The Vault owner deliberately keeps a grant-derived member as a direct
/// member: provenance is dropped and any server restriction lifted.
pub async fn make_direct(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path((vault_id, member_id)): Path<(String, String)>,
) -> Result<Json<Value>, ApiError> {
    require_ready(&state)?;
    let user = crate::current_user(&state, &headers).await?;
    let now = cloud::now_epoch();
    let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
    let (role, _, _) = crate::require_authenticated_vault_write_tx(&mut tx, &user, &vault_id).await?;
    if role != "owner" {
        return Err(ApiError::forbidden("VAULT_ROLE_REQUIRED", "owner role is required"));
    }
    let deleted = sqlx::query("DELETE FROM cloud_vault_member_sources WHERE vault_id=? AND user_id=?")
        .bind(&vault_id)
        .bind(&member_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if deleted.rows_affected() != 1 {
        return Err(ApiError::not_found());
    }
    sqlx::query("DELETE FROM cloud_member_restrictions WHERE vault_id=? AND user_id=?")
        .bind(&vault_id)
        .bind(&member_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    cloud::audit_tx(
        &mut tx,
        cloud::AuditEntry::vault(&vault_id, "vault.member_made_direct")
            .actor(&user.user_id)
            .detail(format!("user_id={member_id}")),
        now,
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"direct": true})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn organization_names_are_normalized_and_bounded() {
        assert_eq!(normalize_name("  Ｏps Team ").unwrap(), ("Ops Team".into(), "ops team".into()));
        assert!(normalize_name("").is_err());
        assert!(normalize_name(&"x".repeat(81)).is_err());
        assert!(normalize_name("bad\u{7}name").is_err());
    }
}

//! Shared PostgreSQL SSH Relay authorization and ticket storage.
//!
//! Tickets and group policy state live in PostgreSQL so every serving node
//! observes the same one-use and revocation decisions. Target destinations
//! are encrypted with the shared instance key and erased as soon as a ticket
//! is consumed.

use std::{collections::BTreeSet, net::IpAddr};

use axum::{
    Json,
    extract::{Path, State, rejection::JsonRejection},
    http::{HeaderMap, StatusCode},
};
use chrono::{DateTime, SecondsFormat, Utc};
use ipnet::IpNet;
use rand::RngCore;
use serde::Deserialize;
use serde_json::{Value, json};
use sqlx::{Postgres, Row, Transaction, postgres::PgRow};
use unicode_normalization::UnicodeNormalization;
use uuid::Uuid;

use crate::{
    ApiError, AppState,
    auth::AuthUser,
    relay::{self, EffectiveRelayPolicy, RelayPolicy, RelayPolicySnapshot, RelayTarget},
};

const LOCK_NAMESPACE: i32 = 0x4154_4552;
const LOCK_INSTANCE_POLICY: i32 = 1;
const LOCK_TICKET_CAPACITY: i32 = 2;
const LOCK_GROUP_CAPACITY: i32 = 3;
const MAX_GROUPS: i64 = 1_000;
const MAX_GROUP_MEMBERS: usize = 1_000;
const MAX_GROUP_NAME_CHARS: usize = 80;
const MAX_GROUP_NAME_BYTES: usize = 320;
const CONNECTION_LEASE_SECONDS: i64 = 10;

type PgTx<'a> = Transaction<'a, Postgres>;

fn pool(state: &AppState) -> Result<&sqlx::PgPool, ApiError> {
    state
        .pg_sync_pool
        .as_ref()
        .ok_or_else(|| ApiError::internal("PostgreSQL Relay repository is unavailable"))
}

async fn lock_shared(tx: &mut PgTx<'_>, key: i32) -> Result<(), ApiError> {
    sqlx::query("SELECT pg_advisory_xact_lock_shared($1,$2)")
        .bind(LOCK_NAMESPACE)
        .bind(key)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

async fn lock_exclusive(tx: &mut PgTx<'_>, key: i32) -> Result<(), ApiError> {
    sqlx::query("SELECT pg_advisory_xact_lock($1,$2)")
        .bind(LOCK_NAMESPACE)
        .bind(key)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

fn parse_policy_arrays(cidrs: String, ports: String) -> Result<(Vec<IpNet>, Vec<u16>), ApiError> {
    let cidr_values: Vec<String> = serde_json::from_str(&cidrs).map_err(ApiError::internal)?;
    let port_values: Vec<u16> = serde_json::from_str(&ports).map_err(ApiError::internal)?;
    let cidrs = relay::parse_stored_cidrs(cidr_values).map_err(ApiError::internal)?;
    relay::validate_stored_ports(&port_values).map_err(ApiError::internal)?;
    Ok((cidrs, port_values))
}

async fn instance_policy_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
) -> Result<RelayPolicySnapshot, ApiError> {
    let row = sqlx::query("SELECT enabled,allow_cidrs,allow_ports,revision,updated_at FROM instance_relay_policy WHERE policy_id=1")
        .fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Ok(RelayPolicySnapshot {
            policy: relay::default_policy(state),
            revision: 0,
            updated_at: None,
        });
    };
    let (allow_cidrs, allow_ports) = parse_policy_arrays(
        row.try_get("allow_cidrs").map_err(ApiError::internal)?,
        row.try_get("allow_ports").map_err(ApiError::internal)?,
    )?;
    let updated_at: DateTime<Utc> = row.try_get("updated_at").map_err(ApiError::internal)?;
    Ok(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled: row.try_get("enabled").map_err(ApiError::internal)?,
            allow_cidrs,
            allow_ports,
        },
        revision: row.try_get("revision").map_err(ApiError::internal)?,
        updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
    })
}

async fn instance_effective_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
) -> Result<EffectiveRelayPolicy, ApiError> {
    let snapshot = instance_policy_tx(tx, state).await?;
    let deployment_cidrs = relay::deployment_cidrs(state);
    let allow_cidrs = relay::normalize_networks(
        snapshot
            .policy
            .allow_cidrs
            .iter()
            .flat_map(|configured| {
                deployment_cidrs
                    .iter()
                    .filter_map(|ceiling| relay::intersect_network(*configured, *ceiling))
            })
            .collect(),
    );
    let deployment_ports = relay::deployment_ports(state);
    let allow_ports = snapshot
        .policy
        .allow_ports
        .iter()
        .copied()
        .filter(|port| deployment_ports.contains(port))
        .collect();
    Ok(EffectiveRelayPolicy {
        enabled: snapshot.policy.enabled && relay::relay_available(state),
        allow_cidrs,
        allow_ports,
    })
}

pub(crate) async fn overview_tx(tx: &mut PgTx<'_>, state: &AppState) -> Result<Value, ApiError> {
    let policy = instance_effective_tx(tx, state).await?;
    Ok(
        json!({"enabled":policy.enabled,"allow_cidrs":policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),"allow_ports":policy.allow_ports,"max_connections_per_user":state.config.relay_max_connections_per_user}),
    )
}

async fn user_policy_tx(
    tx: &mut PgTx<'_>,
    user_id: &str,
) -> Result<Option<RelayPolicySnapshot>, ApiError> {
    let row = sqlx::query("SELECT enabled,allow_cidrs,allow_ports,revision,updated_at FROM user_relay_policies WHERE user_id=$1")
        .bind(user_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else { return Ok(None) };
    let (allow_cidrs, allow_ports) = parse_policy_arrays(
        row.try_get("allow_cidrs").map_err(ApiError::internal)?,
        row.try_get("allow_ports").map_err(ApiError::internal)?,
    )?;
    let revision: i64 = row.try_get("revision").map_err(ApiError::internal)?;
    let updated_at: DateTime<Utc> = row.try_get("updated_at").map_err(ApiError::internal)?;
    let watermark: Option<(i64, DateTime<Utc>)> = sqlx::query_as::<_, (i64, DateTime<Utc>)>(
        "SELECT revision,updated_at FROM user_relay_policy_revisions WHERE user_id=$1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if !watermark.is_some_and(|(version, time)| version == revision && time == updated_at) {
        return Err(ApiError::internal(
            "Relay user policy version watermark does not match override row",
        ));
    }
    Ok(Some(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled: row.try_get("enabled").map_err(ApiError::internal)?,
            allow_cidrs,
            allow_ports,
        },
        revision,
        updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
    }))
}

async fn user_policy_version_tx(
    tx: &mut PgTx<'_>,
    user_id: &str,
    policy: Option<&RelayPolicySnapshot>,
) -> Result<(i64, Option<String>), ApiError> {
    let watermark: Option<(i64, DateTime<Utc>)> = sqlx::query_as::<_, (i64, DateTime<Utc>)>(
        "SELECT revision,updated_at FROM user_relay_policy_revisions WHERE user_id=$1",
    )
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    match (policy, watermark) {
        (Some(policy), Some((revision, updated_at)))
            if revision == policy.revision
                && policy.updated_at.as_deref()
                    == Some(
                        updated_at
                            .to_rfc3339_opts(SecondsFormat::Millis, true)
                            .as_str(),
                    ) =>
        {
            Ok((
                revision,
                Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
            ))
        }
        (Some(_), _) => Err(ApiError::internal(
            "Relay user policy version watermark does not match override row",
        )),
        (None, Some((revision, updated_at))) => Ok((
            revision,
            Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
        )),
        (None, None) => Ok((0, None)),
    }
}

async fn group_policy_tx(
    tx: &mut PgTx<'_>,
    group_id: &str,
) -> Result<Option<RelayPolicySnapshot>, ApiError> {
    let row = sqlx::query("SELECT enabled,allow_cidrs,allow_ports,revision,updated_at FROM relay_access_group_relay_policies WHERE group_id=$1")
        .bind(group_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else { return Ok(None) };
    let (allow_cidrs, allow_ports) = parse_policy_arrays(
        row.try_get("allow_cidrs").map_err(ApiError::internal)?,
        row.try_get("allow_ports").map_err(ApiError::internal)?,
    )?;
    let revision: i64 = row.try_get("revision").map_err(ApiError::internal)?;
    let updated_at: DateTime<Utc> = row.try_get("updated_at").map_err(ApiError::internal)?;
    let watermark: Option<(i64, DateTime<Utc>)> = sqlx::query_as("SELECT revision,updated_at FROM relay_access_group_relay_policy_revisions WHERE group_id=$1")
        .bind(group_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    if !watermark.is_some_and(|(version, time)| version == revision && time == updated_at) {
        return Err(ApiError::internal(
            "Relay group policy version watermark does not match override row",
        ));
    }
    Ok(Some(RelayPolicySnapshot {
        policy: RelayPolicy {
            enabled: row.try_get("enabled").map_err(ApiError::internal)?,
            allow_cidrs,
            allow_ports,
        },
        revision,
        updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
    }))
}

async fn authorization_revision_tx(tx: &mut PgTx<'_>, user_id: &str) -> Result<i64, ApiError> {
    sqlx::query_scalar("SELECT revision FROM relay_user_authorization_versions WHERE user_id=$1")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map(|v| v.unwrap_or(0))
        .map_err(ApiError::internal)
}

async fn effective_policy_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    user_id: &str,
) -> Result<EffectiveRelayPolicy, ApiError> {
    let instance = instance_effective_tx(tx, state).await?;
    let mut effective = if let Some(user) = user_policy_tx(tx, user_id).await? {
        relay::restrict_effective_policy(&instance, &user.policy)
    } else {
        instance
    };
    let rows = sqlx::query("SELECT p.enabled,p.allow_cidrs,p.allow_ports,p.revision,p.updated_at,pr.revision AS watermark_revision,pr.updated_at AS watermark_updated_at FROM relay_access_group_members m JOIN relay_access_group_relay_policies p ON p.group_id=m.group_id LEFT JOIN relay_access_group_relay_policy_revisions pr ON pr.group_id=p.group_id WHERE m.user_id=$1 ORDER BY m.group_id")
        .bind(user_id).fetch_all(&mut **tx).await.map_err(ApiError::internal)?;
    for row in rows {
        let revision: i64 = row.try_get("revision").map_err(ApiError::internal)?;
        let updated_at: DateTime<Utc> = row.try_get("updated_at").map_err(ApiError::internal)?;
        let watermark_revision: Option<i64> = row
            .try_get("watermark_revision")
            .map_err(ApiError::internal)?;
        let watermark_updated_at: Option<DateTime<Utc>> = row
            .try_get("watermark_updated_at")
            .map_err(ApiError::internal)?;
        if watermark_revision != Some(revision) || watermark_updated_at != Some(updated_at) {
            return Err(ApiError::internal(
                "Relay group policy version watermark does not match override row",
            ));
        }
        let (allow_cidrs, allow_ports) = parse_policy_arrays(
            row.try_get("allow_cidrs").map_err(ApiError::internal)?,
            row.try_get("allow_ports").map_err(ApiError::internal)?,
        )?;
        let restriction = RelayPolicy {
            enabled: row.try_get("enabled").map_err(ApiError::internal)?,
            allow_cidrs,
            allow_ports,
        };
        effective = relay::restrict_effective_policy(&effective, &restriction);
    }
    Ok(effective)
}

pub(crate) async fn effective_policy_for_user(
    state: &AppState,
    user_id: &str,
) -> Result<EffectiveRelayPolicy, ApiError> {
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let policy = effective_policy_tx(&mut tx, state, user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(policy)
}

pub(crate) async fn ensure_active_device(
    state: &AppState,
    user_id: &str,
    device_id: &str,
) -> Result<(), ApiError> {
    let active: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM devices WHERE device_id=$1 AND user_id=$2 AND status='active')")
        .bind(device_id).bind(user_id).fetch_one(pool(state)?).await.map_err(ApiError::internal)?;
    if active {
        Ok(())
    } else {
        Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ))
    }
}

pub(crate) async fn issue_ticket(
    state: &AppState,
    user_id: &str,
    device_id: &str,
    session_id: &str,
    access_hash: &str,
    ip: IpAddr,
    port: u16,
) -> Result<(String, String), ApiError> {
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let session: Option<(DateTime<Utc>, DateTime<Utc>)> = sqlx::query_as(
        "SELECT s.access_expires_at,s.refresh_expires_at FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4 AND s.revoked_at IS NULL AND s.access_expires_at>clock_timestamp() AND s.refresh_expires_at>clock_timestamp() AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
        .bind(session_id).bind(user_id).bind(device_id).bind(access_hash).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some((access_expiry, refresh_expiry)) = session else {
        return Err(ApiError::unauthorized());
    };
    lock_shared(&mut tx, LOCK_INSTANCE_POLICY).await?;
    let policy = effective_policy_tx(&mut tx, state, user_id).await?;
    if !policy.enabled {
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_DISABLED",
            "relay is disabled by instance policy",
        ));
    }
    if !relay::effective_target_allowed(&policy, ip, port) {
        return Err(ApiError::forbidden(
            "TARGET_DENIED",
            "target is outside the configured relay policy",
        ));
    }
    let authorization_revision = authorization_revision_tx(&mut tx, user_id).await?;
    lock_exclusive(&mut tx, LOCK_TICKET_CAPACITY).await?;
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let cutoff = now - chrono::Duration::seconds(relay::TICKET_RATE_WINDOW_SECONDS);
    sqlx::query("DELETE FROM relay_tickets WHERE created_at <= $1")
        .bind(cutoff)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let (issued, oldest): (i64, Option<i64>) = sqlx::query_as("SELECT COUNT(*),floor(extract(epoch FROM MIN(created_at)))::BIGINT FROM relay_tickets WHERE user_id=$1 AND created_at>$2")
        .bind(user_id).bind(cutoff).fetch_one(&mut *tx).await.map_err(ApiError::internal)?;
    if issued >= relay::MAX_TICKETS_PER_USER_PER_WINDOW {
        let oldest = oldest;
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(relay::relay_rate_limit_error(oldest, now.timestamp()));
    }
    let retained: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM relay_tickets")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    if retained >= relay::MAX_RETAINED_TICKETS {
        tx.commit().await.map_err(ApiError::internal)?;
        return Err(ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "RELAY_BUSY",
            "relay ticket capacity is temporarily full",
        ));
    }
    let expires_at = (now + chrono::Duration::seconds(relay::TICKET_TTL_SECONDS))
        .min(access_expiry)
        .min(refresh_expiry);
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let ticket = base64::Engine::encode(&base64::engine::general_purpose::URL_SAFE_NO_PAD, raw);
    let ticket_hash = crate::sha256_hex(ticket.as_bytes());
    let target_envelope = relay::encrypt_relay_destination(state, &ticket_hash, ip, port)?;
    sqlx::query("INSERT INTO relay_tickets(ticket_hash,user_id,device_id,session_id,session_access_expires_at,target_envelope,expires_at,consumed_at,created_at,authorization_revision) VALUES($1,$2,$3,$4,$5,$6,$7,NULL,$8,$9)")
        .bind(&ticket_hash).bind(user_id).bind(device_id).bind(session_id).bind(access_expiry).bind(target_envelope).bind(expires_at).bind(now).bind(authorization_revision)
        .execute(&mut *tx).await.map_err(ApiError::internal)?;
    record_account_event_tx(
        &mut tx,
        state,
        user_id,
        Some(device_id),
        "relay.ticket_issued",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((
        ticket,
        expires_at.to_rfc3339_opts(SecondsFormat::Millis, true),
    ))
}

pub(crate) async fn consume_ticket(
    state: &AppState,
    token: &str,
) -> Result<Option<RelayTarget>, ApiError> {
    if !relay::is_valid_ticket(token) {
        return Ok(None);
    }
    let ticket_hash = crate::sha256_hex(token.as_bytes());
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    lock_shared(&mut tx, LOCK_INSTANCE_POLICY).await?;
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let row = sqlx::query("UPDATE relay_tickets SET consumed_at=$1 WHERE ticket_hash=$2 AND consumed_at IS NULL AND expires_at>$1 AND session_access_expires_at>$1 AND target_envelope LIKE 'rtd1:%' AND EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=relay_tickets.session_id AND s.user_id=relay_tickets.user_id AND s.device_id=relay_tickets.device_id AND s.access_expires_at=relay_tickets.session_access_expires_at AND s.access_expires_at>$1 AND s.refresh_expires_at>$1 AND s.revoked_at IS NULL AND u.status='active' AND d.status='active') RETURNING user_id,device_id,session_id,target_envelope,authorization_revision")
        .bind(now).bind(&ticket_hash).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    let Some(row) = row else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let envelope: String = row.try_get("target_envelope").map_err(ApiError::internal)?;
    sqlx::query("UPDATE relay_tickets SET target_envelope='' WHERE ticket_hash=$1")
        .bind(&ticket_hash)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
    let device_id: String = row.try_get("device_id").map_err(ApiError::internal)?;
    let session_id: String = row.try_get("session_id").map_err(ApiError::internal)?;
    let authorization_revision: i64 = row
        .try_get("authorization_revision")
        .map_err(ApiError::internal)?;
    let current_revision = authorization_revision_tx(&mut tx, &user_id).await?;
    let policy = effective_policy_tx(&mut tx, state, &user_id).await?;
    let destination = relay::decrypt_relay_destination(state, &ticket_hash, &envelope).ok();
    tx.commit().await.map_err(ApiError::internal)?;
    let Some((ip, port)) = destination.filter(|(ip, port)| {
        authorization_revision == current_revision
            && relay::effective_target_allowed(&policy, *ip, *port)
    }) else {
        return Ok(None);
    };
    Ok(Some(RelayTarget {
        user_id,
        device_id,
        session_id,
        ip,
        port,
        authorization_revision,
        connection_id: None,
    }))
}

pub(crate) async fn relay_session_active(state: &AppState, target: &RelayTarget) -> bool {
    let Ok(pg) = pool(state) else { return false };
    let active: Result<bool, _> = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.refresh_expires_at>clock_timestamp() AND s.revoked_at IS NULL AND u.status='active' AND d.status='active')")
        .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_one(pg).await;
    match active {
        Ok(value) => value,
        Err(_) => {
            tracing::warn!(event = "relay_session_state_check_failed");
            false
        }
    }
}

pub(crate) async fn relay_connection_active(state: &AppState, target: &RelayTarget) -> bool {
    let Ok(pg) = pool(state) else { return false };
    let result = async {
        let mut tx = pg.begin().await.map_err(ApiError::internal)?;
        let active_session: Option<String> = sqlx::query_scalar("SELECT s.session_id FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.refresh_expires_at>clock_timestamp() AND s.revoked_at IS NULL AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
            .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
        if active_session.is_none() { tx.commit().await.map_err(ApiError::internal)?; return Ok::<bool,ApiError>(false) }
        lock_shared(&mut tx,LOCK_INSTANCE_POLICY).await?;
        let policy = effective_policy_tx(&mut tx,state,&target.user_id).await?;
        let revision = authorization_revision_tx(&mut tx,&target.user_id).await?;
        if revision != target.authorization_revision || !relay::effective_target_allowed(&policy,target.ip,target.port) {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok::<bool,ApiError>(false)
        }
        if let Some(connection_id)=target.connection_id {
            let renewed=sqlx::query("UPDATE relay_connection_leases SET heartbeat_at=clock_timestamp(),lease_expires_at=clock_timestamp()+($2 * INTERVAL '1 second') WHERE connection_id=$1 AND user_id=$3 AND lease_expires_at>clock_timestamp()")
                .bind(connection_id).bind(CONNECTION_LEASE_SECONDS).bind(&target.user_id).execute(&mut *tx).await.map_err(ApiError::internal)?;
            if renewed.rows_affected()!=1 { tx.commit().await.map_err(ApiError::internal)?; return Ok(false) }
        }
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(true)
    }.await;
    match result {
        Ok(active) => active,
        Err(_) => {
            tracing::warn!(event = "relay_policy_state_check_failed");
            false
        }
    }
}

pub(crate) async fn record_connected(
    state: &AppState,
    target: &RelayTarget,
    connection_id: Uuid,
) -> Result<bool, ApiError> {
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    let session: Option<String>=sqlx::query_scalar("SELECT s.session_id FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.revoked_at IS NULL AND s.refresh_expires_at>clock_timestamp() AND u.status='active' AND d.status='active' FOR SHARE OF s,u,d")
        .bind(&target.session_id).bind(&target.user_id).bind(&target.device_id).fetch_optional(&mut *tx).await.map_err(ApiError::internal)?;
    if session.is_none() {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    lock_shared(&mut tx, LOCK_INSTANCE_POLICY).await?;
    let revision = authorization_revision_tx(&mut tx, &target.user_id).await?;
    let policy = effective_policy_tx(&mut tx, state, &target.user_id).await?;
    if revision != target.authorization_revision
        || !relay::effective_target_allowed(&policy, target.ip, target.port)
    {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    // Serialize cluster-wide admission so simultaneous sockets cannot exceed
    // the configured per-user or fixed instance cap across serving nodes.
    lock_exclusive(&mut tx, LOCK_TICKET_CAPACITY).await?;
    sqlx::query("DELETE FROM relay_connection_leases WHERE lease_expires_at<=clock_timestamp()")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let (user_count,total_count):(i64,i64)=sqlx::query_as("SELECT (SELECT COUNT(*) FROM relay_connection_leases WHERE user_id=$1 AND lease_expires_at>clock_timestamp()),(SELECT COUNT(*) FROM relay_connection_leases WHERE lease_expires_at>clock_timestamp())")
        .bind(&target.user_id).fetch_one(&mut *tx).await.map_err(ApiError::internal)?;
    let user_limit = i64::try_from(state.config.relay_max_connections_per_user).unwrap_or(i64::MAX);
    if user_count >= user_limit || total_count >= relay::MAX_GLOBAL_RELAY_CONNECTIONS as i64 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    let inserted=sqlx::query("INSERT INTO relay_connection_leases(connection_id,node_id,user_id,device_id,session_id,session_access_expires_at,authorization_revision,created_at,heartbeat_at,lease_expires_at) SELECT $1,$2,$3,$4,$5,s.access_expires_at,$6,clock_timestamp(),clock_timestamp(),clock_timestamp()+($7 * INTERVAL '1 second') FROM sessions s WHERE s.session_id=$5 AND s.user_id=$3 AND s.device_id=$4 AND s.revoked_at IS NULL AND s.refresh_expires_at>clock_timestamp()")
        .bind(connection_id).bind(state.pg_relay_node_id).bind(&target.user_id).bind(&target.device_id).bind(&target.session_id).bind(revision).bind(CONNECTION_LEASE_SECONDS).execute(&mut *tx).await.map_err(ApiError::internal)?;
    if inserted.rows_affected() != 1 {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(false);
    }
    record_account_event_tx(
        &mut tx,
        state,
        &target.user_id,
        Some(&target.device_id),
        "relay.connected",
    )
    .await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(true)
}

pub(crate) async fn release_connection_lease(state: &AppState, connection_id: Uuid) {
    if let Ok(pg) = pool(state) {
        if sqlx::query("DELETE FROM relay_connection_leases WHERE connection_id=$1 AND node_id=$2")
            .bind(connection_id)
            .bind(state.pg_relay_node_id)
            .execute(pg)
            .await
            .is_err()
        {
            tracing::warn!(event = "relay_connection_lease_release_failed");
        }
    }
}

async fn record_account_event_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    user_id: &str,
    device_id: Option<&str>,
    action: &str,
) -> Result<(), ApiError> {
    let scope = crate::audit::account_scope_id(&state.cursor_key, user_id)?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('account',$1,$2,$3,$4,'relay',NULL,'success',$5,'api')")
        .bind(scope).bind(user_id).bind(device_id).bind(action).bind(occurred_at).execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn record_admin_event_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    actor: &AuthUser,
    action: &str,
    resource_type: &str,
    resource_id: Option<&str>,
) -> Result<(), ApiError> {
    let scope = crate::audit::instance_scope_id(&state.cursor_key, &state.instance.instance_id)?;
    let resource_id = resource_id
        .map(|id| crate::audit::instance_resource_id(&state.cursor_key, resource_type, id))
        .transpose()?;
    let occurred_at: i64 =
        sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('instance',$1,$2,$3,$4,$5,$6,'success',$7,'api')")
        .bind(scope).bind(&actor.user_id).bind(&actor.device_id).bind(action).bind(resource_type).bind(resource_id).bind(occurred_at).execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn admin_tx<'a>(
    state: &'a AppState,
    headers: &HeaderMap,
) -> Result<(AuthUser, PgTx<'a>), ApiError> {
    let actor = crate::current_user(state, headers).await?;
    let mut tx = pool(state)?.begin().await.map_err(ApiError::internal)?;
    crate::pg_admin_jobs::require_instance_admin_tx(
        &mut tx,
        state,
        &actor,
        &state.config.admin_usernames,
    )
    .await?;
    Ok((actor, tx))
}

fn policy_json(policy: &RelayPolicy) -> Value {
    json!({"enabled":policy.enabled,"allow_cidrs":policy.allow_cidrs.iter().map(ToString::to_string).collect::<Vec<_>>(),"allow_ports":policy.allow_ports})
}

fn effective_policy_json(policy: &EffectiveRelayPolicy) -> Value {
    policy_json(&RelayPolicy {
        enabled: policy.enabled,
        allow_cidrs: policy.allow_cidrs.clone(),
        allow_ports: policy.allow_ports.clone(),
    })
}

fn admin_instance_policy_json(state: &AppState, snapshot: RelayPolicySnapshot) -> Value {
    json!({
        "policy":policy_json(&snapshot.policy),
        "deployment_limits":{"relay_available":relay::relay_available(state),"allow_cidrs":relay::deployment_cidrs(state).iter().map(ToString::to_string).collect::<Vec<_>>(),"allow_ports":relay::deployment_ports(state)},
        "max_connections_per_user":state.config.relay_max_connections_per_user,
        "revision":snapshot.revision,"updated_at":snapshot.updated_at
    })
}

fn admin_user_policy_json(
    user_id: &str,
    instance: RelayPolicySnapshot,
    user: Option<RelayPolicySnapshot>,
    effective: EffectiveRelayPolicy,
    revision: i64,
    updated_at: Option<String>,
) -> Value {
    let inherited = user.is_none();
    let selected = user
        .as_ref()
        .map(|entry| &entry.policy)
        .unwrap_or(&instance.policy);
    json!({"user_id":user_id,"inherited":inherited,"policy":policy_json(selected),"effective_policy":effective_policy_json(&effective),"instance_policy_revision":instance.revision,"revision":revision,"updated_at":updated_at})
}

fn invalid_policy(code: &'static str, message: &'static str) -> ApiError {
    ApiError::bad_request(code, message)
}

fn parse_policy(
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
    code: &'static str,
    message: &'static str,
) -> Result<RelayPolicy, ApiError> {
    relay::parse_group_policy_fields(enabled, allow_cidrs, allow_ports)
        .map_err(|_| invalid_policy(code, message))
}

fn validate_instance_policy(policy: &RelayPolicy, state: &AppState) -> Result<(), ApiError> {
    if policy.enabled && !relay::relay_available(state) {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_POLICY_UNAVAILABLE",
            "relay cannot be enabled while deployment limits make it unavailable",
        ));
    }
    if policy.allow_cidrs.iter().any(|requested| {
        !state
            .config
            .relay_allow_cidrs
            .iter()
            .any(|ceiling| relay::is_network_within(*requested, *ceiling))
    }) || policy
        .allow_ports
        .iter()
        .any(|port| !state.config.relay_allow_ports.contains(port))
    {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_POLICY_OUTSIDE_LIMITS",
            "relay policy must be contained by deployment limits",
        ));
    }
    Ok(())
}

async fn write_user_policy_version_tx(
    tx: &mut PgTx<'_>,
    user_id: &str,
    revision: i64,
    updated_at: DateTime<Utc>,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO user_relay_policy_revisions(user_id,revision,updated_at) VALUES($1,$2,$3) ON CONFLICT(user_id) DO UPDATE SET revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at")
        .bind(user_id).bind(revision).bind(updated_at).execute(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(())
}

async fn invalidate_user_tickets_tx(tx: &mut PgTx<'_>, user_id: &str) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM relay_tickets WHERE user_id=$1 AND consumed_at IS NULL")
        .bind(user_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct InstancePolicyRequest {
    expected_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UserPolicyRequest {
    expected_revision: i64,
    expected_instance_policy_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PolicyResetRequest {
    expected_revision: i64,
}

pub(crate) async fn get_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    let response = admin_instance_policy_json(&state, instance_policy_tx(&mut tx, &state).await?);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn update_admin_policy(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<InstancePolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(request)=request.map_err(|_|invalid_policy("INVALID_RELAY_POLICY_REQUEST","body must contain only expected_revision, enabled, allow_cidrs, and allow_ports with bounded canonical values"))?;
    if request.expected_revision < 0 {
        return Err(invalid_policy(
            "INVALID_RELAY_POLICY_REQUEST",
            "expected_revision must be nonnegative",
        ));
    }
    let candidate = parse_policy(
        request.enabled,
        request.allow_cidrs,
        request.allow_ports,
        "INVALID_RELAY_POLICY_REQUEST",
        "body must contain only expected_revision, enabled, allow_cidrs, and allow_ports with bounded canonical values",
    )?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    lock_exclusive(&mut tx, LOCK_INSTANCE_POLICY).await?;
    let current = instance_policy_tx(&mut tx, &state).await?;
    if current.revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_POLICY_CONFLICT",
            "relay policy changed since it was read",
        ));
    }
    validate_instance_policy(&candidate, &state)?;
    let snapshot = if candidate != current.policy {
        let revision = current
            .revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay policy revision overflowed"))?;
        let updated_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let cidrs = serde_json::to_string(
            &candidate
                .allow_cidrs
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
        )
        .map_err(ApiError::internal)?;
        let ports = serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO instance_relay_policy(policy_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES(1,$1,$2,$3,$4,$5) ON CONFLICT(policy_id) DO UPDATE SET enabled=EXCLUDED.enabled,allow_cidrs=EXCLUDED.allow_cidrs,allow_ports=EXCLUDED.allow_ports,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at")
            .bind(candidate.enabled).bind(cidrs).bind(ports).bind(revision).bind(updated_at).execute(&mut *tx).await.map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM relay_tickets WHERE consumed_at IS NULL")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        record_admin_event_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_policy_updated",
            "relay_policy",
            None,
        )
        .await?;
        RelayPolicySnapshot {
            policy: candidate,
            revision,
            updated_at: Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
        }
    } else {
        current
    };
    let response = admin_instance_policy_json(&state, snapshot);
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

async fn require_policy_user_tx(tx: &mut PgTx<'_>, user_id: &str) -> Result<(), ApiError> {
    let exists: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE user_id=$1)")
        .bind(user_id)
        .fetch_one(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if exists {
        Ok(())
    } else {
        Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "RELAY_USER_NOT_FOUND",
            "relay policy account does not exist",
        ))
    }
}

async fn admin_user_policy_response(
    tx: &mut PgTx<'_>,
    state: &AppState,
    user_id: &str,
) -> Result<Value, ApiError> {
    let instance = instance_policy_tx(tx, state).await?;
    let user = user_policy_tx(tx, user_id).await?;
    let (revision, updated_at) = user_policy_version_tx(tx, user_id, user.as_ref()).await?;
    let effective = effective_policy_tx(tx, state, user_id).await?;
    Ok(admin_user_policy_json(
        user_id, instance, user, effective, revision, updated_at,
    ))
}

pub(crate) async fn get_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    require_policy_user_tx(&mut tx, &user_id).await?;
    let response = admin_user_policy_response(&mut tx, &state, &user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn update_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<UserPolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(request)=request.map_err(|_|invalid_policy("INVALID_RELAY_USER_POLICY_REQUEST","body must contain only expected revisions, enabled, allow_cidrs, and allow_ports with bounded canonical values"))?;
    if request.expected_revision < 0 || request.expected_instance_policy_revision < 0 {
        return Err(invalid_policy(
            "INVALID_RELAY_USER_POLICY_REQUEST",
            "expected revisions must be nonnegative",
        ));
    }
    let expected_revision = request.expected_revision;
    let expected_instance_revision = request.expected_instance_policy_revision;
    let candidate = parse_policy(
        request.enabled,
        request.allow_cidrs,
        request.allow_ports,
        "INVALID_RELAY_USER_POLICY_REQUEST",
        "body must contain only expected revisions, enabled, allow_cidrs, and allow_ports with bounded canonical values",
    )?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    lock_shared(&mut tx, LOCK_INSTANCE_POLICY).await?;
    require_policy_user_tx(&mut tx, &user_id).await?;
    sqlx::query("SELECT user_id FROM users WHERE user_id=$1 FOR UPDATE")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let instance = instance_policy_tx(&mut tx, &state).await?;
    if expected_instance_revision != instance.revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "instance relay policy changed since it was read",
        ));
    }
    let current = user_policy_tx(&mut tx, &user_id).await?;
    let (current_revision, _) = user_policy_version_tx(&mut tx, &user_id, current.as_ref()).await?;
    if expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "relay user policy changed since it was read",
        ));
    }
    let inherited = current
        .as_ref()
        .map(|value| &value.policy)
        .unwrap_or(&instance.policy);
    if candidate != *inherited {
        let instance_effective = instance_effective_tx(&mut tx, &state).await?;
        relay::validate_user_policy_limits(&candidate, &instance_effective)?;
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay user policy revision overflowed"))?;
        let updated_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let cidrs = serde_json::to_string(
            &candidate
                .allow_cidrs
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
        )
        .map_err(ApiError::internal)?;
        let ports = serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO user_relay_policies(user_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(user_id) DO UPDATE SET enabled=EXCLUDED.enabled,allow_cidrs=EXCLUDED.allow_cidrs,allow_ports=EXCLUDED.allow_ports,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at")
            .bind(&user_id).bind(candidate.enabled).bind(cidrs).bind(ports).bind(revision).bind(updated_at).execute(&mut *tx).await.map_err(ApiError::internal)?;
        write_user_policy_version_tx(&mut tx, &user_id, revision, updated_at).await?;
        invalidate_user_tickets_tx(&mut tx, &user_id).await?;
        record_admin_event_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_policy_updated",
            "relay_user_policy",
            Some(&user_id),
        )
        .await?;
    }
    let response = admin_user_policy_response(&mut tx, &state, &user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn reset_admin_user_policy(
    State(state): State<AppState>,
    Path(user_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<PolicyResetRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    let Json(request) = request.map_err(|_| {
        invalid_policy(
            "INVALID_RELAY_USER_POLICY_RESET_REQUEST",
            "body must contain only expected_revision",
        )
    })?;
    if request.expected_revision < 0 {
        return Err(invalid_policy(
            "INVALID_RELAY_USER_POLICY_RESET_REQUEST",
            "expected_revision must be nonnegative",
        ));
    }
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    require_policy_user_tx(&mut tx, &user_id).await?;
    sqlx::query("SELECT user_id FROM users WHERE user_id=$1 FOR UPDATE")
        .bind(&user_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    let current = user_policy_tx(&mut tx, &user_id).await?;
    let (current_revision, _) = user_policy_version_tx(&mut tx, &user_id, current.as_ref()).await?;
    if request.expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_USER_POLICY_CONFLICT",
            "relay user policy changed since it was read",
        ));
    }
    if current.is_some() {
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("relay user policy revision overflowed"))?;
        let updated_at: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM user_relay_policies WHERE user_id=$1")
            .bind(&user_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        write_user_policy_version_tx(&mut tx, &user_id, revision, updated_at).await?;
        invalidate_user_tickets_tx(&mut tx, &user_id).await?;
        record_admin_event_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_policy_updated",
            "relay_user_policy",
            Some(&user_id),
        )
        .await?;
    }
    let response = admin_user_policy_response(&mut tx, &state, &user_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CreateGroupRequest {
    name: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct RenameGroupRequest {
    expected_revision: i64,
    name: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DeleteGroupRequest {
    expected_revision: i64,
    expected_membership_revision: i64,
    expected_policy_revision: i64,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ReplaceMembersRequest {
    expected_revision: i64,
    user_ids: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct UpdateGroupPolicyRequest {
    expected_revision: i64,
    expected_instance_policy_revision: i64,
    enabled: bool,
    allow_cidrs: Vec<String>,
    allow_ports: Vec<u16>,
}

fn invalid_group_request() -> ApiError {
    invalid_policy(
        "INVALID_RELAY_GROUP_REQUEST",
        "request must contain only bounded, valid relay group fields",
    )
}
fn invalid_members_request() -> ApiError {
    invalid_policy(
        "INVALID_RELAY_GROUP_MEMBERS_REQUEST",
        "user_ids must be a bounded array of unique canonical account UUIDs",
    )
}
fn invalid_group_policy_request() -> ApiError {
    invalid_policy(
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

fn normalize_group_name(name: String) -> Result<(String, String), ApiError> {
    let name = name.trim().nfkc().collect::<String>();
    if name.is_empty()
        || name.chars().count() > MAX_GROUP_NAME_CHARS
        || name.len() > MAX_GROUP_NAME_BYTES
        || name.chars().any(char::is_control)
    {
        return Err(invalid_group_request());
    }
    let key = name
        .nfkc()
        .flat_map(char::to_lowercase)
        .nfkc()
        .collect::<String>();
    Ok((name, key))
}

async fn group_revision_tx(tx: &mut PgTx<'_>, group_id: &str, lock: bool) -> Result<i64, ApiError> {
    let query = if lock {
        "SELECT revision FROM relay_access_groups WHERE group_id=$1 FOR UPDATE"
    } else {
        "SELECT revision FROM relay_access_groups WHERE group_id=$1"
    };
    sqlx::query_scalar(query)
        .bind(group_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(group_not_found)
}

async fn group_members_tx(tx: &mut PgTx<'_>, group_id: &str) -> Result<Vec<Value>, ApiError> {
    let rows=sqlx::query("SELECT u.user_id,u.username FROM relay_access_group_members m JOIN users u ON u.user_id=m.user_id WHERE m.group_id=$1 ORDER BY lower(u.username),u.user_id")
        .bind(group_id).fetch_all(&mut **tx).await.map_err(ApiError::internal)?;
    Ok(rows.into_iter().map(|row|json!({"user_id":row.get::<String,_>("user_id"),"username":row.get::<String,_>("username")})).collect())
}

async fn group_user_ids_tx(tx: &mut PgTx<'_>, group_id: &str) -> Result<Vec<String>, ApiError> {
    sqlx::query_scalar(
        "SELECT user_id FROM relay_access_group_members WHERE group_id=$1 ORDER BY user_id",
    )
    .bind(group_id)
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)
}

async fn group_policy_version_tx(
    tx: &mut PgTx<'_>,
    group_id: &str,
    policy: Option<&RelayPolicySnapshot>,
) -> Result<(i64, Option<String>), ApiError> {
    let row:Option<(i64,DateTime<Utc>)>=sqlx::query_as::<_,(i64,DateTime<Utc>)>("SELECT revision,updated_at FROM relay_access_group_relay_policy_revisions WHERE group_id=$1")
        .bind(group_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    match (policy, row) {
        (Some(policy), Some((revision, updated_at)))
            if revision == policy.revision
                && policy.updated_at.as_deref()
                    == Some(
                        updated_at
                            .to_rfc3339_opts(SecondsFormat::Millis, true)
                            .as_str(),
                    ) =>
        {
            Ok((
                revision,
                Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
            ))
        }
        (Some(_), _) => Err(ApiError::internal(
            "Relay group policy version watermark does not match override row",
        )),
        (None, Some((revision, updated_at))) => Ok((
            revision,
            Some(updated_at.to_rfc3339_opts(SecondsFormat::Millis, true)),
        )),
        (None, None) => Ok((0, None)),
    }
}

async fn group_policy_response_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    group_id: &str,
) -> Result<Value, ApiError> {
    let instance = instance_policy_tx(tx, state).await?;
    let instance_effective = instance_effective_tx(tx, state).await?;
    let group_policy = group_policy_tx(tx, group_id).await?;
    let (revision, updated_at) =
        group_policy_version_tx(tx, group_id, group_policy.as_ref()).await?;
    let selected = group_policy
        .as_ref()
        .map(|snapshot| &snapshot.policy)
        .unwrap_or(&instance.policy);
    let effective = group_policy
        .as_ref()
        .map(|snapshot| relay::restrict_effective_policy(&instance_effective, &snapshot.policy))
        .unwrap_or(instance_effective);
    Ok(
        json!({"inherited":group_policy.is_none(),"revision":revision,"updated_at":updated_at,"instance_policy_revision":instance.revision,"policy":policy_json(selected),"effective_policy":effective_policy_json(&effective)}),
    )
}

async fn group_detail_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    group_id: &str,
) -> Result<Value, ApiError> {
    let row=sqlx::query("SELECT group_id,name,revision,created_at,updated_at FROM relay_access_groups WHERE group_id=$1").bind(group_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?.ok_or_else(group_not_found)?;
    let membership_revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=$1",
    )
    .bind(group_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("Relay group membership revision is missing"))?;
    let created: DateTime<Utc> = row.try_get("created_at").map_err(ApiError::internal)?;
    let updated: DateTime<Utc> = row.try_get("updated_at").map_err(ApiError::internal)?;
    Ok(
        json!({"group":{"group_id":row.get::<String,_>("group_id"),"name":row.get::<String,_>("name"),"revision":row.get::<i64,_>("revision"),"created_at":created.to_rfc3339_opts(SecondsFormat::Millis,true),"updated_at":updated.to_rfc3339_opts(SecondsFormat::Millis,true)},"members":{"revision":membership_revision,"items":group_members_tx(tx,group_id).await?},"policy":group_policy_response_tx(tx,state,group_id).await?}),
    )
}

async fn bump_user_authorization_tx(tx: &mut PgTx<'_>, user_id: &str) -> Result<(), ApiError> {
    let updated:Option<i64>=sqlx::query_scalar("INSERT INTO relay_user_authorization_versions(user_id,revision) VALUES($1,1) ON CONFLICT(user_id) DO UPDATE SET revision=relay_user_authorization_versions.revision+1 WHERE relay_user_authorization_versions.revision<9223372036854775807 RETURNING revision")
        .bind(user_id).fetch_optional(&mut **tx).await.map_err(ApiError::internal)?;
    if updated.is_none() {
        return Err(ApiError::internal(
            "Relay user authorization revision overflowed",
        ));
    }
    invalidate_user_tickets_tx(tx, user_id).await
}

async fn bump_group_members_and_revoke_tx(
    tx: &mut PgTx<'_>,
    group_id: &str,
) -> Result<(), ApiError> {
    for user_id in group_user_ids_tx(tx, group_id).await? {
        sqlx::query("SELECT user_id FROM users WHERE user_id=$1 FOR UPDATE")
            .bind(&user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
        bump_user_authorization_tx(tx, &user_id).await?;
    }
    Ok(())
}

async fn audit_group_tx(
    tx: &mut PgTx<'_>,
    state: &AppState,
    actor: &AuthUser,
    action: &str,
    group_id: &str,
) -> Result<(), ApiError> {
    record_admin_event_tx(
        tx,
        state,
        actor,
        action,
        "relay_access_group",
        Some(group_id),
    )
    .await
}

pub(crate) async fn list_groups(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    let rows: Vec<PgRow> = sqlx::query("SELECT g.group_id,g.name,g.revision,g.updated_at,m.revision AS membership_revision,COALESCE(pr.revision,0) AS policy_revision,COUNT(DISTINCT gm.user_id)::BIGINT AS member_count,(p.group_id IS NULL) AS policy_inherited FROM relay_access_groups g JOIN relay_access_group_membership_revisions m ON m.group_id=g.group_id LEFT JOIN relay_access_group_members gm ON gm.group_id=g.group_id LEFT JOIN relay_access_group_relay_policies p ON p.group_id=g.group_id LEFT JOIN relay_access_group_relay_policy_revisions pr ON pr.group_id=g.group_id GROUP BY g.group_id,m.revision,pr.revision,p.group_id ORDER BY g.name_key,g.group_id")
        .fetch_all(&mut *tx).await.map_err(ApiError::internal)?;
    let groups=rows.into_iter().map(|row|{let updated:DateTime<Utc>=row.get("updated_at");json!({"group_id":row.get::<String,_>("group_id"),"name":row.get::<String,_>("name"),"revision":row.get::<i64,_>("revision"),"membership_revision":row.get::<i64,_>("membership_revision"),"policy_revision":row.get::<i64,_>("policy_revision"),"member_count":row.get::<i64,_>("member_count"),"policy_inherited":row.get::<bool,_>("policy_inherited"),"updated_at":updated.to_rfc3339_opts(SecondsFormat::Millis,true)})}).collect::<Vec<_>>();
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(json!({"groups":groups})))
}

pub(crate) async fn create_group(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: Result<Json<CreateGroupRequest>, JsonRejection>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let Json(request) = request.map_err(|_| invalid_group_request())?;
    let (name, name_key) = normalize_group_name(request.name)?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    lock_exclusive(&mut tx, LOCK_GROUP_CAPACITY).await?;
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
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM relay_access_groups WHERE name_key=$1)")
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
    let id = Uuid::new_v4().to_string();
    let now: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    sqlx::query("INSERT INTO relay_access_groups(group_id,name,name_key,revision,created_at,updated_at) VALUES($1,$2,$3,1,$4,$4)").bind(&id).bind(&name).bind(&name_key).bind(now).execute(&mut *tx).await.map_err(ApiError::internal)?;
    sqlx::query(
        "INSERT INTO relay_access_group_membership_revisions(group_id,revision) VALUES($1,0)",
    )
    .bind(&id)
    .execute(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    audit_group_tx(&mut tx, &state, &actor, "admin.relay_group_created", &id).await?;
    let response = group_detail_tx(&mut tx, &state, &id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok((StatusCode::CREATED, Json(response)))
}

pub(crate) async fn get_group(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    let response = group_detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn rename_group(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<RenameGroupRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_request())?;
    if request.expected_revision < 0 {
        return Err(invalid_group_request());
    };
    let (name, name_key) = normalize_group_name(request.name)?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    let revision = group_revision_tx(&mut tx, &group_id, true).await?;
    if revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_CONFLICT",
            "Relay access group changed since it was read",
        ));
    }
    let current: String =
        sqlx::query_scalar("SELECT name FROM relay_access_groups WHERE group_id=$1")
            .bind(&group_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
    if current != name {
        let duplicate: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM relay_access_groups WHERE name_key=$1 AND group_id<>$2)",
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
        let updated: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET name=$1,name_key=$2,revision=revision+1,updated_at=$3 WHERE group_id=$4 AND revision=$5").bind(&name).bind(&name_key).bind(updated).bind(&group_id).bind(revision).execute(&mut *tx).await.map_err(ApiError::internal)?;
        audit_group_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_renamed",
            &group_id,
        )
        .await?;
    }
    let response = group_detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn delete_group(
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
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    let revision = group_revision_tx(&mut tx, &group_id, true).await?;
    if revision != request.expected_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_CONFLICT",
            "Relay access group changed since it was read",
        ));
    }
    let membership: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=$1 FOR UPDATE",
    )
    .bind(&group_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("Relay group membership revision is missing"))?;
    if membership != request.expected_membership_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_MEMBERSHIP_CONFLICT",
            "Relay group membership changed since it was read",
        ));
    }
    let policy = group_policy_tx(&mut tx, &group_id).await?;
    let (policy_revision, _) = group_policy_version_tx(&mut tx, &group_id, policy.as_ref()).await?;
    if policy_revision != request.expected_policy_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "Relay group policy changed since it was read",
        ));
    }
    bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
    audit_group_tx(
        &mut tx,
        &state,
        &actor,
        "admin.relay_group_deleted",
        &group_id,
    )
    .await?;
    sqlx::query("DELETE FROM relay_access_groups WHERE group_id=$1 AND revision=$2")
        .bind(&group_id)
        .bind(revision)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(StatusCode::NO_CONTENT)
}

pub(crate) async fn replace_group_members(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<ReplaceMembersRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_members_request())?;
    if request.expected_revision < 0
        || request.user_ids.len() > MAX_GROUP_MEMBERS
        || request.user_ids.iter().any(|id| !canonical_uuid(id))
    {
        return Err(invalid_members_request());
    }
    let submitted_count = request.user_ids.len();
    let target = request.user_ids.into_iter().collect::<BTreeSet<_>>();
    if target.len() != submitted_count {
        return Err(invalid_members_request());
    }
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    let _group = group_revision_tx(&mut tx, &group_id, true).await?;
    let revision: i64 = sqlx::query_scalar(
        "SELECT revision FROM relay_access_group_membership_revisions WHERE group_id=$1 FOR UPDATE",
    )
    .bind(&group_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?
    .ok_or_else(|| ApiError::internal("Relay group membership revision is missing"))?;
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
    if existing != target {
        let affected = existing.union(&target).cloned().collect::<BTreeSet<_>>();
        for id in &affected {
            sqlx::query("SELECT user_id FROM users WHERE user_id=$1 FOR UPDATE")
                .bind(id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        }
        // Serialize additions with account disable/delete before validating
        // status. Checking first can observe an uncommitted disable as active,
        // then wait on the row lock and insert that disabled account afterward.
        for id in &additions {
            let status: Option<String> =
                sqlx::query_scalar("SELECT status FROM users WHERE user_id=$1")
                    .bind(id)
                    .fetch_optional(&mut *tx)
                    .await
                    .map_err(ApiError::internal)?;
            if status.as_deref() != Some("active") {
                return Err(invalid_members_request());
            }
        }
        sqlx::query("UPDATE relay_access_group_membership_revisions SET revision=revision+1 WHERE group_id=$1 AND revision=$2").bind(&group_id).bind(revision).execute(&mut *tx).await.map_err(ApiError::internal)?;
        let updated: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=$1 WHERE group_id=$2")
            .bind(updated)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM relay_access_group_members WHERE group_id=$1")
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        for id in &target {
            sqlx::query("INSERT INTO relay_access_group_members(group_id,user_id,created_at) VALUES($1,$2,$3)").bind(&group_id).bind(id).bind(updated).execute(&mut *tx).await.map_err(ApiError::internal)?;
        }
        for id in affected {
            bump_user_authorization_tx(&mut tx, &id).await?;
        }
        audit_group_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_membership_updated",
            &group_id,
        )
        .await?;
    }
    let response = group_detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn get_group_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let (_actor, mut tx) = admin_tx(&state, &headers).await?;
    group_revision_tx(&mut tx, &group_id, false).await?;
    let response = group_policy_response_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

fn validate_group_policy(
    policy: &RelayPolicy,
    instance: &EffectiveRelayPolicy,
) -> Result<(), ApiError> {
    if policy.enabled && !instance.enabled {
        return Err(ApiError::new(
            StatusCode::UNPROCESSABLE_ENTITY,
            "RELAY_GROUP_POLICY_UNAVAILABLE",
            "group Relay policy cannot be enabled while the instance Relay policy is unavailable",
        ));
    }
    if policy.allow_cidrs.iter().any(|requested| {
        !instance
            .allow_cidrs
            .iter()
            .any(|ceiling| relay::is_network_within(*requested, *ceiling))
    }) || policy
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

pub(crate) async fn update_group_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<UpdateGroupPolicyRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_policy_request())?;
    if request.expected_revision < 0 || request.expected_instance_policy_revision < 0 {
        return Err(invalid_group_policy_request());
    }
    let expected_revision = request.expected_revision;
    let expected_instance_revision = request.expected_instance_policy_revision;
    let candidate = parse_policy(
        request.enabled,
        request.allow_cidrs,
        request.allow_ports,
        "INVALID_RELAY_GROUP_POLICY_REQUEST",
        "body must contain only bounded canonical Relay policy fields and nonnegative revisions",
    )?;
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    lock_shared(&mut tx, LOCK_INSTANCE_POLICY).await?;
    group_revision_tx(&mut tx, &group_id, true).await?;
    let instance = instance_policy_tx(&mut tx, &state).await?;
    if instance.revision != expected_instance_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "instance Relay policy changed since it was read",
        ));
    }
    let current = group_policy_tx(&mut tx, &group_id).await?;
    let (current_revision, _) =
        group_policy_version_tx(&mut tx, &group_id, current.as_ref()).await?;
    if expected_revision != current_revision {
        return Err(ApiError::conflict(
            "RELAY_GROUP_POLICY_CONFLICT",
            "Relay group policy changed since it was read",
        ));
    }
    let instance_effective = instance_effective_tx(&mut tx, &state).await?;
    validate_group_policy(&candidate, &instance_effective)?;
    let inherited = current
        .as_ref()
        .map(|value| &value.policy)
        .unwrap_or(&instance.policy);
    if candidate != *inherited {
        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| ApiError::internal("Relay group policy revision overflowed"))?;
        let updated: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let cidrs = serde_json::to_string(
            &candidate
                .allow_cidrs
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
        )
        .map_err(ApiError::internal)?;
        let ports = serde_json::to_string(&candidate.allow_ports).map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO relay_access_group_relay_policies(group_id,enabled,allow_cidrs,allow_ports,revision,updated_at) VALUES($1,$2,$3,$4,$5,$6) ON CONFLICT(group_id) DO UPDATE SET enabled=EXCLUDED.enabled,allow_cidrs=EXCLUDED.allow_cidrs,allow_ports=EXCLUDED.allow_ports,revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at").bind(&group_id).bind(candidate.enabled).bind(cidrs).bind(ports).bind(revision).bind(updated).execute(&mut *tx).await.map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO relay_access_group_relay_policy_revisions(group_id,revision,updated_at) VALUES($1,$2,$3) ON CONFLICT(group_id) DO UPDATE SET revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at").bind(&group_id).bind(revision).bind(updated).execute(&mut *tx).await.map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=$1 WHERE group_id=$2")
            .bind(updated)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
        audit_group_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_policy_updated",
            &group_id,
        )
        .await?;
    }
    let response = group_detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

pub(crate) async fn reset_group_policy(
    State(state): State<AppState>,
    Path(group_id): Path<String>,
    headers: HeaderMap,
    request: Result<Json<PolicyResetRequest>, JsonRejection>,
) -> Result<Json<Value>, ApiError> {
    canonical_group_id(&group_id)?;
    let Json(request) = request.map_err(|_| invalid_group_policy_request())?;
    if request.expected_revision < 0 {
        return Err(invalid_group_policy_request());
    }
    let (actor, mut tx) = admin_tx(&state, &headers).await?;
    group_revision_tx(&mut tx, &group_id, true).await?;
    let current = group_policy_tx(&mut tx, &group_id).await?;
    let (current_revision, _) =
        group_policy_version_tx(&mut tx, &group_id, current.as_ref()).await?;
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
        let updated: DateTime<Utc> = sqlx::query_scalar("SELECT clock_timestamp()")
            .fetch_one(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("DELETE FROM relay_access_group_relay_policies WHERE group_id=$1")
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        sqlx::query("INSERT INTO relay_access_group_relay_policy_revisions(group_id,revision,updated_at) VALUES($1,$2,$3) ON CONFLICT(group_id) DO UPDATE SET revision=EXCLUDED.revision,updated_at=EXCLUDED.updated_at").bind(&group_id).bind(revision).bind(updated).execute(&mut *tx).await.map_err(ApiError::internal)?;
        sqlx::query("UPDATE relay_access_groups SET updated_at=$1 WHERE group_id=$2")
            .bind(updated)
            .bind(&group_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        bump_group_members_and_revoke_tx(&mut tx, &group_id).await?;
        audit_group_tx(
            &mut tx,
            &state,
            &actor,
            "admin.relay_group_policy_reset",
            &group_id,
        )
        .await?;
    }
    let response = group_detail_tx(&mut tx, &state, &group_id).await?;
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Json(response))
}

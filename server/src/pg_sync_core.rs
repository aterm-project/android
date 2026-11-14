//! Test-only PostgreSQL sync transaction pilot.
//!
//! This module is compiled only for tests. It is not connected to `AppState`,
//! HTTP routes, production startup, or production migrations, and it does not
//! demonstrate general PostgreSQL support. The schema is a deliberately small
//! vertical slice used to exercise authorization fencing, counter allocation,
//! CAS, immutable writes, object references and GC deferral, audit/outbox
//! writes, receipts, replay, and rollback in one transaction. Those tables and
//! effects are fixture-local examples; this is not production repository
//! parity, object-store integration, GC processing, audit policy, or push
//! delivery.
//!
//! The fixture-local lock order implemented here is session → account →
//! device → vault → membership → counter → record head. It describes only the
//! rows and operations in `postgres_sync_core.sql`; it is not an adopted
//! production lock order. Existing account/device/Vault lifecycle routes use
//! other lock paths, so this pilot does not establish global deadlock
//! freedom or validate revoke behavior for those production routes.

use std::{collections::BTreeSet, str::FromStr, time::Duration};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row, postgres::PgConnectOptions, postgres::PgPoolOptions};
use thiserror::Error;
use uuid::Uuid;

const FIXTURE: &str = include_str!("../tests/fixtures/postgres_sync_core.sql");
const VAULT_ID: &str = "pilot-vault";
const USER_A: &str = "pilot-user-a";
const USER_B: &str = "pilot-user-b";
const DEVICE_A: &str = "pilot-device-a";
const DEVICE_B: &str = "pilot-device-b";
const SESSION_A: &str = "pilot-session-a";
const SESSION_B: &str = "pilot-session-b";

#[derive(Debug, Error, PartialEq, Eq)]
enum PilotError {
    #[error("PostgreSQL pilot requires ATERMIUS_TEST_PG_URL")]
    MissingDatabaseUrl,
    #[error("PostgreSQL pilot URL must explicitly name a disposable database")]
    MissingDatabaseName,
    #[error("PostgreSQL pilot refuses shared/template database")]
    UnsafeDatabase,
    #[error("PostgreSQL pilot database setup failed")]
    Database,
    #[error("authorization fence rejected the request")]
    Unauthorized,
    #[error("record head compare-and-swap failed")]
    StaleCas,
    #[error("idempotency key was reused with different content")]
    IdempotencyReuse,
    #[error("operation is invalid for the current head")]
    InvalidOperation,
    #[error("operation key epoch does not match the active Vault epoch")]
    KeyEpochConflict,
    #[error("operation membership version is stale")]
    MembershipVersionConflict,
}

type PilotResult<T> = Result<T, PilotError>;

#[derive(Clone, Copy, Debug, Serialize)]
struct PilotActor {
    user_id: &'static str,
    device_id: &'static str,
    session_id: &'static str,
    access_hash: &'static str,
}

const ACTOR_A: PilotActor = PilotActor {
    user_id: USER_A,
    device_id: DEVICE_A,
    session_id: SESSION_A,
    access_hash: "access-hash-a",
};

const ACTOR_B: PilotActor = PilotActor {
    user_id: USER_B,
    device_id: DEVICE_B,
    session_id: SESSION_B,
    access_hash: "access-hash-b",
};

#[derive(Clone, Debug, Serialize, Deserialize)]
struct PilotOperation {
    op_id: String,
    device_seq: i64,
    record_id: String,
    revision_id: String,
    base_revision_id: Option<String>,
    operation: String,
    envelope: String,
    digest: String,
    key_epoch: i64,
    membership_version: i64,
    object_refs: Vec<String>,
}

#[derive(Clone, Debug)]
struct PilotBatch {
    actor: PilotActor,
    vault_id: String,
    batch_id: String,
    request_digest: String,
    operations: Vec<PilotOperation>,
}

#[derive(Debug)]
struct PilotOutcome {
    response_json: String,
    replayed: bool,
}

#[derive(Clone)]
struct PgSyncPilot {
    pool: PgPool,
}

impl PgSyncPilot {
    fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn commit_batch(&self, batch: &PilotBatch) -> PilotResult<PilotOutcome> {
        let mut tx = self.pool.begin().await.map_err(|_| PilotError::Database)?;

        // This order is local to this fixture. Shared row locks allow two
        // distinct actors to reach the vault counter concurrently while
        // ensuring a revocation UPDATE waits for an in-flight fenced write.
        let session = sqlx::query(
            "SELECT user_id, device_id, access_hash, active, expires_at > CURRENT_TIMESTAMP AS unexpired FROM pilot_sessions WHERE session_id = $1 FOR SHARE",
        )
        .bind(&batch.actor.session_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        .ok_or(PilotError::Unauthorized)?;
        if session.get::<String, _>("user_id") != batch.actor.user_id
            || session.get::<String, _>("device_id") != batch.actor.device_id
            || session.get::<String, _>("access_hash") != batch.actor.access_hash
            || !session.get::<bool, _>("active")
            || !session.get::<bool, _>("unexpired")
        {
            return Err(PilotError::Unauthorized);
        }

        let account_active = sqlx::query_scalar::<_, bool>(
            "SELECT active FROM pilot_accounts WHERE user_id = $1 FOR SHARE",
        )
        .bind(&batch.actor.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        .ok_or(PilotError::Unauthorized)?;
        if !account_active {
            return Err(PilotError::Unauthorized);
        }

        let device =
            sqlx::query("SELECT user_id, active FROM pilot_devices WHERE device_id = $1 FOR SHARE")
                .bind(&batch.actor.device_id)
                .fetch_optional(&mut *tx)
                .await
                .map_err(|_| PilotError::Database)?
                .ok_or(PilotError::Unauthorized)?;
        if device.get::<String, _>("user_id") != batch.actor.user_id
            || !device.get::<bool, _>("active")
        {
            return Err(PilotError::Unauthorized);
        }

        let vault = sqlx::query(
            "SELECT active, key_epoch, membership_version FROM pilot_vaults WHERE vault_id = $1 FOR SHARE",
        )
        .bind(&batch.vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        .ok_or(PilotError::Unauthorized)?;
        if !vault.get::<bool, _>("active") {
            return Err(PilotError::Unauthorized);
        }
        let key_epoch: i64 = vault.get("key_epoch");
        let vault_membership_version: i64 = vault.get("membership_version");

        let membership = sqlx::query(
            "SELECT role, active, membership_version FROM pilot_memberships WHERE vault_id = $1 AND user_id = $2 FOR SHARE",
        )
        .bind(&batch.vault_id)
        .bind(&batch.actor.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        .ok_or(PilotError::Unauthorized)?;
        if !membership.get::<bool, _>("active")
            || !matches!(
                membership.get::<String, _>("role").as_str(),
                "owner" | "writer"
            )
            || membership.get::<i64, _>("membership_version") != vault_membership_version
        {
            return Err(PilotError::Unauthorized);
        }

        // This per-Vault row serializes missing-head creates as well as
        // sequence allocation; PostgreSQL cannot row-lock an absent head.
        sqlx::query(
            "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = $1 FOR UPDATE",
        )
        .bind(&batch.vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        .ok_or(PilotError::Unauthorized)?;

        if let Some(row) = sqlx::query(
            "SELECT request_digest, response_json FROM pilot_batch_receipts WHERE vault_id = $1 AND device_id = $2 AND batch_id = $3",
        )
        .bind(&batch.vault_id)
        .bind(&batch.actor.device_id)
        .bind(&batch.batch_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?
        {
            if row.get::<String, _>("request_digest") != batch.request_digest {
                return Err(PilotError::IdempotencyReuse);
            }
            let stored_response: String = row.get("response_json");
            let mut response: Value =
                serde_json::from_str(&stored_response).map_err(|_| PilotError::Database)?;
            if let Some(results) = response.get_mut("results").and_then(Value::as_array_mut) {
                for result in results {
                    result["already_committed"] = Value::Bool(true);
                }
            }
            let response_json =
                serde_json::to_string(&response).map_err(|_| PilotError::Database)?;
            tx.commit().await.map_err(|_| PilotError::Database)?;
            return Ok(PilotOutcome {
                response_json,
                replayed: true,
            });
        }

        let mut results = Vec::with_capacity(batch.operations.len());
        let mut newly_committed = 0usize;
        for operation in &batch.operations {
            if operation.key_epoch != key_epoch {
                return Err(PilotError::KeyEpochConflict);
            }
            if operation.membership_version != vault_membership_version {
                return Err(PilotError::MembershipVersionConflict);
            }
            let head = sqlx::query(
                "SELECT revision_id, deleted FROM pilot_record_heads WHERE vault_id = $1 AND record_id = $2 FOR UPDATE",
            )
            .bind(&batch.vault_id)
            .bind(&operation.record_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;

            if let Some(row) = sqlx::query(
                "SELECT request_digest, revision_id, commit_seq FROM pilot_op_receipts WHERE vault_id = $1 AND op_id = $2",
            )
            .bind(&batch.vault_id)
            .bind(&operation.op_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?
            {
                if row.get::<String, _>("request_digest") != operation.digest {
                    return Err(PilotError::IdempotencyReuse);
                }
                results.push(json!({
                    "op_id": operation.op_id,
                    "revision_id": row.get::<String, _>("revision_id"),
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "already_committed": true,
                }));
                continue;
            }

            let current = head.as_ref().map(|row| {
                (
                    row.get::<String, _>("revision_id"),
                    row.get::<bool, _>("deleted"),
                )
            });
            match (operation.operation.as_str(), current.as_ref()) {
                ("create", None) if operation.base_revision_id.is_none() => {}
                ("update", Some((revision_id, false)))
                    if operation.base_revision_id.as_ref() == Some(revision_id) => {}
                ("delete", Some((revision_id, false)))
                    if operation.base_revision_id.as_ref() == Some(revision_id) => {}
                ("create", None) | ("update", _) | ("delete", _) => {
                    return Err(PilotError::StaleCas);
                }
                _ => return Err(PilotError::InvalidOperation),
            }

            let revision_exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM pilot_record_versions WHERE vault_id = $1 AND record_id = $2 AND revision_id = $3)",
            )
            .bind(&batch.vault_id)
            .bind(&operation.record_id)
            .bind(&operation.revision_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;
            if revision_exists {
                return Err(PilotError::InvalidOperation);
            }

            persist_object_references(
                &mut tx,
                &batch.vault_id,
                &operation.revision_id,
                &operation.object_refs,
            )
            .await?;

            let commit_seq: i64 = sqlx::query_scalar(
                "UPDATE pilot_vault_counters SET last_committed_seq = last_committed_seq + 1 WHERE vault_id = $1 RETURNING last_committed_seq",
            )
            .bind(&batch.vault_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;
            let envelope_json =
                serde_json::to_string(&operation.envelope).map_err(|_| PilotError::Database)?;
            let deleted = operation.operation == "delete";

            sqlx::query(
                "INSERT INTO pilot_record_versions (vault_id, record_id, revision_id, base_revision_id, envelope, digest, commit_seq, device_id, operation) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            )
            .bind(&batch.vault_id)
            .bind(&operation.record_id)
            .bind(&operation.revision_id)
            .bind(&operation.base_revision_id)
            .bind(&envelope_json)
            .bind(&operation.digest)
            .bind(commit_seq)
            .bind(&batch.actor.device_id)
            .bind(&operation.operation)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;

            sqlx::query(
                "INSERT INTO pilot_record_heads (vault_id, record_id, revision_id, deleted, commit_seq) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (vault_id, record_id) DO UPDATE SET revision_id = EXCLUDED.revision_id, deleted = EXCLUDED.deleted, commit_seq = EXCLUDED.commit_seq",
            )
            .bind(&batch.vault_id)
            .bind(&operation.record_id)
            .bind(&operation.revision_id)
            .bind(deleted)
            .bind(commit_seq)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;

            sqlx::query(
                "INSERT INTO pilot_change_events (vault_id, commit_seq, event_type, record_id, revision_id, envelope) VALUES ($1, $2, $3, $4, $5, $6)",
            )
            .bind(&batch.vault_id)
            .bind(commit_seq)
            .bind(&operation.operation)
            .bind(&operation.record_id)
            .bind(&operation.revision_id)
            .bind(&envelope_json)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;

            sqlx::query(
                "INSERT INTO pilot_op_receipts (vault_id, op_id, device_id, device_seq, request_digest, record_id, revision_id, commit_seq) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            )
            .bind(&batch.vault_id)
            .bind(&operation.op_id)
            .bind(&batch.actor.device_id)
            .bind(operation.device_seq)
            .bind(&operation.digest)
            .bind(&operation.record_id)
            .bind(&operation.revision_id)
            .bind(commit_seq)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;

            results.push(json!({
                "op_id": operation.op_id,
                "revision_id": operation.revision_id,
                "commit_seq": commit_seq.to_string(),
                "already_committed": false,
            }));
            newly_committed += 1;
        }

        if newly_committed > 0 {
            sqlx::query(
                "INSERT INTO pilot_audit_events (vault_id, actor_user_id, actor_device_id, action) VALUES ($1, $2, $3, 'vault.sync_batch_committed')",
            )
            .bind(&batch.vault_id)
            .bind(batch.actor.user_id)
            .bind(batch.actor.device_id)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;
            sqlx::query(
                "INSERT INTO pilot_mobile_push_outbox (vault_id, source_device_id, event_type) VALUES ($1, $2, 'sync_available')",
            )
            .bind(&batch.vault_id)
            .bind(batch.actor.device_id)
            .execute(&mut *tx)
            .await
            .map_err(|_| PilotError::Database)?;
        }

        let response_json = serde_json::to_string(&json!({
            "batch_id": batch.batch_id,
            "results": results,
        }))
        .map_err(|_| PilotError::Database)?;
        sqlx::query(
            "INSERT INTO pilot_batch_receipts (vault_id, device_id, batch_id, request_digest, response_json) VALUES ($1, $2, $3, $4, $5)",
        )
        .bind(&batch.vault_id)
        .bind(&batch.actor.device_id)
        .bind(&batch.batch_id)
        .bind(&batch.request_digest)
        .bind(&response_json)
        .execute(&mut *tx)
        .await
        .map_err(|_| PilotError::Database)?;

        tx.commit().await.map_err(|_| PilotError::Database)?;
        Ok(PilotOutcome {
            response_json,
            replayed: false,
        })
    }
}

struct TestDatabase {
    pool: PgPool,
    admin_pool: PgPool,
    schema: String,
    cleaned: bool,
}

impl TestDatabase {
    async fn create() -> PilotResult<Self> {
        let url =
            std::env::var("ATERMIUS_TEST_PG_URL").map_err(|_| PilotError::MissingDatabaseUrl)?;
        let options = PgConnectOptions::from_str(&url).map_err(|_| PilotError::Database)?;
        let database = options
            .get_database()
            .ok_or(PilotError::MissingDatabaseName)?
            .to_ascii_lowercase();
        ensure_disposable_database(&database)?;

        let admin_pool = PgPoolOptions::new()
            .max_connections(6)
            .connect_with(options.clone())
            .await
            .map_err(|_| PilotError::Database)?;
        let schema = format!("atermius_pg_sync_pilot_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .map_err(|_| PilotError::Database)?;

        let mut database = Self {
            pool: admin_pool.clone(),
            admin_pool,
            schema: schema.clone(),
            cleaned: false,
        };
        let scoped_options = options.options([("search_path", format!("\"{schema}\""))]);
        database.pool = PgPoolOptions::new()
            .max_connections(6)
            .connect_with(scoped_options)
            .await
            .map_err(|_| PilotError::Database)?;
        sqlx::raw_sql(FIXTURE)
            .execute(&database.pool)
            .await
            .map_err(|_| PilotError::Database)?;
        seed_fixture(&database.pool).await?;
        Ok(database)
    }

    async fn cleanup(&mut self) -> PilotResult<()> {
        self.pool.close().await;
        sqlx::query(&format!(
            "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
            self.schema
        ))
        .execute(&self.admin_pool)
        .await
        .map_err(|_| PilotError::Database)?;
        self.cleaned = true;
        Ok(())
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

async fn seed_fixture(pool: &PgPool) -> PilotResult<()> {
    sqlx::query("INSERT INTO pilot_vaults (vault_id, active, key_epoch, membership_version) VALUES ($1, TRUE, 1, 1)")
        .bind(VAULT_ID)
        .execute(pool)
        .await
        .map_err(|_| PilotError::Database)?;
    for (actor, role) in [(&ACTOR_A, "owner"), (&ACTOR_B, "writer")] {
        sqlx::query("INSERT INTO pilot_accounts (user_id, active) VALUES ($1, TRUE)")
            .bind(actor.user_id)
            .execute(pool)
            .await
            .map_err(|_| PilotError::Database)?;
        sqlx::query("INSERT INTO pilot_devices (device_id, user_id, active) VALUES ($1, $2, TRUE)")
            .bind(actor.device_id)
            .bind(actor.user_id)
            .execute(pool)
            .await
            .map_err(|_| PilotError::Database)?;
        sqlx::query("INSERT INTO pilot_sessions (session_id, user_id, device_id, active, access_hash, expires_at) VALUES ($1, $2, $3, TRUE, $4, CURRENT_TIMESTAMP + INTERVAL '1 hour')")
            .bind(actor.session_id)
            .bind(actor.user_id)
            .bind(actor.device_id)
            .bind(actor.access_hash)
            .execute(pool)
            .await
            .map_err(|_| PilotError::Database)?;
        sqlx::query("INSERT INTO pilot_memberships (vault_id, user_id, role, active, membership_version) VALUES ($1, $2, $3, TRUE, 1)")
            .bind(VAULT_ID)
            .bind(actor.user_id)
            .bind(role)
            .execute(pool)
            .await
            .map_err(|_| PilotError::Database)?;
    }
    sqlx::query("INSERT INTO pilot_vault_counters (vault_id, last_committed_seq) VALUES ($1, 0)")
        .bind(VAULT_ID)
        .execute(pool)
        .await
        .map_err(|_| PilotError::Database)?;
    sqlx::query("INSERT INTO pilot_blob_objects (vault_id, object_id, storage_state, gc_after) VALUES ($1, 'pilot-object-a', 'available', CURRENT_TIMESTAMP), ($1, 'pilot-object-b', 'available', CURRENT_TIMESTAMP)")
        .bind(VAULT_ID)
        .execute(pool)
        .await
        .map_err(|_| PilotError::Database)?;
    Ok(())
}

fn ensure_disposable_database(database: &str) -> PilotResult<()> {
    let database = database.to_ascii_lowercase();
    if matches!(database.as_str(), "postgres" | "template0" | "template1")
        || !(database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"))
    {
        Err(PilotError::UnsafeDatabase)
    } else {
        Ok(())
    }
}

fn batch(actor: PilotActor, batch_id: &str, operations: Vec<PilotOperation>) -> PilotBatch {
    let vault_id = VAULT_ID.to_owned();
    let payload = serde_json::to_vec(&(&vault_id, batch_id, &actor, &operations)).unwrap();
    let request_digest = hex::encode(Sha256::digest(payload));
    PilotBatch {
        actor,
        vault_id,
        batch_id: batch_id.to_owned(),
        request_digest,
        operations,
    }
}

fn operation(
    op_id: &str,
    device_seq: i64,
    record_id: &str,
    revision_id: &str,
    base_revision_id: Option<&str>,
    operation: &str,
) -> PilotOperation {
    let mut operation = PilotOperation {
        op_id: op_id.to_owned(),
        device_seq,
        record_id: record_id.to_owned(),
        revision_id: revision_id.to_owned(),
        base_revision_id: base_revision_id.map(str::to_owned),
        operation: operation.to_owned(),
        envelope: format!("ciphertext:{revision_id}"),
        digest: String::new(),
        key_epoch: 1,
        membership_version: 1,
        object_refs: Vec::new(),
    };
    refresh_operation_digest(&mut operation);
    operation
}

fn with_object_ref(mut operation: PilotOperation, object_id: &str) -> PilotOperation {
    operation.object_refs.push(object_id.to_owned());
    refresh_operation_digest(&mut operation);
    operation
}

fn refresh_operation_digest(operation: &mut PilotOperation) {
    let payload = serde_json::to_vec(&(
        &operation.op_id,
        operation.device_seq,
        &operation.record_id,
        &operation.revision_id,
        &operation.base_revision_id,
        &operation.operation,
        &operation.envelope,
        operation.key_epoch,
        operation.membership_version,
        &operation.object_refs,
    ))
    .unwrap();
    operation.digest = hex::encode(Sha256::digest(payload));
}

async fn persist_object_references(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    vault_id: &str,
    revision_id: &str,
    object_refs: &[String],
) -> PilotResult<()> {
    if object_refs.is_empty() {
        return Ok(());
    }
    let unique_refs: BTreeSet<&str> = object_refs.iter().map(String::as_str).collect();
    if unique_refs.len() != object_refs.len() {
        return Err(PilotError::InvalidOperation);
    }
    for object_id in unique_refs {
        let available: Option<bool> = sqlx::query_scalar(
            "SELECT storage_state = 'available' FROM pilot_blob_objects WHERE vault_id = $1 AND object_id = $2 FOR UPDATE",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(|_| PilotError::Database)?;
        if available != Some(true) {
            return Err(PilotError::InvalidOperation);
        }
        sqlx::query(
            "INSERT INTO pilot_object_references (vault_id, revision_id, object_id) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
        )
        .bind(vault_id)
        .bind(revision_id)
        .bind(object_id)
        .execute(&mut **tx)
        .await
        .map_err(|_| PilotError::Database)?;
        sqlx::query(
            "UPDATE pilot_blob_objects SET gc_after = NULL WHERE vault_id = $1 AND object_id = $2",
        )
        .bind(vault_id)
        .bind(object_id)
        .execute(&mut **tx)
        .await
        .map_err(|_| PilotError::Database)?;
    }
    Ok(())
}

async fn scalar_i64(pool: &PgPool, sql: &str) -> i64 {
    sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
}

async fn wait_for_pilot_session_lock_wait(pool: &PgPool) {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let waiting: bool = sqlx::query_scalar(
                "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE '%pilot_sessions%')",
            )
            .fetch_one(pool)
            .await
            .unwrap();
            if waiting {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("pilot writer should wait behind the uncommitted session revocation");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn postgres_test_only_pilot_rejects_shared_databases() {
        for database in ["postgres", "template0", "template1"] {
            assert_eq!(
                ensure_disposable_database(database),
                Err(PilotError::UnsafeDatabase)
            );
        }
        assert_eq!(ensure_disposable_database("atermius_test_sync"), Ok(()));
        assert_eq!(ensure_disposable_database("atermius_pg_test_sync"), Ok(()));
        assert_eq!(
            ensure_disposable_database("production_sync"),
            Err(PilotError::UnsafeDatabase)
        );
    }

    #[tokio::test]
    #[ignore = "test-only PostgreSQL pilot; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_test_only_auth_session_device_membership_and_version_fences_reject() {
        let mut database = TestDatabase::create().await.unwrap();
        let pilot = PgSyncPilot::new(database.pool.clone());

        let wrong_access = PilotActor {
            access_hash: "wrong-access-hash",
            ..ACTOR_A
        };
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    wrong_access,
                    "wrong-access",
                    vec![operation(
                        "wrong-access-op",
                        1,
                        "wrong-access-record",
                        "rev",
                        None,
                        "create"
                    )],
                ))
                .await
                .unwrap_err(),
            PilotError::Unauthorized
        );

        sqlx::query("UPDATE pilot_sessions SET expires_at = CURRENT_TIMESTAMP - INTERVAL '1 second' WHERE session_id = $1")
            .bind(SESSION_A)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    ACTOR_A,
                    "expired-session",
                    vec![operation(
                        "expired-op",
                        1,
                        "expired-record",
                        "rev",
                        None,
                        "create"
                    )],
                ))
                .await
                .unwrap_err(),
            PilotError::Unauthorized
        );
        sqlx::query("UPDATE pilot_sessions SET expires_at = CURRENT_TIMESTAMP + INTERVAL '1 hour' WHERE session_id = $1")
            .bind(SESSION_A)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE pilot_accounts SET active = FALSE WHERE user_id = $1")
            .bind(USER_A)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    ACTOR_A,
                    "inactive-account",
                    vec![operation(
                        "inactive-account-op",
                        1,
                        "inactive-account-record",
                        "rev",
                        None,
                        "create"
                    )],
                ))
                .await
                .unwrap_err(),
            PilotError::Unauthorized
        );
        sqlx::query("UPDATE pilot_accounts SET active = TRUE WHERE user_id = $1")
            .bind(USER_A)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE pilot_devices SET active = FALSE WHERE device_id = $1")
            .bind(DEVICE_A)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    ACTOR_A,
                    "inactive-device",
                    vec![operation(
                        "inactive-device-op",
                        1,
                        "inactive-device-record",
                        "rev",
                        None,
                        "create"
                    )],
                ))
                .await
                .unwrap_err(),
            PilotError::Unauthorized
        );
        sqlx::query("UPDATE pilot_devices SET active = TRUE WHERE device_id = $1")
            .bind(DEVICE_A)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query(
            "UPDATE pilot_memberships SET active = FALSE WHERE vault_id = $1 AND user_id = $2",
        )
        .bind(VAULT_ID)
        .bind(USER_A)
        .execute(&database.pool)
        .await
        .unwrap();
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    ACTOR_A,
                    "inactive-membership",
                    vec![operation(
                        "inactive-membership-op",
                        1,
                        "inactive-membership-record",
                        "rev",
                        None,
                        "create"
                    )],
                ))
                .await
                .unwrap_err(),
            PilotError::Unauthorized
        );
        sqlx::query(
            "UPDATE pilot_memberships SET active = TRUE WHERE vault_id = $1 AND user_id = $2",
        )
        .bind(VAULT_ID)
        .bind(USER_A)
        .execute(&database.pool)
        .await
        .unwrap();

        let mut stale_epoch = operation(
            "stale-epoch-op",
            1,
            "stale-epoch-record",
            "rev",
            None,
            "create",
        );
        stale_epoch.key_epoch = 2;
        refresh_operation_digest(&mut stale_epoch);
        assert_eq!(
            pilot
                .commit_batch(&batch(ACTOR_A, "stale-epoch", vec![stale_epoch]))
                .await
                .unwrap_err(),
            PilotError::KeyEpochConflict
        );

        let mut stale_membership = operation(
            "stale-member-op",
            1,
            "stale-member-record",
            "rev",
            None,
            "create",
        );
        stale_membership.membership_version = 2;
        refresh_operation_digest(&mut stale_membership);
        assert_eq!(
            pilot
                .commit_batch(&batch(
                    ACTOR_A,
                    "stale-membership-version",
                    vec![stale_membership]
                ))
                .await
                .unwrap_err(),
            PilotError::MembershipVersionConflict
        );

        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = 'pilot-vault'"
            )
            .await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_record_versions").await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_op_receipts").await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_batch_receipts").await,
            0
        );
        database.cleanup().await.unwrap();
    }

    #[tokio::test]
    #[ignore = "test-only PostgreSQL pilot; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_test_only_distinct_record_writes_allocate_contiguous_sequences() {
        let mut database = TestDatabase::create().await.unwrap();
        let pilot = PgSyncPilot::new(database.pool.clone());
        let first = batch(
            ACTOR_A,
            "batch-a",
            vec![operation("op-a", 1, "record-a", "rev-a", None, "create")],
        );
        let second = batch(
            ACTOR_B,
            "batch-b",
            vec![operation("op-b", 1, "record-b", "rev-b", None, "create")],
        );
        let (first, second) = tokio::join!(pilot.commit_batch(&first), pilot.commit_batch(&second));
        let first: Value = serde_json::from_str(&first.unwrap().response_json).unwrap();
        let second: Value = serde_json::from_str(&second.unwrap().response_json).unwrap();
        let mut sequences = [
            first["results"][0]["commit_seq"]
                .as_str()
                .unwrap()
                .parse::<i64>()
                .unwrap(),
            second["results"][0]["commit_seq"]
                .as_str()
                .unwrap()
                .parse::<i64>()
                .unwrap(),
        ];
        sequences.sort_unstable();
        assert_eq!(sequences, [1, 2]);
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = 'pilot-vault'"
            )
            .await,
            2
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_record_versions").await,
            2
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_change_events").await,
            2
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_op_receipts").await,
            2
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_batch_receipts").await,
            2
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_audit_events").await,
            2
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_mobile_push_outbox"
            )
            .await,
            2
        );
        database.cleanup().await.unwrap();
    }

    #[tokio::test]
    #[ignore = "test-only PostgreSQL pilot; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_test_only_lost_ack_batch_replay_preserves_result_and_marks_receipt() {
        let mut database = TestDatabase::create().await.unwrap();
        let pilot = PgSyncPilot::new(database.pool.clone());
        let batch = batch(
            ACTOR_A,
            "lost-ack-batch",
            vec![with_object_ref(
                operation(
                    "lost-ack-op",
                    1,
                    "lost-ack-record",
                    "lost-ack-rev",
                    None,
                    "create",
                ),
                "pilot-object-a",
            )],
        );
        let original = pilot.commit_batch(&batch).await.unwrap();
        let replay = pilot.commit_batch(&batch).await.unwrap();
        assert!(!original.replayed);
        assert!(replay.replayed);
        let original_response: Value = serde_json::from_str(&original.response_json).unwrap();
        let replay_response: Value = serde_json::from_str(&replay.response_json).unwrap();
        assert_eq!(original_response["results"][0]["op_id"], "lost-ack-op");
        assert_eq!(
            original_response["results"][0]["revision_id"],
            replay_response["results"][0]["revision_id"]
        );
        assert_eq!(
            original_response["results"][0]["commit_seq"],
            replay_response["results"][0]["commit_seq"]
        );
        assert_eq!(original_response["results"][0]["already_committed"], false);
        assert_eq!(replay_response["results"][0]["already_committed"], true);
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = 'pilot-vault'"
            )
            .await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_record_versions").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_change_events").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_op_receipts").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_batch_receipts").await,
            1
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_object_references"
            )
            .await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_audit_events").await,
            1
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_mobile_push_outbox"
            )
            .await,
            1
        );
        let gc_after: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT gc_after FROM pilot_blob_objects WHERE object_id = 'pilot-object-a'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(gc_after, None);
        database.cleanup().await.unwrap();
    }

    #[tokio::test]
    #[ignore = "test-only PostgreSQL pilot; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_test_only_stale_cas_rolls_back_prior_batch_writes() {
        let mut database = TestDatabase::create().await.unwrap();
        let pilot = PgSyncPilot::new(database.pool.clone());
        let seed = batch(
            ACTOR_A,
            "seed-head",
            vec![operation(
                "seed-op",
                1,
                "shared-record",
                "head-rev-1",
                None,
                "create",
            )],
        );
        pilot.commit_batch(&seed).await.unwrap();

        let stale = batch(
            ACTOR_A,
            "stale-after-valid-op",
            vec![
                with_object_ref(
                    operation(
                        "valid-prefix-op",
                        2,
                        "new-record",
                        "new-rev",
                        None,
                        "create",
                    ),
                    "pilot-object-b",
                ),
                operation(
                    "stale-op",
                    3,
                    "shared-record",
                    "head-rev-3",
                    Some("old-rev"),
                    "update",
                ),
            ],
        );
        assert_eq!(
            pilot.commit_batch(&stale).await.unwrap_err(),
            PilotError::StaleCas
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = 'pilot-vault'"
            )
            .await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_record_versions").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_change_events").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_op_receipts").await,
            1
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_batch_receipts").await,
            1
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_record_heads WHERE record_id = 'new-record'"
            )
            .await,
            0
        );
        let head: String = sqlx::query_scalar(
            "SELECT revision_id FROM pilot_record_heads WHERE record_id = 'shared-record'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(head, "head-rev-1");
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_object_references"
            )
            .await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_audit_events").await,
            1
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_mobile_push_outbox"
            )
            .await,
            1
        );
        let gc_after: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT gc_after FROM pilot_blob_objects WHERE object_id = 'pilot-object-b'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert!(gc_after.is_some());
        database.cleanup().await.unwrap();
    }

    #[tokio::test]
    #[ignore = "test-only PostgreSQL pilot; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_test_only_revoke_write_serialization_rejects_after_revoke_commit() {
        let mut database = TestDatabase::create().await.unwrap();
        let pilot = PgSyncPilot::new(database.pool.clone());
        let mut revoke_tx = database.pool.begin().await.unwrap();
        sqlx::query("SELECT session_id FROM pilot_sessions WHERE session_id = $1 FOR UPDATE")
            .bind(SESSION_A)
            .fetch_one(&mut *revoke_tx)
            .await
            .unwrap();
        sqlx::query("UPDATE pilot_sessions SET active = FALSE WHERE session_id = $1")
            .bind(SESSION_A)
            .execute(&mut *revoke_tx)
            .await
            .unwrap();

        let write = batch(
            ACTOR_A,
            "racing-write",
            vec![operation(
                "racing-op",
                1,
                "racing-record",
                "racing-rev",
                None,
                "create",
            )],
        );
        let write_task = tokio::spawn(async move { pilot.commit_batch(&write).await });
        wait_for_pilot_session_lock_wait(&database.admin_pool).await;
        revoke_tx.commit().await.unwrap();
        assert_eq!(
            write_task.await.unwrap().unwrap_err(),
            PilotError::Unauthorized
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT last_committed_seq FROM pilot_vault_counters WHERE vault_id = 'pilot-vault'"
            )
            .await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_record_versions").await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_change_events").await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_op_receipts").await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_batch_receipts").await,
            0
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_object_references"
            )
            .await,
            0
        );
        assert_eq!(
            scalar_i64(&database.pool, "SELECT COUNT(*) FROM pilot_audit_events").await,
            0
        );
        assert_eq!(
            scalar_i64(
                &database.pool,
                "SELECT COUNT(*) FROM pilot_mobile_push_outbox"
            )
            .await,
            0
        );
        database.cleanup().await.unwrap();
    }
}

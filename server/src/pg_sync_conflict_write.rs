//! PostgreSQL transaction adapter for conflict creation and resolution.
//!
//! This is a narrow write capability composed into `PgSyncRepository`; it
//! does not imply complete PostgreSQL support. It expects the bounded
//! PostgreSQL core through migration 0005 and adds only the conflict operation
//! replay key in migration 0006. Conflict/history reads are separate composed
//! capabilities; unported account/Vault/device lifecycle operations,
//! object upload/GC workers, registration/refresh, and the global lifecycle
//! lock-order migration remain separate work.
//!
//! Both operations use the PG sync-core lock order: session → user → device →
//! Vault → membership → conflict/counter → referenced object. The Vault row
//! lock serializes sync writers and conflict sequence allocation. Existing
//! SQLite lifecycle paths have not been migrated to or audited against this
//! PostgreSQL lock order.

use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};

use crate::{
    ApiError,
    auth::AuthUser,
    now_rfc3339,
    pg_notifications::notify_sync_wake,
    pg_record_redaction::{reject_redacted_record_tx, require_redaction_client_for_vault_tx},
    sync::{conflict_idempotency_retry, conflict_resolution_retry},
    sync_repository::{CreateConflictCommand, RepositoryFuture, ResolveConflictCommand},
};

pub(crate) trait SyncConflictWriteRepository: Send + Sync {
    fn create_conflict(
        &self,
        command: CreateConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;

    fn resolve_conflict(
        &self,
        command: ResolveConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct PgSyncConflictWriteRepository {
    pool: PgPool,
}

impl PgSyncConflictWriteRepository {
    /// Uses a pool provisioned with the PostgreSQL sync migrations through
    /// `0006_sync_conflict_write.sql`. Production startup constructs it through
    /// `PgSyncRepository`.
    pub(crate) fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    async fn create(&self, command: CreateConflictCommand) -> Result<Value, ApiError> {
        let CreateConflictCommand {
            user,
            vault_id,
            device_id,
            conflict_id,
            request_digest,
            envelope_json,
            operation,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_and_lock_vault(&mut tx, &user, &vault_id).await?;
        reject_redacted_record_tx(&mut tx, &vault_id, &operation.record_id).await?;

        // Exact retries are looked up before the v2 roster gate. A capability
        // report can be invalidated after the original write without making a
        // replay create a second branch or lose its idempotent response.
        let existing = sqlx::query(
            "SELECT conflict_id,digest FROM conflicts WHERE vault_id=$1 AND device_id=$2 AND op_id=$3",
        )
        .bind(&vault_id)
        .bind(&device_id)
        .bind(&operation.op_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .map(|row| {
            (
                row.get::<String, _>("conflict_id"),
                row.get::<String, _>("digest"),
            )
        });
        if let Some(existing_id) = conflict_idempotency_retry(existing, &request_digest)? {
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "conflict_id": existing_id,
                "record_id": operation.record_id,
                "revision_id": operation.revision_id,
                "status": "stored",
            }));
        }

        if operation.record_schema >= 2 {
            require_v2_capability_support(&mut tx, &vault_id).await?;
            sqlx::query(
                "UPDATE vaults SET required_record_schema=2 WHERE vault_id=$1 AND required_record_schema<2",
            )
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }

        let conflict_seq: i64 = sqlx::query_scalar(
            "UPDATE vault_counters SET last_conflict_seq=last_conflict_seq+1 WHERE vault_id=$1 RETURNING last_conflict_seq",
        )
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

        persist_object_references(
            &mut tx,
            &vault_id,
            &operation.revision_id,
            &operation.object_refs,
        )
        .await?;

        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq,op_id) VALUES($1,$2,$3,$4,$5,$6,$7,$8::timestamptz,$9,$10)")
            .bind(&conflict_id)
            .bind(&vault_id)
            .bind(&operation.record_id)
            .bind(&operation.base)
            .bind(&envelope_json)
            .bind(&request_digest)
            .bind(&device_id)
            .bind(now_rfc3339())
            .bind(conflict_seq)
            .bind(&operation.op_id)
            .execute(&mut *tx)
            .await
            .map_err(map_conflict_insert_error)?;

        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "conflict_id": conflict_id,
            "record_id": operation.record_id,
            "revision_id": operation.revision_id,
            "status": "stored",
        }))
    }

    async fn resolve(&self, command: ResolveConflictCommand) -> Result<Value, ApiError> {
        let ResolveConflictCommand {
            user,
            vault_id,
            conflict_id,
            resolved_revision_id,
        } = command;
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        authorize_and_lock_vault(&mut tx, &user, &vault_id).await?;

        // Lock the conflict row so concurrent attempts to resolve it produce
        // one sequence/audit row and deterministic replay results.
        let row = sqlx::query(
            "SELECT record_id,resolved_revision_id,resolution_seq FROM conflicts WHERE conflict_id=$1 AND vault_id=$2 FOR UPDATE",
        )
        .bind(&conflict_id)
        .bind(&vault_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?
        .ok_or_else(ApiError::not_found)?;
        let record_id: String = row.get("record_id");
        reject_redacted_record_tx(&mut tx, &vault_id, &record_id).await?;
        let existing_revision = row.get::<Option<String>, _>("resolved_revision_id");
        if conflict_resolution_retry(existing_revision.as_deref(), &resolved_revision_id)? {
            let resolution_seq = row
                .try_get::<Option<i64>, _>("resolution_seq")
                .map_err(ApiError::internal)?
                .ok_or_else(|| ApiError::internal("resolved conflict is missing its sequence"))?;
            tx.commit().await.map_err(ApiError::internal)?;
            return Ok(json!({
                "status": "resolved",
                "resolved_revision_id": existing_revision,
                "resolution_seq": resolution_seq.to_string(),
                "already_resolved": true,
            }));
        }

        let head: Option<String> = sqlx::query_scalar(
            "SELECT revision_id FROM record_heads WHERE vault_id=$1 AND record_id=$2 FOR SHARE",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if head.as_deref() != Some(resolved_revision_id.as_str()) {
            return Err(ApiError::conflict(
                "REVISION_CONFLICT",
                "resolution must point to the current main revision",
            ));
        }
        let version_exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM record_versions WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3)",
        )
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&resolved_revision_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if !version_exists {
            return Err(ApiError::not_found());
        }

        let resolution_seq: i64 = sqlx::query_scalar(
            "UPDATE vault_counters SET last_conflict_seq=last_conflict_seq+1 WHERE vault_id=$1 RETURNING last_conflict_seq",
        )
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let updated = sqlx::query("UPDATE conflicts SET resolved_revision_id=$1,resolution_seq=$2,resolution_at=$3::timestamptz WHERE conflict_id=$4 AND vault_id=$5 AND resolved_revision_id IS NULL")
            .bind(&resolved_revision_id)
            .bind(resolution_seq)
            .bind(now_rfc3339())
            .bind(&conflict_id)
            .bind(&vault_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        if updated.rows_affected() != 1 {
            return Err(ApiError::conflict(
                "CONFLICT_ALREADY_RESOLVED",
                "conflict was already resolved",
            ));
        }

        record_resolution_audit(&mut tx, &vault_id, &user, &conflict_id).await?;
        notify_sync_wake(&mut tx).await?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "resolved",
            "resolved_revision_id": resolved_revision_id,
            "resolution_seq": resolution_seq.to_string(),
            "already_resolved": false,
        }))
    }
}

impl SyncConflictWriteRepository for PgSyncConflictWriteRepository {
    fn create_conflict(
        &self,
        command: CreateConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.create(command))
    }

    fn resolve_conflict(
        &self,
        command: ResolveConflictCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.resolve(command))
    }
}

async fn authorize_and_lock_vault(
    tx: &mut Transaction<'_, Postgres>,
    user: &AuthUser,
    vault_id: &str,
) -> Result<(), ApiError> {
    crate::pg_sync_auth::PgSyncAuthRepository::recheck_active_principal_for_sync_tx(tx, user)
        .await?;

    let vault = sqlx::query("SELECT state FROM vaults WHERE vault_id=$1 FOR UPDATE")
        .bind(vault_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    let Some(vault) = vault else {
        return Err(ApiError::not_found());
    };
    match vault.get::<String, _>("state").as_str() {
        "active" => {}
        "deleting" => return Err(ApiError::vault_deletion_pending()),
        _ => return Err(ApiError::not_found()),
    }

    let membership = sqlx::query(
        "SELECT role,state FROM vault_members WHERE vault_id=$1 AND user_id=$2 FOR SHARE",
    )
    .bind(vault_id)
    .bind(&user.user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(membership) = membership else {
        return Err(ApiError::not_found());
    };
    if membership.get::<String, _>("state") != "active" {
        return Err(ApiError::not_found());
    }
    if !matches!(
        membership.get::<String, _>("role").as_str(),
        "owner" | "editor"
    ) {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    require_redaction_client_for_vault_tx(tx, vault_id, user).await?;
    Ok(())
}

async fn require_v2_capability_support(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
) -> Result<(), ApiError> {
    let incompatible: bool = sqlx::query_scalar(
        r#"SELECT EXISTS(
            SELECT 1 FROM vault_members vm
            JOIN devices d ON d.user_id=vm.user_id AND d.status='active'
            LEFT JOIN device_capability_reports r ON r.device_id=d.device_id AND r.user_id=d.user_id
            WHERE vm.vault_id=$1 AND vm.state='active'
              AND (r.device_id IS NULL OR r.max_record_schema<2
                OR r.max_attachment_bytes<1073741824
                OR NOT (r.host_attachment_manifest_versions @> '[2]'::jsonb))
        )"#,
    )
    .bind(vault_id)
    .fetch_one(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if incompatible {
        return Err(ApiError::conflict(
            "VAULT_CLIENT_CAPABILITY_REQUIRED",
            "all active devices of active vault members must support schema 2, attachment manifest v2, and 1 GiB attachments",
        ));
    }
    Ok(())
}

async fn persist_object_references(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    revision_id: &str,
    object_refs: &[String],
) -> Result<(), ApiError> {
    let unique: std::collections::BTreeSet<&str> = object_refs.iter().map(String::as_str).collect();
    if unique.len() != object_refs.len() {
        return Err(ApiError::conflict(
            "OBJECT_REFERENCE_UNAVAILABLE",
            "one or more referenced objects are unavailable",
        ));
    }
    for object_id in unique {
        let available: Option<bool> = sqlx::query_scalar(
            "SELECT storage_state='available' FROM blob_objects WHERE vault_id=$1 AND object_id=$2 FOR UPDATE",
        )
        .bind(vault_id)
        .bind(object_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if available != Some(true) {
            return Err(ApiError::conflict(
                "OBJECT_REFERENCE_UNAVAILABLE",
                "one or more referenced objects are unavailable",
            ));
        }
        sqlx::query(
            "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES($1,$2,$3) ON CONFLICT(vault_id,revision_id,object_id) DO NOTHING",
        )
        .bind(vault_id)
        .bind(revision_id)
        .bind(object_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        sqlx::query("UPDATE blob_objects SET gc_after=NULL WHERE vault_id=$1 AND object_id=$2")
            .bind(vault_id)
            .bind(object_id)
            .execute(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(())
}

async fn record_resolution_audit(
    tx: &mut Transaction<'_, Postgres>,
    vault_id: &str,
    user: &AuthUser,
    conflict_id: &str,
) -> Result<(), ApiError> {
    sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('vault',$1,$2,$3,'vault.conflict_resolved','conflict',$4,'success',$5,'api')")
        .bind(vault_id)
        .bind(&user.user_id)
        .bind(&user.device_id)
        .bind(conflict_id)
        .bind(chrono::Utc::now().timestamp())
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(())
}

fn map_conflict_insert_error(error: sqlx::Error) -> ApiError {
    if let sqlx::Error::Database(database) = &error
        && database.code().as_deref() == Some("23505")
        && database.constraint() == Some("idx_conflicts_device_op_id")
    {
        return ApiError::conflict(
            "IDEMPOTENCY_KEY_REUSED",
            "conflict operation id was already used for different content",
        );
    }
    ApiError::internal(error)
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, panic_any, resume_unwind},
        str::FromStr,
    };

    use futures_util::FutureExt;
    use sqlx::{
        PgPool,
        postgres::{PgConnectOptions, PgListener, PgPoolOptions},
    };
    use uuid::Uuid;

    use super::*;
    use crate::sync::{Envelope, VerifiedOperation};

    const CORE: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const FEED: &str = include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const WRITE: &str = include_str!("../migrations/postgres/0006_sync_conflict_write.sql");
    const SNAPSHOTS: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
    const REDACTIONS: &str = include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );
    const USER: &str = "pg-conflict-user";
    const DEVICE: &str = "pg-conflict-device";
    const SESSION: &str = "pg-conflict-session";
    const VAULT: &str = "pg-conflict-vault";
    const ACCESS_HASH: &str = "pg-conflict-access";
    const OBJECT: &str = "550e8400-e29b-41d4-a716-446655440000";

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    struct SchemaSetupFailure {
        schema: String,
    }

    struct SchemaSetupCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl SchemaSetupCleanupGuard {
        fn arm(admin_pool: PgPool, schema: String) -> Self {
            Self {
                admin_pool,
                schema,
                armed: true,
            }
        }

        async fn cleanup(&mut self) -> Result<(), sqlx::Error> {
            if !self.armed {
                return Ok(());
            }
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await?;
            self.armed = false;
            Ok(())
        }

        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    impl Drop for SchemaSetupCleanupGuard {
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
            Self::create_with_write_migration(true).await
        }

        async fn create_before_write_migration() -> Self {
            Self::create_with_write_migration(false).await
        }

        async fn create_with_write_migration(apply_write: bool) -> Self {
            Self::create_with_setup_failure(apply_write, false).await
        }

        async fn create_with_setup_failure(
            apply_write: bool,
            fail_after_core_migration: bool,
        ) -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL conflict tests require ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing to run PostgreSQL tests outside an explicitly disposable database"
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
            let schema = format!("atermius_pg_conflict_write_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            let mut cleanup_guard =
                SchemaSetupCleanupGuard::arm(admin_pool.clone(), schema.clone());
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect isolated PostgreSQL search path");
                sqlx::raw_sql(CORE)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL sync core schema");
                if fail_after_core_migration {
                    panic_any(SchemaSetupFailure {
                        schema: schema.clone(),
                    });
                }
                sqlx::raw_sql(FEED)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL conflict feed schema");
                if apply_write {
                    sqlx::raw_sql(WRITE)
                        .execute(&pool)
                        .await
                        .expect("apply PostgreSQL conflict write schema");
                }
                sqlx::raw_sql(SNAPSHOTS)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL snapshot prerequisite schema");
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema (\
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
                )
                .execute(&pool)
                .await
                .expect("create PostgreSQL schema-version fixture");
                sqlx::raw_sql(REDACTIONS)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL record-redaction schema");
                sqlx::raw_sql(REDACTED_CONFLICT_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL redacted-conflict compatibility schema");
                seed(&pool).await;
                pool
            })
            .catch_unwind()
            .await;
            match setup {
                Ok(pool) => {
                    cleanup_guard.disarm();
                    Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    }
                }
                Err(payload) => {
                    cleanup_guard
                        .cleanup()
                        .await
                        .expect("remove isolated PostgreSQL schema after setup failure");
                    resume_unwind(payload)
                }
            }
        }

        async fn apply_write_migration(&self) {
            sqlx::raw_sql(WRITE)
                .execute(&self.pool)
                .await
                .expect("apply PostgreSQL conflict write schema");
        }

        async fn cleanup(mut self) {
            self.pool.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL test schema");
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

    async fn seed(pool: &PgPool) {
        sqlx::query(
            "INSERT INTO users(user_id,username,status) VALUES($1,'pg-conflict-user','active')",
        )
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) VALUES($1,$2,'test','active')",
        )
        .bind(DEVICE)
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,'pg-conflict-refresh',CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
            .bind(SESSION)
            .bind(USER)
            .bind(DEVICE)
            .bind(ACCESS_HASH)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) VALUES($1,$2,'active',1,1)")
            .bind(VAULT)
            .bind(USER)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
        )
        .bind(VAULT)
        .bind(USER)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,last_conflict_seq) VALUES($1,0,0)")
            .bind(VAULT)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO blob_objects(vault_id,object_id,size,sha256,gc_after) VALUES($1,$2,1,repeat('a',64),1)")
            .bind(VAULT)
            .bind(OBJECT)
            .execute(pool)
            .await
            .unwrap();
    }

    fn actor() -> AuthUser {
        AuthUser {
            user_id: USER.to_owned(),
            device_id: DEVICE.to_owned(),
            session_id: SESSION.to_owned(),
            access_hash: ACCESS_HASH.to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        }
    }

    fn operation(
        op_id: &str,
        record_id: &str,
        revision_id: &str,
        schema: i64,
    ) -> VerifiedOperation {
        let env = Envelope {
            header: json!({
                "record_id":record_id,
                "revision_id":revision_id,
                "op_id":op_id,
                "record_schema":schema,
                "device_seq":"1",
                "key_epoch":"1",
                "membership_version":"1",
                "operation":"create",
                "base_revision_id":null,
                "object_refs":[]
            }),
            nonce: "AA".to_owned(),
            ciphertext: "AA".to_owned(),
            signature: "verified-test-envelope".to_owned(),
        };
        VerifiedOperation {
            record_id: record_id.to_owned(),
            revision_id: revision_id.to_owned(),
            op_id: op_id.to_owned(),
            record_schema: schema,
            device_seq: "1".to_owned(),
            key_epoch: 1,
            membership_version: 1,
            operation: "create".to_owned(),
            base: None,
            object_refs: Vec::new(),
            env,
        }
    }

    fn with_object(mut operation: VerifiedOperation, object_id: &str) -> VerifiedOperation {
        operation.object_refs.push(object_id.to_owned());
        operation.env.header["object_refs"] = json!([object_id]);
        operation
    }

    fn create_command(conflict_id: &str, operation: VerifiedOperation) -> CreateConflictCommand {
        let request_digest = crate::sha256_hex(&crate::jcs(&operation.env).unwrap());
        let envelope_json = serde_json::to_string(&operation.env).unwrap();
        CreateConflictCommand {
            user: actor(),
            vault_id: VAULT.to_owned(),
            device_id: DEVICE.to_owned(),
            conflict_id: conflict_id.to_owned(),
            request_digest,
            envelope_json,
            operation,
        }
    }

    fn resolve_command(conflict_id: &str, revision_id: &str) -> ResolveConflictCommand {
        ResolveConflictCommand {
            user: actor(),
            vault_id: VAULT.to_owned(),
            conflict_id: conflict_id.to_owned(),
            resolved_revision_id: revision_id.to_owned(),
        }
    }

    async fn seed_current_revision(pool: &PgPool, record_id: &str, revision_id: &str) {
        let envelope = r#"{"header":{"record_schema":1}}"#;
        sqlx::query("INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) VALUES($1,$2,$3,NULL,$4,'seed-digest',1,$5,'create',CURRENT_TIMESTAMP)")
            .bind(VAULT)
            .bind(record_id)
            .bind(revision_id)
            .bind(envelope)
            .bind(DEVICE)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES($1,$2,$3,FALSE,1)")
            .bind(VAULT)
            .bind(record_id)
            .bind(revision_id)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=1 WHERE vault_id=$1")
            .bind(VAULT)
            .execute(pool)
            .await
            .unwrap();
    }

    async fn count(pool: &PgPool, sql: &str) -> i64 {
        sqlx::query_scalar(sql).fetch_one(pool).await.unwrap()
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL setup-cleanup acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_test_setup_failure_drops_partially_migrated_schema() {
        let url = std::env::var("ATERMIUS_TEST_PG_URL").unwrap();
        let options = PgConnectOptions::from_str(&url).unwrap();
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options)
            .await
            .unwrap();
        let payload = match AssertUnwindSafe(TestDatabase::create_with_setup_failure(true, true))
            .catch_unwind()
            .await
        {
            Ok(_) => panic!("forced PostgreSQL fixture setup failure unexpectedly succeeded"),
            Err(payload) => payload,
        };
        let failure = match payload.downcast::<SchemaSetupFailure>() {
            Ok(failure) => failure,
            Err(_) => panic!("fixture setup did not return its forced failure marker"),
        };
        let still_exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)")
                .bind(failure.schema.as_str())
                .fetch_one(&admin_pool)
                .await
                .unwrap();
        assert!(!still_exists, "failed fixture setup left its schema behind");
        admin_pool.close().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-write acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_create_persists_sequence_and_object_reference_atomically() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let command = create_command(
            "conflict-one",
            with_object(operation("op-one", "record-one", "branch-one", 1), OBJECT),
        );
        let response = repository.create_conflict(command).await.unwrap();
        assert_eq!(response["status"], "stored");
        assert_eq!(response["conflict_id"], "conflict-one");
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            1
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM conflicts WHERE conflict_seq=1 AND op_id='op-one'"
            )
            .await,
            1
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM object_references WHERE revision_id='branch-one'"
            )
            .await,
            1
        );
        let gc_after: Option<i64> = sqlx::query_scalar(
            "SELECT gc_after FROM blob_objects WHERE vault_id=$1 AND object_id=$2",
        )
        .bind(VAULT)
        .bind(OBJECT)
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(gc_after, None);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL redaction acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_create_and_resolve_reject_redacted_records_before_mutation() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let record_id = "record-reserved-by-redaction";
        let deleted_revision_id = "deleted-revision";
        let redaction_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,1)")
            .bind(VAULT)
            .bind(record_id)
            .bind(deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query(
            "UPDATE vault_counters SET last_committed_seq=2,last_conflict_seq=1 WHERE vault_id=$1",
        )
        .bind(VAULT)
        .execute(&database.pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,1,2)")
            .bind(&redaction_id)
            .bind(VAULT)
            .bind(record_id)
            .bind(deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();
        let existing_conflict = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq) VALUES($1,$2,$3,NULL,'{}','digest',$4,CURRENT_TIMESTAMP,1)")
            .bind(&existing_conflict)
            .bind(VAULT)
            .bind(record_id)
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();

        let create_error = repository
            .create_conflict(create_command(
                "redacted-conflict-create",
                operation("redacted-create-op", record_id, "new-revision", 1),
            ))
            .await
            .unwrap_err();
        assert_eq!(create_error.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(create_error.body.code, "RECORD_REDACTED");
        let resolve_error = repository
            .resolve_conflict(resolve_command(&existing_conflict, "resolved-revision"))
            .await
            .unwrap_err();
        assert_eq!(resolve_error.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(resolve_error.body.code, "RECORD_REDACTED");
        assert_eq!(
            count(&database.pool, "SELECT COUNT(*) FROM conflicts").await,
            1
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            1
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-write acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_create_replay_is_idempotent_and_digest_mismatch_is_rejected() {
        let database = TestDatabase::create().await;
        let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
        listener.listen("atermius_sync_wake_v1").await.unwrap();
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let command = create_command(
            "conflict-original",
            operation("op-replay", "record", "branch", 1),
        );
        let first = repository.create_conflict(command).await.unwrap();
        let notification = tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
            .await
            .expect("committed conflict creation should notify")
            .unwrap();
        assert_eq!(notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(notification.payload(), "");
        let replay = repository
            .create_conflict(create_command(
                "new-random-conflict-id",
                operation("op-replay", "record", "branch", 1),
            ))
            .await
            .unwrap();
        assert_eq!(first["conflict_id"], replay["conflict_id"]);
        assert_eq!(replay["conflict_id"], "conflict-original");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "idempotent conflict creation replay must not notify"
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            1
        );
        let mut mismatch = create_command(
            "different-conflict-id",
            operation("op-replay", "record", "branch", 1),
        );
        mismatch.request_digest = "a-different-request-digest".to_owned();
        let error = repository.create_conflict(mismatch).await.unwrap_err();
        assert_eq!(error.body.code, "IDEMPOTENCY_KEY_REUSED");
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            1
        );
        drop(listener);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-write acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_create_object_failure_rolls_back_sequence_and_reference() {
        let database = TestDatabase::create().await;
        sqlx::query(
            "UPDATE blob_objects SET storage_state='deleting' WHERE vault_id=$1 AND object_id=$2",
        )
        .bind(VAULT)
        .bind(OBJECT)
        .execute(&database.pool)
        .await
        .unwrap();
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let command = create_command(
            "conflict-unavailable-object",
            with_object(operation("op-unavailable", "record", "branch", 1), OBJECT),
        );
        let error = repository.create_conflict(command).await.unwrap_err();
        assert_eq!(error.body.code, "OBJECT_REFERENCE_UNAVAILABLE");
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            0
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            0
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM object_references").await,
            0
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL capability acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_v2_requires_active_vault_devices_then_persists_required_schema() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let operation = operation("op-v2", "record-v2", "branch-v2", 2);
        let error = repository
            .create_conflict(create_command("conflict-v2", operation.clone()))
            .await
            .unwrap_err();
        assert_eq!(error.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            0
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            0
        );
        sqlx::query("INSERT INTO device_capability_reports(device_id,user_id,revision,max_record_schema,host_attachment_manifest_versions,max_attachment_bytes,signature) VALUES($1,$2,1,2,'[2]'::jsonb,1073741824,'verified-test-report')")
            .bind(DEVICE)
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        repository
            .create_conflict(create_command("conflict-v2", operation))
            .await
            .unwrap();
        assert_eq!(
            count(
                &database.pool,
                "SELECT required_record_schema::bigint FROM vaults WHERE vault_id='pg-conflict-vault'"
            )
            .await,
            2
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL resolution acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_resolution_checks_current_head_and_replays_exact_resolution() {
        let database = TestDatabase::create().await;
        let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
        listener.listen("atermius_sync_wake_v1").await.unwrap();
        seed_current_revision(&database.pool, "record", "current-r1").await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        repository
            .create_conflict(create_command(
                "resolve-conflict",
                operation("resolve-op", "record", "branch-r2", 1),
            ))
            .await
            .unwrap();
        let created_notification =
            tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
                .await
                .expect("committed conflict creation should notify")
                .unwrap();
        assert_eq!(created_notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(created_notification.payload(), "");
        let resolved = repository
            .resolve_conflict(resolve_command("resolve-conflict", "current-r1"))
            .await
            .unwrap();
        assert_eq!(resolved["already_resolved"], false);
        assert_eq!(resolved["resolution_seq"], "2");
        let resolved_notification =
            tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
                .await
                .expect("committed conflict resolution should notify")
                .unwrap();
        assert_eq!(resolved_notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(resolved_notification.payload(), "");
        let replay = repository
            .resolve_conflict(resolve_command("resolve-conflict", "current-r1"))
            .await
            .unwrap();
        assert_eq!(replay["already_resolved"], true);
        assert_eq!(replay["resolution_seq"], "2");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "exact conflict resolution replay must not notify"
        );
        let mismatch = repository
            .resolve_conflict(resolve_command("resolve-conflict", "another-revision"))
            .await
            .unwrap_err();
        assert_eq!(mismatch.body.code, "CONFLICT_ALREADY_RESOLVED");
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            2
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM audit_events").await,
            1
        );

        repository
            .create_conflict(create_command(
                "stale-head-conflict",
                operation("stale-head-op", "record", "branch-r3", 1),
            ))
            .await
            .unwrap();
        let stale_notification =
            tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
                .await
                .expect("committed conflict creation should notify")
                .unwrap();
        assert_eq!(stale_notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(stale_notification.payload(), "");
        sqlx::query("UPDATE record_heads SET revision_id='current-r2',commit_seq=2 WHERE vault_id=$1 AND record_id='record'")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        let stale = repository
            .resolve_conflict(resolve_command("stale-head-conflict", "current-r1"))
            .await
            .unwrap_err();
        assert_eq!(stale.body.code, "REVISION_CONFLICT");
        drop(listener);
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL concurrent resolution acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_resolution_concurrent_exact_replay_has_one_effect_and_rejects_mismatch() {
        let database = TestDatabase::create().await;
        let mut listener = PgListener::connect_with(&database.pool).await.unwrap();
        listener.listen("atermius_sync_wake_v1").await.unwrap();
        seed_current_revision(&database.pool, "record", "current-r1").await;

        let setup_repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        setup_repository
            .create_conflict(create_command(
                "concurrent-resolution-conflict",
                operation("concurrent-resolution-op", "record", "branch-r2", 1),
            ))
            .await
            .unwrap();
        let created_notification =
            tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
                .await
                .expect("committed conflict creation should notify")
                .unwrap();
        assert_eq!(created_notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(created_notification.payload(), "");

        // Model two server nodes with separate pools and PostgreSQL backend
        // connections, both targeting the same immutable resolution request.
        let url = std::env::var("ATERMIUS_TEST_PG_URL").unwrap();
        let options = PgConnectOptions::from_str(&url).unwrap();
        let search_path = format!("\"{}\"", database.schema);
        let node_a_pool = PgPoolOptions::new()
            .max_connections(1)
            .connect_with(
                options
                    .clone()
                    .options([("search_path", search_path.clone())]),
            )
            .await
            .expect("connect first isolated server-node pool");
        let node_b_pool = PgPoolOptions::new()
            .max_connections(1)
            .connect_with(options.options([("search_path", search_path)]))
            .await
            .expect("connect second isolated server-node pool");
        let node_a_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&node_a_pool)
            .await
            .unwrap();
        let node_b_pid: i32 = sqlx::query_scalar("SELECT pg_backend_pid()")
            .fetch_one(&node_b_pool)
            .await
            .unwrap();
        assert_ne!(
            node_a_pid, node_b_pid,
            "independent node pools must use separate PostgreSQL connections"
        );

        let node_a = PgSyncConflictWriteRepository::new(node_a_pool.clone());
        let node_b = PgSyncConflictWriteRepository::new(node_b_pool.clone());
        let start = std::sync::Arc::new(tokio::sync::Barrier::new(3));
        let node_a_start = start.clone();
        let node_a_task = tokio::spawn(async move {
            node_a_start.wait().await;
            node_a
                .resolve_conflict(resolve_command(
                    "concurrent-resolution-conflict",
                    "current-r1",
                ))
                .await
        });
        let node_b_start = start.clone();
        let node_b_task = tokio::spawn(async move {
            node_b_start.wait().await;
            node_b
                .resolve_conflict(resolve_command(
                    "concurrent-resolution-conflict",
                    "current-r1",
                ))
                .await
        });
        start.wait().await;
        let node_a_result = node_a_task.await.unwrap().unwrap();
        let node_b_result = node_b_task.await.unwrap().unwrap();

        let first_commits = [&node_a_result, &node_b_result]
            .into_iter()
            .filter(|response| response["already_resolved"] == false)
            .count();
        let replays = [&node_a_result, &node_b_result]
            .into_iter()
            .filter(|response| response["already_resolved"] == true)
            .count();
        assert_eq!(
            first_commits, 1,
            "exactly one node should commit resolution"
        );
        assert_eq!(
            replays, 1,
            "the other node should replay the committed result"
        );
        for response in [&node_a_result, &node_b_result] {
            assert_eq!(response["status"], "resolved");
            assert_eq!(response["resolved_revision_id"], "current-r1");
            assert_eq!(response["resolution_seq"], "2");
        }

        let notification = tokio::time::timeout(std::time::Duration::from_secs(2), listener.recv())
            .await
            .expect("one committed resolution should notify sync listeners")
            .unwrap();
        assert_eq!(notification.channel(), "atermius_sync_wake_v1");
        assert_eq!(notification.payload(), "");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "concurrent replay must not emit a second notification"
        );

        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            2,
            "one resolution should allocate exactly one conflict sequence"
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            1,
            "resolution should update the one existing conflict-feed row"
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM conflicts WHERE conflict_id='concurrent-resolution-conflict' AND resolved_revision_id='current-r1' AND resolution_seq=2"
            )
            .await,
            1,
            "the conflict feed should contain one resolved row with the stored revision and sequence"
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM audit_events WHERE action='vault.conflict_resolved' AND resource_id='concurrent-resolution-conflict'"
            )
            .await,
            1,
            "resolution should create exactly one audit event"
        );

        let mismatch = PgSyncConflictWriteRepository::new(node_a_pool.clone())
            .resolve_conflict(resolve_command(
                "concurrent-resolution-conflict",
                "different-revision",
            ))
            .await
            .unwrap_err();
        assert_eq!(mismatch.body.code, "CONFLICT_ALREADY_RESOLVED");
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(150), listener.recv())
                .await
                .is_err(),
            "mismatched replay must not emit a notification"
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            2,
            "mismatched replay must not allocate another sequence"
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            1,
            "mismatched replay must not add a conflict-feed row"
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM audit_events WHERE action='vault.conflict_resolved' AND resource_id='concurrent-resolution-conflict'"
            )
            .await,
            1,
            "mismatched replay must not add another audit event"
        );

        drop(listener);
        node_a_pool.close().await;
        node_b_pool.close().await;
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL auth-fence acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_create_rejects_expired_wrong_session_revoked_device_and_viewer() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        let mut wrong_access = create_command(
            "wrong-access",
            operation("wrong-access-op", "record-a", "branch-a", 1),
        );
        wrong_access.user.access_hash = "wrong-access-hash".to_owned();
        assert_eq!(
            repository
                .create_conflict(wrong_access)
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED"
        );
        sqlx::query("UPDATE sessions SET revoked_at=CURRENT_TIMESTAMP WHERE session_id=$1")
            .bind(SESSION)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "revoked-session",
                    operation("revoked-session-op", "record-r", "branch-r", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED"
        );
        sqlx::query("UPDATE sessions SET revoked_at=NULL WHERE session_id=$1")
            .bind(SESSION)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE sessions SET access_expires_at=CURRENT_TIMESTAMP-INTERVAL '1 second' WHERE session_id=$1")
            .bind(SESSION)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "expired-session",
                    operation("expired-op", "record-b", "branch-b", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED"
        );
        sqlx::query("UPDATE sessions SET access_expires_at=CURRENT_TIMESTAMP+INTERVAL '1 hour' WHERE session_id=$1")
            .bind(SESSION)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE users SET status='deleting' WHERE user_id=$1")
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "inactive-account",
                    operation("inactive-account-op", "record-u", "branch-u", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "AUTH_REQUIRED"
        );
        sqlx::query("UPDATE users SET status='active' WHERE user_id=$1")
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "revoked-device",
                    operation("revoked-op", "record-c", "branch-c", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "DEVICE_REVOKED"
        );
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=$1")
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_members SET state='removed' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT)
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "inactive-member",
                    operation("inactive-member-op", "record-m", "branch-m", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "NOT_FOUND"
        );
        sqlx::query("UPDATE vault_members SET state='active',role='viewer' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT)
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            repository
                .create_conflict(create_command(
                    "viewer-member",
                    operation("viewer-op", "record-d", "branch-d", 1),
                ))
                .await
                .unwrap_err()
                .body
                .code,
            "VAULT_READ_ONLY"
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM conflicts").await,
            0
        );
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            0
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL audit atomicity acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_resolution_audit_failure_rolls_back_resolution_and_sequence() {
        let database = TestDatabase::create().await;
        seed_current_revision(&database.pool, "record", "current-r1").await;
        let repository = PgSyncConflictWriteRepository::new(database.pool.clone());
        repository
            .create_conflict(create_command(
                "audit-failure-conflict",
                operation("audit-failure-op", "record", "branch-r2", 1),
            ))
            .await
            .unwrap();
        sqlx::query("ALTER TABLE audit_events ADD CONSTRAINT reject_conflict_resolution_audit CHECK (action <> 'vault.conflict_resolved')")
            .execute(&database.pool)
            .await
            .unwrap();
        assert!(
            repository
                .resolve_conflict(resolve_command("audit-failure-conflict", "current-r1"))
                .await
                .is_err()
        );
        let resolved: Option<String> = sqlx::query_scalar(
            "SELECT resolved_revision_id FROM conflicts WHERE conflict_id='audit-failure-conflict'",
        )
        .fetch_one(&database.pool)
        .await
        .unwrap();
        assert_eq!(resolved, None);
        assert_eq!(
            count(
                &database.pool,
                "SELECT last_conflict_seq FROM vault_counters"
            )
            .await,
            1
        );
        assert_eq!(
            count(&database.pool, "SELECT count(*) FROM audit_events").await,
            0
        );
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL migration cleanup acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_write_migration_preserves_legacy_rows_and_signer_ids() {
        let database = TestDatabase::create_before_write_migration().await;
        sqlx::query(r#"INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq) VALUES('legacy-conflict',$1,'legacy-record',NULL,'{"header":{"op_id":"00000000-0000-4000-8000-000000000001"}}','legacy-digest',$2,CURRENT_TIMESTAMP,1),('legacy-duplicate',$1,'legacy-record',NULL,'{"header":{"op_id":"00000000-0000-4000-8000-000000000001"}}','legacy-digest-2',$2,CURRENT_TIMESTAMP,2)"#)
            .bind(VAULT)
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES('pg-conflict-other-owner','other-owner','active')")
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,'pg-conflict-other-owner','owner','active')")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vaults SET owner_user_id='pg-conflict-other-owner' WHERE vault_id=$1")
            .bind(VAULT)
            .execute(&database.pool)
            .await
            .unwrap();
        database.apply_write_migration().await;
        let op_id: Option<String> =
            sqlx::query_scalar("SELECT op_id FROM conflicts WHERE conflict_id='legacy-conflict'")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(
            op_id.as_deref(),
            Some("00000000-0000-4000-8000-000000000001")
        );
        let duplicate_op_id: Option<String> =
            sqlx::query_scalar("SELECT op_id FROM conflicts WHERE conflict_id='legacy-duplicate'")
                .fetch_one(&database.pool)
                .await
                .unwrap();
        assert_eq!(duplicate_op_id, None);
        sqlx::query("DELETE FROM devices WHERE device_id=$1")
            .bind(DEVICE)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("DELETE FROM users WHERE user_id=$1")
            .bind(USER)
            .execute(&database.pool)
            .await
            .unwrap();
        assert_eq!(
            count(
                &database.pool,
                "SELECT count(*) FROM conflicts WHERE device_id='pg-conflict-device'"
            )
            .await,
            2
        );
        database.cleanup().await;
    }
}

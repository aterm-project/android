//! PostgreSQL implementation of the bounded conflict-feed read capability.
//!
//! This bounded capability is composed into `PgSyncRepository` for the
//! restricted PostgreSQL sync runtime. It implements only the shared
//! conflict-feed repository boundary over the additive schema in
//! `migrations/postgres/0005_sync_conflict_feed.sql`.

use futures_util::TryStreamExt;
use serde_json::{Value, json};
use sqlx::{PgPool, Row};

use crate::{
    ApiError,
    auth::AuthUser,
    pg_record_redaction::{
        PgRedactionProofSigner, redaction_columns, redaction_from_join_row,
        require_redaction_client_for_vault_tx,
    },
    sync::{
        SyncPageBudget, ensure_envelope_readable, ensure_sync_page_response_fits,
        sync_page_item_too_large,
    },
    sync_repository::{ConflictChangesPageCommand, RepositoryFuture},
};

/// A narrow capability so this adapter cannot be mistaken for the complete
/// PostgreSQL sync repository.
pub(crate) trait SyncConflictChangesReadRepository: Send + Sync {
    fn read_conflict_changes_page(
        &self,
        command: ConflictChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct PgSyncConflictChangesReadRepository {
    pool: PgPool,
    proof_signer: Option<PgRedactionProofSigner>,
}

impl PgSyncConflictChangesReadRepository {
    /// Expects the PostgreSQL sync-core schema plus
    /// `0005_sync_conflict_feed.sql` in the pool search path.
    pub(crate) fn new(pool: PgPool) -> Self {
        Self {
            pool,
            proof_signer: None,
        }
    }

    pub(crate) fn with_signer(pool: PgPool, proof_signer: PgRedactionProofSigner) -> Self {
        Self {
            pool,
            proof_signer: Some(proof_signer),
        }
    }

    async fn read_page(&self, command: ConflictChangesPageCommand) -> Result<Value, ApiError> {
        #[cfg(test)]
        let test_pause = command.test_pause.clone();

        let ConflictChangesPageCommand {
            user,
            vault_id,
            after_seq,
            after_seq_wire,
            limit,
            server_generation,
            generation,
            ..
        } = command;
        // Match SQLite's repository boundary even when an internal caller
        // bypasses the HTTP query parser.
        let limit = limit.clamp(1, 500);

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        // Keep authorization, checkpoint validation, high watermark, and rows
        // in one MVCC snapshot. This must remain the transaction's first SQL
        // statement because PostgreSQL defaults to statement-scoped READ COMMITTED.
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        require_active_session_device_read(&mut tx, &user).await?;
        let member: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM vaults v \
             JOIN vault_members vm ON vm.vault_id=v.vault_id \
             JOIN users u ON u.user_id=vm.user_id \
             WHERE v.vault_id=$1 AND vm.user_id=$2 \
               AND vm.state='active' AND u.status='active'",
        )
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if member.is_none() {
            return Err(ApiError::not_found());
        }
        require_redaction_client_for_vault_tx(&mut tx, &vault_id, &user).await?;

        // Match the SQLite error precedence: Vault membership is established
        // before the generation checkpoint or sequence is examined.
        if server_generation
            .as_deref()
            .is_some_and(|checkpoint| checkpoint != generation)
        {
            return Err(ApiError::gone(
                "CONFLICT_FEED_GENERATION_CHANGED",
                "conflict feed checkpoint belongs to another server generation",
            )
            .with_details(json!({
                "server_generation": server_generation,
                "current_generation": generation,
                "recovery": "restart_from_zero",
            })));
        }

        let high_watermark: i64 =
            sqlx::query_scalar("SELECT last_conflict_seq FROM vault_counters WHERE vault_id=$1")
                .bind(&vault_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        if after_seq > high_watermark {
            return Err(ApiError::gone(
                "CONFLICT_FEED_SEQUENCE_AHEAD",
                "after_seq is beyond the current conflict feed high watermark",
            )
            .with_details(json!({ "recovery": "restart_from_zero" })));
        }

        // Acceptance tests pause after the snapshot and bounds have been read,
        // then commit a concurrent feed write from another connection.
        #[cfg(test)]
        if let Some(pause) = test_pause.as_ref() {
            pause.pause().await;
        }

        let redaction_columns = redaction_columns("rr");
        let rows_sql = format!(
            "SELECT feed.seq,feed.event_type,feed.conflict_id,feed.record_id,feed.base_revision_id,\
                    feed.resolved_revision_id,\
                    to_char(feed.created_at AT TIME ZONE 'UTC',\
                            'YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"') AS created_at,\
                    feed.envelope,{redaction_columns} \
             FROM (\
               SELECT vault_id,conflict_seq AS seq,'created'::TEXT AS event_type,\
                      conflict_id,record_id,base_revision_id,\
                      NULL::TEXT AS resolved_revision_id,created_at,envelope \
               FROM conflicts \
               WHERE vault_id=$1 AND conflict_seq>$2 AND conflict_seq<=$3 \
             UNION ALL \
               SELECT vault_id,resolution_seq AS seq,'resolved'::TEXT AS event_type,\
                      conflict_id,record_id,base_revision_id,\
                      resolved_revision_id,resolution_at AS created_at,\
               NULL::TEXT AS envelope \
               FROM conflicts \
               WHERE vault_id=$4 AND resolution_seq>$5 AND resolution_seq<=$6\
             ) AS feed \
             LEFT JOIN record_redactions rr ON rr.vault_id=feed.vault_id AND rr.record_id=feed.record_id \
             ORDER BY feed.seq ASC LIMIT $7"
        );
        let mut rows = sqlx::query(&rows_sql)
            .bind(&vault_id)
            .bind(after_seq)
            .bind(high_watermark)
            .bind(&vault_id)
            .bind(after_seq)
            .bind(high_watermark)
            .bind(limit + 1)
            .fetch(&mut *tx);

        let mut events = Vec::new();
        let mut budget = SyncPageBudget::default();
        let mut has_more = false;
        let mut next_after_seq = after_seq;
        while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
            if events.len() >= limit as usize {
                has_more = true;
                break;
            }
            let event_type: String = row.get("event_type");
            let is_created = event_type == "created";
            let event = if let Some(statement) = redaction_from_join_row(&row)? {
                let signer = self
                    .proof_signer
                    .as_ref()
                    .ok_or_else(|| ApiError::internal("redaction proof signer is unavailable"))?;
                json!({
                    "seq": row.get::<i64, _>("seq").to_string(),
                    "type": "redacted",
                    "conflict_id": row.get::<String, _>("conflict_id"),
                    "record_id": row.get::<String, _>("record_id"),
                    "redaction": signer.proof(&statement)?,
                })
            } else {
                let mut event = json!({
                    "seq": row.get::<i64, _>("seq").to_string(),
                    "type": event_type,
                    "conflict_id": row.get::<String, _>("conflict_id"),
                    "record_id": row.get::<String, _>("record_id"),
                    "base_revision_id": row.get::<Option<String>, _>("base_revision_id"),
                    "resolved_revision_id": row.get::<Option<String>, _>("resolved_revision_id"),
                    "created_at": row.get::<String, _>("created_at"),
                });
                if is_created {
                    let encoded: Option<String> = row.get("envelope");
                    let encoded = encoded.ok_or_else(|| {
                        ApiError::internal("unredacted conflict is missing its envelope")
                    })?;
                    let envelope =
                        serde_json::from_str::<Value>(&encoded).map_err(ApiError::internal)?;
                    ensure_envelope_readable(user.declares_record_schema2, &envelope)?;
                    event["envelope"] = envelope;
                }
                event
            };
            if !budget.try_add(&event)? {
                if events.is_empty() {
                    return Err(sync_page_item_too_large());
                }
                has_more = true;
                break;
            }
            next_after_seq = row.get("seq");
            events.push(event);
        }
        drop(rows);

        let response = json!({
            "vault_id": vault_id,
            "after_seq": after_seq_wire,
            "high_watermark": high_watermark.to_string(),
            "events": events,
            "next_after_seq": next_after_seq.to_string(),
            "has_more": has_more,
            "server_generation": generation,
        });
        ensure_sync_page_response_fits(&response)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }
}

impl SyncConflictChangesReadRepository for PgSyncConflictChangesReadRepository {
    fn read_conflict_changes_page(
        &self,
        command: ConflictChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_page(command))
    }
}

async fn require_active_session_device_read(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT s.revoked_at IS NOT NULL AS revoked,\
                s.access_expires_at>CURRENT_TIMESTAMP AS unexpired,\
                u.status AS account_status,d.status AS device_status \
         FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        return Err(ApiError::unauthorized());
    };
    if row.get::<bool, _>("revoked")
        || !row.get::<bool, _>("unexpired")
        || row.get::<String, _>("account_status") != "active"
    {
        return Err(ApiError::unauthorized());
    }
    if row.get::<String, _>("device_status") != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        sync::Arc,
        time::Duration,
    };

    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use ed25519_dalek::SigningKey;
    use futures_util::FutureExt;
    use sqlx::{PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use uuid::Uuid;

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const RETENTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const SNAPSHOT_MIGRATION: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );
    const USER_ID: &str = "pg-conflict-user";
    const DEVICE_ID: &str = "pg-conflict-device";
    const SESSION_ID: &str = "pg-conflict-session";
    const VAULT_ID: &str = "e950523f-c2bd-42fb-a66c-d9c87d86d331";
    const ACCESS_HASH: &str = "pg-conflict-access-hash";
    const GENERATION: &str = "4bcf11d5-99ed-49f3-8012-6f1d706edc91";

    struct TestDatabase {
        pool: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    /// Armed immediately after schema creation so failures while connecting,
    /// migrating, or seeding cannot strand the isolated test schema.
    struct SchemaSetupCleanupGuard {
        admin_pool: PgPool,
        schema: String,
        armed: bool,
    }

    impl SchemaSetupCleanupGuard {
        fn new(admin_pool: PgPool, schema: String) -> Self {
            Self {
                admin_pool,
                schema,
                armed: true,
            }
        }

        async fn cleanup(&mut self) {
            if !self.armed {
                return;
            }
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated schema after fixture setup failure");
            self.armed = false;
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
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL conflict-feed tests require ATERMIUS_TEST_PG_URL");
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
            let schema = format!("atermius_pg_conflict_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL test schema");
            let mut setup_guard = SchemaSetupCleanupGuard::new(admin_pool.clone(), schema.clone());
            let setup = AssertUnwindSafe(async {
                let pool = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
                    .await
                    .expect("connect isolated PostgreSQL search path");
                sqlx::raw_sql(CORE_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply bounded PostgreSQL sync-core schema");
                sqlx::raw_sql(RETENTION_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL changes-read schema");
                sqlx::raw_sql(CONFLICT_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL conflict-feed schema");
                sqlx::raw_sql(SNAPSHOT_MIGRATION)
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
                sqlx::raw_sql(REDACTION_MIGRATION)
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
                    let database = Self {
                        pool,
                        admin_pool,
                        schema,
                        cleaned: false,
                    };
                    setup_guard.disarm();
                    database
                }
                Err(payload) => {
                    setup_guard.cleanup().await;
                    resume_unwind(payload)
                }
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
            .expect("drop isolated PostgreSQL test schema");
            let remains: bool =
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM pg_namespace WHERE nspname=$1)")
                    .bind(&self.schema)
                    .fetch_one(&self.admin_pool)
                    .await
                    .expect("verify isolated PostgreSQL test schema cleanup");
            assert!(
                !remains,
                "isolated PostgreSQL test schema remains after cleanup"
            );
            self.cleaned = true;
            self.admin_pool.close().await;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            // This fallback runs if a test panics before explicit cleanup.
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
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) VALUES($1,$2,'reader','active')",
        )
        .bind(DEVICE_ID)
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,'pg-conflict-refresh-hash',CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
            .bind(SESSION_ID)
            .bind(USER_ID)
            .bind(DEVICE_ID)
            .bind(ACCESS_HASH)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) VALUES($1,$2,'active',1,1)",
        )
        .bind(VAULT_ID)
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
        )
        .bind(VAULT_ID)
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO vault_counters(vault_id,last_committed_seq,minimum_available_seq,last_conflict_seq) VALUES($1,0,1,0)",
        )
        .bind(VAULT_ID)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn insert_conflict(pool: &PgPool, conflict_id: &str, seq: i64, envelope: &str) {
        let record_id = format!("record-{conflict_id}");
        let digest = crate::sha256_hex(envelope.as_bytes());
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq) VALUES($1,$2,$3,'base-revision',$4,$5,$6,CURRENT_TIMESTAMP,$7)")
            .bind(conflict_id)
            .bind(VAULT_ID)
            .bind(record_id)
            .bind(envelope)
            .bind(digest)
            .bind(DEVICE_ID)
            .bind(seq)
            .execute(pool)
            .await
            .unwrap();
    }

    async fn set_high_watermark(pool: &PgPool, seq: i64) {
        sqlx::query("UPDATE vault_counters SET last_conflict_seq=$1 WHERE vault_id=$2")
            .bind(seq)
            .bind(VAULT_ID)
            .execute(pool)
            .await
            .unwrap();
    }

    async fn insert_resolution(pool: &PgPool, conflict_id: &str, seq: i64) {
        sqlx::query("UPDATE conflicts SET resolved_revision_id='resolved-revision',resolution_seq=$1,resolution_at=CURRENT_TIMESTAMP WHERE conflict_id=$2 AND vault_id=$3")
            .bind(seq)
            .bind(conflict_id)
            .bind(VAULT_ID)
            .execute(pool)
            .await
            .unwrap();
        set_high_watermark(pool, seq).await;
    }

    fn actor() -> AuthUser {
        AuthUser {
            user_id: USER_ID.to_owned(),
            device_id: DEVICE_ID.to_owned(),
            session_id: SESSION_ID.to_owned(),
            access_hash: ACCESS_HASH.to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        }
    }

    fn proof_signer() -> PgRedactionProofSigner {
        let key = Arc::new(SigningKey::from_bytes(&[0x59; 32]));
        let instance = crate::InstanceInfo {
            instance_id: "3a25ea6e-53f5-47b6-9d82-97c43acb8a0b".to_owned(),
            server_space_id: "60fa13ac-45b6-449a-a980-b83d77a0f5b0".to_owned(),
            generation: GENERATION.to_owned(),
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
            signing_key_transitions: Vec::new(),
        };
        PgRedactionProofSigner::new(instance, key)
    }

    fn command(
        user: AuthUser,
        after_seq: i64,
        after_seq_wire: &str,
        server_generation: Option<String>,
        limit: i64,
    ) -> ConflictChangesPageCommand {
        ConflictChangesPageCommand {
            user,
            vault_id: VAULT_ID.to_owned(),
            after_seq,
            after_seq_wire: after_seq_wire.to_owned(),
            limit,
            server_generation,
            generation: GENERATION.to_owned(),
            test_pause: None,
        }
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL redaction acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_replaces_redacted_payload_with_signed_marker() {
        let database = TestDatabase::create().await;
        let repository =
            PgSyncConflictChangesReadRepository::with_signer(database.pool.clone(), proof_signer());
        let conflict_id = Uuid::new_v4().to_string();
        let record_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        let redaction_id = Uuid::new_v4().to_string();
        let envelope = r#"{"header":{"record_schema":1},"ciphertext":"must-not-leak"}"#;
        let digest = crate::sha256_hex(envelope.as_bytes());
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq) VALUES($1,$2,$3,$4,$5,$6,$7,CURRENT_TIMESTAMP,1)")
            .bind(&conflict_id)
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&revision_id)
            .bind(envelope)
            .bind(digest)
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        set_high_watermark(&database.pool, 1).await;
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,1)")
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&revision_id)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=2 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,1,2)")
            .bind(&redaction_id)
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&revision_id)
            .execute(&database.pool)
            .await
            .unwrap();

        let page = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 10))
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        let event = &events[0];
        assert_eq!(event["type"], "redacted");
        assert_eq!(event["conflict_id"], conflict_id);
        assert_eq!(event["record_id"], record_id);
        assert_eq!(event["redaction"]["redaction_id"], redaction_id);
        assert_eq!(event.as_object().unwrap().len(), 5);
        assert!(event.get("envelope").is_none());
        assert!(event.get("base_revision_id").is_none());

        let mut legacy = actor();
        legacy.declares_sync_redaction_v1 = false;
        let error = repository
            .read_conflict_changes_page(command(legacy, 0, "0", None, 10))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::UPGRADE_REQUIRED);
        assert_eq!(error.body.code, "CLIENT_REDACTION_CAPABILITY_REQUIRED");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-feed acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_pages_created_and_resolved_events_as_a_replayable_prefix() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictChangesReadRepository::new(database.pool.clone());
        let first_id = Uuid::new_v4().to_string();
        let second_id = Uuid::new_v4().to_string();
        let envelope1 = r#"{"header":{"record_schema":1},"ciphertext":"branch-one"}"#;
        let envelope2 = r#"{"header":{"record_schema":1},"ciphertext":"branch-two"}"#;
        insert_conflict(&database.pool, &first_id, 1, envelope1).await;
        insert_conflict(&database.pool, &second_id, 2, envelope2).await;
        insert_resolution(&database.pool, &first_id, 3).await;

        let first = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 2))
            .await
            .unwrap();
        assert_eq!(first["vault_id"], VAULT_ID);
        assert_eq!(first["after_seq"], "0");
        assert_eq!(first["high_watermark"], "3");
        assert_eq!(first["server_generation"], GENERATION);
        assert_eq!(first["has_more"], true);
        assert_eq!(first["next_after_seq"], "2");
        assert_eq!(first["events"].as_array().unwrap().len(), 2);
        assert_eq!(first["events"][0]["seq"], "1");
        assert_eq!(first["events"][0]["type"], "created");
        assert_eq!(first["events"][0]["conflict_id"], first_id);
        assert_eq!(first["events"][0]["envelope"]["ciphertext"], "branch-one");
        assert_eq!(first["events"][1]["seq"], "2");
        assert_eq!(first["events"][1]["type"], "created");
        assert_eq!(first["events"][1]["conflict_id"], second_id);

        let replay = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 2))
            .await
            .unwrap();
        assert_eq!(replay, first);

        let second = repository
            .read_conflict_changes_page(command(actor(), 2, "2", Some(GENERATION.to_owned()), 2))
            .await
            .unwrap();
        assert_eq!(second["events"].as_array().unwrap().len(), 1);
        let resolved = &second["events"][0];
        assert_eq!(resolved["seq"], "3");
        assert_eq!(resolved["type"], "resolved");
        assert_eq!(resolved["conflict_id"], first_id);
        assert_eq!(resolved["resolved_revision_id"], "resolved-revision");
        assert!(resolved.get("envelope").is_none());
        assert_eq!(second["next_after_seq"], "3");
        assert_eq!(second["has_more"], false);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-feed bounds acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_rejects_stale_generation_and_ahead_sequence_and_bounds_pages() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictChangesReadRepository::new(database.pool.clone());
        for seq in 1..=3 {
            let id = Uuid::new_v4().to_string();
            let envelope =
                format!(r#"{{"header":{{"record_schema":1}},"ciphertext":"branch-{seq}"}}"#);
            insert_conflict(&database.pool, &id, seq, &envelope).await;
        }
        set_high_watermark(&database.pool, 3).await;

        let foreign_generation = "8bcf11d5-99ed-49f3-8012-6f1d706edc91".to_owned();
        let generation_error = repository
            .read_conflict_changes_page(command(
                actor(),
                0,
                "0",
                Some(foreign_generation.clone()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(generation_error.status, axum::http::StatusCode::GONE);
        assert_eq!(
            generation_error.body.code,
            "CONFLICT_FEED_GENERATION_CHANGED"
        );
        assert_eq!(
            generation_error.body.details.unwrap(),
            json!({
                "server_generation": foreign_generation,
                "current_generation": GENERATION,
                "recovery": "restart_from_zero"
            })
        );

        let ahead_error = repository
            .read_conflict_changes_page(command(actor(), 4, "4", Some(GENERATION.to_owned()), 10))
            .await
            .unwrap_err();
        assert_eq!(ahead_error.status, axum::http::StatusCode::GONE);
        assert_eq!(ahead_error.body.code, "CONFLICT_FEED_SEQUENCE_AHEAD");
        assert_eq!(
            ahead_error.body.details.unwrap(),
            json!({ "recovery": "restart_from_zero" })
        );

        // Match the storage contract's defensive clamp for internal callers.
        let clamped_low = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 0))
            .await
            .unwrap();
        assert_eq!(clamped_low["events"].as_array().unwrap().len(), 1);
        assert_eq!(clamped_low["next_after_seq"], "1");
        assert_eq!(clamped_low["has_more"], true);
        let clamped_high = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 501))
            .await
            .unwrap();
        assert_eq!(clamped_high["events"].as_array().unwrap().len(), 3);
        assert_eq!(clamped_high["next_after_seq"], "3");
        assert_eq!(clamped_high["has_more"], false);

        // Schema-2 payloads are rejected unless the active caller declared
        // support, matching `ensure_envelope_readable` on the SQLite reader.
        let schema2_id = Uuid::new_v4().to_string();
        insert_conflict(
            &database.pool,
            &schema2_id,
            4,
            r#"{"header":{"record_schema":2},"ciphertext":"schema-two"}"#,
        )
        .await;
        set_high_watermark(&database.pool, 4).await;
        let schema2_error = repository
            .read_conflict_changes_page(command(actor(), 3, "3", None, 10))
            .await
            .unwrap_err();
        assert_eq!(schema2_error.status, axum::http::StatusCode::CONFLICT);
        assert_eq!(schema2_error.body.code, "VAULT_CLIENT_CAPABILITY_REQUIRED");
        let mut capable_actor = actor();
        capable_actor.declares_record_schema2 = true;
        let schema2_page = repository
            .read_conflict_changes_page(command(capable_actor, 3, "3", None, 10))
            .await
            .unwrap();
        assert_eq!(schema2_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(schema2_page["events"][0]["seq"], "4");
        assert_eq!(
            schema2_page["events"][0]["envelope"]["header"]["record_schema"],
            2
        );

        // A single created event larger than the shared page budget fails
        // closed instead of returning an empty page with a stuck cursor.
        let oversized_id = Uuid::new_v4().to_string();
        let oversized = format!(
            r#"{{"header":{{"record_schema":1}},"ciphertext":"{}"}}"#,
            "x".repeat(4 * 1024 * 1024)
        );
        insert_conflict(&database.pool, &oversized_id, 5, &oversized).await;
        set_high_watermark(&database.pool, 5).await;
        let size_error = repository
            .read_conflict_changes_page(command(actor(), 4, "4", None, 10))
            .await
            .unwrap_err();
        assert_eq!(size_error.status, axum::http::StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(size_error.body.code, "PAYLOAD_TOO_LARGE");

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-feed authorization acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_rechecks_session_device_and_membership_before_checkpoints() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictChangesReadRepository::new(database.pool.clone());

        let mut wrong_session = actor();
        wrong_session.access_hash = "wrong-access-hash".to_owned();
        let unauthenticated = repository
            .read_conflict_changes_page(command(
                wrong_session,
                0,
                "0",
                Some("8bcf11d5-99ed-49f3-8012-6f1d706edc91".to_owned()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(unauthenticated.status, axum::http::StatusCode::UNAUTHORIZED);

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let revoked_device = repository
            .read_conflict_changes_page(command(actor(), 0, "0", None, 10))
            .await
            .unwrap_err();
        assert_eq!(revoked_device.status, axum::http::StatusCode::FORBIDDEN);
        assert_eq!(revoked_device.body.code, "DEVICE_REVOKED");
        sqlx::query("UPDATE devices SET status='active' WHERE device_id=$1")
            .bind(DEVICE_ID)
            .execute(&database.pool)
            .await
            .unwrap();

        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=$1 AND user_id=$2")
            .bind(VAULT_ID)
            .bind(USER_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let missing_member = repository
            .read_conflict_changes_page(command(
                actor(),
                0,
                "0",
                Some("8bcf11d5-99ed-49f3-8012-6f1d706edc91".to_owned()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(missing_member.status, axum::http::StatusCode::NOT_FOUND);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-feed snapshot acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_snapshot_keeps_high_watermark_and_rows_together_during_write() {
        let database = TestDatabase::create().await;
        let first_id = Uuid::new_v4().to_string();
        insert_conflict(
            &database.pool,
            &first_id,
            1,
            r#"{"header":{"record_schema":1},"ciphertext":"before"}"#,
        )
        .await;
        set_high_watermark(&database.pool, 1).await;

        let pause = Arc::new(crate::recovery::TestPause::new());
        let _release_pause = crate::recovery::ReleasePauseOnDrop::new(pause.clone());
        let read_repository = PgSyncConflictChangesReadRepository::new(database.pool.clone());
        let mut page_command = command(actor(), 0, "0", None, 10);
        page_command.test_pause = Some(pause.clone());
        let read = tokio::spawn(async move {
            read_repository
                .read_conflict_changes_page(page_command)
                .await
        });

        tokio::time::timeout(Duration::from_secs(5), pause.wait_until_reached())
            .await
            .expect("reader reaches pause after snapshot bounds");

        // The feed writer updates the counter and creates the row in one
        // transaction. A repeatable-read page must see both before or neither.
        let second_id = Uuid::new_v4().to_string();
        let mut writer = database.pool.begin().await.unwrap();
        sqlx::query("UPDATE vault_counters SET last_conflict_seq=2 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        let envelope = r#"{"header":{"record_schema":1},"ciphertext":"after"}"#;
        let digest = crate::sha256_hex(envelope.as_bytes());
        sqlx::query("INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest,device_id,created_at,conflict_seq) VALUES($1,$2,$3,'base-revision',$4,$5,$6,CURRENT_TIMESTAMP,2)")
            .bind(&second_id)
            .bind(VAULT_ID)
            .bind(format!("record-{second_id}"))
            .bind(envelope)
            .bind(digest)
            .bind(DEVICE_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        writer.commit().await.unwrap();

        pause.release();
        let first_page = tokio::time::timeout(Duration::from_secs(5), read)
            .await
            .expect("snapshot read completes")
            .unwrap()
            .unwrap();
        assert_eq!(first_page["high_watermark"], "1");
        assert_eq!(first_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(first_page["events"][0]["seq"], "1");
        assert_eq!(first_page["events"][0]["conflict_id"], first_id);
        assert_eq!(first_page["next_after_seq"], "1");
        assert_eq!(first_page["has_more"], false);

        let next_page = PgSyncConflictChangesReadRepository::new(database.pool.clone())
            .read_conflict_changes_page(command(actor(), 1, "1", Some(GENERATION.to_owned()), 10))
            .await
            .unwrap();
        assert_eq!(next_page["high_watermark"], "2");
        assert_eq!(next_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(next_page["events"][0]["seq"], "2");
        assert_eq!(next_page["events"][0]["conflict_id"], second_id);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL conflict-feed cleanup acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_conflict_feed_error_rolls_back_and_disposable_schema_is_removed() {
        let database = TestDatabase::create().await;
        let repository = PgSyncConflictChangesReadRepository::new(database.pool.clone());
        let error = repository
            .read_conflict_changes_page(command(
                actor(),
                0,
                "0",
                Some("8bcf11d5-99ed-49f3-8012-6f1d706edc91".to_owned()),
                10,
            ))
            .await
            .unwrap_err();
        assert_eq!(error.body.code, "CONFLICT_FEED_GENERATION_CHANGED");

        // A failed read must release its transaction/connection, and explicit
        // cleanup verifies the isolated schema is gone from the test database.
        let health: i32 = sqlx::query_scalar("SELECT 1")
            .fetch_one(&database.pool)
            .await
            .expect("connection is reusable after a failed page read");
        assert_eq!(health, 1);
        database.cleanup().await;
    }
}

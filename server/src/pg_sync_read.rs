//! PostgreSQL implementation of the bounded `/sync/changes` read capability.
//!
//! This bounded capability is composed into `PgSyncRepository` for the
//! restricted PostgreSQL sync runtime. It implements the shared changes-page
//! repository boundary with the same command and cursor/response helpers as
//! SQLite.

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
        SyncPageBudget, cursor_is_expired, encode_cursor_with_key, ensure_envelope_readable,
        ensure_sync_page_response_fits, parse_cursor_with_key, sync_page_item_too_large,
    },
    sync_repository::{ChangesPageCommand, RepositoryFuture},
};

/// A narrow capability so callers cannot mistake this read slice for the
/// complete PostgreSQL sync repository.
pub(crate) trait SyncChangesReadRepository: Send + Sync {
    fn read_changes_page(
        &self,
        command: ChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>>;
}

pub(crate) struct PgSyncChangesReadRepository {
    pool: PgPool,
    proof_signer: Option<PgRedactionProofSigner>,
}

impl PgSyncChangesReadRepository {
    /// Expects the dedicated PostgreSQL sync-core schema plus
    /// `0002_sync_changes_retention.sql` in the pool search path.
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

    async fn read_page(&self, command: ChangesPageCommand) -> Result<Value, ApiError> {
        #[cfg(test)]
        let test_pause = command.test_pause.clone();

        let ChangesPageCommand {
            user,
            vault_id,
            raw_cursor,
            limit,
            cursor_key,
            generation,
            ..
        } = command;
        // Match the existing storage-boundary clamp. PostgreSQL accepts
        // LIMIT 0 and negative-looking values differently from SQLite, so do
        // not rely on the HTTP extractor as the only guard.
        let limit = limit.clamp(1, 500);

        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        // This must be the transaction's first SQL statement: all following
        // authorization, membership, high-watermark/floor, and event reads
        // must use one PostgreSQL MVCC snapshot while commits and retention
        // can proceed concurrently.
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;

        require_active_session_device_read(&mut tx, &user).await?;
        let member: Option<i32> = sqlx::query_scalar(
            "SELECT 1 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=$1 AND vm.user_id=$2 AND vm.state='active' AND u.status='active'",
        )
        .bind(&vault_id)
        .bind(&user.user_id)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if member.is_none() {
            // Preserve the existing read contract: deleting Vaults remain
            // readable during the deletion window, but inactive membership
            // and unknown Vault IDs are indistinguishable.
            return Err(ApiError::not_found());
        }
        require_redaction_client_for_vault_tx(&mut tx, &vault_id, &user).await?;

        // Parse only after the membership check so malformed and recovery-only
        // cursors do not reveal anything about a Vault the caller cannot read.
        let after = match raw_cursor {
            Some(cursor) => parse_cursor_with_key(&cursor_key, &generation, &vault_id, &cursor)?,
            None => 0,
        };

        let counters = sqlx::query(
            "SELECT last_committed_seq,minimum_available_seq FROM vault_counters WHERE vault_id=$1",
        )
        .bind(&vault_id)
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let high: i64 = counters.get("last_committed_seq");
        let minimum_available: i64 = counters.get("minimum_available_seq");
        if after > high {
            return Err(ApiError::gone(
                "CURSOR_EXPIRED",
                "cursor points beyond the current history",
            ));
        }
        if cursor_is_expired(after, minimum_available) {
            return Err(ApiError::gone(
                "CURSOR_EXPIRED",
                "change history before this cursor has expired; create a fresh snapshot",
            )
            .with_details(json!({
                "recovery":"create_snapshot",
                "preserve_local_outbox":true
            })));
        }

        // Deterministically exercise a single snapshot against concurrent
        // retention in ignored PostgreSQL acceptance tests only.
        #[cfg(test)]
        if let Some(pause) = test_pause.as_ref() {
            pause.pause().await;
        }

        let redaction_columns = redaction_columns("rr");
        let rows_sql = format!(
            "SELECT ce.commit_seq,ce.event_type,ce.record_id,ce.revision_id,ce.envelope,{redaction_columns} \
             FROM change_events ce LEFT JOIN record_redactions rr \
               ON rr.vault_id=ce.vault_id AND rr.record_id=ce.record_id \
             WHERE ce.vault_id=$1 AND ce.commit_seq>$2 AND ce.commit_seq<=$3 \
             ORDER BY ce.commit_seq LIMIT $4"
        );
        let mut rows = sqlx::query(&rows_sql)
            .bind(&vault_id)
            .bind(after)
            .bind(high)
            .bind(limit + 1)
            .fetch(&mut *tx);
        let mut events = Vec::new();
        let mut budget = SyncPageBudget::default();
        let mut has_more = false;
        let mut last_seq = after;
        while let Some(row) = rows.try_next().await.map_err(ApiError::internal)? {
            if events.len() >= limit as usize {
                has_more = true;
                break;
            }
            let statement = redaction_from_join_row(&row)?;
            let event = if let Some(statement) = statement.as_ref() {
                let signer = self
                    .proof_signer
                    .as_ref()
                    .ok_or_else(|| ApiError::internal("redaction proof signer is unavailable"))?;
                json!({
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "event_type": "record_redacted",
                    "record_id": row.get::<String, _>("record_id"),
                    "redaction": signer.proof(statement)?,
                })
            } else {
                let encoded: Option<String> = row.get("envelope");
                let encoded = encoded.ok_or_else(|| {
                    ApiError::internal("unredacted change event is missing its envelope")
                })?;
                let event = json!({
                    "commit_seq": row.get::<i64, _>("commit_seq").to_string(),
                    "event_type": row.get::<String, _>("event_type"),
                    "record_id": row.get::<String, _>("record_id"),
                    "revision_id": row.get::<String, _>("revision_id"),
                    "envelope": serde_json::from_str::<Value>(&encoded)
                        .map_err(ApiError::internal)?,
                });
                ensure_envelope_readable(user.declares_record_schema2, &event["envelope"])?;
                event
            };
            if !budget.try_add(&event)? {
                if events.is_empty() {
                    return Err(sync_page_item_too_large());
                }
                has_more = true;
                break;
            }
            last_seq = row.get("commit_seq");
            events.push(event);
        }
        drop(rows);
        let response = json!({
            "events": events,
            "next_cursor": encode_cursor_with_key(&cursor_key, &generation, &vault_id, last_seq)?,
            "has_more": has_more,
            "server_generation": generation,
        });
        ensure_sync_page_response_fits(&response)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(response)
    }
}

impl SyncChangesReadRepository for PgSyncChangesReadRepository {
    fn read_changes_page(
        &self,
        command: ChangesPageCommand,
    ) -> RepositoryFuture<'_, Result<Value, ApiError>> {
        Box::pin(self.read_page(command))
    }
}

async fn require_active_session_device_read(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    user: &AuthUser,
) -> Result<(), ApiError> {
    let row = sqlx::query(
        "SELECT s.revoked_at IS NOT NULL AS revoked,s.access_expires_at>CURRENT_TIMESTAMP AS unexpired,u.status AS account_status,d.status AS device_status FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4",
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
    const READ_MIGRATION: &str =
        include_str!("../migrations/postgres/0002_sync_changes_retention.sql");
    const INSTANCE_MIGRATION: &str = include_str!("../migrations/postgres/0003_instance_meta.sql");
    const CONFLICT_MIGRATION: &str =
        include_str!("../migrations/postgres/0005_sync_conflict_feed.sql");
    const CONFLICT_WRITE_MIGRATION: &str =
        include_str!("../migrations/postgres/0006_sync_conflict_write.sql");
    const SNAPSHOT_MIGRATION: &str = include_str!("../migrations/postgres/0007_sync_snapshots.sql");
    const REDACTION_MIGRATION: &str =
        include_str!("../migrations/postgres/0030_record_redactions.sql");
    const REDACTED_CONFLICT_MIGRATION: &str = concat!(
        include_str!("../migrations/postgres/0031_redacted_conflict_resolution.sql"),
        include_str!("../migrations/postgres/0032_record_restore_deadlines.sql"),
        include_str!("../migrations/postgres/0033_record_auto_purge_opt_in.sql"),
        include_str!("../migrations/postgres/0034_record_auto_purge_scan.sql")
    );
    const USER_ID: &str = "pg-read-user";
    const DEVICE_ID: &str = "pg-read-device";
    const SESSION_ID: &str = "pg-read-session";
    const VAULT_ID: &str = "e950523f-c2bd-42fb-a66c-d9c87d86d331";
    const ACCESS_HASH: &str = "pg-read-access-hash";
    const CURSOR_KEY: [u8; 32] = [0x5a; 32];
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
                .expect("ignored PostgreSQL changes tests require ATERMIUS_TEST_PG_URL");
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
            let schema = format!("atermius_pg_read_{}", Uuid::new_v4().simple());
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
                sqlx::raw_sql(READ_MIGRATION)
                    .execute(&pool)
                    .await
                    .expect("apply PostgreSQL changes-read schema");
                sqlx::raw_sql(
                    "CREATE TABLE atermius_instance_schema (\
                        singleton SMALLINT PRIMARY KEY CHECK(singleton=1),\
                        schema_version INTEGER NOT NULL CHECK(schema_version>=1)\
                     ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,29)",
                )
                .execute(&pool)
                .await
                .expect("create PostgreSQL schema-version fixture");
                for migration in [
                    INSTANCE_MIGRATION,
                    CONFLICT_MIGRATION,
                    CONFLICT_WRITE_MIGRATION,
                    SNAPSHOT_MIGRATION,
                    REDACTION_MIGRATION,
                    REDACTED_CONFLICT_MIGRATION,
                ] {
                    sqlx::raw_sql(migration)
                        .execute(&pool)
                        .await
                        .expect("apply PostgreSQL redaction-read schema");
                }
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
            "INSERT INTO users(user_id,username,status) VALUES($1,'pg-read-user','active')",
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
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,'pg-read-refresh-hash',CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
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
            "INSERT INTO vault_counters(vault_id,last_committed_seq,minimum_available_seq) VALUES($1,2,1)",
        )
        .bind(VAULT_ID)
        .execute(pool)
        .await
        .unwrap();
        insert_event(pool, 1, "old-record", "old-revision", r#"{"opaque":1}"#).await;
        insert_event(pool, 2, "new-record", "new-revision", r#"{"opaque":2}"#).await;
    }

    async fn insert_event(pool: &PgPool, seq: i64, record: &str, revision: &str, envelope: &str) {
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES($1,$2,'create',$3,$4,$5,CURRENT_TIMESTAMP)")
            .bind(VAULT_ID)
            .bind(seq)
            .bind(record)
            .bind(revision)
            .bind(envelope)
            .execute(pool)
            .await
            .unwrap();
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
        let key = Arc::new(SigningKey::from_bytes(&[0x5a; 32]));
        let instance = crate::InstanceInfo {
            instance_id: "3a25ea6e-53f5-47b6-9d82-97c43acb8a0b".to_owned(),
            server_space_id: "60fa13ac-45b6-449a-a980-b83d77a0f5b0".to_owned(),
            generation: GENERATION.to_owned(),
            signing_public_key: URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()),
            signing_key_transitions: Vec::new(),
        };
        PgRedactionProofSigner::new(instance, key)
    }

    fn command(user: AuthUser, raw_cursor: Option<String>, limit: i64) -> ChangesPageCommand {
        ChangesPageCommand {
            user,
            vault_id: VAULT_ID.to_owned(),
            raw_cursor,
            limit,
            cursor_key: CURSOR_KEY,
            generation: GENERATION.to_owned(),
            test_pause: None,
        }
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL redaction acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_changes_projects_every_redacted_record_event_without_payload_for_capable_clients() {
        let database = TestDatabase::create().await;
        let repository =
            PgSyncChangesReadRepository::with_signer(database.pool.clone(), proof_signer());
        let record_id = Uuid::new_v4().to_string();
        let deleted_revision_id = Uuid::new_v4().to_string();
        let redaction_id = Uuid::new_v4().to_string();
        sqlx::query("UPDATE change_events SET record_id=$1,revision_id=$2 WHERE vault_id=$3 AND commit_seq=1")
            .bind(&record_id)
            .bind(&deleted_revision_id)
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE change_events SET record_id=$1,revision_id=$2 WHERE vault_id=$3 AND commit_seq=2")
            .bind(&record_id)
            .bind(Uuid::new_v4().to_string())
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,1)")
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,1,3)")
            .bind(&redaction_id)
            .bind(VAULT_ID)
            .bind(&record_id)
            .bind(&deleted_revision_id)
            .execute(&database.pool)
            .await
            .unwrap();

        let page = repository
            .read_changes_page(command(actor(), None, 10))
            .await
            .unwrap();
        let events = page["events"].as_array().unwrap();
        assert_eq!(events.len(), 2);
        for event in events {
            assert_eq!(event["event_type"], "record_redacted");
            assert_eq!(event["record_id"], record_id);
            assert_eq!(event.as_object().unwrap().len(), 4);
            assert!(event.get("revision_id").is_none());
            assert!(event.get("envelope").is_none());
            assert_eq!(event["redaction"]["redaction_id"], redaction_id);
        }

        let mut legacy = actor();
        legacy.declares_sync_redaction_v1 = false;
        let error = repository
            .read_changes_page(command(legacy, None, 10))
            .await
            .unwrap_err();
        assert_eq!(error.status, axum::http::StatusCode::UPGRADE_REQUIRED);
        assert_eq!(error.body.code, "CLIENT_REDACTION_CAPABILITY_REQUIRED");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL changes-read acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_changes_pages_replay_and_advance_only_the_returned_prefix() {
        let database = TestDatabase::create().await;
        let repository = PgSyncChangesReadRepository::new(database.pool.clone());

        let first = repository
            .read_changes_page(command(actor(), None, 1))
            .await
            .unwrap();
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["events"][0]["commit_seq"], "1");
        assert_eq!(first["has_more"], true);
        assert_eq!(first["server_generation"], GENERATION);
        let cursor = first["next_cursor"].as_str().unwrap().to_owned();
        assert_eq!(
            crate::sync::parse_cursor_with_key(&CURSOR_KEY, GENERATION, VAULT_ID, &cursor).unwrap(),
            1
        );

        let replay = repository
            .read_changes_page(command(actor(), None, 1))
            .await
            .unwrap();
        assert_eq!(replay, first);

        let second = repository
            .read_changes_page(command(actor(), Some(cursor), 1))
            .await
            .unwrap();
        assert_eq!(second["events"].as_array().unwrap().len(), 1);
        assert_eq!(second["events"][0]["commit_seq"], "2");
        assert_eq!(second["has_more"], false);

        let empty = repository
            .read_changes_page(command(
                actor(),
                Some(second["next_cursor"].as_str().unwrap().to_owned()),
                1,
            ))
            .await
            .unwrap();
        assert_eq!(empty["events"].as_array().unwrap().len(), 0);
        assert_eq!(empty["has_more"], false);
        assert_eq!(
            crate::sync::parse_cursor_with_key(
                &CURSOR_KEY,
                GENERATION,
                VAULT_ID,
                empty["next_cursor"].as_str().unwrap()
            )
            .unwrap(),
            2
        );

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL changes-read snapshot acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_changes_snapshot_survives_concurrent_commit_and_retention() {
        let database = TestDatabase::create().await;
        let repository = PgSyncChangesReadRepository::new(database.pool.clone());
        let pause = Arc::new(crate::recovery::TestPause::new());
        let _release_pause = crate::recovery::ReleasePauseOnDrop::new(pause.clone());
        let read_repository = PgSyncChangesReadRepository::new(database.pool.clone());
        let mut page_command = command(actor(), None, 1);
        page_command.test_pause = Some(pause.clone());
        let read =
            tokio::spawn(async move { read_repository.read_changes_page(page_command).await });

        tokio::time::timeout(Duration::from_secs(5), pause.wait_until_reached())
            .await
            .expect("reader reaches pause after snapshot bounds");

        // Model the production ordering for append plus retention: add seq 3,
        // then move the floor to seq 2 and prune seq 1 atomically. The paused
        // repeatable-read transaction must still see old floor/high=1/2 and
        // event prefix 1/2, while a later page sees floor/high=2/3.
        let mut writer = database.pool.begin().await.unwrap();
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3,minimum_available_seq=2 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES($1,3,'create','latest-record','latest-revision','{\"opaque\":3}',CURRENT_TIMESTAMP)")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        sqlx::query("DELETE FROM change_events WHERE vault_id=$1 AND commit_seq<2")
            .bind(VAULT_ID)
            .execute(&mut *writer)
            .await
            .unwrap();
        writer.commit().await.unwrap();

        pause.release();
        let first = tokio::time::timeout(Duration::from_secs(5), read)
            .await
            .expect("snapshot read completes")
            .unwrap()
            .unwrap();
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["events"][0]["commit_seq"], "1");
        assert_eq!(first["has_more"], true);
        let first_cursor = first["next_cursor"].as_str().unwrap().to_owned();

        let later = repository
            .read_changes_page(command(actor(), Some(first_cursor), 10))
            .await
            .unwrap();
        let seqs: Vec<&str> = later["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|event| event["commit_seq"].as_str().unwrap())
            .collect();
        assert_eq!(seqs, ["2", "3"]);
        assert_eq!(later["has_more"], false);

        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL changes-read bounds acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_changes_rejects_expired_and_foreign_generation_cursors_and_oversized_items() {
        let database = TestDatabase::create().await;
        let repository = PgSyncChangesReadRepository::new(database.pool.clone());
        sqlx::query("UPDATE vault_counters SET minimum_available_seq=2 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let old =
            crate::sync::encode_cursor_with_key(&CURSOR_KEY, GENERATION, VAULT_ID, 0).unwrap();
        let expired = repository
            .read_changes_page(command(actor(), Some(old), 1))
            .await
            .unwrap_err();
        assert_eq!(expired.status, axum::http::StatusCode::GONE);
        assert_eq!(expired.body.code, "CURSOR_EXPIRED");
        assert_eq!(expired.body.details.unwrap()["recovery"], "create_snapshot");

        let foreign = crate::sync::encode_cursor_with_key(
            &CURSOR_KEY,
            "8bcf11d5-99ed-49f3-8012-6f1d706edc91",
            VAULT_ID,
            1,
        )
        .unwrap();
        let foreign_error = repository
            .read_changes_page(command(actor(), Some(foreign), 1))
            .await
            .unwrap_err();
        assert_eq!(foreign_error.status, axum::http::StatusCode::GONE);
        assert_eq!(foreign_error.body.code, "CURSOR_EXPIRED");

        sqlx::query("DELETE FROM change_events WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let too_large = format!("{{\"opaque\":\"{}\"}}", "x".repeat(4 * 1024 * 1024));
        insert_event(
            &database.pool,
            3,
            "large-record",
            "large-revision",
            &too_large,
        )
        .await;
        sqlx::query("UPDATE vault_counters SET last_committed_seq=3,minimum_available_seq=1 WHERE vault_id=$1")
            .bind(VAULT_ID)
            .execute(&database.pool)
            .await
            .unwrap();
        let oversized = repository
            .read_changes_page(command(actor(), None, 1))
            .await
            .unwrap_err();
        assert_eq!(oversized.status, axum::http::StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(oversized.body.code, "PAYLOAD_TOO_LARGE");

        database.cleanup().await;
    }
}

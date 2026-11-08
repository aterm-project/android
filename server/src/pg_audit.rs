//! PostgreSQL-backed audit event paging for the restricted sync runtime.
//!
//! The first page takes a short table-level SHARE lock before computing its
//! high watermark. It waits for prior audit-writing transactions to finish and
//! blocks new audit writes only until that watermark is captured. Audited write
//! paths append their audit event as the final database write, avoiding a
//! lock-queue cycle between this table lock and domain-row locks.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use sqlx::{PgPool, Row};

use crate::{ApiError, auth::AuthUser};

pub(crate) struct PgAuditPage {
    pub(crate) high_watermark: i64,
    pub(crate) events: Vec<PgAuditEvent>,
}

pub(crate) struct PgAuditEvent {
    pub(crate) event_id: i64,
    scope_type: String,
    scope_id: String,
    actor_user_id: Option<String>,
    actor_device_id: Option<String>,
    action: String,
    resource_type: String,
    resource_id: Option<String>,
    result: String,
    occurred_at: i64,
    source: String,
}

impl PgAuditEvent {
    pub(crate) fn into_json(self) -> Result<Value, ApiError> {
        let occurred_at = DateTime::<Utc>::from_timestamp(self.occurred_at, 0)
            .ok_or_else(|| ApiError::internal("audit timestamp is invalid"))?
            .to_rfc3339();
        Ok(json!({
            "event_id": self.event_id.to_string(),
            "scope": self.scope_type,
            "vault_id": if self.scope_type == "vault" { Value::String(self.scope_id) } else { Value::Null },
            "actor_user_id": self.actor_user_id,
            "actor_device_id": self.actor_device_id,
            "action": self.action,
            "resource_type": self.resource_type,
            "resource_id": self.resource_id,
            "result": self.result,
            "occurred_at": occurred_at,
            "source": self.source,
        }))
    }

    fn into_instance_admin_json(self, resource_key: &[u8; 32]) -> Result<Value, ApiError> {
        let occurred_at = DateTime::<Utc>::from_timestamp(self.occurred_at, 0)
            .ok_or_else(|| ApiError::internal("audit timestamp is invalid"))?
            .to_rfc3339();
        let resource_id = self
            .resource_id
            .as_deref()
            .map(|id| crate::audit::instance_resource_id(resource_key, &self.resource_type, id))
            .transpose()?;
        Ok(json!({
            "event_id": self.event_id.to_string(),
            "scope": "instance",
            "actor_user_id": self.actor_user_id,
            "actor_device_id": self.actor_device_id,
            "action": self.action,
            "resource_type": self.resource_type,
            "resource_id": resource_id,
            "result": self.result,
            "occurred_at": occurred_at,
            "source": self.source,
        }))
    }
}

/// Lists one bounded installation-scope audit page for a configured instance
/// administrator. Authentication and the allowlist check are revalidated
/// under shared session/account/device row locks in the same transaction as
/// the page query. On the first page, the audit SHARE lock is acquired only
/// after those rows, matching audited write paths' domain-before-audit lock
/// order while capturing a stable event high watermark.
pub(crate) async fn list_instance_admin_page(
    pool: &PgPool,
    user: &AuthUser,
    admin_usernames: &[String],
    raw_cursor: Option<&str>,
    limit: i64,
    cursor_key: &[u8; 32],
    requester_scope: &str,
    generation: &str,
) -> Result<Value, ApiError> {
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;

    let username: Option<String> = sqlx::query_scalar(
        "SELECT u.username FROM sessions s \
         JOIN users u ON u.user_id=s.user_id \
         JOIN devices d ON d.device_id=s.device_id AND d.user_id=s.user_id \
         WHERE s.session_id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.access_hash=$4 \
           AND s.revoked_at IS NULL AND s.access_expires_at>CURRENT_TIMESTAMP \
           AND u.status='active' AND d.status='active' \
         FOR SHARE OF s,u,d",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(username) = username else {
        return Err(ApiError::unauthorized());
    };
    if !admin_usernames
        .iter()
        .any(|configured| configured == &username)
    {
        return Err(ApiError::forbidden(
            "INSTANCE_ADMIN_REQUIRED",
            "this account is not configured for instance administration",
        ));
    }

    // Authorization is deliberately checked before parsing a cursor so a
    // non-admin cannot use cursor errors to probe another account's feed.
    let first_page = raw_cursor.is_none();
    let mut cursor = match raw_cursor {
        Some(value) => crate::audit::decode_cursor(cursor_key, value, requester_scope, generation)?,
        None => crate::audit::AuditCursor {
            version: 1,
            requester_scope: requester_scope.to_owned(),
            server_generation: generation.to_owned(),
            high_watermark: 0,
            after_event_id: 0,
        },
    };
    if first_page {
        // SHARE conflicts with audit writers' RowExclusive lock. The lock is
        // held only while the watermark and bounded page are read.
        sqlx::query("LOCK TABLE audit_events IN SHARE MODE")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        cursor.high_watermark = sqlx::query_scalar(
            "SELECT COALESCE(MAX(event_id),0) FROM audit_events WHERE scope_type='instance'",
        )
        .fetch_one(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    }

    let rows = sqlx::query(
        "SELECT event_id,actor_user_id,actor_device_id,action,resource_type,resource_id,\
                result,occurred_at,source \
         FROM audit_events \
         WHERE scope_type='instance' AND event_id>$1 AND event_id<=$2 \
         ORDER BY event_id ASC LIMIT $3",
    )
    .bind(cursor.after_event_id)
    .bind(cursor.high_watermark)
    .bind(limit)
    .fetch_all(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    tx.commit().await.map_err(ApiError::internal)?;

    let has_more = rows.len() as i64 > limit - 1;
    let events = rows
        .into_iter()
        .map(|row| {
            Ok::<(i64, Value), ApiError>((
                row.try_get("event_id").map_err(ApiError::internal)?,
                PgAuditEvent {
                    event_id: row.try_get("event_id").map_err(ApiError::internal)?,
                    scope_type: "instance".to_owned(),
                    scope_id: String::new(),
                    actor_user_id: row.try_get("actor_user_id").map_err(ApiError::internal)?,
                    actor_device_id: row.try_get("actor_device_id").map_err(ApiError::internal)?,
                    action: row.try_get("action").map_err(ApiError::internal)?,
                    resource_type: row.try_get("resource_type").map_err(ApiError::internal)?,
                    resource_id: row.try_get("resource_id").map_err(ApiError::internal)?,
                    result: row.try_get("result").map_err(ApiError::internal)?,
                    occurred_at: row.try_get("occurred_at").map_err(ApiError::internal)?,
                    source: row.try_get("source").map_err(ApiError::internal)?,
                }
                .into_instance_admin_json(cursor_key)?,
            ))
        })
        .collect::<Result<Vec<_>, ApiError>>()?;
    let page_rows = events
        .into_iter()
        .take((limit - 1).max(0) as usize)
        .collect::<Vec<_>>();
    let response_events = page_rows
        .iter()
        .map(|(_, event)| event.clone())
        .collect::<Vec<_>>();
    let next_cursor = if has_more {
        let after_event_id = page_rows
            .last()
            .map(|(event_id, _)| *event_id)
            .unwrap_or(cursor.after_event_id);
        Some(crate::audit::encode_cursor(
            cursor_key,
            &crate::audit::AuditCursor {
                after_event_id,
                ..cursor
            },
        )?)
    } else {
        None
    };
    Ok(json!({
        "events": response_events,
        "next_cursor": next_cursor,
        "has_more": has_more,
    }))
}

/// Reads one bounded personal audit page. `first_page` is true only when no
/// signed cursor was supplied; its short transaction takes the audit table
/// SHARE lock to calculate a stable watermark. The bounded scope query runs
/// after that lock is released, so a sparse caller cannot block all audit
/// writers while scanning unrelated event IDs.
pub(crate) async fn list_page(
    pool: &PgPool,
    first_page: bool,
    after_event_id: i64,
    cursor_high_watermark: i64,
    requester_scope: &str,
    user_id: &str,
    limit: i64,
) -> Result<PgAuditPage, ApiError> {
    let high_watermark = if first_page {
        let mut tx = pool.begin().await.map_err(ApiError::internal)?;
        // READ COMMITTED gives each statement a fresh snapshot. Set it before
        // the table lock so MAX sees commits that finished while LOCK waited.
        sqlx::query("SET TRANSACTION ISOLATION LEVEL READ COMMITTED")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        // This must be the first relation lock. SHARE conflicts with audit
        // writers' RowExclusive locks. Migration 0018 sets identity CACHE 1
        // and repairs its value above MAX. Writers that start after this lock
        // is released therefore receive IDs above the captured watermark.
        sqlx::query("LOCK TABLE audit_events IN SHARE MODE")
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        let high_watermark =
            sqlx::query_scalar::<_, i64>("SELECT COALESCE(MAX(event_id),0) FROM audit_events")
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        high_watermark
    } else {
        cursor_high_watermark
    };

    // The raw-scope branch preserves only historical PG logout events written
    // before logout began using the account HMAC. Requiring both the exact
    // action and actor prevents an unrelated raw account-scope row from being
    // surfaced to this caller.
    let rows = sqlx::query(
        "SELECT e.event_id,e.scope_type,e.scope_id,e.actor_user_id,e.actor_device_id,\
                e.action,e.resource_type,e.resource_id,e.result,e.occurred_at,e.source \
         FROM audit_events e \
         WHERE e.event_id>$1 AND e.event_id<=$2 AND (\
           (e.scope_type='account' AND e.scope_id=$3) OR \
           (e.scope_type='account' AND e.scope_id=$4 \
             AND e.action='auth.logout_succeeded' AND e.actor_user_id=$5) OR \
           (e.scope_type='vault' AND EXISTS(\
             SELECT 1 FROM vault_members vm JOIN vaults v ON v.vault_id=vm.vault_id \
             WHERE vm.vault_id=e.scope_id AND vm.user_id=$6 \
               AND vm.state='active' AND vm.role IN ('owner','editor') \
               AND v.state IN ('active','deleting')\
           ))\
         ) ORDER BY e.event_id ASC LIMIT $7",
    )
    .bind(after_event_id)
    .bind(high_watermark)
    .bind(requester_scope)
    .bind(user_id)
    .bind(user_id)
    .bind(user_id)
    .bind(limit)
    .fetch_all(pool)
    .await
    .map_err(ApiError::internal)?;

    let events = rows
        .into_iter()
        .map(|row| {
            Ok(PgAuditEvent {
                event_id: row.try_get("event_id").map_err(ApiError::internal)?,
                scope_type: row.try_get("scope_type").map_err(ApiError::internal)?,
                scope_id: row.try_get("scope_id").map_err(ApiError::internal)?,
                actor_user_id: row.try_get("actor_user_id").map_err(ApiError::internal)?,
                actor_device_id: row.try_get("actor_device_id").map_err(ApiError::internal)?,
                action: row.try_get("action").map_err(ApiError::internal)?,
                resource_type: row.try_get("resource_type").map_err(ApiError::internal)?,
                resource_id: row.try_get("resource_id").map_err(ApiError::internal)?,
                result: row.try_get("result").map_err(ApiError::internal)?,
                occurred_at: row.try_get("occurred_at").map_err(ApiError::internal)?,
                source: row.try_get("source").map_err(ApiError::internal)?,
            })
        })
        .collect::<Result<Vec<_>, ApiError>>()?;

    Ok(PgAuditPage {
        high_watermark,
        events,
    })
}

#[cfg(test)]
mod tests {
    use std::{
        panic::{AssertUnwindSafe, resume_unwind},
        str::FromStr,
        sync::Arc,
        time::Duration,
    };

    use axum::{
        body::{Body, to_bytes},
        http::{Request, StatusCode, header::AUTHORIZATION},
    };
    use futures_util::FutureExt;
    use sqlx::{
        Connection, PgConnection, PgPool, postgres::PgConnectOptions, postgres::PgPoolOptions,
    };
    use tower::ServiceExt;
    use uuid::Uuid;

    use super::*;

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const INSTANCE_META_MIGRATION: &str =
        include_str!("../migrations/postgres/0003_instance_meta.sql");
    const INSTANCE_AUDIT_MIGRATION: &str =
        include_str!("../migrations/postgres/0010_account_onboarding.sql");
    const AUDIT_MIGRATION: &str = include_str!("../migrations/postgres/0018_audit_event_order.sql");

    struct TestDatabase {
        pool_a: PgPool,
        pool_b: PgPool,
        admin_pool: PgPool,
        schema: String,
        cleaned: bool,
    }

    impl TestDatabase {
        async fn create() -> Self {
            let url = std::env::var("ATERMIUS_TEST_PG_URL")
                .expect("ignored PostgreSQL audit test requires ATERMIUS_TEST_PG_URL");
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
                .expect("connect PostgreSQL disposable database");
            let schema = format!("atermius_pg_audit_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL audit schema");
            let mut cleanup = SchemaCleanupGuard {
                admin_pool: admin_pool.clone(),
                schema: schema.clone(),
                armed: true,
            };

            let setup = AssertUnwindSafe(async {
                let schema_options = options.options([("search_path", format!("\"{schema}\""))]);
                let pool_a = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(schema_options.clone())
                    .await
                    .expect("connect first PostgreSQL audit node");
                let pool_b = PgPoolOptions::new()
                    .max_connections(8)
                    .connect_with(schema_options)
                    .await
                    .expect("connect second PostgreSQL audit node");
                sqlx::raw_sql(CORE_MIGRATION)
                    .execute(&pool_a)
                    .await
                    .expect("apply PostgreSQL audit core schema");
                (pool_a, pool_b)
            })
            .catch_unwind()
            .await;
            let (pool_a, pool_b) = match setup {
                Ok(pools) => pools,
                Err(payload) => {
                    drop(cleanup);
                    resume_unwind(payload)
                }
            };
            cleanup.disarm();
            Self {
                pool_a,
                pool_b,
                admin_pool,
                schema,
                cleaned: false,
            }
        }

        async fn cleanup(mut self) {
            self.pool_a.close().await;
            self.pool_b.close().await;
            sqlx::query(&format!(
                "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
                self.schema
            ))
            .execute(&self.admin_pool)
            .await
            .expect("drop isolated PostgreSQL audit schema");
            self.admin_pool.close().await;
            self.cleaned = true;
        }
    }

    impl Drop for TestDatabase {
        fn drop(&mut self) {
            if self.cleaned {
                return;
            }
            let pool_a = self.pool_a.clone();
            let pool_b = self.pool_b.clone();
            let admin_pool = self.admin_pool.clone();
            let schema = self.schema.clone();
            if let Ok(runtime) = tokio::runtime::Handle::try_current() {
                runtime.spawn(async move {
                    pool_a.close().await;
                    pool_b.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                });
            }
        }
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

    impl SchemaCleanupGuard {
        fn disarm(&mut self) {
            self.armed = false;
        }
    }

    #[derive(Clone)]
    struct TestAccount {
        user_id: String,
        device_id: String,
        access_token: String,
    }

    async fn seed_account(pool: &PgPool) -> TestAccount {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let access_token = format!("pg-audit-access-{}", Uuid::new_v4());
        let session_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO users(user_id,username) VALUES($1,$2)")
            .bind(&user_id)
            .bind(format!("{}@example.test", Uuid::new_v4()))
            .execute(pool)
            .await
            .expect("seed PostgreSQL audit user");
        sqlx::query("INSERT INTO devices(device_id,user_id) VALUES($1,$2)")
            .bind(&device_id)
            .bind(&user_id)
            .execute(pool)
            .await
            .expect("seed PostgreSQL audit device");
        sqlx::query(
            "INSERT INTO sessions(\
                session_id,user_id,device_id,family_id,access_hash,refresh_hash,\
                access_expires_at,refresh_expires_at\
             ) VALUES($1,$2,$3,$4,$5,$6,CURRENT_TIMESTAMP+INTERVAL '1 hour',\
                      CURRENT_TIMESTAMP+INTERVAL '1 day')",
        )
        .bind(session_id)
        .bind(&user_id)
        .bind(&device_id)
        .bind(Uuid::new_v4().to_string())
        .bind(crate::sha256_hex(access_token.as_bytes()))
        .bind(Uuid::new_v4().to_string())
        .execute(pool)
        .await
        .expect("seed PostgreSQL audit session");
        TestAccount {
            user_id,
            device_id,
            access_token,
        }
    }

    async fn insert_event(
        pool: &PgPool,
        scope_type: &str,
        scope_id: &str,
        actor_user_id: Option<&str>,
        action: &str,
    ) -> i64 {
        sqlx::query_scalar(
            "INSERT INTO audit_events(\
                scope_type,scope_id,actor_user_id,action,resource_type,result,occurred_at,source\
             ) VALUES($1,$2,$3,$4,'audit_test','success',\
                      floor(extract(epoch FROM clock_timestamp()))::BIGINT,'api')\
             RETURNING event_id",
        )
        .bind(scope_type)
        .bind(scope_id)
        .bind(actor_user_id)
        .bind(action)
        .fetch_one(pool)
        .await
        .expect("insert PostgreSQL audit fixture")
    }

    fn test_config(data_dir: std::path::PathBuf) -> crate::Config {
        crate::Config {
            data_dir,
            backup_archive_dir: None,
            backup_key_file: None,
            backup_replication_env: crate::BackupReplicationEnv::default(),
            mfa_encryption_key_file: None,
            backup_retention_count: None,
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

    async fn sqlite_app_state() -> crate::AppState {
        let data_dir = std::env::temp_dir().join(format!("atermius-pg-audit-{}", Uuid::new_v4()));
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        crate::open_state(&database, test_config(data_dir))
            .await
            .expect("open local SQLite state for HTTP router")
    }

    fn pg_node_state(mut state: crate::AppState, pool: PgPool) -> crate::AppState {
        state.pg_sync_only = true;
        state.pg_sync_auth = Some(crate::pg_sync_auth::PgSyncAuthRepository::new(pool.clone()));
        state.pg_sync_pool = Some(pool);
        state
    }

    async fn http_request(
        app: &axum::Router,
        method: axum::http::Method,
        uri: &str,
        token: Option<&str>,
    ) -> (StatusCode, Value) {
        let mut request = Request::builder().method(method).uri(uri);
        if let Some(token) = token {
            request = request.header(AUTHORIZATION, format!("Bearer {token}"));
        }
        let response = app
            .clone()
            .oneshot(
                request
                    .body(Body::empty())
                    .expect("build audit HTTP request"),
            )
            .await
            .expect("run audit HTTP request");
        let status = response.status();
        let body = to_bytes(response.into_body(), 1024 * 1024)
            .await
            .expect("read audit HTTP response");
        let json = serde_json::from_slice(&body).expect("decode audit HTTP response JSON");
        (status, json)
    }

    async fn wait_for_share_lock(pool: &PgPool, schema: &str) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let waiting: bool = sqlx::query_scalar(
                    "SELECT EXISTS(\
                       SELECT 1 FROM pg_locks l \
                       JOIN pg_class c ON c.oid=l.relation \
                       JOIN pg_namespace n ON n.oid=c.relnamespace \
                       JOIN pg_stat_activity a ON a.pid=l.pid \
                       WHERE n.nspname=$1 AND c.relname='audit_events' \
                         AND l.mode='ShareLock' AND NOT l.granted \
                         AND a.query LIKE 'LOCK TABLE audit_events IN SHARE MODE%'\
                     )",
                )
                .bind(schema)
                .fetch_one(pool)
                .await
                .expect("inspect PostgreSQL audit lock queue");
                if waiting {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("first-page request must wait behind an uncommitted audit writer");
    }

    async fn wait_for_domain_row_lock(pool: &PgPool) {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let waiting: bool = sqlx::query_scalar(
                    "SELECT EXISTS(\
                       SELECT 1 FROM pg_stat_activity \
                       WHERE wait_event_type='Lock' \
                         AND query LIKE 'UPDATE vaults SET membership_version=membership_version+1%'\
                     )",
                )
                .fetch_one(pool)
                .await
                .expect("inspect PostgreSQL audit writer lock queue");
                if waiting {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("domain update must wait before requesting audit access");
    }

    #[tokio::test]
    #[ignore = "real two-node PostgreSQL audit acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_audit_http_hwm_is_stable_and_scope_is_rechecked_across_nodes() {
        let database = TestDatabase::create().await;

        let owner = seed_account(&database.pool_a).await;
        let editor = seed_account(&database.pool_a).await;
        let owner_scope = crate::audit::account_scope_id(&[0x42; 32], &owner.user_id).unwrap();
        let lock_vault_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id) VALUES($1,$2)")
            .bind(&lock_vault_id)
            .bind(&owner.user_id)
            .execute(&database.pool_a)
            .await
            .expect("seed domain-row lock fixture");
        sqlx::query(
            "INSERT INTO audit_events(event_id,scope_type,scope_id,action,resource_type,result,occurred_at,source) \
             VALUES(300,'account',$1,'audit.seed','account','success',100,'api')",
        )
        .bind(&owner_scope)
        .execute(&database.pool_a)
        .await
        .expect("seed explicit imported audit event");
        let identity_sequence: String =
            sqlx::query_scalar("SELECT pg_get_serial_sequence('audit_events','event_id')")
                .fetch_one(&database.pool_a)
                .await
                .expect("resolve audit identity sequence");
        // Model an old node that has already reserved a CACHE 5 block. The
        // backend is closed before the offline repair, matching the runbook's
        // requirement to stop every node and flush backend-local sequence
        // caches before deploying migration 0018.
        let test_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ignored PostgreSQL audit test requires ATERMIUS_TEST_PG_URL");
        let old_backend_options = PgConnectOptions::from_str(&test_url)
            .expect("valid PostgreSQL test URL")
            .options([("search_path", format!("\"{}\"", database.schema))]);
        let mut old_backend = PgConnection::connect_with(&old_backend_options)
            .await
            .expect("open independent old PostgreSQL backend");
        sqlx::query(&format!("ALTER SEQUENCE {identity_sequence} CACHE 5"))
            .execute(&mut old_backend)
            .await
            .expect("set a non-default cache before applying the migration");
        let cached_id: i64 =
            sqlx::query_scalar("SELECT nextval(pg_get_serial_sequence('audit_events','event_id'))")
                .fetch_one(&mut old_backend)
                .await
                .expect("consume an ID from the old backend's cached sequence block");
        assert!(
            (1..300).contains(&cached_id),
            "the old backend must consume a cached ID below the imported MAX"
        );
        old_backend
            .close()
            .await
            .expect("close old backend and discard its unused cached IDs");
        sqlx::query("SELECT setval(pg_get_serial_sequence('audit_events','event_id'),10,TRUE)")
            .execute(&database.pool_a)
            .await
            .expect("place identity sequence behind imported row");
        sqlx::raw_sql(AUDIT_MIGRATION)
            .execute(&database.pool_a)
            .await
            .expect("repair audit sequence and enforce cache size one");

        let generated_id = insert_event(
            &database.pool_a,
            "account",
            &owner_scope,
            Some(&owner.user_id),
            "audit.after_sequence_repair",
        )
        .await;
        assert!(
            generated_id > 300,
            "identity must advance past imported MAX"
        );
        let cache_size: i64 = sqlx::query_scalar(
            "SELECT cache_size FROM pg_sequences \
             WHERE schemaname=current_schema() \
               AND sequencename=(SELECT c.relname FROM pg_class c \
                 JOIN pg_depend d ON d.objid=c.oid \
                 WHERE d.refobjid=to_regclass('audit_events') \
                   AND d.refobjsubid=(SELECT attnum FROM pg_attribute \
                     WHERE attrelid=to_regclass('audit_events') AND attname='event_id') \
                   AND d.deptype='i' LIMIT 1)",
        )
        .fetch_one(&database.pool_a)
        .await
        .expect("read audit identity cache size");
        assert_eq!(cache_size, 1);

        let mut state_a = sqlite_app_state().await;
        state_a.cursor_key = Arc::new([0x42; 32]);
        let state_a = pg_node_state(state_a, database.pool_a.clone());
        let state_b = pg_node_state(state_a.clone(), database.pool_b.clone());
        let app_a = crate::router(state_a.clone()).await;
        let app_b = crate::router(state_b.clone()).await;

        let (status, max_page) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/audit?limit=200",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(max_page["events"].as_array().unwrap().len() <= 200);
        let (status, error) = http_request(
            &app_b,
            axum::http::Method::GET,
            "/api/v1/audit?limit=201",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(error["error"]["code"], "INVALID_LIMIT");

        // Hold a domain row and audit insert on node A. The first page on node
        // B must wait for this transaction before capturing its HWM. A
        // competing domain writer queues behind node A; after it obtains the
        // row, its audit insert must wait until the reader releases SHARE.
        let mut writer = database.pool_a.begin().await.unwrap();
        sqlx::query("UPDATE vaults SET active_epoch=active_epoch+1 WHERE vault_id=$1")
            .bind(&lock_vault_id)
            .execute(&mut *writer)
            .await
            .expect("lock the domain row before recording its audit");
        let inflight_id: i64 = sqlx::query_scalar(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,action,resource_type,result,occurred_at,source) \
             VALUES('account',$1,$2,'audit.inflight','account','success',200,'api') \
             RETURNING event_id",
        )
        .bind(&owner_scope)
        .bind(&owner.user_id)
        .fetch_one(&mut *writer)
        .await
        .expect("insert held audit event");
        let audit_app_b = app_b.clone();
        let owner_token = owner.access_token.clone();
        let first_page_task = tokio::spawn(async move {
            http_request(
                &audit_app_b,
                axum::http::Method::GET,
                "/api/v1/audit?limit=2",
                Some(&owner_token),
            )
            .await
        });
        wait_for_share_lock(&database.admin_pool, &database.schema).await;
        let competing_pool = database.pool_b.clone();
        let competing_vault = lock_vault_id.clone();
        let competing_scope = owner_scope.clone();
        let competing_user = owner.user_id.clone();
        let domain_writer = tokio::spawn(async move {
            let mut tx = competing_pool.begin().await.unwrap();
            sqlx::query(
                "UPDATE vaults SET membership_version=membership_version+1 WHERE vault_id=$1",
            )
            .bind(&competing_vault)
            .execute(&mut *tx)
            .await
            .unwrap();
            let event_id: i64 = sqlx::query_scalar(
                "INSERT INTO audit_events(\
                    scope_type,scope_id,actor_user_id,action,resource_type,result,occurred_at,source\
                 ) VALUES('account',$1,$2,'audit.domain_writer_after_share','account','success',\
                          floor(extract(epoch FROM clock_timestamp()))::BIGINT,'api')\
                 RETURNING event_id",
            )
            .bind(&competing_scope)
            .bind(&competing_user)
            .fetch_one(&mut *tx)
            .await
            .unwrap();
            tx.commit().await.unwrap();
            event_id
        });
        wait_for_domain_row_lock(&database.admin_pool).await;
        writer.commit().await.expect("commit held audit writer");

        let (status, first_page) = tokio::time::timeout(Duration::from_secs(5), first_page_task)
            .await
            .expect("first-page read completes after writer commit")
            .expect("first-page request task completes");
        let domain_writer_id = tokio::time::timeout(Duration::from_secs(5), domain_writer)
            .await
            .expect("competing writer completes after first-page lock release")
            .expect("competing writer task completes");
        assert_eq!(status, StatusCode::OK);
        assert_eq!(first_page["events"].as_array().unwrap().len(), 2);
        assert_eq!(first_page["events"][0]["event_id"], "300");
        assert_eq!(
            first_page["events"][1]["event_id"],
            generated_id.to_string()
        );
        assert_eq!(first_page["has_more"], true);
        let cursor = first_page["next_cursor"].as_str().unwrap().to_owned();
        let (payload, signature) = cursor.split_once('.').unwrap();
        let replacement = if signature.starts_with('A') { 'B' } else { 'A' };
        let tampered_cursor = format!("{payload}.{replacement}{}", &signature[1..]);
        let (status, error) = http_request(
            &app_a,
            axum::http::Method::GET,
            &format!("/api/v1/audit?cursor={tampered_cursor}"),
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(error["error"]["code"], "INVALID_AUDIT_CURSOR");

        let after_hwm_id = insert_event(
            &database.pool_b,
            "account",
            &owner_scope,
            Some(&owner.user_id),
            "audit.after_first_page",
        )
        .await;
        assert!(after_hwm_id > inflight_id);
        let (status, second_page) = http_request(
            &app_a,
            axum::http::Method::GET,
            &format!("/api/v1/audit?limit=1&cursor={cursor}"),
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(second_page["events"].as_array().unwrap().len(), 1);
        assert_eq!(
            second_page["events"][0]["event_id"],
            inflight_id.to_string()
        );
        assert_eq!(second_page["has_more"], false);
        assert!(!second_page.to_string().contains("audit.after_first_page"));
        assert!(
            domain_writer_id > inflight_id,
            "the domain writer blocked behind the SHARE watermark lock must allocate above it"
        );
        assert!(
            !second_page
                .to_string()
                .contains("audit.domain_writer_after_share")
        );

        // Seed old SQLite-compatible raw logout scope plus deliberately
        // malformed raw-scope rows. The compatibility exception is exact.
        let raw_logout_id = insert_event(
            &database.pool_a,
            "account",
            &owner.user_id,
            Some(&owner.user_id),
            "auth.logout_succeeded",
        )
        .await;
        insert_event(
            &database.pool_a,
            "account",
            &owner.user_id,
            Some(&owner.user_id),
            "audit.raw_scope_spoof",
        )
        .await;
        insert_event(
            &database.pool_a,
            "account",
            &owner.user_id,
            Some(&editor.user_id),
            "auth.logout_succeeded",
        )
        .await;
        let editor_scope = crate::audit::account_scope_id(&[0x42; 32], &editor.user_id).unwrap();
        let vault_id = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id) VALUES($1,$2)")
            .bind(&vault_id)
            .bind(&owner.user_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active'),($1,$3,'editor','active')",
        )
        .bind(&vault_id)
        .bind(&owner.user_id)
        .bind(&editor.user_id)
        .execute(&database.pool_a)
        .await
        .unwrap();
        let editor_account_event = insert_event(
            &database.pool_a,
            "account",
            &editor_scope,
            Some(&editor.user_id),
            "audit.editor_page_start",
        )
        .await;
        let vault_event_id = insert_event(
            &database.pool_a,
            "vault",
            &vault_id,
            Some(&owner.user_id),
            "vault.audit_scope_sentinel",
        )
        .await;

        let (status, owner_page) = http_request(
            &app_b,
            axum::http::Method::GET,
            "/api/v1/audit?limit=100",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let events = owner_page["events"].as_array().unwrap();
        assert!(events.iter().any(|event| event["scope"] == "vault"));
        assert!(
            events
                .iter()
                .any(|event| event["event_id"] == raw_logout_id.to_string())
        );
        assert!(
            events
                .iter()
                .any(|event| event["event_id"] == vault_event_id.to_string())
        );
        assert!(events.iter().all(|event| event.get("scope_id").is_none()));
        let owner_body = owner_page.to_string();
        assert!(!owner_body.contains("audit.raw_scope_spoof"));
        assert!(!owner_body.contains(&editor_scope));
        assert!(owner_body.contains("auth.logout_succeeded"));

        // An editor initially sees the shared Vault event. The current role is
        // rechecked on each cursor page, so a downgrade or revocation removes
        // it from a cursor issued before the membership change.
        let (status, editor_first) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/audit?limit=1",
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            editor_first["events"][0]["event_id"],
            editor_account_event.to_string()
        );
        assert_eq!(editor_first["has_more"], true);
        let editor_cursor = editor_first["next_cursor"].as_str().unwrap().to_owned();
        let (status, editor_vault_page) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/audit?limit=100&cursor={editor_cursor}"),
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(
            editor_vault_page["events"]
                .as_array()
                .unwrap()
                .iter()
                .any(|event| event["event_id"] == vault_event_id.to_string())
        );
        sqlx::query("UPDATE vault_members SET role='viewer' WHERE vault_id=$1 AND user_id=$2")
            .bind(&vault_id)
            .bind(&editor.user_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
        let (status, after_downgrade) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/audit?limit=100&cursor={editor_cursor}"),
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(after_downgrade["events"].as_array().unwrap().is_empty());

        sqlx::query("UPDATE vault_members SET role='editor' WHERE vault_id=$1 AND user_id=$2")
            .bind(&vault_id)
            .bind(&editor.user_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
        let (status, editor_before_revoke) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/audit?limit=1",
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let revoke_cursor = editor_before_revoke["next_cursor"]
            .as_str()
            .unwrap()
            .to_owned();
        sqlx::query("UPDATE vault_members SET state='revoked' WHERE vault_id=$1 AND user_id=$2")
            .bind(&vault_id)
            .bind(&editor.user_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
        let (status, after_revoke) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/audit?limit=100&cursor={revoke_cursor}"),
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(after_revoke["events"].as_array().unwrap().is_empty());

        let (status, editor_page) = http_request(
            &app_b,
            axum::http::Method::GET,
            "/api/v1/audit?limit=100",
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(
            editor_page["events"]
                .as_array()
                .unwrap()
                .iter()
                .all(|event| { event["scope"] == "account" || event["vault_id"] != vault_id })
        );
        assert!(!editor_page.to_string().contains(&owner_scope));
        assert!(!editor_page.to_string().contains("audit.raw_scope_spoof"));

        let transferred_cursor = first_page["next_cursor"].as_str().unwrap();
        let (status, error) = http_request(
            &app_a,
            axum::http::Method::GET,
            &format!("/api/v1/audit?cursor={transferred_cursor}"),
            Some(&editor.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(error["error"]["code"], "INVALID_AUDIT_CURSOR");

        let mut stale_state = state_a.clone();
        let mut stale_instance = (*stale_state.instance).clone();
        stale_instance.generation = Uuid::new_v4().to_string();
        stale_state.instance = Arc::new(stale_instance);
        let stale_app = crate::router(stale_state).await;
        let (status, error) = http_request(
            &stale_app,
            axum::http::Method::GET,
            &format!("/api/v1/audit?cursor={transferred_cursor}"),
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::GONE);
        assert_eq!(error["error"]["code"], "AUDIT_CURSOR_EXPIRED");

        let (status, _) = http_request(
            &app_a,
            axum::http::Method::POST,
            "/api/v1/audit",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        let (status, _) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/audit/",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        let (status, _) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/audit?limit=0",
            Some(&owner.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let (status, error) =
            http_request(&app_a, axum::http::Method::GET, "/api/v1/audit", None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(error["error"]["code"], "AUTH_REQUIRED");

        drop(stale_app);
        drop(app_a);
        drop(app_b);
        let path = state_a.config.data_dir.clone();
        state_a.db.close().await;
        tokio::fs::remove_dir_all(path)
            .await
            .expect("remove local SQLite HTTP fixture");
        database.cleanup().await;
    }

    #[tokio::test]
    #[ignore = "real two-node PostgreSQL admin-audit acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn pg_instance_admin_audit_is_allowlisted_private_and_cursor_stable_across_nodes() {
        let database = TestDatabase::create().await;
        sqlx::raw_sql(INSTANCE_META_MIGRATION)
            .execute(&database.pool_a)
            .await
            .expect("apply shared PostgreSQL instance metadata migration");
        sqlx::raw_sql(INSTANCE_AUDIT_MIGRATION)
            .execute(&database.pool_a)
            .await
            .expect("apply instance-scoped audit contract migration");
        let admin = seed_account(&database.pool_a).await;
        let second_admin = seed_account(&database.pool_a).await;
        let outsider = seed_account(&database.pool_a).await;
        let admin_username: String =
            sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1")
                .bind(&admin.user_id)
                .fetch_one(&database.pool_a)
                .await
                .unwrap();
        let second_admin_username: String =
            sqlx::query_scalar("SELECT username FROM users WHERE user_id=$1")
                .bind(&second_admin.user_id)
                .fetch_one(&database.pool_a)
                .await
                .unwrap();
        let mut state_a = sqlite_app_state().await;
        state_a.cursor_key = Arc::new([0x52; 32]);
        Arc::make_mut(&mut state_a.config).admin_usernames =
            vec![admin_username, second_admin_username];
        let state_a = pg_node_state(state_a, database.pool_a.clone());
        let state_b = pg_node_state(state_a.clone(), database.pool_b.clone());
        let app_a = crate::router(state_a.clone()).await;
        let app_b = crate::router(state_b.clone()).await;

        let (status, missing) =
            http_request(&app_a, axum::http::Method::GET, "/api/v1/admin/audit", None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(missing["error"]["code"], "AUTH_REQUIRED");
        let (status, denied) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/admin/audit",
            Some(&outsider.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert_eq!(denied["error"]["code"], "INSTANCE_ADMIN_REQUIRED");
        let (status, invalid_limit) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/admin/audit?limit=201",
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(invalid_limit["error"]["code"], "INVALID_LIMIT");
        let (status, unsupported) = http_request(
            &app_a,
            axum::http::Method::POST,
            "/api/v1/admin/audit",
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(unsupported["error"]["code"], "PG_SYNC_SCOPE_LIMITED");
        let (status, neighbor) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/admin/accounts",
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(neighbor["error"]["code"], "PG_SYNC_SCOPE_LIMITED");

        let marker = Uuid::new_v4().to_string();
        let raw_instance_resource = format!("{marker}.raw_instance_resource");
        let first_instance_action = format!("{marker}.instance_a");
        sqlx::query(
            "INSERT INTO audit_events(scope_type,scope_id,actor_user_id,action,resource_type,resource_id,result,occurred_at,source) \
             VALUES('instance','opaque-instance-scope',$1,$2,'audit_test',$3,'success', \
                    floor(extract(epoch FROM clock_timestamp()))::BIGINT,'api')",
        )
        .bind(&admin.user_id)
        .bind(&first_instance_action)
        .bind(&raw_instance_resource)
        .execute(&database.pool_a)
        .await
        .expect("insert instance audit resource privacy fixture");
        insert_event(
            &database.pool_a,
            "account",
            "opaque-account-scope",
            Some(&admin.user_id),
            &format!("{marker}.account_sentinel"),
        )
        .await;
        insert_event(
            &database.pool_a,
            "vault",
            "opaque-vault-scope",
            Some(&admin.user_id),
            &format!("{marker}.vault_sentinel"),
        )
        .await;
        insert_event(
            &database.pool_a,
            "instance",
            "opaque-instance-scope",
            Some(&admin.user_id),
            &format!("{marker}.instance_b"),
        )
        .await;
        insert_event(
            &database.pool_a,
            "instance",
            "opaque-instance-scope",
            Some(&admin.user_id),
            &format!("{marker}.instance_c"),
        )
        .await;

        let (status, first) = http_request(
            &app_a,
            axum::http::Method::GET,
            "/api/v1/admin/audit?limit=1",
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(
            first
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect::<std::collections::BTreeSet<_>>(),
            ["events", "has_more", "next_cursor"]
                .into_iter()
                .map(str::to_owned)
                .collect()
        );
        assert_eq!(first["events"].as_array().unwrap().len(), 1);
        assert_eq!(first["has_more"], true);
        let cursor = first["next_cursor"].as_str().unwrap().to_owned();
        let event = &first["events"][0];
        assert_eq!(event["scope"], "instance");
        assert!(event.get("vault_id").is_none());
        assert_eq!(
            event["resource_id"],
            crate::audit::instance_resource_id(&[0x52; 32], "audit_test", &raw_instance_resource)
                .unwrap()
        );
        assert!(!event.to_string().contains(&raw_instance_resource));

        let (status, transferred_cursor) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/admin/audit?limit=1&cursor={cursor}"),
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(transferred_cursor["events"].as_array().unwrap().len(), 1);
        let next_cursor = transferred_cursor["next_cursor"]
            .as_str()
            .unwrap()
            .to_owned();

        let (status, tampered) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/admin/audit?limit=1&cursor={next_cursor}x"),
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(tampered["error"]["code"], "INVALID_AUDIT_CURSOR");
        let (status, wrong_admin_scope) = http_request(
            &app_b,
            axum::http::Method::GET,
            &format!("/api/v1/admin/audit?limit=1&cursor={cursor}"),
            Some(&second_admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert_eq!(wrong_admin_scope["error"]["code"], "INVALID_AUDIT_CURSOR");

        let mut stale_state = state_a.clone();
        let mut stale_instance = (*stale_state.instance).clone();
        stale_instance.generation = Uuid::new_v4().to_string();
        stale_state.instance = Arc::new(stale_instance);
        let stale_app = crate::router(stale_state).await;
        let (status, expired) = http_request(
            &stale_app,
            axum::http::Method::GET,
            &format!("/api/v1/admin/audit?limit=1&cursor={cursor}"),
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::GONE);
        assert_eq!(expired["error"]["code"], "AUDIT_CURSOR_EXPIRED");

        let mut events = first["events"].as_array().unwrap().clone();
        events.extend(
            transferred_cursor["events"]
                .as_array()
                .unwrap()
                .iter()
                .cloned(),
        );
        let late_action = format!("{marker}.late_instance");
        insert_event(
            &database.pool_a,
            "instance",
            "opaque-instance-scope",
            Some(&admin.user_id),
            &late_action,
        )
        .await;
        let mut current_cursor = next_cursor;
        loop {
            let (status, page) = http_request(
                &app_a,
                axum::http::Method::GET,
                &format!("/api/v1/admin/audit?limit=1&cursor={current_cursor}"),
                Some(&admin.access_token),
            )
            .await;
            assert_eq!(status, StatusCode::OK);
            events.extend(page["events"].as_array().unwrap().iter().cloned());
            if page["has_more"] == false {
                assert_eq!(page["next_cursor"], Value::Null);
                break;
            }
            current_cursor = page["next_cursor"].as_str().unwrap().to_owned();
        }
        let actions = events
            .iter()
            .map(|event| event["action"].as_str().unwrap())
            .collect::<Vec<_>>();
        let instance_a = format!("{marker}.instance_a");
        let instance_b = format!("{marker}.instance_b");
        let instance_c = format!("{marker}.instance_c");
        assert!(actions.contains(&instance_a.as_str()));
        assert!(actions.contains(&instance_b.as_str()));
        assert!(actions.contains(&instance_c.as_str()));
        assert!(!actions.iter().any(|action| action.contains("sentinel")));
        assert!(!actions.contains(&late_action.as_str()));

        sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=$1")
            .bind(&admin.device_id)
            .execute(&database.pool_a)
            .await
            .unwrap();
        let (status, revoked) = http_request(
            &app_b,
            axum::http::Method::GET,
            "/api/v1/admin/audit",
            Some(&admin.access_token),
        )
        .await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        assert_eq!(revoked["error"]["code"], "AUTH_REQUIRED");

        drop(stale_app);
        drop(app_a);
        drop(app_b);
        let path = state_a.config.data_dir.clone();
        state_a.db.close().await;
        tokio::fs::remove_dir_all(path)
            .await
            .expect("remove local SQLite HTTP fixture");
        database.cleanup().await;
    }
}

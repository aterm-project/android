//! PostgreSQL endpoint storage and multi-node notification push delivery.
//!
//! Sync commits enqueue metadata-only hints in the commit transaction. This
//! adapter stores opaque tokens with the same envelope contract as SQLite
//! and leases due outbox rows across PostgreSQL serving nodes.

use std::sync::Arc;

use serde_json::{Value, json};
use sqlx::{PgPool, Postgres, Row, Transaction};
use tokio::time::{MissedTickBehavior, interval, timeout};
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::mobile_push::{
    PUSH_DEAD_LETTER_TIME, PUSH_LEASE_SECONDS, PUSH_MAX_ATTEMPTS, PUSH_RETRY_BASE_SECONDS,
    PUSH_RETRY_MAX_SECONDS, PUSH_SEND_TIMEOUT, PUSH_WORKER_POLL, PushPayload, PushProvider,
    PushProviderKind, PushSendResult, decrypt_push_token, derive_push_keys_from_key,
    encrypt_push_token, record_push_send_result, token_fingerprint,
};
use crate::{ApiError, auth};

#[derive(Clone)]
pub(crate) struct PgMobilePushRepository {
    pool: PgPool,
    auth_rate_key: Arc<[u8; 32]>,
}

#[derive(Debug)]
struct PushDelivery {
    endpoint_id: String,
    device_id: String,
    provider: PushProviderKind,
    token_hash: String,
    token_envelope: String,
    requested_seq: i64,
    attempt_count: i64,
    lease_id: String,
}

impl PgMobilePushRepository {
    pub(crate) fn new(pool: PgPool, auth_rate_key: Arc<[u8; 32]>) -> Self {
        Self {
            pool,
            auth_rate_key,
        }
    }

    pub(crate) async fn register_endpoint(
        &self,
        user: &auth::AuthUser,
        provider: PushProviderKind,
        token: Zeroizing<String>,
    ) -> Result<Value, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;

        // Serialize first registration and token rotation on the account lock,
        // then reuse the endpoint ID when building its authenticated envelope.
        let existing_endpoint: Option<String> = sqlx::query_scalar(
            "SELECT endpoint_id FROM notification_push_endpoints \
             WHERE device_id=$1 AND user_id=$2 AND provider=$3 FOR UPDATE",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(provider.as_str())
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        let endpoint_id = existing_endpoint.unwrap_or_else(|| Uuid::new_v4().to_string());

        let (_, fingerprint_key) = derive_push_keys_from_key(self.auth_rate_key.as_ref())?;
        let token_hash = token_fingerprint(&fingerprint_key, &token)?;
        let existing_token_owner: Option<(String, String)> = sqlx::query_as(
            "SELECT device_id,provider FROM notification_push_endpoints \
             WHERE token_hash=$1",
        )
        .bind(&token_hash)
        .fetch_optional(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if existing_token_owner
            .as_ref()
            .is_some_and(|(device_id, owner_provider)| {
                device_id != &user.device_id || owner_provider != provider.as_str()
            })
        {
            return Err(ApiError::conflict(
                "PUSH_ENDPOINT_IN_USE",
                "push endpoint is already registered",
            ));
        }

        let envelope = encrypt_push_token(
            self.auth_rate_key.as_ref(),
            &endpoint_id,
            &user.device_id,
            provider,
            &token_hash,
            &token,
        )?;
        let now: i64 =
            sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                .fetch_one(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
        sqlx::query(
            "INSERT INTO notification_push_endpoints( \
                 endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at \
             ) VALUES($1,$2,$3,$4,$5,$6,$7,$7) \
             ON CONFLICT(device_id,provider) DO UPDATE SET \
                 token_hash=excluded.token_hash,token_envelope=excluded.token_envelope, \
                 updated_at=excluded.updated_at",
        )
        .bind(&endpoint_id)
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(provider.as_str())
        .bind(&token_hash)
        .bind(envelope)
        .bind(now)
        .execute(&mut *tx)
        .await
        .map_err(|error| {
            if let sqlx::Error::Database(database) = &error
                && database.code().as_deref() == Some("23505")
            {
                return ApiError::conflict(
                    "PUSH_ENDPOINT_IN_USE",
                    "push endpoint is already registered",
                );
            }
            ApiError::internal(error)
        })?;
        // Match the SQLite contract: rotating an endpoint makes an existing
        // coalesced hint immediately due, but registration alone creates none.
        sqlx::query(
            "UPDATE notification_push_outbox SET \
                 requested_seq=requested_seq+1,attempt_count=0,next_attempt_at=$1, \
                 lease_id=NULL,lease_until=NULL,dead_lettered=FALSE,updated_at=$1 \
             WHERE endpoint_id=$2",
        )
        .bind(now)
        .bind(&endpoint_id)
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "registered",
            "device_id": user.device_id,
            "provider": provider.as_str(),
        }))
    }

    pub(crate) async fn delete_endpoint(
        &self,
        user: &auth::AuthUser,
        provider: PushProviderKind,
    ) -> Result<Value, ApiError> {
        let mut tx = self.pool.begin().await.map_err(ApiError::internal)?;
        lock_active_principal(&mut tx, user).await?;
        sqlx::query(
            "DELETE FROM notification_push_endpoints \
             WHERE device_id=$1 AND user_id=$2 AND provider=$3",
        )
        .bind(&user.device_id)
        .bind(&user.user_id)
        .bind(provider.as_str())
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        Ok(json!({
            "status": "removed",
            "device_id": user.device_id,
            "provider": provider.as_str(),
        }))
    }

    /// Starts one worker per serving node. A node claims only providers for
    /// which its own configured adapter can deliver, so mixed provider
    /// configuration does not churn another provider's durable queue.
    pub(crate) fn start_worker(self, provider: Option<Arc<dyn PushProvider>>) {
        let Some(provider) = provider else {
            return;
        };
        tokio::spawn(async move {
            let mut poll = interval(PUSH_WORKER_POLL);
            poll.set_missed_tick_behavior(MissedTickBehavior::Skip);
            loop {
                poll.tick().await;
                match self.run_one_due(provider.as_ref()).await {
                    Ok(_) => {}
                    Err(error) => tracing::warn!(
                        error_code = %error.body.code,
                        "PostgreSQL mobile push delivery iteration failed"
                    ),
                }
            }
        });
    }

    async fn run_one_due(&self, provider: &dyn PushProvider) -> Result<bool, ApiError> {
        let supported = [PushProviderKind::FcmV1, PushProviderKind::Apns]
            .into_iter()
            .filter(|kind| provider.supports(*kind))
            .map(|kind| kind.as_str().to_owned())
            .collect::<Vec<_>>();
        let Some(delivery) = claim_one_due(&self.pool, &supported).await? else {
            return Ok(false);
        };
        let token = match decrypt_push_token(
            self.auth_rate_key.as_ref(),
            &delivery.endpoint_id,
            &delivery.device_id,
            delivery.provider,
            &delivery.token_hash,
            &delivery.token_envelope,
        ) {
            Ok(token) => token,
            Err(()) => {
                park_unreadable_endpoint(&self.pool, &delivery).await?;
                return Ok(true);
            }
        };
        let result = timeout(
            PUSH_SEND_TIMEOUT,
            provider.send(delivery.provider, token, PushPayload::SyncAvailable),
        )
        .await
        .unwrap_or(PushSendResult::RetryableFailure);
        record_push_send_result(delivery.provider, result);
        finish_delivery(&self.pool, &delivery, result).await?;
        Ok(true)
    }
}

async fn lock_active_principal(
    tx: &mut Transaction<'_, Postgres>,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    crate::pg_auth_lifecycle::lock_account_lifecycle(tx, &user.user_id).await?;
    crate::pg_auth_lifecycle::lock_active_principal_tx(tx, user).await?;
    Ok(())
}

async fn claim_one_due(
    pool: &PgPool,
    supported_providers: &[String],
) -> Result<Option<PushDelivery>, ApiError> {
    if supported_providers.is_empty() {
        return Ok(None);
    }
    let lease_id = Uuid::new_v4().to_string();
    let mut tx = pool.begin().await.map_err(ApiError::internal)?;
    let claimed = sqlx::query(
        "WITH db_clock AS ( \
             SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now \
         ), candidate AS ( \
             SELECT o.endpoint_id FROM notification_push_outbox o \
             JOIN notification_push_endpoints e ON e.endpoint_id=o.endpoint_id \
             JOIN devices d ON d.device_id=e.device_id AND d.user_id=e.user_id \
             JOIN users u ON u.user_id=e.user_id \
             CROSS JOIN db_clock c \
             WHERE o.requested_seq>o.delivered_seq AND NOT o.dead_lettered \
               AND o.next_attempt_at<=c.now \
               AND (o.lease_id IS NULL OR o.lease_until<=c.now) \
               AND e.provider=ANY($1::TEXT[]) AND d.status='active' AND u.status='active' \
             ORDER BY o.next_attempt_at,o.updated_at,o.endpoint_id \
             FOR UPDATE OF o SKIP LOCKED LIMIT 1 \
         ) \
         UPDATE notification_push_outbox o SET \
             lease_id=$2,lease_until=c.now+$3,attempt_count=o.attempt_count+1,updated_at=c.now \
         FROM candidate,db_clock c WHERE o.endpoint_id=candidate.endpoint_id \
         RETURNING o.endpoint_id,o.requested_seq,o.attempt_count",
    )
    .bind(supported_providers)
    .bind(&lease_id)
    .bind(PUSH_LEASE_SECONDS)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(claimed) = claimed else {
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let endpoint_id: String = claimed.try_get("endpoint_id").map_err(ApiError::internal)?;
    let row = sqlx::query(
        "SELECT e.device_id,e.provider,e.token_hash,e.token_envelope \
         FROM notification_push_endpoints e \
         JOIN devices d ON d.device_id=e.device_id AND d.user_id=e.user_id \
         JOIN users u ON u.user_id=e.user_id \
         WHERE e.endpoint_id=$1 AND d.status='active' AND u.status='active'",
    )
    .bind(&endpoint_id)
    .fetch_optional(&mut *tx)
    .await
    .map_err(ApiError::internal)?;
    let Some(row) = row else {
        sqlx::query("DELETE FROM notification_push_outbox WHERE endpoint_id=$1")
            .bind(&endpoint_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        tx.commit().await.map_err(ApiError::internal)?;
        return Ok(None);
    };
    let provider = PushProviderKind::parse(
        &row.try_get::<String, _>("provider")
            .map_err(ApiError::internal)?,
    )?;
    let delivery = PushDelivery {
        endpoint_id,
        device_id: row.try_get("device_id").map_err(ApiError::internal)?,
        provider,
        token_hash: row.try_get("token_hash").map_err(ApiError::internal)?,
        token_envelope: row.try_get("token_envelope").map_err(ApiError::internal)?,
        requested_seq: claimed
            .try_get("requested_seq")
            .map_err(ApiError::internal)?,
        attempt_count: claimed
            .try_get("attempt_count")
            .map_err(ApiError::internal)?,
        lease_id,
    };
    // The claim and endpoint ciphertext are now durable; provider I/O starts
    // only after releasing PostgreSQL row locks.
    tx.commit().await.map_err(ApiError::internal)?;
    Ok(Some(delivery))
}

async fn park_unreadable_endpoint(pool: &PgPool, delivery: &PushDelivery) -> Result<(), ApiError> {
    sqlx::query(
        "WITH db_clock AS (SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now) \
         UPDATE notification_push_outbox o SET lease_id=NULL,lease_until=NULL, \
             next_attempt_at=$1,dead_lettered=TRUE,updated_at=c.now \
         FROM db_clock c WHERE o.endpoint_id=$2 AND o.lease_id=$3",
    )
    .bind(PUSH_DEAD_LETTER_TIME)
    .bind(&delivery.endpoint_id)
    .bind(&delivery.lease_id)
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn retry_delay(attempt_count: i64) -> i64 {
    let exponent = attempt_count.saturating_sub(1).clamp(0, 30) as u32;
    PUSH_RETRY_BASE_SECONDS
        .saturating_mul(1_i64.checked_shl(exponent).unwrap_or(i64::MAX))
        .min(PUSH_RETRY_MAX_SECONDS)
}

async fn finish_delivery(
    pool: &PgPool,
    delivery: &PushDelivery,
    result: PushSendResult,
) -> Result<(), ApiError> {
    match result {
        PushSendResult::Accepted => {
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result).await?;
            sqlx::query(
                "WITH db_clock AS (SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now) \
                 UPDATE notification_push_outbox o SET \
                     delivered_seq=GREATEST(o.delivered_seq,$1),lease_id=NULL,lease_until=NULL, \
                     attempt_count=0,next_attempt_at=c.now,dead_lettered=FALSE,updated_at=c.now \
                 FROM db_clock c WHERE o.endpoint_id=$2 AND o.lease_id=$3",
            )
            .bind(delivery.requested_seq)
            .bind(&delivery.endpoint_id)
            .bind(&delivery.lease_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query(
                "DELETE FROM notification_push_outbox \
                 WHERE endpoint_id=$1 AND delivered_seq>=requested_seq AND lease_id IS NULL",
            )
            .bind(&delivery.endpoint_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
        PushSendResult::InvalidToken => {
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result).await?;
            sqlx::query(
                "DELETE FROM notification_push_endpoints e \
                 WHERE endpoint_id=$1 AND token_hash=$2 \
                   AND EXISTS(SELECT 1 FROM notification_push_outbox o \
                              WHERE o.endpoint_id=e.endpoint_id AND o.lease_id=$3)",
            )
            .bind(&delivery.endpoint_id)
            .bind(&delivery.token_hash)
            .bind(&delivery.lease_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
        PushSendResult::RetryableFailure => {
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            record_delivery_result(&mut tx, delivery.provider, result).await?;
            let current = sqlx::query(
                "SELECT requested_seq,attempt_count FROM notification_push_outbox \
                 WHERE endpoint_id=$1 AND lease_id=$2 FOR UPDATE",
            )
            .bind(&delivery.endpoint_id)
            .bind(&delivery.lease_id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            let Some(current) = current else {
                tx.commit().await.map_err(ApiError::internal)?;
                return Ok(());
            };
            let requested_seq: i64 = current
                .try_get("requested_seq")
                .map_err(ApiError::internal)?;
            let attempt_count: i64 = current
                .try_get("attempt_count")
                .map_err(ApiError::internal)?;
            let newer_work_arrived =
                requested_seq > delivery.requested_seq || attempt_count < delivery.attempt_count;
            let exhausted = !newer_work_arrived && delivery.attempt_count >= PUSH_MAX_ATTEMPTS;
            let delay = if newer_work_arrived {
                0
            } else {
                retry_delay(delivery.attempt_count)
            };
            sqlx::query(
                "WITH db_clock AS (SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now) \
                 UPDATE notification_push_outbox o SET lease_id=NULL,lease_until=NULL, \
                     next_attempt_at=CASE WHEN $2 THEN $3 WHEN $1=0 THEN c.now ELSE c.now+$1 END, \
                     dead_lettered=$2,updated_at=c.now \
                 FROM db_clock c WHERE o.endpoint_id=$4 AND o.lease_id=$5",
            )
            .bind(delay)
            .bind(exhausted)
            .bind(PUSH_DEAD_LETTER_TIME)
            .bind(&delivery.endpoint_id)
            .bind(&delivery.lease_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
        }
    }
    Ok(())
}

async fn record_delivery_result(
    tx: &mut Transaction<'_, Postgres>,
    provider: PushProviderKind,
    result: PushSendResult,
) -> Result<(), ApiError> {
    sqlx::query(
        "WITH db_clock AS (SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now) \
         INSERT INTO notification_push_delivery_daily(provider,outcome,day_start,count) \
         SELECT $1,$2,(now/86400)*86400,1 FROM db_clock \
         ON CONFLICT(provider,outcome,day_start) DO UPDATE \
             SET count=notification_push_delivery_daily.count+1",
    )
    .bind(provider.as_str())
    .bind(result.outcome_key())
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    sqlx::query(
        "WITH db_clock AS (SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT AS now) \
         DELETE FROM notification_push_delivery_daily d USING db_clock c \
         WHERE d.day_start<(c.now/86400)*86400-30*86400",
    )
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        collections::VecDeque,
        future::Future,
        panic::{AssertUnwindSafe, resume_unwind},
        pin::Pin,
        str::FromStr,
        sync::{
            Arc, Mutex,
            atomic::{AtomicUsize, Ordering},
        },
    };

    use sqlx::{PgPool, Row, postgres::PgConnectOptions, postgres::PgPoolOptions};
    use tokio::sync::Notify;
    use uuid::Uuid;
    use zeroize::Zeroizing;

    use super::{PgMobilePushRepository, retry_delay};
    use crate::{
        auth::AuthUser,
        mobile_push::{PushPayload, PushProvider, PushProviderKind, PushSendResult},
        pg_device_lifecycle::PgDeviceLifecycleRepository,
    };

    const CORE_MIGRATION: &str = include_str!("../migrations/postgres/0001_sync_commit_core.sql");
    const INSTANCE_MIGRATION: &str = include_str!("../migrations/postgres/0003_instance_meta.sql");
    const AUTH_MIGRATION: &str = include_str!("../migrations/postgres/0009_auth_lifecycle.sql");
    const PUSH_MIGRATION: &str =
        include_str!("../migrations/postgres/0019_mobile_push_outbox_due.sql");
    const DELIVERY_DAILY_MIGRATION: &str =
        include_str!("../migrations/postgres/0039_mobile_push_delivery_daily.sql");
    const USER_ID: &str = "pg-mobile-push-user";
    const ACTOR_DEVICE_ID: &str = "pg-mobile-push-actor";
    const TARGET_DEVICE_ID: &str = "pg-mobile-push-target";
    const ACTOR_SESSION_ID: &str = "pg-mobile-push-actor-session";
    const TARGET_SESSION_ID: &str = "pg-mobile-push-target-session";
    const ACTOR_ACCESS_HASH: &str = "pg-mobile-push-actor-hash";
    const TARGET_ACCESS_HASH: &str = "pg-mobile-push-target-hash";
    const TOKEN: &str = "opaque-push-token-0123456789";

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
                .expect("ignored PostgreSQL mobile-push test requires ATERMIUS_TEST_PG_URL");
            let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
            let database = options
                .get_database()
                .expect("PostgreSQL test URL names a database")
                .to_ascii_lowercase();
            assert!(
                database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
                "refusing PostgreSQL tests outside an explicitly disposable database"
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
            let schema = format!("atermius_pg_mobile_push_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
                .execute(&admin_pool)
                .await
                .expect("create isolated PostgreSQL mobile-push schema");
            let pool_options = options.options([("search_path", format!("\"{schema}\""))]);
            let pool_a = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(pool_options.clone())
                .await
                .expect("connect first isolated PostgreSQL node");
            let pool_b = PgPoolOptions::new()
                .max_connections(8)
                .connect_with(pool_options)
                .await
                .expect("connect second isolated PostgreSQL node");
            sqlx::raw_sql(
                "CREATE TABLE atermius_instance_schema( \
                     singleton SMALLINT PRIMARY KEY CHECK(singleton=1), \
                     schema_version INTEGER NOT NULL CHECK(schema_version>=1) \
                 ); INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,38)",
            )
            .execute(&pool_a)
            .await
            .expect("seed the current instance schema marker for the focused push migration test");
            for migration in [
                CORE_MIGRATION,
                INSTANCE_MIGRATION,
                AUTH_MIGRATION,
                PUSH_MIGRATION,
                DELIVERY_DAILY_MIGRATION,
            ] {
                if let Err(error) = sqlx::raw_sql(migration).execute(&pool_a).await {
                    pool_a.close().await;
                    pool_b.close().await;
                    let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                        .execute(&admin_pool)
                        .await;
                    admin_pool.close().await;
                    panic!("apply isolated PostgreSQL mobile-push migration: {error}");
                }
            }
            seed(&pool_a).await;
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
            .expect("drop isolated PostgreSQL mobile-push schema");
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

    struct FakeProvider {
        calls: AtomicUsize,
        results: Mutex<VecDeque<PushSendResult>>,
        tokens: Mutex<Vec<String>>,
        payloads: Mutex<Vec<&'static str>>,
        entered: Notify,
        release: Notify,
        block_first: AtomicUsize,
    }

    impl FakeProvider {
        fn new(results: impl IntoIterator<Item = PushSendResult>) -> Self {
            Self {
                calls: AtomicUsize::new(0),
                results: Mutex::new(results.into_iter().collect()),
                tokens: Mutex::new(Vec::new()),
                payloads: Mutex::new(Vec::new()),
                entered: Notify::new(),
                release: Notify::new(),
                block_first: AtomicUsize::new(1),
            }
        }
    }

    impl PushProvider for FakeProvider {
        fn supports(&self, provider: PushProviderKind) -> bool {
            provider == PushProviderKind::FcmV1
        }

        fn send<'a>(
            &'a self,
            provider: PushProviderKind,
            token: Zeroizing<String>,
            payload: PushPayload,
        ) -> Pin<Box<dyn Future<Output = PushSendResult> + Send + 'a>> {
            Box::pin(async move {
                self.calls.fetch_add(1, Ordering::SeqCst);
                self.tokens.lock().unwrap().push(token.to_string());
                self.payloads.lock().unwrap().push(payload.wire_json());
                assert_eq!(provider, PushProviderKind::FcmV1);
                assert_eq!(payload.wire_json(), r#"{"type":"sync_available"}"#);
                if self.block_first.fetch_sub(1, Ordering::SeqCst) == 1 {
                    self.entered.notify_one();
                    self.release.notified().await;
                }
                self.results
                    .lock()
                    .unwrap()
                    .pop_front()
                    .unwrap_or(PushSendResult::RetryableFailure)
            })
        }
    }

    fn actor(device_id: &str, session_id: &str, access_hash: &str) -> AuthUser {
        AuthUser {
            user_id: USER_ID.to_owned(),
            device_id: device_id.to_owned(),
            session_id: session_id.to_owned(),
            access_hash: access_hash.to_owned(),
            declares_record_schema2: false,
            declares_sync_redaction_v1: true,
        }
    }

    async fn seed(pool: &PgPool) {
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,'push-user','active')")
            .bind(USER_ID)
            .execute(pool)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,status) \
             VALUES($1,$3,'actor','active'),($2,$3,'target','active')",
        )
        .bind(ACTOR_DEVICE_ID)
        .bind(TARGET_DEVICE_ID)
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash, \
                 access_expires_at,refresh_expires_at) \
             VALUES($1,$3,$4,$5,'push-actor-refresh',CURRENT_TIMESTAMP+INTERVAL '1 hour', \
                    CURRENT_TIMESTAMP+INTERVAL '1 day'), \
                   ($2,$3,$6,$7,'push-target-refresh',CURRENT_TIMESTAMP+INTERVAL '1 hour', \
                    CURRENT_TIMESTAMP+INTERVAL '1 day')",
        )
        .bind(ACTOR_SESSION_ID)
        .bind(TARGET_SESSION_ID)
        .bind(USER_ID)
        .bind(ACTOR_DEVICE_ID)
        .bind(ACTOR_ACCESS_HASH)
        .bind(TARGET_DEVICE_ID)
        .bind(TARGET_ACCESS_HASH)
        .execute(pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO auth_credentials( \
                 user_id,login_verifier_hash,verifier_salt,kdf_json,account_key_envelope \
             ) VALUES($1,'verifier','salt','{}','{}')",
        )
        .bind(USER_ID)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn enqueue(pool: &PgPool, endpoint_id: &str, requested_seq: i64, attempts: i64) {
        sqlx::query(
            "INSERT INTO notification_push_outbox( \
                 endpoint_id,requested_seq,delivered_seq,attempt_count,next_attempt_at, \
                 lease_id,lease_until,dead_lettered,updated_at \
             ) VALUES($1,$2,0,$3,0,NULL,NULL,FALSE, \
                      floor(extract(epoch FROM clock_timestamp()))::BIGINT)",
        )
        .bind(endpoint_id)
        .bind(requested_seq)
        .bind(attempts)
        .execute(pool)
        .await
        .unwrap();
    }

    async fn endpoint_id(pool: &PgPool, device_id: &str) -> String {
        sqlx::query_scalar("SELECT endpoint_id FROM notification_push_endpoints WHERE device_id=$1")
            .bind(device_id)
            .fetch_one(pool)
            .await
            .unwrap()
    }

    #[test]
    fn retry_delay_is_bounded() {
        assert_eq!(retry_delay(1), 5);
        assert_eq!(retry_delay(2), 10);
        assert_eq!(retry_delay(8), 640);
        assert_eq!(retry_delay(100), 900);
    }

    #[tokio::test]
    #[ignore = "real PostgreSQL mobile-push acceptance; requires ATERMIUS_TEST_PG_URL for a disposable database"]
    async fn postgres_mobile_push_registration_delivery_retry_dead_letter_and_revoke_are_shared() {
        use futures_util::FutureExt;

        let database = TestDatabase::create().await;
        let result = AssertUnwindSafe(async {
            let key = Arc::new([0x5a_u8; 32]);
            let repo_a = PgMobilePushRepository::new(database.pool_a.clone(), key.clone());
            let repo_b = PgMobilePushRepository::new(database.pool_b.clone(), key.clone());
            let target = actor(TARGET_DEVICE_ID, TARGET_SESSION_ID, TARGET_ACCESS_HASH);
            let actor = actor(ACTOR_DEVICE_ID, ACTOR_SESSION_ID, ACTOR_ACCESS_HASH);

            repo_a
                .register_endpoint(
                    &target,
                    PushProviderKind::FcmV1,
                    crate::mobile_push::normalize_push_token(
                        PushProviderKind::FcmV1,
                        TOKEN.to_owned(),
                    )
                    .unwrap(),
                )
                .await
                .unwrap();
            let endpoint = endpoint_id(&database.pool_b, TARGET_DEVICE_ID).await;
            let stored = sqlx::query(
                "SELECT token_hash,token_envelope FROM notification_push_endpoints \
                 WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            let token_hash: String = stored.try_get("token_hash").unwrap();
            let envelope: String = stored.try_get("token_envelope").unwrap();
            assert!(!envelope.contains(TOKEN));
            assert!(envelope.starts_with("npe1:"));
            assert_eq!(
                crate::mobile_push::decrypt_push_token(
                    key.as_ref(),
                    &endpoint,
                    TARGET_DEVICE_ID,
                    PushProviderKind::FcmV1,
                    &token_hash,
                    &envelope,
                )
                .unwrap()
                .as_str(),
                TOKEN
            );
            enqueue(&database.pool_a, &endpoint, 1, 0).await;

            let provider = Arc::new(FakeProvider::new([
                PushSendResult::Accepted,
                PushSendResult::RetryableFailure,
                PushSendResult::Accepted,
                PushSendResult::RetryableFailure,
                PushSendResult::InvalidToken,
            ]));
            let entered = provider.entered.notified();
            let first_repo = repo_a.clone();
            let first_provider = provider.clone();
            let first_worker =
                tokio::spawn(async move { first_repo.run_one_due(first_provider.as_ref()).await });
            entered.await;
            let lease_row =
                sqlx::query("SELECT lease_id FROM notification_push_outbox WHERE endpoint_id=$1")
                    .bind(&endpoint)
                    .fetch_one(&database.pool_b)
                    .await
                    .unwrap();
            let lease: Option<String> = lease_row.try_get("lease_id").unwrap();
            assert!(lease.is_some(), "claim must commit before provider I/O");
            assert!(
                !repo_b.run_one_due(provider.as_ref()).await.unwrap(),
                "a second node must skip the live lease"
            );
            provider.release.notify_one();
            assert!(first_worker.await.unwrap().unwrap());
            assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
            assert_eq!(provider.tokens.lock().unwrap().as_slice(), [TOKEN]);
            assert_eq!(
                provider.payloads.lock().unwrap().as_slice(),
                [r#"{"type":"sync_available"}"#]
            );
            let outbox_count: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_outbox WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(outbox_count, 0, "accepted hint is removed after delivery");

            enqueue(&database.pool_a, &endpoint, 2, 0).await;
            assert!(repo_b.run_one_due(provider.as_ref()).await.unwrap());
            let retry_state = sqlx::query(
                "SELECT attempt_count,lease_id,next_attempt_at \
                 FROM notification_push_outbox WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_a)
            .await
            .unwrap();
            assert_eq!(retry_state.get::<i64, _>("attempt_count"), 1);
            assert_eq!(retry_state.get::<Option<String>, _>("lease_id"), None);
            let next_attempt: i64 = retry_state.get("next_attempt_at");
            let db_now: i64 =
                sqlx::query_scalar("SELECT floor(extract(epoch FROM clock_timestamp()))::BIGINT")
                    .fetch_one(&database.pool_a)
                    .await
                    .unwrap();
            assert!(next_attempt >= db_now + 4, "retry delay uses database time");
            sqlx::query(
                "UPDATE notification_push_outbox SET next_attempt_at=0 WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .execute(&database.pool_a)
            .await
            .unwrap();
            assert!(repo_a.run_one_due(provider.as_ref()).await.unwrap());

            enqueue(&database.pool_a, &endpoint, 3, super::PUSH_MAX_ATTEMPTS - 1).await;
            assert!(repo_a.run_one_due(provider.as_ref()).await.unwrap());
            let dead_letter: (bool, Option<String>) = sqlx::query_as(
                "SELECT dead_lettered,lease_id FROM notification_push_outbox WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(dead_letter, (true, None));
            assert!(
                !repo_b.run_one_due(provider.as_ref()).await.unwrap(),
                "dead-lettered work must not be claimed again"
            );

            repo_b
                .register_endpoint(
                    &target,
                    PushProviderKind::FcmV1,
                    crate::mobile_push::normalize_push_token(
                        PushProviderKind::FcmV1,
                        TOKEN.to_owned(),
                    )
                    .unwrap(),
                )
                .await
                .unwrap();
            let re_registered_endpoint = endpoint_id(&database.pool_a, TARGET_DEVICE_ID).await;
            assert_eq!(re_registered_endpoint, endpoint);
            assert!(repo_a.run_one_due(provider.as_ref()).await.unwrap());
            let endpoint_count: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_endpoints WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(endpoint_count, 0, "invalid provider tokens are removed");
            let shared_delivery_results: Vec<(String, i64)> = sqlx::query_as(
                "SELECT outcome,count FROM notification_push_delivery_daily \
                 WHERE provider='fcm_v1' ORDER BY outcome",
            )
            .fetch_all(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(
                shared_delivery_results,
                vec![
                    ("accepted".to_owned(), 2),
                    ("invalid_token".to_owned(), 1),
                    ("retryable_failure".to_owned(), 2),
                ],
                "delivery results must be visible from the peer PostgreSQL node",
            );

            repo_a
                .register_endpoint(
                    &target,
                    PushProviderKind::FcmV1,
                    crate::mobile_push::normalize_push_token(
                        PushProviderKind::FcmV1,
                        TOKEN.to_owned(),
                    )
                    .unwrap(),
                )
                .await
                .unwrap();
            let endpoint = endpoint_id(&database.pool_a, TARGET_DEVICE_ID).await;
            enqueue(&database.pool_a, &endpoint, 1, 0).await;
            sqlx::raw_sql(
                "CREATE FUNCTION fail_push_revoke_audit() RETURNS trigger LANGUAGE plpgsql AS $$ \
                 BEGIN RAISE EXCEPTION 'forced audit rejection'; END $$; \
                 CREATE TRIGGER fail_push_revoke_audit BEFORE INSERT ON audit_events \
                 FOR EACH ROW WHEN (NEW.action='device.revoked') \
                 EXECUTE FUNCTION fail_push_revoke_audit();",
            )
            .execute(&database.pool_a)
            .await
            .unwrap();
            let lifecycle = PgDeviceLifecycleRepository::new(database.pool_a.clone(), [0x21; 32]);
            assert!(
                lifecycle
                    .revoke_device(&actor, TARGET_DEVICE_ID)
                    .await
                    .is_err()
            );
            let status: String =
                sqlx::query_scalar("SELECT status FROM devices WHERE device_id=$1")
                    .bind(TARGET_DEVICE_ID)
                    .fetch_one(&database.pool_b)
                    .await
                    .unwrap();
            let retained_endpoints: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_endpoints WHERE device_id=$1",
            )
            .bind(TARGET_DEVICE_ID)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            let retained_outbox: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_outbox WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(status, "active", "audit failure rolls back revocation");
            assert_eq!(retained_endpoints, 1, "failed revoke retains endpoint");
            assert_eq!(retained_outbox, 1, "failed revoke retains queued hint");
            sqlx::raw_sql(
                "DROP TRIGGER fail_push_revoke_audit ON audit_events; \
                 DROP FUNCTION fail_push_revoke_audit();",
            )
            .execute(&database.pool_a)
            .await
            .unwrap();
            lifecycle
                .revoke_device(&actor, TARGET_DEVICE_ID)
                .await
                .unwrap();
            let retained_endpoints: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_endpoints WHERE device_id=$1",
            )
            .bind(TARGET_DEVICE_ID)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            let retained_outbox: i64 = sqlx::query_scalar(
                "SELECT count(*) FROM notification_push_outbox WHERE endpoint_id=$1",
            )
            .bind(&endpoint)
            .fetch_one(&database.pool_b)
            .await
            .unwrap();
            assert_eq!(retained_endpoints, 0, "successful revoke deletes endpoint");
            assert_eq!(retained_outbox, 0, "endpoint deletion cascades the outbox");
        })
        .catch_unwind()
        .await;
        database.cleanup().await;
        if let Err(payload) = result {
            resume_unwind(payload);
        }
    }
}

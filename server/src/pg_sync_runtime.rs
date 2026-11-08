//! Explicitly selected PostgreSQL shared sync/lifecycle connection configuration.
//!
//! This mode is a restricted runtime slice. It wires sync, bootstrap and
//! registration, password login/refresh/logout, account and Vault projections,
//! device enrollment/capability/revocation, Vault creation/invitations/member
//! lifecycle/key rotation/ownership transfer/deletion, account deletion,
//! Recovery, session-preserving password change, and TOTP MFA. Bounded workers handle
//! invitation and Recovery challenge retention,
//! due account/Vault deletion, audit retention, sync-event and snapshot payload
//! retention, auth-rate bucket cleanup, and the external-object deletion queue.
//! A bounded PostgreSQL `maintenance` CLI pass is available while nodes remain
//! online. Ordinary encrypted-object init/chunk/complete/download and bounded
//! unreferenced-object GC use that shared queue and require shared filesystem or
//! S3 storage; the node-local SQLite object store is rejected at PG startup.
//! MFA login challenge cleanup is opportunistic during rate-limited challenge
//! creation and deletes at most 500 expired or consumed rows per request; it
//! has no periodic worker. Generic mobile sync hints use an encrypted endpoint
//! registry and a PostgreSQL-leased outbox worker; instance-admin audit has a
//! bounded read-only listing route. The shared PostgreSQL admin-job ledger
//! supports maintenance, manual and scheduled instance backup, and isolated restore; other admin APIs,
//! collaboration APIs, and general PG/HA parity remain outside this runtime
//! slice. Operators apply migrations `0001` through `0038` before starting a
//! node; startup validates the dedicated schema, including durable object pins,
//! and fails closed if it is incomplete. Serving nodes hold a database-scoped shared
//! advisory lock for their full lifetime; the offline MFA key rotator requires
//! the exclusive lock and an otherwise quiescent database. SQLite remains the
//! default runtime.

use std::{path::PathBuf, str::FromStr};

use sqlx::{
    PgConnection, PgPool, Postgres, pool::PoolConnection, postgres::PgConnectOptions,
    postgres::PgPoolOptions,
};

use crate::ApiError;

// Stable across processes and schemas in the same PostgreSQL database. The
// database OID occupies the low 32 bits, so all nodes targeting the same DB
// derive the same advisory key without consulting node-local files.
const PG_RUNTIME_LOCK_NAMESPACE: i64 = 0x4154_4552;
const PG_RUNTIME_LOCK_HEARTBEAT: std::time::Duration = std::time::Duration::from_secs(1);

pub(crate) struct PgRuntimeAdvisoryLock {
    connection: PoolConnection<Postgres>,
    key: i64,
}

impl PgRuntimeAdvisoryLock {
    /// Keeps the serving process fail closed if its lock-owning connection is
    /// lost or the session lock is unexpectedly released. The caller races
    /// this future against the HTTP server and exits on any error.
    pub(crate) async fn wait_until_lost(&mut self) -> Result<(), ApiError> {
        loop {
            tokio::time::sleep(PG_RUNTIME_LOCK_HEARTBEAT).await;
            let held: bool = sqlx::query_scalar(
                "SELECT EXISTS (SELECT 1 FROM pg_locks \
                 WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted \
                   AND mode='ShareLock' AND objsubid=1 \
                   AND classid=(($1 >> 32) & 4294967295)::oid \
                   AND objid=($1 & 4294967295)::oid)",
            )
            .bind(self.key)
            .fetch_one(&mut *self.connection)
            .await
            .map_err(|_| ApiError::internal("PostgreSQL runtime coordination lock was lost"))?;
            if !held {
                return Err(ApiError::internal(
                    "PostgreSQL runtime coordination lock was lost",
                ));
            }
        }
    }

    pub(crate) async fn release(mut self) -> Result<(), ApiError> {
        let released: bool = sqlx::query_scalar("SELECT pg_advisory_unlock_shared($1)")
            .bind(self.key)
            .fetch_one(&mut *self.connection)
            .await
            .map_err(|_| ApiError::internal("PostgreSQL runtime coordination lock was lost"))?;
        if !released {
            return Err(ApiError::internal(
                "PostgreSQL runtime coordination lock was lost",
            ));
        }
        Ok(())
    }
}

pub(crate) async fn acquire_server_lifetime_lock(
    pool: &PgPool,
) -> Result<PgRuntimeAdvisoryLock, ApiError> {
    let mut connection = pool.acquire().await.map_err(ApiError::internal)?;
    let key = runtime_advisory_lock_key(&mut connection).await?;
    sqlx::query("SELECT pg_advisory_lock_shared($1)")
        .bind(key)
        .execute(&mut *connection)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL runtime coordination lock is unavailable"))?;
    let held: bool = sqlx::query_scalar(
        "SELECT EXISTS (SELECT 1 FROM pg_locks \
         WHERE locktype='advisory' AND pid=pg_backend_pid() AND granted \
           AND mode='ShareLock' AND objsubid=1 \
           AND classid=(($1 >> 32) & 4294967295)::oid \
           AND objid=($1 & 4294967295)::oid)",
    )
    .bind(key)
    .fetch_one(&mut *connection)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL runtime coordination lock is unavailable"))?;
    if !held {
        return Err(ApiError::internal(
            "PostgreSQL runtime coordination lock is unavailable",
        ));
    }
    Ok(PgRuntimeAdvisoryLock { connection, key })
}

pub(crate) async fn acquire_offline_rotation_lock(
    connection: &mut PgConnection,
) -> Result<i64, ApiError> {
    let key = runtime_advisory_lock_key(connection).await?;
    let acquired: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock($1)")
        .bind(key)
        .fetch_one(&mut *connection)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL offline rotation lock is unavailable"))?;
    if !acquired {
        return Err(ApiError::conflict(
            "POSTGRES_RUNTIME_ACTIVE",
            "PostgreSQL service nodes are still active",
        ));
    }
    Ok(key)
}

pub(crate) async fn ensure_no_other_database_clients(
    connection: &mut PgConnection,
) -> Result<(), ApiError> {
    let sessions: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM pg_stat_activity \
         WHERE datid=(SELECT oid FROM pg_database WHERE datname=current_database()) \
           AND pid<>pg_backend_pid() AND backend_type='client backend'",
    )
    .fetch_one(&mut *connection)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL offline rotation could not verify quiescence"))?;
    if sessions != 0 {
        return Err(ApiError::conflict(
            "POSTGRES_RUNTIME_ACTIVE",
            "PostgreSQL database still has client connections",
        ));
    }
    Ok(())
}

async fn runtime_advisory_lock_key(connection: &mut PgConnection) -> Result<i64, ApiError> {
    sqlx::query_scalar(
        "SELECT (($1::BIGINT << 32) | d.oid::BIGINT) \
         FROM pg_database d WHERE d.datname=current_database()",
    )
    .bind(PG_RUNTIME_LOCK_NAMESPACE)
    .fetch_one(connection)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL runtime lock key is unavailable"))
}

#[derive(Clone)]
pub(crate) struct PgSyncRuntimeConfig {
    pub(crate) database_url: String,
    pub(crate) schema: String,
    pub(crate) instance_signing_key_file: PathBuf,
    pub(crate) auth_rate_limit_key_file: PathBuf,
}

impl PgSyncRuntimeConfig {
    /// PostgreSQL is selected only by an exact explicit environment value.
    /// The default continues to use the existing SQLite-only runtime.
    pub(crate) fn from_env() -> Result<Option<Self>, ApiError> {
        Self::from_values(
            std::env::var("ATERMIUS_SYNC_BACKEND").ok().as_deref(),
            std::env::var("ATERMIUS_SYNC_PG_URL").ok().as_deref(),
            std::env::var("ATERMIUS_SYNC_PG_SCHEMA").ok().as_deref(),
            std::env::var("ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE")
                .ok()
                .as_deref(),
            std::env::var("ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE")
                .ok()
                .as_deref(),
        )
    }

    fn from_values(
        backend: Option<&str>,
        database_url: Option<&str>,
        schema: Option<&str>,
        instance_signing_key_file: Option<&str>,
        auth_rate_limit_key_file: Option<&str>,
    ) -> Result<Option<Self>, ApiError> {
        match backend.unwrap_or("sqlite") {
            "sqlite" => Ok(None),
            "postgres" => {
                let database_url = required_value(database_url)?;
                if !database_url.starts_with("postgres://")
                    && !database_url.starts_with("postgresql://")
                {
                    return Err(config_error(
                        "ATERMIUS_SYNC_PG_URL must use the PostgreSQL URL scheme",
                    ));
                }
                let schema = required_value(schema)?;
                if !valid_identifier(schema) {
                    return Err(config_error(
                        "ATERMIUS_SYNC_PG_SCHEMA must be a simple PostgreSQL identifier",
                    ));
                }
                Ok(Some(Self {
                    database_url: database_url.to_owned(),
                    schema: schema.to_owned(),
                    instance_signing_key_file: PathBuf::from(required_value(
                        instance_signing_key_file,
                    )?),
                    auth_rate_limit_key_file: PathBuf::from(required_value(
                        auth_rate_limit_key_file,
                    )?),
                }))
            }
            _ => Err(config_error(
                "ATERMIUS_SYNC_BACKEND must be either sqlite or postgres",
            )),
        }
    }

    pub(crate) async fn connect(&self) -> Result<PgPool, ApiError> {
        self.connect_inner(None).await
    }

    pub(crate) async fn connect_with_restore_policy(
        &self,
        legacy_restore_retention_days: i64,
    ) -> Result<PgPool, ApiError> {
        self.connect_inner(Some(legacy_restore_retention_days))
            .await
    }

    async fn connect_inner(
        &self,
        legacy_restore_retention_days: Option<i64>,
    ) -> Result<PgPool, ApiError> {
        let options = PgConnectOptions::from_str(&self.database_url)
            .map_err(|_| config_error("PostgreSQL sync connection configuration is invalid"))?
            .options([("search_path", format!("\"{}\"", self.schema))]);
        let pool = PgPoolOptions::new()
            .max_connections(16)
            .connect_with(options)
            .await
            .map_err(|_| ApiError::internal("PostgreSQL sync backend is unavailable"))?;
        self.validate_schema(&pool).await?;
        if let Some(days) = legacy_restore_retention_days {
            backfill_postgres_restore_deadlines(&pool, days).await?;
        }
        Ok(pool)
    }

    async fn validate_schema(&self, pool: &PgPool) -> Result<(), ApiError> {
        let current_schema: Option<String> = sqlx::query_scalar("SELECT current_schema()")
            .fetch_one(pool)
            .await
            .map_err(|_| ApiError::internal("PostgreSQL sync schema is unavailable"))?;
        if current_schema.as_deref() != Some(self.schema.as_str()) {
            return Err(ApiError::internal(
                "PostgreSQL sync search_path does not select the configured schema",
            ));
        }

        // Presence checks cover every migration layer used by the composed
        // sync repository and restricted password-auth lifecycle.
        const REQUIRED_TABLES: &[&str] = &[
            "users",
            "devices",
            "sessions",
            "auth_credentials",
            "password_change_receipts",
            "refresh_history",
            "auth_mfa",
            "auth_mfa_recovery_codes",
            "auth_mfa_login_challenges",
            "account_invitations",
            "invitations",
            "vaults",
            "vault_members",
            "vault_key_envelopes",
            "membership_manifests",
            "device_capability_reports",
            "device_redaction_capability_reports",
            "vault_counters",
            "record_versions",
            "record_heads",
            "record_graveyard",
            "record_redactions",
            "record_redacted_revisions",
            "change_events",
            "op_receipts",
            "batch_receipts",
            "blob_objects",
            "backup_object_pins",
            "backup_object_pin_sets",
            "object_references",
            "uploads",
            "upload_chunks",
            "vault_deletion_requests",
            "object_delete_queue",
            "account_deletion_requests",
            "account_recovery",
            "account_recovery_generation",
            "account_recovery_key_envelopes",
            "account_recovery_challenges",
            "account_recovery_receipts",
            "vault_device_archives",
            "audit_events",
            "instance_admin_jobs",
            "instance_backup_schedule",
            "notification_tickets",
            "notification_push_endpoints",
            "notification_push_outbox",
            "instance_relay_policy",
            "user_relay_policies",
            "user_relay_policy_revisions",
            "relay_access_groups",
            "relay_access_group_members",
            "relay_access_group_membership_revisions",
            "relay_access_group_relay_policies",
            "relay_access_group_relay_policy_revisions",
            "relay_user_authorization_versions",
            "relay_tickets",
            "relay_connection_leases",
            "vault_presence",
            "vault_presence_heartbeat_limits",
            "auth_rate_limit_meta",
            "auth_rate_limits",
            "conflicts",
            "snapshots",
            "snapshot_items",
            "instance_meta",
            "atermius_instance_schema",
            "instance_metrics_credential",
            "instance_backup_replications",
            "record_auto_purge_scan_control",
            "record_auto_purge_vault_cursors",
        ];
        for table in REQUIRED_TABLES {
            let relation: Option<String> = sqlx::query_scalar("SELECT to_regclass($1)::text")
                .bind(table)
                .fetch_one(pool)
                .await
                .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
            if relation.is_none() {
                return Err(ApiError::internal(
                    "PostgreSQL shared schema is incomplete; apply migrations 0001 through 0039",
                ));
            }
        }
        let relay_columns_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(DISTINCT column_name)=6 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='instance_relay_policy' \
                  AND column_name=ANY(ARRAY['policy_id','enabled','allow_cidrs','allow_ports','revision','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=6 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='user_relay_policies' \
                  AND column_name=ANY(ARRAY['user_id','enabled','allow_cidrs','allow_ports','revision','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=3 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='user_relay_policy_revisions' \
                  AND column_name=ANY(ARRAY['user_id','revision','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=6 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_access_groups' \
                  AND column_name=ANY(ARRAY['group_id','name','name_key','revision','created_at','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=3 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_access_group_members' \
                  AND column_name=ANY(ARRAY['group_id','user_id','created_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=2 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_access_group_membership_revisions' \
                  AND column_name=ANY(ARRAY['group_id','revision']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=6 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_access_group_relay_policies' \
                  AND column_name=ANY(ARRAY['group_id','enabled','allow_cidrs','allow_ports','revision','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=3 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_access_group_relay_policy_revisions' \
                  AND column_name=ANY(ARRAY['group_id','revision','updated_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=2 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_user_authorization_versions' \
                  AND column_name=ANY(ARRAY['user_id','revision']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=10 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_tickets' \
                  AND column_name=ANY(ARRAY['ticket_hash','user_id','device_id','session_id', \
                    'session_access_expires_at','target_envelope','expires_at','consumed_at', \
                    'created_at','authorization_revision']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=10 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='relay_connection_leases' \
                  AND column_name=ANY(ARRAY['connection_id','node_id','user_id','device_id','session_id', \
                    'session_access_expires_at','authorization_revision','created_at','heartbeat_at', \
                    'lease_expires_at']::text[])) \
               AND (SELECT COUNT(*)=9 AND bool_and(is_nullable='NO') \
                FROM information_schema.columns WHERE table_schema=current_schema() \
                  AND table_name='relay_tickets' AND column_name=ANY(ARRAY[ \
                    'ticket_hash','user_id','device_id','session_id','session_access_expires_at', \
                    'target_envelope','expires_at','created_at','authorization_revision']::text[])) \
               AND (SELECT COUNT(*)=10 FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name='relay_tickets') \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name='relay_tickets' \
                   AND column_name='consumed_at' AND is_nullable='YES') \
               AND (SELECT COUNT(*)=10 AND bool_and(is_nullable='NO') \
                FROM information_schema.columns WHERE table_schema=current_schema() \
                  AND table_name='relay_connection_leases') \
               AND NOT EXISTS(SELECT 1 FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name='relay_tickets' \
                   AND column_name=ANY(ARRAY['ticket_token','target_ip','target_host','target_port']::text[])) \
               AND EXISTS(SELECT 1 FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid \
                 JOIN pg_namespace n ON n.oid=t.relnamespace WHERE n.nspname=current_schema() \
                   AND t.relname='sessions' AND c.conname='sessions_relay_identity_unique' \
                   AND c.contype='u' AND c.convalidated \
                   AND pg_get_constraintdef(c.oid)='UNIQUE (session_id, user_id, device_id)') \
               AND (SELECT COUNT(*)=45 AND bool_and(c.convalidated) \
                    AND bool_and(CASE \
                      WHEN c.conname IN ('instance_relay_policy_pkey','user_relay_policies_pkey', \
                        'user_relay_policy_revisions_pkey','relay_access_groups_pkey', \
                        'relay_access_group_members_pkey','relay_access_group_membership_revisions_pkey', \
                        'relay_access_group_relay_policies_pkey','relay_access_group_relay_policy_revisions_pkey', \
                        'relay_user_authorization_versions_pkey','relay_tickets_pkey', \
                        'relay_connection_leases_pkey') THEN c.contype='p' \
                      WHEN c.conname='relay_access_groups_name_key_key' THEN c.contype='u' \
                      WHEN c.conname IN ('relay_access_group_members_group_id_fkey', \
                        'relay_access_group_members_user_id_fkey', \
                        'relay_access_group_membership_revisions_group_id_fkey', \
                        'relay_access_group_relay_policies_group_id_fkey', \
                        'relay_access_group_relay_policy_revisions_group_id_fkey', \
                        'relay_tickets_device_user_fkey','relay_tickets_session_identity_fkey', \
                        'relay_connection_leases_device_user_fkey', \
                        'relay_connection_leases_session_identity_fkey') \
                        THEN c.contype='f' AND c.confdeltype='c' \
                      ELSE c.contype='c' END) \
                    FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid \
                    JOIN pg_namespace n ON n.oid=t.relnamespace \
                    WHERE n.nspname=current_schema() AND c.conname=ANY(ARRAY[ \
                      'instance_relay_policy_pkey','instance_relay_policy_singleton_check', \
                      'instance_relay_policy_revision_check','instance_relay_policy_cidrs_array_check', \
                      'instance_relay_policy_ports_array_check','user_relay_policies_pkey', \
                      'user_relay_policies_revision_check','user_relay_policies_cidrs_array_check', \
                      'user_relay_policies_ports_array_check','user_relay_policy_revisions_pkey', \
                      'user_relay_policy_revisions_revision_check','relay_access_groups_pkey', \
                      'relay_access_groups_name_key_key','relay_access_groups_revision_check', \
                      'relay_access_groups_id_check','relay_access_groups_name_check', \
                      'relay_access_groups_name_key_check','relay_access_group_members_pkey', \
                      'relay_access_group_members_group_id_fkey','relay_access_group_members_user_id_fkey', \
                      'relay_access_group_membership_revisions_pkey', \
                      'relay_access_group_membership_revisions_group_id_fkey', \
                      'relay_access_group_membership_revisions_revision_check', \
                      'relay_access_group_relay_policies_pkey','relay_access_group_relay_policies_group_id_fkey', \
                      'relay_access_group_relay_policies_revision_check', \
                      'relay_access_group_relay_policies_cidrs_array_check', \
                      'relay_access_group_relay_policies_ports_array_check', \
                      'relay_access_group_relay_policy_revisions_pkey', \
                      'relay_access_group_relay_policy_revisions_group_id_fkey', \
                      'relay_access_group_relay_policy_revisions_revision_check', \
                      'relay_user_authorization_versions_pkey', \
                      'relay_user_authorization_versions_revision_check','relay_tickets_pkey', \
                      'relay_tickets_hash_format','relay_tickets_target_envelope_format', \
                      'relay_tickets_expiry_window','relay_tickets_authorization_revision_check', \
                      'relay_tickets_device_user_fkey','relay_tickets_session_identity_fkey', \
                      'relay_connection_leases_pkey','relay_connection_leases_authorization_revision_check', \
                      'relay_connection_leases_time_check','relay_connection_leases_device_user_fkey', \
                      'relay_connection_leases_session_identity_fkey' \
                    ]::text[]))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !relay_columns_ready {
            return Err(ApiError::internal(
                "PostgreSQL SSH Relay schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let relay_indexes_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT idx.relname)=7 \
             FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid \
             JOIN pg_namespace n ON n.oid=idx.relnamespace \
             WHERE n.nspname=current_schema() AND i.indisvalid AND i.indisready \
               AND ((idx.relname=ANY(ARRAY['idx_relay_tickets_expires', \
                     'idx_relay_tickets_user_created','idx_relay_tickets_unconsumed_expires']::text[]) \
                     AND i.indrelid=to_regclass('relay_tickets')) \
                 OR (idx.relname=ANY(ARRAY['idx_relay_connection_leases_expiry', \
                     'idx_relay_connection_leases_user_expiry', \
                     'idx_relay_connection_leases_node_expiry']::text[]) \
                     AND i.indrelid=to_regclass('relay_connection_leases')) \
                 OR (idx.relname='idx_relay_access_group_members_user' \
                     AND i.indrelid=to_regclass('relay_access_group_members'))) ",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !relay_indexes_ready {
            return Err(ApiError::internal(
                "PostgreSQL SSH Relay indexes are missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        let audit_sequence_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS(\
               SELECT 1 \
               FROM pg_sequences s \
               JOIN pg_class seq ON seq.relname=s.sequencename \
               JOIN pg_namespace seq_ns ON seq_ns.oid=seq.relnamespace \
                 AND seq_ns.nspname=s.schemaname \
               JOIN pg_depend d ON d.classid='pg_class'::regclass \
                 AND d.objid=seq.oid AND d.refclassid='pg_class'::regclass \
                 AND d.refobjid=to_regclass('audit_events') \
                 AND d.refobjsubid=(SELECT a.attnum FROM pg_attribute a \
                   WHERE a.attrelid=to_regclass('audit_events') \
                     AND a.attname='event_id') AND d.deptype='i' \
               WHERE s.schemaname=current_schema() AND s.cache_size=1 \
                 AND s.last_value IS NOT NULL \
                 AND s.last_value >= COALESCE( \
                   (SELECT MAX(event_id) FROM audit_events), 0)\
             )",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !audit_sequence_ready {
            return Err(ApiError::internal(
                "PostgreSQL audit identity sequence is not ready; apply migrations 0001 through 0039",
            ));
        }
        for (table, column) in [
            ("auth_mfa", "pending_seed_envelope"),
            ("auth_mfa", "pending_credential_version"),
            ("auth_mfa_recovery_codes", "code_hash"),
            ("auth_mfa_recovery_codes", "consumed_at"),
            ("auth_mfa_login_challenges", "challenge_id_hash"),
            ("auth_mfa_login_challenges", "credential_version"),
            ("auth_mfa_login_challenges", "attempt_count"),
            ("auth_mfa_login_challenges", "consumed_at"),
        ] {
            let present: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM information_schema.columns \
                 WHERE table_schema=current_schema() AND table_name=$1 AND column_name=$2)",
            )
            .bind(table)
            .bind(column)
            .fetch_one(pool)
            .await
            .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
            if !present {
                return Err(ApiError::internal(
                    "PostgreSQL shared schema is incomplete; apply migrations 0001 through 0039",
                ));
            }
        }
        let challenge_mfa_cascade: bool = sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM pg_constraint c \
                 JOIN pg_class child ON child.oid=c.conrelid \
                 JOIN pg_namespace n ON n.oid=child.relnamespace \
                 JOIN pg_class parent ON parent.oid=c.confrelid \
                 WHERE n.nspname=current_schema() \
                   AND child.relname='auth_mfa_login_challenges' \
                   AND parent.relname='auth_mfa' \
                   AND c.conname='auth_mfa_login_challenges_user_id_fkey' \
                   AND c.contype='f' AND c.confdeltype='c' \
             )",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !challenge_mfa_cascade {
            return Err(ApiError::internal(
                "PostgreSQL MFA challenge cascade is missing; apply migrations 0001 through 0039",
            ));
        }
        let push_due_index_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM pg_index i \
                 JOIN pg_class idx ON idx.oid=i.indexrelid \
                 JOIN pg_namespace n ON n.oid=idx.relnamespace \
                 WHERE n.nspname=current_schema() \
                   AND idx.relname='idx_notification_push_outbox_due' \
                   AND i.indisvalid AND i.indisready \
                   AND i.indrelid=to_regclass('notification_push_outbox') \
             )",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !push_due_index_ready {
            return Err(ApiError::internal(
                "PostgreSQL mobile push outbox index is missing; apply migrations 0001 through 0039",
            ));
        }
        let push_token_envelope_constraint_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM pg_constraint c \
                 JOIN pg_class table_class ON table_class.oid=c.conrelid \
                 JOIN pg_namespace n ON n.oid=table_class.relnamespace \
                 WHERE n.nspname=current_schema() \
                   AND table_class.relname='notification_push_endpoints' \
                   AND c.conname='notification_push_token_envelope_length' \
                   AND c.contype='c' AND c.convalidated \
             )",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !push_token_envelope_constraint_ready {
            return Err(ApiError::internal(
                "PostgreSQL mobile push token constraint is missing; apply migrations 0001 through 0039",
            ));
        }
        let push_delivery_schema_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.tables \
             WHERE table_schema=current_schema() AND table_name='notification_push_delivery_daily') \
             AND (SELECT COUNT(*)=4 FROM information_schema.columns \
                  WHERE table_schema=current_schema() AND table_name='notification_push_delivery_daily') \
             AND EXISTS(SELECT 1 FROM pg_constraint c \
                        WHERE c.conrelid=to_regclass('notification_push_delivery_daily') \
                          AND c.contype='p' AND c.convalidated)",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !push_delivery_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL mobile push delivery aggregate schema is missing; apply migrations 0001 through 0039",
            ));
        }
        let instance_audit_index_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS( \
                 SELECT 1 FROM pg_index i \
                 JOIN pg_class idx ON idx.oid=i.indexrelid \
                 JOIN pg_namespace n ON n.oid=idx.relnamespace \
                 WHERE n.nspname=current_schema() \
                   AND idx.relname='idx_audit_events_instance_event_id' \
                   AND i.indisvalid AND i.indisready \
                   AND i.indrelid=to_regclass('audit_events') \
             )",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !instance_audit_index_ready {
            return Err(ApiError::internal(
                "PostgreSQL instance audit index is missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        let presence_indexes_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT idx.relname)=5 FROM pg_index i \
             JOIN pg_class idx ON idx.oid=i.indexrelid \
             JOIN pg_namespace n ON n.oid=idx.relnamespace \
             WHERE n.nspname=current_schema() AND i.indisvalid AND i.indisready \
               AND idx.relname=ANY(ARRAY[ \
                 'idx_vault_presence_expiry', \
                 'idx_vault_presence_session', \
                 'idx_vault_presence_vault_user_expiry', \
                 'idx_vault_presence_vault_expiry', \
                 'idx_vault_presence_heartbeat_limit_expiry' \
               ]::text[]) \
               AND ((idx.relname='idx_vault_presence_expiry' \
                       AND i.indrelid=to_regclass('vault_presence')) \
                 OR (idx.relname='idx_vault_presence_session' \
                       AND i.indrelid=to_regclass('vault_presence')) \
                 OR (idx.relname='idx_vault_presence_vault_user_expiry' \
                       AND i.indrelid=to_regclass('vault_presence')) \
                 OR (idx.relname='idx_vault_presence_vault_expiry' \
                       AND i.indrelid=to_regclass('vault_presence')) \
                 OR (idx.relname='idx_vault_presence_heartbeat_limit_expiry' \
                       AND i.indrelid=to_regclass('vault_presence_heartbeat_limits')))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !presence_indexes_ready {
            return Err(ApiError::internal(
                "PostgreSQL Vault presence indexes are missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        let admin_job_indexes_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT idx.relname)=5 \
             AND bool_and(idx.relname <> 'idx_instance_admin_jobs_one_active' OR \
                          (i.indisunique AND i.indpred IS NOT NULL \
                           AND pg_get_expr(i.indpred,i.indrelid) LIKE '%queued%' \
                           AND pg_get_expr(i.indpred,i.indrelid) LIKE '%running%')) \
             FROM pg_index i \
             JOIN pg_class idx ON idx.oid=i.indexrelid \
             JOIN pg_namespace n ON n.oid=idx.relnamespace \
             WHERE n.nspname=current_schema() AND i.indisvalid AND i.indisready \
               AND idx.relname=ANY(ARRAY[ \
                 'idx_instance_admin_jobs_one_active', \
                 'idx_instance_admin_jobs_page', \
                 'idx_instance_admin_jobs_worker', \
                 'idx_instance_admin_jobs_scheduled_slot', \
                 'idx_instance_admin_jobs_scheduled_history' \
               ]::text[]) \
               AND i.indrelid=to_regclass('instance_admin_jobs')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !admin_job_indexes_ready {
            return Err(ApiError::internal(
                "PostgreSQL instance-admin job indexes are missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        let backup_restore_job_columns_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT column_name)=24 FROM information_schema.columns \
             WHERE table_schema=current_schema() AND table_name='instance_admin_jobs' \
             AND column_name=ANY(ARRAY[ \
                 'archive_id','archive_source','archive_sha256','archive_timestamp', \
                 'restore_stage_status','restore_stage_ready_at','restore_stage_generation', \
                 'request_origin','scheduled_for','archive_bytes', \
                 'restore_stage_binding_id','restore_stage_target_fingerprint', \
                 'restore_stage_target_database_oid','restore_stage_target_database_name', \
                 'restore_stage_schema','restore_stage_object_store_id','restore_stage_object_count', \
                 'restore_stage_discard_requested_by_user_id','restore_stage_discard_requested_by_device_id', \
                 'restore_stage_discard_requested_at','restore_stage_discarded_at', \
                 'restore_stage_target_cleaned_at','restore_stage_discard_attempts', \
                 'restore_stage_discard_next_retry_at' \
               ]::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_restore_job_columns_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup/restore job schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_restore_job_constraints_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT c.conname)=16 AND bool_and(c.convalidated) \
             AND bool_and(c.contype='c') \
             FROM pg_constraint c \
             JOIN pg_class table_class ON table_class.oid=c.conrelid \
             JOIN pg_namespace n ON n.oid=table_class.relnamespace \
             WHERE n.nspname=current_schema() \
               AND table_class.relname='instance_admin_jobs' \
               AND c.conname=ANY(ARRAY[ \
                 'instance_admin_jobs_action_check', \
                 'instance_admin_jobs_status_check', \
                 'instance_admin_jobs_result_code_check', \
                 'instance_admin_jobs_archive_id_check', \
                 'instance_admin_jobs_archive_digest_check', \
                 'instance_admin_jobs_archive_timestamp_check', \
                 'instance_admin_jobs_restore_stage_check', \
                 'instance_admin_jobs_action_archive_check', \
                 'instance_admin_jobs_transition_check', \
                 'instance_admin_jobs_archive_completion_check', \
                 'instance_admin_jobs_restore_stage_binding_check', \
                 'instance_admin_jobs_restore_stage_target_cleanup_check', \
                 'instance_admin_jobs_restore_discard_retry_check', \
                 'instance_admin_jobs_request_origin_check', \
                 'instance_admin_jobs_scheduled_request_check', \
                 'instance_admin_jobs_backup_bytes_check' \
               ]::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_restore_job_constraints_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup/restore job constraints are missing; apply migrations 0001 through 0039",
            ));
        }
        if !postgres_restore_archive_source_constraint_is_exact(pool).await? {
            return Err(ApiError::internal(
                "PostgreSQL restore source constraint is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let notification_ticket_columns_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT column_name)=9 FROM information_schema.columns \
             WHERE table_schema=current_schema() AND table_name='notification_tickets' \
               AND column_name=ANY(ARRAY[ \
                 'ticket_hash','user_id','device_id','session_id','server_generation', \
                 'session_access_expires_at','created_at','expires_at','consumed_at' \
               ]::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !notification_ticket_columns_ready {
            return Err(ApiError::internal(
                "PostgreSQL notification ticket schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let notification_ticket_constraints_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT c.conname)=7 \
             AND bool_and(c.convalidated) \
             AND bool_and(CASE \
               WHEN c.conname='notification_tickets_pkey' THEN c.contype='p' \
               WHEN c.conname IN ( \
                 'notification_tickets_user_id_fkey', \
                 'notification_tickets_session_id_fkey', \
                 'notification_tickets_device_user_fkey' \
               ) THEN c.contype='f' AND c.confdeltype='c' \
               ELSE c.contype='c' \
             END) \
             FROM pg_constraint c \
             JOIN pg_class table_class ON table_class.oid=c.conrelid \
             JOIN pg_namespace n ON n.oid=table_class.relnamespace \
             WHERE n.nspname=current_schema() \
               AND table_class.relname='notification_tickets' \
               AND c.conname=ANY(ARRAY[ \
                 'notification_tickets_pkey', \
                 'notification_tickets_hash_format', \
                 'notification_tickets_user_id_fkey', \
                 'notification_tickets_session_id_fkey', \
                 'notification_tickets_device_user_fkey', \
                 'notification_tickets_expiry_after_creation', \
                 'notification_tickets_expiry_within_session' \
               ]::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !notification_ticket_constraints_ready {
            return Err(ApiError::internal(
                "PostgreSQL notification ticket constraints are missing; apply migrations 0001 through 0039",
            ));
        }
        let notification_ticket_indexes_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT idx.relname)=4 \
             FROM pg_index i \
             JOIN pg_class idx ON idx.oid=i.indexrelid \
             JOIN pg_namespace n ON n.oid=idx.relnamespace \
             WHERE n.nspname=current_schema() AND i.indisvalid AND i.indisready \
               AND idx.relname=ANY(ARRAY[ \
                 'idx_notification_tickets_user_created', \
                 'idx_notification_tickets_session_created', \
                 'idx_notification_tickets_expiry', \
                 'idx_notification_tickets_created' \
               ]::text[]) \
               AND i.indrelid=to_regclass('notification_tickets')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !notification_ticket_indexes_ready {
            return Err(ApiError::internal(
                "PostgreSQL notification ticket indexes are missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        let backup_schema_marker_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM atermius_instance_schema \
             WHERE singleton=1 AND schema_version=39)",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_schema_marker_ready {
            return Err(ApiError::internal(
                "PostgreSQL instance schema marker is missing or outdated; apply migrations 0001 through 0039",
            ));
        }
        let metrics_credential_schema_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(*)=4 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='instance_metrics_credential') \
               AND (SELECT COUNT(DISTINCT column_name)=4 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                  AND column_name=ANY(ARRAY['credential_id','verifier','created_at','updated_at']::text[])) \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                            AND column_name='credential_id' AND data_type='smallint' AND is_nullable='NO') \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                            AND column_name='verifier' AND data_type='bytea' AND is_nullable='NO') \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                            AND column_name='created_at' AND data_type='timestamp with time zone' AND is_nullable='NO') \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='instance_metrics_credential' \
                            AND column_name='updated_at' AND data_type='timestamp with time zone' AND is_nullable='NO') \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('instance_metrics_credential') \
                            AND c.contype='c' AND c.convalidated \
                            AND pg_get_constraintdef(c.oid) LIKE '%credential_id = 1%') \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('instance_metrics_credential') \
                            AND c.contype='p' AND c.convalidated \
                            AND pg_get_constraintdef(c.oid) LIKE '%credential_id%') \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('instance_metrics_credential') \
                            AND c.contype='c' AND c.convalidated \
                            AND pg_get_constraintdef(c.oid) LIKE '%octet_length(verifier)%')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !metrics_credential_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL metrics credential schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_replication_constraints_ready =
            postgres_backup_replication_constraints_are_exact(pool).await?;
        if !backup_replication_constraints_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup replication schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_replication_schema_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(*)=14 AND COUNT(DISTINCT column_name)=14 AND bool_and( \
                  CASE column_name \
                    WHEN 'archive_id' THEN data_type='text' AND is_nullable='NO' \
                    WHEN 'origin' THEN data_type='text' AND is_nullable='NO' \
                    WHEN 'created_at' THEN data_type='timestamp with time zone' AND is_nullable='NO' \
                    WHEN 'status' THEN data_type='text' AND is_nullable='NO' \
                    WHEN 'archive_bytes' THEN data_type='bigint' AND is_nullable='YES' \
                    WHEN 'archive_sha256' THEN data_type='text' AND is_nullable='YES' \
                    WHEN 'attempt_count' THEN data_type='bigint' AND is_nullable='NO' \
                    WHEN 'next_attempt_at' THEN data_type='timestamp with time zone' AND is_nullable='YES' \
                    WHEN 'started_at' THEN data_type='timestamp with time zone' AND is_nullable='YES' \
                    WHEN 'last_attempt_at' THEN data_type='timestamp with time zone' AND is_nullable='YES' \
                    WHEN 'completed_at' THEN data_type='timestamp with time zone' AND is_nullable='YES' \
                    WHEN 'failure_category' THEN data_type='text' AND is_nullable='YES' \
                    WHEN 'multipart_upload_id' THEN data_type='text' AND is_nullable='YES' \
                    WHEN 'lease_expires_at' THEN data_type='timestamp with time zone' AND is_nullable='YES' \
                    ELSE FALSE \
                  END) FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='instance_backup_replications') \
               AND (SELECT COUNT(DISTINCT c.conname)=16 AND bool_and(c.convalidated) \
                    AND bool_and(CASE WHEN c.contype='p' THEN c.conname='instance_backup_replications_pkey' \
                                      ELSE c.contype='c' END) \
                    FROM pg_constraint c \
                    WHERE c.conrelid=to_regclass('instance_backup_replications') \
                      AND c.conname=ANY(ARRAY[ \
                        'instance_backup_replications_pkey', \
                        'instance_backup_replications_archive_id_format', \
                        'instance_backup_replications_origin_check', \
                        'instance_backup_replications_status_check', \
                        'instance_backup_replications_archive_bytes_check', \
                        'instance_backup_replications_archive_sha256_check', \
                        'instance_backup_replications_attempt_count_check', \
                        'instance_backup_replications_failure_category_check', \
                        'instance_backup_replications_archive_digest_pair_check', \
                        'instance_backup_replications_succeeded_shape_check', \
                        'instance_backup_replications_pending_archive_shape_check', \
                        'instance_backup_replications_running_shape_check', \
                        'instance_backup_replications_retry_wait_shape_check', \
                        'instance_backup_replications_pending_shape_check', \
                        'instance_backup_replications_interrupted_shape_check', \
                        'instance_backup_replications_lease_shape_check' \
                      ]::text[])) \
               AND (SELECT COUNT(DISTINCT idx.relname)=2 AND bool_and(i.indisvalid AND i.indisready) \
                    FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid \
                    JOIN pg_namespace n ON n.oid=idx.relnamespace \
                    WHERE n.nspname=current_schema() AND i.indrelid=to_regclass('instance_backup_replications') \
                      AND idx.relname=ANY(ARRAY[ \
                        'idx_instance_backup_replications_one_running', \
                        'idx_instance_backup_replications_due' \
                      ]::text[])) \
               AND EXISTS(SELECT 1 FROM pg_index i \
                          JOIN pg_class idx ON idx.oid=i.indexrelid \
                          JOIN pg_am am ON am.oid=idx.relam \
                          WHERE i.indexrelid=to_regclass('idx_instance_backup_replications_one_running') \
                            AND i.indrelid=to_regclass('instance_backup_replications') \
                            AND am.amname='btree' AND i.indisunique AND i.indisvalid AND i.indisready \
                            AND i.indnatts=1 AND i.indnkeyatts=1 AND i.indexprs IS NOT NULL \
                            AND pg_get_expr(i.indexprs,i.indrelid)='1' \
                            AND pg_get_expr(i.indpred,i.indrelid)='(status = ''running''::text)') \
               AND EXISTS(SELECT 1 FROM pg_index i \
                          JOIN pg_class idx ON idx.oid=i.indexrelid \
                          JOIN pg_am am ON am.oid=idx.relam \
                          WHERE i.indexrelid=to_regclass('idx_instance_backup_replications_due') \
                            AND i.indrelid=to_regclass('instance_backup_replications') \
                            AND am.amname='btree' AND NOT i.indisunique AND i.indisvalid AND i.indisready \
                            AND i.indnatts=4 AND i.indnkeyatts=4 \
                            AND i.indexprs IS NULL AND i.indpred IS NULL \
                            AND (SELECT array_agg(a.attname::text ORDER BY key.ordinality) \
                                 FROM unnest(i.indkey) WITH ORDINALITY AS key(attnum,ordinality) \
                                 JOIN pg_attribute a ON a.attrelid=i.indrelid AND a.attnum=key.attnum) \
                                =ARRAY['status','next_attempt_at','created_at','archive_id']::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_replication_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup replication schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let restore_deadline_column_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM information_schema.columns \
             WHERE table_schema=current_schema() AND table_name='record_versions' \
               AND column_name='restore_until' AND data_type='timestamp with time zone')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !restore_deadline_column_ready {
            return Err(ApiError::internal(
                "PostgreSQL restore deadline schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let auto_purge_schema_ready: bool = sqlx::query_scalar(
            "SELECT \
               EXISTS(SELECT 1 FROM information_schema.columns \
                      WHERE table_schema=current_schema() AND table_name='record_graveyard' \
                        AND column_name='auto_purge_enabled' AND data_type='boolean' \
                        AND is_nullable='NO' AND column_default='false') \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='record_graveyard' \
                            AND column_name='auto_purge_revision' AND data_type='bigint' \
                            AND is_nullable='NO' AND column_default='0') \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('record_graveyard') \
                            AND c.conname='record_graveyard_auto_purge_revision_nonnegative' \
                            AND c.contype='c' AND c.convalidated \
                            AND pg_get_constraintdef(c.oid) LIKE '%auto_purge_revision >= 0%') \
               AND EXISTS(SELECT 1 FROM pg_index i \
                          JOIN pg_class idx ON idx.oid=i.indexrelid \
                          JOIN pg_namespace n ON n.oid=idx.relnamespace \
                          WHERE n.nspname=current_schema() \
                            AND idx.relname='idx_record_graveyard_auto_purge_candidates' \
                            AND i.indrelid=to_regclass('record_graveyard') \
                            AND i.indisvalid AND i.indisready AND i.indpred IS NOT NULL \
                            AND pg_get_expr(i.indpred,i.indrelid)='(auto_purge_enabled = true)' \
                            AND i.indnkeyatts=2 AND i.indnatts=6 \
                            AND pg_get_indexdef(i.indexrelid,1,FALSE)='vault_id' \
                            AND pg_get_indexdef(i.indexrelid,2,FALSE)='record_id' \
                            AND (SELECT collname FROM pg_catalog.pg_collation WHERE oid=i.indcollation[0])='C' \
                            AND (SELECT collname FROM pg_catalog.pg_collation WHERE oid=i.indcollation[1])='C' \
                            AND pg_get_indexdef(i.indexrelid,3,FALSE)='deleted_revision' \
                            AND pg_get_indexdef(i.indexrelid,4,FALSE)='deleted_seq' \
                            AND pg_get_indexdef(i.indexrelid,5,FALSE)='auto_purge_enabled' \
                            AND pg_get_indexdef(i.indexrelid,6,FALSE)='auto_purge_revision')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !auto_purge_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL automatic tombstone purge schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let auto_purge_scan_schema_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(DISTINCT column_name)=16 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='record_auto_purge_scan_control' \
                  AND column_name=ANY(ARRAY['singleton','after_vault_id','server_generation', \
                    'cursor_revision','lease_token','lease_expires_at','last_scan_status', \
                    'last_scan_started_at','last_scan_finished_at','last_scan_candidates', \
                    'last_scan_purged','last_scan_not_due','last_scan_capability_blocked', \
                    'last_scan_conflict_blocked','last_scan_reference_blocked', \
                    'last_scan_stale_or_withdrawn']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=8 FROM information_schema.columns \
                    WHERE table_schema=current_schema() AND table_name='record_auto_purge_vault_cursors' \
                      AND column_name=ANY(ARRAY['vault_id','after_record_id','high_water_record_id', \
                        'pending_record_id','pending_deleted_revision_id','pending_deleted_seq', \
                        'server_generation','updated_at']::text[])) \
               AND EXISTS(SELECT 1 FROM record_auto_purge_scan_control \
                          WHERE singleton=1 AND server_generation>0 AND cursor_revision>=0 \
                            AND last_scan_status IN ('never','running','completed','failed')) \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('record_auto_purge_vault_cursors') \
                            AND c.contype='c' AND c.convalidated \
                            AND pg_get_constraintdef(c.oid) LIKE '%pending_record_id IS NULL%' \
                            AND pg_get_constraintdef(c.oid) LIKE '%pending_deleted_seq IS NOT NULL%' \
                            AND pg_get_constraintdef(c.oid) LIKE '%high_water_record_id IS NOT NULL%') \
               AND EXISTS(SELECT 1 FROM pg_index i \
                          JOIN pg_class idx ON idx.oid=i.indexrelid \
                          JOIN pg_namespace n ON n.oid=idx.relnamespace \
                          WHERE n.nspname=current_schema() \
                            AND idx.relname='idx_record_auto_purge_vault_cursors_generation' \
                            AND i.indrelid=to_regclass('record_auto_purge_vault_cursors') \
                            AND i.indisvalid AND i.indisready AND i.indnkeyatts=2 \
                            AND pg_get_indexdef(i.indexrelid,1,FALSE)='server_generation' \
                            AND pg_get_indexdef(i.indexrelid,2,FALSE)='vault_id' \
                            AND (SELECT collname FROM pg_catalog.pg_collation WHERE oid=i.indcollation[1])='C')",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !auto_purge_scan_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL automatic tombstone scan schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let redaction_schema_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(DISTINCT column_name)=7 FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='record_redactions' \
                  AND column_name=ANY(ARRAY['redaction_id','vault_id','record_id', \
                    'deleted_revision_id','deleted_seq','redaction_seq','created_at']::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=3 FROM information_schema.columns \
                    WHERE table_schema=current_schema() AND table_name='record_redacted_revisions' \
                      AND column_name=ANY(ARRAY['vault_id','record_id','revision_id']::text[])) \
               AND EXISTS(SELECT 1 FROM information_schema.columns \
                          WHERE table_schema=current_schema() AND table_name='snapshots' \
                            AND column_name='redacted_at') \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('record_redactions') \
                            AND c.contype='f' AND c.convalidated \
                            AND c.confrelid=to_regclass('record_graveyard') \
                            AND c.confdeltype='r' AND c.confupdtype='r' \
                            AND pg_get_constraintdef(c.oid) LIKE \
                              'FOREIGN KEY (vault_id, record_id, deleted_revision_id, deleted_seq) REFERENCES record_graveyard(vault_id, record_id, deleted_revision, deleted_seq)%') \
               AND (SELECT COUNT(*)=3 FROM pg_attribute a \
                    WHERE a.attrelid IN (to_regclass('record_versions'), \
                         to_regclass('change_events'),to_regclass('conflicts')) \
                      AND a.attname='envelope' AND NOT a.attisdropped AND NOT a.attnotnull) \
               AND EXISTS(SELECT 1 FROM pg_constraint c \
                          WHERE c.conrelid=to_regclass('conflicts') \
                            AND c.conname='conflicts_redacted_resolution_check' \
                            AND c.contype='c' AND c.convalidated) \
               AND (SELECT COUNT(DISTINCT idx.relname)=3 AND bool_and(i.indisvalid AND i.indisready) \
                    FROM pg_index i JOIN pg_class idx ON idx.oid=i.indexrelid \
                    JOIN pg_namespace n ON n.oid=idx.relnamespace \
                    WHERE n.nspname=current_schema() \
                      AND idx.relname=ANY(ARRAY['idx_record_graveyard_redaction_metadata', \
                        'idx_record_redactions_vault_record', \
                        'idx_record_redacted_revisions_lookup']::text[]))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL redaction schema validation failed"))?;
        if !redaction_schema_ready {
            return Err(ApiError::internal(
                "PostgreSQL record redaction schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_schedule_ready: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM instance_backup_schedule WHERE schedule_id=1) \
             AND (SELECT COUNT(DISTINCT column_name)=3 FROM information_schema.columns \
                  WHERE table_schema=current_schema() AND table_name='instance_backup_schedule' \
                    AND column_name=ANY(ARRAY['schedule_id','interval_hours','next_run_at']::text[])) \
             AND (SELECT COUNT(DISTINCT c.conname)=4 AND bool_and(c.convalidated) \
                  FROM pg_constraint c JOIN pg_class t ON t.oid=c.conrelid \
                  JOIN pg_namespace n ON n.oid=t.relnamespace \
                  WHERE n.nspname=current_schema() AND t.relname='instance_backup_schedule' \
                    AND c.conname=ANY(ARRAY[ \
                      'instance_backup_schedule_pkey', \
                      'instance_backup_schedule_singleton_check', \
                      'instance_backup_schedule_interval_hours_check', \
                      'instance_backup_schedule_due_pair_check' \
                    ]::text[]))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_schedule_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup schedule schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_pin_columns_ready: bool = sqlx::query_scalar(
            "SELECT \
               (SELECT COUNT(DISTINCT column_name)=5 AND bool_and(is_nullable='NO') \
                FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='backup_object_pins' \
                  AND column_name=ANY(ARRAY[ \
                    'backup_id','storage_store_id','storage_key','expires_at','created_at' \
                  ]::text[])) \
               AND (SELECT COUNT(DISTINCT column_name)=4 AND bool_and(is_nullable='NO') \
                FROM information_schema.columns \
                WHERE table_schema=current_schema() AND table_name='backup_object_pin_sets' \
                  AND column_name=ANY(ARRAY[ \
                    'backup_id','object_count','expires_at','created_at' \
                  ]::text[]))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_pin_columns_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup object pin schema is incomplete; apply migrations 0001 through 0039",
            ));
        }
        let backup_pin_constraints_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT c.conname)=7 \
             AND bool_and(c.convalidated) \
             AND bool_and(CASE WHEN c.contype='p' THEN c.conname IN ( \
                   'backup_object_pins_pkey','backup_object_pin_sets_pkey') \
                   ELSE c.contype='c' END) \
             FROM pg_constraint c \
             JOIN pg_class table_class ON table_class.oid=c.conrelid \
             JOIN pg_namespace n ON n.oid=table_class.relnamespace \
             WHERE n.nspname=current_schema() \
               AND table_class.relname=ANY(ARRAY[ \
                 'backup_object_pins','backup_object_pin_sets' \
               ]::text[]) \
               AND c.conname=ANY(ARRAY[ \
                 'backup_object_pins_pkey', \
                 'backup_object_pins_backup_id_format', \
                 'backup_object_pins_storage_store_id_check', \
                 'backup_object_pins_storage_key_check', \
                 'backup_object_pin_sets_pkey', \
                 'backup_object_pin_sets_backup_id_format', \
                 'backup_object_pin_sets_object_count_check' \
               ]::text[])",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_pin_constraints_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup object pin constraints are missing; apply migrations 0001 through 0039",
            ));
        }
        let backup_pin_indexes_ready: bool = sqlx::query_scalar(
            "SELECT COUNT(DISTINCT idx.relname)=3 \
             FROM pg_index i \
             JOIN pg_class idx ON idx.oid=i.indexrelid \
             JOIN pg_namespace n ON n.oid=idx.relnamespace \
             WHERE n.nspname=current_schema() AND i.indisvalid AND i.indisready \
               AND ((idx.relname IN ( \
                      'idx_backup_object_pins_storage_expiry', \
                      'idx_backup_object_pins_expiry') \
                     AND i.indrelid=to_regclass('backup_object_pins')) \
                 OR (idx.relname='idx_backup_object_pin_sets_expiry' \
                     AND i.indrelid=to_regclass('backup_object_pin_sets')))",
        )
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync schema validation failed"))?;
        if !backup_pin_indexes_ready {
            return Err(ApiError::internal(
                "PostgreSQL backup object pin indexes are missing or invalid; apply migrations 0001 through 0039",
            ));
        }
        Ok(())
    }
}

pub(crate) async fn backfill_postgres_restore_deadlines(
    pool: &PgPool,
    retention_days: i64,
) -> Result<(), ApiError> {
    if !(1..=3650).contains(&retention_days) {
        return Err(ApiError::internal(
            "legacy restore retention policy is outside the supported range",
        ));
    }
    sqlx::query(
        "UPDATE record_versions \
         SET restore_until=created_at + make_interval(days => $1::INTEGER) \
         WHERE operation='delete' AND restore_until IS NULL",
    )
    .bind(retention_days as i32)
    .execute(pool)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

fn required_value(value: Option<&str>) -> Result<&str, ApiError> {
    value
        .filter(|value| !value.is_empty())
        .ok_or_else(|| config_error("PostgreSQL sync backend configuration is incomplete"))
}

fn valid_identifier(value: &str) -> bool {
    let mut bytes = value.bytes();
    let Some(first) = bytes.next() else {
        return false;
    };
    (first.is_ascii_alphabetic() || first == b'_')
        && bytes.all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        && value.len() <= 63
}

fn config_error(message: &'static str) -> ApiError {
    ApiError::new(
        axum::http::StatusCode::INTERNAL_SERVER_ERROR,
        "INVALID_SYNC_BACKEND_CONFIGURATION",
        message,
    )
}

async fn postgres_backup_replication_constraints_are_exact(
    pool: &PgPool,
) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "WITH expected(conname,contype,definition) AS (VALUES \
           ('instance_backup_replications_pkey','p','PRIMARY KEY (archive_id)'), \
           ('instance_backup_replications_archive_id_format','c','CHECK ((archive_id ~ ''^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$''::text))'), \
           ('instance_backup_replications_origin_check','c','CHECK ((origin = ANY (ARRAY[''manual''::text, ''scheduled''::text])))'), \
           ('instance_backup_replications_status_check','c','CHECK ((status = ANY (ARRAY[''pending_archive''::text, ''pending''::text, ''running''::text, ''retry_wait''::text, ''succeeded''::text, ''interrupted''::text, ''failed''::text])))'), \
           ('instance_backup_replications_archive_bytes_check','c','CHECK (((archive_bytes IS NULL) OR (archive_bytes > 0)))'), \
           ('instance_backup_replications_archive_sha256_check','c','CHECK (((archive_sha256 IS NULL) OR (archive_sha256 ~ ''^[0-9a-f]{64}$''::text)))'), \
           ('instance_backup_replications_attempt_count_check','c','CHECK ((attempt_count >= 0))'), \
           ('instance_backup_replications_failure_category_check','c','CHECK (((failure_category IS NULL) OR (failure_category = ANY (ARRAY[''archive_unavailable''::text, ''credentials_invalid''::text, ''remote_unavailable''::text, ''remote_integrity_mismatch''::text, ''replication_failed''::text]))))'), \
           ('instance_backup_replications_archive_digest_pair_check','c','CHECK (( (archive_bytes IS NULL) = (archive_sha256 IS NULL)))'), \
           ('instance_backup_replications_succeeded_shape_check','c','CHECK (((status <> ''succeeded''::text) OR ((archive_bytes IS NOT NULL) AND (archive_sha256 IS NOT NULL) AND (completed_at IS NOT NULL) AND (failure_category IS NULL) AND (next_attempt_at IS NULL) AND (multipart_upload_id IS NULL))))'), \
           ('instance_backup_replications_pending_archive_shape_check','c','CHECK (((status <> ''pending_archive''::text) OR ((archive_bytes IS NULL) AND (archive_sha256 IS NULL) AND (attempt_count = 0))))'), \
           ('instance_backup_replications_running_shape_check','c','CHECK (((status <> ''running''::text) OR ((started_at IS NOT NULL) AND (next_attempt_at IS NULL) AND (failure_category IS NULL))))'), \
           ('instance_backup_replications_retry_wait_shape_check','c','CHECK (((status <> ''retry_wait''::text) OR ((next_attempt_at IS NOT NULL) AND (failure_category IS NOT NULL))))'), \
           ('instance_backup_replications_pending_shape_check','c','CHECK (((status <> ''pending''::text) OR ((archive_bytes IS NOT NULL) AND (archive_sha256 IS NOT NULL) AND (next_attempt_at IS NOT NULL) AND (failure_category IS NULL))))'), \
           ('instance_backup_replications_interrupted_shape_check','c','CHECK (((status <> ''interrupted''::text) OR (next_attempt_at IS NOT NULL)))'), \
           ('instance_backup_replications_lease_shape_check','c','CHECK (((status = ''running''::text) = (lease_expires_at IS NOT NULL)))') \
         ) \
         SELECT COUNT(c.conname)=16 AND bool_and(c.convalidated) \
                AND bool_and(c.contype=expected.contype AND \
                    regexp_replace(pg_get_constraintdef(c.oid),'[[:space:]]+','','g') = \
                    regexp_replace(expected.definition,'[[:space:]]+','','g')) \
         FROM expected LEFT JOIN pg_constraint c \
           ON c.conrelid=to_regclass('instance_backup_replications') \
          AND c.conname=expected.conname",
    )
    .fetch_one(pool)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL backup replication schema validation failed"))
}

const PG_RESTORE_ARCHIVE_CHECK: &str = "CHECK ((((action = 'maintenance'::text) AND (archive_id IS NULL) AND (archive_source IS NULL) AND (archive_sha256 IS NULL) AND (archive_timestamp IS NULL) AND (restore_stage_status IS NULL) AND (restore_stage_ready_at IS NULL) AND (restore_stage_generation IS NULL)) OR ((action = 'backup'::text) AND (archive_id = job_id) AND (archive_source IS NULL) AND (restore_stage_status IS NULL) AND (restore_stage_ready_at IS NULL) AND (restore_stage_generation IS NULL)) OR ((action = 'restore'::text) AND (archive_id IS NOT NULL) AND (archive_source = ANY (ARRAY['local'::text, 'replica'::text])))))";

async fn postgres_restore_archive_source_constraint_is_exact(
    pool: &PgPool,
) -> Result<bool, ApiError> {
    sqlx::query_scalar(
        "SELECT COUNT(c.conname)=1 AND bool_and(c.convalidated AND c.contype='c' \
            AND regexp_replace(pg_get_constraintdef(c.oid),'[[:space:]]+','','g') \
                =regexp_replace($1,'[[:space:]]+','','g')) \
         FROM pg_constraint c \
         WHERE c.conrelid=to_regclass('instance_admin_jobs') \
           AND c.conname='instance_admin_jobs_action_archive_check'",
    )
    .bind(PG_RESTORE_ARCHIVE_CHECK)
    .fetch_one(pool)
    .await
    .map_err(|_| ApiError::internal("PostgreSQL restore source schema validation failed"))
}

#[cfg(test)]
mod tests {
    use super::{
        PgSyncRuntimeConfig, acquire_server_lifetime_lock,
        postgres_backup_replication_constraints_are_exact,
        postgres_restore_archive_source_constraint_is_exact, valid_identifier,
    };

    #[test]
    fn postgres_schema_name_is_a_single_bounded_identifier() {
        let max = "x".repeat(63);
        let too_long = "x".repeat(64);
        for valid in ["atermius_test", "A1", "_schema", max.as_str()] {
            assert!(valid_identifier(valid));
        }
        for invalid in [
            "",
            "1schema",
            "schema.name",
            "x;DROP_SCHEMA",
            too_long.as_str(),
        ] {
            assert!(!valid_identifier(invalid));
        }
    }

    #[test]
    fn backend_selection_is_opt_in_and_rejects_partial_or_unsafe_configuration() {
        assert!(
            PgSyncRuntimeConfig::from_values(None, None, None, None, None)
                .unwrap()
                .is_none()
        );
        assert!(
            PgSyncRuntimeConfig::from_values(
                Some("sqlite"),
                Some("postgresql://ignored"),
                None,
                None,
                None,
            )
            .unwrap()
            .is_none()
        );
        assert!(
            PgSyncRuntimeConfig::from_values(Some("postgres"), None, None, None, None,).is_err()
        );
        assert!(
            PgSyncRuntimeConfig::from_values(
                Some("postgres"),
                Some("sqlite://local"),
                Some("schema"),
                Some("/shared/instance.key"),
                Some("/shared/rate.key"),
            )
            .is_err()
        );
        assert!(
            PgSyncRuntimeConfig::from_values(
                Some("postgres"),
                Some("postgresql://operator@db/test"),
                Some("schema;drop"),
                Some("/shared/instance.key"),
                Some("/shared/rate.key"),
            )
            .is_err()
        );
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn releasing_shared_runtime_lock_allows_exclusive_lock_from_another_session() {
        use std::str::FromStr;

        use sqlx::{Connection, PgConnection, postgres::PgConnectOptions, postgres::PgPoolOptions};

        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for the PostgreSQL lock test");
        let parsed_url = url::Url::parse(&database_url).unwrap();
        let database_name = parsed_url.path().trim_start_matches('/');
        assert!(
            database_name.starts_with("atermius_test")
                || database_name.starts_with("atermius_pg_test"),
            "runtime lock test requires an explicitly disposable PostgreSQL database"
        );

        let options = PgConnectOptions::from_str(&database_url).unwrap();
        let pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone())
            .await
            .unwrap();
        let mut observer = PgConnection::connect_with(&options).await.unwrap();
        let lock = acquire_server_lifetime_lock(&pool).await.unwrap();
        let key = lock.key;

        let blocked: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock($1)")
            .bind(key)
            .fetch_one(&mut observer)
            .await
            .unwrap();
        assert!(
            !blocked,
            "an exclusive lock must remain blocked while the shared runtime lock is held"
        );

        if let Err(error) = lock.release().await {
            pool.close().await;
            panic!("explicit shared runtime lock release failed: {error:?}");
        }
        let acquired: bool = sqlx::query_scalar("SELECT pg_try_advisory_lock($1)")
            .bind(key)
            .fetch_one(&mut observer)
            .await
            .unwrap();
        assert!(
            acquired,
            "another PostgreSQL session must acquire the exclusive lock after shared release"
        );
        let unlocked: bool = sqlx::query_scalar("SELECT pg_advisory_unlock($1)")
            .bind(key)
            .fetch_one(&mut observer)
            .await
            .unwrap();
        assert!(unlocked, "the observer must release its exclusive lock");

        observer.close().await.unwrap();
        pool.close().await;
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn postgres_runtime_rejects_same_name_backup_replication_check_with_wrong_definition() {
        use std::str::FromStr;

        use sqlx::{postgres::PgConnectOptions, postgres::PgPoolOptions};
        use uuid::Uuid;

        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for the PostgreSQL readiness test");
        let options = PgConnectOptions::from_str(&database_url).unwrap();
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "schema readiness test requires an explicitly disposable PostgreSQL database"
        );
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone())
            .await
            .unwrap();
        let schema = format!("atermius_pg_runtime_check_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .unwrap();
        let test_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
            .await
            .unwrap();

        let result = async {
            sqlx::raw_sql(
                "CREATE TABLE atermius_instance_schema ( \
                   singleton SMALLINT PRIMARY KEY CHECK(singleton=1), \
                   schema_version INTEGER NOT NULL \
                 ); \
                 INSERT INTO atermius_instance_schema(singleton,schema_version) VALUES(1,35)",
            )
            .execute(&test_pool)
            .await
            .map_err(|error| error.to_string())?;
            sqlx::raw_sql(include_str!(
                "../migrations/postgres/0036_instance_backup_replications.sql"
            ))
            .execute(&test_pool)
            .await
            .map_err(|error| error.to_string())?;
            sqlx::raw_sql(include_str!(
                "../migrations/postgres/0037_instance_backup_replication_leases.sql"
            ))
            .execute(&test_pool)
            .await
            .map_err(|error| error.to_string())?;
            let valid_before = postgres_backup_replication_constraints_are_exact(&test_pool)
                .await
                .map_err(|error| format!("valid schema check failed: {}", error.body.code))?;
            sqlx::raw_sql(
                "ALTER TABLE instance_backup_replications \
                   DROP CONSTRAINT instance_backup_replications_lease_shape_check; \
                 ALTER TABLE instance_backup_replications \
                   ADD CONSTRAINT instance_backup_replications_lease_shape_check CHECK (TRUE)",
            )
            .execute(&test_pool)
            .await
            .map_err(|error| error.to_string())?;
            let valid_after = postgres_backup_replication_constraints_are_exact(&test_pool)
                .await
                .map_err(|error| format!("malformed schema check failed: {}", error.body.code))?;
            Ok::<_, String>((valid_before, valid_after))
        }
        .await;

        test_pool.close().await;
        sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
            .execute(&admin_pool)
            .await
            .unwrap();
        admin_pool.close().await;
        let (valid_before, valid_after) = result.unwrap();
        assert!(
            valid_before,
            "the exact migration-defined constraints must pass"
        );
        assert!(
            !valid_after,
            "a same-name permissive lease CHECK must fail schema readiness"
        );
    }

    #[tokio::test]
    #[ignore = "requires ATERMIUS_TEST_PG_URL naming a disposable PostgreSQL database"]
    async fn postgres_runtime_rejects_same_name_restore_archive_check_with_wrong_definition() {
        use std::{path::Path, str::FromStr};

        use sqlx::{postgres::PgConnectOptions, postgres::PgPoolOptions};
        use uuid::Uuid;

        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("ATERMIUS_TEST_PG_URL is required for the PostgreSQL readiness test");
        let options = PgConnectOptions::from_str(&database_url).unwrap();
        let database = options
            .get_database()
            .expect("PostgreSQL test URL names a database")
            .to_ascii_lowercase();
        assert!(
            database.starts_with("atermius_test") || database.starts_with("atermius_pg_test"),
            "schema readiness test requires an explicitly disposable PostgreSQL database"
        );
        let admin_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.clone())
            .await
            .unwrap();
        let schema = format!("atermius_pg_restore_check_{}", Uuid::new_v4().simple());
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .unwrap();
        let test_pool = PgPoolOptions::new()
            .max_connections(2)
            .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
            .await
            .unwrap();

        let result = async {
            let migration_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
            let mut migrations: Vec<_> = std::fs::read_dir(&migration_dir)
                .map_err(|error| error.to_string())?
                .filter_map(Result::ok)
                .map(|entry| entry.path())
                .filter(|path| {
                    path.file_name()
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| {
                            name.as_bytes()
                                .get(..4)
                                .is_some_and(|prefix| prefix.iter().all(u8::is_ascii_digit))
                                && name.ends_with(".sql")
                        })
                })
                .collect();
            migrations.sort();
            for migration in migrations {
                let sql = std::fs::read_to_string(migration).map_err(|error| error.to_string())?;
                sqlx::raw_sql(&sql)
                    .execute(&test_pool)
                    .await
                    .map_err(|error| error.to_string())?;
            }
            let valid_before = postgres_restore_archive_source_constraint_is_exact(&test_pool)
                .await
                .map_err(|error| format!("valid schema check failed: {}", error.body.code))?;
            sqlx::raw_sql(
                "ALTER TABLE instance_admin_jobs \
                   DROP CONSTRAINT instance_admin_jobs_action_archive_check; \
                 ALTER TABLE instance_admin_jobs \
                   ADD CONSTRAINT instance_admin_jobs_action_archive_check CHECK (TRUE)",
            )
            .execute(&test_pool)
            .await
            .map_err(|error| error.to_string())?;
            let valid_after = postgres_restore_archive_source_constraint_is_exact(&test_pool)
                .await
                .map_err(|error| format!("malformed schema check failed: {}", error.body.code))?;
            Ok::<_, String>((valid_before, valid_after))
        }
        .await;

        test_pool.close().await;
        sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
            .execute(&admin_pool)
            .await
            .unwrap();
        admin_pool.close().await;
        let (valid_before, valid_after) = result.unwrap();
        assert!(
            valid_before,
            "the exact migration-defined restore source constraint must pass"
        );
        assert!(
            !valid_after,
            "a same-name permissive restore source CHECK must fail schema readiness"
        );
    }
}

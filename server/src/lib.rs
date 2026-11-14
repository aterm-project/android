//! Atermius ciphertext-only self-hosted sync server.
//!
//! The service deliberately has no vault decryption primitive or plaintext record API.

mod account;
mod admin;
mod audit;
mod auth;
mod backup;
mod backup_replication;
mod backup_status;
mod cloud;
mod cloud_orgs;
#[cfg(test)]
mod cloud_tests;
mod collaboration;
mod control;
// Per-account credential visibility and client-side Vault-key escrow (SQLite only).
mod credential_visibility;
#[cfg(test)]
mod credential_visibility_tests;
mod database;
mod database_encryption;
#[cfg(test)]
mod database_encryption_tests;
mod device_capabilities;
mod error;
mod instance_identity;
mod maintenance_repository;
mod mfa;
mod mfa_key_rotation;
mod mobile_push;
mod notifications;
mod object_store;
mod object_store_migration;
mod objects;
mod redaction_capabilities;
// Shared object transfer and bounded GC for the restricted PostgreSQL runtime.
mod pg_objects;
// Shared administrator maintenance jobs for the restricted PostgreSQL runtime.
mod pg_admin_jobs;
// Aggregate-only mobile push health snapshots for the restricted PG admin surface.
mod pg_admin_push_health;
// Shared, verifier-only PostgreSQL storage for future Prometheus admin routes.
#[allow(dead_code)]
mod pg_admin_metrics;
// Shared PostgreSQL ciphertext-backup replication outbox foundation.
#[allow(dead_code)]
mod pg_backup_replication;
// Aggregate-only instance administrator reads for the restricted PostgreSQL runtime.
mod pg_admin_overview;
// Read-only account and session projections for the restricted PG admin surface.
mod pg_admin_accounts;
// Username-bound account invitation management for the restricted PG admin surface.
mod pg_admin_invitations;
// Safe Vault inventory and transactional quota controls for the restricted PG admin surface.
mod pg_admin_vaults;
// Stable PostgreSQL audit reads use the sequence and lock contract from migration 0018.
mod pg_audit;
// Shared bounded history, snapshot-payload, and auth-bucket retention for PG.
mod pg_maintenance;
// Shared short-lived Vault presence leases for the restricted PostgreSQL runtime.
mod pg_presence;
// PostgreSQL sync mutation transactions are composed into PgSyncRepository.
mod pg_sync_commit;
// PostgreSQL bearer authentication and key lookup are selected only by the
// explicitly configured restricted sync-core runtime.
mod pg_sync_auth;
// Shared PostgreSQL auth-attempt counters are selected for allowed anonymous
// authentication routes in restricted sync-core mode.
mod pg_rate_limit;
// Password login and refresh for explicitly provisioned PostgreSQL accounts.
mod pg_auth_lifecycle;
// Shared PostgreSQL TOTP enrollment and login challenges.
mod pg_mfa;
// Shared PostgreSQL account bootstrap, registration, and invite issuance.
mod pg_account_onboarding;
// PostgreSQL account/Vault read projections needed to unlock the Web client.
mod pg_account_reads;
// Signed synchronous approval of additional PostgreSQL-backed devices.
mod pg_device_enrollment;
// Shared PostgreSQL signed capability updates and device revocation.
mod pg_device_lifecycle;
// PostgreSQL-backed mobile endpoint storage and leased sync-hint delivery.
mod pg_mobile_push;
// Shared PostgreSQL WebSocket invalidations with LISTEN/NOTIFY and poll fallback.
mod pg_notifications;
// Atomic PostgreSQL Vault creation for accounts using the shared runtime.
mod pg_vault_lifecycle;
// Device-bound PostgreSQL Vault invitation issuance and acceptance.
mod pg_vault_invitations;
// Atomic PostgreSQL Vault key rotation.
mod pg_vault_rotation;
// PostgreSQL Vault deletion requests, purge, and durable external-object GC.
mod pg_vault_deletion;
// PostgreSQL account deletion, shared-history key archives, and purge.
mod pg_account_deletion;
// Client-encrypted PostgreSQL account Recovery lifecycle.
mod pg_account_recovery;
mod pg_recovery_context;
// Shared PostgreSQL SSH Relay tickets, policy, access groups, and connection leases.
mod pg_record_purge;
mod pg_record_redaction;
// Bounded automatic tombstone purge scanner, invoked by Maintenance only for
// records with explicit per-tombstone Vault Owner consent.
mod pg_record_auto_purge_scan;
mod pg_redaction_capabilities;
mod pg_relay;
mod record_purge;
mod record_purge_actor;
// Bounded automatic tombstone purge scanner for the local SQLite runtime.
mod sqlite_auto_purge_scan;
// Shared secret loading/derivation used by the restricted sync-core runtime.
mod pg_runtime_keys;
#[cfg(test)]
mod pg_sync_core;
#[allow(dead_code)]
mod pg_sync_read;
// PostgreSQL conflict-feed paging is composed into PgSyncRepository.
#[allow(dead_code)]
mod pg_sync_conflict_read;
// PostgreSQL conflict creation/resolution are used only by the restricted
// sync-core runtime; lifecycle operations remain blocked there.
#[allow(dead_code)]
mod pg_sync_conflict_write;
// PostgreSQL revision/history reads are composed into the restricted
// sync-core runtime.
#[allow(dead_code)]
mod pg_sync_history_read;
// PostgreSQL snapshot create/read are composed into the restricted sync-core
// runtime.
#[allow(dead_code)]
mod pg_sync_snapshots;
// Composite PostgreSQL sync-trait adapter; the ordinary runtime still uses
// SQLite. An explicitly selected restricted sync-core runtime constructs it
// after schema and shared-key validation.
mod desktop;
mod pg_sync_repository;
mod pg_sync_runtime;
mod presence;
mod rate_limit;
mod recovery;
mod relay;
mod relay_groups;
mod secure_file;
mod share_gateway;
mod share_guest;
mod share_links;
mod sync;
mod sync_repository;

use std::{
    collections::HashMap,
    ffi::OsStr,
    fs::{File, OpenOptions},
    net::SocketAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
    time::Duration,
};

use axum::{
    Router,
    extract::{OriginalUri, Request},
    http::{HeaderName, HeaderValue, Method, StatusCode, header::CONTENT_TYPE},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post, put},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::SigningKey;
use ipnet::IpNet;
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Digest;
use sqlx::{
    PgPool, Row, Sqlite, SqlitePool, Transaction,
    sqlite::{SqliteJournalMode, SqlitePoolOptions},
};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tower_http::{cors::CorsLayer, limit::RequestBodyLimitLayer, trace::TraceLayer};
use uuid::Uuid;

pub use auth::{create_account_invitation, create_account_invitation_with_credential_visibility};
pub use backup::{
    BackupSummary, BackupVerification, PgRestoreStageActivationResult,
    PgRestoreStageRollbackFenceResult, RestoreResult, activate_pg_restore_stage, backup_instance,
    fence_pg_restore_stage_rollback, install_configured_admin_restore_stage,
    restore_instance_to_new_directory, restore_instance_with_runtime_policy_drift,
    verify_instance_backup,
};
pub use backup_status::{record_backup_failure, record_backup_success};
pub use database_encryption::{
    DatabaseCheckpointSummary, DatabaseEncryptSummary, DatabaseRekeySummary,
    checkpoint_database_offline, encrypt_database_offline, generate_database_key_file,
    import_database_key_file, rekey_database_offline,
};
pub use error::{ApiError, ErrorBody};
pub use instance_identity::rotate_instance_signing_key;
pub use mfa_key_rotation::{
    MfaKeyRotationSummary, rotate_mfa_seed_encryption_key,
    rotate_mfa_seed_encryption_key_for_selected_backend,
    rotate_mfa_seed_encryption_key_with_database_key,
};
pub use object_store_migration::run_object_store_migration;

pub(crate) const DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP: i64 = 10_000;
pub(crate) const MAX_ACTIVE_RECOVERY_CHALLENGE_CAP: i64 = 100_000;

#[derive(Clone)]
pub struct AppState {
    pub db: SqlitePool,
    pub(crate) sync_repository: Arc<dyn sync_repository::SyncRepository>,
    pub(crate) pg_sync_pool: Option<PgPool>,
    pub(crate) pg_relay_node_id: Uuid,
    pub(crate) pg_sync_auth: Option<pg_sync_auth::PgSyncAuthRepository>,
    pub(crate) pg_redaction_capabilities:
        Option<pg_redaction_capabilities::PgRedactionCapabilityRepository>,
    pub(crate) pg_auth_lifecycle: Option<pg_auth_lifecycle::PgAuthLifecycleRepository>,
    pub(crate) pg_mfa: Option<pg_mfa::PgMfaRepository>,
    pub(crate) pg_account_onboarding: Option<pg_account_onboarding::PgAccountOnboardingRepository>,
    pub(crate) pg_account_reads: Option<pg_account_reads::PgAccountReadsRepository>,
    pub(crate) pg_vault_deletion: Option<pg_vault_deletion::PgVaultDeletionRepository>,
    pub(crate) pg_account_deletion: Option<pg_account_deletion::PgAccountDeletionRepository>,
    pub(crate) pg_objects: Option<pg_objects::PgObjectRepository>,
    pub(crate) pg_mobile_push: Option<pg_mobile_push::PgMobilePushRepository>,
    pub(crate) pg_auth_rate_limits: Option<pg_rate_limit::PgAuthRateLimitRepository>,
    pub(crate) pg_sync_only: bool,
    pub(crate) maintenance_repository: Arc<dyn maintenance_repository::MaintenanceRepository>,
    pub instance: Arc<InstanceInfo>,
    pub signing_key: Arc<SigningKey>,
    pub cursor_key: Arc<[u8; 32]>,
    pub auth_rate_key: Arc<[u8; 32]>,
    pub dummy_login_verifier_hash: Arc<String>,
    /// Optional operator-held key used only to encrypt TOTP seeds at rest.
    /// It is intentionally not derived from or stored in the instance DB.
    pub mfa_encryption_key: Option<Arc<[u8; 32]>>,
    /// Operator-held SQLCipher key of the main database, when encryption at
    /// rest is enabled. Used to open restore stages prepared by this server.
    pub(crate) database_key: Option<Arc<database::DatabaseKey>>,
    pub(crate) database_encryption: database::DatabaseEncryption,
    pub(crate) object_store: object_store::ObjectStore,
    pub relay_connections: Arc<Mutex<HashMap<String, usize>>>,
    pub relay_connection_slots: Arc<Semaphore>,
    pub object_completion_slots: Arc<Semaphore>,
    pub notification_connections: Arc<Mutex<HashMap<String, usize>>>,
    pub notification_connection_slots: Arc<Semaphore>,
    pub notification_query_slots: Arc<Semaphore>,
    pub(crate) pg_notification_hub: pg_notifications::PgNotificationHub,
    pub(crate) collaboration: collaboration::CollaborationState,
    /// Organizations, temporary links and the trusted share gateway.
    pub(crate) cloud: Arc<cloud::CloudState>,
    pub maintenance_lock: Arc<tokio::sync::Mutex<()>>,
    pub(crate) vault_limits: VaultLimits,
    pub config: Arc<Config>,
}

/// Instance-wide account and membership ceilings loaded once at startup.
/// Operators can raise the defaults within these hard bounds through the
/// corresponding `ATERMIUS_MAX_*` environment variables.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct VaultLimits {
    pub(crate) max_vaults_per_user: i64,
    pub(crate) max_members_per_vault: i64,
}

impl VaultLimits {
    fn from_env() -> Self {
        Self::from_values(
            std::env::var("ATERMIUS_MAX_VAULTS_PER_USER").ok(),
            std::env::var("ATERMIUS_MAX_MEMBERS_PER_VAULT").ok(),
        )
    }

    fn from_values(
        max_vaults_per_user: Option<String>,
        max_members_per_vault: Option<String>,
    ) -> Self {
        Self {
            max_vaults_per_user: bounded_value(max_vaults_per_user, 50, 1, 4096),
            max_members_per_vault: bounded_value(max_members_per_vault, 100, 1, 1000),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct InstanceInfo {
    pub instance_id: String,
    pub server_space_id: String,
    pub generation: String,
    pub signing_public_key: String,
    pub signing_key_transitions: Vec<InstanceKeyTransition>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InstanceKeyTransition {
    pub format: String,
    pub instance_id: String,
    pub from_public_key: String,
    pub to_public_key: String,
    pub issued_at: String,
    pub signature: String,
}

#[derive(Serialize)]
struct InstanceKeyTransitionPayload<'a> {
    format: &'static str,
    instance_id: &'a str,
    from_public_key: &'a str,
    to_public_key: &'a str,
    issued_at: &'a str,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub data_dir: PathBuf,
    /// Optional owner-configured destination for encrypted instance backups.
    /// Both backup settings are optional so existing deployments can start;
    /// the allowlisted admin action fails closed until both are valid.
    pub backup_archive_dir: Option<PathBuf>,
    pub backup_key_file: Option<PathBuf>,
    /// Raw optional settings for the server-only S3 backup replica. Raw OS
    /// strings are retained so explicitly empty/non-Unicode values fail
    /// closed during validation instead of silently disabling replication.
    pub backup_replication_env: BackupReplicationEnv,
    /// Optional external 32-byte owner-only key file for TOTP seed encryption.
    pub mfa_encryption_key_file: Option<PathBuf>,
    /// Optional external 32-byte owner-only SQLCipher key for the main
    /// SQLite database (`ATERMIUS_DATABASE_KEY_FILE`). It must live outside
    /// `data_dir`. Unset keeps a plaintext database and is reported to admins.
    pub database_key_file: Option<PathBuf>,
    /// The raw optional value is retained so malformed and non-Unicode values
    /// fail closed instead of silently disabling archive retention.
    pub backup_retention_count: Option<std::ffi::OsString>,
    pub registration_open: bool,
    pub relay_enabled: bool,
    pub guacd_address: Option<String>,
    pub terminal_collaboration_enabled: bool,
    pub relay_allow_cidrs: Vec<IpNet>,
    pub relay_allow_ports: Vec<u16>,
    pub relay_max_connections_per_user: usize,
    pub public_origin: Option<String>,
    pub web_dir: Option<PathBuf>,
    pub max_object_bytes: i64,
    pub max_request_bytes: usize,
    pub history_retention_days: i64,
    /// Number of days a tombstoned record may be restored before clients must
    /// create a new record ID. Defaults to the product's 30-day recycle bin.
    pub record_restore_retention_days: i64,
    pub vault_deletion_grace_seconds: i64,
    pub account_deletion_grace_seconds: i64,
    pub audit_retention_days: i64,
    pub object_gc_grace_seconds: i64,
    /// Normalized account usernames permitted to view instance administration data.
    pub admin_usernames: Vec<String>,
    pub auth_rate_limits: AuthRateLimits,
}

#[derive(Debug, Clone, Default)]
pub struct BackupReplicationEnv {
    pub bucket: Option<std::ffi::OsString>,
    pub region: Option<std::ffi::OsString>,
    pub credentials_file: Option<std::ffi::OsString>,
    pub endpoint_url: Option<std::ffi::OsString>,
    pub prefix: Option<std::ffi::OsString>,
}

impl BackupReplicationEnv {
    fn from_env() -> Self {
        Self {
            bucket: std::env::var_os("ATERMIUS_BACKUP_S3_BUCKET"),
            region: std::env::var_os("ATERMIUS_BACKUP_S3_REGION"),
            credentials_file: std::env::var_os("ATERMIUS_BACKUP_S3_CREDENTIALS_FILE"),
            endpoint_url: std::env::var_os("ATERMIUS_BACKUP_S3_ENDPOINT_URL"),
            prefix: std::env::var_os("ATERMIUS_BACKUP_S3_PREFIX"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct AuthRateLimits {
    pub window_seconds: i64,
    pub login_user_limit: i64,
    pub login_pair_limit: i64,
    pub login_ip_limit: i64,
    pub prelogin_user_limit: i64,
    pub prelogin_pair_limit: i64,
    pub prelogin_ip_limit: i64,
    pub register_user_limit: i64,
    pub register_pair_limit: i64,
    pub register_ip_limit: i64,
    pub recovery_start_user_limit: i64,
    pub recovery_start_pair_limit: i64,
    pub recovery_start_ip_limit: i64,
    pub recovery_complete_user_limit: i64,
    pub recovery_complete_pair_limit: i64,
    pub recovery_complete_ip_limit: i64,
    pub max_active_recovery_challenges: i64,
}

impl Default for AuthRateLimits {
    fn default() -> Self {
        Self {
            window_seconds: 900,
            login_user_limit: 12,
            login_pair_limit: 8,
            login_ip_limit: 3000,
            prelogin_user_limit: 30,
            prelogin_pair_limit: 20,
            prelogin_ip_limit: 6000,
            register_user_limit: 3,
            register_pair_limit: 3,
            register_ip_limit: 60,
            recovery_start_user_limit: 6,
            recovery_start_pair_limit: 5,
            recovery_start_ip_limit: 300,
            recovery_complete_user_limit: 5,
            recovery_complete_pair_limit: 4,
            recovery_complete_ip_limit: 120,
            max_active_recovery_challenges: DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP,
        }
    }
}

impl AuthRateLimits {
    fn from_env() -> Self {
        let defaults = Self::default();
        Self {
            window_seconds: bounded_env(
                "ATERMIUS_AUTH_RATE_WINDOW_SECONDS",
                defaults.window_seconds,
                60,
                86_400,
            ),
            login_user_limit: bounded_env(
                "ATERMIUS_AUTH_LOGIN_USER_LIMIT",
                defaults.login_user_limit,
                1,
                1000,
            ),
            login_pair_limit: bounded_env(
                "ATERMIUS_AUTH_LOGIN_PAIR_LIMIT",
                defaults.login_pair_limit,
                1,
                1000,
            ),
            login_ip_limit: bounded_env(
                "ATERMIUS_AUTH_LOGIN_IP_LIMIT",
                defaults.login_ip_limit,
                100,
                100_000,
            ),
            prelogin_user_limit: bounded_env(
                "ATERMIUS_AUTH_PRELOGIN_USER_LIMIT",
                defaults.prelogin_user_limit,
                1,
                1000,
            ),
            prelogin_pair_limit: bounded_env(
                "ATERMIUS_AUTH_PRELOGIN_PAIR_LIMIT",
                defaults.prelogin_pair_limit,
                1,
                1000,
            ),
            prelogin_ip_limit: bounded_env(
                "ATERMIUS_AUTH_PRELOGIN_IP_LIMIT",
                defaults.prelogin_ip_limit,
                100,
                100_000,
            ),
            register_user_limit: bounded_env(
                "ATERMIUS_AUTH_REGISTER_USER_LIMIT",
                defaults.register_user_limit,
                1,
                1000,
            ),
            register_pair_limit: bounded_env(
                "ATERMIUS_AUTH_REGISTER_PAIR_LIMIT",
                defaults.register_pair_limit,
                1,
                1000,
            ),
            register_ip_limit: bounded_env(
                "ATERMIUS_AUTH_REGISTER_IP_LIMIT",
                defaults.register_ip_limit,
                10,
                100_000,
            ),
            recovery_start_user_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_START_USER_LIMIT",
                defaults.recovery_start_user_limit,
                1,
                1000,
            ),
            recovery_start_pair_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_START_PAIR_LIMIT",
                defaults.recovery_start_pair_limit,
                1,
                1000,
            ),
            recovery_start_ip_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_START_IP_LIMIT",
                defaults.recovery_start_ip_limit,
                100,
                100_000,
            ),
            recovery_complete_user_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_COMPLETE_USER_LIMIT",
                defaults.recovery_complete_user_limit,
                1,
                1000,
            ),
            recovery_complete_pair_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_COMPLETE_PAIR_LIMIT",
                defaults.recovery_complete_pair_limit,
                1,
                1000,
            ),
            recovery_complete_ip_limit: bounded_env(
                "ATERMIUS_AUTH_RECOVERY_COMPLETE_IP_LIMIT",
                defaults.recovery_complete_ip_limit,
                100,
                100_000,
            ),
            max_active_recovery_challenges: bounded_env(
                "ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES",
                defaults.max_active_recovery_challenges,
                1,
                MAX_ACTIVE_RECOVERY_CHALLENGE_CAP,
            ),
        }
    }
}

fn bounded_env(name: &str, default: i64, minimum: i64, maximum: i64) -> i64 {
    bounded_value(std::env::var(name).ok(), default, minimum, maximum)
}

fn bounded_value(value: Option<String>, default: i64, minimum: i64, maximum: i64) -> i64 {
    value
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| (minimum..=maximum).contains(value))
        .unwrap_or(default)
}

fn parse_relay_allow_cidrs(value: Option<&str>) -> Vec<IpNet> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Vec::new();
    };
    let entries = value.split(',').collect::<Vec<_>>();
    if entries.len() > relay::MAX_RELAY_POLICY_CIDRS {
        return Vec::new();
    }
    let mut cidrs = Vec::with_capacity(entries.len());
    for entry in entries {
        let entry = entry.trim();
        if entry.is_empty() || entry.len() > relay::MAX_RELAY_POLICY_CIDR_LENGTH {
            return Vec::new();
        }
        let Ok(network) = entry.parse::<IpNet>() else {
            return Vec::new();
        };
        cidrs.push(network.trunc());
    }
    cidrs.sort_by_key(ToString::to_string);
    cidrs.dedup();
    cidrs
}

fn parse_relay_allow_ports(value: Option<&str>) -> Vec<u16> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Vec::new();
    };
    let entries = value.split(',').collect::<Vec<_>>();
    if entries.len() > relay::MAX_RELAY_POLICY_PORTS {
        return Vec::new();
    }
    let Ok(mut ports) = entries
        .into_iter()
        .map(|port| port.trim().parse::<u16>())
        .collect::<Result<Vec<_>, _>>()
    else {
        return Vec::new();
    };
    if ports.contains(&0) {
        return Vec::new();
    }
    ports.sort_unstable();
    ports.dedup();
    ports
}

pub(crate) const MAX_BACKUP_RETENTION_COUNT: usize = 1000;

fn parse_backup_retention_count(value: Option<&OsStr>) -> Result<Option<usize>, &'static str> {
    let Some(value) = value else {
        return Ok(None);
    };
    let value = value
        .to_str()
        .ok_or("ATERMIUS_BACKUP_RETENTION_COUNT must be a positive integer from 1 to 1000")?;
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err("ATERMIUS_BACKUP_RETENTION_COUNT must be a positive integer from 1 to 1000");
    }
    let count = value
        .parse::<usize>()
        .map_err(|_| "ATERMIUS_BACKUP_RETENTION_COUNT must be a positive integer from 1 to 1000")?;
    if !(1..=MAX_BACKUP_RETENTION_COUNT).contains(&count) {
        return Err("ATERMIUS_BACKUP_RETENTION_COUNT must be a positive integer from 1 to 1000");
    }
    Ok(Some(count))
}

impl Config {
    pub fn from_env() -> Self {
        let data_dir = std::env::var_os("ATERMIUS_DATA_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("./data"));
        let backup_archive_dir = std::env::var_os("ATERMIUS_BACKUP_ARCHIVE_DIR")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let backup_key_file = std::env::var_os("ATERMIUS_BACKUP_KEY_FILE")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let mfa_encryption_key_file = std::env::var_os("ATERMIUS_MFA_ENCRYPTION_KEY_FILE")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let database_key_file = std::env::var_os("ATERMIUS_DATABASE_KEY_FILE")
            .filter(|value| !value.is_empty())
            .map(PathBuf::from);
        let backup_retention_count = std::env::var_os("ATERMIUS_BACKUP_RETENTION_COUNT");
        let backup_replication_env = BackupReplicationEnv::from_env();
        let relay_allow_cidrs =
            parse_relay_allow_cidrs(std::env::var("ATERMIUS_RELAY_ALLOW_CIDRS").ok().as_deref());
        let relay_allow_ports =
            parse_relay_allow_ports(std::env::var("ATERMIUS_RELAY_ALLOW_PORTS").ok().as_deref());
        let history_retention_days = std::env::var("ATERMIUS_HISTORY_RETENTION_DAYS")
            .ok()
            .and_then(|value| value.parse::<i64>().ok())
            .filter(|days| (1..=3650).contains(days))
            .unwrap_or(90);
        let record_restore_retention_days =
            bounded_env("ATERMIUS_RECORD_RESTORE_RETENTION_DAYS", 30, 1, 3650);
        let vault_deletion_grace_seconds = bounded_env(
            "ATERMIUS_VAULT_DELETION_GRACE_SECONDS",
            7 * 24 * 60 * 60,
            60,
            90 * 24 * 60 * 60,
        );
        let account_deletion_grace_seconds = bounded_env(
            "ATERMIUS_ACCOUNT_DELETION_GRACE_SECONDS",
            7 * 24 * 60 * 60,
            60,
            90 * 24 * 60 * 60,
        );
        let audit_retention_days = bounded_env("ATERMIUS_AUDIT_RETENTION_DAYS", 365, 1, 3650);
        let object_gc_grace_seconds = bounded_env(
            "ATERMIUS_OBJECT_GC_GRACE_SECONDS",
            7 * 24 * 60 * 60,
            60,
            90 * 24 * 60 * 60,
        );
        let admin_usernames =
            parse_admin_usernames(std::env::var("ATERMIUS_ADMIN_USERNAMES").ok().as_deref());
        Self {
            data_dir,
            backup_archive_dir,
            backup_key_file,
            backup_replication_env,
            mfa_encryption_key_file,
            database_key_file,
            backup_retention_count,
            // Public signup stays disabled; an operator-issued one-time token is required.
            registration_open: false,
            guacd_address: std::env::var("ATERMIUS_GUACD_ADDRESS")
                .ok()
                .filter(|value| !value.trim().is_empty()),
            relay_enabled: std::env::var("ATERMIUS_RELAY_ENABLED").is_ok_and(|s| s == "true"),
            terminal_collaboration_enabled: std::env::var(
                "ATERMIUS_TERMINAL_COLLABORATION_ENABLED",
            )
            .is_ok_and(|s| s == "true"),
            relay_allow_cidrs,
            relay_allow_ports,
            relay_max_connections_per_user: 4,
            public_origin: std::env::var("ATERMIUS_PUBLIC_ORIGIN").ok(),
            web_dir: std::env::var_os("ATERMIUS_WEB_DIR").map(PathBuf::from),
            max_object_bytes: 64 * 1024 * 1024,
            max_request_bytes: 1024 * 1024,
            history_retention_days,
            record_restore_retention_days,
            vault_deletion_grace_seconds,
            account_deletion_grace_seconds,
            audit_retention_days,
            object_gc_grace_seconds,
            admin_usernames,
            auth_rate_limits: AuthRateLimits::from_env(),
        }
    }

    pub fn is_instance_admin(&self, username: &str) -> bool {
        self.admin_usernames
            .iter()
            .any(|configured| configured == username)
    }

    pub(crate) fn validated_backup_retention_count(&self) -> Result<Option<usize>, &'static str> {
        parse_backup_retention_count(self.backup_retention_count.as_deref())
    }
}

fn parse_admin_usernames(value: Option<&str>) -> Vec<String> {
    let Some(value) = value.map(str::trim).filter(|value| !value.is_empty()) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for username in value.split(',') {
        let Ok(normalized) = auth::normalized_username(username) else {
            // A malformed allowlist fails closed rather than activating a partial policy.
            return Vec::new();
        };
        if !result.contains(&normalized) {
            result.push(normalized);
        }
    }
    result
}

#[derive(Debug, Serialize)]
pub struct InstanceResponse {
    pub instance_id: String,
    pub server_space_id: String,
    pub generation: String,
    pub signing_public_key: String,
    pub signing_key_transitions: Vec<InstanceKeyTransition>,
    pub protocol_version: u32,
    pub setup_required: bool,
    pub restore_retention_days: i64,
    pub capabilities: Vec<&'static str>,
    /// Pre-login notice for the registration screen. Present only when the
    /// `credential_visibility` capability is advertised (SQLite runtime).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub credential_visibility_default: Option<&'static str>,
    pub limits: InstanceLimits,
}

#[derive(Debug, Serialize)]
pub struct InstanceLimits {
    pub max_object_bytes: i64,
    pub max_upload_chunk_bytes: usize,
    pub max_record_object_refs: usize,
}

pub async fn open_state(database_url: &str, config: Config) -> Result<AppState, ApiError> {
    let legacy_restore_retention_days = config.record_restore_retention_days;
    open_state_with_restore_policy(database_url, config, legacy_restore_retention_days).await
}

/// Opens a service database and freezes legacy delete deadlines using the
/// policy that was authoritative when the source database/archive was made.
/// Normal startup passes the current configured value; archive restore passes
/// the archived runtime policy instead.
pub(crate) async fn open_state_with_restore_policy(
    database_url: &str,
    config: Config,
    legacy_restore_retention_days: i64,
) -> Result<AppState, ApiError> {
    if !(1..=3650).contains(&legacy_restore_retention_days) {
        return Err(ApiError::internal(
            "legacy restore retention policy is outside the supported range",
        ));
    }
    let pg_sync_config = pg_sync_runtime::PgSyncRuntimeConfig::from_env()?;
    database::parse_sqlite_database_url(database_url)?;
    secure_file::create_private_data_dir(&config.data_dir)?;
    // A configured key must be valid before anything opens SQLite.
    let database_key = database::DatabaseKey::configured(&config)?;
    let options = database::main_sqlite_options(database_url, database_key.as_ref())?;
    // Detect the on-disk format before SQLite opens the file and before
    // migrations run, so a key/format mismatch never touches the file.
    database::reject_incomplete_encryption(options.get_filename())?;
    let database_encryption = database::startup_database_encryption(
        database::detect_database_file(options.get_filename())?,
        database_key.as_ref(),
    )?;
    // User attachment storage is opt-in and independent from the S3 archive
    // replica. Validate all static settings and credentials before opening the
    // service to requests.
    let object_store = object_store::ObjectStore::from_env(&config)?;
    let db = SqlitePoolOptions::new()
        .max_connections(8)
        .connect_with(
            options
                .create_if_missing(true)
                .foreign_keys(true)
                .journal_mode(SqliteJournalMode::Wal)
                .busy_timeout(std::time::Duration::from_secs(10)),
        )
        .await
        .map_err(|error| database::map_keyed_error(error, database_key.as_ref()))?;
    // Fail closed if this build cannot encrypt, and surface a wrong key as
    // DATABASE_KEY_INVALID before migrations run.
    database::require_cipher_support_pool(&db).await?;
    database::verify_keyed_pool(&db, database_key.as_ref()).await?;
    sqlx::migrate!("./migrations")
        .run(&db)
        .await
        .map_err(ApiError::internal)?;
    backfill_sqlite_restore_deadlines(&db, legacy_restore_retention_days).await?;
    relay::clear_legacy_relay_ticket_destinations(&db).await?;

    let (
        instance,
        signing_key,
        pg_sync_pool,
        pg_sync_auth,
        sync_repository,
        cursor_key,
        auth_rate_key,
    ) = if let Some(pg_config) = pg_sync_config {
        let pg_pool = pg_config
            .connect_with_restore_policy(legacy_restore_retention_days)
            .await?;
        let (instance, signing_key) = instance_identity::load_or_create_postgres(
            &pg_pool,
            &pg_config.instance_signing_key_file,
        )
        .await?;
        let runtime_keys = pg_runtime_keys::PgRuntimeKeys::load(
            &pg_config.auth_rate_limit_key_file,
            &signing_key,
        )?;
        let cursor_key = *runtime_keys.cursor_key();
        let auth_rate_key = *runtime_keys.auth_rate_key();
        let pg_auth = pg_sync_auth::PgSyncAuthRepository::new(pg_pool.clone());
        let repository = Arc::new(pg_sync_repository::PgSyncRepository::new(
            pg_pool.clone(),
            instance.clone(),
            Arc::new(signing_key.clone()),
        ));
        (
            instance,
            signing_key,
            Some(pg_pool),
            Some(pg_auth),
            repository as Arc<dyn sync_repository::SyncRepository>,
            cursor_key,
            auth_rate_key,
        )
    } else {
        let (instance, signing_key) =
            instance_identity::load_or_create(&db, &config.data_dir).await?;
        let auth_rate_key =
            secure_file::read_or_create_private_key(&config.data_dir.join("auth-rate-limit.key"))?;
        let mut cursor_key = [0_u8; 32];
        hkdf::Hkdf::<sha2::Sha256>::new(Some(b"atermius-instance"), signing_key.as_bytes())
            .expand(b"atermius/cursor-hmac/v1", &mut cursor_key)
            .map_err(ApiError::internal)?;
        (
            instance.clone(),
            signing_key.clone(),
            None,
            None,
            Arc::new(sync_repository::SqliteSyncRepository::new(
                db.clone(),
                instance.clone(),
                Arc::new(signing_key.clone()),
            )) as Arc<dyn sync_repository::SyncRepository>,
            cursor_key,
            auth_rate_key,
        )
    };
    object_store.validate_catalogue(&db).await?;
    let mfa_encryption_key = config
        .mfa_encryption_key_file
        .as_deref()
        .map(secure_file::read_private_key)
        .transpose()?
        .map(Arc::new);
    let pg_auth_rate_limits = pg_sync_pool.as_ref().map(|pool| {
        pg_rate_limit::PgAuthRateLimitRepository::new(
            pool.clone(),
            auth_rate_key,
            config.auth_rate_limits.clone(),
        )
    });
    let pg_auth_lifecycle = pg_sync_pool
        .as_ref()
        .map(|pool| pg_auth_lifecycle::PgAuthLifecycleRepository::new(pool.clone(), cursor_key));
    let pg_mfa = pg_sync_pool
        .as_ref()
        .map(|pool| pg_mfa::PgMfaRepository::new(pool.clone(), cursor_key));
    let vault_limits = VaultLimits::from_env();
    let pg_account_onboarding = pg_sync_pool.as_ref().map(|pool| {
        pg_account_onboarding::PgAccountOnboardingRepository::new(
            pool.clone(),
            cursor_key,
            instance.instance_id.clone(),
            config.audit_retention_days,
            vault_limits.max_vaults_per_user,
            vault_limits.max_members_per_vault,
        )
    });
    let pg_account_reads = pg_sync_pool
        .as_ref()
        .map(|pool| pg_account_reads::PgAccountReadsRepository::new(pool.clone()));
    let pg_vault_deletion = pg_sync_pool
        .as_ref()
        .map(|pool| pg_vault_deletion::PgVaultDeletionRepository::new(pool.clone()));
    let dummy_login_verifier_hash = auth::dummy_login_verifier_hash()?;
    let pg_account_deletion = pg_sync_pool.as_ref().map(|pool| {
        pg_account_deletion::PgAccountDeletionRepository::new(
            pool.clone(),
            cursor_key,
            auth_rate_key,
            dummy_login_verifier_hash.clone(),
        )
    });
    let pg_objects = pg_sync_pool.as_ref().map(|pool| {
        pg_objects::PgObjectRepository::new(pool.clone(), instance.instance_id.clone())
    });
    let pg_mobile_push = pg_sync_pool.as_ref().map(|pool| {
        pg_mobile_push::PgMobilePushRepository::new(pool.clone(), Arc::new(auth_rate_key))
    });
    if let Some(repository) = pg_objects.as_ref() {
        repository.validate_schema(&object_store).await?;
    }
    let pg_redaction_capabilities = pg_sync_pool
        .as_ref()
        .map(|pool| pg_redaction_capabilities::PgRedactionCapabilityRepository::new(pool.clone()));
    let cloud = cloud::CloudState::open(
        &db,
        &config,
        &signing_key,
        &instance.instance_id,
        pg_sync_pool.is_some(),
    )
    .await?;
    Ok(AppState {
        sync_repository,
        pg_sync_only: pg_sync_pool.is_some(),
        pg_sync_auth,
        pg_redaction_capabilities,
        pg_auth_lifecycle,
        pg_mfa,
        pg_account_onboarding,
        pg_account_reads,
        pg_vault_deletion,
        pg_account_deletion,
        pg_objects,
        pg_mobile_push,
        pg_auth_rate_limits,
        pg_sync_pool,
        pg_relay_node_id: Uuid::new_v4(),
        maintenance_repository: Arc::new(maintenance_repository::SqliteMaintenanceRepository::new(
            db.clone(),
        )),
        db,
        instance: Arc::new(instance),
        signing_key: Arc::new(signing_key),
        cursor_key: Arc::new(cursor_key),
        auth_rate_key: Arc::new(auth_rate_key),
        dummy_login_verifier_hash: Arc::new(dummy_login_verifier_hash),
        mfa_encryption_key,
        database_key: database_key.map(Arc::new),
        database_encryption,
        object_store,
        relay_connections: Arc::new(Mutex::new(HashMap::new())),
        relay_connection_slots: Arc::new(Semaphore::new(relay::MAX_GLOBAL_RELAY_CONNECTIONS)),
        // SQLite stores object payloads inline; serialize assembly to bound memory use.
        object_completion_slots: Arc::new(Semaphore::new(1)),
        notification_connections: Arc::new(Mutex::new(HashMap::new())),
        notification_connection_slots: Arc::new(Semaphore::new(
            notifications::MAX_GLOBAL_CONNECTIONS,
        )),
        notification_query_slots: Arc::new(Semaphore::new(notifications::MAX_GLOBAL_POLL_QUERIES)),
        pg_notification_hub: pg_notifications::PgNotificationHub::default(),
        collaboration: collaboration::CollaborationState::default(),
        cloud: Arc::new(cloud),
        maintenance_lock: Arc::new(tokio::sync::Mutex::new(())),
        vault_limits,
        config: Arc::new(config),
    })
}

async fn backfill_sqlite_restore_deadlines(
    db: &SqlitePool,
    retention_days: i64,
) -> Result<(), ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::internal)?;
    loop {
        // Use bounded batches so an old database with a long delete history
        // does not require copying every tombstone into memory at startup.
        let rows = sqlx::query(
            "SELECT rowid,created_at FROM record_versions \
             WHERE operation='delete' AND restore_until IS NULL \
             ORDER BY rowid LIMIT 256",
        )
        .fetch_all(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
        if rows.is_empty() {
            break;
        }
        for row in rows {
            let row_id: i64 = row.try_get("rowid").map_err(ApiError::internal)?;
            let created_at: String = row.try_get("created_at").map_err(ApiError::internal)?;
            let deleted_at = chrono::DateTime::parse_from_rfc3339(&created_at)
                .map_err(ApiError::internal)?
                .with_timezone(&chrono::Utc);
            let restore_until = (deleted_at + chrono::Duration::days(retention_days)).to_rfc3339();
            sqlx::query(
                "UPDATE record_versions SET restore_until=? \
                 WHERE rowid=? AND operation='delete' AND restore_until IS NULL",
            )
            .bind(restore_until)
            .bind(row_id)
            .execute(&mut *tx)
            .await
            .map_err(ApiError::internal)?;
        }
    }
    tx.commit().await.map_err(ApiError::internal)
}

/// Creates a fresh single-use bootstrap secret. Only the CLI prints this value.
pub async fn create_bootstrap_token(state: &AppState) -> Result<String, ApiError> {
    if let Some(repository) = state.pg_account_onboarding.as_ref() {
        return repository.create_bootstrap_token().await;
    }
    let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&state.db)
        .await
        .map_err(ApiError::internal)?;
    let consumed: Option<String> =
        sqlx::query_scalar("SELECT setup_consumed_at FROM instance_meta WHERE id=1")
            .fetch_one(&state.db)
            .await
            .map_err(ApiError::internal)?;
    if users > 0 || consumed.is_some() {
        return Err(ApiError::conflict(
            "SETUP_CLOSED",
            "initial setup has already been completed",
        ));
    }
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    let token = URL_SAFE_NO_PAD.encode(raw);
    let hash = hex::encode(sha2::Sha256::digest(token.as_bytes()));
    sqlx::query("UPDATE instance_meta SET bootstrap_token_hash=? WHERE id=1")
        .bind(hash)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    Ok(token)
}

/// Changes the persisted rollback generation after restoring an older backup.
/// The caller must stop the server first; this is an offline operator action.
pub async fn recover_server_generation(state: &AppState) -> Result<String, ApiError> {
    let _runtime_lock = acquire_runtime_lock(&state.config.data_dir)?;
    let generation = Uuid::new_v4().to_string();
    let updated = sqlx::query("UPDATE instance_meta SET generation=? WHERE id=1")
        .bind(&generation)
        .execute(&state.db)
        .await
        .map_err(ApiError::internal)?;
    if updated.rows_affected() != 1 {
        return Err(ApiError::internal("instance metadata row is missing"));
    }
    Ok(generation)
}

pub(crate) fn acquire_runtime_lock(data_dir: &std::path::Path) -> Result<File, ApiError> {
    let path = data_dir.join("server.lock");
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options.open(path).map_err(ApiError::internal)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(ApiError::internal)?;
    }
    file.try_lock().map_err(|_| {
        ApiError::conflict(
            "SERVER_RUNNING",
            "the server data directory is locked by a running server process",
        )
    })?;
    Ok(file)
}

pub(crate) fn acquire_maintenance_run_lock(data_dir: &std::path::Path) -> Result<File, ApiError> {
    secure_file::secure_existing_data_dir(data_dir)?;
    let path = data_dir.join("maintenance.lock");
    let mut options = OpenOptions::new();
    options.create(true).truncate(false).read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let file = options.open(path).map_err(ApiError::internal)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))
            .map_err(ApiError::internal)?;
    }
    file.try_lock().map_err(|_| {
        ApiError::conflict(
            "MAINTENANCE_ALREADY_RUNNING",
            "maintenance is already running",
        )
    })?;
    Ok(file)
}

/// Acquires the process-local and interprocess exclusion shared by retention
/// maintenance and instance backups. This lock is intentionally held over the
/// complete operation, including sidecar persistence.
#[allow(dead_code)] // The identity fields are consumed by the dormant purge service entry.
pub(crate) struct InstanceMaintenanceGuard<'a> {
    _mutex_guard: tokio::sync::MutexGuard<'a, ()>,
    maintenance_lock: Arc<tokio::sync::Mutex<()>>,
    data_dir: PathBuf,
    _process_guard: File,
}

impl InstanceMaintenanceGuard<'_> {
    #[allow(dead_code)] // No production caller is wired before persistent purge opt-in exists.
    pub(crate) fn belongs_to(&self, state: &AppState) -> bool {
        Arc::ptr_eq(&self.maintenance_lock, &state.maintenance_lock)
            && self.data_dir == state.config.data_dir
    }
}

pub(crate) async fn acquire_instance_maintenance_lock(
    state: &AppState,
) -> Result<InstanceMaintenanceGuard<'_>, ApiError> {
    let mutex_guard = state.maintenance_lock.lock().await;
    let process_guard = acquire_maintenance_run_lock(&state.config.data_dir)?;
    Ok(InstanceMaintenanceGuard {
        _mutex_guard: mutex_guard,
        maintenance_lock: Arc::clone(&state.maintenance_lock),
        data_dir: state.config.data_dir.clone(),
        _process_guard: process_guard,
    })
}

/// The offline backup CLI and the online admin job use the same interprocess
/// lock as maintenance so they cannot snapshot while another fixed operation
/// is running.
pub async fn run_operator_backup(
    config: &Config,
    database_url: &str,
    archive_path: &std::path::Path,
    backup_key_path: &std::path::Path,
) -> Result<BackupSummary, ApiError> {
    let _process_guard = acquire_maintenance_run_lock(&config.data_dir)?;
    let result = backup_instance(config, database_url, archive_path, backup_key_path).await;
    match result {
        Ok(summary) => {
            record_backup_success(
                &config.data_dir,
                summary.migration_version,
                summary.archive_bytes,
            )?;
            Ok(summary)
        }
        Err(error) => {
            record_backup_failure(&config.data_dir)?;
            Err(error)
        }
    }
}

/// Runs the bounded retention and opted-in tombstone purge pass used by the
/// hourly and administrator Maintenance paths. Exposed to the local operator
/// CLI and tests.
pub async fn run_maintenance(state: &AppState) -> Result<(), ApiError> {
    if let Some(pool) = state.pg_sync_pool.as_ref() {
        let rate_limits = state
            .pg_auth_rate_limits
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL auth rate limits are unavailable"))?;
        // Retention can run beside service nodes, but it must hold the same
        // shared database lock as a node so an offline exclusive operation
        // (such as MFA key rotation) cannot start in the middle of the pass.
        let runtime_lock = pg_sync_runtime::acquire_server_lifetime_lock(pool).await?;
        let result = async {
            pg_maintenance::PgMaintenanceRepository::new(pool.clone())
                .run_one_pass(state.config.history_retention_days, rate_limits)
                .await?;

            let signer = pg_record_redaction::PgRedactionProofSigner::new(
                (*state.instance).clone(),
                state.signing_key.clone(),
            );
            let purge = pg_record_purge::PgRecordPurgeRepository::new(pool.clone(), signer);
            pg_record_auto_purge_scan::PgRecordAutoPurgeScanRepository::new(pool.clone(), purge)
                .scan_batch(32, 4, 300, state.config.object_gc_grace_seconds)
                .await?;
            Ok(())
        }
        .await;
        let release_result = runtime_lock.release().await;
        return match result {
            Err(error) => {
                let _ = release_result;
                Err(error)
            }
            Ok(()) => release_result,
        };
    }
    let _guard = acquire_instance_maintenance_lock(state).await?;
    let retention_count = state
        .config
        .validated_backup_retention_count()
        .map_err(ApiError::internal)?;
    if retention_count.is_some() {
        backup::validate_backup_retention_configuration(&state.config)?;
    }
    recovery::prune_challenges(
        state,
        chrono::Utc::now().timestamp(),
        recovery::RECOVERY_CHALLENGE_PRUNE_BATCHES_PER_MAINTENANCE,
    )
    .await?;
    auth::prune_account_invitations(
        state,
        chrono::Utc::now().timestamp(),
        auth::ACCOUNT_INVITATION_PRUNE_BATCHES_PER_MAINTENANCE,
    )
    .await?;
    sync::compact_expired_history(state).await?;
    if let Some(retention_count) = retention_count {
        backup::prune_configured_admin_backups(state, retention_count).await?;
    }
    sqlite_auto_purge_scan::run_record_auto_purge_scan_sqlite(
        state,
        &_guard,
        sqlite_auto_purge_scan::RecordAutoPurgeScanLimits::default(),
    )
    .await?;
    Ok(())
}

pub async fn router(state: AppState) -> Router {
    let mut app = Router::new()
        .route("/health/live", get(health_live))
        .route("/health/ready", get(health_ready))
        .route("/api/v1/instance", get(instance_info))
        .route("/api/v1/openapi.yaml", get(openapi))
        .route("/api/v1/auth/prelogin", post(auth::prelogin))
        .route("/api/v1/auth/register", post(auth::register))
        .route("/api/v1/auth/login", post(auth::login))
        .route("/api/v1/auth/login/mfa", post(mfa::login))
        .route("/api/v1/auth/mfa", get(mfa::status))
        .route("/api/v1/auth/mfa/totp/setup", post(mfa::setup_totp))
        .route("/api/v1/auth/mfa/totp/confirm", post(mfa::confirm_totp))
        .route(
            "/api/v1/auth/mfa/recovery-codes",
            post(mfa::rotate_recovery_codes),
        )
        .route("/api/v1/auth/mfa/totp", delete(mfa::disable_totp))
        .route("/api/v1/auth/password-change", post(auth::change_password))
        .route(
            "/api/v1/auth/recovery",
            put(recovery::configure).delete(recovery::disable),
        )
        .route("/api/v1/auth/recovery/contexts", get(recovery::contexts))
        .route(
            "/api/v1/auth/recovery/key-envelopes",
            put(recovery::upload_key_envelopes),
        )
        .route("/api/v1/auth/recovery/start", post(recovery::start))
        .route("/api/v1/auth/recovery/inspect", post(recovery::inspect))
        .route("/api/v1/auth/recovery/complete", post(recovery::complete))
        .route("/api/v1/auth/refresh", post(auth::refresh))
        .route("/api/v1/auth/logout", post(auth::logout))
        .route("/api/v1/account/delete", post(account::delete_account))
        .route(
            "/api/v1/account/delete/cancel",
            post(account::cancel_account_deletion),
        )
        .route("/api/v1/me", get(auth::me))
        .route("/api/v1/admin/overview", get(admin::overview))
        .route("/api/v1/admin/push-health", get(admin::push_health))
        .route("/api/v1/admin/metrics", get(admin::metrics))
        .route(
            "/api/v1/admin/metrics-credential",
            get(admin::metrics_credential_status)
                .post(admin::rotate_metrics_credential)
                .delete(admin::revoke_metrics_credential),
        )
        .route("/api/v1/admin/backup-status", get(admin::backup_status))
        .route(
            "/api/v1/admin/backup-replication",
            get(admin::backup_replication_status),
        )
        .route(
            "/api/v1/admin/backup-replication/preflight",
            post(admin::backup_replication_preflight),
        )
        .route(
            "/api/v1/admin/backup-schedule",
            get(admin::get_backup_schedule).put(admin::update_backup_schedule),
        )
        .route(
            "/api/v1/admin/restore-sources",
            get(admin::list_restore_sources),
        )
        .route(
            "/api/v1/admin/restore-stages/{restore_job_id}/discard",
            post(admin::discard_restore_stage),
        )
        .route(
            "/api/v1/admin/jobs",
            get(admin::list_jobs).post(admin::create_job),
        )
        .route("/api/v1/admin/audit", get(audit::list_instance_admin_audit))
        .route("/api/v1/admin/accounts", get(admin::list_accounts))
        .route(
            "/api/v1/admin/account-invitations",
            get(admin::list_account_invitations).post(admin::create_account_invitation),
        )
        .route(
            "/api/v1/admin/account-invitations/{invitation_id}/revoke",
            post(admin::revoke_account_invitation),
        )
        .route(
            "/api/v1/admin/accounts/{user_id}/status",
            put(admin::update_account_status),
        )
        .route(
            "/api/v1/admin/accounts/{user_id}/sessions",
            get(admin::list_account_sessions),
        )
        .route(
            "/api/v1/admin/accounts/{user_id}/sessions/revoke",
            post(admin::revoke_account_sessions),
        )
        .route(
            "/api/v1/admin/accounts/{user_id}/sessions/{session_id}/revoke",
            post(admin::revoke_account_session),
        )
        .route("/api/v1/admin/vaults", get(admin::list_vaults))
        .route(
            "/api/v1/admin/vaults/{vault_id}/quota",
            put(admin::update_vault_quota),
        )
        .route(
            "/api/v1/devices",
            get(auth::list_devices).post(auth::register_device),
        )
        .route(
            "/api/v1/devices/capabilities",
            put(device_capabilities::put_device_capability_report),
        )
        .route(
            "/api/v1/devices/redaction-capabilities",
            put(redaction_capabilities::put_device_redaction_capability_report),
        )
        .route("/api/v1/devices/{id}/revoke", post(auth::revoke_device))
        .route(
            "/api/v1/vaults",
            get(control::list_vaults).post(control::create_vault),
        )
        .route(
            "/api/v1/vaults/{vault_id}/members",
            get(control::list_members),
        )
        .route(
            "/api/v1/vaults/{vault_id}/presence",
            get(presence::list).post(presence::heartbeat),
        )
        .route(
            "/api/v1/vaults/{vault_id}/terminal-sessions",
            post(collaboration::create_session),
        )
        .route(
            "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/ticket",
            post(collaboration::issue_observer_ticket),
        )
        .route(
            "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease",
            post(collaboration::grant_controller_lease)
                .delete(collaboration::revoke_controller_lease),
        )
        .route(
            "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease/ticket",
            post(collaboration::issue_controller_ticket),
        )
        .route(
            "/api/v1/vaults/{vault_id}/terminal-sessions/{session_id}",
            delete(collaboration::stop_session),
        )
        .route(
            "/api/v1/vaults/{vault_id}/devices",
            get(control::vault_devices),
        )
        .route(
            "/api/v1/vaults/{vault_id}/invitations",
            post(control::create_invitation),
        )
        .route(
            "/api/v1/invitations/accept",
            post(control::accept_invitation),
        )
        .route(
            "/api/v1/vaults/{vault_id}/membership",
            get(control::membership),
        )
        .route(
            "/api/v1/vaults/{vault_id}/keys/rotate",
            post(control::rotate_key),
        )
        .route(
            "/api/v1/vaults/{vault_id}/ownership/transfer",
            post(control::transfer_ownership),
        )
        .route("/api/v1/vaults/{vault_id}", delete(control::delete_vault))
        .route(
            "/api/v1/vaults/{vault_id}/deletion/cancel",
            post(control::cancel_vault_deletion),
        )
        .route("/api/v1/vaults/{vault_id}/sync/push", post(sync::push))
        .route(
            "/api/v1/vaults/{vault_id}/records/{record_id}/purge",
            post(sync::purge_record),
        )
        .route(
            "/api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge",
            put(sync::update_automatic_purge_policy),
        )
        .route(
            "/api/v1/vaults/{vault_id}/changes",
            get(sync::changes)
                .route_layer(axum::middleware::from_fn(sync::guard_sync_query_length)),
        )
        .route(
            "/api/v1/vaults/{vault_id}/snapshots",
            post(sync::create_snapshot),
        )
        .route(
            "/api/v1/snapshots/{snapshot_id}",
            get(sync::get_snapshot)
                .route_layer(axum::middleware::from_fn(sync::guard_sync_query_length)),
        )
        .route(
            "/api/v1/vaults/{vault_id}/revisions/{revision_id}",
            get(sync::get_revision),
        )
        .route(
            "/api/v1/vaults/{vault_id}/revisions",
            get(sync::revision_history)
                .route_layer(axum::middleware::from_fn(sync::guard_sync_query_length)),
        )
        .route(
            "/api/v1/vaults/{vault_id}/conflicts",
            get(sync::conflict_history)
                .route_layer(axum::middleware::from_fn(sync::guard_sync_query_length))
                .post(sync::create_conflict),
        )
        .route(
            "/api/v1/vaults/{vault_id}/conflict-changes",
            get(sync::conflict_changes)
                .route_layer(axum::middleware::from_fn(sync::guard_sync_query_length)),
        )
        .route(
            "/api/v1/vaults/{vault_id}/conflicts/{conflict_id}/resolve",
            post(sync::resolve_conflict),
        )
        .route(
            "/api/v1/vaults/{vault_id}/uploads/init",
            post(objects::init_upload),
        )
        .route(
            "/api/v1/uploads/{upload_id}/chunks/{index}",
            put(objects::put_chunk),
        )
        .route(
            "/api/v1/uploads/{upload_id}/complete",
            post(objects::complete_upload),
        )
        .route(
            "/api/v1/vaults/{vault_id}/objects/{object_id}",
            get(objects::get_object),
        )
        .route("/relay/v1/connect", get(relay::connect))
        .route("/desktop/v1/connect", get(relay::connect_desktop))
        .route(
            "/api/v1/notifications/tickets",
            post(notifications::create_ticket),
        )
        .route(
            "/api/v1/notifications/push-endpoints/{device_id}",
            put(mobile_push::register_endpoint),
        )
        .route(
            "/api/v1/notifications/push-endpoints/{device_id}/{provider}",
            delete(mobile_push::delete_endpoint),
        )
        .route("/api/v1/notifications", get(notifications::connect))
        .route("/collaboration/v1/connect", get(collaboration::connect))
        .route("/api/v1/audit", get(audit::list_audit))
        .fallback(spa_fallback);
    if state.pg_sync_only {
        app = app
            .route(
                "/api/v1/admin/relay-policy",
                get(pg_relay::get_admin_policy).put(pg_relay::update_admin_policy),
            )
            .route(
                "/api/v1/admin/relay-policy/users/{user_id}",
                get(pg_relay::get_admin_user_policy)
                    .put(pg_relay::update_admin_user_policy)
                    .delete(pg_relay::reset_admin_user_policy),
            )
            .route(
                "/api/v1/admin/relay-groups",
                get(pg_relay::list_groups).post(pg_relay::create_group),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}",
                get(pg_relay::get_group)
                    .put(pg_relay::rename_group)
                    .delete(pg_relay::delete_group),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}/members",
                put(pg_relay::replace_group_members),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}/relay-policy",
                get(pg_relay::get_group_policy)
                    .put(pg_relay::update_group_policy)
                    .delete(pg_relay::reset_group_policy),
            )
            .route("/api/v1/relay/tickets", post(relay::create_ticket));
    } else {
        app = cloud_routes(app);
        app = credential_visibility::routes(app);
        app = app
            .route(
                "/api/v1/admin/relay-policy",
                get(relay::get_admin_policy).put(relay::update_admin_policy),
            )
            .route(
                "/api/v1/admin/relay-policy/users/{user_id}",
                get(relay::get_admin_user_policy)
                    .put(relay::update_admin_user_policy)
                    .delete(relay::reset_admin_user_policy),
            )
            .route(
                "/api/v1/admin/relay-groups",
                get(relay_groups::list).post(relay_groups::create),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}",
                get(relay_groups::get)
                    .put(relay_groups::rename)
                    .delete(relay_groups::delete),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}/members",
                put(relay_groups::replace_members),
            )
            .route(
                "/api/v1/admin/relay-groups/{group_id}/relay-policy",
                get(relay_groups::get_policy)
                    .put(relay_groups::update_policy)
                    .delete(relay_groups::reset_policy),
            )
            .route("/api/v1/relay/tickets", post(relay::create_ticket));
    }
    let mut app = app.with_state::<()>(state.clone());
    app = app.layer(RequestBodyLimitLayer::new(state.config.max_request_bytes));
    app = app.layer(middleware::from_fn_with_state(
        state.clone(),
        guard_pg_sync_scope,
    ));
    // Browser clients may use a separately hosted Web origin. Keep CORS
    // restricted to the configured exact origin and explicitly allow the
    // authenticated capability marker plus bounded object/range headers.
    if let Some(cors) = api_cors_layer(state.config.public_origin.as_deref()) {
        app = app.layer(cors);
    }
    app.layer(
        TraceLayer::new_for_http()
            .make_span_with(make_http_request_span)
            .on_failure(|_failure, latency: Duration, span: &tracing::Span| {
                // Do not emit tower-http's formatted error: transport and
                // downstream errors may contain caller-controlled details.
                tracing::error!(
                    parent: span,
                    latency_ms = latency.as_millis() as u64,
                    error_category = "transport_or_server",
                    "HTTP request failed"
                );
            }),
    )
    .layer(middleware::from_fn(apply_response_security_headers))
    .layer(middleware::from_fn(request_id_context))
}

/// Cloud collaboration routes. Registered only for the SQLite runtime; in the
/// PostgreSQL sync-core runtime they do not exist (and the scope guard keeps
/// returning PG_SYNC_SCOPE_LIMITED), so no partial sharing path is exposed.
fn cloud_routes(app: Router<AppState>) -> Router<AppState> {
    let guest_body_limit = RequestBodyLimitLayer::new(16 * 1024);
    app.route("/api/v1/share-gateway/keys", get(share_gateway::keys))
        .route(
            "/api/v1/vaults/{vault_id}/share-capsules",
            get(share_gateway::list_capsules),
        )
        .route(
            "/api/v1/vaults/{vault_id}/hosts/{host_id}/gateway-capsule",
            put(share_gateway::put_capsule).delete(share_gateway::delete_capsule),
        )
        .route("/api/v1/share-links", get(share_links::list_my_links))
        .route(
            "/api/v1/share-slugs/{slug}/availability",
            get(share_links::slug_availability),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links",
            get(share_links::list_links).post(share_links::create_link),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links/{link_id}",
            get(share_links::get_link).put(share_links::update_link),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links/{link_id}/revoke",
            post(share_links::revoke_link),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links/{link_id}/rotate-secret",
            post(share_links::rotate_secret),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links/{link_id}/activity",
            get(share_links::activity),
        )
        .route(
            "/api/v1/vaults/{vault_id}/share-links/{link_id}/guest-sessions/{guest_session_id}/terminate",
            post(share_links::terminate_guest_session),
        )
        .route(
            "/api/v1/vaults/{vault_id}/cloud-audit",
            get(share_links::vault_audit),
        )
        .route(
            "/api/v1/guest/redeem",
            post(share_guest::redeem).route_layer(guest_body_limit.clone()),
        )
        .route("/api/v1/guest/session", get(share_guest::session))
        .route(
            "/api/v1/guest/logout",
            post(share_guest::logout).route_layer(guest_body_limit.clone()),
        )
        .route(
            "/api/v1/guest/connections",
            post(share_guest::create_connection).route_layer(guest_body_limit),
        )
        .route("/gateway/v1/connect", get(share_guest::connect))
        .merge(cloud_orgs::routes())
}

async fn guard_pg_sync_scope(
    axum::extract::State(state): axum::extract::State<AppState>,
    request: Request,
    next: Next,
) -> Response {
    if !state.pg_sync_only || pg_sync_route_is_supported(request.method(), request.uri().path()) {
        return next.run(request).await;
    }
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "PG_SYNC_SCOPE_LIMITED",
        "this PostgreSQL sync-core runtime does not provide this API operation",
    )
    .into_response()
}

fn pg_sync_route_is_supported(method: &Method, path: &str) -> bool {
    if pg_web_fallback_request_is_supported(method, path) {
        return true;
    }
    // Relay is enabled in PG only through its shared policy/ticket/session
    // repository. Match the raw paths and methods exactly so adjacent routes
    // and malformed separators remain closed.
    if path == "/api/v1/relay/tickets" {
        return method == Method::POST;
    }
    if path == "/api/v1/devices/redaction-capabilities" {
        return method == Method::PUT;
    }
    if path == "/relay/v1/connect" || path == "/desktop/v1/connect" {
        return method == Method::GET;
    }
    if path == "/api/v1/admin/relay-policy" {
        return method == Method::GET || method == Method::PUT;
    }
    if path == "/api/v1/admin/metrics" {
        return method == Method::GET;
    }
    if path == "/api/v1/admin/metrics-credential" {
        return method == Method::GET || method == Method::POST || method == Method::DELETE;
    }
    if path == "/api/v1/admin/backup-replication" {
        return method == Method::GET;
    }
    if path == "/api/v1/admin/backup-replication/preflight" {
        return method == Method::POST;
    }
    if path == "/api/v1/admin/relay-groups" {
        return method == Method::GET || method == Method::POST;
    }
    const RELAY_USER_POLICY_PREFIX: &str = "/api/v1/admin/relay-policy/users/";
    if let Some(suffix) = path.strip_prefix(RELAY_USER_POLICY_PREFIX) {
        return match (method, suffix.split('/').collect::<Vec<_>>().as_slice()) {
            (&Method::GET | &Method::PUT | &Method::DELETE, [user_id]) => !user_id.is_empty(),
            _ => false,
        };
    }
    const RELAY_GROUP_PREFIX: &str = "/api/v1/admin/relay-groups/";
    if let Some(suffix) = path.strip_prefix(RELAY_GROUP_PREFIX) {
        return match (method, suffix.split('/').collect::<Vec<_>>().as_slice()) {
            (&Method::GET | &Method::PUT | &Method::DELETE, [group_id]) => !group_id.is_empty(),
            (&Method::PUT, [group_id, "members"]) => !group_id.is_empty(),
            (&Method::GET | &Method::PUT | &Method::DELETE, [group_id, "relay-policy"]) => {
                !group_id.is_empty()
            }
            _ => false,
        };
    }
    // Notification tickets and WebSockets have shared PG implementations;
    // keep these exact paths explicit so adjacent API paths stay fail-closed.
    if path == "/api/v1/notifications/tickets" {
        return method == Method::POST;
    }
    if path == "/api/v1/notifications" {
        return method == Method::GET;
    }
    // Keep these parameterized routes exact in the raw URI path. The generic
    // segment matcher below filters empty segments for several older routes;
    // doing that here would also admit duplicate separators and trailing `/`.
    const PUSH_ENDPOINT_PREFIX: &str = "/api/v1/notifications/push-endpoints/";
    if let Some(suffix) = path.strip_prefix(PUSH_ENDPOINT_PREFIX) {
        let endpoint_segments: Vec<_> = suffix.split('/').collect();
        return match (method, endpoint_segments.as_slice()) {
            (&Method::PUT, [device_id]) => !device_id.is_empty(),
            (&Method::DELETE, [device_id, provider]) => {
                !device_id.is_empty() && !provider.is_empty()
            }
            _ => false,
        };
    }
    const VAULT_PRESENCE_PREFIX: &str = "/api/v1/vaults/";
    if path.ends_with("/presence")
        && let Some(suffix) = path.strip_prefix(VAULT_PRESENCE_PREFIX)
    {
        let endpoint_segments: Vec<_> = suffix.split('/').collect();
        return match (method, endpoint_segments.as_slice()) {
            (&Method::GET | &Method::POST, [vault_id, "presence"]) => !vault_id.is_empty(),
            _ => false,
        };
    }
    // Record purge and its per-tombstone consent are admitted only on their
    // exact PostgreSQL-backed routes. Keep raw path validation here rather than in
    // the generic segment matcher below, which intentionally normalizes
    // empty path segments for older routes.
    const RECORD_PURGE_PREFIX: &str = "/api/v1/vaults/";
    if let Some(suffix) = path.strip_prefix(RECORD_PURGE_PREFIX)
        && suffix
            .split('/')
            .any(|segment| segment == "purge" || segment == "automatic-purge")
    {
        return matches!(
            (method, suffix.split('/').collect::<Vec<_>>().as_slice()),
            (&Method::POST, [vault_id, "records", record_id, "purge"])
                | (&Method::PUT, [vault_id, "records", record_id, "automatic-purge"])
                if !vault_id.is_empty() && !record_id.is_empty()
        );
    }
    let segments: Vec<_> = path
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect();
    if segments.as_slice() == ["api", "v1", "audit"] {
        return method == Method::GET && path == "/api/v1/audit";
    }
    if segments.as_slice() == ["api", "v1", "admin", "audit"] {
        return method == Method::GET && path == "/api/v1/admin/audit";
    }
    if segments.as_slice() == ["api", "v1", "admin", "overview"] {
        return method == Method::GET && path == "/api/v1/admin/overview";
    }
    if segments.as_slice() == ["api", "v1", "admin", "push-health"] {
        return method == Method::GET && path == "/api/v1/admin/push-health";
    }
    if segments.as_slice() == ["api", "v1", "admin", "accounts"] {
        return method == Method::GET && path == "/api/v1/admin/accounts";
    }
    const ADMIN_VAULTS_PATH: &str = "/api/v1/admin/vaults";
    if path == ADMIN_VAULTS_PATH {
        return method == Method::GET;
    }
    if let Some(suffix) = path.strip_prefix("/api/v1/admin/vaults/") {
        let vault_segments: Vec<_> = suffix.split('/').collect();
        return matches!((method, vault_segments.as_slice()),
            (&Method::PUT, [vault_id, "quota"]) if !vault_id.is_empty()
        );
    }
    const ADMIN_INVITATIONS_PATH: &str = "/api/v1/admin/account-invitations";
    if path == ADMIN_INVITATIONS_PATH {
        return method == Method::GET || method == Method::POST;
    }
    if let Some(suffix) = path.strip_prefix("/api/v1/admin/account-invitations/") {
        let invitation_segments: Vec<_> = suffix.split('/').collect();
        return matches!((method, invitation_segments.as_slice()),
            (&Method::POST, [invitation_id, "revoke"]) if !invitation_id.is_empty()
        );
    }
    const ADMIN_ACCOUNTS_PREFIX: &str = "/api/v1/admin/accounts/";
    if let Some(suffix) = path.strip_prefix(ADMIN_ACCOUNTS_PREFIX) {
        let account_segments: Vec<_> = suffix.split('/').collect();
        return match (method, account_segments.as_slice()) {
            (&Method::GET, [user_id, "sessions"])
            | (&Method::PUT, [user_id, "status"])
            | (&Method::POST, [user_id, "sessions", "revoke"]) => !user_id.is_empty(),
            (&Method::POST, [user_id, "sessions", session_id, "revoke"]) => {
                !user_id.is_empty() && !session_id.is_empty()
            }
            _ => false,
        };
    }
    if segments.as_slice() == ["api", "v1", "admin", "jobs"] {
        return path == "/api/v1/admin/jobs" && (method == Method::GET || method == Method::POST);
    }
    const ADMIN_RESTORE_STAGE_PREFIX: &str = "/api/v1/admin/restore-stages/";
    if let Some(suffix) = path.strip_prefix(ADMIN_RESTORE_STAGE_PREFIX) {
        return matches!((method, suffix.split('/').collect::<Vec<_>>().as_slice()),
            (&Method::POST, [job_id, "discard"]) if is_canonical_uuid(job_id)
        );
    }
    if segments.as_slice() == ["api", "v1", "admin", "restore-sources"] {
        return path == "/api/v1/admin/restore-sources" && method == Method::GET;
    }
    if segments.as_slice() == ["api", "v1", "admin", "backup-status"] {
        return path == "/api/v1/admin/backup-status" && method == Method::GET;
    }
    if segments.as_slice() == ["api", "v1", "admin", "backup-schedule"] {
        return path == "/api/v1/admin/backup-schedule"
            && (method == Method::GET || method == Method::PUT);
    }
    match (method, segments.as_slice()) {
        (&Method::GET, ["health", "live" | "ready"])
        | (&Method::GET, ["api", "v1", "instance"])
        | (&Method::POST, ["api", "v1", "auth", "prelogin"])
        | (&Method::POST, ["api", "v1", "auth", "register"])
        | (&Method::POST, ["api", "v1", "auth", "login"])
        | (&Method::POST, ["api", "v1", "auth", "login", "mfa"])
        | (&Method::GET, ["api", "v1", "auth", "mfa"])
        | (&Method::POST, ["api", "v1", "auth", "mfa", "totp", "setup"])
        | (&Method::POST, ["api", "v1", "auth", "mfa", "totp", "confirm"])
        | (&Method::POST, ["api", "v1", "auth", "mfa", "recovery-codes"])
        | (&Method::DELETE, ["api", "v1", "auth", "mfa", "totp"])
        | (&Method::POST, ["api", "v1", "auth", "password-change"])
        | (&Method::POST, ["api", "v1", "auth", "refresh"])
        | (&Method::POST, ["api", "v1", "auth", "logout"])
        | (&Method::GET, ["api", "v1", "audit"])
        | (&Method::PUT, ["api", "v1", "auth", "recovery"])
        | (&Method::DELETE, ["api", "v1", "auth", "recovery"])
        | (&Method::GET, ["api", "v1", "auth", "recovery", "contexts"])
        | (&Method::PUT, ["api", "v1", "auth", "recovery", "key-envelopes"])
        | (&Method::POST, ["api", "v1", "auth", "recovery", "start"])
        | (&Method::POST, ["api", "v1", "auth", "recovery", "inspect"])
        | (&Method::POST, ["api", "v1", "auth", "recovery", "complete"])
        | (&Method::POST, ["api", "v1", "account", "delete"])
        | (&Method::POST, ["api", "v1", "account", "delete", "cancel"])
        | (&Method::GET, ["api", "v1", "me"])
        | (&Method::GET, ["api", "v1", "devices"])
        | (&Method::POST, ["api", "v1", "devices"])
        | (&Method::PUT, ["api", "v1", "devices", "capabilities"])
        | (&Method::POST, ["api", "v1", "devices", _, "revoke"])
        | (&Method::GET, ["api", "v1", "vaults"])
        | (&Method::POST, ["api", "v1", "vaults"])
        | (&Method::GET, ["api", "v1", "vaults", _, "members"])
        | (&Method::GET, ["api", "v1", "vaults", _, "devices"])
        | (&Method::POST, ["api", "v1", "vaults", _, "invitations"])
        | (&Method::POST, ["api", "v1", "invitations", "accept"])
        | (&Method::POST, ["api", "v1", "vaults", _, "keys", "rotate"])
        | (&Method::POST, ["api", "v1", "vaults", _, "ownership", "transfer"])
        | (&Method::DELETE, ["api", "v1", "vaults", _])
        | (&Method::POST, ["api", "v1", "vaults", _, "deletion", "cancel"])
        | (&Method::GET, ["api", "v1", "vaults", _, "membership"])
        | (&Method::POST, ["api", "v1", "vaults", _, "sync", "push"])
        | (&Method::POST, ["api", "v1", "vaults", _, "uploads", "init"])
        | (&Method::PUT, ["api", "v1", "uploads", _, "chunks", _])
        | (&Method::POST, ["api", "v1", "uploads", _, "complete"])
        | (&Method::GET, ["api", "v1", "vaults", _, "objects", _])
        | (&Method::GET, ["api", "v1", "vaults", _, "changes"])
        | (&Method::POST, ["api", "v1", "vaults", _, "snapshots"])
        | (&Method::GET, ["api", "v1", "snapshots", _])
        | (&Method::GET, ["api", "v1", "vaults", _, "revisions"])
        | (&Method::GET, ["api", "v1", "vaults", _, "revisions", _])
        | (&Method::GET, ["api", "v1", "vaults", _, "conflicts"])
        | (&Method::POST, ["api", "v1", "vaults", _, "conflicts"])
        | (&Method::GET, ["api", "v1", "vaults", _, "conflict-changes"])
        | (&Method::POST, ["api", "v1", "vaults", _, "conflicts", _, "resolve"]) => true,
        _ => false,
    }
}

fn pg_web_fallback_request_is_supported(method: &Method, path: &str) -> bool {
    if method != Method::GET && method != Method::HEAD {
        return false;
    }
    // Static assets and Flutter SPA routes are public read-only resources.
    // Keep API, health, Relay, and collaboration namespaces out of the
    // fallback path so unsupported operations remain fail-closed and a
    // WebSocket endpoint can never be interpreted as a page request.
    !["/api", "/health", "/relay", "/collaboration", "/gateway", "/desktop"]
        .iter()
        .any(|prefix| {
            path == *prefix
                || path
                    .strip_prefix(*prefix)
                    .is_some_and(|suffix| suffix.starts_with('/'))
        })
}

#[cfg(test)]
mod pg_sync_scope_tests {
    use super::{pg_sync_route_is_supported, pg_web_fallback_request_is_supported};
    use axum::http::Method;

    #[test]
    fn restricted_pg_runtime_allows_onboarding_unlock_reads_and_sync_routes() {
        for (method, path) in [
            (Method::GET, "/health/live"),
            (Method::GET, "/health/ready"),
            (Method::GET, "/api/v1/instance"),
            (Method::GET, "/api/v1/audit"),
            (Method::GET, "/api/v1/admin/audit"),
            (Method::GET, "/api/v1/admin/overview"),
            (Method::GET, "/api/v1/admin/push-health"),
            (Method::GET, "/api/v1/admin/metrics"),
            (Method::GET, "/api/v1/admin/metrics-credential"),
            (Method::GET, "/api/v1/admin/backup-replication"),
            (Method::POST, "/api/v1/admin/backup-replication/preflight"),
            (Method::POST, "/api/v1/admin/metrics-credential"),
            (Method::DELETE, "/api/v1/admin/metrics-credential"),
            (Method::GET, "/api/v1/admin/jobs"),
            (Method::POST, "/api/v1/admin/jobs"),
            (Method::GET, "/api/v1/admin/restore-sources"),
            (
                Method::POST,
                "/api/v1/admin/restore-stages/123e4567-e89b-12d3-a456-426614174000/discard",
            ),
            (Method::GET, "/api/v1/admin/backup-status"),
            (Method::GET, "/api/v1/admin/backup-schedule"),
            (Method::PUT, "/api/v1/admin/backup-schedule"),
            (Method::GET, "/api/v1/admin/accounts"),
            (Method::GET, "/api/v1/admin/vaults"),
            (
                Method::PUT,
                "/api/v1/admin/vaults/123e4567-e89b-12d3-a456-426614174000/quota",
            ),
            (Method::GET, "/api/v1/admin/account-invitations"),
            (Method::POST, "/api/v1/admin/account-invitations"),
            (
                Method::POST,
                "/api/v1/admin/account-invitations/123e4567-e89b-12d3-a456-426614174000/revoke",
            ),
            (
                Method::GET,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions",
            ),
            (
                Method::PUT,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/status",
            ),
            (
                Method::POST,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/revoke",
            ),
            (
                Method::POST,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/123e4567-e89b-12d3-a456-426614174001/revoke",
            ),
            (Method::POST, "/api/v1/auth/prelogin"),
            (Method::POST, "/api/v1/auth/register"),
            (Method::POST, "/api/v1/auth/login"),
            (Method::POST, "/api/v1/auth/login/mfa"),
            (Method::GET, "/api/v1/auth/mfa"),
            (Method::POST, "/api/v1/auth/mfa/totp/setup"),
            (Method::POST, "/api/v1/auth/mfa/totp/confirm"),
            (Method::POST, "/api/v1/auth/mfa/recovery-codes"),
            (Method::DELETE, "/api/v1/auth/mfa/totp"),
            (Method::POST, "/api/v1/auth/password-change"),
            (Method::POST, "/api/v1/auth/refresh"),
            (Method::POST, "/api/v1/auth/logout"),
            (Method::PUT, "/api/v1/auth/recovery"),
            (Method::DELETE, "/api/v1/auth/recovery"),
            (Method::GET, "/api/v1/auth/recovery/contexts"),
            (Method::PUT, "/api/v1/auth/recovery/key-envelopes"),
            (Method::POST, "/api/v1/auth/recovery/start"),
            (Method::POST, "/api/v1/auth/recovery/inspect"),
            (Method::POST, "/api/v1/auth/recovery/complete"),
            (Method::POST, "/api/v1/account/delete"),
            (Method::POST, "/api/v1/account/delete/cancel"),
            (Method::GET, "/api/v1/me"),
            (Method::GET, "/api/v1/devices"),
            (Method::POST, "/api/v1/devices"),
            (Method::PUT, "/api/v1/devices/capabilities"),
            (Method::PUT, "/api/v1/devices/redaction-capabilities"),
            (Method::POST, "/api/v1/devices/device-id/revoke"),
            (Method::POST, "/api/v1/notifications/tickets"),
            (Method::GET, "/api/v1/notifications"),
            (Method::POST, "/api/v1/relay/tickets"),
            (Method::GET, "/relay/v1/connect"),
            (Method::GET, "/api/v1/admin/relay-policy"),
            (Method::PUT, "/api/v1/admin/relay-policy"),
            (
                Method::GET,
                "/api/v1/admin/relay-policy/users/123e4567-e89b-12d3-a456-426614174000",
            ),
            (
                Method::PUT,
                "/api/v1/admin/relay-policy/users/123e4567-e89b-12d3-a456-426614174000",
            ),
            (
                Method::DELETE,
                "/api/v1/admin/relay-policy/users/123e4567-e89b-12d3-a456-426614174000",
            ),
            (Method::GET, "/api/v1/admin/relay-groups"),
            (Method::POST, "/api/v1/admin/relay-groups"),
            (
                Method::GET,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000",
            ),
            (
                Method::PUT,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000",
            ),
            (
                Method::DELETE,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000",
            ),
            (
                Method::PUT,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000/members",
            ),
            (
                Method::GET,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000/relay-policy",
            ),
            (
                Method::PUT,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000/relay-policy",
            ),
            (
                Method::DELETE,
                "/api/v1/admin/relay-groups/123e4567-e89b-12d3-a456-426614174000/relay-policy",
            ),
            (
                Method::PUT,
                "/api/v1/notifications/push-endpoints/device-id",
            ),
            (
                Method::DELETE,
                "/api/v1/notifications/push-endpoints/device-id/fcm_v1",
            ),
            (Method::GET, "/api/v1/vaults"),
            (Method::POST, "/api/v1/vaults"),
            (Method::GET, "/api/v1/vaults/v/members"),
            (Method::POST, "/api/v1/vaults/v/invitations"),
            (Method::POST, "/api/v1/invitations/accept"),
            (Method::POST, "/api/v1/vaults/v/keys/rotate"),
            (Method::POST, "/api/v1/vaults/v/ownership/transfer"),
            (Method::DELETE, "/api/v1/vaults/v"),
            (Method::POST, "/api/v1/vaults/v/deletion/cancel"),
            (Method::GET, "/api/v1/vaults/v/devices"),
            (Method::GET, "/api/v1/vaults/v/membership"),
            (Method::GET, "/api/v1/vaults/vault-id/presence"),
            (Method::POST, "/api/v1/vaults/vault-id/presence"),
            (Method::POST, "/api/v1/vaults/v/sync/push"),
            (Method::POST, "/api/v1/vaults/v/records/r/purge"),
            (Method::PUT, "/api/v1/vaults/v/records/r/automatic-purge"),
            (Method::POST, "/api/v1/vaults/v/uploads/init"),
            (Method::PUT, "/api/v1/uploads/u/chunks/0"),
            (Method::POST, "/api/v1/uploads/u/complete"),
            (Method::GET, "/api/v1/vaults/v/objects/o"),
            (Method::GET, "/api/v1/vaults/v/changes"),
            (Method::POST, "/api/v1/vaults/v/snapshots"),
            (Method::GET, "/api/v1/snapshots/s"),
            (Method::GET, "/api/v1/vaults/v/revisions"),
            (Method::GET, "/api/v1/vaults/v/revisions/r"),
            (Method::GET, "/api/v1/vaults/v/conflicts"),
            (Method::POST, "/api/v1/vaults/v/conflicts"),
            (Method::GET, "/api/v1/vaults/v/conflict-changes"),
            (Method::POST, "/api/v1/vaults/v/conflicts/c/resolve"),
        ] {
            assert!(
                pg_sync_route_is_supported(&method, path),
                "unexpectedly blocked {method} {path}"
            );
        }
        for (method, path) in [
            (Method::GET, "/api/v1/auth/login/mfa"),
            (Method::POST, "/api/v1/auth/mfa/totp"),
            (Method::PUT, "/api/v1/auth/mfa/totp/setup"),
            (Method::POST, "/api/v1/auth/mfa/totp/setup/extra"),
            (Method::DELETE, "/api/v1/auth/mfa/recovery-codes"),
            (Method::PUT, "/api/v1/auth/mfa/recovery-codes"),
            (Method::POST, "/api/v1/auth/mfa/recovery-codes/extra"),
            (Method::POST, "/api/v1/auth/mfa/totp/confirm/extra"),
            (Method::GET, "/api/v1/auth/password-change"),
            (Method::PATCH, "/api/v1/auth/recovery"),
            (Method::POST, "/api/v1/auth/recovery"),
            (Method::DELETE, "/api/v1/auth/recovery/contexts"),
            (Method::GET, "/api/v1/auth/recovery/start"),
            (Method::POST, "/api/v1/auth/recovery/complete/extra"),
            (Method::DELETE, "/api/v1/account/delete"),
            (Method::GET, "/api/v1/account/delete"),
            (Method::POST, "/api/v1/account/delete/extra"),
            (Method::GET, "/api/v1/account/delete/cancel"),
            (Method::POST, "/api/v1/account/delete/cancel/extra"),
            (Method::PUT, "/api/v1/admin/account-invitations"),
            (Method::DELETE, "/api/v1/admin/account-invitations"),
            (Method::GET, "/api/v1/admin/account-invitations/"),
            (Method::POST, "/api/v1/admin/push-health"),
            (Method::DELETE, "/api/v1/admin/push-health"),
            (Method::GET, "/api/v1/admin/push-health/"),
            (Method::GET, "/api/v1/admin/push-health/extra"),
            (Method::POST, "/api/v1/admin/metrics"),
            (Method::PUT, "/api/v1/admin/metrics"),
            (Method::GET, "/api/v1/admin/metrics/"),
            (Method::GET, "/api/v1/admin/metrics-credential/"),
            (Method::GET, "/api/v1/admin/metrics-credential/extra"),
            (Method::PUT, "/api/v1/admin/metrics-credential"),
            (Method::PATCH, "/api/v1/admin/metrics-credential"),
            (
                Method::POST,
                "/api/v1/admin/account-invitations/123e4567-e89b-12d3-a456-426614174000/revoke/",
            ),
            (
                Method::POST,
                "/api/v1/admin/account-invitations/123e4567-e89b-12d3-a456-426614174000/revoke/extra",
            ),
            (
                Method::GET,
                "/api/v1/admin/account-invitations/123e4567-e89b-12d3-a456-426614174000/revoke",
            ),
            (Method::DELETE, "/api/v1/vaults/v/invitations"),
            (Method::POST, "/api/v1/vaults/v/invitations/i/revoke"),
            (Method::PUT, "/api/v1/vaults/v/members"),
            (Method::DELETE, "/api/v1/invitations/accept"),
            (Method::GET, "/api/v1/relay/tickets"),
            (Method::PUT, "/api/v1/relay/tickets"),
            (Method::POST, "/api/v1/relay/tickets/"),
            (Method::POST, "/api/v1/relay/tickets/extra"),
            (Method::POST, "/relay/v1/connect"),
            (Method::GET, "/relay/v1/connect/"),
            (Method::GET, "/relay/v1/connect/extra"),
            (Method::POST, "/api/v1/admin/relay-policy"),
            (Method::GET, "/api/v1/admin/relay-policy/"),
            (Method::GET, "/api/v1/admin/relay-groups/"),
            (Method::GET, "/api/v1/admin/relay-groups//members"),
            (Method::PUT, "/api/v1/admin/relay-groups/id/members/"),
            (Method::GET, "/api/v1/admin/relay-groups/id/relay-policy/"),
            (Method::POST, "/api/v1/vaults/v/keys/rotate/extra"),
            (Method::POST, "/api/v1/vaults/v/ownership/transfer/extra"),
            (Method::DELETE, "/api/v1/vaults/v/deletion/cancel"),
            (Method::POST, "/api/v1/vaults/v/deletion/cancel/extra"),
            (Method::GET, "/api/v1/vaults/v/deletion/cancel"),
            (Method::PATCH, "/api/v1/vaults/v"),
            (Method::PUT, "/api/v1/vaults/vault-id/presence"),
            (Method::GET, "/api/v1/vaults/vault-id/presence/"),
            (Method::POST, "/api/v1/vaults/vault-id//presence"),
            (Method::GET, "/api/v1/vaults/vault-id/presence/extra"),
            (Method::DELETE, "/api/v1/vaults/v/extra"),
            (Method::GET, "/api/v1/vaults/v/ownership/transfer"),
            (Method::GET, "/api/v1/vaults/v/keys/rotate"),
            (Method::GET, "/api/v1/devices/capabilities"),
            (Method::GET, "/api/v1/devices/redaction-capabilities"),
            (Method::POST, "/api/v1/devices/device-id/revoke/extra"),
            (Method::DELETE, "/api/v1/devices/device-id/revoke"),
            (Method::POST, "/api/v1/devices/device-id/restore"),
            (Method::PUT, "/api/v1/notifications/tickets"),
            (Method::GET, "/api/v1/notifications/tickets"),
            (Method::POST, "/api/v1/notifications"),
            (Method::GET, "/api/v1/notifications/"),
            (Method::GET, "/api/v1/notifications/extra"),
            (Method::POST, "/api/v1/notifications/tickets/"),
            (Method::POST, "/api/v1/notifications/tickets/extra"),
            (
                Method::POST,
                "/api/v1/notifications/push-endpoints/device-id",
            ),
            (
                Method::DELETE,
                "/api/v1/notifications/push-endpoints/device-id",
            ),
            (
                Method::PUT,
                "/api/v1/notifications/push-endpoints/device-id/fcm_v1",
            ),
            (
                Method::DELETE,
                "/api/v1/notifications/push-endpoints/device-id/fcm_v1/extra",
            ),
            (
                Method::GET,
                "/api/v1/notifications/push-endpoints/device-id",
            ),
            (
                Method::PUT,
                "/api/v1/notifications/push-endpoints/device-id/",
            ),
            (
                Method::PUT,
                "/api/v1/notifications//push-endpoints/device-id",
            ),
            (
                Method::PUT,
                "/api/v1/notifications/push-endpoints//device-id",
            ),
            (
                Method::DELETE,
                "/api/v1/notifications/push-endpoints/device-id/fcm_v1/",
            ),
            (
                Method::DELETE,
                "/api/v1/notifications/push-endpoints/device-id//fcm_v1",
            ),
            (Method::DELETE, "/api/v1/uploads/u/chunks/0"),
            (Method::GET, "/api/v1/uploads/u/complete"),
            (Method::POST, "/api/v1/vaults/v/objects/o"),
            (Method::GET, "/api/v1/vaults/v/records/r/purge"),
            (Method::PUT, "/api/v1/vaults/v/records/r/purge"),
            (Method::POST, "/api/v1/vaults/v/records/r/purge/"),
            (Method::POST, "/api/v1/vaults/v/records//r/purge"),
            (Method::PUT, "/api/v1/vaults/v/records/r/automatic-purge/"),
            (Method::PUT, "/api/v1/vaults/v/records//automatic-purge"),
            (Method::POST, "/api/v1/auth/password-change/extra"),
            (Method::GET, "/api/v1/openapi.yaml"),
            (Method::POST, "/api/v1/audit"),
            (Method::GET, "/api/v1/audit/"),
            (Method::GET, "/api/v1/audit/extra"),
            (Method::POST, "/api/v1/admin/audit"),
            (Method::GET, "/api/v1/admin/audit/"),
            (Method::GET, "/api/v1/admin/audit/extra"),
            (Method::POST, "/api/v1/admin/overview"),
            (Method::GET, "/api/v1/admin/overview/"),
            (Method::GET, "/api/v1/admin/overview/extra"),
            (Method::GET, "/api/v1/admin/jobs/"),
            (Method::GET, "/api/v1/admin/restore-sources/"),
            (Method::GET, "/api/v1/admin/backup-status/"),
            (Method::POST, "/api/v1/admin/backup-status"),
            (Method::GET, "/api/v1/admin/backup-replication/"),
            (Method::POST, "/api/v1/admin/backup-replication/preflight/"),
            (Method::GET, "/api/v1/admin/backup-replication/preflight"),
            (Method::POST, "/api/v1/admin/backup-replication"),
            (Method::GET, "/api/v1/admin/backup-schedule/"),
            (Method::PUT, "/api/v1/admin/backup-schedule/"),
            (Method::POST, "/api/v1/admin/backup-schedule"),
            (Method::DELETE, "/api/v1/admin/backup-schedule"),
            (Method::POST, "/api/v1/admin/restore-sources"),
            (
                Method::POST,
                "/api/v1/admin/restore-stages/123e4567-e89b-12d3-a456-426614174000/discard/",
            ),
            (
                Method::POST,
                "/api/v1/admin/restore-stages/not-a-uuid/discard",
            ),
            (
                Method::DELETE,
                "/api/v1/admin/restore-stages/123e4567-e89b-12d3-a456-426614174000/discard",
            ),
            (Method::PUT, "/api/v1/admin/jobs"),
            (Method::DELETE, "/api/v1/admin/jobs"),
            (Method::POST, "/api/v1/admin/accounts"),
            (Method::GET, "/api/v1/admin/accounts/"),
            (Method::POST, "/api/v1/admin/vaults"),
            (Method::GET, "/api/v1/admin/vaults/"),
            (Method::PUT, "/api/v1/admin/vaults"),
            (
                Method::PUT,
                "/api/v1/admin/vaults/123e4567-e89b-12d3-a456-426614174000/quota/",
            ),
            (
                Method::PUT,
                "/api/v1/admin/vaults/123e4567-e89b-12d3-a456-426614174000//quota",
            ),
            (
                Method::PUT,
                "/api/v1/admin/vaults/123e4567-e89b-12d3-a456-426614174000/quota/extra",
            ),
            (
                Method::GET,
                "/api/v1/admin/vaults/123e4567-e89b-12d3-a456-426614174000/quota",
            ),
            (
                Method::GET,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/",
            ),
            (
                Method::GET,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/extra",
            ),
            (
                Method::POST,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions",
            ),
            (
                Method::GET,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/status",
            ),
            (
                Method::PUT,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/status/",
            ),
            (
                Method::PUT,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/revoke",
            ),
            (
                Method::GET,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/revoke",
            ),
            (
                Method::POST,
                "/api/v1/admin/accounts/123e4567-e89b-12d3-a456-426614174000/sessions/123e4567-e89b-12d3-a456-426614174001/revoke/",
            ),
            (Method::PUT, "/api/v1/admin/account-invitations"),
            (
                Method::POST,
                "/api/v1/admin/account-invitations/123e4567-e89b-12d3-a456-426614174000/revoke/",
            ),
        ] {
            assert!(
                !pg_sync_route_is_supported(&method, path),
                "unexpectedly exposed {method} {path}"
            );
        }
    }

    #[test]
    fn restricted_pg_runtime_serves_only_read_only_non_api_web_fallbacks() {
        for (method, path) in [
            (Method::GET, "/"),
            (Method::HEAD, "/index.html"),
            (Method::GET, "/main.dart.js"),
            (Method::GET, "/settings"),
            (Method::GET, "/assets/font.woff2"),
        ] {
            assert!(
                pg_web_fallback_request_is_supported(&method, path),
                "expected read-only Web fallback {method} {path} to be available"
            );
            assert!(
                pg_sync_route_is_supported(&method, path),
                "expected PG runtime to pass Web fallback {method} {path}"
            );
        }
        for (method, path) in [
            (Method::POST, "/"),
            (Method::OPTIONS, "/settings"),
            (Method::GET, "/api"),
            (Method::GET, "/api/v1/unimplemented"),
            (Method::HEAD, "/api/v1/instance"),
            (Method::GET, "/health/not-real"),
            (Method::GET, "/collaboration/v1/connect"),
        ] {
            assert!(
                !pg_web_fallback_request_is_supported(&method, path),
                "unexpectedly admitted reserved or mutating Web fallback {method} {path}"
            );
            assert!(
                !pg_sync_route_is_supported(&method, path),
                "unexpectedly exposed unsupported request {method} {path}"
            );
        }
    }
}

fn make_http_request_span(request: &Request) -> tracing::Span {
    let request_id = request
        .extensions()
        .get::<error::RequestContext>()
        .map(error::RequestContext::request_id)
        .unwrap_or("missing");
    let method = match *request.method() {
        Method::GET => "GET",
        Method::HEAD => "HEAD",
        Method::POST => "POST",
        Method::PUT => "PUT",
        Method::PATCH => "PATCH",
        Method::DELETE => "DELETE",
        Method::OPTIONS => "OPTIONS",
        _ => "OTHER",
    };

    // Deliberately omit URI, query, headers, and body from request spans.
    tracing::info_span!("http.request", request_id = %request_id, method = method)
}

async fn request_id_context(mut request: Request, next: Next) -> Response {
    // Never reflect a caller-provided ID. An untrusted value could contain
    // sensitive text, create log injection, or make unrelated requests look
    // correlated. Generate a canonical UUID and replace the inbound header.
    let request_id = Uuid::new_v4().to_string();
    request.headers_mut().remove("x-request-id");
    let request_context = error::RequestContext::new(
        request_id.clone(),
        request.uri().path().starts_with("/api/"),
    );
    request.extensions_mut().insert(request_context.clone());

    error::with_request_context(request_context, async move {
        let mut response = next.run(request).await;
        response.headers_mut().insert(
            "x-request-id",
            HeaderValue::from_str(&request_id).expect("a canonical UUID is a valid header value"),
        );
        response
    })
    .await
}

fn api_cors_layer(public_origin: Option<&str>) -> Option<CorsLayer> {
    let origin = public_origin.and_then(|value| HeaderValue::from_str(value).ok())?;
    Some(
        CorsLayer::new()
            .allow_origin(origin)
            .allow_methods([
                Method::GET,
                Method::POST,
                Method::PUT,
                Method::DELETE,
                Method::OPTIONS,
            ])
            .allow_headers([
                axum::http::header::ACCEPT,
                axum::http::header::ACCEPT_ENCODING,
                axum::http::header::AUTHORIZATION,
                axum::http::header::CONTENT_TYPE,
                axum::http::header::RANGE,
                HeaderName::from_static("if-range"),
                HeaderName::from_static("x-atermius-capability-marker"),
                HeaderName::from_static("x-atermius-redaction-marker"),
                HeaderName::from_static("x-content-sha256"),
            ])
            .expose_headers([
                axum::http::header::ACCEPT_RANGES,
                axum::http::header::CONTENT_RANGE,
                axum::http::header::ETAG,
                HeaderName::from_static("x-request-id"),
            ]),
    )
}

async fn apply_response_security_headers(request: Request, next: Next) -> Response {
    let path = request.uri().path().to_owned();
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        "Content-Security-Policy",
        HeaderValue::from_static(
            "default-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'; object-src 'none'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self' http: https: ws: wss:; worker-src 'self' blob:; manifest-src 'self'",
        ),
    );
    headers.insert(
        "X-Content-Type-Options",
        HeaderValue::from_static("nosniff"),
    );
    headers.insert("X-Frame-Options", HeaderValue::from_static("DENY"));
    headers.insert("Referrer-Policy", HeaderValue::from_static("no-referrer"));
    headers.insert(
        "Permissions-Policy",
        HeaderValue::from_static("camera=(), geolocation=(), microphone=(), payment=()"),
    );
    if path == "/s" || path.starts_with("/s/") || path == "/join" || path.starts_with("/api/v1/guest/") {
        // Guest landing/join pages: never cached, isolated browsing context.
        headers.insert(
            "Cross-Origin-Opener-Policy",
            HeaderValue::from_static("same-origin"),
        );
    }
    if path.starts_with("/api/")
        || path.starts_with("/health/")
        || path == "/s"
        || path.starts_with("/s/")
        || path == "/join"
    {
        headers.insert("Cache-Control", HeaderValue::from_static("no-store"));
    } else {
        // Flutter asset names are stable across releases; revalidate them so a
        // browser cannot keep running stale client protocol code indefinitely.
        headers.insert("Cache-Control", HeaderValue::from_static("no-cache"));
    }
    response
}

async fn spa_fallback(
    axum::extract::State(state): axum::extract::State<AppState>,
    OriginalUri(uri): OriginalUri,
) -> Response {
    if uri.path() == "/api"
        || uri.path().starts_with("/api/")
        || uri.path() == "/health"
        || uri.path().starts_with("/health/")
        || uri.path() == "/relay"
        || uri.path().starts_with("/relay/")
        || uri.path() == "/gateway"
        || uri.path().starts_with("/gateway/")
    {
        return ApiError::not_found().into_response();
    }
    let Some(web_dir) = state.config.web_dir.as_ref() else {
        return ApiError::not_found().into_response();
    };
    let Ok(root) = tokio::fs::canonicalize(web_dir).await else {
        return ApiError::not_found().into_response();
    };
    let relative = uri.path().trim_start_matches('/');
    if !relative.is_empty() && !relative.split('/').any(|part| part == "." || part == "..") {
        let candidate = root.join(relative);
        if let Ok(real) = tokio::fs::canonicalize(&candidate).await {
            if real.starts_with(&root) {
                if let Ok(meta) = tokio::fs::metadata(&real).await {
                    let file = if meta.is_dir() {
                        real.join("index.html")
                    } else {
                        real
                    };
                    if let Ok(file) = tokio::fs::canonicalize(&file).await {
                        if file.starts_with(&root) {
                            if let Ok(bytes) = tokio::fs::read(&file).await {
                                let mime =
                                    match file.extension().and_then(|v| v.to_str()).unwrap_or("") {
                                        "html" => "text/html; charset=utf-8",
                                        "js" => "text/javascript; charset=utf-8",
                                        "mjs" => "text/javascript; charset=utf-8",
                                        "css" => "text/css; charset=utf-8",
                                        "json" => "application/json",
                                        "svg" => "image/svg+xml",
                                        "png" => "image/png",
                                        "jpg" | "jpeg" => "image/jpeg",
                                        "webp" => "image/webp",
                                        "ico" => "image/x-icon",
                                        "wasm" => "application/wasm",
                                        "woff2" => "font/woff2",
                                        _ => "application/octet-stream",
                                    };
                                let mut response = bytes.into_response();
                                response.headers_mut().insert(
                                    CONTENT_TYPE,
                                    axum::http::HeaderValue::from_static(mime),
                                );
                                return response;
                            }
                        }
                    }
                }
            }
        }
    }
    // Missing asset paths should remain 404s; extensionless paths are Flutter SPA routes.
    if uri
        .path()
        .rsplit('/')
        .next()
        .is_some_and(|last| last.contains('.'))
    {
        return ApiError::not_found().into_response();
    }
    let index = match tokio::fs::canonicalize(root.join("index.html")).await {
        Ok(p) if p.starts_with(&root) => p,
        _ => return ApiError::not_found().into_response(),
    };
    match tokio::fs::read(index).await {
        Ok(bytes) => {
            let mut response = bytes.into_response();
            response.headers_mut().insert(
                CONTENT_TYPE,
                axum::http::HeaderValue::from_static("text/html; charset=utf-8"),
            );
            response
        }
        Err(_) => ApiError::not_found().into_response(),
    }
}

/// Opens and serves the configured instance while holding the runtime lock
/// before SQLite is opened. Offline data operations use the same lock, so a
/// new server process cannot inspect or mutate the database during them.
pub async fn serve_from_config(
    database_url: &str,
    config: Config,
    address: SocketAddr,
) -> Result<(), ApiError> {
    secure_file::create_private_data_dir(&config.data_dir)?;
    let runtime_lock = acquire_runtime_lock(&config.data_dir)?;
    let state = open_state(database_url, config).await?;
    serve_with_runtime_lock(state, address, runtime_lock).await
}

pub async fn serve(state: AppState, address: SocketAddr) -> Result<(), ApiError> {
    let runtime_lock = acquire_runtime_lock(&state.config.data_dir)?;
    serve_with_runtime_lock(state, address, runtime_lock).await
}

async fn serve_with_runtime_lock(
    state: AppState,
    address: SocketAddr,
    _runtime_lock: File,
) -> Result<(), ApiError> {
    if state.database_encryption == database::DatabaseEncryption::Disabled {
        tracing::warn!(
            "instance database encryption at rest is disabled; configure ATERMIUS_DATABASE_KEY_FILE and run `atermius-server database-encrypt` (see docs/runbooks/database-encryption.md)"
        );
    }
    if state.pg_sync_only {
        // PG backup creation and replication use shared PostgreSQL job/outbox
        // state. Validate the provider settings and private credentials here;
        // replica restore remains disabled until its source/download path is
        // moved off the SQLite sidecar as well.
        backup_replication::validate_startup_configuration(&state.config)?;
        // The PG sync-core runtime intentionally does not start SQLite admin,
        // backup, or collaboration workers. PostgreSQL object reservations
        // and GC use shared row-locked repositories; the bounded maintenance
        // action and PostgreSQL notification listener use their PG workers.
        let pg_pool = state
            .pg_sync_pool
            .as_ref()
            .ok_or_else(|| ApiError::internal("PostgreSQL sync pool is unavailable"))?;
        let mut pg_runtime_lock = pg_sync_runtime::acquire_server_lifetime_lock(pg_pool).await?;
        // Try LISTEN before exposing a listening socket. If that bounded
        // attempt fails, WebSocket snapshot polling remains active while the
        // background listener retries. Sockets reauthorize from current state
        // before sending metadata after every wake.
        let notification_listener = pg_notifications::PgNotificationListener::start(
            pg_pool.clone(),
            state.pg_notification_hub.clone(),
        )
        .await;
        // Do not expose a listening socket while an offline exclusive
        // operation owns the database coordination lock. In particular, the
        // process must not accept TCP connections into a backlog before it is
        // safe to serve requests against PostgreSQL.
        let listener = match TcpListener::bind(address).await {
            Ok(listener) => listener,
            Err(error) => {
                notification_listener.shutdown().await;
                let _ = pg_runtime_lock.release().await;
                return Err(ApiError::internal(error));
            }
        };
        pg_admin_jobs::start_worker(state.clone());
        if let Some(repository) = state.pg_account_onboarding.clone() {
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
                loop {
                    interval.tick().await;
                    if let Err(error) = repository.prune_invitation_history().await {
                        tracing::warn!(error = %error, "PostgreSQL invitation history cleanup failed");
                    }
                }
            });
        }
        let maintenance_state = state.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                if let Err(error) = run_maintenance(&maintenance_state).await {
                    tracing::warn!(
                        error_code = %error.body.code,
                        "PostgreSQL retention maintenance failed"
                    );
                }
            }
        });
        if let Some(repository) = state.pg_vault_deletion.clone() {
            let object_store = state.object_store.clone();
            let object_repository = state.pg_objects.clone();
            let retention_days = state.config.audit_retention_days;
            let account_deletion = state.pg_account_deletion.clone();
            let account_recovery = pg_account_recovery::from_state(&state);
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(10));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    interval.tick().await;
                    let now = chrono::Utc::now().timestamp();
                    if let Some(account_deletion) = account_deletion.as_ref() {
                        if let Err(error) = account_deletion
                            .purge_due_account_deletions(now, retention_days)
                            .await
                        {
                            tracing::warn!(
                                error_code = %error.body.code,
                                "PostgreSQL due account deletion cleanup failed"
                            );
                        }
                    }
                    if let Some(account_recovery) = account_recovery.as_ref() {
                        if let Err(error) = account_recovery.prune_challenges(now).await {
                            tracing::warn!(
                                error_code = %error.body.code,
                                "PostgreSQL Recovery challenge cleanup failed"
                            );
                        }
                    }
                    if let Err(error) = repository
                        .purge_due_vault_deletions(now, retention_days)
                        .await
                    {
                        tracing::warn!(
                            error_code = %error.body.code,
                            "PostgreSQL due Vault deletion cleanup failed"
                        );
                    }
                    if let Some(object_repository) = object_repository.as_ref() {
                        if let Err(error) = object_repository.cleanup_expired_backup_pins(100).await
                        {
                            tracing::warn!(
                                error_code = %error.body.code,
                                "PostgreSQL expired backup object pin cleanup failed"
                            );
                        }
                        if let Err(error) = object_repository.prune_expired_uploads(now, 100).await
                        {
                            tracing::warn!(
                                error_code = %error.body.code,
                                "PostgreSQL expired object upload cleanup failed"
                            );
                        }
                        if let Err(error) = object_repository.collect_due_objects(now, 100).await {
                            tracing::warn!(
                                error_code = %error.body.code,
                                "PostgreSQL object garbage collection failed"
                            );
                        }
                    }
                    if let Err(error) = repository
                        .drain_object_delete_queue(&object_store, now, 32)
                        .await
                    {
                        tracing::warn!(
                            error_code = %error.body.code,
                            "PostgreSQL external object deletion queue drain failed"
                        );
                    }
                }
            });
        }
        if backup_replication::replication_requested(&state.config) {
            let replication_state = state.clone();
            let replication_repository =
                pg_backup_replication::PgBackupReplicationRepository::new(pg_pool.clone());
            tokio::spawn(async move {
                let mut interval = tokio::time::interval(std::time::Duration::from_secs(
                    backup_replication::REPLICATION_POLL_SECONDS,
                ));
                interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
                loop {
                    interval.tick().await;
                    if let Err(error) = backup_replication::run_one_pg_due(
                        &replication_state,
                        &replication_repository,
                    )
                    .await
                    {
                        tracing::warn!(
                            error_code = %error.body.code,
                            "PostgreSQL encrypted backup replication worker iteration failed"
                        );
                    }
                }
            });
        }
        let server = axum::serve(
            listener,
            router(state)
                .await
                .into_make_service_with_connect_info::<SocketAddr>(),
        );
        let outcome = tokio::select! {
            result = server => Ok(result),
            lost = pg_runtime_lock.wait_until_lost() => {
                let error = match lost {
                    Err(error) => error,
                    Ok(()) => ApiError::internal("PostgreSQL runtime coordination lock was lost"),
                };
                tracing::error!(error_code = %error.body.code, "PostgreSQL runtime coordination lock lost; stopping service");
                Err(error)
            }
        };
        notification_listener.shutdown().await;
        return match outcome {
            Ok(result) => {
                pg_runtime_lock.release().await?;
                result.map_err(ApiError::internal)
            }
            Err(error) => {
                let _ = pg_runtime_lock.release().await;
                Err(error)
            }
        };
    }
    backup::validate_backup_retention_configuration(&state.config)?;
    backup_replication::validate_startup_configuration(&state.config)?;
    backup::validate_backup_schedule_configuration(&state).await?;
    admin::recover_interrupted_jobs(&state).await?;
    backup::recover_interrupted_scheduled_backup_runs(&state).await?;
    backup_replication::recover_interrupted(&state).await?;
    let listener = TcpListener::bind(address)
        .await
        .map_err(ApiError::internal)?;
    let maintenance_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(60 * 60));
        loop {
            interval.tick().await;
            if let Err(error) = run_maintenance(&maintenance_state).await {
                tracing::warn!(error = %error, "database maintenance failed");
            }
        }
    });
    let scheduled_backup_state = state.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(
            backup::SCHEDULED_BACKUP_POLL_SECONDS,
        ));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            interval.tick().await;
            if let Err(error) = backup::run_due_scheduled_backup(&scheduled_backup_state).await {
                tracing::warn!(error = %error, "scheduled backup run failed");
            }
        }
    });
    if backup_replication::replication_requested(&state.config) {
        let replication_state = state.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(
                backup_replication::REPLICATION_POLL_SECONDS,
            ));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                if let Err(error) = backup_replication::run_one_due(&replication_state).await {
                    tracing::warn!(
                        error_code = %error.body.code,
                        "encrypted backup replication worker iteration failed"
                    );
                }
            }
        });
    }
    if let Some(repository) = state.pg_mobile_push.clone() {
        repository.start_worker(mobile_push::configured_provider());
    } else {
        mobile_push::start_worker(state.clone(), mobile_push::configured_provider());
    }
    axum::serve(
        listener,
        router(state)
            .await
            .into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await
    .map_err(ApiError::internal)
}

async fn health_live() -> axum::Json<serde_json::Value> {
    axum::Json(serde_json::json!({"status":"ok"}))
}

async fn health_ready(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Result<axum::Json<serde_json::Value>, ApiError> {
    if let Some(pg_pool) = state.pg_sync_pool.as_ref() {
        sqlx::query("SELECT 1")
            .execute(pg_pool)
            .await
            .map_err(ApiError::internal)?;
    } else {
        sqlx::query("SELECT 1")
            .execute(&state.db)
            .await
            .map_err(ApiError::internal)?;
    }
    Ok(axum::Json(serde_json::json!({"status":"ready"})))
}

async fn instance_info(
    axum::extract::State(state): axum::extract::State<AppState>,
) -> Result<axum::Json<InstanceResponse>, ApiError> {
    let count: i64 = if let Some(pg_pool) = state.pg_sync_pool.as_ref() {
        sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(pg_pool)
            .await
            .map_err(ApiError::internal)?
    } else {
        sqlx::query_scalar("SELECT COUNT(*) FROM users")
            .fetch_one(&state.db)
            .await
            .map_err(ApiError::internal)?
    };
    let setup_required = if let Some(repository) = state.pg_account_onboarding.as_ref() {
        repository.setup_required().await?
    } else {
        count == 0
    };
    let credential_visibility_default =
        credential_visibility::public_instance_default(&state).await?;
    Ok(axum::Json(InstanceResponse {
        instance_id: state.instance.instance_id.clone(),
        server_space_id: state.instance.server_space_id.clone(),
        generation: state.instance.generation.clone(),
        signing_public_key: state.instance.signing_public_key.clone(),
        signing_key_transitions: state.instance.signing_key_transitions.clone(),
        protocol_version: 1,
        setup_required,
        restore_retention_days: state.config.record_restore_retention_days,
        capabilities: {
            let mut c = if state.pg_sync_only {
                vec![
                    "ciphertext_sync",
                    "instance_signing_key",
                    "instance_key_transitions",
                    "snapshots",
                    "revision_history",
                    "conflict_history",
                    "encrypted_objects",
                    "signed_membership",
                    "device_redaction_capability_reports",
                    "postgres_sync_core_restricted",
                ]
            } else {
                vec![
                    "ciphertext_sync",
                    "instance_signing_key",
                    "instance_key_transitions",
                    "snapshots",
                    "revision_history",
                    "conflict_history",
                    "encrypted_objects",
                    "signed_membership",
                    "device_capability_reports",
                    "device_redaction_capability_reports",
                ]
            };
            if !state.pg_sync_only
                && state.config.relay_enabled
                && !state.config.relay_allow_cidrs.is_empty()
                && !state.config.relay_allow_ports.is_empty()
                && state.config.public_origin.is_some()
            {
                c.push("relay");
            }
            if state.config.public_origin.is_some() {
                c.push("notifications");
            }
            if !state.pg_sync_only
                && state.config.terminal_collaboration_enabled
                && state.config.public_origin.is_some()
            {
                c.push("terminal_collaboration");
            }
            if credential_visibility_default.is_some() {
                c.push("credential_visibility");
            }
            if cloud::organizations_ready(&state) {
                c.push("organizations");
            }
            if cloud::share_links_ready(&state) {
                c.push("share_links");
                c.push("share_gateway_ssh");
                c.push("share_gateway_rdp");
                if state.cloud.config.vnc_enabled {
                    c.push("share_gateway_vnc");
                }
            }
            if !state.pg_sync_only
                && state
                    .config
                    .web_dir
                    .as_ref()
                    .is_some_and(|d| d.join("index.html").is_file())
            {
                c.push("web_static");
            }
            c
        },
        credential_visibility_default,
        limits: InstanceLimits {
            max_object_bytes: state.config.max_object_bytes,
            max_upload_chunk_bytes: objects::CHUNK_SIZE_BYTES,
            max_record_object_refs: sync::MAX_OBJECT_REFS,
        },
    }))
}

async fn openapi() -> Response {
    (
        StatusCode::OK,
        [(CONTENT_TYPE, "application/yaml; charset=utf-8")],
        include_str!("../openapi.yaml"),
    )
        .into_response()
}

pub(crate) fn now() -> chrono::DateTime<chrono::Utc> {
    chrono::Utc::now()
}
pub(crate) fn now_rfc3339() -> String {
    now().to_rfc3339()
}
pub(crate) fn sha256_hex(data: &[u8]) -> String {
    hex::encode(sha2::Sha256::digest(data))
}
pub(crate) fn is_canonical_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|id| id.to_string() == value)
}
pub(crate) fn jcs<T: Serialize>(value: &T) -> Result<Vec<u8>, ApiError> {
    serde_jcs::to_vec(value).map_err(|_| ApiError::invalid_envelope("invalid JSON envelope"))
}

pub(crate) async fn current_user(
    state: &AppState,
    headers: &axum::http::HeaderMap,
) -> Result<auth::AuthUser, ApiError> {
    auth::authenticate(state, headers).await
}

/// Authenticates a request through the backend that owns the Vault sync
/// ledger. The SQLite path remains the default; PostgreSQL sync mode never
/// consults the node-local SQLite account tables for sync principals.
pub(crate) async fn current_sync_user(
    state: &AppState,
    headers: &axum::http::HeaderMap,
) -> Result<auth::AuthUser, ApiError> {
    let Some(pg_auth) = state.pg_sync_auth.as_ref() else {
        return auth::authenticate(state, headers).await;
    };
    let token = auth::bearer_token(headers)?;
    pg_auth
        .authenticate_token_with_markers(
            token,
            auth::declares_record_schema2(headers),
            auth::declares_sync_redaction_v1(headers),
        )
        .await
}

pub(crate) async fn require_vault(
    state: &AppState,
    user_id: &str,
    vault_id: &str,
    write: bool,
) -> Result<(String, i64, i64), ApiError> {
    if let Some(pg_pool) = state.pg_sync_pool.as_ref() {
        let row = sqlx::query(
            "SELECT vm.role,v.active_epoch,v.membership_version,v.state \
             FROM vaults v \
             JOIN vault_members vm ON vm.vault_id=v.vault_id \
             JOIN users u ON u.user_id=vm.user_id \
             WHERE v.vault_id=$1 AND vm.user_id=$2 AND vm.state='active' \
               AND v.state IN ('active','deleting') AND u.status='active'",
        )
        .bind(vault_id)
        .bind(user_id)
        .fetch_optional(pg_pool)
        .await
        .map_err(ApiError::internal)?;
        let Some(row) = row else {
            return Err(ApiError::not_found());
        };
        use sqlx::Row;
        let role: String = row.try_get("role").map_err(ApiError::internal)?;
        let active_epoch: i64 = row.try_get("active_epoch").map_err(ApiError::internal)?;
        let membership_version: i64 = row
            .try_get("membership_version")
            .map_err(ApiError::internal)?;
        let status: String = row.try_get("state").map_err(ApiError::internal)?;
        if write && status == "deleting" {
            return Err(ApiError::vault_deletion_pending());
        }
        if write && role == "viewer" {
            return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
        }
        return Ok((role, active_epoch, membership_version));
    }
    let row = sqlx::query_as::<_, (String, i64, i64, String)>(
        "SELECT CASE WHEN vm.role='editor' AND EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='viewer') THEN 'viewer' ELSE vm.role END AS role,v.active_epoch,v.membership_version,v.state FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active'",
    ).bind(vault_id).bind(user_id).fetch_optional(&state.db).await.map_err(ApiError::internal)?;
    let Some((role, epoch, membership_version, status)) = row else {
        // Keep foreign vault IDs indistinguishable from absent IDs.
        return Err(ApiError::not_found());
    };
    if write && status == "deleting" {
        return Err(ApiError::vault_deletion_pending());
    }
    if write && role == "viewer" {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    Ok((role, epoch, membership_version))
}

/// Rechecks account status after acquiring SQLite's writer lock. This fences
/// in-flight writes behind a concurrent account deletion.
pub(crate) async fn require_active_account_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
) -> Result<(), ApiError> {
    let status: Option<String> = sqlx::query_scalar("SELECT status FROM users WHERE user_id=?")
        .bind(user_id)
        .fetch_optional(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if status.as_deref() == Some("active") {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

/// Reserves SQLite's writer before rechecking the authenticated principal.
/// This must run inside the same transaction as a session-bound HTTP write so
/// logout, device revocation, and account deletion are ordered with the write.
pub(crate) async fn require_active_session_device_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    let session = sqlx::query_as::<_, (Option<String>, String)>(
        "UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? AND access_hash=? RETURNING revoked_at,access_expires_at",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((revoked_at, access_expires_at)) = session else {
        return Err(ApiError::unauthorized());
    };
    if revoked_at.is_some()
        || chrono::DateTime::parse_from_rfc3339(&access_expires_at)
            .map_or(true, |expires| expires <= chrono::Utc::now())
    {
        return Err(ApiError::unauthorized());
    }

    require_active_account_tx(tx, &user.user_id).await?;
    let device_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM devices WHERE device_id=? AND user_id=?")
            .bind(&user.device_id)
            .bind(&user.user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }

    // Recheck the independent redaction marker after taking SQLite's writer
    // reservation. Authentication may have read "no report" before a
    // concurrent first publication; every session-bound write fence must
    // therefore invalidate again in this transaction.
    if !user.declares_sync_redaction_v1 {
        sqlx::query(
            "UPDATE device_redaction_capability_reports SET invalidated_at=? \
             WHERE device_id=? AND user_id=? AND invalidated_at IS NULL",
        )
        .bind(now_rfc3339())
        .bind(&user.device_id)
        .bind(&user.user_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    }
    Ok(())
}

/// Rechecks an already-authenticated collaboration socket using its immutable
/// login-session identity instead of its rotating access-token hash. Refresh
/// may replace the hash while preserving the same session; the socket remains
/// valid only while that exact session/device/account stays active and its
/// refresh lifetime has not elapsed. The no-op UPDATE acquires SQLite's writer
/// lock so revocation and account/device lifecycle changes are ordered with
/// the connection check.
pub(crate) async fn require_active_collaboration_session_tx(
    tx: &mut Transaction<'_, Sqlite>,
    session_id: &str,
    user_id: &str,
    device_id: &str,
) -> Result<(), ApiError> {
    let session = sqlx::query_as::<_, (Option<String>, String)>(
        "UPDATE sessions SET revoked_at=revoked_at WHERE session_id=? AND user_id=? AND device_id=? RETURNING revoked_at,refresh_expires_at",
    )
    .bind(session_id)
    .bind(user_id)
    .bind(device_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((revoked_at, refresh_expires_at)) = session else {
        return Err(ApiError::unauthorized());
    };
    if revoked_at.is_some()
        || chrono::DateTime::parse_from_rfc3339(&refresh_expires_at)
            .map_or(true, |expires| expires <= chrono::Utc::now())
    {
        return Err(ApiError::unauthorized());
    }

    require_active_account_tx(tx, user_id).await?;
    let device_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM devices WHERE device_id=? AND user_id=?")
            .bind(device_id)
            .bind(user_id)
            .fetch_optional(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if device_status.as_deref() != Some("active") {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

/// Rechecks a bearer principal inside the same read transaction as protected
/// data. Unlike `require_active_session_device_tx`, this helper does not
/// acquire SQLite's writer lock. Call it before any other query in a
/// read-only transaction so the session check and following data queries use
/// one SQLite snapshot.
pub(crate) async fn require_active_session_device_read_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &auth::AuthUser,
) -> Result<(), ApiError> {
    let session = sqlx::query_as::<_, (Option<String>, String, String, String)>(
        "SELECT s.revoked_at,s.access_expires_at,u.status,d.status FROM sessions s JOIN users u ON u.user_id=s.user_id JOIN devices d ON d.device_id=s.device_id WHERE s.session_id=? AND s.user_id=? AND s.device_id=? AND s.access_hash=?",
    )
    .bind(&user.session_id)
    .bind(&user.user_id)
    .bind(&user.device_id)
    .bind(&user.access_hash)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((revoked_at, access_expires_at, account_status, device_status)) = session else {
        return Err(ApiError::unauthorized());
    };
    if revoked_at.is_some()
        || chrono::DateTime::parse_from_rfc3339(&access_expires_at)
            .map_or(true, |expires| expires <= chrono::Utc::now())
        || account_status != "active"
    {
        return Err(ApiError::unauthorized());
    }
    if device_status != "active" {
        return Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        ));
    }
    Ok(())
}

/// Session-bound counterpart to `require_vault_write_tx`. The user-ID helper
/// remains available to internal maintenance and tests that have no HTTP
/// bearer session.
pub(crate) async fn require_authenticated_vault_write_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user: &auth::AuthUser,
    vault_id: &str,
) -> Result<(String, i64, i64), ApiError> {
    require_active_session_device_tx(tx, user).await?;
    let access = require_vault_write_tx(tx, &user.user_id, vault_id).await?;
    require_redaction_client_for_vault_tx(tx, vault_id, user.declares_sync_redaction_v1).await?;
    Ok(access)
}

/// Fails closed for pre-redaction clients once a Vault has a durable
/// redaction statement. Callers must invoke this only after authenticating the
/// session and checking Vault membership, in the same transaction as the
/// payload read or write.
pub(crate) async fn require_redaction_client_for_vault_tx(
    tx: &mut Transaction<'_, Sqlite>,
    vault_id: &str,
    declares_sync_redaction_v1: bool,
) -> Result<(), ApiError> {
    let has_redactions: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM record_redactions WHERE vault_id=?)")
            .bind(vault_id)
            .fetch_one(&mut **tx)
            .await
            .map_err(ApiError::internal)?;
    if has_redactions && !declares_sync_redaction_v1 {
        return Err(ApiError::new(
            axum::http::StatusCode::UPGRADE_REQUIRED,
            "CLIENT_REDACTION_CAPABILITY_REQUIRED",
            "this Vault contains redacted records and requires a compatible client",
        ));
    }
    Ok(())
}

/// Rechecks membership and deletion state after the caller has begun its
/// mutation transaction. The no-op update acquires SQLite's writer lock so a
/// concurrent delete, cancel, or purge is ordered before or after this write.
pub(crate) async fn require_vault_write_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    vault_id: &str,
) -> Result<(String, i64, i64), ApiError> {
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(vault_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    require_active_account_tx(tx, user_id).await?;
    let row = sqlx::query_as::<_, (String, i64, i64, String)>(
        "SELECT CASE WHEN vm.role='editor' AND EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='viewer') THEN 'viewer' ELSE vm.role END AS role,v.active_epoch,v.membership_version,v.state FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none')",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let Some((role, epoch, membership_version, status)) = row else {
        return Err(ApiError::not_found());
    };
    if status == "deleting" {
        return Err(ApiError::vault_deletion_pending());
    }
    if role == "viewer" {
        return Err(ApiError::forbidden("VAULT_READ_ONLY", "vault is read-only"));
    }
    Ok((role, epoch, membership_version))
}

/// Rechecks active membership while serializing an export/read transaction
/// against the final purge. Deleting vaults remain readable until purge wins
/// the SQLite writer lock; this helper intentionally imposes no role check.
pub(crate) async fn require_vault_read_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    vault_id: &str,
) -> Result<(String, i64, i64, String), ApiError> {
    let locked = sqlx::query("UPDATE vaults SET state=state WHERE vault_id=?")
        .bind(vault_id)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
    if locked.rows_affected() == 0 {
        return Err(ApiError::not_found());
    }
    require_active_account_tx(tx, user_id).await?;
    let row = sqlx::query_as::<_, (String, i64, i64, String)>(
        "SELECT CASE WHEN vm.role='editor' AND EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='viewer') THEN 'viewer' ELSE vm.role END AS role,v.active_epoch,v.membership_version,v.state FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none')",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    row.ok_or_else(ApiError::not_found)
}

/// Checks Vault read access without upgrading a read transaction to a writer.
/// Use for read-only endpoints that bind this authorization check and data
/// retrieval to one SQLite snapshot rather than serializing with all writers.
pub(crate) async fn require_vault_read_snapshot_tx(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: &str,
    vault_id: &str,
) -> Result<(), ApiError> {
    let member: Option<i64> = sqlx::query_scalar(
        "SELECT 1 FROM vaults v JOIN vault_members vm ON vm.vault_id=v.vault_id JOIN users u ON u.user_id=vm.user_id WHERE v.vault_id=? AND vm.user_id=? AND vm.state='active' AND NOT EXISTS(SELECT 1 FROM cloud_member_restrictions cr WHERE cr.vault_id=vm.vault_id AND cr.user_id=vm.user_id AND cr.max_role='none') AND u.status='active'",
    )
    .bind(vault_id)
    .bind(user_id)
    .fetch_optional(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    if member.is_some() {
        Ok(())
    } else {
        Err(ApiError::not_found())
    }
}

pub(crate) async fn ensure_active_device(
    state: &AppState,
    user_id: &str,
    device_id: &str,
) -> Result<String, ApiError> {
    let status: Option<String> =
        sqlx::query_scalar("SELECT status FROM devices WHERE device_id=? AND user_id=?")
            .bind(device_id)
            .bind(user_id)
            .fetch_optional(&state.db)
            .await
            .map_err(ApiError::internal)?;
    match status.as_deref() {
        Some("active") => Ok(device_id.to_owned()),
        _ => Err(ApiError::forbidden(
            "DEVICE_REVOKED",
            "device is not active",
        )),
    }
}

#[cfg(test)]
mod config_tests {
    use super::{
        DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP, IpNet, MAX_ACTIVE_RECOVERY_CHALLENGE_CAP,
        MAX_BACKUP_RETENTION_COUNT, VaultLimits, acquire_maintenance_run_lock, bounded_value,
        parse_admin_usernames, parse_backup_retention_count, parse_relay_allow_cidrs,
        parse_relay_allow_ports,
    };
    use crate::relay;
    use std::ffi::OsStr;

    #[test]
    fn vault_limits_default_and_bound_operator_overrides() {
        assert_eq!(
            VaultLimits::from_values(None, None),
            VaultLimits {
                max_vaults_per_user: 50,
                max_members_per_vault: 100,
            }
        );
        assert_eq!(
            VaultLimits::from_values(Some("4096".into()), Some("1000".into())),
            VaultLimits {
                max_vaults_per_user: 4096,
                max_members_per_vault: 1000,
            }
        );
        assert_eq!(
            VaultLimits::from_values(Some("1".into()), Some("1".into())),
            VaultLimits {
                max_vaults_per_user: 1,
                max_members_per_vault: 1,
            }
        );
        for invalid in ["0", "4097", "-1", "many"] {
            assert_eq!(
                VaultLimits::from_values(Some(invalid.into()), Some(invalid.into())),
                VaultLimits {
                    max_vaults_per_user: 50,
                    max_members_per_vault: 100,
                },
                "invalid bounded limit {invalid:?} must fall back to its default"
            );
        }
    }

    #[test]
    fn active_recovery_challenge_cap_defaults_and_bounds_operator_override() {
        const DEFAULT: i64 = DEFAULT_ACTIVE_RECOVERY_CHALLENGE_CAP;
        const MAXIMUM: i64 = MAX_ACTIVE_RECOVERY_CHALLENGE_CAP;
        assert_eq!(bounded_value(None, DEFAULT, 1, MAXIMUM), DEFAULT);
        assert_eq!(bounded_value(Some("1".into()), DEFAULT, 1, MAXIMUM), 1);
        assert_eq!(
            bounded_value(Some(MAXIMUM.to_string()), DEFAULT, 1, MAXIMUM),
            MAXIMUM
        );
        for invalid in ["0", "100001", "-1", "not-a-number"] {
            assert_eq!(
                bounded_value(Some(invalid.into()), DEFAULT, 1, MAXIMUM),
                DEFAULT,
                "invalid Recovery capacity {invalid:?} must fall back to its default"
            );
        }
    }

    #[test]
    fn backup_retention_count_is_optional_and_strictly_bounded() {
        assert_eq!(parse_backup_retention_count(None), Ok(None));
        assert_eq!(
            parse_backup_retention_count(Some(OsStr::new("1"))),
            Ok(Some(1))
        );
        assert_eq!(
            parse_backup_retention_count(Some(OsStr::new("1000"))),
            Ok(Some(MAX_BACKUP_RETENTION_COUNT))
        );
        for invalid in ["", "0", "-1", "+1", "1001", "1.0", " 2", "2 ", "many"] {
            assert!(
                parse_backup_retention_count(Some(OsStr::new(invalid))).is_err(),
                "invalid retention count {invalid:?} must fail closed"
            );
        }
        #[cfg(unix)]
        {
            use std::os::unix::ffi::OsStrExt;
            assert!(parse_backup_retention_count(Some(OsStr::from_bytes(b"\xff"))).is_err());
        }
    }

    #[test]
    fn instance_admin_allowlist_normalizes_deduplicates_and_fails_closed() {
        assert_eq!(parse_admin_usernames(None), Vec::<String>::new());
        assert_eq!(parse_admin_usernames(Some("  ")), Vec::<String>::new());
        assert_eq!(
            parse_admin_usernames(Some(" Admin@Example.TEST,admin@example.test ")),
            ["admin@example.test"]
        );
        assert_eq!(
            parse_admin_usernames(Some("admin@example.test,not-an-email")),
            Vec::<String>::new()
        );
    }

    #[test]
    fn relay_cidr_ceiling_is_all_or_empty_normalized_and_bounded() {
        assert_eq!(parse_relay_allow_cidrs(None), Vec::<IpNet>::new());
        assert_eq!(parse_relay_allow_cidrs(Some("  ")), Vec::<IpNet>::new());
        assert_eq!(
            parse_relay_allow_cidrs(Some("172.19.0.1/24, 2001:DB8::/32,172.19.0.0/24")),
            [
                "172.19.0.0/24".parse::<IpNet>().unwrap(),
                "2001:db8::/32".parse::<IpNet>().unwrap()
            ]
        );
        for malformed in [
            "10.0.0.0/8,not-a-network",
            "10.0.0.0/8,",
            ",10.0.0.0/8",
            "10.0.0.0/8,,192.168.0.0/16",
        ] {
            assert_eq!(
                parse_relay_allow_cidrs(Some(malformed)),
                Vec::<IpNet>::new(),
                "malformed ceiling {malformed:?} must fail closed as a whole"
            );
        }
        let too_long = format!("{}/8", "1".repeat(65));
        assert!(parse_relay_allow_cidrs(Some(&too_long)).is_empty());
        let too_many = vec!["10.0.0.0/8"; relay::MAX_RELAY_POLICY_CIDRS + 1].join(",");
        assert!(parse_relay_allow_cidrs(Some(&too_many)).is_empty());
    }

    #[test]
    fn relay_port_allowlist_is_exact_and_invalid_values_fail_closed() {
        assert_eq!(parse_relay_allow_ports(None), Vec::<u16>::new());
        assert_eq!(parse_relay_allow_ports(Some("  ")), Vec::<u16>::new());
        assert_eq!(parse_relay_allow_ports(Some("22, 2222,22")), [22, 2222]);
        for invalid in ["22,0", "22,65536", "22,ssh", ",22", "22,"] {
            assert_eq!(
                parse_relay_allow_ports(Some(invalid)),
                Vec::<u16>::new(),
                "invalid allowlist {invalid:?} must fail closed"
            );
        }
        let too_many = vec!["22"; relay::MAX_RELAY_POLICY_PORTS + 1].join(",");
        assert!(parse_relay_allow_ports(Some(&too_many)).is_empty());
    }

    #[test]
    fn object_gc_grace_configuration_is_bounded() {
        const DEFAULT: i64 = 7 * 24 * 60 * 60;
        const MAXIMUM: i64 = 90 * 24 * 60 * 60;
        assert_eq!(bounded_value(None, DEFAULT, 60, MAXIMUM), DEFAULT);
        assert_eq!(bounded_value(Some("60".into()), DEFAULT, 60, MAXIMUM), 60);
        assert_eq!(
            bounded_value(Some(MAXIMUM.to_string()), DEFAULT, 60, MAXIMUM),
            MAXIMUM
        );
        for invalid in ["59", "7776001", "-1", "not-a-number"] {
            assert_eq!(
                bounded_value(Some(invalid.into()), DEFAULT, 60, MAXIMUM),
                DEFAULT
            );
        }
    }

    #[test]
    fn account_deletion_grace_configuration_is_bounded() {
        const DEFAULT: i64 = 7 * 24 * 60 * 60;
        const MAXIMUM: i64 = 90 * 24 * 60 * 60;
        assert_eq!(bounded_value(None, DEFAULT, 60, MAXIMUM), DEFAULT);
        assert_eq!(bounded_value(Some("60".into()), DEFAULT, 60, MAXIMUM), 60);
        assert_eq!(
            bounded_value(Some(MAXIMUM.to_string()), DEFAULT, 60, MAXIMUM),
            MAXIMUM
        );
        for invalid in ["59", "7776001", "-1", "not-a-number"] {
            assert_eq!(
                bounded_value(Some(invalid.into()), DEFAULT, 60, MAXIMUM),
                DEFAULT
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn runtime_lock_is_owner_only_and_rejects_symlinks() {
        use std::{
            fs,
            os::unix::fs::{PermissionsExt, symlink},
        };

        let data_dir =
            std::env::temp_dir().join(format!("atermius-runtime-lock-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&data_dir).unwrap();
        fs::set_permissions(&data_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let lock = super::acquire_runtime_lock(&data_dir).unwrap();
        assert_eq!(
            fs::metadata(data_dir.join("server.lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        drop(lock);

        fs::remove_file(data_dir.join("server.lock")).unwrap();
        let outside = data_dir.with_extension("lock-target");
        fs::write(&outside, b"not a lock").unwrap();
        symlink(&outside, data_dir.join("server.lock")).unwrap();
        assert!(super::acquire_runtime_lock(&data_dir).is_err());

        fs::remove_dir_all(data_dir).unwrap();
        fs::remove_file(outside).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn maintenance_run_lock_is_private_and_excludes_another_app_state() {
        use std::{fs, os::unix::fs::PermissionsExt};

        let data_dir = std::env::temp_dir().join(format!(
            "atermius-maintenance-file-lock-{}",
            uuid::Uuid::new_v4()
        ));
        fs::create_dir(&data_dir).unwrap();
        fs::set_permissions(&data_dir, fs::Permissions::from_mode(0o700)).unwrap();
        let lock = acquire_maintenance_run_lock(&data_dir).unwrap();
        assert_eq!(
            fs::metadata(data_dir.join("maintenance.lock"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        let conflict = acquire_maintenance_run_lock(&data_dir).unwrap_err();
        assert_eq!(conflict.body.code, "MAINTENANCE_ALREADY_RUNNING");
        drop(lock);
        acquire_maintenance_run_lock(&data_dir).unwrap();
        fs::remove_dir_all(data_dir).unwrap();
    }
}

#[cfg(test)]
mod web_security_tests {
    use super::{
        Request, Router, api_cors_layer, apply_response_security_headers, request_id_context,
    };
    use axum::{body::Body, routing::get};
    use tower::ServiceExt;

    #[tokio::test]
    async fn browser_responses_receive_security_headers_and_path_scoped_cache_policy() {
        let app = Router::new()
            .route("/api/v1/audit", get(|| async { "ok" }))
            .route("/workspace", get(|| async { "ok" }))
            .layer(axum::middleware::from_fn(apply_response_security_headers));

        for (path, expected_cache) in [("/api/v1/audit", "no-store"), ("/workspace", "no-cache")] {
            let response = app
                .clone()
                .oneshot(Request::builder().uri(path).body(Body::empty()).unwrap())
                .await
                .unwrap();
            let headers = response.headers();
            assert!(
                headers["Content-Security-Policy"]
                    .to_str()
                    .unwrap()
                    .contains("frame-ancestors 'none'")
            );
            assert!(
                headers["Content-Security-Policy"]
                    .to_str()
                    .unwrap()
                    .contains("script-src 'self' 'wasm-unsafe-eval'")
            );
            assert_eq!(headers["X-Content-Type-Options"], "nosniff");
            assert_eq!(headers["X-Frame-Options"], "DENY");
            assert_eq!(headers["Referrer-Policy"], "no-referrer");
            assert_eq!(headers["Cache-Control"], expected_cache);
        }
    }

    #[tokio::test]
    async fn capability_and_attachment_cors_preflight_is_exact_origin_only() {
        let expected_origin = "https://web.example.test";
        let Some(cors) = api_cors_layer(Some(expected_origin)) else {
            panic!("valid exact origin must enable API CORS");
        };
        assert!(api_cors_layer(None).is_none());
        let app = Router::new()
            .route("/api/v1/objects", axum::routing::get(|| async { "ok" }))
            .layer(cors)
            .layer(axum::middleware::from_fn(request_id_context));

        let allowed = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri("/api/v1/objects")
                    .header("origin", expected_origin)
                    .header("access-control-request-method", "GET")
                    .header(
                        "access-control-request-headers",
                        "authorization,content-type,x-atermius-capability-marker,x-atermius-redaction-marker,range,if-range,x-content-sha256",
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(allowed.status(), axum::http::StatusCode::OK);
        let headers = allowed.headers();
        assert_eq!(headers["access-control-allow-origin"], expected_origin);
        let allowed_headers = headers["access-control-allow-headers"]
            .to_str()
            .unwrap()
            .to_ascii_lowercase();
        for required in [
            "authorization",
            "content-type",
            "x-atermius-capability-marker",
            "x-atermius-redaction-marker",
            "range",
            "if-range",
            "x-content-sha256",
        ] {
            assert!(allowed_headers.contains(required), "missing {required}");
        }

        let actual = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/v1/objects")
                    .header("origin", expected_origin)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let exposed = actual.headers()["access-control-expose-headers"]
            .to_str()
            .unwrap()
            .to_ascii_lowercase();
        for required in ["etag", "content-range", "accept-ranges"] {
            assert!(
                exposed.contains(required),
                "missing exposed header {required}"
            );
        }
        assert!(exposed.contains("x-request-id"));
        assert!(actual.headers().contains_key("x-request-id"));

        let rejected = app
            .oneshot(
                Request::builder()
                    .method("OPTIONS")
                    .uri("/api/v1/objects")
                    .header("origin", "https://attacker.example")
                    .header("access-control-request-method", "GET")
                    .header(
                        "access-control-request-headers",
                        "authorization,x-atermius-capability-marker",
                    )
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        // The configured origin may be emitted as a fixed value. A browser
        // at the attacker origin still rejects it because it does not match
        // its own Origin; the server must never echo the untrusted origin.
        assert_ne!(
            rejected
                .headers()
                .get("access-control-allow-origin")
                .and_then(|value| value.to_str().ok()),
            Some("https://attacker.example"),
        );
    }
}

#[cfg(test)]
mod request_id_tests {
    use super::{Request, Router, make_http_request_span, request_id_context};
    use crate::ApiError;
    use axum::{body::Body, routing::post};
    use std::{
        io,
        sync::{Arc, Mutex},
        time::Duration,
    };
    use tower::ServiceExt;
    use tower_http::trace::TraceLayer;
    use tracing_subscriber::fmt::format::FmtSpan;

    #[derive(Clone)]
    struct SharedLog(Arc<Mutex<Vec<u8>>>);

    impl io::Write for SharedLog {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for SharedLog {
        type Writer = Self;

        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn generated_request_id_matches_api_error_header_and_trace_without_logging_secrets() {
        let captured_logs = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_max_level(tracing::Level::TRACE)
            .with_span_events(FmtSpan::NEW)
            .with_writer(SharedLog(captured_logs.clone()))
            .finish();
        let _subscriber_guard = tracing::subscriber::set_default(subscriber);

        let app = Router::new()
            .route(
                "/api/v1/test-error",
                post(|| async { Err::<&'static str, _>(ApiError::internal("INTERNAL_SENTINEL")) }),
            )
            .layer(
                TraceLayer::new_for_http()
                    .make_span_with(make_http_request_span)
                    .on_failure(|_failure, latency: Duration, span: &tracing::Span| {
                        tracing::error!(
                            parent: span,
                            latency_ms = latency.as_millis() as u64,
                            error_category = "transport_or_server",
                            "HTTP request failed"
                        );
                    }),
            )
            .layer(axum::middleware::from_fn(request_id_context));

        let response = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/v1/test-error?query_marker=QUERY_SECRET")
                    .header("x-request-id", "caller-controlled-id/secret")
                    .header("authorization", "Bearer AUTH_SECRET")
                    .header("content-type", "text/plain")
                    .body(Body::from("BODY_SECRET"))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            axum::http::StatusCode::INTERNAL_SERVER_ERROR
        );
        let header_id = response
            .headers()
            .get("x-request-id")
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        let parsed_id = uuid::Uuid::parse_str(&header_id).unwrap();
        assert_eq!(parsed_id.to_string(), header_id, "ID must be canonical");
        let body = axum::body::to_bytes(response.into_body(), 16 * 1024)
            .await
            .unwrap();
        let body: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(body["error"]["request_id"], header_id);
        assert_eq!(body["error"]["code"], "INTERNAL");
        assert_eq!(body["error"]["message"], "request could not be completed");
        assert!(!body.to_string().contains("INTERNAL_SENTINEL"));

        let logs = String::from_utf8(captured_logs.lock().unwrap().clone()).unwrap();
        assert!(
            logs.contains(&header_id),
            "request trace must carry response ID"
        );
        assert!(
            logs.lines()
                .any(|line| line.contains("http.request") && line.contains(&header_id)),
            "the tracing span itself must carry the response ID"
        );
        assert!(
            logs.contains("INTERNAL"),
            "safe API error category is logged"
        );
        for secret in [
            "caller-controlled-id",
            "QUERY_SECRET",
            "AUTH_SECRET",
            "BODY_SECRET",
            "INTERNAL_SENTINEL",
        ] {
            assert!(!logs.contains(secret), "logs leaked {secret}");
        }
    }
}

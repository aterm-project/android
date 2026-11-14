//! Shared configuration and runtime state for cloud collaboration:
//! organizations, temporary share links, guest sessions and the trusted
//! share gateway.
//!
//! Everything here is SQLite-only. In the PostgreSQL sync-core runtime the
//! routes are not registered and no capability is advertised (fail closed).
use std::{
    collections::{HashMap, VecDeque},
    net::IpAddr,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use axum::http::{HeaderMap, StatusCode, header::ORIGIN};
use ipnet::IpNet;
use sqlx::{Sqlite, SqlitePool, Transaction};
use tokio::sync::{Semaphore, broadcast};

use crate::{ApiError, AppState, Config};

pub(crate) const DEFAULT_LINK_LIFETIME_SECONDS: i64 = 24 * 60 * 60;
pub(crate) const DEFAULT_MAX_LINK_LIFETIME_SECONDS: i64 = 30 * 24 * 60 * 60;
pub(crate) const HARD_MAX_LINK_LIFETIME_SECONDS: i64 = 90 * 24 * 60 * 60;
pub(crate) const DEFAULT_GUEST_SESSION_SECONDS: i64 = 2 * 60 * 60;
pub(crate) const MAX_GUEST_SESSION_SECONDS: i64 = 12 * 60 * 60;
pub(crate) const GUEST_IDLE_SECONDS: i64 = 15 * 60;
pub(crate) const DEFAULT_MAX_GUEST_CONNECTIONS: usize = 32;

/// Operator configuration. Defaults keep every sharing path closed until the
/// required origin, gateway key, guacd and target policy are all present.
#[derive(Debug, Clone)]
pub(crate) struct CloudConfig {
    pub(crate) links_enabled: bool,
    pub(crate) gateway_key_file: Option<PathBuf>,
    pub(crate) allow_cidrs: Vec<IpNet>,
    pub(crate) allow_ports: Vec<u16>,
    pub(crate) deny_cidrs: Vec<IpNet>,
    pub(crate) vnc_enabled: bool,
    pub(crate) max_link_lifetime_seconds: i64,
    pub(crate) max_guest_connections: usize,
    pub(crate) max_display_width: u16,
    pub(crate) max_display_height: u16,
    pub(crate) organizations_enabled: bool,
    pub(crate) org_creation_any: bool,
    /// Successful-or-not redemption attempts per client IP per minute
    /// (default 10; the per-hour ceiling is six times this value).
    pub(crate) redeem_ip_per_minute: usize,
    /// Malformed settings are recorded so startup can refuse to enable a
    /// partial policy instead of silently widening it.
    pub(crate) config_errors: Vec<&'static str>,
    /// Malformed organization settings keep organizations closed.
    pub(crate) org_config_errors: Vec<&'static str>,
}

/// Reads optional operator settings. ABSENT selects the documented default;
/// PRESENT but malformed (including empty or out-of-range) is recorded as a
/// configuration error, which keeps the affected feature closed instead of
/// silently falling back to a broader default.
struct Settings<'a> {
    lookup: &'a dyn Fn(&str) -> Option<std::ffi::OsString>,
    errors: Vec<&'static str>,
}

impl Settings<'_> {
    fn raw(&mut self, name: &'static str) -> Option<String> {
        let value = (self.lookup)(name)?;
        match value.into_string() {
            Ok(text) if !text.trim().is_empty() => Some(text.trim().to_owned()),
            _ => {
                self.errors.push(name);
                None
            }
        }
    }

    fn boolean(&mut self, name: &'static str, default: bool) -> bool {
        match self.raw(name).as_deref() {
            None => default,
            Some("true") => true,
            Some("false") => false,
            Some(_) => {
                self.errors.push(name);
                default
            }
        }
    }

    fn number<T: std::str::FromStr + PartialOrd + Copy>(&mut self, name: &'static str, default: T, min: T, max: T) -> T {
        match self.raw(name) {
            None => default,
            Some(text) => match text.parse::<T>() {
                Ok(value) if value >= min && value <= max => value,
                _ => {
                    self.errors.push(name);
                    default
                }
            },
        }
    }

    fn cidrs(&mut self, name: &'static str) -> Vec<IpNet> {
        let Some(value) = self.raw(name) else {
            return Vec::new();
        };
        let mut result = Vec::new();
        for entry in value.split(',') {
            match entry.trim().parse::<IpNet>() {
                Ok(network) if result.len() < 256 => result.push(network.trunc()),
                _ => {
                    self.errors.push(name);
                    return Vec::new();
                }
            }
        }
        result.sort_by_key(ToString::to_string);
        result.dedup();
        result
    }

    fn ports(&mut self, name: &'static str, default: &[u16]) -> Vec<u16> {
        let Some(value) = self.raw(name) else {
            return default.to_vec();
        };
        let mut ports = Vec::new();
        for entry in value.split(',') {
            match entry.trim().parse::<u16>() {
                Ok(port) if port != 0 && ports.len() < 256 => ports.push(port),
                _ => {
                    self.errors.push(name);
                    return Vec::new();
                }
            }
        }
        ports.sort_unstable();
        ports.dedup();
        ports
    }
}

impl CloudConfig {
    pub(crate) fn from_env() -> Self {
        Self::from_lookup(&|name| std::env::var_os(name))
    }

    pub(crate) fn from_lookup(lookup: &dyn Fn(&str) -> Option<std::ffi::OsString>) -> Self {
        let mut settings = Settings { lookup, errors: Vec::new() };
        let links_enabled = settings.boolean("ATERMIUS_SHARE_LINKS_ENABLED", false);
        let gateway_key_file = settings.raw("ATERMIUS_SHARE_GATEWAY_KEY_FILE").map(PathBuf::from);
        let allow_cidrs = settings.cidrs("ATERMIUS_SHARE_ALLOW_CIDRS");
        let deny_cidrs = settings.cidrs("ATERMIUS_SHARE_DENY_CIDRS");
        let allow_ports = settings.ports("ATERMIUS_SHARE_ALLOW_PORTS", &[22, 3389]);
        let vnc_enabled = settings.boolean("ATERMIUS_SHARE_VNC_ENABLED", false);
        let max_link_lifetime_seconds = settings.number(
            "ATERMIUS_SHARE_MAX_LINK_LIFETIME_SECONDS",
            DEFAULT_MAX_LINK_LIFETIME_SECONDS,
            3600,
            HARD_MAX_LINK_LIFETIME_SECONDS,
        );
        let max_guest_connections = settings.number(
            "ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS",
            DEFAULT_MAX_GUEST_CONNECTIONS,
            1,
            1024,
        );
        let redeem_ip_per_minute = settings.number("ATERMIUS_SHARE_REDEEM_IP_LIMIT_PER_MINUTE", 10_usize, 1, 1000);
        let max_display_width = settings.number("ATERMIUS_SHARE_MAX_DISPLAY_WIDTH", 1920_u16, 320, 4096);
        let max_display_height = settings.number("ATERMIUS_SHARE_MAX_DISPLAY_HEIGHT", 1200_u16, 200, 4096);
        let config_errors = std::mem::take(&mut settings.errors);
        let organizations_enabled = settings.boolean("ATERMIUS_ORGANIZATIONS_ENABLED", true);
        let org_creation_any = match settings.raw("ATERMIUS_ORG_CREATION").as_deref() {
            None | Some("admin") => false,
            Some("any") => true,
            Some(_) => {
                settings.errors.push("ATERMIUS_ORG_CREATION");
                false
            }
        };
        Self {
            links_enabled,
            gateway_key_file,
            allow_cidrs,
            allow_ports,
            deny_cidrs,
            vnc_enabled,
            max_link_lifetime_seconds,
            max_guest_connections,
            max_display_width,
            max_display_height,
            organizations_enabled,
            org_creation_any,
            redeem_ip_per_minute,
            config_errors,
            org_config_errors: settings.errors,
        }
    }

    #[cfg(test)]
    pub(crate) fn for_tests() -> Self {
        Self {
            links_enabled: true,
            gateway_key_file: None,
            allow_cidrs: vec!["10.0.0.0/8".parse().unwrap(), "192.0.2.0/24".parse().unwrap()],
            allow_ports: vec![22, 3389],
            deny_cidrs: vec!["10.99.0.0/16".parse().unwrap()],
            vnc_enabled: false,
            max_link_lifetime_seconds: DEFAULT_MAX_LINK_LIFETIME_SECONDS,
            max_guest_connections: DEFAULT_MAX_GUEST_CONNECTIONS,
            max_display_width: 1920,
            max_display_height: 1200,
            organizations_enabled: true,
            org_creation_any: true,
            redeem_ip_per_minute: 10,
            config_errors: Vec::new(),
            org_config_errors: Vec::new(),
        }
    }
}

/// Narrowing changes that require active gateway sockets to recheck now.
#[derive(Debug, Clone)]
pub(crate) enum RevocationEvent {
    Link(String),
    GuestSession(String),
}

#[derive(Default)]
pub(crate) struct RateLimiter {
    windows: Mutex<HashMap<String, VecDeque<i64>>>,
}

impl RateLimiter {
    /// Sliding-window limiter. Returns `Err(retry_after)` when `key` already
    /// has `limit` events within `window` seconds; otherwise records one.
    /// Returns `Err(retry_after)` when `key` already reached `limit` events
    /// in the window, without recording a new event.
    pub(crate) fn blocked(&self, key: &str, limit: usize, window: i64, now: i64) -> Result<(), u64> {
        let Ok(mut windows) = self.windows.lock() else {
            return Err(window as u64);
        };
        let Some(events) = windows.get_mut(key) else {
            return Ok(());
        };
        while events.front().is_some_and(|first| *first <= now - window) {
            events.pop_front();
        }
        if events.len() >= limit {
            let oldest = events.front().copied().unwrap_or(now);
            return Err((oldest + window - now).max(1) as u64);
        }
        Ok(())
    }

    pub(crate) fn record(&self, key: &str, now: i64) {
        if let Ok(mut windows) = self.windows.lock() {
            windows.entry(key.to_owned()).or_default().push_back(now);
        }
    }

    pub(crate) fn check(&self, key: &str, limit: usize, window: i64, now: i64) -> Result<(), u64> {
        let Ok(mut windows) = self.windows.lock() else {
            return Err(window as u64);
        };
        if windows.len() > 100_000 {
            windows.retain(|_, events| events.back().is_some_and(|last| *last > now - 3600));
        }
        let events = windows.entry(key.to_owned()).or_default();
        while events.front().is_some_and(|first| *first <= now - window) {
            events.pop_front();
        }
        if events.len() >= limit {
            let oldest = events.front().copied().unwrap_or(now);
            return Err((oldest + window - now).max(1) as u64);
        }
        events.push_back(now);
        Ok(())
    }
}

pub(crate) struct CloudState {
    pub(crate) config: CloudConfig,
    pub(crate) gateway: Option<crate::share_gateway::GatewayKey>,
    pub(crate) revocations: broadcast::Sender<RevocationEvent>,
    pub(crate) guest_connection_slots: Arc<Semaphore>,
    pub(crate) rate: RateLimiter,
    pub(crate) resolver: Arc<dyn crate::share_gateway::ShareResolver>,
    /// Test-only artificial delay of every gateway authorization recheck.
    #[cfg(test)]
    pub(crate) recheck_delay_ms: std::sync::atomic::AtomicU64,
}

impl CloudState {
    pub(crate) fn disabled() -> Self {
        let mut config = CloudConfig::from_env();
        config.links_enabled = false;
        config.organizations_enabled = false;
        Self::with(config, None)
    }

    pub(crate) fn with(config: CloudConfig, gateway: Option<crate::share_gateway::GatewayKey>) -> Self {
        let (revocations, _) = broadcast::channel(1024);
        Self {
            guest_connection_slots: Arc::new(Semaphore::new(config.max_guest_connections)),
            config,
            gateway,
            revocations,
            rate: RateLimiter::default(),
            resolver: Arc::new(crate::share_gateway::SystemShareResolver),
            #[cfg(test)]
            recheck_delay_ms: std::sync::atomic::AtomicU64::new(0),
        }
    }

    /// Loads configuration and the gateway key. A configured gateway key file
    /// inside the data directory is refused: instance backups archive the
    /// data directory and must never contain the gateway private key.
    pub(crate) async fn open(
        db: &SqlitePool,
        config: &Config,
        signing_key: &ed25519_dalek::SigningKey,
        instance_id: &str,
        pg_mode: bool,
    ) -> Result<Self, ApiError> {
        if pg_mode {
            return Ok(Self::disabled());
        }
        let cloud = CloudConfig::from_env();
        if !cloud.org_config_errors.is_empty() {
            tracing::warn!(
                event = "cloud_organization_config_invalid",
                settings = ?cloud.org_config_errors,
                "organization configuration is malformed; organizations stay disabled"
            );
        }
        if !cloud.config_errors.is_empty() {
            tracing::warn!(
                event = "cloud_sharing_config_invalid",
                settings = ?cloud.config_errors,
                "share link configuration is malformed; sharing stays disabled"
            );
        }
        let gateway = match cloud.gateway_key_file.as_ref() {
            Some(path) if cloud.links_enabled && cloud.config_errors.is_empty() => Some(
                crate::share_gateway::GatewayKey::load_or_create(
                    db,
                    path,
                    &config.data_dir,
                    signing_key,
                    instance_id,
                )
                .await?,
            ),
            _ => None,
        };
        Ok(Self::with(cloud, gateway))
    }

    #[cfg(test)]
    pub(crate) fn test_recheck_delay(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.recheck_delay_ms.load(std::sync::atomic::Ordering::Relaxed))
    }

    pub(crate) fn notify(&self, event: RevocationEvent) {
        let _ = self.revocations.send(event);
    }
}

/// True only when every prerequisite of the trusted-gateway link feature is
/// configured. Capabilities, management routes and guest routes all use it.
pub(crate) fn share_links_ready(state: &AppState) -> bool {
    let cloud = &state.cloud.config;
    !state.pg_sync_only
        && cloud.links_enabled
        && cloud.config_errors.is_empty()
        && state.cloud.gateway.is_some()
        && state.config.guacd_address.is_some()
        && state
            .config
            .public_origin
            .as_deref()
            .is_some_and(|origin| !origin.trim().is_empty())
        && !cloud.allow_cidrs.is_empty()
        && !cloud.allow_ports.is_empty()
}

pub(crate) fn organizations_ready(state: &AppState) -> bool {
    !state.pg_sync_only
        && state.cloud.config.organizations_enabled
        && state.cloud.config.org_config_errors.is_empty()
}

pub(crate) fn sharing_disabled() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "GATEWAY_DISABLED",
        "temporary sharing is not configured on this server",
    )
}

pub(crate) fn organizations_disabled() -> ApiError {
    ApiError::new(
        StatusCode::SERVICE_UNAVAILABLE,
        "ORGANIZATIONS_DISABLED",
        "organizations are not enabled on this server",
    )
}

/// Begins a transaction that takes SQLite's writer reservation first, so a
/// later read-then-write sequence cannot fail with an unretryable
/// SQLITE_BUSY snapshot upgrade under concurrency. Only valid when sharing
/// is ready (the active gateway key row always exists then).
pub(crate) async fn begin_write(db: &SqlitePool) -> Result<Transaction<'_, Sqlite>, ApiError> {
    let mut tx = db.begin().await.map_err(ApiError::internal)?;
    sqlx::query("UPDATE share_gateway_keys SET state=state WHERE state='active'")
        .execute(&mut *tx)
        .await
        .map_err(ApiError::internal)?;
    Ok(tx)
}

pub(crate) fn now_epoch() -> i64 {
    chrono::Utc::now().timestamp()
}

pub(crate) fn epoch_rfc3339(epoch: i64) -> String {
    chrono::DateTime::<chrono::Utc>::from_timestamp(epoch, 0)
        .map(|value| value.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_default()
}

pub(crate) fn parse_rfc3339_epoch(value: &str) -> Option<i64> {
    if value.len() > 40 {
        return None;
    }
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|value| value.timestamp())
}

pub(crate) fn random_token() -> String {
    use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
    use rand::RngCore;
    let mut raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut raw);
    URL_SAFE_NO_PAD.encode(raw)
}

/// Accepts exactly a 43-character canonical base64url encoding of 32 bytes.
pub(crate) fn is_token(value: &str) -> bool {
    crate::relay::is_valid_ticket(value)
}

pub(crate) fn token_hash(value: &str) -> String {
    crate::sha256_hex(value.as_bytes())
}

pub(crate) fn exact_origin(state: &AppState, headers: &HeaderMap) -> bool {
    let Some(expected) = state.config.public_origin.as_deref() else {
        return false;
    };
    let mut values = headers.get_all(ORIGIN).iter();
    matches!(
        (values.next(), values.next()),
        (Some(value), None) if value.to_str().ok() == Some(expected)
    )
}

/// Coarse, non-identifying client network for owner activity views.
pub(crate) fn ip_prefix(ip: IpAddr) -> String {
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, c, _] = v4.octets();
            format!("{a}.{b}.{c}.0/24")
        }
        IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => ip_prefix(IpAddr::V4(v4)),
            None => {
                let s = v6.segments();
                format!("{:x}:{:x}:{:x}::/48", s[0], s[1], s[2])
            }
        },
    }
}

/// Coarse browser family; never the raw User-Agent string.
pub(crate) fn ua_family(headers: &HeaderMap) -> &'static str {
    let ua = headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("");
    if ua.contains("Edg/") {
        "edge"
    } else if ua.contains("Firefox/") {
        "firefox"
    } else if ua.contains("Chrome/") || ua.contains("Chromium/") {
        "chromium"
    } else if ua.contains("Safari/") {
        "safari"
    } else if ua.is_empty() {
        "none"
    } else {
        "other"
    }
}

pub(crate) struct AuditEntry<'a> {
    pub(crate) scope_type: &'static str,
    pub(crate) scope_id: &'a str,
    pub(crate) link_id: Option<&'a str>,
    pub(crate) guest_session_id: Option<&'a str>,
    pub(crate) connection_id: Option<&'a str>,
    pub(crate) actor_user_id: Option<&'a str>,
    pub(crate) action: &'static str,
    pub(crate) result: &'static str,
    /// Metadata only: field names, codes, coarse network. Callers must never
    /// pass tokens, credentials, envelopes or user content here.
    pub(crate) detail: Option<String>,
}

impl<'a> AuditEntry<'a> {
    pub(crate) fn vault(vault_id: &'a str, action: &'static str) -> Self {
        Self {
            scope_type: "vault",
            scope_id: vault_id,
            link_id: None,
            guest_session_id: None,
            connection_id: None,
            actor_user_id: None,
            action,
            result: "success",
            detail: None,
        }
    }
    pub(crate) fn org(org_id: &'a str, action: &'static str) -> Self {
        Self {
            scope_type: "org",
            ..Self::vault(org_id, action)
        }
    }
    pub(crate) fn link(mut self, link_id: &'a str) -> Self {
        self.link_id = Some(link_id);
        self
    }
    pub(crate) fn guest(mut self, guest_session_id: &'a str) -> Self {
        self.guest_session_id = Some(guest_session_id);
        self
    }
    pub(crate) fn connection(mut self, connection_id: &'a str) -> Self {
        self.connection_id = Some(connection_id);
        self
    }
    pub(crate) fn actor(mut self, user_id: &'a str) -> Self {
        self.actor_user_id = Some(user_id);
        self
    }
    pub(crate) fn result(mut self, result: &'static str) -> Self {
        self.result = result;
        self
    }
    pub(crate) fn detail(mut self, detail: impl Into<String>) -> Self {
        self.detail = Some(detail.into());
        self
    }
}

pub(crate) async fn audit_tx(
    tx: &mut Transaction<'_, Sqlite>,
    entry: AuditEntry<'_>,
    now: i64,
) -> Result<(), ApiError> {
    sqlx::query(
        "INSERT INTO cloud_audit_events(scope_type,scope_id,link_id,guest_session_id,connection_id,actor_user_id,action,result,detail,occurred_epoch) \
         VALUES(?,?,?,?,?,?,?,?,?,?)",
    )
    .bind(entry.scope_type)
    .bind(entry.scope_id)
    .bind(entry.link_id)
    .bind(entry.guest_session_id)
    .bind(entry.connection_id)
    .bind(entry.actor_user_id)
    .bind(entry.action)
    .bind(entry.result)
    .bind(entry.detail)
    .bind(now)
    .execute(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    Ok(())
}

pub(crate) async fn audit(state: &AppState, entry: AuditEntry<'_>, now: i64) {
    let result = async {
        let mut tx = state.db.begin().await.map_err(ApiError::internal)?;
        audit_tx(&mut tx, entry, now).await?;
        tx.commit().await.map_err(ApiError::internal)
    }
    .await;
    if result.is_err() {
        tracing::warn!(event = "cloud_audit_write_failed");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rate_limiter_is_a_bounded_sliding_window() {
        let limiter = RateLimiter::default();
        for second in 0..3 {
            assert!(limiter.check("ip", 3, 60, 1000 + second).is_ok());
        }
        assert_eq!(limiter.check("ip", 3, 60, 1010), Err(50));
        assert!(limiter.check("other", 3, 60, 1010).is_ok());
        assert!(limiter.check("ip", 3, 60, 1061).is_ok());
    }

    fn lookup(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<std::ffi::OsString> {
        move |name| pairs.iter().find(|(k, _)| *k == name).map(|(_, v)| (*v).into())
    }

    #[test]
    fn absent_settings_use_closed_defaults() {
        let config = CloudConfig::from_lookup(&lookup(&[]));
        assert!(!config.links_enabled && !config.vnc_enabled);
        assert!(config.config_errors.is_empty() && config.org_config_errors.is_empty());
        assert_eq!(config.allow_ports, vec![22, 3389]);
        assert_eq!(config.max_guest_connections, DEFAULT_MAX_GUEST_CONNECTIONS);
        assert!(config.organizations_enabled && !config.org_creation_any);
    }

    #[test]
    fn present_but_invalid_settings_close_the_feature_instead_of_widening() {
        for (name, value) in [
            ("ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS", "0"),
            ("ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS", "lots"),
            ("ATERMIUS_SHARE_MAX_LINK_LIFETIME_SECONDS", "99999999999"),
            ("ATERMIUS_SHARE_MAX_LINK_LIFETIME_SECONDS", "30d"),
            ("ATERMIUS_SHARE_REDEEM_IP_LIMIT_PER_MINUTE", "-1"),
            ("ATERMIUS_SHARE_LINKS_ENABLED", "yes"),
            ("ATERMIUS_SHARE_VNC_ENABLED", "TRUE"),
            ("ATERMIUS_SHARE_ALLOW_CIDRS", "10.0.0.0/8,not-a-cidr"),
            ("ATERMIUS_SHARE_DENY_CIDRS", "   "),
            ("ATERMIUS_SHARE_ALLOW_PORTS", "22,0"),
            ("ATERMIUS_SHARE_GATEWAY_KEY_FILE", ""),
            ("ATERMIUS_SHARE_MAX_DISPLAY_WIDTH", "10000"),
        ] {
            let pairs: &'static [(&'static str, &'static str)] = Box::leak(Box::new([
                (name, value),
                ("ATERMIUS_SHARE_LINKS_ENABLED", "true"),
            ]));
            let config = CloudConfig::from_lookup(&lookup(pairs));
            assert!(config.config_errors.contains(&name), "{name}={value:?} must be a config error");
        }
        let config = CloudConfig::from_lookup(&lookup(&[("ATERMIUS_ORGANIZATIONS_ENABLED", "1")]));
        assert_eq!(config.org_config_errors, vec!["ATERMIUS_ORGANIZATIONS_ENABLED"]);
        let config = CloudConfig::from_lookup(&lookup(&[("ATERMIUS_ORG_CREATION", "everyone")]));
        assert_eq!(config.org_config_errors, vec!["ATERMIUS_ORG_CREATION"]);
        // Trimmed exact values are accepted.
        let config = CloudConfig::from_lookup(&lookup(&[
            ("ATERMIUS_SHARE_LINKS_ENABLED", " true "),
            ("ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS", "8"),
            ("ATERMIUS_ORG_CREATION", "any"),
        ]));
        assert!(config.links_enabled && config.org_creation_any && config.config_errors.is_empty());
        assert_eq!(config.max_guest_connections, 8);
    }

    #[test]
    fn audit_network_is_coarse() {
        assert_eq!(ip_prefix("203.0.113.77".parse().unwrap()), "203.0.113.0/24");
        assert_eq!(ip_prefix("2001:db8:1:2::9".parse().unwrap()), "2001:db8:1::/48");
        assert_eq!(ip_prefix("::ffff:198.51.100.3".parse().unwrap()), "198.51.100.0/24");
    }

    #[test]
    fn time_helpers_round_trip_whole_seconds() {
        assert_eq!(epoch_rfc3339(0), "1970-01-01T00:00:00Z");
        assert_eq!(parse_rfc3339_epoch("2026-11-08T12:00:00+08:00"), Some(1_794_110_400));
        assert_eq!(parse_rfc3339_epoch("not a date"), None);
    }
}

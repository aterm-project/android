//! Handler-level tests for organizations, capsules, share links and guest
//! routes, run through the real router against real SQLite migrations.
use std::{
    net::{IpAddr, SocketAddr},
    sync::{Arc, Mutex},
};

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{HeaderMap, HeaderValue, Method, Request, StatusCode, header},
};
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signer, SigningKey};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use sha2::Digest;
use tower::ServiceExt;
use uuid::Uuid;

use crate::{
    AppState, AuthRateLimits, Config, cloud,
    share_gateway::{CAPSULE_FORMAT, CAPSULE_INNER_FORMAT, CapsuleHeader, GatewayKey, ResolveFuture, ShareResolver},
};

pub(crate) const ORIGIN: &str = "https://share.example.test";

struct FakeResolver(Mutex<Vec<IpAddr>>);

impl ShareResolver for FakeResolver {
    fn resolve<'a>(&'a self, _hostname: &'a str, _port: u16) -> ResolveFuture<'a> {
        let answers = self.0.lock().unwrap().clone();
        Box::pin(async move { Ok(answers) })
    }
}

pub(crate) struct World {
    pub(crate) state: AppState,
    resolver: Arc<FakeResolver>,
}

pub(crate) struct Account {
    pub(crate) user_id: String,
    pub(crate) device_id: String,
    pub(crate) access: String,
    pub(crate) signing: SigningKey,
}

fn test_config(data_dir: std::path::PathBuf) -> Config {
    Config {
        backup_archive_dir: None,
        backup_key_file: None,
        mfa_encryption_key_file: None,
        backup_retention_count: None,
        backup_replication_env: crate::BackupReplicationEnv::default(),
        data_dir,
        registration_open: false,
        guacd_address: Some("127.0.0.1:9".to_owned()),
        relay_enabled: false,
        terminal_collaboration_enabled: false,
        relay_allow_cidrs: Vec::new(),
        relay_allow_ports: Vec::new(),
        relay_max_connections_per_user: 1,
        public_origin: Some(ORIGIN.to_owned()),
        web_dir: None,
        max_object_bytes: 64 * 1024 * 1024,
        max_request_bytes: 1024 * 1024,
        history_retention_days: 90,
        record_restore_retention_days: 30,
        vault_deletion_grace_seconds: 7 * 24 * 60 * 60,
        account_deletion_grace_seconds: 7 * 24 * 60 * 60,
        audit_retention_days: 365,
        object_gc_grace_seconds: 7 * 24 * 60 * 60,
        admin_usernames: vec!["admin@example.test".to_owned()],
        auth_rate_limits: AuthRateLimits::default(),
    }
}

impl World {
    pub(crate) async fn new() -> Self {
        Self::with(|_| {}).await
    }

    pub(crate) async fn with(adjust: impl FnOnce(&mut cloud::CloudConfig)) -> Self {
        let data_dir = std::env::temp_dir().join(format!("atermius-cloud-{}", Uuid::new_v4()));
        crate::secure_file::create_private_data_dir(&data_dir).unwrap();
        let database = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
        let mut state = crate::open_state(&database, test_config(data_dir)).await.unwrap();
        let gateway = GatewayKey::for_tests(&state.db, &state.signing_key, &state.instance.instance_id).await;
        let mut config = cloud::CloudConfig::for_tests();
        adjust(&mut config);
        let resolver = Arc::new(FakeResolver(Mutex::new(vec!["10.1.2.3".parse().unwrap()])));
        let mut cloud_state = cloud::CloudState::with(config, Some(gateway));
        cloud_state.resolver = resolver.clone();
        state.cloud = Arc::new(cloud_state);
        Self { state, resolver }
    }

    pub(crate) fn set_dns(&self, answers: &[&str]) {
        *self.resolver.0.lock().unwrap() = answers.iter().map(|a| a.parse().unwrap()).collect();
    }

    pub(crate) async fn account(&self, username: &str) -> Account {
        let user_id = Uuid::new_v4().to_string();
        let device_id = Uuid::new_v4().to_string();
        let session_id = Uuid::new_v4().to_string();
        let access = format!("cloud-access-{}", Uuid::new_v4());
        let signing = SigningKey::generate(&mut rand::rngs::OsRng);
        let now = chrono::Utc::now();
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(&user_id)
            .bind(username)
            .bind(now.to_rfc3339())
            .execute(&self.state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'cloud-test',?,?,?)")
            .bind(&device_id)
            .bind(&user_id)
            .bind(URL_SAFE_NO_PAD.encode(signing.verifying_key().as_bytes()))
            .bind(URL_SAFE_NO_PAD.encode([5_u8; 32]))
            .bind(now.to_rfc3339())
            .execute(&self.state.db)
            .await
            .unwrap();
        sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'cloud-family',?,?,?,?,?)")
            .bind(&session_id)
            .bind(&user_id)
            .bind(&device_id)
            .bind(crate::sha256_hex(access.as_bytes()))
            .bind(format!("cloud-refresh-{}", Uuid::new_v4()))
            .bind((now + chrono::Duration::minutes(30)).to_rfc3339())
            .bind((now + chrono::Duration::days(30)).to_rfc3339())
            .bind(now.to_rfc3339())
            .execute(&self.state.db)
            .await
            .unwrap();
        Account { user_id, device_id, access, signing }
    }

    pub(crate) async fn vault(&self, owner: &Account, members: &[(&Account, &str)]) -> String {
        let vault_id = Uuid::new_v4().to_string();
        let now = crate::now_rfc3339();
        sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,created_at) VALUES(?,?,?)")
            .bind(&vault_id)
            .bind(&owner.user_id)
            .bind(&now)
            .execute(&self.state.db)
            .await
            .unwrap();
        for (account, role) in std::iter::once((owner, "owner")).chain(members.iter().copied()) {
            sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,?,'active',?)")
                .bind(&vault_id)
                .bind(&account.user_id)
                .bind(role)
                .bind(&now)
                .execute(&self.state.db)
                .await
                .unwrap();
        }
        vault_id
    }

    pub(crate) async fn host(&self, vault_id: &str) -> (String, String) {
        let record_id = Uuid::new_v4().to_string();
        let revision_id = Uuid::new_v4().to_string();
        self.set_head(vault_id, &record_id, &revision_id, false).await;
        (record_id, revision_id)
    }

    pub(crate) async fn set_head(&self, vault_id: &str, record_id: &str, revision_id: &str, deleted: bool) {
        sqlx::query("INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) VALUES(?,?,?,?,1) ON CONFLICT(vault_id,record_id) DO UPDATE SET revision_id=excluded.revision_id,deleted=excluded.deleted")
            .bind(vault_id)
            .bind(record_id)
            .bind(revision_id)
            .bind(i64::from(deleted))
            .execute(&self.state.db)
            .await
            .unwrap();
    }

    pub(crate) async fn call(&self, method: Method, path: &str, headers: HeaderMap, body: Option<Value>) -> (StatusCode, HeaderMap, Value) {
        let mut builder = Request::builder().method(method).uri(path);
        for (name, value) in &headers {
            builder = builder.header(name, value);
        }
        if body.is_some() && !headers.contains_key(header::CONTENT_TYPE) {
            builder = builder.header(header::CONTENT_TYPE, "application/json");
        }
        let mut request = builder
            .body(body.map_or_else(Body::empty, |value| Body::from(value.to_string())))
            .unwrap();
        request
            .extensions_mut()
            .insert(ConnectInfo(SocketAddr::from(([203, 0, 113, 9], 40000))));
        let response = crate::router(self.state.clone()).await.oneshot(request).await.unwrap();
        let status = response.status();
        let headers = response.headers().clone();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, headers, value)
    }

    pub(crate) async fn bearer(&self, account: &Account, method: Method, path: &str, body: Option<Value>) -> (StatusCode, Value) {
        let mut headers = HeaderMap::new();
        headers.insert(header::AUTHORIZATION, HeaderValue::from_str(&format!("Bearer {}", account.access)).unwrap());
        let (status, _, value) = self.call(method, path, headers, body).await;
        (status, value)
    }

    pub(crate) fn sealed_capsule(&self, owner: &Account, vault_id: &str, host_id: &str, revision: &str, protocol: &str, target: &str, port: u16, identity: Option<&str>) -> Value {
        let key = self.state.cloud.gateway.as_ref().unwrap();
        let inner = json!({
            "format": CAPSULE_INNER_FORMAT,
            "vault_id": vault_id,
            "host_record_id": host_id,
            "host_revision_id": revision,
            "gateway_key_id": key.key_id,
            "record_kind": "host",
            "protocol": protocol,
            "target_host": target,
            "target_port": port,
            "username": "deploy",
            "password": "SENTINEL-HOST-PASSWORD-7f3a",
            "host_identity": identity,
            "ssh_host_key_algorithm": if protocol == "ssh" { Some("ssh-ed25519") } else { None },
        });
        let sealed = key.seal_for_tests(inner.to_string().as_bytes());
        let mut header = CapsuleHeader {
            format: CAPSULE_FORMAT.into(),
            vault_id: vault_id.into(),
            host_record_id: host_id.into(),
            host_revision_id: revision.into(),
            gateway_key_id: key.key_id.clone(),
            protocol: protocol.into(),
            target_host: target.into(),
            target_port: port,
            host_identity: identity.map(str::to_owned),
            sealed_sha256: URL_SAFE_NO_PAD.encode(sha2::Sha256::digest(&sealed)),
            sealer_user_id: owner.user_id.clone(),
            sealer_device_id: owner.device_id.clone(),
            created_at: crate::now_rfc3339(),
            signature: None,
        };
        let signed = serde_jcs::to_vec(&header).unwrap();
        header.signature = Some(URL_SAFE_NO_PAD.encode(owner.signing.sign(&signed).to_bytes()));
        json!({"header": header, "sealed": URL_SAFE_NO_PAD.encode(&sealed)})
    }

    pub(crate) async fn shared_host(&self, owner: &Account, vault_id: &str) -> String {
        let (host_id, revision) = self.host(vault_id).await;
        let body = self.sealed_capsule(owner, vault_id, &host_id, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
        let (status, value) = self
            .bearer(owner, Method::PUT, &format!("/api/v1/vaults/{vault_id}/hosts/{host_id}/gateway-capsule"), Some(body))
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        host_id
    }

    pub(crate) async fn link(&self, owner: &Account, vault_id: &str, host_id: &str, extra: Value) -> (Value, String, String) {
        let token = cloud::random_token();
        let mut body = json!({
            "link_id": Uuid::new_v4().to_string(),
            "redeem_token": token,
            "display_envelope": "opaque-envelope.v1",
            "targets": [{"target_id": Uuid::new_v4().to_string(), "host_record_id": host_id}],
        });
        for (key, value) in extra.as_object().unwrap() {
            body[key] = value.clone();
        }
        let (status, value) = self
            .bearer(owner, Method::POST, &format!("/api/v1/vaults/{vault_id}/share-links"), Some(body))
            .await;
        assert_eq!(status, StatusCode::CREATED, "{value}");
        let slug = value["slug"].as_str().unwrap().to_owned();
        (value, slug, token)
    }

    pub(crate) fn guest_headers(cookie: Option<&str>) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(header::ORIGIN, HeaderValue::from_static(ORIGIN));
        headers.insert("x-atermius-guest", HeaderValue::from_static("v1"));
        if let Some(cookie) = cookie {
            headers.insert(header::COOKIE, HeaderValue::from_str(&format!("__Host-atermius-guest={cookie}")).unwrap());
        }
        headers
    }

    pub(crate) async fn redeem(&self, slug: &str, token: &str) -> (StatusCode, HeaderMap, Value) {
        self.call(
            Method::POST,
            "/api/v1/guest/redeem",
            Self::guest_headers(None),
            Some(json!({"slug": slug, "redeem_token": token})),
        )
        .await
    }

    pub(crate) async fn db_bytes(&self) -> Vec<u8> {
        let _ = sqlx::query("PRAGMA wal_checkpoint(FULL)").execute(&self.state.db).await;
        let mut bytes = std::fs::read(self.state.config.data_dir.join("atermius.db")).unwrap();
        if let Ok(wal) = std::fs::read(self.state.config.data_dir.join("atermius.db-wal")) {
            bytes.extend(wal);
        }
        bytes
    }
}

pub(crate) fn ssh_fp() -> String {
    format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode([3_u8; 32]))
}

fn cookie_from(headers: &HeaderMap) -> String {
    let value = headers.get(header::SET_COOKIE).unwrap().to_str().unwrap();
    value
        .strip_prefix("__Host-atermius-guest=")
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned()
}

fn contains(haystack: &[u8], needle: &str) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle.as_bytes())
}

#[tokio::test]
async fn capabilities_are_truthful_and_sharing_stays_closed_without_gateway() {
    let world = World::new().await;
    let (_, _, info) = world.call(Method::GET, "/api/v1/instance", HeaderMap::new(), None).await;
    let caps = info["capabilities"].as_array().unwrap();
    assert!(caps.contains(&json!("share_links")) && caps.contains(&json!("organizations")));
    assert!(!caps.contains(&json!("share_gateway_vnc")), "VNC is opt-in");

    // Same deployment without a gateway key: closed and not advertised.
    let mut closed = World::new().await;
    let config = closed.state.cloud.config.clone();
    closed.state.cloud = Arc::new(cloud::CloudState::with(config, None));
    let (_, _, info) = closed.call(Method::GET, "/api/v1/instance", HeaderMap::new(), None).await;
    assert!(!info["capabilities"].as_array().unwrap().contains(&json!("share_links")));
    let owner = closed.account("o@example.test").await;
    let vault = closed.vault(&owner, &[]).await;
    let (status, value) = closed.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links"), None).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::SERVICE_UNAVAILABLE, Some("GATEWAY_DISABLED")));
    let (status, _, value) = closed.redeem("abc-def", &cloud::random_token()).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "guest routes look like unknown links when disabled");
    assert_eq!(value["error"]["code"], "SHARE_LINK_UNAVAILABLE");
}

#[tokio::test]
async fn capsule_put_checks_signature_owner_head_identity_and_target_policy() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let editor = world.account("editor@example.test").await;
    let stranger = world.account("stranger@example.test").await;
    let vault = world.vault(&owner, &[(&editor, "editor")]).await;
    let other_vault = world.vault(&stranger, &[]).await;
    let (host, revision) = world.host(&vault).await;
    let path = format!("/api/v1/vaults/{vault}/hosts/{host}/gateway-capsule");

    // Editor (and anyone not the owner) cannot seal/expose Host credentials.
    let body = world.sealed_capsule(&editor, &vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, value) = world.bearer(&editor, Method::PUT, &path, Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::FORBIDDEN, Some("VAULT_ROLE_REQUIRED")));
    // A stranger sees a uniform 404 for a foreign Vault.
    let body = world.sealed_capsule(&stranger, &vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, _) = world.bearer(&stranger, Method::PUT, &path, Some(body)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    // Header bound to another Host/Vault than the path → 400.
    let body = world.sealed_capsule(&owner, &other_vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::BAD_REQUEST, Some("CAPSULE_BINDING_MISMATCH")));
    // Tampered header (signature no longer valid).
    let mut body = world.sealed_capsule(&owner, &vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    body["header"]["target_port"] = json!(3389);
    let (status, _) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    // SSH without trusted host key → HOST_KEY_REQUIRED.
    let body = world.sealed_capsule(&owner, &vault, &host, &revision, "ssh", "db.internal.example", 22, None);
    let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::UNPROCESSABLE_ENTITY, Some("HOST_KEY_REQUIRED")));
    // VNC is disabled by default.
    let body = world.sealed_capsule(&owner, &vault, &host, &revision, "vnc", "10.1.2.3", 5900, None);
    let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::UNPROCESSABLE_ENTITY, Some("HOST_SHARE_UNSUPPORTED")));
    // Forbidden / policy-excluded addresses and ports.
    for (target, port) in [
        ("127.0.0.1", 22), ("::1", 22), ("169.254.169.254", 22), ("fd00:ec2::254", 22),
        ("100.100.100.200", 22), ("::ffff:127.0.0.1", 22), ("0.0.0.0", 22), ("224.0.0.1", 22),
        ("10.99.0.5", 22), ("172.16.0.1", 22), ("10.1.2.3", 2222),
    ] {
        let body = world.sealed_capsule(&owner, &vault, &host, &revision, "ssh", target, port, Some(&ssh_fp()));
        let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
        assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::FORBIDDEN, Some("TARGET_DENIED")), "{target}:{port}");
    }
    // DNS answers are all inspected: one loopback answer poisons the name.
    world.set_dns(&["10.1.2.3", "127.0.0.1"]);
    let body = world.sealed_capsule(&owner, &vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, _) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    world.set_dns(&["10.1.2.3"]);
    // Stale revision.
    let body = world.sealed_capsule(&owner, &vault, &host, &Uuid::new_v4().to_string(), "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::CONFLICT, Some("HOST_REVISION_CHANGED")));
    // Success; listing exposes metadata only.
    let body = world.sealed_capsule(&owner, &vault, &host, &revision, "ssh", "db.internal.example", 22, Some(&ssh_fp()));
    let (status, value) = world.bearer(&owner, Method::PUT, &path, Some(body)).await;
    assert_eq!(status, StatusCode::OK, "{value}");
    assert_eq!(value["status"], "active");
    let (status, list) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-capsules"), None).await;
    assert_eq!(status, StatusCode::OK);
    assert!(!list.to_string().contains("sealed\""), "sealed bytes never leave the server");
    // Host edited → capsule reported stale.
    world.set_head(&vault, &host, &Uuid::new_v4().to_string(), false).await;
    let (_, list) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-capsules"), None).await;
    assert_eq!(list["capsules"][0]["status"], "stale_host_revision");
    // The database never holds the capsule plaintext.
    assert!(!contains(&world.db_bytes().await, "SENTINEL-HOST-PASSWORD-7f3a"));
}

#[tokio::test]
async fn link_creation_enforces_owner_tenant_defaults_and_slug_rules() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let editor = world.account("editor@example.test").await;
    let other = world.account("other@example.test").await;
    let vault = world.vault(&owner, &[(&editor, "editor")]).await;
    let other_vault = world.vault(&other, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let foreign_host = world.shared_host(&other, &other_vault).await;

    let (link, slug, _) = world.link(&owner, &vault, &host, json!({})).await;
    assert_eq!(link["max_redemptions"], 1, "default one redemption");
    assert_eq!(link["max_concurrent"], 1);
    assert_eq!(link["permissions"], json!({"clipboard_to_remote": false, "clipboard_from_remote": false, "view_only": false}));
    let from = cloud::parse_rfc3339_epoch(link["valid_from"].as_str().unwrap()).unwrap();
    let until = cloud::parse_rfc3339_epoch(link["expires_at"].as_str().unwrap()).unwrap();
    assert_eq!(until - from, 24 * 3600, "default 24 h");
    assert_eq!(slug.len(), 12);

    let base = |host: &str| json!({
        "link_id": Uuid::new_v4().to_string(),
        "redeem_token": cloud::random_token(),
        "display_envelope": "opaque",
        "targets": [{"target_id": Uuid::new_v4().to_string(), "host_record_id": host}],
    });
    // Editor cannot share (no escalation through the sharing API).
    let (status, _) = world.bearer(&editor, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(base(&host))).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    // A Host of another Vault cannot be substituted → 404.
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(base(&foreign_host))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    // Unknown privileged fields are rejected.
    for field in ["can_edit", "share", "show_credentials", "target_host"] {
        let mut body = base(&host);
        body[field] = json!(true);
        let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body)).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{field}");
    }
    // Custom slug: normalized, unique, reserved words, conflict without owner leak.
    let mut body = base(&host);
    body["slug"] = json!("Demo-Room");
    let (status, value) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body)).await;
    assert_eq!((status, value["slug"].as_str()), (StatusCode::CREATED, Some("demo-room")));
    let mut body = base(&foreign_host);
    body["slug"] = json!("demo-room");
    let (status, value) = world.bearer(&other, Method::POST, &format!("/api/v1/vaults/{other_vault}/share-links"), Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::CONFLICT, Some("SLUG_TAKEN")));
    assert!(!value.to_string().contains(&owner.user_id));
    let mut body = base(&host);
    body["slug"] = json!("admin");
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    // Lifetime ceiling and explicit unlimited redemptions.
    let mut body = base(&host);
    body["expires_at"] = json!(cloud::epoch_rfc3339(cloud::now_epoch() + 91 * 24 * 3600));
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body)).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY);
    let mut body = base(&host);
    body["max_redemptions"] = Value::Null;
    let (status, value) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body.clone())).await;
    assert_eq!((status, &value["max_redemptions"]), (StatusCode::CREATED, &Value::Null));
    // Idempotent replay vs reused ID.
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body.clone())).await;
    assert_eq!(status, StatusCode::OK);
    body["view_only"] = json!(true);
    let (status, value) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links"), Some(body)).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::CONFLICT, Some("IDEMPOTENCY_KEY_REUSED")));
    // Another Vault's link ID through this Vault path → 404.
    let (other_link, _, _) = world.link(&other, &other_vault, &foreign_host, json!({})).await;
    let (status, _) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{}", other_link["link_id"].as_str().unwrap()), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links/{}/revoke", other_link["link_id"].as_str().unwrap()), Some(json!({}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn guest_auth_domain_origin_csrf_and_cookie_attributes() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (_, slug, token) = world.link(&owner, &vault, &host, json!({"max_redemptions": 5})).await;
    let body = json!({"slug": slug, "redeem_token": token});

    let mut no_origin = World::guest_headers(None);
    no_origin.remove(header::ORIGIN);
    let mut wrong_origin = World::guest_headers(None);
    wrong_origin.insert(header::ORIGIN, HeaderValue::from_static("https://evil.example"));
    let mut no_marker = World::guest_headers(None);
    no_marker.remove("x-atermius-guest");
    let mut form = World::guest_headers(None);
    form.insert(header::CONTENT_TYPE, HeaderValue::from_static("text/plain"));
    let mut bearer = World::guest_headers(None);
    bearer.insert(header::AUTHORIZATION, HeaderValue::from_str(&format!("Bearer {}", owner.access)).unwrap());
    let mut cross_site = World::guest_headers(None);
    cross_site.insert("sec-fetch-site", HeaderValue::from_static("cross-site"));
    for (headers, expected) in [
        (no_origin, StatusCode::FORBIDDEN),
        (wrong_origin, StatusCode::FORBIDDEN),
        (no_marker, StatusCode::FORBIDDEN),
        (form, StatusCode::UNSUPPORTED_MEDIA_TYPE),
        (bearer, StatusCode::BAD_REQUEST),
        (cross_site, StatusCode::FORBIDDEN),
    ] {
        let (status, _, _) = world.call(Method::POST, "/api/v1/guest/redeem", headers, Some(body.clone())).await;
        assert_eq!(status, expected);
    }
    let (_, _, link) = world.call(Method::GET, &format!("/api/v1/vaults/{vault}/share-links"), {
        let mut h = HeaderMap::new();
        h.insert(header::AUTHORIZATION, HeaderValue::from_str(&format!("Bearer {}", owner.access)).unwrap());
        h
    }, None).await;
    assert_eq!(link["links"][0]["redemptions"], 0, "rejected requests change no state");

    let (status, headers, view) = world.redeem(&slug, &token).await;
    assert_eq!(status, StatusCode::OK, "{view}");
    let cookie_header = headers.get(header::SET_COOKIE).unwrap().to_str().unwrap();
    assert!(cookie_header.starts_with("__Host-atermius-guest="));
    for attribute in ["Secure", "HttpOnly", "SameSite=Strict", "Path=/"] {
        assert!(cookie_header.contains(attribute));
    }
    assert!(!cookie_header.contains("Domain"));
    let max_age: i64 = cookie_header.split("Max-Age=").nth(1).unwrap().split(';').next().unwrap().parse().unwrap();
    assert!(max_age <= 7200 && max_age > 7000);
    assert!(view.get("vault_id").is_none() && !view.to_string().contains("deploy"));
    let cookie = cookie_from(&headers);

    // The guest cookie is not a Bearer credential and vice versa.
    let mut cookie_on_bearer = HeaderMap::new();
    cookie_on_bearer.insert(header::COOKIE, HeaderValue::from_str(&format!("__Host-atermius-guest={cookie}")).unwrap());
    let (status, _, _) = world.call(Method::GET, &format!("/api/v1/vaults/{vault}/share-links"), cookie_on_bearer, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _, session) = world.call(Method::GET, &format!("/api/v1/guest/session?slug={slug}"), World::guest_headers(Some(&cookie)), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(session["link_id"], view["link_id"]);
    // Refresh does not consume a redemption.
    let (_, link) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{}", view["link_id"].as_str().unwrap()), None).await;
    assert_eq!(link["redemptions"], 1);
    // Unknown target fields for a connection → 422 (guest cannot choose targets).
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let target = view["targets"][0]["target_id"].as_str().unwrap().to_owned();
    for extra in ["host", "port", "protocol", "username", "password", "hostname"] {
        let mut request = json!({"slug": slug, "target_id": target});
        request[extra] = json!("x");
        let (status, _, _) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(request)).await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{extra}");
    }
    // Another link's target ID through this cookie → 404.
    let host2 = world.shared_host(&owner, &vault).await;
    let (other_link, _, _) = world.link(&owner, &vault, &host2, json!({})).await;
    let (status, _, _) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": slug, "target_id": other_link["targets"][0]["target_id"]}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn redemption_is_atomic_uniform_and_secrets_are_hashed_at_rest() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({})).await;

    // Wrong secret and unknown slug are indistinguishable.
    let (s1, _, wrong) = world.redeem(&slug, &cloud::random_token()).await;
    let (s2, _, unknown) = world.redeem("no-such-link", &token).await;
    assert_eq!((s1, s2), (StatusCode::NOT_FOUND, StatusCode::NOT_FOUND));
    assert_eq!(wrong["error"]["code"], unknown["error"]["code"]);
    assert_eq!(wrong["error"]["message"], unknown["error"]["message"]);

    let mut tasks = Vec::new();
    for _ in 0..32 {
        let state = world.state.clone();
        let (slug, token) = (slug.clone(), token.clone());
        tasks.push(tokio::spawn(async move {
            let mut request = Request::builder()
                .method(Method::POST)
                .uri("/api/v1/guest/redeem")
                .header(header::ORIGIN, ORIGIN)
                .header("x-atermius-guest", "v1")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(json!({"slug": slug, "redeem_token": token}).to_string()))
                .unwrap();
            // Distinct source addresses keep the per-IP limiter out of the way.
            request.extensions_mut().insert(ConnectInfo(SocketAddr::from(([198, 51, 100, rand::random::<u8>()], 1))));
            let response = crate::router(state).await.oneshot(request).await.unwrap();
            let status = response.status();
            let cookie = response.headers().get(header::SET_COOKIE).map(|v| v.to_str().unwrap().to_owned());
            (status, cookie)
        }));
    }
    let mut ok = 0;
    let mut cookies = Vec::new();
    for task in tasks {
        let (status, cookie) = task.await.unwrap();
        if status == StatusCode::OK {
            ok += 1;
            cookies.push(cookie.unwrap());
        } else {
            assert!(matches!(status, StatusCode::GONE | StatusCode::TOO_MANY_REQUESTS), "{status}");
        }
    }
    assert_eq!(ok, 1, "exactly one of 32 concurrent redemptions succeeds");
    let cookie = cookies[0].strip_prefix("__Host-atermius-guest=").unwrap().split(';').next().unwrap().to_owned();
    let (status, _, value) = world.redeem(&slug, &token).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::GONE, Some("SHARE_LINK_EXHAUSTED")));

    // Issue a ticket and scan every table for plaintext secrets.
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let (status, _, ticket) = world
        .call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": slug, "target_id": link["targets"][0]["target_id"]})))
        .await;
    assert_eq!(status, StatusCode::OK, "{ticket}");
    let bytes = world.db_bytes().await;
    for secret in [token.as_str(), cookie.as_str(), ticket["ticket"].as_str().unwrap()] {
        assert!(!contains(&bytes, secret), "plaintext secret persisted");
        assert!(contains(&bytes, &crate::sha256_hex(secret.as_bytes())), "hash stored");
    }
    // Audit rows hold metadata only.
    let audit: Vec<String> = sqlx::query_scalar("SELECT COALESCE(detail,'') FROM cloud_audit_events")
        .fetch_all(&world.state.db)
        .await
        .unwrap();
    for row in audit {
        assert!(!row.contains(&token) && !row.contains(&cookie) && !row.contains("SENTINEL"));
    }
}

#[tokio::test]
async fn time_window_is_half_open_on_the_server_clock() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let now = cloud::now_epoch();
    let (_, slug, token) = world
        .link(&owner, &vault, &host, json!({"valid_from": cloud::epoch_rfc3339(now + 3600), "expires_at": cloud::epoch_rfc3339(now + 7200)}))
        .await;
    let (status, _, value) = world.redeem(&slug, &token).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::FORBIDDEN, Some("SHARE_LINK_NOT_YET_VALID")));
    assert_eq!(value["error"]["details"]["valid_from"], cloud::epoch_rfc3339(now + 3600));
    // Move the window into the past directly (server clock decides).
    sqlx::query("UPDATE share_links SET valid_from_epoch=?,expires_epoch=? WHERE slug=?")
        .bind(now - 7200)
        .bind(now)
        .bind(&slug)
        .execute(&world.state.db)
        .await
        .unwrap();
    let (status, _, value) = world.redeem(&slug, &token).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::GONE, Some("SHARE_LINK_EXPIRED")));
}

#[tokio::test]
async fn tickets_respect_revocation_limits_and_dns_rebinding() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_connections": 2})).await;
    let link_id = link["link_id"].as_str().unwrap().to_owned();
    let target = link["targets"][0]["target_id"].clone();
    let (_, headers, _) = world.redeem(&slug, &token).await;
    let cookie = cookie_from(&headers);
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let ticket_request = || json!({"slug": slug, "target_id": target});

    // DNS rebinding at ticket time: the name now also answers loopback.
    world.set_dns(&["10.1.2.3", "127.0.0.1"]);
    let (status, _, value) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(ticket_request())).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::FORBIDDEN, Some("TARGET_DENIED")));
    world.set_dns(&["10.1.2.3"]);

    let (status, _, first) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(ticket_request())).await;
    assert_eq!(status, StatusCode::OK);
    // Revoke between ticket and connect: consumption fails.
    let (status, _) = world.bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links/{link_id}/revoke"), Some(json!({}))).await;
    assert_eq!(status, StatusCode::OK);
    let guest_session: String = sqlx::query_scalar("SELECT guest_session_id FROM share_guest_sessions WHERE link_id=?")
        .bind(&link_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    let ticket_rows: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM share_gateway_tickets WHERE ticket_hash=?")
        .bind(crate::sha256_hex(first["ticket"].as_str().unwrap().as_bytes()))
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(ticket_rows, 0, "revocation deletes unconsumed tickets");
    let (status, _, value) = world.call(Method::GET, &format!("/api/v1/guest/session?slug={slug}"), World::guest_headers(Some(&cookie)), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "{value}");
    let mut tx = world.state.db.begin().await.unwrap();
    let denied = crate::share_guest::authorize_tx(&mut tx, &world.state, &guest_session, target.as_str().unwrap(), None, cloud::now_epoch(), true).await;
    assert!(matches!(denied, Err(crate::share_guest::Denied::Revoked(_))));
    drop(tx);

    // max_connections and concurrency on a fresh link.
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_connections": 2, "max_concurrent": 1})).await;
    let target = link["targets"][0]["target_id"].clone();
    let (_, headers, _) = world.redeem(&slug, &token).await;
    let mut guest = World::guest_headers(Some(&cookie_from(&headers)));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    // G14 admission semantics: issuing tickets charges nothing (the gateway
    // charges max_connections when it admits a connection; see the served
    // admission tests). Issuance only refuses cheaply once the link is
    // already exhausted.
    for _ in 0..3 {
        let (status, _, _) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": slug, "target_id": target}))).await;
        assert_eq!(status, StatusCode::OK);
    }
    let counted: i64 = sqlx::query_scalar("SELECT connections FROM share_links WHERE link_id=?")
        .bind(link["link_id"].as_str().unwrap())
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(counted, 0, "ticket issuance is not a connection attempt");
    sqlx::query("UPDATE share_links SET connections=max_connections WHERE link_id=?")
        .bind(link["link_id"].as_str().unwrap())
        .execute(&world.state.db)
        .await
        .unwrap();
    let (status, _, value) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": slug, "target_id": target}))).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::GONE, Some("SHARE_LINK_EXHAUSTED")));
    // A live connection at the concurrency limit refuses without counting.
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_connections": 5})).await;
    let link_id = link["link_id"].as_str().unwrap().to_owned();
    let target = link["targets"][0]["target_id"].clone();
    let (_, headers, _) = world.redeem(&slug, &token).await;
    let mut guest = World::guest_headers(Some(&cookie_from(&headers)));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let session: String = sqlx::query_scalar("SELECT guest_session_id FROM share_guest_sessions WHERE link_id=?")
        .bind(&link_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO share_gateway_connections(connection_id,link_id,guest_session_id,target_id,protocol,started_epoch,heartbeat_epoch) VALUES(?,?,?,?,'ssh',?,?)")
        .bind(Uuid::new_v4().to_string())
        .bind(&link_id)
        .bind(&session)
        .bind(target.as_str().unwrap())
        .bind(cloud::now_epoch())
        .bind(cloud::now_epoch())
        .execute(&world.state.db)
        .await
        .unwrap();
    let (status, _, value) = world.call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": slug, "target_id": target}))).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::TOO_MANY_REQUESTS, Some("SHARE_CONCURRENCY_LIMIT")));
    let (_, refreshed) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{link_id}"), None).await;
    assert_eq!(refreshed["connections"], 0, "refused attempts are not counted");
}

#[tokio::test]
async fn narrowing_rotation_host_changes_and_owner_demotion_revoke_access() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let editor = world.account("editor@example.test").await;
    let vault = world.vault(&owner, &[(&editor, "editor")]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_redemptions": 3, "clipboard_to_remote": true})).await;
    let link_id = link["link_id"].as_str().unwrap().to_owned();
    let target = link["targets"][0]["target_id"].as_str().unwrap().to_owned();
    let (_, headers, _) = world.redeem(&slug, &token).await;
    let cookie = cookie_from(&headers);
    let session: String = sqlx::query_scalar("SELECT guest_session_id FROM share_guest_sessions WHERE link_id=?")
        .bind(&link_id)
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    let authorize = |expected: (i64, i64)| {
        let state = world.state.clone();
        let session = session.clone();
        let target = target.clone();
        async move {
            let mut tx = state.db.begin().await.unwrap();
            crate::share_guest::authorize_tx(&mut tx, &state, &session, &target, Some(expected), cloud::now_epoch(), true)
                .await
                .map(|_| ())
        }
    };
    assert!(authorize((1, 1)).await.is_ok());
    // Widening does not disturb established connections …
    let (status, updated) = world
        .bearer(&owner, Method::PUT, &format!("/api/v1/vaults/{vault}/share-links/{link_id}"), Some(json!({"expected_revision": 1, "max_concurrent": 3})))
        .await;
    assert_eq!(status, StatusCode::OK, "{updated}");
    assert!(authorize((1, 1)).await.is_ok());
    // … narrowing (clipboard off) does.
    let (status, _) = world
        .bearer(&owner, Method::PUT, &format!("/api/v1/vaults/{vault}/share-links/{link_id}"), Some(json!({"expected_revision": 2, "clipboard_to_remote": false})))
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(authorize((1, 1)).await, Err(crate::share_guest::Denied::Revoked("policy_changed")));
    assert!(authorize((2, 1)).await.is_ok());
    // Host edit keeps established sessions; Host deletion ends them.
    world.set_head(&vault, &host, &Uuid::new_v4().to_string(), false).await;
    assert!(authorize((2, 1)).await.is_ok());
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let (status, _, value) = world.call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": slug, "target_id": target}))).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::CONFLICT, Some("CAPSULE_STALE")));
    let head: String = sqlx::query_scalar("SELECT revision_id FROM record_heads WHERE record_id=?").bind(&host).fetch_one(&world.state.db).await.unwrap();
    world.set_head(&vault, &host, &head, true).await;
    assert_eq!(authorize((2, 1)).await, Err(crate::share_guest::Denied::Revoked("host_deleted")));
    world.set_head(&vault, &host, &head, false).await;
    // Owner demoted (ownership moved away) → creator lost access.
    sqlx::query("UPDATE vault_members SET role='editor' WHERE vault_id=? AND user_id=?")
        .bind(&vault)
        .bind(&owner.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    assert_eq!(authorize((2, 1)).await, Err(crate::share_guest::Denied::Revoked("creator_lost_access")));
    sqlx::query("UPDATE vault_members SET role='owner' WHERE vault_id=? AND user_id=?")
        .bind(&vault)
        .bind(&owner.user_id)
        .execute(&world.state.db)
        .await
        .unwrap();
    assert!(authorize((2, 1)).await.is_ok());
    // Secret rotation ends sessions and invalidates the old URL.
    let (status, rotated) = world
        .bearer(&owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links/{link_id}/rotate-secret"), Some(json!({"expected_revision": 3, "redeem_token": cloud::random_token(), "display_envelope": "new-envelope"})))
        .await;
    assert_eq!(status, StatusCode::OK, "{rotated}");
    assert!(authorize((2, 1)).await.is_err());
    let (status, _, _) = world.redeem(&slug, &token).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "old URL is dead");
    // Owner terminates a session; activity shows metadata only.
    let (_, activity) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{link_id}/activity"), None).await;
    assert_eq!(activity["sessions"][0]["end_reason"], "secret_rotated");
    assert_eq!(activity["sessions"][0]["ip_prefix"], "203.0.113.0/24");
    assert!(!activity.to_string().contains(&cookie) && !activity.to_string().contains(&token));
    let (status, _) = world.bearer(&editor, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{link_id}/activity"), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn organizations_invitations_teams_and_grants_never_distribute_keys() {
    let world = World::with(|config| config.org_creation_any = false).await;
    let admin = world.account("admin@example.test").await;
    let alice = world.account("alice@example.test").await;
    let bob = world.account("bob@example.test").await;
    let mallory = world.account("mallory@example.test").await;

    let (status, _) = world.bearer(&alice, Method::POST, "/api/v1/orgs", Some(json!({"name": "Ops"}))).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "org creation is admin-only by default");
    let (status, org) = world.bearer(&admin, Method::POST, "/api/v1/orgs", Some(json!({"name": "Ops"}))).await;
    assert_eq!(status, StatusCode::CREATED);
    let org_id = org["org_id"].as_str().unwrap().to_owned();
    // Non-members cannot see the organization (uniform 404).
    let (status, _) = world.bearer(&mallory, Method::GET, &format!("/api/v1/orgs/{org_id}"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    // Invitation bound to bob; one-use; mallory cannot use it.
    let (status, invite) = world
        .bearer(&admin, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "member", "intended_username": "bob@example.test"})))
        .await;
    assert_eq!(status, StatusCode::CREATED);
    let token = invite["token"].as_str().unwrap().to_owned();
    let (status, _) = world.bearer(&mallory, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": token}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, inspected) = world.bearer(&bob, Method::POST, "/api/v1/org-invitations/inspect", Some(json!({"token": token}))).await;
    assert_eq!((status, inspected["name"].as_str()), (StatusCode::OK, Some("Ops")));
    let (status, joined) = world.bearer(&bob, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": token}))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(joined["vault_keys_pending"], true);
    let (status, _) = world.bearer(&bob, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": token}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "one-use");
    // Members cannot manage the organization.
    let (status, value) = world.bearer(&bob, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "admin"}))).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::FORBIDDEN, Some("ORG_ROLE_REQUIRED")));

    // Alice joins as admin via an open invitation.
    let (_, invite) = world.bearer(&admin, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "admin"}))).await;
    let (status, _) = world.bearer(&alice, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": invite["token"]}))).await;
    assert_eq!(status, StatusCode::OK);
    // Team in this org; members of another org cannot be added.
    let (_, team) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/teams"), Some(json!({"name": "SRE"}))).await;
    let team_id = team["team_id"].as_str().unwrap().to_owned();
    let (status, _) = world
        .bearer(&alice, Method::PUT, &format!("/api/v1/orgs/{org_id}/teams/{team_id}/members"), Some(json!({"user_ids": [mallory.user_id], "expected_revision": 1})))
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = world
        .bearer(&alice, Method::PUT, &format!("/api/v1/orgs/{org_id}/teams/{team_id}/members"), Some(json!({"user_ids": [bob.user_id], "expected_revision": 1})))
        .await;
    assert_eq!(status, StatusCode::OK);
    // A second org's team cannot be granted on this org's Vault.
    let (_, other_org) = world.bearer(&admin, Method::POST, "/api/v1/orgs", Some(json!({"name": "Other"}))).await;
    let (_, other_team) = world.bearer(&admin, Method::POST, &format!("/api/v1/orgs/{}/teams", other_org["org_id"].as_str().unwrap()), Some(json!({"name": "X"}))).await;

    // Alice's Vault attached to the org; desired grant for the team.
    let vault = world.vault(&alice, &[]).await;
    let (status, _) = world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/organization"), Some(json!({"org_id": org_id}))).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = world
        .bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/team/{}", other_team["team_id"].as_str().unwrap()), Some(json!({"role": "viewer", "expected_grants_revision": 1})))
        .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "cross-org team");
    let (status, _) = world
        .bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/team/{team_id}"), Some(json!({"role": "editor", "expected_grants_revision": 1})))
        .await;
    assert_eq!(status, StatusCode::OK);
    // The org owner (admin) is not a Vault member: may see desired grants but
    // never the key-distribution view, and holds no key envelope.
    let (status, _) = world.bearer(&admin, Method::GET, &format!("/api/v1/vaults/{vault}/grants"), None).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = world.bearer(&admin, Method::GET, &format!("/api/v1/vaults/{vault}/key-distribution"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    // A malicious org admin adds themselves to the granted team: still only a
    // pending desired member, no key envelope or membership row appears.
    let (status, _) = world
        .bearer(&admin, Method::PUT, &format!("/api/v1/orgs/{org_id}/teams/{team_id}/members"), Some(json!({"user_ids": [bob.user_id, admin.user_id], "expected_revision": 2})))
        .await;
    assert_eq!(status, StatusCode::OK);
    let (status, dist) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/key-distribution"), None).await;
    assert_eq!(status, StatusCode::OK);
    let additions = dist["pending_additions"].as_array().unwrap();
    assert_eq!(additions.len(), 2);
    assert!(additions.iter().all(|a| a["status"] == "waiting_for_device"));
    let envelopes: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM vault_key_envelopes WHERE vault_id=?").bind(&vault).fetch_one(&world.state.db).await.unwrap();
    let members: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM vault_members WHERE vault_id=?").bind(&vault).fetch_one(&world.state.db).await.unwrap();
    assert_eq!((envelopes, members), (0, 1));
    // Removing bob from the org removes his desired grant immediately.
    let (status, _) = world.bearer(&alice, Method::DELETE, &format!("/api/v1/orgs/{org_id}/members/{}", bob.user_id), None).await;
    assert_eq!(status, StatusCode::OK);
    let (_, dist) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/key-distribution"), None).await;
    assert_eq!(dist["pending_additions"].as_array().unwrap().len(), 1);
    // Admins cannot remove owners; the last owner cannot leave.
    let (status, _) = world.bearer(&alice, Method::DELETE, &format!("/api/v1/orgs/{org_id}/members/{}", admin.user_id), None).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let (status, value) = world.bearer(&admin, Method::DELETE, &format!("/api/v1/orgs/{org_id}/members/{}", admin.user_id), None).await;
    assert_eq!((status, value["error"]["code"].as_str()), (StatusCode::CONFLICT, Some("ORG_LAST_OWNER")));
}

#[test]
fn postgres_runtime_never_allows_cloud_routes() {
    for (method, path) in [
        (Method::GET, "/api/v1/share-links"),
        (Method::POST, "/api/v1/guest/redeem"),
        (Method::GET, "/gateway/v1/connect"),
        (Method::POST, "/api/v1/orgs"),
        (Method::GET, "/api/v1/share-gateway/keys"),
    ] {
        assert!(!crate::pg_sync_route_is_supported(&method, path), "{path}");
    }
    // The guest landing page itself is a static SPA route.
    assert!(crate::pg_sync_route_is_supported(&Method::GET, "/s/demo-room"));
}

// ---------------------------------------------------------------------------
// R4.1 — accepted grant-derived members: immediate restriction, union of
// remaining grants, role downgrade, direct provenance untouched.
// ---------------------------------------------------------------------------

async fn vault_access(world: &World, user: &Account, vault: &str, write: bool) -> Result<String, String> {
    crate::require_vault(&world.state, &user.user_id, vault, write)
        .await
        .map(|(role, _, _)| role)
        .map_err(|error| error.body.code)
}

#[tokio::test]
async fn accepted_grant_members_are_restricted_immediately_with_union_semantics() {
    let world = World::new().await;
    let alice = world.account("alice@example.test").await;
    let bob = world.account("bob@example.test").await;
    let carol = world.account("carol@example.test").await;
    let (_, org) = world.bearer(&alice, Method::POST, "/api/v1/orgs", Some(json!({"name": "Union"}))).await;
    let org_id = org["org_id"].as_str().unwrap().to_owned();
    for member in [&bob, &carol] {
        let (_, invite) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "member"}))).await;
        let (status, _) = world.bearer(member, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": invite["token"]}))).await;
        assert_eq!(status, StatusCode::OK);
    }
    let (_, t1) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/teams"), Some(json!({"name": "T1"}))).await;
    let (_, t2) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/teams"), Some(json!({"name": "T2"}))).await;
    let (t1, t2) = (t1["team_id"].as_str().unwrap().to_owned(), t2["team_id"].as_str().unwrap().to_owned());
    let team_path = |team: &str| format!("/api/v1/orgs/{org_id}/teams/{team}/members");
    let mut t1_rev = 1;
    let mut t2_rev = 1;
    for (team, rev, users) in [(&t1, &mut t1_rev, vec![bob.user_id.clone(), carol.user_id.clone()]), (&t2, &mut t2_rev, vec![bob.user_id.clone()])] {
        let (status, _) = world.bearer(&alice, Method::PUT, &team_path(team), Some(json!({"user_ids": users, "expected_revision": *rev}))).await;
        assert_eq!(status, StatusCode::OK);
        *rev += 1;
    }
    // Carol is a DIRECT member (existing out-of-band invitation, no provenance).
    let vault = world.vault(&alice, &[(&carol, "editor")]).await;
    world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/organization"), Some(json!({"org_id": org_id}))).await;
    let (_, grant) = world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/team/{t1}"), Some(json!({"role": "editor", "expected_grants_revision": 1}))).await;
    let (_, _) = world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/team/{t2}"), Some(json!({"role": "viewer", "expected_grants_revision": grant["grants_revision"]}))).await;
    // Bob's membership was established by an owner-consented key delivery
    // and accepted invitation (the full real flow runs in the black-box
    // suite); here the resulting rows are created directly.
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
        .bind(&vault).bind(&bob.user_id).bind(crate::now_rfc3339()).execute(&world.state.db).await.unwrap();
    sqlx::query("INSERT INTO cloud_vault_member_sources(vault_id,user_id,created_epoch) VALUES(?,?,0)")
        .bind(&vault).bind(&bob.user_id).execute(&world.state.db).await.unwrap();
    assert_eq!(vault_access(&world, &bob, &vault, true).await, Ok("editor".into()));

    // Leaving T1 keeps the T2 grant: union ⇒ viewer, writes refused now.
    let (status, _) = world.bearer(&alice, Method::PUT, &team_path(&t1), Some(json!({"user_ids": [carol.user_id], "expected_revision": t1_rev}))).await;
    assert_eq!(status, StatusCode::OK);
    t1_rev += 1;
    assert_eq!(vault_access(&world, &bob, &vault, true).await, Err("VAULT_READ_ONLY".into()));
    assert_eq!(vault_access(&world, &bob, &vault, false).await, Ok("viewer".into()));
    let mut tx = world.state.db.begin().await.unwrap();
    assert!(crate::require_vault_write_tx(&mut tx, &bob.user_id, &vault).await.is_err());
    drop(tx);
    let (_, vaults) = world.bearer(&bob, Method::GET, "/api/v1/vaults", None).await;
    let listed = vaults["vaults"].as_array().unwrap().iter().find(|v| v["vault_id"] == json!(vault)).unwrap().clone();
    assert_eq!(listed["can_write"], false);
    // The signed role is still reported to the key-holder unchanged.
    let (_, roster) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/members"), None).await;
    assert!(roster.to_string().contains("\"editor\""));
    let (_, dist) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/key-distribution"), None).await;
    assert_eq!(dist["restricted_to_viewer"][0]["user_id"], json!(bob.user_id));

    // Leaving T2 too ⇒ no grant left ⇒ all Vault access blocked immediately.
    let (status, _) = world.bearer(&alice, Method::PUT, &team_path(&t2), Some(json!({"user_ids": [], "expected_revision": t2_rev}))).await;
    assert_eq!(status, StatusCode::OK);
    t2_rev += 1;
    assert_eq!(vault_access(&world, &bob, &vault, false).await, Err("NOT_FOUND".into()));
    let (status, _) = world.bearer(&bob, Method::GET, &format!("/api/v1/vaults/{vault}/membership"), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, vaults) = world.bearer(&bob, Method::GET, "/api/v1/vaults", None).await;
    assert!(!vaults.to_string().contains(&vault));
    let (_, dist) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/key-distribution"), None).await;
    assert_eq!(dist["rotation_required"], true);
    assert_eq!(dist["pending_removals"][0]["server_access"], "blocked");

    // Re-adding to T1 restores (editor) — server enforcement follows grants.
    let (status, _) = world.bearer(&alice, Method::PUT, &team_path(&t1), Some(json!({"user_ids": [carol.user_id, bob.user_id], "expected_revision": t1_rev}))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(vault_access(&world, &bob, &vault, true).await, Ok("editor".into()));

    // Org removal removes coverage again; direct member Carol is untouched
    // even when she is removed from the organization.
    for member in [&bob, &carol] {
        let (status, _) = world.bearer(&alice, Method::DELETE, &format!("/api/v1/orgs/{org_id}/members/{}", member.user_id), None).await;
        assert_eq!(status, StatusCode::OK);
    }
    assert_eq!(vault_access(&world, &bob, &vault, false).await, Err("NOT_FOUND".into()));
    assert_eq!(vault_access(&world, &carol, &vault, true).await, Ok("editor".into()));

    // The key-holder may deliberately keep Bob as a direct member.
    let (status, _) = world.bearer(&bob, Method::POST, &format!("/api/v1/vaults/{vault}/member-sources/{}/make-direct", bob.user_id), Some(json!({}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a restricted member cannot lift their own restriction");
    let (status, _) = world.bearer(&alice, Method::POST, &format!("/api/v1/vaults/{vault}/member-sources/{}/make-direct", bob.user_id), Some(json!({}))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(vault_access(&world, &bob, &vault, true).await, Ok("editor".into()));
    // Detaching the Vault never affects direct members.
    world.bearer(&alice, Method::DELETE, &format!("/api/v1/vaults/{vault}/organization"), None).await;
    assert_eq!(vault_access(&world, &bob, &vault, true).await, Ok("editor".into()));
}

#[tokio::test]
async fn malformed_present_config_keeps_sharing_closed_and_unadvertised() {
    let world = World::with(|config| config.config_errors.push("ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS")).await;
    let (_, _, info) = world.call(Method::GET, "/api/v1/instance", HeaderMap::new(), None).await;
    assert!(!info["capabilities"].as_array().unwrap().contains(&json!("share_links")));
    let owner = world.account("o@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let (status, _) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links"), None).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    let world = World::with(|config| config.org_config_errors.push("ATERMIUS_ORG_CREATION")).await;
    let (_, _, info) = world.call(Method::GET, "/api/v1/instance", HeaderMap::new(), None).await;
    assert!(!info["capabilities"].as_array().unwrap().contains(&json!("organizations")));
    let owner = world.account("o@example.test").await;
    let (status, _) = world.bearer(&owner, Method::POST, "/api/v1/orgs", Some(json!({"name": "x"}))).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
}

// ---------------------------------------------------------------------------
// R4.3 — revocation is not delayed by stalled setup or blocked I/O.
// ---------------------------------------------------------------------------

mod live_socket {
    use super::*;
    use futures_util::{SinkExt, StreamExt};
    use std::time::{Duration, Instant};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::{TcpListener, TcpStream},
        sync::mpsc,
    };
    use tokio_tungstenite::{
        connect_async,
        tungstenite::{Message, client::IntoClientRequest},
    };

    #[derive(Clone, Copy)]
    pub(super) enum Guacd {
        /// Accepts and reads `select`, never answers (stalled handshake).
        Stall,
        /// Completes the handshake, then floods output forever.
        Flood,
        /// Completes the handshake, then never reads again.
        Deaf,
    }

    async fn read_instructions(stream: &mut TcpStream, count: usize) -> Option<()> {
        let mut seen = 0;
        let mut byte = [0_u8; 1];
        while seen < count {
            if stream.read(&mut byte).await.ok()? == 0 {
                return None;
            }
            if byte[0] == b';' {
                seen += 1;
            }
        }
        Some(())
    }

    /// Fake guacd; reports the instant its connection ended (EOF/error).
    pub(super) async fn fake_guacd(mode: Guacd) -> (SocketAddr, mpsc::UnboundedReceiver<Instant>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let tx = tx.clone();
                tokio::spawn(async move {
                    if read_instructions(&mut stream, 1).await.is_none() {
                        let _ = tx.send(Instant::now());
                        return;
                    }
                    match mode {
                        Guacd::Stall => {
                            let mut sink = [0_u8; 256];
                            while matches!(stream.read(&mut sink).await, Ok(n) if n > 0) {}
                        }
                        Guacd::Flood | Guacd::Deaf => {
                            let args = crate::desktop::encode(&[
                                "args", "VERSION_1_5_0", "hostname", "port", "username", "password",
                                "cert-fingerprints", "ignore-cert", "disable-copy", "disable-paste", "security",
                            ]);
                            stream.write_all(args.as_bytes()).await.unwrap();
                            if read_instructions(&mut stream, 5).await.is_none() {
                                let _ = tx.send(Instant::now());
                                return;
                            }
                            stream.write_all(crate::desktop::encode(&["ready", "fixture"]).as_bytes()).await.unwrap();
                            if matches!(mode, Guacd::Flood) {
                                let chunk = crate::desktop::encode(&["nop"]).repeat(8192);
                                while stream.write_all(chunk.as_bytes()).await.is_ok() {}
                            } else {
                                // Never read. A tiny periodic write detects the
                                // gateway dropping us (EPIPE/RST) without
                                // draining the backlog it cannot deliver.
                                let nop = crate::desktop::encode(&["nop"]);
                                loop {
                                    tokio::time::sleep(Duration::from_millis(50)).await;
                                    if stream.write_all(nop.as_bytes()).await.is_err() {
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    let _ = tx.send(Instant::now());
                });
            }
        });
        (addr, rx)
    }

    pub(super) async fn serve(world: &mut World, guacd: SocketAddr) -> SocketAddr {
        let mut config = (*world.state.config).clone();
        config.guacd_address = Some(guacd.to_string());
        world.state.config = Arc::new(config);
        let app = crate::router(world.state.clone()).await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await
        });
        addr
    }

    pub(super) async fn rdp_link(world: &World, owner: &Account, vault: &str) -> Value {
        rdp_link_with(world, owner, vault, json!({"max_redemptions": 3})).await
    }

    pub(super) async fn rdp_link_with(world: &World, owner: &Account, vault: &str, options: Value) -> Value {
        let (host, revision) = world.host(vault).await;
        let body = world.sealed_capsule(owner, vault, &host, &revision, "rdp", "10.1.2.3", 3389, Some(&"ab".repeat(32)));
        let (status, value) = world
            .bearer(owner, Method::PUT, &format!("/api/v1/vaults/{vault}/hosts/{host}/gateway-capsule"), Some(body))
            .await;
        assert_eq!(status, StatusCode::OK, "{value}");
        let (link, slug, token) = world.link(owner, vault, &host, options).await;
        json!({"link": link, "slug": slug, "token": token})
    }

    /// Redeems [link] as a new guest: (cookie, target_id).
    pub(super) async fn redeem_guest(world: &World, link: &Value) -> (String, String) {
        let (status, headers, view) = world.redeem(link["slug"].as_str().unwrap(), link["token"].as_str().unwrap()).await;
        assert_eq!(status, StatusCode::OK, "{view}");
        (super::cookie_from(&headers), view["targets"][0]["target_id"].as_str().unwrap().to_owned())
    }

    /// Issues a ticket through the real handler (asserts success).
    pub(super) async fn issue_ticket(world: &World, link: &Value, cookie: &str, target: &str) -> String {
        let mut guest = World::guest_headers(Some(cookie));
        guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let (status, _, ticket) = world
            .call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": link["slug"], "target_id": target})))
            .await;
        assert_eq!(status, StatusCode::OK, "{ticket}");
        ticket["ticket"].as_str().unwrap().to_owned()
    }

    /// Presents [ticket] on a served gateway socket. Ok(socket) once admitted
    /// (and the `open` frame sent), Err((close code, reason)) when refused.
    pub(super) async fn authenticate(server: SocketAddr, cookie: &str, ticket: &str) -> Result<Socket, (u16, String)> {
        let mut request = format!("ws://{server}/gateway/v1/connect").into_client_request().unwrap();
        request.headers_mut().insert("origin", ORIGIN.parse().unwrap());
        request.headers_mut().insert("cookie", format!("__Host-atermius-guest={cookie}").parse().unwrap());
        let (mut socket, _) = connect_async(request).await.unwrap();
        socket
            .send(Message::Text(json!({"type": "authenticate", "ticket": ticket}).to_string().into()))
            .await
            .unwrap();
        match socket.next().await {
            Some(Ok(Message::Text(text))) if text.contains("\"authenticated\"") => {
                socket
                    .send(Message::Text(json!({"type": "open", "width": 1024, "height": 768}).to_string().into()))
                    .await
                    .unwrap();
                Ok(socket)
            }
            Some(Ok(Message::Close(Some(frame)))) => Err((u16::from(frame.code), frame.reason.to_string())),
            other => panic!("unexpected gateway answer: {other:?}"),
        }
    }

    pub(super) type Socket = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

    pub(super) async fn open_gateway(world: &World, server: SocketAddr, link: &Value) -> Socket {
        let (status, headers, view) = world.redeem(link["slug"].as_str().unwrap(), link["token"].as_str().unwrap()).await;
        assert_eq!(status, StatusCode::OK, "{view}");
        let cookie = super::cookie_from(&headers);
        let mut guest = World::guest_headers(Some(&cookie));
        guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
        let (status, _, ticket) = world
            .call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": link["slug"], "target_id": view["targets"][0]["target_id"]})))
            .await;
        assert_eq!(status, StatusCode::OK, "{ticket}");
        let mut request = format!("ws://{server}/gateway/v1/connect").into_client_request().unwrap();
        request.headers_mut().insert("origin", ORIGIN.parse().unwrap());
        request.headers_mut().insert("cookie", format!("__Host-atermius-guest={cookie}").parse().unwrap());
        let (mut socket, _) = connect_async(request).await.unwrap();
        socket
            .send(Message::Text(json!({"type": "authenticate", "ticket": ticket["ticket"]}).to_string().into()))
            .await
            .unwrap();
        let hello = socket.next().await.unwrap().unwrap();
        assert!(hello.to_text().unwrap().contains("authenticated"), "{hello:?}");
        socket
            .send(Message::Text(json!({"type": "open", "width": 1024, "height": 768}).to_string().into()))
            .await
            .unwrap();
        socket
    }

    pub(super) async fn revoke(world: &World, owner: &Account, vault: &str, link: &Value) -> Instant {
        let started = Instant::now();
        let (status, _) = world
            .bearer(owner, Method::POST, &format!("/api/v1/vaults/{vault}/share-links/{}/revoke", link["link"]["link_id"].as_str().unwrap()), Some(json!({})))
            .await;
        assert_eq!(status, StatusCode::OK);
        started
    }

    pub(super) async fn close_code(socket: &mut Socket) -> Option<u16> {
        while let Some(message) = socket.next().await {
            match message {
                Ok(Message::Close(frame)) => return frame.map(|f| u16::from(f.code)),
                Ok(_) => continue,
                Err(_) => return None,
            }
        }
        None
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn revocation_cancels_a_stalled_guacd_handshake_within_bound() {
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, mut ended) = fake_guacd(Guacd::Stall).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link(&world, &owner, &vault).await;
    let mut socket = open_gateway(&world, server, &link).await;
    // Let setup reach the stalled guacd handshake (credentials already sealed in memory).
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let started = revoke(&world, &owner, &vault, &link).await;
    let code = tokio::time::timeout(std::time::Duration::from_secs(3), close_code(&mut socket)).await;
    assert_eq!(code.expect("closed within 3 s"), Some(4403));
    let upstream = tokio::time::timeout(std::time::Duration::from_secs(3), ended.recv()).await.expect("upstream dropped").unwrap();
    assert!(upstream.duration_since(started) <= std::time::Duration::from_secs(3));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn revocation_is_not_delayed_by_a_guest_that_stops_reading() {
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, mut ended) = fake_guacd(Guacd::Flood).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link(&world, &owner, &vault).await;
    // The guest never reads again; guacd keeps flooding until buffers fill.
    let _socket = open_gateway(&world, server, &link).await;
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let started = revoke(&world, &owner, &vault, &link).await;
    let upstream = tokio::time::timeout(std::time::Duration::from_secs(3), ended.recv()).await.expect("upstream dropped").unwrap();
    assert!(upstream.duration_since(started) <= std::time::Duration::from_secs(3));
    // The connection is recorded as ended for the owner's activity view.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(3);
    loop {
        let open: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM share_gateway_connections WHERE ended_epoch IS NULL")
            .fetch_one(&world.state.db).await.unwrap();
        if open == 0 {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "connection row not ended");
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn revocation_is_not_delayed_by_an_upstream_that_stops_reading() {
    use futures_util::{SinkExt, StreamExt};
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, mut ended) = fake_guacd(Guacd::Deaf).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link(&world, &owner, &vault).await;
    let socket = open_gateway(&world, server, &link).await;
    let (mut sink, mut stream) = socket.split();
    // Flood valid key input so the gateway's upstream write blocks.
    let flood = crate::desktop::encode(&["key", "65", "1"]).repeat(4000);
    let writer = tokio::spawn(async move {
        loop {
            let send = sink.send(tokio_tungstenite::tungstenite::Message::Binary(flood.clone().into_bytes().into()));
            if tokio::time::timeout(std::time::Duration::from_millis(200), send).await.map_or(true, |r| r.is_err()) {
                // Our own send is backpressured: stop writing so the reader
                // half (which shares the connection) can observe the close.
                break;
            }
        }
        sink
    });
    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
    let blocked: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM share_gateway_connections WHERE ended_epoch IS NULL")
        .fetch_one(&world.state.db).await.unwrap();
    assert_eq!(blocked, 1, "connection is live while the upstream is not reading");
    let started = revoke(&world, &owner, &vault, &link).await;
    // Server side: the upstream is dropped and the connection ended within the bound.
    let upstream = tokio::time::timeout(std::time::Duration::from_secs(3), ended.recv()).await.expect("upstream dropped within 3 s").unwrap();
    assert!(upstream.duration_since(started) <= std::time::Duration::from_secs(3));
    // Guest side: a close (or connection end) is observed within the bound.
    let _sink = writer.await.unwrap();
    let observed = tokio::time::timeout(std::time::Duration::from_secs(3), async {
        while let Some(message) = stream.next().await {
            match message {
                Ok(tokio_tungstenite::tungstenite::Message::Close(frame)) => return frame.map(|f| u16::from(f.code)),
                Ok(_) => continue,
                Err(_) => return None,
            }
        }
        None
    })
    .await;
    assert!(observed.is_ok(), "guest saw the connection end within 3 s");
    assert!(started.elapsed() <= std::time::Duration::from_secs(4));
}

// ---------------------------------------------------------------------------
// R5 — capsule sealer lifecycle; R4 follow-up — audit authorization.
// ---------------------------------------------------------------------------

#[tokio::test]
async fn sealer_device_revocation_and_authority_loss_stop_guest_access() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let editor = world.account("editor@example.test").await;
    let vault = world.vault(&owner, &[(&editor, "editor")]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_redemptions": 3})).await;
    let target = link["targets"][0]["target_id"].as_str().unwrap().to_owned();
    let (_, headers, _) = world.redeem(&slug, &token).await;
    let cookie = cookie_from(&headers);
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let session: String = sqlx::query_scalar("SELECT guest_session_id FROM share_guest_sessions LIMIT 1")
        .fetch_one(&world.state.db).await.unwrap();
    let established = || {
        let (state, session, target) = (world.state.clone(), session.clone(), target.clone());
        async move {
            let mut tx = state.db.begin().await.unwrap();
            crate::share_guest::authorize_tx(&mut tx, &state, &session, &target, Some((1, 1)), cloud::now_epoch(), true)
                .await
                .map(|_| ())
        }
    };
    // Ticket issued before the device revocation …
    let (status, _, ticket) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": slug, "target_id": target}))).await;
    assert_eq!(status, StatusCode::OK, "{ticket}");
    assert!(established().await.is_ok());
    // … the owner's sealing device is revoked (the account stays the owner,
    // so only the sealer predicate can catch this).
    sqlx::query("UPDATE devices SET status='revoked' WHERE device_id=?")
        .bind(&owner.device_id).execute(&world.state.db).await.unwrap();
    // Established connections fail their next recheck,
    assert_eq!(established().await, Err(crate::share_guest::Denied::Revoked("sealer_authority_lost")));
    // the already issued ticket can no longer be consumed (same predicate),
    let mut tx = world.state.db.begin().await.unwrap();
    let consume = crate::share_guest::authorize_tx(&mut tx, &world.state, &session, &target, Some((1, 1)), cloud::now_epoch(), false).await;
    assert!(matches!(consume, Err(crate::share_guest::Denied::Revoked("sealer_authority_lost"))));
    drop(tx);
    // and new tickets are refused.
    let (status, _, value) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": slug, "target_id": target}))).await;
    assert_eq!((status, value["error"]["details"]["reason"].as_str()), (StatusCode::FORBIDDEN, Some("sealer_authority_lost")));
    // The owner sees the honest state.
    let (status, _) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{}", link["link_id"].as_str().unwrap()), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED, "the owner's revoked device cannot manage links either");
    let rows: Vec<String> = sqlx::query_scalar("SELECT state FROM share_host_capsules").fetch_all(&world.state.db).await.unwrap();
    assert_eq!(rows, vec!["active".to_owned()]);
    // Restoring the device restores access; then the sealer loses Vault
    // authority (ownership transferred) → refused again.
    sqlx::query("UPDATE devices SET status='active' WHERE device_id=?")
        .bind(&owner.device_id).execute(&world.state.db).await.unwrap();
    assert!(established().await.is_ok());
    let (_, capsules) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-capsules"), None).await;
    assert_eq!(capsules["capsules"][0]["status"], "active");
    sqlx::query("UPDATE vault_members SET role=CASE user_id WHEN ? THEN 'editor' ELSE 'owner' END WHERE vault_id=?")
        .bind(&owner.user_id).bind(&vault).execute(&world.state.db).await.unwrap();
    assert!(matches!(established().await, Err(crate::share_guest::Denied::Revoked(_))));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sealer_device_revocation_closes_an_established_gateway_socket_within_bound() {
    use futures_util::StreamExt;
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, _ended) = fake_guacd(Guacd::Deaf).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link(&world, &owner, &vault).await;
    let mut socket = open_gateway(&world, server, &link).await;
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let started = std::time::Instant::now();
    // Revoked through the regular device-lifecycle path (no cloud broadcast):
    // the 2-second recheck alone must close the connection.
    sqlx::query("UPDATE devices SET status='revoked',revoked_at=? WHERE device_id=?")
        .bind(crate::now_rfc3339()).bind(&owner.device_id).execute(&world.state.db).await.unwrap();
    let code = tokio::time::timeout(std::time::Duration::from_secs(3), close_code(&mut socket)).await;
    assert_eq!(code.expect("closed within 3 s"), Some(4403));
    assert!(started.elapsed() <= std::time::Duration::from_secs(3));
    let _ = socket.next().await;
}

#[tokio::test]
async fn vault_audit_listing_honours_restrictions_including_existing_cursors() {
    let world = World::new().await;
    let alice = world.account("alice@example.test").await;
    let bob = world.account("bob@example.test").await;
    let (_, org) = world.bearer(&alice, Method::POST, "/api/v1/orgs", Some(json!({"name": "Audit"}))).await;
    let org_id = org["org_id"].as_str().unwrap().to_owned();
    let (_, invite) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "member"}))).await;
    world.bearer(&bob, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": invite["token"]}))).await;
    let vault = world.vault(&alice, &[]).await;
    world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/organization"), Some(json!({"org_id": org_id}))).await;
    let (_, grant) = world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/user/{}", bob.user_id), Some(json!({"role": "editor", "expected_grants_revision": 1}))).await;
    sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state,added_at) VALUES(?,?,'editor','active',?)")
        .bind(&vault).bind(&bob.user_id).bind(crate::now_rfc3339()).execute(&world.state.db).await.unwrap();
    sqlx::query("INSERT INTO cloud_vault_member_sources(vault_id,user_id,created_epoch) VALUES(?,?,0)")
        .bind(&vault).bind(&bob.user_id).execute(&world.state.db).await.unwrap();
    for i in 0..5 {
        sqlx::query("INSERT INTO audit_events(scope_type,scope_id,actor_user_id,actor_device_id,action,resource_type,resource_id,result,occurred_at,source) VALUES('vault',?,?,NULL,'vault.test_event','vault',NULL,'success',?,'api')")
            .bind(&vault).bind(&alice.user_id).bind(1_000 + i).execute(&world.state.db).await.unwrap();
    }
    let vault_rows = |page: &Value| page["events"].as_array().unwrap().iter().filter(|e| e["action"] == "vault.test_event").count();
    let (status, first) = world.bearer(&bob, Method::GET, "/api/v1/audit?limit=2", None).await;
    assert_eq!(status, StatusCode::OK, "{first}");
    let cursor = first["next_cursor"].as_str().map(str::to_owned);
    let (_, all) = world.bearer(&bob, Method::GET, "/api/v1/audit?limit=200", None).await;
    assert_eq!(vault_rows(&all), 5, "editor sees Vault audit");
    // Downgrade to viewer through the remaining grant.
    let (status, _) = world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/user/{}", bob.user_id), Some(json!({"role": "viewer", "expected_grants_revision": grant["grants_revision"]}))).await;
    assert_eq!(status, StatusCode::OK);
    let (_, after) = world.bearer(&bob, Method::GET, "/api/v1/audit?limit=200", None).await;
    assert_eq!(vault_rows(&after), 0, "restricted-to-viewer member loses editor audit access");
    if let Some(cursor) = cursor {
        let (status, next) = world.bearer(&bob, Method::GET, &format!("/api/v1/audit?limit=200&cursor={cursor}"), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(vault_rows(&next), 0, "a cursor issued before the change reveals nothing new");
    }
    // Removal ⇒ none.
    let (_, grants) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/grants"), None).await;
    world.bearer(&alice, Method::DELETE, &format!("/api/v1/vaults/{vault}/grants/user/{}", bob.user_id), Some(json!({"expected_grants_revision": grants["grants_revision"]}))).await;
    let (_, after) = world.bearer(&bob, Method::GET, "/api/v1/audit?limit=200", None).await;
    assert_eq!(vault_rows(&after), 0);
    // Departing owner detaches their Vault: grant-derived members lose access.
    let carol = world.account("carol@example.test").await;
    let (_, invite) = world.bearer(&alice, Method::POST, &format!("/api/v1/orgs/{org_id}/invitations"), Some(json!({"role": "admin"}))).await;
    world.bearer(&carol, Method::POST, "/api/v1/org-invitations/accept", Some(json!({"token": invite["token"]}))).await;
    let (_, grants) = world.bearer(&alice, Method::GET, &format!("/api/v1/vaults/{vault}/grants"), None).await;
    world.bearer(&alice, Method::PUT, &format!("/api/v1/vaults/{vault}/grants/user/{}", bob.user_id), Some(json!({"role": "editor", "expected_grants_revision": grants["grants_revision"]}))).await;
    assert!(crate::require_vault(&world.state, &bob.user_id, &vault, true).await.is_ok());
    world.bearer(&alice, Method::PUT, &format!("/api/v1/orgs/{org_id}/members/{}", carol.user_id), Some(json!({"role": "owner"}))).await;
    let (status, _) = world.bearer(&alice, Method::DELETE, &format!("/api/v1/orgs/{org_id}/members/{}", alice.user_id), None).await;
    assert_eq!(status, StatusCode::OK, "alice leaves; her Vault leaves with her");
    assert!(crate::require_vault(&world.state, &bob.user_id, &vault, false).await.is_err());
}

// G2 capsule substitution, G4 Vault deletion / key retirement, G15 expiry.
#[tokio::test]
async fn capsule_swap_vault_deletion_key_retirement_and_session_expiry() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    // G2: valid capsule bytes of Host X presented as Host Y fail the inner binding check.
    let (x, x_rev) = world.host(&vault).await;
    let body = world.sealed_capsule(&owner, &vault, &x, &x_rev, "ssh", "10.1.2.3", 22, Some(&ssh_fp()));
    let row = crate::share_gateway::CapsuleRow {
        vault_id: vault.clone(),
        host_record_id: Uuid::new_v4().to_string(),
        host_revision_id: x_rev.clone(),
        gateway_key_id: world.state.cloud.gateway.as_ref().unwrap().key_id.clone(),
        protocol: "ssh".into(),
        target_host: "10.1.2.3".into(),
        target_port: 22,
        host_identity: Some(ssh_fp()),
        sealed: body["sealed"].as_str().unwrap().to_owned(),
    };
    assert!(matches!(crate::share_gateway::unseal_capsule(&world.state, &row), Err(crate::share_gateway::UnsealError::Mismatch)));
    let ok_row = crate::share_gateway::CapsuleRow { host_record_id: x.clone(), ..row };
    assert!(crate::share_gateway::unseal_capsule(&world.state, &ok_row).is_ok());

    let host = world.shared_host(&owner, &vault).await;
    let (link, slug, token) = world.link(&owner, &vault, &host, json!({"max_redemptions": 3})).await;
    let target = link["targets"][0]["target_id"].as_str().unwrap().to_owned();
    world.redeem(&slug, &token).await;
    let session: String = sqlx::query_scalar("SELECT guest_session_id FROM share_guest_sessions LIMIT 1")
        .fetch_one(&world.state.db).await.unwrap();
    let check = |established: bool| {
        let (state, session, target) = (world.state.clone(), session.clone(), target.clone());
        async move {
            let mut tx = state.db.begin().await.unwrap();
            crate::share_guest::authorize_tx(&mut tx, &state, &session, &target, Some((1, 1)), cloud::now_epoch(), established).await.map(|_| ())
        }
    };
    assert!(check(true).await.is_ok());
    // G4: Vault enters deletion → creator no longer an active-Vault owner.
    sqlx::query("UPDATE vaults SET state='deleting' WHERE vault_id=?").bind(&vault).execute(&world.state.db).await.unwrap();
    assert_eq!(check(true).await, Err(crate::share_guest::Denied::Revoked("creator_lost_access")));
    sqlx::query("UPDATE vaults SET state='active' WHERE vault_id=?").bind(&vault).execute(&world.state.db).await.unwrap();
    // G4: gateway key retired/rotated → capsules stale, connections end.
    // Simulates a restart with a new key file: the capsule's key is no longer active.
    let old_key = Uuid::new_v4().to_string();
    sqlx::query("INSERT INTO share_gateway_keys(key_id,public_key,signed_payload,signature,state,created_at) VALUES(?,?,'p','s','retired',?)")
        .bind(&old_key).bind(format!("retired-{old_key}")).bind(crate::now_rfc3339()).execute(&world.state.db).await.unwrap();
    sqlx::query("UPDATE share_host_capsules SET gateway_key_id=? WHERE host_record_id=?")
        .bind(&old_key).bind(&host).execute(&world.state.db).await.unwrap();
    let retired = check(true).await;
    sqlx::query("UPDATE share_host_capsules SET gateway_key_id=? WHERE host_record_id=?")
        .bind(&world.state.cloud.gateway.as_ref().unwrap().key_id).bind(&host).execute(&world.state.db).await.unwrap();
    assert!(matches!(retired, Err(crate::share_guest::Denied::Revoked("gateway_key_retired"))), "{retired:?}");
    assert!(check(true).await.is_ok());
    // G15: idle new connections refused; session lifetime is absolute.
    let now = cloud::now_epoch();
    sqlx::query("UPDATE share_guest_sessions SET last_seen_epoch=? WHERE guest_session_id=?")
        .bind(now - cloud::GUEST_IDLE_SECONDS).bind(&session).execute(&world.state.db).await.unwrap();
    assert_eq!(check(false).await, Err(crate::share_guest::Denied::Expired("session_idle")));
    sqlx::query("UPDATE share_guest_sessions SET expires_epoch=? WHERE guest_session_id=?")
        .bind(now).bind(&session).execute(&world.state.db).await.unwrap();
    assert_eq!(check(true).await, Err(crate::share_guest::Denied::Expired("session_expired")));
}

// R6.3 — a guest cookie for link A is only usable under A's own address.
#[tokio::test]
async fn guest_session_and_connections_are_bound_to_the_shown_link_address() {
    let world = World::new().await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let host = world.shared_host(&owner, &vault).await;
    let (link_a, slug_a, token_a) = world.link(&owner, &vault, &host, json!({"slug": "address-a"})).await;
    let (_, slug_b, _) = world.link(&owner, &vault, &host, json!({"slug": "address-b"})).await;
    let (_, headers, view) = world.redeem(&slug_a, &token_a).await;
    assert_eq!(view["slug"], "address-a");
    let cookie = cookie_from(&headers);
    let session = |slug: String| {
        let path = format!("/api/v1/guest/session?slug={slug}");
        let headers = World::guest_headers(Some(&cookie));
        let world = &world;
        async move { world.call(Method::GET, &path, headers, None).await }
    };
    // Same-link refresh works and does not consume an opening.
    let (status, _, resumed) = session(slug_a.clone()).await;
    assert_eq!((status, resumed["slug"].as_str()), (StatusCode::OK, Some("address-a")));
    // Another link's address, an unknown address and a missing address all
    // look exactly like an unknown link and reveal nothing about A.
    for other in [slug_b.clone(), "no-such-address".to_owned()] {
        let (status, _, body) = session(other).await;
        assert_eq!((status, body["error"]["code"].as_str()), (StatusCode::NOT_FOUND, Some("SHARE_LINK_UNAVAILABLE")));
        assert!(!body.to_string().contains(link_a["link_id"].as_str().unwrap()));
    }
    let (status, _, _) = world.call(Method::GET, "/api/v1/guest/session", World::guest_headers(Some(&cookie)), None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let mut guest = World::guest_headers(Some(&cookie));
    guest.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/json"));
    let target = link_a["targets"][0]["target_id"].clone();
    for other in [json!(slug_b), json!("no-such-address")] {
        let (status, _, _) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"slug": other, "target_id": target}))).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
    }
    let (status, _, _) = world.call(Method::POST, "/api/v1/guest/connections", guest.clone(), Some(json!({"target_id": target}))).await;
    assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "the address is required");
    let (status, _, ticket) = world.call(Method::POST, "/api/v1/guest/connections", guest, Some(json!({"slug": slug_a, "target_id": target}))).await;
    assert_eq!(status, StatusCode::OK, "{ticket}");
    let (_, current) = world.bearer(&owner, Method::GET, &format!("/api/v1/vaults/{vault}/share-links/{}", link_a["link_id"].as_str().unwrap()), None).await;
    assert_eq!(current["redemptions"], 1);
}

// R6.4 — the full ≤3 s budget holds when authorization checks are slow.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn revocation_budget_holds_with_slow_authorization_checks() {
    use live_socket::*;
    for (delay_ms, label) in [(800_u64, "slow but within the check bound"), (2500, "slower than the check bound: fail closed")] {
        let mut world = World::new().await;
        let (guacd, _ended) = fake_guacd(Guacd::Deaf).await;
        let server = serve(&mut world, guacd).await;
        let owner = world.account("owner@example.test").await;
        let vault = world.vault(&owner, &[]).await;
        let link = rdp_link(&world, &owner, &vault).await;
        let mut socket = open_gateway(&world, server, &link).await;
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        world.state.cloud.recheck_delay_ms.store(delay_ms, std::sync::atomic::Ordering::Relaxed);
        // Revocation through a path that sends no wake-up (device lifecycle),
        // so detection relies on the poll + bounded check.
        let started = std::time::Instant::now();
        sqlx::query("UPDATE devices SET status='revoked',revoked_at=? WHERE device_id=?")
            .bind(crate::now_rfc3339()).bind(&owner.device_id).execute(&world.state.db).await.unwrap();
        let code = tokio::time::timeout(std::time::Duration::from_secs(4), close_code(&mut socket)).await;
        let elapsed = started.elapsed();
        assert_eq!(code.expect(label), Some(4403), "{label}");
        assert!(elapsed <= std::time::Duration::from_secs(3), "{label}: closed after {elapsed:?}");
    }
}


// ---------------------------------------------------------------------------
// G14: quota is charged only on gateway admission (issue → consume boundary)
// ---------------------------------------------------------------------------

async fn link_connections(world: &World, link: &Value) -> i64 {
    sqlx::query_scalar("SELECT connections FROM share_links WHERE link_id=?")
        .bind(link["link"]["link_id"].as_str().unwrap())
        .fetch_one(&world.state.db)
        .await
        .unwrap()
}

async fn ticket_consumed(world: &World, ticket: &str) -> bool {
    let consumed: Option<i64> = sqlx::query_scalar("SELECT consumed_epoch FROM share_gateway_tickets WHERE ticket_hash=?")
        .bind(crate::sha256_hex(ticket.as_bytes()))
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    consumed.is_some()
}

async fn wait_until(what: &str, mut done: impl AsyncFnMut() -> bool) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while !done().await {
        assert!(std::time::Instant::now() < deadline, "{what}");
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn instance_capacity_refusal_neither_consumes_the_ticket_nor_charges_the_link() {
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, _ended) = fake_guacd(Guacd::Deaf).await;
    let server = serve(&mut world, guacd).await;
    // Instance capacity 1: hold every other slot for the whole test.
    let slots = world.state.cloud.guest_connection_slots.clone();
    let _reserved = slots.clone().try_acquire_many_owned((slots.available_permits() - 1) as u32).unwrap();
    assert_eq!(slots.available_permits(), 1);
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link_a = rdp_link_with(&world, &owner, &vault, json!({"max_connections": 5})).await;
    let link_b = rdp_link_with(&world, &owner, &vault, json!({"max_connections": 1})).await;
    let (cookie_a, target_a) = redeem_guest(&world, &link_a).await;
    let (cookie_b, target_b) = redeem_guest(&world, &link_b).await;
    // Both tickets are issued while the instance is idle.
    let ticket_a = issue_ticket(&world, &link_a, &cookie_a, &target_a).await;
    let ticket_b = issue_ticket(&world, &link_b, &cookie_b, &target_b).await;

    let first = authenticate(server, &cookie_a, &ticket_a).await.expect("first connection admitted");
    let refused = authenticate(server, &cookie_b, &ticket_b).await.err().expect("second refused at capacity");
    assert_eq!(refused, (4429, "instance_capacity".to_owned()));
    assert!(!ticket_consumed(&world, &ticket_b).await, "a capacity refusal does not consume the ticket");
    assert_eq!(link_connections(&world, &link_b).await, 0, "nor charge max_connections");
    assert_eq!(link_connections(&world, &link_a).await, 1);

    // The first guest leaves; the slot frees; the SAME ticket is now admitted
    // and uses link B's only connection attempt.
    drop(first);
    wait_until("instance slot released", async || slots.available_permits() == 1).await;
    let second = authenticate(server, &cookie_b, &ticket_b).await.expect("admitted after the slot was released");
    assert!(ticket_consumed(&world, &ticket_b).await);
    assert_eq!(link_connections(&world, &link_b).await, 1);
    // A consumed ticket is one-use.
    drop(second);
    wait_until("instance slot released", async || slots.available_permits() == 1).await;
    assert_eq!(authenticate(server, &cookie_b, &ticket_b).await.err(), Some((4401, "invalid_ticket".to_owned())));
    assert_eq!(link_connections(&world, &link_b).await, 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_admission_race_on_one_slot_charges_only_the_winner() {
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, _ended) = fake_guacd(Guacd::Deaf).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link_with(&world, &owner, &vault, json!({"max_redemptions": 2, "max_connections": 5, "max_concurrent": 1})).await;
    let (cookie_1, target) = redeem_guest(&world, &link).await;
    let (cookie_2, _) = redeem_guest(&world, &link).await;
    // Both tickets are issued while the link is idle (issuance cannot see the race).
    let ticket_1 = issue_ticket(&world, &link, &cookie_1, &target).await;
    let ticket_2 = issue_ticket(&world, &link, &cookie_2, &target).await;
    assert_eq!(link_connections(&world, &link).await, 0);

    let (one, two) = tokio::join!(authenticate(server, &cookie_1, &ticket_1), authenticate(server, &cookie_2, &ticket_2));
    let (winner, (loser_cookie, loser_ticket, refusal)) = match (one, two) {
        (Ok(socket), Err(refusal)) => (socket, (cookie_2, ticket_2, refusal)),
        (Err(refusal), Ok(socket)) => (socket, (cookie_1, ticket_1, refusal)),
        other => panic!("exactly one admission expected: {:?}", (other.0.is_ok(), other.1.is_ok())),
    };
    assert_eq!(refusal, (4429, "concurrency".to_owned()));
    assert_eq!(link_connections(&world, &link).await, 1, "only the admitted connection is charged");
    assert!(!ticket_consumed(&world, &loser_ticket).await, "the losing ticket stays usable");
    let live: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM share_gateway_connections WHERE ended_epoch IS NULL")
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(live, 1, "max_concurrent 1 is exact");

    // After the winner ends, the loser's untouched ticket is admitted.
    drop(winner);
    wait_until("winner ended", async || {
        sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM share_gateway_connections WHERE ended_epoch IS NULL")
            .fetch_one(&world.state.db)
            .await
            .unwrap()
            == 0
    })
    .await;
    let _late = authenticate(server, &loser_cookie, &loser_ticket).await.expect("admitted once the slot is free");
    assert_eq!(link_connections(&world, &link).await, 2);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn simultaneous_admissions_never_exceed_max_connections() {
    use live_socket::*;
    let mut world = World::new().await;
    let (guacd, _ended) = fake_guacd(Guacd::Deaf).await;
    let server = serve(&mut world, guacd).await;
    let owner = world.account("owner@example.test").await;
    let vault = world.vault(&owner, &[]).await;
    let link = rdp_link_with(&world, &owner, &vault, json!({"max_redemptions": 3, "max_connections": 1, "max_concurrent": 3})).await;
    let mut guests = Vec::new();
    for _ in 0..3 {
        let (cookie, target) = redeem_guest(&world, &link).await;
        let ticket = issue_ticket(&world, &link, &cookie, &target).await;
        guests.push((cookie, ticket));
    }
    assert_eq!(link_connections(&world, &link).await, 0, "three tickets issued, nothing charged");
    let (a, b, c) = tokio::join!(
        authenticate(server, &guests[0].0, &guests[0].1),
        authenticate(server, &guests[1].0, &guests[1].1),
        authenticate(server, &guests[2].0, &guests[2].1),
    );
    let results = [a, b, c];
    let admitted = results.iter().filter(|r| r.is_ok()).count();
    assert_eq!(admitted, 1, "exactly one simultaneous admission");
    for refused in results.iter().filter_map(|r| r.as_ref().err()) {
        assert_eq!(refused, &(4429, "exhausted".to_owned()));
    }
    assert_eq!(link_connections(&world, &link).await, 1, "max_connections 1 is never exceeded");
    let started: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM share_gateway_connections")
        .fetch_one(&world.state.db)
        .await
        .unwrap();
    assert_eq!(started, 1);
}

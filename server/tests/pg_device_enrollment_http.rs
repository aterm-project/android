//! Full Axum route and middleware acceptance for PostgreSQL device enrollment.
//!
//! Run through `server/scripts/test-pg-device-enrollment-http.sh`; the runner creates
//! a disposable loopback-only PostgreSQL 17 database whose name starts with
//! `atermius_test_`, then removes the container on exit.

use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    str::FromStr,
    time::Duration,
};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use sqlx::{
    PgPool, Row,
    postgres::{PgConnectOptions, PgPoolOptions},
};
use uuid::Uuid;

const RUNTIME_SCHEMA: &str = "atermius_device_enrollment_http";
const MIGRATIONS: &[&str] = &[
    "0001_sync_commit_core.sql",
    "0002_sync_changes_retention.sql",
    "0003_instance_meta.sql",
    "0004_auth_rate_limits.sql",
    "0005_sync_conflict_feed.sql",
    "0006_sync_conflict_write.sql",
    "0007_sync_snapshots.sql",
    "0008_sync_snapshot_pages.sql",
    "0009_auth_lifecycle.sql",
    "0010_account_onboarding.sql",
    "0011_vault_invitations.sql",
    "0012_vault_deletion.sql",
    "0013_account_deletion.sql",
    "0014_account_recovery.sql",
    "0015_object_storage.sql",
    "0016_password_change_receipts.sql",
    "0017_postgres_totp_mfa.sql",
    "0018_audit_event_order.sql",
    "0019_mobile_push_outbox_due.sql",
    "0020_instance_audit_event_index.sql",
    "0021_vault_presence.sql",
    "0022_instance_admin_maintenance_jobs.sql",
    "0023_notification_tickets.sql",
    "0024_backup_object_pins.sql",
    "0025_instance_admin_backup_restore_jobs.sql",
    "0026_instance_backup_schedule.sql",
    "0027_shared_ssh_relay.sql",
    "0028_restore_stage_discard.sql",
    "0029_redaction_capability_reports.sql",
    "0030_record_redactions.sql",
    "0031_redacted_conflict_resolution.sql",
    "0032_record_restore_deadlines.sql",
    "0033_record_auto_purge_opt_in.sql",
    "0034_record_auto_purge_scan.sql",
    "0035_instance_metrics_credential.sql",
    "0036_instance_backup_replications.sql",
    "0037_instance_backup_replication_leases.sql",
    "0038_replica_restore_sources.sql",
    "0039_mobile_push_delivery_daily.sql",
];

struct TestDatabase {
    pool: PgPool,
    admin_pool: PgPool,
    schema: String,
    cleaned: bool,
}

impl TestDatabase {
    async fn create() -> Self {
        let url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("run the disposable PostgreSQL 17 acceptance script");
        let parsed = url::Url::parse(&url).expect("valid PostgreSQL test URL");
        assert!(
            matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "::1")),
            "refusing non-loopback PostgreSQL test host"
        );
        let database = parsed.path().trim_start_matches('/');
        assert!(
            database.starts_with("atermius_test_"),
            "refusing a database outside the explicitly disposable atermius_test_* namespace"
        );
        let schema = std::env::var("ATERMIUS_SYNC_PG_SCHEMA")
            .expect("acceptance runner must select an isolated runtime schema");
        assert_eq!(schema, RUNTIME_SCHEMA);

        let options = PgConnectOptions::from_str(&url).expect("valid PostgreSQL test URL");
        let admin_pool = PgPoolOptions::new()
            .max_connections(3)
            .connect_with(options.clone())
            .await
            .expect("connect only to the disposable loopback PostgreSQL database");
        let exists: bool = sqlx::query_scalar("SELECT to_regnamespace($1) IS NOT NULL")
            .bind(&schema)
            .fetch_one(&admin_pool)
            .await
            .expect("check isolated schema name");
        assert!(!exists, "refusing to reuse existing test schema {schema}");
        sqlx::query(&format!("CREATE SCHEMA \"{schema}\""))
            .execute(&admin_pool)
            .await
            .expect("create isolated enrollment runtime schema");

        let pool = PgPoolOptions::new()
            .max_connections(8)
            .connect_with(options.options([("search_path", format!("\"{schema}\""))]))
            .await
            .expect("connect to isolated enrollment runtime schema");
        let migration_dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations/postgres");
        let available = fs::read_dir(&migration_dir)
            .expect("read PostgreSQL migrations")
            .map(|entry| entry.expect("read migration entry").file_name())
            .filter_map(|name| name.into_string().ok())
            .filter(|name| name.ends_with(".sql"))
            .collect::<std::collections::HashSet<_>>();
        for migration in MIGRATIONS {
            assert!(
                available.contains(*migration),
                "expected current PostgreSQL migration {migration}"
            );
            let sql = fs::read_to_string(migration_dir.join(migration))
                .expect("read PostgreSQL migration");
            sqlx::raw_sql(&sql)
                .execute(&pool)
                .await
                .unwrap_or_else(|error| panic!("apply PostgreSQL migration {migration}: {error}"));
        }
        assert_eq!(
            MIGRATIONS.len(),
            39,
            "runtime must be tested at current schema"
        );

        Self {
            pool,
            admin_pool,
            schema,
            cleaned: false,
        }
    }

    async fn cleanup(&mut self) {
        self.pool.close().await;
        sqlx::query(&format!(
            "DROP SCHEMA IF EXISTS \"{}\" CASCADE",
            self.schema
        ))
        .execute(&self.admin_pool)
        .await
        .expect("drop isolated device-enrollment schema");
        self.admin_pool.close().await;
        self.cleaned = true;
    }
}

impl Drop for TestDatabase {
    fn drop(&mut self) {
        if self.cleaned {
            return;
        }
        let pool = self.pool.clone();
        let admin_pool = self.admin_pool.clone();
        let schema = self.schema.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                pool.close().await;
                let _ = sqlx::query(&format!("DROP SCHEMA IF EXISTS \"{schema}\" CASCADE"))
                    .execute(&admin_pool)
                    .await;
                admin_pool.close().await;
            });
        }
    }
}

fn sign_json(key: &SigningKey, value: &Value) -> String {
    URL_SAFE_NO_PAD.encode(
        key.sign(&serde_jcs::to_vec(value).expect("canonicalize JSON"))
            .to_bytes(),
    )
}

fn signed_enrollment(
    account_id: &str,
    approver_device_id: &str,
    vault_id: &str,
    approver_key: &SigningKey,
    target_device_id: &str,
    epochs: &[i64],
) -> Value {
    let target_key = SigningKey::from_bytes(&[11; 32]);
    let signing_public_key = URL_SAFE_NO_PAD.encode(target_key.verifying_key().as_bytes());
    let encryption_public_key = URL_SAFE_NO_PAD.encode([13; 32]);
    let device_proof = json!({
        "account_id": account_id,
        "device_id": target_device_id,
        "encryption_public_key": encryption_public_key,
        "signing_public_key": signing_public_key,
    });
    let device = json!({
        "device_id": target_device_id,
        "name": "new device",
        "signing_public_key": signing_public_key,
        "encryption_public_key": encryption_public_key,
        "signature": sign_json(&target_key, &device_proof),
    });
    let certificate_payload = json!({
        "account_id": account_id,
        "approver_device_id": approver_device_id,
        "device": device,
    });
    let vault_key_envelopes = epochs
        .iter()
        .map(|epoch| {
            let envelope = json!({
                "version": 1,
                "suite": "crypto_box_seal",
                "ciphertext": URL_SAFE_NO_PAD.encode([*epoch as u8; 48]),
            });
            let key_payload = json!({
                "vault_id": vault_id,
                "recipient_device_id": target_device_id,
                "key_epoch": epoch,
                "membership_version": 1,
                "envelope": envelope,
            });
            json!({
                "vault_id": vault_id,
                "recipient_device_id": target_device_id,
                "key_epoch": epoch,
                "membership_version": 1,
                "envelope": envelope,
                "signature": sign_json(approver_key, &key_payload),
            })
        })
        .collect::<Vec<_>>();
    json!({
        "device": device,
        "approver_device_id": approver_device_id,
        "certificate_signature": sign_json(approver_key, &certificate_payload),
        "vault_key_envelopes": vault_key_envelopes,
    })
}

async fn post_enrollment(
    client: &reqwest::Client,
    base_url: &str,
    access_token: &str,
    body: Value,
) -> (u16, Value) {
    let response = client
        .post(format!("{base_url}/api/v1/devices"))
        .bearer_auth(access_token)
        .json(&body)
        .send()
        .await
        .expect("send request through local HTTP server and middleware");
    let status = response.status().as_u16();
    let body = response.json().await.expect("decode HTTP JSON response");
    (status, body)
}

fn access_hash(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

struct PgObjectGcWorker {
    child: Child,
}

impl Drop for PgObjectGcWorker {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn spawn_pg_object_gc_worker(data_dir: &Path, address: &str) -> PgObjectGcWorker {
    fs::create_dir_all(data_dir).expect("create isolated PostgreSQL GC worker data directory");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(data_dir, fs::Permissions::from_mode(0o700))
            .expect("restrict PostgreSQL GC worker data directory");
    }
    let child = Command::new(env!("CARGO_BIN_EXE_atermius-server"))
        .arg("serve")
        .env("ATERMIUS_DATA_DIR", data_dir)
        .env("ATERMIUS_BIND", address)
        .env_remove("ATERMIUS_DATABASE_URL")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("start real PostgreSQL object GC worker process");
    PgObjectGcWorker { child }
}

async fn install_real_object_fixture(
    pool: &PgPool,
    object_store_root: &Path,
    instance_id: &str,
    vault_id: &str,
    object_id: &str,
    bytes: &[u8],
) -> String {
    let upload_id: String = sqlx::query_scalar(
        "SELECT upload_id FROM uploads WHERE vault_id=$1 AND object_id=$2 AND state='completed'",
    )
    .bind(vault_id)
    .bind(object_id)
    .fetch_one(pool)
    .await
    .expect("read completed object upload id");
    let storage_key =
        format!("atermius/objects/v1/{instance_id}/{vault_id}/{object_id}/{upload_id}");
    let sha256 = hex::encode(Sha256::digest(bytes));
    let object_size = i64::try_from(bytes.len()).expect("fixture object size fits PostgreSQL");
    let updated_object = sqlx::query(
        "UPDATE blob_objects SET size=$1,sha256=$2,storage_key=$3 \
         WHERE vault_id=$4 AND object_id=$5 AND storage_state='available'",
    )
    .bind(object_size)
    .bind(&sha256)
    .bind(&storage_key)
    .bind(vault_id)
    .bind(object_id)
    .execute(pool)
    .await
    .expect("write provider-shaped object catalogue metadata");
    assert_eq!(updated_object.rows_affected(), 1);
    let updated_upload = sqlx::query(
        "UPDATE uploads SET expected_size=$1,expected_sha256=$2,storage_key=$3 \
         WHERE upload_id=$4 AND state='completed'",
    )
    .bind(object_size)
    .bind(&sha256)
    .bind(&storage_key)
    .bind(&upload_id)
    .execute(pool)
    .await
    .expect("write completed upload retry-grant metadata");
    assert_eq!(updated_upload.rows_affected(), 1);

    let mut object_directory = object_store_root.to_path_buf();
    for component in storage_key.split('/').take(6) {
        object_directory.push(component);
        fs::create_dir_all(&object_directory).expect("create private object fixture directory");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&object_directory, fs::Permissions::from_mode(0o700))
                .expect("restrict private object fixture directory");
        }
    }
    let object_path = object_store_root.join(&storage_key);
    fs::write(&object_path, bytes).expect("write immutable filesystem object fixture");
    storage_key
}

fn acceptance_filesystem_store_id() -> String {
    let root = std::env::var_os("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT")
        .map(PathBuf::from)
        .expect("acceptance runner configures a private filesystem object store");
    fs::create_dir_all(&root).expect("create acceptance object-store root");
    let marker = root.join(".atermius-store-id");
    if !marker.exists() {
        let id = Uuid::new_v4().to_string();
        #[cfg(unix)]
        {
            use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt};
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&marker)
                .expect("create private object-store identity marker");
            file.write_all(id.as_bytes())
                .expect("write object-store identity");
            file.write_all(b"\n")
                .expect("terminate object-store identity");
            file.sync_all().expect("sync object-store identity");
        }
        #[cfg(not(unix))]
        panic!("PostgreSQL filesystem object-store acceptance requires Unix");
    }
    let id = fs::read_to_string(&marker)
        .expect("read acceptance object-store identity")
        .trim()
        .to_owned();
    Uuid::parse_str(&id).expect("acceptance store identity is a UUID");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = fs::metadata(&marker)
            .expect("stat object-store identity marker")
            .permissions();
        permissions.set_mode(0o600);
        fs::set_permissions(&marker, permissions).expect("secure object-store identity marker");
    }
    id
}

fn signed_redaction_capability_report(
    key: &SigningKey,
    account_id: &str,
    device_id: &str,
    revision: i64,
) -> String {
    let payload = json!({
        "format":"atermius-sync-redaction-capability-v1",
        "account_id":account_id,
        "device_id":device_id,
        "revision":revision,
        "sync_redaction_version":1,
    });
    sign_json(key, &payload)
}

fn verify_record_redaction_proof(proof: &Value) {
    let public_key = URL_SAFE_NO_PAD
        .decode(
            proof["signing_public_key"]
                .as_str()
                .expect("proof public key"),
        )
        .expect("decode proof public key");
    let public_key: [u8; 32] = public_key.try_into().expect("Ed25519 public key length");
    let verifying_key = VerifyingKey::from_bytes(&public_key).expect("valid proof public key");
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(proof["signature"].as_str().expect("proof signature"))
        .expect("decode proof signature");
    let signature_bytes: [u8; 64] = signature_bytes
        .try_into()
        .expect("Ed25519 signature length");
    let signature = Signature::from_bytes(&signature_bytes);
    let mut unsigned = proof.clone();
    unsigned
        .as_object_mut()
        .expect("proof object")
        .remove("signature");
    verifying_key
        .verify(
            &serde_jcs::to_vec(&unsigned).expect("canonicalize redaction proof"),
            &signature,
        )
        .expect("verify current-key redaction proof");
}

async fn post_record_purge(
    client: &reqwest::Client,
    base_url: &str,
    access_token: &str,
    vault_id: &str,
    record_id: &str,
    deleted_revision_id: &str,
    deleted_seq: &str,
    marker: bool,
) -> (u16, Value) {
    let mut request = client
        .post(format!(
            "{base_url}/api/v1/vaults/{vault_id}/records/{record_id}/purge"
        ))
        .bearer_auth(access_token)
        .json(&json!({
            "expected_deleted_revision_id":deleted_revision_id,
            "expected_deleted_seq":deleted_seq,
        }));
    if marker {
        request = request.header("x-atermius-redaction-marker", "v1");
    }
    let response = request.send().await.expect("send owner purge HTTP request");
    let status = response.status().as_u16();
    let body = response.json().await.expect("decode purge HTTP response");
    (status, body)
}

async fn record_purge_state_digest(pool: &PgPool, vault_id: &str, record_id: &str) -> String {
    sqlx::query_scalar(
        "SELECT jsonb_build_object( \
           'counter', (SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1), \
           'conflict_counter', (SELECT last_conflict_seq FROM vault_counters WHERE vault_id=$1), \
           'redactions', COALESCE((SELECT jsonb_agg(jsonb_build_array(record_id,deleted_revision_id,deleted_seq,redaction_seq) ORDER BY record_id) FROM record_redactions WHERE vault_id=$1),'[]'::jsonb), \
           'redacted_revisions', COALESCE((SELECT jsonb_agg(jsonb_build_array(record_id,revision_id) ORDER BY record_id,revision_id) FROM record_redacted_revisions WHERE vault_id=$1),'[]'::jsonb), \
           'devices', COALESCE((SELECT jsonb_agg(jsonb_build_array(d.device_id,d.user_id,d.signing_public_key,d.status) ORDER BY d.user_id,d.device_id) FROM devices d JOIN vault_members vm ON vm.user_id=d.user_id WHERE vm.vault_id=$1),'[]'::jsonb), \
           'reports', COALESCE((SELECT jsonb_agg(jsonb_build_array(r.device_id,r.account_id,r.revision,r.sync_redaction_version,r.signature,r.invalidated_at) ORDER BY r.account_id,r.device_id) FROM device_redaction_capability_reports r JOIN devices d ON d.device_id=r.device_id JOIN vault_members vm ON vm.user_id=d.user_id WHERE vm.vault_id=$1),'[]'::jsonb), \
           'versions', COALESCE((SELECT jsonb_agg(jsonb_build_array(record_id,revision_id,base_revision_id,envelope,digest,commit_seq,device_id,operation,created_at) ORDER BY record_id,commit_seq) FROM record_versions WHERE vault_id=$1),'[]'::jsonb), \
           'changes', COALESCE((SELECT jsonb_agg(jsonb_build_array(commit_seq,event_type,record_id,revision_id,envelope) ORDER BY commit_seq) FROM change_events WHERE vault_id=$1),'[]'::jsonb), \
           'conflicts', COALESCE((SELECT jsonb_agg(jsonb_build_array(conflict_id,record_id,base_revision_id,envelope,digest,device_id,conflict_seq,resolved_revision_id,resolution_seq,resolution_at) ORDER BY conflict_seq) FROM conflicts WHERE vault_id=$1),'[]'::jsonb), \
           'heads', COALESCE((SELECT jsonb_agg(jsonb_build_array(record_id,revision_id,deleted,commit_seq) ORDER BY record_id) FROM record_heads WHERE vault_id=$1),'[]'::jsonb), \
           'graveyard', COALESCE((SELECT jsonb_agg(jsonb_build_array(record_id,deleted_revision,deleted_seq) ORDER BY record_id) FROM record_graveyard WHERE vault_id=$1),'[]'::jsonb), \
           'snapshots', COALESCE((SELECT jsonb_agg(jsonb_build_array(snapshot_id,manifest_json,snapshot_item_count,snapshot_manifest_format,redacted_at) ORDER BY snapshot_id) FROM snapshots WHERE vault_id=$1),'[]'::jsonb), \
           'snapshot_items', COALESCE((SELECT jsonb_agg(jsonb_build_array(i.snapshot_id,i.record_id,i.item_json) ORDER BY i.snapshot_id,i.record_id) FROM snapshot_items i JOIN snapshots s ON s.snapshot_id=i.snapshot_id WHERE s.vault_id=$1),'[]'::jsonb), \
           'object_references', COALESCE((SELECT jsonb_agg(jsonb_build_array(revision_id,object_id) ORDER BY revision_id,object_id) FROM object_references WHERE vault_id=$1),'[]'::jsonb), \
           'blobs', COALESCE((SELECT jsonb_agg(jsonb_build_array(object_id,storage_state,gc_after) ORDER BY object_id) FROM blob_objects WHERE vault_id=$1),'[]'::jsonb), \
           'uploads', COALESCE((SELECT jsonb_agg(jsonb_build_array(upload_id,object_id,state,expires_at) ORDER BY upload_id) FROM uploads WHERE vault_id=$1),'[]'::jsonb), \
           'receipts', COALESCE((SELECT jsonb_agg(jsonb_build_array(op_id,record_id,revision_id,commit_seq) ORDER BY op_id) FROM op_receipts WHERE vault_id=$1),'[]'::jsonb), \
           'audits', COALESCE((SELECT jsonb_agg(jsonb_build_array(action,resource_id,result) ORDER BY event_id) FROM audit_events WHERE scope_type='vault' AND scope_id=$1),'[]'::jsonb), \
           'target', $2)::text",
    )
    .bind(vault_id)
    .bind(record_id)
    .fetch_one(pool)
    .await
    .expect("read exact PostgreSQL purge state digest")
}

#[tokio::test]
#[ignore = "real PostgreSQL HTTP acceptance; use scripts/test-pg-device-enrollment-http.sh"]
async fn http_route_rejects_incomplete_epoch_set_then_commits_exact_enrollment() {
    let mut database = TestDatabase::create().await;
    let account_id = Uuid::new_v4().to_string();
    let approver_device_id = Uuid::new_v4().to_string();
    let target_device_id = Uuid::new_v4().to_string();
    let vault_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    let access_token = "pg-http-device-enrollment-access-token-0123456789";
    let approver_key = SigningKey::from_bytes(&[7; 32]);
    let approver_signing_key = URL_SAFE_NO_PAD.encode(approver_key.verifying_key().as_bytes());
    let approver_encryption_key = URL_SAFE_NO_PAD.encode([17; 32]);

    sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
        .bind(&account_id)
        .bind(format!("{account_id}@example.test"))
        .execute(&database.pool)
        .await
        .expect("insert active test account");
    sqlx::query(
        "INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,status) \
         VALUES($1,$2,'approver',$3,$4,'active')",
    )
    .bind(&approver_device_id)
    .bind(&account_id)
    .bind(&approver_signing_key)
    .bind(&approver_encryption_key)
    .execute(&database.pool)
    .await
    .expect("insert active approving device");
    sqlx::query(
        "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash, \
         access_expires_at,refresh_expires_at) \
         VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '30 days')",
    )
    .bind(&session_id)
    .bind(&account_id)
    .bind(&approver_device_id)
    .bind(access_hash(access_token))
    .bind(Uuid::new_v4().to_string())
    .execute(&database.pool)
    .await
    .expect("insert active bearer session");
    sqlx::query(
        "INSERT INTO vaults(vault_id,owner_user_id,state,active_epoch,membership_version) \
         VALUES($1,$2,'active',2,1)",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .execute(&database.pool)
    .await
    .expect("insert active Vault at epoch two");
    sqlx::query(
        "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .execute(&database.pool)
    .await
    .expect("insert active Vault membership");
    sqlx::query(
        "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id, \
         envelope,envelope_signature,signer_device_id,membership_version) \
         VALUES($1,2,$2,$3,'{}'::jsonb,'fixture-source-signature',$3,1)",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .bind(&approver_device_id)
    .execute(&database.pool)
    .await
    .expect("insert current source envelope while deliberately omitting epoch one");

    let data_dir = std::env::var_os("ATERMIUS_DATA_DIR")
        .map(PathBuf::from)
        .expect("acceptance runner provides a private server data directory");
    let sqlite_url = format!("sqlite://{}/http.db?mode=rwc", data_dir.display());
    let state = atermius_server::open_state(&sqlite_url, atermius_server::Config::from_env())
        .await
        .expect("open the real PostgreSQL-backed runtime");
    let app = atermius_server::router(state.clone()).await;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind local ephemeral HTTP port");
    let address = listener.local_addr().expect("read local HTTP address");
    let server = tokio::spawn(async move {
        axum::serve(listener, app)
            .await
            .expect("serve the complete Axum router");
    });
    let client = reqwest::Client::new();
    let base_url = format!("http://{address}");

    let incomplete = signed_enrollment(
        &account_id,
        &approver_device_id,
        &vault_id,
        &approver_key,
        &target_device_id,
        &[2],
    );
    let (status, body) = post_enrollment(&client, &base_url, access_token, incomplete).await;
    assert_eq!(status, 422, "{body}");
    assert_eq!(body["error"]["code"], "INVALID_ENVELOPE");

    let rejected_device_rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM devices WHERE device_id=$1 AND user_id=$2")
            .bind(&target_device_id)
            .bind(&account_id)
            .fetch_one(&database.pool)
            .await
            .expect("check rejected target device");
    let rejected_capability_rows: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM device_capability_reports WHERE device_id=$1")
            .bind(&target_device_id)
            .fetch_one(&database.pool)
            .await
            .expect("check rejected capability report");
    let rejected_envelopes: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_device_id=$1")
            .bind(&target_device_id)
            .fetch_one(&database.pool)
            .await
            .expect("check rejected key envelopes");
    let rejected_audits: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM audit_events WHERE actor_user_id=$1 AND resource_id=$2",
    )
    .bind(&account_id)
    .bind(&target_device_id)
    .fetch_one(&database.pool)
    .await
    .expect("check rejected registration audit");
    let source_envelopes_after_reject: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM vault_key_envelopes WHERE recipient_device_id=$1")
            .bind(&approver_device_id)
            .fetch_one(&database.pool)
            .await
            .expect("check unchanged source key set");
    let all_audits_after_reject: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM audit_events")
        .fetch_one(&database.pool)
        .await
        .expect("check no audit mutation on rejection");
    assert_eq!(rejected_device_rows, 0, "rejection inserted no device");
    assert_eq!(rejected_capability_rows, 0, "rejection inserted no report");
    assert_eq!(rejected_envelopes, 0, "rejection inserted no envelopes");
    assert_eq!(
        rejected_audits, 0,
        "rejection inserted no registration audit"
    );
    assert_eq!(
        source_envelopes_after_reject, 1,
        "rejection preserved source rows"
    );
    assert_eq!(
        all_audits_after_reject, 0,
        "rejection leaves audit table unchanged"
    );

    sqlx::query(
        "INSERT INTO vault_key_envelopes(vault_id,epoch,recipient_user_id,recipient_device_id, \
         envelope,envelope_signature,signer_device_id,membership_version) \
         VALUES($1,1,$2,$3,'{}'::jsonb,'fixture-source-signature',$3,1)",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .bind(&approver_device_id)
    .execute(&database.pool)
    .await
    .expect("complete source device historical epoch set");
    let complete = signed_enrollment(
        &account_id,
        &approver_device_id,
        &vault_id,
        &approver_key,
        &target_device_id,
        &[1, 2],
    );
    let expected_device = complete["device"].clone();
    let expected_envelopes = complete["vault_key_envelopes"].as_array().unwrap().clone();
    let (status, body) = post_enrollment(&client, &base_url, access_token, complete).await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["device_id"], target_device_id);
    assert_eq!(body["status"], "active");
    assert_eq!(body["vault_key_envelope_count"], 2);

    let device = sqlx::query(
        "SELECT device_id,user_id,name,signing_public_key,encryption_public_key,status \
         FROM devices WHERE device_id=$1",
    )
    .bind(&target_device_id)
    .fetch_one(&database.pool)
    .await
    .expect("read inserted device");
    assert_eq!(
        device.try_get::<String, _>("device_id").unwrap(),
        target_device_id
    );
    assert_eq!(device.try_get::<String, _>("user_id").unwrap(), account_id);
    assert_eq!(
        device.try_get::<String, _>("name").unwrap(),
        expected_device["name"]
    );
    assert_eq!(
        device.try_get::<String, _>("signing_public_key").unwrap(),
        expected_device["signing_public_key"]
    );
    assert_eq!(
        device
            .try_get::<String, _>("encryption_public_key")
            .unwrap(),
        expected_device["encryption_public_key"]
    );
    assert_eq!(device.try_get::<String, _>("status").unwrap(), "active");

    let rows = sqlx::query(
        "SELECT epoch,membership_version,envelope,envelope_signature,signer_device_id \
         FROM vault_key_envelopes WHERE recipient_device_id=$1 AND recipient_user_id=$2 \
         ORDER BY epoch",
    )
    .bind(&target_device_id)
    .bind(&account_id)
    .fetch_all(&database.pool)
    .await
    .expect("read inserted Vault envelopes");
    assert_eq!(rows.len(), expected_envelopes.len());
    for (row, expected) in rows.iter().zip(expected_envelopes.iter()) {
        assert_eq!(
            row.try_get::<i64, _>("epoch").unwrap(),
            expected["key_epoch"]
        );
        assert_eq!(
            row.try_get::<i64, _>("membership_version").unwrap(),
            expected["membership_version"]
        );
        assert_eq!(
            row.try_get::<Value, _>("envelope").unwrap(),
            expected["envelope"]
        );
        assert_eq!(
            row.try_get::<String, _>("envelope_signature").unwrap(),
            expected["signature"]
        );
        assert_eq!(
            row.try_get::<String, _>("signer_device_id").unwrap(),
            approver_device_id
        );
    }

    let audits = sqlx::query(
        "SELECT actor_user_id,actor_device_id,action,resource_type,resource_id,result,source \
         FROM audit_events WHERE actor_user_id=$1 AND resource_id=$2",
    )
    .bind(&account_id)
    .bind(&target_device_id)
    .fetch_all(&database.pool)
    .await
    .expect("read target registration audit");
    assert_eq!(
        audits.len(),
        1,
        "successful enrollment emits exactly one audit row"
    );
    assert_eq!(
        audits[0].try_get::<String, _>("actor_user_id").unwrap(),
        account_id
    );
    assert_eq!(
        audits[0].try_get::<String, _>("actor_device_id").unwrap(),
        approver_device_id
    );
    assert_eq!(
        audits[0].try_get::<String, _>("action").unwrap(),
        "device.registered"
    );
    assert_eq!(
        audits[0].try_get::<String, _>("resource_type").unwrap(),
        "device"
    );
    assert_eq!(
        audits[0].try_get::<String, _>("resource_id").unwrap(),
        target_device_id
    );
    assert_eq!(audits[0].try_get::<String, _>("result").unwrap(), "success");
    assert_eq!(audits[0].try_get::<String, _>("source").unwrap(), "api");

    server.abort();
    let _ = server.await;
    drop(state);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "two-node PostgreSQL redaction HTTP acceptance; use scripts/test-pg-device-enrollment-http.sh"]
async fn redaction_changes_and_legacy_gate_are_consistent_across_two_http_nodes() {
    let mut database = TestDatabase::create().await;
    let account_id = Uuid::new_v4().to_string();
    let device_id = Uuid::new_v4().to_string();
    let vault_id = Uuid::new_v4().to_string();
    let record_id = Uuid::new_v4().to_string();
    let deleted_revision_id = Uuid::new_v4().to_string();
    let redaction_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    let access_token = format!("pg-redaction-access-{}", Uuid::new_v4());
    sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
        .bind(&account_id)
        .bind(format!("{account_id}@example.test"))
        .execute(&database.pool)
        .await
        .expect("insert sync acceptance user");
    sqlx::query("INSERT INTO devices(device_id,user_id,status) VALUES($1,$2,'active')")
        .bind(&device_id)
        .bind(&account_id)
        .execute(&database.pool)
        .await
        .expect("insert sync acceptance device");
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at) VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')")
        .bind(&session_id)
        .bind(&account_id)
        .bind(&device_id)
        .bind(access_hash(&access_token))
        .bind(Uuid::new_v4().to_string())
        .execute(&database.pool)
        .await
        .expect("insert sync acceptance session");
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state) VALUES($1,$2,'active')")
        .bind(&vault_id)
        .bind(&account_id)
        .execute(&database.pool)
        .await
        .expect("insert sync acceptance Vault");
    sqlx::query(
        "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .execute(&database.pool)
    .await
    .expect("insert sync acceptance membership");
    sqlx::query("INSERT INTO vault_counters(vault_id,last_committed_seq,minimum_available_seq,last_conflict_seq) VALUES($1,2,1,0)")
        .bind(&vault_id)
        .execute(&database.pool)
        .await
        .expect("insert sync acceptance counters");
    sqlx::query("INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) VALUES($1,$2,$3,1)")
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(&database.pool)
        .await
        .expect("insert exact graveyard tombstone");
    for (seq, event_type) in [(1_i64, "delete"), (2_i64, "record_redacted")] {
        sqlx::query("INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) VALUES($1,$2,$3,$4,$5,$6,CURRENT_TIMESTAMP)")
            .bind(&vault_id)
            .bind(seq)
            .bind(event_type)
            .bind(&record_id)
            .bind(&deleted_revision_id)
            .bind(if seq == 1 { Some("{\"ciphertext\":\"private\"}") } else { None })
            .execute(&database.pool)
            .await
            .expect("insert sequence-preserving change event");
    }
    sqlx::query("INSERT INTO record_redactions(redaction_id,vault_id,record_id,deleted_revision_id,deleted_seq,redaction_seq) VALUES($1,$2,$3,$4,1,2)")
        .bind(&redaction_id)
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(&database.pool)
        .await
        .expect("insert redaction proof ledger row");

    let active_report_account = Uuid::new_v4().to_string();
    let invalidated_report_account = Uuid::new_v4().to_string();
    let inactive_report_account = Uuid::new_v4().to_string();
    let active_report_device = Uuid::new_v4().to_string();
    let invalidated_report_device = Uuid::new_v4().to_string();
    let inactive_report_device = Uuid::new_v4().to_string();
    let no_report_device = Uuid::new_v4().to_string();
    let archived_device = Uuid::new_v4().to_string();
    for (account_id, device_id) in [
        (&active_report_account, &active_report_device),
        (&invalidated_report_account, &invalidated_report_device),
        (&inactive_report_account, &inactive_report_device),
    ] {
        sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
            .bind(account_id)
            .bind(format!("{account_id}@example.test"))
            .execute(&database.pool)
            .await
            .expect("insert Vault roster projection user");
        sqlx::query("INSERT INTO devices(device_id,user_id,status) VALUES($1,$2,'active')")
            .bind(device_id)
            .bind(account_id)
            .execute(&database.pool)
            .await
            .expect("insert Vault roster projection device");
    }
    sqlx::query("INSERT INTO devices(device_id,user_id,status) VALUES($1,$2,'active')")
        .bind(&no_report_device)
        .bind(&account_id)
        .execute(&database.pool)
        .await
        .expect("insert device without redaction report");
    for (member_account, role, member_state) in [
        (&active_report_account, "editor", "active"),
        (&invalidated_report_account, "editor", "active"),
        (&inactive_report_account, "editor", "revoked"),
    ] {
        sqlx::query("INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,$3,$4)")
            .bind(&vault_id)
            .bind(member_account)
            .bind(role)
            .bind(member_state)
            .execute(&database.pool)
            .await
            .expect("insert Vault roster projection membership");
    }
    sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,account_id,revision,sync_redaction_version,signature) VALUES($1,$2,3,1,'active-signature')")
        .bind(&active_report_device)
        .bind(&active_report_account)
        .execute(&database.pool)
        .await
        .expect("insert active redaction capability report");
    sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,account_id,revision,sync_redaction_version,signature,invalidated_at) VALUES($1,$2,7,1,'invalidated-signature',TIMESTAMPTZ '2025-01-02 03:04:05+00')")
        .bind(&invalidated_report_device)
        .bind(&invalidated_report_account)
        .execute(&database.pool)
        .await
        .expect("insert invalidated redaction capability report");
    sqlx::query("INSERT INTO device_redaction_capability_reports(device_id,account_id,revision,sync_redaction_version,signature) VALUES($1,$2,9,1,'inactive-signature')")
        .bind(&inactive_report_device)
        .bind(&inactive_report_account)
        .execute(&database.pool)
        .await
        .expect("insert inactive-member redaction capability report");
    sqlx::query("INSERT INTO vault_device_archives(vault_id,user_id,device_id,signing_public_key,encryption_public_key) VALUES($1,$2,$3,'archive-sign','archive-box')")
        .bind(&vault_id)
        .bind(Uuid::new_v4().to_string())
        .bind(&archived_device)
        .execute(&database.pool)
        .await
        .expect("insert archived Vault device");

    let data_root = std::env::var_os("ATERMIUS_DATA_DIR")
        .map(PathBuf::from)
        .expect("acceptance runner provides a private server data directory");
    let mut servers = Vec::new();
    let mut states = Vec::new();
    let mut addresses = Vec::new();
    for node in ["redaction-node-a", "redaction-node-b"] {
        let node_dir = data_root.join(node);
        fs::create_dir_all(&node_dir).expect("create isolated SQLite state directory");
        let sqlite_url = format!("sqlite://{}/http.db?mode=rwc", node_dir.display());
        let state = atermius_server::open_state(&sqlite_url, atermius_server::Config::from_env())
            .await
            .expect("open node against the shared PostgreSQL runtime");
        let app = atermius_server::router(state.clone()).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind local node HTTP port");
        addresses.push(format!(
            "http://{}",
            listener.local_addr().expect("read node HTTP address")
        ));
        servers.push(tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve PostgreSQL redaction acceptance node");
        }));
        states.push(state);
    }

    let client = reqwest::Client::new();
    let devices_uri = format!("/api/v1/vaults/{vault_id}/devices");
    for base in &addresses {
        let response = client
            .get(format!("{base}{devices_uri}"))
            .bearer_auth(&access_token)
            .send()
            .await
            .expect("fetch Vault-scoped device reports from PostgreSQL node");
        let status = response.status().as_u16();
        let body: Value = response.json().await.expect("decode Vault device response");
        assert_eq!(status, 200, "{body}");
        let devices = body["devices"].as_array().expect("device DTOs");
        let report_for = |device_id: &str| {
            devices
                .iter()
                .find(|device| device["device_id"] == device_id)
                .unwrap_or_else(|| panic!("missing device DTO {device_id}"))
        };
        assert_eq!(
            report_for(&active_report_device)["redaction_capability_report"],
            json!({
                "format": "atermius-sync-redaction-capability-v1",
                "account_id": active_report_account,
                "device_id": active_report_device,
                "revision": 3,
                "sync_redaction_version": 1,
                "signature": "active-signature",
                "invalidated_at": null,
            })
        );
        let invalidated = &report_for(&invalidated_report_device)["redaction_capability_report"];
        assert_eq!(invalidated["revision"], 7);
        assert_eq!(invalidated["signature"], "invalidated-signature");
        assert!(
            chrono::DateTime::parse_from_rfc3339(
                invalidated["invalidated_at"]
                    .as_str()
                    .expect("invalidated timestamp")
            )
            .is_ok()
        );
        assert_eq!(
            report_for(&inactive_report_device)["redaction_capability_report"],
            Value::Null
        );
        assert_eq!(
            report_for(&no_report_device)["redaction_capability_report"],
            Value::Null
        );
        assert_eq!(
            report_for(&archived_device)["redaction_capability_report"],
            Value::Null
        );
    }
    let uri = format!("/api/v1/vaults/{vault_id}/changes");
    let mut node_proofs = Vec::new();
    for base in &addresses {
        let response = client
            .get(format!("{base}{uri}"))
            .bearer_auth(&access_token)
            .header("x-atermius-redaction-marker", "v1")
            .send()
            .await
            .expect("fetch redacted changes from PostgreSQL node");
        let status = response.status().as_u16();
        let body: Value = response.json().await.expect("decode changes response");
        assert_eq!(status, 200, "{body}");
        let events = body["events"].as_array().unwrap();
        assert_eq!(events.len(), 2);
        for event in events {
            assert_eq!(event["event_type"], "record_redacted");
            assert_eq!(event["record_id"], record_id);
            assert_eq!(event.as_object().unwrap().len(), 4);
            assert!(event.get("envelope").is_none());
            assert!(event.get("revision_id").is_none());
            assert_eq!(event["redaction"]["redaction_id"], redaction_id);
        }
        node_proofs.push(events[0]["redaction"].clone());
    }
    assert_eq!(node_proofs[0], node_proofs[1]);

    let legacy = client
        .get(format!("{}{uri}", addresses[1]))
        .bearer_auth(&access_token)
        .send()
        .await
        .expect("request redacted changes as an old client");
    assert_eq!(legacy.status().as_u16(), 426);
    let legacy_body: Value = legacy.json().await.expect("decode compatibility error");
    assert_eq!(
        legacy_body["error"]["code"],
        "CLIENT_REDACTION_CAPABILITY_REQUIRED"
    );

    for server in servers {
        server.abort();
        let _ = server.await;
    }
    drop(states);
    database.cleanup().await;
}

#[tokio::test]
#[ignore = "two-node PostgreSQL purge HTTP acceptance; use scripts/test-pg-device-enrollment-http.sh"]
async fn record_purge_is_owner_gated_atomic_and_shared_across_two_http_nodes() {
    let mut database = TestDatabase::create().await;
    let object_store_id = acceptance_filesystem_store_id();
    let account_id = Uuid::new_v4().to_string();
    let non_owner_account_id = Uuid::new_v4().to_string();
    let non_owner_device_id = Uuid::new_v4().to_string();
    let owner_device_id = Uuid::new_v4().to_string();
    let second_device_id = Uuid::new_v4().to_string();
    let vault_id = Uuid::new_v4().to_string();
    let record_id = Uuid::new_v4().to_string();
    let created_revision_id = Uuid::new_v4().to_string();
    let deleted_revision_id = Uuid::new_v4().to_string();
    let live_record_id = Uuid::new_v4().to_string();
    let live_revision_id = Uuid::new_v4().to_string();
    let conflict_id = Uuid::new_v4().to_string();
    let conflict_revision_id = Uuid::new_v4().to_string();
    let collectible_object_id = Uuid::new_v4().to_string();
    let shared_object_id = Uuid::new_v4().to_string();
    let old_snapshot_id = Uuid::new_v4().to_string();
    let retry_race_record_id = Uuid::new_v4().to_string();
    let retry_race_create_revision_id = Uuid::new_v4().to_string();
    let retry_race_delete_revision_id = Uuid::new_v4().to_string();
    let retry_race_snapshot_id = Uuid::new_v4().to_string();
    let session_id = Uuid::new_v4().to_string();
    let non_owner_session_id = Uuid::new_v4().to_string();
    let access_token = format!("pg-record-purge-access-{}", Uuid::new_v4());
    let non_owner_access_token = format!("pg-record-purge-non-owner-{}", Uuid::new_v4());
    let owner_key = SigningKey::from_bytes(&[41; 32]);
    let second_key = SigningKey::from_bytes(&[42; 32]);
    let rotated_second_key = SigningKey::from_bytes(&[43; 32]);
    let non_owner_key = SigningKey::from_bytes(&[44; 32]);
    let now = chrono::Utc::now();
    let created_at = now - chrono::Duration::days(45);
    let deleted_at = now - chrono::Duration::days(31);

    sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
        .bind(&account_id)
        .bind(format!("{account_id}@example.test"))
        .execute(&database.pool)
        .await
        .expect("insert active purge owner");
    sqlx::query("INSERT INTO users(user_id,username,status) VALUES($1,$2,'active')")
        .bind(&non_owner_account_id)
        .bind(format!("{non_owner_account_id}@example.test"))
        .execute(&database.pool)
        .await
        .expect("insert active non-owner Vault member");
    sqlx::query(
        "INSERT INTO devices(device_id,user_id,name,signing_public_key,status) \
         VALUES($1,$2,'non-owner purge device',$3,'active')",
    )
    .bind(&non_owner_device_id)
    .bind(&non_owner_account_id)
    .bind(URL_SAFE_NO_PAD.encode(non_owner_key.verifying_key().as_bytes()))
    .execute(&database.pool)
    .await
    .expect("insert non-owner active device");
    for (device_id, key) in [
        (&owner_device_id, &owner_key),
        (&second_device_id, &second_key),
    ] {
        sqlx::query(
            "INSERT INTO devices(device_id,user_id,name,signing_public_key,status) \
             VALUES($1,$2,'purge acceptance device',$3,'active')",
        )
        .bind(device_id)
        .bind(&account_id)
        .bind(URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes()))
        .execute(&database.pool)
        .await
        .expect("insert active Vault device");
    }
    sqlx::query(
        "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash, \
         access_expires_at,refresh_expires_at) \
         VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')",
    )
    .bind(&session_id)
    .bind(&account_id)
    .bind(&owner_device_id)
    .bind(access_hash(&access_token))
    .bind(Uuid::new_v4().to_string())
    .execute(&database.pool)
    .await
    .expect("insert owner bearer session");
    sqlx::query(
        "INSERT INTO sessions(session_id,user_id,device_id,access_hash,refresh_hash, \
         access_expires_at,refresh_expires_at) \
         VALUES($1,$2,$3,$4,$5,CURRENT_TIMESTAMP+INTERVAL '1 hour',CURRENT_TIMESTAMP+INTERVAL '1 day')",
    )
    .bind(&non_owner_session_id)
    .bind(&non_owner_account_id)
    .bind(&non_owner_device_id)
    .bind(access_hash(&non_owner_access_token))
    .bind(Uuid::new_v4().to_string())
    .execute(&database.pool)
    .await
    .expect("insert non-owner bearer session");
    sqlx::query("INSERT INTO vaults(vault_id,owner_user_id,state) VALUES($1,$2,'active')")
        .bind(&vault_id)
        .bind(&account_id)
        .execute(&database.pool)
        .await
        .expect("insert purge acceptance Vault");
    sqlx::query(
        "INSERT INTO vault_members(vault_id,user_id,role,state) VALUES($1,$2,'owner','active')",
    )
    .bind(&vault_id)
    .bind(&account_id)
    .execute(&database.pool)
    .await
    .expect("insert active owner membership");
    sqlx::query(
        "INSERT INTO vault_members(vault_id,user_id,role,state) \
         VALUES($1,$2,'editor','active')",
    )
    .bind(&vault_id)
    .bind(&non_owner_account_id)
    .execute(&database.pool)
    .await
    .expect("insert active non-owner membership");
    sqlx::query(
        "INSERT INTO vault_counters(vault_id,last_committed_seq,minimum_available_seq,last_conflict_seq) \
         VALUES($1,3,1,2)",
    )
    .bind(&vault_id)
    .execute(&database.pool)
    .await
    .expect("insert purge acceptance sync counters");

    let created_envelope = json!({
        "header":{"revision_id":created_revision_id,"record_schema":1},
        "nonce":"nonce-create","ciphertext":"created-secret","signature":"sig-create"
    });
    let deleted_envelope = json!({
        "header":{"revision_id":deleted_revision_id,"record_schema":1},
        "nonce":"nonce-delete","ciphertext":"deleted-secret","signature":"sig-delete"
    });
    let live_envelope = json!({
        "header":{"revision_id":live_revision_id,"record_schema":1},
        "nonce":"nonce-live","ciphertext":"live-secret","signature":"sig-live"
    });
    for (record, revision, base, operation, seq, envelope, timestamp) in [
        (
            &record_id,
            &created_revision_id,
            None,
            "create",
            1_i64,
            &created_envelope,
            created_at,
        ),
        (
            &record_id,
            &deleted_revision_id,
            Some(created_revision_id.as_str()),
            "delete",
            2_i64,
            &deleted_envelope,
            deleted_at,
        ),
        (
            &live_record_id,
            &live_revision_id,
            None,
            "create",
            3_i64,
            &live_envelope,
            now,
        ),
    ] {
        sqlx::query(
            "INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope, \
             digest,commit_seq,device_id,operation,created_at) \
             VALUES($1,$2,$3,$4,$5,'fixture-digest',$6,$7,$8,$9)",
        )
        .bind(&vault_id)
        .bind(record)
        .bind(revision)
        .bind(base)
        .bind(envelope.to_string())
        .bind(seq)
        .bind(&owner_device_id)
        .bind(operation)
        .bind(timestamp)
        .execute(&database.pool)
        .await
        .expect("insert version history");
        if operation == "delete" {
            sqlx::query(
                "UPDATE record_versions SET restore_until=clock_timestamp()-INTERVAL '1 day' \
                 WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3",
            )
            .bind(&vault_id)
            .bind(record)
            .bind(revision)
            .execute(&database.pool)
            .await
            .expect("seed immutable delete deadline");
        }
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES($1,$2,$3,$4,$5,$6,$7)",
        )
        .bind(&vault_id)
        .bind(seq)
        .bind(operation)
        .bind(record)
        .bind(revision)
        .bind(envelope.to_string())
        .bind(timestamp)
        .execute(&database.pool)
        .await
        .expect("insert sequence-preserving change event");
    }
    sqlx::query(
        "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
         VALUES($1,$2,$3,TRUE,2),($1,$4,$5,FALSE,3)",
    )
    .bind(&vault_id)
    .bind(&record_id)
    .bind(&deleted_revision_id)
    .bind(&live_record_id)
    .bind(&live_revision_id)
    .execute(&database.pool)
    .await
    .expect("insert live and deleted record heads");
    sqlx::query(
        "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
         VALUES($1,$2,$3,2)",
    )
    .bind(&vault_id)
    .bind(&record_id)
    .bind(&deleted_revision_id)
    .execute(&database.pool)
    .await
    .expect("insert current tombstone reservation");

    let conflict_envelope = json!({
        "header":{"revision_id":conflict_revision_id,"op_id":Uuid::new_v4()},
        "nonce":"conflict-nonce","ciphertext":"conflict-secret","signature":"conflict-sig"
    });
    sqlx::query(
        "INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest, \
         device_id,created_at,conflict_seq,resolved_revision_id,resolution_seq,resolution_at,op_id) \
         VALUES($1,$2,$3,$4,$5,'conflict-digest',$6,$7,1,$8,2,$7,$9)",
    )
    .bind(&conflict_id)
    .bind(&vault_id)
    .bind(&record_id)
    .bind(&created_revision_id)
    .bind(conflict_envelope.to_string())
    .bind(&owner_device_id)
    .bind(now)
    .bind(&deleted_revision_id)
    .bind(Uuid::new_v4().to_string())
    .execute(&database.pool)
    .await
    .expect("insert a resolved conflict branch");

    sqlx::query(
        "INSERT INTO blob_objects(vault_id,object_id,size,sha256,storage_backend,storage_key, \
         storage_store_id,storage_state) \
         VALUES($1,$2,3,repeat('a',64),'filesystem',$4,$6,'available'), \
               ($1,$3,3,repeat('b',64),'filesystem',$5,$6,'available')",
    )
    .bind(&vault_id)
    .bind(&collectible_object_id)
    .bind(&shared_object_id)
    .bind(format!("purge/{collectible_object_id}"))
    .bind(format!("purge/{shared_object_id}"))
    .bind(&object_store_id)
    .execute(&database.pool)
    .await
    .expect("insert collectible and shared object catalog rows");
    for (revision, object_id) in [
        (&created_revision_id, &collectible_object_id),
        (&deleted_revision_id, &collectible_object_id),
        (&conflict_revision_id, &collectible_object_id),
        (&deleted_revision_id, &shared_object_id),
        (&live_revision_id, &shared_object_id),
    ] {
        sqlx::query(
            "INSERT INTO object_references(vault_id,revision_id,object_id) VALUES($1,$2,$3)",
        )
        .bind(&vault_id)
        .bind(revision)
        .bind(object_id)
        .execute(&database.pool)
        .await
        .expect("insert object reference");
    }
    for object_id in [&collectible_object_id, &shared_object_id] {
        sqlx::query(
            "INSERT INTO uploads(upload_id,vault_id,user_id,object_id,expected_size,expected_sha256, \
             chunk_size,state,expires_at,storage_backend,storage_store_id,storage_key) \
             VALUES($1,$2,$3,$4,3,repeat('a',64),3,'completed',CURRENT_TIMESTAMP+INTERVAL '1 day', \
                    'filesystem',$6,$5)",
        )
        .bind(Uuid::new_v4().to_string())
        .bind(&vault_id)
        .bind(&account_id)
        .bind(object_id)
        .bind(format!("upload/{object_id}"))
        .bind(&object_store_id)
        .execute(&database.pool)
        .await
        .expect("insert completed-upload retry grant");
    }
    sqlx::query(
        "INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark, \
         manifest_json,expires_at,created_at,server_generation,snapshot_item_count,snapshot_manifest_format) \
         VALUES($1,$2,$3,3,2,$4,CURRENT_TIMESTAMP+INTERVAL '1 hour',$5,'pg-test-generation',2,'paged')",
    )
    .bind(&old_snapshot_id)
    .bind(&vault_id)
    .bind(&account_id)
    .bind(json!([
        {"kind":"head","record_id":record_id,"envelope":{"ciphertext":"snapshot-secret"}},
        {"kind":"head","record_id":live_record_id,"envelope":{"ciphertext":"live-snapshot-secret"}}
    ]).to_string())
    .bind(now)
    .execute(&database.pool)
    .await
    .expect("insert pre-purge materialized snapshot");
    for (record, item) in [
        (
            &record_id,
            json!({"kind":"head","record_id":record_id,"envelope":{"ciphertext":"snapshot-secret"}}),
        ),
        (
            &live_record_id,
            json!({"kind":"head","record_id":live_record_id,"envelope":{"ciphertext":"live-snapshot-secret"}}),
        ),
    ] {
        sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES($1,$2,$3)")
            .bind(&old_snapshot_id)
            .bind(record)
            .bind(item.to_string())
            .execute(&database.pool)
            .await
            .expect("insert snapshot page payload");
    }
    sqlx::query(
        "INSERT INTO op_receipts(vault_id,op_id,device_id,device_seq,request_digest,record_id,revision_id,commit_seq) \
         VALUES($1,$2,$3,'2','fixture-operation-digest',$4,$5,2)",
    )
    .bind(&vault_id)
    .bind(Uuid::new_v4().to_string())
    .bind(&owner_device_id)
    .bind(&record_id)
    .bind(&deleted_revision_id)
    .execute(&database.pool)
    .await
    .expect("insert operation idempotency receipt");
    sqlx::query(
        "INSERT INTO batch_receipts(vault_id,device_id,batch_id,request_digest,response_json) \
         VALUES($1,$2,$3,'fixture-batch-digest','{}')",
    )
    .bind(&vault_id)
    .bind(&owner_device_id)
    .bind(Uuid::new_v4().to_string())
    .execute(&database.pool)
    .await
    .expect("insert batch idempotency receipt");

    let data_root = std::env::var_os("ATERMIUS_DATA_DIR")
        .map(PathBuf::from)
        .expect("acceptance runner provides a private server data directory");
    let mut servers = Vec::new();
    let mut states = Vec::new();
    let mut addresses = Vec::new();
    for node in ["purge-node-a", "purge-node-b"] {
        let node_dir = data_root.join(node);
        fs::create_dir_all(&node_dir).expect("create isolated node-local state directory");
        let sqlite_url = format!("sqlite://{}/http.db?mode=rwc", node_dir.display());
        let mut config = atermius_server::Config::from_env();
        // Deliberately differ from the policy used to seed the tombstone.
        // Both nodes must honor the persisted absolute deadline.
        config.record_restore_retention_days = 1;
        let state = atermius_server::open_state(&sqlite_url, config)
            .await
            .expect("open node against shared PostgreSQL sync state");
        let app = atermius_server::router(state.clone()).await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind local purge acceptance port");
        addresses.push(format!(
            "http://{}",
            listener.local_addr().expect("read purge HTTP address")
        ));
        servers.push(tokio::spawn(async move {
            axum::serve(listener, app)
                .await
                .expect("serve PostgreSQL purge acceptance node");
        }));
        states.push(state);
    }
    let object_store_root = std::env::var_os("ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT")
        .map(PathBuf::from)
        .expect("acceptance runner configures a private filesystem object store");
    let collectible_object_bytes = b"purge-created collectible object bytes";
    let shared_object_bytes = b"shared live-revision object bytes";
    let collectible_storage_key = install_real_object_fixture(
        &database.pool,
        &object_store_root,
        &states[0].instance.instance_id,
        &vault_id,
        &collectible_object_id,
        collectible_object_bytes,
    )
    .await;
    let shared_storage_key = install_real_object_fixture(
        &database.pool,
        &object_store_root,
        &states[0].instance.instance_id,
        &vault_id,
        &shared_object_id,
        shared_object_bytes,
    )
    .await;
    let client = reqwest::Client::new();

    // The marker is a required request precondition. An active device with
    // no independent signed report also blocks purge without changing state.
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        false,
    )
    .await;
    assert_eq!(status, 400, "{body}");
    assert_eq!(body["error"]["code"], "INVALID_REDACTION_MARKER");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "a missing marker must not mutate server state"
    );
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "VAULT_REDACTION_CAPABILITY_REQUIRED");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "missing capability reports must not mutate server state"
    );

    for (device_id, key, revision) in [
        (&owner_device_id, &owner_key, 1_i64),
        (&second_device_id, &second_key, 1_i64),
    ] {
        sqlx::query(
            "INSERT INTO device_redaction_capability_reports( \
                 device_id,account_id,revision,sync_redaction_version,signature,updated_at \
             ) VALUES($1,$2,$3,1,$4,CURRENT_TIMESTAMP)",
        )
        .bind(device_id)
        .bind(&account_id)
        .bind(revision)
        .bind(signed_redaction_capability_report(
            key,
            &account_id,
            device_id,
            revision,
        ))
        .execute(&database.pool)
        .await
        .expect("insert valid signed redaction capability report");
    }
    sqlx::query(
        "INSERT INTO device_redaction_capability_reports( \
             device_id,account_id,revision,sync_redaction_version,signature,updated_at \
         ) VALUES($1,$2,1,1,$3,CURRENT_TIMESTAMP)",
    )
    .bind(&non_owner_device_id)
    .bind(&non_owner_account_id)
    .bind(signed_redaction_capability_report(
        &non_owner_key,
        &non_owner_account_id,
        &non_owner_device_id,
        1,
    ))
    .execute(&database.pool)
    .await
    .expect("insert non-owner device redaction capability report");
    // Reports are revalidated against the current device key while the purge
    // transaction holds lifecycle locks, not trusted by their stored bit.
    sqlx::query("UPDATE devices SET signing_public_key=$1 WHERE device_id=$2")
        .bind(URL_SAFE_NO_PAD.encode(rotated_second_key.verifying_key().as_bytes()))
        .bind(&second_device_id)
        .execute(&database.pool)
        .await
        .expect("rotate second device key after its capability report");
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[1],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "VAULT_REDACTION_CAPABILITY_REQUIRED");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "a stale report signature must not mutate server state"
    );
    sqlx::query(
        "UPDATE device_redaction_capability_reports SET revision=2,signature=$1, \
             invalidated_at=NULL,updated_at=CURRENT_TIMESTAMP WHERE device_id=$2 AND account_id=$3",
    )
    .bind(signed_redaction_capability_report(
        &rotated_second_key,
        &account_id,
        &second_device_id,
        2,
    ))
    .bind(&second_device_id)
    .bind(&account_id)
    .execute(&database.pool)
    .await
    .expect("publish a report valid for the current device key");

    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[1],
        &non_owner_access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 403, "{body}");
    assert_eq!(body["error"]["code"], "VAULT_OWNER_REQUIRED");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "a non-owner purge request must not mutate server state"
    );

    let wrong_revision_id = Uuid::new_v4().to_string();
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &wrong_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "RECORD_DELETE_CHANGED");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "a mismatched tombstone must not mutate server state"
    );

    sqlx::query("UPDATE record_versions SET restore_until=clock_timestamp()+INTERVAL '30 days' WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3")
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(&database.pool)
        .await
        .expect("make tombstone too recent for restore fence rejection");
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[1],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "RECORD_PURGE_NOT_DUE");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "a tombstone inside its restore period must not mutate server state"
    );
    sqlx::query("UPDATE record_versions SET restore_until=clock_timestamp()-INTERVAL '1 second' WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3")
        .bind(&vault_id)
        .bind(&record_id)
        .bind(&deleted_revision_id)
        .execute(&database.pool)
        .await
        .expect("restore expired tombstone fixture time");

    let unresolved_conflict_id = Uuid::new_v4().to_string();
    let unresolved_revision_id = Uuid::new_v4().to_string();
    let unresolved_envelope = json!({
        "header":{"revision_id":unresolved_revision_id},
        "nonce":"unresolved-nonce","ciphertext":"unresolved-private","signature":"s"
    });
    sqlx::query(
        "INSERT INTO conflicts(conflict_id,vault_id,record_id,base_revision_id,envelope,digest, \
         device_id,created_at,conflict_seq) VALUES($1,$2,$3,$4,$5,'unresolved-digest',$6,$7,3)",
    )
    .bind(&unresolved_conflict_id)
    .bind(&vault_id)
    .bind(&record_id)
    .bind(&created_revision_id)
    .bind(unresolved_envelope.to_string())
    .bind(&owner_device_id)
    .bind(now)
    .execute(&database.pool)
    .await
    .expect("insert unresolved conflict for purge gate acceptance");
    sqlx::query("UPDATE vault_counters SET last_conflict_seq=3 WHERE vault_id=$1")
        .bind(&vault_id)
        .execute(&database.pool)
        .await
        .expect("advance conflict counter to unresolved conflict");
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "RECORD_HAS_UNRESOLVED_CONFLICTS");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "an unresolved conflict must not mutate server state"
    );
    sqlx::query("DELETE FROM conflicts WHERE conflict_id=$1 AND vault_id=$2")
        .bind(&unresolved_conflict_id)
        .bind(&vault_id)
        .execute(&database.pool)
        .await
        .expect("remove unresolved conflict fixture");
    sqlx::query("UPDATE vault_counters SET last_conflict_seq=2 WHERE vault_id=$1")
        .bind(&vault_id)
        .execute(&database.pool)
        .await
        .expect("restore conflict counter after unresolved-conflict fixture");

    let duplicate_record_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope, \
         digest,commit_seq,device_id,operation,created_at) \
         VALUES($1,$2,$3,NULL,$4,'legacy-duplicate-digest',4,$5,'create',$6)",
    )
    .bind(&vault_id)
    .bind(&duplicate_record_id)
    .bind(&created_revision_id)
    .bind(
        json!({"header":{"revision_id":created_revision_id},"nonce":"n","ciphertext":"foreign"})
            .to_string(),
    )
    .bind(&owner_device_id)
    .bind(now)
    .execute(&database.pool)
    .await
    .expect("insert legal legacy duplicate revision ID on another record");
    sqlx::query("INSERT INTO object_references(vault_id,revision_id,object_id) VALUES($1,$2,$3)")
        .bind(&vault_id)
        .bind(&created_revision_id)
        .bind(&shared_object_id)
        .execute(&database.pool)
        .await
        .expect("insert foreign legacy attachment reference");
    let state_before = record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[1],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 409, "{body}");
    assert_eq!(body["error"]["code"], "REDACTION_REFERENCE_AMBIGUOUS");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before,
        "an ambiguous legacy revision mapping must preserve sequences and object references"
    );
    sqlx::query(
        "DELETE FROM object_references WHERE vault_id=$1 AND revision_id=$2 AND object_id=$3",
    )
    .bind(&vault_id)
    .bind(&created_revision_id)
    .bind(&shared_object_id)
    .execute(&database.pool)
    .await
    .expect("remove duplicate legacy object reference fixture");
    sqlx::query("DELETE FROM record_versions WHERE vault_id=$1 AND record_id=$2")
        .bind(&vault_id)
        .bind(&duplicate_record_id)
        .execute(&database.pool)
        .await
        .expect("remove duplicate legacy revision fixture");

    // A successful purge must commit durable mobile sync hints to every
    // other active member device, while excluding the source device. Inject
    // an outbox failure once first to prove that the proof/feed mutation and
    // mobile hint remain one transaction.
    for (endpoint_id, device_id, user_id, token_hash) in [
        (
            "pg-purge-source-endpoint",
            &owner_device_id,
            &account_id,
            "a".repeat(64),
        ),
        (
            "pg-purge-peer-endpoint",
            &second_device_id,
            &account_id,
            "b".repeat(64),
        ),
        (
            "pg-purge-member-endpoint",
            &non_owner_device_id,
            &non_owner_account_id,
            "c".repeat(64),
        ),
    ] {
        sqlx::query(
            "INSERT INTO notification_push_endpoints( \
                 endpoint_id,device_id,user_id,provider,token_hash,token_envelope,created_at,updated_at \
             ) VALUES($1,$2,$3,'apns',$4,repeat('x',80),$5,$5)",
        )
        .bind(endpoint_id)
        .bind(device_id)
        .bind(user_id)
        .bind(token_hash)
        .bind(now.timestamp())
        .execute(&database.pool)
        .await
        .expect("insert purge push endpoint fixture");
    }
    sqlx::raw_sql(
        "CREATE FUNCTION purge_push_acceptance_fail() RETURNS trigger LANGUAGE plpgsql AS $$ \
         BEGIN RAISE EXCEPTION 'injected purge push enqueue failure'; END $$; \
         CREATE TRIGGER purge_push_acceptance_fail_trigger BEFORE INSERT ON notification_push_outbox \
         FOR EACH ROW EXECUTE FUNCTION purge_push_acceptance_fail();",
    )
    .execute(&database.pool)
    .await
    .expect("install purge push enqueue rollback fault");
    let state_before_push_failure =
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await;
    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 500, "{body}");
    assert_eq!(body["error"]["code"], "INTERNAL");
    assert_eq!(
        record_purge_state_digest(&database.pool, &vault_id, &record_id).await,
        state_before_push_failure,
        "push enqueue failure must roll back the redaction transaction"
    );
    let queued_after_failure: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM notification_push_outbox WHERE endpoint_id IN \
         ('pg-purge-source-endpoint','pg-purge-peer-endpoint','pg-purge-member-endpoint')",
    )
    .fetch_one(&database.pool)
    .await
    .expect("verify failed purge did not commit push work");
    assert_eq!(queued_after_failure, 0);
    sqlx::raw_sql(
        "DROP TRIGGER purge_push_acceptance_fail_trigger ON notification_push_outbox; \
         DROP FUNCTION purge_push_acceptance_fail()",
    )
    .execute(&database.pool)
    .await
    .expect("remove purge push enqueue rollback fault");

    let (status, body) = post_record_purge(
        &client,
        &addresses[0],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["status"], "purged");
    assert_eq!(body["already_purged"], false);
    let proof = body["redaction"].clone();
    assert_eq!(proof["format"], "atermius-record-redaction-proof-v1");
    assert_eq!(proof["vault_id"], vault_id);
    assert_eq!(proof["record_id"], record_id);
    assert_eq!(proof["deleted_revision_id"], deleted_revision_id);
    assert_eq!(proof["deleted_seq"], "2");
    assert_eq!(proof["redaction_seq"], "4");
    verify_record_redaction_proof(&proof);

    let push_sequences: Vec<(String, i64)> = sqlx::query_as(
        "SELECT endpoint_id,requested_seq FROM notification_push_outbox \
         WHERE endpoint_id IN ('pg-purge-source-endpoint','pg-purge-peer-endpoint','pg-purge-member-endpoint') \
         ORDER BY endpoint_id",
    )
    .fetch_all(&database.pool)
    .await
    .expect("read durable push hints after purge");
    assert_eq!(
        push_sequences,
        vec![
            ("pg-purge-member-endpoint".to_owned(), 1),
            ("pg-purge-peer-endpoint".to_owned(), 1),
        ],
        "purge queues each other active member device exactly once and excludes the source"
    );

    // Retry through the peer node exactly simulates a lost acknowledgement;
    // it must return the same immutable unsigned statement and current proof.
    let (status, retry) = post_record_purge(
        &client,
        &addresses[1],
        &access_token,
        &vault_id,
        &record_id,
        &deleted_revision_id,
        "2",
        true,
    )
    .await;
    assert_eq!(status, 200, "{retry}");
    assert_eq!(retry["already_purged"], true);
    assert_eq!(retry["redaction"], proof);
    let push_sequences_after_retry: Vec<(String, i64)> = sqlx::query_as(
        "SELECT endpoint_id,requested_seq FROM notification_push_outbox \
         WHERE endpoint_id IN ('pg-purge-source-endpoint','pg-purge-peer-endpoint','pg-purge-member-endpoint') \
         ORDER BY endpoint_id",
    )
    .fetch_all(&database.pool)
    .await
    .expect("read durable push hints after purge retry");
    assert_eq!(
        push_sequences_after_retry, push_sequences,
        "idempotent purge retry must not enqueue duplicate mobile push work"
    );

    let old_snapshot = client
        .get(format!(
            "{}/api/v1/snapshots/{old_snapshot_id}?limit=1",
            addresses[1]
        ))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("request invalidated snapshot through peer node");
    assert_eq!(old_snapshot.status().as_u16(), 410);
    let old_snapshot: Value = old_snapshot.json().await.expect("decode snapshot error");
    assert_eq!(old_snapshot["error"]["code"], "SNAPSHOT_REDACTED");

    let old_revision = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/revisions/{created_revision_id}",
            addresses[1]
        ))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("request redacted direct revision through peer node");
    assert_eq!(old_revision.status().as_u16(), 410);
    let old_revision: Value = old_revision.json().await.expect("decode revision error");
    assert_eq!(old_revision["error"]["code"], "RECORD_REDACTED");
    assert_eq!(old_revision["error"]["details"]["redaction"], proof);

    let old_object = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/objects/{collectible_object_id}",
            addresses[1]
        ))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("request purged attachment through peer node");
    assert_eq!(old_object.status().as_u16(), 404);

    // A snapshot created after purge has one stable graveyard item for the
    // redacted record, signed with the current instance key on read.
    let fresh_snapshot_response = client
        .post(format!(
            "{}/api/v1/vaults/{vault_id}/snapshots",
            addresses[1]
        ))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("create a fresh post-purge snapshot through peer node");
    assert_eq!(fresh_snapshot_response.status().as_u16(), 200);
    let fresh_snapshot: Value = fresh_snapshot_response
        .json()
        .await
        .expect("decode fresh snapshot creation response");
    let fresh_snapshot_id = fresh_snapshot["snapshot_id"]
        .as_str()
        .expect("fresh snapshot id")
        .to_owned();
    let fresh_snapshot_response = client
        .get(format!(
            "{}/api/v1/snapshots/{fresh_snapshot_id}",
            addresses[1]
        ))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read fresh post-purge snapshot through peer node");
    assert_eq!(fresh_snapshot_response.status().as_u16(), 200);
    let fresh_snapshot_view: Value = fresh_snapshot_response
        .json()
        .await
        .expect("decode fresh snapshot manifest");
    let graveyard_items = fresh_snapshot_view["manifest"]
        .as_array()
        .expect("fresh inline snapshot manifest")
        .iter()
        .filter(|item| item["kind"] == "graveyard" && item["record_id"] == record_id)
        .collect::<Vec<_>>();
    assert_eq!(
        graveyard_items.len(),
        1,
        "fresh snapshot has one graveyard item"
    );
    assert_eq!(
        graveyard_items[0]["deleted_revision_id"],
        deleted_revision_id
    );
    assert_eq!(graveyard_items[0]["deleted_seq"], "2");
    assert_eq!(graveyard_items[0]["redaction"], proof);
    verify_record_redaction_proof(&graveyard_items[0]["redaction"]);

    // Snapshot-bound revision history retains both old sequence positions
    // but returns a signed redacted projection for each encrypted payload.
    let revisions_response = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/revisions",
            addresses[1]
        ))
        .query(&[("snapshot_id", fresh_snapshot_id.as_str()), ("limit", "1")])
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read snapshot-bound revisions from peer node");
    assert_eq!(revisions_response.status().as_u16(), 200);
    let first_revisions: Value = revisions_response
        .json()
        .await
        .expect("decode first redacted revision page");
    assert_eq!(first_revisions["revisions"].as_array().unwrap().len(), 1);
    assert_eq!(first_revisions["revisions"][0]["commit_seq"], "1");
    assert_eq!(first_revisions["revisions"][0]["operation"], "redacted");
    assert_eq!(first_revisions["revisions"][0]["redaction"], proof);
    assert_eq!(first_revisions["has_more"], true);
    let revision_cursor = first_revisions["next_cursor"]
        .as_str()
        .expect("revision continuation cursor");
    let second_revisions_response = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/revisions",
            addresses[1]
        ))
        .query(&[
            ("snapshot_id", fresh_snapshot_id.as_str()),
            ("limit", "1"),
            ("cursor", revision_cursor),
        ])
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read second redacted revision page from peer node");
    assert_eq!(second_revisions_response.status().as_u16(), 200);
    let second_revisions: Value = second_revisions_response
        .json()
        .await
        .expect("decode second redacted revision page");
    assert_eq!(second_revisions["revisions"][0]["commit_seq"], "2");
    assert_eq!(second_revisions["revisions"][0]["operation"], "redacted");
    assert_eq!(second_revisions["revisions"][0]["redaction"], proof);

    let conflicts_response = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/conflicts",
            addresses[1]
        ))
        .query(&[("snapshot_id", fresh_snapshot_id.as_str()), ("limit", "1")])
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read snapshot-bound conflict history from peer node");
    assert_eq!(conflicts_response.status().as_u16(), 200);
    let conflicts_history: Value = conflicts_response
        .json()
        .await
        .expect("decode redacted conflict history");
    assert_eq!(conflicts_history["conflicts"].as_array().unwrap().len(), 1);
    assert_eq!(conflicts_history["conflicts"][0]["conflict_seq"], "1");
    assert_eq!(conflicts_history["conflicts"][0]["resolution_seq"], "2");
    assert_eq!(
        conflicts_history["conflicts"][0]["resolved_revision_id"],
        Value::Null
    );
    assert_eq!(conflicts_history["conflicts"][0]["redaction"], proof);

    let conflict_feed_first = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/conflict-changes",
            addresses[1]
        ))
        .query(&[("limit", "1")])
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read first redacted conflict-feed page");
    let conflict_feed_first_status = conflict_feed_first.status().as_u16();
    let conflict_feed_first_body = conflict_feed_first
        .text()
        .await
        .expect("read first redacted conflict-feed page body");
    assert_eq!(
        conflict_feed_first_status, 200,
        "{conflict_feed_first_body}"
    );
    let conflict_feed_first: Value = serde_json::from_str(&conflict_feed_first_body)
        .expect("decode first redacted conflict-feed page");
    assert_eq!(conflict_feed_first["events"].as_array().unwrap().len(), 1);
    assert_eq!(conflict_feed_first["events"][0]["seq"], "1");
    assert_eq!(conflict_feed_first["events"][0]["type"], "redacted");
    assert_eq!(conflict_feed_first["events"][0]["redaction"], proof);
    assert_eq!(conflict_feed_first["has_more"], true);
    assert_eq!(conflict_feed_first["next_after_seq"], "1");
    let feed_generation = conflict_feed_first["server_generation"]
        .as_str()
        .expect("conflict feed generation");
    let conflict_feed_second = client
        .get(format!(
            "{}/api/v1/vaults/{vault_id}/conflict-changes",
            addresses[1]
        ))
        .query(&[
            ("after_seq", "1"),
            ("limit", "1"),
            ("server_generation", feed_generation),
        ])
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read second redacted conflict-feed page");
    assert_eq!(conflict_feed_second.status().as_u16(), 200);
    let conflict_feed_second: Value = conflict_feed_second
        .json()
        .await
        .expect("decode second redacted conflict-feed page");
    assert_eq!(conflict_feed_second["events"].as_array().unwrap().len(), 1);
    assert_eq!(conflict_feed_second["events"][0]["seq"], "2");
    assert_eq!(conflict_feed_second["events"][0]["type"], "redacted");
    assert_eq!(conflict_feed_second["events"][0]["redaction"], proof);
    assert_eq!(conflict_feed_second["has_more"], false);
    assert_eq!(conflict_feed_second["next_after_seq"], "2");

    let object_state = sqlx::query(
        "SELECT collected.gc_after AS collected_gc,shared.gc_after AS shared_gc, \
                (SELECT COUNT(*) FROM object_references WHERE vault_id=$1 AND object_id=$2) AS collected_refs, \
                (SELECT COUNT(*) FROM object_references WHERE vault_id=$1 AND object_id=$3) AS shared_refs, \
                (SELECT COUNT(*) FROM uploads WHERE vault_id=$1 AND object_id=$2 AND state='collected') AS collected_grants, \
                (SELECT COUNT(*) FROM uploads WHERE vault_id=$1 AND object_id=$3 AND state='completed') AS shared_grants \
         FROM blob_objects collected JOIN blob_objects shared ON shared.vault_id=collected.vault_id \
         WHERE collected.vault_id=$1 AND collected.object_id=$2 AND shared.object_id=$3",
    )
    .bind(&vault_id)
    .bind(&collectible_object_id)
    .bind(&shared_object_id)
    .fetch_one(&database.pool)
    .await
    .expect("read post-purge attachment reachability");
    assert!(object_state.get::<Option<i64>, _>("collected_gc").is_some());
    assert_eq!(object_state.get::<Option<i64>, _>("shared_gc"), None);
    assert_eq!(object_state.get::<i64, _>("collected_refs"), 0);
    assert_eq!(object_state.get::<i64, _>("shared_refs"), 1);
    assert_eq!(object_state.get::<i64, _>("collected_grants"), 1);
    assert_eq!(object_state.get::<i64, _>("shared_grants"), 1);

    // Purge establishes the GC deadline, while the test forces only the
    // unshared object's deadline due so the real PostgreSQL worker can collect
    // it without changing the shared live-revision object's reachability.
    let due_deadline = sqlx::query(
        "UPDATE blob_objects \
         SET gc_after=floor(extract(epoch FROM clock_timestamp()))::BIGINT-1 \
         WHERE vault_id=$1 AND object_id=$2 AND storage_state='available'",
    )
    .bind(&vault_id)
    .bind(&collectible_object_id)
    .execute(&database.pool)
    .await
    .expect("make only the purge-created unshared object GC-due");
    assert_eq!(due_deadline.rows_affected(), 1);

    // This committed pin set has the same header and exact store/key rows the
    // backup snapshot path writes transactionally before pg_dump. The worker
    // therefore sees a live backup pin, not a test-only collector bypass.
    let backup_id = Uuid::new_v4().to_string();
    sqlx::query(
        "INSERT INTO backup_object_pin_sets(backup_id,object_count,expires_at) \
         VALUES($1,1,clock_timestamp()+INTERVAL '5 minutes')",
    )
    .bind(&backup_id)
    .execute(&database.pool)
    .await
    .expect("insert active backup pin-set header");
    sqlx::query(
        "INSERT INTO backup_object_pins(backup_id,storage_store_id,storage_key,expires_at) \
         VALUES($1,$2,$3,clock_timestamp()+INTERVAL '5 minutes')",
    )
    .bind(&backup_id)
    .bind(&object_store_id)
    .bind(&collectible_storage_key)
    .execute(&database.pool)
    .await
    .expect("pin the exact collectible object for an active backup");

    let worker_port = std::net::TcpListener::bind("127.0.0.1:0")
        .expect("reserve local PostgreSQL GC worker port");
    let worker_address = worker_port
        .local_addr()
        .expect("read reserved PostgreSQL GC worker port");
    drop(worker_port);
    let worker_data_dir = data_root.join("pg-object-gc-worker");
    let mut gc_worker = spawn_pg_object_gc_worker(
        &worker_data_dir,
        &format!("127.0.0.1:{}", worker_address.port()),
    );
    let worker_url = format!("http://{worker_address}");
    let worker_client = reqwest::Client::new();
    let ready_deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(status) = gc_worker
            .child
            .try_wait()
            .expect("check PostgreSQL GC worker process")
        {
            panic!("PostgreSQL GC worker exited before readiness: {status}");
        }
        if let Ok(response) = worker_client
            .get(format!("{worker_url}/health/live"))
            .timeout(Duration::from_millis(300))
            .send()
            .await
            && response.status().is_success()
        {
            break;
        }
        assert!(
            tokio::time::Instant::now() < ready_deadline,
            "PostgreSQL GC worker did not become healthy"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    // /health/live is exposed only after serve starts its maintenance worker.
    // Let the worker's immediate first tick pass, then verify both the active
    // pin and the still-due catalogue row prevented queue creation.
    tokio::time::sleep(Duration::from_millis(500)).await;
    let pinned_state = sqlx::query(
        "SELECT b.gc_after<=floor(extract(epoch FROM clock_timestamp()))::BIGINT AS due, \
                EXISTS(SELECT 1 FROM backup_object_pin_sets s WHERE s.backup_id=$3 \
                       AND s.object_count=1 AND s.expires_at>clock_timestamp()) AS live_pin_set, \
                EXISTS(SELECT 1 FROM backup_object_pins p WHERE p.backup_id=$3 \
                       AND p.storage_store_id=$4 AND p.storage_key=$5 \
                       AND p.expires_at>clock_timestamp()) AS live_object_pin, \
                (SELECT COUNT(*) FROM object_delete_queue q \
                 WHERE q.storage_store_id=$4 AND q.storage_key=$5) AS queued \
         FROM blob_objects b WHERE b.vault_id=$1 AND b.object_id=$2",
    )
    .bind(&vault_id)
    .bind(&collectible_object_id)
    .bind(&backup_id)
    .bind(&object_store_id)
    .bind(&collectible_storage_key)
    .fetch_one(&database.pool)
    .await
    .expect("read due object while the backup pin is active");
    assert!(pinned_state.get::<bool, _>("due"));
    assert!(pinned_state.get::<bool, _>("live_pin_set"));
    assert!(pinned_state.get::<bool, _>("live_object_pin"));
    assert_eq!(pinned_state.get::<i64, _>("queued"), 0);
    assert!(object_store_root.join(&collectible_storage_key).is_file());

    // The durable queue row and catalogue retirement commit together. Pause
    // the provider worker's first lease claim briefly so the test can inspect
    // that committed deletion intent before allowing real filesystem deletion.
    sqlx::raw_sql(
        "CREATE FUNCTION purge_gc_acceptance_pause_claim() RETURNS trigger LANGUAGE plpgsql AS $$ \
         BEGIN \
           IF OLD.lease_id IS NULL AND NEW.lease_id IS NOT NULL THEN PERFORM pg_sleep(3); END IF; \
           RETURN NEW; \
         END $$; \
         CREATE TRIGGER purge_gc_acceptance_pause_claim BEFORE UPDATE OF lease_id \
         ON object_delete_queue FOR EACH ROW EXECUTE FUNCTION purge_gc_acceptance_pause_claim();",
    )
    .execute(&database.pool)
    .await
    .expect("pause the first delete-queue lease for a bounded inspection window");
    sqlx::query(
        "UPDATE backup_object_pins SET expires_at=clock_timestamp()-INTERVAL '1 second' \
         WHERE backup_id=$1",
    )
    .bind(&backup_id)
    .execute(&database.pool)
    .await
    .expect("expire active backup object pin");
    sqlx::query(
        "UPDATE backup_object_pin_sets SET expires_at=clock_timestamp()-INTERVAL '1 second' \
         WHERE backup_id=$1",
    )
    .bind(&backup_id)
    .execute(&database.pool)
    .await
    .expect("expire active backup pin-set lease");

    let collection_deadline = tokio::time::Instant::now() + Duration::from_secs(22);
    loop {
        let collection_state = sqlx::query(
            "SELECT (SELECT COUNT(*) FROM blob_objects b \
                     WHERE b.vault_id=$1 AND b.object_id=$2) AS catalogue_rows, \
                    (SELECT COUNT(*) FROM object_delete_queue q \
                     WHERE q.storage_store_id=$3 AND q.storage_key=$4) AS queue_rows",
        )
        .bind(&vault_id)
        .bind(&collectible_object_id)
        .bind(&object_store_id)
        .bind(&collectible_storage_key)
        .fetch_one(&database.pool)
        .await
        .expect("wait for real PostgreSQL object collection");
        if collection_state.get::<i64, _>("catalogue_rows") == 0
            && collection_state.get::<i64, _>("queue_rows") == 1
        {
            break;
        }
        assert!(
            tokio::time::Instant::now() < collection_deadline,
            "PostgreSQL GC did not retire the due object into its durable delete queue"
        );
        tokio::time::sleep(Duration::from_millis(100)).await;
    }

    let durable_delete = sqlx::query(
        "SELECT storage_backend,storage_store_id,storage_key,expected_size,expected_sha256, \
                state,attempt_count,lease_id IS NULL AS unleased,lease_until IS NULL AS no_lease_until \
         FROM object_delete_queue WHERE storage_store_id=$1 AND storage_key=$2",
    )
    .bind(&object_store_id)
    .bind(&collectible_storage_key)
    .fetch_one(&database.pool)
    .await
    .expect("read durable delete intent after catalogue retirement");
    let collectible_digest = hex::encode(Sha256::digest(collectible_object_bytes));
    assert_eq!(
        durable_delete.get::<String, _>("storage_backend"),
        "filesystem"
    );
    assert_eq!(
        durable_delete.get::<String, _>("storage_store_id"),
        object_store_id
    );
    assert_eq!(
        durable_delete.get::<String, _>("storage_key"),
        collectible_storage_key
    );
    assert_eq!(
        durable_delete.get::<i64, _>("expected_size"),
        collectible_object_bytes.len() as i64
    );
    assert_eq!(
        durable_delete.get::<String, _>("expected_sha256"),
        collectible_digest
    );
    assert_eq!(durable_delete.get::<String, _>("state"), "pending");
    assert_eq!(durable_delete.get::<i64, _>("attempt_count"), 0);
    assert!(durable_delete.get::<bool, _>("unleased"));
    assert!(durable_delete.get::<bool, _>("no_lease_until"));

    let collected_upload = sqlx::query(
        "SELECT state,expected_size,expected_sha256,storage_key FROM uploads \
         WHERE vault_id=$1 AND object_id=$2 AND state='collected'",
    )
    .bind(&vault_id)
    .bind(&collectible_object_id)
    .fetch_one(&database.pool)
    .await
    .expect("verify GC revoked the collectible completed-upload retry grant");
    assert_eq!(collected_upload.get::<String, _>("state"), "collected");
    assert_eq!(
        collected_upload.get::<i64, _>("expected_size"),
        collectible_object_bytes.len() as i64
    );
    assert_eq!(
        collected_upload.get::<String, _>("expected_sha256"),
        collectible_digest
    );
    assert_eq!(
        collected_upload.get::<String, _>("storage_key"),
        collectible_storage_key
    );

    let shared_after_collection = sqlx::query(
        "SELECT b.size,b.sha256,b.storage_key,b.storage_state,b.gc_after, \
                (SELECT COUNT(*) FROM object_references r \
                 WHERE r.vault_id=b.vault_id AND r.object_id=b.object_id) AS reference_count, \
                u.state AS upload_state,u.expected_size AS upload_size, \
                u.expected_sha256 AS upload_sha256,u.storage_key AS upload_key \
         FROM blob_objects b JOIN uploads u ON u.vault_id=b.vault_id AND u.object_id=b.object_id \
         WHERE b.vault_id=$1 AND b.object_id=$2 AND u.state='completed'",
    )
    .bind(&vault_id)
    .bind(&shared_object_id)
    .fetch_one(&database.pool)
    .await
    .expect("read shared live object after collectible GC");
    let shared_digest = hex::encode(Sha256::digest(shared_object_bytes));
    assert_eq!(
        shared_after_collection.get::<i64, _>("size"),
        shared_object_bytes.len() as i64
    );
    assert_eq!(
        shared_after_collection.get::<String, _>("sha256"),
        shared_digest
    );
    assert_eq!(
        shared_after_collection.get::<String, _>("storage_key"),
        shared_storage_key
    );
    assert_eq!(
        shared_after_collection.get::<String, _>("storage_state"),
        "available"
    );
    assert_eq!(
        shared_after_collection.get::<Option<i64>, _>("gc_after"),
        None
    );
    assert_eq!(shared_after_collection.get::<i64, _>("reference_count"), 1);
    assert_eq!(
        shared_after_collection.get::<String, _>("upload_state"),
        "completed"
    );
    assert_eq!(
        shared_after_collection.get::<i64, _>("upload_size"),
        shared_object_bytes.len() as i64
    );
    assert_eq!(
        shared_after_collection.get::<String, _>("upload_sha256"),
        shared_digest
    );
    assert_eq!(
        shared_after_collection.get::<String, _>("upload_key"),
        shared_storage_key
    );
    assert!(object_store_root.join(&shared_storage_key).is_file());

    let deletion_deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        let queue_rows: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM object_delete_queue WHERE storage_store_id=$1 AND storage_key=$2",
        )
        .bind(&object_store_id)
        .bind(&collectible_storage_key)
        .fetch_one(&database.pool)
        .await
        .expect("wait for real filesystem deletion queue completion");
        if queue_rows == 0 && !object_store_root.join(&collectible_storage_key).exists() {
            break;
        }
        if tokio::time::Instant::now() >= deletion_deadline {
            let queue_state = sqlx::query(
                "SELECT state,attempt_count,last_failure_category,lease_id IS NULL AS unleased \
                 FROM object_delete_queue WHERE storage_store_id=$1 AND storage_key=$2",
            )
            .bind(&object_store_id)
            .bind(&collectible_storage_key)
            .fetch_optional(&database.pool)
            .await
            .expect("inspect stuck filesystem deletion intent");
            let diagnostic = queue_state.map(|row| {
                format!(
                    "state={}, attempts={}, failure={:?}, unleased={}",
                    row.get::<String, _>("state"),
                    row.get::<i64, _>("attempt_count"),
                    row.get::<Option<String>, _>("last_failure_category"),
                    row.get::<bool, _>("unleased")
                )
            });
            panic!(
                "object delete queue did not finish physical filesystem deletion; queue={diagnostic:?}, object_exists={}",
                object_store_root.join(&collectible_storage_key).exists()
            );
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert!(object_store_root.join(&shared_storage_key).is_file());
    drop(gc_worker);
    sqlx::raw_sql(
        "DROP TRIGGER purge_gc_acceptance_pause_claim ON object_delete_queue; \
         DROP FUNCTION purge_gc_acceptance_pause_claim()",
    )
    .execute(&database.pool)
    .await
    .expect("remove temporary GC acceptance queue synchronization trigger");

    let preserved_receipts: (i64, i64) = sqlx::query_as(
        "SELECT (SELECT COUNT(*) FROM op_receipts WHERE vault_id=$1), \
                (SELECT COUNT(*) FROM batch_receipts WHERE vault_id=$1)",
    )
    .bind(&vault_id)
    .fetch_one(&database.pool)
    .await
    .expect("read idempotency receipt counts after purge");
    assert_eq!(preserved_receipts, (1, 1));
    let scrubbed_history = sqlx::query(
        "SELECT (SELECT COUNT(*) FROM record_versions WHERE vault_id=$1 AND record_id=$2 \
                   AND envelope='{}' AND digest='' AND device_id='') AS revisions, \
                (SELECT COUNT(*) FROM change_events WHERE vault_id=$1 AND record_id=$2 \
                   AND event_type='redacted' AND envelope='{}' AND revision_id='') AS events, \
                (SELECT COUNT(*) FROM conflicts WHERE vault_id=$1 AND record_id=$2 \
                   AND envelope='{}' AND digest='' AND device_id='' AND op_id IS NULL \
                   AND resolved_revision_id IS NULL AND resolution_seq=2 \
                   AND resolution_at IS NOT NULL) AS conflicts, \
                (SELECT COUNT(*) FROM record_heads WHERE vault_id=$1 AND record_id=$2) AS heads, \
                (SELECT COUNT(*) FROM record_graveyard WHERE vault_id=$1 AND record_id=$2 \
                   AND deleted_revision=$3 AND deleted_seq=2) AS graveyard",
    )
    .bind(&vault_id)
    .bind(&record_id)
    .bind(&deleted_revision_id)
    .fetch_one(&database.pool)
    .await
    .expect("read preserved and scrubbed redaction rows");
    assert_eq!(scrubbed_history.get::<i64, _>("revisions"), 2);
    assert_eq!(scrubbed_history.get::<i64, _>("events"), 2);
    assert_eq!(scrubbed_history.get::<i64, _>("conflicts"), 1);
    assert_eq!(scrubbed_history.get::<i64, _>("heads"), 0);
    assert_eq!(scrubbed_history.get::<i64, _>("graveyard"), 1);
    let snapshot_scrubbed: (String, i64, String, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as(
            "SELECT manifest_json,snapshot_item_count,snapshot_manifest_format,redacted_at \
             FROM snapshots WHERE snapshot_id=$1",
        )
        .bind(&old_snapshot_id)
        .fetch_one(&database.pool)
        .await
        .expect("read invalidated snapshot after purge");
    assert_eq!(snapshot_scrubbed.0, "[]");
    assert_eq!(snapshot_scrubbed.1, 0);
    assert_eq!(snapshot_scrubbed.2, "expired");
    assert!(snapshot_scrubbed.3.is_some());
    let erased_pages: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM snapshot_items WHERE snapshot_id=$1")
            .bind(&old_snapshot_id)
            .fetch_one(&database.pool)
            .await
            .expect("check old snapshot page erasure");
    assert_eq!(erased_pages, 0);

    let changes = client
        .get(format!("{}/api/v1/vaults/{vault_id}/changes", addresses[1]))
        .bearer_auth(&access_token)
        .header("x-atermius-redaction-marker", "v1")
        .send()
        .await
        .expect("read purge event from peer node");
    assert_eq!(changes.status().as_u16(), 200);
    let changes: Value = changes.json().await.expect("decode redacted changes");
    assert_eq!(changes["events"][0]["event_type"], "record_redacted");
    assert_eq!(changes["events"][0]["redaction"], proof);

    // A one-shot database fault happens after snapshot invalidation, history
    // scrubbing, reference changes, and counter allocation. Two concurrent
    // peer-node retries force one transaction to roll back and one to commit;
    // the transactional counter must contain no gap and only one proof row.
    let (retry_created_at, retry_deleted_at): (
        chrono::DateTime<chrono::Utc>,
        chrono::DateTime<chrono::Utc>,
    ) = sqlx::query_as(
        "SELECT clock_timestamp()-INTERVAL '45 days', \
                clock_timestamp()-INTERVAL '31 days'",
    )
    .fetch_one(&database.pool)
    .await
    .expect("sample rollback-race fixture timestamps from PostgreSQL");
    let retry_create_envelope = json!({
        "header":{"revision_id":retry_race_create_revision_id,"record_schema":1},
        "nonce":"rollback-create","ciphertext":"rollback-create-secret","signature":"s"
    });
    let retry_delete_envelope = json!({
        "header":{"revision_id":retry_race_delete_revision_id,"record_schema":1},
        "nonce":"rollback-delete","ciphertext":"rollback-delete-secret","signature":"s"
    });
    sqlx::query(
        "INSERT INTO record_versions(vault_id,record_id,revision_id,base_revision_id,envelope,digest, \
         commit_seq,device_id,operation,created_at) \
         VALUES($1,$2,$3,NULL,$4,'rollback-digest-create',5,$5,'create',$6), \
               ($1,$2,$7,$3,$8,'rollback-digest-delete',6,$5,'delete',$9)",
    )
    .bind(&vault_id)
    .bind(&retry_race_record_id)
    .bind(&retry_race_create_revision_id)
    .bind(retry_create_envelope.to_string())
    .bind(&owner_device_id)
    .bind(retry_created_at)
    .bind(&retry_race_delete_revision_id)
    .bind(retry_delete_envelope.to_string())
    .bind(retry_deleted_at)
    .execute(&database.pool)
    .await
    .expect("insert rollback-race tombstone versions");
    sqlx::query(
        "UPDATE record_versions SET restore_until=clock_timestamp()-INTERVAL '1 second' \
         WHERE vault_id=$1 AND record_id=$2 AND revision_id=$3",
    )
    .bind(&vault_id)
    .bind(&retry_race_record_id)
    .bind(&retry_race_delete_revision_id)
    .execute(&database.pool)
    .await
    .expect("seed rollback-race tombstone restore deadline");
    sqlx::query(
        "INSERT INTO record_heads(vault_id,record_id,revision_id,deleted,commit_seq) \
         VALUES($1,$2,$3,TRUE,6)",
    )
    .bind(&vault_id)
    .bind(&retry_race_record_id)
    .bind(&retry_race_delete_revision_id)
    .execute(&database.pool)
    .await
    .expect("insert rollback-race tombstone head");
    sqlx::query(
        "INSERT INTO record_graveyard(vault_id,record_id,deleted_revision,deleted_seq) \
         VALUES($1,$2,$3,6)",
    )
    .bind(&vault_id)
    .bind(&retry_race_record_id)
    .bind(&retry_race_delete_revision_id)
    .execute(&database.pool)
    .await
    .expect("insert rollback-race graveyard row");
    for (seq, revision, operation, envelope, timestamp) in [
        (
            5_i64,
            &retry_race_create_revision_id,
            "create",
            &retry_create_envelope,
            retry_created_at,
        ),
        (
            6_i64,
            &retry_race_delete_revision_id,
            "delete",
            &retry_delete_envelope,
            retry_deleted_at,
        ),
    ] {
        sqlx::query(
            "INSERT INTO change_events(vault_id,commit_seq,event_type,record_id,revision_id,envelope,created_at) \
             VALUES($1,$2,$3,$4,$5,$6,$7)",
        )
        .bind(&vault_id)
        .bind(seq)
        .bind(operation)
        .bind(&retry_race_record_id)
        .bind(revision)
        .bind(envelope.to_string())
        .bind(timestamp)
        .execute(&database.pool)
        .await
        .expect("insert rollback-race event row");
    }
    sqlx::query("UPDATE vault_counters SET last_committed_seq=6 WHERE vault_id=$1")
        .bind(&vault_id)
        .execute(&database.pool)
        .await
        .expect("advance test sequence to the second tombstone");
    sqlx::query(
        "INSERT INTO snapshots(snapshot_id,vault_id,requested_by,high_watermark,conflict_high_watermark, \
         manifest_json,expires_at,created_at,server_generation,snapshot_item_count,snapshot_manifest_format) \
         VALUES($1,$2,$3,6,2,$4,CURRENT_TIMESTAMP+INTERVAL '1 hour',$5,'pg-test-generation',1,'paged')",
    )
    .bind(&retry_race_snapshot_id)
    .bind(&vault_id)
    .bind(&account_id)
    .bind(json!([{"kind":"head","record_id":retry_race_record_id,"envelope":{"ciphertext":"rollback-snapshot-secret"}}]).to_string())
    .bind(now)
    .execute(&database.pool)
    .await
    .expect("insert rollback-race snapshot");
    sqlx::query("INSERT INTO snapshot_items(snapshot_id,record_id,item_json) VALUES($1,$2,$3)")
        .bind(&retry_race_snapshot_id)
        .bind(&retry_race_record_id)
        .bind(json!({"kind":"head","record_id":retry_race_record_id,"envelope":{"ciphertext":"rollback-snapshot-secret"}}).to_string())
        .execute(&database.pool)
        .await
        .expect("insert rollback-race snapshot page");
    sqlx::raw_sql(
        "CREATE SEQUENCE purge_acceptance_fail_once_seq; \
         CREATE FUNCTION purge_acceptance_fail_once() RETURNS trigger LANGUAGE plpgsql AS $$ \
         BEGIN \
           IF NEW.event_type='record_redacted' AND nextval('purge_acceptance_fail_once_seq')=1 THEN \
             PERFORM pg_sleep(0.25); \
             RAISE EXCEPTION 'one-shot purge rollback acceptance fault'; \
           END IF; \
           RETURN NEW; \
         END $$; \
         CREATE TRIGGER purge_acceptance_fail_once_trigger BEFORE INSERT ON change_events \
         FOR EACH ROW EXECUTE FUNCTION purge_acceptance_fail_once();",
    )
    .execute(&database.pool)
    .await
    .expect("install one-shot failure after purge state has been staged");

    let (node_a_result, node_b_result) = tokio::join!(
        post_record_purge(
            &client,
            &addresses[0],
            &access_token,
            &vault_id,
            &retry_race_record_id,
            &retry_race_delete_revision_id,
            "6",
            true,
        ),
        post_record_purge(
            &client,
            &addresses[1],
            &access_token,
            &vault_id,
            &retry_race_record_id,
            &retry_race_delete_revision_id,
            "6",
            true,
        ),
    );
    let results = [node_a_result, node_b_result];
    let success = results
        .iter()
        .find(|(status, _)| *status == 200)
        .expect("one concurrent purge succeeds");
    let failure = results
        .iter()
        .find(|(status, _)| *status == 500)
        .expect("one concurrent purge rolls back");
    assert_eq!(failure.1["error"]["code"], "INTERNAL");
    assert_eq!(success.1["already_purged"], false);
    verify_record_redaction_proof(&success.1["redaction"]);
    let committed_seq: i64 =
        sqlx::query_scalar("SELECT last_committed_seq FROM vault_counters WHERE vault_id=$1")
            .bind(&vault_id)
            .fetch_one(&database.pool)
            .await
            .expect("read sequence after failed and successful concurrent purge");
    assert_eq!(
        committed_seq, 7,
        "rolled-back attempt must not consume a sequence"
    );
    let second_redactions: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM record_redactions WHERE vault_id=$1 AND record_id=$2",
    )
    .bind(&vault_id)
    .bind(&retry_race_record_id)
    .fetch_one(&database.pool)
    .await
    .expect("count race target proof rows");
    assert_eq!(second_redactions, 1);
    let retry_snapshot_redacted: Option<chrono::DateTime<chrono::Utc>> =
        sqlx::query_scalar("SELECT redacted_at FROM snapshots WHERE snapshot_id=$1")
            .bind(&retry_race_snapshot_id)
            .fetch_one(&database.pool)
            .await
            .expect("read snapshot after concurrent rollback and commit");
    assert!(retry_snapshot_redacted.is_some());
    let final_events: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM change_events WHERE vault_id=$1 AND commit_seq=7 AND event_type='record_redacted'",
    )
    .bind(&vault_id)
    .fetch_one(&database.pool)
    .await
    .expect("confirm one committed redaction event");
    assert_eq!(final_events, 1);

    for server in servers {
        server.abort();
        let _ = server.await;
    }
    drop(states);
    database.cleanup().await;
}

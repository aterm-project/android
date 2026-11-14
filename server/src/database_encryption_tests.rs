//! SQLCipher database encryption at rest: pinned SQLCipher semantics, key-file
//! rules, startup detection, the offline CLI operations, the admin overview
//! field, and the raw-bytes canary checks.

use std::{
    fs,
    os::unix::fs::{PermissionsExt, symlink},
    path::{Path, PathBuf},
};

use axum::{
    body::Body,
    http::{Method, Request, StatusCode, header},
};
use http_body_util::BodyExt;
use sqlx::{ConnectOptions, Connection, sqlite::SqliteJournalMode};
use tower::ServiceExt;
use uuid::Uuid;

use crate::{
    ApiError, AppState, AuthRateLimits, Config, checkpoint_database_offline,
    database::{
        self, DatabaseEncryption, DatabaseFileFormat, DatabaseKey, SQLITE_PLAINTEXT_HEADER,
        detect_database_file, keyed_sqlite_options, pre_encrypt_plaintext_copy,
        sqlite_file_options, startup_database_encryption,
    },
    encrypt_database_offline, generate_database_key_file, open_state, rekey_database_offline,
    secure_file,
};

const CANARY: &str = "canary-user-7f3a1c9e@example.test";

fn private_root() -> PathBuf {
    let path = std::env::temp_dir().join(format!("atermius-dbenc-{}", Uuid::new_v4()));
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path
}

fn write_key(path: &Path, byte: u8) {
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(path).unwrap();
    std::io::Write::write_all(&mut file, &[byte; 32]).unwrap();
}

fn key(byte: u8) -> DatabaseKey {
    DatabaseKey::from_slice(&[byte; 32]).unwrap()
}

fn config(data_dir: &Path, key_file: Option<&Path>) -> Config {
    Config {
        backup_archive_dir: None,
        backup_key_file: None,
        mfa_encryption_key_file: None,
        database_key_file: key_file.map(Path::to_path_buf),
        backup_retention_count: None,
        backup_replication_env: crate::BackupReplicationEnv::default(),
        data_dir: data_dir.to_path_buf(),
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
        vault_deletion_grace_seconds: 604800,
        account_deletion_grace_seconds: 604800,
        audit_retention_days: 365,
        object_gc_grace_seconds: 604800,
        admin_usernames: vec!["dbenc-admin@example.test".to_owned()],
        auth_rate_limits: AuthRateLimits::default(),
    }
}

fn database_url(data_dir: &Path) -> String {
    format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display())
}

async fn open(data_dir: &Path, key_file: Option<&Path>) -> Result<AppState, ApiError> {
    secure_file::create_private_data_dir(data_dir).unwrap();
    open_state(&database_url(data_dir), config(data_dir, key_file)).await
}

fn file_contains(path: &Path, needle: &[u8]) -> bool {
    match fs::read(path) {
        Ok(bytes) => bytes.windows(needle.len()).any(|window| window == needle),
        Err(_) => false,
    }
}

fn has_plaintext_header(path: &Path) -> bool {
    fs::read(path)
        .map(|bytes| bytes.starts_with(SQLITE_PLAINTEXT_HEADER))
        .unwrap_or(false)
}

/// Every regular file in `directory` (no recursion needed: the data
/// directory layout is flat for the database and its sidecars).
fn regular_files(directory: &Path) -> Vec<PathBuf> {
    fs::read_dir(directory)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| fs::symlink_metadata(path).unwrap().file_type().is_file())
        .collect()
}

/// Every regular file below `directory`, recursively, without following
/// symlinks (backup snapshot directories nest one level).
fn all_regular_files(directory: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        let file_type = fs::symlink_metadata(&path).unwrap().file_type();
        if file_type.is_dir() {
            files.extend(all_regular_files(&path));
        } else if file_type.is_file() {
            files.push(path);
        }
    }
    files
}

/// What a backup killed before its `TempDirectory` cleanup leaves in the data
/// directory: a private `.backup-snapshot-<uuid>` directory holding a
/// `VACUUM INTO` snapshot (encrypted with the pool's key, if any) and copies
/// of the instance keys.
async fn leave_interrupted_backup_snapshot(state: &AppState, data_dir: &Path) -> PathBuf {
    let snapshot_dir = data_dir.join(format!(".backup-snapshot-{}", Uuid::new_v4()));
    fs::create_dir(&snapshot_dir).unwrap();
    fs::set_permissions(&snapshot_dir, fs::Permissions::from_mode(0o700)).unwrap();
    let snapshot = snapshot_dir.join("database.sqlite");
    sqlx::query("VACUUM INTO ?")
        .bind(snapshot.to_string_lossy().into_owned())
        .execute(&state.db)
        .await
        .unwrap();
    for name in ["instance-ed25519.key", "auth-rate-limit.key"] {
        fs::copy(data_dir.join(name), snapshot_dir.join(name)).unwrap();
    }
    snapshot_dir
}

async fn insert_user(state: &AppState, username: &str) {
    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
        .bind(Uuid::new_v4().to_string())
        .bind(username)
        .bind(crate::now_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
}

async fn user_exists(state: &AppState, username: &str) -> bool {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM users WHERE username=?")
        .bind(username)
        .fetch_one(&state.db)
        .await
        .unwrap()
        == 1
}

async fn checkpoint_and_close(state: AppState) {
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_all(&state.db)
        .await
        .unwrap();
    state.db.close().await;
}

fn code(result: Result<impl Sized, ApiError>) -> String {
    match result {
        Ok(_) => panic!("operation unexpectedly succeeded"),
        Err(error) => error.body.code,
    }
}

#[tokio::test]
async fn sqlcipher_semantics_relied_on_by_backup_restore_and_cli() {
    let root = private_root();
    let path = root.join("keyed.db");
    let primary = key(0x11);
    let mut connection = keyed_sqlite_options(
        sqlite_file_options(&path, None)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal),
        Some(&primary),
    )
    .connect()
    .await
    .unwrap();
    // The build links SQLCipher.
    let version: String = sqlx::query_scalar("PRAGMA cipher_version")
        .fetch_one(&mut connection)
        .await
        .unwrap();
    assert!(!version.is_empty());
    sqlx::query("CREATE TABLE users(id INTEGER PRIMARY KEY, username TEXT)")
        .execute(&mut connection)
        .await
        .unwrap();
    sqlx::query("PRAGMA user_version=42")
        .execute(&mut connection)
        .await
        .unwrap();
    sqlx::query("INSERT INTO users(username) VALUES(?)")
        .bind(CANARY)
        .execute(&mut connection)
        .await
        .unwrap();

    // VACUUM INTO on a keyed connection writes a snapshot encrypted with the
    // same key and keeps user_version; the backup path relies on this.
    let snapshot = root.join("snapshot.db");
    sqlx::query("VACUUM INTO ?")
        .bind(snapshot.to_string_lossy().into_owned())
        .execute(&mut connection)
        .await
        .unwrap();
    assert_eq!(
        detect_database_file(&snapshot).unwrap(),
        DatabaseFileFormat::Encrypted
    );
    assert!(!file_contains(&snapshot, CANARY.as_bytes()));
    let summary = database::inspect_database_file(&snapshot, Some(&primary))
        .await
        .unwrap();
    assert_eq!(summary.user_version, 42);
    assert_eq!(summary.table_rows.get("users"), Some(&1));
    let unkeyed_error = sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM sqlite_master")
        .fetch_one(
            &mut sqlite_file_options(&snapshot, None)
                .connect()
                .await
                .unwrap(),
        )
        .await
        .unwrap_err();
    assert!(database::is_not_a_database(&unkeyed_error));
    let wrong = database::inspect_database_file(&snapshot, Some(&key(0x99)))
        .await
        .unwrap_err();
    assert_eq!(wrong.body.code, "DATABASE_KEY_INVALID");

    // From a keyed connection, ATTACH without KEY inherits the main key, so a
    // plaintext file cannot be attached that way.
    let plaintext = root.join("plain.db");
    let mut plain = sqlite_file_options(&plaintext, None)
        .create_if_missing(true)
        .journal_mode(SqliteJournalMode::Wal)
        .connect()
        .await
        .unwrap();
    sqlx::query("CREATE TABLE t(x TEXT)")
        .execute(&mut plain)
        .await
        .unwrap();
    sqlx::query("PRAGMA user_version=7")
        .execute(&mut plain)
        .await
        .unwrap();
    sqlx::query("INSERT INTO t VALUES(?)")
        .bind(CANARY)
        .execute(&mut plain)
        .await
        .unwrap();
    plain.close().await.unwrap();
    let inherited = sqlx::query("ATTACH DATABASE ? AS inherited")
        .bind(plaintext.to_string_lossy().into_owned())
        .execute(&mut connection)
        .await
        .unwrap_err();
    assert!(database::is_not_a_database(&inherited));

    // Bare sqlcipher_export does not copy user_version: the export helper
    // copies it explicitly.
    let bare_export = root.join("bare-export.db");
    sqlx::query("ATTACH DATABASE ? AS bare KEY ?")
        .bind(bare_export.to_string_lossy().into_owned())
        .bind(primary.raw_key_literal().as_str())
        .execute(&mut connection)
        .await
        .unwrap();
    sqlx::query("SELECT sqlcipher_export('bare')")
        .fetch_all(&mut connection)
        .await
        .unwrap();
    let exported_version: i64 = sqlx::query_scalar("PRAGMA bare.user_version")
        .fetch_one(&mut connection)
        .await
        .unwrap();
    assert_eq!(exported_version, 0);
    sqlx::query("DETACH DATABASE bare")
        .execute(&mut connection)
        .await
        .unwrap();
    connection.close().await.unwrap();

    let exported = root.join("exported.db");
    let summary = database::export_plaintext_to_encrypted(&plaintext, &exported, &primary)
        .await
        .unwrap();
    assert_eq!(summary.user_version, 7);
    assert_eq!(summary.table_rows.get("t"), Some(&1));
    assert!(!has_plaintext_header(&exported));
    assert!(!file_contains(&exported, CANARY.as_bytes()));
    assert_eq!(
        fs::metadata(&exported).unwrap().permissions().mode() & 0o777,
        0o600
    );
    // The export target must not exist beforehand.
    assert!(
        database::export_plaintext_to_encrypted(&plaintext, &exported, &primary)
            .await
            .is_err()
    );

    // PRAGMA rekey works on a WAL database; afterwards only the new key opens it.
    let rotated = key(0x22);
    let after = database::rekey_database_file(&exported, &primary, &rotated)
        .await
        .unwrap();
    assert_eq!(after, summary);
    assert_eq!(
        database::inspect_database_file(&exported, Some(&primary))
            .await
            .unwrap_err()
            .body
            .code,
        "DATABASE_KEY_INVALID"
    );
    assert_eq!(
        database::rekey_database_file(&exported, &rotated, &rotated)
            .await
            .unwrap_err()
            .body
            .code,
        "DATABASE_KEY_UNCHANGED"
    );

    // Key material is never formatted.
    assert_eq!(format!("{primary:?}"), "DatabaseKey(<redacted>)");
    let literal = primary.raw_key_literal();
    assert!(literal.starts_with("x'") && literal.ends_with('\'') && literal.len() == 67);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn database_key_file_must_be_private_regular_32_bytes_outside_data_dir() {
    let root = private_root();
    let data_dir = root.join("data");
    secure_file::create_private_data_dir(&data_dir).unwrap();
    let invalid = |path: &Path| {
        let error = DatabaseKey::read_file(path, &data_dir).unwrap_err();
        assert_eq!(error.body.code, "DATABASE_KEY_FILE_INVALID", "{path:?}");
        assert!(!error.body.message.contains(path.to_string_lossy().as_ref()));
    };

    let good = root.join("good.key");
    write_key(&good, 0x41);
    assert_eq!(DatabaseKey::read_file(&good, &data_dir).unwrap(), key(0x41));

    invalid(&root.join("missing.key"));

    let short = root.join("short.key");
    fs::write(&short, [1_u8; 31]).unwrap();
    fs::set_permissions(&short, fs::Permissions::from_mode(0o600)).unwrap();
    invalid(&short);

    let readable = root.join("group-readable.key");
    fs::write(&readable, [2_u8; 32]).unwrap();
    fs::set_permissions(&readable, fs::Permissions::from_mode(0o640)).unwrap();
    invalid(&readable);

    let link = root.join("link.key");
    symlink(&good, &link).unwrap();
    invalid(&link);

    let hard_link = root.join("hard-link.key");
    fs::hard_link(&good, &hard_link).unwrap();
    invalid(&hard_link);
    fs::remove_file(&hard_link).unwrap();

    let inside = data_dir.join("database.key");
    write_key(&inside, 0x42);
    invalid(&inside);
    // An alias of the data directory through a symlinked parent is inside too.
    let alias = root.join("data-alias");
    symlink(&data_dir, &alias).unwrap();
    invalid(&alias.join("database.key"));

    assert!(
        DatabaseKey::configured(&config(&data_dir, None))
            .unwrap()
            .is_none()
    );
    assert_eq!(
        code(DatabaseKey::configured(&config(&data_dir, Some(&short)))),
        "DATABASE_KEY_FILE_INVALID"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn startup_decision_table_matches_the_operator_contract() {
    let configured = key(0x10);
    let with_key = Some(&configured);
    assert_eq!(
        startup_database_encryption(DatabaseFileFormat::Absent, with_key).unwrap(),
        DatabaseEncryption::Enabled
    );
    assert_eq!(
        startup_database_encryption(DatabaseFileFormat::Encrypted, with_key).unwrap(),
        DatabaseEncryption::Enabled
    );
    assert_eq!(
        code(startup_database_encryption(
            DatabaseFileFormat::Plaintext,
            with_key
        )),
        "DATABASE_NOT_ENCRYPTED"
    );
    assert_eq!(
        code(startup_database_encryption(
            DatabaseFileFormat::Encrypted,
            None
        )),
        "DATABASE_KEY_REQUIRED"
    );
    assert_eq!(
        startup_database_encryption(DatabaseFileFormat::Absent, None).unwrap(),
        DatabaseEncryption::Disabled
    );
    assert_eq!(
        startup_database_encryption(DatabaseFileFormat::Plaintext, None).unwrap(),
        DatabaseEncryption::Disabled
    );
    assert_eq!(DatabaseEncryption::Enabled.as_str(), "enabled");
    assert_eq!(DatabaseEncryption::Disabled.as_str(), "disabled");
    let message = database::database_not_encrypted().body.message;
    assert!(message.contains("database-encrypt"));
}

#[tokio::test]
async fn encrypted_database_never_exposes_a_canary_in_raw_file_bytes() {
    let root = private_root();
    // Control: the canary is visible in a plaintext instance, so the raw-byte
    // search below can detect a leak.
    let plain_dir = root.join("plain");
    let plain = open(&plain_dir, None).await.unwrap();
    assert_eq!(plain.database_encryption, DatabaseEncryption::Disabled);
    insert_user(&plain, CANARY).await;
    checkpoint_and_close(plain).await;
    let plain_db = plain_dir.join("atermius.db");
    assert!(has_plaintext_header(&plain_db));
    assert!(file_contains(&plain_db, CANARY.as_bytes()));

    let key_file = root.join("database.key");
    write_key(&key_file, 0x5a);
    let data_dir = root.join("encrypted");
    let state = open(&data_dir, Some(&key_file)).await.unwrap();
    assert_eq!(state.database_encryption, DatabaseEncryption::Enabled);
    insert_user(&state, CANARY).await;
    let database = data_dir.join("atermius.db");
    let wal = data_dir.join("atermius.db-wal");
    // While the pool is open the committed row is still only in the WAL.
    assert!(wal.is_file(), "WAL mode keeps the new row in -wal");
    assert!(fs::metadata(&wal).unwrap().len() > 0);
    for path in regular_files(&data_dir) {
        assert!(
            !file_contains(&path, CANARY.as_bytes()),
            "canary leaked into {path:?}"
        );
    }
    assert!(!has_plaintext_header(&database));
    assert_eq!(
        detect_database_file(&database).unwrap(),
        DatabaseFileFormat::Encrypted
    );
    checkpoint_and_close(state).await;
    for path in regular_files(&data_dir) {
        assert!(
            !file_contains(&path, CANARY.as_bytes()),
            "canary leaked into {path:?} after checkpoint"
        );
    }
    // No database key material is stored in the data directory.
    let key_bytes = [0x5a_u8; 32];
    let key_hex = hex::encode(key_bytes);
    for path in regular_files(&data_dir) {
        assert!(!file_contains(&path, &key_bytes), "{path:?}");
        assert!(!file_contains(&path, key_hex.as_bytes()), "{path:?}");
    }

    let reopened = open(&data_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&reopened, CANARY).await);
    reopened.db.close().await;
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn startup_refuses_key_and_format_mismatches_before_migrations() {
    let root = private_root();
    let key_file = root.join("database.key");
    write_key(&key_file, 0x61);
    let wrong_key_file = root.join("wrong.key");
    write_key(&wrong_key_file, 0x62);

    // Plaintext database + configured key: refused without touching the file.
    let plain_dir = root.join("plain");
    let plain = open(&plain_dir, None).await.unwrap();
    insert_user(&plain, CANARY).await;
    checkpoint_and_close(plain).await;
    for sidecar in database::sqlite_sidecars(&plain_dir.join("atermius.db")) {
        let _ = fs::remove_file(sidecar);
    }
    let before = fs::read(plain_dir.join("atermius.db")).unwrap();
    let refused = open(&plain_dir, Some(&key_file)).await;
    let error = refused.err().unwrap();
    assert_eq!(error.body.code, "DATABASE_NOT_ENCRYPTED");
    assert!(error.body.message.contains("database-encrypt"));
    assert_eq!(fs::read(plain_dir.join("atermius.db")).unwrap(), before);
    assert!(!plain_dir.join("atermius.db-wal").exists());

    // Encrypted database without a key.
    let encrypted_dir = root.join("encrypted");
    let encrypted = open(&encrypted_dir, Some(&key_file)).await.unwrap();
    insert_user(&encrypted, CANARY).await;
    checkpoint_and_close(encrypted).await;
    assert_eq!(
        code(open(&encrypted_dir, None).await),
        "DATABASE_KEY_REQUIRED"
    );
    // Wrong key.
    assert_eq!(
        code(open(&encrypted_dir, Some(&wrong_key_file)).await),
        "DATABASE_KEY_INVALID"
    );
    // Configured but invalid key file.
    let unsafe_key = root.join("unsafe.key");
    fs::write(&unsafe_key, [0x63_u8; 32]).unwrap();
    fs::set_permissions(&unsafe_key, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(
        code(open(&encrypted_dir, Some(&unsafe_key)).await),
        "DATABASE_KEY_FILE_INVALID"
    );
    let inside_key = encrypted_dir.join("inside.key");
    write_key(&inside_key, 0x61);
    assert_eq!(
        code(open(&encrypted_dir, Some(&inside_key)).await),
        "DATABASE_KEY_FILE_INVALID"
    );
    fs::remove_file(&inside_key).unwrap();
    // A plaintext copy left by an interrupted database-encrypt blocks startup.
    let leftover = pre_encrypt_plaintext_copy(&encrypted_dir.join("atermius.db"));
    fs::write(&leftover, b"plaintext leftover").unwrap();
    assert_eq!(
        code(open(&encrypted_dir, Some(&key_file)).await),
        "DATABASE_ENCRYPTION_INCOMPLETE"
    );
    fs::remove_file(&leftover).unwrap();
    let state = open(&encrypted_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    state.db.close().await;
    fs::remove_dir_all(root).unwrap();
}

async fn seed_admin_session(state: &AppState, username: &str) -> String {
    let user_id = Uuid::new_v4().to_string();
    let device_id = Uuid::new_v4().to_string();
    let access = format!("dbenc-access-{}", Uuid::new_v4());
    let now = chrono::Utc::now();
    sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
        .bind(&user_id)
        .bind(username)
        .bind(now.to_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO devices(device_id,user_id,name,signing_public_key,encryption_public_key,created_at) VALUES(?,?,'dbenc','sign','encrypt',?)")
        .bind(&device_id)
        .bind(&user_id)
        .bind(now.to_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
    sqlx::query("INSERT INTO sessions(session_id,user_id,device_id,family_id,access_hash,refresh_hash,access_expires_at,refresh_expires_at,created_at) VALUES(?,?,?,'dbenc-family',?,?,?,?,?)")
        .bind(Uuid::new_v4().to_string())
        .bind(&user_id)
        .bind(&device_id)
        .bind(crate::sha256_hex(access.as_bytes()))
        .bind(format!("dbenc-refresh-{}", Uuid::new_v4()))
        .bind((now + chrono::Duration::minutes(10)).to_rfc3339())
        .bind((now + chrono::Duration::days(30)).to_rfc3339())
        .bind(now.to_rfc3339())
        .execute(&state.db)
        .await
        .unwrap();
    access
}

async fn overview_encryption(state: &AppState) -> serde_json::Value {
    let access = seed_admin_session(state, "dbenc-admin@example.test").await;
    let app = crate::router(state.clone()).await;
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/v1/admin/overview")
                .header(header::AUTHORIZATION, format!("Bearer {access}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: serde_json::Value = serde_json::from_slice(&body).unwrap();
    json["database_encryption"].clone()
}

#[tokio::test]
async fn admin_overview_reports_database_encryption_state() {
    let root = private_root();
    let plain = open(&root.join("plain"), None).await.unwrap();
    assert_eq!(overview_encryption(&plain).await, "disabled");
    plain.db.close().await;

    let key_file = root.join("database.key");
    write_key(&key_file, 0x71);
    let encrypted = open(&root.join("encrypted"), Some(&key_file))
        .await
        .unwrap();
    assert_eq!(overview_encryption(&encrypted).await, "enabled");
    encrypted.db.close().await;
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn database_key_generate_creates_private_key_and_refuses_unsafe_paths() {
    let root = private_root();
    let data_dir = root.join("data");
    // The data directory may not exist yet before the first start.
    let keys = root.join("keys");
    fs::create_dir(&keys).unwrap();
    fs::set_permissions(&keys, fs::Permissions::from_mode(0o700)).unwrap();
    let out = keys.join("database.key");
    generate_database_key_file(&data_dir, &out).unwrap();
    let metadata = fs::metadata(&out).unwrap();
    assert_eq!(metadata.len(), 32);
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    let first = fs::read(&out).unwrap();
    assert_ne!(first, vec![0_u8; 32]);
    // Never overwritten.
    assert_eq!(
        code(generate_database_key_file(&data_dir, &out)),
        "DATABASE_KEY_FILE_EXISTS"
    );
    assert_eq!(fs::read(&out).unwrap(), first);
    // A second key is different.
    let second = keys.join("database.next.key");
    generate_database_key_file(&data_dir, &second).unwrap();
    assert_ne!(fs::read(&second).unwrap(), first);

    secure_file::create_private_data_dir(&data_dir).unwrap();
    assert_eq!(
        code(generate_database_key_file(
            &data_dir,
            &data_dir.join("database.key")
        )),
        "INVALID_DATABASE_KEY_PATH"
    );
    assert!(!data_dir.join("database.key").exists());
    assert_eq!(
        code(generate_database_key_file(
            &data_dir,
            &root.join("missing-dir").join("database.key")
        )),
        "INVALID_DATABASE_KEY_PATH"
    );
    let shared = root.join("shared");
    fs::create_dir(&shared).unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o777)).unwrap();
    assert_eq!(
        code(generate_database_key_file(
            &data_dir,
            &shared.join("database.key")
        )),
        "INVALID_DATABASE_KEY_PATH"
    );
    // Review finding: a sticky shared directory like /tmp (1777) is refused
    // as well; the only key copy must not land in a shared, often volatile
    // location. Group-writable is refused with or without the sticky bit.
    for mode in [0o1777, 0o1770, 0o770] {
        let sticky = root.join(format!("shared-{mode:o}"));
        fs::create_dir(&sticky).unwrap();
        fs::set_permissions(&sticky, fs::Permissions::from_mode(mode)).unwrap();
        assert_eq!(
            code(generate_database_key_file(
                &data_dir,
                &sticky.join("database.key")
            )),
            "INVALID_DATABASE_KEY_PATH",
            "{mode:o}"
        );
        assert!(!sticky.join("database.key").exists());
    }
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn database_encrypt_round_trip_preserves_data_and_leaves_no_plaintext() {
    let root = private_root();
    let data_dir = root.join("data");
    let key_file = root.join("database.key");
    write_key(&key_file, 0x81);
    let state = open(&data_dir, None).await.unwrap();
    insert_user(&state, CANARY).await;
    for index in 0..25 {
        insert_user(&state, &format!("bulk-{index}@example.test")).await;
    }
    let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&state.db)
        .await
        .unwrap();
    let generation = state.instance.generation.clone();
    state.db.close().await;
    let url = database_url(&data_dir);

    // Requires the key and the stopped server.
    assert_eq!(
        code(encrypt_database_offline(&config(&data_dir, None), &url).await),
        "DATABASE_KEY_REQUIRED"
    );
    let running = crate::acquire_runtime_lock(&data_dir).unwrap();
    assert_eq!(
        code(encrypt_database_offline(&config(&data_dir, Some(&key_file)), &url).await),
        "SERVER_RUNNING"
    );
    drop(running);
    assert!(has_plaintext_header(&data_dir.join("atermius.db")));

    let summary = encrypt_database_offline(&config(&data_dir, Some(&key_file)), &url)
        .await
        .unwrap();
    assert!(!summary.resumed);
    assert!(summary.tables > 10);
    assert!(summary.rows >= users);

    let database = data_dir.join("atermius.db");
    assert!(!has_plaintext_header(&database));
    assert!(!pre_encrypt_plaintext_copy(&database).exists());
    for path in regular_files(&data_dir) {
        assert!(
            !file_contains(&path, CANARY.as_bytes()),
            "plaintext remains in {path:?}"
        );
        assert!(!has_plaintext_header(&path), "{path:?}");
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        assert!(
            !name.contains(".encrypt-") && !name.ends_with(".tmp"),
            "{name}"
        );
    }

    let encrypted = open(&data_dir, Some(&key_file)).await.unwrap();
    assert_eq!(encrypted.database_encryption, DatabaseEncryption::Enabled);
    assert_eq!(encrypted.instance.generation, generation);
    assert!(user_exists(&encrypted, CANARY).await);
    let after: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(&encrypted.db)
        .await
        .unwrap();
    assert_eq!(after, users);
    checkpoint_and_close(encrypted).await;

    assert_eq!(
        code(encrypt_database_offline(&config(&data_dir, Some(&key_file)), &url).await),
        "DATABASE_ALREADY_ENCRYPTED"
    );
    assert_eq!(code(open(&data_dir, None).await), "DATABASE_KEY_REQUIRED");
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn database_encrypt_finishes_an_interrupted_run() {
    let root = private_root();
    let key_file = root.join("database.key");
    write_key(&key_file, 0x91);

    // Interrupted before the replacement: only an extra hard link exists.
    let before_dir = root.join("before");
    let state = open(&before_dir, None).await.unwrap();
    insert_user(&state, CANARY).await;
    checkpoint_and_close(state).await;
    let database = before_dir.join("atermius.db");
    fs::hard_link(&database, pre_encrypt_plaintext_copy(&database)).unwrap();
    assert_eq!(
        code(open(&before_dir, None).await),
        "DATABASE_ENCRYPTION_INCOMPLETE"
    );
    let summary = encrypt_database_offline(
        &config(&before_dir, Some(&key_file)),
        &database_url(&before_dir),
    )
    .await
    .unwrap();
    assert!(!summary.resumed);
    assert!(!pre_encrypt_plaintext_copy(&database).exists());
    let state = open(&before_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    state.db.close().await;

    // Interrupted after the encrypted file was installed: the plaintext copy
    // must be removed by rerunning the command.
    let after_dir = root.join("after");
    let state = open(&after_dir, Some(&key_file)).await.unwrap();
    insert_user(&state, CANARY).await;
    checkpoint_and_close(state).await;
    let database = after_dir.join("atermius.db");
    fs::write(pre_encrypt_plaintext_copy(&database), CANARY).unwrap();
    assert_eq!(
        code(open(&after_dir, Some(&key_file)).await),
        "DATABASE_ENCRYPTION_INCOMPLETE"
    );
    let summary = encrypt_database_offline(
        &config(&after_dir, Some(&key_file)),
        &database_url(&after_dir),
    )
    .await
    .unwrap();
    assert!(summary.resumed);
    assert!(!pre_encrypt_plaintext_copy(&database).exists());
    let state = open(&after_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    state.db.close().await;
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn database_rekey_rotates_the_key_and_the_old_key_stops_working() {
    let root = private_root();
    let data_dir = root.join("data");
    let old_key = root.join("database.key");
    let new_key = root.join("database.next.key");
    write_key(&old_key, 0xa1);
    write_key(&new_key, 0xa2);
    let same_bytes = root.join("database.copy.key");
    write_key(&same_bytes, 0xa1);
    let url = database_url(&data_dir);

    let state = open(&data_dir, Some(&old_key)).await.unwrap();
    insert_user(&state, CANARY).await;
    state.db.close().await;

    let running = crate::acquire_runtime_lock(&data_dir).unwrap();
    assert_eq!(
        code(rekey_database_offline(&config(&data_dir, Some(&old_key)), &url, &new_key).await),
        "SERVER_RUNNING"
    );
    drop(running);
    assert_eq!(
        code(rekey_database_offline(&config(&data_dir, None), &url, &new_key).await),
        "DATABASE_KEY_REQUIRED"
    );
    assert_eq!(
        code(rekey_database_offline(&config(&data_dir, Some(&old_key)), &url, &old_key).await),
        "DATABASE_KEY_UNCHANGED"
    );
    assert_eq!(
        code(rekey_database_offline(&config(&data_dir, Some(&old_key)), &url, &same_bytes).await),
        "DATABASE_KEY_UNCHANGED"
    );
    assert_eq!(
        code(rekey_database_offline(&config(&data_dir, Some(&new_key)), &url, &old_key).await),
        "DATABASE_KEY_INVALID"
    );

    let summary = rekey_database_offline(&config(&data_dir, Some(&old_key)), &url, &new_key)
        .await
        .unwrap();
    assert!(summary.rows > 0);
    assert_eq!(
        code(open(&data_dir, Some(&old_key)).await),
        "DATABASE_KEY_INVALID"
    );
    for path in regular_files(&data_dir) {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        assert!(!name.contains(".rekey-"), "{name}");
        assert!(!file_contains(&path, CANARY.as_bytes()), "{path:?}");
    }
    let state = open(&data_dir, Some(&new_key)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    checkpoint_and_close(state).await;

    // A plaintext database cannot be rekeyed.
    let plain_dir = root.join("plain");
    let plain = open(&plain_dir, None).await.unwrap();
    checkpoint_and_close(plain).await;
    assert_eq!(
        code(
            rekey_database_offline(
                &config(&plain_dir, Some(&old_key)),
                &database_url(&plain_dir),
                &new_key
            )
            .await
        ),
        "DATABASE_NOT_ENCRYPTED"
    );
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn offline_mfa_rotation_and_object_migration_open_the_encrypted_database() {
    let root = private_root();
    let data_dir = root.join("data");
    let database_key = root.join("database.key");
    write_key(&database_key, 0xb1);
    let state = open(&data_dir, Some(&database_key)).await.unwrap();
    checkpoint_and_close(state).await;
    let url = database_url(&data_dir);
    let mfa_old = root.join("mfa-old.key");
    let mfa_new = root.join("mfa-new.key");
    write_key(&mfa_old, 0xb2);
    write_key(&mfa_new, 0xb3);

    assert_eq!(
        code(crate::rotate_mfa_seed_encryption_key(&data_dir, &url, &mfa_old, &mfa_new).await),
        "DATABASE_KEY_REQUIRED"
    );
    let summary = crate::rotate_mfa_seed_encryption_key_with_database_key(
        &data_dir,
        &url,
        Some(&database_key),
        &mfa_old,
        &mfa_new,
    )
    .await
    .unwrap();
    assert_eq!(summary.active_envelopes + summary.pending_envelopes, 0);

    assert_eq!(
        code(
            crate::run_object_store_migration(
                &config(&data_dir, None),
                &url,
                &Uuid::new_v4().to_string()
            )
            .await
        ),
        "DATABASE_KEY_REQUIRED"
    );
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn database_encrypt_removes_plaintext_snapshots_left_by_interrupted_backups() {
    let root = private_root();
    let data_dir = root.join("data");
    let key_file = root.join("database.key");
    write_key(&key_file, 0xc1);
    let state = open(&data_dir, None).await.unwrap();
    insert_user(&state, CANARY).await;
    let snapshot_dir = leave_interrupted_backup_snapshot(&state, &data_dir).await;
    checkpoint_and_close(state).await;
    let snapshot = snapshot_dir.join("database.sqlite");
    assert!(has_plaintext_header(&snapshot));
    assert!(file_contains(&snapshot, CANARY.as_bytes()));
    // Unrelated hidden entries are not touched.
    let unrelated = data_dir.join(".backup-snapshots-are-not-this");
    fs::write(&unrelated, b"keep").unwrap();

    let summary = encrypt_database_offline(
        &config(&data_dir, Some(&key_file)),
        &database_url(&data_dir),
    )
    .await
    .unwrap();
    assert_eq!(summary.removed_backup_snapshots, 1);
    assert!(!snapshot_dir.exists());
    assert_eq!(fs::read(&unrelated).unwrap(), b"keep");
    fs::remove_file(&unrelated).unwrap();
    // No file anywhere below the data directory is readable plaintext.
    for path in all_regular_files(&data_dir) {
        assert!(!has_plaintext_header(&path), "{path:?}");
        assert!(
            !file_contains(&path, CANARY.as_bytes()),
            "plaintext remains in {path:?}"
        );
    }
    let encrypted = open(&data_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&encrypted, CANARY).await);
    checkpoint_and_close(encrypted).await;

    // A rerun on the encrypted database still clears a leftover snapshot
    // before refusing.
    let stray = data_dir.join(format!(".backup-snapshot-{}", Uuid::new_v4()));
    fs::create_dir(&stray).unwrap();
    fs::write(stray.join("database.sqlite"), SQLITE_PLAINTEXT_HEADER).unwrap();
    assert_eq!(
        code(
            encrypt_database_offline(
                &config(&data_dir, Some(&key_file)),
                &database_url(&data_dir)
            )
            .await
        ),
        "DATABASE_ALREADY_ENCRYPTED"
    );
    assert!(!stray.exists());
    fs::remove_dir_all(root).unwrap();
}

#[tokio::test]
async fn database_rekey_removes_old_key_snapshots_and_reports_an_installed_unverified_copy() {
    let root = private_root();
    let data_dir = root.join("data");
    let old_key = root.join("database.key");
    let new_key = root.join("database.next.key");
    let newest_key = root.join("database.newest.key");
    write_key(&old_key, 0xd1);
    write_key(&new_key, 0xd2);
    write_key(&newest_key, 0xd3);
    let url = database_url(&data_dir);

    let state = open(&data_dir, Some(&old_key)).await.unwrap();
    insert_user(&state, CANARY).await;
    let snapshot_dir = leave_interrupted_backup_snapshot(&state, &data_dir).await;
    checkpoint_and_close(state).await;
    assert_eq!(
        detect_database_file(&snapshot_dir.join("database.sqlite")).unwrap(),
        DatabaseFileFormat::Encrypted
    );

    let summary = rekey_database_offline(&config(&data_dir, Some(&old_key)), &url, &new_key)
        .await
        .unwrap();
    assert_eq!(summary.removed_backup_snapshots, 1);
    assert!(!snapshot_dir.exists());

    // If the final check after the atomic replace fails, the error says the
    // live database is already under the new key (it is), never that
    // nothing was replaced.
    crate::database_encryption::tests::inject_installed_rekey_verification_failure();
    let error = rekey_database_offline(&config(&data_dir, Some(&new_key)), &url, &newest_key)
        .await
        .err()
        .expect("injected verification failure must be reported");
    assert_eq!(error.body.code, "DATABASE_REKEY_INSTALLED_UNVERIFIED");
    assert!(error.body.message.contains("NEW key"));
    assert!(!error.body.message.contains("nothing was replaced"));
    assert_eq!(
        code(open(&data_dir, Some(&new_key)).await),
        "DATABASE_KEY_INVALID"
    );
    let state = open(&data_dir, Some(&newest_key)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    checkpoint_and_close(state).await;
    for path in regular_files(&data_dir) {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        assert!(!name.contains(".rekey-"), "{name}");
    }
    fs::remove_dir_all(root).unwrap();
}

/// Review finding: the runbook's shell snippet for restoring a backed-up key
/// deleted an existing key file when `set -C` refused to overwrite it.
/// `database-key-import` replaces the snippet: it never replaces or removes
/// an existing file and creates nothing from invalid input.
#[test]
fn database_key_import_restores_a_backed_up_key_and_never_touches_an_existing_one() {
    use crate::database_encryption::import_database_key_file;
    use base64::Engine as _;
    use std::os::unix::fs::MetadataExt;

    let root = private_root();
    let data_dir = root.join("data");
    let keys = root.join("keys");
    fs::create_dir(&keys).unwrap();
    fs::set_permissions(&keys, fs::Permissions::from_mode(0o700)).unwrap();
    let original = keys.join("database.key");
    generate_database_key_file(&data_dir, &original).unwrap();
    let original_bytes = fs::read(&original).unwrap();
    // `base64 /keys/database.key` output: standard alphabet, padded, newline.
    let backup = format!(
        "{}\n",
        base64::engine::general_purpose::STANDARD.encode(&original_bytes)
    );

    // Onto a fresh keys directory: the same 32 bytes, private, and readable
    // through the server's own key validation.
    let fresh = root.join("fresh-keys");
    fs::create_dir(&fresh).unwrap();
    fs::set_permissions(&fresh, fs::Permissions::from_mode(0o700)).unwrap();
    let restored = fresh.join("database.key");
    import_database_key_file(&data_dir, &restored, &backup).unwrap();
    assert_eq!(fs::read(&restored).unwrap(), original_bytes);
    let metadata = fs::metadata(&restored).unwrap();
    assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    assert_eq!(metadata.nlink(), 1);
    // Wrapped or indented input is accepted.
    let wrapped = fresh.join("wrapped.key");
    let (head, tail) = backup.trim().split_at(20);
    import_database_key_file(&data_dir, &wrapped, &format!("  {head}\r\n{tail}\n\n")).unwrap();
    assert_eq!(fs::read(&wrapped).unwrap(), original_bytes);

    // An existing key is never replaced or removed, even by a different key.
    let other = format!(
        "{}\n",
        base64::engine::general_purpose::STANDARD.encode([0x5a_u8; 32])
    );
    assert_eq!(
        code(import_database_key_file(&data_dir, &original, &other)),
        "DATABASE_KEY_FILE_EXISTS"
    );
    assert_eq!(fs::read(&original).unwrap(), original_bytes);
    assert_eq!(
        code(import_database_key_file(&data_dir, &original, "not base64")),
        "INVALID_DATABASE_KEY"
    );
    assert_eq!(fs::read(&original).unwrap(), original_bytes);

    // Invalid input creates nothing.
    let refused = fresh.join("refused.key");
    for invalid in [
        String::new(),
        "%%%%".to_owned(),
        base64::engine::general_purpose::STANDARD.encode([1_u8; 31]),
        base64::engine::general_purpose::STANDARD.encode([1_u8; 33]),
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([0xfb_u8; 32]),
    ] {
        assert_eq!(
            code(import_database_key_file(&data_dir, &refused, &invalid)),
            "INVALID_DATABASE_KEY",
            "{invalid:?}"
        );
        assert!(fs::symlink_metadata(&refused).is_err());
    }
    // Same path rules as database-key-generate.
    secure_file::create_private_data_dir(&data_dir).unwrap();
    assert_eq!(
        code(import_database_key_file(
            &data_dir,
            &data_dir.join("database.key"),
            &backup
        )),
        "INVALID_DATABASE_KEY_PATH"
    );
    let shared = root.join("shared");
    fs::create_dir(&shared).unwrap();
    fs::set_permissions(&shared, fs::Permissions::from_mode(0o1777)).unwrap();
    assert_eq!(
        code(import_database_key_file(
            &data_dir,
            &shared.join("database.key"),
            &backup
        )),
        "INVALID_DATABASE_KEY_PATH"
    );
    assert!(!shared.join("database.key").exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn database_key_generate_reports_only_an_existing_path_as_exists() {
    use crate::database_encryption::key_file_create_error;
    use secure_file::NewPrivateKeyError;

    let exists = key_file_create_error(NewPrivateKeyError::AlreadyExists(std::io::Error::from(
        std::io::ErrorKind::AlreadyExists,
    )));
    assert_eq!(exists.body.code, "DATABASE_KEY_FILE_EXISTS");
    for failure in [
        std::io::ErrorKind::PermissionDenied,
        std::io::ErrorKind::ReadOnlyFilesystem,
        std::io::ErrorKind::StorageFull,
        std::io::ErrorKind::Other,
    ] {
        let error = key_file_create_error(NewPrivateKeyError::Failed(ApiError::internal(
            std::io::Error::from(failure),
        )));
        assert_eq!(error.body.code, "DATABASE_KEY_FILE_WRITE_FAILED");
        assert!(!error.body.message.contains("already exists"));
        assert!(!error.body.message.contains('/'));
    }

    // A real creation failure that is not "exists": procfs refuses new
    // files (ENOENT) even for root, so this is deterministic on Linux.
    #[cfg(target_os = "linux")]
    {
        let data_dir = std::env::temp_dir().join(format!("atermius-dbenc-{}", Uuid::new_v4()));
        let out = Path::new("/proc/self/atermius-database.key");
        assert_eq!(
            code(generate_database_key_file(&data_dir, out)),
            "DATABASE_KEY_FILE_WRITE_FAILED"
        );
    }
}

#[tokio::test]
async fn database_checkpoint_folds_a_left_over_wal_into_the_encrypted_database() {
    let root = private_root();
    let key_file = root.join("database.key");
    let other_key = root.join("database.other.key");
    write_key(&key_file, 0xe1);
    write_key(&other_key, 0xe2);

    // A server that stopped uncleanly leaves committed rows only in the
    // WAL. Capture such a crash image while the pool is still open.
    let live_dir = root.join("live");
    let state = open(&live_dir, Some(&key_file)).await.unwrap();
    sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
        .fetch_all(&state.db)
        .await
        .unwrap();
    insert_user(&state, CANARY).await;
    let data_dir = root.join("data");
    secure_file::create_private_data_dir(&data_dir).unwrap();
    for name in [
        "atermius.db",
        "atermius.db-wal",
        "instance-ed25519.key",
        "auth-rate-limit.key",
    ] {
        fs::copy(live_dir.join(name), data_dir.join(name)).unwrap();
    }
    state.db.close().await;
    let wal = data_dir.join("atermius.db-wal");
    assert!(fs::metadata(&wal).unwrap().len() > 0);
    assert!(!file_contains(&wal, CANARY.as_bytes()));
    let url = database_url(&data_dir);

    // Refusals: missing key, wrong key, running server.
    assert_eq!(
        code(checkpoint_database_offline(&config(&data_dir, None), &url).await),
        "DATABASE_KEY_REQUIRED"
    );
    assert_eq!(
        code(checkpoint_database_offline(&config(&data_dir, Some(&other_key)), &url).await),
        "DATABASE_KEY_INVALID"
    );
    let running = crate::acquire_runtime_lock(&data_dir).unwrap();
    assert_eq!(
        code(checkpoint_database_offline(&config(&data_dir, Some(&key_file)), &url).await),
        "SERVER_RUNNING"
    );
    drop(running);

    let summary = checkpoint_database_offline(&config(&data_dir, Some(&key_file)), &url)
        .await
        .unwrap();
    assert!(summary.encrypted);
    assert!(summary.rows > 0);
    for sidecar in database::sqlite_sidecars(&data_dir.join("atermius.db")) {
        assert!(!sidecar.exists(), "{sidecar:?}");
    }
    for path in regular_files(&data_dir) {
        assert!(!has_plaintext_header(&path), "{path:?}");
    }
    // The row that was only in the WAL is now in the main file.
    let state = open(&data_dir, Some(&key_file)).await.unwrap();
    assert!(user_exists(&state, CANARY).await);
    checkpoint_and_close(state).await;

    // Plaintext instances work without a key; a key on plaintext is refused.
    let plain_dir = root.join("plain");
    let plain = open(&plain_dir, None).await.unwrap();
    checkpoint_and_close(plain).await;
    let plain_url = database_url(&plain_dir);
    assert_eq!(
        code(checkpoint_database_offline(&config(&plain_dir, Some(&key_file)), &plain_url).await),
        "DATABASE_NOT_ENCRYPTED"
    );
    let summary = checkpoint_database_offline(&config(&plain_dir, None), &plain_url)
        .await
        .unwrap();
    assert!(!summary.encrypted);
    fs::remove_dir_all(root).unwrap();
}

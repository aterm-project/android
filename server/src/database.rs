//! Main application database URL selection and SQLCipher keying.
//!
//! The account, lifecycle, object, maintenance, and application stores remain
//! SQLite-backed. The separately configured restricted PostgreSQL sync-core
//! connection is opened by `pg_sync_runtime`; do not pass its URL through this
//! parser or mistake SQLx parser behavior for general PostgreSQL support.
//!
//! Every open of the main database, of a backup snapshot, or of a restore
//! stage goes through [`keyed_sqlite_options`] (directly or through
//! [`main_sqlite_options`] / [`sqlite_file_options`]). When an operator key is
//! configured the database is SQLCipher-encrypted with that raw 256-bit key;
//! without one it is a legacy plaintext SQLite file. The key is applied only
//! through SQLx's ordered `key` pragma (always executed before any other
//! pragma) and statement logging is disabled for keyed connections, so the key
//! never reaches logs. `SqliteConnectOptions`' `Debug` output contains pragma
//! values: never format keyed options.

use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::Read,
    path::{Path, PathBuf},
    str::FromStr,
};

use axum::http::StatusCode;
use rand::RngCore;
use sqlx::{
    ConnectOptions, Connection, Row, SqliteConnection, SqlitePool,
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
};
use zeroize::Zeroizing;

use crate::{ApiError, Config, secure_file};

/// The fixed main database file name inside `ATERMIUS_DATA_DIR`.
pub(crate) const MAIN_DATABASE_FILE: &str = "atermius.db";
/// Every plaintext SQLite 3 database starts with this header. A SQLCipher
/// file starts with a random salt instead (no plaintext header is kept).
pub(crate) const SQLITE_PLAINTEXT_HEADER: &[u8; 16] = b"SQLite format 3\0";
/// Backup-manifest identifier for a SQLCipher 4 snapshot keyed with a raw
/// 32-byte key (`PRAGMA key = "x'<hex>'"`, no passphrase KDF).
pub(crate) const SQLCIPHER_RAW_KEY_SCHEME: &str = "sqlcipher4-raw-key-v1";
/// SQLite primary result code for "file is not a database". SQLCipher returns
/// it when a key is missing, wrong, or applied to a plaintext file.
const SQLITE_NOTADB: &str = "26";

pub(crate) fn parse_sqlite_database_url(
    database_url: &str,
) -> Result<SqliteConnectOptions, ApiError> {
    let scheme = database_url.split_once(':').map(|(scheme, _)| scheme);
    if scheme != Some("sqlite") {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "UNSUPPORTED_DATABASE_BACKEND",
            "the main application database supports SQLite only",
        ));
    }

    SqliteConnectOptions::from_str(database_url).map_err(ApiError::internal)
}

/// An operator-held raw SQLCipher key. The bytes are zeroized on drop and
/// never formatted.
pub(crate) struct DatabaseKey {
    bytes: Zeroizing<[u8; 32]>,
}

impl std::fmt::Debug for DatabaseKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("DatabaseKey(<redacted>)")
    }
}

impl PartialEq for DatabaseKey {
    fn eq(&self, other: &Self) -> bool {
        // Not timing sensitive: only local offline tools compare keys.
        self.bytes.as_ref() == other.bytes.as_ref()
    }
}

impl Eq for DatabaseKey {}

impl DatabaseKey {
    pub(crate) fn generate() -> Self {
        let mut bytes = Zeroizing::new([0_u8; 32]);
        rand::rngs::OsRng.fill_bytes(bytes.as_mut());
        Self { bytes }
    }

    pub(crate) fn from_slice(bytes: &[u8]) -> Result<Self, ApiError> {
        if bytes.len() != 32 {
            return Err(ApiError::internal("database key must be 32 bytes"));
        }
        let mut key = Zeroizing::new([0_u8; 32]);
        key.copy_from_slice(bytes);
        Ok(Self { bytes: key })
    }

    /// Reads an owner-only, single-linked, regular 32-byte key file that does
    /// not live inside `data_dir`. Every failure is reported with the same
    /// fixed operator message and never includes file contents.
    pub(crate) fn read_file(path: &Path, data_dir: &Path) -> Result<Self, ApiError> {
        if !path_is_outside_directory(data_dir, path) {
            return Err(database_key_file_invalid());
        }
        let bytes = secure_file::read_private_key_zeroizing(path)
            .map_err(|_| database_key_file_invalid())?;
        Ok(Self { bytes })
    }

    /// Loads `ATERMIUS_DATABASE_KEY_FILE` for `config`. A configured but
    /// unusable file is an error; an unset value means encryption is off.
    pub(crate) fn configured(config: &Config) -> Result<Option<Self>, ApiError> {
        config
            .database_key_file
            .as_deref()
            .map(|path| Self::read_file(path, &config.data_dir))
            .transpose()
    }

    pub(crate) fn as_bytes(&self) -> &[u8; 32] {
        &self.bytes
    }

    /// `x'<64 lowercase hex>'`: SQLCipher's raw-key syntax, used for the bound
    /// `ATTACH ... KEY ?` parameter.
    pub(crate) fn raw_key_literal(&self) -> Zeroizing<String> {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        // Allocated once at its final size, so no reallocation leaves an
        // unzeroized partial copy behind.
        let mut literal = Zeroizing::new(String::with_capacity(3 + 2 * self.bytes.len()));
        literal.push_str("x'");
        for byte in self.bytes.iter() {
            literal.push(char::from(HEX[usize::from(byte >> 4)]));
            literal.push(char::from(HEX[usize::from(byte & 0x0f)]));
        }
        literal.push('\'');
        literal
    }

    /// The raw-key literal quoted as a `PRAGMA key`/`PRAGMA rekey` value.
    fn pragma_value(&self) -> Zeroizing<String> {
        let literal = self.raw_key_literal();
        let mut value = Zeroizing::new(String::with_capacity(literal.len() + 2));
        value.push('"');
        value.push_str(literal.as_str());
        value.push('"');
        value
    }
}

/// `PRAGMA rekey = "x'<hex>'"`, built directly into a zeroizing buffer (no
/// intermediate plain `String` from `format!`).
fn rekey_sql(new: &DatabaseKey) -> Zeroizing<String> {
    const PREFIX: &str = "PRAGMA rekey = ";
    let value = new.pragma_value();
    let mut sql = Zeroizing::new(String::with_capacity(PREFIX.len() + value.len()));
    sql.push_str(PREFIX);
    sql.push_str(value.as_str());
    sql
}

/// Applies the optional SQLCipher key to any SQLite connection options. SQLx
/// executes the `key` pragma first on every new connection. Keyed connections
/// never log statements, because SQLx would otherwise log the pragma batch
/// (at debug level, or at warn level when it is slow).
pub(crate) fn keyed_sqlite_options(
    options: SqliteConnectOptions,
    key: Option<&DatabaseKey>,
) -> SqliteConnectOptions {
    match key {
        Some(key) => {
            // SQLx keeps pragma values as owned strings for the lifetime of
            // the pool; SQLCipher keeps the derived key in memory as well.
            let value: String = key.pragma_value().as_str().to_owned();
            options.disable_statement_logging().pragma("key", value)
        }
        None => options,
    }
}

/// Parses the main database URL (SQLite only) and applies the optional key.
pub(crate) fn main_sqlite_options(
    database_url: &str,
    key: Option<&DatabaseKey>,
) -> Result<SqliteConnectOptions, ApiError> {
    Ok(keyed_sqlite_options(
        parse_sqlite_database_url(database_url)?,
        key,
    ))
}

/// Connection options for an existing database file (snapshot, stage, or
/// the main database opened read-only) with the optional key applied.
pub(crate) fn sqlite_file_options(path: &Path, key: Option<&DatabaseKey>) -> SqliteConnectOptions {
    keyed_sqlite_options(SqliteConnectOptions::new().filename(path), key)
}

/// On-disk format of a database path, determined without opening SQLite.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DatabaseFileFormat {
    /// No file, or a zero-length file that SQLite would initialize.
    Absent,
    /// Starts with the plaintext SQLite 3 header.
    Plaintext,
    /// Anything else: a SQLCipher database (or an unreadable/corrupt file).
    Encrypted,
}

pub(crate) fn detect_database_file(path: &Path) -> Result<DatabaseFileFormat, ApiError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(DatabaseFileFormat::Absent);
        }
        Err(error) => return Err(ApiError::internal(error)),
    };
    let metadata = file.metadata().map_err(ApiError::internal)?;
    if !metadata.file_type().is_file() {
        return Err(ApiError::internal("database path is not a regular file"));
    }
    if metadata.len() == 0 {
        return Ok(DatabaseFileFormat::Absent);
    }
    let mut header = [0_u8; 16];
    let mut read = 0;
    let mut reader = file;
    while read < header.len() {
        match reader
            .read(&mut header[read..])
            .map_err(ApiError::internal)?
        {
            0 => break,
            count => read += count,
        }
    }
    if read == header.len() && &header == SQLITE_PLAINTEXT_HEADER {
        Ok(DatabaseFileFormat::Plaintext)
    } else {
        Ok(DatabaseFileFormat::Encrypted)
    }
}

/// Name of the hard link that keeps the original plaintext database reachable
/// while `database-encrypt` replaces and re-verifies the live file.
pub(crate) fn pre_encrypt_plaintext_copy(database: &Path) -> PathBuf {
    let name = database
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| MAIN_DATABASE_FILE.to_owned());
    database.with_file_name(format!(".{name}.pre-encrypt-plaintext"))
}

/// Refuses to start while an interrupted `database-encrypt` left its
/// plaintext copy next to the database: the copy defeats encryption at rest.
pub(crate) fn reject_incomplete_encryption(database: &Path) -> Result<(), ApiError> {
    match std::fs::symlink_metadata(pre_encrypt_plaintext_copy(database)) {
        Ok(_) => Err(database_encryption_incomplete()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

pub(crate) fn database_encryption_incomplete() -> ApiError {
    ApiError::conflict(
        "DATABASE_ENCRYPTION_INCOMPLETE",
        "an interrupted `database-encrypt` left a plaintext copy in the data directory; stop the server and rerun `atermius-server database-encrypt` offline to finish",
    )
}

/// Whether the main database is encrypted at rest. Reported to instance
/// admins so the admin UI can warn about a plaintext deployment.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DatabaseEncryption {
    Enabled,
    Disabled,
}

impl DatabaseEncryption {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Enabled => "enabled",
            Self::Disabled => "disabled",
        }
    }
}

/// Startup decision table (run before SQLite opens the file or migrations
/// run). See `docs/runbooks/database-encryption.md`.
pub(crate) fn startup_database_encryption(
    format: DatabaseFileFormat,
    key: Option<&DatabaseKey>,
) -> Result<DatabaseEncryption, ApiError> {
    match (format, key.is_some()) {
        (DatabaseFileFormat::Plaintext, true) => Err(database_not_encrypted()),
        (DatabaseFileFormat::Encrypted, false) => Err(database_key_required()),
        (DatabaseFileFormat::Absent | DatabaseFileFormat::Encrypted, true) => {
            Ok(DatabaseEncryption::Enabled)
        }
        (DatabaseFileFormat::Absent | DatabaseFileFormat::Plaintext, false) => {
            Ok(DatabaseEncryption::Disabled)
        }
    }
}

/// With a key, an existing plaintext file is a configuration mismatch that
/// must be reported explicitly instead of as an unreadable database. Without a
/// key, callers keep their legacy error behavior.
pub(crate) fn require_keyed_format(path: &Path, key: Option<&DatabaseKey>) -> Result<(), ApiError> {
    if key.is_some() && detect_database_file(path)? == DatabaseFileFormat::Plaintext {
        return Err(database_not_encrypted());
    }
    Ok(())
}

/// Maps "file is not a database" on a keyed connection to
/// `DATABASE_KEY_INVALID`; all other failures stay opaque.
pub(crate) fn map_keyed_error(error: sqlx::Error, key: Option<&DatabaseKey>) -> ApiError {
    if key.is_some() && is_not_a_database(&error) {
        return database_key_invalid();
    }
    ApiError::internal(error)
}

pub(crate) fn is_not_a_database(error: &sqlx::Error) -> bool {
    matches!(error, sqlx::Error::Database(database) if database.code().as_deref() == Some(SQLITE_NOTADB))
}

/// SQLCipher accepts any key at `PRAGMA key` time; the first page read
/// decides. Force that read so a wrong key fails here, not in a later query.
pub(crate) async fn verify_keyed_pool(
    pool: &SqlitePool,
    key: Option<&DatabaseKey>,
) -> Result<(), ApiError> {
    if key.is_some() {
        require_cipher_support_pool(pool).await?;
    }
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM sqlite_master")
        .fetch_one(pool)
        .await
        .map(|_| ())
        .map_err(|error| map_keyed_error(error, key))
}

/// Opens a keyed pool on an existing file and verifies the key. Use for
/// snapshots, restore stages, and offline tools.
pub(crate) async fn connect_keyed_pool(
    options: SqliteConnectOptions,
    key: Option<&DatabaseKey>,
    max_connections: u32,
) -> Result<SqlitePool, ApiError> {
    require_keyed_format(options.get_filename(), key)?;
    let pool = SqlitePoolOptions::new()
        .max_connections(max_connections)
        .connect_with(options)
        .await
        .map_err(|error| map_keyed_error(error, key))?;
    if let Err(error) = verify_keyed_pool(&pool, key).await {
        pool.close().await;
        return Err(error);
    }
    Ok(pool)
}

async fn connect_keyed_connection(
    options: SqliteConnectOptions,
    key: Option<&DatabaseKey>,
) -> Result<SqliteConnection, ApiError> {
    let mut connection = options
        .connect()
        .await
        .map_err(|error| map_keyed_error(error, key))?;
    if key.is_some() {
        let version: Option<String> = sqlx::query_scalar("PRAGMA cipher_version")
            .fetch_optional(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        if version.as_deref().is_none_or(str::is_empty) {
            return Err(database_encryption_unavailable());
        }
    }
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM sqlite_master")
        .fetch_one(&mut connection)
        .await
        .map_err(|error| map_keyed_error(error, key))?;
    Ok(connection)
}

/// Fails closed unless this build links SQLCipher (`PRAGMA cipher_version`
/// returns a version string).
pub(crate) async fn require_cipher_support_pool(pool: &SqlitePool) -> Result<(), ApiError> {
    let version: Option<String> = sqlx::query_scalar("PRAGMA cipher_version")
        .fetch_optional(pool)
        .await
        .map_err(ApiError::internal)?;
    if version.as_deref().is_none_or(str::is_empty) {
        return Err(database_encryption_unavailable());
    }
    Ok(())
}

/// Logical content fingerprint used to prove an encryption/rekey copy is
/// complete: per-table row counts plus `user_version`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DatabaseContentSummary {
    pub(crate) table_rows: BTreeMap<String, i64>,
    pub(crate) user_version: i64,
}

impl DatabaseContentSummary {
    pub(crate) fn total_rows(&self) -> i64 {
        self.table_rows.values().sum()
    }
}

async fn content_summary(
    connection: &mut SqliteConnection,
) -> Result<DatabaseContentSummary, ApiError> {
    let names: Vec<String> = sqlx::query_scalar(
        "SELECT name FROM main.sqlite_master \
         WHERE type='table' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name",
    )
    .fetch_all(&mut *connection)
    .await
    .map_err(ApiError::internal)?;
    let mut table_rows = BTreeMap::new();
    for name in names {
        let quoted = name.replace('"', "\"\"");
        let count: i64 = sqlx::query_scalar(&format!("SELECT COUNT(*) FROM main.\"{quoted}\""))
            .fetch_one(&mut *connection)
            .await
            .map_err(ApiError::internal)?;
        table_rows.insert(name, count);
    }
    let user_version: i64 = sqlx::query_scalar("PRAGMA main.user_version")
        .fetch_one(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    Ok(DatabaseContentSummary {
        table_rows,
        user_version,
    })
}

async fn require_integrity(connection: &mut SqliteConnection) -> Result<(), ApiError> {
    let integrity: String = sqlx::query_scalar("PRAGMA main.integrity_check")
        .fetch_one(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    if integrity != "ok" {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "DATABASE_INTEGRITY_FAILED",
            "the database failed SQLite integrity_check; nothing was changed",
        ));
    }
    Ok(())
}

async fn checkpoint_truncate(connection: &mut SqliteConnection) -> Result<(), ApiError> {
    let row = sqlx::query("PRAGMA main.wal_checkpoint(TRUNCATE)")
        .fetch_one(&mut *connection)
        .await
        .map_err(ApiError::internal)?;
    let busy: i64 = row.try_get(0).map_err(ApiError::internal)?;
    if busy != 0 {
        return Err(ApiError::conflict(
            "DATABASE_BUSY",
            "the database WAL could not be fully checkpointed; stop every process using it",
        ));
    }
    Ok(())
}

/// Opens `path` (optionally keyed) on one connection, checkpoints its WAL,
/// verifies integrity, and returns its content summary. The file is fully
/// closed (and its WAL removed) on return.
pub(crate) async fn inspect_database_file(
    path: &Path,
    key: Option<&DatabaseKey>,
) -> Result<DatabaseContentSummary, ApiError> {
    require_keyed_format(path, key)?;
    let options = sqlite_file_options(path, key).create_if_missing(false);
    let mut connection = connect_keyed_connection(options, key).await?;
    let result = async {
        checkpoint_truncate(&mut connection).await?;
        require_integrity(&mut connection).await?;
        content_summary(&mut connection).await
    }
    .await;
    let closed = connection.close().await.map_err(ApiError::internal);
    let summary = result?;
    closed?;
    Ok(summary)
}

/// Copies a plaintext SQLite database into a new SQLCipher file with
/// `ATTACH ... KEY` + `sqlcipher_export` (which does not copy `user_version`,
/// so it is copied explicitly) and verifies the copy. The target must not
/// exist; it is created mode 0600 before SQLite writes to it. Returns the
/// verified summary. The plaintext source is not modified.
pub(crate) async fn export_plaintext_to_encrypted(
    source: &Path,
    target: &Path,
    key: &DatabaseKey,
) -> Result<DatabaseContentSummary, ApiError> {
    if detect_database_file(source)? != DatabaseFileFormat::Plaintext {
        return Err(ApiError::internal(
            "plaintext export source is not a plaintext SQLite database",
        ));
    }
    let expected = inspect_database_file(source, None).await?;
    create_empty_private_file(target)?;
    let result = async {
        let options = sqlite_file_options(source, None)
            .create_if_missing(false)
            // The source connection must not log the bound ATTACH key.
            .disable_statement_logging();
        let mut connection = connect_keyed_connection(options, None).await?;
        let exported = async {
            let attach_key = key.raw_key_literal();
            sqlx::query("ATTACH DATABASE ? AS atermius_encrypted KEY ?")
                .bind(target.to_string_lossy().into_owned())
                .bind(attach_key.as_str())
                .execute(&mut connection)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query("SELECT sqlcipher_export('atermius_encrypted')")
                .fetch_all(&mut connection)
                .await
                .map_err(ApiError::internal)?;
            sqlx::query(&format!(
                "PRAGMA atermius_encrypted.user_version = {}",
                expected.user_version
            ))
            .execute(&mut connection)
            .await
            .map_err(ApiError::internal)?;
            sqlx::query("DETACH DATABASE atermius_encrypted")
                .execute(&mut connection)
                .await
                .map_err(ApiError::internal)?;
            Ok::<_, ApiError>(())
        }
        .await;
        let closed = connection.close().await.map_err(ApiError::internal);
        exported?;
        closed?;
        if detect_database_file(target)? != DatabaseFileFormat::Encrypted {
            return Err(ApiError::internal(
                "encrypted export produced a plaintext file",
            ));
        }
        let actual = inspect_database_file(target, Some(key)).await?;
        if actual != expected {
            return Err(ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                "DATABASE_ENCRYPTION_VERIFY_FAILED",
                "the encrypted copy does not match the source row counts; nothing was replaced",
            ));
        }
        sync_file(target)?;
        Ok(actual)
    }
    .await;
    if result.is_err() {
        let _ = remove_database_files(target);
    }
    result
}

/// Re-encrypts `path` from `old` to `new` with `PRAGMA rekey` and verifies the
/// result: the new key opens it with identical content and the old key no
/// longer does. Callers run this only on a private copy or restore stage, so
/// an interruption never leaves the live database half rekeyed.
pub(crate) async fn rekey_database_file(
    path: &Path,
    old: &DatabaseKey,
    new: &DatabaseKey,
) -> Result<DatabaseContentSummary, ApiError> {
    if old == new {
        return Err(ApiError::bad_request(
            "DATABASE_KEY_UNCHANGED",
            "the new database key must differ from the current key",
        ));
    }
    let expected = inspect_database_file(path, Some(old)).await?;
    let options = sqlite_file_options(path, Some(old)).create_if_missing(false);
    let mut connection = connect_keyed_connection(options, Some(old)).await?;
    let rekeyed = async {
        // PRAGMA takes no bound parameters, so the key is part of the SQL
        // text. Keep our copy zeroizing and do not cache the statement: a
        // persistent statement would keep the SQL text as a statement-cache
        // key for the connection's lifetime. sqlx's per-execution copy of
        // the SQL and SQLite's prepared-statement text are freed (not
        // zeroized) as soon as the statement finishes.
        let sql = rekey_sql(new);
        sqlx::query(sql.as_str())
            .persistent(false)
            .execute(&mut connection)
            .await
            .map_err(ApiError::internal)?;
        drop(sql);
        checkpoint_truncate(&mut connection).await
    }
    .await;
    let closed = connection.close().await.map_err(ApiError::internal);
    rekeyed?;
    closed?;
    let actual = inspect_database_file(path, Some(new)).await?;
    if actual != expected {
        return Err(ApiError::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "DATABASE_REKEY_VERIFY_FAILED",
            "the rekeyed database does not match its previous row counts",
        ));
    }
    match connect_keyed_connection(sqlite_file_options(path, Some(old)), Some(old)).await {
        Err(error) if error.body.code == "DATABASE_KEY_INVALID" => {}
        Ok(connection) => {
            let _ = connection.close().await;
            return Err(ApiError::internal(
                "the previous database key still opens the database",
            ));
        }
        Err(error) => return Err(error),
    }
    sync_file(path)?;
    Ok(actual)
}

fn create_empty_private_file(path: &Path) -> Result<(), ApiError> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
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
    Ok(())
}

pub(crate) fn sync_file(path: &Path) -> Result<(), ApiError> {
    File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(ApiError::internal)
}

/// `-wal`, `-shm` and `-journal` sidecar paths for a database file.
pub(crate) fn sqlite_sidecars(path: &Path) -> [PathBuf; 3] {
    let path = path.as_os_str().to_string_lossy();
    [
        PathBuf::from(format!("{path}-wal")),
        PathBuf::from(format!("{path}-shm")),
        PathBuf::from(format!("{path}-journal")),
    ]
}

pub(crate) fn remove_sqlite_sidecars(path: &Path) -> Result<(), ApiError> {
    for sidecar in sqlite_sidecars(path) {
        match std::fs::remove_file(&sidecar) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Ok(())
}

fn remove_database_files(path: &Path) -> Result<(), ApiError> {
    remove_sqlite_sidecars(path)?;
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

/// True when `path` (resolved through its existing parent) is not inside
/// `directory`. A missing `directory` is compared lexically after making it
/// absolute so a key can be generated before the data directory exists.
pub(crate) fn path_is_outside_directory(directory: &Path, path: &Path) -> bool {
    let Some(directory) = resolve_existing_or_absolute(directory) else {
        return false;
    };
    let Some(file_name) = path.file_name() else {
        return false;
    };
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let Ok(parent) = std::fs::canonicalize(parent) else {
        return false;
    };
    !parent.join(file_name).starts_with(&directory)
}

fn resolve_existing_or_absolute(path: &Path) -> Option<PathBuf> {
    match std::fs::canonicalize(path) {
        Ok(path) => Some(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            // Resolve the deepest existing ancestor so a symlinked parent of a
            // not-yet-created data directory is still compared canonically.
            let absolute = std::path::absolute(path).ok()?;
            let mut existing = absolute.as_path();
            let mut rest = Vec::new();
            loop {
                match std::fs::canonicalize(existing) {
                    Ok(canonical) => {
                        let mut resolved = canonical;
                        for component in rest.iter().rev() {
                            resolved.push(component);
                        }
                        return Some(resolved);
                    }
                    Err(_) => {
                        rest.push(existing.file_name()?.to_owned());
                        existing = existing.parent()?;
                    }
                }
            }
        }
        Err(_) => None,
    }
}

pub(crate) fn database_not_encrypted() -> ApiError {
    ApiError::conflict(
        "DATABASE_NOT_ENCRYPTED",
        "ATERMIUS_DATABASE_KEY_FILE is configured but the instance database is plaintext; stop the server and run `atermius-server database-encrypt` offline, or remove the key setting",
    )
}

pub(crate) fn database_key_required() -> ApiError {
    ApiError::conflict(
        "DATABASE_KEY_REQUIRED",
        "the database is encrypted; configure ATERMIUS_DATABASE_KEY_FILE with its key",
    )
}

pub(crate) fn database_key_invalid() -> ApiError {
    ApiError::conflict(
        "DATABASE_KEY_INVALID",
        "the configured database key does not open this database",
    )
}

pub(crate) fn database_key_file_invalid() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "DATABASE_KEY_FILE_INVALID",
        "the database key file must be an existing owner-only, single-linked, regular 32-byte file outside ATERMIUS_DATA_DIR",
    )
}

pub(crate) fn database_encryption_unavailable() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "DATABASE_ENCRYPTION_UNAVAILABLE",
        "this server build does not include SQLCipher database encryption",
    )
}

#[cfg(test)]
mod tests {
    use super::parse_sqlite_database_url;
    use crate::{Config, open_state};

    #[test]
    fn main_database_accepts_sqlite_and_rejects_other_backends_without_echoing_urls() {
        for url in [
            "sqlite::memory:",
            "sqlite:///var/lib/atermius/atermius.db?mode=rwc",
        ] {
            assert!(parse_sqlite_database_url(url).is_ok(), "{url}");
        }

        for url in [
            "postgres://operator:do-not-log@db.example/vault",
            "postgresql://operator:do-not-log@db.example/vault",
            "mysql://operator:do-not-log@db.example/vault",
        ] {
            let error = parse_sqlite_database_url(url).unwrap_err();
            assert_eq!(error.body.code, "UNSUPPORTED_DATABASE_BACKEND");
            assert_eq!(
                error.body.message,
                "the main application database supports SQLite only"
            );
            assert!(!error.to_string().contains("do-not-log"));
        }
    }

    #[test]
    fn raw_key_literal_and_rekey_sql_use_sqlcipher_raw_key_syntax() {
        let bytes: Vec<u8> = (0_u8..32)
            .map(|index| index.wrapping_mul(37) ^ 0xa5)
            .collect();
        let key = super::DatabaseKey::from_slice(&bytes).unwrap();
        let expected = format!("x'{}'", hex::encode(&bytes));
        let literal = key.raw_key_literal();
        assert_eq!(literal.as_str(), expected);
        // Built at its final size: no reallocation left a stray copy.
        assert_eq!(literal.capacity(), literal.len());
        let sql = super::rekey_sql(&key);
        assert_eq!(sql.as_str(), format!("PRAGMA rekey = \"{expected}\""));
        assert_eq!(sql.capacity(), sql.len());
        assert_eq!(format!("{key:?}"), "DatabaseKey(<redacted>)");
    }

    #[tokio::test]
    async fn open_state_rejects_postgresql_before_creating_data_directory() {
        let data_dir =
            std::env::temp_dir().join(format!("atermius-unsupported-db-{}", uuid::Uuid::new_v4()));
        let mut config = Config::from_env();
        config.data_dir = data_dir.clone();

        let error = match open_state(
            "postgresql://operator:do-not-log@127.0.0.1/atermius",
            config,
        )
        .await
        {
            Ok(_) => panic!("PostgreSQL URL unexpectedly opened a server state"),
            Err(error) => error,
        };

        assert_eq!(error.body.code, "UNSUPPORTED_DATABASE_BACKEND");
        assert!(!error.to_string().contains("do-not-log"));
        assert!(!data_dir.exists());
    }
}

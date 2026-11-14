//! Offline operator commands for SQLCipher encryption at rest of the main
//! SQLite database: key generation, encrypting an existing plaintext
//! database, key rotation, and a keyed offline checkpoint. The database
//! commands hold the server runtime lock and the maintenance lock (like
//! `restore` and `rotate-mfa-key`). Encrypt and rekey work on a private copy
//! inside the data directory, verify it, and only then atomically replace
//! `atermius.db`.

use std::{
    fs,
    path::{Path, PathBuf},
};

use axum::http::StatusCode;
use uuid::Uuid;

use crate::{
    ApiError, Config, acquire_maintenance_run_lock, acquire_runtime_lock, backup,
    database::{
        self, DatabaseEncryption, DatabaseFileFormat, DatabaseKey, MAIN_DATABASE_FILE,
        detect_database_file, inspect_database_file, pre_encrypt_plaintext_copy,
        remove_sqlite_sidecars, sqlite_sidecars,
    },
    secure_file,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseEncryptSummary {
    pub tables: usize,
    pub rows: i64,
    /// True when this run only finished an interrupted earlier run whose
    /// encrypted database had already been installed.
    pub resumed: bool,
    /// Leftover `.backup-snapshot-*` entries of killed backup runs that were
    /// removed from the data directory (they may hold plaintext snapshots).
    pub removed_backup_snapshots: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseRekeySummary {
    pub tables: usize,
    pub rows: i64,
    /// Leftover `.backup-snapshot-*` entries (snapshots under the old key)
    /// that were removed from the data directory.
    pub removed_backup_snapshots: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseCheckpointSummary {
    pub tables: usize,
    pub rows: i64,
    pub encrypted: bool,
}

/// Creates a new random 32-byte database key file with mode 0600. Refuses to
/// overwrite an existing path and refuses any path inside `data_dir`.
pub fn generate_database_key_file(data_dir: &Path, out: &Path) -> Result<(), ApiError> {
    write_new_database_key_file(data_dir, out, &DatabaseKey::generate())
}

/// Restores a backed-up database key: `encoded` is the standard base64 of
/// the 32 raw key bytes (as `base64 /keys/database.key` prints it; line
/// breaks and surrounding whitespace are ignored). The file is created with
/// the same rules as [`generate_database_key_file`]: mode 0600, outside
/// `data_dir`, in a directory that is not group/world-writable, and an
/// existing path is never replaced or removed.
pub fn import_database_key_file(
    data_dir: &Path,
    out: &Path,
    encoded: &str,
) -> Result<(), ApiError> {
    use base64::Engine as _;
    let compact = zeroize::Zeroizing::new(
        encoded
            .chars()
            .filter(|character| !character.is_ascii_whitespace())
            .collect::<String>(),
    );
    let bytes = zeroize::Zeroizing::new(
        base64::engine::general_purpose::STANDARD
            .decode(compact.as_bytes())
            .map_err(|_| invalid_database_key_import())?,
    );
    if bytes.len() != 32 {
        return Err(invalid_database_key_import());
    }
    let key = DatabaseKey::from_slice(&bytes)?;
    write_new_database_key_file(data_dir, out, &key)
}

fn invalid_database_key_import() -> ApiError {
    ApiError::bad_request(
        "INVALID_DATABASE_KEY",
        "standard input must be the base64 encoding of exactly 32 key bytes",
    )
}

fn write_new_database_key_file(
    data_dir: &Path,
    out: &Path,
    key: &DatabaseKey,
) -> Result<(), ApiError> {
    if !database::path_is_outside_directory(data_dir, out) {
        return Err(ApiError::bad_request(
            "INVALID_DATABASE_KEY_PATH",
            "the database key file must be outside ATERMIUS_DATA_DIR, in an existing directory",
        ));
    }
    let parent = out
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    validate_key_directory(parent)?;
    match fs::symlink_metadata(out) {
        Ok(_) => return Err(database_key_file_exists()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(database_key_file_write_failed()),
    }
    secure_file::create_new_private_key(out, key.as_bytes()).map_err(key_file_create_error)?;
    // Read it back through the exact validation the server uses.
    let reread = DatabaseKey::read_file(out, data_dir)?;
    if &reread != key {
        return Err(ApiError::internal("database key file verification failed"));
    }
    Ok(())
}

/// Only an existing path is reported as `DATABASE_KEY_FILE_EXISTS`; every
/// other creation failure (unwritable, read-only or full key directory, fsync
/// failure) gets its own code. Neither message includes the path.
pub(crate) fn key_file_create_error(error: secure_file::NewPrivateKeyError) -> ApiError {
    match error {
        secure_file::NewPrivateKeyError::AlreadyExists(_) => database_key_file_exists(),
        secure_file::NewPrivateKeyError::Failed(_) => database_key_file_write_failed(),
    }
}

fn database_key_file_exists() -> ApiError {
    ApiError::conflict(
        "DATABASE_KEY_FILE_EXISTS",
        "the database key file already exists; it was not changed",
    )
}

fn database_key_file_write_failed() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "DATABASE_KEY_FILE_WRITE_FAILED",
        "the database key file could not be created; check that the key directory is writable by the service user and has free space",
    )
}

fn validate_key_directory(parent: &Path) -> Result<(), ApiError> {
    let metadata = fs::metadata(parent).map_err(|_| {
        ApiError::bad_request(
            "INVALID_DATABASE_KEY_PATH",
            "the database key directory must already exist",
        )
    })?;
    if !metadata.is_dir() {
        return Err(ApiError::bad_request(
            "INVALID_DATABASE_KEY_PATH",
            "the database key directory must be a directory",
        ));
    }
    // Unlike data-directory ancestors, a sticky shared directory such as
    // `/tmp` is refused too: the only copy of the key must not land in a
    // shared (and often volatile) location.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o022 != 0 {
            return Err(ApiError::bad_request(
                "INVALID_DATABASE_KEY_PATH",
                "the database key directory must not be group/world-writable",
            ));
        }
    }
    Ok(())
}

/// Encrypts an existing plaintext `ATERMIUS_DATA_DIR/atermius.db` in place
/// with the key named by `ATERMIUS_DATABASE_KEY_FILE`. Offline only.
pub async fn encrypt_database_offline(
    config: &Config,
    database_url: &str,
) -> Result<DatabaseEncryptSummary, ApiError> {
    let database = prepare_offline_database_command(config, database_url)?;
    let _runtime_lock = acquire_runtime_lock(&config.data_dir)?;
    let _maintenance_lock = acquire_maintenance_run_lock(&config.data_dir)?;
    let key = DatabaseKey::configured(config)?.ok_or_else(|| {
        ApiError::conflict(
            "DATABASE_KEY_REQUIRED",
            "database-encrypt requires ATERMIUS_DATABASE_KEY_FILE; create one with `atermius-server database-key-generate --out <path outside the data directory>`",
        )
    })?;
    require_regular_database_file(&database)?;
    remove_stale_temporaries(&config.data_dir)?;
    // A backup killed before encryption may have left a complete plaintext
    // snapshot directory beside the database. Both locks are held, so no
    // backup can be using one.
    let removed_backup_snapshots = backup::remove_stale_backup_snapshots(&config.data_dir)?;

    let plaintext_copy = pre_encrypt_plaintext_copy(&database);
    if fs::symlink_metadata(&plaintext_copy).is_ok() {
        match detect_database_file(&database)? {
            DatabaseFileFormat::Encrypted => {
                // Interrupted after the encrypted file was installed: verify
                // it with the configured key, then drop the plaintext copy.
                let summary = inspect_database_file(&database, Some(&key)).await?;
                remove_private_path(&plaintext_copy)?;
                sync_directory(&config.data_dir)?;
                return Ok(DatabaseEncryptSummary {
                    tables: summary.table_rows.len(),
                    rows: summary.total_rows(),
                    resumed: true,
                    removed_backup_snapshots,
                });
            }
            DatabaseFileFormat::Plaintext if same_file(&database, &plaintext_copy)? => {
                // Interrupted before the replacement: the copy is only a
                // second link to the untouched plaintext database.
                remove_private_path(&plaintext_copy)?;
                sync_directory(&config.data_dir)?;
            }
            _ => {
                return Err(ApiError::conflict(
                    "DATABASE_ENCRYPTION_INCOMPLETE",
                    "an interrupted database-encrypt left an unexpected plaintext copy; inspect the data directory before retrying",
                ));
            }
        }
    }

    match detect_database_file(&database)? {
        DatabaseFileFormat::Plaintext => {}
        DatabaseFileFormat::Encrypted => {
            return Err(ApiError::conflict(
                "DATABASE_ALREADY_ENCRYPTED",
                "the instance database is already encrypted",
            ));
        }
        DatabaseFileFormat::Absent => return Err(database_missing()),
    }

    let temporary = TemporaryDatabase::new(&config.data_dir, "encrypt");
    let expected =
        database::export_plaintext_to_encrypted(&database, &temporary.path, &key).await?;
    // The plaintext database was checkpointed and fully closed by the export,
    // so any remaining sidecar is stale plaintext and must not be applied to
    // (or left beside) the encrypted replacement.
    remove_sqlite_sidecars(&database)?;
    remove_sqlite_sidecars(&temporary.path)?;

    // Keep the plaintext original reachable until the installed encrypted
    // file has been verified at its final path.
    fs::hard_link(&database, &plaintext_copy).map_err(ApiError::internal)?;
    sync_directory(&config.data_dir)?;
    fs::rename(&temporary.path, &database).map_err(ApiError::internal)?;
    temporary.disarm();
    sync_directory(&config.data_dir)?;

    match inspect_database_file(&database, Some(&key)).await {
        Ok(actual) if actual == expected => {}
        result => {
            let _ = remove_sqlite_sidecars(&database);
            fs::rename(&plaintext_copy, &database).map_err(ApiError::internal)?;
            sync_directory(&config.data_dir)?;
            return Err(match result {
                Err(error) => error,
                Ok(_) => ApiError::conflict(
                    "DATABASE_ENCRYPTION_VERIFY_FAILED",
                    "the installed encrypted database did not verify; the plaintext database was put back",
                ),
            });
        }
    }
    remove_sqlite_sidecars(&database)?;
    remove_private_path(&plaintext_copy)?;
    sync_directory(&config.data_dir)?;
    Ok(DatabaseEncryptSummary {
        tables: expected.table_rows.len(),
        rows: expected.total_rows(),
        resumed: false,
        removed_backup_snapshots,
    })
}

/// Re-encrypts the encrypted main database from the configured key to the
/// key in `new_key_file` (`PRAGMA rekey` on a verified private copy, then an
/// atomic replace). The operator must point `ATERMIUS_DATABASE_KEY_FILE` at
/// the new key before restarting the server.
pub async fn rekey_database_offline(
    config: &Config,
    database_url: &str,
    new_key_file: &Path,
) -> Result<DatabaseRekeySummary, ApiError> {
    let database = prepare_offline_database_command(config, database_url)?;
    let _runtime_lock = acquire_runtime_lock(&config.data_dir)?;
    let _maintenance_lock = acquire_maintenance_run_lock(&config.data_dir)?;
    let current = DatabaseKey::configured(config)?.ok_or_else(|| {
        ApiError::conflict(
            "DATABASE_KEY_REQUIRED",
            "database-rekey requires the current key in ATERMIUS_DATABASE_KEY_FILE",
        )
    })?;
    if config.database_key_file.as_deref() == Some(new_key_file) {
        return Err(ApiError::bad_request(
            "DATABASE_KEY_UNCHANGED",
            "the new database key file must differ from ATERMIUS_DATABASE_KEY_FILE",
        ));
    }
    let new = DatabaseKey::read_file(new_key_file, &config.data_dir)?;
    if new == current {
        return Err(ApiError::bad_request(
            "DATABASE_KEY_UNCHANGED",
            "the new database key must differ from the current key",
        ));
    }
    require_regular_database_file(&database)?;
    database::reject_incomplete_encryption(&database)?;
    match detect_database_file(&database)? {
        DatabaseFileFormat::Encrypted => {}
        DatabaseFileFormat::Plaintext => return Err(database::database_not_encrypted()),
        DatabaseFileFormat::Absent => return Err(database_missing()),
    }
    remove_stale_temporaries(&config.data_dir)?;
    // Snapshots of killed backup runs are under the key being retired.
    let removed_backup_snapshots = backup::remove_stale_backup_snapshots(&config.data_dir)?;

    // Checkpoint and verify the live database with the current key; after
    // the close no WAL remains, so a byte copy is a complete database.
    let expected = inspect_database_file(&database, Some(&current)).await?;
    remove_sqlite_sidecars(&database)?;
    let temporary = TemporaryDatabase::new(&config.data_dir, "rekey");
    copy_private_file(&database, &temporary.path)?;
    let actual = database::rekey_database_file(&temporary.path, &current, &new).await?;
    if actual != expected {
        return Err(ApiError::conflict(
            "DATABASE_REKEY_VERIFY_FAILED",
            "the rekeyed copy does not match the database; nothing was replaced",
        ));
    }
    remove_sqlite_sidecars(&temporary.path)?;
    fs::rename(&temporary.path, &database).map_err(ApiError::internal)?;
    temporary.disarm();
    // From here on the live database is the rekeyed copy: a failure must not
    // be reported as "nothing was replaced".
    sync_directory(&config.data_dir).map_err(|_| rekey_installed_unverified())?;
    remove_sqlite_sidecars(&database).map_err(|_| rekey_installed_unverified())?;
    let installed = verify_installed_rekey(&database, &new).await;
    if !matches!(installed, Ok(ref installed) if *installed == expected) {
        return Err(rekey_installed_unverified());
    }
    Ok(DatabaseRekeySummary {
        tables: expected.table_rows.len(),
        rows: expected.total_rows(),
        removed_backup_snapshots,
    })
}

async fn verify_installed_rekey(
    database: &Path,
    new: &DatabaseKey,
) -> Result<database::DatabaseContentSummary, ApiError> {
    #[cfg(test)]
    if tests::fail_installed_rekey_verification() {
        return Err(ApiError::internal(
            "injected installed-rekey verification failure",
        ));
    }
    inspect_database_file(database, Some(new)).await
}

fn rekey_installed_unverified() -> ApiError {
    ApiError::new(
        StatusCode::INTERNAL_SERVER_ERROR,
        "DATABASE_REKEY_INSTALLED_UNVERIFIED",
        "the rekeyed copy already replaced the live database, which is now under the NEW key, but the final verification did not complete; keep both key files, configure the new key and run `atermius-server database-checkpoint --server-stopped` to verify it, or restore a backup",
    )
}

/// Offline WAL checkpoint and integrity check of the main database with the
/// configured key (or none for a plaintext instance). Holds the runtime lock
/// and the maintenance lock, runs `PRAGMA wal_checkpoint(TRUNCATE)` and
/// `PRAGMA integrity_check`, fully closes the database, and then requires the
/// `-wal`, `-shm` and `-journal` sidecars to be absent. Used before
/// `install-restore-stage`, which reads the source database read-only and
/// refuses any sidecar; a host-side `sqlite3` cannot open an encrypted file.
pub async fn checkpoint_database_offline(
    config: &Config,
    database_url: &str,
) -> Result<DatabaseCheckpointSummary, ApiError> {
    let database = prepare_offline_database_command(config, database_url)?;
    let _runtime_lock = acquire_runtime_lock(&config.data_dir)?;
    let _maintenance_lock = acquire_maintenance_run_lock(&config.data_dir)?;
    let key = DatabaseKey::configured(config)?;
    require_regular_database_file(&database)?;
    database::reject_incomplete_encryption(&database)?;
    let format = detect_database_file(&database)?;
    if format == DatabaseFileFormat::Absent {
        return Err(database_missing());
    }
    let encryption = database::startup_database_encryption(format, key.as_ref())?;
    let summary = inspect_database_file(&database, key.as_ref()).await?;
    for sidecar in sqlite_sidecars(&database) {
        match fs::symlink_metadata(&sidecar) {
            Ok(_) => {
                return Err(ApiError::conflict(
                    "DATABASE_SIDECAR_REMAINS",
                    "a SQLite -wal, -shm or -journal sidecar remained after the offline checkpoint and close; make sure no other process uses the database and retry",
                ));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(ApiError::internal(error)),
        }
    }
    Ok(DatabaseCheckpointSummary {
        tables: summary.table_rows.len(),
        rows: summary.total_rows(),
        encrypted: encryption == DatabaseEncryption::Enabled,
    })
}

fn prepare_offline_database_command(
    config: &Config,
    database_url: &str,
) -> Result<PathBuf, ApiError> {
    let expected = format!(
        "sqlite://{}/{MAIN_DATABASE_FILE}?mode=rwc",
        config.data_dir.display()
    );
    if database_url != expected {
        return Err(ApiError::bad_request(
            "UNSUPPORTED_DATABASE_URL",
            "database encryption commands support only ATERMIUS_DATA_DIR/atermius.db",
        ));
    }
    secure_file::secure_existing_data_dir(&config.data_dir)?;
    Ok(config.data_dir.join(MAIN_DATABASE_FILE))
}

fn require_regular_database_file(database: &Path) -> Result<(), ApiError> {
    match fs::symlink_metadata(database) {
        Ok(metadata) if metadata.file_type().is_file() => Ok(()),
        Ok(_) => Err(ApiError::internal(
            "the instance database path must be a regular non-symlink file",
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Err(database_missing()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn database_missing() -> ApiError {
    ApiError::conflict(
        "DATABASE_MISSING",
        "no instance database exists; a server started with ATERMIUS_DATABASE_KEY_FILE creates a new encrypted database",
    )
}

fn temporary_prefix(kind: &str) -> String {
    format!(".{MAIN_DATABASE_FILE}.{kind}-")
}

/// Removes leftovers of an interrupted encrypt/rekey run. They are never
/// plaintext: both are SQLCipher files (export target or rekey copy).
fn remove_stale_temporaries(data_dir: &Path) -> Result<(), ApiError> {
    let prefixes = [temporary_prefix("encrypt"), temporary_prefix("rekey")];
    for entry in fs::read_dir(data_dir).map_err(ApiError::internal)? {
        let entry = entry.map_err(ApiError::internal)?;
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if !prefixes
            .iter()
            .any(|prefix| name.starts_with(prefix.as_str()))
        {
            continue;
        }
        let metadata = fs::symlink_metadata(entry.path()).map_err(ApiError::internal)?;
        if metadata.file_type().is_file() {
            fs::remove_file(entry.path()).map_err(ApiError::internal)?;
        }
    }
    Ok(())
}

struct TemporaryDatabase {
    path: PathBuf,
    armed: std::cell::Cell<bool>,
}

impl TemporaryDatabase {
    fn new(data_dir: &Path, kind: &str) -> Self {
        Self {
            path: data_dir.join(format!("{}{}.tmp", temporary_prefix(kind), Uuid::new_v4())),
            armed: std::cell::Cell::new(true),
        }
    }

    fn disarm(&self) {
        self.armed.set(false);
    }
}

impl Drop for TemporaryDatabase {
    fn drop(&mut self) {
        if self.armed.get() {
            let _ = remove_sqlite_sidecars(&self.path);
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn copy_private_file(source: &Path, target: &Path) -> Result<(), ApiError> {
    let mut input = fs::File::open(source).map_err(ApiError::internal)?;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    let mut output = options.open(target).map_err(ApiError::internal)?;
    std::io::copy(&mut input, &mut output).map_err(ApiError::internal)?;
    output.sync_all().map_err(ApiError::internal)
}

fn remove_private_path(path: &Path) -> Result<(), ApiError> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn same_file(left: &Path, right: &Path) -> Result<bool, ApiError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let left = fs::symlink_metadata(left).map_err(ApiError::internal)?;
        let right = fs::symlink_metadata(right).map_err(ApiError::internal)?;
        Ok(left.dev() == right.dev() && left.ino() == right.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = (left, right);
        Ok(false)
    }
}

fn sync_directory(path: &Path) -> Result<(), ApiError> {
    fs::File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(ApiError::internal)
}

#[cfg(test)]
pub(crate) mod tests {
    use std::cell::Cell;

    thread_local! {
        static FAIL_INSTALLED_REKEY_VERIFICATION: Cell<bool> = const { Cell::new(false) };
    }

    /// Makes the next post-install rekey verification on this thread fail.
    /// `#[tokio::test]` runs the command on the test thread, so parallel
    /// tests are unaffected.
    pub(crate) fn inject_installed_rekey_verification_failure() {
        FAIL_INSTALLED_REKEY_VERIFICATION.with(|flag| flag.set(true));
    }

    pub(super) fn fail_installed_rekey_verification() -> bool {
        FAIL_INSTALLED_REKEY_VERIFICATION.with(|flag| flag.replace(false))
    }
}

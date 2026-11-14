//! Offline operator rotation for the server-side MFA TOTP seed key.

use std::{path::Path, str::FromStr, time::Duration};

use sqlx::{Connection, PgConnection, Postgres, Row, SqlitePool, postgres::PgConnectOptions};

use crate::{
    ApiError, acquire_maintenance_run_lock, acquire_runtime_lock, database, mfa, secure_file,
};

static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MfaKeyRotationSummary {
    pub active_envelopes: u64,
    pub pending_envelopes: u64,
}

/// Re-encrypts all current and pending TOTP seeds for this single SQLite
/// instance. Both process locks are held from before SQLite is opened through
/// commit. No schema, recovery-code, replay, or other MFA state is modified.
/// This entry point opens a plaintext (unencrypted) instance database; use
/// [`rotate_mfa_seed_encryption_key_with_database_key`] when
/// `ATERMIUS_DATABASE_KEY_FILE` is configured.
pub async fn rotate_mfa_seed_encryption_key(
    data_dir: &Path,
    database_url: &str,
    old_key_file: &Path,
    new_key_file: &Path,
) -> Result<MfaKeyRotationSummary, ApiError> {
    rotate_mfa_seed_encryption_key_with_database_key(
        data_dir,
        database_url,
        None,
        old_key_file,
        new_key_file,
    )
    .await
}

/// Same as [`rotate_mfa_seed_encryption_key`] for an instance database that
/// may be SQLCipher-encrypted with the key in `database_key_file`.
pub async fn rotate_mfa_seed_encryption_key_with_database_key(
    data_dir: &Path,
    database_url: &str,
    database_key_file: Option<&Path>,
    old_key_file: &Path,
    new_key_file: &Path,
) -> Result<MfaKeyRotationSummary, ApiError> {
    secure_file::secure_existing_data_dir(data_dir)?;
    let expected_url = format!("sqlite://{}/atermius.db?mode=rwc", data_dir.display());
    if database_url != expected_url {
        return Err(ApiError::internal(
            "MFA key rotation is restricted to ATERMIUS_DATA_DIR/atermius.db",
        ));
    }

    // Match the server and maintenance lock ordering used by offline backup
    // and object-store migration commands. Holding both prevents an online
    // service or another fixed maintenance operation from racing this write.
    let _runtime_lock = acquire_runtime_lock(data_dir)?;
    let _maintenance_lock = acquire_maintenance_run_lock(data_dir)?;

    let database_path = data_dir.join("atermius.db");
    let database_metadata = std::fs::symlink_metadata(&database_path)
        .map_err(|_| ApiError::internal("instance database is unavailable"))?;
    if !database_metadata.file_type().is_file() {
        return Err(ApiError::internal(
            "instance database must be a regular non-symlink file",
        ));
    }
    if old_key_file == new_key_file {
        return Err(ApiError::internal(
            "old and new MFA encryption key files must be different",
        ));
    }
    let old_key = secure_file::read_private_key_zeroizing(old_key_file)?;
    let new_key = secure_file::read_private_key_zeroizing(new_key_file)?;
    if old_key.as_ref() == new_key.as_ref() {
        return Err(ApiError::internal(
            "old and new MFA encryption keys must be different",
        ));
    }

    let database_key = database_key_file
        .map(|path| database::DatabaseKey::read_file(path, data_dir))
        .transpose()?;
    let options = database::main_sqlite_options(database_url, database_key.as_ref())?
        .create_if_missing(false)
        .foreign_keys(true)
        .busy_timeout(Duration::from_secs(10));
    database::startup_database_encryption(
        database::detect_database_file(&database_path)?,
        database_key.as_ref(),
    )?;
    let db = database::connect_keyed_pool(options, database_key.as_ref(), 1).await?;

    verify_database_scope(&db).await?;
    verify_current_schema(&db).await?;
    let mut tx = db
        .begin_with("BEGIN IMMEDIATE")
        .await
        .map_err(ApiError::internal)?;
    let result = mfa::reencrypt_seed_envelopes(&mut tx, &old_key, &new_key).await;
    match result {
        Ok(counts) => {
            tx.commit().await.map_err(ApiError::internal)?;
            db.close().await;
            Ok(MfaKeyRotationSummary {
                active_envelopes: counts.active,
                pending_envelopes: counts.pending,
            })
        }
        Err(error) => {
            tx.rollback().await.map_err(ApiError::internal)?;
            db.close().await;
            Err(error)
        }
    }
}

/// Selects the offline rotation backend from the exact shared-runtime setting.
/// An invalid PostgreSQL selection/configuration is rejected instead of
/// silently falling back to the node-local SQLite file.
pub async fn rotate_mfa_seed_encryption_key_for_selected_backend(
    data_dir: &Path,
    sqlite_database_url: &str,
    sqlite_database_key_file: Option<&Path>,
    old_key_file: &Path,
    new_key_file: &Path,
) -> Result<MfaKeyRotationSummary, ApiError> {
    match crate::pg_sync_runtime::PgSyncRuntimeConfig::from_env()? {
        Some(config) => {
            rotate_pg_mfa_seed_encryption_key(&config, old_key_file, new_key_file).await
        }
        None => {
            rotate_mfa_seed_encryption_key_with_database_key(
                data_dir,
                sqlite_database_url,
                sqlite_database_key_file,
                old_key_file,
                new_key_file,
            )
            .await
        }
    }
}

async fn rotate_pg_mfa_seed_encryption_key(
    config: &crate::pg_sync_runtime::PgSyncRuntimeConfig,
    old_key_file: &Path,
    new_key_file: &Path,
) -> Result<MfaKeyRotationSummary, ApiError> {
    if old_key_file == new_key_file {
        return Err(ApiError::internal(
            "old and new MFA encryption key files must be different",
        ));
    }
    let old_key = secure_file::read_private_key_zeroizing(old_key_file)?;
    let new_key = secure_file::read_private_key_zeroizing(new_key_file)?;
    if old_key.as_ref() == new_key.as_ref() {
        return Err(ApiError::internal(
            "old and new MFA encryption keys must be different",
        ));
    }

    // Reuse the runtime's complete migration/schema/cascade checks, then close
    // that pool before the offline connection checks whether any other client
    // is still attached to this database.
    let validation_pool = config.connect().await?;
    validation_pool.close().await;

    let options = PgConnectOptions::from_str(&config.database_url)
        .map_err(|_| ApiError::internal("PostgreSQL sync connection configuration is invalid"))?
        .options([("search_path", format!("\"{}\"", config.schema))]);
    let mut connection = PgConnection::connect_with(&options)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL sync backend is unavailable"))?;
    let lock_key = crate::pg_sync_runtime::acquire_offline_rotation_lock(&mut connection).await?;
    crate::pg_sync_runtime::ensure_no_other_database_clients(&mut connection).await?;

    let outcome = async {
        let mut tx = connection.begin().await.map_err(ApiError::internal)?;
        match reencrypt_pg_seed_envelopes(&mut tx, &old_key, &new_key).await {
            Ok(summary) => {
                tx.commit().await.map_err(ApiError::internal)?;
                Ok(summary)
            }
            Err(error) => {
                // The failed decrypt/encrypt/update is intentionally rolled
                // back before returning. Never include envelope or key bytes
                // in the operator-visible error.
                let _ = tx.rollback().await;
                Err(error)
            }
        }
    }
    .await;
    let unlocked: Result<bool, ApiError> = sqlx::query_scalar("SELECT pg_advisory_unlock($1)")
        .bind(lock_key)
        .fetch_one(&mut connection)
        .await
        .map_err(|_| ApiError::internal("PostgreSQL offline rotation lock was lost"));
    match outcome {
        Err(error) => Err(error),
        Ok(summary) => match unlocked {
            Ok(true) => Ok(summary),
            Ok(false) | Err(_) => Err(ApiError::internal(
                "PostgreSQL offline rotation lock was lost",
            )),
        },
    }
}

async fn reencrypt_pg_seed_envelopes(
    tx: &mut sqlx::Transaction<'_, Postgres>,
    old_key: &[u8; 32],
    new_key: &[u8; 32],
) -> Result<MfaKeyRotationSummary, ApiError> {
    let rows = sqlx::query(
        "SELECT user_id,totp_seed_envelope,pending_seed_envelope FROM auth_mfa \
         WHERE totp_seed_envelope IS NOT NULL OR pending_seed_envelope IS NOT NULL \
         ORDER BY user_id FOR UPDATE",
    )
    .fetch_all(&mut **tx)
    .await
    .map_err(ApiError::internal)?;
    let mut summary = MfaKeyRotationSummary::default();
    for row in rows {
        let user_id: String = row.try_get("user_id").map_err(ApiError::internal)?;
        let active: Option<String> = row
            .try_get("totp_seed_envelope")
            .map_err(ApiError::internal)?;
        let pending: Option<String> = row
            .try_get("pending_seed_envelope")
            .map_err(ApiError::internal)?;
        let rotated_active = active
            .as_deref()
            .map(|envelope| mfa::reencrypt_seed_envelope(old_key, new_key, &user_id, envelope))
            .transpose()?;
        let rotated_pending = pending
            .as_deref()
            .map(|envelope| mfa::reencrypt_seed_envelope(old_key, new_key, &user_id, envelope))
            .transpose()?;
        let update = sqlx::query(
            "UPDATE auth_mfa SET totp_seed_envelope=$1,pending_seed_envelope=$2 \
             WHERE user_id=$3 AND totp_seed_envelope IS NOT DISTINCT FROM $4 \
               AND pending_seed_envelope IS NOT DISTINCT FROM $5",
        )
        .bind(&rotated_active)
        .bind(&rotated_pending)
        .bind(&user_id)
        .bind(&active)
        .bind(&pending)
        .execute(&mut **tx)
        .await
        .map_err(ApiError::internal)?;
        if update.rows_affected() != 1 {
            return Err(ApiError::internal(
                "MFA seed envelope changed during offline key rotation",
            ));
        }
        summary.active_envelopes += u64::from(active.is_some());
        summary.pending_envelopes += u64::from(pending.is_some());
    }
    Ok(summary)
}

async fn verify_database_scope(db: &SqlitePool) -> Result<(), ApiError> {
    let integrity: Vec<String> = sqlx::query_scalar("PRAGMA integrity_check")
        .fetch_all(db)
        .await
        .map_err(ApiError::internal)?;
    if integrity.len() != 1 || integrity[0] != "ok" {
        return Err(ApiError::internal("SQLite integrity check failed"));
    }
    let foreign_keys = sqlx::query("PRAGMA foreign_key_check")
        .fetch_all(db)
        .await
        .map_err(ApiError::internal)?;
    if !foreign_keys.is_empty() {
        return Err(ApiError::internal("SQLite foreign key check failed"));
    }
    Ok(())
}

async fn verify_current_schema(db: &SqlitePool) -> Result<(), ApiError> {
    let expected: Vec<i64> = MIGRATOR.iter().map(|migration| migration.version).collect();
    let applied: Vec<i64> =
        sqlx::query_scalar("SELECT version FROM _sqlx_migrations WHERE success=1 ORDER BY version")
            .fetch_all(db)
            .await
            .map_err(ApiError::internal)?;
    let failed: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM _sqlx_migrations WHERE success=0")
        .fetch_one(db)
        .await
        .map_err(ApiError::internal)?;
    if applied != expected || failed != 0 {
        return Err(ApiError::internal(
            "instance database migrations are incomplete or unsupported",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf};

    use sqlx::{Row, sqlite::SqlitePoolOptions};
    use uuid::Uuid;

    use super::*;
    use crate::mfa::{decrypt_seed, encrypt_seed};

    struct Fixture {
        data_dir: PathBuf,
        db: SqlitePool,
        old_key_path: PathBuf,
        new_key_path: PathBuf,
        old_key: [u8; 32],
        new_key: [u8; 32],
    }

    impl Fixture {
        async fn new() -> Self {
            let data_dir =
                std::env::temp_dir().join(format!("atermius-mfa-rotate-{}", Uuid::new_v4()));
            fs::create_dir(&data_dir).unwrap();
            fs::set_permissions(&data_dir, fs::Permissions::from_mode(0o700)).unwrap();
            let database_path = data_dir.join("atermius.db");
            // Same central helper as production opens (no key: plaintext).
            let options = crate::database::sqlite_file_options(&database_path, None)
                .create_if_missing(true)
                .foreign_keys(true)
                .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal);
            let db = SqlitePoolOptions::new()
                .max_connections(1)
                .connect_with(options)
                .await
                .unwrap();
            MIGRATOR.run(&db).await.unwrap();
            let old_key = [0x31; 32];
            let new_key = [0x72; 32];
            let old_key_path = data_dir.join("old.key");
            let new_key_path = data_dir.join("new.key");
            fs::write(&old_key_path, old_key).unwrap();
            fs::write(&new_key_path, new_key).unwrap();
            fs::set_permissions(&old_key_path, fs::Permissions::from_mode(0o600)).unwrap();
            fs::set_permissions(&new_key_path, fs::Permissions::from_mode(0o600)).unwrap();
            Self {
                data_dir,
                db,
                old_key_path,
                new_key_path,
                old_key,
                new_key,
            }
        }

        fn database_url(&self) -> String {
            format!("sqlite://{}/atermius.db?mode=rwc", self.data_dir.display())
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            // Tests explicitly close pools before this drops. Ignore cleanup
            // errors so a test assertion remains the primary failure.
            let _ = fs::remove_dir_all(&self.data_dir);
        }
    }

    async fn insert_user(fixture: &Fixture, user_id: &str) {
        sqlx::query("INSERT INTO users(user_id,username,created_at) VALUES(?,?,?)")
            .bind(user_id)
            .bind(format!("{user_id}@example.test"))
            .bind("2026-01-01T00:00:00Z")
            .execute(&fixture.db)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn rotates_active_and_pending_envelopes_without_touching_recovery_or_replay_state() {
        let fixture = Fixture::new().await;
        let user_id = "mfa-rotation-user";
        insert_user(&fixture, user_id).await;
        let active_seed = [0x19; 20];
        let pending_seed = [0xa4; 20];
        let active = encrypt_seed(&fixture.old_key, user_id, &active_seed).unwrap();
        let pending = encrypt_seed(&fixture.old_key, user_id, &pending_seed).unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step, \
             pending_seed_envelope,pending_expires_at,pending_credential_version) \
             VALUES(?,?,100,987,?,?,3)",
        )
        .bind(user_id)
        .bind(&active)
        .bind(&pending)
        .bind(200_i64)
        .execute(&fixture.db)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa_recovery_codes(code_id,user_id,salt,code_hash,created_at,consumed_at) \
             VALUES('rotation-code',?,?,?,100,NULL)",
        )
        .bind(user_id)
        .bind("abcdefghijklmnopqrstuv")
        .bind("a".repeat(64))
        .execute(&fixture.db)
        .await
        .unwrap();
        let recovery_before: (String, String, i64, Option<i64>) = sqlx::query(
            "SELECT salt,code_hash,created_at,consumed_at FROM auth_mfa_recovery_codes WHERE code_id='rotation-code'",
        )
        .fetch_one(&fixture.db)
        .await
        .map(|row| (row.get(0), row.get(1), row.get(2), row.get(3)))
        .unwrap();

        let result = rotate_mfa_seed_encryption_key(
            &fixture.data_dir,
            &fixture.database_url(),
            &fixture.old_key_path,
            &fixture.new_key_path,
        )
        .await
        .unwrap();
        assert_eq!(
            result,
            MfaKeyRotationSummary {
                active_envelopes: 1,
                pending_envelopes: 1
            }
        );

        let row = sqlx::query(
            "SELECT totp_seed_envelope,enabled_at,last_totp_step,pending_seed_envelope, \
             pending_expires_at,pending_credential_version FROM auth_mfa WHERE user_id=?",
        )
        .bind(user_id)
        .fetch_one(&fixture.db)
        .await
        .unwrap();
        let rotated_active: String = row.get(0);
        let enabled_at: i64 = row.get(1);
        let last_totp_step: i64 = row.get(2);
        let rotated_pending: String = row.get(3);
        let pending_expires_at: i64 = row.get(4);
        let pending_credential_version: i64 = row.get(5);
        assert_ne!(rotated_active, active);
        assert_ne!(rotated_pending, pending);
        assert_eq!(
            &*decrypt_seed(&fixture.new_key, user_id, &rotated_active).unwrap(),
            &active_seed
        );
        assert_eq!(
            &*decrypt_seed(&fixture.new_key, user_id, &rotated_pending).unwrap(),
            &pending_seed
        );
        assert!(decrypt_seed(&fixture.old_key, user_id, &rotated_active).is_err());
        assert!(decrypt_seed(&fixture.old_key, user_id, &rotated_pending).is_err());
        assert_eq!(
            (
                enabled_at,
                last_totp_step,
                pending_expires_at,
                pending_credential_version
            ),
            (100, 987, 200, 3)
        );
        let recovery_after: (String, String, i64, Option<i64>) = sqlx::query(
            "SELECT salt,code_hash,created_at,consumed_at FROM auth_mfa_recovery_codes WHERE code_id='rotation-code'",
        )
        .fetch_one(&fixture.db)
        .await
        .map(|row| (row.get(0), row.get(1), row.get(2), row.get(3)))
        .unwrap();
        assert_eq!(recovery_after, recovery_before);
        fixture.db.close().await;
    }

    #[tokio::test]
    async fn malformed_later_envelope_rolls_back_earlier_updates() {
        let fixture = Fixture::new().await;
        let valid_user = "a-mfa-rollback-user";
        let malformed_user = "z-mfa-rollback-user";
        insert_user(&fixture, valid_user).await;
        insert_user(&fixture, malformed_user).await;
        let active = encrypt_seed(&fixture.old_key, valid_user, &[0x41; 20]).unwrap();
        let pending = encrypt_seed(&fixture.old_key, valid_user, &[0x42; 20]).unwrap();
        sqlx::query(
            "INSERT INTO auth_mfa(user_id,totp_seed_envelope,enabled_at,last_totp_step, \
             pending_seed_envelope,pending_expires_at,pending_credential_version) \
             VALUES(?,?,100,12,?,?,1)",
        )
        .bind(valid_user)
        .bind(&active)
        .bind(&pending)
        .bind(200_i64)
        .execute(&fixture.db)
        .await
        .unwrap();
        let malformed = "not-a-valid-seed-envelope";
        sqlx::query(
            "INSERT INTO auth_mfa(user_id,pending_seed_envelope,pending_expires_at,pending_credential_version) \
             VALUES(?,?,200,1)",
        )
        .bind(malformed_user)
        .bind(malformed)
        .execute(&fixture.db)
        .await
        .unwrap();

        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &fixture.database_url(),
                &fixture.old_key_path,
                &fixture.new_key_path,
            )
            .await
            .is_err()
        );
        let valid_row = sqlx::query(
            "SELECT totp_seed_envelope,pending_seed_envelope FROM auth_mfa WHERE user_id=?",
        )
        .bind(valid_user)
        .fetch_one(&fixture.db)
        .await
        .unwrap();
        assert_eq!(valid_row.get::<String, _>(0), active);
        assert_eq!(valid_row.get::<String, _>(1), pending);
        let malformed_row =
            sqlx::query("SELECT pending_seed_envelope FROM auth_mfa WHERE user_id=?")
                .bind(malformed_user)
                .fetch_one(&fixture.db)
                .await
                .unwrap();
        assert_eq!(malformed_row.get::<String, _>(0), malformed);
        fixture.db.close().await;
    }

    #[tokio::test]
    async fn rejects_external_database_and_equal_or_unsafe_key_files() {
        let fixture = Fixture::new().await;
        let database_url = fixture.database_url();
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                "sqlite:///tmp/foreign.db?mode=rwc",
                &fixture.old_key_path,
                &fixture.new_key_path,
            )
            .await
            .is_err()
        );
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &database_url,
                &fixture.old_key_path,
                &fixture.old_key_path,
            )
            .await
            .is_err()
        );
        fs::write(&fixture.new_key_path, fixture.old_key).unwrap();
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &database_url,
                &fixture.old_key_path,
                &fixture.new_key_path,
            )
            .await
            .is_err()
        );
        fs::write(&fixture.new_key_path, fixture.new_key).unwrap();
        fs::set_permissions(&fixture.new_key_path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &database_url,
                &fixture.old_key_path,
                &fixture.new_key_path,
            )
            .await
            .is_err()
        );
        fs::write(&fixture.new_key_path, [0_u8; 31]).unwrap();
        fs::set_permissions(&fixture.new_key_path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &database_url,
                &fixture.old_key_path,
                &fixture.new_key_path,
            )
            .await
            .is_err()
        );
        fs::write(&fixture.new_key_path, fixture.new_key).unwrap();
        fs::set_permissions(&fixture.new_key_path, fs::Permissions::from_mode(0o600)).unwrap();
        let symlink_path = fixture.data_dir.join("new-key-link");
        std::os::unix::fs::symlink(&fixture.new_key_path, &symlink_path).unwrap();
        assert!(
            rotate_mfa_seed_encryption_key(
                &fixture.data_dir,
                &database_url,
                &fixture.old_key_path,
                &symlink_path,
            )
            .await
            .is_err()
        );
        fixture.db.close().await;
    }
}

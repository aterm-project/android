use std::path::{Path, PathBuf};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use rand::RngCore;
use sqlx::{PgPool, Row, SqlitePool};
use uuid::Uuid;

use crate::{
    ApiError, AppState, InstanceInfo, InstanceKeyTransition, InstanceKeyTransitionPayload,
    acquire_runtime_lock, jcs, now_rfc3339, secure_file,
};

const TRANSITION_FORMAT: &str = "atermius-instance-key-transition-v1";

struct StoredInstanceIdentity {
    instance_id: String,
    server_space_id: String,
    generation: String,
    signing_public_key: String,
    signing_key_transitions_json: String,
}

#[derive(Clone, Copy)]
enum IdentityDatabase<'a> {
    Sqlite(&'a SqlitePool),
    Postgres(&'a PgPool),
}

pub(crate) async fn load_or_create(
    db: &SqlitePool,
    data_dir: &Path,
) -> Result<(InstanceInfo, SigningKey), ApiError> {
    load_or_create_from_database(db, data_dir).await
}

/// Loads the singleton instance identity from PostgreSQL, creating its
/// metadata row once when absent. PostgreSQL nodes must point this at the same
/// explicitly provisioned owner-only signing-key file; identity is never
/// derived from a node-local data directory and this function never creates a
/// key file.
pub(crate) async fn load_or_create_postgres(
    db: &PgPool,
    shared_key_path: &Path,
) -> Result<(InstanceInfo, SigningKey), ApiError> {
    let raw_key = secure_file::read_private_key_zeroizing(shared_key_path)?;
    let signing_key = SigningKey::from_bytes(&*raw_key);
    let signing_public_key = encode_public_key(&signing_key);
    let database = IdentityDatabase::Postgres(db);

    let identity = match read_identity(database).await? {
        Some(identity) => identity,
        None => {
            let candidate = InstanceInfo {
                instance_id: Uuid::new_v4().to_string(),
                server_space_id: Uuid::new_v4().to_string(),
                generation: Uuid::new_v4().to_string(),
                signing_public_key: signing_public_key.clone(),
                signing_key_transitions: Vec::new(),
            };
            // The singleton primary key arbitrates concurrent initializers.
            // Every contender reads the row that won after the insert, rather
            // than returning its own uncommitted candidate identity.
            insert_identity(database, &candidate).await?;
            read_identity(database)
                .await?
                .ok_or_else(|| ApiError::internal("persisted instance metadata row is missing"))?
        }
    };

    if identity.signing_public_key != signing_public_key {
        return Err(ApiError::internal(
            "shared instance identity key does not match persisted identity",
        ));
    }
    let transitions: Vec<InstanceKeyTransition> =
        serde_json::from_str(&identity.signing_key_transitions_json)
            .map_err(|_| ApiError::internal("stored instance key transition chain is invalid"))?;
    verify_transition_chain_shape(&identity.instance_id, &transitions)?;
    Ok((to_instance_info(identity, transitions)?, signing_key))
}

async fn load_or_create_from_database(
    db: &SqlitePool,
    data_dir: &Path,
) -> Result<(InstanceInfo, SigningKey), ApiError> {
    let database = IdentityDatabase::Sqlite(db);
    let active_path = data_dir.join("instance-ed25519.key");
    let staged_path = rotation_staged_path(data_dir);
    let previous_path = rotation_previous_path(data_dir);
    let existing = read_identity(database).await?;
    let Some(identity) = existing else {
        secure_file::remove_private_file_if_exists(&staged_path)?;
        secure_file::remove_private_file_if_exists(&previous_path)?;
        let signing_key =
            SigningKey::from_bytes(&secure_file::read_or_create_private_key(&active_path)?);
        let info = InstanceInfo {
            instance_id: Uuid::new_v4().to_string(),
            server_space_id: Uuid::new_v4().to_string(),
            generation: Uuid::new_v4().to_string(),
            signing_public_key: encode_public_key(&signing_key),
            signing_key_transitions: Vec::new(),
        };
        insert_identity(database, &info).await?;
        return Ok((info, signing_key));
    };

    let mut transitions: Vec<InstanceKeyTransition> =
        serde_json::from_str(&identity.signing_key_transitions_json)
            .map_err(|_| ApiError::internal("stored instance key transition chain is invalid"))?;
    verify_transition_chain_shape(&identity.instance_id, &transitions)?;

    let active = secure_file::read_private_key_if_exists(&active_path)?;
    if let Some(raw) = active {
        let active_key = SigningKey::from_bytes(&raw);
        if encode_public_key(&active_key) == identity.signing_public_key {
            return Ok((to_instance_info(identity, transitions)?, active_key));
        }
    }

    // A mismatch is only recoverable when a completed DB transaction has a
    // matching fsynced next-key file and the old private key can authenticate
    // the final transition. The lock prevents a concurrent operator command
    // from publishing or removing either journal file while boot recovers it.
    let _runtime_lock = acquire_runtime_lock(data_dir)?;
    let identity = read_identity(database)
        .await?
        .ok_or_else(|| ApiError::internal("instance metadata row disappeared"))?;
    transitions = serde_json::from_str(&identity.signing_key_transitions_json)
        .map_err(|_| ApiError::internal("stored instance key transition chain is invalid"))?;
    verify_transition_chain_shape(&identity.instance_id, &transitions)?;

    let current_old = secure_file::read_private_key_if_exists(&active_path)?;
    let previous_old = secure_file::read_private_key_if_exists(&previous_path)?;
    let old_raw = current_old
        .as_ref()
        .or(previous_old.as_ref())
        .ok_or_else(|| ApiError::internal("instance identity key is missing during rotation"))?;
    let old_key = SigningKey::from_bytes(old_raw);
    let staged_raw = secure_file::read_private_key_if_exists(&staged_path)?
        .ok_or_else(|| ApiError::internal("staged instance identity key is missing"))?;
    let staged_key = SigningKey::from_bytes(&staged_raw);
    if encode_public_key(&staged_key) != identity.signing_public_key {
        return Err(ApiError::internal(
            "staged instance identity key does not match persisted identity",
        ));
    }
    let transition = transitions
        .last()
        .ok_or_else(|| ApiError::internal("instance key rotation has no transition proof"))?;
    verify_transition(
        transition,
        &old_key,
        &identity.instance_id,
        &identity.signing_public_key,
    )?;

    if previous_old.is_none() {
        secure_file::write_new_private_key(&previous_path, old_raw)?;
    }
    secure_file::promote_private_key(&staged_path, &active_path)?;
    let promoted = secure_file::read_private_key(&active_path)?;
    let promoted_key = SigningKey::from_bytes(&promoted);
    if encode_public_key(&promoted_key) != identity.signing_public_key {
        return Err(ApiError::internal(
            "promoted instance identity key does not match persisted identity",
        ));
    }
    let _ = secure_file::remove_private_file_if_exists(&previous_path);
    Ok((to_instance_info(identity, transitions)?, promoted_key))
}

/// Rotates the instance identity key while the service is stopped. The DB
/// transition is committed before replacing the active key file. If the
/// process stops between those steps, `load_or_create` verifies and completes
/// the staged rotation on the next start.
pub async fn rotate_instance_signing_key(state: &AppState) -> Result<(String, String), ApiError> {
    let _runtime_lock = acquire_runtime_lock(&state.config.data_dir)?;
    let active_path = state.config.data_dir.join("instance-ed25519.key");
    let staged_path = rotation_staged_path(&state.config.data_dir);
    let previous_path = rotation_previous_path(&state.config.data_dir);

    let raw_old = secure_file::read_private_key(&active_path)?;
    let old_key = SigningKey::from_bytes(&raw_old);
    let old_public = encode_public_key(&old_key);
    if old_public != state.instance.signing_public_key
        || old_key.as_bytes() != state.signing_key.as_bytes()
    {
        return Err(ApiError::conflict(
            "INSTANCE_IDENTITY_CHANGED",
            "instance identity changed after this operator command loaded state; retry it",
        ));
    }
    let current = read_identity(IdentityDatabase::Sqlite(&state.db))
        .await?
        .ok_or_else(|| ApiError::internal("instance metadata row is missing"))?;
    if current.instance_id != state.instance.instance_id || current.signing_public_key != old_public
    {
        return Err(ApiError::conflict(
            "INSTANCE_IDENTITY_CHANGED",
            "persisted instance identity does not match the active key",
        ));
    }

    // Orphaned files from a command that stopped before the DB commit are
    // safe to replace only after the persisted identity was checked above.
    secure_file::remove_private_file_if_exists(&staged_path)?;
    secure_file::remove_private_file_if_exists(&previous_path)?;

    let mut new_raw = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut new_raw);
    let new_key = SigningKey::from_bytes(&new_raw);
    let new_public = encode_public_key(&new_key);
    let issued_at = now_rfc3339();
    let payload = InstanceKeyTransitionPayload {
        format: TRANSITION_FORMAT,
        instance_id: &current.instance_id,
        from_public_key: &old_public,
        to_public_key: &new_public,
        issued_at: &issued_at,
    };
    let signature = old_key.sign(&jcs(&payload)?);
    let transition = InstanceKeyTransition {
        format: TRANSITION_FORMAT.to_owned(),
        instance_id: current.instance_id.clone(),
        from_public_key: old_public.clone(),
        to_public_key: new_public.clone(),
        issued_at,
        signature: URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    };
    let mut transitions: Vec<InstanceKeyTransition> =
        serde_json::from_str(&current.signing_key_transitions_json)
            .map_err(|_| ApiError::internal("stored instance key transition chain is invalid"))?;
    verify_transition_chain_shape(&current.instance_id, &transitions)?;
    transitions.push(transition);

    secure_file::write_new_private_key(&staged_path, &new_raw)?;
    secure_file::write_new_private_key(&previous_path, &raw_old)?;
    new_raw.fill(0);

    let new_generation = Uuid::new_v4().to_string();
    let transitions_json = serde_json::to_string(&transitions).map_err(ApiError::internal)?;
    if !compare_and_swap_identity(
        IdentityDatabase::Sqlite(&state.db),
        &current.instance_id,
        &old_public,
        &new_public,
        &transitions_json,
        &new_generation,
    )
    .await?
    {
        return Err(ApiError::conflict(
            "INSTANCE_IDENTITY_CHANGED",
            "persisted instance identity changed during key rotation",
        ));
    }
    // If commit outcome is uncertain, leave the staged/previous files in
    // place. Startup can safely decide from the committed public key.

    secure_file::promote_private_key(&staged_path, &active_path)?;
    let promoted = secure_file::read_private_key(&active_path)?;
    if encode_public_key(&SigningKey::from_bytes(&promoted)) != new_public {
        return Err(ApiError::internal(
            "promoted instance identity key does not match rotation result",
        ));
    }
    secure_file::remove_private_file_if_exists(&previous_path)?;
    Ok((new_public, new_generation))
}

async fn read_identity(
    db: IdentityDatabase<'_>,
) -> Result<Option<StoredInstanceIdentity>, ApiError> {
    match db {
        IdentityDatabase::Sqlite(pool) => {
            let row = sqlx::query(
                "SELECT instance_id,server_space_id,generation,signing_public_key,signing_key_transitions_json FROM instance_meta WHERE id=1",
            )
            .fetch_optional(pool)
            .await
            .map_err(ApiError::internal)?;
            row.map(|row| {
                Ok(StoredInstanceIdentity {
                    instance_id: row.try_get("instance_id").map_err(ApiError::internal)?,
                    server_space_id: row.try_get("server_space_id").map_err(ApiError::internal)?,
                    generation: row.try_get("generation").map_err(ApiError::internal)?,
                    signing_public_key: row
                        .try_get("signing_public_key")
                        .map_err(ApiError::internal)?,
                    signing_key_transitions_json: row
                        .try_get("signing_key_transitions_json")
                        .map_err(ApiError::internal)?,
                })
            })
            .transpose()
        }
        IdentityDatabase::Postgres(pool) => {
            let row = sqlx::query(
                "SELECT instance_id,server_space_id,generation,signing_public_key,signing_key_transitions_json FROM instance_meta WHERE id=1",
            )
            .fetch_optional(pool)
            .await
            .map_err(ApiError::internal)?;
            row.map(|row| {
                Ok(StoredInstanceIdentity {
                    instance_id: row.try_get("instance_id").map_err(ApiError::internal)?,
                    server_space_id: row.try_get("server_space_id").map_err(ApiError::internal)?,
                    generation: row.try_get("generation").map_err(ApiError::internal)?,
                    signing_public_key: row
                        .try_get("signing_public_key")
                        .map_err(ApiError::internal)?,
                    signing_key_transitions_json: row
                        .try_get("signing_key_transitions_json")
                        .map_err(ApiError::internal)?,
                })
            })
            .transpose()
        }
    }
}

async fn insert_identity(db: IdentityDatabase<'_>, info: &InstanceInfo) -> Result<(), ApiError> {
    match db {
        IdentityDatabase::Sqlite(pool) => {
            sqlx::query("INSERT INTO instance_meta(id,instance_id,server_space_id,generation,signing_public_key) VALUES(1,?,?,?,?)")
                .bind(&info.instance_id)
                .bind(&info.server_space_id)
                .bind(&info.generation)
                .bind(&info.signing_public_key)
                .execute(pool)
                .await
                .map_err(ApiError::internal)?;
        }
        IdentityDatabase::Postgres(pool) => {
            sqlx::query("INSERT INTO instance_meta(id,instance_id,server_space_id,generation,signing_public_key) VALUES(1,$1,$2,$3,$4) ON CONFLICT (id) DO NOTHING")
                .bind(&info.instance_id)
                .bind(&info.server_space_id)
                .bind(&info.generation)
                .bind(&info.signing_public_key)
                .execute(pool)
                .await
                .map_err(ApiError::internal)?;
        }
    }
    Ok(())
}

async fn compare_and_swap_identity(
    db: IdentityDatabase<'_>,
    instance_id: &str,
    expected_public_key: &str,
    new_public_key: &str,
    transitions_json: &str,
    generation: &str,
) -> Result<bool, ApiError> {
    match db {
        IdentityDatabase::Sqlite(pool) => {
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            let updated = sqlx::query("UPDATE instance_meta SET signing_public_key=?, signing_key_transitions_json=?, generation=? WHERE id=1 AND instance_id=? AND signing_public_key=?")
                .bind(new_public_key)
                .bind(transitions_json)
                .bind(generation)
                .bind(instance_id)
                .bind(expected_public_key)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            Ok(updated.rows_affected() == 1)
        }
        IdentityDatabase::Postgres(pool) => {
            let mut tx = pool.begin().await.map_err(ApiError::internal)?;
            let updated = sqlx::query("UPDATE instance_meta SET signing_public_key=$1, signing_key_transitions_json=$2, generation=$3 WHERE id=1 AND instance_id=$4 AND signing_public_key=$5")
                .bind(new_public_key)
                .bind(transitions_json)
                .bind(generation)
                .bind(instance_id)
                .bind(expected_public_key)
                .execute(&mut *tx)
                .await
                .map_err(ApiError::internal)?;
            tx.commit().await.map_err(ApiError::internal)?;
            Ok(updated.rows_affected() == 1)
        }
    }
}

fn to_instance_info(
    identity: StoredInstanceIdentity,
    signing_key_transitions: Vec<InstanceKeyTransition>,
) -> Result<InstanceInfo, ApiError> {
    Ok(InstanceInfo {
        instance_id: identity.instance_id,
        server_space_id: identity.server_space_id,
        generation: identity.generation,
        signing_public_key: identity.signing_public_key,
        signing_key_transitions,
    })
}

fn encode_public_key(key: &SigningKey) -> String {
    URL_SAFE_NO_PAD.encode(key.verifying_key().as_bytes())
}

fn verify_transition_chain_shape(
    instance_id: &str,
    transitions: &[InstanceKeyTransition],
) -> Result<(), ApiError> {
    for transition in transitions {
        if transition.format != TRANSITION_FORMAT
            || transition.instance_id != instance_id
            || DateTimeCheck::is_invalid(&transition.issued_at)
            || decode_key(&transition.from_public_key).is_err()
            || decode_key(&transition.to_public_key).is_err()
        {
            return Err(ApiError::internal(
                "stored instance key transition chain is invalid",
            ));
        }
        let signature = URL_SAFE_NO_PAD.decode(&transition.signature).map_err(|_| {
            ApiError::internal("stored instance key transition signature is invalid")
        })?;
        if URL_SAFE_NO_PAD.encode(&signature) != transition.signature {
            return Err(ApiError::internal(
                "stored instance key transition signature is invalid",
            ));
        }
        Signature::from_slice(&signature).map_err(|_| {
            ApiError::internal("stored instance key transition signature is invalid")
        })?;
    }
    if transitions
        .windows(2)
        .any(|pair| pair[0].to_public_key != pair[1].from_public_key)
    {
        return Err(ApiError::internal(
            "stored instance key transition chain is discontinuous",
        ));
    }
    Ok(())
}

fn verify_transition(
    transition: &InstanceKeyTransition,
    old_key: &SigningKey,
    instance_id: &str,
    expected_new_public: &str,
) -> Result<(), ApiError> {
    if transition.format != TRANSITION_FORMAT
        || transition.instance_id != instance_id
        || transition.from_public_key != encode_public_key(old_key)
        || transition.to_public_key != expected_new_public
        || DateTimeCheck::is_invalid(&transition.issued_at)
    {
        return Err(ApiError::internal(
            "instance key transition does not match persisted identity",
        ));
    }
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(&transition.signature)
        .map_err(|_| ApiError::internal("instance key transition signature is invalid"))?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| ApiError::internal("instance key transition signature is invalid"))?;
    if URL_SAFE_NO_PAD.encode(signature.to_bytes()) != transition.signature {
        return Err(ApiError::internal(
            "instance key transition signature is invalid",
        ));
    }
    old_key
        .verifying_key()
        .verify(
            &jcs(&InstanceKeyTransitionPayload {
                format: TRANSITION_FORMAT,
                instance_id,
                from_public_key: &transition.from_public_key,
                to_public_key: &transition.to_public_key,
                issued_at: &transition.issued_at,
            })?,
            &signature,
        )
        .map_err(|_| ApiError::internal("instance key transition signature is invalid"))
}

fn decode_key(encoded: &str) -> Result<VerifyingKey, ApiError> {
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| ApiError::internal("instance public key is invalid"))?;
    let raw: [u8; 32] = bytes
        .try_into()
        .map_err(|_| ApiError::internal("instance public key is invalid"))?;
    if URL_SAFE_NO_PAD.encode(raw) != encoded {
        return Err(ApiError::internal("instance public key is not canonical"));
    }
    VerifyingKey::from_bytes(&raw).map_err(ApiError::internal)
}

struct DateTimeCheck;

impl DateTimeCheck {
    fn is_invalid(value: &str) -> bool {
        chrono::DateTime::parse_from_rfc3339(value).is_err()
    }
}

fn rotation_staged_path(data_dir: &Path) -> PathBuf {
    data_dir.join("instance-ed25519.next")
}

fn rotation_previous_path(data_dir: &Path) -> PathBuf {
    data_dir.join("instance-ed25519.previous")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sqlx::sqlite::SqlitePoolOptions;

    fn private_temp_dir() -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("atermius-instance-identity-{}", Uuid::new_v4()));
        std::fs::create_dir(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        path
    }

    async fn identity_test_db() -> SqlitePool {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::query("CREATE TABLE instance_meta (id INTEGER PRIMARY KEY, instance_id TEXT NOT NULL, server_space_id TEXT NOT NULL, generation TEXT NOT NULL, signing_public_key TEXT NOT NULL, signing_key_transitions_json TEXT NOT NULL DEFAULT '[]')")
            .execute(&db)
            .await
            .unwrap();
        db
    }

    fn signed_transition(
        instance_id: &str,
        old_key: &SigningKey,
        new_key: &SigningKey,
    ) -> InstanceKeyTransition {
        let from_public_key = encode_public_key(old_key);
        let to_public_key = encode_public_key(new_key);
        let issued_at = "2026-09-27T12:00:00Z".to_owned();
        let payload = InstanceKeyTransitionPayload {
            format: TRANSITION_FORMAT,
            instance_id,
            from_public_key: &from_public_key,
            to_public_key: &to_public_key,
            issued_at: &issued_at,
        };
        let signature = old_key.sign(&jcs(&payload).unwrap());
        InstanceKeyTransition {
            format: TRANSITION_FORMAT.to_owned(),
            instance_id: instance_id.to_owned(),
            from_public_key,
            to_public_key,
            issued_at,
            signature: URL_SAFE_NO_PAD.encode(signature.to_bytes()),
        }
    }

    #[test]
    fn transition_requires_old_key_and_binds_instance_and_target() {
        let old_key = SigningKey::from_bytes(&[1_u8; 32]);
        let new_key = SigningKey::from_bytes(&[2_u8; 32]);
        let transition = signed_transition("instance-1", &old_key, &new_key);
        assert!(
            verify_transition(
                &transition,
                &old_key,
                "instance-1",
                &encode_public_key(&new_key)
            )
            .is_ok()
        );
        assert!(
            verify_transition(
                &transition,
                &old_key,
                "instance-2",
                &encode_public_key(&new_key)
            )
            .is_err()
        );
        assert!(
            verify_transition(
                &transition,
                &new_key,
                "instance-1",
                &encode_public_key(&new_key)
            )
            .is_err()
        );
        assert!(
            verify_transition(
                &transition,
                &old_key,
                "instance-1",
                &encode_public_key(&old_key)
            )
            .is_err()
        );
    }

    #[test]
    fn stored_transition_chain_rejects_discontinuities_and_unknown_fields() {
        let first = SigningKey::from_bytes(&[3_u8; 32]);
        let second = SigningKey::from_bytes(&[4_u8; 32]);
        let third = SigningKey::from_bytes(&[5_u8; 32]);
        let a = signed_transition("instance-1", &first, &second);
        let b = signed_transition("instance-1", &second, &third);
        assert!(verify_transition_chain_shape("instance-1", &[a.clone(), b.clone()]).is_ok());

        let disconnected = signed_transition("instance-1", &first, &third);
        assert!(verify_transition_chain_shape("instance-1", &[a, disconnected]).is_err());

        let mut malformed = serde_json::to_value(b).unwrap();
        malformed["unexpected"] = json!(true);
        assert!(serde_json::from_value::<InstanceKeyTransition>(malformed).is_err());
    }

    #[tokio::test]
    async fn startup_finishes_rotation_after_database_commit_before_key_promotion() {
        let data_dir = private_temp_dir();
        let db = identity_test_db().await;
        let (old_info, old_key) = load_or_create(&db, &data_dir).await.unwrap();
        let old_raw = *old_key.as_bytes();
        let new_key = SigningKey::from_bytes(&[42_u8; 32]);
        let transition = signed_transition(&old_info.instance_id, &old_key, &new_key);
        let staged = rotation_staged_path(&data_dir);
        let previous = rotation_previous_path(&data_dir);
        secure_file::write_new_private_key(&staged, new_key.as_bytes()).unwrap();
        secure_file::write_new_private_key(&previous, &old_raw).unwrap();
        let generation = Uuid::new_v4().to_string();
        sqlx::query("UPDATE instance_meta SET signing_public_key=?, signing_key_transitions_json=?, generation=? WHERE id=1")
            .bind(encode_public_key(&new_key))
            .bind(serde_json::to_string(&[transition]).unwrap())
            .bind(&generation)
            .execute(&db)
            .await
            .unwrap();

        // This is the crash window after the durable metadata transaction but
        // before the staged key has replaced the active key file.
        let (recovered, recovered_key) = load_or_create(&db, &data_dir).await.unwrap();
        assert_eq!(recovered.instance_id, old_info.instance_id);
        assert_eq!(recovered.server_space_id, old_info.server_space_id);
        assert_eq!(recovered.generation, generation);
        assert_eq!(recovered.signing_key_transitions.len(), 1);
        assert_eq!(recovered.signing_public_key, encode_public_key(&new_key));
        assert_eq!(recovered_key.as_bytes(), new_key.as_bytes());
        assert!(!staged.exists());
        assert!(!previous.exists());
        assert_eq!(
            encode_public_key(&SigningKey::from_bytes(
                &secure_file::read_private_key(&data_dir.join("instance-ed25519.key")).unwrap()
            )),
            recovered.signing_public_key
        );

        db.close().await;
        std::fs::remove_dir_all(data_dir).unwrap();
    }

    #[tokio::test]
    async fn sqlite_instance_identity_compare_and_swap_rejects_stale_public_key() {
        let db = identity_test_db().await;
        let instance_id = Uuid::new_v4().to_string();
        let old_public_key = encode_public_key(&SigningKey::from_bytes(&[71_u8; 32]));
        let new_public_key = encode_public_key(&SigningKey::from_bytes(&[72_u8; 32]));
        let next_generation = Uuid::new_v4().to_string();
        sqlx::query("INSERT INTO instance_meta(id,instance_id,server_space_id,generation,signing_public_key) VALUES(1,?,?,?,?)")
            .bind(&instance_id)
            .bind(Uuid::new_v4().to_string())
            .bind(Uuid::new_v4().to_string())
            .bind(&old_public_key)
            .execute(&db)
            .await
            .unwrap();

        assert!(
            compare_and_swap_identity(
                IdentityDatabase::Sqlite(&db),
                &instance_id,
                &old_public_key,
                &new_public_key,
                "[]",
                &next_generation,
            )
            .await
            .unwrap()
        );
        assert!(
            !compare_and_swap_identity(
                IdentityDatabase::Sqlite(&db),
                &instance_id,
                &old_public_key,
                &old_public_key,
                "[]",
                "stale-generation",
            )
            .await
            .unwrap()
        );
        let stored = read_identity(IdentityDatabase::Sqlite(&db))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(stored.signing_public_key, new_public_key);
        assert_eq!(stored.generation, next_generation);
        db.close().await;
    }

    struct PostgresIdentityFixture {
        admin_db: PgPool,
        db: PgPool,
        database_url: String,
        schema: String,
    }

    impl PostgresIdentityFixture {
        async fn create() -> Self {
            let database_url = disposable_postgres_url();
            let admin_db = sqlx::postgres::PgPoolOptions::new()
                .max_connections(1)
                .connect(&database_url)
                .await
                .unwrap_or_else(|_| {
                    panic!("could not connect to the disposable PostgreSQL test database")
                });
            let schema = format!("atermius_identity_{}", Uuid::new_v4().simple());
            sqlx::query(&format!("CREATE SCHEMA {schema}"))
                .execute(&admin_db)
                .await
                .expect("could not create isolated PostgreSQL test schema");
            let db = match connect_scoped_postgres_pool(&database_url, &schema).await {
                Ok(db) => db,
                Err(_) => {
                    let cleanup = sqlx::query(&format!("DROP SCHEMA {schema} CASCADE"))
                        .execute(&admin_db)
                        .await;
                    admin_db.close().await;
                    cleanup.expect("could not clean schema after opening test pool failed");
                    panic!("could not open the isolated PostgreSQL identity test pool");
                }
            };
            Self {
                admin_db,
                db,
                database_url,
                schema,
            }
        }

        async fn connect_pool(&self) -> Result<PgPool, sqlx::Error> {
            connect_scoped_postgres_pool(&self.database_url, &self.schema).await
        }

        async fn migrate(&self) -> Result<(), ApiError> {
            sqlx::query(include_str!(
                "../migrations/postgres/0003_instance_meta.sql"
            ))
            .execute(&self.db)
            .await
            .map_err(ApiError::internal)?;
            Ok(())
        }

        async fn cleanup(self) -> Result<(), sqlx::Error> {
            self.db.close().await;
            let result = sqlx::query(&format!("DROP SCHEMA {} CASCADE", self.schema))
                .execute(&self.admin_db)
                .await
                .map(|_| ());
            self.admin_db.close().await;
            result
        }
    }

    async fn connect_scoped_postgres_pool(
        database_url: &str,
        schema: &str,
    ) -> Result<PgPool, sqlx::Error> {
        let schema_for_connections = schema.to_owned();
        sqlx::postgres::PgPoolOptions::new()
            .max_connections(4)
            .after_connect(move |connection, _metadata| {
                let schema = schema_for_connections.clone();
                Box::pin(async move {
                    sqlx::query(&format!("SET search_path TO {schema}"))
                        .execute(connection)
                        .await?;
                    Ok(())
                })
            })
            .connect(database_url)
            .await
    }

    fn disposable_postgres_url() -> String {
        let database_url = std::env::var("ATERMIUS_TEST_PG_URL")
            .expect("set ATERMIUS_TEST_PG_URL to a disposable PostgreSQL database");
        let parsed = url::Url::parse(&database_url)
            .expect("ATERMIUS_TEST_PG_URL must be a valid PostgreSQL URL");
        let database_name = parsed
            .path_segments()
            .and_then(|mut segments| segments.next_back())
            .unwrap_or_default();
        assert!(
            database_name.starts_with("atermius_test_"),
            "PostgreSQL identity tests require a database whose name starts with `atermius_test_`"
        );
        database_url
    }

    fn private_child_dir(parent: &Path, name: &str) -> PathBuf {
        let path = parent.join(name);
        std::fs::create_dir(&path).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        }
        path
    }

    fn provision_shared_key(directory: &Path, name: &str, seed: u8) -> (PathBuf, [u8; 32]) {
        let shared_dir = private_child_dir(directory, name);
        let path = shared_dir.join("instance-ed25519.key");
        let key = [seed; 32];
        secure_file::write_new_private_key(&path, &key).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        (path, key)
    }

    #[tokio::test]
    #[ignore = "requires a disposable atermius_test_* PostgreSQL database in ATERMIUS_TEST_PG_URL"]
    async fn postgres_instance_identity_concurrent_nodes_share_one_persisted_identity() {
        let data_root = private_temp_dir();
        let node_a = private_child_dir(&data_root, "node-a-data");
        let node_b = private_child_dir(&data_root, "node-b-data");
        let (shared_key_path, shared_key) = provision_shared_key(&data_root, "shared-key", 91);
        let fixture = PostgresIdentityFixture::create().await;
        let outcome = async {
            fixture.migrate().await?;
            let db_a = fixture.connect_pool().await.map_err(ApiError::internal)?;
            let db_b = fixture.connect_pool().await.map_err(ApiError::internal)?;
            let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
            let first = {
                let barrier = barrier.clone();
                let key_path = shared_key_path.clone();
                async move {
                    barrier.wait().await;
                    load_or_create_postgres(&db_a, &key_path)
                        .await
                        .map(|(info, key)| (info, *key.as_bytes()))
                }
            };
            let second = {
                let barrier = barrier.clone();
                let key_path = shared_key_path.clone();
                async move {
                    barrier.wait().await;
                    load_or_create_postgres(&db_b, &key_path)
                        .await
                        .map(|(info, key)| (info, *key.as_bytes()))
                }
            };
            let (first, second) = tokio::join!(first, second);
            let first = first?;
            let second = second?;
            let row_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_meta")
                .fetch_one(&fixture.db)
                .await
                .map_err(ApiError::internal)?;
            let node_local_keys_absent = !node_a.join("instance-ed25519.key").exists()
                && !node_b.join("instance-ed25519.key").exists();
            let database = IdentityDatabase::Postgres(&fixture.db);
            let next_key_a = SigningKey::from_bytes(&[77_u8; 32]);
            let next_key_b = SigningKey::from_bytes(&[78_u8; 32]);
            let next_public_a = encode_public_key(&next_key_a);
            let next_public_b = encode_public_key(&next_key_b);
            let next_generation_a = Uuid::new_v4().to_string();
            let next_generation_b = Uuid::new_v4().to_string();
            let (updated_a, updated_b) = tokio::join!(
                compare_and_swap_identity(
                    database,
                    &first.0.instance_id,
                    &first.0.signing_public_key,
                    &next_public_a,
                    "[]",
                    &next_generation_a,
                ),
                compare_and_swap_identity(
                    database,
                    &first.0.instance_id,
                    &first.0.signing_public_key,
                    &next_public_b,
                    "[]",
                    &next_generation_b,
                ),
            );
            let updated_a = updated_a?;
            let updated_b = updated_b?;
            let stale_update = compare_and_swap_identity(
                database,
                &first.0.instance_id,
                &first.0.signing_public_key,
                &first.0.signing_public_key,
                "[]",
                &first.0.generation,
            )
            .await?;
            let stored = read_identity(database)
                .await?
                .ok_or_else(|| ApiError::internal("PostgreSQL test identity disappeared"))?;
            let (winning_public, winning_generation) = if updated_a {
                (next_public_a, next_generation_a)
            } else {
                (next_public_b, next_generation_b)
            };
            Ok::<_, ApiError>((
                first,
                second,
                row_count,
                node_local_keys_absent,
                updated_a,
                updated_b,
                stale_update,
                winning_public,
                winning_generation,
                stored,
            ))
        }
        .await;
        let cleanup = fixture.cleanup().await;
        std::fs::remove_dir_all(&data_root).expect("could not clean shared identity key fixture");
        cleanup.expect("could not remove isolated PostgreSQL identity schema");

        let (
            (first_info, first_key),
            (second_info, second_key),
            row_count,
            node_local_keys_absent,
            updated_a,
            updated_b,
            stale_update,
            winning_public,
            winning_generation,
            stored,
        ) = outcome.expect("concurrent PostgreSQL instance identity initialization failed");
        assert_ne!(node_a, node_b);
        assert_eq!(first_info.instance_id, second_info.instance_id);
        assert_eq!(first_info.server_space_id, second_info.server_space_id);
        assert_eq!(first_info.generation, second_info.generation);
        assert_eq!(
            first_info.signing_public_key,
            second_info.signing_public_key
        );
        assert_eq!(
            first_info.signing_public_key,
            encode_public_key(&SigningKey::from_bytes(&shared_key))
        );
        assert_eq!(first_key, shared_key);
        assert_eq!(second_key, shared_key);
        assert_eq!(row_count, 1);
        assert!(node_local_keys_absent);
        assert_ne!(updated_a, updated_b);
        assert!(!stale_update);
        assert_eq!(stored.instance_id, first_info.instance_id);
        assert_eq!(stored.signing_public_key, winning_public);
        assert_eq!(stored.generation, winning_generation);
    }

    #[tokio::test]
    #[ignore = "requires a disposable atermius_test_* PostgreSQL database in ATERMIUS_TEST_PG_URL"]
    async fn postgres_instance_identity_reopens_from_another_node_data_directory() {
        let data_root = private_temp_dir();
        let node_a = private_child_dir(&data_root, "node-a-data");
        let node_b = private_child_dir(&data_root, "node-b-data");
        let (shared_key_path, shared_key) = provision_shared_key(&data_root, "shared-key", 92);
        let fixture = PostgresIdentityFixture::create().await;
        let outcome = async {
            fixture.migrate().await?;
            let first = load_or_create_postgres(&fixture.db, &shared_key_path).await?;
            let db_b = fixture.connect_pool().await.map_err(ApiError::internal)?;
            let reopened = load_or_create_postgres(&db_b, &shared_key_path).await?;
            let row_count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM instance_meta")
                .fetch_one(&db_b)
                .await
                .map_err(ApiError::internal)?;
            let node_local_keys_absent = !node_a.join("instance-ed25519.key").exists()
                && !node_b.join("instance-ed25519.key").exists();
            db_b.close().await;
            Ok::<_, ApiError>((
                first.0,
                *first.1.as_bytes(),
                reopened.0,
                *reopened.1.as_bytes(),
                row_count,
                node_local_keys_absent,
            ))
        }
        .await;
        let cleanup = fixture.cleanup().await;
        std::fs::remove_dir_all(&data_root).expect("could not clean shared identity key fixture");
        cleanup.expect("could not remove isolated PostgreSQL identity schema");

        let (first, first_key, reopened, reopened_key, row_count, node_local_keys_absent) =
            outcome.expect("PostgreSQL instance identity reopen failed");
        assert_ne!(node_a, node_b);
        assert_eq!(first.instance_id, reopened.instance_id);
        assert_eq!(first.server_space_id, reopened.server_space_id);
        assert_eq!(first.generation, reopened.generation);
        assert_eq!(first.signing_public_key, reopened.signing_public_key);
        assert_eq!(
            first.signing_public_key,
            encode_public_key(&SigningKey::from_bytes(&shared_key))
        );
        assert_eq!(first_key, shared_key);
        assert_eq!(reopened_key, shared_key);
        assert_eq!(row_count, 1);
        assert!(node_local_keys_absent);
    }

    #[tokio::test]
    #[ignore = "requires a disposable atermius_test_* PostgreSQL database in ATERMIUS_TEST_PG_URL"]
    async fn postgres_instance_identity_rejects_a_shared_key_mismatch_without_mutation() {
        let data_root = private_temp_dir();
        let (shared_key_path, _) = provision_shared_key(&data_root, "shared-key", 93);
        let (wrong_key_path, _) = provision_shared_key(&data_root, "wrong-key", 94);
        let fixture = PostgresIdentityFixture::create().await;
        let outcome = async {
            fixture.migrate().await?;
            let (created, _) = load_or_create_postgres(&fixture.db, &shared_key_path).await?;
            let mismatch = load_or_create_postgres(&fixture.db, &wrong_key_path).await;
            let stored = read_identity(IdentityDatabase::Postgres(&fixture.db))
                .await?
                .ok_or_else(|| ApiError::internal("PostgreSQL test identity disappeared"))?;
            Ok::<_, ApiError>((created, mismatch.is_err(), stored))
        }
        .await;
        let cleanup = fixture.cleanup().await;
        std::fs::remove_dir_all(&data_root).expect("could not clean shared identity key fixture");
        cleanup.expect("could not remove isolated PostgreSQL identity schema");

        let (created, rejected_mismatch, stored) =
            outcome.expect("PostgreSQL instance identity mismatch check failed");
        assert!(rejected_mismatch, "mismatched shared key must fail closed");
        assert_eq!(stored.instance_id, created.instance_id);
        assert_eq!(stored.server_space_id, created.server_space_id);
        assert_eq!(stored.generation, created.generation);
        assert_eq!(stored.signing_public_key, created.signing_public_key);
    }
}

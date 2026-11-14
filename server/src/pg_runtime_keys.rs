//! Runtime-only key loading for a future PostgreSQL-backed service state.
//!
//! This module deliberately accepts the provisioned shared auth-rate key path
//! directly. It does not know about a node data directory, create key files, or
//! select a local fallback, so each process must be configured with the same
//! operator-provisioned secret explicitly.

use std::path::Path;

use ed25519_dalek::SigningKey;
use hkdf::Hkdf;
use sha2::Sha256;
use zeroize::Zeroizing;

use crate::{ApiError, secure_file};

const AUTH_RATE_KEY_BYTES: usize = 32;

/// Secret material needed by PostgreSQL-backed runtime services.
///
/// The auth-rate key is shared by all nodes through an explicitly configured
/// owner-only file. The cursor key is derived from the singleton instance
/// signing key using the same HKDF contract as the current SQLite startup.
/// Both values are cleared when this value is dropped.
pub(crate) struct PgRuntimeKeys {
    auth_rate_key: Zeroizing<[u8; AUTH_RATE_KEY_BYTES]>,
    cursor_key: Zeroizing<[u8; 32]>,
}

impl PgRuntimeKeys {
    /// Loads an explicitly provisioned shared auth-rate key and derives the
    /// sync cursor key for the persisted instance identity.
    ///
    /// `shared_auth_rate_key_file` must refer to an existing owner-only,
    /// regular, single-linked 32-byte file. This method never creates a file
    /// and never consults node-local state.
    pub(crate) fn load(
        shared_auth_rate_key_file: &Path,
        instance_signing_key: &SigningKey,
    ) -> Result<Self, ApiError> {
        let auth_rate_key = read_shared_auth_rate_key(shared_auth_rate_key_file)?;
        let cursor_key = derive_cursor_key(instance_signing_key)?;
        Ok(Self {
            auth_rate_key,
            cursor_key,
        })
    }

    pub(crate) fn auth_rate_key(&self) -> &[u8; AUTH_RATE_KEY_BYTES] {
        &self.auth_rate_key
    }

    pub(crate) fn cursor_key(&self) -> &[u8; 32] {
        &self.cursor_key
    }
}

fn read_shared_auth_rate_key(
    shared_auth_rate_key_file: &Path,
) -> Result<Zeroizing<[u8; AUTH_RATE_KEY_BYTES]>, ApiError> {
    let bytes = secure_file::read_private_secret_file(
        shared_auth_rate_key_file,
        AUTH_RATE_KEY_BYTES as u64,
    )?;
    if bytes.len() != AUTH_RATE_KEY_BYTES {
        return Err(ApiError::internal(
            "shared auth-rate key must be a regular 32-byte file",
        ));
    }
    let mut key = Zeroizing::new([0_u8; AUTH_RATE_KEY_BYTES]);
    key.copy_from_slice(&bytes);
    Ok(key)
}

fn derive_cursor_key(instance_signing_key: &SigningKey) -> Result<Zeroizing<[u8; 32]>, ApiError> {
    // Preserve the existing open_state derivation contract exactly. All PG
    // nodes must use the persisted shared instance signing key for this value.
    let mut cursor_key = Zeroizing::new([0_u8; 32]);
    Hkdf::<Sha256>::new(Some(b"atermius-instance"), instance_signing_key.as_bytes())
        .expand(b"atermius/cursor-hmac/v1", &mut *cursor_key)
        .map_err(ApiError::internal)?;
    Ok(cursor_key)
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use ed25519_dalek::SigningKey;
    use uuid::Uuid;

    use super::PgRuntimeKeys;
    use crate::secure_file;

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("atermius-pg-runtime-keys-{}", Uuid::new_v4()));
            secure_file::create_private_data_dir(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn independently_constructed_nodes_with_shared_inputs_derive_identical_keys() {
        let shared = TestDirectory::new();
        let node_a = TestDirectory::new();
        let node_b = TestDirectory::new();
        let shared_key_path = shared.path().join("shared-auth-rate.key");
        secure_file::write_new_private_key(&shared_key_path, &[0x41; 32]).unwrap();

        let instance_signing_key = SigningKey::from_bytes(&[0x62; 32]);
        let node_a_keys = PgRuntimeKeys::load(&shared_key_path, &instance_signing_key).unwrap();
        let node_b_keys = PgRuntimeKeys::load(&shared_key_path, &instance_signing_key).unwrap();

        assert_eq!(node_a_keys.auth_rate_key(), node_b_keys.auth_rate_key());
        assert_eq!(node_a_keys.cursor_key(), node_b_keys.cursor_key());
        // Keep distinct local node contexts in the fixture to document that
        // the helper has no local-data-dir input or local fallback behavior.
        assert_ne!(node_a.path(), node_b.path());
    }

    #[test]
    fn missing_shared_auth_key_fails_closed_without_creating_a_file() {
        let directory = TestDirectory::new();
        let missing_path = directory.path().join("shared-auth-rate.key");
        let signing_key = SigningKey::from_bytes(&[0x63; 32]);

        assert!(PgRuntimeKeys::load(&missing_path, &signing_key).is_err());
        assert!(!missing_path.exists());
    }

    #[cfg(unix)]
    #[test]
    fn unsafe_shared_auth_key_fails_closed_without_replacing_the_file() {
        use std::os::unix::fs::PermissionsExt;

        let directory = TestDirectory::new();
        let unsafe_path = directory.path().join("shared-auth-rate.key");
        fs::write(&unsafe_path, [0x74; 32]).unwrap();
        fs::set_permissions(&unsafe_path, fs::Permissions::from_mode(0o644)).unwrap();
        let signing_key = SigningKey::from_bytes(&[0x64; 32]);

        assert!(PgRuntimeKeys::load(&unsafe_path, &signing_key).is_err());
        assert_eq!(fs::read(&unsafe_path).unwrap(), [0x74; 32]);
        assert_eq!(
            fs::symlink_metadata(&unsafe_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o644
        );
    }

    #[test]
    fn cursor_key_tracks_instance_signing_key_while_auth_rate_key_is_independent() {
        let directory = TestDirectory::new();
        let shared_key_path = directory.path().join("shared-auth-rate.key");
        secure_file::write_new_private_key(&shared_key_path, &[0x75; 32]).unwrap();

        let first =
            PgRuntimeKeys::load(&shared_key_path, &SigningKey::from_bytes(&[0x65; 32])).unwrap();
        let second =
            PgRuntimeKeys::load(&shared_key_path, &SigningKey::from_bytes(&[0x66; 32])).unwrap();

        assert_eq!(first.auth_rate_key(), second.auth_rate_key());
        assert_ne!(first.cursor_key(), second.cursor_key());
    }
}

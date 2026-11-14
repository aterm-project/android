use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};

use rand::RngCore;
use uuid::Uuid;
use zeroize::Zeroizing;

use crate::ApiError;

/// Creates a missing mode-0700 data directory before SQLite or key files are
/// opened, and requires an existing path to already meet that boundary.
/// Keeping it owner-only also protects SQLite WAL/SHM and lock files.
pub(crate) fn create_private_data_dir(path: &Path) -> Result<(), ApiError> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).map_err(ApiError::internal)?;
    match create_private_dir(path) {
        Ok(()) => {
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(path, fs::Permissions::from_mode(0o700))
                    .map_err(ApiError::internal)?;
            }
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(ApiError::internal(error)),
    }
    secure_existing_data_dir(path)
}

fn create_private_dir(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        let mut builder = fs::DirBuilder::new();
        builder.mode(0o700).create(path)
    }
    #[cfg(not(unix))]
    {
        fs::create_dir(path)
    }
}

/// Requires an existing real directory and removes group/other access on Unix.
/// The final configured path may not be a symlink.
pub(crate) fn secure_existing_data_dir(path: &Path) -> Result<(), ApiError> {
    let metadata = fs::symlink_metadata(path).map_err(ApiError::internal)?;
    if !metadata.file_type().is_dir() {
        return Err(ApiError::internal(
            "instance data path must be an existing real directory",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        use std::os::unix::fs::PermissionsExt;
        let canonical = fs::canonicalize(path).map_err(ApiError::internal)?;
        let mode = metadata.permissions().mode();
        let system_paths = ["/", "/tmp", "/var/tmp", "/home", "/root", "/var/lib"];
        if system_paths
            .iter()
            .any(|system_path| canonical == Path::new(system_path))
            || mode & 0o7777 != 0o700
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(ApiError::internal(
                "instance data directory must be a dedicated owner-only directory with mode 0700; prepare it before starting the server",
            ));
        }
        validate_private_directory_ancestors(&canonical)?;
    }
    Ok(())
}

#[cfg(unix)]
fn validate_private_directory_ancestors(path: &Path) -> Result<(), ApiError> {
    use std::os::unix::fs::PermissionsExt;

    let mut ancestor = path.parent();
    while let Some(directory) = ancestor {
        let metadata = fs::metadata(directory).map_err(ApiError::internal)?;
        let mode = metadata.permissions().mode();
        // Sticky shared directories such as /tmp protect the owner's entry
        // from other users renaming it. Other writable ancestors let them
        // replace the path before SQLite opens files beneath it.
        if mode & 0o022 != 0 && mode & 0o1000 == 0 {
            return Err(ApiError::internal(
                "instance data directory has a group/world-writable non-sticky ancestor",
            ));
        }
        ancestor = directory.parent();
    }
    Ok(())
}

/// Reads a 32-byte private key or publishes a newly generated one atomically.
/// The temporary file is private from its first byte, and a hard link makes
/// the complete, fsynced key visible in one operation to concurrent starters.
pub(crate) fn read_or_create_private_key(path: &Path) -> Result<[u8; 32], ApiError> {
    match read_existing(path) {
        Ok(key) => return Ok(key),
        Err(ReadKeyError::Missing) => {}
        Err(ReadKeyError::Invalid(error)) => return Err(ApiError::internal(error)),
    }

    let parent = path
        .parent()
        .ok_or_else(|| ApiError::internal("private key path has no parent directory"))?;
    let file_name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| ApiError::internal("private key path is invalid"))?;
    let mut key = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut key);

    for _ in 0..4 {
        let temporary = parent.join(format!(".{file_name}.{}.tmp", Uuid::new_v4()));
        match create_private_file(&temporary) {
            Ok(mut file) => {
                if let Err(error) = set_private_mode(&file) {
                    drop(file);
                    let _ = fs::remove_file(&temporary);
                    return Err(error);
                }
                if let Err(error) = file.write_all(&key).and_then(|()| file.sync_all()) {
                    let _ = fs::remove_file(&temporary);
                    return Err(ApiError::internal(error));
                }
                drop(file);
                match fs::hard_link(&temporary, path) {
                    Ok(()) => {
                        let _ = fs::remove_file(&temporary);
                        return read_existing(path)
                            .map_err(|error| ApiError::internal(error.into_display()));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                        let _ = fs::remove_file(&temporary);
                        return read_existing(path)
                            .map_err(|error| ApiError::internal(error.into_display()));
                    }
                    Err(error) => {
                        let _ = fs::remove_file(&temporary);
                        return Err(ApiError::internal(error));
                    }
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(ApiError::internal(error)),
        }
    }

    Err(ApiError::internal(
        "could not create a unique temporary private key file",
    ))
}

/// Reads an existing owner-only 32-byte key without creating or following a
/// symlink. Used for operator-held backup keys and existing instance keys.
pub(crate) fn read_private_key(path: &Path) -> Result<[u8; 32], ApiError> {
    read_existing(path).map_err(|error| ApiError::internal(error.into_display()))
}

/// Reads an existing owner-only 32-byte key into a zeroizing buffer. Offline
/// key-rotation tools should use this instead of `read_private_key` so both
/// the read buffer and the returned key are cleared when dropped.
pub(crate) fn read_private_key_zeroizing(path: &Path) -> Result<Zeroizing<[u8; 32]>, ApiError> {
    let bytes = read_private_secret_file(path, 32)?;
    if bytes.len() != 32 {
        return Err(ApiError::internal(
            "private key must be a regular 32-byte file",
        ));
    }
    let mut key = Zeroizing::new([0_u8; 32]);
    key.copy_from_slice(&bytes);
    Ok(key)
}

/// Reads a small owner-only secret document without following links. The
/// returned byte buffer is zeroized when dropped; callers must separately
/// zeroize parsed string fields and must never log parse errors or contents.
pub(crate) fn read_private_secret_file(
    path: &Path,
    max_bytes: u64,
) -> Result<Zeroizing<Vec<u8>>, ApiError> {
    let file = open_no_follow_read(path)
        .map_err(|_| ApiError::internal("private secret file is unavailable or unsafe"))?;
    let metadata = file
        .metadata()
        .map_err(|_| ApiError::internal("private secret file is unavailable or unsafe"))?;
    if !metadata.file_type().is_file() || metadata.len() == 0 || metadata.len() > max_bytes {
        return Err(ApiError::internal(
            "private secret file has an invalid type or size",
        ));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let mode = metadata.permissions().mode();
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.nlink() != 1
            || mode & 0o077 != 0
            || mode & 0o111 != 0
            || mode & 0o400 == 0
        {
            return Err(ApiError::internal(
                "private secret file must be owner-only, readable, and single-linked",
            ));
        }
    }
    let mut bytes = Zeroizing::new(Vec::with_capacity(metadata.len() as usize));
    let mut reader = file;
    reader
        .read_to_end(&mut bytes)
        .map_err(|_| ApiError::internal("private secret file could not be read"))?;
    if bytes.len() as u64 != metadata.len() || bytes.len() as u64 > max_bytes {
        return Err(ApiError::internal(
            "private secret file changed while reading",
        ));
    }
    Ok(bytes)
}

pub(crate) fn read_private_key_if_exists(path: &Path) -> Result<Option<[u8; 32]>, ApiError> {
    match read_existing(path) {
        Ok(key) => Ok(Some(key)),
        Err(ReadKeyError::Missing) => Ok(None),
        Err(ReadKeyError::Invalid(error)) => Err(ApiError::internal(error)),
    }
}

/// Publishes a new owner-only key file without replacing an existing path.
/// The key becomes visible only after all 32 bytes have been written and
/// fsynced. Used by the offline instance-key rotation journal.
pub(crate) fn write_new_private_key(path: &Path, key: &[u8; 32]) -> Result<(), ApiError> {
    let mut file = create_private_file(path).map_err(ApiError::internal)?;
    set_private_mode(&file)?;
    if let Err(error) = file.write_all(key).and_then(|()| file.sync_all()) {
        drop(file);
        let _ = fs::remove_file(path);
        return Err(ApiError::internal(error));
    }
    drop(file);
    sync_parent(path)?;
    Ok(())
}

/// Promotes a staged owner-only key file over the active file. Unix rename is
/// atomic. On platforms where rename cannot replace an existing file, callers
/// must first preserve the active key in the rotation journal's previous-key
/// file; startup can then finish the promotion after an interrupted command.
pub(crate) fn promote_private_key(staged: &Path, active: &Path) -> Result<(), ApiError> {
    #[cfg(windows)]
    if active.exists() {
        fs::remove_file(active).map_err(ApiError::internal)?;
    }
    fs::rename(staged, active).map_err(ApiError::internal)?;
    sync_parent(active)
}

pub(crate) fn remove_private_file_if_exists(path: &Path) -> Result<(), ApiError> {
    match fs::remove_file(path) {
        Ok(()) => sync_parent(path),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(ApiError::internal(error)),
    }
}

fn sync_parent(path: &Path) -> Result<(), ApiError> {
    #[cfg(not(unix))]
    {
        let _ = path;
        return Ok(());
    }
    #[cfg(unix)]
    {
        let parent = path
            .parent()
            .ok_or_else(|| ApiError::internal("private key path has no parent directory"))?;
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .map_err(ApiError::internal)
    }
}

enum ReadKeyError {
    Missing,
    Invalid(std::io::Error),
}

impl ReadKeyError {
    fn into_display(self) -> std::io::Error {
        match self {
            Self::Missing => std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "private key disappeared during initialization",
            ),
            Self::Invalid(error) => error,
        }
    }
}

fn read_existing(path: &Path) -> Result<[u8; 32], ReadKeyError> {
    let file = match open_no_follow_read(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Err(ReadKeyError::Missing);
        }
        Err(error) => return Err(ReadKeyError::Invalid(error)),
    };
    let metadata = file.metadata().map_err(ReadKeyError::Invalid)?;
    if !metadata.file_type().is_file() || metadata.len() != 32 {
        return Err(ReadKeyError::Invalid(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "private key must be a regular 32-byte file",
        )));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = metadata.permissions().mode();
        if mode & 0o077 != 0 || mode & 0o111 != 0 || mode & 0o700 == 0 {
            return Err(ReadKeyError::Invalid(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "private key file has group or other permissions; set mode 0600",
            )));
        }
    }
    let mut bytes = [0_u8; 32];
    let mut reader = file;
    reader
        .read_exact(&mut bytes)
        .map_err(ReadKeyError::Invalid)?;
    Ok(bytes)
}

fn create_private_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    }
    options.open(path)
}

#[cfg(unix)]
fn set_private_mode(file: &File) -> Result<(), ApiError> {
    use std::os::unix::fs::PermissionsExt;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))
        .map_err(ApiError::internal)
}

#[cfg(not(unix))]
fn set_private_mode(_: &File) -> Result<(), ApiError> {
    Ok(())
}

fn open_no_follow_read(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // A private key path must be a regular file. Nonblocking open lets us
        // reject a FIFO at the metadata check without waiting for a writer.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    options.open(path)
}

#[cfg(all(test, unix))]
mod tests {
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
        path::{Path, PathBuf},
        thread,
    };

    use super::{create_private_data_dir, read_or_create_private_key, secure_existing_data_dir};

    fn test_dir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("atermius-private-key-{}", Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        path
    }

    use uuid::Uuid;

    #[test]
    fn creates_mode_0600_key_and_reuses_it() {
        let directory = test_dir();
        let path = directory.join("private.key");
        let created = read_or_create_private_key(&path).unwrap();
        assert_eq!(read_or_create_private_key(&path).unwrap(), created);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn concurrent_initializers_publish_one_complete_key() {
        let directory = test_dir();
        let path = directory.join("private.key");
        let workers = (0..8)
            .map(|_| {
                let path = path.clone();
                thread::spawn(move || read_or_create_private_key(&path).unwrap())
            })
            .collect::<Vec<_>>();
        let keys = workers
            .into_iter()
            .map(|worker| worker.join().unwrap())
            .collect::<Vec<_>>();
        assert!(keys.iter().all(|key| key == &keys[0]));
        assert_eq!(fs::metadata(&path).unwrap().len(), 32);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_symlinks_and_group_or_world_readable_legacy_files() {
        let directory = test_dir();
        let target = directory.join("target.key");
        fs::write(&target, [3_u8; 32]).unwrap();
        let link = directory.join("link.key");
        symlink(&target, &link).unwrap();
        assert!(read_or_create_private_key(&link).is_err());

        let legacy = directory.join("legacy.key");
        fs::write(&legacy, [4_u8; 32]).unwrap();
        fs::set_permissions(&legacy, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_or_create_private_key(&legacy).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unsafe_existing_data_directory_is_rejected_without_chmod() {
        let directory = test_dir();
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(create_private_data_dir(&directory).is_err());
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o755
        );
        assert!(secure_existing_data_dir(Path::new("/")).is_err());

        let target = directory.join("target");
        fs::create_dir(&target).unwrap();
        let link = directory.join("data-link");
        symlink(&target, &link).unwrap();
        assert!(secure_existing_data_dir(&link).is_err());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn newly_created_data_directory_is_owner_only() {
        let parent = test_dir();
        let data_dir = parent.join("nested").join("instance");
        create_private_data_dir(&data_dir).unwrap();
        assert_eq!(
            fs::metadata(&data_dir).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::remove_dir_all(parent).unwrap();
    }

    #[test]
    fn data_directory_rejects_a_non_sticky_shared_ancestor_without_changing_it() {
        let parent = test_dir();
        fs::set_permissions(&parent, fs::Permissions::from_mode(0o777)).unwrap();
        let data_dir = parent.join("instance");
        assert!(create_private_data_dir(&data_dir).is_err());
        assert_eq!(
            fs::metadata(&parent).unwrap().permissions().mode() & 0o777,
            0o777
        );
        fs::remove_dir_all(parent).unwrap();
    }
}

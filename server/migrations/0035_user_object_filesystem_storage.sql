-- Widen the external object backend discriminator from SQLite/S3 to also
-- allow a private filesystem volume. Rebuild the small catalogue tables so
-- their CHECK constraints remain enforced on every SQLite connection.

CREATE TABLE blob_objects_fs (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    object_id TEXT NOT NULL,
    bytes BLOB NOT NULL,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    created_at TEXT NOT NULL,
    gc_after INTEGER,
    storage_backend TEXT NOT NULL DEFAULT 'sqlite'
        CHECK(storage_backend IN ('sqlite','s3','filesystem')),
    storage_key TEXT,
    storage_store_id TEXT,
    storage_state TEXT NOT NULL DEFAULT 'available'
        CHECK(storage_state IN ('available','deleting')),
    PRIMARY KEY(vault_id, object_id)
);
INSERT INTO blob_objects_fs(
    vault_id,object_id,bytes,size,sha256,created_at,gc_after,
    storage_backend,storage_key,storage_store_id,storage_state
)
SELECT
    vault_id,object_id,bytes,size,sha256,created_at,gc_after,
    storage_backend,storage_key,storage_store_id,storage_state
FROM blob_objects;

CREATE TABLE object_references_fs (
    vault_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    PRIMARY KEY(vault_id, revision_id, object_id),
    FOREIGN KEY(vault_id, object_id)
        REFERENCES blob_objects_fs(vault_id, object_id) ON DELETE CASCADE
);
INSERT INTO object_references_fs(vault_id,revision_id,object_id)
SELECT vault_id,revision_id,object_id FROM object_references;

DROP TABLE object_references;
DROP TABLE blob_objects;
ALTER TABLE blob_objects_fs RENAME TO blob_objects;
ALTER TABLE object_references_fs RENAME TO object_references;
CREATE INDEX idx_blob_objects_gc_after
    ON blob_objects(gc_after)
    WHERE gc_after IS NOT NULL;

-- upload_chunks has a cascading foreign key to uploads, so rebuild both tables
-- together to preserve all in-flight reservations and uploaded chunks.
CREATE TABLE uploads_fs (
    upload_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id),
    object_id TEXT NOT NULL,
    expected_size INTEGER NOT NULL,
    expected_sha256 TEXT NOT NULL,
    chunk_size INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'open',
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL,
    storage_backend TEXT NOT NULL DEFAULT 'sqlite'
        CHECK(storage_backend IN ('sqlite','s3','filesystem')),
    storage_store_id TEXT
);
INSERT INTO uploads_fs(
    upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,
    chunk_size,state,expires_at,created_at,storage_backend,storage_store_id
)
SELECT
    upload_id,vault_id,user_id,object_id,expected_size,expected_sha256,
    chunk_size,state,expires_at,created_at,storage_backend,storage_store_id
FROM uploads;

CREATE TABLE upload_chunks_fs (
    upload_id TEXT NOT NULL REFERENCES uploads_fs(upload_id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    bytes BLOB NOT NULL,
    sha256 TEXT NOT NULL,
    PRIMARY KEY(upload_id, chunk_index)
);
INSERT INTO upload_chunks_fs(upload_id,chunk_index,bytes,sha256)
SELECT upload_id,chunk_index,bytes,sha256 FROM upload_chunks;

DROP TABLE upload_chunks;
DROP TABLE uploads;
ALTER TABLE uploads_fs RENAME TO uploads;
ALTER TABLE upload_chunks_fs RENAME TO upload_chunks;

-- External deletes must survive account/Vault cascades. Permit filesystem
-- rows in the same generic durable queue while retaining store/key uniqueness.
CREATE TABLE object_delete_queue_fs (
    queue_id TEXT PRIMARY KEY,
    storage_backend TEXT NOT NULL CHECK(storage_backend IN ('s3','filesystem')),
    storage_key TEXT NOT NULL,
    storage_store_id TEXT NOT NULL,
    expected_size INTEGER NOT NULL CHECK(expected_size > 0),
    expected_sha256 TEXT NOT NULL CHECK(length(expected_sha256)=64),
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK(state IN ('pending','retry_wait','quarantined')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
    next_attempt_at INTEGER NOT NULL,
    last_failure_category TEXT
        CHECK(last_failure_category IS NULL OR last_failure_category IN
            ('remote_unavailable','integrity_mismatch')),
    created_at TEXT NOT NULL,
    UNIQUE(storage_store_id,storage_key)
);
INSERT INTO object_delete_queue_fs(
    queue_id,storage_backend,storage_key,storage_store_id,expected_size,
    expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at
)
SELECT
    queue_id,storage_backend,storage_key,storage_store_id,expected_size,
    expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at
FROM object_delete_queue;
DROP TABLE object_delete_queue;
ALTER TABLE object_delete_queue_fs RENAME TO object_delete_queue;
CREATE INDEX idx_object_delete_queue_due
    ON object_delete_queue(state,next_attempt_at,created_at,queue_id);

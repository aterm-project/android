ALTER TABLE blob_objects
    ADD COLUMN storage_backend TEXT NOT NULL DEFAULT 'sqlite'
        CHECK(storage_backend IN ('sqlite','s3'));
ALTER TABLE blob_objects ADD COLUMN storage_key TEXT;
ALTER TABLE blob_objects ADD COLUMN storage_store_id TEXT;
ALTER TABLE blob_objects
    ADD COLUMN storage_state TEXT NOT NULL DEFAULT 'available'
        CHECK(storage_state IN ('available','deleting'));

ALTER TABLE uploads
    ADD COLUMN storage_backend TEXT NOT NULL DEFAULT 'sqlite'
        CHECK(storage_backend IN ('sqlite','s3'));
ALTER TABLE uploads ADD COLUMN storage_store_id TEXT;

-- This queue deliberately has no Vault/user foreign key: purge transactions
-- must durably retain S3 deletion work after the owning Vault is cascaded.
-- Keeping the deterministic key, size and digest lets retries confirm they
-- are deleting the intended immutable ciphertext object.
CREATE TABLE object_delete_queue (
    queue_id TEXT PRIMARY KEY,
    storage_backend TEXT NOT NULL CHECK(storage_backend='s3'),
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

CREATE INDEX idx_object_delete_queue_due
    ON object_delete_queue(state,next_attempt_at,created_at,queue_id);

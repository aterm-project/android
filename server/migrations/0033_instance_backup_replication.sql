-- Durable ciphertext replication outbox. An outbox row is inserted before a
-- generated archive snapshot so a restored DB can reconcile the same object
-- key even though the snapshot predates upload completion.
CREATE TABLE instance_backup_replications (
    archive_id TEXT PRIMARY KEY
        CHECK (length(archive_id) = 36
            AND archive_id = lower(archive_id)
            AND substr(archive_id,9,1) = '-'
            AND substr(archive_id,14,1) = '-'
            AND substr(archive_id,19,1) = '-'
            AND substr(archive_id,24,1) = '-'
            AND replace(archive_id,'-','') NOT GLOB '*[^0-9a-f]*'),
    origin TEXT NOT NULL CHECK (origin IN ('manual','scheduled')),
    created_at TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN (
        'pending_archive','pending','running','retry_wait','succeeded','interrupted','failed'
    )),
    archive_bytes INTEGER CHECK (archive_bytes IS NULL OR archive_bytes > 0),
    archive_sha256 TEXT CHECK (archive_sha256 IS NULL OR
        (length(archive_sha256) = 64 AND archive_sha256 NOT GLOB '*[^0-9a-f]*')),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at INTEGER,
    started_at INTEGER,
    last_attempt_at INTEGER,
    completed_at INTEGER,
    failure_category TEXT CHECK (failure_category IS NULL OR failure_category IN (
        'archive_unavailable','credentials_invalid','remote_unavailable',
        'remote_integrity_mismatch','replication_failed'
    )),
    multipart_upload_id TEXT,
    CHECK ((archive_bytes IS NULL) = (archive_sha256 IS NULL)),
    CHECK (status != 'succeeded' OR
        (archive_bytes IS NOT NULL AND archive_sha256 IS NOT NULL
            AND completed_at IS NOT NULL AND failure_category IS NULL
            AND next_attempt_at IS NULL AND multipart_upload_id IS NULL)),
    CHECK (status != 'pending_archive' OR
        (archive_bytes IS NULL AND archive_sha256 IS NULL AND attempt_count = 0)),
    CHECK (status != 'running' OR
        (started_at IS NOT NULL AND next_attempt_at IS NULL
            AND failure_category IS NULL)),
    CHECK (status != 'retry_wait' OR
        (next_attempt_at IS NOT NULL AND failure_category IS NOT NULL)),
    CHECK (status != 'pending' OR
        (archive_bytes IS NOT NULL AND archive_sha256 IS NOT NULL
            AND next_attempt_at IS NOT NULL AND failure_category IS NULL)),
    CHECK (status != 'interrupted' OR next_attempt_at IS NOT NULL)
);

CREATE UNIQUE INDEX idx_instance_backup_replications_one_running
    ON instance_backup_replications((1))
    WHERE status = 'running';

CREATE INDEX idx_instance_backup_replications_due
    ON instance_backup_replications(status,next_attempt_at,created_at,archive_id);

-- Restore requests now bind the selected source. Existing rows remain local.
ALTER TABLE instance_admin_jobs
    ADD COLUMN archive_source TEXT NOT NULL DEFAULT 'local'
    CHECK (archive_source IN ('local','replica'));

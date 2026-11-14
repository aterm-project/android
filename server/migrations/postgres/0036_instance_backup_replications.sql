-- Shared, privacy-safe durable outbox for encrypted instance archive
-- replication. No provider credentials, endpoints, bucket names, or object
-- paths are stored in this table.
CREATE TABLE instance_backup_replications (
    archive_id TEXT NOT NULL,
    origin TEXT NOT NULL
        CONSTRAINT instance_backup_replications_origin_check
        CHECK (origin IN ('manual', 'scheduled')),
    created_at TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL
        CONSTRAINT instance_backup_replications_status_check
        CHECK (status IN (
        'pending_archive', 'pending', 'running', 'retry_wait', 'succeeded',
        'interrupted', 'failed'
    )),
    archive_bytes BIGINT
        CONSTRAINT instance_backup_replications_archive_bytes_check
        CHECK (archive_bytes IS NULL OR archive_bytes > 0),
    archive_sha256 TEXT
        CONSTRAINT instance_backup_replications_archive_sha256_check
        CHECK (
        archive_sha256 IS NULL OR archive_sha256 ~ '^[0-9a-f]{64}$'
    ),
    attempt_count BIGINT NOT NULL DEFAULT 0
        CONSTRAINT instance_backup_replications_attempt_count_check
        CHECK (attempt_count >= 0),
    next_attempt_at TIMESTAMPTZ,
    started_at TIMESTAMPTZ,
    last_attempt_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    failure_category TEXT
        CONSTRAINT instance_backup_replications_failure_category_check
        CHECK (failure_category IS NULL OR failure_category IN (
        'archive_unavailable', 'credentials_invalid', 'remote_unavailable',
        'remote_integrity_mismatch', 'replication_failed'
    )),
    multipart_upload_id TEXT,
    CONSTRAINT instance_backup_replications_pkey PRIMARY KEY (archive_id),
    CONSTRAINT instance_backup_replications_archive_id_format
        CHECK (archive_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    CONSTRAINT instance_backup_replications_archive_digest_pair_check
        CHECK ((archive_bytes IS NULL) = (archive_sha256 IS NULL)),
    CONSTRAINT instance_backup_replications_succeeded_shape_check
        CHECK (status != 'succeeded' OR
        (archive_bytes IS NOT NULL AND archive_sha256 IS NOT NULL
            AND completed_at IS NOT NULL AND failure_category IS NULL
            AND next_attempt_at IS NULL AND multipart_upload_id IS NULL)),
    CONSTRAINT instance_backup_replications_pending_archive_shape_check
        CHECK (status != 'pending_archive' OR
        (archive_bytes IS NULL AND archive_sha256 IS NULL AND attempt_count = 0)),
    CONSTRAINT instance_backup_replications_running_shape_check
        CHECK (status != 'running' OR
        (started_at IS NOT NULL AND next_attempt_at IS NULL
            AND failure_category IS NULL)),
    CONSTRAINT instance_backup_replications_retry_wait_shape_check
        CHECK (status != 'retry_wait' OR
        (next_attempt_at IS NOT NULL AND failure_category IS NOT NULL)),
    CONSTRAINT instance_backup_replications_pending_shape_check
        CHECK (status != 'pending' OR
        (archive_bytes IS NOT NULL AND archive_sha256 IS NOT NULL
            AND next_attempt_at IS NOT NULL AND failure_category IS NULL)),
    CONSTRAINT instance_backup_replications_interrupted_shape_check
        CHECK (status != 'interrupted' OR next_attempt_at IS NOT NULL)
);

CREATE UNIQUE INDEX idx_instance_backup_replications_one_running
    ON instance_backup_replications((1))
    WHERE status = 'running';

CREATE INDEX idx_instance_backup_replications_due
    ON instance_backup_replications(status, next_attempt_at, created_at, archive_id);

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 36)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

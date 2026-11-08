-- Extend the shared, leased PostgreSQL instance-admin ledger to the
-- server-generated encrypted backup and isolated restore-stage operations.
-- The archive identifier is a canonical UUID only; archive paths, key files,
-- database URLs, and restore target URLs remain operator-side configuration.

ALTER TABLE instance_admin_jobs
    DROP CONSTRAINT instance_admin_jobs_action_check,
    DROP CONSTRAINT instance_admin_jobs_status_check,
    DROP CONSTRAINT instance_admin_jobs_result_code_check,
    DROP CONSTRAINT instance_admin_jobs_check;

ALTER TABLE instance_admin_jobs
    ADD COLUMN archive_id TEXT,
    ADD COLUMN archive_source TEXT,
    ADD COLUMN archive_sha256 TEXT,
    ADD COLUMN archive_timestamp TEXT,
    ADD COLUMN restore_stage_status TEXT,
    ADD COLUMN restore_stage_ready_at TIMESTAMPTZ,
    ADD COLUMN restore_stage_generation TEXT,
    ADD CONSTRAINT instance_admin_jobs_action_check
        CHECK (action IN ('maintenance', 'backup', 'restore')),
    ADD CONSTRAINT instance_admin_jobs_status_check
        CHECK (status IN ('queued', 'running', 'succeeded', 'failed', 'interrupted')),
    ADD CONSTRAINT instance_admin_jobs_result_code_check
        CHECK (result_code IS NULL OR result_code IN (
            'completed', 'maintenance_failed', 'backup_failed', 'restore_failed', 'interrupted'
        )),
    ADD CONSTRAINT instance_admin_jobs_archive_id_check
        CHECK (archive_id IS NULL OR (
            length(archive_id) = 36
            AND archive_id = lower(archive_id)
            AND substr(archive_id,9,1) = '-'
            AND substr(archive_id,14,1) = '-'
            AND substr(archive_id,19,1) = '-'
            AND substr(archive_id,24,1) = '-'
            AND replace(archive_id,'-','') !~ '[^0-9a-f]'
        )),
    ADD CONSTRAINT instance_admin_jobs_archive_digest_check
        CHECK (archive_sha256 IS NULL OR archive_sha256 ~ '^[0-9a-f]{64}$'),
    ADD CONSTRAINT instance_admin_jobs_archive_timestamp_check
        CHECK (archive_timestamp IS NULL OR archive_timestamp ~ '^[0-9]{8}T[0-9]{6}\.[0-9]{3}Z$'),
    ADD CONSTRAINT instance_admin_jobs_restore_stage_check
        CHECK (
            (restore_stage_status IS NULL AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL)
            OR (action = 'restore'
                AND restore_stage_status = 'ready'
                AND restore_stage_ready_at IS NOT NULL
                AND restore_stage_generation IS NOT NULL
                AND length(restore_stage_generation) = 36
                AND restore_stage_generation = lower(restore_stage_generation)
                AND substr(restore_stage_generation,9,1) = '-'
                AND substr(restore_stage_generation,14,1) = '-'
                AND substr(restore_stage_generation,19,1) = '-'
                AND substr(restore_stage_generation,24,1) = '-'
                AND replace(restore_stage_generation,'-','') !~ '[^0-9a-f]')
            OR (action = 'restore' AND restore_stage_status IN ('failed', 'interrupted')
                AND restore_stage_ready_at IS NULL AND restore_stage_generation IS NULL)
        ),
    ADD CONSTRAINT instance_admin_jobs_action_archive_check
        CHECK (
            (action = 'maintenance' AND archive_id IS NULL AND archive_source IS NULL
                AND archive_sha256 IS NULL AND archive_timestamp IS NULL AND restore_stage_status IS NULL
                AND restore_stage_ready_at IS NULL AND restore_stage_generation IS NULL)
            OR (action = 'backup' AND archive_id = job_id AND archive_source IS NULL
                AND restore_stage_status IS NULL AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL)
            OR (action = 'restore' AND archive_id IS NOT NULL AND archive_source = 'local')
        ),
    ADD CONSTRAINT instance_admin_jobs_transition_check
        CHECK (
            (status = 'queued' AND started_at IS NULL AND finished_at IS NULL
                AND result_code IS NULL AND worker_token IS NULL AND lease_expires_at IS NULL)
            OR (status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL
                AND result_code IS NULL AND worker_token IS NOT NULL AND lease_expires_at IS NOT NULL)
            OR (status = 'succeeded' AND started_at IS NOT NULL AND finished_at IS NOT NULL
                AND result_code = 'completed' AND worker_token IS NULL AND lease_expires_at IS NULL)
            OR (status = 'failed' AND started_at IS NOT NULL AND finished_at IS NOT NULL
                AND worker_token IS NULL AND lease_expires_at IS NULL
                AND ((action = 'maintenance' AND result_code = 'maintenance_failed')
                    OR (action = 'backup' AND result_code = 'backup_failed')
                    OR (action = 'restore' AND result_code = 'restore_failed')))
            OR (status = 'interrupted' AND finished_at IS NOT NULL
                AND result_code = 'interrupted' AND worker_token IS NULL AND lease_expires_at IS NULL)
        ),
    ADD CONSTRAINT instance_admin_jobs_archive_completion_check
        CHECK (
            (action <> 'backup' OR status <> 'succeeded'
                OR (archive_timestamp IS NOT NULL AND archive_sha256 IS NOT NULL))
            AND (action <> 'restore' OR status <> 'succeeded'
                OR (archive_sha256 IS NOT NULL AND restore_stage_status = 'ready'))
        );

-- Instance-wide snapshot and restore operations must not race maintenance,
-- another backup, or another restore. A constant partial unique index is the
-- cross-node admission fence; workers still claim rows with SKIP LOCKED.
DROP INDEX idx_instance_admin_jobs_one_active;
CREATE UNIQUE INDEX idx_instance_admin_jobs_one_active
    ON instance_admin_jobs ((1))
    WHERE status IN ('queued', 'running');

CREATE INDEX idx_instance_admin_jobs_backup_sources
    ON instance_admin_jobs (finished_at DESC, job_id DESC)
    WHERE action = 'backup' AND status = 'succeeded';
CREATE INDEX idx_instance_admin_jobs_restore_stage_status
    ON instance_admin_jobs (restore_stage_status, restore_stage_ready_at, job_id)
    WHERE action = 'restore' AND restore_stage_status IS NOT NULL;

-- The archive manifest records the PostgreSQL schema revision separately
-- from SQLite migrations. Readiness requires this marker to match the backup
-- implementation's supported schema version.
CREATE TABLE IF NOT EXISTS atermius_instance_schema (
    singleton SMALLINT PRIMARY KEY CHECK (singleton = 1),
    schema_version INTEGER NOT NULL CHECK (schema_version >= 1)
);
INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 25)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

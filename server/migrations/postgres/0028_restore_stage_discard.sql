-- Bind every new PostgreSQL restore stage to one isolated database and add a
-- durable, retryable discard lifecycle. Existing `ready` stages keep NULL
-- binding fields and therefore remain visible but fail closed for discard.

ALTER TABLE instance_admin_jobs
    ADD COLUMN restore_stage_binding_id UUID,
    ADD COLUMN restore_stage_target_fingerprint TEXT,
    ADD COLUMN restore_stage_target_database_oid BIGINT,
    ADD COLUMN restore_stage_target_database_name TEXT,
    ADD COLUMN restore_stage_schema TEXT,
    ADD COLUMN restore_stage_object_store_id TEXT,
    ADD COLUMN restore_stage_object_count BIGINT,
    ADD COLUMN restore_stage_discard_requested_by_user_id TEXT,
    ADD COLUMN restore_stage_discard_requested_by_device_id TEXT,
    ADD COLUMN restore_stage_discard_requested_at TIMESTAMPTZ,
    ADD COLUMN restore_stage_discarded_at TIMESTAMPTZ,
    ADD COLUMN restore_stage_target_cleaned_at TIMESTAMPTZ,
    ADD COLUMN restore_stage_discard_attempts INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN restore_stage_discard_next_retry_at TIMESTAMPTZ;

ALTER TABLE instance_admin_jobs
    DROP CONSTRAINT instance_admin_jobs_restore_stage_check,
    DROP CONSTRAINT instance_admin_jobs_archive_completion_check;

ALTER TABLE instance_admin_jobs
    ADD CONSTRAINT instance_admin_jobs_restore_stage_check
        CHECK (
            (restore_stage_status IS NULL
                AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL
                AND restore_stage_discard_requested_by_user_id IS NULL
                AND restore_stage_discard_requested_by_device_id IS NULL
                AND restore_stage_discard_requested_at IS NULL
                AND restore_stage_discarded_at IS NULL
                AND restore_stage_target_cleaned_at IS NULL)
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
                AND replace(restore_stage_generation,'-','') !~ '[^0-9a-f]'
                AND restore_stage_discard_requested_by_user_id IS NULL
                AND restore_stage_discard_requested_by_device_id IS NULL
                AND restore_stage_discard_requested_at IS NULL
                AND restore_stage_discarded_at IS NULL
                AND restore_stage_target_cleaned_at IS NULL)
            OR (action = 'restore'
                AND restore_stage_status = 'discarding'
                AND restore_stage_ready_at IS NOT NULL
                AND restore_stage_generation IS NOT NULL
                AND length(restore_stage_generation) = 36
                AND restore_stage_generation = lower(restore_stage_generation)
                AND substr(restore_stage_generation,9,1) = '-'
                AND substr(restore_stage_generation,14,1) = '-'
                AND substr(restore_stage_generation,19,1) = '-'
                AND substr(restore_stage_generation,24,1) = '-'
                AND replace(restore_stage_generation,'-','') !~ '[^0-9a-f]'
                AND restore_stage_discard_requested_by_user_id IS NOT NULL
                AND restore_stage_discard_requested_by_device_id IS NOT NULL
                AND restore_stage_discard_requested_at IS NOT NULL
                AND restore_stage_discarded_at IS NULL
                AND restore_stage_target_cleaned_at IS NULL)
            OR (action = 'restore'
                AND restore_stage_status = 'discarded'
                AND restore_stage_ready_at IS NOT NULL
                AND restore_stage_generation IS NOT NULL
                AND length(restore_stage_generation) = 36
                AND restore_stage_generation = lower(restore_stage_generation)
                AND substr(restore_stage_generation,9,1) = '-'
                AND substr(restore_stage_generation,14,1) = '-'
                AND substr(restore_stage_generation,19,1) = '-'
                AND substr(restore_stage_generation,24,1) = '-'
                AND replace(restore_stage_generation,'-','') !~ '[^0-9a-f]'
                AND restore_stage_discard_requested_by_user_id IS NOT NULL
                AND restore_stage_discard_requested_by_device_id IS NOT NULL
                AND restore_stage_discard_requested_at IS NOT NULL
                AND restore_stage_discarded_at IS NOT NULL)
            OR (action = 'restore' AND restore_stage_status IN ('failed', 'interrupted')
                AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL
                AND restore_stage_discard_requested_by_user_id IS NULL
                AND restore_stage_discard_requested_by_device_id IS NULL
                AND restore_stage_discard_requested_at IS NULL
                AND restore_stage_discarded_at IS NULL
                AND restore_stage_target_cleaned_at IS NULL)
        ),
    ADD CONSTRAINT instance_admin_jobs_restore_stage_target_cleanup_check
        CHECK (restore_stage_target_cleaned_at IS NULL OR restore_stage_status = 'discarded'),
    ADD CONSTRAINT instance_admin_jobs_restore_discard_retry_check
        CHECK (restore_stage_discard_attempts >= 0),
    ADD CONSTRAINT instance_admin_jobs_restore_stage_binding_check
        CHECK (
            (restore_stage_binding_id IS NULL
                AND restore_stage_target_fingerprint IS NULL
                AND restore_stage_target_database_oid IS NULL
                AND restore_stage_target_database_name IS NULL
                AND restore_stage_schema IS NULL
                AND restore_stage_object_store_id IS NULL
                AND restore_stage_object_count IS NULL)
            OR (action = 'restore'
                AND restore_stage_binding_id IS NOT NULL
                AND restore_stage_target_fingerprint IS NOT NULL
                AND restore_stage_target_fingerprint ~ '^[0-9a-f]{64}$'
                AND restore_stage_target_database_oid IS NOT NULL
                AND restore_stage_target_database_oid > 0
                AND restore_stage_target_database_name IS NOT NULL
                AND length(restore_stage_target_database_name) BETWEEN 1 AND 63
                AND restore_stage_schema IS NOT NULL
                AND restore_stage_schema ~ '^[A-Za-z_][A-Za-z0-9_]{0,62}$'
                AND restore_stage_object_store_id IS NOT NULL
                AND restore_stage_object_store_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                AND restore_stage_object_count IS NOT NULL
                AND restore_stage_object_count >= 0)
        ),
    ADD CONSTRAINT instance_admin_jobs_archive_completion_check
        CHECK (
            (action <> 'backup' OR status <> 'succeeded'
                OR (archive_timestamp IS NOT NULL AND archive_sha256 IS NOT NULL))
            AND (action <> 'restore' OR status <> 'succeeded'
                OR (archive_sha256 IS NOT NULL
                    AND restore_stage_status IN ('ready', 'discarding', 'discarded')))
            AND (restore_stage_status NOT IN ('discarding', 'discarded')
                OR restore_stage_binding_id IS NOT NULL)
        );

CREATE INDEX idx_instance_admin_jobs_restore_discard_retry
    ON instance_admin_jobs (
        restore_stage_status,
        restore_stage_discard_next_retry_at,
        restore_stage_discard_requested_at,
        job_id
    )
    WHERE action = 'restore'
      AND restore_stage_status IN ('discarding','discarded')
      AND restore_stage_target_cleaned_at IS NULL;

-- Keep restored archives and the active source instance on the same schema
-- contract. The restore runner applies this migration to marker-27 archives.
INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 28)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

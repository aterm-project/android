-- Allow restore jobs to bind either a local generated archive or its
-- authenticated S3 replica. All other action/archive invariants remain fixed.
ALTER TABLE instance_admin_jobs
    DROP CONSTRAINT instance_admin_jobs_action_archive_check;

ALTER TABLE instance_admin_jobs
    ADD CONSTRAINT instance_admin_jobs_action_archive_check
        CHECK (
            (action = 'maintenance' AND archive_id IS NULL AND archive_source IS NULL
                AND archive_sha256 IS NULL AND archive_timestamp IS NULL
                AND restore_stage_status IS NULL AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL)
            OR (action = 'backup' AND archive_id = job_id AND archive_source IS NULL
                AND restore_stage_status IS NULL AND restore_stage_ready_at IS NULL
                AND restore_stage_generation IS NULL)
            OR (action = 'restore' AND archive_id IS NOT NULL
                AND archive_source IN ('local', 'replica'))
        );

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 38)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

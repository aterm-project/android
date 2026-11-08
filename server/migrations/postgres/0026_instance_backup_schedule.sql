-- Durable PostgreSQL scheduled-backup state. Scheduled work enters the same
-- shared instance-admin ledger as manual work so the existing partial unique
-- active-job index remains the cross-node admission fence.

ALTER TABLE instance_admin_jobs
    ADD COLUMN request_origin TEXT NOT NULL DEFAULT 'manual',
    ADD COLUMN scheduled_for TIMESTAMPTZ,
    ADD COLUMN archive_bytes BIGINT CHECK (archive_bytes IS NULL OR archive_bytes > 0),
    ALTER COLUMN requested_by_user_id DROP NOT NULL,
    ALTER COLUMN requested_by_device_id DROP NOT NULL;

ALTER TABLE instance_admin_jobs
    ADD CONSTRAINT instance_admin_jobs_request_origin_check
        CHECK (request_origin IN ('manual', 'scheduled')),
    ADD CONSTRAINT instance_admin_jobs_scheduled_request_check
        CHECK (
            (request_origin = 'manual' AND scheduled_for IS NULL
                AND requested_by_user_id IS NOT NULL AND requested_by_device_id IS NOT NULL)
            OR (request_origin = 'scheduled' AND action = 'backup'
                AND scheduled_for IS NOT NULL
                AND requested_by_user_id IS NULL AND requested_by_device_id IS NULL)
        ),
    ADD CONSTRAINT instance_admin_jobs_backup_bytes_check
        CHECK (request_origin <> 'scheduled' OR status <> 'succeeded' OR archive_bytes IS NOT NULL);

CREATE UNIQUE INDEX idx_instance_admin_jobs_scheduled_slot
    ON instance_admin_jobs (scheduled_for)
    WHERE request_origin = 'scheduled';
CREATE INDEX idx_instance_admin_jobs_scheduled_history
    ON instance_admin_jobs (scheduled_for DESC, job_id DESC)
    WHERE request_origin = 'scheduled';

CREATE TABLE instance_backup_schedule (
    schedule_id SMALLINT PRIMARY KEY,
    interval_hours INTEGER,
    next_run_at TIMESTAMPTZ,
    CONSTRAINT instance_backup_schedule_singleton_check CHECK (schedule_id = 1),
    CONSTRAINT instance_backup_schedule_interval_hours_check
        CHECK (interval_hours IS NULL OR interval_hours BETWEEN 1 AND 720),
    CONSTRAINT instance_backup_schedule_due_pair_check
        CHECK ((interval_hours IS NULL) = (next_run_at IS NULL))
);
INSERT INTO instance_backup_schedule(schedule_id, interval_hours, next_run_at)
VALUES (1, NULL, NULL);

-- Version 26 includes the durable schedule and scheduled-job provenance. The
-- restore path keeps support for authenticated v25 archives by applying this
-- bundled migration to an isolated target before publishing its restore stage.
INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 26)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

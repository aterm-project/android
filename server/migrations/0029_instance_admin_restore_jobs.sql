-- Add fixed, path-free archive restore staging to the existing single-slot
-- administrator job queue. The selected archive is identified only by the
-- UUID already assigned to a durable server-generated backup operation; the
-- API additionally requires its exact private generated archive file to exist.
CREATE TABLE instance_admin_jobs_v3 (
    job_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE,
    requested_by_user_id TEXT NOT NULL,
    requested_by_device_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('maintenance','backup','restore')),
    archive_id TEXT,
    archive_sha256 TEXT,
    archive_timestamp TEXT,
    status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','failed','interrupted')),
    requested_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    result_code TEXT CHECK (result_code IS NULL OR result_code IN (
        'completed','maintenance_failed','backup_failed','restore_failed','interrupted'
    )),
    CHECK (
        (action = 'restore' AND archive_id IS NOT NULL
            AND length(archive_id) = 36
            AND archive_id = lower(archive_id)
            AND substr(archive_id,9,1) = '-'
            AND substr(archive_id,14,1) = '-'
            AND substr(archive_id,19,1) = '-'
            AND substr(archive_id,24,1) = '-'
            AND replace(archive_id,'-','') NOT GLOB '*[^0-9a-f]*')
        OR (action IN ('maintenance','backup') AND archive_id IS NULL)
    ),
    CHECK (
        (action = 'restore' AND (archive_sha256 IS NULL OR
            (length(archive_sha256) = 64 AND archive_sha256 NOT GLOB '*[^0-9a-f]*')))
        OR (action IN ('maintenance','backup') AND archive_sha256 IS NULL)
    ),
    CHECK (action = 'backup' OR archive_timestamp IS NULL),
    CHECK (
        (status = 'queued' AND started_at IS NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'succeeded' AND started_at IS NOT NULL AND finished_at IS NOT NULL
            AND result_code = 'completed' AND (action != 'restore' OR archive_sha256 IS NOT NULL))
        OR (status = 'failed' AND started_at IS NOT NULL AND finished_at IS NOT NULL
            AND ((action = 'maintenance' AND result_code = 'maintenance_failed')
                 OR (action = 'backup' AND result_code = 'backup_failed')
                 OR (action = 'restore' AND result_code = 'restore_failed')))
        OR (status = 'interrupted' AND finished_at IS NOT NULL AND result_code = 'interrupted')
    )
);

INSERT INTO instance_admin_jobs_v3(
    job_id,request_id,requested_by_user_id,requested_by_device_id,action,archive_id,
    archive_sha256,archive_timestamp,status,requested_at,started_at,finished_at,result_code
)
SELECT job_id,request_id,requested_by_user_id,requested_by_device_id,action,NULL,
       NULL,NULL,status,requested_at,started_at,finished_at,result_code
FROM instance_admin_jobs;

DROP TABLE instance_admin_jobs;
ALTER TABLE instance_admin_jobs_v3 RENAME TO instance_admin_jobs;

CREATE UNIQUE INDEX idx_instance_admin_jobs_one_active
    ON instance_admin_jobs((1))
    WHERE status IN ('queued','running');

CREATE INDEX idx_instance_admin_jobs_requested
    ON instance_admin_jobs(requested_at DESC, job_id DESC);

CREATE INDEX idx_instance_admin_jobs_archive
    ON instance_admin_jobs(archive_id, action, status);

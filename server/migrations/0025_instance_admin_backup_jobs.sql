-- Extend the fixed durable admin-job queue with server-configured encrypted
-- instance backups. The constant-expression partial index makes the one
-- active slot global across both fixed actions.
CREATE TABLE instance_admin_jobs_v2 (
    job_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE,
    requested_by_user_id TEXT NOT NULL,
    requested_by_device_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action IN ('maintenance','backup')),
    status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','failed','interrupted')),
    requested_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    result_code TEXT CHECK (result_code IS NULL OR result_code IN ('completed','maintenance_failed','backup_failed','interrupted')),
    CHECK (
        (status = 'queued' AND started_at IS NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'succeeded' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND result_code = 'completed')
        OR (status = 'failed' AND started_at IS NOT NULL AND finished_at IS NOT NULL
            AND ((action = 'maintenance' AND result_code = 'maintenance_failed')
                 OR (action = 'backup' AND result_code = 'backup_failed')))
        OR (status = 'interrupted' AND finished_at IS NOT NULL AND result_code = 'interrupted')
    )
);

INSERT INTO instance_admin_jobs_v2(
    job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,
    requested_at,started_at,finished_at,result_code
)
SELECT job_id,request_id,requested_by_user_id,requested_by_device_id,action,status,
       requested_at,started_at,finished_at,result_code
FROM instance_admin_jobs;

DROP TABLE instance_admin_jobs;
ALTER TABLE instance_admin_jobs_v2 RENAME TO instance_admin_jobs;

CREATE UNIQUE INDEX idx_instance_admin_jobs_one_active
    ON instance_admin_jobs((1))
    WHERE status IN ('queued','running');

CREATE INDEX idx_instance_admin_jobs_requested
    ON instance_admin_jobs(requested_at DESC, job_id DESC);

-- Durable state for the small fixed set of instance-admin background jobs.
-- Request IDs are globally unique so an idempotency key cannot be replayed
-- under another account. The partial index is the final guard against
-- overlapping cleanup runs.
CREATE TABLE instance_admin_jobs (
    job_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE,
    requested_by_user_id TEXT NOT NULL,
    requested_by_device_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action = 'maintenance'),
    status TEXT NOT NULL CHECK (status IN ('queued','running','succeeded','failed','interrupted')),
    requested_at TEXT NOT NULL,
    started_at TEXT,
    finished_at TEXT,
    result_code TEXT CHECK (result_code IS NULL OR result_code IN ('completed','maintenance_failed','interrupted')),
    CHECK (
        (status = 'queued' AND started_at IS NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL AND result_code IS NULL)
        OR (status = 'succeeded' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND result_code = 'completed')
        OR (status = 'failed' AND started_at IS NOT NULL AND finished_at IS NOT NULL AND result_code = 'maintenance_failed')
        OR (status = 'interrupted' AND finished_at IS NOT NULL AND result_code = 'interrupted')
    )
);

CREATE UNIQUE INDEX idx_instance_admin_jobs_one_active_maintenance
    ON instance_admin_jobs(action)
    WHERE status IN ('queued','running');

CREATE INDEX idx_instance_admin_jobs_requested
    ON instance_admin_jobs(requested_at DESC, job_id DESC);

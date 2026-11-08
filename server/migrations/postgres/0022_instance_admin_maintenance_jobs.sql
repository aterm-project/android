-- Shared administrative maintenance jobs for the restricted PostgreSQL
-- runtime. Backups/restores intentionally remain outside this ledger because
-- their current archive implementation is bound to the SQLite database.
CREATE TABLE instance_admin_jobs (
    job_id TEXT PRIMARY KEY,
    request_id TEXT NOT NULL UNIQUE
        CHECK (request_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    requested_by_user_id TEXT NOT NULL,
    requested_by_device_id TEXT NOT NULL,
    action TEXT NOT NULL CHECK (action = 'maintenance'),
    status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'succeeded', 'failed')),
    requested_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    started_at TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    result_code TEXT CHECK (result_code IS NULL OR result_code IN ('completed', 'maintenance_failed')),
    worker_token TEXT,
    lease_expires_at TIMESTAMPTZ,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    CHECK (
        (status = 'queued' AND started_at IS NULL AND finished_at IS NULL
            AND result_code IS NULL AND worker_token IS NULL AND lease_expires_at IS NULL)
        OR (status = 'running' AND started_at IS NOT NULL AND finished_at IS NULL
            AND result_code IS NULL AND worker_token IS NOT NULL AND lease_expires_at IS NOT NULL)
        OR (status = 'succeeded' AND started_at IS NOT NULL AND finished_at IS NOT NULL
            AND result_code = 'completed' AND worker_token IS NULL AND lease_expires_at IS NULL)
        OR (status = 'failed' AND started_at IS NOT NULL AND finished_at IS NOT NULL
            AND result_code = 'maintenance_failed' AND worker_token IS NULL AND lease_expires_at IS NULL)
    )
);

-- Only one instance-wide job can be queued or running at a time. This is the
-- cross-node admission fence; the worker separately claims rows with
-- FOR UPDATE SKIP LOCKED and a renewable lease.
CREATE UNIQUE INDEX idx_instance_admin_jobs_one_active
    ON instance_admin_jobs (action)
    WHERE status IN ('queued', 'running');
CREATE INDEX idx_instance_admin_jobs_page
    ON instance_admin_jobs (requested_at DESC, job_id DESC);
CREATE INDEX idx_instance_admin_jobs_worker
    ON instance_admin_jobs (requested_at, job_id)
    WHERE status IN ('queued', 'running');

-- Durable server-generated backup cadence and individual scheduled runs.
-- The singleton stores the operator-selected interval and UTC Unix due time.
-- A claimed run is written in the same transaction that advances next_run_at,
-- so restarts cannot claim the same cadence slot twice.
CREATE TABLE instance_backup_schedule (
    schedule_id INTEGER PRIMARY KEY CHECK (schedule_id = 1),
    interval_hours INTEGER CHECK (interval_hours IS NULL OR interval_hours BETWEEN 1 AND 720),
    next_run_at INTEGER,
    CHECK (
        (interval_hours IS NULL AND next_run_at IS NULL)
        OR (interval_hours IS NOT NULL AND next_run_at IS NOT NULL)
    )
);

INSERT INTO instance_backup_schedule(schedule_id, interval_hours, next_run_at)
VALUES (1, NULL, NULL);

CREATE TABLE instance_scheduled_backup_runs (
    run_id TEXT PRIMARY KEY,
    scheduled_for INTEGER NOT NULL UNIQUE,
    started_at INTEGER NOT NULL,
    finished_at INTEGER,
    status TEXT NOT NULL CHECK (status IN ('running','succeeded','failed','interrupted')),
    result_code TEXT CHECK (result_code IS NULL OR result_code IN ('completed','backup_failed','interrupted')),
    migration_version INTEGER,
    archive_bytes INTEGER,
    CHECK (
        (status = 'running' AND finished_at IS NULL AND result_code IS NULL
            AND migration_version IS NULL AND archive_bytes IS NULL)
        OR (status = 'succeeded' AND finished_at IS NOT NULL AND result_code = 'completed'
            AND migration_version IS NOT NULL AND migration_version >= 0
            AND archive_bytes IS NOT NULL AND archive_bytes > 0)
        OR (status = 'failed' AND finished_at IS NOT NULL AND result_code = 'backup_failed'
            AND migration_version IS NULL AND archive_bytes IS NULL)
        OR (status = 'interrupted' AND finished_at IS NOT NULL AND result_code = 'interrupted'
            AND migration_version IS NULL AND archive_bytes IS NULL)
    )
);

CREATE INDEX idx_instance_scheduled_backup_runs_recent
    ON instance_scheduled_backup_runs(scheduled_for DESC, run_id DESC);

CREATE UNIQUE INDEX idx_instance_scheduled_backup_runs_one_active
    ON instance_scheduled_backup_runs((1))
    WHERE status = 'running';

-- Track the separately published filesystem lifecycle without changing the
-- successful restore-job terminal state. API DTOs expose ready, discarding,
-- discarded, or unverified only to the original job owner; other admins see
-- null. `discarding` remains retryable after startup recovery is deferred.
CREATE TABLE instance_admin_restore_stages (
    restore_job_id TEXT PRIMARY KEY
        REFERENCES instance_admin_jobs(job_id) ON DELETE CASCADE,
    generation TEXT NOT NULL
        CHECK (length(generation) = 36
            AND generation = lower(generation)
            AND substr(generation,9,1) = '-'
            AND substr(generation,14,1) = '-'
            AND substr(generation,19,1) = '-'
            AND substr(generation,24,1) = '-'
            AND replace(generation,'-','') NOT GLOB '*[^0-9a-f]*'),
    status TEXT NOT NULL CHECK (status IN ('ready','discarding','discarded')),
    ready_at TEXT NOT NULL,
    discard_requested_by_user_id TEXT,
    discard_requested_by_device_id TEXT,
    discarded_at TEXT,
    CHECK ((status = 'discarded') = (discarded_at IS NOT NULL)),
    CHECK (
        (status = 'ready' AND discard_requested_by_user_id IS NULL
            AND discard_requested_by_device_id IS NULL)
        OR (status IN ('discarding','discarded')
            AND discard_requested_by_user_id IS NOT NULL
            AND discard_requested_by_device_id IS NOT NULL)
    )
);

CREATE INDEX idx_instance_admin_restore_stages_status
    ON instance_admin_restore_stages(status,ready_at,restore_job_id);

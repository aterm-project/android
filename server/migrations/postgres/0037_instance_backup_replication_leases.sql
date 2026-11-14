-- Cross-node replication workers use the monotonically increasing
-- attempt_count as a fencing generation and a database-clock lease expiry.
-- A row left running by the previous schema has no safe lease owner, so make
-- it immediately retryable before requiring a lease for running rows.
ALTER TABLE instance_backup_replications
    ADD COLUMN lease_expires_at TIMESTAMPTZ;

UPDATE instance_backup_replications
SET status='interrupted',
    next_attempt_at=clock_timestamp(),
    started_at=NULL,
    completed_at=NULL,
    failure_category='remote_unavailable',
    lease_expires_at=NULL
WHERE status='running';

ALTER TABLE instance_backup_replications
    ADD CONSTRAINT instance_backup_replications_lease_shape_check
    CHECK ((status='running') = (lease_expires_at IS NOT NULL));

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 37)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

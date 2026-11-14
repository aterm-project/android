ALTER TABLE vault_counters
    ADD COLUMN minimum_available_seq INTEGER NOT NULL DEFAULT 1;

ALTER TABLE change_events
    ADD COLUMN created_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00+00:00';

UPDATE change_events
SET created_at = COALESCE(
    (
        SELECT record_versions.created_at
        FROM record_versions
        WHERE record_versions.vault_id = change_events.vault_id
          AND record_versions.record_id = change_events.record_id
          AND record_versions.revision_id = change_events.revision_id
    ),
    created_at
);

CREATE INDEX IF NOT EXISTS idx_change_events_retention
    ON change_events(vault_id, created_at, commit_seq);

ALTER TABLE snapshots
    ADD COLUMN server_generation TEXT NOT NULL DEFAULT '';

UPDATE snapshots
SET server_generation = (SELECT generation FROM instance_meta WHERE id=1)
WHERE server_generation='';

-- Expired upload payloads are removed by the maintenance task while keeping
-- their small metadata row long enough for clients to receive UPLOAD_EXPIRED.

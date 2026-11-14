-- Durable, aggregate-only control state for a future bounded automatic
-- tombstone scan. This migration does not schedule or enable a worker.
--
-- Rebuild the candidate index so each Vault can be traversed by the stable
-- (vault_id, record_id) keyset while the exact tombstone/policy identity is
-- available from the index itself.
DROP INDEX IF EXISTS idx_record_graveyard_auto_purge_candidates;
CREATE INDEX idx_record_graveyard_auto_purge_candidates
    ON record_graveyard(vault_id COLLATE "C", record_id COLLATE "C")
    INCLUDE (deleted_revision, deleted_seq, auto_purge_enabled, auto_purge_revision)
    WHERE auto_purge_enabled = TRUE;

CREATE TABLE record_auto_purge_scan_control (
    singleton SMALLINT PRIMARY KEY CHECK (singleton = 1),
    after_vault_id TEXT COLLATE "C",
    server_generation BIGINT NOT NULL DEFAULT 1 CHECK (server_generation > 0),
    cursor_revision BIGINT NOT NULL DEFAULT 0 CHECK (cursor_revision >= 0),
    lease_token TEXT,
    lease_expires_at TIMESTAMPTZ,
    last_scan_status TEXT NOT NULL DEFAULT 'never'
        CHECK (last_scan_status IN ('never', 'running', 'completed', 'failed')),
    last_scan_started_at TIMESTAMPTZ,
    last_scan_finished_at TIMESTAMPTZ,
    last_scan_candidates BIGINT NOT NULL DEFAULT 0 CHECK (last_scan_candidates >= 0),
    last_scan_purged BIGINT NOT NULL DEFAULT 0 CHECK (last_scan_purged >= 0),
    last_scan_not_due BIGINT NOT NULL DEFAULT 0 CHECK (last_scan_not_due >= 0),
    last_scan_capability_blocked BIGINT NOT NULL DEFAULT 0
        CHECK (last_scan_capability_blocked >= 0),
    last_scan_conflict_blocked BIGINT NOT NULL DEFAULT 0
        CHECK (last_scan_conflict_blocked >= 0),
    last_scan_reference_blocked BIGINT NOT NULL DEFAULT 0
        CHECK (last_scan_reference_blocked >= 0),
    last_scan_stale_or_withdrawn BIGINT NOT NULL DEFAULT 0
        CHECK (last_scan_stale_or_withdrawn >= 0),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL))
);

INSERT INTO record_auto_purge_scan_control(singleton)
VALUES (1)
ON CONFLICT (singleton) DO NOTHING;

CREATE TABLE record_auto_purge_vault_cursors (
    vault_id TEXT PRIMARY KEY REFERENCES vaults(vault_id) ON DELETE CASCADE,
    after_record_id TEXT COLLATE "C",
    high_water_record_id TEXT COLLATE "C",
    pending_record_id TEXT COLLATE "C",
    pending_deleted_revision_id TEXT,
    pending_deleted_seq BIGINT,
    server_generation BIGINT NOT NULL CHECK (server_generation > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CHECK (
        (pending_record_id IS NULL AND pending_deleted_revision_id IS NULL AND pending_deleted_seq IS NULL)
        OR
        (pending_record_id IS NOT NULL AND pending_deleted_revision_id IS NOT NULL
         AND pending_deleted_seq IS NOT NULL AND pending_deleted_seq > 0
         AND high_water_record_id IS NOT NULL
         AND pending_record_id COLLATE "C" <= high_water_record_id COLLATE "C"
         AND (after_record_id IS NULL
              OR pending_record_id COLLATE "C" > after_record_id COLLATE "C"))
    ),
    CHECK (
        high_water_record_id IS NULL
        OR after_record_id IS NULL
        OR after_record_id COLLATE "C" <= high_water_record_id COLLATE "C"
    )
);

CREATE INDEX idx_record_auto_purge_vault_cursors_generation
    ON record_auto_purge_vault_cursors(server_generation, vault_id COLLATE "C")
    WHERE high_water_record_id IS NOT NULL OR pending_record_id IS NOT NULL;

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 34)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

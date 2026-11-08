-- Durable, bounded scan cursors for a future explicitly enabled record purge
-- worker. This migration stores only scheduling metadata and aggregate pass
-- counters; it does not start a worker or opt any tombstone into purge.
CREATE TABLE record_auto_purge_scan_control (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    after_vault_id TEXT,
    server_generation INTEGER NOT NULL DEFAULT 1 CHECK (server_generation > 0),
    cursor_revision INTEGER NOT NULL DEFAULT 0
        CHECK (cursor_revision BETWEEN 0 AND 9223372036854775807),
    lease_token TEXT,
    lease_expires_at TEXT,
    last_scan_status TEXT NOT NULL DEFAULT 'never'
        CHECK (last_scan_status IN ('never', 'running', 'completed', 'failed')),
    last_scan_started_at TEXT,
    last_scan_finished_at TEXT,
    last_scan_candidates INTEGER NOT NULL DEFAULT 0 CHECK (last_scan_candidates >= 0),
    last_scan_purged INTEGER NOT NULL DEFAULT 0 CHECK (last_scan_purged >= 0),
    last_scan_not_due INTEGER NOT NULL DEFAULT 0 CHECK (last_scan_not_due >= 0),
    last_scan_capability_blocked INTEGER NOT NULL DEFAULT 0
        CHECK (last_scan_capability_blocked >= 0),
    last_scan_conflict_blocked INTEGER NOT NULL DEFAULT 0
        CHECK (last_scan_conflict_blocked >= 0),
    last_scan_reference_blocked INTEGER NOT NULL DEFAULT 0
        CHECK (last_scan_reference_blocked >= 0),
    last_scan_stale_or_withdrawn INTEGER NOT NULL DEFAULT 0
        CHECK (last_scan_stale_or_withdrawn >= 0),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL))
);

INSERT INTO record_auto_purge_scan_control(singleton) VALUES (1);

CREATE TABLE record_auto_purge_vault_cursors (
    vault_id TEXT PRIMARY KEY COLLATE BINARY
        REFERENCES vaults(vault_id) ON DELETE CASCADE,
    after_record_id TEXT COLLATE BINARY,
    high_water_record_id TEXT COLLATE BINARY,
    pending_record_id TEXT COLLATE BINARY,
    pending_deleted_revision_id TEXT COLLATE BINARY,
    pending_deleted_seq INTEGER,
    server_generation INTEGER NOT NULL CHECK (server_generation > 0),
    updated_at TEXT NOT NULL,
    CHECK (after_record_id IS NULL OR high_water_record_id IS NOT NULL),
    CHECK (after_record_id IS NULL OR after_record_id <= high_water_record_id),
    CHECK ((pending_record_id IS NULL AND pending_deleted_revision_id IS NULL
            AND pending_deleted_seq IS NULL)
        OR (pending_record_id IS NOT NULL AND pending_deleted_revision_id IS NOT NULL
            AND pending_deleted_seq IS NOT NULL AND pending_deleted_seq > 0
            AND high_water_record_id IS NOT NULL
            AND pending_record_id <= high_water_record_id
            AND (after_record_id IS NULL OR pending_record_id > after_record_id)))
);

CREATE INDEX idx_record_auto_purge_vault_cursors_generation
    ON record_auto_purge_vault_cursors(server_generation, vault_id COLLATE BINARY);

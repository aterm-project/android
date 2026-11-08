-- Add the PostgreSQL conflict-change feed used by the isolated bounded read
-- adapter in pg_sync_conflict_read.rs. Conflict creation and resolution
-- writers must allocate last_conflict_seq and insert/update the matching feed
-- row in the same Vault transaction.

ALTER TABLE vault_counters
    ADD COLUMN last_conflict_seq BIGINT NOT NULL DEFAULT 0
        CHECK (last_conflict_seq >= 0);

CREATE TABLE conflicts (
    conflict_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    base_revision_id TEXT,
    envelope TEXT NOT NULL,
    digest TEXT NOT NULL,
    -- Historical signer identifiers intentionally do not reference devices;
    -- account/device cleanup must not erase an existing conflict event.
    device_id TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    conflict_seq BIGINT NOT NULL CHECK (conflict_seq > 0),
    resolved_revision_id TEXT,
    resolution_seq BIGINT,
    resolution_at TIMESTAMPTZ,
    CHECK (
        (resolved_revision_id IS NULL AND resolution_seq IS NULL AND resolution_at IS NULL)
        OR
        (resolved_revision_id IS NOT NULL AND resolution_seq IS NOT NULL AND resolution_at IS NOT NULL)
    ),
    CHECK (resolution_seq IS NULL OR resolution_seq > conflict_seq),
    UNIQUE (vault_id, conflict_seq)
);

CREATE UNIQUE INDEX idx_conflicts_vault_resolution_seq
    ON conflicts(vault_id, resolution_seq)
    WHERE resolution_seq IS NOT NULL;

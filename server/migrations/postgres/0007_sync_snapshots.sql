-- Immutable paired-watermark snapshot manifests for the PostgreSQL sync
-- read capability. Apply after sync-core, retention, conflict-feed, and
-- conflict-replay migrations in the dedicated schema search_path; this is
-- not part of the default SQLite migration chain.

CREATE TABLE snapshots (
    snapshot_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    requested_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    high_watermark BIGINT NOT NULL CHECK (high_watermark >= 0),
    conflict_high_watermark BIGINT NOT NULL CHECK (conflict_high_watermark >= 0),
    manifest_json TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    server_generation TEXT NOT NULL CHECK (length(server_generation) > 0)
);

-- Supports expiry cleanup by Vault while the snapshot_id primary key covers
-- direct reads and the requested_by index supports account-scoped cleanup.
CREATE INDEX idx_snapshots_vault_expiry
    ON snapshots(vault_id, expires_at);

CREATE INDEX idx_snapshots_requester_created
    ON snapshots(requested_by, created_at DESC);

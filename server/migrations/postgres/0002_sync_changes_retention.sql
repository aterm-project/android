-- Retention cursor floor for the PostgreSQL /sync/changes read capability.
-- This additive migration belongs after the bounded PostgreSQL sync-core
-- schema in 0001 and remains separate from the default SQLite migrator.
ALTER TABLE vault_counters
    ADD COLUMN minimum_available_seq BIGINT NOT NULL DEFAULT 1;

CREATE INDEX idx_change_events_retention
    ON change_events(vault_id, created_at, commit_seq);

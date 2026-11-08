-- Automatic tombstone purge is an explicit, per-tombstone opt-in. Existing
-- graveyard rows are disabled by default; revisions let owner updates use
-- compare-and-swap semantics without relying on process-local state.
ALTER TABLE record_graveyard
    ADD COLUMN auto_purge_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN auto_purge_revision BIGINT NOT NULL DEFAULT 0
        CONSTRAINT record_graveyard_auto_purge_revision_nonnegative
        CHECK (auto_purge_revision >= 0);

-- Maintenance scans only opted-in current tombstones and then revalidates the
-- exact row under the Vault writer fence before purging it.
CREATE INDEX idx_record_graveyard_auto_purge_candidates
    ON record_graveyard(deleted_seq, vault_id, record_id)
    WHERE auto_purge_enabled;

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 33)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

-- Automatic permanent purge consent is attached to the exact current
-- tombstone. Existing tombstones remain disabled until their Owner opts in.
ALTER TABLE record_graveyard
    ADD COLUMN auto_purge_enabled INTEGER NOT NULL DEFAULT 0
        CHECK (auto_purge_enabled IN (0, 1));
ALTER TABLE record_graveyard
    ADD COLUMN auto_purge_revision INTEGER NOT NULL DEFAULT 0
        CHECK (auto_purge_revision BETWEEN 0 AND 9223372036854775807);

CREATE INDEX idx_record_graveyard_auto_purge_candidates
    ON record_graveyard(vault_id, record_id)
    WHERE auto_purge_enabled = 1;

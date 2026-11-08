-- Immutable redaction statements are separate from the live-head/graveyard
-- projection. The ledger keeps record IDs reserved after their payload is
-- purged and provides the metadata needed to serialize signed proofs.
CREATE TABLE record_redactions (
    redaction_id TEXT PRIMARY KEY NOT NULL,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    deleted_revision_id TEXT NOT NULL,
    deleted_seq INTEGER NOT NULL CHECK (deleted_seq > 0),
    redaction_seq INTEGER NOT NULL CHECK (redaction_seq > 0),
    created_at TEXT NOT NULL,
    UNIQUE (vault_id, record_id),
    UNIQUE (vault_id, deleted_revision_id),
    UNIQUE (vault_id, redaction_seq),
    CHECK (redaction_seq > deleted_seq),
    FOREIGN KEY (vault_id, record_id)
        REFERENCES record_graveyard(vault_id, record_id) ON DELETE CASCADE
);

CREATE INDEX idx_record_redactions_vault_record
    ON record_redactions(vault_id, record_id);

-- Marked snapshots are rejected before manifest access. Payload cleanup and
-- the write that sets this marker are part of the future purge transaction.
ALTER TABLE snapshots ADD COLUMN redacted_at TEXT;

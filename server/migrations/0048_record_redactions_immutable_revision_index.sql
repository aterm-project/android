-- Keep redaction statements bound to the exact tombstone that reserved the
-- record ID. A redaction cannot outlive an unrelated/replaced graveyard row,
-- while a Vault-wide cascade may still remove all of its private data.
CREATE UNIQUE INDEX idx_record_graveyard_redaction_metadata
    ON record_graveyard(vault_id, record_id, deleted_revision, deleted_seq);

CREATE TABLE record_redactions_rebuild (
    redaction_id TEXT PRIMARY KEY NOT NULL,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    deleted_revision_id TEXT NOT NULL,
    deleted_seq INTEGER NOT NULL CHECK (deleted_seq > 0),
    redaction_seq INTEGER NOT NULL CHECK (redaction_seq > deleted_seq),
    created_at TEXT NOT NULL,
    UNIQUE (vault_id, record_id),
    UNIQUE (vault_id, deleted_revision_id),
    UNIQUE (vault_id, redaction_seq),
    FOREIGN KEY (vault_id, record_id, deleted_revision_id, deleted_seq)
        REFERENCES record_graveyard(vault_id, record_id, deleted_revision, deleted_seq)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

-- Copying through the new FK deliberately aborts this migration if an
-- existing proof disagrees with the tombstone metadata it claims to attest.
INSERT INTO record_redactions_rebuild(
    redaction_id, vault_id, record_id, deleted_revision_id, deleted_seq,
    redaction_seq, created_at
)
SELECT redaction_id, vault_id, record_id, deleted_revision_id, deleted_seq,
       redaction_seq, created_at
FROM record_redactions;

DROP TABLE record_redactions;
ALTER TABLE record_redactions_rebuild RENAME TO record_redactions;

CREATE INDEX idx_record_redactions_vault_record
    ON record_redactions(vault_id, record_id);

-- Payload rows may later be removed, but every revision ID that belonged to
-- the redacted record must continue to resolve to its immutable proof.
CREATE TABLE record_redacted_revisions (
    vault_id TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    PRIMARY KEY (vault_id, record_id, revision_id),
    FOREIGN KEY (vault_id, record_id)
        REFERENCES record_redactions(vault_id, record_id) ON DELETE CASCADE
);

CREATE INDEX idx_record_redacted_revisions_lookup
    ON record_redacted_revisions(vault_id, revision_id);

INSERT OR IGNORE INTO record_redacted_revisions(vault_id, record_id, revision_id)
SELECT vault_id, record_id, deleted_revision_id
FROM record_redactions;

INSERT OR IGNORE INTO record_redacted_revisions(vault_id, record_id, revision_id)
SELECT v.vault_id, v.record_id, v.revision_id
FROM record_versions v
JOIN record_redactions r ON r.vault_id=v.vault_id AND r.record_id=v.record_id;

-- Ledger insertion backfills all still-present history, and future retained
-- revisions of a redacted record are indexed automatically. Purge may delete
-- envelopes only after this index is durable.
CREATE TRIGGER record_redactions_index_existing_revisions
AFTER INSERT ON record_redactions
BEGIN
    INSERT OR IGNORE INTO record_redacted_revisions(vault_id, record_id, revision_id)
    VALUES(NEW.vault_id, NEW.record_id, NEW.deleted_revision_id);
    INSERT OR IGNORE INTO record_redacted_revisions(vault_id, record_id, revision_id)
    SELECT vault_id, record_id, revision_id
    FROM record_versions
    WHERE vault_id=NEW.vault_id AND record_id=NEW.record_id;
END;

CREATE TRIGGER record_versions_index_redacted_revision
AFTER INSERT ON record_versions
WHEN EXISTS (
    SELECT 1 FROM record_redactions
    WHERE vault_id=NEW.vault_id AND record_id=NEW.record_id
)
BEGIN
    INSERT OR IGNORE INTO record_redacted_revisions(vault_id, record_id, revision_id)
    VALUES(NEW.vault_id, NEW.record_id, NEW.revision_id);
END;

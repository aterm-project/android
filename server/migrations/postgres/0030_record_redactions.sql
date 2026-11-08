-- PostgreSQL read-side support for RECORD-REDACTION-v1.
-- This migration does not add a purge writer. The immutable proof ledger is
-- bound to the exact graveyard tombstone and retains an ID-only index for all
-- revisions belonging to a redacted record.

CREATE UNIQUE INDEX idx_record_graveyard_redaction_metadata
    ON record_graveyard(vault_id, record_id, deleted_revision, deleted_seq);

CREATE TABLE record_redactions (
    redaction_id TEXT PRIMARY KEY NOT NULL,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    deleted_revision_id TEXT NOT NULL,
    deleted_seq BIGINT NOT NULL CHECK (deleted_seq > 0),
    redaction_seq BIGINT NOT NULL CHECK (redaction_seq > deleted_seq),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (vault_id, record_id),
    UNIQUE (vault_id, deleted_revision_id),
    UNIQUE (vault_id, redaction_seq),
    FOREIGN KEY (vault_id, record_id, deleted_revision_id, deleted_seq)
        REFERENCES record_graveyard(vault_id, record_id, deleted_revision, deleted_seq)
        ON DELETE RESTRICT ON UPDATE RESTRICT
);

CREATE INDEX idx_record_redactions_vault_record
    ON record_redactions(vault_id, record_id);

-- A direct revision URL has no record_id component. Preserve every historic
-- revision-to-record association before a future payload scrub, including
-- legacy duplicate revision IDs. Readers must reject ambiguous mappings.
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

CREATE FUNCTION index_record_redaction_revisions() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO record_redacted_revisions(vault_id, record_id, revision_id)
    VALUES (NEW.vault_id, NEW.record_id, NEW.deleted_revision_id)
    ON CONFLICT DO NOTHING;

    INSERT INTO record_redacted_revisions(vault_id, record_id, revision_id)
    SELECT v.vault_id, v.record_id, v.revision_id
    FROM record_versions v
    WHERE v.vault_id = NEW.vault_id AND v.record_id = NEW.record_id
    ON CONFLICT DO NOTHING;
    RETURN NEW;
END
$$;

CREATE TRIGGER record_redactions_index_existing_revisions
AFTER INSERT ON record_redactions
FOR EACH ROW EXECUTE FUNCTION index_record_redaction_revisions();

CREATE FUNCTION index_new_redacted_revision() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO record_redacted_revisions(vault_id, record_id, revision_id)
    SELECT NEW.vault_id, NEW.record_id, NEW.revision_id
    WHERE EXISTS (
        SELECT 1 FROM record_redactions r
        WHERE r.vault_id = NEW.vault_id AND r.record_id = NEW.record_id
    )
    ON CONFLICT DO NOTHING;
    RETURN NEW;
END
$$;

CREATE TRIGGER record_versions_index_redacted_revision
AFTER INSERT ON record_versions
FOR EACH ROW EXECUTE FUNCTION index_new_redacted_revision();

-- Treat proof data as immutable to ordinary SQL callers. Full Vault deletion
-- may still cascade the private ledger with the Vault itself.
CREATE FUNCTION protect_record_redaction_ledger() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'record redaction ledger rows are immutable';
END
$$;

CREATE TRIGGER record_redactions_immutable
BEFORE UPDATE OR DELETE ON record_redactions
FOR EACH ROW EXECUTE FUNCTION protect_record_redaction_ledger();

-- Redacted snapshots are rejected before any manifest/page payload is read.
ALTER TABLE snapshots ADD COLUMN redacted_at TIMESTAMPTZ;

-- Future scrub transactions must retain sequence-bearing rows while clearing
-- only encrypted payload columns. No purge writer is exposed by this slice.
ALTER TABLE record_versions ALTER COLUMN envelope DROP NOT NULL;
ALTER TABLE change_events ALTER COLUMN envelope DROP NOT NULL;
ALTER TABLE conflicts ALTER COLUMN envelope DROP NOT NULL;

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 30)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

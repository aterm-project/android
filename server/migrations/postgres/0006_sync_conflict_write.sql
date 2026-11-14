-- Conflict-write idempotency for the PostgreSQL sync core. Apply after
-- 0005_sync_conflict_feed.sql under the same dedicated schema/search_path.
-- Historical signer identifiers stay as plain text and are never cascaded
-- with device cleanup. Valid legacy envelopes receive one deterministic
-- idempotency receipt; malformed/duplicate rows remain with a NULL op_id.

ALTER TABLE conflicts
    ADD COLUMN op_id TEXT;

-- Preserve one deterministic idempotency receipt for each valid legacy
-- (vault,device,op_id) group. Malformed JSON, missing/noncanonical op IDs, and
-- duplicate history remain untouched with op_id NULL; no signer row is
-- rewritten or removed.
DO $$
DECLARE
    conflict_row RECORD;
    parsed_op_id TEXT;
BEGIN
    FOR conflict_row IN
        SELECT conflict_id, vault_id, device_id, conflict_seq, envelope
        FROM conflicts
        ORDER BY vault_id, device_id, conflict_seq, conflict_id
    LOOP
        BEGIN
            parsed_op_id := (conflict_row.envelope::jsonb #>> '{header,op_id}');
        EXCEPTION WHEN OTHERS THEN
            parsed_op_id := NULL;
        END;

        IF parsed_op_id IS NULL
           OR length(parsed_op_id) <> 36
           OR lower(parsed_op_id) <> parsed_op_id
           OR EXISTS (
                SELECT 1 FROM conflicts c
                WHERE c.vault_id = conflict_row.vault_id
                  AND c.device_id = conflict_row.device_id
                  AND c.op_id = parsed_op_id
           )
        THEN
            CONTINUE;
        END IF;

        UPDATE conflicts
        SET op_id = parsed_op_id
        WHERE conflict_id = conflict_row.conflict_id;
    END LOOP;
END
$$;

CREATE UNIQUE INDEX idx_conflicts_device_op_id
    ON conflicts(vault_id, device_id, op_id)
    WHERE op_id IS NOT NULL;

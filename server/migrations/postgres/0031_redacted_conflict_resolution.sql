-- Preserve the conflict feed's resolution position after redaction scrubs the
-- resolved revision ID. Only the empty-envelope redacted form may retain a
-- resolution sequence without its revision identifier.

DO $$
DECLARE
    constraint_name TEXT;
BEGIN
    FOR constraint_name IN
        SELECT c.conname
        FROM pg_constraint c
        WHERE c.conrelid = 'conflicts'::regclass
          AND c.contype = 'c'
          AND pg_get_constraintdef(c.oid) LIKE '%resolved_revision_id%'
          AND pg_get_constraintdef(c.oid) LIKE '%resolution_seq%'
          AND pg_get_constraintdef(c.oid) LIKE '%resolution_at%'
    LOOP
        EXECUTE format('ALTER TABLE conflicts DROP CONSTRAINT %I', constraint_name);
    END LOOP;
END
$$;

ALTER TABLE conflicts
    ADD CONSTRAINT conflicts_redacted_resolution_check CHECK (
        (resolved_revision_id IS NULL AND resolution_seq IS NULL AND resolution_at IS NULL)
        OR
        (resolved_revision_id IS NOT NULL AND resolution_seq IS NOT NULL AND resolution_at IS NOT NULL)
        OR
        (envelope = '{}' AND resolved_revision_id IS NULL
            AND resolution_seq IS NOT NULL AND resolution_at IS NOT NULL
            AND resolution_seq > conflict_seq)
    );

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 31)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

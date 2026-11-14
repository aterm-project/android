-- Freeze the restore window per delete revision. Application startup or the
-- archive upgrade helper backfills legacy NULL values with the appropriate
-- runtime policy before the schema is used for requests.
ALTER TABLE record_versions ADD COLUMN restore_until TIMESTAMPTZ;

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 32)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

-- Freeze the restore window per delete revision. The application backfills
-- legacy NULL values from the effective policy before serving requests.
ALTER TABLE record_versions ADD COLUMN restore_until TEXT;

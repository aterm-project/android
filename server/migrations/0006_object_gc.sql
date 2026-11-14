ALTER TABLE blob_objects ADD COLUMN gc_after INTEGER;

CREATE INDEX IF NOT EXISTS idx_blob_objects_gc_after
    ON blob_objects(gc_after)
    WHERE gc_after IS NOT NULL;

-- Persist every head captured by a snapshot as an immutable, keyset-ordered
-- item so large Vaults can bootstrap through bounded pages. Existing
-- snapshot manifests are backfilled without changing their legacy JSON.
CREATE TABLE IF NOT EXISTS snapshot_items (
    snapshot_id TEXT NOT NULL REFERENCES snapshots(snapshot_id) ON DELETE CASCADE,
    record_id TEXT COLLATE BINARY NOT NULL,
    item_json TEXT NOT NULL,
    PRIMARY KEY(snapshot_id, record_id)
);

INSERT OR IGNORE INTO snapshot_items(snapshot_id, record_id, item_json)
SELECT s.snapshot_id,
       json_extract(item.value, '$.record_id'),
       item.value
FROM snapshots AS s,
     json_each(s.manifest_json) AS item
WHERE json_type(s.manifest_json) = 'array'
  AND json_type(item.value, '$.record_id') = 'text'
  AND json_extract(item.value, '$.record_id') <> '';

ALTER TABLE snapshots
    ADD COLUMN snapshot_item_count INTEGER NOT NULL DEFAULT 0
    CHECK (snapshot_item_count >= 0);

ALTER TABLE snapshots
    ADD COLUMN snapshot_manifest_format TEXT NOT NULL DEFAULT 'legacy'
    CHECK (snapshot_manifest_format IN ('legacy', 'inline', 'paged', 'expired'));

UPDATE snapshots
SET snapshot_item_count = (
        SELECT COUNT(*) FROM snapshot_items WHERE snapshot_items.snapshot_id = snapshots.snapshot_id
    ),
    snapshot_manifest_format = 'legacy';

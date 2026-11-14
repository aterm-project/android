-- Immutable per-record snapshot items support bounded keyset bootstrap pages.
CREATE TABLE snapshot_items (
    snapshot_id TEXT NOT NULL REFERENCES snapshots(snapshot_id) ON DELETE CASCADE,
    record_id TEXT COLLATE "C" NOT NULL,
    item_json TEXT NOT NULL,
    PRIMARY KEY(snapshot_id, record_id)
);

INSERT INTO snapshot_items(snapshot_id,record_id,item_json)
SELECT s.snapshot_id,
       item.value->>'record_id',
       item.value::TEXT
FROM snapshots AS s
CROSS JOIN LATERAL jsonb_array_elements(s.manifest_json::jsonb) AS item(value)
WHERE jsonb_typeof(s.manifest_json::jsonb) = 'array'
  AND jsonb_typeof(item.value->'record_id') = 'string'
  AND item.value->>'record_id' <> ''
ON CONFLICT (snapshot_id,record_id) DO NOTHING;

ALTER TABLE snapshots
    ADD COLUMN snapshot_item_count BIGINT NOT NULL DEFAULT 0 CHECK (snapshot_item_count >= 0),
    ADD COLUMN snapshot_manifest_format TEXT NOT NULL DEFAULT 'legacy'
        CHECK (snapshot_manifest_format IN ('legacy','inline','paged','expired'));

UPDATE snapshots
SET snapshot_item_count = (
        SELECT COUNT(*) FROM snapshot_items WHERE snapshot_items.snapshot_id = snapshots.snapshot_id
    ),
    snapshot_manifest_format = 'legacy';

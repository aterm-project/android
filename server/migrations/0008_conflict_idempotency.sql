-- Conflict branch retries are identified by the signed envelope's op_id,
-- scoped to the vault and submitting device. Keep this nullable so malformed
-- or duplicate legacy history rows can remain intact without blocking upgrade.
ALTER TABLE conflicts
    ADD COLUMN op_id TEXT;

-- Backfill one deterministic canonical receipt for each legacy
-- (vault,device,op_id) group. Any older duplicate rows remain visible in
-- history with op_id NULL; they are not deleted or rewritten.
WITH extracted AS (
    SELECT conflict_id,
           vault_id,
           device_id,
           conflict_seq,
           CASE
               WHEN json_valid(envelope) THEN json_extract(envelope, '$.header.op_id')
               ELSE NULL
           END AS op_id
    FROM conflicts
), ranked AS (
    SELECT conflict_id,
           op_id,
           ROW_NUMBER() OVER (
               PARTITION BY vault_id, device_id, op_id
               ORDER BY conflict_seq, conflict_id
           ) AS duplicate_rank
    FROM extracted
    WHERE typeof(op_id) = 'text'
      AND length(op_id) = 36
      AND lower(op_id) = op_id
)
UPDATE conflicts
SET op_id = (
    SELECT ranked.op_id
    FROM ranked
    WHERE ranked.conflict_id = conflicts.conflict_id
      AND ranked.duplicate_rank = 1
)
WHERE conflict_id IN (
    SELECT conflict_id
    FROM ranked
    WHERE duplicate_rank = 1
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_conflicts_device_op_id
    ON conflicts(vault_id, device_id, op_id)
    WHERE op_id IS NOT NULL;

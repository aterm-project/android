-- Conflict branches and their one-time resolution transition need an ordered
-- per-vault stream so an encrypted export can share one fixed snapshot
-- boundary with record revisions.
ALTER TABLE vault_counters
    ADD COLUMN last_conflict_seq INTEGER NOT NULL DEFAULT 0;

ALTER TABLE conflicts
    ADD COLUMN conflict_seq INTEGER NOT NULL DEFAULT 0;

ALTER TABLE conflicts
    ADD COLUMN resolution_seq INTEGER;

-- Existing branches have no sequence. Give them a deterministic order. Old
-- resolved states are placed after all old branch creations; old snapshots
-- remain NULL below because the old server never captured a conflict watermark.
WITH ranked AS (
    SELECT conflict_id,
           ROW_NUMBER() OVER (PARTITION BY vault_id ORDER BY created_at, conflict_id) AS seq
    FROM conflicts
)
UPDATE conflicts
SET conflict_seq = (
    SELECT ranked.seq
    FROM ranked
    WHERE ranked.conflict_id = conflicts.conflict_id
);

WITH ranked_resolutions AS (
    SELECT resolved.conflict_id,
           ROW_NUMBER() OVER (
               PARTITION BY resolved.vault_id
               ORDER BY resolved.conflict_seq, resolved.conflict_id
           ) AS seq,
           (SELECT COUNT(*)
            FROM conflicts AS all_branches
            WHERE all_branches.vault_id = resolved.vault_id) AS branch_count
    FROM conflicts AS resolved
    WHERE resolved.resolved_revision_id IS NOT NULL
)
UPDATE conflicts
SET resolution_seq = (
    SELECT ranked_resolutions.branch_count + ranked_resolutions.seq
    FROM ranked_resolutions
    WHERE ranked_resolutions.conflict_id = conflicts.conflict_id
)
WHERE resolved_revision_id IS NOT NULL;

UPDATE vault_counters
SET last_conflict_seq =
    (SELECT COUNT(*) FROM conflicts WHERE conflicts.vault_id = vault_counters.vault_id)
    + (SELECT COUNT(*) FROM conflicts
       WHERE conflicts.vault_id = vault_counters.vault_id
         AND conflicts.resolved_revision_id IS NOT NULL);

CREATE UNIQUE INDEX IF NOT EXISTS idx_conflicts_vault_seq
    ON conflicts(vault_id, conflict_seq);

CREATE INDEX IF NOT EXISTS idx_conflicts_vault_resolution_seq
    ON conflicts(vault_id, resolution_seq)
    WHERE resolution_seq IS NOT NULL;

-- NULL distinguishes legacy snapshots that cannot promise a conflict boundary.
-- Their existing GET manifest and change-cursor behavior stays unchanged;
-- complete history readers ask the client to create a fresh snapshot.
ALTER TABLE snapshots
    ADD COLUMN conflict_high_watermark INTEGER;

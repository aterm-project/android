-- Preserve the timestamp of each first successful conflict resolution so the
-- append-only conflict event feed can report the event time accurately.
ALTER TABLE conflicts
    ADD COLUMN resolution_at TEXT;

-- Older servers recorded the resolved revision but not the time the branch
-- was resolved. Use that revision's creation time as the best available
-- historical timestamp, falling back to the conflict creation time if its
-- revision row is unavailable.
UPDATE conflicts
SET resolution_at = COALESCE(
    (
        SELECT record_versions.created_at
        FROM record_versions
        WHERE record_versions.vault_id = conflicts.vault_id
          AND record_versions.record_id = conflicts.record_id
          AND record_versions.revision_id = conflicts.resolved_revision_id
    ),
    conflicts.created_at
)
WHERE resolved_revision_id IS NOT NULL;

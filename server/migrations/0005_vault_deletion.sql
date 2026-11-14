-- A deletion request is also a small audit record. It intentionally has no
-- foreign key to vaults or users so the final purge does not erase the audit.
CREATE TABLE IF NOT EXISTS vault_deletion_requests (
    request_id INTEGER PRIMARY KEY AUTOINCREMENT,
    vault_id TEXT NOT NULL,
    requested_at INTEGER NOT NULL,
    purge_after INTEGER NOT NULL,
    actor_hash TEXT,
    cancelled_at INTEGER,
    purged_at INTEGER,
    CHECK (purge_after > requested_at),
    CHECK (cancelled_at IS NULL OR purged_at IS NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_vault_deletion_one_pending
    ON vault_deletion_requests(vault_id)
    WHERE cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_vault_deletion_due
    ON vault_deletion_requests(purge_after)
    WHERE cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_vault_deletion_audit_retention
    ON vault_deletion_requests(COALESCE(purged_at, cancelled_at))
    WHERE cancelled_at IS NOT NULL OR purged_at IS NOT NULL;

-- The previous implementation could set a vault to `deleting` without a
-- deadline. Preserve that delete intent, granting a fresh default grace from
-- migration time so the new maintenance job cannot immediately purge it.
INSERT INTO vault_deletion_requests(vault_id, requested_at, purge_after, actor_hash)
SELECT v.vault_id, clock.now_epoch, clock.now_epoch + 604800, NULL
FROM vaults AS v
CROSS JOIN (SELECT CAST(strftime('%s', 'now') AS INTEGER) AS now_epoch) AS clock
WHERE v.state = 'deleting';

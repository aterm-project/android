-- Account deletion is delayed and reversible. The ledger intentionally has
-- no FK to users so its anonymous terminal audit survives account cleanup.
CREATE TABLE IF NOT EXISTS account_deletion_requests (
    request_id TEXT PRIMARY KEY,
    user_id TEXT,
    requested_at INTEGER NOT NULL,
    purge_after INTEGER NOT NULL,
    actor_hash TEXT NOT NULL,
    cancelled_at INTEGER,
    purged_at INTEGER,
    CHECK (purge_after > requested_at),
    CHECK (cancelled_at IS NULL OR purged_at IS NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_account_deletion_one_pending
    ON account_deletion_requests(user_id)
    WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_account_deletion_due
    ON account_deletion_requests(purge_after)
    WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_account_deletion_audit_retention
    ON account_deletion_requests(COALESCE(purged_at, cancelled_at))
    WHERE cancelled_at IS NOT NULL OR purged_at IS NOT NULL;

-- Marks exactly the devices revoked by a pending account deletion. Cancellation
-- may reactivate only these devices; sessions remain revoked and are not reused.
ALTER TABLE devices ADD COLUMN account_deletion_request_id TEXT;

-- A deleted account's public keys may still be required to validate signatures
-- on immutable records in surviving shared vaults. Keep only vault-scoped,
-- public verification material. Vault deletion cascades this archive.
CREATE TABLE IF NOT EXISTS vault_device_archives (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    encryption_public_key TEXT NOT NULL,
    archived_at TEXT NOT NULL,
    PRIMARY KEY(vault_id, device_id)
);

CREATE INDEX IF NOT EXISTS idx_vault_device_archives_user
    ON vault_device_archives(user_id, vault_id);

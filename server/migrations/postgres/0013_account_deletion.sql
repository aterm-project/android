-- PostgreSQL account deletion lifecycle.
--
-- The request survives account removal, so it deliberately has no user
-- foreign key. Shared Vault signatures retain signer device IDs after the
-- device row is removed; vault-scoped public key archives are the lookup path
-- for those historical signatures.

ALTER TABLE devices
    ADD COLUMN account_deletion_request_id TEXT;

CREATE TABLE account_deletion_requests (
    request_id TEXT PRIMARY KEY,
    user_id TEXT,
    requested_at BIGINT NOT NULL,
    purge_after BIGINT NOT NULL,
    actor_hash TEXT NOT NULL CHECK (actor_hash ~ '^[0-9a-f]{64}$'),
    cancelled_at BIGINT,
    purged_at BIGINT,
    CHECK (purge_after > requested_at),
    CHECK (cancelled_at IS NULL OR purged_at IS NULL)
);

CREATE UNIQUE INDEX idx_account_deletion_one_pending
    ON account_deletion_requests(user_id)
    WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX idx_account_deletion_due
    ON account_deletion_requests(purge_after, request_id)
    WHERE user_id IS NOT NULL AND cancelled_at IS NULL AND purged_at IS NULL;

CREATE INDEX idx_account_deletion_retention
    ON account_deletion_requests(COALESCE(purged_at, cancelled_at), request_id)
    WHERE cancelled_at IS NOT NULL OR purged_at IS NOT NULL;

CREATE INDEX idx_devices_account_deletion_request
    ON devices(user_id, account_deletion_request_id)
    WHERE account_deletion_request_id IS NOT NULL;

CREATE TABLE vault_device_archives (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    encryption_public_key TEXT NOT NULL,
    archived_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (vault_id, device_id)
);

CREATE INDEX idx_vault_device_archives_user
    ON vault_device_archives(user_id, vault_id);

-- Historical signatures and key-envelope provenance must remain verifiable
-- after a contributor leaves. Recipient ownership still cascades separately,
-- so a purged account's private key envelope is removed.
ALTER TABLE membership_manifests
    DROP CONSTRAINT IF EXISTS membership_manifests_signer_device_id_fkey;

ALTER TABLE vault_key_envelopes
    DROP CONSTRAINT IF EXISTS vault_key_envelopes_signer_device_id_fkey;

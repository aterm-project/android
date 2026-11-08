-- PostgreSQL first-account bootstrap and username-bound invitation storage.
-- Existing accounts and instance identity metadata are retained in place.

ALTER TABLE instance_meta
    ADD COLUMN bootstrap_token_hash TEXT,
    ADD COLUMN setup_consumed_at TIMESTAMPTZ;

CREATE TABLE account_invitations (
    invitation_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    consumed_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL
);
CREATE INDEX idx_account_invitations_username
    ON account_invitations(username, expires_at, consumed_at, revoked_at);

CREATE TABLE vault_key_envelopes (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    epoch BIGINT NOT NULL CHECK (epoch > 0),
    recipient_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL,
    envelope JSONB NOT NULL,
    envelope_signature TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    membership_version BIGINT NOT NULL CHECK (membership_version > 0),
    PRIMARY KEY (vault_id, epoch, recipient_device_id),
    FOREIGN KEY (recipient_device_id, recipient_user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE
);

CREATE TABLE membership_manifests (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    membership_version BIGINT NOT NULL CHECK (membership_version > 0),
    previous_digest TEXT,
    manifest_json JSONB NOT NULL,
    digest TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    signature TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (vault_id, membership_version)
);

-- CLI-issued invitation audit rows have an instance scope. Retain all existing
-- rows while widening only the allowed scope values.
ALTER TABLE audit_events
    DROP CONSTRAINT audit_events_scope_type_check;
ALTER TABLE audit_events
    ADD CONSTRAINT audit_events_scope_type_check
        CHECK (scope_type IN ('account', 'vault', 'instance'));

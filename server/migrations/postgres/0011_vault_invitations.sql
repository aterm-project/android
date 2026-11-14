-- Device-addressed, single-use Vault invitations. The plaintext bearer token
-- is returned once by the API; only its SHA-256 hex digest is persisted.
CREATE TABLE invitations (
    invitation_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE
        CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    role TEXT NOT NULL CHECK (role IN ('editor', 'viewer')),
    key_envelope JSONB NOT NULL CHECK (
        jsonb_typeof(key_envelope) = 'object'
        AND key_envelope ?& ARRAY[
            'recipient_device_id', 'key_epoch', 'membership_version', 'envelope', 'signature'
        ]
        AND jsonb_typeof(key_envelope->'recipient_device_id') = 'string'
        AND jsonb_typeof(key_envelope->'key_epoch') = 'number'
        AND key_envelope->>'key_epoch' ~ '^[1-9][0-9]*$'
        AND jsonb_typeof(key_envelope->'membership_version') = 'number'
        AND key_envelope->>'membership_version' ~ '^[1-9][0-9]*$'
        AND jsonb_typeof(key_envelope->'envelope') = 'object'
        AND jsonb_typeof(key_envelope->'signature') = 'string'
        AND key_envelope->>'signature' <> ''
    ),
    recipient_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(user_id),
    expires_at TIMESTAMPTZ NOT NULL,
    accepted_by TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    accepted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    issuance_order BIGINT NOT NULL CHECK (issuance_order > 0),
    CHECK (expires_at > created_at),
    CHECK (
        (accepted_at IS NULL AND accepted_by IS NULL)
        OR (accepted_at IS NOT NULL AND accepted_by IS NOT NULL
            AND accepted_by = recipient_user_id)
    ),
    CHECK (key_envelope->>'recipient_device_id' = recipient_device_id),
    FOREIGN KEY (recipient_device_id, recipient_user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    UNIQUE (vault_id, recipient_user_id, issuance_order)
);

CREATE INDEX idx_invitation_pending_recipient_order
    ON invitations(
        vault_id,
        recipient_user_id,
        issuance_order DESC,
        created_at DESC,
        invitation_id DESC
    )
    WHERE accepted_at IS NULL;

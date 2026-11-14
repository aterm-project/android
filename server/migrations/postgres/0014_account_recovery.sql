-- Client-encrypted account recovery for PostgreSQL-backed service nodes.
-- The server stores public recovery keys, opaque ciphertext, hashes, and
-- response-loss idempotency receipts. Recovery private material and codes stay
-- on clients.

CREATE TABLE account_recovery (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation BIGINT NOT NULL CHECK (recovery_generation > 0),
    recovery_public_signing_key TEXT NOT NULL,
    recovery_public_encryption_key TEXT NOT NULL,
    recovery_envelope TEXT NOT NULL,
    recovery_identity_envelope TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL
);

-- Keep generation outside the removable descriptor so disable/re-enable
-- cannot make an older recovery challenge or envelope current again.
CREATE TABLE account_recovery_generation (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    last_generation BIGINT NOT NULL CHECK (last_generation >= 0)
);

INSERT INTO account_recovery_generation(user_id, last_generation)
SELECT user_id, recovery_generation FROM account_recovery;

CREATE TABLE account_recovery_key_envelopes (
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation BIGINT NOT NULL CHECK (recovery_generation > 0),
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    key_epoch BIGINT NOT NULL CHECK (key_epoch > 0),
    envelope TEXT NOT NULL,
    recovery_signature TEXT NOT NULL,
    -- Historical uploader IDs intentionally have no device FK: deleting a
    -- device must not invalidate a still-needed Vault recovery envelope.
    uploader_device_id TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (user_id, recovery_generation, vault_id, key_epoch)
);
CREATE INDEX idx_recovery_key_envelopes_context
    ON account_recovery_key_envelopes(user_id, vault_id, key_epoch);

-- Decoy start requests use NULL user_id. Real rows cascade on account purge;
-- the identifier/value themselves are never persisted, only their hashes.
CREATE TABLE account_recovery_challenges (
    challenge_id_hash TEXT PRIMARY KEY CHECK (challenge_id_hash ~ '^[0-9a-f]{64}$'),
    challenge_hash TEXT NOT NULL CHECK (challenge_hash ~ '^[0-9a-f]{64}$'),
    user_id TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation BIGINT NOT NULL CHECK (recovery_generation > 0),
    expires_at BIGINT NOT NULL,
    consumed_at BIGINT
);
CREATE INDEX idx_recovery_challenges_expiry
    ON account_recovery_challenges(expires_at);

-- Completion retries can return the original opaque success response after
-- sessions have been revoked. Receipts are account-owned and purge with it.
CREATE TABLE account_recovery_receipts (
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL,
    request_digest TEXT NOT NULL CHECK (request_digest ~ '^[0-9a-f]{64}$'),
    response_json TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    PRIMARY KEY (user_id, operation_id)
);

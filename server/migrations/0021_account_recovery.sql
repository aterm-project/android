-- Client encrypted account recovery. The server stores only opaque envelopes,
-- public verification keys, challenge hashes and keyed idempotency digests.
CREATE TABLE account_recovery (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation INTEGER NOT NULL CHECK (recovery_generation > 0),
    recovery_public_signing_key TEXT NOT NULL,
    recovery_public_encryption_key TEXT NOT NULL,
    recovery_envelope TEXT NOT NULL,
    recovery_identity_envelope TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE account_recovery_key_envelopes (
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation INTEGER NOT NULL CHECK (recovery_generation > 0),
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    key_epoch INTEGER NOT NULL CHECK (key_epoch > 0),
    envelope TEXT NOT NULL,
    recovery_signature TEXT NOT NULL,
    uploader_device_id TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(user_id, recovery_generation, vault_id, key_epoch)
);
CREATE INDEX idx_recovery_key_envelopes_context
    ON account_recovery_key_envelopes(user_id, vault_id, key_epoch);

-- Public challenge identifiers and values are never stored, only their hashes.
CREATE TABLE account_recovery_challenges (
    challenge_id_hash TEXT PRIMARY KEY CHECK (
        length(challenge_id_hash) = 64 AND challenge_id_hash NOT GLOB '*[^0-9a-f]*'
    ),
    challenge_hash TEXT NOT NULL CHECK (
        length(challenge_hash) = 64 AND challenge_hash NOT GLOB '*[^0-9a-f]*'
    ),
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation INTEGER NOT NULL CHECK (recovery_generation > 0),
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);
CREATE INDEX idx_recovery_challenges_expiry
    ON account_recovery_challenges(expires_at);

-- One opaque HMAC receipt per account/operation ID; response JSON contains no
-- secrets and allows response-loss retries after completion revoked sessions.
CREATE TABLE account_recovery_receipts (
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL,
    request_digest TEXT NOT NULL CHECK (
        length(request_digest) = 64 AND request_digest NOT GLOB '*[^0-9a-f]*'
    ),
    response_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    PRIMARY KEY(user_id, operation_id)
);

-- Extend the bounded persistent auth limiter for recovery's username based
-- anonymous start and completion requests while preserving existing buckets.
DROP TRIGGER IF EXISTS auth_rate_limits_count_insert;
DROP TRIGGER IF EXISTS auth_rate_limits_count_delete;
DROP INDEX IF EXISTS idx_auth_rate_limits_expiry;
ALTER TABLE auth_rate_limits RENAME TO auth_rate_limits_old;
CREATE TABLE auth_rate_limits (
    scope TEXT NOT NULL CHECK (scope IN ('user', 'pair', 'ip')),
    endpoint TEXT NOT NULL CHECK (endpoint IN ('prelogin', 'login', 'register', 'recovery_start', 'recovery_complete')),
    subject_hash TEXT NOT NULL,
    window_started INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    PRIMARY KEY(scope, endpoint, subject_hash, window_started)
);
INSERT INTO auth_rate_limits(scope, endpoint, subject_hash, window_started, attempts)
SELECT scope, endpoint, subject_hash, window_started, attempts FROM auth_rate_limits_old;
DROP TABLE auth_rate_limits_old;
CREATE INDEX idx_auth_rate_limits_expiry ON auth_rate_limits(window_started);
CREATE TRIGGER auth_rate_limits_count_insert
AFTER INSERT ON auth_rate_limits
BEGIN
    UPDATE auth_rate_limit_meta SET bucket_count=bucket_count+1 WHERE id=1;
END;
CREATE TRIGGER auth_rate_limits_count_delete
AFTER DELETE ON auth_rate_limits
BEGIN
    UPDATE auth_rate_limit_meta SET bucket_count=bucket_count-1 WHERE id=1;
END;

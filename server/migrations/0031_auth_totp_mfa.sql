CREATE TABLE auth_mfa (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    totp_seed_envelope TEXT,
    enabled_at INTEGER,
    last_totp_step INTEGER,
    pending_seed_envelope TEXT,
    pending_expires_at INTEGER,
    pending_credential_version INTEGER,
    CHECK (
        (totp_seed_envelope IS NULL AND enabled_at IS NULL AND last_totp_step IS NULL)
        OR
        (totp_seed_envelope IS NOT NULL AND enabled_at IS NOT NULL AND last_totp_step IS NOT NULL)
    ),
    CHECK (
        (pending_seed_envelope IS NULL AND pending_expires_at IS NULL AND pending_credential_version IS NULL)
        OR
        (pending_seed_envelope IS NOT NULL AND pending_expires_at IS NOT NULL AND pending_credential_version IS NOT NULL)
    )
);

CREATE TABLE auth_mfa_recovery_codes (
    code_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES auth_mfa(user_id) ON DELETE CASCADE,
    salt TEXT NOT NULL CHECK (length(salt) = 22),
    code_hash TEXT NOT NULL CHECK (length(code_hash) = 64),
    created_at INTEGER NOT NULL,
    consumed_at INTEGER,
    UNIQUE(user_id, code_hash)
);
CREATE INDEX idx_auth_mfa_recovery_codes_remaining
    ON auth_mfa_recovery_codes(user_id, consumed_at);

CREATE TABLE auth_mfa_login_challenges (
    challenge_id_hash TEXT PRIMARY KEY CHECK (length(challenge_id_hash) = 64),
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    credential_version INTEGER NOT NULL CHECK (credential_version > 0),
    expires_at INTEGER NOT NULL,
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 5),
    consumed_at INTEGER
);
CREATE INDEX idx_auth_mfa_login_challenges_user_expiry
    ON auth_mfa_login_challenges(user_id, expires_at);

-- MFA completion uses the existing bounded authentication buckets under its
-- own endpoint label. Rebuild the checked enum while preserving every live
-- bucket and its global capacity accounting.
DROP TRIGGER IF EXISTS auth_rate_limits_count_insert;
DROP TRIGGER IF EXISTS auth_rate_limits_count_delete;
DROP INDEX IF EXISTS idx_auth_rate_limits_expiry;
ALTER TABLE auth_rate_limits RENAME TO auth_rate_limits_old;
CREATE TABLE auth_rate_limits (
    scope TEXT NOT NULL CHECK (scope IN ('user', 'pair', 'ip')),
    endpoint TEXT NOT NULL CHECK (endpoint IN (
        'prelogin', 'login', 'mfa_login', 'register', 'recovery_start', 'recovery_complete'
    )),
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

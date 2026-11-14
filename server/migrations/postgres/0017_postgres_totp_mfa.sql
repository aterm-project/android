-- PostgreSQL TOTP enrollment, single-use recovery codes, and password-login
-- challenges. Challenges belong to an enabled/pending MFA row so deleting MFA
-- state (disable or Recovery reset) invalidates them even after reenrollment.

CREATE TABLE auth_mfa_recovery_codes (
    code_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES auth_mfa(user_id) ON DELETE CASCADE,
    salt TEXT NOT NULL CHECK (salt ~ '^[A-Za-z0-9_-]{22}$'),
    code_hash TEXT NOT NULL CHECK (code_hash ~ '^[0-9a-f]{64}$'),
    created_at BIGINT NOT NULL,
    consumed_at BIGINT,
    UNIQUE (user_id, code_hash)
);
CREATE INDEX idx_auth_mfa_recovery_codes_active
    ON auth_mfa_recovery_codes(user_id, code_id) WHERE consumed_at IS NULL;

CREATE TABLE auth_mfa_login_challenges (
    challenge_id_hash TEXT PRIMARY KEY
        CHECK (challenge_id_hash ~ '^[0-9a-f]{64}$'),
    user_id TEXT NOT NULL CONSTRAINT auth_mfa_login_challenges_user_id_fkey
        REFERENCES auth_mfa(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    credential_version BIGINT NOT NULL CHECK (credential_version > 0),
    expires_at BIGINT NOT NULL,
    attempt_count BIGINT NOT NULL DEFAULT 0 CHECK (attempt_count BETWEEN 0 AND 5),
    consumed_at BIGINT,
    FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_auth_mfa_login_challenges_user_expiry
    ON auth_mfa_login_challenges(user_id, expires_at)
    WHERE consumed_at IS NULL;
CREATE INDEX idx_auth_mfa_login_challenges_expiry
    ON auth_mfa_login_challenges(expires_at);

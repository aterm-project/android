-- Narrow PostgreSQL authentication lifecycle support for provisioned users.
-- Registration/bootstrap and invitation issuance are deliberately separate.

CREATE TABLE auth_credentials (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    login_verifier_hash TEXT NOT NULL,
    verifier_salt TEXT NOT NULL,
    kdf_json TEXT NOT NULL,
    account_key_envelope TEXT NOT NULL,
    credential_version BIGINT NOT NULL DEFAULT 1 CHECK (credential_version > 0)
);

-- Consumed refresh hashes are durable replay evidence. Keep this ledger
-- independent of account/device rows so purge does not erase reuse evidence.
CREATE TABLE refresh_history (
    refresh_hash TEXT PRIMARY KEY,
    family_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    consumed_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX idx_refresh_family ON refresh_history(family_id);

-- This is the MFA state needed by password login to fail closed. Enrollment,
-- recovery-code, and challenge endpoints remain outside this migration.
CREATE TABLE auth_mfa (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    totp_seed_envelope TEXT,
    enabled_at BIGINT,
    last_totp_step BIGINT,
    pending_seed_envelope TEXT,
    pending_expires_at BIGINT,
    pending_credential_version BIGINT,
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

ALTER TABLE audit_events
    DROP CONSTRAINT audit_events_result_check;
ALTER TABLE audit_events
    ADD CONSTRAINT audit_events_result_check CHECK (result IN ('success', 'failure'));

-- Retain one non-secret response-loss receipt for the caller's preserved
-- session. Request bodies, verifiers, KDF material, and account-key envelopes
-- are never stored in this table.
CREATE TABLE password_change_receipts (
    session_id TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL,
    request_digest TEXT NOT NULL CHECK (request_digest ~ '^[0-9a-f]{64}$'),
    credential_version BIGINT NOT NULL CHECK (credential_version > 1),
    created_at BIGINT NOT NULL
);

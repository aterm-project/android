-- One non-secret response-loss receipt per retained caller session. The
-- request body and all verifier/envelope values are never stored.
CREATE TABLE password_change_receipts (
    session_id TEXT PRIMARY KEY REFERENCES sessions(session_id) ON DELETE CASCADE,
    operation_id TEXT NOT NULL,
    request_digest TEXT NOT NULL CHECK (
        length(request_digest) = 64 AND request_digest NOT GLOB '*[^0-9a-f]*'
    ),
    credential_version INTEGER NOT NULL CHECK (credential_version > 1),
    created_at INTEGER NOT NULL
);

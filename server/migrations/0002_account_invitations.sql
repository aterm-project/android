CREATE TABLE IF NOT EXISTS account_invitations (
    invitation_id TEXT PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    username TEXT NOT NULL,
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT,
    revoked_at TEXT,
    consumed_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_account_invitations_username
    ON account_invitations(username, expires_at, consumed_at, revoked_at);

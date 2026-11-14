-- Bound authenticated heartbeat writes per session and Vault while preserving
-- independent leases for the same session across different Vaults.
CREATE TABLE IF NOT EXISTS vault_presence_heartbeat_limits (
    vault_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    last_heartbeat_at INTEGER NOT NULL, -- Unix milliseconds.
    PRIMARY KEY (vault_id, session_id),
    FOREIGN KEY (vault_id) REFERENCES vaults(vault_id) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_vault_presence_heartbeat_limit_expiry
    ON vault_presence_heartbeat_limits(last_heartbeat_at);
CREATE INDEX IF NOT EXISTS idx_vault_presence_session
    ON vault_presence(session_id);
CREATE INDEX IF NOT EXISTS idx_vault_presence_vault_user_expiry
    ON vault_presence(vault_id, user_id, expires_at);
CREATE INDEX IF NOT EXISTS idx_vault_presence_vault_expiry
    ON vault_presence(vault_id, expires_at);

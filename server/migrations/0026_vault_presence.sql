-- Short-lived device presence is a lease, not Vault content or audit history.
-- Rows are keyed by authenticated session so parallel sessions do not replace
-- one another; consumers collapse live leases to one device entry.
CREATE TABLE IF NOT EXISTS vault_presence (
    vault_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    last_seen_at TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    PRIMARY KEY (vault_id, session_id),
    FOREIGN KEY (vault_id, user_id)
        REFERENCES vault_members(vault_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (device_id) REFERENCES devices(device_id) ON DELETE CASCADE,
    FOREIGN KEY (session_id) REFERENCES sessions(session_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_vault_presence_expiry
    ON vault_presence(expires_at);
CREATE INDEX IF NOT EXISTS idx_vault_presence_vault_device
    ON vault_presence(vault_id, user_id, device_id, expires_at);

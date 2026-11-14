-- Shared short-lived presence leases for PostgreSQL-backed Vault members.
-- Presence is operational state; it is not encrypted Vault history or audit.
CREATE TABLE vault_presence (
    vault_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    last_seen_at TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (vault_id, session_id),
    FOREIGN KEY (vault_id, user_id)
        REFERENCES vault_members(vault_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_vault_presence_expiry ON vault_presence(expires_at);
CREATE INDEX idx_vault_presence_session ON vault_presence(session_id);
CREATE INDEX idx_vault_presence_vault_user_expiry
    ON vault_presence(vault_id, user_id, expires_at);
CREATE INDEX idx_vault_presence_vault_expiry
    ON vault_presence(vault_id, expires_at);

-- Bound heartbeat writes by authenticated session and Vault, while allowing
-- one session to publish independent leases into multiple Vaults.
CREATE TABLE vault_presence_heartbeat_limits (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    last_heartbeat_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (vault_id, session_id)
);
CREATE INDEX idx_vault_presence_heartbeat_limit_expiry
    ON vault_presence_heartbeat_limits(last_heartbeat_at);

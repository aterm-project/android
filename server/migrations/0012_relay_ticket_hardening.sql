-- Legacy tickets cannot prove which session issued them and therefore fail
-- closed after this migration. Their existing 30-second TTL bounds cleanup.
ALTER TABLE relay_tickets ADD COLUMN session_id TEXT;
ALTER TABLE relay_tickets ADD COLUMN session_access_expires_at TEXT;
ALTER TABLE relay_tickets ADD COLUMN created_at INTEGER NOT NULL DEFAULT 0;

CREATE INDEX idx_relay_tickets_expires
    ON relay_tickets(expires_at);
CREATE INDEX idx_relay_tickets_user_created
    ON relay_tickets(user_id, created_at);

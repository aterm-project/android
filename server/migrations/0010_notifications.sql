CREATE TABLE notification_tickets (
    ticket_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    session_id TEXT NOT NULL REFERENCES sessions(session_id) ON DELETE CASCADE,
    server_generation TEXT NOT NULL,
    session_access_expires_at TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

CREATE INDEX idx_notification_tickets_expiry
    ON notification_tickets(expires_at);
CREATE INDEX idx_notification_tickets_user_created
    ON notification_tickets(user_id, created_at);
CREATE INDEX idx_notification_tickets_session_created
    ON notification_tickets(session_id, created_at);

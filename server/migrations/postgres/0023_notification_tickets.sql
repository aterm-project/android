-- Short-lived, single-use WebSocket credentials for metadata-only sync hints.
-- The bearer ticket itself and Vault/record content are never stored here.

CREATE TABLE notification_tickets (
    ticket_hash TEXT NOT NULL,
    user_id TEXT NOT NULL
        CONSTRAINT notification_tickets_user_id_fkey
        REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL
        CONSTRAINT notification_tickets_session_id_fkey
        REFERENCES sessions(session_id) ON DELETE CASCADE,
    server_generation TEXT NOT NULL,
    session_access_expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    CONSTRAINT notification_tickets_pkey PRIMARY KEY (ticket_hash),
    CONSTRAINT notification_tickets_hash_format
        CHECK (ticket_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT notification_tickets_device_user_fkey
        FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    CONSTRAINT notification_tickets_expiry_after_creation
        CHECK (expires_at > created_at),
    CONSTRAINT notification_tickets_expiry_within_session
        CHECK (expires_at <= session_access_expires_at)
);

-- These indexes bound per-user/per-session issuance-rate checks and make
-- expiry cleanup independent of ticket consumption order.
CREATE INDEX idx_notification_tickets_user_created
    ON notification_tickets(user_id, created_at DESC);
CREATE INDEX idx_notification_tickets_session_created
    ON notification_tickets(session_id, created_at DESC);
CREATE INDEX idx_notification_tickets_expiry
    ON notification_tickets(expires_at);
CREATE INDEX idx_notification_tickets_created
    ON notification_tickets(created_at);

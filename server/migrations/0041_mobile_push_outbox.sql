-- Optional mobile push routing metadata. Provider tokens are encrypted by the
-- application before they reach this table; the outbox contains only opaque
-- endpoint IDs and delivery bookkeeping.
CREATE UNIQUE INDEX idx_devices_id_user
    ON devices(device_id,user_id);

CREATE TABLE notification_push_endpoints (
    endpoint_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('fcm_v1','apns')),
    token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash)=64),
    token_envelope TEXT NOT NULL CHECK (length(token_envelope) BETWEEN 80 AND 8192),
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    UNIQUE(device_id,provider),
    FOREIGN KEY(device_id,user_id) REFERENCES devices(device_id,user_id) ON DELETE CASCADE,
    FOREIGN KEY(user_id) REFERENCES users(user_id) ON DELETE CASCADE
);

CREATE INDEX idx_notification_push_endpoints_user
    ON notification_push_endpoints(user_id,device_id);

CREATE TABLE notification_push_outbox (
    endpoint_id TEXT PRIMARY KEY REFERENCES notification_push_endpoints(endpoint_id) ON DELETE CASCADE,
    requested_seq INTEGER NOT NULL CHECK (requested_seq > 0),
    delivered_seq INTEGER NOT NULL DEFAULT 0 CHECK (delivered_seq >= 0),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at INTEGER NOT NULL,
    lease_id TEXT,
    lease_until INTEGER,
    dead_lettered INTEGER NOT NULL DEFAULT 0 CHECK (dead_lettered IN (0,1)),
    updated_at INTEGER NOT NULL,
    CHECK (delivered_seq <= requested_seq),
    CHECK ((lease_id IS NULL AND lease_until IS NULL) OR
           (lease_id IS NOT NULL AND lease_until IS NOT NULL))
);

CREATE INDEX idx_notification_push_outbox_due
    ON notification_push_outbox(dead_lettered,next_attempt_at,lease_until,updated_at);

CREATE TRIGGER purge_notification_push_endpoints_on_device_revocation
AFTER UPDATE OF status ON devices
WHEN OLD.status='active' AND NEW.status!='active'
BEGIN
    DELETE FROM notification_push_endpoints WHERE device_id=NEW.device_id;
END;

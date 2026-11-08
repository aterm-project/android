CREATE TABLE audit_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope_type TEXT NOT NULL CHECK (scope_type IN ('account', 'vault')),
    scope_id TEXT NOT NULL,
    actor_user_id TEXT,
    actor_device_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    result TEXT NOT NULL CHECK (result = 'success'),
    occurred_at INTEGER NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('api', 'maintenance'))
);

CREATE INDEX idx_audit_events_scope_event
    ON audit_events(scope_type, scope_id, event_id);
CREATE INDEX idx_audit_events_retention
    ON audit_events(occurred_at);
CREATE INDEX idx_audit_events_actor
    ON audit_events(actor_user_id, event_id);

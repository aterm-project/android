-- Login failures are auditable only after attribution to an existing account.
-- Keep all prior successful audit metadata byte-for-byte intact while allowing
-- the second fixed result value.
DROP INDEX idx_audit_events_scope_event;
DROP INDEX idx_audit_events_retention;
DROP INDEX idx_audit_events_actor;

ALTER TABLE audit_events RENAME TO audit_events_v11;

CREATE TABLE audit_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope_type TEXT NOT NULL CHECK (scope_type IN ('account', 'vault')),
    scope_id TEXT NOT NULL,
    actor_user_id TEXT,
    actor_device_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    result TEXT NOT NULL CHECK (result IN ('success', 'failure')),
    occurred_at INTEGER NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('api', 'maintenance'))
);

INSERT INTO audit_events(
    event_id,scope_type,scope_id,actor_user_id,actor_device_id,action,
    resource_type,resource_id,result,occurred_at,source
)
SELECT
    event_id,scope_type,scope_id,actor_user_id,actor_device_id,action,
    resource_type,resource_id,result,occurred_at,source
FROM audit_events_v11;

DROP TABLE audit_events_v11;

CREATE INDEX idx_audit_events_scope_event
    ON audit_events(scope_type, scope_id, event_id);
CREATE INDEX idx_audit_events_retention
    ON audit_events(occurred_at);
CREATE INDEX idx_audit_events_actor
    ON audit_events(actor_user_id, event_id);

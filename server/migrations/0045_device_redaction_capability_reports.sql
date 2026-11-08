-- Device capability for the permanent record-redaction protocol is kept
-- separate from the existing schema/attachment report so older clients can
-- continue verifying that strict signed payload without schema changes.
CREATE TABLE device_redaction_capability_reports (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    sync_redaction_version INTEGER NOT NULL CHECK (sync_redaction_version = 1),
    signature TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    invalidated_at TEXT,
    UNIQUE (device_id, user_id)
);

CREATE INDEX idx_device_redaction_capability_reports_user
    ON device_redaction_capability_reports(user_id, device_id);

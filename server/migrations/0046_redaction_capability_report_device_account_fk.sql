-- SQLite cannot ALTER a table to add a composite foreign key. Rebuild the
-- small report table so its device/account pair is constrained like the
-- PostgreSQL table. The parent pair needs its own unique index even though
-- device_id is already the devices primary key.
CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_device_user_unique
    ON devices(device_id, user_id);

CREATE TABLE device_redaction_capability_reports_v0046 (
    device_id TEXT PRIMARY KEY NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    sync_redaction_version INTEGER NOT NULL CHECK (sync_redaction_version = 1),
    signature TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    invalidated_at TEXT,
    FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE
);

INSERT INTO device_redaction_capability_reports_v0046(
    device_id, user_id, revision, sync_redaction_version, signature,
    updated_at, invalidated_at
)
SELECT device_id, user_id, revision, sync_redaction_version, signature,
       updated_at, invalidated_at
FROM device_redaction_capability_reports;

DROP TABLE device_redaction_capability_reports;
ALTER TABLE device_redaction_capability_reports_v0046
    RENAME TO device_redaction_capability_reports;

CREATE INDEX idx_device_redaction_capability_reports_user
    ON device_redaction_capability_reports(user_id, device_id);

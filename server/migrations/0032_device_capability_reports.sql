ALTER TABLE vaults
    ADD COLUMN required_record_schema INTEGER NOT NULL DEFAULT 1
    CHECK (required_record_schema BETWEEN 1 AND 2);

CREATE TABLE device_capability_reports (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision > 0),
    max_record_schema INTEGER NOT NULL CHECK (max_record_schema BETWEEN 1 AND 2),
    host_attachment_manifest_versions TEXT NOT NULL
        CHECK (json_valid(host_attachment_manifest_versions)
            AND json_type(host_attachment_manifest_versions) = 'array'),
    max_attachment_bytes INTEGER NOT NULL CHECK (max_attachment_bytes BETWEEN 0 AND 1073741824),
    signature TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_device_capability_reports_user
    ON device_capability_reports(user_id, device_id);

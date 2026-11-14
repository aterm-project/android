-- Separately signed report for clients that can retain and verify permanent
-- sync redaction markers. This must remain independent of the older record
-- schema capability report: legacy clients reject unknown fields there.

CREATE TABLE device_redaction_capability_reports (
    device_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL CHECK (revision > 0),
    sync_redaction_version BIGINT NOT NULL CHECK (sync_redaction_version = 1),
    signature TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    invalidated_at TIMESTAMPTZ,
    FOREIGN KEY (device_id, account_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE
);

CREATE INDEX idx_device_redaction_capability_account
    ON device_redaction_capability_reports(account_id, device_id);

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 29)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

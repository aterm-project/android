-- Test-only PostgreSQL sync transaction pilot. This fixture is loaded into a
-- unique disposable schema by pg_sync_core.rs and is not a production schema
-- or migration.
CREATE TABLE pilot_accounts (
    user_id TEXT PRIMARY KEY,
    active BOOLEAN NOT NULL
);

CREATE TABLE pilot_devices (
    device_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES pilot_accounts(user_id),
    active BOOLEAN NOT NULL
);

CREATE TABLE pilot_sessions (
    session_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES pilot_accounts(user_id),
    device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    active BOOLEAN NOT NULL,
    access_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE pilot_vaults (
    vault_id TEXT PRIMARY KEY,
    active BOOLEAN NOT NULL,
    key_epoch BIGINT NOT NULL,
    membership_version BIGINT NOT NULL
);

CREATE TABLE pilot_memberships (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    user_id TEXT NOT NULL REFERENCES pilot_accounts(user_id),
    role TEXT NOT NULL,
    active BOOLEAN NOT NULL,
    membership_version BIGINT NOT NULL,
    PRIMARY KEY (vault_id, user_id)
);

CREATE TABLE pilot_vault_counters (
    vault_id TEXT PRIMARY KEY REFERENCES pilot_vaults(vault_id),
    last_committed_seq BIGINT NOT NULL DEFAULT 0
);

CREATE TABLE pilot_record_heads (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    deleted BOOLEAN NOT NULL DEFAULT FALSE,
    commit_seq BIGINT NOT NULL,
    PRIMARY KEY (vault_id, record_id)
);

CREATE TABLE pilot_record_versions (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    base_revision_id TEXT,
    envelope TEXT NOT NULL,
    digest TEXT NOT NULL,
    commit_seq BIGINT NOT NULL,
    device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    operation TEXT NOT NULL,
    PRIMARY KEY (vault_id, record_id, revision_id),
    UNIQUE (vault_id, commit_seq)
);

CREATE TABLE pilot_change_events (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    commit_seq BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    envelope TEXT NOT NULL,
    PRIMARY KEY (vault_id, commit_seq)
);

CREATE TABLE pilot_op_receipts (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    op_id TEXT NOT NULL,
    device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    device_seq BIGINT NOT NULL,
    request_digest TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    commit_seq BIGINT NOT NULL,
    PRIMARY KEY (vault_id, op_id),
    UNIQUE (vault_id, device_id, device_seq)
);

CREATE TABLE pilot_blob_objects (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    object_id TEXT NOT NULL,
    storage_state TEXT NOT NULL,
    gc_after TIMESTAMPTZ,
    PRIMARY KEY (vault_id, object_id)
);

CREATE TABLE pilot_object_references (
    vault_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    PRIMARY KEY (vault_id, revision_id, object_id),
    FOREIGN KEY (vault_id, object_id)
        REFERENCES pilot_blob_objects(vault_id, object_id)
        ON DELETE CASCADE
);

CREATE TABLE pilot_audit_events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    actor_user_id TEXT NOT NULL REFERENCES pilot_accounts(user_id),
    actor_device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    action TEXT NOT NULL
);

CREATE TABLE pilot_mobile_push_outbox (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    source_device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    event_type TEXT NOT NULL
);

CREATE TABLE pilot_batch_receipts (
    vault_id TEXT NOT NULL REFERENCES pilot_vaults(vault_id),
    device_id TEXT NOT NULL REFERENCES pilot_devices(device_id),
    batch_id TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY (vault_id, device_id, batch_id)
);

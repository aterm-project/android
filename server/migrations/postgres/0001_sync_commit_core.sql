-- PostgreSQL commit-only sync core, schema version 1.
--
-- This is a bounded engine migration for PgSyncCommitRepository, not the
-- PostgreSQL equivalent of the complete SQLite migration set. It contains
-- only the shared principal/Vault rows and the write-side sync ledger needed
-- by PushCommit. Account registration, refresh rotation, Vault lifecycle,
-- object upload/processing, notification delivery, admin, backup, and every
-- read/history/conflict route remain outside this migration and adapter.
-- Apply this file with a dedicated schema selected in search_path. It is not
-- part of the default `./migrations` SQLite migration directory.

CREATE TABLE users (
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE devices (
    device_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name TEXT NOT NULL DEFAULT 'device',
    signing_public_key TEXT NOT NULL DEFAULT '',
    encryption_public_key TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMPTZ,
    UNIQUE (device_id, user_id)
);
CREATE INDEX idx_devices_user ON devices(user_id, status);

CREATE TABLE sessions (
    session_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    family_id TEXT NOT NULL DEFAULT '',
    access_hash TEXT NOT NULL,
    refresh_hash TEXT NOT NULL,
    access_expires_at TIMESTAMPTZ NOT NULL,
    refresh_expires_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (device_id, user_id) REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    UNIQUE (refresh_hash)
);
CREATE INDEX idx_sessions_access ON sessions(access_hash, revoked_at);

CREATE TABLE vaults (
    vault_id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id),
    state TEXT NOT NULL DEFAULT 'active',
    active_epoch BIGINT NOT NULL DEFAULT 1,
    membership_version BIGINT NOT NULL DEFAULT 1,
    required_record_schema SMALLINT NOT NULL DEFAULT 1 CHECK (required_record_schema BETWEEN 1 AND 2),
    name_envelope JSONB,
    quota_bytes BIGINT NOT NULL DEFAULT 1073741824,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE vault_members (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'active',
    added_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (vault_id, user_id)
);
CREATE INDEX idx_members_user ON vault_members(user_id, state);

CREATE TABLE device_capability_reports (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL CHECK (revision > 0),
    max_record_schema SMALLINT NOT NULL CHECK (max_record_schema BETWEEN 1 AND 2),
    host_attachment_manifest_versions JSONB NOT NULL
        CHECK (jsonb_typeof(host_attachment_manifest_versions) = 'array'),
    max_attachment_bytes BIGINT NOT NULL CHECK (max_attachment_bytes BETWEEN 0 AND 1073741824),
    signature TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE vault_counters (
    vault_id TEXT PRIMARY KEY REFERENCES vaults(vault_id) ON DELETE CASCADE,
    last_committed_seq BIGINT NOT NULL DEFAULT 0 CHECK (last_committed_seq >= 0)
);

CREATE TABLE record_versions (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    base_revision_id TEXT,
    envelope TEXT NOT NULL,
    digest TEXT NOT NULL,
    commit_seq BIGINT NOT NULL,
    -- Historical signer IDs deliberately outlive device/account rows.
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('create', 'update', 'delete', 'restore')),
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (vault_id, record_id, revision_id),
    UNIQUE (vault_id, commit_seq)
);
CREATE INDEX idx_versions_seq ON record_versions(vault_id, commit_seq);
-- Revision reads and Vault-wide revision-ID collision checks use this
-- independent key because legacy storage permits the same ID on two records.
CREATE INDEX idx_versions_revision_lookup ON record_versions(vault_id, revision_id);

CREATE TABLE record_heads (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    deleted BOOLEAN NOT NULL DEFAULT FALSE,
    commit_seq BIGINT NOT NULL,
    PRIMARY KEY (vault_id, record_id)
);

CREATE TABLE record_graveyard (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    deleted_revision TEXT NOT NULL,
    deleted_seq BIGINT NOT NULL,
    PRIMARY KEY (vault_id, record_id)
);

CREATE TABLE change_events (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    commit_seq BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    envelope TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (vault_id, commit_seq)
);

CREATE TABLE op_receipts (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    op_id TEXT NOT NULL,
    -- Idempotency records are historical data and are not device-owned rows.
    device_id TEXT NOT NULL,
    -- Device sequence is a canonical unsigned decimal string in the signed
    -- protocol and may use the full u64 range, so it is not a BIGINT.
    device_seq TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    commit_seq BIGINT NOT NULL,
    PRIMARY KEY (vault_id, op_id),
    UNIQUE (vault_id, device_id, device_seq)
);

CREATE TABLE batch_receipts (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    -- Device/account purge must not block or erase the immutable batch ledger.
    device_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY (vault_id, device_id, batch_id)
);

-- The sync commit adapter uses this catalogue only to lock complete objects,
-- attach references, and clear GC eligibility atomically. Object creation,
-- bytes/backends, deletion workers, and durable external-delete queues are
-- intentionally not part of this bounded migration.
CREATE TABLE blob_objects (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    object_id TEXT NOT NULL,
    size BIGINT NOT NULL DEFAULT 0,
    sha256 TEXT NOT NULL DEFAULT '',
    storage_backend TEXT NOT NULL DEFAULT 'sqlite'
        CHECK (storage_backend IN ('sqlite', 's3', 'filesystem')),
    storage_key TEXT,
    storage_store_id TEXT,
    storage_state TEXT NOT NULL DEFAULT 'available'
        CHECK (storage_state IN ('available', 'deleting')),
    gc_after BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (vault_id, object_id)
);
CREATE INDEX idx_blob_objects_gc_after ON blob_objects(gc_after) WHERE gc_after IS NOT NULL;

CREATE TABLE object_references (
    vault_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    PRIMARY KEY (vault_id, revision_id, object_id),
    FOREIGN KEY (vault_id, object_id) REFERENCES blob_objects(vault_id, object_id) ON DELETE CASCADE
);

CREATE TABLE audit_events (
    event_id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    scope_type TEXT NOT NULL CHECK (scope_type IN ('account', 'vault')),
    scope_id TEXT NOT NULL,
    actor_user_id TEXT,
    actor_device_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    result TEXT NOT NULL CHECK (result = 'success'),
    occurred_at BIGINT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('api', 'maintenance'))
);
CREATE INDEX idx_audit_events_scope_event ON audit_events(scope_type, scope_id, event_id);

-- These rows are enqueued transactionally only. Endpoint registration and
-- provider delivery workers are separate, unsupported operations here.
CREATE TABLE notification_push_endpoints (
    endpoint_id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    provider TEXT NOT NULL CHECK (provider IN ('fcm_v1', 'apns')),
    token_hash TEXT NOT NULL UNIQUE CHECK (length(token_hash) = 64),
    token_envelope TEXT NOT NULL,
    created_at BIGINT NOT NULL,
    updated_at BIGINT NOT NULL,
    UNIQUE (device_id, provider),
    FOREIGN KEY (device_id, user_id) REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE
);
CREATE TABLE notification_push_outbox (
    endpoint_id TEXT PRIMARY KEY REFERENCES notification_push_endpoints(endpoint_id) ON DELETE CASCADE,
    requested_seq BIGINT NOT NULL CHECK (requested_seq > 0),
    delivered_seq BIGINT NOT NULL DEFAULT 0 CHECK (delivered_seq >= 0),
    attempt_count BIGINT NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    next_attempt_at BIGINT NOT NULL,
    lease_id TEXT,
    lease_until BIGINT,
    dead_lettered BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at BIGINT NOT NULL,
    CHECK (delivered_seq <= requested_seq),
    CHECK ((lease_id IS NULL AND lease_until IS NULL) OR (lease_id IS NOT NULL AND lease_until IS NOT NULL))
);

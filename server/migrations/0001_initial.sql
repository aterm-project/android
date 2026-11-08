PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS instance_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    instance_id TEXT NOT NULL,
    server_space_id TEXT NOT NULL,
    generation TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    bootstrap_token_hash TEXT,
    setup_consumed_at TEXT
);
CREATE TABLE IF NOT EXISTS users (
    user_id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS auth_credentials (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    login_verifier_hash TEXT NOT NULL,
    verifier_salt TEXT NOT NULL,
    kdf_json TEXT NOT NULL,
    account_key_envelope TEXT NOT NULL,
    credential_version INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS devices (
    device_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    encryption_public_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL,
    revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_devices_user ON devices(user_id, status);
CREATE TABLE IF NOT EXISTS sessions (
    session_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    family_id TEXT NOT NULL,
    access_hash TEXT NOT NULL,
    refresh_hash TEXT NOT NULL,
    access_expires_at TEXT NOT NULL,
    refresh_expires_at TEXT NOT NULL,
    revoked_at TEXT,
    created_at TEXT NOT NULL,
    UNIQUE(refresh_hash)
);
CREATE INDEX IF NOT EXISTS idx_sessions_access ON sessions(access_hash, revoked_at);
CREATE TABLE IF NOT EXISTS refresh_history (
    refresh_hash TEXT PRIMARY KEY,
    family_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    consumed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_refresh_family ON refresh_history(family_id);
CREATE TABLE IF NOT EXISTS vaults (
    vault_id TEXT PRIMARY KEY,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id),
    state TEXT NOT NULL DEFAULT 'active',
    active_epoch INTEGER NOT NULL DEFAULT 1,
    membership_version INTEGER NOT NULL DEFAULT 1,
    name_envelope TEXT,
    quota_bytes INTEGER NOT NULL DEFAULT 1073741824,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS vault_members (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    state TEXT NOT NULL DEFAULT 'active',
    added_at TEXT NOT NULL,
    PRIMARY KEY(vault_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_members_user ON vault_members(user_id, state);
CREATE TABLE IF NOT EXISTS vault_key_envelopes (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    epoch INTEGER NOT NULL,
    recipient_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    envelope TEXT NOT NULL,
    envelope_signature TEXT NOT NULL,
    signer_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    membership_version INTEGER NOT NULL,
    PRIMARY KEY(vault_id, epoch, recipient_device_id)
);
CREATE TABLE IF NOT EXISTS vault_counters (
    vault_id TEXT PRIMARY KEY REFERENCES vaults(vault_id) ON DELETE CASCADE,
    last_committed_seq INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS record_heads (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    commit_seq INTEGER NOT NULL,
    PRIMARY KEY(vault_id, record_id)
);
CREATE TABLE IF NOT EXISTS record_versions (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    base_revision_id TEXT,
    envelope TEXT NOT NULL,
    digest TEXT NOT NULL,
    commit_seq INTEGER NOT NULL,
    device_id TEXT NOT NULL,
    operation TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(vault_id, record_id, revision_id),
    UNIQUE(vault_id, commit_seq)
);
CREATE INDEX IF NOT EXISTS idx_versions_seq ON record_versions(vault_id, commit_seq);
CREATE TABLE IF NOT EXISTS change_events (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    commit_seq INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    envelope TEXT NOT NULL,
    PRIMARY KEY(vault_id, commit_seq)
);
CREATE TABLE IF NOT EXISTS op_receipts (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    op_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    device_seq TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    record_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    commit_seq INTEGER NOT NULL,
    PRIMARY KEY(vault_id, op_id),
    UNIQUE(vault_id, device_id, device_seq)
);
CREATE TABLE IF NOT EXISTS batch_receipts (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    batch_id TEXT NOT NULL,
    request_digest TEXT NOT NULL,
    response_json TEXT NOT NULL,
    PRIMARY KEY(vault_id, device_id, batch_id)
);
CREATE TABLE IF NOT EXISTS record_graveyard (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    deleted_revision TEXT NOT NULL,
    deleted_seq INTEGER NOT NULL,
    PRIMARY KEY(vault_id, record_id)
);
CREATE TABLE IF NOT EXISTS snapshots (
    snapshot_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    requested_by TEXT NOT NULL REFERENCES users(user_id),
    high_watermark INTEGER NOT NULL,
    manifest_json TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS conflicts (
    conflict_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    record_id TEXT NOT NULL,
    base_revision_id TEXT,
    envelope TEXT NOT NULL,
    digest TEXT NOT NULL,
    device_id TEXT NOT NULL,
    created_at TEXT NOT NULL,
    resolved_revision_id TEXT
);
CREATE TABLE IF NOT EXISTS uploads (
    upload_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id),
    object_id TEXT NOT NULL,
    expected_size INTEGER NOT NULL,
    expected_sha256 TEXT NOT NULL,
    chunk_size INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'open',
    expires_at TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS upload_chunks (
    upload_id TEXT NOT NULL REFERENCES uploads(upload_id) ON DELETE CASCADE,
    chunk_index INTEGER NOT NULL,
    bytes BLOB NOT NULL,
    sha256 TEXT NOT NULL,
    PRIMARY KEY(upload_id, chunk_index)
);
CREATE TABLE IF NOT EXISTS blob_objects (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    object_id TEXT NOT NULL,
    bytes BLOB NOT NULL,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(vault_id, object_id)
);
CREATE TABLE IF NOT EXISTS object_references (
    vault_id TEXT NOT NULL,
    revision_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    PRIMARY KEY(vault_id, revision_id, object_id),
    FOREIGN KEY(vault_id, object_id) REFERENCES blob_objects(vault_id, object_id) ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS invitations (
    invitation_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL,
    key_envelope TEXT NOT NULL,
    recipient_user_id TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    recipient_device_id TEXT REFERENCES devices(device_id) ON DELETE CASCADE,
    signer_device_id TEXT REFERENCES devices(device_id) ON DELETE CASCADE,
    created_by TEXT NOT NULL REFERENCES users(user_id),
    expires_at TEXT NOT NULL,
    accepted_by TEXT REFERENCES users(user_id),
    accepted_at TEXT
);
CREATE TABLE IF NOT EXISTS membership_manifests (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    membership_version INTEGER NOT NULL,
    previous_digest TEXT,
    manifest_json TEXT NOT NULL,
    digest TEXT NOT NULL,
    signer_device_id TEXT NOT NULL,
    signature TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(vault_id, membership_version)
);
CREATE TABLE IF NOT EXISTS relay_tickets (
    ticket_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    target_ip TEXT NOT NULL,
    target_port INTEGER NOT NULL,
    expires_at TEXT NOT NULL,
    consumed_at TEXT
);

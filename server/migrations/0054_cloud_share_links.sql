-- Cloud collaboration: trusted-gateway capsules, temporary links, guest
-- sessions, one-use gateway tickets and active connection accounting.
-- Every secret is stored only as a SHA-256 hash. Capsules are sealed to the
-- gateway X25519 key whose private half is outside the data directory.

CREATE TABLE IF NOT EXISTS share_gateway_keys (
    key_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL UNIQUE,
    signed_payload TEXT NOT NULL,
    signature TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'retired')),
    created_at TEXT NOT NULL,
    retired_at TEXT
);

CREATE TABLE IF NOT EXISTS share_host_capsules (
    capsule_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    host_revision_id TEXT NOT NULL,
    gateway_key_id TEXT NOT NULL REFERENCES share_gateway_keys(key_id),
    protocol TEXT NOT NULL CHECK (protocol IN ('ssh', 'rdp', 'vnc')),
    target_host TEXT NOT NULL,
    target_port INTEGER NOT NULL CHECK (target_port BETWEEN 1 AND 65535),
    header_json TEXT NOT NULL,
    sealed TEXT NOT NULL,
    sealed_sha256 TEXT NOT NULL,
    sealer_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    sealer_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    state TEXT NOT NULL CHECK (state IN ('active', 'revoked')),
    revision INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (vault_id, host_record_id),
    FOREIGN KEY (vault_id, host_record_id) REFERENCES record_heads(vault_id, record_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS share_links (
    link_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    slug TEXT NOT NULL UNIQUE,
    slug_custom INTEGER NOT NULL CHECK (slug_custom IN (0, 1)),
    redeem_token_hash TEXT NOT NULL,
    secret_version INTEGER NOT NULL DEFAULT 1,
    display_envelope TEXT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active', 'paused', 'revoked', 'suspended')),
    suspend_reason TEXT,
    valid_from_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,
    max_redemptions INTEGER,
    redemptions INTEGER NOT NULL DEFAULT 0,
    max_connections INTEGER,
    connections INTEGER NOT NULL DEFAULT 0,
    max_concurrent INTEGER NOT NULL DEFAULT 1,
    session_lifetime_seconds INTEGER NOT NULL DEFAULT 7200,
    clipboard_to_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_to_remote IN (0, 1)),
    clipboard_from_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_from_remote IN (0, 1)),
    view_only INTEGER NOT NULL DEFAULT 0 CHECK (view_only IN (0, 1)),
    authz_revision INTEGER NOT NULL DEFAULT 1,
    revision INTEGER NOT NULL DEFAULT 1,
    request_digest TEXT NOT NULL,
    created_epoch INTEGER NOT NULL,
    updated_epoch INTEGER NOT NULL,
    revoked_epoch INTEGER,
    UNIQUE (link_id, vault_id),
    CHECK (expires_epoch > valid_from_epoch)
);
CREATE INDEX IF NOT EXISTS idx_share_links_vault ON share_links(vault_id, state);
CREATE INDEX IF NOT EXISTS idx_share_links_owner ON share_links(owner_user_id, state);

-- Composite keys bind every target to the link's own Vault and to the
-- capsule of a Host in that same Vault.
CREATE TABLE IF NOT EXISTS share_link_targets (
    link_id TEXT NOT NULL,
    vault_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    position INTEGER NOT NULL,
    PRIMARY KEY (link_id, target_id),
    UNIQUE (link_id, host_record_id),
    FOREIGN KEY (link_id, vault_id) REFERENCES share_links(link_id, vault_id) ON DELETE CASCADE,
    FOREIGN KEY (vault_id, host_record_id) REFERENCES share_host_capsules(vault_id, host_record_id) ON DELETE CASCADE
);

-- Released custom/random slugs cannot be reused immediately.
CREATE TABLE IF NOT EXISTS share_slug_reservations (
    slug TEXT PRIMARY KEY,
    released_epoch INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS share_guest_sessions (
    guest_session_id TEXT PRIMARY KEY,
    link_id TEXT NOT NULL REFERENCES share_links(link_id) ON DELETE CASCADE,
    cookie_hash TEXT NOT NULL UNIQUE,
    secret_version INTEGER NOT NULL,
    created_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,
    last_seen_epoch INTEGER NOT NULL,
    revoked_epoch INTEGER,
    end_reason TEXT,
    ip_prefix TEXT,
    ua_family TEXT
);
CREATE INDEX IF NOT EXISTS idx_share_guest_sessions_link ON share_guest_sessions(link_id, revoked_epoch);

CREATE TABLE IF NOT EXISTS share_gateway_tickets (
    ticket_hash TEXT PRIMARY KEY,
    guest_session_id TEXT NOT NULL REFERENCES share_guest_sessions(guest_session_id) ON DELETE CASCADE,
    link_id TEXT NOT NULL,
    target_id TEXT NOT NULL,
    authz_revision INTEGER NOT NULL,
    secret_version INTEGER NOT NULL,
    created_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,
    consumed_epoch INTEGER,
    FOREIGN KEY (link_id, target_id) REFERENCES share_link_targets(link_id, target_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_share_gateway_tickets_session ON share_gateway_tickets(guest_session_id, created_epoch);

CREATE TABLE IF NOT EXISTS share_gateway_connections (
    connection_id TEXT PRIMARY KEY,
    link_id TEXT NOT NULL REFERENCES share_links(link_id) ON DELETE CASCADE,
    guest_session_id TEXT NOT NULL REFERENCES share_guest_sessions(guest_session_id) ON DELETE CASCADE,
    target_id TEXT NOT NULL,
    protocol TEXT NOT NULL,
    target_ip TEXT,
    target_port INTEGER,
    started_epoch INTEGER NOT NULL,
    heartbeat_epoch INTEGER NOT NULL,
    ended_epoch INTEGER,
    end_reason TEXT,
    bytes_to_guest INTEGER NOT NULL DEFAULT 0,
    bytes_from_guest INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_share_gateway_connections_link ON share_gateway_connections(link_id, ended_epoch);
CREATE INDEX IF NOT EXISTS idx_share_gateway_connections_session ON share_gateway_connections(guest_session_id, ended_epoch);

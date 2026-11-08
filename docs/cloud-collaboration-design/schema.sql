-- =====================================================================
-- Atermius cloud collaboration & temporary access — SCHEMA PROPOSAL ONLY
-- =====================================================================
-- DO NOT EXECUTE. This file is a design artifact for review; it is not a
-- migration and is not referenced by server/migrations. Dialect: SQLite
-- (default runtime). PostgreSQL notes are inline as `-- PG:` comments.
--
-- Proposed split into SQLite migrations (numbers follow 0052):
--   0053_organizations.sql        organizations, members, invitations, teams
--   0054_vault_principal_grants.sql vaults/vault_members columns, grants
--   0055_share_gateway.sql        gateway keys, host capsules, host access grants
--   0056_share_links.sql          links, targets, slug reservations
--   0057_guest_sessions.sql       guest sessions, tickets, connections
--   0058_share_policy.sql         instance share policy singleton
-- Numbering reflects table dependencies only; when shipping by phase, P1 tables
-- (gateway keys, capsules, links, guest tables, policy) may be renumbered ahead of
-- P2 org tables (0053-0054); host_access_grants references teams and ships with P2.
-- PostgreSQL equivalents start at 0040 and must ship with their own
-- Pg*Repository and exact-route allowlist entries (server/src/lib.rs:1571).
--
-- Conventions (same as existing migrations):
--   * IDs are canonical lowercase UUIDv4 TEXT.
--   * Timestamps are UTC RFC 3339 TEXT, except *_epoch INTEGER columns used
--     for range scans (mirrors relay_tickets.created_at).
--   * Every secret-bearing value is stored ONLY as lowercase hex SHA-256.
--   * Revisions are monotonically increasing INTEGER CAS counters.
--   * Saved window combinations (client WindowCombination v1 in the encrypted
--     Preference key 'windowCombinations', plus the proposed additive key
--     'windowCombinationPlacements') need NO server table: they are ordinary
--     client-encrypted Vault records.
--   * Phasing: P1 uses only share_gateway_keys, host_gateway_capsules,
--     share_links(+targets, slugs), guest_*, gateway_*, instance_share_policy,
--     with link/capsule writes restricted to Vault owners. Organizations,
--     teams and vault_principal_grants are P2. host_access_grants is P2.
--     vault_members.role='admin' is P3 (requires membership_roles_v2).
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- 0053 organizations / teams  (server-visible control-plane metadata)
-- ---------------------------------------------------------------------
CREATE TABLE organizations (
    org_id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
    name_key TEXT NOT NULL UNIQUE,            -- NFKC + lowercase, like relay_access_groups
    state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'deleting')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    membership_revision INTEGER NOT NULL DEFAULT 1 CHECK (membership_revision >= 1),
    -- Policy bits; JSON kept small and validated by the server.
    editors_may_share INTEGER NOT NULL DEFAULT 0 CHECK (editors_may_share IN (0, 1)),
    remove_from_org_vaults_on_leave INTEGER NOT NULL DEFAULT 1
        CHECK (remove_from_org_vaults_on_leave IN (0, 1)),
    created_by TEXT NOT NULL REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE organization_members (
    org_id TEXT NOT NULL REFERENCES organizations(org_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'removed')),
    joined_at TEXT NOT NULL,
    removed_at TEXT,
    PRIMARY KEY (org_id, user_id)
);
CREATE INDEX idx_org_members_user ON organization_members(user_id, state);
-- At least one active owner is enforced transactionally by the server
-- (cannot be expressed as a portable CHECK).

CREATE TABLE organization_invitations (
    invitation_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(org_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,          -- SHA-256 of the 32-byte token
    intended_username TEXT,                   -- optional binding; NULL = any account
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    initial_team_ids TEXT NOT NULL DEFAULT '[]', -- JSON array, validated vs teams(org_id)
    account_invitation_id TEXT REFERENCES account_invitations(invitation_id) ON DELETE SET NULL,
    created_by TEXT NOT NULL REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,                 -- <= created_at + 14 days
    consumed_at TEXT,
    consumed_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    revoked_at TEXT,
    CHECK (NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL))
);
CREATE INDEX idx_org_invitations_pending
    ON organization_invitations(org_id, expires_at)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;

CREATE TABLE teams (
    team_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES organizations(org_id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 128),
    name_key TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    membership_revision INTEGER NOT NULL DEFAULT 0 CHECK (membership_revision >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    UNIQUE (org_id, team_id),                 -- target of composite FKs
    UNIQUE (org_id, name_key)
);

CREATE TABLE team_members (
    org_id TEXT NOT NULL,
    team_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (team_id, user_id),
    FOREIGN KEY (org_id, team_id) REFERENCES teams(org_id, team_id) ON DELETE CASCADE,
    -- A team member must be a member row of the SAME org (cross-org substitution guard).
    FOREIGN KEY (org_id, user_id) REFERENCES organization_members(org_id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_team_members_user ON team_members(user_id, org_id);
-- Server additionally requires organization_members.state='active' on insert
-- and deletes team_members rows in the same transaction that sets state='removed'.

-- ---------------------------------------------------------------------
-- 0054 Vault ↔ organization, desired-state grants
-- ---------------------------------------------------------------------
ALTER TABLE vaults ADD COLUMN org_id TEXT REFERENCES organizations(org_id);
ALTER TABLE vaults ADD COLUMN grants_revision INTEGER NOT NULL DEFAULT 0;
ALTER TABLE vaults ADD COLUMN rotation_required_at TEXT;   -- set when a key holder was suspended
ALTER TABLE vaults ADD COLUMN rotation_reason TEXT;        -- fixed enum: member_suspended|member_removed|manual
CREATE INDEX idx_vaults_org ON vaults(org_id) WHERE org_id IS NOT NULL;

-- vault_members.role gains 'admin'; vault_members.state gains 'suspended'.
-- SQLite 0001 declares both as unconstrained TEXT, so only application
-- validation changes. PG: vault_members has no CHECK either, but
-- postgres/0011_vault_invitations.sql has CHECK (role IN ('editor','viewer'))
-- on invitations; replace it only when admin invitations are enabled.
ALTER TABLE vault_members ADD COLUMN source TEXT NOT NULL DEFAULT 'direct';
    -- 'direct' (existing invitation) | 'grant' (materialized from vault_principal_grants) | 'both'
ALTER TABLE vault_members ADD COLUMN suspended_at TEXT;
ALTER TABLE vault_members ADD COLUMN suspend_reason TEXT;

CREATE TABLE vault_principal_grants (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    principal_type TEXT NOT NULL CHECK (principal_type IN ('user', 'team')),
    principal_id TEXT NOT NULL,               -- user_id or team_id
    org_id TEXT,                              -- required for team grants
    role TEXT NOT NULL CHECK (role IN ('admin', 'editor', 'viewer')),
    revision INTEGER NOT NULL DEFAULT 1 CHECK (revision >= 1),
    granted_by TEXT NOT NULL REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (vault_id, principal_type, principal_id),
    CHECK ((principal_type = 'team') = (org_id IS NOT NULL)),
    FOREIGN KEY (org_id, principal_id) REFERENCES teams(org_id, team_id) ON DELETE CASCADE
    -- SQLite: a composite FK with a NULL column is not enforced, so user grants
    -- pass; team grants are enforced. Server also checks vaults.org_id = org_id
    -- (team must belong to the Vault's organization) inside the write tx.
    -- PG: same FK with MATCH SIMPLE semantics.
);
CREATE INDEX idx_vault_grants_principal ON vault_principal_grants(principal_type, principal_id);

-- No key-distribution queue table: pending additions/removals are DERIVED by
--   expand(grants) ∪ direct members   vs   latest membership manifest members
--   and active devices lacking vault_key_envelopes for the active epoch.

-- ---------------------------------------------------------------------
-- 0055 Share gateway keys, Host capsules, Host access (gateway_connect) grants
-- ---------------------------------------------------------------------
CREATE TABLE share_gateway_keys (
    key_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL UNIQUE,          -- base64url X25519 (32 bytes)
    instance_signature TEXT NOT NULL,         -- Ed25519 by instance key over JCS({key_id,public_key,created_at})
    state TEXT NOT NULL CHECK (state IN ('active', 'retiring', 'retired')),
    created_at TEXT NOT NULL,
    retire_after TEXT,
    retired_at TEXT,
    retired_reason TEXT                       -- rotation|compromise|restore
);
CREATE UNIQUE INDEX idx_share_gateway_single_active
    ON share_gateway_keys(state) WHERE state = 'active';
-- Private key lives ONLY in ATERMIUS_SHARE_GATEWAY_KEY_FILE (never in DB/backups).

CREATE TABLE host_gateway_capsules (
    capsule_id TEXT PRIMARY KEY,              -- client-generated UUID (idempotency key)
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    host_revision_id TEXT NOT NULL,
    gateway_key_id TEXT NOT NULL REFERENCES share_gateway_keys(key_id),
    protocol TEXT NOT NULL CHECK (protocol IN ('ssh', 'rdp', 'vnc')),
    target_host TEXT NOT NULL,                -- normalized DNS name or IP literal (server-visible)
    target_port INTEGER NOT NULL CHECK (target_port BETWEEN 1 AND 65535),
    header_json TEXT NOT NULL,                -- signed outer header (JCS)
    header_signature TEXT NOT NULL,
    sealed_capsule BLOB NOT NULL CHECK (length(sealed_capsule) <= 307200),
    sealed_sha256 TEXT NOT NULL,
    sealer_user_id TEXT NOT NULL REFERENCES users(user_id),
    sealer_device_id TEXT NOT NULL REFERENCES devices(device_id),
    membership_version INTEGER NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    state TEXT NOT NULL CHECK (state IN ('active', 'stale', 'revoked')),
    stale_reason TEXT,                        -- host_revision_changed|gateway_key_retired|sealer_lost_access
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    FOREIGN KEY (vault_id, host_record_id)
        REFERENCES record_heads(vault_id, record_id) ON DELETE CASCADE,
    UNIQUE (vault_id, host_record_id, capsule_id)
);
-- At most one non-revoked capsule per Host.
CREATE UNIQUE INDEX idx_host_capsule_current
    ON host_gateway_capsules(vault_id, host_record_id) WHERE state <> 'revoked';
-- Revoked rows keep only metadata: the server sets sealed_capsule = x'' on revoke
-- (hard delete of ciphertext), retaining sealed_sha256 for audit correlation.

CREATE TABLE host_access_grants (
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    principal_type TEXT NOT NULL CHECK (principal_type IN ('user', 'team')),
    principal_id TEXT NOT NULL,
    org_id TEXT,
    capability TEXT NOT NULL DEFAULT 'gateway_connect' CHECK (capability = 'gateway_connect'),
    label TEXT NOT NULL CHECK (length(label) BETWEEN 1 AND 128), -- P1 plaintext display name (UI: server-visible)
    clipboard_to_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_to_remote IN (0, 1)),
    clipboard_from_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_from_remote IN (0, 1)),
    view_only INTEGER NOT NULL DEFAULT 0 CHECK (view_only IN (0, 1)),
    file_transfer INTEGER NOT NULL DEFAULT 0 CHECK (file_transfer = 0),  -- P1 locked off
    recording INTEGER NOT NULL DEFAULT 0 CHECK (recording = 0),          -- P1 locked off
    expires_at TEXT,                          -- optional; NULL = until revoked
    revision INTEGER NOT NULL DEFAULT 1,
    authz_revision INTEGER NOT NULL DEFAULT 1,
    granted_by TEXT NOT NULL REFERENCES users(user_id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (vault_id, host_record_id, principal_type, principal_id),
    FOREIGN KEY (vault_id, host_record_id)
        REFERENCES record_heads(vault_id, record_id) ON DELETE CASCADE,
    FOREIGN KEY (org_id, principal_id) REFERENCES teams(org_id, team_id) ON DELETE CASCADE,
    CHECK ((principal_type = 'team') = (org_id IS NOT NULL))
);
CREATE INDEX idx_host_access_grants_principal
    ON host_access_grants(principal_type, principal_id);

-- ---------------------------------------------------------------------
-- 0056 Share links
-- ---------------------------------------------------------------------
CREATE TABLE share_links (
    link_id TEXT PRIMARY KEY,                 -- client-generated UUID (idempotency key)
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    owner_user_id TEXT NOT NULL REFERENCES users(user_id),   -- creator, or adopter after adopt
    created_by_device_id TEXT NOT NULL REFERENCES devices(device_id),
    slug TEXT NOT NULL UNIQUE CHECK (length(slug) BETWEEN 3 AND 48),
    slug_kind TEXT NOT NULL CHECK (slug_kind IN ('random', 'custom')),
    redeem_token_hash TEXT NOT NULL UNIQUE,
    secret_version INTEGER NOT NULL DEFAULT 1 CHECK (secret_version >= 1),
    display_envelope TEXT NOT NULL CHECK (length(display_envelope) <= 12288), -- XChaCha, fragment-derived key
    state TEXT NOT NULL DEFAULT 'active'
        CHECK (state IN ('active', 'paused', 'revoked', 'suspended')),
    suspend_reason TEXT,   -- creator_lost_access|host_deleted|capsule_stale|vault_deleting|gateway_key_retired|policy
    valid_from TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    valid_from_epoch INTEGER NOT NULL,
    expires_at_epoch INTEGER NOT NULL CHECK (expires_at_epoch > valid_from_epoch),
    schedule_json TEXT,                       -- NULL = continuous; else {timezone, windows[]}
    schedule_tzdata_version TEXT,
    max_redemptions INTEGER CHECK (max_redemptions IS NULL OR max_redemptions BETWEEN 1 AND 1000),
    redemptions INTEGER NOT NULL DEFAULT 0 CHECK (redemptions >= 0),
    max_connections INTEGER CHECK (max_connections IS NULL OR max_connections BETWEEN 1 AND 10000),
    connections INTEGER NOT NULL DEFAULT 0 CHECK (connections >= 0),
    max_concurrent INTEGER NOT NULL DEFAULT 1 CHECK (max_concurrent BETWEEN 1 AND 10),
    guest_session_seconds INTEGER NOT NULL DEFAULT 7200 CHECK (guest_session_seconds BETWEEN 300 AND 43200),
    idle_timeout_seconds INTEGER NOT NULL DEFAULT 900 CHECK (idle_timeout_seconds BETWEEN 60 AND 3600),
    clipboard_to_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_to_remote IN (0, 1)),
    clipboard_from_remote INTEGER NOT NULL DEFAULT 0 CHECK (clipboard_from_remote IN (0, 1)),
    view_only INTEGER NOT NULL DEFAULT 0 CHECK (view_only IN (0, 1)),
    file_transfer INTEGER NOT NULL DEFAULT 0 CHECK (file_transfer = 0),
    recording INTEGER NOT NULL DEFAULT 0 CHECK (recording = 0),
    suspend_on_host_change INTEGER NOT NULL DEFAULT 1 CHECK (suspend_on_host_change IN (0, 1)),
    -- P2 optional anti-scanner / sensitive-share settings (DESIGN §6.4):
    redeem_requires_approval INTEGER NOT NULL DEFAULT 0 CHECK (redeem_requires_approval IN (0, 1)),
    verification_code_hash TEXT,              -- Argon2id PHC string of an out-of-band 6-digit code; NULL = off
    revision INTEGER NOT NULL DEFAULT 1,      -- any PATCH
    authz_revision INTEGER NOT NULL DEFAULT 1,-- only narrowing changes / revoke / rotate
    request_digest TEXT NOT NULL,             -- idempotent create replay check
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    revoked_at TEXT,
    revoked_by TEXT REFERENCES users(user_id)
);
CREATE INDEX idx_share_links_vault ON share_links(vault_id, state, expires_at_epoch);
CREATE INDEX idx_share_links_owner ON share_links(owner_user_id, state);
CREATE INDEX idx_share_links_expiry ON share_links(expires_at_epoch) WHERE state <> 'revoked';

CREATE TABLE share_link_targets (
    link_id TEXT NOT NULL REFERENCES share_links(link_id) ON DELETE CASCADE,
    target_id TEXT NOT NULL,                  -- UUID shown to guest; never a host_record_id
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL CHECK (ordinal BETWEEN 0 AND 7),
    state TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'suspended')),
    suspend_reason TEXT,
    PRIMARY KEY (link_id, target_id),
    UNIQUE (link_id, host_record_id),
    UNIQUE (link_id, ordinal),
    FOREIGN KEY (vault_id, host_record_id)
        REFERENCES record_heads(vault_id, record_id) ON DELETE CASCADE
    -- Server checks share_link_targets.vault_id = share_links.vault_id in the
    -- create tx (SQLite cannot express a cross-table equality CHECK).
    -- PG: add composite FK (link_id, vault_id) -> share_links(link_id, vault_id)
    --     with UNIQUE (link_id, vault_id) on share_links.
);
CREATE INDEX idx_share_link_targets_host ON share_link_targets(vault_id, host_record_id);

CREATE TABLE share_slug_reservations (
    slug TEXT PRIMARY KEY,
    reserved_until_epoch INTEGER NOT NULL     -- cooldown after link hard-delete (default 7 days)
);

-- ---------------------------------------------------------------------
-- 0057 Guest sessions, connection tickets, connections
-- ---------------------------------------------------------------------
CREATE TABLE guest_sessions (
    guest_session_id TEXT PRIMARY KEY,
    link_id TEXT NOT NULL REFERENCES share_links(link_id) ON DELETE CASCADE,
    cookie_hash TEXT NOT NULL UNIQUE,
    secret_version INTEGER NOT NULL,
    authz_revision INTEGER NOT NULL,          -- snapshot at redemption
    created_at TEXT NOT NULL,
    expires_at_epoch INTEGER NOT NULL,
    idle_expires_at_epoch INTEGER NOT NULL,
    last_seen_epoch INTEGER NOT NULL,
    approval_state TEXT NOT NULL DEFAULT 'not_required'
        CHECK (approval_state IN ('not_required', 'pending', 'approved', 'denied')),  -- P2
    verification_failures INTEGER NOT NULL DEFAULT 0 CHECK (verification_failures BETWEEN 0 AND 5), -- P2
    revoked_at TEXT,
    revoke_reason TEXT,                       -- link_revoked|secret_rotated|terminated|replaced|logout|narrowed
    client_ip_token TEXT,                     -- truncated/HMACed per instance audit IP policy
    user_agent_family TEXT                    -- coarse family only
);
CREATE INDEX idx_guest_sessions_link ON guest_sessions(link_id, revoked_at);
CREATE INDEX idx_guest_sessions_expiry ON guest_sessions(expires_at_epoch);

-- Shared by guest and bearer (gateway_connect / member) tickets.
CREATE TABLE gateway_connection_tickets (
    ticket_hash TEXT PRIMARY KEY,
    principal_kind TEXT NOT NULL CHECK (principal_kind IN ('guest', 'user')),
    guest_session_id TEXT REFERENCES guest_sessions(guest_session_id) ON DELETE CASCADE,
    link_id TEXT REFERENCES share_links(link_id) ON DELETE CASCADE,
    target_id TEXT,
    user_id TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    device_id TEXT REFERENCES devices(device_id) ON DELETE CASCADE,
    session_id TEXT,                          -- login session for bearer principals
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    capsule_id TEXT NOT NULL REFERENCES host_gateway_capsules(capsule_id) ON DELETE CASCADE,
    pinned_destination TEXT NOT NULL,         -- AEAD-encrypted ip:port, same scheme as relay 'rtd1:'
    authz_revision INTEGER NOT NULL,
    created_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,           -- <= created + 30
    consumed_epoch INTEGER,
    CHECK ((principal_kind = 'guest') = (guest_session_id IS NOT NULL AND link_id IS NOT NULL AND target_id IS NOT NULL)),
    CHECK ((principal_kind = 'user') = (user_id IS NOT NULL AND device_id IS NOT NULL AND session_id IS NOT NULL))
);
CREATE INDEX idx_gateway_tickets_expiry ON gateway_connection_tickets(expires_epoch);

CREATE TABLE gateway_connections (
    connection_id TEXT PRIMARY KEY,
    principal_kind TEXT NOT NULL CHECK (principal_kind IN ('guest', 'user')),
    guest_session_id TEXT REFERENCES guest_sessions(guest_session_id) ON DELETE SET NULL,
    link_id TEXT REFERENCES share_links(link_id) ON DELETE SET NULL,
    user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    vault_id TEXT NOT NULL,
    host_record_id TEXT NOT NULL,
    target_ip TEXT NOT NULL,                  -- same retention policy as relay targets
    target_port INTEGER NOT NULL,
    protocol TEXT NOT NULL,
    node_id TEXT NOT NULL,                    -- process/node owning the socket (PG multi-node)
    started_epoch INTEGER NOT NULL,
    heartbeat_epoch INTEGER NOT NULL,         -- >60 s stale => counted as ended
    ended_epoch INTEGER,
    end_reason TEXT,
    bytes_to_target INTEGER NOT NULL DEFAULT 0,
    bytes_to_client INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_gateway_connections_active_link
    ON gateway_connections(link_id) WHERE ended_epoch IS NULL;
CREATE INDEX idx_gateway_connections_active_user
    ON gateway_connections(user_id) WHERE ended_epoch IS NULL;

-- ---------------------------------------------------------------------
-- 0058 Instance share policy (row created lazily; absent row = defaults)
-- ---------------------------------------------------------------------
CREATE TABLE instance_share_policy (
    policy_id INTEGER PRIMARY KEY CHECK (policy_id = 1),
    links_enabled INTEGER NOT NULL CHECK (links_enabled IN (0, 1)),          -- default 0
    gateway_grants_enabled INTEGER NOT NULL CHECK (gateway_grants_enabled IN (0, 1)),
    org_creation TEXT NOT NULL CHECK (org_creation IN ('any', 'instance_admin')),
    allowed_protocols TEXT NOT NULL,          -- JSON subset of ["ssh","rdp","vnc"]; default ["ssh","rdp"]
    allow_ports TEXT NOT NULL,                -- JSON; intersected with relay policy
    max_link_lifetime_seconds INTEGER NOT NULL CHECK (max_link_lifetime_seconds BETWEEN 3600 AND 7776000),
    max_guest_session_seconds INTEGER NOT NULL CHECK (max_guest_session_seconds BETWEEN 300 AND 43200),
    max_instance_guest_connections INTEGER NOT NULL CHECK (max_instance_guest_connections BETWEEN 0 AND 1024),
    max_display_width INTEGER NOT NULL DEFAULT 1920 CHECK (max_display_width BETWEEN 320 AND 4096),
    max_display_height INTEGER NOT NULL DEFAULT 1200 CHECK (max_display_height BETWEEN 200 AND 4096),
    revision INTEGER NOT NULL CHECK (revision >= 1),
    updated_at TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- Reference queries (illustrative, not part of the migration)
-- ---------------------------------------------------------------------
-- Atomic redemption (one statement; 0 rows => re-read to choose error code):
--   UPDATE share_links
--      SET redemptions = redemptions + 1
--    WHERE slug = :slug AND redeem_token_hash = :hash AND state = 'active'
--      AND valid_from_epoch <= :now AND expires_at_epoch > :now
--      AND (max_redemptions IS NULL OR redemptions < max_redemptions)
--   RETURNING link_id, vault_id, owner_user_id, secret_version, authz_revision, ...;
--   (schedule window + creator-permission checks run in the same tx before commit)
--
-- Periodic connection re-authorization (every <= 2 s per guest connection):
--   SELECT 1
--     FROM share_links l
--     JOIN share_link_targets t ON t.link_id = l.link_id AND t.target_id = :target
--     JOIN vaults v ON v.vault_id = l.vault_id AND v.state = 'active'
--     JOIN vault_members m ON m.vault_id = l.vault_id AND m.user_id = l.owner_user_id
--                         AND m.state = 'active' AND m.role IN ('owner','admin','editor')
--     JOIN users u ON u.user_id = l.owner_user_id AND u.status = 'active'
--     JOIN record_heads h ON h.vault_id = t.vault_id AND h.record_id = t.host_record_id AND h.deleted = 0
--     JOIN host_gateway_capsules c ON c.vault_id = t.vault_id AND c.host_record_id = t.host_record_id
--                                AND c.state = 'active'
--     JOIN share_gateway_keys k ON k.key_id = c.gateway_key_id AND k.state IN ('active','retiring')
--     JOIN guest_sessions g ON g.guest_session_id = :gs AND g.revoked_at IS NULL
--                          AND g.expires_at_epoch > :now AND g.idle_expires_at_epoch > :now
--    WHERE l.link_id = :link AND l.state = 'active' AND t.state = 'active'
--      AND l.authz_revision = :conn_authz_revision
--      AND l.expires_at_epoch > :now
--      AND (l.suspend_on_host_change = 0 OR h.revision_id = c.host_revision_id);
--   -- editor role additionally requires organizations.editors_may_share = 1;
--   -- schedule window and instance/relay policy are evaluated in Rust.

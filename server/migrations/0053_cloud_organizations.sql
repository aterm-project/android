-- Cloud collaboration: organizations, teams, invitations and desired Vault
-- grants. All rows are server-visible plaintext control metadata. Vault keys
-- are never stored here; key distribution reuses device-targeted Vault
-- invitations created by the key-holding Vault owner.

CREATE TABLE IF NOT EXISTS cloud_organizations (
    org_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    created_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    membership_revision INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS cloud_org_members (
    org_id TEXT NOT NULL REFERENCES cloud_organizations(org_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
    joined_at TEXT NOT NULL,
    PRIMARY KEY (org_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_cloud_org_members_user ON cloud_org_members(user_id);

CREATE TABLE IF NOT EXISTS cloud_teams (
    org_id TEXT NOT NULL REFERENCES cloud_organizations(org_id) ON DELETE CASCADE,
    team_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL,
    created_at TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY (org_id, team_id),
    UNIQUE (org_id, name_key)
);

-- Composite foreign keys prevent a team member row from naming a team or a
-- user of another organization.
CREATE TABLE IF NOT EXISTS cloud_team_members (
    org_id TEXT NOT NULL,
    team_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    added_at TEXT NOT NULL,
    PRIMARY KEY (team_id, user_id),
    FOREIGN KEY (org_id, team_id) REFERENCES cloud_teams(org_id, team_id) ON DELETE CASCADE,
    FOREIGN KEY (org_id, user_id) REFERENCES cloud_org_members(org_id, user_id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS idx_cloud_team_members_user ON cloud_team_members(org_id, user_id);

CREATE TABLE IF NOT EXISTS cloud_org_invitations (
    invitation_id TEXT PRIMARY KEY,
    org_id TEXT NOT NULL REFERENCES cloud_organizations(org_id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
    intended_user_id TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    team_id TEXT,
    created_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,
    consumed_epoch INTEGER,
    consumed_by TEXT,
    revoked_epoch INTEGER,
    FOREIGN KEY (org_id, team_id) REFERENCES cloud_teams(org_id, team_id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_cloud_org_invitations_org ON cloud_org_invitations(org_id, created_epoch);

-- A Vault attached to an organization. Kept in a side table so the existing
-- `vaults` schema and every existing query remain unchanged.
CREATE TABLE IF NOT EXISTS cloud_vault_orgs (
    vault_id TEXT PRIMARY KEY REFERENCES vaults(vault_id) ON DELETE CASCADE,
    org_id TEXT NOT NULL REFERENCES cloud_organizations(org_id) ON DELETE CASCADE,
    attached_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    attached_at TEXT NOT NULL,
    grants_revision INTEGER NOT NULL DEFAULT 1,
    UNIQUE (vault_id, org_id)
);
CREATE INDEX IF NOT EXISTS idx_cloud_vault_orgs_org ON cloud_vault_orgs(org_id);

-- Desired state only. A grant never carries key material.
CREATE TABLE IF NOT EXISTS cloud_vault_grants (
    vault_id TEXT NOT NULL,
    org_id TEXT NOT NULL,
    principal_type TEXT NOT NULL CHECK (principal_type IN ('user', 'team')),
    principal_id TEXT NOT NULL,
    role TEXT NOT NULL CHECK (role IN ('editor', 'viewer')),
    granted_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (vault_id, principal_type, principal_id),
    FOREIGN KEY (vault_id, org_id) REFERENCES cloud_vault_orgs(vault_id, org_id) ON DELETE CASCADE
);

-- Vault memberships that were created through key distribution for a grant.
-- Direct memberships (existing out-of-band invitations) are never listed and
-- are therefore never affected by organization changes.
CREATE TABLE IF NOT EXISTS cloud_vault_member_sources (
    vault_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    created_epoch INTEGER NOT NULL,
    PRIMARY KEY (vault_id, user_id),
    FOREIGN KEY (vault_id, user_id) REFERENCES vault_members(vault_id, user_id) ON DELETE CASCADE
);

-- Immediate server-side restriction of grant-derived memberships whose
-- remaining grants no longer cover them (max_role='none') or only cover a
-- weaker role (max_role='viewer'). The signed membership manifest and
-- vault_members row are left untouched so existing manifest/rotation
-- invariants keep holding; every Vault access predicate consults this table.
-- Removing the key itself still requires the owner's signed key rotation.
CREATE TABLE IF NOT EXISTS cloud_member_restrictions (
    vault_id TEXT NOT NULL,
    user_id TEXT NOT NULL,
    max_role TEXT NOT NULL CHECK (max_role IN ('none', 'viewer')),
    updated_epoch INTEGER NOT NULL,
    PRIMARY KEY (vault_id, user_id),
    FOREIGN KEY (vault_id, user_id) REFERENCES vault_members(vault_id, user_id) ON DELETE CASCADE
);

-- A recipient device's own signed share card (the existing
-- `atermius-vault-share-request-v1` device self-proof). Public material only.
CREATE TABLE IF NOT EXISTS cloud_device_cards (
    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    card_json TEXT NOT NULL,
    published_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cloud_device_cards_user ON cloud_device_cards(user_id);

-- A Vault invitation token sealed (crypto_box_seal) by the owner's client to
-- the recipient device's registered X25519 key. The server cannot open it.
CREATE TABLE IF NOT EXISTS cloud_key_deliveries (
    delivery_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    invitation_id TEXT NOT NULL UNIQUE REFERENCES invitations(invitation_id) ON DELETE CASCADE,
    recipient_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    recipient_device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
    sealed_token TEXT NOT NULL,
    created_by TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_epoch INTEGER NOT NULL,
    expires_epoch INTEGER NOT NULL,
    opened_epoch INTEGER
);
CREATE INDEX IF NOT EXISTS idx_cloud_key_deliveries_recipient ON cloud_key_deliveries(recipient_device_id, opened_epoch);

-- Metadata-only audit for organizations and sharing. Never stores tokens,
-- cookies, tickets, capsules, credentials, display envelopes or session data.
CREATE TABLE IF NOT EXISTS cloud_audit_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    scope_type TEXT NOT NULL CHECK (scope_type IN ('org', 'vault')),
    scope_id TEXT NOT NULL,
    link_id TEXT,
    guest_session_id TEXT,
    connection_id TEXT,
    actor_user_id TEXT,
    action TEXT NOT NULL,
    result TEXT NOT NULL,
    detail TEXT,
    occurred_epoch INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_cloud_audit_scope ON cloud_audit_events(scope_type, scope_id, event_id);
CREATE INDEX IF NOT EXISTS idx_cloud_audit_link ON cloud_audit_events(link_id, event_id);

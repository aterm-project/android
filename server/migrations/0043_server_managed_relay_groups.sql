-- Server-managed access groups are an administrative control plane. They are
-- separate from client-owned, encrypted Vault records and never derive ACLs
-- from ciphertext supplied by clients.
CREATE TABLE relay_access_groups (
    group_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE TABLE relay_access_group_members (
    group_id TEXT NOT NULL REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at TEXT NOT NULL,
    PRIMARY KEY (group_id, user_id)
);
CREATE INDEX idx_relay_access_group_members_user
    ON relay_access_group_members(user_id, group_id);

-- Membership CAS has a distinct lifetime from the group name revision.
CREATE TABLE relay_access_group_membership_revisions (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 0 AND 9223372036854775807)
);

-- A missing policy row means the group inherits the current instance policy.
CREATE TABLE relay_access_group_relay_policies (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);
CREATE TABLE relay_access_group_relay_policy_revisions (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);

-- Every affected active Relay connection captures this authorization version.
-- Membership and group-policy changes advance it, closing existing sockets on
-- their next authorization poll even if a later policy happens to re-allow the
-- same target. Tickets are similarly bound to the version observed at issue.
CREATE TABLE relay_user_authorization_versions (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807)
);
ALTER TABLE relay_tickets
    ADD COLUMN authorization_revision INTEGER NOT NULL DEFAULT 0
    CHECK (authorization_revision BETWEEN 0 AND 9223372036854775807);

-- Shared PostgreSQL state for SSH Relay. Tickets are hash-only credentials
-- whose destination is stored as an authenticated encrypted envelope; target
-- host/IP data must never be written in plaintext. One-use consumption is an
-- atomic UPDATE performed by the Relay repository.

-- The composite identity supports foreign keys which bind a Relay ticket or
-- live lease to exactly one account/device/session without binding the mutable
-- access expiry. Runtime checks compare the captured expiry separately so a
-- refresh cannot preserve an old ticket or silently change a live session.
ALTER TABLE sessions
    ADD CONSTRAINT sessions_relay_identity_unique
        UNIQUE (session_id, user_id, device_id);

CREATE TABLE instance_relay_policy (
    policy_id SMALLINT PRIMARY KEY,
    enabled BOOLEAN NOT NULL,
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT instance_relay_policy_singleton_check CHECK (policy_id = 1),
    CONSTRAINT instance_relay_policy_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807),
    CONSTRAINT instance_relay_policy_cidrs_array_check CHECK (jsonb_typeof(allow_cidrs::jsonb) = 'array'),
    CONSTRAINT instance_relay_policy_ports_array_check CHECK (jsonb_typeof(allow_ports::jsonb) = 'array')
);

CREATE TABLE user_relay_policies (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL,
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT user_relay_policies_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807),
    CONSTRAINT user_relay_policies_cidrs_array_check CHECK (jsonb_typeof(allow_cidrs::jsonb) = 'array'),
    CONSTRAINT user_relay_policies_ports_array_check CHECK (jsonb_typeof(allow_ports::jsonb) = 'array')
);

-- Keep the CAS generation after removing a user override, so inheritance does
-- not reset the generation to zero and accidentally accept a stale write.
CREATE TABLE user_relay_policy_revisions (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT user_relay_policy_revisions_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807)
);

CREATE TABLE relay_access_groups (
    group_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    name_key TEXT NOT NULL UNIQUE,
    revision BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT relay_access_groups_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807),
    CONSTRAINT relay_access_groups_id_check CHECK (length(group_id) BETWEEN 1 AND 128),
    CONSTRAINT relay_access_groups_name_check CHECK (length(name) BETWEEN 1 AND 128),
    CONSTRAINT relay_access_groups_name_key_check CHECK (length(name_key) BETWEEN 1 AND 256)
);

CREATE TABLE relay_access_group_members (
    group_id TEXT NOT NULL REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT relay_access_group_members_pkey PRIMARY KEY (group_id, user_id)
);
CREATE INDEX idx_relay_access_group_members_user
    ON relay_access_group_members(user_id, group_id);

CREATE TABLE relay_access_group_membership_revisions (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL,
    CONSTRAINT relay_access_group_membership_revisions_revision_check CHECK (revision BETWEEN 0 AND 9223372036854775807)
);

CREATE TABLE relay_access_group_relay_policies (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    enabled BOOLEAN NOT NULL,
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT relay_access_group_relay_policies_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807),
    CONSTRAINT relay_access_group_relay_policies_cidrs_array_check CHECK (jsonb_typeof(allow_cidrs::jsonb) = 'array'),
    CONSTRAINT relay_access_group_relay_policies_ports_array_check CHECK (jsonb_typeof(allow_ports::jsonb) = 'array')
);

CREATE TABLE relay_access_group_relay_policy_revisions (
    group_id TEXT PRIMARY KEY REFERENCES relay_access_groups(group_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT relay_access_group_relay_policy_revisions_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807)
);

-- Tickets and existing sockets capture this revision. Every membership or
-- policy change advances affected users' generation to revoke both promptly.
CREATE TABLE relay_user_authorization_versions (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    revision BIGINT NOT NULL,
    CONSTRAINT relay_user_authorization_versions_revision_check CHECK (revision BETWEEN 1 AND 9223372036854775807)
);

CREATE TABLE relay_tickets (
    ticket_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    session_access_expires_at TIMESTAMPTZ NOT NULL,
    target_envelope TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL,
    authorization_revision BIGINT NOT NULL,
    CONSTRAINT relay_tickets_hash_format CHECK (ticket_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT relay_tickets_target_envelope_format CHECK (
        target_envelope = '' OR (length(target_envelope) BETWEEN 6 AND 4096 AND target_envelope LIKE 'rtd1:%')
    ),
    CONSTRAINT relay_tickets_expiry_window CHECK (
        expires_at > created_at AND expires_at <= created_at + INTERVAL '30 seconds'
    ),
    CONSTRAINT relay_tickets_authorization_revision_check CHECK (authorization_revision BETWEEN 0 AND 9223372036854775807),
    CONSTRAINT relay_tickets_device_user_fkey FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    CONSTRAINT relay_tickets_session_identity_fkey FOREIGN KEY (session_id, user_id, device_id)
        REFERENCES sessions(session_id, user_id, device_id) ON DELETE CASCADE
);
CREATE INDEX idx_relay_tickets_expires ON relay_tickets(expires_at);
CREATE INDEX idx_relay_tickets_user_created ON relay_tickets(user_id, created_at);
CREATE INDEX idx_relay_tickets_unconsumed_expires ON relay_tickets(expires_at)
    WHERE consumed_at IS NULL;

-- These leases coordinate live connection limits and stale-worker cleanup
-- across serving nodes. They intentionally contain no target host/address.
CREATE TABLE relay_connection_leases (
    connection_id UUID PRIMARY KEY,
    node_id UUID NOT NULL,
    user_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    session_access_expires_at TIMESTAMPTZ NOT NULL,
    authorization_revision BIGINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL,
    heartbeat_at TIMESTAMPTZ NOT NULL,
    lease_expires_at TIMESTAMPTZ NOT NULL,
    CONSTRAINT relay_connection_leases_authorization_revision_check CHECK (authorization_revision BETWEEN 0 AND 9223372036854775807),
    CONSTRAINT relay_connection_leases_time_check CHECK (
        created_at <= heartbeat_at AND lease_expires_at > heartbeat_at
        AND lease_expires_at <= heartbeat_at + INTERVAL '5 minutes'
    ),
    CONSTRAINT relay_connection_leases_device_user_fkey FOREIGN KEY (device_id, user_id)
        REFERENCES devices(device_id, user_id) ON DELETE CASCADE,
    CONSTRAINT relay_connection_leases_session_identity_fkey FOREIGN KEY (session_id, user_id, device_id)
        REFERENCES sessions(session_id, user_id, device_id) ON DELETE CASCADE
);
CREATE INDEX idx_relay_connection_leases_expiry
    ON relay_connection_leases(lease_expires_at);
CREATE INDEX idx_relay_connection_leases_user_expiry
    ON relay_connection_leases(user_id, lease_expires_at);
CREATE INDEX idx_relay_connection_leases_node_expiry
    ON relay_connection_leases(node_id, lease_expires_at);

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 27)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

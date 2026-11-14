-- Optional per-account SSH Relay restrictions. When no row exists, the
-- authenticated account inherits the current instance policy.
CREATE TABLE user_relay_policies (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);

-- Keep the CAS generation after deleting the override row. This preserves
-- true inheritance (no user_relay_policies row) without allowing an old
-- expected_revision=0 request to pass after an override has been set/reset.
CREATE TABLE user_relay_policy_revisions (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);

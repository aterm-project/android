-- The row is created lazily when an administrator first changes the policy.
-- With no row, revision 0 is the current deployment environment policy.
CREATE TABLE instance_relay_policy (
    policy_id INTEGER PRIMARY KEY CHECK (policy_id = 1),
    enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
    allow_cidrs TEXT NOT NULL,
    allow_ports TEXT NOT NULL,
    revision INTEGER NOT NULL CHECK (revision BETWEEN 1 AND 9223372036854775807),
    updated_at TEXT NOT NULL
);

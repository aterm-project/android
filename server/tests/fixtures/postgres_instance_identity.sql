-- Isolated pilot schema for the instance-identity persistence compatibility
-- test. This is deliberately not part of the production migration runner.
CREATE TABLE instance_meta (
    id BIGINT PRIMARY KEY CHECK (id = 1),
    instance_id TEXT NOT NULL,
    server_space_id TEXT NOT NULL,
    generation TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    signing_key_transitions_json TEXT NOT NULL DEFAULT '[]'
);

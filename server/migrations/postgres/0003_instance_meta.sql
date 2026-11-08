-- Singleton PostgreSQL instance identity metadata.
--
-- The private Ed25519 key is provisioned separately on a shared, owner-only
-- filesystem path and is never stored in PostgreSQL. All service nodes use
-- the same file and this row so they publish one stable instance identity.

CREATE TABLE instance_meta (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    instance_id TEXT NOT NULL CHECK (length(instance_id) > 0),
    server_space_id TEXT NOT NULL CHECK (length(server_space_id) > 0),
    generation TEXT NOT NULL CHECK (length(generation) > 0),
    signing_public_key TEXT NOT NULL CHECK (length(signing_public_key) > 0),
    signing_key_transitions_json TEXT NOT NULL DEFAULT '[]'
);

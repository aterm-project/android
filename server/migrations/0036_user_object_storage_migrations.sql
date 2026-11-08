-- Durable forward-progress journal for offline user-object backend moves.
-- A running server refuses to start while any job is incomplete, so the
-- catalogue cannot be served in a mixed external-store state.
CREATE TABLE object_store_migration_jobs (
    migration_id TEXT PRIMARY KEY,
    source_backend TEXT NOT NULL CHECK(source_backend IN ('sqlite','s3','filesystem')),
    source_store_id TEXT,
    target_backend TEXT NOT NULL CHECK(target_backend IN ('sqlite','s3','filesystem')),
    target_store_id TEXT,
    state TEXT NOT NULL DEFAULT 'copying' CHECK(state IN ('copying','complete')),
    object_count INTEGER NOT NULL CHECK(object_count >= 0),
    reference_count INTEGER NOT NULL CHECK(reference_count >= 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    CHECK((source_backend='sqlite' AND source_store_id IS NULL) OR
          (source_backend<>'sqlite' AND source_store_id IS NOT NULL)),
    CHECK((target_backend='sqlite' AND target_store_id IS NULL) OR
          (target_backend<>'sqlite' AND target_store_id IS NOT NULL))
);

CREATE TABLE object_store_migration_items (
    migration_id TEXT NOT NULL REFERENCES object_store_migration_jobs(migration_id) ON DELETE CASCADE,
    vault_id TEXT NOT NULL,
    object_id TEXT NOT NULL,
    source_backend TEXT NOT NULL CHECK(source_backend IN ('sqlite','s3','filesystem')),
    source_key TEXT,
    source_store_id TEXT,
    target_backend TEXT NOT NULL CHECK(target_backend IN ('sqlite','s3','filesystem')),
    target_key TEXT,
    target_store_id TEXT,
    expected_size INTEGER NOT NULL CHECK(expected_size > 0),
    expected_sha256 TEXT NOT NULL CHECK(length(expected_sha256)=64),
    state TEXT NOT NULL DEFAULT 'pending'
        CHECK(state IN ('pending','catalogue_switched','source_pruned')),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY(migration_id,vault_id,object_id),
    CHECK((source_backend='sqlite' AND source_key IS NULL AND source_store_id IS NULL) OR
          (source_backend<>'sqlite' AND source_key IS NOT NULL AND source_store_id IS NOT NULL)),
    CHECK((target_backend='sqlite' AND target_key IS NULL AND target_store_id IS NULL) OR
          (target_backend<>'sqlite' AND target_key IS NOT NULL AND target_store_id IS NOT NULL))
);

CREATE INDEX idx_object_store_migration_items_state
    ON object_store_migration_items(migration_id,state,vault_id,object_id);

CREATE UNIQUE INDEX idx_object_store_one_incomplete_migration
    ON object_store_migration_jobs(state)
    WHERE state='copying';

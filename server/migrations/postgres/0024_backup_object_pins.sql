-- Durable, leased references to external object bytes selected by a PostgreSQL
-- backup snapshot. Pins intentionally have no FK to backup jobs or Vaults: they
-- must survive catalogue cascades until the backup releases them or the lease
-- expires.

CREATE TABLE backup_object_pins (
    backup_id TEXT NOT NULL,
    storage_store_id TEXT NOT NULL CHECK (length(storage_store_id) > 0),
    storage_key TEXT NOT NULL CHECK (length(storage_key) > 0),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT backup_object_pins_pkey
        PRIMARY KEY (backup_id, storage_store_id, storage_key),
    CONSTRAINT backup_object_pins_backup_id_format
        CHECK (backup_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);

-- The set header lets renewals fail closed if bounded expiry cleanup has
-- already removed some or all rows from a non-empty pin set. It also records
-- valid empty-object backups without inventing a sentinel store/key pin.
CREATE TABLE backup_object_pin_sets (
    backup_id TEXT PRIMARY KEY,
    object_count BIGINT NOT NULL CHECK (object_count >= 0),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    CONSTRAINT backup_object_pin_sets_backup_id_format
        CHECK (backup_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
);

-- GC and the provider deletion worker check the exact immutable store/key
-- against the database clock. The second index bounds expiry cleanup batches.
CREATE INDEX idx_backup_object_pins_storage_expiry
    ON backup_object_pins(storage_store_id, storage_key, expires_at);
CREATE INDEX idx_backup_object_pins_expiry
    ON backup_object_pins(expires_at, backup_id, storage_store_id, storage_key);
CREATE INDEX idx_backup_object_pin_sets_expiry
    ON backup_object_pin_sets(expires_at, backup_id);

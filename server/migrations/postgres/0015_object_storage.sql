-- Shared PostgreSQL reservations for encrypted object uploads. Object bytes
-- remain in the configured shared S3/filesystem backend; PostgreSQL owns the
-- immutable catalogue, chunk staging area, quota reservations, and GC ledger.
CREATE TABLE uploads (
    upload_id TEXT PRIMARY KEY,
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    object_id TEXT NOT NULL,
    expected_size BIGINT NOT NULL CHECK (expected_size > 0),
    expected_sha256 TEXT NOT NULL CHECK (expected_sha256 ~ '^[0-9a-f]{64}$'),
    chunk_size BIGINT NOT NULL CHECK (chunk_size > 0),
    state TEXT NOT NULL DEFAULT 'open'
        CHECK (state IN ('open','completing','completed','expired','collected')),
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    storage_backend TEXT NOT NULL CHECK (storage_backend IN ('s3','filesystem')),
    storage_store_id TEXT NOT NULL CHECK (length(storage_store_id) > 0),
    storage_key TEXT NOT NULL CHECK (length(storage_key) > 0)
);
CREATE INDEX idx_uploads_vault_object_state
    ON uploads(vault_id, object_id, state, expires_at);
CREATE INDEX idx_uploads_expired
    ON uploads(state, expires_at, upload_id)
    WHERE state IN ('open','completing');

CREATE TABLE upload_chunks (
    upload_id TEXT NOT NULL REFERENCES uploads(upload_id) ON DELETE CASCADE,
    chunk_index BIGINT NOT NULL CHECK (chunk_index >= 0),
    bytes BYTEA NOT NULL,
    sha256 TEXT NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    PRIMARY KEY (upload_id, chunk_index)
);

-- A completing reservation means the provider PUT may already be in flight.
-- Queue its exact immutable key before an account or Vault FK cascade can
-- erase the only durable copy of that cleanup intent.
CREATE FUNCTION queue_completing_upload_deletes(p_user_id TEXT, p_vault_id TEXT)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    upload_row RECORD;
    queued_row RECORD;
BEGIN
    FOR upload_row IN
        SELECT upload_id,storage_backend,storage_key,storage_store_id,
               expected_size,expected_sha256
        FROM uploads
        WHERE state='completing'
          AND (p_user_id IS NULL OR user_id=p_user_id)
          AND (p_vault_id IS NULL OR vault_id=p_vault_id)
        ORDER BY upload_id
        FOR UPDATE
    LOOP
        INSERT INTO object_delete_queue(
            queue_id,storage_backend,storage_key,storage_store_id,expected_size,
            expected_sha256,state,attempt_count,next_attempt_at,last_failure_category,created_at
        ) VALUES (
            'upload-expiry-' || upload_row.upload_id,
            upload_row.storage_backend,
            upload_row.storage_key,
            upload_row.storage_store_id,
            upload_row.expected_size,
            upload_row.expected_sha256,
            'pending',0,
            floor(extract(epoch FROM clock_timestamp()))::BIGINT + 90000,
            NULL,CURRENT_TIMESTAMP
        ) ON CONFLICT(storage_store_id,storage_key) DO NOTHING;

        SELECT storage_backend,expected_size,expected_sha256
        INTO queued_row
        FROM object_delete_queue
        WHERE storage_store_id=upload_row.storage_store_id
          AND storage_key=upload_row.storage_key;
        IF NOT FOUND
           OR queued_row.storage_backend<>upload_row.storage_backend
           OR queued_row.expected_size<>upload_row.expected_size
           OR queued_row.expected_sha256<>upload_row.expected_sha256 THEN
            RAISE EXCEPTION 'completing upload key has conflicting deletion metadata'
                USING ERRCODE='integrity_constraint_violation';
        END IF;
    END LOOP;
END;
$$;

CREATE FUNCTION queue_user_completing_upload_deletes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM queue_completing_upload_deletes(OLD.user_id,NULL);
    RETURN OLD;
END;
$$;

CREATE FUNCTION queue_vault_completing_upload_deletes()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    PERFORM queue_completing_upload_deletes(NULL,OLD.vault_id);
    RETURN OLD;
END;
$$;

CREATE TRIGGER users_queue_completing_upload_deletes
BEFORE DELETE ON users
FOR EACH ROW EXECUTE FUNCTION queue_user_completing_upload_deletes();

CREATE TRIGGER vaults_queue_completing_upload_deletes
BEFORE DELETE ON vaults
FOR EACH ROW EXECUTE FUNCTION queue_vault_completing_upload_deletes();

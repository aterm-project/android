-- Shared authentication rate-limit counters for PostgreSQL-backed service
-- nodes. Counter identities are HMACs; the instance-wide HMAC key is
-- provisioned out of band and must be the same on every node. This migration
-- is additive and intentionally independent of the incomplete PostgreSQL
-- sync/auth route wiring.

CREATE TABLE auth_rate_limit_meta (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    bucket_count BIGINT NOT NULL DEFAULT 0 CHECK (bucket_count BETWEEN 0 AND 100000)
);
INSERT INTO auth_rate_limit_meta(id, bucket_count) VALUES (1, 0);

CREATE TABLE auth_rate_limits (
    scope TEXT NOT NULL CHECK (scope IN ('user', 'pair', 'ip')),
    endpoint TEXT NOT NULL CHECK (endpoint IN (
        'prelogin', 'login', 'mfa_login', 'register', 'recovery_start', 'recovery_complete'
    )),
    subject_hash TEXT NOT NULL CHECK (subject_hash ~ '^[0-9a-f]{64}$'),
    window_started BIGINT NOT NULL,
    attempts BIGINT NOT NULL DEFAULT 1 CHECK (attempts BETWEEN 1 AND 1000000),
    PRIMARY KEY (scope, endpoint, subject_hash, window_started)
);
CREATE INDEX idx_auth_rate_limits_expiry ON auth_rate_limits(window_started);

-- Maintain a bounded global active-row count efficiently for statement-level
-- inserts/deletes. The application takes the singleton meta row FOR UPDATE
-- before capacity checks and all bucket mutations, making the cap atomic
-- across independent pools and service processes.
CREATE FUNCTION auth_rate_limits_count_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    inserted_count BIGINT;
BEGIN
    SELECT count(*) INTO inserted_count FROM new_rows;
    UPDATE auth_rate_limit_meta
       SET bucket_count = bucket_count + inserted_count
     WHERE id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'authentication rate-limit metadata row is missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER auth_rate_limits_count_insert
AFTER INSERT ON auth_rate_limits
REFERENCING NEW TABLE AS new_rows
FOR EACH STATEMENT EXECUTE FUNCTION auth_rate_limits_count_insert();

CREATE FUNCTION auth_rate_limits_count_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    deleted_count BIGINT;
BEGIN
    SELECT count(*) INTO deleted_count FROM old_rows;
    UPDATE auth_rate_limit_meta
       SET bucket_count = bucket_count - deleted_count
     WHERE id = 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'authentication rate-limit metadata row is missing';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER auth_rate_limits_count_delete
AFTER DELETE ON auth_rate_limits
REFERENCING OLD TABLE AS old_rows
FOR EACH STATEMENT EXECUTE FUNCTION auth_rate_limits_count_delete();

-- Shared, independently revocable Prometheus scrape credential. Only the
-- server-keyed HMAC verifier is retained; the plaintext credential is issued
-- once by the future admin route.
CREATE TABLE instance_metrics_credential (
    credential_id SMALLINT PRIMARY KEY CHECK (credential_id = 1),
    verifier BYTEA NOT NULL CHECK (octet_length(verifier) = 32),
    created_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

INSERT INTO atermius_instance_schema(singleton, schema_version)
VALUES (1, 35)
ON CONFLICT (singleton) DO UPDATE
    SET schema_version = GREATEST(atermius_instance_schema.schema_version, EXCLUDED.schema_version);

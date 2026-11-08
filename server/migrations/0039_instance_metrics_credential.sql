-- A single, independently revocable Prometheus scrape credential. Only a
-- server-keyed HMAC verifier is retained; plaintext is returned once.
CREATE TABLE instance_metrics_credential (
    credential_id INTEGER PRIMARY KEY CHECK (credential_id = 1),
    verifier BLOB NOT NULL CHECK (typeof(verifier) = 'blob' AND length(verifier) = 32),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

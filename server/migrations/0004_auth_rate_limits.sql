CREATE TABLE IF NOT EXISTS auth_rate_limits (
    scope TEXT NOT NULL CHECK (scope IN ('user', 'pair', 'ip')),
    endpoint TEXT NOT NULL CHECK (endpoint IN ('prelogin', 'login', 'register')),
    subject_hash TEXT NOT NULL,
    window_started INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    PRIMARY KEY(scope, endpoint, subject_hash, window_started)
);

CREATE INDEX IF NOT EXISTS idx_auth_rate_limits_expiry
    ON auth_rate_limits(window_started);

CREATE TABLE IF NOT EXISTS auth_rate_limit_meta (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    bucket_count INTEGER NOT NULL DEFAULT 0 CHECK (bucket_count >= 0)
);

INSERT OR IGNORE INTO auth_rate_limit_meta(id, bucket_count) VALUES(1, 0);

CREATE TRIGGER IF NOT EXISTS auth_rate_limits_count_insert
AFTER INSERT ON auth_rate_limits
BEGIN
    UPDATE auth_rate_limit_meta SET bucket_count=bucket_count+1 WHERE id=1;
END;

CREATE TRIGGER IF NOT EXISTS auth_rate_limits_count_delete
AFTER DELETE ON auth_rate_limits
BEGIN
    UPDATE auth_rate_limit_meta SET bucket_count=bucket_count-1 WHERE id=1;
END;

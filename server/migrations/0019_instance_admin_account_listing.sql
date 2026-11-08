-- Keep bounded instance-admin account pages ordered without sorting every
-- account row, and make per-account live-session counts inexpensive.
CREATE INDEX idx_users_admin_listing
    ON users(created_at DESC, user_id ASC);

CREATE INDEX idx_sessions_user_refresh_expiry
    ON sessions(user_id, refresh_expires_at)
    WHERE revoked_at IS NULL;

-- Recovery generation must remain monotonic when a user disables and later
-- re-enables recovery. Keep this counter outside the deletable descriptor.
CREATE TABLE account_recovery_generation (
    user_id TEXT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
    last_generation INTEGER NOT NULL CHECK (last_generation >= 0)
);

INSERT INTO account_recovery_generation(user_id, last_generation)
SELECT user_id, recovery_generation FROM account_recovery;

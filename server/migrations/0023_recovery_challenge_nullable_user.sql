-- Persist the same opaque Recovery challenge shape for real and decoy starts.
-- Decoy rows use NULL for user_id and therefore cannot match an account during
-- inspect/complete validation. Existing challenge hashes and expiry state are
-- retained byte-for-byte across the table rebuild.
CREATE TABLE account_recovery_challenges_new (
    challenge_id_hash TEXT PRIMARY KEY CHECK (
        length(challenge_id_hash) = 64 AND challenge_id_hash NOT GLOB '*[^0-9a-f]*'
    ),
    challenge_hash TEXT NOT NULL CHECK (
        length(challenge_hash) = 64 AND challenge_hash NOT GLOB '*[^0-9a-f]*'
    ),
    user_id TEXT REFERENCES users(user_id) ON DELETE CASCADE,
    recovery_generation INTEGER NOT NULL CHECK (recovery_generation > 0),
    expires_at INTEGER NOT NULL,
    consumed_at INTEGER
);

INSERT INTO account_recovery_challenges_new (
    challenge_id_hash,
    challenge_hash,
    user_id,
    recovery_generation,
    expires_at,
    consumed_at
)
SELECT
    challenge_id_hash,
    challenge_hash,
    user_id,
    recovery_generation,
    expires_at,
    consumed_at
FROM account_recovery_challenges;

DROP TABLE account_recovery_challenges;
ALTER TABLE account_recovery_challenges_new RENAME TO account_recovery_challenges;

CREATE INDEX idx_recovery_challenges_expiry
    ON account_recovery_challenges(expires_at);

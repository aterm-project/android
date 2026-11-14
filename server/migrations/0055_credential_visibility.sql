-- Credential visibility v1 (SQLite runtime only).
--
-- Every account has an administrator-controlled credential-visibility mode.
-- `private` keeps today's zero-knowledge behavior. `admin_visible` makes the
-- account's own client escrow its Vault keys to an instance escrow X25519 key
-- whose private half is held only by administrator clients (wrapped under
-- each administrator's account key and under one offline recovery code).
-- The server stores ciphertext, signatures and public keys only; nothing in
-- this schema can decrypt a Vault key or a record without an administrator's
-- client-side secret. Existing accounts become `private` (no silent exposure
-- on upgrade).

ALTER TABLE users ADD COLUMN credential_visibility TEXT NOT NULL DEFAULT 'private'
    CHECK (credential_visibility IN ('private', 'admin_visible'));
-- NULL means the mode was set at account creation and never changed since.
ALTER TABLE users ADD COLUMN credential_visibility_changed_at TEXT;

-- NULL means "use the instance default at registration time".
ALTER TABLE account_invitations ADD COLUMN credential_visibility TEXT
    CHECK (credential_visibility IS NULL OR credential_visibility IN ('private', 'admin_visible'));

CREATE TABLE IF NOT EXISTS instance_credential_policy (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    default_visibility TEXT NOT NULL CHECK (default_visibility IN ('private', 'admin_visible')),
    updated_at TEXT NOT NULL,
    updated_by_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL
);
INSERT OR IGNORE INTO instance_credential_policy(id, default_visibility, updated_at)
    VALUES (1, 'private', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));

-- At most one escrow key exists. `signed_payload` is the exact JCS string the
-- instance signing key signed; `creator_signature` is the creating
-- administrator device's Ed25519 signature over the creation statement.
-- `recovery_wrap` is the escrow secret key encrypted under an Argon2id key
-- derived from an offline recovery code that the server never receives.
CREATE TABLE IF NOT EXISTS credential_escrow_keys (
    key_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL UNIQUE,
    signed_payload TEXT NOT NULL,
    instance_signature TEXT NOT NULL,
    creator_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    creator_device_id TEXT,
    creator_signature TEXT NOT NULL,
    recovery_wrap TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE TRIGGER IF NOT EXISTS credential_escrow_keys_single_row
BEFORE INSERT ON credential_escrow_keys
WHEN EXISTS (SELECT 1 FROM credential_escrow_keys)
BEGIN
    SELECT RAISE(ABORT, 'credential escrow key already exists');
END;

-- One wrap per administrator account: the escrow secret key encrypted under
-- a key derived from that administrator's random account key.
CREATE TABLE IF NOT EXISTS credential_escrow_key_wraps (
    key_id TEXT NOT NULL REFERENCES credential_escrow_keys(key_id) ON DELETE CASCADE,
    user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    wrap TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (key_id, user_id)
);

-- One sealed Vault key per (Vault, key epoch, escrow key). Rows are written by
-- an admin_visible member's own device and are never overwritten.
CREATE TABLE IF NOT EXISTS credential_escrow_envelopes (
    vault_id TEXT NOT NULL REFERENCES vaults(vault_id) ON DELETE CASCADE,
    key_epoch INTEGER NOT NULL CHECK (key_epoch >= 1),
    key_id TEXT NOT NULL REFERENCES credential_escrow_keys(key_id) ON DELETE CASCADE,
    sealed TEXT NOT NULL,
    signature TEXT NOT NULL,
    depositor_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    depositor_device_id TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (vault_id, key_epoch, key_id)
);
CREATE INDEX IF NOT EXISTS idx_credential_escrow_envelopes_key
    ON credential_escrow_envelopes(key_id, vault_id);
CREATE INDEX IF NOT EXISTS idx_credential_escrow_envelopes_depositor
    ON credential_escrow_envelopes(depositor_user_id);

-- Administrator reads of escrowed credentials, shown to the affected user.
-- Rows are coalesced (same administrator, account and Vault within ten
-- minutes) and pruned to the newest 200 per account in the insert transaction.
CREATE TABLE IF NOT EXISTS credential_admin_views (
    view_id TEXT PRIMARY KEY,
    target_user_id TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    admin_user_id TEXT REFERENCES users(user_id) ON DELETE SET NULL,
    vault_id TEXT,
    viewed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_credential_admin_views_target
    ON credential_admin_views(target_user_id, viewed_at DESC);
CREATE INDEX IF NOT EXISTS idx_credential_admin_views_admin
    ON credential_admin_views(admin_user_id);
CREATE INDEX IF NOT EXISTS idx_credential_escrow_key_wraps_user
    ON credential_escrow_key_wraps(user_id);

-- Escrow-status computation looks up an account's delivered Vault key epochs.
CREATE INDEX IF NOT EXISTS idx_vault_key_envelopes_recipient_user
    ON vault_key_envelopes(recipient_user_id, vault_id, epoch);

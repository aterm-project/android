-- Preserve issuance ordering for pending invitations. Historical rows remain
-- NULL because their actual creation time cannot be reconstructed safely.
ALTER TABLE invitations ADD COLUMN created_at TEXT;
ALTER TABLE invitations ADD COLUMN issuance_order INTEGER;

CREATE INDEX idx_invitation_pending_recipient_order
    ON invitations(vault_id, recipient_user_id, issuance_order DESC, created_at DESC, invitation_id DESC)
    WHERE accepted_at IS NULL;

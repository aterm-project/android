-- Terminal instance-account invitations can be removed after the configured
-- retention horizon; their audit events remain independently retained.
CREATE INDEX idx_account_invitations_consumed_retention
    ON account_invitations(consumed_at)
    WHERE consumed_at IS NOT NULL;

CREATE INDEX idx_account_invitations_revoked_retention
    ON account_invitations(revoked_at)
    WHERE revoked_at IS NOT NULL;

CREATE INDEX idx_account_invitations_expired_retention
    ON account_invitations(expires_at)
    WHERE consumed_at IS NULL AND revoked_at IS NULL;

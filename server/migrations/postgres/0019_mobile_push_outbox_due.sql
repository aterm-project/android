-- The outbox already exists in 0001 for transactional sync enqueue. This
-- migration adds the due-work index and aligns encrypted token envelope bounds
-- with the SQLite endpoint contract before a PostgreSQL delivery worker starts.
ALTER TABLE notification_push_endpoints
    ADD CONSTRAINT notification_push_token_envelope_length
    CHECK (char_length(token_envelope) BETWEEN 80 AND 8192);

CREATE INDEX idx_notification_push_outbox_due
    ON notification_push_outbox(next_attempt_at,updated_at,endpoint_id)
    WHERE requested_seq > delivered_seq AND dead_lettered=FALSE;

-- Admin audit pagination filters on the instance scope and advances by the
-- globally monotonic event ID. Keep this partial index small while allowing
-- the fixed-high-water-mark page query to seek and stream in event order.
CREATE INDEX idx_audit_events_instance_event_id
    ON audit_events(event_id)
    WHERE scope_type = 'instance';

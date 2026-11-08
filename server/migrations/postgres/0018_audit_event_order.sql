-- Prepare audit event IDs for stable cross-request pagination.
--
-- Apply while every application node and database-backed worker is stopped.
-- This both drops any identity values cached by old backends and repairs the
-- sequence after explicit-ID imports/restores before the new runtime starts.
-- First-page readers take SHARE on audit_events before reading MAX(event_id);
-- all normal writers use this identity sequence and insert the audit row as
-- their final database write in the transaction.
BEGIN;

LOCK TABLE audit_events IN ACCESS EXCLUSIVE MODE;

DO $$
DECLARE
    event_sequence REGCLASS;
    sequence_last_value BIGINT;
    sequence_is_called BOOLEAN;
    highest_event_id BIGINT;
BEGIN
    event_sequence := pg_get_serial_sequence(
        format('%I.%I', current_schema(), 'audit_events'),
        'event_id'
    )::REGCLASS;
    IF event_sequence IS NULL THEN
        RAISE EXCEPTION 'audit event identity sequence is unavailable';
    END IF;

    EXECUTE format(
        'SELECT last_value, is_called FROM %s',
        event_sequence
    ) INTO sequence_last_value, sequence_is_called;
    SELECT COALESCE(MAX(event_id), 0)
      INTO highest_event_id
      FROM audit_events;

    -- A restore or explicit identity import may leave the sequence behind the
    -- table. Advance it so the next generated value is strictly above MAX.
    IF NOT sequence_is_called OR sequence_last_value < highest_event_id THEN
        PERFORM setval(
            event_sequence,
            GREATEST(sequence_last_value, highest_event_id),
            TRUE
        );
    END IF;

    -- CACHE > 1 lets different backends hand out values from reserved blocks
    -- out of order. The upgrade procedure disconnects every old backend first
    -- so no node can retain a pre-migration block.
    EXECUTE format('ALTER SEQUENCE %s CACHE 1', event_sequence);
END;
$$;

COMMIT;

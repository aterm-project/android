-- Bound the PostgreSQL instance-audit feed's high-watermark and keyset scans.
-- The partial B-tree contains only instance-scope event IDs, which lets MAX,
-- range predicates, and ORDER BY event_id skip account/Vault audit rows.
--
-- Apply this file as a single statement in autocommit mode. CREATE INDEX
-- CONCURRENTLY cannot run inside a transaction block. It permits ordinary
-- audit reads and writes during its two scans, unlike a regular CREATE INDEX,
-- but consumes extra I/O/WAL and can wait for old snapshots to finish. If an
-- interrupted build leaves an invalid index, inspect pg_index.indisvalid,
-- drop that invalid index concurrently, and rerun this migration before
-- starting a runtime that requires it.
CREATE INDEX CONCURRENTLY idx_audit_events_instance_event_id
    ON audit_events (event_id)
    WHERE scope_type = 'instance';

# PostgreSQL runtime schema upgrade

> **Current release:** migrations 0001 through 0032 and schema-32 readiness are
> required. Migration 0028 adds durable binding and discard lifecycle state
> for isolated PostgreSQL restore stages. Migration 0029 adds the separate
> signed redaction-capability report and retained invalidation watermark.
> Migration 0030 adds record-redaction state, 0031 adds resolved-conflict
> redaction compatibility, and 0032 stores a fixed restore deadline on each
> delete revision. The runtime also includes the schema-27 SSH Relay tables
> and scheduled backups.
> Encrypted restore archives with markers 25 through 32 are supported; older
> markers are upgraded on the isolated target through the bundled migration
> chain.

The restricted PostgreSQL runtime does not apply migrations at startup. Apply
the ordered SQL files under `server/migrations/postgres` to the configured
schema before starting a release that depends on them. Startup checks the
shared schema and fails closed when a required table, migration object, or
audit identity-sequence invariant is missing.

## Upgrade procedure

1. Take and verify a PostgreSQL backup using the deployment's existing backup
   procedure. Record the target database and schema; keep credentials out of
   shell arguments and logs.
2. Stop every Atermius node and database-backed worker that can write to the
   target database. Stop migration/import jobs and monitoring processes that
   can write audit rows as well. Confirm all old application connections have
   closed; migration 0018 must clear any per-backend identity-sequence cache.
3. Using the deployment's protected PostgreSQL credentials, apply every
   unapplied file in `server/migrations/postgres` in ascending numeric order,
   with the intended schema selected in `search_path`. Do not apply these
   PostgreSQL files to the SQLite database or default SQLite migration
   directory.
4. Confirm the migration command completed successfully. Migration 0018
   takes an exclusive lock on `audit_events`, advances its identity sequence
   above the greatest stored `event_id`, and sets the sequence cache to one.
   It is safe to rerun after a partial deployment only when the target nodes
   remain stopped; the sequence repair is monotonic. Migration 0019 adds the
   push-outbox due index and validates encrypted endpoint-envelope bounds.
   Migration 0020 is one `CREATE INDEX CONCURRENTLY` statement: execute that
   file in PostgreSQL autocommit mode, outside any explicit transaction. It
   builds the partial instance-audit event index while ordinary reads and
   writes continue, at the cost of extra I/O/WAL and waiting for old snapshots.
   Before starting the new runtime, confirm the index is both `indisready` and
   `indisvalid` in `pg_index`. Migration 0021 creates the shared Vault
   presence lease and heartbeat-gate tables with their read/cleanup indexes;
   it runs as ordinary transactional DDL. Migration 0022 creates the shared
   instance-admin maintenance-job ledger and its page, worker, and unique
   one-active-job indexes; it also runs as ordinary transactional DDL.
   Migration 0024 adds durable pins that prevent PostgreSQL object GC and
   external-delete workers from removing bytes held by a backup snapshot.
   Migration 0025 extends the shared job ledger for encrypted backup and
   isolated restore metadata and replaces the active-job index with an
   instance-wide one-job fence. Both run as ordinary transactional DDL.
   Migration 0026 advances the runtime schema marker to 26 and adds shared
   PostgreSQL backup-schedule state, scheduled-job provenance and readiness
   constraints/indexes. It is ordinary transactional DDL so the restore worker
   can apply the bundled migration to an isolated schema-25 restore target.
   Migration 0027 adds shared Relay policy, access-group, hash-only ticket and
   connection-lease state, plus the foreign keys and indexes used for
   cross-node authorization and cleanup. Target data is stored only in the
   authenticated encrypted ticket envelope. It is ordinary transactional DDL
   and advances the shared marker to 27. Migration 0028 adds restore-stage
   target binding, discard actor/timestamps, two-phase cleanup state, and
   bounded retry scheduling to the shared job ledger. Its constraints and
   retry index keep that lifecycle durable across nodes. It is ordinary
   transactional DDL and advances the shared marker to 28. Migration 0029 adds
   the signed per-device redaction-capability report and retained invalidation
   watermark. It is ordinary transactional DDL and advances the marker to 29.
   Migration 0030 adds the redaction ledger and supporting indexes; migration
   0031 preserves resolved conflict rows when their payloads are redacted.
   Migration 0032 adds nullable `record_versions.restore_until` and advances
   the shared marker to 32. These are ordinary transactional DDL. After
   migration 0032, the new server backfills legacy delete rows before serving:
   active databases use the same effective retention value the old runtime
   advertised at upgrade time, while restored archives use the archived
   runtime-policy value. This preserves the cutoff visible immediately before
   upgrade; older schemas did not retain historical per-delete policy values.
   Start the schema-32 release only after migrations 0001 through 0032 have
   been applied and readiness checks pass.
5. Start the new runtime release on every node. Readiness checks that the
   `audit_events.event_id` identity sequence is present, has cache size one,
   and has a last value at least as high as the table maximum. It also checks
   the push schema objects, the valid instance-audit index, the presence
   tables/indexes, the maintenance-job and backup/restore ledger constraints
   and indexes, the schedule row/constraints/indexes, Relay tables/constraints/
   indexes and marker 32, including the restore-stage binding/discard checks
   and retry index, and both backup-pin tables. An invalid sequence or
   missing migration fails startup before the node serves traffic.
6. Confirm every node is healthy before re-enabling scheduled database
   maintenance and other writers.

Do not run a mixed-version rolling deployment across migration 0018. A
pre-migration backend may still hold cached identity values, which can make a
later insert receive an ID below the audit page high-water mark. Stop the old
nodes first, apply the migration once to the shared schema, and then start the
new release.

If an operator imports `audit_events` with explicit `event_id` values after
migration 0018, stop all nodes and rerun migration 0018 before serving writes.
This restores the identity sequence after the import. Ordinary application
inserts omit `event_id` and use the identity sequence.

Migration 0018 also supports the first page of `GET /api/v1/audit`. That read
starts a `READ COMMITTED` transaction, locks `audit_events` in `SHARE` mode,
reads `MAX(event_id)`, and commits to release the lock before running the
scope-filtered page query. With sequence cache size one, every audit insert
that starts after the lock is released receives an ID above this high-water
mark. Keeping the scope scan outside the table lock prevents a user with few
matching events from blocking audit writes while PostgreSQL filters unrelated
rows. Audited write transactions append their audit rows as their final
database write, preventing a lock-queue cycle while the page establishes its
stable high-water mark.

Migration 0020 adds a partial B-tree over instance-scope audit event IDs. It
supports the bounded first-page high-water mark and ordered keyset query for
`GET /api/v1/admin/audit` without scanning unrelated account/Vault event IDs.
If a concurrent index build is interrupted, inspect the named index's
`pg_index.indisvalid` value. Drop an invalid remnant with
`DROP INDEX CONCURRENTLY IF EXISTS idx_audit_events_instance_event_id;`, then
rerun migration 0020 in autocommit mode and verify both `indisready` and
`indisvalid` before starting the runtime.

Migration 0022 introduced the shared PostgreSQL maintenance-job ledger;
migration 0025 expands it for encrypted backup and isolated restore, migration
0026 adds the shared schedule row and scheduled-job metadata, migration
0028 adds the durable restore-stage discard lifecycle, migration 0029 adds the
redaction-capability report and retained invalidation watermark, migration
0030 adds the record-redaction ledger, migration 0031 preserves resolved
conflict rows during payload scrubbing, and migration 0032 adds fixed tombstone
restore deadlines. The partial unique
index is the shared cross-node fence that permits at most one
queued or running instance-admin job. Each node's worker claims with
`FOR UPDATE SKIP LOCKED`, a random worker token, and a renewable database-clock
lease; job state transitions and HMAC-only instance audit events commit in the
same PostgreSQL transactions. The 30-second schedule worker uses the
PostgreSQL clock and writes the scheduled backup job and next due time
atomically. Readiness verifies the ledger constraints and indexes, schedule
objects and marker 32, the redaction-capability report table, redaction ledger,
conflict-redaction compatibility, restore-deadline column, and both backup-pin
tables before serving.
`GET /api/v1/admin/jobs`
advertises backup only when archive storage, key, schema and PostgreSQL client
tools are ready; `backup_schedule` is advertised when its shared schema is
ready, while enabling a cadence also requires backup configuration and tools.
Restore is advertised only when `ATERMIUS_PG_RESTORE_TARGET_URL` points to a
distinct empty database and the runtime schema name is a dedicated application
schema (not `public`, a PostgreSQL system schema, or the reserved
`atermius_restore_control` schema). PG mode currently supports local archive
sources only. PG scheduled backup is available through the shared job ledger;
unfinished scheduled jobs are marked interrupted after lease expiry and are
not replayed. The `restore_stage_discard` capability is advertised when the
shared schema is ready, the restore target URL is configured, and the private
archive/staging directory is available. Discard does not require the backup
encryption key or `pg_dump`/`pg_restore`; creating backups and restoring new
stages still require their own configured storage, key, and compatible tools.

Restore prepares a separate target database/schema and private object-store
stage; it does not activate or cut over the live service. A new stage records a
random binding in both the shared job ledger and the target's reserved
`atermius_restore_control.stage_binding` marker. That binding includes the
configured target fingerprint, PostgreSQL database name and OID, application
schema, generation, and staged object-store identity/inventory. Discard is
available only to the original requesting user while that user is an active
instance administrator. It validates the job receipt, archive identity and
digest, target URL/database identity, marker, restored schema, generation and
staged-object inventory before deleting anything. Unknown schemas or objects,
a changed/recreated target, a missing or mismatched marker, and other validation
failures stop cleanup without deleting the mismatched target contents.

Cleanup has two durable phases: remove the bound application schema and staged
object files while retaining the target marker; then commit the discarded
lifecycle and one audit event, remove the marker, and record target cleanup in
the shared ledger. The marker and a target-side advisory lock protect an
interrupted cleanup from another node or from reuse of the target. A worker
retries unfinished `discarding` or `discarded` cleanup with exponential delay
from 30 seconds up to one hour; an owner can also retry from Settings. A fully
completed replay returns the existing discard timestamp and does not add a
second discard audit event. The configured target database itself remains in
place. Discard removes only the isolated restore copy and staged files; it does
not alter the source archive, live database, or active object store. The
runtime still does not provide SQLite replication, remote replica restore, or
online activation. A single-server, offline Compose cutover coordinator is
documented in the [backup and restore runbook](instance-backup-restore.md).
The restore target's `activated_at` and `rollback_started_at` fields are
created in its local `atermius_restore_control.stage_binding` table when the
stage is built. They are not shared migrations, do not change schema marker
28, and do not add migration 0029. Current stages require both nullable
`TIMESTAMPTZ` columns before activation or rollback fencing. A legacy marker
missing either field remains eligible for fully validated discard; activation
and fencing fail closed because the marker cannot safely arbitrate those
transitions.

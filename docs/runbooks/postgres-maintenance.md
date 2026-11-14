# PostgreSQL bounded retention maintenance

> **Current release:** PostgreSQL scheduled backups use migration 0026 and the
> shared instance-admin job ledger. The dual-node HTTP acceptance passed on a
> disposable PostgreSQL 17 cluster. A full schema-25 encrypted archive restore
> was not part of that schedule acceptance.

**Batch-boundary verification (2026-10-10):** two focused acceptance tests
passed against disposable PostgreSQL 17.11. They verified that one maintenance
pass removes at most 500 expired change events and processes at most eight
expired snapshots per Vault, and that presence cleanup removes at most 10,000
expired leases and 10,000 obsolete heartbeat-gate rows per pass. The harness
also verified fixture process shutdown and exact temporary-root cleanup. This
does not cover PG Settings Chromium or establish general PostgreSQL parity.

This procedure runs one bounded retention pass for the restricted PostgreSQL
runtime. It is safe to run while service nodes are online. SQLite remains the
default backend; select PostgreSQL explicitly and use the same deployment
configuration, secrets, service account, and local `ATERMIUS_DATA_DIR` used by
the running server.

## When to run it

Each PostgreSQL node starts an hourly maintenance worker. The interval's first
tick runs immediately after startup; later ticks run every hour. The worker and
the operator command use the same bounded pass, so the command is useful for
draining an accumulated backlog or retrying after a transient database error.
Repeated and concurrent passes are safe. A single pass may leave due work for
the next worker tick or operator run.

The maintenance process takes the database-scoped shared runtime advisory
lock. This allows it to coexist with serving nodes and prevents an offline
operation from starting during a pass. MFA key rotation needs the exclusive
lock and a database with no other client connections, so stop nodes and
workers and follow [the MFA key rotation runbook](mfa-seed-key-rotation.md)
before rotating that key.

## Run one pass

For a running Compose service named `server`, run this from the deployment's
Compose project with the same environment file and overlays used to start it.
The example assumes that service is already configured for PostgreSQL; this
repository's default Compose file is SQLite-only and does not provision or
configure a PostgreSQL database:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  exec server /usr/local/bin/atermius-server maintenance
```

For another deployment, invoke `atermius-server maintenance` as the service
user with the service's normal environment and secret mounts. In particular,
keep `ATERMIUS_SYNC_BACKEND=postgres`, the shared PG URL/schema, the runtime key
file settings, and the local SQLite `ATERMIUS_DATABASE_URL` configuration
unchanged. Do not put database credentials or key material in command-line
arguments. The command prints `Maintenance completed.` and exits zero on
success; a failed configuration or database operation exits nonzero. The
command accepts no additional arguments; unsupported arguments fail before the
runtime opens either database. It does not print row counts or secret values.

An allowlisted instance administrator can also start this same bounded pass
from Settings with **Run maintenance now**. In PostgreSQL mode the API stores a
durable job in the shared migration-0022 ledger; every node can observe it, and
one worker claims it with a database-clock lease. Request replay by the same
administrator and device returns the original job. Only one maintenance job
can be queued or running across the instance. The UI shows the fixed result and
does not expose internal errors. This Settings action runs the same
`PgMaintenanceRepository` pass as the CLI and hourly worker.

The PostgreSQL job API reports capabilities for the active runtime. It can
advertise encrypted backup when the archive directory, key, schema and
`pg_dump`/`pg_restore` tools are ready. It advertises restore only when
`ATERMIUS_PG_RESTORE_TARGET_URL` points to a distinct empty database. PG
restore sources are local encrypted archives only. The shared backup-status
summary is available, but does not prove that an archive remains present or is
restorable. Replication, remote replica restore, and restore-stage discard
remain unavailable in PostgreSQL mode.

An allowlisted administrator uses
`GET /api/v1/admin/backup-schedule` and `PUT /api/v1/admin/backup-schedule`
with `interval_hours` from 1 to 720 or `null` to disable. Each PG node polls
shared due state every 30 seconds using the PostgreSQL clock. A short
transaction locks the schedule row, claims one due slot, creates a scheduled
backup in the shared `instance_admin_jobs` ledger and advances the
next due time atomically. Missed intervals coalesce to the next future due
time. The ledger's unique queued/running-job fence serializes scheduled work
against manual backup, restore and maintenance across nodes; if another job
owns the slot, the schedule remains due. Restart recovery marks unfinished
scheduled work interrupted and never replays it. Schedule changes are audited
with the real administrator actor; run lifecycle records use an explicit
scheduler/system origin, never a fabricated administrator. The schedule
capability requires schema/API readiness. Enabling also requires every node
that can claim the job to share the private archive directory, 32-byte backup
key, PostgreSQL schema and external object store, with compatible
`pg_dump`/`pg_restore` tools. When backup storage or key is missing, GET still
returns the schedule state and PUT enable fails with `BACKUP_NOT_CONFIGURED`.

The PG restore job
prepares a separate database and filesystem object-store stage; it does not
activate or cut over the live service. See the PostgreSQL section in the
[backup and restore runbook](instance-backup-restore.md) before enabling these
actions.

The current PG runtime requires migrations through
`0027_shared_ssh_relay.sql` before it starts. The requirements include the `0019`
mobile-push outbox constraint/index, the `0020` concurrent instance-audit
index, the `0021` presence lease tables/indexes, the `0024` backup object-pin
tables, the `0025` shared backup/restore job schema, the `0026` schedule state
and job provenance, and the `0027` Relay policy/group/ticket/lease schema and
readiness objects. Follow
the [PostgreSQL runtime upgrade procedure](postgres-runtime-upgrade.md) for
migration ordering and concurrent-index recovery. The command does not apply
PostgreSQL migrations and does not fall back to SQLite for retention work when
PostgreSQL is selected. Startup still opens and migrates the node-local SQLite
application database required by the current runtime.

For a runtime release that adds migrations, follow the
[PostgreSQL runtime upgrade procedure](postgres-runtime-upgrade.md) before
starting the new binary.

## What one pass removes

History retention uses the configured `ATERMIUS_HISTORY_RETENTION_DAYS`
cutoff (default 90 days, valid range 1–3650). The separate `ATERMIUS_RECORD_RESTORE_RETENTION_DAYS` policy (default 30, valid range 1–3650) controls how long a deleted record can be restored; expired tombstones remain reserved by the graveyard. It advances only a contiguous
expired prefix of each Vault's ordered event stream. At most 32 Vault counters
with due work are claimed per pass, and at most 500 events are examined per
Vault. The counter floor update and deletion of that exact prefix commit in
the same transaction. A recent or missing event at the floor stops compaction;
later events are not skipped. Idle Vaults do not consume the due-work batch.

Expired snapshots are first changed to an empty manifest with format
`expired`. A pass claims at most eight snapshots per claimed Vault and deletes
at most 1,000 snapshot child rows across the entire pass. It keeps the parent
snapshot row as a tombstone. Snapshot reads use the PostgreSQL clock and return
`410 SNAPSHOT_EXPIRED` as soon as the snapshot expires, including while child
rows are being removed and after cleanup completes. Do not delete these parent
rows as a manual cleanup step.

Authentication rate-limit cleanup deletes at most 1,000 expired buckets per
pass. A metadata row lock serializes cleanup with bucket writes, and the
existing database trigger keeps the global bucket count in sync.

Notification-ticket cleanup deletes at most 1,000 rows per pass, and only
after their creation time is at least 60 seconds old according to PostgreSQL.
Tickets remain part of per-user and per-session issuance limits for that full
minute, even though an unconsumed ticket can authenticate a WebSocket for only
30 seconds. This preserves the rate-limit window while bounding cleanup work.

Presence maintenance deletes at most 10,000 expired or no-longer-authorized
Vault leases and 10,000 obsolete heartbeat-gate rows per pass. Presence reads
filter expired leases immediately using PostgreSQL time, so a cleanup backlog
cannot make an offline device appear online. The 90-second lease TTL and
five-second heartbeat gate are shared across service nodes.

All cutoffs use PostgreSQL time. Row locks and `SKIP LOCKED` coordinate
multiple nodes and operator runs. History/snapshot cleanup and rate-limit
cleanup commit in separate transactions; a failure rolls back the affected
subsystem's batch and can be retried by a later pass.

## Troubleshooting

- If the command exits nonzero, check the service's sanitized application
  logs and PostgreSQL availability, schema, and permissions. Do not advance
  `minimum_available_seq`, delete snapshot parents, or edit bucket counts by
  hand.
- A pass reports no counts. To drain a large backlog sooner, run it again;
  each invocation remains bounded.
- If a snapshot has expired, clients should create a new snapshot and preserve
  their local outbox according to the sync recovery flow. The server retains
  the expired parent so all nodes return the same `410` response.
- This maintenance pass covers PostgreSQL sync-event retention, expired
  snapshot payloads, expired notification tickets, authentication rate-limit
  buckets, and presence leases. It does not establish general PostgreSQL/HA
  parity or replace account/Vault deletion, object-store, backup, or restore
  workers. Account and Vault deletion deadlines and retention cutoffs are
  rechecked against PostgreSQL time in their own lifecycle paths. The Settings
  maintenance-job route is supported; other PG admin controls remain outside
  this slice.

The supported boundaries and current source-check scope are recorded in
[implementation status](../IMPLEMENTATION-STATUS.md). Follow the dated evidence
in this runbook for its specific PostgreSQL slice; it is not a general PG parity claim.

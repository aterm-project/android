# Instance backup and restore

This runbook covers the encrypted SQLite instance archive produced by the
`atermius-server backup` command and the staged `restore` command. It is an
operator recovery procedure, not a substitute for an isolated restore drill.

## PostgreSQL runtime backup and restore

> **Current release:** PostgreSQL shared schema marker 39 and migrations
> 0001–0039 are required. Restore-target control markers carry target-local
> activation and rollback-fence timestamps. Migration 0029 separately adds
> device redaction-capability state. The marker-25 encrypted archive restore
> and isolated discard path have passed focused PostgreSQL 17.11 acceptance;
> the offline Compose coordinator has mocked recovery tests but has not run as
> a live cutover.

PostgreSQL uses the Settings job API, not the SQLite backup CLI flow below.
Use a release with PostgreSQL migrations through 0039_mobile_push_delivery_daily.sql and matching schema-39 runtime readiness checks. Marker-25 encrypted archives upgrade through the current schema during isolated restore. Each serving node must share the same private ATERMIUS_BACKUP_ARCHIVE_DIR, backup key, PostgreSQL schema and external object-store bytes/configuration. Configure the archive directory as an owner-only mode-0700 directory outside ATERMIUS_DATA_DIR, and ATERMIUS_BACKUP_KEY_FILE as a service-owner-only file containing exactly 32 bytes outside ATERMIUS_DATA_DIR. These settings are separate from PostgreSQL connection secrets. Keep the archive volume and encryption key separately protected and retain the exact ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE and ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE values with recovery material. The MFA seed-encryption key remains separately managed as described above.

The PG capability list advertises backup only when the archive directory, key, schema-39 marker, backup-pin schema and compatible pg_dump/pg_restore tools are ready. An allowlisted administrator can request Run encrypted backup in Settings. The worker exports a repeatable-read snapshot, pins referenced object bytes against garbage collection and the delete queue, then creates an authenticated encrypted archive containing the PostgreSQL dump, external object bytes, and required instance keys. The API returns safe job/archive metadata; paths and key material stay on the server. PostgreSQL exposes local backup sources and a shared backup-status summary. This status is not proof that an archive remains present or has passed a restore drill. PG off-host replication runs when valid S3 provider settings are configured; remote replica restore is advertised only when those settings, compatible tools, the archive/key paths and the separate empty restore target are ready.

Migrations 0036_instance_backup_replications.sql and
0037_instance_backup_replication_leases.sql store the shared replication
outbox and fenced-worker lease. With valid ATERMIUS_BACKUP_S3_* settings,
manual and scheduled backup jobs register the archive before taking the
snapshot and publish its exact byte count and digest after creation. The PG
worker claims due rows across serving nodes, renews a five-minute
database-clock lease while transferring, uses an increasing attempt generation
to reject stale writes, and retries retryable failures with bounded backoff.
Claim processing also reconciles pre-snapshot outbox rows after producer
termination: active queued/running backup jobs remain pending, complete
succeeded-job metadata becomes claimable, and failed/interrupted or incomplete
jobs record the fixed `archive_unavailable` outcome.
It conditionally writes only the deterministic encrypted archive key and
verifies the remote object byte count and SHA-256 before marking success.
Configure the same bucket, region, endpoint, prefix and credentials file on
every serving node; provider credentials remain node-local and never enter
PostgreSQL.

An authenticated instance administrator can read GET
/api/v1/admin/backup-replication. The PG route checks the live session, device
and administrator status in the same repeatable-read transaction as the shared
status snapshot. The Web Settings card reads this safe DTO; it exposes fixed
state/failure labels, timestamps, archive ID and size, but not bucket,
endpoint, region, prefix, or credentials. The archive volume and encryption
key must be shared across serving nodes so whichever node claims a row can
read the exact local archive. The focused PG/Chromium Settings acceptance passed
on 2026-10-12 using the loopback S3 fixture and verified byte-exact replication
from Node A as observed on Node B. At schema marker 39, PG lists only successful
replica objects whose outbox metadata exactly matches the succeeded backup job.
Settings can prepare and discard an isolated restore stage from that replica
when S3 configuration, backup/key paths, compatible tools and a separate empty
target are ready. The two-node acceptance removed the local archive before
restoring, then checked missing-object and same-length content-tampering
failures. This verifies the loopback S3-compatible path only; it does not
establish provider-cloud interoperability or live activation/cutover.

An allowlisted administrator uses `GET /api/v1/admin/backup-schedule`
and `PUT /api/v1/admin/backup-schedule` to read or set `interval_hours` from 1
to 720, or `null` to disable. With migration 0026 and schedule readiness,
Settings advertises the schedule capability even before backup storage is
configured; enabling without it returns `BACKUP_NOT_CONFIGURED`. Enabling
requires every node that may claim a scheduled job to share the private archive
directory, the 32-byte backup key, the PostgreSQL schema and external object
store, plus compatible `pg_dump`/`pg_restore` tools. A 30-second PostgreSQL-clock worker
atomically claims a due slot, queues a scheduled backup in the shared
`instance_admin_jobs` ledger and advances the next due time; missed intervals
coalesce. The ledger's one-active-job fence serializes scheduled work with
manual backup, restore and maintenance across nodes. Busy work leaves the due
slot unconsumed. Restart recovery marks unfinished runs interrupted without
replay. Schedule changes retain the authenticated administrator actor in the
audit trail; scheduled job lifecycle records use an explicit scheduler/system
origin, never a fabricated human actor. The exact dual-node acceptance covers
authorization, strict request bodies, audit rollback, due-slot contention,
single archive creation, source-catalog visibility, disable/last-run behavior,
and interruption without replay.

To enable restore, set `ATERMIUS_PG_RESTORE_TARGET_URL` to a different empty
database. The readiness check rejects the source database and requires the
target to have create privileges, no application schema, and no public
relations (including tables, views and sequences). The runtime application
schema must be a dedicated schema name;
`public`, PostgreSQL system schemas, and the reserved
`atermius_restore_control` name are rejected. The target must be reachable
with the service's normal PostgreSQL connection settings. Restore is
advertised only while this target is ready. An allowlisted administrator
selects a local server-generated archive in **Settings → Instance restore**.
The worker authenticates and validates the archive, restores it into that
database, places external object bytes into a private filesystem store below
`$ATERMIUS_BACKUP_ARCHIVE_DIR/restore-staging/atermius-pg-restore-<job-id>`,
rotates the restored instance generation, and revokes archived sessions. It
does not change the live database, object store, sessions, or generation. A
completed restore makes the configured target nonempty. Before another restore,
discard the previous stage and verify the target is empty, or configure a new
isolated empty target.

New backups from schema 29 record marker 29. The restore verifier accepts
archive markers 25 through 29.
After restoring the dump into the isolated empty target, the worker confirms
that the restored schema marker matches the authenticated archive manifest,
then applies only release-bundled static migrations needed to reach schema
29: marker 25 applies 0026, 0027, 0028 and 0029; marker 26 applies 0027, 0028
and 0029; marker 27 applies 0028 and 0029; marker 28 applies 0029; marker 29
needs no upgrade. It verifies the complete schema-29 readiness contract
before marking the restore stage ready. It never
executes SQL supplied by an archive or migrates the live source database as
part of restore. Migration failure leaves the restored
target populated and unsuitable for retry; provision a new empty target before
another attempt. The opt-in `test_pg_marker25_encrypted_archive_full_restore_acceptance`
fixture exercises an actual marker-25 PostgreSQL custom dump and authenticated
XChaCha-encrypted archive through the production admin-job worker. When
The 2026-10-10 validation passed: the archive reached marker 28; the test
checked the target marker/default schedule, restored object bytes and new store
binding, session revocation, stage receipt/job digest, and unchanged live-source
generation, signing key and session/object counts. The Settings discard then
removed the application schema, stage files and target-side marker, recorded
one audit event, retained the target database, and returned the same receipt on
cross-node idempotent retries. The source archive and live database remained
unchanged. The fixture uses disposable databases. The separate offline
activation/cutover path and its scope are documented below; this worker test
does not establish replication, production failover or general PG parity.

The complementary `test_pg_http_v25_encrypted_restore_settings_stage_acceptance`
case in `integration/test_pg_sync_http_acceptance.py` exercises the historical
marker-25 archive from Settings against two PG17 nodes. It passed **1/1 in
68.28s** on Web Release SHA-256
`bfc6c80b5e30abc15b4cab51fee5714211a0d3cff6218582946199bbbff57d54`. It covers
anonymous and non-admin denial, one authenticated submission, cross-node job
visibility, Prepared/Stage ID persistence, owner-authorized discard, target
cleanup, audit and preservation of the source archive/live database. The full
two-node PG HTTP module passed **68/68 in 901.84s**. Run it with the opt-in PG
HTTP acceptance fixture, Chromium, and a fresh isolated empty restore target.
After a successful restore/discard cycle, the configured target database
remains in place and is empty of the staged application/control schemas; check
that it is otherwise suitable before reusing it as a fresh restore target.

### Discard a PostgreSQL isolated restore stage

After reviewing a ready stage, its original requesting user can discard it in
**Settings → Instance jobs → Discard isolated copy**, while that user is still
an active instance administrator. Another administrator cannot discard that
job. A restore job that was interrupted after its durable stage became ready
can also be discarded. The API is
`POST /api/v1/admin/restore-stages/{restore_job_id}/discard` and requires the
exact body `{"request_id":"<canonical-lowercase-uuid>"}`. The server derives
the archive, target, application schema and stage directory from the durable
job; the client cannot choose a database, schema, path or object-store ID.

Only stages created with the 0028 target binding can be safely discarded.
Stages created before that migration have no durable binding and fail closed;
this endpoint will not infer their target or delete them. For a bound stage,
the shared job ledger and target database both hold its random binding. The
target marker lives in the reserved
`atermius_restore_control.stage_binding` table and records the job/archive
identity and digest, generation, schema, target URL fingerprint, database name
and OID, and staged object-store identity/count. Before deleting anything, the
service validates that marker against the job, validates the restored schema's
marker, generation and object-store references, and validates the exact
job-derived private stage directory and object inventory. An absent or changed
configured target, a recreated database, unexpected non-system schemas or
public relations, a missing or tampered marker, dependent application objects,
unknown stage files, or any other mismatch stops cleanup and preserves the
untrusted contents. Keep the original target URL and the private
archive/staging directory available until discard completes.

Cleanup runs in two phases while a target-side advisory lock prevents a second
node from racing it. First the service removes only the bound application
schema and stage object files, and commits that removal while retaining the
target marker. It then records the durable discarded lifecycle and one
`admin.restore_stage_discarded` audit event with the requesting administrator
and device identity, removes the marker, and records target-cleanup completion
in the shared ledger. If a process or node stops mid-cleanup, the original
owner can retry **Retry discard**. The worker also retries unfinished
`discarding` or partially finalized `discarded` stages
after the durable retry time; failures use exponential backoff from 30 seconds
up to one hour. When fully complete, replay returns the same durable discard
timestamp without adding another audit event. The retry is lifecycle-based;
`request_id` is validated as a canonical UUID but is not the durable
idempotency key.

Discard capability requires the shared schema, configured target URL and
private archive/staging directory. It does not require the backup encryption
key or `pg_dump`/`pg_restore`, so it remains available when those tools or the
key have been removed after staging. It deletes the isolated application
schema and staged object files plus the target marker; it retains the target
database itself. It does not modify the source archive, live database, active
object store, live sessions or live generation. This lifecycle remains
isolated from online requests. A separate offline Compose coordinator now
coordinates the PostgreSQL URL, object-store root, instance signing/rate-limit
key files, service health and target activation marker. The coordinator's
tested scope and production limits follow.

### Offline PostgreSQL Compose cutover

This procedure supports one server container created with exactly these
Compose files, in order: `compose.yaml`, `compose.backup.yaml`,
`compose.object-store-filesystem.yaml`, and `compose.postgres.yaml`. It refuses
a running service created with additional overlays, including Caddy, MFA,
push, monitoring or other overlays. Do not apply it to HA or multi-node server
deployments. See the deployment guide for key provisioning and Compose
configuration. Run the coordinator on the Docker host using a local Unix-socket
context; it rejects remote contexts and `DOCKER_HOST` values that are remote
or differ from that selected local socket because receipt, key and bind-source
checks run on the coordinator host.

Before cutover, complete all of the following:

1. Create and test a verified encrypted backup, and complete the Web Settings
   restore into an isolated stage. Review the stage receipt and copy its
   canonical restore job UUID.
2. Provision a third PostgreSQL database for the post-cutover restore target.
   The source, prepared stage and next target URLs must name three distinct
   databases. Using a protected PostgreSQL administration client, verify the
   next target has no application schema or user relations in `public`, and
   that the service role can create its schema and objects. The coordinator
   checks URL distinctness only; it does not connect to the next target or
   prove that it is empty.
3. Confirm the restored filesystem object tree exists under the private backup
   mount at `restore-staging/atermius-pg-restore-<job-id>/object-store` and the
   stage has only the expected receipt, object-store directory and two
   restored PostgreSQL key files. The coordinator validates the exact stage
   inventory and file ownership/modes.
4. Drain the browser/API ingress outside this tool. Stop every other Atermius
   node, PG-backed worker, migration process, scheduler, importer, and other
   process that can write to the source, stage or next database. Confirm all
   old application connections and scheduled writes have stopped. The
   coordinator requires the operator's explicit ingress-drained and
   all-PG-writers-stopped confirmations; it cannot independently enforce
   those conditions or control ingress.
5. Keep the source database, original object-store volume, source key files,
   encrypted archive, archive key, staged object tree and protected
   `deploy/.env` backup. The coordinator retains a mode-0600 original `.env`
   in `deploy/.pg-restore-cutover`; it contains source database credentials.
   This state directory is mode 0700 and must be protected as sensitive
   operator state.

From the repository root, run `apply` with the UUID from Settings:

```sh
python3 deploy/pg_restore_cutover.py apply --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
python3 deploy/pg_restore_cutover.py status --job-id <restore-job-uuid>
```

The coordinator validates `.env`, the prepared receipt, the exact Compose file
list, the live container's PG environment and critical mounts, and the health
identity of the running source. It writes a private journal before stopping
the `server` service; it does not stop the database, ingress, or proxy. It
switches the service PG URL to the staged database and changes the object
store root and restored key-file paths as one `.env` update. It then waits for
readiness, verifies that instance ID, server-space ID and signing public key
match the source while the generation matches the stage receipt and differs
from the source, and records activation against the stage's target-bound
receipt.

The PostgreSQL target marker serializes activation and rollback fencing under
the same advisory lock. If a pre-activation step fails, the coordinator
persists a rollback fence on the stage before pointing the service back to the
source; a later activation attempt against that stage then fails closed. The
restore-next URL is installed for a future restore. `recover` resumes either
the recorded rollback or an activation whose result may have committed before
a process stopped:

```sh
python3 deploy/pg_restore_cutover.py recover --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
```

`rollback` is for a stage that has not been activated:

```sh
python3 deploy/pg_restore_cutover.py rollback --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
```

An activated stage cannot be rolled back. If an activation marker exists while
the local coordinator journal still says `stage_verified`, rollback refuses,
restarts the stage when possible, and moves the journal to
`activation_uncertain`; `recover` then retries activation idempotently. Do
not call the server's `fence-pg-restore-stage-rollback` or
`activate-pg-restore-stage` CLI commands outside the coordinator.

After cutover, the tool leaves external ingress drained. Verify the live
service and application data using the operator's checks, then change ingress
outside this tool. After any client or background writer reaches the promoted
database, the source may diverge. Keep source database/object-store data and
keys for forensic recovery; do not use the pre-activation rollback command as
a failback. Plan failback as a new restore and separately reviewed cutover.
The coordinator does not delete databases, volumes, archives, stage files or
keys.

The present acceptance includes **29/29** mocked cutover tests, a real local-context
Compose render with all six critical mounts, and a PostgreSQL 17.11 test of full encrypted marker-25 restore, activation,
idempotent activation, target rollback fence, activated-stage discard
rejection and source-data preservation. The locked serial Rust suite passed
**304 library / 76 ignored and 7 binary tests**, plus migration, OpenAPI,
WebSocket and doc targets; formatting and server build passed. It does not prove a live Docker
Compose switch, production ingress, next-target readiness, extra Compose
overlays, replication, failover/HA or general PostgreSQL parity.

## What the archive records

The archive contains the SQLite database, the instance Ed25519 private key,
and the authentication rate-limit key. SQLite currently stores opaque object
payloads in the database, so the database snapshot includes those payloads and
their metadata. The archive is encrypted with the separate 32-byte operator
backup key. Store the archive and that key separately from the live data
directory, and keep an offline copy of the key.

The optional mobile push endpoint envelope derives separate encryption and
fingerprint keys from `auth-rate-limit.key`. This file is shared with other
server features; it is not a push-only rotation key. Preserve and restore it
with the exact SQLite database. If the database and key do not match, push
token decryption fails closed and delivery is parked. Restore the matching
archive/key pair, or after a future push sender is configured, have devices
register their provider tokens again. Review any overall auth-rate key change
as a separate server-key operation.

The archive does **not** contain the optional TOTP MFA seed-encryption key.
When MFA is enabled, SQLite contains encrypted TOTP seed envelopes and salted
recovery-code hashes, so keep an independent protected copy of the exact
32-byte `ATERMIUS_MFA_ENCRYPTION_KEY_FILE` value. Keep it separate from both
the instance archive and the archive-encryption key.
For a deliberate MFA key change, use the offline
[MFA seed-key rotation runbook](mfa-seed-key-rotation.md). Keep the key that
matches each retained backup; a backup made before key rotation still needs
the old key.

The encrypted manifest records the policy version and effective values for
registration, Relay enablement and allowlists, authentication limits, admin
usernames, public origin, Web asset directory, object/request limits, history
retention, deletion grace periods, audit retention, and object-GC grace.
`ATERMIUS_DATA_DIR` and the listener bind address are deployment-specific and
are supplied by the restore environment. The manifest does not contain
credentials such as the backup key.

## Create an archive

Stop is not required for SQLite backup. Use a new archive path and an existing
private key file containing exactly 32 bytes:

```sh
atermius-server backup \
  --archive /secure/offline-path/instance.atb \
  --key-file /secure/key-store/atermius-backup.key
```

The command refuses to replace an existing archive. Copy the finished archive
off the instance host and verify that the recovery key can be retrieved from
its separate storage location.

An allowlisted instance administrator can also request the fixed `backup`
action from **Settings → Instance jobs**. The durable job worker uses the same
SQLite snapshot and encrypted archive implementation as the CLI, with a
server-generated filename in the configured archive directory. One backup or
maintenance job may be active at a time. The API and UI expose only job state
and fixed result categories; they do not return host paths, key bytes, or
internal failure details. If either backup setting is absent or invalid, the
request fails with `BACKUP_NOT_CONFIGURED` and creates no job.

Server-triggered backup is disabled unless both `ATERMIUS_BACKUP_ARCHIVE_DIR`
and `ATERMIUS_BACKUP_KEY_FILE` are configured. For Compose deployments, use
the opt-in [`compose.backup.yaml`](../../deploy/compose.backup.yaml) overlay as
described in the deployment guide. The archive directory and 32-byte operator
key file must be owner-only and outside `ATERMIUS_DATA_DIR`; the configured
archive directory must have sufficient free space. A successful job creates a
local encrypted archive but does not upload or restore it. Local archive
retention is optional: set `ATERMIUS_BACKUP_RETENTION_COUNT` to an integer from
1 through 1000 in the Compose `.env` file to enable it. Leave the variable
unset to disable pruning. An explicitly empty or malformed value is invalid;
the server fails closed at startup rather than silently disabling the policy.

The setting requires the same valid archive-directory and key-file
configuration as server-triggered backup, so enable it only with the backup
overlay. Hourly maintenance retains the newest configured count of eligible
server-triggered archives in that private archive directory. An archive is
eligible only when it is a regular file with a server-generated name tied to a
durable backup-job ID. On Unix, it must also be owned by the service user,
have mode 0600, and have a single hard link. The policy does not remove
CLI-created archives, symlinks, directories, or unrecognized files.
Maintenance and backup creation share a lock and cannot overlap. Because
pruning runs during maintenance, the eligible archive count can temporarily
exceed the configured count between a backup and the next maintenance pass.

This policy only prunes local eligible archives; it does not copy them to
separate storage. Choose an off-host copy schedule and retention policy
accordingly, and periodically use `verify-backup` and the isolated restore
procedure below.

An allowlisted administrator can enable a durable schedule in **Settings →
Instance backup schedule** once the private backup directory and key are
configured. Set an interval from 1 through 720 hours; leave the schedule
disabled when manual backups are preferred. The admin API exposes only whether
the private configuration validates, the interval, next due time, and fixed
metadata for the most recent scheduled run. Schedule updates serialize with
backup/maintenance operations. A due occurrence and its next due time are
committed before archive creation. If the process stops during an occurrence,
the run is marked `interrupted` at startup and is not replayed; the following
interval remains scheduled. Scheduled run IDs are included among eligible
server archives for the optional retention policy.

The schedule and run records live in the instance SQLite database and are
therefore part of encrypted instance archives. Restoring an enabled schedule
requires the restored service to have valid private `ATERMIUS_BACKUP_ARCHIVE_DIR`
and `ATERMIUS_BACKUP_KEY_FILE` settings before it starts; startup fails closed
when those settings are unavailable. The local `backup-status.json` sidecar is
not included in archives, while durable schedule/run records are.

## Replicate and restore from an S3-compatible target

The replica restore workflow is supported by SQLite and by the restricted PostgreSQL runtime at schema marker 39. PostgreSQL uses the shared S3 upload and Settings status described above, then exposes only replicas whose outbox row matches the exact successful backup job. The existing Settings flow prepares and discards the replica restore as an isolated stage; it does not activate or replace live data. All PG serving nodes need the shared private archive volume and matching S3 configuration, while the isolated restore target remains separately configured.

Follow the [S3 replication deployment guide](../../deploy/README.md#replicate-encrypted-archives-to-s3-compatible-storage)
to mount the private credentials JSON and configure one bucket, region, optional
HTTPS endpoint and optional prefix. The server reads credentials from that
owner-only file with an explicit static credential provider. Administrator
requests cannot select a target or supply remote paths. Replication copies only
the already encrypted `.atb` file and uses the stable key
`<prefix>/atermius/v1/<instance-id>/<archive-id>.atb`.

An instance administrator can use **Settings → Backup replication → Check bucket access**
to run a bounded `HeadBucket` request against the server-configured target. The
request accepts no endpoint, bucket, or credentials from the client. A passing
result verifies bucket access only; it does not verify object uploads,
multipart operations, restores, or broad provider compatibility. Missing or
invalid server configuration and provider failures return fixed, generic
results without provider diagnostics.

An allowlisted administrator can review **Settings → Backup replication** and
select a `replica` row from **Settings → Instance restore**. The catalog entry
means the service previously completed and verified that copy; it is not a
promise that an operator or provider has not since removed it. SQLite checks
its successful local outbox row; PostgreSQL checks the shared successful
outbox entry against the exact successful backup job, including archive ID,
origin, byte count and SHA-256. Replica job acceptance checks that metadata and
the configured target but does not make a network request. The restore worker rechecks `HeadObject`,
downloads the exact deterministic key to a new mode-0600
file in the private restore staging area, verifies its expected length and
SHA-256, authenticates the encrypted archive with the separately mounted
backup key, then stages the database into the job's isolated directory. The
remote bucket, endpoint and key are never accepted from the request. If the
worker cannot find, authenticate, or safely download the selected replica,
the durable job ends with the fixed `restore_failed` result and does not touch
live data. The result does not expose provider errors or remote details. Missing
or unconfigured outbox metadata is rejected before job acceptance with
`RESTORE_SOURCE_UNAVAILABLE`.

The outbox is written before the archive snapshot. It durably records archive
ID, origin, size/hash when available, upload attempt state, retry time, failure
category and multipart upload ID. Upload failures do not fail an archive job
that already created its local archive. Restart marks active replication as
interrupted, then reconciles the deterministic object key: an existing copy is
downloaded and fully verified; an absent copy is uploaded from the protected
local archive. A conditional-write conflict is accepted only after the server
downloads and validates the existing object. Different bytes are never
overwritten. Retryable remote failures use bounded backoff. Fixed categories
are `archive_unavailable`, `credentials_invalid`, `remote_unavailable`,
`remote_integrity_mismatch`, and `replication_failed`; raw provider messages
and credentials are never returned.

Local retention never removes an archive while its replication is waiting,
running, interrupted or terminally unsuccessful. Thus the retained local
count can exceed its configured number while a copy needs operator attention.
The service does not delete completed remote objects. Configure a provider
lifecycle rule to abort incomplete multipart uploads after one day as a fallback
for a crash immediately after upload creation; the worker also lists and aborts
incomplete uploads for a retried archive key. A completed remote object can
only be deleted by operator/provider policy, after which its catalog entry will
fail validation when selected for restore.

## Review the last local backup attempt

An authenticated instance administrator on the `ATERMIUS_ADMIN_USERNAMES`
allowlist can open **Settings → Instance backup status** to view the latest
`backup` CLI or server-triggered job result recorded for this data directory. The private
`backup-status.json` sidecar records the latest attempt time and fixed success
or failure result, migration version, encrypted archive byte count, and the
fixed `backup_failed` category. Schema v2 also retains the timestamp of the
last successful local archive creation across later failed attempts; legacy
successful v1 attempts seed that timestamp from their attempt time, while a
legacy failed attempt does not imply an earlier success. The sidecar contains
no archive/key paths, key bytes, runtime policy values, or error text. It is
not included in instance archives, so a restored data directory starts with
no local attempt or success history.

This panel reports the latest local sidecar value. Writing that value is
best-effort after archive creation; if the archive was created but the sidecar
could not be updated, use the durable admin job row as the execution result.
Neither view proves that an archive copied off-host still exists, matches the
reported size, or can be restored. `verify-backup` does not change the status.
Continue to verify retained archives and perform isolated restore drills.
Argument parsing or default database URL validation failures happen before a
backup attempt is recorded.

The protected Prometheus metrics endpoint exports the unlabeled
`atermius_backup_last_success_timestamp_seconds` gauge from this sidecar. It is
zero when no local success is recorded, including immediately after restore;
it reports only the recorded local archive creation and does not measure
off-host replication or restore success.

## Prepare an isolated restore from Settings

An allowlisted administrator can prepare a restore copy while the service
continues to serve the current data directory. In **Settings → Instance
restore**, select an available server-generated archive by its creation time,
size, and origin, then confirm the action. The catalog contains only archives
created by an admin backup or scheduled backup job; CLI-created archives remain
available to the offline CLI workflow. The API accepts an archive ID, never a
filesystem path or key.

The restore job verifies the archive and prepares a new private directory at
`$ATERMIUS_BACKUP_ARCHIVE_DIR/restore-staging/atermius-restore-<job-id>`. The job
ID is shown as the stage ID in Settings. The API does not return the target
path. The server holds the same maintenance lock used by backup creation and
retention while it prepares the copy, so these fixed operations do not overlap.
It does not stop the service, change `ATERMIUS_DATA_DIR`, change a Compose
volume, or activate the target. The active data directory is not replaced. The
live database records the durable restore job and its admin-audit events; the
operation does not change active account, Vault, session, or generation data.
The selected source archive is read-only during staging. The staged database
uses the current migration code, receives a new generation, and has archived
sessions revoked. This online workflow requires the archived runtime policy to
match the current effective configuration. For reviewed policy drift, use the
offline CLI procedure below.

### Discard an isolated stage

After reviewing a completed restore stage, the original job owner can use
**Settings → Instance jobs → Discard isolated copy**. The confirmation explains
that the service first validates the server-created receipt and exact private
stage contents. Cancel sends no request. Only an instance administrator who
created that restore job can see or invoke the action; another administrator
does not receive actionable stage state.

The API route is
`POST /api/v1/admin/restore-stages/{restore_job_id}/discard` with the exact
body `{"request_id":"<canonical-lowercase-uuid>"}`. The server derives the
target under `restore-staging` from the durable restore job; clients cannot
submit a path. Before deleting, the server verifies the job/archive identity,
source, archive digest, receipt, generation, SQLite integrity and migration
state, both private keys, directory/file permissions, and the exact allowlisted
entries: `.atermius-restore-receipt.json`, `atermius.db`,
`auth-rate-limit.key`, and `instance-ed25519.key`. A pre-existing SQLite
WAL/SHM sidecar or any other unknown entry makes the operation fail closed and
remain untouched. The isolated payload files are removed before the receipt;
the service syncs each directory boundary and removes the now-empty stage.

The durable lifecycle appears as prepared, cleanup pending, discarded, or
unverified for the original job owner. If deletion or final database commit is
interrupted, retry **Retry discard**; after a process restart the service also
tries to finish a validated `discarding` stage. If startup cannot acquire the
maintenance lock or the backup mount is unavailable, it defers cleanup and
keeps the job retryable. An unverified legacy stage is fully revalidated before
any deletion. A successful discard returns the same durable completion receipt
on retry and writes exactly one `admin.restore_stage_discarded` audit event
with the requesting administrator/device identity and an HMAC job resource.
This operation removes only the isolated copy: it does not change the source
archive, current data directory, live generation, sessions or business records,
and it does not perform restore activation or cutover.

Before cutover, confirm the completed job in Settings and keep the current
live data directory as the rollback point. For the standard Compose deployment,
use the journaled coordinator below; it installs into a distinct named volume,
updates all data settings together, and owns the source checkpoint and service
restart sequence. Keep both volumes until the restored instance passes
application checks. If the source archive must remain available after local
retention runs, copy it off-host and verify that copy. Use the direct offline
installer only when deliberately managing the service and data-directory
switch yourself; do not combine a manual install with the Compose coordinator.

Verify readiness, sign in with a fresh session, unlock a test account, inspect
a known Vault record, and read a known object before restoring normal traffic.
Online no-replace stage publication currently requires a Linux server; on other server operating systems the job fails closed without changing the active data directory. If restart cannot validate the optional backup configuration or the stage receipt, SQLite database, or private key files, the durable job becomes interrupted, the stage is left untouched, and the live service still starts. Do not point the live service at an interrupted stage.

The stage has a new server generation and revoked archived sessions; clients
must obtain fresh sessions and coordinate their snapshots. Keep the old data
directory as the rollback point until these checks pass. Rollback means stop
the service and restore the prior `ATERMIUS_DATA_DIR` and database URL; the
online preparation step never modifies that prior directory.

## Install a Web-prepared stage into a new volume

`install-restore-stage` copies a completed Web stage into a new data directory
on Linux. It does not call the Web API, start or stop the service, change a
Compose mount, or switch traffic. The source data volume and the published
stage remain available for rollback and review.

First confirm in Settings that the Web restore job is `succeeded` and its
stage is `ready`. The standard Compose path is the coordinator in the next
section; it stops the server and runs this installer itself. Use the direct
offline command below only when you are managing the service and volume
transition manually. Do not install the stage first and then run the
coordinator, because the coordinator requires a new target volume with no
`/restored` directory. For a direct install, stop the server cleanly and run
the installer with the same runtime policy and backup configuration that were
in effect when the stage was prepared. The process must be able to read the source
`ATERMIUS_DATA_DIR`, the configured backup archive/key, and a pre-existing
owner-only `server.lock`; that lock must be unlocked.

After the server has stopped, checkpoint the source database so the durable
ready-job record is in the main database. The server may leave WAL data when
it stops; the installer does not checkpoint or modify the source. In an
offline maintenance window, with the source volume temporarily writable and
no server process running, run a SQLite checkpoint, for example:

```sh
sqlite3 "$ATERMIUS_DATA_DIR/atermius.db" 'PRAGMA wal_checkpoint(TRUNCATE);'
```

After the SQLite command exits, confirm the checkpoint reports `busy=0` and
that all three paths `atermius.db-wal`, `atermius.db-shm`, and
`atermius.db-journal` are absent. Even a zero-byte sidecar is rejected. Then
mount the source read-only for the installer. If any sidecar remains, do not
run the install command; finish the offline database close/checkpoint and
verify the sidecars are gone. After confirming no server or SQLite process has
the database open, an empty `-wal` or stale `-shm` may be removed as part of
that offline cleanup. Never remove a nonempty WAL or rollback journal; let
SQLite recover/checkpoint it first.

If the command reports `RESTORE_PUBLISHED_DURABILITY_UNCERTAIN`, the
no-replace publication already succeeded but syncing the target parent
directory failed. The target may already exist; inspect it before retrying and
do not assume a failed command left the destination absent.
The new target parent must already exist, be privately
controlled, and be on the destination volume; the final `data` directory must
not exist. For the installer process, mount the source data directory and the
archive/key inputs read-only, and mount the destination volume read-write.

```sh
atermius-server install-restore-stage \
  --restore-job-id 01234567-89ab-cdef-0123-456789abcdef \
  --target-data-dir /new-volume/data \
  --server-stopped
```

The installer binds the canonical job ID to its durable completed job row,
archive ID/source/digest, ready-stage generation, receipt, and SQLite
`instance_meta.generation`. It verifies database integrity, foreign keys,
current schema, both private key files, exact file allowlists, and private
permissions before and after copying. The destination is assembled in a
private temporary directory on the target volume, synced, rechecked, then
published with a no-replace directory rename. Existing targets, symlinks,
unknown files, SQLite WAL/SHM/journal files, missing lock files, locked
servers, and config/policy drift fail closed. The installer opens the source
lock read-only and never creates or chmods it. Its success message confirms
the new generation; it does not perform activation.

The receipt binds the stage to a SHA-256 of the complete canonical runtime
policy summary. A stage prepared under another effective policy is rejected;
restore it only after aligning the runtime configuration and preparing a new
stage. Legacy ready stages whose receipts lack this fingerprint remain
readable for review and discard but cannot be installed; prepare a fresh stage
instead. If the hidden temporary directory remains after a host crash, inspect
it before cleanup and do not treat it as an installed data directory.

After installation, use the host-side Compose cutover coordinator below. It
updates the selected named volume, `ATERMIUS_DATA_DIR`, and
`ATERMIUS_DATABASE_URL` together, and records the previous values before it
restarts the service. Do not remove or overwrite the old volume. The installer
and coordinator leave both named volumes available for rollback.

### Apply and roll back a Web-prepared stage with Compose

Run the coordinator from the project checkout on the Linux host that owns the
Docker Compose project. It requires Python 3, the Docker Compose plugin, and a
local Docker named volume using the `local` driver. The operator account must
be able to lock and checkpoint the service-owned source files and update the
deployment `.env`; root is normally required with the UID 10001 volume. The
health URL must reach this service on the local host. Create a private,
persistent journal directory first; the journal is mode 0600 and supports
status, interrupted-operation reconciliation, and explicit rollback.

```sh
install -d -m 700 /var/lib/atermius
python3 deploy/restore_cutover.py apply \
  --project-name atermius \
  --env-file deploy/.env \
  --compose-file deploy/compose.yaml \
  --restore-job-id 01234567-89ab-cdef-0123-456789abcdef \
  --target-volume atermius-data-restored-20261007 \
  --health-url http://127.0.0.1:8080 \
  --journal /var/lib/atermius/restore-cutover.json
```

Replace the example project, job ID, and target volume with the values for the
deployment. In particular, use the exact Compose project name that owns the
source volume. The target volume must differ from the source, and its
`/restored` path must not exist. The installer creates that directory and
preserves unrelated files already in the target volume. The coordinator
resolves the exact local source volume mountpoint, verifies its owner-only
layout and unlocked `server.lock`, runs `PRAGMA wal_checkpoint(TRUNCATE)` and
`integrity_check`, then confirms all SQLite WAL, SHM, and rollback-journal
sidecars are absent. It installs the ready stage, writes the target volume and
both data path settings to the env
file, and starts the standard Compose service. It accepts the cutover only
when `/health/ready` succeeds, the instance and server-space IDs match the
source, and the generation has changed. A failed startup or identity check
restores the recorded env values and starts the source service again. The
checkpoint verifies and flushes the source SQLite state without deleting either
volume or changing logical records. The coordinator fails closed if the local
volume mountpoint, lock, database, checkpoint, integrity check, or sidecar
verification cannot be proven; remote Docker contexts and non-local volume
drivers are outside this workflow.

Inspect the durable operation state with:

```sh
python3 deploy/restore_cutover.py status \
  --journal /var/lib/atermius/restore-cutover.json
```

After a committed apply, sign in with a fresh session, unlock a test account
(including the separately mounted MFA seed-encryption key when enabled), read a
known Vault record, and download a known object before returning normal
traffic. Old sessions are rejected because restore rotates the server
generation. If these application-level checks fail, explicitly roll back:

```sh
python3 deploy/restore_cutover.py rollback \
  --journal /var/lib/atermius/restore-cutover.json
```

The coordinator does not delete either named volume. Keep both until the
restored instance passes application checks and a fresh off-host backup is
verified. Preserve the private journal with the recovery record. This workflow
coordinates the local Compose service; it does not update an external TLS
proxy or prove production traffic routing. The offline
`atermius-server restore --server-stopped` command remains available for
operator-supplied archives and explicitly chosen data directories.

The offline `atermius-server restore --server-stopped` command remains the
workflow for operator-supplied archives, policy-drift review, and environments
where the staged directory must be chosen explicitly. Do not use the Web job
as a live cutover control.

## Verify an archive

Run the non-destructive verifier against a retained archive before relying on
it or before beginning a restore drill. The verifier authenticates the
manifest and every encrypted chunk, checks file digests, SQLite integrity and
foreign keys, validates the archived 32-byte service keys, and confirms that
the archived migration version matches the database and is supported by this
server. It does not open or migrate the
active database, change instance generation, revoke sessions, or publish a
restore directory. It briefly extracts authenticated files into a private
temporary directory and removes that directory on normal success and error
paths. Keep the archive and key outside `ATERMIUS_DATA_DIR` and preserve the
owner-only permissions required by the backup tools.

The service may remain online while verification runs because the verifier
only reads the archive and the private backup key. Use the same separate key
path used to create the archive:

```sh
atermius-server verify-backup \
  --archive /secure/offline-path/instance.atb \
  --key-file /secure/key-store/atermius-backup.key
```

The archive and key must be owner-only regular files; special files such as
FIFOs are rejected without blocking. Success prints only the number of archived
files and the database migration version. A wrong key, altered or incomplete
archive, unsupported schema, or SQLite integrity failure returns a nonzero exit. Verification is a useful
archive check, but it does not replace an isolated restore rehearsal and a
post-restore login/read test.

## Restore with matching policy

Restore requires the original instance data directory to exist and the server
to be stopped. The destination must be a new directory outside the active
data directory, with an existing parent directory. The command verifies the
archive, stages files privately, migrates and checks the database, revokes
restored sessions, changes `server_generation`, then publishes the destination
without replacing an existing target.

```sh
atermius-server restore \
  --archive /secure/offline-path/instance.atb \
  --key-file /secure/key-store/atermius-backup.key \
  --target-data-dir /var/lib/atermius-restored \
  --server-stopped
```

The restore process compares the archived runtime policy with the effective
configuration in its environment before publishing. If they differ, restore
fails with `RUNTIME_POLICY_DRIFT` and lists only the differing field names; it
does not print configured values. Align the target environment with the
intended policy and retry.

Before starting the restored service, restore the exact MFA key file with
owner-only permissions and configure `ATERMIUS_MFA_ENCRYPTION_KEY_FILE` (for
Compose, use `compose.mfa.yaml` and the documented host directory). A missing
setting does not prevent startup, but TOTP verification and setup return
`503 MFA_KEY_UNAVAILABLE`; password login still issues the factor challenge
and, during normal operation, an unused recovery code can complete it. A
configured missing, malformed, symlinked, or non-private key fails startup
closed. If the original key is
lost, enrolled seeds cannot be recovered: users can sign in with unused
recovery codes, then must use account Recovery or another supported recovery
path before reenrolling. Key rotation is not supported.

Restore keeps enrolled TOTP enabled but deliberately invalidates MFA state
captured in the archive: pending enrollments and login challenges are deleted,
all archived unused MFA recovery codes are consumed, and each enabled seed's
last accepted step is advanced to the current 30-second step. This prevents a
database rollback from reactivating saved recovery codes or replaying a recent
TOTP step. After restoring the original MFA key, users should wait for the
next TOTP step to sign in, then rotate their recovery codes. Because restore
consumes the archived codes, if the original TOTP key is unavailable, full
cryptographic account Recovery is the fallback; the separate MFA recovery
codes are not a substitute.

An enabled scheduled-backup cadence and its run history are part of the
encrypted database snapshot. A schedule archive is captured while its own run
is still `running`; when a restored instance starts, startup recovery changes
that occurrence to `interrupted`, keeps the archived `next_run_at`, and does
not replay the claimed occurrence. It will create an archive only when that
preserved next due time arrives.

## Explicitly accept policy drift

Use `--accept-runtime-policy-drift` only after reviewing the named differences
and confirming that the target environment is the policy you intend to run.
This option changes no environment values; the restored service uses the
configuration supplied when it is started. The command prints the accepted
field names, without values, so the operator can record the exception.

```sh
atermius-server restore \
  --archive /secure/offline-path/instance.atb \
  --key-file /secure/key-store/atermius-backup.key \
  --target-data-dir /var/lib/atermius-restored \
  --server-stopped \
  --accept-runtime-policy-drift
```

Archives made before the runtime-policy version was added are treated as
incomplete and fail closed by default. Review the target configuration against
the source deployment records before using the explicit override. An archive
with an unsupported newer policy version remains rejected; the override does
not permit interpreting an unknown policy schema. Unknown manifest fields
remain invalid.

## Compose named-volume restore rehearsal

Run the real container/volume acceptance from the repository root before
relying on a self-hosted backup, after server migrations, and periodically
thereafter:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q integration/test_compose_backup_restore.py
```

By default, the test builds the current `deploy/compose.yaml` image. It creates
a unique Compose project, source and restore named volumes, loopback port,
archive/key host directories, and test account. It writes opaque Vault record
and object bytes, creates an encrypted archive, force-recreates the source
container, and verifies the source volume still serves the original session
and data.

Before switching volumes, the acceptance corrupts an archive copy and runs the
offline restore while the source service is stopped, as required by the CLI.
The restore must fail without publishing `/data/restored` or changing a
canary in the target volume. The source service is then restarted on its
original volume. The test verifies readiness, the original session and
generation, and the byte-identical opaque Host envelope and object before any
successful restore.

The acceptance then restores the valid archive into the separate target volume
and starts a new container on `/data/restored`. It checks preserved instance
and server-space identity, a changed generation, rejection of old access and
refresh sessions, fresh login, and byte-identical opaque Host envelope and
object payload. After stopping the restored service, it selects the original
source volume again, restarts that service, and verifies the original session,
generation, Vault envelope, and object bytes still work. Cleanup tears down
the isolated project, removes only its two exact generated volume names, and
checks that both names are absent.

The cutover acceptance keeps both named volumes through readiness, identity,
fresh-login, Vault-record, and object checks. It also injects a readiness
failure to exercise automatic source rollback. The coordinator never deletes
the source or target volume; keep the source intact until the restored
instance is accepted.

When a current compatible image is already built locally, set
`ATERMIUS_COMPOSE_TEST_IMAGE` to its image tag to skip the image build while
running the same volume/restore flow:

```sh
ATERMIUS_COMPOSE_TEST_IMAGE=atermius-server:local \
  PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q integration/test_compose_backup_restore.py
```

This mode verifies the selected image; it does not prove that the current
checkout builds into that image. The default build mode is the source-build
check. The acceptance requires Docker Compose, permission to provision host
mounts owned by container UID 10001, and enough space in Docker's data root for
the Flutter and Rust build stages.

The 2026-10-02 rollback drill passed 1/1 in 81.55 seconds with the override
path. At the start, `/disk2` had 1.1 GB free, so this run did not validate a
fresh multi-stage Dockerfile build. Its temporary image used the existing
`aterm-final-deploy-20260928-server:latest` runtime base and replaced the
server binary with `server/target/debug/atermius-server` (SHA-256
`9d0557e0e7edbeea5d4fece9c1746a20614896f5e4de5d76e30fccc850c988f9`). No
server source or migration file was newer than that binary. It also copied
the Web bundle present at image creation (built 2026-10-02 12:44–12:45 UTC);
the later rebuilt Web bundle is not part of this API/volume test. The temporary
image, its context, exact Compose project and volumes, pytest data directory,
archive/key files, and generated test bytecode were removed. This result
verifies backup, failed-restore preservation, target activation, and source
volume rollback with that binary and runtime base; it does not verify the
current checkout's complete production Docker build.

The 2026-10-02 current-bundle rerun also passed **1/1 in 80.39 seconds** with the same prebuilt-image override pattern. It used a temporary image from the existing `aterm-final-deploy-20260928-server:latest` runtime, replaced the server executable with the current debug binary (the same SHA-256 above), and copied the current Web release bundle (rebuilt at 2026-10-02 13:13 UTC). Thus the Compose restore/rollback acceptance then covered the latest Web artifact in the container, while the fresh multi-stage production Dockerfile build remained unverified at that time. The temporary tag/context and test-owned containers/volumes were removed. The Docker data root had 624 MiB free before this run and 210 MiB after. The temporary image, context, containers, and volumes were removed, but BuildKit retained this run’s private COPY cache records. An exact record-ID prune did not remove them, so no broader shared-cache prune was attempted. The low-space recommendation from that run was point-in-time; it was superseded by the isolated 2026-10-06 default-build acceptance below. No broader Docker cache/image prune was performed.

**Current-checkout source-build and rollback revalidation — 2026-10-06:** `env -u ATERMIUS_COMPOSE_TEST_IMAGE PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q integration/test_compose_backup_restore.py` passed **1/1 in 124.79 seconds** without an image override. The default multi-stage build produced local `linux/amd64` image `atermius-backup-f1d5ead6cbd84b0a8466-server:latest`, ID `sha256:b810db41e1fa0d6a188b4a77b6c3368550e2bc2ad57cced1dabe3c5e35cdd613`. Build-context manifest: 1,470 files / 32,622,129 bytes, SHA-256 `af31b64161a01f77a0a85afb7ddec3dbe61b336c9297b6f233516d79599ba40c`. The test covered corrupt-archive preservation, restore into the separate target volume, fresh login and old-session rejection, exact opaque record/object bytes, and source-volume rollback. Test project containers, exact generated volumes, and private pytest fixture directory were removed; the local image remains and has no registry digest because it was not pushed. This is a local source-build/isolated-volume rehearsal, not a live traffic cutover or production upgrade rollback. Keep activation and volume selection operator-controlled and offline as described above.

## After restore

Review the CLI result and the named data directory before changing the service's
`ATERMIUS_DATA_DIR`. Keep the old directory intact until the restored service
passes health checks and an account can log in and read a known Vault record
and object. Restored access and refresh sessions are revoked; users must log in
again. The new generation invalidates prior sync cursors, so clients must
perform snapshot recovery while retaining their local pending edits.

The archived instance identity is preserved. If the restored archive predates
an instance signing-key rotation already accepted by clients, those clients
will reject the older identity because its transition chain cannot prove a
backward rotation. Do not bypass that client check. This case requires an
operator-managed identity recovery procedure and is not yet automated; include
it in restore planning when choosing backup retention points.

Run a restore drill before relying on an archive, after server migrations, and
periodically thereafter. Record the archive timestamp, observed recovery point,
generation change, policy drift decision, and restore verification results.

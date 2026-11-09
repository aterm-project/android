# Offline attachment object-store migration

This runbook targets the SQLite instance catalogue and moves every completed encrypted attachment in the instance
catalogue between SQLite, the private filesystem backend, and S3-compatible
storage. It includes SQLite rows when the configured source is an external
backend, so legacy SQLite objects do not remain behind after an external-store
cutover. The API, object IDs, signed sync operations, and references do not
change.

The operation is offline. The server must remain stopped from the first
preflight through the final verification and configuration switch. The command
takes `server.lock` and the shared `maintenance.lock` before opening SQLite or
creating a destination filesystem identity marker. The explicit
`--server-stopped` flag is an operator acknowledgement; the locks enforce it.

## Preconditions

1. Make an encrypted instance backup and verify it. Backup hydration includes
   active filesystem/S3 attachment bytes, so this archive is the clean rollback
   point even when the live catalogue currently uses an external store.
2. Keep the source backend, database, source volume/bucket, and target backend
   available until the migration completes and the target service has passed
   its read checks.
3. Wait for uploads to finish. The migration refuses any `open` or
   `completing` reservation, any object in `deleting` state, or any non-empty
   external-delete queue. Finish or safely resolve those operations first.
4. Do not run backup, maintenance, another migration, or a second server
   against the same data directory during the migration.
5. Use the existing source settings in `ATERMIUS_OBJECT_STORE_*`. Set the
   destination independently through `ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_*`.
   S3 credentials are read from a private credentials file and never belong in
   command-line arguments or logs.
6. Check capacity before starting. The migration keeps source objects, so an
   external destination needs room for another full copy. A SQLite destination
   needs room for the migrated ciphertext plus SQLite WAL growth. SQLite does
   not automatically return freed pages to the filesystem when objects move
   out. Also reserve space for the verified `.atb` archive; backup hydration
   includes external object bytes. Do not run `VACUUM` during this procedure.

The source must be configured as the backend currently referenced by external
catalogue rows. A catalogue containing SQLite plus one filesystem/S3 identity
is valid when that external backend is configured as the source. A SQLite
source configuration cannot read arbitrary external rows and will reject such
a catalogue.

## Destination configuration

For a filesystem destination, pre-create a dedicated absolute directory owned
by the server UID, mode `0700`, with no symlink path component. It must be
outside the database directory and must not be the source volume when changing
between filesystem identities. Configure:

```sh
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND=filesystem
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_FILESYSTEM_ROOT=/migration-object-store
```

For an S3-compatible destination, provide the bucket, region, and private
credentials file inside the migration container. Endpoint and prefix are
optional; remote endpoints must satisfy the normal object-store HTTPS policy.

```sh
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND=s3
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_BUCKET=example-bucket
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_REGION=us-east-1
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_CREDENTIALS_FILE=/run/secrets/object-store-target.json
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_ENDPOINT_URL=https://s3.example.test
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX=atermius-production
```

For a SQLite destination, set only:

```sh
ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND=sqlite
```

SQLite-to-SQLite or an identical backend identity and S3 prefix is rejected as
a no-op. Moving between different S3 prefixes in the same bucket is supported;
the journal stores and checks exact object keys because S3 store identity does
not include the prefix.

## Migration procedure

Create and verify the backup using the existing operator commands and paths
mounted into the container. Include the same source-backend Compose overlay used
by the current service (`compose.object-store-filesystem.yaml` or
`compose.object-store-s3.yaml`). The commands below show a filesystem source;
for an S3 source, replace that overlay with `compose.object-store-s3.yaml`:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  -f deploy/compose.backup.yaml -f deploy/compose.object-store-filesystem.yaml exec -T server \
  /usr/local/bin/atermius-server backup \
  --archive /backups/pre-object-migration.atb --key-file /backup-key/atermius-backup.key

docker compose --env-file deploy/.env -f deploy/compose.yaml \
  -f deploy/compose.backup.yaml -f deploy/compose.object-store-filesystem.yaml exec -T server \
  /usr/local/bin/atermius-server verify-backup \
  --archive /backups/pre-object-migration.atb --key-file /backup-key/atermius-backup.key
```

Stop the application service and run a one-off command using the same Compose
project, data volume, and source overlay. Pass the destination environment
explicitly to `docker compose run`; for an S3 destination, mount its credentials
read-only at the path configured above. Example filesystem-to-S3:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  -f deploy/compose.object-store-filesystem.yaml stop server

# Export or set these host-side values before running Compose. The target
# credentials file must be readable only by UID 10001 and is mounted read-only.
TARGET_S3_BUCKET=example-bucket
TARGET_S3_REGION=us-east-1
TARGET_S3_CREDENTIALS_HOST_FILE=/srv/atermius-object-store-target/credentials.json
TARGET_S3_PREFIX=atermius-production

docker compose --env-file deploy/.env -f deploy/compose.yaml \
  -f deploy/compose.object-store-filesystem.yaml run --rm --no-deps \
  -v "$TARGET_S3_CREDENTIALS_HOST_FILE:/run/secrets/object-store-target.json:ro" \
  -e ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_BACKEND=s3 \
  -e ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_BUCKET="$TARGET_S3_BUCKET" \
  -e ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_REGION="$TARGET_S3_REGION" \
  -e ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_CREDENTIALS_FILE=/run/secrets/object-store-target.json \
  -e ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_S3_PREFIX="$TARGET_S3_PREFIX" \
  server migrate-user-objects --migration-id 11111111-1111-4111-8111-111111111111 --server-stopped
```

If the destination is in AWS rather than a custom endpoint, omit the target
endpoint variable entirely. For a filesystem destination, mount its
pre-provisioned owner-only volume into the one-off container (for example at
`/migration-object-store`) and pass the filesystem backend/root settings in the
same way. Do not point the target root at the source volume.

Replace the example migration UUID with a newly generated canonical lowercase
UUID and record it in the change log. If the process fails, keep the service
stopped and rerun the exact command with the same migration ID and unchanged
source/target settings. A `copying` journal deliberately prevents normal server
startup until the job is resumed and reaches `complete`.

After the command reports success, change the normal
`ATERMIUS_OBJECT_STORE_BACKEND` settings to match the destination and start the
service with the destination filesystem root or S3 bucket/credentials/prefix.
Check readiness, fetch representative existing objects through the API, and
confirm the expected sync references on a second device before considering the
cutover complete. Do not restart with source settings after catalogue rows have
switched.

## Journal, retries, and rollback

The SQLite journal records the source/target backend identities, exact object
keys, expected size and SHA-256, a stable migration UUID, reference count, and
per-object cutover state. It contains no attachment plaintext or credentials.
The migration scans metadata without loading the complete catalogue payloads
into memory, verifies each source payload, publishes an immutable destination
copy, reads it back, and then changes the blob row plus its journal checkpoint
in one SQLite transaction. `object_references`, object IDs, `created_at`, and
`gc_after` are preserved. SQLite destinations store the verified bytes inline.

Destination objects are never removed automatically. If the process stops
after a destination write, repeating the same immutable write verifies and
reuses it. If a row has switched but the process exits before the final job
checkpoint, the command verifies every target object and completes the same
journal. Do not replace a destination filesystem volume or change the target
S3 prefix while resuming.

There is no in-place cancel or rollback command. For an incomplete job, first
restore the exact source and destination availability/configuration, then rerun
the same migration ID to resume. Do not delete or edit journal rows manually.
If forward recovery is impossible, restore the verified pre-migration archive
into a new data directory and start it with the hydrated SQLite object store;
keep the interrupted data directory and all source/destination storage
untouched for investigation.

The source copy remains in place for filesystem/S3 sources. A SQLite source is
changed in the active catalogue as each item switches, so retain the verified
pre-migration `.atb` archive for rollback. Before the target server accepts
new writes, the safest rollback is to restore that archive into a new data
directory, run the restored instance with its hydrated SQLite object store,
and keep the original data directory and external volumes untouched. Once the
target service has accepted new writes, restoring the old archive would lose
those writes; take a new backup and plan a forward/reverse migration from the
current catalogue instead.

The migration is an operator-controlled downtime procedure, not a live
dual-write mode. It does not prune source objects, change the sync protocol,
rewrite signed references, or provide an online cutover window.

# MFA TOTP seed-key rotation

Use this offline procedure to change the dedicated 32-byte key configured by
`ATERMIUS_MFA_ENCRYPTION_KEY_FILE`. SQLite remains the default target. With
`ATERMIUS_SYNC_BACKEND=postgres`, the command instead rotates seed envelopes in
the configured PostgreSQL schema. It does not change recovery-code hashes,
consumed-code state, login challenges, replay steps, setup expiry, or credential
versions.

## Before rotation

1. Make and verify an encrypted instance backup. Record which MFA key belongs
   to that backup; the MFA key is stored separately and is not inside the
   archive. Keep the old key in protected offline storage while any backup
   encrypted under it may need to be restored.
2. Stop the server and confirm the instance is not being served by another
   process. For SQLite, the command takes `server.lock` and
   `maintenance.lock`. For PostgreSQL, upgrade every node to a release that
   holds the database runtime advisory lock, stop all nodes and database-backed
   workers, disable automatic restarts for the maintenance window, and close
   every client connection to the target database. The PostgreSQL command takes
   an exclusive try-lock and refuses if a cooperating node holds its shared
   lock or if `pg_stat_activity` reports any other client backend. The flag
   `--server-stopped` is an operator attestation; it is not treated as proof by
   itself. The database connection check is deliberately conservative and
   includes psql, monitoring, and other application clients. Keep all nodes
   stopped until the new key is installed.
3. Create a different random 32-byte key in the same protected host directory
   as the configured key. Keep both files owner-only, mode `0600`, owned by
   the service user, regular, and single-linked. Do not place either key in
   the data directory backup or in shell arguments as key material.

Example for a Compose deployment using `deploy/compose.mfa.yaml` (run from the
repository root; set `KEY_DIR` to the same host directory as
`ATERMIUS_MFA_KEY_HOST_DIR` in `deploy/.env`):

```sh
KEY_DIR=/srv/atermius-mfa-key
(umask 077; set -C; head -c 32 /dev/urandom > "$KEY_DIR/atermius-mfa.next.key")
sudo chown 10001:10001 "$KEY_DIR/atermius-mfa.next.key"
sudo chmod 0600 "$KEY_DIR/atermius-mfa.next.key"

docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.mfa.yaml \
  run --rm --no-deps \
  -v "$KEY_DIR/atermius-mfa.key:/rotate/old.key:ro" \
  -v "$KEY_DIR/atermius-mfa.next.key:/rotate/new.key:ro" \
  --entrypoint /usr/local/bin/atermius-server server \
  rotate-mfa-key --old-key-file /rotate/old.key \
  --new-key-file /rotate/new.key --server-stopped
```

The command is restricted to the regular `ATERMIUS_DATA_DIR/atermius.db`,
requires the current schema and passing SQLite integrity/foreign-key checks,
and uses one `BEGIN IMMEDIATE` transaction for every active and pending
envelope. A wrong old key, malformed envelope, unsafe key file, incomplete
migration, or failed database check aborts the transaction. It prints only
counts, never key material or seed contents.

For a PostgreSQL deployment, run the command with the same exact backend,
database URL, schema, and required runtime-key file settings used by the
service. `ATERMIUS_DATABASE_URL` must remain the local
`ATERMIUS_DATA_DIR/atermius.db` URL accepted by the restricted runtime; it is
not the rotation target. The PG command validates the complete shared schema
through migration 0018, closes its validation pool, and then uses one dedicated
connection with the configured schema in `search_path`. It locks by PostgreSQL
database OID, so every schema and node in that database shares the same lock.
The re-encryption runs in one PostgreSQL transaction and only updates the two
seed-envelope columns. Any bad old key, malformed envelope, failed update, or
schema/quiescence check aborts without committing earlier envelope changes.
The PG command refuses if any other client backend is connected to that
database. Do not run it from a session connected to the target database; use a
separate control database for orchestration and ensure automated health checks
and monitoring have also disconnected.

Example environment for a PG deployment (supply values through the protected
deployment environment, not command-line arguments):

```sh
export ATERMIUS_SYNC_BACKEND=postgres
export ATERMIUS_SYNC_PG_URL='postgresql://...'
export ATERMIUS_SYNC_PG_SCHEMA='atermius'
export ATERMIUS_PG_INSTANCE_SIGNING_KEY_FILE='/keys/instance-signing.key'
export ATERMIUS_PG_AUTH_RATE_LIMIT_KEY_FILE='/keys/auth-rate-limit.key'
```

Then run the same `atermius-server rotate-mfa-key --old-key-file ...
--new-key-file ... --server-stopped` command shown above. A misspelled or
partial PostgreSQL configuration fails closed and never falls back to the
node-local SQLite database.

For application releases that add PostgreSQL schema migrations, use the
[PostgreSQL runtime upgrade procedure](postgres-runtime-upgrade.md). Migration
0018 sets the audit identity sequence to `CACHE 1`; all old nodes must be
stopped first so no backend can retain a pre-upgrade sequence cache.

## Activate and verify the new key

After the command reports success:

1. Preserve a separate copy of the old key in protected offline storage for
   backups created before rotation. Keep its backup association clear.
2. Atomically replace the configured host key file with the staged new key on
   the same filesystem (for example, `mv -f "$KEY_DIR/atermius-mfa.next.key"
   "$KEY_DIR/atermius-mfa.key"`). Keep the configured filename and
   owner/mode expected by the deployment. Do not restart the server while the
   configured file still contains the old key.
3. Start the server and verify readiness. Complete a TOTP login with an
   enrolled account, then verify an unused recovery code still works if your
   normal acceptance procedure covers it.
4. Retain the new key separately from the instance backup. Future backups
   require this key; restoring an older backup requires that backup's old key.

If the command exits with an error, it has not committed envelope changes;
leave the old key configured, inspect the sanitized error, and retry only
after correcting the identified input or database condition. If the command
reports success but the process is interrupted before the key file is
switched, keep the server stopped and finish installing the staged new key.
The database now requires the new key. Do not rerun with the old key.

Permanent loss of the key matching the current database makes active TOTP
seeds unrecoverable. Account Recovery can clear MFA and require enrollment
again, but recovery codes do not reconstruct a TOTP seed.

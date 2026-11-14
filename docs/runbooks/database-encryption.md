# Database encryption at rest (SQLCipher)

The main SQLite database (`ATERMIUS_DATA_DIR/atermius.db`) can be encrypted at
rest with SQLCipher. The key is a raw 32-byte file named by
`ATERMIUS_DATABASE_KEY_FILE`; it must live **outside** the data directory, so a
stolen database file, WAL file, backup snapshot or restore stage reveals
nothing on its own (see [what is and is not protected](#what-is-and-is-not-protected)
for the other files on the data volume). Usernames, KDF salts, account-key envelopes,
verifier hashes, audit rows, the credential-visibility escrow tables and all
other database contents are covered, which also blocks offline master-password
guessing from a database dump.

This runbook covers new instances, enabling encryption on an existing
instance, key rotation, key backup, backups/restores, and the exact limits of
the protection.

## How it works

- The server binary links a bundled SQLCipher (built with vendored OpenSSL).
  Startup fails closed with `DATABASE_ENCRYPTION_UNAVAILABLE` if
  `PRAGMA cipher_version` reports no SQLCipher.
- The key is applied as a raw key, `PRAGMA key = "x'<64 hex>'"`, through the
  SQLx `key` pragma, which SQLx always executes before any other pragma on
  every new connection. A raw 256-bit key needs no passphrase KDF. SQLCipher 4
  encrypts every page with AES-256 and authenticates it with HMAC-SHA512.
- SQL statement logging is disabled on encrypted connections, so the key
  pragma can never reach the logs (SQLx would otherwise log statements at
  debug level, and slow statements at warn level). Error messages never
  contain the key, the key path, or SQLite details.
- The key file follows the same private-file rules as the other operator
  keys: an existing regular file (not a symlink), owned by the service user,
  single-linked, with no group/other permissions (mode `0600`), exactly 32
  bytes, outside `ATERMIUS_DATA_DIR`. A configured but invalid file stops
  startup with `DATABASE_KEY_FILE_INVALID`.

### Startup decision table

Detection runs before SQLite opens the file and before any migration. A file
that starts with `SQLite format 3\0` is plaintext; any other non-empty file is
treated as encrypted.

| Database file | `ATERMIUS_DATABASE_KEY_FILE` | Result |
| --- | --- | --- |
| missing (new instance) | set | creates an encrypted database |
| encrypted | set, correct key | starts; overview reports `enabled` |
| encrypted | set, wrong key | fails: `DATABASE_KEY_INVALID` |
| encrypted | unset | fails: `DATABASE_KEY_REQUIRED` |
| plaintext | set | fails: `DATABASE_NOT_ENCRYPTED` (run `database-encrypt` offline) |
| plaintext or missing | unset | starts unencrypted, logs one warning, overview reports `disabled` |
| any, with a leftover `.atermius.db.pre-encrypt-plaintext` | any | fails: `DATABASE_ENCRYPTION_INCOMPLETE` (rerun `database-encrypt`) |

`GET /api/v1/admin/overview` returns `"database_encryption": "enabled"` or
`"disabled"`. The client's instance overview (Settings › Instance overview)
and its credential-visibility administration card show a warning with a
pointer to this runbook when it is `disabled`, and a quiet "encrypted at
rest" status when it is `enabled`; older servers without the field show
neither.

## New instance (Docker Compose)

`deploy/compose.yaml` mounts a dedicated `server-keys` volume at `/keys`
(separate from the `/data` volume; the image creates `/keys` as `0700`, owned
by UID 10001) and passes `ATERMIUS_DATABASE_KEY_FILE` through. An empty value
means encryption is off. `deploy/.env.example` sets
`ATERMIUS_DATABASE_KEY_FILE=/keys/database.key` for new instances.

Generate the key **before the first start**:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  run --build --rm --no-deps server database-key-generate --out /keys/database.key
```

The command writes 32 random bytes with mode `0600`, refuses to overwrite an
existing file, refuses any path inside the data directory, and refuses a
group/world-writable key directory, including a shared sticky directory such
as `/tmp` (a volatile location could lose the only copy of the key on reboot).
Then start the stack as usual and confirm the admin overview reports
`enabled`. Back up the key right away (see [Back up the key](#back-up-the-key)).

Without Compose, the key file must be owned by the user the service runs as
(the server refuses a key file owned by anyone else with
`DATABASE_KEY_FILE_INVALID`), so create it **as that user** in a directory
that user owns with mode `0700`. For a service running as `atermius`:

```sh
sudo install -d -m 700 -o atermius -g atermius /etc/atermius
sudo -u atermius env ATERMIUS_DATA_DIR=/var/lib/atermius \
  atermius-server database-key-generate --out /etc/atermius/database.key
```

Use the service's real `ATERMIUS_DATA_DIR`, so the command can check that the
key is outside it. Then set `ATERMIUS_DATABASE_KEY_FILE=/etc/atermius/database.key`
for the service. Running the command as root instead creates a root-owned
file that a service running as another user cannot use.

## Enable encryption on an existing instance

Encryption is a one-way, offline migration. There is no decrypt command, and
older server releases cannot open an encrypted database or an encrypted
archive (they fail closed). Plan accordingly.

1. Upgrade to this release and confirm the instance is healthy with its
   current plaintext database.
2. Make and verify a backup (`backup` + `verify-backup`, or the admin backup
   job). This is your only rollback path to a plaintext database and to an
   older server release. Note that it is plaintext inside its encrypted
   archive; store and retire it accordingly.
3. Generate the key (`database-key-generate`, as above) and add
   `ATERMIUS_DATABASE_KEY_FILE=/keys/database.key` to `deploy/.env`.
4. Stop the server (`docker compose ... stop server`). A Web restore stage
   prepared before this step stays plaintext: it can still be discarded after
   encryption, but `install-restore-stage` refuses it with
   `DATABASE_NOT_ENCRYPTED`; prepare a new stage instead.
5. Encrypt offline:

   ```sh
   docker compose --env-file deploy/.env -f deploy/compose.yaml \
     run --rm --no-deps server database-encrypt --server-stopped
   ```

   The command takes the server runtime lock and the maintenance lock (it
   refuses with `SERVER_RUNNING` while a server holds the data directory),
   removes any `.backup-snapshot-*` directory that a killed backup run left in
   the data directory (it can hold a complete plaintext snapshot; with both
   locks held no backup can be using it, and the command reports how many it
   removed), checkpoints the WAL, runs `PRAGMA integrity_check`, records per-table row
   counts and `user_version`, exports into a private SQLCipher copy inside the
   data directory with `ATTACH ... KEY` + `sqlcipher_export`, copies
   `user_version`, and verifies the copy (integrity check, identical row counts
   and `user_version`). It then fsyncs the copy, keeps the plaintext original
   reachable as a hard link, atomically renames the copy over `atermius.db`,
   removes stale `-wal`/`-shm` sidecars, re-verifies the installed file with
   the key, and only then removes the plaintext link. If the re-verification
   fails, the plaintext database is put back.
6. Start the server. The admin overview now reports `enabled`.
7. Make a new backup immediately. Retire the plaintext pre-encryption backups
   once the encrypted backups have been verified.

If the command is interrupted, run it again: it finishes a run whose
encrypted file was already installed (removing the plaintext link) and
otherwise starts over. The server refuses to start while the plaintext link
`.atermius.db.pre-encrypt-plaintext` exists (`DATABASE_ENCRYPTION_INCOMPLETE`).
Leftover `.atermius.db.encrypt-*.tmp` / `.atermius.db.rekey-*.tmp` files are
SQLCipher files, never plaintext, and are removed by the next run. Rerunning
`database-encrypt` on an already encrypted database also removes leftover
`.backup-snapshot-*` directories before it reports `DATABASE_ALREADY_ENCRYPTED`.

## Rotate the key

1. Make and verify a backup.
2. Generate the new key next to the current one:

   ```sh
   docker compose --env-file deploy/.env -f deploy/compose.yaml \
     run --rm --no-deps server database-key-generate --out /keys/database.next.key
   ```

3. Stop the server, then rekey offline:

   ```sh
   docker compose --env-file deploy/.env -f deploy/compose.yaml \
     run --rm --no-deps server database-rekey \
     --new-key-file /keys/database.next.key --server-stopped
   ```

   The command requires the current key in `ATERMIUS_DATABASE_KEY_FILE`, takes
   both locks, removes `.backup-snapshot-*` directories left by killed backup
   runs (they are under the key being retired), checkpoints and verifies the
   live database, rekeys a private copy with `PRAGMA rekey`, verifies that the
   new key opens the copy with identical row counts and that the old key no
   longer opens it, and then atomically replaces `atermius.db`. The live file
   is never half rekeyed. Every failure before that replacement leaves the live
   database unchanged under the current key. If the replacement succeeded but
   the final re-verification with the new key does not complete, the command
   fails with `DATABASE_REKEY_INSTALLED_UNVERIFIED`: the live database **is
   already under the new key**. Keep both key files, point
   `ATERMIUS_DATABASE_KEY_FILE` at the new key, and run
   `database-checkpoint --server-stopped` (below) to verify the database with
   it before starting the server, or restore a backup.
4. Set `ATERMIUS_DATABASE_KEY_FILE=/keys/database.next.key` in `deploy/.env`
   and start the server. With the old key still configured, startup fails with
   `DATABASE_KEY_INVALID`, which is the signal to update the setting.
5. Make a new backup, back up the new key, and destroy the old key once you no
   longer need it. Existing archives carry their own database key (inside the
   encrypted archive payload) and stay restorable with their backup key.

## Back up the key

Without the key, the database cannot be opened. Keep at least one copy of
the key **separately** from the data volume, from the backup archives, and
from the backup key. For example, print it as base64 and store it in a
password manager or a sealed offline location:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  run --rm --no-deps --entrypoint base64 server /keys/database.key
```

To restore the key onto a fresh keys volume, let the server decode it with
`database-key-import`, so the raw key never touches a host file. In bash,
`read -rs` keeps the pasted value out of the terminal echo and the shell
history:

```sh
read -rs DATABASE_KEY_B64   # paste the base64 from your record, then Enter
printf '%s\n' "$DATABASE_KEY_B64" | docker compose --env-file deploy/.env -f deploy/compose.yaml \
  run --rm --no-deps -T server database-key-import --out /keys/database.key
unset DATABASE_KEY_B64
```

`database-key-import` reads the base64 from standard input and creates the
key file as the service user with mode `0600`, under the same rules as
`database-key-generate` (outside the data directory, in a directory that is
not group/world-writable). It **never replaces or removes an existing key
file**: if `/keys/database.key` already exists it fails with
`DATABASE_KEY_FILE_EXISTS` and leaves that file untouched, and input that is
not the base64 of exactly 32 bytes fails with `INVALID_DATABASE_KEY` without
creating anything. The server validates the file again at startup. (An
earlier version of this runbook used a shell snippet whose cleanup deleted an
existing key file when it refused to overwrite it; do not use that snippet.)

## Offline checkpoint and verification

The stock `sqlite3` tool and Python's `sqlite3` module cannot open a
SQLCipher database. For offline maintenance that needs a fully checkpointed
database file (for example before `install-restore-stage`), use the server
binary, which applies the configured key:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml \
  run --rm --no-deps server database-checkpoint --server-stopped
```

It takes both locks (refusing with `SERVER_RUNNING` while a server holds the
data directory), applies the same key/format checks as startup
(`DATABASE_KEY_REQUIRED`, `DATABASE_NOT_ENCRYPTED`, `DATABASE_KEY_INVALID`),
runs `PRAGMA wal_checkpoint(TRUNCATE)` and `PRAGMA integrity_check`, fully
closes the database, and fails with `DATABASE_SIDECAR_REMAINS` if a `-wal`,
`-shm` or `-journal` file is still present. It also works on a plaintext
instance without a key. It does not change logical records. The Compose
restore cutover coordinator (`deploy/restore_cutover.py`) runs this command
inside the server image when the source database is encrypted.

## Backups and restores

- **Backup of an encrypted instance.** `VACUUM INTO` on the keyed connection
  writes the snapshot already encrypted with the same key (verified, see
  findings below); the server also checks the snapshot has no plaintext
  header before archiving it. The archive manifest records
  `"database_encryption": "sqlcipher4-raw-key-v1"` and the encrypted archive
  payload carries `database.key` next to `instance-ed25519.key` and
  `auth-rate-limit.key`, so archives stay self-contained under
  `ATERMIUS_BACKUP_KEY_FILE`. The database key is read into memory only; it is
  never written to the data directory, the snapshot directory or a restore
  stage. Older server releases reject these archives (unknown manifest field).
- **Backup of a plaintext instance** writes the unchanged legacy format.
- **Restore matrix** (`restore`, Web restore stage, `verify-backup`):

  | Archive | Target `ATERMIUS_DATABASE_KEY_FILE` | Result |
  | --- | --- | --- |
  | encrypted | set | staged copy opened with the archived key and rekeyed to the target key (unchanged if equal) |
  | encrypted | unset | fails `DATABASE_KEY_REQUIRED`; nothing is published |
  | legacy plaintext | set | encrypted during staging with `sqlcipher_export`; the transient plaintext extraction stays in the private stage directory and is replaced atomically (see the note on interrupted restores below) |
  | legacy plaintext | unset | unchanged plaintext restore |

  `verify-backup` opens an encrypted snapshot with its archived key, so it
  needs no database key configuration.
- **Interrupted offline restores.** `restore` extracts the archive into a
  private `.atermius-restore-<uuid>.staging` directory next to the new
  target. If the process is killed before it publishes the target (kill,
  OOM, power loss), that stage keeps the extracted database, which for a
  legacy plaintext archive can still be plaintext. The next `restore` into
  the same parent directory removes such stale stages first (only private
  directories of the service user, and never one that another running
  `restore` still holds) and reports how many it removed. If you do not run
  another restore there, delete leftover `.atermius-restore-*.staging`
  directories yourself.
- **Web restore stages** are prepared by the running server and are encrypted
  with the server's configured key; `install-restore-stage` must therefore run
  with the same `ATERMIUS_DATABASE_KEY_FILE` (without it, it fails with
  `DATABASE_KEY_REQUIRED` before reading anything), and the installed target
  uses that key. Discard pending stages before rotating the key: a stage
  prepared under the old key no longer validates. The Compose cutover
  coordinator checkpoints an encrypted source with `database-checkpoint`
  inside the server image; it never opens the encrypted file on the host.
- **S3 replication** copies the finished `.atb` archive bytes only and never
  reads the database file.
- **Credential-visibility escrow data** (see
  [CREDENTIAL-VISIBILITY.md](../CREDENTIAL-VISIBILITY.md#data-at-rest-database-encryption))
  lives in ordinary tables and needs no extra step. Backups and restores
  carry the escrow key, administrator wraps, deposits, view log and account
  modes unchanged; the server suite round-trips them through the `restore`
  path into plaintext, rekeyed, same-key and newly encrypted targets and
  checks that the restored escrow key, deposits and records still work.
  After restoring an older archive, read the escrow-key note in
  [CREDENTIAL-VISIBILITY.md](../CREDENTIAL-VISIBILITY.md#operational-notes).

## What is and is not protected

Protected:

- `atermius.db`, its `-wal` file (pages are encrypted before they reach the
  WAL), backup snapshots (including the private `.backup-snapshot-*`
  directory a backup uses inside the data directory), Web restore stages, and
  the temporary files of `database-encrypt`/`database-rekey`. The `-shm` file
  holds only the WAL index, no row data.
- Offline attacks on a copied data volume or database file, including
  master-password guessing from KDF salts and verifier hashes.
- The credential-visibility tables `instance_credential_policy`,
  `credential_escrow_keys`, `credential_escrow_key_wraps`,
  `credential_escrow_envelopes` and `credential_admin_views`, and the
  `credential_visibility` columns of `users` and `account_invitations`.
  Deposits and wraps are client ciphertext in any case; encryption at rest
  also hides which accounts are `admin_visible`, which Vaults have deposits and
  the administrator view log. More importantly, a plaintext file holds an
  administrator's KDF salt, verifier and account-key envelope next to that
  administrator's wrap of the escrow key, so guessing that one master password
  offline would open every deposit. A server test checks that the descriptor
  format string, usernames and sealed deposits never appear in the raw bytes
  of an encrypted database or its WAL, while they do in an unkeyed control.

Not protected:

- An attacker who obtains the key volume as well (or root on the running
  host), or the memory of the running server or of an offline command: the
  key is necessarily in process memory while they run. The server zeroizes
  its own key buffers, but SQLx keeps the `key` pragma string in the pool
  options for the pool's lifetime, and SQLx and SQLite make short-lived,
  non-zeroized copies of statement text and bound values (the `PRAGMA rekey`
  statement and the `ATTACH ... KEY ?` value of the offline commands) that
  are freed right after the statement finishes. Anyone holding the key (or an
  encrypted backup archive together with `ATERMIUS_BACKUP_KEY_FILE`, which
  carries the database key) reads the credential-visibility tables as in a
  plaintext database and can guess administrators' master passwords offline;
  deposits then still need an administrator's account key or the escrow
  recovery code.
- Other files in the data directory are not inside the database:
  `instance-ed25519.key` (instance signing key), `auth-rate-limit.key`, the
  runtime/maintenance locks, and `backup-status.json`. Protect the data volume
  with normal host controls; full-disk or volume encryption remains
  recommended.
- Storage that already held plaintext: after `database-encrypt`, freed disk
  blocks, SSD remapped blocks, filesystem snapshots and earlier volume
  backups may still contain old plaintext pages. Use full-disk encryption, or
  migrate to a fresh volume and destroy the old one, if that matters.
- Backups created before encryption was enabled (plaintext inside their
  encrypted archives).
- A `restore` killed before it published its target leaves its private
  `.atermius-restore-<uuid>.staging` directory next to the target until the
  next `restore` into the same parent removes it (see
  [Backups and restores](#backups-and-restores)); for a legacy plaintext
  archive it can hold the plaintext database.
- On a plaintext instance, a backup process that is killed before its cleanup
  runs leaves its private `.backup-snapshot-<id>` directory, with a complete
  plaintext database snapshot and copies of the instance keys, in the data
  directory. `database-encrypt` removes every such directory before it
  encrypts (and `database-rekey` removes old-key ones), so none survives the
  migration. Nothing removes them while encryption stays off; delete them
  with the server stopped if a backup was interrupted.
- Client data is already end-to-end encrypted; this feature protects server
  metadata, not the client cryptography.
- **PostgreSQL restricted sync-core is out of scope.** Use storage-level
  encryption for PostgreSQL (encrypted volumes/disks, or provider-managed
  encryption at rest). The node-local SQLite store of a PostgreSQL deployment
  still uses SQLCipher when `ATERMIUS_DATABASE_KEY_FILE` is set, and the PG
  admin overview reports that node-local state.

## Recorded SQLCipher findings

Verified experimentally on 2026-11-13 against the bundled build
(`libsqlite3-sys 0.30.1`, feature `bundled-sqlcipher-vendored-openssl`,
`PRAGMA cipher_version` = `4.5.7 community`) and pinned by
`database_encryption_tests::sqlcipher_semantics_relied_on_by_backup_restore_and_cli`:

- `VACUUM INTO '<file>'` on a keyed connection writes an output encrypted with
  the **same** key (no plaintext header, no plaintext rows) and preserves
  `user_version`. Opening the output without a key or with another key fails
  with SQLite result code 26 ("file is not a database"). The backup therefore
  keeps using `VACUUM INTO`; `ATTACH ... KEY` + `sqlcipher_export` is not
  needed for snapshots.
- `ATTACH DATABASE ? AS x KEY ?` accepts the raw-key text `x'<hex>'` as a
  bound parameter. `SELECT sqlcipher_export('x')` copies schema and rows but
  **not** `user_version` (it stays 0), so the export helper copies
  `user_version` explicitly.
- In the bundled source, `sqlcipher_export` clears foreign-key enforcement
  for the copy, creates tables and indexes, copies rows (and
  `sqlite_sequence`), and only then installs triggers and views by writing
  `sqlite_schema`, so no trigger fires during an export. The export helper
  still compares per-table row counts afterwards.
- From a keyed connection, `ATTACH` without `KEY` inherits the main key; a
  plaintext file must be attached with `KEY ''`. No server code attaches
  databases except the export helper, which runs on the plaintext source.
- A missing key, a wrong key, or a key applied to a plaintext file all surface
  as result code 26: at connect time when a pragma such as
  `journal_mode=WAL` reads the file, otherwise on the first query. The server
  forces a read right after connecting and maps code 26 on a keyed connection
  to `DATABASE_KEY_INVALID`.
- `PRAGMA rekey` works on a WAL-mode database (including uncheckpointed WAL
  frames); afterwards only the new key opens it. The server still rekeys only
  private copies or stages, never the live file in place.
- The bundled build compiles SQLCipher with `SQLITE_HAS_CODEC` and
  `SQLITE_TEMP_STORE=2`: temporary tables, indexes and sort spills default to
  memory, and the server never sets `PRAGMA temp_store=FILE`, so no plaintext
  temporary database files are written.
- Read-only `immutable=1` connections work with a key (used for the
  read-only source checks of `install-restore-stage`).
- SQLx stores `key` as its first ordered pragma, so `key` is executed before
  `journal_mode`, `foreign_keys` and every other pragma. SQLx's `Debug` output
  of connection options includes pragma values, so keyed options must never be
  formatted (the code never does; `DatabaseKey`'s own `Debug` is redacted).
- Raw keys skip the PBKDF2 passphrase KDF: dozens of keyed opens in the
  probe completed in milliseconds even with an unoptimised debug build.

## Error codes

| Code | Meaning and action |
| --- | --- |
| `DATABASE_KEY_FILE_INVALID` | The configured key file is missing, not a private regular single-linked 32-byte file, or inside the data directory. Fix the file or the setting. |
| `DATABASE_NOT_ENCRYPTED` | A key is configured but the database is plaintext. Stop the server and run `database-encrypt`, or remove the setting. |
| `DATABASE_KEY_REQUIRED` | The database (or a restore archive) is encrypted but no key is configured. |
| `DATABASE_KEY_INVALID` | The configured key does not open the database (for example, after a rekey without updating the setting). |
| `DATABASE_ENCRYPTION_INCOMPLETE` | An interrupted `database-encrypt` left its plaintext link; rerun `database-encrypt`. |
| `DATABASE_ENCRYPTION_UNAVAILABLE` | The binary was built without SQLCipher. Rebuild from this source tree. |
| `DATABASE_ALREADY_ENCRYPTED`, `DATABASE_MISSING`, `DATABASE_KEY_UNCHANGED`, `DATABASE_KEY_FILE_EXISTS`, `INVALID_DATABASE_KEY_PATH`, `INVALID_DATABASE_KEY` | CLI preconditions; nothing was changed. `DATABASE_KEY_FILE_EXISTS` means only that the output path already exists. `INVALID_DATABASE_KEY_PATH` also covers a group/world-writable (including sticky, `/tmp`-like) key directory. `INVALID_DATABASE_KEY` means `database-key-import` did not receive the base64 of exactly 32 bytes. |
| `DATABASE_KEY_FILE_WRITE_FAILED` | `database-key-generate` or `database-key-import` could not create the new key file (for example the key directory is not writable by the service user, is read-only, or is full). No key file was left behind when the write itself failed; fix the directory and retry. |
| `DATABASE_ENCRYPTION_VERIFY_FAILED`, `DATABASE_REKEY_VERIFY_FAILED`, `DATABASE_INTEGRITY_FAILED`, `DATABASE_BUSY` | Verification or checkpoint failed; the live database was not replaced (or, for `database-encrypt`, the plaintext original was put back). |
| `DATABASE_REKEY_INSTALLED_UNVERIFIED` | `database-rekey` already replaced the live database, which is now under the **new** key, but the final re-verification did not complete. Keep both key files, configure the new key, and run `database-checkpoint --server-stopped`; restore a backup if it fails. |
| `DATABASE_SIDECAR_REMAINS` | `database-checkpoint` closed the database but a `-wal`, `-shm` or `-journal` file remained; make sure no other process uses the data directory and retry. |

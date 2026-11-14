# Browser integration fixture reference

[Setup the combined API/Web workspace](https://github.com/aterm-project/server/blob/main/docs/INTEGRATION.md)

Commands and paths below assume the **assembled test workspace**, including both API source and the compiled frontend. They are not directly runnable from an API-only or Web-only checkout. Historical acceptance counts belong to their named version/run; they are not a current full-suite pass. Missing environment/fixture skips require explicit reporting. Use only disposable test accounts and targets.

## Web profile acceptance

`WEB-IT-01` runs the compiled Flutter Web app in two isolated Chromium browser
contexts against a disposable local Rust server and SQLite database. It uses
the UI to bootstrap/register the owner, create and approve a second device,
sign in from the second context, sync an encrypted Host in both directions,
and exercise offline edits followed by recovery. It also opens two tabs inside
the Owner's first BrowserContext, concurrently creates two distinct encrypted
Hosts offline, reconnects both tabs, and checks that both render the converged
set. The test verifies the actual Drift storage implementation is the same
cross-tab-safe persistent backend in both pages and inspects server receipts,
versions, events, heads, device sequences and Vault commit delta for exactly-once
persistence. Startup probes Drift storage before opening its Vault connection
and rejects unsafe IndexedDB and in-memory fallbacks. Focused Flutter tests
assert that both rejected implementations make zero connection-open calls; a
`sharedIndexedDb` retry opens once and enters the app. The error screen is
accessible, hides raw exception/account details, and can retry after browser
storage changes. The probe may perform an IndexedDB metadata existence check
for an existing database; no Drift/SQLite Vault connection or query occurs
before allowlist approval. It then exports a same-Vault portable archive from profile A and imports it into profile
B before B pulls the new record, while preserving B's pending outbox and one
encrypted attachment object block. It also exercises encrypted attachment
manifest/object sync, conflict workflows, trusted-device revocation and account
deletion cancellation followed by fresh login. The temporary database,
bootstrap token, browser state, and keys are removed when the command exits.

The normal `test:profiles` path also creates one structured Bash Snippet on
profile A, syncs it to B, verifies the push and B's changes response contain
only opaque encrypted envelopes, then checks B's Snippets list contains the
editable record and compares its decrypted title, mode, program, text parameter
schema, argv definition, and tag in the editor. A
run-isolated marker check covers the server SQLite database and any WAL/SHM
sidecars; the server must persist exactly one matching operation, version,
event, and head. The test closes the editor without opening the run review and
asserts that no SSH Relay ticket was requested, so it creates no remote command
side effect.

Build the current client bundle and install the pinned browser test dependency:

```sh
cd apps/client
flutter build web --release --no-web-resources-cdn
cd ../../integration/web
npm ci
npm run test:profiles
npm run test:multi-vault-switch
npm run test:groups
npm run test:storage-recovery
npm run test:local-profile
npm run test:local-to-sync-migration
npm run test:team-members
npm run test:team-ownership-audit
npm run test:password-change
npm run test:vault-preferences
npm run test:credential-conflicts
npm run test:host-security-conflicts
npm run test:attachments
npm run test:host-attachments-s3
npm run test:host-attachments-filesystem
npm run test:attachment-save-picker
npm run test:sync-crash-recovery
npm run test:sync-snapshot-staging
npm run test:sync-crash-recovery:reenroll
npm run test:stale-outbox-membership
npm run test:audit-log
npm run test:backup-status
npm run test:backup-schedule
npm run test:admin-restore-stage
npm run test:knownhost-sync
npm run test:relay
npm run test:port-forward-sync
npm run test:relay-cleanup
```

## Multi-Vault switching and isolation acceptance

`WEB-MULTI-VAULT-SWITCH-01` reuses the isolated two-profile server/browser
fixture and creates a second encrypted Vault before device approval, so both
enrolled devices receive both Vault keys through the normal approval flow. It
creates distinct Hosts and default-workspace preferences, switches A→B→A on
both profiles, and checks each current Vault ID, Host list/count, and selected
preference. It also creates a real stale cross-device Host conflict in Vault A,
queues an offline A Host operation, then syncs a B operation while A remains
pending. Route/body Vault IDs and operation record IDs are compared to ensure
the pending A operation and A conflict traffic are not sent through B. The
scenario records Relay ticket and WebSocket attempts and requires both to be
zero. The dedicated entry point is:

```sh
npm run test:multi-vault-switch
```

The test requires the current Flutter Web release bundle, Cargo, Node.js 18+,
and the pinned Playwright Chromium fixture. It uses no SSH target and never
requests a Relay session. Its Flutter controller race/outbox regression is in
`apps/client/test/registration_vault_hydration_test.dart`; browser and Flutter
test execution status is recorded in the acceptance matrix.

On the v1.34 release bundle, the following 12-command historical matrix passed serially:
`test:profiles`, `test:groups`, `test:storage-recovery`, `test:local-profile`,
`test:team-members`, `test:password-change`, `test:vault-preferences`,
`test:attachments`, `test:audit-log`, `test:knownhost-sync`, `test:relay`, and
`test:relay-cleanup`. This browser matrix does not include native builds or
device acceptance.

## Encrypted SSH port-forward profile sync acceptance

`WEB-PORT-FORWARD-01` reuses the isolated Relay SSHD fixture and stops after a
focused two-profile workflow. While Profile A is connected to its temporary
SSH Host, it saves a dynamic loopback SOCKS profile with a run-specific local
port. Profile A syncs the Host update before Profile B is independently
enrolled and approved; Profile B then pulls and decrypts the profile and opens
its own SSH terminal. Both profiles must render the saved profile and the
explicit `Unavailable in Web` state, with no Start/Stop forwarding action.
Sync request/response bodies and SQLite/WAL/SHM are checked for the unique
plaintext marker. The test also checks the profile port stays unbound and
there is no new Relay ticket/WebSocket, SSH session, or SSH forwarding channel
request when the profile is saved or displayed. It never attempts to start
forwarding in Chromium. All browser, server, database, account, key and SSHD
fixtures use the Relay harness's isolated temporary resources and are removed
through its normal cleanup path.

The focused test requires the current Flutter Web release bundle, Cargo, Node
18+, Playwright Chromium, root, OpenSSH `sshd` and `ssh-keygen`, the existing
`/run/sshd`, and a non-loopback IPv4 interface named `eth0`. It does not modify
system SSH configuration or connect to an external host. Native device
forwarding execution is not covered by this Web acceptance.

```sh
npm run test:port-forward-sync
```

`playwright` is pinned in `package.json` and `package-lock.json`. Playwright
downloads its matching Chromium build during `npm ci` when it is not already
cached. To install it explicitly, run `npx playwright install chromium`. In
containers, install system libraries with `npx playwright install --with-deps
chromium`. A nonstandard browser path can be supplied through
`PLAYWRIGHT_CHROMIUM_EXECUTABLE`.

## Web keyboard-interactive SSH acceptance

`WEB-RELAY-KBDINT-01` uses the current Flutter Web workspace, the real Relay
WebSocket route, two temporary OpenSSH servers, and a compiled Linux-PAM
module. The first SSHD accepts only `keyboard-interactive`; the second
advertises `keyboard-interactive,password` so the cancellation case proves
that dismissing the challenge does not fall through to the saved password
credential. The successful case checks the exact Host and endpoint context,
the generated host-key fingerprint before explicit trust, an echo-on account
code prompt, an echo-off one-time-code prompt, authentication, and a shell
command inside a temporary chroot. The cancellation case requires zero
password-factor attempts, zero sessions on its SSHD, and keeps the first
authenticated Relay socket open. Relay tickets must target only the two
fixture endpoints.

The fixture needs Linux root, `cc`, Linux-PAM development headers, writable
`/etc/pam.d`, OpenSSH `sshd` and `ssh-keygen`, `/run/sshd`, Node 18+, the pinned
Playwright Chromium, the built Web release bundle, Cargo, and a non-loopback
IPv4 interface named `eth0`. It does not contact an external SSH server or
change system SSH configuration. It creates one unpredictable PAM service
name with exclusive creation and mode `0600`; its PAM module, SSHD configs,
host keys, chroot, account, server database, and browser contexts live in
temporary fixture directories. The runner stops both SSHD process groups
before removing its PAM service and removes that service and temporary data in
its `finally` cleanup on success, assertion failure, SIGINT, or SIGTERM.

The acceptance checks that the account code, one-time code, saved-password
canary, and shell marker are absent in plaintext from Vault sync request and
response bodies; it also scans browser local/session storage, IndexedDB, page
input values, the disposable server database, application logs, and SSHD logs
for the applicable markers. The shell marker is expected in the temporary
remote file and terminal output, so it is excluded from the browser-page
absence assertion. SSH authentication answers are necessarily sent over the
active SSH transport; this test checks they are not stored or written to the
server's sync/database/log paths. This is a Linux/PAM Web acceptance only and
does not establish native-client coverage or compatibility with every PAM
module or SSH server.

Current verification status: **passed — 2026-10-09**. The current Web Release
bundle completed `WEB-RELAY-KBDINT-01`: two sequential INFO_REQUEST rounds
retained the exact Host/endpoint context; account code was echo-on and the
one-time code rendered as a password input. The accepted answers opened one
SSH shell and ran the fixture command. Cancelling a second Host challenge
caused zero SSH sessions and zero post-challenge password-factor attempts,
while the first Relay socket remained active. All four Relay tickets targeted
the two allowlisted fixture endpoints. The run completed 52 sync-privacy
checks and scanned one IndexedDB database and 118 records. Answer markers were
absent from browser storage; answer and shell markers were absent from sync,
server database and logs. There were zero canceled-host sessions. The PAM
service, SSHDs, server, browser, temporary account and fixture data were
removed in `finally`.

This is Linux/PAM Web coverage only; it does not establish Android, iOS,
Windows, Linux desktop or every SSH server/PAM module's behavior.

Build the current Flutter Web release bundle and install the pinned browser
dependency as described above, then run:

```sh
npm run test:relay:keyboard-interactive
```

## Backup CLI status acceptance

`WEB-BACKUP-STATUS-01` starts a disposable server and two isolated Chromium
profiles. An allowlisted instance administrator and a separately invited
member open Settings; the backup status card is hidden from the member and the
member receives HTTP 403 from the status endpoint. The administrator loads the
empty status, then the runner creates an owner-only backup key and calls the
real `backup` CLI to produce an encrypted archive and private status sidecar.
After refresh, the Web UI shows the successful attempt time, migration version
and archive byte count. The runner then invokes a real failed backup, checks its
fixed `backup_failed` category and time, and verifies that migration version,
archive bytes, and other success-only metadata remain absent from the API and
rendered card. Exact sidecar/API fields and rendered text are checked for
filesystem paths, key material and a runtime-policy sentinel. Finally,
`verify-backup` runs against the prior archive while the server is online; the
failure sidecar, active data tree, archive digest and temporary staging entries
must be unchanged. Credentials, generated keys, archive, database and browser
state are temporary and removed during cleanup.

Build the current Web release bundle and server binary using the setup steps
above, then run:

```sh
npm run test:backup-status
```

Use Node.js 18 or newer. The acceptance scripts use the built-in `fetch` API
and `AbortSignal.timeout`.

The test requires `cargo`, OpenSSL, and the server crate dependencies. It builds
the Rust debug binary with `cargo build --locked`, then starts that binary with
a unique loopback port and fresh temporary data directory. It does not use or
write to a production server, persistent browser profile, or real account.

The multi-tab assertions target Chromium's `sharedIndexedDb` backend. The
expired-ticket test now verifies synchronized refresh rotation across two tabs.
Other browser storage modes, storage exhaustion/clearing, hostile-mode browser
injection, and long-offline recovery remain separate acceptance gaps.

## Scheduled encrypted backup acceptance

`WEB-BACKUP-SCHEDULE-01` runs the current Flutter Web release in two isolated
Chromium profiles against a disposable server with a private archive directory
and owner-only encryption key. It verifies that the invited non-admin cannot
see the Settings schedule card or call either endpoint, while the allowlisted
administrator can load the schedule, enable a one-hour interval, and disable
it through Settings. Direct requests cover missing and extra fields, wrong JSON
types, and both interval bounds. To avoid waiting an hour, the acceptance stops
its own server, moves only the disposable database due time into the past,
restarts the same instance, and observes the real encrypted archive and durable
run result in the administrator UI. Responses and rendered text are checked
for filesystem paths, key material, and internal run IDs. The server, database,
archive, key, and browser contexts are temporary and removed on exit.

After building the current Web release and installing the pinned Playwright
dependency as described above, run:

```sh
npm run test:backup-schedule
```

## Backup replication acceptance

`test:backup-replication` verifies the administrator-only backup replication
status and restore-source flow in two independent Chromium profiles. It checks
that members cannot see or call the admin controls, that an archive available
from both local and replica storage can be selected specifically from the
replica, and that this source remains attached to the restore request and job.
It also checks response/UI privacy markers and browser page errors. The S3
compatible storage endpoint is a temporary fixture bound to loopback; the test
does not contact a real cloud service.

Build the current Flutter Web release bundle and server binary using the setup
steps above, and make sure the pinned Playwright dependency and Chromium browser
are installed. Then run:

```sh
npm run test:backup-replication --prefix integration/web
```

## Administrator isolated restore staging

`WEB-ADMIN-RESTORE-STAGE-01` starts a disposable server with a private archive
directory and owner-only backup key, then opens separate administrator and
invited-member Chromium profiles. It produces a real server-generated archive,
checks the safe source catalog and member authorization, and selects the source
in Settings. Canceling the confirmation must send no job request. Confirming it
must send one strict restore request and complete a durable restore-staging job.
The test verifies that the isolated staging directory exists, the source
archive hash is unchanged, the live service stays online, and rendered/API
metadata does not expose archive names, filesystem paths, or key bytes. The
server, archive, staged copy, key, database, and browser profiles are temporary
and removed during cleanup.

Build the current Web release bundle and server binary using the setup steps
above, then run:

```sh
npm run test:admin-restore-stage
```

## LocalVault to sync Vault migration acceptance

`WEB-LOCAL-MIGRATION-01` is a Web-only Chromium acceptance; it does not verify
Android, Windows, Linux, iOS, or native client behavior. It creates a Host and
Credential in a LocalVault before
the browser has a server account, then switches the same Chromium context into
the authenticated server workspace and opens migration from Settings. It
forces the first migration sync push to return a temporary failure after the
new Vault and source-side replay journal have been durably staged. The test
resumes from the rendered journal, requires the same target Vault ID and no
second Vault creation, and checks that the migrated Host, Credential, Group,
Snippet and supported `defaultSection` Preference decrypt in the selected
server workspace. It then creates a separate Chromium BrowserContext, requests
a new signed device identity, approves it from the owner context, imports the
sealed approval. If migrated records are already visible after sign-in, the
test checks that auto-selected workspace; otherwise it opens the destination
Vault from its Settings tile. A read-only Vault-list request verifies a sealed
key envelope addressed to the second device's own identity. The harness
records whether the selected target pulled automatically; if not, it runs
`Sync now`. A successful target changes response must contain all five opaque
migration events. Before leaving Sync health, the test waits for the Sync now
control to be enabled and the status to remain Idle, then records allow-listed
Last pull, Outbox, conflict, and unavailable-record counts. It records the
owner-side Snippet title/empty-state result, then visits Snippets,
Hosts, Groups, Credentials and Settings even if an earlier marker is absent;
diagnostics retain per-view marker booleans and allow-listed empty-state labels,
and the final assertion requires every migrated record field. It verifies the
active Vault and decrypted Snippets default in Settings.
Account and Vault device listings must show two distinct active devices,
including the second device on the destination Vault. A direct changes-feed
read and read-only SQLite inspection assert that the target contains exactly
five opaque create envelopes, heads, events and receipts; generated Host,
Credential, Group and Snippet plaintext markers must not appear in API
envelopes or any file under the disposable server data directory. The test
also verifies that the encrypted source LocalVault database still exists.
Diagnostics contain only fixed stage names, counts and booleans; enrollment
and approval JSON, passwords, keys, and credential secret are kept in memory
and clipboard contents are cleared after each transfer.

This acceptance covers the currently supported LocalVault record subset above;
unsupported preference variants, tombstones, and object references remain
fail-closed migration cases. It requires the release bundle, pinned Playwright
dependency, Cargo and Python 3 (for read-only SQLite inspection); the server,
browser contexts, source profile and all synthetic data are disposable.

```sh
npm run test:local-to-sync-migration
```

## Browser storage startup recovery

`WEB-STORAGE-RECOVERY` starts the release bundle through a disposable local
server and opens a fresh Chromium context. A context init script preserves the
native `SharedWorker`, then hides it before Flutter starts so Drift cannot use
the supported shared worker backends. The acceptance verifies the accessible
secure-storage recovery explanation and Retry action, and confirms startup
does not mount authentication, call an application API, or emit the Drift
database-open marker. It restores the native constructor in the same page,
retries, then verifies a safe persistent Drift backend and the server URL step
of AuthFlow. Diagnostics report only stage names, counts, error categories and
allowlisted backend names. No account is registered, and the temporary server
database, log, process and browser context are removed on exit.

```sh
npm run test:storage-recovery
```

## Password change acceptance

`WEB-PASSWORD-01` provisions a disposable instance and uses a fresh Chromium
context to register its first account, change the master password in Settings,
verify the same bearer session can still load the account profile, lock the
workspace, confirm the old password receives an HTTP 401, and sign in again
with the new password. The failed-login check uses only the status code; it
does not inspect or depend on error text that could distinguish an unknown
account. The harness prints only stage names, HTTP statuses, and boolean
assertions. It never prints form contents, request bodies, authorization
headers, bootstrap credentials, or server logs. Its temporary database and
browser context are removed after each run.

After building the current Web release and installing the pinned Playwright
dependency as described above, run:

```sh
npm run test:password-change
```

## Anonymous full-device-loss Recovery acceptance

`WEB-RECOVERY-FULL-LOSS-01` registers a synthetic account in a disposable
Chromium profile, creates one encrypted Host in its first Vault, and configures
Recovery through signed-in Settings. It closes and discards the original browser
profile while leaving its server-side device and session rows active. Before
Recovery, the lost device's bearer still works (HTTP 200). A second clean profile
with no inherited browser storage uses the anonymous Recovery UI to start a
challenge, inspect the signed Recovery identity and required Vault context,
submit a new password/device and Recovery identity, and complete recovery. The
server then revokes the old device/session (the old bearer returns HTTP 401),
and the replacement password signs in normally. Assertions verify one active
replacement device/session, the original Vault and exact opaque Host revision,
generation 2, one revoked original device, and one device keybox plus one
Recovery keybox for the new device.

The same journey first exercises Web MFA: it enrolls TOTP, displays one-time
recovery codes, rejects reused TOTP and recovery proofs, enforces the five-attempt
challenge cap, disables and re-enables MFA, and then performs signed full-loss
Recovery. The replacement password logs in without a second factor, while the
existing opaque Host revision remains intact.

The runner observes the Web sodium implementation in memory to obtain test-only
secret byte patterns. It scans those patterns and both Recovery codes in HTTP
request/response bodies, persistent data from both browser profiles, and
server files. Browser persistence includes local/session storage, IndexedDB
rows (including Blob contents), Cache API entries, and OPFS files. Any unreadable
store or Blob causes a scan failure; both profiles had zero failures in the
latest run. The synthetic Host marker is also checked against server files and
wire bodies. Output is limited to stages, HTTP statuses, counts, and booleans;
it does not print credentials, key material, Recovery codes, request bodies, or
server logs. The browser Web secure-storage plugin encrypts values into
same-origin localStorage while keeping its AES key in that origin's storage;
this check proves absence of raw secret bytes in the tested persisted values,
not resistance to same-origin script access or XSS. The latest current-bundle
run exited 0. The test requires the current Flutter Web release bundle, Cargo,
Python 3, and the pinned Playwright dependency. Its server, database, browser
state, credentials and keys are disposable and removed on exit.

```sh
npm run test:account-recovery:full-loss
```

The same browser flow has a restricted PostgreSQL variant. Run it through the
two-node integration fixture so the fixture owns database provisioning, node
credentials, a same-origin routing proxy, and a loopback-only state/privacy
probe; the Chromium/Node child receives only the Web inputs and probe address.
The fixture requires the opt-in disposable PG URL and a built server binary:

```sh
ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 \
ATERMIUS_TEST_PG_URL=postgresql://.../atermius_test_sync_http \
ATERMIUS_PG_HTTP_SERVER_BIN=/path/to/atermius-server \
pytest -q integration/test_pg_sync_http_acceptance.py::test_pg_http_account_recovery_full_loss_web_acceptance
```

This runs the `test:pg-recovery:full-loss` package script under pytest. The
browser completes Recovery on node B, signs in on node A, and verifies the
preserved Host and cross-node session revocation against PostgreSQL.

## PostgreSQL SSH Relay acceptance

The opt-in PostgreSQL HTTP fixture runs three focused Relay cases against two
PG-backed server nodes. It verifies a one-use ticket issued by node A and
consumed by node B, a real SSH shell command, SFTP upload/download byte
equality, replay rejection, administrator policy/group APIs, and the current
Web Settings flow against PostgreSQL. The Chromium case registers an
allowlisted owner through Web, saves instance policy, creates a server-managed
group, saves its narrower policy, and reads both states from node B. Run the
three focused cases with a disposable database whose name starts with
`atermius_test` or
`atermius_pg_test`:

```sh
ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 \
ATERMIUS_TEST_PG_URL=postgresql://.../atermius_test_sync_http \
ATERMIUS_PG_HTTP_SERVER_BIN=/path/to/atermius-server \
pytest -q integration/test_pg_sync_http_acceptance.py \
  -k 'test_pg_http_relay_cross_node_openssh_shell_sftp_acceptance or test_pg_http_relay_admin_policy_groups_privacy_and_watermark_acceptance or test_pg_http_admin_relay_settings_browser_acceptance'
```

The fixture requires Linux root, PostgreSQL 17, OpenSSH tools, `/run/sshd`,
and the Python acceptance dependencies. It creates and removes its schema and
server processes; use a disposable database. The PG Chromium case covers
instance-policy read/save and group create/override save from Settings. It does
not cover per-user override editing in PG Chromium, other browser engines,
native clients, production networking, or general PostgreSQL parity. The
broader Relay Settings lifecycle and group membership UI remain covered by the
separate SQLite Chromium runners.

Extended PG Relay lifecycle cases live in a separate module so the deliberate
node-A crash is isolated from the other tests. Run them with the same
disposable PostgreSQL settings:

```sh
ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 \
ATERMIUS_TEST_PG_URL=postgresql://.../atermius_test_sync_http \
ATERMIUS_PG_HTTP_SERVER_BIN=/path/to/atermius-server \
pytest -q integration/test_pg_relay_extended_acceptance.py
```

The concurrency case races one ticket across both nodes and then opens five
SSH transports concurrently; it requires exactly one redemption winner and
exactly four admitted connections under the shared per-user cap. The
revocation case confirms a live node-B SSH WebSocket closes after node A logs
out the session. The crash case SIGKILLs node A with four active leases, waits
past the 10-second PG lease TTL, and verifies node B can admit a fifth
connection after stale-lease cleanup. Node A is killed only inside this
dedicated fixture, whose teardown then removes the isolated schema and data.
The `test:pg-relay:concurrency`, `test:pg-relay:revocation`, and
`test:pg-relay:crash-lease` package scripts name the corresponding runners;
the pytest module supplies their credentials and target fixture.

The complete opt-in PG HTTP module and the extended Relay lifecycle module can
be run together with the same disposable database:

```sh
ATERMIUS_RUN_PG_HTTP_ACCEPTANCE=1 \
ATERMIUS_TEST_PG_URL=postgresql://.../atermius_test_sync_http \
ATERMIUS_PG_HTTP_SERVER_BIN=/path/to/atermius-server \
pytest -q integration/test_pg_sync_http_acceptance.py \
  integration/test_pg_relay_extended_acceptance.py
```

The latest run passed **68/68** existing PG HTTP cases plus **3/3** extended
Relay cases on PostgreSQL 17.7. Per-user Relay override editing in PG Chromium
is the next Settings acceptance gap.

## Team member lifecycle acceptance

`WEB-TEAM-01` uses two independent browser contexts and a disposable instance.
The first account is bootstrapped as Vault Owner; a separately invited account
registers in the other context, exports its signed public device card, and
accepts a one-time Vault invitation created by the Owner. The test observes
the pending and active member states, changes the member from Editor to Viewer
and back, checks that host writes are disabled/enabled in the member UI, then
revokes access and confirms a fresh login no longer lists the shared Vault.
Its output contains only stages and sanitized HTTP statuses. Temporary
credentials, browser contexts, server process and database are cleared during
cleanup. Owner/Admin/Editor/Viewer coverage is incomplete: the current wire
roles and UI expose Owner/Editor/Viewer only.

```sh
npm run test:team-members
```

## Vault ownership transfer and audit acceptance

`WEB-TEAM-OWNERSHIP-AUDIT-01` provisions an initial Owner and a separately
invited Editor in isolated Chromium profiles. It verifies that dismissing the
ownership confirmation does not submit a transfer, then confirms transfer and
the accompanying key rotation through the Web UI. The former Owner must become
an Editor who can still write Hosts but cannot invite or manage members; the
new Owner must gain member-management controls and retain Host write access.
The new Owner opens the Vault audit view, where the runner checks the two
membership role-change events, ownership-transfer event, and key-rotation event
both in the API response and as rendered UI rows. Diagnostics contain only
stage names, sanitized HTTP statuses and boolean assertions. The disposable
server, database, browser profiles, credentials, and invitation tokens are
removed during cleanup.
On failure, the runner keeps a mode-0600 screenshot in `/tmp` and prints its
path for diagnosis; remove it after review.

Build the current Web release bundle and server binary using the setup steps
above, then run:

```sh
npm run test:team-ownership-audit
```

## Host attachment acceptance

`WEB-ATTACH-01` runs three fresh browser/server/database scenarios: server
committed upload chunk with a dropped ACK, expired upload reservation, and
upload/download task recovery after Chromium `SIGKILL`. The final scenario
requires Linux `/proc`; it kills the isolated Chromium process group and
relaunches the same persistent profile. Across the scenarios, the test checks
encrypted object upload, byte-range download, decryption, save and removal;
upload ID/chunk recovery; the `atermius_vault` IndexedDB catalog; contiguous
ETag-bound ranges and final byte equality; Host sync gating; and that isolated
SQLite/object storage do not contain the synthetic plaintext marker or file
name. The E2E verifies durable tasks through their restored UI and Range
behavior, not by directly querying client SQLite rows. It requires the
`sqlite3` command-line client in addition to the dependencies listed above.

```sh
npm run test:attachments
```

## Host Attachments S3 backend acceptance

`WEB-ATTACH-S3-01` starts the production server in S3 object-store mode, two
independent persistent Chromium profiles, and the shared loopback-only opaque
S3 fixture. Profile A selects a disk-backed `256 MiB + 1` attachment through
the Host Attachments UI, exercising the production v2 object layout without
changing its size gates. The test verifies conditional ciphertext object
writes and the encrypted Host reference revision, syncs that Host to Profile
B, then uses Profile B's Host Attachments download action. Browser API Range
responses and backend S3 Range requests must succeed. The save adapter is
shimmed to compare every decrypted output chunk byte-for-byte with the source
file and to compare the complete SHA-256 before close.

The runner writes a temporary strict JSON credentials file with mode `0600`
outside the server data directory and strips ambient `AWS_*` and object-store
environment overrides from the server process. It connects only to the
fixture's IPv4 loopback endpoint; browser requests must stay on the disposable
application origin and must not contain fixture control credentials. The
fixture verifies SigV4 request signatures and accepts only its synthetic
access key. SQLite/WAL/SHM and stored opaque S3 objects are checked for the
synthetic plaintext marker and attachment filename. The operating-system save
dialog and real filesystem permissions are not exercised; the UI transfer,
server S3 backend, cross-profile sync, Range path, exact output bytes, and
digest checks are real.

Prerequisites are the current Flutter Web release bundle, Cargo/Rust for the
server build, Node.js 18+, and Playwright Chromium. `npm ci` installs the
pinned Playwright package; install Chromium with `npx playwright install
chromium` when it is not cached. The runner builds the server binary, starts
only loopback fixtures, and never connects to a cloud provider or uses real
cloud credentials.

```sh
npm run test:host-attachments-s3
```

## Filesystem-backed Host Attachments browser acceptance

`WEB-ATTACH-FS-01` runs the current Web release bundle against an isolated Rust
server configured with `ATERMIUS_OBJECT_STORE_BACKEND=filesystem` and a private,
temporary filesystem root. Two separate persistent Chromium profiles exercise
the existing Host Attachments UI: Profile A uploads one small encrypted v1
attachment and syncs its Host reference; Profile B pulls that encrypted
reference, uses the authenticated HTTP Range API to download/decrypt the opaque
object, saves the resulting file through Chromium's download flow, and compares
the saved bytes and SHA-256 with the source file. The runner verifies that the
filesystem key contains only the expected UUID namespace, object files and
SQLite/WAL/SHM contain no plaintext canary or filename, and the filesystem root
and store identity do not appear in browser/API traffic or server output. It
also checks owner-only root/identity permissions, rejects a symlink root, and
restarts the same database against a different empty root to verify identity
mismatch fails closed. The server, data, object root, downloads and both browser
profiles are isolated under one temporary directory and removed on exit. No
cloud account or fake object-store service is used; the runner starts the local
server binary directly with a temporary root equivalent to the Compose
`/object-store` mount.

Build the current Flutter Web release bundle first, install the pinned test
dependency, then run this serial browser suite:

```sh
npm run test:host-attachments-filesystem
```

It requires Node.js 18+, Cargo and the server crate dependencies, and
Playwright Chromium (`npx playwright install chromium` when Chromium is not
cached). The runner builds the server debug binary with `cargo build --locked`;
it does not rebuild the Web bundle. `PLAYWRIGHT_CHROMIUM_EXECUTABLE` can select
a nonstandard local browser path. This focused small-v1 UI journey does not
replace the S3 acceptance for large v2 attachments or native-device testing.

## Web attachment save-picker adapter contract

`test:attachment-save-picker` runs a Chrome-targeted Flutter browser test of the
compiled Dart Web File System Access adapter. A JavaScript shim supplies
`showSaveFilePicker`, file handles, and writable streams; the three cases check
synchronous picker invocation and the suggested filename, plaintext chunk
ordering with close-on-commit, abort behavior and idempotence, and picker
cancellation. This is an adapter contract test; it does not display the
operating-system picker or establish native permissions.

`test:attachment-save-picker-ui` extends that contract through the compiled
Flutter Web application and the real Host Attachments button. It creates a
private disk-backed `256 MiB + 1` byte fixture, so the production v2 format,
signed reader-capability gate, upload path, and streaming download path are
used without changing either production size threshold. The test checks all 66
uploaded ciphertext objects and their synced Host references, captures the
picker call while `navigator.userActivation.isActive` is true and before the
first object request, then streams each plaintext write to a Playwright route
that calculates SHA-256 incrementally. It requires the complete source digest,
4 MiB maximum writes, successful object responses before close, one close, no
abort, no browser Blob download, and removal of the completed transfer task.
The JS picker/writable and sink are test shims: this verifies the Web UI call
path, ordering, chunking and content integrity, but it does not show an
operating-system dialog, grant or persist real browser filesystem permissions,
or verify a saved file on disk. Native save dialogs and native large-file
workflows remain unverified.

Install dependencies with `npm ci` in this directory and install Chromium with
`npx playwright install chromium`, then run:

```sh
npm run test:attachment-save-picker
npm run test:attachment-save-picker-ui
```

The runner uses `flutter` from `PATH`; set `FLUTTER_BIN` when the Flutter SDK
binary has another location. Set `CHROME_EXECUTABLE` to use an existing Chrome
or Chromium installation instead of Playwright's cached browser.

## Snapshot recovery staging and browser restart

`WEB-SNAPSHOT-STAGING-01` verifies that paged snapshot recovery remains durable
while a Web process is interrupted. The runner creates two encrypted Host heads,
forces a one-item page size, and injects `410 CURSOR_EXPIRED` for the exact
Vault/cursor pair. It reconstructs the real Drift SQLite file from the
Chromium profile's IndexedDB `files` and `blocks` stores. At the interruption
boundary, the first verified item and continuation cursor must be committed in
the stage tables, while the existing encrypted-record cache and checkpoint stay
unchanged. Chromium then closes and reopens the same persistent profile. The
client must resume the same snapshot at the saved cursor, never request page one
again, activate both records and checkpoint atomically, and remove all stage,
item and cursor rows.

Run it after building `apps/client/build/web` and `server/target/debug/atermius-server`
and installing the pinned Web test dependencies:

```sh
npm run test:sync-snapshot-staging
```

The runner validates SQLite `integrity_check`, record IDs/revisions, the saved
cursor, opaque encrypted envelopes, absence of fixture plaintext, browser
errors and process/profile/temp cleanup. It only covers Chromium's
`sharedIndexedDb` backend and a SQLite fixture with two Host heads. The 410 is
injected by Playwright rather than produced by natural server retention expiry;
OPFS, other browser engines, native clients, physical power loss and PostgreSQL
parity are not established by this command.

## Ordinary Host outbox crash recovery

`WEB-SYNC-CRASH-01` creates a disposable server and two separate persistent
Chromium profiles. Profile B enrolls through a request that Profile A approves.
Profile A creates an encrypted Host; the harness confirms the server's real
commit receipt, drops the browser-facing push acknowledgement, and blocks the
matching changes response so the outbox remains pending before the forced
crash. It sends `SIGKILL` only to Profile A's Chromium process group, relaunches
the same profile, then gates the exact changes envelope while the UI still
reports one pending operation. Releasing the response must clear pending while
the server retains one matching version, event, receipt, and head.

`npm run test:sync-crash-recovery` passed using the original device identity
because its Web secure-store `.device` entry survived Chromium termination.
`npm run test:sync-crash-recovery:reenroll` also passed: a browser init script
simulates missing device/session/refresh secure-store entries after SIGKILL and
before Flutter startup; Profile B approves A's new enrollment, and A resumes
with a new device identity. The simulation verifies the authorized recovery
path without claiming Chromium termination caused the storage loss. Both runs
check Flutter's visible pending count rather than querying the IndexedDB
outbox row directly. They cover a server-committed Host operation whose
acknowledgement and pre-crash changes response were lost.

`npm run test:sync-crash-recovery:uncommitted` covers the complementary case:
the fixture seeds the current Drift IndexedDB `files`/`blocks` schema so the
new profile is pinned to `sharedIndexedDb`, then aborts the Host create push
before it reaches the server. Before SIGKILL, the runner snapshots and
reconstructs the durable `/database` file from 4096-byte IndexedDB blocks and
queries it read-only. It checks the exact pending opaque operation, local
record/revision/envelope digest and null commit sequence, while the server has
no matching receipt, event, version or head. After hard Chromium termination
and same-profile/device restart, it permits the captured push once, snapshots
the IndexedDB database again, and verifies the outbox is empty and the local
record has the committed sequence. Server state must contain exactly one
matching receipt, event, version and head. Diagnostics expose metadata and
hashes, not record bodies. This is one deterministic Host-create scenario on
the `sharedIndexedDb` backend; OPFS, native storage and broader operation
matrices remain outside this acceptance.

`npm run test:sync-crash-recovery:credential` runs the same real IndexedDB
outbox/SIGKILL boundary for one newly created Password SSH Credential. It
checks that the synthetic password is absent from the encrypted local SQLite
snapshot, observed push envelope, and server SQLite/WAL/SHM before and after
recovery. The same persistent Profile A must commit that exact operation once;
already-approved Profile B must pull its matching opaque event and decrypt the
password only in the local Credential editor. Profile B must not push while
performing that read. This adds one Password Credential create case on
`sharedIndexedDb`; updates, private-key Credentials, other record types, OPFS,
native clients, and other crash boundaries remain outside this acceptance.

`npm run test:sync-storage-write-failure` injects a one-shot IndexedDB
read/write transaction abort in Chromium's current-bundle Drift SharedWorker,
after the first mutation of the `atermius_vault` `blocks` store. The scenario is
pinned to the `sharedIndexedDb` backend. While the IDB commit is held, a second
same-origin tab issues a database read; after the injected abort it must receive
the fixed quarantine error instead of a result from SQLite's hot page cache.
The originating tab must show a recoverable save error, and both tabs must
enter the recovery-required state. A later mutation in the failed session and
manual sync from the second tab are blocked; the runner checks zero further
database requests and zero pushes during quarantine. The harness records only
fixed event names, event counts and database-port ordinals. This simulates an
IndexedDB transaction abort; it does not simulate real disk quota exhaustion
or browser-origin eviction.

Before hard termination, the runner reconstructs the durable SQLite
`/database` from the actual IndexedDB `files`/`blocks` stores and checks
`integrity_check`, encrypted record/outbox counts, server commit sequence, and
pre-retry push count. The failed save must leave no Host or outbox row, surface
a recoverable error, preserve an Add Host retry action, and avoid the success
notice. The runner then kills Chromium, relaunches the same persistent profile,
retries Host creation once, and checks one server receipt, version, event, and
matching head, plus a cleared local outbox. The latest verified run retained
the device identity and used same-device recovery. If a future run finds the
Web device identity absent, the existing trusted-device re-enrollment flow can
recover it; that condition is reported separately and is not attributed to the
IndexedDB abort. This is one Host-create scenario on `sharedIndexedDb`; OPFS,
native storage, real quota exhaustion, origin eviction, and broader mutation
types remain outside this acceptance.

Rebuild the checked-in SharedWorker from its Dart entrypoint before building a
new Web release bundle, so local Drift changes are included in the worker:

```sh
cd apps/client
dart compile js -O4 web/drift_worker.dart -o web/drift_worker.js
flutter build web --release --no-pub --no-web-resources-cdn
```

`npm run test:idb-write-failure-probe` is a smaller real-Chromium check of the
SharedWorker mutation hook and IndexedDB transaction rollback/readback. It does
not start Flutter or a server and does not verify app-level error handling.

```sh
npm run test:sync-crash-recovery
npm run test:sync-crash-recovery:reenroll
npm run test:sync-crash-recovery:uncommitted
npm run test:sync-storage-write-failure
npm run test:idb-write-failure-probe
npm run test:indexeddb-sqlite-snapshot
```

The storage-write-failure, uncommitted-operation, and lost-ACK browser
acceptances passed with exit code 0. The focused write-failure run observed an
aborted `blocks` transaction, durable SQLite integrity `ok`, unchanged local
record/outbox counts, visible recoverable UI error, no pre-retry server push,
and exactly-once retry after restart. The standalone worker probe and block
reconstruction unit check also passed. Each browser runner removes its isolated
profiles, exported database snapshots, and server fixture on completion.

## Offline outbox recovery after a membership change

`WEB-STALE-OUTBOX-01` uses three disposable Chromium contexts and a loopback
server. The Owner invites an Editor, commits a synthetic Host and waits for the
Editor to receive it. The Editor then changes the Host while offline, leaving
one encrypted operation in its local outbox. While the Editor stays offline,
the Owner invites a third disposable account and leaves that invitation
pending; this advances the signed membership version without rotating the Vault
key epoch. The Editor page and runtime stay open throughout the outage. After
Chromium restores networking, the test uses the visible sync control and waits
for the old envelope to receive `MEMBERSHIP_VERSION_CONFLICT`. It then requires
the same Editor session to reload the Vault descriptor and signed membership
chain, replace the queued envelope using the current membership version, and
commit the Host update. The acceptance checks that the replacement uses the
new membership version and unchanged key epoch, the pending count returns to
zero, and the Owner sees the updated Host. It inspects only envelope shape and
version metadata; it never prints ciphertext, tokens, account credentials or
Host values. Host fields use synthetic values at the reserved `192.0.2.0/24`
documentation range, and the test never opens an SSH connection.

```sh
npm run test:stale-outbox-membership
```

This scenario covers membership-version change with the same key epoch.
Changed-base conflicts after competing Host edits remain covered by the
cross-profile conflict acceptance.

## Password Credential outbox recovery after a membership change

`WEB-STALE-CREDENTIAL-MEMBERSHIP-01` uses three disposable Chromium contexts
and a loopback server. The Owner commits a password Credential and the Editor
pulls it, then changes its password while offline. While the Editor stays
offline, the Owner creates a pending invitation for a third account. This
advances the signed membership version without rotating the Vault key epoch.
The still-open Editor reconnects and recovers the same encrypted local edit.
Depending on whether its current descriptor and signed membership chain were
already refreshed before the first push, the Editor makes either one stale
proof attempt or an initial stale attempt followed by one post-refresh stale
proof. Every stale attempt must retain the same operation, revision, envelope,
epoch and membership version and must leave the server ledger and receipts
unchanged. The Editor then commits exactly one newly encrypted operation at
the current membership version. The Owner pulls that exact replacement and
decrypts the updated password field.

The runner checks API request/response bodies, browser IndexedDB SQLite files,
server SQLite/WAL/SHM and server logs for synthetic Credential plaintext
markers. It also requires zero browser runtime errors and removes the isolated
accounts, browser contexts, database and server fixtures on exit. Credential
values and plaintext markers are never printed.

```sh
npm run test:stale-credential-membership
```

## Concurrent Credential conflicts

`WEB-CREDENTIAL-CONFLICT-01` runs two approved, isolated Web profiles against a
disposable server. A creates and commits one password Credential; both profiles
then go offline and edit that same record with different names and passwords.
A commits first, and B's stale signed branch is retained through the conflict
endpoint. A receives the conflict feed, adopts B's verified whole-record branch
in the inbox, and commits a new revision signed by A's current device. Both
profiles must decrypt the selected name, username and password. The runner
checks matching create/resolve events, three committed revisions with exactly
one receipt/event each, a single stale conflict row with no stale receipt or
revision, and no generated plaintext markers in API envelopes or SQLite/WAL/SHM.
This section verifies the legacy whole-branch selection path. The same runner
also includes a separate password-Credential field-merge journey; it is limited
to name, username and secret and does not provide a generic Credential diff or
merge.

```sh
npm run test:credential-conflicts
```

## Host connection tuple conflicts

`WEB-HOST-SECURITY-CONFLICT-01` runs two approved Web profiles against a
disposable server. Both profiles edit the same Host while offline: A changes
the address and commits first, while B changes the port from the same base.
B must review the original base, A's committed head, and its own signed branch;
the review presents the entire connection tuple as two mutually exclusive
choices. Selecting B's tuple creates one update signed by B against A's current
head. Both profiles then converge on that revision, and the server records one
resolution audit linked to the committed head. API bodies, server SQLite/WAL/SHM
and server logs are checked for Host plaintext markers, and the flow must not
start Relay or a terminal connection.

```sh
npm run test:host-security-conflicts
```

The field-merge journey verifies:

- A and B make divergent offline edits; the stale signed branch is retained
  encrypted and does not become a committed revision, event or receipt.
- The preview verifies both signed branches and only enables merge for an
  undeleted password Credential with supported payload fields and matching
  manifests. Private-key/passphrase/fingerprint/certificate and other
  authentication material stay on whole-branch resolution.
- Name and username can use explicit sources independently. Password secret
  stays masked by default and always requires a source choice, including when
  equal on both branches. A current-head change invalidates the review and
  produces no staged write; the user must reload values and choose again.
- The resolving update is signed by the active device and encrypted against
  the reviewed current head. The runner checks its matching version, event,
  receipt, head and exactly-once resolution audit; both profiles decrypt the
  selected result, the resolved feed closes B's exact conflict outbox chain,
  and B reaches Idle.
- HTTP/browser captures and server SQLite/WAL/SHM/log scans contain no
  generated Credential secret marker. The server stores opaque ciphertext
  and does not perform the merge.

The latest run reports 4 committed revisions for the two-field merge and 3
for the same-field secret merge, one resolution audit for each, 1307 HTTP and
browser marker checks, zero SQLite/WAL/SHM marker matches, and no marker in
the server log. Native device workflows, other authentication kinds, generic
field diff/merge and cross-platform interoperability remain outside this
Web acceptance.

## SSH Relay and SFTP acceptance

`WEB-RELAY-01` starts two isolated OpenSSH servers: a Bastion bound to the
container's non-loopback `eth0` IPv4 address and a Target bound only to
`127.0.0.1`. It configures the Bastion key to permit forwarding only to that
Target address and port. The Web UI saves a Bastion Host and a separate Target
Host that references it as its single Jump Host, each with its own credential
and KnownHost trust. The Relay allowlist contains only the Bastion address and
port; the harness inspects ticket requests and asserts none names the Target.
The browser opens a real terminal and performs SFTP against the loopback Target
through the Bastion. It rotates the Target key and the Bastion key separately
and verifies each changed key is rejected at its own SSH hop. Terminal/SFTP
coverage includes concurrent tabs, upload/download byte equality, delete and
navigation, UTF-8 text editing, stale-save conflict compare/cancel, Save as,
explicit overwrite, the 10 MiB limit and disconnect cleanup.

The full `test:relay` journey also verifies the Bash-only shell-history opt-in.
The Web UI copies the hook setup command but does not paste or send it; the test
explicitly pastes it into the interactive terminal, runs a safe command, and
checks that its command and exit status appear in that terminal tab. History is
stored in the client’s encrypted local database. A user can separately opt in
to encrypted Vault sync; the two-profile flow verifies the receiving device
decrypts history while its own upload setting stays off. Stop local capture
ignores the next event, and `atermius_off` removes the remote in-memory hook
before fixture teardown. Terminal search is checked separately to ensure its
query is not sent over the SSH Relay socket.

The same run also creates a second browser profile, enrolls it through A's
device approval, and syncs the encrypted Host, Credential, and KnownHost needed
to connect. A creates a structured Bash Snippet that stores a reference to the
saved password Credential; its record contains the Credential ID, not the
secret. The harness verifies a successful opaque push, waits for B's `/changes`
response to contain the exact same operation and envelope SHA-256, and captures
push/changes request and response bodies from the Credential's first sync through
the Snippet sync. Every captured body must be marker-free. It waits for B's next
sync/reload before checking the Snippet card. On A and B, Review and run shows
the exact target and a redacted secret placeholder; the command sends nothing
before confirmation. Each confirmed run exits 0 and adds exactly one target
invocation with the expected text and Credential arguments. The result UI masks
an exact secret echo in stdout and stderr; transformed or partial echoes are not
covered. Shell syntax inside either parameter remains literal. The server
SQLite/WAL/SHM scan finds no secret marker, and each Relay ticket targets only
the allowlisted Bastion.
Credential values are decrypted and resolved on the client, then sent as stdin
inside the encrypted SSH exec channel. The remote process receives them as argv,
so other processes running under the same remote UID may observe them. This
acceptance is Web-only. The same run verifies two-target sequential batch
execution: both exact target previews are required before any dispatch, each
confirmed command runs once, and both results report exit 0. A separate
structured command returns exit 1; cancellation is also checked and must not
close the interactive terminal or retry the command. Retry/replay semantics
and native clients remain unverified. The harness logs safe counts, booleans
and hashes, never approval JSON, keys, tokens or Credential values.

The test requires a Linux root process, `sshd`, `ssh-keygen`, `mknod`,
`/run/sshd`, `iproute2`, and a non-loopback IPv4 interface named `eth0`. The
isolated chroots contain only the required `/dev/null` and `/dev/tty` device
nodes; the host `/dev` is not mounted. A missing Relay prerequisite prints
`WEB-RELAY-01 skipped` and exits nonzero, so a skip is not an acceptance pass.
The harness does not create `/run/sshd` or modify system SSH configuration.
All keys, file contents, server state, browser state and remote fixture data
are temporary and removed during cleanup. The client
supports a bounded acyclic chain of up to eight Jump Hosts. The Host's
`jump_host_id` links remain inside the client-encrypted HostRecord, so the
server sees only its opaque envelope. The focused multi-hop mode enrolls a
second browser profile, syncs the encrypted route, and verifies a real
A → B → loopback Target shell, one A-only Relay ticket/WebSocket, disconnect,
and changed-key authentication boundaries at Target, B, and A. Dedicated
three-hop and four-hop modes below cover their own shell/SFTP routes.

After a complete Vault reload, the client also checks every decrypted Host
route for missing references, self references, cycles and depth beyond eight.
Affected Host cards show the issue and open the editor for repair; unrelated
valid Hosts stay available. The check does not rewrite or remove encrypted
records, and the Relay connector still rejects a malformed route before it
requests a ticket. The server does not inspect these links.

```sh
npm run test:relay
WEB_RELAY_MULTIHOP_ONLY=1 npm run test:relay
npm run test:relay:three-hop
npm run test:relay:four-hop
npm run test:relay:max-depth
npm run test:relay:shell-completion
```

`test:relay:shell-completion` runs only the cross-profile Bash history and
completion scenario. Profile A explicitly enables encrypted history sync;
Profile B keeps upload disabled, pulls and decrypts the same history, selects
a command suggestion without sending it, then presses Enter and must create
exactly one completed history event. The runner checks SSH frame deltas, that
Profile B made no push and the sync ledger did not change, that command markers
are absent from sync storage/server logs, and that the isolated browser, account,
server, SSHD and temporary data are removed. On the current Web Release bundle
(`main.dart.js` SHA-256
`71b1ced0d7954073c2f1cca0354c65b614c59d344bfe684f7b0ccf02c74b4c1e`),
`TMPDIR=/tmp/aterminal-tests npm_config_cache=/tmp/aterminal-npm-cache CARGO_BUILD_JOBS=2 npm run test:relay:shell-completion --prefix integration/web`
exited 0 with `WEB-SHELL-COMPLETION-01 passed` and cleanup passed. This checks
one Web/Chromium shell-history completion path; it does not establish native
parity or broader shell-completion behavior.

`WEB-RELAY-THREE-HOP-01` enrolls Profile B, syncs an encrypted four-Host chain,
and runs the real A → B → C → Target route without the legacy one- or two-hop
terminal journeys. Each SSHD has a separate generated host key, user key, and
chroot. The acceptance approves each KnownHost in order, verifies key
authentication boundaries at every trust prompt, checks that Relay tickets
target only A and that exactly one Relay WebSocket stays active for the shell,
executes a marker only in the Target chroot, rejects a changed C host key
before C/Target authentication, scans sync and SQLite bodies for plaintext
Credential markers, and verifies browser and fixture cleanup.

`WEB-RELAY-FOUR-HOP-01` runs a separate A → B → C → D → Target route from
Profile B after syncing encrypted Hosts and Credentials. Each SSH node has an
independent host key, user key, and chroot; each bastion permits forwarding
only to its next hop, and Relay tickets target A only. Five ordered KnownHost
prompts and SSH authentication counters prove each hop's trust boundary. The
runner checks a Target-only shell marker, byte-exact binary and UTF-8 SFTP
upload/download/delete on the same Relay route, and fail-closed rejection when
D's host key changes before D or Target authenticates. It also scans sync
responses and SQLite/WAL/SHM markers, checks browser errors, and removes all
fixtures. Run it with `npm run test:relay:four-hop`; this does not cover routes
beyond four hops or native clients.

`WEB-RELAY-MAX-DEPTH-01` exercises the maximum supported chain, A → B → C → D → E → F → G → H → Target, from a separately enrolled Profile B. Eight independent Jump Hosts and the Target use distinct host keys, user keys, credentials and chroots; each bastion's forwarding ACL permits only its next hop, while Relay tickets target A only. The runner accepts nine KnownHost prompts in order and checks per-hop SSH authentication counters at every decision. It then verifies a Target-only shell marker and byte-exact SFTP upload/download/delete for binary and UTF-8 files over the active route. Rotating H's host key must fail closed after A–G authenticate and before H or Target authenticates. Cross-profile sync and server SQLite/WAL/SHM scans check for private-key and Credential-secret markers. The runner allows no new browser errors during the changed-key and privacy checks; any earlier console resource-load error must correlate to a same-profile Vault-presence 401 followed by successful token refresh. Run it with `npm run test:relay:max-depth`. This verifies one loopback Chromium path at the eight-Jump-Host limit; it does not establish native transport, other-browser or non-loopback behavior.

## Workspace nested-pane SSH acceptance

`WEB-WORKSPACE-LAYOUT-01` keeps the two-pane Workspace route on synthetic
banner sinks to check Relay ticket targeting, WebSocket lifecycle, and
pane-local disconnect. Its recursive three-pane route uses three independent
encrypted Host records retargeted to temporary OpenSSH servers. A fresh
password-only Unix account and password are created for each run; each server
has a different temporary host key. SSH forwarding, public-key authentication,
keyboard-interactive authentication, agent forwarding, and X11 are disabled.
The temporary SSHD listeners bind only to the runner's RFC1918 private
non-loopback `eth0` address. The Relay allowlist contains that address and the
exact six test ports. Run this acceptance inside a private test network with
public egress disabled: the temporary interactive shell runs under the host's
network namespace while the fixture is alive.

Before the browser journey, direct OpenSSH probes reject a random wrong
password, then authenticate to all three fixtures and execute run-specific
shell commands. Profile B preview, save, sync, and reload must reach none of
the SSHD targets. On each recursive Workspace pane, explicit Connect first
opens an SSH key exchange to the exact Host/port. Because the key is initially
unknown, the client closes that socket and shows its SHA256 fingerprint. The
acceptance compares the displayed fingerprint byte-for-byte with that
fixture's generated SSHD key fingerprint, approves trust, and checks that the
approval syncs before automatic retry. The retry creates one more exact-target
Relay ticket/WebSocket and completes password authentication plus a shell
session on the matching SSHD. Thus the three panes produce six ticket/socket
attempts: one closed first-use handshake and one authenticated session each.
Disconnecting Pane 1 closes only its authenticated SSHD session and Relay
transport; Panes 2 and 3 remain connected. The test checks privacy markers in
captured sync traffic and SQLite/WAL/SHM. The regular two-pane synthetic test
remains a separate Relay-lifecycle assertion. This Workspace path does not
replace the full `WEB-RELAY-01` file-transfer matrix, which separately covers
browser SFTP with its public-key-authenticated OpenSSH fixture.

The same current-bundle journey also accepts pane-scoped SFTP. Each live pane's
Files action activates that exact pane tab and opens SFTP over its already
authenticated SSH connection. The runner opens Pane 2 Files, navigates to
`/tmp`, creates a run-scoped directory, and verifies the directory exists only
in Pane 2's expected fixture chroot. Only Pane 2's SFTP request/session counts
advance; Pane 1 and Pane 3 remain unchanged. After returning to Terminal and
reopening Pane 2 Files, its path remains `/tmp` while the tab is open. Pane 3
starts at its own `/` root and opens its own SFTP subsystem. This flow creates
no Relay ticket or WebSocket beyond the SSH transport already in use. SFTP
paths are runtime-only tab state: they are not Workspace metadata or encrypted
cross-device sync records, and acceptance makes no process-restart persistence
claim.

The acceptance requires the current Flutter Web release bundle, Cargo, Node,
Playwright Chromium, Linux root, OpenSSH `sshd`/`ssh-keygen`/`ssh`, `sshpass`,
`/run/sshd`, `iproute2`, `useradd`, `userdel`, `groupdel`, `getent`,
`chpasswd`, `openssl`, `ldd`, `/bin/bash`, `id`, and a non-loopback IPv4
RFC1918 private IPv4 interface named `eth0`. `/run/sshd` must already exist with root ownership
and safe permissions. A private writable `TMPDIR` is required; the runner does
not create `/run/sshd`, alter system SSH configuration, or contact external
hosts. Normal completion and SIGINT/SIGTERM trigger fixture cleanup, removing its daemons, account, group, keys, configs, chroots, and logs. SIGKILL or host failure cannot run in-process cleanup.
```sh
npm run test:workspace-layout
```

The focused `test:workspace-layout:tmux-process-restart` mode verifies same-profile
Chromium process termination and recovery of a remote tmux Workspace. It first
creates and syncs the encrypted Workspace descriptor, unbinds the application
page from browser storage, then SIGKILLs the isolated Chromium process group.
The runner reopens the exact persistent profile, reauthenticates with the same
device identity, and checks that reauthentication and preview do not create an
SSH/Relay/tmux attachment or Workspace push. Explicit Connect verifies the
host-key proof plus authenticated retry; explicit Resume confirmation then
reattaches one client to the original tmux session without opening another
Relay or SSH transport. The SSH fixture counts three tmux management execs and
one attach PTY during Resume. It checks encrypted Workspace ledger stability,
privacy markers and cleanup. This is Linux Chromium/Web evidence; it does not
cover native clients, other browser storage backends, arbitrary crash timing,
or real production SSH targets.

It requires the current Flutter Web release bundle, Cargo, Node.js 18+,
Playwright Chromium, Linux root, OpenSSH `sshd`/`ssh-keygen`, `sshpass`,
`/run/sshd`, tmux, and a non-loopback RFC1918 IPv4 interface named `eth0`.
Use a private test network with public egress disabled. The test uses only
run-scoped accounts and fixture hosts, and removes browser/server/tmux
resources and its temporary root on normal completion.

```sh
TMPDIR=/home npm run test:workspace-layout:tmux-process-restart
```

The focused `test:workspace-layout:max-panes` mode skips the SSHD/tmux setup and
tests the encrypted eight-pane Workspace boundary directly. It reaches 8/8,
checks that adding a ninth pane is disabled, removes and restores Pane 8, saves
one encrypted Workspace, and verifies Profile B receives and decrypts the
ordered Host references, Active Pane 8, and the saved preview. It requires the
current Flutter Web release bundle, Node, Playwright Chromium, and the isolated
API/database fixture, but does not start SSHD or establish Relay sessions.

```sh
npm run test:workspace-layout:max-panes
```

The focused `test:workspace-layout:rename-sync` mode uses two independent Web
profiles to create and sync a two-pane Workspace, rename it through the visible
Workspace actions menu, and verify that Profile B decrypts the exact encrypted
update while keeping the same record, ordered Host references, and Active Pane
2. It checks one Profile A update/receipt/event/head, no Profile B push, no
Relay activity, API/SQLite/WAL/SHM/log marker privacy, browser errors, and
fixture cleanup. Like max-pane mode, it reuses the current Flutter Web release
bundle and skips SSHD/tmux setup.

```sh
npm run test:workspace-layout:rename-sync
```

## OpenSSH config import and cross-profile sync acceptance

`WEB-OPENSSH-CONFIG-IMPORT-01` supplies a synthetic SSH config to Profile A
through Playwright's in-memory file chooser. The runner never writes the config
or its `IdentityFile` paths to disk, and the importer must not open the
referenced paths. The preview must show both literal Hosts and the `ProxyJump`
relation without displaying either key path. The runner verifies that no Host
is saved before the separate confirmation dialog is accepted.

After confirmation, Profile A must create exactly two encrypted Host records.
The runner links each opaque push envelope to its single commit receipt,
SQLite event, record head and stored envelope. Profile B is independently
enrolled and must receive those exact encrypted envelopes in its changes
response, decrypt both Hosts, and render the target with its `Via Jump Host`
relationship. Request/response bodies, server SQLite/WAL/SHM files, both
profiles' IndexedDB SQLite snapshots and server logs are searched for unique
config values and IdentityFile path markers. The test
also requires zero Relay ticket/WebSocket activity, zero browser page/console
errors and complete removal of the temporary browser/server/database fixture.
It uses `.example.invalid` targets without SSH credentials and never attempts
a connection.

Build the current Flutter Web release and server binary, install the pinned
Playwright dependency if needed, then run:

```sh
cd apps/client
flutter build web --release --no-web-resources-cdn
cd ../../integration/web
npm run test:openssh-config-import
```

The runner builds the locked Rust server binary and requires Node.js 18+,
Playwright Chromium, Python 3 for read-only SQLite inspection, and the server
crate dependencies. Its server, account, database, logs and browser contexts
are isolated under one temporary root and removed during teardown.

## tmux SSH fixture PTY parser smoke

`test:tmux-ssh-fixture` is a no-browser fixture check. It starts an isolated
OpenSSH server/account and tmux socket, verifies the version and session
management commands, opens a real SSH PTY attachment, checks that the fixture
parser maps the attached client to the correct session, then detaches, removes
the session, and verifies cleanup. It requires Linux root, OpenSSH, `sshpass`,
`runuser`, `/run/sshd`, tmux, and an RFC1918 private IPv4 interface. Its output
contains only status booleans/counts, and it removes the run-specific account
and fixture files on completion.

```sh
npm run test:tmux-ssh-fixture --prefix integration/web
```

## Relay interruption cleanup acceptance

`WEB-RELAY-CLEANUP` starts the same isolated Bastion/Target fixture, waits for
the test's ready marker, interrupts the Relay E2E process, and verifies the
expected interrupt exit code and removal of temporary fixtures. This checks
the signal-handler cleanup path independently from a normal successful Relay
run. Its current v1.34 acceptance passed.

```sh
npm run test:relay-cleanup
```

## KnownHost cross-device acceptance

`WEB-KNOWNHOST-01` uses two isolated Web profiles enrolled into one disposable
Vault. Profile A first approves a host key; Profile B pulls it and reaches the
SSH authentication boundary without another prompt. The test then blocks only
`/sync/changes` and `/sync/conflict-changes` reads for both profiles while SSH
Relay stays online. Each profile encounters a different previously unseen
endpoint/key, explicitly confirms the first-seen key, queues one encrypted
local create and stops that SSH handshake. While offline, there are no server
sync writes. Once reads are restored, the runner observes exactly two encrypted
creates, both profiles pull them, show `CONFLICT — CONNECTIONS BLOCKED`, and
reject both keys before SSH authentication.

Profile A revokes one exact endpoint/fingerprint record through its accessible
action. The signed encrypted update advances that existing record head and
adds exactly one commit, version, event and receipt; Profile B pulls it, both
profiles clear the conflict and verify the retained key, while the revoked key
remains rejected. Profile A then revokes the retained record in the same way,
Profile B pulls without adding a write, and A explicitly reapproves the
previously revoked fingerprint as a new record. That approval adds exactly one
matching commit set; Profile B pulls and accepts the selected key while still
rejecting the other revoked key. A later unrelated replacement key is also
rejected. The Settings rows use state-keyed explicit Semantics labels so
`TRUSTED`, `CONFLICT`, `QUEUED — NOT TRUSTED` and `REVOKED` update in the Web
accessibility tree with their visible state.

### Older KnownHost readers

KnownHost reapproval after revocation uses schema v2 and carries the exact
`(record_id, revision_id)` heads the approving client observed. A strict schema
v1 client rejects the v2 fields after decrypting the record. The opaque Vault
server has no client capability negotiation and cannot produce per-device
KnownHost payloads, so a v2 reapproval cannot be made readable by those clients
without dropping the causal references or weakening the current client's
revoked-key fail-closed check. Keep every device that must make KnownHost trust
decisions on a schema-v2-capable client before performing a reapproval; an older
reader must treat the v2 record as unavailable and upgrade before it can
evaluate trust again.

`apps/client/test/legacy_known_host_v1_interop_test.dart` exercises actual
signed, encrypted Vault envelopes through decrypt/readback, then feeds the
decrypted payload to an independent frozen strict-v1 reader fixture. It proves
that v1 payloads still parse and a v2 reapproval is rejected rather than
silently accepted after dropping `observed_revocations`. The fixture models the
v1 payload contract; this repository does not contain an archived historical
client binary, so this is not a full old-build/device acceptance run.

SQLite/WAL/SHM checks ensure fixture endpoint and fingerprint markers remain
encrypted. The server Relay allowlist contains only the fixture's `eth0`
address and two SSH ports. SSHD disables root and password login, TTY,
forwarding, and tunnels; the synthetic SSH username is invalid, so the test
covers host-key validation before authentication and never opens a shell.
Browser state, database, generated keys, and logs are temporary and removed on
exit. Build the current Web release with `flutter build web --release --no-web-resources-cdn`;
same-origin CanvasKit is required by the strict CSP.
The runner requires root, `sshd`, `ssh-keygen`, the existing `/run/sshd`, `ip`,
and a non-loopback `eth0` IPv4 address. The offline exception is first-seen
only; remote approvals and revocations cannot be checked until reconnect, and
the active SSH attempt remains stopped until a fresh sync confirms trust.

```sh
npm run test:knownhost-sync
```

## Vault-synced workspace preference acceptance

`WEB-PREFERENCE-01` uses the current Flutter Web release bundle and two
isolated Chromium profiles enrolled into one disposable Vault. Profile A sets
its default workspace section to Snippets, saves it as a Vault-encrypted
record, and synchronizes. Profile B pulls the opaque envelope, then locks,
reloads, signs in again, and must open the Command snippets workspace. The test
checks the push and pull envelopes, server record/event/receipt rows, and the
temporary SQLite database plus WAL files for preference plaintext markers.
This is separate from `test:local-profile`, which covers LocalVault-only
Preferences and asserts that they make no API requests. The isolated server,
database, browser state and generated credentials are removed at exit.

```sh
npm run test:vault-preferences
```

## Server Vault Groups acceptance

`WEB-GROUPS-01` uses two isolated Chromium profiles enrolled in one disposable
Vault. Profile A creates a Credential, a parent Group, a child Group under it,
a Bastion Host, and a Target Host assigned to the child Group and referencing
the Bastion as its single Jump Host. Profile B pulls and decrypts the records;
the UI assertions check the Group parent relationship, Host count, Jump Host
relationship and inherited Credential resolution. B clears the Target's Jump
Host and renames the child Group, pushes both updates, and A must receive and
render them. Delete confirmation verifies a Group cannot be deleted while a
Host or child Group still references it.

The runner associates each stage with the exact opaque record IDs and operation
envelopes. It verifies create/update revisions, receipts, change events, record
heads, ciphertext-only envelope shapes, absence of synthetic Group, Host and
Credential plaintext markers in push/pull payloads and SQLite/WAL/SHM files,
and no delete operation for referenced records. The server does not parse
`jump_host_id`; it stores only the opaque client-encrypted Host envelope. The
v1.34 acceptance passed. The disposable server, database, browser state, and
generated credentials are removed at exit.

```sh
npm run test:groups
```

## Trusted device capability reports

The Trusted devices page verifies each signed `capability_report` against the
current account ID, device ID and enrolled device signing public key before it
shows the reported record schema, attachment manifest versions and maximum
attachment size. A missing report is shown as `not reported`; an invalid,
tampered or misbound report receives a fixed unverified label without exposing
its claimed values. The widget test covers a valid signature, an absent report,
and a report whose attachment limit was altered after signing.

```sh
cd apps/client
flutter test --no-pub test/devices_widget_test.dart
```

The focused device widget file passed **7/7**; the full Flutter suite later
passed **1,055 tests with 3 skipped**. The current Web Release bundle
(`main.dart.js` SHA-256
`71b1ced0d7954073c2f1cca0354c65b614c59d344bfe684f7b0ccf02c74b4c1e`) was
rebuilt after this UI change. The device-report scenario is covered by Flutter
widgets, not a separate Chromium journey.

## Administrator per-account Relay policy acceptance

`WEB-ADMIN-RELAY-POLICY-01` now covers both the instance-wide Settings policy
and the account-scoped Relay panel on an active, non-current account card. The
runner first verifies that the invited target and current administrator both
inherit the instance selection. The target account panel must make no user
policy request while collapsed; expanding it loads the account and instance
revisions and renders the inherited state. Saving a disabled account selection
must create a user override through the UI, with both
`expected_revision` and `expected_instance_policy_revision` in the strict PUT
body. Resetting the override must return the target to inherited state without
changing the current administrator's account policy.

The runner injects a competing account write and a separate instance policy
write. Each stale UI save must receive HTTP 409 while retaining the edited
checkbox, CIDR and port draft. Reloading the latest policy must retain the
draft; after the instance conflict is resolved by reloading, the UI resets the
account to inherit. The final admin audit read checks the exact number and
resource types of successful policy writes, confirms stale writes created no
ledger entries, and verifies user resource IDs are opaque HMAC identifiers.
Member Settings must hide both Relay policy panels, and member GET/PUT/DELETE
requests to the selected user's policy endpoint must return 403. Policy DTOs,
audit rows, browser errors and rendered text are checked for account credentials
and private server paths.

Build the current Flutter Web release bundle and install the pinned Playwright
dependency as described above, then run:

```sh
npm run test:admin-relay-policy
```

The runner builds the Rust server, then starts a disposable instance with
private deployment limits. It requires Node 18+, Cargo, Playwright Chromium,
and an RFC1918 IPv4 address on `eth0`; browser requests are restricted to the
fixture origin. The Web bundle and server must both include the per-account
Relay PUT contract carrying `expected_instance_policy_revision`. This slice is
accepted on the current release bundle (`main.dart.js` SHA-256
`71b1ced0d7954073c2f1cca0354c65b614c59d344bfe684f7b0ccf02c74b4c1e`):
`TMPDIR=/tmp/aterminal-tests npm_config_cache=/tmp/aterminal-npm-cache CARGO_BUILD_JOBS=2 npm run test:admin-relay-policy --prefix integration/web` exited 0
with `WEB-ADMIN-RELAY-POLICY-01 passed`. The browser run verified lazy account
policy loading, inherited state, dual-revision save, independent stale-account
and stale-instance 409 responses retaining the draft, reload and reset-to-inherit,
current-admin isolation, member/anonymous access gates, opaque HMAC audit IDs,
privacy scans, self-only CSP, zero external requests/page errors, and fixture
cleanup. See `docs/WEB-ACCEPTANCE-MATRIX.md` for scope and known limitations.

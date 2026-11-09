# Deployment reference

The server image builds the API only. The browser frontend is built separately from the sibling Web repository. Start with the [English installation guide](../docs/INSTALLATION.en.md) or [中文安装指南](../docs/INSTALLATION.md) for API + Web, first account, HTTPS and temporary sharing. This page retains detailed operational/optional-overlay procedures.

The following minimal commands are **API-only**; they do not serve the browser UI. For a Web or HTTPS stack, retain all of its active overlays in every command.

From the repository root:

```sh
cp deploy/.env.example deploy/.env
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --build
docker compose --env-file deploy/.env -f deploy/compose.yaml exec -T server \
  /usr/local/bin/atermius-server bootstrap
```

Store the one-time bootstrap token printed by `bootstrap` securely, then enter
it in the first-account setup screen. The token is consumed by the first
successful account registration. Do not run `bootstrap` again after it has
been consumed. Inspect readiness with:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml ps
curl --fail http://127.0.0.1:8080/health/ready
```

## PostgreSQL runtime and offline restore cutover

PostgreSQL mode is an opt-in single-server deployment. It uses a dedicated
schema in the source database, a separately configured restore-stage database,
the shared encrypted-backup directory/key, and the filesystem object-store
overlay. Provision two 32-byte PostgreSQL runtime keys as owner-only regular
files for UID 10001. Their parent directory must be owned by UID 10001 with
mode 0700; each file must have mode 0600. Keep the source keys outside the
backup directory and instance data volume:

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-pg-keys
sudo install -m 600 -o 10001 -g 10001 /secure/provisioned/instance-ed25519.key \
  /srv/atermius-pg-keys/instance-ed25519.key
sudo install -m 600 -o 10001 -g 10001 /secure/provisioned/auth-rate-limit.key \
  /srv/atermius-pg-keys/auth-rate-limit.key
```

Set the PostgreSQL values shown in [`deploy/.env.example`](.env.example) in
`deploy/.env`, then restrict the file to its owner (`chmod 600 deploy/.env`).
The source URL, restore-stage URL, and restore-next URL must name three
different databases. Keep URL credentials out of shell history, process
arguments, terminal output, and logs. The stage and next databases need to be
reachable by the service role and empty before a restore is prepared. Before
assigning a database as either target, use a protected PostgreSQL admin client
to confirm it has no application schema or user relations in `public`, and
that the service role can create the required schema and objects. The
coordinator checks that the URLs differ; it does not connect to or prove that
the next target is empty.

Apply exactly these Compose files in this order for the supported runtime:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.backup.yaml \
  -f deploy/compose.object-store-filesystem.yaml \
  -f deploy/compose.postgres.yaml up -d --build
```

Apply ordered PostgreSQL migrations 0001–0028 to the dedicated schema before
serving traffic. The runtime does not migrate its shared schema at startup.
See the [PostgreSQL schema upgrade runbook](../docs/runbooks/postgres-runtime-upgrade.md)
and the [backup and restore runbook](../docs/runbooks/instance-backup-restore.md)
for readiness requirements, archive staging, and recovery boundaries. The
offline coordinator currently accepts only the four Compose files above; it
fails closed if the running container was created with Caddy, MFA, push,
monitoring, or another additional overlay. Do not use it for such a stack.

Run the coordinator on the Docker host through a local Unix-socket Docker
context. It rejects remote contexts and `DOCKER_HOST` values that are remote
or differ from that selected local socket because restore receipts, keys and
bind sources are verified on the machine running the script.

After an allowlisted administrator has prepared and reviewed a PostgreSQL
restore stage in Web Settings, pass its canonical job UUID to the coordinator.
Drain external ingress yourself and stop every other process or scheduled job
that can write to any of the three PostgreSQL databases. The tool does not
control a reverse proxy or open traffic. Run the operations from the
repository root:

```sh
python3 deploy/pg_restore_cutover.py apply --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
python3 deploy/pg_restore_cutover.py status --job-id <restore-job-uuid>
```

`apply` stops and recreates only the Compose `server` service. It moves the
stage PostgreSQL URL, staged object-store root, and restored instance keys
together, checks readiness and instance identity/generation, then records the
activation marker against the stage receipt. If a pre-activation step fails,
the rollback path fences the stage against later activation before restoring
the source configuration. `recover` resumes the durable cutover or rollback
state after process interruption:

```sh
python3 deploy/pg_restore_cutover.py recover --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
```

Use explicit rollback only while the activation marker has not been committed:

```sh
python3 deploy/pg_restore_cutover.py rollback --job-id <restore-job-uuid> \
  --confirm-ingress-drained --confirm-all-pg-writers-stopped
```

The PostgreSQL target marker serializes activation and rollback fencing under
one advisory lock. A stage with a committed activation marker cannot be
rolled back by this tool. Once client traffic or any writer reaches the
promoted database, the old source can diverge; keep it, its object data, the
source runtime keys, the archive, and the staged object files for recovery, and
do not switch back as an ordinary rollback. Plan any failback as a separate
restore/cutover. The coordinator never deletes a database, archive, key, or
volume and never changes the ingress state. Its mode-0600 environment backup
contains the original connection strings; protect `deploy/.pg-restore-cutover`
as sensitive operator state and retain it until recovery and backup-retention
policy permit removal.

The current acceptance covers **29/29** mocked Compose state transitions, a
local-context Compose render with all six critical mounts, and a real
PostgreSQL **17.11** encrypted-archive activation/rollback-fence test.
The PG assertions cover idempotent fencing, activation refusal after fencing,
and discard refusal after activation. The locked serial Rust suite passed
**304 library / 76 ignored and 7 binary tests**, plus migration, OpenAPI,
WebSocket and doc targets; formatting and server build passed. The acceptance
does not claim that this coordinator has been run against a live Compose
deployment, external ingress, an HA topology, or an additional Compose overlay.

## Optional Caddy HTTPS edge

For a deployment that needs browser access from other machines, Caddy can
terminate HTTPS and proxy the complete application origin. The base Compose
file remains unchanged: without the edge overlay, the server is still
published on loopback port 8080. With the overlay, Compose removes that server
port mapping and publishes only Caddy on HTTP/HTTPS; Caddy and the origin share
the dedicated `caddy-backend` network. The origin also remains on the default
Compose network, while Caddy is not attached to it. Caddy forwards the request
host, scheme and direct peer address, and its `reverse_proxy` handler supports
the existing WebSocket upgrade paths without a separate route. The overlay
requires Docker Compose 2.24 or newer for its explicit port-list reset.

Set the DNS name, ACME contact and exact browser origin in `deploy/.env`:

```dotenv
ATERMIUS_CADDY_DOMAIN=termius.example.org
ATERMIUS_CADDY_ACME_EMAIL=admin@example.org
ATERMIUS_PUBLIC_ORIGIN=https://termius.example.org
```

Point the domain's A/AAAA records to the host and allow inbound TCP 80/443 and
UDP 443 if HTTP/3 is desired. The stock Caddy image uses its built-in ACME
issuers; the domain and contact are supplied through Compose environment
configuration. This overlay does not install a DNS-challenge provider plugin.
Use the exact external origin in `ATERMIUS_PUBLIC_ORIGIN`, including a
nonstandard port if one is configured. Apply the overlay with:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.caddy.yaml up -d --build
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.caddy.yaml ps
```

The `server` healthcheck verifies the origin and database. The `edge`
healthcheck makes an HTTPS request through Caddy to `/health/ready`, so a
healthy origin does not imply that the browser-facing proxy is healthy. Check
the `edge` health state and the external HTTPS readiness URL when monitoring a
deployment. In edge mode the origin port is not published on the Docker host.
Apply any other optional Compose overlays alongside both base and edge files.

The local edge acceptance uses Caddy's private internal CA, performs a
certificate-verified HTTPS readiness request and a WebSocket Relay echo, then
checks origin/proxy health separately while stopping each component. It is a
loopback test only; it does not claim real ACME issuance, cloud-provider,
firewall, DNS, or public-network acceptance:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q integration/test_compose_caddy_edge.py
```

The default per-account limit is 50 active Vault memberships, including Vaults
in deletion grace; pending invitations do not use a slot until accepted. The
default per-Vault limit is 100 active or invited members; revoked members do
not use a slot. Set `ATERMIUS_MAX_VAULTS_PER_USER` or
`ATERMIUS_MAX_MEMBERS_PER_VAULT` in `deploy/.env` to adjust these limits. The
accepted ranges are `1`–`4096` Vaults per account and `1`–`1000` members per
Vault. Invalid or out-of-range values fall back to the corresponding default
at server startup. The limits are loaded at startup, so restart the server
after changing them.

Anonymous Recovery start also has a global cap of 10,000 live challenges.
Live means `expires_at` is later than the current time and the challenge is
unconsumed; configured-account and NULL-owner decoy rows both count. Set
`ATERMIUS_MAX_ACTIVE_RECOVERY_CHALLENGES` in `deploy/.env` to an integer from
1 to 100,000. Invalid or out-of-range values use the 10,000 default. When the
cap is full, `/auth/recovery/start` returns the generic `429 RATE_LIMITED`
response with `Retry-After` based on the next live challenge expiry, and does
not insert a challenge. The setting loads at startup, so restart the server
after changing it.

## Mobile background sync hints

FCM HTTP v1 and Apple Push Notification service (APNs) are independent optional
providers. Enable one or both with their Compose overlays. A missing or invalid
provider configuration disables registration for that provider and returns
`503 PUSH_DELIVERY_DISABLED` without storing its submitted token. Endpoint
deletion remains available. Push sends only generic wake-up hints; WebSocket
and polling sync continue to be the source of truth. An overlay's required
environment fields must be present before Compose will start that provider;
leaving an overlay out disables only that provider.

To enable FCM, provision a Google service-account JSON file for a Firebase
project that has FCM HTTP v1 enabled. The server reads only `type`, `project_id`,
`client_email`, and `private_key`; it ignores any credential-file `token_uri`
and uses fixed HTTPS Google OAuth and FCM endpoints. Redirects and proxy
environment settings are disabled for these requests. The file must be an
absolute, owner-only regular file, not a symlink, owned by the server's UID
10001, mode 0600, with one hard link, and no more than 16 KiB. Keep it outside
the data volume and never place its contents in `deploy/.env`.

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-fcm
sudo install -m 600 -o 10001 -g 10001 /dev/null \
  /srv/atermius-fcm/service-account.json
sudoedit /srv/atermius-fcm/service-account.json
```

Set `ATERMIUS_FCM_SERVICE_ACCOUNT_HOST_FILE` in `deploy/.env` to the host path
of that file, then apply the FCM overlay and recreate the service:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.push-fcm.yaml up -d
```

The overlay mounts the service-account file read-only. Provider configuration
loads at startup, so recreate the service after changing the credential file
or environment. If the FCM configuration is missing or invalid, FCM registration
is disabled and existing WebSocket/polling sync is unaffected. The adapter can
send FCM's generic background data hint to FCM-registered Android or iOS apps.

To enable APNs, provision an Apple-issued APNs authentication key for the
application's bundle ID. The key must be a P-256 private key in `.p8` format.
Place it in a protected host directory outside the data volume, backups, and
source tree. It must be an absolute path to a regular, non-symlink file owned by
the server's UID `10001`, readable only by that owner (mode `0600`), with one
hard link. Do not put its contents or its private key value in `deploy/.env`,
Compose output, logs, or source control. For example, provision the directory
and copy the key from your protected secret manager:

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-apns
sudo install -m 600 -o 10001 -g 10001 /secure/provisioned/AuthKey_0123456789.p8 \
  /srv/atermius-apns/AuthKey_0123456789.p8
sudo stat -c '%U:%G %a %n' /srv/atermius-apns/AuthKey_0123456789.p8
```

Set these values in `deploy/.env`:

- `ATERMIUS_APNS_PRIVATE_KEY_HOST_FILE`: absolute host path to the `.p8` file;
  the container receives it at `/run/secrets/atermius-apns-auth-key.p8` through
  `ATERMIUS_APNS_PRIVATE_KEY_FILE`.
- `ATERMIUS_APNS_TEAM_ID` and `ATERMIUS_APNS_KEY_ID`: the Apple Team ID and key
  ID, each exactly 10 ASCII letters or digits.
- `ATERMIUS_APNS_TOPIC`: the app's validated bundle identifier, for example
  `com.example.atermius`.
- `ATERMIUS_APNS_USE_SANDBOX`: optional. Set it to `true` only for sandbox
  device tokens. When true, the sender uses the fixed Apple sandbox host
  `api.sandbox.push.apple.com`; when unset or false, it uses the fixed
  production host `api.push.apple.com`. The selected hostname cannot be
  overridden by environment proxy settings or a credential value.

Apply the APNs overlay and recreate the service:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.push-apns.yaml up -d
```

To run both providers concurrently, configure both credential files and all
provider values, then apply both overlays. Each key file is mounted read-only;
the FCM environment and mount remain present when APNs is added:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.push-fcm.yaml \
  -f deploy/compose.push-apns.yaml up -d
```

Provider configuration loads at startup. Recreate the service after changing a
key file, Team ID, key ID, topic, sandbox selection, or FCM service account.
Invalid APNs configuration disables only APNs registration; invalid FCM
configuration disables only FCM registration. Existing sync remains available.

Vault commits enqueue only a generic `{"type":"sync_available"}` payload for
other active member devices, in the same SQLite transaction as the Vault
commit. The worker sends after commit using a durable lease, bounded
exponential retry, and dead-lettering. Delivery is at-least-once; retries or a
restart can repeat the same generic hint, so clients should coalesce it and
use their ordinary authorized pull. The payload does not include Vault IDs,
record IDs, Host data, or envelopes. The recipient set is checked at enqueue
time. A generic hint queued while a device had active Vault membership can
still be delivered after that membership is later revoked; the outbox
deliberately does not retain Vault identity. Clients must always pull and
re-check current authorization before showing synced data.

Registered provider tokens are encrypted with a domain-separated key derived
from `auth-rate-limit.key`, which is also used by other server features. Keep
that key with the SQLite database in the protected backup/restore process; it
is not a push-only rotation key. A key/database mismatch fails closed and
parks token delivery. Restore the matching pair, or after push delivery is
configured, have devices register their current provider token again. Assess
any overall server-key rotation separately.

## Configure a Prometheus scrape credential

An allowlisted instance administrator can create a dedicated scrape credential
from **Settings → Prometheus scrape credential**. The value is shown once; the
service retains only a keyed verifier. Store the value in the scraper's
protected secret store and configure it as an HTTP `Authorization: Bearer`
credential for `GET /api/v1/admin/metrics`. Do not put it in a URL, dashboard,
checked-in config, command history, or logs. The credential grants access only
to that fixed, aggregate-only metrics endpoint; the ordinary administrator
session remains available for interactive Settings access.

Rotation immediately invalidates the previous value. Update the scraper's
protected secret promptly; reload it if that scraper requires one. There is
no overlap period. Revocation immediately disables scraping and can be done from
the same Settings card. The admin audit records the actor and action without
the credential.

## Collect metrics with the optional Prometheus overlay

`compose.prometheus.yaml` adds a pinned Prometheus 3.14.0 service without
changing the default deployment. Prometheus reaches the server only on the
private `metrics` network and scrapes the fixed
`GET /api/v1/admin/metrics` endpoint. The server remains attached to its
normal Compose network too, so enabling collection does not remove its
existing outbound connectivity. Prometheus stores data in a separate named
TSDB volume with its default 15-day retention. The unauthenticated web UI and
API are published on the host only at `127.0.0.1`; inside Compose they listen
on port 9090 on the project bridge. The scrape itself uses the separate
internal `metrics` network; the project bridge contains only the server and
Prometheus services in this deployment. Use an authenticated proxy for remote
access. The Prometheus lifecycle reload endpoint is not enabled.

The fixed metric `atermius_backup_last_success_timestamp_seconds` records the
Unix timestamp of the last successful local encrypted archive creation, or
`0` when this data directory has no recorded success. It reads the private
`backup-status.json` sidecar and carries no backup ID, path, size, or version.
The sidecar is not included in archives, so after restore the gauge stays at
zero until a new local archive succeeds. It does not prove replication or
restore verification; consult the backup job and replication status and run
isolated restore drills for those checks.

Create a host directory for the one-line token file before applying the
overlay. The pinned default image runs as UID/GID 65534 (`nobody`); on a normal
Linux Docker host, provision the directory as root-owned and group-readable by
that UID:

```sh
sudo install -d -o root -g 65534 -m 0750 /srv/atermius-prometheus-secrets
```

Set `ATERMIUS_PROMETHEUS_CREDENTIALS_HOST_DIR` in `deploy/.env` to that
directory. `ATERMIUS_PROMETHEUS_HOST_PORT` optionally changes the loopback UI
port (default `9090`). Use an approved secret manager or other protected
process to write the raw value returned once from **Settings → Prometheus
scrape credential** to `metrics-token`, owned by `65534:65534` with mode
`0400`. Keep the directory at mode `0750`; do not put the token in `.env`,
Compose config, environment variables, command arguments, shell history,
dashboards, or logs. The overlay mounts the whole directory read-only so
atomic file replacement remains visible inside the container. If Docker user
namespace remapping or rootless Docker is enabled, adapt host ownership to the
UID/GID mapping visible inside Prometheus and verify it can read the file
without making it world-readable.

Start the collector with the normal server:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.prometheus.yaml up -d --build
```

Check `http://127.0.0.1:9090/targets` and query a fixed series such as
`atermius_accounts{status="active"}`. The checked-in
[`prometheus.yml`](prometheus/prometheus.yml) uses
`authorization.credentials_file` for the bearer token. Prometheus reads that
file for every scrape, so token rotation requires an atomic replacement of
`metrics-token` in the mounted directory but no Prometheus restart or config
reload. There is no overlap period: the server invalidates the old token as
soon as the admin creates a replacement, so a short scrape failure can occur
before the new file is installed. Preserve owner/mode, then confirm the target
returns to `UP`. Send SIGHUP to Prometheus only when its configuration file
or checked-in alert rules change; do not enable the unauthenticated lifecycle
reload endpoint:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.prometheus.yaml kill -s HUP prometheus
```

If the credential is revoked, Prometheus reports failed scrapes until another
token is created and installed; remove the revoked file. Intentional removal
of the Prometheus TSDB is done with `docker compose down --volumes`.

The opt-in collector loads the read-only
[`atermius-alerts.yml`](prometheus/atermius-alerts.yml) rule file. It raises
`AtermiusMetricsScrapeUnavailable` when the Atermius metrics scrape has failed
continuously for 30 seconds; the Grafana dashboard shows the current firing
alert count. The rule uses only the fixed scrape target labels and does not
include account, Vault, credential, or request data. This Compose layer does
not send notifications by itself. The optional Alertmanager webhook overlay
below is separate. Validate rule edits with `promtool check rules`, then send
the SIGHUP shown above. Prometheus exposes active alert state at
`/api/v1/alerts`; its host port is published only on loopback.

See [Prometheus configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/),
[alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/),
[rules](https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/),
[HTTP API alerts](https://prometheus.io/docs/prometheus/latest/querying/api/#alerts),
[local storage](https://prometheus.io/docs/prometheus/latest/storage/), and
[Docker installation](https://prometheus.io/docs/prometheus/latest/installation/)
for the upstream configuration, TSDB, and image behavior.

## Send scrape alerts to an optional webhook

`compose.alertmanager.yaml` adds a single Alertmanager instance and replaces
the Prometheus config with a variant that sends alerts to the static Compose
target `alertmanager:9093`. Apply it after both the base and Prometheus files.
The server and Prometheus use the internal `metrics` network for scraping.
Prometheus and Alertmanager share a separate internal `alertmanager` network
for alert delivery; the server is not attached to that network. Alertmanager
uses its own regular `alertmanager-egress` bridge to send outbound webhook
requests, so other services cannot reach its unauthenticated UI/API through
that network. No Alertmanager port is published on the host. The default
server-only and Prometheus-only Compose configurations remain unchanged.

The pinned `prom/alertmanager:v0.34.1` config routes only the fixed
`AtermiusMetricsScrapeUnavailable` alert to the webhook. The rule fires after
the metrics scrape has failed continuously for 30 seconds. Its labels and
annotations contain only the alert name, fixed warning severity, fixed scrape
target labels, and a static summary; they do not contain account, Vault, SSH
credential, or request data. The webhook receiver has `send_resolved: true`,
so it receives both firing notifications and a resolved notification after a
successful scrape clears the alert. Alertmanager groups by alert name and may
repeat an ongoing firing notification according to its configured interval.
The notification endpoint must accept Alertmanager's JSON webhook payloads,
including resolved updates.

Provision a protected directory and a one-line `webhook-url` file. The URL can
grant access to the receiving service, so treat it as a secret. On a normal
Linux Docker host, the pinned container runs as UID/GID 65534; create the
directory and file so that only this service identity can read the URL:

```sh
sudo install -d -o root -g 65534 -m 0750 /srv/atermius-alertmanager-secrets
sudo install -m 0400 -o 65534 -g 65534 /dev/null \
  /srv/atermius-alertmanager-secrets/webhook-url
sudoedit /srv/atermius-alertmanager-secrets/webhook-url
```

Write only the receiver URL on one line. Set
`ATERMIUS_ALERTMANAGER_WEBHOOK_HOST_DIR` in `deploy/.env` to the directory,
for example `/srv/atermius-alertmanager-secrets`. Compose requires this value
when the overlay is enabled and provides no path default. The directory is
mounted read-only at `/run/atermius-alertmanager-secrets`; Alertmanager reads
the URL from `webhook-url` using `url_file`. Do not put the URL in Compose YAML,
`.env`, container environment, command arguments, shell history, or logs. If
Docker user-namespace remapping or rootless Docker is enabled, adapt ownership
to the UID/GID mapping visible inside the container while keeping the file
private.

Start the server, collector, and webhook delivery service together:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.prometheus.yaml \
  -f deploy/compose.alertmanager.yaml up -d --build
```

Confirm Prometheus is scraping the server at `http://127.0.0.1:9090/targets`,
then inspect Alertmanager logs with the same Compose files:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.prometheus.yaml \
  -f deploy/compose.alertmanager.yaml logs alertmanager
```

There is no Alertmanager host UI or API port. When rotating the webhook URL,
replace the protected file atomically with the new one-line value and restart
Alertmanager so it loads the updated URL. A scrape credential rotation can
temporarily fire the alert while the replacement `metrics-token` file is
installed. Once scraping recovers, Alertmanager sends the resolved update;
receiver-side processing and delivery guarantees depend on the webhook service.
Prometheus config or rule edits still require the SIGHUP procedure above; an
Alertmanager config edit requires restarting the Alertmanager service.

This overlay supports one local Alertmanager instance for the one local
Prometheus collector. It does not configure remote or multi-instance alert
aggregation, email, Slack, or any other notification integration. Keep the
Alertmanager notification state in its separate named volume when recreating
the container. Avoid `docker compose down --volumes` as a way to reset only
Alertmanager state because that command removes every volume in the stack.

See [Alertmanager configuration](https://prometheus.io/docs/alerting/latest/configuration/)
for webhook receiver and resolved-notification fields.

## View the optional Grafana instance dashboard

`compose.grafana.yaml` adds the pinned official Grafana 13.2.3 image and a
provisioned **Atermius Instance Overview** dashboard. Apply it after both the
base and Prometheus files; the base server-only deployment remains unchanged.
The nine panels include the current count of firing Atermius scrape alerts.
The dashboard uses only the fixed aggregate account, Vault, active-device,
stored-blob, upload-reservation, Vault-quota, Relay-policy, and scrape-health
series. It contains no account, device, Vault, Host, or request identifiers.

Create a private directory for the Grafana bootstrap password. The standard
Grafana image runs as UID 472 with primary GID 0, so on a normal Linux Docker
host the directory may be root-owned and executable only by that group, with
the password file readable only by UID 472:

```sh
sudo install -d -o root -g root -m 0750 /srv/atermius-grafana-secrets
sudo install -m 0400 -o 472 -g 0 /dev/null \
  /srv/atermius-grafana-secrets/admin-password
sudoedit /srv/atermius-grafana-secrets/admin-password
```

Use a unique, high-entropy value. Set
`ATERMIUS_GRAFANA_ADMIN_PASSWORD_HOST_DIR` in `deploy/.env` to that directory.
The whole directory is mounted read-only; the password itself is read through
`GF_SECURITY_ADMIN_PASSWORD__FILE` and is not placed in Compose environment
values. The value initializes the first Grafana administrator in the
persistent Grafana database. Change the password through Grafana's account
settings; update the protected file to the same value for a consistent fresh
Grafana database restore. The file must remain available when Grafana starts.
If Docker user-namespace remapping or rootless Docker is enabled, adapt host
ownership to the in-container UID/GID mapping while keeping the file private.

Start Prometheus and Grafana together:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.prometheus.yaml \
  -f deploy/compose.grafana.yaml up -d --build
```

Grafana login is required; anonymous access and self-service signup are
disabled. Its UI is published only on
`http://127.0.0.1:${ATERMIUS_GRAFANA_HOST_PORT:-3000}`. The Grafana database and
settings use a separate named volume. Provisioned dashboard and datasource
files are read-only; dashboard file changes are polled every 30 seconds, and
the datasource is reconciled on Grafana startup. The provisioned dashboard is
not editable in the UI; update its JSON and Grafana loads the change on the
next poll. Recreate Grafana after changing datasource provisioning.
The overlay disables Grafana's bundled-plugin startup auto-update: the image
uses a read-only root filesystem, and upstream has documented plugin
unregistration when an attempted update cannot write to the bundled plugin
directory. Upgrade Grafana by changing the pinned image tag after reviewing
the release and rerunning the Compose acceptance.
Grafana joins the Compose `metrics` network for its Prometheus datasource and
the project bridge for loopback host-port publishing. Use an authenticated
proxy for remote access rather than publishing port 3000 on a public interface.

The Grafana password is distinct from the Prometheus scrape credential. The
dashboard and datasource provisioning do not store or receive that scrape
credential; Prometheus alone reads its protected `metrics-token` file.
See the [Grafana Docker secret-file configuration](https://grafana.com/docs/grafana/latest/setup-grafana/configure-docker/),
[file provisioning guide](https://grafana.com/docs/grafana/latest/administration/provisioning/),
[13.2.3 release](https://github.com/grafana/grafana/releases/tag/v13.2.3), and
the upstream [read-only bundled-plugin update report](https://github.com/grafana/grafana/issues/132528)
for the pinned image and provisioning behavior.

Public self-service signup stays disabled. After the first account has
completed bootstrap, an operator can issue a one-time account invitation for
the intended normalized username:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml exec -T server \
  /usr/local/bin/atermius-server create-account-invite --username 'person@example.com'
```

The command prints a bearer token once. Transmit it to that person out of
band, using a private channel, and do not commit it or copy it into tickets or
logs. It expires after seven days by default, is bound to the username, and is
consumed by that account's successful registration. The account invitation
grants only a personal vault; sharing an existing team vault requires a
separate owner-issued vault invitation.

## Store encrypted attachment objects on a dedicated filesystem volume

The optional `compose.object-store-filesystem.yaml` overlay stores new
client-encrypted attachment objects on a separate local Docker volume. Existing
SQLite-backed objects remain in SQLite, and each new upload continues through
the same authenticated API; the browser never receives the storage path or a
direct filesystem capability. Do not combine this overlay with
`compose.object-store-s3.yaml`; one server instance selects one external
attachment backend.

Apply it with the normal deployment:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.object-store-filesystem.yaml up -d --build
```

The overlay mounts the dedicated named volume at `/object-store` and sets
`ATERMIUS_OBJECT_STORE_BACKEND=filesystem` plus
`ATERMIUS_OBJECT_STORE_FILESYSTEM_ROOT=/object-store`. Set
`ATERMIUS_OBJECT_STORE_FILESYSTEM_VOLUME_NAME` in `deploy/.env` only when you
need a non-default Docker volume name. The runtime root must be an absolute,
pre-provisioned directory with no symlink in any path component, owned by the
server UID 10001 and restricted to that service. The Compose image prepares the
mount point for UID 10001; keep this volume separate from `/data`, backup
archives, and any host directory exposed to untrusted users.

The service creates a private `.atermius-store-id` marker containing the volume
identity. It rejects symlink/non-regular marker files and mismatched ownership,
permissions, or identity. If the database still references external objects,
replacing this volume with an empty one causes startup to fail closed. Do not
copy, edit, or delete the marker independently of a planned restore. Object
files use the generated path
`atermius/objects/v1/<instance-uuid>/<vault-uuid>/<object-uuid>/<upload-uuid>`;
the server walks this UUID-only path without following symlinks, publishes
immutable files atomically, and validates object size and SHA-256 before full
reads. Range requests read only their selected bytes. Remote deletion intents
remain durable and retryable until the file is safely removed.

Instance backup creation reads and verifies active filesystem objects into its
private SQLite snapshot, so the resulting `.atb` archive restores without the
object volume. If an object is missing, replaced by a symlink, non-regular,
truncated, or has a digest mismatch, archive creation fails without modifying
the source database. Do not restore only `/data` after losing the object
volume; restore from the self-contained instance archive instead.

The local-filesystem acceptance suite exercises the authenticated API against
the configured filesystem root, including path/symlink rejection, immutable
replay/conflict behavior, Range/If-Range, ACL, durable deletion retry and
offline archive restore. The Compose overlay was also started with a fresh
named volume: the service reached readiness as UID/GID 10001, the volume was
initialized to owner-only mode 0700, and the private store identity marker was
created as mode 0600. These checks do not involve an external cloud provider.
The separate S3-compatible backend is documented below.

To move existing attachment objects between SQLite, the filesystem volume, or
S3, use the offline journaled procedure in
[`docs/OBJECT-STORE-MIGRATION.md`](../docs/OBJECT-STORE-MIGRATION.md). Make and
verify a self-contained `.atb` backup first, stop the server, preserve the
source configuration while resuming a failed migration, and switch the normal
backend settings only after the migration command reports complete. Do not
combine filesystem and S3 overlays for the serving process; the migration
command accepts its destination through separate
`ATERMIUS_OBJECT_STORE_MIGRATION_TARGET_*` settings.

## Store encrypted attachment objects in S3-compatible storage

The optional `compose.object-store-s3.yaml` overlay stores new client-encrypted
attachment objects in an S3-compatible bucket. The server continues to accept
and serve existing SQLite-backed objects, so enabling the overlay does not
move existing rows. New uploads are proxied through the server; browsers never
receive S3 credentials, endpoints, keys, or presigned URLs. This object backend
is separate from `compose.backup-s3.yaml`, which replicates complete encrypted
`.atb` instance archives.

Provision a credentials JSON file outside the instance data directory. It must
be owned by service UID 10001, mode 0600, a regular file with one hard link, and
must not be a symlink. The strict accepted shape is:

```json
{"access_key_id":"<access-key>","secret_access_key":"<secret-key>","session_token":"<optional-session-token>"}
```

`session_token` may be omitted for long-lived credentials. Unknown JSON fields
are rejected. The service reads only this file and does not fall back to AWS
environment variables, profiles, or instance roles. Keep the credentials file
separate from the encrypted object bucket and database.

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-object-store-s3
sudo install -m 600 -o 10001 -g 10001 /dev/null \
  /srv/atermius-object-store-s3/credentials.json
sudoedit /srv/atermius-object-store-s3/credentials.json
```

Set `ATERMIUS_OBJECT_STORE_S3_BUCKET`, `ATERMIUS_OBJECT_STORE_S3_REGION`, and
`ATERMIUS_OBJECT_STORE_S3_CREDENTIALS_HOST_FILE` in `deploy/.env`. The endpoint
and prefix are optional. A custom HTTP endpoint is allowed only for loopback
fixtures; remote endpoints must use HTTPS. The credentials file is mounted
read-only. Apply the base deployment and object-storage overlay:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.object-store-s3.yaml up -d --build
```

The generated object key is
`<prefix>/atermius/objects/v1/<instance-uuid>/<vault-uuid>/<object-uuid>/<upload-uuid>`.
The bucket policy should scope `s3:GetObject`, `s3:PutObject`, and
`s3:DeleteObject` to this deployment's object namespace. Grant `s3:ListBucket`
only for the same prefix so the service can distinguish a missing object from
an authorization failure during retries and cleanup. The backend uses
conditional `If-None-Match: *` writes and ETag-conditional deletes; choose a
provider that supports those operations and byte-range GETs. It does not use
multipart operations for attachment objects.

The server checks the configured bucket/region/endpoint identity at startup and
fails closed when stored S3 metadata exists but the backend is unavailable or
misconfigured. `ATERMIUS_OBJECT_STORE_BACKEND` defaults to `sqlite`; setting
S3 variables while that backend is selected is rejected. Existing SQLite
objects stay in SQLite and new completed uploads use S3. Switching back to
SQLite requires restoring a self-contained instance archive: archive creation
downloads and verifies each active S3 object into its private SQLite snapshot,
then emits the existing `.atb` format. Missing or corrupt remote objects stop
archive publication without changing the source database. The restore path
serves hydrated attachment objects without access to the original S3 service.

The S3-compatible acceptance suite uses a strict loopback SigV4 fixture and
does not claim live-provider compatibility. Before using a provider in
production, verify its conditional write/delete, metadata, range, missing-key,
and credential policies. The deployment overlay and server configuration do
not enable or configure encrypted archive replication; that requires the
separate backup overlays documented below.

## Instance administration

To enable instance-wide administration, set
`ATERMIUS_ADMIN_USERNAMES` to a comma-separated list of already enrolled,
normalized lowercase usernames (email-like values), for example
`ATERMIUS_ADMIN_USERNAMES=admin@example.com,ops@example.com`, then recreate the
server container so it reads the updated environment. Leave the value empty to
disable instance-admin access; an invalid list also fails closed and disables
access for all accounts. `GET /api/v1/me` reports the caller's
`policy.instance_admin` flag; the overview API still requires the caller's
current active authenticated session. A missing, invalid, expired, or revoked
session receives HTTP 401, while an authenticated account outside the
allowlist receives HTTP 403 `INSTANCE_ADMIN_REQUIRED`.

`GET /api/v1/admin/overview` returns instance-wide aggregate counters and the
effective Relay policy. Counters do not identify accounts or Vaults, and the
response never includes Vault names, record contents, SSH data, ciphertext, or
other client payloads. This endpoint is read-only.

Per-Vault quota management is available in the instance-admin API. It provides
`GET /api/v1/admin/vaults?limit=50&offset=0` (limit 1–100,
offset 0–1,000,000) and
`PUT /api/v1/admin/vaults/{vault_id}/quota` with a `quota_bytes` integer from
1 byte through 1 TiB; zero returns `INVALID_QUOTA`. Quota usage is completed
blob bytes plus reservations for open, unexpired uploads. Only active Vaults
can be changed, and the requested quota cannot be below current usage.
Every successful quota set creates an instance audit event with the
authenticated actor and an HMACed Vault resource ID. These routes expose
per-Vault IDs, owner usernames and storage metadata to allowlisted admins, but
no Vault names or client payloads. This remains a
narrow operator API, not a complete admin panel.

Instance audit review is implemented and verified. Its contract is
`GET /api/v1/admin/audit?limit=100&cursor=<opaque>`: limit defaults to 100 and
is capped at 200. It returns only instance-scope events, never the separate
account/Vault feeds, and its HMAC cursor is bound to the admin account,
instance generation and a fixed page high-water mark. The event resource ID is
HMACed, so this feed does not expose raw Vault IDs; rows also omit usernames,
addresses and client payloads. Invalid pagination returns 400
`INVALID_LIMIT`, invalid cursors return 400 `INVALID_AUDIT_CURSOR`, expired
generation cursors return 410 `AUDIT_CURSOR_EXPIRED`, missing sessions return
401 and non-allowlisted accounts return 403. The instance event sequence uses
a partial SQLite index for stable event-order pagination as the audit table
grows. See `docs/IMPLEMENTATION-STATUS.md` for current test evidence and
remaining administrator controls.

Allowlisted instance administrators can list bounded account metadata at
`GET /api/v1/admin/accounts`, inspect a user's session/device metadata at
`GET /api/v1/admin/accounts/{user_id}/sessions`, change active/disabled account
status with `PUT /api/v1/admin/accounts/{user_id}/status`, and revoke one or all
sessions. Disabling an account atomically revokes every existing session while
preserving devices, Vault membership, and encrypted data. Enabling never
restores a prior session; the user must log in again. Administrators cannot
target their own account/session, and accounts already in deletion grace stay
under the account-deletion lifecycle. The UI and API omit token hashes, source
addresses, password material, and client payloads; successful changes enter
the instance-scope audit feed with an HMACed account resource ID.

## Optional TOTP MFA key

TOTP MFA is disabled for an account until the operator configures its dedicated
seed-encryption key. Keep this 32-byte key outside the server data directory
and outside the encrypted instance archive; the archive stores the SQLite seed
envelope, not the key that opens it. Create an owner-only directory and file
owned by the container service UID (10001):

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-mfa-key
umask 077
head -c 32 /dev/urandom > /srv/atermius-mfa-key/atermius-mfa.key
sudo chown 10001:10001 /srv/atermius-mfa-key/atermius-mfa.key
chmod 600 /srv/atermius-mfa-key/atermius-mfa.key
```

Keep independently protected offline copies of this exact key. Set
`ATERMIUS_MFA_KEY_HOST_DIR` in `deploy/.env`, then include the MFA overlay when
starting the service:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.mfa.yaml up -d
```

The overlay mounts only the key file read-only at
`/mfa-key/atermius-mfa.key`; the default Compose stack does not mount an MFA
secret. A configured missing, malformed, symlinked, or non-private key fails
server startup closed. If the environment setting is omitted while MFA rows
exist, password login can still issue the usual short-lived factor challenge
and a single-use recovery code can complete it. TOTP verification, enrollment,
recovery-code rotation, and TOTP disable return the fixed
`MFA_KEY_UNAVAILABLE` response until the original key is restored. Losing the
key permanently makes stored TOTP seeds unrecoverable; recovery codes preserve
login only during normal operation and do not reconstruct the TOTP seed. Back
up and restore the key separately from the encrypted archive, and restore the
same bytes before starting a restored instance. Restore keeps enabled TOTP
seeds but advances their replay marker, deletes pending setup/challenges, and
consumes every recovery code from the restored snapshot. After restoring the
key, users must wait for the next TOTP step to sign in and should rotate their
recovery codes. If the key is unavailable after restore, use full account
Recovery; the archived MFA codes have already been consumed. Key rotation is
available only as a server-stopped offline operation; follow the
[MFA seed-key rotation runbook](../docs/runbooks/mfa-seed-key-rotation.md).
Keep each old key paired with the encrypted backups that still require it.

### Manually request an encrypted backup

An allowlisted administrator can request the fixed `backup` action from
**Settings → Instance jobs**. The request enters the durable admin-job queue;
only one maintenance or backup job can be queued or running at a time. The
server chooses the archive filename and encrypts the archive with the mounted
operator key. The UI reports job state and fixed result categories but never
shows the configured paths, key material, or internal error text. A missing or
unsafe backup configuration is rejected with `BACKUP_NOT_CONFIGURED` before a
job is queued.

This is an opt-in feature. Create an owner-only archive directory and a
separate owner-only directory containing the 32-byte operator key, both outside
the server data directory. Set their host paths in `deploy/.env`, then apply
the backup overlay when starting the service:

```sh
sudo install -d -m 700 -o 10001 -g 10001 \
  /srv/atermius-backups /srv/atermius-backup-key
umask 077
head -c 32 /dev/urandom > /srv/atermius-backup-key/atermius-backup.key
sudo chown 10001:10001 /srv/atermius-backup-key/atermius-backup.key
chmod 600 /srv/atermius-backup-key/atermius-backup.key
```

Set `ATERMIUS_BACKUP_ARCHIVE_HOST_DIR` and
`ATERMIUS_BACKUP_KEY_HOST_DIR` in `deploy/.env` to those existing host
directories. To enable bounded cleanup, uncomment
`ATERMIUS_BACKUP_RETENTION_COUNT=10` in `deploy/.env` (or choose another
integer from **1** through **1000**). Leave the setting absent to disable
automatic cleanup. The backup overlay passes an absent value through as
unset; an explicitly empty value is invalid and makes server startup fail
closed. Do not add a fallback such as `${ATERMIUS_BACKUP_RETENTION_COUNT:-}`
to the Compose file, because that converts an unset value into an invalid empty
setting.

Start or recreate the server with both Compose files:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.backup.yaml up -d
```

The overlay mounts the archive directory read-write and the key directory
read-only. The server checks that configured paths are owner-only, point outside
`ATERMIUS_DATA_DIR`, and that the key is an owner-only regular file containing
exactly 32 bytes. The archive directory must have enough free space for each
new archive. When retention is enabled, hourly maintenance keeps the newest
configured number of eligible server-triggered archives. Eligibility requires
a regular file in the validated private archive directory whose generated name
matches a durable server backup-job ID. On Unix, the file must also be
service-owned, mode 0600 and have a single hard link. CLI-created archives,
symlinks, directories, and unrecognized files are left untouched. Pruning
and archive creation share the maintenance lock, so they do not overlap. The count may
temporarily exceed the limit between backups and the next maintenance pass.

Retention only removes local eligible archives; it does not copy them off-host,
or provide restore controls. Choose an off-host copy policy that accounts for
the configured local count, and periodically use `verify-backup` and the
isolated restore procedure below.

### Replicate encrypted archives to S3-compatible storage

Replication is an optional server-side extension of the private backup
configuration. It uploads the already encrypted `.atb` archive; the S3 target
never receives a plaintext database or backup key. The browser can read safe
copy state and choose a completed replica as a restore source, but it cannot
set the endpoint, bucket, prefix, or credentials.

Provision an owner-only credentials JSON file outside the data and archive
directories. It must be owned by service UID 10001, mode 0600, a regular file
with one hard link, and must not be a symlink. The accepted JSON shape is:

```json
{"access_key_id":"<access-key>","secret_access_key":"<secret-key>","session_token":null}
```

Use short-lived credentials when the provider supports them. The Rust service
uses only the static values read from this file; it does not fall back to
ambient AWS environment, profile, or instance-role credentials. Protect the
file separately from the encrypted archives and the 32-byte archive key.

Set the bucket, region, and host path in `deploy/.env`. `ENDPOINT_URL` and
`PREFIX` are optional; leave them commented out for AWS S3. A custom HTTP
endpoint is accepted only for loopback mock fixtures. Real custom endpoints
must use HTTPS. The endpoint is operator configuration and is never
administrator API input.

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-backup-s3
sudo install -m 600 -o 10001 -g 10001 /dev/null \
  /srv/atermius-backup-s3/credentials.json
sudoedit /srv/atermius-backup-s3/credentials.json
```

Add the `ATERMIUS_BACKUP_S3_BUCKET`, `ATERMIUS_BACKUP_S3_REGION`, and
`ATERMIUS_BACKUP_S3_CREDENTIALS_HOST_FILE` values. Optionally set
`ATERMIUS_BACKUP_S3_ENDPOINT_URL` and `ATERMIUS_BACKUP_S3_PREFIX`. The S3
configuration is all-or-none. Apply all three overlays:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml \
  -f deploy/compose.backup.yaml \
  -f deploy/compose.backup-s3.yaml up -d
```

The extra overlay mounts the credentials file read-only and gives the server a
fixed bucket and region. Its object key is generated by the server as
`<prefix>/atermius/v1/<instance-id>/<archive-id>.atb`; restore APIs accept only
the archive ID and `local` or `replica` source. Use an S3-compatible provider
that supports the following behavior:

- `HeadObject` returns object length and the `atermius-sha256` user metadata.
  A missing object must return 404. S3 returns 403 for a missing key if the
  role lacks `s3:ListBucket`, which the worker treats as a remote failure.
- The provider supports `GetObject`, `ListMultipartUploads`, multipart create,
  upload, complete and abort. `ListMultipartUploads` must paginate reliably;
  the worker uses it to find and abort abandoned uploads for its exact key.
- `PutObject` and `CompleteMultipartUpload` honor `If-None-Match: *`. A 412
  or multipart 409 causes a fresh `HeadObject` and complete download, digest,
  and archive-authentication check. The worker treats a byte-for-byte matching
  valid object as an idempotent success and rejects a different object without
  overwriting it.
- Single-part `PutObject` accepts the SHA-256 checksum header. The server also
  stores the SHA-256 in user metadata and reads the full object back after an
  upload; metadata alone is not trusted as an integrity check.

Grant the service role only bucket listing needed to distinguish a missing
key, multipart listing, object reads/writes, and multipart abort. Scope
`s3:ListBucket` and `s3:ListBucketMultipartUploads` to this deployment's
`atermius/v1/<instance-id>/` prefix where the provider supports prefix
conditions, and scope object actions to that instance subtree. The required
actions are `s3:ListBucket`, `s3:ListBucketMultipartUploads`, `s3:GetObject`,
`s3:PutObject`, and `s3:AbortMultipartUpload`. The service does not delete
completed remote archives. If using a provider lifecycle rule to remove
completed objects, remember that the local UI catalog records the last known
successful copy and the restore worker still verifies remote presence and
integrity before staging.

The outbox row is committed before each generated archive snapshot. It tracks
pending, running, retry, interrupted, and terminal state by archive ID; retries
always reconcile the same deterministic object key. A running row and any
unsuccessful terminal row protect its local archive from configured local
retention. Retryable remote errors use bounded exponential backoff, and
multipart upload IDs are persisted immediately. Configure the bucket to abort
incomplete multipart uploads after one day as a fallback for a process crash
between multipart creation and ID persistence. The normal worker also lists
and aborts incomplete uploads for a retried key before starting a new upload.
Use **Settings → Backup replication** to review only the configured flag,
waiting count, and latest fixed failure category. Paths, bucket, endpoint, keys,
object names, and provider errors are not returned.

An allowlisted instance administrator can enable scheduled backups from
**Settings → Instance backup schedule** after the private backup overlay is
configured. Choose an interval from **1 through 720 hours**; the default is
disabled. Schedule and occurrence state are stored durably with the instance
database. The server claims each due occurrence once, advances the next due
time in the same transaction, and creates an encrypted archive with the same
private archive directory and key as manual server backups. The Settings card
shows the next due time and most recent scheduled result, without displaying
filesystem paths or key material. Schedule updates, manual backups and
maintenance serialize with the shared operation lock. If the process stops
during a scheduled run, that run is marked interrupted on restart and is not
replayed; the next due occurrence remains scheduled. Hourly maintenance applies
configured retention to eligible manual and scheduled server archives.

Restoring the SQLite database also restores the enabled schedule and its
occurrence history. Configure the same private archive directory and key
before starting a restored instance with an enabled schedule; startup fails
closed if those private settings do not validate. Off-host copy and restore
remain operator workflows.

Disabling an account does not erase encrypted data already cached on its
devices and cannot close SSH connections opened directly by a client. Existing
Relay and notification connections recheck session state about every two
seconds; an already-authorized request may finish before the next check.

Set `ATERMIUS_PUBLIC_ORIGIN` to the exact browser origin that serves this
instance's Web client, for example `https://termius.example.org` or
`https://termius.example.org:8443`. Use only scheme, host, and optional port;
do not include a path or trailing slash. The server uses this exact origin for
API CORS preflights and strict WebSocket notification `Origin` validation. API
preflight allows `Authorization`, `Content-Type`, `X-Atermius-Capability-Marker`,
`Range`, `If-Range`, and `X-Content-SHA256`; object responses expose `ETag`,
`Content-Range`, and `Accept-Ranges` for verified range downloads. Other origins
are not allowed. If the setting is empty, cross-origin browser requests are
disabled, while same-origin and native clients continue to synchronize;
notification tickets/WebSockets stay disabled. Native clients can use the
notification channel only when their configured API origin exactly matches
this value; otherwise they fall back to polling.

The first Web terminal-collaboration slice is disabled by default. Enable it
with `ATERMIUS_TERMINAL_COLLABORATION_ENABLED=true` together with the exact
`ATERMIUS_PUBLIC_ORIGIN` above. It routes host-encrypted frames only to
explicitly approved Vault member devices; the server cannot read terminal
output, input is not supported, and sessions exist only in process memory.
Restarting the server ends all active collaboration sessions. This v1 feature
is single-process and Web-only; native clients and multi-server fanout are not
implemented.

The Flutter Web document and server responses use a Content Security Policy
that permits local application scripts and WebAssembly, blocks objects and
framing, and does not load third-party scripts. Its `connect-src` allows HTTP,
HTTPS, WS, and WSS schemes so a browser client can connect to a user-configured
self-hosted instance. The server also sends `X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy`, and a restrictive `Permissions-Policy`;
API and health responses are `no-store`, and Web assets are revalidated with
`no-cache`. Preserve these headers through the TLS reverse proxy. Configure
HSTS at the TLS terminator after HTTPS is enabled.

SSH Relay remains unavailable unless deliberately enabled with explicit
destination CIDR and port allowlists. To enable it, set
`ATERMIUS_RELAY_ENABLED=true`, set `ATERMIUS_RELAY_ALLOW_CIDRS` to a
comma-separated list of reviewed IP networks, set `ATERMIUS_RELAY_ALLOW_PORTS`
to a comma-separated list of exact destination ports, and configure the exact
TLS browser origin in `ATERMIUS_PUBLIC_ORIGIN`. For example, an SSH-only private
network policy could use `ATERMIUS_RELAY_ALLOW_CIDRS=10.40.0.0/16,fd12:3456:789a::/48`
and `ATERMIUS_RELAY_ALLOW_PORTS=22`. Both allowlists must be non-empty;
malformed or over-limit CIDR and port lists fail closed and leave Relay
disabled. The deployment accepts at most 256 CIDRs (each no longer than 64
bytes) and 4,096 destination ports. Keep this feature
off unless the deployment has a reviewed network policy and TLS-protected
public origin; setting `ATERMIUS_PUBLIC_ORIGIN` alone enables sync
notifications, not Relay.

The instance-admin Settings page can further narrow the active Relay CIDRs,
exact ports, and enabled state. These saved settings are durable in SQLite and
are revisioned to prevent concurrent administrator edits from silently
overwriting one another. They never replace the deployment variables: each
selected CIDR must be contained by a configured deployment CIDR, every
selected port must be in `ATERMIUS_RELAY_ALLOW_PORTS`, and the deployment must
still have the Relay enable flag, a public origin, and valid non-empty network
lists. If those deployment gates are later removed, Relay becomes unavailable
immediately; the saved administrator selection remains stored and can become
effective again only after the deployment gates are restored. If the operator
narrows the deployment CIDR or port lists, the saved policy remains visible
but server authorization intersects it with those current limits; the admin
can revise the saved selection to fit the new limits. The admin overview
reports effective state. A policy change invalidates unused Relay
tickets; established server Relay connections close on their next policy
authorization poll when disabled or outside the new allowed targets. Continue
to treat deployment environment settings as the outer network security
boundary.

The v1 Relay accepts IP literals and DNS hostnames in ASCII IDNA A-label form.
The normalized hostname is limited to 253 bytes; one trailing root dot may
make the request value 254 bytes. The service resolves A and AAAA once through
the configured system resolver, with a two-second timeout, at most 32 answers,
and at most 32 active blocking lookups. It checks every answer against the
effective CIDR and exact-port policy plus the special-address deny rules, then
encrypts one allowed IP into the one-use ticket. The socket connects to that
pinned IP without another DNS lookup. Hostnames are not stored in tickets,
audit events, or application logs; the system DNS resolver necessarily sees
the queried hostname, so configure that resolver according to your privacy
requirements. Loopback, unspecified, link-local, multicast, broadcast, and
known cloud metadata IPs (including Alibaba Cloud's `100.100.100.200`) are
rejected even when a configured CIDR includes them. Ports outside the exact
`ATERMIUS_RELAY_ALLOW_PORTS` list are rejected. Each target ticket is one-use,
expires within 30 seconds,
and is bound to the current active account, device, session, and target. The
WebSocket handshake requires exactly one `Origin` header matching
`ATERMIUS_PUBLIC_ORIGIN`; native clients must send the same configured origin.
Tickets are limited to 20 per user per minute; the service permits 256 Relay
connections globally and four per user. Each connection is capped at one hour
and 1 GiB total transferred data. A pending TCP/WebSocket write is closed if
it has not completed within 30 seconds; session checks continue while writes
are backpressured, and WebSocket/TCP shutdown is bounded to two seconds. Successful ticket issue and TCP connection
events appear in account audit metadata, which excludes target addresses,
ports, host names, ticket values, and SSH bytes. Pending ticket rows are pruned
by hourly maintenance or on subsequent ticket issuance after the rate window.

Per-user or per-group network policies are not implemented in this v1 scope.

Sync history is retained for 90 days by default. Set
`ATERMIUS_HISTORY_RETENTION_DAYS` in `deploy/.env` to a value from 1 through
3650 days to change the retention window; the service reads this setting when
it starts. A shorter window limits how far an offline client can replay its
change cursor before it must rebuild from a snapshot.

Vault deletion has a seven-day cancellation window by default. Set
`ATERMIUS_VAULT_DELETION_GRACE_SECONDS` to 60 through 7,776,000 seconds
(90 days) to change it. Completed or cancelled deletion audit rows are retained
for 365 days by default; set `ATERMIUS_AUDIT_RETENTION_DAYS` to 1 through 3650
days to change that window. Pending deletion rows are kept until they are
cancelled or purged, regardless of audit retention.

Account deletion has a seven-day cancellation window by default. Set
ATERMIUS_ACCOUNT_DELETION_GRACE_SECONDS to 60 through 7,776,000 seconds
(90 days) to change it. It uses the same terminal audit retention setting.

`GET /api/v1/audit` exposes paged control-plane metadata. Account events are
visible only to the account; vault events are visible to current active Owners
and Editors, while Viewers do not see them. The cursor expires when the server
generation changes, so clients should restart pagination. Audit retention uses
`ATERMIUS_AUDIT_RETENTION_DAYS` (365 days by default, 1 through 3650); hourly
maintenance removes older events. Entries contain opaque IDs and fixed action
labels only: no source IP, User-Agent, host, command, token, request body,
envelope or ciphertext. Permanent account purge clears actor IDs while keeping
the remaining audit metadata until retention expires.

Completed encrypted objects receive a seven-day orphan-collection grace by
default. Set `ATERMIUS_OBJECT_GC_GRACE_SECONDS` to 60 through 7,776,000 seconds
(90 days) to change it. Record revisions and conflict branches explicitly pin
their referenced objects; maintenance only removes objects whose deadline has
passed and that have no reference rows. Pre-migration blob objects have no GC
deadline and are retained indefinitely. Successful upload completion removes
temporary chunk payloads immediately.

Authentication limits use a separate fixed window (15 minutes by default) for
each endpoint and count by normalized username, username plus the TCP peer, and
TCP peer IP. The defaults are:

| Endpoint | Per username | Per username and peer | Per peer IP |
| --- | ---: | ---: | ---: |
| Login | 12 | 8 | 3000 |
| Prelogin | 30 | 20 | 6000 |
| Registration | 3 | 3 | 60 |

Set `ATERMIUS_AUTH_RATE_WINDOW_SECONDS` and the corresponding
`ATERMIUS_AUTH_{LOGIN,PRELOGIN,REGISTER}_{USER,PAIR,IP}_LIMIT` values in
`deploy/.env` to tune the policy. The window accepts 60–86400 seconds. The
peer-IP budgets are intentionally broad for installations where every client
arrives through one reverse proxy; the server buckets on its TCP peer address
and does not trust `X-Forwarded-For` by default. A rejected request returns
HTTP 429 with a `Retry-After` header. Username/IP bucket subjects are HMACed
with the private `auth-rate-limit.key` stored in `/data`; include that file
alongside the database and instance signing key in backups. The server creates
it with owner-only permissions and refuses unsafe key-file permissions.

The named volume survives container replacement. The server has encrypted
backup and staged restore commands. Create a separate 32-byte operator key and
keep it outside the server volume and away from the backup archive:

At startup the server creates a missing `ATERMIUS_DATA_DIR` with Unix mode
0700. An existing directory must already be a dedicated, non-system directory
owned by the service UID with mode 0700; startup fails without changing a
broadly accessible directory. Its ancestors cannot be group/world-writable
unless sticky (as `/tmp` is).
The image prepares `/data` with mode 0700 and UID 10001 ownership. For a host
bind mount, provision it before startup:

```sh
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-data
```

For an existing named volume created by an older image, verify that it is the
dedicated Atermius volume before tightening it once:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml run --rm --no-deps \
  --user 0 --entrypoint /bin/sh server \
  -c 'chmod 0700 /data && chown 10001:10001 /data'
```

All server commands use only `ATERMIUS_DATA_DIR/atermius.db`; custom or
external `ATERMIUS_DATABASE_URL` values are rejected so the database cannot
escape the owner-only data directory. The process lock, SQLite WAL/SHM files,
and temporary database snapshots are inside this directory boundary. `server.lock`
is created with mode 0600 and symlinks are rejected.

Prepare separate, private mount paths for the temporary archive and operator
key. Both paths must be outside `/data`. Protect the archive and key with
distinct access controls at rest. This example uses local staging only; it does
not by itself provide off-host or separate-domain protection:

```sh
sudo install -d -m 700 -o 10001 -g 10001 \
  /srv/atermius-backup-staging /srv/atermius-backup-key
umask 077
head -c 32 /dev/urandom > /srv/atermius-backup-key/atermius-backup.key
sudo chown 10001:10001 /srv/atermius-backup-key/atermius-backup.key
chmod 600 /srv/atermius-backup-key/atermius-backup.key
docker compose --env-file deploy/.env -f deploy/compose.yaml run --rm --no-deps \
  -v /srv/atermius-backup-staging:/backups \
  -v /srv/atermius-backup-key:/backup-key:ro \
  server backup \
  --archive /backups/atermius-$(date -u +%Y%m%dT%H%M%SZ).atb \
  --key-file /backup-key/atermius-backup.key
```

The backup command is online-safe: SQLite `VACUUM INTO` captures one WAL-aware
consistent snapshot. It refuses a missing source DB, a custom/external
`ATERMIUS_DATABASE_URL`, and an archive path that already exists. The resulting
archive is mode 0600 and encrypted with the separate key. After the command
succeeds, copy the archive to off-host backup storage and remove the local
staging copy; keep the key in a separate secrets manager or offline location.
The local bind mounts only keep the key out of the archive directory and do
not count as independent failure domains. Losing the key makes the archive
unreadable. Back up `deploy/.env` (or the deployment's equivalent), TLS and
reverse-proxy configuration, and any host-specific configuration separately
under the same offline protection policy. The archive includes a non-secret
runtime-policy summary for comparison, but it does not copy arbitrary
environment values or recreate the deployment configuration.

Check a retained archive without stopping the service or publishing a restore
directory. Mount both the archive and 32-byte key read-only, keeping them
outside the server data volume:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml run --rm --no-deps \
  -v /srv/atermius-backup-staging:/backups:ro \
  -v /srv/atermius-backup-key:/backup-key:ro \
  server verify-backup \
  --archive /backups/atermius-20260930T120000Z.atb \
  --key-file /backup-key/atermius-backup.key
```

`verify-backup` authenticates all archive chunks, checks their digests and the
archived 32-byte service keys, then checks SQLite integrity, foreign keys and
schema compatibility. It reads no
active instance database and prints only file count and migration version on
success. A failed check exits nonzero. Keep the verifier's result with the
backup inventory; still perform the isolated restore rehearsal below because
archive verification does not test startup, policy matching or application
login against the restored instance.

To restore, stop the service and prepare a separate, empty host directory. The
restore command holds the current data directory's OS lock, verifies the
encrypted archive and staged SQLite DB, runs supported migrations, checks
SQLite integrity and foreign keys, rotates server generation, and revokes
restored sessions. It never replaces the current volume; it atomically
publishes a complete new directory only after every check succeeds.

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml stop server
sudo install -d -m 700 -o 10001 -g 10001 /srv/atermius-restore-staging
docker compose --env-file deploy/.env -f deploy/compose.yaml run --rm --no-deps \
  -v /srv/atermius-backup-staging:/backups:ro \
  -v /srv/atermius-backup-key:/backup-key:ro \
  -v /srv/atermius-restore-staging:/restore \
  server restore \
  --archive /backups/atermius-YYYYMMDDTHHMMSSZ.atb \
  --key-file /backup-key/atermius-backup.key \
  --target-data-dir /restore/atermius-restored \
  --server-stopped
```

Replace the archive filename with the selected backup. Keep the old named
volume intact as rollback. The restored host directory is
`/srv/atermius-restore-staging/atermius-restored`. After reviewing the printed
new generation and preserving the matching `.env`/proxy configuration, edit
`deploy/compose.yaml`: replace `server-data:/data` with
`/srv/atermius-restore-staging/atermius-restored:/data`, then start the service:

```sh
docker compose --env-file deploy/.env -f deploy/compose.yaml up -d --no-build
docker compose --env-file deploy/.env -f deploy/compose.yaml ps
curl --fail http://127.0.0.1:8080/health/ready
```

Check account login, record sync, and object download before retiring the old
volume. To roll back, stop the service and restore `server-data:/data` in the
Compose file. The restore command supports only SQLite at
`ATERMIUS_DATA_DIR/atermius.db`; it rejects external/custom database URLs. Keep
the backup key offline and separately protected. Restore staging and final data
directories must be dedicated mode-0700 directories with safe ancestors as
described above. Rehearse the procedure before relying on a recovery-time
objective.

For a restore stage prepared in the administrator Settings page, use the
operator-run named-volume cutover coordinator in
[`docs/runbooks/instance-backup-restore.md`](../docs/runbooks/instance-backup-restore.md#apply-and-roll-back-a-web-prepared-stage-with-compose).
It updates the Compose `.env` volume name, data directory, and SQLite URL as a
single journaled operation, gates startup on readiness and preserved instance
identity, and can restore the recorded source values. Keep both volumes until
you have checked a fresh login, a known Vault record, and a known object.

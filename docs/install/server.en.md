# Install and deploy the self-hosted service

[中文](server.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md) · [Advanced options](../../deploy/README.md)

## Choose a deployment

| Setup | What it provides |
| --- | --- |
| API only | Native clients connect to the API; no bundled browser UI |
| API + Web | Separate API and nginx images, one browser origin |
| API + Web + HTTPS | Public browser origin through the optional Caddy edge |
| Add desktop/share overlays | guacd and explicitly enabled temporary access |

`server/Dockerfile` builds **only the API**. The Web image is built separately from the root `Dockerfile`. Neither a public hosted service nor a pre-published container image is assumed. Use Docker with Compose **2.24+**; the HTTPS overlays use `!reset`. Docker builds download pinned toolchains/dependencies, so the host does not need Flutter/Rust installed for this route.

## 1. Get the repository

Use a GitHub account with access to the private repository. With GitHub CLI, `gh auth login` and `gh auth setup-git` configure HTTPS credentials; SSH-key Git authentication also works.

```sh
git clone https://github.com/aterm-project/atermius.git
cd atermius
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
```

Compose resolves paths from `deploy/`: both the API and the Web build context are the repository root `..`, using `server/Dockerfile` and the root `Dockerfile` respectively. Run the commands below from the repository root. For an existing installation, keep the current environment/volumes and use the update section instead of repeating initialization.

## 2. Local same-host trial

Edit `deploy/.env` before starting. For a local browser at port 8081:

```dotenv
ATERMIUS_ADMIN_USERNAMES=admin@example.com
ATERMIUS_PUBLIC_ORIGIN=http://localhost:8081
```

Use your intended administrator username. Registration stays closed by default; the first account uses a bootstrap token. Organization creation defaults to configured instance administrators. HTTP is only for loopback development; another computer or phone needs the HTTPS setup below.

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml ps
curl --fail http://127.0.0.1:8080/health/ready
```

Open **http://localhost:8081**. The API is bound on loopback 8080 and Web on loopback 8081. A healthy API alone does not verify the frontend, proxy or browser storage.

For API-only deployments omit `compose.web.yaml`, set the public/API origin to the API endpoint (for example `http://localhost:8080` for this local trial), and use a native client. The API-only image does not contain a browser index or guest/join landing UI.

## 3. Create the first account

On a fresh instance run:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml exec -T server \
  /usr/local/bin/atermius-server bootstrap
```

Keep the printed one-use token private. In the Web/client server-account flow enter the instance origin, your administrator username, your chosen password and that bootstrap token. Save the recovery material. The allowlisted username must match if you want instance-admin/organization-creation features.

Once consumed, bootstrap is not the normal way to add users. Use the instance's account invitation/registration controls. Organization invitations are a separate membership step and cannot bypass account policy. Use the same active overlay list when running operational `exec` commands on a more advanced stack.

## 4. HTTPS for other machines

Configure DNS and reachability for your own domain, then set:

```dotenv
ATERMIUS_CADDY_DOMAIN=atermius.example.com
ATERMIUS_CADDY_ACME_EMAIL=admin@example.com
ATERMIUS_PUBLIC_ORIGIN=https://atermius.example.com
```

Replace the examples with real operator-owned values. Allow the edge's HTTP/HTTPS ports through the intended firewall. Deploy at the origin root; the public origin has scheme/host/port and no `/api/v1` suffix. Apply the overlays in order:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml up -d --build
curl --fail https://atermius.example.com/health/ready
```

The web-edge overlay is essential: it switches Caddy from API-only routing to nginx. It removes the loopback Web publishing; Caddy exposes the application origin. If you use your own TLS proxy instead, preserve same-origin API/WebSocket routing and consult [the edge runbook](../runbooks/https-edge-proxy.md). Check the external certificate and readiness URL; localhost-only health is not public HTTPS acceptance.

## 5. Enable temporary guest access only when needed

Registered-user organizations/Host sharing are SQLite capabilities. Temporary browser SSH/RDP additionally needs guacd and the trusted gateway. Set these in the environment used by the stack:

```dotenv
ATERMIUS_SHARE_LINKS_ENABLED=true
ATERMIUS_SHARE_ALLOW_CIDRS=10.20.0.0/16
ATERMIUS_SHARE_ALLOW_PORTS=22,3389
ATERMIUS_SHARE_DENY_CIDRS=172.16.0.0/12
ATERMIUS_SHARE_VNC_ENABLED=false
```

Use your actual narrow target networks/ports. The policy creates no network route; guacd must be able to reach the target. Keep API/guacd/database networks denied. If your targets overlap the example deny range, design explicit isolation and deny rules instead of simply exposing the whole container network. Loopback, metadata and other forbidden targets remain rejected.

For the Caddy/Web setup above:

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.desktop.yaml -f deploy/compose.share.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.desktop.yaml -f deploy/compose.share.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml up -d --build
```

`share-gateway-key` is a separate persistent key volume outside `/data`. The gateway can decrypt access capsules and observe sessions; it is not zero-knowledge. Losing that key makes existing capsules stale and requires owners to reseal. Do not publish guacd's port. Check `/api/v1/instance` capabilities and then test a dedicated target. See [cloud sharing](../CLOUD-SHARING.md) for policy, owner/guest flows, quotas and revocation.

PostgreSQL cloud routes remain closed. A PostgreSQL sync-core deployment has additional keys/migration/restore prerequisites and is documented in [deployment reference](../../deploy/README.md#postgresql-runtime-and-offline-restore-cutover); it is not a substitute for this SQLite cloud setup.

## 6. Regular browser SSH

This is separate from guest access. Enable `ATERMIUS_RELAY_ENABLED=true` only with explicit `ATERMIUS_RELAY_ALLOW_CIDRS`, `ATERMIUS_RELAY_ALLOW_PORTS` and the exact public origin. Regular browser SSH/SFTP uses the byte Relay. Desktop/guest gateway traffic uses guacd and a different trust boundary. Instance/account policies can restrict access further.

## 7. Update, back up and diagnose

Record the exact environment file and **complete overlay list** you used. Reuse that list for `config --quiet`, `up`, `ps`, `logs` and `exec`; omitting an overlay can remove its configuration. `--quiet` validates configuration without printing resolved secrets.

Keep the same data-volume name. Back up through the [instance backup/restore runbook](../runbooks/instance-backup-restore.md), including its separate key requirements. Before updating, stop new traffic as appropriate, update the repository with `git pull --ff-only` from its root, and rebuild/recreate the same stack. Do not overwrite `deploy/.env` or remove volumes as an upgrade procedure.

Use `ps`, `/health/ready`, the external Web page and sanitized server logs to separate API, proxy, policy and target failures. Copying files out of a running SQLite volume is not a complete instance-backup procedure. Optional MFA, object storage, provider push and monitoring remain in the [deployment reference](../../deploy/README.md).

To move from the pre-merge side-by-side `server` + `web` checkouts: take a backup with the runbook first, copy the old `deploy/.env` into the new clone's `deploy/.env` (keep `chmod 600`), keep the same data-volume name, Compose project name (if you set one explicitly) and complete overlay list, then rebuild the same stack from the new clone. Do not run bootstrap again on an existing instance.

For a Rust developer build only:

```sh
rustup toolchain install 1.94.1
cargo +1.94.1 build --locked --manifest-path server/Cargo.toml --jobs 8
cargo +1.94.1 test --locked --manifest-path server/Cargo.toml --jobs 2 -- --test-threads=2
```

The source CI uses Rust 1.94.1. Full native client/platform acceptance and public production deployment are separate from these checks.

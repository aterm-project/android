<p align="center"><img src="docs/assets/atermius-mark.svg" width="72" alt="Atermius"></p>

<h1 align="center">Atermius · Server</h1>

<p align="center">Self-hosted encrypted workspace API, organizations and temporary access gateway.</p>
<p align="center"><a href="README.zh-CN.md">简体中文</a> · <a href="docs/INSTALLATION.en.md">Install</a> · <a href="docs/README.md">Documentation</a> · <a href="https://github.com/aterm-project/server/actions/workflows/checks.yml">CI</a></p>

## Start here

No published end-user server binary or hosted service is provided. Build the API image from this checkout; the installation guide includes the separate Web image, HTTPS and first-account bootstrap.

- [Install and deploy](docs/INSTALLATION.en.md)
- [Deployment options](deploy/README.md)
- [Cloud sharing and gateway trust](docs/CLOUD-SHARING.md)
- [Integration tests](docs/INTEGRATION.md)
- [Operational runbooks](docs/README.md)

## What is included

| Capability | Role |
| --- | --- |
| Encrypted sync | Signed device identities, Vault membership and ciphertext records |
| Organizations and teams | Invitations, roles, desired grants and owner-confirmed key delivery |
| Host sharing | A dedicated sharing Vault for selected Hosts and approved dependencies |
| Temporary links | Custom addresses, start/expiry, limits, revocation and activity |
| Operations | SQLite, restricted PostgreSQL, backup/restore and optional monitoring |

## Quick start

Docker + Compose 2.24 or later. Clone `web` beside `server` for the browser UI.

```bash
git clone https://github.com/aterm-project/server.git
git clone https://github.com/aterm-project/web.git
cd server
cp deploy/.env.example deploy/.env
# Configure deploy/.env, then follow docs/INSTALLATION.en.md.
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
```

These repositories are currently private; your GitHub account needs access to clone them or download private artifacts. Detailed host prerequisites, output paths and update steps are in the [installation guide](docs/INSTALLATION.en.md).

## Support boundaries

The API image and browser image are separate. Cloud collaboration requires SQLite. Temporary SSH/RDP links use an opt-in trusted gateway that can decrypt login capsules and observe sessions. PostgreSQL cloud routes remain closed; VNC is explicit opt-in and has no live acceptance claim.

The full Flutter suite has disclosed historical failures. CI runs its documented focused checks; review the workflow and [validation documentation](docs/README.md) for their scope. Keep server state, account credentials and signing material outside Git.

## Repository layout

`server/` contains the Rust crate; `deploy/` contains Compose overlays; `docs/` and `integration/` contain guides and test harnesses.

Third-party licenses and upstream notices remain alongside their dependencies. The Rust crate declares AGPL-3.0-or-later in `server/Cargo.toml`.

## Other repositories

[Desktop](https://github.com/aterm-project/desktop) · [Android](https://github.com/aterm-project/android) · [iOS](https://github.com/aterm-project/ios) · [Web](https://github.com/aterm-project/web)

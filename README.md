<p align="center"><img src="docs/assets/atermius-mark.svg" width="72" alt="Atermius"></p>

<h1 align="center">Atermius</h1>

<p align="center">An encrypted SSH workspace for Android, iOS, Windows, macOS, Linux and the browser, with an optional self-hosted sync server.</p>
<p align="center"><a href="README.zh-CN.md">简体中文</a> · <a href="docs/INSTALLATION.en.md">Install</a> · <a href="docs/README.md">Documentation</a> · <a href="https://github.com/aterm-project/atermius/releases">Releases</a> · <a href="https://github.com/aterm-project/atermius/actions">CI</a></p>

## Start here

There is no published consumer installer matching the current main branch. Build from source using the guides, or try a daily pre-release build. Do not treat a successful source CI run or a daily build as a signed store distribution.

- [Installation and build](docs/INSTALLATION.en.md)
- [First workspace and connection](docs/GETTING_STARTED.en.md)
- [Features and platform boundaries](docs/FEATURES.md)
- [Sharing Hosts](docs/SHARING.en.md)
- [Self-hosted server](docs/install/server.en.md)
- [Troubleshooting](docs/TROUBLESHOOTING.en.md)
- [Developer checks](docs/DEVELOPMENT.md)
- [All documentation](docs/README.md)

## What is included

The client is one Flutter app:

- SSH terminals, compact Host lists, groups and reusable commands; Telnet, plus local shell and serial Console on desktop.
- SFTP/SCP file workspaces, split panes and saved window sets where supported.
- RDP and VNC through direct engines where the platform build has them, or through the server's gateway.
- Local encrypted profiles or a self-hosted synchronized Vault.
- Organizations, member sharing and temporary links when enabled by the server.
- Optional loopback MCP access for external AI tools on desktop and Android.
- Chinese, Japanese, English and Russian UI; application accents and terminal palettes are separate settings.

The server is a self-hosted encrypted workspace API, organization manager and temporary access gateway:

| Capability | Role |
| --- | --- |
| Encrypted sync | Signed device identities, Vault membership and ciphertext records |
| Organizations and teams | Invitations, roles, desired grants and owner-confirmed key delivery |
| Host sharing | A dedicated sharing Vault for selected Hosts and approved dependencies |
| Temporary links | Custom addresses, start/expiry, limits, revocation and activity |
| Operations | SQLite, restricted PostgreSQL, backup/restore and optional monitoring |

## Platforms

| Platform | Guide | Build entry point | Daily build |
| --- | --- | --- | --- |
| Android | [Android](docs/install/android.en.md) | `flutter build apk` in `apps/client` | `android-daily-*`: APK signed in CI |
| Windows | [Desktop](docs/install/desktop.en.md) | `integration/native/build_rdp_windows.ps1`, then `flutter build windows` | `desktop-daily-*`: portable ZIP, not code-signed |
| Linux | [Desktop](docs/install/desktop.en.md) | `flutter build linux` | `desktop-daily-*`: tar.gz bundle |
| macOS | [Desktop](docs/install/desktop.en.md) | `scripts/build_macos.sh --release` | `desktop-daily-*`: ZIP, ad-hoc signed, not notarized |
| iOS | [iOS](docs/install/ios.en.md) | `scripts/build_ios.sh`, or `flutter build ios` | `ios-daily-*`: unsigned IPA |
| Browser | [Web](docs/install/web.en.md) | `flutter build web --release --no-web-resources-cdn`, or the root `Dockerfile` | `web-daily-*`: static site + `deploy/nginx.conf` |
| Server | [Server](docs/install/server.en.md) | Docker Compose in `deploy/` | None; build from source |

## Quick start

Flutter 3.47.5 / Dart 3.13 plus each platform's tools. Windows needs the native RDP bundle first; iOS and macOS need Xcode. See the [installation guide](docs/INSTALLATION.en.md).

```bash
git clone https://github.com/aterm-project/atermius.git
cd atermius/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build apk --debug
```

Other targets: `flutter build linux --release`, `flutter build web --release --no-web-resources-cdn`, or the platform guide.

For the server, Docker + Compose 2.24 or later:

```bash
cd atermius
cp deploy/.env.example deploy/.env
# Configure deploy/.env, then follow docs/install/server.en.md.
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
```

This repository is currently private; your GitHub account needs access to clone it or download private artifacts.

## Daily builds

Daily builds are published as pre-releases on the [Releases](https://github.com/aterm-project/atermius/releases) page with tags `<platform>-daily-YYYYMMDD.N-<sha12>`, where the platform is `android`, `desktop`, `ios` or `web`. Each one carries `evidence-<platform>.json` and `SHA256SUMS`. A build runs at most once per UTC day and only when product inputs changed; see [`.github/daily-build/README.md`](.github/daily-build/README.md). Releases from before the merge stay on the archived repositories.

## Repository layout

| Path | Contents |
| --- | --- |
| `apps/client/` | The Flutter app with `android/`, `ios/`, `macos/`, `windows/`, `linux/` and `web/` runners; native RDP engine sources are under `apps/client/native/` |
| `packages/` | Five patched local dependency forks (`drift`, `sqlite3`, `xterm`, `dartssh2`, `desktop_drop`) |
| `protocol/` | Shared contracts and test vectors |
| `server/` | Rust API crate and its `Dockerfile` |
| `deploy/` | Server Compose files and overlays, plus the Web image's `nginx.conf` |
| `Dockerfile` | Browser frontend image (Flutter web build served by nginx) |
| `integration/` | API/browser test harness, native platform probes and the MCP stdio bridge |
| `tools/` | Flutter SDK helper, integration-workspace assembly and nginx proxy verification |
| `scripts/` | One-step macOS and iOS build scripts |
| `docs/` | User, operator and developer documentation |

## Support boundaries

Native Windows RDP requires the bundled `atermius_rdp.dll` engine; other platforms use their own engine builds or the server gateway (see [remote desktop](docs/REMOTE-DESKTOP.md)). Browser SSH requires an enabled, restricted Relay. Temporary browser SSH/RDP is a separate trusted-gateway flow that can decrypt login capsules and observe sessions. The API image and browser image are separate. Cloud collaboration requires SQLite; PostgreSQL cloud routes remain closed. VNC through the gateway is explicit opt-in and has no live acceptance claim.

Native platform build/device acceptance is separate from the Linux Dart/widget checks in CI. The full Flutter suite has disclosed historical failures. CI runs its documented focused checks; review the workflow and [validation documentation](docs/README.md) for their scope. Keep server state, account credentials and signing material outside Git.

Third-party licenses and upstream notices remain alongside their dependencies. The Rust crate declares AGPL-3.0-or-later in `server/Cargo.toml`.

## History

Atermius used to live in five repositories under `aterm-project`: `android`, `desktop`, `ios` and `web` (the same Flutter app with different platform runners) and `server`. On 2026-11-14 they were merged into this repository with their Git history preserved. `aterm-project/android` was renamed to `aterm-project/atermius`; `desktop`, `ios`, `web` and `server` were archived read-only and keep their earlier releases. Each former repository's source-import records are kept unchanged in [docs/provenance/](docs/provenance/), listed in the [documentation index](docs/README.md).

# Install and build

[中文](INSTALLATION.md) · [README](../README.md) · [Documentation](README.md)

Every client and the server live in one repository: `apps/client/` is one Flutter app with all platform runners, `server/` is the Rust API and `deploy/` holds the deployment files. Complete the common steps on this page, then follow your platform's guide.

## Choose a platform

| Platform | Guide | Build entry point | Daily build tag |
| --- | --- | --- | --- |
| Android | [Build and install on Android](install/android.en.md) | `flutter build apk` in `apps/client` | `android-daily-*` |
| Windows / Linux / macOS | [Build and install the desktop client](install/desktop.en.md) | Windows: `integration/native/build_rdp_windows.ps1` first; macOS: `scripts/build_macos.sh` | `desktop-daily-*` |
| iOS | [Build the iOS client](install/ios.en.md) | `scripts/build_ios.sh`, or `flutter build ios` | `ios-daily-*` |
| Browser | [Build and deploy the browser frontend](install/web.en.md) | `flutter build web`, or the root `Dockerfile` | `web-daily-*` |
| Self-hosted server | [Install and deploy the self-hosted service](install/server.en.md) | Docker Compose files in `deploy/` | None; build from source |

## Repository access and SDK

The repository is private. Authenticate your Git credential helper with an account that has access. With GitHub CLI, `gh auth login` then `gh auth setup-git` configures HTTPS Git without embedding a token in the clone URL. Existing SSH-key authentication also works.

```sh
git clone https://github.com/aterm-project/atermius.git
cd atermius
```

Paths and commands in the platform guides are relative to this repository root.

For the clients, install **Flutter 3.47.5**, which supplies **Dart 3.13**, from the [official archive](https://docs.flutter.dev/install/archive), add its `bin` directory to PATH, then run `flutter --version` and `flutter doctor -v`. Keep `pubspec.lock` and all five local dependency forks in `packages/`. The toolchain requirement is stricter than some old README text. On Linux, `tools/install_flutter_linux.sh` can install a temporary SDK; see [developer checks](DEVELOPMENT.md). The Docker route for the server needs no Flutter/Rust on the host.

## Prebuilt builds

There is no current-main consumer installer. The platform guides below build your own application.

Daily builds are published as **pre-releases** on this repository's [Releases](https://github.com/aterm-project/atermius/releases) page, tagged `<platform>-daily-YYYYMMDD.N-<sha12>` where the platform is `android`, `desktop`, `ios` or `web`. Each pre-release carries the build outputs, `evidence-<platform>.json` and `SHA256SUMS`. They are CI outputs for testing, not store or notarized distributions:

- Android: an APK signed in CI with the project's pinned certificate. An installed app with a different signature cannot be updated in place.
- Desktop: a Windows portable ZIP (with `atermius_rdp.dll`, not code-signed), a Linux tar.gz of `bundle/`, and a macOS ZIP (ad-hoc signed, not notarized).
- iOS: an unsigned IPA. It cannot be installed until you re-sign it with your own Apple identity and provisioning profile.
- Web: an archive of the `web/` static site plus `deploy/nginx.conf`. Deployment still needs the API.

Trigger rules, outputs and verification are described in [`.github/daily-build/README.md`](../.github/daily-build/README.md). Releases made before the 2026-11-14 merge, including Desktop `ci-input-*` archives (build inputs, not installers), remain on the archived repositories' Releases pages. Neither source CI nor a daily build is native device acceptance.

## Moving from the old repositories

`aterm-project/android` was renamed to `aterm-project/atermius`. An existing clone can keep pulling after `git remote set-url origin https://github.com/aterm-project/atermius.git`. `desktop`, `ios`, `web` and `server` are archived read-only; clone this repository instead. The server no longer needs `server` and `web` checked out side by side: one clone is enough.

## Update an existing build

Export/back up the workspace first, close Atermius, update the repository with `git pull --ff-only`, resolve dependencies with the same pinned SDK/lockfile and rebuild. Replace the complete runtime bundle; keep the native engine and Dart app from the same build. Preserve the application's data and, on mobile, its signing identity. Source, SDKs and build caches belong on the build workstation/CI; a runtime computer only needs the finished application and its runtime dependencies.

Server updates, backups and the overlay list have their own rules; see the [server guide](install/server.en.md).

[First use](GETTING_STARTED.en.md) · [Troubleshooting](TROUBLESHOOTING.en.md) · [Developer checks](DEVELOPMENT.md)

# Build and deploy the browser frontend

[中文](INSTALLATION.md) · [README](../README.md)

## Repository access and SDK

Repositories are private. Authenticate your Git credential helper with an account that has access. With GitHub CLI, `gh auth login` then `gh auth setup-git` configures HTTPS Git without embedding a token in the clone URL. Existing SSH-key authentication also works.

Install **Flutter 3.47.5**, which supplies **Dart 3.13**, from the [official archive](https://docs.flutter.dev/install/archive), add its `bin` directory to PATH, then run `flutter --version` and `flutter doctor -v`. Keep `pubspec.lock` and all five local dependency forks. The toolchain requirement is stricter than some old README text.

There is no current-main consumer installer in Releases. Desktop `ci-input-*` archives are build inputs. The commands below build your own application; CI source checks alone are not native device acceptance.

## Build the site

```sh
git clone https://github.com/aterm-project/web.git
cd web/apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

Deploy the complete **`apps/client/build/web/`** output. `--no-web-resources-cdn` keeps CanvasKit same-origin; the repository also bundles Unicode fallback fonts and their notices. Use a real HTTP server, not `file://`.

## Deploy with the API

The recommended setup is the server repository's [installation guide](https://github.com/aterm-project/server/blob/main/docs/INSTALLATION.en.md). Clone `server` and `web` as siblings. The server's `compose.web.yaml` resolves this checkout through `../../web` relative to its Compose directory, builds the frontend image and provides one browser origin for API/WebSocket traffic.

For a manual image build, from the Web repository root:

```sh
docker build -t atermius-web:local .
```

The image listens on port **8080**, runs as nginx and expects `server:8080` on its Docker network. A standalone `docker run` with no API service is not a complete deployment. Use the server Compose stack for networking, TLS and persistent API data. No published GHCR image or public hosted instance is assumed.

## Guest links and regular SSH

The supplied nginx serves `/s/*` and `/join` with no-store/referrer/CSP headers and proxies `/gateway/*` with WebSocket upgrade support. Preserve `share-bootstrap.js` before Flutter; it removes access-link fragments before routing/requests. Generic static hosting without these routes/proxy headers is insufficient for guest access.

Regular signed-in browser SSH needs the server Relay and a narrow target policy. Guest SSH/RDP instead requires the separate trusted gateway. Cloud collaboration is SQLite-only; guest cookies require HTTPS. Local browser profiles cannot open direct OS TCP or local shells.

## Verify the built runtime

From this repository root, with Docker available:

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

This starts only disposable loopback fixtures and checks real nginx headers, API forwarding and a WebSocket echo. It does not deploy a public service or replace a real guest/target test.

## Update an existing build

Export/back up the workspace first, close Atermius, update this checkout with `git pull --ff-only`, resolve dependencies with the same pinned SDK/lockfile and rebuild. Replace the complete runtime bundle; keep the native engine and Dart app from the same build. Preserve the application's data and, on mobile, its signing identity. Source, SDKs and build caches belong on the build workstation/CI; a runtime computer only needs the finished application and its runtime dependencies.

[First use](GETTING_STARTED.en.md) · [Troubleshooting](TROUBLESHOOTING.en.md) · [Developer checks](DEVELOPMENT.md)

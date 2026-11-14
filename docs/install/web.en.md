# Build and deploy the browser frontend

[中文](web.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md)

First complete repository access, cloning and the Flutter toolchain in the [install overview](../INSTALLATION.en.md). Every command below starts from the repository root.

## Build the site

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

Deploy the complete **`apps/client/build/web/`** output. `--no-web-resources-cdn` keeps CanvasKit same-origin; the repository also bundles Unicode fallback fonts and their notices. Use a real HTTP server, not `file://`.

## Deploy with the API

The recommended setup is the [server installation guide](server.en.md). The API and the frontend now live in the same repository: the server's `deploy/compose.web.yaml` builds the frontend image from the root `Dockerfile` and provides one browser origin for API/WebSocket traffic. A sibling `web` checkout is no longer needed.

For a manual image build, from the repository root:

```sh
docker build -t atermius-web:local .
```

The image listens on port **8080**, runs as nginx with `deploy/nginx.conf` and expects `server:8080` on its Docker network. A standalone `docker run` with no API service is not a complete deployment. Use the server Compose stack for networking, TLS and persistent API data. No published GHCR image or public hosted instance is assumed.

## Guest links and regular SSH

The supplied nginx serves `/s/*` and `/join` with no-store/referrer/CSP headers and proxies `/gateway/*` with WebSocket upgrade support. Preserve `share-bootstrap.js` before Flutter; it removes access-link fragments before routing/requests. Generic static hosting without these routes/proxy headers is insufficient for guest access.

Regular signed-in browser SSH needs the server Relay and a narrow target policy. Guest SSH/RDP instead requires the separate trusted gateway. Cloud collaboration is SQLite-only; guest cookies require HTTPS. Local browser profiles cannot open direct OS TCP or local shells.

## Verify the built runtime

From the repository root, with Docker available:

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

This starts only disposable loopback fixtures and checks real nginx headers, API forwarding and a WebSocket echo. It does not deploy a public service or replace a real guest/target test.

Before updating an existing build, read "Update an existing build" in the [install overview](../INSTALLATION.en.md).

[First use](../GETTING_STARTED.en.md) · [Troubleshooting](../TROUBLESHOOTING.en.md) · [Developer checks](../DEVELOPMENT.md)

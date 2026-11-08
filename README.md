# Atermius server suite

Rust API/server, migrations, administrative tools and deployment configurations.
The frontend is maintained and built in the sibling `web` repository.

```sh
cd server
cargo build --locked --jobs 8
cargo test --locked --jobs 8
```

Rust 1.94.1 is the container build toolchain. From this repository root, run
`docker compose -f deploy/compose.yaml up --build` for the API on loopback port
8080. Configure the administrator/bootstrap flow following `deploy/README.md`.
Registration and relays remain disabled by default. No deployment is performed
by the repository import. Do not commit `.env`, state, backup data or credentials.

Clone the frontend repository alongside this repository as `../web`, then use:

```sh
docker compose -f deploy/compose.yaml -f deploy/compose.web.yaml up --build
```

The frontend is served on loopback port 8081 and proxies the API and WebSockets
to the server. For public TLS, add `-f deploy/compose.caddy.yaml` and
`-f deploy/compose.web-edge.yaml`, set the domain/contact/public origin variables,
and follow the deployment runbook. Existing API-only overlays remain available.
The web-edge override routes the public origin to the frontend; without it Caddy
continues to route directly to the API. The current server uses the direct peer address for IP rate limiting; when placed
behind a proxy, clients share that proxy address. Account/pair rate limits still
apply. This import does not add trusted-proxy support or change authentication.

`docs/cloud-collaboration-design` contains design proposals for temporary external
sharing, not a claim those proposed features have been implemented or deployed.
Existing baseline test failures are not hidden by this source split. Server code
retains its declared AGPL-3.0-or-later license; third-party notices remain intact.

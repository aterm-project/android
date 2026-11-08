# Caddy HTTPS edge deployment

This runbook adds an optional Caddy edge to the existing single-container
Compose deployment. The default `compose.yaml` behavior is unchanged. The
edge overlay clears the server's published port and exposes the same-origin
Web/API/Relay service through Caddy. The origin joins the default and dedicated
`caddy-backend` networks; Caddy joins only `caddy-backend`. Docker Compose 2.24
or newer is required for the overlay's explicit port-list reset.

## Configure

1. Point a DNS A/AAAA record for the chosen hostname at the Docker host.
2. Permit inbound TCP 80 and 443. UDP 443 is optional and enables HTTP/3.
3. Set the exact values in `deploy/.env`:

   ```dotenv
   ATERMIUS_CADDY_DOMAIN=termius.example.org
   ATERMIUS_CADDY_ACME_EMAIL=admin@example.org
   ATERMIUS_PUBLIC_ORIGIN=https://termius.example.org
   ```

   If the public HTTPS port is nonstandard, include it in
   `ATERMIUS_PUBLIC_ORIGIN`. Caddy's standard ACME issuers use HTTP-01 or
   TLS-ALPN-01. The supplied Caddy image does not contain DNS-provider
   plugins. Do not put DNS credentials in the Compose environment.
4. Start the edge mode:

   ```sh
   docker compose --env-file deploy/.env \
     -f deploy/compose.yaml -f deploy/compose.caddy.yaml up -d --build
   docker compose --env-file deploy/.env \
     -f deploy/compose.yaml -f deploy/compose.caddy.yaml ps
   ```

   Caddy stores certificates and ACME account state in the project-scoped
   `caddy-data` volume. Preserve this volume across service upgrades.

## Readiness and failure handling

`server` health is the origin/database signal. `edge` health is a separate
HTTPS probe through Caddy to `/health/ready`; it becomes unhealthy if Caddy
cannot reach a ready origin. Do not use a healthy server container alone as
proof that the public HTTPS endpoint is reachable. Monitoring should check
both the Compose `edge` health state and the external HTTPS endpoint.

When Caddy is stopped or cannot serve requests, the public health URL must
fail even if the server remains healthy. When the origin is stopped, Caddy's
healthcheck must become unhealthy and the HTTPS readiness route must stop
returning 200. Restore traffic only after the `edge` healthcheck and an
external HTTPS request both succeed.

## Local acceptance

The test `integration/test_compose_caddy_edge.py` creates a unique Compose
project, binds Caddy to temporary loopback ports and uses Caddy's internal CA.
It verifies the trusted test CA, HTTPS readiness, an authenticated Relay
ticket and binary WebSocket echo, the absence of a published origin port, and
separate origin/edge failure states. Its `finally` cleanup runs
`docker compose down --volumes` for that unique project only. Run it with:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m pytest -q integration/test_compose_caddy_edge.py
```

This local test does not exercise public DNS, real ACME issuance, a public
firewall, production certificate renewal, or a cloud/provider-specific
deployment. Those require a separate environment-specific drill.

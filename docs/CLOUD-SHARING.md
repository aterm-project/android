# Cloud access: organizations, Host sharing and temporary links

This guide covers the self-hosted deployment and the honest trust model of
Atermius cloud access. Design background: `docs/cloud-collaboration-design/`
(proposal) and `docs/cloud-collaboration-design/IMPLEMENTATION-ADR.md`
(what was actually built).

## What it does

| Feature | How | Server can read |
| --- | --- | --- |
| Organizations, teams, invitations | Server-managed control metadata; one-time join links `/join#o1.<token>` (token hash at rest) | names, members, roles, teams |
| Share Hosts with members/teams | Encrypted Vaults stay the unit. "Share only this Host" creates a dedicated sharing Vault with a copy of the selected Host and the dependencies the owner approves. Grants are *desired* access; the Vault key reaches a recipient only after the Vault owner confirms the recipient's device fingerprint (existing signed invitation, token sealed to the device). | grants, membership metadata; never Vault keys or Host records |
| Temporary browser links | `/s/<slug>#s1.<secret>` (secret only in the fragment). Guests connect through the server's **trusted gateway** (guacd) to an owner-selected SSH or RDP Host. | link metadata; **the gateway can open the sealed Host login and see the session** |

### Trust model of temporary links (not end-to-end encrypted)

When an owner creates a link, the Host's login is sealed (`crypto_box_seal`)
to the gateway X25519 key. The gateway key is signed by the instance key and
the client verifies that signature against its pinned instance key before
sealing. Whoever holds the gateway private key file *and* the database
(normally the server operator, or an attacker who compromises the server)
can open every stored capsule and watch sessions. A database or backup leak
alone does not reveal logins because the key file is never inside the data
directory or backups. Guests never receive the password or key through the
sharing API or the rendered stream, but inside the session they can do
anything the target account allows — use a dedicated low-privilege account.

## Requirements (default SQLite deployment)

* guacd 1.6.0 (`deploy/compose.desktop.yaml`), reachable only by the server.
* `ATERMIUS_PUBLIC_ORIGIN` = the exact browser origin (e.g. `https://atermius.example.com`).
* TLS in front (cookies are `__Host-` / `Secure`).

Start with the complete [English installation flow](INSTALLATION.en.md) or [中文安装流程](INSTALLATION.md). It includes the separate Web image, exact HTTPS origin, Caddy/web-edge routing, administrator setup and target policy. Adding only a gateway overlay does not provision a usable HTTPS guest website.

For an existing stack, retain **every** active Web/TLS/backup/etc. overlay and add `compose.desktop.yaml` and `compose.share.yaml`. The environment example keeps temporary links off: explicitly set `ATERMIUS_SHARE_LINKS_ENABLED=true` and a narrow `ATERMIUS_SHARE_ALLOW_CIDRS` before enabling them. Use `--env-file deploy/.env` consistently; `.env` variables affect the container only when the selected Compose files pass them through.

After deployment, check the exact public origin:

```sh
curl --fail https://atermius.example.com/api/v1/instance
```

`share_links`, `share_gateway_ssh`, `share_gateway_rdp` and `organizations` appear only when their respective prerequisites are valid. Replace the example domain before running this check.

PostgreSQL sync-core deployments: cloud routes are **not registered** and no
capability is advertised; the existing PG scope guard keeps returning
`PG_SYNC_SCOPE_LIMITED`. This is a deliberate fail-closed limitation.

## Settings

Absent settings use the defaults below. A setting that is present but
malformed (wrong boolean spelling, out-of-range number, bad CIDR, empty value)
is a configuration error: the affected feature stays closed and unadvertised;
the server never falls back to a broader default.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ATERMIUS_SHARE_LINKS_ENABLED` | `false` | `true` to enable temporary links |
| `ATERMIUS_SHARE_GATEWAY_KEY_FILE` | — | 32-byte X25519 key (created 0600 on first start). Must be outside `ATERMIUS_DATA_DIR`; startup fails otherwise. |
| `ATERMIUS_SHARE_ALLOW_CIDRS` | — (required) | Target networks guests may reach |
| `ATERMIUS_SHARE_ALLOW_PORTS` | `22,3389` | Target ports |
| `ATERMIUS_SHARE_DENY_CIDRS` | — | Always-denied networks (put the compose/guacd/DB networks here) |
| `ATERMIUS_SHARE_VNC_ENABLED` | `false` | VNC has no transport encryption; only advertised when `true` |
| `ATERMIUS_SHARE_MAX_LINK_LIFETIME_SECONDS` | `2592000` (30 d) | 3600–7776000 |
| `ATERMIUS_SHARE_MAX_GUEST_CONNECTIONS` | `32` | Instance-wide concurrent guest connections (1–1024) |
| `ATERMIUS_SHARE_REDEEM_IP_LIMIT_PER_MINUTE` | `10` | Redemption attempts per client IP per minute (hour limit = 6×) |
| `ATERMIUS_SHARE_MAX_DISPLAY_WIDTH` / `_HEIGHT` | `1920` / `1200` | Guest display clamp |
| `ATERMIUS_ORGANIZATIONS_ENABLED` | `true` | Organizations, teams, grants |
| `ATERMIUS_ORG_CREATION` | `admin` | `admin` (instance admins in `ATERMIUS_ADMIN_USERNAMES`) or `any` |

Always-forbidden targets (independent of policy): loopback, link-local,
unspecified, multicast/broadcast, cloud metadata (169.254.169.254,
fd00:ec2::254, 100.100.100.200) and IPv4-mapped variants. Names are
re-resolved at link creation, ticket issue and connect; if **any** DNS answer
is forbidden or denied the target is refused; guacd only ever receives the
checked IP literal. If Relay is configured, the owner's Relay user/group
policy also bounds what they may expose.

## Owner flow

1. Host menu → **Share…**.
2. *Temporary links*: choose start (now or scheduled), lifetime (1 h / 24 h /
   7 d / custom), openings (default 1), connection attempts, simultaneous
   connections, view-only, clipboard directions, custom address, title.
   SSH Hosts need a trusted KnownHost; RDP Hosts a pinned certificate. Copy
   the link once (it cannot be shown again; rotate the secret if lost).
3. *Members & teams*: create a dedicated sharing Vault (only the selected
   Host and approved dependencies are copied), attach it to an organization,
   grant users/teams viewer/editor, then confirm each recipient device
   fingerprint and deliver the key. Whole-Vault sharing is a separate,
   explicitly labeled choice. After a recipient has accepted, raising or
   lowering their grant shows **Make Editor/Viewer**: the owner confirms and
   the client applies the signed Vault member-role change (the server alone
   never changes an accepted member's cryptographic role; until then the
   server enforces the narrower of grant and signed role).
4. Every owner operation (sealing, links, sharing-Vault copies, key
   delivery, role changes, member removal) is bound to the account, device,
   server, API session and Vault it started in. A sign-out, account or
   server switch, or a Vault selection that does not take effect (or is
   superseded by the user, including switching away and back) aborts before
   the next request; copies are only written into the newly created sharing
   Vault, and the previously selected Vault is restored only if the user did
   not request another selection meanwhile. If the server had already
   completed a step (the Vault or the invitation exists), the error says so;
   nothing is undone silently and nothing is applied to the newer session.
5. Activity: guest sessions (coarse IP /24 or /48, browser family), live
   connections, metadata-only audit; end sessions; pause, rotate, revoke.

## Guest flow

`/s/<slug>#s1.<secret>` → `web/share-bootstrap.js` removes the fragment from
the address bar before Flutter, routing or any request → neutral landing page
→ **Continue** (redeems; sets `__Host-atermius-guest`, HttpOnly, Secure,
SameSite=Strict) → target list → **Connect** (30 s one-use ticket →
`/gateway/v1/connect`). Refreshing resumes the session without using another
opening. Nothing redeems or connects automatically.

The guest cookie is bound to the link address shown in the browser:
`GET /api/v1/guest/session?slug=<slug>` and `POST /api/v1/guest/connections`
(`{"slug", "target_id"}`) answer the same uniform `404` as an unknown link
when the cookie belongs to another link, so opening `/s/B` with a session for
`/s/A` never displays or connects A. The page additionally refuses any
answer whose `slug` differs from its address.

## Revocation bounds

Revoke, rotate, pause, narrowing edits, guest-session termination, Host
deletion, sealer device revocation, owner loss and organization/team/grant
removal close affected gateway connections within 3 s, including when the
authorization check itself is slow: a broadcast wake-up plus a 1 s recheck
interval, each recheck bounded by a 1 s timeout (a recheck that cannot finish
counts as revoked), and a non-blocking upstream close bounded by 0.5 s. These
also run while connection setup or I/O is blocked. Removing a member
from an organization blocks grant-derived Vault access on the server
immediately (sync, objects, notifications, presence, collaboration, audit,
Vault lists); the Vault owner must still rotate the Vault key to remove the
member cryptographically and should change any credentials the member saw.

## WebSocket close codes (`/gateway/v1/connect`)

`4400` protocol violation · `4401` ticket invalid · `4403` revoked/changed ·
`4408` expired/idle · `4429` limits · `4502` target/guacd/host-key failure.

### What counts as a connection attempt

A link's *connection attempts* (`max_connections`) are charged when the
gateway **admits** a connection, not when the 30-second ticket is issued.
Admission happens in one serialized step when the ticket is presented on
`/gateway/v1/connect`: an instance-wide guest slot is taken first, then the
current authorization, the link's simultaneous-connection limit and the
per-session limit are checked, and only then is one attempt charged
atomically and the one-use ticket consumed.

* Refused for instance capacity (`4429 instance_capacity`) or for too many
  simultaneous connections (`4429 concurrency`): nothing is charged and the
  ticket is **not** consumed; the guest may present it again until it
  expires.
* Refused because the link is used up (`4429 exhausted`) or access was
  revoked/changed (`4403`): the ticket is consumed (it can never succeed).
* Admitted: the attempt counts even if the target host, guacd or the remote
  login fails afterwards.

Issuing a ticket only performs cheap early refusals (already used up, already
at the simultaneous limit) and never charges an attempt.

## Backups and key loss

Instance backups do not contain the gateway key. After restoring to a new
key, existing capsules report `stale_gateway_key` and links stop admitting new
connections until owners share again. For immediate access removal, use link revocation/session termination or stop the service. Do not use deleting a key file as a substitute for revoking a running process's access. A new key loaded on restart makes prior capsules stale.

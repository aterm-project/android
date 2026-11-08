# Web Terminal Collaboration Protocol v1

This document defines the first live, read-only observer slice of §17.2 in
`PROJECT_PLAN.md`. It is versioned independently from the Vault sync protocol.

## Security and ownership model

- The host device opens and owns the SSH connection. The server does not open
  SSH connections and does not receive SSH credentials.
- The host explicitly selects active Vault member devices before creating a
  session. The observer set is fixed for the lifetime of a v1 session. A later
  observer requires a new session and new independent observer secrets.
- Each approved device receives its own host-signed keybox containing an
  independent random 32-byte observer secret sealed to that device's
  registered Curve25519 public key. Secrets are independent across observers,
  so one observer cannot derive another observer's frame key. The server
  checks authorization and the host signature, but never opens or stores key
  material durably.
- Terminal output and host-authoritative resize frames are encrypted and
  signed by the host. Each observer gets a recipient-specific frame with
  recipient-bound key derivation and authenticated data. The server only
  routes bounded ciphertext to the named approved observer.
- Observers verify the host signature using the host signing key in the
  authenticated Vault device directory. This follows the current client trust
  model for Vault-signed data over the configured server connection; v1 does
  not add an independently fetched device-enrollment certificate chain for a
  hostile-directory-server threat model.
- Observers have no input, paste, mouse, command, or resize-request message.
  The WebSocket server rejects every observer application frame. The Web UI
  renders into a separate read-only terminal model.
- Rooms, tickets, keyboxes, and queued frames are memory-only. Server restart,
  host disconnect, host stop, expiry, or a Vault membership-version change
  ends the session. A disconnected observer cannot resume an old session.

## HTTP control plane

All endpoints require the normal authenticated access token in the HTTPS
`Authorization` header and a registered active device. WebSocket tickets are
single-use, short-lived, hash-only server-side credentials; access and refresh
tokens are never placed in the WebSocket URL or first frame. The feature is
disabled by default and requires both
`ATERMIUS_TERMINAL_COLLABORATION_ENABLED=true` and a configured
`ATERMIUS_PUBLIC_ORIGIN`; the instance endpoint advertises the capability only
when both are present.

### Create a host session

`POST /api/v1/vaults/{vault_id}/terminal-sessions`

```json
{
  "protocol_version": 1,
  "session_id": "<client-generated canonical UUID>",
  "expires_at": "<UTC RFC3339 timestamp, at most 15 minutes ahead>",
  "observers": [
    {
      "user_id": "<active Vault member user UUID>",
      "device_id": "<active registered device UUID>",
      "keybox": {
        "format": "atermius-terminal-keybox-v1",
        "session_id": "<same session UUID>",
        "vault_id": "<route Vault UUID>",
        "membership_version": 1,
        "host_user_id": "<authenticated host user UUID>",
        "host_device_id": "<authenticated host device UUID>",
        "observer_user_id": "<observer user UUID>",
        "observer_device_id": "<observer device UUID>",
        "role": "observer",
        "epoch": 1,
        "expires_at": "<same expiry>",
        "sealed_secret": "<canonical base64url-no-pad crypto_box_seal bytes>",
        "signature": "<canonical base64url-no-pad Ed25519 signature>"
      }
    }
  ]
}
```

The host signs the JCS serialization of every keybox field except `signature`
with the registered host device signing key. The signature binds the session,
Vault, current membership version, host and observer identities, observer
role, epoch, expiry, and sealed bytes. The server rejects duplicate targets,
inactive/nonmember devices, invalid signatures, stale membership versions,
unknown fields, malformed encodings, empty observer sets, and more than eight
observers.

On success the response contains `session_id`, `expires_at`, `host_ticket`,
and `connect_path`. Tickets expire within 30 seconds and bind the authenticated
user, device, login session, server generation, room, and role.

### Join an explicitly approved observer device

`POST /api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/ticket`

Only a device included in the create request can obtain a ticket. The response
contains `ticket`, `role: "observer"`, the signed `keybox`,
`ticket_expires_at` (the single-use ticket deadline, at most 30 seconds ahead),
and `connect_path`. `keybox.expires_at` remains the room/session deadline.
The ticket request has an empty body. Issuance and consumption each recheck
active account, device, login session, Vault, membership, membership version,
session expiry, and the explicit device grant.

### Stop a host session

`DELETE /api/v1/vaults/{vault_id}/terminal-sessions/{session_id}`

Only the original active host device can stop the room. The server closes the
host and every observer connection and clears transient room state.

## WebSocket data plane

The Web client connects to the returned `connect_path` using the configured
public HTTPS origin. Upgrade requires exactly one `Origin` header equal to
`ATERMIUS_PUBLIC_ORIGIN`. The first text frame within ten seconds is:

```json
{"type":"authenticate","ticket":"<single-use ticket>"}
```

Tickets are consumed atomically. A host publishes one frame per approved
observer:

After valid ticket consumption, the server first sends the text acknowledgement
`{"type":"authenticated","role":"host"|"observer","session_id":"<UUID>"}`.
Clients must wait for this message before publishing output or rendering the
session as connected.

After ticket consumption, the socket stays bound to the original login
`session_id`, user, and device. A normal access-token refresh can rotate that
session's access-token hash without interrupting the socket; the server
continues to check session revocation, refresh expiry, account/device status,
and Vault membership under SQLite writer ordering. A socket whose refresh
session expires or is revoked is closed.

```json
{
  "type": "frame",
  "frame": {
    "format": "atermius-terminal-frame-v1",
    "session_id": "<UUID>",
    "vault_id": "<UUID>",
    "membership_version": 1,
    "host_user_id": "<UUID>",
    "host_device_id": "<UUID>",
    "recipient_user_id": "<UUID>",
    "recipient_device_id": "<UUID>",
    "role": "observer",
    "epoch": 1,
    "sequence": 1,
    "kind": "output",
    "nonce": "<canonical base64url-no-pad 24-byte XChaCha nonce>",
    "ciphertext": "<canonical base64url-no-pad XChaCha20-Poly1305 ciphertext+tag>",
    "signature": "<base64url-no-pad Ed25519 signature>"
  }
}
```

`kind` is `output` or `resize`. Sequence numbers start at one and increase
independently per observer and kind. Because an approved observer may join
after a host has begun publishing and v1 has no history replay, its first
received sequence may be any positive value; thereafter the receiver requires
the exact next sequence and rejects duplicates, gaps, and out-of-order frames.
The server may retain and deliver only the latest opaque, host-signed `resize`
frame for that target when it joins or reconnects, so the observer gets the
current host dimensions without receiving prior terminal output. The UI
identifies the view as live-only and does not imply that earlier output is
available. `output` plaintext is bounded UTF-8 terminal output;
`resize` plaintext is canonical JSON `{ "cols": n, "rows": n }` with
`1 <= cols <= 500` and `1 <= rows <= 300`. The client derives a distinct 32-byte frame key for each
recipient and kind using HKDF-SHA256 (SHA-256, 32-byte output, UTF-8 session
UUID as salt) over that recipient's observer secret and canonical JCS info
`["atermius", "terminal-collaboration-frame", 1, vault_id,
membership_version, session_id, host_user_id, host_device_id,
recipient_user_id, recipient_device_id, "observer", epoch, kind]`. It
encrypts with XChaCha20-Poly1305-IETF and a fresh random 24-byte nonce carried
in the `nonce` field. Canonical JCS of the unsigned frame metadata (all frame
fields except `ciphertext` and `signature`) is AEAD additional authenticated
data. The host Ed25519-signs the canonical JCS object containing all frame
fields except `signature`, including the nonce and ciphertext.
Observers check exact context, sequence, host signature, AEAD tag, and payload
shape before rendering.

The server enforces the frame shape, target binding, role, current room epoch,
per-frame and per-session byte limits, rate limits, and bounded queues. A
WebSocket JSON application message is at most 64 KiB UTF-8; the host chunks
terminal output to at most 16 KiB UTF-8 per encrypted frame. It
does not decrypt or persist frames. Observer application frames are protocol
violations and close that observer connection. Slow observers are disconnected
without blocking the host or other observers. The Web host also caps projected
browser WebSocket send buffering at 128 KiB; if the browser remains above the
high-water mark for three seconds, it closes collaboration and clears the
ephemeral keys while leaving the host's independent SSH connection available.

## Limits of the v1 observer-only slice

This describes the v1 observer-only slice. It is a single-process,
memory-only Web implementation. It does not provide observer-request approval
during an active session, history replay, reconnect/resume, selective in-place
key rotation, tmux reattachment, native Android/iOS/Linux/Windows transports,
or multi-server room fanout. Host resize is authoritative; observers cannot
request a remote terminal resize. Revocation closes the room and requires the
host to create a new key and session. Offline or previously received plaintext
cannot be revoked from an observer device. Protocol v2 adds the narrowly scoped
controller lease described below.


## Protocol v2: host-approved single-controller input

This additive extension keeps the v1 observer protocol unchanged. A v1 room
cannot grant input control. A v2 room opts in at host-session creation; it may
still issue ordinary v1 observer tickets, and those observers remain read-only.
The host proactively chooses one already-approved observer device and grants
one short-lived controller lease. There is no silent downgrade from a requested
v2 session to v1. The create request uses `protocol_version: 2`; its initial
observer list and observer keyboxes retain the v1 shape. A request with any
other protocol version cannot later create a controller lease.

The SSH connection remains on the host device. Controller input is encrypted
end-to-end to the host and signed by the controller's registered device key.
The server validates the active lease, ticket identity, controller signature,
sequence and size limits, then forwards the opaque frame only to the host. It
does not decode terminal input, execute commands, receive host credentials, or
persist lease secrets or frame content. The host validates and decrypts the
frame before passing its bytes to the existing SSH terminal input sink.

### Host-created controller lease

`POST /api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease`

Only the authenticated host device for a v2 room may create a lease. The target
must be one of the session's explicitly approved observers and must still be an
active Vault member/device. At most one lease may be active. The host supplies
an unpredictable canonical UUID `lease_id`, `control_epoch`, and `expires_at`;
epochs start at one and increase by exactly one for every successful grant in
that room. Expiry must be a UTC RFC3339 timestamp representing a whole-second
instant (its fractional part, if present, must be zero), after the current
time, no more than five minutes ahead, and no later than the session expiry.
Clients round the requested deadline down to the nearest whole second before
signing the control keybox. Repeating the same grant after a lost response is
idempotent only while the exact same
lease is active; a different active lease is rejected until the host revokes
it or it expires.

The request contains the controller user/device IDs and a
`atermius-terminal-control-keybox-v2` object binding the session, Vault,
membership version, host and controller IDs, `lease_id`, `control_epoch`, the
purpose `input`, expiry, and `sealed_secret`. The host creates a fresh random
32-byte control secret for each lease, seals it to the approved controller
device's registered Curve25519 public key, and signs the JCS serialization of
the entire keybox except `signature` with its registered Ed25519 key. This
secret is independent of the v1 observer-output secret. The server verifies
the host signature and exact target/context but cannot open the sealed secret.
Lease records and tickets exist only in room memory.

A successful response is exactly the active lease metadata:

```json
{
  "lease_id": "<same lease UUID>",
  "control_epoch": 1,
  "expires_at": "<same UTC RFC3339 timestamp>"
}
```

The response does not echo the keybox or return the control secret. The host
keeps its lease secret only in local memory.

After the grant is committed, the server sends the exact target's already
authenticated v2 observer connection this event. If the target connects after
the grant, the server sends the same event after authenticating that observer
while the lease is still active:

```json
{
  "type": "controller_lease_granted",
  "session_id": "<UUID>",
  "lease_id": "<UUID>",
  "control_epoch": 1,
  "expires_at": "<UTC RFC3339 timestamp>"
}
```

This event contains no keybox or secret. It is delivered only to the selected
device in a v2 room and does not alter v1 observer connections or messages.
The client reveals its join-control action only after receiving this event.

The exact request shape is:

```json
{
  "controller_user_id": "<active Vault member user UUID>",
  "controller_device_id": "<active approved device UUID>",
  "lease_id": "<fresh canonical UUID>",
  "control_epoch": 1,
  "expires_at": "<UTC RFC3339 timestamp, at most five minutes ahead>",
  "keybox": {
    "format": "atermius-terminal-control-keybox-v2",
    "session_id": "<UUID>",
    "vault_id": "<route Vault UUID>",
    "membership_version": 1,
    "host_user_id": "<authenticated host user UUID>",
    "host_device_id": "<authenticated host device UUID>",
    "controller_user_id": "<same controller user UUID>",
    "controller_device_id": "<same controller device UUID>",
    "lease_id": "<same lease UUID>",
    "control_epoch": 1,
    "purpose": "input",
    "expires_at": "<same lease expiry>",
    "sealed_secret": "<canonical base64url-no-pad crypto_box_seal bytes>",
    "signature": "<canonical base64url-no-pad Ed25519 signature>"
  }
}
```

`POST /api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease/ticket`

Only the exact device named by the currently active lease may request this
empty-body route. The response contains a one-use, short-lived `ticket`,
`role: "controller"`, the lease ID and epoch, the signed `control_keybox`, the
ticket expiry, and the WebSocket connect path. The ticket is bound to the device,
account, login session, server generation, room, lease and controller role.
Ticket issuance and consumption recheck the lease, account/device/session,
Vault membership version and expiry. Revocation or expiry invalidates all
unconsumed tickets. The target must keep its existing observer connection open
to receive and decrypt host output. The controller connection is a separate
input-only channel and does not replace or duplicate the observer output path.
The response fields are exactly `ticket`, `role`, `lease_id`, `control_epoch`,
`control_keybox`, `ticket_expires_at`, and `connect_path`.

`DELETE /api/v1/vaults/{vault_id}/terminal-sessions/{session_id}/controller-lease`

Only the host device can revoke the active lease. Revocation and input
acceptance are serialized under the room lock and the existing authorization
writer ordering. The server clears lease state, invalidates outstanding
tickets, closes the controller socket with a fixed control-revoked reason, and
notifies the host connection with the lease ID and fixed lifecycle reason. It
does not close the host's SSH or collaboration connection.

### Encrypted input frames

After controller-ticket authentication, the client must receive and validate
the exact acknowledgement shape:

```json
{"type":"authenticated","role":"controller","session_id":"<UUID>","lease_id":"<UUID>","control_epoch":1}
```

The controller may then send only:

```json
{
  "type": "input",
  "frame": {
    "format": "atermius-terminal-input-frame-v2",
    "session_id": "<UUID>",
    "vault_id": "<UUID>",
    "membership_version": 1,
    "host_user_id": "<UUID>",
    "host_device_id": "<UUID>",
    "controller_user_id": "<UUID>",
    "controller_device_id": "<UUID>",
    "lease_id": "<UUID>",
    "control_epoch": 1,
    "sequence": 1,
    "nonce": "<canonical base64url-no-pad 24-byte XChaCha nonce>",
    "ciphertext": "<canonical base64url-no-pad XChaCha20-Poly1305 ciphertext+tag>",
    "signature": "<canonical base64url-no-pad Ed25519 signature>"
  }
}
```

The controller derives a distinct 32-byte input key with HKDF-SHA256 over the
lease-only secret, UTF-8 session UUID salt, and canonical JCS info:
`["atermius", "terminal-collaboration-input", 2, vault_id,
membership_version, session_id, host_user_id, host_device_id,
controller_user_id, controller_device_id, lease_id, control_epoch]`. It
encrypts raw terminal input bytes with XChaCha20-Poly1305-IETF and a fresh
24-byte nonce. Canonical JCS of all frame metadata except `ciphertext` and
`signature` is AEAD additional authenticated data. The controller signs the
canonical JCS object containing every frame field except `signature`. The
server verifies that signature against the registered controller-device
signing key; the host repeats context, identity, signature, lease and sequence
checks before decrypting and writing the bytes to SSH.

The controller socket is input-only: it receives no terminal output or
additional application messages. Its paired observer socket remains the sole
output stream. When the lease ends, the server sends the host
`controller_lease_ended` event shown below and closes the controller socket
with the fixed reason appropriate to the lifecycle action.

```json
{
  "type": "controller_lease_ended",
  "lease_id": "<UUID>",
  "reason": "revoked"
}
```

The allowed reasons are `revoked`, `expired`, and
`controller_disconnected`. The server sends this event to both the host and
the exact target observer connection, when connected. Other observers receive
nothing. The controller learns the lease ended from the WebSocket close and
clears its local lease secret and input key; the target observer clears its
pending grant and hides the join action. The observer output socket stays open.

Input sequence numbers start at one and increase exactly by one for each
accepted frame in the lease. The server and host reject duplicate, skipped,
out-of-order, expired, revoked, wrong-device, wrong-epoch or wrong-lease
frames. Encrypted input plaintext is at most 8 KiB per frame; WebSocket JSON
messages remain at most 64 KiB. The server applies per-lease frame/byte rate
limits and bounded host queues. Slow input delivery fails closed without
blocking host output. Only one controller may connect for a lease; a
controller disconnect ends the lease and requires a fresh host grant, keybox,
ticket, lease ID and sequence space.

Host disconnect, session stop/expiry, server restart, account/device/session
revocation, Vault membership revocation/version change, lease expiry or host
action clears the lease secret and closes its controller socket. After a lease
has been granted, v1 observers continue to receive only v1 output/resize
frames; any observer-originated application frame remains a protocol error.
Control input accepted before revocation takes effect may already have reached
the SSH connection and cannot be recalled. Previously received terminal
plaintext likewise cannot be revoked from an observer device.

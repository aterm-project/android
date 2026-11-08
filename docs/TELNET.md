# Telnet

Atermius includes an embedded Telnet client (`apps/client/lib/telnet/`). It is
a separate protocol (`HostProtocol.telnet`, default port 23), not a wrapper
around SSH or an OS `telnet` binary. No external program is launched.

## Security model

- **Telnet is plaintext.** Everything sent, including passwords typed at a
  login prompt, travels unencrypted. The host editor, the terminal (a yellow
  notice before connecting), the status bar and Host properties say so. No TLS
  or security claim is made for the connection. The saved Host entry itself
  remains encrypted like every other Vault/LocalVault record.
- **Login is always interactive.** Telnet Hosts cannot store a user name,
  password, private key, Keychain reference, Jump Host or port forwarding
  (`HostRecord.validate` rejects them; the editor hides those fields and drops
  them when an SSH Host is switched to Telnet). Group default credentials are
  never resolved for Telnet. The client never parses login prompts and never
  sends a credential automatically. NEW-ENVIRON/AUTHENTICATION are refused,
  so no user name is sent through options either.
- Error text is a fixed, localized category (refused, timed out, lookup
  failed, unreachable, relay unavailable, unsupported in browser, protocol
  error, connection lost, cancelled). Raw socket/OS/Relay text is never shown.
- Endpoint text written into the terminal is stripped of C0/C1 control
  characters and length-bounded, so a crafted host name cannot inject
  terminal escape sequences.
- SSH-only features (SFTP, SCP, `ssh_exec`, forwarding, OS probe, detach to
  window) stay gated on an SSH connection and are unavailable for Telnet.

## Transports

| Mode | Transport |
| --- | --- |
| Native (desktop/mobile), account or LocalVault | Direct TCP (`dart:io` `Socket`), 15 s connect timeout |
| Web, signed in to a server | Authenticated server Relay: `createRelayTicket` + `connectRelaySocket` (one-use ticket in the first frame, same CIDR/port allowlist, per-user/group policy and audit as SSH). The administrator must allow the destination port (e.g. 23); defaults are not changed. |
| Web LocalVault profile | Not supported (browsers cannot open raw TCP); an explicit message is shown. |

## Supported options (RFC 854/855, RFC 1143 Q method)

| Option | Direction | Behaviour |
| --- | --- | --- |
| ECHO (1, RFC 857) | server | Accepted; client requests `DO ECHO`. Client never echoes for the server (`DO ECHO` from server → `WONT`). No local line editing/echo is implemented. |
| SUPPRESS-GO-AHEAD (3, RFC 858) | both | Accepted; client requests `DO SGA`. |
| BINARY (0, RFC 856) | both | Accepted. Changes take effect in stream order, including within one packet. |
| TERMINAL-TYPE (24, RFC 1091) | client | Accepted on `DO`. `SEND` → `IS XTERM-256COLOR`, `XTERM`, `VT100`, then `VT100` repeated (end of list), then restarts. |
| NAWS (31, RFC 1073) | client | Offered proactively (`WILL NAWS`). Sent after enablement and on every size change; 255 bytes doubled; clamped 1..65535. |
| anything else | — | Refused (`DONT`/`WONT`) once; RFC 1143 prevents loops. |

## Data handling

- Streaming parser: IAC/IAC-IAC, commands and `SB … SE` may be split at any
  byte boundary. Subnegotiations are capped at 512 bytes; longer payloads are
  discarded but the stream stays synchronized. An IAC command inside SB ends
  the SB and resynchronizes.
- Receive NVT: without BINARY, `CR NUL` → `CR` (also across chunks). Output is
  decoded as UTF-8 (malformed bytes → U+FFFD).
- Send NVT: without BINARY every line ending (CR, LF, CR LF) is sent as
  `CR LF`; IAC (0xFF) is always doubled. With BINARY, bytes are raw except IAC
  doubling.
- Bounds: one input write is limited to 1 MiB after encoding; larger pastes
  are rejected whole (localized error, nothing partial is sent). More than
  4096 negotiation replies without any data closes the connection with a
  protocol error. The terminal scrollback uses the existing bounded terminal
  (10 000 lines cloud, 5 000 local).
- `close()` is idempotent; cancel during connect, connect timeout, tab close,
  lock or Vault/account/device scope changes close a late connection instead of
  attaching it. Queued output after a scope change is not written. A
  synchronous transport write failure ends the session with a sanitized error.

## UI integration

- Unified "+" menus (cloud and local), `NewSessionMenu`, host editor protocol
  selector, search palette filter chip and icon (`Icons.settings_ethernet`),
  host cards ("Telnet · host:port"), Host properties.
- Quick connect: `telnet host`, `telnet host:2323`, `telnet -p 2323 host`,
  `telnet --port=2323 host`, `telnet [2001:db8::1]:23`, `telnet 2001:db8::1`.
  `user@host` and `-l` are rejected (login is interactive).
- Tabs: independent duplicate, split (cloud peer selection includes live
  Telnet), saved window-set restore (`kind: telnet`), saved-workspace panes
  (reuse of a live Telnet pane, Vault-bound restore).
- MCP: sessions report `kind: "telnet"`, `terminal_read`/`terminal_write`
  work, `ssh_exec_available` and `sftp_available` are false.

## Limitations

- No LINEMODE (RFC 1184), NEW-ENVIRON, AUTHENTICATION, ENCRYPT, TSPEED,
  X-DISPLAY, STATUS, TIMING-MARK or Telnet-over-TLS.
- No local echo or local line editing for servers that do not echo.
- No transport write-backlog cap beyond the per-write 1 MiB limit (the OS/
  WebSocket sink buffers).
- Telnet tabs cannot be detached to a separate window (same as Console).
- Termius CSV import still reports `telnet` rows as an unsupported protocol.

# Troubleshooting

[中文](TROUBLESHOOTING.md) · [Install](INSTALLATION.en.md)

| Symptom | Check |
| --- | --- |
| Git clone or artifact download returns 404 | Repositories/artifacts are private. Use a GitHub account with repository access; do not put its token in a URL or README. |
| `pub get` rejects the SDK/lockfile | Select Flutter 3.47.5 / Dart 3.13 and keep the five local `packages/` forks. Use `--enforce-lockfile`; do not upgrade dependencies as a setup workaround. |
| Windows build reports missing `atermius_rdp.dll` | Build the native bundle first or set `ATERMIUS_RDP_DIR` to a matching bundle. See the desktop installation guide. |
| A copied executable will not start | Copy the entire generated runtime/bundle, including libraries, assets and licenses. |
| Android APK will not replace an installed app | Check application ID and signing certificate. A different signing key cannot update the existing package; preserve/export data before choosing a migration. |
| Browser requests external CanvasKit/fonts or violates CSP | Rebuild with `--no-web-resources-cdn`, deploy the complete build output and use the supplied proxy. |
| Browser cannot connect SSH | The account workspace needs Relay enabled with the exact public origin, permitted target CIDR and port. A local browser profile has no direct OS TCP transport. |
| RDP error `20008` | Check the target port/TLS first. If a certificate fingerprint is available, review the trust prompt; a generic handshake failure is not always an untrusted certificate. |
| Temporary link has no gateway capability | Use SQLite, HTTPS, guacd, gateway-key storage and explicit target policy. Check `/api/v1/instance` and the server logs without exposing secrets. |
| Guest link is not yet usable or is expired | Check UTC start/expiry, openings, attempt/concurrency limits and revocation. A different link's existing cookie cannot open this link. |
| Local settings/profile seem missing in a browser | Check the browser origin/profile, private mode and storage policy. A new origin is a separate storage scope. |
| Full Flutter suite fails while focused CI passes | Keep the documented baseline failures separate; reproduce and report the exact failing case. Do not label the full suite green. |
| One-click Termius import cannot read the key or the key is rejected | Open Termius Desktop once on this computer and choose Allow in the macOS Keychain prompt. If you switched between the App Store and downloaded builds, open the one you use and retry. Otherwise export CSV from Termius and import that file. |

For server deployment, health and backup questions use the [server documentation](https://github.com/aterm-project/server/blob/main/docs/README.md). For protocol details see [remote desktop](REMOTE-DESKTOP.md) and [Telnet](TELNET.md).

An issue report should state OS/architecture, app/source version, target protocol, a minimal reproduction and sanitized error text. Exclude passwords, private keys, access-link fragments, account tokens and user databases.

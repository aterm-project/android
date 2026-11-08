# Web frontend

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

The generated site is `apps/client/build/web`. `Dockerfile` builds a standalone
frontend image. It serves static files and proxies API/WebSocket routes to the
server service on the same Docker network, preserving a single browser origin.
See `deploy/compose.web.yaml` in the server repository. The browser SSH transport
requires an explicitly enabled and restricted server relay.

## Source layout

`apps/client` contains the Flutter application. `packages/{drift,sqlite3,xterm}`
contains the existing patched dependencies, with their upstream notices intact.
The relative paths are intentional: each repository builds independently without
cloning sibling repositories. `protocol` contains the shared API contract and test
vectors. The application name and package identifiers remain Atermius; the GitHub
organization name does not rename installed applications or their data stores.

Shared Dart code is vendored at the same reviewed snapshot in the four client
repositories. When changing shared code, apply the same reviewed change to each
client repository and verify the hashes recorded in `SOURCE_PROVENANCE.json`.
Platform runners stay in their owning repository. Do not copy build output or
private runtime data between repositories. Initial provenance records the import;
normal later changes are tracked by Git commits.

## Validation and limits

Use Flutter 3.47.5 / Dart 3.13 and the committed `pubspec.lock`:

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter test --concurrency=4 test/session_workspace_actions_test.dart test/workspace_tab_drag_test.dart test/terminal_tools_sidebar_test.dart
```

The imported Windows/Android application has prior build and device evidence.
Splitting the repository does not establish new platform acceptance. Existing
full-suite baseline failures/hangs are not represented as passing. CI runs the
focused checks above; it does not claim the full suite is green. No user keys,
signing secrets, test-machine passwords, local databases, build artifacts or agent
logs belong in this repository. Mobile push-provider configuration is supplied
separately. Keep upstream licenses when distributing bundled dependencies.

The server lives in the sibling `server` repository. The additional external
temporary-sharing/cloud collaboration design is a proposal, not a deployment.

## Latest imported transport support

The validated Local Shell/Telnet integration is included. See [Local Shell](docs/LOCAL-SHELL.md)
and [Telnet](docs/TELNET.md) for supported platforms and transport limits. Windows
packaging is handled separately; this repository import does not claim new device acceptance.

# Android client

Android SDK and JDK 17 are required.

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build apk --debug
```

Debug builds are suitable for development only. Configure your own signing key
for release distribution. Native RDP is not available on Android.

## Source layout

`apps/client` contains the Flutter application. `packages/{drift,sqlite3,xterm,dartssh2,desktop_drop}`
contains the existing patched dependencies, with their upstream notices intact.
The relative paths are intentional: each repository builds independently without
cloning sibling repositories. `protocol` contains the shared API contract and test
vectors. The application name and package identifiers remain Atermius; the GitHub
organization name does not rename installed applications or their data stores.

Shared Dart code is vendored at the same reviewed snapshot in the four client
repositories. When changing shared code, apply the same reviewed change to each
client repository and verify the hashes recorded in `SOURCE_SNAPSHOT.json`.
Platform runners stay in their owning repository. Do not copy build output or
private runtime data between repositories. `SOURCE_PROVENANCE.json` records the
initial import; `SOURCE_SNAPSHOT.json` records this reviewed integration.

## Validation and limits

Use Flutter 3.47.5 / Dart 3.13 and the committed `pubspec.lock`:

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter test --concurrency=2 test/session_workspace_actions_test.dart test/workspace_tab_drag_test.dart test/terminal_tools_sidebar_test.dart test/cloud_access_client_test.dart test/cloud_access_interop_test.dart
```

The imported Windows/Android application has prior build and device evidence.
Splitting the repository does not establish new platform acceptance. Existing
full-suite baseline failures/hangs are not represented as passing. CI runs the
focused checks above; it does not claim the full suite is green. No user keys,
signing secrets, test-machine passwords, local databases, build artifacts or agent
logs belong in this repository. Mobile push-provider configuration is supplied
separately. Keep upstream licenses when distributing bundled dependencies.

The server lives in the sibling [`server`](https://github.com/aterm-project/server)
repository. Organizations, teams, joining and owner-confirmed encrypted Host
sharing are implemented. Temporary browser links support custom addresses,
scheduled start/expiry, limits, rotation, revocation and session activity. These
controls appear only when the server advertises the required capabilities.

Temporary SSH/RDP access requires explicitly enabling the trusted gateway on a
SQLite server. Its key holder can decrypt access capsules and observe sessions;
this gateway is not zero-knowledge. PostgreSQL cloud routes remain closed, and
VNC requires explicit opt-in. See the server's
[cloud deployment guide](https://github.com/aterm-project/server/blob/main/docs/CLOUD-SHARING.md).
Source publication does not deploy a public service or install a new native app.

## Latest imported transport support

The validated Local Shell/Telnet integration is included. See [Local Shell](docs/LOCAL-SHELL.md)
and [Telnet](docs/TELNET.md) for supported platforms and transport limits. Windows
packaging is handled separately; this repository import does not claim new device acceptance.

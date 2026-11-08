# Desktop client: Windows, macOS, Linux

Windows and Linux runners are imported; the macOS runner is newly generated
with Flutter 3.47.5 and has not been built or tested on a Mac.

Windows requires Visual Studio C++ tools, CMake 3.28+ and vcpkg. Install
`openssl:x64-windows-static-md` and `zlib:x64-windows-static-md` with vcpkg.
First build the bundled
FreeRDP engine using `integration/native/build_rdp_windows.ps1 -VcpkgRoot <path>`.
Then run `flutter pub get --enforce-lockfile` and `flutter build windows` from
`apps/client`. Set `ATERMIUS_RDP_DIR` if using a separately built engine bundle.
The native engine build is capped at 8 workers; no USB driver is installed.

Linux requires CMake, Ninja, a C/C++ toolchain, GTK 3 development headers,
`libsecret-1-dev`, and a running desktop keyring service;
run `flutter build linux`. macOS requires Xcode; run `flutter build macos`.
Signing, notarization, permissions, native RDP and full UI behavior on Mac/Linux
require platform-specific validation; Windows RDP evidence does not cover them.

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

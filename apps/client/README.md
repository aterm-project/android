# Atermius Flutter client

Flutter client for Android, iOS, Windows, Linux and Web. Web uses the same encrypted vault and sync protocol as native clients; SSH bytes travel through the server's WebSocket relay while SSH authentication and host key checks remain in the browser.

## Toolchain

- Flutter 3.41 or newer, Dart 3.12 or newer
- Atermius API v1 server (see `../../protocol/API-CONTRACT.md`)
- Web builds need no platform SDK. Native builds also need the matching platform toolchain below.

## Native platform runners

The Flutter runners for Android, iOS, Linux and Windows are already present in this repository. You do not need to run `flutter create` to generate them. Build a target on a host with its platform tools installed, for example `flutter build apk`, `flutter build ios`, `flutter build linux` or `flutter build windows`.

| Target | Required build environment |
| --- | --- |
| Android | Android SDK command-line tools, a platform SDK and build tools, plus a compatible JDK. Android Studio can install and manage these. |
| iOS | macOS, Xcode and its command-line tools; signing is needed to install or distribute an app on devices. |
| Linux | Linux, CMake, Ninja, a C/C++ toolchain and GTK 3 development headers/libraries. |
| Windows | Windows, Visual Studio with the C++ desktop development workload and Windows SDK. |

The current development host is Linux. Flutter 3.47.5 is installed, but this host does not currently have the Android SDK (`adb`/`sdkmanager`), CMake or GTK 3 development files; it also cannot provide the macOS/Xcode or Windows/MSVC toolchains. Native release builds therefore have not been verified here. The Web build and its checks are documented below.

## Local setup

```sh
cd apps/client
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter run -d chrome
```

For native platforms, install that target's toolchain from the table above, then select the matching Flutter device or build target.

### Optional Android and iOS background sync hints

Native mobile builds can register a provider token for this device after the user turns on **Settings → Background sync notifications**. The permission prompt is made only by that action. Android uses FCM. On iOS, the client prefers the APNs device token when available; if it is unavailable, or the server reports that APNs delivery is disabled, the client uses FCM. The server keeps only one provider endpoint per device through a successful switch. The app stores only the opt-in bit in platform secure storage; it does not persist or display provider tokens. Tokens are sent directly to the authenticated current-device endpoint and encrypted by the server. FCM and APNs carry only the generic `sync_available` hint; WebSocket and polling remain the synchronization sources, and Web never initializes Firebase or registers an endpoint.

The client listens for `sync_available` only while the opted-in account/device session is active and the app is in the foreground. It accepts only that exact message type, discards the message data immediately, and uses the existing authenticated sync coordinator to pull encrypted changes. Background-isolate pulls are not supported: the background callback cannot safely reuse the unlocked workspace's in-memory vault keys and repository. A hint received while the app is backgrounded does not perform a pull; normal foreground resume, WebSocket and polling provide synchronization.

This feature is default-disabled. Pass Firebase client options at build time for both platform apps. The values are client configuration, not server credentials, and are compiled into the mobile app. Do not include the server service-account JSON in a client build.

```sh
cd apps/client
flutter build apk \
  --dart-define=ATERMIUS_FCM_API_KEY=<firebase-web-api-key> \
  --dart-define=ATERMIUS_FCM_PROJECT_ID=<firebase-project-id> \
  --dart-define=ATERMIUS_FCM_SENDER_ID=<firebase-messaging-sender-id> \
  --dart-define=ATERMIUS_FCM_ANDROID_APP_ID=<firebase-android-app-id>

flutter build ios \
  --dart-define=ATERMIUS_FCM_API_KEY=<firebase-web-api-key> \
  --dart-define=ATERMIUS_FCM_PROJECT_ID=<firebase-project-id> \
  --dart-define=ATERMIUS_FCM_SENDER_ID=<firebase-messaging-sender-id> \
  --dart-define=ATERMIUS_FCM_IOS_APP_ID=<firebase-ios-app-id> \
  --dart-define=ATERMIUS_FCM_IOS_BUNDLE_ID=<ios-bundle-id>
```

When FCM delivery is enabled or used as the iOS fallback, use the Firebase project ID that owns the app registrations. It must exactly match the `project_id` in the self-hosted server's service-account file configured with `ATERMIUS_FCM_SERVICE_ACCOUNT_FILE`; otherwise FCM rejects token delivery. The Android Firebase app package must match the app's Android application ID, and the iOS Firebase app bundle ID must match `ATERMIUS_FCM_IOS_BUNDLE_ID`. Direct APNs delivery requires the server-side APNs key and topic documented in [`deploy/README.md`](../../deploy/README.md). For iOS, enable Push Notifications and Background Modes → Remote notifications for the app, use a provisioning profile with the matching APNs environment, and configure the APNs authentication key for that Firebase project when FCM is used. The Xcode target includes the remote-notification background mode and development/production APNs entitlement by build configuration.

Without all required per-platform build defines, the Settings control explains that FCM is unavailable and remains disabled. This does not affect account sync, WebSocket notifications, or polling. Build and test Web normally; no Firebase options are required for Web.

## Verification

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build web --release --no-web-resources-cdn
flutter test test/web_build_config_test.dart
```

The Web release must be built with `--no-web-resources-cdn`. Flutter then sets `useLocalCanvasKit` in its bootstrap build config and loads CanvasKit from the same-origin `canvaskit/` directory; this is required by the strict Content Security Policy. The custom loader also points Flutter's Unicode fallback font service at same-origin `fonts/`. The complete fallback font map emitted by the current Flutter Web SDK is bundled there with per-family OFL notices, so CJK, symbol and emoji rendering does not depend on Google Fonts at runtime. `web_build_config_test.dart` checks CanvasKit files and every fallback URL in the compiled SDK map. Serve the Web release over HTTPS. Set the API base URL in the first-run screen; remote API URLs must use HTTPS, while plain HTTP is accepted only for `localhost`, `127.0.0.1` and `::1` development. Server Vault rows and pending envelopes are stored by Drift; private Vault material is wrapped locally and kept in platform secure storage only while the Vault is unlocked.

### Encrypted record object references

The generic record envelope supports an optional `header.object_refs` extension, derived from plaintext `_manifest.object_refs`. References are lowercase canonical UUIDs in strictly ascending order, unique, with a maximum of 1024 entries. The header is covered by both the AEAD associated data and device signature. Empty or omitted references retain the legacy envelope shape without an empty header field. Decryption rejects malformed references or any header/manifest mismatch. Record DTOs and conflict resolution preserve `_manifest` when records are edited or re-encrypted.

Host cards include an encrypted attachment manager for upload, download and removal. Each attachment has a random object key; the client encrypts file content in 4 MiB logical AES-GCM chunks and puts its name, media type and key in the encrypted Host manifest. The server stores opaque object ciphertext and signed references. Persistent transfer jobs support retry, cancel and Range download continuation; Web acceptance covers lost upload acknowledgements, expired upload reservations, page reload and Chromium process restart. The client still caps a file at 256 MiB and uses whole-file picker/decrypt buffers; native cross-platform transfer acceptance remains.

## Current implementation boundary

Implemented client workflows:

- First-run instance setup, bootstrap registration with a client-generated account and personal Vault, password login, local unlock and lock/sign-out.
- Encrypted host, group, credential and snippet CRUD. Record envelopes and the durable outbox are local-first; credentials, private keys and passphrases are never sent to the API as plaintext.
- Separate local-only profile mode: create/unlock/lock a profile; create, read, edit and delete encrypted Hosts, Credentials and nested Groups in an isolated LocalVault database. Group parent links and Host assignments are checked transactionally; groups with active Host/child references cannot be deleted. Credential lists hold only name, username, authentication kind and revision; passwords/private keys/passphrases stay inside encrypted records and are masked in the editor. The flow makes no API request and does not sync across devices. Snippets, preferences, local SSH/SFTP, encrypted export/import and local-to-server migration remain unimplemented. Chromium acceptance covers CRUD, hierarchy/reference behavior, reload/unlock recovery, ciphertext-only browser storage and zero API/external-origin requests. Native build/runtime acceptance remains.
- Authenticated pull/push sync, retry-safe queued edits, revision conflict branch preservation and explicit local/remote resolution.
- SSH shell over the WebSocket relay in browsers and direct SSH on native targets. First-seen host keys require user confirmation; changed fingerprints are rejected.
- SFTP list/navigation, folder creation, file upload/download and deletion using the SSH connection.
- Copy/paste device-enrollment requests for a fresh browser, with explicit review of identity fingerprints on an already approved member device. Approval seals every locally held Vault/epoch key to the new device; private keys remain local.
- Vault selection/creation, sync status, device listing/revocation controls and server/instance settings.
- Settings password change. The client derives the old/new login material and re-wraps the existing account key locally; it does not send the master password. The server revokes other sessions and supports an exact retry on the active session. An uncertain request is retained in client memory only and is lost on logout or process restart.
- Host attachment listing, encrypted upload/download, and removal. Viewer members can list and download but cannot upload or remove.
- Portable encrypted Vault archive export/import from Settings. The v1 archive includes a fixed server history snapshot, tombstones present in that history, local outbox/conflict branches, referenced encrypted objects and epoch keys. It uses an independent Argon2id-derived key and XChaCha20-Poly1305 authenticated chunks; archive files contain no session token or device private key. Import fully validates into staging before applying and can upload a missing immutable object only after its archived bytes and references pass validation.
- Account deletion from Settings uses a separate password re-check, displays the server's exact `purge_after`, and clears local session/decrypted key state without sending logout after server-side revocation. The login page exposes a sessionless cancellation action; it only restores the account/device state and requires a separate explicit login.

Archive restore is restricted to the same server space and Vault; cross-space remapping/resigning is rejected. The archive cannot recover data already purged by the server unless a prior archive exists. Historical attachment/object bytes are included when reachable from signed records or retained in the local encrypted-object cache. The client calls `GET /api/v1/vaults/{vault_id}/devices` to validate historical signatures and fails closed if signer ownership cannot be verified.

### Permanent record purge

The Web recycle bin exposes permanent purge only to the active Vault Owner and only after the displayed restore deadline. The confirmation requires an explicit acknowledgement and sends the tombstone revision ID and sequence shown by the current snapshot; SQLite and restricted PostgreSQL recheck the owner, exact current tombstone, retention deadline, unresolved conflicts and verified redaction-v1 support for every active Vault device. Purge removes payloads from active server state and clients verify and apply the signed redaction through sync before advancing their cursor. It cannot erase offline device copies or retained backups; restoring a pre-purge backup may restore old payloads.

The Owner automatic-purge control stores consent separately for each exact tombstone. It calls `PUT /api/v1/vaults/{vault_id}/records/{record_id}/automatic-purge` with the strict body `{expected_deleted_revision_id,expected_deleted_seq,expected_policy_revision,enabled}`. Consent defaults to off, compare-and-set uses the policy revision, restore and a later delete reset the new tombstone to off at revision 0, and re-enabling after opt-out advances the revision. The existing hourly and administrator Maintenance paths run a bounded scan; the exact purge transaction rechecks Owner consent, restore deadline, and its other safety conditions. Enabling consent does not purge the record immediately. Backup restore opts any enabled consent out, and legacy backups without the exact tombstone policy remain opted out. Consent does not erase offline device copies, exports, or older encrypted backups; restoring a pre-purge backup may restore ciphertext.

Follow-up work: complete member lifecycle and key-rotation recovery, QR enrollment, multi-hop SSH/port-forwarding UI, resumable large-file transfers and cross-platform attachment acceptance, complete bilingual copy and platform lifecycle hardening.

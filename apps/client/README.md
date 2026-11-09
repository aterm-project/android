# Atermius Flutter application

[Repository installation guide](../../docs/INSTALLATION.en.md) · [中文安装指南](../../docs/INSTALLATION.md) · [First use](../../docs/GETTING_STARTED.en.md)

This directory is the shared application layer. Use **Flutter 3.47.5 / Dart 3.13** and the committed lockfile. The four client repositories carry identical shared Dart code and their own platform runners; use the repository that owns the platform you are building.

| Target | Repository | Host tools |
| --- | --- | --- |
| Windows/macOS/Linux | [desktop](https://github.com/aterm-project/desktop) | Platform toolchain; Windows also needs its native RDP bundle |
| Android | [android](https://github.com/aterm-project/android) | Android SDK and JDK 17 |
| iOS | [ios](https://github.com/aterm-project/ios) | macOS, Xcode and signing for devices |
| Browser | [web](https://github.com/aterm-project/web) | Flutter SDK; API and same-origin proxy for deployment |

From this directory:

```sh
flutter --version
flutter doctor -v
flutter pub get --enforce-lockfile
```

The repository includes generated Dart models/localizations. Normal builds do not require regenerating the database. After an intentional schema/catalog change, use the appropriate generator and review its diff. Do not run `flutter create .` over an existing platform runner.

## Source map

`lib/ui` contains workspace/settings surfaces, `lib/ssh` and `lib/desktop` session plumbing, `lib/cloud` cloud access, and `lib/storage` encrypted persistence. Local path overrides resolve to `../../packages/{drift,sqlite3,xterm,dartssh2,desktop_drop}`; keep these forks and their notices together with the app.

Local profiles support terminals, files, groups, snippets and the applicable local workflows. Synchronized Vaults add encrypted sync, trusted-device enrollment and owner-controlled sharing. Browser regular SSH uses a restricted byte Relay; temporary access instead uses the explicitly trusted gateway. See [features](../../docs/FEATURES.md) and [sharing](../../docs/SHARING.en.md) for boundaries.

## Checks and distribution

Run the focused commands in [development](../../docs/DEVELOPMENT.md). Full-suite historical failures and native device acceptance are separate from those checks. Web output requires `--no-web-resources-cdn` so CanvasKit/fonts stay same-origin. Native bundles must include required libraries/assets; a lone executable is insufficient.

Optional mobile push is default-off and carries synchronization hints, not Vault content. Client Firebase options and server provider credentials are separate. See the [mobile push setup](../../docs/MOBILE-PUSH.md); never bundle a server service-account private key in a client.

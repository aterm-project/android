# Build and install on Android

[中文](INSTALLATION.md) · [README](../README.md)

## Repository access and SDK

Repositories are private. Authenticate your Git credential helper with an account that has access. With GitHub CLI, `gh auth login` then `gh auth setup-git` configures HTTPS Git without embedding a token in the clone URL. Existing SSH-key authentication also works.

Install **Flutter 3.47.5**, which supplies **Dart 3.13**, from the [official archive](https://docs.flutter.dev/install/archive), add its `bin` directory to PATH, then run `flutter --version` and `flutter doctor -v`. Keep `pubspec.lock` and all five local dependency forks. The toolchain requirement is stricter than some old README text.

There is no current-main consumer installer in Releases. Desktop `ci-input-*` archives are build inputs. The commands below build your own application; CI source checks alone are not native device acceptance.

## Development APK

Install Android Studio/SDK command-line tools, the platform/build tools selected by the pinned Flutter Gradle plugin, and **JDK 17**. This project targets Java/Kotlin 17 and uses AGP 9.1.0; resolve Android-toolchain issues in `flutter doctor -v`. Accept Android SDK licenses interactively. Enable USB debugging or use an emulator.

```sh
git clone https://github.com/aterm-project/android.git
cd android/apps/client
flutter doctor -v
flutter doctor --android-licenses
flutter pub get --enforce-lockfile
flutter build apk --debug
adb devices
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

The application ID is `com.atermius.aterm_client`. The output path above is relative to `apps/client`. `adb install -r` requests an update while retaining data, but requires a compatible signing identity. Do not uninstall a differently signed existing app before exporting its data.

## Release distribution

The checked-in `release` Gradle variant currently uses **debug signing**. Merely running `flutter build apk --release` does not create a production-signed distribution. Configure your own keystore/signing configuration following [Flutter Android signing](https://docs.flutter.dev/deployment/android#sign-the-app), keep keys/password files outside Git and preserve that identity for updates.

After signing has been configured:

```sh
flutter build apk --release
flutter build appbundle --release
```

Outputs are `build/app/outputs/flutter-apk/app-release.apk` and `build/app/outputs/bundle/release/app-release.aab`. App Bundles are for a store/distributor, not directly installed with `adb install`. No current Play Store release is provided by this repository.

## First use and scope

Choose local data or your HTTPS self-hosted instance. SSH uses the native transport; local shell/serial Console and the Windows native RDP engine are not Android features. Temporary guest links can be opened in a supported browser. Mobile OS background limits may interrupt sessions/forwarding. Optional [push hints](MOBILE-PUSH.md) require separate provider configuration.

## Update an existing build

Export/back up the workspace first, close Atermius, update this checkout with `git pull --ff-only`, resolve dependencies with the same pinned SDK/lockfile and rebuild. Replace the complete runtime bundle; keep the native engine and Dart app from the same build. Preserve the application's data and, on mobile, its signing identity. Source, SDKs and build caches belong on the build workstation/CI; a runtime computer only needs the finished application and its runtime dependencies.

[First use](GETTING_STARTED.en.md) · [Troubleshooting](TROUBLESHOOTING.en.md) · [Developer checks](DEVELOPMENT.md)

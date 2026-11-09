# Build the iOS client

[中文](INSTALLATION.md) · [README](../README.md)

## Repository access and SDK

Repositories are private. Authenticate your Git credential helper with an account that has access. With GitHub CLI, `gh auth login` then `gh auth setup-git` configures HTTPS Git without embedding a token in the clone URL. Existing SSH-key authentication also works.

Install **Flutter 3.47.5**, which supplies **Dart 3.13**, from the [official archive](https://docs.flutter.dev/install/archive), add its `bin` directory to PATH, then run `flutter --version` and `flutter doctor -v`. Keep `pubspec.lock` and all five local dependency forks. The toolchain requirement is stricter than some old README text.

There is no current-main consumer installer in Releases. Desktop `ci-input-*` archives are build inputs. The commands below build your own application; CI source checks alone are not native device acceptance.

## Build host

Use **macOS with Xcode and its command-line tools**. Install dependency tooling requested by `flutter doctor` (including CocoaPods when the selected plugin integration requires it). Windows/Linux cannot build a signed iOS application. Follow [Flutter iOS release setup](https://docs.flutter.dev/deployment/ios).

```sh
git clone https://github.com/aterm-project/ios.git
cd ios/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

A no-codesign build checks compilation only; it is not an installable signed release. Its app bundle is normally under `build/ios/iphoneos/Runner.app`. For a simulator, use `flutter build ios --simulator` and a compatible simulator target.

## Device and distribution signing

In `Runner.xcworkspace`, select the Runner target, set your Apple team and unique Bundle ID, and configure the device/profile and entitlements. The current Bundle ID is `com.atermius.atermClient`; use your own registered identity for distribution. Optional push needs the matching APNs environment and provider setup in [mobile hints](MOBILE-PUSH.md).

With signing ready, run from `apps/client`:

```sh
flutter build ipa --release
```

The exported package is under `build/ios/ipa/`. Use your supported Apple device/TestFlight/App Store distribution workflow. No current App Store/TestFlight release or iOS device/UI acceptance is claimed here. Native Windows RDP is not included.

## Update an existing build

Export/back up the workspace first, close Atermius, update this checkout with `git pull --ff-only`, resolve dependencies with the same pinned SDK/lockfile and rebuild. Replace the complete runtime bundle; keep the native engine and Dart app from the same build. Preserve the application's data and, on mobile, its signing identity. Source, SDKs and build caches belong on the build workstation/CI; a runtime computer only needs the finished application and its runtime dependencies.

[First use](GETTING_STARTED.en.md) · [Troubleshooting](TROUBLESHOOTING.en.md) · [Developer checks](DEVELOPMENT.md)

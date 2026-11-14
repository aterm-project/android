# Build the iOS client

[中文](ios.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md)

First complete repository access, cloning and the Flutter toolchain in the [install overview](../INSTALLATION.en.md). Every command below starts from the repository root.

## Build host

Use **macOS with Xcode 26+ and its command-line tools**, CocoaPods 1.16+, CMake 3.28+, Ninja and any other dependency tooling requested by `flutter doctor`. Windows/Linux cannot build a signed iOS application. Follow [Flutter iOS release setup](https://docs.flutter.dev/deployment/ios).

## One-step build script

The repository includes the OpenSSL 3.5.9 + FreeRDP 3.33.0 native engine `atermius_rdp.xcframework`, with device (`ios-arm64`) and simulator (`ios-arm64-simulator`) slices, and a one-step build script:

```sh
# Build both the simulator package (.app/.zip) and the unsigned device package (.unsigned.ipa)
./scripts/build_ios.sh --all

# Simulator app only
./scripts/build_ios.sh --simulator

# Release unsigned device IPA only
./scripts/build_ios.sh --unsigned-ipa
```

The script verifies or builds `apps/client/native/desktop/build/ios/bundle/atermius_rdp.xcframework`, embeds the matching-architecture `atermius_rdp.framework` and licenses for the current target, and writes to **`dist/`** at the repository root:

- **`Atermius-iphonesimulator.app`** / **`Atermius-iphonesimulator-arm64.zip`** (install into a simulator with `xcrun simctl install booted`)
- **`Atermius-ios-unsigned.ipa`** (with a `.sha256` checksum)

The unsigned IPA cannot be installed on a device until it is signed as described below. Add `--rebuild-engine` to rebuild the engine.

## Manual Flutter build

To check compilation without the script:

```sh
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

A no-codesign build checks compilation only; it is not an installable signed release. Its app bundle is normally under `build/ios/iphoneos/Runner.app`. For a simulator, use `flutter build ios --simulator` and a compatible simulator target. A manual build does not perform the script's engine verification and embedding.

## Device and distribution signing

The project is configured for automatic signing (`CODE_SIGN_STYLE = Automatic`) with development-team settings. The default `Runner.entitlements` does not require the restricted push entitlement, so an ordinary development provisioning profile can sign it. To enable production APNs push, point `CODE_SIGN_ENTITLEMENTS` at `Runner/RunnerPush.entitlements`; the push environment and provider setup are in [mobile hints](../MOBILE-PUSH.md).

The current Bundle ID is `com.atermius.atermClient`; use your own registered identity for distribution. To build a device-signed IPA with your local developer certificate:

```sh
./scripts/build_ios.sh --device --team-id <YOUR_TEAM_ID> --bundle-id <YOUR_PROVISIONED_BUNDLE_ID>
```

The output is **`dist/Atermius-ios-signed.ipa`** at the repository root.

Alternatively, in `apps/client/ios/Runner.xcworkspace` select the Runner target, set your Apple team and unique Bundle ID, configure the device/profile and entitlements, and run on a connected device. With signing ready you can also run from `apps/client`:

```sh
flutter build ipa --release
```

The exported package is under `build/ios/ipa/`. Use your supported Apple device/TestFlight/App Store distribution workflow. No current App Store/TestFlight release or iOS device/UI acceptance is claimed here. The Windows native RDP engine (`atermius_rdp.dll`) is not used on iOS; iOS uses the `atermius_rdp.xcframework` above.

Before updating an existing build, read "Update an existing build" in the [install overview](../INSTALLATION.en.md).

[First use](../GETTING_STARTED.en.md) · [Troubleshooting](../TROUBLESHOOTING.en.md) · [Developer checks](../DEVELOPMENT.md)

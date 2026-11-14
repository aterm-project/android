# Build and install the desktop client

[中文](desktop.md) · [Install overview](../INSTALLATION.en.md) · [README](../../README.md)

First complete repository access, cloning and the Flutter toolchain in the [install overview](../INSTALLATION.en.md). Every command below starts from the repository root.

## Windows x64

Use Windows with **Visual Studio 2022**, the **Desktop development with C++** workload, Windows SDK and CMake 3.28+. The native helper currently chooses the VS 2022 generator explicitly. See [Flutter Windows setup](https://docs.flutter.dev/platform-integration/windows/setup) for the host toolchain.

Run PowerShell on the build workstation from the repository root. If you already have vcpkg, set `$atermVcpkgRoot` to that checkout and skip its clone/bootstrap. Run these commands sequentially:

```powershell
$atermVcpkgRoot = Join-Path $env:USERPROFILE 'src\vcpkg'
git clone https://github.com/microsoft/vcpkg.git $atermVcpkgRoot
& (Join-Path $atermVcpkgRoot 'bootstrap-vcpkg.bat')
$env:VCPKG_MAX_CONCURRENCY = '8'
$env:CMAKE_BUILD_PARALLEL_LEVEL = '8'
& (Join-Path $atermVcpkgRoot 'vcpkg.exe') install openssl:x64-windows-static-md zlib:x64-windows-static-md
.\integration\native\build_rdp_windows.ps1 -VcpkgRoot $atermVcpkgRoot -Workers 8
$env:ATERMIUS_RDP_DIR = (Resolve-Path 'apps/client/native/desktop/build/windows/bundle').Path
cd apps/client
flutter pub get --enforce-lockfile
flutter build windows --release
```

The helper pins FreeRDP 3.33.0, verifies its source digest and builds a bundle with licenses and `build-manifest.json`. Windows CMake requires `atermius_rdp.dll`; this is a build prerequisite even if you do not plan to open RDP. Do not substitute an arbitrary DLL. Optional USB builds/hardware need separate setup and acceptance; this guide installs no driver.

The application output is **`apps/client/build/windows/x64/runner/Release/`**. Copy the entire directory to the runtime machine, then start **`aterm_client.exe`**. Keep `data/`, Flutter/plugin/native DLLs and licenses together. Install the supported Microsoft C++ x64 runtime if the target lacks it, following [Flutter distribution guidance](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows). Create a desktop shortcut to this executable with the application's directory as its working directory. No Flutter SDK or Visual Studio is needed on the runtime machine.

A portable archive can be made from `apps/client`:

```powershell
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath Atermius-windows-x64.zip
```

This is not a signed installer. Signing/distribution is the distributor's separate step.

## Linux

Use a Linux build host and an active desktop D-Bus/Secret Service keyring (for example an unlocked GNOME Keyring). The following package example is for Debian/Ubuntu; other distributions need equivalent development packages.

```sh
sudo apt-get update
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build linux --release
```

Keep the complete **`apps/client/build/linux/<arch>/release/bundle/`** directory, including `lib/` and `data/`. Run it inside the target desktop session so secure storage is available. See [Flutter Linux distribution](https://docs.flutter.dev/platform-integration/linux/building). Native Windows RDP is not included in Linux; consult [remote desktop](../REMOTE-DESKTOP.md) for the gateway path. Current Linux source/widget CI is not a new running-Linux-GUI acceptance.

## macOS (Apple Silicon arm64)

Use macOS with Xcode 26+, its command-line tools, CMake 3.28+, Ninja and any other dependency tooling requested by `flutter doctor`. Make sure the pinned **Flutter 3.47.5 / Dart 3.13.4** is on `PATH`.

### One-step build script

The repository includes an Apple-native FreeRDP 3.33.0 + OpenSSL 3.5.9 direct-connection engine and a complete packaging script. From the repository root:

```sh
./scripts/build_macos.sh --release
```

The script runs the whole pipeline:

1. Checks and, when needed, builds `apps/client/native/desktop/build/macos/bundle/libatermius_rdp.dylib` (exporting all 25 `aterm_rdp_*` C ABI symbols and verifying it has no external non-system dynamic library dependencies).
2. Runs `flutter pub get --enforce-lockfile` and `flutter build macos --release`.
3. Embeds `libatermius_rdp.dylib` and its open-source licenses into `Atermius.app/Contents/Frameworks/` and `Contents/Resources/atermius_rdp_licenses/`, and verifies the `aterm_macos_*` file-clipboard/display-layout FFI symbols exported by the main executable.
4. Detects an `Apple Development` certificate in the local keychain (pass `--adhoc` in certificate-less CI) for layered code signing, then verifies with `codesign --verify --deep --strict`.
5. Writes **`Atermius.app`**, **`Atermius-macos-arm64.zip`**, **`Atermius-macos-arm64.dmg`** and their `.sha256` digest files to **`dist/`** at the repository root.

The script also accepts `--debug`, `--profile`, `--skip-dmg`, `--rebuild-engine` and `--sign-identity`; run it with `--help` for details.

### Manual Flutter build

You can also build the preserved macOS runner directly:

```sh
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build macos --release
open macos/Runner.xcworkspace
```

The `.app` is under **`apps/client/build/macos/Build/Products/Release/`**. A manual build runs only the Flutter part; it does not perform the script's engine build, embedding, FFI symbol checks or signing verification.

For interactive debugging in Xcode, open `apps/client/macos/Runner.xcworkspace` after building the engine once. The Windows native RDP engine (`atermius_rdp.dll`) is not used on macOS. The runner has not had current macOS device/UI acceptance. Before public distribution, configure your signing team and entitlements, sign with a Developer ID Application certificate and complete Apple notarization. See [Flutter macOS distribution](https://docs.flutter.dev/platform-integration/macos/building).

Before updating an existing build, read "Update an existing build" in the [install overview](../INSTALLATION.en.md).

[First use](../GETTING_STARTED.en.md) · [Troubleshooting](../TROUBLESHOOTING.en.md) · [Developer checks](../DEVELOPMENT.md)

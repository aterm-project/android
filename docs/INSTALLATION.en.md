# Build and install the desktop client

[中文](INSTALLATION.md) · [README](../README.md)

## Repository access and SDK

Repositories are private. Authenticate your Git credential helper with an account that has access. With GitHub CLI, `gh auth login` then `gh auth setup-git` configures HTTPS Git without embedding a token in the clone URL. Existing SSH-key authentication also works.

Install **Flutter 3.47.5**, which supplies **Dart 3.13**, from the [official archive](https://docs.flutter.dev/install/archive), add its `bin` directory to PATH, then run `flutter --version` and `flutter doctor -v`. Keep `pubspec.lock` and all five local dependency forks. The toolchain requirement is stricter than some old README text.

There is no current-main consumer installer in Releases. Desktop `ci-input-*` archives are build inputs. The commands below build your own application; CI source checks alone are not native device acceptance.

## Windows x64

Use Windows with **Visual Studio 2022**, the **Desktop development with C++** workload, Windows SDK and CMake 3.28+. The native helper currently chooses the VS 2022 generator explicitly. See [Flutter Windows setup](https://docs.flutter.dev/platform-integration/windows/setup) for the host toolchain.

Run PowerShell on the build workstation. If you already have vcpkg, set `$atermVcpkgRoot` to that checkout and skip its clone/bootstrap. Run these commands sequentially:

```powershell
git clone https://github.com/aterm-project/desktop.git
cd desktop
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
git clone https://github.com/aterm-project/desktop.git
cd desktop/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build linux --release
```

Keep the complete **`apps/client/build/linux/<arch>/release/bundle/`** directory, including `lib/` and `data/`. Run it inside the target desktop session so secure storage is available. See [Flutter Linux distribution](https://docs.flutter.dev/platform-integration/linux/building). Native Windows RDP is not included in Linux; consult [remote desktop](REMOTE-DESKTOP.md) for the gateway path. Current Linux source/widget CI is not a new running-Linux-GUI acceptance.

## macOS

Use macOS, Xcode/command-line tools and any dependency tooling requested by `flutter doctor`. Build using this repository's preserved macOS runner:

```sh
git clone https://github.com/aterm-project/desktop.git
cd desktop/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build macos --release
open macos/Runner.xcworkspace
```

The `.app` is under **`apps/client/build/macos/Build/Products/Release/`**. Configure your signing team, entitlements and notarization before distribution. The runner has not had current macOS device/UI acceptance; the Windows RDP engine does not establish Mac support. See [Flutter macOS distribution](https://docs.flutter.dev/platform-integration/macos/building).

## Update an existing build

Export/back up the workspace first, close Atermius, update this checkout with `git pull --ff-only`, resolve dependencies with the same pinned SDK/lockfile and rebuild. Replace the complete runtime bundle; keep the native engine and Dart app from the same build. Preserve the application's data and, on mobile, its signing identity. Source, SDKs and build caches belong on the build workstation/CI; a runtime computer only needs the finished application and its runtime dependencies.

[First use](GETTING_STARTED.en.md) · [Troubleshooting](TROUBLESHOOTING.en.md) · [Developer checks](DEVELOPMENT.md)

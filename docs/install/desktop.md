# 桌面版构建与安装

[English](desktop.en.md) · [安装总览](../INSTALLATION.md) · [README](../../README.zh-CN.md)

先按[安装总览](../INSTALLATION.md)完成仓库权限、克隆与 Flutter 工具链准备。以下命令都从仓库根目录开始。

## Windows x64

构建机需要 Windows、**Visual Studio 2022** 的 **使用 C++ 的桌面开发**工作负载、Windows SDK 与 CMake 3.28+。原生构建脚本明确使用 VS 2022 生成器，参考 [Flutter Windows 环境说明](https://docs.flutter.dev/platform-integration/windows/setup)。

在开发机 PowerShell 中进入仓库根目录，按顺序执行。已有 vcpkg 时，将 `$atermVcpkgRoot` 改为实际路径，跳过克隆与 bootstrap：

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

原生脚本固定 FreeRDP 3.33.0 并核对来源摘要，输出带许可证和 `build-manifest.json` 的 bundle。Windows CMake 要求存在匹配的 `atermius_rdp.dll`，即使暂不使用 RDP 也需先构建；不要随意替换 DLL。可选 USB 构建及硬件需要单独配置/验收，本指南不安装驱动。

成品目录为 **`apps/client/build/windows/x64/runner/Release/`**，将**完整目录**部署到运行机器，启动 **`aterm_client.exe`**。保留 `data/`、Flutter/插件/原生 DLL 与许可证；目标缺少 C++ 运行库时按 [Flutter 分发说明](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)配置受支持的微软 x64 运行库。为 EXE 创建桌面快捷方式，工作目录设为应用目录。运行机器不需要 Flutter SDK、Visual Studio 或源码。

可在 `apps/client` 打包便携目录：

```powershell
Compress-Archive -Path build\windows\x64\runner\Release\* -DestinationPath Atermius-windows-x64.zip
```

这不是已签名安装器，正式签名与分发需由发行方另外完成。

## Linux

需要 Linux 构建机，以及桌面会话内可用的 D-Bus/Secret Service 安全存储，例如已解锁的 GNOME Keyring。下例适用于 Debian/Ubuntu，其他发行版安装等价开发包：

```sh
sudo apt-get update
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libsecret-1-dev liblzma-dev
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build linux --release
```

部署 **`apps/client/build/linux/<arch>/release/bundle/`** 完整目录，保留 `lib/`、`data/`，在目标桌面会话运行。参考 [Flutter Linux 分发](https://docs.flutter.dev/platform-integration/linux/building)。Linux 不包含 Windows 原生 RDP 引擎，网关路径见[远程桌面](../REMOTE-DESKTOP.md)。当前 Linux 源码/组件 CI 不代表新版本 Linux GUI 已验收。

## macOS（Apple Silicon arm64）

在 macOS 安装 Xcode 26+、命令行工具、CMake 3.28+ 与 Ninja，以及 `flutter doctor` 提示的其他依赖工具，并确保锁定的 **Flutter 3.47.5 / Dart 3.13.4** 位于 `PATH`。

### 一键打包脚本

仓库内置 Apple 原生 FreeRDP 3.33.0 + OpenSSL 3.5.9 直连引擎与完整一键打包脚本，在仓库根目录执行：

```sh
./scripts/build_macos.sh --release
```

脚本会自动完成以下闭环：

1. 检查并按需编译 `apps/client/native/desktop/build/macos/bundle/libatermius_rdp.dylib`（导出全部 25 个 `aterm_rdp_*` C ABI 符号，并校验无外部非系统动态库依赖）；
2. 执行 `flutter pub get --enforce-lockfile` 与 `flutter build macos --release`；
3. 将 `libatermius_rdp.dylib` 与开源许可证内嵌至 `Atermius.app/Contents/Frameworks/` 与 `Contents/Resources/atermius_rdp_licenses/`，校验主程序导出的 `aterm_macos_*` 文件剪贴板/显示器布局 FFI 符号；
4. 自动检测本机钥匙串中的 `Apple Development` 证书（无证书 CI 环境可传 `--adhoc`）进行分层代码签名并通过 `codesign --verify --deep --strict` 校验；
5. 在仓库根目录的 **`dist/`** 输出 **`Atermius.app`**、**`Atermius-macos-arm64.zip`**、**`Atermius-macos-arm64.dmg`** 及其 `.sha256` 摘要文件。

脚本还支持 `--debug`、`--profile`、`--skip-dmg`、`--rebuild-engine` 与 `--sign-identity`，用 `--help` 查看说明。

### 手动 Flutter 构建

也可以直接使用仓库保留的 macOS 启动工程构建：

```sh
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build macos --release
open macos/Runner.xcworkspace
```

`.app` 位于 **`apps/client/build/macos/Build/Products/Release/`**。手动构建只执行 Flutter 部分，不包含上面脚本的引擎构建、内嵌、FFI 符号与签名校验步骤。

如需在 Xcode 中交互调试，在完成一次引擎构建后直接打开 `apps/client/macos/Runner.xcworkspace` 即可运行。Windows 原生 RDP 引擎（`atermius_rdp.dll`）不用于 macOS。该启动工程尚未完成当前版本的 macOS 设备/界面验收。正式公开发行前请配置签名团队与 entitlements，使用 Developer ID Application 证书签名并执行 Apple Notarization 公证，参考 [Flutter macOS 分发](https://docs.flutter.dev/platform-integration/macos/building)。

更新已有版本前请先阅读[安装总览](../INSTALLATION.md)中的“更新已有版本”。

[首次使用](../GETTING_STARTED.md) · [常见问题](../TROUBLESHOOTING.md) · [开发验证](../DEVELOPMENT.md)

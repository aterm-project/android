# 桌面版构建与安装

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md)

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。

Releases 中尚无与当前主干对应的正式安装包，Desktop 的 `ci-input-*` 是构建输入。以下步骤用于自己构建应用；源码 CI 不代表完成了原生设备验收。

## Windows x64

构建机需要 Windows、**Visual Studio 2022** 的 **使用 C++ 的桌面开发**工作负载、Windows SDK 与 CMake 3.28+。原生构建脚本明确使用 VS 2022 生成器，参考 [Flutter Windows 环境说明](https://docs.flutter.dev/platform-integration/windows/setup)。

在开发机 PowerShell 按顺序执行。已有 vcpkg 时，将 `$atermVcpkgRoot` 改为实际路径，跳过克隆与 bootstrap：

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
git clone https://github.com/aterm-project/desktop.git
cd desktop/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build linux --release
```

部署 **`apps/client/build/linux/<arch>/release/bundle/`** 完整目录，保留 `lib/`、`data/`，在目标桌面会话运行。参考 [Flutter Linux 分发](https://docs.flutter.dev/platform-integration/linux/building)。Linux 不包含 Windows 原生 RDP 引擎，网关路径见[远程桌面](REMOTE-DESKTOP.md)。当前 Linux 源码/组件 CI 不代表新版本 Linux GUI 已验收。

## macOS

在 macOS 安装 Xcode、命令行工具及 `flutter doctor` 要求的依赖，使用仓库已有的 macOS 工程：

```sh
git clone https://github.com/aterm-project/desktop.git
cd desktop/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build macos --release
open macos/Runner.xcworkspace
```

产物为 **`apps/client/build/macos/Build/Products/Release/`** 内的 `.app`。分发前配置自己的签名团队、权限与公证。当前 macOS 尚未完成新版本设备/UI 验收，Windows 引擎不代表 Mac 原生 RDP 支持；参考 [Flutter macOS 分发](https://docs.flutter.dev/platform-integration/macos/building)。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在源码目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

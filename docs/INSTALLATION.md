# iOS 构建

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md)

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。

Releases 中尚无与当前主干对应的正式安装包，Desktop 的 `ci-input-*` 是构建输入。以下步骤用于自己构建应用；源码 CI 不代表完成了原生设备验收。

## 构建环境

需要 **macOS、Xcode 与其命令行工具**，并安装 `flutter doctor` 要求的依赖；所选插件集成需要时安装 CocoaPods。Windows/Linux 不能构建已签名 iOS 应用，参考 [Flutter iOS 分发说明](https://docs.flutter.dev/deployment/ios)。

```sh
git clone https://github.com/aterm-project/ios.git
cd ios/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

`--no-codesign` 仅验证编译，不生成可直接安装的签名发行版；应用目录通常为 `build/ios/iphoneos/Runner.app`。模拟器使用 `flutter build ios --simulator` 和匹配目标。

## 设备与分发签名

在 `Runner.xcworkspace` 的 Runner Target 配置自己的 Apple 团队、唯一 Bundle ID、设备/描述文件和权限。当前 Bundle ID 为 `com.atermius.atermClient`，正式分发使用自己注册的身份。可选推送还需要匹配 APNs 环境，见[移动端提示](MOBILE-PUSH.md)。

签名就绪后，在 `apps/client` 执行：

```sh
flutter build ipa --release
```

输出位于 `build/ios/ipa/`，按受支持的设备、TestFlight 或 App Store 流程分发。本仓库未提供当前 App Store/TestFlight 发行版，尚未完成 iOS 设备/UI 验收，也不包含 Windows 原生 RDP 引擎。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在源码目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

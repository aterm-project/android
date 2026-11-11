# iOS 构建

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md)

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。

Releases 中尚无与当前主干对应的正式安装包，Desktop 的 `ci-input-*` 是构建输入。以下步骤用于自己构建应用；源码 CI 不代表完成了原生设备验收。

## 构建环境与一键打包

需要 **macOS、Xcode 26+ 与其命令行工具**、CocoaPods 1.16+、CMake 3.28+ 与 Ninja。仓库已内置面向真机（`ios-arm64`）与模拟器（`ios-arm64-simulator`）双切片的 OpenSSL 3.5.9 + FreeRDP 3.33.0 原生引擎 `atermius_rdp.xcframework` 及一键构建脚本：

```sh
cd ios
# 默认同时构建模拟器包 (.app/.zip) 与免签真机发行包 (.unsigned.ipa)
./scripts/build_ios.sh --all

# 仅构建 iOS 模拟器应用包
./scripts/build_ios.sh --simulator

# 仅构建 Release 免签真机 IPA
./scripts/build_ios.sh --unsigned-ipa
```

构建脚本会自动校验/编译 `apps/client/native/desktop/build/ios/bundle/atermius_rdp.xcframework`，根据当前构建目标自动嵌入对应架构的 `atermius_rdp.framework` 与许可证，并在 **`ios/dist/`** 生成：

- **`Atermius-iphonesimulator.app`** / **`Atermius-iphonesimulator-arm64.zip`**（可直接通过 `xcrun simctl install booted` 安装到模拟器）
- **`Atermius-ios-unsigned.ipa`**（含 `.sha256` 校验和）

## 设备与分发签名

工程默认配置了自动签名（`CODE_SIGN_STYLE = Automatic`）与开发团队参数，且默认 `Runner.entitlements` 不强依赖受限推送权限以便普通开发描述文件直接签名（启用 APNs 生产推送时可将 `CODE_SIGN_ENTITLEMENTS` 指向 `Runner/RunnerPush.entitlements`，见[移动端提示](MOBILE-PUSH.md)）。

使用本地开发者证书构建真机签名 IPA：

```sh
cd ios
./scripts/build_ios.sh --device --team-id <YOUR_TEAM_ID> --bundle-id <YOUR_PROVISIONED_BUNDLE_ID>
```

输出位于 **`ios/dist/Atermius-ios-signed.ipa`**；也可打开 `apps/client/ios/Runner.xcworkspace` 在 Xcode 中直接连真机运行调试，或执行 `flutter build ipa --release` 按 TestFlight / App Store 流程归档分发。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在源码目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

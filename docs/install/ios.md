# iOS 构建

[English](ios.en.md) · [安装总览](../INSTALLATION.md) · [README](../../README.zh-CN.md)

先按[安装总览](../INSTALLATION.md)完成仓库权限、克隆与 Flutter 工具链准备。以下命令都从仓库根目录开始。

## 构建环境

需要 **macOS、Xcode 26+ 与其命令行工具**、CocoaPods 1.16+、CMake 3.28+ 与 Ninja，以及 `flutter doctor` 提示的其他依赖工具。Windows/Linux 无法构建已签名的 iOS 应用。参考 [Flutter iOS 发布说明](https://docs.flutter.dev/deployment/ios)。

## 一键打包脚本

仓库已内置面向真机（`ios-arm64`）与模拟器（`ios-arm64-simulator`）双切片的 OpenSSL 3.5.9 + FreeRDP 3.33.0 原生引擎 `atermius_rdp.xcframework` 及一键构建脚本：

```sh
# 默认同时构建模拟器包 (.app/.zip) 与免签真机发行包 (.unsigned.ipa)
./scripts/build_ios.sh --all

# 仅构建 iOS 模拟器应用包
./scripts/build_ios.sh --simulator

# 仅构建 Release 免签真机 IPA
./scripts/build_ios.sh --unsigned-ipa
```

构建脚本会自动校验/编译 `apps/client/native/desktop/build/ios/bundle/atermius_rdp.xcframework`，根据当前构建目标自动嵌入对应架构的 `atermius_rdp.framework` 与许可证，并在仓库根目录的 **`dist/`** 生成：

- **`Atermius-iphonesimulator.app`** / **`Atermius-iphonesimulator-arm64.zip`**（可直接通过 `xcrun simctl install booted` 安装到模拟器）
- **`Atermius-ios-unsigned.ipa`**（含 `.sha256` 校验和）

免签 IPA 不能直接安装到设备，需要先按下文签名。需要重新编译引擎时加 `--rebuild-engine`。

## 手动 Flutter 构建

也可以不使用脚本，直接检查编译：

```sh
cd apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build ios --no-codesign
open ios/Runner.xcworkspace
```

无签名构建只用于检查能否编译，不是可安装的签名发行包，应用包通常位于 `build/ios/iphoneos/Runner.app`。模拟器使用 `flutter build ios --simulator` 和兼容的模拟器目标。手动构建不包含上面脚本的引擎校验与嵌入步骤。

## 设备与分发签名

工程默认配置了自动签名（`CODE_SIGN_STYLE = Automatic`）与开发团队参数，且默认 `Runner.entitlements` 不强依赖受限推送权限，以便普通开发描述文件直接签名。启用 APNs 生产推送时可将 `CODE_SIGN_ENTITLEMENTS` 指向 `Runner/RunnerPush.entitlements`，推送环境与服务端配置见[移动端推送提示](../MOBILE-PUSH.md)。

当前 Bundle ID 为 `com.atermius.atermClient`；对外分发时请改用自己注册的标识。使用本地开发者证书构建真机签名 IPA：

```sh
./scripts/build_ios.sh --device --team-id <YOUR_TEAM_ID> --bundle-id <YOUR_PROVISIONED_BUNDLE_ID>
```

输出位于仓库根目录的 **`dist/Atermius-ios-signed.ipa`**。

也可以在 `apps/client/ios/Runner.xcworkspace` 中选择 Runner target，设置自己的 Apple 团队、唯一 Bundle ID、设备/描述文件与 entitlements，直接连真机运行调试；或在签名就绪后从 `apps/client` 执行：

```sh
flutter build ipa --release
```

导出的包位于 `build/ios/ipa/`，按 TestFlight / App Store 或其他受支持的 Apple 分发流程处理。此处不声明已有当前 App Store/TestFlight 发行版，也不声明已完成 iOS 设备/界面验收。Windows 原生 RDP 引擎（`atermius_rdp.dll`）不用于 iOS，iOS 使用上面的 `atermius_rdp.xcframework`。

更新已有版本前请先阅读[安装总览](../INSTALLATION.md)中的“更新已有版本”。

[首次使用](../GETTING_STARTED.md) · [常见问题](../TROUBLESHOOTING.md) · [开发验证](../DEVELOPMENT.md)

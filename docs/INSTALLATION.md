# Android 构建与安装

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md)

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。

Releases 中尚无与当前主干对应的正式安装包，Desktop 的 `ci-input-*` 是构建输入。以下步骤用于自己构建应用；源码 CI 不代表完成了原生设备验收。

## 开发 APK

安装 Android Studio/SDK 命令行工具、固定 Flutter 插件要求的平台/构建工具，以及 **JDK 17**。项目的 Java/Kotlin 目标为 17，AGP 为 9.1.0；先解决 `flutter doctor -v` 的 Android 环境问题并交互确认 SDK 许可。启用设备 USB 调试或启动模拟器：

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

包名是 `com.atermius.aterm_client`，产物路径相对 `apps/client`。`adb install -r` 请求保留资料更新，但新旧包必须使用兼容签名；遇到签名不同，应先导出资料，不要直接卸载已有应用。

## 正式分发

仓库的 `release` Gradle 配置目前仍使用**调试签名**，仅执行 `flutter build apk --release` 不会得到正式签名发行包。先按 [Flutter Android 签名说明](https://docs.flutter.dev/deployment/android#sign-the-app)配置自己的 keystore 和 Gradle 签名，密钥/密码文件不提交 Git，后续更新保持签名身份。

完成签名配置后：

```sh
flutter build apk --release
flutter build appbundle --release
```

产物分别为 `build/app/outputs/flutter-apk/app-release.apk`、`build/app/outputs/bundle/release/app-release.aab`。AAB 用于商店/发行渠道，不能直接用 `adb install` 安装。本仓库当前没有提供 Play Store 发行版。

## 首次使用与范围

选择本地资料或自己的 HTTPS 实例。SSH 使用原生传输；本机 Shell、串口 Console 和 Windows 原生 RDP 引擎不属于 Android 能力。临时访客链接可在支持的浏览器中打开，前后台策略可能中断会话/转发。[可选推送提示](MOBILE-PUSH.md)需单独配置。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在源码目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

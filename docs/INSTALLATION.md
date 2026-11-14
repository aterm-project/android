# 安装与构建

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md) · [文档导航](README.md)

所有客户端与服务端都在同一个仓库：`apps/client/` 是一套 Flutter 应用，包含各平台启动工程；`server/` 是 Rust API，`deploy/` 是部署配置。先完成本页的通用准备，再进入对应平台的指南。

## 选择平台

| 平台 | 指南 | 构建入口 | 每日构建标签 |
| --- | --- | --- | --- |
| Android | [Android 构建与安装](install/android.md) | `apps/client` 中执行 `flutter build apk` | `android-daily-*` |
| Windows / Linux / macOS | [桌面版构建与安装](install/desktop.md) | Windows 先运行 `integration/native/build_rdp_windows.ps1`；macOS 使用 `scripts/build_macos.sh` | `desktop-daily-*` |
| iOS | [iOS 构建](install/ios.md) | `scripts/build_ios.sh`，或 `flutter build ios` | `ios-daily-*` |
| 浏览器 | [浏览器前端构建与部署](install/web.md) | `flutter build web`，或根目录 `Dockerfile` | `web-daily-*` |
| 自托管服务端 | [自托管服务安装与部署](install/server.md) | `deploy/` 下的 Docker Compose | 无，从源码构建 |

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

```sh
git clone https://github.com/aterm-project/atermius.git
cd atermius
```

各平台指南中的路径与命令都相对这个仓库根目录。

客户端从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和 `packages/` 下五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。Linux 上也可以用 `tools/install_flutter_linux.sh` 临时安装 SDK，见[开发与验证](DEVELOPMENT.md)。服务端使用 Docker 方案时，宿主机不需要安装 Flutter/Rust。

## 预编译构建

当前没有与最新主干对应的正式用户安装包，以下各平台指南用于自己构建应用。

每日构建以**预发布**形式发布在本仓库的 [Releases](https://github.com/aterm-project/atermius/releases) 页面，标签格式为 `<平台>-daily-YYYYMMDD.N-<sha12>`，平台为 `android`、`desktop`、`ios` 或 `web`。每个预发布附带构建产物、`evidence-<平台>.json` 与 `SHA256SUMS`。这些是 CI 产物，供测试使用，不是商店或公证后的发行版：

- Android：CI 用项目固定证书签名的 APK；签名不同的已安装版本不能直接覆盖。
- Desktop：Windows 便携 ZIP（含 `atermius_rdp.dll`，未做代码签名）、Linux `bundle/` 的 tar.gz、macOS ZIP（仅 ad-hoc 签名，未公证）。
- iOS：未签名的 IPA，需要用自己的 Apple 身份和描述文件重新签名后才能安装。
- Web：`web/` 静态站点与 `deploy/nginx.conf` 的压缩包，部署仍需要 API。

构建触发条件、产物与校验细节见 [`.github/daily-build/README.md`](../.github/daily-build/README.md)。2026-11-14 合并之前的各平台旧版本（包括 Desktop 的 `ci-input-*` 构建输入，它们不是安装包）仍保留在已归档原仓库的 Releases 中。源码 CI 或每日构建通过，都不代表完成了原生设备验收。

## 从旧仓库迁移

原 `aterm-project/android` 已更名为 `aterm-project/atermius`，已有克隆可以执行 `git remote set-url origin https://github.com/aterm-project/atermius.git` 后继续拉取。`desktop`、`ios`、`web`、`server` 已归档为只读，请改用本仓库重新克隆。服务端原来要求 `server` 与 `web` 并列放在同一父目录，现在一个克隆即可。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在仓库根目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

服务端的更新、备份与覆盖文件列表另有要求，见[服务端部署](install/server.md)。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

<p align="center"><img src="docs/assets/atermius-mark.svg" width="72" alt="Atermius"></p>

<h1 align="center">Atermius</h1>

<p align="center">覆盖 Android、iOS、Windows、macOS、Linux 与浏览器的加密 SSH 工作区，可选自托管同步服务端。</p>
<p align="center"><a href="README.md">English</a> · <a href="docs/INSTALLATION.md">安装指南</a> · <a href="docs/README.md">文档导航</a> · <a href="https://github.com/aterm-project/atermius/releases">Releases</a> · <a href="https://github.com/aterm-project/atermius/actions">CI</a></p>

## 从这里开始

当前没有与最新主干对应的正式用户安装包，请按指南从源码构建，或试用每日预发布构建。源码 CI 通过或每日构建成功，都不代表已经提供商店签名的发行版。

- [安装与构建](docs/INSTALLATION.md)
- [首次使用与连接主机](docs/GETTING_STARTED.md)
- [功能与平台边界](docs/FEATURES.md)
- [分享主机](docs/SHARING.md)
- [自托管服务端](docs/install/server.md)
- [常见问题](docs/TROUBLESHOOTING.md)
- [开发与验证](docs/DEVELOPMENT.md)
- [全部文档](docs/README.md)

## 主要能力

客户端是同一套 Flutter 应用：

- SSH 终端、紧凑主机列表、分组与快捷指令；支持 Telnet，桌面端另有本机 Shell 与串口 Console。
- SFTP/SCP 文件工作区、分屏和受平台支持的窗口组合。
- RDP 与 VNC：平台构建带有直连引擎时直接连接，否则经服务端网关。
- 加密本地资料，或连接自托管服务端使用同步 Vault。
- 服务端启用相应能力后，提供组织、成员分享与临时链接。
- 桌面端与 Android 可选开启本机回环 MCP，供外部 AI 工具接入。
- 中、日、英、俄四种界面语言；应用强调色与终端配色分开设置。

服务端负责自托管加密工作区 API、组织管理与临时访问网关：

| 能力 | 用途 |
| --- | --- |
| 加密同步 | 设备签名、Vault 成员关系与密文记录同步 |
| 组织与团队 | 邀请、角色、访问授权与持有者确认后的密钥交付 |
| 主机分享 | 仅复制所选主机及确认过的依赖到独立共享 Vault |
| 临时链接 | 自定义地址、开始与到期时间、配额、撤销和活动管理 |
| 运维 | SQLite、受限 PostgreSQL、备份恢复与可选监控 |

## 支持的平台

| 平台 | 指南 | 构建入口 | 每日构建 |
| --- | --- | --- | --- |
| Android | [Android](docs/install/android.md) | 在 `apps/client` 执行 `flutter build apk` | `android-daily-*`：CI 签名的 APK |
| Windows | [桌面版](docs/install/desktop.md) | 先运行 `integration/native/build_rdp_windows.ps1`，再 `flutter build windows` | `desktop-daily-*`：便携 ZIP，未做代码签名 |
| Linux | [桌面版](docs/install/desktop.md) | `flutter build linux` | `desktop-daily-*`：tar.gz 运行目录 |
| macOS | [桌面版](docs/install/desktop.md) | `scripts/build_macos.sh --release` | `desktop-daily-*`：ZIP，仅 ad-hoc 签名，未公证 |
| iOS | [iOS](docs/install/ios.md) | `scripts/build_ios.sh`，或 `flutter build ios` | `ios-daily-*`：未签名 IPA |
| 浏览器 | [Web](docs/install/web.md) | `flutter build web --release --no-web-resources-cdn`，或根目录 `Dockerfile` | `web-daily-*`：静态站点与 `deploy/nginx.conf` |
| 服务端 | [服务端](docs/install/server.md) | `deploy/` 下的 Docker Compose | 无，从源码构建 |

## 快速开始

Flutter 3.47.5 / Dart 3.13 与对应平台工具链。Windows 需要先构建原生 RDP bundle，iOS 与 macOS 需要 Xcode，详见[安装指南](docs/INSTALLATION.md)。

```bash
git clone https://github.com/aterm-project/atermius.git
cd atermius/apps/client
flutter doctor -v
flutter pub get --enforce-lockfile
flutter build apk --debug
```

其他目标可改用 `flutter build linux --release`、`flutter build web --release --no-web-resources-cdn`，或按平台指南操作。

服务端需要 Docker 与 Compose 2.24+：

```bash
cd atermius
cp deploy/.env.example deploy/.env
# 先配置 deploy/.env，再按 docs/install/server.md 完成初始化。
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
```

仓库目前为私有仓库，克隆和下载私有构建资产需要 GitHub 访问权限。

## 每日构建

每日构建以预发布形式发布在 [Releases](https://github.com/aterm-project/atermius/releases) 页面，标签为 `<平台>-daily-YYYYMMDD.N-<sha12>`，平台为 `android`、`desktop`、`ios` 或 `web`，每个预发布附带 `evidence-<平台>.json` 与 `SHA256SUMS`。每个 UTC 日最多构建一次，且只在产品输入有变化时构建，详见 [`.github/daily-build/README.md`](.github/daily-build/README.md)。合并前的旧版本仍保留在已归档的原仓库中。

## 源码结构

| 路径 | 内容 |
| --- | --- |
| `apps/client/` | Flutter 应用，含 `android/`、`ios/`、`macos/`、`windows/`、`linux/`、`web/` 启动工程；原生 RDP 引擎源码在 `apps/client/native/` |
| `packages/` | 五个打过补丁的本地依赖分支（`drift`、`sqlite3`、`xterm`、`dartssh2`、`desktop_drop`） |
| `protocol/` | 共享协议与测试向量 |
| `server/` | Rust API 工程及其 `Dockerfile` |
| `deploy/` | 服务端 Compose 配置与覆盖文件，以及 Web 镜像使用的 `nginx.conf` |
| `Dockerfile` | 浏览器前端镜像（Flutter Web 构建 + nginx） |
| `integration/` | API/浏览器集成测试、原生平台探针与 MCP stdio 桥接脚本 |
| `tools/` | Flutter SDK 安装脚本、集成测试工作区组装与 nginx 代理验证 |
| `scripts/` | macOS 与 iOS 一键构建脚本 |
| `docs/` | 用户、运维与开发文档 |

## 支持范围

Windows 原生 RDP 需要配套的 `atermius_rdp.dll` 引擎；其他平台使用各自构建的引擎或服务端网关，见[远程桌面](docs/REMOTE-DESKTOP.md)。浏览器常规 SSH 需要启用并限制目标范围的 Relay；临时浏览器 SSH/RDP 是独立的受信网关流程，网关可解密登录胶囊并观察会话。API 与浏览器前端分别构建。云端协作目前要求 SQLite，PostgreSQL 云端路由保持关闭；经网关的 VNC 需显式启用，尚未完成真实连接验收。

Linux 上的 Dart/组件 CI 不代表各原生平台已完成构建或设备验收。完整 Flutter 套件仍有已披露的历史失败；仓库 CI 执行工作流中列出的针对性检查，具体范围见[验证与文档导航](docs/README.md)。服务端数据、账户凭据和签名材料不应提交到 Git。

第三方许可证与上游说明保留在相应依赖目录。Rust 工程在 `server/Cargo.toml` 中声明 AGPL-3.0-or-later。

## 仓库历史

Atermius 原先分布在 `aterm-project` 下的五个仓库：`android`、`desktop`、`ios`、`web`（同一套 Flutter 应用的不同平台启动工程）和 `server`。2026-11-14 这五个仓库合并为本仓库，并保留了各自的 Git 历史。`aterm-project/android` 更名为 `aterm-project/atermius`；`desktop`、`ios`、`web`、`server` 已归档为只读，旧版本 Releases 留在原处。各原仓库的源码导入记录原样保存在 [docs/provenance/](docs/provenance/)，并列在[文档导航](docs/README.md)中。

# Documentation / 文档导航

[English README](../README.md) · [中文 README](../README.zh-CN.md)

| Start / 入口 | English | 中文 |
| --- | --- | --- |
| Install and build / 安装构建 | [Installation](INSTALLATION.en.md) | [安装](INSTALLATION.md) |
| First workspace / 首次使用 | [Getting started](GETTING_STARTED.en.md) | [上手](GETTING_STARTED.md) |
| Sharing / 主机分享 | [Host sharing](SHARING.en.md) | [分享](SHARING.md) |
| Troubleshooting / 排障 | [Troubleshooting](TROUBLESHOOTING.en.md) | [常见问题](TROUBLESHOOTING.md) |

## Install by platform / 按平台安装

| Platform / 平台 | English | 中文 |
| --- | --- | --- |
| Android | [Build and install](install/android.en.md) | [构建与安装](install/android.md) |
| Windows / Linux / macOS | [Desktop client](install/desktop.en.md) | [桌面版](install/desktop.md) |
| iOS | [iOS client](install/ios.en.md) | [iOS 构建](install/ios.md) |
| Browser / 浏览器 | [Browser frontend](install/web.en.md) | [浏览器前端](install/web.md) |
| Self-hosted server / 自托管服务端 | [Install, HTTPS and first account](install/server.en.md) | [安装、HTTPS 与首次账户](install/server.md) |

Daily builds, release tags and moving from the old repositories are covered in the [installation overview](INSTALLATION.en.md) / [安装总览](INSTALLATION.md).

## Features and workflows / 功能流程

- [Platform boundaries / 平台矩阵](FEATURES.md)
- [Quick connect / 快捷连接](QUICK-CONNECT.md)
- [SSH tools sidebar / SSH 右侧工具栏](TERMINAL-SIDEBAR.md)
- [Local shell / 本机 Shell](LOCAL-SHELL.md)
- [Telnet](TELNET.md)
- [RDP, VNC and Console / 远程桌面](REMOTE-DESKTOP.md)
- [Termius/OpenSSH transfer / 导入导出](IMPORT_EXPORT.md)
- [External MCP / 外部 MCP](MCP.md) · [MCP on Android / Android 上的 MCP](MCP-ANDROID.md)
- [Mobile push hints / 移动端推送提示](MOBILE-PUSH.md)

## Server operations / 服务端运维

- [Advanced deployment reference / 高级部署配置](../deploy/README.md)
- [Cloud organizations, member sharing and guest gateway / 云端与分享](CLOUD-SHARING.md)
- [Credential visibility: private and administrator-visible accounts / 凭据可见性：私密加密与管理员可见](CREDENTIAL-VISIBILITY.md) · [中文](CREDENTIAL-VISIBILITY.zh-CN.md)
- [HTTPS edge and proxy](runbooks/https-edge-proxy.md)
- [Instance backup and restore](runbooks/instance-backup-restore.md)
- [MFA seed key rotation](runbooks/mfa-seed-key-rotation.md)
- [Database encryption at rest (SQLCipher) / 数据库静态加密](runbooks/database-encryption.md)
- [PostgreSQL maintenance](runbooks/postgres-maintenance.md)
- [PostgreSQL schema/runtime upgrade](runbooks/postgres-runtime-upgrade.md)
- [Attachment object-store migration](OBJECT-STORE-MIGRATION.md)
- [Implementation and acceptance boundaries](IMPLEMENTATION-STATUS.md)

SQLite cloud functionality and restricted PostgreSQL sync-core have different support boundaries. The gateway key is separate from ordinary instance backups. Retain the exact environment/overlay list for updates and recovery. / SQLite 云端与受限 PostgreSQL 不是同一支持范围，网关密钥独立于普通实例备份，更新恢复需保留准确环境与覆盖文件列表。

## Development and review / 开发与审阅

- [Developer checks / 开发检查](DEVELOPMENT.md)
- [Encrypted data and recovery notes / 加密资料与恢复](DATA-AND-RECOVERY.md)
- [Integration tests (API + Web) / 集成测试](INTEGRATION.md)
- [Browser fixture reference](../integration/web/README.md)
- [Current cloud implementation decisions](cloud-collaboration-design/IMPLEMENTATION-ADR.md)
- [Original cloud proposal](cloud-collaboration-design/DESIGN.md) · [API](cloud-collaboration-design/API.yaml) · [schema](cloud-collaboration-design/schema.sql) · [rollout](cloud-collaboration-design/ROLLOUT.md)
- [Proposal acceptance plan](cloud-collaboration-design/ACCEPTANCE-TESTS.md)

The proposal directory contains design history, not a promise that every proposed feature shipped. Use CLOUD-SHARING and the implementation ADR for current behavior. / 设计提案不是已交付功能清单，以当前实现说明为准。

## Repository history / 仓库历史

Until 2026-11-14 the project lived in five repositories: `android`, `desktop`, `ios`, `web` and `server`. Their source-import records are kept unchanged as historical files; they describe the pre-merge repositories, not the current tree. / 2026-11-14 之前项目分为五个仓库，下列导入记录原样保留，仅描述合并前各仓库，不对应当前目录。

| Former repository / 原仓库 | Import records / 导入记录 |
| --- | --- |
| `android` | [SOURCE_PROVENANCE.json](provenance/android/SOURCE_PROVENANCE.json) · [SOURCE_SNAPSHOT.json](provenance/android/SOURCE_SNAPSHOT.json) |
| `desktop` | [SOURCE_PROVENANCE.json](provenance/desktop/SOURCE_PROVENANCE.json) · [SOURCE_SNAPSHOT.json](provenance/desktop/SOURCE_SNAPSHOT.json) |
| `ios` | [SOURCE_PROVENANCE.json](provenance/ios/SOURCE_PROVENANCE.json) · [SOURCE_SNAPSHOT.json](provenance/ios/SOURCE_SNAPSHOT.json) |
| `web` | [SOURCE_PROVENANCE.json](provenance/web/SOURCE_PROVENANCE.json) · [SOURCE_SNAPSHOT.json](provenance/web/SOURCE_SNAPSHOT.json) |
| `server` | [SOURCE_PROVENANCE.json](provenance/server/SOURCE_PROVENANCE.json) (no snapshot file / 无快照文件) |

CI checks focused Dart/widget cases on Linux; Web also builds its JS release and verifies the real nginx runtime. The full Flutter suite has historical failures. Source CI and isolated target checks do not establish a deployed public service or complete native/hardware acceptance. / 源码 CI、完整套件与实际设备验收分别记录，不将环境跳过或部分运行称为全部通过。

# Server documentation / 服务端文档

[English README](../README.md) · [中文 README](../README.zh-CN.md)

## Install / 安装

- [English installation and first account](INSTALLATION.en.md)
- [中文安装、HTTPS 与首次账户](INSTALLATION.md)
- [Advanced deployment reference / 高级部署配置](../deploy/README.md)
- [Cloud organizations, member sharing and guest gateway / 云端与分享](CLOUD-SHARING.md)

## Operate / 运维

- [HTTPS edge and proxy](runbooks/https-edge-proxy.md)
- [Instance backup and restore](runbooks/instance-backup-restore.md)
- [MFA seed key rotation](runbooks/mfa-seed-key-rotation.md)
- [PostgreSQL maintenance](runbooks/postgres-maintenance.md)
- [PostgreSQL schema/runtime upgrade](runbooks/postgres-runtime-upgrade.md)

SQLite cloud functionality and restricted PostgreSQL sync-core have different support boundaries. The gateway key is separate from ordinary instance backups. Retain the exact environment/overlay list for updates and recovery. / SQLite 云端与受限 PostgreSQL 不是同一支持范围，网关密钥独立于普通实例备份，更新恢复需保留准确环境与覆盖文件列表。

- [Attachment object-store migration](OBJECT-STORE-MIGRATION.md)
- [Implementation and acceptance boundaries](IMPLEMENTATION-STATUS.md)

## Develop and review / 开发与审阅

- [Cross-repository tests](INTEGRATION.md)
- [Browser fixture reference](../integration/web/README.md)
- [Current cloud implementation decisions](cloud-collaboration-design/IMPLEMENTATION-ADR.md)
- [Original cloud proposal](cloud-collaboration-design/DESIGN.md)
- [Proposal acceptance plan](cloud-collaboration-design/ACCEPTANCE-TESTS.md)

The proposal directory contains design history, not a promise that every proposed feature shipped. Use CLOUD-SHARING and the implementation ADR for current behavior. Source CI and isolated target checks do not establish a deployed public service or complete native/hardware acceptance. / 设计提案不是已交付功能清单，以当前实现说明为准。

<p align="center"><img src="docs/assets/atermius-mark.svg" width="72" alt="Atermius"></p>

<h1 align="center">Atermius · Server</h1>

<p align="center">自托管加密工作区 API、组织管理与临时访问网关。</p>
<p align="center"><a href="README.md">English</a> · <a href="docs/INSTALLATION.md">安装指南</a> · <a href="docs/README.md">文档导航</a> · <a href="https://github.com/aterm-project/server/actions/workflows/checks.yml">CI</a></p>

## 从这里开始

当前未发布面向用户的服务端二进制，也未提供已上线的托管服务。请从源码构建 API 镜像；安装指南包含独立 Web 镜像、HTTPS 和首次账户初始化。

- [安装与部署](docs/INSTALLATION.md)
- [高级部署选项](deploy/README.md)
- [云端分享与网关信任边界](docs/CLOUD-SHARING.md)
- [集成测试](docs/INTEGRATION.md)
- [运维文档导航](docs/README.md)

## 主要能力

| 能力 | 用途 |
| --- | --- |
| 加密同步 | 设备签名、Vault 成员关系与密文记录同步 |
| 组织与团队 | 邀请、角色、访问授权与持有者确认后的密钥交付 |
| 主机分享 | 仅复制所选主机及确认过的依赖到独立共享 Vault |
| 临时链接 | 自定义地址、开始与到期时间、配额、撤销和活动管理 |
| 运维 | SQLite、受限 PostgreSQL、备份恢复与可选监控 |

## 快速开始

Docker 与 Compose 2.24+，浏览器界面需要同级 `web` 仓库。

```bash
git clone https://github.com/aterm-project/server.git
git clone https://github.com/aterm-project/web.git
cd server
cp deploy/.env.example deploy/.env
# 先配置 deploy/.env，再按 docs/INSTALLATION.md 完成初始化。
docker compose --env-file deploy/.env -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
```

仓库目前为私有仓库，克隆和下载私有构建资产需要 GitHub 访问权限。完整的系统依赖、构建产物路径与更新步骤见[安装指南](docs/INSTALLATION.md)。

## 支持范围

API 与浏览器前端分别构建。云端协作目前要求 SQLite；临时 SSH/RDP 通过显式启用的受信网关，网关可解密登录胶囊并观察会话。PostgreSQL 云端路由保持关闭；VNC 需显式启用，尚未完成真实连接验收。

完整 Flutter 套件仍有已披露的历史失败；仓库 CI 执行工作流中列出的针对性检查。具体范围见[验证与文档导航](docs/README.md)。服务端数据、账户凭据和签名材料不应提交到 Git。

## 源码结构

`server/` 为 Rust 工程，`deploy/` 为 Compose 配置，`docs/` 与 `integration/` 为说明和集成测试。

第三方许可证与上游说明保留在相应依赖目录。Rust 工程在 `server/Cargo.toml` 中声明 AGPL-3.0-or-later。

## 其他仓库

[Desktop](https://github.com/aterm-project/desktop) · [Android](https://github.com/aterm-project/android) · [iOS](https://github.com/aterm-project/ios) · [Web](https://github.com/aterm-project/web)

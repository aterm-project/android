# 自托管服务安装与部署

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md) · [高级配置](../deploy/README.md)

## 先选择部署方式

| 方式 | 提供的内容 |
| --- | --- |
| 仅 API | 原生客户端连接 API，不包含浏览器界面 |
| API + Web | 独立 API 与 nginx 镜像，通过同一浏览器来源提供服务 |
| API + Web + HTTPS | 可选 Caddy 代理，提供外部浏览器 HTTPS 来源 |
| 添加 desktop/share 覆盖配置 | guacd 和显式启用的临时访问 |

服务端 Dockerfile **只构建 API**，Web 镜像从同级 `web` 仓库构建。不假定已有托管服务或预制容器镜像。需要 Docker 和 **Compose 2.24+**，HTTPS 配置使用 `!reset`。镜像构建会下载固定工具链及依赖，使用此方案时宿主机不需要安装 Flutter/Rust。

## 1. 克隆两个仓库

使用有私有仓库权限的 GitHub 账户；GitHub CLI 可通过 `gh auth login`、`gh auth setup-git` 配置 HTTPS 凭据，也可使用自己的 Git SSH Key。在父目录执行：

```sh
git clone https://github.com/aterm-project/server.git
git clone https://github.com/aterm-project/web.git
cd server
cp deploy/.env.example deploy/.env
chmod 600 deploy/.env
```

目录须为 `parent/server`、`parent/web`。路径相对 `server/deploy` 解析：API 构建上下文为 `..`，Web 为 `../../web`。已有实例直接看更新章节，不要重做初始化或覆盖原环境文件。

## 2. 同机回环试用

先编辑 `deploy/.env`，例如本机浏览器使用 8081 时：

```dotenv
ATERMIUS_ADMIN_USERNAMES=admin@example.com
ATERMIUS_PUBLIC_ORIGIN=http://localhost:8081
```

将管理员用户名改为自己的值。默认不开放公共注册，第一个账户使用 bootstrap 令牌；创建组织默认要求实例管理员。HTTP 仅用于回环开发，其他电脑/手机访问应使用下节 HTTPS。

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml up -d --build
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml ps
curl --fail http://127.0.0.1:8080/health/ready
```

浏览器打开 **http://localhost:8081**。API 仅映射回环 8080，Web 仅映射回环 8081。API 健康不代表前端、代理或浏览器存储全部正常。

仅 API 部署可去掉 `compose.web.yaml`，将来源地址设为 API 端点（本机示例 `http://localhost:8080`），再由原生客户端连接；API 镜像本身不含浏览器首页或访客/加入页面。

## 3. 创建第一个账户

仅在新实例执行：

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml exec -T server \
  /usr/local/bin/atermius-server bootstrap
```

妥善保存打印的一次性令牌，在 Web/客户端的服务端账户流程填写实例来源、管理员用户名、自选密码及 bootstrap 令牌，独立保存恢复材料。需要管理员/组织创建功能时，用户名必须与允许名单匹配。

令牌消费后，新增用户使用实例的账户邀请/注册功能。组织邀请是另一层成员关系，不能绕过账户注册。高级栈执行运维 `exec` 时仍应使用全部已启用覆盖文件。

## 4. 为其他设备配置 HTTPS

为自己的域名配置 DNS 和访问路径，并设置：

```dotenv
ATERMIUS_CADDY_DOMAIN=atermius.example.com
ATERMIUS_CADDY_ACME_EMAIL=admin@example.com
ATERMIUS_PUBLIC_ORIGIN=https://atermius.example.com
```

替换示例值，按计划开放代理的 HTTP/HTTPS 端口。服务部署在来源根路径，来源包含协议/主机/端口，不附加 `/api/v1`。覆盖文件按下列顺序使用：

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml up -d --build
curl --fail https://atermius.example.com/health/ready
```

必须保留 web-edge 覆盖，它把 Caddy 从仅代理 API 改为代理 nginx，并取消 Web 的回环端口映射。使用自己的 TLS 代理时，保留同源 API/WebSocket 路由，参考[边缘代理运行手册](runbooks/https-edge-proxy.md)。核对外部证书和 HTTPS 健康地址，不能仅凭本机健康检查认为公网 TLS 已验收。

## 5. 按需启用临时访客访问

注册用户的组织/主机分享属于 SQLite 能力；临时浏览器 SSH/RDP 还需要 guacd 和受信网关。在本栈使用的环境中设置：

```dotenv
ATERMIUS_SHARE_LINKS_ENABLED=true
ATERMIUS_SHARE_ALLOW_CIDRS=10.20.0.0/16
ATERMIUS_SHARE_ALLOW_PORTS=22,3389
ATERMIUS_SHARE_DENY_CIDRS=172.16.0.0/12
ATERMIUS_SHARE_VNC_ENABLED=false
```

按实际目标收窄网段与端口。允许策略不会创建网络路由，目标必须从 guacd 可达；API、guacd、数据库所在网络仍应被拒绝。若目标也在示例拒绝范围内，应设计隔离与明确拒绝规则，不能直接放开整个容器网络。回环、元数据等禁止目标始终被拒绝。

对上述 Caddy/Web 方案执行：

```sh
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.desktop.yaml -f deploy/compose.share.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml config --quiet
docker compose --env-file deploy/.env \
  -f deploy/compose.yaml -f deploy/compose.web.yaml \
  -f deploy/compose.desktop.yaml -f deploy/compose.share.yaml \
  -f deploy/compose.caddy.yaml -f deploy/compose.web-edge.yaml up -d --build
```

`share-gateway-key` 使用独立持久卷，位于 `/data` 外。网关能解密登录胶囊和观察会话，并非零知识；丢失网关密钥后，旧胶囊失效，需持有者重新封装。不要发布 guacd 端口。核对 `/api/v1/instance` 能力，再用专用目标验证，详见[云端分享说明](CLOUD-SHARING.md)。

PostgreSQL 云端路由仍保持关闭。PostgreSQL 同步核心另有密钥、迁移与恢复前提，见[部署参考](../deploy/README.md#postgresql-runtime-and-offline-restore-cutover)，不能替代此 SQLite 云端配置。

## 6. 浏览器常规 SSH

它与临时访客访问不同。仅在配置明确的 `ATERMIUS_RELAY_ALLOW_CIDRS`、`ATERMIUS_RELAY_ALLOW_PORTS` 和精确来源后启用 `ATERMIUS_RELAY_ENABLED=true`。常规浏览器 SSH/SFTP 使用字节 Relay，远程桌面/访客则使用受信 guacd；账户策略可能进一步限制目标。

## 7. 更新、备份与排障

记录实际环境文件及**全部覆盖文件列表**，后续 `config --quiet`、`up`、`ps`、`logs`、`exec` 均使用同一列表，遗漏覆盖文件会移除相应配置。`--quiet` 只验证，不打印解析后的秘密。

保留同一数据卷名称，按[实例备份/恢复手册](runbooks/instance-backup-restore.md)备份并保管独立密钥。更新前按需停止新流量，以 `git pull --ff-only` 更新同级源码，再重建同一栈；不要把覆盖 `.env` 或删除持久卷作为升级步骤。

用 `ps`、`/health/ready`、外部 Web 页面与脱敏日志区分 API、代理、策略及目标问题。直接复制运行中 SQLite 卷不是完整实例备份。MFA、对象存储、推送和监控等高级选项见[部署参考](../deploy/README.md)。

仅构建 Rust 工程的开发者可运行：

```sh
rustup toolchain install 1.94.1
cargo +1.94.1 build --locked --manifest-path server/Cargo.toml --jobs 8
cargo +1.94.1 test --locked --manifest-path server/Cargo.toml --jobs 2 -- --test-threads=2
```

源码 CI 使用 Rust 1.94.1；这些检查不等于完成原生客户端设备验收或生产部署。

# 浏览器前端构建与部署

[English](web.en.md) · [安装总览](../INSTALLATION.md) · [README](../../README.zh-CN.md)

先按[安装总览](../INSTALLATION.md)完成仓库权限、克隆与 Flutter 工具链准备。以下命令都从仓库根目录开始。

## 构建站点

```sh
cd apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

部署 **`apps/client/build/web/` 完整目录**。`--no-web-resources-cdn` 保证 CanvasKit 同源，仓库也包含 Unicode 回退字体与许可证。使用真正的 HTTP 服务，不使用 `file://` 打开。

## 与 API 一起部署

推荐按[服务端部署指南](server.md)操作。API 与前端现在位于同一仓库：服务端 Compose 的 `deploy/compose.web.yaml` 使用仓库根目录的 `Dockerfile` 构建前端镜像，并代理 API/WebSocket，形成同一浏览器来源，不再需要同级 `web` 目录。

手动构建镜像时，在仓库根目录执行：

```sh
docker build -t atermius-web:local .
```

镜像在 **8080** 监听，以 nginx 用户运行，使用 `deploy/nginx.conf`，要求 Docker 网络内存在 `server:8080`。仅单独启动 Web 容器不是完整部署；网络、TLS 与持久 API 数据按服务端 Compose 栈配置，不假定已有 GHCR 镜像或公网托管实例。

## 临时链接与常规 SSH

提供的 nginx 为 `/s/*`、`/join` 设置禁止缓存、referrer 与 CSP 响应头，并为 `/gateway/*` 保留 WebSocket 升级。保留 Flutter 之前加载的 `share-bootstrap.js`，先移除访问链接片段，再启动路由/请求。仅上传静态文件而不配置这些路由和代理不足以提供访客访问。

账户模式常规 SSH 需要服务端 Relay 和严格目标策略；临时 SSH/RDP 使用另一个受信网关。云端协作要求 SQLite，访客 Cookie 要求 HTTPS；浏览器本地资料不能创建直接 TCP 或本机 Shell。

## 验证构建后的运行环境

在仓库根目录、Docker 可用时运行：

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

只启动可清理的回环测试环境，验证真实 nginx 响应头、API 转发与 WebSocket 回显，不会上线公网，也不代替真实访客/目标连接测试。

更新已有版本前请先阅读[安装总览](../INSTALLATION.md)中的“更新已有版本”。

[首次使用](../GETTING_STARTED.md) · [常见问题](../TROUBLESHOOTING.md) · [开发验证](../DEVELOPMENT.md)

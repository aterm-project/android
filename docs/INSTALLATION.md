# 浏览器前端构建与部署

[English](INSTALLATION.en.md) · [README](../README.zh-CN.md)

## 仓库权限与工具链

仓库目前为私有，Git 凭据需使用有访问权限的账户。使用 GitHub CLI 时，先运行 `gh auth login`、`gh auth setup-git`；已有 SSH Key 认证也可使用，不要将令牌写进克隆 URL。

从[官方归档](https://docs.flutter.dev/install/archive)安装 **Flutter 3.47.5 / Dart 3.13**，将 SDK 的 `bin` 加入 PATH，以 `flutter --version`、`flutter doctor -v` 检查。保留锁文件和五个本地依赖分支，不使用旧 README 中过低的 SDK 版本。

Releases 中尚无与当前主干对应的正式安装包，Desktop 的 `ci-input-*` 是构建输入。以下步骤用于自己构建应用；源码 CI 不代表完成了原生设备验收。

## 构建站点

```sh
git clone https://github.com/aterm-project/web.git
cd web/apps/client
flutter pub get --enforce-lockfile
flutter build web --release --no-web-resources-cdn
```

部署 **`apps/client/build/web/` 完整目录**。`--no-web-resources-cdn` 保证 CanvasKit 同源，仓库也包含 Unicode 回退字体与许可证。使用真正的 HTTP 服务，不使用 `file://` 打开。

## 与 API 一起部署

推荐按服务端[安装指南](https://github.com/aterm-project/server/blob/main/docs/INSTALLATION.md)操作，将 `server` 与 `web` 放在同一父目录。服务端 `compose.web.yaml` 相对 Compose 所在目录通过 `../../web` 找到本仓库，构建前端镜像并代理 API/WebSocket，形成同一浏览器来源。

手动构建镜像时，在 Web 仓库根目录执行：

```sh
docker build -t atermius-web:local .
```

镜像在 **8080** 监听，以 nginx 用户运行，要求 Docker 网络内存在 `server:8080`。仅单独启动 Web 容器不是完整部署；网络、TLS 与持久 API 数据按服务端 Compose 栈配置，不假定已有 GHCR 镜像或公网托管实例。

## 临时链接与常规 SSH

提供的 nginx 为 `/s/*`、`/join` 设置禁止缓存、referrer 与 CSP 响应头，并为 `/gateway/*` 保留 WebSocket 升级。保留 Flutter 之前加载的 `share-bootstrap.js`，先移除访问链接片段，再启动路由/请求。仅上传静态文件而不配置这些路由和代理不足以提供访客访问。

账户模式常规 SSH 需要服务端 Relay 和严格目标策略；临时 SSH/RDP 使用另一个受信网关。云端协作要求 SQLite，访客 Cookie 要求 HTTPS；浏览器本地资料不能创建直接 TCP 或本机 Shell。

## 验证构建后的运行环境

在本仓库根目录、Docker 可用时运行：

```sh
python3 tools/verify_cloud_proxy.py --web-root apps/client/build/web
```

只启动可清理的回环测试环境，验证真实 nginx 响应头、API 转发与 WebSocket 回显，不会上线公网，也不代替真实访客/目标连接测试。

## 更新已有版本

先导出/备份资料并退出 Atermius，再在源码目录执行 `git pull --ff-only`，使用固定 SDK 和锁文件重新构建。替换完整运行目录，Dart 应用与原生引擎保持来自同一次构建。保留应用资料和移动端签名身份；不要用删除资料或卸载作为默认升级步骤。源码、SDK 和构建缓存放在开发机或 CI，运行机器只部署完整应用与运行依赖。

[首次使用](GETTING_STARTED.md) · [常见问题](TROUBLESHOOTING.md) · [开发验证](DEVELOPMENT.md)

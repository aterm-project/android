# 常见问题

[English](TROUBLESHOOTING.en.md) · [安装](INSTALLATION.md)

| 现象 | 检查方向 |
| --- | --- |
| 克隆或下载构建资产返回 404 | 仓库与资产目前为私有，需要对应 GitHub 访问权限；不要把令牌写进 URL 或文档。 |
| SDK 或锁文件不匹配 | 使用 Flutter 3.47.5 / Dart 3.13，保留五个 `packages/` 本地依赖；使用 `--enforce-lockfile`，不要靠任意升级依赖绕过安装问题。 |
| Windows 缺少 `atermius_rdp.dll` | 先构建原生引擎，或将 `ATERMIUS_RDP_DIR` 指向匹配的完整 bundle。 |
| 复制 EXE 后无法启动 | 需要完整运行目录，包含 DLL、资源与许可证，不能只复制 EXE。 |
| APK 无法覆盖已有应用 | 核对包名和签名证书；不同签名不能直接更新，迁移前先保存资料。 |
| Web 加载外部 CanvasKit/字体或出现 CSP 错误 | 以 `--no-web-resources-cdn` 重建，部署完整目录并使用提供的代理。 |
| 浏览器 SSH 无法连接 | 账户模式需开启 Relay，设置精确来源、允许的 CIDR 与端口；浏览器本地资料不具备直接 TCP 连接。 |
| RDP `20008` | 先核对目标端口/TLS；若取得证书指纹，按提示核验信任。通用握手失败不一定是证书问题。 |
| 没有临时网关能力 | 核对 SQLite、HTTPS、guacd、网关密钥存储和目标策略，检查 `/api/v1/instance`；日志中不要泄露秘密。 |
| 链接暂不可用或过期 | 核对 UTC 时间窗口、打开次数、连接/并发额度及撤销状态；另一链接的 Cookie 不能用于此链接。 |
| 浏览器本地资料/设置似乎消失 | 核对来源地址、浏览器资料、隐私模式和存储策略，不同来源有不同存储作用域。 |
| 全套测试失败而针对性 CI 通过 | 区分并记录历史基线失败，提供精确失败用例，不要称全套已通过。 |
| 一键导入 Termius 提示无法读取密钥或密钥不匹配 | 先在本机打开一次 Termius 桌面版；macOS 钥匙串弹窗选择“允许”。在 App Store 版与官网版之间切换过时，打开当前使用的版本后重试。仍失败时在 Termius 导出 CSV 再导入。 |

部署、健康检查和备份见[服务端文档](https://github.com/aterm-project/server/blob/main/docs/README.md)；协议细节见[远程桌面](REMOTE-DESKTOP.md)与 [Telnet](TELNET.md)。

提交问题请说明系统/架构、应用或源码版本、协议、最小复现和脱敏错误信息，不要包含密码、私钥、完整访问链接、账户令牌或用户数据库。

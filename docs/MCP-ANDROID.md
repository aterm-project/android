# Android 上的外部 AI（MCP）接入

通用工具、权限与配置格式见 [MCP.md](MCP.md)。本文只说明 Android 的监听、后台生命周期、转发方式和系统限制。

## 监听与认证

Android 与桌面端使用同一个监听实现：只绑定设备的 `127.0.0.1`（IPv4 回环），路径固定 `/mcp`，从不监听 `0.0.0.0`、局域网或 IPv6 地址。每次启用生成新的 256 位随机 Bearer 令牌，仅保存在内存。以下限制与桌面端相同，没有因 Android 放宽：

- `Host` 必须是 `127.0.0.1:<端口>` 或 `localhost:<端口>`；带 `Origin` 时必须是同端口的 `http://127.0.0.1` / `http://localhost`，用于阻止浏览器页面和 DNS 重绑定。
- 先校验 Host/Origin，再常量时间比较 `Authorization: Bearer <令牌>`；失败返回 401，不进入工具层。
- 仅 `POST application/json`，`Accept` 需同时含 `application/json` 与 `text/event-stream`；`GET` 返回 405。
- 请求体上限 512 KiB，请求体 10 秒内未传完即断开，最多 4 个并发工具请求（超出 429）。
- 同时打开的连接（含未认证连接）超过 16 个时返回 503，防止设备上的其他应用占满监听。

注意：Android 上任何安装了网络权限的应用都能连到本机回环端口，安全边界是令牌本身，而不是端口不可达。只把复制的配置交给受信任的客户端。

## 后台生命周期

在 **设置 → AI / MCP** 中启用服务是唯一的启动方式，且必须在应用可见时进行（Android 12 起禁止后台启动前台服务）。

1. 监听成功后，应用启动一个不导出（`exported=false`）的前台服务，类型为 `specialUse`，并显示常驻通知“外部 AI 访问已开启”，正文只含 `127.0.0.1:<端口>`，不含令牌。锁屏上通知内容为私密。
2. Android 13 及以上首次启用时会请求通知权限，仅为显示该通知及其 **停止** 按钮。只有通知确实可以显示（已授予通知权限、未关闭应用通知、未屏蔽“External AI (MCP)”通知渠道）时，MCP 才能在后台保持；否则按第 4 条的仅前台模式处理。
3. 通知中的 **停止**、从最近任务中划掉应用、系统终止前台服务或进程、Flutter 引擎销毁、监听套接字意外关闭，都会停止 MCP 并使令牌失效。服务使用 `START_NOT_STICKY`，进程被杀后不会自动恢复，令牌也不会被持久化；需要重新启用并更新 AI 端配置。
4. 若前台服务无法启动（被系统拒绝、超时等），或通知无法显示，MCP 只在应用可见时有效：应用一旦进入后台（`hidden`/`paused`），立即停止并撤销令牌，避免后台访问既不可见也无法从通知停止，或进程被冻结后令牌仍然有效但请求无响应。下拉通知栏、权限对话框等短暂遮挡（`inactive`）不会触发撤销。
   - 在应用内（可见时）授予通知权限或重新开启通知后，无需重新启用即可恢复后台保持。
   - 已在后台保持时，若在系统设置中关闭应用通知或屏蔽 MCP 渠道，立即撤销令牌；若在应用可见时关闭，则降为仅前台模式。撤回已授予的通知权限会由系统直接结束进程，令牌随之失效。
5. 应用内锁定、退出、切换 Profile / 账户 / Vault 与桌面端一致，会撤销授权。与 Windows 一致，设备锁屏本身不会停止 MCP；需要锁屏即撤销时请在锁屏前停止服务。

## 外部 AI 的连接方式

令牌和 URL 只从应用的“复制连接配置”获取。以下所有方式都必须让客户端发送的 `Host` 仍为 `127.0.0.1:<设备端口>`，因此**本地端口与设备端口必须相同**；使用不同端口会被 Host 校验拒绝（403），这是预期行为，不要通过改写 Host 的反向代理绕过。

### 同一设备上的客户端（如 Termux）

直接使用复制的配置，URL 为 `http://127.0.0.1:8765/mcp`。客户端在前台时 Atermius 在后台，必须依赖上面的前台服务；若通知或“使用中的应用”中看不到 Atermius，说明处于仅前台模式，切换应用即会撤销。

### 电脑通过 ADB（USB 或已配对的无线调试）

```sh
adb forward tcp:8765 tcp:8765        # 两端端口相同
# ……使用期间保持连接……
adb forward --remove tcp:8765
```

`adb forward` 默认只在电脑的 `127.0.0.1` 上监听。不要使用 `adb -a`（让 adb server 监听所有网卡），也不要再把该端口转发到局域网。

### 电脑通过 SSH

设备上运行 SSH 服务端（例如 Termux `sshd`，默认端口 8022）时，在电脑上：

```sh
ssh -N -L 127.0.0.1:8765:127.0.0.1:8765 -p 8022 <用户>@<设备地址>
```

或在设备上向电脑建立反向隧道：

```sh
ssh -N -R 127.0.0.1:8765:127.0.0.1:8765 <用户>@<电脑地址>
```

不要使用 `-g`、`0.0.0.0` 绑定地址或服务端 `GatewayPorts yes`。隧道只应把电脑本机回环映射到设备回环。

### 仅支持 stdio 的客户端

在电脑上完成上述转发后，可用仓库中的 `integration/mcp/stdio_bridge.py`，通过环境变量 `ATERMIUS_MCP_URL=http://127.0.0.1:8765/mcp` 与 `ATERMIUS_MCP_TOKEN` 提供端点和令牌；它同样只接受回环 URL，不记录令牌或消息。

## 系统限制（如实说明）

- **前台服务类型**：Android 14 起前台服务必须声明类型。本地 MCP 服务器不属于数据同步、媒体、定位等任何既定类型，因此使用 `specialUse` 并在清单中写明用途（`PROPERTY_SPECIAL_USE_FGS_SUBTYPE`）。若通过 Google Play 分发，需要在 Play Console 中提交该特殊用途声明并可能被审核。`specialUse` 没有系统运行时长上限；仍实现了 `onTimeout` 以便未来限制时撤销。
- **通知可被划掉**：Android 14 起用户可以划掉前台服务通知，服务不会因此停止；它仍显示在“使用中的应用”中。需要停止时请使用通知的停止按钮、“使用中的应用”或应用设置。
- **休眠与省电**：前台服务让进程不被缓存冻结，但应用不持有 WakeLock，屏幕关闭后 CPU 可能进入休眠，请求会延迟到设备被唤醒（USB/ADB 流量通常会唤醒设备）。部分厂商 ROM 的省电策略可能直接结束前台服务或进程；此时令牌随进程消失，客户端会收到连接被拒绝，需要重新启用。
- **其他应用可见**：见上文，回环端口对本机其他应用可达，依赖令牌和 Host/Origin 校验。设备被他人持有并已解锁时，应先停止 MCP。
- **不可后台启动**：服务只能在应用可见时由用户启用；系统重启或进程重建后不会自动开启。

## 验证范围

`test/mcp_listener_transport_test.dart` 以原始 TCP 套接字验证回环绑定、认证、Host/Origin、大小/超时/并发/连接上限和撤销；`test/mcp_listener_lifecycle_test.dart` 以模拟平台通道验证前台服务租约、通知停止、后台撤销与真实 `McpService` 令牌失效。这些是 Dart 层测试，不构成 Android 设备或 GUI 验证；Kotlin 原生服务需在实际 APK 构建与设备上验证。

---

## English summary

- The Android listener is the desktop one: IPv4 loopback only, unchanged Host/Origin/Bearer/size/timeout limits, plus a 16-connection cap because every app on the device can reach loopback. The 256-bit in-memory token is the security boundary.
- Enabling MCP (an explicit action while the app is visible) starts an unexported `specialUse` foreground service with an ongoing notification whose **Stop** action revokes the token. Android 13+ asks for the notification permission at that moment only.
- MCP stays alive in the background only while that notification can really be shown (permission granted, app notifications on, MCP channel not blocked). Otherwise it is foreground-only and revoked when the app is hidden/paused. Granting notifications while the app is visible restores background protection; blocking them while protected downgrades to foreground-only in the foreground and revokes immediately in the background.
- Notification Stop, task removal, service/process death, engine teardown or socket loss stop MCP and invalidate the token; `START_NOT_STICKY`, nothing persisted. Without a foreground service or a visible notification, MCP is revoked as soon as the app is hidden. In-app lock/logout/workspace switch revoke as on desktop; device screen lock does not (same as Windows).
- Forward with identical ports so `Host` stays `127.0.0.1:<port>`: `adb forward tcp:8765 tcp:8765`, or `ssh -L 127.0.0.1:8765:127.0.0.1:8765 …` / `ssh -R 127.0.0.1:8765:127.0.0.1:8765 …`. Never `adb -a`, `ssh -g`, `GatewayPorts`, LAN binds or Host-rewriting proxies.
- Limits: Play distribution needs a special-use declaration; Android 14+ notifications are dismissible (the service stays in Active apps); no wakelock, so screen-off deep sleep may delay requests; aggressive OEM battery managers may kill the service (token is then gone).

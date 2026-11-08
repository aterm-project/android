# RDP、VNC 与本机 Console

主机编辑器新增 `Protocol`，可选择 SSH、RDP 或 VNC。旧记录没有 `protocol` 时仍解释为 SSH；默认端口分别为 22、3389、5900。协议和 RDP 证书指纹随主机记录加密保存、导出和同步。修改协议时保留自定义端口，清除不适用的 SSH 跳板/转发配置。

## 使用方式

- **Windows 独立客户端**：标签栏的“＋”直接选择 SSH、RDP、VNC 或本机 Console。RDP 使用随包的 FreeRDP 3.33.0 / OpenSSL 3.6.5；VNC 使用应用内的 RFB 实现。本地模式与账户工作区均从设备直接连接目标，无需 guacd、Docker、WSL 或外部桌面查看器。画面仍在应用标签/分屏内，三个点菜单提供 Ctrl+Alt+Delete、复制和粘贴。
- **Web 与其他平台的 RDP**：Web 继续使用账户工作区和服务端网关。尚未打包原生 RDP 引擎的平台保留已有网关路径：账户模式使用服务端，本地模式使用 `127.0.0.1:4822`。原生 VNC 源码已共用直接连接实现；本轮没有更新 Android 安装包，也不将 Android RDP 标记为独立运行已完成。
- **本机 Console**：桌面端“＋”菜单的“本机 Console”打开本机交互式 Shell 标签。Unix 使用 `$SHELL`（回退 `/bin/sh`），Windows 使用 `%COMSPEC%`（回退 `cmd.exe`）。PTY 连接现有 xterm 组件，支持尺寸变化和关闭进程。Console 不保存为远程主机、不参与凭据同步。
- **浏览器本地配置**：不能直接创建操作系统 Shell 或 TCP 连接。Web RDP/VNC 使用已登录的账户工作区和服务端网关。本次没有添加浏览器本机代理或服务端 Shell 接口。

## 服务端部署

远程桌面采用 Apache Guacamole 的 guacd 转换 RDP/VNC，客户端使用共享 Flutter 渲染器。已有 SSH Relay 不需要 guacd。

```sh
export ATERMIUS_RELAY_ENABLED=true
export ATERMIUS_PUBLIC_ORIGIN=https://atermius.example.com
export ATERMIUS_RELAY_ALLOW_CIDRS=10.20.0.0/16
export ATERMIUS_RELAY_ALLOW_PORTS=22,3389,5900

docker compose -f deploy/compose.yaml -f deploy/compose.desktop.yaml up -d --build
```

按实际目标缩小 CIDR 和端口范围，并保留现有 TLS 反向代理配置。叠加配置添加固定版本/摘要的 `guacamole/guacd:1.6.0`，不发布 4822 端口。服务端通过 `ATERMIUS_GUACD_ADDRESS=guacd:4822` 访问它；非 Compose 部署可以设置为 `127.0.0.1:4822`。未配置时 `/desktop/v1/connect` 返回 `503 DESKTOP_DISABLED`。

guacd 是受信任的会话网关：会话期间可接触目标凭据、画面和输入，不能将它当作 SSH 的端到端加密字节中继。只在受信任的本机/私有容器网络上开放 guacd，并在部署网络限制其可达目标。Atermius 的 Relay 策略约束初始连接目标；远程服务自身的重定向行为还需由网关的网络访问策略限制。服务端不持久化桌面密码或录制画面，音频、打印、磁盘与 SFTP 重定向均未启用。

未内置 RDP 引擎的其他桌面平台，使用本地配置时仍可启动回环网关（Windows 新包不需要）：

```sh
docker run --rm --name atermius-local-guacd \
  -p 127.0.0.1:4822:4822 \
  guacamole/guacd:1.6.0@sha256:8974eaa9ba32f713daf311e7cc8cd7e4cdfba1edea39eed75524e78ef4b08f4f
```

主机地址必须从 guacd 所在网络可达；容器里的 `127.0.0.1` 指容器自身。

## RDP 证书与登录

Windows 遇到未受信任证书时会自动弹出确认框，显示目标地址和证书 DER 的 SHA-256。点击“信任并保存”后，指纹随该主机加密保存，再用此精确指纹重新连接。下次指纹变化时展示新旧指纹，只有点击“更新并连接”才替换保存记录并继续；取消、保存失败或工作区切换均不会放行。保存通过主机版本检查，避免覆盖并发编辑或恢复已经删除的主机。证书确认发生在目标认证之前，不设置忽略证书验证。

`20008` 是 TLS 握手失败的通用码。若引擎已取得被拒绝的证书，客户端使用上述确认流程；若没有取得证书，仍保留明确的 TLS/端口错误，不将所有握手失败误判为未信任证书。

此流程已随 2026-11-07 Windows 更新交付，并对隔离 xrdp TLS 目标验证未知/错误指纹拒绝、证书指纹提取和确认后的真实画面。新 Dart 接口必须与新 DLL 一起分发；当前构建目录为 `C:\atermius-rdpfix\20261107\native-bundle`。具体包、桌面快捷方式与验证边界见 [证书与快捷连接交付记录](../.codex-build/rdp-search-20261107/README.md)。

默认保留证书校验。自签名证书或按固定 IP 连接的主机，可在编辑器填入管理员通过可信渠道提供的 **RDP certificate SHA-256**。接受 64 个十六进制字符或带冒号格式，规范化后随主机加密保存。Windows 引擎使用证书 DER 的 SHA-256 严格匹配，错误指纹或未受信任且未指定指纹的证书均拒绝；网关使用 `cert-fingerprints` 校验，不自动信任首次证书，不设置 `ignore-cert=true`。该功能要求 guacd 支持 `cert-fingerprints`，否则拒绝连接。

需要 NLA 的 Windows 主机必须提前保存用户名和密码。可使用 `user@domain` 用户名；当前没有交互式 NLA 凭据补充对话框。未填写凭据时，只能使用允许图形登录的目标。SSH 私钥、Jump Host、端口转发、tmux 和 SSH 文件管理不适用于桌面会话。

## 每台主机的 RDP/VNC 选项、独立窗口与重定向（开发中 — 2026-11-07）

主机编辑器的 RDP 主机新增 **RDP options**，VNC 主机新增 **VNC display**。设置随主机加密保存（manifest 中的 `rdp_settings_v1` / `vnc_settings_v1`）；未改动时不写入，旧记录保持原样。设置不包含任何密码。

- **分辨率**：自动（随窗口）、预设（1280×720 … 3840×2160）或自定义；限制为每边 200–8192 像素、总像素不超过 32 MP。RDP 固定尺寸在连接时生效；自动模式通过显示控制通道随窗口调整。会话菜单“分辨率与缩放…”会显示服务器是否支持实时调整。VNC 仅在服务器协商 ExtendedDesktopSize 后才发送 SetDesktopSize，并显示服务器返回的结果；不支持时只提供本地缩放，并明确说明。“本地显示（适应窗口 / 实际大小）”只缩放本窗口，不改变远程分辨率。
- **多显示器**：使用本机全部显示器的布局；此时远程分辨率由显示器决定。“每个显示器一个窗口”为每台显示器打开一个无边框窗口。
- **剪贴板**：文本与文件分开开关。文件：可发送本机已复制的文件（Windows 资源管理器）或选择文件；远程复制的文件可保存到所选文件夹，并放入本机剪贴板。远程文件名不安全时整批拒绝；不覆盖已有文件。
- **本地资源**：指定文件夹（不提供“全部驱动器”）、声音播放/录音（winmm）、打印机（Windows 打印后台；服务器需有对应驱动，不支持 XPS Easy Print）、智能卡（系统 WinSCard）、摄像头（Media Foundation，原格式直通）。通用 USB 需要设备本身已使用 WinUSB 驱动；**Atermius 不安装、不替换任何驱动，也不修改系统策略**。引擎不具备某项能力时，开关会变灰并注明原因。
- **独立窗口**：远程桌面标签可移到独立窗口，或按显示器拆分。会话、主机和凭据始终留在主窗口；子窗口只显示画面并转发输入，锁定、退出或关闭主窗口时一并关闭。
- **键盘**：远程桌面获得焦点后，所有按键都发送到远程，只有 **Ctrl+Alt+Home** 在本机打开会话菜单（与 Windows 远程桌面客户端一致）。

验证与限制：见 `.codex-build/rdp-claude-20261107/RESULT.md`。摄像头、智能卡、打印机、麦克风和 USB 尚未在真实硬件上验收。

## Windows 独立版本验收 — 2026-11-07

- 隐藏原生 Windows 终端底部 Ctrl/Alt 软件键栏；Android 软件键栏保留。Windows 平台定向测试验证实体 Ctrl+C、中文提交与终端输入处理器不受隐藏影响。
- 统一创建菜单按所选协议预填默认端口。远程桌面取消第二条信息 topbar，功能收进圆角三个点菜单。
- Console/桌面在本地工作区中随选中标签隔离焦点，切换后释放修饰键；桌面分屏单击即可恢复键盘焦点。目标禁用剪贴板时只提示，不再把它视为传输断开。
- Windows Session0 AOT 探针对隔离 xrdp TLS 与 VNC 目标验证真实画面变化和键鼠输入；目标内命令标记独立确认输入到达。错误证书指纹、自签名证书未设置指纹均被拒绝。没有连接或操作用户正在使用的 Windows RDP 会话。
- Windows ConPTY 验证真实命令回显、101×41 尺寸变化和进程关闭。最终包的协议引擎和 PTY DLL 均与所测 DLL 对应校验。
- RDP 位图存储兼容 xrdp 的四像素对齐：源宽不得小于目标，最多允许三个填充像素且必须四像素对齐；其他尺寸/数据边界检查保留。补丁和来源固定在 `apps/client/native/desktop/bitmap_padding.cmake`。
- 详细源码、包摘要、测试与交付记录见 [Windows 独立桌面交付](../.codex-build/direct-desktop-20261107/README.md)。本轮未以用户 RDP 的表现作为观测指标，也未宣称完整 Windows GUI 人工验收。

Windows RDP 保留 TLS/NLA 协议支持与证书校验；本轮真实目标是 xrdp TLS，尚未对 Windows Server NLA、域策略、所有键盘布局和剪贴板策略完成兼容矩阵。音视频、磁盘、打印和智能卡重定向已在后续开发中加入，见上节。VNC 支持 RFB 3.3/3.7/3.8、Raw/CopyRect/DesktopSize、无认证及传统 VNC 密码认证；不实现 VeNCrypt/RealVNC 专有认证，传统 VNC 传输不加密，剪贴板使用协议规定的 Latin-1 文本。

构建 Windows 引擎使用固定 FreeRDP 源码摘要，先通过 vcpkg 准备 `openssl:x64-windows-static-md` 与 `zlib:x64-windows-static-md`，再运行 `integration/native/build_rdp_windows.ps1`。将产物目录设为 `ATERMIUS_RDP_DIR` 后构建 Flutter Windows。CMake 在缺少引擎时拒绝生成不完整安装包；DLL 与许可证随 Release 一起分发。

## 验证范围

2026-11-06：

- Dart 协议/渲染/主机编辑及相关模型、原有终端控制器定向测试通过；Chromium 验证 Unicode 分包、PNG 解码、图层复制与裁剪复位。
- 本地保险库验证无用户名的 RDP/VNC 主机可以保存，协议、密码和证书指纹可加密读回；SSH 服务拒绝将桌面主机用作 SSH 目标或跳板。
- 隔离的 guacd 1.6.0 + TigerVNC 和 xrdp 实测画面与键鼠；xrdp 使用 TLS 和指定 SHA-256 指纹。两条链路在目标容器中写入独立命令标记，并保留渲染截图于 `.codex-build/desktop-20261106/`。
- Linux 真实 PTY 测试验证 `test -t 0`、`stty size` 与关闭进程。
- 服务端 WebSocket 验证一次性票据、Origin、目标固定、禁止客户端重新握手/改目标、设备撤销断开；现有 Relay Rust 回归通过。
- Linux 和 Web Release 可构建。Windows/macOS 的 PTY 适配使用 flutter_pty，未在真实 Windows/macOS 设备上验收。未验证 Windows Server NLA、移动触屏/IME、音视频、打印/磁盘重定向或所有 Guacamole 扩展。

以上为定向验收，不代表全仓库测试通过。既有 `host_editor_tags_test.dart` 对 HostCard 徽标/编辑入口的断言在当前工作区仍失败；本次新增的主机编辑器测试通过。Web 已验证编译、Chromium 协议渲染及独立服务端鉴权链路，未进行完整浏览器登录后连接真实 RDP/VNC 的端到端验收。

普通回归：

```sh
cd apps/client
flutter test test/desktop_protocol_test.dart test/desktop_host_editor_test.dart
# Chromium 环境另运行：flutter test --platform chrome test/desktop_protocol_test.dart
```

真实网关与 PTY 测试为显式启用的 `desktop_guacd_acceptance_test.dart` 和 `local_console_acceptance_test.dart`，只对隔离测试目标运行；配置参数见文件头。`integration/test_desktop.py` 使用临时账户/数据库和受控 guacd 协议端点，无需生产服务。

参考：[Apache Guacamole 协议](https://guacamole.apache.org/doc/gug/guacamole-protocol.html)、[guacamole-common-js](https://github.com/apache/guacamole-client/tree/1.6.0/guacamole-common-js)、[RDP 配置](https://guacamole.apache.org/doc/gug/configuring-guacamole.html)、[flutter_pty](https://github.com/TerminalStudio/flutter_pty)。客户端绘图实现为本项目的 Dart 代码，不依赖嵌套网页或系统远程桌面客户端。

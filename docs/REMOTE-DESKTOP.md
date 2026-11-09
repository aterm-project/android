# RDP、VNC 与本机 Console

[文档导航](README.md) · [平台矩阵](FEATURES.md) · [安装构建](INSTALLATION.md)

## 选择连接路径

| 路径 | 前提与范围 |
| --- | --- |
| Windows 原生 RDP | 与应用匹配的 `atermius_rdp.dll` bundle，直接连接目标，不依赖 guacd |
| Android 原生 RDP | APK 内的 `libatermius_rdp.so`（arm64-v8a、x86_64），直接连接目标，不依赖 guacd 或外部查看器 |
| 原生 VNC | 使用应用中的直接 RFB 实现，具体平台取决于构建和运行能力 |
| 账户模式浏览器 RDP/VNC | 服务端配置 guacd、来源和目标策略 |
| 临时访客 SSH/RDP | 单独的可信分享网关，要求 SQLite、HTTPS、胶囊与链接策略 |
| 本机 Shell / 串口 Console | 桌面操作系统和相应 Shell/设备；浏览器不能创建系统进程或串口 |

添加主机时选择协议并检查端口，默认 SSH/RDP/VNC 分别为 22/3389/5900；保留自定义端口。密码、证书指纹及协议设置随主机加密保存。SSH 跳板、转发、tmux 和 SSH 文件管理不是 RDP/VNC 设置。

## 证书与登录

Windows 在取得被拒证书时显示目标和证书 DER 的 SHA-256。先与可信渠道核对，再选择信任保存；指纹变化需要再次确认。取消、保存失败或工作区切换不会放行，不使用忽略证书验证来绕过问题。`20008` 是通用 TLS 握手错误，没有取得证书时也可能是端口或 TLS 配置错误。

可在主机编辑器录入管理员提供的证书 SHA-256。Windows 引擎严格匹配；网关要求支持 `cert-fingerprints`，不会自动接受首次证书。目标使用 NLA 时需提前保存用户名、密码和必要域信息；当前没有登录过程中补填 NLA 凭据的完整对话框。

## 显示、窗口与资源

主机编辑器提供 RDP/VNC 显示选项，包括自动、预设或自定义尺寸。RDP 实时调整依赖目标的显示控制能力；VNC 仅在协商 ExtendedDesktopSize 后尝试改变远端尺寸，否则提供本地适应/实际大小缩放。多显示器、独立窗口和分屏依赖当前平台与引擎能力，不等于每台设备都具备这些能力。

Windows 原生引擎提供文本/文件剪贴板与可用资源重定向的设置，能力不可用时应保持禁用或显示原因。摄像头、麦克风、智能卡、打印机、USB 和物理多显示器仍需要真实硬件验收。应用不安装或替换 USB 驱动；设备须具备兼容现有系统绑定。临时访客网关不开放文件、驱动器、打印或录制通道。

远程桌面获得焦点后，按键发往远端；Windows 的 **Ctrl+Alt+Home** 打开本机会话菜单，其他绑定按应用设置处理。

## Android 直接连接

Android 上 RDP/VNC 只走直接连接，在会话标签和分屏内显示：VNC 由应用内 RFB 实现连接目标地址；RDP 由 APK 内引擎连接。连接使用系统路由和当前 VPN，不绑定特定网络，也不读取进程环境中的 HTTP(S) 代理；VPN 阻断目标时连接照常失败。任何模式（含已登录账户）都不会回退到本机 `127.0.0.1:4822` 或服务端桌面网关。未打包引擎的 APK 中，RDP 明确报告“无法启动 RDP 引擎”。

证书流程与 Windows 相同：首次或变化的证书显示 SHA-256，用户确认保存后按该指纹重连。Android 引擎不读取系统 CA 库，CA 签发证书同样需要确认指纹。首版不提供文件夹、打印机、智能卡、音频、摄像头、USB 重定向，相关选项按引擎能力禁用；文本剪贴板与显示调整保留。引擎的 FreeRDP 配置目录位于应用私有目录。WinPR 需要 JavaVM，`MainActivity` 启动时以 `System.loadLibrary` 加载引擎以运行其 `JNI_OnLoad`；未注册 JavaVM 时引擎拒绝创建连接，RDP 报告不可用而不会使应用退出。

引擎构建：`apps/client/native/desktop/android/build_engine.sh` 用 NDK r28+ 及 `deps.lock` 中固定摘要的官方 OpenSSL 3.5.9 与 FreeRDP 3.33.0 源码包，生成每个 ABI 一个自包含 `.so`（依赖静态链接，16 KB 页对齐），并由 `verify_engine.py` 检查导出、依赖和对齐。脚本不联网，源码包需预先放入 `--deps` 目录。随后以 `-Patermius.rdpEngineDir=<输出目录>`（可加 `-Patermius.requireRdpEngine=true`）构建 APK，许可证随包放在 `assets/licenses/atermius_rdp/`；用 `integration/native/android_apk_abi_check.py --require-lib libatermius_rdp.so` 核对 APK。

## 网关部署

网关可访问目标登录信息、画面和输入，是受信组件。仅将 guacd 放在受控私有网络，限制目标范围，不向外发布 4822。普通 SSH 字节 Relay 不需要 guacd。

使用[服务端安装指南](https://github.com/aterm-project/server/blob/main/docs/INSTALLATION.md)组装独立 API/Web；常规远程桌面添加 `compose.desktop.yaml` 并配置 Relay 目标策略。临时分享另加 `compose.share.yaml`，参考[分享配置](https://github.com/aterm-project/server/blob/main/docs/CLOUD-SHARING.md)。操作时保留原来的 TLS/Web/其他覆盖文件，不在客户端仓库运行不存在的服务端路径。

Windows 直接 RDP 构建步骤见[桌面仓库指南](https://github.com/aterm-project/desktop/blob/main/docs/INSTALLATION.md)。使用配套 FreeRDP 源码摘要与许可证，不引用历史测试机器的构建目录，也不单独替换 Dart 程序或 DLL。

## 已知边界与验证

RDP 目标的 NLA、域策略、所有键盘布局、资源/剪贴板组合仍需相应环境验证。VNC 支持的传统 RFB 传输不提供端到端加密，未实现所有专有/VeNCrypt 认证；传统剪贴板按 Latin-1 处理，不承诺完整 Unicode 剪贴板。当前源码 CI 的组件/协议检查不等于新的 Windows/macOS/Android/iOS 可视 GUI 验收。

针对性测试入口为 `apps/client/test/desktop_protocol_test.dart`、`desktop_host_editor_test.dart`、Android 路由的 `android_direct_desktop_test.dart`/`android_desktop_route_test.dart` 及显式启用的网关/Console 验收文件。跨仓服务端链路参考[集成说明](https://github.com/aterm-project/server/blob/main/docs/INTEGRATION.md)。环境条件不足的跳过不算真实目标通过；物理硬件和当前安装包验收单独记录。

参考：[Guacamole 协议](https://guacamole.apache.org/doc/gug/guacamole-protocol.html)、[RDP 配置](https://guacamole.apache.org/doc/gug/configuring-guacamole.html)、[Flutter Windows 分发](https://docs.flutter.dev/platform-integration/windows/building)。


## Keyboard, pointer and fullscreen controls

Android 首页及设置页进入全屏后保留导航和 Tools 菜单，始终可以选择退出全屏；选中会话时仍隐藏导航，仅放大当前面板。

SSH/Telnet 的终端菜单和标签右键菜单（Android 长按标签）提供 Disconnect／断开连接。主动断开保留原标签、分屏及终端记录，并暂停每 5 秒自动重连；点击“恢复连接”后重新建立连接并恢复后续自动重连。组合标签只断开当前选中的面板。关闭标签仍通过原关闭入口执行。断开时也会取消尚未完成的连接，延迟返回的旧连接不能重新接管面板。

Android 的键盘、触摸/鼠标切换和三点参数菜单位于同一个贴边悬浮按钮组，可共同拖动。常规手机及左右分屏内横向并排，极窄面板改为纵向排列。Android 全屏会隐藏应用标签栏和状态栏，将当前面板铺满内容区；退出按钮或系统返回恢复原有分屏和会话。组合标签也可以拖动其中当前选中的会话，以重新排列分屏；连接与终端记录不会复制或重建。

账户与本地配置下的 SSH、Telnet、RDP、VNC 会话断开后可点击“恢复连接”。SSH/Telnet 已建立的会话中断后每 5 秒尝试重连；首次连接失败由用户手动重试，主机密钥拒绝停止自动弹窗重试。恢复保留原标签、分屏位置及终端记录，不重放先前输入。关闭标签、锁定配置、切换账户或 Vault 后，旧作用域不能继续重连；主机密钥和 RDP 证书仍执行原有验证流程。

On Android, RDP and VNC show a dock on the edge of each pane. The keyboard button opens the system keyboard together with a special-key bar. Ctrl/Alt/Shift/Win apply to the next key after a single tap; double-tap to lock, then tap again to release. Composed text is sent when the IME commits it. The adjacent button switches between direct touch and a relative mouse touchpad. In touchpad mode, tap clicks at the cursor, slide moves it, two fingers scroll or right-click, and a second tap held down drags. The dock can move vertically or to the opposite edge and stays inside the resized pane above the keyboard.

The navigation bar's Tools menu and remote desktop's three-dot menu provide Enter fullscreen / Exit fullscreen. Windows covers the current monitor and restores its saved placement; macOS uses native fullscreen Spaces; Android hides system bars through its own-window insets controller; iOS uses supported manual overlays. Web uses the browser fullscreen API and follows browser exit events. An unavailable platform operation keeps the normal window and reports the failure. System-owned window captions may remain visible in Android desktop windowing mode.

On Android/iOS, pull a tab down to lift it from a scrolling strip, then drag to a highlighted pane edge. A diagonal pull is accepted while a horizontal swipe still scrolls tabs. A drop in the centre leaves the layout intact; a small amount of corner jitter keeps the highlighted direction. Stationary long-press still opens the tab/group context menu.

VNC IME text retains legacy Latin-1 keysyms where available, and uses Unicode keysyms for additional characters, as required for maximum compatibility by [RFC 6143 §7.5.4](https://www.rfc-editor.org/rfc/rfc6143.html#section-7.5.4). RDP uses Unicode text events when no soft modifier is active.

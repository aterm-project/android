# Features and platform boundaries / 功能与平台边界

[English first use](GETTING_STARTED.en.md) · [中文上手](GETTING_STARTED.md)

| Workflow / 功能 | Native clients / 原生客户端 | Browser / 浏览器 |
| --- | --- | --- |
| SSH + SFTP/SCP | Direct SSH; OS/network permissions apply / 直接连接 | Regular account workspace uses the server's restricted Relay / 账户模式需 Relay |
| Local encrypted profile / 加密本地资料 | Device-local persistence / 设备端保存 | Browser-origin storage; no direct OS TCP / 站点存储，无直接系统 TCP |
| Encrypted sync / 加密同步 | Optional self-hosted account / 可选自托管账户 | Same Vault/device protocol / 同一 Vault 与设备协议 |
| Local shell + serial Console / 本机终端与串口 | Desktop only; installed shell/device required / 桌面需已安装 Shell/设备 | Unavailable / 不支持 |
| SSH forwarding / SSH 转发 | Native socket runtime; remote SSH policy also applies / 系统套接字与 SSH 服务端策略约束 | Rules can be represented; no OS TCP listener / 不创建系统 TCP 监听 |
| Native RDP / 原生 RDP | Windows with matching bundled FreeRDP engine; Android with the engine packaged in the APK; macOS/iOS engine builds are in their [install guides](INSTALLATION.en.md) / Windows 需配套引擎，Android 使用 APK 内引擎，macOS/iOS 见[安装指南](INSTALLATION.md) | Uses the optional server gateway / 使用可选服务端网关 |
| RDP/VNC display / 远程桌面画面 | Available transport depends on platform/build / 依平台与构建能力 | guacd, target policy and account prerequisites apply / 需网关、目标策略与账户 |
| Split panes and saved sets / 分屏与窗口组合 | Workspace support; OS windows on desktop / 工作区支持，系统窗口限桌面 | Browser workspace panes / 浏览器工作区面板 |
| Organizations and member Host sharing / 组织与成员分享 | Requires server capabilities / 需服务端能力 | Requires server capabilities / 需服务端能力 |
| Temporary guest SSH/RDP / 临时访客访问 | Open its URL in a supported browser / 在支持的浏览器打开链接 | Separate account-free trusted-gateway flow / 独立免账户受信网关流程 |
| External MCP / 外部 MCP | Desktop and Android loopback service, explicit opt-in; iOS has no listener / 桌面与 Android 回环服务，显式启用；iOS 不监听 | No OS listener / 不监听系统端口 |

Chinese, Japanese, English and Russian UI catalogs are included. Application accents and terminal palettes are separate settings. / 界面包含中、日、英、俄四种语言；应用强调色与终端配色分开设置。

Source availability is not a native-device acceptance claim. macOS/iOS runners require their own build/signing/device validation; Android does not bundle the native Windows RDP engine. Physical USB, camera, microphone, smart-card, printer and multiple-monitor workflows need compatible systems/hardware and separate acceptance. Atermius installs no USB driver. / 源码存在不等于已完成设备验收；macOS/iOS 需要相应构建、签名与设备验证，Android 不含 Windows 原生 RDP 引擎。USB、摄像头、麦克风、智能卡、打印机及物理多显示器须另行验证，应用不安装 USB 驱动。

Regular browser SSH is an encrypted byte Relay; a desktop/guest gateway can access the remote login/session. See [sharing](SHARING.en.md), [远程桌面](REMOTE-DESKTOP.md), [本机 Shell](LOCAL-SHELL.md), [Telnet](TELNET.md), [导入导出](IMPORT_EXPORT.md) and [MCP](MCP.md).

# Atermius 云端协作与临时访问设计（提案）

- 状态：**设计提案，未实现**。本文不代表任何功能已交付；所有表、路由、字段均为待评审草案。
- 日期：2026-11-07；作者：Claude Opus 5.5（独立设计会话）。
- 配套文件：[`API.yaml`](API.yaml)（OpenAPI 草案）、[`schema.sql`](schema.sql)（仅提案，不执行）、[`ROLLOUT.md`](ROLLOUT.md)（上线与兼容）、[`ACCEPTANCE-TESTS.md`](ACCEPTANCE-TESTS.md)（验收与滥用用例）。
- **安全门槛（协调评审 2026-11-07 第 5 点）**：总纲 §24.8「规范级加固放最后」不适用于本功能的核心门槛。任何对外暴露的分享/访客/网关能力（包括原型）在开放前必须同时具备：对象级授权（每次读/写/连接/WS 复查）、Origin/CSRF、基线速率与并发上限、凭据与日志泄露防护，以及对应的**负向验收测试**（`ACCEPTANCE-TESTS.md` §1「核心安全门槛」）。只有阈值调优、模糊测试、外部评审、可选的会话密钥绑定等归入上线前里程碑 MH，文中以「MH」标注。

---

## 0. 核心决策摘要

| # | 决策 | 理由 |
| --- | --- | --- |
| D1 | **共享的密码学单元仍是 Vault**。「把 Host 分享给用户/团队」= 把 Host 放进（或复制到）一个共享 Vault，并对该 Vault 授予用户/团队角色。不在 v1 引入记录级密钥。 | 现有 E2E 边界、签名成员清单、epoch 轮换、Recovery box 全部以 Vault 为单位（总纲 §7.3、§8.7、§9.7）。记录级密钥会改写记录密文格式与所有验证器。 |
| D2 | 新增**服务端管理的组织/团队控制面**（名称、成员、角色对服务端可见），团队授权只表达「期望成员」；**密钥分发仍由持有 Vault 密钥的 V-Owner 客户端在逐人确认后完成**（P3 起可含 V-Admin；“待分发密钥”状态是显式的）。 | 服务端不能替用户封装 Vault 密钥（G12）。与 `relay_access_groups` 一样属于明文元数据，必须在 UI 与文档中如实说明。 |
| D3 | 外部访客（临时链接）与内部「仅连接」授权使用**隔离网关会话**（Gateway mode）：创建者客户端把最小连接胶囊（目标、用户名、凭据、主机密钥/证书指纹）`crypto_box_seal` 给**网关专用 X25519 公钥**；网关解封后经现有 guacd 管线终止 SSH/RDP/VNC，访客浏览器只拿到画面/终端渲染流。 | 分享 API 与渲染流不向访客下发登录秘密；不需要创建者在线；复用已验收的 `/desktop/v1/connect` + guacd 管线（`server/src/desktop.rs`）。代价（如实）：网关私钥可重复使用、胶囊持久存储，**掌握网关私钥 + 数据库的运营者/入侵者可在任何时间解封任何未删除的胶囊**；「只在会话期间解封」是实现策略，不是密码学保证。这是按 Host/链接显式 opt-in 的「受信网关」模式，不是零知识。 |
| D4 | 链接 URL = `https://<origin>/s/<slug>#s1.<secret>`。slug 只是地址；256-bit secret 只在 fragment，前端派生 `redeem_token` 后以 POST body 兑换，服务端只存 SHA-256；兑换成功设置 `__Host-` HttpOnly Secure SameSite=Strict cookie。 | fragment 不进入 HTTP 请求、Referer 与访问日志；GET 不消耗次数、兑换需用户点击，可挡住普通链接预览（unfurler）。**不能**保证安全扫描器无法兑换：邮件/聊天安全网关可能拿到含 fragment 的完整 URL 并执行 JS、点击按钮（§6.4 残余风险与缓解）。 |
| D5 | 访客永远**不能选择目标**；目标在创建链接时由服务端按「创建者有效 Relay 策略 ∩ 实例共享策略」检查并固定，每次连接重新解析 DNS、检查全部答案、按 IP 固定拨号。 | 防止 guest 驱动的 SSRF/开放代理与 DNS rebinding。 |
| D6 | 撤销/收窄统一为「推进 `authz_revision` + 活动连接 ≤2 s 复查后关闭」，并加进程内广播即时唤醒；收窄一律断开，放宽只影响新连接。 | 与现有 Relay 授权版本机制一致（`server/migrations/0043_server_managed_relay_groups.sql`、`server/src/relay.rs:1801`）。 |
| D7 | 已保存窗口组合**以客户端已实现的 `WindowCombination` v1 为基线**（加密 Vault Preference `workspace/windowCombinations/all`，混合 SSH/SFTP/SCP/RDP/VNC/Console、串口/波特率、远程路径、≤32 组合/≤32 面板、比例 0.15–0.85、独立标签）。云端不新增服务端表，沿用加密记录同步与 Vault 角色授权。多窗口几何作为**附加** Preference 键 `windowCombinationPlacements` 提案，不改写 v1 配方；`WorkspaceRecord` v1–v3 原样保留。 | 不与进行中的客户端功能冲突；总纲 §7.4 规定像素坐标不同步，只同步规范化放置意图。 |
| D7a | 主页**一次点击 = 打开并连接**该组合（用户手势即授权）；主机密钥/RDP 证书/NLA 等身份确认仍逐个出现；另设可选「预览」次要操作；**永不**在启动、同步拉取或被动读取时自动连接。 | 用户明确要求一键打开；与 `CombinationRestoreCoordinator` 现有语义一致。 |
| D9 | **MVP 收窄**：P1 只用现有 owner/editor/viewer；临时链接与网关胶囊在 P1 仅限 V-Owner（Gateway 授权属 P2，同样先限 V-Owner）；Vault `admin` 角色与 manifest 签名者 v2 延后到 P3 的兼容阶段。 | 避免把所有 Host 分享绑到成员清单密码学改写上。 |
| D8 | 浏览器本地解密（E2E guest）只作为 P3 扩展，且**仅允许短期/一次性凭据**（例如创建者签发的短期 SSH 证书）。 | 浏览器拿到的凭据必然可被访客导出；不能声称「零知识」同时「访客看不到密码」。 |

---

## 1. 现状盘点（扩展而非替换）

| 领域 | 已有实现 | 文件 | 本设计如何复用 |
| --- | --- | --- | --- |
| 账户/会话 | Bearer access/refresh、设备绑定 session、MFA、管理员邀请注册 | `server/src/auth.rs`、`server/migrations/0001_initial.sql`（`sessions`、`devices`）、`0002_account_invitations.sql` | 组织邀请对未注册者复用 `account_invitations` 发放注册资格 |
| Vault 与成员 | 角色 `owner/editor/viewer`；设备定向邀请（token hash、key envelope、签名 manifest）；轮换、所有权转移、删除宽限 | `server/src/control.rs:1074`（create_invitation，仅 owner）、`:1336`（accept）、`:1523`（rotate）、`:1536`（transfer）；`0001_initial.sql`（`vault_members`、`vault_key_envelopes`、`membership_manifests`、`invitations`） | P2 新增 `suspended` 状态与 `source`，团队授权通过新 `membership/apply` 落成签名 manifest；`admin` 角色延后到 P3 |
| 授权检查 | `require_vault`：成员 active + 账户 active，外部 Vault ID 统一 404 | `server/src/lib.rs:2909` | 所有新 Vault 子资源沿用同一 404 语义 |
| Relay | 30 s 单次票据（hash 存储，目标加密），绑定 session/设备/授权版本；禁 loopback/link-local/元数据；部署∩实例∩账户∩组策略；~2 s 轮询断开 | `server/src/relay.rs:44-200,1496-1660,1801`；`0012`、`0030`、`0042`、`0043` 迁移 | 共享目标检查、DNS 解析/固定、授权版本断开全部复用 |
| 远程桌面网关 | `/desktop/v1/connect`：首帧票据→`DesktopHello`（含明文用户名/密码）→服务端构造 guacd `connect`，hostname/port 由票据固定；输入指令白名单 | `server/src/desktop.rs:100-240`、`docs/REMOTE-DESKTOP.md` | 访客/仅连接会话复用 handshake，凭据来源从浏览器改为网关解封的胶囊；新增 ssh 协议与 clipboard/read-only 参数 |
| 终端协作 | 主持端持 SSH，观察者 E2E 帧；v2 单控制者租约；内存房间 | `server/src/collaboration.rs`、`protocol/TERMINAL-COLLABORATION.md` | 作为「创建者在线的协助模式」备选（§2.3 方案 C），不是访客链接首选 |
| 服务端管理组 | `relay_access_groups`（实例管理员、明文名称、CAS revision） | `0043_server_managed_relay_groups.sql`、`server/src/relay_groups.rs` | 团队表沿用其 NFKC name_key、独立 membership revision、CAS 全量替换风格；**两者不合并** |
| 审计 | `audit_events`，账户/实例范围 | `server/src/audit.rs`、`0011`/`0016`/`0018` | 新事件类型；不写秘密 |
| 安全头 | 严格 CSP、`Referrer-Policy: no-referrer`、`X-Frame-Options: DENY`、API `no-store`；CORS 仅精确 public origin | `server/src/lib.rs:2321-2380` | 访客页沿用；新增 COOP 与 guest 自定义头 |
| PG 路线 | exact-route allowlist；新路由默认在 PG 模式关闭 | `server/src/lib.rs:1571` | 新功能 SQLite 先行，PG 需单独 repository 与 allowlist 项（见 ROLLOUT） |
| 客户端模型 | `HostRecord` 内嵌 `HostLogin`（密码/私钥/口令随 Host 加密）；`HostProtocol` ssh/rdp/vnc；`rdpCertificateSha256` | `apps/client/lib/domain/models.dart:28,163,254` | 胶囊字段直接取自 Host 记录与 KnownHost |
| Workspace（旧） | 加密记录 v1（tabs）/v2（双分屏）/v3（嵌套二叉分屏，≤8 叶，2500–7500 bp，仅 SSH Host 引用，每叶显式 Connect） | `apps/client/lib/domain/workspace_layout.dart`；总纲 §7.1 | 原样保留，不扩展、不迁移覆盖 |
| **窗口组合（现行基线）** | `WindowCombination` v1：pane 种类 `ssh/sftp/scp/rdp/vnc/console`；`remote_path`（sftp/scp，绝对路径 ≤2048 B）；`serial_port` + `baud_rate`（console，300–4 000 000）；分屏树深度 ≤16、`ratio` 0.15–0.85；树外 pane = 独立标签；活动 pane 必须在树内；≤32 面板/组合、≤32 组合、整列表 ≤30 000 B；存于单条加密 Preference（scope `workspace`、key `windowCombinations`、platform `all`）；恢复先整体校验再逐个打开并在每个异步边界检查作用域租约 | `apps/client/lib/domain/window_combination.dart`、`ui/window_combinations.dart`、`domain/vault_preference.dart:339,449`、`app_controller.dart:6107-6160`、`ui/app_shell.dart:647` | 云端设计以此为准（§10） |
| 未知记录/键 | 旧客户端对 `FormatException`/未知类型或未知 Preference 键计为不可用、不暴露 revision 供编辑 | `apps/client/lib/app_controller.dart:5700-5712`、`domain/vault_preference.dart:566-570` | 附加键 `windowCombinationPlacements` 对旧客户端安全降级（需集成验证） |
| RDP 显示设置 | Host 级 `RdpResolutionMode { fitWindow, fixed }` + width/height，随 Host 加密 | `apps/client/lib/desktop/rdp_settings.dart:14,83,195` | 组合只引用 Host；分辨率在打开时取当前 Host 设置；网关分享尺寸受策略上限约束（§7.4） |
| 主题 | `AppColors.accent = #315BC5`（已为蓝色），`lime/teal` 为兼容别名 | `apps/client/lib/ui/app_theme.dart:3-19` | 提议更深的品牌蓝 token（§11.3），由 Codex 落地 |
| Web URL | 未设置 URL strategy（Flutter Web 默认 hash 策略） | `apps/client/lib/main.dart` | fragment 必须在 Flutter 启动前由自托管 bootstrap JS 取出并清除（§6.2） |

**缺口**：无组织/团队、无 Vault admin、无记录级共享、无匿名/临时访问、无「可连接但不可见凭据」模型（总纲 NG11）、窗口组合无多窗口几何、无跨 Vault 引用、整列表单记录导致并发保存冲突需手工解决。

---

## 2. 架构与信任边界

### 2.1 组件

```text
 创建者客户端(已解锁 Vault) ──HTTPS(Bearer)──► API 服务 ──► SQLite/PG(控制面元数据 + 不透明密文)
        │  sealed capsule (X25519 网关公钥)              │
        │                                                ▼
        │                                  Share Gateway 模块(持网关私钥, 仅内存解封)
        │                                                │ guacd 协议(私有网络)
 访客浏览器 ──HTTPS(cookie)/WSS(/gateway/v1/connect)──►  guacd ──TCP(固定 IP)──► 目标 SSH/RDP/VNC
```

- P1：Share Gateway 为 API 进程内模块；网关私钥来自独立文件 `ATERMIUS_SHARE_GATEWAY_KEY_FILE`（0600，**不在数据目录、不进实例备份**）。
- P2（面向公网实例开放链接前强烈建议完成）：独立 `atermius-gateway` 进程/容器，无数据库凭据，通过 Unix socket 仅接收「胶囊 + 固定 IP/端口 + 权限参数」，返回流；API 进程永不持有网关私钥。

### 2.2 服务端能/不能解密什么

| 数据 | 存放 | 服务端/DB 泄露 | 运行中的服务端运营者 | 访客 |
| --- | --- | --- | --- | --- |
| Vault 记录（Host、凭据、窗口组合、Workspace） | 加密记录 | 不可解密 | 不可解密 | 不可见 |
| 组织/团队名称、成员、角色、Vault 授权 | 明文元数据 | 可见 | 可见 | 不可见 |
| Host 访问授权 / 链接元数据（时间、次数、slug、权限位、目标 IP:端口） | 明文元数据 | 可见 | 可见 | 自己链接的有效期/权限 |
| 链接展示信封（标题、备注、Host 显示名） | 由 fragment 派生密钥加密 | 不可解密 | 不可解密（除非篡改 Web 代码，见 §2.5） | 可见 |
| 网关胶囊（目标、用户名、密码/私钥、主机密钥/证书指纹） | `crypto_box_seal` 给网关公钥，持久存储直至撤销/过期删除 | **仅 DB/备份泄露不可解密**（前提：网关私钥文件未一并泄露） | **可解密，且不限于会话期间**：私钥可重复使用，持有私钥文件 + DB 者可随时解封任何未删除胶囊；「仅会话期解封」只是代码策略 | 不通过分享 API/渲染流获得（但见 §2.5 目标侧风险） |
| 链接 secret / redeem token / cookie / 连接票据 | 仅 SHA-256 | 不可还原 | 只能在请求经过时截获 | 自己持有 |
| 网关会话内容（终端字符/画面/键鼠/剪贴板） | 不持久化；P1 禁止录制 | — | 可见（与现有 Web RDP 同） | 可见 |
| 成员直连 SSH（Web dartssh2 + Relay） | E2E | 不可见 | 不可见（仅目标地址与流量） | — |

UI 文案（创建链接/仅连接授权时强制展示）：「访客通过本服务器的网关连接。为此，该 Host 的登录凭据会加密交给服务器网关保管直到链接撤销或过期；服务器运营者（或入侵服务器者）可以解开它并看到会话内容。访客不会通过分享功能拿到密码或私钥，但在远程会话里仍能执行该账户允许的任何操作。请使用专用的低权限账户。」

### 2.3 访客能力的三种实现比较

| 方案 | 访客如何获得能力 | 服务端知识 | 访客能否导出凭据 | 创建者需在线 | 协议 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| A 浏览器本地解密 | fragment 派生密钥解开 E2E 胶囊，浏览器运行 dartssh2 经 Relay | SSH：零；Web RDP 仍经 guacd，服务端可见 | **能**（devtools/内存） | 否 | SSH（RDP 不能真正 E2E） | 仅 P3，且只允许短期/一次性凭据 |
| **B 隔离网关会话（选定）** | 胶囊封给网关公钥；网关解封并终止协议 | 持网关私钥者随时可解封胶囊并见会话内容；仅 DB/备份泄露不可见 | 不经分享 API 获得；会话内可读目标侧秘密/留后门（§2.5） | 否 | SSH/RDP/VNC（复用 guacd） | **P1/P2 实现** |
| C 主持端代理（现有终端协作） | 创建者设备持连接，访客收 E2E 帧/租约输入 | 零 | 不能 | **是** | 仅终端 | 作为“实时协助”入口保留；访客无注册设备需另设 fragment 派生帧密钥（P3） |

选 B 的理由：满足「点击分享链接不会把永久密码/私钥静默导出给访客」「创建者离线也可用」「RDP/VNC 同一路径」，并最大化复用已验收管线。代价如实写入 §2.2：B 依赖对服务器网关的信任。降低暴露的手段（不改变信任性质）：胶囊在链接/授权全部撤销或过期后立即硬删除；P2 网关独立进程使 API 进程与 DB 不持有私钥；网关私钥定期轮换并使旧胶囊失效；推荐分享专用账户或短期凭据。

### 2.4 主机身份校验（网关不得成为 MITM）

- SSH：分享前 Host 必须有当前 KnownHost（创建者已 TOFU/确认）；胶囊携带 OpenSSH `known_hosts` 行，作为 guacd `host-key` 参数。无 KnownHost 的 SSH Host 不可分享（`HOST_KEY_REQUIRED`）。
- RDP：必须有 `rdpCertificateSha256`（或 P2 起支持 CA 链 + 证书主机名校验）；映射到 guacd `cert-fingerprints`，`ignore-cert` 恒为 false（与 `desktop.rs` 现状一致）。
- VNC：传统 VNC 无传输加密；允许分享但 UI 标红「链路不加密」，实例策略可禁用（默认禁用 VNC 访客分享）。

### 2.5 不在保护范围内

- 恶意 Web 分发者/被入侵服务器可替换前端，从而读取展示信封或诱导用户泄露数据（总纲 NG12 / §8.1）。
- 已获得 Vault 密钥的成员被移除后仍可用曾见过的凭据直连目标；服务端只能阻止其经本服务的未来访问。必须提示在目标轮换凭据。
- 访客在会话内对目标主机执行的操作（例如读取目标上的配置/密钥文件、自行添加 SSH 公钥、创建账户、在 RDP 中保存凭据）不受链接撤销影响；有交互 shell 或桌面的访客可以在目标侧取得该账户可读的任何秘密。因此产品文案只承诺「分享功能本身不向访客下发登录凭据」，不承诺「访客无法获得任何凭据」。推荐分享专用低权限账户，UI 给出提示。
- 网关模式不是零知识：网关私钥持有者（运营者、入侵者、或拿到私钥文件的备份介质）可解封所有未删除胶囊。

---

## 3. 领域模型

```text
Organization 1─* OrganizationMember(user, role: owner|admin|member)
Organization 1─* Team 1─* TeamMember(user ∈ org members)
Organization 1─* Vault(org_id 可空：个人 Vault 不属于组织)
Vault 1─* VaultPrincipalGrant(principal: user|team, role: admin|editor|viewer)   ← 期望状态
Vault 1─* VaultMember(user, role, state: invited|active|suspended|revoked, source)  ← 已落成 manifest 的实际状态
Vault 1─* HostGatewayCapsule(host_record_id, host_revision_id, gateway_key_id)    ← 每 Host 至多 1 个当前胶囊
Vault 1─* HostAccessGrant(host_record_id, principal: user|team, capability: gateway_connect, 权限位)
Vault 1─* ShareLink 1─* ShareLinkTarget(host_record_id → capsule)
ShareLink 1─* GuestSession 1─* GatewayConnection
ShareGatewayKey(key_id, x25519 pk, 实例密钥签名, active|retiring|retired)
```

- `host_record_id` 是 Vault 内不透明 UUID；服务端只校验 `(vault_id, record_id)` 在 `record_heads` 中存在且未删除，不知道它是不是 Host（胶囊签名头声明 `record_kind=host`，网关解封后核对）。
- `VaultMember.source`：`direct`（现有邀请）/`grant`（由团队或用户授权落成）。授权被删除且无其他来源时，服务端**立即**置 `suspended`（拒绝服务方向，服务端可单方面执行），随后由持钥客户端签发移除 manifest 并轮换 epoch。

---

## 4. 权限矩阵

角色定义：组织 **O-Owner / O-Admin / O-Member**（P2）；Vault **V-Owner / V-Admin（P3 新增，MVP 不存在）/ Editor / Viewer**；**Gateway 授权者**（非 Vault 成员，只有 `gateway_connect`）；**Guest**（链接访客）；**实例管理员**。

| 操作 | V-Owner | V-Admin | Editor | Viewer | Gateway 授权者 | Guest | O-Owner/O-Admin（非 Vault 成员） | 实例管理员 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 列出 Vault 内 Host（解密） | ✓ | ✓ | ✓ | ✓ | ✗（只见授权时的展示信封） | ✗（只见链接展示信封） | ✗ | ✗ |
| 查看 Host 密码/私钥 | ✓ | ✓ | ✓ | ✓¹ | ✗ | ✗ | ✗ | ✗ |
| 直连（E2E/本地） | ✓ | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ |
| 经网关连接 | ✓² | ✓² | ✓² | ✓² | ✓ | ✓（链接目标内） | ✗ | ✗ |
| 编辑 Host | ✓ | ✓ | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 授予用户/团队 Vault 角色（期望状态） | ✓ | ✓（≤editor） | ✗ | ✗ | ✗ | ✗ | ✓（组织 Vault；≤editor，不分发密钥） | ✗ |
| 分发密钥 / 签 manifest | ✓ | ✓³ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 授予 Host gateway_connect | ✓ | ✓ | 策略⁴ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 封装/更新网关胶囊 | ✓ | ✓ | 策略⁴ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 创建临时链接 | ✓ | ✓ | 策略⁴ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 撤销链接 | ✓（全部） | ✓（全部） | 自己创建的 | ✗ | ✗ | 仅退出自己的会话 | ✓（组织 Vault 全部） | 紧急全局禁用 |
| 终止访客会话 | ✓ | ✓ | 自己链接的 | ✗ | ✗ | 自己 | ✓（组织 Vault） | ✓（实例级） |
| 轮换 epoch / 转移所有权 / 删除 Vault | ✓ | 轮换 ✓³；其余 ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| 剪贴板 / 文件 | 本地自主 | 本地自主 | 本地自主 | 本地自主 | 授权位 | 链接位（默认关） | — | — |
| 查看链接活动审计 | ✓ | ✓ | 自己链接的 | ✗ | ✗ | ✗ | ✓（组织 Vault） | 实例审计 |

1. 总纲 §9.6：持钥 Viewer 必然可读凭据；「可用不可见」只能用 Gateway 授权（替代 NG11 的网关方案）。
2. 成员也可走网关（例如在不能运行 SSH 的设备上），同样受实例共享策略约束。
3. V-Admin 签 manifest 需客户端验证器支持 `admin` 签名者（`membership_roles_v2` 设备能力，P3，见 ROLLOUT）；之前仅 Owner 可签（现状 `control.rs:1090`）。
4. 组织策略 `editors_may_share`（P2 起），默认 false；个人 Vault 无组织策略时 Editor 不可分享。
5. **MVP（P1）实际生效子集**：只有 V-Owner 可创建/撤销链接与胶囊（Gateway 授权在 P2 才出现）；V-Admin 列与组织列在对应阶段前不存在，服务端拒绝 `admin` 角色值。

**不变式（服务端在同一事务内校验）**

- 授予者只能授予 ≤ 自己的能力；链接/授权能力 ⊆ 创建者当前能力；链接与 Gateway 授权**永不**含 edit/share/查看凭据；Guest 与 Gateway 授权者不能再分享（无转授链）。
- 链接的有效性在每次兑换、签票、连接、复查时**重新计算**创建者当前权限；创建者失权 → 链接 `suspended`（`CREATOR_LOST_ACCESS`），可由当前 V-Owner（例如所有权转移后的新 Owner）或 P3 的 V-Admin「接管」（更新 `owner_user_id` 并重封胶囊）。P1 中创建者即 V-Owner，失权只发生在账户停用或所有权转移时。
- 团队授权要求 `team.org_id = vault.org_id`（复合外键）；用户授权给组织 Vault 时被授权者必须是该组织 active 成员。个人 Vault 只能授权给用户。

---

## 5. 产品流程

### 5.1 组织、邀请与加入

1. 任何 active 账户可创建组织（实例策略 `org_creation: any|instance_admin`，默认 instance_admin）。
2. O-Owner/O-Admin `POST /orgs/{org_id}/invitations`：可指定 `intended_username`（可选）、角色（member/admin）、初始团队、有效期（≤14 天，默认 7 天）。返回一次性 `token`（32 B，仅返回一次，服务端存 SHA-256）。链接形如 `/join#o1.<token>`（同样放 fragment）。
3. 若实例注册关闭且受邀者无账户：邀请同时签发一条 `account_invitations`（复用现有表，`organization_invitations.account_invitation_id` 关联），注册完成后在同一流程中接受组织邀请。
4. `POST /org-invitations/accept`（Bearer + body token）：原子消费（`consumed_at IS NULL AND revoked_at IS NULL AND expires_at>now`），写成员、团队成员，推进 `membership_revision`。
5. 加入组织**不**自动获得任何 Vault 密钥；团队授权的 Vault 显示「等待密钥分发」。

### 5.2 把 Host 分享给用户/团队

1. Host 菜单「共享…」→ 对话框「成员与团队」页签：
   - Host 已在共享 Vault：直接编辑该 Vault 的授权（用户/团队 × 角色），或为 Host 添加 Gateway 授权。
   - Host 在个人 Vault：提示「共享以 Vault 为单位」，提供「移动到共享 Vault」或「复制到共享 Vault」（总纲 §7.3：读取→目标库重新加密创建→确认同步→按选择删除源记录）。**跳板链**（`jumpHostId`）必须一起复制或阻止（引用限同一 Vault）。
2. `PUT /vaults/{vault_id}/grants/{principal_type}/{principal_id}` 写期望状态（CAS `expected_revision`）。
3. 密钥分发（P2；**必须由持钥 V-Owner 在 UI 横幅「3 名成员等待密钥」中逐人确认指纹后执行，不自动执行**——否则只持有组织管理权的人可间接让 Owner 客户端把 Vault 密钥封给任意用户）：
   - `GET /vaults/{vault_id}/key-distribution` 返回 `pending_additions`（user、active device、封装公钥、指纹、来源授权）与 `pending_removals`、`rotation_required`。
   - （P2 仅 V-Owner；P3 起 V-Admin）客户端对新增设备 `crypto_box_seal` 当前 epoch 密钥、签发 `membership_version+1` manifest（新成员标「未验证」直至指纹核对，沿用 §9.7），`POST /vaults/{vault_id}/membership/apply`（`expected_membership_version` + `grants_revision` 双 CAS）。
   - 有 `pending_removals` 时走现有 `POST /vaults/{vault_id}/keys/rotate`（新 epoch、剩余成员 envelopes、manifest 移除）。
4. 成员新增设备：沿用现有设备登记后由用户已有设备补 envelope 的路径；`key-distribution` 也列出「成员新设备缺 envelope」。

### 5.3 Gateway 授权（内部「可用但不下发凭据」，P2）

1. 创建者为 Host 生成/刷新网关胶囊（§7.1），`PUT .../hosts/{host_id}/gateway-capsule`。
2. `PUT .../hosts/{host_id}/access-grants/{principal_type}/{principal_id}`，权限位同链接（§7.4）。首版（P2）显示名使用创建者显式填写的明文 `label`（UI 提示「服务器可见」）；P3 改为对被授权用户各 active 设备 `crypto_box_seal` 的展示信封。
3. 被授权者在主页「共享给我」列表中看到条目，点击 → `POST .../hosts/{host_id}/gateway-tickets` → WS。

### 5.4 创建临时链接

1. Host 菜单「共享…」→「临时链接」页签（可多选 Host，≤8 个目标；P1 仅 V-Owner 可见此页签）。
2. 表单：生效时间（默认立即）、过期时间（默认 24 h，上限实例策略默认 30 天）、可选周期窗口（§8.3）、最多兑换次数（默认 1，可空=不限，≤1000）、最多连接次数（可空）、并发上限（默认 1）、单次会话上限（默认 2 h）、剪贴板（两向各一开关，默认关）、只读观看（默认关）、slug（随机或自定义）。文件传输与录制 P1 显示为不可用（锁定关）。
3. 客户端：生成 `link_secret`（32 B CSPRNG）→ 派生 `redeem_token` 与 `display_key`（§6.1）→ 确保每个目标 Host 有当前胶囊（无则先 PUT）→ 用 `display_key` 加密展示信封 → `POST /vaults/{vault_id}/share-links`。请求携带 `redeem_token`（不是 `link_secret`），服务端计算并只存其 SHA-256，token 本身不落库、不进日志；`link_secret` 与 `display_key` 从不离开创建者客户端。
4. 响应返回 `link_id`、slug、URL 前缀；客户端拼接 `#s1.<secret>` 后显示「复制链接」，并提示：**链接即访问权**、仅通过可信渠道发送。secret 只存在于创建者内存与剪贴板；之后无法再次查看（丢失只能「轮换 secret」生成新链接）。

### 5.5 访客兑换与连接

1. 访客打开 `/s/<slug>#s1.<secret>`。服务端对任意 `/s/*` 返回同一 SPA（不区分 slug 是否存在，防枚举）。
2. 自托管 `share-bootstrap.js`（Flutter 启动前执行）：读取 `location.hash` → 立即 `history.replaceState(null, '', '/s/<slug>')` 清除 fragment → 保存到模块级变量供 Dart 一次性读取后清零。
3. 落地页（兑换前不显示任何链接信息，降低预览/旁观者获取元数据）：「你收到一个 Atermius 临时访问链接」+「继续」按钮。**只有用户点击后**才 `POST /api/v1/guest/redeem`。
4. 服务端原子兑换（§9）→ 创建 `guest_sessions`、设置 cookie → 返回 `link_id`、`display_envelope`、目标列表（target_id/protocol）、有效期、权限位、限制。客户端用 `display_key` 解密标题/Host 显示名；`display_key` 存 `sessionStorage`（仅当前标签页，用于刷新后重新显示；不是访问凭据）。
5. 访客点击某目标 →`POST /api/v1/guest/connections`（cookie + Origin + `X-Atermius-Guest: v1`）→ 30 s 单次票据 → `wss://<origin>/gateway/v1/connect` 首帧认证 → 网关解封胶囊、构造 guacd `connect` → 双向转发（§12.2）。
6. 刷新页面：cookie 仍有效则 `GET /guest/session` 恢复，不再消耗兑换次数。

### 5.6 撤销、成员变动

| 事件 | 立即（同事务） | 活动连接 | 后续 |
| --- | --- | --- | --- |
| 撤销链接 | `state=revoked`、`authz_revision++`、删除未消费票据、撤销所有 guest_sessions | ≤2 s 关闭（进程内广播通常 <100 ms），关闭码 4403 | 胶囊无其他引用→硬删除 |
| 收窄链接（缩短时间、关剪贴板、降并发） | `authz_revision++` | 关闭，访客可按新权限重连 | — |
| 放宽链接 | revision++ 但 `authz_revision` 不变 | 不影响 | 新连接生效 |
| 轮换 secret | `secret_version++`、新 hash；默认撤销旧版本 guest_sessions | 默认关闭 | 新 URL |
| 创建者失去 Vault share 权限/被移出组织/账户停用 | 其链接 `suspended(CREATOR_LOST_ACCESS)` | 关闭 | 他人可接管 |
| 团队成员被移除 | 由该团队派生且无其他来源的 `vault_members` → `suspended`；该用户 Gateway 授权失效；`vaults.rotation_required_at` 置位 | 该用户的 Gateway 连接、同步 WS 关闭；E2E Relay 连接因 Relay 不感知 Vault，不受影响（如实说明） | 持钥客户端轮换 epoch；UI 列出「其可见过凭据的 Host」建议在目标轮换 |
| Host 被删除（tombstone） | 引用它的链接目标/授权 `suspended(HOST_DELETED)` | 关闭 | 恢复 Host 不自动恢复链接 |
| Host 新 revision（编辑） | 胶囊 `stale`；默认（`suspend_on_host_change=true`）相关链接目标暂停新连接 | 现有连接继续（不改变已协商的会话） | 有权客户端同步后自动重封胶囊并恢复 |
| Vault 进入 deleting | 全部链接/授权 suspended | 关闭 | — |
| 网关密钥 retired/泄露 | 相关胶囊 stale → 链接 suspended | 泄露时立即关闭 | 客户端用新公钥重封 |
| 实例共享策略关闭/收窄 | 全局 `share_policy.revision++` | 不再满足者关闭 | — |

---

## 6. Token、链接与 cookie

### 6.1 格式与派生

```text
link_secret   = 32 bytes CSPRNG
fragment      = "s1." || base64url_nopad(link_secret)
redeem_token  = HKDF-SHA256(ikm=link_secret, salt="", info=JCS(["atermius","share-link-redeem",1]), L=32)
display_key   = HKDF-SHA256(ikm=link_secret, salt=link_id, info=JCS(["atermius","share-link-display",1,link_id,secret_version]), L=32)
server stores = hex(SHA-256(base64url_nopad(redeem_token)))     // 与现有 token_hash 惯例一致
```

- `redeem_token` 与 `display_key` 用途分离；服务端从未见过 `link_secret` 与 `display_key`。P3 E2E 模式再派生 `capsule_key`，格式向前兼容。
- 展示信封：XChaCha20-Poly1305，AAD = JCS(`{format:"atermius-share-display-v1", link_id, vault_id, secret_version}`)，明文 `{title, note, targets:[{target_id,label}]}`，≤8 KiB。
- 兑换比较：先按 slug 取行，再常量时间比较 hash；未知 slug、错误 secret、已撤销统一 `404 SHARE_LINK_UNAVAILABLE`。secret 验证通过后才区分 `SHARE_LINK_NOT_YET_VALID`（附 `valid_from`）、`SHARE_LINK_EXPIRED`、`SHARE_LINK_EXHAUSTED`、`SHARE_LINK_OUTSIDE_SCHEDULE`（附下个窗口）。
- 其他 token：组织邀请 token、guest cookie、连接票据都是 32 B CSPRNG，只存 SHA-256；连接票据 30 s、单次。

### 6.2 避免泄露

- secret 只在 fragment：不进入请求行、`Referer`（Fetch 规范剥离 fragment；另有 `Referrer-Policy: no-referrer`）、代理/访问日志或分析（项目本无第三方统计）。
- bootstrap 在 Flutter 路由初始化、应用 API 请求及任何第三方脚本运行之前清除 fragment（加载 HTML/同源 bootstrap 的初始请求本身不会携带 fragment）（Flutter 默认 hash 路由会把 `#s1...` 当路由，必须先清除）。脚本为自托管同源文件以满足 `script-src 'self'`。
- 服务端日志：`/s/<slug>` 路径可记录（slug 非秘密），请求 body 永不记录；`redeem_token`、cookie、ticket 在 tracing span 中禁止出现（随分享功能验证日志脱敏，见 G9）。
- 访客页响应头追加：`Cross-Origin-Opener-Policy: same-origin`、`Cache-Control: no-store`；不设 `Permissions-Policy` 放宽。
- 已知残余：fragment 仍会留在发送渠道（邮件、聊天记录）与收件端浏览器历史以外的副本中——UI 文案明确。

### 6.3 Cookie、CSRF、Origin

- `Set-Cookie: __Host-atermius-guest=<32B b64url>; Secure; HttpOnly; SameSite=Strict; Path=/; Max-Age=<≤ 会话剩余秒数>`。`__Host-` 前缀保证无 Domain、Path=/、Secure。
- 一个浏览器同时只持有一个访客会话；兑换新链接时替换 cookie 并撤销旧会话（P1 简化）。
- 所有 guest 写接口：`Origin` 必须精确等于 `ATERMIUS_PUBLIC_ORIGIN`（或 P3 的独立 `ATERMIUS_SHARE_ORIGIN`），必须带 `X-Atermius-Guest: v1` 与 `Content-Type: application/json`（触发预检，CORS 只放行精确 origin）。
- Guest cookie **不能**访问任何 Bearer API；Bearer 也不能访问 guest API（中间件按路由前缀分离）。
- WS：`Origin` 精确匹配 + cookie 对应的 guest_session 必须等于票据绑定的 guest_session + 首帧票据。

### 6.4 重放与扫描器

- 兑换是 POST 且需用户点击；GET `/s/*` 不改变状态。普通链接预览（只做 GET、不带 fragment、不执行 JS）因此无法兑换。
- **残余风险**：部分邮件/聊天安全扫描器会收到完整 URL（含 fragment），在无头浏览器中执行 JS 甚至点击按钮。它们可以兑换链接、消耗 `max_redemptions`，并在扫描器自己的浏览器里得到 guest cookie。不能宣称扫描器普遍无法兑换。
- 缓解（P1）：兑换只建立会话、**不自动连接**，连接还需第二次点击，扫描器即使兑换也极少真正开启目标会话；创建者「活动」视图显示每次兑换的时间、IP 段、UA 族，可一键终止会话并「轮换 secret」重新发放；默认 `max_redemptions=1` 时被扫描器消耗会表现为访客看到 `SHARE_LINK_EXHAUSTED`，UI 提示「请联系分享者重新发送」；文案建议通过不做链接改写的渠道发送敏感链接。
- 可选加强（P2 设置，敏感分享推荐）：
  - **兑换需批准**：兑换后会话处于 `pending_approval`，创建者在客户端（推送/页面）批准后才能签发连接票据；
  - **一次性验证码**：创建者另行口头/另一渠道告知 6 位码（服务端存 Argon2id 哈希，5 次失败锁定该会话，不锁定链接）；
  - **账户绑定**：链接只允许指定实例账户兑换（访客须登录），此时退化为 Gateway 授权。
- 重放 redeem_token：受 `max_redemptions` 约束；`max_redemptions=null` 的链接重放会创建新会话（这是链接语义），受并发上限与速率限制约束。
- cookie 被窃取 = 会话被窃取：以短有效期、空闲超时、并发上限、创建者可见活动列表与一键终止限制影响。MH：可选 WebCrypto 不可导出密钥绑定（DPoP 风格）会话。

### 6.5 自定义 slug 与自定义域名

| | 自定义 slug | 自定义域名 |
| --- | --- | --- |
| 是什么 | 路径地址 `/s/<slug>`，不含任何授权能力 | 访客入口所在的源（`https://share.example.com`） |
| 谁设置 | 链接创建者 | 实例运维（部署配置 `ATERMIUS_SHARE_ORIGIN` + 反向代理 TLS） |
| 校验 | `^[a-z0-9](?:[a-z0-9-]{1,46}[a-z0-9])$`，NFKC+小写；保留词（`api`、`admin`、`login`、`s`、`join`…）；实例内唯一 | Origin/CORS/CSP/cookie 作用域随之改变；必须是独立源，不能是用户可控子域 |
| 生命周期 | 链接删除后 slug 进入 `share_slug_reservations` 冷却 7 天（防旧链接地址立刻指向新分享） | 变更是部署事件；旧链接失效需公告 |
| 风险 | 可猜测、可描述性信息泄露（slug 对服务端日志与旁观者可见）→ 提示不要放敏感词 | 独立源可将 guest cookie 与主应用存储隔离（P3 推荐） |

P1 不提供每链接自定义域名。

---

## 7. 网关胶囊与会话

### 7.1 胶囊格式 `atermius-gateway-capsule-v1`

外层（明文、签名，服务端校验并存储）：

```json
{
  "format": "atermius-gateway-capsule-v1",
  "vault_id": "<uuid>", "host_record_id": "<uuid>", "host_revision_id": "<uuid>",
  "membership_version": "12", "gateway_key_id": "<uuid>",
  "protocol": "ssh|rdp|vnc", "target_host": "db1.internal.example", "target_port": 22,
  "sealed_sha256": "<b64url>", "sealer_user_id": "<uuid>", "sealer_device_id": "<uuid>",
  "created_at": "2026-11-07T12:00:00Z",
  "signature": "<Ed25519 over JCS(all fields except signature)>"
}
```

内层（`crypto_box_seal(gateway_pk, UTF8(JCS(inner)))`，≤ 300 KiB）：

```json
{
  "format": "atermius-gateway-capsule-inner-v1",
  "vault_id": "...", "host_record_id": "...", "host_revision_id": "...", "gateway_key_id": "...",
  "record_kind": "host", "protocol": "ssh", "target_host": "...", "target_port": 22,
  "username": "deploy",
  "auth": {"kind": "password", "password": "..."} | {"kind": "private_key", "private_key": "<OpenSSH>", "passphrase": "..."},
  "ssh_known_host": "<known_hosts line>",
  "rdp": {"certificate_sha256": "<64 hex>", "domain": null},
  "display": {"mode": "fit_window", "width": null, "height": null}
}
```

- 服务端写入时：签名者设备 active、属于签名用户、用户当前为 V-Owner（P2 起含策略允许的 Editor，P3 起含 V-Admin），`membership_version` 为当前值，`(vault_id, host_record_id)` 头存在且 `host_revision_id` 等于当前 head，`gateway_key_id` active，目标通过 §7.3 检查。
- 网关解封后：内层所有绑定字段必须等于外层与数据库行；不符→ `CAPSULE_MISMATCH` 并标记胶囊 `revoked`、审计。这阻止服务端/攻击者在 Host/Vault 之间调换胶囊。
- 实现策略：胶囊明文只在网关内存、只在 guacd `connect` 指令构造期间存在，随后 `zeroize`（与现有 `DesktopHello` Drop 一致）；不缓存解封结果。这是降低暴露的工程约束，**不是**密码学保证（§2.2）。
- 胶囊还携带 Host 当前显示设置 `display: {mode: fit_window|fixed, width?, height?}`（取自 `RdpSettings`），网关按 §7.4 策略夹紧。
- 不支持（P1 拒绝）：跳板链 Host、端口转发、代理、agent 转发、Host 级启动脚本。

### 7.2 网关密钥

- 首次启动生成 X25519 密钥对，私钥写 `ATERMIUS_SHARE_GATEWAY_KEY_FILE`；公钥 + `key_id` 由**实例 Ed25519 密钥**签名后写 `share_gateway_keys`。客户端从 `GET /share-gateway/keys` 取，验证实例签名（实例公钥已 TOFU 固定，§9.7），再封装。
- 轮换：新密钥 active，旧密钥 `retiring`（默认 14 天）；`key-distribution` 类似的 `GET /vaults/{id}/gateway-capsules?needs_reseal=true` 让有权客户端后台重封；到期 `retired` → 剩余胶囊 stale。泄露：立即 retired，相关连接关闭。
- 备份：网关私钥不进入 `backup.rs` 归档；恢复后胶囊无法解封 → 全部 stale，客户端重封。这是刻意设计（DB/备份泄露 ≠ 凭据泄露）。

### 7.3 端点限制（SSRF / 开放代理）

1. 目标只来自胶囊外层，由创建者客户端提交；访客与 Gateway 授权者请求中**没有**任何目标字段。
2. 创建胶囊、创建链接、签发每张连接票据时：按现有 `normalize_dns_hostname`/`parse_ip_literal` 规范化 → DNS 解析（≤32 答案、2 s 超时，复用 `resolve_dns_target`）→ 每个候选地址都过 `is_forbidden_ip`（loopback、link-local、未指定、组播、广播、169.254.169.254、fd00:ec2::254、100.100.100.200、IPv4-mapped）→ 过有效策略：`deployment ∩ instance relay ∩ 创建者账户/组 relay ∩ instance share policy`（共享策略默认端口 {22,3389}，VNC 5900 默认关）。
3. 选一个允许的 IP 写入连接票据（服务端 AEAD 加密，同 `relay_tickets` 的 `rtd1:` 目标加密），guacd `hostname` 参数用该 IP 字面量——guacd 不再解析 DNS。SSH 主机密钥/RDP 证书指纹校验保证 IP 变化不会连到冒充者。
4. 额外禁止：Atermius 自身监听地址、数据库/guacd/对象存储地址（部署配置 `ATERMIUS_SHARE_DENY_CIDRS` 默认包含 compose 内网段）。
5. guacd 容器网络出站按部署限制（现有文档要求），防 RDP 重定向 PDU 把 guacd 引到其他地址。
6. 拨号速率、并发、时长见 §7.5。

### 7.4 权限位到 guacd 参数的映射

| 链接/授权位 | 默认 | guacd 参数 | 服务端过滤（纵深防御） |
| --- | --- | --- | --- |
| `clipboard_to_remote` | false | `disable-paste = !value` | 为 false 时丢弃访客 `clipboard`/对应 `blob`/`end` 指令 |
| `clipboard_from_remote` | false | `disable-copy = !value` | 为 false 时丢弃发往访客的 `clipboard` 流 |
| `view_only` | false | `read-only = true` | 丢弃 `key`/`mouse`/`clipboard` |
| 文件传输 | 锁定 false（P1） | `enable-sftp=false`、`enable-drive=false`、`sftp-disable-*` 不设 | 输入白名单本就无 `file`/`pipe`/`put`（`desktop.rs:100`） |
| 打印、音频输入、音频输出 | false | `enable-printing=false`、`enable-audio-input=false`、`disable-audio=true` | — |
| 录制 | 锁定 false（P1） | 不设置 `recording-path` | 运行时断言 |
| SSH 主机密钥 | 必需 | `host-key=<known_hosts line>` | 无则拒绝 |
| RDP 证书 | 必需 | `cert-fingerprints`、`ignore-cert=false` | 与现有一致 |

参数名依据 Apache Guacamole 手册（Configuring Guacamole：SSH `host-key`/`private-key`/`passphrase`/`enable-sftp`；通用 `disable-copy`/`disable-paste`、`recording-path`；RDP `enable-drive`/`enable-printing`/`enable-audio-input`/`disable-audio`/`cert-fingerprints`）。实现时需对固定版本 guacd 1.6.0 的 `args` 应答逐项确认，缺少某参数时 **fail closed**（与现有 `cert-fingerprints` 检查一致）。

活动会话中关闭剪贴板：属于收窄 → 断开（guacd 参数在 connect 时固定），服务端过滤器在断开前立即生效。

**显示尺寸（RDP/VNC/SSH 终端画面）**：Host 设置 `fit_window` → 使用访客 `open`/`size` 指令的视口尺寸；`fixed` → 使用 Host 的固定宽高。两者都夹紧到实例策略 `max_display_width × max_display_height`（默认 1920×1200，硬上限沿用 `desktop.rs` 的 4096×4096、下限 320×200），并限制 `size` 指令频率（≤4 次/秒，合并抖动）。访客不能请求超出策略的尺寸；超出时按比例缩小而非拒绝连接。

### 7.5 资源预算（默认值即首个对外版本的生效值；实例可在上限内调整；MH 只做校准）

| 项 | 默认 | 上限 |
| --- | --- | --- |
| 链接有效期 | 24 h | 实例 `max_link_lifetime` 默认 30 天，硬上限 90 天 |
| guest 会话寿命 / 空闲 | 2 h / 15 min | 12 h / 60 min |
| 单连接寿命 | min(会话剩余, 2 h) | 现有 `MAX_RELAY_DURATION` 1 h 对 Relay；网关单独 12 h |
| 每链接并发连接 | 1 | 10 |
| 每 guest 会话并发 | 2 | 4 |
| 实例访客并发总数 | 32 | 配置 |
| 兑换速率 | 10/min/IP，60/h/IP；全实例 600/min | — |
| 兑换失败 | 5/min/IP，失败计入审计；**不按 slug 锁定**（避免知道 slug 者 DoS 链接） | — |
| 连接票据 | 30 s、单次；每 guest 会话 20/min | — |
| 流量 | 每连接 1 GiB（同 `MAX_RELAY_BYTES`） | — |
| 链接数 | 每 Vault 200 active，每用户 500 | — |

---

## 8. 时间、计划与过期

### 8.1 时间语义

- 所有时刻 UTC RFC 3339、整秒；服务端以**数据库/服务端时钟**判定，客户端时钟只用于显示。
- `valid_from ≤ now < expires_at`（半开区间）。`expires_at - created_at ≤ max_link_lifetime`；`valid_from` 不得早于创建时间 1 分钟以上、不得晚于 1 年。
- 会话/连接的截止 = min(链接 expires_at, 当前计划窗口结束, 会话寿命, 连接寿命)。到期前 5 分钟发 `SESSION_EXPIRING` 控制帧；到点关闭（4408）。
- 次数：`max_redemptions`（成功兑换次数）与可选 `max_connections`（成功签发且被消费的连接票据次数）。`connections` 在票据签发时计数，票据过期未消费也**不退还**（简单，且无法靠反复签票刷新额度）；UI 文案称「连接尝试次数」。

### 8.2 状态

存储 `state ∈ {active, paused, revoked, suspended}`；对外 `status` 计算：`revoked` > `suspended(reason)` > `paused` > `expired` > `exhausted` > `not_yet_valid` > `outside_schedule` > `active`。过期链接保留 30 天供审计后硬删（维护任务，复用 maintenance 调度）。

### 8.3 周期计划（可选扩展，P2）

```json
{"timezone": "Asia/Shanghai",
 "windows": [{"days": ["mon","tue","wed","thu","fri"], "start": "09:00", "end": "18:00"}]}
```

- `timezone` 必须是 IANA 区域名（含 `UTC` 与 `Etc/*`）；拒绝 `UTC+8`、`CST` 等偏移/缩写。服务端使用固定版本 tz 数据库（如 `chrono-tz`），响应回显 `tzdata_version`。
- 窗口按**当地墙钟**定义，`end` 可小于 `start` 表示跨午夜（属于 start 所在日）；最多 14 个窗口，每窗口 ≥15 min。
- DST：不存在的本地时刻（春季跳变）→ 取跳变后的第一个有效时刻；重复的本地时刻（秋季回拨）→ `start` 取较早一次、`end` 取较晚一次（窗口不会因回拨缩短）。
- 计划只收窄 `valid_from/expires_at`，不延长。窗口结束：活动连接收到 5 分钟预警后关闭（4409），会话 cookie 保留，下一个窗口可重新连接。
- UI 用创建者时区展示，同时显示访客本地时间与 UTC。

---

## 9. 并发与竞态

| 竞态 | 处理 |
| --- | --- |
| 并发兑换 vs `max_redemptions` | SQLite：单写事务 `UPDATE share_links SET redemptions=redemptions+1 WHERE slug=? AND state='active' AND redeem_token_hash=? AND valid_from<=? AND expires_at>? AND (max_redemptions IS NULL OR redemptions<max_redemptions) RETURNING ...`，同事务插入 guest_session；PG：同一条件 UPDATE（行锁）。影响 0 行→再读取以区分错误码。 |
| 兑换 vs 撤销 | 同一行写锁串行；撤销事务删除未消费票据并撤销会话；兑换若在撤销后提交必然看到 `state=revoked`。 |
| 签票 vs 撤销 vs 消费 | 票据绑定 `authz_revision`、`guest_session_id`、`secret_version`；消费时在事务内重新检查全部条件（与 `consume_ticket` 一致）。 |
| 并发上限 | 连接开始时在事务内 `COUNT(gateway_connections WHERE link_id=? AND ended_epoch IS NULL AND heartbeat_epoch>now-60)`；多节点 PG 用 `SELECT ... FOR UPDATE` 锁 link 行后计数；连接结束/心跳超时（60 s 无心跳视为结束）释放。 |
| 胶囊重封 vs Host 编辑 | `PUT gateway-capsule` 带 `expected_capsule_revision` 与 `host_revision_id`；host head 已前进→ `409 HOST_REVISION_CHANGED`，客户端拉取后重封。 |
| 授权变更 vs 密钥分发 | `membership/apply` 带 `expected_membership_version` 与 `expected_grants_revision`；任一不符→ `409`，客户端重新读取 key-distribution。 |
| 团队成员替换并发 | 团队成员 CAS 全量替换（`expected_membership_revision`），同 relay groups。 |
| 链接 PATCH 并发 | `expected_revision` CAS；收窄字段变化同时 `authz_revision++`。 |
| 创建者失权 vs 正在创建链接 | 创建事务内重新校验创建者角色与 Vault 状态。 |
| slug 唯一 | `UNIQUE(slug)` + 冷却表；冲突→ `409 SLUG_TAKEN`（不透露属于谁）。 |
| 多节点撤销传播 | PG `LISTEN/NOTIFY share_authz` 唤醒 + ≤2 s 轮询兜底；SQLite 单进程用 `tokio::sync::broadcast`。 |
| 时钟边界 | 所有时间判定使用单一 `now`（事务开始时取 DB 时间）；不在事务中途重取。 |
| 幂等 | 创建链接/胶囊/授权请求携带客户端 UUID（`link_id`/`capsule_id`），同 ID + 同摘要重放返回原结果，不同摘要→ `409 IDEMPOTENCY_KEY_REUSED`。 |

---

## 10. 已保存窗口组合（WindowCombination）

### 10.1 现行基线（客户端已实现，云端设计不改写）

- 存储：每个 Vault 一条加密 Preference 记录，`scope="workspace"`、`key="windowCombinations"`、`platform_family="all"`，`value` 为 `WindowCombination.encode(list)` 的 JSON 文本（`domain/vault_preference.dart:339`、`app_controller.dart:6127`）。服务端只见普通加密记录。
- 配方 v1 字段：`{version:1, id, name, panes[], tree, active}`；pane `{kind, host, remote_path, serial_port, baud_rate}`：
  - `kind ∈ {ssh, sftp, scp, rdp, vnc, console}`；`console` 无 `host`，可带 `serial_port` + `baud_rate`（300–4 000 000）；
  - `remote_path` 仅 sftp/scp，绝对路径 ≤2048 B；
  - `tree` 为二叉分屏（`axis`、`ratio` 0.15–0.85、`first/second`），叶为 `{pane: index}`，深度 ≤16；不在树中的 pane 是**独立标签**；`active` 必须在树内；
  - 每组合 ≤32 pane，每 Vault ≤32 组合，整列表 ≤30 000 B UTF-8。
- 引用：`host` 是**当前作用域（当前 Vault）**内的 Host ID，打开时解析；Host 的协议、端口、RDP 分辨率（`RdpResolutionMode.fitWindow|fixed`）、证书指纹与凭据全部取自打开时的当前 Host 记录，配方不复制这些设置。
- 恢复：`CombinationRestoreCoordinator` 先整体校验所有 pane 可解析，再逐个打开，每个异步边界检查作用域租约（切换 Vault/锁定即停止）。

### 10.2 一键打开语义（D7a）

- 主页组合卡片的**主操作 = 打开并连接**整个组合。这次点击即用户授权；SSH 主机密钥、RDP 证书确认、缺少 NLA 凭据等身份提示仍按 pane 顺序逐个出现，任何一个被拒绝只让该 pane 失败，其余继续。
- 可选次要操作「预览」：只还原布局、不连接，每个 pane 显示「连接」。
- **永不**自动连接的情形：应用启动、Vault 解锁、同步拉取到新组合、通知/推送、深链接打开主页、MCP/外部调用未经用户确认。
- 平台差异：Windows/Linux 桌面全部可用；Android 不支持 `console`（本机 shell/串口）→ 该 pane 计入失败并提示；当前组合恢复入口在 Web 不支持 `console`、`sftp` 与 `scp`→ 同上；串口名是设备相关的（`COM3` vs `/dev/ttyUSB0`），他端找不到时该 pane 失败、提示「在本设备重新选择串口并另存」。
- WorkspaceRecord v1–v3 保留其「每叶显式 Connect」旧语义，不受此变化影响。

### 10.3 云端同步与授权

- 无服务端新表、无新路由：沿用记录 CAS、冲突、历史、对象无关。
- 授权 = Vault 角色：Owner/Editor 可保存/删除组合；Viewer 可打开（连接仍需 Viewer 可读的 Host 凭据，符合 §9.6）；Gateway 授权者与访客**看不到也不能使用**组合（无 Vault 密钥）。
- 共享 Vault 中的组合对所有成员可见；保存前 UI 提示「此组合将同步给该 Vault 的全部成员」。
- 串口名、远程路径虽在密文内，但会同步给共享 Vault 其他成员——保存到共享 Vault 时提示。
- **并发保存**：整列表是一条记录，两台设备同时保存会产生记录冲突，当前实现报「窗口组合存在同步冲突，请先解决冲突」。提议的客户端三方合并（无协议变化）：按组合 `id` 合并——仅一侧新增/删除/修改的组合直接采用；两侧都修改同一 `id` → 保留一侧并把另一侧另存为新 `id`、名称加「（冲突副本）」；合并结果超过 32 个或 30 000 B → 不自动合并，保留冲突分支让用户选择。合并后的写入以当前 head 为 base 提交新 revision。
- **跨 Vault 引用**：v1 不支持（引用只在当前 Vault 解析）。如未来需要个人组合引用团队 Host，提案 pane 增加可选 `vault` 字段，规则：只有个人 Vault（唯一成员为自己）中的组合可引用其他 Vault；共享 Vault 中的组合只能引用同 Vault；解析只在本地已解密的目标 Vault 中进行；无权/已删除 → 该 pane 失败，不按名称匹配。这需要配方 `version:2`（见 §10.5 迁移规则）。

### 10.4 多窗口几何（提案，未实现）

窗口自身几何 API 由 RDP 会话负责的客户端工作提供；本节只定义同步格式，**不改变** v1 配方：

- 附加 Preference 键 `windowCombinationPlacements`（同一 Vault、`scope="workspace"`、`platform_family="all"`），值为：

```json
{"version": 1, "placements": [{
  "combination_id": "<v1 id>",
  "windows": [{
    "window_id": "<uuid>",
    "pane_indexes": [2, 3],
    "display": {"role": "primary|secondary", "ordinal": 0},
    "rect_bp": {"x": 0, "y": 0, "w": 6000, "h": 10000},
    "state": "normal|maximized|fullscreen"
  }]
}]}
```

  - `pane_indexes` 指向 v1 配方中**独立标签**（不在主窗口 `tree` 内）的 pane，表示这些标签在独立窗口中打开；未列出的 pane 留在主窗口。每个独立窗口内多个 pane 为标签；P1 不在独立窗口内保存分屏树（若需要，作为 v2 配方的一部分）。
  - 最多 6 个独立窗口/组合；`rect_bp` 为相对显示器**工作区**的 basis points（0–10000，`w,h ≥ 1500`）；`display.ordinal` 为非主显示器按左→右、上→下的序号。
  - 组合被删除或 pane 下标失效 → 该放置条目忽略并在下次保存时清理；放置记录永不影响配方本身能否打开。
- 不同步：像素坐标、DPI、显示器名称/序列号、窗口句柄（总纲 §7.4）。设备本地表 `combination_window_placements(combination_id, window_id, display_fingerprint, x, y, w, h, scale, state, updated_at)` 保存精确几何；恢复顺序：本地指纹匹配 → 同步的 `role/ordinal` → 主显示器；夹紧使窗口 ≥50% 可见、标题栏完全可见、不小于平台最小尺寸，重叠时级联 32 px。
- 仅在用户显式「保存/更新组合」时写同步放置；拖动窗口只更新本地表。
- 平台映射：桌面 = 原生独立窗口；Android = 降级为主窗口标签；Web = 主窗口就地打开，其余窗口显示「打开窗口 2/3」按钮，每次点击一次 `window.open`（浏览器要求用户手势，不承诺一次点击打开多个浏览器窗口；但一次点击仍连接主窗口内所有 pane）。
- 旧客户端：未知 Preference 键在 `VaultPreferenceRecord.fromJson` 抛 `FormatException` → 计为不可用、不覆盖（需集成测试确认）；它们继续按 v1 配方把所有 pane 打开在主窗口。

### 10.5 版本演进规则（若将来需要配方 v2）

- **不得削减**：v2 必须至少支持 v1 的全部 pane 种类、`remote_path`、`serial_port/baud_rate`、≤32 pane、深度 ≤16、比例 0.15–0.85、独立标签与活动 pane 语义。
- **显式、非破坏迁移**：v2 客户端读取 v1；只有用户在 UI 中保存了需要 v2 特性的组合时，才把**该 Vault** 的列表写成 v2，且仅当该 Vault 所有 active 设备的能力报告声明 `window_combination_v2`（复用 `PUT /devices/capabilities` 机制）；否则拒绝保存该特性并说明原因。写 v2 前保留原 v1 revision（记录历史可恢复）。
- `WorkspaceRecord` v1–v3 → 窗口组合：仅提供用户触发的「转换为窗口组合」（SSH 叶 → `kind:"ssh"`，比例 `bp/10000`；2500–7500 bp 落在 0.15–0.85 内，深度 ≤7 ≤16，无信息损失），原 Workspace 记录不删除。

---

## 11. Web/客户端 UX

### 11.1 页面与对话框（无第二条 topbar）

- **Host 菜单 → 「共享…」**：一个紧凑对话框（桌面 560 px 宽；移动端底部表单），两段式分段控件：
  - 「成员与团队」：搜索框（与现有 Host 搜索相同样式）选择用户/团队，角色下拉；列出当前授权与「等待密钥」徽标；Gateway 授权开关「仅可连接（不可见凭据，经服务器网关）」。
  - 「临时链接」：列表（状态点、slug、过期倒计时、兑换次数 x/y、活动会话数）+「新建链接」。新建为同一对话框内的第二屏：时间（快捷 1 h / 24 h / 7 天 / 自定义）、次数、剪贴板两开关、只读、slug、可展开「周期窗口」。底部固定信任提示（§2.2 文案）。
  - 创建成功屏：大号「复制链接」按钮、「仅显示一次」说明、二维码（可选，P2）。
- **Settings → 共享**：所有我创建/可管理的链接与 Gateway 授权（按 Vault 过滤），批量撤销。
- **Settings → 组织**：成员、团队、邀请（三标签）；与现有 Settings 分栏一致。
- **主页**：「共享给我」区块（Gateway 授权条目）与窗口组合卡片行（主操作「打开」= 打开并连接，次要「…」菜单含预览/重命名/删除，§10.2）；不新增 topbar。
- **访客页**：极简单栏：标题、有效期、Host 卡片列表（协议图标 + 显示名 + 「连接」）、权限说明（剪贴板/只读）、「退出」。连接后复用现有桌面渲染器标签页，工具收进圆角「…」菜单（与 `docs/REMOTE-DESKTOP.md` 现状一致）。SSH 访客画面由 guacd 的终端仿真渲染为图像流（不是本地 xterm），字体/主题由网关参数决定；这是网关模式的已知体验差异。

### 11.2 平台约定

- Apple HIG 精神：清晰层级、内容优先、圆角分组列表、分段控件、破坏性操作红色且二次确认（撤销链接、移除成员）。
- Windows：对话框按钮顺序「主要操作在左」与 Fluent 一致（`确定/取消`）；窗口 chrome 保持现有自定义标题栏。
- Android：Material 3 底部表单与 FAB 位置；不启用动态取色覆盖品牌蓝（可选设置）。
- Web：键盘可达（Tab 顺序、Esc 关闭）、`prefers-reduced-motion`、复制按钮使用 Clipboard API 需用户手势。

### 11.3 深蓝强调色 token（建议，Codex 落地）

| Token | 值 | 用途 | 对比度 |
| --- | --- | --- | --- |
| `accent` | `#1F4FB8` | 主按钮、选中态填充 | 白字 7.32:1 |
| `accentPressed` | `#1D46A8` | 按下 | 白字 8.42:1 |
| `accentText`（深色背景上的文字/图标） | `#8DAEF4` | 链接、选中文字 | 对 `#0A0F15` 8.69:1 |
| `accentContainer` | `#1B2F5C` | 选中行背景 | 配 `#D8E4FF` 文本 |
| 浅色主题 `accent` | `#1F4FB8` | 同上 | 对白底 7.32:1、对 `#F5F7FA` 6.82:1 |

- 当前 `#315BC5`（白字 6.12:1）已是蓝色，调整为更深的 `#1F4FB8` 以符合「深蓝」并提升对比度；`lime/teal` 别名应逐步移除，排查残留绿色强调（终端 ANSI 绿色、成功语义色保留，不属于强调色）。

---

## 12. API 与 WS 合同（摘要；完整见 `API.yaml`）

### 12.1 HTTP 分组

| 分组 | 路由 | 认证 |
| --- | --- | --- |
| 组织 | `GET/POST /orgs`；`GET/PATCH /orgs/{org_id}`；`GET /orgs/{org_id}/members`；`PUT/DELETE /orgs/{org_id}/members/{user_id}`；`GET/POST /orgs/{org_id}/invitations`；`POST /orgs/{org_id}/invitations/{invitation_id}/revoke`；`POST /org-invitations/inspect`；`POST /org-invitations/accept` | Bearer（inspect 无认证，token 在 body） |
| 团队 | `GET/POST /orgs/{org_id}/teams`；`GET/PATCH/DELETE /orgs/{org_id}/teams/{team_id}`；`PUT /orgs/{org_id}/teams/{team_id}/members` | Bearer |
| Vault 授权 | `PUT /vaults/{vault_id}/organization`；`GET /vaults/{vault_id}/grants`；`PUT/DELETE /vaults/{vault_id}/grants/{principal_type}/{principal_id}`；`GET /vaults/{vault_id}/key-distribution`；`POST /vaults/{vault_id}/membership/apply` | Bearer |
| 网关 | `GET /share-gateway/keys`；`GET /vaults/{vault_id}/gateway-capsules`；`GET/PUT/DELETE /vaults/{vault_id}/hosts/{host_id}/gateway-capsule`；`GET /vaults/{vault_id}/hosts/{host_id}/access-grants`；`PUT/DELETE /vaults/{vault_id}/hosts/{host_id}/access-grants/{principal_type}/{principal_id}`；`GET /shared-with-me`；`POST /vaults/{vault_id}/hosts/{host_id}/gateway-tickets` | Bearer（keys 无认证） |
| 链接管理 | `GET /share-links`；`GET/POST /vaults/{vault_id}/share-links`；`GET/PATCH /vaults/{vault_id}/share-links/{link_id}`；`POST .../{link_id}/revoke`；`POST .../{link_id}/rotate-secret`；`POST .../{link_id}/adopt`；`GET .../{link_id}/activity`；`POST .../{link_id}/guest-sessions/{guest_session_id}/terminate`；`GET /share-slugs/{slug}/availability` | Bearer |
| 访客 | `POST /guest/redeem`；`GET /guest/session`；`POST /guest/logout`；`POST /guest/connections` | cookie + Origin + `X-Atermius-Guest: v1`（redeem 无 cookie） |
| 实例策略 | `GET/PUT /admin/share-policy` | 实例管理员 allowlist |
| 能力公告 | `GET /instance` 增加 `capabilities.organizations`、`capabilities.share_links`、`capabilities.gateway`（仅当 guacd + public origin + 网关密钥均就绪） | 公开 |

各路由所属阶段见 `API.yaml` 的 `x-phase`（P2 另有 `.../guest-sessions/{id}/approval`）。所有 Vault 子资源：未知/无权 Vault、Host、link ID 统一 `404`（同 `require_vault`）。路径参数与 body 中的 `vault_id`/`host_id` 不一致→ `400`。

### 12.2 WS `/gateway/v1/connect`

1. Upgrade：`Origin` 精确匹配（浏览器必有；原生客户端仅限 Bearer 票据类型，与 `connect_desktop` 规则一致）；guest 票据要求 cookie。`max_message_size 96 KiB`。
2. 10 s 内首个文本帧：`{"type":"authenticate","ticket":"<ticket>"}`；服务端原子消费并复查全部条件。
3. 服务端回 `{"type":"authenticated","connection_id":"<uuid>","expires_at":"...","idle_timeout_seconds":900,"permissions":{"clipboard_to_remote":false,"clipboard_from_remote":false,"view_only":false}}`。
4. 客户端发 `{"type":"open","width":1280,"height":800}`（只含视口尺寸；无协议、目标、凭据字段，`deny_unknown_fields`；网关按 Host 显示设置与策略上限夹紧，§7.4）。网关构造 guacd 握手（SSH 新增 `private-key`/`passphrase`/`host-key`/`disable-copy`/`disable-paste`/`read-only`）。
5. 数据帧：Guacamole 指令文本（首字节为数字）；控制帧：JSON 对象（首字节 `{`）。客户端→服务端指令经 `valid_input` 白名单 + 权限过滤；服务端→客户端过滤 clipboard 流。
6. 服务端控制帧：`{"type":"notice","code":"SESSION_EXPIRING","at":"..."}`、`{"type":"closing","code":"LINK_REVOKED"}`。
7. 关闭码：`4400` 协议违规、`4401` 认证失败/票据无效、`4403` 撤销/失权、`4408` 过期/空闲、`4409` 计划窗口结束、`4429` 预算/并发、`4502` 目标/guacd 失败（无细节）。
8. 授权复查：每 ≤2 s 一次 + 广播唤醒；条件见 §5.6；任一失败→关闭并审计 `end_reason`。

### 12.3 错误码（新增）

`SHARE_LINK_UNAVAILABLE`(404)、`SHARE_LINK_NOT_YET_VALID`(403)、`SHARE_LINK_EXPIRED`(410)、`SHARE_LINK_EXHAUSTED`(410)、`SHARE_LINK_OUTSIDE_SCHEDULE`(403)、`SHARE_LINK_SUSPENDED`(403, details.reason)、`GUEST_SESSION_REQUIRED`(401)、`GUEST_ORIGIN_DENIED`(403)、`SHARE_CONCURRENCY_LIMIT`(429)、`SLUG_TAKEN`(409)、`SLUG_INVALID`(422)、`HOST_KEY_REQUIRED`(422)、`HOST_SHARE_UNSUPPORTED`(422, details.reason: jump_host|port_forward|protocol)、`HOST_REVISION_CHANGED`(409)、`CAPSULE_STALE`(409)、`GATEWAY_KEY_RETIRED`(409)、`GATEWAY_DISABLED`(503)、`SHARE_PERMISSION_EXCEEDS_GRANTOR`(403)、`ORG_ROLE_REQUIRED`(403)、`KEY_DISTRIBUTION_CONFLICT`(409)、`MEMBERSHIP_ROLES_V2_REQUIRED`(426)、`SHARE_APPROVAL_PENDING`(403, P2)、`SHARE_VERIFICATION_REQUIRED`(401, P2)。

---

## 13. 数据模型与迁移（摘要；DDL 见 `schema.sql`）

- SQLite 迁移 `0053_organizations.sql` … `0058_share_policy.sql`；PG 对应 `0040+`。全部为**新增表/新增可空列**，不改写已有行语义。
- `vaults.org_id`（可空 FK）、`vaults.grants_revision`、`vaults.rotation_required_at`、`vaults.rotation_reason`。
- `vault_members`：新增 `source`（默认 `direct`）、`suspended_at`、`suspend_reason`；`role` 允许 `admin`；`state` 允许 `suspended`。SQLite `0001_initial.sql` 与 PG `postgres/0001_sync_commit_core.sql` 中 role/state 均为无 CHECK 的 TEXT，只需改应用层校验；PG `postgres/0011_vault_invitations.sql` 的 `invitations.role CHECK (role IN ('editor','viewer'))` 仅在开放 admin 邀请时替换。
- 复合外键防跨租户替换：`share_link_targets(vault_id, host_record_id)` → `record_heads(vault_id, record_id)`；`host_gateway_capsules(vault_id, host_record_id)` 同；`team_members(org_id, team_id)` → `teams(org_id, team_id)`，`team_members(org_id, user_id)` → `organization_members(org_id, user_id)`；`vault_principal_grants(org_id, team_id)` → `teams`。
- 窗口组合（含提案的 `windowCombinationPlacements`）：**无服务端 schema**。

---

## 14. 审计

| 事件 | 字段（只含元数据） |
| --- | --- |
| `org.created/updated/member_role_changed/member_removed` | org_id、actor、target user_id、role |
| `org.invitation_created/accepted/revoked/expired` | invitation_id、org_id、actor、role |
| `team.created/renamed/deleted/members_replaced` | team_id、org_id、成员数、revision |
| `vault.grant_set/removed`、`vault.member_suspended`、`vault.key_distribution_applied` | vault_id、principal、role、membership_version |
| `host.capsule_set/stale/revoked`、`host.access_grant_set/removed` | vault_id、host_record_id、capsule_id、gateway_key_id、protocol、目标 IP:端口（与 Relay 相同保留策略） |
| `share_link.created/updated/secret_rotated/revoked/suspended/adopted` | link_id、vault_id、actor、变更字段名（不含值中的秘密）、authz_revision |
| `share_link.redeemed/redeem_denied` | link_id（仅 secret 校验通过后记录）、guest_session_id、结果码、IP（按实例审计 IP 策略截断/哈希）、UA 族 |
| `gateway.connection_started/ended` | connection_id、principal（guest_session/user）、target_id、固定 IP:端口、时长、字节数、end_reason |

禁止写入：link_secret、redeem_token、cookie、ticket、胶囊（内外层签名可记录 sealed_sha256）、用户名/密码/私钥、展示信封明文、guacd 参数、终端/画面/剪贴板内容。未知 slug 的失败只计入速率计数器，不写逐条审计（防日志放大）。

---

## 15. 范围限制

- 不实现：记录级密钥、组织恢复密钥、SSO/SCIM（总纲 P3）、每链接自定义域名、访客文件传输与录制（P1）、跳板链/端口转发 Host 的网关分享、多节点网关房间迁移、访客 E2E 模式（P3）、窗口组合跨 Vault 引用（需配方 v2）。
- 窗口组合云端部分仅为同步/授权/几何提案；客户端配方本身由 Codex/客户端工作拥有。
- 团队名、成员关系、Vault 授权、链接时间/次数/目标 IP 对服务端可见。
- 网关模式不是零知识；不得在产品文案中把临时链接描述为端到端加密。
- 撤销不能收回访客/成员已经看到的内容，也不能撤销其在目标主机上已做的变更。

---

## 16. 实施阶段与核心安全门槛（内联）

| 阶段 | 内容 |
| --- | --- |
| P0 | 网关密钥与签名、guacd SSH handshake 参数（缺参数 fail closed）、实例共享策略（默认关）、guest/Bearer 路由隔离中间件、日志脱敏 |
| P1 | V-Owner 的 Host 胶囊 + 临时链接（连续有效期、次数、并发、slug、剪贴板/只读）、访客兑换/会话/连接、撤销/轮换/终止/活动；SSH + RDP |
| P1-C | 窗口组合云端（纯客户端）：按 id 合并、一键打开并连接的验收、`windowCombinationPlacements` |
| P2 | 组织/团队/邀请、Vault 期望授权 + V-Owner 确认的密钥分发、Gateway 授权、审批/验证码/周期计划、接管、网关独立进程 |
| P3 | Vault admin + manifest 签名者 v2、独立 share origin、访客 E2E（短期凭据）、组合 v2/跨 Vault、PG 多节点 |
| MH | 阈值校准、模糊测试、外部评审、DPoP 式会话绑定 |

**核心安全门槛**（与功能同时交付，任一缺失即不得开放对应路由，含原型；详细用例见 `ACCEPTANCE-TESTS.md` §1 G1–G16）：

1. 每个读/写/签票/WS 消费/周期复查都在事务内做对象级授权，外部 ID 统一 404，复合外键防跨租户替换。
2. 分享能力 ⊆ 创建者当前能力；链接/授权永不含 edit/share/查看凭据；无转授。
3. guest 路由：精确 Origin + `X-Atermius-Guest` + JSON；`__Host-` HttpOnly Secure SameSite=Strict cookie；Bearer 与 cookie 互不通用；WS Origin + cookie + 单次票据。
4. 原子次数与并发计数；基线速率/并发/寿命上限（§7.5 默认值即上线值，MH 只做校准）。
5. 所有 token/cookie/ticket 只存 SHA-256；秘密、胶囊、凭据、展示信封明文不进日志/审计/响应。
6. 目标只来自签名胶囊，按策略交集与禁止地址检查，每次连接重新解析并按 IP 固定；guest 输入不能改变目标或 guacd 参数。
7. 剪贴板/文件/录制默认关闭并在服务端双重执行；收窄立即断开。
8. 撤销、失权、成员变动 ≤2 s 关闭活动连接（广播唤醒 + 轮询兜底）。


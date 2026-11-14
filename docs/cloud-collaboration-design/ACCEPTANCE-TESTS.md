# 验收测试与滥用用例（提案）

测试层级：**R** = Rust 单元/仓库测试（真实 SQLite）；**H** = `integration/` Python 黑盒 HTTP/WS（临时账户与数据库，同 `integration/test_relay.py`、`test_desktop.py` 风格，受控 guacd 协议端点）；**W** = Chromium Web 验收；**PG** = 两节点 PostgreSQL（仅在 PG 支持阶段）。

## 1. 核心安全门槛（随功能交付的放行条件，不属于 MH）

任何分享/访客/网关路由对外开放前，以下负向测试必须全部存在并通过。

| # | 门槛 | 测试 | 层级 |
| --- | --- | --- | --- |
| G1 | 对象授权：外部 Vault/Host/link/target/guest_session ID 一律 404，与不存在不可区分 | 用户 A 用自己的 token 访问用户 B 的 `vault_id`、在自己 Vault 路径中放 B 的 `host_id`/`link_id`/`target_id`、guest cookie 访问另一链接的 `target_id` → 404，且响应体/耗时形状一致 | H |
| G2 | 无跨租户替换 | 创建链接时 `targets[].host_record_id` 属于另一个 Vault → 404；胶囊 header `vault_id`/`host_record_id` 与路径不符 → 400；把 Host X 的有效胶囊字节放到 Host Y 的 PUT → 网关解封后 `CAPSULE_MISMATCH`，连接拒绝且胶囊 revoked；团队授权使用其他组织的 `team_id` → 404 | H/R |
| G3 | 不越权分享 | Editor/Viewer 创建链接、胶囊、授权 → 403（P1）；链接请求含 edit/share/查看凭据类字段 → 422（`deny_unknown_fields`）；Guest/Gateway 授权者调用任何管理路由 → 401/403 | H |
| G4 | 每次连接/WS 复查 | 票据签发后撤销链接 → 消费失败；连接中撤销链接、轮换 secret、收窄权限、暂停、创建者被降为 Viewer、Host tombstone、Vault 删除、策略关闭、网关 key retired → 各自在 ≤3 s 内以规定关闭码关闭（4403/4408/4409） | H |
| G5 | Origin/CSRF | guest 路由：缺失/错误 Origin、缺 `X-Atermius-Guest`、`text/plain` 表单提交、跨站 `fetch` with credentials → 拒绝且不改变状态；WS 错误 Origin → 403；guest cookie 调 Bearer 路由、Bearer 调 guest 路由 → 401 | H/W |
| G6 | Cookie 属性 | `Set-Cookie` 精确含 `__Host-` 前缀、`Secure`、`HttpOnly`、`SameSite=Strict`、`Path=/`、无 `Domain`、`Max-Age` ≤ 会话剩余 | H |
| G7 | 原子次数 | 32 并发兑换 `max_redemptions=1` → 恰好 1 成功；`max_concurrent=1` 下 8 并发连接 → 恰好 1 个建立；`max_connections=N` 精确 | R/H |
| G8 | Token 安全 | DB 中不存在 redeem_token / cookie / ticket / 邀请 token 明文（扫描全部表）；错误 secret 与未知 slug 返回同一 404；token 长度/字符集校验 | R/H |
| G9 | 秘密不入日志/审计 | 以哨兵字符串作为 Host 密码、私钥、口令、redeem_token、cookie、ticket、fragment、展示信封明文跑完整流程；在服务端日志（含 tracing span、错误路径、panic 处理）、审计表、响应头中搜索哨兵 → 0 命中 | H |
| G10 | 目标限制（SSRF） | 胶囊目标为 127.0.0.1、::1、169.254.169.254、fd00:ec2::254、100.100.100.200、::ffff:127.0.0.1、0.0.0.0、组播、guacd/DB 地址、策略外 CIDR/端口 → 拒绝；DNS 名首次解析到允许地址、复查时解析到 loopback（rebinding）→ 拒绝；guacd `connect` 的 hostname 恒为已检查 IP 字面量 | R/H |
| G11 | 访客无法选择目标/参数 | guest `connections` 与 WS `open` 帧中加入 host/port/protocol/username/password/任意 guac `connect` 参数 → 422/4400；WS 发送 `select`、`connect`、`file`、`put`、`pipe`、`argv` 指令 → 4400 | H |
| G12 | 不下发凭据 | 访客全部 HTTP 响应与 WS 服务端→客户端帧中不含哨兵密码/私钥/用户名；SSH 无 KnownHost / RDP 无证书指纹时分享被拒（`HOST_KEY_REQUIRED`） | H |
| G13 | 剪贴板/只读/文件默认 | 默认链接：服务端→访客 `clipboard` 流被过滤、访客→服务端 `clipboard` 被丢弃；guacd 收到 `disable-copy=true`、`disable-paste=true`、`enable-sftp=false`、`enable-drive=false`、无 `recording-path`；`view_only` 时 `key`/`mouse` 被丢弃且 `read-only=true` | H |
| G14 | 速率与并发上限 | 超过兑换速率 → 429 + Retry-After；实例访客并发上限、每会话票据速率生效；超限不消耗次数 | H |
| G15 | 时间边界 | `valid_from` 之前、`expires_at` 当刻（半开区间）、会话寿命/空闲到期 → 正确错误码与关闭；以服务端时钟为准（伪造客户端时间无效） | R/H |
| G16 | 成员变动撤销 | （P2）移除团队成员 → 其派生 Vault 成员 suspended、其 Gateway 连接与同步 WS 关闭、其拥有的链接 suspended 且访客连接关闭、Vault `rotation_required`；组织管理员不能使 Owner 客户端自动分发密钥（key-distribution 需显式确认） | H |

## 2. 功能验收（摘录）

| 场景 | 期望 | 层级 |
| --- | --- | --- |
| 创建 SSH 链接 → 访客打开 URL → 点击继续 → 连接 | 终端可交互；刷新页面不消耗次数；fragment 在 Flutter 路由初始化及首个应用 API 请求前已从地址栏移除（检查 `history` 与发出的请求） | W |
| RDP 链接，Host `fixed 2560×1440`，策略上限 1920×1200 | guacd 收到夹紧后的尺寸；访客视口变化不超上限 | H |
| 自定义 slug 冲突/保留词/冷却期 | 409/422；不泄露占用者 | H |
| 轮换 secret | 旧 URL 404；新 URL 可用；默认旧会话关闭 | H |
| Host 编辑（新 revision） | `suspend_on_host_change` 时新连接 `CAPSULE_STALE`；创建者客户端重封后恢复；现有连接继续 | H |
| 网关重启 / 备份恢复 | 无网关私钥时 `capabilities.gateway` 不公告；恢复后胶囊 stale → 重封恢复 | H |
| 周期计划（P2） | `Asia/Shanghai` 工作日窗口；`America/New_York` DST 跳变/回拨边界按 DESIGN §8.3；窗口结束 5 分钟预警后 4409 | R |
| 窗口组合一键打开 | 主页单击后所有可解析 pane 依次连接；主机密钥/证书提示逐个出现；拒绝一个只影响该 pane；启动/解锁/同步不触发连接；「预览」不连接 | W/桌面 |
| 窗口组合并发保存 | 两设备离线分别新增不同组合 → 合并后两者都在；同 id 两侧修改 → 生成「（冲突副本）」；超过 32 个不自动合并 | Dart 单元 |
| 窗口组合基线保真 | SCP/SFTP `remote_path`、console `serial_port/baud_rate`、深度 16、比例 0.15/0.85 边界、独立标签往返编码不变；旧客户端遇 `windowCombinationPlacements` 不覆盖 | Dart 单元 |
| Workspace v3 → 组合转换 | 比例/树/Host 顺序无损；原 Workspace 记录保留 | Dart 单元 |
| 深蓝主题 | 主按钮白字对比度 ≥7:1；无残留绿色强调（ANSI 与成功语义色除外） | Golden/W |

## 3. 滥用用例

| 攻击 | 预期防御 | 测试 |
| --- | --- | --- |
| 链接预览机器人 GET `/s/<slug>` | 不消耗、不泄露链接信息（所有 `/s/*` 同一 SPA） | H |
| 安全扫描器带 fragment 执行 JS 并点击「继续」 | 可能消耗一次兑换（已知残余风险）；不自动连接；活动视图可见；P2 审批/验证码阻止其获得连接 | W（模拟无头点击）+ H |
| 枚举 slug | 统一 404 + 每 IP 速率限制；不按 slug 锁定 | H |
| 暴力猜 secret | 256-bit；速率限制；失败只计数不逐条审计 | R |
| 偷取 cookie 后在另一浏览器重放 | 会话有效期/空闲/并发限制；创建者可终止；（MH）DPoP 绑定 | H |
| 访客把网关当代理（端口转发、SOCKS、跳板） | 网关无转发通道；跳板/转发 Host 不可分享；guacd SSH 不开启 SFTP/端口转发 | H |
| RDP 重定向 PDU 引导 guacd 连其他主机 | guacd 网络出站限制（部署）+ 证书指纹 | 部署检查 |
| 大量 `size` 指令 / 超大 blob | 频率与尺寸夹紧，`valid_input` 长度上限 | H |
| 被移除成员继续使用已知凭据直连目标 | 服务端无法阻止（如实）；UI 轮换提示出现 | W |
| 恶意组织管理员把自己加入团队以获取 Vault 密钥 | 仅得到「等待密钥」；Owner 必须逐人确认指纹 | H |
| 服务端替换网关公钥 | 客户端校验实例签名（固定实例公钥），不符拒绝封装 | Dart 单元 |
| 访客在会话中读取目标侧秘密/留后门 | 无法由服务端阻止（如实）；文案建议专用低权限账户 | 文案审查 |

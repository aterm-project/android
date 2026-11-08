# 上线、兼容与实施阶段（提案）

本文配合 [`DESIGN.md`](DESIGN.md)。所有阶段均未实现。每个阶段只有在其「核心安全门槛」负向测试（[`ACCEPTANCE-TESTS.md`](ACCEPTANCE-TESTS.md) §1）全部通过后才能对外开放，包括内部原型/演示实例；没有「先暴露原型、后补门槛」的路径。

## 1. 阶段

| 阶段 | 范围 | 前置 | 不包含 |
| --- | --- | --- | --- |
| **P0 基础** | 网关密钥生成/签名/轮换（`share_gateway_keys`、`ATERMIUS_SHARE_GATEWAY_KEY_FILE`，排除备份）；`desktop.rs` handshake 增加 `ssh` 协议与 `host-key`/`private-key`/`passphrase`/`disable-copy`/`disable-paste`/`read-only`，args 缺失即 fail closed；实例共享策略（默认关）；guest 路由中间件（cookie/Origin/自定义头）与 Bearer 路由隔离；日志脱敏 | guacd 1.6.0 部署（`deploy/compose.desktop.yaml`）、`ATERMIUS_PUBLIC_ORIGIN` | 任何对外路由开放 |
| **P1 临时链接 MVP** | V-Owner 创建 Host 胶囊与临时链接（连续有效期、兑换/连接次数、并发、随机/自定义 slug、剪贴板两向开关、只读）；访客兑换/会话/连接；撤销、轮换 secret、终止会话、活动视图；SSH（需 KnownHost）与 RDP（需证书指纹） | P0 + 核心门槛测试 | 组织/团队、Gateway 授权、周期计划、VNC（默认禁用）、文件传输、录制、跳板链 Host |
| **P1-C 窗口组合云端**（与 P1 并行，纯客户端） | 基于现行 `WindowCombination` v1：按 `id` 三方合并、共享 Vault 保存提示、主页一键打开并连接（客户端已实现语义的验收）；`windowCombinationPlacements` 附加键（几何 API 由 RDP 工作提供） | 无服务端改动 | 配方 v2、跨 Vault 引用 |
| **P2 团队** | 组织/成员/邀请（复用 `account_invitations`）、团队、Vault 期望授权、`key-distribution` + `membership/apply`（**仅 V-Owner，逐人确认指纹**）、成员移除即暂停 + rotation_required；Host Gateway 授权（用户/团队）；`editors_may_share`；链接兑换审批 / 一次性验证码 / 周期计划；接管（adopt）；**网关独立进程**（API 进程与 DB 不持网关私钥） | P1 稳定 | Vault admin |
| **P3 扩展** | Vault `admin` 角色与 manifest 签名者 v2（`membership_roles_v2` 设备能力）；独立 share origin；访客 E2E 模式（仅短期凭据）；窗口组合配方 v2/跨 Vault；PG 多节点网关连接计数与 LISTEN/NOTIFY | P2 | — |
| **MH**（上线前） | 阈值校准、模糊测试（guac 指令过滤、胶囊解析、schedule 解析）、外部评审、DPoP 式会话绑定、日志/审计保留策略复核 | — | — |

建议 P1 内顺序：P0 → 胶囊 PUT/GET（含签名与目标策略）→ 链接 CRUD/撤销 → guest redeem/session → `/gateway/v1/connect`（含复查与关闭码）→ 活动/终止 → Web UI。每步都带对应负向测试。

## 2. 功能开关与能力公告

| 开关 | 默认 | 效果 |
| --- | --- | --- |
| `instance_share_policy.links_enabled` | false | 关闭时链接管理与 guest 路由返回 `503 GATEWAY_DISABLED`（guest 路由返回同一 404 以免探测） |
| `instance_share_policy.gateway_grants_enabled` | false | P2 Gateway 授权 |
| `ATERMIUS_SHARE_GATEWAY_KEY_FILE` | 未设置 | 未设置则 `capabilities.gateway` 不出现，所有网关功能关闭 |
| `ATERMIUS_ORGANIZATIONS_ENABLED` | false | P2 组织路由 |

`GET /instance` 仅在 guacd 可用、public origin 已配置、网关密钥已加载、策略开启时公告 `capabilities.share_links` / `capabilities.gateway`；旧客户端忽略未知能力。

## 3. 向后兼容

- **数据库**：只新增表与可空/有默认值的列（`schema.sql`）。旧二进制回滚后忽略新表；`vault_members.source` 默认 `direct`。回滚前必须先关闭开关，确保没有 `suspended` 成员或 `admin` 角色（旧代码会把 `suspended` 当作非 active → 拒绝访问，属于安全方向；`admin` 在 P3 前不存在）。
- **成员清单**：P1/P2 不改变 manifest 格式与签名者规则（仍仅 Owner 签）；团队来源的成员在 manifest 中与直接成员完全相同。P3 引入 admin 签名者前，用设备能力报告门控：该 Vault 所有 active 设备声明 `membership_roles_v2` 才允许授予 admin（否则 `426 MEMBERSHIP_ROLES_V2_REQUIRED`）。
- **现有邀请**：设备定向 Vault 邀请流程不变；团队授权是附加路径。
- **Relay / Web RDP**：`/relay/v1/connect`、`/desktop/v1/connect` 行为不变；网关使用新 WS 路径 `/gateway/v1/connect`，并加入 `spa_fallback` 的非 SPA 前缀与 PG allowlist（仅在 PG repository 实现后）。
- **PG 模式**：新路由默认不在 `pg_sync_route_is_supported` allowlist → 404/关闭；PG 支持必须单独实现 `Pg*Repository`、迁移 `postgres/0040+`，并通过两节点验收后才加入 allowlist。
- **备份/恢复**：新表随实例备份；网关私钥不随备份 → 恢复后所有胶囊 stale、链接 suspended(`capsule_stale`)，客户端重封后恢复。恢复演练需覆盖。
- **窗口组合**：`WindowCombination` v1 保持不变；附加键 `windowCombinationPlacements` 对旧客户端为未知 Preference 键（不可用、不覆盖）。`WorkspaceRecord` v1–v3 不变；只提供用户触发的单向「转换为窗口组合」，不删除原记录。配方 v2 的显式迁移规则见 DESIGN §10.5。
- **主题**：深蓝 token 变更只影响 `AppColors`；兼容别名 `lime/teal` 在一个版本内保留后移除。

## 4. 运维与回滚

- 紧急停用：`PUT /admin/share-policy {links_enabled:false}` → 推进策略 revision → 所有访客连接 ≤2 s 关闭；不删除数据。
- 网关私钥泄露：轮换 → 旧 key `retired(compromise)` → 相关连接立即关闭、胶囊 stale；公告运营者可能已读取的 Host 列表（`host_gateway_capsules` 元数据），提示在目标轮换凭据。
- 监控（不含秘密）：活动访客连接数、兑换成功/失败率、按关闭码的结束计数、胶囊 stale 数、复查超时次数。

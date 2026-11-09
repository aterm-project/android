# 外部 AI 的 MCP 接入

在桌面或 Android 客户端解锁工作区，打开 **设置 → AI / MCP**，选择端口后启用，再复制连接配置到外部 AI 的 MCP 配置中。在“机器访问权限”中设置默认权限，以及每台机器的“禁止访问 / 只读 / 读写”覆盖项。新工作区默认只读；读写权限允许连接、输入、执行命令和写文件。默认禁止、单台读写可建立允许列表。权限收紧立即生效并取消受影响的在途调用；提升权限须成功保存。启用与停止服务独立于机器权限；停止会撤销令牌。

服务仅监听 `http://127.0.0.1:8765/mcp`（端口可改）。每次启用生成独立随机 Bearer 令牌，不写入磁盘。配置含令牌，只交给信任的客户端。锁定、退出或切换工作区会撤销授权；重新启用后需要更新 AI 端配置。多窗口应使用不同端口。停止 MCP 不关闭已打开的会话，也不能撤销已经发生的远程操作；等待用户确认的连接可能仍由应用完成。

Windows、Linux、macOS 和 Android 支持监听；Web、iOS 不监听端口。Android 使用带“停止 MCP”按钮的前台通知；电脑端通过 ADB 转发同一端口连接，见 [Android 连通与后台运行](MCP-ANDROID.md)。服务与当前已解锁的本地 Profile 或云端 Vault 绑定，不把密钥交给服务器，不包含内置模型聊天。

| 工具 | 用途 | 需要操作权限 |
| --- | --- | --- |
| `workspace_status` | 工作区状态 | 否 |
| `hosts_list` / `sessions_list` | 分页列出主机 / 会话 | 否 |
| `host_connect` / `console_open` | 连接已保存的主机 / 打开 Console | 是 |
| `session_focus` / `session_close` | 切换 / 关闭标签 | 是 |
| `terminal_read` | 读取保留的终端文本 | 否 |
| `terminal_write` | 向交互终端输入文本（换行可能执行命令） | 是 |
| `ssh_exec` | 在已有 SSH 连接的独立通道执行命令 | 是 |
| `sftp_list` / `sftp_read_text` | 列目录 / 读取 UTF-8 文本和 SHA-256 | 否 |
| `sftp_write_text` | 独占创建或核对摘要后替换文本文件 | 是 |

权限按本机的本地 Profile 或服务器实例、账户和 Vault 隔离保存，不参与同步，Android 备份和设备迁移也排除这些授权。禁止访问的机器不会出现在主机、会话列表及计数中，直接使用其 ID 也无法访问；只读仅允许读取已打开的终端和 SFTP 内容，不允许连接、切换或关闭会话。

主机与会话列表不返回密码、私钥或解锁密钥。终端输出和文件内容仍可能包含敏感信息，且应被 AI 作为不可信数据处理。SSH 主机密钥、RDP 证书及认证提示继续走应用交互，不自动信任。RDP / VNC 提供连接和标签管理，暂不暴露图像或鼠标控制。

调用顺序示例：`hosts_list` → `host_connect {host_id}` → `sessions_list` → `ssh_exec {session_id,command,timeout_seconds}`。文件替换先 `sftp_read_text`，再以返回的 `sha256` 作为 `sftp_write_text` 的 `expected_sha256`，`mode` 设为 `replace`；新建使用 `create`。文件路径必须绝对路径。超时后的远程结果可能不确定，不自动重试有副作用的调用。

每次仅执行一个工具请求；命令超时最多 120 秒，工具总截止时间 130 秒。文本文件和命令输出上限 64 KiB，终端读取最多 2000 行，列表一页最多 200 项。工具日志只在内存保留最近 50 条名称和成功状态，停止服务后清空。

## HTTP 客户端配置

应用设置中复制的配置使用 Streamable HTTP，其结构如下。示例令牌必须替换为本次启用生成的值，只保存到受信客户端的私有配置：

```json
{
  "mcpServers": {
    "atermius": {
      "url": "http://127.0.0.1:8765/mcp",
      "headers": {
        "Authorization": "Bearer REPLACE_WITH_CURRENT_ENABLE_TOKEN"
      }
    }
  }
}
```

按外部客户端支持的 HTTP 配置语法调整。请求需包含 JSON Content-Type 及协议要求的 Accept/方法头；服务使用 JSON 响应，不提供 SSE 推送，GET 返回 405。应用复制配置与当前启用端口/令牌一致，停用后旧令牌失效。

仅支持 stdio 的客户端需要另行配置兼容适配器；当前拆分仓库不附带旧说明中的 Python 桥接脚本。无需在运行机器克隆整个历史工程或公开监听端口。

参考：[MCP Streamable HTTP 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)。

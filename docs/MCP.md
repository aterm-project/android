# 外部 AI 的 MCP 接入

在桌面客户端解锁工作区，打开 **设置 → AI / MCP**，选择端口后启用，再复制连接配置到外部 AI 的 MCP 配置中。默认仅只读；需要连接、输入、执行命令或写文件时，先打开“允许外部 AI 执行操作”，再启用服务。修改权限会停止服务，旧令牌失效。

服务仅监听 `http://127.0.0.1:8765/mcp`（端口可改）。每次启用生成独立随机 Bearer 令牌，不写入磁盘。配置含令牌，只交给信任的客户端。锁定、退出或切换工作区会撤销授权；重新启用后需要更新 AI 端配置。多窗口应使用不同端口。停止 MCP 不关闭已打开的会话，也不能撤销已经发生的远程操作；等待用户确认的连接可能仍由应用完成。

Windows、Linux、macOS 桌面支持监听；Web 和移动端显示能力说明，不监听端口。服务与当前已解锁的本地 Profile 或云端 Vault 绑定，不把密钥交给服务器，不包含内置模型聊天。

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

主机与会话列表不返回密码、私钥或解锁密钥。终端输出和文件内容仍可能包含敏感信息，且应被 AI 作为不可信数据处理。SSH 主机密钥、RDP 证书及认证提示继续走应用交互，不自动信任。RDP / VNC 提供连接和标签管理，暂不暴露图像或鼠标控制。

调用顺序示例：`hosts_list` → `host_connect {host_id}` → `sessions_list` → `ssh_exec {session_id,command,timeout_seconds}`。文件替换先 `sftp_read_text`，再以返回的 `sha256` 作为 `sftp_write_text` 的 `expected_sha256`，`mode` 设为 `replace`；新建使用 `create`。文件路径必须绝对路径。超时后的远程结果可能不确定，不自动重试有副作用的调用。

每次仅执行一个工具请求；命令超时最多 120 秒，工具总截止时间 130 秒。文本文件和命令输出上限 64 KiB，终端读取最多 2000 行，列表一页最多 200 项。工具日志只在内存保留最近 50 条名称和成功状态，停止服务后清空。

## 客户端兼容

支持 Streamable HTTP JSON 响应：2025-03-26、2025-06-18、2025-11-25 的 `initialize` 流程，以及 2026-07-28 的请求元数据、方法头与 `server/discover`。本服务不使用 SSE 推送，GET 返回 405。请求需携带 `Authorization: Bearer …`、`Content-Type: application/json` 和 `Accept: application/json, text/event-stream`。

仅支持 stdio 的客户端可使用仓库中的 `integration/mcp/stdio_bridge.py`，需要 Python 3，无第三方依赖：

```json
{
  "mcpServers": {
    "atermius": {
      "command": "python3",
      "args": ["/absolute/path/to/atermius/integration/mcp/stdio_bridge.py"],
      "env": {
        "ATERMIUS_MCP_URL": "http://127.0.0.1:8765/mcp",
        "ATERMIUS_MCP_TOKEN": "替换为本次启用生成的令牌，不含 Bearer 前缀"
      }
    }
  }
}
```

Windows 可将 command 改为已安装的 `python`，路径使用实际仓库路径。桥接器不启动应用、不监听公网、不跟随重定向，不使用环境代理。其 stdio 请求顺序执行；长请求期间取消请使用应用中的停止按钮，或等待工具截止时间。

协议依据：[Streamable HTTP](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http)、[2025-11-25 传输](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)、[发现](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)。

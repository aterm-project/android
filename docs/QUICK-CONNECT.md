# 首页搜索和快捷连接

本地与账户主页在输入时实时筛选主机，操作、协议筛选和分组选项位于搜索框下方。输入连接命令后可按回车或点击连接提示：

| 输入 | 行为 |
| --- | --- |
| `ssh root@example.com -p 22122` | SSH 连接指定用户名和端口 |
| `rdp admin@192.0.2.10` | RDP，默认 3389 |
| `rdp DOMAIN\user@host -p 3390` | RDP 域用户名与自定义端口 |
| `vnc 192.0.2.10:5901` | VNC，未指定端口时为 5900 |
| `ssh user@[2001:db8::1] -p 22` | IPv6 地址 |
| `console` | 桌面端本机 Shell |
| `console tty @COM3` | Windows COM3 串口，115200 baud、8N1 |
| `console tty @COM12 -b 9600` | Windows 串口与自定义波特率 |

串口也接受 `tty @COM3` 和 `console @COM3`。当前 COM 串口实现仅适用于 Windows；Web 不启动本机 Console，也不会将这些文本作为服务器端 Shell 命令执行。

匹配已保存主机时，协议、地址、端口和显式用户名必须一致，才复用该主机的凭据。多个匹配项会让用户选择。新地址打开右侧凭据编辑器，预填协议、地址、用户名和端口，点击“保存并连接”后随主机加密保存登录信息并发起连接。取消不会建立连接。

命令解析器只接受连接参数，不调用 Shell，不支持 `-o`、代理命令、管道或附加远程命令。普通文本继续作为名称、地址、用户名或标签搜索。Windows 串口使用系统通信 API，8 数据位、无校验、1 停止位、无流控；输入队列限制为 64 KiB，读取不阻塞界面，写入带超时，标签关闭会释放设备。波特率范围为 50–4000000，具体值仍须设备驱动支持。

串口实现依据微软 [COMMTIMEOUTS](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-commtimeouts)、[DCB](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-dcb) 和 [SetCommState](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setcommstate)。当前 Windows 探针验证不存在端口的可见错误和正常清理；没有实体串口收发验收。

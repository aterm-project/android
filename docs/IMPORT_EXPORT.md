# 导入与导出 / Import and export

[首次使用](GETTING_STARTED.md) · [First use](GETTING_STARTED.en.md)

当前支持 Termius 兼容 CSV、OpenSSH 配置和 OpenSSH 文件包。它们是已知格式的互操作，不读取 Termius 原生加密导出或云端数据库。/ Current transfer supports Termius-compatible CSV, OpenSSH config and OpenSSH bundles; it does not decrypt native Termius vault exports or cloud data.

Termius CSV 模板的八列顺序为 / The supported eight-column template is:

```csv
Groups,Label,Tags,Hostname/IP,Protocol,Port,Username,Password
```

导入先预览分组、标签、协议、身份与遗漏项，再确认写入当前资料或 Vault。SSH/Mosh 形式按 SSH 处理，Telnet 有相应映射；RDP/VNC 属于扩展而非标准 Termius 模板能力。不要把“文件被接受”理解为所有字段都能无损往返。/ Review groups, tags, protocol, identity and reported losses before applying. Mosh-shaped entries map to SSH, Telnet is recognized, and RDP/VNC are extension protocols rather than standard template guarantees.

CSV 不能完整承载 SSH 私钥、证书、跳板和转发语义；导出会报告遗漏/降级。需要私钥文件时使用受支持的 OpenSSH 包并核对预览。包不是 Termius 加密 Vault 格式。/ CSV cannot represent every key/certificate/jump-host/forwarding field; inspect reported omissions. Use an OpenSSH bundle when supported key files are needed. It is not a native Termius vault archive.

包含密码或私钥的导出文件是敏感明文资料，应使用明确授权的目标保存。CSV 保持模板值兼容，并不会把所有字段改写为电子表格安全公式；不要把不可信导出当电子表格执行。/ An export containing secrets is plaintext sensitive material. CSV preserves template values; do not execute untrusted CSV content as spreadsheet formulas.

恢复整个加密工作区时使用应用的加密备份/导出流程，遵守其相同实例/Vault 限制；主机格式迁移与完整备份恢复是不同操作。/ For complete encrypted workspace recovery, use the app's encrypted archive flow and its same-instance/Vault limits.

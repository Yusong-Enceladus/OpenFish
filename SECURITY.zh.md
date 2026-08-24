# 安全策略

完整的信任边界、威胁、控制与剩余风险分析见
[OpenFish 威胁模型](docs/openfish-threat-model.zh.md)。

OpenFish 会运行本地编程 Agent；在用户批准的权限范围内，它们可以读取文件和执行命令。请将每个
Harness Pack、ACP Registry 条目、插件、MCP Server 与项目指令文件都视为可执行或模型可见的
第三方输入。

## 报告漏洞

不要为漏洞、凭证泄露或能够越过可见审批边界执行命令的问题创建公开 Issue。请使用本仓库 GitHub
页面中的 **Security → Report a vulnerability** 私下报告。请提供受影响的 OpenFish Build、
操作系统／架构、Harness id／版本、最小复现与影响。除非维护者在私密报告中明确请求脱敏样本，
否则请移除 API Key、Token、私有源码、个人路径与会话记录。

## 支持版本

OpenFish 当前为 Public Alpha。安全修复只面向最新的 Alpha 标签；固定到旧 Harness Pack 版本的
任务仍可继续运行，但发现已知不安全分发后，新安装可能被拒绝。

## 安全边界

- Harness 凭证通过 Host Credential API 与原生 Keychain 存储；绝不能放进 Pack 的普通环境变量表。
- 配对 Token 只返回一次，Host 只持久化其 SHA-256 摘要；已配对设备可以从 Host 撤销。
- ACP Registry 元数据不等于代码审计。OpenFish 会分别报告 Registry 状态与 Runtime 兼容性。
- `workspace-write` 不是虚拟机。Harness 仍拥有其自身 Sandbox 与操作系统实际授予的权限。
- LAN 连接应只在可信网络或 Tailscale 中使用；不要把 Host 端口直接暴露到公网。

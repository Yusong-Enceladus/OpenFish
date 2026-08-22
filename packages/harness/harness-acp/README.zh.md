# `@deepseek-ai/dsh-harness-acp`

[English](README.md)

此包是 Open Fish Harness Pack 背后的通用 ACP Driver。安装使用壳子自带且固定版本的 Node/npm 或 Bun runtime，把每个 Pack 版本放入 Open Fish 管理状态。会话从该精确快照以不经过 shell 的 argv 启动可执行文件，而不会再次解析网络包。随后 Driver 把远端 ACP 会话映射到普通 DSH `Agent`、`Session`、inbox、审批、取消和状态约定。

## Model Experience

### ACP 拥有的对话

#### 模型看到什么

所选 ACP Harness 会通过 ACP `session/prompt` 接收用户按顺序提交的文本提示词。Open Fish 不会向该远端 Harness 对话注入 DSH 系统提示词或工具 schema。

#### Token 影响

取决于数据，并由所选 Harness 及其模型提供方拥有；此桥接不增加提示词 token。

#### KV Cache 影响

当 Harness 支持 ACP load-session 时，在远端 Harness 会话内保持仅追加；Open Fish 会让恢复失败，而不会创建无关历史。

## Known Limitations and Deferred Work

- Driver 会声明支持 terminal 认证，但不声明 ACP 工具 terminal 或文件系统客户端操作；Harness 自行执行工具，并通过 ACP 请求权限。
- 提示附件和工具 terminal 回调不属于 v0 Driver。Pack 声明的认证方式可在壳子中选择。由 Agent 管理的浏览器登录仍归 Harness；API Key 在每次启动时从 Host 的只写 credential 服务解析，并通过 ACP 认证请求传递，不进入 Pack 状态。
- Codex 当前通过 ACP Registry 适配器运行，而该适配器底层调用官方开源 Codex 包。直接的 Codex App Server Driver 能暴露更多提供方原生事件，属于保真度升级，不是选择或运行 Codex 的前置条件。
- 包代码会以 Host 进程配置的操作系统权限运行；发布者元数据和 ACP Registry 传输不能替代包管理器完整性、操作系统沙箱或用户审批。

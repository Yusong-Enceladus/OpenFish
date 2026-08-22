# OpenFish 兼容性

[English](openfish-compatibility.md) | 中文

OpenFish 的兼容性是一份可测试契约，不是“名字叫 Harness 的程序都能自动运行”的宣传。壳子只有两条扩展边界：

1. 兼容 ACP 的 Harness 直接使用内置 ACP Driver，不需要新增原生 UI。模型、思考强度、模式与标准会话选项来自实时 ACP 配置目录。
2. 非 ACP Harness 需要一个 `HarnessDriver` 插件；目录、安装器、会话版本固定、存储、原生壳子与手机传输保持复用。

## 支持等级

| 等级 | 含义 |
| --- | --- |
| 发布基线 | 自动契约测试与打包 Runtime 检查会阻断 OpenFish 发布。 |
| Alpha 已验证 | 除发布基线外，已在受支持 Mac 上留下真实 Runtime／人工路径证据。 |
| 社区兼容 | 来自 ACP Registry、OpenFish 社区目录或自定义 Pack，使用通用 Driver，但不阻断 OpenFish 发布。 |
| 协议不支持 | OpenFish 运行它之前需要新增 Driver 插件。 |

## 当前矩阵

| Harness | 入口 | 等级 | 认证归属 | 说明 |
| --- | --- | --- | --- | --- |
| DeepSeek Harness | 内置 `dsh` Pack | 发布基线 | DSH Provider 配置 | 覆盖原生 Host／会话行为与 No Project 存储。 |
| Codex CLI | ACP Registry `codex-acp` | Alpha 已验证 | Codex／ChatGPT 或 Codex API 配置 | 模型与思考选项来自实时 ACP 会话。 |
| Oh My Pi | 精选 `oh-my-pi` Pack | Alpha 已验证 | OMP | 通过 OMP ACP 命令运行；OMP 私有设置仍归 OMP 管理。 |
| Pi | ACP Registry `pi-acp` | 社区兼容 | Pi | 复用通用 ACP 路径；目前还不是带真实账号的发布阻断项。 |
| 其他 ACP Registry Agent | Registry Pack | 社区兼容 | 所选 Agent | Registry 只验证元数据／认证形状；启动后才记录 OpenFish Runtime 兼容性。 |
| OpenFish 社区 Pack | 社区目录 | 社区兼容 | Pack／Agent | Pull Request 审核校验公开 Manifest 与精确分发版本；真实 Runtime 成功前始终标记为未验证。 |
| 自定义 ACP 进程 | 用户 Pack | 社区兼容 | Pack／Agent | 必须固定精确包版本；Secret 应放入认证字段而不是启动环境数据。 |
| 非 ACP Harness | Driver 插件 | 协议不支持 | Driver 定义 | 只有名字或可执行文件无法安全推断私有会话语义。 |

## 发布阻断旅程

Harness 契约门禁覆盖 Manifest 接纳、首次启动、No Project、Harness 切换、模型／配置变化、恢复时版本固定、缺失认证、ACP 断开／取消、未来未知标准选项与打包 Host 生命周期。 `script/check_harness_contract.sh` 由 macOS 发布构建器强制调用。

兼容报告必须包含 Harness id／版本、OpenFish Build、Host 架构、工作区模式、认证方式名称（绝不包含凭证）与首条脱敏错误。Registry 条目只是发现元数据，不代表安全审计或质量背书。

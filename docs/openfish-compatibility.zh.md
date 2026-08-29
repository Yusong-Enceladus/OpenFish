# OpenFish 兼容性

[English](openfish-compatibility.md) | 中文

OpenFish 的兼容性是一份可测试契约，不是“名字叫 Harness 的程序都能自动运行”的宣传。壳子只有两条扩展边界：

1. 兼容 ACP 的 Harness 直接使用内置 ACP Driver，不需要新增原生 UI。模型、思考强度、模式与标准会话选项来自实时 ACP 配置目录。
2. 非 ACP Harness 需要一个 [`HarnessDriver` 插件](harness-driver-sdk.zh.md)；目录、安装器、会话版本固定、存储、原生壳子与手机传输保持复用。

## 支持等级

| 等级 | 含义 |
| --- | --- |
| 发布基线 | 自动契约测试与打包 Runtime 检查会阻断 OpenFish 发布。 |
| Alpha 已验证 | 除发布基线外，已在受支持 Mac 上留下真实 Runtime／人工路径证据。 |
| 发布候选 | Pack 与 Driver 已存在，但当前 Artifact 尚未同时取得自动门禁与真实 Runtime 记录。 |
| 社区兼容 | 来自 ACP Registry、OpenFish 社区目录或自定义 Pack，使用通用 Driver，但不阻断 OpenFish 发布。 |
| 协议不支持 | OpenFish 运行它之前需要新增 Driver 插件。 |

## 当前矩阵

| Harness | 入口 | 等级 | 认证归属 | 说明 |
| --- | --- | --- | --- | --- |
| DeepSeek Harness | 内置 `dsh` Pack | 发布候选 | DSH Provider 配置 | 原生 Host／Session 与 No Project 路径必须针对最终 Release Artifact 通过后，才升级为发布基线。 |
| Codex CLI | 内置官方 `codex app-server` Pack | Alpha 已验证 | 现有 Codex 登录、托管 ChatGPT 登录或 OpenAI API Key | 精确 `0.150.1` 既有登录证据覆盖隔离安装、7 个实时模型、模型特定思考强度、1 次完成的提示词与 Seatbelt 下的恢复。模型与账号／计费标签仍来自实时 app-server 响应；托管 ChatGPT 登录、API Key 计费与最终产物分支行仍待完成。 |
| Oh My Pi | 精选 `oh-my-pi` Pack | Alpha 已验证 | OMP | 精确 `18.0.10` 实时证据覆盖隔离安装、启动、2 种已发现认证方式、Session 创建与恢复，以及通过通用 ACP 投影 2 种 Mode 与 Agent 公布的 Thinking Control。未认证 Harness 没有公布模型，因此带认证的模型／思考强度／发送证据仍待完成；OpenFish 不会臆造回退模型，OMP 私有设置仍归 OMP 管理。 |
| Pi | ACP Registry `pi-acp` | 社区兼容 | Pi | 复用通用 ACP 路径；目前还不是带真实账号的发布阻断项。 |
| 其他 ACP Registry Agent | Registry Pack | 社区兼容 | 所选 Agent | Registry 只验证元数据／认证形状；启动后才记录 OpenFish Runtime 兼容性。 |
| OpenFish 社区 Pack | 社区目录 | 社区兼容 | Pack／Agent | Pull Request 审核校验公开 Manifest 与精确分发版本；真实 Runtime 成功前始终标记为未验证。 |
| 自定义 ACP 进程 | 用户 Pack | 社区兼容 | Pack／Agent | 必须固定精确包版本；Secret 应放入认证字段而不是启动环境数据。 |
| 非 ACP Harness | 公共 Driver SDK 插件 | Driver 加载前不支持 | Driver 定义 | 只有名字或可执行文件无法安全推断私有会话语义；Conformance 报告会在启动前拒绝不完整的生命周期、工作区、编辑与观测声明。 |

2026-08-29 的实时 ACP Registry 包含 39 个 agent，其中包括 Codex、Claude、Cursor、Gemini、OpenCode、Pi 与 Copilot 条目。OpenFish 可以把这些精确版本的分发信息投影到通用 ACP 路径，无需增加原生 UI 分支；但在安装后的运行时通过用户平台验证前，每个条目仍只属于社区兼容。Registry 是每小时更新的发现来源，不是冻结的 OpenFish 支持列表。上游 Codex `0.151.0` 也于 2026-08-29 发布；OpenFish 会保留已测试的 `0.150.1` 发布基线，直到新版通过仓库规定的 24 小时最短发布时长门禁，以及相同的隔离、模型、思考强度、提示词与恢复路径。

## 发布阻断旅程

Harness 契约门禁覆盖 Manifest 接纳、首次启动、No Project、Harness 切换、模型／配置变化、恢复时版本固定、缺失认证、ACP 断开／取消、未来未知标准选项与打包 Host 生命周期。 `script/check_harness_contract.sh` 由 macOS 发布构建器强制调用。

兼容报告必须包含 Harness id／版本、OpenFish Build、Host 架构、工作区模式、认证方式名称（绝不包含凭证）与首条脱敏错误。Registry 条目只是发现元数据，不代表安全审计或质量背书。

本表描述源码要求的证据，并不等于当前 Working Copy 已通过。Tagged Release 只能依据该准确 Artifact 生成的报告，把候选项升级为更高等级。

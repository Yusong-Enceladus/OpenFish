# Agent Note: Open Fish Harness Pack Runtime

Status: implemented

[English](2026-08-20-openfish-harness-pack-runtime.md) | 中文

## Problem

Open Fish 原本是单一 DSH Runtime 的原生壳子。如果把 Codex、Pi、Oh My Pi 或未来 Harness 直接写进壳子，每个提供方都会形成产品专属分支，用户需要预装工具，而且公共图形界面还会错误描述私有 Runtime 内部结构。

## Decision

Open Fish 按会话选择 Harness。Harness Pack v0 负责身份、协议、分发、发布者元数据、可用性和如实的架构图。图声明 `opaque`、`observable` 或 `composable`；只有 Pack 声明为可编辑的节点才能修改。壳子搜索分离的目录，不内置提供方 id。

DSH 保留为内置原生路径。通用 ACP Driver 通过壳子自带的 Node/npm 或固定版本 Bun 安装每个包版本并启动精确的受管快照，持久化 ACP 远端身份，把文本输出和生命周期映射到公共 Session 表面，桥接审批与取消，并保留每个原生 ACP 更新。官方 ACP Registry 与生成后的 OpenFish 社区目录会在启动时填充发现数据。内置和已配置用户 Pack 覆盖所有冲突，官方 ACP 条目优先于社区条目。社区条目始终标记为未验证，并遵循相同的准确版本准入规则。curated Oh My Pi Pack 使用 Bun，因为其发布的 CLI 要求 Bun 1.3.14 或更高版本，而且尚未进入 Registry。

`session.create` 接受 `harnessId`。现有会话会拒绝冲突选择；每个冷 API 入口都恢复 `harness/selected` 记录的 Harness，绝不会悄悄让 DSH 恢复外部历史。Agent Preset 仍是 DSH 专属概念，ACP 模型、思考强度与其他标准选项则来自每个实时 ACP 会话。可编辑的 composable 节点可以声明 `acpSessionOptions`；通用 Driver 会在新建会话时应用这些默认值，并拒绝 Harness 未声明支持的值。Host 持久化共享默认项、安装、认证偏好、活动版本和回滚快照。macOS Landing 流程要求用户选择一个默认 Harness，并在需要时安装所选 Pack；macOS 与 iOS 设置修改同一个 Host 默认项，而每个空白任务在第一轮之前仍可另选 Harness。原生选择界面会在使用前展示来源、安装、认证、兼容性与 Pack 真实性等级图。macOS Harness Studio 可以创建、编辑、导入和导出自定义 Pack；发布通过不含凭证的 Manifest 贡献到生成后的社区目录。

原生组合为未指定 Workspace 的会话提供 Host 自有的 `$DSH_HOME/openfish/sessions/no-workspace` cwd。启动器的当前目录绝不会把未分组任务错误归类成用户项目。

## Alternatives considered

- **硬编码 DSH、Codex 和 OMP Adapter。** 这只能优化首批名单，无法证明第四个 ACP Harness 可以不重编壳子直接接入。
- **把 Harness 当成模型提供方。** Harness 拥有 Agent Loop、工具、审批协议和会话语义；模型路由无法表达这些所有权。
- **承诺每个进程都有一张可编辑图。** 黑盒 CLI 不暴露稳定节点或安全变更语义。如实的 opaque 执行加无损原生事件可行；composable 必须由 Pack 声明。
- **要求用户安装每个 CLI。** 这违背集成式产品要求。npm ACP Pack 会在 Open Fish Runtime 路径中按需安装。

## Verification

Manifest 与生命周期测试覆盖 Pack 准入、悬空图边拒绝、任意 ACP Registry 映射、第三方 Driver 注册、原子状态恢复、更新和回滚。ACP 测试证明会话从受管安装快照启动。API Carrier 测试覆盖目录变更与 `harnessId` 会话线协议。原生构建覆盖 macOS 图编辑、iOS 选择、Host 组合和冷恢复边界。

## Consequences

任何发布兼容 Registry 元数据的 npm ACP Agent 都可以无需修改壳子代码直接出现、安装并运行。Codex 与 Pi 当前来自 Registry，Oh My Pi 则作为 curated Pack 复用同一个 ACP Driver。新协议实现导出的 `HarnessDriver` 接口即可，无需修改壳子或 Session 代码。Codex 的 ACP 适配器底层运行官方 Codex 包，但未来直接 App Server Driver 会保留更多提供方原生保真度。图编辑仅对 Pack 声明的 composable 节点开放；浏览器登录仍归 Harness，API Key 留在 Host credential 服务，对话不会声称可跨 Harness 移植。

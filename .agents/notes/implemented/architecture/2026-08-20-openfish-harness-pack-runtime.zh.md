# Agent Note: Open Fish Harness Pack Runtime

Status: implemented

[English](2026-08-20-openfish-harness-pack-runtime.md) | 中文

## Problem

Open Fish 原本是单一 DSH Runtime 的原生壳子。如果把 Codex、Pi、Oh My Pi 或未来 Harness 直接写进壳子，每个提供方都会形成产品专属分支，用户需要预装工具，而且公共图形界面还会错误描述私有 Runtime 内部结构。

## Decision

Open Fish 按会话选择 Harness。Harness 是把用户意图、上下文与模型转化为受控、可观察、可恢复行动的执行系统；它拥有 Agent Loop、工具、权限、会话语义和面向模型提供方的配置。Harness Pack v0 负责身份、协议、分发、发布者元数据、可用性和有证据支撑的 Architecture Manifest。图声明 `opaque`、`observable` 或 `composable`；opaque Pack 必须只展示一个如实的 Runtime 边界，observable 与 composable Pack 则必须声明一条连通且有证据的控制流。系统没有装饰性的节点下限：视图展示 Pack 或 Driver 能够支撑的全部已知职责，绝不猜测私有内部结构。只有 Pack 声明可编辑且具有类型化 Driver 绑定的节点才能改变执行。通用目录发现与会话代码不按提供方 id 分支。

DSH 保留为内置原生路径。Codex 使用独立 Driver 对接官方 `codex app-server` 协议，保留实时 ChatGPT／API 账号状态、模型与思考强度、thread 恢复／删除／fork、工具调用、审批和原生事件。通用 ACP 通过壳子自带的 Node/npm、固定版本 Bun、随附 uv 或带校验和的有界平台归档安装每个包版本并启动精确受管快照。它持久化 ACP 远端身份，把无损原生更新流映射到公共 Session 表面，并桥接标准审批、取消、图片、文件与终端回调，但不接管远端 Agent Loop。官方 ACP Registry 与生成后的 OpenFish 社区目录会在启动时填充发现数据。内置和已配置用户 Pack 覆盖所有冲突，官方 ACP 条目优先于社区条目。社区条目始终标记为未验证，并遵循相同的准确版本准入规则。curated Oh My Pi Pack 通过固定版本 Bun 运行其公开的 ACP 命令，因为它尚未进入 Registry。

`session.create` 接受 `harnessId` 和可选的客户端生成 `sessionId`。客户端会在第一轮前只准备一个准确的空白持久身份，仅把该 id 与所选 Harness 写入每台 Host 独立的私有投影缓存；即使响应丢失或 App 重启，也会接回同一个任务。现有会话拒绝冲突 Harness；每个冷 API 入口都恢复 `harness/selected`，绝不会悄悄让 DSH 恢复外部历史。未开始的草稿可以本地丢弃，但已开始任务绝不会经过草稿路径删除。Codex 把丢弃映射为提供方 `thread/delete`；通用 ACP 只停止被放弃的进程，因为 ACP 没有提供方侧删除原语。

Agent Preset 仍是 DSH 专属概念。Codex 的模型、思考强度与账号身份来自实时 app-server；ACP 模型与标准选项来自每个实时 ACP 会话。模型／配置变更按会话串行执行并始终与 Driver 权威状态重新同步，即使发起变更的 UI 请求在变更写入协议后被取消。可编辑的 composable 节点可以声明 `acpSessionOptions`；通用 Driver 会在新建会话时应用默认值，并拒绝 Harness 未声明支持的值。Host 持久化共享默认项、安装、非秘密认证偏好、活动版本和回滚快照。macOS Landing 要求选择默认 Harness 并在需要时安装；macOS 与 iOS 设置修改同一个 Host 默认项，每个空白任务在第一轮之前仍可另选 Harness。原生选择采用 Progressive Lens：Simple 说明适用场景与登录方式；Architecture 解释有证据支撑的职责及其实时状态；Mac Manifest Editor 用于创建、导入、校验、预检和导出 Pack。iPhone 提供相同的 Simple、Architecture 理解层和只读 Builder 交接；发布与涉及凭证的编辑留在权威 Mac Host。发布通过不含凭证的 Manifest 贡献到生成后的社区目录。

每个未指定 Workspace 的会话都获得独立的 Host 自有 `$DSH_HOME/openfish/no-project/<sessionId>` cwd。它会在两端归入“No Project”，绝不会继承 Desktop、启动器 cwd 或另一个无项目任务的文件。

## Alternatives considered

- **硬编码 DSH、Codex 和 OMP Adapter。** 这只能优化首批名单，无法证明第四个 ACP Harness 可以不重编壳子直接接入。
- **把 Harness 当成模型提供方。** Harness 拥有 Agent Loop、工具、审批协议和会话语义；模型路由无法表达这些所有权。
- **承诺每个进程都有一张可编辑图。** 黑盒 CLI 不暴露稳定节点或安全变更语义。如实的 opaque 执行加无损原生事件可行；composable 必须由 Pack 声明。
- **要求用户安装每个 CLI。** 这违背集成式产品要求。npm ACP Pack 会在 Open Fish Runtime 路径中按需安装。

## Verification

Manifest、生命周期、Driver Conformance、ACP 集成、API Carrier、原生客户端、配对、沙箱、发布与隐私检查共同形成发布门禁。它们覆盖 Pack 准入、任意 Registry 映射、opaque／有证据／composable 图、准确版本安装、有界归档解包、第三方 Driver 注册、生命周期脚本许可、原子更新与回滚、权威模型／配置变更、准确草稿恢复、No Project 隔离、无损原生事件、真实能力门禁、语音生命周期失败、配对证明／撤销，以及 Mac／iPhone 冷恢复。真实 DSH、Codex、OMP 轨迹与合成未知 ACP Fixture 单独记录，契约测试通过绝不被表述为提供方认证。

## Consequences

任何兼容 ACP Registry 的条目都可以无需修改壳子代码直接出现、安装并运行。未知 Registry Agent 在获得更强证据前只显示一个 opaque 边界。DSH、官方 Codex app-server 与 curated Oh My Pi 使用从源码推导的 Manifest 和有意义的职责；Open Fish UI、操作系统与模型提供方均位于 Harness 边界之外。新协议实现 Driver API v1 后，可以通过用户许可且准确固定来源的公开 Driver Bundle 加入，而不要求发布新版原生 App。Driver 代码会在关闭生命周期脚本的情况下暂存、进行结构准入、隔离进程并协商 Capability，但它仍是第三方可执行代码，绝不等同于安全的数据型 Pack。图编辑仅对 Pack 声明的 composable 节点和真实 Driver 绑定开放；浏览器登录仍归 Harness，API Key 留在 Host credential 服务，对话不会声称可跨 Harness 移植。

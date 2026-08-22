# Agent Note：OpenFish 行业体验参考

状态：proposed

[English](2026-08-22-openfish-experience-reference.md) | 中文

## 问题

OpenFish 需要完整重做 Mac 和 iPhone 体验，但此前的视觉改动没有先记录与优秀 Coding Agent、原生效率工具、图编辑器、运行时和扩展市场产品的系统比较。因此，当前控件虽然在本机看似合理，却仍存在信息层级弱、任务配置拥挤、架构图静态、空态和错误态不一致，以及核心价值不可见或未经证明等问题。

本文记录 2026-08-22 的当前一手资料对比和产品基线审计。它从属于完整的[产品完成合同](2026-08-22-openfish-product-completion-contract.md)，不会缩小该合同。

## 参考矩阵

| 产品 | 一手依据 | 优秀模式 | OpenFish 采用方式 | 拒绝或限制 |
| --- | --- | --- | --- | --- |
| OpenAI 模型平台 | [最新模型指南](https://developers.openai.com/api/docs/guides/latest-model)、[模型目录](https://developers.openai.com/api/docs/models) | 模型身份和思考强度分离，控件随模型变化。 | Harness、账户、Provider/模型和思考强度保持独立可见；只渲染真实声明的强度。 | 不按模型名字猜测思考强度列表。 |
| OpenCode | [入门](https://opencode.ai/docs)、[模型](https://opencode.ai/docs/models)、[Provider](https://opencode.ai/docs/providers)、[权限](https://opencode.ai/docs/permissions) | 明确连接 Provider，使用 `provider/model` 身份，记忆/默认选择、模型 Variant、可配权限、Plan/Build 模式。 | 显示凭据来源、精确 Provider/模型、思考或 Variant、权限策略和任务模式。 | 不预载大量未配置模型，也不静默选择第一个模型。 |
| Claude Code | [设置](https://docs.anthropic.com/en/docs/claude-code/getting-started)、[CLI](https://docs.anthropic.com/en/docs/claude-code/cli-usage) | 安装 Doctor、明确认证/计费模式、模型与权限模式、恢复和工具控制。 | 增加 Harness 预检、账户/计费说明、固定版本会话和可操作恢复。 | 找到可执行文件不等于任务已经验证。 |
| Cursor | [Agent 模式](https://docs.cursor.com/agent) | 模型、模式、工具靠近任务并分组，配置渐进展开。 | 常用任务控件留在输入区，低频选项进入明确的 Harness 菜单。 | 不把当前模型或权限模式埋到设置里。 |
| LangGraph Studio | [Studio](https://docs.langchain.com/oss/python/langgraph/studio) | 架构加实时中间状态、工具调用、结果、调试和时间旅行。 | 分离声明架构与运行时证据，并把节点状态关联到持久事件。 | 不根据私有内部实现猜测动画。 |
| ComfyUI | [子图](https://docs.comfy.org/interface/features/subgraph)、[App Mode](https://docs.comfy.org/interface/app-mode) | 可复用嵌套图、类型插槽、暴露参数、节点库，以及与编辑界面分离的简单使用界面。 | 使用 Simple / Architecture / Manifest Editor 三层；只暴露 Pack 明确声明的重要参数。 | 不强迫普通用户看图，也不把装饰性 JSON 称为可执行 Builder。 |
| n8n | [执行历史](https://docs.n8n.io/workflows/executions/all-executions/) | 保存执行、用原始/当前工作流重试、把历史执行加载到画布。 | 保留固定版本执行证据、重试和 Trace 到节点的关联。 | 默认 Harness 改变时不修改历史会话。 |
| VS Code | [扩展清单](https://code.visualstudio.com/api/references/extension-manifest)、[扩展宿主](https://code.visualstudio.com/api/advanced-topics/extension-host)、[CI](https://code.visualstudio.com/api/working-with-extensions/continuous-integration) | 版本化清单、Engine 兼容、隔离/延迟扩展宿主、自动兼容检查。 | Driver API 和 Pack Schema 版本化、能力协商、运行时隔离、不兼容拒绝和一致性测试。 | Registry 收录不等于可信或兼容。 |
| Raycast | [开发平台](https://developers.raycast.com/)、[安装](https://developers.raycast.com/basics/install-an-extension)、[安全](https://developers.raycast.com/information/security)、[上架准备](https://developers.raycast.com/basics/prepare-an-extension-for-store) | 类型化原生组件、应用内发现/安装、本地开发隔离、审核、公证和截图隐私检查。 | 提供原生通用能力/配置组件，分离本地 Pack 与社区条目，增加发布和隐私关卡。 | 社区发布不代表安全背书。 |
| LM Studio | [开发文档](https://lmstudio.ai/docs/developer)、[应用文档](https://lmstudio.ai/docs/app) | 本地运行时和模型的下载/加载/列举生命周期、离线运行和本地 Server 边界。 | 分开显示安装、运行时、Provider、模型、本地/远程归属。 | “已安装”不等于“已加载、已认证且可运行”。 |
| Linear | [显示选项](https://linear.app/docs/display-options)、[Peek](https://linear.app/docs/peek)、[选择](https://linear.app/docs/select-issues) | 高密度但一致的导航、快速预览、键盘/鼠标对等、克制使用弹窗。 | Mac 使用稳定任务列表、快速 Inspector、可预测焦点和键盘操作。 | 普通任务修改不反复弹窗。 |
| Apple 平台 | [macOS 设计](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)、[侧栏](https://developer.apple.com/design/human-interface-guidelines/sidebars)、[工具栏](https://developer.apple.com/design/human-interface-guidelines/toolbars)、[设置](https://developer.apple.com/design/human-interface-guidelines/settings)、[无障碍](https://developer.apple.com/design/human-interface-guidelines/accessibility) | 可缩放、键盘优先的 Mac 布局，浅层侧栏，克制工具栏，稳定设置，熟悉操作和适合 iPhone 的导航。 | 建立统一词汇和设备特定导航，保留焦点、缩放、Dynamic Type、触控目标和 VoiceOver 语义。 | 不把桌面侧栏照搬到 iPhone，也不把高频任务控件塞进设置。 |

## 基线审计

2026-08-22 在重做前捕获了确定性的 Mac Fixture。它只含合成数据，不包含用户账户、项目、主机或凭据信息。

- New Task 有大量未利用的纵向空间，输入区下方单行控件过于拥挤；项目、权限、Harness、模型、思考强度、Harness 选项、账户、Preset、语音和发送缺少清楚分组。
- 活动 Harness 有时在视觉上弱于模型和账户，但它实际拥有 Agent 语义。Host、Harness、账户、Provider/模型和权限散落在 Header、输入区、设置和 Inspector 中。
- Onboarding 的 Simple/Architecture/Builder 基础有价值，但 Provider 设置与当前 Harness 和主要操作脱节；Fixture 节点数曾与 DSH 内置 Manifest 漂移。
- 对话阅读尚清楚，但输入区仍密集，任务元数据在多处重复。
- Inspector 把架构显示成纵向列表，而非连接的数据流或实时激活；图预览没有执行状态、边语义、缩放、搜索或方向辅助。
- 浅色模式的信息层级和对比弱于深色模式。这只是视觉发现，不代表无障碍合规结论。
- iPhone 架构网格会裁剪长节点标题和 Kind；Mac-only Builder 虽有说明，但仍需直接 Handoff 和共享验证结果。

## 选定方向

OpenFish 使用克制的原生效率工具外壳，配合明确的运行时控制条和 Progressive Lens：

1. **Simple** 为默认层，回答 Harness 用途、安装与信任、认证与计费、当前 Provider/模型及思考强度，以及这台 Mac 能否运行。
2. **Architecture** 显示有证据的职责和有向流。节点只在状态、权限、故障、配置或可观察数据流独立时拆分，不按函数数量拆分。
3. **Runtime** 叠加持久节点活动、权限边界、工具事件、错误和选定配置，不为动画收集私有内容。
4. **Manifest Editor** 创建/导入版本化 Pack、图、凭据引用、精确 Distribution、默认值和证据；只有具备可执行类型节点语义时才称 Builder。

任务输入区保持 Prompt 为视觉主体。项目和权限属于任务范围组；Harness、账户、Provider/模型、思考强度和 Harness 特定选项属于运行时组；低频选项渐进展开，但所有当前值始终可读。空态、加载态、需设置、离线、可恢复错误和致命错误使用稳定区域，不随意替换整个页面。

Mac 保留两层任务侧栏、快捷键、可调整 Inspector、指针能力和独立设置窗口。iPhone 使用 Navigation Stack、大触控目标和紧凑菜单，以审批和连续使用为主要任务；需要凭据的安装或发布明确 Handoff 到 Mac。

## 验收标准

- 每个重做后的 P0 界面至少能对应上表一个采用模式和一个明确的 OpenFish 需求，单纯审美偏好不够。
- Mac/iPhone Fixture 覆盖有数据、空、加载、需设置、离线、可恢复错误和致命错误，且不含个人数据。
- Host、Harness、Driver、账户、Provider/模型、思考强度、工作区和权限在任务创建或恢复处保持独立且最新。
- Architecture 不虚构内部结构；Runtime 只来自持久观察事件；标签在支持尺寸下不裁剪。
- 宣称设计通过前，必须包括当前截图和真实键盘、窗口缩放、VoiceOver、Dynamic Type、外观及物理设备检查。

## 风险

- 多产品组合容易变成功能拼贴，因此选定方向只使用一个稳定身份层级和 Progressive Lens，不复制孤立视觉。
- 能力驱动的通用 UI 容易机械而冗长，因此 Simple 负责总结，Architecture 和 Manifest Editor 保留精确证据与配置。
- 确定性 Fixture 会掩盖真实故障；它只用于设计和公开截图，不能代替真实 DSH、Codex、OMP、干净机器或物理设备证据。

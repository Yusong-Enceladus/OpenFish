# Agent Note: OpenFish 产品完备与公开发布契约

Status: proposed

[English](2026-08-22-openfish-product-completion-contract.md) | 中文

## 问题

OpenFish 已经具备真实的 macOS 原生壳子、配套 iPhone 客户端、基于 DSH 的会话基础设施、Harness Pack 契约、DSH 原生路径、通用 ACP 路径、受管 Harness 安装，以及早期的 Simple、Architecture 和 Builder 视图。这些部分证明了方向，但还没有证明完整的产品声明。目前的仓库还不能诚实地承诺：新用户只需在干净电脑上安装一个应用，就能选择任意未来 Harness、理解并配置它、在 Mac 和 iPhone 之间可靠运行、创建另一个 Harness 并发布，而且无需针对产品单独开发。

缺口不是某一个孤立 Bug。最近的失败暴露了会话创建、工作区处理、模型发现、思考强度控件、认证、ACP 生命周期、布局、语音输入、设备连接、应用安装和产品身份中的重复假设。只修用户报告的那个实例，会让同一个假设继续在下一个 Harness、Provider、账号、电脑或设备状态下失败。

视觉工作也存在同一种缺陷。之前没有先系统比较 Coding Agent、原生效率工具、图编辑器、Onboarding、配置工具和 Marketplace 等类别中的优秀产品，就开始了零散样式调整。重设计不能因为比现有 UI 干净一点就通过验收；它必须有明确的参考证据、有意图的设计系统、完整的状态覆盖，以及符合各自设备特性的 Mac／iPhone 一致性。

本 Note 是下一轮实现的持久产品契约。它区分已经验证的基础与尚未兑现的承诺，记录完整的 P0／P1 验收范围，并防止后续对话或上下文压缩悄悄缩小工作范围。

## 提案

OpenFish 将成为一个面向可互换 Agent Harness 的原生、集成式、跨设备控制平面。非技术用户在一台没有预装 DSH、Codex、Pi、Node、Bun、Python 工具或 Harness CLI 的电脑上安装 OpenFish；在 Onboarding 中选择默认 Harness；完成明确的认证和模型配置；随后开始任务。同一用户可以在 Settings 中修改默认值，也可以为每个新任务选择不同 Harness。技术用户可以导入或创建 Harness Pack、检查有证据支撑的结构、编辑受支持配置、运行兼容性测试、导出并提交发布。

OpenFish 始终是壳子和控制平面，而不是 Harness。所选 Harness 拥有其 Agent Loop、上下文构造、工具行为、执行与沙箱边界、审批语义、Provider 集成、面向模型的配置、持久化和远端会话生命周期。DSH 可以同时承担当前 Host 和原生 Harness，但所有 UI 与协议表面都必须区分 Host、Harness、模型 Provider、账号和模型。选择另一个 Harness 会创建固定到该 Harness 及其版本的会话；当底层 Harness 无法提供互通时，OpenFish 不承诺对话可移植。

产品要承认不确定性，不能虚构兼容性或内部结构。实现受支持协议的 Harness 可以复用现有 Driver；使用新协议的 Harness 需要 Driver 插件；没有可检查证据的私有 Harness 只显示一个 opaque Runtime 边界。进入 Registry 只能证明可发现，不能证明发布者可信、Runtime 兼容、质量良好或通过安全审查。

## 产品事实与定位

在本契约通过之前，对外措辞应把 OpenFish 描述为一个构建在 DSH 之上、正在验证统一 Harness Pack 与 ACP 体验的实验性原生多 Harness 客户端。每项能力只能标为 implemented、experimental 或 planned。不得宣称通用自动兼容、完整 Harness Marketplace、可执行的可视化 Harness Builder、第三方包已通过安全验证、跨 Harness 对话可移植或不存在 Bug。

目标差异化来自四项能力的组合：一体化安装和配置体验、原生 Mac／iPhone 连续性、对每个 Harness 进行诚实且有证据支撑的解释与 Runtime 观测，以及从 Pack 创建、测试到发布的 Creator 路径。如果 OpenFish 只发布为 DSH 皮肤加通用 ACP Launcher，它是一个有用的实验，但还不是所声明的 Harness 生态。

OpenFish 不会因为名称、发布时间或社区热度就宣布某个 Harness“最好”。Harness 质量需要独立、可复现地比较任务成功率、可靠性、延迟、成本、安全性、工具保真度和用户需求。壳子兼容性与 Harness 质量始终是两类不同指标。

## 从第一性原理定义 Harness 契约

Harness 是把用户意图、上下文、模型和可用工具转化为受控、可观察、可恢复行动的执行系统。其边界包括 Agent Loop，以及实质决定这些行动的策略和状态。模型、Provider 账号、Host 进程、Shell 窗口或图形客户端本身都不等于 Harness。

OpenFish 在 Onboarding、Settings、新建任务、诊断和持久化中始终分别呈现五种身份：

1. OpenFish Client 负责呈现并协调体验。
2. Host 负责本地权威、存储、进程监管、凭证和远端设备服务。
3. Harness 负责 Agent 行为和会话语义。
4. 账号或认证方式决定谁付费以及授权了什么服务。
5. Provider 和模型决定 Harness 契约内的推理、模型专属选项和额度。

架构证据按以下优先级使用：官方机器可读 Manifest、固定源码推导描述、Runtime 观测行为、声明性文档，最后才是 opaque 边界。每个可见节点都要说明责任、边界、已知时的类型化输入输出、证据来源，以及它是 declared、observed、editable 还是 inferred。OpenFish 绝不为了让图显得完整而添加装饰性节点。

## 集成式安装与生命周期

Release 必须自带受支持基线需要的所有 Runtime。一台全新的受支持 Mac 即使没有全局 Node、npm、Bun、uv、Python 包、DSH、Codex 或 OMP，也能安装、认证并运行。每次受管 Harness 安装都使用准确版本和隔离目录，在分发提供校验信息时验证 checksum 或签名，记录 provenance，并且在恢复固定版本会话时绝不重新解析浮动包。

安装流程明确显示下载、验证、认证、健康检查、重试、取消、回滚、更新和卸载状态。更新失败后旧版本仍可运行。如果保留的会话仍引用某个 Harness 版本，在没有明确迁移或删除决定时不得移除它。执行前解释不受支持的平台和缺少完整性元数据的情况。

第三方代码只获得 Harness 所需的最小文件系统、网络、环境变量和进程权限。未验证的社区包警告必须与 OpenFish Runtime 兼容结果分开。OpenFish 绝不传输或记录密码、API Key、私钥、Session Token、Cookie 或一次性代码；秘密存入系统凭证库，只暴露给已授权的本地 Runtime。

## 可扩展性与兼容性

扩展边界由版本化 Harness Pack Schema、版本化 Driver SDK、Capability Negotiation 和 Conformance Test 组成。原生客户端从这些契约渲染能力与配置，不添加 switch 分支、Provider id、固定可执行路径、模型列表或针对单个 Harness 的布局分支。

协商能力覆盖安装、认证、账号身份、模型、思考强度及其他选项、Workspace 模式、权限、审批、问题、文件、工具、事件、取消、恢复、Fork、归档、更新、回滚、诊断、图证据、Runtime 观测和 Builder 操作。未知配置字段通过 Schema 驱动的通用控件呈现，或明确标为不支持；OpenFish 不猜测私有 Flag。

兼容性有四种可见结果：supported、experimental、opaque-but-runnable 和 incompatible。Publisher Verification、源码 provenance、Registry 来源、安装完整性、协议 conformance 与 OpenFish Runtime 成功执行是彼此独立的事实。脱敏兼容报告记录 OpenFish Build、平台、Harness id 与版本、Driver 与协议版本、Workspace 模式、认证方式名称、已测能力和第一条可操作失败信息，但不包含凭证或私密会话内容。

通用扩展证明使用两个在原生 UI 编写时不存在的合成 Harness。一个实现 ACP，能够在不改原生客户端的情况下完成发现、安装、配置、运行、恢复和显示；另一个使用新的 Driver 插件，在不改 Session 或 Presentation 代码的情况下接入同一套壳子契约。格式错误、未固定版本或 Capability 自相矛盾的 Pack 必须在启动前拒绝。

## Harness 选择、认证、模型与会话

首次启动必须选择默认 Harness；目录为空或获取失败时提供恢复路径，而不是空白弹窗。Settings 可以修改共享默认值，每个空白任务在第一轮之前可以覆盖它。已有任务保留 Harness id、Driver、协议、准确版本、远端 Session 身份、账号选择、模型、思考强度、Workspace 模式和 Capability。修改全局默认值绝不能静默改变已有任务。

任务输入区按 Harness、账号或认证方式、Provider 与模型、思考强度或 Harness 专属控件、Workspace 和权限的层级呈现。选中值必须可见，不能隐藏在图标后。可用模型和选项来自实时 Harness 契约。如果没有可路由模型，发送必须被阻止并提供直接配置入口；绝不能创建名为 `harness` 的假 Provider、静默选择写死模型，或展示无法真正应用的选项。

认证必须说明任务使用 ChatGPT／Codex 订阅、OpenAI API 计费、其他 Provider Key、本地模型、浏览器登录，还是 Harness 自有终端登录。OpenFish 只有在显示凭证来源和选中账号后，才能复用已有且已授权的本地凭证。登录始终由用户发起，切换账号不得跨 Harness 移动或暴露凭证。

未选择项目的会话在 Mac 和 iPhone 上都是一等 No Project 会话。它们使用 OpenFish 管理的工作目录，或协议定义的 no-cwd 模式，绝不使用 Desktop 或 Host 启动目录。每个 Release 基线 Harness 的 No Project 模式都必须支持创建、发送、模型选择、Harness 选择、思考强度、恢复、Fork、归档、搜索、导入和跨设备显示。UI 绝不能把它们改称 Other。

## Progressive Lens 与 Runtime 可观测性

默认 Simple Lens 说明 Harness 适合谁、如何安装和登录、将使用哪个账号和模型、兼容与信任状态、重要权限以及切换的后果。Architecture 是用户主动进入的深层视图，而不是 Onboarding 默认页。

Architecture Lens 展示 Harness 边界和对其关键职责有用的聚合。它既不能只显示一个毫无意义的 Provider 节点，也不能无边界地倾倒函数。节点分组依据 Runtime Ownership 和用户相关行为：当组件具有不同状态、权限、失败、配置或可观察数据流时拆分；不会改变理解或控制的实现细节则合并。图在 Mac 和 iPhone 上都支持 Zoom、Pan、搜索、聚焦、键盘导航、可读的 Minimap 或等价定位方式，以及不被裁切的标签。

Runtime Lens 区分声明架构与任务实际激活的组件和边。它可以显示状态迁移、工具与权限边界、事件、错误、延迟、选中配置，以及经过脱敏的数据／控制流。观测不能变成对隐藏内部的声明，也不能为了动画图而采集私密内容。

DSH、Codex、OMP、合成测试 Harness 与 Demo Fixture 使用与运行产品相同的 Manifest 来源。截图和样例数据不能漂移成不同的节点数量或 Capability。Opaque Harness 仍可通过安装、信任、认证、Capability、日志和 Runtime 边界观测诚实地提供价值，而不虚构内部组件。

## Builder、测试与发布

在 Graph 具备可执行语义之前，产品应把当前功能称为 Manifest Editor，而不是 Harness Builder。完整 Builder 包含 Node Kind Registry、Typed Port、配置 Schema、Secret Reference、Validation、可执行或绑定 Driver 的语义、Undo／Redo、版本 Diff、Import／Export、Dry Run、隔离兼容测试与 Live Trace 关联。只有 Pack 和 Driver 声明行为可编辑时，编辑节点才真正改变行为。

创建 Harness 必须生成可运行、版本化的 Pack 或项目，而不是装饰性 JSON。Test 操作在隔离环境安装它，测试协商 Capability，把失败定位到责任节点或契约，并产出不含凭证的兼容报告。Export 移除秘密和个人路径，同时保留准确分发信息与 provenance。

Publish 必须真实提交到有文档的社区 Registry 或仓库流程，显示验证与审核状态，并记录版本、Publisher、provenance、兼容和撤销状态。Catalog 必须提供有意义的内置与发现结果，而不是空搜索框。它区分 Discoverability 与 Endorsement，并支持更新、回滚、报告、移除和版本历史。只有存在可信后端时才加入排行、评分和下载量。

iPhone 客户端可以把涉及凭证的编辑、本地安装和发布保留为明确的 Mac Handoff。它仍需显示相同的 Simple、Architecture、Runtime、验证、版本和信任事实，而且绝不能把只读视图呈现为可编辑 Builder。

## 基于行业案例的体验设计

在仓库中形成带日期、基于当前一手产品资料与实际操作的 Reference Matrix 之前，不得开始大规模 UI 实现。研究覆盖 Codex、Claude Code 或 Claude Desktop、Cursor、Windsurf、GitHub Copilot、OpenCode、Continue 等 Coding Agent 产品；OpenRouter 风格 Selector、LM Studio、Jan、Open WebUI 等模型与本地 Runtime 产品；ComfyUI、LangGraph Studio、n8n、Flowise、Dify、Node-RED 等图产品；GPT Builder／Store、VS Code Extensions、Raycast Store、Home Assistant Integration、Obsidian Plugin 等扩展生态；以及 Things、Linear、ChatGPT、GitHub Mobile、Raycast 等成熟跨设备产品。

Reference Matrix 记录截图或来源链接、目标用户、信息架构、Onboarding、导航、任务输入区、Harness／模型／账号层级、安装与认证、配置披露、图交互、创建与发布、空白／加载／错误／离线状态、移动端适配、Accessibility，以及具体采纳或拒绝的模式。它是决策证据，而不是复制品牌或视觉的许可。每个选定的 OpenFish 方向都要给出与最强相关参考的并排理由。

重设计覆盖完整 Mac 和 iPhone 产品：Onboarding、Landing、Sidebar 与任务组织、New Task、任务 Transcript、Composer、Approval 与 Question、Harness 选择、模型与账号、权限、Installer 与 Authentication、No Project、Settings、Remote Pairing、Notification、各 Graph Lens、Builder 与 Catalog、Voice、Search、Empty State、Progress、可恢复与致命错误、Offline 与 Reconnect、Update 和破坏性操作确认。

共享 Design System 定义 Typography、Spacing、Color、Elevation、Material、Icon、组件状态、Motion、文案语气与响应式行为。Mac 尊重键盘、Pointer、窗口缩放、Focus、Menu 和信息密度；iPhone 尊重触控尺寸、Safe Area、Dynamic Type、导航深度、中断、后台和单手操作。两端都支持本地化、Contrast、VoiceOver 阅读顺序与 Label、Reduced Motion、清晰 Focus 和语义化错误播报。只有经过设备测试后才能宣称 Accessibility。

现有具体缺陷继续作为 Release Regression：Onboarding 不得默认 Architecture；非 DSH 任务不得声称“work through DSH”；Host 与 Harness 标签不得混成 Local DSH；Active Harness 不得只用图标表示；Composer 不得拥挤或裁切 Selector；Caret 与 Placeholder 必须从预期 Inset 开始；Light Appearance 必须可读；iPhone Graph Chip 与 Edge 不得裁切；Builder Handoff 与 Install Action 必须说明真实效果；No Project 不得变成 Other；每个模型、思考强度、账号、Workspace 与权限选择必须持续可见且可操作。

## 跨设备、语音与安装产品行为

Mac Host 与 iPhone Client 通过可信 LAN 或 Tailscale 完成 Pair、Revoke、Discover、Reconnect 和操作，不能把 Host 暴露到公网。手机显示与 Mac 相同的 Session、Harness、模型、账号模式、Approval、Question、Queue 和兼容事实。离线操作和并发编辑具备明确的 Queue、Conflict、Retry 和 Cancel 行为。Credential 与 Pairing Token 保留在 Keychain，Diagnostics 默认脱敏主机名与私密内容。

语音输入必须承受反复 Start／Stop、权限允许、拒绝后再撤销、音频中断、Route 与设备变化、前后台切换、网络丢失，以及任务或 Harness 切换。UI 解释识别是 On-device、由操作系统处理中介，还是 Cloud-assisted；当平台可能向外发送音频时不得宣称仅本地处理。除非用户明确选择其他模式，只有用户确认后的最终文本才能进入任务。

Build Artifact 不能被当成已安装更新。Release 验证使用 Applications 中唯一一个拥有正确图标、Bundle ID、签名身份和 LaunchServices Registration 的当前 OpenFish App，以及预期的 iPhone 或 TestFlight Build。从开发 Bundle ID 迁移时保留兼容 Preference 与 Session，同时避免 Dock、Spotlight 或 Applications 出现重复结果。

## Demo 与公开展示

Mac 和 iPhone 都有确定性、网络隔离的 Demo State，其中包含合成 Project、Session、账号、模型、Graph Evidence、Error、Approval 和 Conversation。Demo Mode 不读取个人数据、不使用真实凭证、不连接 Host 或 Provider、不缓存发现结果、不请求语音权限，也不写入 Production State。界面必须清楚标识这是 Demo Data。

公开材料包括 OpenFish 图标、经过隐私检查的 Mac 总览、iPhone 连续性视图、Harness 选择与设置、真实的 Architecture 与 Runtime 视图、Builder／Test／Publish 流程，以及一张解释 Host、Harness、Account／Provider 和设备的简洁图。截图从确定性 Fixture 生成，裁掉无关窗口，移除 Metadata，并经过文字与图像隐私检查。短视频或动态演示只能在底层流程稳定后作为可选项加入。

README 说明支持平台、准确的 Release 基线 Harness、兼容等级、安装、认证与费用归属、安全边界、限制、Roadmap 标签、贡献路径、License 和可复现 Quick Start。它绝不能暴露个人路径、电脑名、项目、账号、Token、截图或 Git History。

## P0 验收契约：安全的 Public Alpha

只有主要 Public Alpha 路径端到端工作，且 Release 没有虚假核心声明时，P0 才算完成。

1. 一台没有任何外部 Runtime 或 Harness CLI 的全新受支持 Mac 可以安装签名并公证的 OpenFish Build，选择默认 Harness，完成明确认证和模型设置，启动 Project 与 No Project 任务，恢复任务，修改默认值，并使用另一个 Harness 新建任务。
2. DSH、Codex 和 OMP 分别通过安装、认证、实时模型发现、模型选择、受支持思考强度、发送、工具与审批流、取消、恢复、归档、更新、回滚和可操作失败恢复。Codex 在受支持时分别证明 ChatGPT Subscription 和 API Billing 路径，且不自动处理或暴露用户 Secret。
3. 任意兼容 ACP Registry Pack 都可在不修改原生 UI 的情况下出现；一个全新的合成 ACP Pack 从发现到恢复全程通过；不兼容或错误 Pack 在启动前给出准确拒绝原因。
4. Composer 和 Settings 始终区分并显示 Host、Harness、Account、Provider／Model、Reasoning、Workspace 与 Permission。No Project 使用专属存储，并在 Mac 和 iPhone 上支持完整 Session 生命周期。
5. Simple 与 Architecture 视图对 DSH、Codex、OMP、Opaque Harness 和合成 Pack 都有证据且有用。Declared 与 Observed 事实清楚区分。Mac Manifest Editor 可以创建、验证、测试、导入并无凭证导出一个可运行自定义 ACP Pack；超出这些语义时，对外文案不能称其为可执行 Builder。
6. 在重设计后的 Mac 与 iPhone P0 流程验收前，行业 Reference Matrix 与选定设计方向已经存在。核心流程覆盖所有 Loading、Empty、Setup-required、Offline、Recoverable-error 和 Fatal-error 状态，并通过各平台适用的 Keyboard、VoiceOver、Dynamic Type、Contrast、Resize 和 Touch-target 检查。
7. 真实 Mac 与 iPhone 验证覆盖 Pair、Disconnect／Reconnect、Approval、Question、任务连续性、语音 Allow／Deny、反复使用语音、前后台和 Remote Revoke。每台测试 Mac 只保留一个可被发现且品牌正确的 OpenFish 安装。
8. 自动化 Contract、Integration、Packaged-runtime、Migration、Native UI 与 Regression Check 覆盖已报告失败：缺少 Injected Tools、Persona Mount 失败、ACP Connection Closed、缺少 Provider／Model、模型 Selector 消失、Reasoning Selector 消失、Caret Inset 错误、No Project 创建失败、App Identity 重复、手机连接丢失和语音崩溃。
9. Release Tree 与 Git History 通过 Secret Scan、人工审核误报、截图 OCR 与 Metadata 检查、Binary 与 Archive 检查、Dependency License Review、Third-party Notice 和 Credential／Log 脱敏检查。Threat Model 覆盖 Harness Supply Chain、Process Authority、本地网络暴露、Credential、Diagnostics 和社区发布。
10. Source Tree 干净，Public GitHub Remote 与 History 只包含批准内容，Release Artifact 已签名并公证，Checksum 与 Provenance 已发布，Install／Uninstall 指南通过验证，公开截图与声明和测试 Build 一致。

## P1 验收契约：完整产品承诺

P1 包含超出 Public Alpha 最小路径的所有明确产品需求。P0 Release 不代表 P1 已完成。

1. 一个新的非 ACP 协议 Driver 插件通过 Public SDK 与 Conformance Suite，且无需修改原生客户端、公共 Session 代码或现有 Driver；Version Negotiation 与不兼容 Upgrade 有已测行为。
2. Runtime Observability 在保护隐私的同时把真实任务活动关联到有证据的节点，Graph Interaction 在 Mac 和 iPhone 上对有代表性的小、中、大 Manifest 均可用。
3. 可执行 Builder 使用 Typed Node 与 Port 创建新的可运行 Harness 项目，验证配置和 Secret Reference，执行隔离 Dry Run 与 Conformance Suite，显示 Live Trace，支持 Undo、Redo、Diff、Import、Export 和 Versioning，并且只通过声明的 Driver 语义改变行为。
4. In-app Publication 把无凭证 Pack 提交到可运行的 Catalog 流程，并展示 Validation、Review、Publisher、Provenance、Compatibility、Version、Update、Rollback、Report、Removal 与 Revocation 状态。Community Trust Signal 在没有证据时绝不能暗示安全背书。
5. 完整 Mac 与 iPhone Screen／State Inventory 使用选定 Design System，并通过支持的 OS、Architecture、Window Size、Appearance、Localization、Accessibility、Network、Account 与 Device Matrix。Mac-only 操作在 iPhone 上使用清楚 Handoff，而不是缺失或误导的控件。
6. Clean-machine 与 Chaos Coverage 包含受支持时的 Apple Silicon 与 Intel、Fresh 与 Upgraded State、No Dependencies、Corrupt Download、Registry Outage、Authentication Expiry、Provider Quota Failure、Harness Crash、Host Restart、ACP Protocol Violation、Network Partition、Low Disk Space、Permission Change、Interrupted Update 和 Concurrent Device Action。
7. 公开价值证据报告 Time to First Successful Task、Harness Setup／Switch Success、Resume Reliability、Setup-failure Recovery、Graph Comprehension、Custom Pack Creation Time 与任务层质量对比，而且不把 Harness 性能和 OpenFish Compatibility 混为一谈。

## 执行顺序与证据

工作按依赖关系推进，而不是优先做容易看见的视觉改动。首先固定真实声明、产品术语、Capability Contract、测试 Harness 和支持的 Release Matrix；随后完成 Clean Install、认证、模型与会话正确性、No Project 和 Driver Conformance；接着产出 Industry Reference Matrix 与 Design Direction，实现完整 Mac／iPhone State Inventory，并完成真实设备连续性和语音行为；Architecture Observation、Executable Builder、Publication 与 Marketplace Trust 建立在这些契约之上；Security、Privacy、Packaging、Migration 与 Release Evidence 最后闭环。

每个验收项都链接到持久实现证据：所属代码或协议、聚焦的自动化检查、必要时的 Clean-machine 或真实设备结果，以及它允许使用的准确公开声明。测试数量本身不能证明覆盖，Simulator Build 不能证明真实设备行为，合成 DSH 行为不能证明 Codex 或 OMP，成功打包也不能证明已安装 App 更新。

## 曾考虑的替代方案

**逐个修报告的 Bug 然后快速发布。** 这种方式保留隐藏假设，并迫使用户成为兼容性测试套件，无法支持通用壳子声明。

**把最热门 Harness 写死。** DSH、Codex 和 OMP 是必要 Release 基线，但产品专属分支会让未来 Harness 变得昂贵，并导致原生客户端、模型、认证和会话持续漂移。

**把每个 CLI 都当成自动兼容。** 名称或可执行路径不能定义协议、会话语义、权限或配置。OpenFish 只能自动化受支持 Driver 契约，并在需要 Adapter 时明确说明。

**从营销描述绘制通用内部图。** 这样会产生漂亮但错误的架构。以证据支撑的 opaque、observable 和 composable 层级既诚实又仍有用。

**复制一个成功产品的 UI。** 没有任何单一参考同时覆盖原生连续性、Coding Agent 会话、图编辑、安装和 Marketplace Trust。跨类别 Evidence Matrix 能支持一致产品，而不复制另一品牌。

**把当前仓库发布成完整生态。** 代码是有意义的实验工作，但当前安装、Release、设备、可扩展性、Builder、安全和 UI 证据不足以支持该声明。

## 验收标准

- 在被另一个经过审核的 Agent Note 取代之前，本 Note 始终是完整范围 Owner；后续 Task Plan 必须链接到这里，不能静默省略未完成的 P0 或 P1。
- 实现报告必须明确区分已验证、已实现但未验证、尚未实现，并说明因此允许使用哪些公开声明。
- 在每个 P0 项都针对 Release Artifact 通过、Privacy Review 完成、Public Remote 正确，并且用户查看最终证据和声明后授权发布之前，不得公开 Release。
- 声称“完整产品”除 P0 外还必须完成所有 P1；Public Alpha 必须清楚说明剩余 P1 限制。

## 风险

- 广泛契约可能变成无限工作，因此实现必须围绕 P0 端到端路径排序，并在每个依赖闭环时记录证据。
- 第三方 Harness 协议、认证、Package 和 Model Catalog 变化很快；Version Pinning、Capability Negotiation、Conformance Fixture、Compatibility Label 和 Rollback 只能降低风险，无法完全消除。
- 强 Graph 与 Marketplace 声明会引入不安全推断和 Supply-chain Trust；即使增加使用摩擦，Evidence Level 以及彼此分离的 Provenance、Compatibility 与 Security 事实也必须始终可见。
- 精美 Demo 可能掩盖 Live Behavior 薄弱；确定性 Fixture 只是展示工具，绝不能替代 Clean-machine、真实 Harness、真实设备或 Failure-path Test。
- macOS 与 iPhone Parity 可能变成虚假的对称；明确的设备职责和 Handoff 优于存在却不能在该设备上工作的控件。

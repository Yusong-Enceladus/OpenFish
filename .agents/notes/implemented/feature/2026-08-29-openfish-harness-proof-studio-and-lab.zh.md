# Agent Note：OpenFish Harness 证据、Studio 与 Lab

Status: implemented

[English](2026-08-29-openfish-harness-proof-studio-and-lab.md) | 中文

## 问题

OpenFish 已经能够安装和运行多个 Harness、把实时配置投影到原生客户端、保留精确 Pack 版本，并展示 Manifest 图，但这些能力本身还不能证明产品的核心声明。一个兼容标签可能掩盖 OpenFish 究竟只是解析了 Pack、找到了可执行体、启动了协议，还是完成了真实会话。后一次 Preflight 可能覆盖更强的会话证据，一个 Pack 版本的证据也可能被误读成另一个版本的证据。

架构界面存在同样的歧义：Pack 编写的图、实时 Trace 与 Host 兼容结论虽然相邻，却没有共同的证据契约。桌面坐标直接挤进 iPhone 后难以阅读。Studio 虽然已经能够编辑真正由 Driver 支持的控件，却没有清楚区分非变更式准入、精确安装、实时 Preflight 与真实任务观察。

最后，“哪个 Harness 最好”仍只能靠印象回答。壳的兼容性不是任务质量，仓库热度不是任务质量，一次成功 Prompt 也不是排行榜。OpenFish 需要一条可检查的比较路径，同时不能收集回答内容或暗中消耗提供方额度。

## 决策

### 精确版本 Proof Ledger

每个 Catalog 条目现在都带有五类相互独立、由 Host 推导的事实：

1. **Declared** 表示 Pack 及其 Graph 通过准入；它不验证发布者的架构声明。
2. **Resolved** 表示精确的可执行体和安装身份；版本固定不会被冒充成校验和验证。
3. **Observed** 表示该精确 Pack 版本真实完成或失败的 Create、Resume 或 Fork；只保留操作元数据，绝不保留任务内容。
4. **Evaluated** 表示得出兼容结论的确切 Host 操作：内置契约、Driver 准入、实时 Preflight、Create、Resume 或 Fork。
5. **Opaque** 表示私有内部仍然是一个明确边界，而不是 OpenFish 编造出来的图。

Harness 状态升级到版本 8，按精确 Pack 版本和操作依据保存证据。迁移时，v8 以前没有来源的兼容结果保守地归为 Driver 准入。更新、回滚和重启都会保留旧版本证据。后一次 Preflight 可以改变最新兼容结论，却不能删除真实会话观察；版本 A 永远不能认证版本 B。只有所有适用事实都已验证时才显示 Fully Verified；支持观察能力但尚未运行，不能冒充已观察。

Pack Graph Evidence 仍只允许 `declared`、`resolved` 或 `observed`。`evaluated` 只属于 Host Proof Ledger，因此不受信任的 Pack 不能自己编写兼容结果。旧的 `source-derived` 和 `runtime-observed` Manifest 仍可读取，并归一化到新词汇，避免已经固定的任务失效。

### Progressive Lens 与窄屏 Map

Mac 和 iPhone 使用相同的四个 Lens：Overview、Map、Trace 和 Studio。Overview 首先展示 Proof Ledger。Map 是默认架构视图，展示所有声明关系；Stage Summary 只是辅助阅读方式。Trace 仍是与已声明节点和边关联的、有序、有界、无内容记录。Studio 负责创作与发布语义。

内置 DSH、Codex 和 OMP Manifest 现在带有有意设计的坐标，不再依赖源码数组顺序。 Mac 画布保留这些坐标以及完整节点点击区域、选择、搜索、键盘焦点、缩放和平移。 iPhone 不再压缩桌面画布：它保留编写者的纵向 Band 或推导出的依赖 Level，并把每个 Band 拆成每行最多两个完整尺寸的 Card。选中组件后只高亮它声明的 Route，精确的输入和输出关系 Label 放在组件检查区，而不是遮住节点或交叉线。拓扑和证据完全共享，阅读布局则适配设备。

Demo Fixture 从同一份内置 Manifest 重新生成，并明确标记为 Partially Verified 的 Demo Ledger。合成 Trace Event 只用于演示交互，绝不会伪装成真实提供方或兼容运行。

### Studio 证据阶段

Studio 新增 Review 页面，展示 Material Change、不可变的 Draft／Installed／Retained 版本线，以及四个证据阶段：Draft Admission、精确安装、无 Prompt 的实时 Preflight、真实任务观察。

`validate-draft` 是 Host 本地、不会改变状态的操作。它运行 Pack Schema 与自定义 Pack 准入，但不新增 Catalog 条目、不安装代码，也不启动 Harness。Save 是独立变更操作。 Install 与 Live Preflight 仍然显式执行，并遵循普通 Harness Setup 相同的代码授权和精确版本边界。已安装版本发生行为变化时，必须先修改版本号。已有的 Driver 类型化 Binding、Secret Reference 校验、Undo/Redo、Diff、Import/Export、Live Preflight、版本保留和 GitHub Review 发布仍构成可执行的 Studio 契约；不受支持的节点绝不会被包装成可以改变行为的控件。

### Harness Lab

Harness Lab 为两个或更多已安装、已认证的 Harness 准备独立 No Project Session，并发现每条 Route 的实时 Account Label、Model Catalog、模型专属 Reasoning 值与 Permission 选项。它顺序发送同一条明确任务，按 Round 轮换顺序，支持重复次数和超时，绝不代替用户回答 Approval Request，并保留每个任务供普通界面检查。所选权限模式仍可能允许某项操作无需询问，因此每项结果都会保留精确模式。

结果把机械事实——Terminal Reason、耗时、首个输出、Tool／Approval 数、提供方上报 Token 与最终答案长度——同用户明确填写的评分和私有备注分开。它不计算全局分数，也不宣布胜者。Prepare 不发送 Prompt；Run 会明确提醒所选订阅或 API Route 可能消耗额度。

可选 JSON 报告排除 Session ID、回答文本、Account Label、路径和本地 Task ID。 Task 文本和私有备注默认排除，并各自需要单独选择；诊断信息和可选备注在本地经过脱敏。报告会记录精确 Harness／Model／Reasoning／Permission Route、运行顺序、重复次数、失败、测量值和统计局限。

## 考虑过的替代方案

**只使用一个绿色兼容标签。** 拒绝，因为它把 Manifest 准入、可执行体身份、启动就绪与真实会话证据混为一谈。

**把成功 Preflight 当成任务观察。** 拒绝，因为不带 Prompt 的协议初始化无法证明模型推理、工具、Resume 或回答质量。

**允许 Pack 声明 Evaluated Evidence。** 拒绝，因为兼容性是 Host 拥有的结论，不是发布者编写的 Graph 元数据。

**把 Mac Graph 压缩到 iPhone。** 拒绝，因为可读 Label 和 Touch Target 比保持展示坐标更重要；手机保留拓扑，而不是桌面几何。

**根据社区热度或单个用户的 Run 发布 Harness 排行榜。** 拒绝，因为 Account、Model、设置、Task、重复次数、Failure 与主观质量都会显著改变结果。Lab 提供可检查实验，而不是虚假的通用排名。

**为了可复现而自动导出 Prompt 和回答。** 拒绝。原始任务仍可在本地检查，比较报告默认无内容，只有用户明确同意后才包含 Task 文本。

## 后果

新准入或新安装的 Harness 通常会显示 Partially Verified，直到真实证据存在。这是有意保留的摩擦：可发现性和 Driver 准入都有价值，但二者都不是已完成任务。

后一次失败的 Preflight 可以让当前兼容结论变成失败，同时较早的成功 Session 仍作为独立 Observed Fact 可见。消费者必须阅读 Ledger，不能从一个颜色推断所有时间线。

未知的私有 Harness 仍可通过安装、认证、配置、兼容性、Trace 和诊断发挥作用，但其内部 Map 保持 Opaque。丰富 Graph 必须有 Pack Evidence，不能从 Harness 名字生成。

Harness Lab 可能消耗提供方额度，也无法让异构 Harness 在科学意义上完全相同。它的独立 No Project Session、精确 Route、轮换顺序、重复运行、保留 Task 与明确局限，使比较可以审计，同时不宣称超过实验本身能够证明的内容。

## 测试

ACP 使用 SDK 客户端应用的类型化请求与通知处理器，并明确拥有持久连接。合成的未来 Harness 测试服务使用对应的 Agent 应用 API。发布检查分别验证运行时协议行为、静态类型与硬件结果；禁用弃用 API 或不安全值规则只会隐藏协议边界的维护问题，不能证明兼容。

后续 SDK 迁移已通过 Host 类型构建、全仓 Lint、全部 253 项 Harness Contract 和 21 项协议传输测试。子进程测试服务分别覆盖 `session/resume` 与 `session/load`，以及按能力声明开放的远端删除和关闭。删除远端 Session 后必须清除其身份，避免销毁连接时再次关闭已经删除的 Session。

聚焦 Contract 覆盖非变更式 Draft 准入、精确版本证据在 Preflight、Update、Reload 和 Pinned Lookup 之间的保留，以及 Controller Routing。完整验证已经通过全部 250 项 Harness Contract、TypeScript Type Check、Mac 与 iPhone Simulator Debug Build、Mac Map／Trace／Studio／Builder／Lab 聚焦 UI 测试，以及 iPhone Map／Trace UI 测试。测试后还逐张检查了 Mac 与 iPhone Map 截图：Graph 文本不再覆盖节点，精确关系仍可在选中组件检查区读取，Demo Lab Route 也明确保持 Synthetic 与 Offline 标识。

生成的 Codex API Catalog 和确定性 Mac／iPhone Demo Catalog 均来自更新后的 Type 与实时 Pack Manifest。公开源码隐私 Gate、源码 Release Gate、独立 Host Smoke 与未签名 arm64 Release 产物已在生产原生修改后通过检查。物理设备的麦克风与后台恢复检查独立于 Simulator 覆盖；XCTest Runner 连接失败不能被报告为 UI 测试通过。

Debug 硬件检查为每次运行保留带时间戳、无内容的历史，不复用最后一次成功字符串。连接检查等待基线完整刷新，包括任务和模型恢复。No Project 检查遇到未发送草稿时拒绝继续，不创建模型轮次，并在系统真实触发的后台／前台切换后检查同一个任务、Harness、模型与思考强度是否保留。

物理 iPhone 已通过五次麦克风启停、真实 Host 连接处理恢复，以及切到系统设置后在同一进程返回时的 No Project 任务／模型恢复。这些检查不发送模型提示词。物理 XCTest Runner 因 DTX 控制通道被拒绝，在启动任何测试用例之前以状态码 74 退出；直接硬件检查不代表物理 UI 点击或布局已经通过 XCTest。

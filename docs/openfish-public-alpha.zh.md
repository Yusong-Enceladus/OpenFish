# OpenFish Public Alpha

[English](openfish-public-alpha.md) | 中文

这个版本面向能够检查 Agent 行为并报告故障的开发者和早期用户；它还不是可无人值守运行的稳定编程产品。

## 已经可用

- 自包含 macOS App，内置打包后的 DSH Host 与托管式 Harness Runtime。
- 安装级默认 Harness 选择，以及每个任务独立选择 Harness。
- No Project 任务存储在 OpenFish 专用位置，而不是 Desktop。
- 由协议驱动的 ACP 模型、思考强度、模式与配置控件。
- Mac 与 iPhone 使用 Progressive Harness Lens 展示 Harness：面向普通用户的 Overview、有证据支撑的关系 Map、有界有序且无内容的 Trace，以及由 Driver 支撑的 Studio。点选组件可把轨迹过滤为实际经过它的步骤。Studio 支持类型化 Graph 控件、撤销／重做、重大变更 Review、不会写入状态的准入 Dry Run、准确版本安装／实时 Preflight、版本保留、导入与无凭证 Export。实时 Preflight 仍可能创建 Provider 自己的状态或产生其定义的初始化成本。
- 每个准确 Pack 版本都有可见证据账本，分别记录已经准入的声明、解析后的可执行身份、真实 Session Operation Observation、Host 兼容性评估与明确的 Opaque 边界；后续 Preflight 既不能抹掉 Session 证据，也不能认证另一个版本。
- 本地 Harness Lab 可让两个或更多已安装 Harness 在隔离的 No Project Session 中运行同一项明确任务，并为每条路线选择实时模型、思考强度、权限、轮换顺序、重复次数与超时。OpenFish 绝不代替用户回答 Approval Request；所选权限模式仍可能允许某项操作无需询问。Lab 保留每项任务供检查，把机械测量与用户质量评分分开，Export 也不包含 Response、账号或路径内容。
- 生成式社区 Pack 目录；通过 Pull Request 发布，无需等待 OpenFish App 发版。
- 面向公开非 ACP Pack 的准确自安装 Driver Bundle 描述。用户明确同意本地执行代码后，Mac App 会使用随 App 打包的 Node／npm Runtime 暂存并结构化校验准确 Bundle，只重启自己验证过的内置 Host，协商 Driver API v1 后继续配置；iPhone 会把这项操作交给已配对 Mac。
- 会话固定到创建任务时使用的 Harness Pack 版本。
- 原生 iPhone 配对、通过认证的实时自动重连、任务投影、审批、队列与语音输入。
- 已实现针对 DSH、官方 Codex app-server 协议、OMP 的 ACP 行为、全新合成 ACP Pack、打包 Host 生命周期、隐私、macOS 构建与 iOS Simulator Build 的发布门禁。真实 iPhone 清单属于单独的手工 Release Evidence；源码不会把 Simulator 冒充真机证明。

## 已知限制

- 支持基线为 macOS 14 及以上、iOS 17 及以上。
- 源码构建不带签名。只有仓库所有者配置 Apple 发布凭证后，带标签的 Mac 产物才会签名并公证。
- 在公开 TestFlight 或 App Store 渠道可用前，真机安装 iPhone App 需要用户自己的 Apple 签名配置。
- 仅仅通过源码编译不能让 Tag 获得发布资格。Pair、Reconnect、Approval、Question、连续性、麦克风允许／拒绝、反复启停语音、前后台恢复与远端 Revoke 必须针对最终 Mac Build 和真实 iPhone 留下记录。
- 独立 OpenFish 默认使用 `app.openfish.mac` 与 `app.openfish.ios` Bundle ID，发布者可以覆盖。Mac App 会迁移旧 DSH 开发 ID 下的 Alpha 偏好与远程凭证；以旧 ID 安装的 iPhone App 需要重新配对。
- 配对通过可信 LAN 或 Tailscale 直连。OpenFish 不运营中继服务，也不得将 Host 端口暴露到公网。
- 任务启动后不能更换 Harness；它会保留创建时选择的准确 Pack 版本与认证引用。
- OpenFish 从实时 Harness 发现 ACP 配置。如果 Harness 没有发布模型或思考选项，OpenFish 不会靠猜测厂商私有参数来伪造控件。
- Harness Lab 会使用所选账号并可能消耗 Provider 额度。它是实验工具，不是全球排名；有意义的公开比较仍需披露任务、准确版本、设置、账号／计费模式、重复次数、失败与脱敏结果。
- 认证与用量费用归所选 Harness／Provider。OpenFish 必须在启动前展示认证方式，但它不提供模型额度，也不会把一家 Provider 的订阅静默转换为另一家额度。
- 内置 Codex 与 OMP Pack 使用经过本次 OpenFish Release 验证的准确版本。公开 Registry 的 `latest` Tag 变化不会原地改写这份可信契约；后续 OpenFish Release 会显式提供 Pack 更新，同时保留已安装版本供回滚和旧任务固定使用。
- 对 Codex，OpenFish 会向实时官方 app-server 查询当前认证路径与计划类型，并丢弃邮箱和凭据材料。只有所选 Driver 能创建真实远端分支时才会提供任务分支；Codex 映射到官方 `thread/fork`，通用 ACP 当前保持禁用。
- ACP Registry 或 OpenFish 社区目录收录只是发现元数据，不代表安全审计或质量背书。非 ACP Harness 必须发布固定来源的 Driver Bundle，而且只有实时 Driver Conformance 通过后才能运行；OpenFish 不会只根据协议名或 Harness 名猜出并执行代码。
- 社区发布目前通过受审核的 GitHub Pull Request 完成；OpenFish 尚未运营 App 内账号、排行系统或一键式 Marketplace 后端。
- ACP Pack 使用类型化控件，其 Driver 绑定会指向运行中 Harness 实时发现的 Option ID。其他节点配置只有在对应 Pack 的 Driver 会验证并消费时才具有执行语义；编辑器会标明不受支持的字段，而不会假装它们能够运行。
- ACP 当前没有永久删除远端 Session 的标准操作。放弃一个已准备的通用 ACP 任务时，OpenFish 会停止受管进程并删除本地空白草稿，但上游 Harness 仍可能保留自己的空白 Session 记录。Codex Driver 会对等价的空白 Thread 调用官方 `thread/delete`。
- 未知 Harness 的内部结构始终只显示一个 opaque 边界。丰富 Architecture 视图必须声明进程边界、连通实际展示的全部职责、为每个组件提供证据，并使用有意义的图边标签。系统不设置装饰性的最少节点数，UI 也不会猜测私有内部结构。
- 新操作系统可能无法继续安装旧任务固定的 Runtime，从而暴露上游兼容性破坏。请导出重要工作。

## 五分钟验收

1. 在 `PATH` 中没有 Node、Bun、uv、DSH、Codex 或 Pi 的 Mac 上启动 App，并选择默认 Harness。
2. 分别创建一个 No Project 任务与项目任务；确认存储位置不同，而且创建均不报错。
3. 新建任务、更换 Harness；当实时 Harness 发布模型、思考强度与权限模式时，分别选择后发送 Prompt。
4. 重启 App 并恢复两个任务；确认各自保留 Harness Pack 版本与配置。
5. 通过 LAN 或 Tailscale 配对 iPhone，读取任务、发送追问，并批准或拒绝一次操作请求。

任何一步失败都请使用 OpenFish Bug 模板报告。只提供第一条脱敏错误，绝不包含凭证或私密会话内容。

# OpenFish Public Alpha

[English](openfish-public-alpha.md) | 中文

这个版本面向能够检查 Agent 行为并报告故障的开发者和早期用户；它还不是可无人值守运行的稳定编程产品。

## 已经可用

- 自包含 macOS App，内置打包后的 DSH Host 与托管式 Harness Runtime。
- 安装级默认 Harness 选择，以及每个任务独立选择 Harness。
- No Project 任务存储在 OpenFish 专用位置，而不是 Desktop。
- 由协议驱动的 ACP 模型、思考强度、模式与配置控件。
- Mac 与 iPhone 上按真实性等级展示 Harness 图，并在 macOS Harness Studio 中创建自定义 Pack、编辑图、导入和无凭证导出。
- 生成式社区 Pack 目录；通过 Pull Request 发布，无需等待 OpenFish App 发版。
- 会话固定到创建任务时使用的 Harness Pack 版本。
- 原生 iPhone 配对、任务投影、审批、队列与语音输入。
- 针对 DSH、Codex ACP、兼容 Pi 的 ACP 行为、打包 Host 生命周期、隐私、macOS 构建与 iOS Simulator 构建的发布门禁。

## 已知限制

- 支持基线为 macOS 14 及以上、iOS 17 及以上。
- 源码构建不带签名。只有仓库所有者配置 Apple 发布凭证后，带标签的 Mac 产物才会签名并公证。
- 在公开 TestFlight 或 App Store 渠道可用前，真机安装 iPhone App 需要用户自己的 Apple 签名配置。
- 独立 OpenFish 默认使用 `app.openfish.mac` 与 `app.openfish.ios` Bundle ID，发布者可以覆盖。Mac App 会迁移旧 DSH 开发 ID 下的 Alpha 偏好与远程凭证；以旧 ID 安装的 iPhone App 需要重新配对。
- 配对通过可信 LAN 或 Tailscale 直连。OpenFish 不运营中继服务，也不得将 Host 端口暴露到公网。
- 任务启动后不能更换 Harness；它会保留创建时选择的准确 Pack 版本与认证引用。
- OpenFish 从实时 Harness 发现 ACP 配置。如果 Harness 没有发布模型或思考选项，OpenFish 不会靠猜测厂商私有参数来伪造控件。
- 认证与用量费用归所选 Harness／Provider。OpenFish 必须在启动前展示认证方式，但它不提供模型额度，也不会把一家 Provider 的订阅静默转换为另一家额度。
- ACP Registry 收录只是发现元数据，不代表 OpenFish 安全审计或质量背书。非 ACP Harness 仍需 Driver 插件。
- 社区发布目前通过受审核的 GitHub Pull Request 完成；OpenFish 尚未运营 App 内账号、排行系统或一键式 Marketplace 后端。
- 通用执行语义只覆盖可编辑 composable 节点中的 `acpSessionOptions`；除非该 Pack 的 Driver 实现了其他配置，否则其余节点配置只用于描述。
- 新操作系统可能无法继续安装旧任务固定的 Runtime，从而暴露上游兼容性破坏。请导出重要工作。

## 五分钟验收

1. 在 `PATH` 中没有 Node、Bun、uv、DSH、Codex 或 Pi 的 Mac 上启动 App，并选择默认 Harness。
2. 分别创建一个 No Project 任务与项目任务；确认存储位置不同，而且创建均不报错。
3. 新建任务、更换 Harness；当实时 Harness 发布模型和思考强度时，分别选择后发送 Prompt。
4. 重启 App 并恢复两个任务；确认各自保留 Harness Pack 版本与配置。
5. 通过 LAN 或 Tailscale 配对 iPhone，读取任务、发送追问，并批准或拒绝一次操作请求。

任何一步失败都请使用 OpenFish Bug 模板报告。只提供第一条脱敏错误，绝不包含凭证或私密会话内容。

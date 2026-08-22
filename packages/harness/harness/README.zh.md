# `@deepseek-ai/dsh-harness`

[English](README.md)

Open Fish 使用此包作为可互换 Agent Harness 的控制平面。Harness Pack v0 声明稳定身份、协议、启动分发、发布者元数据和架构图。壳子不会猜测 Harness 的私有内部结构：图级别分为 `opaque`、`observable` 和 `composable`，只有显式标记为可编辑的节点才能变成控件。

内置 `dsh` Pack 始终可用。目录会在启动时获取官方 ACP Registry，并把每个兼容的 npx、uvx 或平台二进制 ACP 条目映射成 Pack；因此目录并不只包含名称里有“Harness”的产品。Open Fish 另外维护尚未进入该 Registry 的 Oh My Pi。部署方可以通过配置加入用户 Pack，原生编辑器也能按身份、分发方式、协议和可拖拽组合图创建 Pack。新增另一个 ACP Pack 不需要修改壳子；新协议只需针对同一公开 SDK 注册一个 `HarnessDriver`。

`registryUrl` 默认指向带版本的 ACP Registry 端点。Registry 失败采用降级策略：上次成功的 Registry 目录、内置、已安装和用户 Pack 仍可用。服务在 `$DSH_HOME/openfish/harnesses` 下持久化用户明确选择的跨设备默认项、用户定义、非秘密认证选择、活动版本，以及仍被会话引用的所有版本。全新状态没有默认 Harness，原生首次引导必须询问用户。安装、更新、回滚、卸载和删除自定义 Pack 均串行执行并原子写入。

Pack v0 支持固定版本的 npm、Bun 和 Python／uvx 包、带校验和的平台二进制，以及由用户明确选择的现有可执行文件。ACP 认证契约从已安装 Harness 动态发现：Agent／浏览器登录仍由 Harness 所有；环境凭证只进入 Open Fish 的只写凭证库，并只注入对应进程；终端登录只会在用户明确操作后启动。Registry 收录状态与 Open Fish 实际运行兼容性分开呈现。会话成功启动后记录兼容；失败则记录经过脱敏、可用于恢复的诊断。

架构图是一份真实性契约，而不是猜测私有内部后的装饰。`opaque` 只展示运行边界，`observable` 描述真实数据流，`composable` 只允许编辑 Pack 明确标为 `editable: true` 的节点。自定义 Pack 可给这些节点附加任意 JSON 配置。Manifest 准入会拒绝未知 schema 版本、非法身份、非法认证契约、缺少非 DSH 分发信息的 Pack，以及悬空图边。

## Model Experience

### Harness 选择记录

#### 模型看到什么

不会直接看到任何内容。协议 Driver 按协议注册，并随其 Cordis effect 生命周期卸载；`harness/selected` 和 `harness/native-event` 则保留为 Host 侧会话记录。

#### Token 影响

无。此包不贡献提示词、工具 schema 或工具结果。

#### KV Cache 影响

无。Harness 身份记录不会进入 DSH 模型请求。

## 扩展 Open Fish

可从 [`examples/custom-acp.pack.json`](examples/custom-acp.pack.json) 开始，并使用
[`schema/harness-pack-v0.schema.json`](schema/harness-pack-v0.schema.json) 校验编辑器或工具输出。
Runtime 还会进行节点／认证 ID 唯一、图边不悬空和包版本精确固定等语义检查。

- 发布进官方 Registry 的 ACP Harness 无需等待 Open Fish 发版即可出现。其分发必须固定版本；缺少 SHA-256 的 Registry 二进制会显示，但安装会被拒绝。
- 自定义 ACP Pack 走同一套原生编辑器路径。包、参数、环境、认证与图配置都是 Pack 数据，而不是应用里的提供方专属分支。
- 新的非 ACP 协议仍需 Driver 插件；壳子、Session API、目录 UI、安装状态和图编辑器无需加入提供方分支。
- Registry 元数据是传输层权威的目录数据，不代表 Open Fish 已审计发布者或包内容，因此设置页会分别显示 Registry 状态与 Open Fish 兼容状态。

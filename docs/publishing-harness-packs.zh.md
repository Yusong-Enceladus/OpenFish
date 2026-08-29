# 发布 OpenFish Harness Pack

[English](publishing-harness-packs.md) | 中文

本教程把不含凭证的 Harness Pack 发布到 OpenFish 社区目录。目录只提供发现元数据，不代表 OpenFish 的安全背书。

## 前置条件

- Harness 支持 ACP、OpenFish 已经包含其协议对应的 Driver，或者 Pack 声明一个准确的自安装 Driver Bundle，并且该包会注册 Driver API v1。
- npm、Bun 与 Python 分发固定到准确版本；二进制归档包含 SHA-256 校验值。
- 认证字段只声明凭证引用；Pack 不包含 API Key、Token、密码、私有路径、主机名或私密对话数据。

## 导出与测试

1. 在 Mac 打开 **Settings → Harnesses**。
2. 在 Harness Studio 创建或编辑 Pack。Harness 不公开内部结构时使用 `opaque`，并且只能展示一个 Runtime 边界。`observable` 与 `composable` Manifest 必须写明 Harness 进程边界、连通展示出来的全部职责、标注关键数据／控制流，并为整张图及每个组件附上 declared、resolved 或 observed 证据。真实只有一个组件的 Runtime 可以只画一个节点；不要为了让图看起来完整而添加填充节点，也不要把 OpenFish、操作系统或模型提供方画进去。只有 Pack 确实允许 OpenFish 编辑的节点才使用 `composable`。只有所选 Driver 定义并校验 Binding 时才添加 Schema 驱动的控制；ACP Driver 接受 `acp-session-option` Binding。`secret-reference` 控制只保存 `OPENAI_API_KEY` 这类 Host 引用名，绝不保存 Secret 值。OpenFish 会在第一轮之前根据实时 Harness 校验控制；未知 Binding 会被拒绝，而不会被冒充为可执行能力。协议专属实时事实必须使用 `driver.<protocol>.*` Signal 并由 Driver 映射；OpenFish 只投影 Signal／Status，不会投影 Prompt、路径、工具参数或账号内容。
3. 打开 **Review** 检查重大变更摘要，先运行 **Validate draft**。它会走与 Save 相同的 Schema 与 Driver Admission 路径，但不会修改 Catalog、安装代码或启动 Harness；后续编辑会让该结果明确过期。只有 Review 后才保存准确版本。
4. 对于非内置协议，在 **Self-installing Driver Bundle** 中填写 npm 包身份，并提供准确的 `package@version` 或 `github:owner/repository#<完整 commit>`。Bundle Patch 只能激活该包自己拥有的模块。只有无法避免时才声明 npm Lifecycle Script；每位安装用户都会看到单独的本地代码警告。**Install & live preflight** 会暂存同一个准确 Bundle，只重启 OpenFish 验证过的内置 Host，等待 Driver 注册后再测试 Harness。该操作刻意与 Dry Run 分开，因为它可能创建 Harness 自己的状态或产生 Provider 定义的初始化成本。
5. 分别使用该 Pack 启动一个 No Project 任务和一个项目任务，确认安装、认证、模型／配置／权限发现、取消与恢复，并确认 Proof Ledger 把 Admission、Preflight 和 Session Observation 归到正确的准确版本。
6. 选择 **Prepare community submission**。OpenFish 要求公开 HTTPS 源码仓库和许可证，拒绝私有路径、带凭据 URL 与疑似凭据值，并生成 `{id}.openfish-harness.json` 和一份脱敏兼容报告。

## 提交

1. Fork [OpenFish 仓库](https://github.com/Yusong-Enceladus/OpenFish)。
2. 把导出的文件放到 `community/harnesses/packs/`，文件名与 Pack id 保持一致。
3. 运行 `pnpm run gen-openfish-community-catalog` 和 `pnpm run test:harness-contract`。
4. 创建 Pull Request，并附上 Manifest、生成后的 `community/harnesses/index.json`、Harness 仓库链接、支持的操作系统和脱敏兼容报告。

审核合并后，OpenFish 客户端会在刷新目录时发现该 Pack。除非 OpenFish 另外记录阻塞发布的验证证据，社区 Pack 始终显示为未验证；目录收录不会提供模型额度，也不会授予凭证访问权。

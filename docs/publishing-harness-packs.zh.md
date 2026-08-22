# 发布 OpenFish Harness Pack

[English](publishing-harness-packs.md) | 中文

本教程把不含凭证的 Harness Pack 发布到 OpenFish 社区目录。目录只提供发现元数据，不代表 OpenFish 的安全背书。

## 前置条件

- Harness 支持 ACP，或者 OpenFish 已经包含其协议对应的 Driver。
- npm、Bun 与 Python 分发固定到准确版本；二进制归档包含 SHA-256 校验值。
- 认证字段只声明凭证引用；Pack 不包含 API Key、Token、密码、私有路径、主机名或私密对话数据。

## 导出与测试

1. 在 Mac 打开 **Settings → Harnesses**。
2. 在 Harness Studio 创建或编辑 Pack。Harness 不公开内部结构时使用 `opaque`；结构真实但只读时使用 `observable`；只有 Pack 确实允许 OpenFish 编辑的节点才使用 `composable`。如需声明可移植的 ACP 默认配置，可在可编辑节点中加入 `acpSessionOptions` 对象，例如 `{"acpSessionOptions":{"model":"model-id","mode":"plan"}}`。OpenFish 会在第一轮之前根据目标 Harness 的实时能力校验这些 id 与值；除非 Pack 的 Driver 另有定义，其他配置键只用于描述。
3. 分别使用该 Pack 启动一个 No Project 任务和一个项目任务，确认安装、认证、模型／配置发现、取消与恢复。
4. 选择 **Prepare Publication**。如果分发环境疑似含有凭证值，OpenFish 会拒绝导出；否则生成 `{id}.openfish-harness.json`。

## 提交

1. Fork [OpenFish 仓库](https://github.com/Yusong-Enceladus/OpenFish)。
2. 把导出的文件放到 `community/harnesses/packs/`，文件名与 Pack id 保持一致。
3. 运行 `pnpm run gen-openfish-community-catalog` 和 `pnpm run test:harness-contract`。
4. 创建 Pull Request，并附上 Manifest、生成后的 `community/harnesses/index.json`、Harness 仓库链接、支持的操作系统和脱敏兼容报告。

审核合并后，OpenFish 客户端会在刷新目录时发现该 Pack。除非 OpenFish 另外记录阻塞发布的验证证据，社区 Pack 始终显示为未验证；目录收录不会提供模型额度，也不会授予凭证访问权。

---
description: "用于 Harness 发现、精确版本生命周期、认证选择和社区 Pack 发布的 Host 与 Client 控制面。"
kind: "package-reference"
---

# Harness Controller

[English](README.md) | 中文

## 概述

`@deepseek-ai/dsh-api-harness-controller` 拥有 Host 的 `ctx.harnessController` 服务与生成的 `ctx.remote.harness` Namespace。它列出和解析已准入的 Harness Pack、刷新公开 Catalog、执行受能力约束的生命周期操作、选择默认项与认证方式，并为可执行代码许可和 Pack 发布提供独立的 Host 本地管理边界。

## 目录

- [使用该包](#use-this-package)
- [模型体验](#model-experience)
- [已知限制与待办事项](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用该包

Client 界面通过生成的 Remote Namespace 操作，而不会直接读取 Pack 文件或安装目录。普通远程变更不能批准未经验证的第三方代码。Host 本地 `manage` Carrier 拥有该许可边界，也负责验证、导出、提交或撤销社区 Pack。所有返回的诊断在到达 Client 之前都会经过 Harness 脱敏边界。

-----

<a id="model-experience"></a>
## 模型体验

无，因为 Harness 发现、生命周期、凭据与发布均属于控制面操作，不注册 Prompt、Tool Schema 或模型结果。

#### KV Cache 影响

没有直接影响；Catalog 与生命周期状态不会进入模型请求前缀。

## 已知限制与待办事项

<a id="known-limitations-and-deferred-work"></a>

- 远程 Client 只能选择已经准入的代码；首次批准未经验证的 Driver 或 Executable 仍必须在 Host 本地完成。
- 社区发布需要已授权的 GitHub 账号，并创建评审 Branch 或 Pull Request，不会绕过仓库评审。
- Controller 会明确报告 Driver/Payload 能力失败，不会模拟 Harness 不支持的操作。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>供维护者使用的工作上下文 — 点击展开</summary>

无。

</details>

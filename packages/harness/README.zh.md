---
description: "OpenFish Harness 包族：Pack 准入、生命周期与投影契约，以及 ACP 和 Codex 协议 Driver。"
kind: "package-group"
---

# harness/ — 可互换 Harness Runtime 包族

[English](README.md) | 中文

## 摘要

harness 包组是 OpenFish 围绕编程智能体 Runtime 建立的版本化边界。核心包负责准入带证据的 Pack、管理精确安装和认证引用、把任务固定到 Pack 版本，并且只投影明确声明且不含内容的运行信号。ACP 包实现通用 ACP Driver 与官方 Codex app-server Driver，不会假装一种协议暴露了另一种协议的私有能力。

## 目录

- [包](#packages)
- [相关文档](#related-documentation)
- [开发说明](#dev-note)

-----

<a id="packages"></a>
## 包

| 包 | 职责 | ctx key |
|---|---|---|
| [`harness/`](harness/README.zh.md) | Pack Schema、Catalog、生命周期、Driver API、Conformance 与持久 Runtime Projection | `ctx.harnesses` |
| [`harness-acp/`](harness-acp/README.zh.md) | 有界 ACP 传输，以及通用 ACP 与官方 Codex app-server Driver | 向 `ctx.harnesses` 注册 Driver |

-----

<a id="related-documentation"></a>
## 相关文档

- [Harness Driver SDK](../../docs/harness-driver-sdk.zh.md) — 版本化 Driver Hook 与能力规则。
- [发布 Harness Pack](../../docs/publishing-harness-packs.zh.md) — 创作、预检、评审与撤销。
- [核心服务参考](../../docs/subsystems/core.zh.md) — 生成的 `ctx.harnesses` 与 `ctx.harnessController` 契约。
- [OpenFish 兼容矩阵](../../docs/openfish-compatibility.zh.md) — 已证明和明确未验证的 Runtime 路径。

<a id="dev-note"></a>
## 开发说明

无。

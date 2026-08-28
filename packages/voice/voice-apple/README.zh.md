---
description: "OpenFish 在 macOS 与 iPhone 上使用的 Apple 设备本地语音 Provider 声明。"
kind: "package-reference"
---

# DSH Voice Apple Provider

[English](README.md) | 中文

## 概述

本包声明可移植 OpenFish 语音契约的 Apple 原生实现，同时把授权与音频执行留在展示设备本地。

## 目录

- [使用该包](#use-this-package)
- [模型体验](#model-experience)
- [已知限制与待办事项](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用该包

这个 Cordis Provider 为 macOS 与 iPhone 声明 DSH voice 的 `apple-local` 实现。Swift 平台适配器执行 Apple 本地识别器及 premium/enhanced 合成器；最终 transcript 仍进入 DSH session API。

<a id="model-experience"></a>
## 模型体验

无，因为该 Provider 不增加任何面向模型的内容。

#### KV Cache 影响

无；Provider 描述只属于启动元数据。

## 已知限制与待办事项

<a id="known-limitations-and-deferred-work"></a>

- 本包声明能力元数据；Apple 授权与音频执行由 Swift 客户端负责。
- 可用性与语言质量取决于操作系统和已安装的 Apple 语音。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>供维护者使用的工作上下文 — 点击展开</summary>

无。

</details>

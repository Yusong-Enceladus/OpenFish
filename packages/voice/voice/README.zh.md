---
description: "OpenFish 原生客户端使用的可移植设备本地语音 Provider 注册表与 transcript 权威契约。"
kind: "package-reference"
---

# DSH Voice

[English](README.md) | 中文

## 概述

本包定义 OpenFish 原生客户端所发现的可移植设备本地语音能力，而且不会创建第二条对话或 transcript 路径。

## 目录

- [使用该包](#use-this-package)
- [模型体验](#model-experience)
- [已知限制与待办事项](#known-limitations-and-deferred-work)
- [开发备注](#dev-note)

-----

<a id="use-this-package"></a>
## 使用该包

本包是 OpenFish 语音能力的 Service Definition，负责 `dsh.voice.v1` Provider 词汇与注册表；它不采集音频、不保存第二份 transcript，也不调用模型。设备端 Provider 在本机执行 STT/TTS，Consumer 通过普通 DSH `session.prompt` 提交最终文本，因此 session log 始终是唯一权威。

<a id="model-experience"></a>
## 模型体验

无，因为本包不会增加提示词、工具 schema 或模型结果。

#### KV Cache 影响

无；能力发现永远不会进入模型请求前缀。

## 已知限制与待办事项

<a id="known-limitations-and-deferred-work"></a>

- 注册表只描述 Provider，不负责选择 Provider 或执行音频操作。
- 平台权限、音频 session、识别与合成生命周期属于设备端适配器。

<a id="dev-note"></a>
### 开发备注

<details>
<summary>供维护者使用的工作上下文 — 点击展开</summary>

无。

</details>

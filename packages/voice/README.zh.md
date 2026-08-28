---
description: "语音能力包组：可移植的设备本地 Provider Registry，以及 Apple 原生 STT/TTS 实现。"
kind: "package-group"
---

# voice/ — 设备本地语音能力包族

[English](README.md) | 中文

## 摘要

voice 包组让语音采集、识别、合成与播放留在展示设备上。Service Definition 包拥有可移植的 `dsh.voice.v1` 能力词汇；Apple 包实现 macOS 与 iPhone Provider。最终的 Speech-to-Text 会进入普通 Session Prompt 边界，因此语音功能不会创建第二套 Transcript 权威。

## 目录

- [包](#packages)
- [相关文档](#related-documentation)
- [开发说明](#dev-note)

-----

<a id="packages"></a>
## 包

| 包 | 职责 | ctx key |
|---|---|---|
| [`voice/`](voice/README.zh.md) | 可移植的设备本地 Provider Registry 与能力描述 | `ctx.voice` |
| [`voice-apple/`](voice-apple/README.zh.md) | 面向 macOS 和 iPhone 的 Apple Speech 与 AVSpeechSynthesizer Provider | 向 `ctx.voice` 注册 |

-----

<a id="related-documentation"></a>
## 相关文档

- [macOS OpenFish 指南](../../apps/x-macos/README.zh.md) — 本地麦克风、听写和语音对话行为。
- [iPhone OpenFish 指南](../../apps/x-ios/README.zh.md) — 设备权限与配对 Session 行为。
- [核心服务参考](../../docs/subsystems/core.zh.md) — 生成的 `ctx.voice` Provider Registry 契约。
- [OpenFish 威胁模型](../../docs/openfish-threat-model.zh.md) — 设备本地音频与 Transcript 边界。

<a id="dev-note"></a>
## 开发说明

无。

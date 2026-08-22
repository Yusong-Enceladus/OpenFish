# DSH Voice

[English](README.md) | 中文

本包是 OpenCodex 语音能力的 Service Definition，负责 `dsh.voice.v1` Provider 词汇与注册表；它不采集音频、不保存第二份 transcript，也不调用模型。设备端 Provider 在本机执行 STT/TTS，Consumer 通过普通 DSH `session.prompt` 提交最终文本，因此 session log 始终是唯一权威。

## 模型体验

无，因为本包不会增加提示词、工具 schema 或模型结果。

#### KV Cache 影响

无；能力发现永远不会进入模型请求前缀。

## 已知限制与待办事项

- 注册表只描述 Provider，不负责选择 Provider 或执行音频操作。
- 平台权限、音频 session、识别与合成生命周期属于设备端适配器。

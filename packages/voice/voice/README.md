# DSH Voice

English | [中文](README.zh.md)

This package is the Service Definition for OpenCodex voice. It owns the `dsh.voice.v1` Provider vocabulary and registry; it does not capture audio, persist a second transcript, or call a model. Device Providers perform local STT/TTS, and Consumers submit finalized text through the ordinary DSH `session.prompt` path so the session log remains authoritative.

## Model Experience

None, as this package adds no prompt text, tool schema, or model result.

#### KV Cache effect

None; capability discovery never enters the model request prefix.

## Known Limitations and Deferred Work

- The registry describes Providers but does not select one or execute audio operations.
- Platform permission, audio-session, recognition, and synthesis lifecycles belong to device adapters.

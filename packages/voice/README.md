---
description: "The voice capability group: a portable device-local provider registry and native Apple STT/TTS implementation."
kind: "package-group"
---

# voice/ — device-local voice capability family

English | [中文](README.zh.md)

## Summary

The voice group keeps speech capture, recognition, synthesis, and playback on the presentation device. The service-definition package owns the portable `dsh.voice.v1` capability vocabulary; the Apple package implements the macOS and iPhone providers. Finalized speech-to-text enters the ordinary Session prompt boundary so voice never creates a second transcript authority.

## Table of Contents

- [Packages](#packages)
- [Related documentation](#related-documentation)
- [Dev Note](#dev-note)

-----

<a id="packages"></a>
## Packages

| Package | Role | ctx key |
|---|---|---|
| [`voice/`](voice/README.md) | Portable device-local Provider registry and capability description | `ctx.voice` |
| [`voice-apple/`](voice-apple/README.md) | Apple Speech and AVSpeechSynthesizer providers for macOS and iPhone | registers on `ctx.voice` |

-----

<a id="related-documentation"></a>
## Related documentation

- [macOS OpenFish guide](../../apps/x-macos/README.md) — local microphone, dictation, and voice-conversation behavior.
- [iPhone OpenFish guide](../../apps/x-ios/README.md) — device permission and paired-session behavior.
- [Core service reference](../../docs/subsystems/core.md) — generated `ctx.voice` Provider-registry contract.
- [OpenFish threat model](../../docs/openfish-threat-model.md) — device-local audio and transcript boundaries.

<a id="dev-note"></a>
## Dev Note

None.

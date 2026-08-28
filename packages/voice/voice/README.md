---
description: "The portable device-local voice Provider registry and transcript-authority contract used by OpenFish native clients."
kind: "package-reference"
---

# DSH Voice

English | [中文](README.zh.md)

## Summary

This package defines the portable, device-local voice capability OpenFish native clients discover without creating a second conversation or transcript path.

## Table of Contents

- [Use this package](#use-this-package)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

This package is the Service Definition for OpenFish voice. It owns the `dsh.voice.v1` Provider vocabulary and registry; it does not capture audio, persist a second transcript, or call a model. Device Providers perform local STT/TTS, and Consumers submit finalized text through the ordinary DSH `session.prompt` path so the session log remains authoritative.

<a id="model-experience"></a>
## Model Experience

None, as this package adds no prompt text, tool schema, or model result.

#### KV Cache effect

None; capability discovery never enters the model request prefix.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

- The registry describes Providers but does not select one or execute audio operations.
- Platform permission, audio-session, recognition, and synthesis lifecycles belong to device adapters.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>

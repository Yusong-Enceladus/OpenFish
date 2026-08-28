---
description: "The Apple device-local voice Provider declaration used by OpenFish on macOS and iPhone."
kind: "package-reference"
---

# DSH Voice Apple Provider

English | [中文](README.zh.md)

## Summary

This package declares the Apple-native implementation of the portable OpenFish voice contract while leaving authorization and audio execution on the presentation device.

## Table of Contents

- [Use this package](#use-this-package)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

This Cordis Provider advertises the `apple-local` implementation of the DSH voice definition for macOS and iPhone. Swift platform adapters execute Apple's on-device recognizer and premium/enhanced synthesizer; finalized transcripts still enter the DSH session API.

<a id="model-experience"></a>
## Model Experience

None, as the Provider adds no model-facing content.

#### KV Cache effect

None; the Provider descriptor is bootstrap metadata only.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

- This package declares capability metadata; Swift clients own Apple's authorization and audio execution.
- Availability and language quality depend on the OS and installed Apple voices.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>

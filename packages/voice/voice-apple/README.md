# DSH Voice Apple Provider

English | [中文](README.zh.md)

This Cordis Provider advertises the `apple-local` implementation of the DSH voice definition for macOS and iPhone. Swift platform adapters execute Apple's on-device recognizer and premium/enhanced synthesizer; finalized transcripts still enter the DSH session API.

## Model Experience

None, as the Provider adds no model-facing content.

#### KV Cache effect

None; the Provider descriptor is bootstrap metadata only.

## Known Limitations and Deferred Work

- This package declares capability metadata; Swift clients own Apple's authorization and audio execution.
- Availability and language quality depend on the OS and installed Apple voices.

---
description: "The OpenFish Harness family: Pack admission, lifecycle and projection contracts, plus ACP and Codex protocol Drivers."
kind: "package-group"
---

# harness/ — interchangeable Harness runtime family

English | [中文](README.zh.md)

## Summary

The harness group is OpenFish's versioned boundary around coding-agent runtimes. The core package admits evidence-backed Packs, manages exact installations and authentication references, pins tasks to Pack versions, and projects only declared content-free runtime signals. The ACP package implements the generic ACP Driver and the official Codex app-server Driver without pretending that one protocol exposes another protocol's private capabilities.

## Table of Contents

- [Packages](#packages)
- [Related documentation](#related-documentation)
- [Dev Note](#dev-note)

-----

<a id="packages"></a>
## Packages

| Package | Role | ctx key |
|---|---|---|
| [`harness/`](harness/README.md) | Pack schema, catalog, lifecycle, Driver API, conformance, and durable runtime projection | `ctx.harnesses` |
| [`harness-acp/`](harness-acp/README.md) | Bounded ACP transport plus generic ACP and official Codex app-server Drivers | registers Drivers on `ctx.harnesses` |

-----

<a id="related-documentation"></a>
## Related documentation

- [Harness Driver SDK](../../docs/harness-driver-sdk.md) — versioned Driver hooks and capability rules.
- [Publishing Harness Packs](../../docs/publishing-harness-packs.md) — authoring, preflight, review, and revocation.
- [Core service reference](../../docs/subsystems/core.md) — generated `ctx.harnesses` and `ctx.harnessController` contracts.
- [OpenFish compatibility matrix](../../docs/openfish-compatibility.md) — demonstrated and explicitly unverified runtime paths.

<a id="dev-note"></a>
## Dev Note

None.

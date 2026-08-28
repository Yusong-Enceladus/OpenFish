---
description: "Host and Client control plane for Harness discovery, exact-version lifecycle, authentication selection, and community Pack publication."
kind: "package-reference"
---

# Harness Controller

English | [中文](README.zh.md)

## Summary

`@deepseek-ai/dsh-api-harness-controller` owns the Host `ctx.harnessController` service and generated `ctx.remote.harness` namespace. It lists and resolves admitted Harness Packs, refreshes public catalogs, performs capability-gated lifecycle operations, selects defaults and authentication methods, and exposes a separate Host-local management boundary for executable-code consent and Pack publication.

## Table of Contents

- [Use this package](#use-this-package)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

Client surfaces call the generated Remote namespace instead of reading Pack files or installation directories. Ordinary remote mutations cannot approve unverified third-party code. The Host-local `manage` carrier owns that consent boundary and also validates, exports, submits, or revokes community Packs. All returned diagnostics pass through the Harness redaction boundary before they reach a client.

-----

<a id="model-experience"></a>
## Model Experience

None, as Harness discovery, lifecycle, credentials, and publication are control-plane operations and register no prompt, tool schema, or model result.

#### KV Cache effect

No direct effect; catalog and lifecycle state never enter the model request prefix.

## Known Limitations and Deferred Work

<a id="known-limitations-and-deferred-work"></a>

- A remote client can select only already admitted code; first-time unverified Driver or executable consent remains Host-local.
- Community publication requires an authorized GitHub account and produces a review branch or pull request rather than bypassing repository review.
- The controller reports Driver/Payload capability failures explicitly and does not emulate unsupported Harness operations.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>

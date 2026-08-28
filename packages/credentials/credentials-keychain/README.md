---
description: "The macOS Keychain credential provider used by OpenFish to keep writable provider secrets out of project files."
kind: "package-reference"
---

# @deepseek-ai/dsh-credentials-keychain

English | [中文](README.zh.md)

## Summary

OpenFish's macOS Host credential provider. Each credential reference is stored as a generic password in the current user's login Keychain under the `app.openfish.credentials` service. `describe` returns only configured/source metadata; secret values are available only to Host-side consumers.

## Table of Contents

- [Use this package](#use-this-package)
- [Model Experience](#model-experience)
- [Known Limitations and Deferred Work](#known-limitations-and-deferred-work)
- [Dev Note](#dev-note)

-----

<a id="use-this-package"></a>
## Use this package

An inherited environment value remains a read-only, higher-priority source for CI, while project and user `.env` files remain read-only fallbacks below Keychain for compatibility with existing setups. On the first launch after upgrading from the file provider, an owner-only `$DSH_HOME/.credentials.yaml` is imported locally; the plaintext file is removed only after every entry is present in Keychain. New writes and removals affect Keychain and emit the ordinary `credentials/updated` event. The provider invokes `/usr/bin/security` with an argument vector and never constructs a shell command.

## Model Experience

### Credential resolution

#### What the model sees

Nothing directly. The provider returns credential values only to Host-side consumers and exposes only configured/source metadata through `describe`.

#### Token effect

None. Keychain values and descriptors do not enter prompts, tool schemas, or tool results.

#### KV Cache effect

None. Credential lookup happens outside model request assembly.

## Known Limitations and Deferred Work

- Keychain storage is available only on macOS; inherited environment values can intentionally shadow writable Keychain entries and must be removed before changing those entries.

<a id="dev-note"></a>
### Dev Note

<details>
<summary>Working context for maintainers — click to expand</summary>

None.

</details>

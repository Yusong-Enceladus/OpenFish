# `@deepseek-ai/dsh-harness`

[中文](README.zh.md)

Open Fish uses this package as the control plane for interchangeable agent Harnesses. A Harness Pack v0 declares a stable identity, protocol, launch distribution, publisher metadata, and an architecture graph. The shell never guesses a Harness's private internals: graph levels are `opaque`, `observable`, or `composable`, and only nodes explicitly marked editable may become controls.

The built-in `dsh` Pack is always available. On startup the catalog fetches the official ACP Registry and projects every compatible npx, uvx, or platform-binary ACP entry into a Pack; the catalog is therefore not limited to products whose names contain “Harness.” Open Fish also curates Oh My Pi because it is not in that Registry. A deployment may add user Packs through configuration, while the native editor can create a Pack by id, distribution, protocol, and a draggable composable graph. Adding another ACP Pack does not require a shell change; a new protocol registers one `HarnessDriver` against the same public SDK.

`registryUrl` defaults to the versioned ACP Registry endpoint. Registry failure is fail-soft: the last successful Registry catalog, built-in, installed, and user Packs remain available. The service persists the explicit cross-device default, user definitions, non-secret authentication choice, active version, and every version still referenced by a session beneath `$DSH_HOME/openfish/harnesses`. Fresh state has no default; the native onboarding must ask. Install, update, rollback, uninstall, and custom-Pack removal are serialized and written atomically.

Pack v0 supports pinned npm, Bun, and Python/uvx packages, checksummed platform binaries, and explicitly user-selected executables. ACP authentication is discovered from the installed Harness: agent/browser login remains Harness-owned, environment credentials live only in Open Fish's write-only credential store and are injected into that process, and terminal login is launched only after a user action. Registry curation and Open Fish runtime compatibility are reported separately. A successful session start records Open Fish compatibility; a failed start records a redacted recovery diagnostic.

The graph is a truthfulness contract, not reverse-engineered decoration. `opaque` exposes only a runtime boundary, `observable` documents real data flow, and `composable` permits editing only for nodes whose Pack sets `editable: true`. Custom Packs may attach arbitrary JSON configuration to those nodes. Manifest admission rejects unknown schema versions, malformed identities, invalid authentication contracts, missing non-DSH distributions, and dangling graph edges.

## Model Experience

### Harness selection records

#### What the model sees

Nothing directly. Protocol drivers register by protocol for the lifetime of their Cordis effect, while `harness/selected` and `harness/native-event` remain host-side session records.

#### Token effect

None. This package contributes no prompt, tool schema, or tool result.

#### KV Cache effect

None. Harness identity records do not enter a DSH model request.

## Extending Open Fish

Start with [`examples/custom-acp.pack.json`](examples/custom-acp.pack.json) and
validate editor/tooling output against
[`schema/harness-pack-v0.schema.json`](schema/harness-pack-v0.schema.json). The
runtime applies additional semantic checks for unique node/auth ids, dangling
edges, and exact package version pins.

- An ACP Harness published in the official Registry appears without an Open Fish release. Its declared distribution must be version-pinned; Registry binaries without a SHA-256 checksum are shown but refused at installation.
- A custom ACP Pack uses the same path through the native editor. Package, arguments, environment, authentication, and graph configuration are Pack data rather than provider-specific application branches.
- A novel non-ACP protocol still needs a Driver plugin; the shell, session API, catalog UI, installation state, and graph editor do not need provider-specific changes.
- Registry metadata is transport-authoritative catalog data, not a claim that Open Fish audited the publisher or package contents. The Settings screen therefore displays Registry and Open Fish compatibility independently.

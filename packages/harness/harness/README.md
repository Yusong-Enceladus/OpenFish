# `@deepseek-ai/dsh-harness`

English | [中文](README.zh.md)

Open Fish uses this package as the control plane for interchangeable agent Harnesses. A Harness Pack v0 declares a stable identity, protocol, launch distribution, publisher metadata, and an architecture graph. The shell never guesses a Harness's private internals: graph levels are `opaque`, `observable`, or `composable`, and only nodes explicitly marked editable may become controls.

The built-in `dsh` and official Codex app-server Packs are always available. On startup the catalog fetches the official ACP Registry and projects every compatible npx, uvx, or platform-binary ACP entry into a Pack; the catalog is therefore not limited to products whose names contain “Harness.” Open Fish also curates Oh My Pi because it is not in that Registry. A deployment may add user Packs through configuration, while the native Manifest Editor can create a Pack by id, distribution, protocol, and a draggable composable graph. Adding another ACP Pack does not require a shell change; a new protocol registers one `HarnessDriver` through the [public Driver SDK](../../../docs/harness-driver-sdk.md).

`registryUrl` defaults to the versioned ACP Registry endpoint. Registry failure is fail-soft: the last successful Registry catalog, built-in, installed, and user Packs remain available. The service persists the explicit cross-device default, user definitions, non-secret authentication choice, active version, and every version still referenced by a session beneath `$DSH_HOME/openfish/harnesses`. Fresh state has no default; the native onboarding must ask. Install, update, rollback, uninstall, and custom-Pack removal are serialized and written atomically.

`communityRegistryUrl` defaults to OpenFish's generated public Pack catalog. Community entries pass the same Pack admission and exact-version rules, remain visibly unverified, and lose every id collision to built-in, user, or official ACP Registry entries. The macOS Manifest Editor imports and edits local Packs, exports credential-free manifests, and links the [community publishing workflow](../../../docs/publishing-harness-packs.md).

Pack v0 supports pinned npm, Bun, and Python/uvx packages, checksummed platform binaries, and explicitly user-selected executables. Binary archives use the bounded in-process ZIP/TAR extractor documented by the generic ACP Driver; links, devices, traversal, decompression bombs, and writes outside the fresh managed snapshot are rejected. ACP authentication is discovered from the installed Harness: agent/browser login remains Harness-owned, environment credentials live only in Open Fish's write-only credential store and are injected into that process, and terminal login is launched only after a user action. Registry curation and Open Fish runtime compatibility are reported separately. A successful session start records Open Fish compatibility; a failed start records a redacted recovery diagnostic.

The graph is an evidence-backed Architecture Manifest, not reverse-engineered decoration. `opaque` exposes exactly one runtime boundary. `observable` and `composable` must name their Harness boundary, connect every responsibility they declare, and attach declared, source-derived, or runtime-observed evidence to every visible component. There is no cosmetic minimum node count: a documented one-component runtime stays one component, while a richer Harness must expose its evidenced control flow instead of being collapsed into a meaningless vendor box. Edge labels explain what crosses each boundary. Open Fish, the operating system, and the model provider are not graph nodes unless they are actually inside that Harness process. `composable` permits editing only for nodes whose Pack sets `editable: true`. Canvas placement lives in the presentation-only `position` field and is never passed to a Driver as executable configuration. An editable node may store only bounded text, boolean, or select values declared by its typed `configSchema`; a `secret-reference` stores a Host credential reference, never the secret. A setting is operational only when its binding is validated and consumed by the selected Driver. The generic ACP Driver applies declared session-option bindings to a new session and rejects ids or values absent from that Harness's live ACP directory. Manifest admission rejects unknown schema versions, malformed identities, invalid authentication contracts, undeclared or unbounded node configuration, missing non-DSH distributions, unsupported components, disconnected or dangling graph edges, and runtime signals not owned by the Pack's protocol Driver. Native clients present the same Manifest through a Progressive Lens: Simple, Architecture, Runtime, and Manifest Editor.

## Extending Open Fish

Start with [`examples/custom-acp.pack.json`](examples/custom-acp.pack.json) and validate editor/tooling output against [`schema/harness-pack-v0.schema.json`](schema/harness-pack-v0.schema.json). The runtime applies additional semantic checks for unique node/auth ids, dangling edges, and exact package version pins.

- An ACP Harness published in the official Registry appears without an Open Fish release. Its declared distribution must be version-pinned; Registry binaries without a SHA-256 checksum are shown but refused at installation.
- A custom ACP Pack uses the same path through the native editor. Package, arguments, environment, authentication, and graph configuration are Pack data rather than provider-specific application branches.
- A novel non-ACP protocol still needs executable protocol code, but a public Pack can declare its exact `driverBundle` package and source. The Mac app asks for code-execution consent, stages and validates that Bundle with its packaged runtime, restarts only its verified embedded Host, waits for Driver API v1 registration, and then continues the same Harness setup flow. No provider-specific native branch or external Node/npm installation is required.
- A Driver plugin is loaded as a DSH Profile Bundle. It must retain the namespace-plugin export shape (`name`/`inject`/`apply`, no default export), registers through an effect, and is removed from the catalog capability surface when that Bundle unloads. Custom live graph facts use the `driver.<protocol>.*` namespace and require the Driver's content-free `runtimeSignals` mapper. See the SDK for the package manifest, Pack descriptor, install, restart, and conformance path.
- Optional actions are capability-gated rather than simulated. A Driver may advertise `session.fork` only when its `fork` hook creates a real branch in the Harness's own durable session system. The official Codex Driver uses app-server `thread/fork`; generic ACP leaves the action unsupported because ACP does not currently define equivalent remote-session semantics.
- Registry metadata is transport-authoritative catalog data, not a claim that Open Fish audited the publisher or package contents. The Settings screen therefore displays Registry and Open Fish compatibility independently.

## Model Experience

### Harness selection records

#### What the model sees

Nothing directly. Protocol drivers register by protocol for the lifetime of their Cordis effect, while `harness/selected` and `harness/native-event` remain host-side session records.

#### Token effect

None. This package contributes no prompt, tool schema, or tool result.

#### KV Cache effect

None. Harness identity records do not enter a DSH model request.

## Known Limitations and Deferred Work

- ACP-compatible Harnesses share the generic Driver. A new non-ACP protocol still requires a real `HarnessDriver`, but a pinned Pack descriptor lets OpenFish install it without an app release; schema-declared node configuration remains inert unless the owning Driver defines and validates its operational binding.
- Community catalog inclusion is discovery, not a security audit or compatibility guarantee. Unverified entries require explicit confirmation, exact package versions, and checksummed binaries.
- Removing an installed or user-authored Pack is blocked while any durable task references it. A confirmed removal deletes all Host-owned installation snapshots and the Pack's private versioned runtime state without following a replaced symlink; shared provider credentials in the Host credential service remain explicit, separately managed state.

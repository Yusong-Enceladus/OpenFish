# Agent Note: Open Fish Harness Pack runtime

Status: implemented

English | [中文](2026-08-20-openfish-harness-pack-runtime.zh.md)

## Problem

Open Fish was a native shell over one DSH runtime. Adding Codex, Pi, Oh My Pi, or a future Harness directly to the shell would make every provider a product-specific branch, require users to preinstall tools, and misrepresent private runtime internals as a common graph.

## Decision

Open Fish selects a Harness per session. Harness Pack v0 owns identity, protocol, distribution, publisher metadata, availability, and an honest architecture graph. Graphs declare `opaque`, `observable`, or `composable`; only Pack-declared editable nodes may be changed. The shell searches a detached catalog and does not contain provider ids.

DSH remains the built-in native path. The generic ACP driver installs each package version through bundled Node/npm or pinned Bun and launches the exact managed snapshot, persists ACP remote identity, maps text output and lifecycle into the common Session surface, bridges approval and cancel, and retains every native ACP update. The official ACP Registry and the generated OpenFish community catalog populate discovery at startup. Built-ins and configured user Packs override every collision, while official ACP entries override community entries. Community entries remain unverified and follow the same exact-version admission rules. The curated Oh My Pi Pack uses Bun because its published CLI requires Bun 1.3.14 or newer and is not yet listed by the Registry.

`session.create` accepts `harnessId`. Existing sessions reject a conflicting choice, and every cold API entry restores the Harness recorded in `harness/selected`; it never silently resumes external history through DSH. Agent Presets remain DSH-only, while ACP models, reasoning levels, and other standard options come from each live ACP session. Editable composable nodes may declare `acpSessionOptions`; the generic Driver applies those defaults to a new session and rejects values the Harness does not advertise. The Host persists a shared default, installs, authentication preference, active version, and rollback snapshots. The macOS landing flow requires one default choice and installs the selected Pack when needed; macOS and iOS settings update that same Host-owned default, while each blank task may choose another Harness before its first turn. Native selection shows source, installation, authentication, compatibility, and the Pack's truthfulness-level graph before use. macOS Harness Studio creates, edits, imports, and exports custom Packs; publication is a credential-free manifest contribution to the generated community catalog.

The native composition gives sessions without a Workspace the Host-owned `$DSH_HOME/openfish/sessions/no-workspace` cwd. A launcher's current directory never classifies an ungrouped task as a user project.

## Alternatives considered

- **Hard-code DSH, Codex, and OMP adapters.** This optimizes the first roster but does not prove that a fourth ACP Harness can arrive without a shell rebuild.
- **Treat Harness as a model provider.** Harness owns the agent loop, tools, approval protocol, and session semantics; a model route cannot represent that ownership.
- **Promise one editable graph for every process.** A black-box CLI exposes neither stable nodes nor safe mutation semantics. Opaque execution plus lossless native events is truthful; composability must be declared by its Pack.
- **Require users to install every CLI.** That defeats the integrated-product requirement. npm ACP Packs are installed on demand inside the Open Fish runtime path.

## Verification

Manifest and lifecycle tests cover Pack admission, dangling-edge rejection, arbitrary ACP Registry projection, third-party Driver registration, atomic state restoration, update, and rollback. ACP tests prove sessions launch a managed installed snapshot. API carrier tests cover catalog mutation and the `harnessId` session wire contract. Native builds cover macOS graph editing, iOS selection, host composition, and cold-resume edges.

## Consequences

Any npm ACP agent that publishes compatible registry metadata can appear, install, and run without shell code changes. Codex and Pi currently arrive through the Registry, while Oh My Pi is a curated Pack over the same ACP driver. A new protocol implements the exported `HarnessDriver` interface without changing shell or session code. Codex's ACP adapter runs the official Codex package underneath, but a future direct App Server Driver would retain more provider-native fidelity. Graph editing is enabled only for Pack-declared composable nodes; browser login remains Harness-owned, API keys remain in the Host credential service, and conversations never claim portability across Harnesses.

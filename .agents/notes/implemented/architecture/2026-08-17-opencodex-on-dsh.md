# Agent Note: Build OpenCodex as a DSH product composition

Status: implemented

English | [中文](2026-08-17-opencodex-on-dsh.zh.md)

## Problem

DSH already owns the agent runtime, append-only session log, tools, approvals, persistence, provider routing, Host RPC, Web client, and plugin lifecycle that an open Codex implementation needs. The parity branch has also added an X CLI, native application shells, an `x-native` bridge, copied interface strings, and several capability packages. Some of those additions reuse DSH correctly, while others prove only that a command, resource, or package exists. Treating those artifacts as a second product stack would duplicate state, protocols, and lifecycle behavior, then make behavioral parity impossible to maintain.

OpenCodex needs one product definition and one ownership rule before more client work continues. The comparison direction is DSH against Codex: functionality that Codex exposes and DSH lacks must be implemented inside the DSH plugin architecture. Codex is not the component being extended, and DSH's current feature set is not the ceiling.

## Decision

### Product invariant

OpenCodex is a strict functional, information-architecture, and key-interaction superset of the release-time Codex desktop work surface inside the unified ChatGPT desktop application, Codex CLI, iPhone, remote, and voice products, plus the release-time DSH Web and `anchored` composition. The comparison target is the Codex product surface, not the unrelated ChatGPT chat surface that happens to share the desktop application. A capability is in scope when a user can observe or rely on it in either baseline, unless this note excludes it explicitly. The captured parity inventory is a traceability snapshot, not a substitute for refreshing the baseline before release.

OpenCodex uses its own name and assets, while Codex supplies the behavior, information architecture, and interaction reference. Core screens and workflows require side-by-side visual and behavioral comparison; copied localization strings, command help, class names, and package presence do not establish parity.

### Runtime ownership

DSH is the OpenCodex runtime, not a dependency hidden behind a parallel X runtime. New behavior follows the extension rules in [the DSH architecture](../../../../docs/architecture.md) and the existing Host/Client split in [the GUI layering decision](../../implemented/architecture/2026-07-19-gui-layering-and-rpc-protocol.md).

| Concern | Authoritative owner | Client rule |
|---|---|---|
| Sessions, turns, messages, tool calls, approvals, and model history | Existing DSH services and the append-only session log | Render projections and send intents; never keep a second durable truth. |
| Business operations | The owning DSH service, exposed through Typert or the existing `/api` Host assembly | Do not add a native-only copy of a business method. |
| New portable capability | A complete DSH capability seam with Service Definition, Service Provider, and Consumer roles where those roles evolve independently | Every client reaches the same registered capability. |
| Product composition | DSH bundles, profiles, presets, and Cordis configuration | OpenCodex is a composed DSH deployment. |
| Platform integration | A platform Service Provider behind a DSH-owned service or Host operation | Swift or platform code owns only the OS-specific implementation. |
| Native presentation | SwiftUI/AppKit on macOS and SwiftUI/UIKit on iPhone | Ephemeral view state is local; product and agent state comes from DSH events and projections. |

The `x-native` bundle may own bootstrap discovery, version negotiation, device authentication, pairing, and transport selection that must happen before a client can call DSH. It does not own session, workspace, agent, tool, approval, settings, voice-domain, or other business operations already represented by DSH. Any retained bootstrap operation must be a Cordis plugin contribution with explicit lifecycle and security rules; the native clients use the ordinary DSH API after bootstrap.

### Client responsibilities

The macOS and iPhone applications are native clients, not WebView shells. The existing DSH Web client remains a supported OpenCodex client. The OpenCodex CLI delegates durable work to the same DSH runtime instead of recreating configuration stores, plugin registries, daemon state, or command behavior in an unrelated implementation.

Native clients implement platform navigation, text input, accessibility, window and scene behavior, notifications, file pickers, audio capture/playback, secure credential UI, and other OS presentation. They consume generated or shared wire contracts and event streams. Polling, locally invented event types, copied business schemas, and client-specific session models are migration signals, not accepted end states.

### Product policies

- DeepSeek is the default model provider; provider selection remains the existing DSH adapter extension point.
- macOS, iPhone, Web, and CLI share one session and task history.
- LAN and Tailscale are the first remote transports; a relay remains an extension point.
- The default voice implementation uses local high-quality STT and TTS Service Providers behind replaceable DSH voice capabilities.
- Codex and earlier DSH data import, export, and migration enter the ordinary DSH persistence model.
- Pets are excluded. Built-in image generation is deferred from the first complete delivery, while its provider extension point remains.

### Evidence and status

Parity status records evidence stages separately: `gap`, `implemented`, `integrated`, `behavior_verified`, `side_by_side_verified`, and `release_verified`. A requirement advances only when the named evidence exists. Help output, copied strings, package presence, compilation, and unit tests may support earlier stages but can never produce `release_verified` by themselves.

Every functional requirement must be reachable through a shipped OpenCodex client, run through the composed DSH profile, preserve and recover its state where Codex does, and pass behavior comparison against the applicable Codex or DSH baseline. Release requires every non-excluded requirement to be `release_verified` after a release-time baseline refresh.

### First implementation slice

The first macOS slice proves the architecture rather than an isolated composer detail. A user selects or creates a workspace and session, sends a prompt, observes streamed assistant and tool events, handles a real approval, sees the tool result and final answer, closes and reopens the client, and resumes the same durable session. The client uses DSH workspace/session services, `/api` business calls, event streams, approval services, and session projections throughout.

The slice begins with a Codex-referenced native information architecture and interaction specification. No engineering shell is presented as a product milestone. Visual review may use deterministic fixtures, but acceptance uses a real composed DSH runtime and a side-by-side Codex workflow.

As of 2026-08-19, this product slice has been forward-ported from DSH rc.5 to rc.8. The macOS client implements the native project/task shell, ordinary DSH RPC and Typert Remote adapters, Host and mux event streams, reconnect/resynchronization, event-to-conversation projection, model selection, DSH permission selection, cancellation, and approval-response paths. The retained `x-native` package identifies the product as OpenCodex and is limited to bootstrap, capability discovery, pairing, and authentication; paired bearer credentials authorize ordinary remote session traffic while privileged Host methods remain loopback-only. DSH remains the sole owner of durable session and workspace state.

The rc.8 TypeScript graph, focused connection, pairing, and voice tests, the full macOS command-line build, and the hermetic behavior workflow pass. The behavior workflow boots the composed DSH Host with isolated persistence, sandbox, approval, tool, local-voice, and model-replay services, then drives the Swift client through prompt, approval, tool result, final answer, shutdown, and durable resume. This supplies implementation, integration, and behavior evidence without an external model request. A live-provider run, real iPhone run, and side-by-side Codex comparison have not yet been performed, so this decision does not claim side-by-side or release verification.

## Alternatives considered

**Build a separate OpenCodex kernel beside DSH.** This duplicates the runtime and makes DSH Web, `anchored`, persistence, tools, and provider behavior second-class integrations instead of the product foundation.

**Expand `x-native` into a complete native business protocol.** This copies the existing DSH Host API and service contracts, creates two evolution paths for every capability, and lets native clients diverge from Web and CLI behavior.

**Generate the Codex command and string surface first.** Generated help and copied strings improve discovery coverage but say nothing about reachability, semantics, persistence, or interaction quality. They remain evidence inputs rather than implementation.

**Ship the DSH Web interface inside native WebViews.** This reuses presentation code but fails the native macOS and iPhone product requirement and cannot reproduce platform interaction, accessibility, voice, windowing, or offline behavior faithfully.

**Rewrite capabilities that DSH already has to match Codex naming.** Names belong in adapters and presentation. Reimplementing an existing DSH capability would add state and lifecycle duplication without improving observable compatibility.

## Verification

- The OpenCodex profile composes the existing DSH Web and `anchored` baseline and adds product capabilities through Cordis plugins, bundles, presets, or platform Service Providers.
- One DSH session event log and one set of DSH services remain authoritative across macOS, iPhone, Web, and CLI; no native or CLI durable store duplicates their business state.
- Every retained `x-native` method is bootstrap-, identity-, authentication-, or transport-specific; business operations use their existing DSH owner and API path.
- The first macOS slice completes the real workspace-to-resumed-session workflow described above, including one approval-gated tool call. The hermetic rc.8 behavior lane verifies this workflow.
- The parity ledger distinguishes implementation, integration, behavior, comparison, and release evidence and reports zero release-verified requirements without release evidence.
- The release baseline covers the current Codex desktop work surface, CLI, iPhone, remote, and voice behavior plus current DSH Web and `anchored`, with only the explicit exclusions in this note removed.

## Consequences

Live-provider, real-iPhone, and side-by-side Codex evidence remain deferred; this implementation decision does not advance those parity stages.

Codex is an observed external product and changes independently, so the evidence inventory can become stale. Release-time recapture and workflow comparison are mandatory even when the implementation has not changed.

Some DSH Host APIs were designed first for the Web client and may not yet expose the event granularity or platform operations a native client needs. The remedy is to extend the owning DSH service or Host assembly once, not create a native-only business model.

High-fidelity native UI work can overfit screenshots while missing state transitions, accessibility, keyboard behavior, or recovery. Deterministic visual fixtures and real runtime workflows must both pass.

Existing X artifacts mix reusable plugins with duplicated stores, copied resources, generated surfaces, and prototype clients. Each artifact needs an explicit keep, refactor, or remove disposition before it can contribute to OpenCodex.

# Agent Note: OpenFish Product Completion and Public Release Contract

Status: proposed

English | [中文](2026-08-22-openfish-product-completion-contract.zh.md)

## Problem

OpenFish already contains a real native macOS shell, a paired iPhone client, DSH-backed session infrastructure, a Harness Pack contract, a native DSH path, a generic ACP path, managed Harness installation, and early Simple, Architecture, and Builder views. Those parts prove a direction, but they do not yet prove the complete product claim. The current repository cannot honestly promise that a new user can install one app on a clean computer, choose any future Harness, understand and configure it, run it reliably across Mac and iPhone, create another Harness, and publish it without product-specific work.

The gap is not one isolated bug. Recent failures exposed repeated assumptions in session creation, workspace handling, model discovery, reasoning controls, authentication, ACP lifetime, layout, voice input, device connectivity, app installation, and product identity. Fixing only the reported instance lets the same assumption fail under the next Harness, provider, account, machine, or device state.

The visual work has the same defect. Incremental styling was attempted without first producing a disciplined comparison of strong products across the coding-agent, native productivity, graph-editor, onboarding, configuration, and marketplace categories. A redesign cannot be accepted because it is merely cleaner than the current UI; it needs explicit reference evidence, an intentional design system, complete state coverage, and Mac/iPhone parity appropriate to each device.

This note is the durable product contract for the next implementation cycle. It separates verified foundations from the unfulfilled promise, records the complete P0/P1 acceptance scope, and prevents a later conversation or context compaction from silently narrowing the work.

## Proposal

OpenFish becomes a native, integrated, cross-device control plane for interchangeable agent Harnesses. A nontechnical user installs OpenFish on a computer with no preinstalled DSH, Codex, Pi, Node, Bun, Python tooling, or Harness CLI; chooses a default Harness during onboarding; completes an explicit authentication and model setup; and starts a task. The same user can change the default in Settings and select a different Harness for each new task. A technical user can import or create a Harness Pack, inspect evidence-backed structure, edit supported configuration, run compatibility tests, export it, and submit it for publication.

OpenFish remains the shell and control plane, not the Harness. The selected Harness owns its agent loop, context construction, tool behavior, execution and sandbox boundary, approval semantics, provider integration, model-facing configuration, persistence, and remote session lifecycle. DSH may act as both the current Host and a native Harness, but every UI and protocol surface distinguishes Host, Harness, model provider, account, and model. Selecting a different Harness creates a session pinned to that Harness and version; OpenFish does not promise conversation portability when the underlying Harness cannot provide it.

The product admits uncertainty instead of inventing compatibility or internal structure. A Harness that implements a supported protocol can use an existing Driver. A Harness with a new protocol needs a Driver plugin. A private Harness with no inspectable evidence appears as one opaque runtime boundary. Registry inclusion proves discoverability, not publisher trust, runtime compatibility, quality, or security review.

## Product truth and positioning

Until this contract passes, public wording describes OpenFish as an experimental native multi-Harness client built on DSH that is validating a common Harness Pack and ACP experience. It may name a capability only as implemented, experimental, or planned. It must not claim universal automatic compatibility, a complete Harness marketplace, an executable visual Harness builder, verified security of third-party packages, cross-Harness conversation portability, or freedom from bugs.

The intended differentiation is the combination of four useful capabilities: one integrated installation and configuration experience, native Mac/iPhone continuity, an honest evidence-backed explanation and runtime observation of each Harness, and a creator path from Pack creation through testing and publication. If OpenFish ships only as a DSH skin plus a generic ACP launcher, it is a useful experiment but not yet the claimed Harness ecosystem.

OpenFish does not declare one Harness “best” from naming, launch timing, or community enthusiasm. Harness quality requires a separate, reproducible comparison of task success, reliability, latency, cost, safety, tool fidelity, and user demand. Shell compatibility and Harness quality remain different measurements.

## First-principles Harness contract

A Harness is the execution system that turns user intent, context, a model, and available tools into controlled, observable, and resumable action. Its boundary includes the agent loop and the policies and state that materially determine that action. A model, provider account, host process, shell window, or graphical client is not by itself a Harness.

OpenFish represents five separate identities throughout onboarding, Settings, task creation, diagnostics, and persistence:

1. The OpenFish client presents and coordinates the experience.
2. The Host owns local authority, storage, process supervision, credentials, and remote-device service.
3. The Harness owns agent behavior and session semantics.
4. The account or authentication method determines who pays and what service is authorized.
5. The provider and model determine inference, model-specific options, and quota within the Harness contract.

Architecture evidence follows this priority: an official machine-readable manifest, a pinned source-derived description, runtime-observed behavior, declared documentation, and finally an opaque boundary. Every visible node states its responsibility, boundary, typed inputs and outputs when known, evidence source, and whether it is declared, observed, editable, or inferred. OpenFish never adds decorative nodes to make a graph appear complete.

## Integrated installation and lifecycle

The release owns every runtime required for its supported baseline. A fresh supported Mac can install, authenticate, and run without global Node, npm, Bun, uv, Python packages, DSH, Codex, or OMP. Every managed Harness installation uses an exact version and isolated location, verifies a checksum or signature when the distribution supplies one, records provenance, and never resolves a floating package again when resuming a pinned session.

Installation provides visible download, verification, authentication, health-check, retry, cancellation, rollback, update, and uninstall states. A failed update leaves the previous runnable version intact. Removing a Harness cannot remove a version still referenced by a retained session without an explicit migration or deletion decision. Unsupported platforms and missing integrity metadata are explained before execution.

Third-party code runs with the least filesystem, network, environment, and process authority the Harness requires. Unverified community packages carry a warning distinct from OpenFish runtime-compatibility results. OpenFish never transmits or logs passwords, API keys, private keys, session tokens, cookies, or one-time codes; secrets live in the platform credential store and are exposed only to the authorized local runtime.

## Extensibility and compatibility

The extension boundary consists of a versioned Harness Pack schema, a versioned Driver SDK, capability negotiation, and conformance tests. Native clients render capabilities and configuration from those contracts; they do not add switch statements, provider ids, fixed executable paths, model lists, or per-Harness layout branches.

The negotiated capability surface covers installation, authentication, account identity, models, reasoning levels and other options, workspace modes, permissions, approvals, questions, files, tools, events, cancellation, resume, fork, archive, update, rollback, diagnostics, graph evidence, runtime observation, and Builder operations. Unknown configuration fields render through schema-driven generic controls or remain explicitly unsupported; OpenFish does not guess private flags.

Compatibility has four visible outcomes: supported, experimental, opaque-but-runnable, and incompatible. Publisher verification, source provenance, registry origin, install integrity, protocol conformance, and successful OpenFish runtime execution are separate facts. A redacted compatibility report records the OpenFish build, platform, Harness id and version, Driver and protocol version, workspace mode, authentication method name, tested capabilities, and first actionable failure without credentials or private session content.

The universal-extension proof uses two synthetic Harnesses that did not exist when the native UI was written. One implements ACP and becomes discoverable, installable, configurable, runnable, resumable, and visible without native client changes. The other uses a new Driver plugin and reaches the same shell contracts without changes to session or presentation code. A malformed, unpinned, or capability-inconsistent Pack is rejected before launch.

## Harness selection, authentication, models, and sessions

First launch requires a default Harness choice; an empty or failed catalog provides recovery instead of a blank modal. Settings can change the shared default, and each blank task can override it before the first turn. Existing tasks retain their Harness id, Driver, protocol, exact version, remote session identity, account choice, model, reasoning value, workspace mode, and capabilities. Changing a global default never mutates them silently.

The task composer presents the hierarchy Harness, account or authentication method, provider and model, reasoning or Harness-specific controls, workspace, and permissions. It displays the selected values rather than hiding them behind icons. The live Harness contract supplies available models and options. A missing routable model blocks sending with a direct setup action; it never creates a fake provider named `harness`, silently chooses a hard-coded model, or shows options that cannot be applied.

Authentication explains whether a task uses a ChatGPT/Codex subscription, OpenAI API billing, another provider key, a local model, browser login, or Harness-owned terminal login. OpenFish may reuse an existing authorized local credential only after showing its source and selected account. Login is always user initiated, and changing accounts does not move or expose credentials across Harnesses.

Sessions without a selected project are first-class No Project sessions on Mac and iPhone. They use an OpenFish-managed working location or a protocol-defined no-cwd mode, never Desktop or the Host launch directory. Create, send, model selection, Harness selection, reasoning, resume, fork, archive, search, import, and cross-device display work in No Project mode for every release-baseline Harness. The UI never relabels these sessions as Other.

## Progressive Lens and runtime observability

The default Simple lens explains what the Harness is for, how it installs and signs in, which account and model it will use, its compatibility and trust status, important permissions, and the consequences of switching. Architecture is an intentional deeper view, not the onboarding default.

The Architecture lens shows the Harness boundary and a useful aggregation of its key responsibilities. It is neither a single meaningless provider node nor an unbounded dump of functions. Node grouping follows runtime ownership and user-relevant behavior: separate components when they have distinct state, authority, failure, configuration, or observable data flow; combine implementation details that do not change understanding or control. The graph supports zoom, pan, search, focus, keyboard navigation, a readable minimap or equivalent orientation, and unclipped labels on Mac and iPhone.

The Runtime lens distinguishes declared architecture from the components and edges actually activated by a task. It can show state transitions, tool and permission boundaries, events, errors, latency, selected configuration, and redacted data/control flow. Observation never becomes a claim about hidden internals, and private content is not captured merely to animate the graph.

DSH, Codex, OMP, synthetic test Harnesses, and demo fixtures use the same manifest source as the running product. Screenshots and sample data cannot drift to a different node count or capability set. An opaque Harness remains honestly useful through install, trust, authentication, capabilities, logs, and runtime-boundary observations without invented components.

## Builder, test, and publication

Until a graph has executable semantics, the product names the current feature Manifest Editor rather than Harness Builder. A complete Builder includes a node-kind registry, typed ports, configuration schemas, secret references, validation, executable or Driver-bound semantics, undo and redo, version diff, import and export, dry run, isolated compatibility tests, and live trace correlation. Editing a node changes behavior only when the Pack and Driver declare that behavior editable.

Creating a Harness produces a runnable, versioned Pack or project rather than decorative JSON. The test action installs it in an isolated environment, exercises negotiated capabilities, reports failures at the responsible node or contract, and emits a credential-free compatibility report. Export removes secrets and personal paths while preserving exact distributions and provenance.

Publishing performs a real submission to a documented community registry or repository workflow, shows validation and review status, and records version, publisher, provenance, compatibility, and revocation state. The catalog provides meaningful built-in and discovered results instead of an empty search box. It separates discovery from endorsement and supports updates, rollback, reports, removal, and version history. Rankings, ratings, and download counts are included only when a trustworthy backend exists.

The iPhone client may keep credential-bearing editing, local installation, and publishing as explicit Mac handoffs. It still displays the same Simple, Architecture, Runtime, validation, version, and trust facts, and it never presents a read-only view as an editable Builder.

## Industry-grounded experience design

No large UI implementation begins until the repository contains a dated reference matrix based on current primary product material and hands-on inspection. The study covers coding-agent products such as Codex, Claude Code or Claude Desktop, Cursor, Windsurf, GitHub Copilot, OpenCode, and Continue; model and local-runtime products such as OpenRouter-style selectors, LM Studio, Jan, and Open WebUI; graph products such as ComfyUI, LangGraph Studio, n8n, Flowise, Dify, and Node-RED; extension ecosystems such as the GPT builder and store, VS Code Extensions, Raycast Store, Home Assistant integrations, and Obsidian plugins; and polished cross-device products such as Things, Linear, ChatGPT, GitHub Mobile, and Raycast.

The reference matrix records screenshots or source links, target users, information architecture, onboarding, navigation, task composer, Harness/model/account hierarchy, installation and authentication, configuration disclosure, graph interaction, creation and publication, empty/loading/error/offline states, mobile adaptation, accessibility, and the specific pattern adopted or rejected. It is evidence for decisions, not permission to copy branding or visuals. Every selected OpenFish direction includes a side-by-side rationale against at least the strongest relevant references.

The redesign covers the complete Mac and iPhone products: onboarding, landing, sidebar and task organization, New Task, task transcript, composer, approvals and questions, Harness selection, models and accounts, permissions, installer and authentication, No Project, Settings, remote pairing, notifications, graph lenses, Builder and catalog, voice, search, empty states, progress, recoverable and fatal errors, offline and reconnect states, updates, and destructive confirmations.

A shared design system defines typography, spacing, color, elevation, materials, icons, component states, motion, copy tone, and responsive behavior. Mac respects keyboard, pointer, window resizing, focus, menus, and density. iPhone respects touch targets, safe areas, Dynamic Type, navigation depth, interruptions, backgrounding, and one-handed use. Both support localization, contrast, VoiceOver reading order and labels, reduced motion, clear focus, and semantic error announcements. Accessibility is claimed only after device testing.

Specific existing defects remain release regressions: onboarding cannot default to Architecture; non-DSH tasks cannot say they “work through DSH”; Host and Harness labels cannot be conflated as Local DSH; the active Harness cannot be icon-only; the composer cannot crowd or clip selectors; the caret and placeholder must begin at the intended inset; light appearance must remain legible; graph chips and edges cannot clip on iPhone; Builder handoff and install actions must state their real effects; No Project must not become Other; and every model, reasoning, account, workspace, and permission selection must remain visible and operable.

## Cross-device, voice, and installed-product behavior

The Mac Host and iPhone client pair, revoke, discover, reconnect, and operate over a trusted LAN or Tailscale connection without exposing the Host to the public internet. The phone shows the same session, Harness, model, account mode, approvals, questions, queue, and compatibility facts as the Mac. Offline actions and concurrent edits have explicit queueing, conflict, retry, and cancellation behavior. Credentials and pairing tokens remain in Keychain and diagnostics redact hostnames and private content by default.

Voice input survives repeated start and stop, permission allow, deny and later revoke, audio interruptions, route and device changes, background and foreground transitions, network loss, and task or Harness switching. The UI explains whether recognition is on-device, operating-system mediated, or cloud-assisted; it does not claim local-only processing when the platform may send audio elsewhere. Only the finalized user-approved text enters the task unless the user explicitly chooses another mode.

A built artifact is not treated as an installed update. Release verification uses one current OpenFish app in Applications with the correct icon, Bundle ID, signing identity, and LaunchServices registration, plus the intended iPhone or TestFlight build. Migration preserves compatible preferences and sessions from development Bundle IDs while avoiding duplicate Dock, Spotlight, or Applications results.

## Demonstration and public presentation

Mac and iPhone have deterministic, network-isolated demo states with synthetic projects, sessions, accounts, models, graph evidence, errors, approvals, and conversations. Demo mode never reads personal data, uses real credentials, connects to a Host or provider, caches discoveries, requests voice permission, or writes into production state. It visibly identifies itself as demo data.

Public material includes the OpenFish icon, a privacy-reviewed Mac overview, an iPhone continuity view, Harness selection and setup, a truthful Architecture and Runtime view, a Builder/test/publication flow, and a concise diagram of Host, Harness, account/provider, and devices. Screenshots are captured from the deterministic fixture, crop unrelated windows, remove metadata, and undergo text and image privacy review. A short video or animated walkthrough is optional only after the underlying flows are stable.

The README states supported platforms, exact release-baseline Harnesses, compatibility levels, installation, authentication and billing ownership, security boundaries, limitations, roadmap labels, contribution path, license, and a reproducible quick start. It never exposes personal paths, computer names, projects, accounts, tokens, screenshots, or git history.

## P0 acceptance contract: safe public alpha

P0 is complete only when the primary public-alpha journey works end to end and the release makes no false core claim.

1. A clean supported Mac with none of the external runtimes or Harness CLIs installs a signed and notarized OpenFish build, chooses a default Harness, completes explicit authentication and model setup, starts a Project and No Project task, resumes it, changes the default, and creates another task with a different Harness.
2. DSH, Codex, and OMP each pass install, authentication, live model discovery, model selection, supported reasoning controls, send, tool and approval flow, cancel, resume, archive, update, rollback, and actionable failure recovery. Codex separately proves ChatGPT subscription and API billing paths when supported, without automating or exposing user secrets.
3. Any compatible ACP Registry Pack can appear without native UI changes; a synthetic new ACP Pack passes discovery through resume; incompatible or malformed Packs fail before launch with a precise reason.
4. The composer and Settings keep Host, Harness, account, provider/model, reasoning, workspace, and permissions distinct and visible. No Project uses dedicated storage and the full session lifecycle on Mac and iPhone.
5. Simple and Architecture views are evidence-backed and useful for DSH, Codex, OMP, an opaque Harness, and the synthetic Pack. Declared and observed facts are visibly distinct. The Mac Manifest Editor can create, validate, test, import, and credential-free export one runnable custom ACP Pack; public wording does not call it an executable Builder beyond those semantics.
6. The industry reference matrix and selected design direction exist before the redesigned Mac and iPhone P0 flows are accepted. Core flows cover all loading, empty, setup-required, offline, recoverable-error, and fatal-error states and pass keyboard, VoiceOver, Dynamic Type, contrast, resizing, and touch-target checks applicable to each platform.
7. Physical Mac and iPhone verification covers pairing, disconnect and reconnect, approvals, questions, task continuity, voice allow and deny, repeated voice use, background and foreground, and remote revocation. Only one correctly branded OpenFish installation remains discoverable on each tested Mac.
8. Automated contract, integration, packaged-runtime, migration, native UI, and regression checks cover the reported failures: missing injected tools, persona mount failure, ACP connection closure, missing provider/model, missing model selector, missing reasoning selector, incorrect caret inset, No Project creation failure, duplicate app identity, phone connection loss, and voice crash.
9. The release tree and git history pass secret scanning, reviewed false-positive handling, screenshot OCR and metadata review, binary and archive inspection, dependency license review, third-party notices, and credential/log redaction checks. A threat model covers Harness supply chain, process authority, local network exposure, credentials, diagnostics, and community publication.
10. The source tree is clean, the public GitHub remote and history contain only approved material, release artifacts are signed and notarized, checksums and provenance are published, installation and uninstall instructions are verified, and public screenshots and claims match the tested build.

## P1 acceptance contract: complete product promise

P1 contains every explicit product requirement beyond the minimum public-alpha path. It is not implied complete by a P0 release.

1. A new non-ACP protocol Driver plugin passes the public SDK and conformance suite without modifying native clients, common session code, or existing Drivers; version negotiation and incompatible upgrades have tested behavior.
2. Runtime Observability correlates real task activity to evidence-backed nodes while preserving privacy, and the graph interaction remains usable at representative small, medium, and large manifest sizes on Mac and iPhone.
3. The executable Builder creates a new runnable Harness project with typed nodes and ports, validates configuration and secret references, runs an isolated dry run and conformance suite, displays live traces, supports undo, redo, diff, import, export, and versioning, and changes behavior only through declared Driver semantics.
4. In-app publication submits a credential-free Pack to an operational catalog workflow and shows validation, review, publisher, provenance, compatibility, versions, update, rollback, report, removal, and revocation state. Community trust signals never imply security endorsement without evidence.
5. The complete Mac and iPhone screen and state inventory uses the selected design system and passes the supported OS, architecture, window-size, appearance, localization, accessibility, network, account, and device matrix. Mac-only operations use clear iPhone handoffs rather than missing or misleading controls.
6. Clean-machine and chaos coverage includes Apple silicon and Intel where supported, fresh and upgraded state, no dependencies, corrupt downloads, registry outage, authentication expiry, provider quota failure, Harness crash, Host restart, ACP protocol violations, network partition, low disk space, permission changes, interrupted updates, and concurrent device actions.
7. Public value evidence reports time to first successful task, Harness setup and switching success, resume reliability, setup-failure recovery, graph comprehension, custom Pack creation time, and task-level quality comparisons without conflating Harness performance with OpenFish compatibility.

## Execution order and evidence

Work proceeds by dependency rather than visual convenience. First freeze truthful claims, the product vocabulary, capability contract, test Harnesses, and supported release matrix. Next complete clean installation, authentication, model and session correctness, No Project, and Driver conformance. Then produce the industry reference matrix and design direction, implement the full Mac/iPhone state inventory, and complete physical-device continuity and voice behavior. Architecture observation, executable Builder semantics, publication, and marketplace trust build on those contracts. Security, privacy, packaging, migration, and release evidence close the cycle.

Each acceptance item links to durable implementation evidence: the owning code or protocol, a focused automated check, a clean-machine or physical-device result when required, and the exact public statement it permits. Test counts alone are not evidence of coverage, simulator builds do not prove physical-device behavior, synthetic DSH behavior does not prove Codex or OMP, and a successful package build does not prove an installed application update.

## Alternatives considered

**Fix each reported bug and publish quickly.** This preserves hidden assumptions and forces users to become the compatibility test suite. It cannot support the universal-shell claim.

**Hard-code the most popular Harnesses.** DSH, Codex, and OMP are necessary release baselines, but product-specific branches make future Harnesses expensive and cause the native clients, models, authentication, and sessions to drift.

**Treat every CLI as automatically compatible.** A name or executable path does not define protocol, session semantics, permissions, or configuration. OpenFish can automate only a supported Driver contract and must explain when an adapter is required.

**Draw a universal internal graph from marketing descriptions.** This creates attractive but false architecture. Evidence-backed opaque, observable, and composable levels preserve honesty and remain useful.

**Copy one successful product's UI.** No single reference covers native continuity, coding-agent sessions, graph editing, installation, and marketplace trust. A cross-category evidence matrix supports a coherent product without copying another brand.

**Publish the current repository as a complete ecosystem.** The code is meaningful experimental work, but current installation, release, device, extensibility, Builder, security, and UI evidence does not justify that claim.

## Acceptance criteria

- This note remains the owning complete scope until superseded by a reviewed Agent Note; later task plans link here and cannot silently omit an unfinished P0 or P1 item.
- Implementation reports explicitly identify which criteria are verified, which are implemented but unverified, which remain unimplemented, and which public claims are therefore allowed.
- No public release occurs until every P0 item passes against the release artifact, privacy review is complete, the public remote is correct, and the user authorizes publication after seeing the final evidence and claims.
- A “complete product” statement requires every P1 item in addition to P0; a public alpha states the remaining P1 limitations plainly.

## Risks

- A broad contract can turn into indefinite work unless implementation stays ordered around the P0 end-to-end path and records evidence as each dependency closes.
- Third-party Harness protocols, authentication, packages, and model catalogs change quickly; version pinning, capability negotiation, conformance fixtures, compatibility labels, and rollback reduce but cannot eliminate that risk.
- Strong graph and marketplace claims invite unsafe inference and supply-chain trust; evidence levels and separate provenance, compatibility, and security facts must remain visible even when they add friction.
- A polished demo can conceal weak live behavior; deterministic fixtures are presentation tools and never substitute for clean-machine, real-Harness, physical-device, or failure-path tests.
- macOS and iPhone parity can become false symmetry; device-specific ownership and explicit handoffs are preferable to controls that exist but cannot work on that device.

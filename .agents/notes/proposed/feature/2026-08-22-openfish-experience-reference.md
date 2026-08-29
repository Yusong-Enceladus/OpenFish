# Agent Note: OpenFish Industry Experience Reference

Status: proposed

English | [中文](2026-08-22-openfish-experience-reference.zh.md)

## Problem

OpenFish needs a full Mac and iPhone redesign, but earlier visual changes were made without a recorded comparison against strong coding-agent, native-productivity, graph, runtime, and extension-marketplace products. The result has been locally plausible controls with weak hierarchy, crowded task configuration, static architecture diagrams, uneven empty/error states, and insufficient evidence that the product claim is visible or useful.

This dated reference records the current primary-source comparison and the baseline product audit captured on 2026-08-22. It is subordinate to the complete [product completion contract](2026-08-22-openfish-product-completion-contract.md); it does not narrow that contract.

## 2026-08-29 ecosystem refresh

- The official Codex stable release is now `0.151.0`; its documented `app-server` remains the interface used by rich Codex clients. The OpenFish release baseline deliberately remains the already live-tested `0.150.1` until `0.151.0` clears the repository's minimum release-age window and passes the same install, model/reasoning, prompt, resume, and sandbox checks. OpenFish keeps prior installed snapshots for task resume and rollback and never follows floating prereleases.
- The official ACP Registry now contains many independently versioned agents and refreshes release metadata hourly. It is the generic discovery plane, not a hand-maintained OpenFish shortlist and not a security endorsement.
- `pi-acp` is present in that Registry at `0.0.33` and wraps the separate Pi coding agent. Pi itself is now published from `earendil-works/pi` with stable `0.84.3`, including session-scoped model/thinking controls. OpenFish exposes Pi through the generic ACP lane instead of adding native Pi UI.
- Oh My Pi stable `18.0.10` continues to expose a direct ACP mode and a broader provider/model/auth surface. Its current provider documentation keeps model credentials in the Harness-owned store and advertises provider-scoped login rather than one global OpenFish model list. It remains the curated Pi-family release baseline because that richer direct integration is materially different from the Registry adapter; this is a support decision, not a claim that OMP produces better coding results.
- OpenCode `1.18.25` is distributed in the ACP Registry as checksum-pinned native binaries for supported platforms. It is a useful proof that Registry ingestion must preserve platform artifacts and integrity facts without product-specific UI.
- The same live Registry now advertises `codex-acp` `1.7.0`, Gemini CLI `0.57.0`, and Harn `0.10.120`. `codex-acp` demonstrates that an ACP adapter can expose rich Codex model, reasoning, approval, and authentication controls, while Harn demonstrates a graph-native agent pipeline. They should enter OpenFish through the generic Registry lane and conformance gate; neither justifies another native selector branch.

These changes strengthen the architectural choice: curate only release-blocking Harnesses whose exact setup OpenFish verifies, while letting every compatible Registry entry flow through one bounded ACP Driver. They do not justify naming Codex, OMP, Pi, OpenCode, or DSH “best” without a common task benchmark.

## Reference matrix

| Product | Primary evidence | Strong pattern | OpenFish adoption | Rejection or limit |
| --- | --- | --- | --- | --- |
| OpenAI model platform | [latest model guide](https://developers.openai.com/api/docs/guides/latest-model), [model directory](https://developers.openai.com/api/docs/models) | Model identity and reasoning effort are separate, model-specific controls. | Keep Harness, account, provider/model, and reasoning as distinct visible values; render only advertised efforts. | Never infer a reasoning list from a model name. |
| OpenCode | [intro](https://opencode.ai/docs), [models](https://opencode.ai/docs/models), [providers](https://opencode.ai/docs/providers), [permissions](https://opencode.ai/docs/permissions) | Explicit provider connection, `provider/model` identity, remembered/default selection, model variants, configurable permissions, plan/build modes. | Show credential source, exact provider/model, reasoning or variant, permission policy, and task mode without hiding ownership. | Do not preload a giant unconfigured model catalog or silently choose the first model. |
| Claude Code | [setup](https://docs.anthropic.com/en/docs/claude-code/getting-started), [CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage) | Installation doctor, explicit authentication/billing modes, model and permission modes, resume and tool controls. | Add Harness preflight, explicit account/billing copy, resumable pinned sessions, and actionable recovery. | A successful executable lookup is not a verified task run. |
| Cursor | [agent modes](https://docs.cursor.com/agent) | Model, mode, and tool controls are grouped near the task, with progressive configuration. | Keep frequently changed task controls in the composer and move rare settings to a disclosed Harness menu. | Do not bury the current model or permission mode in Settings. |
| LangGraph Studio | [Studio](https://docs.langchain.com/oss/python/langgraph/studio) | Architecture plus live intermediate state, tool calls, results, debugging, and time travel. | Separate declared Architecture from Runtime evidence and correlate node state with durable events. | Do not animate nodes based on guessed private internals. |
| ComfyUI | [subgraphs](https://docs.comfy.org/interface/features/subgraph), [App Mode](https://docs.comfy.org/interface/app-mode) | Reusable nested graphs, typed slots, exposed parameters, node library, and a simple app-facing surface distinct from editing. | Use Simple / Architecture / Manifest Editor lenses; expose only meaningful Pack-declared parameters. | Do not force ordinary users into the graph or call decorative JSON an executable Builder. |
| n8n | [execution history](https://docs.n8n.io/workflows/executions/all-executions/) | Saved executions, retry with original/current workflow, and loading an execution onto the canvas. | Retain version-pinned execution evidence, retry, and trace-to-node correlation. | Do not mutate historical sessions when a default Harness changes. |
| VS Code | [extension manifest](https://code.visualstudio.com/api/references/extension-manifest), [extension hosts](https://code.visualstudio.com/api/advanced-topics/extension-host), [CI](https://code.visualstudio.com/api/working-with-extensions/continuous-integration) | Versioned manifests, engine compatibility, isolated/lazy extension hosts, and automated compatibility checks. | Version Driver API and Pack schema, negotiate capabilities, isolate runtimes, reject incompatible drivers, and run conformance tests. | Registry presence is not trust or compatibility proof. |
| Raycast | [developer platform](https://developers.raycast.com/), [install](https://developers.raycast.com/basics/install-an-extension), [security](https://developers.raycast.com/information/security), [store preparation](https://developers.raycast.com/basics/prepare-an-extension-for-store) | Typed native components, in-app discovery/install, local development separation, review, notarization, privacy-reviewed screenshots. | Provide native generic capability/config components, separate local/user Packs from community entries, and add publication/privacy gates. | Do not imply community publication is security endorsement. |
| LM Studio | [developer docs](https://lmstudio.ai/docs/developer), [app docs](https://lmstudio.ai/docs/app) | Explicit download/load/list lifecycle for local runtimes and models, offline operation, and a local server boundary. | Show install, runtime, provider, model, and local/remote ownership as separate states. | “Installed” must not mean “loaded, authenticated, and runnable.” |
| Linear | [display options](https://linear.app/docs/display-options), [peek](https://linear.app/docs/peek), [selection](https://linear.app/docs/select-issues) | Dense but consistent navigation, quick preview, keyboard/pointer parity, and restrained modal use. | Use a stable task list, quick inspector, predictable focus, and keyboard actions on Mac. | Avoid modal configuration for every ordinary task change. |
| Apple platforms | [macOS design](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars), [toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars), [settings](https://developer.apple.com/design/human-interface-guidelines/settings), [accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | Resizable keyboard-first Mac layouts, shallow sidebars, uncrowded toolbars, stable Settings, familiar actions, device-appropriate iPhone navigation. | Build one shared vocabulary and device-specific navigation; preserve focus, resizing, Dynamic Type, touch targets, and VoiceOver semantics. | Do not copy a desktop sidebar onto iPhone or put frequent task controls in Settings. |

## Baseline audit

The 2026-08-22 deterministic Mac fixture was captured before the redesign work. It contains synthetic data and no user account, project, host, or credential content.

- New Task has excessive unused vertical space and a crowded single-row composer. Project, permission, Harness, model, reasoning, Harness options, account, preset, voice, and submit compete without strong grouping.
- The active Harness can still become visually subordinate to model and account even though it owns the agent semantics. Host, Harness, account, provider/model, and permission facts are distributed across the header, composer, Settings, and inspector.
- Onboarding has a useful Simple/Architecture/Builder foundation, but provider setup is visually detached from the selected Harness and the primary action. Fixture node counts had drifted from the built-in DSH manifest.
- Conversation reading is reasonably clear, but the composer remains dense and metadata is repeated in several locations.
- The inspector showed architecture as a vertical list, not connected flow or live activation. The graph preview had no execution state, edge semantics, pan/zoom, search, or orientation aid.
- Light appearance has weaker hierarchy and contrast than dark appearance. This is a visual finding, not an accessibility compliance result.
- The iPhone architecture grid can clip long node titles and kinds. Mac-only Builder ownership is disclosed, but the handoff needs a direct action and shared validation results.

## Proposal

OpenFish uses a calm native productivity shell with an explicit runtime control strip and a Progressive Lens:

1. **Simple** is the default. It answers what this Harness is for, whether it is installed and trusted, how it authenticates and bills, which provider/model and reasoning are selected, and whether the Mac can run it.
2. **Architecture** shows evidence-backed responsibilities and directed flow. Node granularity follows distinct state, authority, failure, configuration, or observable data flow—not implementation function count.
3. **Runtime** overlays durable node activity, permission boundaries, tool events, errors, and selected configuration without collecting private content for animation.
4. **Manifest Editor** creates/imports a versioned Pack, graph, credentials references, exact distribution, defaults, and evidence. “Builder” remains reserved for executable typed-node semantics.

The task composer keeps the prompt visually dominant. Project and permission form one task-scope group; Harness, account, provider/model, reasoning, and Harness-specific options form one runtime group; rare options use progressive disclosure while every active value stays readable. Empty, loading, setup-required, offline, recovery, and fatal states occupy the same stable regions instead of replacing the whole interface unpredictably.

Mac keeps the two-level task sidebar, keyboard shortcuts, resizable inspector, pointer affordances, and a separate Settings window. iPhone uses navigation stacks, large touch targets, compact menus, approvals and continuity as primary jobs, and explicit Mac handoffs for credential-bearing installation or publication.

The implemented Lens hierarchy follows the same trace-first pattern used by current agent debuggers: Runtime puts the chronological, content-free execution record first and uses the declared component structure as a filter. Architecture uses ordered Pack-derived stages as the master and responsibility, data flow, executable controls, and evidence as the selected detail. It does not place every phase in a clipped horizontal strip, and iPhone keeps the component filter behind progressive disclosure after the trace.

## Alternatives considered

**Patch each weak screen independently.** Local visual fixes preserve the conflicting identity hierarchy and allow the same Harness state to drift between onboarding, the composer, Settings, and the inspector.

**Clone one competing product.** No compared product combines installable Harness runtimes, pinned cross-Harness sessions, a paired iPhone client, evidence-backed architecture, and Pack authoring. OpenFish adopts verified interaction patterns without copying another product's skin or omitting its own ownership boundaries.

**Make the graph the default interface.** A mandatory graph exposes implementation detail before ordinary users can answer what will run, how it authenticates, and what it costs. Progressive Lens keeps those decisions in Simple while preserving exact evidence and editing for technical users.

## Acceptance criteria

- Every redesigned P0 screen can point to at least one adopted pattern above and a concrete OpenFish need; visual preference alone is insufficient.
- Mac and iPhone fixtures cover populated, empty, loading, setup-required, offline, recoverable-error, and fatal-error states without personal data.
- Host, Harness, Driver, account, provider/model, reasoning, workspace, and permission identities are distinct and current wherever a task can start or resume.
- Architecture never invents internals; Runtime activity is derived from durable observed events; labels remain readable at supported sizes.
- Design review includes current screenshots and hands-on keyboard, resizing, VoiceOver, Dynamic Type, appearance, and physical-device checks before claiming acceptance.

## Risks

- Combining patterns from many products can create a feature collage. The selected direction therefore uses one stable identity hierarchy and Progressive Lens rather than copying isolated visuals.
- Capability-driven generic UI can become mechanically verbose. Simple mode must summarize, while Architecture and Manifest Editor retain exact evidence and configuration.
- Deterministic fixtures can hide live failures. They support design and public screenshots only; they never substitute for real DSH, Codex, OMP, clean-machine, or physical-device evidence.

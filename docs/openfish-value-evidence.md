# OpenFish value evidence

English | [中文](openfish-value-evidence.zh.md)

OpenFish is valuable only if its control plane removes setup and continuity work without hiding who runs code, who receives data, or who bills the user. A large catalog, attractive graph, or successful build is not evidence of that outcome. This report keeps product value separate from Harness task quality and records missing evidence instead of replacing it with marketing.

## Claims under evaluation

| Product claim | Success measure | Current evidence status | Release interpretation |
| --- | --- | --- | --- |
| One app reaches a first successful task on a clean Mac | Median and failure distribution from app install through explicit Harness auth, live model selection, Project/No Project creation, and a completed response | Not measured on a clean-machine sample | Implemented release-candidate path; do not claim effortless setup yet |
| A user can switch Harnesses without learning their CLIs | Successful new-task override, correct account/model/reasoning controls, and no mutation of an existing task | Harness/ACP contracts and the packaged-runtime gate pass on Apple Silicon; the official Codex `0.150.1` existing-login path and OMP `18.0.10` unauthenticated lifecycle have live working-copy evidence, while authenticated OMP and the final DSH/Codex/OMP artifact matrix remain pending | Claim protocol-driven selection and the two exact verified paths, not universal success |
| Tasks resume reliably across app and Host restarts | Resume success by Harness/version/workspace mode, with remote identity and pinned configuration retained | Resume, fork, and Pack-pinning fixtures plus the packaged clean-state Host smoke pass; the live multi-Harness retention matrix is still pending | Do not publish a reliability percentage |
| Setup failures are recoverable | Recovery from missing auth, no routable model, corrupt download, interrupted update, Harness exit, registry outage, and Host reconnect without losing existing tasks | Missing-auth/model, invalid-Pack, ACP exit/cancel, Host reconnect, and update/rollback contracts pass; a complete chaos run has not been recorded | Describe explicit recovery states, not proven robustness |
| Architecture views improve understanding | Users correctly identify Host, Harness, account/provider, model, workspace boundary, evidence level, and the ordered path actually observed through representative Packs | Evidence-backed manifests and a bounded content-free execution trace are implemented on Mac and iPhone; no comprehension study has been run | Call it an evidence-backed lens and execution trace, not a proven comprehension improvement |
| A technical user can create a Pack efficiently | Time from empty Manifest Editor to admitted exact-version Pack, prompt-free live preflight, credential-free export, and successful task | Executable workflow implemented; task-time sample not measured; provider-owned preflight state/cost is not asserted | Call the current surface Manifest Editor, not a universal visual Harness Builder |
| Mac–iPhone continuity reduces interruption | Pair/reconnect/follow-up/approval/question/revoke completion and recovery after background or network loss on a physical phone | The current-source DEBUG app builds, signs, installs, and launches on the connected iPhone 17 Pro. Its content-free hardware checks pass five production microphone start/stop cycles and a live Host lifecycle sequence: cold profile restore, authenticated baseline, deliberate background stop, foreground reconnect, and restored baseline. Simulator approval/question and microphone-denied UI plus the authenticated Host self-revoke contract pass. The physical XCTest Runner installs and starts, but its local-network DTX control channel disconnected before test cases began; current tap-driven follow-up, approval, question, and revoke evidence therefore remains pending | Claim the exact physical hardware and lifecycle paths; do not infer the still-unrecorded interactions from Simulator or protocol tests |

## Ecosystem calibration — 2026-08-29

The bar moved while OpenFish was being built. OpenAI now describes the open Codex Harness as the same execution layer behind its app, CLI, and IDE experiences, and exposes persistent product integration through app-server. Codex `0.151.0` is the newest upstream release as of 2026-08-29, but it is a same-day release; OpenFish keeps the tested `0.150.1` baseline until the minimum-release-age gate and the same live journey pass. ACP version 1 separately standardizes capability negotiation across clients and agents, and its hourly-updated Registry currently contains 39 agents. OMP `18.0.10` is the current stable release and advertises live catalog refresh, provider-specific reasoning metadata, OAuth improvements, and application-level usage attribution.

These developments validate the need for a Harness boundary, but they also remove two weak product claims: OpenFish did not make Codex embeddable, and merely launching ACP agents is no longer differentiated. The remaining useful claim is the combination of provider-neutral managed installation and isolation, one visible account/model/permission contract, native Mac–iPhone continuity, and an evidence-backed path to inspect, author, test, and publish Harness Packs. If any one of those collapses into a hard-coded launcher, an invented graph, or a read-only phone viewer, OpenFish has not yet earned that claim.

Primary references: OpenAI's [Codex as a platform](https://learn.chatgpt.com/blog/codex-as-a-platform), the exact [Codex `0.151.0` release](https://github.com/openai/codex/releases/tag/rust-v0.151.0), the [ACP protocol repository](https://github.com/agentclientprotocol/agent-client-protocol), the live [ACP Registry](https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json), and the exact [OMP `18.0.10` release](https://github.com/can1357/oh-my-pi/releases/tag/v18.0.10).

## Recorded live Harness evidence — 2026-08-29

- Official Codex `0.150.1`, using the isolated existing-login route, installed and launched through the product Driver under macOS Seatbelt. The live app-server returned seven models, exposed model-specific reasoning choices, completed one minimal billed prompt, persisted the turn, and resumed its remote thread. OpenFish copied the system CA bundle into the private Harness runtime instead of granting the Harness access to an external trust directory. Managed ChatGPT login and API-key billing remain separate unrecorded routes.
- OMP `18.0.10` installed and launched through the generic ACP Driver under the same isolation boundary. It returned two authentication methods, created and resumed a session, and exposed two modes plus its `thinking` configuration through the generic option projection. The unauthenticated session returned no model directory, so OpenFish must present sign-in before model selection and must not invent fallback models. No billed prompt was sent; an authenticated OMP model/reasoning/send run remains pending.
- These are working-copy observations, not evidence for a final DMG. They promote the exact Codex existing-login and OMP unauthenticated lifecycle paths to verified alpha; they do not prove the complete DSH/Codex/OMP artifact matrix or clean-machine success.

## Harness quality is a different experiment

OpenFish compatibility answers whether a Harness can be installed, configured, invoked, observed, resumed, and controlled through the shell. It does not answer whether that Harness is best. Comparing DSH, Codex, OMP, Pi, OpenCode, Claude Code, or another agent requires the same task set and independent measurements for task completion, regressions, latency, cost, tool fidelity, security behavior, and subjective fit. Provider quota and account type must be reported with those results.

OpenFish will not rank a Harness from repository stars, launch recency, naming, a single demo, or the shell's own compatibility result. A future benchmark report must publish its tasks, Harness and model versions, settings, accounts/billing modes, repetitions, failures, and raw redacted outcomes.

## Release evidence record

The exact release candidate supplies the evidence row, not the working-copy implementation. Record each item as **passed**, **failed**, or **not run**, with an artifact version and date:

1. Clean Apple Silicon setup and, when supported, clean Intel setup.
2. DSH, official Codex app-server, and OMP ACP live journeys.
3. Fresh generic ACP Pack and fresh non-ACP Driver conformance journeys.
4. Project and No Project creation, send, cancel, resume, archive, search, fork where supported, update, rollback, and uninstall retention.
5. Mac and iPhone loading, empty, setup, offline, recoverable, fatal, accessibility, resize, and Dynamic Type states.
6. Physical iPhone pairing, reconnect, follow-up, approval, question, continuity, voice allow/deny, repeated start/stop, background recovery, and revoke.
7. Source/history/assets privacy review, threat-model review, packaged-runtime checks, signing/notarization, and install/uninstall review.

Until these rows are recorded for the final artifact, the honest position is: **OpenFish now has a real differentiated control-plane implementation and one verified official Codex path, but its clean-install reliability and public impact are not yet demonstrated.**

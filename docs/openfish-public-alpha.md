# OpenFish Public Alpha

English | [中文](openfish-public-alpha.zh.md)

This release is for developers and early adopters who can inspect an agent's actions and report failures. It is not yet a stable, unattended coding product.

## What is ready

- A self-contained macOS app with a packaged DSH Host and managed Harness runtimes.
- Per-install default Harness selection and per-task Harness selection.
- No Project tasks stored in a dedicated OpenFish location rather than Desktop.
- Protocol-driven ACP model, reasoning, mode, and configuration controls.
- Progressive Harness Lens views on Mac and iPhone: a plain-language Overview, an evidence-backed relationship Map, a bounded ordered content-free Trace, and a Driver-backed Studio. Selecting a component filters the trace to the steps that touched it. Studio supports typed graph controls, undo/redo, material-change review, a non-mutating admission dry-run, exact-version install/live preflight, version retention, import, and credential-free export. A live preflight may still create provider-owned state or incur provider-specific setup cost.
- A visible proof ledger for every exact Pack version. It separates admitted declarations, resolved executable identity, observed real-session operations, Host compatibility evaluation, and an explicit opaque boundary; a later preflight cannot erase session evidence or certify a different version.
- A local Harness Lab that runs the same explicit task through two or more installed Harnesses in isolated No Project sessions with route-specific live model, reasoning, and permission choices, rotated order, repetitions, and timeout. OpenFish never answers an approval request on the user's behalf; the selected permission mode can still allow an operation without asking. Lab preserves each task for inspection, separates mechanical measurements from user-rated quality, and exports no response/account/path content.
- A generated community Pack catalog whose pull-request publishing path does not require an OpenFish app release.
- Exact self-installing Driver Bundle descriptors for public non-ACP Packs. After explicit local code consent, the Mac app uses its packaged Node/npm runtime to stage and structurally admit the exact Bundle, restart only its verified embedded Host, negotiate Driver API v1, and continue setup; the iPhone hands this operation to the paired Mac.
- Session pinning to the Harness Pack version that created the task.
- Native iPhone pairing, authenticated live reconnection, task projection, approvals, queueing, and voice input.
- Release-gate implementations for DSH, the official Codex app-server protocol, OMP's ACP behavior, a fresh synthetic ACP Pack, packaged Host lifecycle, privacy, macOS builds, and an iOS Simulator build. A real iPhone checklist is separate manual release evidence; this source tree does not pretend a Simulator proves the device path.

## Known limits

- macOS 14 or newer and iOS 17 or newer are the supported baselines.
- Source builds are unsigned. Tagged Mac artifacts are signed and notarized only when the repository owner configures Apple release credentials.
- Installing the iPhone app on a physical device requires the user's own Apple signing setup until a public TestFlight or App Store channel exists.
- A tag is not accepted merely because the source checks compile. Pairing, reconnect, approval, question, continuity, microphone allow/deny, repeated voice start/stop, foreground/background recovery, and remote revoke must be recorded against the final Mac build and a physical iPhone.
- The independent OpenFish bundle identifiers are `app.openfish.mac` and `app.openfish.ios` by default and can be overridden by release owners. The Mac app migrates pre-alpha preferences and remote credentials from the former DSH development id; an iPhone installed under the former id must be paired again.
- Pairing is direct over a trusted LAN or Tailscale. OpenFish does not operate a relay service and the Host port must not be exposed to the public internet.
- A task cannot change Harnesses after it starts. It keeps the exact Pack version and auth reference chosen at creation time.
- OpenFish discovers ACP configuration from the live Harness. A Harness that does not publish a model or reasoning option cannot be made configurable by guessing provider-specific flags.
- Harness Lab uses the selected accounts and may consume provider quota. It is an experiment surface, not a global ranking: a useful published comparison still needs disclosed tasks, exact versions, settings, account/billing modes, repetitions, failures, and redacted outcomes.
- Authentication and usage charges belong to the selected Harness/provider. OpenFish must show the auth method before launch, but it never grants model quota and never silently converts one provider's subscription into another.
- Built-in Codex and OMP Packs use exact versions tested with this OpenFish release. A public registry moving its `latest` tag never rewrites that trusted contract in place; a later OpenFish release exposes an explicit Pack update while retaining the installed version for rollback and pinned tasks.
- For Codex, OpenFish asks the live official app-server for the current authentication route and plan type and discards email and credential material. A task fork is offered only when the selected Driver exposes a real remote branch; Codex maps it to official `thread/fork`, while generic ACP currently leaves it disabled.
- ACP Registry or OpenFish community inclusion is discovery metadata, not a security audit or quality endorsement. A non-ACP Harness must publish a pinned Driver Bundle and still passes live Driver conformance before it becomes runnable; OpenFish never derives executable code from only a protocol or Harness name.
- Community publishing currently uses a reviewed GitHub pull request; OpenFish does not yet operate an in-app account, ranking system, or one-click marketplace backend.
- ACP Packs use typed controls whose Driver bindings target option ids discovered from the running Harness. Other node configuration has execution semantics only when that Pack's Driver validates and consumes it; the editor labels unsupported fields instead of pretending they run.
- ACP currently defines no permanent remote-session deletion. Abandoning a prepared generic ACP task stops the managed process and removes OpenFish's local blank draft, but the upstream Harness may retain its own blank-session record. The Codex Driver uses official `thread/delete` for the equivalent blank thread.
- Unknown Harness internals remain one opaque boundary. Rich Architecture views require a declared process boundary, a connected account of every responsibility actually shown, evidence for every component, and meaningful edge labels. There is no cosmetic node minimum, and the UI does not infer private internals.
- Older tasks can expose upstream compatibility breaks when their pinned runtime is no longer installable on a newer OS. Export important work.

## Five-minute acceptance check

1. Launch the Mac app on a machine without Node, Bun, uv, DSH, Codex, or Pi in `PATH` and choose a default Harness.
2. Create one No Project task and one project task; verify their locations are distinct and neither creation fails.
3. Open a fresh task, change Harness, choose a model, reasoning level, and permission mode when the live Harness advertises them, then send a prompt.
4. Restart the app and resume both tasks; verify each retains its Harness Pack version and configuration.
5. Pair an iPhone on LAN or Tailscale, read the tasks, send a follow-up, and approve or reject one requested action.

If any step fails, file the OpenFish bug template. Include only the first redacted error and never include credentials or private session content.

# OpenFish Public Alpha

English | [中文](openfish-public-alpha.zh.md)

This release is for developers and early adopters who can inspect an agent's
actions and report failures. It is not yet a stable, unattended coding product.

## What is ready

- A self-contained macOS app with a packaged DSH Host and managed Harness
  runtimes.
- Per-install default Harness selection and per-task Harness selection.
- No Project tasks stored in a dedicated OpenFish location rather than Desktop.
- Protocol-driven ACP model, reasoning, mode, and configuration controls.
- Session pinning to the Harness Pack version that created the task.
- Native iPhone pairing, task projection, approvals, queueing, and voice input.
- Release gates for DSH, Codex ACP, Pi-compatible ACP behavior, packaged Host
  lifecycle, privacy, macOS builds, and an iOS simulator build.

## Known limits

- macOS 14 or newer and iOS 17 or newer are the supported baselines.
- Source builds are unsigned. Tagged Mac artifacts are signed and notarized
  only when the repository owner configures Apple release credentials.
- Installing the iPhone app on a physical device requires the user's own Apple
  signing setup until a public TestFlight or App Store channel exists.
- The independent OpenFish bundle identifiers are `app.openfish.mac` and
  `app.openfish.ios` by default and can be overridden by release owners. The Mac
  app migrates pre-alpha preferences and remote credentials from the former DSH
  development id; an iPhone installed under the former id must be paired again.
- Pairing is direct over a trusted LAN or Tailscale. OpenFish does not operate a
  relay service and the Host port must not be exposed to the public internet.
- A task cannot change Harnesses after it starts. It keeps the exact Pack
  version and auth reference chosen at creation time.
- OpenFish discovers ACP configuration from the live Harness. A Harness that
  does not publish a model or reasoning option cannot be made configurable by
  guessing provider-specific flags.
- Authentication and usage charges belong to the selected Harness/provider.
  OpenFish must show the auth method before launch, but it never grants model
  quota and never silently converts one provider's subscription into another.
- ACP Registry inclusion is discovery metadata, not an OpenFish security audit
  or quality endorsement. Non-ACP Harnesses still require a Driver plugin.
- Older tasks can expose upstream compatibility breaks when their pinned
  runtime is no longer installable on a newer OS. Export important work.

## Five-minute acceptance check

1. Launch the Mac app on a machine without Node, Bun, uv, DSH, Codex, or Pi in
   `PATH` and choose a default Harness.
2. Create one No Project task and one project task; verify their locations are
   distinct and neither creation fails.
3. Open a fresh task, change Harness, choose a model and a reasoning level when
   the live Harness advertises them, then send a prompt.
4. Restart the app and resume both tasks; verify each retains its Harness Pack
   version and configuration.
5. Pair an iPhone on LAN or Tailscale, read the tasks, send a follow-up, and
   approve or reject one requested action.

If any step fails, file the OpenFish bug template. Include only the first
redacted error and never include credentials or private session content.

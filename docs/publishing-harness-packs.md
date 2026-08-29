# Publish an OpenFish Harness Pack

English | [中文](publishing-harness-packs.zh.md)

This tutorial publishes a credential-free Harness Pack to the OpenFish community catalog. The catalog is discovery metadata, not an OpenFish security endorsement.

## Prerequisites

- The Harness speaks ACP, OpenFish already contains a Driver for its protocol, or the Pack declares an exact self-installing Driver Bundle whose package registers Driver API v1.
- npm, Bun, and Python distributions use an exact version. Binary archives include a SHA-256 checksum.
- Authentication fields name credential references; the Pack contains no API key, token, password, private path, hostname, or private conversation data.

## Export and test

1. Open **Settings → Harnesses** on the Mac.
2. Create or edit the Pack in Harness Studio. Use `opaque` when the Harness does not publish internals; it must expose exactly one runtime boundary. `observable` and `composable` manifests must name the Harness process boundary, connect every responsibility they show, label important data/control flow, and cite declared, resolved, or observed evidence for the graph and every component. A truthful one-component runtime is valid; never add filler nodes, OpenFish, the operating system, or a model provider merely to make the diagram look complete. Use `composable` only for nodes the Pack actually permits OpenFish to edit. Add schema-driven controls only when the selected Driver defines and validates their binding; the ACP Driver accepts `acp-session-option` bindings. A `secret-reference` control stores only a Host reference such as `OPENAI_API_KEY`, never the secret value. OpenFish validates controls against the live Harness before the first turn; unknown bindings are rejected instead of being treated as executable. Protocol-specific live facts use `driver.<protocol>.*` signals and require a Driver mapper; OpenFish projects only signal/status, never prompt, path, tool argument, or account content.
3. Open **Review** and inspect the material-change summary. Run **Validate draft** first: it executes the same schema and Driver admission path as save but does not modify the catalog, install code, or launch the Harness. Editing afterward makes that result stale. Save only the reviewed exact version.
4. For a non-bundled protocol, fill **Self-installing Driver Bundle** with the npm package identity and either an exact `package@version` or `github:owner/repository#<full-commit>`. The Bundle patch may activate only modules owned by that package. Declare npm lifecycle scripts only when unavoidable; every installing user sees a separate local-code warning. **Install & live preflight** stages the same exact Bundle, restarts only OpenFish's verified embedded Host, and waits for its Driver registration before testing the Harness. This step is intentionally separate because it can create Harness-owned state or provider-specific setup cost.
5. Start a No Project task and a project task with the Pack. Confirm installation, authentication, model/config/permission discovery, cancellation, and resume. Verify that the proof ledger attributes admission, preflight, and session observations to the correct exact version.
6. Choose **Prepare community submission**. OpenFish requires a public HTTPS source repository and license, refuses private paths, credentialed URLs, and credential-like values, and writes `{id}.openfish-harness.json` plus a redacted compatibility report.

## Submit

1. Fork the [OpenFish repository](https://github.com/Yusong-Enceladus/OpenFish).
2. Add the exported file beneath `community/harnesses/packs/` with a filename matching its Pack id.
3. Run `pnpm run gen-openfish-community-catalog` and `pnpm run test:harness-contract`.
4. Open a pull request containing the manifest, generated `community/harnesses/index.json`, the Harness repository link, supported operating systems, and a redacted compatibility report.

After review and merge, OpenFish clients discover the Pack during catalog refresh. Community Packs remain marked unverified until OpenFish separately records release-blocking evidence; inclusion never grants access to model quota or credentials.

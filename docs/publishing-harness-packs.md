# Publish an OpenFish Harness Pack

English | [中文](publishing-harness-packs.zh.md)

This tutorial publishes a credential-free Harness Pack to the OpenFish community catalog. The catalog is discovery metadata, not an OpenFish security endorsement.

## Prerequisites

- The Harness speaks ACP, or OpenFish already contains a Driver for its protocol.
- npm, Bun, and Python distributions use an exact version. Binary archives include a SHA-256 checksum.
- Authentication fields name credential references; the Pack contains no API key, token, password, private path, hostname, or private conversation data.

## Export and test

1. Open **Settings → Harnesses** on the Mac.
2. Create or edit the Pack in Harness Studio. Use `opaque` when the Harness does not publish internals; it must expose exactly one runtime boundary. `observable` and `composable` manifests must name the Harness process boundary, include at least three connected runtime responsibilities, and cite declared, source-derived, or runtime-observed evidence for the graph and every component. Never add OpenFish, the operating system, or a model provider as a node merely to make the diagram look complete. Use `composable` only for nodes the Pack actually permits OpenFish to edit. For portable ACP defaults, put an `acpSessionOptions` object on an editable node, for example `{"acpSessionOptions":{"model":"model-id","mode":"plan"}}`. OpenFish validates those ids and values against the live Harness before the first turn; other config keys are descriptive unless the Pack's Driver defines them.
3. Start a No Project task and a project task with the Pack. Confirm installation, authentication, model/config discovery, cancellation, and resume.
4. Choose **Prepare Publication**. OpenFish refuses to export a distribution environment that appears to contain credential values and writes `{id}.openfish-harness.json`.

## Submit

1. Fork the [OpenFish repository](https://github.com/Yusong-Enceladus/OpenFish).
2. Add the exported file beneath `community/harnesses/packs/` with a filename matching its Pack id.
3. Run `pnpm run gen-openfish-community-catalog` and `pnpm run test:harness-contract`.
4. Open a pull request containing the manifest, generated `community/harnesses/index.json`, the Harness repository link, supported operating systems, and a redacted compatibility report.

After review and merge, OpenFish clients discover the Pack during catalog refresh. Community Packs remain marked unverified until OpenFish separately records release-blocking evidence; inclusion never grants access to model quota or credentials.

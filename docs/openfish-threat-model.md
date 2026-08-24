# OpenFish threat model

English | [中文](openfish-threat-model.zh.md)

This document describes the security boundary of the OpenFish Public Alpha. It is a design and release-review input, not a guarantee that third-party agent code is safe.

## Assets and trust boundaries

OpenFish separates five authorities:

1. The native Mac and iPhone clients present state and user decisions.
2. The DSH-based Host owns durable tasks, managed runtime files, credentials, process supervision, and paired-device transport.
3. The selected Harness owns its agent loop, protocol behavior, model traffic, tools, and remote-session semantics.
4. The selected account/provider owns authentication, billing, retention, and model service policy.
5. A project or No Project directory defines the file boundary requested for that task.

The Host, a Harness process, a model provider, a Pack publisher, and a paired phone are not interchangeable trust identities. OpenFish displays these identities separately and pins Harness version, authentication-method name, workspace mode, model, reasoning option, and negotiated capabilities to the task. Secret values and authentication cookies are never part of that task identity.

## Threats, controls, and residual risk

### Harness and dependency supply chain

- Built-in, ACP Registry, OpenFish community, and user Packs are labeled separately. Discovery, publisher verification, installation integrity, protocol compatibility, and a successful runtime test are independent facts.
- User and community package distributions must be exact-version pins. Every remote binary installation requires SHA-256 and a credential-free HTTPS source; Registry entries without a checksum may remain discoverable but cannot install. ZIP/TAR extraction runs in-process with entry/path/compressed/unpacked limits, rejects links, devices, duplicate outputs, and traversal, and normalizes the resulting private file modes. npm/Bun package pins currently identify an exact registry version but are not presented as a cryptographic checksum when none is available.
- Installation is staged and promoted atomically. The previous installed Pack is retained for rollback, and versions referenced by tasks cannot be uninstalled silently.
- Third-party Driver Bundle package-manager and lifecycle scripts run with a closed, operation-private environment: private HOME/cache/temp roots, empty npm user and global configs, the public npm registry, the packaged toolchain path, disabled system Git configuration and credential prompts, and no inherited provider keys, npm tokens, shell hooks, `NODE_OPTIONS`, or `NODE_PATH`. A project `.npmrc` is rejected rather than borrowing a private-registry trust context. The admitted Driver code itself remains trusted Host plugin code after the explicit Mac authorization step.
- Driver lifecycle scripts are disabled by default. The Mac records consent against the exact Driver source; rollback reuses that recorded choice and refuses an older source whose consent is unknown. The Plugins page exposes the recorded state.
- Registry or community inclusion is not source review, malware review, or an endorsement. Package-manager infrastructure and upstream maintainer compromise remain residual risks.

### Harness process authority

- Managed Harnesses receive a private HOME, cache, config, data, and temporary root. The ambient user home is hidden. Readable roots are limited to the selected workspace, exact installation/runtime snapshot, packaged OpenFish runtime, and authentication roots explicitly required by the chosen method.
- The embedded Host starts from an allowlisted environment rather than the Mac app's ambient environment. Provider keys, package-manager credentials, shell hooks, `NODE_OPTIONS`, `SSH_AUTH_SOCK`, and unrelated app variables are not inherited by the Host or forwarded to Harness processes.
- In read-only and workspace-write modes, OpenFish requires a platform sandbox that enforces protected reads, filesystem writes, denial of inbound listeners, host-process control, and host IPC. Launch fails when the resident-process boundary reports only partial enforcement.
- Outbound network access remains available because remote model providers and package registries require it. A Harness can send data it is allowed to read to its provider. `danger-full-access` is an explicit user-authorized bypass of the OpenFish process confinement. Neither mode is a virtual machine.
- A compromised Harness can misuse the workspace, its own injected credential, and any authority the user explicitly granted. OpenFish cannot make untrusted agent code safe after granting that authority.

### Credentials and billing

- Secret values are written only through the Host credential service and native Keychain-backed stores. Packs contain credential references and non-secret authentication-method names, never API keys, passwords, bearer tokens, cookies, recovery codes, or one-time pairing codes.
- Only the selected Harness process receives the credentials required by its selected authentication method. Host-local credential and Pack-authoring RPCs are denied to non-loopback clients.
- OpenFish shows whether a task uses a subscription, usage-billed API, local model, or Harness-managed account when the Pack/Driver can prove it. OpenFish does not convert one provider's subscription into another and cannot guarantee upstream billing or retention behavior.

### Mac–iPhone connection

- Pairing codes can be created only from loopback, expire, and are redeemed once. Remote redemption requires a TLS-certificate-bound HMAC made with the out-of-band code itself; the public code id crossing the bootstrap connection is insufficient to forge that proof. The Host keeps the raw code only in memory until redemption or expiry, persists paired tokens only as SHA-256 digests, and the phone stores its bearer credential and pinned Host certificate fingerprint in Keychain.
- Remote requests require an allowed Host authority, an accepted TLS socket, the pinned Host certificate, and paired authentication. Credential/settings mutation, model-provider discovery that may reveal local configuration, Pack authoring/removal, Driver Bundle authorization, interactive terminal login, file pickers, and administration of other devices remain loopback-only. A paired device can revoke only its own proven registration; the Host Mac can list and revoke every device. A paired phone may request a reviewed Pack lifecycle action, but it cannot authorize Host code.
- The current direct transport is intended only for a trusted LAN or Tailscale and does not provide an OpenFish relay. OpenFish refuses plain HTTP for a remote Host; Tailscale or another authenticated network layer is still recommended for reachability and exposure control. Never expose the Host port to the public internet.
- The packaged Host keeps one matching TLS certificate/key pair until certificate expiry so a routine restart cannot silently strand pinned phones. Invalid, mismatched, or expired material is replaced transactionally; replacement changes the fingerprint and therefore requires pairing again.
- A paired phone can perform the task actions exposed by the remote contract, including prompts and approvals. Revoke lost or shared devices immediately.

### Driver Bundle authorization

- A non-bundled protocol Pack cannot install, authenticate, preflight, become the default, create, resume, or fork until the Mac app has admitted its exact Driver source, restarted the verified embedded Host, observed the Driver registration, and committed a loopback-only authorization record.
- Authorization is scoped to the protocol and exact package source. Activating a different Driver source replaces the prior proof; an older Pack then stops with an actionable exact-version message instead of silently running through newer code.
- The record contains only package identity, exact source, and authorization time. It contains no package-manager credential, provider secret, session token, or user content.

### Tasks, files, and diagnostics

- No Project tasks use a per-session directory below the private OpenFish data root rather than Desktop or the Host launch directory. Project tasks use the selected project root. Deleting or discarding a No Project task removes its managed directory only after the session lifecycle releases it.
- Mac and iPhone offline projections are stored per Host in an owner-only OpenFish Application Support directory, excluded from backups; iPhone also applies Data Protection. Composer text and pending attachments are never cached. Revocation or explicit unpair purges that Host projection and draft identity.
- Native clients preallocate and persist only the id and Harness id of a prepared blank task. A retry adopts that exact id, so a lost response or app restart does not create another upstream conversation. Codex can permanently delete the matching blank thread; ACP has no standard remote-delete operation, so a generic ACP Harness may retain provider-owned blank-session state according to its own protocol.
- Session logs necessarily contain prompts, model output, tool results, paths, and approval history. Runtime Architecture projections record content-free signal names and node/edge status; they do not copy prompts, commands, credentials, account labels, or tool arguments.
- Compatibility reports contain build/platform, Harness/Driver versions, workspace mode, authentication-method name, capability results, and a first redacted failure. Public exports reject common private paths, local hosts, private IP addresses, credential-like values, unpinned packages, and secret-bearing environment fields.
- Users must review exported tasks, Packs, diagnostics, screenshots, and issue attachments. Automated redaction cannot recognize every confidential project name or business fact.

### Community publication and public assets

- Publishing prepares a credential-free Pack and compatibility report for an explicit repository pull request. It does not silently upload source, task content, credentials, or local runtime files.
- Public screenshots must come from the network-isolated deterministic Demo State. The release check rejects embedded image metadata and OCR-detectable personal paths, email addresses, local hostnames, private IP addresses, and credential-like text. Human review is still required because OCR and regular expressions are incomplete.
- Demo State uses synthetic projects, tasks, accounts, models, errors, approvals, and architecture evidence. It does not read production state, start the Host, contact a provider, or request microphone access.

## Release review

A public release requires source secret/path scanning, public-asset metadata and OCR review, dependency-license and third-party notice review, packaged-bundle path and symlink checks, Harness contract tests, supported native builds, and a manual review of the final Git history and release artifacts. Physical iPhone continuity and microphone checks are manual release evidence until a trustworthy device lab exists; simulator builds must not be described as physical-device proof.

Report vulnerabilities through GitHub's private **Security → Report a vulnerability** flow described in [SECURITY.md](../SECURITY.md).

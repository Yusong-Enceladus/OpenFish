# Security policy

OpenFish runs local coding agents that can read files and execute commands with
the permissions approved by the user. Treat every Harness Pack, ACP Registry
entry, plugin, MCP server, and project instruction file as executable or
model-visible third-party input.

## Reporting a vulnerability

Do not open a public issue for a vulnerability, credential exposure, or a bug
that can execute commands outside the displayed approval boundary. Use this
repository's GitHub **Security → Report a vulnerability** flow. Include the
affected OpenFish build, OS/architecture, Harness id/version, minimum
reproduction, and impact. Remove API keys, tokens, private source, personal
paths, and session transcripts unless a maintainer explicitly requests a
redacted sample in the private report.

## Supported versions

OpenFish is a Public Alpha. Security fixes target the newest tagged alpha only;
older Harness Pack versions remain runnable for pinned tasks but may be denied
for new installation when a known unsafe distribution is identified.

## Security boundaries

- Harness credentials are stored through the Host credential API and native
  Keychain; they must never be placed in a Pack's ordinary environment map.
- Pairing tokens are returned once and persisted by the Host only as SHA-256
  digests. A paired device can be revoked from the Host.
- ACP Registry metadata is not a code audit. OpenFish reports registry status
  separately from runtime compatibility.
- `workspace-write` is not a virtual machine. A Harness retains the authority
  its own sandbox and the operating system grant it.
- LAN connections should remain on a trusted network or Tailscale. Do not
  expose the Host port directly to the public internet.

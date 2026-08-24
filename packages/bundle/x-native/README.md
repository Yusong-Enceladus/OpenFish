# OpenCodex native bootstrap bundle

English | [中文](README.zh.md)

DSH plugin for the small protocol a native OpenCodex client needs before it joins the ordinary DSH API. It owns discovery, capability negotiation, the live method manifest, and native-device identity. Business RPC remains on the existing DSH `/api` gateway; this bundle does not duplicate session, workspace, agent, tool, approval, settings, or voice-domain operations.

## Routes

| Method | Path | Purpose |
|---|---|---|
| GET | `/x-native/v2/health` | liveness + versioned handshake |
| GET | `/x-native/v2/capabilities` | live composition and transport facts |
| GET | `/x-native/v2/methods` | live `/api` method manifest for native codegen |
| POST | `/x-native/v2/pairing-code` | mint a short-lived code on the Host |
| POST | `/x-native/v2/pair` | register a local device or redeem a remote code |
| GET | `/x-native/v2/devices` | list non-secret device records on the Host |
| POST | `/x-native/v2/revoke` | revoke a device token on the Host |
| POST | `/x-native/v2/self/revoke` | revoke only the authenticated calling device |

## Protocol facts

- `protocolVersion: v2` and `minimumClientProtocol: v2` come from the composed bootstrap contract. Current native clients reject an incompatible handshake before loading business state.
- `api.base: /api`, with events on `/api/events.host` and `/api/events.mux`; those paths are owned by `dsh-client-connection` and are mirrored here only as bootstrap discovery facts.
- The method manifest is derived from the live Typert local registry, so it is empty when no `typert` service is composed and automatically includes every mounted remote namespace in the full Web profile.
- Pairing records are stored under `$DSH_HOME/x-native/devices.json` (override with `config.dataDir`). Tokens are persisted as SHA-256 digests; the secret is returned exactly once at pairing time.
- A local client may pair directly. A remote client must redeem a ten-minute, single-use code created on the Host through TLS code proof: the HMAC is keyed by the out-of-band code itself and bound to the Host certificate fingerprint, so the public code id sent on the bootstrap connection cannot manufacture a valid proof. The resulting bearer is accepted by the ordinary DSH HTTP and WebSocket trust boundary; device listing, code creation, and revocation of other devices remain Host-local, while a paired device may revoke only itself.
- LAN and Tailscale use the same authenticated DSH carrier. Relay remains a replaceable transport plugin and is reported only when mounted.
- The image-generation capability flag describes the mounted provider registry. OpenCodex intentionally ships no image model.
- A native task created without a Workspace uses its own `$DSH_HOME/openfish/no-project/<session-id>` cwd; it never inherits the folder that launched the Host process or shares another No Project task's files.

## Composition

The bundle must be mounted in a web/native host profile:

```yaml
- insert:
    - id: x-native
      name: '@deepseek-ai/dsh-bundle-x-native'
      inject: [webServer, connection]
      config:
        protocolVersion: v2
```

It does not belong in headless and does not modify the anchored agent preset.

## Verification

```sh
pnpm build:lib:host
pnpm vitest run packages/bundle/x-native/tests/x-native.spec.ts
DSH_HOME=<profile home> dsh --profile x-native-dev --host 127.0.0.1 --port 3180
curl http://127.0.0.1:3180/x-native/v2/capabilities
```

## Security boundary

- Pairing codes live only in Host memory, expire after ten minutes, and are consumed before device registration begins. The raw code never crosses the bootstrap request and never reaches disk.
- The HTTP parser requires a supported client surface and a non-empty device name before it can mutate the registry; malformed pairing and revocation bodies fail with `invalid-request`.
- Device mutations are serialized, the registry is written atomically with mode `0600`, and bearer comparison uses constant-time digest comparison.
- A bearer authorizes the ordinary non-privileged DSH API. Configuration and credential methods retain the Host connection layer's stricter loopback-only policy.
- The registry currently has deployment-wide authorization rather than per-device ACLs. Relay behavior belongs to the selected relay plugin, not this bundle.

## Model Experience

None, as this bootstrap-only bundle registers no model-facing prompts, tools, schemas, or results.

#### KV Cache effect

None; bootstrap metadata never enters the model request prefix.

## Known Limitations and Deferred Work

- Authorization is deployment-wide rather than scoped per device, workspace, or session.
- Relay transport is intentionally deferred to a replaceable DSH transport plugin.
- Migration/import capability is advertised only when the composed rc.8 Host exposes it; it is not a native bootstrap responsibility.

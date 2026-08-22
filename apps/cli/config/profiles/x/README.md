# OpenCodex product profile template

English | [中文](README.zh.md)

The directory and `dsh --profile x` spelling are legacy compatibility names. This template composes the OpenCodex host on DSH: the launcher installs the installation-owned floor (`dsh-base` + `dsh-web-app` + `dsh-bundle-x-native`), and this directory adds voice, scheduling, and time context as ordinary Cordis plugins. DSH remains the only runtime and durable session owner; `x-native` contributes bootstrap discovery, version negotiation, pairing, identity, and transport facts only.

Run directly from a source checkout:

```sh
pnpm dsh --profile x --port 3080
```

The CLI materializes this complete template on first use. OpenCodex binds to LAN/Tailscale by default and requires a paired device bearer for every remote API or WebSocket request; pass `--host 127.0.0.1` for a local-only Host.

The anchored agent preset ships beside this template at `apps/cli/config/agent-presets/anchored` and is mounted automatically from the installation's shipped preset root with system trust. Select it as the default from Settings → Agent presets or per session. The legacy profile name does not authorize product behavior outside ordinary DSH services and Cordis composition.

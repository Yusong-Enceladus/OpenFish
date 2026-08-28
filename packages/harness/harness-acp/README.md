# `@deepseek-ai/dsh-harness-acp`

English | [中文](README.zh.md)

This package is the generic ACP driver behind Open Fish Harness Packs. Installation uses the bundled, pinned Node/npm or Bun runtime and places each Pack version under Open Fish managed state. Sessions launch the executable from that exact snapshot with shell-free argv, rather than resolving the network package again. The driver then projects the remote ACP session through the ordinary DSH `Agent`, `Session`, inbox, approval, cancellation, and status contracts.

## Model Experience

### ACP-owned conversation

#### What the model sees

The selected ACP Harness receives the user's ordered text prompt through ACP `session/prompt`. Open Fish does not inject DSH system prompts or tool schemas into that remote Harness conversation.

#### Token effect

Data-dependent and owned by the selected Harness and its model provider; this bridge adds no prompt tokens.

#### KV Cache effect

Append-only within the remote Harness session when that Harness supports ACP load-session; Open Fish fails resume instead of creating unrelated history.

## Known Limitations and Deferred Work

- Generic ACP bridges permission requests, image prompts, workspace-confined text-file operations, and bounded client terminals. The selected Harness still owns its own agent loop and decides which of those standard callbacks it uses.
- Authentication methods declared by the Pack are selectable in OpenFish. Agent-owned browser login stays with the Harness; API keys are resolved per launch from the Host's write-only credential service and never enter Pack state.
- Codex uses a separate built-in Driver for the official `codex app-server` protocol, including its live account, model/reasoning, thread resume/delete, and real `thread/fork` operations. It is not routed through the generic ACP adapter.
- Generic ACP has no standard provider-side session-delete or fork primitive. OpenFish stops an abandoned ACP draft locally and disables fork instead of pretending those remote semantics exist.
- Managed Harness processes launch inside the selected OpenFish workspace and process sandbox profile with private HOME/cache/config/temp roots. Publisher metadata and ACP Registry transport still do not replace package integrity, sandbox enforcement, or explicit user approval.
- Checksummed platform archives are extracted in-process rather than delegated to host archive tools. OpenFish accepts ZIP, TAR, TAR.GZ, TGZ, TAR.BZ2, and TBZ2, rejects links and non-regular archive entries, caps the archive at 20,000 entries, 1,024-byte paths, 512 MiB compressed, and 2 GiB unpacked/decompressed, and never writes outside a fresh managed version directory. A directly downloaded executable remains supported when its declared SHA-256 matches.

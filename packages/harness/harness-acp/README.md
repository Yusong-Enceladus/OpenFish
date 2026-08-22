# `@deepseek-ai/dsh-harness-acp`

[中文](README.zh.md)

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

- The driver advertises terminal authentication but no ACP tool-terminal or file-system client operations; Harnesses execute their own tools and request permission through ACP.
- Prompt attachments and tool-terminal callbacks are not part of this v0 driver. Authentication methods declared by the Pack are selectable in the shell. Agent-owned browser login stays with the Harness; API keys are resolved per launch from the Host's write-only credential service and passed in the ACP authentication request without entering Pack state.
- Codex currently runs through the ACP Registry adapter, which invokes the official open-source Codex package underneath. A direct Codex App Server Driver would expose more provider-native events than the ACP surface and remains a fidelity upgrade, not a prerequisite for selecting or running Codex.
- Package execution runs third-party code with the Host process's configured OS authority; publisher metadata and ACP Registry transport do not replace package-manager integrity, OS sandboxing, or user approval.

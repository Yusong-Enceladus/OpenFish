# @deepseek-ai/dsh-agent-default-model

English | [中文](README.zh.md)

The deployment default used when an entry point creates an Agent that has no session-local model selection. `AgentDefaultModelConfig` provides `ctx.agentDefaultModel`; direct entry points such as `dsh --profile headless` and Host-backed entry points such as ApiProxy read the same service instead of owning parallel provider/model defaults.

The plugin config requires `{ provider, model }`. That composition entry is the base of the `agent-default-model` Settings section; a mounted settings provider layers the user's choice over it and changes are visible on the next `currentSelection()` read. `reasoningEffort` belongs to the Settings section but deliberately not to plugin config: a complete saved selection can clear an effort when the next selected model has none, while a composition value would be inherited again.

- `ctx.agentDefaultModel.currentSelection()` returns a detached `{ provider, model, reasoningEffort? }` selection for a newly created Agent.
- `ctx.agentDefaultModel.saveSelection(selection)` saves the complete user selection. Without a settings provider it is a no-op and the composition entry remains current.

The service does not validate catalog membership. A provider route may serve an unadvertised model, and the consumer that actually opens a model request owns availability diagnostics.

## Model Experience

Indirectly, through the provider/model selection supplied to an entry point; request assembly and adapters own the model-visible request.

#### KV Cache effect

Changing the default affects only sessions that have never accepted a task-local choice and have not assembled a request. `agent/model-selected` records an accepted choice even while New Task is blank; older sessions fall back to their latest `request/header`. Either durable pin keeps an established session from drifting when the process-wide default changes.

## Known Limitations and Deferred Work

- The service owns one process-wide default; `@deepseek-ai/dsh-agent` owns the durable per-session selection event and entry points decide when to record an accepted choice.
- Without a settings provider, `saveSelection()` cannot retain a selection for a later Agent.

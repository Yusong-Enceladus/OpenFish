/**
 * Agent-scoped model selection shared by runtime entry points.
 * @module @deepseek-ai/dsh-agent/model-selection
 */

import type { Context } from '@deepseek-ai/cordis'
import type { LlmCallConfig, ReasoningEffortId } from '@deepseek-ai/dsh-llm'
import type { Session, SessionEvent } from '@deepseek-ai/dsh-session'

declare module '@deepseek-ai/dsh-session/types' {
  interface SessionEventMap {
    /**
     * Complete model choice accepted for this session. Unlike request/header,
     * this log-only user intent also exists before the first prompt and is
     * therefore the durable pin for a blank task across Host restarts.
     */
    'agent/model-selected': {
      provider: string
      model: string
      reasoningEffort?: string
    }
  }
}

/** Complete provider, model, and optional reasoning effort selected for one live Agent. */
export interface ModelSelection {
  /** Registered provider route. */
  provider: string
  /** Provider-owned model id. */
  model: string
  /** Adapter-owned reasoning effort, or provider/default behavior when absent. */
  reasoningEffort?: ReasoningEffortId
}

/** Mutable model selection plus the value captured for the current step. */
export interface ModelSelectionRef {
  /** Model selected for the next step that enters prompt assembly. */
  current: ModelSelection | undefined
  /** Selection captured when the current step entered prompt assembly. */
  assembled: ModelSelection | undefined
}

/**
 * Compare two complete selections without treating an absent effort as a default string.
 * @param left - first complete selection, or no selection.
 * @param right - second complete selection, or no selection.
 * @returns whether provider, model, and optional effort are identical.
 */
export function sameModelSelection(left: ModelSelection | undefined, right: ModelSelection | undefined): boolean {
  return left?.provider === right?.provider
    && left?.model === right?.model
    && left?.reasoningEffort === right?.reasoningEffort
}

/**
 * Fold the last accepted session-local model choice from the durable log.
 * This is intentionally independent from request/header: a user can select a
 * model while a New Task is still blank, then quit before sending a prompt.
 * @param events - durable session log in append order.
 * @returns the last accepted selection, or undefined when none was recorded.
 */
export function effectiveSessionModelSelection(events: readonly SessionEvent[]): ModelSelection | undefined {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event?.type !== 'agent/model-selected') continue
    return {
      provider: event.data.provider,
      model: event.data.model,
      ...event.data.reasoningEffort === undefined
        ? {}
        : { reasoningEffort: event.data.reasoningEffort as ReasoningEffortId },
    }
  }
  return undefined
}

/**
 * Persist an accepted selection before acknowledging the switch to a client.
 * Re-selecting the identical value is inert so reconnect retries do not grow
 * the append-only log.
 * @param session - session whose durable model pin is changing.
 * @param selection - complete accepted provider, model, and effort choice.
 */
export function recordSessionModelSelection(session: Session, selection: ModelSelection): void {
  if (sameModelSelection(effectiveSessionModelSelection(session.events), selection)) return
  session.append('agent/model-selected', {
    provider: selection.provider,
    model: selection.model,
    ...selection.reasoningEffort === undefined
      ? {}
      : { reasoningEffort: String(selection.reasoningEffort) },
  })
}

/**
 * Couple one mutable selection to Agent-scoped prompt assembly and request routing.
 * Prompt assembly snapshots the selected model before delegating, then applies
 * its provider/model pair and effort to request config so a
 * concurrent switch takes effect on a later step instead of splitting the two
 * surfaces. An absent selected effort clears any inherited effort, restoring
 * the selected model's provider/default behavior.
 *
 * @param agentCtx - The selected Agent's scoped context.
 * @param selection - Mutable selection owned by the calling entry point.
 * @returns Disposer for both scoped waterfall listeners.
 */
export function installModelSelection(agentCtx: Context, selection: ModelSelectionRef): () => void {
  const disposeAssembly = agentCtx.on('system-prompt/assemble', async (_assembly, _context, next) => {
    const selected = selection.current
    const assembled = await next()
    selection.assembled = selected
    if (selected === undefined) return assembled
    return {
      ...assembled,
      variables: {
        ...assembled.variables,
        provider: selected.provider,
        model: selected.model,
      },
    }
  })
  const disposeRequest = agentCtx.on(
    'agent/request',
    async (_payload, next): Promise<LlmCallConfig> => {
      const resolved = await next()
      const selected = selection.assembled
      if (selected === undefined) return resolved
      const { reasoningEffort: _inheritedEffort, ...withoutInheritedEffort } = resolved
      return {
        ...withoutInheritedEffort,
        provider: selected.provider,
        model: selected.model,
        ...selected.reasoningEffort === undefined
          ? {}
          : { reasoningEffort: selected.reasoningEffort },
      }
    },
  )
  return () => {
    disposeAssembly()
    disposeRequest()
  }
}

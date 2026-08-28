/** Minimal, privacy-safe durable projections of third-party Harness events. @module */

import type { SessionNotification } from '@agentclientprotocol/sdk'
import { safeHarnessEventValue } from '@deepseek-ai/dsh-harness'

type JsonRecord = Record<string, unknown>

function record(value: unknown): JsonRecord | undefined {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as JsonRecord
    : undefined
}

function shortString(value: unknown, maximum = 4_096): string | undefined {
  if (typeof value !== 'string' || value.length === 0 || value.length > maximum) return undefined
  if (/[\u0000-\u001f\u007f]/u.test(value)) return undefined
  return value
}

function contentProjection(value: unknown): unknown | undefined {
  const block = record(value)
  const type = shortString(block?.type, 64)
  if (block === undefined || type === undefined) return undefined
  if (type === 'text') return { type, text: block.text }
  if (type === 'resource_link') {
    return { type, name: block.name, title: block.title, uri: block.uri, mimeType: block.mimeType }
  }
  if (type === 'resource') {
    const resource = record(block.resource)
    if (resource === undefined || typeof resource.text !== 'string') return undefined
    return { type, resource: { uri: resource.uri, mimeType: resource.mimeType, text: resource.text } }
  }
  // Images, audio, and binary resources are deliberately omitted here. Agent
  // message images use the AttachmentStore; duplicating base64 in a native
  // event would bypass its type and size policy.
  return undefined
}

function toolContentProjection(value: unknown): unknown | undefined {
  const block = record(value)
  const type = shortString(block?.type, 64)
  if (block === undefined || type === undefined) return undefined
  if (type === 'content') {
    const content = contentProjection(block.content)
    return content === undefined ? undefined : { type, content }
  }
  if (type === 'diff') {
    return { type, path: block.path, oldText: block.oldText, newText: block.newText }
  }
  if (type === 'terminal') return { type, terminalId: block.terminalId }
  return undefined
}

function toolProjection(update: JsonRecord, sessionUpdate: 'tool_call' | 'tool_call_update'): unknown | undefined {
  const toolCallId = shortString(update.toolCallId, 512)
  if (toolCallId === undefined) return undefined
  return safeHarnessEventValue({
    sessionUpdate,
    toolCallId,
    title: update.title,
    kind: update.kind,
    status: update.status,
    rawInput: update.rawInput,
    rawOutput: update.rawOutput,
    content: Array.isArray(update.content)
      ? update.content.map(toolContentProjection).filter(value => value !== undefined)
      : update.content,
    locations: Array.isArray(update.locations)
      ? update.locations.map((value) => {
        const location = record(value)
        return location === undefined ? undefined : { path: location.path, line: location.line }
      }).filter(value => value !== undefined)
      : update.locations,
  })
}

/**
 * Keep only ACP updates needed to reconstruct OpenFish-owned UI. Streamed
 * model text/thoughts and media are projected into canonical assistant events
 * elsewhere and must never be duplicated as opaque provider state.
 * @param update - One live ACP Session notification update.
 * @returns The bounded durable projection, or `undefined` for live-only data.
 */
export function durableAcpSessionUpdate(update: SessionNotification['update']): unknown | undefined {
  switch (update.sessionUpdate) {
    case 'tool_call':
    case 'tool_call_update':
      return toolProjection(update as unknown as JsonRecord, update.sessionUpdate)
    case 'plan':
      return safeHarnessEventValue({ sessionUpdate: update.sessionUpdate, entries: update.entries })
    case 'plan_update':
      return safeHarnessEventValue({ sessionUpdate: update.sessionUpdate, plan: update.plan })
    case 'plan_removed':
      return safeHarnessEventValue({ sessionUpdate: update.sessionUpdate })
    case 'available_commands_update':
      return safeHarnessEventValue({
        sessionUpdate: update.sessionUpdate,
        availableCommands: update.availableCommands.map(command => ({
          name: command.name,
          description: command.description,
          ...(command.input === undefined || command.input === null
            ? {} : { input: { hint: command.input.hint } }),
        })),
      })
    default:
      return undefined
  }
}

const DURABLE_CODEX_ITEM_FIELDS = [
  'id', 'type', 'title', 'status', 'command', 'query', 'input',
  'aggregatedOutput', 'output', 'result', 'changes', 'content',
] as const

/**
 * Project the official Codex app-server notification stream into the minimum
 * durable facts used by OpenFish. Unknown notifications and model text deltas
 * remain live-only. Authentication/account payloads are never copied.
 * @param method - Official app-server notification method.
 * @param params - Untrusted notification parameters.
 * @returns The bounded durable projection, or `undefined` for live-only data.
 */
export function durableCodexNotification(method: string, params: Readonly<JsonRecord>): unknown | undefined {
  if (method === 'turn/completed') {
    const turn = record(params.turn)
    const threadId = shortString(params.threadId, 512)
    const id = shortString(turn?.id, 512)
    const status = shortString(turn?.status, 128)
    if (threadId === undefined || id === undefined || status === undefined) return undefined
    return safeHarnessEventValue({ method, params: { threadId, turn: { id, status } } })
  }
  if (method !== 'item/started' && method !== 'item/completed') return undefined
  const source = record(params.item)
  const id = shortString(source?.id, 512)
  const type = shortString(source?.type, 128)
  if (source === undefined || id === undefined || type === undefined
    || type === 'agentMessage' || type === 'reasoning') return undefined
  const item: JsonRecord = { id, type }
  for (const field of DURABLE_CODEX_ITEM_FIELDS) {
    if (field === 'id' || field === 'type') continue
    if (Object.hasOwn(source, field)) item[field] = source[field]
  }
  return safeHarnessEventValue({
    method,
    params: {
      threadId: shortString(params.threadId, 512),
      turnId: shortString(params.turnId, 512),
      itemId: shortString(params.itemId, 512),
      item,
    },
  })
}

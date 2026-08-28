/** Content-safe diagnostics shared by the Harness Host boundary. @module */

import { homedir } from 'node:os'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'

const MAX_INPUT_CODE_POINTS = 16_384
const MAX_OUTPUT_CODE_POINTS = 800
const MAX_EVENT_STRING_CODE_POINTS = 65_536
const MAX_EVENT_TOTAL_CODE_POINTS = 262_144
const MAX_EVENT_COLLECTION_ITEMS = 128
const MAX_EVENT_DEPTH = 8
const MAX_EVENT_NODES = 4_096

const SECRET_FIELD = new RegExp(
  String.raw`(?:api.?key|access.?token|refresh.?token|session.?token|secret|password`
    + String.raw`|passwd|authorization|cookie|credential|private.?key)`,
  'iu',
)

function replaceLiteral(message: string, literal: string, replacement: string): string {
  return literal.length === 0 || literal === '/' ? message : message.split(literal).join(replacement)
}

function boundedCodePoints(value: string, maximum: number): string {
  if (value.length <= maximum) return value
  let result = ''
  let count = 0
  for (const point of value) {
    if (count++ >= maximum) break
    result += point
  }
  return result
}

function redactHarnessText(value: string): string {
  let message = value
  for (const [name, secret] of Object.entries(process.env)) {
    if (!SECRET_FIELD.test(name)) continue
    if (secret === undefined || secret.length < 6) continue
    message = replaceLiteral(message, secret, '[redacted]')
  }
  message = message
    .replace(/((?:api[-_ ]?key|access[-_ ]?token|refresh[-_ ]?token|session[-_ ]?token|secret|password|authorization|cookie|credential)\s*(?:[:=]\s*|["']\s+))(?:Bearer\s+)?[^\s,;)}\]]+/giu, '$1[redacted]')
    .replace(/\bBearer\s+[a-z0-9._~+/=-]{6,}\b/giu, 'Bearer [redacted]')
    .replace(/\b(?:sk|gh[opushr]|github_pat|xox[aboprs])[-_][a-z0-9_-]{8,}\b/giu, '[redacted]')
    .replace(/\bAIza[A-Za-z0-9_-]{20,}\b/gu, '[redacted]')
    .replace(/\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/gu, '[redacted]')
    .replace(/(https?:\/\/)[^\s/@:]+:[^\s/@]+@/giu, '$1[redacted]@')
  message = replaceLiteral(message, dshHomePath(), '$DSH_HOME')
  return replaceLiteral(message, homedir(), '~')
}

function diagnosticText(error: unknown, fallback: string): string {
  try {
    const value = error instanceof Error
      ? error.message
      : typeof error === 'string' ? error : String(error)
    if (typeof value === 'string' && value.trim().length > 0) {
      // ACP deliberately serializes ordinary handler exceptions as the
      // generic JSON-RPC message "Internal error" while retaining the
      // provider-authored diagnostic in `error.data.details`. Preserve that
      // useful detail through the same bounding/redaction boundary instead of
      // forcing every Harness adapter to understand one SDK error class.
      const record = typeof error === 'object' && error !== null
        ? error as { data?: unknown }
        : undefined
      const data = record?.data
      const details = typeof data === 'object' && data !== null
        && 'details' in data && typeof (data as { details?: unknown }).details === 'string'
        ? (data as { details: string }).details
        : undefined
      if (details !== undefined && details.trim().length > 0 && !value.includes(details)) {
        return `${value}: ${details}`
      }
      return value
    }
  } catch {
    // A third-party Driver may throw a Proxy or object with a hostile toString.
  }
  return fallback
}

/**
 * Bound and redact process/Driver-owned text before it reaches logs, durable
 * session events, Remote failures, or client UI.
 * @param error - Untrusted thrown value or process diagnostic.
 * @param fallback - Safe replacement when no useful message survives.
 * @returns A bounded, single-line, secret-redacted diagnostic.
 */
export function safeHarnessDiagnostic(error: unknown, fallback = 'Harness operation failed'): string {
  const bounded = boundedCodePoints(diagnosticText(error, fallback), MAX_INPUT_CODE_POINTS)
  let message = redactHarnessText(bounded.trim().length > 0 ? bounded : fallback)
  message = message.replace(/[\r\n\t]+/gu, ' ').replace(/\s{2,}/gu, ' ').trim()
  if (message.length === 0) message = fallback
  return boundedCodePoints(message, MAX_OUTPUT_CODE_POINTS)
}

interface EventSanitizerState {
  readonly seen: WeakSet<object>
  nodes: number
  remainingCodePoints: number
}

function safeEventValue(value: unknown, state: EventSanitizerState, depth: number): unknown {
  if (state.nodes++ >= MAX_EVENT_NODES || depth > MAX_EVENT_DEPTH) return '[truncated]'
  if (value === null || typeof value === 'boolean') return value
  if (typeof value === 'number') return Number.isFinite(value) ? value : null
  if (typeof value === 'string') {
    if (state.remainingCodePoints <= 0) return '[truncated]'
    const maximum = Math.min(MAX_EVENT_STRING_CODE_POINTS, state.remainingCodePoints)
    const redacted = boundedCodePoints(redactHarnessText(value), maximum)
    state.remainingCodePoints -= Array.from(redacted).length
    return redacted
  }
  if (typeof value !== 'object') return undefined
  if (state.seen.has(value)) return '[circular]'
  state.seen.add(value)
  try {
    if (Array.isArray(value)) {
      return value.slice(0, MAX_EVENT_COLLECTION_ITEMS)
        .map(item => safeEventValue(item, state, depth + 1))
        .filter(item => item !== undefined)
    }
    const output: Record<string, unknown> = {}
    let count = 0
    for (const key of Object.keys(value)) {
      if (count++ >= MAX_EVENT_COLLECTION_ITEMS) break
      if (key === '__proto__' || key === 'prototype' || key === 'constructor') continue
      const safeKey = boundedCodePoints(key.replace(/[\u0000-\u001f\u007f]/gu, ''), 256)
      if (safeKey.length === 0) continue
      if (SECRET_FIELD.test(safeKey)) {
        output[safeKey] = '[redacted]'
        continue
      }
      let child: unknown
      try { child = (value as Record<string, unknown>)[key] } catch { child = '[unreadable]' }
      const safeChild = safeEventValue(child, state, depth + 1)
      if (safeChild !== undefined) output[safeKey] = safeChild
    }
    return output
  } finally {
    state.seen.delete(value)
  }
}

/**
 * Convert an untrusted Harness/provider payload into bounded, JSON-compatible,
 * secret-redacted durable state. Callers must still whitelist the fields and
 * event kinds they actually need; this is the final persistence guard.
 * @param value - Untrusted Harness or provider payload.
 * @returns A bounded JSON-compatible projection.
 */
export function safeHarnessEventValue(value: unknown): unknown {
  return safeEventValue(value, {
    seen: new WeakSet(),
    nodes: 0,
    remainingCodePoints: MAX_EVENT_TOTAL_CODE_POINTS,
  }, 0)
}

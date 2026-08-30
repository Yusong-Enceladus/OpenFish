/** Canonical Typert streams merged into one reconnect generation for native clients. */

import type { Context } from '@deepseek-ai/cordis'
import type { RemoteEventDownlinkFrame } from '@deepseek-ai/dsh-api-gateway'
import type { SessionFollowFrame } from '@deepseek-ai/dsh-api-session-controller'
import { SessionId } from '@deepseek-ai/dsh-session'
import type { JsonValue } from '@deepseek-ai/dsh-session/types'
import { expandHistoryRecord } from './history.ts'
import type {
  NativeFollowFrame,
  NativeFollowRequest,
  NativeRemoteEventFrame,
  NativeSessionFollowFrame,
} from './protocol.ts'

/**
 * Maximum number of canonical frames retained for one native connection.
 * A slow or suspended device reconnects from durable snapshots/history instead
 * of allowing an unbounded in-memory backlog to grow inside the Host.
 */
export const NATIVE_FEED_QUEUE_CAPACITY = 2_048

/** Merge generic Host contracts without translating or inventing Harness semantics. */
export async function *followNativeContracts(
  ctx: Context,
  request: NativeFollowRequest,
  signal: AbortSignal,
): AsyncIterable<NativeFollowFrame> {
  signal.throwIfAborted()
  const lifetime = new AbortController()
  const combined = AbortSignal.any([signal, lifetime.signal])
  const queue = new NativeFeedQueue()
  const pumps: Promise<void>[] = [
    pump(
      'remote-events',
      ctx.typertGateway.wireStream.open('$events', { args: {} }, combined),
      value => ({ channel: 'remote-events', value: projectRemoteEventFrame(value as RemoteEventDownlinkFrame) }),
      queue,
      combined,
    ),
    pump(
      'workspace',
      Promise.resolve(ctx.workspaceController.follow(combined)),
      value => ({ channel: 'workspace', value }),
      queue,
      combined,
    ),
    pump(
      'control',
      Promise.resolve(ctx.sessionController.control(combined)),
      value => ({ channel: 'control', value }),
      queue,
      combined,
    ),
  ]
  if (request.sessionId !== undefined) {
    const sessionId = SessionId(request.sessionId)
    const address = request.parentSessionId === undefined
      ? { kind: 'session' as const, sessionId }
      : {
        kind: 'subagent' as const,
        parentSessionId: SessionId(request.parentSessionId),
        childSessionId: sessionId,
        mode: request.mode ?? 'continuable',
      }
    pumps.push(pump(
      'session',
      Promise.resolve(ctx.sessionController.follow({
        address,
        ...(request.maxMessages === undefined ? {} : { maxMessages: request.maxMessages }),
      }, combined)),
      value => ({ channel: 'session', sessionId, value: projectSessionFrame(value) }),
      queue,
      combined,
    ))
  }
  try {
    yield* queue.read(combined)
  } finally {
    lifetime.abort(new Error('x-native: native feed generation closed'))
    await Promise.allSettled(pumps)
  }
}

function projectRemoteEventFrame(value: RemoteEventDownlinkFrame): NativeRemoteEventFrame {
  if (value.type === 'emit') {
    assertJsonValue(value.args)
    return { ...value, args: value.args }
  }
  if (value.type === 'waterfall') {
    assertJsonValue(value.request)
    return { ...value, request: value.request }
  }
  return value
}

function assertJsonValue(value: unknown, ancestors = new Set<object>()): asserts value is JsonValue {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number' && Number.isFinite(value)) return
  if (typeof value !== 'object' || ancestors.has(value)) {
    throw new Error('x-native: forwarded Host event contains non-JSON data')
  }
  const prototype: unknown = Object.getPrototypeOf(value)
  if (!Array.isArray(value) && prototype !== Object.prototype && prototype !== null) {
    throw new Error('x-native: forwarded Host event contains non-JSON data')
  }
  ancestors.add(value)
  try {
    if (Array.isArray(value)) {
      for (const item of value) assertJsonValue(item, ancestors)
    } else {
      for (const item of Object.values(value)) assertJsonValue(item, ancestors)
    }
  } finally {
    ancestors.delete(value)
  }
}

function projectSessionFrame(value: SessionFollowFrame): NativeSessionFollowFrame {
  if (value.type === 'event') return value
  return {
    type: 'snapshot',
    header: value.header,
    cursor: value.cursor,
    events: value.records.flatMap(record => expandHistoryRecord(record).map(event => ({
      type: 'event' as const,
      event,
    }))),
    hasMore: value.hasMore,
    projections: value.projections,
  }
}

async function pump<T>(
  label: string,
  sourcePromise: Promise<AsyncIterable<T>>,
  project: (value: T) => NativeFollowFrame,
  queue: NativeFeedQueue,
  signal: AbortSignal,
): Promise<void> {
  try {
    const source = await sourcePromise
    for await (const value of source) {
      if (signal.aborted) return
      queue.push(project(value))
    }
    if (!signal.aborted) queue.fail(new Error(`x-native: ${label} stream ended unexpectedly`))
  } catch (error) {
    if (!signal.aborted) queue.fail(error)
  }
}

/** Bounded single-consumer queue used by one native reconnect generation. */
export class NativeFeedQueue {
  private readonly frames: NativeFollowFrame[] = []
  private waiter: (() => void) | undefined
  private failure: Error | undefined

  push(frame: NativeFollowFrame): void {
    if (this.failure !== undefined) return
    if (this.frames.length >= NATIVE_FEED_QUEUE_CAPACITY) {
      // Do not deliver a partial stale tail after overflow. Closing the
      // generation makes both native clients rejoin the canonical snapshot and
      // durable history contracts, which is the only lossless recovery path.
      this.frames.length = 0
      this.fail(new Error(
        `x-native: native client fell behind by more than ${NATIVE_FEED_QUEUE_CAPACITY} frames; reconnect to resynchronize`,
      ))
      return
    }
    this.frames.push(frame)
    this.wake()
  }

  fail(error: unknown): void {
    if (this.failure !== undefined) return
    this.failure = error instanceof Error ? error : new Error(String(error))
    this.wake()
  }

  async *read(signal: AbortSignal): AsyncIterable<NativeFollowFrame> {
    const aborted = (): void => { this.wake() }
    signal.addEventListener('abort', aborted, { once: true })
    try {
      while (!signal.aborted) {
        const frame = this.frames.shift()
        if (frame !== undefined) {
          yield frame
          continue
        }
        if (this.failure !== undefined) throw this.failure
        await new Promise<void>((resolve) => { this.waiter = resolve })
        this.waiter = undefined
      }
    } finally {
      signal.removeEventListener('abort', aborted)
    }
  }

  private wake(): void {
    const waiter = this.waiter
    this.waiter = undefined
    waiter?.()
  }
}

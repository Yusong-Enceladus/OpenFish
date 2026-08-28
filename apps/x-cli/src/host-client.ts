/**
 * Small Node client for the DSH Host carrier. OpenCodex CLI deliberately owns
 * no session or model state: every business operation crosses the same `/api`
 * boundary used by Web, macOS, and iPhone.
 */

import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { extname } from 'node:path'
import { loadConnection } from './xstore.ts'

export interface HostRpcErrorBody {
  code: string
  message: string
  details?: unknown
}

export class HostRpcError extends Error {
  constructor(readonly method: string, readonly body: HostRpcErrorBody) {
    super(`${method}: ${body.code}: ${body.message}`)
    this.name = 'HostRpcError'
  }
}

export interface SessionSummaryView {
  sessionId: string
  updatedAt: number
  running: boolean
  blank: boolean
  cwd?: string
  parentSessionId?: string
  origin?: 'subagent'
  projections?: { asOfSeq: number; values: Record<string, unknown> }
}

export interface WorkspaceView {
  workspaceId: string
  path: string
  title: string
  sessionIds: string[]
}

export interface HistoryEntryView {
  event: {
    type: string
    seq: number
    time: number
    data: Record<string, unknown>
  }
  view?: unknown
}

export interface HistoryView {
  events: HistoryEntryView[]
  hasMore: boolean
  projections?: { asOfSeq: number; values: Record<string, unknown> }
}

function configuredToken(): string | undefined {
  const envName = process.env.OPENCODEX_REMOTE_AUTH_TOKEN_ENV
    ?? process.env.X_REMOTE_AUTH_TOKEN_ENV
  if (envName !== undefined && envName !== '') {
    const token = process.env[envName]
    if (token !== undefined && token !== '') return token
  }
  const connection = loadConnection()
  return connection !== undefined && connection.expiresAt > Date.now() ? connection.token : undefined
}

/** Convert the CLI's ws/http address vocabulary into an HTTP API origin. */
export function normalizeApiBase(value?: string): string {
  const input = value ?? process.env.OPENCODEX_API ?? process.env.X_API ?? loadConnection()?.api
    ?? 'http://127.0.0.1:3080'
  if (input.startsWith('unix://')) {
    throw new Error('unix app-server transport is not mounted by this OpenCodex DSH composition')
  }
  const normalized = input.startsWith('ws://')
    ? `http://${input.slice(5)}`
    : input.startsWith('wss://')
      ? `https://${input.slice(6)}`
      : input
  return normalized.replace(/\/+$/, '').replace(/\/api$/, '')
}

/** Raw authenticated bootstrap request (outside the RPC envelope). */
export async function hostRequest(
  path: string,
  init: RequestInit = {},
  base = normalizeApiBase(),
): Promise<Response> {
  const headers = new Headers(init.headers)
  const token = configuredToken()
  if (token !== undefined) headers.set('authorization', `Bearer ${token}`)
  return fetch(`${base}${path.startsWith('/') ? path : `/${path}`}`, { ...init, headers })
}

async function invoke<T>(method: string, args: unknown, base = normalizeApiBase()): Promise<T> {
  const rpcId = randomUUID()
  const response = await hostRequest(`/api/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } }),
  }, base)
  const text = await response.text()
  if (!response.ok) throw new Error(`${method}: HTTP ${response.status}: ${text.slice(0, 240)}`)
  let envelope: unknown
  try {
    envelope = JSON.parse(text)
  } catch {
    throw new Error(`${method}: Host returned non-JSON data`)
  }
  if (typeof envelope !== 'object' || envelope === null) throw new Error(`${method}: invalid Host response`)
  const record = envelope as Record<string, unknown>
  if (record.type !== 'server-response' || record.rpcId !== rpcId) {
    throw new Error(`${method}: response correlation failed`)
  }
  const result = record.result
  if (typeof result !== 'object' || result === null) throw new Error(`${method}: missing result`)
  const outcome = result as Record<string, unknown>
  if (outcome.ok === true) return outcome.value as T
  const error = typeof outcome.error === 'object' && outcome.error !== null
    ? outcome.error as Record<string, unknown>
    : {}
  throw new HostRpcError(method, {
    code: typeof error.code === 'string' ? error.code : 'unknown',
    message: typeof error.message === 'string' ? error.message : 'Host rejected the request',
    details: error.details,
  })
}

/** Invoke a request-object Typert method. */
export function rpc<T>(method: string, request: unknown, base = normalizeApiBase()): Promise<T> {
  return invoke(method, { request }, base)
}

/** Invoke a Typert method whose public parameters are direct wire fields. */
export function rpcDirect<T>(method: string, args: unknown, base = normalizeApiBase()): Promise<T> {
  return invoke(method, args, base)
}

/** Invoke a parameterless Typert method. */
export function rpcEmpty<T>(method: string, base = normalizeApiBase()): Promise<T> {
  return invoke(method, {}, base)
}

export async function listSessions(): Promise<SessionSummaryView[]> {
  return (await rpcEmpty<{ items: SessionSummaryView[] }>('session/list')).items
}

export async function listWorkspaces(): Promise<{ items: WorkspaceView[]; archivedSessionIds: string[] }> {
  return rpcEmpty('workspace/list')
}

export function projectedTitle(session: SessionSummaryView): string | undefined {
  const value = session.projections?.values.title
  return typeof value === 'string' && value.trim() !== '' ? value : undefined
}

/** Resolve an exact id first, then an unambiguous projected title. */
export async function resolveSession(reference: string | undefined, last = false): Promise<SessionSummaryView> {
  const sessions = (await listSessions()).filter(item => item.origin !== 'subagent' && !item.blank)
    .sort((left, right) => right.updatedAt - left.updatedAt)
  if (last || reference === undefined || reference === '') {
    const newest = sessions[0]
    if (newest === undefined) throw new Error('no saved OpenCodex task exists')
    return newest
  }
  const exact = sessions.find(item => item.sessionId === reference)
  if (exact !== undefined) return exact
  const titled = sessions.filter(item => projectedTitle(item) === reference)
  const [titleMatch] = titled
  if (titled.length === 1 && titleMatch !== undefined) return titleMatch
  if (titled.length > 1) throw new Error(`session name ${JSON.stringify(reference)} is ambiguous; use its id`)
  throw new Error(`session ${JSON.stringify(reference)} was not found`)
}

/** Read all history pages in ascending seq order. */
export async function fullHistory(sessionId: string): Promise<HistoryEntryView[]> {
  const pages: HistoryEntryView[][] = []
  let beforeSeq: number | undefined
  do {
    const page = await rpc<HistoryView>('xNative/history', {
      sessionId,
      ...(beforeSeq === undefined ? {} : { beforeSeq }),
      maxMessages: 200,
    })
    pages.unshift(page.events)
    const first = page.events[0]?.event.seq
    if (!page.hasMore || first === undefined || first <= 0) break
    beforeSeq = first
  } while (true)
  return pages.flat()
}

function textBlocks(value: unknown): string {
  if (!Array.isArray(value)) return ''
  return value.map((block) => {
    if (typeof block !== 'object' || block === null) return ''
    const record = block as Record<string, unknown>
    return record.type === 'text' && typeof record.text === 'string' ? record.text : ''
  }).filter(Boolean).join('\n')
}

export function latestAssistantText(events: readonly HistoryEntryView[]): string {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const entry = events[index]
    if (entry === undefined) continue
    const event = entry.event
    if (event.type !== 'assistant/message') continue
    const message = event.data.message
    if (typeof message !== 'object' || message === null) continue
    const text = textBlocks((message as Record<string, unknown>).content)
    if (text !== '') return text
  }
  return ''
}

export function imagePart(path: string): { type: 'image'; mediaType: string; data: string; name: string } {
  const extension = extname(path).toLowerCase()
  const mediaType = extension === '.png' ? 'image/png'
    : extension === '.jpg' || extension === '.jpeg' ? 'image/jpeg'
      : extension === '.webp' ? 'image/webp'
        : extension === '.gif' ? 'image/gif'
          : undefined
  if (mediaType === undefined) throw new Error(`unsupported image type for ${JSON.stringify(path)}`)
  return { type: 'image', mediaType, data: readFileSync(path).toString('base64'), name: path.split(/[\\/]/).pop() ?? path }
}

function websocketURL(path: string): string {
  const url = new URL(normalizeApiBase())
  url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:'
  url.pathname = path
  url.search = ''
  url.hash = ''
  return url.href
}

function retryableCarrierFailure(error: unknown): boolean {
  if (!(error instanceof Error)) return false
  return error instanceof TypeError
    || /could not open DSH|event stream failed|fetch failed|ECONN|ENOTFOUND|network|socket|closed/i.test(error.message)
}

type NativeFeedItem =
  | { kind: 'frame'; frame: Record<string, unknown> }
  | { kind: 'ended'; error?: Error }

class NativeFeedQueue {
  private readonly buffered: NativeFeedItem[] = []
  private readonly waiting: Array<(item: NativeFeedItem) => void> = []

  push(item: NativeFeedItem): void {
    const waiter = this.waiting.shift()
    if (waiter !== undefined) {
      waiter(item)
      return
    }
    if (this.buffered.length >= 4_096) {
      this.buffered.length = 0
      this.buffered.push({ kind: 'ended', error: new Error('OpenFish native feed buffer overflow') })
      return
    }
    this.buffered.push(item)
  }

  async next(remainingMs: number): Promise<NativeFeedItem> {
    const ready = this.buffered.shift()
    if (ready !== undefined) return ready
    return new Promise<NativeFeedItem>((resolve, reject) => {
      const deliver = (item: NativeFeedItem): void => {
        clearTimeout(timer)
        resolve(item)
      }
      const timer = setTimeout(() => {
        const index = this.waiting.indexOf(deliver)
        if (index >= 0) this.waiting.splice(index, 1)
        reject(new Error('task exceeded the 24 hour CLI wait limit'))
      }, remainingMs)
      this.waiting.push(deliver)
    })
  }
}

interface NativeFeedSocket {
  socket: WebSocket
  streamId: string
}

function openNativeFeed(sessionId: string, queue: NativeFeedQueue): Promise<NativeFeedSocket> {
  const token = configuredToken()
  const protocols = token === undefined ? [] : [`opencodex.bearer.${token}`]
  const socket = new WebSocket(websocketURL('/api/remote.mux'), protocols)
  const streamId = randomUUID()
  socket.addEventListener('message', (event) => {
    try {
      if (typeof event.data !== 'string') throw new Error('Gateway returned a non-text stream frame')
      const decoded: unknown = JSON.parse(event.data)
      if (typeof decoded !== 'object' || decoded === null) throw new Error('Gateway returned an invalid stream frame')
      const envelope = decoded as Record<string, unknown>
      if (envelope.streamId !== streamId) return
      if (envelope.type === 'item') {
        if (typeof envelope.value !== 'object' || envelope.value === null) {
          throw new Error('Gateway native feed item is not an object')
        }
        queue.push({ kind: 'frame', frame: envelope.value as Record<string, unknown> })
        return
      }
      if (envelope.type === 'error') {
        const failure = typeof envelope.error === 'object' && envelope.error !== null
          ? envelope.error as Record<string, unknown>
          : {}
        queue.push({
          kind: 'ended',
          error: new Error(typeof failure.message === 'string' ? failure.message : 'Gateway native feed failed'),
        })
        return
      }
      if (envelope.type === 'end') queue.push({ kind: 'ended' })
    } catch (error) {
      queue.push({ kind: 'ended', error: error instanceof Error ? error : new Error(String(error)) })
      socket.close(1002, 'invalid Gateway frame')
    }
  })
  socket.addEventListener('close', () => { queue.push({ kind: 'ended' }) }, { once: true })
  return new Promise((resolve, reject) => {
    socket.addEventListener('open', () => {
      socket.send(JSON.stringify({
        type: 'open',
        streamId,
        endpoint: 'xNative/follow',
        payload: { args: { request: { sessionId, maxMessages: 200 } } },
      }))
      resolve({ socket, streamId })
    }, { once: true })
    socket.addEventListener('error', () => {
      if (socket.readyState !== WebSocket.OPEN) reject(new Error('could not open OpenFish Gateway event stream'))
      else queue.push({ kind: 'ended', error: new Error('OpenFish Gateway event stream failed') })
    }, { once: true })
  })
}

function closeNativeFeed(active: NativeFeedSocket | undefined): void {
  if (active === undefined) return
  if (active.socket.readyState === WebSocket.OPEN) {
    active.socket.send(JSON.stringify({ type: 'cancel', streamId: active.streamId }))
    active.socket.close(1000, 'CLI turn complete')
  } else if (active.socket.readyState === WebSocket.CONNECTING) {
    active.socket.close(1000, 'CLI turn complete')
  }
}

function nativeSessionEntries(frame: Record<string, unknown>, sessionId: string): HistoryEntryView[] {
  if (frame.channel !== 'session' || frame.sessionId !== sessionId
    || typeof frame.value !== 'object' || frame.value === null) return []
  const value = frame.value as Record<string, unknown>
  const entries = value.type === 'snapshot' && Array.isArray(value.events)
    ? value.events
    : value.type === 'event' ? [value] : []
  return entries.flatMap((entry): HistoryEntryView[] => {
    if (typeof entry !== 'object' || entry === null) return []
    const event = (entry as Record<string, unknown>).event
    if (typeof event !== 'object' || event === null) return []
    const record = event as Record<string, unknown>
    if (typeof record.type !== 'string' || typeof record.seq !== 'number'
      || typeof record.time !== 'number' || typeof record.data !== 'object' || record.data === null) return []
    return [{ event: {
      type: record.type,
      seq: record.seq,
      time: record.time,
      data: record.data as Record<string, unknown>,
    } }]
  })
}

function nativeStatus(frame: Record<string, unknown>, sessionId: string): boolean | undefined {
  if (frame.channel !== 'remote-events' || typeof frame.value !== 'object' || frame.value === null) return undefined
  const value = frame.value as Record<string, unknown>
  if (value.type !== 'emit' || value.event !== 'api-session/status' || !Array.isArray(value.args)) return undefined
  return value.args[0] === sessionId && typeof value.args[1] === 'boolean' ? value.args[1] : undefined
}

/** Wait for a turn through the same reconnect-safe native Gateway feed as Mac and iPhone. */
export async function waitForTurn(
  sessionId: string,
  afterSeq: number,
  onEvents?: (events: HistoryEntryView[]) => void,
): Promise<HistoryEntryView[]> {
  let seenRunning = false
  let deliveredSeq = afterSeq
  const deadline = Date.now() + 24 * 60 * 60 * 1_000
  let reconnectAttempt = 0

  const synchronize = async (): Promise<{ history: HistoryEntryView[]; complete: boolean }> => {
    const [summary, history] = await Promise.all([
      listSessions().then(items => items.find(item => item.sessionId === sessionId)),
      fullHistory(sessionId),
    ])
    const next = history.filter(entry => entry.event.seq > deliveredSeq)
    const newest = next.at(-1)
    if (newest !== undefined) {
      deliveredSeq = newest.event.seq
      onEvents?.(next)
    }
    seenRunning ||= summary?.running === true
    const ended = history.some(entry => entry.event.seq > afterSeq && entry.event.type === 'turn/end')
    return { history, complete: summary !== undefined && !summary.running && (seenRunning || ended) }
  }

  while (Date.now() < deadline) {
    const queue = new NativeFeedQueue()
    let active: NativeFeedSocket | undefined
    try {
      active = await openNativeFeed(sessionId, queue)
      reconnectAttempt = 0
      const baseline = await synchronize()
      if (baseline.complete) return baseline.history

      while (true) {
        const item = await queue.next(Math.max(1, deadline - Date.now()))
        if (item.kind === 'ended') {
          if (item.error !== undefined) throw item.error
          break
        }
        const status = nativeStatus(item.frame, sessionId)
        if (status === true) seenRunning = true
        if (status === false && seenRunning) {
          const final = await synchronize()
          if (final.complete) return final.history
        }
        const entries = nativeSessionEntries(item.frame, sessionId)
          .filter(entry => entry.event.seq > deliveredSeq)
        if (entries.length === 0) continue
        deliveredSeq = entries.at(-1)?.event.seq ?? deliveredSeq
        onEvents?.(entries)
        if (entries.some(entry => entry.event.type === 'turn/end' && entry.event.seq > afterSeq)) {
          return (await synchronize()).history
        }
      }
    } catch (error) {
      const remaining = deadline - Date.now()
      if (remaining <= 0) break
      if (!retryableCarrierFailure(error)) throw error
      reconnectAttempt += 1
      if (reconnectAttempt >= 3) {
        try {
          await rpcEmpty('xNative/describe')
          throw new Error(`DSH Host is reachable but its Gateway event stream cannot be opened: ${String(error)}`)
        } catch (probeError) {
          if (!retryableCarrierFailure(probeError)) throw probeError
        }
      }
      const cap = Math.min(10_000, 250 * (2 ** Math.min(reconnectAttempt, 5)))
      const delay = Math.min(remaining, Math.max(100, Math.floor(cap / 2 + Math.random() * cap / 2)))
      await new Promise(resolve => setTimeout(resolve, delay))
    } finally {
      closeNativeFeed(active)
    }
  }
  throw new Error('task exceeded the 24 hour CLI wait limit')
}

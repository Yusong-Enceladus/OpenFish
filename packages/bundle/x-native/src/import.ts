/** Bounded Codex/DSH transcript migration into ordinary replayable DSH tasks. */

import { Buffer } from 'node:buffer'
import type { Context } from '@deepseek-ai/cordis'
import { createAssistantMessage, createUserMessage } from '@deepseek-ai/dsh-llm'
import { Session } from '@deepseek-ai/dsh-session'
import { scanLog } from '@deepseek-ai/dsh-session-persistence-jsonl'
import { unzipSync } from 'fflate'
import type {
  NativeImportFile,
  NativeImportFormat,
  NativeImportItem,
  NativeImportRequest,
  NativeImportValue,
} from './protocol.ts'

const MAX_FILES = 64
const MAX_ARCHIVE_ENTRIES = 256
const MAX_WIRE_CHARS = 96 * 1024 * 1024
const MAX_INPUT_BYTES = 64 * 1024 * 1024
const MAX_UNCOMPRESSED_BYTES = 192 * 1024 * 1024
const MAX_JSONL_LINES = 250_000
const MAX_TRANSCRIPT_CHARS = 24 * 1024 * 1024
const MAX_MESSAGE_CHARS = 2 * 1024 * 1024

interface TranscriptMessage {
  readonly role: 'user' | 'assistant'
  readonly text: string
  readonly provider?: string
  readonly model?: string
}

interface ParsedTranscript {
  readonly source: 'codex' | 'dsh'
  readonly sourceSessionId?: string
  readonly root: boolean
  readonly title?: string
  readonly messages: readonly TranscriptMessage[]
}

interface ExpandedInput {
  readonly name: string
  readonly bytes: Buffer
  readonly sourceHint?: 'codex' | 'dsh'
  readonly root: boolean
}

/** Parse every source before creating the first task, then materialize each transcript serially. */
export async function importNativeSessions(
  ctx: Context,
  request: NativeImportRequest,
  signal: AbortSignal,
): Promise<NativeImportValue> {
  validateRequest(request)
  const decoded = request.files.map(decodeFile)
  const inputBytes = decoded.reduce((total, file) => total + file.bytes.length, 0)
  if (inputBytes > MAX_INPUT_BYTES) throw new Error('x-native import exceeds the 64 MiB decoded input limit')
  signal.throwIfAborted()

  const expanded = decoded.flatMap(file => expandInput(file, request.format))
  if (expanded.length === 0) throw new Error('x-native import contains no supported JSONL transcript')
  if (expanded.length > MAX_ARCHIVE_ENTRIES) throw new Error('x-native import contains too many transcripts')
  const transcripts = expanded.map(parseTranscript)
  signal.throwIfAborted()

  const items: NativeImportItem[] = []
  for (const transcript of transcripts) {
    signal.throwIfAborted()
    const created = await ctx.sessionController.create({
      ...(request.workspaceId === undefined
        ? { noProject: true as const }
        : { workspaceId: request.workspaceId as never }),
      // Imported history is replayed by DSH. External Harness remote-thread
      // identities cannot truthfully claim ownership of synthetic local history.
      harnessId: 'dsh',
    }, signal)
    const session = ctx.sessions.get(created.sessionId)
    if (session === undefined) throw new Error(`imported task "${created.sessionId}" was not attached`)
    appendTranscript(session, transcript.messages)
    const title = importTitle(transcript)
    if (title !== undefined) await ctx.sessionController.rename({ sessionId: created.sessionId, title })
    await ctx.sessions.flush(session)
    items.push({
      sessionId: created.sessionId,
      ...(transcript.sourceSessionId === undefined ? {} : { sourceSessionId: transcript.sourceSessionId }),
      source: transcript.source,
      root: transcript.root,
    })
  }
  return { items }
}

function validateRequest(request: NativeImportRequest): void {
  const formats: readonly NativeImportFormat[] = ['auto', 'dsh-jsonl', 'dsh-zip', 'codex-jsonl', 'codex-zip']
  if (!formats.includes(request.format)) throw new Error(`unsupported x-native import format "${String(request.format)}"`)
  if (!Array.isArray(request.files) || request.files.length === 0 || request.files.length > MAX_FILES) {
    throw new Error(`x-native import accepts 1 to ${MAX_FILES} files`)
  }
  const wireChars = request.files.reduce((total, file) => total + file.data.length, 0)
  if (wireChars > MAX_WIRE_CHARS) throw new Error('x-native import exceeds the bounded wire payload')
}

function decodeFile(file: NativeImportFile): ExpandedInput {
  if (typeof file.name !== 'string' || file.name.trim() === '' || file.name.length > 512) {
    throw new Error('x-native import file name must contain 1 to 512 characters')
  }
  if (typeof file.data !== 'string' || file.data.length === 0 || file.data.length % 4 !== 0
    || !/^[A-Za-z0-9+/]*={0,2}$/u.test(file.data)) {
    throw new Error(`x-native import file "${file.name}" is not canonical base64`)
  }
  const bytes = Buffer.from(file.data, 'base64')
  if (bytes.length === 0 || bytes.toString('base64') !== file.data) {
    throw new Error(`x-native import file "${file.name}" is not canonical base64`)
  }
  return { name: file.name, bytes, root: true }
}

function expandInput(file: ExpandedInput, format: NativeImportFormat): ExpandedInput[] {
  const explicitZip = format === 'dsh-zip' || format === 'codex-zip'
  const zip = explicitZip || (format === 'auto' && isZip(file.bytes))
  if (!zip) {
    const sourceHint = format === 'dsh-jsonl' ? 'dsh' : format === 'codex-jsonl' ? 'codex' : undefined
    return [{
      ...file,
      ...(sourceHint === undefined ? {} : { sourceHint }),
    }]
  }
  inspectZip(file.bytes)
  const entries = unzipSync(new Uint8Array(file.bytes))
  const sourceHint = format === 'dsh-zip' ? 'dsh' : format === 'codex-zip' ? 'codex' : undefined
  return Object.entries(entries).flatMap(([name, bytes]): ExpandedInput[] => {
    if (!safeArchivePath(name) || name.endsWith('/') || !name.toLowerCase().endsWith('.jsonl')) return []
    return [{
      name: `${file.name}:${name}`,
      bytes: Buffer.from(bytes),
      ...(sourceHint === undefined ? {} : { sourceHint }),
      root: sourceHint === 'dsh' || name === 'session.jsonl'
        ? name === 'session.jsonl' || !name.startsWith('subagents/')
        : true,
    }]
  })
}

function isZip(bytes: Buffer): boolean {
  return bytes.length >= 4 && bytes.readUInt32LE(0) === 0x04034b50
}

/** Inspect the central directory before inflation so a ZIP bomb fails before allocating its output. */
function inspectZip(bytes: Buffer): void {
  if (!isZip(bytes)) throw new Error('x-native import ZIP has no local-file header')
  const minimum = Math.max(0, bytes.length - 65_557)
  let eocd = -1
  for (let offset = bytes.length - 22; offset >= minimum; offset -= 1) {
    if (bytes.readUInt32LE(offset) === 0x06054b50) { eocd = offset; break }
  }
  if (eocd < 0) throw new Error('x-native import ZIP has no end-of-central-directory record')
  if (bytes.readUInt16LE(eocd + 4) !== 0 || bytes.readUInt16LE(eocd + 6) !== 0) {
    throw new Error('multi-disk ZIP archives are not supported')
  }
  const entries = bytes.readUInt16LE(eocd + 10)
  const directoryBytes = bytes.readUInt32LE(eocd + 12)
  const directoryOffset = bytes.readUInt32LE(eocd + 16)
  if (entries === 0xffff || directoryBytes === 0xffffffff || directoryOffset === 0xffffffff) {
    throw new Error('ZIP64 imports are not supported')
  }
  if (entries > MAX_ARCHIVE_ENTRIES || directoryOffset + directoryBytes > eocd) {
    throw new Error('x-native import ZIP central directory is invalid or too large')
  }
  let cursor = directoryOffset
  let uncompressed = 0
  for (let index = 0; index < entries; index += 1) {
    if (cursor + 46 > bytes.length || bytes.readUInt32LE(cursor) !== 0x02014b50) {
      throw new Error('x-native import ZIP central directory is corrupt')
    }
    const flags = bytes.readUInt16LE(cursor + 8)
    if ((flags & 0x1) !== 0) throw new Error('encrypted ZIP entries are not supported')
    const size = bytes.readUInt32LE(cursor + 24)
    if (size === 0xffffffff) throw new Error('ZIP64 entries are not supported')
    uncompressed += size
    if (uncompressed > MAX_UNCOMPRESSED_BYTES) {
      throw new Error('x-native import ZIP exceeds the 192 MiB uncompressed limit')
    }
    const nameLength = bytes.readUInt16LE(cursor + 28)
    const extraLength = bytes.readUInt16LE(cursor + 30)
    const commentLength = bytes.readUInt16LE(cursor + 32)
    const end = cursor + 46 + nameLength + extraLength + commentLength
    if (end > bytes.length) throw new Error('x-native import ZIP entry metadata is truncated')
    const name = bytes.subarray(cursor + 46, cursor + 46 + nameLength).toString('utf8')
    if (!safeArchivePath(name)) throw new Error(`unsafe ZIP entry path "${name}"`)
    cursor = end
  }
  if (cursor !== directoryOffset + directoryBytes) throw new Error('x-native import ZIP directory length mismatch')
}

function safeArchivePath(name: string): boolean {
  return name.length > 0 && name.length <= 1_024 && !name.includes('\0') && !name.includes('\\')
    && !name.startsWith('/') && !/^[A-Za-z]:/u.test(name)
    && name.split('/').every(segment => segment !== '..')
}

function parseTranscript(input: ExpandedInput): ParsedTranscript {
  const text = new TextDecoder('utf-8', { fatal: true }).decode(input.bytes)
  const lines = text.split(/\r?\n/u).filter(line => line.trim() !== '')
  if (lines.length === 0 || lines.length > MAX_JSONL_LINES) {
    throw new Error(`"${input.name}" has no transcript or exceeds ${MAX_JSONL_LINES} JSONL records`)
  }
  const source = input.sourceHint ?? detectSource(lines[0] as string)
  return source === 'dsh'
    ? parseDshTranscript(input.name, input.root, input.bytes)
    : parseCodexTranscript(input.name, input.root, lines)
}

function detectSource(firstLine: string): 'codex' | 'dsh' {
  let first: unknown
  try { first = JSON.parse(firstLine) } catch { throw new Error('imported JSONL begins with invalid JSON') }
  if (typeof first !== 'object' || first === null) throw new Error('imported JSONL records must be objects')
  const type = (first as { type?: unknown }).type
  if (type === 'session') return 'dsh'
  if (type === 'session_meta' || type === 'event_msg' || type === 'response_item' || type === 'turn_context') return 'codex'
  throw new Error(`could not detect JSONL transcript type from "${String(type)}"`)
}

function parseDshTranscript(name: string, root: boolean, bytes: Buffer): ParsedTranscript {
  let scanned: ReturnType<typeof scanLog>
  try { scanned = scanLog(bytes) } catch (error) {
    throw new Error(`DSH transcript "${name}" is invalid: ${error instanceof Error ? error.message : String(error)}`)
  }
  const restored = Session.fromRestore(scanned.meta.id, scanned.events, scanned.meta)
  const messages = restored.deriveMessages().flatMap((message): TranscriptMessage[] => {
    if (message.role === 'user' && message.source.kind !== 'user') return []
    if (message.role !== 'user' && message.role !== 'assistant') return []
    const text = visibleText(message.content)
    if (text === '') return []
    return [{
      role: message.role,
      text,
      ...(message.role === 'assistant' && message.source.kind === 'model'
        ? { provider: message.source.provider, model: message.source.model }
        : {}),
    }]
  })
  ensureTranscriptSize(name, messages)
  if (messages.length === 0) throw new Error(`DSH transcript "${name}" has no replayable user or assistant text`)
  const titleEvent = (scanned.events as readonly { type: string; data: unknown }[])
    .findLast(event => event.type === 'session/title')
  const titleData = asRecord(titleEvent?.data)
  const title = typeof titleData.title === 'string' ? titleData.title : undefined
  return { source: 'dsh', sourceSessionId: scanned.meta.id, root, ...(title === undefined ? {} : { title }), messages }
}

function parseCodexTranscript(name: string, root: boolean, lines: readonly string[]): ParsedTranscript {
  let sourceSessionId: string | undefined
  let provider = 'openai'
  let model = 'codex'
  const candidates: Array<TranscriptMessage & { preferred: boolean }> = []
  for (const [index, line] of lines.entries()) {
    let value: unknown
    try { value = JSON.parse(line) } catch { throw new Error(`Codex transcript "${name}" has invalid JSON at line ${index + 1}`) }
    if (typeof value !== 'object' || value === null) continue
    const record = value as Record<string, unknown>
    const payload = asRecord(record.payload)
    if (record.type === 'session_meta') {
      if (typeof payload.id === 'string') sourceSessionId = payload.id
      if (typeof payload.model_provider === 'string') provider = payload.model_provider
      continue
    }
    if (record.type === 'turn_context') {
      if (typeof payload.model === 'string') model = payload.model
      continue
    }
    if (record.type === 'event_msg' && payload.type === 'user_message') {
      const text = scalarText(payload.message)
      if (text !== '') candidates.push({ role: 'user', text, preferred: true })
      continue
    }
    if (record.type === 'event_msg' && payload.type === 'agent_message') {
      const text = scalarText(payload.message)
      if (text !== '') candidates.push({ role: 'assistant', text, provider, model, preferred: false })
      continue
    }
    if (record.type !== 'response_item' || payload.type !== 'message') continue
    const role = payload.role
    if (role !== 'user' && role !== 'assistant') continue
    const text = responseContentText(payload.content)
    if (text === '') continue
    candidates.push({
      role,
      text,
      ...(role === 'assistant' ? { provider, model } : {}),
      preferred: role === 'assistant',
    })
  }
  const preferred = new Set(candidates.filter(item => item.preferred).map(item => `${item.role}\0${item.text}`))
  const messages = candidates
    .filter(item => item.preferred || !preferred.has(`${item.role}\0${item.text}`))
    .map(({ preferred: _preferred, ...message }) => message)
    .filter((message, index, all) => index === 0
      || message.role !== all[index - 1]?.role || message.text !== all[index - 1]?.text)
  ensureTranscriptSize(name, messages)
  if (messages.length === 0) throw new Error(`Codex transcript "${name}" has no replayable user or assistant text`)
  return { source: 'codex', ...(sourceSessionId === undefined ? {} : { sourceSessionId }), root, messages }
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function scalarText(value: unknown): string {
  return typeof value === 'string' ? boundedMessage(value) : ''
}

function responseContentText(value: unknown): string {
  if (typeof value === 'string') return boundedMessage(value)
  if (!Array.isArray(value)) return ''
  return boundedMessage(value.flatMap((block): string[] => {
    const item = asRecord(block)
    const text = item.text
    return (item.type === 'input_text' || item.type === 'output_text' || item.type === 'text')
      && typeof text === 'string' ? [text] : []
  }).join('\n'))
}

function visibleText(content: readonly unknown[]): string {
  return boundedMessage(content.flatMap((block): string[] => {
    const item = asRecord(block)
    return item.type === 'text' && typeof item.text === 'string' ? [item.text] : []
  }).join('\n'))
}

function boundedMessage(value: string): string {
  const normalized = value.replaceAll('\0', '').trim()
  if (normalized.length > MAX_MESSAGE_CHARS) throw new Error('one imported transcript message exceeds 2 MiB')
  return normalized
}

function ensureTranscriptSize(name: string, messages: readonly TranscriptMessage[]): void {
  const chars = messages.reduce((total, message) => total + message.text.length, 0)
  if (chars > MAX_TRANSCRIPT_CHARS) throw new Error(`transcript "${name}" exceeds the 24 MiB text limit`)
}

function appendTranscript(session: Session, messages: readonly TranscriptMessage[]): void {
  let turn = 0
  let step = 0
  let openTurn = false
  const closeTurn = (): void => {
    if (!openTurn) return
    session.append('turn/end', { turn, reason: { kind: 'completed' } })
    openTurn = false
  }
  const openNextTurn = (): void => {
    closeTurn()
    turn += 1
    step = 0
    session.append('turn/start', { turn })
    openTurn = true
  }
  for (const message of messages) {
    if (message.role === 'user') {
      openNextTurn()
      session.append('user/message', createUserMessage({
        content: [{ type: 'text', text: message.text }],
        source: { kind: 'user' },
      }), { surfaceOp: 'append' })
      continue
    }
    if (!openTurn) openNextTurn()
    step += 1
    session.append('step/start', { turn, step })
    session.append('assistant/message', {
      turn,
      step,
      message: createAssistantMessage({
        content: [{ type: 'text', text: message.text }],
        source: { provider: message.provider ?? 'import', model: message.model ?? 'transcript' },
      }),
    }, { surfaceOp: 'append' })
    session.append('step/end', { turn, step })
  }
  closeTurn()
}

function importTitle(transcript: ParsedTranscript): string | undefined {
  const raw = transcript.title ?? transcript.messages.find(message => message.role === 'user')?.text
  if (raw === undefined) return undefined
  const line = raw.split(/\r?\n/u)[0]?.replaceAll(/\s+/gu, ' ').trim()
  if (line === undefined || line === '') return undefined
  const prefix = transcript.source === 'codex' ? 'Imported · ' : ''
  return `${prefix}${line}`.slice(0, 80)
}

import { createInterface } from 'node:readline'
import { appendFileSync, writeFileSync } from 'node:fs'

type Frame = { id?: number; method?: string; params?: Record<string, unknown> }

const THREAD_ID = 'official-codex-thread'
const FORK_ID = 'official-codex-fork'
let turn = 0

function send(frame: Record<string, unknown>): void {
  process.stdout.write(`${JSON.stringify(frame)}\n`)
}

function respond(frame: Frame, result: unknown): void {
  send({ id: frame.id, result })
}

createInterface({ input: process.stdin }).on('line', (line) => {
  if (line.trim().length === 0) return
  const frame = JSON.parse(line) as Frame
  const trace = process.env.OPENFISH_CODEX_FIXTURE_TRACE
  if (trace !== undefined && frame.method !== undefined) appendFileSync(trace, `${frame.method}\n`)
  switch (frame.method) {
    case 'initialize':
      respond(frame, { userAgent: 'synthetic-codex-app-server' })
      break
    case 'initialized':
      break
    case 'model/list':
      respond(frame, { data: [{
        id: 'gpt-test', displayName: 'GPT Test', description: 'Synthetic official model', isDefault: true,
        defaultReasoningEffort: 'medium',
        supportedReasoningEfforts: [
          { reasoningEffort: 'low', description: 'Fast' },
          { reasoningEffort: 'medium', description: 'Balanced' },
          { reasoningEffort: 'high', description: 'Deep' },
        ],
      }] })
      break
    case 'account/read':
      respond(frame, {
        account: { type: 'chatgpt', email: 'fixture@example.invalid', planType: 'pro' },
        requiresOpenaiAuth: true,
      })
      break
    case 'thread/start':
      respond(frame, { thread: { id: THREAD_ID, ephemeral: false } })
      break
    case 'thread/resume':
      respond(frame, { thread: { id: frame.params?.threadId ?? THREAD_ID, model: 'gpt-test', reasoningEffort: 'high' } })
      break
    case 'thread/fork':
      respond(frame, { thread: { id: FORK_ID, forkedFromId: frame.params?.threadId ?? THREAD_ID } })
      break
    case 'thread/delete':
      respond(frame, {})
      break
    case 'turn/start': {
      const crashOnceMarker = process.env.OPENFISH_CODEX_FIXTURE_CRASH_ONCE_MARKER
      if (crashOnceMarker !== undefined) {
        try {
          writeFileSync(crashOnceMarker, 'crashed\n', { flag: 'wx' })
          process.exit(72)
        } catch (error: unknown) {
          if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
        }
      }
      const id = `turn-${++turn}`
      const threadId = typeof frame.params?.threadId === 'string' ? frame.params.threadId : THREAD_ID
      const input = Array.isArray(frame.params?.input) ? frame.params.input : []
      const text = input
        .filter((entry): entry is { type: string; text: string } => entry !== null && typeof entry === 'object')
        .filter(entry => entry.type === 'text' && typeof entry.text === 'string')
        .map(entry => entry.text)
        .join('')
      if (text === 'auth-expired') {
        send({ id: frame.id, error: { code: -32001, message: 'authentication expired; access_token=sk-test-supersecret123456' } })
        break
      }
      if (text === 'quota-failure') {
        send({ id: frame.id, error: { code: -32002, message: 'provider quota exceeded; authorization=Bearer sk-test-supersecret123456' } })
        break
      }
      respond(frame, { turn: { id, status: 'inProgress' } })
      send({ method: 'turn/started', params: { threadId, turn: { id, status: 'inProgress' } } })
      send({
        method: 'item/completed',
        params: {
          threadId, turnId: id,
          item: { id: `message-${turn}`, type: 'agentMessage', text: `codex:${text}`, phase: 'final_answer' },
        },
      })
      send({ method: 'turn/completed', params: { threadId, turn: { id, status: 'completed' } } })
      break
    }
    case 'turn/interrupt':
      respond(frame, {})
      break
    default:
      if (frame.id !== undefined) send({ id: frame.id, error: { code: -32601, message: `Unknown method ${String(frame.method)}` } })
  }
})

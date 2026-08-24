import { createInterface } from 'node:readline'
import { appendFileSync } from 'node:fs'

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
      const id = `turn-${++turn}`
      const threadId = typeof frame.params?.threadId === 'string' ? frame.params.threadId : THREAD_ID
      const input = Array.isArray(frame.params?.input) ? frame.params.input : []
      const text = input
        .filter((entry): entry is { type: string; text: string } => entry !== null && typeof entry === 'object')
        .filter(entry => entry.type === 'text' && typeof entry.text === 'string')
        .map(entry => entry.text)
        .join('')
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

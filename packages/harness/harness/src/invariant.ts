/** Package-owned invariant companion for Harness selection records. @module */

import type { Context } from '@deepseek-ai/cordis'
import type { InvariantFailure, InvariantInstaller } from '@deepseek-ai/dsh-invariants'
import type { Session, SessionEvent } from '@deepseek-ai/dsh-session'
import type {} from './index.ts'

const PACKAGE_NAME = '@deepseek-ai/dsh-harness'
export const name = 'harness-invariant'
export const inject = ['invariants']

function validate(events: readonly SessionEvent[], fail: InvariantFailure): void {
  const selected = events.filter(event => event.type === 'harness/selected')
  if (selected.length > 1) fail('a session must select at most one Harness')
  const firstTurn = events.find(event => event.type === 'turn/start')
  if (selected[0] !== undefined && firstTurn !== undefined && selected[0].seq > firstTurn.seq) {
    fail('Harness selection must precede the first turn')
  }
  const selectedId = selected[0]?.data.harnessId
  for (const event of events) {
    if ((event.type === 'harness/native-event' || event.type === 'harness/runtime-node') && event.data.harnessId !== selectedId) {
      fail(`Harness event ${event.seq} does not match the selected Harness`)
    }
    if (event.type === 'harness/runtime-node') {
      if (event.data.nodeId.length === 0 || event.data.activity.length === 0) fail(`Harness runtime event ${event.seq} is incomplete`)
    }
  }
}

const install: InvariantInstaller = Object.assign((ctx: Context, fail: InvariantFailure) => {
  for (const session of ctx.sessions.list()) validate(session.events, fail)
  ctx.on('session/created', (session) => { validate(session.events, fail) }, { global: true })
  ctx.on('internal/dispatch', (_mode, eventName, args) => {
    if (eventName !== 'session/event') return
    const [session, event] = args as [Session, SessionEvent]
    if (event.type !== 'harness/selected' && event.type !== 'harness/native-event' && event.type !== 'harness/runtime-node') return
    validate([...session.events, event], fail)
  }, { global: true })
}, { inject: ['sessions'] })

export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))

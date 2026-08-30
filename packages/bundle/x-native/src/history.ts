/** Native raw-event history adapter over the canonical paged Session journal. */

import type { Context } from '@deepseek-ai/cordis'
import type {
  SessionHistoryRecord,
  SessionWireEvent,
} from '@deepseek-ai/dsh-api-session-controller'
import { decodeStorageRecord } from '@deepseek-ai/dsh-session/chunk-rows'
import { SessionId } from '@deepseek-ai/dsh-session'
import type { NativeHistoryRequest, NativeHistoryValue } from './protocol.ts'

/** Read a bounded page and losslessly expand transport-packed delta runs for Swift. */
export async function nativeHistory(
  ctx: Context,
  request: NativeHistoryRequest,
  signal: AbortSignal,
): Promise<NativeHistoryValue> {
  const sessionId = SessionId(request.sessionId)
  const inspected = await ctx.sessionController.inspect(sessionId, signal)
  const throughSeq = inspected.events.at(-1)?.seq ?? -1
  const address = request.parentSessionId === undefined
    ? { kind: 'session' as const, sessionId }
    : {
      kind: 'subagent' as const,
      parentSessionId: SessionId(request.parentSessionId),
      childSessionId: sessionId,
      mode: request.mode ?? 'continuable',
    }
  const page = await ctx.sessionController.page({
    address,
    throughSeq,
    ...(request.beforeSeq === undefined ? {} : { beforeSeq: request.beforeSeq }),
    ...(request.maxMessages === undefined ? {} : { maxMessages: request.maxMessages }),
  }, signal)
  const summaries = await ctx.sessionController.list({}, signal)
  const projections = summaries.items.find(item => item.sessionId === sessionId)?.projections
  return {
    events: page.records.flatMap(record => expandHistoryRecord(record).map(event => ({ event }))),
    hasMore: page.hasMore,
    ...(projections === undefined ? {} : { projections }),
  }
}

/** Expand one storage-optimized history record into canonical wire events. */
export function expandHistoryRecord(record: SessionHistoryRecord): SessionWireEvent[] {
  if (record.type === 'event') return [record.event]
  const type = record.event.type.replace(/^chunkrow\//u, '')
  return decodeStorageRecord({
    type,
    seq0: record.event.seq,
    time0: record.event.time,
    data: record.event.data,
  }).map(event => event as unknown as SessionWireEvent)
}

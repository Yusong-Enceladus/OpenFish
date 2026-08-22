import { describe, expect, it } from 'vitest'
import type { SessionEvent } from '@deepseek-ai/dsh-session'
import { harnessRuntimeProjectionDefinition as projection } from '../src/projection.ts'

describe('Harness runtime projection', () => {
  it('keeps the latest durable observation for each declared node', () => {
    let state = projection.init()
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 1, time: 10,
      data: { harnessId: 'fixture' as never, nodeId: 'tools', status: 'active', activity: 'tool_call' },
    } as SessionEvent)
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 2, time: 20,
      data: { harnessId: 'fixture' as never, nodeId: 'tools', status: 'completed', activity: 'tool completed' },
    } as SessionEvent)
    expect(projection.view(state).nodes.tools).toEqual({ status: 'completed', activity: 'tool completed', seq: 2, time: 20 })
  })
})

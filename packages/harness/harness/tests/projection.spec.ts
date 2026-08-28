import { describe, expect, it } from 'vitest'
import { harnessRuntimeProjectionDefinition as projection } from '../src/projection.ts'

describe('Harness runtime projection', () => {
  const view = (state: ReturnType<typeof projection.init>) => projection.wire.view(state)

  it('keeps the latest durable observation for each declared node', () => {
    let state = projection.init()
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 1, time: 10,
      data: { harnessId: 'fixture' as never, nodeId: 'tools', status: 'active', activity: 'tool_call' },
    })
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 2, time: 20,
      data: { harnessId: 'fixture' as never, nodeId: 'tools', status: 'completed', activity: 'tool completed' },
    })
    expect(view(state)).toMatchObject({ harnessId: 'fixture' })
    expect(view(state).nodes.tools).toEqual({ status: 'completed', activity: 'tool completed', seq: 2, time: 20 })
  })

  it('keeps the latest durable observation for each declared edge', () => {
    let state = projection.init()
    state = projection.apply(state, {
      type: 'harness/runtime-edge', seq: 3, time: 30,
      data: {
        harnessId: 'fixture' as never,
        edgeKey: 'model\u0000\u0000output\u0000',
        from: 'model', to: 'output', signal: 'output.activity',
        status: 'active', activity: 'Harness output activity observed',
      },
    })
    expect(view(state).edges['model\u0000\u0000output\u0000']).toEqual({
      from: 'model', to: 'output', signal: 'output.activity', status: 'active',
      activity: 'Harness output activity observed', seq: 3, time: 30,
    })
  })

  it('pins observations to the selected Pack identity and clears stale runtime state', () => {
    let state = projection.init()
    state = projection.apply(state, {
      type: 'harness/selected', seq: 1, time: 10,
      data: { harnessId: 'first' as never, version: '1.0.0', protocol: 'acp', workspaceMode: 'no-project' },
    })
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 2, time: 20,
      data: { harnessId: 'first' as never, nodeId: 'runtime', status: 'active', activity: 'ready' },
    })
    state = projection.apply(state, {
      type: 'harness/selected', seq: 3, time: 30,
      data: { harnessId: 'second' as never, version: '2.0.0', protocol: 'acp', workspaceMode: 'no-project' },
    })
    expect(view(state)).toEqual({
      harnessId: 'second', version: '2.0.0', workspaceMode: 'no-project', nodes: {}, edges: {},
    })
  })
})

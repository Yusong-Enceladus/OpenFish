import { describe, expect, it } from 'vitest'
import { harnessRuntimeProjectionDefinition as projection } from '../src/projection.ts'
import type { HarnessRuntimeProjection } from '../src/projection.types.ts'

describe('Harness runtime projection', () => {
  const view = (state: HarnessRuntimeProjection) => projection.wire.view(state)

  it('keeps the latest durable observation for each declared node', () => {
    let state: HarnessRuntimeProjection = projection.init()
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 1, time: 10,
      data: {
        harnessId: 'fixture' as never, nodeId: 'tools', signal: 'tool.activity',
        status: 'active', activity: '/Users/alice/private-command',
      },
    })
    state = projection.apply(state, {
      type: 'harness/runtime-node', seq: 2, time: 20,
      data: {
        harnessId: 'fixture' as never, nodeId: 'tools', signal: 'tool.activity',
        status: 'completed', activity: 'sk-must-never-cross-the-projection',
      },
    })
    expect(view(state)).toMatchObject({ harnessId: 'fixture' })
    expect(view(state).nodes.tools).toEqual({
      status: 'completed', activity: 'Tool activity observed', signal: 'tool.activity', seq: 2, time: 20,
    })
    expect(view(state).observations).toEqual([
      {
        kind: 'node', id: 'tools', status: 'active', activity: 'Tool activity observed',
        signal: 'tool.activity', seq: 1, time: 10,
      },
      {
        kind: 'node', id: 'tools', status: 'completed', activity: 'Tool activity observed',
        signal: 'tool.activity', seq: 2, time: 20,
      },
    ])
  })

  it('keeps the latest durable observation for each declared edge', () => {
    let state: HarnessRuntimeProjection = projection.init()
    state = projection.apply(state, {
      type: 'harness/runtime-edge', seq: 3, time: 30,
      data: {
        harnessId: 'fixture' as never,
        edgeKey: 'model\u0000\u0000output\u0000',
        from: 'model', to: 'output', signal: 'output.activity',
        status: 'active', activity: 'private model output',
      },
    })
    expect(view(state).edges['model\u0000\u0000output\u0000']).toEqual({
      from: 'model', to: 'output', signal: 'output.activity', status: 'active',
      activity: 'Output activity observed', seq: 3, time: 30,
    })
    expect(view(state).observations).toEqual([{
      kind: 'edge', id: 'model\u0000\u0000output\u0000', from: 'model', to: 'output',
      signal: 'output.activity', status: 'active', activity: 'Output activity observed', seq: 3, time: 30,
    }])
  })

  it('never replays caller text from legacy runtime events without a signal', () => {
    const state = projection.apply(projection.init(), {
      type: 'harness/runtime-node', seq: 1, time: 10,
      data: {
        harnessId: 'fixture' as never, nodeId: 'legacy', status: 'active',
        activity: 'private historical command --token secret',
      },
    })
    expect(view(state).nodes.legacy?.activity).toBe('Legacy runtime activity observed')
    expect(JSON.stringify(view(state))).not.toContain('private historical command')
  })

  it('pins observations to the selected Pack identity and clears stale runtime state', () => {
    let state: HarnessRuntimeProjection = projection.init()
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
      harnessId: 'second', version: '2.0.0', workspaceMode: 'no-project', nodes: {}, edges: {}, observations: [],
    })
  })

  it('keeps a bounded ordered trace so loops remain explainable without leaking event content', () => {
    let state: HarnessRuntimeProjection = projection.init()
    for (let seq = 0; seq < 140; seq++) {
      state = projection.apply(state, {
        type: 'harness/runtime-node', seq, time: seq * 10,
        data: {
          harnessId: 'fixture' as never, nodeId: seq % 2 === 0 ? 'loop' : 'tools',
          signal: seq % 2 === 0 ? 'turn.started' : 'tool.activity',
          status: 'active', activity: seq % 2 === 0 ? 'Turn started' : 'Tool activity observed',
        },
      })
    }
    const observations = view(state).observations
    expect(observations).toHaveLength(128)
    expect(observations[0]?.seq).toBe(12)
    expect(observations.at(-1)?.seq).toBe(139)
    expect(observations.every(item => !('content' in item))).toBe(true)
  })
})

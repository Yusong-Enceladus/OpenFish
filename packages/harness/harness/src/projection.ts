/** Durable read model for live Harness architecture evidence. @module */

import { z } from 'zod'
import type { ProjectionDefinition } from '@deepseek-ai/dsh-session-projection'
import type { HarnessRuntimeProjection } from './projection.types.ts'
import type {} from './index.ts'

interface HarnessRuntimeState { nodes: HarnessRuntimeProjection['nodes'] }

const schema = z.object({
  nodes: z.record(z.string(), z.object({
    status: z.enum(['active', 'waiting', 'completed', 'failed']),
    activity: z.string(),
    seq: z.number().int().nonnegative(),
    time: z.number().nonnegative(),
  }).strict()),
}).strict()

/** Whole-log latest runtime state for every Pack-declared node. */
export const harnessRuntimeProjectionDefinition: ProjectionDefinition<'harnessRuntime', HarnessRuntimeState> = {
  key: 'harnessRuntime',
  schema,
  init: () => ({ nodes: {} }),
  apply(state, event) {
    if (event.type !== 'harness/runtime-node') return state
    return {
      nodes: {
        ...state.nodes,
        [event.data.nodeId]: {
          status: event.data.status,
          activity: event.data.activity,
          seq: event.seq,
          time: event.time,
        },
      },
    }
  },
  view: state => state,
  stateVersion: 1,
}

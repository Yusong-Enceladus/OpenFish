/** Durable read model for live Harness architecture evidence. @module */

import { z } from 'zod'
import type { ProjectionDefinition } from '@deepseek-ai/dsh-session-projection'
import type { HarnessRuntimeProjection } from './projection.types.ts'
import type {} from './index.ts'

interface HarnessRuntimeState {
  harnessId?: string
  version?: string
  nodes: HarnessRuntimeProjection['nodes']
  edges: HarnessRuntimeProjection['edges']
}

const runtimeSignalSchema = z.string().min(1).regex(/^[a-z0-9][a-z0-9._-]*$/u)

const schema = z.object({
  harnessId: z.string().min(1).optional(),
  version: z.string().min(1).optional(),
  nodes: z.record(z.string(), z.object({
    status: z.enum(['active', 'waiting', 'completed', 'failed']),
    activity: z.string(),
    signal: runtimeSignalSchema.optional(),
    seq: z.number().int().nonnegative(),
    time: z.number().nonnegative(),
  }).strict()),
  edges: z.record(z.string(), z.object({
    from: z.string().min(1),
    to: z.string().min(1),
    fromPort: z.string().min(1).optional(),
    toPort: z.string().min(1).optional(),
    status: z.enum(['active', 'waiting', 'completed', 'failed']),
    activity: z.string(),
    signal: runtimeSignalSchema,
    seq: z.number().int().nonnegative(),
    time: z.number().nonnegative(),
  }).strict()),
}).strict()

/** Whole-log latest runtime state for every Pack-declared node. */
export const harnessRuntimeProjectionDefinition: ProjectionDefinition<'harnessRuntime', HarnessRuntimeState> = {
  key: 'harnessRuntime',
  // Zod's `.optional()` widens an optional output slot to `T | undefined`;
  // JSON serialization makes that indistinguishable from an absent property,
  // while the public projection deliberately keeps exact optional fields.
  schema: schema as unknown as z.ZodType<HarnessRuntimeProjection>,
  init: () => ({ nodes: {}, edges: {} }),
  apply(state, event) {
    if (event.type === 'harness/selected') {
      const sameIdentity = state.harnessId === undefined || state.harnessId === event.data.harnessId
      return {
        harnessId: event.data.harnessId,
        version: event.data.version,
        nodes: sameIdentity ? state.nodes : {},
        edges: sameIdentity ? state.edges : {},
      }
    }
    if (event.type === 'harness/runtime-edge') {
      const sameIdentity = state.harnessId === undefined || state.harnessId === event.data.harnessId
      return {
        harnessId: event.data.harnessId,
        ...(sameIdentity && state.version !== undefined ? { version: state.version } : {}),
        nodes: sameIdentity ? state.nodes : {},
        edges: {
          ...(sameIdentity ? state.edges : {}),
          [event.data.edgeKey]: {
            from: event.data.from,
            to: event.data.to,
            ...(event.data.fromPort === undefined ? {} : { fromPort: event.data.fromPort }),
            ...(event.data.toPort === undefined ? {} : { toPort: event.data.toPort }),
            status: event.data.status,
            activity: event.data.activity,
            signal: event.data.signal,
            seq: event.seq,
            time: event.time,
          },
        },
      }
    }
    if (event.type !== 'harness/runtime-node') return state
    const sameIdentity = state.harnessId === undefined || state.harnessId === event.data.harnessId
    return {
      harnessId: event.data.harnessId,
      ...(sameIdentity && state.version !== undefined ? { version: state.version } : {}),
      edges: sameIdentity ? state.edges : {},
      nodes: {
        ...(sameIdentity ? state.nodes : {}),
        [event.data.nodeId]: {
          status: event.data.status,
          activity: event.data.activity,
          ...(event.data.signal === undefined ? {} : { signal: event.data.signal }),
          seq: event.seq,
          time: event.time,
        },
      },
    }
  },
  view: state => state,
  stateVersion: 3,
}

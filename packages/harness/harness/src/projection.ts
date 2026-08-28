/** Durable read model for live Harness architecture evidence. @module */

import { z } from 'zod'
import type { ProjectionDefinition } from '@deepseek-ai/dsh-session-projection'
import type { HarnessRuntimeProjection } from './projection.types.ts'
import type {} from './index.ts'

type HarnessRuntimeState = HarnessRuntimeProjection

const runtimeSignalSchema = z.string().min(1).regex(/^[a-z0-9][a-z0-9._-]*$/u)

const schema = z.object({
  harnessId: z.string().min(1).optional(),
  version: z.string().min(1).optional(),
  authMethod: z.string().min(1).optional(),
  workspaceMode: z.enum(['project', 'no-project', 'custom-cwd']).optional(),
  capabilities: z.array(z.object({
    id: z.string().min(1),
    status: z.enum(['supported', 'runtime', 'unsupported']),
    source: z.enum(['host', 'pack', 'driver', 'runtime']),
    detail: z.string().optional(),
  }).strict()).optional(),
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
export const harnessRuntimeProjectionDefinition = {
  key: 'harnessRuntime',
  // Zod's `.optional()` widens an optional output slot to `T | undefined`;
  // JSON serialization makes that indistinguishable from an absent property,
  // while the public projection deliberately keeps exact optional fields.
  stateSchema: schema as unknown as z.ZodType<HarnessRuntimeState>,
  init: () => ({ nodes: {}, edges: {} }),
  apply(state, event) {
    if (event.type === 'harness/selected') {
      const sameIdentity = state.harnessId === undefined || state.harnessId === event.data.harnessId
      return {
        harnessId: event.data.harnessId,
        version: event.data.version,
        ...(event.data.authMethod === undefined ? {} : { authMethod: event.data.authMethod }),
        ...(event.data.workspaceMode === undefined ? {} : { workspaceMode: event.data.workspaceMode }),
        ...(event.data.capabilities === undefined ? {} : { capabilities: event.data.capabilities }),
        nodes: sameIdentity ? state.nodes : {},
        edges: sameIdentity ? state.edges : {},
      }
    }
    if (event.type === 'harness/runtime-edge') {
      const sameIdentity = state.harnessId === undefined || state.harnessId === event.data.harnessId
      return {
        harnessId: event.data.harnessId,
        ...(sameIdentity && state.version !== undefined ? { version: state.version } : {}),
        ...(sameIdentity && state.authMethod !== undefined ? { authMethod: state.authMethod } : {}),
        ...(sameIdentity && state.workspaceMode !== undefined ? { workspaceMode: state.workspaceMode } : {}),
        ...(sameIdentity && state.capabilities !== undefined ? { capabilities: state.capabilities } : {}),
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
      ...(sameIdentity && state.authMethod !== undefined ? { authMethod: state.authMethod } : {}),
      ...(sameIdentity && state.workspaceMode !== undefined ? { workspaceMode: state.workspaceMode } : {}),
      ...(sameIdentity && state.capabilities !== undefined ? { capabilities: state.capabilities } : {}),
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
  wire: {
    viewSchema: schema as unknown as z.ZodType<HarnessRuntimeProjection>,
    view: state => state,
  },
  stateVersion: 4,
} satisfies ProjectionDefinition<'harnessRuntime', HarnessRuntimeState>

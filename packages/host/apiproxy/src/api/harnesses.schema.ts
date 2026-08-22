import { z } from 'zod'
import type { RequestPayload, ResponseValue } from './rpc-map.ts'
import type { Wire } from './rpc.schema.ts'

const graphNodeSchema = z.object({
  id: z.string().min(1),
  kind: z.string().min(1),
  title: z.string().min(1),
  editable: z.boolean(),
  config: z.record(z.string(), z.unknown()).optional(),
})

const graphSchema = z.object({
  level: z.enum(['opaque', 'observable', 'composable']),
  nodes: z.array(graphNodeSchema),
  edges: z.array(z.object({ from: z.string().min(1), to: z.string().min(1) })),
})

const distributionSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('npx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('bunx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('uvx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('binary'), archive: z.string().url(), sha256: z.string().optional(), command: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('executable'), command: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
])

/** Detached Harness catalog row schema. */
export const harnessCatalogEntrySchema = z.object({
  schemaVersion: z.literal(0),
  id: z.string().min(1),
  name: z.string().min(1),
  version: z.string().min(1),
  description: z.string().optional(),
  publisher: z.string().min(1),
  license: z.string().optional(),
  repository: z.string().optional(),
  icon: z.string().optional(),
  verified: z.boolean(),
  protocol: z.string().min(1),
  source: z.enum(['builtin', 'acp-registry', 'openfish-community', 'user']),
  isDefault: z.boolean(),
  distribution: distributionSchema.optional(),
  graph: graphSchema,
  available: z.boolean(),
  unavailableReason: z.string().optional(),
  installation: z.object({
    status: z.enum(['builtin', 'not-installed', 'installing', 'installed', 'failed']),
    installedVersion: z.string().optional(),
    availableVersion: z.string(),
    previousVersions: z.array(z.string()),
    error: z.string().optional(),
  }),
  auth: z.object({
    methods: z.array(z.object({
      id: z.string(),
      name: z.string(),
      kind: z.enum(['agent', 'environment', 'terminal']),
      fields: z.array(z.object({
        ref: z.string(),
        name: z.string(),
        env: z.string().optional(),
        required: z.boolean(),
        secret: z.boolean(),
        placeholder: z.string().optional(),
      })),
      terminal: z.object({ args: z.array(z.string()), env: z.record(z.string(), z.string()) }).optional(),
    })),
    selectedMethod: z.string().optional(),
    status: z.enum(['not-required', 'needs-selection', 'needs-credentials', 'configured']),
    missingFields: z.array(z.string()),
  }),
  compatibility: z.object({
    status: z.enum(['untested', 'ready', 'compatible', 'failed']),
    checkedAt: z.string().optional(),
    message: z.string().optional(),
  }),
})

/** harness.list request payload. */
export const harnessListRequestSchema = z.object({
  query: z.string().trim().max(200).optional(),
}) satisfies z.ZodType<Wire<RequestPayload<'harness.list'>>>

/** harness.list response value. */
export const harnessListValueSchema = z.object({
  items: z.array(harnessCatalogEntrySchema),
}) satisfies z.ZodType<Wire<ResponseValue<'harness.list'>>>

/** harness.refresh request payload. */
export const harnessRefreshRequestSchema = z.object({}) satisfies z.ZodType<Wire<RequestPayload<'harness.refresh'>>>
/** harness.refresh response value. */
export const harnessRefreshValueSchema = harnessListValueSchema satisfies z.ZodType<Wire<ResponseValue<'harness.refresh'>>>

const customPackSchema = z.object({
  schemaVersion: z.literal(0), id: z.string().min(1), name: z.string().min(1), version: z.string().min(1),
  description: z.string().optional(), publisher: z.string().min(1), license: z.string().optional(),
  repository: z.string().optional(), icon: z.string().optional(), protocol: z.string().min(1),
  authMethods: z.array(z.object({
    id: z.string().min(1), name: z.string().min(1), kind: z.enum(['agent', 'environment', 'terminal']),
    fields: z.array(z.object({
      ref: z.string().min(1), name: z.string().min(1), env: z.string().min(1).optional(),
      required: z.boolean(), secret: z.boolean(), placeholder: z.string().optional(),
    })),
    terminal: z.object({ args: z.array(z.string()), env: z.record(z.string(), z.string()) }).optional(),
  })).optional(),
  distribution: distributionSchema, graph: graphSchema,
})

/** harness.mutate lifecycle/editor request payload. */
export const harnessMutateRequestSchema = z.object({
  action: z.enum(['install', 'uninstall', 'update', 'rollback', 'remove', 'auth', 'login', 'default', 'clear-default', 'upsert']),
  id: z.string().optional(), authMethod: z.string().optional(), pack: customPackSchema.optional(),
}) satisfies z.ZodType<Wire<RequestPayload<'harness.mutate'>>>
/** harness.mutate response value. */
export const harnessMutateValueSchema = harnessListValueSchema satisfies z.ZodType<Wire<ResponseValue<'harness.mutate'>>>

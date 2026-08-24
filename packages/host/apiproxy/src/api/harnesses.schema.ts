import { z } from 'zod'
import type { HarnessRuntimeSignal } from '@deepseek-ai/dsh-harness'
import type { RequestPayload, ResponseValue } from './rpc-map.ts'
import type { Wire } from './rpc.schema.ts'

const graphEvidenceSchema = z.object({
  kind: z.enum(['declared', 'source-derived', 'runtime-observed']),
  source: z.string().min(1),
  version: z.string().min(1).optional(),
})

const runtimeSignalSchema = (
  z.string().min(1).regex(/^[a-z0-9][a-z0-9._-]*$/u)
) as unknown as z.ZodType<HarnessRuntimeSignal>

const graphPortSchema = z.object({
  id: z.string().min(1), name: z.string().min(1), direction: z.enum(['input', 'output']),
  dataType: z.string().min(1), required: z.boolean().optional(),
})

const configFieldSchema = z.object({
  id: z.string().min(1), name: z.string().min(1), description: z.string().min(1).optional(),
  type: z.enum(['string', 'boolean', 'select', 'secret-reference']), required: z.boolean(),
  choices: z.array(z.object({
    id: z.string().min(1), name: z.string().min(1), description: z.string().min(1).optional(),
  })).min(1).optional(),
  binding: z.object({ kind: z.string().min(1), target: z.string().min(1) }),
})

const graphNodeSchema = z.object({
  id: z.string().min(1),
  kind: z.string().min(1),
  title: z.string().min(1),
  editable: z.boolean(),
  responsibility: z.string().min(1).optional(),
  inputs: z.array(z.string().min(1)).optional(),
  outputs: z.array(z.string().min(1)).optional(),
  ports: z.array(graphPortSchema).optional(),
  evidence: z.array(graphEvidenceSchema).min(1).optional(),
  observes: z.array(runtimeSignalSchema).min(1).optional(),
  position: z.object({ x: z.number(), y: z.number() }).optional(),
  configSchema: z.object({ version: z.literal(1), fields: z.array(configFieldSchema).min(1) }).optional(),
  config: z.record(z.string(), z.unknown()).optional(),
})

const graphSchema = z.object({
  level: z.enum(['opaque', 'observable', 'composable']),
  manifestVersion: z.literal(1).optional(),
  boundary: z.string().min(1).optional(),
  evidence: z.array(graphEvidenceSchema).min(1).optional(),
  nodes: z.array(graphNodeSchema),
  edges: z.array(z.object({
    from: z.string().min(1), to: z.string().min(1),
    fromPort: z.string().min(1).optional(), toPort: z.string().min(1).optional(),
    label: z.string().min(1).optional(),
    observes: z.array(runtimeSignalSchema).min(1).optional(),
  })),
})

const driverBundleSchema = z.object({
  apiVersion: z.literal(1),
  package: z.string().min(1),
  spec: z.string().min(1),
  requiresInstallScripts: z.boolean(),
})

const distributionSchema = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('npx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('bunx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({ kind: z.literal('uvx'), package: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
  z.object({
    kind: z.literal('binary'), archive: z.url(), sha256: z.string().optional(),
    command: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()),
  }),
  z.object({ kind: z.literal('executable'), command: z.string().min(1), args: z.array(z.string()), env: z.record(z.string(), z.string()) }),
])

const harnessCapabilitySchema = z.object({
  id: z.enum([
    'lifecycle.install', 'lifecycle.update', 'lifecycle.rollback', 'lifecycle.uninstall',
    'session.create', 'session.resume', 'session.cancel', 'session.fork', 'session.archive',
    'workspace.project', 'workspace.no-project',
    'configuration.models', 'configuration.reasoning', 'configuration.auth', 'configuration.agent-presets',
    'interaction.tools', 'interaction.approvals', 'interaction.questions', 'interaction.files', 'interaction.events',
    'architecture.manifest', 'architecture.runtime-observation', 'architecture.edit',
    'diagnostics.preflight', 'builder.manifest', 'builder.test', 'builder.publish',
  ]),
  status: z.enum(['supported', 'runtime', 'unsupported']),
  source: z.enum(['host', 'pack', 'driver', 'runtime']),
  detail: z.string().optional(),
})

const accountSchema = z.object({
  label: z.string().min(1),
  billing: z.enum(['subscription', 'usage', 'local', 'harness-managed', 'unknown']),
  detail: z.string().min(1),
})

const modelConfigurationSchema = z.object({
  owner: z.enum(['host', 'harness']), required: z.boolean(), detail: z.string().min(1),
})

const agentAuthSchema = z.object({
  metaKey: z.string().min(1), fieldMap: z.record(z.string().min(1), z.string().min(1)),
})

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
  account: accountSchema.optional(),
  modelConfiguration: modelConfigurationSchema.optional(),
  driverBundle: driverBundleSchema.optional(),
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
    integrity: z.object({
      status: z.enum(['trusted-runtime', 'checksum-declared', 'checksum-verified', 'version-pinned', 'local-executable', 'unverified']),
      source: z.string(),
      digest: z.string().optional(),
      detail: z.string(),
    }),
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
      account: accountSchema.optional(),
      agent: agentAuthSchema.optional(),
      terminal: z.object({ args: z.array(z.string()), env: z.record(z.string(), z.string()) }).optional(),
    })),
    selectedMethod: z.string().optional(),
    status: z.enum(['not-required', 'needs-selection', 'needs-credentials', 'configured']),
    missingFields: z.array(z.string()),
  }),
  compatibility: z.object({
    status: z.enum(['untested', 'ready', 'compatible', 'failed']),
    classification: z.enum(['supported', 'experimental', 'opaque-but-runnable', 'incompatible']),
    checkedAt: z.string().optional(),
    message: z.string().optional(),
  }),
  publication: z.object({
    status: z.enum(['local-draft', 'update-draft', 'submitted', 'published', 'revocation-requested', 'revoked']),
    review: z.enum(['not-submitted', 'pending', 'changes-requested', 'closed', 'merged', 'revoked']),
    publishedVersion: z.string().optional(),
    knownVersions: z.array(z.string()),
    catalogUrl: z.url().optional(),
    detail: z.string(),
    revokedVersion: z.string().optional(),
    revokedReason: z.string().optional(),
    revokedAt: z.string().optional(),
    reviewUrl: z.url().optional(),
  }).optional(),
  capabilities: z.array(harnessCapabilitySchema),
  driver: z.object({
    apiVersion: z.literal(1),
    protocol: z.string().min(1),
    loaded: z.boolean(),
    authorization: z.enum(['not-required', 'required', 'authorized']),
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

/** harness.resolve request payload. */
export const harnessResolveRequestSchema = z.object({
  id: z.string().min(1),
  version: z.string().min(1).optional(),
  authMethod: z.string().min(1).optional(),
}) satisfies z.ZodType<Wire<RequestPayload<'harness.resolve'>>>

/** harness.resolve response value. */
export const harnessResolveValueSchema = z.object({
  item: harnessCatalogEntrySchema,
}) satisfies z.ZodType<Wire<ResponseValue<'harness.resolve'>>>

/** harness.refresh request payload. */
export const harnessRefreshRequestSchema = z.object({}) satisfies z.ZodType<Wire<RequestPayload<'harness.refresh'>>>
/** harness.refresh response value. */
export const harnessRefreshValueSchema = harnessListValueSchema satisfies z.ZodType<Wire<ResponseValue<'harness.refresh'>>>

const customPackSchema = z.object({
  schemaVersion: z.literal(0), id: z.string().min(1), name: z.string().min(1), version: z.string().min(1),
  description: z.string().optional(), publisher: z.string().min(1), license: z.string().optional(),
  repository: z.string().optional(), icon: z.string().optional(), protocol: z.string().min(1),
  account: accountSchema.optional(), modelConfiguration: modelConfigurationSchema.optional(),
  driverBundle: driverBundleSchema.optional(),
  authMethods: z.array(z.object({
    id: z.string().min(1), name: z.string().min(1), kind: z.enum(['agent', 'environment', 'terminal']),
    fields: z.array(z.object({
      ref: z.string().min(1), name: z.string().min(1), env: z.string().min(1).optional(),
      required: z.boolean(), secret: z.boolean(), placeholder: z.string().optional(),
    })),
    account: accountSchema.optional(),
    agent: agentAuthSchema.optional(),
    terminal: z.object({ args: z.array(z.string()), env: z.record(z.string(), z.string()) }).optional(),
  })).optional(),
  distribution: distributionSchema, graph: graphSchema,
})

/** harness.mutate lifecycle/editor request payload. */
export const harnessMutateRequestSchema = z.object({
  action: z.enum(['install', 'uninstall', 'update', 'rollback', 'auth', 'probe', 'default', 'clear-default']),
  id: z.string().optional(), authMethod: z.string().optional(), acceptUnverified: z.boolean().optional(), pack: customPackSchema.optional(),
}) satisfies z.ZodType<Wire<RequestPayload<'harness.mutate'>>>
/** harness.mutate response value. */
export const harnessMutateValueSchema = harnessListValueSchema satisfies z.ZodType<Wire<ResponseValue<'harness.mutate'>>>

/** Host-local Pack authoring and terminal-login request payload. */
export const harnessManageRequestSchema = z.object({
  action: z.enum(['install', 'update', 'probe', 'remove', 'login', 'upsert', 'validate-publication', 'submit-publication', 'submit-revocation', 'authorize-driver']),
  id: z.string().optional(), version: z.string().optional(),
  driverPackage: z.string().optional(), driverSpec: z.string().optional(),
  authMethod: z.string().optional(), reason: z.string().optional(),
  acceptUnverified: z.boolean().optional(), pack: customPackSchema.optional(),
}) satisfies z.ZodType<Wire<RequestPayload<'harness.manage'>>>
/** harness.manage response value. */
export const harnessManageValueSchema = harnessListValueSchema satisfies z.ZodType<Wire<ResponseValue<'harness.manage'>>>

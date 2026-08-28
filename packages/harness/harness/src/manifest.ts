/** Harness Pack v0 admission and ACP Registry projection. @module */

import { z } from 'zod'
import { isAbsolute, normalize, win32 } from 'node:path'
import type { HarnessId, HarnessPack } from './types.ts'

const MAX_SHORT_TEXT = 256
const MAX_DETAIL_TEXT = 8_192
const MAX_URL_TEXT = 4_096
const MAX_ARGUMENTS = 128
const MAX_ENVIRONMENT_FIELDS = 128
const MAX_GRAPH_NODES = 256
const MAX_GRAPH_EDGES = 1_024
const MAX_NODE_PORTS = 64
const MAX_NODE_CONTROLS = 64
const MAX_SELECT_CHOICES = 128
const MAX_RUNTIME_SIGNALS = 64
const MAX_REGISTRY_AGENTS = 4_096
const MAX_REGISTRY_AUTHORS = 32
const MAX_REGISTRY_BINARY_TARGETS = 32
const FORBIDDEN_TEXT_CONTROL = /[\u0000\u0008\u000b\u000c\u000e-\u001f\u007f]/u
const shortText = z.string().min(1).max(MAX_SHORT_TEXT)
  .refine(value => value.trim().length > 0 && !/[\u0000-\u001f\u007f]/u.test(value), 'Expected printable non-empty text.')
const stableId = z.string().min(1).max(MAX_SHORT_TEXT).regex(/^[a-z0-9][a-z0-9._-]*$/u)
const optionalShortText = z.string().max(MAX_SHORT_TEXT)
  .refine(value => !/[\u0000-\u001f\u007f]/u.test(value), 'Expected printable text.')
const detailText = z.string().min(1).max(MAX_DETAIL_TEXT)
  .refine(value => value.trim().length > 0 && !FORBIDDEN_TEXT_CONTROL.test(value), 'Expected non-empty display text.')
const optionalDetailText = z.string().max(MAX_DETAIL_TEXT)
  .refine(value => !FORBIDDEN_TEXT_CONTROL.test(value), 'Expected display text.')
const urlText = z.string().max(MAX_URL_TEXT).url()
const processText = z.string().max(MAX_DETAIL_TEXT).refine(value => !value.includes('\u0000'), 'Process text cannot contain NUL.')
const argumentList = z.array(processText).max(MAX_ARGUMENTS)
const stringRecord = z.record(z.string().min(1).max(MAX_SHORT_TEXT), processText).superRefine((record, context) => {
  if (Object.keys(record).length > MAX_ENVIRONMENT_FIELDS) {
    context.addIssue({ code: 'custom', message: `Environment maps may contain at most ${MAX_ENVIRONMENT_FIELDS} entries.` })
  }
})
const ENVIRONMENT_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/u
const SENSITIVE_ENVIRONMENT_NAME = /(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)$/iu
const EXACT_NPM_VERSION = /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/u
const EXACT_PYTHON_VERSION = /^[0-9][0-9A-Za-z._+-]*$/u
const NPM_PACKAGE_NAME = /^(?:@[a-z0-9][a-z0-9._~-]*\/)?[a-z0-9][a-z0-9._~-]*$/u
const PYTHON_PACKAGE_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]*$/u
const EXACT_GITHUB_DRIVER = /^github:[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\/[A-Za-z0-9._-]+#[0-9a-fA-F]{40}$/u
const BUNDLED_DRIVER_PROTOCOLS = new Set(['dsh', 'acp', 'codex-app-server'])
const BUILTIN_RUNTIME_SIGNALS = new Set([
  'protocol.ready', 'session.ready', 'turn.started', 'turn.completed', 'turn.failed',
  'model.completed', 'tool.activity', 'output.activity', 'approval.requested', 'approval.resolved',
])
const PRIVATE_PUBLICATION_TEXT = [
  /(?:^|[\s"'])\/Users\/[^/\s"']+/u,
  /(?:^|[\s"'])[A-Za-z]:\\Users\\[^\\\s"']+/u,
  /\bfile:\/\//iu,
  /\b(?:localhost|[a-z0-9-]+\.local)(?::\d+)?\b/iu,
  /\b127\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/u,
  /\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b/u,
  /\b192\.168\.\d{1,3}\.\d{1,3}\b/u,
  /\b172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b/u,
  /\b(?:sk|token|key)-[a-z0-9_-]{12,}\b/iu,
  /\b(?:api[_-]?key|authorization|password|secret|session[_-]?token)\s*[:=]\s*\S+/iu,
]
const distribution = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('npx'), package: shortText, args: argumentList.default([]), env: stringRecord.default({}) }),
  z.object({ kind: z.literal('bunx'), package: shortText, args: argumentList.default([]), env: stringRecord.default({}) }),
  z.object({ kind: z.literal('uvx'), package: shortText, args: argumentList.default([]), env: stringRecord.default({}) }),
  z.object({
    kind: z.literal('binary'), archive: urlText, sha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(),
    command: z.string().min(1).max(MAX_URL_TEXT), args: argumentList.default([]), env: stringRecord.default({}),
  }),
  z.object({ kind: z.literal('executable'), command: z.string().min(1).max(MAX_URL_TEXT), args: argumentList.default([]), env: stringRecord.default({}) }),
])
const graphEvidence = z.object({
  kind: z.enum(['declared', 'source-derived', 'runtime-observed']),
  source: detailText,
  version: shortText.optional(),
})
const runtimeSignal = z.string().min(1).max(MAX_SHORT_TEXT).regex(/^[a-z0-9][a-z0-9._-]*$/u)
const graphPort = z.object({
  id: stableId, name: shortText, direction: z.enum(['input', 'output']),
  dataType: shortText, required: z.boolean().optional(),
})
const configField = z.object({
  id: stableId, name: shortText, description: detailText.optional(),
  type: z.enum(['string', 'boolean', 'select', 'secret-reference']), required: z.boolean(),
  choices: z.array(z.object({
    id: shortText, name: shortText, description: detailText.optional(),
  })).min(1).max(MAX_SELECT_CHOICES).optional(),
  binding: z.object({ kind: stableId, target: z.string().min(1).max(MAX_SHORT_TEXT) }),
})
const nodeConfiguration = z.record(
  stableId,
  z.union([optionalDetailText, z.boolean(), z.number().finite()]),
).superRefine((record, context) => {
  if (Object.keys(record).length > MAX_NODE_CONTROLS + 2) {
    context.addIssue({ code: 'custom', message: `Node configuration may contain at most ${MAX_NODE_CONTROLS} controls.` })
  }
})
const graphNode = z.object({
  id: stableId,
  kind: stableId,
  title: shortText,
  editable: z.boolean(),
  responsibility: detailText.optional(),
  inputs: z.array(shortText).max(MAX_NODE_PORTS).optional(),
  outputs: z.array(shortText).max(MAX_NODE_PORTS).optional(),
  ports: z.array(graphPort).max(MAX_NODE_PORTS).optional(),
  evidence: z.array(graphEvidence).min(1).max(32).optional(),
  observes: z.array(runtimeSignal).min(1).max(MAX_RUNTIME_SIGNALS).optional(),
  position: z.object({ x: z.number().finite(), y: z.number().finite() }).optional(),
  configSchema: z.object({ version: z.literal(1), fields: z.array(configField).min(1).max(MAX_NODE_CONTROLS) }).optional(),
  config: nodeConfiguration.optional(),
})
const graph = z.object({
  level: z.enum(['opaque', 'observable', 'composable']),
  manifestVersion: z.literal(1).optional(),
  boundary: detailText.optional(),
  evidence: z.array(graphEvidence).min(1).max(32).optional(),
  nodes: z.array(graphNode).max(MAX_GRAPH_NODES),
  edges: z.array(z.object({
    from: shortText, to: shortText,
    fromPort: shortText.optional(), toPort: shortText.optional(),
    label: shortText.optional(),
    observes: z.array(runtimeSignal).min(1).max(MAX_RUNTIME_SIGNALS).optional(),
  })).max(MAX_GRAPH_EDGES),
})
const driverBundle = z.object({
  apiVersion: z.literal(1),
  package: shortText,
  spec: z.string().min(1).max(MAX_URL_TEXT),
  requiresInstallScripts: z.boolean(),
})
const account = z.object({
  label: shortText,
  billing: z.enum(['subscription', 'usage', 'local', 'harness-managed', 'unknown']),
  detail: detailText,
})
const modelConfiguration = z.object({
  owner: z.enum(['host', 'harness']), required: z.boolean(), detail: detailText,
})
const authenticationDiscovery = z.object({
  source: z.enum(['pack', 'runtime']), detail: detailText,
})
const agentAuthentication = z.object({
  metaKey: shortText,
  fieldMap: z.record(shortText, shortText).superRefine((record, context) => {
    if (Object.keys(record).length > MAX_NODE_CONTROLS) {
      context.addIssue({ code: 'custom', message: `Agent authentication maps may contain at most ${MAX_NODE_CONTROLS} entries.` })
    }
  }),
})

const packSchema = z.object({
  schemaVersion: z.literal(0),
  id: stableId,
  name: shortText,
  // Versions become managed directory names and durable session identities.
  // Keep the vocabulary portable and traversal-free before any filesystem use.
  version: z.string().max(MAX_SHORT_TEXT).regex(/^[0-9A-Za-z][0-9A-Za-z._+-]*$/u),
  description: optionalDetailText.optional(),
  publisher: shortText,
  license: optionalShortText.optional(),
  repository: urlText.optional(),
  icon: urlText.optional(),
  verified: z.boolean(),
  protocol: stableId,
  account: account.optional(),
  modelConfiguration: modelConfiguration.optional(),
  authenticationDiscovery: authenticationDiscovery.optional(),
  driverBundle: driverBundle.optional(),
  authMethods: z.array(z.object({
    id: stableId, name: shortText, kind: z.enum(['agent', 'environment', 'terminal']),
    fields: z.array(z.object({
      ref: shortText, name: shortText, env: shortText.optional(),
      required: z.boolean().default(true), secret: z.boolean().default(true), placeholder: optionalShortText.optional(),
    })).max(MAX_NODE_CONTROLS).default([]),
    account: account.optional(),
    agent: agentAuthentication.optional(),
    terminal: z.object({ args: argumentList, env: stringRecord }).optional(),
  })).max(32).optional(),
  distribution: distribution.optional(),
  graph,
  source: z.enum(['builtin', 'acp-registry', 'openfish-community', 'user']),
})

/**
 * Parse an untrusted Harness Pack document and reject dangling graph edges.
 * @param input - Untrusted Pack-shaped value.
 * @returns Validated Pack v0 with schema defaults applied.
 */
export function parseHarnessPack(input: unknown): HarnessPack {
  const parsed = packSchema.parse(input) as HarnessPack
  const pack: HarnessPack = {
    ...parsed,
    graph: {
      ...parsed.graph,
      nodes: parsed.graph.nodes.map((node) => {
        const config = node.config
        const schemaOwnsLegacyKeys = node.configSchema?.fields.some(field => field.id === 'x' || field.id === 'y') === true
        if (node.position !== undefined || config === undefined || schemaOwnsLegacyKeys
          || typeof config.x !== 'number' || !Number.isFinite(config.x)
          || typeof config.y !== 'number' || !Number.isFinite(config.y)) return node
        const { x, y, ...driverConfig } = config
        const nodeWithoutConfig = { ...node }
        delete nodeWithoutConfig.config
        return {
          ...nodeWithoutConfig,
          position: { x, y },
          ...(Object.keys(driverConfig).length === 0 ? {} : { config: driverConfig }),
        }
      }),
    },
  }
  const nodes = new Set(pack.graph.nodes.map(node => node.id))
  if (nodes.size !== pack.graph.nodes.length) throw new Error(`Harness Pack "${pack.id}" graph node ids must be unique`)
  const authMethods = pack.authMethods ?? []
  if (new Set(authMethods.map(method => method.id)).size !== authMethods.length) {
    throw new Error(`Harness Pack "${pack.id}" authentication method ids must be unique`)
  }
  for (const method of authMethods) {
    if (method.kind === 'terminal' && method.terminal === undefined) {
      throw new Error(`Harness Pack "${pack.id}" terminal authentication method "${method.id}" requires terminal argv`)
    }
    if (method.kind !== 'terminal' && method.terminal !== undefined) {
      throw new Error(`Harness Pack "${pack.id}" non-terminal authentication method "${method.id}" cannot declare terminal argv`)
    }
    if (method.kind !== 'agent' && method.agent !== undefined) {
      throw new Error(`Harness Pack "${pack.id}" non-agent authentication method "${method.id}" cannot declare ACP agent metadata`)
    }
    if (method.agent !== undefined) {
      const fieldRefs = new Set(method.fields.map(field => field.ref))
      const unknown = Object.keys(method.agent.fieldMap).find(ref => !fieldRefs.has(ref))
      if (unknown !== undefined) {
        throw new Error(`Harness Pack "${pack.id}" agent authentication maps unknown credential reference "${unknown}"`)
      }
    }
    for (const field of method.fields) {
      if (!ENVIRONMENT_NAME.test(field.ref)) {
        throw new Error(`Harness Pack "${pack.id}" authentication field "${field.ref}" is not a credential reference`)
      }
      if (field.env !== undefined && !ENVIRONMENT_NAME.test(field.env)) {
        throw new Error(`Harness Pack "${pack.id}" authentication field "${field.ref}" has an invalid environment name`)
      }
    }
    for (const key of Object.keys(method.terminal?.env ?? {})) {
      if (!ENVIRONMENT_NAME.test(key)) throw new Error(`Harness Pack "${pack.id}" terminal authentication has an invalid environment name`)
    }
  }
  if (pack.driverBundle !== undefined) {
    if (BUNDLED_DRIVER_PROTOCOLS.has(pack.protocol)) {
      throw new Error(`Harness Pack "${pack.id}" cannot replace bundled protocol Driver "${pack.protocol}"`)
    }
    if (pack.driverBundle.package.length > 214 || !NPM_PACKAGE_NAME.test(pack.driverBundle.package)) {
      throw new Error(`Harness Pack "${pack.id}" Driver Bundle has an invalid package identity`)
    }
    const registryPackage = pinnedNpmPackageName(pack.driverBundle.spec)
    if (registryPackage !== undefined && registryPackage !== pack.driverBundle.package) {
      throw new Error(`Harness Pack "${pack.id}" Driver Bundle spec does not match package "${pack.driverBundle.package}"`)
    }
    if (registryPackage === undefined && !EXACT_GITHUB_DRIVER.test(pack.driverBundle.spec)) {
      throw new Error(`Harness Pack "${pack.id}" Driver Bundle must pin an exact npm version or GitHub commit`)
    }
  }
  if (pack.source === 'openfish-community' && !BUNDLED_DRIVER_PROTOCOLS.has(pack.protocol)
    && pack.driverBundle === undefined) {
    throw new Error(`Harness Pack "${pack.id}" publication requires an exact self-installable Driver Bundle`)
  }

  const validateRuntimeSignal = (signal: string): void => {
    if (BUILTIN_RUNTIME_SIGNALS.has(signal)) return
    if (!signal.startsWith(`driver.${pack.protocol}.`) || signal.length === `driver.${pack.protocol}.`.length) {
      throw new Error(`Harness Pack "${pack.id}" runtime signal "${signal}" must use namespace "driver.${pack.protocol}."`)
    }
  }
  for (const edge of pack.graph.edges) {
    if (!nodes.has(edge.from) || !nodes.has(edge.to)) {
      throw new Error(`Harness Pack "${pack.id}" graph edge references an unknown node`)
    }
    if (edge.from === edge.to) throw new Error(`Harness Pack "${pack.id}" graph cannot connect a node to itself`)
    for (const signal of edge.observes ?? []) validateRuntimeSignal(signal)
    const source = pack.graph.nodes.find(node => node.id === edge.from)
    const target = pack.graph.nodes.find(node => node.id === edge.to)
    const sourcePort = edge.fromPort === undefined ? undefined : source?.ports?.find(port => port.id === edge.fromPort)
    const targetPort = edge.toPort === undefined ? undefined : target?.ports?.find(port => port.id === edge.toPort)
    if (edge.fromPort !== undefined && (sourcePort === undefined || sourcePort.direction !== 'output')) {
      throw new Error(`Harness Pack "${pack.id}" graph edge references an invalid output port`)
    }
    if (edge.toPort !== undefined && (targetPort === undefined || targetPort.direction !== 'input')) {
      throw new Error(`Harness Pack "${pack.id}" graph edge references an invalid input port`)
    }
    if (sourcePort !== undefined && targetPort !== undefined && sourcePort.dataType !== targetPort.dataType) {
      throw new Error(`Harness Pack "${pack.id}" graph edge connects incompatible port types "${sourcePort.dataType}" and "${targetPort.dataType}"`)
    }
  }
  const edgeKeys = pack.graph.edges.map(edge => `${edge.from}\u0000${edge.fromPort ?? ''}\u0000${edge.to}\u0000${edge.toPort ?? ''}`)
  if (new Set(edgeKeys).size !== edgeKeys.length) throw new Error(`Harness Pack "${pack.id}" graph edges must be unique`)
  for (const edge of pack.graph.edges) {
    if (edge.observes !== undefined && new Set(edge.observes).size !== edge.observes.length) {
      throw new Error(`Harness Pack "${pack.id}" graph edge runtime signals must be unique`)
    }
  }
  if (pack.graph.level !== 'composable' && pack.graph.nodes.some(node => node.editable)) {
    throw new Error(`Harness Pack "${pack.id}" may expose editable nodes only at graph level "composable"`)
  }
  if (pack.graph.level === 'opaque' && pack.graph.nodes.length !== 1) {
    throw new Error(`Harness Pack "${pack.id}" opaque graph must expose exactly one runtime boundary node`)
  }
  if (pack.graph.level !== 'opaque') {
    if (pack.graph.nodes.length === 0) throw new Error(`Harness Pack "${pack.id}" ${pack.graph.level} graph needs at least one evidenced component`)
    const adjacent = new Map(pack.graph.nodes.map(node => [node.id, new Set<string>()]))
    for (const edge of pack.graph.edges) {
      adjacent.get(edge.from)?.add(edge.to)
      adjacent.get(edge.to)?.add(edge.from)
    }
    const visited = new Set<string>()
    const pending = [pack.graph.nodes[0]?.id].filter((id): id is string => id !== undefined)
    while (pending.length > 0) {
      const id = pending.pop()
      if (id === undefined || visited.has(id)) continue
      visited.add(id)
      for (const next of adjacent.get(id) ?? []) pending.push(next)
    }
    if (visited.size !== pack.graph.nodes.length) {
      throw new Error(`Harness Pack "${pack.id}" ${pack.graph.level} graph must connect every declared component`)
    }
    if (pack.graph.boundary === undefined || pack.graph.evidence === undefined) {
      throw new Error(`Harness Pack "${pack.id}" ${pack.graph.level} graph requires a boundary and graph evidence`)
    }
    const unsupported = pack.graph.nodes.find(node => node.responsibility === undefined || node.evidence === undefined)
    if (unsupported !== undefined) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${unsupported.id}" requires responsibility and evidence`)
    }
  }
  for (const node of pack.graph.nodes) {
    for (const signal of node.observes ?? []) validateRuntimeSignal(signal)
    if (node.inputs !== undefined && new Set(node.inputs).size !== node.inputs.length) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" declares an input more than once`)
    }
    if (node.outputs !== undefined && new Set(node.outputs).size !== node.outputs.length) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" declares an output more than once`)
    }
    if (node.observes !== undefined && new Set(node.observes).size !== node.observes.length) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" declares a runtime signal more than once`)
    }
    if (node.ports !== undefined && new Set(node.ports.map(port => port.id)).size !== node.ports.length) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" declares a port more than once`)
    }
    const fields = node.configSchema?.fields ?? []
    if (fields.length > 0 && !node.editable) {
      throw new Error(`Harness Pack "${pack.id}" read-only node "${node.id}" cannot declare executable configuration fields`)
    }
    if (new Set(fields.map(field => field.id)).size !== fields.length) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" declares a configuration field more than once`)
    }
    const fieldIds = new Set(fields.map(field => field.id))
    const unknownConfiguration = Object.keys(node.config ?? {}).find(key => !fieldIds.has(key))
    if (unknownConfiguration !== undefined) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${node.id}" configures undeclared field "${unknownConfiguration}"`)
    }
    for (const field of fields) {
      if (field.type === 'select' && (field.choices?.length ?? 0) === 0) {
        throw new Error(`Harness Pack "${pack.id}" select field "${field.id}" requires choices`)
      }
      if (field.type !== 'select' && field.choices !== undefined) {
        throw new Error(`Harness Pack "${pack.id}" non-select field "${field.id}" cannot declare choices`)
      }
      if (field.choices !== undefined && new Set(field.choices.map(choice => choice.id)).size !== field.choices.length) {
        throw new Error(`Harness Pack "${pack.id}" select field "${field.id}" declares a choice more than once`)
      }
      const value = node.config?.[field.id]
      if (field.required && value === undefined) {
        throw new Error(`Harness Pack "${pack.id}" required field "${field.id}" needs a credential-free default or reference`)
      }
      if (field.type === 'boolean' && value !== undefined && typeof value !== 'boolean') {
        throw new Error(`Harness Pack "${pack.id}" boolean field "${field.id}" must store a boolean`)
      }
      if (field.type !== 'boolean' && value !== undefined && typeof value !== 'string') {
        throw new Error(`Harness Pack "${pack.id}" field "${field.id}" must store text`)
      }
      if (field.type === 'select' && typeof value === 'string'
        && !field.choices?.some(choice => choice.id === value)) {
        throw new Error(`Harness Pack "${pack.id}" select field "${field.id}" must select a declared choice`)
      }
      if (field.type === 'secret-reference' && value !== undefined
        && (typeof value !== 'string' || !ENVIRONMENT_NAME.test(value))) {
        throw new Error(`Harness Pack "${pack.id}" credential-reference field "${field.id}" must store a Host credential reference, never a secret value`)
      }
    }
  }
  if (pack.protocol !== 'dsh' && pack.distribution === undefined) {
    throw new Error(`Harness Pack "${pack.id}" requires a distribution`)
  }
  for (const key of Object.keys(pack.distribution?.env ?? {})) {
    if (!ENVIRONMENT_NAME.test(key)) throw new Error(`Harness Pack "${pack.id}" distribution has an invalid environment name`)
  }
  if ((pack.source === 'user' || pack.source === 'openfish-community') && pack.distribution !== undefined) {
    const distribution = pack.distribution
    if ((distribution.kind === 'npx' || distribution.kind === 'bunx') && !isPinnedNpmPackage(distribution.package)) {
      throw new Error(`Harness Pack "${pack.id}" must pin its npm/Bun package to an exact version`)
    }
    if (distribution.kind === 'uvx' && !isPinnedPythonPackage(distribution.package)) {
      throw new Error(`Harness Pack "${pack.id}" must pin its Python package to an exact version`)
    }
  }
  if (pack.distribution?.kind === 'binary') {
    const command = pack.distribution.command.replaceAll('\\', '/')
    if (isAbsolute(command) || win32.isAbsolute(pack.distribution.command) || normalize(command).startsWith('..')) {
      throw new Error(`Harness Pack "${pack.id}" binary command must stay inside its installation directory`)
    }
    if (pack.source !== 'builtin' && !isCredentialFreeHttpsUrl(pack.distribution.archive)) {
      throw new Error(`Harness Pack "${pack.id}" binary must use a credential-free HTTPS archive URL`)
    }
  }
  if (pack.source === 'openfish-community' && pack.distribution?.kind === 'executable') {
    throw new Error(`Harness Pack "${pack.id}" community publication requires a portable package or checksummed binary distribution`)
  }
  if (pack.source === 'openfish-community' && pack.distribution?.kind === 'binary' && pack.distribution.sha256 === undefined) {
    throw new Error(`Harness Pack "${pack.id}" community binary publication requires a SHA-256 checksum`)
  }
  if (pack.source === 'user' || pack.source === 'openfish-community') {
    const publicEnvironments = [pack.distribution?.env, ...authMethods.map(method => method.terminal?.env)]
    for (const environment of publicEnvironments) {
      const leaked = Object.entries(environment ?? {}).find(([name, value]) => SENSITIVE_ENVIRONMENT_NAME.test(name) && value !== '')
      if (leaked !== undefined) {
        throw new Error(`Harness Pack "${pack.id}" cannot store a value for potential secret "${leaked[0]}"; declare an Authentication field instead`)
      }
    }
  }
  return pack
}

function publicStrings(value: unknown, path = '$'): Array<{ path: string; value: string }> {
  if (typeof value === 'string') return [{ path, value }]
  if (Array.isArray(value)) return value.flatMap((entry, index) => publicStrings(entry, `${path}[${index}]`))
  if (typeof value !== 'object' || value === null) return []
  return Object.entries(value).flatMap(([key, entry]) => publicStrings(entry, `${path}.${key}`))
}

/**
 * Normalize and validate a credential-free Pack for the public OpenFish
 * community workflow. This is publication admission, not a security review.
 * @param input - untrusted Pack candidate supplied for public review.
 * @returns a normalized unverified community Pack when admission succeeds.
 */
export function prepareHarnessPublication(input: unknown): HarnessPack {
  const candidate = typeof input === 'object' && input !== null
    ? { ...(input as Record<string, unknown>), source: 'openfish-community', verified: false }
    : input
  const pack = parseHarnessPack(candidate)
  if (pack.repository === undefined || !isCredentialFreeHttpsUrl(pack.repository)) {
    throw new Error(`Harness Pack "${pack.id}" publication requires a public HTTPS source repository`)
  }
  if (pack.license === undefined || pack.license.trim() === '') {
    throw new Error(`Harness Pack "${pack.id}" publication requires a license identifier`)
  }
  const privateValue = publicStrings(pack).find(entry => PRIVATE_PUBLICATION_TEXT.some(pattern => pattern.test(entry.value)))
  if (privateValue !== undefined) {
    throw new Error(`Harness Pack "${pack.id}" publication contains private or credential-like data at ${privateValue.path}`)
  }
  if (pack.icon !== undefined && !isCredentialFreeHttpsUrl(pack.icon)) {
    throw new Error(`Harness Pack "${pack.id}" publication icon must be a credential-free HTTPS URL`)
  }
  if (pack.distribution?.kind === 'executable') {
    throw new Error(`Harness Pack "${pack.id}" publication requires a portable package or checksummed binary distribution`)
  }
  if (pack.distribution?.kind === 'binary' && !isCredentialFreeHttpsUrl(pack.distribution.archive)) {
    throw new Error(`Harness Pack "${pack.id}" publication binary must use a credential-free HTTPS archive URL`)
  }
  if (pack.distribution?.kind === 'binary' && pack.distribution.sha256 === undefined) {
    throw new Error(`Harness Pack "${pack.id}" publication binary requires a SHA-256 checksum`)
  }
  return pack
}

function isCredentialFreeHttpsUrl(source: string): boolean {
  try {
    const url = new URL(source)
    return url.protocol === 'https:' && url.username === '' && url.password === ''
  } catch {
    return false
  }
}

const openFishCommunityRevocationSchema = z.object({
  id: z.string().min(1),
  version: z.string().min(1),
  reason: z.string().min(1),
  revokedAt: z.iso.datetime(),
  reviewUrl: z.url().optional(),
})

const openFishCommunitySchema = z.object({
  version: z.literal(0),
  packs: z.array(z.unknown()),
  revocations: z.array(openFishCommunityRevocationSchema).default([]),
})

/** Reviewable ledger entry blocking new installs of one exact community Pack version. */
export type OpenFishCommunityRevocation = z.infer<typeof openFishCommunityRevocationSchema>

/**
 * Parse both admitted Packs and the explicit, reviewable revocation ledger.
 * @param input - untrusted generated community catalog document.
 * @returns normalized Packs and revocations without granting verification status.
 */
export function openFishCommunityCatalog(input: unknown): {
  packs: HarnessPack[]
  revocations: OpenFishCommunityRevocation[]
} {
  const catalog = openFishCommunitySchema.parse(input)
  const packs = catalog.packs.map((candidate) => {
    if (typeof candidate !== 'object' || candidate === null || Array.isArray(candidate)) {
      throw new Error('OpenFish community catalog entries must be objects')
    }
    return prepareHarnessPublication(candidate)
  })
  return { packs, revocations: catalog.revocations.map(item => ({ ...item })) }
}

/**
 * Parse the OpenFish community catalog and mark every entry as unverified data.
 * @param input - Untrusted generated community catalog document.
 * @returns Validated, credential-free community Packs.
 */
export function packsFromOpenFishCommunity(input: unknown): HarnessPack[] {
  return openFishCommunityCatalog(input).packs
}

function isPinnedNpmPackage(spec: string): boolean {
  return pinnedNpmPackageName(spec) !== undefined
}

function pinnedNpmPackageName(spec: string): string | undefined {
  const versionAt = spec.startsWith('@') ? spec.indexOf('@', 1) : spec.lastIndexOf('@')
  const name = versionAt > 0 ? spec.slice(0, versionAt) : ''
  return name.length <= 214 && NPM_PACKAGE_NAME.test(name)
    && EXACT_NPM_VERSION.test(spec.slice(versionAt + 1)) ? name : undefined
}

function isPinnedPythonPackage(spec: string): boolean {
  const equals = spec.lastIndexOf('==')
  const at = spec.lastIndexOf('@')
  const separator = equals > 0 ? equals : at
  const width = equals > 0 ? 2 : 1
  const name = separator > 0 ? spec.slice(0, separator) : ''
  return separator > 0
    && PYTHON_PACKAGE_NAME.test(name)
    && EXACT_PYTHON_VERSION.test(spec.slice(separator + width))
}

const registryBinaryTargets = z.record(shortText, z.object({
  archive: urlText,
  sha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(),
  cmd: z.string().min(1).max(MAX_URL_TEXT).refine(value => !value.includes('\u0000'), 'Command cannot contain NUL.'),
  args: argumentList.optional(),
  env: stringRecord.optional(),
})).superRefine((record, context) => {
  if (Object.keys(record).length > MAX_REGISTRY_BINARY_TARGETS) {
    context.addIssue({
      code: 'custom',
      message: `ACP Registry binary maps may contain at most ${MAX_REGISTRY_BINARY_TARGETS} targets.`,
    })
  }
})

const acpRegistryAgentSchema = z.object({
  id: stableId,
  name: shortText,
  // Registry metadata is bounded here, while registryDistribution() below
  // decides whether a package version is exact enough to become executable.
  version: shortText,
  description: optionalDetailText.optional(),
  repository: urlText.optional(),
  authors: z.array(shortText).max(MAX_REGISTRY_AUTHORS).optional(),
  license: optionalShortText.optional(),
  icon: urlText.optional(),
  distribution: z.object({
    npx: z.object({
      package: shortText,
      args: argumentList.optional(),
      env: stringRecord.optional(),
    }).optional(),
    uvx: z.object({
      package: shortText,
      args: argumentList.optional(),
      env: stringRecord.optional(),
    }).optional(),
    binary: registryBinaryTargets.optional(),
  }).loose(),
}).loose()

// Validate and bound the shared envelope before inspecting rows. Individual
// publishers do not get to make every other Registry entry unavailable by
// shipping one malformed row; admission remains per-Pack below.
const acpRegistrySchema = z.object({
  version: shortText,
  agents: z.array(z.unknown()).max(MAX_REGISTRY_AGENTS),
}).loose()

/**
 * Project supported ACP Registry package or platform distributions into Pack v0.
 * @param input - Untrusted ACP Registry document.
 * @returns Runnable Pack rows for this host; unsupported distributions are omitted.
 */
export function packsFromAcpRegistry(input: unknown): HarnessPack[] {
  const registry = acpRegistrySchema.parse(input)
  const seen = new Set<string>()
  return registry.agents.flatMap((candidate): HarnessPack[] => {
    const parsed = acpRegistryAgentSchema.safeParse(candidate)
    if (!parsed.success) return []
    const agent = parsed.data
    // Duplicate publisher rows are ambiguous. Retain the first Registry row
    // deterministically instead of silently letting a later row replace it.
    if (seen.has(agent.id)) return []
    seen.add(agent.id)
    const selected = registryDistribution(agent.distribution, agent.version)
    if (selected === undefined) return []
    return [parseHarnessPack({
      schemaVersion: 0,
      id: agent.id as HarnessId,
      name: agent.name,
      version: agent.version,
      ...(agent.description === undefined ? {} : { description: agent.description }),
      publisher: agent.authors?.join(', ') || 'ACP Registry publisher',
      ...(agent.license === undefined ? {} : { license: agent.license }),
      ...(agent.repository === undefined ? {} : { repository: agent.repository }),
      ...(agent.icon === undefined ? {} : { icon: agent.icon }),
      // Registry discovery is provenance, not publisher identity or a code
      // audit. Only OpenFish-owned built-ins carry the verification seal.
      verified: false,
      protocol: 'acp',
      modelConfiguration: {
        owner: 'harness', required: false,
        detail: 'Models and model-specific controls are discovered from the running ACP session.',
      },
      authenticationDiscovery: {
        source: 'runtime',
        detail: 'The ACP Registry does not declare account requirements. OpenFish discovers them from the installed Harness before first use.',
      },
      distribution: selected,
      graph: registryArchitecture(agent),
      source: 'acp-registry',
    })]
  })
}

type AcpRegistryAgent = z.infer<typeof acpRegistryAgentSchema>

function registryArchitecture(agent: AcpRegistryAgent): HarnessPack['graph'] {
  return {
    level: 'opaque',
    manifestVersion: 1,
    boundary: `${agent.name} process`,
    evidence: [{ kind: 'declared', source: 'ACP Registry', version: agent.version }],
    nodes: [{
      id: 'runtime', kind: 'harness-runtime', title: agent.name, editable: false,
      responsibility: 'Runs the ACP agent while its private internal architecture remains undisclosed.',
      inputs: ['ACP requests'], outputs: ['ACP updates'],
      observes: [
        'protocol.ready', 'session.ready', 'turn.started', 'turn.completed', 'turn.failed',
        'model.completed', 'tool.activity', 'output.activity', 'approval.requested', 'approval.resolved',
      ],
      evidence: [{ kind: 'declared', source: 'ACP Registry', version: agent.version }],
    }],
    edges: [],
  }
}

type RegistryDistribution = AcpRegistryAgent['distribution']

/** Prefer a native target, then Node, then Python for this exact host. */
function registryDistribution(distribution: RegistryDistribution, version: string): HarnessPack['distribution'] | undefined {
  const target = registryTarget()
  const binary = distribution.binary?.[target]
  if (binary?.sha256 !== undefined) {
    return {
      kind: 'binary', archive: binary.archive, sha256: binary.sha256,
      command: binary.cmd, args: binary.args ?? [], env: binary.env ?? {},
    }
  }
  const npx = distribution.npx
  if (npx !== undefined && validBareNpmPackage(npx.package) && EXACT_NPM_VERSION.test(version)) {
    return { kind: 'npx', package: pinNpmPackage(npx.package, version), args: npx.args ?? [], env: npx.env ?? {} }
  }
  const uvx = distribution.uvx
  if (uvx !== undefined && validBarePythonPackage(uvx.package) && EXACT_PYTHON_VERSION.test(version)) {
    return { kind: 'uvx', package: pinPythonPackage(uvx.package, version), args: uvx.args ?? [], env: uvx.env ?? {} }
  }
  if (binary !== undefined) {
    return { kind: 'binary', archive: binary.archive, command: binary.cmd, args: binary.args ?? [], env: binary.env ?? {} }
  }
  return undefined
}

function validBareNpmPackage(spec: string): boolean {
  const versionAt = spec.startsWith('@') ? spec.indexOf('@', 1) : spec.lastIndexOf('@')
  const bare = versionAt > 0 ? spec.slice(0, versionAt) : spec
  return bare.length <= 214 && NPM_PACKAGE_NAME.test(bare)
}

function validBarePythonPackage(spec: string): boolean {
  const equals = spec.lastIndexOf('==')
  const at = spec.lastIndexOf('@')
  const separator = equals > 0 ? equals : at
  const bare = separator > 0 ? spec.slice(0, separator) : spec
  return PYTHON_PACKAGE_NAME.test(bare)
}

function registryTarget(): string {
  const platform = process.platform === 'darwin' ? 'darwin' : process.platform === 'win32' ? 'windows' : 'linux'
  const architecture = process.arch === 'arm64' ? 'aarch64' : 'x86_64'
  return `${platform}-${architecture}`
}

/** Pin one Registry npm distribution to the Registry's reviewed version. */
function pinNpmPackage(packageName: string, version: string): string {
  const versionAt = packageName.startsWith('@') ? packageName.indexOf('@', 1) : packageName.lastIndexOf('@')
  const bare = versionAt > 0 ? packageName.slice(0, versionAt) : packageName
  return `${bare}@${version}`
}

function pinPythonPackage(packageName: string, version: string): string {
  const equals = packageName.lastIndexOf('==')
  const at = packageName.lastIndexOf('@')
  const separator = equals > 0 ? equals : at
  const bare = separator > 0 ? packageName.slice(0, separator) : packageName
  return `${bare}==${version}`
}

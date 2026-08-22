/** Harness Pack v0 admission and ACP Registry projection. @module */

import { z } from 'zod'
import { isAbsolute, normalize, win32 } from 'node:path'
import type { HarnessId, HarnessPack } from './types.ts'

const stringRecord = z.record(z.string(), z.string())
const ENVIRONMENT_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/u
const SENSITIVE_ENVIRONMENT_NAME = /(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)$/iu
const distribution = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('npx'), package: z.string().min(1), args: z.array(z.string()).default([]), env: stringRecord.default({}) }),
  z.object({ kind: z.literal('bunx'), package: z.string().min(1), args: z.array(z.string()).default([]), env: stringRecord.default({}) }),
  z.object({ kind: z.literal('uvx'), package: z.string().min(1), args: z.array(z.string()).default([]), env: stringRecord.default({}) }),
  z.object({
    kind: z.literal('binary'), archive: z.url(), sha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(),
    command: z.string().min(1), args: z.array(z.string()).default([]), env: stringRecord.default({}),
  }),
  z.object({ kind: z.literal('executable'), command: z.string().min(1), args: z.array(z.string()).default([]), env: stringRecord.default({}) }),
])
const graphEvidence = z.object({
  kind: z.enum(['declared', 'source-derived', 'runtime-observed']),
  source: z.string().min(1),
  version: z.string().min(1).optional(),
})
const graphNode = z.object({
  id: z.string().min(1),
  kind: z.string().min(1),
  title: z.string().min(1),
  editable: z.boolean(),
  responsibility: z.string().min(1).optional(),
  inputs: z.array(z.string().min(1)).optional(),
  outputs: z.array(z.string().min(1)).optional(),
  evidence: z.array(graphEvidence).min(1).optional(),
  config: z.record(z.string(), z.unknown()).optional(),
})
const graph = z.object({
  level: z.enum(['opaque', 'observable', 'composable']),
  manifestVersion: z.literal(1).optional(),
  boundary: z.string().min(1).optional(),
  evidence: z.array(graphEvidence).min(1).optional(),
  nodes: z.array(graphNode),
  edges: z.array(z.object({ from: z.string().min(1), to: z.string().min(1) })),
})

const packSchema = z.object({
  schemaVersion: z.literal(0),
  id: z.string().regex(/^[a-z0-9][a-z0-9._-]*$/),
  name: z.string().min(1),
  version: z.string().min(1),
  description: z.string().optional(),
  publisher: z.string().min(1),
  license: z.string().optional(),
  repository: z.url().optional(),
  icon: z.url().optional(),
  verified: z.boolean(),
  protocol: z.string().regex(/^[a-z0-9][a-z0-9._-]*$/),
  authMethods: z.array(z.object({
    id: z.string().min(1), name: z.string().min(1), kind: z.enum(['agent', 'environment', 'terminal']),
    fields: z.array(z.object({
      ref: z.string().min(1), name: z.string().min(1), env: z.string().min(1).optional(),
      required: z.boolean().default(true), secret: z.boolean().default(true), placeholder: z.string().optional(),
    })).default([]),
    terminal: z.object({ args: z.array(z.string()), env: z.record(z.string(), z.string()) }).optional(),
  })).optional(),
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
  const pack = packSchema.parse(input) as HarnessPack
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
  for (const edge of pack.graph.edges) {
    if (!nodes.has(edge.from) || !nodes.has(edge.to)) {
      throw new Error(`Harness Pack "${pack.id}" graph edge references an unknown node`)
    }
  }
  if (pack.graph.level !== 'composable' && pack.graph.nodes.some(node => node.editable)) {
    throw new Error(`Harness Pack "${pack.id}" may expose editable nodes only at graph level "composable"`)
  }
  if (pack.graph.level === 'opaque' && pack.graph.nodes.length !== 1) {
    throw new Error(`Harness Pack "${pack.id}" opaque graph must expose exactly one runtime boundary node`)
  }
  if (pack.graph.level !== 'opaque') {
    if (pack.graph.nodes.length < 3 || pack.graph.edges.length < 2) {
      throw new Error(`Harness Pack "${pack.id}" ${pack.graph.level} graph must explain at least three connected components`)
    }
    if (pack.graph.boundary === undefined || pack.graph.evidence === undefined) {
      throw new Error(`Harness Pack "${pack.id}" ${pack.graph.level} graph requires a boundary and graph evidence`)
    }
    const unsupported = pack.graph.nodes.find(node => node.responsibility === undefined || node.evidence === undefined)
    if (unsupported !== undefined) {
      throw new Error(`Harness Pack "${pack.id}" architecture node "${unsupported.id}" requires responsibility and evidence`)
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
    if (distribution.kind === 'uvx' && !/(?:==|@)[0-9]/u.test(distribution.package)) {
      throw new Error(`Harness Pack "${pack.id}" must pin its Python package to an exact version`)
    }
  }
  if (pack.distribution?.kind === 'binary') {
    const command = pack.distribution.command.replaceAll('\\', '/')
    if (isAbsolute(command) || win32.isAbsolute(pack.distribution.command) || normalize(command).startsWith('..')) {
      throw new Error(`Harness Pack "${pack.id}" binary command must stay inside its installation directory`)
    }
  }
  if (pack.source === 'openfish-community' && pack.distribution?.kind === 'executable') {
    throw new Error(`Harness Pack "${pack.id}" community publication requires a portable package or checksummed binary distribution`)
  }
  if (pack.source === 'openfish-community' && pack.distribution?.kind === 'binary' && pack.distribution.sha256 === undefined) {
    throw new Error(`Harness Pack "${pack.id}" community binary publication requires a SHA-256 checksum`)
  }
  if (pack.source === 'openfish-community') {
    const publicEnvironments = [pack.distribution?.env, ...authMethods.map(method => method.terminal?.env)]
    for (const environment of publicEnvironments) {
      const leaked = Object.entries(environment ?? {}).find(([name, value]) => SENSITIVE_ENVIRONMENT_NAME.test(name) && value !== '')
      if (leaked !== undefined) {
        throw new Error(`Harness Pack "${pack.id}" community publication cannot contain a value for potential secret "${leaked[0]}"`)
      }
    }
  }
  return pack
}

const openFishCommunitySchema = z.object({
  version: z.literal(0),
  packs: z.array(z.unknown()),
})

/**
 * Parse the OpenFish community catalog and mark every entry as unverified data.
 * @param input - Untrusted generated community catalog document.
 * @returns Validated, credential-free community Packs.
 */
export function packsFromOpenFishCommunity(input: unknown): HarnessPack[] {
  const catalog = openFishCommunitySchema.parse(input)
  return catalog.packs.map((candidate) => {
    if (typeof candidate !== 'object' || candidate === null || Array.isArray(candidate)) {
      throw new Error('OpenFish community catalog entries must be objects')
    }
    return parseHarnessPack({ ...candidate, verified: false, source: 'openfish-community' })
  })
}

function isPinnedNpmPackage(spec: string): boolean {
  const versionAt = spec.startsWith('@') ? spec.indexOf('@', 1) : spec.lastIndexOf('@')
  return versionAt > 0 && /^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/u.test(spec.slice(versionAt + 1))
}

const acpRegistrySchema = z.object({
  version: z.string(),
  agents: z.array(z.object({
    id: z.string().min(1),
    name: z.string().min(1),
    version: z.string().min(1),
    description: z.string().optional(),
    repository: z.url().optional(),
    authors: z.array(z.string()).optional(),
    license: z.string().optional(),
    icon: z.url().optional(),
    distribution: z.object({
      npx: z.object({
        package: z.string().min(1),
        args: z.array(z.string()).optional(),
        env: stringRecord.optional(),
      }).optional(),
      uvx: z.object({
        package: z.string().min(1),
        args: z.array(z.string()).optional(),
        env: stringRecord.optional(),
      }).optional(),
      binary: z.record(z.string(), z.object({
        archive: z.url(), sha256: z.string().regex(/^[a-fA-F0-9]{64}$/).optional(), cmd: z.string().min(1),
        args: z.array(z.string()).optional(), env: stringRecord.optional(),
      })).optional(),
    }).loose(),
  }).loose()),
})

/**
 * Project supported ACP Registry package or platform distributions into Pack v0.
 * @param input - Untrusted ACP Registry document.
 * @returns Runnable Pack rows for this host; unsupported distributions are omitted.
 */
export function packsFromAcpRegistry(input: unknown): HarnessPack[] {
  const registry = acpRegistrySchema.parse(input)
  return registry.agents.flatMap((agent): HarnessPack[] => {
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
      verified: true,
      protocol: 'acp',
      ...(agent.id === 'codex-acp' ? { authMethods: [
        { id: 'chat-gpt', name: 'ChatGPT', kind: 'agent', fields: [] },
        { id: 'api-key', name: 'OpenAI API key', kind: 'agent', fields: [
          { ref: 'OPENAI_API_KEY', name: 'OpenAI API key', env: 'OPENAI_API_KEY', required: true, secret: true },
        ] },
      ] } : {}),
      distribution: selected,
      graph: registryArchitecture(agent),
      source: 'acp-registry',
    })]
  })
}

function registryArchitecture(agent: z.infer<typeof acpRegistrySchema>['agents'][number]): HarnessPack['graph'] {
  if (agent.id !== 'codex-acp') {
    return {
      level: 'opaque',
      manifestVersion: 1,
      boundary: `${agent.name} process`,
      evidence: [{ kind: 'declared', source: 'ACP Registry', version: agent.version }],
      nodes: [{
        id: 'runtime', kind: 'harness-runtime', title: agent.name, editable: false,
        responsibility: 'Runs the ACP agent while its private internal architecture remains undisclosed.',
        inputs: ['ACP requests'], outputs: ['ACP updates'],
        evidence: [{ kind: 'declared', source: 'ACP Registry', version: agent.version }],
      }],
      edges: [],
    }
  }
  const codexEvidence = { kind: 'source-derived' as const, source: 'https://github.com/openai/codex', version: agent.version }
  return {
    level: 'observable',
    manifestVersion: 1,
    boundary: 'Codex ACP agent process',
    evidence: [codexEvidence, { kind: 'declared', source: 'ACP Registry codex-acp', version: agent.version }],
    nodes: [
      {
        id: 'acp', kind: 'protocol-adapter', title: 'ACP interface', editable: false,
        responsibility: 'Translates ACP session calls, updates, configuration, and permissions for Codex.',
        inputs: ['ACP initialize', 'session prompt', 'client capabilities'], outputs: ['session updates', 'permission requests'],
        evidence: [{ kind: 'declared', source: 'ACP Registry codex-acp', version: agent.version }],
      },
      {
        id: 'session', kind: 'agent-session', title: 'Thread & turn runtime', editable: false,
        responsibility: 'Owns the thread, current turn, cancellation, and streamed item lifecycle.',
        inputs: ['prompt', 'thread options'], outputs: ['turn items', 'terminal state'], evidence: [codexEvidence],
      },
      {
        id: 'context', kind: 'context-runtime', title: 'Context assembly', editable: false,
        responsibility: 'Builds model input from instructions, conversation history, skills, and environment context.',
        inputs: ['instructions', 'history', 'environment'], outputs: ['model input'], evidence: [codexEvidence],
      },
      {
        id: 'model', kind: 'model-client', title: 'Model client', editable: false,
        responsibility: 'Streams inference through the selected Codex account, provider, model, and reasoning level.',
        inputs: ['model input', 'model configuration'], outputs: ['assistant and tool-call stream'], evidence: [codexEvidence],
      },
      {
        id: 'tools', kind: 'tool-runtime', title: 'Tool runtime', editable: false,
        responsibility: 'Dispatches shell, file, MCP, skill, browser, and other enabled tool operations.',
        inputs: ['tool call', 'active capabilities'], outputs: ['tool result', 'workspace change'], evidence: [codexEvidence],
      },
      {
        id: 'sandbox', kind: 'execution-boundary', title: 'Sandbox', editable: false,
        responsibility: 'Constrains filesystem and network effects according to the active sandbox policy.',
        inputs: ['command', 'sandbox policy'], outputs: ['bounded process effect'], evidence: [codexEvidence],
      },
      {
        id: 'approvals', kind: 'permission-policy', title: 'Approvals', editable: false,
        responsibility: 'Requests a user or reviewer decision when an operation crosses its permitted boundary.',
        inputs: ['planned effect', 'approval policy'], outputs: ['approval decision'], evidence: [codexEvidence],
      },
      {
        id: 'persistence', kind: 'session-storage', title: 'Session persistence', editable: false,
        responsibility: 'Retains thread identity and resumable conversation state owned by Codex.',
        inputs: ['thread events'], outputs: ['resumable thread'], evidence: [codexEvidence],
      },
    ],
    edges: [
      { from: 'acp', to: 'session' }, { from: 'session', to: 'context' }, { from: 'context', to: 'model' },
      { from: 'model', to: 'session' }, { from: 'session', to: 'tools' }, { from: 'tools', to: 'approvals' },
      { from: 'approvals', to: 'sandbox' }, { from: 'sandbox', to: 'tools' }, { from: 'session', to: 'persistence' },
      { from: 'session', to: 'acp' },
    ],
  }
}

type RegistryDistribution = z.infer<typeof acpRegistrySchema>['agents'][number]['distribution']

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
  if (npx !== undefined) return { kind: 'npx', package: pinNpmPackage(npx.package, version), args: npx.args ?? [], env: npx.env ?? {} }
  const uvx = distribution.uvx
  if (uvx !== undefined) return { kind: 'uvx', package: pinPythonPackage(uvx.package, version), args: uvx.args ?? [], env: uvx.env ?? {} }
  if (binary !== undefined) {
    return { kind: 'binary', archive: binary.archive, command: binary.cmd, args: binary.args ?? [], env: binary.env ?? {} }
  }
  return undefined
}

function registryTarget(): string {
  const platform = process.platform === 'darwin' ? 'darwin' : process.platform === 'win32' ? 'windows' : 'linux'
  const architecture = process.arch === 'arm64' ? 'aarch64' : 'x86_64'
  return `${platform}-${architecture}`
}

/** Pin one Registry npm distribution to the Registry's reviewed version. */
function pinNpmPackage(packageName: string, version: string): string {
  return packageName.lastIndexOf('@') > 0 ? packageName : `${packageName}@${version}`
}

function pinPythonPackage(packageName: string, version: string): string {
  return /(?:==|@)/u.test(packageName) ? packageName : `${packageName}==${version}`
}

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
const graphNode = z.object({
  id: z.string().min(1),
  kind: z.string().min(1),
  title: z.string().min(1),
  editable: z.boolean(),
  config: z.record(z.string(), z.unknown()).optional(),
})
const graph = z.object({
  level: z.enum(['opaque', 'observable', 'composable']),
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
      graph: {
        level: 'opaque',
        nodes: [{ id: 'runtime', kind: 'harness-runtime', title: agent.name, editable: false }],
        edges: [],
      },
      source: 'acp-registry',
    })]
  })
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

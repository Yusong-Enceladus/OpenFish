/** Harness Pack catalog and protocol-driver registry for Open Fish. @module */

import { Context, Service } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import { randomUUID } from 'node:crypto'
import { chmod, lstat, mkdir, readFile, rename, rm, unlink, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'
import { SessionId, type SessionEvent } from '@deepseek-ai/dsh-session'
import type { Agent } from '@deepseek-ai/dsh-agent'
import type {} from '@deepseek-ai/dsh-session-persistence'
import type {} from '@deepseek-ai/dsh-user-approval'
import { openFishCommunityCatalog, packsFromAcpRegistry, parseHarnessPack, prepareHarnessPublication, type OpenFishCommunityRevocation } from './manifest.ts'
import { harnessRuntimeProjectionDefinition } from './projection.ts'
import { inspectHarnessDriver, negotiateHarnessDriverApi } from './conformance.ts'
import { safeHarnessDiagnostic } from './diagnostic.ts'
import { observeHarnessRuntime } from './runtime.ts'
import type {
  HarnessAuthMethod,
  HarnessAuthoringContract,
  HarnessCapability,
  HarnessCatalogEntry,
  HarnessCommunitySubmissionRecord,
  HarnessPublication,
  HarnessCompatibility,
  HarnessDriver,
  HarnessForkRequest,
  HarnessId,
  HarnessInstallation,
  HarnessPack,
  HarnessPreflightResult,
  HarnessSessionRequest,
} from './types.ts'

export * from './manifest.ts'
export * from './projection.ts'
export * from './conformance.ts'
export * from './diagnostic.ts'
export * from './runtime.ts'
export type * from './projection.types.ts'
export type * from './types.ts'

/**
 * Preserve a concrete Driver's inferred type while checking the public Driver contract.
 * @param driver - Concrete Driver implementation to validate and preserve.
 * @returns The same Driver with its concrete inferred type.
 */
export function defineHarnessDriver<T extends HarnessDriver>(driver: T): T { return driver }

/** Exact built-in DSH Harness package version pinned into every new task. */
export const BUILTIN_DSH_VERSION = (createRequire(import.meta.url)('../package.json') as { version: string }).version

/**
 * Register a public Driver for exactly the lifetime of its Cordis plugin.
 * The owning plugin must declare `export const inject = ['harnesses']` so the
 * registry exists before this helper runs.
 * @param ctx - Cordis plugin context that owns the registration effect.
 * @param driver - Public protocol Driver to register.
 */
export function registerHarnessDriver(ctx: Context, driver: HarnessDriver): void {
  ctx.effect(() => ctx.harnesses.registerDriver(driver), 'harness-driver')
}

declare module '@deepseek-ai/cordis' {
  interface Context { harnesses: HarnessService }
}

declare module '@deepseek-ai/dsh-session/types' {
  interface SessionEventMap {
    /** Selected runtime identity and its remote session, committed before the first turn. */
    'harness/selected': {
      harnessId: HarnessId
      version: string
      protocol: string
      /** Exact non-secret authentication choice used to create this task. */
      authMethod?: string
      /** Exact location contract fixed before the first turn. */
      workspaceMode?: 'project' | 'no-project' | 'custom-cwd'
      /** Exact Driver/Pack capability contract visible when the task was created. */
      capabilities?: import('./types.ts').HarnessCapability[]
      remoteSessionId?: string
    }
    /** Replacement remote identity for the same pinned Harness after recoverable blank-session loss. */
    'harness/remote-session': {
      harnessId: HarnessId
      remoteSessionId: string
      reason: 'blank-session-recovery' | 'session-fork'
    }
    /** Lossless provider event retained when no common Open Fish presentation exists. */
    'harness/native-event': { harnessId: HarnessId; event: unknown }
    /** Runtime evidence that a declared architecture component participated in this session. */
    'harness/runtime-node': {
      harnessId: HarnessId
      nodeId: string
      /** Absent only on runtime facts written by pre-binding OpenFish builds. */
      signal?: import('./types.ts').HarnessRuntimeSignal
      status: 'active' | 'waiting' | 'completed' | 'failed'
      activity: string
    }
    /** Runtime evidence that one declared data-flow connection participated in this session. */
    'harness/runtime-edge': {
      harnessId: HarnessId
      edgeKey: string
      from: string
      to: string
      fromPort?: string
      toPort?: string
      signal: import('./types.ts').HarnessRuntimeSignal
      status: 'active' | 'waiting' | 'completed' | 'failed'
      activity: string
    }
  }
}

/** Harness catalog configuration. */
export interface HarnessConfig {
  /** ACP Registry JSON endpoint refreshed at startup and on user request. */
  registryUrl?: string
  /** OpenFish community Pack catalog refreshed independently from the ACP Registry. */
  communityRegistryUrl?: string
  /** Untrusted Pack v0 documents admitted before Registry rows are merged. */
  packs?: unknown[]
  /** Managed Harness state root; defaults beneath `$DSH_HOME`. */
  stateDir?: string
}

/** Statically walkable Harness catalog configuration schema. */
export const Config: Schema<HarnessConfig> = Schema.object({
  registryUrl: Schema.string().default('https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json'),
  communityRegistryUrl: Schema.string().default('https://raw.githubusercontent.com/Yusong-Enceladus/OpenFish/main/community/harnesses/index.json'),
  packs: Schema.array(Schema.any()).default([]),
  stateDir: Schema.string(),
})

const HOST_ARCHIVE_CAPABILITY: HarnessCapability = {
  id: 'session.archive',
  status: 'supported',
  source: 'host',
  detail: 'OpenFish archives the task without deleting its Harness session or durable transcript.',
}

function abortSignalIsAborted(signal: AbortSignal): boolean {
  return signal.aborted
}

/** Convert an untrusted Driver availability probe into one client-safe result. */
async function inspectDriverAvailability(driver: HarnessDriver, pack: HarnessPack): Promise<string | undefined> {
  try {
    const result: unknown = await driver.available(pack)
    if (result === undefined) return undefined
    if (typeof result !== 'string' || result.trim() === '') {
      return 'Harness Driver returned an invalid availability result.'
    }
    return safeHarnessDiagnostic(result, 'Harness launch prerequisites are unavailable')
  } catch (error: unknown) {
    return safeHarnessDiagnostic(error, 'Harness availability check failed')
  }
}

/** Admit one untrusted Driver without allowing its diagnostics to escape the Host boundary. */
async function requireConformantDriver(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessCapability[]> {
  let inspection
  try {
    inspection = await inspectHarnessDriver(driver, pack)
  } catch (error: unknown) {
    throw new Error(safeHarnessDiagnostic(error, 'Harness Driver inspection failed'))
  }
  if (!inspection.compatible) {
    throw new Error(safeHarnessDiagnostic(
      `Harness Driver conformance failed: ${inspection.issues.join(' ')}`,
      'Harness Driver conformance failed',
    ))
  }
  return inspection.capabilities
}

/** Remove one Host-owned Harness directory without following a replaced link. */
async function removeManagedHarnessDirectory(directory: string): Promise<void> {
  try {
    const information = await lstat(directory)
    if (information.isSymbolicLink()) {
      await unlink(directory)
      return
    }
    await rm(directory, { recursive: true, force: true })
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
}

/** Diagnose an exact managed directory without following a replaced link. */
async function managedDirectoryIssue(directory: string, label: string): Promise<string | undefined> {
  try {
    const information = await lstat(directory)
    if (information.isSymbolicLink()) return `${label} was replaced by a symbolic link`
    if (!information.isDirectory()) return `${label} is not a directory`
    return undefined
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return `${label} is missing`
    throw error
  }
}

async function requireManagedDirectory(directory: string, label: string): Promise<void> {
  const issue = await managedDirectoryIssue(directory, label)
  if (issue !== undefined) throw new Error(issue)
}

/** Create one private Host-owned directory, then validate the final path. */
async function ensureManagedDirectory(directory: string, label: string): Promise<void> {
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await requireManagedDirectory(directory, label)
  await chmod(directory, 0o700)
}

/** Add shell-owned lifecycle facts independently of any protocol Driver. */
function withHostCapabilities(driverCapabilities: readonly HarnessCapability[]): HarnessCapability[] {
  const capabilities = driverCapabilities
    .filter(capability => capability.id !== HOST_ARCHIVE_CAPABILITY.id)
    .map(capability => ({ ...capability }))
  const workspaceIndex = capabilities.findIndex(capability => capability.id.startsWith('workspace.'))
  capabilities.splice(workspaceIndex === -1 ? capabilities.length : workspaceIndex, 0, { ...HOST_ARCHIVE_CAPABILITY })
  return capabilities
}

/** Add authoring workflow facts owned by the OpenFish Host, not a protocol Driver. */
function withUserBuilderCapabilities(
  pack: HarnessPack,
  capabilities: readonly HarnessCapability[],
  livePreflightAvailable: boolean,
): HarnessCapability[] {
  if (pack.source !== 'user') return capabilities.map(capability => ({ ...capability }))
  const byId = new Map(capabilities.map(capability => [capability.id, { ...capability }]))
  byId.set('builder.manifest', {
    id: 'builder.manifest', status: 'supported', source: 'host',
    detail: 'The OpenFish Manifest Editor can create, edit, import, export, and validate this local Pack without Harness-specific native UI.',
  })
  byId.set('builder.test', livePreflightAvailable
    ? {
      id: 'builder.test', status: 'supported', source: 'driver',
      detail: 'The loaded Driver owns a live, non-prompting preflight for this exact Pack version.',
    }
    : {
      id: 'builder.test', status: 'unsupported', source: 'host',
      detail: 'Load a compatible Driver with live preflight support before this Pack can be tested or submitted.',
    })
  byId.set('builder.publish', {
    id: 'builder.publish', status: 'supported', source: 'host',
    detail: 'OpenFish performs credential-free admission, submits a real GitHub review, tracks its status, and supports reviewed exact-version updates and revocation requests.',
  })
  return [...byId.values()]
}

interface StoredInstall {
  active?: HarnessPack
  previous: HarnessPack[]
  authMethod?: string
  /** Exact Pack versions whose installed Driver completed authentication discovery. */
  authDiscoveries?: Record<string, string>
  compatibility?: { status: 'ready' | 'compatible' | 'failed'; checkedAt: string; message?: string }
}

type StoredCommunitySubmission = HarnessCommunitySubmissionRecord

/**
 * Host-local proof that the Mac app admitted one exact Driver Bundle and then
 * observed its protocol Driver in the restarted Host. The active proof is
 * protocol-scoped: a later Driver update replaces it, so an older Pack cannot
 * silently run against different code merely because both use the same
 * protocol id.
 */
interface StoredDriverAuthorization {
  package: string
  spec: string
  authorizedAt: string
}

interface StoredHarnessState {
  version: 7
  defaultHarnessId?: string
  customPacks: HarnessPack[]
  registryPacks: HarnessPack[]
  communityPacks: HarnessPack[]
  communityRevocations: OpenFishCommunityRevocation[]
  communitySubmissions: StoredCommunitySubmission[]
  communityRevocationSubmissions: StoredCommunitySubmission[]
  driverAuthorizations: Record<string, StoredDriverAuthorization>
  installs: Record<string, StoredInstall>
}

interface StoredHarnessStateCandidate {
  version: 1 | 2 | 3 | 4 | 5 | 6 | 7
  defaultHarnessId?: string
  customPacks: HarnessPack[]
  registryPacks?: HarnessPack[]
  communityPacks?: HarnessPack[]
  communityRevocations?: OpenFishCommunityRevocation[]
  communitySubmissions?: unknown[]
  communityRevocationSubmissions?: unknown[]
  driverAuthorizations?: unknown
  installs: Record<string, StoredInstall>
}

const EMPTY_STATE: StoredHarnessState = {
  version: 7,
  customPacks: [],
  registryPacks: [],
  communityPacks: [],
  communityRevocations: [],
  communitySubmissions: [],
  communityRevocationSubmissions: [],
  driverAuthorizations: {},
  installs: {},
}

function storedAuthenticationDiscoveries(input: unknown): Record<string, string> {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return {}
  return Object.fromEntries(Object.entries(input).filter(([version, completedAt]) =>
    /^[0-9A-Za-z][0-9A-Za-z._+-]*$/u.test(version)
      && typeof completedAt === 'string'
      && !Number.isNaN(Date.parse(completedAt))))
}

function storedDriverAuthorizations(input: unknown): Record<string, StoredDriverAuthorization> {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return {}
  return Object.fromEntries(Object.entries(input).flatMap(([protocol, raw]) => {
    if (!/^[a-z0-9][a-z0-9._-]*$/u.test(protocol)
      || typeof raw !== 'object' || raw === null || Array.isArray(raw)) return []
    const candidate = raw as Record<string, unknown>
    if (typeof candidate.package !== 'string' || candidate.package.length === 0
      || typeof candidate.spec !== 'string' || candidate.spec.length === 0
      || typeof candidate.authorizedAt !== 'string' || Number.isNaN(Date.parse(candidate.authorizedAt))) return []
    return [[protocol, {
      package: candidate.package,
      spec: candidate.spec,
      authorizedAt: candidate.authorizedAt,
    } satisfies StoredDriverAuthorization]]
  }))
}

function storedCommunitySubmission(input: unknown): StoredCommunitySubmission | undefined {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) return undefined
  const candidate = input as Record<string, unknown>
  if (typeof candidate.id !== 'string' || !/^[a-z0-9][a-z0-9._-]*$/u.test(candidate.id)) return undefined
  if (typeof candidate.version !== 'string' || candidate.version === '') return undefined
  if (typeof candidate.reviewUrl !== 'string' || typeof candidate.branch !== 'string' || candidate.branch === '') return undefined
  if (!/^https:\/\/github\.com\/Yusong-Enceladus\/OpenFish\/pull\/[1-9][0-9]*$/u.test(candidate.reviewUrl)) return undefined
  if (typeof candidate.submittedAt !== 'string' || Number.isNaN(Date.parse(candidate.submittedAt))) return undefined
  if (!['pending', 'changes-requested', 'closed', 'merged'].includes(String(candidate.review))) return undefined
  return {
    id: candidate.id as HarnessId,
    version: candidate.version,
    reviewUrl: candidate.reviewUrl,
    branch: candidate.branch,
    submittedAt: candidate.submittedAt,
    review: candidate.review as StoredCommunitySubmission['review'],
  }
}

async function boundedJsonResponse(response: Response, maximumBytes: number, label: string): Promise<unknown> {
  const declared = response.headers.get('content-length')
  if (declared !== null && (!/^[0-9]+$/u.test(declared) || Number(declared) > maximumBytes)) {
    throw new Error(`${label} exceeds the ${maximumBytes}-byte response limit`)
  }
  if (response.body === null) throw new Error(`${label} returned no response body`)
  const reader = response.body.getReader()
  const chunks: Uint8Array[] = []
  let total = 0
  try {
    while (true) {
      const next = await reader.read()
      if (next.done) break
      total += next.value.byteLength
      if (total > maximumBytes) {
        await reader.cancel(`${label} response exceeded its size limit`).catch(() => undefined)
        throw new Error(`${label} exceeds the ${maximumBytes}-byte response limit`)
      }
      chunks.push(next.value)
    }
  } finally {
    reader.releaseLock()
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  let text: string
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes)
  } catch (error: unknown) {
    throw new Error(`${label} is not valid UTF-8`, { cause: error })
  }
  try {
    return JSON.parse(text) as unknown
  } catch (error: unknown) {
    throw new Error(`${label} is not valid JSON`, { cause: error })
  }
}

async function refreshedCommunitySubmission(
  submission: StoredCommunitySubmission,
  signal?: AbortSignal,
): Promise<StoredCommunitySubmission> {
  const match = /^https:\/\/github\.com\/Yusong-Enceladus\/OpenFish\/pull\/([1-9][0-9]*)$/u.exec(submission.reviewUrl)
  if (match?.[1] === undefined) return submission
  const response = await fetch(`https://api.github.com/repos/Yusong-Enceladus/OpenFish/pulls/${match[1]}`, {
    headers: {
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'OpenFish-Harness-Catalog',
    },
    ...(signal === undefined ? {} : { signal }),
  }).catch(() => undefined)
  if (response?.ok !== true) return submission
  const pull = await response.json() as { state?: unknown; merged_at?: unknown }
  let changesRequested = false
  if (typeof pull.merged_at !== 'string' && pull.state !== 'closed') {
    const reviewsResponse = await fetch(
      `https://api.github.com/repos/Yusong-Enceladus/OpenFish/pulls/${match[1]}/reviews?per_page=100`,
      {
        headers: {
          Accept: 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'OpenFish-Harness-Catalog',
        },
        ...(signal === undefined ? {} : { signal }),
      },
    ).catch(() => undefined)
    if (reviewsResponse?.ok === true) {
      const reviews = await reviewsResponse.json() as Array<{
        user?: { login?: unknown }
        state?: unknown
        submitted_at?: unknown
      }>
      const latestByReviewer = new Map<string, { state: string; submittedAt: number }>()
      for (const review of Array.isArray(reviews) ? reviews : []) {
        if (typeof review.user?.login !== 'string' || typeof review.state !== 'string') continue
        const submittedAt = typeof review.submitted_at === 'string' ? Date.parse(review.submitted_at) : Number.NaN
        const sortableTime = Number.isNaN(submittedAt) ? 0 : submittedAt
        const previous = latestByReviewer.get(review.user.login)
        if (previous === undefined || sortableTime >= previous.submittedAt) {
          latestByReviewer.set(review.user.login, { state: review.state, submittedAt: sortableTime })
        }
      }
      changesRequested = [...latestByReviewer.values()].some(review => review.state === 'CHANGES_REQUESTED')
    }
  }
  const review = typeof pull.merged_at === 'string'
    ? 'merged' as const
    : pull.state === 'closed'
      ? 'closed' as const
      : changesRequested
        ? 'changes-requested' as const
        : 'pending' as const
  return { ...submission, review }
}

/**
 * Admit a persisted Pack written by an older Open Fish runtime. Some early ACP
 * discovery snapshots omitted the newly-required `fields` array. Prefer the
 * current catalog definition for the same auth method (important for API-key
 * fields), then fall back to an empty form for protocol-owned login methods.
 */
function parseStoredHarnessPack(input: unknown, fallback?: HarnessPack): HarnessPack {
  if (typeof input !== 'object' || input === null) return parseHarnessPack(input)
  const inputRecord = input as Record<string, unknown>
  const record = migrateStoredArchitecture(inputRecord)
  const rawMethods = record.authMethods
  let methods: unknown = rawMethods
  if (Array.isArray(rawMethods)) {
    const storedMethods = (rawMethods as unknown[]).map((candidate) => {
      if (typeof candidate !== 'object' || candidate === null) return candidate
      const method = candidate as Record<string, unknown>
      const id = typeof method.id === 'string' ? method.id : undefined
      const fallbackMethod = fallback?.authMethods?.find(item => item.id === id)
      const storedFields = Array.isArray(method.fields) ? method.fields : fallbackMethod?.fields ?? []
      const fields = storedFields.some(field => typeof field === 'object' && field !== null
        && (field as Record<string, unknown>).ref === 'CODEX_API_KEY')
        && fallbackMethod?.fields.some(field => field.ref === 'OPENAI_API_KEY') === true
        ? fallbackMethod.fields
        : storedFields
      return {
        ...method,
        fields,
        ...(method.account === undefined && fallbackMethod?.account !== undefined ? { account: fallbackMethod.account } : {}),
      }
    })
    methods = [
      ...storedMethods,
      ...(fallback?.authMethods ?? []).filter(fallbackMethod => !storedMethods.some(candidate =>
        typeof candidate === 'object' && candidate !== null
          && (candidate as Record<string, unknown>).id === fallbackMethod.id)),
    ]
  }
  return parseHarnessPack({
    ...record,
    ...(record.account === undefined && fallback?.account !== undefined ? { account: fallback.account } : {}),
    ...(record.modelConfiguration === undefined && fallback?.modelConfiguration !== undefined
      ? { modelConfiguration: fallback.modelConfiguration }
      : {}),
    ...(record.authenticationDiscovery === undefined && fallback?.authenticationDiscovery !== undefined
      ? { authenticationDiscovery: fallback.authenticationDiscovery }
      : {}),
    ...(methods === undefined ? {} : { authMethods: methods }),
  })
}

function mergeDiscoveredAuthentication(
  declared: readonly HarnessAuthMethod[] | undefined,
  discovered: readonly HarnessAuthMethod[],
): HarnessAuthMethod[] {
  const merged = discovered.map((method) => {
    const fallback = declared?.find(candidate => candidate.id === method.id)
    return {
      ...fallback,
      ...method,
      fields: method.fields,
      ...(method.account === undefined && fallback?.account !== undefined ? { account: fallback.account } : {}),
    }
  })
  // Discovery supplements the Pack contract; it must not erase a curated
  // terminal flow merely because ACP initialize advertises only protocol-level
  // methods (or none). This lets a future Harness combine live env-var methods
  // with one Pack-declared provider/account setup without native UI branches.
  return [
    ...merged,
    ...(declared ?? []).filter(method => !discovered.some(candidate => candidate.id === method.id)),
  ]
}

/** Admit Driver-discovered authentication through the same Pack schema as public manifests. */
function withDiscoveredAuthentication(pack: HarnessPack, value: unknown): HarnessPack {
  if (!Array.isArray(value)) throw new Error('Harness Driver authentication discovery result must be an array')
  const discoveredPack = parseHarnessPack({ ...pack, authMethods: value })
  return parseHarnessPack({
    ...pack,
    authMethods: mergeDiscoveredAuthentication(pack.authMethods, discoveredPack.authMethods ?? []),
  })
}

/** Keep preflight reports content-free, bounded, and safe to persist or project. */
function normalizeHarnessPreflightResult(value: unknown): HarnessPreflightResult | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new Error('Harness Driver preflight result must be an object')
  }
  const candidate = value as Record<string, unknown>
  if (typeof candidate.message !== 'string' || candidate.message.trim() === '') {
    throw new Error('Harness Driver preflight result requires a non-empty message')
  }
  if (candidate.modelCount !== undefined
    && (!Number.isSafeInteger(candidate.modelCount) || Number(candidate.modelCount) < 0)) {
    throw new Error('Harness Driver preflight model count must be a non-negative integer')
  }
  let configurationIds: string[] | undefined
  if (candidate.configurationIds !== undefined) {
    if (!Array.isArray(candidate.configurationIds)
      || candidate.configurationIds.some(id => typeof id !== 'string'
        || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/u.test(id))) {
      throw new Error('Harness Driver preflight configuration ids are invalid')
    }
    configurationIds = [...new Set(candidate.configurationIds as string[])]
  }
  return {
    message: safeHarnessDiagnostic(candidate.message, 'Harness live preflight passed'),
    ...(candidate.modelCount === undefined ? {} : { modelCount: Number(candidate.modelCount) }),
    ...(configurationIds === undefined ? {} : { configurationIds }),
  }
}

/** Carry newly introduced non-executable auth discovery metadata onto an exact installed snapshot. */
function withCurrentAuthenticationContract(catalog: HarnessPack, snapshot: HarnessPack): HarnessPack {
  if (catalog.id !== snapshot.id || catalog.version !== snapshot.version
    || snapshot.authenticationDiscovery !== undefined
    || catalog.authenticationDiscovery === undefined) return snapshot
  return { ...snapshot, authenticationDiscovery: catalog.authenticationDiscovery }
}

/** Downgrade legacy decorative graphs instead of preserving an unsupported observable claim. */
function migrateStoredArchitecture(record: Record<string, unknown>): Record<string, unknown> {
  const graph = record.graph
  if (typeof graph !== 'object' || graph === null || Array.isArray(graph)) return record
  const candidate = graph as Record<string, unknown>
  const nodes = Array.isArray(candidate.nodes) ? candidate.nodes : []
  const edges = Array.isArray(candidate.edges) ? candidate.edges : []
  if (candidate.level === 'opaque' && nodes.length === 1) return record
  const nodeRecords = nodes.filter((node): node is Record<string, unknown> => typeof node === 'object' && node !== null)
  const nodeIds = nodeRecords.map(node => node.id).filter((id): id is string => typeof id === 'string')
  const uniqueNodeIds = new Set(nodeIds)
  const adjacent = new Map(nodeIds.map(id => [id, new Set<string>()]))
  let validEdges = true
  for (const edge of edges) {
    if (typeof edge !== 'object' || edge === null) {
      validEdges = false
      continue
    }
    const from = (edge as Record<string, unknown>).from
    const to = (edge as Record<string, unknown>).to
    if (typeof from !== 'string' || typeof to !== 'string'
      || !uniqueNodeIds.has(from) || !uniqueNodeIds.has(to)) {
      validEdges = false
      continue
    }
    adjacent.get(from)?.add(to)
    adjacent.get(to)?.add(from)
  }
  const visited = new Set<string>()
  const pending = nodeIds[0] === undefined ? [] : [nodeIds[0]]
  while (pending.length > 0) {
    const id = pending.pop()
    if (id === undefined || visited.has(id)) continue
    visited.add(id)
    pending.push(...(adjacent.get(id) ?? []))
  }
  const supported = candidate.level !== 'opaque' && nodes.length > 0
    && nodeRecords.length === nodes.length && nodeIds.length === nodes.length
    && uniqueNodeIds.size === nodes.length && validEdges && visited.size === nodes.length
    && typeof candidate.boundary === 'string' && Array.isArray(candidate.evidence)
    && nodeRecords.every(node => typeof node.responsibility === 'string'
      && Array.isArray(node.evidence))
  if (supported) return record
  const first = nodes.find(node => typeof node === 'object' && node !== null) as Record<string, unknown> | undefined
  const title = typeof first?.title === 'string' ? first.title : typeof record.name === 'string' ? record.name : 'Harness runtime'
  return {
    ...record,
    graph: {
      level: 'opaque', manifestVersion: 1, boundary: `${title} process`,
      evidence: [{ kind: 'declared', source: 'Legacy Pack boundary' }],
      nodes: [{
        id: 'runtime', kind: 'harness-runtime', title, editable: false,
        responsibility: 'Runs the Harness while its internal architecture remains undisclosed.',
        inputs: ['protocol requests'], outputs: ['protocol updates'],
        observes: [
          'protocol.ready', 'session.ready', 'turn.started', 'turn.completed', 'turn.failed',
          'model.completed', 'tool.activity', 'output.activity', 'approval.requested', 'approval.resolved',
        ],
        evidence: [{ kind: 'declared', source: 'Legacy Pack boundary' }],
      }],
      edges: [],
    },
  }
}

const BUILTIN_DSH = parseHarnessPack({
  schemaVersion: 0,
  id: 'dsh',
  name: 'DeepSeek Harness',
  version: BUILTIN_DSH_VERSION,
  description: 'Open Fish native DSH runtime.',
  publisher: 'DeepSeek',
  verified: true,
  protocol: 'dsh',
  account: {
    label: 'Model account selected for the DSH Harness', billing: 'unknown',
    detail: 'The selected DSH model route determines the provider account and billing boundary.',
  },
  modelConfiguration: {
    owner: 'host', required: true,
    detail: 'Configure at least one model route on the OpenFish Host before starting a DSH task.',
  },
  graph: {
    level: 'observable',
    manifestVersion: 1,
    boundary: 'DeepSeek Harness process',
    evidence: [{ kind: 'source-derived', source: 'docs/architecture.md', version: BUILTIN_DSH_VERSION }],
    nodes: [
      {
        id: 'context', kind: 'context-runtime', title: 'Context assembly', editable: false,
        responsibility: 'Builds the model-visible prompt from instructions, workspace context, skills, and session history.',
        inputs: ['user intent', 'workspace', 'session history'], outputs: ['model context'],
        evidence: [{ kind: 'source-derived', source: 'packages/context', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'loop', kind: 'agent-loop', title: 'Agent loop', editable: false,
        responsibility: 'Coordinates inference, tool calls, approvals, and turn termination.',
        inputs: ['model context', 'session controls'], outputs: ['assistant events', 'tool requests'],
        observes: ['turn.started', 'turn.completed', 'turn.failed'],
        evidence: [{ kind: 'source-derived', source: 'packages/core/agent-loop', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'models', kind: 'model-router', title: 'Model routing', editable: false,
        responsibility: 'Resolves a configured provider, model, and reasoning controls for each inference request.',
        inputs: ['model selection', 'credentials'], outputs: ['streamed inference'],
        observes: ['model.completed'],
        evidence: [{ kind: 'source-derived', source: 'packages/llm', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'tools', kind: 'tool-runtime', title: 'Tool runtime', editable: false,
        responsibility: 'Publishes active tools, validates arguments, and records structured results.',
        inputs: ['tool request', 'active catalog'], outputs: ['tool result', 'render intent'],
        observes: ['tool.activity'],
        evidence: [{ kind: 'source-derived', source: 'packages/core/tools', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'sandbox', kind: 'execution-boundary', title: 'Execution boundary', editable: false,
        responsibility: 'Applies the active sandbox provider to operations that request confinement; exact enforcement depends on the selected provider and policy.',
        inputs: ['approved operation', 'workspace policy'], outputs: ['enforced or reported effect'],
        evidence: [{ kind: 'source-derived', source: 'packages/sandbox', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'approvals', kind: 'permission-policy', title: 'Approvals', editable: false,
        responsibility: 'Stops sensitive operations until the configured policy or user grants permission.',
        inputs: ['operation risk', 'preset policy'], outputs: ['allow or deny decision'],
        observes: ['approval.requested', 'approval.resolved'],
        evidence: [{ kind: 'source-derived', source: 'packages/guard', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'session', kind: 'session-runtime', title: 'Session persistence', editable: false,
        responsibility: 'Persists events, selected Harness identity, and resumable conversation state.',
        inputs: ['agent events', 'control state'], outputs: ['durable session', 'replay'],
        evidence: [{ kind: 'source-derived', source: 'packages/session', version: BUILTIN_DSH_VERSION }],
      },
      {
        id: 'extensions', kind: 'plugin-runtime', title: 'Plugin composition', editable: false,
        responsibility: 'Composes optional capabilities without changing the core agent loop.',
        inputs: ['plugin manifests', 'configuration'], outputs: ['capability graph'],
        evidence: [{ kind: 'source-derived', source: 'packages/core', version: BUILTIN_DSH_VERSION }],
      },
    ],
    edges: [
      { from: 'context', to: 'loop', label: 'assembled context', observes: ['turn.started'] },
      { from: 'loop', to: 'models', label: 'inference request', observes: ['turn.started'] },
      { from: 'models', to: 'loop', label: 'model stream', observes: ['model.completed'] },
      { from: 'loop', to: 'tools', label: 'tool request', observes: ['tool.activity'] },
      { from: 'tools', to: 'approvals', label: 'guarded effect', observes: ['approval.requested'] },
      { from: 'approvals', to: 'sandbox', label: 'approved operation' },
      { from: 'sandbox', to: 'tools', label: 'enforced execution' },
      { from: 'loop', to: 'session', label: 'durable events' },
      { from: 'extensions', to: 'loop', label: 'loop capabilities' },
      { from: 'extensions', to: 'tools', label: 'tool contributions' },
    ],
  },
  source: 'builtin',
})

function codexCaField() {
  return {
    ref: 'OPENFISH_CODEX_CA_CERTIFICATE',
    name: 'Custom CA bundle (optional)',
    env: 'CODEX_CA_CERTIFICATE',
    required: false,
    secret: false,
    placeholder: '/absolute/path/to/ca-bundle.pem',
  }
}

function curatedCodex(version = '0.150.1'): HarnessPack {
  return parseHarnessPack({
    schemaVersion: 0,
    id: 'codex',
    name: 'Codex',
    version,
    description: 'Official Codex Harness through the OpenAI app-server protocol.',
    publisher: 'OpenAI',
    repository: 'https://github.com/openai/codex',
    verified: true,
    protocol: 'codex-app-server',
    source: 'builtin',
    account: {
      label: 'Codex account', billing: 'harness-managed',
      detail: 'Codex app-server uses the locally authorized ChatGPT subscription or API credential selected by Codex.',
    },
    modelConfiguration: {
      owner: 'harness', required: true,
      detail: 'Models and their exact supported reasoning efforts come from the live official model/list response.',
    },
    authMethods: [
      {
        id: 'codex-local-login', name: 'Existing Codex login', kind: 'agent', fields: [codexCaField()],
        account: {
          label: 'Existing Codex account', billing: 'harness-managed',
          detail: 'After you confirm, OpenFish imports only the existing Codex auth.json into a private account-method profile; Codex task history, config, and logs remain outside the Harness boundary. The credential is never returned to the UI or stored in Pack/session state. At runtime app-server reports the actual account route so OpenFish does not guess billing.',
        },
      },
      {
        id: 'codex-managed-login', name: 'Sign in with ChatGPT', kind: 'terminal', fields: [codexCaField()],
        terminal: { args: [], env: {} },
        account: {
          label: 'ChatGPT · Codex plan', billing: 'subscription',
          detail: 'OpenFish opens the official Codex sign-in inside an isolated OpenFish-owned profile. The official Codex runtime stores and refreshes that login; OpenFish never copies the token into app state.',
        },
      },
      {
        id: 'codex-api-key', name: 'OpenAI API key', kind: 'environment',
        fields: [
          { ref: 'OPENAI_API_KEY', name: 'OpenAI API key', env: 'OPENAI_API_KEY', required: true, secret: true },
          codexCaField(),
        ],
        account: {
          label: 'OpenAI API billing', billing: 'usage',
          detail: 'Requests are billed to the OpenAI API project owning this key.',
        },
      },
    ],
    distribution: { kind: 'npx', package: `@openai/codex@${version}`, args: ['app-server', '--stdio'], env: {} },
    graph: {
      level: 'observable', manifestVersion: 1, boundary: 'Codex app-server process',
      evidence: [{ kind: 'source-derived', source: 'https://github.com/openai/codex/tree/main/codex-rs/app-server', version }],
      nodes: [
        { id: 'app-server', kind: 'protocol-adapter', title: 'App-server', editable: false, responsibility: 'Owns the official JSON-RPC boundary used by Codex interfaces.', observes: ['protocol.ready'], evidence: [{ kind: 'source-derived', source: 'codex-rs/app-server', version }] },
        { id: 'thread', kind: 'agent-session', title: 'Thread & turn', editable: false, responsibility: 'Owns durable Codex threads, turns, items, cancellation, and resume.', observes: ['session.ready', 'turn.started', 'turn.completed', 'turn.failed'], evidence: [{ kind: 'source-derived', source: 'codex-rs/app-server-protocol', version }] },
        { id: 'context', kind: 'context-runtime', title: 'Context', editable: false, responsibility: 'Builds model input from instructions, history, skills, apps, and the environment.', evidence: [{ kind: 'source-derived', source: 'codex-rs/core', version }] },
        { id: 'model', kind: 'model-client', title: 'Model client', editable: false, responsibility: 'Streams inference using the selected live model and advertised reasoning effort.', observes: ['model.completed'], evidence: [{ kind: 'source-derived', source: 'codex-rs/core', version }] },
        { id: 'tools', kind: 'tool-runtime', title: 'Tools', editable: false, responsibility: 'Executes coding, shell, MCP, skills, apps, and other enabled capabilities.', observes: ['tool.activity'], evidence: [{ kind: 'source-derived', source: 'codex-rs/core', version }] },
        { id: 'sandbox', kind: 'execution-boundary', title: 'Sandbox', editable: false, responsibility: 'Constrains filesystem and network effects under the selected policy.', evidence: [{ kind: 'source-derived', source: 'codex-rs/core', version }] },
        { id: 'approvals', kind: 'permission-policy', title: 'Approvals', editable: false, responsibility: 'Requests user review before boundary-crossing operations.', observes: ['approval.requested', 'approval.resolved'], evidence: [{ kind: 'source-derived', source: 'codex-rs/app-server', version }] },
        { id: 'output', kind: 'output-stream', title: 'Output stream', editable: false, responsibility: 'Publishes reasoning summaries, tool progress, and final answers as typed items.', observes: ['output.activity'], evidence: [{ kind: 'source-derived', source: 'codex-rs/app-server-protocol', version }] },
      ],
      edges: [
        { from: 'app-server', to: 'thread', label: 'JSON-RPC lifecycle', observes: ['session.ready'] },
        { from: 'thread', to: 'context', label: 'turn state', observes: ['turn.started'] },
        { from: 'context', to: 'model', label: 'model input', observes: ['turn.started'] },
        { from: 'model', to: 'tools', label: 'tool call', observes: ['tool.activity'] },
        { from: 'tools', to: 'approvals', label: 'guarded effect', observes: ['approval.requested'] },
        { from: 'approvals', to: 'sandbox', label: 'approved operation' },
        { from: 'sandbox', to: 'tools', label: 'constrained execution' },
        { from: 'model', to: 'output', label: 'reasoning and answer', observes: ['model.completed', 'output.activity'] },
        { from: 'tools', to: 'output', label: 'progress and result', observes: ['tool.activity'] },
      ],
    },
  })
}

function ompSource(kind: 'blob' | 'tree', ...segments: string[]): string {
  return `https://github.com/can1357/oh-my-pi/${kind}/main/${segments.join('/')}`
}

function curatedOmp(version = '18.0.9'): HarnessPack {
  return parseHarnessPack({
    schemaVersion: 0,
    id: 'oh-my-pi',
    name: 'Oh My Pi',
    version,
    description: 'Community Harness with native ACP mode and advanced coding tools.',
    publisher: 'Oh My Pi contributors',
    repository: 'https://github.com/can1357/oh-my-pi',
    verified: false,
    protocol: 'acp',
    account: {
      label: 'Provider account managed by Oh My Pi', billing: 'harness-managed',
      detail: 'Oh My Pi owns provider credentials and reports its available models through ACP.',
    },
    modelConfiguration: {
      owner: 'harness', required: false,
      detail: 'Models and supported reasoning controls are discovered from the running Oh My Pi session.',
    },
    authMethods: [{
      id: 'omp-provider-login',
      name: 'Sign in to a model provider',
      kind: 'terminal',
      fields: [],
      terminal: { args: ['auth-broker', 'login'], env: {} },
      account: {
        label: 'Provider selected in Oh My Pi',
        billing: 'harness-managed',
        detail: 'Oh My Pi opens its provider picker and stores that provider login inside the isolated OpenFish-managed OMP profile. The selected provider owns usage and billing; OpenFish does not receive its token.',
      },
    }],
    distribution: { kind: 'bunx', package: `@oh-my-pi/pi-coding-agent@${version}`, args: ['acp'], env: {} },
    graph: {
      level: 'observable',
      manifestVersion: 1,
      boundary: 'Oh My Pi agent process',
      evidence: [{ kind: 'source-derived', source: 'https://github.com/can1357/oh-my-pi', version }],
      nodes: [
        {
          id: 'resources', kind: 'context-loader', title: 'Resource loader', editable: false,
          responsibility: 'Discovers context files, prompts, skills, and project configuration.',
          inputs: ['workspace', 'OMP configuration'], outputs: ['agent resources'],
          evidence: [{ kind: 'source-derived', source: ompSource('tree', 'packages', 'coding-agent', 'src'), version }],
        },
        {
          id: 'session', kind: 'agent-session', title: 'Agent session', editable: false,
          responsibility: 'Owns the conversation, agent loop, compaction, and lifecycle events.',
          inputs: ['prompt', 'agent resources'], outputs: ['messages', 'tool requests'],
          observes: ['session.ready', 'turn.started', 'turn.completed', 'turn.failed', 'output.activity'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'packages', 'coding-agent', 'src', 'session', 'agent-session.ts'), version }],
        },
        {
          id: 'models', kind: 'model-registry', title: 'Model registry', editable: false,
          responsibility: 'Combines bundled, configured, discovered, and extension-provided model catalogs.',
          inputs: ['provider config', 'credentials'], outputs: ['available model route'],
          observes: ['model.completed'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'packages', 'coding-agent', 'src', 'config', 'model-registry.ts'), version }],
        },
        {
          id: 'tools', kind: 'tool-registry', title: 'Tool registry', editable: false,
          responsibility: 'Selects built-in and discoverable tools for the active session.',
          inputs: ['tool configuration', 'session'], outputs: ['validated tool execution'],
          observes: ['tool.activity'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'packages', 'coding-agent', 'src', 'tools', 'index.ts'), version }],
        },
        {
          id: 'permissions', kind: 'permission-policy', title: 'Permission policy', editable: false,
          responsibility: 'Classifies tool effects and requests approval for guarded operations.',
          inputs: ['tool request', 'policy'], outputs: ['permission decision'],
          observes: ['approval.requested', 'approval.resolved'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'packages', 'coding-agent', 'src', 'tools', 'index.ts'), version }],
        },
        {
          id: 'execution', kind: 'execution-runtime', title: 'Execution runtime', editable: false,
          responsibility: 'Runs filesystem, shell, language, browser, and other coding tools.',
          inputs: ['approved tool request'], outputs: ['workspace effect', 'tool result'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'README.md'), version }],
        },
        {
          id: 'extensions', kind: 'extension-runtime', title: 'Extensions', editable: false,
          responsibility: 'Adds tools, commands, event handlers, providers, and custom interaction behavior.',
          inputs: ['extension packages'], outputs: ['runtime contributions'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'docs', 'extensions.md'), version }],
        },
        {
          id: 'persistence', kind: 'session-storage', title: 'Persistence', editable: false,
          responsibility: 'Stores session entries, branches, checkpoints, and resumable agent state.',
          inputs: ['session events'], outputs: ['durable history'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'packages', 'coding-agent', 'src', 'session', 'session-manager.ts'), version }],
        },
        {
          id: 'acp', kind: 'protocol-adapter', title: 'ACP interface', editable: false,
          responsibility: 'Projects the OMP session into ACP prompts, updates, controls, and permission requests.',
          inputs: ['ACP client requests', 'agent events'], outputs: ['ACP session updates'],
          observes: ['protocol.ready'],
          evidence: [{ kind: 'source-derived', source: ompSource('blob', 'README.md'), version }],
        },
      ],
      edges: [
        { from: 'resources', to: 'session', label: 'agent resources', observes: ['turn.started'] },
        { from: 'models', to: 'session', label: 'selected route', observes: ['model.completed'] },
        { from: 'extensions', to: 'session', label: 'event behavior' },
        { from: 'extensions', to: 'models', label: 'provider contributions' },
        { from: 'extensions', to: 'tools', label: 'tool contributions' },
        { from: 'session', to: 'tools', label: 'tool request' },
        { from: 'tools', to: 'permissions', label: 'classified effect', observes: ['approval.requested'] },
        { from: 'permissions', to: 'execution', label: 'approved operation' },
        { from: 'execution', to: 'session', label: 'effect and result', observes: ['tool.activity'] },
        { from: 'session', to: 'persistence', label: 'history and checkpoint', observes: ['turn.completed', 'turn.failed'] },
        { from: 'acp', to: 'session', label: 'prompt and controls', observes: ['session.ready', 'turn.started'] },
        { from: 'session', to: 'acp', label: 'typed updates', observes: ['output.activity'] },
      ],
    },
    source: 'builtin',
  })
}

/**
 * Return the exact built-in Pack manifests used by the running catalog.
 *
 * Screenshot/demo fixtures are generated from this function so their graph,
 * evidence, authentication, and model ownership cannot drift from the live
 * product while remaining network-isolated at runtime.
 * @returns Cloned built-in Pack manifests for the running OpenFish build.
 */
export function builtInHarnessPacks(): HarnessPack[] {
  return structuredClone([BUILTIN_DSH, curatedCodex(), curatedOmp()])
}

/** Identities whose runtime semantics are owned by this exact OpenFish build. */
const RESERVED_HARNESS_IDS = new Set<string>(builtInHarnessPacks().map(pack => pack.id))

function customPackAdmissionIssue(pack: HarnessPack): string | undefined {
  if (pack.protocol === 'dsh') {
    return 'The built-in DSH protocol is not a public Driver id and cannot be claimed by a custom Harness Pack.'
  }
  if (RESERVED_HARNESS_IDS.has(pack.id)) {
    return `Harness id "${pack.id}" is reserved by the bundled OpenFish catalog. Fork it under a new id instead of replacing its trusted identity.`
  }
  return undefined
}

/** Derive a client-safe supply-chain statement without overstating package-manager guarantees. */
function installationIntegrity(
  pack: HarnessPack,
  status: HarnessInstallation['status'],
): HarnessInstallation['integrity'] {
  if (pack.protocol === 'dsh') {
    return {
      status: 'trusted-runtime',
      source: 'OpenFish application bundle',
      detail: 'This Harness ships inside the exact OpenFish application build currently running.',
    }
  }
  const distribution = pack.distribution
  if (distribution === undefined) {
    return {
      status: 'unverified',
      source: pack.source,
      detail: 'This Pack has no portable distribution and cannot be independently verified or installed.',
    }
  }
  if (distribution.kind === 'binary') {
    if (distribution.sha256 === undefined) {
      return {
        status: 'unverified',
        source: distribution.archive,
        detail: 'The binary source declares no SHA-256 digest; OpenFish will show it for discovery but refuse installation.',
      }
    }
    return {
      status: status === 'installed' ? 'checksum-verified' : 'checksum-declared',
      source: distribution.archive,
      digest: `sha256:${distribution.sha256.toLowerCase()}`,
      detail: status === 'installed'
        ? 'The downloaded archive matched the Pack-declared SHA-256 digest before promotion.'
        : 'A SHA-256 digest is declared and will be checked before installation is promoted.',
    }
  }
  if (distribution.kind === 'executable') {
    return {
      status: 'local-executable',
      source: distribution.command,
      detail: 'This user-selected local executable is not copied or cryptographically verified by OpenFish.',
    }
  }
  return {
    status: 'version-pinned',
    source: distribution.package,
    detail: 'The package is pinned to an exact version. This is reproducible identity, not a checksum verification claim.',
  }
}

function catalogCompatibility(
  pack: HarnessPack,
  evidence: Omit<HarnessCompatibility, 'classification'>,
): HarnessCompatibility {
  const classification = evidence.status === 'failed'
    ? 'incompatible' as const
    : evidence.status !== 'compatible'
      ? 'experimental' as const
      : pack.graph.level === 'opaque'
        ? 'opaque-but-runnable' as const
        : 'supported' as const
  return {
    ...evidence,
    ...(evidence.message === undefined
      ? {}
      : { message: safeHarnessDiagnostic(evidence.message, 'Compatibility check failed') }),
    classification,
  }
}

/** Catalog plus effect-scoped protocol drivers. */
export class HarnessService extends Service {
  static Config = Config

  private readonly packs = new Map<HarnessId, HarnessPack>()
  private readonly drivers = new Map<HarnessPack['protocol'], HarnessDriver>()
  private readonly initialRefresh: Promise<void>
  private readonly stateFile: string
  private readonly installRoot: string
  private readonly runtimeRoot: string
  private state: StoredHarnessState = structuredClone(EMPTY_STATE)
  private readonly transient = new Map<HarnessId, {
    status: 'installing' | 'failed'
    phase?: NonNullable<HarnessInstallation['operationPhase']>
    detail?: string
    error?: string
  }>()
  private mutation: Promise<void> = Promise.resolve()

  constructor(ctx: Context, private readonly config: HarnessConfig) {
    super(ctx, 'harnesses')
    const stateDir = config.stateDir ?? dshHomePath('openfish', 'harnesses')
    this.stateFile = join(stateDir, 'state.json')
    this.installRoot = join(stateDir, 'installed')
    this.runtimeRoot = join(stateDir, 'runtime')
    this.packs.set(BUILTIN_DSH.id, BUILTIN_DSH)
    const codex = curatedCodex()
    this.packs.set(codex.id, codex)
    const omp = curatedOmp()
    this.packs.set(omp.id, omp)
    for (const input of config.packs ?? []) {
      const pack = parseHarnessPack(input)
      const issue = customPackAdmissionIssue(pack)
      if (issue !== undefined) {
        ctx.logger.warn(`Ignoring configured Harness Pack: ${issue}`)
        continue
      }
      this.packs.set(pack.id, pack)
    }
    // Local state is the startup barrier; remote registries are enrichment.
    // Keeping network refresh on this barrier made first-run onboarding empty
    // whenever GitHub, npm, or the ACP Registry was slow or offline even
    // though the supported baseline Packs were already bundled locally.
    this.initialRefresh = this.initialize().catch((error: unknown) => {
      ctx.logger.warn(`Harness local state could not be restored; serving bundled Packs: ${safeHarnessDiagnostic(error, 'state restore failed')}`)
    })
    ctx.effect(() => {
      const controller = new AbortController()
      const startupRefresh = this.initialRefresh.then(async () => {
        if (controller.signal.aborted) return
        try {
          await this.refresh(controller.signal)
        } catch (error: unknown) {
          if (!abortSignalIsAborted(controller.signal)) {
            ctx.logger.warn(`Harness registry startup refresh failed; retaining the local catalog: ${safeHarnessDiagnostic(error, 'registry refresh failed')}`)
          }
        }
      })
      return async () => {
        controller.abort()
        await startupRefresh
      }
    }, 'harnesses.registry-refresh()')
  }

  private async initialize(): Promise<void> {
    await ensureManagedDirectory(dirname(this.stateFile), 'Harness state directory')
    await ensureManagedDirectory(this.installRoot, 'Harness installation root')
    await ensureManagedDirectory(this.runtimeRoot, 'Harness runtime root')
    try {
      const parsed = JSON.parse(await readFile(this.stateFile, 'utf8')) as unknown
      if (typeof parsed === 'object' && parsed !== null && [1, 2, 3, 4, 5, 6, 7].includes(Number((parsed as { version?: unknown }).version))) {
        const candidate = parsed as StoredHarnessStateCandidate
        const customPacks = candidate.customPacks
          .map(pack => parseHarnessPack({ ...pack, source: 'user' }))
          .filter((pack) => {
            const issue = customPackAdmissionIssue(pack)
            if (issue !== undefined) this.ctx.logger.warn(`Ignoring unsafe persisted custom Harness Pack: ${issue}`)
            return issue === undefined
          })
        const registryPacks = (candidate.registryPacks ?? [])
          .map(pack => parseHarnessPack({ ...pack, source: 'acp-registry' }))
          .filter((pack) => {
            const issue = customPackAdmissionIssue(pack)
            if (issue !== undefined) this.ctx.logger.warn(`Ignoring unsafe cached ACP Registry Pack: ${issue}`)
            return issue === undefined
          })
        const communityPacks = (candidate.communityPacks ?? [])
          .map(pack => parseHarnessPack({ ...pack, verified: false, source: 'openfish-community' }))
          .filter((pack) => {
            const issue = customPackAdmissionIssue(pack)
            if (issue !== undefined) this.ctx.logger.warn(`Ignoring unsafe cached community Pack: ${issue}`)
            return issue === undefined
          })
        const catalog = new Map<HarnessId, HarnessPack>([
          ...registryPacks.map(pack => [pack.id, pack] as const),
          ...communityPacks.map(pack => [pack.id, pack] as const),
          ...customPacks.map(pack => [pack.id, pack] as const),
        ])
        const installs = Object.fromEntries(Object.entries(candidate.installs).map(([id, install]) => {
          const fallback = catalog.get(id as HarnessId) ?? this.packs.get(id as HarnessId)
          return [id, {
            ...(install.active === undefined ? {} : { active: parseStoredHarnessPack(install.active, fallback) }),
            previous: install.previous.map(pack => parseStoredHarnessPack(pack, fallback)),
            ...(install.authMethod === undefined ? {} : { authMethod: install.authMethod }),
            ...(Object.keys(storedAuthenticationDiscoveries(install.authDiscoveries)).length === 0
              ? {}
              : { authDiscoveries: storedAuthenticationDiscoveries(install.authDiscoveries) }),
            ...(install.compatibility === undefined ? {} : { compatibility: install.compatibility }),
          } satisfies StoredInstall]
        }))
        this.state = {
          version: 7,
          // v1 always materialized DSH even when the user never chose it. Do
          // not mistake that compatibility default for consent during upgrade.
          ...(candidate.version >= 2 && candidate.defaultHarnessId !== undefined
            ? { defaultHarnessId: candidate.defaultHarnessId }
            : {}),
          customPacks,
          registryPacks,
          communityPacks,
          communityRevocations: candidate.communityRevocations ?? [],
          communitySubmissions: (candidate.communitySubmissions ?? [])
            .map(storedCommunitySubmission)
            .filter((submission): submission is StoredCommunitySubmission => submission !== undefined),
          communityRevocationSubmissions: (candidate.communityRevocationSubmissions ?? [])
            .map(storedCommunitySubmission)
            .filter((submission): submission is StoredCommunitySubmission => submission !== undefined),
          driverAuthorizations: storedDriverAuthorizations(candidate.driverAuthorizations),
          installs,
        }
        for (const pack of this.state.registryPacks) this.packs.set(pack.id, pack)
        for (const pack of this.state.communityPacks) {
          if (!this.packs.has(pack.id)) this.packs.set(pack.id, pack)
        }
        for (const pack of this.state.customPacks) this.packs.set(pack.id, pack)
        for (const install of Object.values(this.state.installs)) {
          if (install.active === undefined) continue
          // Curated versions are release-tested exact Pack identities rather
          // than floating npm aliases. Retain the installed snapshot across an
          // app upgrade so its active/previous transaction remains explicit;
          // a newer app-bundled Pack remains the available update.
          const curatedBuiltin = (install.active.id === 'codex'
              && install.active.protocol === 'codex-app-server'
              && install.active.source === 'builtin')
            || (install.active.id === 'oh-my-pi'
              && install.active.protocol === 'acp'
              && install.active.source === 'builtin')
          // The constructor already installed this OpenFish release's exact
          // curated Pack in the catalog. Keep the older installed Pack only in
          // active/previous state so the row can truthfully offer the new
          // release-tested version as an explicit update.
          if (!curatedBuiltin && !this.packs.has(install.active.id)) {
            this.packs.set(install.active.id, install.active)
          }
        }
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }

  private async saveState(): Promise<void> {
    await ensureManagedDirectory(dirname(this.stateFile), 'Harness state directory')
    const temporary = `${this.stateFile}.tmp`
    await writeFile(temporary, `${JSON.stringify(this.state, null, 2)}\n`, { mode: 0o600 })
    await rename(temporary, this.stateFile)
  }

  private serialize(operation: () => Promise<void>): Promise<void> {
    const result = this.mutation.then(operation, operation)
    this.mutation = result.catch(() => {})
    return result
  }

  /**
   * Register one protocol implementation until its owning effect unloads.
   * @param driver - Protocol implementation to reserve.
   * @returns Disposer that removes only this exact registration.
   */
  registerDriver(driver: HarnessDriver): () => void {
    let apiVersion: unknown
    let protocol: unknown
    try {
      apiVersion = driver.apiVersion
      protocol = driver.protocol
    } catch (error: unknown) {
      throw new Error(`Harness Driver identity could not be read: ${safeHarnessDiagnostic(error, 'identity access failed')}`)
    }
    const protocolLabel = typeof protocol === 'string' ? protocol : 'invalid'
    const api = negotiateHarnessDriverApi(typeof apiVersion === 'number' ? apiVersion : Number.NaN)
    if (!api.compatible) throw new Error(`Harness driver "${protocolLabel}" uses an unsupported API version: ${api.message}`)
    if (typeof protocol !== 'string' || !/^[a-z0-9][a-z0-9._-]*$/u.test(protocol)) {
      throw new Error(`Harness driver protocol "${protocolLabel}" is invalid`)
    }
    if (protocol === 'dsh') throw new Error('The built-in DSH runtime is not a public Driver registration id')
    for (const method of ['capabilities', 'available', 'create', 'resume', 'dispose'] as const) {
      let implementation: unknown
      try {
        implementation = driver[method]
      } catch (error: unknown) {
        throw new Error(`Harness driver "${protocol}" member "${method}" could not be read: ${safeHarnessDiagnostic(error, 'member access failed')}`)
      }
      if (typeof implementation !== 'function') {
        throw new Error(`Harness driver "${protocol}" is missing required method "${method}"`)
      }
    }
    if (this.drivers.has(protocol)) throw new Error(`Harness driver "${protocol}" is already registered`)
    this.drivers.set(protocol, driver)
    return () => { if (this.drivers.get(protocol) === driver) this.drivers.delete(protocol) }
  }

  private packAtVersion(id: HarnessId, version: string): HarnessPack | undefined {
    const catalogPack = this.packs.get(id)
    const install = this.state.installs[id]
    return [catalogPack, install?.active, ...(install?.previous ?? [])]
      .find(candidate => candidate?.version === version)
  }

  private driverAuthorizationIssue(pack: HarnessPack): string | undefined {
    const bundle = pack.driverBundle
    if (bundle === undefined) return undefined
    const authorization = this.state.driverAuthorizations[pack.protocol]
    if (authorization?.package === bundle.package && authorization.spec === bundle.spec) return undefined
    return `Harness "${pack.id}" version ${pack.version} requires exact Driver Bundle ${bundle.spec}; activate and authorize it in the OpenFish Mac app before this Pack can run`
  }

  private requireDriverAuthorization(pack: HarnessPack): void {
    const issue = this.driverAuthorizationIssue(pack)
    if (issue !== undefined) throw new Error(issue)
  }

  /**
   * Record one exact Driver Bundle only after the loopback-pinned Mac bridge
   * admitted it and observed the matching Driver in the restarted Host.
   * Remote clients cannot call the authoring plane that exposes this method.
   * @param id - Exact Harness Pack identity.
   * @param version - Exact admitted Pack version.
   * @param packageName - Driver package identity declared by the Pack.
   * @param spec - Exact immutable Driver installation spec.
   */
  async authorizeDriverBundle(
    id: HarnessId,
    version: string,
    packageName: string,
    spec: string,
  ): Promise<void> {
    await this.initialRefresh
    const pack = this.packAtVersion(id, version)
    if (pack === undefined) throw new Error(`Harness "${id}" version ${version} is not present in the admitted catalog`)
    const bundle = pack.driverBundle
    if (bundle === undefined) throw new Error(`Harness "${id}" does not declare a separately installed Driver Bundle`)
    if (bundle.package !== packageName || bundle.spec !== spec) {
      throw new Error(`Driver authorization does not match Harness "${id}" version ${version}`)
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    await requireConformantDriver(driver, pack)
    await this.serialize(async () => {
      this.state.driverAuthorizations[pack.protocol] = {
        package: bundle.package,
        spec: bundle.spec,
        authorizedAt: new Date().toISOString(),
      }
      await this.saveState()
    })
  }

  /**
   * Refresh ACP Registry metadata without deleting user or built-in Packs.
   * @param signal - Optional cancellation for the registry request.
   */
  async refresh(signal?: AbortSignal): Promise<void> {
    signal?.throwIfAborted()
    await this.initialRefresh
    signal?.throwIfAborted()
    const options = signal === undefined ? {} : { signal }
    const [response, communityResponse] = await Promise.all([
      fetch(this.config.registryUrl ?? 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json', options).catch(() => undefined),
      fetch(this.config.communityRegistryUrl ?? 'https://raw.githubusercontent.com/Yusong-Enceladus/OpenFish/main/community/harnesses/index.json', options).catch(() => undefined),
    ])
    let registryPacks: HarnessPack[] | undefined
    if (response?.ok) {
      try {
        registryPacks = packsFromAcpRegistry(await boundedJsonResponse(
          response,
          16 * 1024 * 1024,
          'ACP Registry',
        )).filter((pack) => {
          const issue = customPackAdmissionIssue(pack)
          if (issue !== undefined) this.ctx.logger.warn(`Ignoring unsafe ACP Registry Pack: ${issue}`)
          return issue === undefined
        })
      } catch (error: unknown) {
        this.ctx.logger.warn(`ACP Registry refresh failed; retaining the last successful catalog: ${safeHarnessDiagnostic(error, 'registry refresh failed')}`)
      }
    } else if (response !== undefined) {
      this.ctx.logger.warn(`ACP Registry returned HTTP ${response.status}; retaining the last successful catalog`)
    }
    let communityPacks: HarnessPack[] | undefined
    let communityRevocations: OpenFishCommunityRevocation[] | undefined
    if (communityResponse?.ok) {
      try {
        const catalog = openFishCommunityCatalog(await boundedJsonResponse(
          communityResponse,
          4 * 1024 * 1024,
          'OpenFish community catalog',
        ))
        communityPacks = catalog.packs.filter((pack) => {
          const issue = customPackAdmissionIssue(pack)
          if (issue !== undefined) this.ctx.logger.warn(`Ignoring unsafe community Pack: ${issue}`)
          return issue === undefined
        })
        communityRevocations = catalog.revocations
      } catch (error: unknown) {
        this.ctx.logger.warn(`OpenFish community Harness catalog refresh failed; retaining the last successful catalog: ${safeHarnessDiagnostic(error, 'community refresh failed')}`)
      }
    }
    const communitySubmissions = await Promise.all(
      this.state.communitySubmissions.map(async submission => await refreshedCommunitySubmission(submission, signal)),
    )
    const communityRevocationSubmissions = await Promise.all(
      this.state.communityRevocationSubmissions.map(async submission => await refreshedCommunitySubmission(submission, signal)),
    )
    signal?.throwIfAborted()
    const nextRegistryPacks = registryPacks ?? this.state.registryPacks
    const nextCommunityPacks = communityPacks ?? this.state.communityPacks
    const nextCommunityRevocations = communityRevocations ?? this.state.communityRevocations
    const nextCommunitySubmissions = this.state.communitySubmissions.map(existing =>
      communitySubmissions.find(candidate => candidate.id === existing.id && candidate.version === existing.version) ?? existing)
    const nextCommunityRevocationSubmissions = this.state.communityRevocationSubmissions.map(existing =>
      communityRevocationSubmissions.find(candidate => candidate.id === existing.id && candidate.version === existing.version) ?? existing)
    // Startup enrichment is detached from the first local catalog read. Avoid
    // a late private-state rewrite when none of the fetched ledgers changed;
    // callers that already completed must not race a no-op refresh at shutdown.
    const changed = JSON.stringify(nextRegistryPacks) !== JSON.stringify(this.state.registryPacks)
      || JSON.stringify(nextCommunityPacks) !== JSON.stringify(this.state.communityPacks)
      || JSON.stringify(nextCommunityRevocations) !== JSON.stringify(this.state.communityRevocations)
      || JSON.stringify(nextCommunitySubmissions) !== JSON.stringify(this.state.communitySubmissions)
      || JSON.stringify(nextCommunityRevocationSubmissions) !== JSON.stringify(this.state.communityRevocationSubmissions)
    if (!changed) return
    await this.serialize(async () => {
      signal?.throwIfAborted()
      // Built-in Packs are a release-tested compatibility contract, not an
      // npm "latest" alias. Their exact distributions change only with an
      // OpenFish release, after which the ordinary installed/previous snapshot
      // path exposes an explicit update and rollback. Registry refresh may add
      // unverified Packs, but it never silently rewrites the trusted Codex or
      // curated OMP version beneath a user's default Harness.
      const refreshedIds = new Set(nextRegistryPacks.map(pack => pack.id))
      const refreshedCommunityIds = new Set(nextCommunityPacks.map(pack => pack.id))
      for (const [id, existing] of this.packs) {
        if (existing.source === 'acp-registry' && !refreshedIds.has(id)) this.packs.delete(id)
        if (existing.source === 'openfish-community' && !refreshedCommunityIds.has(id)) {
          const retainedInstall = this.state.installs[id]?.active
          const explicitlyRevoked = nextCommunityRevocations.some(item => item.id === id && item.version === existing.version)
          if (retainedInstall === undefined && !explicitlyRevoked) this.packs.delete(id)
        }
      }
      this.state.registryPacks = nextRegistryPacks
      const retainedCommunityPacks = this.state.communityPacks.filter(pack =>
        !refreshedCommunityIds.has(pack.id)
        && (this.state.installs[pack.id]?.active !== undefined
          || nextCommunityRevocations.some(item => item.id === pack.id && item.version === pack.version)))
      this.state.communityPacks = [...nextCommunityPacks, ...retainedCommunityPacks]
      this.state.communityRevocations = nextCommunityRevocations
      this.state.communitySubmissions = nextCommunitySubmissions
      this.state.communityRevocationSubmissions = nextCommunityRevocationSubmissions
      for (const pack of nextRegistryPacks) {
        const existing = this.packs.get(pack.id)
        if (existing?.source === 'builtin' || existing?.source === 'user') continue
        this.packs.set(pack.id, pack)
      }
      for (const pack of nextCommunityPacks) {
        const existing = this.packs.get(pack.id)
        if (existing?.source === 'builtin' || existing?.source === 'user' || existing?.source === 'acp-registry') continue
        this.packs.set(pack.id, pack)
      }
      await this.saveState()
    })
  }

  /**
   * List every Pack with its current driver availability.
   * @returns Detached catalog rows in insertion order.
   */
  async list(): Promise<HarnessCatalogEntry[]> {
    await this.initialRefresh
    // Once a remote refresh has entered its atomic commit, keep the in-memory
    // catalog and its private state file on the same durable revision.
    // A managed install deliberately exposes a transient Host-owned phase to
    // native clients. Waiting for the long install transaction here would
    // make that progress unobservable and turn cancellation into a blind UI.
    // The committed install state remains unchanged until activation; while
    // the transient exists, catalogEntry() overlays only bounded public phase
    // text on that last durable state.
    if (![...this.transient.values()].some(item => item.status === 'installing')) {
      await this.mutation
    }
    return await Promise.all([...this.packs.values()].map(async (pack) => {
      const install = this.state.installs[pack.id]
      return await this.catalogEntry(pack, install?.active ?? pack, install?.authMethod)
    }))
  }

  /**
   * Resolve the exact installed Pack and authentication choice pinned by a task.
   * @param id - Stable Harness identity recorded by the task.
   * @param version - Exact Pack version recorded by the task.
   * @param authMethod - Exact non-secret authentication method recorded by the task.
   * @returns Detached catalog row describing what that task actually runs.
   */
  async describe(id: HarnessId, version?: string, authMethod?: string): Promise<HarnessCatalogEntry> {
    await this.initialRefresh
    await this.mutation
    const catalogPack = this.require(id)
    const install = this.state.installs[id]
    const effectivePack = version === undefined
      ? install?.active ?? catalogPack
      : [catalogPack.protocol === 'dsh' ? catalogPack : undefined, install?.active, ...(install?.previous ?? [])]
        .find(candidate => candidate?.version === version)
    if (effectivePack === undefined) {
      throw new Error(`Harness "${id}" version ${version} is not installed; restore that version or fork the task onto a current Harness`)
    }
    if (authMethod !== undefined && !(effectivePack.authMethods ?? []).some(method => method.id === authMethod)) {
      throw new Error(`Harness "${id}" version ${effectivePack.version} does not declare authentication method "${authMethod}"`)
    }
    return await this.catalogEntry(catalogPack, effectivePack, authMethod ?? install?.authMethod, version !== undefined)
  }

  private publicationFor(pack: HarnessPack): HarnessPublication | undefined {
    if (pack.source !== 'user' && pack.source !== 'openfish-community') return undefined
    const community = this.state.communityPacks.filter(item => item.id === pack.id)
    const published = community.find(item => item.version === pack.version)
    const revocation = this.state.communityRevocations.find(item => item.id === pack.id && item.version === pack.version)
    const submission = this.state.communitySubmissions.find(item => item.id === pack.id && item.version === pack.version)
    const revocationSubmission = this.state.communityRevocationSubmissions
      .find(item => item.id === pack.id && item.version === pack.version)
    const knownVersions = [...new Set([
      pack.version,
      ...community.map(item => item.version),
      ...([this.state.installs[pack.id]?.active, ...(this.state.installs[pack.id]?.previous ?? [])]
        .filter((item): item is HarnessPack => item !== undefined)
        .map(item => item.version)),
    ])].sort()
    const catalogUrl = 'https://github.com/Yusong-Enceladus/OpenFish/tree/main/community/harnesses'
    if (revocation !== undefined) {
      return {
        status: 'revoked', review: 'revoked', ...(published === undefined ? {} : { publishedVersion: published.version }),
        knownVersions, catalogUrl,
        detail: `Version ${pack.version} was explicitly revoked. Existing pinned tasks may resume, but OpenFish will not install it or use it for new tasks.`,
        revokedVersion: revocation.version, revokedReason: revocation.reason,
        revokedAt: revocation.revokedAt, ...(revocation.reviewUrl === undefined ? {} : { reviewUrl: revocation.reviewUrl }),
      }
    }
    if (revocationSubmission !== undefined) {
      const detail = revocationSubmission.review === 'merged'
        ? 'The revocation review was merged; OpenFish is waiting for the generated catalog to publish the exact-version ledger entry.'
        : revocationSubmission.review === 'closed'
          ? 'The revocation review closed without changing the catalog. The Pack remains installable unless a later reviewed revocation is merged.'
          : revocationSubmission.review === 'changes-requested'
            ? 'Maintainers requested changes to the revocation evidence. Open the review to respond before this exact version can be blocked.'
            : 'An exact-version revocation is in maintainer review. The Pack remains available until that public review is merged.'
      return {
        status: 'revocation-requested', review: revocationSubmission.review,
        ...(published === undefined ? {} : { publishedVersion: published.version }),
        knownVersions, catalogUrl, reviewUrl: revocationSubmission.reviewUrl, detail,
      }
    }
    if (published !== undefined) {
      return {
        status: 'published', review: 'merged', publishedVersion: published.version,
        knownVersions, catalogUrl,
        detail: `Version ${published.version} is present in the reviewed OpenFish community catalog.`,
      }
    }
    if (submission !== undefined) {
      const reviewDetail = submission.review === 'merged'
        ? 'The review was merged; OpenFish is waiting for the generated public catalog to publish this exact version.'
        : submission.review === 'closed'
          ? 'The review closed without catalog publication. Edit the Pack, increment its version when behavior changes, and submit again.'
          : submission.review === 'changes-requested'
            ? 'Maintainers requested changes. Open the review, update the Pack, and submit the corrected exact version.'
            : 'The credential-free Pack is in community review. It is not discoverable or endorsed until review and catalog merge complete.'
      return {
        status: 'submitted', review: submission.review,
        knownVersions, catalogUrl, reviewUrl: submission.reviewUrl,
        detail: reviewDetail,
      }
    }
    if (pack.source === 'user' && community.length > 0) {
      return {
        status: 'update-draft', review: 'not-submitted',
        ...(community[0] === undefined ? {} : { publishedVersion: community[0].version }),
        knownVersions, catalogUrl,
        detail: 'This local version differs from the reviewed community version. Export it to prepare an explicit update submission.',
      }
    }
    if (pack.source === 'user') {
      return {
        status: 'local-draft', review: 'not-submitted', knownVersions, catalogUrl,
        detail: 'This Pack exists only on this Mac until its credential-free manifest is reviewed and merged.',
      }
    }
    return {
      status: 'published', review: 'merged', publishedVersion: pack.version,
      knownVersions, catalogUrl,
      detail: `Version ${pack.version} is retained from the reviewed OpenFish community catalog.`,
    }
  }

  private isRevoked(pack: HarnessPack): boolean {
    return this.state.communityRevocations.some(item => item.id === pack.id && item.version === pack.version)
  }

  private async catalogEntry(
    catalogPack: HarnessPack,
    snapshotPack: HarnessPack,
    selectedAuthMethod: string | undefined,
    allowRevokedResume = false,
  ): Promise<HarnessCatalogEntry> {
    const effectivePack = withCurrentAuthenticationContract(catalogPack, snapshotPack)
    const install = this.state.installs[catalogPack.id]
    const transient = this.transient.get(catalogPack.id)
    const driver = this.drivers.get(effectivePack.protocol)
    const installation = effectivePack.protocol === 'dsh'
      ? {
        status: 'builtin' as const,
        installedVersion: effectivePack.version,
        availableVersion: catalogPack.version,
        previousVersions: [],
        integrity: installationIntegrity(effectivePack, 'builtin'),
      }
      : {
        status: transient?.status === 'installing'
          ? 'installing' as const
          : transient?.status === 'failed' && install?.active === undefined
            ? 'failed' as const
            : install?.active === undefined ? 'not-installed' as const : 'installed' as const,
        ...(install?.active === undefined ? {} : { installedVersion: install.active.version }),
        availableVersion: catalogPack.version,
        previousVersions: install?.previous.map(item => item.version) ?? [],
        ...(transient?.phase === undefined ? {} : { operationPhase: transient.phase }),
        ...(transient?.detail === undefined ? {} : { operationDetail: transient.detail }),
        integrity: installationIntegrity(
          effectivePack,
          install?.active === undefined ? 'not-installed' : 'installed',
        ),
        ...(transient?.error === undefined ? {} : { error: transient.error }),
      }
    const auth = {
      methods: effectivePack.authMethods ?? [],
      ...(selectedAuthMethod === undefined ? {} : { selectedMethod: selectedAuthMethod }),
      ...await this.authenticationState(effectivePack, selectedAuthMethod, driver),
    }
    const compatibility = catalogCompatibility(effectivePack, install?.compatibility ?? (effectivePack.protocol === 'dsh'
      ? { status: 'compatible' as const, checkedAt: new Date(0).toISOString(), message: 'Built in to this Open Fish runtime.' }
      : { status: 'untested' as const }))
    const publication = this.publicationFor(effectivePack)
    const publicationFields = publication === undefined ? {} : { publication }
    const revokedReason = publication?.status === 'revoked' && !allowRevokedResume
      ? `Harness version ${effectivePack.version} was revoked: ${publication.revokedReason ?? 'see the community review record'}`
      : undefined
    const driverAuthorizationIssue = this.driverAuthorizationIssue(effectivePack)
    const isDefault = this.state.defaultHarnessId === catalogPack.id
      && (effectivePack.protocol === 'dsh'
        || (install?.active !== undefined
          && driverAuthorizationIssue === undefined
          && (auth.status === 'not-required' || auth.status === 'configured')))
    const observesRuntime = effectivePack.graph.nodes.some(node => node.observes !== undefined)
      || effectivePack.graph.edges.some(edge => edge.observes !== undefined)
    const builtinCapabilities = [
      { id: 'lifecycle.install', status: 'unsupported', source: 'driver', detail: 'DSH is built into the OpenFish Host.' },
      { id: 'lifecycle.update', status: 'runtime', source: 'driver', detail: 'DSH updates with the OpenFish runtime.' },
      { id: 'lifecycle.rollback', status: 'unsupported', source: 'driver' },
      { id: 'lifecycle.uninstall', status: 'unsupported', source: 'driver' },
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'session.cancel', status: 'supported', source: 'driver' },
      { id: 'session.fork', status: 'supported', source: 'driver' },
      { ...HOST_ARCHIVE_CAPABILITY, detail: 'OpenFish archives the task without deleting its DSH session or durable transcript.' },
      { id: 'workspace.project', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'configuration.models', status: 'supported', source: 'runtime' },
      { id: 'configuration.reasoning', status: 'supported', source: 'runtime' },
      { id: 'configuration.auth', status: 'supported', source: 'runtime' },
      { id: 'configuration.agent-presets', status: 'supported', source: 'driver', detail: 'DSH presets configure the built-in agent composition before the first prompt.' },
      { id: 'interaction.tools', status: 'supported', source: 'driver' },
      { id: 'interaction.approvals', status: 'supported', source: 'driver' },
      { id: 'interaction.questions', status: 'supported', source: 'driver' },
      { id: 'interaction.files', status: 'supported', source: 'driver' },
      { id: 'interaction.events', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      { id: 'architecture.runtime-observation', status: observesRuntime ? 'runtime' : 'unsupported', source: 'runtime', detail: observesRuntime ? 'Only Pack-bound, content-free session signals activate declared nodes and flows.' : 'This Pack declares no runtime observation bindings.' },
      { id: 'architecture.edit', status: effectivePack.graph.level === 'composable' && effectivePack.graph.nodes.some(node => node.editable) ? 'supported' : 'unsupported', source: 'pack' },
      { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
      { id: 'builder.manifest', status: 'supported', source: 'pack' },
      { id: 'builder.test', status: 'supported', source: 'driver' },
      { id: 'builder.publish', status: 'unsupported', source: 'host', detail: 'The bundled DSH Pack is read only; fork a user-authored Pack to use the reviewed community submission workflow.' },
    ] as const
    const driverInfo = {
      apiVersion: 1 as const,
      protocol: effectivePack.protocol,
      loaded: effectivePack.protocol === 'dsh' || driver !== undefined,
      authorization: effectivePack.driverBundle === undefined
        ? 'not-required' as const
        : driverAuthorizationIssue === undefined ? 'authorized' as const : 'required' as const,
    }
    const emptyAuthoring: HarnessAuthoringContract = { nodeKinds: [], bindingKinds: [] }
    if (effectivePack.protocol === 'dsh') {
      return {
        ...effectivePack, ...publicationFields, isDefault, available: true, installation, auth, compatibility,
        capabilities: [...builtinCapabilities], authoring: emptyAuthoring, driver: driverInfo,
      }
    }
    if (driver === undefined) {
      return {
        ...effectivePack, ...publicationFields, isDefault, available: false, unavailableReason: revokedReason ?? `No ${effectivePack.protocol} driver is loaded`, installation, auth, compatibility,
        capabilities: withUserBuilderCapabilities(effectivePack, [{ id: 'architecture.manifest', status: 'supported', source: 'pack' }], false), authoring: emptyAuthoring, driver: driverInfo,
      }
    }
    let capabilities: HarnessCapability[]
    let authoring = emptyAuthoring
    try {
      const inspection = await inspectHarnessDriver(driver, effectivePack)
      capabilities = withHostCapabilities(inspection.capabilities)
      if (!inspection.compatible) {
        const reason = safeHarnessDiagnostic(
          `Harness Driver conformance failed: ${inspection.issues.join(' ')}`,
          'Driver conformance failed',
        )
        return {
          ...effectivePack,
          ...publicationFields,
          isDefault,
          available: false,
          unavailableReason: revokedReason ?? reason,
          installation,
          auth,
          compatibility: catalogCompatibility(effectivePack, { status: 'failed' as const, checkedAt: new Date().toISOString(), message: reason }),
          capabilities: withUserBuilderCapabilities(effectivePack, capabilities, false),
          authoring: emptyAuthoring,
          driver: driverInfo,
        }
      }
      authoring = inspection.authoring
    } catch (error: unknown) {
      const reason = safeHarnessDiagnostic(error, 'Driver inspection failed')
      return {
        ...effectivePack, ...publicationFields, isDefault, available: false, unavailableReason: revokedReason ?? reason, installation, auth,
        compatibility: catalogCompatibility(effectivePack, { status: 'failed' as const, checkedAt: new Date().toISOString(), message: reason }),
        capabilities: withUserBuilderCapabilities(effectivePack, withHostCapabilities([]), false),
        authoring: emptyAuthoring,
        driver: driverInfo,
      }
    }
    capabilities = withUserBuilderCapabilities(effectivePack, capabilities, driver.preflight !== undefined)
    const snapshotExpected = install?.active?.version === effectivePack.version
      || install?.previous.some(candidate => candidate.version === effectivePack.version) === true
    const snapshotIssue = snapshotExpected
      ? await managedDirectoryIssue(
        join(this.installRoot, effectivePack.id, effectivePack.version),
        `Harness "${effectivePack.id}" ${effectivePack.version} installation snapshot`,
      )
      : undefined
    const driverUnavailableReason = await inspectDriverAvailability(driver, effectivePack)
    const authenticationIssue = snapshotExpected && auth.status === 'unknown' ? auth.detail : undefined
    const unavailableReason = driverAuthorizationIssue ?? snapshotIssue ?? driverUnavailableReason ?? authenticationIssue
    const effectiveUnavailableReason = revokedReason ?? unavailableReason
    return {
      ...effectivePack, ...publicationFields,
      isDefault,
      available: revokedReason === undefined && unavailableReason === undefined,
      ...(effectiveUnavailableReason === undefined ? {} : { unavailableReason: effectiveUnavailableReason }),
      installation, auth, capabilities, authoring, driver: driverInfo,
      compatibility: catalogCompatibility(effectivePack, install?.compatibility ?? (unavailableReason === undefined
        ? { status: 'ready' as const, message: 'Launch prerequisites are present; first session has not been verified yet.' }
        : { status: 'failed' as const, checkedAt: new Date().toISOString(), message: unavailableReason })),
    }
  }

  /**
   * Install or update one Pack with a recoverable previous-version snapshot.
   * @param id - Catalog identity to install.
   * @param signal - Optional package-download cancellation.
   */
  async install(id: HarnessId, signal?: AbortSignal): Promise<void> {
    await this.initialRefresh
    signal?.throwIfAborted()
    await this.serialize(async () => {
      signal?.throwIfAborted()
      const pack = this.require(id)
      if (pack.protocol === 'dsh') return
      if (this.isRevoked(pack)) {
        const revocation = this.state.communityRevocations.find(item => item.id === pack.id && item.version === pack.version)
        throw new Error(`Harness "${pack.id}" version ${pack.version} was revoked and cannot be installed${revocation?.reason === undefined ? '' : `: ${revocation.reason}`}`)
      }
      const driver = this.drivers.get(pack.protocol)
      if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
      this.requireDriverAuthorization(pack)
      await requireConformantDriver(driver, pack)
      signal?.throwIfAborted()
      const existing = this.state.installs[pack.id]
      if (existing?.active?.version === pack.version) {
        const installationDirectory = join(this.installRoot, pack.id, pack.version)
        const issue = await managedDirectoryIssue(
          installationDirectory,
          `Harness "${pack.id}" ${pack.version} installation snapshot`,
        )
        if (issue === undefined) {
          let activePack = withCurrentAuthenticationContract(pack, existing.active)
          const needsAuthenticationDiscovery = pack.authenticationDiscovery?.source === 'runtime'
            && existing.authDiscoveries?.[pack.version] === undefined
          if (needsAuthenticationDiscovery && driver.discoverAuth !== undefined) {
            activePack = withDiscoveredAuthentication(pack, await driver.discoverAuth(
              pack,
              installationDirectory,
              await this.runtimeDirectory(pack),
            ))
            signal?.throwIfAborted()
          }
          await requireConformantDriver(driver, activePack)
          signal?.throwIfAborted()
          const unavailable = await inspectDriverAvailability(driver, activePack)
          signal?.throwIfAborted()
          if (unavailable !== undefined) throw new Error(unavailable)
          const validAuthMethod = existing.authMethod === undefined
            || (activePack.authMethods ?? []).some(method => method.id === existing.authMethod)
          if (activePack !== existing.active || !validAuthMethod || needsAuthenticationDiscovery) {
            const previousInstall = existing
            this.state.installs[pack.id] = {
              ...existing,
              active: activePack,
              ...(needsAuthenticationDiscovery
                ? { authDiscoveries: { ...existing.authDiscoveries, [pack.version]: new Date().toISOString() } }
                : {}),
            }
            if (!validAuthMethod) delete this.state.installs[pack.id]?.authMethod
            try {
              await this.saveState()
            } catch (error: unknown) {
              this.state.installs[pack.id] = previousInstall
              throw error
            }
          }
          this.transient.delete(id)
          return
        }
      }
      const retained = existing?.previous.find(candidate => candidate.version === pack.version)
      if (retained !== undefined && existing?.active !== undefined) {
        const retainedDirectory = join(this.installRoot, retained.id, retained.version)
        const issue = await managedDirectoryIssue(
          retainedDirectory,
          `Harness "${retained.id}" ${retained.version} retained installation snapshot`,
        )
        if (issue === undefined) {
          let retainedPack = withCurrentAuthenticationContract(pack, retained)
          const needsAuthenticationDiscovery = pack.authenticationDiscovery?.source === 'runtime'
            && existing.authDiscoveries?.[pack.version] === undefined
          if (needsAuthenticationDiscovery && driver.discoverAuth !== undefined) {
            retainedPack = withDiscoveredAuthentication(pack, await driver.discoverAuth(
              pack,
              retainedDirectory,
              await this.runtimeDirectory(pack),
            ))
            signal?.throwIfAborted()
          }
          await requireConformantDriver(driver, retainedPack)
          signal?.throwIfAborted()
          const unavailable = await inspectDriverAvailability(driver, retainedPack)
          signal?.throwIfAborted()
          if (unavailable !== undefined) throw new Error(unavailable)
          const authMethod = existing.authMethod !== undefined
            && (retainedPack.authMethods ?? []).some(method => method.id === existing.authMethod)
            ? existing.authMethod
            : undefined
          this.state.installs[pack.id] = {
            active: retainedPack,
            previous: [existing.active, ...existing.previous.filter(candidate => candidate.version !== retained.version)],
            ...(authMethod === undefined ? {} : { authMethod }),
            ...(existing.authDiscoveries === undefined && !needsAuthenticationDiscovery
              ? {}
              : {
                authDiscoveries: {
                  ...existing.authDiscoveries,
                  ...(needsAuthenticationDiscovery ? { [pack.version]: new Date().toISOString() } : {}),
                },
              }),
          }
          await this.saveState()
          this.transient.delete(id)
          return
        }
      }
      this.transient.set(id, {
        status: 'installing', phase: 'staging',
        detail: `Installing exact ${pack.name} ${pack.version} distribution in an isolated runtime…`,
      })
      const parentDirectory = join(this.installRoot, pack.id)
      const installationDirectory = join(parentDirectory, pack.version)
      const stagingDirectory = join(parentDirectory, `.${pack.version}.installing-${randomUUID()}`)
      const runtimeWasReferenced = existing?.active?.version === pack.version
        || existing?.previous.some(candidate => candidate.version === pack.version) === true
      let promoted = false
      let attemptedRuntimeDirectory: string | undefined
      try {
        await ensureManagedDirectory(this.installRoot, 'Harness installation root')
        await mkdir(parentDirectory, { recursive: true, mode: 0o700 })
        await requireManagedDirectory(parentDirectory, `Harness "${pack.id}" installation directory`)
        // Driver API v1 permits a local `executable` Pack without a custom
        // install hook. The Host still owns an immutable per-version snapshot
        // directory so session cwd, retention, rollback, and disposal have the
        // same lifecycle contract as package-backed Drivers.
        await mkdir(stagingDirectory, { recursive: true, mode: 0o700 })
        const runtimeDirectory = await this.runtimeDirectory(pack)
        attemptedRuntimeDirectory = runtimeDirectory
        await driver.install?.(pack, stagingDirectory, runtimeDirectory, signal)
        signal?.throwIfAborted()
        this.transient.set(id, {
          status: 'installing', phase: 'discovering-auth',
          detail: `Discovering ${pack.name} authentication methods without reading secret values…`,
        })
        const discoveredAuth = await driver.discoverAuth?.(pack, stagingDirectory, runtimeDirectory)
        signal?.throwIfAborted()
        const installedPack = discoveredAuth === undefined
          ? pack
          : withDiscoveredAuthentication(pack, discoveredAuth)
        this.transient.set(id, {
          status: 'installing', phase: 'verifying',
          detail: `Validating ${pack.name} against Driver API v1 and its declared capabilities…`,
        })
        await requireConformantDriver(driver, installedPack)
        signal?.throwIfAborted()
        const previous = existing?.active === undefined || existing.active.version === pack.version
          ? existing?.previous ?? []
          : [existing.active, ...existing.previous]
            .filter(candidate => candidate.version !== pack.version)
            .filter((candidate, index, all) => all.findIndex(other => other.version === candidate.version) === index)
        // No committed Pack references this version here: same-version active
        // and retained snapshots returned above. Replace only an orphan left
        // by an interrupted pre-transaction build, then atomically promote.
        await rm(installationDirectory, { recursive: true, force: true })
        this.transient.set(id, {
          status: 'installing', phase: 'activating',
          detail: `Activating the verified ${pack.name} ${pack.version} snapshot atomically…`,
        })
        await rename(stagingDirectory, installationDirectory)
        promoted = true
        signal?.throwIfAborted()
        this.transient.set(id, {
          status: 'installing', phase: 'health-check',
          detail: `Checking ${pack.name} launch prerequisites before committing the update…`,
        })
        const unavailable = await inspectDriverAvailability(driver, installedPack)
        signal?.throwIfAborted()
        if (unavailable !== undefined) throw new Error(unavailable)
        this.state.installs[pack.id] = {
          active: installedPack,
          previous,
          ...(existing?.authMethod === undefined ? {} : { authMethod: existing.authMethod }),
          ...(driver.discoverAuth === undefined
            ? (existing?.authDiscoveries === undefined ? {} : { authDiscoveries: existing.authDiscoveries })
            : {
              authDiscoveries: {
                ...existing?.authDiscoveries,
                [pack.version]: new Date().toISOString(),
              },
            }),
        }
        await this.saveState()
        this.transient.delete(id)
      } catch (error) {
        if (existing === undefined) Reflect.deleteProperty(this.state.installs, pack.id)
        else this.state.installs[pack.id] = existing
        await rm(stagingDirectory, { recursive: true, force: true }).catch(() => undefined)
        if (promoted) await rm(installationDirectory, { recursive: true, force: true }).catch(() => undefined)
        if (!runtimeWasReferenced && attemptedRuntimeDirectory !== undefined) {
          await removeManagedHarnessDirectory(attemptedRuntimeDirectory).catch(() => undefined)
        }
        if (signal?.aborted === true) {
          this.transient.delete(id)
          throw error
        }
        const message = safeHarnessDiagnostic(error, 'Harness installation failed')
        this.transient.set(id, { status: 'failed', error: message })
        throw new Error(message)
      }
    })
  }

  /**
   * Run a non-secret live preflight without sending a model prompt.
   * Provider-owned state or setup cost remains provider-specific.
   * @param id - Installed Harness Pack to probe.
   * @param signal - Optional cancellation for installation and protocol checks.
   */
  async probe(id: HarnessId, signal?: AbortSignal): Promise<void> {
    await this.initialRefresh
    const catalogPack = this.require(id)
    if (catalogPack.protocol === 'dsh') {
      await this.recordCompatibility(id, { status: 'compatible', checkedAt: new Date().toISOString(), message: 'Built-in runtime and Driver API v1 are loaded.' })
      return
    }
    const install = this.state.installs[id]
    if (install?.active === undefined) {
      throw new Error(`Harness "${id}" must be installed explicitly before preflight`)
    }
    const effective = withCurrentAuthenticationContract(catalogPack, install.active)
    const driver = this.drivers.get(effective.protocol)
    if (driver === undefined) throw new Error(`No ${effective.protocol} Harness driver is loaded`)
    this.requireDriverAuthorization(effective)
    await requireConformantDriver(driver, effective)
    const unavailable = await inspectDriverAvailability(driver, effective)
    if (unavailable !== undefined) throw new Error(unavailable)
    const selectedMethod = install.authMethod
    const auth = await this.authenticationState(effective, selectedMethod, driver)
    if (auth.status !== 'configured' && auth.status !== 'not-required') {
      await this.recordCompatibility(id, {
        status: 'ready', checkedAt: new Date().toISOString(),
        message: `Driver and installation passed; authentication is ${auth.status.replaceAll('-', ' ')}. Live protocol preflight was not started.`,
      })
      throw new Error(`Harness "${effective.id}" authentication is ${auth.status.replaceAll('-', ' ')}; configure an account before live preflight`)
    }
    const installationDirectory = join(this.installRoot, effective.id, effective.version)
    await requireManagedDirectory(
      installationDirectory,
      `Harness "${effective.id}" ${effective.version} installation snapshot`,
    )
    const runtimeDirectory = await this.runtimeDirectory(effective)
    const preflightDirectory = join(runtimeDirectory, 'preflight', randomUUID())
    await mkdir(preflightDirectory, { recursive: true, mode: 0o700 })
    try {
      signal?.throwIfAborted()
      const capabilities = withHostCapabilities(await requireConformantDriver(driver, effective))
      signal?.throwIfAborted()
      const result = normalizeHarnessPreflightResult(await driver.preflight?.({
        harnessId: effective.id,
        sessionId: SessionId(`openfish-preflight-${randomUUID()}`),
        cwd: preflightDirectory,
        version: effective.version,
        installationDirectory,
        runtimeDirectory,
        ...(selectedMethod === undefined ? {} : { authMethod: selectedMethod }),
        workspaceMode: 'no-project',
        capabilities,
      }, effective, signal))
      signal?.throwIfAborted()
      const message = result?.message
        ?? 'Driver API, exact installation snapshot, launch prerequisites, and authentication checks passed. This Driver does not implement a live protocol preflight.'
      await this.recordCompatibility(id, {
        status: result === undefined ? 'ready' : 'compatible', checkedAt: new Date().toISOString(), message,
      })
    } catch (error: unknown) {
      if (signal?.aborted === true) throw error
      const message = safeHarnessDiagnostic(error, 'Harness live preflight failed')
      await this.recordCompatibilityWithoutMasking(id, {
        status: 'failed', checkedAt: new Date().toISOString(), message,
      })
      throw new Error(message)
    } finally {
      await rm(preflightDirectory, { recursive: true, force: true }).catch(() => undefined)
    }
  }

  /**
   * Remove managed package files while retaining the discoverable catalog row.
   * @param id - Installed Harness identity.
   */
  async uninstall(id: HarnessId): Promise<void> {
    await this.initialRefresh
    const retainedBy = await this.sessionsReferencing(id)
    if (retainedBy.length > 0) {
      throw new Error(
        `Harness "${id}" is retained by ${retainedBy.length} task${retainedBy.length === 1 ? '' : 's'}. Retained tasks keep their exact Harness version pinned, so this installation cannot be removed yet.`,
      )
    }
    await this.serialize(async () => {
      const pack = this.require(id)
      if (pack.protocol === 'dsh') throw new Error('The built-in DSH Harness cannot be uninstalled')
      // Files are removed before the durable catalog commit. If filesystem
      // cleanup fails, the installed snapshot remains discoverable and the
      // user can retry instead of being left with an unreachable orphan.
      await removeManagedHarnessDirectory(join(this.installRoot, pack.id))
      await removeManagedHarnessDirectory(join(this.runtimeRoot, pack.id))
      const previousState = structuredClone(this.state)
      const previousTransient = this.transient.get(id)
      this.removeInstall(pack.id)
      this.transient.delete(id)
      try {
        await this.saveState()
      } catch (error: unknown) {
        this.state = previousState
        if (previousTransient === undefined) this.transient.delete(id)
        else this.transient.set(id, previousTransient)
        throw error
      }
    })
  }

  /**
   * Activate the most recently retained installed Pack snapshot.
   * @param id - Installed Harness identity.
   */
  async rollback(id: HarnessId): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const install = this.state.installs[id]
      const previous = install?.previous[0]
      if (install?.active === undefined || previous === undefined) throw new Error(`Harness "${id}" has no rollback version`)
      this.requireDriverAuthorization(previous)
      const driver = this.drivers.get(previous.protocol)
      if (driver === undefined) throw new Error(`No ${previous.protocol} Harness driver is loaded`)
      await requireConformantDriver(driver, previous)
      const unavailable = await inspectDriverAvailability(driver, previous)
      if (unavailable !== undefined) throw new Error(unavailable)
      await requireManagedDirectory(
        join(this.installRoot, previous.id, previous.version),
        `Harness "${previous.id}" ${previous.version} rollback snapshot`,
      )
      install.previous = [install.active, ...install.previous.slice(1)]
      install.active = previous
      if (install.authMethod !== undefined
        && !(previous.authMethods ?? []).some(method => method.id === install.authMethod)) {
        delete install.authMethod
      }
      delete install.compatibility
      await this.saveState()
    })
  }

  /**
   * Persist a non-secret authentication preference for the next launch.
   * @param id - Harness whose login mode is selected.
   * @param method - Pack-declared method id, or absent to clear the preference.
   */
  async selectAuth(id: HarnessId, method?: string): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const catalogPack = this.require(id)
      const pack = this.state.installs[catalogPack.id]?.active ?? catalogPack
      if (method !== undefined && !(pack.authMethods ?? []).some(candidate => candidate.id === method)) {
        throw new Error(`Harness "${id}" does not declare authentication method "${method}"`)
      }
      const install = this.state.installs[pack.id] ?? { previous: [] }
      this.state.installs[pack.id] = { ...install, ...(method === undefined ? {} : { authMethod: method }) }
      if (method === undefined) delete this.state.installs[pack.id]?.authMethod
      await this.saveState()
    })
  }

  /**
   * Launch one explicitly selected interactive authentication flow.
   * @param id - Installed Harness whose terminal login should run.
   * @param methodId - Pack-declared terminal authentication method.
   * @param signal - Optional cancellation forwarded to the Driver login flow.
   */
  async authenticateInteractive(id: HarnessId, methodId: string, signal?: AbortSignal): Promise<void> {
    await this.initialRefresh
    const pack = this.require(id)
    const install = this.state.installs[pack.id]
    const active = pack.protocol === 'dsh' ? pack : install?.active
    if (active === undefined) throw new Error(`Harness "${id}" must be installed before login`)
    const method = active.authMethods?.find(candidate => candidate.id === methodId)
    if (method?.kind !== 'terminal') throw new Error(`Harness "${id}" does not declare terminal authentication method "${methodId}"`)
    const driver = this.drivers.get(active.protocol)
    if (driver?.authenticateInteractive === undefined) throw new Error(`The ${active.protocol} driver cannot run interactive authentication`)
    this.requireDriverAuthorization(active)
    await requireConformantDriver(driver, active)
    const unavailable = await inspectDriverAvailability(driver, active)
    if (unavailable !== undefined) throw new Error(unavailable)
    const installationDirectory = join(this.installRoot, active.id, active.version)
    await requireManagedDirectory(
      installationDirectory,
      `Harness "${active.id}" ${active.version} installation snapshot`,
    )
    try {
      await driver.authenticateInteractive(
        active,
        installationDirectory,
        await this.runtimeDirectory(active),
        method,
        signal,
      )
    } catch (error: unknown) {
      if (signal?.aborted === true) throw error
      throw new Error(safeHarnessDiagnostic(error, 'Harness sign-in failed'))
    }
    const authentication = await this.authenticationState(active, methodId, driver)
    if (authentication.status !== 'configured') {
      throw new Error(`Harness sign-in did not become ready: ${authentication.detail}`)
    }
    await this.selectAuth(id, methodId)
  }

  /**
   * Persist the cross-device default chosen by native Open Fish clients.
   * @param id - Harness to use for new tasks by default.
   */
  async selectDefault(id: HarnessId): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const catalogPack = this.require(id)
      const selectedPack = withCurrentAuthenticationContract(
        catalogPack,
        this.state.installs[id]?.active ?? catalogPack,
      )
      if (this.isRevoked(selectedPack)) {
        throw new Error(`Harness "${id}" version ${selectedPack.version} was revoked and cannot become the default`)
      }
      if (catalogPack.protocol !== 'dsh') {
        const installedPack = this.state.installs[id]?.active
        if (installedPack === undefined) throw new Error(`Harness "${id}" must be installed before it can become the default`)
        const pack = withCurrentAuthenticationContract(catalogPack, installedPack)
        const driver = this.drivers.get(pack.protocol)
        if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
        this.requireDriverAuthorization(pack)
        await requireConformantDriver(driver, pack)
        const unavailable = await inspectDriverAvailability(driver, pack)
        if (unavailable !== undefined) throw new Error(unavailable)
        const authMethod = this.state.installs[id]?.authMethod
        const authentication = await this.authenticationState(pack, authMethod, driver)
        if (authentication.status === 'needs-selection') {
          throw new Error(`Harness "${id}" requires an explicit authentication method before it can become the default`)
        }
        if (authentication.status === 'needs-credentials') {
          throw new Error(`Harness "${id}" is not authenticated: ${authentication.detail}`)
        }
        if (authentication.status === 'unknown') {
          throw new Error(`Harness "${id}" did not expose an authentication discovery method and cannot become the default`)
        }
      }
      this.state.defaultHarnessId = id
      await this.saveState()
    })
  }

  /** Explicitly clear the default so first-run clients must ask the user. */
  async clearDefault(): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      delete this.state.defaultHarnessId
      await this.saveState()
    })
  }

  /**
   * Read the explicit cross-device default.
   * @returns Selected Harness id, or absent before onboarding completes.
   */
  async defaultId(): Promise<HarnessId | undefined> {
    await this.initialRefresh
    await this.mutation
    const id = this.state.defaultHarnessId as HarnessId | undefined
    if (id === undefined) return undefined
    const catalogPack = this.packs.get(id)
    if (catalogPack === undefined) return undefined
    if (catalogPack.protocol === 'dsh') return id
    const installedPack = this.state.installs[id]?.active
    if (installedPack === undefined) return undefined
    const pack = withCurrentAuthenticationContract(catalogPack, installedPack)
    if (this.isRevoked(pack)) return undefined
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) return undefined
    if (this.driverAuthorizationIssue(pack) !== undefined) return undefined
    try {
      await requireConformantDriver(driver, pack)
      if (await inspectDriverAvailability(driver, pack) !== undefined) return undefined
      const auth = await this.authenticationState(pack, this.state.installs[id]?.authMethod, driver)
      return auth.status === 'not-required' || auth.status === 'configured' ? id : undefined
    } catch {
      return undefined
    }
  }

  /**
   * Create or replace one user Pack without editing Open Fish source.
   * @param input - Untrusted Pack v0 document from the graphical editor or API.
   * @returns Admitted user Pack.
   */
  async upsert(input: unknown): Promise<HarnessPack> {
    await this.initialRefresh
    if (typeof input !== 'object' || input === null || Array.isArray(input)) throw new Error('A custom Harness Pack must be an object')
    const pack = parseHarnessPack({ ...input, source: 'user', verified: false })
    const admissionIssue = customPackAdmissionIssue(pack)
    if (admissionIssue !== undefined) throw new Error(admissionIssue)
    await this.serialize(async () => {
      const index = this.state.customPacks.findIndex(item => item.id === pack.id)
      if (index === -1) this.state.customPacks.push(pack)
      else this.state.customPacks[index] = pack
      this.packs.set(pack.id, pack)
      await this.saveState()
    })
    return pack
  }

  /**
   * Validate one public community submission without mutating the local catalog.
   * @param input - Untrusted Pack-shaped publication payload.
   * @returns Exact installed, preflighted, and admitted Pack safe to submit for review.
   */
  async validatePublication(input: unknown): Promise<HarnessPack> {
    await this.initialRefresh
    const pack = prepareHarnessPublication(input)
    const local = this.require(pack.id)
    if (local.source !== 'user' || local.version !== pack.version) {
      throw new Error('Community publication requires the exact current user-authored Pack version')
    }
    const installation = this.state.installs[pack.id]
    if (installation?.active?.version !== pack.version) {
      throw new Error(`Harness Pack "${pack.id}" version ${pack.version} must be installed before publication`)
    }
    if (installation.compatibility?.status !== 'ready' && installation.compatibility?.status !== 'compatible') {
      throw new Error(`Harness Pack "${pack.id}" must pass its prompt-free live preflight before publication`)
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) {
      throw new Error(`Harness Pack "${pack.id}" cannot be published from this Host because no ${pack.protocol} Driver is loaded`)
    }
    this.requireDriverAuthorization(pack)
    await requireConformantDriver(driver, pack)
    return pack
  }

  /**
   * Persist the review identity returned by the documented community backend.
   * This method records no credential or Pack content and never treats a
   * submitted review as catalog inclusion.
   *
   * @param input - Exact local Pack identity and GitHub review facts.
   */
  async recordCommunitySubmission(input: HarnessCommunitySubmissionRecord): Promise<void> {
    await this.initialRefresh
    const candidate = storedCommunitySubmission(input)
    if (candidate === undefined) throw new Error('Community submission record is invalid')
    const pack = this.require(candidate.id)
    if (pack.source !== 'user' || pack.version !== candidate.version) {
      throw new Error('Community submission must reference the exact current user-authored Pack version')
    }
    await this.serialize(async () => {
      this.state.communitySubmissions = this.state.communitySubmissions.filter(item =>
        item.id !== candidate.id || item.version !== candidate.version)
      this.state.communitySubmissions.push(candidate)
      await this.saveState()
    })
  }

  /**
   * Persist the public review identity for an exact-version revocation request.
   * @param input - Exact local Pack identity and GitHub revocation review facts.
   */
  async recordCommunityRevocationSubmission(input: HarnessCommunitySubmissionRecord): Promise<void> {
    await this.initialRefresh
    const candidate = storedCommunitySubmission(input)
    if (candidate === undefined) throw new Error('Community revocation submission record is invalid')
    const pack = this.require(candidate.id)
    const published = this.state.communityPacks.some(item =>
      item.id === candidate.id && item.version === candidate.version)
    if (!published || pack.version !== candidate.version) {
      throw new Error('Community revocation must reference an exact currently-published Pack version')
    }
    if (this.state.communityRevocations.some(item =>
      item.id === candidate.id && item.version === candidate.version)) {
      throw new Error('This exact Harness Pack version is already revoked')
    }
    await this.serialize(async () => {
      this.state.communityRevocationSubmissions = this.state.communityRevocationSubmissions.filter(item =>
        item.id !== candidate.id || item.version !== candidate.version)
      this.state.communityRevocationSubmissions.push(candidate)
      await this.saveState()
    })
  }

  /**
   * Remove one user-authored Pack definition.
   * @param id - User Pack identity.
   */
  async removeUserPack(id: HarnessId): Promise<void> {
    await this.initialRefresh
    const retainedBy = await this.sessionsReferencing(id)
    if (retainedBy.length > 0) {
      throw new Error(
        `Harness Pack "${id}" is retained by ${retainedBy.length} task${retainedBy.length === 1 ? '' : 's'}. Retained tasks keep their exact Harness version pinned, so this Pack cannot be removed yet.`,
      )
    }
    await this.serialize(async () => {
      const pack = this.require(id)
      if (pack.source !== 'user') throw new Error('Only user Harness Packs can be removed')
      // Preserve the Pack and its catalog row until both Host-owned roots are
      // gone. This keeps a failed cleanup recoverable through the same UI.
      await removeManagedHarnessDirectory(join(this.installRoot, id))
      await removeManagedHarnessDirectory(join(this.runtimeRoot, id))
      const previousState = structuredClone(this.state)
      this.state.customPacks = this.state.customPacks.filter(item => item.id !== id)
      this.removeInstall(id)
      if (this.state.defaultHarnessId === id) delete this.state.defaultHarnessId
      this.packs.delete(id)
      try {
        await this.saveState()
      } catch (error: unknown) {
        this.state = previousState
        this.packs.set(id, pack)
        throw error
      }
    })
  }

  /**
   * Resolve a Pack by stable id.
   * @param id - Exact Pack identity.
   * @returns Admitted Pack definition.
   */
  require(id: HarnessId): HarnessPack {
    const pack = this.packs.get(id)
    if (pack === undefined) throw new Error(`Unknown Harness Pack "${id}"`)
    return pack
  }

  /**
   * Resolve the exact Pack and effect-scoped Driver used to project one task's runtime evidence.
   * @param id - Stable Harness Pack identity.
   * @param version - Optional exact installed version pinned by a task.
   * @returns Matching runtime binding, or undefined when the identity is unavailable.
   */
  runtimeBinding(id: HarnessId, version?: string): { pack: HarnessPack; driver?: HarnessDriver } | undefined {
    const catalogPack = this.packs.get(id)
    if (catalogPack === undefined) return undefined
    const install = this.state.installs[id]
    const pack = version === undefined
      ? install?.active ?? catalogPack
      : [catalogPack.protocol === 'dsh' ? catalogPack : undefined, install?.active, ...(install?.previous ?? [])]
        .find(candidate => candidate?.version === version)
    if (pack === undefined) return undefined
    const driver = this.drivers.get(pack.protocol)
    return { pack, ...(driver === undefined ? {} : { driver }) }
  }

  private removeInstall(id: HarnessId): void {
    this.state.installs = Object.fromEntries(Object.entries(this.state.installs).filter(([key]) => key !== id))
  }

  /** Keep mutable Harness state version-scoped so an update can be rolled back intact. */
  private async runtimeDirectory(pack: HarnessPack): Promise<string> {
    const legacy = join(this.runtimeRoot, pack.id)
    const versioned = join(legacy, pack.version)
    await ensureManagedDirectory(this.runtimeRoot, 'Harness runtime root')
    await ensureManagedDirectory(legacy, `Harness "${pack.id}" runtime directory`)
    // Builds before version-scoped runtime state wrote these five private
    // roots directly beneath the Harness id. Move that local state once so an
    // existing login is preserved without letting the next version mutate it.
    const legacyRoots = ['home', 'cache', 'config', 'data', 'tmp']
    const hasLegacyState = await Promise.all(legacyRoots.map(async (name) => {
      try {
        const information = await lstat(join(legacy, name))
        if (information.isSymbolicLink()) {
          throw new Error(`Harness "${pack.id}" legacy runtime ${name} was replaced by a symbolic link`)
        }
        return information.isDirectory()
      } catch (error: unknown) {
        if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false
        throw error
      }
    })).then(results => results.some(Boolean))
    if (hasLegacyState) {
      await ensureManagedDirectory(versioned, `Harness "${pack.id}" ${pack.version} runtime directory`)
      for (const name of legacyRoots) {
        try { await rename(join(legacy, name), join(versioned, name)) } catch (error) {
          const code = (error as NodeJS.ErrnoException).code
          if (code !== 'ENOENT' && code !== 'EEXIST') throw error
        }
      }
    }
    await ensureManagedDirectory(versioned, `Harness "${pack.id}" ${pack.version} runtime directory`)
    return versioned
  }

  /** Return every live or durable task pinned to a Harness before destructive lifecycle work. */
  private async sessionsReferencing(id: HarnessId): Promise<SessionId[]> {
    const matches = new Set<SessionId>()
    const live = this.ctx.sessions.list()
    const liveIds = new Set(live.map(session => session.id))
    for (const session of live) {
      const selected = session.events.findLast(event => event.type === 'harness/selected')
      if (selected?.data.harnessId === id) matches.add(session.id)
    }
    const persistence = this.ctx.get('sessionPersistence')
    if (persistence === undefined) return [...matches]
    for (const header of await persistence.list()) {
      if (liveIds.has(header.id)) continue
      const stored = await persistence.load(header.id)
      const selected = stored.events.findLast(event => event.type === 'harness/selected')
      if (selected?.data.harnessId === id) matches.add(header.id)
    }
    return [...matches]
  }

  /**
   * Create a non-DSH session through its registered protocol driver.
   * @param id - Selected Harness Pack identity.
   * @param sessionId - New local session identity.
   * @param cwd - Absolute session working directory.
   * @param workspaceMode - Explicit project or no-project workspace contract.
   * @param signal - Optional cancellation for creation and live capability discovery.
   * @returns Published external Agent.
   */
  async create(
    id: HarnessId,
    sessionId: SessionId,
    cwd: string,
    workspaceMode?: HarnessSessionRequest['workspaceMode'],
    signal?: AbortSignal,
  ): Promise<Agent> {
    return await this.driverRequest('create', {
      harnessId: id, sessionId, cwd,
      ...(workspaceMode === undefined ? {} : { workspaceMode }),
    }, signal)
  }

  /**
   * Resume a persisted non-DSH session through its registered protocol driver.
   * @param id - Persisted Harness Pack identity.
   * @param sessionId - Existing local session identity.
   * @param cwd - Persisted absolute working directory.
   * @param version - Exact installed Pack version recorded by the session.
   * @param authMethod - Exact non-secret authentication choice recorded by the session.
   * @param workspaceMode - Persisted project or no-project workspace contract.
   * @param signal - Optional cancellation for resume and live capability discovery.
   * @returns Restored external Agent.
   */
  async resume(
    id: HarnessId,
    sessionId: SessionId,
    cwd: string,
    version?: string,
    authMethod?: string,
    workspaceMode?: HarnessSessionRequest['workspaceMode'],
    signal?: AbortSignal,
  ): Promise<Agent> {
    return await this.driverRequest('resume', {
      harnessId: id,
      sessionId,
      cwd,
      ...(version === undefined ? {} : { version }),
      ...(authMethod === undefined ? {} : { authMethod }),
      ...(workspaceMode === undefined ? {} : { workspaceMode }),
    }, signal)
  }

  /**
   * Fork one external Harness through its protocol Driver. The Driver owns
   * both the real remote branch and publication of the local seeded Agent;
   * this service still owns exact-version, authentication, installation, and
   * capability admission.
   * @param id - Persisted Harness Pack identity.
   * @param sourceSessionId - Existing local source task identity.
   * @param sessionId - New local child task identity.
   * @param cwd - Absolute working directory for the child task.
   * @param seed - Durable source events copied into the child task.
   * @param version - Exact installed Pack version pinned by the source task.
   * @param authMethod - Exact non-secret authentication choice pinned by the source task.
   * @param workspaceMode - Project or no-project workspace contract pinned by the source task.
   * @returns Published external child Agent.
   */
  async fork(
    id: HarnessId,
    sourceSessionId: SessionId,
    sessionId: SessionId,
    cwd: string,
    seed: SessionEvent[],
    version?: string,
    authMethod?: string,
    workspaceMode?: HarnessSessionRequest['workspaceMode'],
  ): Promise<Agent> {
    await this.initialRefresh
    const catalogPack = this.require(id)
    let pack = catalogPack
    if (pack.protocol === 'dsh') throw new Error('The DSH Harness is forked by the native AgentLoop')
    const install = this.state.installs[pack.id]
    if (install?.active === undefined) {
      throw new Error(`Harness "${pack.id}" must be installed explicitly before forking a task`)
    }
    const sourceSelection = seed.findLast(event => event.type === 'harness/selected')?.data
    if (sourceSelection === undefined || sourceSelection.harnessId !== pack.id) {
      throw new Error(`Harness "${pack.id}" fork seed does not contain the pinned source identity`)
    }
    if (version !== undefined && sourceSelection.version !== version) {
      throw new Error(`Harness "${pack.id}" fork version does not match the pinned source task`)
    }
    const pinnedVersion = version ?? sourceSelection.version
    const pinned = [install.active, ...install.previous].find(candidate => candidate.version === pinnedVersion)
    if (pinned === undefined) throw new Error(`Harness "${pack.id}" version ${pinnedVersion} is not installed`)
    pack = withCurrentAuthenticationContract(catalogPack, pinned)
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    this.requireDriverAuthorization(pack)
    const negotiatedCapabilities = withHostCapabilities(await requireConformantDriver(driver, pack))
    if (sourceSelection.version !== pack.version || sourceSelection.protocol !== pack.protocol) {
      throw new Error(`Harness "${pack.id}" fork seed does not contain the exact pinned source identity`)
    }
    if (authMethod !== undefined && sourceSelection.authMethod !== authMethod) {
      throw new Error(`Harness "${pack.id}" fork authentication does not match the pinned source task`)
    }
    if (workspaceMode !== undefined && sourceSelection.workspaceMode !== workspaceMode) {
      throw new Error(`Harness "${pack.id}" fork workspace mode does not match the pinned source task`)
    }
    const capabilities = withHostCapabilities(sourceSelection.capabilities ?? negotiatedCapabilities)
    if (driver.fork === undefined
      || !negotiatedCapabilities.some(capability => capability.id === 'session.fork' && capability.status !== 'unsupported')
      || !capabilities.some(capability => capability.id === 'session.fork' && capability.status !== 'unsupported')) {
      throw new Error(`Harness "${pack.id}" does not expose a real remote-session fork through its Driver`)
    }
    const selectedWorkspaceMode = sourceSelection.workspaceMode ?? workspaceMode
    const requiredWorkspaceCapability = selectedWorkspaceMode === 'no-project'
      ? 'workspace.no-project'
      : selectedWorkspaceMode === undefined ? undefined : 'workspace.project'
    if (requiredWorkspaceCapability !== undefined
      && !capabilities.some(capability => capability.id === requiredWorkspaceCapability && capability.status !== 'unsupported')) {
      throw new Error(`Harness "${pack.id}" does not support ${selectedWorkspaceMode} tasks`)
    }
    const unavailable = await inspectDriverAvailability(driver, pack)
    if (unavailable !== undefined) throw new Error(unavailable)
    const selectedAuth = sourceSelection.authMethod ?? authMethod ?? install.authMethod
    const authentication = await this.authenticationState(pack, selectedAuth, driver)
    if (authentication.status === 'needs-selection') throw new Error(`Harness "${pack.id}" requires an explicit authentication method`)
    if (authentication.status === 'needs-credentials') {
      throw new Error(`Harness "${pack.id}" is not authenticated: ${authentication.detail}`)
    }
    if (authentication.status === 'unknown') {
      throw new Error(`Harness "${pack.id}" authentication is unknown; install it and let its Driver discover the available sign-in methods before starting a task`)
    }
    const request: HarnessForkRequest = {
      harnessId: pack.id,
      sourceSessionId,
      sessionId,
      cwd,
      seed,
      version: pack.version,
      installationDirectory: join(this.installRoot, pack.id, pack.version),
      runtimeDirectory: await this.runtimeDirectory(pack),
      capabilities,
      ...(selectedAuth === undefined ? {} : { authMethod: selectedAuth }),
      ...(selectedWorkspaceMode === undefined ? {} : { workspaceMode: selectedWorkspaceMode }),
    }
    let agent: Agent
    try {
      agent = await driver.fork(request, pack)
      await this.requireDriverSession(agent, request, pack, driver, 'fork')
    } catch (error: unknown) {
      const message = safeHarnessDiagnostic(error, 'Harness fork failed')
      await this.recordCompatibilityWithoutMasking(pack.id, {
        status: 'failed', checkedAt: new Date().toISOString(),
        message,
      })
      throw new Error(message)
    }
    await this.recordCompatibilityWithoutMasking(pack.id, {
      status: 'compatible', checkedAt: new Date().toISOString(),
    })
    return agent
  }

  /**
   * Stop and detach one live external Harness session through the exact Driver
   * and Pack version that created it. This is an in-memory lifecycle action;
   * the durable transcript remains available for a later resume.
   * @param id - Persisted Harness Pack identity.
   * @param sessionId - Live local task identity to detach.
   * @param version - Optional exact installed Pack version pinned by the task.
   */
  async disposeSession(id: HarnessId, sessionId: SessionId, version?: string): Promise<void> {
    await this.initialRefresh
    let pack = this.require(id)
    const install = this.state.installs[pack.id]
    if (version !== undefined) {
      const pinned = [install?.active, ...(install?.previous ?? [])]
        .find(candidate => candidate?.version === version)
      if (pinned === undefined) {
        throw new Error(`Harness "${pack.id}" version ${version} is not installed`)
      }
      pack = pinned
    } else {
      pack = install?.active ?? pack
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    this.requireDriverAuthorization(pack)
    await requireConformantDriver(driver, pack)
    try {
      await driver.dispose(sessionId, pack)
    } catch (error: unknown) {
      throw new Error(safeHarnessDiagnostic(error, 'Harness session disposal failed'))
    }
  }

  /**
   * Permanently discard one live, never-started external Harness draft.
   * Unlike ordinary disposal, a Driver may use this boundary to remove a
   * provider-side thread that it had to create for live model/configuration
   * discovery. The API Proxy proves the task is blank before calling here.
   * @param id - Persisted Harness Pack identity.
   * @param sessionId - Blank local draft identity to discard.
   * @param version - Optional exact installed Pack version pinned by the draft.
   */
  async discardSession(id: HarnessId, sessionId: SessionId, version?: string): Promise<void> {
    await this.initialRefresh
    let pack = this.require(id)
    const install = this.state.installs[pack.id]
    if (version !== undefined) {
      const pinned = [install?.active, ...(install?.previous ?? [])]
        .find(candidate => candidate?.version === version)
      if (pinned === undefined) {
        throw new Error(`Harness "${pack.id}" version ${version} is not installed`)
      }
      pack = pinned
    } else {
      pack = install?.active ?? pack
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    this.requireDriverAuthorization(pack)
    await requireConformantDriver(driver, pack)
    try {
      if (driver.discard === undefined) await driver.dispose(sessionId, pack)
      else await driver.discard(sessionId, pack)
    } catch (error: unknown) {
      throw new Error(safeHarnessDiagnostic(error, 'Harness draft discard failed'))
    }
  }

  private async driverRequest(
    operation: 'create' | 'resume',
    request: HarnessSessionRequest,
    signal?: AbortSignal,
  ): Promise<Agent> {
    signal?.throwIfAborted()
    const catalogPack = this.require(request.harnessId)
    let pack = catalogPack
    if (pack.protocol === 'dsh') throw new Error('The DSH Harness is created by the native AgentLoop')
    if (this.state.installs[pack.id]?.active === undefined) {
      throw new Error(`Harness "${pack.id}" must be installed explicitly before creating a task`)
    }
    const install = this.state.installs[pack.id]
    if (request.version !== undefined) {
      const pinned = [install?.active, ...(install?.previous ?? [])].find(candidate => candidate?.version === request.version)
      if (pinned === undefined) {
        throw new Error(`Harness "${pack.id}" version ${request.version} is not installed; restore that version or fork the task onto a current Harness`)
      }
      pack = withCurrentAuthenticationContract(catalogPack, pinned)
    } else {
      pack = withCurrentAuthenticationContract(catalogPack, install?.active ?? pack)
    }
    if (operation === 'create' && this.isRevoked(pack)) {
      throw new Error(`Harness "${pack.id}" version ${pack.version} was revoked and cannot start new tasks; update the Harness or choose another one`)
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    this.requireDriverAuthorization(pack)
    const capabilities = withHostCapabilities(await requireConformantDriver(driver, pack))
    signal?.throwIfAborted()
    const requiredWorkspaceCapability = request.workspaceMode === 'no-project'
      ? 'workspace.no-project'
      : request.workspaceMode === undefined ? undefined : 'workspace.project'
    if (requiredWorkspaceCapability !== undefined
      && !capabilities.some(capability => capability.id === requiredWorkspaceCapability && capability.status !== 'unsupported')) {
      throw new Error(`Harness "${pack.id}" does not support ${request.workspaceMode} tasks`)
    }
    const unavailable = await inspectDriverAvailability(driver, pack)
    signal?.throwIfAborted()
    if (unavailable !== undefined) throw new Error(unavailable)
    const authMethod = request.authMethod ?? this.state.installs[pack.id]?.authMethod
    const authentication = await this.authenticationState(pack, authMethod, driver)
    signal?.throwIfAborted()
    if (authentication.status === 'needs-selection') throw new Error(`Harness "${pack.id}" requires an explicit authentication method`)
    if (authentication.status === 'needs-credentials') {
      throw new Error(`Harness "${pack.id}" is not authenticated: ${authentication.detail}`)
    }
    if (authentication.status === 'unknown') {
      throw new Error(`Harness "${pack.id}" authentication is unknown; install it and let its Driver discover the available sign-in methods before starting a task`)
    }
    const installationDirectory = join(this.installRoot, pack.id, pack.version)
    await requireManagedDirectory(
      installationDirectory,
      `Harness "${pack.id}" ${pack.version} installation snapshot`,
    )
    const runtimeDirectory = await this.runtimeDirectory(pack)
    let agent: Agent
    try {
      agent = await driver[operation]({
        ...request,
        installationDirectory,
        runtimeDirectory,
        capabilities,
        ...(authMethod === undefined ? {} : { authMethod }),
      }, pack, signal)
      await this.requireDriverSession(
        agent,
        { ...request, capabilities, ...(authMethod === undefined ? {} : { authMethod }) },
        pack,
        driver,
        operation,
      )
    } catch (error: unknown) {
      if (signal !== undefined && abortSignalIsAborted(signal)) throw error
      const message = safeHarnessDiagnostic(error, 'Harness session failed')
      await this.recordCompatibilityWithoutMasking(pack.id, {
        status: 'failed', checkedAt: new Date().toISOString(),
        message,
      })
      throw new Error(message)
    }
    await this.recordCompatibilityWithoutMasking(pack.id, {
      status: 'compatible', checkedAt: new Date().toISOString(),
    })
    return agent
  }

  /**
   * Enforce the session identity a Driver promised before native clients can
   * address it. A malformed Driver must not leave an invisible process or
   * provider-side draft after returning the wrong task, cwd, or Pack pin.
   */
  private async requireDriverSession(
    agent: Agent,
    request: HarnessSessionRequest,
    pack: HarnessPack,
    driver: HarnessDriver,
    operation: 'create' | 'resume' | 'fork',
  ): Promise<void> {
    const issues: string[] = []
    try {
      if (String(agent.id) !== String(request.sessionId)) issues.push(`Agent id is "${agent.id}" instead of "${request.sessionId}"`)
      if (String(agent.session.header.id) !== String(request.sessionId)) {
        issues.push(`Session id is "${agent.session.header.id}" instead of "${request.sessionId}"`)
      }
      if (agent.session.header.cwd !== request.cwd) {
        issues.push(`Session cwd is "${agent.session.header.cwd ?? 'missing'}" instead of the admitted workspace`)
      }
      if (this.ctx.sessions.get(request.sessionId) !== agent.session) {
        issues.push('Driver did not publish the exact returned Session through the Host SessionStore')
      }
      const selected = agent.session.events.findLast(event => event.type === 'harness/selected')?.data
      if (selected === undefined) issues.push('Session has no durable harness/selected identity')
      else {
        if (selected.harnessId !== pack.id) issues.push(`Session selected Harness "${selected.harnessId}" instead of "${pack.id}"`)
        if (selected.version !== pack.version) issues.push(`Session selected version "${selected.version}" instead of "${pack.version}"`)
        if (selected.protocol !== pack.protocol) issues.push(`Session selected protocol "${selected.protocol}" instead of "${pack.protocol}"`)
        if (request.workspaceMode !== undefined && selected.workspaceMode !== request.workspaceMode) {
          issues.push(`Session workspace mode is "${selected.workspaceMode ?? 'missing'}" instead of "${request.workspaceMode}"`)
        }
        if (request.authMethod !== undefined && selected.authMethod !== request.authMethod) {
          issues.push(`Session authentication method is "${selected.authMethod ?? 'missing'}" instead of the admitted method`)
        }
        if (selected.remoteSessionId !== undefined
          && (typeof selected.remoteSessionId !== 'string' || selected.remoteSessionId.length === 0)) {
          issues.push('Session pinned an invalid remote Harness identity')
        }
        if (operation === 'create') {
          if (selected.capabilities === undefined) {
            issues.push('New Session did not pin its negotiated capability snapshot')
          } else if (JSON.stringify(selected.capabilities) !== JSON.stringify(request.capabilities ?? [])) {
            issues.push('New Session capability snapshot differs from the admitted Driver contract')
          }
          if (selected.authMethod !== request.authMethod) {
            issues.push('New Session authentication method differs from the admitted selection')
          }
          if (selected.workspaceMode !== request.workspaceMode) {
            issues.push('New Session workspace mode differs from the admitted location contract')
          }
        }
      }
    } catch (error: unknown) {
      issues.push(`Driver result could not be inspected: ${safeHarnessDiagnostic(error, 'invalid Agent or Session object')}`)
    }
    if (issues.length === 0) return
    let cleanupIssue: string | undefined
    try {
      if (operation === 'resume' || driver.discard === undefined) await driver.dispose(request.sessionId, pack)
      else await driver.discard(request.sessionId, pack)
    } catch (error: unknown) {
      cleanupIssue = safeHarnessDiagnostic(error, 'Driver cleanup failed')
    }
    throw new Error(
      `Harness Driver returned an invalid ${operation} result: ${issues.join('. ')}.`
        + (cleanupIssue === undefined ? '' : ` Cleanup also failed: ${cleanupIssue}`),
    )
  }

  private async authenticationState(
    pack: HarnessPack,
    selectedMethod: string | undefined,
    driver: HarnessDriver | undefined,
  ): Promise<{
    status: 'unknown' | 'not-required' | 'needs-selection' | 'needs-credentials' | 'configured'
    missingFields: string[]
    detail: string
  }> {
    const methods = pack.authMethods ?? []
    if (methods.length === 0) {
      if (pack.authenticationDiscovery?.source === 'runtime') {
        const install = this.state.installs[pack.id]
        const installedVersion = [install?.active, ...(install?.previous ?? [])]
          .some(candidate => candidate?.version === pack.version)
        const discoveryCompleted = install?.authDiscoveries?.[pack.version] !== undefined
        if (!installedVersion || driver?.discoverAuth === undefined || !discoveryCompleted) {
          return {
            status: 'unknown', missingFields: [],
            detail: pack.authenticationDiscovery.detail,
          }
        }
        return {
          status: 'not-required', missingFields: [],
          detail: 'The installed Harness completed authentication discovery and advertised no required sign-in method.',
        }
      }
      return {
        status: 'not-required', missingFields: [],
        detail: pack.authenticationDiscovery?.detail ?? 'This Pack declares that no Harness-level sign-in is required.',
      }
    }
    if (selectedMethod === undefined) {
      return {
        status: 'needs-selection', missingFields: [],
        detail: 'Choose one of the authentication methods advertised by this Harness.',
      }
    }
    if (!methods.some(method => method.id === selectedMethod)) {
      return {
        status: 'needs-selection', missingFields: [],
        detail: 'The previously selected authentication method is no longer advertised by this Harness.',
      }
    }
    const locations = {
      installationDirectory: join(this.installRoot, pack.id, pack.version),
      runtimeDirectory: join(this.runtimeRoot, pack.id, pack.version),
    }
    const method = methods.find(candidate => candidate.id === selectedMethod)
    if (driver?.missingCredentials === undefined) {
      if (method !== undefined && method.kind !== 'terminal'
        && !method.fields.some(field => field.required)) {
        return {
          status: 'configured', missingFields: [],
          detail: 'The selected protocol-owned authentication method has no Host credential fields.',
        }
      }
      return {
        status: 'unknown', missingFields: [],
        detail: 'The loaded Harness Driver cannot prove whether the selected authentication method is ready.',
      }
    }
    let rawMissing: unknown
    try {
      rawMissing = await driver.missingCredentials(pack, selectedMethod, locations)
    } catch (error: unknown) {
      return {
        status: 'unknown', missingFields: [],
        detail: safeHarnessDiagnostic(error, 'Harness credential-readiness inspection failed'),
      }
    }
    const permittedRefs = new Set([
      ...(method?.fields.map(field => field.ref) ?? []),
      ...(method === undefined ? [] : [`auth-state:${method.id}`]),
      ...(method?.kind === 'terminal' ? [`terminal-login:${method.id}`] : []),
    ])
    if (!Array.isArray(rawMissing)
      || rawMissing.some(ref => typeof ref !== 'string' || !permittedRefs.has(ref))) {
      return {
        status: 'unknown', missingFields: [],
        detail: 'The Harness Driver returned an invalid credential-readiness result.',
      }
    }
    const missingFields = [...new Set(rawMissing as string[])]
    const missingHarnessState = missingFields.some(ref => ref.startsWith('auth-state:') || ref.startsWith('terminal-login:'))
    return missingFields.length === 0
      ? { status: 'configured', missingFields, detail: 'The selected authentication method is ready on this Host.' }
      : {
        status: 'needs-credentials', missingFields,
        detail: missingHarnessState
          ? `Complete “${method?.name ?? selectedMethod}” sign-in on this Host.`
          : 'Enter the required credentials for the selected authentication method.',
      }
  }

  private async recordCompatibility(id: HarnessId, compatibility: NonNullable<StoredInstall['compatibility']>): Promise<void> {
    await this.serialize(async () => {
      const existing = this.state.installs[id] ?? { previous: [] }
      this.state.installs[id] = {
        ...existing,
        compatibility: {
          ...compatibility,
          ...(compatibility.message === undefined
            ? {}
            : { message: safeHarnessDiagnostic(compatibility.message, 'Harness compatibility check failed') }),
        },
      }
      await this.saveState()
    })
  }

  /** Session success/failure must never be replaced by optional catalog bookkeeping failure. */
  private async recordCompatibilityWithoutMasking(
    id: HarnessId,
    compatibility: NonNullable<StoredInstall['compatibility']>,
  ): Promise<void> {
    try {
      await this.recordCompatibility(id, compatibility)
    } catch (error: unknown) {
      this.ctx.logger.warn(
        `Harness "${id}" compatibility state could not be persisted after a session lifecycle result: ${safeHarnessDiagnostic(error, 'state write failed')}`,
      )
    }
  }
}

export const name = 'harnesses'
export const inject = ['sessions']
export function apply(ctx: Context, config: HarnessConfig): void {
  ctx.plugin(HarnessService, config)
  ctx.inject(['harnesses'], (runtimeCtx) => {
    const harnesses = runtimeCtx.harnesses
    const logger = runtimeCtx.logger
    runtimeCtx.on('session/event', (session, event) => {
      if (event.type === 'harness/runtime-node' || event.type === 'harness/runtime-edge') return
      const selectedEvent = event.type === 'harness/selected'
        ? event
        : session.events.findLast(candidate => candidate.type === 'harness/selected')
      const harnessId = selectedEvent?.data.harnessId ?? BUILTIN_DSH.id
      const version = selectedEvent?.data.version
      const binding = harnesses.runtimeBinding(harnessId, version)
      ?? (harnessId === BUILTIN_DSH.id ? { pack: BUILTIN_DSH, driver: undefined } : undefined)
      if (binding === undefined) return

      const observations: Array<{
        signal: import('./types.ts').HarnessRuntimeSignal
        status: import('./runtime.ts').HarnessRuntimeStatus
      }> = []
      if (event.type === 'harness/selected') {
        observations.push(
          { signal: 'protocol.ready', status: 'completed' },
          { signal: 'session.ready', status: 'waiting' },
        )
      } else if (event.type === 'turn/start') observations.push({ signal: 'turn.started', status: 'active' })
      else if (event.type === 'assistant/message') observations.push({ signal: 'model.completed', status: 'completed' })
      else if (event.type === 'tool/call' || event.type === 'tool/result') observations.push({ signal: 'tool.activity', status: 'active' })
      else if (event.type === 'approval/asked') observations.push({ signal: 'approval.requested', status: 'active' })
      else if (event.type === 'approval/decided') observations.push({ signal: 'approval.resolved', status: 'completed' })
      else if (event.type === 'assistant/chunk') observations.push({ signal: 'output.activity', status: 'active' })
      else if (event.type === 'turn/end') {
        const failed = event.data.reason.kind === 'error'
        observations.push({ signal: failed ? 'turn.failed' : 'turn.completed', status: failed ? 'failed' : 'waiting' })
      }

      try {
        const raw = binding.driver?.runtimeSignals?.(event, binding.pack)
        if (Array.isArray(raw)) {
          for (const candidate of (raw as readonly unknown[]).slice(0, 64)) {
            if (typeof candidate !== 'object' || candidate === null) continue
            const signal = (candidate as { signal?: unknown }).signal
            const status = (candidate as { status?: unknown }).status
            if (typeof signal !== 'string' || typeof status !== 'string') continue
            const namespaced = signal.startsWith(`driver.${binding.pack.protocol}.`)
              && signal.length <= 256
              && /^[a-z0-9][a-z0-9._-]*$/u.test(signal)
            const builtin = [
              'protocol.ready', 'session.ready', 'turn.started', 'turn.completed', 'turn.failed',
              'model.completed', 'tool.activity', 'output.activity', 'approval.requested', 'approval.resolved',
            ].includes(signal)
            if ((!builtin && !namespaced)
            || !['active', 'waiting', 'completed', 'failed'].includes(status)) continue
            observations.push({
              signal: signal as import('./types.ts').HarnessRuntimeSignal,
              status: status as import('./runtime.ts').HarnessRuntimeStatus,
            })
          }
        }
      } catch (error: unknown) {
        logger.warn(`Harness Driver runtime observation failed: ${safeHarnessDiagnostic(error, 'runtime observation failed')}`)
      }
      if (observations.length === 0) return
      // Session publication rejects re-entrant appends. These facts derive from
      // the event that just committed, so publish them in the next microtask in
      // source-event order. Receiving the source event already proves that this
      // exact Session was attached at the publication boundary.
      queueMicrotask(() => {
        const seen = new Set<string>()
        try {
          for (const observation of observations) {
            const key = `${observation.signal}\u0000${observation.status}`
            if (seen.has(key)) continue
            seen.add(key)
            observeHarnessRuntime(session, binding.pack, observation.signal, observation.status)
          }
        } catch (error: unknown) {
          logger.warn(`Harness runtime observation could not be recorded: ${safeHarnessDiagnostic(error, 'runtime observation append failed')}`)
        }
      })
    }, { global: true })
  })
  ctx.inject(['sessionProjections'], (projectionCtx) => {
    projectionCtx.sessionProjections.register(harnessRuntimeProjectionDefinition)
  })
}

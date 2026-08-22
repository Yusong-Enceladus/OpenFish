/** Harness Pack catalog and protocol-driver registry for Open Fish. @module */

import { Context, Service } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'
import type { SessionId } from '@deepseek-ai/dsh-session'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { packsFromAcpRegistry, parseHarnessPack } from './manifest.ts'
import type {
  HarnessCatalogEntry,
  HarnessDriver,
  HarnessId,
  HarnessPack,
  HarnessSessionRequest,
} from './types.ts'

export * from './manifest.ts'
export type * from './types.ts'

declare module '@deepseek-ai/cordis' {
  interface Context { harnesses: HarnessService }
}

declare module '@deepseek-ai/dsh-session/types' {
  interface SessionEventMap {
    /** Selected runtime identity and its remote session, committed before the first turn. */
    'harness/selected': { harnessId: HarnessId; version: string; protocol: string; remoteSessionId?: string }
    /** Lossless provider event retained when no common Open Fish presentation exists. */
    'harness/native-event': { harnessId: HarnessId; event: unknown }
  }
}

/** Harness catalog configuration. */
export interface HarnessConfig {
  /** ACP Registry JSON endpoint refreshed at startup and on user request. */
  registryUrl?: string
  /** Untrusted Pack v0 documents admitted before Registry rows are merged. */
  packs?: unknown[]
  /** Managed Harness state root; defaults beneath `$DSH_HOME`. */
  stateDir?: string
}

/** Statically walkable Harness catalog configuration schema. */
export const Config: Schema<HarnessConfig> = Schema.object({
  registryUrl: Schema.string().default('https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json'),
  packs: Schema.array(Schema.any()).default([]),
  stateDir: Schema.string(),
})

interface StoredInstall {
  active?: HarnessPack
  previous: HarnessPack[]
  authMethod?: string
  compatibility?: { status: 'compatible' | 'failed'; checkedAt: string; message?: string }
}

interface StoredHarnessState {
  version: 2
  defaultHarnessId?: string
  customPacks: HarnessPack[]
  registryPacks: HarnessPack[]
  installs: Record<string, StoredInstall>
}

const EMPTY_STATE: StoredHarnessState = { version: 2, customPacks: [], registryPacks: [], installs: {} }

/**
 * Admit a persisted Pack written by an older Open Fish runtime. Some early ACP
 * discovery snapshots omitted the newly-required `fields` array. Prefer the
 * current catalog definition for the same auth method (important for API-key
 * fields), then fall back to an empty form for protocol-owned login methods.
 */
function parseStoredHarnessPack(input: unknown, fallback?: HarnessPack): HarnessPack {
  if (typeof input !== 'object' || input === null) return parseHarnessPack(input)
  const record = input as Record<string, unknown>
  const methods = Array.isArray(record.authMethods)
    ? record.authMethods.map((candidate) => {
      if (typeof candidate !== 'object' || candidate === null) return candidate
      const method = candidate as Record<string, unknown>
      if (Array.isArray(method.fields)) return method
      const id = typeof method.id === 'string' ? method.id : undefined
      const fallbackMethod = fallback?.authMethods?.find(item => item.id === id)
      return { ...method, fields: fallbackMethod?.fields ?? [] }
    })
    : record.authMethods
  return parseHarnessPack({ ...record, ...(methods === undefined ? {} : { authMethods: methods }) })
}

const BUILTIN_DSH = parseHarnessPack({
  schemaVersion: 0,
  id: 'dsh',
  name: 'DeepSeek Harness',
  version: 'builtin',
  description: 'Open Fish native DSH runtime.',
  publisher: 'DeepSeek',
  verified: true,
  protocol: 'dsh',
  graph: {
    level: 'observable',
    nodes: [{ id: 'runtime', kind: 'harness-runtime', title: 'DSH plugin runtime', editable: false }],
    edges: [],
  },
  source: 'builtin',
})

function curatedOmp(version = '17.4.0'): HarnessPack {
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
    distribution: { kind: 'bunx', package: `@oh-my-pi/pi-coding-agent@${version}`, args: ['acp'], env: {} },
    graph: {
      level: 'observable',
      nodes: [{ id: 'runtime', kind: 'harness-runtime', title: 'Oh My Pi ACP runtime', editable: false }],
      edges: [],
    },
    source: 'builtin',
  })
}

/** Catalog plus effect-scoped protocol drivers. */
export class HarnessService extends Service {
  static Config = Config

  private readonly packs = new Map<HarnessId, HarnessPack>()
  private readonly drivers = new Map<HarnessPack['protocol'], HarnessDriver>()
  private readonly initialRefresh: Promise<void>
  private readonly stateFile: string
  private readonly installRoot: string
  private state: StoredHarnessState = structuredClone(EMPTY_STATE)
  private readonly transient = new Map<HarnessId, { status: 'installing' | 'failed'; error?: string }>()
  private mutation: Promise<void> = Promise.resolve()

  constructor(ctx: Context, private readonly config: HarnessConfig) {
    super(ctx, 'harnesses')
    const stateDir = config.stateDir ?? dshHomePath('openfish', 'harnesses')
    this.stateFile = join(stateDir, 'state.json')
    this.installRoot = join(stateDir, 'installed')
    this.packs.set(BUILTIN_DSH.id, BUILTIN_DSH)
    const omp = curatedOmp()
    this.packs.set(omp.id, omp)
    for (const input of config.packs ?? []) {
      const pack = parseHarnessPack(input)
      this.packs.set(pack.id, pack)
    }
    this.initialRefresh = this.initialize().catch((error: unknown) => {
      ctx.logger.warn(`Harness registry startup refresh failed; serving built-in and user Packs: ${String(error)}`)
    })
  }

  private async initialize(): Promise<void> {
    try {
      const parsed = JSON.parse(await readFile(this.stateFile, 'utf8')) as unknown
      if (typeof parsed === 'object' && parsed !== null && [1, 2].includes(Number((parsed as { version?: unknown }).version))) {
        const candidate = parsed as Omit<StoredHarnessState, 'version'> & { version: 1 | 2 }
        const customPacks = candidate.customPacks.map(pack => parseHarnessPack({ ...pack, source: 'user' }))
        const registryPacks = (candidate.registryPacks ?? []).map(pack => parseHarnessPack({ ...pack, source: 'acp-registry' }))
        const catalog = new Map<HarnessId, HarnessPack>([
          ...customPacks.map(pack => [pack.id, pack] as const),
          ...registryPacks.map(pack => [pack.id, pack] as const),
        ])
        const installs = Object.fromEntries(Object.entries(candidate.installs).map(([id, install]) => {
          const fallback = catalog.get(id as HarnessId)
          return [id, {
            ...(install.active === undefined ? {} : { active: parseStoredHarnessPack(install.active, fallback) }),
            previous: install.previous.map(pack => parseStoredHarnessPack(pack, fallback)),
            ...(install.authMethod === undefined ? {} : { authMethod: install.authMethod }),
            ...(install.compatibility === undefined ? {} : { compatibility: install.compatibility }),
          } satisfies StoredInstall]
        }))
        this.state = {
          version: 2,
          // v1 always materialized DSH even when the user never chose it. Do
          // not mistake that compatibility default for consent during upgrade.
          ...(candidate.version === 2 && candidate.defaultHarnessId !== undefined
            ? { defaultHarnessId: candidate.defaultHarnessId }
            : {}),
          customPacks,
          registryPacks,
          installs,
        }
        for (const pack of this.state.customPacks) this.packs.set(pack.id, pack)
        for (const pack of this.state.registryPacks) this.packs.set(pack.id, pack)
        for (const install of Object.values(this.state.installs)) {
          if (install.active !== undefined && !this.packs.has(install.active.id)) this.packs.set(install.active.id, install.active)
        }
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
    await this.refresh()
  }

  private async saveState(): Promise<void> {
    await mkdir(dirname(this.stateFile), { recursive: true })
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
    if (this.drivers.has(driver.protocol)) throw new Error(`Harness driver "${driver.protocol}" is already registered`)
    this.drivers.set(driver.protocol, driver)
    return () => { if (this.drivers.get(driver.protocol) === driver) this.drivers.delete(driver.protocol) }
  }

  /**
   * Refresh ACP Registry metadata without deleting user or built-in Packs.
   * @param signal - Optional cancellation for the registry request.
   */
  async refresh(signal?: AbortSignal): Promise<void> {
    const options = signal === undefined ? {} : { signal }
    const [response, ompResponse] = await Promise.all([
      fetch(this.config.registryUrl ?? 'https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json', options),
      fetch('https://registry.npmjs.org/@oh-my-pi%2Fpi-coding-agent/latest', options).catch(() => undefined),
    ])
    if (!response.ok) throw new Error(`ACP Registry returned HTTP ${response.status}`)
    if (ompResponse?.ok) {
      const metadata = await ompResponse.json() as { version?: unknown }
      if (typeof metadata.version === 'string' && metadata.version.length > 0) {
        const omp = curatedOmp(metadata.version)
        this.packs.set(omp.id, omp)
      }
    }
    const registryPacks = packsFromAcpRegistry(await response.json())
    const refreshedIds = new Set(registryPacks.map(pack => pack.id))
    for (const [id, existing] of this.packs) {
      if (existing.source === 'acp-registry' && !refreshedIds.has(id)) this.packs.delete(id)
    }
    this.state.registryPacks = registryPacks
    for (const pack of registryPacks) {
      const existing = this.packs.get(pack.id)
      if (existing?.source === 'builtin' || existing?.source === 'user') continue
      this.packs.set(pack.id, pack)
    }
    await this.saveState()
  }

  /**
   * List every Pack with its current driver availability.
   * @returns Detached catalog rows in insertion order.
   */
  async list(): Promise<HarnessCatalogEntry[]> {
    await this.initialRefresh
    return await Promise.all([...this.packs.values()].map(async (pack) => {
      const install = this.state.installs[pack.id]
      const transient = this.transient.get(pack.id)
      const driver = this.drivers.get(pack.protocol)
      const effectivePack = install?.active ?? pack
      const installation = pack.protocol === 'dsh'
        ? { status: 'builtin' as const, installedVersion: pack.version, availableVersion: pack.version, previousVersions: [] }
        : {
          status: transient?.status ?? (install?.active === undefined ? 'not-installed' as const : 'installed' as const),
          ...(install?.active === undefined ? {} : { installedVersion: install.active.version }),
          availableVersion: pack.version,
          previousVersions: install?.previous.map(item => item.version) ?? [],
          ...(transient?.error === undefined ? {} : { error: transient.error }),
        }
      const auth = {
        methods: effectivePack.authMethods ?? [],
        ...(install?.authMethod === undefined ? {} : { selectedMethod: install.authMethod }),
        ...await this.authenticationState(effectivePack, install?.authMethod, driver),
      }
      const compatibility = install?.compatibility ?? (pack.protocol === 'dsh'
        ? { status: 'compatible' as const, checkedAt: new Date(0).toISOString(), message: 'Built in to this Open Fish runtime.' }
        : { status: 'untested' as const })
      const isDefault = this.state.defaultHarnessId === pack.id
      if (pack.protocol === 'dsh') return { ...pack, isDefault, available: true, installation, auth, compatibility }
      if (driver === undefined) {
        return {
          ...pack, isDefault, available: false, unavailableReason: `No ${pack.protocol} driver is loaded`, installation, auth, compatibility,
        }
      }
      const unavailableReason = await driver.available(pack)
      return {
        ...pack,
        isDefault,
        available: unavailableReason === undefined,
        ...(unavailableReason === undefined ? {} : { unavailableReason }), installation, auth,
        compatibility: install?.compatibility ?? (unavailableReason === undefined
          ? { status: 'ready' as const, message: 'Launch prerequisites are present; first session has not been verified yet.' }
          : { status: 'failed' as const, checkedAt: new Date().toISOString(), message: unavailableReason }),
      }
    }))
  }

  /**
   * Install or update one Pack with a recoverable previous-version snapshot.
   * @param id - Catalog identity to install.
   * @param signal - Optional package-download cancellation.
   */
  async install(id: HarnessId, signal?: AbortSignal): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const pack = this.require(id)
      if (pack.protocol === 'dsh') return
      const driver = this.drivers.get(pack.protocol)
      if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
      this.transient.set(id, { status: 'installing' })
      try {
        const installationDirectory = join(this.installRoot, pack.id, pack.version)
        await driver.install?.(pack, installationDirectory, signal)
        const discoveredAuth = await driver.discoverAuth?.(pack, installationDirectory)
        const installedPack = discoveredAuth === undefined ? pack : { ...pack, authMethods: discoveredAuth }
        const existing = this.state.installs[pack.id]
        const previous = existing?.active === undefined || existing.active.version === pack.version
          ? existing?.previous ?? []
          : [existing.active, ...existing.previous].filter((candidate, index, all) =>
            all.findIndex(other => other.version === candidate.version) === index)
        this.state.installs[pack.id] = {
          active: installedPack,
          previous,
          ...(existing?.authMethod === undefined ? {} : { authMethod: existing.authMethod }),
        }
        await this.saveState()
        this.transient.delete(id)
      } catch (error) {
        this.transient.set(id, { status: 'failed', error: error instanceof Error ? error.message : String(error) })
        throw error
      }
    })
  }

  /**
   * Remove managed package files while retaining the discoverable catalog row.
   * @param id - Installed Harness identity.
   */
  async uninstall(id: HarnessId): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const pack = this.require(id)
      if (pack.protocol === 'dsh') throw new Error('The built-in DSH Harness cannot be uninstalled')
      this.removeInstall(pack.id)
      this.transient.delete(id)
      await rm(join(this.installRoot, pack.id), { recursive: true, force: true })
      await this.saveState()
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
      install.previous = [install.active, ...install.previous.slice(1)]
      install.active = previous
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
      const pack = this.require(id)
      if (method !== undefined && !(pack.authMethods ?? []).some(candidate => candidate.id === method)) {
        throw new Error(`Harness "${id}" does not declare authentication method "${method}"`)
      }
      const install = this.state.installs[pack.id] ?? { previous: [] }
      this.state.installs[pack.id] = { ...install, ...(method === undefined ? {} : { authMethod: method }) }
      if (method === undefined) delete this.state.installs[pack.id]?.authMethod
      await this.saveState()
    })
  }

  /** Launch one explicitly selected interactive authentication flow. */
  async authenticateInteractive(id: HarnessId, methodId: string): Promise<void> {
    await this.initialRefresh
    const pack = this.require(id)
    const install = this.state.installs[pack.id]
    const active = pack.protocol === 'dsh' ? pack : install?.active
    if (active === undefined) throw new Error(`Harness "${id}" must be installed before login`)
    const method = active.authMethods?.find(candidate => candidate.id === methodId)
    if (method?.kind !== 'terminal') throw new Error(`Harness "${id}" does not declare terminal authentication method "${methodId}"`)
    const driver = this.drivers.get(active.protocol)
    if (driver?.authenticateInteractive === undefined) throw new Error(`The ${active.protocol} driver cannot run interactive authentication`)
    await driver.authenticateInteractive(active, join(this.installRoot, active.id, active.version), method)
    await this.selectAuth(id, methodId)
  }

  /**
   * Persist the cross-device default chosen by native Open Fish clients.
   * @param id - Harness to use for new tasks by default.
   */
  async selectDefault(id: HarnessId): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      this.require(id)
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

  /** Current explicit default, absent until a user chooses one. */
  async defaultId(): Promise<HarnessId | undefined> {
    await this.initialRefresh
    return this.state.defaultHarnessId as HarnessId | undefined
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
   * Remove one user-authored Pack definition.
   * @param id - User Pack identity.
   */
  async removeUserPack(id: HarnessId): Promise<void> {
    await this.initialRefresh
    await this.serialize(async () => {
      const pack = this.require(id)
      if (pack.source !== 'user') throw new Error('Only user Harness Packs can be removed')
      this.state.customPacks = this.state.customPacks.filter(item => item.id !== id)
      this.removeInstall(id)
      if (this.state.defaultHarnessId === id) delete this.state.defaultHarnessId
      this.packs.delete(id)
      await rm(join(this.installRoot, id), { recursive: true, force: true })
      await this.saveState()
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

  private removeInstall(id: HarnessId): void {
    this.state.installs = Object.fromEntries(Object.entries(this.state.installs).filter(([key]) => key !== id))
  }

  /**
   * Create a non-DSH session through its registered protocol driver.
   * @param id - Selected Harness Pack identity.
   * @param sessionId - New local session identity.
   * @param cwd - Absolute session working directory.
   * @returns Published external Agent.
   */
  async create(id: HarnessId, sessionId: SessionId, cwd: string): Promise<Agent> {
    return await this.driverRequest('create', { harnessId: id, sessionId, cwd })
  }

  /**
   * Resume a persisted non-DSH session through its registered protocol driver.
   * @param id - Persisted Harness Pack identity.
   * @param sessionId - Existing local session identity.
   * @param cwd - Persisted absolute working directory.
   * @returns Restored external Agent.
   */
  async resume(id: HarnessId, sessionId: SessionId, cwd: string, version?: string): Promise<Agent> {
    return await this.driverRequest('resume', { harnessId: id, sessionId, cwd, ...(version === undefined ? {} : { version }) })
  }

  private async driverRequest(operation: 'create' | 'resume', request: HarnessSessionRequest): Promise<Agent> {
    let pack = this.require(request.harnessId)
    if (pack.protocol === 'dsh') throw new Error('The DSH Harness is created by the native AgentLoop')
    if (this.state.installs[pack.id]?.active === undefined) await this.install(pack.id)
    const install = this.state.installs[pack.id]
    if (request.version !== undefined) {
      const pinned = [install?.active, ...(install?.previous ?? [])].find(candidate => candidate?.version === request.version)
      if (pinned === undefined) {
        throw new Error(`Harness "${pack.id}" version ${request.version} is not installed; restore that version or fork the task onto a current Harness`)
      }
      pack = pinned
    } else {
      pack = install?.active ?? pack
    }
    const driver = this.drivers.get(pack.protocol)
    if (driver === undefined) throw new Error(`No ${pack.protocol} Harness driver is loaded`)
    const unavailable = await driver.available(pack)
    if (unavailable !== undefined) throw new Error(unavailable)
    const authMethod = this.state.installs[pack.id]?.authMethod
    const authentication = await this.authenticationState(pack, authMethod, driver)
    if (authentication.status === 'needs-selection') throw new Error(`Harness "${pack.id}" requires an explicit authentication method`)
    if (authentication.status === 'needs-credentials') {
      throw new Error(`Harness "${pack.id}" is missing required credentials: ${authentication.missingFields.join(', ')}`)
    }
    const installationDirectory = join(this.installRoot, pack.id, pack.version)
    try {
      const agent = await driver[operation]({
        ...request,
        installationDirectory,
        ...(authMethod === undefined ? {} : { authMethod }),
      }, pack)
      await this.recordCompatibility(pack.id, { status: 'compatible', checkedAt: new Date().toISOString() })
      return agent
    } catch (error: unknown) {
      await this.recordCompatibility(pack.id, {
        status: 'failed', checkedAt: new Date().toISOString(),
        message: error instanceof Error ? error.message : String(error),
      })
      throw error
    }
  }

  private async authenticationState(
    pack: HarnessPack,
    selectedMethod: string | undefined,
    driver: HarnessDriver | undefined,
  ): Promise<{ status: 'not-required' | 'needs-selection' | 'needs-credentials' | 'configured'; missingFields: string[] }> {
    const methods = pack.authMethods ?? []
    if (methods.length === 0) return { status: 'not-required', missingFields: [] }
    if (selectedMethod === undefined) return { status: 'needs-selection', missingFields: [] }
    const missingFields = await driver?.missingCredentials?.(pack, selectedMethod) ?? []
    return { status: missingFields.length === 0 ? 'configured' : 'needs-credentials', missingFields }
  }

  private async recordCompatibility(id: HarnessId, compatibility: NonNullable<StoredInstall['compatibility']>): Promise<void> {
    await this.serialize(async () => {
      const existing = this.state.installs[id] ?? { previous: [] }
      this.state.installs[id] = { ...existing, compatibility }
      await this.saveState()
    })
  }
}

export const name = 'harnesses'
export function apply(ctx: Context, config: HarnessConfig): void { ctx.plugin(HarnessService, config) }
export default HarnessService

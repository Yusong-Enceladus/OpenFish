/** macOS Keychain-backed credential provider used by the native OpenFish Host. @module */

import { execFile } from 'node:child_process'
import { readFile, stat, unlink } from 'node:fs/promises'
import { promisify } from 'node:util'
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { CredentialProvider, credentialRef, parseCredentialKey } from '@deepseek-ai/dsh-credentials'
import type {
  CredentialInfo,
  CredentialKey,
  CredentialRecord,
  CredentialRecordEntry,
  CredentialRecordInfo,
  CredentialRef,
  ResolvedCredential,
} from '@deepseek-ai/dsh-credentials'
import { dshHomePath } from '@deepseek-ai/dsh-home-paths'
import { launchEnvironmentOf } from '@deepseek-ai/dsh-launch-environment'
import { parse as parseYaml } from 'yaml'

const execFileAsync = promisify(execFile)
export const name = 'credentials-keychain'
/** Keychain generic-password service reserved for OpenFish credentials. */
export const SERVICE_NAME = 'app.openfish.credentials'

/** Minimal credential-store operations used by the provider and its tests. */
export interface KeychainExecutor {
  get(account: string): Promise<string | undefined>
  set(account: string, value: string): Promise<void>
  remove(account: string): Promise<void>
}

function notFound(error: unknown): boolean {
  const value = error as { code?: unknown; status?: unknown }
  return value.code === 'ENOENT' || value.status === 44
}

/** Shell-free adapter over Apple's supported `security` command. */
export class SecurityKeychainExecutor implements KeychainExecutor {
  constructor(private readonly service = SERVICE_NAME) {}

  async get(account: string): Promise<string | undefined> {
    try {
      const { stdout } = await execFileAsync('/usr/bin/security', ['find-generic-password', '-a', account, '-s', this.service, '-w'])
      return stdout.trim() || undefined
    } catch (error: unknown) {
      if (notFound(error)) return undefined
      throw error
    }
  }

  async set(account: string, value: string): Promise<void> {
    await execFileAsync('/usr/bin/security', ['add-generic-password', '-a', account, '-s', this.service, '-w', value, '-U'])
  }

  async remove(account: string): Promise<void> {
    try {
      await execFileAsync('/usr/bin/security', ['delete-generic-password', '-a', account, '-s', this.service])
    } catch (error: unknown) {
      if (!notFound(error)) throw error
    }
  }
}

/** macOS Keychain credential provider configuration. */
export interface Config {
  /** Generic-password service name used to isolate OpenFish credentials. */
  service?: string
  /** Owner-only legacy YAML path imported once and removed after success. */
  legacyPath?: string
}

function accountFor(ref: CredentialRef): string {
  return `openfish:${ref}`
}

const RECORD_INDEX_ACCOUNT = 'openfish:records:index'

function accountForRecord(key: CredentialKey): string {
  return `openfish:record:${key}`
}

function assertJsonValue(value: unknown, seen = new Set<object>()): void {
  if (value === null || typeof value === 'string' || typeof value === 'boolean') return
  if (typeof value === 'number' && Number.isFinite(value)) return
  if (typeof value !== 'object') throw new TypeError('keychain credential record contains a non-JSON value')
  if (seen.has(value)) throw new TypeError('keychain credential record contains a cycle')
  if (!Array.isArray(value) && Object.getPrototypeOf(value) !== Object.prototype) {
    throw new TypeError('keychain credential record contains a non-plain object')
  }
  seen.add(value)
  for (const nested of Object.values(value)) assertJsonValue(nested, seen)
  seen.delete(value)
}

function admittedRecord(key: CredentialKey, value: unknown): CredentialRecord {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    throw new TypeError(`keychain credential record "${key}" is not an object`)
  }
  const record = value as Record<string, unknown>
  if (record.kind === 'api-key') {
    if (Object.keys(record).some(field => !['kind', 'key', 'env'].includes(field))) {
      throw new TypeError(`keychain credential record "${key}" has an unknown field`)
    }
    if (record.key !== undefined && (typeof record.key !== 'string' || record.key.length === 0)) {
      throw new TypeError(`keychain credential record "${key}" has an invalid key`)
    }
    let env: Record<string, string> | undefined
    if (record.env !== undefined) {
      if (typeof record.env !== 'object' || record.env === null || Array.isArray(record.env)) {
        throw new TypeError(`keychain credential record "${key}" has invalid environment values`)
      }
      env = {}
      for (const [name, entry] of Object.entries(record.env as Record<string, unknown>)) {
        credentialRef(name)
        if (typeof entry !== 'string' || entry.length === 0) {
          throw new TypeError(`keychain credential record "${key}" has an invalid environment value`)
        }
        env[name] = entry
      }
    }
    return {
      kind: 'api-key',
      ...(record.key === undefined ? {} : { key: record.key }),
      ...(env === undefined ? {} : { env }),
    }
  }
  if (record.kind === 'grant') {
    if (Object.keys(record).some(field => !['kind', 'payload'].includes(field)) || !('payload' in record)) {
      throw new TypeError(`keychain credential record "${key}" has an invalid grant payload`)
    }
    assertJsonValue(record.payload)
    return { kind: 'grant', payload: record.payload }
  }
  throw new TypeError(`keychain credential record "${key}" has an unknown kind`)
}

/** Values never enter settings, Pack state, process arguments, or API responses. */
export class KeychainCredentials extends CredentialProvider {
  static Config: z<Config> = z.object({
    service: z.string().default(SERVICE_NAME).description('macOS Keychain service name'),
    legacyPath: z.string().description('Owner-only legacy YAML file imported once, then removed'),
  })

  private readonly executor: KeychainExecutor
  private readonly ready: Promise<void>
  private recordMutationTail: Promise<void> = Promise.resolve()

  constructor(ctx: Context, config: Config = {}, executor?: KeychainExecutor) {
    super(ctx)
    if (process.platform !== 'darwin' && executor === undefined) throw new Error('Keychain credentials require macOS')
    this.executor = executor ?? new SecurityKeychainExecutor(config.service)
    this.ready = executor === undefined || config.legacyPath !== undefined
      ? this.migrateLegacy(config.legacyPath ?? dshHomePath('.credentials.yaml'))
      : Promise.resolve()
  }

  async resolve(ref: CredentialRef): Promise<ResolvedCredential | undefined> {
    await this.ready
    const validated = credentialRef(ref)
    const environment = launchEnvironmentOf(this.ctx)
    const inherited = environment.getFrom(validated, ['process'])
    if (inherited !== undefined && inherited.value !== '') return { value: inherited.value, source: 'env' }
    const value = await this.executor.get(accountFor(validated))
    if (value !== undefined) return { value, source: 'keychain' }
    const fallback = environment.getFrom(validated, ['project-env', 'user-env'])
    return fallback === undefined || fallback.value === '' ? undefined : { value: fallback.value, source: fallback.source }
  }

  async describe(ref: CredentialRef): Promise<CredentialInfo> {
    await this.ready
    const validated = credentialRef(ref)
    const environment = launchEnvironmentOf(this.ctx)
    const inherited = environment.getFrom(validated, ['process'])
    if (inherited !== undefined && inherited.value !== '') {
      return { configured: true, source: 'env', writable: false }
    }
    const configured = await this.executor.get(accountFor(validated)) !== undefined
    if (configured) return { configured: true, source: 'keychain', writable: true }
    const fallback = environment.getFrom(validated, ['project-env', 'user-env'])
    return fallback === undefined || fallback.value === ''
      ? { configured: false, writable: true }
      : { configured: true, source: fallback.source, writable: true }
  }

  async set(ref: CredentialRef, value: string): Promise<void> {
    await this.ready
    const validated = credentialRef(ref)
    const inherited = launchEnvironmentOf(this.ctx).getFrom(validated, ['process'])
    if (inherited !== undefined && inherited.value !== '') {
      throw new Error(`keychain credentials: inherited environment shadows ${validated}; remove it before writing`)
    }
    if (value === '') throw new Error('keychain credentials: empty value is absent; use unset')
    await this.executor.set(accountFor(validated), value)
    this.notifyUpdated(validated)
  }

  async unset(ref: CredentialRef): Promise<void> {
    await this.ready
    const validated = credentialRef(ref)
    const inherited = launchEnvironmentOf(this.ctx).getFrom(validated, ['process'])
    if (inherited !== undefined && inherited.value !== '') {
      throw new Error(`keychain credentials: inherited environment shadows ${validated}; remove it before deleting`)
    }
    await this.executor.remove(accountFor(validated))
    this.notifyUpdated(validated)
  }

  private enqueueRecordMutation<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.recordMutationTail.then(operation, operation)
    this.recordMutationTail = result.then(() => undefined, () => undefined)
    return result
  }

  private async recordIndex(): Promise<CredentialKey[]> {
    const serialized = await this.executor.get(RECORD_INDEX_ACCOUNT)
    if (serialized === undefined) return []
    const parsed = JSON.parse(serialized) as unknown
    if (!Array.isArray(parsed) || parsed.some(value => typeof value !== 'string')) {
      throw new Error('keychain credential record index is invalid')
    }
    return [...new Set(parsed.map(value => parseCredentialKey(value as string)))]
      .sort((left, right) => String(left).localeCompare(String(right)))
  }

  private async writeRecordIndex(keys: readonly CredentialKey[]): Promise<void> {
    if (keys.length === 0) {
      await this.executor.remove(RECORD_INDEX_ACCOUNT)
      return
    }
    await this.executor.set(RECORD_INDEX_ACCOUNT, JSON.stringify(keys.map(String).toSorted()))
  }

  private async readStoredRecord(key: CredentialKey): Promise<CredentialRecord | undefined> {
    const serialized = await this.executor.get(accountForRecord(key))
    if (serialized === undefined) return undefined
    return admittedRecord(key, JSON.parse(serialized) as unknown)
  }

  override async readRecord(key: CredentialKey): Promise<CredentialRecord | undefined> {
    await this.ready
    await this.recordMutationTail
    return this.readStoredRecord(key)
  }

  override async describeRecord(key: CredentialKey): Promise<CredentialRecordInfo> {
    const record = await this.readRecord(key)
    return record === undefined
      ? { configured: false, writable: true }
      : { configured: true, kind: record.kind, writable: true }
  }

  override async listRecords(): Promise<readonly CredentialRecordEntry[]> {
    await this.ready
    await this.recordMutationTail
    const entries: CredentialRecordEntry[] = []
    for (const key of await this.recordIndex()) {
      const record = await this.readStoredRecord(key)
      if (record !== undefined) entries.push({ key, kind: record.kind })
    }
    return entries
  }

  override modifyRecord(
    key: CredentialKey,
    mutate: (current: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
  ): Promise<CredentialRecord | undefined> {
    return this.enqueueRecordMutation(async () => {
      await this.ready
      const current = await this.readStoredRecord(key)
      const proposed = await mutate(current)
      if (proposed === undefined) return current
      const next = admittedRecord(key, proposed)
      await this.executor.set(accountForRecord(key), JSON.stringify(next))
      const index = await this.recordIndex()
      if (!index.includes(key)) await this.writeRecordIndex([...index, key])
      this.notifyRecordUpdated(key)
      return next
    })
  }

  override deleteRecord(key: CredentialKey): Promise<void> {
    return this.enqueueRecordMutation(async () => {
      await this.ready
      const current = await this.readStoredRecord(key)
      if (current === undefined) return
      await this.executor.remove(accountForRecord(key))
      await this.writeRecordIndex((await this.recordIndex()).filter(candidate => candidate !== key))
      this.notifyRecordUpdated(key)
    })
  }

  private async migrateLegacy(path: string): Promise<void> {
    try {
      const metadata = await stat(path)
      if ((metadata.mode & 0o077) !== 0) throw new Error(`Legacy credential file is readable by other users: ${path}`)
      const parsed = parseYaml(await readFile(path, 'utf8')) as unknown
      if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('Legacy credential file must be a mapping')
      for (const [rawRef, rawValue] of Object.entries(parsed as Record<string, unknown>)) {
        const ref = credentialRef(rawRef)
        if (typeof rawValue !== 'string' || rawValue === '') throw new Error(`Legacy credential "${rawRef}" is not a non-empty string`)
        const account = accountFor(ref)
        if (await this.executor.get(account) === undefined) await this.executor.set(account, rawValue)
      }
      await unlink(path)
      this.ctx.logger.info('credentials-keychain: imported and removed the owner-only legacy credential file')
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return
      throw error
    }
  }
}

export default KeychainCredentials

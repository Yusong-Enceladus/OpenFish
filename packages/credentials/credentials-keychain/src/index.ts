/** macOS Keychain-backed credential provider used by the native OpenFish Host. @module */

import { execFile } from 'node:child_process'
import { readFile, stat, unlink } from 'node:fs/promises'
import { promisify } from 'node:util'
import type { Context } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'
import { CredentialProvider, credentialRef } from '@deepseek-ai/dsh-credentials'
import type { CredentialInfo, CredentialRef, ResolvedCredential } from '@deepseek-ai/dsh-credentials'
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

/** Values never enter settings, Pack state, process arguments, or API responses. */
export class KeychainCredentials extends CredentialProvider {
  static Config: z<Config> = z.object({
    service: z.string().default(SERVICE_NAME).description('macOS Keychain service name'),
    legacyPath: z.string().description('Owner-only legacy YAML file imported once, then removed'),
  })

  private readonly executor: KeychainExecutor
  private readonly ready: Promise<void>

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

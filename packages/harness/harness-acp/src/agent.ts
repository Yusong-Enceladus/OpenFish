/** Durable DSH Agent projection over one persistent ACP subprocess session. @module */

import { dirname, join, normalize, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Readable as NodeReadable, Writable as NodeWritable } from 'node:stream'
import { existsSync } from 'node:fs'
import { chmod, lstat, mkdir, readdir, readFile, readlink, rm, writeFile } from 'node:fs/promises'
import { createHash } from 'node:crypto'
import {
  ClientSideConnection,
  ndJsonStream,
  PROTOCOL_VERSION,
  type Agent as AcpConnection,
  type Client,
  type ContentBlock as AcpContentBlock,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type SessionConfigOption,
  type SessionNotification,
} from '@agentclientprotocol/sdk'
import type { Context } from '@deepseek-ai/cordis'
import { agentEvents, Inbox, type Agent, type AgentCancelCause, type AgentEventDispatch, type AgentOptions, type AgentStatus, type CancelOptions, type InboxTarget } from '@deepseek-ai/dsh-agent'
import { BlockAssembler, createAssistantMessage, type UserMessage } from '@deepseek-ai/dsh-llm'
import { createScope, type Scope } from '@deepseek-ai/dsh-scope'
import type { Session, SessionId, TurnEndReason } from '@deepseek-ai/dsh-session'
import type { HarnessAuthMethod, HarnessPack } from '@deepseek-ai/dsh-harness'
import type { SubprocessHandle } from '@deepseek-ai/dsh-subprocess'
import type {} from '@deepseek-ai/dsh-user-approval'
import { credentialRef } from '@deepseek-ai/dsh-credentials'

type Phase = { kind: 'idle'; turn: number } | { kind: 'running'; turn: number; abort: AbortController }

/** One model and its optional reasoning directory advertised by an ACP Harness. */
export interface AcpHarnessModelOption {
  id: string
  name: string
  description?: string
  reasoning?: {
    efforts: Array<{ id: string; name: string; description?: string }>
    defaultEffort?: string
  }
}

/** Current ACP model selection plus every model the live Harness advertises. */
export interface AcpHarnessModelCatalog {
  current: string
  currentReasoningEffort?: string
  models: AcpHarnessModelOption[]
}

/** One selectable value in a projected ACP session option. */
export interface AcpHarnessConfigValue {
  id: string
  name: string
  description?: string
  group?: string
  groupName?: string
}

/** UI-safe projection of one live ACP session configuration option. */
export interface AcpHarnessConfigOption {
  id: string
  name: string
  description?: string
  category?: string
  type: 'select' | 'boolean'
  currentValue: string | boolean
  values: AcpHarnessConfigValue[]
}

/**
 * Resolve portable session defaults declared by editable Pack nodes.
 * `acpSessionOptions` maps standard ACP configuration ids to select/boolean
 * values, so this remains generic when a new Harness appears.
 * @param pack - Admitted Pack whose composable nodes may declare defaults.
 * @returns Ordered ACP option assignments for a newly created session.
 */
export function packSessionConfiguration(pack: HarnessPack): Array<{ id: string; value: string | boolean }> {
  if (pack.graph.level !== 'composable') return []
  const resolved = new Map<string, string | boolean>()
  for (const node of pack.graph.nodes) {
    if (!node.editable || node.config === undefined) continue
    const raw = node.config.acpSessionOptions
    if (raw === undefined) continue
    if (raw === null || Array.isArray(raw) || typeof raw !== 'object') {
      throw new Error(`Harness Pack node "${node.id}" must declare "acpSessionOptions" as an object`)
    }
    for (const [id, value] of Object.entries(raw)) {
      if (id.trim() === '' || (typeof value !== 'string' && typeof value !== 'boolean')) {
        throw new Error(`Harness Pack node "${node.id}" has an invalid ACP session option "${id}"`)
      }
      const previous = resolved.get(id)
      if (previous !== undefined && previous !== value) {
        throw new Error(`Harness Pack declares conflicting values for ACP session option "${id}"`)
      }
      resolved.set(id, value)
    }
  }
  return [...resolved].map(([id, value]) => ({ id, value }))
}

function flattenedSelectOptions(option: Extract<SessionConfigOption, { type: 'select' }>) {
  return option.options.flatMap(entry => 'group' in entry ? entry.options : [entry])
}

/**
 * Build a lossless, UI-safe projection of standard ACP session options.
 * @param configOptions - Live options returned by the ACP Harness.
 * @returns Every option in the order advertised by the Harness.
 */
export function acpHarnessConfigCatalog(configOptions: readonly SessionConfigOption[]): AcpHarnessConfigOption[] {
  return configOptions.map(option => ({
    id: option.id,
    name: option.name,
    ...(option.description === undefined || option.description === null ? {} : { description: option.description }),
    ...(option.category === undefined || option.category === null ? {} : { category: option.category }),
    type: option.type,
    currentValue: option.currentValue,
    values: option.type === 'select'
      ? option.options.flatMap(entry => 'group' in entry
        ? entry.options.map(value => ({
          id: value.value,
          name: value.name,
          ...(value.description === undefined || value.description === null ? {} : { description: value.description }),
          group: entry.group,
          groupName: entry.name,
        }))
        : [{
          id: entry.value,
          name: entry.name,
          ...(entry.description === undefined || entry.description === null ? {} : { description: entry.description }),
        }])
      : [],
  }))
}

/**
 * Project ACP model and thought-level options into OpenFish's picker shape.
 * @param configOptions - Live options returned by the ACP Harness.
 * @returns A model directory, or undefined when the Harness exposes no model option.
 */
export function acpHarnessModelCatalog(configOptions: readonly SessionConfigOption[]): AcpHarnessModelCatalog | undefined {
  const option = configOptions.find(candidate => candidate.type === 'select' && candidate.category === 'model')
  if (option === undefined || option.type !== 'select') return undefined
  const flattened = flattenedSelectOptions(option)
  const thought = configOptions.find(candidate => candidate.type === 'select' && candidate.category === 'thought_level')
  const efforts = thought?.type === 'select'
    ? flattenedSelectOptions(thought).map(entry => ({
      id: entry.value,
      name: entry.name,
      ...(entry.description === undefined || entry.description === null ? {} : { description: entry.description }),
    }))
    : []
  return {
    current: option.currentValue,
    ...(thought?.type === 'select' ? { currentReasoningEffort: thought.currentValue } : {}),
    models: flattened.map(entry => ({
      id: entry.value,
      name: entry.name,
      ...(entry.description === undefined || entry.description === null ? {} : { description: entry.description }),
      // ACP only advertises thought levels for the active model. Project them
      // onto that exact route; after a model switch the authoritative config
      // response refreshes both the model and its supported effort set.
      ...(entry.value === option.currentValue && efforts.length > 0
        ? { reasoning: {
          efforts,
          ...(thought?.type === 'select' ? { defaultEffort: thought.currentValue } : {}),
        } }
        : {}),
    })),
  }
}

function npxCliPath(): string {
  const embedded = embeddedRuntimePackagePath('npm', join('bin', 'npx-cli.js'))
  if (embedded !== undefined) return embedded
  return join(dirname(fileURLToPath(import.meta.resolve('npm/package.json'))), 'bin', 'npx-cli.js')
}

function npmCliPath(): string {
  const embedded = embeddedRuntimePackagePath('npm', join('bin', 'npm-cli.js'))
  if (embedded !== undefined) return embedded
  return join(dirname(fileURLToPath(import.meta.resolve('npm/package.json'))), 'bin', 'npm-cli.js')
}

function bunCliPath(): string {
  const embedded = embeddedRuntimePackagePath('bun', join('bin', 'bun.exe'))
  if (embedded !== undefined) return embedded
  return join(dirname(fileURLToPath(import.meta.resolve('bun/package.json'))), 'bin', 'bun.exe')
}

function uvCliPath(): string {
  const runtimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
  if (runtimeRoot !== undefined && runtimeRoot !== '') {
    const candidate = join(runtimeRoot, 'uv', process.platform === 'win32' ? 'uv.exe' : 'uv')
    if (existsSync(candidate)) return candidate
  }
  return process.platform === 'win32' ? 'uv.exe' : 'uv'
}

function pythonPackageCommand(spec: string): string {
  const versionAt = spec.indexOf('==')
  const name = versionAt === -1 ? spec : spec.slice(0, versionAt)
  return name.replaceAll('_', '-').split('/').at(-1) as string
}

function embeddedRuntimePackagePath(packageName: string, relativePath: string): string | undefined {
  const runtimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
  if (runtimeRoot === undefined || runtimeRoot === '') return undefined
  const candidate = join(runtimeRoot, 'app', 'node_modules', '.pnpm', 'node_modules', packageName, relativePath)
  return existsSync(candidate) ? candidate : undefined
}

/**
 * Resolve a Pack distribution into one shell-free argv.
 * @param pack - Admitted Pack with a launch distribution.
 * @returns Executable argv and explicit environment overlay.
 */
export function launchArgv(pack: HarnessPack): { argv: string[]; env: Record<string, string> } {
  const distribution = pack.distribution
  if (distribution === undefined) throw new Error(`Harness Pack "${pack.id}" has no launch distribution`)
  if (distribution.kind === 'executable') {
    return { argv: [distribution.command, ...distribution.args], env: distribution.env }
  }
  if (distribution.kind === 'bunx') {
    return { argv: [bunCliPath(), 'x', '--bun', distribution.package, ...distribution.args], env: distribution.env }
  }
  if (distribution.kind === 'uvx') {
    return { argv: [uvCliPath(), 'tool', 'run', '--from', distribution.package, pythonPackageCommand(distribution.package), ...distribution.args], env: distribution.env }
  }
  if (distribution.kind === 'binary') {
    return { argv: [distribution.command, ...distribution.args], env: distribution.env }
  }
  return {
    argv: [process.execPath, npxCliPath(), '--yes', distribution.package, ...distribution.args],
    env: distribution.env,
  }
}

function packageName(spec: string): string {
  if (spec.startsWith('@')) {
    const versionAt = spec.indexOf('@', 1)
    return versionAt === -1 ? spec : spec.slice(0, versionAt)
  }
  const versionAt = spec.lastIndexOf('@')
  return versionAt <= 0 ? spec : spec.slice(0, versionAt)
}

/**
 * Resolve the executable installed in a pinned Open Fish package snapshot.
 * @param pack - Admitted package-backed Harness definition.
 * @param directory - Exact managed version directory.
 * @returns Shell-free executable argv and explicit environment overlay.
 */
export async function managedLaunchArgv(pack: HarnessPack, directory: string): Promise<{ argv: string[]; env: Record<string, string> }> {
  const distribution = pack.distribution
  if (distribution === undefined) throw new Error(`Harness Pack "${pack.id}" has no launch distribution`)
  if (distribution.kind === 'executable') return launchArgv(pack)
  if (distribution.kind === 'binary') {
    const command = managedBinaryCommand(directory, distribution.command)
    return { argv: [command, ...distribution.args], env: distribution.env }
  }
  if (distribution.kind === 'uvx') {
    const executable = join(directory, 'bin', process.platform === 'win32'
      ? `${pythonPackageCommand(distribution.package)}.exe`
      : pythonPackageCommand(distribution.package))
    if (!existsSync(executable)) throw new Error(`Installed Python Harness does not expose "${pythonPackageCommand(distribution.package)}"`)
    return { argv: [executable, ...distribution.args], env: distribution.env }
  }
  const name = packageName(distribution.package)
  const manifestPath = join(directory, 'node_modules', ...name.split('/'), 'package.json')
  const manifest = JSON.parse(await readFile(manifestPath, 'utf8')) as { bin?: string | Record<string, string> }
  const binName = typeof manifest.bin === 'string'
    ? name.split('/').at(-1)
    : Object.keys(manifest.bin ?? {})[0]
  if (binName === undefined) throw new Error(`Installed Harness package "${name}" does not declare an executable`)
  const executable = join(directory, 'node_modules', '.bin', binName)
  return {
    // A managed bunx snapshot must keep using Open Fish's pinned Bun. Running
    // its .bin shim directly delegates through /usr/bin/env and can silently
    // select an older user-installed Bun from PATH.
    argv: distribution.kind === 'bunx'
      ? [bunCliPath(), executable, ...distribution.args]
      : [executable, ...distribution.args],
    env: distribution.env,
  }
}

function startupDiagnostic(child: SubprocessHandle): string | undefined {
  const stderr = child.collected.stderr?.readFrom(0).text.trim()
  if (stderr === undefined || stderr === '') return undefined
  return sanitizeDiagnostic(stderr.split(/\r?\n/u).filter(line => line.trim() !== '').slice(-12).join(' | ').slice(0, 1_600))
}

function sanitizeDiagnostic(input: string): string {
  return input
    .replace(/\/Users\/[^/\s]+/gu, '$HOME')
    .replace(/\b(?:sk|key|token)-[A-Za-z0-9_-]{12,}\b/gu, '[REDACTED]')
    .replace(/((?:api[_-]?key|authorization|token)\s*[:=]\s*)[^\s,;]+/giu, '$1[REDACTED]')
}

/**
 * Materialize one package distribution beneath Open Fish's managed state root.
 * @param ctx - Host context that owns the subprocess boundary.
 * @param pack - Admitted package-backed Harness definition.
 * @param directory - Exact managed version destination.
 * @param signal - Optional package-manager cancellation.
 */
export async function installHarnessPack(ctx: Context, pack: HarnessPack, directory: string, signal?: AbortSignal): Promise<void> {
  const distribution = pack.distribution
  if (distribution === undefined || distribution.kind === 'executable') return
  await mkdir(directory, { recursive: true })
  if (distribution.kind === 'binary') {
    await installBinaryHarness(ctx, pack, directory, signal)
    return
  }
  if (distribution.kind === 'uvx') {
    await ctx.subprocess.resolveExecutable(uvCliPath())
    const child = ctx.subprocess.spawn({
      argv: [uvCliPath(), 'tool', 'install', '--force', distribution.package], cwd: directory,
      env: { UV_TOOL_DIR: join(directory, 'tools'), UV_TOOL_BIN_DIR: join(directory, 'bin') },
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000, ...(signal === undefined ? {} : { signal }),
    })
    const outcome = await child.done
    if (outcome.exitCode !== 0) {
      const diagnostic = child.collected.stderr?.readFrom(0).text.trim()
        || child.collected.stdout?.readFrom(0).text.trim() || `exit ${String(outcome.exitCode)}`
      throw new Error(`Harness Python package installation failed: ${sanitizeDiagnostic(diagnostic)}`)
    }
    return
  }
  const argv = distribution.kind === 'npx'
    ? [process.execPath, npmCliPath(), 'install', '--prefix', directory, '--no-save', '--package-lock=false', distribution.package]
    : [bunCliPath(), 'add', '--cwd', directory, distribution.package]
  const child = ctx.subprocess.spawn({
    argv,
    cwd: directory,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    graceMs: 3_000,
    ...(signal === undefined ? {} : { signal }),
  })
  const outcome = await child.done
  if (outcome.exitCode !== 0) {
    const diagnostic = child.collected.stderr?.readFrom(0).text.trim()
      || child.collected.stdout?.readFrom(0).text.trim()
      || `exit ${String(outcome.exitCode)}`
    throw new Error(`Harness package installation failed: ${diagnostic}`)
  }
}

/**
 * Launch only through ACP initialize to materialize Harness-owned authentication.
 * @param ctx - Host context that owns the managed subprocess runtime.
 * @param pack - Admitted Pack to probe.
 * @param installationDirectory - Managed installation directory for the Pack.
 * @returns Authentication methods advertised during ACP initialization.
 */
export async function discoverAcpAuthentication(
  ctx: Context,
  pack: HarnessPack,
  installationDirectory: string,
): Promise<HarnessAuthMethod[]> {
  const { argv, env } = await managedLaunchArgv(pack, installationDirectory)
  const child = ctx.subprocess.spawn({
    argv, cwd: installationDirectory, env,
    stdio: { stdin: 'pipe', stdout: 'pipe', stderr: { maxBytes: 64 * 1024 } }, graceMs: 3_000,
  })
  if (child.stdin === undefined || child.stdout === undefined) {
    child.terminate()
    throw new Error('ACP Harness authentication probe did not expose protocol pipes')
  }
  const connection = new ClientSideConnection(
    (): Client => ({
      sessionUpdate: () => Promise.resolve(),
      requestPermission: () => Promise.resolve({ outcome: { outcome: 'cancelled' } }),
    }),
    ndJsonStream(
      NodeWritable.toWeb(child.stdin) as WritableStream<Uint8Array>,
      NodeReadable.toWeb(child.stdout) as ReadableStream<Uint8Array>,
    ),
  )
  try {
    const initialized = await connection.initialize({
      protocolVersion: PROTOCOL_VERSION,
      clientCapabilities: { plan: {}, auth: { terminal: true }, fs: { readTextFile: false, writeTextFile: false } },
      clientInfo: { name: 'open-fish', title: 'Open Fish', version: '0.1.0' },
    })
    return (initialized.authMethods ?? []).map((method): HarnessAuthMethod => {
      if ('type' in method && method.type === 'env_var') {
        return {
          id: method.id, name: method.name, kind: 'environment',
          fields: method.vars.map(variable => ({
            // ACP names the process environment variable itself. Reusing that
            // valid credential reference lets existing CI/user credentials
            // work and avoids an artificial Open Fish-only alias.
            ref: credentialRef(variable.name),
            name: variable.label ?? variable.name,
            env: variable.name,
            required: variable.optional !== true,
            secret: variable.secret !== false,
          })),
        }
      }
      if ('type' in method && method.type === 'terminal') {
        return {
          id: method.id, name: method.name, kind: 'terminal', fields: [],
          terminal: { args: method.args ?? [], env: method.env ?? {} },
        }
      }
      if (pack.id === 'codex-acp' && method.id === 'api-key') {
        return { id: method.id, name: method.name, kind: 'agent', fields: [
          { ref: 'OPENAI_API_KEY', name: 'OpenAI API key', env: 'OPENAI_API_KEY', required: true, secret: true },
        ] }
      }
      return { id: method.id, name: method.name, kind: 'agent', fields: [] }
    })
  } finally {
    child.terminate()
    await child.done.catch(() => undefined)
  }
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", "'\\''")}'`
}

function appleScriptQuote(value: string): string {
  return value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')
}

/**
 * Open ACP terminal authentication after an explicit macOS UI action.
 * @param ctx - Host context that owns the managed subprocess runtime.
 * @param pack - Admitted Pack whose command will be launched.
 * @param installationDirectory - Managed installation directory for the Pack.
 * @param method - Terminal method previously advertised by that Harness.
 */
export async function launchAcpTerminalAuthentication(
  ctx: Context,
  pack: HarnessPack,
  installationDirectory: string,
  method: HarnessAuthMethod,
): Promise<void> {
  if (method.kind !== 'terminal' || method.terminal === undefined) throw new Error('Selected authentication method is not interactive terminal login')
  if (process.platform !== 'darwin') throw new Error('Interactive Harness login currently requires the Open Fish macOS app')
  const launched = await managedLaunchArgv(pack, installationDirectory)
  const env = { ...launched.env, ...method.terminal.env }
  for (const key of Object.keys(env)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(key)) throw new Error(`Terminal authentication declared invalid environment key "${key}"`)
  }
  const command = [
    `cd -- ${shellQuote(installationDirectory)}`,
    ['env', ...Object.entries(env).map(([key, value]) => shellQuote(`${key}=${value}`)),
      ...[...launched.argv, ...method.terminal.args].map(shellQuote)].join(' '),
  ].join(' && ')
  const child = ctx.subprocess.spawn({
    argv: ['/usr/bin/osascript', '-e', 'tell application "Terminal"', '-e', 'activate',
      '-e', `do script "${appleScriptQuote(command)}"`, '-e', 'end tell'],
    cwd: installationDirectory,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 8 * 1024 }, stderr: { maxBytes: 16 * 1024 } },
    graceMs: 3_000,
  })
  const outcome = await child.done
  if (outcome.exitCode !== 0) {
    const detail = child.collected.stderr?.readFrom(0).text.trim() || `exit ${String(outcome.exitCode)}`
    throw new Error(`Could not open Harness login: ${sanitizeDiagnostic(detail)}`)
  }
}

function managedBinaryCommand(directory: string, command: string): string {
  const candidate = resolve(directory, normalize(command.replace(/^\.\//u, '')))
  const outside = relative(directory, candidate)
  if (outside.startsWith('..') || outside === '') throw new Error('Harness binary command must name a file inside its managed installation directory')
  return candidate
}

async function installBinaryHarness(
  ctx: Context,
  pack: HarnessPack,
  directory: string,
  signal?: AbortSignal,
): Promise<void> {
  const distribution = pack.distribution
  if (distribution?.kind !== 'binary') return
  if (pack.source === 'acp-registry' && distribution.sha256 === undefined) {
    throw new Error('Registry binary has no SHA-256 checksum; Open Fish will not install an unverifiable archive')
  }
  const response = await fetch(distribution.archive, signal === undefined ? {} : { signal })
  if (!response.ok) throw new Error(`Harness binary download failed with HTTP ${response.status}`)
  const data = new Uint8Array(await response.arrayBuffer())
  if (distribution.sha256 !== undefined) {
    const actual = createHash('sha256').update(data).digest('hex')
    if (actual.toLowerCase() !== distribution.sha256.toLowerCase()) throw new Error('Harness binary checksum mismatch')
  }
  const archiveName = new URL(distribution.archive).pathname.split('/').at(-1) || 'download'
  const archivePath = join(directory, archiveName)
  await writeFile(archivePath, data, { mode: 0o600 })
  const lower = archiveName.toLowerCase()
  const argv = lower.endsWith('.zip')
    ? (process.platform === 'darwin' ? ['/usr/bin/ditto', '-x', '-k', archivePath, directory] : ['unzip', '-q', archivePath, '-d', directory])
    : /\.(?:tar\.gz|tgz|tar\.bz2|tbz2)$/u.test(lower)
      ? ['tar', '-xf', archivePath, '-C', directory]
      : undefined
  if (argv !== undefined) {
    const listing = ctx.subprocess.spawn({
      argv: lower.endsWith('.zip') ? ['unzip', '-Z1', archivePath] : ['tar', '-tf', archivePath],
      cwd: directory,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 2 * 1024 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000,
    })
    const listed = await listing.done
    if (listed.exitCode !== 0) throw new Error('Harness archive could not be inspected safely')
    const entries = listing.collected.stdout?.readFrom(0).text.split(/\r?\n/u).filter(Boolean) ?? []
    if (entries.some(entry => entry.startsWith('/') || entry.startsWith('\\') || normalize(entry.replaceAll('\\', '/')).startsWith('..'))) {
      throw new Error('Harness archive contains a path outside its installation directory')
    }
    const child = ctx.subprocess.spawn({
      argv, cwd: directory, stdio: { stdin: 'ignore', stdout: { maxBytes: 32 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000, ...(signal === undefined ? {} : { signal }),
    })
    const outcome = await child.done
    if (outcome.exitCode !== 0) {
      throw new Error(`Harness binary extraction failed: ${child.collected.stderr?.readFrom(0).text.trim() || `exit ${String(outcome.exitCode)}`}`)
    }
  } else {
    await writeFile(managedBinaryCommand(directory, distribution.command), data, { mode: 0o700 })
  }
  const command = managedBinaryCommand(directory, distribution.command)
  if (!existsSync(command)) throw new Error(`Harness archive did not contain declared command "${distribution.command}"`)
  await rejectEscapingLinks(directory, directory)
  if (process.platform !== 'win32') await chmod(command, 0o700)
  if (archivePath !== command) await rm(archivePath, { force: true })
}

async function rejectEscapingLinks(root: string, directory: string): Promise<void> {
  for (const entry of await readdir(directory)) {
    const path = join(directory, entry)
    const stat = await lstat(path)
    if (stat.isSymbolicLink()) {
      const target = resolve(directory, await readlink(path))
      if (relative(root, target).startsWith('..')) throw new Error('Harness archive contains a symbolic link outside its installation directory')
    } else if (stat.isDirectory()) {
      await rejectEscapingLinks(root, path)
    }
  }
}

function promptBlocks(message: UserMessage): AcpContentBlock[] {
  const content: AcpContentBlock[] = []
  for (const block of message.content) {
    if (block.type === 'text') content.push({ type: 'text', text: block.text })
  }
  if (content.length === 0) throw new Error('This ACP Harness currently accepts text prompts only')
  return content
}

/** One external ACP session rendered through the ordinary DSH Agent/session lifecycle. */
export class AcpHarnessAgent implements Agent {
  readonly options: AgentOptions
  readonly inbox: Inbox
  private readonly scope: Scope
  readonly ctx: Context
  private phase: Phase
  private activity: Promise<void> = Promise.resolve()
  private process: SubprocessHandle | undefined
  private connection: ClientSideConnection | undefined
  private remoteSessionId: string | undefined
  private configOptions: SessionConfigOption[] = []
  private activeAssembler: BlockAssembler | undefined
  private activeChunkSeqs: number[] = []
  private pendingStartupUpdates: SessionNotification[] = []
  private maintenanceAbort: AbortController | undefined
  private readonly dispatch: AgentEventDispatch

  constructor(
    private readonly hostCtx: Context,
    public readonly id: SessionId,
    public readonly session: Session,
    private readonly pack: HarnessPack,
    private readonly installationDirectory: string,
    private readonly preferredAuthMethod?: string,
  ) {
    this.options = { provider: 'harness', model: pack.id }
    const lastTurn = session.events.findLast(event => event.type === 'turn/start')?.data.turn ?? 0
    this.phase = { kind: 'idle', turn: lastTurn }
    this.scope = createScope(hostCtx, this)
    this.ctx = this.scope.ctx.extend({ agent: this })
    this.dispatch = agentEvents(hostCtx, this)
    this.inbox = new Inbox(session, {
      inserted: (message) => { this.dispatch.emit('agent/inbox/inserted', { message }) },
      discarded: (message) => { this.dispatch.emit('agent/inbox/discarded', { message }) },
      claimed: (message, turn) => { this.dispatch.emit('agent/inbox/claimed', { message, turn }) },
    })
  }

  get status(): AgentStatus { return this.phase.kind === 'idle' ? 'idle' : 'running' }

  /**
   * Launch, initialize, and either create or load the remote ACP session.
   * @param resumeRemoteSessionId - Persisted ACP identity to load; absent creates a session.
   */
  async start(resumeRemoteSessionId?: string): Promise<void> {
    const { argv, env } = await managedLaunchArgv(this.pack, this.installationDirectory)
    const authEnv = await this.resolveAuthenticationEnvironment()
    const child = this.hostCtx.subprocess.spawn({
      argv,
      cwd: this.session.header.cwd ?? process.cwd(),
      stdio: { stdin: 'pipe', stdout: 'pipe', stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000,
      env: { ...env, ...authEnv },
    })
    if (child.stdin === undefined || child.stdout === undefined) {
      child.terminate()
      throw new Error('ACP Harness subprocess did not expose protocol pipes')
    }
    this.process = child
    const makeClient = (_agent: AcpConnection): Client => ({
      sessionUpdate: notification => this.sessionUpdate(notification),
      requestPermission: request => this.requestPermission(request),
    })
    const connection = new ClientSideConnection(
      makeClient,
      ndJsonStream(
        NodeWritable.toWeb(child.stdin) as WritableStream<Uint8Array>,
        NodeReadable.toWeb(child.stdout) as ReadableStream<Uint8Array>,
      ),
    )
    this.connection = connection
    try {
      const initialized = await connection.initialize({
        protocolVersion: PROTOCOL_VERSION,
        clientCapabilities: { plan: {}, auth: { terminal: true }, fs: { readTextFile: false, writeTextFile: false } },
        clientInfo: { name: 'open-fish', title: 'Open Fish', version: '0.1.0' },
      })
      const authMethods = initialized.authMethods ?? []
      const agentMethods = authMethods.filter(method => !('type' in method))
      const selectedPackMethod = this.pack.authMethods?.find(method => method.id === this.preferredAuthMethod)
      const hasOpenAiApiKey = process.env.CODEX_API_KEY !== undefined || process.env.OPENAI_API_KEY !== undefined
      const agentAuth = this.preferredAuthMethod === undefined
        ? (hasOpenAiApiKey
          ? agentMethods.find(method => method.id === 'api-key') ?? agentMethods[0]
          : agentMethods.find(method => method.id === 'chat-gpt') ?? agentMethods[0])
        : agentMethods.find(method => method.id === this.preferredAuthMethod)
      if (this.preferredAuthMethod !== undefined && selectedPackMethod?.kind === 'agent' && agentAuth === undefined) {
        throw new Error(`Harness "${this.pack.id}" does not advertise authentication method "${this.preferredAuthMethod}"`)
      }
      if (selectedPackMethod?.kind === 'terminal') {
        // The explicit login action ran the Pack's terminal command. The
        // resulting Harness-owned credentials are validated by session/new.
      } else if (selectedPackMethod?.kind === 'environment') {
        // Required fields were resolved before launch and are already scoped to this subprocess.
      } else if (agentAuth !== undefined) {
        const apiKey = agentAuth.id === 'api-key' ? await this.resolveOpenAiApiKey() : undefined
        await connection.authenticate({
          methodId: agentAuth.id,
          ...(apiKey === undefined ? {} : { _meta: { 'api-key': { apiKey } } }),
        })
      }
      else if (authMethods.length > 0 && selectedPackMethod === undefined) {
        throw new Error(`Harness "${this.pack.id}" requires an interactive or environment authentication method not yet configured in Open Fish`)
      }
      if (resumeRemoteSessionId !== undefined) {
        const request = { sessionId: resumeRemoteSessionId, cwd: this.session.header.cwd ?? process.cwd(), mcpServers: [] }
        // Prefer ACP's resume primitive: Open Fish already owns and renders
        // the durable transcript, so asking the Harness to stream its entire
        // history again is redundant. Codex advertises this capability and
        // its lightweight resume path is the reliable way to rejoin a thread.
        const loaded = initialized.agentCapabilities?.sessionCapabilities?.resume !== undefined
          ? await connection.resumeSession(request)
          : initialized.agentCapabilities?.loadSession
            ? await connection.loadSession(request)
            : undefined
        if (loaded === undefined) throw new Error(`Harness "${this.pack.id}" cannot resume sessions`)
        this.configOptions = loaded.configOptions ?? []
        this.remoteSessionId = resumeRemoteSessionId
      } else {
        const created = await connection.newSession({ cwd: this.session.header.cwd ?? process.cwd(), mcpServers: [] })
        this.configOptions = created.configOptions ?? []
        this.remoteSessionId = created.sessionId
      }
    } catch (error: unknown) {
      await this.disposeProcess()
      const diagnostic = startupDiagnostic(child)
      if (diagnostic !== undefined) {
        throw new Error(`ACP Harness "${this.pack.name}" failed to start: ${diagnostic}`, { cause: error })
      }
      throw error
    }
  }

  private async resolveAuthenticationEnvironment(): Promise<Record<string, string>> {
    const method = this.pack.authMethods?.find(candidate => candidate.id === this.preferredAuthMethod)
    if (method === undefined) return {}
    const credentials = this.hostCtx.get('credentials')
    const environment: Record<string, string> = {}
    for (const field of method.fields) {
      const value = await credentials?.resolve(credentialRef(field.ref))
      if (field.required && value === undefined) throw new Error(`Authentication needs ${field.name}`)
      if (value !== undefined && field.env !== undefined) environment[field.env] = value.value
    }
    return environment
  }

  private async resolveOpenAiApiKey(): Promise<string | undefined> {
    const credentials = this.hostCtx.get('credentials')
    if (credentials !== undefined) {
      for (const name of ['CODEX_API_KEY', 'OPENAI_API_KEY']) {
        const hit = await credentials.resolve(credentialRef(name))
        if (hit !== undefined) return hit.value
      }
    }
    return process.env.CODEX_API_KEY ?? process.env.OPENAI_API_KEY
  }

  /** Remote id committed after startup and before publication. */
  commitSelection(): void {
    if (this.remoteSessionId === undefined) throw new Error('ACP Harness session is not ready')
    this.session.append('harness/selected', {
      harnessId: this.pack.id,
      version: this.pack.version,
      protocol: 'acp',
      remoteSessionId: this.remoteSessionId,
    })
    this.observeKinds(['protocol-adapter'], 'completed', 'ACP connection initialized')
    this.observeKinds(['agent-session'], 'waiting', 'Harness session ready')
    const buffered = this.pendingStartupUpdates
    this.pendingStartupUpdates = []
    for (const update of buffered) void this.recordSessionUpdate(update)
  }

  /**
   * Read the current model directory without mutating the ACP session.
   * @returns Live model directory advertised by this ACP Harness, when present.
   */
  harnessModelCatalog(): AcpHarnessModelCatalog | undefined {
    return acpHarnessModelCatalog(this.configOptions)
  }

  /**
   * Read the complete current configuration directory without mutating the session.
   * @returns Complete live ACP configuration directory, including future categories.
   */
  harnessConfigCatalog(): AcpHarnessConfigOption[] {
    return acpHarnessConfigCatalog(this.configOptions)
  }

  /** Apply Pack defaults against this Harness's live ACP capability directory. */
  async applyPackConfiguration(): Promise<void> {
    for (const option of packSessionConfiguration(this.pack)) {
      await this.selectHarnessConfig(option.id, option.value)
    }
  }

  /**
   * Set an ACP option and replace the local directory with its authoritative response.
   * @param configId - Live ACP configuration id.
   * @param value - Advertised select value or boolean state.
   * @returns Refreshed live configuration directory.
   */
  async selectHarnessConfig(configId: string, value: string | boolean): Promise<AcpHarnessConfigOption[]> {
    const connection = this.connection
    const remoteSessionId = this.remoteSessionId
    const config = this.configOptions.find(option => option.id === configId)
    if (connection === undefined || remoteSessionId === undefined || config === undefined) {
      throw new Error(`Harness "${this.pack.id}" does not expose configuration option "${configId}"`)
    }
    if (config.type === 'boolean') {
      if (typeof value !== 'boolean') throw new Error(`Harness option "${configId}" requires a boolean value`)
    } else {
      if (typeof value !== 'string' || !flattenedSelectOptions(config).some(candidate => candidate.value === value)) {
        throw new Error(`Harness "${this.pack.id}" does not advertise value "${String(value)}" for option "${configId}"`)
      }
    }
    const response = await connection.setSessionConfigOption({
      sessionId: remoteSessionId,
      configId,
      ...(config.type === 'boolean' ? { type: 'boolean' as const, value: value as boolean } : { value: value as string }),
    })
    this.configOptions = response.configOptions
    return this.harnessConfigCatalog()
  }

  /**
   * Select an ACP-advertised model and optional standard thought level.
   * @param model - Model id advertised by the live Harness.
   * @param reasoningEffort - Optional thought-level id advertised after model selection.
   * @returns Authoritative selected model and optional reasoning effort.
   */
  async selectHarnessModel(model: string, reasoningEffort?: string): Promise<{ model: string; reasoningEffort?: string }> {
    const connection = this.connection
    const remoteSessionId = this.remoteSessionId
    const catalog = this.harnessModelCatalog()
    const config = this.configOptions.find(option => option.type === 'select' && option.category === 'model')
    if (connection === undefined || remoteSessionId === undefined || catalog === undefined || config === undefined) {
      throw new Error(`Harness "${this.pack.id}" does not expose model selection`)
    }
    if (!catalog.models.some(candidate => candidate.id === model)) {
      throw new Error(`Harness "${this.pack.id}" does not advertise model "${model}"`)
    }
    const response = await connection.setSessionConfigOption({
      sessionId: remoteSessionId,
      configId: config.id,
      value: model,
    })
    this.configOptions = response.configOptions
    if (reasoningEffort !== undefined) {
      const thought = this.configOptions.find(option => option.type === 'select' && option.category === 'thought_level')
      if (thought === undefined || thought.type !== 'select') {
        throw new Error(`Harness "${this.pack.id}" does not expose reasoning effort selection`)
      }
      const advertised = flattenedSelectOptions(thought)
      if (!advertised.some(candidate => candidate.value === reasoningEffort)) {
        throw new Error(`Harness "${this.pack.id}" does not advertise reasoning effort "${reasoningEffort}" for model "${model}"`)
      }
      const effortResponse = await connection.setSessionConfigOption({
        sessionId: remoteSessionId,
        configId: thought.id,
        value: reasoningEffort,
      })
      this.configOptions = effortResponse.configOptions
    }
    const selected = this.harnessModelCatalog()
    return {
      model: selected?.current ?? model,
      ...(selected?.currentReasoningEffort === undefined ? {} : { reasoningEffort: selected.currentReasoningEffort }),
    }
  }

  send(message: UserMessage, target: InboxTarget, wakeup: boolean): void {
    this.inbox.append(target, message)
    if (wakeup) this.wake()
  }
  followup(message: UserMessage): void { this.send(message, 'next-turn', true) }
  steer(message: UserMessage): void { this.send(message, 'next-step', true) }
  inject(message: UserMessage): void { this.send(message, 'next-step', false) }

  cancel(cause: AgentCancelCause, options: CancelOptions = {}): void {
    if (!options.keepInbox) this.inbox.clear()
    this.maintenanceAbort?.abort(cause)
    if (this.phase.kind === 'running') {
      this.phase.abort.abort(cause)
      if (this.remoteSessionId !== undefined) {
        // A process that exits concurrently has already enacted the cancel.
        void this.connection?.cancel({ sessionId: this.remoteSessionId }).catch(() => undefined)
      }
    }
  }

  async whenIdle(): Promise<void> {
    let observed: Promise<void>
    do await (observed = this.activity)
    while (observed !== this.activity)
  }

  runMaintenance<T>(task: (signal: AbortSignal) => Promise<T>): Promise<T> {
    if (this.phase.kind !== 'idle' || this.maintenanceAbort !== undefined) throw new Error(`agent "${this.id}" already has active work`)
    const abort = new AbortController()
    this.maintenanceAbort = abort
    const operation = task(abort.signal).finally(() => {
      this.maintenanceAbort = undefined
      if (this.inbox.hasPending) this.wake()
    })
    this.activity = operation.then(() => undefined, () => undefined)
    return operation
  }

  private wake(): void {
    if (this.phase.kind !== 'idle' || this.maintenanceAbort !== undefined) return
    const done = Promise.withResolvers<void>()
    this.activity = done.promise
    const running: Phase = { kind: 'running', turn: this.phase.turn, abort: new AbortController() }
    this.phase = running
    this.dispatch.emit('agent/status', { status: 'running' })
    void this.hostCtx.agents.withInitiator(this, () => this.drive(running)).then(done.resolve, done.reject)
  }

  private async drive(running: Extract<Phase, { kind: 'running' }>): Promise<void> {
    try {
      while (this.inbox.hasPending && !running.abort.signal.aborted) await this.turn(running)
    } catch (error: unknown) {
      this.dispatch.emit('agent/error', { turn: running.turn, step: 1, error })
    } finally {
      this.phase = { kind: 'idle', turn: running.turn }
      this.dispatch.emit('agent/status', { status: 'idle' })
      if (this.inbox.hasPending) this.wake()
    }
  }

  private async turn(running: Extract<Phase, { kind: 'running' }>): Promise<void> {
    const turn = ++running.turn
    let reason: TurnEndReason = { kind: 'completed' }
    let stepStarted = false
    this.session.append('turn/start', { turn })
    this.observeKinds(['agent-session', 'agent-loop', 'context-runtime', 'context-loader'], 'active', `Turn ${turn} started`)
    try {
      const messages = [
        ...this.inbox.claim('next-turn', turn),
        ...this.inbox.claim('next-step', turn),
      ]
      if (messages.length === 0) return
      this.session.append('step/start', { turn, step: 1 })
      stepStarted = true
      for (const message of messages) this.session.append('user/message', message, { surfaceOp: 'append' })
      this.activeAssembler = new BlockAssembler()
      this.activeChunkSeqs = []
      const connection = this.connection
      const remoteSessionId = this.remoteSessionId
      if (connection === undefined || remoteSessionId === undefined) throw new Error('ACP Harness connection is not ready')
      const result = await connection.prompt({
        sessionId: remoteSessionId,
        prompt: messages.flatMap(promptBlocks),
      })
      this.observeKinds(['model-client', 'model-router', 'model-registry'], 'completed', `Turn ${turn} inference completed`)
      const assembler = this.activeAssembler
      const content = assembler.blocks()
      if (content.length > 0) {
        this.session.append('assistant/message', {
          turn,
          step: 1,
          message: createAssistantMessage({ content, source: { provider: 'harness', model: this.pack.id } }),
        }, { surfaceOp: 'append', sourceEventSeqs: this.activeChunkSeqs })
      }
      if (result.stopReason === 'cancelled') reason = { kind: 'aborted', reason: { kind: 'user' } }
      else if (result.stopReason === 'max_tokens') reason = { kind: 'max-tokens' }
      else if (result.stopReason !== 'end_turn') reason = { kind: 'error', error: { code: 'ACP_STOP', message: result.stopReason } }
    } catch (error: unknown) {
      if (running.abort.signal.aborted) reason = { kind: 'aborted', reason: running.abort.signal.reason as AgentCancelCause }
      else reason = { kind: 'error', error: { code: 'ACP_ERROR', message: error instanceof Error ? error.message : String(error) } }
      this.observeKinds(['agent-session', 'agent-loop'], 'failed', `Turn ${turn} failed`)
      throw error
    } finally {
      this.activeAssembler = undefined
      this.activeChunkSeqs = []
      if (stepStarted) this.session.append('step/end', { turn, step: 1 })
      this.session.append('turn/end', { turn, reason })
      if (reason.kind !== 'error') this.observeKinds(['agent-session', 'agent-loop'], 'waiting', `Turn ${turn} finished`)
    }
  }

  private sessionUpdate(params: SessionNotification): Promise<void> {
    if (this.session.events.findLast(event => event.type === 'harness/selected') === undefined) {
      this.pendingStartupUpdates.push(params)
      return Promise.resolve()
    }
    return this.recordSessionUpdate(params)
  }

  private recordSessionUpdate(params: SessionNotification): Promise<void> {
    const update = params.update
    if (update.sessionUpdate === 'config_option_update') this.configOptions = update.configOptions
    this.session.append('harness/native-event', { harnessId: this.pack.id, event: update })
    if (update.sessionUpdate.includes('tool')) {
      this.observeKinds(['tool-runtime', 'tool-registry'], 'active', update.sessionUpdate)
    }
    if (update.sessionUpdate === 'agent_message_chunk' && update.content.type === 'text' && this.activeAssembler !== undefined) {
      const event = this.session.append('assistant/chunk', {
        turn: this.phase.kind === 'running' ? this.phase.turn : 0,
        step: 1,
        chunk: { type: 'text-delta', index: 0, text: update.content.text },
      })
      this.activeChunkSeqs.push(event.seq)
      this.activeAssembler.push(event.data.chunk)
    }
    return Promise.resolve()
  }

  private async requestPermission(request: RequestPermissionRequest): Promise<RequestPermissionResponse> {
    const allow = request.options.find(option => option.kind === 'allow_once' || option.kind === 'allow_always')
    const reject = request.options.find(option => option.kind === 'reject_once' || option.kind === 'reject_always')
    const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
    this.observeKinds(['permission-policy'], 'active', request.toolCall.title ?? 'Permission requested')
    const outcome = await this.hostCtx.approval.request({
      agent: this,
      toolName: request.toolCall.title ?? 'External Harness action',
      reason: `Requested by ${this.pack.name}`,
      ...(signal === undefined ? {} : { signal }),
    })
    const selected = outcome === 'allowed-once' ? allow : reject
    this.observeKinds(['permission-policy'], 'completed', outcome)
    return selected === undefined
      ? { outcome: { outcome: 'cancelled' } }
      : { outcome: { outcome: 'selected', optionId: selected.optionId } }
  }

  private observeKinds(kinds: string[], status: 'active' | 'waiting' | 'completed' | 'failed', activity: string): void {
    for (const node of this.pack.graph.nodes) {
      if (!kinds.includes(node.kind)) continue
      this.session.append('harness/runtime-node', { harnessId: this.pack.id, nodeId: node.id, status, activity })
    }
  }

  /** Stop the remote session and release its process and scoped registrations. */
  async dispose(): Promise<void> {
    this.cancel({ kind: 'disposed' })
    await this.whenIdle()
    await this.scope.dispose()
    await this.disposeProcess()
  }

  private async disposeProcess(): Promise<void> {
    const child = this.process
    this.process = undefined
    if (child === undefined) return
    child.stdin?.end()
    const timeout = AbortSignal.timeout(1_000)
    if (!await child.waitForExit(timeout)) child.terminate()
    await child.waitForExit()
  }
}

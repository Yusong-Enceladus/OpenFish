/** Durable DSH Agent projection over one persistent ACP subprocess session. @module */

import { basename, dirname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Readable as NodeReadable, Transform, Writable as NodeWritable } from 'node:stream'
import { pipeline } from 'node:stream/promises'
import { StringDecoder } from 'node:string_decoder'
import { closeSync, constants, createReadStream, existsSync, mkdirSync, openSync, writeSync } from 'node:fs'
import { access, chmod, lstat, mkdir, open, readdir, readFile, realpath, rename, rm } from 'node:fs/promises'
import { createHash, randomUUID } from 'node:crypto'
import {
  ClientSideConnection,
  CreateElicitationRequest as AcpCreateElicitationRequest,
  ElicitationPropertySchema as AcpElicitationPropertySchema,
  MultiSelectItems as AcpMultiSelectItems,
  PROTOCOL_VERSION,
  type Agent as AcpConnection,
  type Client,
  type ContentBlock as AcpContentBlock,
  type BooleanPropertySchema,
  type CreateElicitationRequest,
  type CreateElicitationResponse,
  type CreateTerminalRequest,
  type ElicitationContentValue,
  type ElicitationPropertySchema,
  type IntegerPropertySchema,
  type KillTerminalRequest,
  type MultiSelectPropertySchema,
  type NumberPropertySchema,
  type ReadTextFileRequest,
  type ReleaseTerminalRequest,
  type RequestPermissionRequest,
  type RequestPermissionResponse,
  type SessionConfigOption,
  type SessionModeState,
  type SessionNotification,
  type StringPropertySchema,
  type StringMultiSelectItems,
  type TitledMultiSelectItems,
  type TerminalOutputRequest,
  type WaitForTerminalExitRequest,
  type WriteTextFileRequest,
} from '@agentclientprotocol/sdk'
import type { Context } from '@deepseek-ai/cordis'
import { agentEvents, Inbox, type Agent, type AgentCancelCause, type AgentEventDispatch, type AgentOptions, type AgentStatus, type CancelOptions, type InboxTarget } from '@deepseek-ai/dsh-agent'
import type { AttachmentStore, ImageMediaType } from '@deepseek-ai/dsh-attachment'
import { BlockAssembler, createAssistantMessage, type UserMessage } from '@deepseek-ai/dsh-llm'
import { createScope, type Scope } from '@deepseek-ai/dsh-scope'
import type { Session, SessionId, TurnEndReason } from '@deepseek-ai/dsh-session'
import {
  observeHarnessRuntime,
  parseHarnessPack,
  safeHarnessDiagnostic,
  type HarnessAuthMethod,
  type HarnessCapability,
  type HarnessPack,
  type HarnessRuntimeSignal,
  type HarnessSessionRequest,
} from '@deepseek-ai/dsh-harness'
import type { SubprocessHandle, SubprocessOutcome, SubprocessTerminalHandle } from '@deepseek-ai/dsh-subprocess'
import type { SandboxMode } from '@deepseek-ai/dsh-sandbox'
import type { SandboxAuthorityController } from '@deepseek-ai/dsh-sandbox-policy'
import type {} from '@deepseek-ai/dsh-user-approval'
import type { AskUserQuestionAnswer, AskUserQuestionAnswerItem, AskUserQuestionItem } from '@deepseek-ai/dsh-user-questions'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { Unzip, UnzipInflate } from 'fflate'
import { extract as extractTar, type TarOptionsWithAliasesAsyncNoFile } from 'tar'
import unbzip2Stream from 'unbzip2-stream'
import { prepareHarnessProcess } from './process-authority.ts'
import { abortableHarnessOperation, harnessStartupError, harnessStartupSignal, harnessTransportClosed } from './startup.ts'
import { boundedAcpNdJsonStream } from './acp-stream.ts'
import { durableAcpSessionUpdate } from './native-event.ts'

type Phase = { kind: 'idle'; turn: number } | { kind: 'running'; turn: number; abort: AbortController }

interface AcpSessionSelectionSnapshot {
  mode?: string
  options: Array<{ id: string; value: string | boolean; category?: string }>
}

/** One model and its optional reasoning directory advertised by an ACP Harness. */
export interface AcpHarnessModelOption {
  id: string
  name: string
  description?: string
  /** Provider identity only when the live ACP option groups declare it. */
  providerId?: string
  providerName?: string
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
  /** Runtime-reported, non-secret billing boundary when the protocol exposes one. */
  account?: {
    label: string
    billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
    detail: string
  }
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
 * Resolve portable session defaults declared by typed controls on editable
 * Pack nodes. Driver-owned bindings map fields to standard ACP configuration
 * ids, so this remains generic when a new Harness appears.
 * @param pack - Admitted Pack whose composable nodes may declare defaults.
 * @returns Ordered ACP option assignments for a newly created session.
 */
export function packSessionConfiguration(pack: HarnessPack): Array<{ id: string; value: string | boolean }> {
  if (pack.graph.level !== 'composable') return []
  const resolved = new Map<string, string | boolean>()
  for (const node of pack.graph.nodes) {
    if (!node.editable || node.config === undefined) continue
    for (const field of node.configSchema?.fields ?? []) {
      if (field.binding.kind !== 'acp-session-option') continue
      const value = node.config[field.id]
      if (value === undefined) {
        if (field.required) throw new Error(`Harness Pack node "${node.id}" requires configuration field "${field.id}"`)
        continue
      }
      if (typeof value !== 'string' && typeof value !== 'boolean') {
        throw new Error(`Harness Pack node "${node.id}" has an invalid value for "${field.id}"`)
      }
      const previous = resolved.get(field.binding.target)
      if (previous !== undefined && previous !== value) {
        throw new Error(`Harness Pack declares conflicting values for ACP session option "${field.binding.target}"`)
      }
      resolved.set(field.binding.target, value)
    }
  }
  return [...resolved].map(([id, value]) => ({ id, value }))
}

function flattenedSelectOptions(option: Extract<SessionConfigOption, { type: 'select' }>) {
  return option.options.flatMap(entry => 'group' in entry ? entry.options : [entry])
}

const MAX_ACP_CONFIG_OPTIONS = 128
const MAX_ACP_CONFIG_VALUES = 1_024
const MAX_ACP_ID_CODE_POINTS = 256
const MAX_ACP_LABEL_CODE_POINTS = 256
const MAX_ACP_DESCRIPTION_CODE_POINTS = 2_048

function validAcpText(value: unknown, maximum: number, allowEmpty = false): value is string {
  if (typeof value !== 'string') return false
  const length = Array.from(value).length
  return (allowEmpty || value.trim().length > 0) && length <= maximum && !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)
}

/**
 * Admit one bounded, unambiguous ACP configuration directory before UI projection or mutation.
 * @param input - Untrusted live ACP configuration options.
 * @returns A validated, bounded option directory.
 */
export function admitAcpSessionConfigOptions(input: readonly SessionConfigOption[]): SessionConfigOption[] {
  if (!Array.isArray(input) || input.length > MAX_ACP_CONFIG_OPTIONS) {
    throw new Error(`ACP configuration directory exceeds ${MAX_ACP_CONFIG_OPTIONS} options`)
  }
  const optionIds = new Set<string>()
  for (const raw of input) {
    const option = raw as SessionConfigOption & Record<string, unknown>
    if (!validAcpText(option.id, MAX_ACP_ID_CODE_POINTS) || optionIds.has(option.id)) {
      throw new Error('ACP configuration option ids must be unique, non-empty, and bounded')
    }
    optionIds.add(option.id)
    if (!validAcpText(option.name, MAX_ACP_LABEL_CODE_POINTS)) {
      throw new Error(`ACP configuration option "${option.id}" has an invalid label`)
    }
    if (option.description !== undefined && option.description !== null
      && !validAcpText(option.description, MAX_ACP_DESCRIPTION_CODE_POINTS, true)) {
      throw new Error(`ACP configuration option "${option.id}" has an invalid description`)
    }
    if (option.category !== undefined && option.category !== null
      && !validAcpText(option.category, MAX_ACP_ID_CODE_POINTS)) {
      throw new Error(`ACP configuration option "${option.id}" has an invalid category`)
    }
    if (option.type === 'boolean') {
      if (typeof option.currentValue !== 'boolean') {
        throw new Error('ACP boolean configuration option requires a boolean current value')
      }
      continue
    }
    if (option.type !== 'select' || !Array.isArray(option.options)) {
      throw new Error('ACP configuration option has an unsupported type')
    }
    const values = flattenedSelectOptions(option)
    if (values.length === 0 || values.length > MAX_ACP_CONFIG_VALUES) {
      throw new Error(`ACP configuration option "${option.id}" has an invalid choice count`)
    }
    const valueIds = new Set<string>()
    for (const entry of option.options) {
      if ('group' in entry) {
        if (!validAcpText(entry.group, MAX_ACP_ID_CODE_POINTS)
          || !validAcpText(entry.name, MAX_ACP_LABEL_CODE_POINTS)) {
          throw new Error(`ACP configuration option "${option.id}" has an invalid choice group`)
        }
      }
    }
    for (const value of values) {
      if (!validAcpText(value.value, MAX_ACP_ID_CODE_POINTS) || valueIds.has(value.value)
        || !validAcpText(value.name, MAX_ACP_LABEL_CODE_POINTS)) {
        throw new Error(`ACP configuration option "${option.id}" has duplicate or invalid choices`)
      }
      valueIds.add(value.value)
      if (value.description !== undefined && value.description !== null
        && !validAcpText(value.description, MAX_ACP_DESCRIPTION_CODE_POINTS, true)) {
        throw new Error(`ACP configuration option "${option.id}" has an invalid choice description`)
      }
    }
    if (!validAcpText(option.currentValue, MAX_ACP_ID_CODE_POINTS)
      || !valueIds.has(option.currentValue)) {
      throw new Error(`ACP configuration option "${option.id}" selected an unadvertised value`)
    }
  }
  return [...input]
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
  const flattened: Array<{
    value: ReturnType<typeof flattenedSelectOptions>[number]
    providerId?: string
    providerName?: string
  }> = option.options.flatMap(entry => 'group' in entry
    ? entry.options.map(value => ({ value, providerId: entry.group, providerName: entry.name }))
    : [{ value: entry }])
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
      id: entry.value.value,
      name: entry.value.name,
      ...(entry.value.description === undefined || entry.value.description === null ? {} : { description: entry.value.description }),
      ...(entry.providerId === undefined ? {} : { providerId: entry.providerId }),
      ...(entry.providerName === undefined ? {} : { providerName: entry.providerName }),
      // ACP only advertises thought levels for the active model. Project them
      // onto that exact route; after a model switch the authoritative config
      // response refreshes both the model and its supported effort set.
      ...(entry.value.value === option.currentValue && efforts.length > 0
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
    if (!existsSync(candidate)) {
      throw new Error('The packaged OpenFish runtime is incomplete: its pinned uv executable is missing')
    }
    return candidate
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
  const candidate = join(runtimeRoot, 'app', 'node_modules', packageName, relativePath)
  if (!existsSync(candidate)) {
    throw new Error(`The packaged OpenFish runtime is incomplete: its pinned ${packageName} executable is missing`)
  }
  return candidate
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

/**
 * Resolve the managed agent binary without its ordinary ACP/session arguments.
 * @param pack - admitted Pack defining the exact distribution.
 * @param directory - exact managed installation directory.
 * @returns argv prefix for the pinned executable and its required runtime.
 */
export async function managedExecutableArgv(pack: HarnessPack, directory: string): Promise<string[]> {
  const launched = await managedLaunchArgv(pack, directory)
  return pack.distribution?.kind === 'bunx'
    ? launched.argv.slice(0, 2)
    : launched.argv.slice(0, 1)
}

/**
 * Build the private success marker for one terminal login without credential data.
 * @param runtimeDirectory - managed per-Pack runtime root.
 * @param methodId - stable authentication method identity.
 * @returns opaque method-specific completion-marker path.
 */
export function terminalAuthenticationMarker(runtimeDirectory: string, methodId: string): string {
  const digest = createHash('sha256').update(methodId).digest('hex').slice(0, 24)
  return join(runtimeDirectory, 'authentication', `${digest}.complete`)
}

function startupDiagnostic(child: SubprocessHandle): string | undefined {
  const stderr = child.collected.stderr?.readFrom(0).text.trim()
  if (stderr === undefined || stderr === '') return undefined
  return safeHarnessDiagnostic(
    stderr.split(/\r?\n/u).filter(line => line.trim() !== '').slice(-12).join(' | ').slice(0, 1_600),
  )
}

/**
 * Materialize one package distribution beneath Open Fish's managed state root.
 * @param ctx - Host context that owns the subprocess boundary.
 * @param pack - Admitted package-backed Harness definition.
 * @param directory - Exact managed version destination.
 * @param runtimeDirectory - Private mutable runtime root used during installation.
 * @param signal - Optional package-manager cancellation.
 */
export async function installHarnessPack(
  ctx: Context,
  pack: HarnessPack,
  directory: string,
  runtimeDirectory: string,
  signal?: AbortSignal,
): Promise<void> {
  const distribution = pack.distribution
  if (distribution === undefined) return
  // Executable Packs do not copy third-party code, but their session process
  // still launches with the exact managed-version directory as cwd. Create
  // that snapshot boundary before recording the Pack as installed; otherwise
  // a valid user-authored local Pack fails its first session with a closed
  // stdin/EPIPE because the subprocess cwd does not exist.
  if (distribution.kind === 'executable') {
    await mkdir(directory, { recursive: true })
    return
  }
  await mkdir(directory, { recursive: true })
  if (distribution.kind === 'binary') {
    await installBinaryHarness(pack, directory, signal)
    return
  }
  if (distribution.kind === 'uvx') {
    await ctx.subprocess.resolveExecutable(uvCliPath())
    const launch = await prepareHarnessProcess(ctx, {
      argv: [uvCliPath(), 'tool', 'install', '--force', distribution.package], cwd: directory,
      installationDirectory: directory, runtimeDirectory, purpose: 'install',
      env: { UV_TOOL_DIR: join(directory, 'tools'), UV_TOOL_BIN_DIR: join(directory, 'bin') },
    })
    const child = ctx.subprocess.spawn({
      argv: launch.argv, cwd: directory, env: launch.env,
      stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000, ...(signal === undefined ? {} : { signal }),
    })
    const outcome = await child.done
    if (outcome.exitCode !== 0) {
      const diagnostic = child.collected.stderr?.readFrom(0).text.trim()
        || child.collected.stdout?.readFrom(0).text.trim() || `exit ${String(outcome.exitCode)}`
      throw new Error(`Harness Python package installation failed: ${safeHarnessDiagnostic(diagnostic)}`)
    }
    return
  }
  const argv = distribution.kind === 'npx'
    ? [process.execPath, npmCliPath(), 'install', '--prefix', directory, '--no-save', '--package-lock=false', distribution.package]
    : [bunCliPath(), 'add', '--cwd', directory, distribution.package]
  const launch = await prepareHarnessProcess(ctx, {
    argv, cwd: directory, installationDirectory: directory, runtimeDirectory, purpose: 'install',
  })
  const child = ctx.subprocess.spawn({
    argv: launch.argv,
    cwd: directory,
    env: launch.env,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 64 * 1024 }, stderr: { maxBytes: 64 * 1024 } },
    graceMs: 3_000,
    ...(signal === undefined ? {} : { signal }),
  })
  const outcome = await child.done
  if (outcome.exitCode !== 0) {
    const diagnostic = child.collected.stderr?.readFrom(0).text.trim()
      || child.collected.stdout?.readFrom(0).text.trim()
      || `exit ${String(outcome.exitCode)}`
    throw new Error(`Harness package installation failed: ${safeHarnessDiagnostic(diagnostic)}`)
  }
}

/**
 * Launch only through ACP initialize to materialize Harness-owned authentication.
 * @param ctx - Host context that owns the managed subprocess runtime.
 * @param pack - Admitted Pack to probe.
 * @param installationDirectory - Managed installation directory for the Pack.
 * @param runtimeDirectory - Private mutable runtime root for the probe.
 * @returns Authentication methods advertised during ACP initialization.
 */
export async function discoverAcpAuthentication(
  ctx: Context,
  pack: HarnessPack,
  installationDirectory: string,
  runtimeDirectory: string,
): Promise<HarnessAuthMethod[]> {
  const { argv, env } = await managedLaunchArgv(pack, installationDirectory)
  const launch = await prepareHarnessProcess(ctx, {
    argv, env, cwd: installationDirectory, installationDirectory, runtimeDirectory, purpose: 'authentication',
  })
  const child = ctx.subprocess.spawn({
    argv: launch.argv, cwd: installationDirectory, env: launch.env,
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
    boundedAcpNdJsonStream(
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
    const advertised = initialized.authMethods ?? []
    if (!Array.isArray(advertised) || advertised.length > 32) {
      throw new Error('ACP Harness advertised too many authentication methods')
    }
    const methods = advertised.map((method): HarnessAuthMethod => {
      if ('type' in method && method.type === 'terminal') {
        if ((method.args?.length ?? 0) > 128 || Object.keys(method.env ?? {}).length > 128) {
          throw new Error('ACP Harness terminal authentication exceeds the supported process configuration limits')
        }
        return {
          id: method.id, name: method.name, kind: 'terminal', fields: [],
          terminal: { args: method.args ?? [], env: method.env ?? {} },
        }
      }
      return { id: method.id, name: method.name, kind: 'agent', fields: [] }
    })
    // Reuse Pack admission so discovery cannot bypass the exact same scalar,
    // process, secret-reference, and duplicate-id rules as authored Packs.
    return parseHarnessPack({ ...pack, authMethods: methods }).authMethods ?? []
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
 * @param runtimeDirectory - Private mutable runtime root for the login.
 * @param method - Terminal method previously advertised by that Harness.
 * @param signal - Optional cancellation while waiting for login completion.
 */
export async function launchAcpTerminalAuthentication(
  ctx: Context,
  pack: HarnessPack,
  installationDirectory: string,
  runtimeDirectory: string,
  method: HarnessAuthMethod,
  signal?: AbortSignal,
): Promise<void> {
  if (method.kind !== 'terminal' || method.terminal === undefined) throw new Error('Selected authentication method is not interactive terminal login')
  if (process.platform !== 'darwin') throw new Error('Interactive Harness login currently requires the Open Fish macOS app')
  const executable = await managedExecutableArgv(pack, installationDirectory)
  const successMarker = terminalAuthenticationMarker(runtimeDirectory, method.id)
  await launchManagedTerminalAuthentication(ctx, {
    argv: [...executable, ...method.terminal.args],
    env: { ...(pack.distribution?.env ?? {}), ...method.terminal.env },
    installationDirectory,
    runtimeDirectory,
    successMarker,
  }, signal)
}

interface ManagedTerminalAuthenticationRequest {
  argv: string[]
  env: Record<string, string>
  installationDirectory: string
  runtimeDirectory: string
  authenticationRoots?: string[]
  completionFile?: string
  successMarker?: string
}

/**
 * Open one shell-free managed login command and optionally wait for its private completion marker.
 * @param ctx - Host context owning the subprocess boundary.
 * @param request - exact argv, private roots, environment, and completion marker.
 * @param signal - optional cancellation while waiting for the marker.
 */
export async function launchManagedTerminalAuthentication(
  ctx: Context,
  request: ManagedTerminalAuthenticationRequest,
  signal?: AbortSignal,
): Promise<void> {
  if (process.platform !== 'darwin') throw new Error('Interactive Harness login currently requires the Open Fish macOS app')
  if (request.successMarker !== undefined) {
    await mkdir(dirname(request.successMarker), { recursive: true, mode: 0o700 })
    await rm(request.successMarker, { force: true })
  }
  const launch = await prepareHarnessProcess(ctx, {
    argv: request.argv,
    env: request.env,
    cwd: request.installationDirectory,
    installationDirectory: request.installationDirectory,
    runtimeDirectory: request.runtimeDirectory,
    purpose: 'authentication',
    ...(request.authenticationRoots === undefined ? {} : { authenticationRoots: request.authenticationRoots }),
  })
  const env = launch.env
  for (const key of Object.keys(env)) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(key)) throw new Error(`Terminal authentication declared invalid environment key "${key}"`)
  }
  const command = [
    `cd -- ${shellQuote(request.installationDirectory)}`,
    ['env', '-i', ...Object.entries(env).flatMap(([key, value]) => value === undefined ? [] : [shellQuote(`${key}=${value}`)]),
      ...launch.argv.map(shellQuote)].join(' '),
    ...(request.successMarker === undefined ? [] : [`/usr/bin/touch -- ${shellQuote(request.successMarker)}`]),
  ].join(' && ')
  const child = ctx.subprocess.spawn({
    argv: ['/usr/bin/osascript', '-e', 'tell application "Terminal"', '-e', 'activate',
      '-e', `do script "${appleScriptQuote(command)}"`, '-e', 'end tell'],
    cwd: request.installationDirectory,
    stdio: { stdin: 'ignore', stdout: { maxBytes: 8 * 1024 }, stderr: { maxBytes: 16 * 1024 } },
    graceMs: 3_000,
  })
  const outcome = await child.done
  if (outcome.exitCode !== 0) {
    const detail = child.collected.stderr?.readFrom(0).text.trim() || `exit ${String(outcome.exitCode)}`
    throw new Error(`Could not open Harness login: ${safeHarnessDiagnostic(detail)}`)
  }
  const completionFile = request.completionFile ?? request.successMarker
  if (completionFile !== undefined) {
    await waitForAuthenticationFile(completionFile, signal)
  }
}

async function waitForAuthenticationFile(path: string, signal?: AbortSignal): Promise<void> {
  const timeout = AbortSignal.timeout(10 * 60 * 1_000)
  const combined = signal === undefined ? timeout : AbortSignal.any([signal, timeout])
  while (!combined.aborted) {
    try {
      await access(path)
      return
    } catch {
      await new Promise<void>((resolve, reject) => {
        const aborted = () => {
          clearTimeout(timer)
          const reason: unknown = combined.reason
          reject(reason instanceof Error ? reason : new Error('Harness authentication was cancelled'))
        }
        const timer = setTimeout(() => {
          combined.removeEventListener('abort', aborted)
          resolve()
        }, 500)
        combined.addEventListener('abort', aborted, { once: true })
      })
    }
  }
  const reason: unknown = combined.reason
  throw reason instanceof Error ? reason : new Error('Harness authentication timed out')
}

function managedBinaryCommand(directory: string, command: string): string {
  const candidate = resolve(directory, normalize(command.replace(/^\.\//u, '')))
  const outside = relative(directory, candidate)
  if (outside.startsWith('..') || outside === '') throw new Error('Harness binary command must name a file inside its managed installation directory')
  return candidate
}

const MAXIMUM_ARCHIVE_ENTRIES = 20_000
const MAXIMUM_ARCHIVE_PATH_BYTES = 1_024
const MAXIMUM_UNPACKED_BYTES = 2 * 1024 * 1024 * 1024

function safeArchiveTarget(directory: string, name: string): { path: string; directory: boolean } {
  if (name.includes('\0') || Buffer.byteLength(name, 'utf8') > MAXIMUM_ARCHIVE_PATH_BYTES) {
    throw new Error('Harness archive contains an invalid or overlong path')
  }
  const portable = name.replaceAll('\\', '/')
  const normalized = normalize(portable)
  if ((normalized === '.' || normalized === `.${sep}`) && portable.endsWith('/')) {
    return { path: directory, directory: true }
  }
  if (portable.length === 0 || portable.startsWith('/') || portable.startsWith('\\')
    || isAbsolute(portable) || normalized === '..' || normalized.startsWith(`..${sep}`)) {
    throw new Error('Harness archive contains a path outside its installation directory')
  }
  const path = resolve(directory, normalized)
  const outside = relative(directory, path)
  if (outside === '' || outside === '..' || outside.startsWith(`..${sep}`) || isAbsolute(outside)) {
    throw new Error('Harness archive contains a path outside its installation directory')
  }
  return { path, directory: portable.endsWith('/') }
}

/**
 * Extract ZIPs without delegating unbounded decompression to an OS utility.
 * ZIP symlink metadata is intentionally ignored: every non-directory entry is
 * materialized as a fresh regular file, then only the declared command is made
 * executable.
 */
async function extractBoundedZip(archivePath: string, directory: string, signal?: AbortSignal): Promise<void> {
  let entryCount = 0
  let declaredBytes = 0
  let writtenBytes = 0
  const openFiles = new Set<number>()
  const targets = new Set<string>()
  const unzip = new Unzip((file) => {
    signal?.throwIfAborted()
    entryCount += 1
    if (entryCount > MAXIMUM_ARCHIVE_ENTRIES) throw new Error('Harness archive exceeds the safe entry-count limit')
    const target = safeArchiveTarget(directory, file.name)
    const collisionKey = process.platform === 'darwin' || process.platform === 'win32'
      ? target.path.toLocaleLowerCase('en-US')
      : target.path
    if (targets.has(collisionKey)) throw new Error('Harness archive contains a duplicate output path')
    targets.add(collisionKey)
    const declared = file.originalSize
    if (declared !== undefined) {
      declaredBytes += declared
      if (!Number.isSafeInteger(declaredBytes) || declaredBytes > MAXIMUM_UNPACKED_BYTES) {
        throw new Error('Harness archive exceeds the 2 GiB unpacked-size limit')
      }
    }
    if (target.directory) {
      mkdirSync(target.path, { recursive: true, mode: 0o700 })
      file.ondata = (error) => { if (error !== null) throw error }
      file.start()
      return
    }
    mkdirSync(dirname(target.path), { recursive: true, mode: 0o700 })
    const handle = openSync(target.path, 'wx', 0o600)
    openFiles.add(handle)
    let fileBytes = 0
    file.ondata = (error, chunk, final) => {
      if (error !== null) throw error
      signal?.throwIfAborted()
      fileBytes += chunk.byteLength
      writtenBytes += chunk.byteLength
      if (!Number.isSafeInteger(writtenBytes) || writtenBytes > MAXIMUM_UNPACKED_BYTES) {
        throw new Error('Harness archive exceeds the 2 GiB unpacked-size limit')
      }
      if (declared !== undefined && fileBytes > declared) {
        throw new Error('Harness ZIP entry exceeded its declared unpacked size')
      }
      if (chunk.byteLength > 0) writeSync(handle, chunk)
      if (final) {
        closeSync(handle)
        openFiles.delete(handle)
        if (declared !== undefined && fileBytes !== declared) {
          throw new Error('Harness ZIP entry did not match its declared unpacked size')
        }
      }
    }
    file.start()
  })
  unzip.register(UnzipInflate)
  try {
    for await (const chunk of createReadStream(archivePath) as AsyncIterable<Uint8Array>) {
      signal?.throwIfAborted()
      unzip.push(chunk, false)
    }
    unzip.push(new Uint8Array(), true)
  } finally {
    for (const handle of openFiles) closeSync(handle)
  }
}

function boundedTarOptions(directory: string, signal?: AbortSignal): TarOptionsWithAliasesAsyncNoFile {
  let entryCount = 0
  let unpackedBytes = 0
  const targets = new Set<string>()
  return {
    cwd: directory,
    strict: true,
    preservePaths: false,
    maxDecompressionRatio: 1_000,
    filter: (name, rawEntry) => {
      signal?.throwIfAborted()
      if (!('type' in rawEntry)) throw new Error('Harness archive entry metadata is unavailable')
      const entry = rawEntry
      entryCount += 1
      if (entryCount > MAXIMUM_ARCHIVE_ENTRIES) throw new Error('Harness archive exceeds the safe entry-count limit')
      const target = safeArchiveTarget(directory, name)
      const collisionKey = process.platform === 'darwin' || process.platform === 'win32'
        ? target.path.toLocaleLowerCase('en-US')
        : target.path
      if (targets.has(collisionKey)) throw new Error('Harness archive contains a duplicate output path')
      targets.add(collisionKey)
      if (entry.type !== 'File' && entry.type !== 'OldFile'
        && entry.type !== 'ContiguousFile' && entry.type !== 'Directory') {
        throw new Error(`Harness archive contains unsupported entry type "${entry.type}"`)
      }
      unpackedBytes += entry.size
      if (!Number.isSafeInteger(unpackedBytes) || unpackedBytes > MAXIMUM_UNPACKED_BYTES) {
        throw new Error('Harness archive exceeds the 2 GiB unpacked-size limit')
      }
      return true
    },
  }
}

async function extractBoundedTar(archivePath: string, directory: string, signal?: AbortSignal): Promise<void> {
  await extractTar({ file: archivePath, ...boundedTarOptions(directory, signal) })
}

async function extractBoundedBzip2Tar(archivePath: string, directory: string, signal?: AbortSignal): Promise<void> {
  let tarBytes = 0
  const boundedTarStream = new Transform({
    transform(chunk: Buffer, _encoding, callback) {
      signal?.throwIfAborted()
      tarBytes += chunk.byteLength
      if (!Number.isSafeInteger(tarBytes) || tarBytes > MAXIMUM_UNPACKED_BYTES) {
        callback(new Error('Harness bzip2 archive exceeds the 2 GiB decompressed TAR limit'))
        return
      }
      callback(null, chunk)
    },
  })
  const unpack = extractTar(boundedTarOptions(directory, signal))
  const streams = [createReadStream(archivePath), unbzip2Stream(), boundedTarStream, unpack] as const
  if (signal === undefined) await pipeline(...streams)
  else await pipeline(...streams, { signal })
}

async function installBinaryHarness(
  pack: HarnessPack,
  directory: string,
  signal?: AbortSignal,
): Promise<void> {
  const distribution = pack.distribution
  if (distribution?.kind !== 'binary') return
  if (distribution.sha256 === undefined) {
    throw new Error('Harness binary has no SHA-256 checksum; Open Fish will not install an unverifiable download')
  }
  const maximumArchiveBytes = 512 * 1024 * 1024
  const response = await fetch(distribution.archive, signal === undefined ? {} : { signal })
  if (!response.ok) throw new Error(`Harness binary download failed with HTTP ${response.status}`)
  const contentLength = Number(response.headers.get('content-length'))
  if (Number.isFinite(contentLength) && contentLength > maximumArchiveBytes) {
    throw new Error('Harness binary archive exceeds the 512 MiB installation limit')
  }
  const archiveName = new URL(distribution.archive).pathname.split('/').at(-1) || 'download'
  const archivePath = join(directory, `.openfish-download-${randomUUID()}-${basename(archiveName)}`)
  if (response.body === null) throw new Error('Harness binary download returned no body')
  const archive = await open(archivePath, 'wx', 0o600)
  const digest = createHash('sha256')
  let downloaded = 0
  try {
    const reader = response.body.getReader()
    while (true) {
      const chunk = await reader.read()
      if (chunk.done) break
      downloaded += chunk.value.byteLength
      if (downloaded > maximumArchiveBytes) {
        await reader.cancel('archive size limit exceeded')
        throw new Error('Harness binary archive exceeds the 512 MiB installation limit')
      }
      digest.update(chunk.value)
      await archive.write(chunk.value)
    }
  } catch (error: unknown) {
    await archive.close().catch(() => undefined)
    await rm(archivePath, { force: true }).catch(() => undefined)
    throw error
  }
  await archive.close()
  if (downloaded === 0) {
    await rm(archivePath, { force: true })
    throw new Error('Harness binary download was empty')
  }
  const actual = digest.digest('hex')
  if (actual.toLowerCase() !== distribution.sha256.toLowerCase()) {
    await rm(archivePath, { force: true })
    throw new Error('Harness binary checksum mismatch')
  }
  const lower = archiveName.toLowerCase()
  if (lower.endsWith('.zip')) {
    await extractBoundedZip(archivePath, directory, signal)
  } else if (/\.(?:tar|tar\.gz|tgz)$/u.test(lower)) {
    await extractBoundedTar(archivePath, directory, signal)
  } else if (/\.(?:tar\.bz2|tbz2)$/u.test(lower)) {
    await extractBoundedBzip2Tar(archivePath, directory, signal)
  } else {
    // A non-archive URL is already streamed into `archivePath`; promote that
    // exact verified byte stream instead of buffering a second copy. The
    // declared command may live in a nested Pack-owned directory.
    const command = managedBinaryCommand(directory, distribution.command)
    if (archivePath !== command) {
      await mkdir(dirname(command), { recursive: true, mode: 0o700 })
      await rename(archivePath, command)
    }
  }
  const command = managedBinaryCommand(directory, distribution.command)
  if (!existsSync(command)) throw new Error(`Harness archive did not contain declared command "${distribution.command}"`)
  await hardenManagedBinaryTree(directory)
  if (process.platform !== 'win32') await chmod(command, 0o700)
  if (archivePath !== command) await rm(archivePath, { force: true })
}

async function hardenManagedBinaryTree(directory: string): Promise<void> {
  for (const entry of await readdir(directory)) {
    const path = join(directory, entry)
    const stat = await lstat(path)
    if (stat.isSymbolicLink()) throw new Error('Harness archive contains a symbolic link')
    if (stat.isDirectory()) {
      await hardenManagedBinaryTree(path)
      if (process.platform !== 'win32') await chmod(path, 0o700)
      continue
    }
    if (!stat.isFile()) throw new Error('Harness archive contains an unsupported filesystem entry')
    if (process.platform !== 'win32') await chmod(path, (stat.mode & 0o111) === 0 ? 0o600 : 0o700)
  }
}

const ACP_CLIENT_FILE_LIMIT = 4 * 1024 * 1024
const ACP_CLIENT_TERMINAL_LIMIT = 4 * 1024 * 1024
const ACP_CLIENT_TERMINAL_DEFAULT_LIMIT = 1024 * 1024
const ACP_CLIENT_TERMINAL_COUNT_LIMIT = 16
const NOFOLLOW_FLAG = process.platform === 'win32' ? 0 : constants.O_NOFOLLOW

interface AcpClientTerminal {
  handle: SubprocessTerminalHandle
  output: string
  truncated: boolean
  readonly outputByteLimit: number
  outcome?: SubprocessOutcome
  failure?: Error
  done: Promise<SubprocessOutcome>
}

interface ElicitationField {
  readonly id: string
  readonly schema: SupportedElicitationPropertySchema
  readonly required: boolean
  readonly valuesByLabel: ReadonlyMap<string, string>
}

const OPTIONAL_ELICITATION_VALUE = '\u0000openfish.optional.skip'

type SupportedElicitationPropertySchema =
  | (StringPropertySchema & { type: 'string' })
  | (NumberPropertySchema & { type: 'number' })
  | (IntegerPropertySchema & { type: 'integer' })
  | (BooleanPropertySchema & { type: 'boolean' })
  | (Omit<MultiSelectPropertySchema, 'items'> & {
    type: 'array'
    items: (StringMultiSelectItems & { type: 'string' }) | TitledMultiSelectItems
  })

function isSupportedElicitationPropertySchema(
  schema: ElicitationPropertySchema,
): schema is SupportedElicitationPropertySchema {
  return AcpElicitationPropertySchema.isString(schema)
    || AcpElicitationPropertySchema.isNumber(schema)
    || AcpElicitationPropertySchema.isInteger(schema)
    || AcpElicitationPropertySchema.isBoolean(schema)
    || (AcpElicitationPropertySchema.isArray(schema)
      && (AcpMultiSelectItems.isString(schema.items) || AcpMultiSelectItems.isTitled(schema.items)))
}

function utf8Tail(value: string, byteLimit: number): { value: string; truncated: boolean } {
  const encoded = Buffer.from(value, 'utf8')
  if (encoded.byteLength <= byteLimit) return { value, truncated: false }
  if (byteLimit === 0) return { value: '', truncated: true }
  let start = encoded.byteLength - byteLimit
  while (start < encoded.byteLength && ((encoded[start] as number) & 0xc0) === 0x80) start++
  return { value: encoded.subarray(start).toString('utf8'), truncated: true }
}

function containsPath(root: string, candidate: string): boolean {
  const offset = relative(root, candidate)
  return offset === '' || (!isAbsolute(offset) && offset !== '..' && !offset.startsWith(`..${sep}`))
}

function boundedTerminalOutputLimit(value: number | null | undefined): number {
  if (value === undefined || value === null) return ACP_CLIENT_TERMINAL_DEFAULT_LIMIT
  if (!Number.isSafeInteger(value) || value < 0 || value > ACP_CLIENT_TERMINAL_LIMIT) {
    throw new Error(`ACP terminal outputByteLimit must be an integer between 0 and ${ACP_CLIENT_TERMINAL_LIMIT}`)
  }
  return value
}

function terminalEnvironment(entries: CreateTerminalRequest['env']): Record<string, string> {
  if (entries === undefined) return {}
  if (entries.length > 128) throw new Error('ACP terminal environment declares too many variables')
  const environment: Record<string, string> = {}
  let bytes = 0
  for (const entry of entries) {
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/u.test(entry.name) || entry.name.toUpperCase().startsWith('DSH_')) {
      throw new Error(`ACP terminal environment name "${entry.name}" is not allowed`)
    }
    if (entry.value.includes('\0')) throw new Error(`ACP terminal environment value for "${entry.name}" contains NUL`)
    bytes += Buffer.byteLength(entry.name) + Buffer.byteLength(entry.value)
    if (bytes > 1024 * 1024) throw new Error('ACP terminal environment is too large')
    environment[entry.name] = entry.value
  }
  return environment
}

function terminalArguments(request: CreateTerminalRequest): string[] {
  const args = request.args ?? []
  if (request.command.length === 0 || request.command.length > 4096 || request.command.includes('\0')) {
    throw new Error('ACP terminal command is empty or invalid')
  }
  if (args.length > 256) throw new Error('ACP terminal command declares too many arguments')
  let bytes = Buffer.byteLength(request.command)
  for (const arg of args) {
    if (arg.includes('\0')) throw new Error('ACP terminal argument contains NUL')
    bytes += Buffer.byteLength(arg)
    if (bytes > 256 * 1024) throw new Error('ACP terminal command is too large')
  }
  return args
}

async function promptBlocks(
  message: UserMessage,
  attachments: AttachmentStore,
  signal?: AbortSignal,
): Promise<AcpContentBlock[]> {
  const content: AcpContentBlock[] = []
  for (const block of message.content) {
    if (block.type === 'text') content.push({ type: 'text', text: block.text })
    if (block.type === 'image') {
      const stored = await attachments.readImage(block.attachment, signal)
      content.push({
        type: 'image',
        data: Buffer.from(stored.data).toString('base64'),
        mimeType: stored.ref.mediaType,
      })
    }
  }
  if (content.length === 0) throw new Error('This ACP Harness accepts text and image prompt content')
  return content
}

function elicitationChoices(schema: SupportedElicitationPropertySchema): Array<{ label: string; value: string }> {
  if (schema.type === 'boolean') return [{ label: 'Yes', value: 'true' }, { label: 'No', value: 'false' }]
  if (schema.type === 'string') {
    if (schema.oneOf !== undefined && schema.oneOf !== null) {
      return schema.oneOf.slice(0, 101).map(option => ({ label: option.title, value: option.const }))
    }
    return (schema.enum ?? []).slice(0, 101).map(value => ({ label: value, value }))
  }
  if (schema.type === 'array') {
    return AcpMultiSelectItems.isTitled(schema.items)
      ? schema.items.anyOf.slice(0, 101).map(option => ({ label: option.title, value: option.const }))
      : schema.items.enum.slice(0, 101).map(value => ({ label: value, value }))
  }
  return []
}

function uniqueChoiceLabels(choices: readonly { label: string; value: string }[]): Array<{ label: string; value: string }> {
  const counts = new Map<string, number>()
  for (const choice of choices) counts.set(choice.label, (counts.get(choice.label) ?? 0) + 1)
  return choices.map(choice => ({
    label: (counts.get(choice.label) ?? 0) > 1 ? `${choice.label} (${choice.value})` : choice.label,
    value: choice.value,
  }))
}

function elicitationFieldValue(
  field: ElicitationField,
  answer: AskUserQuestionAnswerItem | undefined,
): ElicitationContentValue | undefined {
  if (answer === undefined) return undefined
  const selected = answer.selected.map(label => field.valuesByLabel.get(label)).filter((value): value is string => value !== undefined)
  if (selected.includes(OPTIONAL_ELICITATION_VALUE)) return undefined
  switch (field.schema.type) {
    case 'array':
      if (selected.length < (field.schema.minItems ?? 0)) return undefined
      if (field.schema.maxItems !== undefined && field.schema.maxItems !== null && selected.length > field.schema.maxItems) return undefined
      return selected
    case 'boolean':
      return selected[0] === 'true' ? true : selected[0] === 'false' ? false : undefined
    case 'integer':
    case 'number': {
      const raw = answer.custom?.trim()
      if (raw === undefined || raw === '') return undefined
      const value = Number(raw)
      if (!Number.isFinite(value) || (field.schema.type === 'integer' && !Number.isInteger(value))) return undefined
      if (field.schema.minimum !== undefined && field.schema.minimum !== null && value < field.schema.minimum) return undefined
      if (field.schema.maximum !== undefined && field.schema.maximum !== null && value > field.schema.maximum) return undefined
      return value
    }
    case 'string': {
      const raw = selected[0] ?? answer.custom
      if (raw === undefined) return undefined
      if (Array.from(raw).length > 65_536) return undefined
      if (field.schema.minLength !== undefined && field.schema.minLength !== null && raw.length < field.schema.minLength) return undefined
      if (field.schema.maxLength !== undefined && field.schema.maxLength !== null && raw.length > field.schema.maxLength) return undefined
      if (field.schema.format === 'email' && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(raw)) return undefined
      if (field.schema.format === 'uri') {
        try {
          const url = new URL(raw)
          if (url.protocol === '') return undefined
        } catch { return undefined }
      }
      if (field.schema.format === 'date') {
        if (!/^\d{4}-\d{2}-\d{2}$/u.test(raw)) return undefined
        const [year, month, day] = raw.split('-').map(Number)
        if (year === undefined || month === undefined || day === undefined) return undefined
        const date = new Date(Date.UTC(year, month - 1, day))
        if (date.getUTCFullYear() !== year || date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day) return undefined
      }
      if (field.schema.format === 'date-time' && Number.isNaN(Date.parse(raw))) return undefined
      return raw
    }
  }
}

/** One external ACP session rendered through the ordinary DSH Agent/session lifecycle. */
export class AcpHarnessAgent implements Agent {
  readonly options: AgentOptions
  readonly inbox: Inbox
  readonly sandboxAuthority: SandboxAuthorityController
  private readonly scope: Scope
  readonly ctx: Context
  private phase: Phase
  private activity: Promise<void> = Promise.resolve()
  private process: SubprocessHandle | undefined
  private processFailure: Promise<never> | undefined
  private processStopped = false
  private connection: ClientSideConnection | undefined
  private remoteSessionId: string | undefined
  private sessionDeleteSupported = false
  private sessionCloseSupported = false
  private configOptions: SessionConfigOption[] = []
  private modeState: SessionModeState | undefined
  /**
   * ACP configuration writes have session-wide side effects: changing a
   * model can replace its thought-level directory and a custom option can
   * replace both. Serialize them at the Driver boundary so callers other
   * than the OpenFish RPC gateway cannot race two individually valid writes
   * against stale option snapshots.
   */
  private configurationMutationChain: Promise<void> = Promise.resolve()
  private activeAssembler: BlockAssembler | undefined
  private activeChunkSeqs: number[] = []
  private activeNextContentIndex = 2
  private pendingStartupUpdates: SessionNotification[] = []
  private maintenanceAbort: AbortController | undefined
  private readonly dispatch: AgentEventDispatch
  private processSandboxMode: SandboxMode
  private readonly clientTerminals = new Map<string, AcpClientTerminal>()
  private readonly workspaceDirectory: string

  constructor(
    private readonly hostCtx: Context,
    public readonly id: SessionId,
    public readonly session: Session,
    private readonly pack: HarnessPack,
    private readonly installationDirectory: string,
    private readonly runtimeDirectory: string,
    private readonly preferredAuthMethod?: string,
    private readonly workspaceMode?: HarnessSessionRequest['workspaceMode'],
    private readonly capabilities: HarnessCapability[] = [],
  ) {
    const workspaceDirectory = session.header.cwd
    if (workspaceDirectory === undefined || !isAbsolute(workspaceDirectory) || workspaceDirectory.includes('\0')) {
      throw new Error('ACP Harness sessions require an explicit absolute Project or OpenFish-managed No Project directory')
    }
    this.workspaceDirectory = workspaceDirectory
    this.options = { provider: 'harness', model: pack.id }
    this.processSandboxMode = hostCtx.sandboxPolicy.resolve({ session }).mode
    const currentSandboxMode = (): SandboxMode => this.processSandboxMode
    this.sandboxAuthority = {
      get mode() { return currentSandboxMode() },
      reconfigure: mode => this.reconfigureSandbox(mode),
    }
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
   * @param sandboxMode - Process sandbox policy applied before launching the Harness.
   * @param signal - Optional cancellation for startup and ACP initialization.
   */
  async start(
    resumeRemoteSessionId?: string,
    sandboxMode = this.processSandboxMode,
    signal?: AbortSignal,
  ): Promise<void> {
    const startup = harnessStartupSignal(signal)
    startup.throwIfAborted()
    const { argv, env } = await managedLaunchArgv(this.pack, this.installationDirectory)
    const authEnv = await this.resolveAuthenticationEnvironment()
    const launch = await prepareHarnessProcess(this.hostCtx, {
      argv,
      cwd: this.workspaceDirectory,
      installationDirectory: this.installationDirectory,
      runtimeDirectory: this.runtimeDirectory,
      purpose: 'session',
      session: this.session,
      sandboxMode,
      env: { ...env, ...authEnv },
    })
    const child = this.hostCtx.subprocess.spawn({
      argv: launch.argv,
      cwd: this.workspaceDirectory,
      stdio: { stdin: 'pipe', stdout: 'pipe', stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000,
      env: launch.env,
    })
    if (child.stdin === undefined || child.stdout === undefined) {
      child.terminate()
      throw new Error('ACP Harness subprocess did not expose protocol pipes')
    }
    this.process = child
    this.processStopped = false
    const processFailure = child.done.then<never>(
      (outcome) => {
        if (this.process === child) this.processStopped = true
        const detail = startupDiagnostic(child)
        const exit = outcome.exitCode === null ? `signal ${outcome.signal ?? 'unknown'}` : `exit ${String(outcome.exitCode)}`
        throw new Error(`ACP Harness "${this.pack.name}" process stopped unexpectedly (${exit})${detail === undefined ? '' : `: ${detail}`}`)
      },
      (error: unknown) => {
        if (this.process === child) this.processStopped = true
        throw new Error(`ACP Harness "${this.pack.name}" process failed: ${safeHarnessDiagnostic(error)}`, { cause: error })
      },
    )
    // A resident Harness can exit while the user is reading the transcript.
    // Observe that rejection here; a turn races it explicitly and the next
    // recovery resumes the exact pinned remote session.
    processFailure.catch(() => undefined)
    this.processFailure = processFailure
    const makeClient = (_agent: AcpConnection): Client => ({
      sessionUpdate: notification => this.sessionUpdate(notification),
      requestPermission: request => this.requestPermission(request),
      readTextFile: request => this.readTextFile(request),
      writeTextFile: request => this.writeTextFile(request),
      createTerminal: request => this.createTerminal(request),
      terminalOutput: request => this.terminalOutput(request),
      waitForTerminalExit: request => this.waitForTerminalExit(request),
      killTerminal: request => this.killTerminal(request),
      releaseTerminal: request => this.releaseTerminal(request),
      createElicitation: request => this.createElicitation(request),
    })
    const connection = new ClientSideConnection(
      makeClient,
      boundedAcpNdJsonStream(
        NodeWritable.toWeb(child.stdin) as WritableStream<Uint8Array>,
        NodeReadable.toWeb(child.stdout) as ReadableStream<Uint8Array>,
      ),
    )
    this.connection = connection
    try {
      const initialized = await abortableHarnessOperation(connection.initialize({
        protocolVersion: PROTOCOL_VERSION,
        clientCapabilities: {
          plan: {},
          auth: { terminal: true },
          elicitation: { form: {} },
          fs: { readTextFile: true, writeTextFile: true },
          terminal: true,
        },
        clientInfo: { name: 'open-fish', title: 'Open Fish', version: '0.1.0' },
      }), startup)
      this.sessionDeleteSupported = initialized.agentCapabilities?.sessionCapabilities?.delete !== undefined
      this.sessionCloseSupported = initialized.agentCapabilities?.sessionCapabilities?.close !== undefined
      const authMethods = initialized.authMethods ?? []
      const agentMethods = authMethods.filter(method => !('type' in method))
      const selectedPackMethod = this.pack.authMethods?.find(method => method.id === this.preferredAuthMethod)
      const agentAuth = this.preferredAuthMethod === undefined
        ? agentMethods[0]
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
        const metadata = selectedPackMethod?.agent === undefined
          ? undefined
          : await this.resolveAgentAuthenticationMetadata(selectedPackMethod)
        await abortableHarnessOperation(connection.authenticate({
          methodId: agentAuth.id,
          ...(metadata === undefined ? {} : { _meta: metadata }),
        }), startup)
      }
      else if (authMethods.length > 0 && selectedPackMethod === undefined) {
        throw new Error(`Harness "${this.pack.id}" requires an interactive or environment authentication method not yet configured in Open Fish`)
      }
      if (resumeRemoteSessionId !== undefined) {
        const request = { sessionId: resumeRemoteSessionId, cwd: this.workspaceDirectory, mcpServers: [] }
        // Prefer ACP's resume primitive: Open Fish already owns and renders
        // the durable transcript, so asking the Harness to stream its entire
        // history again is redundant. Codex advertises this capability and
        // its lightweight resume path is the reliable way to rejoin a thread.
        const loaded = initialized.agentCapabilities?.sessionCapabilities?.resume !== undefined
          ? await abortableHarnessOperation(connection.resumeSession(request), startup)
          : initialized.agentCapabilities?.loadSession
            ? await abortableHarnessOperation(connection.loadSession(request), startup)
            : undefined
        if (loaded === undefined) throw new Error(`Harness "${this.pack.id}" cannot resume sessions`)
        this.configOptions = admitAcpSessionConfigOptions(loaded.configOptions ?? [])
        this.modeState = loaded.modes ?? undefined
        this.remoteSessionId = resumeRemoteSessionId
      } else {
        const created = await abortableHarnessOperation(
          connection.newSession({ cwd: this.workspaceDirectory, mcpServers: [] }),
          startup,
        )
        this.configOptions = admitAcpSessionConfigOptions(created.configOptions ?? [])
        this.modeState = created.modes ?? undefined
        this.remoteSessionId = created.sessionId
      }
      this.processSandboxMode = sandboxMode
    } catch (error: unknown) {
      await this.disposeProcess()
      if (startup.aborted) throw harnessStartupError(`ACP Harness "${this.pack.name}"`, startup, error)
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

  private async resolveAgentAuthenticationMetadata(method: HarnessAuthMethod): Promise<Record<string, unknown>> {
    if (method.agent === undefined) return {}
    const credentials = this.hostCtx.get('credentials')
    const values: Record<string, string> = {}
    for (const field of method.fields) {
      const property = method.agent.fieldMap[field.ref]
      if (property === undefined) continue
      const hit = await credentials?.resolve(credentialRef(field.ref))
      if (field.required && hit === undefined) throw new Error(`Authentication needs ${field.name}`)
      if (hit !== undefined) values[property] = hit.value
    }
    return { [method.agent.metaKey]: values }
  }

  /** Remote id committed after startup and before publication. */
  commitSelection(): void {
    if (this.remoteSessionId === undefined) throw new Error('ACP Harness session is not ready')
    const existing = this.session.events.findLast(event => event.type === 'harness/selected')
    if (existing === undefined) {
      this.session.append('harness/selected', {
        harnessId: this.pack.id,
        version: this.pack.version,
        protocol: 'acp',
        ...(this.preferredAuthMethod === undefined ? {} : { authMethod: this.preferredAuthMethod }),
        ...(this.workspaceMode === undefined ? {} : { workspaceMode: this.workspaceMode }),
        capabilities: this.capabilities,
        remoteSessionId: this.remoteSessionId,
      })
    } else {
      if (existing.data.harnessId !== this.pack.id || existing.data.version !== this.pack.version
        || existing.data.protocol !== 'acp'
        || existing.data.authMethod !== this.preferredAuthMethod
        || existing.data.workspaceMode !== this.workspaceMode) {
        throw new Error('Cannot recover ACP session under a different pinned Harness identity')
      }
      const currentRemote = this.session.events.findLast(event => event.type === 'harness/remote-session')
        ?.data.remoteSessionId ?? existing.data.remoteSessionId
      if (currentRemote !== this.remoteSessionId) {
        this.session.append('harness/remote-session', {
          harnessId: this.pack.id,
          remoteSessionId: this.remoteSessionId,
          reason: 'blank-session-recovery',
        })
      }
    }
    this.observe('protocol.ready', 'completed', 'ACP connection initialized')
    this.observe('session.ready', 'waiting', 'Harness session ready')
    const buffered = this.pendingStartupUpdates
    this.pendingStartupUpdates = []
    for (const update of buffered) {
      void this.recordSessionUpdate(update).catch((error: unknown) => {
        this.dispatch.emit('agent/error', {
          turn: this.phase.turn,
          step: 1,
          error: new Error(safeHarnessDiagnostic(error)),
        })
      })
    }
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
    const options = acpHarnessConfigCatalog(this.configOptions)
    const mode = this.modeState
    if (mode === undefined || mode.availableModes.length === 0) return options
    return [...options, {
      id: this.modeControlId(),
      name: 'Operating mode',
      description: 'Harness-owned behavior mode advertised by the live ACP session.',
      category: 'mode',
      type: 'select',
      currentValue: mode.currentModeId,
      values: mode.availableModes.map(item => ({
        id: item.id,
        name: item.name,
        ...(item.description === undefined || item.description === null ? {} : { description: item.description }),
      })),
    }]
  }

  private modeControlId(): string {
    let id = 'openfish:acp:session-mode'
    while (this.configOptions.some(option => option.id === id)) id += ':'
    return id
  }

  /**
   * Apply Pack defaults against this Harness's live ACP capability directory.
   * @param signal - Optional cancellation between configuration mutations.
   */
  async applyPackConfiguration(signal?: AbortSignal): Promise<void> {
    for (const option of packSessionConfiguration(this.pack)) {
      await this.selectHarnessConfig(option.id, option.value, signal)
    }
  }

  /**
   * Set an ACP option and replace the local directory with its authoritative response.
   * @param configId - Live ACP configuration id.
   * @param value - Advertised select value or boolean state.
   * @param signal - Optional cancellation before and after the ACP mutation.
   * @returns Refreshed live configuration directory.
   */
  async selectHarnessConfig(
    configId: string,
    value: string | boolean,
    signal?: AbortSignal,
  ): Promise<AcpHarnessConfigOption[]> {
    return this.serializeConfigurationMutation(
      () => this.selectHarnessConfigUnserialized(configId, value, signal),
    )
  }

  private async selectHarnessConfigUnserialized(
    configId: string,
    value: string | boolean,
    signal?: AbortSignal,
  ): Promise<AcpHarnessConfigOption[]> {
    const connection = this.connection
    const remoteSessionId = this.remoteSessionId
    if (connection !== undefined && remoteSessionId !== undefined && configId === this.modeControlId()) {
      const mode = this.modeState
      if (mode === undefined || typeof value !== 'string'
        || !mode.availableModes.some(candidate => candidate.id === value)) {
        throw new Error(`Harness "${this.pack.id}" does not advertise operating mode "${String(value)}"`)
      }
      signal?.throwIfAborted()
      const operation = connection.setSessionMode({ sessionId: remoteSessionId, modeId: value })
      // ACP does not define cancellation for configuration mutation. Once the
      // request is on the wire, await its authoritative response even if the
      // UI closes so local and remote state cannot diverge.
      await operation
      this.modeState = { ...mode, currentModeId: value }
      signal?.throwIfAborted()
      return this.harnessConfigCatalog()
    }
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
    signal?.throwIfAborted()
    const operation = connection.setSessionConfigOption({
      sessionId: remoteSessionId,
      configId,
      ...(config.type === 'boolean' ? { type: 'boolean' as const, value: value as boolean } : { value: value as string }),
    })
    const response = await operation
    this.configOptions = admitAcpSessionConfigOptions(response.configOptions)
    signal?.throwIfAborted()
    return this.harnessConfigCatalog()
  }

  /**
   * Select an ACP-advertised model and optional standard thought level.
   * @param model - Model id advertised by the live Harness.
   * @param reasoningEffort - Optional thought-level id advertised after model selection.
   * @param signal - Optional cancellation before and after model selection.
   * @returns Authoritative selected model and optional reasoning effort.
   */
  async selectHarnessModel(
    model: string,
    reasoningEffort?: string,
    signal?: AbortSignal,
  ): Promise<{ model: string; reasoningEffort?: string }> {
    return this.serializeConfigurationMutation(
      () => this.selectHarnessModelUnserialized(model, reasoningEffort, signal),
    )
  }

  private serializeConfigurationMutation<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.configurationMutationChain.then(operation)
    this.configurationMutationChain = result.then(() => undefined, () => undefined)
    return result
  }

  private async selectHarnessModelUnserialized(
    model: string,
    reasoningEffort?: string,
    signal?: AbortSignal,
  ): Promise<{ model: string; reasoningEffort?: string }> {
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
    signal?.throwIfAborted()
    const modelOperation = connection.setSessionConfigOption({
      sessionId: remoteSessionId,
      configId: config.id,
      value: model,
    })
    const response = await modelOperation
    this.configOptions = admitAcpSessionConfigOptions(response.configOptions)
    if (reasoningEffort !== undefined) {
      const thought = this.configOptions.find(option => option.type === 'select' && option.category === 'thought_level')
      if (thought === undefined || thought.type !== 'select') {
        throw new Error(`Harness "${this.pack.id}" does not expose reasoning effort selection`)
      }
      const advertised = flattenedSelectOptions(thought)
      if (!advertised.some(candidate => candidate.value === reasoningEffort)) {
        throw new Error(`Harness "${this.pack.id}" does not advertise reasoning effort "${reasoningEffort}" for model "${model}"`)
      }
      signal?.throwIfAborted()
      const effortOperation = connection.setSessionConfigOption({
        sessionId: remoteSessionId,
        configId: thought.id,
        value: reasoningEffort,
      })
      const effortResponse = await effortOperation
      this.configOptions = admitAcpSessionConfigOptions(effortResponse.configOptions)
    }
    const selected = this.harnessModelCatalog()
    signal?.throwIfAborted()
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

  /** Replace the resident ACP process before the durable permission facts change. */
  private reconfigureSandbox(mode: SandboxMode): Promise<void> {
    if (mode === this.processSandboxMode) return Promise.resolve()
    return this.runMaintenance(async () => {
      const remoteSessionId = this.remoteSessionId
      if (remoteSessionId === undefined) throw new Error(`Harness "${this.pack.id}" has no resumable session identity`)
      const previous = this.processSandboxMode
      const stagedSelection = this.selectionSnapshot()
      await this.disposeProcess()
      try {
        await this.start(remoteSessionId, mode)
        await this.restoreSelection(stagedSelection)
      } catch (error: unknown) {
        try {
          await this.disposeProcess()
          await this.start(remoteSessionId, previous)
          await this.restoreSelection(stagedSelection)
        } catch (rollbackError: unknown) {
          throw new AggregateError(
            [error, rollbackError],
            `Harness "${this.pack.id}" could not change access mode and its previous process could not be restored`,
          )
        }
        throw error
      }
    })
  }

  /** Delete the provider-side identity for an explicitly abandoned blank draft when ACP advertises it. */
  deleteCurrentRemoteSession(): Promise<void> {
    return this.runMaintenance(async (signal) => {
      const connection = this.connection
      const remoteSessionId = this.remoteSessionId
      if (connection === undefined || remoteSessionId === undefined || !this.sessionDeleteSupported) return
      signal.throwIfAborted()
      await connection.deleteSession({ sessionId: remoteSessionId })
      signal.throwIfAborted()
      this.remoteSessionId = undefined
    })
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
      this.dispatch.emit('agent/error', {
        turn: running.turn,
        step: 1,
        error: new Error(safeHarnessDiagnostic(error)),
      })
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
    this.observe('turn.started', 'active', `Turn ${turn} started`)
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
      this.activeNextContentIndex = 2
      await this.reconnectStoppedProcess(running.abort.signal)
      const connection = this.connection
      const remoteSessionId = this.remoteSessionId
      if (connection === undefined || remoteSessionId === undefined) throw new Error('ACP Harness connection is not ready')
      const prompt = (await Promise.all(messages.map(message =>
        promptBlocks(message, this.hostCtx.attachments, running.abort.signal)))).flat()
      const promptOperation = connection.prompt({
        sessionId: remoteSessionId,
        prompt,
      })
      const result = this.processFailure === undefined
        ? await promptOperation
        : await Promise.race([promptOperation, this.processFailure])
      this.observe('model.completed', 'completed', `Turn ${turn} inference completed`)
      const assembler = this.activeAssembler
      const content = assembler.blocks()
      if (content.length > 0) {
        this.session.append('assistant/message', {
          turn,
          step: 1,
          message: createAssistantMessage({
            content,
            source: { provider: 'harness', model: this.harnessModelCatalog()?.current ?? this.pack.id },
          }),
        }, { surfaceOp: 'append', sourceEventSeqs: this.activeChunkSeqs })
      }
      if (result.stopReason === 'cancelled') reason = { kind: 'aborted', reason: { kind: 'user' } }
      else if (result.stopReason === 'max_tokens') reason = { kind: 'max-tokens' }
      else if (result.stopReason !== 'end_turn') {
        reason = { kind: 'error', error: { code: 'ACP_STOP', message: safeHarnessDiagnostic(result.stopReason) } }
      }
    } catch (error: unknown) {
      let failure = error
      if (harnessTransportClosed(error)) this.processStopped = true
      if (!running.abort.signal.aborted && this.processStopped) {
        try {
          await this.reconnectStoppedProcess(running.abort.signal)
          failure = new Error(`${safeHarnessDiagnostic(error)}. OpenFish restored the pinned Harness session; retry this turn because the interrupted prompt may have reached the provider.`)
        } catch (recoveryError: unknown) {
          failure = new Error(`${safeHarnessDiagnostic(error)}. Automatic Harness recovery failed: ${safeHarnessDiagnostic(recoveryError)}`, {
            cause: new AggregateError([error, recoveryError]),
          })
        }
      }
      if (running.abort.signal.aborted) reason = { kind: 'aborted', reason: running.abort.signal.reason as AgentCancelCause }
      else reason = { kind: 'error', error: { code: 'ACP_ERROR', message: safeHarnessDiagnostic(failure) } }
      this.observe('turn.failed', 'failed', `Turn ${turn} failed`)
      throw new Error(safeHarnessDiagnostic(failure))
    } finally {
      this.activeAssembler = undefined
      this.activeChunkSeqs = []
      this.activeNextContentIndex = 2
      if (stepStarted) this.session.append('step/end', { turn, step: 1 })
      this.session.append('turn/end', { turn, reason })
      if (reason.kind !== 'error') this.observe('turn.completed', 'waiting', `Turn ${turn} finished`)
    }
  }

  private sessionUpdate(params: SessionNotification): Promise<void> {
    if (this.session.events.findLast(event => event.type === 'harness/selected') === undefined) {
      this.pendingStartupUpdates.push(params)
      return Promise.resolve()
    }
    return this.recordSessionUpdate(params)
  }

  private async recordSessionUpdate(params: SessionNotification): Promise<void> {
    const update = params.update
    if (update.sessionUpdate === 'config_option_update') {
      this.configOptions = admitAcpSessionConfigOptions(update.configOptions)
    }
    if (update.sessionUpdate === 'current_mode_update' && this.modeState !== undefined) {
      this.modeState = { ...this.modeState, currentModeId: update.currentModeId }
    }
    const durableUpdate = durableAcpSessionUpdate(update)
    if (durableUpdate !== undefined) {
      this.session.append('harness/native-event', { harnessId: this.pack.id, event: durableUpdate })
    }
    if (update.sessionUpdate.includes('tool')) {
      this.observe('tool.activity', 'active', update.sessionUpdate)
    }
    const assembler = this.activeAssembler
    if ((update.sessionUpdate === 'agent_message_chunk' || update.sessionUpdate === 'agent_thought_chunk')
      && update.content.type === 'text' && assembler !== undefined) {
      this.observe('output.activity', 'active', 'Streaming Harness response')
      const reasoning = update.sessionUpdate === 'agent_thought_chunk'
      const event = this.session.append('assistant/chunk', {
        turn: this.phase.kind === 'running' ? this.phase.turn : 0,
        step: 1,
        chunk: { type: reasoning ? 'reasoning-delta' : 'text-delta', index: reasoning ? 1 : 0, text: update.content.text },
      })
      this.activeChunkSeqs.push(event.seq)
      assembler.push(event.data.chunk)
    }
    if (update.sessionUpdate === 'agent_message_chunk' && update.content.type === 'image' && assembler !== undefined) {
      const allowed = this.hostCtx.attachments.imageLimits.mediaTypes
      if (!allowed.includes(update.content.mimeType as ImageMediaType)) {
        throw new Error(`ACP Harness returned unsupported image type "${update.content.mimeType}"`)
      }
      const encodedLimit = Math.ceil(this.hostCtx.attachments.imageLimits.maxImageBytes / 3) * 4 + 4
      const canonicalBase64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u
      if (update.content.data.length > encodedLimit || !canonicalBase64.test(update.content.data)) {
        throw new Error('ACP Harness returned an invalid or oversized base64 image')
      }
      const data = Buffer.from(update.content.data, 'base64')
      if (data.toString('base64') !== update.content.data) throw new Error('ACP Harness returned non-canonical base64 image data')
      const attachment = await this.hostCtx.attachments.saveImage({
        data,
        mediaType: update.content.mimeType as ImageMediaType,
      })
      const event = this.session.append('assistant/chunk', {
        turn: this.phase.kind === 'running' ? this.phase.turn : 0,
        step: 1,
        chunk: { type: 'block-end' as const, index: this.activeNextContentIndex++, block: { type: 'image' as const, attachment } },
      })
      this.activeChunkSeqs.push(event.seq)
      assembler.push(event.data.chunk)
    }
    if (update.sessionUpdate === 'agent_message_chunk' && assembler !== undefined
      && update.content.type === 'resource_link') {
      const text = `[${update.content.title ?? update.content.name}](${update.content.uri})`
      const event = this.session.append('assistant/chunk', {
        turn: this.phase.kind === 'running' ? this.phase.turn : 0,
        step: 1,
        chunk: { type: 'text-delta' as const, index: 0, text },
      })
      this.activeChunkSeqs.push(event.seq)
      assembler.push(event.data.chunk)
    }
    if (update.sessionUpdate === 'agent_message_chunk' && assembler !== undefined
      && update.content.type === 'resource' && 'text' in update.content.resource) {
      const text = update.content.resource.text
      const event = this.session.append('assistant/chunk', {
        turn: this.phase.kind === 'running' ? this.phase.turn : 0,
        step: 1,
        chunk: { type: 'text-delta' as const, index: 0, text },
      })
      this.activeChunkSeqs.push(event.seq)
      assembler.push(event.data.chunk)
    }
  }

  private assertClientSession(sessionId: string): void {
    if (this.remoteSessionId !== undefined && sessionId !== this.remoteSessionId) {
      throw new Error('ACP client request belongs to a different session')
    }
  }

  private async workspaceRootPath(): Promise<string> {
    return realpath(this.workspaceDirectory)
  }

  private async workspaceExistingPath(path: string): Promise<string> {
    if (!isAbsolute(path) || path.includes('\0')) throw new Error('ACP client paths must be absolute and contain no NUL')
    const [root, candidate] = await Promise.all([this.workspaceRootPath(), realpath(path)])
    if (!containsPath(root, candidate)) throw new Error('ACP client path is outside the task workspace')
    return candidate
  }

  private async workspaceWritePath(path: string): Promise<string> {
    if (!isAbsolute(path) || path.includes('\0')) throw new Error('ACP client paths must be absolute and contain no NUL')
    if (this.processSandboxMode === 'read-only') throw new Error('ACP file writes are disabled by this task access mode')
    const [root, parent] = await Promise.all([this.workspaceRootPath(), realpath(dirname(path))])
    if (!containsPath(root, parent)) throw new Error('ACP client path is outside the task workspace')
    const candidate = join(parent, basename(path))
    try {
      const stat = await lstat(candidate)
      if (stat.isSymbolicLink() || !stat.isFile()) throw new Error('ACP file writes require a regular non-symlink target')
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
    return candidate
  }

  private async readTextFile(request: ReadTextFileRequest): Promise<{ content: string }> {
    this.assertClientSession(request.sessionId)
    if (request.line !== undefined && request.line !== null
      && (!Number.isSafeInteger(request.line) || request.line < 1)) throw new Error('ACP read line must be a positive integer')
    if (request.limit !== undefined && request.limit !== null
      && (!Number.isSafeInteger(request.limit) || request.limit < 0 || request.limit > 100_000)) {
      throw new Error('ACP read limit must be an integer between 0 and 100000')
    }
    const path = await this.workspaceExistingPath(request.path)
    const handle = await open(path, constants.O_RDONLY | NOFOLLOW_FLAG)
    try {
      const stat = await handle.stat()
      if (!stat.isFile()) throw new Error('ACP reads require a regular file')
      if (stat.size > ACP_CLIENT_FILE_LIMIT) throw new Error(`ACP text reads are limited to ${ACP_CLIENT_FILE_LIMIT} bytes`)
      const content = await handle.readFile('utf8')
      if ((request.line === undefined || request.line === null) && (request.limit === undefined || request.limit === null)) {
        return { content }
      }
      const start = (request.line ?? 1) - 1
      const lines = content.split('\n')
      const end = request.limit === undefined || request.limit === null ? undefined : start + request.limit
      return { content: lines.slice(start, end).join('\n') }
    } finally {
      await handle.close()
    }
  }

  private async writeTextFile(request: WriteTextFileRequest): Promise<Record<string, never>> {
    this.assertClientSession(request.sessionId)
    if (Buffer.byteLength(request.content, 'utf8') > ACP_CLIENT_FILE_LIMIT) {
      throw new Error(`ACP text writes are limited to ${ACP_CLIENT_FILE_LIMIT} bytes`)
    }
    const path = await this.workspaceWritePath(request.path)
    const handle = await open(
      path,
      constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | NOFOLLOW_FLAG,
      0o600,
    )
    try {
      const stat = await handle.stat()
      if (!stat.isFile()) throw new Error('ACP writes require a regular file')
      await handle.writeFile(request.content, 'utf8')
    } finally {
      await handle.close()
    }
    return {}
  }

  private terminal(request: { sessionId: string; terminalId: string }): AcpClientTerminal {
    this.assertClientSession(request.sessionId)
    const terminal = this.clientTerminals.get(request.terminalId)
    if (terminal === undefined) throw new Error(`Unknown ACP terminal "${request.terminalId}"`)
    if (terminal.failure !== undefined) throw terminal.failure
    return terminal
  }

  private async createTerminal(request: CreateTerminalRequest): Promise<{ terminalId: string }> {
    this.assertClientSession(request.sessionId)
    if (this.clientTerminals.size >= ACP_CLIENT_TERMINAL_COUNT_LIMIT) {
      throw new Error(`ACP terminal limit of ${ACP_CLIENT_TERMINAL_COUNT_LIMIT} reached`)
    }
    const args = terminalArguments(request)
    const environment = terminalEnvironment(request.env)
    const workspaceRoot = await this.workspaceRootPath()
    const cwd = await this.workspaceExistingPath(request.cwd ?? workspaceRoot)
    if (!(await lstat(cwd)).isDirectory()) throw new Error('ACP terminal cwd must be a directory')
    const executable = await this.hostCtx.subprocess.resolveExecutable(request.command, environment)
    const prepared = await prepareHarnessProcess(this.hostCtx, {
      argv: [executable, ...args],
      cwd,
      workspaceRoot,
      installationDirectory: this.installationDirectory,
      runtimeDirectory: this.runtimeDirectory,
      purpose: 'session',
      session: this.session,
      sandboxMode: this.processSandboxMode,
      env: environment,
    })
    const childEnvironment = Object.fromEntries(Object.entries(prepared.env)
      .filter((entry): entry is [string, string] => entry[1] !== undefined))
    const handle = await this.hostCtx.subprocess.spawnTerminal({
      argv: prepared.argv,
      cwd,
      env: childEnvironment,
      rows: 24,
      cols: 80,
      graceMs: 3_000,
    })
    const outputByteLimit = boundedTerminalOutputLimit(request.outputByteLimit)
    const terminal: AcpClientTerminal = {
      handle, output: '', truncated: false, outputByteLimit, done: handle.done,
    }
    terminal.done = handle.done.then((outcome) => {
      terminal.outcome = outcome
      return outcome
    }, (error: unknown) => {
      const failure = error instanceof Error ? error : new Error('ACP terminal failed', { cause: error })
      terminal.failure = failure
      throw failure
    })
    const decoder = new StringDecoder('utf8')
    const append = (value: string) => {
      const tail = utf8Tail(terminal.output + value, terminal.outputByteLimit)
      terminal.output = tail.value
      terminal.truncated ||= tail.truncated
    }
    handle.output.on('data', (chunk: Buffer | string) =>{  append(decoder.write(typeof chunk === 'string' ? Buffer.from(chunk) : chunk)) })
    handle.output.once('end', () =>{  append(decoder.end()) })
    handle.output.once('error', (error: unknown) => {
      terminal.failure ??= error instanceof Error ? error : new Error('ACP terminal output failed', { cause: error })
    })
    void terminal.done.catch(() => undefined)
    const terminalId = randomUUID()
    this.clientTerminals.set(terminalId, terminal)
    return { terminalId }
  }

  private terminalOutput(request: TerminalOutputRequest): Promise<{
    output: string
    truncated: boolean
    exitStatus?: { exitCode?: number | null; signal?: string | null }
  }> {
    const terminal = this.terminal(request)
    return Promise.resolve({
      output: terminal.output,
      truncated: terminal.truncated,
      ...(terminal.outcome === undefined ? {} : { exitStatus: {
        exitCode: terminal.outcome.exitCode,
        signal: terminal.outcome.signal,
      } }),
    })
  }

  private async waitForTerminalExit(request: WaitForTerminalExitRequest): Promise<{
    exitCode?: number | null
    signal?: string | null
  }> {
    const outcome = await this.terminal(request).done
    return { exitCode: outcome.exitCode, signal: outcome.signal }
  }

  private async killTerminal(request: KillTerminalRequest): Promise<Record<string, never>> {
    const terminal = this.terminal(request)
    await terminal.handle.terminate()
    await terminal.done.catch(() => undefined)
    return {}
  }

  private async releaseTerminal(request: ReleaseTerminalRequest): Promise<Record<string, never>> {
    const terminal = this.terminal(request)
    this.clientTerminals.delete(request.terminalId)
    await terminal.handle.terminate()
    await terminal.done.catch(() => undefined)
    return {}
  }

  private async createElicitation(request: CreateElicitationRequest): Promise<CreateElicitationResponse> {
    if (!AcpCreateElicitationRequest.isForm(request)) return { action: 'decline' }
    if ('sessionId' in request) this.assertClientSession(request.sessionId)
    const properties = Object.entries(request.requestedSchema.properties ?? {})
    if (properties.length === 0 || properties.length > 32 || request.message.length > 10_000
      || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(request.message)
      || (request.requestedSchema.title?.length ?? 0) > 128) return { action: 'decline' }
    const requiredRows = request.requestedSchema.required ?? []
    if (requiredRows.length > 32) return { action: 'decline' }
    const required = new Set(requiredRows)
    if ([...required].some(id => !properties.some(([candidate]) => candidate === id))) return { action: 'decline' }
    const fields: ElicitationField[] = []
    const questions: AskUserQuestionItem[] = []
    for (const [id, schema] of properties) {
      if (id.length === 0 || id.length > 256 || /[\u0000-\u001f\u007f]/u.test(id)) return { action: 'decline' }
      if (!isSupportedElicitationPropertySchema(schema)) return { action: 'decline' }
      // ACP permits arbitrary JSON-Schema regular expressions. Driver API v1
      // does not execute untrusted regexes inside the Host process.
      if (schema.type === 'string' && schema.pattern !== undefined && schema.pattern !== null) return { action: 'decline' }
      const isRequired = required.has(id)
      const choices = uniqueChoiceLabels([
        ...elicitationChoices(schema),
        ...(isRequired ? [] : [{ label: 'Skip this optional field', value: OPTIONAL_ELICITATION_VALUE }]),
      ])
      if (choices.length > 100 || choices.some(choice => choice.label.length === 0 || choice.label.length > 512
        || choice.value.length === 0 || choice.value.length > 4_096
        || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(choice.label + choice.value))) {
        return { action: 'decline' }
      }
      if ((schema.title?.length ?? 0) > 512 || (schema.description?.length ?? 0) > 10_000) return { action: 'decline' }
      if ((schema.type === 'string' && ((schema.maxLength ?? 0) > 65_536 || (schema.minLength ?? 0) > 65_536))
        || (schema.type === 'array' && ((schema.maxItems ?? 0) > 100 || (schema.minItems ?? 0) > 100))) {
        return { action: 'decline' }
      }
      const valuesByLabel = new Map(choices.map(choice => [choice.label, choice.value]))
      fields.push({ id, schema, required: isRequired, valuesByLabel })
      const detail = [request.message, schema.description ?? undefined, isRequired ? undefined : 'Optional']
        .filter((value): value is string => value !== undefined && value !== '').join('\n\n')
      questions.push({
        id,
        question: schema.title ?? id,
        ...(request.requestedSchema.title === undefined || request.requestedSchema.title === null
          ? {} : { header: request.requestedSchema.title }),
        ...(detail === '' ? {} : { detail }),
        ...(choices.length === 0 ? {} : { options: choices.map(choice => ({ label: choice.label })) }),
        ...(schema.type === 'array' ? { multiSelect: true } : {}),
      })
    }
    const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
    let answer: AskUserQuestionAnswer
    try {
      answer = await this.hostCtx.userQuestions.ask({ questions, agent: this, ...(signal === undefined ? {} : { signal }) })
    } catch {
      return { action: 'cancel' }
    }
    const answers = new Map(answer.answers.map(item => [item.id, item]))
    const content: Record<string, ElicitationContentValue> = {}
    for (const field of fields) {
      const value = elicitationFieldValue(field, answers.get(field.id))
      if (value === undefined) {
        if (field.required) return { action: 'decline' }
      } else {
        content[field.id] = value
      }
    }
    return { action: 'accept', content }
  }

  private async requestPermission(request: RequestPermissionRequest): Promise<RequestPermissionResponse> {
    const allow = request.options.find(option => option.kind === 'allow_once' || option.kind === 'allow_always')
    const reject = request.options.find(option => option.kind === 'reject_once' || option.kind === 'reject_always')
    const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
    this.observe('approval.requested', 'active', request.toolCall.title ?? 'Permission requested')
    const outcome = await this.hostCtx.approval.request({
      agent: this,
      toolName: request.toolCall.title ?? 'External Harness action',
      reason: `Requested by ${this.pack.name}`,
      ...(signal === undefined ? {} : { signal }),
    })
    const selected = outcome === 'allowed-once' ? allow : reject
    this.observe('approval.resolved', 'completed', outcome)
    return selected === undefined
      ? { outcome: { outcome: 'cancelled' } }
      : { outcome: { outcome: 'selected', optionId: selected.optionId } }
  }

  private observe(signal: HarnessRuntimeSignal, status: 'active' | 'waiting' | 'completed' | 'failed', activity: string): void {
    observeHarnessRuntime(this.session, this.pack, signal, status, activity)
  }

  private async reconnectStoppedProcess(signal: AbortSignal): Promise<void> {
    if (!this.processStopped) return
    const remoteSessionId = this.remoteSessionId
    if (remoteSessionId === undefined) throw new Error(`Harness "${this.pack.id}" stopped before it created a resumable session`)
    const stagedSelection = this.selectionSnapshot()
    await this.disposeProcess()
    await this.start(remoteSessionId, this.processSandboxMode, signal)
    await this.restoreSelection(stagedSelection, signal)
  }

  /** Capture every live user-visible ACP selection before replacing a process. */
  private selectionSnapshot(): AcpSessionSelectionSnapshot {
    return {
      ...(this.modeState === undefined ? {} : { mode: this.modeState.currentModeId }),
      options: this.configOptions.map(option => ({
        id: option.id,
        value: option.currentValue,
        ...(option.category === undefined || option.category === null ? {} : { category: option.category }),
      })),
    }
  }

  /** Restore the exact advertised ACP configuration without Harness-specific knowledge. */
  private async restoreSelection(snapshot: AcpSessionSelectionSnapshot, signal?: AbortSignal): Promise<void> {
    if (snapshot.mode !== undefined) {
      const mode = this.modeState
      if (mode === undefined || !mode.availableModes.some(candidate => candidate.id === snapshot.mode)) {
        throw new Error(`Harness "${this.pack.id}" no longer advertises operating mode "${snapshot.mode}"`)
      }
      if (mode.currentModeId !== snapshot.mode) {
        await this.selectHarnessConfigUnserialized(this.modeControlId(), snapshot.mode, signal)
      }
    }
    const ordered = [...snapshot.options].sort((left, right) => {
      const priority = (category?: string) => category === 'model' ? 0 : category === 'thought_level' ? 1 : 2
      return priority(left.category) - priority(right.category)
    })
    for (const selected of ordered) {
      const live = this.configOptions.find(option => option.id === selected.id)
      if (live === undefined) {
        throw new Error(`Harness "${this.pack.id}" no longer advertises configuration option "${selected.id}"`)
      }
      if (live.currentValue === selected.value) continue
      await this.selectHarnessConfigUnserialized(selected.id, selected.value, signal)
    }
  }

  /** Stop the remote session and release its process and scoped registrations. */
  async dispose(): Promise<void> {
    this.cancel({ kind: 'disposed' })
    await this.whenIdle()
    const connection = this.connection
    const remoteSessionId = this.remoteSessionId
    try {
      if (connection !== undefined && remoteSessionId !== undefined && this.sessionCloseSupported) {
        await connection.closeSession({ sessionId: remoteSessionId })
      }
    } finally {
      await this.scope.dispose()
      await this.disposeProcess()
    }
  }

  private async disposeProcess(): Promise<void> {
    const terminals = [...this.clientTerminals.values()]
    this.clientTerminals.clear()
    const terminalFailures: unknown[] = []
    await Promise.all(terminals.map(async (terminal) => {
      try {
        await terminal.handle.terminate()
        await terminal.done.catch(() => undefined)
      } catch (error: unknown) {
        terminalFailures.push(error)
      }
    }))
    const child = this.process
    this.process = undefined
    this.processFailure = undefined
    this.processStopped = false
    this.connection = undefined
    this.sessionDeleteSupported = false
    this.sessionCloseSupported = false
    if (child !== undefined) {
      child.stdin?.end()
      const timeout = AbortSignal.timeout(1_000)
      if (!await child.waitForExit(timeout)) child.terminate()
      await child.waitForExit()
    }
    if (terminalFailures.length > 0) throw new AggregateError(terminalFailures, 'ACP client terminals failed to terminate')
  }
}

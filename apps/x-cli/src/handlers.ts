/** OpenCodex CLI handlers over the DSH runtime and Host API. */

import { spawn, spawnSync } from 'node:child_process'
import { createConnection } from 'node:net'
import {
  existsSync,
  mkdirSync,
  readFileSync,
  realpathSync,
  readdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { homedir, hostname } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  clearConnection,
  listMarketplaces,
  marketplaceCacheRoot,
  readStdin,
  removeMarketplace,
  saveConnection,
  saveMarketplace,
  type Marketplace,
} from './xstore.ts'
import {
  applyConfigOverride,
  loadFeatureRegistry,
  loadLayeredConfig,
  validateFeatureRequests,
  validateStrictConfig,
  type XConfig,
} from './config.ts'
import { addServer, getServer, listServers, removeServer } from './mcp.ts'
import {
  fullHistory,
  hostRequest,
  imagePart,
  latestAssistantText,
  normalizeApiBase,
  projectedTitle,
  resolveSession,
  rpc,
  waitForTurn,
  type SessionSummaryView,
} from './host-client.ts'

export interface Invocation {
  path: string
  args: string[]
}

const PRODUCT = 'opencodex'
const LEGACY_PROFILE = 'x'
const VERSION = '0.1.0-x.0'

function productHome(): string {
  return process.env.OPENCODEX_HOME ?? process.env.X_HOME ?? join(homedir(), '.opencodex')
}

function dshHome(): string {
  return process.env.DSH_HOME ?? join(homedir(), '.dsh')
}

function profileDir(): string {
  return join(dshHome(), 'profiles', LEGACY_PROFILE)
}

function pidFile(): string {
  return join(productHome(), 'app-server.pid')
}

/** Locate the DSH launcher. It remains the only runtime entry point. */
export function dshBin(): string {
  const override = process.env.OPENCODEX_DSH_BIN ?? process.env.X_DSH_BIN
  if (override) return override
  const repoCandidate = fileURLToPath(new URL('../../cli/src/bin.ts', import.meta.url))
  if (existsSync(repoCandidate)) return repoCandidate
  const probe = spawnSync('which', ['dsh'], { encoding: 'utf8' })
  const dshPath = (probe.stdout as string | null)?.trim()
  if (probe.status === 0 && dshPath) return dshPath
  throw new Error('opencodex: cannot locate dsh; set OPENCODEX_DSH_BIN or install dsh')
}

function dshArgv(args: string[]): { command: string; args: string[] } {
  const resolved = dshBin()
  return resolved.endsWith('.ts')
    ? { command: process.execPath, args: ['--import', 'tsx/esm', resolved, ...args] }
    : resolved.endsWith('.js')
      ? { command: process.execPath, args: [resolved, ...args] }
      : { command: resolved, args }
}

function spawnDsh(args: string[], extra?: { cwd?: string; env?: NodeJS.ProcessEnv }): number {
  const command = dshArgv(args)
  const result = spawnSync(command.command, command.args, {
    stdio: 'inherit',
    cwd: extra?.cwd,
    env: extra?.env,
  })
  if (result.error) {
    process.stderr.write(`opencodex: failed to run dsh: ${String(result.error)}\n`)
    return 1
  }
  return result.status ?? 0
}

/** API origin used by all Host-backed commands. */
export function apiBase(): string {
  return normalizeApiBase()
}

function listOption(value: unknown): string[] {
  if (typeof value === 'string') return [value]
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

function stringOption(opts: Record<string, unknown>, key: string): string | undefined {
  const value = opts[key]
  return typeof value === 'string' && value !== '' ? value : undefined
}

function emitJson(value: unknown): void {
  process.stdout.write(`${JSON.stringify(value, null, 2)}\n`)
}

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

function daemonPid(): number | undefined {
  try {
    const value = Number.parseInt(readFileSync(pidFile(), 'utf8').trim(), 10)
    if (!Number.isSafeInteger(value) || value <= 0) return undefined
    process.kill(value, 0)
    return value
  } catch {
    return undefined
  }
}

function serverArgs(remote: boolean, listen?: string): string[] {
  let host: string | undefined = remote ? undefined : '127.0.0.1'
  let port = '3080'
  if (listen !== undefined) {
    const url = new URL(listen.includes('://') ? listen : `http://${listen}`)
    if (!['http:', 'ws:'].includes(url.protocol)) {
      throw new Error(`listen transport ${JSON.stringify(url.protocol)} is not mounted; use http:// or ws://`)
    }
    host = url.hostname
    if (host === '') throw new Error('listen endpoint requires a host')
    if (host !== '127.0.0.1' && host !== '0.0.0.0') {
      throw new Error('OpenCodex Host listen address must be 127.0.0.1 or 0.0.0.0')
    }
    if (host === '0.0.0.0') host = undefined
    if (url.port !== '') port = url.port
  }
  const args = ['--profile', LEGACY_PROFILE, '--port', port, '--no-open']
  if (host !== undefined) args.push('--host', host)
  return args
}

function startDaemon(remote = false, listen?: string): number | undefined {
  const existing = daemonPid()
  if (existing !== undefined) return existing
  mkdirSync(dirname(pidFile()), { recursive: true, mode: 0o700 })
  const command = dshArgv(serverArgs(remote, listen))
  const child = spawn(command.command, command.args, {
    stdio: 'ignore',
    detached: true,
    cwd: process.cwd(),
  })
  child.unref()
  if (child.pid !== undefined) writeFileSync(pidFile(), `${child.pid}\n`, { mode: 0o600 })
  return child.pid
}

function stopDaemon(): void {
  const pid = daemonPid()
  if (pid !== undefined) {
    try { process.kill(pid, 'SIGTERM') } catch { /* already gone */ }
  }
  try { unlinkSync(pidFile()) } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }
}

async function health(): Promise<boolean> {
  try {
    const response = await hostRequest('/x-native/v2/health', { signal: AbortSignal.timeout(1_500) })
    return response.ok
  } catch {
    return false
  }
}

async function ensureHost(): Promise<void> {
  if (await health()) return
  const base = new URL(apiBase())
  if (base.hostname !== '127.0.0.1' && base.hostname !== 'localhost' && base.hostname !== '::1') {
    throw new Error(`OpenCodex Host at ${apiBase()} is unreachable`)
  }
  startDaemon(false, base.origin)
  const deadline = Date.now() + 15_000
  while (Date.now() < deadline) {
    if (await health()) return
    await new Promise(resolveWait => setTimeout(resolveWait, 200))
  }
  throw new Error(`OpenCodex Host did not become ready at ${apiBase()}`)
}

interface LiveNativeCapabilities {
  product: string
  protocolVersion: string
  host: string
  surface: string
  features: {
    apiProxy: boolean
    typert: boolean
    remotePlugin: boolean
    voicePlugin: boolean
    localVoice: boolean
    imageGenerationExtension: boolean
  }
  contracts: {
    sessions: boolean
    workspaces: boolean
    interactions: boolean
    settings: boolean
    providers: boolean
    migration: boolean
    sandbox: boolean
  }
  voice?: { contract: string; transcriptAuthority: string; providers: Array<{ id: string; locality: string }> }
  transports: { lan: boolean; tailscale: boolean; relay: boolean }
  surfaces: string[]
}

interface LiveCapabilityRow {
  name: string
  owner: string
  state: 'composed' | 'extension-point'
  detail: string
}

async function readLiveCapabilities(): Promise<LiveNativeCapabilities> {
  const response = await hostRequest('/x-native/v2/capabilities')
  if (!response.ok) throw new Error(`capability discovery failed with HTTP ${response.status}`)
  const value = await response.json() as LiveNativeCapabilities
  if (value.product !== PRODUCT || value.host !== 'dsh' || value.protocolVersion !== 'v2') {
    throw new Error('the connected Host is not an OpenCodex-on-DSH v2 composition')
  }
  return value
}

function compositionCapabilityRows(value: LiveNativeCapabilities): LiveCapabilityRow[] {
  const row = (name: string, state: boolean, owner: string, detail: string): LiveCapabilityRow => ({
    name,
    owner,
    state: state ? 'composed' : 'extension-point',
    detail,
  })
  return [
    row('runtime', value.features.apiProxy && value.features.typert, 'DSH Host', 'Typert business API and event carriers'),
    row('sessions', value.contracts.sessions, 'dsh-session', 'turns, history, streaming, cancellation, and recovery'),
    row('workspaces', value.contracts.workspaces, 'dsh-workspace', 'projects, task ordering, and archives'),
    row('interactions', value.contracts.interactions, 'dsh-interaction', 'approvals and user questions'),
    row('models', value.contracts.providers, 'dsh-llm', 'DeepSeek default and replaceable provider routes'),
    row('settings', value.contracts.settings, 'dsh-settings', 'settings and write-only credentials'),
    row('migration', value.contracts.migration, 'dsh-session', 'Codex/DSH import and DSH export'),
    row('sandbox', value.contracts.sandbox, 'dsh-shell', 'one-shot commands through the composed sandbox Provider'),
    row('voice.local', value.features.localVoice && value.voice?.contract === 'dsh.voice.v1', 'dsh-voice', 'device-local STT/TTS; finalized text enters session.prompt'),
    row('remote.lan', value.transports.lan, 'dsh-connection', 'authenticated direct Host transport'),
    row('remote.tailscale', value.transports.tailscale, 'dsh-connection', 'authenticated direct Host transport'),
    row('remote.relay', value.transports.relay, 'dsh-remote-plugin', 'replaceable relay transport'),
    row('image-generation', value.features.imageGenerationExtension, 'dsh image Provider seam', 'provider registry only; no bundled model'),
    ...['macos', 'iphone', 'cli', 'web'].map(surface => row(
      `surface.${surface}`,
      value.surfaces.includes(surface),
      surface === 'web' ? 'DSH Web' : 'OpenCodex native adapter',
      'client of the same DSH services and session log',
    )),
  ]
}

function titleOf(session: SessionSummaryView): string {
  return projectedTitle(session) ?? (session.cwd === undefined ? session.sessionId : basename(session.cwd))
}

function promptParts(text: string, opts: Record<string, unknown>): Array<Record<string, unknown>> {
  const content: Array<Record<string, unknown>> = [{ type: 'text', text }]
  for (const path of listOption(opts.image)) content.push(imagePart(resolve(path)))
  return content
}

interface CliModelCatalog {
  current: { provider: string; model: string }
  groups: Array<{ id: string; name: string; models: Array<{ id: string }> }>
}

function configuredLocalGroups(catalog: CliModelCatalog, requested?: string): CliModelCatalog['groups'] {
  const normalized = requested?.toLowerCase().replaceAll(/[^a-z0-9]/g, '')
  return catalog.groups.filter((group) => {
    const id = group.id.toLowerCase().replaceAll(/[^a-z0-9]/g, '')
    const name = group.name.toLowerCase().replaceAll(/[^a-z0-9]/g, '')
    if (normalized !== undefined) return id === normalized || name === normalized
      || id.includes(normalized) || name.includes(normalized)
    return id.includes('ollama') || name.includes('ollama')
      || id.includes('lmstudio') || name.includes('lmstudio')
  })
}

async function selectModel(
  sessionId: string,
  requested: string | undefined,
  localProvider: string | undefined,
  reasoningEffort: string | undefined,
): Promise<void> {
  if (requested === undefined && localProvider === undefined) return
  const catalog = await rpc<CliModelCatalog>('session.models', { sessionId })
  let localGroup: CliModelCatalog['groups'][number] | undefined
  if (localProvider !== undefined) {
    const matches = configuredLocalGroups(catalog, localProvider)
    if (matches.length === 0) {
      throw new Error(`local provider ${JSON.stringify(localProvider)} is not configured on the DSH Host`)
    }
    if (matches.length > 1) {
      throw new Error(`local provider ${JSON.stringify(localProvider)} is ambiguous: ${matches.map(group => group.id).join(', ')}`)
    }
    localGroup = matches[0]
  }
  let provider: string
  let model: string
  const slash = requested?.indexOf('/') ?? -1
  if (requested !== undefined && slash > 0) {
    provider = requested.slice(0, slash)
    model = requested.slice(slash + 1)
    if (localGroup !== undefined && provider !== localGroup.id) {
      throw new Error(`model provider ${JSON.stringify(provider)} conflicts with --local-provider ${JSON.stringify(localGroup.id)}`)
    }
  } else if (requested !== undefined && localGroup !== undefined) {
    provider = localGroup.id
    model = requested
  } else if (requested !== undefined) {
    const owners = catalog.groups.filter(group => group.models.some(candidate => candidate.id === requested))
    if (owners.length > 1) throw new Error(`model ${JSON.stringify(requested)} exists under multiple providers; use provider/model`)
    provider = owners[0]?.id ?? catalog.current.provider
    model = requested
  } else {
    const first = localGroup?.models[0]
    if (localGroup === undefined || first === undefined) {
      throw new Error(`local provider ${JSON.stringify(localProvider)} advertises no selectable model`)
    }
    provider = localGroup.id
    model = first.id
  }
  await rpc('session.selectModel', {
    sessionId,
    provider,
    model,
    ...(reasoningEffort === undefined ? {} : { reasoningEffort }),
  })
}

async function setPermission(sessionId: string, opts: Record<string, unknown>): Promise<void> {
  const preset = opts.dangerouslyBypassApprovalsAndSandbox === true
    ? 'danger-full-access'
    : stringOption(opts, 'sandbox')
  if (preset === undefined) return
  if (!['read-only', 'workspace-write', 'danger-full-access'].includes(preset)) {
    throw new Error(`unsupported sandbox preset ${JSON.stringify(preset)}`)
  }
  const execution = await rpc<{ result: { kind: 'success' | 'error'; text?: string } }>('commands/execute', {
    args: { agentId: sessionId, line: `/permission ${preset}`, images: [] },
  })
  if (execution.result.kind !== 'success') {
    throw new Error(execution.result.text ?? `permission preset ${JSON.stringify(preset)} was rejected`)
  }
}

function normalizedApprovalPolicy(value: string): 'ask' | 'never' {
  if (value === 'never') return 'never'
  if (value === 'ask' || value === 'on-request' || value === 'untrusted') return 'ask'
  throw new Error(
    `unsupported approval policy ${JSON.stringify(value)}; this DSH composition supports ask/on-request/untrusted or never`,
  )
}

async function setApprovalPolicy(sessionId: string, opts: Record<string, unknown>): Promise<void> {
  const raw = stringOption(opts, 'askForApproval')
  if (raw === undefined) return
  const policy = normalizedApprovalPolicy(raw)
  if (opts.dangerouslyBypassApprovalsAndSandbox === true && policy !== 'never') {
    throw new Error('--dangerously-bypass-approvals-and-sandbox conflicts with an interactive approval policy')
  }
  const execution = await rpc<{ result: { kind: 'success' | 'error'; text?: string } }>('commands/execute', {
    args: { agentId: sessionId, line: `/approval ${policy}`, images: [] },
  })
  if (execution.result.kind !== 'success') {
    throw new Error(execution.result.text ?? `approval policy ${JSON.stringify(policy)} was rejected`)
  }
}

function configString(config: XConfig, key: string): string | undefined {
  const value = config[key]
  return typeof value === 'string' && value !== '' ? value : undefined
}

function applyExecutionConfig(opts: Record<string, unknown>, config: XConfig): void {
  if (stringOption(opts, 'model') === undefined) opts.model = configString(config, 'model')
  if (stringOption(opts, 'sandbox') === undefined) opts.sandbox = configString(config, 'sandbox_mode')
  if (stringOption(opts, 'askForApproval') === undefined) {
    opts.askForApproval = configString(config, 'approval_policy')
  }
  if (stringOption(opts, 'modelReasoningEffort') === undefined) {
    opts.modelReasoningEffort = configString(config, 'model_reasoning_effort')
  }
}

function rejectUnsupportedExecutionFlags(opts: Record<string, unknown>): void {
  if (opts.approveForMe === true) {
    throw new Error('--approve-for-me requires an automatic approval-reviewer plugin, which is not mounted')
  }
  if (opts.dangerouslyBypassHookTrust === true) {
    throw new Error('--dangerously-bypass-hook-trust is unavailable because DSH hook trust has no invocation-scoped bypass')
  }
  if (opts.ignoreRules === true) {
    throw new Error('--ignore-rules is unavailable because composed DSH instruction providers cannot be bypassed per invocation')
  }
  const writable = listOption(opts.addDir)
  if (writable.length > 0) {
    throw new Error(`--add-dir is unavailable because the mounted DSH sandbox supports one writable workspace root (received ${writable.length})`)
  }
}

async function configureSession(sessionId: string, opts: Record<string, unknown>): Promise<void> {
  rejectUnsupportedExecutionFlags(opts)
  let localProvider = stringOption(opts, 'localProvider')
  if (opts.oss === true && localProvider === undefined) {
    const catalog = await rpc<CliModelCatalog>('session.models', { sessionId })
    const local = configuredLocalGroups(catalog)
    if (local.length === 0) throw new Error('--oss requested a local model, but no Ollama or LM Studio provider is configured')
    if (local.length > 1) {
      throw new Error(`multiple local providers are configured (${local.map(group => group.id).join(', ')}); use --local-provider`)
    }
    const [onlyLocalProvider] = local
    if (onlyLocalProvider === undefined) throw new Error('--oss could not resolve the configured local provider')
    localProvider = onlyLocalProvider.id
  }
  await selectModel(
    sessionId,
    stringOption(opts, 'model'),
    localProvider,
    stringOption(opts, 'modelReasoningEffort'),
  )
  await setPermission(sessionId, opts)
  await setApprovalPolicy(sessionId, opts)
}

async function workspaceFor(cwd: string): Promise<string> {
  const value = await rpc<{ workspace: { workspaceId: string } }>('workspace.create', { path: cwd })
  return value.workspace.workspaceId
}

async function acquirePrompt(args: string[]): Promise<string> {
  const direct = args.join(' ').trim()
  if (direct !== '') return direct
  if (!process.stdin.isTTY) return readStdin()
  return ''
}

async function submitAndPrint(sessionId: string, prompt: string, opts: Record<string, unknown>): Promise<number> {
  if (prompt === '') throw new Error('a prompt is required (argument or stdin)')
  const schemaPath = stringOption(opts, 'outputSchema')
  const effectivePrompt = schemaPath === undefined
    ? prompt
    : `${prompt}\n\nReturn the final answer as JSON matching this schema exactly:\n${readFileSync(resolve(schemaPath), 'utf8')}`
  const before = await fullHistory(sessionId)
  const afterSeq = before.at(-1)?.event.seq ?? -1
  await rpc('session.prompt', {
    sessionId,
    mode: 'queue',
    content: promptParts(effectivePrompt, opts),
    clientTimeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
  })
  const json = opts.json === true
  const history = await waitForTurn(sessionId, afterSeq, json
    ? (events) => { for (const entry of events) process.stdout.write(`${JSON.stringify(entry)}\n`) }
    : undefined)
  const final = latestAssistantText(history)
  if (!json && final !== '') process.stdout.write(`${final}\n`)
  const output = stringOption(opts, 'outputLastMessage')
  if (output !== undefined) writeFileSync(resolve(output), final, 'utf8')
  return history.some(entry => entry.event.seq > afterSeq && entry.event.type === 'turn/end'
    && (entry.event.data.reason as { kind?: string } | undefined)?.kind === 'error') ? 1 : 0
}

async function createTask(prompt: string, opts: Record<string, unknown>): Promise<number> {
  rejectUnsupportedExecutionFlags(opts)
  if (opts.ephemeral === true) {
    throw new Error('this DSH composition has no disposable-session persistence provider; omit --ephemeral')
  }
  await ensureHost()
  const cwd = resolve(stringOption(opts, 'cd') ?? process.cwd())
  const workspaceId = await workspaceFor(cwd)
  const created = await rpc<{ sessionId: string }>('session.create', { workspaceId })
  await configureSession(created.sessionId, opts)
  return submitAndPrint(created.sessionId, prompt, opts)
}

async function resumeTask(
  reference: string | undefined,
  prompt: string,
  opts: Record<string, unknown>,
  fork: boolean,
): Promise<number> {
  rejectUnsupportedExecutionFlags(opts)
  await ensureHost()
  const source = await resolveSession(reference, opts.last === true)
  const sessionId = fork
    ? (await rpc<{ sessionId: string }>('session.fork', { sessionId: source.sessionId })).sessionId
    : source.sessionId
  await configureSession(sessionId, opts)
  if (prompt === '') {
    await openSurface(sessionId)
    return 0
  }
  return submitAndPrint(sessionId, prompt, opts)
}

function reviewPrompt(opts: Record<string, unknown>, extra: string): string {
  const target = opts.uncommitted === true ? 'the current uncommitted changes'
    : stringOption(opts, 'base') !== undefined ? `the changes against base ${stringOption(opts, 'base')}`
      : stringOption(opts, 'commit') !== undefined ? `commit ${stringOption(opts, 'commit')}`
        : 'the current workspace changes'
  const title = stringOption(opts, 'title')
  return [`Review ${target}. Identify concrete correctness, security, and regression issues.`, title === undefined ? '' : `Review title: ${title}.`, extra].filter(Boolean).join('\n\n')
}

function nativeAppBundle(): string | undefined {
  const explicit = process.env.OPENCODEX_APP_BUNDLE
  if (explicit !== undefined && existsSync(explicit)) return explicit
  const repository = fileURLToPath(new URL(
    '../../../.build/opencodex/DerivedData/Build/Products/Debug/OpenCodex.app',
    import.meta.url,
  ))
  return existsSync(repository) ? repository : undefined
}

async function openSurface(sessionId?: string, path?: string): Promise<void> {
  await ensureHost()
  if (process.platform === 'darwin') {
    const installed = spawnSync('open', ['-Rb', 'ai.deepseek.opencodex'])
    if (installed.status === 0) {
      const args = ['-b', 'ai.deepseek.opencodex']
      if (path !== undefined) args.push(path)
      spawnSync('open', args)
      return
    }
    const appBundle = nativeAppBundle()
    if (appBundle !== undefined) {
      const child = spawn('open', ['-n', appBundle], { stdio: 'ignore', detached: true })
      child.unref()
      return
    }
  }
  const url = `${apiBase()}/${sessionId === undefined ? '' : `#session=${encodeURIComponent(sessionId)}`}`
  const opener = process.platform === 'win32' ? ['cmd.exe', ['/c', 'start', '', url]] as const
    : process.platform === 'darwin' ? ['open', [url]] as const
      : ['xdg-open', [url]] as const
  const child = spawn(opener[0], [...opener[1]], { stdio: 'ignore', detached: true })
  child.unref()
}

const PROTOCOL_JSON_SCHEMA = {
  $schema: 'https://json-schema.org/draft/2020-12/schema',
  title: 'OpenCodex native bootstrap protocol v2',
  type: 'object',
  properties: {
    handshake: {
      type: 'object',
      required: ['ok', 'product', 'protocolVersion', 'minimumClientProtocol', 'host', 'surface'],
      properties: {
        ok: { const: true }, product: { const: 'opencodex' }, protocolVersion: { const: 'v2' },
        minimumClientProtocol: { type: 'string' }, host: { const: 'dsh' }, surface: { const: 'native' },
        plainHost: { enum: ['127.0.0.1', '0.0.0.0'] }, secureRemotePort: { type: 'integer', minimum: 1, maximum: 65535 },
      },
    },
    capabilities: {
      type: 'object',
      required: ['product', 'protocolVersion', 'api', 'features', 'contracts', 'pairing', 'transports', 'surfaces'],
      properties: {
        product: { const: 'opencodex' }, protocolVersion: { const: 'v2' },
        api: { type: 'object' }, features: { type: 'object' }, contracts: { type: 'object' },
        voice: {
          type: 'object',
          properties: {
            contract: { const: 'dsh.voice.v1' },
            transcriptAuthority: { const: 'session.prompt' },
            providers: { type: 'array', items: { type: 'object' } },
          },
        },
        pairing: { type: 'object', properties: { kind: { const: 'authenticated-tls-code' }, durable: { const: true } } },
        transports: { type: 'object' }, surfaces: { type: 'array', items: { enum: ['macos', 'iphone', 'cli', 'web'] } },
      },
    },
  },
}

const PROTOCOL_TS = `// Generated by opencodex app-server generate-ts — native bootstrap v2.
export interface OpenCodexNativeHandshake {
  ok: true
  product: 'opencodex'
  protocolVersion: 'v2'
  minimumClientProtocol: string
  host: 'dsh'
  surface: 'native'
  plainHost?: '127.0.0.1' | '0.0.0.0'
  secureRemotePort?: number
}
export interface OpenCodexNativeCapabilities {
  product: 'opencodex'
  protocolVersion: 'v2'
  host: 'dsh'
  surface: 'native'
  api: { base: string; hostEvents: string; muxEvents: string }
  features: { apiProxy: boolean; typert: boolean; remotePlugin: boolean; voicePlugin: boolean; localVoice: boolean; imageGenerationExtension: boolean }
  contracts: { sessions: boolean; workspaces: boolean; interactions: boolean; settings: boolean; providers: boolean; migration: boolean; sandbox: boolean }
  voice?: { contract: 'dsh.voice.v1'; transcriptAuthority: 'session.prompt'; providers: Array<{ id: string; name: string; platforms: Array<'macos' | 'iphone' | 'web'>; operations: Array<'speech-to-text' | 'text-to-speech'>; locality: 'device'; streaming: boolean; interruptible: boolean; quality: 'standard' | 'enhanced' | 'premium' }> }
  pairing: { supported: boolean; kind: 'authenticated-tls-code'; durable: boolean }
  transports: { lan: boolean; tailscale: boolean; relay: boolean }
  surfaces: Array<'macos' | 'iphone' | 'cli' | 'web'>
}
`

function generateProtocolFiles(opts: Record<string, unknown>, kind: 'json-schema' | 'typescript'): number {
  if (opts.experimental === true) {
    throw new Error('--experimental requested fields that the stable OpenCodex native protocol does not define')
  }
  const out = stringOption(opts, 'out') ?? 'opencodex-native'
  mkdirSync(out, { recursive: true })
  if (kind === 'json-schema') {
    writeFileSync(join(out, 'opencodex-native.schema.json'), `${JSON.stringify(PROTOCOL_JSON_SCHEMA, null, 2)}\n`)
    process.stdout.write(`wrote ${join(out, 'opencodex-native.schema.json')}\n`)
  } else {
    const path = join(out, 'opencodex-native.ts')
    writeFileSync(path, PROTOCOL_TS)
    const prettier = stringOption(opts, 'prettier')
    if (prettier !== undefined) {
      const formatted = spawnSync(prettier, ['--write', path], { stdio: 'inherit' })
      if (formatted.error !== undefined) throw formatted.error
      if (formatted.status !== 0) throw new Error(`Prettier exited with status ${formatted.status ?? 'unknown'}`)
    }
    process.stdout.write(`wrote ${path}\n`)
  }
  return 0
}

function runDshCaptured(args: string[]): { code: number; stdout: string; stderr: string } {
  const command = dshArgv(args)
  const result = spawnSync(command.command, command.args, {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.error !== undefined) throw result.error
  return {
    code: result.status ?? 1,
    stdout: redactCommandOutput(result.stdout),
    stderr: redactCommandOutput(result.stderr),
  }
}

interface AvailableMarketplacePlugin {
  name: string
  marketplace: string
  description?: string
  packageSpec?: string
  compatible: boolean
}

function safeMarketplaceName(source: string): string {
  let candidate: string
  try {
    const url = new URL(source)
    candidate = basename(url.pathname)
  } catch {
    candidate = basename(source)
  }
  candidate = candidate.replace(/\.git$/i, '')
  if (!/^[a-zA-Z0-9._-]+$/.test(candidate) || candidate === '.' || candidate === '') {
    throw new Error(`cannot derive a safe marketplace name from ${JSON.stringify(source)}`)
  }
  return candidate
}

function publicMarketplaceSource(source: string): string {
  try {
    const url = new URL(source)
    if (url.username !== '' || url.password !== '') {
      url.username = ''
      url.password = ''
    }
    url.search = ''
    return url.toString()
  } catch {
    return source
  }
}

function normalizeMarketplace(marketplace: Marketplace): Marketplace {
  if (marketplace.kind !== undefined && marketplace.root !== undefined) return marketplace
  const localCandidate = resolve(marketplace.source)
  if (existsSync(localCandidate) && statSync(localCandidate).isDirectory()) {
    return { ...marketplace, kind: 'local', root: realpathSync(localCandidate) }
  }
  const cached = join(marketplaceCacheRoot(), marketplace.name)
  if (existsSync(cached) && statSync(cached).isDirectory()) {
    return { ...marketplace, kind: 'git', root: realpathSync(cached) }
  }
  return { ...marketplace, kind: marketplace.kind ?? 'git' }
}

function normalizedMarketplaces(): Marketplace[] {
  return listMarketplaces().map(normalizeMarketplace)
}

function redactCommandOutput(value: string): string {
  return value
    .replace(/([a-z][a-z0-9+.-]*:\/\/)[^/@\s]+@/giu, '$1[redacted]@')
    .replace(/([?&](?:token|access_token|key|secret)=)[^&\s]+/giu, '$1[redacted]')
}

function gitMarketplaceSource(source: string): string | undefined {
  if (/^(?:https?|ssh|git):\/\//i.test(source) || /^git@[^:]+:/i.test(source)) return source
  if (/^[^/\s]+\/[^/\s]+$/.test(source)) return `https://github.com/${source}.git`
  return undefined
}

function runGit(args: string[], cwd?: string): void {
  const result = spawnSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  if (result.status !== 0) {
    throw new Error(`git marketplace operation failed (exit ${result.status ?? 'unknown'})`)
  }
}

function refreshMarketplace(marketplace: Marketplace): Marketplace {
  marketplace = normalizeMarketplace(marketplace)
  const root = marketplace.root ?? (marketplace.kind === 'local' ? resolve(marketplace.source) : undefined)
  if (root === undefined || !existsSync(root)) {
    throw new Error(`marketplace ${JSON.stringify(marketplace.name)} has no readable snapshot`)
  }
  if (marketplace.kind === 'git') {
    if (marketplace.ref !== undefined) {
      runGit(['fetch', '--depth', '1', 'origin', marketplace.ref], root)
      runGit(['checkout', '--detach', 'FETCH_HEAD'], root)
    } else {
      runGit(['pull', '--ff-only'], root)
    }
    const sparse = marketplace.sparse ?? []
    if (sparse.length > 0) {
      runGit(['sparse-checkout', 'set', ...sparse], root)
    }
  }
  const refreshed = { ...marketplace, root: realpathSync(root), updatedAt: new Date().toISOString() }
  saveMarketplace(refreshed)
  return refreshed
}

function addMarketplaceSource(source: string, ref?: string, sparse: string[] = []): Marketplace {
  const name = safeMarketplaceName(source)
  const local = existsSync(resolve(source)) ? realpathSync(resolve(source)) : undefined
  let marketplace: Marketplace
  if (local !== undefined) {
    if (!statSync(local).isDirectory()) throw new Error('a local marketplace source must be a directory')
    if (ref !== undefined || sparse.length > 0) throw new Error('--ref and --sparse apply only to Git marketplaces')
    marketplace = { name, source: local, kind: 'local', root: local, updatedAt: new Date().toISOString() }
  } else {
    const gitSource = gitMarketplaceSource(source)
    if (gitSource === undefined) throw new Error('marketplace source must be an existing directory, Git URL, or owner/repository')
    const root = join(marketplaceCacheRoot(), name)
    if (!existsSync(root)) {
      mkdirSync(marketplaceCacheRoot(), { recursive: true, mode: 0o700 })
      const cloneArgs = ['clone', '--depth', '1']
      if (ref !== undefined) cloneArgs.push('--branch', ref)
      if (sparse.length > 0) cloneArgs.push('--filter=blob:none', '--sparse')
      cloneArgs.push(gitSource, root)
      runGit(cloneArgs)
      if (sparse.length > 0) runGit(['sparse-checkout', 'set', ...sparse], root)
    }
    marketplace = { name, source: publicMarketplaceSource(gitSource), kind: 'git', root: realpathSync(root), ...(ref === undefined ? {} : { ref }), ...(sparse.length === 0 ? {} : { sparse }), updatedAt: new Date().toISOString() }
  }
  // A configured source must expose a real catalog now, not only metadata.
  readMarketplacePlugins(marketplace)
  saveMarketplace(marketplace)
  return marketplace
}

function readMarketplacePlugins(marketplace: Marketplace): AvailableMarketplacePlugin[] {
  marketplace = normalizeMarketplace(marketplace)
  const root = marketplace.root ?? (marketplace.kind === 'local' ? resolve(marketplace.source) : undefined)
  if (root === undefined) throw new Error(`marketplace ${JSON.stringify(marketplace.name)} has no local snapshot`)
  const candidates = [
    join(root, 'opencodex-marketplace.json'),
    join(root, '.opencodex', 'marketplace.json'),
    join(root, '.agents', 'plugins', 'marketplace.json'),
    join(root, '.claude-plugin', 'marketplace.json'),
  ]
  const manifestPath = candidates.find(existsSync)
  if (manifestPath === undefined) {
    throw new Error(`marketplace ${JSON.stringify(marketplace.name)} has no supported marketplace.json catalog`)
  }
  const parsed = JSON.parse(readFileSync(manifestPath, 'utf8')) as { plugins?: unknown }
  if (!Array.isArray(parsed.plugins)) throw new Error(`marketplace ${JSON.stringify(marketplace.name)} has no plugins array`)
  return parsed.plugins.map((raw): AvailableMarketplacePlugin => {
    if (typeof raw !== 'object' || raw === null) throw new Error(`marketplace ${JSON.stringify(marketplace.name)} contains an invalid plugin row`)
    const entry = raw as Record<string, unknown>
    if (typeof entry.name !== 'string' || entry.name.trim() === '') throw new Error(`marketplace ${JSON.stringify(marketplace.name)} contains an unnamed plugin`)
    const source = entry.package ?? entry.source
    let packageSpec: string | undefined
    if (typeof source === 'string' && source !== '') {
      packageSpec = source.startsWith('.') || source.startsWith('/') ? resolve(root, source) : source
    } else if (typeof source === 'object' && source !== null) {
      const path = (source as Record<string, unknown>).path
      if (typeof path === 'string' && path !== '') packageSpec = resolve(root, path)
    }
    let compatible = packageSpec !== undefined
    if (packageSpec !== undefined && existsSync(packageSpec)) {
      const packagePath = join(packageSpec, 'package.json')
      if (!existsSync(packagePath)) compatible = false
      else {
        const manifest = JSON.parse(readFileSync(packagePath, 'utf8')) as { dsh?: { bundle?: { patch?: unknown } } }
        compatible = manifest.dsh?.bundle?.patch !== undefined
      }
    }
    return {
      name: entry.name,
      marketplace: marketplace.name,
      ...(typeof entry.description === 'string' ? { description: entry.description } : {}),
      ...(packageSpec === undefined ? {} : { packageSpec }),
      compatible,
    }
  })
}

function availablePlugins(marketplaceName?: string): AvailableMarketplacePlugin[] {
  const sources = marketplaceName === undefined
    ? normalizedMarketplaces()
    : normalizedMarketplaces().filter(entry => entry.name === marketplaceName)
  return sources.flatMap(readMarketplacePlugins)
}

function resolvePluginInstall(spec: string, explicitMarketplace?: string): { name: string; packageSpec: string; marketplace?: string } {
  let name = spec
  let marketplaceName = explicitMarketplace
  if (marketplaceName === undefined) {
    const suffix = normalizedMarketplaces().find(entry => spec.endsWith(`@${entry.name}`))
    if (suffix !== undefined) {
      marketplaceName = suffix.name
      name = spec.slice(0, -(suffix.name.length + 1))
    }
  }
  if (marketplaceName === undefined) return { name, packageSpec: name }
  const candidates = availablePlugins(marketplaceName).filter(entry => entry.name === name)
  if (candidates.length !== 1) throw new Error(`plugin ${JSON.stringify(name)} was not found uniquely in marketplace ${JSON.stringify(marketplaceName)}`)
  const [plugin] = candidates
  if (plugin === undefined) throw new Error(`plugin ${JSON.stringify(name)} was not found`)
  if (!plugin.compatible || plugin.packageSpec === undefined) {
    throw new Error(`plugin ${JSON.stringify(name)} is not a DSH Cordis bundle and cannot join the OpenCodex profile`)
  }
  return { name, packageSpec: plugin.packageSpec, marketplace: marketplaceName }
}

interface ProfileManifest {
  dependencies?: Record<string, string>
  dsh?: { profile?: { bundles?: string[] } }
}

function readProfileManifest(): ProfileManifest {
  try {
    return JSON.parse(readFileSync(join(profileDir(), 'package.json'), 'utf8')) as ProfileManifest
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return {}
    throw error
  }
}

function packageNameFromSpec(spec: string): string | undefined {
  if (existsSync(spec)) {
    const path = statSync(spec).isDirectory() ? join(spec, 'package.json') : spec
    if (existsSync(path)) {
      const manifest = JSON.parse(readFileSync(path, 'utf8')) as { name?: unknown }
      if (typeof manifest.name === 'string' && manifest.name !== '') return manifest.name
    }
  }
  if (spec.startsWith('@')) {
    const slash = spec.indexOf('/')
    if (slash < 2) return undefined
    const version = spec.indexOf('@', slash)
    return version === -1 ? spec : spec.slice(0, version)
  }
  if (/^[a-zA-Z0-9._-]+(?:@[^/]+)?$/.test(spec)) return spec.split('@')[0]
  return undefined
}

function assertBundleActivated(
  before: ProfileManifest,
  after: ProfileManifest,
  packageSpec: string,
): void {
  const beforeDependencies = before.dependencies ?? {}
  const afterDependencies = after.dependencies ?? {}
  const changed = Object.keys(afterDependencies).filter(name => beforeDependencies[name] !== afterDependencies[name])
  const direct = packageNameFromSpec(packageSpec)
  const candidates = new Set([...changed, ...(direct === undefined ? [] : [direct])])
  const bundles = new Set(after.dsh?.profile?.bundles ?? [])
  if ([...candidates].some(name => bundles.has(name))) return

  // DSH intentionally permits plain dependencies. OpenCodex's plugin command
  // is narrower: roll back newly added plain packages so the user never sees a
  // successful "plugin" install that contributed no Cordis layer.
  for (const name of changed) runDshCaptured(['plugin', '--profile', LEGACY_PROFILE, 'remove', name])
  throw new Error(
    `${packageSpec} installed no dsh.bundle Cordis layer; the plain dependency was not retained`,
  )
}

function discoverRollouts(root: string, threads: readonly string[] = []): string[] {
  const found: string[] = []
  const visit = (dir: string): void => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const path = join(dir, entry.name)
      if (entry.isDirectory()) visit(path)
      else if (entry.isFile() && entry.name.endsWith('.jsonl')
        && (threads.length === 0 || threads.some(thread => entry.name.includes(thread)))) found.push(path)
    }
  }
  if (existsSync(root)) visit(root)
  return found.sort()
}

async function migrateRollouts(opts: Record<string, unknown>): Promise<number> {
  const root = join(process.env.CODEX_HOME ?? join(homedir(), '.codex'), 'sessions')
  const files = discoverRollouts(root, listOption(opts.thread))
  const rollouts = files.map(path => ({ path, bytes: statSync(path).size }))
  if (opts.apply !== true) {
    const view = { source: root, files: files.length, bytes: rollouts.reduce((sum, item) => sum + item.bytes, 0), apply: false, rollouts }
    if (opts.json === true) emitJson(view)
    else {
      process.stdout.write(`Found ${view.files} Codex rollout file(s), ${view.bytes} bytes. Re-run with --apply to import.\n`)
      if (opts.verbose === true) {
        for (const item of rollouts) process.stdout.write(`${item.bytes}\t${item.path}\n`)
      }
    }
    return 0
  }
  if (files.length === 0) throw new Error(`no Codex rollout files found under ${root}`)
  const rateRaw = stringOption(opts, 'maxMibPerSecond')
  const rate = rateRaw === undefined ? undefined : Number(rateRaw)
  if (rate !== undefined && (!Number.isFinite(rate) || rate <= 0)) {
    throw new Error('--max-mib-per-second must be a positive number')
  }
  await ensureHost()
  const workspaceId = await workspaceFor(process.cwd())
  const batches: string[][] = []
  let batch: string[] = []
  let batchBytes = 0
  for (const path of files) {
    const bytes = statSync(path).size
    if (bytes > 160 * 1024 * 1024) {
      throw new Error(`rollout ${JSON.stringify(path)} exceeds the 160 MiB migration safety limit`)
    }
    if (batch.length >= 32 || (batch.length > 0 && batchBytes + bytes > 48 * 1024 * 1024)) {
      batches.push(batch)
      batch = []
      batchBytes = 0
    }
    batch.push(path)
    batchBytes += bytes
  }
  if (batch.length > 0) batches.push(batch)
  const imported: unknown[] = []
  const startedAt = Date.now()
  let transferredBytes = 0
  for (const batch of batches) {
    const payloadFiles = batch.map((path) => {
      const data = readFileSync(path)
      transferredBytes += data.byteLength * 2
      return { name: basename(path), data: data.toString('base64') }
    })
    const value = await rpc<{ items: unknown[] }>('session.import', {
      workspaceId,
      format: 'codex-jsonl',
      files: payloadFiles,
    })
    imported.push(...value.items)
    if (opts.verbose === true && opts.json !== true) {
      for (const path of batch) process.stdout.write(`imported\t${path}\n`)
    }
    if (rate !== undefined) {
      const expectedMs = transferredBytes / (rate * 1024 * 1024) * 1_000
      const remainingMs = expectedMs - (Date.now() - startedAt)
      if (remainingMs > 0) await new Promise(resolveWait => setTimeout(resolveWait, remainingMs))
    }
  }
  if (opts.json === true) emitJson({ imported })
  else process.stdout.write(`Imported ${imported.length} task(s) into the DSH session store.\n`)
  return 0
}

function completion(shell = 'bash'): string {
  const commands = ['app', 'app-server', 'archive', 'completion', 'doctor', 'exec', 'features', 'fork', 'login', 'logout', 'mcp', 'migrate-rollouts', 'plugin', 'remote-control', 'resume', 'review', 'sandbox', 'unarchive']
  const joined = commands.join(' ')
  if (shell === 'fish') return `complete -c opencodex -f -a '${joined}'\n`
  if (shell === 'zsh') return `#compdef opencodex\n_arguments '1:command:(${joined})'\n`
  return `_opencodex_complete(){ COMPREPLY=( $(compgen -W '${joined}' -- "\${COMP_WORDS[1]}") ); }; complete -F _opencodex_complete opencodex\n`
}

interface CliSandboxResult {
  exitCode: number | null
  signal: string | null
  timedOut: boolean
  aborted: boolean
  stdout: string
  stderr: string
  stdoutTruncated: boolean
  stderrTruncated: boolean
  sandbox: { mode: 'read-only' | 'workspace-write'; denied: boolean; enforcement?: 'full' | 'partial' }
}

function quoteCommandArgument(value: string): string {
  if (process.platform === 'win32') return `'${value.replaceAll("'", "''")}'`
  return `'${value.replaceAll("'", '\'\\\'\'')}'`
}

function commandSource(args: string[]): string {
  if (args.length === 0) throw new Error('missing command to run in the DSH sandbox')
  const [command] = args
  if (command === undefined) throw new Error('missing command to run in the DSH sandbox')
  return args.length === 1 ? command : args.map(quoteCommandArgument).join(' ')
}

function sandboxRequest(
  args: string[],
  opts: Record<string, unknown>,
): { command: string; cwd: string; mode: 'read-only' | 'workspace-write'; timeoutMs?: number } {
  rejectOptions(opts, [
    ['sandboxStateReadableRoot', '--sandbox-state-readable-root'],
    ['sandboxStateDisableNetwork', '--sandbox-state-disable-network'],
    ['allowUnixSocket', '--allow-unix-socket'],
    ['logDenials', '--log-denials'],
    ['includeManagedConfig', '--include-managed-config'],
  ], 'cannot be represented by DSH\'s file-effect sandbox contract')

  let mode = stringOption(opts, 'permissionProfile') ?? stringOption(opts, 'sandbox') ?? 'read-only'
  let cwd = process.cwd()
  const stateText = stringOption(opts, 'sandboxStateJson')
  if (stateText !== undefined) {
    let state: unknown
    try { state = JSON.parse(stateText) } catch { throw new Error('--sandbox-state-json must be valid JSON') }
    if (typeof state !== 'object' || state === null || Array.isArray(state)) {
      throw new Error('--sandbox-state-json must be a JSON object')
    }
    const record = state as Record<string, unknown>
    const supported = new Set(['mode', 'sandbox_mode', 'workspaceRoot', 'workspace_root', 'timeoutMs', 'timeout_ms'])
    const unknown = Object.keys(record).filter(key => !supported.has(key))
    if (unknown.length > 0) {
      throw new Error(`--sandbox-state-json contains fields outside the DSH sandbox contract: ${unknown.join(', ')}`)
    }
    const stateMode = record.mode ?? record.sandbox_mode
    if (typeof stateMode === 'string') mode = stateMode
    const stateRoot = record.workspaceRoot ?? record.workspace_root
    if (typeof stateRoot === 'string' && stateRoot !== '') cwd = resolve(stateRoot)
    const timeout = record.timeoutMs ?? record.timeout_ms
    if (timeout !== undefined && (typeof timeout !== 'number' || !Number.isSafeInteger(timeout) || timeout <= 0 || timeout > 600_000)) {
      throw new Error('sandbox timeout must be an integer from 1 to 600000 milliseconds')
    }
    if (typeof timeout === 'number') {
      return normalizedSandboxRequest(args, mode, cwd, timeout)
    }
  }
  return normalizedSandboxRequest(args, mode, cwd)
}

function normalizedSandboxRequest(
  args: string[],
  mode: string,
  cwd: string,
  timeoutMs?: number,
): { command: string; cwd: string; mode: 'read-only' | 'workspace-write'; timeoutMs?: number } {
  if (mode !== 'read-only' && mode !== 'workspace-write') {
    throw new Error(`sandbox permission profile must be read-only or workspace-write, got ${JSON.stringify(mode)}`)
  }
  return { command: commandSource(args), cwd: resolve(cwd), mode, ...(timeoutMs === undefined ? {} : { timeoutMs }) }
}

async function runSandboxCommand(args: string[], opts: Record<string, unknown>): Promise<number> {
  await ensureHost()
  const result = await rpc<CliSandboxResult>('host.runSandboxed', sandboxRequest(args, opts))
  if (result.stdout !== '') process.stdout.write(result.stdout)
  if (result.stderr !== '') process.stderr.write(result.stderr)
  if (result.stdoutTruncated || result.stderrTruncated) {
    process.stderr.write('opencodex sandbox: DSH bounded the captured command output; the displayed tail is incomplete\n')
  }
  if (result.timedOut) process.stderr.write('opencodex sandbox: command timed out\n')
  if (result.sandbox.denied) process.stderr.write('opencodex sandbox: the DSH sandbox denied a file operation\n')
  return result.exitCode ?? (result.aborted || result.signal !== null ? 130 : 1)
}

function unavailable(path: string, capability: string): number {
  process.stderr.write(`opencodex ${path}: this DSH composition does not mount ${capability}\n`)
  return 2
}

function optionWasProvided(opts: Record<string, unknown>, key: string): boolean {
  const value = opts[key]
  if (Array.isArray(value)) return value.length > 0
  return value !== undefined && value !== false
}

function rejectOptions(
  opts: Record<string, unknown>,
  entries: ReadonlyArray<readonly [key: string, flag: string]>,
  explanation: string,
): void {
  const present = entries.filter(([key]) => optionWasProvided(opts, key)).map(([, flag]) => flag)
  if (present.length > 0) throw new Error(`${present.join(', ')} ${explanation}`)
}

/** Compatibility export retained for callers of the old test seam. */
export function printStatus(path: string): void {
  process.stdout.write(`opencodex ${path}: available through the DSH Host\n`)
}

export async function run(invocation: Invocation, opts: Record<string, unknown>): Promise<number> {
  const path = invocation.path
  const args = invocation.args
  try {
    opts = { ...opts }
    const config = opts.ignoreUserConfig === true
      ? {}
      : loadLayeredConfig(stringOption(opts, 'profile'))
    for (const configOverride of listOption(opts.config)) applyConfigOverride(config, configOverride)
    const requestedFeatureOverrides = [
      ...listOption(opts.enable).map(name => `--enable ${name}`),
      ...listOption(opts.disable).map(name => `--disable ${name}`),
    ]
    if (requestedFeatureOverrides.length > 0) {
      throw new Error(
        `${requestedFeatureOverrides.join(', ')} cannot rewrite the running DSH service graph; use plugin add/remove or edit the OpenCodex Cordis profile`,
      )
    }
    if (opts.strictConfig === true) {
      const unknown = validateStrictConfig(config)
      if (unknown.length > 0) throw new Error(`strict config: unknown keys: ${unknown.join(', ')}`)
    }
    const featureErrors = validateFeatureRequests(config)
    if (featureErrors.length > 0) {
      throw new Error(`invalid compatibility feature config: ${featureErrors.join('; ')}`)
    }
    applyExecutionConfig(opts, config)
    const remote = stringOption(opts, 'remote')
    if (remote !== undefined) process.env.OPENCODEX_API = remote
    const tokenEnv = stringOption(opts, 'remoteAuthTokenEnv')
    if (tokenEnv !== undefined) process.env.OPENCODEX_REMOTE_AUTH_TOKEN_ENV = tokenEnv

    if (path === 'app-server' || path.startsWith('app-server/')) {
      rejectOptions(opts, [
        ['codeModeHost', '--code-mode-host'],
        ['analyticsDefaultEnabled', '--analytics-default-enabled'],
        ['wsAuth', '--ws-auth'],
        ['wsTokenFile', '--ws-token-file'],
        ['wsTokenSha256', '--ws-token-sha256'],
        ['wsSharedSecretFile', '--ws-shared-secret-file'],
        ['wsIssuer', '--ws-issuer'],
        ['wsAudience', '--ws-audience'],
        ['wsMaxClockSkewSeconds', '--ws-max-clock-skew-seconds'],
      ], 'is not part of the DSH Host carrier; OpenCodex remote access uses one-time pairing and durable bearer identities')
    }

    if (path === 'exec') return await createTask(await acquirePrompt(args), opts)
    if (path === 'exec/resume' || path === 'resume') {
      return await resumeTask(args[0], await acquirePrompt(args.slice(1)), opts, false)
    }
    if (path === 'exec/fork' || path === 'fork') {
      return await resumeTask(args[0], await acquirePrompt(args.slice(1)), opts, true)
    }
    if (path === 'exec/review' || path === 'review') {
      const targets = [opts.uncommitted === true, stringOption(opts, 'base') !== undefined, stringOption(opts, 'commit') !== undefined]
      if (targets.filter(Boolean).length > 1) throw new Error('choose only one of --uncommitted, --base, or --commit')
      return await createTask(reviewPrompt(opts, await acquirePrompt(args)), opts)
    }

    if (path === 'app') {
      if (stringOption(opts, 'downloadUrl') !== undefined) {
        return unavailable(path, 'a downloadable installer override; launch an installed or locally built OpenCodex app')
      }
      await openSurface(undefined, args[0])
      return 0
    }

    if (path === 'archive' || path === 'unarchive') {
      await ensureHost()
      const session = await resolveSession(args[0])
      const method = path === 'archive' ? 'workspace.archiveSession' : 'workspace.unarchiveSession'
      const value = await rpc<{ archivedSessionIds: string[] }>(method, { sessionId: session.sessionId })
      if (opts.json === true) emitJson({ sessionId: session.sessionId, archived: path === 'archive', archivedSessionIds: value.archivedSessionIds })
      else process.stdout.write(`${path === 'archive' ? 'Archived' : 'Unarchived'} ${titleOf(session)} (${session.sessionId})\n`)
      return 0
    }
    if (path === 'delete') return unavailable(path, 'a permanent session-deletion persistence provider; use archive instead')

    if (path === 'migrate-rollouts') return await migrateRollouts(opts)

    if (path === 'login') {
      if (opts.withApiKey === true || opts.withAccessToken === true) {
        await ensureHost()
        const secret = await readStdin()
        if (secret === '') throw new Error('credential stdin is empty')
        const ref = opts.withApiKey === true ? 'DEEPSEEK_API_KEY' : 'OPENAI_API_KEY'
        await rpc('credentials.set', { ref, value: secret })
        process.stdout.write(`Credential stored by the DSH Host for ${ref}.\n`)
        return 0
      }
      if (opts.deviceAuth === true) {
        const code = process.stdin.isTTY ? undefined : await readStdin()
        const response = await hostRequest('/x-native/v2/pair', {
          method: 'POST', headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ surface: 'cli', deviceName: `${hostname()} (OpenCodex CLI)`, appVersion: VERSION, ...(code === undefined || code === '' ? {} : { code }) }),
        })
        const value = await response.json() as { deviceId?: string; token?: string; expiresAt?: number; error?: { message?: string } }
        if (!response.ok || value.deviceId === undefined || value.token === undefined || value.expiresAt === undefined) {
          throw new Error(value.error?.message ?? `pairing failed with HTTP ${response.status}`)
        }
        saveConnection({
          api: apiBase(),
          deviceId: value.deviceId,
          token: value.token,
          expiresAt: value.expiresAt,
          updatedAt: new Date().toISOString(),
        })
        process.stdout.write(`Paired this CLI as device ${value.deviceId}. The bearer token was stored locally with mode 0600.\n`)
        return 0
      }
      process.stderr.write('Usage: opencodex login [--with-api-key | --with-access-token | --device-auth]\n')
      return 1
    }

    if (path === 'login/status') {
      await ensureHost()
      const value = await rpc<{ credentials: Record<string, { configured: boolean; source?: string; writable: boolean }> }>(
        'credentials.describe', { refs: ['DEEPSEEK_API_KEY', 'OPENAI_API_KEY'] },
      )
      const rows = Object.entries(value.credentials).map(([ref, state]) => ({ ref, ...state }))
      if (opts.json === true) emitJson(rows)
      else for (const row of rows) process.stdout.write(`${row.ref}\t${row.configured ? `configured (${row.source ?? 'provider'})` : 'not configured'}\n`)
      return rows.some(row => row.configured) ? 0 : 1
    }

    if (path === 'logout') {
      await ensureHost()
      for (const ref of ['DEEPSEEK_API_KEY', 'OPENAI_API_KEY']) {
        const described = await rpc<{ credentials: Record<string, { writable: boolean }> }>('credentials.describe', { refs: [ref] })
        if (described.credentials[ref]?.writable === true) await rpc('credentials.unset', { ref })
      }
      clearConnection()
      process.stdout.write('Writable model credentials were removed from the DSH Host; the local device profile was cleared.\n')
      return 0
    }

    if (path === 'plugin' || path === 'plugin/list') {
      const manifest = readProfileManifest()
      const bundles = new Set(manifest.dsh?.profile?.bundles ?? [])
      const installed = Object.entries(manifest.dependencies ?? {})
        .filter(([name]) => bundles.has(name))
        .map(([name, version]) => ({ name, version }))
      const marketplace = stringOption(opts, 'marketplace')
      const available = opts.available === true ? availablePlugins(marketplace) : []
      if (opts.json === true) emitJson({ installed, ...(opts.available === true ? { available } : {}) })
      else {
        for (const plugin of installed) process.stdout.write(`${plugin.name}@${plugin.version}\n`)
        if (opts.available === true) {
          for (const plugin of available) {
            process.stdout.write(`${plugin.name}\t${plugin.marketplace}\t${plugin.compatible ? 'DSH bundle' : 'incompatible'}\n`)
          }
        }
      }
      return 0
    }

    if (path === 'plugin/add' || path === 'plugin/remove') {
      const spec = args[0]
      if (spec === undefined) throw new Error('missing <PLUGIN[@MARKETPLACE]>')
      const resolved = resolvePluginInstall(spec, stringOption(opts, 'marketplace'))
      let packageSpec = resolved.packageSpec
      if (path === 'plugin/remove' && existsSync(packageSpec)) {
        const manifest = JSON.parse(readFileSync(join(packageSpec, 'package.json'), 'utf8')) as { name?: unknown }
        if (typeof manifest.name === 'string') packageSpec = manifest.name
      }
      const before = readProfileManifest()
      const result = runDshCaptured(['plugin', '--profile', LEGACY_PROFILE, path === 'plugin/add' ? 'add' : 'remove', packageSpec])
      if (path === 'plugin/add' && result.code === 0) {
        assertBundleActivated(before, readProfileManifest(), packageSpec)
      }
      if (opts.json === true) emitJson({ plugin: resolved.name, marketplace: resolved.marketplace, ok: result.code === 0 })
      else { process.stdout.write(result.stdout); if (result.stderr !== '') process.stderr.write(result.stderr) }
      return result.code
    }

    if (path === 'plugin/marketplace' || path === 'plugin/marketplace/list') {
      const marketplaces = normalizedMarketplaces()
      if (opts.json === true) emitJson(marketplaces)
      else for (const entry of marketplaces) process.stdout.write(`${entry.name}\t${publicMarketplaceSource(entry.source)}\n`)
      return 0
    }
    if (path === 'plugin/marketplace/add') {
      const source = args[0]
      if (source === undefined) throw new Error('missing <SOURCE>')
      const ref = stringOption(opts, 'ref')
      const sparse = listOption(opts.sparse)
      const entry = addMarketplaceSource(source, ref, sparse)
      if (opts.json === true) emitJson(entry); else process.stdout.write(`Added marketplace ${entry.name}.\n`)
      return 0
    }
    if (path === 'plugin/marketplace/remove') {
      const name = args[0]
      if (name === undefined) throw new Error('missing <MARKETPLACE_NAME>')
      const removed = removeMarketplace(name)
      if (opts.json === true) emitJson({ name, removed }); else process.stdout.write(`${removed ? 'Removed' : 'Not found'} ${name}.\n`)
      return removed ? 0 : 1
    }
    if (path === 'plugin/marketplace/upgrade') {
      const targets = args[0] === undefined ? normalizedMarketplaces() : normalizedMarketplaces().filter(entry => entry.name === args[0])
      const refreshed = targets.map(refreshMarketplace)
      for (const entry of refreshed) readMarketplacePlugins(entry)
      if (opts.json === true) emitJson(refreshed); else for (const entry of refreshed) process.stdout.write(`Refreshed ${entry.name}.\n`)
      return refreshed.length > 0 ? 0 : 1
    }

    if (path === 'features/list') {
      await ensureHost()
      const capabilities = await readLiveCapabilities()
      const rows = compositionCapabilityRows(capabilities)
      if (opts.json === true) {
        emitJson({ owner: 'dsh', capabilities: rows })
      } else {
        for (const feature of rows) {
          process.stdout.write(`${feature.name.padEnd(24)} ${feature.state.padEnd(16)} ${feature.owner.padEnd(24)} ${feature.detail}\n`)
        }
      }
      return 0
    }
    if (path === 'features/enable' || path === 'features/disable') {
      const feature = args[0]
      if (feature === undefined) throw new Error('missing feature name')
      throw new Error(
        `${feature} is a DSH composition capability, not a CLI-local flag; use opencodex plugin ${path === 'features/enable' ? 'add' : 'remove'} or edit the Cordis profile`,
      )
    }

    if (path === 'mcp' || path === 'mcp/list') {
      const servers = listServers()
      if (opts.json === true) emitJson(servers)
      else for (const server of servers) process.stdout.write(`${server.name.padEnd(24)} ${server.transport}\n`)
      return 0
    }
    if (path === 'mcp/get') {
      const server = args[0] === undefined ? undefined : getServer(args[0])
      if (server === undefined) throw new Error(`MCP server ${JSON.stringify(args[0])} is not configured`)
      emitJson(opts.json === true ? server : server.config)
      return 0
    }
    if (path === 'mcp/add') {
      const name = args[0]
      if (name === undefined) throw new Error('missing <NAME>')
      if (opts.oauthClientId !== undefined || opts.oauthClientRegistration !== undefined || opts.oauthResource !== undefined) {
        return unavailable(path, 'an MCP OAuth provider; bearer environment references and stdio servers are supported')
      }
      const env: Record<string, string> = {}
      for (const assignment of listOption(opts.env)) {
        const equals = assignment.indexOf('=')
        if (equals <= 0) throw new Error(`--env must be KEY=VALUE, got ${JSON.stringify(assignment)}`)
        const key = assignment.slice(0, equals)
        if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`invalid environment variable name ${JSON.stringify(key)}`)
        env[key] = assignment.slice(equals + 1)
      }
      const url = stringOption(opts, 'url')
      const bearerTokenEnvVar = stringOption(opts, 'bearerTokenEnvVar')
      const server = addServer(name, {
        ...(url === undefined ? {} : { url }),
        ...(bearerTokenEnvVar === undefined ? {} : { bearerTokenEnvVar }),
        env,
        commandArgs: args.slice(1),
      })
      if (opts.json === true) emitJson(server); else process.stdout.write(`Added ${server.name}. Restart the OpenCodex Host to activate it.\n`)
      return 0
    }
    if (path === 'mcp/remove') {
      if (args[0] === undefined) throw new Error('missing <NAME>')
      const removed = removeServer(args[0])
      process.stdout.write(`${removed ? 'Removed' : 'Not found'} ${args[0]}.\n`)
      return removed ? 0 : 1
    }
    if (path === 'mcp/login' || path === 'mcp/logout') return unavailable(path, 'an MCP OAuth provider')
    if (path === 'mcp-server') return unavailable(path, 'an outbound MCP-server bridge (the mounted MCP plugin is a client bridge)')

    if (path === 'remote-control/pair') {
      await ensureHost()
      const response = await hostRequest('/x-native/v2/pairing-code', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' })
      const value = await response.json() as { code?: string; expiresAt?: number; error?: { message?: string } }
      if (!response.ok || value.code === undefined) throw new Error(value.error?.message ?? `pairing code failed with HTTP ${response.status}`)
      if (opts.json === true) emitJson(value)
      else process.stdout.write(`Pairing code: ${value.code}\nExpires: ${new Date(value.expiresAt ?? 0).toISOString()}\n`)
      return 0
    }
    if (path === 'remote-control/start') {
      const pid = startDaemon(true)
      if (opts.json === true) emitJson({ running: true, pid }); else process.stdout.write(`Remote OpenCodex Host started (pid ${pid ?? 'unknown'}).\n`)
      return 0
    }
    if (path === 'remote-control/stop') {
      stopDaemon()
      if (opts.json === true) emitJson({ running: false }); else process.stdout.write('OpenCodex Host stopped.\n')
      return 0
    }
    if (path === 'remote-control') {
      const pid = daemonPid()
      if (opts.json === true) emitJson({ running: pid !== undefined, pid }); else process.stdout.write(pid === undefined ? 'OpenCodex Host is not running.\n' : `OpenCodex Host is running (pid ${pid}).\n`)
      return pid === undefined ? 1 : 0
    }

    if (path === 'app-server/generate-json-schema') return generateProtocolFiles(opts, 'json-schema')
    if (path === 'app-server/generate-ts') return generateProtocolFiles(opts, 'typescript')
    if (path === 'app-server/proxy') {
      const sock = stringOption(opts, 'sock')
      if (sock === undefined) throw new Error('missing --sock <SOCKET_PATH>')
      return await new Promise((resolveCode) => {
        const socket = createConnection(sock)
        socket.once('error', (error) => { process.stderr.write(`opencodex app-server proxy: ${errorText(error)}\n`); resolveCode(1) })
        socket.once('connect', () => { process.stdin.pipe(socket); socket.pipe(process.stdout) })
        socket.once('close', () =>{  resolveCode(0) })
      })
    }
    if (path === 'app-server/version' || path === 'app-server/daemon/version') {
      process.stdout.write(`opencodex-app-server ${VERSION} (DSH web profile + native bootstrap v2)\n`)
      return 0
    }
    if (path === 'app-server/daemon/bootstrap') {
      if (opts.remoteControl === true) {
        return unavailable(path, 'a bootstrap-time remote toggle; bootstrap first, then use remote-control start')
      }
      return spawnDsh(['plugin', '--profile', LEGACY_PROFILE, 'install'])
    }
    if (path === 'app-server/daemon/start' || path === 'app-server/daemon/restart'
      || path === 'app-server/daemon/enable-remote-control' || path === 'app-server/daemon/disable-remote-control') {
      if (path !== 'app-server/daemon/start') stopDaemon()
      const remoteMode = path === 'app-server/daemon/enable-remote-control'
      const pid = startDaemon(remoteMode, stringOption(opts, 'listen'))
      process.stdout.write(`OpenCodex app server started (pid ${pid ?? 'unknown'}, ${remoteMode ? 'LAN/Tailscale' : 'loopback'} mode).\n`)
      return 0
    }
    if (path === 'app-server/daemon/stop') { stopDaemon(); return 0 }
    if (path === 'exec-server') {
      return unavailable(path, 'a separate exec-server runtime; OpenCodex serves execution through the DSH Host')
    }
    if (path === 'app-server') {
      if (args.length > 0) throw new Error(`unknown app-server command ${JSON.stringify(args[0])}`)
      if (opts.stdio === true) return unavailable(path, 'a stdio Host carrier; HTTP/WebSocket is the authoritative transport')
      return spawnDsh(serverArgs(false, stringOption(opts, 'listen')))
    }

    if (path === 'doctor') {
      const checks: Array<{ name: string; ok: boolean; detail: string }> = []
      try { checks.push({ name: 'DSH runtime', ok: true, detail: dshBin() }) } catch (error) { checks.push({ name: 'DSH runtime', ok: false, detail: errorText(error) }) }
      const reachable = await health()
      checks.push({ name: 'DSH Host API', ok: reachable, detail: apiBase() })
      if (reachable) {
        try {
          const handshake = await (await hostRequest('/x-native/v2/health')).json() as { protocolVersion?: string; product?: string }
          checks.push({ name: 'Native protocol', ok: handshake.product === PRODUCT && handshake.protocolVersion === 'v2', detail: `${handshake.product ?? 'unknown'} ${handshake.protocolVersion ?? 'unknown'}` })
          const description = await rpc<{ provider: string; model: string }>('host.describe', {})
          checks.push({ name: 'Default model', ok: true, detail: `${description.provider}/${description.model}` })
        } catch (error) { checks.push({ name: 'Host contract', ok: false, detail: errorText(error) }) }
      }
      if (opts.json === true) emitJson({ status: checks.every(check => check.ok) ? 'ok' : 'degraded', checks })
      else if (opts.summary === true) process.stdout.write(`${checks.filter(check => check.ok).length}/${checks.length} checks passed\n`)
      else for (const check of checks) process.stdout.write(`${opts.ascii === true ? (check.ok ? '[ok]' : '[!!]') : (check.ok ? '✓' : '✗')} ${check.name}: ${check.detail}\n`)
      return checks.every(check => check.ok) ? 0 : 1
    }

    if (path === 'debug/models') {
      if (opts.bundled === true) emitJson(loadFeatureRegistry())
      else { await ensureHost(); emitJson(await rpc('llm.providers', {})) }
      return 0
    }
    if (path === 'debug/prompt-input') {
      emitJson({ content: promptParts(await acquirePrompt(args), opts) })
      return 0
    }
    if (path === 'debug/app-server/send-message-v2') return await createTask(args.join(' '), opts)

    if (path === 'completion') { process.stdout.write(completion(args[0])); return 0 }
    if (path === 'sandbox') return await runSandboxCommand(args, opts)

    if (path === 'cloud' || path.startsWith('cloud/') || path === 'apply') {
      return unavailable(path, 'a cloud task provider; local, LAN, Tailscale, and relay transports use DSH sessions')
    }
    if (path === 'update') return unavailable(path, 'a package-manager updater; update with the package manager used to install OpenCodex')
    if (path === 'debug') return unavailable(path, 'the requested debug subcommand')

    if (path === 'features' || path === 'plugin/marketplace' || path === 'app-server/daemon') {
      process.stderr.write(`opencodex ${path}: choose a subcommand; see --help\n`)
      return 1
    }
    throw new Error(`unknown command path ${path}`)
  } catch (error) {
    process.stderr.write(`opencodex ${path}: ${errorText(error)}\n`)
    return 1
  }
}

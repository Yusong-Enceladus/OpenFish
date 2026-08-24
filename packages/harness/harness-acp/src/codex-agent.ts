/** First-class OpenFish Agent projection over the official Codex app-server. */
import { homedir } from 'node:os'
import { join } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { constants } from 'node:fs'
import { chmod, lstat, mkdir, open, rename, rm, writeFile } from 'node:fs/promises'
import type { Context } from '@deepseek-ai/cordis'
import {
  agentEvents, Inbox,
  type Agent, type AgentCancelCause, type AgentEventDispatch, type AgentOptions,
  type AgentStatus, type CancelOptions, type InboxTarget,
} from '@deepseek-ai/dsh-agent'
import { createAssistantMessage, type UserMessage } from '@deepseek-ai/dsh-llm'
import { createScope, type Scope } from '@deepseek-ai/dsh-scope'
import type { Session, SessionId, TurnEndReason } from '@deepseek-ai/dsh-session'
import {
  observeHarnessRuntime,
  type HarnessCapability,
  type HarnessPack,
  type HarnessRuntimeSignal,
  type HarnessSessionRequest,
} from '@deepseek-ai/dsh-harness'
import type { SubprocessHandle } from '@deepseek-ai/dsh-subprocess'
import type { SandboxMode } from '@deepseek-ai/dsh-sandbox'
import type { SandboxAuthorityController } from '@deepseek-ai/dsh-sandbox-policy'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import {
  CodexAppServerWire,
  type CodexAppServerAccount,
  type CodexAppServerModel,
  type CodexAppServerTurnInput,
} from '@deepseek-ai/dsh-subagent-codex'
import type { AskUserQuestionAnswer, AskUserQuestionItem } from '@deepseek-ai/dsh-user-questions'
import { managedLaunchArgv } from './agent.ts'
import type { AcpHarnessConfigOption, AcpHarnessModelCatalog } from './agent.ts'
import { prepareHarnessProcess } from './process-authority.ts'
import { harnessStartupError, harnessStartupSignal } from './startup.ts'

type Phase = { kind: 'idle'; turn: number } | { kind: 'running'; turn: number; abort: AbortController }

/**
 * Resolve the private process boundary for one Codex authentication method.
 * @param runtimeDirectory - OpenFish-owned runtime root for the Harness Pack.
 * @param authMethod - Selected non-secret authentication method identity.
 * @returns Authentication-specific runtime directory.
 */
export function codexAuthenticationRuntimeDirectory(runtimeDirectory: string, authMethod?: string): string {
  const identity = authMethod ?? 'unselected'
  const digest = createHash('sha256').update(identity).digest('hex').slice(0, 24)
  return join(runtimeDirectory, 'authentication-profiles', digest)
}

/**
 * Resolve the private, authentication-specific Codex home owned by OpenFish.
 * @param runtimeDirectory - OpenFish-owned runtime root for the Harness Pack.
 * @param authMethod - Selected non-secret authentication method identity.
 * @returns Isolated Codex home directory.
 */
export function codexAuthenticationHome(runtimeDirectory: string, authMethod?: string): string {
  return join(codexAuthenticationRuntimeDirectory(runtimeDirectory, authMethod), 'codex-home')
}

/**
 * Prepare one isolated Codex account profile. Existing Codex login reuse copies
 * only `auth.json`; it never grants the Harness access to ambient Codex tasks,
 * config, logs, or session state.
 * @param runtimeDirectory - OpenFish-owned runtime root for the Harness Pack.
 * @param authMethod - Selected non-secret authentication method identity.
 * @param importExistingLogin - Whether to copy the ambient Codex login into the isolated profile.
 * @returns Private Codex home prepared for the selected authentication method.
 */
export async function prepareCodexAuthenticationHome(
  runtimeDirectory: string,
  authMethod?: string,
  importExistingLogin = false,
): Promise<string> {
  const home = codexAuthenticationHome(runtimeDirectory, authMethod)
  await mkdir(home, { recursive: true, mode: 0o700 })
  await chmod(home, 0o700)
  if (!importExistingLogin) return home

  const destination = join(home, 'auth.json')
  let destinationInfo: Awaited<ReturnType<typeof lstat>> | undefined
  try {
    destinationInfo = await lstat(destination)
    if (!destinationInfo.isFile()) throw new Error('OpenFish Codex account profile contains an invalid auth.json entry')
  } catch (error: unknown) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
  }

  const source = join(homedir(), '.codex', 'auth.json')
  // O_NOFOLLOW closes the lstat/read race: "reuse existing login" can import
  // exactly the regular auth file, never an arbitrary symlink target.
  const sourceHandle = await open(source, constants.O_RDONLY | constants.O_NOFOLLOW)
  let sourceInfo: Awaited<ReturnType<typeof sourceHandle.stat>>
  let bytes: Buffer
  try {
    sourceInfo = await sourceHandle.stat()
    if (!sourceInfo.isFile() || sourceInfo.size <= 0 || sourceInfo.size > 1024 * 1024) {
      throw new Error('The existing Codex login is not a regular auth.json file within the supported size limit')
    }
    bytes = await sourceHandle.readFile()
  } finally {
    await sourceHandle.close()
  }
  try {
    const parsed = JSON.parse(bytes.toString('utf8')) as unknown
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) throw new Error('not an object')
  } catch (error: unknown) {
    throw new Error('The existing Codex auth.json is not valid JSON', { cause: error })
  }
  // A private profile may have refreshed its own token after the last import.
  // Refresh only when the user has since changed the ambient Codex login.
  if (destinationInfo !== undefined && destinationInfo.mtimeMs >= sourceInfo.mtimeMs) return home
  const temporary = join(home, `.auth.json.importing-${randomUUID()}`)
  try {
    await writeFile(temporary, bytes, { mode: 0o600, flag: 'wx' })
    await rename(temporary, destination)
    await chmod(destination, 0o600)
  } finally {
    await rm(temporary, { force: true }).catch(() => undefined)
  }
  return home
}

/** Persistent Harness Agent driven by Codex's official app-server protocol. */
export class CodexHarnessAgent implements Agent {
  readonly options: AgentOptions
  readonly inbox: Inbox
  readonly sandboxAuthority: SandboxAuthorityController
  readonly ctx: Context
  private readonly scope: Scope
  private readonly dispatch: AgentEventDispatch
  private phase: Phase
  private activity: Promise<void> = Promise.resolve()
  private process: SubprocessHandle | undefined
  private wire: CodexAppServerWire | undefined
  private remoteThreadId: string | undefined
  private models: CodexAppServerModel[] = []
  private account: CodexAppServerAccount | undefined
  private selectedModel: string | undefined
  private selectedEffort: string | undefined
  private maintenanceAbort: AbortController | undefined
  private processSandboxMode: SandboxMode

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
   * Launch the official Codex app-server and create or resume its durable thread.
   * @param resumeThreadId - Persisted Codex thread identity; absent creates a thread.
   * @param sandboxMode - Process sandbox policy applied before launching Codex.
   * @param signal - Optional cancellation for startup and protocol discovery.
   */
  async start(
    resumeThreadId?: string,
    sandboxMode = this.processSandboxMode,
    signal?: AbortSignal,
  ): Promise<void> {
    const startup = harnessStartupSignal(signal)
    startup.throwIfAborted()
    const { argv, env } = await managedLaunchArgv(this.pack, this.installationDirectory)
    const authEnv = await this.authenticationEnvironment()
    const codexHome = await prepareCodexAuthenticationHome(
      this.runtimeDirectory,
      this.preferredAuthMethod,
      this.preferredAuthMethod === 'codex-local-login',
    )
    const processRuntimeDirectory = codexAuthenticationRuntimeDirectory(
      this.runtimeDirectory,
      this.preferredAuthMethod,
    )
    const launch = await prepareHarnessProcess(this.hostCtx, {
      argv,
      cwd: this.session.header.cwd ?? process.cwd(),
      installationDirectory: this.installationDirectory,
      runtimeDirectory: processRuntimeDirectory,
      purpose: 'session',
      session: this.session,
      sandboxMode,
      env: {
        ...env,
        ...authEnv,
        CODEX_HOME: codexHome,
      },
    })
    const child = this.hostCtx.subprocess.spawn({
      argv: launch.argv,
      cwd: this.session.header.cwd ?? process.cwd(),
      env: launch.env,
      stdio: { stdin: 'pipe', stdout: 'pipe', stderr: { maxBytes: 64 * 1024 } },
      graceMs: 3_000,
    })
    if (child.stdin === undefined || child.stdout === undefined) {
      child.terminate()
      throw new Error('Codex app-server did not expose protocol pipes')
    }
    this.process = child
    const wire = new CodexAppServerWire(child.stdout, child.stdin, 'never', {
      clientInfo: { name: 'openfish', title: 'OpenFish', version: '0.1.0' },
      approval: async (kind) => {
        const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
        this.observe('approval.requested', 'active', `${kind} approval requested`)
        const outcome = await this.hostCtx.approval.request({
          agent: this,
          toolName: kind === 'command' ? 'Codex command' : 'Codex file change',
          reason: 'Requested by the Codex Harness',
          ...(signal === undefined ? {} : { signal }),
        })
        this.observe('approval.resolved', 'completed', outcome)
        return outcome === 'allowed-once' ? 'accept' : 'decline'
      },
      userInput: params => this.answerCodexUserInput(params),
      mcpElicitation: params => this.answerCodexMcpElicitation(params),
      notification: (method, params) => {
        if (this.session.events.findLast(event => event.type === 'harness/selected') !== undefined) {
          this.session.append('harness/native-event', { harnessId: this.pack.id, event: { method, params } })
        }
        if (method.startsWith('item/')) this.observe(codexItemSignal(method, params), 'active', method)
      },
    })
    this.wire = wire
    try {
      wire.start()
      await wire.initialize(startup)
      // account/read is authoritative on current app-server releases, but an
      // older compatible Codex may not implement it yet. Account explanation
      // is supplementary product metadata: never make an otherwise usable
      // Harness fail to start because that optional method is unavailable.
      this.account = await wire.readAccount(startup).catch(() => undefined)
      this.models = await wire.listModels(startup)
      const preferred = this.models.find(model => model.isDefault) ?? this.models[0]
      if (resumeThreadId === undefined) {
        this.selectedModel = preferred?.id
        this.selectedEffort = preferred?.defaultReasoningEffort
        this.remoteThreadId = await wire.startDurableThread(this.session.header.cwd ?? process.cwd(), startup)
      } else {
        const retained = await wire.resumeThread(resumeThreadId, this.session.header.cwd ?? process.cwd(), startup)
        this.selectedModel = retained.model
        this.selectedEffort = retained.reasoningEffort
        this.remoteThreadId = resumeThreadId
      }
      this.processSandboxMode = sandboxMode
    } catch (error: unknown) {
      await this.disposeProcess()
      if (startup.aborted) throw harnessStartupError('Codex Harness', startup, error)
      throw new Error(`Codex Harness failed to start: ${error instanceof Error ? error.message : String(error)}`, { cause: error })
    }
  }

  private async authenticationEnvironment(): Promise<Record<string, string>> {
    const method = this.pack.authMethods?.find(candidate => candidate.id === this.preferredAuthMethod)
    if (method === undefined || method.kind !== 'environment') return {}
    const environment: Record<string, string> = {}
    for (const field of method.fields) {
      const hit = await this.hostCtx.credentials.resolve(credentialRef(field.ref))
      if (field.required && hit === undefined) throw new Error(`Authentication needs ${field.name}`)
      if (hit !== undefined && field.env !== undefined) environment[field.env] = hit.value
    }
    return environment
  }

  /** Commit the exact live Codex identity and capabilities into the local task transcript. */
  commitSelection(): void {
    if (this.remoteThreadId === undefined) throw new Error('Codex Harness thread is not ready')
    const existing = this.session.events.findLast(event => event.type === 'harness/selected')
    if (existing === undefined) {
      this.session.append('harness/selected', {
        harnessId: this.pack.id, version: this.pack.version,
        protocol: this.pack.protocol,
        ...(this.preferredAuthMethod === undefined ? {} : { authMethod: this.preferredAuthMethod }),
        ...(this.workspaceMode === undefined ? {} : { workspaceMode: this.workspaceMode }),
        capabilities: this.capabilities,
        remoteSessionId: this.remoteThreadId,
      })
    } else {
      if (existing.data.harnessId !== this.pack.id || existing.data.version !== this.pack.version
        || existing.data.protocol !== this.pack.protocol
        || existing.data.authMethod !== this.preferredAuthMethod
        || existing.data.workspaceMode !== this.workspaceMode) {
        throw new Error('Cannot recover Codex under a different pinned Harness identity')
      }
      const currentRemote = this.session.events.findLast(event => event.type === 'harness/remote-session')
        ?.data.remoteSessionId ?? existing.data.remoteSessionId
      if (currentRemote !== this.remoteThreadId) {
        this.session.append('harness/remote-session', {
          harnessId: this.pack.id,
          remoteSessionId: this.remoteThreadId,
          reason: 'blank-session-recovery',
        })
      }
    }
    this.observe('protocol.ready', 'completed', 'Codex app-server initialized')
    this.observe('session.ready', 'waiting', 'Codex thread ready')
  }

  /**
   * Project the authoritative model surface discovered from the live Codex app-server.
   * @returns Live Codex models, reasoning efforts, selection, and non-secret account description.
   */
  harnessModelCatalog(): AcpHarnessModelCatalog | undefined {
    const current = this.selectedModel ?? (this.models.find(model => model.isDefault) ?? this.models[0])?.id
    if (current === undefined) return undefined
    return {
      current,
      ...(this.selectedEffort === undefined ? {} : { currentReasoningEffort: this.selectedEffort }),
      ...(this.account === undefined ? {} : { account: codexAccountDescriptor(this.account) }),
      models: this.models.map(model => ({
        id: model.id,
        name: model.displayName,
        providerId: 'openai',
        providerName: 'OpenAI',
        ...(model.description === undefined ? {} : { description: model.description }),
        ...(model.supportedReasoningEfforts.length === 0 ? {} : {
          reasoning: {
            efforts: model.supportedReasoningEfforts.map(effort => ({
              id: effort.reasoningEffort,
              name: effort.reasoningEffort.replaceAll('-', ' ').replace(/\b\w/gu, value => value.toUpperCase()),
              ...(effort.description === undefined ? {} : { description: effort.description }),
            })),
            ...(model.defaultReasoningEffort === undefined ? {} : { defaultEffort: model.defaultReasoningEffort }),
          },
        }),
      })),
    }
  }

  /**
   * Project the Codex-specific configuration surface exposed through Driver API v1.
   * @returns Empty configuration catalog because Driver API v1 exposes no Codex-specific options.
   */
  harnessConfigCatalog(): AcpHarnessConfigOption[] { return [] }

  /**
   * Reject unsupported Codex configuration mutations through Driver API v1.
   * @param configId - Requested configuration identity.
   * @param _value - Requested configuration value.
   * @param signal - Optional cancellation checked before rejection.
   * @returns Never resolves because Codex advertises no configuration options.
   */
  selectHarnessConfig(
    configId: string,
    _value: string | boolean,
    signal?: AbortSignal,
  ): Promise<AcpHarnessConfigOption[]> {
    signal?.throwIfAborted()
    throw new Error(`Codex Harness does not expose configuration option "${configId}" through Driver API v1`)
  }

  /**
   * Stage a model and reasoning effort advertised by the live Codex app-server.
   * @param model - Live Codex model identity.
   * @param reasoningEffort - Optional effort advertised for the selected model.
   * @param signal - Optional cancellation checked around local selection.
   * @returns Authoritative staged selection used by the next turn.
   */
  selectHarnessModel(
    model: string,
    reasoningEffort?: string,
    signal?: AbortSignal,
  ): Promise<{ model: string; reasoningEffort?: string }> {
    signal?.throwIfAborted()
    const option = this.models.find(candidate => candidate.id === model)
    if (option === undefined) throw new Error(`Codex does not advertise model "${model}"`)
    if (reasoningEffort !== undefined
      && !option.supportedReasoningEfforts.some(candidate => candidate.reasoningEffort === reasoningEffort)) {
      throw new Error(`Codex model "${model}" does not advertise reasoning effort "${reasoningEffort}"`)
    }
    signal?.throwIfAborted()
    this.selectedModel = model
    this.selectedEffort = reasoningEffort ?? option.defaultReasoningEffort
    return Promise.resolve({
      model,
      ...(this.selectedEffort === undefined ? {} : { reasoningEffort: this.selectedEffort }),
    })
  }

  /**
   * Ask the official app-server to copy history through one exact remote turn.
   * @param lastTurnId - Provider turn identity that bounds the forked history.
   * @returns New durable Codex thread identity.
   */
  async forkRemoteThread(lastTurnId: string): Promise<string> {
    const wire = this.wire
    if (wire === undefined) throw new Error('Codex app-server is not ready')
    return await wire.forkThread(
      this.session.header.cwd ?? process.cwd(),
      lastTurnId,
      AbortSignal.timeout(30_000),
    )
  }

  /**
   * Remove an unpublished remote child after local fork publication fails.
   * @param threadId - Exact Codex thread identity to delete.
   */
  async deleteRemoteThread(threadId: string): Promise<void> {
    const wire = this.wire
    if (wire === undefined) return
    await wire.deleteThread(threadId, AbortSignal.timeout(10_000))
  }

  /** Delete the provider-side identity allocated for a never-started draft. */
  async deleteCurrentRemoteThread(): Promise<void> {
    const threadId = this.remoteThreadId
    if (threadId === undefined) return
    await this.deleteRemoteThread(threadId)
    this.remoteThreadId = undefined
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
      this.wire?.interrupt()
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

  /** Replace the resident Codex process before the durable permission facts change. */
  private reconfigureSandbox(mode: SandboxMode): Promise<void> {
    if (mode === this.processSandboxMode) return Promise.resolve()
    return this.runMaintenance(async () => {
      const remoteThreadId = this.remoteThreadId
      if (remoteThreadId === undefined) throw new Error('Codex has no resumable thread identity')
      const previous = this.processSandboxMode
      await this.disposeProcess()
      try {
        await this.start(remoteThreadId, mode)
      } catch (error: unknown) {
        try {
          await this.start(remoteThreadId, previous)
        } catch (rollbackError: unknown) {
          throw new AggregateError(
            [error, rollbackError],
            'Codex could not change access mode and its previous process could not be restored',
          )
        }
        throw error
      }
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
    this.observe('turn.started', 'active', `Turn ${turn} started`)
    try {
      const messages = [...this.inbox.claim('next-turn', turn), ...this.inbox.claim('next-step', turn)]
      if (messages.length === 0) return
      this.session.append('step/start', { turn, step: 1 })
      stepStarted = true
      for (const message of messages) this.session.append('user/message', message, { surfaceOp: 'append' })
      const inputs = await this.codexTurnInputs(messages, running.abort.signal)
      if (inputs.length === 0) throw new Error('Codex Harness accepts text and image prompt content')
      const wire = this.wire
      if (wire === undefined) throw new Error('Codex app-server is not ready')
      const result = await wire.runTurn(inputs, running.abort.signal, {
        ...(this.selectedModel === undefined ? {} : { model: this.selectedModel }),
        ...(this.selectedEffort === undefined ? {} : { effort: this.selectedEffort }),
      })
      if (result.output.length > 0) {
        this.session.append('assistant/message', {
          turn, step: 1,
          message: createAssistantMessage({
            content: result.output,
            source: { provider: 'harness', model: this.selectedModel ?? this.pack.id },
          }),
        }, { surfaceOp: 'append' })
      }
      this.observe('model.completed', 'completed', `Turn ${turn} completed`)
    } catch (error: unknown) {
      if (running.abort.signal.aborted) reason = { kind: 'aborted', reason: running.abort.signal.reason as AgentCancelCause }
      else reason = { kind: 'error', error: { code: 'CODEX_APP_SERVER_ERROR', message: error instanceof Error ? error.message : String(error) } }
      this.observe('turn.failed', 'failed', `Turn ${turn} failed`)
      throw error
    } finally {
      if (stepStarted) this.session.append('step/end', { turn, step: 1 })
      this.session.append('turn/end', { turn, reason })
      if (reason.kind !== 'error') this.observe('turn.completed', 'waiting', `Turn ${turn} finished`)
    }
  }

  private async codexTurnInputs(messages: readonly UserMessage[], signal: AbortSignal): Promise<CodexAppServerTurnInput[]> {
    const inputs: CodexAppServerTurnInput[] = []
    for (const message of messages) {
      for (const block of message.content) {
        signal.throwIfAborted()
        if (block.type === 'text') {
          inputs.push({ type: 'text', text: block.text, text_elements: [] })
          continue
        }
        if (block.type === 'image') {
          const stored = await this.hostCtx.attachments.readImage(block.attachment, signal)
          const encoded = Buffer.from(stored.data).toString('base64')
          inputs.push({
            type: 'image',
            url: `data:${stored.ref.mediaType};base64,${encoded}`,
            detail: 'auto',
          })
        }
      }
    }
    return inputs
  }

  private async answerCodexUserInput(params: Readonly<Record<string, unknown>>): Promise<Record<string, unknown>> {
    const rows = Array.isArray(params.questions) ? params.questions : []
    if (rows.length === 0 || rows.length > 32) return { answers: {} }
    const questions: AskUserQuestionItem[] = []
    const secretIds = new Set<string>()
    for (const raw of rows) {
      const row = codexObject(raw)
      const id = codexString(row.id)
      const question = codexString(row.question)
      if (id === undefined || question === undefined || id.length > 256 || question.length > 10_000) {
        return { answers: {} }
      }
      if (row.isSecret === true) {
        secretIds.add(id)
        continue
      }
      const options = Array.isArray(row.options)
        ? row.options.slice(0, 100).flatMap((rawOption) => {
          const option = codexObject(rawOption)
          const label = codexString(option.label)
          if (label === undefined || label.length > 512) return []
          const description = codexString(option.description)
          return [{ label, ...(description === undefined ? {} : { description }) }]
        })
        : []
      const header = codexString(row.header)
      questions.push({
        id,
        question,
        ...(header === undefined ? {} : { header }),
        ...(options.length === 0 ? {} : { options }),
      })
    }
    const response: Record<string, { answers: string[] }> = {}
    for (const id of secretIds) response[id] = { answers: [] }
    if (questions.length === 0) return { answers: response }
    const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
    let answer: AskUserQuestionAnswer
    try {
      answer = await this.hostCtx.userQuestions.ask({ questions, agent: this, ...(signal === undefined ? {} : { signal }) })
    } catch {
      return { answers: response }
    }
    for (const item of answer.answers) {
      const values = [...item.selected]
      if (item.custom !== undefined && item.custom.trim() !== '') values.push(item.custom)
      response[item.id] = { answers: values }
    }
    return { answers: response }
  }

  private async answerCodexMcpElicitation(params: Readonly<Record<string, unknown>>): Promise<Record<string, unknown>> {
    if (params.mode !== 'form') return { action: 'decline', content: null }
    const schema = codexObject(params.requestedSchema)
    const properties = Object.entries(codexObject(schema.properties))
    if (properties.length === 0 || properties.length > 32) return { action: 'decline', content: null }
    const required = new Set(Array.isArray(schema.required) ? schema.required.filter((value): value is string => typeof value === 'string') : [])
    const questions: AskUserQuestionItem[] = []
    const fields = new Map<string, { type: string; required: boolean; values: Map<string, unknown>; schema: Record<string, unknown> }>()
    for (const [id, rawField] of properties) {
      const field = codexObject(rawField)
      const type = codexString(field.type)
      if (id.length === 0 || id.length > 256 || type === undefined) return { action: 'decline', content: null }
      const format = codexString(field.format)?.toLowerCase()
      // DSH's generic question surface intentionally has no secret text field.
      // Never downgrade a password/write-only MCP value into ordinary visible
      // task state; the server can retry through its own credential mechanism.
      if (format === 'password' || format === 'secret' || field.writeOnly === true || field['x-sensitive'] === true) {
        return { action: 'decline', content: null }
      }
      // JSON Schema patterns are arbitrary regular expressions. Driver API v1
      // does not execute untrusted regexes in the native client or Host.
      if (field.pattern !== undefined) return { action: 'decline', content: null }
      const isRequired = required.has(id)
      const choices = codexElicitationChoices(field)
      if (!isRequired) choices.push({ label: 'Skip this optional field', value: undefined })
      const values = new Map(choices.map(choice => [choice.label, choice.value]))
      const description = [codexString(params.message), codexString(field.description), isRequired ? undefined : 'Optional']
        .filter((value): value is string => value !== undefined && value !== '').join('\n\n')
      const header = codexString(params.serverName)
      questions.push({
        id,
        question: codexString(field.title) ?? id,
        ...(header === undefined ? {} : { header }),
        ...(description === '' ? {} : { detail: description }),
        ...(choices.length === 0 ? {} : { options: choices.map(choice => ({ label: choice.label })) }),
        ...(type === 'array' ? { multiSelect: true } : {}),
      })
      fields.set(id, { type, required: isRequired, values, schema: field })
    }
    const signal = this.phase.kind === 'running' ? this.phase.abort.signal : undefined
    let answer: AskUserQuestionAnswer
    try {
      answer = await this.hostCtx.userQuestions.ask({ questions, agent: this, ...(signal === undefined ? {} : { signal }) })
    } catch {
      return { action: 'cancel', content: null }
    }
    const byId = new Map(answer.answers.map(item => [item.id, item]))
    const content: Record<string, unknown> = {}
    for (const [id, field] of fields) {
      const item = byId.get(id)
      const selected = item?.selected.map(label => field.values.get(label)).filter(value => value !== undefined) ?? []
      let value: unknown
      if (field.type === 'array') {
        const customValues = item?.custom?.split(/\r?\n/u)
          .map(entry => entry.trim()).filter(entry => entry !== '') ?? []
        value = selected.length > 0 ? selected : customValues.length > 0 ? customValues : undefined
      }
      else if (field.type === 'boolean') value = selected[0]
      else if (field.type === 'number' || field.type === 'integer') {
        const number = Number(item?.custom)
        if (Number.isFinite(number) && (field.type !== 'integer' || Number.isInteger(number))) value = number
      } else value = selected[0] ?? item?.custom
      if (value === undefined) {
        if (field.required) return { action: 'decline', content: null }
        continue
      }
      if (typeof value === 'number') {
        const minimum = field.schema.minimum
        const maximum = field.schema.maximum
        if (typeof minimum === 'number' && value < minimum) return { action: 'decline', content: null }
        if (typeof maximum === 'number' && value > maximum) return { action: 'decline', content: null }
      }
      if (typeof value === 'string') {
        const minLength = field.schema.minLength
        const maxLength = field.schema.maxLength
        if (typeof minLength === 'number' && value.length < minLength) return { action: 'decline', content: null }
        if (typeof maxLength === 'number' && value.length > maxLength) return { action: 'decline', content: null }
      }
      if (Array.isArray(value)) {
        const minItems = field.schema.minItems
        const maxItems = field.schema.maxItems
        if (typeof minItems === 'number' && value.length < minItems) return { action: 'decline', content: null }
        if (typeof maxItems === 'number' && value.length > maxItems) return { action: 'decline', content: null }
      }
      content[id] = value
    }
    return { action: 'accept', content }
  }

  private observe(signal: HarnessRuntimeSignal, status: 'active' | 'waiting' | 'completed' | 'failed', activity: string): void {
    observeHarnessRuntime(this.session, this.pack, signal, status, activity)
  }

  /** Stop active work, release the scoped Agent, and terminate the Codex process. */
  async dispose(): Promise<void> {
    this.cancel({ kind: 'disposed' })
    await this.whenIdle()
    await this.scope.dispose()
    await this.disposeProcess()
  }

  private async disposeProcess(): Promise<void> {
    this.wire?.close()
    this.wire = undefined
    const child = this.process
    this.process = undefined
    if (child === undefined) return
    child.stdin?.end()
    const timeout = AbortSignal.timeout(1_000)
    if (!await child.waitForExit(timeout)) child.terminate()
    await child.waitForExit()
  }
}

function codexObject(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {}
}

function codexString(value: unknown): string | undefined {
  return typeof value === 'string' && value.length > 0 ? value : undefined
}

function codexElicitationChoices(field: Record<string, unknown>): Array<{ label: string; value: unknown }> {
  if (field.type === 'boolean') return [{ label: 'Yes', value: true }, { label: 'No', value: false }]
  const source = field.type === 'array' ? codexObject(field.items) : field
  let choices: Array<{ label: string; value: unknown }> = []
  for (const key of ['oneOf', 'anyOf'] as const) {
    if (!Array.isArray(source[key])) continue
    choices = source[key].flatMap((raw) => {
      const option = codexObject(raw)
      if (typeof option.const !== 'string') return []
      return [{ label: codexString(option.title) ?? option.const, value: option.const }]
    })
    if (choices.length > 0) break
  }
  if (choices.length === 0 && Array.isArray(source.enum)) {
    const names = Array.isArray(source.enumNames) ? source.enumNames : []
    choices = source.enum.flatMap((value, index) => typeof value === 'string'
      ? [{ label: typeof names[index] === 'string' ? names[index] : value, value }]
      : [])
  }
  const counts = new Map<string, number>()
  for (const choice of choices) counts.set(choice.label, (counts.get(choice.label) ?? 0) + 1)
  return choices.slice(0, 100).map(choice => ({
    ...choice,
    label: (counts.get(choice.label) ?? 0) > 1 ? `${choice.label} (${String(choice.value)})` : choice.label,
  }))
}

function codexAccountDescriptor(account: CodexAppServerAccount): NonNullable<AcpHarnessModelCatalog['account']> {
  if (account.type === 'chatgpt') {
    const plan = account.planType
      ?.replaceAll('-', ' ')
      .replace(/\b\w/gu, value => value.toUpperCase())
      ?? 'Plan Not Reported'
    return {
      label: `ChatGPT · ${plan}`,
      billing: 'subscription',
      detail: `The official Codex app-server reports ChatGPT authentication (${plan}). Requests use that Codex plan; OpenFish receives no token or email.`,
    }
  }
  if (account.type === 'apiKey' || account.type === 'apikey') {
    return {
      label: 'OpenAI API billing',
      billing: 'usage',
      detail: 'The official Codex app-server reports API-key authentication. Requests are billed to the OpenAI API project owning that credential.',
    }
  }
  if (account.type === 'amazonBedrock') {
    return {
      label: 'Amazon Bedrock through Codex',
      billing: 'usage',
      detail: 'The official Codex app-server reports an Amazon Bedrock route. Billing belongs to the configured AWS account.',
    }
  }
  return {
    label: `Codex account · ${account.type}`,
    billing: account.requiresOpenaiAuth ? 'harness-managed' : 'unknown',
    detail: 'The official Codex app-server reported this authentication route. OpenFish does not infer a subscription or billing owner beyond that response.',
  }
}

function codexItemSignal(method: string, params: unknown): HarnessRuntimeSignal {
  if (/(?:agent.?message|reasoning)/iu.test(method)) return 'output.activity'
  if (typeof params === 'object' && params !== null) {
    const item = (params as { item?: unknown }).item
    if (typeof item === 'object' && item !== null) {
      const type = (item as { type?: unknown }).type
      if (type === 'agentMessage' || type === 'reasoning') return 'output.activity'
    }
  }
  return 'tool.activity'
}

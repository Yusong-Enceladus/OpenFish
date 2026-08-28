/**
 * Minimal Codex app-server 0.150.1 protocol adapter. The shared JSON-RPC
 * transport owns framing and request correlation; this module owns only the
 * product methods, current thread/turn association, unattended approval
 * responses, and terminal-answer selection.
 *
 * @module @deepseek-ai/dsh-subagent-codex/wire
 */

import type { Readable, Writable } from 'node:stream'
import type { ContentBlock } from '@deepseek-ai/dsh-llm'
import type { SubagentResult } from '@deepseek-ai/dsh-subagent'
import { JsonRpcLineTransport } from '@deepseek-ai/dsh-sdk-protocol'
import type { CodexPermissionMode } from './run.ts'

type JsonObject = Record<string, unknown>
const MAXIMUM_EARLY_TURN_NOTIFICATIONS = 256

/** Product facts owned by the Codex wire after publication. */
export interface CodexWireFailureFacts {
  readonly stage: 'turn-start' | 'turn'
  readonly category:
    | 'limit'
    | 'access-policy'
    | 'service'
    | 'transport'
    | 'product-error'
    | 'invalid-result'
    | 'unknown'
  readonly httpStatus?: number | undefined
}

/** Live model metadata advertised by the official Codex app-server. */
export interface CodexAppServerModel {
  readonly id: string
  readonly displayName: string
  readonly description?: string
  readonly defaultReasoningEffort?: string
  readonly supportedReasoningEfforts: ReadonlyArray<{
    readonly reasoningEffort: string
    readonly description?: string
  }>
  readonly isDefault?: boolean
}

/** Model settings retained by a durable Codex thread when app-server reports them. */
export interface CodexAppServerThreadSelection {
  readonly model?: string
  readonly reasoningEffort?: string
}

/** Privacy-minimized billing identity reported by the official app-server. */
export interface CodexAppServerAccount {
  readonly type: string
  readonly planType?: string
  readonly requiresOpenaiAuth: boolean
}

/** User input accepted by the official v2 turn/start protocol. */
export type CodexAppServerTurnInput = string | {
  readonly type: 'text'
  readonly text: string
  readonly text_elements?: readonly never[]
} | {
  readonly type: 'image'
  readonly url: string
  readonly detail?: 'auto' | 'low' | 'high' | 'original' | null
} | {
  readonly type: 'localImage'
  readonly path: string
  readonly detail?: 'auto' | 'low' | 'high' | 'original' | null
}

/** Optional interactive hooks used when the wire powers a first-class UI. */
export interface CodexAppServerWireHooks {
  /** Public product identity reported to Codex compliance logs. */
  readonly clientInfo?: {
    readonly name: string
    readonly title: string
    readonly version: string
  }
  readonly approval?: (
    kind: 'command' | 'file',
    params: Readonly<JsonObject>,
  ) => Promise<'accept' | 'decline' | 'cancel'>
  readonly userInput?: (params: Readonly<JsonObject>) => Promise<JsonObject>
  readonly mcpElicitation?: (params: Readonly<JsonObject>) => Promise<JsonObject>
  readonly notification?: (method: string, params: Readonly<JsonObject>) => void
}

const THREAD_PERMISSION_PARAMS: Readonly<Record<CodexPermissionMode, JsonObject>> = {
  never: { approvalPolicy: 'never' },
  'approve-for-me': {
    approvalPolicy: 'on-request',
    approvalsReviewer: 'auto_review',
    sandbox: 'workspace-write',
  },
  'dangerously-bypass-approvals-and-sandbox': {
    approvalPolicy: 'never',
    sandbox: 'danger-full-access',
  },
}

function object(value: unknown, label: string): JsonObject {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error(`subagent-codex: app-server returned invalid ${label}`)
  }
  return value as JsonObject
}

function string(value: unknown, label: string): string {
  if (typeof value !== 'string' || value.length === 0 || Array.from(value).length > 4_096
    || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) {
    throw new Error(`subagent-codex: app-server returned invalid ${label}`)
  }
  return value
}

function boundedString(value: unknown, label: string, maximum = 2_048): string {
  const accepted = string(value, label)
  if (Array.from(accepted).length > maximum || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(accepted)) {
    throw new Error(`subagent-codex: app-server returned unbounded ${label}`)
  }
  return accepted
}

function boundedOptionalString(value: unknown, label: string, maximum = 2_048): string {
  if (typeof value !== 'string'
    || Array.from(value).length > maximum
    || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) {
    throw new Error(`subagent-codex: app-server returned invalid ${label}`)
  }
  return value
}

function unattendedDecision(params: JsonObject): 'cancel' | 'decline' {
  const available = params.availableDecisions
  if (available === undefined || available === null) return 'decline'
  if (Array.isArray(available)) {
    if (available.includes('cancel')) return 'cancel'
    if (available.includes('decline')) return 'decline'
  }
  throw new Error('subagent-codex: app-server offered no unattended approval decision')
}

function numericHttpStatus(value: unknown): number | undefined {
  return typeof value === 'number'
    && Number.isInteger(value)
    && value >= 0
    && value <= 65_535
    ? value
    : undefined
}

interface ParsedFailureInfo {
  readonly category: CodexWireFailureFacts['category']
  readonly httpStatus?: number | undefined
  readonly maxTokens?: true
  readonly sandboxFailure?: true
}

function objectFailureInfo(value: JsonObject): ParsedFailureInfo {
  const keys = Object.keys(value)
  const category = keys[0]
  if (keys.length !== 1 || category === undefined) {
    return { category: 'unknown' }
  }
  const detail = value[category]
  if (detail === null || typeof detail !== 'object' || Array.isArray(detail)) {
    return { category: 'unknown' }
  }
  const fields = detail as JsonObject
  switch (category) {
    case 'httpConnectionFailed':
    case 'responseStreamConnectionFailed':
    case 'responseStreamDisconnected':
    case 'responseTooManyFailedAttempts':
    {
      const httpStatus = numericHttpStatus(fields.httpStatusCode)
      return httpStatus === undefined
        ? { category: 'transport' }
        : { category: 'transport', httpStatus }
    }
    case 'activeTurnNotSteerable':
      return { category: 'product-error' }
    default:
      return { category: 'unknown' }
  }
}

function failureInfo(turn: JsonObject): ParsedFailureInfo {
  if (turn.status !== 'failed') return { category: 'unknown' }
  const error = turn.error
  if (error === null || typeof error !== 'object' || Array.isArray(error)) {
    return { category: 'unknown' }
  }
  const info = (error as JsonObject).codexErrorInfo
  if (typeof info === 'string') {
    switch (info) {
      case 'contextWindowExceeded':
        return { category: 'limit', maxTokens: true }
      case 'sessionBudgetExceeded':
      case 'usageLimitExceeded':
        return { category: 'limit' }
      case 'serverOverloaded':
      case 'internalServerError':
        return { category: 'service' }
      case 'cyberPolicy':
      case 'misalignmentPolicyViolation':
      case 'unauthorized':
        return { category: 'access-policy' }
      case 'badRequest':
      case 'threadRollbackFailed':
      case 'other':
        return { category: 'product-error' }
      case 'sandboxError':
        return { category: 'access-policy', sandboxFailure: true }
      default:
        return { category: 'unknown' }
    }
  }
  return info !== null && typeof info === 'object' && !Array.isArray(info)
    ? objectFailureInfo(info as JsonObject)
    : { category: 'unknown' }
}

function unattendedDiagnostic(
  mode: CodexPermissionMode,
  request: 'command approval' | 'file approval' | 'permission grant' | 'user input' | 'MCP elicitation' | 'command execution' | 'file change' | 'sandbox execution',
  decision: 'cancelled' | 'declined' | 'denied' | 'empty response' | 'failed',
  reason: string,
): string {
  return `Codex unattended decision (mode: ${mode}; request: ${request}; decision: ${decision}): ${reason}`
}

function thrown(value: unknown): Error {
  /* v8 ignore next -- typed protocol and stream failures reject with Error. */
  return value instanceof Error ? value : new Error(String(value))
}

function abortError(signal: AbortSignal): Error {
  return signal.reason instanceof Error
    ? signal.reason
    : new Error(`subagent-codex: app-server request aborted: ${String(signal.reason)}`)
}

async function raceAbort<T>(pending: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) {
    void pending.catch(() => {})
    throw abortError(signal)
  }
  let rejectAbort!: (error: Error) => void
  const aborted = new Promise<never>((_resolve, reject) => { rejectAbort = reject })
  const onAbort = (): void => { rejectAbort(abortError(signal)) }
  signal.addEventListener('abort', onAbort, { once: true })
  try {
    return await Promise.race([pending, aborted])
  } finally {
    signal.removeEventListener('abort', onAbort)
  }
}

/**
 * One app-server connection and its single ephemeral thread/turn.
 *
 * The class deliberately exposes no generic request surface. Supporting
 * another product method must first become part of the provider contract.
 */
export class CodexAppServerWire {
  private readonly transport: JsonRpcLineTransport
  private readonly fatal = Promise.withResolvers<never>()
  private threadId: string | undefined
  private turnId: string | undefined
  private pendingTurnId: string | undefined
  private turnCompleted: PromiseWithResolvers<{
    readonly params: JsonObject
    readonly order: number
  }> | undefined
  private readonly earlyTurnNotifications: Array<{
    readonly method: string
    readonly params: JsonObject
    readonly order: number
  }> = []
  private lastFinalAnswer: string | undefined
  private lastUnphasedAnswer: string | undefined
  private diagnostic: string | undefined
  private failure: CodexWireFailureFacts | undefined
  private diagnosticOrder = 0
  private observationOrder = 0
  private pendingDiagnostic: {
    readonly order: number
    readonly request: Parameters<typeof unattendedDiagnostic>[1]
    readonly decision: Parameters<typeof unattendedDiagnostic>[2]
    readonly reason: string
  } | undefined
  private inputEnded = false
  private terminalObserved = false
  private closed = false
  private readonly model: string | undefined
  private readonly hooks: CodexAppServerWireHooks

  constructor(
    private readonly input: Readable,
    output: Writable,
    private readonly permissionMode: CodexPermissionMode,
    modelOrHooks?: string | CodexAppServerWireHooks,
    hooks: CodexAppServerWireHooks = {},
  ) {
    this.model = typeof modelOrHooks === 'string' ? modelOrHooks : undefined
    this.hooks = typeof modelOrHooks === 'string' ? hooks : modelOrHooks ?? hooks
    this.transport = new JsonRpcLineTransport(input, output)
    // Fatal protocol state can arrive after the current guarded operation has
    // already settled. Keep the shared rejection observed without inserting
    // another promise-adoption hop into active races.
    void this.fatal.promise.catch(() => {})
    this.transport.onRequest((method, params) => this.handleServerRequest(method, params))
    this.transport.onNotification((method, params) => {
      try {
        this.handleNotification(method, params)
      } catch (error: unknown) {
        this.fail(thrown(error))
      }
    })
    this.input.on('error', this.onInputError)
    this.input.on('end', this.onInputEnd)
    // Pipe errors can race protocol closure and process teardown. Retain both
    // error listeners for the lifetime of their per-run streams so no late
    // EPIPE or read failure becomes an unhandled EventEmitter error.
    output.on('error', this.onOutputError)
  }

  /** Start reading app-server frames. */
  start(): void {
    this.transport.start()
  }

  /**
   * Whether protocol output ended before a terminal turn notification.
   * @returns `true` only for an early protocol close without a terminal turn.
   */
  endedBeforeTerminal(): boolean {
    return this.inputEnded && !this.terminalObserved
  }

  /**
   * Perform the required app-server initialize/initialized handshake.
   * @param signal - unpublished-start cancellation.
   */
  async initialize(signal: AbortSignal): Promise<void> {
    object(await this.guarded(this.transport.request('initialize', {
      clientInfo: this.hooks.clientInfo ?? {
        name: 'deepseek-harness',
        title: 'DeepSeek Harness',
        version: '0.0.1',
      },
      capabilities: {
        experimentalApi: false,
        requestAttestation: false,
      },
    }, signal), signal), 'initialize response')
    this.transport.notify('initialized')
    await this.guarded(this.transport.flush(), signal)
  }

  /**
   * Create the run's private ephemeral thread and retain its identity.
   * @param cwd - parent Session workspace.
   * @param signal - unpublished-start cancellation.
   */
  async startThread(cwd: string, signal: AbortSignal): Promise<void> {
    const response = object(await this.guarded(this.transport.request('thread/start', {
      cwd,
      ephemeral: true,
      ...this.model === undefined ? {} : { model: this.model },
      ...THREAD_PERMISSION_PARAMS[this.permissionMode],
    }, signal), signal), 'thread/start response')
    const thread = object(response.thread, 'thread/start thread')
    const id = string(thread.id, 'thread/start thread id')
    if (thread.ephemeral !== true) {
      throw new Error('subagent-codex: app-server did not create an ephemeral thread')
    }
    this.threadId = id
  }

  /**
   * Create a durable Codex thread for a first-class Harness session.
   * @param cwd - canonical workspace used by the remote thread.
   * @param signal - cancellation while the app-server creates the thread.
   * @returns the authoritative remote thread identity.
   */
  async startDurableThread(cwd: string, signal: AbortSignal): Promise<string> {
    const response = object(await this.guarded(this.transport.request('thread/start', {
      cwd,
      approvalPolicy: 'on-request',
      approvalsReviewer: 'user',
      sandbox: 'workspace-write',
    }, signal), signal), 'thread/start response')
    const thread = object(response.thread, 'thread/start thread')
    const id = string(thread.id, 'thread/start thread id')
    this.threadId = id
    return id
  }

  /**
   * Resume an existing durable Codex thread.
   * @param threadId - authoritative remote thread identity.
   * @param cwd - current canonical workspace for resumed execution.
   * @param signal - cancellation while the app-server resumes the thread.
   * @returns model and effort selected by the resumed remote thread.
   */
  async resumeThread(threadId: string, cwd: string, signal: AbortSignal): Promise<CodexAppServerThreadSelection> {
    const response = object(await this.guarded(this.transport.request('thread/resume', {
      threadId, cwd,
      approvalPolicy: 'on-request', approvalsReviewer: 'user', sandbox: 'workspace-write',
    }, signal), signal), 'thread/resume response')
    const thread = object(response.thread, 'thread/resume thread')
    this.threadId = string(thread.id, 'thread/resume thread id')
    return {
      ...(typeof thread.model === 'string' ? { model: thread.model } : {}),
      ...(typeof thread.reasoningEffort === 'string' ? { reasoningEffort: thread.reasoningEffort } : {}),
    }
  }

  /**
   * Create a durable server-owned branch without retargeting this connection's source thread.
   * @param cwd - canonical workspace for the new branch.
   * @param lastTurnId - source turn delimiting the branch point.
   * @param signal - cancellation while the app-server forks the thread.
   * @returns authoritative identity of the new remote thread.
   */
  async forkThread(cwd: string, lastTurnId: string, signal: AbortSignal): Promise<string> {
    if (this.threadId === undefined) throw new Error('subagent-codex: no source thread is active')
    const response = object(await this.guarded(this.transport.request('thread/fork', {
      threadId: this.threadId,
      lastTurnId,
      cwd,
      approvalPolicy: 'on-request', approvalsReviewer: 'user', sandbox: 'workspace-write',
    }, signal), signal), 'thread/fork response')
    const thread = object(response.thread, 'thread/fork thread')
    return string(thread.id, 'thread/fork thread id')
  }

  /**
   * Best-effort cleanup for a remote branch whose local child failed to publish.
   * @param threadId - remote thread identity to delete.
   * @param signal - cancellation while the app-server deletes the thread.
   */
  async deleteThread(threadId: string, signal: AbortSignal): Promise<void> {
    object(await this.guarded(this.transport.request('thread/delete', { threadId }, signal), signal), 'thread/delete response')
  }

  /**
   * Read the authoritative current Codex model and effort directory.
   * @param signal - cancellation while the catalog is fetched.
   * @returns model entries advertised by the running app-server.
   */
  async listModels(signal: AbortSignal): Promise<CodexAppServerModel[]> {
    const response = object(await this.guarded(this.transport.request('model/list', {
      includeHidden: false,
    }, signal), signal), 'model/list response')
    if (!Array.isArray(response.data) || response.data.length > 512) {
      throw new Error('subagent-codex: app-server returned invalid model/list data')
    }
    const models = response.data.map((raw): CodexAppServerModel => {
      const model = object(raw, 'model/list model')
      if (Array.isArray(model.supportedReasoningEfforts) && model.supportedReasoningEfforts.length > 32) {
        throw new Error('subagent-codex: app-server returned too many reasoning efforts')
      }
      const efforts = Array.isArray(model.supportedReasoningEfforts)
        ? model.supportedReasoningEfforts.map((rawEffort) => {
          const effort = object(rawEffort, 'model reasoning effort')
          return {
            reasoningEffort: boundedString(effort.reasoningEffort, 'model reasoning effort id', 128),
            ...(typeof effort.description === 'string'
              ? { description: boundedOptionalString(effort.description, 'model reasoning effort description') }
              : {}),
          }
        })
        : []
      const effortIds = efforts.map(effort => effort.reasoningEffort)
      if (new Set(effortIds).size !== effortIds.length) {
        throw new Error('subagent-codex: app-server returned duplicate model reasoning efforts')
      }
      const id = boundedString(model.id, 'model id', 256)
      const defaultReasoningEffort = typeof model.defaultReasoningEffort === 'string'
        ? boundedString(model.defaultReasoningEffort, 'default model reasoning effort', 128)
        : undefined
      if (defaultReasoningEffort !== undefined && !effortIds.includes(defaultReasoningEffort)) {
        throw new Error(`subagent-codex: app-server model "${id}" defaulted to an unadvertised reasoning effort`)
      }
      return {
        id,
        displayName: typeof model.displayName === 'string'
          ? boundedString(model.displayName, 'model display name', 256)
          : id,
        ...(typeof model.description === 'string'
          ? { description: boundedOptionalString(model.description, 'model description') }
          : {}),
        ...(defaultReasoningEffort === undefined ? {} : { defaultReasoningEffort }),
        supportedReasoningEfforts: efforts,
        ...(typeof model.isDefault === 'boolean' ? { isDefault: model.isDefault } : {}),
      }
    })
    const modelIds = models.map(model => model.id)
    if (new Set(modelIds).size !== modelIds.length || models.filter(model => model.isDefault === true).length > 1) {
      throw new Error('subagent-codex: app-server returned an ambiguous model directory')
    }
    return models
  }

  /**
   * Read the active Codex billing route without refreshing credentials.
   * Email and all credential material are deliberately discarded at the wire
   * boundary; OpenFish only needs auth mode and plan type to explain quota.
   * @param signal - cancellation while account metadata is fetched.
   * @returns redacted auth and plan facts, or undefined when signed out.
   */
  async readAccount(signal: AbortSignal): Promise<CodexAppServerAccount | undefined> {
    const response = object(await this.guarded(this.transport.request('account/read', {
      refreshToken: false,
    }, signal), signal), 'account/read response')
    if (response.account === null || response.account === undefined) return undefined
    const account = object(response.account, 'account/read account')
    return {
      type: boundedString(account.type, 'account type', 128),
      ...(typeof account.planType === 'string' && account.planType.length > 0
        ? { planType: boundedString(account.planType, 'account plan type', 128) }
        : {}),
      requiresOpenaiAuth: response.requiresOpenaiAuth === true,
    }
  }

  /**
   * Submit one text/image task and wait for this thread/turn's authoritative
   * terminal notification.
   * @param inputs - already validated task text or image blocks.
   * @param signal - local cancellation for the published run.
   * @param selection - optional model and reasoning effort for this turn.
   * @returns the shared subagent result.
   */
  async runTurn(
    inputs: readonly CodexAppServerTurnInput[],
    signal: AbortSignal,
    selection: { readonly model?: string; readonly effort?: string } = {},
  ): Promise<SubagentResult> {
    this.turnId = undefined
    this.pendingTurnId = undefined
    this.lastFinalAnswer = undefined
    this.lastUnphasedAnswer = undefined
    this.terminalObserved = false
    this.earlyTurnNotifications.length = 0
    const completion = Promise.withResolvers<{
      readonly params: JsonObject
      readonly order: number
    }>()
    this.turnCompleted = completion
    const threadId = this.threadId as string
    try {
      const response = object(await this.guarded(this.transport.request('turn/start', {
        threadId,
        input: inputs.map(input => typeof input === 'string'
          ? { type: 'text', text: input, text_elements: [] }
          : input.type === 'text' ? { ...input, text_elements: input.text_elements ?? [] } : input),
        ...(selection.model === undefined ? {} : { model: selection.model }),
        ...(selection.effort === undefined ? {} : { effort: selection.effort }),
      }, signal), signal), 'turn/start response')
      const turn = object(response.turn, 'turn/start turn')
      this.commitTurnId(string(turn.id, 'turn/start turn id'))
    } catch (error: unknown) {
      this.recordFailure({ stage: 'turn-start', category: 'unknown' })
      throw error
    }

    let completed: {
      readonly params: JsonObject
      readonly order: number
    }
    let terminal: JsonObject
    try {
      completed = await this.guarded(completion.promise, signal)
      terminal = object(completed.params.turn, 'turn/completed turn')
    } catch (error: unknown) {
      this.recordFailure({ stage: 'turn', category: 'unknown' })
      throw error
    }
    const status = terminal.status
    if (status !== 'completed') {
      const parsed = failureInfo(terminal)
      this.recordFailure(parsed.httpStatus === undefined
        ? { stage: 'turn', category: parsed.category }
        : {
          stage: 'turn',
          category: parsed.category,
          httpStatus: parsed.httpStatus,
        })
      if (parsed.sandboxFailure) {
        this.recordDiagnostic(
          'sandbox execution',
          'failed',
          'Codex reported a sandbox failure',
          completed.order,
        )
      }
      if (parsed.maxTokens) {
        return { output: this.collectOutput(), stopReason: 'max-tokens' }
      }
      const detail = status === 'failed' ? `: ${parsed.category}` : ''
      throw new Error(`subagent-codex: Codex turn ended with status ${String(status)}${detail}`)
    }
    const output = this.collectOutput()
    if (output.length === 0) {
      this.recordFailure({ stage: 'turn', category: 'invalid-result' })
      throw new Error('subagent-codex: Codex completed without a final answer')
    }
    return { output, stopReason: 'completed' }
  }

  /**
   * Best-effort remote cancellation. Local settlement and process teardown
   * remain authoritative when the child no longer accepts protocol requests.
   */
  interrupt(): void {
    if (this.threadId === undefined || this.turnId === undefined || this.closed) return
    void this.transport.request('turn/interrupt', {
      threadId: this.threadId,
      turnId: this.turnId,
    }).catch(() => {})
  }

  /**
   * The best non-commentary answer observed so far, preserving exact bytes.
   * @returns the selected final or nullable-phase text block, if any.
   */
  collectOutput(): ContentBlock[] {
    const selected = this.lastFinalAnswer ?? this.lastUnphasedAnswer
    return selected !== undefined && selected.trim().length > 0
      ? [{ type: 'text', text: selected }]
      : []
  }

  /**
   * The latest safe unattended permission fact observed for this run.
   * @returns provider-authored diagnostic text, when one was observed.
   */
  collectDiagnostic(): string | undefined {
    return this.diagnostic
  }

  /**
   * The structured failure fact observed for this published turn.
   * Call only after a non-completed return or rejection from {@link runTurn}.
   * @returns the fixed stage/category pair and optional HTTP status.
   */
  collectFailure(): CodexWireFailureFacts {
    return this.failure as CodexWireFailureFacts
  }

  /** Detach JSON-RPC listeners and reject outstanding requests. Idempotent. */
  close(): void {
    if (this.closed) return
    this.closed = true
    this.input.off('end', this.onInputEnd)
    this.transport.close()
  }

  private async guarded<T>(pending: Promise<T>, signal: AbortSignal): Promise<T> {
    const withFatal = Promise.race([this.fatal.promise, pending])
    return raceAbort(withFatal, signal)
  }

  private fail(error: Error): void {
    this.fatal.reject(error)
  }

  private readonly onInputError = (error: Error): void => {
    this.fail(error)
  }

  private readonly onOutputError = (error: Error): void => {
    this.fail(error)
  }

  private readonly onInputEnd = (): void => {
    this.inputEnded = true
    this.fail(new Error('subagent-codex: app-server protocol stream closed'))
  }

  private observePendingTurnId(id: string): void {
    if (this.turnCompleted === undefined) {
      throw new Error('subagent-codex: app-server referenced a turn before turn/start')
    }
    if (this.pendingTurnId !== undefined && this.pendingTurnId !== id) {
      throw new Error('subagent-codex: app-server referenced conflicting turns')
    }
    this.pendingTurnId = id
  }

  private commitTurnId(id: string): void {
    if (this.pendingTurnId !== undefined && this.pendingTurnId !== id) {
      throw new Error('subagent-codex: turn/start response did not match the active turn')
    }
    this.turnId = id
    const pendingDiagnostic = this.pendingDiagnostic
    this.pendingDiagnostic = undefined
    if (pendingDiagnostic !== undefined) {
      this.recordDiagnostic(
        pendingDiagnostic.request,
        pendingDiagnostic.decision,
        pendingDiagnostic.reason,
        pendingDiagnostic.order,
      )
    }
    const notifications = this.earlyTurnNotifications.splice(0)
    for (const notification of notifications) {
      this.handleNotification(
        notification.method,
        notification.params,
        notification.order,
      )
    }
  }

  /**
   * Validate the request's thread and turn association.
   * @returns `true` when the matching turn is still provisional, so the caller
   * defers its diagnostic until `commitTurnId()`.
   */
  private validateRunIds(
    params: JsonObject,
    nullableTurn = false,
  ): boolean {
    if (params.threadId !== this.threadId) {
      throw new Error('subagent-codex: app-server request referenced another thread')
    }
    if (nullableTurn && params.turnId === null) return false
    const id = string(params.turnId, 'server request turn id')
    if (this.turnId === undefined) {
      this.observePendingTurnId(id)
      return true
    }
    if (id !== this.turnId) {
      throw new Error('subagent-codex: app-server request referenced another turn')
    }
    return false
  }

  private recordRequestDiagnostic(
    provisional: boolean,
    request: Parameters<typeof unattendedDiagnostic>[1],
    decision: Parameters<typeof unattendedDiagnostic>[2],
    reason: string,
  ): void {
    const order = this.nextObservationOrder()
    if (provisional) {
      this.pendingDiagnostic = {
        order,
        request,
        decision,
        reason,
      }
      return
    }
    this.recordDiagnostic(request, decision, reason, order)
  }

  private recordDiagnostic(
    request: Parameters<typeof unattendedDiagnostic>[1],
    decision: Parameters<typeof unattendedDiagnostic>[2],
    reason: string,
    order = this.nextObservationOrder(),
  ): void {
    if (order < this.diagnosticOrder) return
    this.diagnosticOrder = order
    this.diagnostic = unattendedDiagnostic(
      this.permissionMode,
      request,
      decision,
      reason,
    )
  }

  private recordFailure(facts: CodexWireFailureFacts): void {
    this.failure = facts
  }

  private nextObservationOrder(): number {
    this.observationOrder += 1
    return this.observationOrder
  }

  private recordDeclinedItem(item: JsonObject, order?: number): boolean {
    if (item.type === 'commandExecution' && item.status === 'declined') {
      this.recordDiagnostic(
        'command execution',
        'declined',
        'Codex declined the command under the selected permission mode',
        order,
      )
      return true
    }
    if (item.type === 'fileChange' && item.status === 'declined') {
      this.recordDiagnostic(
        'file change',
        'declined',
        'Codex declined the file change under the selected permission mode',
        order,
      )
      return true
    }
    return false
  }

  private handleServerRequest(method: string, params: JsonObject): Promise<unknown> {
    try {
      switch (method) {
        case 'item/commandExecution/requestApproval':
        {
          const provisional = this.validateRunIds(params)
          if (this.hooks.approval !== undefined) return this.hooks.approval('command', params).then(decision => ({ decision }))
          const decision = unattendedDecision(params)
          this.recordRequestDiagnostic(
            provisional,
            'command approval',
            decision === 'cancel' ? 'cancelled' : 'declined',
            'the provider does not grant interactive approval',
          )
          return Promise.resolve({ decision })
        }
        case 'item/fileChange/requestApproval':
        {
          const provisional = this.validateRunIds(params)
          if (this.hooks.approval !== undefined) return this.hooks.approval('file', params).then(decision => ({ decision }))
          const decision = unattendedDecision(params)
          this.recordRequestDiagnostic(
            provisional,
            'file approval',
            decision === 'cancel' ? 'cancelled' : 'declined',
            'the provider does not grant interactive approval',
          )
          return Promise.resolve({ decision })
        }
        case 'item/permissions/requestApproval':
          this.recordRequestDiagnostic(
            this.validateRunIds(params),
            'permission grant',
            'denied',
            'the provider grants no additional turn permissions',
          )
          return Promise.resolve({ permissions: {}, scope: 'turn' })
        case 'item/tool/requestUserInput':
        {
          const provisional = this.validateRunIds(params)
          if (this.hooks.userInput !== undefined) return this.hooks.userInput(params)
          this.recordRequestDiagnostic(
            provisional,
            'user input',
            'empty response',
            'the provider does not collect interactive answers',
          )
          return Promise.resolve({ answers: {} })
        }
        case 'mcpServer/elicitation/request':
        {
          const provisional = this.validateRunIds(params, true)
          if (this.hooks.mcpElicitation !== undefined) return this.hooks.mcpElicitation(params)
          this.recordRequestDiagnostic(
            provisional,
            'MCP elicitation',
            'declined',
            'the provider does not collect interactive MCP input',
          )
          return Promise.resolve({ action: 'decline', content: null, _meta: null })
        }
        default:
          throw new Error(`subagent-codex: unsupported app-server request ${JSON.stringify(method)}`)
      }
    } catch (error: unknown) {
      const normalized = thrown(error)
      this.fail(normalized)
      return Promise.reject(normalized)
    }
  }

  private handleNotification(
    method: string,
    params: JsonObject,
    order?: number,
  ): void {
    boundedString(method, 'notification method', 256)
    this.hooks.notification?.(method, params)
    if (method === 'turn/started') {
      const threadId = string(params.threadId, 'turn/started thread id')
      if (threadId !== this.threadId) return
      const turn = object(params.turn, 'turn/started turn')
      if (this.turnCompleted !== undefined && this.turnId === undefined) {
        this.observePendingTurnId(string(turn.id, 'turn/started turn id'))
      }
      return
    }
    if (method === 'item/completed') {
      const threadId = string(params.threadId, 'item/completed thread id')
      if (threadId !== this.threadId) return
      const id = string(params.turnId, 'item/completed turn id')
      if (this.turnId === undefined) {
        if (this.turnCompleted !== undefined) {
          this.observePendingTurnId(id)
          if (this.earlyTurnNotifications.length >= MAXIMUM_EARLY_TURN_NOTIFICATIONS) {
            throw new Error('subagent-codex: app-server emitted too many early turn notifications')
          }
          this.earlyTurnNotifications.push({
            method,
            params,
            order: this.nextObservationOrder(),
          })
        }
        return
      }
      if (id !== this.turnId) return
      const item = object(params.item, 'item/completed item')
      if (this.recordDeclinedItem(item, order)) return
      if (item.type !== 'agentMessage') return
      const text = typeof item.text === 'string'
        ? item.text
        : (() => { throw new Error('subagent-codex: app-server returned an invalid agent message') })()
      if (item.phase === 'final_answer') {
        this.lastFinalAnswer = text
      } else if (item.phase === null) {
        this.lastUnphasedAnswer = text
      } else if (item.phase !== 'commentary') {
        throw new Error(`subagent-codex: app-server returned an unknown agent message phase ${JSON.stringify(item.phase)}`)
      }
      return
    }
    if (method !== 'turn/completed') return
    const threadId = string(params.threadId, 'turn/completed thread id')
    if (threadId !== this.threadId) return
    const turn = object(params.turn, 'turn/completed turn')
    const id = string(turn.id, 'turn/completed turn id')
    const turnCompleted = this.turnCompleted
    if (turnCompleted === undefined) return
    if (this.turnId === undefined) {
      this.observePendingTurnId(id)
      if (this.earlyTurnNotifications.length >= MAXIMUM_EARLY_TURN_NOTIFICATIONS) {
        throw new Error('subagent-codex: app-server emitted too many early turn notifications')
      }
      this.earlyTurnNotifications.push({
        method,
        params,
        order: this.nextObservationOrder(),
      })
      return
    }
    if (id !== this.turnId) return
    this.terminalObserved = true
    if (!['completed', 'interrupted', 'failed'].includes(String(turn.status))) {
      throw new Error(`subagent-codex: app-server returned invalid terminal turn status ${String(turn.status)}`)
    }
    turnCompleted.resolve({
      params,
      order: order ?? this.nextObservationOrder(),
    })
  }
}

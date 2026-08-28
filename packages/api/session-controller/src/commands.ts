/** Session commands whose activation policy is explicit at each Remote method. */

import { randomUUID } from 'node:crypto'
import { chmod, cp, lstat, mkdir, realpath, rm } from 'node:fs/promises'
import { dirname, join, resolve } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import type { Agent, ModelSelection as AgentModelSelection } from '@deepseek-ai/dsh-agent'
import { PresetMountError, UnknownPresetError } from '@deepseek-ai/dsh-agent-presets'
import { AttachmentError, admitEncodedImages } from '@deepseek-ai/dsh-attachment'
import type { ImageAttachmentRef } from '@deepseek-ai/dsh-attachment'
import {
  ReasoningEffortId, createUserMessage, freezeMessage,
} from '@deepseek-ai/dsh-llm'
import type { ContentBlock, MessageSource } from '@deepseek-ai/dsh-llm'
import {
  BUILTIN_DSH_VERSION,
  safeHarnessDiagnostic as safeClientDiagnostic,
  type HarnessId,
} from '@deepseek-ai/dsh-harness'
import type {} from '@deepseek-ai/dsh-harness'
import { SessionId } from '@deepseek-ai/dsh-session'
import type { SessionEvent, SessionHeader, UserMessage } from '@deepseek-ai/dsh-session'
import { SessionQueryError, type SessionObservation } from '@deepseek-ai/dsh-session-query'
import { SessionTitleInvalidError } from '@deepseek-ai/dsh-session-title'
import { TypertRemoteFailure } from '@deepseek-ai/dsh-typert-protocol'
import type { Workspace } from '@deepseek-ai/dsh-workspace'
import {
  ApiSessionAgentController,
  ApiSessionCwdConflict,
  ApiSessionNotFound,
  ApiSessionPresetConflict,
  ApiSessionSubagentOwnership,
  apiSessionSubagentOwnershipError,
  hasApiSessionSubagentOwner,
  inspectApiSession,
} from './agent.ts'
import { buildModelCatalog } from './catalog.ts'
import type {
  HarnessConfigOption,
  SessionAttachmentRequest,
  SessionAttachmentValue,
  SessionCancelRequest,
  SessionCancelValue,
  SessionCreateRequest,
  SessionCreateValue,
  SessionDiscardRequest,
  SessionDiscardValue,
  SessionForkRequest,
  SessionForkValue,
  SessionPromptRequest,
  SessionPromptValue,
  SessionRenameRequest,
  SessionRenameValue,
  SessionSelectModelRequest,
  SessionSelectModelValue,
  SessionModels,
  SessionModelsRequest,
  SessionSetHarnessConfigRequest,
  SessionSetHarnessConfigValue,
  SessionUpdateQueueRequest,
  SessionUpdateQueueValue,
} from './types.ts'

interface HarnessModelController {
  harnessModelCatalog(): {
    current: string
    currentReasoningEffort?: string
    models: SessionModels['groups'][number]['models']
    account?: SessionModels['account']
  } | undefined
  harnessConfigCatalog(): HarnessConfigOption[]
  selectHarnessModel(
    model: string,
    reasoningEffort?: string,
    signal?: AbortSignal,
  ): Promise<{ model: string; reasoningEffort?: string }>
  selectHarnessConfig(
    configId: string,
    value: string | boolean,
    signal?: AbortSignal,
  ): Promise<HarnessConfigOption[]>
}

function harnessModelController(agent: Agent): HarnessModelController | undefined {
  const candidate = agent as Agent & Partial<HarnessModelController>
  return typeof candidate.harnessModelCatalog === 'function'
    && typeof candidate.harnessConfigCatalog === 'function'
    && typeof candidate.selectHarnessModel === 'function'
    && typeof candidate.selectHarnessConfig === 'function'
    ? candidate as HarnessModelController
    : undefined
}

function runtimeAgentOptions(agent: Agent): Agent['options'] | undefined {
  return (agent as Omit<Agent, 'options'> & { readonly options?: Agent['options'] }).options
}

interface SessionReadState {
  readonly id: SessionId
  readonly header: SessionHeader
  readonly events: SessionEvent[]
}

/** Implements Session business commands delegated by the Session Controller Remote service. */
export class SessionCommandController {
  private readonly defaultSessionDirectory: string

  /**
   * @param ctx - Host context carrying Agent, model, attachment, title, and Workspace services.
   * @param agents - sole owner of create, resume, and Session-local model selection.
   * @param defaultSessionDirectory - private root used for first-class No Project tasks.
   */
  constructor(
    private readonly ctx: Context,
    private readonly agents: ApiSessionAgentController,
    defaultSessionDirectory: string,
  ) {
    this.defaultSessionDirectory = resolve(defaultSessionDirectory)
  }

  /**
   * Create or idempotently adopt one ordinary Session.
   * @param request - requested identity, location, and Agent preset.
   * @returns the Session identity and resolved preset when configured.
   */
  async create(request: SessionCreateRequest, signal?: AbortSignal): Promise<SessionCreateValue> {
    signal?.throwIfAborted()
    const locationCount = Number(request.workspaceId !== undefined)
      + Number(request.cwd !== undefined)
      + Number(request.noProject === true)
    if (locationCount > 1) {
      reject('bad-request', 'session.create accepts exactly one of workspaceId, cwd, or noProject', {})
    }
    const sessionId = request.sessionId ?? SessionId(`session-${randomUUID()}`)
    let workspace: Workspace | undefined
    if (request.workspaceId !== undefined) {
      workspace = this.ctx.workspaceRegistry.get(request.workspaceId)
      if (workspace === undefined) {
        reject('workspace-not-found', `workspace "${request.workspaceId}" not found`, {
          workspaceId: request.workspaceId,
        })
      }
    }
    const workspaceMode = workspace !== undefined
      ? 'project' as const
      : request.cwd !== undefined ? 'custom-cwd' as const : 'no-project' as const
    const harnesses = this.ctx.get('harnesses')
    const requestedHarness = request.harnessId
      ?? (harnesses === undefined ? 'dsh' : await harnesses.defaultId())
    if (requestedHarness === undefined) {
      reject(
        'harness-selection-required',
        'Choose a default Harness before creating the first task.',
        {},
      )
    }
    let createdNoProjectDirectory = false
    let cwd: string
    try {
      if (workspace?.path !== undefined) cwd = workspace.path
      else if (request.cwd !== undefined) cwd = request.cwd
      else {
        const prepared = await this.ensureNoProjectDirectory(sessionId)
        cwd = prepared.path
        createdNoProjectDirectory = prepared.created
      }
    } catch (error: unknown) {
      reject(
        'invalid-no-project-directory',
        `OpenFish could not prepare a private No Project directory: ${safeClientDiagnostic(error, 'directory preparation failed')}`,
        { sessionId },
      )
    }
    if (requestedHarness !== 'dsh' && request.agentPreset !== undefined) {
      reject('bad-request', 'Agent Presets apply only to the DSH Harness', {})
    }
    let adopted: Agent
    try {
      adopted = await this.agents.ensureSession(
        sessionId,
        cwd,
        request.sessionId !== undefined,
        request.agentPreset,
        requestedHarness,
        workspaceMode,
        signal,
      )
    } catch (error) {
      if (createdNoProjectDirectory) {
        await rm(this.noProjectDirectory(sessionId), { recursive: true, force: true }).catch(() => undefined)
      }
      this.rejectCreation(sessionId, error)
    }
    if (requestedHarness === 'dsh'
      && adopted.session.events.findLast(event => event.type === 'harness/selected') === undefined) {
      const capabilities = harnesses === undefined
        ? undefined
        : (await harnesses.describe('dsh' as HarnessId)).capabilities
      adopted.session.append('harness/selected', {
        harnessId: 'dsh' as HarnessId,
        version: BUILTIN_DSH_VERSION,
        protocol: 'dsh',
        workspaceMode,
        ...(capabilities === undefined ? {} : { capabilities: [...capabilities] }),
      })
    }
    if (workspace !== undefined) {
      try {
        await workspace.attachSession(sessionId)
      } catch (error) {
        let rollback: string | undefined
        try {
          await this.discard({ sessionId })
        } catch (cleanupError: unknown) {
          rollback = safeClientDiagnostic(cleanupError, 'draft cleanup failed')
        }
        reject(
          'workspace-attach-failed',
          rollback === undefined
            ? `session "${sessionId}" could not attach to workspace "${workspace.id}" and its blank draft was removed: ${safeClientDiagnostic(error, 'workspace attachment failed')}`
            : `session "${sessionId}" could not attach to workspace "${workspace.id}"; draft cleanup also failed: ${rollback}`,
          { sessionId, workspaceId: workspace.id },
        )
      }
    }
    const agentPreset = this.agents.presetForSession(adopted.session)
    return {
      sessionId,
      harnessId: adopted.session.events.findLast(event => event.type === 'harness/selected')?.data.harnessId
        ?? requestedHarness,
      ...(agentPreset === undefined ? {} : { agentPreset }),
    }
  }

  /** Permanently remove one never-started draft and its provider-side blank thread. */
  async discard(request: SessionDiscardRequest): Promise<SessionDiscardValue> {
    let agent = this.ctx.agents.get(request.sessionId)
    if (agent === undefined) {
      let inspected: Awaited<ReturnType<typeof inspectApiSession>>
      try {
        inspected = await inspectApiSession(this.ctx, request.sessionId)
      } catch (error: unknown) {
        if (error instanceof ApiSessionNotFound) {
          reject('session-not-found', error.message, { sessionId: request.sessionId })
        }
        reject('internal', `draft inspection failed: ${safeClientDiagnostic(error, 'draft inspection failed')}`, {})
      }
      if (inspected.events.some(event => event.type === 'turn/start')) {
        reject('agent-busy', `session "${request.sessionId}" has started and cannot be discarded`, {
          reason: 'only a conversation-not-started draft can be discarded',
        })
      }
      agent = await this.resolveAgent(request.sessionId)
    }
    if (agent.status !== 'idle' || agent.session.events.some(event => event.type === 'turn/start')) {
      reject('agent-busy', `session "${request.sessionId}" has started and cannot be discarded`, {
        reason: 'only an idle conversation-not-started draft can be discarded',
      })
    }
    const selected = agent.session.events.findLast(event => event.type === 'harness/selected')?.data
    const id = selected?.harnessId ?? 'dsh'
    const sessionCwd = agent.session.header.cwd
    try {
      if (id === 'dsh') {
        if (!await this.agents.disposeOwnedAgent(request.sessionId)) {
          throw new Error('the Session controller does not own this draft Agent')
        }
      } else {
        const harnesses = this.ctx.get('harnesses')
        if (harnesses === undefined) throw new Error('Harness service is not mounted')
        await harnesses.discardSession(id, request.sessionId, selected?.version)
      }
      for (const workspace of this.ctx.workspaceRegistry.list()) {
        if (workspace.sessionIds.includes(request.sessionId)) {
          await workspace.detachSession(request.sessionId)
        }
      }
      const persistence = this.ctx.get('sessionPersistence')
      if (persistence === undefined) throw new Error('session persistence is not configured')
      await persistence.delete(request.sessionId)
      const noProjectDirectory = this.noProjectDirectory(request.sessionId)
      if (sessionCwd === noProjectDirectory) {
        await rm(noProjectDirectory, { recursive: true, force: true })
      }
      return { discarded: true }
    } catch (error: unknown) {
      reject('internal', `could not discard draft session "${request.sessionId}": ${safeClientDiagnostic(error, 'draft cleanup failed')}`, {})
    }
  }

  /** Read the live model/reasoning/account/config directory for one exact task. */
  async models(request: SessionModelsRequest, signal?: AbortSignal): Promise<SessionModels> {
    signal?.throwIfAborted()
    const agent = await this.resolveAgent(request.sessionId)
    signal?.throwIfAborted()
    const current = this.agents.selectionFor(agent).current
    if (current.provider === 'harness') {
      const controller = harnessModelController(agent)
      const catalog = controller?.harnessModelCatalog()
      if (catalog !== undefined && catalog.models.length > 0) {
        return {
          current: {
            provider: 'harness',
            model: catalog.current,
            ...(catalog.currentReasoningEffort === undefined
              ? {}
              : { reasoningEffort: catalog.currentReasoningEffort }),
          },
          routable: true,
          groups: [{ id: 'harness', name: 'Harness models', models: catalog.models }],
          failures: [],
          ...(catalog.account === undefined ? {} : { account: catalog.account }),
          harnessOptions: controller?.harnessConfigCatalog() ?? [],
        }
      }
      let required = false
      let failure: string | undefined
      try {
        required = await this.harnessRequiresAdvertisedModel(agent)
      } catch (error: unknown) {
        required = true
        failure = `The selected Harness model contract could not be resolved: ${safeClientDiagnostic(error, 'model contract unavailable')}`
      }
      return {
        current: { ...current },
        routable: !required,
        groups: [],
        failures: required ? [{
          id: 'harness',
          name: 'Harness models',
          message: failure ?? 'This Harness requires a model, but its live runtime did not advertise any model choices.',
        }] : [],
        ...(catalog?.account === undefined ? {} : { account: catalog.account }),
        harnessOptions: controller?.harnessConfigCatalog() ?? [],
      }
    }
    const catalog = await buildModelCatalog(this.ctx)
    signal?.throwIfAborted()
    return {
      current: { ...current },
      routable: catalog.routableProviders.includes(current.provider),
      groups: catalog.groups,
      failures: catalog.failures,
    }
  }

  /**
   * Validate and install one Session-local model selection.
   * @param request - Session identity and requested model selection.
   * @returns the normalized selection installed for the Session.
   */
  async selectModel(
    request: SessionSelectModelRequest,
    signal?: AbortSignal,
  ): Promise<SessionSelectModelValue> {
    signal?.throwIfAborted()
    const agent = await this.resolveAgent(request.sessionId)
    const harnessController = harnessModelController(agent)
    if (runtimeAgentOptions(agent)?.provider === 'harness') {
      if (harnessController === undefined || request.provider !== 'harness') {
        reject(
          'model-unavailable',
          'This Harness accepts only its own live advertised model choices.',
          { provider: request.provider, model: request.model },
        )
      }
      return this.agents.serializeImageAdmission(agent, async () => {
        try {
          const selected = await harnessController.selectHarnessModel(
            request.model,
            request.reasoningEffort,
            signal,
          )
          signal?.throwIfAborted()
          const accepted: AgentModelSelection = {
            provider: 'harness',
            model: selected.model,
            ...(selected.reasoningEffort === undefined
              ? {}
              : { reasoningEffort: ReasoningEffortId(selected.reasoningEffort) }),
          }
          this.agents.selectForNextRequest(agent, accepted)
          return { selected: { ...accepted } }
        } catch (error: unknown) {
          // Model switches can succeed remotely before a later reasoning
          // mutation fails. Reconcile the live runtime so the pinned task does
          // not display a model it is no longer using.
          const live = harnessController.harnessModelCatalog()
          if (live !== undefined) {
            const reconciled: AgentModelSelection = {
              provider: 'harness',
              model: live.current,
              ...(live.currentReasoningEffort === undefined
                ? {}
                : { reasoningEffort: ReasoningEffortId(live.currentReasoningEffort) }),
            }
            const previous = this.agents.selectionFor(agent).current
            if (previous.provider !== reconciled.provider
              || previous.model !== reconciled.model
              || previous.reasoningEffort !== reconciled.reasoningEffort) {
              this.agents.selectForNextRequest(agent, reconciled)
            }
          }
          reject(
            'model-unavailable',
            safeClientDiagnostic(error, 'Harness model selection failed'),
            { provider: request.provider, model: request.model },
          )
        }
      })
    }
    return this.agents.serializeImageAdmission(agent, async () => {
      try {
        const resolved = await this.ctx.llm.resolveCallConfig({
          provider: request.provider,
          model: request.model,
          ...(request.reasoningEffort === undefined
            ? {}
            : { reasoningEffort: ReasoningEffortId(request.reasoningEffort) }),
        })
        signal?.throwIfAborted()
        const selected: AgentModelSelection = {
          provider: resolved.provider,
          model: resolved.model,
          ...(resolved.reasoningEffort === undefined
            ? {}
            : { reasoningEffort: resolved.reasoningEffort }),
        }
        this.agents.selectForNextRequest(agent, selected)
        try {
          await this.ctx.agentDefaultModel.saveSelection(selected)
        } catch (error) {
          this.ctx.logger.warn(
            `session-controller: model selection changed for the Session but the default was not saved: ${safeClientDiagnostic(error, 'default model persistence failed')}`,
          )
        }
        return { selected: { ...selected } }
      } catch (error) {
        if (error instanceof TypertRemoteFailure) throw error
        reject(
          'model-unavailable',
          safeClientDiagnostic(error, 'model selection failed'),
          { provider: request.provider, model: request.model },
        )
      }
    })
  }

  /** Mutate one configuration option owned by the live Harness session. */
  async setHarnessConfig(
    request: SessionSetHarnessConfigRequest,
    signal?: AbortSignal,
  ): Promise<SessionSetHarnessConfigValue> {
    signal?.throwIfAborted()
    const agent = await this.resolveAgent(request.sessionId)
    const controller = harnessModelController(agent)
    const options = runtimeAgentOptions(agent)
    if (options?.provider !== 'harness' || controller === undefined) {
      reject('model-unavailable', 'This session does not expose Harness configuration.', {
        provider: options?.provider ?? 'unknown',
        model: options?.model ?? 'unknown',
      })
    }
    return this.agents.serializeImageAdmission(agent, async () => {
      try {
        const selected = await controller.selectHarnessConfig(
          request.configId,
          request.value,
          signal,
        )
        signal?.throwIfAborted()
        return { options: selected }
      } catch (error: unknown) {
        if (signal?.aborted === true) reject('cancelled', 'Harness configuration was cancelled', {})
        reject(
          'model-unavailable',
          safeClientDiagnostic(error, 'Harness configuration failed'),
          { provider: 'harness', model: request.configId },
        )
      }
    })
  }

  /**
   * Normalize and append a user-owned Session title.
   * @param request - Session identity and proposed title.
   * @returns the accepted title and durable event sequence.
   */
  async rename(request: SessionRenameRequest): Promise<SessionRenameValue> {
    const agent = await this.resolveAgent(request.sessionId)
    const titles = this.ctx.get('sessionTitle')
    if (titles === undefined) {
      reject('internal', 'renaming is unavailable: this deployment mounts no session-title service', {})
    }
    try {
      const accepted = titles.rename(agent.session, request.title)
      return { title: accepted.title, seq: accepted.eventSeq }
    } catch (error) {
      if (error instanceof SessionTitleInvalidError) {
        reject('title-invalid', error.message, { sessionId: request.sessionId })
      }
      reject(
        'internal',
        `failed to rename session "${request.sessionId}": ${safeClientDiagnostic(error, 'rename failed')}`,
        {},
      )
    }
  }

  /**
   * Create a new ordinary Session from one completed-turn prefix.
   * @param request - source Session and optional event anchor.
   * @returns the new Session identity.
   */
  async fork(request: SessionForkRequest): Promise<SessionForkValue> {
    if (request.atSeq !== undefined
      && (!Number.isInteger(request.atSeq) || request.atSeq < 0)) {
      reject('bad-request', 'atSeq must be a non-negative integer', {})
    }
    let observed: SessionObservation
    try {
      observed = await this.ctx.sessionQuery.observeSession(request.sessionId)
    } catch (error) {
      if (error instanceof SessionQueryError
        && error.code === 'SESSION_QUERY_SESSION_NOT_FOUND') {
        reject('session-not-found', `session "${request.sessionId}" not found`, {
          sessionId: request.sessionId,
        })
      }
      reject(
        'internal',
        `fork source unavailable for session "${request.sessionId}": ${safeClientDiagnostic(error, 'source inspection failed')}`,
        {},
      )
    }
    using source = observed
    const lastSeq = source.events.at(-1)?.seq ?? -1
    const atSeq = request.atSeq
    const anchoredBoundary = atSeq === undefined
      ? undefined
      : source.events.find(event => event.type === 'turn/end' && event.seq >= atSeq)
    const boundary = anchoredBoundary
      ?? (atSeq === undefined || atSeq > lastSeq
        ? source.events.findLast(event => event.type === 'turn/end')
        : undefined)
    if (boundary === undefined) {
      reject(
        'fork-unavailable',
        atSeq !== undefined && atSeq <= lastSeq
          ? `session "${request.sessionId}" has not completed the turn containing event ${String(atSeq)}`
          : `session "${request.sessionId}" has no completed turn to fork from`,
        { sessionId: request.sessionId },
      )
    }
    let cut = boundary.seq + 1
    while (cut < source.events.length && source.events[cut]?.type !== 'turn/start') cut++
    let workspace: Workspace | undefined
    try {
      workspace = await this.forkWorkspace(source.header)
    } catch (error) {
      reject(
        'internal',
        `failed to resolve fork workspace for session "${request.sessionId}": ${safeClientDiagnostic(error, 'workspace resolution failed')}`,
        {},
      )
    }
    const childId = SessionId(`session-${randomUUID()}`)
    const selectedHarness = source.events.findLast(event => event.type === 'harness/selected')?.data
    const sourceWorkspaceMode = selectedHarness?.workspaceMode
      ?? (workspace !== undefined
        ? 'project'
        : this.isManagedNoProjectDirectory(source.header.cwd) ? 'no-project' : 'custom-cwd')
    let childCwd = source.header.cwd
    let removeChildDirectoryOnFailure = false
    if (sourceWorkspaceMode === 'no-project') {
      try {
        childCwd = await this.copyNoProjectDirectory(source.header.cwd, childId)
        removeChildDirectoryOnFailure = true
      } catch (error: unknown) {
        reject(
          'internal',
          `failed to prepare an isolated No Project directory for fork "${childId}": ${safeClientDiagnostic(error, 'directory preparation failed')}`,
          { sessionId: request.sessionId },
        )
      }
    }
    if (selectedHarness !== undefined && selectedHarness.harnessId !== 'dsh') {
      const harnesses = this.ctx.get('harnesses')
      if (harnesses === undefined) reject('internal', 'Harness service is not mounted', {})
      try {
        await harnesses.fork(
          selectedHarness.harnessId,
          source.header.id,
          childId,
          childCwd ?? this.defaultSessionDirectory,
          source.events.slice(0, cut),
          selectedHarness.version,
          selectedHarness.authMethod,
          selectedHarness.workspaceMode,
        )
      } catch (error: unknown) {
        if (removeChildDirectoryOnFailure) {
          await rm(this.noProjectDirectory(childId), { recursive: true, force: true }).catch(() => undefined)
        }
        reject(
          'fork-unavailable',
          safeClientDiagnostic(error, 'Harness fork failed'),
          { sessionId: request.sessionId },
        )
      }
      if (workspace !== undefined) {
        try {
          await workspace.attachSession(childId)
        } catch (error: unknown) {
          reject(
            'workspace-attach-failed',
            `session "${childId}" was forked but could not attach to workspace "${workspace.id}": ${safeClientDiagnostic(error, 'workspace attachment failed')}`,
            { sessionId: childId, workspaceId: workspace.id },
          )
        }
      }
      return { sessionId: childId }
    }
    const composition = await this.agents.composeAgent(this.agents.presetForObservation(source))
    try {
      const { provider, model } = this.ctx.agentDefaultModel.currentSelection()
      const handle = await this.ctx.agents.create({
        sessionId: childId,
        seed: source.events.slice(0, cut),
        meta: {
          ...(childCwd === undefined ? {} : { cwd: childCwd }),
          parentSession: source.header.id,
          seedLength: cut,
          ...(composition.agentPreset === undefined
            ? {}
            : { agentPreset: composition.agentPreset }),
        },
        agentOptions: { provider, model },
        setup: composition.setup,
      })
      this.agents.adoptOwnedAgent(handle)
    } catch (error) {
      if (removeChildDirectoryOnFailure) {
        await rm(this.noProjectDirectory(childId), { recursive: true, force: true }).catch(() => undefined)
      }
      reject(
        'internal',
        `failed to fork session "${request.sessionId}": ${safeClientDiagnostic(error, 'session fork failed')}`,
        {},
      )
    }
    if (workspace !== undefined) {
      try {
        await workspace.attachSession(childId)
      } catch (error) {
        reject(
          'workspace-attach-failed',
          `session "${childId}" was forked but could not attach to workspace "${workspace.id}": ${safeClientDiagnostic(error, 'workspace attachment failed')}`,
          { sessionId: childId, workspaceId: workspace.id },
        )
      }
    }
    return { sessionId: childId }
  }

  /**
   * Admit one browser prompt after explicit Agent resume and image validation.
   * @param request - Session identity, prompt content, source metadata, and delivery mode.
   * @returns acknowledgement that the Agent accepted the prompt.
   */
  async prompt(request: SessionPromptRequest): Promise<SessionPromptValue> {
    const clientTimeZone = request.clientTimeZone === undefined
      ? undefined
      : canonicalClientTimeZone(request.clientTimeZone)
    if (request.clientTimeZone !== undefined && clientTimeZone === undefined) {
      reject(
        'invalid-time-zone',
        'clientTimeZone must be UTC or a valid IANA Area/Location name',
        { value: request.clientTimeZone },
      )
    }
    const agent = await this.resolveAgent(request.sessionId)
    const selection = this.agents.selectionFor(agent).current
    if (selection.provider === 'harness') {
      const catalog = harnessModelController(agent)?.harnessModelCatalog()
      if ((catalog === undefined || catalog.models.length === 0)
        && await this.harnessRequiresAdvertisedModel(agent)) {
        reject(
          'model-unavailable',
          'This Harness requires a model, but its live runtime did not advertise any model choices.',
          { provider: selection.provider, model: selection.model },
        )
      }
    } else if (!routeServed(this.ctx, selection.provider)) {
      reject(
        'model-unavailable',
        `no adapter serves provider "${selection.provider}"; select a model for this session`,
        { provider: selection.provider, model: selection.model },
      )
    }
    const source: MessageSource = {
      kind: 'user',
      rpcId: request.requestId,
      ...(clientTimeZone === undefined ? {} : { clientTimeZone }),
    }
    const hasImage = request.content.some(part => part.type === 'image')
    const admit = async (): Promise<SessionPromptValue> => {
      try {
        if (hasImage && this.agents.selectionFor(agent).current.provider !== 'harness') {
          const current = this.agents.selectionFor(agent).current
          const model = await this.ctx.llm.resolveModelInfo(current.provider, current.model)
          if (model.inputModalities !== undefined && !model.inputModalities.includes('image')) {
            reject(
              'attachment-error',
              `Model "${current.model}" does not support image input.`,
              { reason: 'MODEL_DOES_NOT_SUPPORT_IMAGES' },
            )
          }
        }
        const content = await durablePromptContent(this.ctx, request.content)
        const message: UserMessage = createUserMessage({ content, source })
        if (request.mode === 'steer') agent.steer(message)
        else agent.followup(message)
      } catch (error) {
        if (error instanceof TypertRemoteFailure) throw error
        if (error instanceof AttachmentError) {
          reject('attachment-error', error.message, { reason: error.code })
        }
        reject('agent-busy', 'prompt rejected', { reason: safeClientDiagnostic(error, 'prompt admission failed') })
      }
      return { accepted: true }
    }
    return hasImage ? this.agents.serializeImageAdmission(agent, admit) : admit()
  }

  /**
   * Read one durable image after proving the Session log references it.
   * @param request - Session and attachment identities used for authorization.
   * @returns the durable attachment reference and base64-encoded bytes.
   */
  async attachment(request: SessionAttachmentRequest): Promise<SessionAttachmentValue> {
    let source: SessionReadState
    try {
      source = await this.readSessionState(request.sessionId)
    } catch (error) {
      if (error instanceof ApiSessionNotFound) {
        reject('session-not-found', error.message, { sessionId: request.sessionId })
      }
      reject(
        'internal',
        `attachment authorization unavailable for session "${request.sessionId}": ${safeClientDiagnostic(error, 'session inspection failed')}`,
        {},
      )
    }
    const ref = referencedImage(source.events, String(request.attachmentId))
    if (ref === undefined) {
      reject(
        'attachment-error',
        'Image is not referenced by this session.',
        { reason: 'ATTACHMENT_NOT_REFERENCED' },
      )
    }
    try {
      const stored = await this.ctx.attachments.readImage(ref)
      return {
        attachment: stored.ref,
        data: Buffer.from(stored.data).toString('base64'),
      }
    } catch (error) {
      if (error instanceof AttachmentError) {
        reject('attachment-error', error.message, { reason: error.code })
      }
      reject('internal', 'Unable to read image attachment.', {})
    }
  }

  /**
   * Mutate one still-pending queue occurrence without resuming a cold Agent.
   * @param request - Session, queue item, and requested mutation.
   * @returns acknowledgement that the queue mutation was applied.
   */
  updateQueue(request: SessionUpdateQueueRequest): SessionUpdateQueueValue {
    if (request.action.kind === 'edit'
      && request.action.content.some(block => block.type !== 'text')) {
      reject(
        'attachment-error',
        'queue edits accept text content only',
        { reason: 'QUEUE_EDIT_NON_TEXT' },
      )
    }
    const agent = this.ctx.agents.get(request.sessionId)
    if (agent !== undefined && hasApiSessionSubagentOwner(this.ctx, agent.session, agent)) {
      rejectFailure(apiSessionSubagentOwnershipError(request.sessionId))
    }
    if (agent === undefined) {
      reject('queue-item-not-found', 'queued item is no longer pending', { itemId: request.itemId })
    }
    const nextTurn = agent.inbox.nextTurn.find(message => message.id === request.itemId)
    const nextStep = agent.inbox.nextStep.find(message => message.id === request.itemId)
    const located = nextTurn === undefined
      ? nextStep === undefined ? undefined : { target: 'next-step' as const, message: nextStep }
      : { target: 'next-turn' as const, message: nextTurn }
    if (located === undefined) {
      reject('queue-item-not-found', 'queued item is no longer pending', { itemId: request.itemId })
    }
    const { target, message } = located
    if (request.action.kind === 'steer' && (target !== 'next-turn' || agent.status !== 'running')) {
      reject('steer-unavailable', 'current turn no longer accepts steering', { itemId: request.itemId })
    }
    if (request.action.kind === 'edit') {
      agent.inbox.replace(request.itemId, freezeMessage<UserMessage>({
        ...message,
        content: [...request.action.content],
      }))
    } else {
      agent.inbox.remove(request.itemId)
      if (request.action.kind === 'steer') agent.steer(message)
    }
    return { accepted: true }
  }

  /**
   * Cancel one live ordinary Agent while retaining pending inbox work.
   * @param request - Session whose active Agent turn is cancelled.
   * @returns acknowledgement that cancellation was requested.
   */
  cancel(request: SessionCancelRequest): SessionCancelValue {
    const agent = this.ctx.agents.get(request.sessionId)
    if (agent === undefined) {
      reject(
        'session-not-found',
        `session "${request.sessionId}" not found (not attached)`,
        { sessionId: request.sessionId },
      )
    }
    if (hasApiSessionSubagentOwner(this.ctx, agent.session, agent)) {
      rejectFailure(apiSessionSubagentOwnershipError(request.sessionId))
    }
    agent.cancel({ kind: 'user' }, { keepInbox: true })
    return { accepted: true }
  }

  private async resolveAgent(sessionId: SessionId): Promise<Agent> {
    const found = await this.agents.resolveAgent(sessionId)
    if ('error' in found) rejectFailure(found.error)
    return found.agent
  }

  private async harnessRequiresAdvertisedModel(agent: Agent): Promise<boolean> {
    const selected = agent.session.events.findLast(event => event.type === 'harness/selected')?.data
    if (selected === undefined) return false
    const harnesses = this.ctx.get('harnesses')
    if (harnesses === undefined) return false
    const described = await harnesses.describe(
      selected.harnessId,
      selected.version,
      selected.authMethod,
    )
    return described.modelConfiguration?.required === true
  }

  private rejectCreation(sessionId: SessionId, error: unknown): never {
    if (error instanceof ApiSessionPresetConflict) {
      reject('agent-preset-conflict', error.message, {
        sessionId: error.sessionId,
        requestedPreset: error.requestedPreset,
        ...(error.existingPreset === undefined ? {} : { existingPreset: error.existingPreset }),
      })
    }
    if (error instanceof UnknownPresetError) {
      reject('agent-preset-not-found', error.message, {
        agentPreset: error.presetId,
        available: [...error.available],
      })
    }
    if (error instanceof PresetMountError) {
      reject('agent-preset-invalid', error.message, {
        agentPreset: error.presetId,
        reason: error.reason,
      })
    }
    if (error instanceof ApiSessionCwdConflict) {
      reject('session-conflict', error.message, {
        sessionId: error.sessionId,
        requestedCwd: error.requestedCwd,
        ...(error.existingCwd === undefined ? {} : { existingCwd: error.existingCwd }),
      })
    }
    if (error instanceof ApiSessionSubagentOwnership) {
      rejectFailure(apiSessionSubagentOwnershipError(error.sessionId))
    }
    reject('internal', `failed to create session "${sessionId}": ${safeClientDiagnostic(error, 'session creation failed')}`, {})
  }

  private async readSessionState(sessionId: SessionId): Promise<SessionReadState> {
    const attached = this.ctx.sessions.get(sessionId)
    if (attached !== undefined) {
      return { id: attached.id, header: attached.header, events: [...attached.events] }
    }
    const inspected = await inspectApiSession(this.ctx, sessionId)
    return { id: inspected.meta.id, header: inspected.meta, events: inspected.events }
  }

  private async forkWorkspace(source: SessionHeader): Promise<Workspace | undefined> {
    const workspaces = this.ctx.workspaceRegistry.list()
    const direct = workspaces.find(workspace => workspace.sessionIds.includes(source.id))
    if (direct !== undefined || source.origin !== 'subagent') return direct
    const lineage = await this.ctx.sessionQuery.traceSession(source.id)
    for (const ancestor of lineage.ancestors) {
      const workspace = workspaces.find(candidate => candidate.sessionIds.includes(ancestor.header.id))
      if (workspace !== undefined) return workspace
    }
    return undefined
  }

  /** Resolve a caller-visible Session id inside the private No Project root. */
  private noProjectDirectory(sessionId: SessionId): string {
    const raw = String(sessionId)
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/u.test(raw)) {
      throw new Error('the Session id is not a portable managed-directory identity')
    }
    const target = join(this.defaultSessionDirectory, raw)
    if (dirname(target) !== this.defaultSessionDirectory) {
      throw new Error('the Session id escapes the managed No Project root')
    }
    return target
  }

  /** Whether a persisted cwd is exactly one Session-owned directory below the managed root. */
  private isManagedNoProjectDirectory(cwd: string | undefined): boolean {
    if (cwd === undefined) return false
    const absolute = resolve(cwd)
    if (dirname(absolute) !== this.defaultSessionDirectory) return false
    try {
      return this.noProjectDirectory(SessionId(absolute.slice(this.defaultSessionDirectory.length + 1))) === absolute
    } catch {
      return false
    }
  }

  /** Create and verify a private directory without accepting a replaced final symlink. */
  private async ensureNoProjectDirectory(sessionId: SessionId): Promise<{ path: string; created: boolean }> {
    await mkdir(this.defaultSessionDirectory, { recursive: true, mode: 0o700 })
    const root = await lstat(this.defaultSessionDirectory)
    if (root.isSymbolicLink() || !root.isDirectory()) {
      throw new Error('the managed No Project root is not a real directory')
    }
    const rootIdentity = await realpath(this.defaultSessionDirectory)
    await chmod(this.defaultSessionDirectory, 0o700)
    const target = this.noProjectDirectory(sessionId)
    let created = false
    try {
      await mkdir(target, { mode: 0o700 })
      created = true
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
    }
    const information = await lstat(target)
    if (information.isSymbolicLink() || !information.isDirectory()) {
      throw new Error('the Session-owned No Project path is not a real directory')
    }
    if (dirname(await realpath(target)) !== rootIdentity) {
      if (created) await rm(target, { recursive: true, force: true }).catch(() => undefined)
      throw new Error('the Session-owned No Project path escaped its managed root')
    }
    await chmod(target, 0o700)
    return { path: target, created }
  }

  /** Clone one No Project working tree into the child Session's own directory. */
  private async copyNoProjectDirectory(source: string | undefined, childId: SessionId): Promise<string> {
    if (!this.isManagedNoProjectDirectory(source) || source === undefined) {
      throw new Error('the source task does not own a valid managed No Project directory')
    }
    const sourceInformation = await lstat(source)
    if (sourceInformation.isSymbolicLink() || !sourceInformation.isDirectory()) {
      throw new Error('the source No Project directory was replaced')
    }
    const rootIdentity = await realpath(this.defaultSessionDirectory)
    if (dirname(await realpath(source)) !== rootIdentity) {
      throw new Error('the source No Project directory escaped its managed root')
    }
    const target = this.noProjectDirectory(childId)
    try {
      await lstat(target)
      throw new Error('the child No Project directory already exists')
    } catch (error: unknown) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
    await cp(source, target, {
      recursive: true,
      force: false,
      errorOnExist: true,
      dereference: false,
      preserveTimestamps: true,
    })
    const targetInformation = await lstat(target)
    if (targetInformation.isSymbolicLink() || !targetInformation.isDirectory()) {
      await rm(target, { recursive: true, force: true }).catch(() => undefined)
      throw new Error('the cloned No Project directory is not a real directory')
    }
    if (dirname(await realpath(target)) !== rootIdentity) {
      await rm(target, { recursive: true, force: true }).catch(() => undefined)
      throw new Error('the cloned No Project directory escaped its managed root')
    }
    await chmod(target, 0o700)
    return target
  }
}

function rejectFailure(error: { readonly code: string; readonly message: string; readonly details: object }): never {
  throw new TypertRemoteFailure(error)
}

function reject(code: string, message: string, details: object): never {
  throw new TypertRemoteFailure({ code, message, details })
}

async function durablePromptContent(
  ctx: Context,
  content: readonly SessionPromptRequest['content'][number][],
): Promise<ContentBlock[]> {
  if (content.every(part => part.type === 'text')) {
    return content.map(part => ({ type: 'text', text: part.text }))
  }
  const refs = await admitEncodedImages(ctx.attachments, content.filter(part => part.type === 'image'))
  let next = 0
  return content.map(part => part.type === 'text'
    ? { type: 'text', text: part.text }
    // admitEncodedImages returns one reference per image part in order.
    : { type: 'image', attachment: refs[next++] as ImageAttachmentRef })
}

function imageBlockIn(
  content: unknown,
  match: (ref: ImageAttachmentRef) => boolean,
): ImageAttachmentRef | undefined {
  if (!Array.isArray(content)) return undefined
  for (const value of content) {
    if (typeof value !== 'object' || value === null || Array.isArray(value)) continue
    const block = value as { readonly type?: unknown; readonly attachment?: unknown; readonly content?: unknown }
    if (block.type === 'image' && typeof block.attachment === 'object' && block.attachment !== null) {
      const ref = block.attachment as ImageAttachmentRef
      if (match(ref)) return ref
    }
    if (block.type === 'tool-result') {
      const nested = imageBlockIn(block.content, match)
      if (nested !== undefined) return nested
    }
  }
  return undefined
}

function imageInEvent(
  event: SessionEvent,
  match: (ref: ImageAttachmentRef) => boolean,
): ImageAttachmentRef | undefined {
  const data = event.data as {
    readonly content?: unknown
    readonly message?: { readonly content?: unknown }
    readonly inserted?: readonly { readonly content?: unknown }[]
    readonly chunk?: { readonly type?: unknown; readonly block?: unknown }
  }
  const direct = imageBlockIn(data.content, match)
  if (direct !== undefined) return direct
  const message = imageBlockIn(data.message?.content, match)
  if (message !== undefined) return message
  for (const inserted of data.inserted ?? []) {
    const found = imageBlockIn(inserted.content, match)
    if (found !== undefined) return found
  }
  return event.type === 'assistant/chunk' && data.chunk?.type === 'block-end'
    ? imageBlockIn([data.chunk.block], match)
    : undefined
}

function referencedImage(
  events: readonly SessionEvent[],
  attachmentId: string,
): ImageAttachmentRef | undefined {
  for (const event of events) {
    const found = imageInEvent(event, ref => String(ref.attachmentId) === attachmentId)
    if (found !== undefined) return found
  }
  return undefined
}

const IANA_TIME_ZONE = /^[A-Za-z][A-Za-z0-9_+.-]*(?:\/[A-Za-z0-9_+.-]+)+$/

function canonicalClientTimeZone(value: string): string | undefined {
  if (value.length === 0 || value.trim() !== value
    || (value !== 'UTC' && !IANA_TIME_ZONE.test(value))) return undefined
  try {
    return new Intl.DateTimeFormat('en-US', { timeZone: value }).resolvedOptions().timeZone
  } catch {
    return undefined
  }
}

function routeServed(ctx: Context, provider: string): boolean {
  return ctx.llm.listProviders().some(entry => entry.id === provider)
}

/** ACP protocol driver for Open Fish Harness Packs. @module */

import type { Context } from '@deepseek-ai/cordis'
import { access } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { effectiveSessionModelSelection, emitAgentEvent, recordSessionModelSelection } from '@deepseek-ai/dsh-agent'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { SessionId, type SessionEvent } from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-session-persistence'
import { hasHarnessRuntimeBindings, type HarnessDriver, type HarnessForkRequest, type HarnessPack, type HarnessSessionRequest } from '@deepseek-ai/dsh-harness'
import { AcpHarnessAgent, discoverAcpAuthentication, installHarnessPack, launchAcpTerminalAuthentication, launchArgv, launchManagedTerminalAuthentication, managedExecutableArgv, terminalAuthenticationMarker } from './agent.ts'
import {
  CodexHarnessAgent,
  codexAuthenticationHome,
  codexAuthenticationRuntimeDirectory,
  prepareCodexAuthenticationHome,
} from './codex-agent.ts'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { ReasoningEffortId } from '@deepseek-ai/dsh-llm'
import { assertHarnessIsolationAvailable } from './process-authority.ts'
import type {} from '@deepseek-ai/dsh-permission-presets'
import type {} from '@deepseek-ai/dsh-attachment'
import type {} from '@deepseek-ai/dsh-user-questions'

export const name = 'harness-acp'
export const inject = ['harnesses', 'agents', 'sessions', 'subprocess', 'sandbox', 'sandboxPolicy', 'approval', 'userQuestions', 'credentials', 'attachments']

/** Validate the only generic executable graph semantics currently owned by the ACP Driver. */
function validateAcpPack(pack: HarnessPack): string[] {
  const issues: string[] = []
  for (const node of pack.graph.nodes) {
    const config = node.config ?? {}
    for (const coordinate of ['x', 'y'] as const) {
      if (config[coordinate] !== undefined
        && (typeof config[coordinate] !== 'number' || !Number.isFinite(config[coordinate]))) {
        issues.push(`Architecture node "${node.id}" has an invalid ${coordinate} presentation coordinate.`)
      }
    }
    if (!node.editable) continue
    const schemaFields = node.configSchema?.fields ?? []
    const fieldIds = new Set(schemaFields.map(field => field.id))
    const unknown = Object.keys(config).filter(key => key !== 'x' && key !== 'y' && key !== 'acpSessionOptions' && !fieldIds.has(key))
    if (unknown.length > 0) {
      issues.push(`ACP node "${node.id}" declares unsupported executable settings: ${unknown.join(', ')}.`)
    }
    for (const field of schemaFields) {
      if (field.type === 'secret-reference') {
        issues.push(`ACP field "${field.id}" on node "${node.id}" cannot hold credentials; declare Pack authentication fields instead.`)
        continue
      }
      if (field.binding.kind !== 'acp-session-option') {
        issues.push(`ACP field "${field.id}" on node "${node.id}" uses unsupported binding "${field.binding.kind}".`)
        continue
      }
      const value = config[field.id]
      if (value === undefined) {
        if (field.required) issues.push(`ACP field "${field.id}" on node "${node.id}" is required.`)
        continue
      }
      if (field.type === 'boolean' ? typeof value !== 'boolean' : typeof value !== 'string') {
        issues.push(`ACP field "${field.id}" on node "${node.id}" has the wrong value type.`)
      }
      if (field.type === 'select' && typeof value === 'string'
        && !field.choices?.some(choice => choice.id === value)) {
        issues.push(`ACP field "${field.id}" on node "${node.id}" selects an undeclared choice.`)
      }
    }
    if (schemaFields.length > 0) continue
    const options = config.acpSessionOptions
    if (typeof options !== 'object' || options === null || Array.isArray(options) || Object.keys(options).length === 0) {
      issues.push(`Editable ACP node "${node.id}" must declare at least one acpSessionOptions setting.`)
      continue
    }
    const invalid = Object.entries(options).find(([, value]) => typeof value !== 'string' && typeof value !== 'boolean')
    if (invalid !== undefined) {
      issues.push(`ACP option "${invalid[0]}" on node "${node.id}" must be a string or boolean.`)
    }
  }
  return issues
}

/** Resolve the official remote turn represented by a completed local fork prefix. */
function completedCodexTurnId(events: readonly SessionEvent[]): string | undefined {
  for (let index = events.length - 1; index >= 0; index--) {
    const event = events[index]
    if (event?.type !== 'harness/native-event') continue
    const native = event.data.event
    if (native === null || typeof native !== 'object' || Array.isArray(native)) continue
    const frame = native as { method?: unknown; params?: unknown }
    if (frame.method !== 'turn/completed'
      || frame.params === null || typeof frame.params !== 'object' || Array.isArray(frame.params)) continue
    const turn = (frame.params as { turn?: unknown }).turn
    if (turn === null || typeof turn !== 'object' || Array.isArray(turn)) continue
    const id = (turn as { id?: unknown }).id
    if (typeof id === 'string' && id.length > 0) return id
  }
  return undefined
}

/** Register the ACP driver and own every external process it publishes. */
export function apply(ctx: Context): void {
  const live = new Map<SessionId, { agent: AcpHarnessAgent; detachAgent: () => void; detachSession: () => void }>()

  const disposeAcp = async (sessionId: SessionId): Promise<void> => {
    const record = live.get(sessionId)
    if (record === undefined) return
    live.delete(sessionId)
    await record.agent.dispose()
    record.detachAgent()
    record.detachSession()
  }

  const preflightAcp = async (
    request: HarnessSessionRequest,
    pack: HarnessPack,
    signal?: AbortSignal,
  ) => {
    signal?.throwIfAborted()
    if (request.installationDirectory === undefined || request.runtimeDirectory === undefined) {
      throw new Error('ACP preflight requires the exact managed installation and runtime directories')
    }
    const session = ctx.sessions.prepare(request.sessionId, { meta: { cwd: request.cwd } })
    ctx.get('permissionPresets')?.initialize(session)
    const agent = new AcpHarnessAgent(
      ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
      request.authMethod, request.workspaceMode, request.capabilities ?? [],
    )
    try {
      await agent.start(undefined, undefined, signal)
      signal?.throwIfAborted()
      await agent.applyPackConfiguration(signal)
      const models = agent.harnessModelCatalog()?.models ?? []
      if (pack.modelConfiguration?.required === true && models.length === 0) {
        throw new Error(`Harness "${pack.id}" requires a model but its live ACP runtime advertised none`)
      }
      const configurationIds = agent.harnessConfigCatalog().map(option => option.id)
      return {
        message: `Live ACP initialization, authentication, ${configurationIds.length} configuration option${configurationIds.length === 1 ? '' : 's'}, and ${models.length} model route${models.length === 1 ? '' : 's'} passed without sending a model prompt.`,
        modelCount: models.length,
        configurationIds,
      }
    } finally {
      await agent.dispose()
    }
  }

  const publish = async (
    request: HarnessSessionRequest,
    pack: HarnessPack,
    resume: boolean,
    signal?: AbortSignal,
  ): Promise<Agent> => {
    signal?.throwIfAborted()
    if (live.has(request.sessionId) || ctx.agents.get(request.sessionId) !== undefined) {
      throw new Error(`agent "${request.sessionId}" is already live`)
    }
    const persistence = resume ? ctx.get('sessionPersistence') : undefined
    if (resume && persistence === undefined) {
      throw new Error('session persistence is required to resume an external Harness')
    }
    // Persistence owns cold identities. Its preparation reserves the exact
    // unpublished Session and is consumed when SessionStore publishes it;
    // rebuilding the inspected log directly through SessionStore conflicts
    // with that ownership and makes every ACP cold resume fail.
    const preparation = persistence === undefined
      ? undefined
      : await persistence.prepare(request.sessionId)
    const session = preparation?.session
      ?? ctx.sessions.prepare(request.sessionId, { meta: { cwd: request.cwd } })
    ctx.get('permissionPresets')?.initialize(session)
    const selected = session.events.findLast(event => event.type === 'harness/selected')
    const capabilitySnapshot = selected?.data.capabilities ?? request.capabilities ?? []
    const remoteSessionId = session.events.findLast(event => event.type === 'harness/remote-session')
      ?.data.remoteSessionId ?? selected?.data.remoteSessionId
    if (request.installationDirectory === undefined) throw new Error('ACP Harness requires a managed installation snapshot')
    if (request.runtimeDirectory === undefined) throw new Error('ACP Harness requires a private managed runtime directory')
    let agent = new AcpHarnessAgent(
      ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
      request.authMethod, request.workspaceMode, capabilitySnapshot,
    )
    let detachSession: (() => void) | undefined
    let detachAgent: (() => void) | undefined
    try {
      try {
        await agent.start(resume ? remoteSessionId : undefined, undefined, signal)
        if (!resume) {
          await agent.applyPackConfiguration(signal)
          agent.commitSelection()
        } else {
          const pinned = effectiveSessionModelSelection(session.events)
          if (pinned?.provider === 'harness') {
            await agent.selectHarnessModel(pinned.model, pinned.reasoningEffort, signal)
          }
        }
        const catalog = agent.harnessModelCatalog()
        if (catalog !== undefined) {
          recordSessionModelSelection(session, {
            provider: 'harness', model: catalog.current,
            ...(catalog.currentReasoningEffort === undefined
              ? {}
              : { reasoningEffort: ReasoningEffortId(catalog.currentReasoningEffort) }),
          })
        }
      } catch (error: unknown) {
        // Some Harnesses (notably Codex) do not persist a remote session until
        // its first turn. An empty Open Fish task is still durable locally, so
        // after a cold launch it may legitimately point at a remote identity
        // that no longer exists. Recreate only that blank remote session; a
        // non-empty transcript must never be silently detached from history.
        const blank = !session.events.some(event => event.type === 'turn/start')
        if (!resume || !blank) throw error
        signal?.throwIfAborted()
        await agent.dispose()
        agent = new AcpHarnessAgent(
          ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
          request.authMethod, request.workspaceMode, capabilitySnapshot,
        )
        await agent.start(undefined, undefined, signal)
        await agent.applyPackConfiguration(signal)
        const pinned = effectiveSessionModelSelection(session.events)
        if (pinned?.provider === 'harness') {
          await agent.selectHarnessModel(pinned.model, pinned.reasoningEffort, signal)
        }
        agent.commitSelection()
      }
      signal?.throwIfAborted()
      detachSession = agent.ctx.sessions.enter(session)
      detachAgent = ctx.agents.enter(agent, ctx.agent)
      agent.ctx.sessions.announce(session)
      ctx.agents.announce(agent)
      emitAgentEvent(ctx, agent, 'agent/session-start', { source: resume ? 'resume' : 'startup' })
      live.set(request.sessionId, { agent, detachAgent, detachSession })
      return agent
    } catch (error: unknown) {
      detachAgent?.()
      detachSession?.()
      await agent.dispose()
      throw error
    } finally {
      preparation?.[Symbol.dispose]()
    }
  }

  const driver: HarnessDriver = {
    apiVersion: 1,
    protocol: 'acp',
    capabilities(pack) {
      return Promise.resolve([
        { id: 'lifecycle.install', status: 'supported', source: 'driver' },
        { id: 'lifecycle.update', status: 'supported', source: 'driver' },
        { id: 'lifecycle.rollback', status: 'supported', source: 'driver' },
        { id: 'lifecycle.uninstall', status: 'supported', source: 'driver' },
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'session.cancel', status: 'supported', source: 'driver' },
        { id: 'session.fork', status: 'unsupported', source: 'driver', detail: 'Driver API v1 has no remote-session fork primitive; OpenFish will not relabel a local transcript copy as a real Harness fork.' },
        { id: 'workspace.project', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.models', status: 'runtime', source: 'runtime', detail: 'Models are reported by the running ACP agent.' },
        { id: 'configuration.reasoning', status: 'runtime', source: 'runtime', detail: 'Reasoning controls appear only when advertised by the selected model.' },
        { id: 'configuration.auth', status: 'runtime', source: 'runtime', detail: 'Authentication is discovered from the installed agent and Pack.' },
        { id: 'configuration.agent-presets', status: 'unsupported', source: 'driver', detail: 'ACP Harnesses expose their own configuration options instead of DSH agent presets.' },
        { id: 'interaction.tools', status: 'supported', source: 'driver' },
        { id: 'interaction.approvals', status: 'supported', source: 'driver' },
        { id: 'interaction.questions', status: 'supported', source: 'driver', detail: 'ACP form elicitation is bridged to OpenFish user questions; unadvertised URL elicitation remains Harness-owned.' },
        { id: 'interaction.files', status: 'supported', source: 'driver', detail: 'Image prompts plus workspace-confined ACP text-file operations are bridged without exposing host paths outside the task root.' },
        { id: 'interaction.events', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
        { id: 'architecture.runtime-observation', status: hasHarnessRuntimeBindings(pack) ? 'runtime' : 'unsupported', source: 'runtime', detail: hasHarnessRuntimeBindings(pack) ? 'Only Pack-bound ACP runtime signals activate declared nodes.' : 'This Pack declares no runtime observation bindings.' },
        { id: 'architecture.edit', status: pack.graph.level === 'composable' && pack.graph.nodes.some(node => node.editable) ? 'supported' : 'unsupported', source: 'pack' },
        { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
        { id: 'builder.manifest', status: 'supported', source: 'pack' },
        { id: 'builder.test', status: 'supported', source: 'driver' },
        { id: 'builder.publish', status: 'unsupported', source: 'host', detail: 'Registry and bundled Packs are read only; fork a user-authored Pack to use OpenFish community submission.' },
      ])
    },
    validatePack(pack) { return Promise.resolve(validateAcpPack(pack)) },
    async available(pack) {
      try {
        assertHarnessIsolationAvailable(ctx)
        if (pack.distribution?.kind === 'binary') {
          return pack.distribution.sha256 === undefined
            ? 'Binary distribution has no SHA-256 checksum and cannot be installed safely'
            : undefined
        }
        const { argv } = launchArgv(pack)
        await ctx.subprocess.resolveExecutable(argv[0] as string)
        return undefined
      } catch (error: unknown) {
        return `Harness "${pack.id}" cannot launch: ${error instanceof Error ? error.message : String(error)}`
      }
    },
    preflight: preflightAcp,
    create: (request, pack, signal) => publish(request, pack, false, signal),
    resume: (request, pack, signal) => publish(request, pack, true, signal),
    dispose: sessionId => disposeAcp(sessionId),
    install: (pack, directory, runtimeDirectory, signal) => installHarnessPack(ctx, pack, directory, runtimeDirectory, signal),
    discoverAuth: (pack, directory, runtimeDirectory) => discoverAcpAuthentication(ctx, pack, directory, runtimeDirectory),
    authenticateInteractive: (pack, directory, runtimeDirectory, method, signal) =>
      launchAcpTerminalAuthentication(ctx, pack, directory, runtimeDirectory, method, signal),
    async missingCredentials(pack, authMethod, locations) {
      const method = pack.authMethods?.find(candidate => candidate.id === authMethod)
      if (method === undefined) return []
      const missing: string[] = []
      for (const field of method.fields) {
        if (field.required && await ctx.credentials.resolve(credentialRef(field.ref)) === undefined) missing.push(field.ref)
      }
      if (method.kind === 'terminal') {
        if (locations === undefined) missing.push(`terminal-login:${method.id}`)
        else {
          try { await access(terminalAuthenticationMarker(locations.runtimeDirectory, method.id)) }
          catch { missing.push(`terminal-login:${method.id}`) }
        }
      }
      return missing
    },
  }

  const codexLive = new Map<SessionId, { agent: CodexHarnessAgent; detachAgent: () => void; detachSession: () => void }>()
  const disposeCodex = async (sessionId: SessionId): Promise<void> => {
    const record = codexLive.get(sessionId)
    if (record === undefined) return
    codexLive.delete(sessionId)
    await record.agent.dispose()
    record.detachAgent()
    record.detachSession()
  }
  const discardCodex = async (sessionId: SessionId): Promise<void> => {
    const record = codexLive.get(sessionId)
    if (record === undefined) return
    codexLive.delete(sessionId)
    try {
      await record.agent.deleteCurrentRemoteThread()
    } finally {
      await record.agent.dispose()
      record.detachAgent()
      record.detachSession()
    }
  }
  const publishCodex = async (
    request: HarnessSessionRequest,
    pack: HarnessPack,
    resume: boolean,
    signal?: AbortSignal,
  ): Promise<Agent> => {
    signal?.throwIfAborted()
    if (codexLive.has(request.sessionId) || ctx.agents.get(request.sessionId) !== undefined) {
      throw new Error(`agent "${request.sessionId}" is already live`)
    }
    const persistence = resume ? ctx.get('sessionPersistence') : undefined
    if (resume && persistence === undefined) throw new Error('session persistence is required to resume Codex')
    const preparation = persistence === undefined ? undefined : await persistence.prepare(request.sessionId)
    const session = preparation?.session ?? ctx.sessions.prepare(request.sessionId, { meta: { cwd: request.cwd } })
    ctx.get('permissionPresets')?.initialize(session)
    const selected = session.events.findLast(event => event.type === 'harness/selected')
    const capabilitySnapshot = selected?.data.capabilities ?? request.capabilities ?? []
    const remoteThreadId = session.events.findLast(event => event.type === 'harness/remote-session')
      ?.data.remoteSessionId ?? selected?.data.remoteSessionId
    if (request.installationDirectory === undefined) throw new Error('Codex Harness requires a managed installation snapshot')
    if (request.runtimeDirectory === undefined) throw new Error('Codex Harness requires a private managed runtime directory')
    let agent = new CodexHarnessAgent(
      ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
      request.authMethod, request.workspaceMode, capabilitySnapshot,
    )
    let detachSession: (() => void) | undefined
    let detachAgent: (() => void) | undefined
    try {
      try {
        await agent.start(resume ? remoteThreadId : undefined, undefined, signal)
        if (!resume) agent.commitSelection()
        else {
          const pinned = effectiveSessionModelSelection(session.events)
          if (pinned?.provider === 'harness') {
            await agent.selectHarnessModel(pinned.model, pinned.reasoningEffort, signal)
          }
        }
      } catch (error: unknown) {
        const blank = !session.events.some(event => event.type === 'turn/start')
        if (!resume || !blank) throw error
        signal?.throwIfAborted()
        await agent.dispose()
        agent = new CodexHarnessAgent(
          ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
          request.authMethod, request.workspaceMode, capabilitySnapshot,
        )
        await agent.start(undefined, undefined, signal)
        const pinned = effectiveSessionModelSelection(session.events)
        if (pinned?.provider === 'harness') {
          await agent.selectHarnessModel(pinned.model, pinned.reasoningEffort, signal)
        }
        agent.commitSelection()
      }
      signal?.throwIfAborted()
      const catalog = agent.harnessModelCatalog()
      if (catalog !== undefined) {
        recordSessionModelSelection(session, {
          provider: 'harness', model: catalog.current,
          ...(catalog.currentReasoningEffort === undefined
            ? {}
            : { reasoningEffort: ReasoningEffortId(catalog.currentReasoningEffort) }),
        })
      }
      detachSession = agent.ctx.sessions.enter(session)
      detachAgent = ctx.agents.enter(agent, ctx.agent)
      agent.ctx.sessions.announce(session)
      ctx.agents.announce(agent)
      emitAgentEvent(ctx, agent, 'agent/session-start', { source: resume ? 'resume' : 'startup' })
      codexLive.set(request.sessionId, { agent, detachAgent, detachSession })
      return agent
    } catch (error: unknown) {
      detachAgent?.()
      detachSession?.()
      await agent.dispose()
      throw error
    } finally {
      preparation?.[Symbol.dispose]()
    }
  }

  const publishCodexFork = async (request: HarnessForkRequest, pack: HarnessPack): Promise<Agent> => {
    if (codexLive.has(request.sessionId) || ctx.agents.get(request.sessionId) !== undefined) {
      throw new Error(`agent "${request.sessionId}" is already live`)
    }
    const source = codexLive.get(request.sourceSessionId)
    if (source === undefined) throw new Error(`Codex source task "${request.sourceSessionId}" is not live`)
    const lastTurnId = completedCodexTurnId(request.seed)
    if (lastTurnId === undefined) {
      throw new Error('Codex cannot map this local fork boundary to an official completed remote turn; resume and complete another turn first')
    }
    if (request.installationDirectory === undefined) throw new Error('Codex Harness fork requires a managed installation snapshot')
    if (request.runtimeDirectory === undefined) throw new Error('Codex Harness fork requires a private managed runtime directory')

    const remoteThreadId = await source.agent.forkRemoteThread(lastTurnId)
    let agent: CodexHarnessAgent | undefined
    let detachSession: (() => void) | undefined
    let detachAgent: (() => void) | undefined
    try {
      const session = ctx.sessions.prepare(request.sessionId, {
        seed: request.seed,
        meta: {
          cwd: request.cwd,
          parentSession: request.sourceSessionId,
          seedLength: request.seed.length,
        },
      })
      session.append('harness/remote-session', {
        harnessId: pack.id,
        remoteSessionId: remoteThreadId,
        reason: 'session-fork',
      })
      ctx.get('permissionPresets')?.initialize(session)
      agent = new CodexHarnessAgent(
        ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
        request.authMethod, request.workspaceMode, request.capabilities ?? [],
      )
      await agent.start(remoteThreadId)
      const pinned = effectiveSessionModelSelection(session.events)
      if (pinned?.provider === 'harness') {
        await agent.selectHarnessModel(pinned.model, pinned.reasoningEffort)
      }
      agent.commitSelection()
      detachSession = agent.ctx.sessions.enter(session)
      detachAgent = ctx.agents.enter(agent, ctx.agent)
      agent.ctx.sessions.announce(session)
      ctx.agents.announce(agent)
      emitAgentEvent(ctx, agent, 'agent/session-start', { source: 'startup' })
      codexLive.set(request.sessionId, { agent, detachAgent, detachSession })
      return agent
    } catch (error: unknown) {
      detachAgent?.()
      detachSession?.()
      await agent?.dispose()
      await source.agent.deleteRemoteThread(remoteThreadId).catch(() => undefined)
      throw error
    }
  }

  const codexDriver: HarnessDriver = {
    apiVersion: 1,
    protocol: 'codex-app-server',
    capabilities(pack) {
      return Promise.resolve([
        { id: 'lifecycle.install', status: 'supported', source: 'driver' },
        { id: 'lifecycle.update', status: 'supported', source: 'driver' },
        { id: 'lifecycle.rollback', status: 'supported', source: 'driver' },
        { id: 'lifecycle.uninstall', status: 'supported', source: 'driver' },
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'session.cancel', status: 'supported', source: 'driver' },
        { id: 'session.fork', status: 'supported', source: 'driver', detail: 'Uses the official app-server thread/fork operation at an exact completed-turn boundary.' },
        { id: 'workspace.project', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.models', status: 'runtime', source: 'runtime' },
        { id: 'configuration.reasoning', status: 'runtime', source: 'runtime' },
        { id: 'configuration.auth', status: 'runtime', source: 'runtime' },
        { id: 'configuration.agent-presets', status: 'unsupported', source: 'driver' },
        { id: 'interaction.tools', status: 'supported', source: 'driver' },
        { id: 'interaction.approvals', status: 'supported', source: 'driver' },
        { id: 'interaction.questions', status: 'supported', source: 'driver', detail: 'Codex request_user_input and form-mode MCP elicitation are bridged to OpenFish; secret and URL-mode prompts stay provider-owned and are not copied into app state.' },
        { id: 'interaction.files', status: 'supported', source: 'driver', detail: 'Validated OpenFish image attachments are sent through the official turn/start image input without exposing their Host storage path.' },
        { id: 'interaction.events', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
        { id: 'architecture.runtime-observation', status: hasHarnessRuntimeBindings(pack) ? 'runtime' : 'unsupported', source: 'runtime', detail: hasHarnessRuntimeBindings(pack) ? 'Only Pack-bound Codex runtime signals activate declared nodes.' : 'This Pack declares no runtime observation bindings.' },
        { id: 'architecture.edit', status: 'unsupported', source: 'driver', detail: 'The Codex app-server Driver exposes an evidence-backed read-only architecture; it does not interpret Pack graph settings.' },
        { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
        { id: 'builder.manifest', status: 'supported', source: 'pack' },
        { id: 'builder.test', status: 'supported', source: 'driver' },
        { id: 'builder.publish', status: 'unsupported', source: 'pack' },
      ])
    },
    async available(pack) {
      try {
        assertHarnessIsolationAvailable(ctx)
        const { argv } = launchArgv(pack)
        await ctx.subprocess.resolveExecutable(argv[0] as string)
        return undefined
      } catch (error: unknown) {
        return `Codex cannot launch: ${error instanceof Error ? error.message : String(error)}`
      }
    },
    async preflight(request, pack, signal) {
      signal?.throwIfAborted()
      if (request.installationDirectory === undefined || request.runtimeDirectory === undefined) {
        throw new Error('Codex preflight requires the exact managed installation and runtime directories')
      }
      const session = ctx.sessions.prepare(request.sessionId, { meta: { cwd: request.cwd } })
      ctx.get('permissionPresets')?.initialize(session)
      const agent = new CodexHarnessAgent(
        ctx, request.sessionId, session, pack, request.installationDirectory, request.runtimeDirectory,
        request.authMethod, request.workspaceMode, request.capabilities ?? [],
      )
      try {
        await agent.start(undefined, undefined, signal)
        signal?.throwIfAborted()
        const models = agent.harnessModelCatalog()?.models ?? []
        if (pack.modelConfiguration?.required === true && models.length === 0) {
          throw new Error('Codex app-server advertised no model routes')
        }
        return {
          message: `Live Codex app-server initialization, authentication, and ${models.length} model route${models.length === 1 ? '' : 's'} passed without sending a model prompt.`,
          modelCount: models.length,
          configurationIds: [],
        }
      } finally {
        // model/list currently requires a durable app-server thread. A
        // content-free preflight must not leave that empty provider-side
        // identity in the user's Codex history after validation completes.
        try { await agent.deleteCurrentRemoteThread() } finally { await agent.dispose() }
      }
    },
    create: (request, pack, signal) => publishCodex(request, pack, false, signal),
    resume: (request, pack, signal) => publishCodex(request, pack, true, signal),
    fork: (request, pack) => publishCodexFork(request, pack),
    dispose: sessionId => disposeCodex(sessionId),
    discard: sessionId => discardCodex(sessionId),
    install: (pack, directory, runtimeDirectory, signal) => installHarnessPack(ctx, pack, directory, runtimeDirectory, signal),
    discoverAuth: pack => Promise.resolve(pack.authMethods ?? []),
    async authenticateInteractive(pack, directory, runtimeDirectory, method, signal) {
      if (method.id !== 'codex-managed-login' || method.kind !== 'terminal') {
        throw new Error(`Codex authentication method "${method.id}" is not an OpenFish-managed interactive login`)
      }
      const executable = await managedExecutableArgv(pack, directory)
      if (executable.length === 0) throw new Error('Installed Codex package does not expose its executable')
      const codexHome = await prepareCodexAuthenticationHome(runtimeDirectory, method.id)
      const processRuntimeDirectory = codexAuthenticationRuntimeDirectory(runtimeDirectory, method.id)
      await launchManagedTerminalAuthentication(ctx, {
        argv: [...executable, 'login'],
        env: { ...(pack.distribution?.env ?? {}), CODEX_HOME: codexHome },
        installationDirectory: directory,
        runtimeDirectory: processRuntimeDirectory,
        completionFile: join(codexHome, 'auth.json'),
      }, signal)
    },
    async missingCredentials(pack, authMethod, locations) {
      const method = pack.authMethods?.find(candidate => candidate.id === authMethod)
      if (method === undefined) return []
      if (method.id === 'codex-local-login') {
        // "Existing Codex login" remains tied to the user's current ambient
        // login choice. A stale private import must not keep this method
        // looking configured after the user logs Codex out locally.
        try {
          await access(join(homedir(), '.codex', 'auth.json'))
          return []
        } catch {
          return ['existing-codex-login']
        }
      }
      if (method.id === 'codex-managed-login') {
        if (locations === undefined) return ['openfish-codex-login']
        try {
          await access(join(codexAuthenticationHome(locations.runtimeDirectory, method.id), 'auth.json'))
          return []
        } catch {
          return ['openfish-codex-login']
        }
      }
      const missing: string[] = []
      for (const field of method.fields) {
        if (field.required && await ctx.credentials.resolve(credentialRef(field.ref)) === undefined) missing.push(field.ref)
      }
      return missing
    },
  }

  ctx.effect(() => {
    const unregister = ctx.harnesses.registerDriver(driver)
    const unregisterCodex = ctx.harnesses.registerDriver(codexDriver)
    return async () => {
      unregister()
      unregisterCodex()
      const records = [...live.values()]
      live.clear()
      for (const record of records) {
        await record.agent.dispose()
        record.detachAgent()
        record.detachSession()
      }
      const codexRecords = [...codexLive.values()]
      codexLive.clear()
      for (const record of codexRecords) {
        await record.agent.dispose()
        record.detachAgent()
        record.detachSession()
      }
    }
  }, 'harness-acp.lifecycle()')
}

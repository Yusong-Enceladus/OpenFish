/** ACP protocol driver for Open Fish Harness Packs. @module */

import type { Context } from '@deepseek-ai/cordis'
import { emitAgentEvent } from '@deepseek-ai/dsh-agent'
import type { Agent } from '@deepseek-ai/dsh-agent'
import { SessionId } from '@deepseek-ai/dsh-session'
import type {} from '@deepseek-ai/dsh-session-persistence'
import type { HarnessDriver, HarnessPack, HarnessSessionRequest } from '@deepseek-ai/dsh-harness'
import { AcpHarnessAgent, discoverAcpAuthentication, installHarnessPack, launchAcpTerminalAuthentication, launchArgv } from './agent.ts'
import { credentialRef } from '@deepseek-ai/dsh-credentials'

export const name = 'harness-acp'
export const inject = ['harnesses', 'agents', 'sessions', 'subprocess', 'approval', 'credentials']

/** Register the ACP driver and own every external process it publishes. */
export function apply(ctx: Context): void {
  const live = new Map<SessionId, { agent: AcpHarnessAgent; detachAgent: () => void; detachSession: () => void }>()

  const publish = async (request: HarnessSessionRequest, pack: HarnessPack, resume: boolean): Promise<Agent> => {
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
    const selected = session.events.findLast(event => event.type === 'harness/selected')
    const remoteSessionId = selected?.data.remoteSessionId
    if (request.installationDirectory === undefined) throw new Error('ACP Harness requires a managed installation snapshot')
    let agent = new AcpHarnessAgent(ctx, request.sessionId, session, pack, request.installationDirectory, request.authMethod)
    let detachSession: (() => void) | undefined
    let detachAgent: (() => void) | undefined
    try {
      try {
        await agent.start(resume ? remoteSessionId : undefined)
        if (!resume) {
          await agent.applyPackConfiguration()
          agent.commitSelection()
        }
      } catch (error: unknown) {
        // Some Harnesses (notably Codex) do not persist a remote session until
        // its first turn. An empty Open Fish task is still durable locally, so
        // after a cold launch it may legitimately point at a remote identity
        // that no longer exists. Recreate only that blank remote session; a
        // non-empty transcript must never be silently detached from history.
        const blank = !session.events.some(event => event.type === 'turn/start')
        if (!resume || !blank) throw error
        await agent.dispose()
        agent = new AcpHarnessAgent(ctx, request.sessionId, session, pack, request.installationDirectory, request.authMethod)
        await agent.start()
        await agent.applyPackConfiguration()
        agent.commitSelection()
      }
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
    async capabilities(pack) {
      return [
        { id: 'lifecycle.install', status: 'supported', source: 'driver' },
        { id: 'lifecycle.update', status: 'supported', source: 'driver' },
        { id: 'lifecycle.rollback', status: 'supported', source: 'driver' },
        { id: 'lifecycle.uninstall', status: 'supported', source: 'driver' },
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'session.cancel', status: 'supported', source: 'driver' },
        { id: 'session.fork', status: 'runtime', source: 'runtime', detail: 'OpenFish can fork visible history; remote Harness continuity depends on ACP resume semantics.' },
        { id: 'session.archive', status: 'supported', source: 'driver' },
        { id: 'workspace.project', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.models', status: 'runtime', source: 'runtime', detail: 'Models are reported by the running ACP agent.' },
        { id: 'configuration.reasoning', status: 'runtime', source: 'runtime', detail: 'Reasoning controls appear only when advertised by the selected model.' },
        { id: 'configuration.auth', status: 'runtime', source: 'runtime', detail: 'Authentication is discovered from the installed agent and Pack.' },
        { id: 'interaction.tools', status: 'supported', source: 'driver' },
        { id: 'interaction.approvals', status: 'supported', source: 'driver' },
        { id: 'interaction.questions', status: 'unsupported', source: 'driver', detail: 'ACP question requests are not mapped by Driver API v1.' },
        { id: 'interaction.files', status: 'unsupported', source: 'driver', detail: 'Driver API v1 currently sends text prompts to ACP Harnesses.' },
        { id: 'interaction.events', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
        { id: 'architecture.runtime-observation', status: 'runtime', source: 'runtime', detail: 'ACP updates provide runtime evidence without claiming private internals.' },
        { id: 'architecture.edit', status: pack.graph.level === 'composable' ? 'supported' : 'unsupported', source: 'pack' },
        { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
        { id: 'builder.manifest', status: 'supported', source: 'pack' },
        { id: 'builder.test', status: 'supported', source: 'driver' },
        { id: 'builder.publish', status: 'unsupported', source: 'pack', detail: 'OpenFish can export a credential-free Pack but does not submit it automatically.' },
      ]
    },
    async available(pack) {
      try {
        if (pack.distribution?.kind === 'binary') {
          return pack.source === 'acp-registry' && pack.distribution.sha256 === undefined
            ? 'Registry binary has no SHA-256 checksum and cannot be installed safely'
            : undefined
        }
        const { argv } = launchArgv(pack)
        await ctx.subprocess.resolveExecutable(argv[0] as string)
        return undefined
      } catch (error: unknown) {
        return `Harness "${pack.id}" cannot launch: ${error instanceof Error ? error.message : String(error)}`
      }
    },
    create: (request, pack) => publish(request, pack, false),
    resume: (request, pack) => publish(request, pack, true),
    install: (pack, directory, signal) => installHarnessPack(ctx, pack, directory, signal),
    discoverAuth: (pack, directory) => discoverAcpAuthentication(ctx, pack, directory),
    authenticateInteractive: (pack, directory, method) => launchAcpTerminalAuthentication(ctx, pack, directory, method),
    async missingCredentials(pack, authMethod) {
      const method = pack.authMethods?.find(candidate => candidate.id === authMethod)
      if (method === undefined) return []
      const missing: string[] = []
      for (const field of method.fields) {
        if (field.required && await ctx.credentials.resolve(credentialRef(field.ref)) === undefined) missing.push(field.ref)
      }
      return missing
    },
  }

  ctx.effect(() => {
    const unregister = ctx.harnesses.registerDriver(driver)
    return async () => {
      unregister()
      const records = [...live.values()]
      live.clear()
      for (const record of records) {
        await record.agent.dispose()
        record.detachAgent()
        record.detachSession()
      }
    }
  }, 'harness-acp.lifecycle()')
}

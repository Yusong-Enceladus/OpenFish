import { Context } from '@deepseek-ai/cordis'
import { mkdtemp, lstat, rm, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import type { Agent, AgentHandle, CreateAgentOptions } from '@deepseek-ai/dsh-agent'
import { PresetMountError } from '@deepseek-ai/dsh-agent-presets'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import type { Workspace, WorkspaceId } from '@deepseek-ai/dsh-workspace'
import { describe, expect, it, vi } from 'vitest'
import {
  ApiSessionAgentController,
  ApiSessionCwdConflict,
} from '../src/agent.ts'
import { SessionCommandController } from '../src/commands.ts'
import { installSessionReadTestServices, testSessionPersistence } from './test-remote.ts'

async function expectFailure(operation: Promise<unknown>, code: string): Promise<void> {
  await expect(operation).rejects.toMatchObject({ failure: { code } })
}

function controllerAgents(ctx: Context, overrides: object = {}): ApiSessionAgentController {
  const agents = new Map<SessionId, Agent>()
  return {
    ensureSession: (sessionId: SessionId, cwd: string) => {
      const session = ctx.sessions.get(sessionId) ?? ctx.sessions.create(sessionId, { meta: { cwd } })
      const agent = { id: sessionId, session, status: 'idle', ctx } as Agent
      agents.set(sessionId, agent)
      return Promise.resolve(agent)
    },
    resolveAgent: (sessionId: SessionId) => {
      const agent = agents.get(sessionId)
      return Promise.resolve(agent === undefined
        ? { error: { code: 'session-not-found', message: 'fixture Agent not found', details: { sessionId } } }
        : { agent })
    },
    disposeOwnedAgent: (sessionId: SessionId) => Promise.resolve(agents.delete(sessionId)),
    adoptOwnedAgent: (handle: AgentHandle) => {
      agents.set(handle.agent.id, handle.agent)
      return handle.agent
    },
    composeAgent: () => Promise.resolve({ setup: () => {} }),
    presetForSession: () => undefined,
    presetForObservation: () => undefined,
    ...overrides,
  } as unknown as ApiSessionAgentController
}

async function baseContext(): Promise<Context> {
  const ctx = new Context()
  await ctx.plugin(SessionStore)
  await ctx.plugin(AgentRegistry)
  installSessionReadTestServices(ctx)
  ctx.provide('agentDefaultModel', {
    currentSelection: () => ({ provider: 'fixture', model: 'fixture-model' }),
    saveSelection: () => Promise.resolve(),
  } as never)
  return ctx
}

describe('Session creation failures', () => {
  it('mints a private Session-owned No Project directory when no target is supplied', async () => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { get: () => undefined, list: () => [] } as never)
    const root = await mkdtemp(join(tmpdir(), 'openfish-no-project-root-'))
    const ensureSession = vi.fn((sessionId: SessionId, cwd: string) => {
      const session = ctx.sessions.create(sessionId, { meta: { cwd } })
      return Promise.resolve({ id: sessionId, session } as Agent)
    })
    const controller = new SessionCommandController(
      ctx,
      controllerAgents(ctx, { ensureSession }),
      root,
    )

    const created = await controller.create({})
    const expectedDirectory = join(root, created.sessionId)

    expect(created.sessionId).toMatch(/^session-/)
    expect(created).not.toHaveProperty('agentPreset')
    expect(ensureSession).toHaveBeenCalledWith(
      created.sessionId,
      expectedDirectory,
      false,
      undefined,
      'dsh',
      'no-project',
      undefined,
    )
    expect((await lstat(expectedDirectory)).isDirectory()).toBe(true)
    expect(ctx.sessions.get(created.sessionId)?.header.cwd).toBe(expectedDirectory)
    expect(ctx.sessions.get(created.sessionId)?.events.findLast(event => event.type === 'harness/selected')?.data)
      .toMatchObject({ harnessId: 'dsh', workspaceMode: 'no-project' })
    await ctx.fiber.dispose()
    await rm(root, { recursive: true, force: true })
  })

  it('fails closed when the managed No Project root is a symlink', async () => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { get: () => undefined, list: () => [] } as never)
    const parent = await mkdtemp(join(tmpdir(), 'openfish-no-project-symlink-'))
    const realRoot = join(parent, 'real')
    const linkedRoot = join(parent, 'linked')
    await symlink(realRoot, linkedRoot)
    const controller = new SessionCommandController(ctx, controllerAgents(ctx), linkedRoot)

    await expectFailure(controller.create({ noProject: true }), 'invalid-no-project-directory')
    await ctx.fiber.dispose()
    await rm(parent, { recursive: true, force: true })
  })

  it('maps missing Workspaces and attachment failures', async () => {
    const missing = await baseContext()
    missing.provide('workspaceRegistry', { get: () => undefined, list: () => [] } as never)
    const missingController = new SessionCommandController(
      missing,
      controllerAgents(missing),
      '/default',
    )
    await expectFailure(missingController.create({
      workspaceId: 'missing' as WorkspaceId,
    }), 'workspace-not-found')
    await missing.fiber.dispose()

    const failed = await baseContext()
    const workspace = {
      id: 'workspace-1' as WorkspaceId,
      path: '/workspace',
      attachSession: () => Promise.reject(new Error('read-only workspace')),
    } as unknown as Workspace
    failed.provide('workspaceRegistry', {
      get: () => workspace,
      list: () => [workspace],
    } as never)
    const failedController = new SessionCommandController(
      failed,
      controllerAgents(failed),
      '/default',
    )
    await expectFailure(failedController.create({
      sessionId: SessionId('workspace-session'),
      workspaceId: workspace.id,
    }), 'workspace-attach-failed')
    await failed.fiber.dispose()
  })

  it.each([
    {
      error: new PresetMountError('broken', 'invalid composition'),
      code: 'agent-preset-invalid',
    },
    {
      error: new ApiSessionCwdConflict(SessionId('cwd-less'), '/requested', undefined),
      code: 'session-conflict',
    },
    {
      error: new ApiSessionCwdConflict(SessionId('wrong-cwd'), '/requested', '/stored'),
      code: 'session-conflict',
    },
    {
      error: new Error('factory unavailable'),
      code: 'internal',
    },
  ])('maps $code creation failures', async ({ error, code }) => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { get: () => undefined, list: () => [] } as never)
    const controller = new SessionCommandController(
      ctx,
      controllerAgents(ctx, { ensureSession: () => Promise.reject(error) }),
      '/default',
    )

    await expectFailure(controller.create({
      sessionId: SessionId('failed-create'), cwd: '/requested',
    }), code)
    await ctx.fiber.dispose()
  })

  it('rejects contradictory create targets', async () => {
    const ctx = await baseContext()
    const controller = new SessionCommandController(ctx, controllerAgents(ctx), '/default')

    await expectFailure(controller.create({
      workspaceId: 'workspace-1' as WorkspaceId,
      cwd: '/workspace',
    }), 'bad-request')
    await expectFailure(controller.create({ cwd: '/workspace', noProject: true }), 'bad-request')
    await ctx.fiber.dispose()
  })

})

function completedSession(
  ctx: Context,
  id: string,
  cwd?: string,
  lineage: { parentSession?: SessionId; origin?: 'subagent' } = {},
) {
  const session = ctx.sessions.create(SessionId(id), {
    meta: { ...(cwd === undefined ? {} : { cwd }), ...lineage },
  })
  session.append('turn/start', { turn: 1 })
  session.append('user/message', createUserMessage({
    content: [{ type: 'text', text: 'work' }], source: { kind: 'user' },
  }), { surfaceOp: 'append' })
  session.append('turn/end', { turn: 1, reason: { kind: 'completed' } })
  return session
}

function resolvedHandle(ctx: Context, sessionId: SessionId): AgentHandle {
  const session = ctx.sessions.get(sessionId) ?? ctx.sessions.create(sessionId)
  return {
    agent: { id: sessionId, session, status: 'idle', ctx } as Agent,
    dispose: () => Promise.resolve(),
  }
}

describe('Session fork failures', () => {
  it('maps missing cold sources with and without persistence', async () => {
    const withoutPersistence = await baseContext()
    withoutPersistence.provide('workspaceRegistry', { list: () => [] } as never)
    const unavailableController = new SessionCommandController(
      withoutPersistence, controllerAgents(withoutPersistence), '/default',
    )
    await expectFailure(unavailableController.fork({
      sessionId: SessionId('missing'),
    }), 'session-not-found')
    await withoutPersistence.fiber.dispose()

    const missing = await baseContext()
    missing.provide('workspaceRegistry', { list: () => [] } as never)
    missing.provide('sessionPersistence', testSessionPersistence(missing, {
      list: () => Promise.resolve([]),
      inspect: vi.fn(),
    }) as never)
    const missingController = new SessionCommandController(missing, controllerAgents(missing), '/default')
    await expectFailure(missingController.fork({
      sessionId: SessionId('missing'),
    }), 'session-not-found')
    await missing.fiber.dispose()
  })

  it('maps an observation failure to an internal fork error', async () => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { list: () => [] } as never)
    vi.spyOn(ctx.sessionQuery, 'observeSession').mockRejectedValue(new Error('storage offline'))
    const controller = new SessionCommandController(ctx, controllerAgents(ctx), '/default')

    await expectFailure(controller.fork({ sessionId: SessionId('unreadable') }), 'internal')
    await ctx.fiber.dispose()
  })

  it('rejects a Session with no completed turn', async () => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { list: () => [] } as never)
    const source = ctx.sessions.create(SessionId('empty-source'))
    const controller = new SessionCommandController(ctx, controllerAgents(ctx), '/default')

    await expectFailure(controller.fork({ sessionId: source.id }), 'fork-unavailable')
    await ctx.fiber.dispose()
  })

  it('maps lineage lookup and Agent creation failures', async () => {
    const lineage = await baseContext()
    lineage.provide('workspaceRegistry', { list: () => [] } as never)
    vi.spyOn(lineage.sessionQuery, 'traceSession')
      .mockRejectedValue(new Error('lineage unavailable'))
    const child = completedSession(lineage, 'subagent-source', '/workspace', {
      parentSession: SessionId('parent'),
      origin: 'subagent',
    })
    const lineageController = new SessionCommandController(lineage, controllerAgents(lineage), '/default')
    await expectFailure(lineageController.fork({ sessionId: child.id }), 'internal')
    await lineage.fiber.dispose()

    const creation = await baseContext()
    creation.provide('workspaceRegistry', { list: () => [] } as never)
    const source = completedSession(creation, 'creation-source', '/workspace')
    vi.spyOn(creation.agents, 'create').mockRejectedValue(new Error('factory failed'))
    const creationController = new SessionCommandController(creation, controllerAgents(creation), '/default')
    await expectFailure(creationController.fork({ sessionId: source.id }), 'internal')
    await creation.fiber.dispose()
  })

  it('omits absent cwd and preset metadata before reporting Workspace attachment failure', async () => {
    const ctx = await baseContext()
    const source = completedSession(ctx, 'workspace-source')
    const workspace = {
      id: 'workspace-1' as WorkspaceId,
      sessionIds: [source.id],
      attachSession: () => Promise.reject(new Error('workspace write failed')),
    } as unknown as Workspace
    ctx.provide('workspaceRegistry', { list: () => [workspace] } as never)
    const create = vi.spyOn(ctx.agents, 'create').mockImplementation(
      (options: CreateAgentOptions) => Promise.resolve(resolvedHandle(ctx, options.sessionId)),
    )
    const controller = new SessionCommandController(ctx, controllerAgents(ctx), '/default')

    await expectFailure(controller.fork({ sessionId: source.id }), 'workspace-attach-failed')
    const options = create.mock.calls[0]?.[0]
    if (options === undefined) throw new Error('Agent creation was not attempted')
    expect(options.meta).not.toHaveProperty('cwd')
    expect(options.meta).not.toHaveProperty('agentPreset')
    await ctx.fiber.dispose()
  })

  it('carries the composed Agent preset into the child metadata', async () => {
    const ctx = await baseContext()
    ctx.provide('workspaceRegistry', { list: () => [] } as never)
    const source = completedSession(ctx, 'preset-source', '/workspace')
    const create = vi.spyOn(ctx.agents, 'create').mockImplementation(
      (options: CreateAgentOptions) => Promise.resolve(resolvedHandle(ctx, options.sessionId)),
    )
    const controller = new SessionCommandController(ctx, controllerAgents(ctx, {
      composeAgent: () => Promise.resolve({ agentPreset: 'minimal', setup: () => {} }),
    }), '/default')

    const forked = await controller.fork({ sessionId: source.id })
    expect(forked.sessionId).toMatch(/^session-/)
    const options = create.mock.calls[0]?.[0]
    if (options === undefined) throw new Error('Agent creation was not attempted')
    expect(options.meta?.agentPreset).toBe('minimal')
    await ctx.fiber.dispose()
  })
})

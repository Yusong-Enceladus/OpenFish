import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import { CredentialProvider } from '@deepseek-ai/dsh-credentials'
import type { CredentialInfo, CredentialRef, ResolvedCredential } from '@deepseek-ai/dsh-credentials'
import { HarnessService, type HarnessId } from '@deepseek-ai/dsh-harness'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import SandboxProvider from '@deepseek-ai/dsh-sandbox'
import type { ConfinedArgv, SandboxPolicy } from '@deepseek-ai/dsh-sandbox'
import SandboxPolicyService from '@deepseek-ai/dsh-sandbox-policy'
import { afterEach, describe, expect, it, vi } from 'vitest'
import LocalSubprocessRuntime from '../../../subprocess/subprocess-local/src/index.ts'
import { parseHarnessPack } from '../../harness/src/manifest.ts'
import { AcpHarnessAgent } from '../src/agent.ts'
import * as AcpHarnessDriver from '../src/index.ts'

const fixture = fileURLToPath(new URL('./fixtures/unknown-acp-server.ts', import.meta.url))
const evidence = [{ kind: 'declared' as const, source: 'Synthetic future ACP fixture', version: '1' }]
const pack = parseHarnessPack({
  schemaVersion: 0,
  id: 'future.synthetic-acp',
  name: 'Future Synthetic ACP',
  version: '9.4.1',
  publisher: 'Future Community',
  verified: false,
  protocol: 'acp',
  source: 'user',
  distribution: {
    kind: 'executable',
    command: process.execPath,
    args: ['--experimental-strip-types', fixture],
    env: {},
  },
  modelConfiguration: { owner: 'harness', required: true, detail: 'Discovered from the live ACP session.' },
  graph: {
    level: 'composable',
    manifestVersion: 1,
    boundary: 'Future community Harness',
    evidence,
    nodes: [
      { id: 'protocol', kind: 'protocol-adapter', title: 'ACP boundary', responsibility: 'Connects Open Fish to the Harness.', editable: false, evidence, observes: ['protocol.ready'] },
      { id: 'session', kind: 'agent-session', title: 'Session', responsibility: 'Owns the durable remote session.', editable: false, evidence, observes: ['session.ready', 'turn.started', 'turn.completed', 'turn.failed'] },
      {
        id: 'model', kind: 'model-router', title: 'Model route', responsibility: 'Selects a live Harness model.', editable: true, evidence,
        observes: ['model.completed'],
        configSchema: { version: 1, fields: [{
          id: 'model', name: 'Model', type: 'string', required: true,
          binding: { kind: 'acp-session-option', target: 'model' },
        }] },
        // This is intentionally not the fixture's protocol default. The E2E
        // proves a visual typed control changes real ACP session behavior.
        config: { model: 'future/model-b' },
      },
      { id: 'output', kind: 'output', title: 'Response', responsibility: 'Streams output to Open Fish.', editable: false, evidence, observes: ['output.activity'] },
    ],
    edges: [
      { from: 'protocol', to: 'session', observes: ['session.ready'] },
      { from: 'session', to: 'model', observes: ['turn.started', 'model.completed'] },
      { from: 'model', to: 'output', observes: ['output.activity', 'turn.completed'] },
    ],
  },
})

function packWithEnvironment(environment: Record<string, string>) {
  return parseHarnessPack({
    ...pack,
    distribution: {
      ...pack.distribution,
      env: { ...pack.distribution?.env, ...environment },
    },
  })
}

const fibers: Array<{ dispose(): unknown }> = []
afterEach(async () => {
  while (fibers.length > 0) await fibers.pop()?.dispose()
  vi.unstubAllGlobals()
})

class EmptyCredentials extends CredentialProvider {
  override resolve(_ref: CredentialRef): Promise<ResolvedCredential | undefined> { return Promise.resolve(undefined) }
  override describe(_ref: CredentialRef): Promise<CredentialInfo> {
    return Promise.resolve({ configured: false, writable: true })
  }
  override set(_ref: CredentialRef, _value: string): Promise<void> { return Promise.resolve() }
  override unset(_ref: CredentialRef): Promise<void> { return Promise.resolve() }
}

/** Protocol tests exercise the Driver; resident isolation has its own real-provider E2E suite. */
class FullTestSandbox extends SandboxProvider {
  confine(argv: readonly string[], _policy: SandboxPolicy): ConfinedArgv {
    return { argv: [...argv], enforcement: 'full', denialSignatures: [], runnerFailureRules: [] }
  }
}

async function runtime() {
  const ctx = new Context()
  void new SessionStore(ctx)
  void new AgentRegistry(ctx)
  void new ApprovalService(ctx, { policy: 'never' })
  fibers.push(await ctx.plugin(FullTestSandbox))
  fibers.push(await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write' }))
  fibers.push(await ctx.plugin(LocalSubprocessRuntime))
  return ctx
}

function prompt(text: string) {
  return createUserMessage({ content: [{ type: 'text', text }], source: { kind: 'user' } })
}

describe('unknown ACP Harness end-to-end contract', () => {
  it('serializes interdependent writes and adopts an on-wire result even when its caller cancels', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-acp-config-'))
    const delayedPack = packWithEnvironment({ OPENFISH_ACP_CONFIG_DELAY_MS: '30' })
    try {
      const session = ctx.sessions.create(SessionId('future-config-serialization'), { meta: { cwd: noProject } })
      const agent = new AcpHarnessAgent(
        ctx, session.id, session, delayedPack, noProject, join(noProject, 'runtime'),
      )
      await agent.start()
      agent.commitSelection()

      const first = agent.selectHarnessModel('future/model-a', 'quick')
      const second = agent.selectHarnessModel('future/model-b')
      await expect(first).resolves.toEqual({ model: 'future/model-a', reasoningEffort: 'quick' })
      await expect(second).resolves.toEqual({ model: 'future/model-b', reasoningEffort: 'quick' })
      expect(agent.harnessModelCatalog()).toMatchObject({
        current: 'future/model-b', currentReasoningEffort: 'quick',
      })

      const controller = new AbortController()
      const cancelled = agent.selectHarnessConfig('reasoning', 'deep', controller.signal)
      setTimeout(() => { controller.abort(new DOMException('picker closed', 'AbortError')) }, 5)
      await expect(cancelled).rejects.toMatchObject({ name: 'AbortError' })
      expect(agent.harnessModelCatalog()).toMatchObject({
        current: 'future/model-b', currentReasoningEffort: 'deep',
      })
      await agent.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('starts, discovers controls, sends, persists identity, and resumes without Harness-specific code', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-no-project-'))
    try {
      const firstSession = ctx.sessions.create(SessionId('future-first'), { meta: { cwd: noProject } })
      const first = new AcpHarnessAgent(
        ctx, firstSession.id, firstSession, pack, noProject, join(noProject, 'runtime-first'),
      )
      await first.start()
      await first.applyPackConfiguration()
      first.commitSelection()

      expect(first.harnessModelCatalog()).toEqual({
        current: 'future/model-b',
        currentReasoningEffort: 'deep',
        models: [
          { id: 'future/model-a', name: 'Future Model A' },
          {
            id: 'future/model-b', name: 'Future Model B',
            reasoning: {
              defaultEffort: 'deep',
              efforts: [{ id: 'quick', name: 'Quick' }, { id: 'deep', name: 'Deep' }],
            },
          },
        ],
      })
      first.followup(prompt('hello'))
      await first.whenIdle()

      expect(firstSession.events.findLast(event => event.type === 'harness/selected')?.data).toEqual({
        harnessId: 'future.synthetic-acp',
        version: '9.4.1',
        protocol: 'acp',
        capabilities: [],
        remoteSessionId: 'future-remote-session',
      })
      const firstAssistant = firstSession.events.findLast(event => event.type === 'assistant/message')
      expect(firstAssistant?.data.message.content).toContainEqual({ type: 'text', text: 'future:hello' })
      expect(firstAssistant?.data.message.source).toEqual({ kind: 'model', provider: 'harness', model: 'future/model-b' })
      const observedNodeIds = firstSession.events
        .filter(event => event.type === 'harness/runtime-node')
        .map(event => event.data.nodeId)
      expect(new Set(observedNodeIds)).toEqual(new Set(['protocol', 'session', 'model', 'output']))
      await first.dispose()

      const resumedSession = ctx.sessions.create(SessionId('future-resumed'), { meta: { cwd: noProject } })
      const resumed = new AcpHarnessAgent(
        ctx, resumedSession.id, resumedSession, pack, noProject, join(noProject, 'runtime-resumed'),
      )
      await resumed.start('future-remote-session')
      resumed.commitSelection()
      resumed.followup(prompt('again'))
      await resumed.whenIdle()

      expect(resumedSession.events.findLast(event => event.type === 'harness/selected')?.data.remoteSessionId)
        .toBe('future-remote-session')
      expect(resumedSession.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'future:again' })
      await resumed.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('runs a user-authored Pack through managed install, preflight, default selection, and No Project creation', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-custom-pack-state-'))
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-custom-pack-no-project-'))
    const ctx = new Context()
    try {
      void new SessionStore(ctx)
      void new AgentRegistry(ctx)
      void new ApprovalService(ctx, { policy: 'never' })
      void new EmptyCredentials(ctx)
      void new HarnessService(ctx, { stateDir })
      ctx.provide('userQuestions', {} as never)
      ctx.provide('attachments', {} as never)
      await ctx.plugin(FullTestSandbox)
      await ctx.plugin(SandboxPolicyService, { mode: 'workspace-write' })
      await ctx.plugin(LocalSubprocessRuntime)
      await ctx.plugin(AcpHarnessDriver)

      const authored = await ctx.harnesses.upsert(pack)
      expect(authored).toMatchObject({
        id: 'future.synthetic-acp', source: 'user', verified: false,
        graph: { level: 'composable', manifestVersion: 1 },
      })
      const customHarness = 'future.synthetic-acp' as HarnessId
      await ctx.harnesses.install(customHarness)
      await ctx.harnesses.probe(customHarness)
      await ctx.harnesses.selectDefault(customHarness)

      const catalog = await ctx.harnesses.list()
      expect(catalog.find(item => item.id === 'future.synthetic-acp')).toMatchObject({
        isDefault: true,
        installation: { status: 'installed', installedVersion: '9.4.1' },
        compatibility: { status: 'compatible', classification: 'supported' },
        driver: { apiVersion: 1, protocol: 'acp', loaded: true, authorization: 'not-required' },
      })

      const agent = await ctx.harnesses.create(
        customHarness, SessionId('custom-pack-first'), noProject,
      ) as AcpHarnessAgent
      expect(agent.session.header.cwd).toBe(noProject)
      expect(agent.harnessModelCatalog()?.models.map(model => model.id)).toEqual([
        'future/model-a', 'future/model-b',
      ])
      await agent.selectHarnessModel('future/model-a', 'quick')
      agent.followup(prompt('created-by-user'))
      await agent.whenIdle()

      expect(agent.session.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'future:created-by-user' })
      expect(agent.session.events.findLast(event => event.type === 'harness/selected')?.data).toMatchObject({
        harnessId: 'future.synthetic-acp', version: '9.4.1', protocol: 'acp',
      })
      expect(new Set(agent.session.events
        .filter(event => event.type === 'harness/runtime-node')
        .map(event => event.data.nodeId)))
        .toEqual(new Set(['protocol', 'session', 'model', 'output']))

      const compatible = (await ctx.harnesses.list()).find(item => item.id === 'future.synthetic-acp')
      expect(compatible?.compatibility.status).toBe('compatible')
      expect(await ctx.harnesses.defaultId()).toBe('future.synthetic-acp')
    } finally {
      await ctx.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
      await rm(noProject, { recursive: true, force: true })
    }
  })
})

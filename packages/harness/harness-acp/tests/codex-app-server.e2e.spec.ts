import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import { CredentialProvider } from '@deepseek-ai/dsh-credentials'
import type {
  CredentialInfo,
  CredentialKey,
  CredentialRecord,
  CredentialRecordEntry,
  CredentialRecordInfo,
  CredentialRef,
  ResolvedCredential,
} from '@deepseek-ai/dsh-credentials'
import { HarnessService, type HarnessAuthMethod, type HarnessId } from '@deepseek-ai/dsh-harness'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import SandboxProvider from '@deepseek-ai/dsh-sandbox'
import type { ConfinedArgv, SandboxPolicy } from '@deepseek-ai/dsh-sandbox'
import SandboxPolicyService from '@deepseek-ai/dsh-sandbox-policy'
import { afterEach, describe, expect, it, vi } from 'vitest'
import LocalSubprocessRuntime from '../../../subprocess/subprocess-local/src/index.ts'
import { parseHarnessPack } from '../../harness/src/manifest.ts'
import { CodexHarnessAgent, codexAuthenticationEnvironment } from '../src/codex-agent.ts'
import * as AcpHarnessDriver from '../src/index.ts'

const fixture = fileURLToPath(new URL('./fixtures/codex-app-server.ts', import.meta.url))
const evidence = [{ kind: 'resolved' as const, source: 'Synthetic official app-server fixture', version: '1' }]
const pack = parseHarnessPack({
  schemaVersion: 0,
  id: 'codex', name: 'Codex', version: 'test', publisher: 'OpenAI', verified: true,
  protocol: 'codex-app-server', source: 'builtin',
  distribution: { kind: 'executable', command: process.execPath, args: ['--experimental-strip-types', fixture], env: {} },
  modelConfiguration: { owner: 'harness', required: true, detail: 'Discovered from official model/list.' },
  graph: {
    level: 'observable', manifestVersion: 1, boundary: 'Codex app-server', evidence,
    nodes: [
      { id: 'app-server', kind: 'protocol-adapter', title: 'App-server', responsibility: 'Owns the protocol.', editable: false, evidence },
      { id: 'thread', kind: 'agent-session', title: 'Thread & turn', responsibility: 'Owns durable state.', editable: false, evidence },
      { id: 'context', kind: 'context-runtime', title: 'Context', responsibility: 'Builds input.', editable: false, evidence },
      { id: 'model', kind: 'model-client', title: 'Model', responsibility: 'Runs inference.', editable: false, evidence },
      { id: 'output', kind: 'output-stream', title: 'Output', responsibility: 'Streams responses.', editable: false, evidence },
    ],
    edges: [
      { from: 'app-server', to: 'thread' }, { from: 'thread', to: 'context' },
      { from: 'context', to: 'model' }, { from: 'model', to: 'output' },
    ],
  },
})
const servicePack = parseHarnessPack({
  ...pack,
  id: 'future.synthetic-codex',
  name: 'Future Synthetic Codex Driver Pack',
  verified: false,
  source: 'user',
})

const fibers: Array<{ dispose(): unknown }> = []
afterEach(async () => {
  while (fibers.length > 0) await fibers.pop()?.dispose()
  vi.unstubAllGlobals()
})

class EmptyCredentials extends CredentialProvider {
  constructor(ctx: Context, private readonly values: Readonly<Record<string, string>> = {}) { super(ctx) }
  override resolve(ref: CredentialRef): Promise<ResolvedCredential | undefined> {
    const value = this.values[String(ref)]
    return Promise.resolve(value === undefined ? undefined : { value, source: 'test' })
  }
  override describe(_ref: CredentialRef): Promise<CredentialInfo> {
    return Promise.resolve({ configured: false, writable: true })
  }
  override set(_ref: CredentialRef, _value: string): Promise<void> { return Promise.resolve() }
  override unset(_ref: CredentialRef): Promise<void> { return Promise.resolve() }
  override readRecord(_key: CredentialKey): Promise<CredentialRecord | undefined> { return Promise.resolve(undefined) }
  override describeRecord(_key: CredentialKey): Promise<CredentialRecordInfo> {
    return Promise.resolve({ configured: false, writable: true })
  }
  override listRecords(): Promise<readonly CredentialRecordEntry[]> { return Promise.resolve([]) }
  override modifyRecord(
    _key: CredentialKey,
    mutate: (current: CredentialRecord | undefined) => Promise<CredentialRecord | undefined>,
  ): Promise<CredentialRecord | undefined> { return mutate(undefined) }
  override deleteRecord(_key: CredentialKey): Promise<void> { return Promise.resolve() }
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

describe('official Codex app-server Harness contract', () => {
  it('copies a custom CA file into the private runtime before exposing its environment path', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-codex-ca-'))
    const source = join(root, 'selected-ca.pem')
    const runtimeDirectory = join(root, 'runtime')
    const pem = '-----BEGIN CERTIFICATE-----\nsynthetic-public-certificate\n-----END CERTIFICATE-----\n'
    await writeFile(source, pem, { mode: 0o644 })
    const ctx = new Context()
    void new EmptyCredentials(ctx, {
      OPENFISH_CODEX_CA_CERTIFICATE: source,
      OPENAI_API_KEY: 'synthetic-test-key',
    })
    fibers.push(ctx.fiber)
    const method: HarnessAuthMethod = {
      id: 'codex-api-key', name: 'API key', kind: 'environment',
      fields: [
        { ref: 'OPENAI_API_KEY', name: 'API key', env: 'OPENAI_API_KEY', required: true, secret: true },
        {
          ref: 'OPENFISH_CODEX_CA_CERTIFICATE', name: 'Custom CA', env: 'CODEX_CA_CERTIFICATE',
          required: false, secret: false,
        },
      ],
    }
    try {
      const environments = await Promise.all(Array.from(
        { length: 8 },
        () => codexAuthenticationEnvironment(ctx, method, runtimeDirectory),
      ))
      const [environment] = environments
      expect(environment).toBeDefined()
      if (environment === undefined) throw new Error('Codex CA environment was not produced')
      expect(new Set(environments.map(item => item.CODEX_CA_CERTIFICATE)).size).toBe(1)
      expect(environment.OPENAI_API_KEY).toBe('synthetic-test-key')
      expect(environment.CODEX_CA_CERTIFICATE).not.toBe(source)
      expect(environment.CODEX_CA_CERTIFICATE?.startsWith(runtimeDirectory)).toBe(true)
      expect(await readFile(environment.CODEX_CA_CERTIFICATE as string, 'utf8')).toBe(pem)
      expect((await stat(environment.CODEX_CA_CERTIFICATE as string)).mode & 0o777).toBe(0o600)
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('permanently discards the exact prepared blank thread through official thread/delete', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-codex-discard-'))
    const trace = join(noProject, 'app-server-methods.log')
    const tracedPack = parseHarnessPack({
      ...pack,
      distribution: {
        ...pack.distribution,
        env: { OPENFISH_CODEX_FIXTURE_TRACE: trace },
      },
    })
    try {
      const session = ctx.sessions.create(SessionId('codex-blank-discard'), { meta: { cwd: noProject } })
      const agent = new CodexHarnessAgent(
        ctx, session.id, session, tracedPack, noProject, join(noProject, 'runtime'),
      )
      await agent.start()
      await agent.deleteCurrentRemoteThread()
      await agent.dispose()
      const methods = (await readFile(trace, 'utf8')).trim().split('\n')
      expect(methods).toContain('thread/start')
      expect(methods).toContain('thread/delete')
      expect(methods).not.toContain('turn/start')
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('discovers per-model effort, runs with No Project, persists, and resumes', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-codex-no-project-'))
    try {
      const firstSession = ctx.sessions.create(SessionId('codex-first'), { meta: { cwd: noProject } })
      const first = new CodexHarnessAgent(
        ctx, firstSession.id, firstSession, pack, noProject, join(noProject, 'runtime-first'),
      )
      await first.start()
      first.commitSelection()
      expect(first.harnessModelCatalog()).toEqual({
        current: 'gpt-test', currentReasoningEffort: 'medium',
        account: {
          label: 'ChatGPT · Pro',
          billing: 'subscription',
          detail: 'The official Codex app-server reports ChatGPT authentication (Pro). Requests use that Codex plan; OpenFish receives no token or email.',
        },
        models: [{
          id: 'gpt-test', name: 'GPT Test', description: 'Synthetic official model',
          providerId: 'openai', providerName: 'OpenAI',
          reasoning: {
            defaultEffort: 'medium',
            efforts: [
              { id: 'low', name: 'Low', description: 'Fast' },
              { id: 'medium', name: 'Medium', description: 'Balanced' },
              { id: 'high', name: 'High', description: 'Deep' },
            ],
          },
        }],
      })
      expect(JSON.stringify(first.harnessModelCatalog())).not.toContain('fixture@example.invalid')
      await first.selectHarnessModel('gpt-test', 'high')
      first.followup(prompt('hello'))
      await first.whenIdle()
      expect(firstSession.header.cwd).toBe(noProject)
      expect(firstSession.events.findLast(event => event.type === 'harness/selected')?.data).toEqual({
        harnessId: 'codex', version: 'test', protocol: 'codex-app-server',
        capabilities: [], remoteSessionId: 'official-codex-thread',
      })
      expect(firstSession.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:hello' })
      expect(firstSession.events.findLast(event => event.type === 'assistant/message')?.data.message.source)
        .toEqual({ kind: 'model', provider: 'harness', model: 'gpt-test' })
      await first.dispose()

      const resumedSession = ctx.sessions.create(SessionId('codex-resumed'), { meta: { cwd: noProject } })
      const resumed = new CodexHarnessAgent(
        ctx, resumedSession.id, resumedSession, pack, noProject, join(noProject, 'runtime-resumed'),
      )
      await resumed.start('official-codex-thread')
      resumed.commitSelection()
      resumed.followup(prompt('again'))
      await resumed.whenIdle()
      expect(resumedSession.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:again' })
      await resumed.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('recovers the exact pinned thread after an app-server crash without replaying the uncertain prompt', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-codex-crash-recovery-'))
    const marker = join(noProject, 'crashed-once')
    const trace = join(noProject, 'app-server-methods.log')
    const crashPack = parseHarnessPack({
      ...pack,
      distribution: {
        ...pack.distribution,
        env: {
          OPENFISH_CODEX_FIXTURE_CRASH_ONCE_MARKER: marker,
          OPENFISH_CODEX_FIXTURE_TRACE: trace,
        },
      },
    })
    try {
      const session = ctx.sessions.create(SessionId('codex-crash-recovery'), { meta: { cwd: noProject } })
      const agent = new CodexHarnessAgent(
        ctx, session.id, session, crashPack, noProject, join(noProject, 'runtime'),
      )
      await agent.start()
      agent.commitSelection()
      await agent.selectHarnessModel('gpt-test', 'low')

      agent.followup(prompt('uncertain operation'))
      await agent.whenIdle()
      expect(session.events.filter(event => event.type === 'assistant/message')).toHaveLength(0)
      expect(session.events.findLast(event => event.type === 'turn/end')?.data.reason).toMatchObject({
        kind: 'error',
        error: { code: 'CODEX_APP_SERVER_ERROR' },
      })
      expect(JSON.stringify(session.events.findLast(event => event.type === 'turn/end')))
        .toContain('retry this turn because the interrupted prompt may have reached Codex')

      agent.followup(prompt('safe retry'))
      await agent.whenIdle()
      expect(agent.harnessModelCatalog()).toMatchObject({
        current: 'gpt-test', currentReasoningEffort: 'low',
      })
      expect(session.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:safe retry' })
      const methods = (await readFile(trace, 'utf8')).trim().split('\n')
      expect(methods.filter(method => method === 'turn/start')).toHaveLength(2)
      expect(methods.filter(method => method === 'thread/resume')).toHaveLength(1)
      await agent.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('preserves the visible model and effort while permissions restart the pinned Codex thread', async () => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-codex-permission-change-'))
    const trace = join(noProject, 'app-server-methods.log')
    const tracedPack = parseHarnessPack({
      ...pack,
      distribution: {
        ...pack.distribution,
        env: { OPENFISH_CODEX_FIXTURE_TRACE: trace },
      },
    })
    try {
      const session = ctx.sessions.create(SessionId('codex-permission-change'), { meta: { cwd: noProject } })
      const agent = new CodexHarnessAgent(
        ctx, session.id, session, tracedPack, noProject, join(noProject, 'runtime'),
      )
      await agent.start()
      agent.commitSelection()
      await agent.selectHarnessModel('gpt-test', 'low')

      await agent.sandboxAuthority.reconfigure('read-only')
      expect(agent.sandboxAuthority.mode).toBe('read-only')
      expect(agent.harnessModelCatalog()).toMatchObject({
        current: 'gpt-test', currentReasoningEffort: 'low',
      })
      expect(session.events.filter(event => event.type === 'harness/selected')).toHaveLength(1)

      agent.followup(prompt('after permission change'))
      await agent.whenIdle()
      expect(session.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:after permission change' })
      const methods = (await readFile(trace, 'utf8')).trim().split('\n')
      expect(methods.filter(method => method === 'thread/resume')).toHaveLength(1)
      await agent.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it.each([
    ['auth-expired', 'authentication expired'],
    ['quota-failure', 'provider quota exceeded'],
  ])('surfaces a redacted Codex %s failure and keeps the thread usable', async (failurePrompt, expected) => {
    const ctx = await runtime()
    const noProject = await mkdtemp(join(tmpdir(), `openfish-codex-${failurePrompt}-`))
    try {
      const session = ctx.sessions.create(SessionId(`codex-${failurePrompt}`), { meta: { cwd: noProject } })
      const agent = new CodexHarnessAgent(
        ctx, session.id, session, pack, noProject, join(noProject, 'runtime'),
      )
      await agent.start()
      agent.commitSelection()

      agent.followup(prompt(failurePrompt))
      await agent.whenIdle()
      const failure = session.events.findLast(event => event.type === 'turn/end')
      expect(failure?.data.reason).toMatchObject({
        kind: 'error',
        error: { code: 'CODEX_APP_SERVER_ERROR', message: expect.stringContaining(expected) as unknown },
      })
      expect(JSON.stringify(failure)).not.toContain('sk-test-supersecret123456')

      agent.followup(prompt('after provider failure'))
      await agent.whenIdle()
      expect(session.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:after provider failure' })
      await agent.dispose()
    } finally {
      await rm(noProject, { recursive: true, force: true })
    }
  })

  it('creates a true app-server fork through the public Driver contract', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-codex-fork-state-'))
    const noProject = await mkdtemp(join(tmpdir(), 'openfish-codex-fork-project-'))
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

      await ctx.harnesses.upsert(servicePack)
      const harnessId = 'future.synthetic-codex' as HarnessId
      await ctx.harnesses.install(harnessId)
      const source = await ctx.harnesses.create(
        harnessId, SessionId('codex-fork-source'), noProject, 'no-project',
      ) as CodexHarnessAgent
      source.followup(prompt('before fork'))
      await source.whenIdle()

      const child = await ctx.harnesses.fork(
        harnessId,
        source.id,
        SessionId('codex-fork-child'),
        noProject,
        [...source.session.events],
        servicePack.version,
        undefined,
        'no-project',
      ) as CodexHarnessAgent
      expect(child.session.header).toMatchObject({
        parentSession: source.id,
        cwd: noProject,
      })
      expect(child.session.events.findLast(event => event.type === 'harness/remote-session')?.data).toEqual({
        harnessId,
        remoteSessionId: 'official-codex-fork',
        reason: 'session-fork',
      })
      child.followup(prompt('after fork'))
      await child.whenIdle()
      expect(child.session.events.findLast(event => event.type === 'assistant/message')?.data.message.content)
        .toContainEqual({ type: 'text', text: 'codex:after fork' })
    } finally {
      await ctx.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
      await rm(noProject, { recursive: true, force: true })
    }
  })
})

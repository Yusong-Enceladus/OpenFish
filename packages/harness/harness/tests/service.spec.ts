import { lstat, mkdir, mkdtemp, readFile, readdir, rm, symlink, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { homedir, tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { builtInHarnessPacks, HarnessService } from '../src/index.ts'
import type { Agent } from '@deepseek-ai/dsh-agent'
import SessionStore, { type SessionEvent } from '@deepseek-ai/dsh-session'
import type { HarnessDriver, HarnessForkRequest, HarnessPack, HarnessSessionRequest } from '../src/types.ts'

function pack(version: string): unknown {
  const evidence = [{ kind: 'declared', source: 'Harness test fixture', version }]
  return {
    schemaVersion: 0, id: 'community.driver-demo', name: 'Driver demo', version, publisher: 'Community',
    verified: false, protocol: 'community-protocol',
    driverBundle: {
      apiVersion: 1, package: '@community/openfish-driver-demo',
      spec: '@community/openfish-driver-demo@1.0.0', requiresInstallScripts: false,
    },
    authMethods: [{
      id: 'local-login', name: 'Local login', kind: 'agent', fields: [],
      account: { label: 'Local account', billing: 'local', detail: 'No external model billing.' },
    }],
    distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
    graph: {
      level: 'composable',
      manifestVersion: 1,
      boundary: 'Driver demo Harness process',
      evidence,
      nodes: [
        { id: 'input', kind: 'input', title: 'Input', editable: false, responsibility: 'Accepts user intent.', evidence, position: { x: 10, y: 20 } },
        { id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false, responsibility: 'Runs the agent loop.', evidence },
        { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes session updates.', evidence },
      ],
      edges: [{ from: 'input', to: 'runtime' }, { from: 'runtime', to: 'output' }],
    },
    source: 'user',
  }
}

async function authorizePackDriver(
  service: HarnessService,
  id = 'community.driver-demo',
  version?: string,
): Promise<void> {
  const catalog = service.require(id as never)
  const candidate = version === undefined || catalog.version === version
    ? catalog
    : await service.describe(id as never, version)
  if (candidate.driverBundle === undefined) return
  await service.authorizeDriverBundle(
    id as never,
    candidate.version,
    candidate.driverBundle.package,
    candidate.driverBundle.spec,
  )
}

async function contextWithSessions(): Promise<Context> {
  const context = new Context()
  await context.plugin(SessionStore)
  return context
}

function publishDriverAgent(
  context: Context,
  request: HarnessSessionRequest | HarnessForkRequest,
  candidate: HarnessPack,
): Agent {
  const existing = context.sessions.get(request.sessionId)
  if (existing !== undefined) return { id: request.sessionId, session: existing } as Agent
  const seed = 'seed' in request ? request.seed : undefined
  const session = context.sessions.create(request.sessionId, {
    ...(seed === undefined ? {} : { seed }),
    meta: { cwd: request.cwd },
  })
  if (session.events.findLast(event => event.type === 'harness/selected') === undefined) {
    session.append('harness/selected', {
      harnessId: candidate.id,
      version: candidate.version,
      protocol: candidate.protocol,
      ...(request.authMethod === undefined ? {} : { authMethod: request.authMethod }),
      ...(request.workspaceMode === undefined ? {} : { workspaceMode: request.workspaceMode }),
      ...(request.capabilities === undefined ? {} : { capabilities: [...request.capabilities] }),
    })
  }
  return { id: request.sessionId, session } as Agent
}

describe('Harness lifecycle and Driver SDK', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('persists custom Packs, install snapshots, rollback, auth, and the cross-device default', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-state-'))
    const installed: string[] = []
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async (candidate: HarnessPack) => { installed.push(candidate.version) },
      discoverAuth: async () => [{ id: 'local-login', name: 'Discovered local login', kind: 'agent', fields: [] }],
      create: async () => { throw new Error('not used') },
      resume: async () => { throw new Error('not used') },
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.upsert(pack('2.0.0'))
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      await service.selectDefault('community.driver-demo' as never)
      await service.rollback('community.driver-demo' as never)

      const row = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(installed).toEqual(['1.0.0', '2.0.0'])
      expect(row).toMatchObject({
        isDefault: true,
        version: '1.0.0',
        installation: { status: 'installed', installedVersion: '1.0.0', availableVersion: '2.0.0', previousVersions: ['2.0.0'] },
        auth: {
          selectedMethod: 'local-login',
          methods: [{ name: 'Discovered local login', account: { label: 'Local account', billing: 'local' } }],
        },
        graph: { level: 'composable' },
        compatibility: { classification: 'experimental' },
      })

      const restored = new HarnessService(new Context(), { stateDir })
      restored.registerDriver(driver)
      const restoredRow = (await restored.list()).find(item => item.id === 'community.driver-demo')
      expect(restoredRow).toMatchObject({ isDefault: true, version: '1.0.0', installation: { installedVersion: '1.0.0' }, source: 'user' })
      const stored = JSON.parse(await readFile(join(stateDir, 'state.json'), 'utf8')) as { version: number }
      expect(stored.version).toBe(7)
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('requires loopback-authorized exact Driver code and never reuses a protocol proof across bundle updates', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-driver-authorization-'))
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await expect(service.install('community.driver-demo' as never)).rejects.toThrow('activate and authorize')
      await expect(service.authorizeDriverBundle(
        'community.driver-demo' as never, '1.0.0',
        '@community/openfish-driver-demo', '@community/openfish-driver-demo@9.9.9',
      )).rejects.toThrow('does not match')
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)

      const next = pack('2.0.0') as Record<string, unknown>
      next.driverBundle = {
        apiVersion: 1, package: '@community/openfish-driver-demo',
        spec: '@community/openfish-driver-demo@2.0.0', requiresInstallScripts: false,
      }
      await service.upsert(next)
      await expect(service.install('community.driver-demo' as never)).rejects.toThrow('@community/openfish-driver-demo@2.0.0')
      await authorizePackDriver(service, 'community.driver-demo', '2.0.0')
      await service.install('community.driver-demo' as never)
      await expect(service.resume(
        'community.driver-demo' as never,
        'old-task' as never,
        join(stateDir, 'no-project', 'old-task'),
        '1.0.0',
      )).rejects.toThrow('@community/openfish-driver-demo@1.0.0')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('removes private runtime state on uninstall and never follows a replaced Harness link', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-remove-runtime-'))
    const protectedDirectory = await mkdtemp(join(tmpdir(), 'openfish-protected-'))
    const context = new Context()
    await context.plugin(SessionStore)
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async (_candidate, _installationDirectory, runtimeDirectory) => {
        await mkdir(runtimeDirectory, { recursive: true, mode: 0o700 })
        await writeFile(join(runtimeDirectory, 'private-login-state.json'), '{}', { mode: 0o600 })
      },
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      const installDirectory = join(stateDir, 'installed', 'community.driver-demo')
      const runtimeDirectory = join(stateDir, 'runtime', 'community.driver-demo')
      expect(await readFile(join(runtimeDirectory, '1.0.0', 'private-login-state.json'), 'utf8')).toBe('{}')

      await service.uninstall('community.driver-demo' as never)
      await expect(lstat(installDirectory)).rejects.toMatchObject({ code: 'ENOENT' })
      await expect(lstat(runtimeDirectory)).rejects.toMatchObject({ code: 'ENOENT' })

      await service.install('community.driver-demo' as never)
      await writeFile(join(protectedDirectory, 'keep.txt'), 'outside Harness state')
      await rm(runtimeDirectory, { recursive: true, force: true })
      await symlink(protectedDirectory, runtimeDirectory, 'dir')
      await service.removeUserPack('community.driver-demo' as never)

      await expect(lstat(runtimeDirectory)).rejects.toMatchObject({ code: 'ENOENT' })
      expect(await readFile(join(protectedDirectory, 'keep.txt'), 'utf8')).toBe('outside Harness state')
      expect((await service.list()).some(item => item.id === 'community.driver-demo')).toBe(false)
    } finally {
      await context.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
      await rm(protectedDirectory, { recursive: true, force: true })
    }
  })

  it('supplements Pack-declared account setup with live authentication discovery', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-auth-merge-'))
    const declared = pack('1.0.0') as Record<string, unknown>
    declared.authMethods = [
      ...((declared.authMethods as HarnessPack['authMethods']) ?? []),
      {
        id: 'provider-picker', name: 'Sign in to a provider', kind: 'terminal', fields: [],
        terminal: { args: ['auth', 'login'], env: {} },
        account: { label: 'Harness provider', billing: 'harness-managed', detail: 'The Harness owns provider login.' },
      },
    ]
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      discoverAuth: async () => [{ id: 'local-login', name: 'Live local login', kind: 'agent', fields: [] }],
      authenticateInteractive: async () => undefined,
      missingCredentials: async () => [],
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [declared] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      const methods = (await service.list()).find(item => item.id === 'community.driver-demo')?.auth.methods
      expect(methods?.find(method => method.id === 'local-login')?.name).toBe('Live local login')
      const providerPicker = methods?.find(method => method.id === 'provider-picker')
      expect(providerPicker?.kind).toBe('terminal')
      expect(providerPicker?.account?.billing).toBe('harness-managed')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('keeps ACP Registry authentication unknown until the installed Harness reports it', async () => {
    vi.stubGlobal('fetch', vi.fn(async input => String(input).includes('community.test')
      ? new Response(JSON.stringify({ version: 0, packs: [], revocations: [] }))
      : new Response(JSON.stringify({
        version: '1.0.0',
        agents: [{
          id: 'future-registry', name: 'Future Registry', version: '3.2.1',
          distribution: { npx: { package: '@future/registry-acp' } },
        }],
      }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-runtime-auth-'))
    const context = new Context()
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'acp',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'runtime', source: 'runtime' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      discoverAuth: async () => [],
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(context, {
        stateDir,
        registryUrl: 'https://registry.test/index.json',
        communityRegistryUrl: 'https://community.test/index.json',
      })
      service.registerDriver(driver)
      await service.refresh()
      const before = (await service.list()).find(item => item.id === 'future-registry')
      expect(before?.auth).toMatchObject({
        status: 'unknown', methods: [],
        detail: expect.stringContaining('does not declare account requirements'),
      })
      await service.install('future-registry' as never)
      const after = (await service.list()).find(item => item.id === 'future-registry')
      expect(after?.auth).toMatchObject({
        status: 'not-required', methods: [],
        detail: expect.stringContaining('advertised no required sign-in method'),
      })
      await service.selectDefault('future-registry' as never)
      expect(await service.defaultId()).toBe('future-registry')
    } finally {
      await context.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('runs and resumes a new non-ACP protocol through only the public Driver contract', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-new-driver-'))
    const requests: Array<{ operation: 'create' | 'resume'; request: HarnessSessionRequest; version: string }> = []
    const disposed: Array<{ sessionId: string; version: string }> = []
    const context = await contextWithSessions()
    const agent = (request: HarnessSessionRequest, candidate: HarnessPack): Agent =>
      publishDriverAgent(context, request, candidate)
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async (request, candidate) => {
        requests.push({ operation: 'create', request, version: candidate.version })
        return agent(request, candidate)
      },
      resume: async (request, candidate) => {
        requests.push({ operation: 'resume', request, version: candidate.version })
        return agent(request, candidate)
      },
      dispose: async (sessionId, candidate) => { disposed.push({ sessionId, version: candidate.version }) },
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      const unregister = service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      const noProject = join(stateDir, 'sessions', 'no-project', 'session-driver')
      const created = await service.create('community.driver-demo' as never, 'session-driver' as never, noProject)
      expect(created.id).toBe('session-driver')

      await service.upsert(pack('2.0.0'))
      await service.install('community.driver-demo' as never)
      const resumed = await service.resume('community.driver-demo' as never, 'session-driver' as never, noProject, '1.0.0')
      expect(resumed.id).toBe('session-driver')
      expect(requests).toHaveLength(2)
      expect(requests[0]?.operation).toBe('create')
      expect(requests[0]?.version).toBe('1.0.0')
      expect(requests[0]?.request.cwd).toBe(noProject)
      expect(requests[0]?.request.authMethod).toBe('local-login')
      expect(requests[1]?.operation).toBe('resume')
      expect(requests[1]?.version).toBe('1.0.0')
      expect(requests[1]?.request.cwd).toBe(noProject)
      expect(requests[1]?.request.version).toBe('1.0.0')
      expect(requests[1]?.request.authMethod).toBe('local-login')
      expect(requests[0]?.request.installationDirectory).toContain('community.driver-demo/1.0.0')
      expect(requests[1]?.request.installationDirectory).toContain('community.driver-demo/1.0.0')
      await service.disposeSession('community.driver-demo' as never, 'session-driver' as never, '1.0.0')
      expect(disposed).toEqual([{ sessionId: 'session-driver', version: '1.0.0' }])

      unregister()
      const unavailable = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(unavailable?.available).toBe(false)
      expect(unavailable?.unavailableReason).toBe('No community-protocol driver is loaded')
      expect(unavailable?.driver).toEqual({
        apiVersion: 1, protocol: 'community-protocol', loaded: false, authorization: 'authorized',
      })
      expect(unavailable?.capabilities.find(capability => capability.id === 'builder.manifest')).toMatchObject({
        status: 'supported', source: 'host',
      })
      expect(unavailable?.capabilities.find(capability => capability.id === 'builder.test')).toMatchObject({
        status: 'unsupported', source: 'host',
      })
      expect(unavailable?.capabilities.find(capability => capability.id === 'builder.publish')).toMatchObject({
        status: 'supported', source: 'host',
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('rejects and cleans up a malformed Driver session without exposing Driver secrets', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-invalid-driver-session-'))
    const context = await contextWithSessions()
    const discarded: string[] = []
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async (request, candidate) => ({
        ...publishDriverAgent(context, request, candidate),
        id: 'sk-test-supersecret123456',
      }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
      discard: async (sessionId) => { discarded.push(String(sessionId)) },
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      let diagnostic = ''
      try {
        await service.create(
          'community.driver-demo' as never,
          'invalid-driver-session' as never,
          join(stateDir, 'no-project', 'invalid-driver-session'),
          'no-project',
        )
      } catch (error: unknown) {
        diagnostic = error instanceof Error ? error.message : String(error)
      }
      expect(discarded).toEqual(['invalid-driver-session'])
      expect(diagnostic).toContain('invalid create result')
      expect(diagnostic).toContain('[redacted]')
      expect(diagnostic).not.toContain('supersecret')
    } finally {
      await context.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('uses a Driver-owned draft discard when available and otherwise falls back to ordinary disposal', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-driver-discard-'))
    const discarded: Array<{ sessionId: string; version: string }> = []
    const disposed: Array<{ sessionId: string; version: string }> = []
    const base: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async (sessionId, candidate) => { disposed.push({ sessionId, version: candidate.version }) },
      discard: async (sessionId, candidate) => { discarded.push({ sessionId, version: candidate.version }) },
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(base)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.discardSession('community.driver-demo' as never, 'draft-one' as never, '1.0.0')
      expect(discarded).toEqual([{ sessionId: 'draft-one', version: '1.0.0' }])
      expect(disposed).toEqual([])

      const fallbackState = await mkdtemp(join(tmpdir(), 'openfish-driver-discard-fallback-'))
      try {
        const fallback = new HarnessService(new Context(), { stateDir: fallbackState, packs: [pack('1.0.0')] })
        const withoutDiscard = { ...base }
        Reflect.deleteProperty(withoutDiscard, 'discard')
        fallback.registerDriver(withoutDiscard)
        await authorizePackDriver(fallback)
        await fallback.install('community.driver-demo' as never)
        await fallback.discardSession('community.driver-demo' as never, 'draft-two' as never, '1.0.0')
        expect(disposed).toEqual([{ sessionId: 'draft-two', version: '1.0.0' }])
      } finally {
        await rm(fallbackState, { recursive: true, force: true })
      }
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('forwards session-create cancellation through an arbitrary Driver without publishing a zombie task', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-driver-cancel-'))
    let driverSignal: AbortSignal | undefined
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async (request, _candidate, signal) => {
        driverSignal = signal
        if (signal === undefined) throw new Error('Driver did not receive the caller cancellation signal')
        await new Promise<void>((_resolve, reject) => {
          const aborted = () => {
            const reason: unknown = signal.reason
            reject(reason instanceof Error ? reason : new Error('Driver request aborted'))
          }
          signal.addEventListener('abort', aborted, { once: true })
        })
        return { id: request.sessionId } as Agent
      },
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      const controller = new AbortController()
      const creating = service.create(
        'community.driver-demo' as never,
        'cancelled-driver-session' as never,
        join(stateDir, 'no-project'),
        'no-project',
        controller.signal,
      )
      await vi.waitFor(() =>{  expect(driverSignal).toBe(controller.signal) })
      controller.abort(new Error('user switched Harness'))
      await expect(creating).rejects.toThrow('user switched Harness')
      expect(driverSignal?.aborted).toBe(true)
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('forks through the source task pinned version, auth, workspace, and capability snapshot', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-driver-fork-'))
    const requests: Array<{ request: HarnessForkRequest; version: string }> = []
    const context = await contextWithSessions()
    const sourceCapabilities = [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'session.fork', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'configuration.auth', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    ] as const
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [...sourceCapabilities],
      available: async () => undefined,
      install: async () => undefined,
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      fork: async (request, candidate) => {
        requests.push({ request, version: candidate.version })
        return publishDriverAgent(context, request, candidate)
      },
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      await service.upsert(pack('2.0.0'))
      await service.install('community.driver-demo' as never)
      const seed = [{
        type: 'harness/selected', seq: 0, time: 1,
        data: {
          harnessId: 'community.driver-demo', version: '1.0.0', protocol: 'community-protocol',
          authMethod: 'local-login', workspaceMode: 'no-project', capabilities: [...sourceCapabilities],
        },
      }] as unknown as SessionEvent[]

      const child = await service.fork(
        'community.driver-demo' as never,
        'source-task' as never,
        'child-task' as never,
        join(stateDir, 'no-project', 'child-task'),
        seed,
      )

      expect(child.id).toBe('child-task')
      expect(requests).toHaveLength(1)
      expect(requests[0]).toMatchObject({
        version: '1.0.0',
        request: {
          sourceSessionId: 'source-task', sessionId: 'child-task', version: '1.0.0',
          authMethod: 'local-login', workspaceMode: 'no-project',
          capabilities: [
            ...sourceCapabilities.slice(0, 3),
            {
              id: 'session.archive', status: 'supported', source: 'host',
              detail: 'OpenFish archives the task without deleting its Harness session or durable transcript.',
            },
            ...sourceCapabilities.slice(3),
          ],
        },
      })
      expect(requests[0]?.request.installationDirectory).toContain('community.driver-demo/1.0.0')
      expect(requests[0]?.request.runtimeDirectory).toContain('community.driver-demo/1.0.0')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('keeps the active snapshot usable and removes staged install/runtime files when low disk interrupts an update', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-update-rollback-'))
    const context = await contextWithSessions()
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async (candidate, directory, runtimeDirectory) => {
        await mkdir(directory, { recursive: true })
        await writeFile(join(directory, 'version.txt'), candidate.version)
        await mkdir(runtimeDirectory, { recursive: true })
        await writeFile(join(runtimeDirectory, 'runtime-version.txt'), candidate.version)
        if (candidate.version === '2.0.0') {
          throw Object.assign(new Error('ENOSPC: no space left on device'), { code: 'ENOSPC' })
        }
      },
      create: async (request, candidate) => publishDriverAgent(context, request, candidate),
      resume: async (request, candidate) => publishDriverAgent(context, request, candidate),
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      await service.upsert(pack('2.0.0'))
      await expect(service.install('community.driver-demo' as never)).rejects.toThrow('no space left on device')

      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        installation: {
          status: 'installed', installedVersion: '1.0.0', availableVersion: '2.0.0',
          error: 'ENOSPC: no space left on device',
        },
      })
      const installParent = join(stateDir, 'installed', 'community.driver-demo')
      expect((await readdir(installParent)).some(name => name.includes('.installing-'))).toBe(false)
      expect(await readFile(join(installParent, '1.0.0', 'version.txt'), 'utf8')).toBe('1.0.0')
      expect(await readFile(join(stateDir, 'runtime', 'community.driver-demo', '1.0.0', 'runtime-version.txt'), 'utf8'))
        .toBe('1.0.0')
      await expect(lstat(join(stateDir, 'runtime', 'community.driver-demo', '2.0.0')))
        .rejects.toMatchObject({ code: 'ENOENT' })
      const agent = await service.create(
        'community.driver-demo' as never,
        'still-runs-old-version' as never,
        join(stateDir, 'no-project'),
      )
      expect(agent.id).toBe('still-runs-old-version')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('exposes only truthful Host transaction phases while an install is running', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-install-phase-'))
    let releaseInstall!: () => void
    let announceInstall!: () => void
    const installing = new Promise<void>((resolve) => { announceInstall = () => resolve() })
    const released = new Promise<void>((resolve) => { releaseInstall = () => resolve() })
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => {
        announceInstall()
        await released
      },
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      const operation = service.install('community.driver-demo' as never)
      await installing
      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        installation: {
          status: 'installing', operationPhase: 'staging',
          operationDetail: expect.stringContaining('isolated runtime'),
        },
      })
      releaseInstall()
      await operation
      expect((await service.list()).find(item => item.id === 'community.driver-demo')?.installation)
        .not.toHaveProperty('operationPhase')
    } finally {
      releaseInstall()
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('cancels a managed install without publishing a failed row or retaining staged runtime files', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-install-cancel-'))
    let installStarted!: () => void
    const started = new Promise<void>((resolve) => { installStarted = () => resolve() })
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async (_candidate, directory, runtimeDirectory, signal) => {
        if (signal === undefined) throw new Error('Install did not receive the caller cancellation signal')
        await mkdir(directory, { recursive: true })
        await mkdir(runtimeDirectory, { recursive: true })
        await writeFile(join(directory, 'partial.txt'), 'staged')
        await writeFile(join(runtimeDirectory, 'partial.txt'), 'runtime')
        installStarted()
        await new Promise<void>((_resolve, reject) => {
          const aborted = () => {
            const reason: unknown = signal.reason
            reject(reason instanceof Error ? reason : new Error('Harness install aborted'))
          }
          signal.addEventListener('abort', aborted, { once: true })
        })
      },
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      const controller = new AbortController()
      const operation = service.install('community.driver-demo' as never, controller.signal)
      await started
      controller.abort(new Error('user cancelled install'))
      await expect(operation).rejects.toThrow('user cancelled install')
      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        installation: { status: 'not-installed' },
      })
      const installation = (await service.list()).find(item => item.id === 'community.driver-demo')?.installation
      expect(installation).not.toHaveProperty('error')
      expect(installation).not.toHaveProperty('operationPhase')
      expect((await readdir(join(stateDir, 'installed', 'community.driver-demo')))
        .some(name => name.includes('.installing-'))).toBe(false)
      await expect(lstat(join(stateDir, 'runtime', 'community.driver-demo', '1.0.0')))
        .rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('marks a missing or linked exact snapshot unavailable and repairs the same version without following the link', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-snapshot-repair-'))
    const protectedDirectory = await mkdtemp(join(tmpdir(), 'openfish-snapshot-protected-'))
    let installs = 0
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async (_candidate, directory) => {
        installs += 1
        await mkdir(directory, { recursive: true })
        await writeFile(join(directory, 'ready.txt'), `install-${installs}`)
      },
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      await writeFile(join(protectedDirectory, 'keep.txt'), 'outside')
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      const snapshot = join(stateDir, 'installed', 'community.driver-demo', '1.0.0')
      await rm(snapshot, { recursive: true, force: true })
      const missing = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(missing?.available).toBe(false)
      expect(missing?.unavailableReason).toContain('snapshot is missing')
      await symlink(protectedDirectory, snapshot, 'dir')
      const linked = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(linked?.available).toBe(false)
      expect(linked?.unavailableReason).toContain('symbolic link')
      await service.install('community.driver-demo' as never)
      expect(await readFile(join(protectedDirectory, 'keep.txt'), 'utf8')).toBe('outside')
      expect(await readFile(join(snapshot, 'ready.txt'), 'utf8')).toBe('install-2')
      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({ available: true })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
      await rm(protectedDirectory, { recursive: true, force: true })
    }
  })

  it('never persists Driver credentials or the private Host home in catalog diagnostics', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-redacted-driver-'))
    const secret = 'github_pat_openfish_private_driver_fixture'
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => {
        throw new Error(`download failed in ${homedir()}/.dsh/openfish/runtime; token=${secret}; Bearer driver-private-bearer`)
      },
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await service.upsert(pack('1.0.0'))
      await authorizePackDriver(service)
      await expect(service.install('community.driver-demo' as never)).rejects.toThrow('download failed')
      const row = (await service.list()).find(item => item.id === 'community.driver-demo')
      const error = row?.installation.error ?? ''
      expect(error).toContain('[redacted]')
      expect(error).not.toContain(secret)
      expect(error).not.toContain('driver-private-bearer')
      expect(error).not.toContain(homedir())
      expect(Array.from(error).length).toBeLessThanOrEqual(800)
      const stored = await readFile(join(stateDir, 'state.json'), 'utf8')
      expect(stored).not.toContain(secret)
      expect(stored).not.toContain('driver-private-bearer')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('refuses implicit installation and incomplete runtime Driver objects', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-explicit-install-'))
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      const complete: HarnessDriver = {
        apiVersion: 1,
        protocol: 'community-protocol',
        capabilities: async () => [
          { id: 'session.create', status: 'supported', source: 'driver' },
          { id: 'session.resume', status: 'supported', source: 'driver' },
          { id: 'workspace.no-project', status: 'supported', source: 'driver' },
          { id: 'configuration.auth', status: 'supported', source: 'driver' },
          { id: 'architecture.manifest', status: 'supported', source: 'pack' },
        ],
        available: async () => undefined,
        create: async request => ({ id: request.sessionId }) as Agent,
        resume: async request => ({ id: request.sessionId }) as Agent,
        dispose: async () => undefined,
      }
      const incomplete = { ...complete } as unknown as Record<string, unknown>
      delete incomplete.dispose
      expect(() => service.registerDriver(incomplete as unknown as HarnessDriver)).toThrow('dispose')
      service.registerDriver(complete)
      await authorizePackDriver(service)
      await expect(service.create(
        'community.driver-demo' as never,
        'unconfirmed-code' as never,
        join(stateDir, 'no-project'),
      )).rejects.toThrow('installed explicitly')
      await expect(service.selectDefault('community.driver-demo' as never)).rejects.toThrow('must be installed')
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('injects shell-owned archive support without requiring every Driver to reimplement it', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-host-capability-'))
    const context = await contextWithSessions()
    const requests: HarnessSessionRequest[] = []
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async (request, candidate) => {
        requests.push(request)
        return publishDriverAgent(context, request, candidate)
      },
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      const service = new HarnessService(context, { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')

      const row = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(row?.capabilities).toContainEqual({
        id: 'session.archive', status: 'supported', source: 'host',
        detail: 'OpenFish archives the task without deleting its Harness session or durable transcript.',
      })

      await service.create(
        'community.driver-demo' as never,
        'host-archive-task' as never,
        join(stateDir, 'no-project', 'host-archive-task'),
        'no-project',
      )
      expect(requests[0]?.capabilities).toContainEqual(expect.objectContaining({
        id: 'session.archive', status: 'supported', source: 'host',
      }))
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('starts without an implicit default and retains the Registry catalog offline', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-offline-'))
    const contexts: Context[] = []
    const registry = {
      version: '1.0.0', agents: [{ id: 'future-agent', name: 'Future Agent', version: '3.2.1',
        description: 'A newly published ACP Harness', authors: ['Community'],
        distribution: { npx: { package: '@example/future-agent@3.2.1' } } }],
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(registry))))
      const onlineContext = new Context()
      contexts.push(onlineContext)
      const online = new HarnessService(onlineContext, { stateDir })
      await online.refresh()
      expect(await online.defaultId()).toBeUndefined()
      expect((await online.list()).some(item => item.id === 'future-agent')).toBe(true)

      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const offlineContext = new Context()
      contexts.push(offlineContext)
      const offline = new HarnessService(offlineContext, { stateDir })
      expect((await offline.list()).some(item => item.id === 'future-agent')).toBe(true)
      expect(await offline.defaultId()).toBeUndefined()
    } finally {
      while (contexts.length > 0) await contexts.pop()?.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('keeps release-tested Codex and Oh My Pi pins when public registries move', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-curated-versions-'))
    try {
      vi.stubGlobal('fetch', vi.fn(async (input) => {
        const url = String(input)
        if (url.includes('registry.json')) return new Response(JSON.stringify({ version: '1', agents: [] }))
        return new Response(JSON.stringify({ version: 0, packs: [] }))
      }))
      const service = new HarnessService(new Context(), { stateDir })
      await service.refresh()

      expect((await service.list()).find(item => item.id === 'codex')).toMatchObject({
        version: '0.150.1', installation: { availableVersion: '0.150.1' },
        distribution: { kind: 'npx', package: '@openai/codex@0.150.1' },
      })
      expect((await service.list()).find(item => item.id === 'oh-my-pi')).toMatchObject({
        version: '18.0.9', installation: { availableVersion: '18.0.9' },
        distribution: { kind: 'bunx', package: '@oh-my-pi/pi-coding-agent@18.0.9' },
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('retains an installed release-tested curated version as the offline restart baseline', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-curated-offline-'))
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'codex-app-server',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      authenticateInteractive: async () => undefined,
      missingCredentials: async () => [],
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async (input) => {
        const url = String(input)
        if (url.includes('registry.json')) return new Response(JSON.stringify({ version: '1', agents: [] }))
        return new Response(JSON.stringify({ version: 0, packs: [] }))
      }))
      const online = new HarnessService(new Context(), { stateDir })
      online.registerDriver(driver)
      await online.refresh()
      await online.install('codex' as never)
      expect((await online.list()).find(item => item.id === 'codex')).toMatchObject({
        version: '0.150.1', installation: { installedVersion: '0.150.1', availableVersion: '0.150.1' },
      })

      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const offline = new HarnessService(new Context(), { stateDir })
      offline.registerDriver(driver)
      expect((await offline.list()).find(item => item.id === 'codex')).toMatchObject({
        version: '0.150.1', installation: { installedVersion: '0.150.1', availableVersion: '0.150.1' },
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('shows a newer app-bundled curated version as an explicit update while retaining the installed pin', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-curated-app-update-'))
    const current = builtInHarnessPacks().find(candidate => candidate.id === 'codex')
    if (current === undefined || current.distribution?.kind !== 'npx') throw new Error('missing bundled Codex fixture')
    const previous = {
      ...current,
      version: '0.148.0',
      distribution: { ...current.distribution, package: '@openai/codex@0.148.0' },
    }
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'codex-app-server',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      await mkdir(join(stateDir, 'installed', 'codex', previous.version), { recursive: true })
      await writeFile(join(stateDir, 'state.json'), JSON.stringify({
        version: 6, customPacks: [], registryPacks: [], communityPacks: [],
        communityRevocations: [], communitySubmissions: [], communityRevocationSubmissions: [],
        driverAuthorizations: {}, installs: { codex: { active: previous, previous: [] } },
      }))
      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const service = new HarnessService(new Context(), { stateDir })
      service.registerDriver(driver)
      expect((await service.list()).find(item => item.id === 'codex')).toMatchObject({
        version: previous.version,
        installation: { installedVersion: previous.version, availableVersion: current.version },
        distribution: { package: previous.distribution.package },
      })
      expect(await service.describe('codex' as never, previous.version)).toMatchObject({
        version: previous.version,
        installation: { installedVersion: previous.version, availableVersion: current.version },
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('preserves a truthful two-component observable architecture during state migration', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-small-architecture-'))
    const evidence = [{ kind: 'declared', source: 'Small Harness manifest' }]
    const smallPack = {
      schemaVersion: 0, id: 'small-acp', name: 'Small ACP', version: '1.0.0', publisher: 'Community',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/small-acp@1.0.0', args: [], env: {} },
      graph: {
        level: 'observable', manifestVersion: 1, boundary: 'Small ACP process', evidence,
        nodes: [
          { id: 'protocol', kind: 'protocol-adapter', title: 'ACP', editable: false, responsibility: 'Accepts ACP requests.', evidence },
          { id: 'runtime', kind: 'agent-runtime', title: 'Runtime', editable: false, responsibility: 'Runs turns.', evidence },
        ],
        edges: [{ from: 'protocol', to: 'runtime', label: 'session request' }],
      },
    }
    try {
      await writeFile(join(stateDir, 'state.json'), JSON.stringify({
        version: 6, customPacks: [smallPack], registryPacks: [], communityPacks: [],
        communityRevocations: [], communitySubmissions: [], communityRevocationSubmissions: [],
        driverAuthorizations: {}, installs: {},
      }))
      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const service = new HarnessService(new Context(), { stateDir })
      expect((await service.list()).find(item => item.id === 'small-acp')?.graph).toMatchObject({
        level: 'observable', boundary: 'Small ACP process',
        nodes: [{ id: 'protocol' }, { id: 'runtime' }],
        edges: [{ from: 'protocol', to: 'runtime' }],
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('migrates legacy installed auth methods without losing catalog credential fields', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-legacy-auth-'))
    const registryPack = {
      ...(pack('1.0.0') as Record<string, unknown>),
      authMethods: [{
        id: 'api-key', name: 'API key', kind: 'environment',
        fields: [{ ref: 'DEMO_API_KEY', name: 'API key', env: 'DEMO_API_KEY', required: true, secret: true }],
        account: { label: 'Demo API · usage billing', billing: 'usage', detail: 'Bills the configured Demo API account.' },
      }],
      source: 'acp-registry',
    }
    const legacyActive = {
      ...registryPack,
      authMethods: [{ id: 'api-key', name: 'API key', kind: 'environment' }],
    }
    try {
      await writeFile(join(stateDir, 'state.json'), JSON.stringify({
        version: 2, customPacks: [], registryPacks: [registryPack],
        installs: { 'community.driver-demo': { active: legacyActive, previous: [] } },
      }))
      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const service = new HarnessService(new Context(), { stateDir })
      const row = (await service.list()).find(item => item.id === 'community.driver-demo')
      expect(row?.auth.methods[0]?.fields).toEqual([
        { ref: 'DEMO_API_KEY', name: 'API key', env: 'DEMO_API_KEY', required: true, secret: true },
      ])
      expect(row?.auth.methods[0]?.account).toEqual({
        label: 'Demo API · usage billing', billing: 'usage', detail: 'Bills the configured Demo API account.',
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('retains the community catalog offline and gives user Packs precedence', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-community-'))
    const contexts: Context[] = []
    const communityPack = {
      schemaVersion: 0, id: 'community.driver-demo', name: 'Published demo', version: '3.0.0', publisher: 'Community',
      license: 'MIT', repository: 'https://github.com/example/driver-demo',
      protocol: 'community-protocol', distribution: { kind: 'npx', package: '@community/driver-demo@3.0.0', args: [], env: {} },
      driverBundle: {
        apiVersion: 1, package: '@community/openfish-driver-demo',
        spec: '@community/openfish-driver-demo@1.0.0', requiresInstallScripts: false,
      },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async (input) => {
        const url = String(input)
        if (url.includes('community.test')) return new Response(JSON.stringify({ version: 0, packs: [communityPack] }))
        if (url.includes('registry.test')) return new Response(JSON.stringify({ version: '1', agents: [] }))
        return new Response(JSON.stringify({ version: '17.4.0' }))
      }))
      const onlineContext = new Context()
      contexts.push(onlineContext)
      const online = new HarnessService(onlineContext, {
        stateDir, registryUrl: 'https://registry.test/index.json', communityRegistryUrl: 'https://community.test/index.json',
      })
      await online.refresh()
      expect((await online.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        name: 'Published demo', source: 'openfish-community', verified: false,
      })

      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const offlineContext = new Context()
      contexts.push(offlineContext)
      const offline = new HarnessService(offlineContext, {
        stateDir, registryUrl: 'https://registry.test/index.json', communityRegistryUrl: 'https://community.test/index.json',
        packs: [pack('4.0.0')],
      })
      expect((await offline.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        version: '4.0.0', source: 'user',
      })
    } finally {
      while (contexts.length > 0) await contexts.pop()?.fiber.dispose()
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('records a submitted review only after exact installation and live preflight', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-community-submission-'))
    const candidate = {
      ...(pack('5.0.0') as Record<string, unknown>),
      license: 'MIT',
      repository: 'https://github.com/example/driver-demo',
      distribution: { kind: 'npx', package: '@community/driver-demo@5.0.0', args: ['acp'], env: {} },
    }
    const driver: HarnessDriver = {
      apiVersion: 1,
      protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
        { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      preflight: async () => ({ message: 'Live protocol initialized without a prompt.' }),
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async request => ({ id: request.sessionId }) as Agent,
      dispose: async () => undefined,
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async (input) => {
        const url = String(input)
        if (url.includes('registry.json')) return new Response(JSON.stringify({ version: '1', agents: [] }))
        if (url.includes('community/harnesses')) return new Response(JSON.stringify({ version: 0, packs: [], revocations: [] }))
        return new Response(JSON.stringify({ version: '17.4.0' }))
      }))
      const service = new HarnessService(new Context(), { stateDir, packs: [candidate] })
      service.registerDriver(driver)
      await expect(service.validatePublication(candidate)).rejects.toThrow('must be installed')
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      await expect(service.validatePublication(candidate)).rejects.toThrow('live preflight')
      await service.probe('community.driver-demo' as never)
      const publicPack = await service.validatePublication(candidate)
      await service.recordCommunitySubmission({
        id: publicPack.id,
        version: publicPack.version,
        reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/42',
        branch: 'openfish/harness-community.driver-demo-5.0.0-fixture',
        submittedAt: '2026-08-23T12:00:00.000Z',
        review: 'pending',
      })

      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        publication: {
          status: 'submitted', review: 'pending',
          reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/42',
        },
      })
      const restored = new HarnessService(new Context(), { stateDir })
      restored.registerDriver(driver)
      expect((await restored.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        publication: { status: 'submitted', review: 'pending' },
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('blocks revoked versions for new work while retaining exact-version resume', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-community-revocation-'))
    const context = await contextWithSessions()
    const communityPack = {
      schemaVersion: 0, id: 'community.driver-demo', name: 'Published demo', version: '3.0.0', publisher: 'Community',
      license: 'MIT', repository: 'https://github.com/example/driver-demo',
      protocol: 'community-protocol', distribution: { kind: 'npx', package: '@community/driver-demo@3.0.0', args: [], env: {} },
      driverBundle: {
        apiVersion: 1, package: '@community/openfish-driver-demo',
        spec: '@community/openfish-driver-demo@1.0.0', requiresInstallScripts: false,
      },
      authMethods: [{ id: 'local-login', name: 'Local login', kind: 'agent', fields: [] }],
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    }
    let revoked = false
    const driver: HarnessDriver = {
      apiVersion: 1, protocol: 'community-protocol',
      capabilities: async () => [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'session.resume', status: 'supported', source: 'driver' },
        { id: 'workspace.no-project', status: 'supported', source: 'driver' },
        { id: 'configuration.auth', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      available: async () => undefined,
      install: async () => undefined,
      create: async request => ({ id: request.sessionId }) as Agent,
      resume: async (request, candidate) => publishDriverAgent(context, request, candidate),
      dispose: async () => undefined,
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async (input) => {
        const url = String(input)
        if (url.includes('community.test')) return new Response(JSON.stringify({
          version: 0,
          packs: revoked ? [] : [communityPack],
          revocations: revoked ? [{
            id: 'community.driver-demo', version: '3.0.0', reason: 'Publisher key compromise',
            revokedAt: '2026-08-22T12:00:00.000Z',
          }] : [],
        }))
        if (url.includes('registry.test')) return new Response(JSON.stringify({ version: '1', agents: [] }))
        return new Response(JSON.stringify({ version: '17.4.0' }))
      }))
      const service = new HarnessService(context, {
        stateDir, registryUrl: 'https://registry.test/index.json', communityRegistryUrl: 'https://community.test/index.json',
      })
      service.registerDriver(driver)
      await service.refresh()
      await authorizePackDriver(service)
      await service.install('community.driver-demo' as never)
      await service.selectAuth('community.driver-demo' as never, 'local-login')
      await service.recordCommunityRevocationSubmission({
        id: 'community.driver-demo' as never,
        version: '3.0.0',
        reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/43',
        branch: 'openfish/revoke-community.driver-demo-3.0.0-fixture',
        submittedAt: '2026-08-23T12:05:00.000Z',
        review: 'pending',
      })
      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        available: true,
        publication: {
          status: 'revocation-requested', review: 'pending',
          reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/43',
        },
      })
      const restoredBeforeMerge = new HarnessService(new Context(), {
        stateDir, registryUrl: 'https://registry.test/index.json', communityRegistryUrl: 'https://community.test/index.json',
      })
      restoredBeforeMerge.registerDriver(driver)
      expect((await restoredBeforeMerge.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        publication: { status: 'revocation-requested', review: 'pending' },
      })
      revoked = true
      await service.refresh()

      expect((await service.list()).find(item => item.id === 'community.driver-demo')).toMatchObject({
        available: false,
        publication: { status: 'revoked', review: 'revoked', revokedReason: 'Publisher key compromise' },
      })
      await expect(service.create(
        'community.driver-demo' as never, 'session-new' as never, join(stateDir, 'new'), 'no-project',
      )).rejects.toThrow('revoked')
      await expect(service.selectDefault('community.driver-demo' as never)).rejects.toThrow('revoked')
      const resumed = await service.resume(
        'community.driver-demo' as never, 'session-existing' as never, join(stateDir, 'existing'), '3.0.0', 'local-login', 'no-project',
      )
      expect(resumed.id).toBe('session-existing')
      expect(await service.describe('community.driver-demo' as never, '3.0.0', 'local-login')).toMatchObject({
        available: true, publication: { status: 'revoked' },
      })
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })
})

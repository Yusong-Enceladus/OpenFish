import { Context } from '@deepseek-ai/cordis'
import { homedir } from 'node:os'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import SessionStore from '@deepseek-ai/dsh-session'
import UserQuestionService from '@deepseek-ai/dsh-user-questions'
import { describe, expect, it, vi } from 'vitest'
import { createApiProxy } from '../src/api-proxy.ts'
import { harnessCatalogEntrySchema } from '../src/api/harnesses.schema.ts'
import { RpcId, type RpcRequest } from '../src/api/rpc.ts'

const submitCommunityPack = vi.hoisted(() => vi.fn())
const submitCommunityRevocation = vi.hoisted(() => vi.fn())
vi.mock('../src/harness-community-github.ts', () => ({
  OPENFISH_GITHUB_TOKEN_REF: 'OPENFISH_GITHUB_TOKEN',
  submitOpenFishCommunityPack: submitCommunityPack,
  submitOpenFishCommunityRevocation: submitCommunityRevocation,
}))

function request<P>(payload: P): RpcRequest<P> {
  return { rpcId: RpcId('harness-request'), payload }
}

describe('Harness catalog wire schema', () => {
  it('preserves portable distribution and architecture data for native Studio clients', () => {
    const evidence = [{ kind: 'declared', source: 'Demo Pack', version: '1.2.3' }]
    const row = harnessCatalogEntrySchema.parse({
      schemaVersion: 0, id: 'community.demo', name: 'Demo', version: '1.2.3', publisher: 'Community', verified: false,
      protocol: 'future-protocol', source: 'openfish-community', isDefault: false,
      driverBundle: {
        apiVersion: 1, package: '@community/openfish-driver-demo',
        spec: '@community/openfish-driver-demo@1.0.0', requiresInstallScripts: false,
      },
      distribution: { kind: 'npx', package: '@community/demo@1.2.3', args: ['acp'], env: { NO_UPDATE: '1' } },
      graph: {
        level: 'composable',
        manifestVersion: 1,
        boundary: 'Demo Harness process',
        evidence,
        nodes: [
          { id: 'input', kind: 'input', title: 'Input', editable: false, responsibility: 'Accepts prompts.', evidence },
          { id: 'runtime', kind: 'runtime', title: 'Runtime', editable: true, responsibility: 'Runs the agent loop.', evidence, config: { model: 'user' } },
          { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes updates.', evidence },
        ],
        edges: [
          { from: 'input', to: 'runtime', label: 'validated prompt' },
          { from: 'runtime', to: 'output', label: 'typed update' },
        ],
      },
      available: false,
      unavailableReason: 'No future-protocol Driver is loaded',
      installation: {
        status: 'not-installed', availableVersion: '1.2.3', previousVersions: [],
        integrity: {
          status: 'version-pinned', source: '@community/demo@1.2.3',
          detail: 'The exact package version is pinned by this fixture.',
        },
      },
      auth: { methods: [], status: 'not-required', missingFields: [] },
      compatibility: { status: 'untested', classification: 'experimental' },
      capabilities: [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      driver: { apiVersion: 1, protocol: 'future-protocol', loaded: false, authorization: 'required' },
    })
    expect(row.distribution).toEqual({
      kind: 'npx', package: '@community/demo@1.2.3', args: ['acp'], env: { NO_UPDATE: '1' },
    })
    expect(row.graph.nodes[1]?.config).toEqual({ model: 'user' })
    expect(row.graph.boundary).toBe('Demo Harness process')
    expect(row.graph.nodes[1]?.evidence).toEqual(evidence)
    expect(row.graph.edges.map(edge => edge.label)).toEqual(['validated prompt', 'typed update'])
    expect(row.driverBundle).toEqual({
      apiVersion: 1, package: '@community/openfish-driver-demo',
      spec: '@community/openfish-driver-demo@1.0.0', requiresInstallScripts: false,
    })
    expect(row.driver).toEqual({ apiVersion: 1, protocol: 'future-protocol', loaded: false, authorization: 'required' })
  })

  it('accepts unverified code consent only through the Host-local management method', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(UserQuestionService)
    await ctx.plugin(AgentRegistry)
    ctx.provide('workspaceRegistry', { list: () => [], archivedSessionIds: new Set() } as never)
    const install = vi.fn(() => Promise.resolve())
    const probe = vi.fn(() => Promise.resolve())
    const candidate = {
      id: 'community.demo', source: 'openfish-community', verified: false,
      installation: { status: 'not-installed', availableVersion: '1.2.3' },
    }
    ctx.provide('harnesses', {
      describe: () => Promise.resolve(candidate),
      install,
      probe,
      list: () => Promise.resolve([]),
    } as never)
    const api = createApiProxy(ctx, {
      cwd: '/tmp', defaultModelSelection: () => ({ provider: 'fixture', model: 'fixture' }),
    })

    const refused = await api.harnesses.mutate(request({ action: 'install', id: 'community.demo' }))
    expect(refused.result.ok).toBe(false)
    if (refused.result.ok) throw new Error('expected a Harness failure')
    expect(refused.result.error.code).toBe('harness-install-failed')
    expect(refused.result.error.message).toContain('Host Mac')
    expect(install).not.toHaveBeenCalled()

    const remoteCannotSelfAssertConsent = await api.harnesses.mutate(request({
      action: 'install', id: 'community.demo', acceptUnverified: true,
    }))
    expect(remoteCannotSelfAssertConsent.result.ok).toBe(false)
    expect(install).not.toHaveBeenCalled()

    const accepted = await api.harnesses.manage(request({
      action: 'install', id: 'community.demo', acceptUnverified: true,
    }))
    expect(accepted.result.ok).toBe(true)
    expect(install).toHaveBeenCalledTimes(1)

    const probeRefused = await api.harnesses.mutate(request({ action: 'probe', id: 'community.demo' }))
    expect(probeRefused.result.ok).toBe(false)
    expect(probe).not.toHaveBeenCalled()
  })

  it('redacts Host secrets and private runtime paths from Harness failures', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(UserQuestionService)
    await ctx.plugin(AgentRegistry)
    ctx.provide('workspaceRegistry', { list: () => [], archivedSessionIds: new Set() } as never)
    const secret = 'sk-openfish-private-fixture-value'
    ctx.provide('harnesses', {
      describe: () => Promise.resolve({
        id: 'community.demo', source: 'openfish-community', verified: true,
        installation: { status: 'not-installed', availableVersion: '1.2.3' },
      }),
      install: () => Promise.reject(new Error(
        `download failed at ${homedir()}/.dsh/openfish/runtime; apiKey=${secret}; `
        + 'Bearer header-secret-value; https://fixture-user:fixture-password@example.invalid/archive',
      )),
      list: () => Promise.resolve([]),
    } as never)
    const api = createApiProxy(ctx, {
      cwd: '/tmp', defaultModelSelection: () => ({ provider: 'fixture', model: 'fixture' }),
    })

    const response = await api.harnesses.mutate(request({ action: 'install', id: 'community.demo' }))
    expect(response.result.ok).toBe(false)
    if (response.result.ok) throw new Error('expected a Harness failure')
    expect(response.result.error.code).toBe('harness-install-failed')
    expect(response.result.error.message).toContain('[redacted]')
    expect(response.result.error.message).not.toContain(secret)
    expect(response.result.error.message).not.toContain('header-secret-value')
    expect(response.result.error.message).not.toContain('fixture-password')
    expect(response.result.error.message).not.toContain(homedir())
    expect(Array.from(response.result.error.message).length).toBeLessThanOrEqual(800)
  })

  it('commits only an exact Driver Bundle identity through the Host-local management plane', async () => {
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(UserQuestionService)
    await ctx.plugin(AgentRegistry)
    ctx.provide('workspaceRegistry', { list: () => [], archivedSessionIds: new Set() } as never)
    const authorizeDriverBundle = vi.fn(() => Promise.resolve())
    ctx.provide('harnesses', {
      authorizeDriverBundle,
      list: () => Promise.resolve([]),
    } as never)
    const api = createApiProxy(ctx, {
      cwd: '/tmp', defaultModelSelection: () => ({ provider: 'fixture', model: 'fixture' }),
    })

    const incomplete = await api.harnesses.manage(request({
      action: 'authorize-driver', id: 'community.demo', version: '1.2.3',
    }))
    expect(incomplete.result.ok).toBe(false)
    expect(authorizeDriverBundle).not.toHaveBeenCalled()

    const accepted = await api.harnesses.manage(request({
      action: 'authorize-driver', id: 'community.demo', version: '1.2.3',
      driverPackage: '@community/openfish-driver-demo',
      driverSpec: '@community/openfish-driver-demo@1.0.0',
    }))
    expect(accepted.result.ok).toBe(true)
    expect(authorizeDriverBundle).toHaveBeenCalledWith(
      'community.demo', '1.2.3',
      '@community/openfish-driver-demo', '@community/openfish-driver-demo@1.0.0',
    )
  })

  it('resolves GitHub authorization only inside the Host and records the accepted review', async () => {
    submitCommunityPack.mockResolvedValueOnce({
      reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/42',
      branch: 'openfish/harness-community.demo-1.2.3-fixture',
      submittedAt: '2026-08-23T12:00:00.000Z',
    })
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(UserQuestionService)
    await ctx.plugin(AgentRegistry)
    ctx.provide('workspaceRegistry', { list: () => [], archivedSessionIds: new Set() } as never)
    ctx.provide('credentials', {
      resolve: vi.fn(() => Promise.resolve({ value: 'host-only-token', source: 'keychain' })),
    } as never)
    const publicPack = {
      id: 'community.demo', version: '1.2.3', name: 'Demo', protocol: 'acp', publisher: 'Fixture',
    }
    const recordCommunitySubmission = vi.fn(() => Promise.resolve())
    ctx.provide('harnesses', {
      require: () => ({ ...publicPack, source: 'user' }),
      validatePublication: () => Promise.resolve({ ...publicPack, source: 'openfish-community' }),
      recordCommunitySubmission,
      list: () => Promise.resolve([]),
    } as never)
    const api = createApiProxy(ctx, {
      cwd: '/tmp', defaultModelSelection: () => ({ provider: 'fixture', model: 'fixture' }),
    })

    const result = await api.harnesses.manage(request({ action: 'submit-publication', id: 'community.demo' }))

    expect(result.result.ok).toBe(true)
    expect(submitCommunityPack).toHaveBeenCalledWith(
      expect.objectContaining({ id: 'community.demo', version: '1.2.3' }),
      'host-only-token',
      undefined,
    )
    expect(recordCommunitySubmission).toHaveBeenCalledWith(expect.objectContaining({
      id: 'community.demo', review: 'pending',
      reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/42',
    }))
  })

  it('submits an exact-version revocation through Host-only authorization and records its review', async () => {
    submitCommunityRevocation.mockResolvedValueOnce({
      reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/43',
      branch: 'openfish/revoke-community.demo-1.2.3-fixture',
      submittedAt: '2026-08-23T12:05:00.000Z',
    })
    const ctx = new Context()
    await ctx.plugin(SessionStore)
    await ctx.plugin(UserQuestionService)
    await ctx.plugin(AgentRegistry)
    ctx.provide('workspaceRegistry', { list: () => [], archivedSessionIds: new Set() } as never)
    ctx.provide('credentials', {
      resolve: vi.fn(() => Promise.resolve({ value: 'host-only-token', source: 'keychain' })),
    } as never)
    const published = {
      id: 'community.demo', version: '1.2.3', name: 'Demo', protocol: 'acp', publisher: 'Fixture',
      source: 'openfish-community', publication: { status: 'published', publishedVersion: '1.2.3' },
    }
    const recordCommunityRevocationSubmission = vi.fn(() => Promise.resolve())
    ctx.provide('harnesses', {
      require: () => published,
      describe: () => Promise.resolve(published),
      recordCommunityRevocationSubmission,
      list: () => Promise.resolve([]),
    } as never)
    const api = createApiProxy(ctx, {
      cwd: '/tmp', defaultModelSelection: () => ({ provider: 'fixture', model: 'fixture' }),
    })

    const result = await api.harnesses.manage(request({
      action: 'submit-revocation', id: 'community.demo',
      reason: 'This exact release has a confirmed unsafe compatibility regression.',
    }))

    expect(result.result.ok).toBe(true)
    expect(submitCommunityRevocation).toHaveBeenCalledWith(expect.objectContaining({
      id: 'community.demo', version: '1.2.3',
      reason: 'This exact release has a confirmed unsafe compatibility regression.',
    }), 'host-only-token', undefined)
    expect(recordCommunityRevocationSubmission).toHaveBeenCalledWith(expect.objectContaining({
      id: 'community.demo', version: '1.2.3', review: 'pending',
      reviewUrl: 'https://github.com/Yusong-Enceladus/OpenFish/pull/43',
    }))
  })
})

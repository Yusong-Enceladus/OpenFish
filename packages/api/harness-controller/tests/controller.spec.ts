import { Context } from '@deepseek-ai/cordis'
import type { HarnessCatalogEntry, HarnessService } from '@deepseek-ai/dsh-harness'
import TypertRegistry from '@deepseek-ai/dsh-typert-registry'
import { TypertRemoteFailure, remoteMethods } from '@deepseek-ai/dsh-typert-protocol'
import { afterEach, describe, expect, it, vi } from 'vitest'
import HarnessController, { HarnessController as NamedHarnessController } from '../src/index.ts'

const signal = (): AbortSignal => new AbortController().signal

function catalogRow(overrides: Partial<HarnessCatalogEntry> = {}): HarnessCatalogEntry {
  return {
    schemaVersion: 0,
    id: 'fixture.acp' as never,
    name: 'Fixture ACP',
    version: '1.0.0',
    publisher: 'Fixture',
    verified: false,
    protocol: 'acp',
    source: 'openfish-community',
    distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
    graph: {
      level: 'opaque',
      nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }],
      edges: [],
    },
    isDefault: false,
    available: true,
    installation: {
      status: 'not-installed', availableVersion: '1.0.0', previousVersions: [],
      integrity: { status: 'local-executable', source: 'Pack', detail: 'Fixture executable.' },
    },
    auth: { methods: [], status: 'not-required', missingFields: [], detail: 'No Harness-level sign-in is required.' },
    compatibility: { status: 'untested', classification: 'experimental' },
    capabilities: [],
    authoring: { nodeKinds: [], bindingKinds: [] },
    driver: { apiVersion: 1, protocol: 'acp', loaded: true, authorization: 'not-required' },
    ...overrides,
  }
}

function fakeHarnesses(row = catalogRow()): HarnessService {
  return {
    list: vi.fn(async () => [row]),
    describe: vi.fn(async () => row),
    refresh: vi.fn(async () => undefined),
    clearDefault: vi.fn(async () => undefined),
    install: vi.fn(async () => undefined),
    uninstall: vi.fn(async () => undefined),
    rollback: vi.fn(async () => undefined),
    probe: vi.fn(async () => undefined),
    selectDefault: vi.fn(async () => undefined),
    selectAuth: vi.fn(async () => undefined),
    authorizeDriverBundle: vi.fn(async () => undefined),
    upsert: vi.fn(async () => row),
    validatePublication: vi.fn(async () => row),
    require: vi.fn(() => row),
    recordCommunitySubmission: vi.fn(async () => undefined),
    recordCommunityRevocationSubmission: vi.fn(async () => undefined),
    removeUserPack: vi.fn(async () => undefined),
    authenticateInteractive: vi.fn(async () => undefined),
  } as unknown as HarnessService
}

async function boot(row = catalogRow()): Promise<{
  context: Context
  controller: HarnessController
  harnesses: HarnessService
}> {
  const context = new Context()
  const harnesses = fakeHarnesses(row)
  context.provide('harnesses', harnesses)
  await context.plugin(TypertRegistry)
  await context.plugin(HarnessController)
  return { context, controller: context.harnessController, harnesses }
}

describe('Harness Remote control plane', () => {
  afterEach(() => vi.restoreAllMocks())

  it('exports a real Loader entry with the complete injection and Remote contract', async () => {
    expect(HarnessController).toBe(NamedHarnessController)
    expect(HarnessController.inject).toEqual(['typert', 'harnesses'])
    const { context, controller } = await boot()
    try {
      expect(controller.typertRemote).toMatchObject({ serviceKey: 'harnessController', namespace: 'harness' })
      expect(remoteMethods(controller)).toEqual([
        { method: 'list', invocation: { kind: 'direct' } },
        { method: 'resolve', invocation: { kind: 'direct' } },
        { method: 'refresh', invocation: { kind: 'direct' } },
        { method: 'mutate', invocation: { kind: 'direct' } },
        { method: 'manage', invocation: { kind: 'direct' } },
      ])
    } finally {
      await context.fiber.dispose()
    }
  })

  it('filters the catalog without inventing compatibility rows', async () => {
    const { context, controller } = await boot()
    try {
      await expect(controller.list({ query: 'fixture' })).resolves.toEqual({ items: [catalogRow()] })
      await expect(controller.list({ query: 'missing' })).resolves.toEqual({ items: [] })
    } finally {
      await context.fiber.dispose()
    }
  })

  it('rejects malformed ids and remote consent for unverified code before installation', async () => {
    const { context, controller, harnesses } = await boot()
    try {
      const malformed = await controller.resolve({ id: 'Not A Harness' }).catch((error: unknown) => error)
      expect(malformed).toBeInstanceOf(TypertRemoteFailure)
      expect((malformed as TypertRemoteFailure).failure).toMatchObject({ code: 'harness-failed' })

      const rejected = await controller.mutate({
        action: 'install', id: 'fixture.acp', acceptUnverified: true,
      }, signal()).catch((error: unknown) => error)
      expect(rejected).toBeInstanceOf(TypertRemoteFailure)
      expect((rejected as TypertRemoteFailure).failure.message).toContain('Host-local')
      expect(harnesses.install).not.toHaveBeenCalled()
    } finally {
      await context.fiber.dispose()
    }
  })

  it('keeps ordinary selection remote-safe and exact Driver authorization on the local plane', async () => {
    const installed = catalogRow({
      installation: {
        status: 'installed', installedVersion: '1.0.0', availableVersion: '1.0.0', previousVersions: [],
        integrity: { status: 'version-pinned', source: 'Fixture', detail: 'Exact fixture.' },
      },
    })
    const { context, controller, harnesses } = await boot(installed)
    try {
      await controller.mutate({ action: 'default', id: 'fixture.acp' }, signal())
      expect(harnesses.selectDefault).toHaveBeenCalledWith('fixture.acp')

      await controller.manage({
        action: 'authorize-driver', id: 'fixture.acp', version: '1.0.0',
        driverPackage: '@fixture/openfish-driver', driverSpec: '@fixture/openfish-driver@1.0.0',
      }, signal())
      expect(harnesses.authorizeDriverBundle).toHaveBeenCalledWith(
        'fixture.acp', '1.0.0', '@fixture/openfish-driver', '@fixture/openfish-driver@1.0.0',
      )
    } finally {
      await context.fiber.dispose()
    }
  })

  it('returns a stable cancelled failure when catalog refresh is already aborted', async () => {
    const { context, controller } = await boot()
    try {
      const abort = new AbortController()
      abort.abort()
      const failure = await controller.refresh(abort.signal).catch((error: unknown) => error)
      expect(failure).toBeInstanceOf(TypertRemoteFailure)
      expect((failure as TypertRemoteFailure).failure).toMatchObject({ code: 'cancelled' })
    } finally {
      await context.fiber.dispose()
    }
  })
})

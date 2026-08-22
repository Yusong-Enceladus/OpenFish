import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { Context } from '@deepseek-ai/cordis'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { HarnessService } from '../src/index.ts'
import type { HarnessDriver, HarnessPack } from '../src/types.ts'

function pack(version: string): unknown {
  return {
    schemaVersion: 0, id: 'community.driver-demo', name: 'Driver demo', version, publisher: 'Community',
    verified: false, protocol: 'community-protocol',
    authMethods: [{ id: 'local-login', name: 'Local login', kind: 'agent', fields: [] }],
    distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
    graph: {
      level: 'composable',
      nodes: [{ id: 'input', kind: 'input', title: 'Input', editable: true, config: { x: 10, y: 20 } }],
      edges: [],
    },
    source: 'user',
  }
}

describe('Harness lifecycle and Driver SDK', () => {
  afterEach(() => vi.unstubAllGlobals())

  it('persists custom Packs, install snapshots, rollback, auth, and the cross-device default', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-state-'))
    const installed: string[] = []
    const driver: HarnessDriver = {
      protocol: 'community-protocol',
      available: async () => undefined,
      install: async (candidate: HarnessPack) => { installed.push(candidate.version) },
      create: async () => { throw new Error('not used') },
      resume: async () => { throw new Error('not used') },
    }
    try {
      const service = new HarnessService(new Context(), { stateDir, packs: [pack('1.0.0')] })
      service.registerDriver(driver)
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
        version: '2.0.0',
        installation: { status: 'installed', installedVersion: '1.0.0', availableVersion: '2.0.0', previousVersions: ['2.0.0'] },
        auth: { selectedMethod: 'local-login' },
        graph: { level: 'composable' },
      })

      const restored = new HarnessService(new Context(), { stateDir })
      restored.registerDriver(driver)
      const restoredRow = (await restored.list()).find(item => item.id === 'community.driver-demo')
      expect(restoredRow).toMatchObject({ isDefault: true, version: '2.0.0', installation: { installedVersion: '1.0.0' }, source: 'user' })
      const stored = JSON.parse(await readFile(join(stateDir, 'state.json'), 'utf8')) as { version: number }
      expect(stored.version).toBe(2)
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })

  it('starts without an implicit default and retains the Registry catalog offline', async () => {
    const stateDir = await mkdtemp(join(tmpdir(), 'openfish-offline-'))
    const registry = {
      version: '1.0.0', agents: [{ id: 'future-agent', name: 'Future Agent', version: '3.2.1',
        description: 'A newly published ACP Harness', authors: ['Community'],
        distribution: { npx: { package: '@example/future-agent@3.2.1' } } }],
    }
    try {
      vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify(registry))))
      const online = new HarnessService(new Context(), { stateDir })
      expect(await online.defaultId()).toBeUndefined()
      expect((await online.list()).some(item => item.id === 'future-agent')).toBe(true)

      vi.stubGlobal('fetch', vi.fn(async () => { throw new Error('offline') }))
      const offline = new HarnessService(new Context(), { stateDir })
      expect((await offline.list()).some(item => item.id === 'future-agent')).toBe(true)
      expect(await offline.defaultId()).toBeUndefined()
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
    } finally {
      await rm(stateDir, { recursive: true, force: true })
    }
  })
})

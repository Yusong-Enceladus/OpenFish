import { describe, expect, it } from 'vitest'
import { packsFromAcpRegistry, parseHarnessPack } from '../src/manifest.ts'

describe('Harness Pack v0', () => {
  it('admits a fourth composable ACP Harness without provider-specific code', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0,
      id: 'community.fourth-harness',
      name: 'Fourth Harness',
      version: '1.2.3',
      publisher: 'Community',
      verified: false,
      protocol: 'acp',
      distribution: { kind: 'npx', package: '@community/fourth-harness@1.2.3', args: ['--acp'], env: {} },
      graph: {
        level: 'composable',
        nodes: [
          { id: 'planner', kind: 'planner', title: 'Planner', editable: true },
          { id: 'executor', kind: 'executor', title: 'Executor', editable: false },
        ],
        edges: [{ from: 'planner', to: 'executor' }],
      },
      source: 'user',
    })
    expect(pack.id).toBe('community.fourth-harness')
    expect(pack.graph.level).toBe('composable')
  })

  it('rejects architecture edges that invent absent internals', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0,
      id: 'broken',
      name: 'Broken',
      version: '1',
      publisher: 'Test',
      verified: false,
      protocol: 'acp',
      distribution: { kind: 'executable', command: '/bin/false', args: [], env: {} },
      graph: { level: 'opaque', nodes: [], edges: [{ from: 'missing', to: 'also-missing' }] },
      source: 'user',
    })).toThrow('unknown node')
  })

  it('projects any npm ACP Registry row into an opaque runnable Pack', () => {
    const [pack] = packsFromAcpRegistry({
      version: '1',
      agents: [{
        id: 'new-agent',
        name: 'New Agent',
        version: '9.0.0',
        authors: ['Example Publisher'],
        distribution: { npx: { package: '@example/new-agent', args: ['--acp'] } },
      }],
    })
    expect(pack).toMatchObject({
      id: 'new-agent',
      protocol: 'acp',
      source: 'acp-registry',
      graph: { level: 'opaque' },
      distribution: { kind: 'npx', package: '@example/new-agent@9.0.0' },
    })
  })

  it('accepts uvx, terminal authentication data, and editable node configuration', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'python-agent', name: 'Python Agent', version: '1.4.0', publisher: 'Community',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'uvx', package: 'python-agent==1.4.0', args: ['acp'], env: { NO_UPDATE: '1' } },
      authMethods: [{ id: 'login', name: 'Login', kind: 'terminal', fields: [], terminal: { args: ['login'], env: {} } }],
      graph: { level: 'composable', nodes: [{ id: 'model', kind: 'model', title: 'Model', editable: true, config: { provider: 'user' } }], edges: [] },
    })
    expect(pack.distribution?.kind).toBe('uvx')
    expect(pack.authMethods?.[0]?.terminal?.args).toEqual(['login'])
    expect(pack.graph.nodes[0]?.config).toEqual({ provider: 'user' })
  })

  it('uses the current platform Registry binary cmd only when it is checksummed', () => {
    const target = process.platform === 'darwin' ? 'darwin' : process.platform === 'win32' ? 'windows' : 'linux'
    const arch = process.arch === 'arm64' ? 'aarch64' : 'x86_64'
    const [pack] = packsFromAcpRegistry({
      version: '1.0.0', agents: [{ id: 'native-agent', name: 'Native Agent', version: '2.0.0', description: 'Native',
        distribution: { binary: { [`${target}-${arch}`]: {
          archive: 'https://example.com/native.tar.gz', cmd: './bin/native', sha256: 'a'.repeat(64),
        } } } }],
    })
    expect(pack?.distribution).toMatchObject({ kind: 'binary', command: './bin/native', sha256: 'a'.repeat(64) })
  })
})

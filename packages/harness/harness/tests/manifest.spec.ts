import { describe, expect, it } from 'vitest'
import { packsFromAcpRegistry, packsFromOpenFishCommunity, parseHarnessPack } from '../src/manifest.ts'

describe('Harness Pack v0', () => {
  it('admits a fourth composable ACP Harness without provider-specific code', () => {
    const evidence = [{ kind: 'declared', source: 'Fourth Harness manifest', version: '1.2.3' }]
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
        manifestVersion: 1,
        boundary: 'Fourth Harness process',
        evidence,
        nodes: [
          { id: 'planner', kind: 'planner', title: 'Planner', editable: true, responsibility: 'Plans the task.', evidence },
          { id: 'executor', kind: 'executor', title: 'Executor', editable: false, responsibility: 'Executes approved actions.', evidence },
          { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes updates.', evidence },
        ],
        edges: [{ from: 'planner', to: 'executor' }, { from: 'executor', to: 'output' }],
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
    const evidence = [{ kind: 'declared', source: 'Python Agent manifest', version: '1.4.0' }]
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'python-agent', name: 'Python Agent', version: '1.4.0', publisher: 'Community',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'uvx', package: 'python-agent==1.4.0', args: ['acp'], env: { NO_UPDATE: '1' } },
      authMethods: [{ id: 'login', name: 'Login', kind: 'terminal', fields: [], terminal: { args: ['login'], env: {} } }],
      graph: {
        level: 'composable', manifestVersion: 1, boundary: 'Python Agent process', evidence,
        nodes: [
          { id: 'input', kind: 'input', title: 'Input', editable: false, responsibility: 'Accepts ACP prompts.', evidence },
          { id: 'model', kind: 'model', title: 'Model', editable: true, responsibility: 'Selects the model route.', evidence, config: { provider: 'user' } },
          { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes ACP updates.', evidence },
        ],
        edges: [{ from: 'input', to: 'model' }, { from: 'model', to: 'output' }],
      },
    })
    expect(pack.distribution?.kind).toBe('uvx')
    expect(pack.authMethods?.[0]?.terminal?.args).toEqual(['login'])
    expect(pack.graph.nodes[1]?.config).toEqual({ provider: 'user' })
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

  it('admits exact-version community Packs without granting verified status', () => {
    const [pack] = packsFromOpenFishCommunity({
      version: 0,
      packs: [{
        schemaVersion: 0, id: 'community.public-agent', name: 'Public Agent', version: '1.2.3', publisher: 'Community',
        verified: true, protocol: 'acp', source: 'user',
        distribution: { kind: 'npx', package: '@community/public-agent@1.2.3', args: ['acp'], env: {} },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })
    expect(pack).toMatchObject({ id: 'community.public-agent', source: 'openfish-community', verified: false })
  })

  it('rejects floating package versions in the community catalog', () => {
    expect(() => packsFromOpenFishCommunity({
      version: 0,
      packs: [{
        schemaVersion: 0, id: 'community.floating', name: 'Floating', version: '1', publisher: 'Community',
        protocol: 'acp', distribution: { kind: 'npx', package: '@community/floating@latest', args: [], env: {} },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })).toThrow('exact version')
  })

  it('rejects credential values from the public community catalog', () => {
    expect(() => packsFromOpenFishCommunity({
      version: 0,
      packs: [{
        schemaVersion: 0, id: 'community.leaked', name: 'Leaked', version: '1.0.0', publisher: 'Community',
        protocol: 'acp', distribution: { kind: 'npx', package: '@community/leaked@1.0.0', args: [], env: { API_KEY: 'private' } },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })).toThrow('cannot contain a value')
  })

  it('rejects a decorative single-node observable graph', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'decorative', name: 'Decorative', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/decorative@1.0.0', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Decorative process',
        evidence: [{ kind: 'declared', source: 'Test manifest' }],
        nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [],
      },
    })).toThrow('at least three connected components')
  })

  it('rejects unexplained observable components without evidence', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'unsupported', name: 'Unsupported', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/unsupported@1.0.0', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Unsupported process',
        evidence: [{ kind: 'declared', source: 'Test manifest' }],
        nodes: [
          { id: 'one', kind: 'input', title: 'One', editable: false },
          { id: 'two', kind: 'runtime', title: 'Two', editable: false },
          { id: 'three', kind: 'output', title: 'Three', editable: false },
        ], edges: [{ from: 'one', to: 'two' }, { from: 'two', to: 'three' }],
      },
    })).toThrow('requires responsibility and evidence')
  })
})

import { describe, expect, it } from 'vitest'
import { openFishCommunityCatalog, packsFromAcpRegistry, packsFromOpenFishCommunity, parseHarnessPack, prepareHarnessPublication } from '../src/manifest.ts'

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
      modelConfiguration: { owner: 'harness', required: false },
      authenticationDiscovery: { source: 'runtime' },
      graph: { level: 'opaque' },
      distribution: { kind: 'npx', package: '@example/new-agent@9.0.0' },
    })
  })

  it('replaces Registry package tags with the Registry exact version', () => {
    const [npmPack] = packsFromAcpRegistry({
      version: '1',
      agents: [{
        id: 'tagged-agent', name: 'Tagged Agent', version: '4.5.6',
        distribution: { npx: { package: '@example/tagged-agent@latest' } },
      }],
    })
    const [pythonPack] = packsFromAcpRegistry({
      version: '1',
      agents: [{
        id: 'python-tagged-agent', name: 'Python Tagged Agent', version: '2.3.4',
        distribution: { uvx: { package: 'python-tagged-agent@main' } },
      }],
    })
    expect(npmPack?.distribution).toMatchObject({ package: '@example/tagged-agent@4.5.6' })
    expect(pythonPack?.distribution).toMatchObject({ package: 'python-tagged-agent==2.3.4' })
  })

  it('omits Registry package distributions whose Registry version is not exact', () => {
    expect(packsFromAcpRegistry({
      version: '1',
      agents: [{
        id: 'floating-registry-agent', name: 'Floating Registry Agent', version: 'latest',
        distribution: { npx: { package: '@example/floating@latest' } },
      }],
    })).toEqual([])
    expect(packsFromAcpRegistry({
      version: '1',
      agents: [{
        id: 'floating-python-agent', name: 'Floating Python Agent', version: '>=2',
        distribution: { uvx: { package: 'floating-python-agent' } },
      }],
    })).toEqual([])
  })

  it('isolates malformed and duplicate Registry rows instead of losing the shared catalog', () => {
    const packs = packsFromAcpRegistry({
      version: '1.0.0',
      agents: [
        {
          id: 'healthy-agent', name: 'Healthy Agent', version: '1.2.3',
          distribution: { npx: { package: '@example/healthy-agent@1.2.3' } },
        },
        {
          id: 'broken-agent', name: '', version: '1.0.0',
          distribution: { npx: { package: '@example/broken-agent' } },
        },
        {
          id: 'healthy-agent', name: 'Ambiguous Replacement', version: '9.9.9',
          distribution: { npx: { package: '@attacker/replacement@9.9.9' } },
        },
        {
          id: 'second-agent', name: 'Second Agent', version: '2.0.0',
          distribution: { uvx: { package: 'second-agent==2.0.0' } },
        },
      ],
    })

    expect(packs.map(pack => pack.id)).toEqual(['healthy-agent', 'second-agent'])
    expect(packs[0]?.distribution).toMatchObject({
      kind: 'npx', package: '@example/healthy-agent@1.2.3',
    })
  })

  it('bounds the untrusted ACP Registry before projecting Pack rows', () => {
    const row = {
      id: 'bounded-agent', name: 'Bounded Agent', version: '1.0.0',
      distribution: { npx: { package: '@example/bounded-agent' } },
    }
    expect(() => packsFromAcpRegistry({
      version: '1',
      agents: Array.from({ length: 4_097 }, (_, index) => ({ ...row, id: `agent-${index}` })),
    })).toThrow()
    expect(packsFromAcpRegistry({
      version: '1',
      agents: [{ ...row, distribution: { npx: {
        package: '@example/bounded-agent', args: Array.from({ length: 129 }, () => '--argument'),
      } } }],
    })).toEqual([])
    expect(packsFromAcpRegistry({
      version: '1',
      agents: [{ ...row, distribution: { binary: Object.fromEntries(
        Array.from({ length: 33 }, (_, index) => [`linux-target-${index}`, {
          archive: `https://example.com/agent-${index}.tar.gz`, cmd: './agent', sha256: 'a'.repeat(64),
        }]),
      ) } }],
    })).toEqual([])
  })

  it('keeps account, model ownership, and generic ACP credential metadata data-driven', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'future-auth', name: 'Future Auth', version: '1.0.0', publisher: 'Future',
      verified: false, protocol: 'acp', source: 'user',
      account: { label: 'Future account', billing: 'usage', detail: 'Bills the selected Future provider account.' },
      modelConfiguration: { owner: 'harness', required: false, detail: 'Models come from the live Future session.' },
      authMethods: [{
        id: 'vendor-token', name: 'Vendor token', kind: 'agent',
        fields: [{ ref: 'FUTURE_TOKEN', name: 'Future token', required: true, secret: true }],
        agent: { metaKey: 'vendor-auth', fieldMap: { FUTURE_TOKEN: 'token' } },
      }],
      distribution: { kind: 'npx', package: '@future/acp@1.0.0', args: [], env: {} },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    })
    expect(pack.account?.label).toBe('Future account')
    expect(pack.modelConfiguration?.owner).toBe('harness')
    expect(pack.authMethods?.[0]?.agent).toEqual({ metaKey: 'vendor-auth', fieldMap: { FUTURE_TOKEN: 'token' } })
  })

  it('accepts uvx, terminal authentication data, and editable node configuration', () => {
    const evidence = [{ kind: 'declared', source: 'Python Agent manifest', version: '1.4.0' }]
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'python-agent', name: 'Python Agent', version: '1.4.0', publisher: 'Community',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'uvx', package: 'python-agent==1.4.0', args: ['acp'], env: { NO_UPDATE: '1' } },
      authMethods: [{
        id: 'login', name: 'Login', kind: 'terminal', fields: [],
        account: { label: 'Python Agent account', billing: 'harness-managed', detail: 'Billing is managed by Python Agent.' },
        terminal: { args: ['login'], env: {} },
      }],
      graph: {
        level: 'composable', manifestVersion: 1, boundary: 'Python Agent process', evidence,
        nodes: [
          { id: 'input', kind: 'input', title: 'Input', editable: false, responsibility: 'Accepts ACP prompts.', evidence },
          {
            id: 'model', kind: 'model', title: 'Model', editable: true,
            responsibility: 'Selects the model route.', evidence,
            configSchema: { version: 1, fields: [{
              id: 'provider', name: 'Provider', type: 'string', required: true,
              binding: { kind: 'acp-session-option', target: 'provider' },
            }] },
            config: { provider: 'user' },
          },
          { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes ACP updates.', evidence },
        ],
        edges: [{ from: 'input', to: 'model' }, { from: 'model', to: 'output' }],
      },
    })
    expect(pack.distribution?.kind).toBe('uvx')
    expect(pack.authMethods?.[0]?.terminal?.args).toEqual(['login'])
    expect(pack.authMethods?.[0]?.account?.billing).toBe('harness-managed')
    expect(pack.graph.nodes[1]?.config).toEqual({ provider: 'user' })
  })

  it('keeps canvas placement separate from executable Driver configuration', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'layout-only', name: 'Layout only', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/layout-only@1.0.0', args: [], env: {} },
      graph: {
        level: 'opaque',
        nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false, config: { x: 120, y: 80 } }],
        edges: [],
      },
    })
    expect(pack.graph.nodes[0]?.position).toEqual({ x: 120, y: 80 })
    expect(pack.graph.nodes[0]?.config).toBeUndefined()
  })

  it('rejects undeclared or nested executable configuration before persistence', () => {
    const evidence = [{ kind: 'declared', source: 'Typed configuration test' }]
    const candidate = {
      schemaVersion: 0, id: 'typed-only', name: 'Typed only', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/typed-only@1.0.0', args: [], env: {} },
      graph: {
        level: 'composable', boundary: 'Typed process', evidence,
        nodes: [{
          id: 'session', kind: 'agent-session', title: 'Session', editable: true,
          responsibility: 'Applies a declared option.', evidence,
          configSchema: { version: 1, fields: [{
            id: 'mode', name: 'Mode', type: 'string', required: true,
            binding: { kind: 'acp-session-option', target: 'mode' },
          }] },
          config: { mode: 'safe' },
        }],
        edges: [],
      },
    }
    expect(() => parseHarnessPack({
      ...candidate,
      graph: { ...candidate.graph, nodes: candidate.graph.nodes.map(node => ({
        ...node, config: { ...node.config, undeclared: 'value' },
      })) },
    })).toThrow('undeclared field')
    expect(() => parseHarnessPack({
      ...candidate,
      graph: { ...candidate.graph, nodes: candidate.graph.nodes.map(node => ({
        ...node, config: { mode: { nested: true } },
      })) },
    })).toThrow()
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
        license: 'MIT', repository: 'https://github.com/example/public-agent',
        verified: true, protocol: 'acp', source: 'user',
        distribution: { kind: 'npx', package: '@community/public-agent@1.2.3', args: ['acp'], env: {} },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })
    expect(pack).toMatchObject({ id: 'community.public-agent', source: 'openfish-community', verified: false })
  })

  it('parses explicit community revocations separately from discoverability', () => {
    const catalog = openFishCommunityCatalog({
      version: 0,
      packs: [],
      revocations: [{
        id: 'community.retired', version: '1.2.3', reason: 'Publisher key compromise',
        revokedAt: '2026-08-22T12:00:00.000Z', reviewUrl: 'https://github.com/example/review/42',
      }],
    })
    expect(catalog.packs).toEqual([])
    expect(catalog.revocations).toEqual([expect.objectContaining({
      id: 'community.retired', version: '1.2.3', reason: 'Publisher key compromise',
    })])
  })

  it('rejects floating package versions in the community catalog', () => {
    expect(() => packsFromOpenFishCommunity({
      version: 0,
      packs: [{
        schemaVersion: 0, id: 'community.floating', name: 'Floating', version: '1', publisher: 'Community',
        license: 'MIT', repository: 'https://github.com/example/floating',
        protocol: 'acp', distribution: { kind: 'npx', package: '@community/floating@latest', args: [], env: {} },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })).toThrow('exact version')
  })

  it('rejects floating Python package versions in user Packs', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'python-floating', name: 'Python Floating', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'uvx', package: 'python-floating>=1', args: [], env: {} },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    })).toThrow('exact version')
  })

  it('rejects credential values from the public community catalog', () => {
    expect(() => packsFromOpenFishCommunity({
      version: 0,
      packs: [{
        schemaVersion: 0, id: 'community.leaked', name: 'Leaked', version: '1.0.0', publisher: 'Community',
        license: 'MIT', repository: 'https://github.com/example/leaked',
        protocol: 'acp', distribution: { kind: 'npx', package: '@community/leaked@1.0.0', args: [], env: { API_KEY: 'private' } },
        graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
      }],
    })).toThrow('cannot store a value')
  })

  it('rejects credential values before a user Pack can be persisted', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'user.leaked', name: 'Leaked', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'acp', source: 'user',
      distribution: {
        kind: 'npx', package: '@example/user-agent@1.0.0', args: [], env: { SERVICE_TOKEN: 'private' },
      },
      graph: {
        level: 'opaque',
        nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }],
        edges: [],
      },
    })).toThrow('declare an Authentication field instead')
  })

  it('stores only Host credential references in executable Pack controls', () => {
    const evidence = [{ kind: 'declared', source: 'Credential reference test' }]
    const candidate = {
      schemaVersion: 0, id: 'user.reference', name: 'Reference', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'private-runtime', source: 'user',
      distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
      graph: {
        level: 'composable', boundary: 'Private Runtime', evidence,
        nodes: [
          { id: 'input', kind: 'input', title: 'Input', editable: false, responsibility: 'Accepts work.', evidence },
          {
            id: 'provider', kind: 'model-router', title: 'Provider', editable: true,
            responsibility: 'Resolves a Host-owned provider credential.', evidence,
            configSchema: { version: 1, fields: [{
              id: 'credential', name: 'Credential', type: 'secret-reference', required: true,
              binding: { kind: 'provider-credential', target: 'api-key' },
            }] },
            config: { credential: 'OPENAI_API_KEY' },
          },
          { id: 'output', kind: 'output', title: 'Output', editable: false, responsibility: 'Publishes work.', evidence },
        ],
        edges: [{ from: 'input', to: 'provider' }, { from: 'provider', to: 'output' }],
      },
    }
    expect(parseHarnessPack(candidate).graph.nodes[1]?.config?.credential).toBe('OPENAI_API_KEY')
    expect(() => parseHarnessPack({
      ...candidate,
      graph: {
        ...candidate.graph,
        nodes: candidate.graph.nodes.map(node => node.id === 'provider'
          ? { ...node, config: { credential: 'sk-not-a-reference-value' } }
          : node),
      },
    })).toThrow('must store a Host credential reference')
  })

  it('rejects credentialed or private publication locations', () => {
    const base = {
      schemaVersion: 0, id: 'community.safe', name: 'Safe', version: '1.0.0', publisher: 'Community',
      license: 'MIT', verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@community/safe@1.0.0', args: [], env: {} },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    }
    expect(() => prepareHarnessPublication({
      ...base, repository: 'https://token@example.com/community/safe',
    })).toThrow('public HTTPS source repository')
    expect(() => prepareHarnessPublication({
      ...base, repository: 'https://github.com/example/safe', description: 'Built at /Users/private/source',
    })).toThrow('private or credential-like data')
    expect(() => prepareHarnessPublication({
      ...base, repository: 'https://github.com/example/safe',
      distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
    })).toThrow('portable package or checksummed binary')
    expect(() => prepareHarnessPublication({
      ...base, repository: 'https://github.com/example/safe',
      distribution: { kind: 'binary', archive: 'https://example.com/safe.tar.gz', command: 'safe', args: [], env: {} },
    })).toThrow('SHA-256 checksum')
  })

  it('accepts a small observable graph when its one real responsibility is explained and evidenced', () => {
    const evidence = [{ kind: 'source-derived', source: 'https://example.com/runtime', version: '1.0.0' }]
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'small-runtime', name: 'Small Runtime', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/small-runtime@1.0.0', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Small Runtime process', evidence,
        nodes: [{
          id: 'loop', kind: 'agent-loop', title: 'Agent loop', editable: false,
          responsibility: 'Owns the complete documented prompt, tool, and response loop.', evidence,
        }],
        edges: [],
      },
    })
    expect(pack.graph.nodes).toHaveLength(1)
  })

  it('admits an exact self-installing Driver Bundle and namespaced runtime signals for a public new protocol', () => {
    const evidence = [{ kind: 'declared', source: 'Future protocol manifest', version: '2.0.0' }]
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'community.future-runtime', name: 'Future Runtime', version: '2.0.0', publisher: 'Future',
      license: 'MIT', repository: 'https://github.com/example/future-runtime', verified: false,
      protocol: 'future-protocol', source: 'openfish-community',
      driverBundle: {
        apiVersion: 1,
        package: '@example/openfish-driver-future',
        spec: '@example/openfish-driver-future@1.2.3',
        requiresInstallScripts: false,
      },
      distribution: { kind: 'npx', package: '@example/future-runtime@2.0.0', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Future Runtime process', evidence,
        nodes: [
          {
            id: 'loop', kind: 'agent-loop', title: 'Loop', editable: false,
            responsibility: 'Owns future-protocol turns.', evidence,
            observes: ['driver.future-protocol.turn-settled'],
          },
          {
            id: 'output', kind: 'output', title: 'Output', editable: false,
            responsibility: 'Publishes typed future-protocol output.', evidence,
          },
        ],
        edges: [{
          from: 'loop', to: 'output', label: 'typed update',
          observes: ['driver.future-protocol.output-published'],
        }],
      },
    })
    expect(pack.driverBundle?.spec).toBe('@example/openfish-driver-future@1.2.3')
    expect(pack.graph.edges[0]?.label).toBe('typed update')
  })

  it('rejects public new protocols without an exact, identity-matched Driver Bundle', () => {
    const base = {
      schemaVersion: 0, id: 'community.future-runtime', name: 'Future Runtime', version: '2.0.0', publisher: 'Future',
      verified: false, protocol: 'future-protocol', source: 'openfish-community',
      distribution: { kind: 'npx', package: '@example/future-runtime@2.0.0', args: [], env: {} },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    }
    expect(() => parseHarnessPack(base)).toThrow('requires an exact self-installable Driver Bundle')
    expect(() => parseHarnessPack({
      ...base,
      driverBundle: {
        apiVersion: 1, package: '@example/openfish-driver-future',
        spec: '@example/different-driver@1.2.3', requiresInstallScripts: false,
      },
    })).toThrow('does not match package')
    expect(() => parseHarnessPack({
      ...base,
      driverBundle: {
        apiVersion: 1, package: '@example/openfish-driver-future',
        spec: '@example/openfish-driver-future@latest', requiresInstallScripts: false,
      },
    })).toThrow('must pin an exact npm version or GitHub commit')
  })

  it('does not let a Pack replace an OpenFish-bundled protocol Driver', () => {
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'user.acp-override', name: 'ACP Override', version: '1.0.0', publisher: 'User',
      verified: false, protocol: 'acp', source: 'user',
      driverBundle: {
        apiVersion: 1, package: '@example/acp-override', spec: '@example/acp-override@1.0.0',
        requiresInstallScripts: false,
      },
      distribution: { kind: 'npx', package: '@example/acp-runtime@1.0.0', args: [], env: {} },
      graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
    })).toThrow('cannot replace bundled protocol Driver "acp"')
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

  it('rejects observable manifests whose declared responsibilities are disconnected', () => {
    const evidence = [{ kind: 'declared', source: 'Disconnected test manifest' }]
    expect(() => parseHarnessPack({
      schemaVersion: 0, id: 'disconnected', name: 'Disconnected', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/disconnected@1.0.0', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Disconnected process', evidence,
        nodes: [
          { id: 'one', kind: 'input', title: 'One', editable: false, responsibility: 'Accepts input.', evidence },
          { id: 'two', kind: 'runtime', title: 'Two', editable: false, responsibility: 'Runs work.', evidence },
          { id: 'three', kind: 'output', title: 'Three', editable: false, responsibility: 'Publishes output.', evidence },
        ],
        edges: [{ from: 'one', to: 'two' }, { from: 'two', to: 'one' }],
      },
    })).toThrow('connect every declared component')
  })
})

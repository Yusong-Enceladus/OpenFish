import { describe, expect, it } from 'vitest'
import { harnessCatalogEntrySchema } from '../src/api/harnesses.schema.ts'

describe('Harness catalog wire schema', () => {
  it('preserves portable distribution and architecture data for native Studio clients', () => {
    const evidence = [{ kind: 'declared', source: 'Demo Pack', version: '1.2.3' }]
    const row = harnessCatalogEntrySchema.parse({
      schemaVersion: 0, id: 'community.demo', name: 'Demo', version: '1.2.3', publisher: 'Community', verified: false,
      protocol: 'acp', source: 'openfish-community', isDefault: false,
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
        edges: [{ from: 'input', to: 'runtime' }, { from: 'runtime', to: 'output' }],
      },
      available: true,
      installation: { status: 'not-installed', availableVersion: '1.2.3', previousVersions: [] },
      auth: { methods: [], status: 'not-required', missingFields: [] },
      compatibility: { status: 'untested' },
      capabilities: [
        { id: 'session.create', status: 'supported', source: 'driver' },
        { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      ],
      driver: { apiVersion: 1, protocol: 'acp', loaded: true },
    })
    expect(row.distribution).toEqual({
      kind: 'npx', package: '@community/demo@1.2.3', args: ['acp'], env: { NO_UPDATE: '1' },
    })
    expect(row.graph.nodes[1]?.config).toEqual({ model: 'user' })
    expect(row.graph.boundary).toBe('Demo Harness process')
    expect(row.graph.nodes[1]?.evidence).toEqual(evidence)
    expect(row.driver).toEqual({ apiVersion: 1, protocol: 'acp', loaded: true })
  })
})

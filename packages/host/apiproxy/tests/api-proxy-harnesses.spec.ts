import { describe, expect, it } from 'vitest'
import { harnessCatalogEntrySchema } from '../src/api/harnesses.schema.ts'

describe('Harness catalog wire schema', () => {
  it('preserves portable distribution and architecture data for native Studio clients', () => {
    const row = harnessCatalogEntrySchema.parse({
      schemaVersion: 0, id: 'community.demo', name: 'Demo', version: '1.2.3', publisher: 'Community', verified: false,
      protocol: 'acp', source: 'openfish-community', isDefault: false,
      distribution: { kind: 'npx', package: '@community/demo@1.2.3', args: ['acp'], env: { NO_UPDATE: '1' } },
      graph: {
        level: 'composable',
        nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: true, config: { model: 'user' } }],
        edges: [],
      },
      available: true,
      installation: { status: 'not-installed', availableVersion: '1.2.3', previousVersions: [] },
      auth: { methods: [], status: 'not-required', missingFields: [] },
      compatibility: { status: 'untested' },
    })
    expect(row.distribution).toEqual({
      kind: 'npx', package: '@community/demo@1.2.3', args: ['acp'], env: { NO_UPDATE: '1' },
    })
    expect(row.graph.nodes[0]?.config).toEqual({ model: 'user' })
  })
})

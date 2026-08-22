import { describe, expect, it } from 'vitest'
import { inspectHarnessDriver } from '../src/conformance.ts'
import { parseHarnessPack } from '../src/manifest.ts'
import type { HarnessDriver } from '../src/types.ts'

const candidate = parseHarnessPack({
  schemaVersion: 0, id: 'future.driver', name: 'Future Driver', version: '1.0.0', publisher: 'Fixture',
  verified: false, protocol: 'future-protocol', source: 'user',
  distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
  graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'harness-runtime', title: 'Future runtime', editable: false }], edges: [] },
})

function driver(capabilities: HarnessDriver['capabilities']): HarnessDriver {
  return {
    apiVersion: 1, protocol: 'future-protocol', capabilities,
    available: async () => undefined,
    create: async () => { throw new Error('fixture does not launch') },
    resume: async () => { throw new Error('fixture does not launch') },
  }
}

describe('Harness Driver API v1 conformance', () => {
  it('admits a new non-ACP Driver without native-client knowledge', async () => {
    const report = await inspectHarnessDriver(driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      { id: 'configuration.models', status: 'runtime', source: 'runtime' },
    ]), candidate)
    expect(report).toMatchObject({ apiVersion: 1, protocol: 'future-protocol', compatible: true, issues: [] })
  })

  it('rejects a capability-inconsistent Driver before launch', async () => {
    const report = await inspectHarnessDriver(driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'architecture.edit', status: 'supported', source: 'driver' },
    ]), candidate)
    expect(report.compatible).toBe(false)
    expect(report.issues.join(' ')).toContain('declared more than once')
    expect(report.issues.join(' ')).toContain('session.resume')
    expect(report.issues.join(' ')).toContain('composable')
  })
})

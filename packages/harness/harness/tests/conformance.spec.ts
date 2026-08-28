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

const composableCandidate = parseHarnessPack({
  schemaVersion: 0, id: 'future.composable', name: 'Future Composable', version: '1.0.0', publisher: 'Fixture',
  verified: false, protocol: 'future-protocol', source: 'user',
  distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
  graph: {
    level: 'composable', boundary: 'Future composable process',
    evidence: [{ kind: 'declared', source: 'Future conformance fixture' }],
    nodes: [{
      id: 'step', kind: 'future-step', title: 'Future step', editable: true,
      responsibility: 'Applies one future Driver setting.',
      evidence: [{ kind: 'declared', source: 'Future conformance fixture' }],
      configSchema: {
        version: 1,
        fields: [{
          id: 'enabled', name: 'Enabled', type: 'boolean', required: true,
          binding: { kind: 'future-setting', target: 'step.enabled' },
        }],
      },
      config: { enabled: true },
    }],
    edges: [],
  },
})

function driver(capabilities: HarnessDriver['capabilities']): HarnessDriver {
  return {
    apiVersion: 1, protocol: 'future-protocol', capabilities,
    available: async () => undefined,
    create: async () => { throw new Error('fixture does not launch') },
    resume: async () => { throw new Error('fixture does not launch') },
    dispose: async () => undefined,
  }
}

describe('Harness Driver API v1 conformance', () => {
  it('admits a new non-ACP Driver without native-client knowledge', async () => {
    const report = await inspectHarnessDriver(driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
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

  it('rejects a runtime Driver that cannot release abandoned sessions', async () => {
    const incomplete = driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    ]) as unknown as Record<string, unknown>
    delete incomplete.dispose

    const report = await inspectHarnessDriver(incomplete as unknown as HarnessDriver, candidate)
    expect(report.compatible).toBe(false)
    expect(report.issues.join(' ')).toContain('session disposal')
  })

  it('rejects a Driver that advertises fork without a real protocol fork primitive', async () => {
    const report = await inspectHarnessDriver(driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'session.fork', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    ]), candidate)

    expect(report.compatible).toBe(false)
    expect(report.issues).toContain('A Driver advertising session.fork must implement a real remote fork primitive.')
  })

  it('reports every missing required method without throwing during inspection', async () => {
    const incomplete = {
      apiVersion: 1,
      protocol: 'future-protocol',
    } as unknown as HarnessDriver

    const report = await inspectHarnessDriver(incomplete, candidate)

    expect(report.compatible).toBe(false)
    for (const method of ['capabilities', 'available', 'create', 'resume', 'dispose']) {
      expect(report.issues.join(' ')).toContain(`required method "${method}"`)
    }
  })

  it('turns malformed runtime capability data into an incompatible report instead of throwing', async () => {
    const malformed = driver(async () => ({ session: 'create' }) as never)
    const report = await inspectHarnessDriver(malformed, candidate)

    expect(report).toMatchObject({
      compatible: false,
      capabilities: [],
    })
    expect(report.issues.join(' ')).toContain('capabilities result must be an array')
    expect(report.issues.join(' ')).toContain('Required capability "session.create" is missing')
  })

  it('normalizes malformed Builder schema data without exposing it to clients', async () => {
    const malformed = driver(async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      { id: 'architecture.edit', status: 'supported', source: 'driver' },
    ])
    malformed.authoring = async () => ({
      nodeKinds: [{ kind: 42, editable: 'yes', inputs: null }],
      bindingKinds: 'not-an-array',
    }) as never
    malformed.validatePack = async () => ({ valid: true }) as never

    const report = await inspectHarnessDriver(malformed, composableCandidate)

    expect(report.compatible).toBe(false)
    expect(report.authoring).toEqual({ nodeKinds: [], bindingKinds: [] })
    expect(report.issues.join(' ')).toContain('nodeKinds and bindingKinds arrays')
    expect(report.issues.join(' ')).toContain('validation result must be a text array')
    expect(report.issues.join(' ')).toContain('unregistered Driver node kind')
  })

  it('rejects older and newer Driver APIs with an actionable Host range', async () => {
    const older = driver(async () => []) as HarnessDriver & { apiVersion: number }
    Object.defineProperty(older, 'apiVersion', { value: 0 })
    const newer = driver(async () => []) as HarnessDriver & { apiVersion: number }
    Object.defineProperty(newer, 'apiVersion', { value: 2 })

    const oldReport = await inspectHarnessDriver(older, candidate)
    const newReport = await inspectHarnessDriver(newer, candidate)

    expect(oldReport).toMatchObject({ compatible: false, hostApiRange: { min: 1, max: 1 } })
    expect(oldReport.issues.join(' ')).toContain('positive integer')
    expect(newReport).toMatchObject({ compatible: false, hostApiRange: { min: 1, max: 1 } })
    expect(newReport.issues.join(' ')).toContain('newer than the maximum supported Host API v1')
  })

  it('requires a real Driver event mapper for protocol-specific runtime signals', async () => {
    const evidence = [{ kind: 'declared', source: 'Future Driver observation test' }]
    const observedPack = parseHarnessPack({
      schemaVersion: 0, id: 'future.observed', name: 'Future Observed', version: '1.0.0', publisher: 'Fixture',
      verified: false, protocol: 'future-protocol', source: 'user',
      distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
      graph: {
        level: 'observable', boundary: 'Future process', evidence,
        nodes: [{
          id: 'loop', kind: 'agent-loop', title: 'Loop', editable: false,
          responsibility: 'Owns protocol-specific turn settlement.', evidence,
          observes: ['driver.future-protocol.turn-settled'],
        }],
        edges: [],
      },
    })
    const capabilities: HarnessDriver['capabilities'] = async () => [
      { id: 'session.create', status: 'supported', source: 'driver' },
      { id: 'session.resume', status: 'supported', source: 'driver' },
      { id: 'workspace.no-project', status: 'supported', source: 'driver' },
      { id: 'architecture.manifest', status: 'supported', source: 'pack' },
      { id: 'architecture.runtime-observation', status: 'supported', source: 'driver' },
    ]
    const missing = await inspectHarnessDriver(driver(capabilities), observedPack)
    expect(missing.compatible).toBe(false)
    expect(missing.issues.join(' ')).toContain('runtimeSignals event mapper')

    const mapped = driver(capabilities)
    mapped.runtimeSignals = () => [{ signal: 'driver.future-protocol.turn-settled', status: 'completed' }]
    const report = await inspectHarnessDriver(mapped, observedPack)
    expect(report).toMatchObject({ compatible: true, issues: [] })
  })
})

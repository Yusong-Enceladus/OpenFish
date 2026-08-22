/** Versioned Harness Driver admission checks shared by tests and the live catalog. @module */

import type { HarnessCapability, HarnessCapabilityId, HarnessDriver, HarnessPack } from './types.ts'

const KNOWN_CAPABILITIES = new Set<HarnessCapabilityId>([
  'lifecycle.install', 'lifecycle.update', 'lifecycle.rollback', 'lifecycle.uninstall',
  'session.create', 'session.resume', 'session.cancel',
  'session.fork', 'session.archive', 'workspace.project', 'workspace.no-project',
  'configuration.models', 'configuration.reasoning', 'configuration.auth',
  'interaction.tools', 'interaction.approvals', 'interaction.questions', 'interaction.files', 'interaction.events',
  'architecture.manifest', 'architecture.runtime-observation', 'architecture.edit',
  'diagnostics.preflight', 'builder.manifest', 'builder.test', 'builder.publish',
])

export interface HarnessDriverConformanceReport {
  protocol: string
  apiVersion: 1
  capabilities: HarnessCapability[]
  issues: string[]
  compatible: boolean
}

/** Inspect one concrete Driver/Pack pair without starting a model-billed session. */
export async function inspectHarnessDriver(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessDriverConformanceReport> {
  const issues: string[] = []
  if (driver.apiVersion !== 1) issues.push('Driver API version must be 1.')
  if (driver.protocol !== pack.protocol) issues.push(`Driver protocol "${driver.protocol}" does not match Pack protocol "${pack.protocol}".`)
  let capabilities: HarnessCapability[] = []
  try { capabilities = await driver.capabilities(pack) } catch (error: unknown) {
    issues.push(`Capability negotiation failed: ${error instanceof Error ? error.message : String(error)}`)
  }
  const seen = new Set<string>()
  for (const capability of capabilities) {
    if (!KNOWN_CAPABILITIES.has(capability.id)) issues.push(`Unknown capability "${capability.id}".`)
    if (seen.has(capability.id)) issues.push(`Capability "${capability.id}" is declared more than once.`)
    seen.add(capability.id)
  }
  for (const required of ['session.create', 'session.resume', 'architecture.manifest'] as const) {
    if (!capabilities.some(item => item.id === required && item.status !== 'unsupported')) issues.push(`Required capability "${required}" is missing.`)
  }
  const edit = capabilities.find(item => item.id === 'architecture.edit')
  if (edit?.status === 'supported' && pack.graph.level !== 'composable') issues.push('Architecture editing requires a composable Pack graph.')
  if (pack.distribution !== undefined && pack.distribution.kind !== 'executable' && driver.install === undefined) {
    issues.push(`Pack distribution "${pack.distribution.kind}" requires Driver installation support.`)
  }
  return { protocol: driver.protocol, apiVersion: 1, capabilities, issues, compatible: issues.length === 0 }
}

/** Reject a Driver/Pack pair with one deterministic, user-actionable error. */
export async function assertHarnessDriverConformance(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessCapability[]> {
  const report = await inspectHarnessDriver(driver, pack)
  if (!report.compatible) throw new Error(`Harness Driver conformance failed: ${report.issues.join(' ')}`)
  return report.capabilities
}

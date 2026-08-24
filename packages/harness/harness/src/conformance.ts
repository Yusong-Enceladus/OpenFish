/** Versioned Harness Driver admission checks shared by tests and the live catalog. @module */

import type { HarnessCapability, HarnessCapabilityId, HarnessDriver, HarnessPack } from './types.ts'

const KNOWN_CAPABILITIES = new Set<HarnessCapabilityId>([
  'lifecycle.install', 'lifecycle.update', 'lifecycle.rollback', 'lifecycle.uninstall',
  'session.create', 'session.resume', 'session.cancel',
  'session.fork', 'session.archive', 'workspace.project', 'workspace.no-project',
  'configuration.models', 'configuration.reasoning', 'configuration.auth', 'configuration.agent-presets',
  'interaction.tools', 'interaction.approvals', 'interaction.questions', 'interaction.files', 'interaction.events',
  'architecture.manifest', 'architecture.runtime-observation', 'architecture.edit',
  'diagnostics.preflight', 'builder.manifest', 'builder.test', 'builder.publish',
])

/** Complete, non-mutating admission result for one concrete Driver and Pack pair. */
export interface HarnessDriverConformanceReport {
  protocol: string
  apiVersion: number
  hostApiRange: { min: number; max: number }
  capabilities: HarnessCapability[]
  issues: string[]
  compatible: boolean
}

/** Driver API range implemented by this OpenFish Host. */
export const HARNESS_DRIVER_API_RANGE = Object.freeze({ min: 1, max: 1 })

/**
 * Deterministic negotiation result exposed to plugin authors and admission diagnostics.
 * @param apiVersion - positive Driver API version declared by the implementation.
 * @returns compatibility, the Host range, and a stable explanatory message.
 */
export function negotiateHarnessDriverApi(apiVersion: number): {
  compatible: boolean
  hostApiRange: { min: number; max: number }
  message: string
} {
  const hostApiRange = { ...HARNESS_DRIVER_API_RANGE }
  if (!Number.isSafeInteger(apiVersion) || apiVersion < 1) {
    return { compatible: false, hostApiRange, message: 'Driver API version must be a positive integer.' }
  }
  if (apiVersion < hostApiRange.min) {
    return {
      compatible: false,
      hostApiRange,
      message: `Driver API v${apiVersion} is older than the minimum supported Host API v${hostApiRange.min}.`,
    }
  }
  if (apiVersion > hostApiRange.max) {
    return {
      compatible: false,
      hostApiRange,
      message: `Driver API v${apiVersion} is newer than the maximum supported Host API v${hostApiRange.max}.`,
    }
  }
  return { compatible: true, hostApiRange, message: `Driver API v${apiVersion} negotiated.` }
}

/**
 * Inspect one concrete Driver/Pack pair without starting a model-billed session.
 * @param driver - loaded implementation to negotiate and inspect.
 * @param pack - admitted manifest the Driver claims to implement.
 * @returns the complete capability and compatibility report.
 */
export async function inspectHarnessDriver(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessDriverConformanceReport> {
  const issues: string[] = []
  const candidate = driver as unknown as Record<string, unknown>
  const apiVersion = typeof candidate.apiVersion === 'number' ? candidate.apiVersion : Number.NaN
  const protocol = typeof candidate.protocol === 'string' ? candidate.protocol : ''
  const api = negotiateHarnessDriverApi(apiVersion)
  if (!api.compatible) issues.push(api.message)
  if (typeof protocol !== 'string' || !/^[a-z0-9][a-z0-9._-]*$/u.test(protocol)) {
    issues.push('Driver protocol must be a stable lowercase identifier.')
  } else if (protocol !== pack.protocol) {
    issues.push(`Driver protocol "${protocol}" does not match Pack protocol "${pack.protocol}".`)
  }
  const requiredMethods = ['capabilities', 'available', 'create', 'resume', 'dispose'] as const
  for (const method of requiredMethods) {
    if (typeof candidate[method] !== 'function') issues.push(`Driver must implement required method "${method}".`)
  }
  if (typeof candidate.dispose !== 'function') {
    issues.push('Driver must implement session disposal so abandoned drafts cannot leak Harness processes.')
  }
  let capabilities: HarnessCapability[] = []
  if (typeof candidate.capabilities === 'function') {
    try { capabilities = await driver.capabilities(pack) } catch (error: unknown) {
      issues.push(`Capability negotiation failed: ${error instanceof Error ? error.message : String(error)}`)
    }
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
  if (!capabilities.some(item => (item.id === 'workspace.project' || item.id === 'workspace.no-project')
    && item.status !== 'unsupported')) {
    issues.push('Driver must support at least one workspace mode.')
  }
  const models = capabilities.find(item => item.id === 'configuration.models')
  const reasoning = capabilities.find(item => item.id === 'configuration.reasoning')
  if (reasoning !== undefined && reasoning.status !== 'unsupported'
    && (models === undefined || models.status === 'unsupported')) {
    issues.push('Reasoning configuration cannot be supported when model configuration is unsupported.')
  }
  const authentication = capabilities.find(item => item.id === 'configuration.auth')
  if ((pack.authMethods?.length ?? 0) > 0
    && (authentication === undefined || authentication.status === 'unsupported')) {
    issues.push('A Pack with authentication methods requires configuration.auth support.')
  }
  const fork = capabilities.find(item => item.id === 'session.fork')
  if (fork !== undefined && fork.status !== 'unsupported' && driver.fork === undefined) {
    issues.push('A Driver advertising session.fork must implement a real remote fork primitive.')
  }
  const edit = capabilities.find(item => item.id === 'architecture.edit')
  if (edit?.status === 'supported' && pack.graph.level !== 'composable') issues.push('Architecture editing requires a composable Pack graph.')
  const editableNodes = pack.graph.nodes.filter(node => node.editable)
  if (editableNodes.length > 0 && driver.validatePack === undefined) {
    issues.push('Composable editable nodes require Driver validation; visual metadata alone is not executable behavior.')
  }
  if (driver.validatePack !== undefined) {
    try { issues.push(...await driver.validatePack(pack)) } catch (error: unknown) {
      issues.push(`Driver Pack validation failed: ${error instanceof Error ? error.message : String(error)}`)
    }
  }
  const observation = capabilities.find(item => item.id === 'architecture.runtime-observation')
  if (observation !== undefined && observation.status !== 'unsupported'
    && !pack.graph.nodes.some(node => (node.observes?.length ?? 0) > 0)
    && !pack.graph.edges.some(edge => (edge.observes?.length ?? 0) > 0)) {
    issues.push('Runtime observation requires at least one Pack-declared node or edge signal binding.')
  }
  const customRuntimeSignals = [
    ...pack.graph.nodes.flatMap(node => node.observes ?? []),
    ...pack.graph.edges.flatMap(edge => edge.observes ?? []),
  ].filter(signal => signal.startsWith('driver.'))
  if (customRuntimeSignals.length > 0 && driver.runtimeSignals === undefined) {
    issues.push('Pack-declared Driver runtime signals require the Driver runtimeSignals event mapper.')
  }
  if (pack.distribution !== undefined && pack.distribution.kind !== 'executable' && driver.install === undefined) {
    issues.push(`Pack distribution "${pack.distribution.kind}" requires Driver installation support.`)
  }
  return { protocol, apiVersion, hostApiRange: api.hostApiRange, capabilities, issues, compatible: issues.length === 0 }
}

/**
 * Reject a Driver/Pack pair with one deterministic, user-actionable error.
 * @param driver - loaded implementation to admit.
 * @param pack - admitted manifest the Driver claims to implement.
 * @returns negotiated capabilities when every conformance rule passes.
 */
export async function assertHarnessDriverConformance(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessCapability[]> {
  const report = await inspectHarnessDriver(driver, pack)
  if (!report.compatible) throw new Error(`Harness Driver conformance failed: ${report.issues.join(' ')}`)
  return report.capabilities
}

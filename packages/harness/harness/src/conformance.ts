/** Versioned Harness Driver admission checks shared by tests and the live catalog. @module */

import type {
  HarnessAuthoringContract,
  HarnessCapability,
  HarnessCapabilityId,
  HarnessConfigField,
  HarnessDriver,
  HarnessNodeConfigValue,
  HarnessPack,
} from './types.ts'
import { safeHarnessDiagnostic } from './diagnostic.ts'

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
  authoring: HarnessAuthoringContract
  issues: string[]
  compatible: boolean
}

const CAPABILITY_STATUSES = new Set(['supported', 'runtime', 'unsupported'])
const CAPABILITY_SOURCES = new Set(['host', 'pack', 'driver', 'runtime'])
const CONFIG_FIELD_TYPES = new Set(['string', 'boolean', 'select', 'secret-reference'])
const PORTABLE_TARGET_PATTERN = /^\^(?:\[[A-Za-z0-9._-]+\][*+?]?)+\$$/u
const MAX_DRIVER_TEXT = 8_192
const MAX_DRIVER_CAPABILITIES = 64
const MAX_DRIVER_BINDING_KINDS = 128
const MAX_DRIVER_NODE_KINDS = 256
const MAX_DRIVER_PORTS = 64
const MAX_DRIVER_CONTROLS = 64
const MAX_DRIVER_CHOICES = 128

function emptyAuthoring(): HarnessAuthoringContract {
  return { nodeKinds: [], bindingKinds: [] }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function textProperty(
  value: Record<string, unknown>,
  property: string,
  owner: string,
  issues: string[],
  optional = false,
): string | undefined {
  const candidate = value[property]
  if (candidate === undefined && optional) return undefined
  if (typeof candidate !== 'string') {
    issues.push(`${owner} property "${property}" must be text.`)
    return optional ? undefined : ''
  }
  if (candidate.length > MAX_DRIVER_TEXT || /[\u0000\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(candidate)) {
    issues.push(`${owner} property "${property}" contains invalid or excessive text.`)
    return optional ? undefined : ''
  }
  return candidate
}

function textArrayProperty(
  value: Record<string, unknown>,
  property: string,
  owner: string,
  issues: string[],
): string[] {
  const candidate = value[property]
  if (!Array.isArray(candidate) || candidate.length > MAX_DRIVER_PORTS
    || candidate.some(item => typeof item !== 'string' || item.length > MAX_DRIVER_TEXT)) {
    issues.push(`${owner} property "${property}" must be a text array.`)
    return []
  }
  return [...candidate]
}

function normalizeCapabilities(value: unknown, issues: string[]): HarnessCapability[] {
  if (!Array.isArray(value)) {
    issues.push('Driver capabilities result must be an array.')
    return []
  }
  const capabilities: HarnessCapability[] = []
  if (value.length > MAX_DRIVER_CAPABILITIES) issues.push(`Driver capabilities may contain at most ${MAX_DRIVER_CAPABILITIES} entries.`)
  for (const [index, raw] of value.slice(0, MAX_DRIVER_CAPABILITIES).entries()) {
    const owner = `Driver capability at index ${index}`
    if (!isRecord(raw)) {
      issues.push(`${owner} must be an object.`)
      continue
    }
    const id = textProperty(raw, 'id', owner, issues)
    const status = textProperty(raw, 'status', owner, issues)
    const source = textProperty(raw, 'source', owner, issues)
    const detail = textProperty(raw, 'detail', owner, issues, true)
    if (id === undefined || status === undefined || source === undefined) continue
    if (!KNOWN_CAPABILITIES.has(id as HarnessCapabilityId)) {
      issues.push(`Unknown capability "${id}".`)
      continue
    }
    if (!CAPABILITY_STATUSES.has(status)) {
      issues.push(`${owner} has invalid status "${status}".`)
      continue
    }
    if (!CAPABILITY_SOURCES.has(source)) {
      issues.push(`${owner} has invalid source "${source}".`)
      continue
    }
    capabilities.push({
      id: id as HarnessCapabilityId,
      status: status as HarnessCapability['status'],
      source: source as HarnessCapability['source'],
      ...(detail === undefined ? {} : { detail }),
    })
  }
  return capabilities
}

function normalizeAuthoringContract(value: unknown, issues: string[]): HarnessAuthoringContract {
  if (!isRecord(value) || !Array.isArray(value.nodeKinds) || !Array.isArray(value.bindingKinds)) {
    issues.push('Driver authoring contract must contain nodeKinds and bindingKinds arrays.')
    return emptyAuthoring()
  }
  const bindingKinds: HarnessAuthoringContract['bindingKinds'] = []
  if (value.bindingKinds.length > MAX_DRIVER_BINDING_KINDS) {
    issues.push(`Driver authoring may contain at most ${MAX_DRIVER_BINDING_KINDS} binding kinds.`)
  }
  for (const [index, raw] of value.bindingKinds.slice(0, MAX_DRIVER_BINDING_KINDS).entries()) {
    const owner = `Authoring binding at index ${index}`
    if (!isRecord(raw)) {
      issues.push(`${owner} must be an object.`)
      continue
    }
    const rawTypes = raw.fieldTypes
    const fieldTypes = Array.isArray(rawTypes)
      ? rawTypes.filter((item): item is HarnessConfigField['type'] => typeof item === 'string' && CONFIG_FIELD_TYPES.has(item))
      : []
    if (!Array.isArray(rawTypes) || fieldTypes.length !== rawTypes.length) {
      issues.push(`${owner} property "fieldTypes" must contain only supported field types.`)
    }
    const targetPattern = textProperty(raw, 'targetPattern', owner, issues, true)
    const targetPlaceholder = textProperty(raw, 'targetPlaceholder', owner, issues, true)
    bindingKinds.push({
      kind: textProperty(raw, 'kind', owner, issues) ?? '',
      name: textProperty(raw, 'name', owner, issues) ?? '',
      description: textProperty(raw, 'description', owner, issues) ?? '',
      fieldTypes,
      targetLabel: textProperty(raw, 'targetLabel', owner, issues) ?? '',
      ...(targetPlaceholder === undefined ? {} : { targetPlaceholder }),
      ...(targetPattern === undefined ? {} : { targetPattern }),
    })
  }
  const nodeKinds: HarnessAuthoringContract['nodeKinds'] = []
  if (value.nodeKinds.length > MAX_DRIVER_NODE_KINDS) {
    issues.push(`Driver authoring may contain at most ${MAX_DRIVER_NODE_KINDS} node kinds.`)
  }
  for (const [index, raw] of value.nodeKinds.slice(0, MAX_DRIVER_NODE_KINDS).entries()) {
    const owner = `Authoring node at index ${index}`
    if (!isRecord(raw)) {
      issues.push(`${owner} must be an object.`)
      continue
    }
    const editable = raw.editable
    if (typeof editable !== 'boolean') issues.push(`${owner} property "editable" must be boolean.`)
    const ports: NonNullable<HarnessAuthoringContract['nodeKinds'][number]['ports']> = []
    if (raw.ports !== undefined) {
      if (!Array.isArray(raw.ports)) issues.push(`${owner} property "ports" must be an array.`)
      else {
        if (raw.ports.length > MAX_DRIVER_PORTS) issues.push(`${owner} may contain at most ${MAX_DRIVER_PORTS} ports.`)
        for (const [portIndex, rawPort] of raw.ports.slice(0, MAX_DRIVER_PORTS).entries()) {
          const portOwner = `${owner} port at index ${portIndex}`
          if (!isRecord(rawPort)) {
            issues.push(`${portOwner} must be an object.`)
            continue
          }
          const direction = textProperty(rawPort, 'direction', portOwner, issues)
          if (direction !== 'input' && direction !== 'output') issues.push(`${portOwner} has invalid direction.`)
          const required = rawPort.required
          if (required !== undefined && typeof required !== 'boolean') issues.push(`${portOwner} property "required" must be boolean.`)
          ports.push({
            id: textProperty(rawPort, 'id', portOwner, issues) ?? '',
            name: textProperty(rawPort, 'name', portOwner, issues) ?? '',
            direction: direction === 'output' ? 'output' : 'input',
            dataType: textProperty(rawPort, 'dataType', portOwner, issues) ?? '',
            ...(typeof required === 'boolean' ? { required } : {}),
          })
        }
      }
    }
    const fields: HarnessConfigField[] = []
    let schema: HarnessAuthoringContract['nodeKinds'][number]['configSchema']
    if (raw.configSchema !== undefined) {
      if (!isRecord(raw.configSchema) || raw.configSchema.version !== 1 || !Array.isArray(raw.configSchema.fields)) {
        issues.push(`${owner} configSchema must be a version 1 object with a fields array.`)
      } else {
        if (raw.configSchema.fields.length > MAX_DRIVER_CONTROLS) {
          issues.push(`${owner} may contain at most ${MAX_DRIVER_CONTROLS} controls.`)
        }
        for (const [fieldIndex, rawField] of raw.configSchema.fields.slice(0, MAX_DRIVER_CONTROLS).entries()) {
          const fieldOwner = `${owner} control at index ${fieldIndex}`
          if (!isRecord(rawField)) {
            issues.push(`${fieldOwner} must be an object.`)
            continue
          }
          const type = textProperty(rawField, 'type', fieldOwner, issues)
          if (type === undefined || !CONFIG_FIELD_TYPES.has(type)) {
            issues.push(`${fieldOwner} has an invalid field type.`)
            continue
          }
          const required = rawField.required
          if (typeof required !== 'boolean') issues.push(`${fieldOwner} property "required" must be boolean.`)
          const rawBinding = rawField.binding
          let binding = { kind: '', target: '' }
          if (!isRecord(rawBinding)) issues.push(`${fieldOwner} binding must be an object.`)
          else binding = {
            kind: textProperty(rawBinding, 'kind', `${fieldOwner} binding`, issues) ?? '',
            target: textProperty(rawBinding, 'target', `${fieldOwner} binding`, issues) ?? '',
          }
          let choices: HarnessConfigField['choices']
          if (rawField.choices !== undefined) {
            if (!Array.isArray(rawField.choices)) issues.push(`${fieldOwner} choices must be an array.`)
            else {
              if (rawField.choices.length > MAX_DRIVER_CHOICES) {
                issues.push(`${fieldOwner} may contain at most ${MAX_DRIVER_CHOICES} choices.`)
              }
              choices = rawField.choices.slice(0, MAX_DRIVER_CHOICES).flatMap((rawChoice, choiceIndex) => {
                const choiceOwner = `${fieldOwner} choice at index ${choiceIndex}`
                if (!isRecord(rawChoice)) {
                  issues.push(`${choiceOwner} must be an object.`)
                  return []
                }
                const description = textProperty(rawChoice, 'description', choiceOwner, issues, true)
                return [{
                  id: textProperty(rawChoice, 'id', choiceOwner, issues) ?? '',
                  name: textProperty(rawChoice, 'name', choiceOwner, issues) ?? '',
                  ...(description === undefined ? {} : { description }),
                }]
              })
            }
          }
          const description = textProperty(rawField, 'description', fieldOwner, issues, true)
          fields.push({
            id: textProperty(rawField, 'id', fieldOwner, issues) ?? '',
            name: textProperty(rawField, 'name', fieldOwner, issues) ?? '',
            ...(description === undefined ? {} : { description }),
            type: type as HarnessConfigField['type'],
            required: typeof required === 'boolean' ? required : false,
            ...(choices === undefined ? {} : { choices }),
            binding,
          })
        }
        schema = { version: 1, fields }
      }
    }
    const rawDefaultConfig = raw.defaultConfig
    let defaultConfig: Record<string, HarnessNodeConfigValue> | undefined
    if (rawDefaultConfig !== undefined && !isRecord(rawDefaultConfig)) {
      issues.push(`${owner} defaultConfig must be an object.`)
    } else if (isRecord(rawDefaultConfig)) {
      const fieldIds = new Set(fields.map(field => field.id))
      const unknownKeys = Object.keys(rawDefaultConfig).filter(key => !fieldIds.has(key))
      if (unknownKeys.length > 0) {
        issues.push(`${owner} defaultConfig contains undeclared controls: ${unknownKeys.join(', ')}.`)
      }
      defaultConfig = Object.fromEntries(Object.entries(rawDefaultConfig)
        .filter(([key, entry]) => fieldIds.has(key)
          && (typeof entry === 'string' || typeof entry === 'boolean'))) as Record<string, HarnessNodeConfigValue>
      if (Object.keys(defaultConfig).length
        !== Object.keys(rawDefaultConfig).filter(key => fieldIds.has(key)).length) {
        issues.push(`${owner} defaultConfig values must be text or boolean.`)
      }
    }
    const observes = raw.observes === undefined
      ? undefined
      : textArrayProperty(raw, 'observes', owner, issues) as NonNullable<
        HarnessAuthoringContract['nodeKinds'][number]['observes']
      >
    nodeKinds.push({
      kind: textProperty(raw, 'kind', owner, issues) ?? '',
      name: textProperty(raw, 'name', owner, issues) ?? '',
      description: textProperty(raw, 'description', owner, issues) ?? '',
      responsibility: textProperty(raw, 'responsibility', owner, issues) ?? '',
      editable: editable === true,
      inputs: textArrayProperty(raw, 'inputs', owner, issues),
      outputs: textArrayProperty(raw, 'outputs', owner, issues),
      ...(raw.ports === undefined ? {} : { ports }),
      ...(observes === undefined ? {} : { observes }),
      ...(schema === undefined ? {} : { configSchema: schema }),
      ...(defaultConfig === undefined ? {} : { defaultConfig }),
    })
  }
  return { nodeKinds, bindingKinds }
}

function configValueIssue(field: HarnessConfigField, value: unknown, owner: string): string | undefined {
  if (value === undefined) return field.required ? `${owner} requires a default for "${field.id}".` : undefined
  if (field.type === 'boolean' && typeof value !== 'boolean') return `${owner} default "${field.id}" must be boolean.`
  if (field.type !== 'boolean' && typeof value !== 'string') return `${owner} default "${field.id}" must be text.`
  if (field.type === 'select' && !field.choices?.some(choice => choice.id === value)) {
    return `${owner} default "${field.id}" must select a declared choice.`
  }
  if (field.type === 'secret-reference' && typeof value === 'string'
    && !/^[A-Za-z_][A-Za-z0-9_]*$/u.test(value)) {
    return `${owner} default "${field.id}" must be a credential reference, never a secret value.`
  }
  return undefined
}

function inspectAuthoringContract(
  authoring: HarnessAuthoringContract,
  protocol: string,
  pack: HarnessPack,
): string[] {
  const issues: string[] = []
  if (!Array.isArray(authoring.nodeKinds) || !Array.isArray(authoring.bindingKinds)) {
    return ['Driver authoring contract must contain nodeKinds and bindingKinds arrays.']
  }
  const bindingIds = new Set<string>()
  for (const binding of authoring.bindingKinds) {
    if (!/^[a-z0-9][a-z0-9._-]*$/u.test(binding.kind)) issues.push(`Authoring binding kind "${binding.kind}" is invalid.`)
    if (bindingIds.has(binding.kind)) issues.push(`Authoring binding kind "${binding.kind}" is declared more than once.`)
    bindingIds.add(binding.kind)
    if (binding.name.trim() === '' || binding.description.trim() === '' || binding.targetLabel.trim() === '') {
      issues.push(`Authoring binding kind "${binding.kind}" needs a name, description, and target label.`)
    }
    if (binding.fieldTypes.length === 0 || new Set(binding.fieldTypes).size !== binding.fieldTypes.length
      || binding.fieldTypes.some(type => !CONFIG_FIELD_TYPES.has(type))) {
      issues.push(`Authoring binding kind "${binding.kind}" has an invalid field type list.`)
    }
    if (binding.targetPattern !== undefined
      && (binding.targetPattern.length > 128 || !PORTABLE_TARGET_PATTERN.test(binding.targetPattern))) {
      issues.push(`Authoring binding kind "${binding.kind}" target pattern must be a bounded anchored character-class expression.`)
    }
  }
  const nodeKinds = new Map<string, HarnessAuthoringContract['nodeKinds'][number]>()
  for (const definition of authoring.nodeKinds) {
    if (!/^[a-z0-9][a-z0-9._-]*$/u.test(definition.kind)) issues.push(`Authoring node kind "${definition.kind}" is invalid.`)
    if (nodeKinds.has(definition.kind)) issues.push(`Authoring node kind "${definition.kind}" is declared more than once.`)
    nodeKinds.set(definition.kind, definition)
    if (definition.name.trim() === '' || definition.description.trim() === '' || definition.responsibility.trim() === '') {
      issues.push(`Authoring node kind "${definition.kind}" needs a name, description, and responsibility.`)
    }
    if (new Set(definition.inputs).size !== definition.inputs.length || definition.inputs.some(input => input.trim() === '')) {
      issues.push(`Authoring node kind "${definition.kind}" has an invalid input list.`)
    }
    if (new Set(definition.outputs).size !== definition.outputs.length || definition.outputs.some(output => output.trim() === '')) {
      issues.push(`Authoring node kind "${definition.kind}" has an invalid output list.`)
    }
    const ports = definition.ports ?? []
    if (new Set(ports.map(port => port.id)).size !== ports.length) issues.push(`Authoring node kind "${definition.kind}" has duplicate port ids.`)
    if (ports.some(port => port.id.trim() === '' || port.name.trim() === '' || port.dataType.trim() === '')) {
      issues.push(`Authoring node kind "${definition.kind}" has an incomplete port.`)
    }
    const observations = definition.observes ?? []
    if (new Set(observations).size !== observations.length || observations.some(signal => signal.startsWith('driver.')
      && !signal.startsWith(`driver.${protocol}.`))) {
      issues.push(`Authoring node kind "${definition.kind}" has an invalid runtime signal namespace.`)
    }
    const fields = definition.configSchema?.fields ?? []
    if (!definition.editable && fields.length > 0) issues.push(`Read-only authoring node kind "${definition.kind}" cannot declare executable controls.`)
    if (new Set(fields.map(field => field.id)).size !== fields.length) issues.push(`Authoring node kind "${definition.kind}" has duplicate control ids.`)
    for (const field of fields) {
      const binding = authoring.bindingKinds.find(candidate => candidate.kind === field.binding.kind)
      if (binding === undefined) issues.push(`Authoring node kind "${definition.kind}" uses unknown binding kind "${field.binding.kind}".`)
      else if (!binding.fieldTypes.includes(field.type)) issues.push(`Binding kind "${binding.kind}" cannot execute ${field.type} controls.`)
      if (field.id.trim() === '' || field.name.trim() === '' || field.binding.target.trim() === '') {
        issues.push(`Authoring node kind "${definition.kind}" has an incomplete control binding.`)
      }
      if (field.type === 'select' && (field.choices === undefined || field.choices.length === 0)) {
        issues.push(`Authoring node kind "${definition.kind}" select control "${field.id}" needs choices.`)
      }
      if (field.type !== 'select' && field.choices !== undefined) {
        issues.push(`Authoring node kind "${definition.kind}" non-select control "${field.id}" cannot declare choices.`)
      }
      if (field.choices !== undefined && (new Set(field.choices.map(choice => choice.id)).size !== field.choices.length
        || field.choices.some(choice => choice.id.trim() === '' || choice.name.trim() === ''))) {
        issues.push(`Authoring node kind "${definition.kind}" control "${field.id}" has invalid choices.`)
      }
      const valueIssue = configValueIssue(field, definition.defaultConfig?.[field.id], `Authoring node kind "${definition.kind}"`)
      if (valueIssue !== undefined) issues.push(valueIssue)
    }
  }
  for (const node of pack.graph.nodes.filter(candidate => candidate.editable)) {
    const definition = nodeKinds.get(node.kind)
    if (definition === undefined) issues.push(`Editable Pack node "${node.id}" uses unregistered Driver node kind "${node.kind}".`)
    else if (!definition.editable) issues.push(`Pack node "${node.id}" uses read-only Driver node kind "${node.kind}" as editable.`)
    for (const field of node.configSchema?.fields ?? []) {
      const binding = authoring.bindingKinds.find(candidate => candidate.kind === field.binding.kind)
      if (binding === undefined) issues.push(`Pack node "${node.id}" uses unregistered binding kind "${field.binding.kind}".`)
      else {
        if (!binding.fieldTypes.includes(field.type)) issues.push(`Pack node "${node.id}" binding "${binding.kind}" cannot execute ${field.type}.`)
        if (binding.targetPattern !== undefined && PORTABLE_TARGET_PATTERN.test(binding.targetPattern)
          && !new RegExp(binding.targetPattern, 'u').test(field.binding.target)) {
          issues.push(`Pack node "${node.id}" binding target "${field.binding.target}" is invalid for "${binding.kind}".`)
        }
      }
    }
  }
  return issues
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
  const members = new Map<string, unknown>()
  const member = (name: string): unknown => {
    if (members.has(name)) return members.get(name)
    try {
      const value = candidate[name]
      members.set(name, value)
      return value
    } catch (error: unknown) {
      issues.push(`Driver member "${name}" could not be read: ${safeHarnessDiagnostic(error, 'member access failed')}`)
      members.set(name, undefined)
      return undefined
    }
  }
  const rawApiVersion = member('apiVersion')
  const rawProtocol = member('protocol')
  const apiVersion = typeof rawApiVersion === 'number' ? rawApiVersion : Number.NaN
  const protocol = typeof rawProtocol === 'string' ? rawProtocol : ''
  const api = negotiateHarnessDriverApi(apiVersion)
  if (!api.compatible) issues.push(api.message)
  if (typeof protocol !== 'string' || !/^[a-z0-9][a-z0-9._-]*$/u.test(protocol)) {
    issues.push('Driver protocol must be a stable lowercase identifier.')
  } else if (protocol !== pack.protocol) {
    issues.push(`Driver protocol "${protocol}" does not match Pack protocol "${pack.protocol}".`)
  }
  const requiredMethods = ['capabilities', 'available', 'create', 'resume', 'dispose'] as const
  for (const method of requiredMethods) {
    if (typeof member(method) !== 'function') {
      issues.push(method === 'dispose'
        ? 'Driver must implement required method "dispose" for session disposal so abandoned drafts cannot leak Harness processes.'
        : `Driver must implement required method "${method}".`)
    }
  }
  let capabilities: HarnessCapability[] = []
  let authoring: HarnessAuthoringContract = emptyAuthoring()
  const capabilityMethod = member('capabilities')
  if (typeof capabilityMethod === 'function') {
    try { capabilities = normalizeCapabilities(await Reflect.apply(capabilityMethod, driver, [pack]), issues) } catch (error: unknown) {
      issues.push(`Capability negotiation failed: ${safeHarnessDiagnostic(error, 'capability negotiation failed')}`)
    }
  }
  const seen = new Set<string>()
  for (const capability of capabilities) {
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
  if (pack.authMethods?.some(method => method.kind === 'terminal'
    || method.fields.some(field => field.required)) === true
    && typeof member('missingCredentials') !== 'function') {
    issues.push('Authentication with required credentials or terminal state requires Driver credential-readiness inspection.')
  }
  if (pack.authMethods?.some(method => method.kind === 'terminal') === true
    && typeof member('authenticateInteractive') !== 'function') {
    issues.push('A Pack with terminal authentication requires a Driver-owned interactive login primitive.')
  }
  if (pack.authenticationDiscovery?.source === 'runtime' && typeof member('discoverAuth') !== 'function') {
    issues.push('Runtime authentication discovery requires a Driver discovery primitive.')
  }
  const fork = capabilities.find(item => item.id === 'session.fork')
  if (fork !== undefined && fork.status !== 'unsupported' && typeof member('fork') !== 'function') {
    issues.push('A Driver advertising session.fork must implement a real remote fork primitive.')
  }
  const edit = capabilities.find(item => item.id === 'architecture.edit')
  if (edit?.status === 'supported' && pack.graph.level !== 'composable') issues.push('Architecture editing requires a composable Pack graph.')
  const editableNodes = pack.graph.nodes.filter(node => node.editable)
  if (editableNodes.length > 0 && typeof member('validatePack') !== 'function') {
    issues.push('Composable editable nodes require Driver validation; visual metadata alone is not executable behavior.')
  }
  const authoringMethod = member('authoring')
  if (typeof authoringMethod === 'function') {
    try {
      authoring = normalizeAuthoringContract(await Reflect.apply(authoringMethod, driver, [pack]), issues)
      issues.push(...inspectAuthoringContract(authoring, protocol, pack))
    } catch (error: unknown) {
      issues.push(`Driver authoring negotiation failed: ${safeHarnessDiagnostic(error, 'authoring negotiation failed')}`)
    }
  } else if (editableNodes.length > 0) {
    issues.push('Composable editable nodes require a Driver-owned authoring contract.')
  }
  const validationMethod = member('validatePack')
  if (typeof validationMethod === 'function') {
    try {
      const validation = await Reflect.apply(validationMethod, driver, [pack]) as unknown
      if (!Array.isArray(validation) || validation.some(issue => typeof issue !== 'string')) {
        issues.push('Driver Pack validation result must be a text array.')
      } else issues.push(...validation.map(issue => safeHarnessDiagnostic(issue, 'Driver Pack validation failed')))
    } catch (error: unknown) {
      issues.push(`Driver Pack validation failed: ${safeHarnessDiagnostic(error, 'Driver Pack validation failed')}`)
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
  if (customRuntimeSignals.length > 0 && typeof member('runtimeSignals') !== 'function') {
    issues.push('Pack-declared Driver runtime signals require the Driver runtimeSignals event mapper.')
  }
  if (pack.distribution !== undefined && pack.distribution.kind !== 'executable' && typeof member('install') !== 'function') {
    issues.push(`Pack distribution "${pack.distribution.kind}" requires Driver installation support.`)
  }
  return { protocol, apiVersion, hostApiRange: api.hostApiRange, capabilities, authoring, issues, compatible: issues.length === 0 }
}

/** Reject an incompatible Driver/Pack pair while retaining its authoring vocabulary. */
export async function assertHarnessDriverInspection(
  driver: HarnessDriver,
  pack: HarnessPack,
): Promise<HarnessDriverConformanceReport> {
  const report = await inspectHarnessDriver(driver, pack)
  if (!report.compatible) throw new Error(`Harness Driver conformance failed: ${report.issues.join(' ')}`)
  return report
}

/**
 * Reject a Driver/Pack pair with one deterministic, user-actionable error.
 * @param driver - loaded implementation to admit.
 * @param pack - admitted manifest the Driver claims to implement.
 * @returns negotiated capabilities when every conformance rule passes.
 */
export async function assertHarnessDriverConformance(driver: HarnessDriver, pack: HarnessPack): Promise<HarnessCapability[]> {
  return (await assertHarnessDriverInspection(driver, pack)).capabilities
}

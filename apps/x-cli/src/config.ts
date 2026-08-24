/**
 * Codex-compatible configuration surface for the X CLI.
 *
 * OpenCodex reads `$OPENCODEX_HOME/config.toml` (default
 * `~/.opencodex/config.toml`) with the same key
 * vocabulary Codex uses; `--strict-config` validates against the captured E2
 * key catalog. The captured Codex feature registry is compatibility evidence,
 * not a second runtime switchboard: live OpenCodex capabilities come from the
 * composed DSH Host.
 */

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { parse, stringify } from 'smol-toml'

export interface FeatureRecord {
  name: string
  stage: string
  codex_state: boolean
  x_state: boolean
}

interface FeatureRegistry {
  features: FeatureRecord[]
}

interface ConfigKeyRegistry {
  keys: Array<{ key: string; category: string }>
}

/** Generated registries are checked in beside the source manifest. */
export function loadFeatureRegistry(): FeatureRecord[] {
  const candidates = [
    new URL('./generated/features.json', import.meta.url),
    new URL('../src/generated/features.json', import.meta.url),
  ]
  for (const candidate of candidates) {
    try {
      return (JSON.parse(readFileSync(candidate, 'utf8')) as FeatureRegistry).features
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  return []
}

function loadConfigKeys(): Set<string> {
  const candidates = [
    new URL('./generated/config-keys.json', import.meta.url),
    new URL('../src/generated/config-keys.json', import.meta.url),
  ]
  const keys = new Set<string>()
  for (const candidate of candidates) {
    try {
      const registry = JSON.parse(readFileSync(candidate, 'utf8')) as ConfigKeyRegistry
      for (const entry of registry.keys) keys.add(entry.key)
      break
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  return keys
}

export function xConfigPath(): string {
  return process.env.OPENCODEX_CONFIG_PATH
    ?? process.env.X_CONFIG_PATH
    ?? join(process.env.OPENCODEX_HOME ?? process.env.X_HOME ?? join(homedir(), '.opencodex'), 'config.toml')
}

export type XConfig = Record<string, unknown> & { features?: Record<string, boolean | string> }

/** Read X config, returning an empty document when absent. */
export function loadXConfig(): XConfig {
  try {
    return parse(readFileSync(xConfigPath(), 'utf8'))
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return {}
    throw error
  }
}

function mergeConfig(base: XConfig, layer: XConfig): XConfig {
  const merged = structuredClone(base)
  for (const [key, value] of Object.entries(layer)) {
    if (typeof value === 'object' && value !== null && !Array.isArray(value)
      && typeof merged[key] === 'object' && merged[key] !== null && !Array.isArray(merged[key])) {
      merged[key] = { ...merged[key] as Record<string, unknown>, ...value as Record<string, unknown> }
    } else {
      merged[key] = value
    }
  }
  return merged
}

/**
 * Load the Codex v2 profile stack: the base document, then
 * `$OPENCODEX_HOME/<profile>.config.toml` layered on top. This mirrors Codex's
 * `-p/--profile <CONFIG_PROFILE_V2>` semantics.
 */
export function loadLayeredConfig(profile?: string): XConfig {
  const base = loadXConfig()
  if (profile === undefined || profile === '') return base
  const profilePath = join(dirname(xConfigPath()), `${profile}.config.toml`)
  try {
    const layer = parse(readFileSync(profilePath, 'utf8')) as XConfig
    return mergeConfig(base, layer)
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return base
    throw error
  }
}

function saveXConfig(config: XConfig): void {
  const path = xConfigPath()
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, stringify(config) + '\n', { mode: 0o600 })
}

/** Apply `-c key=value` overrides; values are parsed as TOML with literal fallback. */
export function applyConfigOverride(config: XConfig, assignment: string): XConfig {
  const equals = assignment.indexOf('=')
  if (equals <= 0) throw new Error(`config override must be key=value, got ${JSON.stringify(assignment)}`)
  const key = assignment.slice(0, equals)
  const raw = assignment.slice(equals + 1)
  let value: unknown = raw
  try {
    value = parse(`v = ${raw}`)['v']
  } catch {
    value = raw
  }
  const parts = key.split('.')
  let cursor: Record<string, unknown> = config
  for (let index = 0; index < parts.length - 1; index += 1) {
    const part = parts[index]
    if (part === undefined) throw new Error(`invalid config assignment ${JSON.stringify(assignment)}`)
    const existing = cursor[part]
    if (typeof existing !== 'object' || existing === null || Array.isArray(existing)) {
      cursor[part] = {}
    }
    cursor = cursor[part] as Record<string, unknown>
  }
  const leaf = parts.at(-1)
  if (leaf === undefined) throw new Error(`invalid config assignment ${JSON.stringify(assignment)}`)
  cursor[leaf] = value
  return config
}

/** `--enable` / `--disable` repeatable flags. */
export function applyFeatureFlag(config: XConfig, name: string, enabled: boolean): XConfig {
  if (!config.features || typeof config.features !== 'object') config.features = {}
  config.features[name] = enabled
  return config
}

export function saveFeatureFlag(name: string, enabled: boolean): XConfig {
  const config = loadXConfig()
  applyFeatureFlag(config, name, enabled)
  saveXConfig(config)
  return config
}

/** `--strict-config`: reject unknown config keys against the captured catalog. */
export function validateStrictConfig(config: XConfig): string[] {
  const known = loadConfigKeys()
  const featureNames = new Set(loadFeatureRegistry().map(feature => feature.name))
  const unknown: string[] = []
  const visit = (record: Record<string, unknown>, prefix: string): void => {
    for (const [key, value] of Object.entries(record)) {
      const dotted = prefix === '' ? key : `${prefix}.${key}`
      if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
        visit(value as Record<string, unknown>, dotted)
      } else if (prefix === 'features' && featureNames.has(key)) {
        continue
      } else if (!known.has(dotted) && !known.has(key)) {
        unknown.push(dotted)
      }
    }
  }
  visit(config, '')
  return unknown
}

/** Captured Codex feature rows for compatibility tooling, never live DSH state. */
export function effectiveFeatures(config: XConfig): FeatureRecord[] {
  const registry = loadFeatureRegistry()
  void config
  return registry
}

/** Validate compatibility-shaped config without pretending it changes Cordis. */
export function validateFeatureRequests(config: XConfig): string[] {
  const errors: string[] = []
  for (const [name, requested] of Object.entries(config.features ?? {})) {
    if (typeof requested !== 'boolean') {
      errors.push(`${name} must be boolean`)
    }
  }
  return errors
}

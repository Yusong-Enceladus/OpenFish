/**
 * Generated Codex CLI surface manifest loader.
 *
 * `command-manifest.json` is produced from the parity baseline by
 * `codex-parity/tools/generate_x_cli_manifest.py`; every captured Codex
 * command and flag appears here with its captured help description.
 */

import { readFileSync } from 'node:fs'

export interface ManifestOption {
  flags: string[]
  arg: string
  description: string
  baseline_id: string
}

export interface ManifestCommand {
  path: string
  name: string
  description: string
  arguments: string[]
  options: ManifestOption[]
}

export interface CommandManifest {
  binary: string
  baseline_binary: string
  source: string
  root_options: ManifestOption[]
  commands: ManifestCommand[]
}

// Source layout (apps/x-cli/src) and bundled layout (apps/x-cli/lib) both
// resolve the checked-in manifest: the source path first, then a build-time
// copy under lib/generated when the distribution bundles one.
export function loadManifest(): CommandManifest {
  const candidates = [
    new URL('./generated/command-manifest.json', import.meta.url),
    new URL('../src/generated/command-manifest.json', import.meta.url),
  ]
  for (const candidate of candidates) {
    try {
      return JSON.parse(readFileSync(candidate, 'utf8')) as CommandManifest
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
  throw new Error(`x: command manifest not found (checked ${candidates.join(', ')})`)
}

/** Render one manifest option as a commander option definition. */
export function commanderOption(option: ManifestOption): string {
  const flags = option.flags.join(', ')
  return option.arg === '' ? flags : `${flags} <${option.arg}>`
}

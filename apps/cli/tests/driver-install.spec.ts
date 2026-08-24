import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterEach, describe, expect, it, vi } from 'vitest'

const spawnSyncMock = vi.hoisted(() => vi.fn())
vi.mock('node:child_process', () => ({ spawnSync: spawnSyncMock }))

import { installDriver, parseDriverCandidate } from '../src/driver.ts'

const packageName = '@acme/openfish-driver'

function packageVersion(spec: string): string {
  const separator = spec.lastIndexOf('@')
  return spec.slice(separator + 1)
}

function materialize(directory: string, spec: string): void {
  const version = packageVersion(spec)
  const packageDirectory = join(directory, 'node_modules', '@acme', 'openfish-driver')
  mkdirSync(packageDirectory, { recursive: true, mode: 0o700 })
  writeFileSync(join(packageDirectory, 'package.json'), JSON.stringify({
    name: packageName,
    version,
    dsh: { bundle: { patch: './cordis.patch.yml' } },
  }))
  writeFileSync(join(packageDirectory, 'cordis.patch.yml'), [
    '- insert:',
    '    - id: acme-driver',
    `      name: '${packageName}'`,
    '',
  ].join('\n'))
  const manifestPath = join(directory, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
    dependencies?: Record<string, string>
  }
  writeFileSync(manifestPath, JSON.stringify({
    ...manifest,
    dependencies: { ...manifest.dependencies, [packageName]: spec },
  }))
  writeFileSync(join(directory, 'package-lock.json'), JSON.stringify({
    lockfileVersion: 3,
    packages: {
      '': { dependencies: { [packageName]: spec } },
      [`node_modules/${packageName}`]: {
        version,
        resolved: `https://registry.npmjs.org/${packageName}/-/${version}.tgz`,
        integrity: `sha512-${version}`,
      },
    },
  }))
}

afterEach(() => {
  vi.unstubAllEnvs()
  spawnSyncMock.mockReset()
})

describe('OpenFish Driver Bundle update transaction', () => {
  it('restores an active exact prior source with its recorded script consent after a failed update', () => {
    const home = mkdtempSync(join(tmpdir(), 'openfish-driver-recovery-'))
    const profile = join(home, 'profiles', 'test')
    mkdirSync(profile, { recursive: true, mode: 0o700 })
    const oldSpec = `${packageName}@1.0.0`
    const nextSpec = `${packageName}@2.0.0`
    writeFileSync(join(profile, 'package.json'), JSON.stringify({
      name: 'openfish-driver-test-profile',
      private: true,
      dependencies: { [packageName]: oldSpec },
      dsh: { profile: { bundles: [packageName] } },
    }))
    writeFileSync(join(profile, '.openfish-driver-state.json'), JSON.stringify({
      version: 1,
      bundles: { [packageName]: { requested: oldSpec, installScriptsAllowed: true } },
    }), { mode: 0o600 })
    materialize(profile, oldSpec)
    vi.stubEnv('DSH_HOME', home)
    vi.stubEnv('OPENAI_API_KEY', 'must-not-reach-driver-install')
    vi.stubEnv('NPM_TOKEN', 'must-not-reach-driver-install')
    vi.stubEnv('NODE_OPTIONS', '--require=must-not-run')
    vi.stubEnv('SSH_AUTH_SOCK', '/private/must-not-reach-driver-install')

    spawnSyncMock.mockImplementation((_executable: string, argv: string[], options: { cwd: string; env: NodeJS.ProcessEnv }) => {
      const spec = argv.find(value => value.startsWith(`${packageName}@`))
      if (spec === undefined) return { status: 1, stdout: '', stderr: 'missing exact package spec' }
      if (options.cwd === profile && spec === nextSpec) {
        rmSync(join(profile, 'node_modules', '@acme', 'openfish-driver'), { recursive: true, force: true })
        return { status: 1, stdout: '', stderr: 'simulated registry failure' }
      }
      materialize(options.cwd, spec)
      return { status: 0, stdout: '', stderr: '' }
    })

    try {
      expect(() => installDriver(profile, parseDriverCandidate(nextSpec), false))
        .toThrow(`restored ${packageName} from its exact prior source`)
      const manifest = JSON.parse(readFileSync(join(profile, 'package.json'), 'utf8')) as {
        dependencies: Record<string, string>
        dsh: { profile: { bundles: string[] } }
      }
      expect(manifest.dependencies[packageName]).toBe(oldSpec)
      expect(manifest.dsh.profile.bundles).toContain(packageName)
      expect(JSON.parse(readFileSync(
        join(profile, 'node_modules', '@acme', 'openfish-driver', 'package.json'), 'utf8',
      ))).toMatchObject({ version: '1.0.0' })
      const calls = spawnSyncMock.mock.calls.map(call => call[1] as string[])
      expect(calls.at(-1)).not.toContain('--ignore-scripts')
      const environments = spawnSyncMock.mock.calls.map(call => (call[2] as { env: NodeJS.ProcessEnv }).env)
      for (const environment of environments) {
        expect(environment).not.toHaveProperty('OPENAI_API_KEY')
        expect(environment).not.toHaveProperty('NPM_TOKEN')
        expect(environment).not.toHaveProperty('NODE_OPTIONS')
        expect(environment).not.toHaveProperty('SSH_AUTH_SOCK')
        expect(environment).toMatchObject({
          npm_config_registry: 'https://registry.npmjs.org/',
          GIT_CONFIG_NOSYSTEM: '1',
          GIT_TERMINAL_PROMPT: '0',
        })
      }
    } finally {
      rmSync(home, { recursive: true, force: true })
    }
  })

  it('fails closed instead of guessing script consent for a legacy active source', () => {
    const home = mkdtempSync(join(tmpdir(), 'openfish-driver-legacy-'))
    const profile = join(home, 'profiles', 'test')
    mkdirSync(profile, { recursive: true, mode: 0o700 })
    const oldSpec = `${packageName}@1.0.0`
    const nextSpec = `${packageName}@2.0.0`
    writeFileSync(join(profile, 'package.json'), JSON.stringify({
      name: 'openfish-driver-test-profile', private: true,
      dependencies: { [packageName]: oldSpec }, dsh: { profile: { bundles: [packageName] } },
    }))
    materialize(profile, oldSpec)
    vi.stubEnv('DSH_HOME', home)
    spawnSyncMock.mockImplementation((_executable: string, argv: string[], options: { cwd: string; env: NodeJS.ProcessEnv }) => {
      const spec = argv.find(value => value.startsWith(`${packageName}@`))
      if (spec === undefined) return { status: 1, stdout: '', stderr: 'missing exact package spec' }
      if (options.cwd === profile) return { status: 1, stdout: '', stderr: 'simulated update failure' }
      materialize(options.cwd, spec)
      return { status: 0, stdout: '', stderr: '' }
    })
    try {
      expect(() => installDriver(profile, parseDriverCandidate(nextSpec), false))
        .toThrow('prior source has no lifecycle-script consent record')
      const manifest = JSON.parse(readFileSync(join(profile, 'package.json'), 'utf8')) as {
        dsh: { profile: { bundles: string[] } }
      }
      expect(manifest.dsh.profile.bundles).not.toContain(packageName)
    } finally {
      rmSync(home, { recursive: true, force: true })
    }
  })
})

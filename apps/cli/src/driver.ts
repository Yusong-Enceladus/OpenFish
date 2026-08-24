/**
 * Exact-version Harness Driver Bundle management for the self-contained
 * OpenFish app. Unlike the general `dsh plugin` pnpm forwarder, this surface
 * accepts three closed operations and never requires a package manager on the
 * user's PATH. Candidates are installed into a disposable staging profile,
 * structurally admitted as DSH bundles, then materialized in the selected
 * profile. A crash between materialization and activation leaves inert files,
 * never a Loader entry pointing at a missing package.
 * @module @deepseek-ai/dsh/driver
 */

import { spawnSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import {
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readlinkSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  symlinkSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs'
import { delimiter, dirname, isAbsolute, join, normalize, relative, resolve, sep } from 'node:path'
import {
  DEFAULT_PROFILE_BUNDLES,
  initProfile,
  loadOverlayPatches,
  PROFILE_TEMPLATES,
  readProfileManifest,
  resolveProfileDir,
  type ProfileManifest,
} from '@deepseek-ai/dsh-app-boot'
import { resolveDshHome } from '@deepseek-ai/dsh-home-paths'
import type { EntryOptions } from '@deepseek-ai/cordis-plugin-loader'
import type { DriverInvocation } from './args.ts'
import { ensureShippedProfile } from './profile-boot.ts'

const NAME = 'openfish driver'
const NPM_TIMEOUT_MS = 5 * 60 * 1_000
const MAX_DIAGNOSTIC_BYTES = 8_192
const DRIVER_STATE_FILE = '.openfish-driver-state.json'

const PACKAGE_NAME_SOURCE = String.raw`(?:@[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?\/)?[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?`
const PACKAGE_NAME = new RegExp(`^${PACKAGE_NAME_SOURCE}$`, 'u')
const EXACT_REGISTRY_SPEC = new RegExp(
  `^(?<name>${PACKAGE_NAME_SOURCE})@(?<version>(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)\\.(?:0|[1-9]\\d*)`
  + String.raw`(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?)$`,
  'u',
)
const EXACT_GITHUB_SPEC = /^github:(?<owner>[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))\/(?<repo>[A-Za-z0-9._-]+)#(?<commit>[0-9a-fA-F]{40})$/u

export interface CandidateSpec {
  spec: string
  packageName: string
  expectedVersion?: string
  source: 'npm' | 'github'
}

interface PackageLockEntry {
  version?: unknown
  resolved?: unknown
  integrity?: unknown
}

interface PackageLockDocument {
  packages?: Record<string, PackageLockEntry>
}

function publicPackageSource(value: string): string {
  try {
    const url = new URL(value)
    url.username = ''
    url.password = ''
    url.search = ''
    return url.href
  } catch {
    return value
      .replace(/https?:\/\/[^\s/@:]+:[^\s/@]+@/giu, 'https://[redacted]@')
      .replace(/([?&](?:token|auth|key|secret)=)[^&#\s]+/giu, '$1[redacted]')
  }
}

interface BundleManifest extends ProfileManifest {
  version?: unknown
}

export interface DriverBundleView {
  packageName: string
  requested: string
  version: string
  patch: string
  source: string
  integrity?: string
  /** Whether this exact source was previously installed with an explicit
   * lifecycle-script consent. Missing means an older manager did not record it. */
  installScriptsAllowed?: boolean
  active: boolean
}

interface DriverInstallState {
  version: 1
  bundles: Record<string, { requested: string; installScriptsAllowed: boolean }>
}

export interface DriverCommandResult {
  action: DriverInvocation['action']
  requiresRestart: boolean
  changedPackage?: string
  bundles: DriverBundleView[]
}

/** Resolve and validate one closed install target. */
export function parseDriverCandidate(spec: string, expectedPackageName?: string): CandidateSpec {
  const registry = EXACT_REGISTRY_SPEC.exec(spec)
  if (registry?.groups?.name !== undefined && registry.groups.version !== undefined) {
    if (expectedPackageName !== undefined && expectedPackageName !== registry.groups.name) {
      throw new Error(`--package must match the registry package name ${registry.groups.name}`)
    }
    return {
      spec,
      packageName: registry.groups.name,
      expectedVersion: registry.groups.version,
      source: 'npm',
    }
  }

  if (EXACT_GITHUB_SPEC.test(spec)) {
    if (expectedPackageName === undefined || !PACKAGE_NAME.test(expectedPackageName)) {
      throw new Error('an exact GitHub commit install needs --package <expected-package-name>')
    }
    return { spec, packageName: expectedPackageName, source: 'github' }
  }

  throw new Error(
    'install needs an exact registry version (for example @scope/driver@1.2.3) '
    + 'or github:<owner>/<repo>#<40-character-commit>',
  )
}

function requirePackageName(value: string): string {
  if (!PACKAGE_NAME.test(value)) throw new Error(`invalid package name ${JSON.stringify(value)}`)
  return value
}

function isInside(parent: string, candidate: string): boolean {
  const path = relative(parent, candidate)
  return path === '' || (!path.startsWith(`..${sep}`) && path !== '..' && !isAbsolute(path))
}

function packageDirectory(root: string, packageName: string): string {
  const lexical = resolve(root, 'node_modules', packageName)
  const modules = realpathSync(resolve(root, 'node_modules'))
  const stat = lstatSync(lexical)
  if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`installed package ${packageName} is not a materialized directory`)
  }
  const actual = realpathSync(lexical)
  if (!isInside(modules, actual)) throw new Error(`installed package ${packageName} escapes its managed node_modules root`)
  return actual
}

function entriesOf(entries: readonly EntryOptions[]): EntryOptions[] {
  const flattened: EntryOptions[] = []
  for (const entry of entries) {
    flattened.push(entry)
    if (entry.group && Array.isArray(entry.config)) flattened.push(...entriesOf(entry.config as EntryOptions[]))
  }
  return flattened
}

function insertedEntries(patches: ReturnType<typeof loadOverlayPatches>): EntryOptions[] {
  return patches.flatMap(patch => Array.isArray(patch.insert) ? entriesOf(patch.insert) : [])
}

function lockEntry(root: string, packageName: string): PackageLockEntry | undefined {
  const path = join(root, 'package-lock.json')
  if (!existsSync(path)) return undefined
  const lock = JSON.parse(readFileSync(path, 'utf8')) as PackageLockDocument
  return lock.packages?.[`node_modules/${packageName}`]
}

/** Structurally admit one staged package without importing or executing it. */
function inspectBundle(root: string, candidate: CandidateSpec, active: boolean): DriverBundleView {
  const directory = packageDirectory(root, candidate.packageName)
  const manifestPath = join(directory, 'package.json')
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as BundleManifest
  if (manifest.name !== candidate.packageName) {
    throw new Error(
      `installed package identity ${JSON.stringify(manifest.name)} does not match ${JSON.stringify(candidate.packageName)}`,
    )
  }
  if (typeof manifest.version !== 'string' || manifest.version === '') {
    throw new Error(`installed package ${candidate.packageName} declares no version`)
  }
  if (candidate.expectedVersion !== undefined && manifest.version !== candidate.expectedVersion) {
    throw new Error(
      `registry resolved ${candidate.packageName} ${manifest.version}; expected exact version ${candidate.expectedVersion}`,
    )
  }
  const declared = manifest.dsh?.bundle?.patch
  if (typeof declared !== 'string' || declared === '' || isAbsolute(declared)) {
    throw new Error(`package ${candidate.packageName} declares no safe relative dsh.bundle.patch`)
  }
  const normalized = normalize(declared)
  if (normalized === '..' || normalized.startsWith(`..${sep}`)) {
    throw new Error(`package ${candidate.packageName} dsh.bundle.patch escapes its package root`)
  }
  const patchPath = realpathSync(join(directory, normalized))
  if (!isInside(directory, patchPath)) {
    throw new Error(`package ${candidate.packageName} dsh.bundle.patch escapes its package root`)
  }
  const patches = loadOverlayPatches(NAME, patchPath)
  const ownsEntry = insertedEntries(patches).some(entry => typeof entry.name === 'string'
    && (entry.name === candidate.packageName || entry.name.startsWith(`${candidate.packageName}/`)))
  if (!ownsEntry) {
    throw new Error(
      `package ${candidate.packageName} is a DSH bundle but its patch inserts no module from that package`,
    )
  }
  const locked = lockEntry(root, candidate.packageName)
  return {
    packageName: candidate.packageName,
    requested: candidate.spec,
    version: manifest.version,
    patch: declared,
    source: typeof locked?.resolved === 'string' ? publicPackageSource(locked.resolved) : candidate.source,
    ...(typeof locked?.integrity === 'string' ? { integrity: locked.integrity } : {}),
    active,
  }
}

function embeddedNpmCli(): string | undefined {
  const runtimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
  const candidates = [
    ...(runtimeRoot === undefined || runtimeRoot === ''
      ? []
      : [join(runtimeRoot, 'node', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js')]),
    resolve(dirname(process.execPath), '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
  ]
  return candidates.find(existsSync)
}

function sanitizedDiagnostic(value: string): string {
  let message = value.slice(-MAX_DIAGNOSTIC_BYTES)
  const home = process.env.HOME
  if (home !== undefined && home !== '') message = message.replaceAll(home, '$HOME')
  message = message
    .replace(/((?:authorization|api[-_ ]?key|token|secret|password|cookie)\s*(?:[:=]\s*|["']\s+))(?:Bearer\s+)?[^\s,;)}\]]+/giu, '$1[redacted]')
    .replace(/https?:\/\/[^\s/@:]+:[^\s/@]+@/giu, 'https://[redacted]@')
  return message.trim()
}

function runNpm(cwd: string, args: readonly string[]): void {
  const projectConfig = join(cwd, '.npmrc')
  if (existsSync(projectConfig)) {
    throw new Error('managed Driver installation refuses a project .npmrc; private registries and ambient npm credentials are outside the one-click path')
  }
  const cli = embeddedNpmCli()
  const executable = cli === undefined ? (process.platform === 'win32' ? 'npm.cmd' : 'npm') : process.execPath
  const argv = cli === undefined ? [...args] : [cli, ...args]
  const runtimeRoot = join(resolveDshHome(), 'openfish', 'driver-npm-runtime')
  mkdirSync(runtimeRoot, { recursive: true, mode: 0o700 })
  const runtime = mkdtempSync(join(runtimeRoot, 'operation-'))
  try {
    const home = join(runtime, 'home')
    const cache = join(runtime, 'cache')
    const temp = join(runtime, 'tmp')
    mkdirSync(home, { recursive: true, mode: 0o700 })
    mkdirSync(cache, { recursive: true, mode: 0o700 })
    mkdirSync(temp, { recursive: true, mode: 0o700 })
    const userConfig = join(runtime, 'npmrc')
    const globalConfig = join(runtime, 'global-npmrc')
    writeFileSync(userConfig, '', { mode: 0o600 })
    writeFileSync(globalConfig, '', { mode: 0o600 })

    // Driver installation must not lend ambient API keys, npm credentials,
    // shell hooks, or the user's HOME to package lifecycle scripts. Public
    // packages still retain the minimum process/runtime environment required
    // by the bundled npm client; private registries are intentionally outside
    // the ordinary one-click Harness path.
    const systemRoot = process.env.SystemRoot
    const safePath = process.platform === 'win32'
      ? [dirname(process.execPath), ...(systemRoot === undefined ? [] : [join(systemRoot, 'System32'), systemRoot])]
      : [dirname(process.execPath), '/usr/bin', '/bin', '/usr/sbin', '/sbin']
    const environment: NodeJS.ProcessEnv = {
      PATH: safePath.join(delimiter),
      HOME: home,
      TMPDIR: temp,
      npm_config_cache: cache,
      npm_config_userconfig: userConfig,
      npm_config_globalconfig: globalConfig,
      npm_config_registry: 'https://registry.npmjs.org/',
      npm_config_loglevel: 'error',
      npm_config_update_notifier: 'false',
      npm_config_audit: 'false',
      npm_config_fund: 'false',
      GIT_CONFIG_NOSYSTEM: '1',
      GIT_TERMINAL_PROMPT: '0',
      GCM_INTERACTIVE: 'never',
      ...(process.env.LANG === undefined ? {} : { LANG: process.env.LANG }),
      ...(process.env.LC_ALL === undefined ? {} : { LC_ALL: process.env.LC_ALL }),
      ...(process.platform !== 'win32' || systemRoot === undefined ? {} : {
        SystemRoot: systemRoot,
        ComSpec: join(systemRoot, 'System32', 'cmd.exe'),
        PATHEXT: process.env.PATHEXT ?? '.COM;.EXE;.BAT;.CMD',
      }),
    }
    const result = spawnSync(executable, argv, {
      cwd,
      env: environment,
      encoding: 'utf8',
      maxBuffer: 1024 * 1024,
      shell: false,
      timeout: NPM_TIMEOUT_MS,
    })
    if (result.error !== undefined) {
      const code = (result.error as NodeJS.ErrnoException).code
      if (code === 'ENOENT') throw new Error('bundled npm is unavailable')
      if (code === 'ETIMEDOUT') throw new Error('npm did not finish within five minutes')
      throw result.error
    }
    if (result.status !== 0) {
      const detail = sanitizedDiagnostic(`${result.stderr}\n${result.stdout}`)
      throw new Error(detail === '' ? `npm exited with status ${String(result.status)}` : detail)
    }
  } finally {
    rmSync(runtime, { recursive: true, force: true })
  }
}

function npmInstallArgs(spec: string, allowScripts: boolean): string[] {
  return [
    'install', spec,
    '--save-exact', '--package-lock=true', '--install-strategy=hoisted', '--legacy-peer-deps',
    '--no-audit', '--no-fund', '--loglevel=error',
    ...(allowScripts ? [] : ['--ignore-scripts']),
  ]
}

function atomicProfileManifest(directory: string, manifest: ProfileManifest): void {
  const destination = join(directory, 'package.json')
  const temporary = join(directory, `.package.json.openfish-${String(process.pid)}-${randomUUID()}.tmp`)
  writeFileSync(temporary, `${JSON.stringify(manifest, undefined, 2)}\n`, { mode: 0o600 })
  try {
    renameSync(temporary, destination)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}

function readDriverState(directory: string): DriverInstallState {
  const path = join(directory, DRIVER_STATE_FILE)
  if (!existsSync(path)) return { version: 1, bundles: {} }
  const stat = lstatSync(path)
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error('Driver consent state is not a regular managed file')
  }
  const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'))
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    throw new Error('Driver consent state is malformed')
  }
  const state = parsed as Record<string, unknown>
  if (state.version !== 1 || typeof state.bundles !== 'object'
    || state.bundles === null || Array.isArray(state.bundles)) {
    throw new Error('Driver consent state is malformed')
  }
  const bundles: DriverInstallState['bundles'] = {}
  for (const [packageName, row] of Object.entries(state.bundles)) {
    if (!PACKAGE_NAME.test(packageName) || typeof row !== 'object' || row === null || Array.isArray(row)) {
      throw new Error('Driver consent state contains an invalid package entry')
    }
    const value = row as { requested?: unknown; installScriptsAllowed?: unknown }
    if (typeof value.requested !== 'string' || typeof value.installScriptsAllowed !== 'boolean') {
      throw new Error(`Driver consent state for ${packageName} is malformed`)
    }
    // Preserve only sources accepted by the same closed install grammar.
    parseDriverCandidate(value.requested, packageName)
    bundles[packageName] = {
      requested: value.requested,
      installScriptsAllowed: value.installScriptsAllowed,
    }
  }
  return { version: 1, bundles }
}

function recoverableDriverState(directory: string): DriverInstallState {
  try {
    return readDriverState(directory)
  } catch (error) {
    // A symlink is a path-authority violation and must fail closed. Ordinary
    // malformed legacy/corrupt metadata is non-authoritative: drop only the
    // remembered script consent so no lifecycle script can run implicitly.
    if (error instanceof Error && error.message === 'Driver consent state is not a regular managed file') throw error
    return { version: 1, bundles: {} }
  }
}

function atomicDriverState(directory: string, state: DriverInstallState): void {
  const destination = join(directory, DRIVER_STATE_FILE)
  const temporary = join(directory, `.${DRIVER_STATE_FILE}-${String(process.pid)}-${randomUUID()}.tmp`)
  writeFileSync(temporary, `${JSON.stringify(state, undefined, 2)}\n`, { mode: 0o600 })
  try {
    renameSync(temporary, destination)
  } catch (error) {
    rmSync(temporary, { force: true })
    throw error
  }
}

function lockOwnerPid(owner: string): number | undefined {
  const match = /^(?<pid>[1-9]\d*)(?:-[0-9a-f-]{36})?\n?$/iu.exec(owner)
  if (match?.groups?.pid === undefined) return undefined
  const pid = Number.parseInt(match.groups.pid, 10)
  return Number.isSafeInteger(pid) && pid > 1 ? pid : undefined
}

function processIsAlive(pid: number): boolean {
  try {
    process.kill(pid, 0)
    return true
  } catch {
    return false
  }
}

function acquireProfileLock(directory: string): () => void {
  const path = join(directory, '.openfish-driver.lock')
  const owner = `${String(process.pid)}-${randomUUID()}`

  // A symlink publishes its small owner token atomically. The former
  // open('wx') + write sequence briefly exposed an empty lock; a concurrent
  // process could classify that file as stale, unlink it, and enter the same
  // profile mutation at the same time.
  for (;;) {
    try {
      symlinkSync(owner, path)
      break
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') throw error
      const stat = lstatSync(path)
      let existingOwner: string
      if (stat.isSymbolicLink()) {
        existingOwner = readlinkSync(path)
      } else if (stat.isFile()) {
        // Read locks written by pre-symlink OpenFish releases so a crashed old
        // process does not permanently block the upgraded manager.
        existingOwner = readFileSync(path, 'utf8')
      } else {
        throw new Error('Driver manager lock path has an unsupported file type')
      }
      const existingPid = lockOwnerPid(existingOwner)
      if (existingPid === undefined) {
        throw new Error('Driver manager lock ownership is unreadable; remove it only after confirming no operation is running')
      }
      if (processIsAlive(existingPid)) {
        throw new Error(`another Driver Bundle operation is running (pid ${String(existingPid)})`)
      }
      // Re-read the atomic token immediately before removal. This prevents a
      // contender that inspected an old dead owner from deleting a lock that
      // another contender has already replaced.
      let current: string
      try {
        current = lstatSync(path).isSymbolicLink() ? readlinkSync(path) : readFileSync(path, 'utf8')
      } catch (readError) {
        if ((readError as NodeJS.ErrnoException).code === 'ENOENT') continue
        throw readError
      }
      if (current !== existingOwner) continue
      try { unlinkSync(path) } catch (unlinkError) {
        if ((unlinkError as NodeJS.ErrnoException).code !== 'ENOENT') throw unlinkError
      }
    }
  }

  return () => {
    try {
      const stat = lstatSync(path)
      if (stat.isSymbolicLink() && readlinkSync(path) === owner) unlinkSync(path)
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error
    }
  }
}

function ensureProfile(name: string): string {
  ensureShippedProfile(name)
  const directory = resolveProfileDir(name)
  if (!existsSync(join(directory, 'package.json'))) {
    initProfile(directory, PROFILE_TEMPLATES[name] ?? DEFAULT_PROFILE_BUNDLES)
  }
  return directory
}

function candidateFromDependency(packageName: string, requested: string): CandidateSpec {
  try {
    return parseDriverCandidate(requested, packageName)
  } catch {
    // A profile may predate the exact Driver manager and contain a valid
    // dependency spec that it did not create. Listing remains observational;
    // installs still accept only the closed exact-spec grammar above.
    return { spec: requested, packageName, source: requested.startsWith('github:') ? 'github' : 'npm' }
  }
}

function listBundles(directory: string): DriverBundleView[] {
  const manifest = readProfileManifest(NAME, directory)
  const state = recoverableDriverState(directory)
  const dependencies = manifest.dependencies ?? {}
  const active = new Set(manifest.dsh?.profile?.bundles ?? [])
  const rows: DriverBundleView[] = []
  for (const packageName of Object.keys(dependencies).sort()) {
    if (!active.has(packageName)) continue
    try {
      const inspected = inspectBundle(
        directory,
        candidateFromDependency(packageName, dependencies[packageName] as string),
        true,
      )
      const consent = state.bundles[packageName]
      rows.push({
        ...inspected,
        ...(consent?.requested === inspected.requested
          ? { installScriptsAllowed: consent.installScriptsAllowed }
          : {}),
      })
    } catch {
      // The Loader itself owns the fail-loud diagnostic on next boot. A list
      // never invents a healthy row for an unreadable or half-removed bundle.
    }
  }
  return rows
}

/** @internal Exported so the exact-source recovery transaction can be exercised without a registry. */
export function installDriver(directory: string, candidate: CandidateSpec, allowScripts: boolean): DriverBundleView {
  const stagingRoot = join(resolveDshHome(), 'openfish', 'driver-staging')
  mkdirSync(stagingRoot, { recursive: true, mode: 0o700 })
  const staging = mkdtempSync(join(stagingRoot, 'candidate-'))
  try {
    writeFileSync(join(staging, 'package.json'), '{"name":"openfish-driver-staging","private":true}\n', { mode: 0o600 })
    // A Driver Bundle must ship the patch that makes it structurally
    // inspectable. Never execute candidate lifecycle code merely to decide
    // whether the package is eligible for the consented install.
    runNpm(staging, npmInstallArgs(candidate.spec, false))
    inspectBundle(staging, candidate, false)

    // An update may replace a package that is already active. Deactivate it
    // before npm can touch node_modules so a crash never leaves the Loader
    // pointing at a missing or half-materialized Driver. A failed operation
    // remains safely inactive and can be retried from the exact source.
    const before = readProfileManifest(NAME, directory)
    const beforeState = recoverableDriverState(directory)
    const beforeBundles = before.dsh?.profile?.bundles ?? []
    if (beforeBundles.includes(candidate.packageName)) {
      atomicProfileManifest(directory, {
        ...before,
        dsh: {
          ...before.dsh,
          profile: {
            ...before.dsh?.profile,
            bundles: beforeBundles.filter(bundle => bundle !== candidate.packageName),
          },
        },
      })
    }

    try {
      runNpm(directory, npmInstallArgs(candidate.spec, allowScripts))
      const installed = inspectBundle(directory, candidate, false)
      const state = recoverableDriverState(directory)
      atomicDriverState(directory, {
        version: 1,
        bundles: {
          ...state.bundles,
          [candidate.packageName]: {
            requested: candidate.spec,
            installScriptsAllowed: allowScripts,
          },
        },
      })
      const manifest = readProfileManifest(NAME, directory)
      const bundles = manifest.dsh?.profile?.bundles ?? []
      if (!bundles.includes(candidate.packageName)) {
        atomicProfileManifest(directory, {
          ...manifest,
          dsh: {
            ...manifest.dsh,
            profile: { ...manifest.dsh?.profile, bundles: [...bundles, candidate.packageName] },
          },
        })
      }
      return { ...installed, active: true }
    } catch (error: unknown) {
      const previous = beforeState.bundles[candidate.packageName]
      const wasActive = beforeBundles.includes(candidate.packageName)
      if (!wasActive) {
        atomicProfileManifest(directory, before)
        atomicDriverState(directory, beforeState)
        throw error
      }
      if (previous === undefined) {
        throw new Error(
          `Driver update failed and the prior source has no lifecycle-script consent record; reinstall ${candidate.packageName} manually`,
          { cause: error },
        )
      }
      try {
        const previousCandidate = parseDriverCandidate(previous.requested, candidate.packageName)
        runNpm(directory, npmInstallArgs(previous.requested, previous.installScriptsAllowed))
        inspectBundle(directory, previousCandidate, false)
        atomicDriverState(directory, beforeState)
        atomicProfileManifest(directory, before)
      } catch (recoveryError: unknown) {
        throw new Error(
          `Driver update failed and restoring ${candidate.packageName} from its exact prior source also failed: ${sanitizedDiagnostic(recoveryError instanceof Error ? recoveryError.message : String(recoveryError))}`,
          { cause: error },
        )
      }
      throw new Error(`Driver update failed; restored ${candidate.packageName} from its exact prior source`, { cause: error })
    }
  } finally {
    rmSync(staging, { recursive: true, force: true })
  }
}

function removeDriver(directory: string, packageName: string): void {
  const manifest = readProfileManifest(NAME, directory)
  const bundles = manifest.dsh?.profile?.bundles ?? []
  if (manifest.dependencies?.[packageName] === undefined || !bundles.includes(packageName)) {
    throw new Error(`${packageName} is not an active dependency-managed Bundle in this profile`)
  }

  // Deactivate first. A crash or npm failure can leave unused files, but the
  // next Host boot never points the Loader at a package that may be absent.
  atomicProfileManifest(directory, {
    ...manifest,
    dsh: {
      ...manifest.dsh,
      profile: { ...manifest.dsh?.profile, bundles: bundles.filter(bundle => bundle !== packageName) },
    },
  })
  try {
    runNpm(directory, [
      'uninstall', packageName, '--package-lock=true', '--ignore-scripts', '--no-audit', '--no-fund', '--loglevel=error',
    ])
    const state = recoverableDriverState(directory)
    const { [packageName]: _removed, ...remaining } = state.bundles
    atomicDriverState(directory, { version: 1, bundles: remaining })
  } catch (error) {
    // Restore activation only when the installed directory still exists. If
    // npm already removed it, the safe state is inactive and retryable.
    if (existsSync(resolve(directory, 'node_modules', packageName))) atomicProfileManifest(directory, manifest)
    throw error
  }
}

function printResult(result: DriverCommandResult): void {
  process.stdout.write(`${JSON.stringify(result)}\n`)
}

/** Execute one already-parsed Driver manager command. */
export function runDriverCommand(invocation: DriverInvocation): Promise<number> {
  try {
    const directory = ensureProfile(invocation.profile)
    if (invocation.action === 'list') {
      printResult({ action: 'list', requiresRestart: false, bundles: listBundles(directory) })
      return Promise.resolve(0)
    }

    const release = acquireProfileLock(directory)
    try {
      if (invocation.action === 'install') {
        const candidate = parseDriverCandidate(invocation.target as string, invocation.packageName)
        installDriver(directory, candidate, invocation.allowScripts)
        printResult({
          action: 'install',
          requiresRestart: true,
          changedPackage: candidate.packageName,
          bundles: listBundles(directory),
        })
      } else {
        const packageName = requirePackageName(invocation.target as string)
        removeDriver(directory, packageName)
        printResult({
          action: 'remove',
          requiresRestart: true,
          changedPackage: packageName,
          bundles: listBundles(directory),
        })
      }
    } finally {
      release()
    }
    return Promise.resolve(0)
  } catch (error: unknown) {
    const message = sanitizedDiagnostic(error instanceof Error ? error.message : String(error))
    process.stderr.write(`${NAME}: ${message === '' ? 'operation failed' : message}\n`)
    return Promise.resolve(1)
  }
}

/** Fail-closed process authority for managed third-party Harness runtimes. @module */

import { chmod, mkdir } from 'node:fs/promises'
import { homedir, tmpdir } from 'node:os'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { Context } from '@deepseek-ai/cordis'
import { canonicalPath, type SandboxExecutionPolicy, type SandboxMode, type SandboxPolicy } from '@deepseek-ai/dsh-sandbox'
import type {} from '@deepseek-ai/dsh-sandbox-policy'
import type { Session } from '@deepseek-ai/dsh-session'

const PACKAGE_ROOT = dirname(fileURLToPath(new URL('../package.json', import.meta.url)))

/** Why a managed process is being started; each purpose has a different workspace grant. */
export type HarnessProcessPurpose = 'install' | 'authentication' | 'session'

/** Inputs for one managed Harness process boundary. */
export interface HarnessProcessAuthorityRequest {
  argv: readonly string[]
  env?: NodeJS.ProcessEnv
  cwd: string
  /** Policy root, when the process starts in a workspace subdirectory. */
  workspaceRoot?: string
  installationDirectory: string
  runtimeDirectory: string
  purpose: HarnessProcessPurpose
  session?: Session
  /** Approved process mode used while atomically replacing a live boundary. */
  sandboxMode?: SandboxMode
  /** Explicit external state owned by the selected authentication method. */
  authenticationRoots?: readonly string[]
}

/** Prepared process facts safe to hand directly to `ctx.subprocess.spawn`. */
export interface ManagedHarnessProcess {
  argv: string[]
  env: NodeJS.ProcessEnv
  enforcement: 'full' | 'user-authorized-full-access'
}

/** Create a private directory and retain owner-only permissions after upgrades. */
async function privateDirectory(path: string): Promise<void> {
  await mkdir(path, { recursive: true, mode: 0o700 })
  await chmod(path, 0o700)
}

function uniqueRoots(paths: readonly string[]): string[] {
  return [...new Set(paths.map(path => canonicalPath(resolve(path))))]
}

function protectedUserRoots(): string[] {
  const roots = [homedir(), tmpdir()]
  if (process.platform === 'darwin') roots.push('/Users', '/Volumes', '/Network', '/private/tmp')
  return uniqueRoots(roots)
}

function trustedRuntimeRoots(argv: readonly string[]): string[] {
  const roots = [PACKAGE_ROOT]
  const runtimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
  if (runtimeRoot !== undefined && runtimeRoot !== '' && isAbsolute(runtimeRoot)) roots.push(runtimeRoot)
  const executable = argv[0]
  if (executable !== undefined && isAbsolute(executable)) roots.push(dirname(executable))
  return uniqueRoots(roots)
}

/**
 * Build the isolated HOME/cache/temp environment and wrap the process in the
 * host's enforcing sandbox. The ambient HOME is hidden, inbound listeners and
 * unrelated-process control are denied, and only the selected workspace,
 * managed snapshot/runtime, trusted Open Fish runtime, and explicit auth roots
 * are restored. Missing or partial enforcement fails before spawn.
 * @param ctx - Host context owning sandbox and policy services.
 * @param request - exact process purpose, roots, argv, and optional session policy.
 * @returns fully prepared argv, scrubbed private environment, and enforcement fact.
 */
export async function prepareHarnessProcess(
  ctx: Context,
  request: HarnessProcessAuthorityRequest,
): Promise<ManagedHarnessProcess> {
  const home = join(request.runtimeDirectory, 'home')
  const cache = join(request.runtimeDirectory, 'cache')
  const config = join(request.runtimeDirectory, 'config')
  const data = join(request.runtimeDirectory, 'data')
  const temp = join(request.runtimeDirectory, 'tmp')
  await Promise.all([home, cache, config, data, temp].map(privateDirectory))

  const environment: NodeJS.ProcessEnv = {
    ...request.env,
    PATH: [dirname(process.execPath), '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin'].join(':'),
    HOME: home,
    TMPDIR: temp,
    XDG_CACHE_HOME: cache,
    XDG_CONFIG_HOME: config,
    XDG_DATA_HOME: data,
    npm_config_cache: join(cache, 'npm'),
    BUN_INSTALL_CACHE_DIR: join(cache, 'bun'),
    UV_CACHE_DIR: join(cache, 'uv'),
    PIP_CACHE_DIR: join(cache, 'pip'),
  }
  const authenticationRoots = uniqueRoots(request.authenticationRoots ?? [])
  const workspaceRoot = canonicalPath(resolve(request.workspaceRoot ?? request.cwd))
  const execution: SandboxExecutionPolicy = request.session === undefined
    ? { mode: request.purpose === 'install' ? 'workspace-write' : 'read-only', workspaceRoot }
    : ctx.sandboxPolicy.resolve({ session: request.session, ...(request.sandboxMode === undefined ? {} : { mode: request.sandboxMode }) })
  if (execution.mode === 'danger-full-access') {
    return { argv: [...request.argv], env: environment, enforcement: 'user-authorized-full-access' }
  }

  const readableRoots = uniqueRoots([
    workspaceRoot,
    request.installationDirectory,
    request.runtimeDirectory,
    ...trustedRuntimeRoots(request.argv),
    ...authenticationRoots,
  ])
  const policy: SandboxPolicy = {
    mode: execution.mode,
    workspaceRoot,
    ...(execution.sessionId === undefined ? {} : { sessionId: execution.sessionId }),
    runtimeWritableRoots: [request.runtimeDirectory, ...authenticationRoots],
    platformTemporaryWrites: false,
    isolation: {
      protectedReadRoots: protectedUserRoots(),
      readableRoots,
      denyNetworkInbound: true,
      denyHostProcessControl: true,
      denyHostInterprocessCommunication: true,
    },
  }
  const confined = ctx.sandbox.confine(request.argv, policy)
  if (confined.enforcement !== 'full') {
    throw new Error('OpenFish refuses to launch a managed Harness without full host-privacy enforcement')
  }
  return { argv: confined.argv, env: environment, enforcement: 'full' }
}

/**
 * Non-mutating host preflight used by catalog availability. It proves the
 * selected provider can express the exact resident-process boundary before
 * OpenFish downloads or executes a third-party package.
 * @param ctx - Host context whose sandbox provider is being checked.
 */
export function assertHarnessIsolationAvailable(ctx: Context): void {
  const cwd = canonicalPath(process.cwd())
  const confined = ctx.sandbox.confine([process.execPath, '--version'], {
    mode: 'read-only',
    workspaceRoot: cwd,
    platformTemporaryWrites: false,
    isolation: {
      protectedReadRoots: protectedUserRoots(),
      readableRoots: uniqueRoots([cwd, PACKAGE_ROOT, dirname(process.execPath)]),
      denyNetworkInbound: true,
      denyHostProcessControl: true,
      denyHostInterprocessCommunication: true,
    },
  })
  if (confined.enforcement !== 'full') {
    throw new Error('the host sandbox reports only partial resident-process isolation')
  }
}

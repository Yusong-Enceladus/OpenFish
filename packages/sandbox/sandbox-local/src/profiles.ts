/**
 * Internal platform-profile builders for the local sandbox provider.
 *
 * @module @deepseek-ai/dsh-sandbox-local/profiles
 */

import { grantArgs as landlockGrantArgs } from '@deepseek-ai/node-addon-landlock-run'
import { canonicalPath, writableRoots } from '@deepseek-ai/dsh-sandbox'
import type { SandboxPolicy } from '@deepseek-ai/dsh-sandbox'

/**
 * Build the bwrap profile arguments for one file-effect policy.
 * @param policy - file-effect policy to express as bwrap mounts.
 * @returns profile arguments before the trailing separator and command argv.
 */
export function bwrapProfileArgs(policy: SandboxPolicy): string[] {
  const args = ['--ro-bind', '/', '/', '--dev', '/dev', '--proc', '/proc', '--die-with-parent']
  const writable = new Set<string>()
  if (policy.mode === 'workspace-write') {
    if (policy.platformTemporaryWrites !== false) args.push('--tmpfs', '/tmp')
    writable.add(policy.workspaceRoot)
  }
  for (const root of policy.runtimeWritableRoots ?? []) writable.add(root)
  for (const root of writable) args.push('--bind', root, root)
  return args
}

/**
 * Build the Landlock launcher grants for one file-effect policy.
 * @param policy - file-effect policy to express as Landlock allow-list grants.
 * @returns launcher grant arguments before the trailing separator and command argv.
 */
export function landlockProfileArgs(policy: SandboxPolicy): string[] {
  const readWrite = ['/dev/null', ...(policy.runtimeWritableRoots ?? [])]
  if (policy.mode === 'workspace-write') {
    if (policy.platformTemporaryWrites !== false) readWrite.push('/tmp')
    readWrite.push(policy.workspaceRoot)
  }
  return landlockGrantArgs({ readOnly: ['/'], readWrite })
}

/** Quote one path as an SBPL string literal. */
function sbplString(path: string): string {
  return `"${path.replaceAll('\\', String.raw`\\`).replaceAll('"', String.raw`\"`)}"`
}

/**
 * Build the sandbox-exec arguments and SBPL profile for one policy. The
 * writable roots come from the shared {@link writableRoots} helper (canonical,
 * deduplicated) so the Seatbelt grant and the in-process fs fence
 * (`@deepseek-ai/dsh-fs-sandbox`) can never drift apart.
 * @param policy - file-effect policy to express as an SBPL profile.
 * @returns sandbox-exec arguments before the trailing separator and command argv.
 */
export function seatbeltProfileArgs(policy: SandboxPolicy): string[] {
  const forms = ['(version 1)', '(allow default)', '(deny file-write*)', `(allow file-write* (literal ${sbplString('/dev/null')}))`]
  const roots = writableRoots(policy)
  if (roots.length > 0) {
    forms.push(`(allow file-write* ${roots.map(root => `(subpath ${sbplString(root)})`).join(' ')})`)
  }
  const isolation = policy.isolation
  if (isolation !== undefined) {
    const protectedRoots = [...new Set(isolation.protectedReadRoots.map(canonicalPath))]
    const readableRoots = [...new Set(isolation.readableRoots.map(canonicalPath))]
    if (protectedRoots.length === 0) throw new Error('sandbox-local: isolation requires at least one protected read root')
    if (readableRoots.length === 0) throw new Error('sandbox-local: isolation requires at least one readable root')
    forms.push(`(deny file-read* ${protectedRoots.map(root => `(subpath ${sbplString(root)})`).join(' ')})`)
    forms.push(`(allow file-read* ${readableRoots.map(root => `(subpath ${sbplString(root)})`).join(' ')})`)
    forms.push('(deny network-inbound)')
    forms.push('(deny process-info*)')
    forms.push('(allow process-info* (target self))')
    forms.push('(allow process-info* (target children))')
    forms.push('(deny signal)')
    forms.push('(allow signal (target self))')
    forms.push('(allow signal (target children))')
    forms.push('(deny appleevent-send)')
    forms.push('(deny mach-lookup)')
  }
  return ['-p', forms.join(' ')]
}

import { lstat, readFile, realpath, readdir, rm, writeFile } from 'node:fs/promises'
import { dirname, extname, join, relative, resolve } from 'node:path'

const root = resolve(process.argv[2] ?? '')
if (root === resolve('.')) throw new Error('usage: node scripts/sanitize-openfish-runtime.mjs /absolute/runtime/app')

const manifestPath = join(root, 'package.json')
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'))
for (const section of ['dependencies', 'optionalDependencies']) {
  if (manifest[section] === undefined) continue
  manifest[section] = Object.fromEntries(Object.keys(manifest[section]).map(name => [name, '*']))
}
delete manifest.devDependencies
delete manifest.pnpm
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

// pnpm's resolution metadata is not needed after the runtime has been laid
// out. It records the builder's content-addressable store and workspace paths,
// which are both private and meaningless on an end user's machine.
for (const metadata of [
  'pnpm-lock.yaml',
  'node_modules/.pnpm/lock.yaml',
  'node_modules/.modules.yaml',
  'node_modules/.pnpm-workspace-state-v1.json',
]) await rm(join(root, metadata), { force: true })

const textExtensions = new Set(['.json', '.yaml', '.yml', '.js', '.mjs', '.cjs', '.ts', '.map', '.md'])
const escapeRegExp = value => value.replace(/[.*+?^${}()|[\]\\]/gu, '\\$&')
const forbidden = [
  new RegExp(escapeRegExp(resolve('.')), 'u'),
  ...(process.env.HOME === undefined ? [] : [new RegExp(escapeRegExp(resolve(process.env.HOME)), 'u')]),
]

async function walk(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name)
    const stat = await lstat(path)
    if (stat.isSymbolicLink()) {
      const target = await realpath(path)
      const escaped = relative(root, target)
      if (escaped.startsWith('..')) throw new Error(`runtime symlink escapes bundle: ${relative(root, path)}`)
    } else if (stat.isDirectory()) {
      await walk(path)
    } else if (textExtensions.has(extname(entry.name)) || entry.name === 'package.json') {
      const text = await readFile(path, 'utf8').catch(() => undefined)
      if (text === undefined) continue
      // Bundlers may preserve absolute source paths in region comments and
      // source maps. They are diagnostic-only, so retain the relationship but
      // replace the builder location with a stable, anonymous virtual root.
      const sanitized = text.replaceAll(resolve('.'), '/openfish-src')
      if (sanitized !== text) await writeFile(path, sanitized)
      if (forbidden.some(pattern => pattern.test(sanitized))) {
        throw new Error(`runtime contains a build-machine path: ${relative(root, path)}`)
      }
    }
  }
}

await walk(root)

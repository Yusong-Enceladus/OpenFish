import { readdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { packsFromOpenFishCommunity } from '../packages/harness/harness/src/manifest.ts'

const root = resolve(import.meta.dirname, '..')
const packsDirectory = resolve(root, 'community/harnesses/packs')
const output = resolve(root, 'community/harnesses/index.json')
const check = process.argv.includes('--check')

const files = (await readdir(packsDirectory, { withFileTypes: true }))
  .filter(entry => entry.isFile() && entry.name.endsWith('.json'))
  .map(entry => entry.name)
  .sort()
const rawPacks = await Promise.all(files.map(async file => JSON.parse(await readFile(resolve(packsDirectory, file), 'utf8')) as unknown))
const packs = packsFromOpenFishCommunity({ version: 0, packs: rawPacks })
const ids = new Set<string>()
for (const pack of packs) {
  if (ids.has(pack.id)) throw new Error(`duplicate OpenFish community Harness id: ${pack.id}`)
  ids.add(pack.id)
}
const rendered = `${JSON.stringify({ version: 0, packs }, null, 2)}\n`
if (check) {
  const current = await readFile(output, 'utf8').catch(() => '')
  if (current !== rendered) throw new Error('community/harnesses/index.json is stale; run pnpm run gen-openfish-community-catalog')
} else {
  await writeFile(output, rendered)
}

console.log(`OpenFish community catalog ${check ? 'verified' : 'generated'}: ${packs.length} Pack(s)`)

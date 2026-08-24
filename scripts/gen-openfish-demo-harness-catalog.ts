import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { builtInHarnessPacks } from '../packages/harness/harness/src/index.ts'
import type { HarnessCapability, HarnessPack } from '../packages/harness/harness/src/types.ts'

const root = resolve(import.meta.dirname, '..')
const outputs = [
  resolve(root, 'apps/x-macos/Sources/XMac/Resources/openfish-demo-harnesses.json'),
  resolve(root, 'apps/x-ios/Sources/XiOS/Resources/openfish-demo-harnesses.json'),
]
const check = process.argv.includes('--check')
const packs = builtInHarnessPacks()
const rendered = `${JSON.stringify({ version: 0, items: packs.map(demoCatalogEntry) }, null, 2)}\n`

for (const output of outputs) {
  if (check) {
    const current = await readFile(output, 'utf8').catch(() => '')
    if (current !== rendered) {
      throw new Error(`${output} is stale; run pnpm run gen-openfish-demo-harness-catalog`)
    }
  } else {
    await mkdir(resolve(output, '..'), { recursive: true })
    await writeFile(output, rendered)
  }
}

console.log(`OpenFish demo Harness catalog ${check ? 'verified' : 'generated'} from ${packs.length} live Pack manifest(s)`)

function demoCatalogEntry(pack: HarnessPack) {
  const builtIn = pack.protocol === 'dsh'
  const installed = builtIn || pack.id === 'codex'
  const selectedMethod = pack.id === 'codex' ? 'codex-local-login' : undefined
  const authMethods = pack.authMethods ?? []
  const integrity = builtIn
    ? {
      status: 'trusted-runtime' as const,
      source: 'OpenFish application bundle',
      detail: 'Demo fact generated from the live built-in Pack; no external runtime is launched.',
    }
    : {
      status: 'version-pinned' as const,
      source: pack.distribution?.kind === 'npx' || pack.distribution?.kind === 'bunx' || pack.distribution?.kind === 'uvx'
        ? pack.distribution.package
        : pack.distribution?.kind === 'binary' ? pack.distribution.archive : pack.distribution?.command ?? pack.source,
      detail: 'Demo package identity is pinned to the exact live Pack version; this is not a checksum claim.',
    }
  return {
    ...pack,
    isDefault: pack.id === 'codex',
    available: true,
    installation: {
      status: builtIn ? 'builtin' as const : installed ? 'installed' as const : 'not-installed' as const,
      ...(installed ? { installedVersion: pack.version } : {}),
      availableVersion: pack.version,
      previousVersions: [],
      integrity,
    },
    auth: {
      methods: authMethods,
      ...(selectedMethod === undefined ? {} : { selectedMethod }),
      status: authMethods.length === 0
        ? 'not-required' as const
        : selectedMethod === undefined ? 'needs-selection' as const : 'configured' as const,
      missingFields: [],
    },
    compatibility: {
      status: installed ? 'compatible' as const : 'ready' as const,
      classification: installed && pack.graph.level !== 'opaque' ? 'supported' as const : 'experimental' as const,
      message: installed ? 'Deterministic Demo data; no Harness process or provider is contacted.' : 'Available to install in a live OpenFish session.',
    },
    capabilities: demoCapabilities(pack),
    driver: {
      apiVersion: 1 as const,
      protocol: pack.protocol,
      loaded: true,
      authorization: pack.driverBundle === undefined ? 'not-required' as const : 'authorized' as const,
    },
  }
}

function demoCapabilities(pack: HarnessPack): HarnessCapability[] {
  const external = pack.protocol !== 'dsh'
  const canFork = pack.protocol === 'dsh' || pack.protocol === 'codex-app-server'
  const observesRuntime = pack.graph.nodes.some(node => (node.observes?.length ?? 0) > 0)
    || pack.graph.edges.some(edge => (edge.observes?.length ?? 0) > 0)
  return [
    { id: 'lifecycle.install', status: external ? 'supported' : 'unsupported', source: 'driver' },
    { id: 'lifecycle.update', status: external ? 'supported' : 'runtime', source: 'driver' },
    { id: 'lifecycle.rollback', status: external ? 'supported' : 'unsupported', source: 'driver' },
    { id: 'lifecycle.uninstall', status: external ? 'supported' : 'unsupported', source: 'driver' },
    { id: 'session.create', status: 'supported', source: 'driver' },
    { id: 'session.resume', status: 'supported', source: 'driver' },
    { id: 'session.cancel', status: 'supported', source: 'driver' },
    { id: 'session.fork', status: canFork ? 'supported' : 'unsupported', source: 'driver', detail: canFork ? 'The live Driver exposes a real Harness-owned branch operation.' : 'This Driver does not claim a remote-session branch primitive.' },
    { id: 'session.archive', status: 'supported', source: 'host', detail: 'OpenFish archives the task without deleting its Harness session.' },
    { id: 'workspace.project', status: 'supported', source: 'driver' },
    { id: 'workspace.no-project', status: 'supported', source: 'driver' },
    { id: 'configuration.models', status: 'runtime', source: 'runtime', detail: 'Discovered from the running Harness.' },
    { id: 'configuration.reasoning', status: 'runtime', source: 'runtime', detail: 'Shown only when the selected model advertises it.' },
    { id: 'configuration.auth', status: 'runtime', source: 'runtime' },
    { id: 'configuration.agent-presets', status: pack.protocol === 'dsh' ? 'supported' : 'unsupported', source: 'driver' },
    { id: 'interaction.tools', status: 'supported', source: 'driver' },
    { id: 'interaction.approvals', status: 'supported', source: 'driver' },
    { id: 'interaction.questions', status: 'supported', source: 'driver', detail: pack.protocol === 'dsh' ? 'OpenFish user questions are native to DSH.' : 'The Driver bridges Harness-owned form questions while refusing secret fields.' },
    { id: 'interaction.files', status: 'supported', source: 'driver', detail: pack.protocol === 'dsh' ? 'DSH receives OpenFish attachments through its native session input.' : 'The Driver bridges image input and workspace-confined file operations.' },
    { id: 'interaction.events', status: 'supported', source: 'driver' },
    { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    { id: 'architecture.runtime-observation', status: observesRuntime ? 'runtime' : 'unsupported', source: 'runtime' },
    { id: 'architecture.edit', status: pack.graph.level === 'composable' && pack.graph.nodes.some(node => node.editable) ? 'supported' : 'unsupported', source: 'pack' },
    { id: 'diagnostics.preflight', status: 'supported', source: 'driver' },
    { id: 'builder.manifest', status: 'supported', source: 'pack' },
    { id: 'builder.test', status: 'supported', source: 'driver' },
    { id: 'builder.publish', status: 'unsupported', source: 'host', detail: 'Bundled catalog Packs are read only. Fork one under a user-owned id to use the real reviewed community submission workflow.' },
  ]
}

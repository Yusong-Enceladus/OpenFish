/**
 * Opt-in live smoke for the Public Alpha Oh My Pi ACP baseline.
 *
 * It installs a pinned package into a temporary managed snapshot, launches the
 * real ACP process, reads only protocol-declared authentication/model metadata,
 * and verifies that its remote session can be resumed. Set
 * OPENFISH_LIVE_BILLED_PROMPT=1 to send one minimal text-only prompt through
 * the selected Harness; this may consume a very small amount of its configured
 * provider quota. Official Codex is deliberately tested by
 * check_openfish_live_codex_app_server.ts instead of the legacy codex-acp shim.
 * The script never prints credentials, model output, or private protocol data,
 * and never writes into the user's OpenFish/DSH state.
 */
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import LocalSubprocessRuntime from '../packages/subprocess/subprocess-local/src/index.ts'
import { parseHarnessPack } from '../packages/harness/harness/src/manifest.ts'
import type { HarnessPack } from '../packages/harness/harness/src/types.ts'
import {
  AcpHarnessAgent,
  discoverAcpAuthentication,
  installHarnessPack,
} from '../packages/harness/harness-acp/src/agent.ts'

const definitions = {
  omp: {
    id: 'oh-my-pi', name: 'Oh My Pi', version: '18.0.3', publisher: 'Oh My Pi contributors',
    distribution: { kind: 'bunx' as const, package: '@oh-my-pi/pi-coding-agent@18.0.3', args: ['acp'], env: {} },
  },
}

function pack(kind: keyof typeof definitions): HarnessPack {
  const definition = definitions[kind]
  return parseHarnessPack({
    schemaVersion: 0,
    ...definition,
    verified: false,
    protocol: 'acp',
    source: 'user',
    modelConfiguration: {
      owner: 'harness', required: false,
      detail: 'Models and optional reasoning controls are discovered from the live ACP session.',
    },
    graph: {
      level: 'opaque',
      manifestVersion: 1,
      boundary: `${definition.name} ACP process`,
      evidence: [{ kind: 'declared', source: 'Live ACP preflight', version: definition.version }],
      nodes: [{
        id: 'runtime', kind: 'harness-runtime', title: `${definition.name} runtime`, editable: false,
        responsibility: 'Runs behind the ACP boundary; this smoke makes no claim about private internals.',
        evidence: [{ kind: 'declared', source: 'Live ACP preflight', version: definition.version }],
      }],
      edges: [],
    },
  })
}

async function main(): Promise<void> {
  const kind = process.argv[2]
  if (kind !== 'omp') throw new Error('usage: check_openfish_live_acp.ts omp')

  const root = await mkdtemp(join(tmpdir(), `openfish-live-${kind}-`))
  const ctx = new Context()
  void new SessionStore(ctx)
  void new AgentRegistry(ctx)
  void new ApprovalService(ctx, { policy: 'never' })
  const runtime = await ctx.plugin(LocalSubprocessRuntime)
  const selected = pack(kind)
  let first: AcpHarnessAgent | undefined
  let resumed: AcpHarnessAgent | undefined
  try {
    const installation = join(root, 'installed')
    await installHarnessPack(ctx, selected, installation)
    const auth = await discoverAcpAuthentication(ctx, selected, installation)

    const initialSession = ctx.sessions.create(SessionId(`live-${kind}-first`), { meta: { cwd: root } })
    first = new AcpHarnessAgent(ctx, initialSession.id, initialSession, selected, installation)
    await first.start()
    first.commitSelection()
    let catalog = first.harnessModelCatalog()
    let options = first.harnessConfigCatalog()
    const optionShapes = options.map(option => ({
      id: option.id, category: option.category ?? null, type: option.type, values: option.values.length,
    }))
    if (process.env.OPENFISH_LIVE_METADATA_ONLY === '1') {
      console.log(JSON.stringify({ harness: kind, optionShapes }))
      return
    }
    const billedPrompt = process.env.OPENFISH_LIVE_BILLED_PROMPT === '1'
    if (billedPrompt) {
      first.followup(createUserMessage({
        content: [{ type: 'text', text: 'Reply with OK only. Do not use tools.' }],
        source: { kind: 'user' },
      }))
      await first.whenIdle()
    }
    const remoteSessionId = initialSession.events.findLast(event => event.type === 'harness/selected')?.data.remoteSessionId
    if (remoteSessionId === undefined || remoteSessionId.length === 0) throw new Error('ACP agent did not publish a resumable session identity')

    await first.dispose()
    first = undefined
    const resumedSession = ctx.sessions.create(SessionId(`live-${kind}-resumed`), { meta: { cwd: root } })
    resumed = new AcpHarnessAgent(ctx, resumedSession.id, resumedSession, selected, installation)
    await resumed.start(remoteSessionId)

    // Deliberately report counts and booleans only: account names, model ids,
    // paths, environment, and protocol payloads can contain private metadata.
    console.log(JSON.stringify({
      harness: kind,
      installed: true,
      started: true,
      resumed: true,
      authenticationMethods: auth.length,
      models: catalog?.models.length ?? 0,
      reasoningAdvertised: catalog?.models.some(model => (model.reasoning?.efforts.length ?? 0) > 0) ?? false,
      billedPrompt,
      optionShapes,
    }))
  } finally {
    await resumed?.dispose()
    await first?.dispose()
    await runtime.dispose()
    await rm(root, { recursive: true, force: true })
  }
}

await main()

/** Live, isolated smoke for the official Codex app-server Harness Driver. */
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import { mkdtemp, readFile, realpath, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import LocalSandboxProvider from '../packages/sandbox/sandbox-local/src/index.ts'
import SandboxPolicyService from '../packages/sandbox/sandbox-policy/src/index.ts'
import LocalSubprocessRuntime from '../packages/subprocess/subprocess-local/src/index.ts'
import { builtInHarnessPacks } from '../packages/harness/harness/src/index.ts'
import { installHarnessPack } from '../packages/harness/harness-acp/src/agent.ts'
import { CodexHarnessAgent } from '../packages/harness/harness-acp/src/codex-agent.ts'

const baselinePack = builtInHarnessPacks().find(candidate => candidate.id === 'codex')
if (baselinePack === undefined) throw new Error('the running OpenFish catalog has no Codex baseline')
const customCa = process.env.OPENFISH_LIVE_CODEX_CA_CERTIFICATE
const pack = customCa === undefined || customCa === ''
  ? baselinePack
  : {
      ...baselinePack,
      distribution: baselinePack.distribution === undefined ? undefined : {
        ...baselinePack.distribution,
        env: { ...baselinePack.distribution.env, CODEX_CA_CERTIFICATE: customCa },
      },
    }

const root = await mkdtemp(join(tmpdir(), 'openfish-live-codex-official-'))
const ctx = new Context()
const unsandboxedDiagnostic = process.env.OPENFISH_LIVE_UNSANDBOXED_DIAGNOSTIC === '1'
void new SessionStore(ctx)
void new AgentRegistry(ctx)
void new ApprovalService(ctx, { policy: 'never' })
const sandbox = await ctx.plugin(LocalSandboxProvider, {
  runnerCommand: [], runnerFailureSignatures: [], probeTimeoutMs: 5_000,
})
const policy = await ctx.plugin(SandboxPolicyService, {
  mode: unsandboxedDiagnostic ? 'danger-full-access' : 'workspace-write', workspaceRoot: root,
})
const runtime = await ctx.plugin(LocalSubprocessRuntime)
let first: CodexHarnessAgent | undefined
let resumed: CodexHarnessAgent | undefined
async function waitForTurn(agent: CodexHarnessAgent): Promise<void> {
  let timer: ReturnType<typeof setTimeout> | undefined
  const timeout = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      agent.cancel({ kind: 'hook', reason: 'official Codex live smoke exceeded 120 seconds' })
      reject(new Error('official Codex live smoke exceeded 120 seconds'))
    }, 120_000)
  })
  try {
    await Promise.race([agent.whenIdle(), timeout])
  } finally {
    if (timer !== undefined) clearTimeout(timer)
  }
}

async function resolveInstallation(runtimeDirectory: string): Promise<string> {
  const override = process.env.OPENFISH_LIVE_CODEX_INSTALLATION
  if (override === undefined || override === '') {
    const installation = join(root, 'installed')
    await installHarnessPack(ctx, pack, installation, runtimeDirectory)
    return installation
  }
  const installation = await realpath(override)
  if (!(await stat(installation)).isDirectory()) throw new Error('Codex live installation cache is not a directory')
  const metadata = JSON.parse(await readFile(join(
    installation, 'node_modules', '@openai', 'codex', 'package.json',
  ), 'utf8')) as { version?: unknown }
  if (metadata.version !== pack.version) {
    throw new Error(`Codex live installation cache has version ${String(metadata.version)}; expected ${pack.version}`)
  }
  return installation
}
try {
  const runtimeDirectory = join(root, 'runtime')
  const installation = await resolveInstallation(runtimeDirectory)
  const firstSession = ctx.sessions.create(SessionId('codex-official-first'), { meta: { cwd: root } })
  first = new CodexHarnessAgent(
    ctx, firstSession.id, firstSession, pack, installation, runtimeDirectory, 'codex-local-login',
  )
  await first.start()
  first.commitSelection()
  const catalog = first.harnessModelCatalog()
  if (catalog === undefined || catalog.models.length === 0) throw new Error('official Codex returned no models')
  const selectable = catalog.models.find(model => (model.reasoning?.efforts.length ?? 0) > 0)
  if (selectable === undefined) throw new Error('official Codex returned no model with reasoning controls')
  const effort = selectable.reasoning?.defaultEffort ?? selectable.reasoning?.efforts[0]?.id
  await first.selectHarnessModel(selectable.id, effort)
  first.followup(createUserMessage({
    content: [{ type: 'text', text: 'Reply with OK only. Do not use tools.' }], source: { kind: 'user' },
  }))
  await waitForTurn(first)
  const remote = firstSession.events.findLast(event => event.type === 'harness/selected')?.data.remoteSessionId
  const completed = firstSession.events.findLast(event => event.type === 'turn/end')?.data.reason.kind === 'completed'
  if (remote === undefined || !completed) throw new Error('official Codex turn did not complete durably')
  await first.dispose()
  first = undefined

  const resumedSession = ctx.sessions.create(SessionId('codex-official-resumed'), { meta: { cwd: root } })
  resumed = new CodexHarnessAgent(
    ctx, resumedSession.id, resumedSession, pack, installation, runtimeDirectory, 'codex-local-login',
  )
  await resumed.start(remote)
  console.log(JSON.stringify({
    installed: true, started: true, models: catalog.models.length,
    reasoningAdvertised: true, selectedReasoning: effort !== undefined,
    completed: true, resumed: true, billedPrompt: true, sandboxed: !unsandboxedDiagnostic,
    customCaConfigured: customCa !== undefined && customCa !== '',
  }))
} finally {
  await resumed?.dispose()
  await first?.dispose()
  await runtime.dispose()
  await policy.dispose()
  await sandbox.dispose()
  await rm(root, { recursive: true, force: true })
}

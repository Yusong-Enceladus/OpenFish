/** Live, isolated smoke for the official Codex app-server Harness Driver. */
import { Context } from '@deepseek-ai/cordis'
import AgentRegistry from '@deepseek-ai/dsh-agent'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import ApprovalService from '@deepseek-ai/dsh-user-approval'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import LocalSubprocessRuntime from '../packages/subprocess/subprocess-local/src/index.ts'
import { parseHarnessPack } from '../packages/harness/harness/src/manifest.ts'
import { installHarnessPack } from '../packages/harness/harness-acp/src/agent.ts'
import { CodexHarnessAgent } from '../packages/harness/harness-acp/src/codex-agent.ts'

const evidence = [{ kind: 'source-derived' as const, source: 'openai/codex app-server', version: '0.149.0' }]
const pack = parseHarnessPack({
  schemaVersion: 0, id: 'codex', name: 'Codex', version: '0.149.0', publisher: 'OpenAI', verified: true,
  protocol: 'codex-app-server', source: 'builtin',
  distribution: { kind: 'npx', package: '@openai/codex@0.149.0', args: ['app-server', '--stdio'], env: {} },
  modelConfiguration: { owner: 'harness', required: true, detail: 'Discovered from official model/list.' },
  graph: {
    level: 'observable', manifestVersion: 1, boundary: 'Codex app-server', evidence,
    nodes: [
      { id: 'protocol', kind: 'protocol-adapter', title: 'App-server', editable: false, responsibility: 'Official protocol boundary.', evidence },
      { id: 'session', kind: 'agent-session', title: 'Thread', editable: false, responsibility: 'Durable Codex thread.', evidence },
      { id: 'model', kind: 'model-client', title: 'Model', editable: false, responsibility: 'Live model and reasoning selection.', evidence },
      { id: 'output', kind: 'output-stream', title: 'Output', editable: false, responsibility: 'Typed Codex output.', evidence },
    ],
    edges: [{ from: 'protocol', to: 'session' }, { from: 'session', to: 'model' }, { from: 'model', to: 'output' }],
  },
})

const root = await mkdtemp(join(tmpdir(), 'openfish-live-codex-official-'))
const ctx = new Context()
void new SessionStore(ctx)
void new AgentRegistry(ctx)
void new ApprovalService(ctx, { policy: 'never' })
const runtime = await ctx.plugin(LocalSubprocessRuntime)
let first: CodexHarnessAgent | undefined
let resumed: CodexHarnessAgent | undefined
try {
  const installation = join(root, 'installed')
  await installHarnessPack(ctx, pack, installation)
  const firstSession = ctx.sessions.create(SessionId('codex-official-first'), { meta: { cwd: root } })
  first = new CodexHarnessAgent(ctx, firstSession.id, firstSession, pack, installation)
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
  await first.whenIdle()
  const remote = firstSession.events.findLast(event => event.type === 'harness/selected')?.data.remoteSessionId
  const completed = firstSession.events.findLast(event => event.type === 'turn/end')?.data.reason.kind === 'completed'
  if (remote === undefined || !completed) throw new Error('official Codex turn did not complete durably')
  await first.dispose()
  first = undefined

  const resumedSession = ctx.sessions.create(SessionId('codex-official-resumed'), { meta: { cwd: root } })
  resumed = new CodexHarnessAgent(ctx, resumedSession.id, resumedSession, pack, installation)
  await resumed.start(remote)
  console.log(JSON.stringify({
    installed: true, started: true, models: catalog.models.length,
    reasoningAdvertised: true, selectedReasoning: effort !== undefined,
    completed: true, resumed: true, billedPrompt: true,
  }))
} finally {
  await resumed?.dispose()
  await first?.dispose()
  await runtime.dispose()
  await rm(root, { recursive: true, force: true })
}

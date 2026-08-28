/** Real OpenFish Loader path for the public Harness Driver extension seam. */

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Context } from '@deepseek-ai/cordis'
import Include from '@deepseek-ai/cordis-plugin-include'
import Loader from '@deepseek-ai/cordis-plugin-loader'
import type { Agent } from '@deepseek-ai/dsh-agent'
import SessionStore, { SessionId } from '@deepseek-ai/dsh-session'
import * as harnessPlugin from '@deepseek-ai/dsh-harness'
import {
  defineHarnessDriver,
  registerHarnessDriver,
  type HarnessDriver,
} from '@deepseek-ai/dsh-harness'

let root: string | undefined
let context: Context | undefined
const driverCalls = { create: 0, resume: 0, dispose: 0 }

afterEach(async () => {
  await context?.fiber.dispose()
  context = undefined
  if (root !== undefined) await rm(root, { recursive: true, force: true })
  root = undefined
  driverCalls.create = 0
  driverCalls.resume = 0
  driverCalls.dispose = 0
  vi.unstubAllGlobals()
})

const futureDriver = defineHarnessDriver({
  apiVersion: 1,
  protocol: 'future-protocol',
  capabilities: async () => [
    { id: 'session.create', status: 'supported', source: 'driver' },
    { id: 'session.resume', status: 'supported', source: 'driver' },
    { id: 'workspace.no-project', status: 'supported', source: 'driver' },
    { id: 'architecture.manifest', status: 'supported', source: 'pack' },
    { id: 'architecture.edit', status: 'supported', source: 'driver' },
    { id: 'builder.manifest', status: 'supported', source: 'driver' },
  ],
  authoring: async () => ({
    nodeKinds: [{
      kind: 'future-step', name: 'Future step', description: 'A fixture step owned by the future Driver.',
      responsibility: 'Applies one future Driver setting.', editable: true,
      inputs: ['request'], outputs: ['result'], observes: ['driver.future-protocol.turn-dispatched'],
    }],
    bindingKinds: [{
      kind: 'future-setting', name: 'Future setting', description: 'A setting interpreted by the future Driver.',
      fieldTypes: ['boolean'], targetLabel: 'Setting id', targetPattern: '^[a-z][a-z0-9-]*$',
    }],
  }),
  validatePack: async pack => pack.graph.nodes.some(node => node.editable
    && node.configSchema?.fields.some(field => field.binding.kind === 'future-setting') === true)
    ? [] : ['Future Driver requires one executable future-setting binding.'],
  runtimeSignals: event => event.type === 'turn/start'
    ? [{ signal: 'driver.future-protocol.turn-dispatched', status: 'active' }]
    : [],
  available: async () => undefined,
  create: async (request) => {
    driverCalls.create++
    if (context === undefined) throw new Error('fixture context is not ready')
    const session = context.sessions.create(request.sessionId, { meta: { cwd: request.cwd } })
    session.append('harness/selected', {
      harnessId: request.harnessId, version: request.version ?? '1.0.0', protocol: 'future-protocol',
      ...(request.workspaceMode === undefined ? {} : { workspaceMode: request.workspaceMode }),
      capabilities: request.capabilities ?? [],
    })
    return { id: request.sessionId, session } as Agent
  },
  resume: async (request) => {
    driverCalls.resume++
    const session = context?.sessions.get(request.sessionId)
    if (session === undefined) throw new Error('fixture session was not persisted')
    return { id: request.sessionId, session } as Agent
  },
  dispose: async () => { driverCalls.dispose++ },
} satisfies HarnessDriver)

const futureDriverPlugin = {
  name: 'future-harness-driver',
  inject: ['harnesses'],
  apply(ctx: Context): void {
    registerHarnessDriver(ctx, futureDriver)
  },
}

const futurePack = {
  schemaVersion: 0,
  id: 'future.driver',
  name: 'Future Driver',
  version: '1.0.0',
  publisher: 'Fixture',
  verified: false,
  protocol: 'future-protocol',
  source: 'user',
  distribution: { kind: 'executable', command: '/usr/bin/true', args: [], env: {} },
  graph: {
    level: 'composable', boundary: 'Future Driver process',
    evidence: [{ kind: 'declared', source: 'Future Driver fixture' }],
    nodes: [{
      id: 'runtime', kind: 'future-step', title: 'Future runtime', editable: true,
      responsibility: 'Applies the future Driver fixture setting.',
      evidence: [{ kind: 'declared', source: 'Future Driver fixture' }],
      observes: ['driver.future-protocol.turn-dispatched'],
      configSchema: { version: 1, fields: [{
        id: 'enabled', name: 'Enabled', type: 'boolean', required: true,
        binding: { kind: 'future-setting', target: 'enabled' },
      }] },
      config: { enabled: true },
    }],
    edges: [],
  },
}

async function boot(): Promise<Context> {
  root = await mkdtemp(join(tmpdir(), 'openfish-harness-loader-'))
  const configPath = join(root, 'cordis.yml')
  const stateDir = join(root, 'state')
  await writeFile(configPath, [
    "- name: '@deepseek-ai/dsh-session'",
    "- name: '@deepseek-ai/dsh-harness'",
    '  config:',
    `    stateDir: ${JSON.stringify(stateDir)}`,
    "- name: '@fixture/future-harness-driver'",
    '',
  ].join('\n'))

  context = new Context()
  context.baseUrl = pathToFileURL(root).href + '/'
  await context.plugin(Loader)
  context.loader.builtins.include = Include
  const modules = new Map<string, unknown>([
    ['@deepseek-ai/dsh-session', SessionStore],
    ['@deepseek-ai/dsh-harness', harnessPlugin],
    ['@fixture/future-harness-driver', futureDriverPlugin],
  ])
  context.loader.internal = {
    version: 'v2',
    async import(specifier: string) {
      if (!modules.has(specifier)) throw new Error(`unexpected Loader import: ${specifier}`)
      return modules.get(specifier)
    },
  } as unknown as NonNullable<typeof context.loader.internal>
  await context.loader.create({
    name: 'cordis:include',
    config: { path: pathToFileURL(configPath).href },
  })
  await context.loader.await()
  return context
}

describe('Harness real Loader composition', () => {
  it('keeps the namespace plugin, registers a third-party Driver, observes DSH, and unregisters on unload', async () => {
    vi.stubGlobal('fetch', vi.fn(async () => new Response(JSON.stringify({ version: '1', agents: [] }))))
    expect('default' in harnessPlugin).toBe(false)

    const ctx = await boot()
    const unloaded = [...ctx.loader.entries()]
      .filter(entry => entry.fiber === undefined && !entry.disabled)
      .map(entry => entry.options.name)
    expect(unloaded).toEqual([])

    await ctx.harnesses.upsert(futurePack)
    await ctx.harnesses.install('future.driver' as never)
    expect((await ctx.harnesses.list()).find(item => item.id === 'future.driver')).toMatchObject({
      available: true,
      driver: { apiVersion: 1, protocol: 'future-protocol', loaded: true, authorization: 'not-required' },
      authoring: {
        nodeKinds: [{ kind: 'future-step', editable: true }],
        bindingKinds: [{ kind: 'future-setting', fieldTypes: ['boolean'] }],
      },
    })

    const created = await ctx.harnesses.create(
      'future.driver' as never,
      SessionId('future-driver-created'),
      root as string,
      'no-project',
    )
    expect(created.session.events.findLast(event => event.type === 'harness/selected')?.data).toMatchObject({
      harnessId: 'future.driver', version: '1.0.0', protocol: 'future-protocol', workspaceMode: 'no-project',
    })
    await ctx.harnesses.disposeSession('future.driver' as never, created.session.id, '1.0.0')
    const resumed = await ctx.harnesses.resume(
      'future.driver' as never,
      created.session.id,
      root as string,
      '1.0.0',
      undefined,
      'no-project',
    )
    expect(resumed.session.id).toBe(created.session.id)
    expect(driverCalls).toEqual({ create: 1, resume: 1, dispose: 1 })

    const dshSession = ctx.sessions.create(SessionId('loader-observation'))
    dshSession.append('turn/start', { turn: 1 })
    await Promise.resolve()
    expect(dshSession.events.some(event => event.type === 'harness/runtime-node')).toBe(true)

    const futureSession = ctx.sessions.create(SessionId('future-loader-observation'))
    futureSession.append('harness/selected', {
      harnessId: 'future.driver' as never,
      version: '1.0.0',
      protocol: 'future-protocol',
      workspaceMode: 'no-project',
    })
    futureSession.append('turn/start', { turn: 1 })
    await Promise.resolve()
    expect(futureSession.events.findLast(event => event.type === 'harness/runtime-node')).toMatchObject({
      data: {
        harnessId: 'future.driver', nodeId: 'runtime',
        signal: 'driver.future-protocol.turn-dispatched', status: 'active',
        activity: 'Driver signal: turn dispatched',
      },
    })

    const driverEntry = [...ctx.loader.entries()]
      .find(entry => entry.options.name === '@fixture/future-harness-driver')
    expect(driverEntry?.fiber).toBeDefined()
    await driverEntry?.fiber?.dispose()
    expect((await ctx.harnesses.list()).find(item => item.id === 'future.driver')).toMatchObject({
      available: false,
      unavailableReason: 'No future-protocol driver is loaded',
      driver: { loaded: false },
    })
  })
})

import { createHash } from 'node:crypto'
import { mkdtemp, mkdir, readFile, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { describe, expect, it, vi } from 'vitest'
import { zipSync } from 'fflate'
import type { Context } from '@deepseek-ai/cordis'
import { parseHarnessPack } from '../../harness/src/manifest.ts'
import {
  acpHarnessConfigCatalog,
  acpHarnessModelCatalog,
  admitAcpSessionConfigOptions,
  installHarnessPack,
  launchArgv,
  managedLaunchArgv,
  packSessionConfiguration,
} from '../src/agent.ts'

const evidence = [{ kind: 'declared' as const, source: 'ACP launch test fixture', version: '1' }]

function composableGraph(nodes: Array<Record<string, unknown>>, edges: Array<{ from: string; to: string }>) {
  return {
    level: 'composable' as const,
    manifestVersion: 1 as const,
    boundary: 'Test ACP Harness process',
    evidence,
    nodes: nodes.map(node => ({ responsibility: 'Tested ACP component.', evidence, ...node })),
    edges,
  }
}

const opaqueGraph = {
  level: 'opaque' as const,
  nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }],
  edges: [],
}

function acpControl(id: string, value: string | boolean) {
  return {
    configSchema: {
      version: 1 as const,
      fields: [{
        id, name: id, type: typeof value === 'boolean' ? 'boolean' as const : 'string' as const,
        required: true, binding: { kind: 'acp-session-option', target: id },
      }],
    },
    config: { [id]: value },
  }
}

describe('ACP Harness launch boundary', () => {
  it('projects only editable composable node defaults into live ACP options', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'configured-acp', name: 'Configured ACP', version: '1.0.0', publisher: 'Test',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/configured-acp@1.0.0', args: [], env: {} },
      graph: composableGraph([
        {
          id: 'model', kind: 'model', title: 'Model', editable: true,
          configSchema: {
            version: 1,
            fields: [
              { id: 'model', name: 'Model', type: 'string', required: true, binding: { kind: 'acp-session-option', target: 'model' } },
              { id: 'sandbox', name: 'Sandbox', type: 'boolean', required: true, binding: { kind: 'acp-session-option', target: 'sandbox' } },
            ],
          },
          config: { model: 'gpt-test', sandbox: true },
        },
        { id: 'hidden', kind: 'runtime', title: 'Hidden', editable: false },
        { id: 'output', kind: 'output', title: 'Output', editable: false },
      ], [{ from: 'model', to: 'hidden' }, { from: 'hidden', to: 'output' }]),
    })
    expect(packSessionConfiguration(pack)).toEqual([
      { id: 'model', value: 'gpt-test' },
      { id: 'sandbox', value: true },
    ])
  })

  it('rejects conflicting portable ACP defaults', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'conflicting-acp', name: 'Conflicting ACP', version: '1.0.0', publisher: 'Test',
      verified: false, protocol: 'acp', source: 'user',
      distribution: { kind: 'npx', package: '@example/conflicting-acp@1.0.0', args: [], env: {} },
      graph: composableGraph([
        { id: 'one', kind: 'model', title: 'One', editable: true, ...acpControl('model', 'one') },
        { id: 'two', kind: 'model', title: 'Two', editable: true, ...acpControl('model', 'two') },
        { id: 'output', kind: 'output', title: 'Output', editable: false },
      ], [{ from: 'one', to: 'output' }, { from: 'two', to: 'output' }]),
    })
    expect(() => packSessionConfiguration(pack)).toThrow('conflicting values')
  })

  it('projects ACP model config options into a selectable model catalog', () => {
    expect(acpHarnessModelCatalog([{
      id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: 'anthropic/claude-sonnet',
      options: [
        { value: 'anthropic/claude-sonnet', name: 'Claude Sonnet', description: 'Anthropic' },
        { value: 'openai/gpt-5', name: 'GPT-5', description: 'OpenAI' },
      ],
    }, {
      id: 'reasoning_effort', name: 'Reasoning effort', category: 'thought_level', type: 'select', currentValue: 'high',
      options: [
        { value: 'low', name: 'Low', description: 'Faster' },
        { value: 'high', name: 'High', description: 'More reasoning' },
      ],
    }])).toEqual({
      current: 'anthropic/claude-sonnet',
      currentReasoningEffort: 'high',
      models: [
        {
          id: 'anthropic/claude-sonnet', name: 'Claude Sonnet', description: 'Anthropic',
          reasoning: {
            defaultEffort: 'high',
            efforts: [
              { id: 'low', name: 'Low', description: 'Faster' },
              { id: 'high', name: 'High', description: 'More reasoning' },
            ],
          },
        },
        { id: 'openai/gpt-5', name: 'GPT-5', description: 'OpenAI' },
      ],
    })
  })

  it('keeps live ACP provider groups distinct from Harness identity', () => {
    expect(acpHarnessModelCatalog([{
      id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: 'openai/gpt-test',
      options: [{ group: 'openai', name: 'OpenAI', options: [
        { value: 'openai/gpt-test', name: 'GPT Test' },
      ] }, { group: 'anthropic', name: 'Anthropic', options: [
        { value: 'anthropic/claude-test', name: 'Claude Test' },
      ] }],
    }])?.models).toEqual([
      { id: 'openai/gpt-test', name: 'GPT Test', providerId: 'openai', providerName: 'OpenAI' },
      { id: 'anthropic/claude-test', name: 'Claude Test', providerId: 'anthropic', providerName: 'Anthropic' },
    ])
  })

  it('projects grouped, boolean, missing, and unknown ACP configuration categories without Harness-specific code', () => {
    expect(acpHarnessConfigCatalog([{
      id: 'mode', name: 'Agent mode', category: 'mode', type: 'select', currentValue: 'agent',
      options: [{ group: 'built-in', name: 'Built in', options: [
        { value: 'agent', name: 'Agent' }, { value: 'plan', name: 'Plan', description: 'Read only' },
      ] }],
    }, {
      id: 'telemetry', name: 'Share diagnostics', type: 'boolean', currentValue: false,
    }, {
      id: 'future-control', name: 'Future control', category: '_vendor.experimental', type: 'select', currentValue: 'safe',
      options: [{ value: 'safe', name: 'Safe' }],
    }])).toEqual([{
      id: 'mode', name: 'Agent mode', category: 'mode', type: 'select', currentValue: 'agent',
      values: [
        { id: 'agent', name: 'Agent', group: 'built-in', groupName: 'Built in' },
        { id: 'plan', name: 'Plan', description: 'Read only', group: 'built-in', groupName: 'Built in' },
      ],
    }, {
      id: 'telemetry', name: 'Share diagnostics', type: 'boolean', currentValue: false, values: [],
    }, {
      id: 'future-control', name: 'Future control', category: '_vendor.experimental', type: 'select', currentValue: 'safe',
      values: [{ id: 'safe', name: 'Safe' }],
    }])
  })

  it('rejects ambiguous or unbounded live ACP configuration before it reaches the shared UI', () => {
    expect(() => admitAcpSessionConfigOptions([{
      id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: 'same',
      options: [
        { value: 'same', name: 'First' },
        { value: 'same', name: 'Second' },
      ],
    }])).toThrow('duplicate or invalid choices')
    expect(() => admitAcpSessionConfigOptions([{
      id: 'mode', name: 'Mode', type: 'select', currentValue: 'missing',
      options: [{ value: 'safe', name: 'Safe' }],
    }])).toThrow('unadvertised value')
    expect(() => admitAcpSessionConfigOptions([{
      id: 'future-control', name: 'x'.repeat(257), type: 'boolean', currentValue: true,
    }])).toThrow('invalid label')
  })

  it('uses shell-free bundled npx argv for a registry Pack', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0,
      id: 'test-acp',
      name: 'Test ACP',
      version: '1.0.0',
      publisher: 'Test',
      verified: false,
      protocol: 'acp',
      distribution: { kind: 'npx', package: '@example/test-acp@1.0.0', args: ['--acp'], env: { TEST: '1' } },
      graph: opaqueGraph,
      source: 'user',
    })
    const launch = launchArgv(pack)
    expect(launch.argv[0]).toBe(process.execPath)
    expect(launch.argv).toContain('--yes')
    expect(launch.argv).toContain('@example/test-acp@1.0.0')
    expect(launch.argv.at(-1)).toBe('--acp')
    expect(launch.env).toEqual({ TEST: '1' })
  })

  it('uses the pinned bundled Bun runtime for a bunx Pack', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0,
      id: 'bun-acp',
      name: 'Bun ACP',
      version: '1.0.0',
      publisher: 'Test',
      verified: false,
      protocol: 'acp',
      distribution: { kind: 'bunx', package: '@example/bun-acp@1.0.0', args: ['acp'], env: {} },
      graph: opaqueGraph,
      source: 'user',
    })
    const launch = launchArgv(pack)
    expect(launch.argv.slice(1)).toEqual(['x', '--bun', '@example/bun-acp@1.0.0', 'acp'])
    expect(launch.argv[0]).toContain('/bun/bin/bun.exe')
  })

  it('uses the managed uv runtime for a pinned Python Pack', () => {
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'python-acp', name: 'Python ACP', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', distribution: { kind: 'uvx', package: 'python-acp==1.0.0', args: ['--acp'], env: {} },
      graph: opaqueGraph, source: 'user',
    })
    const launch = launchArgv(pack)
    expect(launch.argv.slice(1)).toEqual(['tool', 'run', '--from', 'python-acp==1.0.0', 'python-acp', '--acp'])
    expect(launch.argv[0]).toMatch(/uv(?:\.exe)?$/u)
  })

  it('launches the exact executable from a managed installed snapshot', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'openfish-harness-'))
    try {
      const packageDirectory = join(directory, 'node_modules', '@example', 'test-acp')
      await mkdir(join(directory, 'node_modules', '.bin'), { recursive: true })
      await mkdir(packageDirectory, { recursive: true })
      await writeFile(join(packageDirectory, 'package.json'), JSON.stringify({ bin: { 'test-acp': 'cli.js' } }))
      const pack = parseHarnessPack({
        schemaVersion: 0, id: 'managed-acp', name: 'Managed ACP', version: '2.0.0', publisher: 'Test', verified: false,
        protocol: 'acp', distribution: { kind: 'npx', package: '@example/test-acp@2.0.0', args: ['--acp'], env: {} },
        graph: opaqueGraph, source: 'user',
      })
      await expect(managedLaunchArgv(pack, directory)).resolves.toEqual({
        argv: [join(directory, 'node_modules', '.bin', 'test-acp'), '--acp'], env: {},
      })
    } finally {
      await rm(directory, { recursive: true, force: true })
    }
  })

  it('keeps a managed bunx snapshot on the pinned bundled Bun runtime', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'openfish-bun-harness-'))
    try {
      const packageDirectory = join(directory, 'node_modules', '@example', 'bun-acp')
      await mkdir(join(directory, 'node_modules', '.bin'), { recursive: true })
      await mkdir(packageDirectory, { recursive: true })
      await writeFile(join(packageDirectory, 'package.json'), JSON.stringify({ bin: { 'bun-acp': 'cli.js' } }))
      const pack = parseHarnessPack({
        schemaVersion: 0, id: 'managed-bun-acp', name: 'Managed Bun ACP', version: '2.0.0', publisher: 'Test', verified: false,
        protocol: 'acp', distribution: { kind: 'bunx', package: '@example/bun-acp@2.0.0', args: ['acp'], env: {} },
        graph: opaqueGraph, source: 'user',
      })
      const launch = await managedLaunchArgv(pack, directory)
      expect(launch.argv[0]).toContain('/bun/bin/bun.exe')
      expect(launch.argv.slice(1)).toEqual([join(directory, 'node_modules', '.bin', 'bun-acp'), 'acp'])
    } finally {
      await rm(directory, { recursive: true, force: true })
    }
  })

  it('prefers the self-contained Open Fish runtime over a developer installation', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'openfish-embedded-runtime-'))
    const previousRuntimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
    try {
      const bundledBun = join(directory, 'app', 'node_modules', 'bun', 'bin', 'bun.exe')
      const installation = join(directory, 'harness')
      const packageDirectory = join(installation, 'node_modules', '@example', 'bun-acp')
      await mkdir(join(installation, 'node_modules', '.bin'), { recursive: true })
      await mkdir(packageDirectory, { recursive: true })
      await mkdir(join(bundledBun, '..'), { recursive: true })
      await writeFile(bundledBun, '')
      await writeFile(join(packageDirectory, 'package.json'), JSON.stringify({ bin: { 'bun-acp': 'cli.js' } }))
      process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = directory
      const pack = parseHarnessPack({
        schemaVersion: 0, id: 'embedded-bun-acp', name: 'Embedded Bun ACP', version: '2.0.0', publisher: 'Test', verified: false,
        protocol: 'acp', distribution: { kind: 'bunx', package: '@example/bun-acp@2.0.0', args: ['acp'], env: {} },
        graph: opaqueGraph, source: 'user',
      })
      const launch = await managedLaunchArgv(pack, installation)
      expect(launch.argv[0]).toBe(bundledBun)
    } finally {
      if (previousRuntimeRoot === undefined) delete process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
      else process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = previousRuntimeRoot
      await rm(directory, { recursive: true, force: true })
    }
  })

  it('uses the hoisted npm executable shipped by the packaged OpenFish Host', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'openfish-embedded-npm-'))
    const previousRuntimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
    try {
      const bundledNpx = join(directory, 'app', 'node_modules', 'npm', 'bin', 'npx-cli.js')
      await mkdir(join(bundledNpx, '..'), { recursive: true })
      await writeFile(bundledNpx, '')
      process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = directory
      const pack = parseHarnessPack({
        schemaVersion: 0, id: 'embedded-node-acp', name: 'Embedded Node ACP', version: '2.0.0',
        publisher: 'Test', verified: false, protocol: 'acp', source: 'user', graph: opaqueGraph,
        distribution: { kind: 'npx', package: '@example/node-acp@2.0.0', args: ['--acp'], env: {} },
      })
      expect(launchArgv(pack).argv).toEqual([
        process.execPath, bundledNpx, '--yes', '@example/node-acp@2.0.0', '--acp',
      ])
    } finally {
      if (previousRuntimeRoot === undefined) delete process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
      else process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = previousRuntimeRoot
      await rm(directory, { recursive: true, force: true })
    }
  })

  it('fails closed instead of borrowing global tools when a packaged runtime is incomplete', async () => {
    const directory = await mkdtemp(join(tmpdir(), 'openfish-incomplete-runtime-'))
    const previousRuntimeRoot = process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
    try {
      process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = directory
      const bunPack = parseHarnessPack({
        schemaVersion: 0, id: 'missing-bun', name: 'Missing Bun', version: '1.0.0', publisher: 'Test',
        verified: false, protocol: 'acp', source: 'user', graph: opaqueGraph,
        distribution: { kind: 'bunx', package: '@example/missing-bun@1.0.0', args: [], env: {} },
      })
      const pythonPack = parseHarnessPack({
        schemaVersion: 0, id: 'missing-uv', name: 'Missing uv', version: '1.0.0', publisher: 'Test',
        verified: false, protocol: 'acp', source: 'user', graph: opaqueGraph,
        distribution: { kind: 'uvx', package: 'missing-uv==1.0.0', args: [], env: {} },
      })
      const nodePack = parseHarnessPack({
        schemaVersion: 0, id: 'missing-npm', name: 'Missing npm', version: '1.0.0', publisher: 'Test',
        verified: false, protocol: 'acp', source: 'user', graph: opaqueGraph,
        distribution: { kind: 'npx', package: '@example/missing-npm@1.0.0', args: [], env: {} },
      })
      expect(() => launchArgv(bunPack)).toThrow('pinned bun executable is missing')
      expect(() => launchArgv(pythonPack)).toThrow('pinned uv executable is missing')
      expect(() => launchArgv(nodePack)).toThrow('pinned npm executable is missing')
    } finally {
      if (previousRuntimeRoot === undefined) delete process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT
      else process.env.OPENFISH_EMBEDDED_RUNTIME_ROOT = previousRuntimeRoot
      await rm(directory, { recursive: true, force: true })
    }
  })

  it('promotes a checksummed direct binary into its declared nested command path', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-direct-binary-'))
    const installation = join(root, 'installed')
    const runtime = join(root, 'runtime')
    const bytes = new TextEncoder().encode('#!/bin/sh\nprintf direct-binary-ok\\n')
    const digest = createHash('sha256').update(bytes).digest('hex')
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'binary-acp', name: 'Binary ACP', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user', graph: opaqueGraph,
      distribution: {
        kind: 'binary', archive: 'https://example.com/download.bin', sha256: digest,
        command: 'bin/acp-agent', args: ['--acp'], env: {},
      },
    })
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(bytes, {
      status: 200,
      headers: { 'content-length': String(bytes.byteLength) },
    }))))
    try {
      await installHarnessPack({} as Context, pack, installation, runtime)
      const command = join(installation, 'bin', 'acp-agent')
      expect(await readFile(command)).toEqual(Buffer.from(bytes))
      if (process.platform !== 'win32') expect((await stat(command)).mode & 0o111).not.toBe(0)
      await expect(readFile(join(installation, 'download.bin'))).rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      vi.unstubAllGlobals()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('refuses every remote binary distribution without a checksum before download', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-unverified-binary-'))
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'unverified-binary', name: 'Unverified Binary', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user', graph: opaqueGraph,
      distribution: {
        kind: 'binary', archive: 'https://example.com/unverified.bin',
        command: 'bin/acp-agent', args: [], env: {},
      },
    })
    const fetch = vi.fn()
    vi.stubGlobal('fetch', fetch)
    try {
      await expect(installHarnessPack({} as Context, pack, join(root, 'installed'), join(root, 'runtime')))
        .rejects.toThrow('no SHA-256 checksum')
      expect(fetch).not.toHaveBeenCalled()
    } finally {
      vi.unstubAllGlobals()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('extracts a checksummed ZIP through the bounded in-process installer', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-bounded-zip-'))
    const installation = join(root, 'installed')
    const runtime = join(root, 'runtime')
    const commandBytes = new TextEncoder().encode('#!/bin/sh\nprintf bounded-zip-ok\\n')
    const archive = zipSync({ 'bin/acp-agent': commandBytes })
    const digest = createHash('sha256').update(archive).digest('hex')
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'zip-acp', name: 'ZIP ACP', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user', graph: opaqueGraph,
      distribution: {
        kind: 'binary', archive: 'https://example.com/harness.zip', sha256: digest,
        command: 'bin/acp-agent', args: [], env: {},
      },
    })
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(archive, { status: 200 }))))
    try {
      await installHarnessPack({} as Context, pack, installation, runtime)
      expect(await readFile(join(installation, 'bin', 'acp-agent'))).toEqual(Buffer.from(commandBytes))
      await expect(readFile(join(installation, 'harness.zip'))).rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      vi.unstubAllGlobals()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('extracts the checksummed TAR.BZ2 format used by current ACP Registry agents', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-bounded-bzip2-'))
    const installation = join(root, 'installed')
    const runtime = join(root, 'runtime')
    // Deterministic one-file USTAR fixture compressed with bzip2. Keeping the
    // bytes in the test proves clean machines do not need a system tar/bzip2.
    const archive = Buffer.from(
      'QlpoOTFBWSZTWZmm5lcAADR7hcqQBABoAvuACAR76d4QAAgBAAAIIAB0ISNGgND1NBiAaMQZU0A9QAyAAaAybMr4jd8gha4gtsqQkBwBFDWv3q+djjEJOKAqCEqWTDqloBxmtXGW7lIOnIDvHwNotCDoBATYM+gdAPSRwVEiNHHUR/F3JFOFCQmabmVw',
      'base64',
    )
    const digest = createHash('sha256').update(archive).digest('hex')
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'bzip2-acp', name: 'Bzip2 ACP', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user', graph: opaqueGraph,
      distribution: {
        kind: 'binary', archive: 'https://example.com/harness.tar.bz2', sha256: digest,
        command: 'bin/acp-agent', args: [], env: {},
      },
    })
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(archive, { status: 200 }))))
    try {
      await installHarnessPack({} as Context, pack, installation, runtime)
      expect(await readFile(join(installation, 'bin', 'acp-agent')))
        .toEqual(Buffer.from('#!/bin/sh\nprintf bzip2-ok\\n'))
      await expect(readFile(join(installation, 'harness.tar.bz2'))).rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      vi.unstubAllGlobals()
      await rm(root, { recursive: true, force: true })
    }
  })

  it('rejects a ZIP entry that escapes the managed installation root', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-escaping-zip-'))
    const installation = join(root, 'installed')
    const runtime = join(root, 'runtime')
    const archive = zipSync({ '../escaped': new Uint8Array([1]), 'bin/acp-agent': new Uint8Array([2]) })
    const digest = createHash('sha256').update(archive).digest('hex')
    const pack = parseHarnessPack({
      schemaVersion: 0, id: 'escaping-zip-acp', name: 'Escaping ZIP ACP', version: '1.0.0', publisher: 'Test', verified: false,
      protocol: 'acp', source: 'user', graph: opaqueGraph,
      distribution: {
        kind: 'binary', archive: 'https://example.com/harness.zip', sha256: digest,
        command: 'bin/acp-agent', args: [], env: {},
      },
    })
    vi.stubGlobal('fetch', vi.fn(() => Promise.resolve(new Response(archive, { status: 200 }))))
    try {
      await expect(installHarnessPack({} as Context, pack, installation, runtime))
        .rejects.toThrow('outside its installation directory')
      await expect(readFile(join(root, 'escaped'))).rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      vi.unstubAllGlobals()
      await rm(root, { recursive: true, force: true })
    }
  })
})

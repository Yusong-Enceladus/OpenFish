#!/usr/bin/env node
/**
 * opencodex — Codex-compatible command surface over the DSH product base.
 *
 * The command tree, flags, and help descriptions are generated from the E1
 * Codex CLI baseline (see codex-parity/tools/generate_x_cli_manifest.py).
 * `x <cmd> --help` therefore mirrors the captured Codex help surface; the
 * handlers in handlers.ts own behavior. `x` remains an executable alias for
 * existing installations; the product and help identity are OpenCodex.
 */

import { Command, Option } from 'commander'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { run } from './handlers.ts'
import { commanderOption, loadManifest, type CommandManifest } from './manifest.ts'

function readVersion(): string {
  const manifest = JSON.parse(
    readFileSync(fileURLToPath(new URL('../package.json', import.meta.url)), 'utf8'),
  ) as { version?: unknown }
  return typeof manifest.version === 'string' ? manifest.version : '0.0.0'
}

const REPEATABLE_OPTIONS = new Set([
  '--config', '--enable', '--disable', '--image', '--add-dir', '--env', '--sparse', '--thread',
  '--sandbox-state-readable-root', '--allow-unix-socket',
])

function addManifestOption(command: Command, option: CommandManifest['root_options'][number]): void {
  const configured = new Option(commanderOption(option), option.description)
  if (option.flags.some(flag => REPEATABLE_OPTIONS.has(flag))) {
    configured.argParser((value: string, previous: string[] | undefined) => [...(previous ?? []), value])
  }
  command.addOption(configured)
}

function build(manifest: CommandManifest): Command {
  const program = new Command()
    .name('opencodex')
    .description('OpenCodex — native and remote coding agent surfaces on the DSH runtime')
    .version(readVersion())
    .helpOption('-h, --help', 'display help for command')
    .showHelpAfterError()
    .argument('[prompt...]', 'optional initial prompt; without one, open the native/Web surface')

  for (const option of manifest.root_options) {
    // Commander owns the version and help flags; the generated manifest also
    // carries the captured Codex flags, so skip them to avoid duplicate-flag
    // conflicts and to preserve Commander's help/version short-circuits.
    if (option.flags.includes('--version') || option.flags.includes('-V')
      || option.flags.includes('--help') || option.flags.includes('-h')) continue
    addManifestOption(program, option)
  }

  const nodes = new Map<string, Command>()
  nodes.set('', program)

  program.action(async (prompt: string[], command: Command) => {
    const code = await run(
      { path: prompt.length === 0 ? 'app' : 'exec', args: prompt },
      command.opts(),
    )
    if (code !== 0) process.exitCode = code
  })
  for (const entry of manifest.commands) {
    const segments = entry.path.split('/')
    let parent = program
    let prefix = ''
    for (let index = 0; index < segments.length - 1; index += 1) {
      const segment = segments[index]
      if (segment === undefined) throw new Error(`invalid command path ${JSON.stringify(entry.path)}`)
      prefix = prefix === '' ? segment : `${prefix}/${segment}`
      const existing = nodes.get(prefix)
      if (existing !== undefined) {
        parent = existing
        continue
      }
      const node = new Command(segment)
      parent.addCommand(node)
      nodes.set(prefix, node)
      parent = node
    }
    const leafName = segments.at(-1)
    if (leafName === undefined) throw new Error(`invalid command path ${JSON.stringify(entry.path)}`)
    const leaf = new Command(leafName)
    const commandArguments = entry.path === 'sandbox' ? ['[command...]'] : entry.arguments
    for (const argument of commandArguments) {
      leaf.argument(argument)
    }
    for (const option of entry.options) {
      if (option.flags.includes('--help') || option.flags.includes('-h')) continue
      addManifestOption(leaf, option)
    }
    leaf.description(entry.description)
    leaf.action(async (...actionArgs: unknown[]) => {
      const command = actionArgs.pop() as Command
      const collected: Record<string, unknown> = {}
      const chain: Command[] = []
      for (let cursor: Command | null = command; cursor !== null; cursor = cursor.parent ?? null) chain.unshift(cursor)
      for (const cursor of chain) Object.assign(collected, cursor.opts())
      const opts = collected
      const args = actionArgs.flatMap((arg): string[] => {
        if (typeof arg === 'string') return [arg]
        if (Array.isArray(arg)) return arg.filter((value): value is string => typeof value === 'string')
        return []
      })
      const code = await run({ path: entry.path, args }, opts)
      if (code !== 0) process.exitCode = code
    })
    parent.addCommand(leaf)
    nodes.set(entry.path, leaf)
  }

  return program
}

const program = build(loadManifest())
await program.parseAsync(process.argv)

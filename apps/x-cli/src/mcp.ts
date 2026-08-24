/**
 * Codex `mcp add/list/get/remove` semantics over the dsh MCP client.
 *
 * MCP servers are rows in the X product profile patch
 * (`$DSH_HOME/profiles/x/cordis.patch.yml`), each row mounting one
 * `@deepseek-ai/dsh-mcp-client` instance. OAuth login/logout are handled by a
 * later milestone; this module owns the configuration plane.
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'
import { dump, load } from 'js-yaml'

export interface McpServerView {
  id: string
  name: string
  transport: 'stdio' | 'streamable-http'
  config: Record<string, unknown>
}

interface PatchRow {
  id?: string
  name?: string
  [key: string]: unknown
}

export function profilePatchPath(): string {
  return join(process.env.DSH_HOME ?? join(homedir(), '.dsh'), 'profiles', 'x', 'cordis.patch.yml')
}

function loadPatch(): PatchRow[] {
  try {
    const value = load(readFileSync(profilePatchPath(), 'utf8'))
    if (Array.isArray(value)) return value as PatchRow[]
    return []
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return []
    throw error
  }
}

function savePatch(rows: PatchRow[]): void {
  const path = profilePatchPath()
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  writeFileSync(path, dump(rows, { lineWidth: 100 }) + '\n', { mode: 0o600 })
}

function rowId(name: string): string {
  return `mcp-${name}`
}

export function listServers(): McpServerView[] {
  return loadPatch()
    .filter((row): row is PatchRow & { id: string; name: string; config: Record<string, unknown> } =>
      typeof row.id === 'string' && row.id.startsWith('mcp-')
      && row.name === '@deepseek-ai/dsh-mcp-client'
      && typeof row.config === 'object' && row.config !== null)
    .map(row => ({
      id: row.id,
      name: typeof row.config.serverName === 'string' ? row.config.serverName : row.id,
      transport: row.config.transport === 'stdio' ? 'stdio' : 'streamable-http',
      config: row.config,
    }))
}

export function getServer(name: string): McpServerView | undefined {
  return listServers().find(server => server.name === name || server.id === rowId(name))
}

function validateName(name: string): void {
  if (!/^[A-Za-z0-9_-]{1,32}$/.test(name)) {
    throw new Error(`MCP server name must match [A-Za-z0-9_-]{1,32}; got ${JSON.stringify(name)}`)
  }
}

export function addServer(name: string, options: {
  url?: string
  env?: Record<string, string>
  bearerTokenEnvVar?: string
  commandArgs?: string[]
}): McpServerView {
  validateName(name)
  if (options.url !== undefined && options.commandArgs !== undefined && options.commandArgs.length > 0) {
    throw new Error('--url and -- <COMMAND> are mutually exclusive')
  }
  if (options.url !== undefined && Object.keys(options.env ?? {}).length > 0) {
    throw new Error('--env applies only to stdio MCP servers')
  }
  if (options.url === undefined && options.bearerTokenEnvVar !== undefined) {
    throw new Error('--bearer-token-env-var applies only to HTTP MCP servers')
  }
  if (options.bearerTokenEnvVar !== undefined && !/^[A-Za-z_][A-Za-z0-9_]*$/.test(options.bearerTokenEnvVar)) {
    throw new Error('--bearer-token-env-var must name an environment variable')
  }
  if (options.url !== undefined) {
    const url = new URL(options.url)
    if (!['http:', 'https:'].includes(url.protocol)) throw new Error('MCP URL must use http or https')
    if (url.username !== '' || url.password !== '') throw new Error('MCP URL must not embed credentials; use --bearer-token-env-var')
  }
  const rows = loadPatch().filter(row => row.id !== rowId(name))
  const config: Record<string, unknown> = options.url !== undefined
    ? {
      transport: 'streamable-http',
      serverName: name,
      url: options.url,
      headers: {},
      ...(options.bearerTokenEnvVar === undefined
        ? {}
        : { bearerTokenEnv: options.bearerTokenEnvVar }),
    }
    : {
      transport: 'stdio',
      serverName: name,
      command: options.commandArgs?.[0] ?? '',
      args: options.commandArgs?.slice(1) ?? [],
      env: options.env ?? {},
      cwd: '',
    }
  if (options.url === undefined && config.command === '') {
    throw new Error('stdio MCP servers require -- <COMMAND> [ARGS...]')
  }
  rows.push({ id: rowId(name), name: '@deepseek-ai/dsh-mcp-client', config })
  savePatch(rows)
  return { id: rowId(name), name, transport: config.transport as 'stdio' | 'streamable-http', config }
}

export function removeServer(name: string): boolean {
  const rows = loadPatch()
  const next = rows.filter(row => row.id !== rowId(name))
  if (next.length === rows.length) return false
  savePatch(next)
  return true
}

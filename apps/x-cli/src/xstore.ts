/**
 * Client-only JSON stores under `$OPENCODEX_HOME`. Model credentials are
 * intentionally absent: they live behind DSH's credentials service. This
 * module stores only plugin source metadata and the local connection identity.
 */

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, join } from 'node:path'

export interface Marketplace {
  name: string
  source: string
  kind?: 'local' | 'git'
  root?: string
  ref?: string
  sparse?: string[]
  updatedAt: string
}

export interface ConnectionProfile {
  api: string
  deviceId: string
  token: string
  expiresAt: number
  updatedAt: string
}

function storePath(name: string): string {
  return join(
    process.env.OPENCODEX_HOME ?? process.env.X_HOME ?? join(homedir(), '.opencodex'),
    name,
  )
}

export function marketplaceCacheRoot(): string {
  return storePath('marketplaces')
}

function readStore<T>(name: string, fallback: T): T {
  try {
    return JSON.parse(readFileSync(storePath(name), 'utf8')) as T
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return fallback
    throw error
  }
}

function writeStore(name: string, value: unknown): void {
  const path = storePath(name)
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
  writeFileSync(path, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 })
}

export function loadConnection(): ConnectionProfile | undefined {
  const value = readStore<ConnectionProfile | undefined>('connection.json', undefined)
  return typeof value?.api === 'string' && typeof value.token === 'string' ? value : undefined
}

export function saveConnection(connection: ConnectionProfile): ConnectionProfile {
  writeStore('connection.json', connection)
  return connection
}

export function clearConnection(): void {
  writeStore('connection.json', {})
}

export function listMarketplaces(): Marketplace[] {
  return readStore<Marketplace[]>('marketplaces.json', [])
}

export function saveMarketplace(marketplace: Marketplace): Marketplace[] {
  const next = [
    ...listMarketplaces().filter(entry => entry.name !== marketplace.name),
    marketplace,
  ].sort((left, right) => left.name.localeCompare(right.name))
  writeStore('marketplaces.json', next)
  return next
}

export function removeMarketplace(name: string): boolean {
  const before = listMarketplaces()
  const next = before.filter(entry => entry.name !== name)
  if (next.length === before.length) return false
  writeStore('marketplaces.json', next)
  return true
}

/** Read stdin up to a small bound for `login --with-*`. */
export function readStdin(limit = 64 * 1024): Promise<string> {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks: Buffer[] = []
    process.stdin.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > limit) {
        reject(new Error(`stdin exceeds ${limit} bytes`))
        process.stdin.destroy()
        return
      }
      chunks.push(chunk)
    })
    process.stdin.on('end', () => { resolve(Buffer.concat(chunks).toString('utf8').trim()) })
    process.stdin.on('error', reject)
  })
}

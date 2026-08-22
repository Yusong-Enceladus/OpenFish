/**
 * x-native bundle tests: the patch layer parses, the wire extraction is
 * stable, and the pairing registry is durable and token-safe.
 */

import { readFileSync } from 'node:fs'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import * as yaml from 'js-yaml'
import { entryListSchema } from '@deepseek-ai/cordis-plugin-include'
import { PairingStore } from '../src/pairing.ts'
import { toNativeMethod } from '../src/protocol.ts'

describe('x-native bundle patch', () => {
  it('declares the x-native row over the web-server surface', () => {
    const root = fileURLToPath(new URL('..', import.meta.url))
    const manifest = JSON.parse(
      readFileSync(resolve(root, 'package.json'), 'utf8'),
    ) as { dsh?: { bundle?: { patch?: string } } }
    expect(manifest.dsh?.bundle?.patch).toBe('./cordis.patch.yml')
    const parsed = yaml.load(
      readFileSync(resolve(root, manifest.dsh!.bundle!.patch!), 'utf8'),
      { schema: entryListSchema },
    )
    if (!Array.isArray(parsed)) throw new TypeError('x-native patch must parse to a patch list')
    const rows = parsed.flatMap((patch): Record<string, unknown>[] =>
      typeof patch === 'object' && patch !== null
        ? (patch as { insert?: Record<string, unknown>[] }).insert ?? []
        : [],
    )
    expect(rows.filter(row => row.id === 'x-native')).toHaveLength(1)
    const row = rows.find(candidate => candidate.id === 'x-native')!
    expect(row.name).toBe('@deepseek-ai/dsh-bundle-x-native')
    expect(row.inject).toEqual(['webServer', 'connection'])
    expect(row.config).toEqual({ protocolVersion: 'v2' })
  })
})

describe('toNativeMethod', () => {
  it('extracts the endpoint and wire parameters from a Typert descriptor', () => {
    const method = toNativeMethod({
      id: 'generated-id',
      service: 'sessions',
      namespace: 'sessions',
      method: 'create',
      parameters: [
        { name: 'payload', wire: 'payload', codec: 'sessions/create.payload' },
      ],
      result: { codec: 'sessions/create.result' },
    })
    expect(method).toEqual({
      endpoint: 'sessions/create',
      service: 'sessions',
      namespace: 'sessions',
      method: 'create',
      parameters: ['payload'],
    })
  })

  it('rejects descriptors that miss required string fields', () => {
    expect(toNativeMethod(null)).toBeUndefined()
    expect(toNativeMethod({ namespace: 'x', method: 'y' })).toBeUndefined()
  })
})

describe('PairingStore', () => {
  it('pairs, lists, and verifies devices; only the digest is persisted', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'x-native-pair-'))
    try {
      const store = new PairingStore(join(dir, 'devices.json'), 1000)
      const pair = await store.pair({ surface: 'iphone', deviceName: 'test phone', appVersion: '0.1.0' })
      expect(pair.deviceId).toBeTruthy()
      expect(pair.token).toHaveLength(43)
      expect(await store.list()).toEqual([
        expect.objectContaining({ deviceId: pair.deviceId, name: 'test phone', surface: 'iphone' }),
      ])
      expect(await store.verify(pair.token)).toEqual(expect.objectContaining({ deviceId: pair.deviceId }))
      expect(await store.verify('not-the-token')).toBeUndefined()
      const persisted = JSON.parse(await readFile(join(dir, 'devices.json'), 'utf8')) as Record<string, unknown>[]
      expect(persisted).toHaveLength(1)
      expect(persisted[0]).not.toHaveProperty('token')
      expect(persisted[0]?.tokenHash).toMatch(/^[0-9a-f]{64}$/)
      expect(JSON.stringify(persisted)).not.toContain(pair.token)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('survives a reopen and drops expired devices', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'x-native-pair-'))
    try {
      const file = join(dir, 'devices.json')
      const store = new PairingStore(file, 1000)
      const pair = await store.pair({ surface: 'macos', deviceName: 'test mac' })
      const reopened = new PairingStore(file, 1000)
      expect((await reopened.list()).map(device => device.deviceId)).toContain(pair.deviceId)
      await new Promise(resolvePromise => setTimeout(resolvePromise, 1100))
      expect(await reopened.list()).toEqual([])
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})

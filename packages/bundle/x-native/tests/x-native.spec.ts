/**
 * x-native bundle tests: the patch layer parses, the wire extraction is
 * stable, and the pairing registry is durable and token-safe.
 */

import { readFileSync } from 'node:fs'
import { createHash, createHmac } from 'node:crypto'
import { createServer } from 'node:http'
import type { AddressInfo } from 'node:net'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'
import { Context } from '@deepseek-ai/cordis'
import type { WebRoute, WebServer } from '@deepseek-ai/dsh-host-webserver'
import { describe, expect, it } from 'vitest'
import * as yaml from 'js-yaml'
import { entryListSchema } from '@deepseek-ai/cordis-plugin-include'
import { XNative } from '../src/index.ts'
import { PairingStore } from '../src/pairing.ts'
import { toNativeMethod } from '../src/protocol.ts'

function fakeWebServer(routes: WebRoute[]): WebServer {
  return {
    host: '127.0.0.1',
    remotePort: undefined,
    exposesSecureRemote: false,
    remoteCertificateFingerprint: undefined,
    register(route: WebRoute) {
      routes.push(route)
      return () => { routes.splice(routes.indexOf(route), 1) }
    },
  } as unknown as WebServer
}

async function serveRoute(route: WebRoute): Promise<{ origin: string; close(): Promise<void> }> {
  const server = createServer((request, response) => { void route.handler(request, response) })
  await new Promise<void>(resolvePromise => server.listen(0, '127.0.0.1', resolvePromise))
  const address = server.address() as AddressInfo
  return {
    origin: `http://127.0.0.1:${String(address.port)}`,
    close: () => new Promise<void>((resolvePromise, reject) => {
      server.close((error) => {
        if (error === undefined || error === null) resolvePromise()
        else reject(error)
      })
    }),
  }
}

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

describe('x-native HTTP validation', () => {
  it('rejects a missing device identity without committing a registration', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'x-native-route-'))
    const ctx = new Context()
    const routes: WebRoute[] = []
    ctx.provide('webServer', fakeWebServer(routes))
    ctx.provide('connection', {
      security: {
        isTrusted: () => true,
        isLoopback: () => true,
        isSecure: () => false,
        authenticate: async () => false,
        registerAuthenticator: () => async () => {},
        hasAuthenticator: false,
      },
    } as unknown as Context['connection'])
    const native = new XNative(ctx, { protocolVersion: 'v2', dataDir: dir })
    const route = routes.find(candidate => candidate.path === '/x-native/v2/pair')
    if (route === undefined) throw new Error('pair route did not register')
    const server = await serveRoute(route)

    try {
      const response = await fetch(`${server.origin}/x-native/v2/pair`, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: '{}',
      })
      expect(response.status).toBe(400)
      await expect(response.json()).resolves.toMatchObject({
        error: { code: 'invalid-request' },
      })
      await expect(native.devices()).resolves.toEqual([])
    } finally {
      await server.close()
      await ctx.fiber.dispose()
      await rm(dir, { recursive: true, force: true })
    }
  })

  it('lets a paired device revoke only the credential proven by its bearer token', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'x-native-self-revoke-'))
    const ctx = new Context()
    const routes: WebRoute[] = []
    ctx.provide('webServer', fakeWebServer(routes))
    ctx.provide('connection', {
      security: {
        isTrusted: () => true,
        isLoopback: () => true,
        isSecure: () => false,
        authenticate: async () => false,
        registerAuthenticator: () => async () => {},
        hasAuthenticator: false,
      },
    } as unknown as Context['connection'])
    const native = new XNative(ctx, { protocolVersion: 'v2', dataDir: dir })
    const first = await native.pair({ surface: 'iphone', deviceName: 'first phone' })
    const second = await native.pair({ surface: 'iphone', deviceName: 'second phone' })
    const route = routes.find(candidate => candidate.path === '/x-native/v2/self/revoke')
    if (route === undefined) throw new Error('self-revoke route did not register')
    const server = await serveRoute(route)

    try {
      const response = await fetch(`${server.origin}/x-native/v2/self/revoke`, {
        method: 'POST',
        headers: { authorization: `Bearer ${first.token}` },
      })
      expect(response.status).toBe(200)
      await expect(response.json()).resolves.toEqual({ revoked: true })
      await expect(native.devices()).resolves.toEqual([
        expect.objectContaining({ deviceId: second.deviceId, name: 'second phone' }),
      ])

      const replay = await fetch(`${server.origin}/x-native/v2/self/revoke`, {
        method: 'POST',
        headers: { authorization: `Bearer ${first.token}` },
      })
      expect(replay.status).toBe(401)
      await expect(replay.json()).resolves.toMatchObject({ error: { code: 'pairing-required' } })
    } finally {
      await server.close()
      await ctx.fiber.dispose()
      await rm(dir, { recursive: true, force: true })
    }
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
      const beforeRevoke = JSON.parse(await readFile(join(dir, 'devices.json'), 'utf8')) as Record<string, unknown>[]
      expect(beforeRevoke).toHaveLength(1)
      expect(beforeRevoke[0]).not.toHaveProperty('token')
      expect(beforeRevoke[0]?.tokenHash).toMatch(/^[0-9a-f]{64}$/)
      expect(JSON.stringify(beforeRevoke)).not.toContain(pair.token)
      expect(await store.revoke(pair.deviceId)).toBe(true)
      expect(await store.verify(pair.token)).toBeUndefined()
      expect(JSON.parse(await readFile(join(dir, 'devices.json'), 'utf8'))).toEqual([])
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

  it('requires the out-of-band code itself for a certificate-bound remote proof', async () => {
    const dir = await mkdtemp(join(tmpdir(), 'x-native-pair-'))
    try {
      const store = new PairingStore(join(dir, 'devices.json'))
      const minted = store.createPairingCode()
      expect(minted.transport).toBe('tls-code-proof-v2')
      const secret = minted.code.replace(/[^A-Za-z0-9]/gu, '').toUpperCase()
      const codeId = createHash('sha256').update(secret).digest('hex')
      expect(codeId).toBe(minted.codeId)
      const certificateFingerprint = 'ab'.repeat(32)
      const request = {
        surface: 'iphone' as const,
        deviceName: 'proof phone',
        appVersion: '0.1.0',
        codeId,
        clientNonce: Buffer.alloc(24, 7).toString('base64url'),
      }
      const message = [
        'openfish-pair-v1', certificateFingerprint, request.clientNonce,
        request.surface, request.deviceName, request.appVersion,
      ].join('\0')

      // codeId crosses the bootstrap connection and is therefore not a
      // secret. It must be insufficient to manufacture the proof.
      const publicIdProof = createHmac('sha256', Buffer.from(codeId, 'hex')).update(message).digest('hex')
      await expect(store.redeemTlsProof({ ...request, proof: publicIdProof }, certificateFingerprint))
        .rejects.toThrow(/does not match/)

      const secretProof = createHmac('sha256', secret).update(message).digest('hex')
      const paired = await store.redeemTlsProof({ ...request, proof: secretProof }, certificateFingerprint)
      expect(await store.verify(paired.token)).toEqual(expect.objectContaining({ deviceId: paired.deviceId }))
      await expect(store.redeemTlsProof({ ...request, proof: secretProof }, certificateFingerprint))
        .rejects.toThrow(/invalid or expired/)
    } finally {
      await rm(dir, { recursive: true, force: true })
    }
  })
})

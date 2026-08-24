/**
 * Durable native-device registry for the x-native bundle.
 *
 * The registry is a single JSON file under the dsh home
 * (`x-native/devices.json`), atomically rewritten. Tokens are stored as
 * SHA-256 digests only; the secret is returned once at pairing time.
 */

import { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname } from 'node:path'
import type {
  NativeDeviceView,
  PairingCodeResponse,
  PairRequest,
  PairResponse,
} from './protocol.ts'

/** Public row plus the stored token digest. */
interface StoredDevice extends NativeDeviceView {
  tokenHash: string
}

/** Default registration lifetime. */
export const DEFAULT_PAIR_TTL_MS = 30 * 24 * 60 * 60 * 1000

/** Default maximum number of registered devices. */
export const DEFAULT_MAX_DEVICES = 32

/** Ten minutes: long enough to type on a phone, short enough to limit guessing. */
export const DEFAULT_PAIR_CODE_TTL_MS = 10 * 60 * 1000

/** Avoid rewriting the durable registry on every streamed/API request. */
const LAST_SEEN_WRITE_INTERVAL_MS = 60 * 1000

export class PairingStore {
  private readonly loaded: StoredDevice[] = []
  // Short-lived pairing codes never touch disk. Retaining the normalized
  // secret in Host memory lets the TLS bootstrap prove knowledge of the code
  // itself; using only its transmitted public id as an HMAC key would let a
  // first-connection TLS interceptor manufacture a valid proof.
  private readonly pairingCodes = new Map<string, { expiresAt: number; secret: string }>()
  private loadedAt: number | undefined
  private operationTail: Promise<void> = Promise.resolve()

  constructor(
    private readonly file: string,
    private readonly ttlMs: number = DEFAULT_PAIR_TTL_MS,
    private readonly maxDevices: number = DEFAULT_MAX_DEVICES,
  ) {}

  /** Serialize registry reads that may prune or persist shared in-memory state. */
  private async exclusive<T>(operation: () => Promise<T>): Promise<T> {
    const previous = this.operationTail
    let release: (() => void) | undefined
    this.operationTail = new Promise<void>((resolve) => { release = resolve })
    await previous
    try {
      return await operation()
    } finally {
      release?.()
    }
  }

  private async load(): Promise<void> {
    const now = Date.now()
    if (this.loadedAt !== undefined) return
    try {
      const raw = JSON.parse(await readFile(this.file, 'utf8')) as unknown
      if (Array.isArray(raw)) {
        for (const value of raw) {
          const device = this.parseStoredDevice(value)
          if (device !== undefined && device.expiresAt > now) this.loaded.push(device)
        }
      }
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code
      if (code !== 'ENOENT') throw error
    }
    this.loadedAt = now
  }

  private parseStoredDevice(value: unknown): StoredDevice | undefined {
    if (typeof value !== 'object' || value === null) return undefined
    const record = value as Record<string, unknown>
    if (typeof record.deviceId !== 'string'
      || typeof record.tokenHash !== 'string'
      || typeof record.name !== 'string'
      || typeof record.surface !== 'string'
      || typeof record.createdAt !== 'number'
      || typeof record.expiresAt !== 'number'
      || typeof record.lastSeenAt !== 'number'
      || !/^[a-f0-9]{64}$/.test(record.tokenHash)) {
      return undefined
    }
    const surface = record.surface
    if (surface !== 'macos' && surface !== 'iphone' && surface !== 'cli') return undefined
    const device: StoredDevice = {
      deviceId: record.deviceId,
      tokenHash: record.tokenHash,
      name: record.name,
      surface,
      createdAt: record.createdAt,
      expiresAt: record.expiresAt,
      lastSeenAt: record.lastSeenAt,
    }
    if (typeof record.appVersion === 'string') device.appVersion = record.appVersion
    return device
  }

  private async save(): Promise<void> {
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 })
    const tmp = `${this.file}.${randomUUID()}.tmp`
    await writeFile(tmp, JSON.stringify(this.loaded, null, 2) + '\n', { mode: 0o600 })
    await rename(tmp, this.file)
  }

  private toView(device: StoredDevice): NativeDeviceView {
    const { tokenHash: _tokenHash, ...view } = device
    return view
  }

  /** Register one native client and return its one-time secret. */
  private async pairUnlocked(request: PairRequest): Promise<PairResponse> {
    await this.load()
    const now = Date.now()
    this.prune(now)
    if (this.loaded.length >= this.maxDevices) {
      throw new PairingError('device-limit', `at most ${this.maxDevices} native devices may be registered`)
    }
    const token = randomBytes(32).toString('base64url')
    const device: StoredDevice = {
      deviceId: randomUUID(),
      tokenHash: createHash('sha256').update(token).digest('hex'),
      name: request.deviceName,
      surface: request.surface,
      createdAt: now,
      expiresAt: now + this.ttlMs,
      lastSeenAt: now,
    }
    if (request.appVersion !== undefined) device.appVersion = request.appVersion
    this.loaded.push(device)
    await this.save()
    return { deviceId: device.deviceId, token, expiresAt: device.expiresAt, createdAt: device.createdAt }
  }

  async pair(request: PairRequest): Promise<PairResponse> {
    return this.exclusive(() => this.pairUnlocked(request))
  }

  /** Mint one short-lived, single-use code. Only a loopback Host surface calls this. */
  createPairingCode(now: number = Date.now()): PairingCodeResponse {
    this.prunePairingCodes(now)
    // Grouped uppercase base32 avoids ambiguous punctuation and is easy to type.
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    const bytes = randomBytes(16)
    let raw = ''
    for (const byte of bytes) {
      const character = alphabet[byte % alphabet.length]
      if (character === undefined) throw new PairingError('invalid-request', 'pairing alphabet lookup failed')
      raw += character
    }
    const code = raw.match(/.{1,4}/g)?.join('-')
    if (code === undefined) throw new PairingError('invalid-request', 'could not create a pairing code')
    const expiresAt = now + DEFAULT_PAIR_CODE_TTL_MS
    const codeId = this.pairingCodeHash(code)
    this.pairingCodes.set(codeId, { expiresAt, secret: this.normalizePairingCode(code) })
    return { code, codeId, expiresAt, transport: 'tls-code-proof-v2' }
  }

  /** Redeem a Host-minted code exactly once and register the remote device. */
  async redeem(request: PairRequest & { code: string }): Promise<PairResponse> {
    return this.exclusive(async () => {
      const now = Date.now()
      this.prunePairingCodes(now)
      const hash = this.pairingCodeHash(request.code)
      const record = this.pairingCodes.get(hash)
      if (record === undefined || record.expiresAt <= now) {
        throw new PairingError('invalid-code', 'pairing code is invalid or expired')
      }
      // Consume before the first await so two concurrent redemptions can never
      // register two devices with one code. A later capacity/I/O failure still
      // consumes the code, which is the safer one-time-secret behavior.
      this.pairingCodes.delete(hash)
      return this.pairUnlocked(request)
    })
  }

  /**
   * Redeem without sending the out-of-band code over an unauthenticated TLS
   * connection. The client proves knowledge of that high-entropy code and
   * binds the proof to the leaf certificate it is currently talking to.
   */
  async redeemTlsProof(
    request: PairRequest & { codeId: string; clientNonce: string; proof: string },
    certificateFingerprint: string,
  ): Promise<PairResponse> {
    return this.exclusive(async () => {
      const now = Date.now()
      this.prunePairingCodes(now)
      const codeId = request.codeId.toLowerCase()
      const fingerprint = certificateFingerprint.toLowerCase()
      if (!/^[a-f0-9]{64}$/.test(codeId)
        || !/^[a-f0-9]{64}$/.test(fingerprint)
        || !/^[A-Za-z0-9_-]{22,86}$/.test(request.clientNonce)
        || !/^[a-fA-F0-9]{64}$/.test(request.proof)) {
        throw new PairingError('invalid-request', 'invalid authenticated pairing proof')
      }
      const record = this.pairingCodes.get(codeId)
      if (record === undefined || record.expiresAt <= now) {
        throw new PairingError('invalid-code', 'pairing code is invalid or expired')
      }
      const expected = createHmac('sha256', record.secret)
        .update(this.pairingProofMessage(request, fingerprint))
        .digest()
      const supplied = Buffer.from(request.proof, 'hex')
      if (supplied.byteLength !== expected.byteLength || !timingSafeEqual(supplied, expected)) {
        throw new PairingError('invalid-code', 'pairing proof does not match this Host')
      }
      this.pairingCodes.delete(codeId)
      return this.pairUnlocked(request)
    })
  }

  /** Public device rows, newest last. */
  async list(): Promise<NativeDeviceView[]> {
    return this.exclusive(async () => {
      await this.load()
      const now = Date.now()
      this.prune(now)
      return this.loaded.map(device => this.toView(device))
    })
  }

  /** Verify a bearer token and refresh the matching device's last-seen time. */
  async verify(token: string): Promise<NativeDeviceView | undefined> {
    if (token === '') return undefined
    return this.exclusive(async () => {
      await this.load()
      const now = Date.now()
      this.prune(now)
      const hash = Buffer.from(createHash('sha256').update(token).digest('hex'))
      const device = this.loaded.find((candidate) => {
        const stored = Buffer.from(candidate.tokenHash)
        return stored.byteLength === hash.byteLength && timingSafeEqual(stored, hash)
      })
      if (device === undefined) return undefined
      if (device.expiresAt <= now) return undefined
      if (now - device.lastSeenAt >= LAST_SEEN_WRITE_INTERVAL_MS) {
        device.lastSeenAt = now
        await this.save()
      }
      return this.toView(device)
    })
  }

  /** Revoke one device immediately. Unknown ids are idempotent. */
  async revoke(deviceId: string): Promise<boolean> {
    return this.exclusive(async () => {
      await this.load()
      const index = this.loaded.findIndex(device => device.deviceId === deviceId)
      if (index === -1) return false
      this.loaded.splice(index, 1)
      await this.save()
      return true
    })
  }

  private pairingCodeHash(code: string): string {
    return createHash('sha256')
      .update(this.normalizePairingCode(code))
      .digest('hex')
  }

  private normalizePairingCode(code: string): string {
    return code.replace(/[^A-Za-z0-9]/g, '').toUpperCase()
  }

  private pairingProofMessage(
    request: Pick<PairRequest, 'surface' | 'deviceName' | 'appVersion'> & { clientNonce: string },
    certificateFingerprint: string,
  ): string {
    return [
      'openfish-pair-v1',
      certificateFingerprint,
      request.clientNonce,
      request.surface,
      request.deviceName,
      request.appVersion ?? '',
    ].join('\0')
  }

  private prunePairingCodes(now: number): void {
    for (const [hash, record] of this.pairingCodes) {
      if (record.expiresAt <= now) this.pairingCodes.delete(hash)
    }
  }

  private prune(now: number): void {
    const alive = this.loaded.filter(device => device.expiresAt > now)
    if (alive.length !== this.loaded.length) {
      this.loaded.splice(0, this.loaded.length, ...alive)
    }
  }
}

/** Typed pairing failure with a stable wire code. */
export class PairingError extends Error {
  constructor(
    readonly code: 'device-limit' | 'invalid-request' | 'invalid-code',
    message: string,
  ) {
    super(message)
    this.name = 'PairingError'
  }
}

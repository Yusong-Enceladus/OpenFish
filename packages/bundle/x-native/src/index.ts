/**
 * OpenCodex native-bootstrap bridge (protocol v2).
 *
 * The dsh Web profile is the product base. This plugin owns the native-client
 * discovery surface while every business RPC stays on the existing dsh `/api`
 * Typert gateway:
 *
 *   GET  /x-native/v2/health        liveness + versioned handshake
 *   GET  /x-native/v2/capabilities  what this host composition offers
 *   GET  /x-native/v2/methods       live `/api` method manifest for native codegen
 *   POST /x-native/v2/pair          register one native client
 *   GET  /x-native/v2/devices       list registered devices (Host-local)
 *
 * The module uses the loader's `apply` shape (like `dsh-host-frontend-static`)
 * so routes register at load time instead of waiting for a service consumer.
 */

import { homedir } from 'node:os'
import { join } from 'node:path'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { Context, Service } from '@deepseek-ai/cordis'
import type { WebRoute } from '@deepseek-ai/dsh-host-webserver'
import type { ConnectionAuthenticationRequest } from '@deepseek-ai/dsh-client-connection'
import z from '@deepseek-ai/schemastery'
import { PairingError, PairingStore, DEFAULT_MAX_DEVICES, DEFAULT_PAIR_TTL_MS } from './pairing.ts'
import {
  toNativeMethod,
  type NativeCapabilities,
  type NativeDeviceView,
  type NativeHandshake,
  type NativeMethod,
  type PairingCodeResponse,
  type PairRequest,
  type PairResponse,
  type RevokeDeviceRequest,
} from './protocol.ts'

export type {
  NativeCapabilities,
  NativeDeviceView,
  NativeHandshake,
  NativeMethod,
  PairingCodeResponse,
  PairRequest,
  PairResponse,
  RevokeDeviceRequest,
} from './protocol.ts'

declare module '@deepseek-ai/cordis' {
  interface Context {
    xNative: XNative
  }
}

/** Stable Cordis plugin name. */
export const name = 'x-native'

/** Service required before the native routes can be registered. */
export const inject = ['webServer', 'connection']

/** API paths owned by dsh-client-connection; duplicated here as protocol facts. */
const API_BASE = '/api'
const HOST_EVENTS_PATH = `${API_BASE}/events.host`
const MUX_EVENTS_PATH = `${API_BASE}/events.mux`
const NATIVE_ROUTE_PREFIX = '/x-native/v2'

/** Maximum accepted JSON body for `/x-native/v2/pair`. */
const MAX_PAIR_BODY_BYTES = 16 * 1024

/** Configuration for OpenCodex native bootstrap discovery and device pairing. */
export interface XNativeConfig {
  /** Negotiated wire protocol version. */
  protocolVersion: string
  /** Native-device registration lifetime in milliseconds. */
  pairTtlMs?: number
  /** Maximum registered native devices. */
  maxDevices?: number
  /** Registry directory override; schema default '' means `$DSH_HOME/x-native`. */
  dataDir: string
}

export const Config: z<XNativeConfig> = z.object({
  protocolVersion: z.string().required(),
  pairTtlMs: z.natural().min(1).default(DEFAULT_PAIR_TTL_MS),
  maxDevices: z.natural().min(1).default(DEFAULT_MAX_DEVICES),
  dataDir: z.string().default(''),
})

const PairRequestSchema: z<PairRequest> = z.object({
  surface: z.union([z.const('macos'), z.const('iphone'), z.const('cli')]),
  deviceName: z.string().min(1).max(128),
  appVersion: z.string().max(64).default(''),
  code: z.string().max(32),
})

const RevokeDeviceRequestSchema: z<RevokeDeviceRequest> = z.object({
  deviceId: z.string().min(1).max(128),
})

/** Minimal Loader facade used for composition-level capability detection. */
interface LoaderFacade {
  entries(): Iterable<{ options: { name?: string } }>
}

/** Minimal Typert facade used for the live method manifest. */
interface TypertFacade {
  local: { list(): unknown[] }
}

interface ApiProxyFacade {
  sessions?: Record<string, unknown>
  workspace?: Record<string, unknown>
  host?: Record<string, unknown>
  settings?: Record<string, unknown>
  credentials?: Record<string, unknown>
  llm?: Record<string, unknown>
  downloads?: Record<string, unknown>
}

function hasFunctions(value: Record<string, unknown> | undefined, ...names: string[]): boolean {
  return value !== undefined && names.every(name => typeof value[name] === 'function')
}

function sendJson(res: ServerResponse, status: number, body: unknown): void {
  const text = JSON.stringify(body)
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(text),
  })
  res.end(text)
}

function methodNotAllowed(res: ServerResponse, allow: string): void {
  res.writeHead(405, { allow })
  res.end()
}

function readJsonBody(req: IncomingMessage, maxBytes: number): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let size = 0
    const chunks: Buffer[] = []
    req.on('data', (chunk: Buffer) => {
      size += chunk.length
      if (size > maxBytes) {
        reject(new PairingError('invalid-request', `request body exceeds ${maxBytes} bytes`))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      try {
        resolve(chunks.length === 0 ? {} : JSON.parse(Buffer.concat(chunks).toString('utf8')))
      } catch (error) {
        reject(new PairingError('invalid-request', `request body is not valid JSON: ${String(error)}`))
      }
    })
    req.on('error', reject)
  })
}

function requestHeader(
  request: ConnectionAuthenticationRequest,
  name: string,
): string | undefined {
  if (request.headers instanceof Headers) return request.headers.get(name) ?? undefined
  const value: unknown = request.headers[name.toLowerCase()]
  if (typeof value === 'string') return value
  if (!Array.isArray(value)) return undefined
  const first = (value as readonly unknown[])[0]
  return typeof first === 'string' ? first : undefined
}

/** Extract HTTP Authorization or the browser-WebSocket subprotocol carrier. */
function bearerToken(request: ConnectionAuthenticationRequest): string | undefined {
  const authorization = requestHeader(request, 'authorization')
  if (authorization?.startsWith('Bearer ') === true) {
    const token = authorization.slice('Bearer '.length).trim()
    if (token !== '') return token
  }
  const protocols = requestHeader(request, 'sec-websocket-protocol')
  for (const protocol of protocols?.split(',') ?? []) {
    const value = protocol.trim()
    const prefix = 'opencodex.bearer.'
    if (value.startsWith(prefix) && value.length > prefix.length) return value.slice(prefix.length)
  }
  return undefined
}

/** DSH-owned bootstrap service used before a native client joins the ordinary API. */
export class XNative extends Service {
  /** Durable device-pairing registry; it never owns business or session state. */
  readonly pairing: PairingStore

  constructor(ctx: Context, private config: XNativeConfig) {
    super(ctx, 'xNative')
    const configuredDataDir = this.config.dataDir
    const dataDir = configuredDataDir
      ? configuredDataDir
      : (ctx.get('dshHomePath') as ((...segments: string[]) => string) | undefined)?.('x-native')
        ?? join(homedir(), '.dsh', 'x-native')
    this.pairing = new PairingStore(
      join(dataDir, 'devices.json'),
      config.pairTtlMs ?? DEFAULT_PAIR_TTL_MS,
      config.maxDevices ?? DEFAULT_MAX_DEVICES,
    )
    ctx.connection.security.registerAuthenticator(async (request) => {
      const token = bearerToken(request)
      return token !== undefined && await this.pairing.verify(token) !== undefined
    })
    const trusted = (req: IncomingMessage): boolean => ctx.connection.security.isTrusted(req)
    const loopback = (req: IncomingMessage): boolean => ctx.connection.security.isLoopback(req)
    const routes: WebRoute[] = [
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/health`,
        handler: (req, res) => {
          if (req.method !== 'GET') {
            methodNotAllowed(res, 'GET')
            return
          }
          if (!trusted(req)) {
            sendJson(res, 403, { error: { code: 'untrusted-host', message: 'request authority is not trusted' } })
            return
          }
          sendJson(res, 200, { ok: true, ...this.handshake() })
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/capabilities`,
        handler: (req, res) => {
          if (req.method !== 'GET') {
            methodNotAllowed(res, 'GET')
            return
          }
          if (!trusted(req)) {
            sendJson(res, 403, { error: { code: 'untrusted-host', message: 'request authority is not trusted' } })
            return
          }
          sendJson(res, 200, this.capabilities())
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/methods`,
        handler: (req, res) => {
          if (req.method !== 'GET') {
            methodNotAllowed(res, 'GET')
            return
          }
          if (!trusted(req)) {
            sendJson(res, 403, { error: { code: 'untrusted-host', message: 'request authority is not trusted' } })
            return
          }
          sendJson(res, 200, this.methods())
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/pairing-code`,
        handler: (req, res) => {
          if (req.method !== 'POST') {
            methodNotAllowed(res, 'POST')
            return
          }
          if (!loopback(req)) {
            sendJson(res, 403, { error: { code: 'loopback-only', message: 'pairing codes can only be created on the Host' } })
            return
          }
          sendJson(res, 201, this.createPairingCode())
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/pair`,
        handler: async (req, res) => {
          if (req.method !== 'POST') {
            methodNotAllowed(res, 'POST')
            return
          }
          if (!trusted(req)) {
            sendJson(res, 403, { error: { code: 'untrusted-host', message: 'request authority is not trusted' } })
            return
          }
          try {
            const body = await readJsonBody(req, MAX_PAIR_BODY_BYTES)
            const request = PairRequestSchema(body as never)
            const pairRequest: PairRequest = {
              surface: request.surface,
              deviceName: request.deviceName,
              ...(request.appVersion === '' ? {} : { appVersion: request.appVersion }),
              ...(request.code === undefined ? {} : { code: request.code }),
            }
            const result = loopback(req) && pairRequest.code === undefined
              ? await this.pair(pairRequest)
              : pairRequest.code === undefined
                ? (() => { throw new PairingError('invalid-code', 'a pairing code is required') })()
                : await this.redeem(pairRequest as PairRequest & { code: string })
            sendJson(res, 201, result)
          } catch (error) {
            if (error instanceof PairingError) {
              const status = error.code === 'device-limit' ? 409 : error.code === 'invalid-code' ? 401 : 400
              sendJson(res, status, { error: { code: error.code, message: error.message } })
              return
            }
            if (error instanceof z.ValidationError) {
              sendJson(res, 400, { error: { code: 'invalid-request', message: error.message } })
              return
            }
            this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
            sendJson(res, 500, { error: { code: 'internal', message: 'pairing failed' } })
          }
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/devices`,
        handler: async (req, res) => {
          if (req.method !== 'GET') {
            methodNotAllowed(res, 'GET')
            return
          }
          if (!loopback(req)) {
            sendJson(res, 403, { error: { code: 'loopback-only', message: 'device listing is Host-local' } })
            return
          }
          try {
            sendJson(res, 200, await this.devices())
          } catch (error) {
            this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
            sendJson(res, 500, { error: { code: 'internal', message: 'device listing failed' } })
          }
        },
      },
      {
        kind: 'exact',
        path: `${NATIVE_ROUTE_PREFIX}/revoke`,
        handler: async (req, res) => {
          if (req.method !== 'POST') {
            methodNotAllowed(res, 'POST')
            return
          }
          if (!loopback(req)) {
            sendJson(res, 403, { error: { code: 'loopback-only', message: 'device revocation is Host-local' } })
            return
          }
          try {
            const body = await readJsonBody(req, MAX_PAIR_BODY_BYTES)
            const request = RevokeDeviceRequestSchema(body as never)
            sendJson(res, 200, { revoked: await this.revoke(request.deviceId) })
          } catch (error) {
            if (error instanceof z.ValidationError || error instanceof PairingError) {
              sendJson(res, 400, { error: { code: 'invalid-request', message: error.message } })
              return
            }
            this.ctx.logger.warn(error instanceof Error ? error : new Error(String(error)))
            sendJson(res, 500, { error: { code: 'internal', message: 'device revocation failed' } })
          }
        },
      },
    ]
    ctx.effect(() => {
      const disposers = routes.map(route => ctx.webServer.register(route))
      return () => { for (const dispose of disposers) dispose() }
    }, 'x-native: v2 routes')
  }

  /** Current native-bootstrap protocol version. */
  get protocolVersion(): string {
    return this.config.protocolVersion
  }

  /**
   * Return the minimal liveness and protocol-negotiation handshake.
   * @returns Stable OpenCodex product and DSH runtime facts.
   */
  handshake(): NativeHandshake {
    const embeddedRuntimeId = process.env.OPENFISH_EMBEDDED_RUNTIME_ID?.trim()
    return {
      product: 'opencodex',
      protocolVersion: this.protocolVersion,
      minimumClientProtocol: 'v2',
      host: 'dsh',
      surface: 'native',
      ...embeddedRuntimeId === undefined || embeddedRuntimeId === ''
        ? {}
        : { embeddedRuntimeId, embeddedProcessId: process.pid },
    }
  }

  /**
   * Read mounted package names for composition capability detection.
   * @returns A fresh set of mounted Loader package names.
   */
  mountedPackages(): Set<string> {
    const names = new Set<string>()
    const loader = this.ctx.get('loader') as LoaderFacade | undefined
    if (loader === undefined) return names
    for (const entry of loader.entries()) {
      const packageName = entry.options.name
      if (packageName !== undefined) names.add(packageName)
    }
    return names
  }

  /**
   * Describe the live DSH composition and the ordinary API a native client should join.
   * @returns Current bootstrap capability facts.
   */
  capabilities(): NativeCapabilities {
    const mounted = this.mountedPackages()
    const voice = this.ctx.get('voice')
    const voiceCapabilities = voice?.describe()
    const apiProxy = this.ctx.get('apiProxy') as ApiProxyFacade | undefined
    const hasLocalVoice = voiceCapabilities?.providers.some(provider =>
      provider.operations.includes('speech-to-text')
        && provider.operations.includes('text-to-speech')) === true
    return {
      product: 'opencodex',
      protocolVersion: this.protocolVersion,
      host: 'dsh',
      surface: 'native',
      api: {
        base: API_BASE,
        hostEvents: HOST_EVENTS_PATH,
        muxEvents: MUX_EVENTS_PATH,
      },
      features: {
        apiProxy: this.ctx.get('apiProxy') !== undefined,
        typert: this.ctx.get('typert') !== undefined,
        remotePlugin: mounted.has('dsh-remote-plugin'),
        voicePlugin: voice !== undefined || mounted.has('dsh-voice-input'),
        localVoice: hasLocalVoice,
        imageGenerationExtension: mounted.has('@deepseek-ai/dsh-extension-image-generation'),
      },
      contracts: {
        sessions: hasFunctions(apiProxy?.sessions, 'create', 'history', 'prompt', 'cancel'),
        workspaces: hasFunctions(apiProxy?.workspace, 'list', 'create', 'archiveSession'),
        interactions: this.ctx.get('approval') !== undefined && this.ctx.get('userQuestions') !== undefined,
        settings: hasFunctions(apiProxy?.settings, 'describe', 'update')
          && hasFunctions(apiProxy?.credentials, 'describe'),
        providers: hasFunctions(apiProxy?.llm, 'providers', 'models')
          && hasFunctions(apiProxy?.sessions, 'selectModel'),
        migration: hasFunctions(apiProxy?.sessions, 'import') && apiProxy?.downloads !== undefined,
        sandbox: hasFunctions(apiProxy?.host, 'runSandboxed'),
      },
      ...(voiceCapabilities === undefined ? {} : { voice: voiceCapabilities }),
      pairing: {
        supported: true,
        kind: 'one-time-code',
        durable: true,
      },
      transports: {
        lan: this.ctx.webServer.host === '0.0.0.0',
        tailscale: this.ctx.webServer.host === '0.0.0.0',
        relay: mounted.has('dsh-remote-plugin'),
      },
      surfaces: ['macos', 'iphone', 'cli', 'web'],
    }
  }

  /**
   * Read the live `/api` method manifest without taking ownership of those methods.
   * @returns Methods sorted by endpoint, or an empty list when Typert is absent.
   */
  methods(): NativeMethod[] {
    const typert = this.ctx.get('typert') as TypertFacade | undefined
    if (typert === undefined) return []
    return typert.local.list()
      .map(descriptor => toNativeMethod(descriptor))
      .filter((method): method is NativeMethod => method !== undefined)
      .sort((left, right) => left.endpoint.localeCompare(right.endpoint))
  }

  /**
   * Register one native device through the DSH pairing store.
   * @param request - Validated device identity supplied by the loopback route.
   * @returns The durable device identity and its one-time bearer token.
   */
  pair(request: PairRequest): Promise<PairResponse> {
    return this.pairing.pair(request)
  }

  /**
   * Mint one short-lived Host-local code for an iPhone or remote Mac.
   * @returns A single-use code and its expiry time.
   */
  createPairingCode(): PairingCodeResponse {
    return this.pairing.createPairingCode()
  }

  /**
   * Redeem a one-time code and create a durable device token.
   * @param request - Device identity and the Host-minted single-use code.
   * @returns The registered device identity and its one-time bearer token.
   */
  redeem(request: PairRequest & { code: string }): Promise<PairResponse> {
    return this.pairing.redeem(request)
  }

  /**
   * List non-secret views of registered native devices.
   * @returns Current, non-expired device registrations.
   */
  devices(): Promise<NativeDeviceView[]> {
    return this.pairing.list()
  }

  /**
   * Revoke one durable device registration and its bearer token.
   * @param deviceId - Stable identifier of the device to revoke.
   * @returns Whether a current registration was removed.
   */
  revoke(deviceId: string): Promise<boolean> {
    return this.pairing.revoke(deviceId)
  }
}

export function apply(ctx: Context, config: XNativeConfig): void {
  new XNative(ctx, config)
}

export default apply

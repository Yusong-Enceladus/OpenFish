/**
 * OpenCodex native bootstrap protocol v2 wire types.
 *
 * These types are the contract macOS/iPhone clients compile against.
 * The business RPC methods themselves stay on the existing dsh `/api` Typert
 * gateway; this surface owns discovery, capability negotiation, the method
 * manifest, and native-device identity — the parts a native client needs
 * before it can speak `/api`.
 */

import type { VoiceCapabilities } from '@deepseek-ai/dsh-voice'

/** Liveness and protocol-negotiation facts returned by the bootstrap health route. */
export interface NativeHandshake {
  /** Product composition served by this host. */
  product: 'opencodex'
  /** Native bootstrap protocol version. */
  protocolVersion: string
  /** Oldest native bootstrap protocol accepted by this Host. */
  minimumClientProtocol: string
  /** Authoritative runtime implementation. */
  host: 'dsh'
  /** Presentation family joining that runtime. */
  surface: 'native'
  /** Actual address of the plaintext carrier; present on loopback health. */
  plainHost?: '127.0.0.1' | '0.0.0.0'
  /** Actual TLS-only remote port, absent when the Host is safely local-only. */
  secureRemotePort?: number
  /** Identity of the packaged Host closure, present only for an embedded Open Fish Host. */
  embeddedRuntimeId?: string
  /** Process owning the embedded Host, used by the native launcher to retire a stale build. */
  embeddedProcessId?: number
}

/** One method exposed by the live Typert gateway (`/api`). */
export interface NativeMethod {
  /** `<namespace>/<method>` wire endpoint used by `/api`. */
  endpoint: string
  /** Cordis service key owning the method. */
  service: string
  /** Wire namespace. */
  namespace: string
  /** Public method name. */
  method: string
  /** Implementation member name when the wire method is an alias. */
  implementation?: string
  /** Ordered wire parameter names. */
  parameters: string[]
  /** `signal` when the transport injects cancellation. */
  cancellation?: string
  /** Context projection replacing one lookup parameter, when present. */
  scope?: { context: string; wire: string }
}

/** Static surface facts reported by `/x-native/v2/capabilities`. */
export interface NativeCapabilities {
  product: 'opencodex'
  protocolVersion: string
  host: 'dsh'
  surface: 'native'
  /** The existing unified API transport a native client should use. */
  api: {
    base: string
    hostEvents: string
    muxEvents: string
  }
  /** Capability facts derived from the live composition. */
  features: {
    apiProxy: boolean
    typert: boolean
    remotePlugin: boolean
    voicePlugin: boolean
    /** A composed device-local STT/TTS Provider is available. */
    localVoice: boolean
    /** Provider registry only; OpenCodex does not bundle an image model. */
    imageGenerationExtension: boolean
  }
  /** Core DSH business contracts discovered from the live service graph. */
  contracts: {
    sessions: boolean
    workspaces: boolean
    interactions: boolean
    settings: boolean
    providers: boolean
    migration: boolean
    sandbox: boolean
  }
  /** DSH-owned provider vocabulary consumed by platform adapters. */
  voice?: VoiceCapabilities
  /** Native-device identity registration. */
  pairing: {
    supported: boolean
    kind: 'authenticated-tls-code'
    /** Whether pairing records survive a host restart. */
    durable: boolean
  }
  /** Reachability modes carried by the same authenticated DSH transport. */
  transports: {
    lan: boolean
    tailscale: boolean
    relay: boolean
  }
  /** Client surfaces this protocol release targets. */
  surfaces: ['macos', 'iphone', 'cli', 'web']
}

/** Registration request accepted by `POST /x-native/v2/pair`. */
export interface PairRequest {
  /** Client surface key. */
  surface: 'macos' | 'iphone' | 'cli'
  /** Human-readable device name shown in the host device list. */
  deviceName: string
  /** Optional client-reported app version. */
  appVersion?: string
  /** One-time code required when redeeming from a non-loopback device. */
  code?: string
  /** SHA-256 id derived from the out-of-band pairing code. */
  codeId?: string
  /** Fresh client nonce used by the authenticated TLS bootstrap. */
  clientNonce?: string
  /** HMAC proof keyed by the out-of-band code and bound to the Host TLS certificate. */
  proof?: string
}

/** Short-lived code created on the Host and typed into a remote client. */
export interface PairingCodeResponse {
  code: string
  codeId: string
  expiresAt: number
  transport: 'tls-code-proof-v2'
  hostURL?: string
}

/** Registration response returned by `POST /x-native/v2/pair`. */
export interface PairResponse {
  /** Stable device id. */
  deviceId: string
  /** Secret bearer token; returned once at pairing time. */
  token: string
  /** Epoch milliseconds when the registration record expires. */
  expiresAt: number
  /** Creation epoch milliseconds. */
  createdAt: number
}

/** Public row of one registered native device (token never returned). */
export interface NativeDeviceView {
  deviceId: string
  name: string
  surface: PairRequest['surface']
  appVersion?: string
  createdAt: number
  expiresAt: number
  lastSeenAt: number
}

/** Explicit device-token revocation request. */
export interface RevokeDeviceRequest {
  deviceId: string
}

/**
 * Extract the public method shape from a Typert invocation descriptor without
 * importing the typert packages (the x-native bundle stays dependency-light).
 */
export function toNativeMethod(value: unknown): NativeMethod | undefined {
  if (typeof value !== 'object' || value === null) return undefined
  const record = value as Record<string, unknown>
  const namespace = record.namespace
  const method = record.method
  const service = record.service
  if (typeof namespace !== 'string' || typeof method !== 'string' || typeof service !== 'string') {
    return undefined
  }
  const parameters = Array.isArray(record.parameters)
    ? record.parameters
      .map((parameter: unknown): string | undefined => {
        if (typeof parameter !== 'object' || parameter === null) return undefined
        const wire = (parameter as Record<string, unknown>).wire
        return typeof wire === 'string' ? wire : undefined
      })
      .filter((wire: string | undefined): wire is string => wire !== undefined)
    : []
  const result: NativeMethod = { endpoint: `${namespace}/${method}`, service, namespace, method, parameters }
  const implementation = record.implementation
  if (typeof implementation === 'string') result.implementation = implementation
  const cancellation = record.cancellation
  if (typeof cancellation === 'object' && cancellation !== null) {
    const parameter = (cancellation as Record<string, unknown>).parameter
    if (parameter === 'signal') result.cancellation = 'signal'
  }
  const scope = record.scope
  if (typeof scope === 'object' && scope !== null) {
    const context = (scope as Record<string, unknown>).context
    const wire = (scope as Record<string, unknown>).wire
    if (typeof context === 'string' && typeof wire === 'string') {
      result.scope = { context, wire }
    }
  }
  return result
}

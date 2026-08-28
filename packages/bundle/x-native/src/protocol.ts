/**
 * OpenCodex native bootstrap protocol v2 wire types.
 *
 * These types are the contract macOS/iPhone clients compile against.
 * The business RPC methods themselves stay on the existing dsh `/api` Typert
 * gateway; this surface owns discovery, capability negotiation, the method
 * manifest, and native-device identity — the parts a native client needs
 * before it can speak `/api`.
 */

import type { JsonValue } from '@deepseek-ai/dsh-session/types'
import type {
  SessionControlFrame,
  SessionEventEntry,
  SessionFollowFrame,
  SessionProjectionBaseline,
  SessionWireEvent,
} from '@deepseek-ai/dsh-api-session-controller'
import type { WorkspaceFollowFrame } from '@deepseek-ai/dsh-api-workspace-controller'

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
  /** Invocation carrier selected by the live Typert descriptor. */
  mode?: 'unary' | 'stream'
}

/** Session optionally joined to one native reconnect generation. */
export interface NativeFollowRequest {
  readonly sessionId?: string
  /** Durable parent proof when following a subagent child. */
  readonly parentSessionId?: string
  /** Provider lifecycle recorded for an addressed subagent child. */
  readonly mode?: 'one-shot' | 'continuable'
  readonly maxMessages?: number
}

type SessionFollowSnapshot = Extract<SessionFollowFrame, { readonly type: 'snapshot' }>

/**
 * Session follow form consumed by native transcript renderers. Storage-only
 * chunk rows are expanded at the Host boundary so every native surface sees
 * the same durable event vocabulary as unary history.
 */
export type NativeSessionFollowFrame =
  | {
    readonly type: 'snapshot'
    readonly header: SessionFollowSnapshot['header']
    readonly cursor: number
    readonly events: readonly SessionEventEntry[]
    readonly hasMore: boolean
    readonly projections: SessionProjectionBaseline
  }
  | SessionEventEntry

/**
 * Forwarded Host event after the Gateway has enforced lossless JSON. Native
 * clients never receive the Gateway's internal `unknown` implementation type.
 */
export type NativeRemoteEventFrame =
  | {
    readonly type: 'ready'
    readonly clientId: string
    readonly host: { readonly home: string }
  }
  | { readonly type: 'emit'; readonly event: string; readonly args: readonly JsonValue[] }
  | {
    readonly type: 'waterfall'
    readonly event: string
    readonly eventId: string
    readonly agentId: string
    readonly request: Readonly<Record<string, JsonValue>>
  }
  | { readonly type: 'cancel'; readonly eventId: string }

/**
 * One capability-neutral native feed item. The channel identifies the owning
 * Host contract; its value remains that contract's canonical wire shape.
 */
export type NativeFollowFrame =
  | { readonly channel: 'remote-events'; readonly value: NativeRemoteEventFrame }
  | { readonly channel: 'workspace'; readonly value: WorkspaceFollowFrame }
  | { readonly channel: 'control'; readonly value: SessionControlFrame }
  | { readonly channel: 'session'; readonly sessionId: string; readonly value: NativeSessionFollowFrame }

/** Backward-history request used by both native surfaces. */
export interface NativeHistoryRequest {
  readonly sessionId: string
  /** Durable parent proof when `sessionId` names a subagent child. */
  readonly parentSessionId?: string
  /** Provider lifecycle recorded for an addressed subagent child. */
  readonly mode?: 'one-shot' | 'continuable'
  readonly beforeSeq?: number
  readonly maxMessages?: number
}

/** Raw-event history projection consumed by the native transcript renderer. */
export interface NativeHistoryValue {
  readonly events: readonly {
    readonly event: SessionWireEvent
  }[]
  readonly hasMore: boolean
  readonly projections?: SessionProjectionBaseline
}

/** Privacy-minimized Host facts used by the native diagnostics surface. */
export interface NativeHostDescription {
  readonly version: string
  /** Intentionally empty: paired clients never receive the Host launch directory. */
  readonly cwd: ''
  readonly provider?: string
  readonly model?: string
  readonly attachedSessions: number
  readonly canOpenPath: boolean
}

/** Archive encodings accepted by the native migration boundary. */
export type NativeImportFormat = 'auto' | 'dsh-jsonl' | 'dsh-zip' | 'codex-jsonl' | 'codex-zip'

/** One in-memory import attachment. Bytes are base64 so every native surface shares one wire shape. */
export interface NativeImportFile {
  readonly name: string
  readonly data: string
}

/** Bounded transcript import request. Imported tasks use the chosen Workspace or first-class No Project storage. */
export interface NativeImportRequest {
  readonly workspaceId?: string
  readonly format: NativeImportFormat
  readonly files: readonly NativeImportFile[]
}

/** One newly-created replayable task and its source identity. */
export interface NativeImportItem {
  readonly sessionId: string
  readonly sourceSessionId?: string
  readonly source: 'codex' | 'dsh'
  readonly root: boolean
}

/** Complete import result after every source was parsed before the first task mutation. */
export interface NativeImportValue {
  readonly items: readonly NativeImportItem[]
}

/** Audio operation implemented by a device-local native voice Provider. */
export type NativeVoiceOperation = 'speech-to-text' | 'text-to-speech'

/** Presentation platform on which a native voice Provider can execute. */
export type NativeVoicePlatform = 'macos' | 'iphone' | 'web'

/** JSON-only device-local voice Provider facts sent during native bootstrap. */
export interface NativeVoiceProviderDescriptor {
  /** Stable implementation identity understood by the platform adapter. */
  readonly id: string
  /** User-facing provider name. */
  readonly name: string
  /** Presentation platforms that can execute this Provider. */
  readonly platforms: readonly NativeVoicePlatform[]
  /** Audio operations implemented by this Provider. */
  readonly operations: readonly NativeVoiceOperation[]
  /** Audio never leaves the presentation device. */
  readonly locality: 'device'
  /** Partial STT or progressive TTS is supported. */
  readonly streaming: boolean
  /** Playback or listening may be interrupted without restarting DSH. */
  readonly interruptible: boolean
  /** Provider quality tier used by the native selection UI. */
  readonly quality: 'standard' | 'enhanced' | 'premium'
}

/** Portable voice contract projected into the self-contained native protocol. */
export interface NativeVoiceCapabilities {
  /** Versioned voice capability contract. */
  readonly contract: 'dsh.voice.v1'
  /** Completed transcripts enter the ordinary session prompt boundary. */
  readonly transcriptAuthority: 'session.prompt'
  /** Device-local Providers currently available to native clients. */
  readonly providers: readonly NativeVoiceProviderDescriptor[]
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
    /** Gateway WebSocket carrying every logical Remote stream. */
    remoteMux: string
    /** Logical Gateway stream carrying forwarded Host events and interactions. */
    remoteEvents: '$events'
    /** Logical stream merging canonical contracts for native clients. */
    nativeFeed: 'xNative/follow'
    /** Deprecated v1 paths retained as absent protocol facts for old decoders. */
    hostEvents?: string
    muxEvents?: string
  }
  /** Capability facts derived from the live composition. */
  features: {
    apiProxy: boolean
    gateway: boolean
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
  voice?: NativeVoiceCapabilities
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
  /** Stable TLS Host address clients should persist instead of a transient LAN IP. */
  hostURL?: string
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
/**
 * Normalize one Typert method descriptor into the bounded native wire form.
 * @param value - Untrusted descriptor projected by the live Typert catalog.
 * @returns The admitted native method, or `undefined` for an invalid descriptor.
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
  const mode = record.mode
  if (mode === 'stream') result.mode = 'stream'
  else result.mode = 'unary'
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

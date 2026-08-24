/** Public Harness Pack, driver, and catalog types. @module */

import type { Agent } from '@deepseek-ai/dsh-agent'
import type { Branded } from '@deepseek-ai/dsh-brand'
import type { SessionEvent, SessionId } from '@deepseek-ai/dsh-session'

/** Stable registry identity of one Harness Pack. */
export type HarnessId = Branded<'HarnessId'>

/** Provenance for one architecture fact exposed by a Harness Pack. */
export interface HarnessGraphEvidence {
  kind: 'declared' | 'source-derived' | 'runtime-observed'
  source: string
  version?: string
}

/** Stable, content-free runtime facts a Driver may bind to declared graph nodes. */
export type HarnessBuiltinRuntimeSignal =
  | 'protocol.ready'
  | 'session.ready'
  | 'turn.started'
  | 'turn.completed'
  | 'turn.failed'
  | 'model.completed'
  | 'tool.activity'
  | 'output.activity'
  | 'approval.requested'
  | 'approval.resolved'

/**
 * A Driver may expose additional content-free facts without waiting for a new
 * Host release. The Pack parser requires the `driver.<protocol>.` namespace,
 * so one Driver cannot light another protocol's architecture by accident.
 */
export type HarnessRuntimeSignal = HarnessBuiltinRuntimeSignal | `driver.${string}`

/** Typed architecture port used by the Manifest Editor and Driver validation. */
export interface HarnessGraphPort {
  id: string
  name: string
  direction: 'input' | 'output'
  dataType: string
  required?: boolean
}

/** One value accepted by a select configuration field. */
export interface HarnessConfigChoice {
  id: string
  name: string
  description?: string
}

/** Driver-owned binding from a generic native control to executable behavior. */
export interface HarnessConfigBinding {
  kind: string
  target: string
}

/** Schema-driven configuration field rendered without Harness-specific native code. */
export interface HarnessConfigField {
  id: string
  name: string
  description?: string
  /** `secret-reference` stores only a Host credential reference such as `OPENAI_API_KEY`, never its value. */
  type: 'string' | 'boolean' | 'select' | 'secret-reference'
  required: boolean
  choices?: HarnessConfigChoice[]
  binding: HarnessConfigBinding
}

/** Versioned executable configuration contract for one editable node. */
export interface HarnessNodeConfigSchema {
  version: 1
  fields: HarnessConfigField[]
}

/** Presentation-only canvas coordinate. Drivers must never interpret it as executable configuration. */
export interface HarnessGraphPosition {
  x: number
  y: number
}

/** One node exposed by a Harness Pack for read-only or editable visualization. */
export interface HarnessGraphNode {
  id: string
  kind: string
  title: string
  editable: boolean
  /** Human-readable ownership statement shown before implementation detail. */
  responsibility?: string
  /** Logical values or capabilities accepted by this component. */
  inputs?: string[]
  /** Logical values, events, or effects produced by this component. */
  outputs?: string[]
  /** Typed ports refine the human-readable input/output summary when the Pack has evidence. */
  ports?: HarnessGraphPort[]
  /** Evidence supporting this component without claiming private internals. */
  evidence?: HarnessGraphEvidence[]
  /** Runtime facts that may truthfully activate this node; absence means no live activation claim. */
  observes?: HarnessRuntimeSignal[]
  /** Optional author-supplied canvas placement, kept separate from Driver-owned `config`. */
  position?: HarnessGraphPosition
  /** Driver-validated controls whose values live in `config` under the field id. */
  configSchema?: HarnessNodeConfigSchema
  config?: Record<string, unknown>
}

/** Directed data-flow connection between two declared Harness nodes. */
export interface HarnessGraphEdge {
  from: string
  to: string
  fromPort?: string
  toPort?: string
  /** Plain-language value or control flow carried by this connection. */
  label?: string
  /** Runtime facts that may truthfully activate this data-flow connection. */
  observes?: HarnessRuntimeSignal[]
}

/** Truthfulness level of a Pack's graph description. */
export type HarnessGraphLevel = 'opaque' | 'observable' | 'composable'

/** Graph descriptor published by a Harness Pack. */
export interface HarnessGraph {
  level: HarnessGraphLevel
  /** Version of the architecture-description contract, independent from Pack v0. */
  manifestVersion?: 1
  /** Label for the process or subsystem boundary represented by this graph. */
  boundary?: string
  /** Evidence that applies to the complete graph. */
  evidence?: HarnessGraphEvidence[]
  nodes: HarnessGraphNode[]
  edges: HarnessGraphEdge[]
}

/** An npm-distributed ACP executable launched through Open Fish's bundled Node runtime. */
export interface NpxHarnessDistribution {
  kind: 'npx'
  package: string
  args: string[]
  env: Record<string, string>
}

/** A Bun-distributed ACP executable launched through Open Fish's bundled Bun runtime. */
export interface BunxHarnessDistribution {
  kind: 'bunx'
  package: string
  args: string[]
  env: Record<string, string>
}

/** A Python package executed through Open Fish's bundled uv runtime. */
export interface UvxHarnessDistribution {
  kind: 'uvx'
  package: string
  args: string[]
  env: Record<string, string>
}

/** A platform-selected archive from the ACP Registry. */
export interface BinaryHarnessDistribution {
  kind: 'binary'
  archive: string
  sha256?: string
  command: string
  args: string[]
  env: Record<string, string>
}

/** A locally configured executable. It is never inferred from an unverified repository. */
export interface ExecutableHarnessDistribution {
  kind: 'executable'
  command: string
  args: string[]
  env: Record<string, string>
}

/** Launch distributions admitted by Harness Pack v0. */
export type HarnessDistribution = NpxHarnessDistribution | BunxHarnessDistribution | UvxHarnessDistribution
  | BinaryHarnessDistribution | ExecutableHarnessDistribution

/**
 * Exact install recipe for a protocol Driver that is not bundled with
 * OpenFish. This is code, not metadata-only Pack state, so native clients must
 * obtain an explicit code-execution confirmation before materializing it.
 */
export interface HarnessDriverBundleRequirement {
  apiVersion: 1
  /** Package identity that must match the installed package.json. */
  package: string
  /** Exact npm version or exact GitHub commit accepted by the Driver manager. */
  spec: string
  /** Lifecycle scripts remain disabled unless the Pack declares and the user confirms this requirement. */
  requiresInstallScripts: boolean
}

/** One credential/configuration input required by an authentication method. */
export interface HarnessAuthField {
  /** Stable credential-store reference. Secret values never appear in Pack state or API responses. */
  ref: string
  name: string
  /** Environment variable populated only for the selected Harness subprocess. */
  env?: string
  required: boolean
  secret: boolean
  placeholder?: string
}

/** Client-safe explanation of the account and billing boundary used by a Harness. */
export interface HarnessAccountDescriptor {
  label: string
  billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
  detail: string
}

/** Pack-declared ownership of model configuration before a session is created. */
export interface HarnessModelConfiguration {
  owner: 'host' | 'harness'
  required: boolean
  detail: string
}

/** Harness Pack v0: identity, launch, protocol, capabilities, and honest graph metadata. */
export interface HarnessPack {
  schemaVersion: 0
  id: HarnessId
  name: string
  version: string
  description?: string
  publisher: string
  license?: string
  repository?: string
  icon?: string
  verified: boolean
  protocol: string
  /** Fallback account boundary when authentication is not selected or not required. */
  account?: HarnessAccountDescriptor
  /** Where a user must configure models; native clients must not infer this from the Harness id. */
  modelConfiguration?: HarnessModelConfiguration
  /** Non-secret sign-in choices the shell may present before first launch. */
  authMethods?: HarnessAuthMethod[]
  /** Self-install recipe for a non-bundled protocol Driver. */
  driverBundle?: HarnessDriverBundleRequirement
  distribution?: HarnessDistribution
  graph: HarnessGraph
  source: 'builtin' | 'acp-registry' | 'openfish-community' | 'user'
}

/** Stable feature identifiers negotiated between Open Fish and a Harness driver. */
export type HarnessCapabilityId =
  | 'lifecycle.install' | 'lifecycle.update' | 'lifecycle.rollback' | 'lifecycle.uninstall'
  | 'session.create' | 'session.resume' | 'session.cancel'
  | 'session.fork' | 'session.archive'
  | 'workspace.project' | 'workspace.no-project'
  | 'configuration.models' | 'configuration.reasoning' | 'configuration.auth' | 'configuration.agent-presets'
  | 'interaction.tools' | 'interaction.approvals' | 'interaction.questions' | 'interaction.files' | 'interaction.events'
  | 'architecture.manifest' | 'architecture.runtime-observation' | 'architecture.edit'
  | 'diagnostics.preflight' | 'builder.manifest' | 'builder.test' | 'builder.publish'

/** Truthful support state. Runtime means support is discovered after launch, not assumed. */
export interface HarnessCapability {
  id: HarnessCapabilityId
  status: 'supported' | 'runtime' | 'unsupported'
  /** Owner of this fact: OpenFish shell, Pack declaration, protocol Driver, or live runtime. */
  source: 'host' | 'pack' | 'driver' | 'runtime'
  detail?: string
}

/** Detached catalog row safe for native and web clients. */
export interface HarnessCatalogEntry extends HarnessPack {
  isDefault: boolean
  available: boolean
  unavailableReason?: string
  installation: HarnessInstallation
  auth: HarnessAuthentication
  compatibility: HarnessCompatibility
  /** Reviewable registry lifecycle; absent for built-in and third-party catalogs. */
  publication?: HarnessPublication
  /** Negotiated capabilities drive native UI visibility and admission diagnostics. */
  capabilities: HarnessCapability[]
  driver: {
    apiVersion: 1
    protocol: string
    loaded: boolean
    authorization: 'not-required' | 'required' | 'authorized'
  }
}

/** Explicit publication state. Catalog deletion alone never masquerades as revocation. */
export interface HarnessPublication {
  status: 'local-draft' | 'update-draft' | 'submitted' | 'published' | 'revocation-requested' | 'revoked'
  review: 'not-submitted' | 'pending' | 'changes-requested' | 'closed' | 'merged' | 'revoked'
  publishedVersion?: string
  knownVersions: string[]
  catalogUrl?: string
  detail: string
  revokedVersion?: string
  revokedReason?: string
  revokedAt?: string
  reviewUrl?: string
}

/** Credential-free local record of a real community review submission. */
export interface HarnessCommunitySubmissionRecord {
  id: HarnessId
  version: string
  reviewUrl: string
  branch: string
  submittedAt: string
  review: 'pending' | 'changes-requested' | 'closed' | 'merged'
}

/** User-controlled lifecycle state for one Harness installation. */
export interface HarnessInstallation {
  status: 'builtin' | 'not-installed' | 'installing' | 'installed' | 'failed'
  installedVersion?: string
  availableVersion: string
  previousVersions: string[]
  /** Truthful supply-chain state; exact-version pins are not mislabeled as checksum verification. */
  integrity: {
    status: 'trusted-runtime' | 'checksum-declared' | 'checksum-verified' | 'version-pinned' | 'local-executable' | 'unverified'
    source: string
    digest?: string
    detail: string
  }
  error?: string
}

/** Non-secret authentication preference; credentials remain owned by the Harness. */
export interface HarnessAuthentication {
  methods: HarnessAuthMethod[]
  selectedMethod?: string
  status: 'not-required' | 'needs-selection' | 'needs-credentials' | 'configured'
  missingFields: string[]
}

/** Open Fish's own local compatibility evidence; independent from Registry curation. */
export interface HarnessCompatibility {
  status: 'untested' | 'ready' | 'compatible' | 'failed'
  /** User-facing compatibility conclusion, separate from lifecycle/test progress. */
  classification: 'supported' | 'experimental' | 'opaque-but-runnable' | 'incompatible'
  checkedAt?: string
  message?: string
}

/** Authentication choice advertised or curated for a Harness. */
export interface HarnessAuthMethod {
  id: string
  name: string
  kind: 'agent' | 'environment' | 'terminal'
  fields: HarnessAuthField[]
  /** Client-safe explanation of whose account pays for work started with this method. */
  account?: HarnessAccountDescriptor
  /** Generic ACP authenticate metadata mapping; values are resolved from the credential store at launch. */
  agent?: { metaKey: string; fieldMap: Record<string, string> }
  /** ACP terminal-auth launch additions. They are data, never a shell fragment. */
  terminal?: { args: string[]; env: Record<string, string> }
}

/** Request to create a session through one selected Harness. */
export interface HarnessSessionRequest {
  harnessId: HarnessId
  sessionId: SessionId
  cwd: string
  /** Exact Pack version recorded by an existing session. */
  version?: string
  /** Exact managed package snapshot selected by Open Fish for this session. */
  installationDirectory?: string
  /** Private Open Fish-owned home/cache/state root for this Harness. */
  runtimeDirectory?: string
  authMethod?: string
  /** Durable location contract chosen by the shell for this task. */
  workspaceMode?: 'project' | 'no-project' | 'custom-cwd'
  /** Exact negotiated capability snapshot committed with a newly-created task. */
  capabilities?: HarnessCapability[]
}

/** Exact local boundary and child identity supplied to a Driver-owned remote fork. */
export interface HarnessForkRequest extends HarnessSessionRequest {
  /** Live source task whose remote Harness session must be branched. */
  sourceSessionId: SessionId
  /** Completed local event prefix the child must inherit verbatim. */
  seed: SessionEvent[]
}

/** Content-free evidence returned by a Driver's non-prompting runtime preflight. */
export interface HarnessPreflightResult {
  /** User-facing statement of what the live probe actually proved. */
  message: string
  /** Number of live models advertised after protocol initialization, when discoverable. */
  modelCount?: number
  /** Stable live configuration ids advertised by the Harness; values remain private to the runtime. */
  configurationIds?: string[]
}

/** One content-free architecture fact mapped from a normalized session event. */
export interface HarnessRuntimeObservation {
  signal: HarnessRuntimeSignal
  status: 'active' | 'waiting' | 'completed' | 'failed'
}

/** One protocol implementation registered on the Harness service. */
export interface HarnessDriver {
  /** Versioned Open Fish driver contract. Unknown versions are rejected at registration. */
  readonly apiVersion: number
  readonly protocol: string
  /** Declare only what this driver can expose for the concrete Pack. */
  capabilities(pack: HarnessPack): Promise<HarnessCapability[]>
  /** Validate every executable node setting this Driver claims to interpret. */
  validatePack?(pack: HarnessPack): Promise<string[]>
  /**
   * Map a normalized local session event to Driver-specific, content-free
   * graph facts. OpenFish validates the protocol namespace and derives the
   * displayed activity label from `signal`; event content is never projected.
   */
  runtimeSignals?(event: SessionEvent, pack: HarnessPack): readonly HarnessRuntimeObservation[]
  available(pack: HarnessPack): Promise<string | undefined>
  /** Initialize the installed protocol without sending a model prompt, validate Pack defaults, then tear it down. */
  preflight?(
    request: HarnessSessionRequest,
    pack: HarnessPack,
    signal?: AbortSignal,
  ): Promise<HarnessPreflightResult>
  create(request: HarnessSessionRequest, pack: HarnessPack, signal?: AbortSignal): Promise<Agent>
  resume(request: HarnessSessionRequest, pack: HarnessPack, signal?: AbortSignal): Promise<Agent>
  /**
   * Create a real remote branch and publish the local child over `seed`.
   * Absence means this protocol cannot preserve its own Harness context when
   * OpenFish forks a task; the shell must hide or disable that action.
   */
  fork?(request: HarnessForkRequest, pack: HarnessPack): Promise<Agent>
  /**
   * Stop and detach the exact live session previously returned by this Driver.
   * Drivers own their process/session handles, so this lifecycle primitive is
   * mandatory: a shell must be able to abandon a blank draft or close a task
   * without leaking a Harness process.
   */
  dispose(sessionId: SessionId, pack: HarnessPack): Promise<void>
  /**
   * Permanently abandon a never-started local draft and remove any remote
   * identity that was allocated while discovering its live configuration.
   *
   * This is deliberately separate from `dispose`: closing OpenFish must keep
   * a durable blank task resumable, while an explicit draft discard must not
   * leave an empty provider-side thread behind. Drivers without a remote
   * deletion primitive may omit it; the Host then falls back to process-only
   * disposal and keeps the local lifecycle truthful.
   */
  discard?(sessionId: SessionId, pack: HarnessPack): Promise<void>
  install?(pack: HarnessPack, directory: string, runtimeDirectory: string, signal?: AbortSignal): Promise<void>
  /** Return missing credential refs without exposing their values. */
  missingCredentials?(
    pack: HarnessPack,
    authMethod?: string,
    locations?: { installationDirectory: string; runtimeDirectory: string },
  ): Promise<string[]>
  /** Discover the exact authentication contract advertised by an installed Harness. */
  discoverAuth?(pack: HarnessPack, installationDirectory: string, runtimeDirectory: string): Promise<HarnessAuthMethod[]>
  /** Launch a Pack-declared interactive login without exposing a command to clients. */
  authenticateInteractive?(
    pack: HarnessPack,
    installationDirectory: string,
    runtimeDirectory: string,
    method: HarnessAuthMethod,
    signal?: AbortSignal,
  ): Promise<void>
}

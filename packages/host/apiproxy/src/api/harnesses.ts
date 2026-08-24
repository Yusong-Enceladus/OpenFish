import type { RpcRequest, RpcResponse } from './rpc.ts'

/** Truthfulness level of a Harness Pack graph. */
export type HarnessGraphLevel = 'opaque' | 'observable' | 'composable'

/** Content-free live facts that a Pack may bind to graph nodes. */
export type HarnessRuntimeSignal =
  | 'protocol.ready' | 'session.ready'
  | 'turn.started' | 'turn.completed' | 'turn.failed'
  | 'model.completed' | 'tool.activity' | 'output.activity'
  | 'approval.requested' | 'approval.resolved'
  | `driver.${string}`

/** Provenance for a graph or component fact shown by native clients. */
export interface HarnessGraphEvidence {
  kind: 'declared' | 'source-derived' | 'runtime-observed'
  source: string
  version?: string
}

/** One graph node exposed by a Harness Pack. */
export interface HarnessGraphNode {
  id: string
  kind: string
  title: string
  editable: boolean
  responsibility?: string
  inputs?: string[]
  outputs?: string[]
  ports?: Array<{
    id: string
    name: string
    direction: 'input' | 'output'
    dataType: string
    required?: boolean
  }>
  evidence?: HarnessGraphEvidence[]
  observes?: HarnessRuntimeSignal[]
  /** Presentation-only canvas placement; never consumed by the Harness Driver. */
  position?: { x: number; y: number }
  configSchema?: {
    version: 1
    fields: Array<{
      id: string
      name: string
      description?: string
      type: 'string' | 'boolean' | 'select' | 'secret-reference'
      required: boolean
      choices?: Array<{ id: string; name: string; description?: string }>
      binding: { kind: string; target: string }
    }>
  }
  config?: Record<string, unknown>
}

/** Directed graph edge exposed by a Harness Pack. */
export interface HarnessGraphEdge {
  from: string
  to: string
  fromPort?: string
  toPort?: string
  label?: string
  observes?: HarnessRuntimeSignal[]
}

/** Exact install recipe for a protocol Driver that is not bundled with OpenFish. */
export interface HarnessDriverBundleRequirement {
  apiVersion: 1
  package: string
  spec: string
  requiresInstallScripts: boolean
}

/** Client-safe Harness architecture graph. */
export interface HarnessGraph {
  level: HarnessGraphLevel
  manifestVersion?: 1
  boundary?: string
  evidence?: HarnessGraphEvidence[]
  nodes: HarnessGraphNode[]
  edges: HarnessGraphEdge[]
}

/** Searchable Harness catalog row detached from driver internals. */
export interface HarnessCatalogEntry {
  schemaVersion: 0
  id: string
  name: string
  version: string
  description?: string
  publisher: string
  license?: string
  repository?: string
  icon?: string
  verified: boolean
  protocol: string
  account?: {
    label: string
    billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
    detail: string
  }
  modelConfiguration?: { owner: 'host' | 'harness'; required: boolean; detail: string }
  driverBundle?: HarnessDriverBundleRequirement
  source: 'builtin' | 'acp-registry' | 'openfish-community' | 'user'
  isDefault: boolean
  distribution?: CustomHarnessPackInput['distribution']
  graph: HarnessGraph
  available: boolean
  unavailableReason?: string
  installation: {
    status: 'builtin' | 'not-installed' | 'installing' | 'installed' | 'failed'
    installedVersion?: string
    availableVersion: string
    previousVersions: string[]
    integrity: {
      status: 'trusted-runtime' | 'checksum-declared' | 'checksum-verified' | 'version-pinned' | 'local-executable' | 'unverified'
      source: string
      digest?: string
      detail: string
    }
    error?: string
  }
  auth: {
    methods: Array<{
      id: string
      name: string
      kind: 'agent' | 'environment' | 'terminal'
      fields: Array<{ ref: string; name: string; env?: string; required: boolean; secret: boolean; placeholder?: string }>
      account?: {
        label: string
        billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
        detail: string
      }
      agent?: { metaKey: string; fieldMap: Record<string, string> }
      terminal?: { args: string[]; env: Record<string, string> }
    }>
    selectedMethod?: string
    status: 'not-required' | 'needs-selection' | 'needs-credentials' | 'configured'
    missingFields: string[]
  }
  compatibility: {
    status: 'untested' | 'ready' | 'compatible' | 'failed'
    classification: 'supported' | 'experimental' | 'opaque-but-runnable' | 'incompatible'
    checkedAt?: string
    message?: string
  }
  publication?: {
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
  capabilities: Array<{
    id: 'lifecycle.install' | 'lifecycle.update' | 'lifecycle.rollback' | 'lifecycle.uninstall'
      | 'session.create' | 'session.resume' | 'session.cancel' | 'session.fork' | 'session.archive'
      | 'workspace.project' | 'workspace.no-project'
      | 'configuration.models' | 'configuration.reasoning' | 'configuration.auth' | 'configuration.agent-presets'
      | 'interaction.tools' | 'interaction.approvals' | 'interaction.questions' | 'interaction.files' | 'interaction.events'
      | 'architecture.manifest' | 'architecture.runtime-observation' | 'architecture.edit'
      | 'diagnostics.preflight' | 'builder.manifest' | 'builder.test' | 'builder.publish'
    status: 'supported' | 'runtime' | 'unsupported'
    source: 'host' | 'pack' | 'driver' | 'runtime'
    detail?: string
  }>
  driver: {
    apiVersion: 1
    protocol: string
    loaded: boolean
    authorization: 'not-required' | 'required' | 'authorized'
  }
}

/** User-authored Pack document accepted by the graphical editor. */
export interface CustomHarnessPackInput {
  schemaVersion: 0
  id: string
  name: string
  version: string
  description?: string
  publisher: string
  license?: string
  repository?: string
  icon?: string
  protocol: string
  account?: {
    label: string
    billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
    detail: string
  }
  modelConfiguration?: { owner: 'host' | 'harness'; required: boolean; detail: string }
  driverBundle?: HarnessDriverBundleRequirement
  authMethods?: Array<{
    id: string
    name: string
    kind: 'agent' | 'environment' | 'terminal'
    fields: Array<{ ref: string; name: string; env?: string; required: boolean; secret: boolean; placeholder?: string }>
    account?: {
      label: string
      billing: 'subscription' | 'usage' | 'local' | 'harness-managed' | 'unknown'
      detail: string
    }
    agent?: { metaKey: string; fieldMap: Record<string, string> }
    terminal?: { args: string[]; env: Record<string, string> }
  }>
  distribution: { kind: 'npx'; package: string; args: string[]; env: Record<string, string> }
    | { kind: 'bunx'; package: string; args: string[]; env: Record<string, string> }
    | { kind: 'uvx'; package: string; args: string[]; env: Record<string, string> }
    | { kind: 'binary'; archive: string; sha256?: string; command: string; args: string[]; env: Record<string, string> }
    | { kind: 'executable'; command: string; args: string[]; env: Record<string, string> }
  graph: HarnessGraph
}

/** Harness discovery and refresh API. */
export interface HarnessesApi {
  list(request: RpcRequest<{ query?: string }>): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
  resolve(request: RpcRequest<{
    id: string
    version?: string
    authMethod?: string
  }>): Promise<RpcResponse<{ item: HarnessCatalogEntry }>>
  refresh(request: RpcRequest<Record<string, never>>): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
  mutate(request: RpcRequest<{
    action: 'install' | 'uninstall' | 'update' | 'rollback' | 'auth' | 'probe' | 'default' | 'clear-default'
    id?: string
    authMethod?: string
    /** Explicit user confirmation for installing or probing unverified third-party code. */
    acceptUnverified?: boolean
    pack?: CustomHarnessPackInput
  }>, signal?: AbortSignal): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
  /**
   * Host-local authoring and native-interaction plane. Unlike lifecycle
   * selection, these actions may write executable Pack definitions, remove
   * them, or open a terminal on the Mac and are therefore loopback-pinned by
   * client-connection.
   */
  manage(request: RpcRequest<{
    action: 'install' | 'update' | 'probe'
      | 'remove' | 'login' | 'upsert' | 'validate-publication' | 'submit-publication' | 'submit-revocation' | 'authorize-driver'
    id?: string
    version?: string
    driverPackage?: string
    driverSpec?: string
    authMethod?: string
    reason?: string
    /** Kept on the shared native payload; authoring actions never consume it. */
    acceptUnverified?: boolean
    pack?: CustomHarnessPackInput
  }>, signal?: AbortSignal): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
}

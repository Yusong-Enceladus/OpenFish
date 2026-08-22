import type { RpcRequest, RpcResponse } from './rpc.ts'

/** Truthfulness level of a Harness Pack graph. */
export type HarnessGraphLevel = 'opaque' | 'observable' | 'composable'

/** One graph node exposed by a Harness Pack. */
export interface HarnessGraphNode {
  id: string
  kind: string
  title: string
  editable: boolean
  config?: Record<string, unknown>
}

/** Directed graph edge exposed by a Harness Pack. */
export interface HarnessGraphEdge { from: string; to: string }

/** Client-safe Harness architecture graph. */
export interface HarnessGraph {
  level: HarnessGraphLevel
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
    error?: string
  }
  auth: {
    methods: Array<{
      id: string
      name: string
      kind: 'agent' | 'environment' | 'terminal'
      fields: Array<{ ref: string; name: string; env?: string; required: boolean; secret: boolean; placeholder?: string }>
      terminal?: { args: string[]; env: Record<string, string> }
    }>
    selectedMethod?: string
    status: 'not-required' | 'needs-selection' | 'needs-credentials' | 'configured'
    missingFields: string[]
  }
  compatibility: { status: 'untested' | 'ready' | 'compatible' | 'failed'; checkedAt?: string; message?: string }
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
  authMethods?: Array<{
    id: string
    name: string
    kind: 'agent' | 'environment' | 'terminal'
    fields: Array<{ ref: string; name: string; env?: string; required: boolean; secret: boolean; placeholder?: string }>
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
  refresh(request: RpcRequest<Record<string, never>>): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
  mutate(request: RpcRequest<{
    action: 'install' | 'uninstall' | 'update' | 'rollback' | 'remove' | 'auth' | 'login' | 'default' | 'clear-default' | 'upsert'
    id?: string
    authMethod?: string
    pack?: CustomHarnessPackInput
  }>, signal?: AbortSignal): Promise<RpcResponse<{ items: HarnessCatalogEntry[] }>>
}

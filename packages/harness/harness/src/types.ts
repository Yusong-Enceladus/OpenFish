/** Public Harness Pack, driver, and catalog types. @module */

import type { Agent } from '@deepseek-ai/dsh-agent'
import type { Branded } from '@deepseek-ai/dsh-brand'
import type { SessionId } from '@deepseek-ai/dsh-session'

/** Stable registry identity of one Harness Pack. */
export type HarnessId = Branded<'HarnessId'>

/** One node exposed by a Harness Pack for read-only or editable visualization. */
export interface HarnessGraphNode {
  id: string
  kind: string
  title: string
  editable: boolean
  config?: Record<string, unknown>
}

/** Directed data-flow connection between two declared Harness nodes. */
export interface HarnessGraphEdge {
  from: string
  to: string
}

/** Truthfulness level of a Pack's graph description. */
export type HarnessGraphLevel = 'opaque' | 'observable' | 'composable'

/** Graph descriptor published by a Harness Pack. */
export interface HarnessGraph {
  level: HarnessGraphLevel
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
  /** Non-secret sign-in choices the shell may present before first launch. */
  authMethods?: HarnessAuthMethod[]
  distribution?: HarnessDistribution
  graph: HarnessGraph
  source: 'builtin' | 'acp-registry' | 'openfish-community' | 'user'
}

/** Detached catalog row safe for native and web clients. */
export interface HarnessCatalogEntry extends HarnessPack {
  isDefault: boolean
  available: boolean
  unavailableReason?: string
  installation: HarnessInstallation
  auth: HarnessAuthentication
  compatibility: HarnessCompatibility
}

/** User-controlled lifecycle state for one Harness installation. */
export interface HarnessInstallation {
  status: 'builtin' | 'not-installed' | 'installing' | 'installed' | 'failed'
  installedVersion?: string
  availableVersion: string
  previousVersions: string[]
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
  checkedAt?: string
  message?: string
}

/** Authentication choice advertised or curated for a Harness. */
export interface HarnessAuthMethod {
  id: string
  name: string
  kind: 'agent' | 'environment' | 'terminal'
  fields: HarnessAuthField[]
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
  authMethod?: string
}

/** One protocol implementation registered on the Harness service. */
export interface HarnessDriver {
  readonly protocol: string
  available(pack: HarnessPack): Promise<string | undefined>
  create(request: HarnessSessionRequest, pack: HarnessPack): Promise<Agent>
  resume(request: HarnessSessionRequest, pack: HarnessPack): Promise<Agent>
  install?(pack: HarnessPack, directory: string, signal?: AbortSignal): Promise<void>
  /** Return missing credential refs without exposing their values. */
  missingCredentials?(pack: HarnessPack, authMethod?: string): Promise<string[]>
  /** Discover the exact authentication contract advertised by an installed Harness. */
  discoverAuth?(pack: HarnessPack, installationDirectory: string): Promise<HarnessAuthMethod[]>
  /** Launch a Pack-declared interactive login without exposing a command to clients. */
  authenticateInteractive?(pack: HarnessPack, installationDirectory: string, method: HarnessAuthMethod): Promise<void>
}

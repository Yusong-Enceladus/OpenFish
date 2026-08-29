/** Browser-safe OpenFish Harness control-plane requests and results. */

import type {
  HarnessAccountDescriptor,
  HarnessAuthentication,
  HarnessAuthenticationDiscovery,
  HarnessAuthMethod,
  HarnessBindingKindDefinition,
  HarnessCapability,
  HarnessCompatibility,
  HarnessDistribution,
  HarnessDriverBundleRequirement,
  HarnessGraphEvidence,
  HarnessGraphPort,
  HarnessId,
  HarnessInstallation,
  HarnessModelConfiguration,
  HarnessNodeConfigSchema,
  HarnessNodeConfigValue,
  HarnessProof,
  HarnessPublication,
} from '@deepseek-ai/dsh-harness'
import type { JsonValue } from '@deepseek-ai/dsh-session/types'

/**
 * Runtime signals are validated by the Harness Pack/Driver boundary, but the
 * transport deliberately carries them as strings. TypeScript template-literal
 * types such as `driver.${string}` are not a runtime codec and must not be
 * mistaken for one by Typert.
 */
export interface HarnessGraphNodeValue {
  readonly id: string
  readonly kind: string
  readonly title: string
  readonly editable: boolean
  readonly responsibility?: string
  readonly inputs?: readonly string[]
  readonly outputs?: readonly string[]
  readonly ports?: readonly HarnessGraphPort[]
  readonly evidence?: readonly HarnessGraphEvidence[]
  readonly observes?: readonly string[]
  readonly position?: { readonly x: number; readonly y: number }
  readonly configSchema?: HarnessNodeConfigSchema
  readonly config?: Readonly<Record<string, HarnessNodeConfigValue>>
}

/** Browser-safe graph edge with already-validated runtime signal names. */
export interface HarnessGraphEdgeValue {
  readonly from: string
  readonly to: string
  readonly fromPort?: string
  readonly toPort?: string
  readonly label?: string
  readonly observes?: readonly string[]
}

/** Browser-safe graph projection returned by the Harness control plane. */
export interface HarnessGraphValue {
  readonly level: 'opaque' | 'observable' | 'composable'
  readonly manifestVersion?: 1
  readonly boundary?: string
  readonly evidence?: readonly HarnessGraphEvidence[]
  readonly nodes: readonly HarnessGraphNodeValue[]
  readonly edges: readonly HarnessGraphEdgeValue[]
}

/** Browser-safe Driver authoring node definition. */
export interface HarnessNodeKindValue {
  readonly kind: string
  readonly name: string
  readonly description: string
  readonly responsibility: string
  readonly editable: boolean
  readonly inputs: readonly string[]
  readonly outputs: readonly string[]
  readonly ports?: readonly HarnessGraphPort[]
  readonly observes?: readonly string[]
  readonly configSchema?: HarnessNodeConfigSchema
  readonly defaultConfig?: Readonly<Record<string, HarnessNodeConfigValue>>
}

/** Browser-safe Driver authoring vocabulary. */
export interface HarnessAuthoringValue {
  readonly nodeKinds: readonly HarnessNodeKindValue[]
  readonly bindingKinds: readonly HarnessBindingKindDefinition[]
}

/**
 * Detached catalog row transported to native/web clients. The Host has
 * already validated every Pack and Driver-owned signal before constructing it.
 */
export interface HarnessCatalogValue {
  readonly schemaVersion: 0
  readonly id: HarnessId
  readonly name: string
  readonly version: string
  readonly description?: string
  readonly publisher: string
  readonly license?: string
  readonly repository?: string
  readonly icon?: string
  readonly verified: boolean
  readonly protocol: string
  readonly account?: HarnessAccountDescriptor
  readonly modelConfiguration?: HarnessModelConfiguration
  readonly authMethods?: readonly HarnessAuthMethod[]
  readonly authenticationDiscovery?: HarnessAuthenticationDiscovery
  readonly driverBundle?: HarnessDriverBundleRequirement
  readonly distribution?: HarnessDistribution
  readonly graph: HarnessGraphValue
  readonly source: 'builtin' | 'acp-registry' | 'openfish-community' | 'user'
  readonly isDefault: boolean
  readonly available: boolean
  readonly unavailableReason?: string
  readonly installation: HarnessInstallation
  readonly auth: HarnessAuthentication
  readonly compatibility: HarnessCompatibility
  readonly proof: HarnessProof
  readonly publication?: HarnessPublication
  readonly capabilities: readonly HarnessCapability[]
  readonly authoring: HarnessAuthoringValue
  readonly driver: {
    readonly apiVersion: 1
    readonly protocol: string
    readonly loaded: boolean
    readonly authorization: 'not-required' | 'required' | 'authorized'
  }
}

/** Filter for the complete locally available Harness catalog. */
export interface HarnessListRequest {
  readonly query?: string
}

/** Catalog response shared by discovery and lifecycle mutations. */
export interface HarnessListValue {
  readonly items: readonly HarnessCatalogValue[]
}

/** Resolve the exact Pack identity pinned by a task. */
export interface HarnessResolveRequest {
  readonly id: string
  readonly version?: string
  readonly authMethod?: string
}

/** Exact, task-safe catalog row. */
export interface HarnessResolveValue {
  readonly item: HarnessCatalogValue
}

/** Remote-safe Harness lifecycle actions. */
export type HarnessMutationAction =
  | 'install' | 'uninstall' | 'update' | 'rollback' | 'auth' | 'probe'
  | 'default' | 'clear-default'

/** Lifecycle request admitted from any authenticated OpenFish client. */
export interface HarnessMutationRequest {
  readonly action: HarnessMutationAction
  readonly id?: string
  readonly authMethod?: string
  /** Deliberately rejected remotely; unverified-code consent is Mac-local. */
  readonly acceptUnverified?: boolean
}

/** Host-local authoring and executable-code actions. */
export type HarnessManageAction =
  | 'install' | 'update' | 'probe' | 'remove' | 'login' | 'upsert'
  | 'validate-draft'
  | 'validate-publication' | 'submit-publication' | 'submit-revocation'
  | 'authorize-driver'

/** Mac-local authoring request. Pack documents are validated by HarnessService. */
export interface HarnessManageRequest {
  readonly action: HarnessManageAction
  readonly id?: string
  readonly version?: string
  readonly driverPackage?: string
  readonly driverSpec?: string
  readonly authMethod?: string
  readonly reason?: string
  readonly acceptUnverified?: boolean
  readonly pack?: JsonValue
}

/** Stable control-plane failure vocabulary. */
export interface HarnessErrorDetailsMap {
  readonly internal: Record<never, never>
  readonly cancelled: Record<never, never>
  readonly 'harness-selection-required': Record<never, never>
  readonly 'harness-integrity-failed': Record<never, never>
  readonly 'harness-auth-required': Record<never, never>
  readonly 'harness-install-failed': Record<never, never>
  readonly 'harness-resume-failed': Record<never, never>
  readonly 'harness-start-failed': Record<never, never>
  readonly 'harness-failed': Record<never, never>
}

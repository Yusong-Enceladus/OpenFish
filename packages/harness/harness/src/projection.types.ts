/** Client-safe Harness runtime projection types. @module */

export interface HarnessRuntimeProjection {
  /** Exact Harness identity that produced these content-free observations. */
  harnessId?: string
  /** Exact Pack version selected by the task, when recorded by the session. */
  version?: string
  /** Exact non-secret account route selected for this task. */
  authMethod?: string
  /** Exact workspace contract pinned before the first turn. */
  workspaceMode?: 'project' | 'no-project' | 'custom-cwd'
  /** Exact capability snapshot used to render this task, not today's catalog. */
  capabilities?: import('./types.ts').HarnessCapability[]
  nodes: Record<string, {
    status: 'active' | 'waiting' | 'completed' | 'failed'
    activity: string
    /** Pack/Driver validation owns the namespace contract; the client wire carries the admitted name. */
    signal?: string
    seq: number
    time: number
  }>
  edges: Record<string, {
    from: string
    to: string
    fromPort?: string
    toPort?: string
    status: 'active' | 'waiting' | 'completed' | 'failed'
    activity: string
    /** Pack/Driver validation owns the namespace contract; the client wire carries the admitted name. */
    signal: string
    seq: number
    time: number
  }>
  /**
   * Bounded, content-free execution order for the current task. Unlike the
   * node/edge maps above, this preserves repeated visits through loops and
   * branches so a client can explain what actually happened instead of only
   * showing the last light on each component.
   */
  observations: Array<{
    kind: 'node' | 'edge'
    /** Node id or the stable, content-free edge key. */
    id: string
    from?: string
    to?: string
    fromPort?: string
    toPort?: string
    status: 'active' | 'waiting' | 'completed' | 'failed'
    activity: string
    signal?: string
    seq: number
    time: number
  }>
}

declare module '@deepseek-ai/dsh-session-projection/types' {
  interface SessionProjectionMap {
    /** Latest truthful activation evidence for declared Harness architecture nodes. */
    harnessRuntime: HarnessRuntimeProjection
  }

  interface SessionProjectionStateMap {
    /** Durable host fold state; this projection intentionally exposes the same content-free facts. */
    harnessRuntime: HarnessRuntimeProjection
  }
}

export {}

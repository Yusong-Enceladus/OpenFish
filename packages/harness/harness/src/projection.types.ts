/** Client-safe Harness runtime projection types. @module */

export interface HarnessRuntimeProjection {
  /** Exact Harness identity that produced these content-free observations. */
  harnessId?: string
  /** Exact Pack version selected by the task, when recorded by the session. */
  version?: string
  nodes: Record<string, {
    status: 'active' | 'waiting' | 'completed' | 'failed'
    activity: string
    signal?: import('./types.ts').HarnessRuntimeSignal
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
    signal: import('./types.ts').HarnessRuntimeSignal
    seq: number
    time: number
  }>
}

declare module '@deepseek-ai/dsh-session-projection/types' {
  interface SessionProjectionMap {
    /** Latest truthful activation evidence for declared Harness architecture nodes. */
    harnessRuntime: HarnessRuntimeProjection
  }
}

export {}

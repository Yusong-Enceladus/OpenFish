/** Client-safe Harness runtime projection types. @module */

export interface HarnessRuntimeProjection {
  nodes: Record<string, {
    status: 'active' | 'waiting' | 'completed' | 'failed'
    activity: string
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

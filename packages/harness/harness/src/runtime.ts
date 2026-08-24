/** Evidence-bound Harness runtime observation helpers. @module */

import type { Session } from '@deepseek-ai/dsh-session'
import type { HarnessPack, HarnessRuntimeSignal } from './types.ts'

/** Content-free lifecycle state projected onto a declared Harness graph binding. */
export type HarnessRuntimeStatus = 'active' | 'waiting' | 'completed' | 'failed'

/**
 * Record one content-free runtime fact only on nodes that explicitly bind it.
 *
 * Drivers must never infer participation from a node title or `kind`. A Pack
 * that omits `observes` remains an honest static architecture description.
 * @param session - session receiving durable content-free runtime events.
 * @param pack - pinned Pack whose declared graph controls every projection.
 * @param signal - observed standard or Driver-owned runtime signal.
 * @param status - lifecycle state associated with this observation.
 * @param _activity - ignored caller text; activity labels come from the signal vocabulary.
 * @returns the number of declared node and edge bindings that received an event.
 */
export function observeHarnessRuntime(
  session: Session,
  pack: HarnessPack,
  signal: HarnessRuntimeSignal,
  status: HarnessRuntimeStatus,
  _activity?: string,
): number {
  // Runtime Graph is a topology/status surface, not a log transport. Drivers
  // may see prompts, commands, paths, account names, and tool arguments; none
  // of that caller-supplied text is allowed into this cross-device projection.
  const activity = runtimeSignalActivity(signal)
  let observed = 0
  for (const node of pack.graph.nodes) {
    if (!node.observes?.includes(signal)) continue
    session.append('harness/runtime-node', { harnessId: pack.id, nodeId: node.id, signal, status, activity })
    observed += 1
  }
  for (const edge of pack.graph.edges) {
    if (!edge.observes?.includes(signal)) continue
    const edgeKey = harnessRuntimeEdgeKey(edge)
    session.append('harness/runtime-edge', {
      harnessId: pack.id,
      edgeKey,
      from: edge.from,
      to: edge.to,
      ...(edge.fromPort === undefined ? {} : { fromPort: edge.fromPort }),
      ...(edge.toPort === undefined ? {} : { toPort: edge.toPort }),
      signal,
      status,
      activity,
    })
    observed += 1
  }
  return observed
}

/**
 * Stable, content-free identity shared by projections and native clients.
 * @param edge - declared endpoints and optional ports.
 * @returns a deterministic identity that does not include labels or runtime content.
 */
export function harnessRuntimeEdgeKey(edge: Pick<HarnessPack['graph']['edges'][number], 'from' | 'to' | 'fromPort' | 'toPort'>): string {
  return [edge.from, edge.fromPort ?? '', edge.to, edge.toPort ?? ''].join('\u0000')
}

function runtimeSignalActivity(signal: HarnessRuntimeSignal): string {
  switch (signal) {
    case 'protocol.ready': return 'Protocol boundary ready'
    case 'session.ready': return 'Session ready'
    case 'turn.started': return 'Turn started'
    case 'turn.completed': return 'Turn completed'
    case 'turn.failed': return 'Turn failed'
    case 'model.completed': return 'Model response completed'
    case 'tool.activity': return 'Tool activity observed'
    case 'output.activity': return 'Output activity observed'
    case 'approval.requested': return 'Approval requested'
    case 'approval.resolved': return 'Approval resolved'
    default: return `Driver signal: ${signal.slice(signal.lastIndexOf('.') + 1).replaceAll('-', ' ').replaceAll('_', ' ')}`
  }
}

/**
 * Test whether a Pack opted any graph element into runtime evidence.
 * @param pack - admitted Pack to inspect.
 * @returns true when at least one node or edge declares an observed signal.
 */
export function hasHarnessRuntimeBindings(pack: HarnessPack): boolean {
  return pack.graph.nodes.some(node => (node.observes?.length ?? 0) > 0)
    || pack.graph.edges.some(edge => (edge.observes?.length ?? 0) > 0)
}

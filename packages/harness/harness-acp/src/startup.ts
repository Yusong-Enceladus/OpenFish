/** Shared cancellation and timeout boundary for Harness process initialization. */

export const HARNESS_STARTUP_TIMEOUT_MS = 45_000

/**
 * Combine a caller cancellation with a hard startup deadline.
 * @param signal - optional caller-owned cancellation.
 * @returns a signal aborted by either the caller or the startup timeout.
 */
export function harnessStartupSignal(signal?: AbortSignal): AbortSignal {
  const timeout = AbortSignal.timeout(HARNESS_STARTUP_TIMEOUT_MS)
  return signal === undefined ? timeout : AbortSignal.any([signal, timeout])
}

/**
 * Await a protocol operation even when its SDK does not accept AbortSignal.
 * @param operation - protocol promise whose completion is being bounded.
 * @param signal - cancellation and timeout signal for the local wait.
 * @returns the operation value when it completes before cancellation.
 */
export async function abortableHarnessOperation<T>(operation: Promise<T>, signal: AbortSignal): Promise<T> {
  signal.throwIfAborted()
  return await new Promise<T>((resolve, reject) => {
    const aborted = () => {
      const reason: unknown = signal.reason
      reject(reason instanceof Error ? reason : new Error('Harness operation was cancelled'))
    }
    signal.addEventListener('abort', aborted, { once: true })
    operation.then(
      (value) => {
        signal.removeEventListener('abort', aborted)
        resolve(value)
      },
      (error: unknown) => {
        signal.removeEventListener('abort', aborted)
        reject(error instanceof Error ? error : new Error('Harness protocol operation failed', { cause: error }))
      },
    )
  })
}

/**
 * Normalize browser cancellation and TimeoutError into an actionable local diagnostic.
 * @param name - Harness display name used in a timeout diagnostic.
 * @param signal - startup signal whose abort reason owns cancellation semantics.
 * @param cause - original operation failure retained as the error cause.
 * @returns a timeout, caller cancellation, or normalized startup error.
 */
export function harnessStartupError(name: string, signal: AbortSignal, cause: unknown): Error {
  const reason: unknown = signal.reason
  if (reason instanceof DOMException && reason.name === 'TimeoutError') {
    return new Error(`${name} did not become ready within ${HARNESS_STARTUP_TIMEOUT_MS / 1_000} seconds`, { cause })
  }
  if (reason instanceof Error) return reason
  return new Error(`${name} startup was cancelled`, { cause })
}

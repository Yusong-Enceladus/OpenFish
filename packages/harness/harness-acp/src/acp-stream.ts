/** Bounded, non-logging ACP NDJSON transport for untrusted Harness processes. */

import type { Stream } from '@agentclientprotocol/sdk'
import { safeHarnessDiagnostic } from '@deepseek-ai/dsh-harness'

/** Maximum admitted size of one newline-delimited ACP JSON message. */
export const MAXIMUM_ACP_MESSAGE_BYTES = 8 * 1024 * 1024

function joinSegments(segments: readonly Uint8Array[], length: number): Uint8Array {
  if (segments.length === 1 && segments[0]?.byteLength === length) return segments[0]
  const joined = new Uint8Array(length)
  let offset = 0
  for (const segment of segments) {
    joined.set(segment, offset)
    offset += segment.byteLength
  }
  return joined
}

/**
 * Convert stdio bytes into ACP messages without retaining or logging an
 * unbounded/malformed process line. The official SDK stream intentionally
 * favors convenience; the OpenFish process boundary must fail closed.
 * @param output - Writable Harness stdin byte stream.
 * @param input - Readable Harness stdout byte stream.
 * @param maximumMessageBytes - Positive upper bound for one NDJSON message.
 * @returns An ACP SDK stream over the bounded transport.
 */
export function boundedAcpNdJsonStream(
  output: WritableStream<Uint8Array>,
  input: ReadableStream<Uint8Array>,
  maximumMessageBytes = MAXIMUM_ACP_MESSAGE_BYTES,
): Stream {
  if (!Number.isSafeInteger(maximumMessageBytes) || maximumMessageBytes < 1) {
    throw new Error('ACP message limit must be a positive safe integer')
  }
  const decoder = new TextDecoder('utf-8', { fatal: true })
  const encoder = new TextEncoder()
  const readable = new ReadableStream<unknown>({
    async start(controller) {
      const reader = input.getReader()
      let segments: Uint8Array[] = []
      let length = 0

      const publish = (): void => {
        if (length === 0) {
          segments = []
          return
        }
        let text: string
        try {
          text = decoder.decode(joinSegments(segments, length)).trim()
        } catch {
          throw new Error('ACP Harness emitted a message that is not valid UTF-8')
        } finally {
          segments = []
          length = 0
        }
        if (text.length === 0) return
        try {
          controller.enqueue(JSON.parse(text) as unknown)
        } catch {
          // Never include the malformed line: it may contain prompts, local
          // paths, provider diagnostics, or credentials.
          throw new Error('ACP Harness emitted invalid JSON')
        }
      }

      try {
        while (true) {
          const { value, done } = await reader.read()
          if (done) break
          if (value === undefined || value.byteLength === 0) continue
          let start = 0
          for (let index = 0; index < value.byteLength; index++) {
            if (value[index] !== 0x0a) continue
            const segment = value.subarray(start, index)
            if (length + segment.byteLength > maximumMessageBytes) {
              throw new Error(`ACP Harness message exceeds the ${maximumMessageBytes}-byte limit`)
            }
            if (segment.byteLength > 0) segments.push(segment.slice())
            length += segment.byteLength
            publish()
            start = index + 1
          }
          if (start < value.byteLength) {
            const segment = value.subarray(start)
            if (length + segment.byteLength > maximumMessageBytes) {
              throw new Error(`ACP Harness message exceeds the ${maximumMessageBytes}-byte limit`)
            }
            segments.push(segment.slice())
            length += segment.byteLength
          }
        }
        publish()
        controller.close()
      } catch (error: unknown) {
        controller.error(new Error(safeHarnessDiagnostic(error, 'ACP Harness protocol input failed')))
        await reader.cancel().catch(() => undefined)
      } finally {
        reader.releaseLock()
      }
    },
  })
  const writable = new WritableStream<unknown>({
    async write(message) {
      let encoded: Uint8Array
      try {
        encoded = encoder.encode(`${JSON.stringify(message)}\n`)
      } catch {
        throw new Error('OpenFish could not encode an ACP request')
      }
      if (encoded.byteLength > maximumMessageBytes) {
        throw new Error(`OpenFish ACP request exceeds the ${maximumMessageBytes}-byte limit`)
      }
      const writer = output.getWriter()
      try {
        await writer.write(encoded)
      } finally {
        writer.releaseLock()
      }
    },
  })
  return { readable, writable } as Stream
}

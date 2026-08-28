import { describe, expect, it } from 'vitest'
import { boundedAcpNdJsonStream } from '../src/acp-stream.ts'

function input(...chunks: string[]): ReadableStream<Uint8Array> {
  const encoder = new TextEncoder()
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(encoder.encode(chunk))
      controller.close()
    },
  })
}

function output(bytes: Uint8Array[]): WritableStream<Uint8Array> {
  return new WritableStream({ write(chunk) { bytes.push(chunk) } })
}

describe('bounded ACP NDJSON transport', () => {
  it('accepts split messages and writes one bounded NDJSON request', async () => {
    const writes: Uint8Array[] = []
    const stream = boundedAcpNdJsonStream(
      output(writes),
      input('{"jsonrpc":"2.0",', '"id":1}\n{"jsonrpc":"2.0","id":2}\n'),
      256,
    )
    const reader = stream.readable.getReader()
    await expect(reader.read()).resolves.toMatchObject({ value: { jsonrpc: '2.0', id: 1 } })
    await expect(reader.read()).resolves.toMatchObject({ value: { jsonrpc: '2.0', id: 2 } })
    await stream.writable.getWriter().write({ jsonrpc: '2.0', id: 3 } as never)
    expect(new TextDecoder().decode(writes[0])).toBe('{"jsonrpc":"2.0","id":3}\n')
  })

  it('fails closed without echoing malformed or oversized process content', async () => {
    const malformedSecret = 'sk-test-supersecret123456'
    const malformed = boundedAcpNdJsonStream(output([]), input(`{"token":"${malformedSecret}"\n`), 256)
    const malformedReader = malformed.readable.getReader()
    let malformedDiagnostic = ''
    try { await malformedReader.read() } catch (error: unknown) {
      malformedDiagnostic = error instanceof Error ? error.message : String(error)
    }
    expect(malformedDiagnostic).toContain('invalid JSON')
    expect(malformedDiagnostic).not.toContain(malformedSecret)

    const oversized = boundedAcpNdJsonStream(output([]), input('x'.repeat(257)), 256)
    await expect(oversized.readable.getReader().read()).rejects.toThrow('256-byte limit')
  })

  it('rejects an oversized host request before writing it to the Harness', async () => {
    const writes: Uint8Array[] = []
    const stream = boundedAcpNdJsonStream(output(writes), input(), 64)
    await expect(stream.writable.getWriter().write({ value: 'x'.repeat(80) } as never)).rejects.toThrow('64-byte limit')
    expect(writes).toEqual([])
  })
})

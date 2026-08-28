import { describe, expect, it } from 'vitest'
import { safeHarnessDiagnostic, safeHarnessEventValue } from '../src/diagnostic.ts'

describe('Harness persistence diagnostics', () => {
  it('redacts credential-shaped text without exposing it in errors', () => {
    const secret = 'sk-test-supersecret123456'
    expect(safeHarnessDiagnostic(`request failed with ${secret}`)).toBe('request failed with [redacted]')
  })

  it('recovers redacted ACP provider detail from a generic JSON-RPC error', () => {
    const error = Object.assign(new Error('Internal error'), {
      data: { details: 'authentication expired; access_token=sk-test-supersecret123456' },
    })
    expect(safeHarnessDiagnostic(error)).toBe('Internal error: authentication expired; access_token=[redacted]')
  })

  it('bounds and recursively redacts untrusted durable event values', () => {
    const value = safeHarnessEventValue({
      inputTokens: 123,
      accessToken: 'must-not-survive',
      nested: { authorization: 'Bearer must-not-survive', output: 'ok' },
      huge: 'x'.repeat(70_000),
    }) as Record<string, unknown>
    expect(value.inputTokens).toBe(123)
    expect(value.accessToken).toBe('[redacted]')
    expect(value.nested).toEqual({ authorization: '[redacted]', output: 'ok' })
    expect((value.huge as string).length).toBe(65_536)
    expect(JSON.stringify(value)).not.toContain('must-not-survive')
  })

  it('terminates cycles and limits hostile collections', () => {
    const cyclic: Record<string, unknown> = {}
    cyclic.self = cyclic
    cyclic.rows = Array.from({ length: 200 }, (_, index) => index)
    const value = safeHarnessEventValue(cyclic) as Record<string, unknown>
    expect(value.self).toBe('[circular]')
    expect(value.rows).toHaveLength(128)
  })
})

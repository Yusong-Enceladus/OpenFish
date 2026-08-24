import { describe, expect, it } from 'vitest'
import { parseDriverCandidate } from '../src/driver.ts'

describe('OpenFish exact Driver Bundle admission', () => {
  it('accepts only an exact registry version or full GitHub commit with an expected identity', () => {
    expect(parseDriverCandidate('@acme/openfish-driver-demo@1.2.3-beta.4+mac')).toEqual({
      spec: '@acme/openfish-driver-demo@1.2.3-beta.4+mac',
      packageName: '@acme/openfish-driver-demo',
      expectedVersion: '1.2.3-beta.4+mac',
      source: 'npm',
    })
    expect(parseDriverCandidate(
      'github:acme/openfish-driver-demo#0123456789abcdef0123456789abcdef01234567',
      '@acme/openfish-driver-demo',
    )).toEqual({
      spec: 'github:acme/openfish-driver-demo#0123456789abcdef0123456789abcdef01234567',
      packageName: '@acme/openfish-driver-demo',
      source: 'github',
    })
  })

  it.each([
    '@acme/openfish-driver-demo',
    '@acme/openfish-driver-demo@latest',
    '@acme/openfish-driver-demo@^1.2.3',
    './driver',
    'file:../driver',
    'https://example.com/driver.tgz',
    'github:acme/openfish-driver-demo#main',
  ])('rejects floating or caller-selected package-manager input %s', (spec) => {
    expect(() => parseDriverCandidate(spec)).toThrow()
  })

  it('binds an exact source to the expected package identity', () => {
    expect(() => parseDriverCandidate('@acme/driver@1.2.3', '@other/driver'))
      .toThrow('--package must match')
    expect(() => parseDriverCandidate(
      'github:acme/driver#0123456789abcdef0123456789abcdef01234567',
    )).toThrow('needs --package')
    expect(() => parseDriverCandidate(
      'github:acme/driver#0123456789abcdef0123456789abcdef01234567',
      '../driver',
    )).toThrow('needs --package')
  })
})

import { Buffer } from 'node:buffer'
import type { HarnessPack } from '@deepseek-ai/dsh-harness'
import { describe, expect, it, vi } from 'vitest'
import { submitOpenFishCommunityPack, submitOpenFishCommunityRevocation } from '../src/harness-community-github.ts'

const pack: HarnessPack = {
  schemaVersion: 0,
  id: 'community.fixture' as never,
  name: 'Community Fixture',
  version: '1.2.3',
  publisher: 'Fixture Author',
  license: 'MIT',
  repository: 'https://github.com/example/community-fixture',
  verified: false,
  protocol: 'acp',
  distribution: { kind: 'npx', package: '@example/community-fixture@1.2.3', args: ['acp'], env: {} },
  graph: { level: 'opaque', nodes: [{ id: 'runtime', kind: 'runtime', title: 'Runtime', editable: false }], edges: [] },
  source: 'openfish-community',
}

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: { 'content-type': 'application/json' } })
}

function requestUrl(input: string | URL | Request): string {
  if (typeof input === 'string') return input
  return input instanceof URL ? input.href : input.url
}

function requestBodyText(body: BodyInit | null | undefined): string {
  if (typeof body !== 'string') throw new Error('expected a JSON request body')
  return body
}

describe('GitHub community Harness submission', () => {
  it('creates a credential-free Pack commit, generated catalog update, and real review', async () => {
    const catalog = Buffer.from(JSON.stringify({ version: 0, packs: [], revocations: [] }), 'utf8').toString('base64')
    const requests: Array<{ url: string; init: RequestInit }> = []
    const transport = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = requestUrl(input)
      requests.push({ url, init: init ?? {} })
      if (url.endsWith('/user')) return json({ login: 'fixture-user' })
      if (url.endsWith('/repos/fixture-user/OpenFish')) {
        return json({
          default_branch: 'main', full_name: 'fixture-user/OpenFish', fork: true,
          parent: { full_name: 'Yusong-Enceladus/OpenFish' },
        })
      }
      if (url.endsWith('/repos/Yusong-Enceladus/OpenFish')) {
        return json({ default_branch: 'main', full_name: 'Yusong-Enceladus/OpenFish', fork: false })
      }
      if (url.includes('/git/ref/heads/main')) return json({ object: { sha: 'base-sha' } })
      if (url.endsWith('/git/refs')) return json({ ref: 'created' }, 201)
      if (url.includes('/contents/community/harnesses/index.json?ref=')) {
        return json({ sha: 'index-sha', encoding: 'base64', content: catalog })
      }
      if (url.includes('/contents/community/harnesses/packs/community.fixture.json') && init?.method === 'GET') {
        return json({ message: 'Not Found' }, 404)
      }
      if (url.includes('/contents/community/harnesses/packs/community.fixture.json') && init?.method === 'PUT') {
        return json({ content: { sha: 'pack-sha' } }, 201)
      }
      if (url.endsWith('/contents/community/harnesses/index.json') && init?.method === 'PUT') {
        return json({ content: { sha: 'next-index-sha' } })
      }
      if (url.endsWith('/repos/Yusong-Enceladus/OpenFish/pulls')) {
        return json({ html_url: 'https://github.com/Yusong-Enceladus/OpenFish/pull/42' }, 201)
      }
      throw new Error(`unexpected GitHub request: ${init?.method ?? 'GET'} ${url}`)
    })

    const result = await submitOpenFishCommunityPack(pack, 'github-secret', undefined, transport)

    expect(result.reviewUrl).toBe('https://github.com/Yusong-Enceladus/OpenFish/pull/42')
    const writes = requests.filter(request => request.init.method === 'PUT')
    const written = writes.map(request => JSON.parse(requestBodyText(request.init.body)) as { content: string })
      .map(request => Buffer.from(request.content, 'base64').toString('utf8'))
    expect(written[0]).toContain('"id": "community.fixture"')
    expect(written[1]).toContain('"packs"')
    expect(written.join('\n')).not.toContain('github-secret')
    expect(requests.every(request => !request.url.includes('github-secret'))).toBe(true)
  })

  it('opens an exact-version revocation review without deleting catalog history', async () => {
    const catalog = Buffer.from(JSON.stringify({ version: 0, packs: [pack], revocations: [] }), 'utf8').toString('base64')
    const ledger = Buffer.from(JSON.stringify({ version: 0, revocations: [] }), 'utf8').toString('base64')
    const requests: Array<{ url: string; init: RequestInit }> = []
    const transport = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
      const url = requestUrl(input)
      requests.push({ url, init: init ?? {} })
      if (url.endsWith('/user')) return json({ login: 'fixture-user' })
      if (url.endsWith('/repos/fixture-user/OpenFish')) {
        return json({
          default_branch: 'main', full_name: 'fixture-user/OpenFish', fork: true,
          parent: { full_name: 'Yusong-Enceladus/OpenFish' },
        })
      }
      if (url.endsWith('/repos/Yusong-Enceladus/OpenFish')) {
        return json({ default_branch: 'main', full_name: 'Yusong-Enceladus/OpenFish', fork: false })
      }
      if (url.includes('/git/ref/heads/main')) return json({ object: { sha: 'base-sha' } })
      if (url.endsWith('/git/refs')) return json({ ref: 'created' }, 201)
      if (url.includes('/contents/community/harnesses/index.json?ref=')) {
        return json({ sha: 'index-sha', encoding: 'base64', content: catalog })
      }
      if (url.includes('/contents/community/harnesses/revocations.json?ref=')) {
        return json({ sha: 'ledger-sha', encoding: 'base64', content: ledger })
      }
      if (url.endsWith('/contents/community/harnesses/revocations.json') && init?.method === 'PUT') {
        return json({ content: { sha: 'next-ledger-sha' } })
      }
      if (url.endsWith('/contents/community/harnesses/index.json') && init?.method === 'PUT') {
        return json({ content: { sha: 'next-index-sha' } })
      }
      if (url.endsWith('/repos/Yusong-Enceladus/OpenFish/pulls')) {
        return json({ html_url: 'https://github.com/Yusong-Enceladus/OpenFish/pull/43' }, 201)
      }
      throw new Error(`unexpected GitHub request: ${init?.method ?? 'GET'} ${url}`)
    })

    const result = await submitOpenFishCommunityRevocation({
      id: 'community.fixture', version: '1.2.3',
      reason: 'The published executable has a confirmed unsafe compatibility regression.',
    }, 'github-secret', undefined, transport)

    expect(result.reviewUrl).toBe('https://github.com/Yusong-Enceladus/OpenFish/pull/43')
    const writes = requests.filter(request => request.init.method === 'PUT')
    const written = writes.map(request => JSON.parse(requestBodyText(request.init.body)) as { content: string })
      .map(request => Buffer.from(request.content, 'base64').toString('utf8'))
    expect(written.join('\n')).toContain('"revocations"')
    expect(written.join('\n')).toContain('confirmed unsafe compatibility regression')
    expect(written.join('\n')).toContain('"packs"')
    expect(written.join('\n')).not.toContain('github-secret')
  })
})

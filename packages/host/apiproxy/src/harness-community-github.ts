/** GitHub-backed OpenFish community Harness submission workflow. @module */

import { Buffer } from 'node:buffer'
import { randomUUID } from 'node:crypto'
import type { HarnessPack } from '@deepseek-ai/dsh-harness'
import { z } from 'zod'

const API_ROOT = 'https://api.github.com'
const UPSTREAM_OWNER = 'Yusong-Enceladus'
const UPSTREAM_REPOSITORY = 'OpenFish'

/** Keychain reference used only by the Host for user-initiated GitHub publication. */
export const OPENFISH_GITHUB_TOKEN_REF = 'OPENFISH_GITHUB_TOKEN'

/** Review record returned after GitHub accepts a real community pull request. */
export interface HarnessCommunitySubmissionResult {
  reviewUrl: string
  branch: string
  submittedAt: string
}

/** Public, reviewable request to stop distributing one exact community Pack. */
export interface HarnessCommunityRevocationRequest {
  id: string
  version: string
  reason: string
}

const githubUserSchema = z.object({ login: z.string() })
const githubRepositorySchema = z.object({
  default_branch: z.string(),
  full_name: z.string().optional(),
  fork: z.boolean().optional(),
  parent: z.object({ full_name: z.string().optional() }).optional(),
})
const gitReferenceSchema = z.object({ object: z.object({ sha: z.string() }) })
const githubContentSchema = z.object({
  sha: z.string(), content: z.string().optional(), encoding: z.string().optional(),
})
const githubPullRequestSchema = z.object({ html_url: z.string() })
const ignoredGitHubResponseSchema = z.unknown()

type GitHubRepository = z.infer<typeof githubRepositorySchema>
type GitHubContent = z.infer<typeof githubContentSchema>
interface CommunityCatalogDocument { version: 0; packs: unknown[]; revocations: unknown[] }
interface CommunityRevocationDocument { version: 0; revocations: unknown[] }

type GitHubFetch = typeof fetch

function headers(token: string): Record<string, string> {
  return {
    Accept: 'application/vnd.github+json',
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'OpenFish-Harness-Publisher',
  }
}

/** Preserve exact optional RequestInit semantics when cancellation is absent. */
function requestSignal(signal?: AbortSignal): { signal?: AbortSignal } {
  return signal === undefined ? {} : { signal }
}

async function github<T>(
  transport: GitHubFetch,
  token: string,
  path: string,
  init: RequestInit,
  expected: readonly number[],
  schema: z.ZodType<T>,
): Promise<{ status: number; value?: T }> {
  const response = await transport(`${API_ROOT}${path}`, {
    ...init,
    // Callers intentionally cannot override authorization or the API media
    // type. Keeping one Host-owned header set also avoids treating every
    // legal `HeadersInit` representation as a spreadable record.
    headers: headers(token),
  })
  if (expected.includes(response.status)) {
    if (!response.ok || response.status === 204 || response.headers.get('content-length') === '0') {
      return { status: response.status }
    }
    return { status: response.status, value: schema.parse(await response.json()) }
  }
  const body = await response.json().catch(() => undefined) as { message?: unknown } | undefined
  const message = typeof body?.message === 'string' ? body.message.slice(0, 600) : `HTTP ${response.status}`
  throw new Error(`GitHub community submission failed: ${message}`)
}

async function waitForFork(
  transport: GitHubFetch,
  token: string,
  login: string,
  signal?: AbortSignal,
): Promise<GitHubRepository> {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    signal?.throwIfAborted()
    const result = await github(
      transport, token, `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}`,
      { method: 'GET', ...requestSignal(signal) }, [200, 404], githubRepositorySchema,
    )
    if (result.status === 200 && result.value !== undefined) {
      assertPublicationRepository(result.value, login)
      return result.value
    }
    await new Promise<void>((resolve, reject) => {
      function aborted(): void {
        clearTimeout(timeout)
        signal?.removeEventListener('abort', aborted)
        const reason: unknown = signal?.reason
        reject(reason instanceof Error ? reason : new Error('GitHub fork wait aborted'))
      }
      function complete(): void {
        signal?.removeEventListener('abort', aborted)
        resolve()
      }
      const timeout = setTimeout(complete, 750)
      signal?.addEventListener('abort', aborted, { once: true })
    })
  }
  throw new Error('GitHub created the fork but it did not become ready within 15 seconds')
}

function assertPublicationRepository(repository: GitHubRepository, login: string): void {
  if (login === UPSTREAM_OWNER && repository.full_name === `${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}`) return
  if (repository.fork === true && repository.parent?.full_name === `${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}`) return
  throw new Error(
    `GitHub account "${login}" already owns an unrelated repository named ${UPSTREAM_REPOSITORY}; `
      + `rename it or create a fork of ${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY} before submitting`,
  )
}

async function repositoryForUser(
  transport: GitHubFetch,
  token: string,
  login: string,
  signal?: AbortSignal,
): Promise<GitHubRepository> {
  const existing = await github(
    transport, token, `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}`,
    { method: 'GET', ...requestSignal(signal) }, [200, 404], githubRepositorySchema,
  )
  if (existing.status === 200 && existing.value !== undefined) {
    assertPublicationRepository(existing.value, login)
    return existing.value
  }
  await github(
    transport, token, `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}/forks`,
    { method: 'POST', body: JSON.stringify({ name: UPSTREAM_REPOSITORY, default_branch_only: true }), ...requestSignal(signal) },
    [202], ignoredGitHubResponseSchema,
  )
  return await waitForFork(transport, token, login, signal)
}

async function putFile(
  transport: GitHubFetch,
  token: string,
  login: string,
  branch: string,
  path: string,
  content: string,
  message: string,
  signal?: AbortSignal,
): Promise<void> {
  const encodedPath = path.split('/').map(encodeURIComponent).join('/')
  const current = await github(
    transport, token,
    `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/contents/${encodedPath}?ref=${encodeURIComponent(branch)}`,
    { method: 'GET', ...requestSignal(signal) }, [200, 404], githubContentSchema,
  )
  await github(
    transport, token,
    `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/contents/${encodedPath}`,
    {
      method: 'PUT', ...requestSignal(signal),
      body: JSON.stringify({
        message,
        branch,
        content: Buffer.from(content, 'utf8').toString('base64'),
        ...(current.status === 200 && current.value?.sha !== undefined ? { sha: current.value.sha } : {}),
      }),
    },
    [200, 201], ignoredGitHubResponseSchema,
  )
}

function decodeContent(document: GitHubContent): string {
  if (document.encoding !== 'base64' || document.content === undefined) {
    throw new Error('GitHub returned an unsupported community catalog document')
  }
  return Buffer.from(document.content.replaceAll('\n', ''), 'base64').toString('utf8')
}

function updateCatalog(document: GitHubContent, pack: HarnessPack): string {
  const parsed = JSON.parse(decodeContent(document)) as Partial<CommunityCatalogDocument>
  if (parsed.version !== 0 || !Array.isArray(parsed.packs) || !Array.isArray(parsed.revocations)) {
    throw new Error('The community catalog on GitHub is not a supported version')
  }
  const packs = parsed.packs.filter((candidate) => {
    if (typeof candidate !== 'object' || candidate === null || Array.isArray(candidate)) return true
    return (candidate as { id?: unknown }).id !== pack.id
  })
  packs.push(pack)
  packs.sort((left, right) => {
    const leftId = publicationIdentity(left).id ?? ''
    const rightId = publicationIdentity(right).id ?? ''
    return leftId.localeCompare(rightId)
  })
  return `${JSON.stringify({ version: 0, packs, revocations: parsed.revocations }, null, 2)}\n`
}

function publicationIdentity(candidate: unknown): { id?: string; version?: string } {
  if (typeof candidate !== 'object' || candidate === null || Array.isArray(candidate)) return {}
  const row = candidate as { id?: unknown; version?: unknown }
  return {
    ...(typeof row.id === 'string' ? { id: row.id } : {}),
    ...(typeof row.version === 'string' ? { version: row.version } : {}),
  }
}

function appendRevocation(
  catalog: GitHubContent,
  ledger: GitHubContent,
  request: HarnessCommunityRevocationRequest,
  revokedAt: string,
): { catalog: string; ledger: string } {
  const parsedCatalog = JSON.parse(decodeContent(catalog)) as Partial<CommunityCatalogDocument>
  const parsedLedger = JSON.parse(decodeContent(ledger)) as Partial<CommunityRevocationDocument>
  if (parsedCatalog.version !== 0 || !Array.isArray(parsedCatalog.packs) || !Array.isArray(parsedCatalog.revocations)) {
    throw new Error('The community catalog on GitHub is not a supported version')
  }
  if (parsedLedger.version !== 0 || !Array.isArray(parsedLedger.revocations)) {
    throw new Error('The community revocation ledger on GitHub is not a supported version')
  }
  if (!parsedCatalog.packs.some((candidate) => {
    const identity = publicationIdentity(candidate)
    return identity.id === request.id && identity.version === request.version
  })) {
    throw new Error(`Harness "${request.id}" version ${request.version} is not present in the community catalog`)
  }
  const keyMatches = (candidate: unknown): boolean => {
    const identity = publicationIdentity(candidate)
    return identity.id === request.id && identity.version === request.version
  }
  if (parsedLedger.revocations.some(keyMatches) || parsedCatalog.revocations.some(keyMatches)) {
    throw new Error(`Harness "${request.id}" version ${request.version} already has a community revocation record`)
  }
  const revocation = { id: request.id, version: request.version, reason: request.reason, revokedAt }
  const sortRows = (rows: unknown[]): unknown[] => rows.sort((left, right) => {
    const a = publicationIdentity(left)
    const b = publicationIdentity(right)
    return `${a.id ?? ''}\u0000${a.version ?? ''}`.localeCompare(`${b.id ?? ''}\u0000${b.version ?? ''}`)
  })
  return {
    ledger: `${JSON.stringify({ version: 0, revocations: sortRows([...parsedLedger.revocations, revocation]) }, null, 2)}\n`,
    catalog: `${JSON.stringify({
      version: 0,
      packs: parsedCatalog.packs,
      revocations: sortRows([...parsedCatalog.revocations, revocation]),
    }, null, 2)}\n`,
  }
}

/**
 * Submit one already-admitted, credential-free Pack to the documented
 * OpenFish community catalog and open a real review pull request.
 *
 * @param pack - Publication-normalized Pack returned by HarnessService.
 * @param token - GitHub credential resolved for this operation only.
 * @param signal - Optional cancellation from the native request.
 * @param transport - Injectable HTTP transport used by focused contract tests.
 * @returns Review URL and durable local submission facts.
 */
export async function submitOpenFishCommunityPack(
  pack: HarnessPack,
  token: string,
  signal?: AbortSignal,
  transport: GitHubFetch = fetch,
): Promise<HarnessCommunitySubmissionResult> {
  if (token.trim() === '') throw new Error('GitHub authorization is required to submit a Harness Pack')
  const user = await github(
    transport, token, '/user', { method: 'GET', ...requestSignal(signal) }, [200], githubUserSchema,
  )
  if (user.value?.login === undefined || user.value.login === '') throw new Error('GitHub did not return the authenticated account')
  const login = user.value.login
  await repositoryForUser(transport, token, login, signal)
  const upstream = await github(
    transport, token, `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}`,
    { method: 'GET', ...requestSignal(signal) }, [200], githubRepositorySchema,
  )
  const upstreamBranch = upstream.value?.default_branch
  if (upstreamBranch === undefined || upstreamBranch === '') {
    throw new Error('GitHub did not return the OpenFish community repository default branch')
  }
  // Always branch from the current upstream revision. A user's fork may be
  // months behind; using its default branch would make an otherwise valid
  // Pack PR carry unrelated stale diffs or fail to merge.
  const baseReference = await github(
    transport, token,
    `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}/git/ref/heads/${encodeURIComponent(upstreamBranch)}`,
    { method: 'GET', ...requestSignal(signal) }, [200], gitReferenceSchema,
  )
  const baseSha = baseReference.value?.object.sha
  if (baseSha === undefined) throw new Error('GitHub did not return the fork base revision')
  const safeId = String(pack.id).replace(/[^a-z0-9._-]+/gu, '-').slice(0, 80)
  const safeVersion = pack.version.replace(/[^0-9A-Za-z._-]+/gu, '-').slice(0, 48)
  const branch = `openfish/harness-${safeId}-${safeVersion}-${randomUUID().slice(0, 8)}`
  await github(
    transport, token, `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/git/refs`,
    { method: 'POST', ...requestSignal(signal), body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: baseSha }) },
    [201], ignoredGitHubResponseSchema,
  )
  const catalogPath = 'community/harnesses/index.json'
  const catalog = await github(
    transport, token,
    `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/contents/${catalogPath}?ref=${encodeURIComponent(branch)}`,
    { method: 'GET', ...requestSignal(signal) }, [200], githubContentSchema,
  )
  if (catalog.value === undefined) throw new Error('GitHub did not return the community catalog')
  const publicPack = `${JSON.stringify(pack, null, 2)}\n`
  await putFile(
    transport, token, login, branch, `community/harnesses/packs/${String(pack.id)}.json`, publicPack,
    `community: submit ${String(pack.id)} ${pack.version}`, signal,
  )
  await putFile(
    transport, token, login, branch, catalogPath, updateCatalog(catalog.value, pack),
    `community: update catalog for ${String(pack.id)} ${pack.version}`, signal,
  )
  const pull = await github(
    transport, token, `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}/pulls`,
    {
      method: 'POST', ...requestSignal(signal),
      body: JSON.stringify({
        title: `community: add ${String(pack.id)} ${pack.version}`,
        head: `${login}:${branch}`,
        base: upstreamBranch,
        body: [
          'Submitted from OpenFish after local Pack validation, exact-version installation, and prompt-free live Driver preflight. The selected Harness may still create provider-owned setup state or incur provider-specific cost.',
          '',
          `- Harness: \`${String(pack.id)}\``,
          `- Version: \`${pack.version}\``,
          `- Protocol: \`${pack.protocol}\``,
          `- Publisher declaration: ${pack.publisher}`,
          '',
          'Community catalog inclusion provides discoverability, not a security endorsement. Maintainers must review provenance, license, distribution pinning, graph evidence, and credential references before merge.',
        ].join('\n'),
      }),
    }, [201], githubPullRequestSchema,
  )
  if (pull.value?.html_url === undefined) throw new Error('GitHub created the review but returned no review URL')
  return { reviewUrl: pull.value.html_url, branch, submittedAt: new Date().toISOString() }
}

/**
 * Open a maintainer-reviewed revocation PR for one exact published Pack.
 * Revocation never deletes history: the generated catalog retains the Pack and
 * adds an explicit ledger row that blocks new installs while pinned tasks can
 * still explain what they ran.
 * @param input - exact Pack identity and public revocation reason.
 * @param token - GitHub bearer credential used only by the request transport.
 * @param signal - optional cancellation for every GitHub operation.
 * @param transport - injectable GitHub fetch implementation.
 * @returns the created review URL, branch, and submission timestamp.
 */
export async function submitOpenFishCommunityRevocation(
  input: HarnessCommunityRevocationRequest,
  token: string,
  signal?: AbortSignal,
  transport: GitHubFetch = fetch,
): Promise<HarnessCommunitySubmissionResult> {
  if (token.trim() === '') throw new Error('GitHub authorization is required to request a Harness revocation')
  const id = input.id.trim()
  const version = input.version.trim()
  const reason = input.reason.trim()
  if (!/^[a-z0-9][a-z0-9._-]*$/u.test(id)) throw new Error('Harness revocation requires a valid Pack id')
  if (version === '' || version.length > 128) throw new Error('Harness revocation requires one exact published version')
  if (reason.length < 20 || reason.length > 2_000) {
    throw new Error('Harness revocation reason must contain 20 to 2,000 characters')
  }
  const request = { id, version, reason }
  const user = await github(
    transport, token, '/user', { method: 'GET', ...requestSignal(signal) }, [200], githubUserSchema,
  )
  if (user.value?.login === undefined || user.value.login === '') throw new Error('GitHub did not return the authenticated account')
  const login = user.value.login
  await repositoryForUser(transport, token, login, signal)
  const upstream = await github(
    transport, token, `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}`,
    { method: 'GET', ...requestSignal(signal) }, [200], githubRepositorySchema,
  )
  const upstreamBranch = upstream.value?.default_branch
  if (upstreamBranch === undefined || upstreamBranch === '') {
    throw new Error('GitHub did not return the OpenFish community repository default branch')
  }
  const baseReference = await github(
    transport, token,
    `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}/git/ref/heads/${encodeURIComponent(upstreamBranch)}`,
    { method: 'GET', ...requestSignal(signal) }, [200], gitReferenceSchema,
  )
  const baseSha = baseReference.value?.object.sha
  if (baseSha === undefined) throw new Error('GitHub did not return the fork base revision')
  const safeId = id.replace(/[^a-z0-9._-]+/gu, '-').slice(0, 80)
  const safeVersion = version.replace(/[^0-9A-Za-z._-]+/gu, '-').slice(0, 48)
  const branch = `openfish/revoke-${safeId}-${safeVersion}-${randomUUID().slice(0, 8)}`
  await github(
    transport, token, `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/git/refs`,
    { method: 'POST', ...requestSignal(signal), body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: baseSha }) },
    [201], ignoredGitHubResponseSchema,
  )
  const catalogPath = 'community/harnesses/index.json'
  const ledgerPath = 'community/harnesses/revocations.json'
  const [catalog, ledger] = await Promise.all([
    github(
      transport, token,
      `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/contents/${catalogPath}?ref=${encodeURIComponent(branch)}`,
      { method: 'GET', ...requestSignal(signal) }, [200], githubContentSchema,
    ),
    github(
      transport, token,
      `/repos/${encodeURIComponent(login)}/${UPSTREAM_REPOSITORY}/contents/${ledgerPath}?ref=${encodeURIComponent(branch)}`,
      { method: 'GET', ...requestSignal(signal) }, [200], githubContentSchema,
    ),
  ])
  if (catalog.value === undefined || ledger.value === undefined) {
    throw new Error('GitHub did not return the community catalog and revocation ledger')
  }
  const revokedAt = new Date().toISOString()
  const updated = appendRevocation(catalog.value, ledger.value, request, revokedAt)
  await putFile(
    transport, token, login, branch, ledgerPath, updated.ledger,
    `community: revoke ${id} ${version}`, signal,
  )
  await putFile(
    transport, token, login, branch, catalogPath, updated.catalog,
    `community: update catalog revocation for ${id} ${version}`, signal,
  )
  const pull = await github(
    transport, token, `/repos/${UPSTREAM_OWNER}/${UPSTREAM_REPOSITORY}/pulls`,
    {
      method: 'POST', ...requestSignal(signal),
      body: JSON.stringify({
        title: `community: revoke ${id} ${version}`,
        head: `${login}:${branch}`,
        base: upstreamBranch,
        body: [
          'Submitted from OpenFish as an explicit exact-version revocation request.',
          '',
          `- Harness: \`${id}\``,
          `- Version: \`${version}\``,
          `- Reason: ${reason}`,
          '',
          'Maintainers must verify the report and provenance before merging. A merged revocation blocks new installs without erasing the public review history.',
        ].join('\n'),
      }),
    }, [201], githubPullRequestSchema,
  )
  if (pull.value?.html_url === undefined) throw new Error('GitHub created the revocation review but returned no review URL')
  return { reviewUrl: pull.value.html_url, branch, submittedAt: revokedAt }
}

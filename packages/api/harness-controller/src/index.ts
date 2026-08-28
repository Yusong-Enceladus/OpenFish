/** OpenFish Harness catalog, lifecycle, authentication, and authoring Remote owner. */

import type { Context } from '@deepseek-ai/cordis'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import type {} from '@deepseek-ai/dsh-credentials'
import { safeHarnessDiagnostic, type HarnessId } from '@deepseek-ai/dsh-harness'
import type {} from '@deepseek-ai/dsh-harness'
import { Remote, TypertRemoteFailure, TypertRemoteService } from '@deepseek-ai/dsh-typert-protocol'
import {
  OPENFISH_GITHUB_TOKEN_REF,
  submitOpenFishCommunityPack,
  submitOpenFishCommunityRevocation,
} from './community-github.ts'
import type {
  HarnessListRequest,
  HarnessListValue,
  HarnessManageRequest,
  HarnessMutationRequest,
  HarnessResolveRequest,
  HarnessResolveValue,
} from './types.ts'

export type * from './types.ts'

declare module '@deepseek-ai/cordis' {
  interface Context {
    /** OpenFish Harness business API and generated `remote.harness` owner. */
    harnessController: HarnessController
  }
}

/** Host service backing the generated `ctx.remote.harness` namespace. */
export class HarnessController extends TypertRemoteService {
  static inject = ['typert', 'harnesses']

  constructor(ctx: Context) {
    super(ctx, 'harnessController', { namespace: 'harness' })
  }

  /**
   * List locally known built-ins, registry entries, community Packs, and user Packs.
   * @param request - Optional bounded catalog query.
   * @returns Matching Harness catalog entries.
   */
  @Remote('list')
  async list(request: HarnessListRequest): Promise<HarnessListValue> {
    try {
      const query = request.query?.trim().toLocaleLowerCase()
      const items = (await this.ctx.harnesses.list()).filter(item => query === undefined || query === ''
        || item.id.toLocaleLowerCase().includes(query)
        || item.name.toLocaleLowerCase().includes(query)
        || item.description?.toLocaleLowerCase().includes(query) === true)
      return { items }
    } catch (error: unknown) {
      fail('internal', `Harness listing failed: ${safeHarnessDiagnostic(error, 'catalog unavailable')}`)
    }
  }

  /**
   * Resolve the exact version and authentication identity recorded by a task.
   * @param request - Pinned Harness identity recorded by the task.
   * @returns The exact resolved Harness catalog entry.
   */
  @Remote('resolve')
  async resolve(request: HarnessResolveRequest): Promise<HarnessResolveValue> {
    try {
      return {
        item: await this.ctx.harnesses.describe(
          harnessId(request.id),
          request.version,
          request.authMethod,
        ),
      }
    } catch (error: unknown) {
      throw harnessFailure(error, 'Harness task identity could not be resolved')
    }
  }

  /**
   * Refresh public catalogs without hiding the deterministic bundled baseline.
   * @param signal - Cancellation for the catalog refresh.
   * @returns The complete catalog after refresh.
   */
  @Remote('refresh')
  async refresh(signal: AbortSignal): Promise<HarnessListValue> {
    try {
      signal.throwIfAborted()
      await this.ctx.harnesses.refresh(signal)
      signal.throwIfAborted()
      return { items: await this.ctx.harnesses.list() }
    } catch (error: unknown) {
      if (signal.aborted) fail('cancelled', 'Harness catalog refresh was cancelled')
      fail('internal', `Harness refresh failed: ${safeHarnessDiagnostic(error, 'catalog refresh failed')}`)
    }
  }

  /**
   * Run lifecycle operations that never accept third-party-code consent remotely.
   * @param request - Requested lifecycle or selection mutation.
   * @param signal - Cancellation for process-owning lifecycle work.
   * @returns The complete catalog after mutation.
   */
  @Remote('mutate')
  async mutate(request: HarnessMutationRequest, signal: AbortSignal): Promise<HarnessListValue> {
    try {
      signal.throwIfAborted()
      if (request.action === 'clear-default') {
        await this.ctx.harnesses.clearDefault()
      } else {
        if (request.id === undefined) throw new Error('A Harness id is required')
        const id = harnessId(request.id)
        if (request.action === 'install' || request.action === 'update' || request.action === 'probe') {
          const candidate = await this.ctx.harnesses.describe(id)
          const introducesCode = candidate.installation.status !== 'installed'
            || candidate.installation.installedVersion !== candidate.installation.availableVersion
          if (introducesCode && !candidate.verified && candidate.source !== 'user') {
            throw new Error(
              `Harness "${candidate.id}" is unverified; admit this exact third-party code on the Host-local Mac management surface before installing or probing it`,
            )
          }
          if (request.acceptUnverified === true) {
            throw new Error('Unverified Harness code consent is accepted only by the Host-local management plane')
          }
        }
        if (request.action === 'install' || request.action === 'update') {
          await this.ctx.harnesses.install(id, signal)
        } else if (request.action === 'uninstall') {
          await this.ctx.harnesses.uninstall(id)
        } else if (request.action === 'rollback') {
          await this.ctx.harnesses.rollback(id)
        } else if (request.action === 'probe') {
          await ensureInstalled(this.ctx, id, signal)
          await this.ctx.harnesses.probe(id, signal)
        } else if (request.action === 'default') {
          await this.ctx.harnesses.selectDefault(id)
        } else {
          await this.ctx.harnesses.selectAuth(id, request.authMethod)
        }
      }
      signal.throwIfAborted()
      return { items: await this.ctx.harnesses.list() }
    } catch (error: unknown) {
      if (signal.aborted) fail('cancelled', `Harness ${request.action} was cancelled`)
      throw harnessFailure(error, `Harness ${request.action} failed`)
    }
  }

  /**
   * Run Mac-authorized executable-code and Pack-authoring operations.
   * The carrier enforces Host-local authority before dispatching this method.
   * @param request - Host-authorized management or authoring operation.
   * @param signal - Cancellation for installation, probing, or publication work.
   * @returns The complete catalog after management.
   */
  @Remote('manage')
  async manage(request: HarnessManageRequest, signal: AbortSignal): Promise<HarnessListValue> {
    try {
      signal.throwIfAborted()
      if (request.action === 'install' || request.action === 'update' || request.action === 'probe') {
        const id = requiredHarnessId(request.id)
        const candidate = await this.ctx.harnesses.describe(id)
        const introducesCode = candidate.installation.status !== 'installed'
          || candidate.installation.installedVersion !== candidate.installation.availableVersion
        if (introducesCode && !candidate.verified && candidate.source !== 'user'
          && request.acceptUnverified !== true) {
          throw new Error(`Harness "${candidate.id}" requires explicit Host-local confirmation for this exact third-party code`)
        }
        if (request.action === 'install' || request.action === 'update') {
          await this.ctx.harnesses.install(id, signal)
        } else {
          await ensureInstalled(this.ctx, id, signal)
          await this.ctx.harnesses.probe(id, signal)
        }
      } else if (request.action === 'authorize-driver') {
        if (request.version === undefined || request.driverPackage === undefined || request.driverSpec === undefined) {
          throw new Error('Exact Harness and Driver Bundle identities are required')
        }
        await this.ctx.harnesses.authorizeDriverBundle(
          requiredHarnessId(request.id),
          request.version,
          request.driverPackage,
          request.driverSpec,
        )
      } else if (request.action === 'upsert') {
        if (request.pack === undefined) throw new Error('A Harness Pack document is required')
        await this.ctx.harnesses.upsert(request.pack)
      } else if (request.action === 'validate-publication') {
        if (request.pack === undefined) throw new Error('A Harness Pack document is required')
        await this.ctx.harnesses.validatePublication(request.pack)
      } else if (request.action === 'submit-publication') {
        const id = requiredHarnessId(request.id)
        const localPack = this.ctx.harnesses.require(id)
        const publicPack = await this.ctx.harnesses.validatePublication(localPack)
        const token = await githubAuthorization(this.ctx)
        const submission = await submitOpenFishCommunityPack(publicPack, token, signal)
        await this.ctx.harnesses.recordCommunitySubmission({
          id: publicPack.id,
          version: publicPack.version,
          reviewUrl: submission.reviewUrl,
          branch: submission.branch,
          submittedAt: submission.submittedAt,
          review: 'pending',
        })
      } else if (request.action === 'submit-revocation') {
        const current = await this.ctx.harnesses.describe(requiredHarnessId(request.id))
        if (request.reason === undefined) throw new Error('A public revocation reason is required')
        if (current.publication?.status !== 'published') {
          throw new Error('Only an exact Pack version already present in the reviewed community catalog can be revoked')
        }
        const token = await githubAuthorization(this.ctx)
        const submission = await submitOpenFishCommunityRevocation({
          id: current.id,
          version: current.version,
          reason: request.reason,
        }, token, signal)
        await this.ctx.harnesses.recordCommunityRevocationSubmission({
          id: current.id,
          version: current.version,
          reviewUrl: submission.reviewUrl,
          branch: submission.branch,
          submittedAt: submission.submittedAt,
          review: 'pending',
        })
      } else {
        const id = requiredHarnessId(request.id)
        if (request.action === 'remove') {
          await this.ctx.harnesses.removeUserPack(id)
        } else {
          if (request.authMethod === undefined) throw new Error('A terminal authentication method is required')
          await this.ctx.harnesses.authenticateInteractive(id, request.authMethod, signal)
        }
      }
      signal.throwIfAborted()
      return { items: await this.ctx.harnesses.list() }
    } catch (error: unknown) {
      if (signal.aborted) fail('cancelled', `Harness ${request.action} was cancelled`)
      throw harnessFailure(error, `Harness ${request.action} failed`)
    }
  }
}

async function ensureInstalled(ctx: Context, id: HarnessId, signal: AbortSignal): Promise<void> {
  const candidate = await ctx.harnesses.describe(id)
  if (candidate.installation.status !== 'builtin' && candidate.installation.status !== 'installed') {
    await ctx.harnesses.install(id, signal)
  }
}

function harnessId(value: string): HarnessId {
  if (!/^[a-z0-9][a-z0-9._-]*$/u.test(value)) fail('harness-failed', 'Harness id is invalid')
  return value as HarnessId
}

function requiredHarnessId(value: string | undefined): HarnessId {
  if (value === undefined) fail('harness-selection-required', 'A Harness id is required')
  return harnessId(value)
}

async function githubAuthorization(ctx: Context): Promise<string> {
  const credentials = ctx.get('credentials')
  if (credentials === undefined) {
    throw new Error('The Host does not provide a credential service for GitHub authorization')
  }
  const authorization = await credentials.resolve(credentialRef(OPENFISH_GITHUB_TOKEN_REF))
  if (authorization === undefined) {
    throw new Error('GitHub authorization is not configured; store it in Keychain before submitting')
  }
  return authorization.value
}

function harnessFailure(error: unknown, fallback: string): TypertRemoteFailure {
  const message = safeHarnessDiagnostic(error, fallback)
  const lower = message.toLocaleLowerCase()
  const code = lower.includes('checksum') || lower.includes('integrity')
    ? 'harness-integrity-failed'
    : lower.includes('credential') || lower.includes('auth') || lower.includes('login')
      ? 'harness-auth-required'
      : lower.includes('install') || lower.includes('download') || lower.includes('extract')
        ? 'harness-install-failed'
        : lower.includes('resume')
          ? 'harness-resume-failed'
          : lower.includes('launch') || lower.includes('start') || lower.includes('connection closed')
            ? 'harness-start-failed'
            : 'harness-failed'
  return new TypertRemoteFailure({ code, message, details: {} })
}

function fail(code: string, message: string): never {
  throw new TypertRemoteFailure({ code, message, details: {} })
}

/** Cordis Loader entry for the Host Harness control plane. */
export default HarnessController

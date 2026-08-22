/** Package-owned invariant companion for the ACP Harness driver. @module */
import type { Context } from '@deepseek-ai/cordis'
import type { InvariantInstaller } from '@deepseek-ai/dsh-invariants'
const PACKAGE_NAME = '@deepseek-ai/dsh-harness-acp'
export const name = 'harness-acp-invariant'
export const inject = ['invariants']

/** No additional runtime invariant: the Harness package owns durable record relations. */
const install: InvariantInstaller = () => {}

export const apply = (ctx: Context): Promise<() => void> =>
  Promise.resolve(ctx.invariants.register(PACKAGE_NAME, install))

import { spawn } from 'node:child_process'
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join, resolve } from 'node:path'
import { describe, it } from 'vitest'
import { fixtureUserPrompts, launchWebScaffold } from './scaffold.ts'

const behaviorBinary = process.env.OPENCODEX_BEHAVIOR_BINARY

describe.skipIf(behaviorBinary === undefined)('OpenCodex native composed-runtime behavior smoke', () => {
  it('sends, answers approval, observes the tool result, and resumes after restart', async () => {
    if (behaviorBinary === undefined) throw new Error('OPENCODEX_BEHAVIOR_BINARY must name the compiled Swift smoke binary')

    process.env.DSH_SNAPSHOT = 'replay'
    const fixture = resolve(import.meta.dirname, 'snapshots/approval-composer/session.jsonl')
    const prompts = fixtureUserPrompts(await readFile(fixture, 'utf8'))
    const prompt = prompts[0]
    if (prompt === undefined || prompts.length !== 1) {
      throw new Error('approval-composer replay fixture must contain exactly one user prompt')
    }

    const scaffold = await launchWebScaffold({
      extraOverlayPath: resolve(import.meta.dirname, 'fixtures/opencodex-native.patch.yml'),
      replayFixture: fixture,
      paceMs: 1,
    })
    let primaryFailure: unknown
    try {
      const workspace = join(scaffold.workspaceCwd, 'workspace')
      const promptFile = join(scaffold.workspaceCwd, 'opencodex-behavior-prompt.txt')
      await mkdir(workspace, { recursive: true })
      await writeFile(promptFile, prompt)

      await new Promise<void>((resolveRun, rejectRun) => {
        const child = spawn(behaviorBinary, [scaffold.baseUrl, workspace, promptFile], {
          stdio: ['ignore', 'inherit', 'inherit'],
        })
        child.once('error', rejectRun)
        child.once('exit', (code, signal) => {
          if (code === 0) resolveRun()
          else rejectRun(new Error(`Swift behavior smoke exited with code ${String(code)} signal ${String(signal)}`))
        })
      })
    } catch (error) {
      primaryFailure = error
    } finally {
      try {
        await scaffold.close()
      } catch (error) {
        primaryFailure = primaryFailure === undefined
          ? error
          : new AggregateError([primaryFailure, error], 'behavior smoke and scaffold teardown both failed')
      }
    }

    if (primaryFailure !== undefined) throw primaryFailure
  }, 120_000)
})

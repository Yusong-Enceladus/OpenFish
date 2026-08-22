import { Context } from '@deepseek-ai/cordis'
import { credentialRef } from '@deepseek-ai/dsh-credentials'
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { tmpdir } from 'node:os'
import { describe, expect, it } from 'vitest'
import { KeychainCredentials, type KeychainExecutor } from '../src/index.ts'

class MemoryKeychain implements KeychainExecutor {
  readonly values = new Map<string, string>()
  async get(account: string): Promise<string | undefined> { return this.values.get(account) }
  async set(account: string, value: string): Promise<void> { this.values.set(account, value) }
  async remove(account: string): Promise<void> { this.values.delete(account) }
}

describe('OpenFish Keychain credentials', () => {
  it('stores and describes a credential without exposing it through describe', async () => {
    const executor = new MemoryKeychain()
    const provider = new KeychainCredentials(new Context(), {}, executor)
    const ref = credentialRef('OPENAI_API_KEY')
    await provider.set(ref, 'secret-value')
    expect(await provider.describe(ref)).toEqual({ configured: true, source: 'keychain', writable: true })
    expect(await provider.resolve(ref)).toEqual({ value: 'secret-value', source: 'keychain' })
    await provider.unset(ref)
    expect(await provider.resolve(ref)).toBeUndefined()
  })

  it('imports an owner-only legacy file and removes plaintext only after Keychain writes succeed', async () => {
    const root = await mkdtemp(join(tmpdir(), 'openfish-keychain-'))
    try {
      const legacyPath = join(root, '.credentials.yaml')
      await writeFile(legacyPath, 'OPENAI_API_KEY: imported-secret\n', { mode: 0o600 })
      const executor = new MemoryKeychain()
      const provider = new KeychainCredentials(new Context(), { legacyPath }, executor)
      expect(await provider.resolve(credentialRef('OPENAI_API_KEY'))).toEqual({ value: 'imported-secret', source: 'keychain' })
      await expect(stat(legacyPath)).rejects.toMatchObject({ code: 'ENOENT' })
    } finally {
      await rm(root, { recursive: true, force: true })
    }
  })

  it('keeps inherited environment credentials read-only and ahead of Keychain', async () => {
    const executor = new MemoryKeychain()
    executor.values.set('openfish:OPENFISH_TEST_API_KEY', 'stored-secret')
    const previous = process.env.OPENFISH_TEST_API_KEY
    process.env.OPENFISH_TEST_API_KEY = 'environment-secret'
    try {
      const provider = new KeychainCredentials(new Context(), {}, executor)
      const ref = credentialRef('OPENFISH_TEST_API_KEY')
      expect(await provider.resolve(ref)).toEqual({ value: 'environment-secret', source: 'env' })
      expect(await provider.describe(ref)).toEqual({ configured: true, source: 'env', writable: false })
      await expect(provider.set(ref, 'replacement')).rejects.toThrow('inherited environment shadows')
    } finally {
      if (previous === undefined) delete process.env.OPENFISH_TEST_API_KEY
      else process.env.OPENFISH_TEST_API_KEY = previous
    }
  })
})

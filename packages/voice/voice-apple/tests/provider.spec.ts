import { Context } from '@deepseek-ai/cordis'
import { describe, expect, it } from 'vitest'
import Voice from '@deepseek-ai/dsh-voice'
import { apply } from '../src/index.ts'

describe('Apple voice provider', () => {
  it('declares both local operations for native Consumers', () => {
    const ctx = new Context()
    new Voice(ctx)
    apply(ctx)
    expect(ctx.voice.list('macos')[0]).toMatchObject({
      id: 'apple-local',
      locality: 'device',
      operations: ['speech-to-text', 'text-to-speech'],
    })
  })
})

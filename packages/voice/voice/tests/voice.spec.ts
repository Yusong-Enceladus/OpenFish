import { Context } from '@deepseek-ai/cordis'
import { describe, expect, it } from 'vitest'
import Voice from '../src/index.ts'

describe('voice capability definition', () => {
  it('registers immutable platform providers and exposes the DSH transcript boundary', () => {
    const voice = new Voice(new Context())
    const dispose = voice.register({
      id: 'apple-local',
      name: 'Apple On-Device Speech',
      platforms: ['macos', 'iphone'],
      operations: ['speech-to-text', 'text-to-speech'],
      locality: 'device',
      streaming: true,
      interruptible: true,
      quality: 'premium',
    })
    expect(voice.describe()).toMatchObject({
      contract: 'dsh.voice.v1',
      transcriptAuthority: 'session.prompt',
    })
    expect(voice.list('web')).toEqual([])
    expect(voice.list('iphone').map(provider => provider.id)).toEqual(['apple-local'])
    dispose()
    expect(voice.list()).toEqual([])
  })
})

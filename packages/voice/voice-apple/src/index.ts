/** Apple on-device STT/TTS provider declaration for DSH voice Consumers. */

import type { Context } from '@deepseek-ai/cordis'
import type {} from '@deepseek-ai/dsh-voice'

export const name = 'voice-apple'
export const inject = ['voice']

export function apply(ctx: Context): void {
  ctx.effect(() => ctx.voice.register({
    id: 'apple-local',
    name: 'Apple On-Device Speech',
    platforms: ['macos', 'iphone'],
    operations: ['speech-to-text', 'text-to-speech'],
    locality: 'device',
    streaming: true,
    interruptible: true,
    quality: 'premium',
  }), 'voice-apple: provider')
}

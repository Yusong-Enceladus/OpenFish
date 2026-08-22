/**
 * DSH-owned voice capability definition.
 *
 * Audio capture, recognition, and playback stay on the presentation device.
 * This service owns the portable provider vocabulary and selection boundary;
 * completed transcripts enter the ordinary DSH session through session.prompt.
 */

import { Context, Service } from '@deepseek-ai/cordis'

/** Audio operation implemented by a device-local voice Provider. */
export type VoiceOperation = 'speech-to-text' | 'text-to-speech'
/** Presentation platform on which a voice Provider can execute. */
export type VoicePlatform = 'macos' | 'iphone' | 'web'

/** One replaceable device-local provider offered by the product composition. */
export interface VoiceProviderDescriptor {
  /** Stable implementation identity understood by the platform adapter. */
  readonly id: string
  /** User-facing provider name. */
  readonly name: string
  /** Presentation platforms that can execute this provider. */
  readonly platforms: readonly VoicePlatform[]
  /** Operations implemented by the provider. */
  readonly operations: readonly VoiceOperation[]
  /** Audio never leaves the presentation device. */
  readonly locality: 'device'
  /** Partial STT or progressive TTS is supported. */
  readonly streaming: boolean
  /** Playback/listening may be interrupted without restarting DSH. */
  readonly interruptible: boolean
  /** Provider quality tier used by the Consumer's selection UI. */
  readonly quality: 'standard' | 'enhanced' | 'premium'
}

/** Immutable description exposed to voice Consumers during bootstrap. */
export interface VoiceCapabilities {
  readonly contract: 'dsh.voice.v1'
  readonly transcriptAuthority: 'session.prompt'
  readonly providers: readonly VoiceProviderDescriptor[]
}

declare module '@deepseek-ai/cordis' {
  interface Context {
    voice: Voice
  }
}

/** Provider registry and immutable capability description. */
export class Voice extends Service {
  private readonly providers = new Map<string, VoiceProviderDescriptor>()

  constructor(ctx: Context) {
    super(ctx, 'voice')
  }

  /**
   * Register one device-local voice Provider for this plugin lifecycle.
   * @param provider - Stable capability descriptor for the platform adapter.
   * @returns A disposer that withdraws the Provider.
   */
  register(provider: VoiceProviderDescriptor): () => void {
    if (provider.id.trim() === '') throw new TypeError('voice provider id must be non-empty')
    if (this.providers.has(provider.id)) throw new Error(`voice provider "${provider.id}" is already registered`)
    if (provider.platforms.length === 0 || provider.operations.length === 0) {
      throw new TypeError('voice provider must declare at least one platform and operation')
    }
    const stored: VoiceProviderDescriptor = Object.freeze({
      ...provider,
      platforms: Object.freeze([...new Set(provider.platforms)]),
      operations: Object.freeze([...new Set(provider.operations)]),
    })
    this.providers.set(stored.id, stored)
    return () => { this.providers.delete(stored.id) }
  }

  /**
   * List registered Providers, optionally restricted to one platform.
   * @param platform - Optional presentation platform filter.
   * @returns Providers sorted by stable identifier.
   */
  list(platform?: VoicePlatform): readonly VoiceProviderDescriptor[] {
    return [...this.providers.values()]
      .filter(provider => platform === undefined || provider.platforms.includes(platform))
      .sort((left, right) => left.id.localeCompare(right.id))
  }

  /**
   * Describe the portable voice contract and its current Providers.
   * @returns A fresh immutable-capability value for bootstrap Consumers.
   */
  describe(): VoiceCapabilities {
    return {
      contract: 'dsh.voice.v1',
      transcriptAuthority: 'session.prompt',
      providers: this.list(),
    }
  }
}

export default Voice

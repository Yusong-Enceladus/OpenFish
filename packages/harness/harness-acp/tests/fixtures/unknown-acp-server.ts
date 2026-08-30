import { Readable, Writable } from 'node:stream'
import { existsSync, writeFileSync } from 'node:fs'
import {
  agent,
  methods,
  ndJsonStream,
  PROTOCOL_VERSION,
} from '@agentclientprotocol/sdk'

const REMOTE_SESSION_ID = 'future-remote-session'
const lifecycleMarker = process.env.OPENFISH_ACP_LIFECYCLE_MARKER
const resumeMethod = process.env.OPENFISH_ACP_RESUME_METHOD ?? 'resume'
let currentModel = 'future/model-a'
let currentReasoning = 'deep'
const configOptions = () => [{
  id: 'model',
  name: 'Model',
  category: 'model' as const,
  type: 'select' as const,
  currentValue: currentModel,
  options: [
    { value: 'future/model-a', name: 'Future Model A' },
    { value: 'future/model-b', name: 'Future Model B' },
  ],
}, {
  id: 'reasoning',
  name: 'Reasoning',
  category: 'thought_level' as const,
  type: 'select' as const,
  currentValue: currentReasoning,
  options: [
    { value: 'quick', name: 'Quick' },
    { value: 'deep', name: 'Deep' },
  ],
}]

const connection = agent({ name: 'future-synthetic-acp' })
  .onRequest(methods.agent.initialize, () => ({
    protocolVersion: PROTOCOL_VERSION,
    agentCapabilities: {
      loadSession: resumeMethod === 'load',
      sessionCapabilities: {
        ...(resumeMethod === 'resume' ? { resume: {} } : {}),
        ...(lifecycleMarker === undefined ? {} : { delete: {}, close: {} }),
      },
      promptCapabilities: { image: false, audio: false, embeddedContext: false },
    },
    authMethods: [],
  }))
  .onRequest(methods.agent.session.new, () => ({ sessionId: REMOTE_SESSION_ID, configOptions: configOptions() }))
  .onRequest(methods.agent.session.resume, () => {
    if (resumeMethod !== 'resume') throw new Error('session/resume was not advertised')
    return { configOptions: configOptions() }
  })
  .onRequest(methods.agent.session.load, () => {
    if (resumeMethod !== 'load') throw new Error('session/load was not advertised')
    return { configOptions: configOptions() }
  })
  .onRequest(methods.agent.session.delete, () => {
    if (lifecycleMarker === undefined) throw new Error('session/delete was not advertised')
    writeFileSync(lifecycleMarker, 'deleted\n', { mode: 0o600, flag: 'a' })
  })
  .onRequest(methods.agent.session.close, () => {
    if (lifecycleMarker === undefined) throw new Error('session/close was not advertised')
    writeFileSync(lifecycleMarker, 'closed\n', { mode: 0o600, flag: 'a' })
  })
  .onRequest(methods.agent.session.setConfigOption, async ({ params }) => {
    if (params.configId === 'model' && typeof params.value === 'string') currentModel = params.value
    if (params.configId === 'reasoning' && typeof params.value === 'string') currentReasoning = params.value
    const delay = Number.parseInt(process.env.OPENFISH_ACP_CONFIG_DELAY_MS ?? '0', 10)
    if (Number.isFinite(delay) && delay > 0) {
      await new Promise(resolve => setTimeout(resolve, delay))
    }
    return { configOptions: configOptions() }
  })
  .onRequest(methods.agent.authenticate, () => undefined)
  .onRequest(methods.agent.session.prompt, async ({ params, client }) => {
    const crashMarker = process.env.OPENFISH_ACP_CRASH_ONCE_MARKER
    if (crashMarker !== undefined && !existsSync(crashMarker)) {
      writeFileSync(crashMarker, 'crashed-once\n', { mode: 0o600 })
      process.exit(72)
    }
    const prompt = params.prompt
      .filter(block => block.type === 'text')
      .map(block => block.text)
      .join('')
    if (prompt === 'auth-expired') {
      throw new Error('authentication expired; access_token=sk-test-supersecret123456')
    }
    if (prompt === 'quota-failure') {
      throw new Error('provider quota exceeded; authorization=Bearer sk-test-supersecret123456')
    }
    await client.notify(methods.client.session.update, {
      sessionId: params.sessionId,
      update: {
        sessionUpdate: 'agent_message_chunk',
        content: { type: 'text', text: `future:${prompt}` },
      },
    })
    return { stopReason: 'end_turn' }
  })
  .onNotification(methods.agent.session.cancel, () => undefined)
  .connect(ndJsonStream(
    Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
    Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
  ))
void connection

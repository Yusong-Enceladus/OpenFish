import { Readable, Writable } from 'node:stream'
import {
  AgentSideConnection,
  ndJsonStream,
  PROTOCOL_VERSION,
  type Agent,
  type InitializeResponse,
  type NewSessionResponse,
  type PromptResponse,
  type ResumeSessionResponse,
} from '@agentclientprotocol/sdk'

const REMOTE_SESSION_ID = 'future-remote-session'
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

function makeAgent(connection: AgentSideConnection): Agent {
  return {
    initialize(): Promise<InitializeResponse> {
      return Promise.resolve({
        protocolVersion: PROTOCOL_VERSION,
        agentCapabilities: {
          sessionCapabilities: { resume: {} },
          promptCapabilities: { image: false, audio: false, embeddedContext: false },
        },
        authMethods: [],
      })
    },
    newSession(): Promise<NewSessionResponse> {
      return Promise.resolve({ sessionId: REMOTE_SESSION_ID, configOptions: configOptions() })
    },
    resumeSession(): Promise<ResumeSessionResponse> {
      return Promise.resolve({ configOptions: configOptions() })
    },
    async setSessionConfigOption(params) {
      if (params.configId === 'model' && typeof params.value === 'string') currentModel = params.value
      if (params.configId === 'reasoning' && typeof params.value === 'string') currentReasoning = params.value
      const delay = Number.parseInt(process.env.OPENFISH_ACP_CONFIG_DELAY_MS ?? '0', 10)
      if (Number.isFinite(delay) && delay > 0) {
        await new Promise(resolve => setTimeout(resolve, delay))
      }
      return { configOptions: configOptions() }
    },
    authenticate(): Promise<void> { return Promise.resolve() },
    async prompt(params): Promise<PromptResponse> {
      const prompt = params.prompt
        .filter(block => block.type === 'text')
        .map(block => block.text)
        .join('')
      await connection.sessionUpdate({
        sessionId: params.sessionId,
        update: {
          sessionUpdate: 'agent_message_chunk',
          content: { type: 'text', text: `future:${prompt}` },
        },
      })
      return { stopReason: 'end_turn' }
    },
    cancel(): Promise<void> { return Promise.resolve() },
  }
}

const connection = new AgentSideConnection(
  makeAgent,
  ndJsonStream(
    Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
    Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
  ),
)
void connection

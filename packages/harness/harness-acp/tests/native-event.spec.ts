import { describe, expect, it } from 'vitest'
import { durableAcpSessionUpdate, durableCodexNotification } from '../src/native-event.ts'

describe('durable native Harness event projection', () => {
  it('does not duplicate ACP model output or base64 media', () => {
    expect(durableAcpSessionUpdate({
      sessionUpdate: 'agent_message_chunk',
      content: { type: 'text', text: 'hello' },
    })).toBeUndefined()
    expect(durableAcpSessionUpdate({
      sessionUpdate: 'agent_message_chunk',
      content: { type: 'image', mimeType: 'image/png', data: 'private-base64' },
    })).toBeUndefined()
  })

  it('keeps bounded ACP tool presentation while removing secret fields and binary content', () => {
    const event = durableAcpSessionUpdate({
      sessionUpdate: 'tool_call',
      toolCallId: 'tool-1',
      title: 'Run command',
      rawInput: { command: 'echo ok', accessToken: 'private-token-value' },
      content: [
        { type: 'content', content: { type: 'image', mimeType: 'image/png', data: 'private-base64' } },
        { type: 'content', content: { type: 'text', text: 'done' } },
      ],
    })
    const encoded = JSON.stringify(event)
    expect(encoded).toContain('Run command')
    expect(encoded).toContain('done')
    expect(encoded).not.toContain('private-token-value')
    expect(encoded).not.toContain('private-base64')
  })

  it('persists only minimal Codex lifecycle and non-message item facts', () => {
    expect(durableCodexNotification('account/updated', { accessToken: 'private' })).toBeUndefined()
    expect(durableCodexNotification('item/completed', {
      threadId: 'thread-1', turnId: 'turn-1',
      item: { id: 'message-1', type: 'agentMessage', text: 'duplicate answer' },
    })).toBeUndefined()
    const tool = durableCodexNotification('item/completed', {
      threadId: 'thread-1', turnId: 'turn-1',
      item: {
        id: 'command-1', type: 'commandExecution', command: 'pwd', status: 'completed',
        result: { password: 'private', output: 'workspace' },
      },
    })
    expect(tool).toEqual({
      method: 'item/completed',
      params: {
        threadId: 'thread-1', turnId: 'turn-1', item: {
          id: 'command-1', type: 'commandExecution', status: 'completed', command: 'pwd',
          result: { password: '[redacted]', output: 'workspace' },
        },
      },
    })
    expect(durableCodexNotification('turn/completed', {
      threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed', items: ['omitted'] },
    })).toEqual({
      method: 'turn/completed',
      params: { threadId: 'thread-1', turn: { id: 'turn-1', status: 'completed' } },
    })
  })
})

/**
 * Pins the protocol order for opcode 107 (state update with merged events):
 * the frame's events are routed before its state update is applied, so a cycle's
 * events precede that cycle's state on the client.
 */

import { describe, it, expect, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { MessageKindOpcode, StateUpdateOpcode, StatePatchOpcode, EventDirection } from './protocol'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'

describe('StateTreeRuntime opcode 107 ordering', () => {
  it('routes the frame events before applying its state update', async () => {
    const runtime = new StateTreeRuntime({
      transportEncoding: {
        message: MessageEncodingValues.opcodeJsonArray,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray
      }
    })
    const view = runtime.createView('test-land', {
      schema: {
        version: '1.0.0',
        lands: { 'test-land': { stateType: 'TestState' } },
        defs: { TestState: { type: 'object', properties: { score: { type: 'integer' } } } }
      } as any
    })

    const order: string[] = []
    vi.spyOn(view, 'handleTransportMessage').mockImplementation((message) => {
      order.push(`event:${(message.payload as any).fromServer?.type}`)
    })
    vi.spyOn(view, 'handleStateUpdate').mockImplementation(() => {
      order.push('state')
    })

    const statePayload = [StateUpdateOpcode.diff, ['/score', StatePatchOpcode.replace, 10]]
    const eventsPayload = [
      [EventDirection.fromServer, 'AttackHit', { damage: 3 }],
      [EventDirection.fromServer, 'MonsterDied', { id: 7 }]
    ]
    const frame = JSON.stringify([MessageKindOpcode.stateUpdateWithEvents, statePayload, eventsPayload])

    // handleMessage is the WebSocket onmessage handler; call it directly with one frame.
    await (runtime as any).handleMessage(frame)

    expect(order).toEqual(['event:AttackHit', 'event:MonsterDied', 'state'])
  })
})

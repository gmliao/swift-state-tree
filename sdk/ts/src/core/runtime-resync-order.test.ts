/**
 * The frames at a resync's sequence (#332): the server sends the snapshot (opcode 3) first, then
 * the merged broadcast frame (opcode 107) with the same sequence. The runtime applies the
 * snapshot, reads the 107 frame's events, and skips its state patches, which the snapshot
 * already holds: no partial `onAdd`, one `onStateUpdate`, and the ack follows the snapshot.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { StateUpdateFeatures, StatePatchOpcode } from './protocol'

const schema = {
  version: '1.0.0',
  lands: { 'test-land': { stateType: 'TestState' } },
  defs: {
    Player: { type: 'object', properties: { hp: { type: 'integer' }, name: { type: 'string' } } },
    TestState: {
      type: 'object',
      properties: {
        score: { type: 'integer' },
        players: { type: 'object', additionalProperties: { $ref: '#/defs/Player' } }
      }
    }
  }
} as any

function setup() {
  vi.useFakeTimers()
  const onStateUpdate = vi.fn()
  const runtime = new StateTreeRuntime({
    transportEncoding: { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray' }
  })
  const view = runtime.createView('test-land', { schema, onStateUpdate } as any)
  const sent: unknown[] = []
  ;(runtime as any).ws = { send: (data: unknown) => sent.push(data), close: () => {} }
  ;(runtime as any).isConnected = true
  runtime.updateStateUpdateFeatures([StateUpdateFeatures.syncSequence])
  const handle = (frame: unknown) => (runtime as any).handleMessage(JSON.stringify(frame))
  return { runtime, view, sent, handle, onStateUpdate }
}

afterEach(() => {
  vi.useRealTimers()
})

describe('frames at a resync sequence', () => {
  it('skips the merged frame patches after the snapshot: no partial onAdd, one onStateUpdate, the ack after the snapshot', async () => {
    const { runtime, view, sent, handle, onStateUpdate } = setup()
    await handle([1, 5, ['/score', StatePatchOpcode.replace, 1], ['/players/a', StatePatchOpcode.replace, { hp: 10, name: 'A' }]])
    const players = view.createMapSubscriptions('/players', (s: any) => s.players)
    const added: Array<[string, any]> = []
    players.onAdd((key: string, value: any) => added.push([key, value]))
    added.length = 0
    onStateUpdate.mockClear()
    sent.length = 0

    // The snapshot: `x` joined in frames this client never got.
    await handle([
      3, 9,
      ['/score', StatePatchOpcode.replace, 4],
      ['/players/a', StatePatchOpcode.replace, { hp: 10, name: 'A' }],
      ['/players/x', StatePatchOpcode.replace, { hp: 7, name: 'X' }]
    ])
    expect(sent).toEqual(['[108,9]'])
    expect(added.map(([key]) => key)).toEqual(['x'])
    expect(onStateUpdate).toHaveBeenCalledTimes(1)

    // The merged broadcast frame at the same sequence, touching only `x.hp`, plus an event.
    const event = vi.spyOn(view, 'handleTransportMessage')
    await handle([107, [1, 9, ['/players/x/hp', StatePatchOpcode.replace, 7]], [[1, 'Hit', { damage: 1 }]]])
    expect(event).toHaveBeenCalledTimes(1)
    expect(added.map(([key]) => key)).toEqual(['x'])
    expect(added[0][1]).toEqual({ hp: 7, name: 'X' })
    expect(onStateUpdate).toHaveBeenCalledTimes(1)
    expect(view.getState()).toEqual({
      score: 4,
      players: { a: { hp: 10, name: 'A' }, x: { hp: 7, name: 'X' } }
    })

    // The next sequence applies as usual.
    await handle([2, 10, ['/players/x/hp', StatePatchOpcode.replace, 6]])
    expect((view.getState() as any).players.x.hp).toBe(6)
    expect(onStateUpdate).toHaveBeenCalledTimes(2)
    runtime.disconnect()
  })
})

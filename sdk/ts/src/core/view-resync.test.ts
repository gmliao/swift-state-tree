/**
 * The in-place resync (#332): a resync update (opcode 3) replaces the view by reconciling it,
 * so only the net changes are notified, and `onResync` follows as a hint.
 */
import { describe, it, expect, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { decodeMessage, StateUpdateFeatures } from './protocol'
import type { StatePatch, StateUpdate, TransportEncodingConfig } from '../types/transport'

const schema = {
  version: '1.0.0',
  lands: { 'test-land': { stateType: 'TestState' } },
  defs: {
    Player: { type: 'object', properties: { hp: { type: 'integer' }, name: { type: 'string' } } },
    TestState: {
      type: 'object',
      properties: {
        score: { type: 'integer' },
        players: { type: 'object', additionalProperties: { $ref: '#/defs/Player' } },
        rooms: {
          type: 'object',
          additionalProperties: { type: 'object', additionalProperties: { type: 'integer' } }
        }
      }
    }
  }
} as any

function makeView(options: Record<string, unknown> = {}) {
  const runtime = new StateTreeRuntime()
  const view = runtime.createView('test-land', { schema, ...options } as any)
  view.handleStateUpdate({
    type: 'firstSync',
    patches: [
      { op: 'replace', path: '/score', value: 1 },
      { op: 'replace', path: '/players/a', value: { hp: 10, name: 'A' } },
      { op: 'replace', path: '/players/b', value: { hp: 5, name: 'B' } },
      { op: 'replace', path: '/rooms/r1', value: { x: 1, y: 2 } }
    ]
  })
  return view
}

const resync: StateUpdate = {
  type: 'resync',
  patches: [
    { op: 'replace', path: '/score', value: 1 },
    { op: 'replace', path: '/players/a', value: { hp: 7, name: 'A' } },
    { op: 'replace', path: '/players/c', value: { hp: 3, name: 'C' } },
    { op: 'replace', path: '/rooms/r1', value: { x: 1, z: 4 } }
  ]
}

describe('in-place resync', () => {
  it('notifies only the net map changes', () => {
    const view = makeView()
    const players = view.createMapSubscriptions('/players', (s: any) => s.players)
    const added: string[] = []
    const removed: string[] = []
    players.onAdd((key: string) => added.push(key))
    players.onRemove((key: string) => removed.push(key))
    added.length = 0

    view.handleStateUpdate(resync)

    expect(added).toEqual(['c'])
    expect(removed).toEqual(['b'])
    expect(view.getState()).toEqual({
      score: 1,
      players: { a: { hp: 7, name: 'A' }, c: { hp: 3, name: 'C' } },
      rooms: { r1: { x: 1, z: 4 } }
    })
  })

  it('handles nested maps the same way', () => {
    const view = makeView()
    const room = view.createMapSubscriptions('/rooms/r1', (s: any) => s.rooms?.r1)
    const added: string[] = []
    const removed: string[] = []
    room.onAdd((key: string) => added.push(key))
    room.onRemove((key: string) => removed.push(key))
    added.length = 0

    view.handleStateUpdate(resync)

    expect(added).toEqual(['z'])
    expect(removed).toEqual(['y'])
  })

  it('gives onPatch the net changes, and fires onStateUpdate once and onResync after it', () => {
    const order: string[] = []
    const patches: StatePatch[] = []
    const view = makeView({
      onPatch: (patch: StatePatch) => patches.push(patch),
      onStateUpdate: () => order.push('state'),
      onResync: () => order.push('resync')
    })
    patches.length = 0
    order.length = 0

    view.handleStateUpdate(resync)

    expect(patches.map((p) => `${p.op} ${p.path}`).sort()).toEqual([
      'add /players/c',
      'add /rooms/r1/z',
      'remove /players/b',
      'remove /rooms/r1/y',
      'replace /players/a/hp'
    ])
    expect(patches.find((p) => p.path === '/players/a/hp')?.value).toBe(7)
    expect(order).toEqual(['state', 'resync'])
  })

  it('leaves an unchanged view without notifications but still fires onResync', () => {
    const onPatch = vi.fn()
    const onResync = vi.fn()
    const view = makeView({ onPatch, onResync })
    onPatch.mockClear()
    view.handleStateUpdate({
      type: 'resync',
      patches: [
        { op: 'replace', path: '/score', value: 1 },
        { op: 'replace', path: '/players/a', value: { hp: 10, name: 'A' } },
        { op: 'replace', path: '/players/b', value: { hp: 5, name: 'B' } },
        { op: 'replace', path: '/rooms/r1', value: { x: 1, y: 2 } }
      ]
    })
    expect(onPatch).not.toHaveBeenCalled()
    expect(onResync).toHaveBeenCalledTimes(1)
  })
})

describe('resync update decoding', () => {
  const config: TransportEncodingConfig = {
    message: 'json',
    stateUpdate: 'opcodeJsonArray',
    stateUpdateFeatures: [StateUpdateFeatures.syncSequence]
  }

  it('decodes opcode 3 as a resync and resets the per-player key map, as a firstSync does', () => {
    const keys = new Map<number, string>([[0, 'stale']])
    const update = decodeMessage('[3,12,["/score",1,4]]', config, keys) as StateUpdate
    expect(update.type).toBe('resync')
    expect(update.seq).toBe(12)
    expect(keys.has(0)).toBe(false)
  })
})

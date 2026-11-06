import { describe, it, expect, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import type { StateUpdate } from '../types/transport'

// #219: a `firstSync` update is not always a complete view. The server also types an update
// `firstSync` to reset a dynamic key scope (`keyScopeResetPending`, a new joiner's broadcast
// reset): its patches are the normal diff, and clients apply them onto their view like a diff.
// So the view must never clear its state on a firstSync. A reconnect gets an exact rebuild
// because the runtime destroys its views on close and the new view starts empty.

const schema = {
  version: '1.0.0',
  lands: { 'test-land': { stateType: 'TestState' } },
  defs: {
    TestState: {
      type: 'object',
      properties: {
        players: { type: 'object', additionalProperties: { $ref: '#/defs/Player' } },
        round: { type: 'integer' }
      }
    },
    Player: { type: 'object', properties: { name: { type: 'string' } } }
  }
} as any

function makeView(onStateUpdate: (state: any) => void = () => {}) {
  const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() }
  return new StateTreeRuntime().createView('test-land', { logger, schema, onStateUpdate })
}

describe('firstSync semantics (#219)', () => {
  it('a key-scope-reset firstSync on a synced view patches in place and keeps the rest', () => {
    const onStateUpdate = vi.fn()
    const view = makeView(onStateUpdate)
    view['handleStateUpdate']({
      type: 'firstSync',
      patches: [
        { path: '/players', op: 'replace', value: { a: { name: 'A' }, b: { name: 'B' } } },
        { path: '/round', op: 'replace', value: 1 }
      ]
    } as StateUpdate)
    const subscriptions = view.createMapSubscriptions<{ name: string }>('/players', (state) => state?.players)
    const removed = vi.fn()
    subscriptions.onRemove(removed)
    onStateUpdate.mockClear()

    // Another player joins: the server's broadcast frame is typed firstSync (key scope reset),
    // carrying only the change.
    view['handleStateUpdate']({
      type: 'firstSync',
      patches: [{ path: '/players/c', op: 'replace', value: { name: 'C' } }]
    } as StateUpdate)

    expect(view.getState()).toEqual({
      players: { a: { name: 'A' }, b: { name: 'B' }, c: { name: 'C' } },
      round: 1
    })
    expect(onStateUpdate).toHaveBeenCalledTimes(1)
    expect(removed).not.toHaveBeenCalled()
  })

  it('after a disconnect, a new view starts empty, so its firstSync is the whole state', () => {
    const runtime = new StateTreeRuntime()
    const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() }
    const old = runtime.createView('test-land', { logger, schema })
    old['handleStateUpdate']({
      type: 'firstSync',
      patches: [{ path: '/players', op: 'replace', value: { a: { name: 'A' }, b: { name: 'B' } } }]
    } as StateUpdate)

    runtime.disconnect()
    expect(old.getState()).toEqual({})

    // The server removed B while the client was away; the new join's firstSync has only A.
    const fresh = runtime.createView('test-land', { logger, schema })
    expect(fresh).not.toBe(old)
    fresh['handleStateUpdate']({
      type: 'firstSync',
      patches: [{ path: '/players', op: 'replace', value: { a: { name: 'A' } } }]
    } as StateUpdate)
    expect(fresh.getState()).toEqual({ players: { a: { name: 'A' } } })
  })
})

import { describe, it, expect, vi } from 'vitest'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import { Position2 } from './deterministic-math'
import type { StatePatch } from '../types/transport'

// #303: no second decode without a patch callback (A), type lookups cached by path pattern (B),
// the patch path split once and walked by index (C). The final-state equivalence on hero-defense
// streams is in Examples/GameDemo/ws-loadtest/tests/sdk-apply-equivalence.test.ts.

const schema: any = {
  version: '1.0.0',
  lands: { 'test-land': { stateType: 'TestState' } },
  defs: {
    TestState: {
      type: 'object',
      properties: {
        players: { type: 'object', additionalProperties: { $ref: '#/defs/Player' } },
        path: { type: 'array', items: { $ref: '#/defs/Position2' } },
        round: { type: 'integer' },
      },
    },
    Player: {
      type: 'object',
      properties: {
        name: { type: 'string' },
        position: { $ref: '#/defs/Position2' },
        players: { type: 'integer' },
      },
    },
    Position2: { type: 'object', properties: { v: { $ref: '#/defs/IVec2' } } },
    IVec2: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' } } },
  },
}

function makeView(options: Record<string, any> = {}): StateTreeView {
  const logger = { debug: vi.fn(), info: vi.fn(), warn: vi.fn(), error: vi.fn() }
  return new StateTreeView(new StateTreeRuntime(), 'test-land', { logger, schema, ...options })
}

const apply = (view: StateTreeView, patch: StatePatch) => (view as any).applyPatch(patch)
const position = (x: number, y: number) => ({ v: { x, y } })

describe('StateTreeView patch apply (#303)', () => {
  it('A: a patch callback still gets the decoded value, its own copy', () => {
    const received: any[] = []
    const view = makeView({ onPatch: (_: StatePatch, value: any) => received.push(value) })
    const listener = vi.fn()
    view.onPatch(listener)
    apply(view, { op: 'replace', path: '/players/p1/position', value: position(1000, 2000) })
    const inState = (view as any).currentState.players.p1.position
    expect(inState).toBeInstanceOf(Position2)
    expect(received[0]).toBeInstanceOf(Position2)
    expect(received[0]).toEqual(inState)
    expect(received[0]).not.toBe(inState)
    expect(listener.mock.calls[0][1]).toBeInstanceOf(Position2)
  })

  it('A: without a patch callback the value is decoded once', () => {
    const count = (view: StateTreeView) => {
      const spy = vi.spyOn(view as any, 'decodeSnapshotValue')
      apply(view, { op: 'replace', path: '/players/p1/position', value: position(1000, 2000) })
      return spy.mock.calls.length
    }
    const plain = count(makeView())
    expect(plain).toBeGreaterThan(0)
    expect(count(makeView({ onPatch: () => {} }))).toBe(2 * plain)
  })

  it('B: the type cache holds patterns, not paths: new map keys add no entries', () => {
    const view = makeView()
    apply(view, { op: 'replace', path: '/players/p0/position', value: position(0, 0) })
    const size = (view as any).typeByPattern.size
    for (let i = 1; i < 500; i++) {
      apply(view, { op: 'replace', path: `/players/p${i}/position`, value: position(i, i) })
      apply(view, { op: 'replace', path: `/path`, value: [position(i, 0)] })
    }
    apply(view, { op: 'replace', path: '/path', value: [position(1, 1)] })
    expect((view as any).typeByPattern.size).toBeLessThanOrEqual(size + 3)
    expect((view as any).currentState.players.p499.position).toBeInstanceOf(Position2)
    expect((view as any).currentState.path[0]).toBeInstanceOf(Position2)
  })

  it('B: a cached lookup equals the uncached walk, whatever the keys look like', () => {
    const view: any = makeView()
    // Map keys that are property names, digits, escaped or empty, in an order where a pattern
    // is cached by one key and then read for another.
    const paths = [
      '/players/p1/position', '/players/position/position', '/players/players/position',
      '/players/7/position', '/players/42/position/v', '/players/a~1b/position', '/players/a~0b/name',
      '/players//position', '/players/round/players', '/path/0', '/path/3/v', '/path/q', '/path/q/v', '/path/x', '/path', '/players',
      '/players/p1', '/players/name', '/round', '', '/nope/x', '/players/p1/nope',
    ]
    for (const order of [paths, [...paths].reverse()]) {
      const fresh: any = makeView()
      for (const p of order) {
        expect(fresh.getTypeForPath(p), p).toBe(view.resolveTypeForPath(p))
        if (p !== '') expect(fresh.isArrayContainerPath(p), p).toBe(view.resolveArrayContainerPath(p))
      }
    }
  })

  it('C: the walk creates missing containers, unescapes keys and removes', () => {
    const view: any = makeView()
    apply(view, { op: 'replace', path: '/round', value: 3 })
    apply(view, { op: 'add', path: '/players/a~1b/name', value: 'slash' })
    apply(view, { op: 'add', path: '/players/a~0b/position', value: position(5, 6) })
    apply(view, { op: 'add', path: '/players//name', value: 'empty' })
    expect(view.currentState.round).toBe(3)
    expect(view.currentState.players['a/b'].name).toBe('slash')
    expect(view.currentState.players['a~b'].position).toBeInstanceOf(Position2)
    expect(view.currentState.players[''].name).toBe('empty')
    apply(view, { op: 'remove', path: '/players/a~1b/name' })
    expect(view.currentState.players['a/b']).toEqual({})
    apply(view, { op: 'remove', path: '/players/a~1b' })
    expect('a/b' in view.currentState.players).toBe(false)
    apply(view, { op: 'remove', path: '/round' })
    expect('round' in view.currentState).toBe(false)
  })
})

/**
 * Atomic values sent positionally (the array of their leaves, in the schema's `leafOrder`):
 * the view rebuilds them, at every nested path, into the DeterministicMath classes.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { StateTreeRuntime } from './runtime'
import type { StateTreeView } from './view'
import { NoOpLogger } from './logger'
import { IVec2, IVec3, Position2, Velocity2, Acceleration2, Angle } from './deterministic-math'
import type { ProtocolSchema } from '../codegen/schema'

const atomic = (leafOrder: string[][]) => ({ atomic: true, leafOrder })

const schema = {
  version: '0.1.0',
  schemaHash: 'test',
  defs: {
    TestState: {
      type: 'object',
      properties: {
        position: { $ref: '#/defs/Position2' },
        velocity: { $ref: '#/defs/Velocity2' },
        acceleration: { $ref: '#/defs/Acceleration2' },
        vec: { $ref: '#/defs/IVec2' },
        vec3: { $ref: '#/defs/IVec3' },
        rotation: { $ref: '#/defs/Angle' },
        positions: { type: 'array', items: { $ref: '#/defs/Position2' } },
        // `[String: [Position2]]`: SchemaGen writes the map's value array inline.
        paths: { type: 'object', additionalProperties: { type: 'array', items: { $ref: '#/defs/Position2' } } },
        // `[Position2]?` and `[String: [Position2]]?`: an optional whose innerType is a collection def.
        maybePath: { $ref: '#/defs/Optional<Array<Position2>>' },
        maybePaths: { $ref: '#/defs/Optional<Dictionary<String, Array<Position2>>>' },
        // An optional struct holding `[Position2]`.
        maybeRoute: { $ref: '#/defs/Optional<Route>' },
        players: { type: 'object', additionalProperties: { $ref: '#/defs/PlayerState' } },
        plain: { $ref: '#/defs/PlainXY' },
      },
    },
    PlayerState: {
      type: 'object',
      properties: { position: { $ref: '#/defs/Position2' }, rotation: { $ref: '#/defs/Angle' }, hp: { type: 'integer' } },
    },
    'Optional<Array<Position2>>': { type: 'object', 'x-stateTree': { optional: true, innerType: 'Array<Position2>' } },
    'Array<Position2>': { type: 'array', items: { $ref: '#/defs/Position2' } },
    'Optional<Dictionary<String, Array<Position2>>>': {
      type: 'object',
      'x-stateTree': { optional: true, innerType: 'Dictionary<String, Array<Position2>>' },
    },
    'Dictionary<String, Array<Position2>>': {
      type: 'object',
      additionalProperties: { type: 'array', items: { $ref: '#/defs/Position2' } },
    },
    'Optional<Route>': { type: 'object', 'x-stateTree': { optional: true, innerType: 'Route' } },
    Route: { type: 'object', properties: { points: { type: 'array', items: { $ref: '#/defs/Position2' } }, name: { type: 'string' } } },
    PlainXY: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' } } },
    Position2: { type: 'object', properties: { v: { $ref: '#/defs/IVec2' } }, 'x-stateTree': atomic([['v', 'x'], ['v', 'y']]) },
    Velocity2: { type: 'object', properties: { v: { $ref: '#/defs/IVec2' } }, 'x-stateTree': atomic([['v', 'x'], ['v', 'y']]) },
    Acceleration2: { type: 'object', properties: { v: { $ref: '#/defs/IVec2' } }, 'x-stateTree': atomic([['v', 'x'], ['v', 'y']]) },
    IVec2: { type: 'object', properties: { x: { type: 'integer' }, y: { type: 'integer' } }, 'x-stateTree': atomic([['x'], ['y']]) },
    IVec3: {
      type: 'object',
      properties: { x: { type: 'integer' }, y: { type: 'integer' }, z: { type: 'integer' } },
      'x-stateTree': atomic([['x'], ['y'], ['z']]),
    },
    Angle: { type: 'object', properties: { degrees: { type: 'integer' } }, 'x-stateTree': atomic([['degrees']]) },
  },
  lands: { 'atomic-land': { stateType: 'TestState' } },
} as unknown as ProtocolSchema

class MockRuntime extends StateTreeRuntime {
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(): void {}
}

describe('StateTreeView positional atomic values', () => {
  let view: StateTreeView

  beforeEach(() => {
    view = new MockRuntime().createView('atomic-land', { schema })
    ;(view as any).isJoined = true
  })

  const replace = (path: string, value: unknown) =>
    view.handleStateUpdate({ type: 'diff', patches: [{ path, op: 'replace', value }] } as any)

  it('rebuilds every math type from its leaves, each as its own class', () => {
    view.handleSnapshot({
      values: {
        position: [64000, 36000],
        velocity: [1000, -2000],
        acceleration: [3000, 4000],
        vec: [5000, 6000],
        vec3: [7000, 8000, 9000],
        rotation: [90500],
      },
    })
    const state = view.getState() as any
    expect(state.position).toBeInstanceOf(Position2)
    expect(state.position.v.x).toBe(64.0)
    expect(state.position.v.y).toBe(36.0)
    expect(state.velocity).toBeInstanceOf(Velocity2)
    expect(state.velocity.v.y).toBe(-2.0)
    expect(state.acceleration).toBeInstanceOf(Acceleration2)
    expect(state.vec).toBeInstanceOf(IVec2)
    expect(state.vec.y).toBe(6.0)
    expect(state.vec3).toBeInstanceOf(IVec3)
    expect(state.vec3.z).toBe(9.0)
    expect(state.rotation).toBeInstanceOf(Angle)
    expect(state.rotation.degrees).toBe(90.5)
  })

  it('rebuilds arrays of them and values nested in an added player and a firstSync', () => {
    view.handleSnapshot({
      values: {
        positions: [[1000, 2000], [3000, 4000]],
        players: { p1: { position: [64000, 36000], rotation: [45000], hp: 7 } },
      },
    })
    replace('/players/p2', { position: [10000, 20000], rotation: [90000], hp: 3 })
    const state = view.getState() as any
    expect(state.positions[1]).toBeInstanceOf(Position2)
    expect(state.positions[1].v.x).toBe(3.0)
    expect(state.players.p1.position).toBeInstanceOf(Position2)
    expect(state.players.p1.rotation.degrees).toBe(45.0)
    expect(state.players.p2.position.v.y).toBe(20.0)
    expect(state.players.p2.hp).toBe(3)
  })

  it('applies a positional patch at an atomic path', () => {
    view.handleSnapshot({ values: { players: { p1: { position: [64000, 36000], rotation: [0], hp: 7 } } } })
    replace('/players/p1/position', [65000, 37000])
    const state = view.getState() as any
    expect(state.players.p1.position).toBeInstanceOf(Position2)
    expect(state.players.p1.position.v.x).toBe(65.0)
  })

  it('still accepts keyed values', () => {
    view.handleSnapshot({ values: { position: { v: { x: 64000, y: 36000 } }, rotation: { degrees: 90000 } } })
    const state = view.getState() as any
    expect(state.position).toBeInstanceOf(Position2)
    expect(state.position.v.x).toBe(64.0)
    expect(state.rotation.degrees).toBe(90.0)
  })

  it('rejects a wrong length, a non-scalar leaf, and an array at a non-atomic object', () => {
    expect(() => replace('/position', [64000])).toThrow(/2 leaves|leafOrder/)
    expect(() => replace('/position', [64000, [1]])).toThrow(/not a scalar/)
    expect(() => replace('/plain', [1000, 2000])).toThrow(/non-atomic/)
  })

  it('rejects an empty or all-non-scalar array at an atomic path, also nested', () => {
    expect(() => replace('/position', [])).toThrow(/0 leaves/)
    expect(() => replace('/position', [[1], [2]])).toThrow(/not a scalar/)
    expect(() => replace('/rotation', [{ degrees: 1 }])).toThrow(/not a scalar/)
    expect(() => replace('/players/p9', { position: [], hp: 1 })).toThrow(/0 leaves/)
    expect(() => replace('/positions/0', [null, null])).toThrow(/not a scalar/)
  })

  it('keeps an array property of atomic values a list, also when empty', () => {
    view.handleSnapshot({ values: { positions: [] } })
    expect((view.getState() as any).positions).toEqual([])
    replace('/positions', [[1000, 2000]])
    const positions = (view.getState() as any).positions
    expect(positions[0]).toBeInstanceOf(Position2)
    expect(positions[0].v.y).toBe(2.0)
  })
})

describe('StateTreeView positional atomic values in a map of arrays', () => {
  let view: StateTreeView

  beforeEach(() => {
    view = new MockRuntime().createView('atomic-land', { schema })
    ;(view as any).isJoined = true
  })

  const replace = (path: string, value: unknown) =>
    view.handleStateUpdate({ type: 'diff', patches: [{ path, op: 'replace', value }] } as any)

  it('rebuilds the elements in a snapshot, a whole list and a single element', () => {
    view.handleSnapshot({ values: { paths: { a: [[1000, 2000], [3000, 4000]], b: [] } } })
    let paths = (view.getState() as any).paths
    expect(paths.a[1]).toBeInstanceOf(Position2)
    expect(paths.a[1].v.x).toBe(3.0)
    expect(paths.b).toEqual([])

    replace('/paths/c', [[5000, 6000]])
    replace('/paths/a/0', [7000, 8000])
    paths = (view.getState() as any).paths
    expect(paths.c[0]).toBeInstanceOf(Position2)
    expect(paths.c[0].v.y).toBe(6.0)
    expect(paths.a[0]).toBeInstanceOf(Position2)
    expect(paths.a[0].v.x).toBe(7.0)
  })

  it('checks each element like any atomic value', () => {
    expect(() => replace('/paths/a/0', [1000])).toThrow(/1 leaves/)
    expect(() => replace('/paths/a', [[1000, 2000, 3000]])).toThrow(/3 leaves/)
  })
})

describe('StateTreeView positional atomic values in optional collections', () => {
  let view: StateTreeView

  beforeEach(() => {
    view = new MockRuntime().createView('atomic-land', { schema })
    ;(view as any).isJoined = true
  })

  const replace = (path: string, value: unknown) =>
    view.handleStateUpdate({ type: 'diff', patches: [{ path, op: 'replace', value }] } as any)
  const state = () => view.getState() as any

  it('[Position2]?: nil, set, a whole list and one element', () => {
    view.handleSnapshot({ values: { maybePath: null } })
    expect(state().maybePath).toBeNull()
    replace('/maybePath', [[1000, 2000], [3000, 4000]])
    expect(state().maybePath[1]).toBeInstanceOf(Position2)
    expect(state().maybePath[1].v.x).toBe(3.0)
    replace('/maybePath/0', [5000, 6000])
    expect(state().maybePath[0].v.y).toBe(6.0)
    replace('/maybePath', [])
    expect(state().maybePath).toEqual([])
    expect(() => replace('/maybePath/0', [1000])).toThrow(/1 leaves/)
  })

  it('[String: [Position2]]?: a snapshot, a key and one element', () => {
    view.handleSnapshot({ values: { maybePaths: { a: [[1000, 2000]] } } })
    expect(state().maybePaths.a[0]).toBeInstanceOf(Position2)
    replace('/maybePaths/b', [[3000, 4000]])
    replace('/maybePaths/a/0', [7000, 8000])
    expect(state().maybePaths.b[0].v.x).toBe(3.0)
    expect(state().maybePaths.a[0].v.x).toBe(7.0)
  })

  it('an optional struct holding [Position2]', () => {
    view.handleSnapshot({ values: { maybeRoute: { points: [[1000, 2000]], name: 'r' } } })
    expect(state().maybeRoute.points[0]).toBeInstanceOf(Position2)
    replace('/maybeRoute/points/0', [3000, 4000])
    expect(state().maybeRoute.points[0].v.y).toBe(4.0)
    expect(state().maybeRoute.name).toBe('r')
  })
})

describe('Schema wire form (x-stateTree.atomicEncoding)', () => {
  const withEncoding = (atomicEncoding?: string) =>
    ({ ...(schema as any), 'x-stateTree': atomicEncoding === undefined ? undefined : { atomicEncoding } }) as ProtocolSchema

  it('accepts positional and a schema without the marker', () => {
    expect(() => new MockRuntime().createView('atomic-land', { schema: withEncoding('positional') })).not.toThrow()
    expect(() => new MockRuntime().createView('atomic-land', { schema: withEncoding(undefined) })).not.toThrow()
  })

  it('refuses a wire form it does not decode, with a clear error', () => {
    expect(() => new MockRuntime().createView('atomic-land', { schema: withEncoding('columnar') })).toThrow(
      /atomicEncoding "columnar".*Update @swiftstatetree\/sdk/
    )
  })
})

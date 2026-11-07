import { describe, expect, it } from 'vitest'
import { compareStates, normalizeForConvergence, UnsafeInteger } from './convergence'
import { Position2 } from './deterministic-math'

const paths = (client: unknown, server: unknown) => compareStates(client, server).map((d) => d.path)

describe('convergence comparison', () => {
  it('reduces SDK math classes to their wire integers', () => {
    expect(normalizeForConvergence({ p: new Position2({ x: 1500, y: -250 }, true) })).toEqual({ p: { v: { x: 1500, y: -250 } } })
    expect(paths({ p: new Position2({ x: 1500, y: -250 }, true) }, { p: { v: { x: 1500, y: -250 } } })).toEqual([])
  })

  it('treats a null and an absent key as the same, and ignores key order', () => {
    expect(paths({ a: 1, b: null }, { a: 1 })).toEqual([])
    expect(paths({ b: 2, a: 1 }, { a: 1, b: 2 })).toEqual([])
  })

  it('compares bigint as number, but never an unsafe integer', () => {
    expect(paths({ n: BigInt(42) }, { n: 42 })).toEqual([])
    expect(normalizeForConvergence(BigInt(2) ** BigInt(60))).toBeInstanceOf(UnsafeInteger)
    expect(paths({ n: BigInt(2) ** BigInt(60) }, { n: BigInt(2) ** BigInt(60) })).toEqual(['/n'])
  })

  it('reports each differing path, with the side that lacks a key', () => {
    const diffs = compareStates({ players: { p1: { hp: 3 } }, list: [1, 2] }, { players: { p1: { hp: 4 } }, list: [1], extra: true })
    expect(diffs.map((d) => d.path)).toEqual(['/extra', '/list/1', '/players/p1/hp'])
    expect(diffs[0]).toEqual({ path: '/extra', client: undefined, server: true })
  })
})

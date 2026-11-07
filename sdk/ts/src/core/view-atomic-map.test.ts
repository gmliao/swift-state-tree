/**
 * A map whose values are atomic (`[PlayerID: Position2]`, Demo's deterministic-math-demo land):
 * the map itself is a container, not a value of its entries' type.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import { Position2 } from './deterministic-math'

class SilentRuntime extends StateTreeRuntime {
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(): void {}
}

const schema = JSON.parse(
  readFileSync(join(dirname(fileURLToPath(import.meta.url)), '../../../../Examples/Demo/schema.json'), 'utf-8')
)

function view() {
  const v = new SilentRuntime().createView('deterministic-math-demo', { schema })
  ;(v as any).isJoined = true
  return v
}

describe('A map of atomic values', () => {
  it('decodes an empty map in a snapshot', () => {
    const v = view()
    v.handleSnapshot({ values: { playerPositions: {} } })
    expect((v.getState() as any).playerPositions).toEqual({})
  })

  it('decodes its entries, keyed or positional, in a snapshot and in a whole-map patch', () => {
    const v = view()
    v.handleSnapshot({ values: { playerPositions: { p1: { v: { x: 1000, y: 2000 } }, p2: [3000, 4000] } } })
    const positions = (v.getState() as any).playerPositions
    expect(positions.p1).toBeInstanceOf(Position2)
    expect(positions.p2).toBeInstanceOf(Position2)
    expect([positions.p2.v.x, positions.p2.v.y]).toEqual([3, 4])
    v.handleStateUpdate({ type: 'diff', patches: [{ path: '/playerPositions', op: 'replace', value: { p3: [5000, 6000] } }] } as any)
    expect(Object.keys((v.getState() as any).playerPositions)).toEqual(['p3'])
    expect((v.getState() as any).playerPositions.p3).toBeInstanceOf(Position2)
  })
})

/**
 * Atomic values in every collection shape (#272), from the Swift fixture
 * `Tests/SwiftStateTreeTransportTests/Fixtures/AtomicArrayShapes/atomic-array-shapes.json`:
 * the view decodes each wire value (positional) to the logical (keyed) value Swift encoded.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import { normalizeForConvergence } from './convergence'
import type { ProtocolSchema } from '../codegen/schema'

interface FixtureCase {
  name: string
  path: string
  wire: unknown
  logical: unknown
}

const fixture: { schema: ProtocolSchema; landType: string; cases: FixtureCase[] } = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/AtomicArrayShapes/atomic-array-shapes.json'
    ),
    'utf-8'
  )
)

class SilentRuntime extends StateTreeRuntime {
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(): void {}
}

function valueAt(state: unknown, path: string): unknown {
  let current: any = state
  for (const part of path.split('/').filter((p) => p !== '')) {
    current = current?.[part]
  }
  return current
}

describe('Atomic values in every collection shape (Swift fixture)', () => {
  it('has a case for every shape', () => {
    expect(fixture.cases.length).toBeGreaterThanOrEqual(13)
  })

  it('decodes every wire value to the logical value, applied in order', () => {
    const view = new SilentRuntime().createView(fixture.landType, { schema: fixture.schema })
    ;(view as any).isJoined = true
    view.handleSnapshot({ values: {} })
    for (const c of fixture.cases) {
      view.handleStateUpdate({ type: 'diff', patches: [{ path: c.path, op: 'replace', value: structuredClone(c.wire) }] } as any)
      expect(normalizeForConvergence(valueAt(view.getState(), c.path)), c.name).toEqual(normalizeForConvergence(c.logical))
    }
  })
})

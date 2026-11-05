/**
 * TypeScript parity with the server's apply oracle on the golden recordings.
 *
 * The Swift replay verifier checks that each sync output's patches, applied to the previous
 * view with an RFC 6901 reference client, give the new view. Passing that proves the patches
 * correct, not that this SDK converges (#121). The golden recordings export every case the
 * oracle checked (view before, patches, the oracle's view after) to
 * `Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/*.apply-cases.json`; this
 * test applies the same patches with `StateTreeView` and requires the oracle's view.
 *
 * Regenerate the fixtures with `Tools/regenerate-sync-output-goldens.sh`.
 */
import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import type { StatePatch, TransportMessage } from '../types/transport'
import type { ProtocolSchema } from '../codegen/schema'

interface ApplyCase {
  scope: string
  before: Record<string, unknown>
  patches: StatePatch[]
  after: Record<string, unknown>
}

class SilentRuntime extends StateTreeRuntime {
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(_message: TransportMessage): void {}
}

const fixtures = join(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens'
)
const goldens = readdirSync(fixtures).filter(f => f.endsWith('.apply-cases.json')).sort()
const schema: ProtocolSchema = JSON.parse(readFileSync(join(fixtures, 'verifier-land.schema.json'), 'utf-8'))

/**
 * Cases where `view.ts` is known to differ from RFC 6901 (#121), as `golden#index`. They run as
 * expected failures, so fixing #121 makes them fail until they are removed from this list.
 */
const knownDivergences = new Set<string>([
  // Patches to /board/a~1b, /board/t~01 and /board/x[1]: view.ts writes the keys "a~1b" and
  // "t~01" instead of "a/b" and "t~1", and an array `x` instead of the key "x[1]".
  'escaped-keys-json#3',
  'escaped-keys-json#4',
  'escaped-keys-json#6',
  'escaped-keys-json#7',
  'escaped-keys-json#8',
])

function applyWithView(applyCase: ApplyCase): Record<string, unknown> {
  const view = new SilentRuntime().createView('sync-output-verifier-test', { schema, playerID: 'p1', deviceID: 'd1' })
  view.handleSnapshot({ values: structuredClone(applyCase.before) })
  view.handleStateUpdate({ type: 'diff', patches: structuredClone(applyCase.patches) })
  return view.getState()
}

describe('view.ts applies the golden recordings like the apply oracle', () => {
  it('has golden apply cases', () => {
    expect(goldens.length).toBeGreaterThan(0)
  })

  for (const golden of goldens) {
    const name = golden.replace('.apply-cases.json', '')
    const cases: ApplyCase[] = JSON.parse(readFileSync(join(fixtures, golden), 'utf-8'))
    describe(name, () => {
      cases.forEach((applyCase, index) => {
        const id = `${name}#${index}`
        const test = knownDivergences.has(id) ? it.fails : it
        test(`${index}: ${applyCase.scope}, ${applyCase.patches.length} patches`, () => {
          expect(applyWithView(applyCase)).toEqual(applyCase.after)
        })
      })
    })
  }
})

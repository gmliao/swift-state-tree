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
 * The one patch path where `view.ts` is known to differ from RFC 6901: it reads `name[n]` as an
 * array index, so the key "x[1]" lands in an array `x` (#202). A case with this path must
 * match the oracle everywhere else, and must still show that divergence, so fixing it makes the
 * test fail until the path is removed from this set. The escaped keys "a~1b" and "t~01" match
 * since #121.
 */
const knownDivergentPaths = new Set<string>(['/board/x[1]'])

function isKnownDivergence(applyCase: ApplyCase): boolean {
  return applyCase.patches.some(patch => knownDivergentPaths.has(patch.path))
}

/** Removes the bracket-key divergence: the key "x[1]" and the array `x` the view writes for it. */
function withoutBracketKey(state: Record<string, unknown>): Record<string, unknown> {
  const copy = structuredClone(state)
  const board = copy.board as Record<string, unknown> | undefined
  if (board) {
    delete board['x[1]']
    delete board.x
  }
  return copy
}

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
        it(`${index}: ${applyCase.scope}, ${applyCase.patches.length} patches`, () => {
          const actual = applyWithView(applyCase)
          if (!isKnownDivergence(applyCase)) {
            expect(actual).toEqual(applyCase.after)
            return
          }
          expect(Array.isArray((actual.board as Record<string, unknown>)?.x)).toBe(true) // still divergent
          expect(withoutBracketKey(actual)).toEqual(withoutBracketKey(applyCase.after))
        })
      })
    })
  }
})

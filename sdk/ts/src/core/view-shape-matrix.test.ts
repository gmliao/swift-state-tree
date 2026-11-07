/**
 * The shape matrix (#257, #271, #272, #278, #284), from the Swift fixture
 * `Tests/SwiftStateTreeTransportTests/Fixtures/ShapeMatrix/shape-matrix.json`: the view decodes
 * each raw opcode frame Swift encoded (JSON text and MessagePack, path hashes and dynamic key
 * slots carried across frames) and applies it; the value at the patch path must equal the logical
 * value Swift encoded, keys byte for byte. A case with `knownIssue` must still fail (decode, path
 * or value); once it passes, its issue is fixed and its marker goes.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import { normalizeForConvergence } from './convergence'
import { decodeMessage } from './protocol'
import type { ProtocolSchema } from '../codegen/schema'
import type { StateUpdate, TransportEncodingConfig } from '../types/transport'

interface FixtureCase {
  name: string
  path: string
  wire: unknown
  logical: unknown
  jsonFrame: string
  messagePackFrame: string
  knownIssue: number | null
}

const fixture: { schema: ProtocolSchema; landType: string; cases: FixtureCase[] } = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/ShapeMatrix/shape-matrix.json'
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

/** The value at a JSON Pointer, each component unescaped (RFC 6901). */
function valueAt(state: unknown, pointer: string): unknown {
  let current: any = state
  for (const token of pointer.split('/').slice(1)) {
    current = current?.[token.replace(/~1/g, '/').replace(/~0/g, '~')]
  }
  return current
}

const formats: { name: string; config: TransportEncodingConfig; frame: (c: FixtureCase) => string | Uint8Array }[] = [
  {
    name: 'opcode JSON',
    config: { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray' } as TransportEncodingConfig,
    frame: (c) => c.jsonFrame,
  },
  {
    name: 'opcode MessagePack',
    config: { message: 'messagepack', stateUpdate: 'opcodeJsonArray' } as TransportEncodingConfig,
    frame: (c) => new Uint8Array(Buffer.from(c.messagePackFrame, 'base64')),
  },
]

describe('Shape matrix (Swift fixture)', () => {
  it('has the shapes it is meant to cover', () => {
    const names = fixture.cases.map((c) => c.name)
    for (const shape of ['map key ending in [n]', 'map key with a slash', 'map key decomposed', 'nested optional atomic', 'let-only struct']) {
      expect(names).toContain(shape)
    }
  })

  for (const format of formats) {
    it(`decodes every ${format.name} frame to the logical value, applied in order`, () => {
      const view = new SilentRuntime().createView(fixture.landType, { schema: fixture.schema })
      ;(view as any).isJoined = true
      view.handleSnapshot({ values: {} })
      const keys = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>() }
      for (const c of fixture.cases) {
        const apply = () => {
          const update = decodeMessage(format.frame(c), format.config, keys) as StateUpdate
          expect(update.type, c.name).toBe('diff')
          expect(update.patches.map((p) => p.path), c.name).toEqual([c.path])
          expect(update.patches[0].value, `${c.name}: the decoded patch value is the wire value`).toEqual(c.wire)
          view.handleStateUpdate(update)
          expect(normalizeForConvergence(valueAt(view.getState(), c.path)), c.name).toEqual(normalizeForConvergence(c.logical))
        }
        if (c.knownIssue == null) {
          apply()
        } else {
          expect(apply, `${c.name}: known issue #${c.knownIssue} passes now; remove its marker`).toThrow()
        }
      }
    })
  }

  it('keeps a decomposed and a composed key apart (no normalization)', () => {
    const view = new SilentRuntime().createView(fixture.landType, { schema: fixture.schema })
    ;(view as any).isJoined = true
    view.handleSnapshot({ values: {} })
    const keys = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>() }
    for (const c of fixture.cases) {
      try {
        view.handleStateUpdate(decodeMessage(c.jsonFrame, formats[0].config, keys) as StateUpdate)
      } catch (error) {
        if (c.knownIssue == null) throw error
      }
    }
    const byKey = (view.getState() as any).byKey
    // Until #289 is fixed, the composed key arrives as the decomposed key's slot.
    const expected = ['a/b', 'a[0]', 'e\u0301', 'plain', 't~x']
    if (!fixture.cases.some((c) => c.knownIssue === 289)) expected.push('\u00e9')
    expect(Object.keys(byKey).sort()).toEqual(expected.sort())
  })
})

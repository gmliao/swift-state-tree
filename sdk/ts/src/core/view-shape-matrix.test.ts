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

/**
 * The one failure each open issue causes here, and the step it happens in. Earlier steps run as
 * usual, and the step must fail with exactly this message; any other failure is a real one.
 * - #287: no path hash below an optional, so the frame doesn't decode;
 * - #289: the composed key reuses the decomposed key's slot, so the decoded path is wrong.
 */
const knownFailures: Record<number, { step: 'decode' | 'path'; message: RegExp }> = {
  287: { step: 'decode', message: /^Unknown pathHash: \d+\./ },
  289: { step: 'path', message: /: decoded path: expected \[/ },
}

/** Runs `step`, which must fail with `issue`'s failure; rethrows anything else. */
function expectKnownFailure(issue: number, label: string, step: () => void): void {
  let failure: unknown
  try {
    step()
  } catch (error) {
    failure = error
  }
  if (failure === undefined) {
    throw new Error(`${label}: known issue #${issue} passes now; remove its marker`)
  }
  const message = failure instanceof Error ? failure.message : String(failure)
  if (!knownFailures[issue]?.message.test(message)) throw failure
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
        const known = c.knownIssue == null ? undefined : knownFailures[c.knownIssue]
        if (c.knownIssue != null && !known) throw new Error(`${c.name}: no known failure for #${c.knownIssue}`)
        let update: StateUpdate | undefined
        const decode = () => {
          update = decodeMessage(format.frame(c), format.config, keys) as StateUpdate
        }
        if (known?.step === 'decode') {
          expectKnownFailure(c.knownIssue!, c.name, decode)
          continue
        }
        decode()
        expect(update!.type, c.name).toBe('diff')
        const path = () => expect(update!.patches.map((p) => p.path), `${c.name}: decoded path`).toEqual([c.path])
        expect(update!.patches[0].value, `${c.name}: the decoded patch value is the wire value`).toEqual(c.wire)
        if (known?.step === 'path') {
          // The patch goes to another key; applying it is checked in the key test below.
          expectKnownFailure(c.knownIssue!, c.name, path)
          continue
        }
        path()
        view.handleStateUpdate(update!)
        expect(normalizeForConvergence(valueAt(view.getState(), c.path)), c.name).toEqual(normalizeForConvergence(c.logical))
      }
    })
  }

  it('fails a known-issue case on any other failure', () => {
    // A mutant: a different error in a #287 case is not taken as #287.
    expect(() =>
      expectKnownFailure(287, 'mutant', () => {
        throw new Error('Dynamic key slot 3 used before definition')
      })
    ).toThrow(/^Dynamic key slot 3 used before definition$/)
    expect(() => expectKnownFailure(289, 'mutant', () => expect(1, 'mutant: wire value').toBe(2))).toThrow(/wire value/)
    expect(() => expectKnownFailure(287, 'mutant', () => {})).toThrow(/known issue #287 passes now/)
    expectKnownFailure(287, 'own', () => {
      throw new Error('Unknown pathHash: 12. Ensure schema is loaded.')
    })
  })

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

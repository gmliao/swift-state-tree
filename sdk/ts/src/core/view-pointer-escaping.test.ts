/**
 * Map keys containing `/`, `~` or brackets, and the empty key, reach the client escaped as RFC 6901
 * pointer components (`~1`, `~0`), in every encoding (#121). The view must unescape them, so
 * the key the server wrote is the key the client sees. The server's own escaping is checked
 * against the golden recordings in `view-golden-apply.test.ts`; the opcode encoders send the
 * same escaped component as the dynamic key (`"a~1b"`, `"x~0y"`). They don't carry the empty
 * key today (#205), so it is tested with JSON patches only.
 */
import { describe, it, expect, beforeEach } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { encode as msgpackEncode } from '@msgpack/msgpack'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import { decodeMessage, pathHashReverseLookup, StateUpdateOpcode, StatePatchOpcode } from './protocol'
import type { StatePatch, StateUpdate, TransportMessage } from '../types/transport'
import type { ProtocolSchema } from '../codegen/schema'

class SilentRuntime extends StateTreeRuntime {
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(_message: TransportMessage): void {}
}

const schema: ProtocolSchema = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/SyncOutputGoldens/verifier-land.schema.json'),
    'utf-8'
  )
)
const boardEntryHash = schema.lands['sync-output-verifier-test'].pathHashes!['board.*']

/** The keys the server writes, and the pointer component it sends for each. */
const keys: Array<[key: string, escaped: string]> = [
  ['a/b', 'a~1b'],
  ['x~y', 'x~0y'],
  ['t~1', 't~01'], // must not unescape to "t/"
  ['x[1]', 'x[1]'], // a key, not an array index (#202)
  ['', '']
]

function applied(patches: StatePatch[]): Record<string, unknown> {
  const view = new SilentRuntime().createView('sync-output-verifier-test', { schema, playerID: 'p1', deviceID: 'd1' })
  view.handleSnapshot({ values: { board: { keep: 1 } } })
  view.handleStateUpdate({ type: 'diff', patches })
  return view.getState().board as Record<string, unknown>
}

/** One opcode diff frame setting each non-empty key to its index, keyed by path hash and dynamic key. */
function opcodeFrame(): unknown[] {
  return [
    StateUpdateOpcode.diff,
    ...keys.filter(([key]) => key !== '').map(([, escaped], i) => [boardEntryHash, escaped, StatePatchOpcode.replace, i])
  ]
}

const expectedBoard = { keep: 1, 'a/b': 0, 'x~y': 1, 't~1': 2, 'x[1]': 3, '': 4 }
const { '': _empty, ...expectedOpcodeBoard } = expectedBoard

describe('escaped map keys (#121)', () => {
  beforeEach(() => {
    // Creating a view loads the schema's path hashes; the decoder reads them
    new SilentRuntime().createView('sync-output-verifier-test', { schema, playerID: 'p1', deviceID: 'd1' })
    expect(pathHashReverseLookup.get(boardEntryHash)).toBe('board.*')
  })

  it('json: replace, add and remove land on the unescaped key', () => {
    const set = keys.map(([, escaped], i) => ({ op: (i % 2 ? 'add' : 'replace') as 'add' | 'replace', path: `/board/${escaped}`, value: i }))
    expect(applied(set)).toEqual(expectedBoard)
    const removed = applied([...set, ...keys.map(([, escaped]) => ({ op: 'remove' as const, path: `/board/${escaped}` }))])
    expect(removed).toEqual({ keep: 1 })
  })

  it('opcodeJsonArray: dynamic keys are unescaped', () => {
    const update = decodeMessage(JSON.stringify(opcodeFrame())) as StateUpdate
    expect(update.type).toBe('diff')
    expect(applied((update as { patches: StatePatch[] }).patches)).toEqual(expectedOpcodeBoard)
  })

  it('messagepack: dynamic keys are unescaped', () => {
    const update = decodeMessage(msgpackEncode(opcodeFrame())) as StateUpdate
    expect(update.type).toBe('diff')
    expect(applied((update as { patches: StatePatch[] }).patches)).toEqual(expectedOpcodeBoard)
  })
})

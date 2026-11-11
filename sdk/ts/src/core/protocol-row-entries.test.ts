/**
 * Row entries (ops 6–9, `rowAddressing`), from the Swift fixture
 * `Tests/SwiftStateTreeTransportTests/Fixtures/RowAddressing/row-addressing-frames.json`: a
 * sequence of frames encoded by Swift with row addressing on and off. Each row frame, decoded
 * and applied in order, must give the same state as its plain frame, in JSON and MessagePack,
 * and leave the rows the fixture names bound. The strict rules follow the Swift decoder's.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { encode } from '@msgpack/msgpack'
import { decodeMessage, pathIndexTableFor, rowPatchIndicesOf, RowEntryProtocolError, RowTables } from './protocol'
import type { StatePatch, StateUpdate, TransportEncodingConfig } from '../types/transport'

interface FixtureFrame {
  name: string
  jsonFrame: string
  messagePackFrame: string
  plainJsonFrame: string
  plainMessagePackFrame: string
  rows: { slot: number; key: string; generation: number }[]
}

const fixture: { pathHashes: Record<string, number>; table: string; frames: FixtureFrame[] } = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/RowAddressing/row-addressing-frames.json'
    ),
    'utf-8'
  )
)

const pathPatterns = new Map(Object.entries(fixture.pathHashes).map(([pattern, hash]) => [hash, pattern]))
const pathIndexTable = pathIndexTableFor(fixture.pathHashes)
const index = (pattern: string): number => pathIndexTable.indexOf(fixture.pathHashes[pattern])
const tableHash = fixture.pathHashes[fixture.table]

function config(features: string[], message: 'opcodeJsonArray' | 'messagepack' = 'opcodeJsonArray'): TransportEncodingConfig {
  return { message, stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: features, pathIndexTable, pathPatterns }
}
const rowFeatures = ['pathIndex', 'fieldMerge', 'rowAddressing']
const plainFeatures = ['pathIndex', 'fieldMerge']

/** One connection's decode state: its key maps and row tables. */
function connection(features: string[], message: 'opcodeJsonArray' | 'messagepack' = 'opcodeJsonArray') {
  const maps = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>(), rowTables: new RowTables() }
  const cfg = config(features, message)
  return {
    tables: maps.rowTables,
    decode: (frame: string | Uint8Array) => decodeMessage(frame, cfg, maps) as StateUpdate,
  }
}

const unescape = (token: string) => token.replace(/~1/g, '/').replace(/~0/g, '~')

/** Applies patches in order to `state` (JSON Pointer paths). */
function apply(state: Record<string, unknown>, patches: StatePatch[]): void {
  for (const patch of patches) {
    const tokens = patch.path.split('/').slice(1).map(unescape)
    const last = tokens.pop()!
    let parent: any = state
    for (const token of tokens) {
      parent[token] ??= {}
      parent = parent[token]
    }
    if (patch.op === 'remove') delete parent[last]
    else parent[last] = structuredClone(patch.value)
  }
}

const bytes = (base64: string) => new Uint8Array(Buffer.from(base64, 'base64'))

describe('Row entries: the Swift fixture', () => {
  for (const format of [
    { name: 'opcode JSON', message: 'opcodeJsonArray' as const, row: (f: FixtureFrame) => f.jsonFrame, plain: (f: FixtureFrame) => f.plainJsonFrame },
    { name: 'opcode MessagePack', message: 'messagepack' as const, row: (f: FixtureFrame) => bytes(f.messagePackFrame), plain: (f: FixtureFrame) => bytes(f.plainMessagePackFrame) },
  ]) {
    it(`${format.name}: every frame gives the plain frame's state and binds the fixture's rows`, () => {
      const rows = connection(rowFeatures, format.message)
      const plain = connection(plainFeatures, format.message)
      const rowState: Record<string, unknown> = {}
      const plainState: Record<string, unknown> = {}
      for (const frame of fixture.frames) {
        apply(rowState, rows.decode(format.row(frame)).patches)
        apply(plainState, plain.decode(format.plain(frame)).patches)
        expect(rowState, frame.name).toEqual(plainState)
        const bound = [...rows.tables.bound(tableHash)]
          .map(([slot, { key, generation }]) => ({ slot, key: unescape(key), generation }))
          .sort((a, b) => a.slot - b.slot)
        expect(bound, frame.name).toEqual(frame.rows)
      }
    })
  }

  it("marks the row entries' patches, and only those", () => {
    const rows = connection(rowFeatures)
    const first = rows.decode(fixture.frames[0].jsonFrame)
    // [12,null,1,1] is today's entry; the three creates follow it.
    expect(rowPatchIndicesOf(first)).toEqual([1, 2, 3])
    const second = rows.decode(fixture.frames[1].jsonFrame)
    // [15,[0,"p"],1,5] is today's; the column set gives two patches.
    expect(rowPatchIndicesOf(second)).toEqual([2, 3])
    // The marks don't show in the patches or in the update's keys.
    expect(Object.keys(second)).toEqual(['type', 'patches'])
    expect(rowPatchIndicesOf(connection(plainFeatures).decode(fixture.frames[0].plainJsonFrame))).toEqual([])
  })
})

describe('Row entries: the strict rules', () => {
  const table = index('units.*')
  const hp = index('units.*.hp')
  const frame = (...entries: string[]) => `[2,${entries.join(',')}]`
  const create = (slot: number, generation: number, key = 'k') => `[${table},${slot},6,${generation},null,"${key}",{"hp":1}]`
  const bound = frame(create(0, 0))

  function fails(data: string, setup: string[], message: string) {
    const rows = connection(rowFeatures)
    for (const s of setup) rows.decode(s)
    let error: unknown
    try {
      rows.decode(data)
    } catch (e) {
      error = e
    }
    expect(error, `accepted: ${message}`).toBeInstanceOf(RowEntryProtocolError)
    expect((error as Error).message).toContain(message)
  }

  it('refuses entries on unbound or bound slots, and a generation that does not go up', () => {
    fails(frame(`[${hp},[0],8,[1]]`), [], 'unbound slot')
    fails(frame(`[${hp},[0],9]`), [], 'unbound slot')
    fails(frame(`[${table},0,7]`), [], 'unbound slot')
    fails(frame(create(0, 1)), [bound], 'bound slot')
    // Deleted, then created again: the generation must go up.
    fails(frame(create(0, 0)), [bound, frame(`[${table},0,7]`)], 'generation 0 after 0')
  })

  it('refuses malformed entries', () => {
    fails(frame(`[${hp},[1,0],8,[1,2]]`), [bound, frame(create(1, 0, 'j'))], 'not ascending')
    fails(frame(`[${hp},[0],8,[1,2]]`), [bound], '1 slots for 2 values')
    fails(frame(`[${hp},0,6,0,null,"k",1]`), [], 'without a slot')
    fails(frame(`[${table},[0],8,[1]]`), [bound], 'Invalid column set')
    fails(frame(`[${table},[0],9]`), [bound], 'Invalid column clear')
    fails(frame(`[${index('units.*.bag.*')},[0],8,[1]]`), [bound], 'not a row or a leaf')
    fails(frame(`[${table},0,7,1]`), [bound], 'must not include a value')
    fails(frame(`[${table},0,6,0,1,"k",{"hp":1}]`), [], 'Invalid row create')
    fails(frame(`[${table},0,6,0,null,7,{"hp":1}]`), [], 'Invalid row create')
  })

  it('refuses numbers that are not a slot or a generation, instead of rounding them', () => {
    for (const slot of ['0.5', '-1', 'true', '2147483648', '"0"', '[0]']) {
      fails(frame(`[${table},${slot},7]`), [bound], 'without a slot')
      fails(frame(`[${table},${slot},6,0,null,"k",{"hp":1}]`), [], 'without a slot')
    }
    for (const slots of ['[0.5]', '[-1]', '[true]', '[0,1.5]', '[]']) {
      fails(frame(`[${hp},${slots},8,[1]]`), [bound], 'not ascending integers')
      fails(frame(`[${hp},${slots},9]`), [bound], 'not ascending integers')
    }
    for (const generation of ['0.5', '-1', 'true', '4294967296']) {
      fails(frame(`[${table},0,6,${generation},null,"k",{"hp":1}]`), [], 'Invalid row create')
    }
  })

  it('takes the same numbers as MessagePack integers, and refuses them as MessagePack floats', () => {
    const rows = connection(rowFeatures, 'messagepack')
    rows.decode(encode([2, [table, 0, 6, 0, null, 'k', { hp: 1 }]]))
    expect(rows.decode(encode([2, [hp, [0], 8, [5]]])).patches).toEqual([{ path: '/units/k/hp', op: 'replace', value: 5 }])
    expect(() => rows.decode(encode([2, [table, 0.5, 7]]))).toThrow(RowEntryProtocolError)
  })

  it('reads a fractional op as no row op: the entry is read as today\'s, and the row stays bound', () => {
    for (const op of ['7.5', '6.5']) {
      const rows = connection(rowFeatures)
      rows.decode(bound)
      expect(() => rows.decode(frame(`[${table},0,${op}]`))).toThrow()
      expect([...rows.tables.bound(tableHash).keys()]).toEqual([0])
    }
  })

  it("keeps the frame's earlier row entries when a later one is refused", () => {
    const rows = connection(rowFeatures)
    expect(() => rows.decode(frame(create(0, 0), create(1, 0, 'j'), `[${hp},[2],8,[1]]`))).toThrow(RowEntryProtocolError)
    expect([...rows.tables.bound(tableHash).keys()].sort()).toEqual([0, 1])
  })
})

describe('Row entries: the op is read before entry[1]', () => {
  const table = index('units.*')
  const hp = index('units.*.hp')

  it('does not define a dynamic key from a column entry whose slot list looks like a key definition', () => {
    const maps = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>(), rowTables: new RowTables() }
    const cfg = config(rowFeatures)
    decodeMessage(`[2,[${table},0,6,0,null,"k",{"hp":1}],[${table},1,6,0,null,"j",{"hp":1}]]`, cfg, maps)
    // [0,1] would be today's two-key list, [1,"x"] a key definition: neither is read as keys.
    const update = decodeMessage(`[2,[${hp},[0,1],8,[2,3]]]`, cfg, maps) as StateUpdate
    expect(update.patches).toEqual([
      { path: '/units/k/hp', op: 'replace', value: 2 },
      { path: '/units/j/hp', op: 'replace', value: 3 },
    ])
    expect(maps.perPlayer.size).toBe(0)
  })
})

describe('Row entries: negotiation', () => {
  const table = index('units.*')
  const create = `[2,[${table},0,6,0,null,"k",{"hp":1}]]`

  it('refuses a row entry when rowAddressing was not negotiated', () => {
    const rows = connection(plainFeatures)
    expect(() => rows.decode(create)).toThrow(RowEntryProtocolError)
    expect(() => rows.decode(create)).toThrow('without rowAddressing negotiated')
  })

  it('refuses a row entry without the connection\'s row tables', () => {
    expect(() => decodeMessage(create, config(rowFeatures), { perPlayer: new Map() })).toThrow('no row tables')
  })

  it("decodes today's frames the same with rowAddressing negotiated", () => {
    const today = fixture.frames.map((f) => f.plainJsonFrame)
    const rows = connection(rowFeatures)
    const plain = connection(plainFeatures)
    for (const data of today) {
      const a = rows.decode(data)
      expect(a).toEqual(plain.decode(data))
      expect(rowPatchIndicesOf(a)).toEqual([])
    }
  })
})

describe('Row entries: resync and firstSync', () => {
  const table = index('units.*')
  const seqConfig = (features: string[]) => config([...features, 'syncSequence'])

  it('a resync clears the row tables; a firstSync does not', () => {
    const maps = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>(), rowTables: new RowTables() }
    const cfg = seqConfig(rowFeatures)
    decodeMessage(`[2,1,[${table},0,6,0,null,"k",{"hp":1}]]`, cfg, maps)
    decodeMessage(`[1,2]`, cfg, maps)
    expect([...maps.rowTables.bound(tableHash).keys()]).toEqual([0])
    // The resync's snapshot creates the row again, generation 0 included.
    decodeMessage(`[3,3,[${table},0,6,0,null,"k",{"hp":2}]]`, cfg, maps)
    expect(maps.rowTables.bound(tableHash).get(0)).toEqual({ key: 'k', generation: 0 })
  })
})

/**
 * Field merge order, from the Swift fixture
 * `Tests/SwiftStateTreeTransportTests/Fixtures/FieldMerge/field-merge-frames.json`: each case is
 * one frame in which a patch touches an entity between two of its field sets (a delete, a
 * respawn, a replaced map, a deleted sibling), encoded by Swift with the merge on and off. The
 * merged frame, decoded and applied in order to the case's initial state, must give the same
 * state as the plain frame, in both JSON and MessagePack.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { decodeMessage } from './protocol'
import type { StatePatch, StateUpdate, TransportEncodingConfig } from '../types/transport'

interface FixtureCase {
  name: string
  initial: Record<string, unknown>
  jsonFrame: string
  messagePackFrame: string
  plainJsonFrame: string
  plainMessagePackFrame: string
}

const fixture: { pathHashes: Record<string, number>; cases: FixtureCase[] } = JSON.parse(
  readFileSync(
    join(
      dirname(fileURLToPath(import.meta.url)),
      '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/FieldMerge/field-merge-frames.json'
    ),
    'utf-8'
  )
)

const pathPatterns = new Map(Object.entries(fixture.pathHashes).map(([pattern, hash]) => [hash, pattern]))

const formats: { name: string; config: TransportEncodingConfig; merged: (c: FixtureCase) => string | Uint8Array; plain: (c: FixtureCase) => string | Uint8Array }[] = [
  {
    name: 'opcode JSON',
    config: { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: ['fieldMerge'], pathPatterns },
    merged: (c) => c.jsonFrame,
    plain: (c) => c.plainJsonFrame,
  },
  {
    name: 'opcode MessagePack',
    config: { message: 'messagepack', stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: ['fieldMerge'], pathPatterns },
    merged: (c) => new Uint8Array(Buffer.from(c.messagePackFrame, 'base64')),
    plain: (c) => new Uint8Array(Buffer.from(c.plainMessagePackFrame, 'base64')),
  },
]

/** Applies patches in order to a copy of `state` (JSON Pointer paths, no escapes in this fixture). */
function apply(state: Record<string, unknown>, patches: StatePatch[]): Record<string, unknown> {
  const root = structuredClone(state)
  for (const patch of patches) {
    const tokens = patch.path.split('/').slice(1)
    const last = tokens.pop()!
    let parent: any = root
    for (const token of tokens) {
      parent[token] ??= {}
      parent = parent[token]
    }
    if (patch.op === 'remove') delete parent[last]
    else parent[last] = structuredClone(patch.value)
  }
  return root
}

function decode(frame: string | Uint8Array, config: TransportEncodingConfig): StatePatch[] {
  return (decodeMessage(frame, config, new Map()) as StateUpdate).patches
}

describe('Field merge order (Swift fixture)', () => {
  it('has the cases it is meant to cover, each with a merged entry', () => {
    const names = fixture.cases.map((c) => c.name)
    for (const name of ['removed between two of its fields', 'removed and respawned between two of its fields', 'its map replaced between two of its fields']) {
      expect(names).toContain(name)
    }
    for (const c of fixture.cases) {
      const entries = (JSON.parse(c.jsonFrame) as unknown[][]).slice(1)
      expect(entries.some((e) => e[2] === 4 || e[2] === 5), `${c.name}: a merged entry`).toBe(true)
      expect(c.jsonFrame.length, `${c.name}: merging makes the frame smaller`).toBeLessThan(c.plainJsonFrame.length)
    }
  })

  for (const format of formats) {
    for (const c of fixture.cases) {
      it(`${format.name}: ${c.name}: the merged frame gives the plain frame's state`, () => {
        const merged = apply(c.initial, decode(format.merged(c), format.config))
        const plain = apply(c.initial, decode(format.plain(c), format.config))
        expect(merged).toEqual(plain)
      })
    }
  }
})

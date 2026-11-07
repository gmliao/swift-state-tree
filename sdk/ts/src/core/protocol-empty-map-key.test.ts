/**
 * An empty map key (`""`) is a key: its dynamic key slot resolves on reuse, and the path is
 * `/byKey/` (the entry under `""`), not the map.
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { decodeMessage, pathHashReverseLookup } from './protocol'
import type { StateUpdate, TransportEncodingConfig } from '../types/transport'

const BY_KEY_ENTRY = 1234
const config = { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray' } as TransportEncodingConfig

describe('An empty map key', () => {
  beforeEach(() => {
    pathHashReverseLookup.clear()
    pathHashReverseLookup.set(BY_KEY_ENTRY, 'byKey.*')
  })

  it('defines and reuses a slot for ""', () => {
    const keys = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>() }
    // [diff, [pathHash, [slot, key], set, value]], then the same slot alone.
    const first = decodeMessage(JSON.stringify([2, [BY_KEY_ENTRY, [0, ''], 1, [4000, 5000]]]), config, keys) as StateUpdate
    const again = decodeMessage(JSON.stringify([2, [BY_KEY_ENTRY, 0, 1, [6000, 7000]]]), config, keys) as StateUpdate
    expect(first.patches.map((p) => p.path)).toEqual(['/byKey/'])
    expect(again.patches.map((p) => p.path)).toEqual(['/byKey/'])
  })

  it('reads "" sent as the key itself', () => {
    const keys = { broadcast: new Map<number, string>(), perPlayer: new Map<number, string>() }
    const update = decodeMessage(JSON.stringify([2, [BY_KEY_ENTRY, '', 1, [4000, 5000]]]), config, keys) as StateUpdate
    expect(update.patches.map((p) => p.path)).toEqual(['/byKey/'])
  })
})

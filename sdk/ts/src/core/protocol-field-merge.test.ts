/**
 * Same-parent field merge (`stateUpdateFeatures: ["fieldMerge"]`): a merged entry
 * `[parentId, dynamicKey, op 4|5, fieldMask, v1, v2, …]` carries several fields of one parent,
 * one value per mask bit in ascending order. A field's bit is its rank among the parent's named
 * children (`parent.<name>`, name not `*`), sorted by name in UTF-8 byte order, as in Swift's
 * `FieldMergeTable`.
 */

import { describe, it, expect } from 'vitest'
import { decodeMessage, fieldMergeChildrenOf, pathIndexTableFor, SUPPORTED_STATE_UPDATE_FEATURES } from './protocol'
import type { StateUpdate, TransportEncodingConfig } from '../types/transport'

const pathHashes: Record<string, number> = {
  round: 1,
  monsters: 2,
  'monsters.*': 3,
  'monsters.*.hp': 10,
  'monsters.*.name': 11,
  'monsters.*.pos': 12,
  'monsters.*.pos.v': 13,
  'monsters.*.pos.v.x': 14,
  'monsters.*.pos.v.y': 15,
  'monsters.*.tags': 16,
  'monsters.*.tags.*': 17,
  big: 20,
  ...Object.fromEntries(Array.from({ length: 33 }, (_, i) => [`big.c${String(i).padStart(2, '0')}`, 100 + i]))
}
const patterns = new Map(Object.entries(pathHashes).map(([pattern, hash]) => [hash, pattern]))

function config(features: string[] = ['fieldMerge'], table?: readonly number[]): TransportEncodingConfig {
  return {
    message: 'opcodeJsonArray',
    stateUpdate: 'opcodeJsonArray',
    stateUpdateFeatures: features,
    pathIndexTable: table,
    pathPatterns: patterns
  }
}

describe('Field merge', () => {
  it('a parent\'s children by bit: named children in byte order, the first 32', () => {
    const children = fieldMergeChildrenOf(patterns)
    expect(children.get(3)).toEqual([10, 11, 12, 16])
    expect(children.get(13)).toEqual([14, 15])
    expect(children.get(20)?.length).toBe(32)
    expect(children.get(20)?.[31]).toBe(131)
    expect(children.has(2), 'monsters.* is a wildcard child').toBe(false)
    // Byte order, not UTF-16 order: U+FF5E sorts before U+1F600 in UTF-8, after it in UTF-16.
    const wide = new Map([[1, 'p'], [2, 'p.\u{1F600}'], [3, 'p.～']])
    expect(fieldMergeChildrenOf(wide).get(1)).toEqual([3, 2])
  })

  it('decodes a merged entry to one patch per bit, in bit order, at its place in the frame', () => {
    const frame = '[2,[1,null,1,7],[3,[0,"a"],4,5,9,[1,2]],[3,0,5,2,"x"],[3,0,2]]'
    const update = decodeMessage(frame, config(), new Map()) as StateUpdate
    expect(update.patches).toEqual([
      { path: '/round', op: 'replace', value: 7 },
      { path: '/monsters/a/hp', op: 'replace', value: 9 },
      { path: '/monsters/a/pos', op: 'replace', value: [1, 2] },
      { path: '/monsters/a/name', op: 'add', value: 'x' },
      { path: '/monsters/a', op: 'remove' }
    ])
  })

  it('reads the parent id as a path index with the pathIndex feature', () => {
    const table = pathIndexTableFor(pathHashes)
    const parentIndex = table.indexOf(3)
    const update = decodeMessage(`[2,[${parentIndex},"a",4,3,1,"n"]]`, config(['pathIndex', 'fieldMerge'], table), new Map()) as StateUpdate
    expect(update.patches).toEqual([
      { path: '/monsters/a/hp', op: 'replace', value: 1 },
      { path: '/monsters/a/name', op: 'replace', value: 'n' }
    ])
  })

  it('reads bit 31 exactly', () => {
    const update = decodeMessage(`[2,[20,null,4,${2 ** 31 + 1},0,31]]`, config(), new Map()) as StateUpdate
    expect(update.patches.map((p) => p.path)).toEqual(['/big/c00', '/big/c31'])
  })

  it('rejects a mask that doesn\'t match the values or names no field', () => {
    expect(() => decodeMessage('[2,[3,"a",4,5,1]]', config(), new Map())).toThrow(/mask 5 for 1 values/)
    expect(() => decodeMessage('[2,[3,"a",4,0]]', config(), new Map())).toThrow(/invalid field mask 0/)
    expect(() => decodeMessage('[2,[3,"a",4,256,1]]', config(), new Map())).toThrow(/Unknown merged field: bit 8/)
    expect(() => decodeMessage(`[2,[3,"a",4,${2 ** 32},1]]`, config(), new Map())).toThrow(/invalid field mask/)
  })

  it('the SDK declares fieldMerge at join', () => {
    expect(SUPPORTED_STATE_UPDATE_FEATURES).toEqual(['pathIndex', 'fieldMerge'])
  })
})

import { describe, expect, it } from 'vitest'
import { ResyncSkip, RowTables, rowPatchIndicesOf } from './index'
import { markRowPatches } from './row-tables'
import type { StateUpdate } from '../types/transport'

const UNITS = 11
const patterns = new Map([[UNITS, 'units.*']])

function update(type: StateUpdate['type'], seq: number | undefined, paths: string[], rowIndices: number[] = []): StateUpdate {
  const result: StateUpdate = {
    type,
    patches: paths.map((path) => ({ path, op: 'replace' as const, value: 1 })),
    ...(seq === undefined ? {} : { seq }),
  }
  markRowPatches(result, rowIndices)
  return result
}

function rowsWith(...bound: Array<[number, number, string]>) {
  const tables = new RowTables()
  for (const [table, slot, key] of bound) tables.bind(table, slot, key, 0)
  return { tables, pathPatterns: patterns }
}

describe('ResyncSkip', () => {
  it('passes every frame before a resync, and the resync itself', () => {
    const skip = new ResyncSkip()
    const diff = update('diff', 4, ['/round'])
    expect(skip.filter(diff)).toBe(diff)
    const resync = update('resync', 4, ['/round'])
    expect(skip.filter(resync)).toBe(resync)
  })

  it("without rows, skips the whole frame at the resync's sequence, and only that one", () => {
    const skip = new ResyncSkip()
    skip.noteApplied(update('resync', 4, ['/round']))
    expect(skip.filter(update('diff', 4, ['/round', '/units/a/hp']))).toBeUndefined()
    const next = update('diff', 5, ['/round'])
    expect(skip.filter(next)).toBe(next)
    const unsequenced = update('diff', undefined, ['/round'])
    expect(skip.filter(unsequenced)).toBe(unsequenced)
  })

  it('with rows, keeps the row patches and the roots bound at the resync, and their marks', () => {
    const skip = new ResyncSkip()
    const rows = rowsWith([UNITS, 0, 'a'])
    skip.noteApplied(update('resync', 4, []), rows)
    // round: skipped; units/a/items/x (today's form, under a bound root): kept; the column: kept.
    const frame = update('diff', 4, ['/round', '/units/a/items/x', '/units/a/hp'], [2])
    const kept = skip.filter(frame, rows)
    expect(kept?.patches.map((p: { path: string }) => p.path)).toEqual(['/units/a/items/x', '/units/a/hp'])
    expect(rowPatchIndicesOf(kept!)).toEqual([1])
  })

  it('reads the roots at the resync, not from the live tables', () => {
    const skip = new ResyncSkip()
    const rows = rowsWith([UNITS, 0, 'a'])
    skip.noteApplied(update('resync', 4, []), rows)
    rows.tables.unbind(UNITS, 0)
    expect(skip.filter(update('diff', 4, ['/units/a/items/x']), rows)?.patches).toHaveLength(1)
  })

  it('applies creates into a table that was empty at the resync, and nothing else there', () => {
    const skip = new ResyncSkip()
    const rows = rowsWith()
    skip.noteApplied(update('resync', 4, []), rows)
    expect(skip.filter(update('diff', 4, ['/units/b'], [0]), rows)?.patches).toHaveLength(1)
    expect(skip.filter(update('diff', 4, ['/units/b/items/x']), rows)).toBeUndefined()
  })

  it('forgets the resync on reset', () => {
    const skip = new ResyncSkip()
    skip.noteApplied(update('resync', 4, []))
    skip.reset()
    const frame = update('diff', 4, ['/round'])
    expect(skip.filter(frame)).toBe(frame)
  })
})

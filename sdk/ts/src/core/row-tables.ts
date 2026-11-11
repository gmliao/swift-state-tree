/**
 * Row tables for row entries (`rowAddressing`). Internal to the SDK: the runtime owns one per
 * connection and the decoder reads and updates it. Not re-exported from the package index.
 */

/**
 * A connection's row tables: per table (the hash of its `<pattern>.*`), the key bound to each
 * slot, and each slot's last generation, which survives the slot's delete. Slots are broadcast
 * only, so there is one set per connection, not one per key scope. Cleared on a resync, not on a
 * key-scope-reset firstSync (the Swift decoder does the same).
 */
export class RowTables {
  private readonly keys = new Map<number, Map<number, string>>()
  private readonly generations = new Map<number, Map<number, number>>()

  key(table: number, slot: number): string | undefined {
    return this.keys.get(table)?.get(slot)
  }

  lastGeneration(table: number, slot: number): number | undefined {
    return this.generations.get(table)?.get(slot)
  }

  bind(table: number, slot: number, key: string, generation: number): void {
    let keys = this.keys.get(table)
    if (!keys) this.keys.set(table, (keys = new Map()))
    keys.set(slot, key)
    let generations = this.generations.get(table)
    if (!generations) this.generations.set(table, (generations = new Map()))
    generations.set(slot, generation)
  }

  unbind(table: number, slot: number): void {
    this.keys.get(table)?.delete(slot)
  }

  clear(): void {
    this.keys.clear()
    this.generations.clear()
  }

  /** The bound slots of `table`, with their keys and generations. */
  bound(table: number): Map<number, { key: string; generation: number }> {
    const result = new Map<number, { key: string; generation: number }>()
    for (const [slot, key] of this.keys.get(table) ?? []) {
      result.set(slot, { key, generation: this.generations.get(table)?.get(slot) ?? 0 })
    }
    return result
  }

  /** The tables with at least one bound slot. */
  boundTables(): number[] {
    return [...this.keys].filter(([, slots]) => slots.size > 0).map(([table]) => table)
  }
}

/** The non-enumerable field that carries a decoded update's row-derived patch indices. */
const ROW_PATCH_INDICES = Symbol('rowPatchIndices')

/** Marks `indices` of `update.patches` as row-derived (nothing when empty). */
export function markRowPatches(update: object, indices: number[]): void {
  if (indices.length > 0) Object.defineProperty(update, ROW_PATCH_INDICES, { value: indices, enumerable: false })
}

export function readRowPatchIndices(update: object): readonly number[] {
  return (update as { [ROW_PATCH_INDICES]?: number[] })[ROW_PATCH_INDICES] ?? []
}

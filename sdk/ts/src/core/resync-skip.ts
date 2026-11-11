import type { StateUpdate } from '../types/transport'
import { markRowPatches, readRowPatchIndices, type RowTables } from './row-tables'

/** A connection's row tables and its land's hash → pattern lookup, with `rowAddressing`. */
export interface ResyncRows {
  tables: RowTables
  pathPatterns?: ReadonlyMap<number, string>
}

/**
 * Which patches of a state frame to apply after a resync (#332). The runtime keeps one per
 * connection, and so does a client that decodes frames itself (ws-loadtest's reconstruction).
 *
 * After a resync, another state frame with the same sequence (the merged broadcast frame the
 * server sends after the snapshot) holds nothing the snapshot doesn't: its patches are not
 * applied, since applying them would notify changes the reconcile already made. Its key
 * definitions are still read by the decoder, and its events are still dispatched.
 *
 * With `rowAddressing`, at or below a slot-addressed root the resync snapshot holds the table as
 * committed, not live. So in that frame a patch from a row entry, and any patch under a root
 * that had a bound row when the resync was applied, still applies. The roots are recorded when
 * the resync is applied, not read from the live tables, which an earlier delete in the frame may
 * already have changed.
 *
 * This mirrors the server's ordering in a broadcast plan with the merged frame (107): the resync
 * snapshot is moved ahead of the shared frame (`TransportAdapter.putResyncSnapshotsFirst`), and a
 * slot-addressed root's full view holds its table as committed, which the shared frame at the
 * same sequence brings to live (`Notes/plans/2026-11-10-row-addressing.md` §4).
 */
export class ResyncSkip {
  private seq: number | undefined
  private rowRoots: ReadonlySet<string> = new Set()

  /**
   * The part of `update` to apply: all of it, nothing (undefined), or with `rows` the patches
   * that still apply. The kept row-derived patches stay marked (`rowPatchIndicesOf`).
   */
  filter(update: StateUpdate, rows?: ResyncRows): StateUpdate | undefined {
    if (update.type === 'resync' || update.seq === undefined || update.seq !== this.seq) return update
    if (!rows) return undefined
    const rowPatches = new Set(readRowPatchIndices(update))
    const patches: StateUpdate['patches'] = []
    const kept: number[] = []
    update.patches.forEach((patch, i) => {
      if (!rowPatches.has(i) && !this.rowRoots.has(rootOf(patch.path))) return
      if (rowPatches.has(i)) kept.push(patches.length)
      patches.push(patch)
    })
    if (patches.length === 0) return undefined
    const filtered = { ...update, patches }
    markRowPatches(filtered, kept)
    return filtered
  }

  /** Call once `update` is applied: a resync records its sequence and, with `rows`, its roots. */
  noteApplied(update: StateUpdate, rows?: ResyncRows): void {
    if (update.type !== 'resync' || update.seq === undefined) return
    this.seq = update.seq
    this.rowRoots = rows ? boundRowRoots(rows) : new Set()
  }

  /** Forgets the last resync (a new connection, or the connection's sequence stopped). */
  reset(): void {
    this.seq = undefined
    this.rowRoots = new Set()
  }
}

/** The roots of the tables with a bound row. */
function boundRowRoots(rows: ResyncRows): Set<string> {
  const roots = new Set<string>()
  for (const table of rows.tables.boundTables()) {
    const pattern = rows.pathPatterns?.get(table)
    if (pattern) roots.add(pattern.split('.')[0])
  }
  return roots
}

/** A JSON Pointer path's first token: the state's top-level field it is under. */
function rootOf(path: string): string {
  const end = path.indexOf('/', 1)
  return end < 0 ? path.slice(1) : path.slice(1, end)
}

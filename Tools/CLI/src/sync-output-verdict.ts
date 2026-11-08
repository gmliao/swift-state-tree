/**
 * Reads the `Sync Output:` line the ReevaluationRunner CLIs print with `--verify`, and checks
 * that the replay actually compared sync outputs: a verdict alone cannot tell "0 mismatches"
 * from "0 compared".
 */

export interface SyncOutputScopeCounts {
  compared: number
  unverifiable: number
  skipped: number
}

export interface SyncOutputVerdict {
  /** `passed`, `partial`, `failed`, `skipped` or `malformed`. */
  verdict: string
  /** Per scope (broadcast, per-player, events, seed, apply); empty for skipped and malformed. */
  scopes: Record<string, SyncOutputScopeCounts>
  /**
   * Incomplete records only: events emitted at or after the last recorded output, which the
   * record ends before syncing (`N tail events not yet synced`); they don't make it partial.
   */
  tailEventsNotSynced: number
  /** The whole summary after `Sync Output: `. */
  line: string
}

/** The scopes every recorded run with players must have compared at least once. */
export const REQUIRED_SCOPES = ['broadcast', 'per-player', 'seed', 'apply']

/** Parses the last `Sync Output:` line of the CLI output; undefined when there is none. */
export function parseSyncOutput(output: string): SyncOutputVerdict | undefined {
  const lines = output.split('\n').filter(l => l.includes('Sync Output:'))
  const last = lines[lines.length - 1]
  if (!last) return undefined
  const line = last.slice(last.indexOf('Sync Output:') + 'Sync Output:'.length).trim()
  const head = line.split(/[\s[(:]/)[0]
  const verdict = head === 'FAILED' ? 'failed' : head
  const scopes: Record<string, SyncOutputScopeCounts> = {}
  const bracket = line.match(/\[compared\/unverifiable\/skipped: ([^\]]*)\]/)
  if (bracket) {
    for (const part of bracket[1].split(',')) {
      const m = part.trim().match(/^(.+) (\d+)\/(\d+)\/(\d+)$/)
      if (m) {
        scopes[m[1]] = { compared: Number(m[2]), unverifiable: Number(m[3]), skipped: Number(m[4]) }
      }
    }
  }
  const tail = line.match(/; (\d+) tail events not yet synced/)
  return { verdict, scopes, tailEventsNotSynced: tail ? Number(tail[1]) : 0, line }
}

/** The skip a record made with in-turn sync off gets: such a record has no sync stream. */
export const IN_TURN_OFF_SKIP = 'skipped (no sync stream: recorded with in-turn sync off)'

/**
 * Whether the server under test runs with in-turn sync, read from `IN_TURN_SYNC` like the Swift
 * side (`InTurnSync.isEnabled`): on unless the value is a recognized false.
 */
export function inTurnSyncEnabled(env: Record<string, string | undefined> = process.env): boolean {
  const raw = env.IN_TURN_SYNC?.trim().toLowerCase()
  return !(raw !== undefined && ['0', 'false', 'no', 'n', 'off'].includes(raw))
}

/**
 * Throws unless the verdict is `passed` and every required scope (and `events`, when the record
 * has it) compared at least once. `partial` fails too: it means unverifiable outputs, a
 * non-benign skip or events left after the last output, and no E2E scenario expects any of them.
 * A scenario that legitimately cannot be fully verified must name its allowed reasons here.
 *
 * With `inTurnSync` false, the record has no sync stream, so the only accepted line is that
 * skip (`IN_TURN_OFF_SKIP`).
 */
export function assertSyncOutputCompared(output: string, inTurnSync: boolean = inTurnSyncEnabled()): SyncOutputVerdict {
  const parsed = parseSyncOutput(output)
  if (!parsed) {
    throw new Error('ReevaluationRunner printed no "Sync Output:" line')
  }
  if (!inTurnSync) {
    if (parsed.line !== IN_TURN_OFF_SKIP) {
      throw new Error(`expected "${IN_TURN_OFF_SKIP}" with in-turn sync off: ${parsed.line}`)
    }
    return parsed
  }
  if (parsed.verdict !== 'passed') {
    throw new Error(`sync output not verified: ${parsed.line}`)
  }
  const required = [...REQUIRED_SCOPES, ...('events' in parsed.scopes ? ['events'] : [])]
  for (const scope of required) {
    const counts = parsed.scopes[scope]
    if (!counts || counts.compared === 0) {
      throw new Error(`sync output scope "${scope}" compared nothing: ${parsed.line}`)
    }
  }
  return parsed
}

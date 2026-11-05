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
  return { verdict, scopes, line }
}

/**
 * Throws unless the verdict is `passed` or `partial` and every required scope (and `events`,
 * when the record has it) compared at least once.
 */
export function assertSyncOutputCompared(output: string): SyncOutputVerdict {
  const parsed = parseSyncOutput(output)
  if (!parsed) {
    throw new Error('ReevaluationRunner printed no "Sync Output:" line')
  }
  if (parsed.verdict !== 'passed' && parsed.verdict !== 'partial') {
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

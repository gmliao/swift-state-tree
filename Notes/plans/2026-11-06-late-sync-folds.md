# Late sync folds: count a fold as late only beyond the coincident window (#232)

Status: open, rev 1.

## Problem

`syncOverdueFolds` counts a fold as overdue when the tick's deadline has passed by any amount (`deadline < now`, `LandKeeper.runSync`). A land's tick and sync loops are phase-locked (`LandLoopPhase.offset`; Hero Defense syncs every 100 ms = 2 × its 50 ms tick), so every sync deadline sits within about a millisecond of a tick deadline. Which loop runs first after the shared deadline decides the count, so it measures a scheduler race. The 2026-11-06 rerun on the 7600X shows 276–388 per 1000 cycles at every room count, including 100 rooms with no skipped cycles.

The impairment experiment needs a count that means "the sync waited for a tick that was really late", and the size of that lateness.

## Decision: add, don't redefine

The existing field keeps its name and its definition. The new definition goes in new fields.

- **Why not redefine `syncOverdueFolds`:** the 2026-11-06 data (`deep-research/multiroom-load-2026-11/`) and the A/B run from today carry `syncOverdueFolds` with the race definition. If the same name meant something else in later data, a reader couldn't tell from a report which one it holds, and comparing an old and a new report under one name would be wrong without warning.
- **What changes:** a fold whose tick is late by more than `coincidentSyncWindow` is also counted as **late** (`syncLateFolds`), and the largest tick lateness at a fold in each profile window is recorded (`syncFoldTickLatenessMaxUs`). `syncOverdueFolds` stays, documented as "deadline passed by any amount (includes the loop race)".
- **Invariant per window:** late ≤ overdue ≤ folds. A late fold is overdue: lateness > window > 0.

## Definitions

At a fold, `lateness = now − nextTickDeadline` (negative when the tick is still ahead, within the window).

| Counter | Counts a fold when | Meaning |
|---|---|---|
| `syncFolds` | always (unchanged) | the sync joined a tick turn |
| `syncOverdueFolds` | `lateness > 0` (unchanged) | deadline passed; mostly the loop race |
| `syncLateFolds` (new) | `lateness > coincidentSyncWindow` | the tick was late beyond what counts as coincident |
| `syncFoldTickLatenessMaxUs` (new) | max of `lateness` over the window's folds, µs, 0 when no fold was overdue | how late, at worst |

The window is the keeper's `coincidentSyncWindow` (min(5 ms, tick / 4, sync / 4)), so the threshold follows the land's own intervals. The comparison is strict: a fold exactly at `deadline + window` isn't late.

## Changes

### Sources (PR, core)

1. **`LandKeeperTransport`** (`Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`): replace `noteInTurnSyncFold(overdue: Bool)` with `noteInTurnSyncFold(_ fold: InTurnSyncFold)`. `InTurnSyncFold` is a small public struct with `tickLateness: Duration` and `coincidentWindow: Duration`, and computed `isOverdue` (`tickLateness > .zero`) and `isLate` (`tickLateness > coincidentWindow`). The classification lives in one place, and the transport gets the lateness. The default implementation stays a no-op. The old method is removed, not deprecated: its only implementer is `TransportAdapter`, and the protocol requirement is documented as called only when `recordsInTurnSyncFolds`.
2. **`LandKeeper.runSync`**: build the `InTurnSyncFold` from `now − deadline` and the window. Keep `foldedSyncs` and `overdueFoldedSyncs`; add `lateFoldedSyncs` (diagnostics, with `cadenceCountersForTesting`). The fold decision itself (`deadline − now ≤ window`) is unchanged, so the runtime behaviour is unchanged: only what's counted changes.
3. **`TransportProfilerCounters`** (`TransportProfilingActor.swift`):
   - `incrementSyncFolds(overdue:)` becomes `recordSyncFold(_:)`.
   - The three counts stay in one atomic word, so a window never splits a fold and late ≤ overdue ≤ folds holds per window: 21 bits each (folds bits 0–20, overdue 21–41, late 42–62). One increment per fold, one exchange per window. The limit is 2,097,151 folds per window. At 10 folds per land per second and the 1 s default window, that's about 200,000 lands, and the profile interval's floor is 100 ms. The doc comment states the limit, and a test checks the field boundaries.
   - `syncFoldTickLatenessMaxUs`: a separate `ManagedAtomic<Int>` with the existing `storeMax`, exchanged with the others. Only overdue folds store into it.
   - The JSONL line gains `syncLateFolds` and `syncFoldTickLatenessMaxUs`. Existing keys don't change.
4. **Tests** (Swift Testing, deterministic, no timing), in `Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift` and `Tests/SwiftStateTreeTransportTests/TransportProfilerSyncCountersTests.swift` (both updated for the new signatures):
   - The fixed-clock hooks the keeper already has (`setNextTickDeadlineForTesting`, `runSyncLoopIterationForTesting(at:)`) drive folds at: deadline − 1 ms (fold, not overdue); deadline + 1 ms (overdue, not late); deadline + window exactly (overdue, not late); deadline + 20 ms (overdue and late, lateness 20 ms). The recording transport checks the `InTurnSyncFold` values, and the keeper's counters check 4 / 3 / 1.
   - Profiler: folds with each classification give the right three counts and max; an exchange resets all of them; counts at the 21-bit boundary don't bleed into the next field.
   - Mutation checks before the PR: `>` → `>=` in `isLate`, a dropped `storeMax`, and the late bit going into the overdue field must each fail a test.

### Examples (direct to main, after the PR merges)

5. **ws-loadtest `server-sync.ts`:** the new fields go in a separate optional list. `parseProfileWindows` keeps requiring only the six existing fields, so 2026-11-06 and b629861 profiles parse as today. The summary adds `lateFoldsPer1000Syncs` and `foldTickLatenessMaxUs` (the max over the phase), each `null` unless every counted window carries the field (the same rule as `sumIfEvery` in `server-send.ts`). The report shows "n/a", never 0, for older data.
6. **Report (`render-html.ts`):** lead with folds / cycles and the late folds per 1000 cycles, plus the max lateness in ms. The overdue column stays, relabelled "past deadline (loop race)".
7. **METRICS.md:** replace the "Until #232" caveat with the three definitions, the threshold, and how to read older reports (late and lateness n/a).
8. **Tests (vitest):** an old-format profile summarizes as before with the new figures `null`; a mixed profile (some windows without the fields) gives `null`; a new profile sums and maxes.

## Backward readability

- Old JSONL, old server: parses unchanged; new figures n/a.
- Old reports in `deep-research/` (`report.json` with `serverSync.summary.totals.syncOverdueFolds`): unchanged, the field still exists with its old meaning. `multiroom-load-2026-11/regenerate.py` keeps reading it, and its README's caveat stays true.
- New JSONL, old client: the old client ignores unknown keys.

## Not in scope

- Changing the fold rule or the phase lock. The fold is intended (the sync never overtakes a coincident tick). Only the measurement changes.
- Rerunning the 2026-11-06 data. Its late count can't be recovered from the raw profile, which has no lateness.

## Verification

- `swift build`, then `swift test --filter InTurnSyncFold` and the profiler counter suite, then the full `swift test`.
- `cd Examples/GameDemo/ws-loadtest && npm test` and `npx tsc --noEmit`.
- One profiled 100-room ws-loadtest run on the Mac, to check the JSONL carries the new keys and the report renders them (not a performance number).
- E2E: `./Tools/CLI/test-e2e-game.sh` for the Examples commit.

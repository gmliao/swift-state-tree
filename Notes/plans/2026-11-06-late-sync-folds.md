# Late sync folds: count a fold as late only beyond the coincident window (#232)

Status: open, rev 2. Rev 1 was reviewed GO with no blocking finding. Rev 2 measures lateness at the tick turn that carries the fold (should A), adds the exact-deadline and double-fold tests (should B), states that the figures are server-wide and that the threshold is printed next to them (should C), and documents the field-overflow and max-window behaviour.

## Problem

`syncOverdueFolds` counts a fold as overdue when the tick's deadline has passed by any amount (`deadline < now`, `LandKeeper.runSync`). A land's tick and sync loops are phase-locked (`LandLoopPhase.offset`; Hero Defense syncs every 100 ms = 2 × its 50 ms tick), so every sync deadline sits within about a millisecond of a tick deadline. Which loop runs first after the shared deadline decides the count, so it measures a scheduler race. The 2026-11-06 rerun on the 7600X shows 276–388 per 1000 cycles at every room count, including 100 rooms with no skipped cycles.

The impairment experiment needs a count that means "the sync waited for a tick that was really late", and the size of that wait.

## Decision: add, don't redefine

The existing field keeps its name and its definition. The new definition goes in new fields.

- **Why not redefine `syncOverdueFolds`:** the 2026-11-06 data (`deep-research/multiroom-load-2026-11/`) and the A/B data (`deep-research/multiroom-load-2026-11-server-ab/`) carry `syncOverdueFolds` with the race definition. If the same name meant something else in later data, a reader couldn't tell from a report which one it holds, and comparing an old and a new report under one name would be wrong without warning. The report labels it "past deadline (loop race)".
- **Where lateness is measured: at the tick turn, not at the fold.** At the fold the tick hasn't run yet, so `now − deadline` there is only a lower bound on how long the folded frame waits. A starved tick task would show a small lateness at the fold and a long real wait. The keeper records the deadline when the sync folds, then measures `tickStart − deadline` when the tick turn that carries the fold starts.
- **One record per folded tick turn, written at that turn's start.** The fold, its overdue flag (decided at the fold, as today) and its lateness go to the transport together. The invariants per window are then late ≤ folds and overdue ≤ folds. A fold can be late without being overdue: the deadline was still ahead at the fold, and the tick started late.

## Definitions

When the sync loop folds into the next tick turn (`deadline − now ≤ coincidentSyncWindow`, unchanged), the keeper keeps `foldDeadline = nextTickDeadline` and `overdueAtFold = deadline < now`. When that tick turn starts, `lateness = tickStart − foldDeadline`.

| Counter | Counts a folded tick turn when | Meaning |
|---|---|---|
| `syncFolds` | always (meaning unchanged) | a sync joined a tick turn |
| `syncOverdueFolds` | `overdueAtFold` (unchanged) | the deadline had passed when the sync loop ran; mostly the loop race |
| `syncLateFolds` (new) | `lateness > coincidentSyncWindow` | the tick turn started later than what counts as coincident |
| `syncFoldTickLatenessMaxUs` (new) | max of `lateness` over the window's folded turns, µs, 0 when none was positive | how late the frame's tick started, at worst |

- **Threshold:** the keeper's `coincidentSyncWindow` (min(5 ms, tick / 4, sync / 4)), so it follows the land's own intervals. The comparison is strict: a turn starting exactly at `deadline + window` isn't late.
- **Server-wide:** like every profile field, these are summed (counts) or maxed (lateness) over all lands in the window, not per land.
- **Reading a window:** `late = 0` with a max at or under the window is consistent. The report prints the threshold next to the max, so the reader can see that.
- **When `syncFolds` is counted:** at the start of the folded tick turn, not at the fold, so a fold near a window edge can land in the next window. Its meaning per cycle is unchanged, and the 2026-11-06 ratios stay comparable.
- **A fold whose tick turn never runs isn't counted.** The land is destroyed or frozen first, and the fold has no frame to delay.

## Changes

### Sources (PR, core)

1. **`LandKeeperTransport`** (`Sources/SwiftStateTree/Runtime/LandKeeperTransport.swift`):
   - Replace `noteInTurnSyncFold(overdue: Bool)` with `noteInTurnSyncFold(_ fold: InTurnSyncFold)`.
   - `InTurnSyncFold` is a small public struct: `overdueAtFold: Bool`, `tickLateness: Duration`, `coincidentWindow: Duration`, and a computed `isLate` (`tickLateness > coincidentWindow`). The classification lives in one place.
   - The default implementation stays a no-op.
   - The old requirement is removed, not deprecated. It had a default implementation, so an external conformer still compiles; its own method just goes unused. The PR body says so.
2. **`LandKeeper`:**
   - `runSync` stores `pendingFold = (deadline, overdueAtFold)` when it sets `inTurnSyncDue` by a fold. It stores only once per tick turn, since a second sync iteration before the tick finds `inTurnSyncDue` already set, as today.
   - The tick turn that consumes `inTurnSyncDue` takes `pendingFold`, computes the lateness from its start instant, updates `foldedSyncs`, `overdueFoldedSyncs` and the new `lateFoldedSyncs` (diagnostics, with `cadenceCountersForTesting`), and calls the transport if `recordsInTurnSyncFolds`.
   - The fold decision itself is unchanged, so the runtime behaviour is unchanged: only what's counted, and when, changes.
   - The tick-start instant comes from a testing clock hook, like `syncClockForTesting`, so tests fix it.
3. **`TransportProfilerCounters`** (`TransportProfilingActor.swift`):
   - `incrementSyncFolds(overdue:)` becomes `recordSyncFold(_:)`.
   - **Packing:** the three counts stay in one atomic word, so a window never splits a fold and the invariants hold per window. That's 21 bits each: folds bits 0–20, overdue 21–41, late 42–62, with one increment per fold and one exchange per window.
   - **The limit is 2,097,151 per field per window.** At 10 folds per land per second and the 1 s default window, that's about 200,000 lands; the profile interval's floor is 100 ms. A field past its limit carries into the next field. The doc comment states this, and a test pins it: a field at its max plus one increment.
   - **`syncFoldTickLatenessMaxUs`** is a separate `ManagedAtomic<Int>` with the existing `storeMax`. It's exchanged first in `takeAndResetSync`, before the packed word. A fold recorded between the two exchanges then counts in the next window while its lateness stays in this one. The doc comment says so: the max can belong to a fold counted in the neighbouring window.
   - The JSONL line gains `syncLateFolds` and `syncFoldTickLatenessMaxUs`. Existing keys don't change.
4. **Tests** (Swift Testing, deterministic, no timing), in `Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift` and `Tests/SwiftStateTreeTransportTests/TransportProfilerSyncCountersTests.swift`. Both are updated for the new signatures.
   - **Keeper, fixed clocks for the sync iteration and the tick start:**

     | fold at | tick starts at | overdue | late | lateness |
     |---|---|---|---|---|
     | deadline − 1 ms | the deadline | no | no | 0 |
     | exactly the deadline (lateness 0) | the deadline | no | no | 0 |
     | deadline + 1 ms | deadline + 1 ms | yes | no | 1 ms |
     | deadline + window | deadline + window | yes | no (strict) | window |
     | deadline − 1 ms | deadline + 20 ms | no | yes | 20 ms (late, not overdue) |
     | deadline + 20 ms | deadline + 20 ms | yes | yes | 20 ms |

   - **Two sync iterations before one tick turn:** one record, with the first fold's deadline.
   - **Profiler:** each classification gives the right counts and max; an exchange resets all of them; and the field-overflow case above.
   - **Mutation checks before the PR:** each of these must fail a test:
     - `>` → `>=` in `isLate`;
     - `<` → `<=` in the overdue check;
     - lateness taken at the fold instead of at the tick start;
     - a dropped `storeMax`;
     - the late bit in the overdue field;
     - recording twice for one tick turn.

### Examples (direct to main, after the PR merges)

5. **ws-loadtest `server-sync.ts`:** the new fields go in a separate optional list. `parseProfileWindows` keeps requiring only the six existing fields, so the 2026-11-06 and `b629861` profiles parse as today. The summary adds `lateFoldsPer1000Syncs` and `foldTickLatenessMaxUs` (the max over the phase). Each is `null` unless every counted window carries the field, the same rule as `sumIfEvery` in `server-send.ts`. The report shows "n/a", never 0, for older data.
6. **Report (`render-html.ts`):** lead with folds / cycles and the late folds per 1000 cycles. Next to them go the max lateness in ms, with the threshold, and a note that the figures are server-wide. The overdue column stays, relabelled "past deadline (loop race)".
7. **METRICS.md:** replace the "Until #232" caveat with the definitions above: where lateness is measured, the threshold, server-wide, and the max-window note. Add how to read older reports: late and lateness are n/a.
8. **Tests (vitest):**
   - an old-format profile summarizes as before, with the new figures `null`;
   - a mixed profile, with some windows lacking the fields, gives `null`;
   - a new profile sums and maxes.

## Backward readability

- **Old JSONL from an old server:** parses unchanged; the new figures are n/a.
- **Old reports in `deep-research/`** (`serverSync.summary.totals.syncOverdueFolds`): unchanged. The field still exists with its old meaning, and both topics' `regenerate.py` keep reading it.
- **New JSONL with an old client:** the old client ignores unknown keys.

## Not in scope

- Changing the fold rule or the phase lock. The fold is intended (the sync never overtakes a coincident tick); only the measurement changes.
- Recomputing the 2026-11-06 data. Its lateness can't be recovered from the raw profile.

## Verification

- `swift build`, then `swift test --filter InTurnSyncFold` and the profiler counter suite, then the full `swift test`.
- `cd Examples/GameDemo/ws-loadtest && npm test` and `npx tsc --noEmit`.
- One profiled 100-room ws-loadtest run on the Mac, to check that the JSONL carries the new keys and the report renders them. It's not a performance number.
- E2E: `./Tools/CLI/test-e2e-game.sh` for the Examples commit.

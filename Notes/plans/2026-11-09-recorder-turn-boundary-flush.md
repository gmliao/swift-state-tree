# Recorder flush at a turn boundary signalled by the keeper (#327, option A)

Step 2 of [the core round](2026-11-09-core-round-and-full-rerun.md). Revised after Review: tick lands get no keeper signal.

## Problem

`ReevaluationRecorder` merges the calls for one tick into `pending`. Its 1 s wall-clock timer (`scheduleFlush` → `timerFlush`) writes `pending` as a `turn` record, at whatever point the keeper has reached in its tick. A tick whose calls straddle the timer becomes two `turn` records, so the file's bytes and the footer's `turnCount` depend on wall time. The reader merges the turns of one tick, so content, replay and `--verify` are unaffected.

"Write only completed ticks" fails for tickless lands. Every turn there is tick 0, so `pending` would hold the whole recording (#327, comment).

## Design

**Recorder** (`ReevaluationRecorder.swift`):
- `timerFlush()` only hands the buffer to the writer (`handOffBuffer()`). It never writes `pending`, so the timer no longer changes the bytes.
- `pending` closes, that is, it is appended to the buffer as one `turn` record, in these cases:
  - a call names a newer tick (as today);
  - `save` (as today);
  - an end-of-turn signal: `recordTick(_:endsTurn:)` or `endTurn()`;
  - the backstop.
- A call for an older tick is still its own `turn` record.
- **Tick lands send no signal.** Their split points are today's split points without the timer, so a recording whose ticks never straddled the timer keeps its exact bytes. A crash loses at most the open tick.
- **Tickless lands signal every keeper turn that recorded anything.** Split points follow keeper turns. This is new framing for every tickless file: one `turn` record per keeper turn, instead of about one per second.
- **Backstop.** At 65536 merged calls without a close, `pending` is appended. The count is deterministic. It warns once per recorder and counts in `backstopClosesForTesting`. It never trips on a tick land's normal tick, and on a tickless land it means a missed signal.
- **Test hooks:**
  - `flushForTesting()` keeps its meaning: end the turn and hand off.
  - `timerFlushForTesting()` runs exactly the timer's body.
  - `forcesTimerFlushAfterEverySubmitForTesting` runs the timer body after every call, so the timer fires at every possible point without timing.

**Keeper** (`LandKeeper.swift`). Only tickless lands (`tickHandler == nil`) signal:
- **In-turn input turn.** `runInputTurn` enqueues its record with `endsTurn: true` (through `enqueueRecorderSubmission`, which doesn't wait) as its last enqueue, after `runTurnOutputs`' sync outputs. `submitTurnRecord` then waits only for the `.turnRecord` hold and for that submission.
  - The hold moves after the enqueue. This changes the order in tests only: `HoldPoints.at` doesn't suspend when nothing is installed.
  - Both tests that use the hold need only the caller suspended. The caller resumes after `submitTurnRecord`.
- **In-turn sync-only turn** (`runSyncOnlyTurn`). An `endTurn` submission at the turn's end, if the turn enqueued a sync output or marker.
- **In-turn OnInitialize.** Its turn record carries `endsTurn`.
- **Legacy tickless pass** (`processPendingActions` with `flushOutputsImmediately`). `endTurn()` after its last recorder call, the server events from `flushOutputs`.
- **Legacy OnInitialize on a tickless land.** `endTurn()` after its calls.
- **Unchanged:** the tick turn (`runTickTurn` / `finishTickTurn`), the legacy tick path, sync outputs and markers.
- Two legacy tickless passes that interleave on the actor can still interleave their calls. That order comes from scheduling, not from the timer. It's the legacy path's existing reentrancy gap, and the backstop bounds it.

**Format.**
- The record kinds, the fields and the reader are unchanged, and the version stays 3.0. The reader merges the turns of one tick (`ReevaluationRecordLog.swift`:124–161), so any split is valid 3.0.
- `ReevaluationRecordLog`'s doc comment gets a note: a tick land's framing follows ticks, a tickless land's follows keeper turns, never time, so files are byte-reproducible.
- Step 3 (#325/#321, 3.1 `passes`) bumps the version for its own change. With per-turn tickless records, each input turn carries one pass, and the merge concatenates them in file order.

## Tests

1. **Recorder, tick-land shape.** Several calls per tick: inputs, state hash, server events, watermark. Two recorders get the same calls; one also has the forced timer flush.
   - Their saved files are byte-identical.
   - They have one `turn` per tick.
   - Without forcing, the bytes equal those the recorder writes when the timer never fires.
2. **Recorder, tickless shape.** Tick 0, several calls per turn, `endTurn` between turns. Same comparison. `turnCount` equals the number of turns, and at most one pending record is held.
3. **Keeper, end to end,** for {tick, tickless} × {in-turn sync, legacy}. One scripted run (joins, actions, ticks stepped by hand, sync-only turns) is recorded by two keepers, one with the forced timer flush.
   - IDs, seed and `createdAt` are pinned.
   - The saved bytes are equal.
   - The backstop counter is 0.
   - Replay verify passes.
   - The PR lists which header and footer fields carry time.
4. **One record per tickless input turn with sync outputs**, checked through the transport fixture: the `endsTurn` record is the turn's last enqueue.
5. **Backstop.** 65537 calls on one tick give two `turn` records, deterministically, and the counter reads 1.
6. **Mutation check.** With `timerFlush` restored to `writePending()`, tests 1–3 fail. Run once and noted in the PR, not committed.
7. **Existing suites** stay unchanged: reevaluation, replay, record log, and `cutBetweenTurnsOfOneTick`.

Gate: `swift test` in the pinned container (swift:6.2.4-noble) with `IN_TURN_SYNC` on and off, then CI on the PR.

## Overlap

- #322 (open) edits `runTick` around the tickless guard. With this revision I don't edit `runTick`.
- Code-1's step 3 adds `passes` to the record that `makeTurnRecord` builds, and to the legacy pass's `record` call. Agreed: this PR lands first and Code-1 rebases, and neither changes the other's parameters.

# Tickless replay in recorded apply order, with per-pass sequence watermarks (#325, #321)

Step 3 of [Core round and full rerun](2026-11-09-core-round-and-full-rerun.md). Line numbers are from `main` with #322 merged.

## Problem

A live tickless land records every input turn under tick 0. The recorder appends each turn's inputs to that frame in apply order, but in three lists (actions, client events, lifecycle inputs), and the frame carries no sequence watermarks.

Replay (#322) loads the whole tick-0 frame into `pendingItems` and applies it in one pass, sorted by `(resolvedAtTick, sequence)` (`readyPendingItemsInOrder`, `LandKeeper.swift:2425`). That causes two problems:

- **#325, order.** An input whose resolvers finish after an input with a higher sequence applies after it live, but replay applies it before. If their handlers don't commute, replayed state differs from live state, and nothing catches it: a tickless land records no per-tick state hash.
- **#321, numbering.** Live, each input takes a sequence number on arrival, and its handler's events take numbers in the pass that applies it (for example actions 0, 2, 4 with events 1, 3, 5). Replay can't restore the counter before each pass, so it numbers the events 0, 1, 2, and the verdict is `passedIgnoringSequence`.

The action completion queue (PR 4) makes out-of-sequence completion the normal case within one session, so it waits for this.

## Format change: record format 3.1

A tick frame gains one optional field, `passes`. Each pass describes one live application of inputs:

```swift
public struct ReevaluationRecordedPass: Codable, Sendable, Equatable {
    /// The shared sequence counter right before the pass applied its first input.
    public let sequenceBefore: Int64
    /// The applied inputs' sequence numbers, in apply order, across actions, client events
    /// and lifecycle inputs (one counter numbers all three, so a sequence names one input).
    public let inputs: [Int64]
}
```

- **Where it lives.**
  - `ReevaluationTickFrame.passes`, decoded with `decodeIfPresent ?? []`.
  - The 3.x `turn` record's `passes`, left out when empty.
  - `ReevaluationTickRecord.passes`.
  - Merging appends, as for the input lists: `ReevaluationTickRecord.merging`, `ReevaluationTickFrame.merging`, the frame assembler and the 2.6 legacy frame model kept for the round-trip test.
  - The inputs themselves stay in their three lists, unchanged. A pass names them by sequence, so nothing is stored twice.
- **Who writes it.** Only tickless lands (no tick handler), on both live paths:
  - The legacy pass (`processPendingActions`, `:2657`). Reached from `runLegacyPass` and the off-path tickless callers. The tick path's call (`runTick`, `:3003`) records no pass, since it has `sequenceBeforeInputs` already.
  - The in-turn input drain (`runInputTurn`, `:3617` → `makeTurnRecord`).

  Each captures `outputCollector.nextSequence` synchronously before `applyInputs` and records one pass with the sequences `applyInputs` applied, in its order. A pass that applied nothing records nothing.
- **Record order equals apply order.** Replay applies passes in record order, so the record order must be the live order.
  - Today the legacy pass applies synchronously and then records through `await recorder.record(...)` (`:2676`), a direct actor call after an await. Two legacy passes can interleave there: pass 2 runs while pass 1's record call is still in flight. Their order in the file then depends on how the recorder's jobs are ordered.
  - Sorting by `sequenceBefore` can't repair this, because two passes without events can tie.
  - So the legacy tickless pass submits its inputs and its pass through `enqueueRecorderSubmission` (the ordered submission queue), synchronously after `applyInputs`, as the in-turn path does.
  - In the same synchronous segment it takes its server events and its sync requests (`syncRequestsByTick` of the shared tick id), and runs them after the record, in the old order (broadcast-only sync, events, sync requests). A pass that runs during another's hold can't then take or run that pass's events or sync requests.
- **Tick lands record no passes.** Their frames are unchanged. The sync-output goldens still move, in their version bytes only (preamble minor, header `format`, metadata `version`), and are regenerated; their frames stay byte-identical, and the tick-land replay tests don't move.
- **Version.**
  - `formatVersion` goes from (3, 0) to (3, 1): the field is optional and additive, so the major stays.
  - The 3.x reader keeps accepting any minor of major 3. A 3.0 record reads as before, with no passes.
  - A 3.0 build reading a 3.1 record ignores the unknown key, so it replays a tickless land in sequence order, today's behavior. Readers and records here come from the same build, so the docs note this rather than force a major bump.
- **JSON (2.x export, `ReevaluationRunner --convert`).** The frame's `passes` is written when non-empty, so a converted 3.1 record keeps its order.

## Replay

`runTick`, re-evaluation mode, on a tickless land. Replay runs each recorded pass as an input turn, through the same functions the live drain uses (the maintainer's choice, 2026-11-09), not a second apply loop:
- **Frame with passes.** Load the frame's inputs as today, indexed by sequence. Then a replay drain:
  1. `await holds.at(.inputDrain)`, as `runInputDrain` does;
  2. the strict check below, on the whole ready set, before any turn runs: a failing frame applies nothing;
  3. for each pass in recorded order: restore the counter to `sequenceBefore` (`restoreSequenceWatermark`), then `runInputTurn` with the pass's inputs in its listed order, with no `await` in between; then `submitTurnRecord` with the turn's record, which holds at `.turnRecord` and records nothing in replay (no recorder).

  `runInputTurn` is unchanged for live. Its live-only parts (taking events and running the sync phase) are already gated on `usesInTurnSync`, which requires `.live`. In replay it keeps no outcome for a waiter, since replay has no callers. The frame's events stay in the collector and are flushed once at the end, as today. Their sequences now match live, because each pass's counter is restored.
- **#322's guard.** `runTick` sends a tickless frame with passes to this replay drain at the one site where #322 made tickless replay take the recorded-tick path. A frame without passes keeps #322's path.
- **Strict.** The tick fails replay, with a "record passes don't match its inputs" reason, when any of these breaks. The check runs before any turn, so a failing frame applies nothing, and a missing input is never applied silently in sequence order.
  - Every loaded input appears in exactly one pass.
  - Every listed sequence names a loaded input.
  - `sequenceBefore` doesn't decrease in record order, so a record inversion fails rather than replaying the wrong order.
- **OnInitialize is outside the passes.** Its lifecycle input sits in the tick-0 frame (`:967`–`996`), but replay applies it before tick 0 from the initialize record, and tick 0 skips it (`:369`–`370`). No pass names it, and the strict check leaves it out.
- **Frame without passes.** These are 3.0 and 2.x tickless records, plus every tick land's frame. The path is today's: one sorted pass. A tickless one keeps `passedIgnoringSequence`.
- **`ReevaluationSource`.** Gains `getPasses(for:) -> [ReevaluationRecordedPass]`. A default implementation in a protocol extension returns `[]`, so outside conformers still compile. The three sources in `ActionSource.swift` implement it.
- **Engine.** A frame with passes counts as watermarked (`watermarkedTicks`, `ReevaluationEngine.swift:324`), so a sequence-only mismatch there is `failed`, not `passedIgnoringSequence`.

## Tests

Swift Testing. The interleaving is forced with a `TestGate` in the resolver, never by timing.

1. **#325, order across sessions.** A tickless land with a recorder.
   - Action A (gated resolver) appends `"A"` to a list; action B (no resolver) appends `"B"`.
   - A comes from player 1, then B from player 2. B applies, then the gate opens.
   - Live is `["B", "A"]`, the replay equals it, and the verdict is `.passed`. Red today, where replay gives `["A", "B"]`.
2. **Across kinds.** The same, with a client event overtaking the pending action, and a lifecycle input (a join) between them.
3. **#321, sequences.** A pass that applies several inputs (the legacy pass with three queued inputs), and three one-input turns. The replayed event sequences equal live ones, and the verdict is `.passed`. #322's tickless test changes from `.passedIgnoringSequence(ticks: [0])` / `[0, 1, 2]` to `.passed` with live sequences.
4. **Both live paths.** Tests 1 and 3 run with the in-turn drain and with the legacy pass. The suite already runs under both `IN_TURN_SYNC` modes, and a test pins the path where it matters.
5. **Old records still replay.**
   - A 3.0 tickless record (written with passes stripped, header "3.0") replays in sequence order with `passedIgnoringSequence`, as today.
   - A 2.x JSON tickless record does the same.
6. **Strict check.** A frame fails replay with that reason when its passes:
   - miss an input;
   - list an unknown sequence;
   - have a decreasing `sequenceBefore`.
7. **Record order under interleaving.**
   - The `.turnRecord` hold moves after the legacy pass's synchronous enqueue: after the record is enqueued, before it is written. #327 makes the same move on the in-turn paths, and after the rebase both legacy and in-turn passes hold after their enqueue.
   - The test holds the first legacy pass there, runs a second pass, then releases the hold.
   - It requires the live order in the record and `.passed`, with no alternative outcome. The inverted record is test 6's case (a decreasing `sequenceBefore`). The direct-`await` mutant enqueues after the hold, so the record is inverted and this test fails.
8. **OnInitialize with resolvers.** A tickless land whose OnInitialize has resolvers, plus a join and actions, replays `.passed`.
9. **Many turn records in tick 0.** Three or more tick-0 turn records, each carrying a pass, which is the shape of a real recording after #327. The reader concatenates their passes in file order, and replay is `.passed`.
10. **Format.**
   - The header says "3.1", and a 3.0 header is still read.
   - Turn records with passes merge by appending.
   - The legacy-model round-trip test covers passes.
   - A tick land's record carries no passes.

Mutants, each to be killed by the tests above:
- replay ignores passes (sorted order);
- the watermark not restored per pass;
- the pass captured after `applyInputs`;
- the strict check removed;
- the legacy pass recorded with a direct `await recorder.record` again (the interleaving test fails);
- passes recorded on tick lands.

## Docs

`docs/core/reevaluation.md` and `.zh-TW.md`:
- the tickless note (`:52`): exact order and sequences from 3.1, and what older records still get;
- a short 3.1 entry in the version notes, including the 3.0-reader caveat.

No wire change, no SDK change and no codegen.

## Out of scope

- A per-turn state hash for tickless lands.
- Tick lands: their order is already the live order.
- The action completion queue's tickless unblocking. That's PR 4, after this.

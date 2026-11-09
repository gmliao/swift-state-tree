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
- **Tick lands record no passes.** Their frames are byte-for-byte unchanged, so the sync-output goldens and the tick-land replay tests don't move.
- **Version.**
  - `formatVersion` goes from (3, 0) to (3, 1): the field is optional and additive, so the major stays.
  - The 3.x reader keeps accepting any minor of major 3. A 3.0 record reads as before, with no passes.
  - A 3.0 build reading a 3.1 record ignores the unknown key, so it replays a tickless land in sequence order, today's behavior. Readers and records here come from the same build, so the docs note this rather than force a major bump.
- **JSON (2.x export, `ReevaluationRunner --convert`).** The frame's `passes` is written when non-empty, so a converted 3.1 record keeps its order.

## Replay

`runTick`, re-evaluation mode, on a tickless land:
- **Frame with passes.** Load the frame's inputs as today, indexed by sequence. Then, for each pass in recorded order:
  1. restore the counter to `sequenceBefore` (`restoreSequenceWatermark`);
  2. apply the pass's inputs in its listed order (`applyInputs`);
  3. remove them from `pendingItems`.

  The frame's events are flushed once at the end, as today. Their sequences now match live, because each pass's counter is restored.
- **Strict.** The tick fails replay, with a "record passes don't match its inputs" reason, when any of these breaks. A missing input is never applied silently in sequence order.
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
   1. Hold the first legacy pass at the existing `.turnRecord` hold, which sits between apply and record (`:2664`).
   2. Run a second pass, then release the hold.
   3. The record holds the passes in live order, and replay gives the live state. A record that inverted them would fail the strict check, never pass silently.
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

# Replay sequence watermark (issue #50)

Status: plan, revised after adversarial check (2026-11-04). Core change (`Sources/`, `Tests/`, plus the two `Examples/*/ReevaluationRunner` callers), one PR.

## Problem

`LandKeeper` numbers actions, client events, lifecycle events and emitted server events from one shared counter (`OutputCollector.takeNextSequence()`). In re-evaluation mode the server events emitted during replay get different `sequence` values from the recording, although their content, order and tick match. `Examples/GameDemo` `ReevaluationRunner` works around this with a content-only re-check that ignores `sequence` and prints "known accounting gap".

The recording format is public (`Codable`), and `ReevaluationEngine` already orders and compares server events by `sequence`, so any consumer that merges inputs and server events into one timeline depends on these numbers matching.

## Findings that shape the fix

1. **In re-evaluation mode, almost only server events draw from the counter.** Input allocation sites are guarded: `onInitialize` (`LandKeeper.swift:486`, live only), `OnJoin` (759/920, guards at 756/915), `OnLeave` (1020, guard 1012), `handleActionEnvelope` (1148, guard 1099), `handleClientEvent` (1302, guard 1267). Replayed inputs reuse their recorded `sequence` (1868/1885/1913). Server events take numbers at `enqueueEmittedEvent` (223) through `LandContext.emitEventHandler`; sync requests do not take numbers; resolvers cannot emit (`ResolverContext` has no emit). One exception: `CanJoin` runs before the join guard (857) and can emit in re-evaluation mode — see Known limitations.
2. **`sequence` does not reach state.** `LandContext` and the transport have no `sequence`; the per-tick state hash is computed from the state snapshot. Uses: input ordering by `(resolvedAtTick, sequence)` (1492–1524), removal set (1720–1742), server-event labels (222–224, 306).
3. **The live counter value cannot be derived from recorded inputs.**
   - inputs are numbered on arrival and `resolvedAtTick` is reassigned after the resolver await (1178), so they may execute ticks later;
   - a throwing resolver (1171) has already taken its number (1148) and is never recorded;
   - `processPendingActions` awaits after the item loop (`recorder.record` 1750, `flushIfNeeded` 1758, sync 1762), before the tick handler (1955), so inputs can take numbers between the item phase and the tick-handler phase. Numbers taken during the post-handler awaits (1969–1978) are covered by the next tick's first watermark.
4. **Both watermark points are exact in a ticked land.** The item loop (1536–1717) has no `await`; in live mode there is no `await` between `nextTickId += 1` (1802) and the `processPendingActions` call (1939). Handlers run only in the item phase and the tick handler.
5. **Tickless lands are not re-evaluable today.** `runTick` returns at 1780–1792 when `tickHandler == nil`, before the source-loading block; live tickless records everything under one tick id.

## Design

**Watermarks.** Two per tick, ticked lands only:
- `sequenceBeforeInputs` (W1): `outputCollector.nextSequence` right before the `processPendingActions` call in `runTick` (~1939);
- `sequenceBeforeTickHandler` (W2): `outputCollector.nextSequence` right before the tick handler (~1955).

**Live capture (no new suspension points).** Read both values synchronously into locals inside `runTick` and pass them to the existing end-of-tick `recorder.record(...)` call (~1982) as new optional parameters. Do not add any `await` to the live path before 1955. Capture only in `runTick`, never in the `processPendingActions` calls made from join/leave/action/client-event paths (807/970/1070/1203/1330). When `tickHandler == nil`, write no watermarks.

**Storage.** `ReevaluationTickFrame` gains two optional `Int64` fields:
- add both keys to the private `CodingKeys` (otherwise the synthesized `encode(to:)` silently drops them) and decode with `decodeIfPresent`;
- make the recorder keep them across every frame rebuild (`record`, `recordLifecycleEvent`, `setStateHash`, `recordServerEvents`, and the new-frame branches): either make the frame fields `var` and mutate in place, or forward the watermarks at every rebuild site.

**Read path.** Add a `ReevaluationSource` requirement (e.g. `getSequenceWatermarks(for tickId:)`) with a default implementation returning `nil` in a protocol extension, so external conformers keep compiling; `JSONReevaluationSource` overrides it.

**Replay restore.** In re-evaluation mode, at W1 (after the source-loading awaits, immediately before the `processPendingActions` call) and at W2 (before the tick handler), if the watermark is present:
- counter ≤ watermark → assign `outputCollector.nextSequence = watermark` (already a `var`, plain assignment);
- counter > watermark → do not move the counter back; leave it. The per-tick server-event comparison catches the extra event (see next point).
- watermark absent (legacy recording) → leave the counter alone.

**Comparison backstop.** In `ReevaluationEngine` (~147), compare recorded and emitted server events whenever **either** side is non-empty (today an extra event in a tick where live emitted nothing is never flagged). The existing strict compare already checks `sequence`. The count/content comparison is the backstop for anything the watermark rule hides (e.g. a missing item-phase event is masked at W2 but still caught by count).

**Runners.**
- `Examples/GameDemo/Sources/ReevaluationRunner/main.swift`: when every frame has watermarks, compare strictly including `sequence` and fail on mismatch; keep the content-only fallback with its warning only for recordings without watermarks; update the comment at ~244–247.
- `Examples/Demo/Sources/ReevaluationRunner/main.swift` already fails strictly (~176–182); confirm it passes with watermarked recordings.
- Monitor path (`ReevaluationRunnerImpl.swift` ~229): confirm it still displays both lists; no behaviour change intended.

Not changed: sequence semantics (one shared counter, global order), input ordering, state hashing, wire format to clients, live timing.

## Known limitations (out of scope, tracked in #66)

- **OnInitialize events in live mode** are tagged tick `-1` (`LandKeeper.swift:488–493`), never flushed, never sent, never recorded; replay runs the same handler at tick 0 and emits them. With the comparison backstop, a land that emits from `OnInitialize` will now be flagged at tick 0. This is a pre-existing live bug (events dropped), not caused by this change. Hero-defense does not emit from `OnInitialize`.
- **`CanJoin` in re-evaluation mode** runs before the join guard and can emit, taking a number and leaking an event when a viewer joins a replay land. Treated as a known limitation; hero-defense's `CanJoin` does not emit.

## Tests (Swift Testing, written first)

1. **Crafted-frame W2 test (deterministic).** Build `JSONReevaluationSource(metadata:frames:)` with W1 = 10, W2 = 15, one action that emits and a tick handler that emits; expect emitted sequences 10 and 15.
2. Record and replay a land whose action handlers and tick handler both emit, with inputs arriving across several ticks: replayed server events equal the recorded ones including `sequence`.
3. A throwing resolver (number consumed, nothing recorded) between two emitting ticks: still identical.
4. A resolver that completes one or more ticks after arrival, made deterministic with a gated resolver (continuation released after one or more `stepTickOnce` calls; actor reentrancy allows stepping while `handleActionEnvelope` is suspended): still identical.
5. Encode/decode round-trip of the new fields (save → `JSONReevaluationSource(filePath:)` → watermarks present), and watermarks survive the recorder methods called in live order (`record` → `setStateHash` → `recordServerEvents` → `record`).
6. Legacy recording without watermark fields decodes and replays; GameDemo runner uses the content-only fallback.
7. Extra replay event: crafted frames with a too-low watermark; the counter is not moved back and the tick is reported as a server-event mismatch.
8. Extra replay event in a tick where live emitted nothing is reported (comparison backstop).
9. Live behaviour unchanged: the same live run with recording on and off yields identical sent server-event sequences and action execution ticks. Review check: `runTick` gains no new `await` before the tick handler.
10. Tickless land: no watermarks written; behaviour unchanged.
11. `OnInitialize` emitting an event: assert the current, documented outcome (flagged at tick 0), so strict mode's behaviour there is deliberate.

## Verification

Repository verification rules for `Sources/` + `Tests/` (+ `Examples/`) changes: full `swift test`, `swift build -c release`, required E2E suites. Paste raw closing lines in the PR.

## Execution and review units

- Inline, test first. One review unit (the whole PR), reviewed through the normal PR review (core PR → dual track).

## Out of scope

- Re-recording and re-running the 41-recording replay batch with watermarks (follow-up after merge).
- Changing what `sequence` means.
- Fixing the two known limitations above (#66).

## Prior notes checked

Searched `Notes/`, `docs/`, `deep-research/` for "sequence counter", "accounting gap", "takeNextSequence", "#50". Only hit: `Notes/plans/2026-08-31-replay-scale-fp-perturbation-experiment-design.md` § Findings 1, which records the gap and defers a core fix. Nothing conflicts with this design.

## Adversarial check record (2026-11-04)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Live capture into locals, written via the end-of-tick `record` call; no new awaits |
| B2 | blocking | No new reporting channel; comparison runs when either side is non-empty |
| S1 | should | `CodingKeys` extended, `decodeIfPresent`, round-trip test |
| S2 | should | Watermarks survive every frame rebuild; test |
| S3 | should | New `ReevaluationSource` requirement with default implementation |
| S4 | should | Out of scope (#66); test pins current outcome |
| S5 | should | Known limitation (#66) |
| S6 | should | Demo runner and Monitor path listed; GameDemo comment updated |
| N1 | nit | Comparison stated as backstop |
| N2 | nit | Plain assignment to `nextSequence` |
| T-a…T-h | tests | Added as tests 1, 4, 5, 7, 8, 9, 10, 11 |

## Amendments during implementation

### A1 (2026-11-04): comparison backstop applies to watermarked frames only

**Gap.** The backstop above ("compare whenever either side is non-empty") assumed every recording stores server events. `ReevaluationTickFrame.init(from:)` decodes a missing `serverEvents` key as `[]`, and seven checked-in recordings predate that field (no frame has the key): `Examples/GameDemo/reevaluation-records/1-hero-defense.json`, `2-hero-defense.json` and the five `hero-defense-2026-01-25T05-*.json` files. Hero-defense emits server events during replay, so with the rule as written every tick where replay emits an event in those files would be reported as a mismatch, and `GameDemo ReevaluationRunner --verify` on them would go from passing to exit 6. No required test or E2E suite uses those files (Swift tests use `3-hero-defense.json`, which has server events; the E2E scripts record fresh).

**Decision.** `ReevaluationEngine` compares when the frame carries sequence watermarks, or when the recorded list is non-empty. Frames without watermarks keep the previous rule (compare only when something was recorded).

**Why.** Watermarked frames always come from recorders that store server events, so an empty recorded list is meaningful there; the stricter check becomes part of the new format's guarantee. Legacy behaviour stays exactly as before, and no extra decode flag is needed.

**Tests.** Tests 7 and 8 use watermarked frames; test 8 adds a legacy (no-watermark) frame showing the old rule still applies.

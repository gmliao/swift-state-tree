# Keep late-queued events for the next sync cycle (issue #77)

Status: plan, revision 2 after adversarial check (2026-11-04). Core change (`Sources/SwiftStateTreeTransport/`, `Tests/`), one PR. Lands before #60.

## Problem

With `opcodeMessagePack`, server events are queued in `PendingEventManager` (`EventSendingPipeline.queueForMergedSend`) and delivered by the next sync cycle. Every cycle that sends ends with `cleanupPendingSyncEvents()` → `pendingEventManager.clearAll()`, which drops **every** queued event, including those queued after the cycle last read the queue. `TransportAdapter` is a reentrant actor and the cycle awaits between reading and clearing, so events emitted by ticks or handlers during that window are never sent.

## Findings (origin/main d365564)

1. **Queue.** `PendingEventManager` holds two append-only arrays, `targetedEvents` and `broadcastEvents`; the only removal is `clearAll()`. Queueing is synchronous (`EventSendingPipeline.swift` ~39–67).
2. **Where `runSyncNowCycle` (~1254–1317) reads the queue (opcode 107):**
   - broadcast events: once, in `sendMergedBroadcastUpdateIfNeeded` (~1398–1458) when it builds the merged frame (`pendingBroadcastBodies()` ~1424/1440), synchronously before any await in that function;
   - targeted events: in `buildSendBatch` (prefix up to `targetedEventsSentInBatch.eventCount`, recorded by #76), then in `flushTargetedEventBodiesIfNeeded` (~1597–1615), which reads per session **at loop time** and awaits `sendEventBodiesSeparately` between sessions.
   - then `cleanupPendingSyncEvents()` (~1310) clears everything.
3. **Loss windows in `runSyncNowCycle`:**
   - broadcast events queued after the merged frame is built (during `Task.yield()`, the batch send, the flush) — lost;
   - targeted events queued during the flush loop — delivered to sessions iterated later, **lost for sessions already iterated**;
   - anything queued between the end of the flush and `cleanupPendingSyncEvents()` — none today (no await), but fragile.
4. **`_syncBroadcastOnlyImpl` (~1639–1673)** has the same shape: `sendBroadcastUpdate` reads broadcast events (~1772), `sendPendingTargetedEvents` (~1850) loops with awaits, then `cleanupPendingSyncEvents()`. Its early return (no players or empty diff) skips the cleanup, so events stay queued (fine, unchanged).
5. **No eligible session.** If no joined session outside initial sync exists, `sendMergedBroadcastUpdateIfNeeded` (~1406) and `sendBroadcastUpdateWithEvents` (~1735–1739) return before reading events, and the cleanup drops them. Keep today's drop. Reason: initial-syncing players already lose events emitted during their join window **even when an eligible session exists** (every send loop skips them and the cleanup removes the events, although their stamps are valid). Keeping events only in the all-initial-syncing case would be inconsistent with that and would hand a joiner events already reflected in its firstSync snapshot. The correct boundary is the firstSync snapshot point, which is #69.
6. **Throw path.** If the cycle throws before the cleanup (encode error), events stay queued and go out next cycle. Unchanged.
7. **json / opcodeJsonArray:** events are not queued (sent when emitted). Unaffected.
8. **Dead readers.** `sendEncodedUpdate` (~2113, reads broadcast bodies when `mergeEvents`) and `syncState` (~2184) have no callers; if revived they would bypass the marks. Delete them in the #60 cleanup.
9. **Kept events need a cycle to deliver them.** A sync request made while a cycle is in flight is rejected by `beginSync` and dropped, not queued. Ticked lands sync on the next tick; a tickless land would keep the events until an unrelated sync request arrives, possibly never.

## Design — remove only what the cycle consumed

- `PendingEventManager`:
  - `var broadcastEventCount: Int` (next to the existing `targetedEventCount`);
  - `pendingTargetedBodies(..., startingAt:, endingBefore:)` — read a half-open slice `[start, end)`; `end` defaults to the current count;
  - `mutating func removeConsumed(targeted: Int, broadcast: Int)` — drop the first `targeted` / `broadcast` entries (clamped, with `assert(n <= count)`), replacing `clearAll()` at the end of a cycle. Keep `clearAll()` for other callers if any.
- `TransportAdapter`: consumption marks are **per-cycle values**, never stored across cycles. Each cycle starts with `marks = (targeted: 0, broadcast: 0)` (0 = remove nothing); the readers return or update the cycle's marks; cleanup uses them. A cycle that throws before cleanup removes nothing (events stay for the next cycle, as today), and no later cycle can see a stale mark.
  - **broadcast mark** = `broadcastEventCount`, taken in the same synchronous block that reads `pendingBroadcastBodies()` (merged frame in `sendMergedBroadcastUpdateIfNeeded`; `sendBroadcastUpdateWithEvents` in broadcast-only cycles). Both readers read synchronously and only await afterwards;
  - **targeted mark** = `targetedEventCount`, taken at the **start** of `flushTargetedEventBodiesIfNeeded` / `sendPendingTargetedEvents`, **before** their `hasTargetedEvents` guard and before any await. Every session reads `[startIndex, mark)`, with `startIndex` = #76's batch offset for served sessions, 0 otherwise. Events queued during the flush loop stay for the next cycle for **all** sessions;
  - **no-duplicate conditions** (state them in a comment): (a) the targeted mark is taken before the guard and any await; (b) the #76 batch offset is ≤ the flush mark (the queue is append-only between batch and flush); (c) `removeConsumed` removes exactly `[0, mark)`;
  - **no eligible session** (finding 5), in both `runSyncNowCycle` and the broadcast-only cycle: set both marks to the current counts (drop, as today), with a comment pointing to #69.
- `cleanupPendingSyncEvents(marks:)` calls `pendingEventManager.removeConsumed(...)` and resets `targetedEventsSentInBatch`.
- **Follow-up sync for kept events** (finding 9), **tickless lands only**:
  - the cycle returns a "kept events remain" flag (queue non-empty after `removeConsumed`); a throwing cycle sets no flag;
  - `withSyncState` issues the follow-up `syncNow` request only **after `await keeper.endSync()` has returned**. A request made inside the cycle, or from an unstructured task that may reach `beginSync` before `endSync` ran, is rejected and dropped;
  - only when the land has **no periodic sync**: expose a `nonisolated` `hasPeriodicSync` on `LandKeeper`, true when loops are auto-started (`autoStartLoops`) and either the tick loop is configured (`tickInterval != nil` and `tickHandler != nil`) or a sync loop runs (`effectiveSyncInterval != nil`) — see `LandKeeper.swift` ~556–585. `tickHandler != nil` alone is wrong both ways (a tick handler without interval, or `autoStartLoops == false`, has no periodic sync; `StateSync(every:)` without a tick handler has one). With periodic sync, the next periodic cycle delivers kept events; a follow-up there would roughly double cycles under load (hero-defense emits broadcast events every tick).
  - bounded in tickless lands: a follow-up runs only if events arrived during the previous cycle, so a steady event source gives back-to-back cycles that each carry real events, no runaway.
- Ordering consequence: an event kept for the next cycle is delivered by that cycle — broadcast ones inside its merged frame, targeted ones in its batch before the session's per-player frame. Update the per-frame order doc on `runSyncNowCycle` with one bullet ("events queued after the cycle read the queue are delivered by the next cycle"), keeping #60's wording intact.

## Tests (Swift Testing, written first)

Use the suspending-transport technique from #74/#76 (send held on a test-controlled continuation); explicit `TransportEnvConfig`; `opcodeMessagePack`.

1. Broadcast event queued while the cycle is held in the batch send: arrives exactly once, in the next cycle's merged frame. Fails on d365564 (never arrives).
2. Targeted events for two sessions queued while the flush is held **between sessions**: the flush awaits `transport.send` per body (`sendEventBodiesSeparately`), so the suspending transport gates `send`, not `sendBatch`. Each event arrives exactly once at its own session, next cycle. Fails on d365564 (lost for the session iterated first).
3. Broadcast-only cycle: a broadcast and a targeted event queued during its held send are delivered by the next cycle, exactly once.
4. No duplicates across cycles: state the exact expected frame counts per session for cycles N and N+1 (events read by N are not resent by N+1).
5. Drop cases (pin current behaviour, see #69): (a) all members initial-syncing, in both `syncNow` and broadcast-only cycles: queued events are dropped and the queue returns to 0; (b) one eligible plus one initial-syncing session: the initial-syncing one does not receive events emitted during its join window.
6. Throw path: an encode failure after the broadcast read (e.g. at the merged-frame pack) removes nothing; the next cycle delivers the events once, and no stale mark affects a later cycle whose reader is skipped.
7. No periodic sync (`hasPeriodicSync == false`, e.g. tickless, no `StateSync`): an event queued during a held cycle arrives through the follow-up sync without any further external sync request (this also fails if the follow-up is issued before `endSync`). Fails on d365564.
7b. Periodic sync (`hasPeriodicSync == true`, tick loop running), an event emitted during every cycle: the number of sync cycles does not exceed ticks + 1 (no follow-ups).
7c. No periodic sync, a handler emits an event during every cycle: cycle count stays ≤ events + 1.
7d. Tick handler but no `tickInterval` (or `autoStartLoops == false`): `hasPeriodicSync == false`, and the follow-up still delivers kept events.
8. Regression: #76's tests and the order doc tests still pass; json / opcodeJsonArray unchanged.

## Verification

Repository verification rules for `Sources/` + `Tests/`: full `swift test --build-system native` (until #71 lands), `swift build -c release`, both E2E scripts (all encodings). Paste raw closing lines.

## Execution and review units

Inline, test first. One review unit (the PR), normal PR review (core PR → dual track).

## Out of scope

- #69 (join window, including the initial-syncing event loss in finding 5), #61 (queue backpressure; also the empty-land queue growth: `_syncNowImpl` returns before `beginSync` when membership is empty, so an empty land that emits events grows the queue without bound), #60 (send ordering; delete the dead readers of finding 8).

## Prior notes checked

Searched `Notes/`, `docs/`, `deep-research/` for "cleanupPendingSyncEvents", "clearAll", "pending event", "event loss". Only hits are the #70 part of `2026-11-04-sync-dirty-flags-and-merged-broadcast.md` (served-session offset, which this plan extends with an end mark). No conflicting decision.

## Adversarial check record (revision 1 → 2)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| S1 | should | Marks are per-cycle values defaulting to 0; throw path removes nothing; broadcast-only no-eligible drop specified; tests 5a, 6 |
| S2 | should | One follow-up `syncNow` when the queue is non-empty after cleanup; finding 9; test 7 |
| F1 (rev 2 pass) | should | Follow-up issued by `withSyncState` after `await keeper.endSync()`; test 7 |
| F2 (rev 2 pass) | should | Follow-up only without periodic sync; tests 7b, 7c |
| F3 (F2 edit) | should | Predicate is `LandKeeper.hasPeriodicSync` (auto-started tick loop or sync loop), not `hasTickHandler`; test 7d |
| S3 | should | Finding 5 reasoned by the join window; recorded on #69; test 5b |
| N1 | nit | Finding 8; deletion assigned to #60's cleanup |
| N2 | nit | Empty-land growth recorded on #61 |
| N3 | nit | Test 2 gates `send`; test 4 states exact counts |
| Q | — | Readers, read-then-await, stamps, double delivery: answered; no-duplicate conditions (a)–(c) stated in Design |

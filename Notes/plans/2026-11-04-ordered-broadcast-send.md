# Ordered state-update send (issue #60)

Status: plan, revision 3 after adversarial checks (2026-11-04). Core change (`Sources/SwiftStateTreeTransport/`, `Tests/`), one PR. Lands after #68, #67 and #70.

## Problem

Clients apply state updates in arrival order, and patches are absolute (`.set` / `.delete`), so an older update applied after a newer one leaves a stale value until that field changes again. Per-session FIFO across sync cycles is a correctness condition of the sync protocol. Today it does not hold, in every encoding.

## Findings

1. **Per-session stream is FIFO, but it has two producers.** `WebSocketTransport` keeps one `AsyncStream<Data>` per session drained by one task (`WebSocketTransport.swift` ~51–76). Producers: (a) direct actor calls `send` / `sendBatch` (~168–203); (b) the lock-based `WebSocketTransportSendQueue` (~7–46, 105–141): a buffer drained by a separate task that wakes every ~0.2 ms, takes up to 64 items and calls `dispatchBatch` on the actor. Production wires (b) in (`LandManager.swift:293`). Per-session order is the interleaving of two independently scheduled producers.
2. **Routes today** (state-related frames of one session):

   | Frame | Call site | Route |
   |---|---|---|
   | per-player / combined `syncNow` update | `encodeAndSendPendingUpdates` → `sendBatchWithProfiling` (`+Profiling.swift` ~76–80) | **queued** (b) |
   | merged broadcast (opcodeMessagePack) | `sendMergedBroadcastUpdateIfNeeded` (~1411) | **direct, unstructured `Task {}` per session** |
   | `syncBroadcastOnly` (merged ~1728, separate ~1781) | `sendWithProfiling` | direct, awaited |
   | firstSync (~2252) | `sendWithProfiling` | direct, awaited |
   | targeted event bodies (~1089, 1138–1153), server events (~960/999) | `transport.send` | direct, awaited |
   | action/join responses and errors | `transport.send` | direct, awaited |

   `syncState` (~2130) and `sendEncodedUpdate` (~2059) have no callers (dead code).
3. **Reorder windows.** Cycles never overlap (`keeper.beginSync` rejects concurrent cycles; a rejected request is dropped), but `syncNow` is triggered from `flushOutputs` right after a tick and `syncBroadcastOnly` can follow immediately (tick flush, `OnLeave`). Windows: (a) the `Task {}` at ~1411 vs any later cycle; (b) queued `syncNow` frames vs a directly sent `syncBroadcastOnly` frame right after — in **all** encodings (in json / opcodeJsonArray the combined per-player update carries broadcast fields too); (c) the join window, tracked separately in #69.
4. `sendBatch` / `dispatchBatch` preserve array order per session (~206–233); the default `Transport.sendBatch` is also in order.

## Design — one route: direct and awaited

Every frame that carries state for a session goes through the transport actor with an awaited call, in the order the adapter issues them. Since cycles do not overlap and each cycle awaits its sends before `endSync`, the order of calls into the actor follows cycle order, and the per-session stream preserves it.

- `sendBatchWithProfiling`: always `await transport.sendBatch(batch)`; stop enqueueing into `transportSendQueue`.
- `sendMergedBroadcastUpdateIfNeeded`: build `[(dataToSend, .session(id))]` for all joined, non-initial-syncing sessions and `await transport.sendBatch(...)` once, instead of one `Task {}` per session. Keep `incrementStateUpdates()` per session. Remove the trailing `await Task.yield()` (note: changes scheduling fairness slightly).
- Within one `syncNow` cycle the issue order is the one #70 defines and documents: a cycle's events precede that cycle's state frame (merged broadcast 107 carries its events inside; a session's targeted events precede its per-player / combined update). This PR keeps it.
- `transportSendQueue` then has no producer. Keep the public API for this PR (the `TransportAdapter` init parameter, the `TransportSendQueue` protocol, `WebSocketTransport.transportSendQueue`) and mark the init parameter deprecated with a note; removal is a separate cleanup.
- The queue's drain task in `WebSocketTransport` (~130–140) wakes every ~0.2 ms forever (~5000 wakeups/s per land type). Start it lazily on the first `enqueue` / `enqueueBatch`, so it never runs when nothing enqueues. These are nonisolated and called concurrently from many adapters, and `drainTask` is `nonisolated(unsafe)`: start it **under the queue's `NSLock`** (e.g. an `onFirstEnqueue` closure set in init, invoked exactly once while the lock is held). Two drainers would break FIFO.

### New suspension points inside a cycle

The merged-broadcast step (today `Task {}` + yield) and the per-player step (today a non-awaited enqueue) become awaited cross-actor calls. While pending, the `TransportAdapter` actor is reentrant: joins, firstSync, disconnects and incoming messages can run between the broadcast and per-player phases. Checked cases: `perPlayerByPlayer` is computed before the first await (~1220–1224); `collectCombinedPendingUpdates` runs with no await before it; `flushTargetedEventBodiesIfNeeded` reads membership at call time and sends events only. #69 (join window) must re-check these points.

Dead code `syncState` / `sendEncodedUpdate`: leave for a separate cleanup; do not cite as send paths.

### Performance check (required in the PR)

The queue was introduced to cut actor contention on the shared transport. Measure before/after in release builds:
- `EncodingBenchmark` (sync time per cycle) at the usual room counts;
- the WebSocket load test at the highest room count used so far (update interval p95/p99, RTT p95, CPU), same machine, same settings;
- per room: count of skipped syncs (`beginSync` returned nil — the request is dropped, not queued) and the `beginSync`→`endSync` duration. One `WebSocketTransport` is shared by all rooms of a land type (`NIOLandHost.swift` ~236, `LandManager.swift` ~188), so awaited sends make every room's cycle wait its turn on that actor; the likely failure under load is silently fewer syncs, not only slower ones.
Report all in the PR. Profiler send latency after the change includes the wait for the transport actor, so it is not comparable with before; say so next to the table. **Stop and report to Main before merging if throughput or the skipped-sync rate regresses materially**; the fallback design is "everything state-related goes through the queue" (including `syncBroadcastOnly` and firstSync).

## Out of scope

- #69 (join window): tests must not join mid-run.
- #61 (unbounded queues, drain loop `break` without finishing, leaked drain task on session-ID reuse).
- #68 / #67 / #70 land first; tests here assume them.

## Tests (Swift Testing, written first)

1. **Real transport, back-to-back cycles.** Real `WebSocketTransport` with a fake `WebSocketConnection` that records frames per session, wired as in production. Drive `syncNow` immediately followed by `syncBroadcastOnly`, many iterations, several sessions: per-session cycle order is strictly increasing. Run it on current code first and report whether it fails.
2. Test 1 for `json`, `opcodeJsonArray`, `opcodeMessagePack`.
3. Client-side copy built from received patches equals the server projection after the run (dirty tracking on, #68 fixed; no joins during the run).
4. Per-session frame count and byte totals per cycle unchanged versus the expected sequence, counted per session (not only in total).
5. Within a cycle, a session's targeted events arrive exactly once and before that cycle's state frame (order documented by #70; this PR must not change it).
6. Idle land: the send-queue drain task is not running (no wakeups) when nothing has been enqueued; concurrent first enqueues from several tasks start exactly one drain task and keep FIFO.

## Verification

Repository verification rules for `Sources/` + `Tests/`: full `swift test`, `swift build -c release`, E2E for all three encodings. Paste raw closing lines in the PR, plus the performance table above.

## Execution and review units

Inline, test first. One review unit (the whole PR), reviewed through the normal PR review (core PR → dual track).

## Prior notes checked

Searched `Notes/`, `docs/`, `deep-research/` for "ordering", "Task.yield", "sendBatch", "TransportSendQueue", "out of order". No prior decision about state-update ordering; the queue's introduction rationale (actor contention) is the reason for the required performance check.

## Adversarial check record (revision 1 → 2)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Single direct-awaited route for all state frames; route table in Findings 2; user chose direct over queue; performance check required |
| B2 | blocking | Split out as #67, fixed in its own PR before this one |
| S1 | should | Findings 3 rewritten; test 1 drives `syncNow` → `syncBroadcastOnly` back-to-back |
| S2 | should | Split out as #68, lands first; test 3 assumes it |
| S3 | should | Split out as #69; tests avoid joins mid-run |
| S4 | should | Test 1 uses the real `WebSocketTransport` with a fake connection, queue wired |
| S5 | should | All three encodings in scope (test 2) |
| N1 | nit | Trailing `Task.yield()` removal noted |
| N2 | nit | Findings 2 describes the queued path |
| N3 | nit | Dead code not cited; cleanup separate |
| N4 | nit | Drain-loop issues added to #61 |
| T-a…T-f | tests | Tests 1–5 |

## Adversarial check record (revision 2 → 3)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Duplicate targeted send is an existing bug → #70, own PR before this one; #70 documents the order (events precede the state frame); test 5 updated |
| S1 | should | Performance check adds skipped-sync count and `beginSync`→`endSync` duration per room; skipped-sync regression is a stop condition |
| S2 | should | Suspension points listed with reasoning; #69 must re-check them |
| S3 | should | Drain task started lazily; test 6 |
| N1 | nit | Profiler send latency not comparable before/after; stated in the PR |

## Confirmation pass (revision 3)

| Id | Severity | Disposition |
|---|---|---|
| S1 | should | Order aligned with #70: events precede their cycle's state frame; test 5 adjusted |
| S2 | should | Lazy drain start under the queue's lock, exactly once; test 6 adds concurrent first enqueue |

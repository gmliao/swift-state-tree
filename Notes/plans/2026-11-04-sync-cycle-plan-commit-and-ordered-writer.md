# Sync cycle as plan + commit, one ordered outbound writer (issues #60, #61; supersedes the #60 "awaited send" plan)

Status: plan, revision 3 (final) after adversarial check (2026-11-04). Core change (`Sources/SwiftStateTreeTransport/`, `Tests/`), three PRs. Replaces the design in `2026-11-04-ordered-broadcast-send.md` (rev 3); that plan's tests are reused.

## Problem

`TransportAdapter` is a reentrant actor. A sync cycle reads shared state (event queue, membership, diff caches), then awaits sends, then acts on what it read before the awaits. Every recent sync bug is this shape: #68 (dirty flags cleared after an await), #70 (targeted events sent twice across batch and flush), #77 (queue cleared after awaits), #60 (frames of one session leave through different paths and overtake each other). The fixes so far (#74, #76, #82) narrow individual windows with marks, offsets and follow-ups; the cycle still has many suspension points between reading and committing.

Root cause: the cycle mixes three phases — read/compute, send, commit — and interleaves them around `await`s. This plan separates them: compute everything synchronously, commit in the same actor turn, and hand frames to an ordered writer without awaiting.

## Findings (origin/main 4edfab2)

1. **Several outbound producers per session.** `sendBatchWithProfiling` (`TransportAdapter+Profiling.swift` ~70–95) enqueues into `transportSendQueue` without await when set (production: `LandManager.swift` ~293 wires the shared `WebSocketTransport.transportSendQueue`), else awaits `transport.sendBatch`. Every other adapter send awaits `transport.send` on the transport actor directly: merged 107 frame (`TransportAdapter.swift` ~1513, one unstructured `Task` per session), targeted event bodies (`sendEventBodiesSeparately` ~1120), immediate events (~985, ~1024), action responses and errors (~708, ~899, ~2501, ~2540, ~2822, ~2862). **Outside the adapter**, `LandRouter` sends to an already joined session: after `adapter.performJoin` (`LandRouter.swift` ~452) the join response goes out directly (`sendJoinResponse` ~611, `await transport.send` + `Task.yield`) before `syncStateForNewPlayer` (~484); `sendError` (~647, ~679) is direct too. Frames of one session therefore take different paths and can reorder (#60).
2. **The queue path.** `WebSocketTransportSendQueue` (`WebSocketTransport.swift` ~8–46) is one NSLock-guarded buffer per transport, drained by a polling task started in `init` (~130–139) that sleeps 0.2 ms with `Task.sleep` when idle. `dispatchBatch` (~206) is synchronous and yields in array order into each session's `AsyncStream` (`SessionSendQueue` ~49–76), which has a single drain task awaiting `connection.send`. The per-session stream is unbounded (#61). `WebSocketTransport` sends nothing of its own besides this.
3. **Suspension points in a cycle** (`runSyncNowCycle` ~1303–1365): `beginSync` hop; merged-frame send + `Task.yield`; `encodeAndSendPendingUpdates` → `sendBatchWithProfiling` + `Task.yield`; `flushTargetedEventBodiesIfNeeded` per-session awaits; `endSync` hop. Extraction, diffing and encoding are already synchronous. `_syncBroadcastOnlyImpl` (~1719), `syncStateForNewPlayer` (~2420, `lateJoinSnapshot` mutates the engine) and #83's `debugSettle` (~3047, calls `runSyncNowCycle`) have the same shape.
4. **Diff caches advance during the diff.** `SyncEngine` is a struct; `computeBroadcastDiffFromSnapshot` (`SyncEngine.swift` ~589–604) and the per-player diff update `lastBroadcastSnapshot` / `lastPerPlayerSnapshots` (~48–51) in place. If encoding throws afterwards, caches have advanced but nothing was sent.
5. **Other state a cycle mutates on success:** `enableDirtyTracking` and its change-rate EMA via `maybeAutoSwitchDirtyTracking` (~2122), `lastUpdateSize`, profiler/state-update counters, change-object metrics, `hasReceivedFirstSync` inside the engine. `initialSyncingPlayers` and membership are only read.
6. **Window bookkeeping that exists only because of the awaits:** #76's `targetedEventsSentInBatch`, the flush loop and its mark-before-guard rule, #77's "same synchronous block" rule for the broadcast mark, the `Task.yield()` calls after sends.
7. **Shared transport.** One `WebSocketTransport` serves every land of a `NIOLandServer` (`NIOLandServer.swift` ~17–47). `.broadcast` / `.broadcastExcept` targets reach every session on it, not only this land's. Immediate `.all` events map to `.broadcast` (`EventSendingPipeline.swift` ~92–93, sent at `TransportAdapter.swift` ~1024) — to be verified separately as a possible cross-land leak in json / opcodeJsonArray (see "Separate issue"). `sendEventBody` (~1171) has no callers.
8. **Toolchain.** Swift 6.4.2, `swift-tools-version: 6.0`, `.macOS(.v14)`. `Synchronization.Mutex` needs macOS 15; `OSAllocatedUnfairLock` is Darwin-only. `AsyncStream.Continuation.yield` is synchronous and thread-safe on both platforms.

## Design

### Contract (document on the writer and on `runSyncNowCycle`)

All frames sent to a session of this land after it joins go through the adapter's one FIFO, in issue order. Per session this gives: join response, then firstSync, then cycle frames; frames of cycle N before frames of cycle N+1; within a cycle, the merged 107 frame, then that session's targeted event frames, then its per-player state frame; action responses, errors and immediate events in issue order relative to state frames. The cycle never awaits a send. Frames enqueued for a session generation that has ended are dropped, not delivered to a later connection with the same `SessionID`. The adapter never sends `.broadcast` / `.broadcastExcept`; targets are expanded to this land's sessions.

### PR 1 — one ordered outbound writer (closes #60)

- `OutboundWriter` owned by the adapter: an `AsyncStream` of elements `(frames: [(Data, EventTarget)], generations: [SessionID: UInt64])`, yielded synchronously, and one consumer task that awaits `transport.sendBatch` per element in order. The consumer captures only the transport and the stream, not the adapter.
- **One element per cycle**: the commit enqueues merged + targeted + per-player frames as one combined batch (one transport-actor hop per room per cycle).
- **Connection generation stamps** (S4, S-a): the transport is the single source of truth. `WebSocketTransport.handleConnection` assigns a connection generation per `SessionID` and passes it to the adapter on connect; the adapter stamps it per `.session` target at enqueue; `dispatchBatch` (generation-aware `sendBatch` overload) compares it with `sessionQueues[sessionID]`'s generation and drops mismatches. Do not reuse `MembershipCoordinator.membershipVersionBySession` (a join version).
- **Router frames through the writer** (B1): add `TransportAdapter.enqueueOutbound(_:to:)`; `LandRouter` sends the join response and post-join errors through it. Pre-join handshake errors stay direct (no adapter frames exist for that session yet).
- Route **every** adapter send through the writer; remove the `Task.yield()` calls that followed sends.
- **Target expansion** (S-b): the adapter resolves `.all` / `.player` / `.client` to this land's `.session(id)` targets from its own membership before enqueueing; the writer only ever carries `.session`. `WebSocketTransport.playerSessions` is transport-wide, so `.player` reaches the same player's sessions in other lands.
- **Writer bound** (S3): count queued bytes and elements at enqueue, decrement in the consumer; over a per-land limit (env via `EnvHelpers` + `*EnvKeys`) log and count it, and, with PR 3, disconnect the slowest sessions. PR 1 ships the counter and a hard ceiling with a logged error; PR 3 adds the per-session policy.
- Stop using `TransportSendQueue`: the adapter ignores the init parameter (deprecated, kept for source compatibility); `LandManager` stops wiring it; `WebSocketTransport` no longer starts the polling drain task; `transportSendQueue` returns nil and is deprecated.
- **Teardown** (S5): on land destroy, stop cycles → finish the continuation → drain with a bounded wait → log the number of frames left or enqueued after finish.
- Profiling: the send-latency sample moves to the consumer (enqueue → `sendBatch` returned). It changes meaning and is not comparable before/after; say so next to the benchmark table.
- Delete dead code: `sendEncodedUpdate`, `syncState`, `sendEventBody`.
- PR 1 only changes send routing; the #76/#77 bookkeeping stays until PR 2.

### PR 2 — sync cycle as plan + commit

With PR 1, the cycle body has no send awaits left. Make that structural:

- `planSyncCycle(state:) throws -> SyncPlan` — synchronous: extraction, diffs **on the real engine, in place** (no engine copy, B2), encoding of every frame in contract order, consumed event counts, and the pending values of the other mutations (finding 5).
- **Throw after diffing** (B2 option a, mechanism per B2'): the in-place diff has already advanced the caches, so dropping them (a nil cache seeds and returns `[]`, `SyncEngine.swift` ~609–614) or diffing with `.all` next time would send nothing. Instead:
  - broadcast: set a flag so the next broadcast diff uses `baseline: .empty` (~595–606: full sets plus deletes of vanished top-level keys, replacement semantics);
  - per-player: reset the affected players' first-sync flag (removal at ~997), so the next cycle sends them a full snapshot. Verify that the SDK applies a second firstSync mid-session as a replace; if not, use a per-player `.empty`-baseline diff instead.
  Throws are rare; no per-cycle copy.
- `commit(_ plan:)` — synchronous, same actor turn: `pendingEventManager.removeConsumed(...)`, the finding-5 mutations (dirty-tracking auto-switch and EMA, `lastUpdateSize`, counters, metrics), `writer.enqueue(plan.frames)`. A failed plan enqueues nothing, removes nothing and leaves those values unchanged. Membership and `initialSyncingPlayers` are read during the plan; with no await between plan and commit the reads stay consistent.
- Apply the same shape to the broadcast-only cycle, to `syncStateForNewPlayer` (firstSync: `lateJoinSnapshot` on the real engine, enqueued through the writer), and to #83's `debugSettle` (still captures its copy in the same turn as `beginSync`).
- Remove finding 6's bookkeeping: served-session offsets, the flush loop, per-reader mark rules. Marks become "counts read at plan time". Keep the #82 follow-up decision after `endSync`.
- Keep the #69 behaviour (initial-syncing players skipped) unchanged; #69 is separate. A large room's synchronous plan holds its adapter for extraction + diff + encode in one turn (largely true already); watch action RTT p95.

### PR 3 — bounded per-session queue (closes #61)

- In `SessionSendQueue`, count pending frames and bytes (incremented on yield, decremented after `connection.send`), guarded by NSLock (macOS 14 + Linux).
- Over a limit (env-configurable, defaults from measured peaks), close the session with a logged reason and count it as a server-initiated disconnect, separate from network disconnects. Tie in the writer-level counter from PR 1.
- Also handle the empty-land queue growth noted on #61. Land PR 3 right after PR 1 if PR 2 slips.

## Tests (written first per PR)

PR 1:
- From the #60 branch: back-to-back `syncNow` / `syncBroadcastOnly` × 3 sessions × three encodings with strictly increasing markers per session; last-seen marker per field equals server state; frames per session per iteration; merged frame → targeted event → per-player frame. Must fail on 4edfab2 for json and opcodeJsonArray.
- Join order: join response < firstSync < first diff, per session, through `LandRouter`.
- Mixed paths: an action response, an immediate event (json) and state frames interleaved; per-session order equals issue order.
- Cycle does not wait for the transport: with a `sendBatch` that never returns, `syncNow` returns and `endSync` runs; frames arrive in order once released; the writer counter reflects the backlog and the ceiling triggers.
- Reconnect with the same `SessionID` while frames for the old generation are queued: none reach the new connection.
- `.all` events reach only this land's sessions with two lands on one transport.
- Teardown drains queued frames; no polling task exists after `WebSocketTransport.init`; the consumer does not keep the adapter alive.
- Benchmark gate (release): cycles per second and transport-actor hop rate at 700 rooms vs 4edfab2.

PR 2:
- Encode failure inside the plan: nothing enqueued, queue unchanged, finding-5 values unchanged, and the next cycle delivers the full change (caches invalidated). Fails on main.
- An event queued from another task during the `beginSync` hop is in this cycle; one queued during the `endSync` hop is delivered by the follow-up (tickless) or the next tick.
- firstSync and `debugSettle` through plan + commit; #83 tests pass.
- Release benchmark row: cycle time with a large broadcast cache (no regression vs PR 1).
- All #74, #76, #77, #82 tests pass, except helpers that counted "the batch" (adjust as on the #60 branch).

PR 3: a session whose connection send never completes is closed after the limit, others unaffected; the counter is decremented on success and on close; env parsing.

All PRs: `SyncStrategyEquivalenceTests`; `assertConverged` once #79 PR 2 lands (the PR that lands after it switches the step to gating, 20 consecutive passes per encoding).

## Verification

Core rules for each PR: full `swift test`, `swift build -c release`, both E2E scripts (all encodings).

Benchmark comparison, release builds, same quiet machine, same scenarios and room counts (up to 700 rooms in ws-loadtest):
- V1 = 4edfab2 (current main), V1+PR1, V2 = after PR 2 (PR 3 measured with its limit off and on).
- Metrics: syncs per second, bytes per sync (expected unchanged), RTT p95, update p95, action RTT p95, disconnect rate (server-initiated separately), CPU, plus per-land skipped syncs and `beginSync`→`endSync` duration from the measurement-only patch (not committed).
- Stop and report if any metric regresses materially. Fallback for transport-actor saturation: one shared MPSC `AsyncStream` per transport with a single dispatching consumer (per-adapter order is preserved because each adapter yields from its own serial actor).

## Execution and review units

PR 1 → PR 2 → PR 3 (PR 3 may follow PR 1 directly). Normal PR review for each (core → dual track).

## Separate issue

Finding 7, confirmed statically: immediate `.all` events (json / opcodeJsonArray) go to `.broadcast`, which reaches every session on the shared transport (every land, including sessions still in handshake); `.player` targets resolve through the transport-wide `playerSessions`, so a player connected to two lands gets the other land's player-targeted frames in every encoding. Open an issue (`priority: before-rerun`) and fix it in PR 1 (target expansion), with a two-land test covering `.all` and `.player` with a player ID shared by both lands.

## Out of scope

- Running sync inside the tick on the keeper (layer 3): removes the `beginSync`/`endSync` hops; separate design issue. Possible Swift route: the adapter shares the keeper's serial executor (`unownedExecutor`) and uses `assumeIsolated`.
- #69 join window (order becomes deterministic with B1, the window stays); #73; #54.

## Prior notes checked

`2026-11-04-ordered-broadcast-send.md` (rev 3, superseded), `2026-11-04-pending-events-kept-across-cycles.md` (#77), `2026-11-04-sync-dirty-flags-and-merged-broadcast.md` (#68/#67/#70), `2026-11-04-e2e-state-convergence.md` (#79), comments on #60 and #61.

## Adversarial check record (revision 1 → 3)

All findings accepted with the reviewer's severity; no disagreements.

| Id | Severity | Disposition |
|---|---|---|
| B1 | blocking | Router join response and post-join errors go through `enqueueOutbound`; join-order test |
| B2 | blocking | No engine copy; diff in place, invalidate caches on a throw after diffing; large-cache benchmark row |
| S1 | should | Finding 5 mutations move into commit; firstSync and settle become plan + commit |
| S2 | should | One combined element per cycle; benchmark gate on PR 1; MPSC fallback |
| S3 | should | Writer-level counter and ceiling in PR 1, policy in PR 3 |
| S4 | should | Session generation stamps; reconnect test |
| S5 | should | Consumer captures transport + stream only; teardown order; `debugSettle` in PR 2 |
| N1 | nit | Yield removal kept; action RTT p95 watched |
| N2 | nit | `sendEventBody` deleted; no `.broadcast` targets; finding 7 as a separate issue |
| N3 | nit | PR 1 is routing only; latency sample meaning noted; PR 3 may follow PR 1 |
| B2' (rev 2 pass) | blocking | Invalidation replaced: `.empty` baseline for the next broadcast diff, first-sync reset per affected player |
| S-a (rev 2 pass) | should | Connection generation owned by the transport, stamped by the adapter, checked in `dispatchBatch` |
| S-b (rev 2 pass) | should | Finding 7 confirmed, `.player` leak added; adapter expands every target to `.session` |

# A closed output gate stops every reply, and the keeper sees a pending failure before its next phase (#696, #704)

Rev 1, 2026-11-21. Plan only: no code until Review's GO. Code pointers are at main a72b007c (no source change since 63f3db18, which has L2c: #718, #724). "TA" is `Sources/SwiftStateTreeTransport/TransportAdapter.swift`, "LK" is `Sources/SwiftStateTree/Runtime/LandKeeper.swift`.

## 1. Both still reproduce on main

**#696: replies are enqueued after the gate closed.** The two answer helpers check only the answer's ticket before they enqueue:
- `sendActionResponse` (TA:5604-5607);
- `handleActionError` (TA:5674-5677).

`enqueueOutbound` → `enqueueFrames` (`TransportAdapter+Outbound.swift:16-33`) doesn't read `outputGate` either. Event sends and the sync commit read the gate themselves (TA:2991, :3031, :4239), so they don't need this.

A reply can be enqueued in two windows:
- **After an adapter-side close, before the keeper applies the failure.** The answer helpers close the gate in their own segment (TA:5620, :5690), and `submitAnswerFailure` (TA:5628) then awaits the keeper. Meanwhile another action of the land can complete, and its answer goes out.
- **After the keeper's `failLand`, before the sessions close.** `failLand` closes the gate in the failing segment (`closeOutputs`, LK:5644) and starts the teardown task, whose `landDidFail` closes the sessions with 4016 later (LK:5645-5648, hold `.landFailedTeardown` at :5646). In that window, an action can still get an error reply: it was submitted after the failure, so `submitAction` throws, or it was pending, so its job is cancelled by `cancelAllActionJobs`.

**Other unchecked enqueues.** The same holds for every other frame through `enqueueOutbound`, all addressed to this land's sessions:
- the decode-error reply (TA:2492);
- the client-event error (TA:2697);
- `sendJoinError` (TA:5980) and `sendJoinResponse` (TA:6020);
- the router's JoinResponse and errors (`LandRouter.swift:1613`, :1737, :1741).

**#704: a sync phase runs between an answer's gate close and the failure.** The answer's segment closes the gate. The failure then reaches the keeper only through the awaited `submitLandFailure` (LK:5541), which queues it as a `.landFailure` input and kicks a server-input turn. Until a turn applies that input, the keeper doesn't know about the failure. Its in-turn sync phase (`runTurnOutputs` LK:4731, `runSyncOnlyTurn` LK:5162) calls `runSyncPhaseInTurnResult` (TA:2848), which plans and commits as usual. With the gate closed, only the commit's `enqueueFrames` is skipped (TA:4239). So, as the issue says:
- the phase flips a waiting join and resolves its waiter, while the closed gate drops its JoinResponse and first sync;
- a plan that throws reports its own `syncPlan` failure first, so the answer's `responseEncode` is dropped as a second cause;
- after `setTransport` to another adapter (LK:475), the phase runs through the new adapter, whose gate is open.

The joiner's first sync (TA:5267) closes the gate and then awaits `submitLandFailure` the same way, so it has the same window.

Both are reproduced by the tests in §3. Each is written first and fails on main.

## 2. Design

### 2.1 #696: the gate is read where every frame is enqueued

`enqueueFrames` drops every frame when `outputGate.isClosed`, and counts the drops (`framesDroppedLandFailed`, like `initialSyncsDroppedLandFailed`). It is synchronous, so the check is in the same segment as the enqueue: the rule CLAUDE.md asks for.
- One chokepoint covers both answer helpers, the error and join replies, and the router's frames, which today each need their own check. Any later send site is covered as well.
- The answer helpers keep their ticket check. A stale answer is still logged as stale (`droppedStaleActionAnswer`); one that the gate drops is logged as dropped because the land failed.
- **Not gated:** `sendFinalFrameAndClose` (`TransportAdapter+Outbound.swift:75`) and the 4016 closes (`closeSessionsForLandFailure`), which don't go through `enqueueFrames`. They carry the close, so they must still go out.
- The existing gate checks (TA:2991, :3031, :4239) stay. The one at :4239 also keeps the commit from starting inbound drains.

An alternative is to check the gate at the two answer helpers only, which is #696's literal scope. It leaves the join and error replies open, so the chokepoint is recommended (§5 Q1).

### 2.2 #704: the failure is noted to the keeper in the closing segment

The adapter can't change keeper state, and the keeper is another actor. So the failure is made visible the way `isDraining` already is: through a lock-protected, set-once box that any isolation can read without an await.
- **The keeper gets `pendingTransportFailure`.** It is a `LandOutputGate`-like box, first failure wins, with a `nonisolated` package method `notePendingFailure(_:)`.
- **Each adapter-side close notes it in the same segment.** Both answer helpers (TA:5620, :5690) and the first-sync failure (TA:5267) call `keeper.notePendingFailure(failure)` right after `outputGate.close(failure)`. The awaited `submitLandFailure` stays, so a land with no turn due still ends promptly. When that queued input arrives, `failLand` finds the land already failing and keeps the first cause.
- **The keeper reads it in one function, at the start of its output step.** `applyPendingTransportFailure()` runs before any sync phase: first in `runTurnOutputs`, and first in `runSyncOnlyTurn`. It calls `failLand` with the noted failure, which keeps its own position stage (`actionResponse` or `syncPhase`). The turn's phase is then skipped. The keeper state changes in a turn, as the reentrancy rule requires; the box only carries the news.
- **It covers all three cases.** No join flips and no plan runs after the note. The first cause is the answer's. A rebind doesn't escape, because the note sits on the keeper, not on either adapter.
- **What it can't close.** The remaining gap is the hop from the answer's await to its segment. A phase that runs in another actor turn before the answer's encode is a phase before the failure existed, which is correct.

An alternative is that `runSyncPhaseInTurnResult` reads its own gate and returns `.landFailed(outputGate.failure)`. It is simpler, but it misses the rebind, and it leaves the keeper's own work in that turn unaware of the failure. So the keeper-side note is recommended (§5 Q2).

### 2.3 Fit with L2d and #700

L2d-1 makes the freeze settle a sync-only turn, whose fence checks `failure == nil && !isDraining` before its phase (L2d delta §2 step 2). L2d-2 routes every live keeper through turns, and L2d-3 deletes the legacy flushOutputs path. #700 moves `runTickTurn`/`runInputTurn` onto `TurnCore`.
- **The note's read is one keeper function, the first act of the output step.** That is the same shape Main set for #716's preflight, which is apply's last act. So it survives L2d-2/3 unchanged, and #700 names it as the output step's first act with no core gap. After L2d-3 the legacy sites are gone, so this plan adds nothing to them. Until then a legacy (unattached) keeper has no adapter and gets no note.
- **L2d-1's settle.** Its fence gains `pendingTransportFailure == nil`, so a settle doesn't commit past a noted failure. Its `.skipped` mapping ("a closed gate gives `released`") stays right for a released freeze. A noted failure ends the land in the settle's turn instead, which matches L2d Q2's recommendation (end the land in the settle's turn). Whichever PR lands second adds that one fence term. This plan's PR can go before L2d-1: it touches `runTurnOutputs`/`runSyncOnlyTurn` with one call each, which L2d rebases over.
- **#716's preflight** (its rev 4 §3.1a) is apply's last act, and this read is the output step's first. Their order doesn't matter: both end the land before any output, and the first cause wins.

### 2.4 One PR for both

Yes. Both are the answer-failure path:
- #696 is the frames that leak after the close;
- #704 is the keeper work that runs after it.

The tests share the `.answerFailureSubmit` hold (#701) and one fixture. The PR has two commits: the `enqueueFrames` gate (#696), then the keeper note (#704). Estimated size: Sources about +70 / −5, Tests about +300.

## 3. Tests (each fails on main first; holds, never timing)

Hold points:
- `TransportAdapterHoldPoint.answerFailureSubmit` (TA:30, #701), between an answer's close and its submit;
- the keeper's `.landFailedTeardown` (LK:5646), between `failLand` and `landDidFail`.

No new hold point is needed.

**#696:**
1. **Adapter-side window.** On a tickless land and on a tick land, under each compressed encoding, action A's response doesn't encode (the untyped-payload fixture, `UntypedEventPayloadTests`). A holds at `.answerFailureSubmit`. Action B then completes normally. B's reply never reaches the transport; `framesDroppedLandFailed` counts it. After the release, the land ends with A's `responseEncode` and the session closes with 4016. The same runs with B's error reply (B's `validate` throws).
2. **Keeper-side window.** A land fails (`failLandForTesting`) and holds at `.landFailedTeardown`. An action is sent in that window. No error reply reaches the transport, and the session still closes with 4016 after the release.
3. **Join and router frames.** Held at `.answerFailureSubmit`, a join request gets neither a JoinResponse nor a join error. The router path is covered by a router-level join of the same land.
4. **The close still goes out.** A session closed with `sendFinalFrameAndClose` after the gate closed still gets its final frame and close.

**#704:**

5. **Join flip.** A holds at `.answerFailureSubmit`, with a join waiting for its flip. A sync turn runs: a tick, or a requested sync-only turn on a tickless land. The join doesn't flip and its waiter isn't resolved as joined. The land ends with `responseEncode`.
6. **First cause.** The same hold, with the sync plan made to throw (`syncPlanFaultForTesting`). The land's failure is A's `responseEncode`, not `syncPlan`.
7. **Rebind.** During the hold, the keeper is moved with `setTransport` to a second adapter, and a sync turn runs. The second adapter's transport gets no state frame. The land ends with A's failure.
8. **The first-sync path** (TA:5267): a joiner whose first sync fails (`firstSyncPlanFaultForTesting`), with another sync turn run before its submit. No commit runs after the close.
9. **#701's pins stay.** They assert "the land hasn't failed yet" during the hold. With the note, that still holds while no keeper turn runs. The pins don't run one, and they gain an assert that the failure is noted.

**Mutants** (each restored afterwards; each must fail a test):
- the gate check in `enqueueFrames` removed;
- `notePendingFailure` removed from each of the three closers;
- `applyPendingTransportFailure` skipped in `runTurnOutputs`, and in `runSyncOnlyTurn`;
- the note box made last-wins.

## 4. Steps, verification, docs

- S1 (one PR, core): the two commits of §2.4, with tests first.
- Gate:
  - Mac: build, the touched suites (`UntypedEventPayloadTests`, `ActionErrorReplyEncodeTests`, `TransportAdapterJoinFlipTests` and the router join suites), and the mutants;
  - CI: the full `swift test` and E2E.
- A/B: none. One lock read per enqueue and one per output step. The same lock is read today in `isClosed` on every event send, and the box is read the same way.
- **Docs, en and zh-TW:**
  - `docs/core/failure-handling.md`: the gate rows say that a closed gate drops every reply and join frame, not only state and event frames, and that the keeper ends the land at its next output step after an answer that didn't encode.
  - The #701 rows (encode before the ticket check) are unchanged.
- **Solutions:** if a lesson comes out of it, add an entry: a gate checked at each send site leaks at the next site added, so check it where frames are enqueued.

## 5. Questions

- Q1: the gate at `enqueueFrames` (every frame, recommended), or at the two answer helpers only (#696's literal scope)?
- Q2: the keeper-side note (covers the rebind, recommended), or the phase reading its adapter's gate (smaller, misses the rebind)?
- Q3: should the noted failure also stop the turn's apply, or only its outputs? Recommended: only the outputs. The inputs were admitted before the note, the record keeps them, and the failure's position says where it was found. Stopping the apply would make the failing turn depend on when the answer encoded.

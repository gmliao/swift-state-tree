# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 6, plan only, for review.
- **Detail:** B0–B2 in full; B3–B6 as outlines. Each of B3–B6 gets its own plan PR before its code, reviewed against the B0–B2 code that exists by then. Each outline's "open" list carries what the reviews of rev 1–3 raised for that step.
- **Open decisions:** D4 (module layering) is open for the maintainer, and B0 waits for it. D1–D3 and D5 are proposals.

**Issue:** #546.

**Inputs:**
- the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`);
- the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10);
- the stateless extraction (#554).

**Prerequisite:** #555 step 2b (#654: the runner, its goldens and the gate) merged on `main`, with the #548 row as recorded at 20e15dae. The branch is cut after that merge; B3 depends on that row (§4).

**Base:** `main` at 25dbdbe8. Line pointers are `Sources/SwiftStateTreeTransport/TransportAdapter.swift` ("TA") there unless a file is named.

## 1. Goal and rule

`TransportAdapter` becomes one `TurnActor`. Its machine holds the adapter's state, and every change to that state is made in a synchronous step or a synchronous answer. Work that waits (the keeper, the transport, timers) leaves the step as an effect, and its result comes back as an input. The core decides whether a result is still wanted, by the key the request was filed under and that key's generation. Handlers hold no tickets (core rule 4).

This is Elm's `Cmd`/`Msg` shape. For timers the closer model is OTP's `erlang:start_timer/4` with `handle_info/2`: the timer's reference comes back in the message, as the scheduled instant does in the core's `timer(at:for:_:)` input.

The rewrite happens on one branch, `rewrite/546-adapter-turn-core`, and merges once (harness plan rev 10). The branch is compared with the goldens `main` recorded. Any difference fails the comparison, unless the branch lists it (`ExpectedDifferences.swift`) or retires the row (`RetiredRows.swift`, with a replacement test).

The router, the manager, the keeper and NIO aren't rewritten. Their hold points stay where they are.

## 2. The machine and its tools

### 2.1 What the machine stores, and what it reaches through its tools

A machine is `PlainData` (`TurnCore.init`, `TurnCore.swift:168`), so it can't store a reference. What the commit needs, besides machine state, is a set of tools:
- the encoders (`EncodingPipeline`, `SyncPlanning`, `SyncStreamCanonical`, after #554);
- `perPlayerTables` (`SyncTablePerPlayerDiff`, a `package final class`, `SyncTables.swift:1880`);
- the mutable broadcast tables (TA:4233);
- the `AtomicLayoutTable` (§2.2);
- the recorder (through the keeper's synchronous calls, §2.3);
- `outboundWriter` and `outputGate`.

**The route: `CommitTools`, passed in, never stored.**
- `CommitTools` is a struct of the tools' references.
- The actor builds it once, as a `let`.
- It travels in the value that runs the commit: the `.syncPhase` query (the core's `Query` has no constraints, `Machine.swift:18`), and the legacy commit query (§3.2).
- The machine's `planAndCommit(_:tools:)` uses it for the duration of that call and keeps nothing.
- **What the compiler checks, and what it doesn't.** `perform` is `@concurrent nonisolated`, so the compiler keeps it away from an actor-owned non-`Sendable` tool. Among the tools that is only `perPlayerTables`. The others are reachable from `perform`: `OutboundWriter` (`@unchecked Sendable`), `outputGate` (a `nonisolated let`) and `EncodingPipeline` (`Sendable`). For those the guard below is the check.

**The "changed only in turns" guard, scoped to the actor.** The borrow flag (`core.borrowStateForTesting < 0`, `TurnCore.swift:84`) is the adapter actor's state, so it is read only on the actor: the assertion sits in the actor-side wrappers through which the commit writes a tool (`perPlayerTables`, the broadcast tables, the writer's commit-side enqueue), never inside the tools themselves. A read of the flag from another executor would race, so no tool reads it. Legitimate writers outside an adapter step are listed and not asserted:
- the keeper's synchronous `closeOutputs`, which writes the output gate outside any adapter step (`TransportAdapter+LandKeeperTransport.swift:97–100`);
- the writer's own drain side (its socket task), which isn't a commit write.

The witness for `perform` is the compiler for `perPlayerTables`, and for the `Sendable` tools a review rule: no `perform` in B2 names the writer's enqueue, the gate or the pipeline. B2's mutant per wrapper (an actor-side write outside a step) must trap.

### 2.2 D4: how other modules' types are stored

`@PlainData` is in `SwiftStateTurns`, which `SwiftStateTreeTransport` doesn't depend on (`Package.swift:85–95`). The machine's state includes other modules' types:
- `SessionID`, `PlayerID`, `ClientID`;
- `StateSnapshot` and `SnapshotValue` (in `SyncEngine`);
- `MessagePackValue` (in `PendingEventManager`);
- `Data`.

The lint refuses a hand-written conformance, and `@PlainData` can't be attached to another module's type.

**Three values go outside the machine under every option:**
- the land's generic `State`, held by `DebugFreezeState<State>`: it stays on the actor until B5 moves the freeze, and then lives in a tool, the freeze's snapshot box;
- the public `joinResponse` closure (`performJoin` and `admitJoin` take `joinResponse: (@Sendable (PlayerID, Int32) -> Data?)?`, TA:2096, :2124), an arbitrary builder that tests use for custom bytes: it stays in actor-owned storage (`ExpectedAdmission`, as today) through B0–B2, because membership isn't machine state yet. B3's plan decides where it lives once membership moves; if B3 replaces the API, that is listed there as a breaking change;
- `SyncEngine`'s `atomicLayout: AtomicLayoutTable` (`SyncEngine.swift:92`): a graph of `final class` `Node`s (`AtomicLayoutTable.swift:33`), possibly cyclic, built once per state type and immutable afterwards. It is configuration, not state. It leaves the machine's stored `SyncEngine` part and travels as a `let` in `CommitTools`. Its builder cache (`Cache`, :120) is a process-wide, locked static, not engine state, and isn't touched;
- the encoders' and the writer's own state, which are tools (§2.1).

So under every option the machine stores `SyncEngine`'s value part, not the engine object. B0 splits the engine (`SyncEngine.swift:47–92`, :151, :304–345):
- **the value part:** the per-player snapshots, the broadcast cache, both retirement flags and the first-sync marks;
- **the layout tool:** the `AtomicLayoutTable`. Every adapter diff path takes the same `AtomicLayoutTable.forState` table from `CommitTools`.

`SyncEngine(for:)` stays for its other callers (replay, `SyncOutputVerifier.swift:250`), as the value part plus its own layout table.

**Lag's clock.** `SyncLagSession` stores `ContinuousClock.Instant` (`SyncLag.swift:105–116`: `committedAt`, `lastAckAt`, `resyncTimes`, `pendingSince`), which isn't `PlainData` under any option. It stores `TurnInstant` instead (already `PlainData`, `PlainData.swift:49`), and lag decisions read the core's clock (`Turn.now`), not `syncLagNow()`. So a stepped test clock now moves lag too. The tests that set `syncLagNowForTesting` move to the test `TurnClock` in B2, and the hook is deleted; each such test is listed in B2's PR.

**The options for the rest (the maintainer's choice; I don't propose one):**
- **(a)** `SwiftStateTree` and the MessagePack target depend on `SwiftStateTurns`, and annotate their value types. Transport then depends on Turns too. `Data: PlainData` is declared in `SwiftStateTurns` itself: the lint permits the protocol's own module, and Turns already imports Foundation, so no new target dependency. This gives the full compile-time check, and puts the turn core under the core DSL module.
- **(b)** The machine stores adapter-side mirror types: IDs as wrapped strings, snapshots and `MessagePackValue` as their encoded bytes, converted at the boundary. The layering is unchanged. The conversion runs on the sync path, so the A/B (§5) measures it.
- **(c)** Those fields stay outside the machine as tools, like `perPlayerTables`. They are reached through `CommitTools` or an actor-side `let`, and guarded as in §2.1. The machine holds only the adapter's own value types. The layering and the hot path are unchanged, and less state is checked at compile time.

### 2.3 The commit and its synchronous calls

There is one plan-and-commit routine, the machine's `planAndCommit(_ read: SyncRead, membership: MembershipView, tools: CommitTools) -> Commit`. It is synchronous.

- **The in-turn commit** runs inside the `.syncPhase` answer. The keeper's sync turn calls it synchronously (`TransportAdapter+LandKeeperTransport.swift:93`), then applies `.committed` and clears dirty flags at once (`LandKeeper.swift:4618`, :4638). So the commit can't be a later input.
- **The legacy commit** runs inside a query too, in B2 (§3.2).

**Synchronous calls the routine makes, allowed and kept there.** None of them calls the adapter back. Each stays in the routine, so its order relative to the commit is today's:
- `keeper.assumeIsolated { $0.recordsSyncStream }` (TA:3844);
- `submitSyncStream(drafts)` (:3882) and the single-draft `submitSyncStream` (:4009). The draft split stays as it is: in-turn, the drafts go back to the keeper in the phase's output; legacy, they are submitted;
- the writer's synchronous enqueue.

**Rule 1 (a query from inside a step traps)** is not at risk, because none of these calls the adapter back. The witness is a mutant that makes the recorder's submission call an adapter query. It must trap in `SyncStreamProducerTests` (`Tests/SwiftStateTreeTransportTests`), which drives the adapter's commit with the sync stream recorded. It runs with in-turn sync on, for both paths that submit: the in-turn draft path and the legacy settle path. The suite's off-mode fixture records nothing on purpose (`SyncStreamProducerTests.swift:284–292`), so it isn't the witness.

## 3. B0–B2 in full

**Each step's gate, run at its SHA (CI parity):**
- the harness: every golden cell compared, green or listed;
- `swift test` with in-turn sync on and off, and with `USE_SYNC_TABLES=false` together with `TYPED_LEAF_VALUES=false` (the tables-off job's environment);
- the wall-clock cadence suite as CI runs it (`WALL_CLOCK_TESTS=1`, `WallClockCadenceSmokeTests`, no parallel), with its "did run" check, in each mode;
- E2E in six cells: `TRANSPORT_ENCODING` `json`, `jsonOpcode` and `messagepack`, each with `IN_TURN_SYNC` on and off;
- the wall-clock baseline lowered for the files the step touched;
- `scripts/pre-push-checks.sh origin/main`.

### 3.1 B0: representations (waits for D4)

- **Goal:** carry out D4, and make every piece of state B2 moves representable in a `PlainData` machine. No behaviour change.
- **Changes:**
  - per D4, the conformances (a), the mirror types (b), or the tool boxes (c);
  - `MembershipCoordinator` (a `final class`, `MembershipCoordinator.swift:22`) becomes a value type, still owned by the actor;
  - `SyncEngine` splits into its value part and the layout tool, with `SyncEngine(for:)` kept (§2.2).
  - `SyncLagSession`'s instants become `TurnInstant` (§2.2); the lag clock change itself lands in B2, with the core.
  - `ExpectedAdmission` and its `joinResponse` closure don't change (§2.2).
- **Owner:** the actor, of everything.
- **Gate:** §3's gate. The goldens must pass unchanged.

### 3.2 B1 and B2

**B1: the empty machine.**
- `TurnCore` in the adapter, the `SwiftStateTurns` dependency, and the production `TurnClock` over `safeTaskSleep` (core plan §3.4).
- The machine has no state yet. No behaviour change.
- Gate: §3's gate.

**B2: sync, lag and the freeze settle move to the machine.** The machine owns, from B2 on:
- the sync state: `syncSkips`, the backlog flags, `lastSyncSeq`, `planSyncSeq`, `syncEngine`, `pendingEventManager`, `carriedDirtyFields`, the sync-stream sets and `syncPhaseCommits` (the commit epoch);
- the lag state: `syncLag`, `syncLagFullPlanRequested`, and the lag timer on `.lagTimer`;
- the freeze settle's commit and its gating of ordinary cycles. The freeze's control (`debugFreeze`, `debugRelease`) and its auto-resume stay on the actor until B5.

The actor keeps membership, join, inbound, actions and land failure.

**Keys in B2:**
- `.syncCycle` for the cycle;
- `.lagTimer` for the lag timer;
- `.followUp(n)` for each failed plan's follow-up: today each runs its own task, and rule 18 allows one timer per key, so they don't coalesce;
- `.freeze` for the settle.

**The in-turn commit.** When the keeper's turn calls `runSyncPhaseInTurn`, the adapter builds a `MembershipView` in the same synchronous segment, and calls `core.query(.syncPhase(read, view, tools))`. The view holds the members, the joining sessions that this phase may flip, the held events, and each session's lag entry. The answer runs `planAndCommit`.

**The legacy cycle stays an actor-driven loop in B2, with its commit as a query.** The legacy driver awaits `keeper.beginSync`. In the segment where that await returns, it builds the `MembershipView` and calls `core.query(.legacyCommit(read, view, tools))`. It then awaits `keeper.endSync`. So the membership view is captured at the cycle's ingress, after the keeper's read, in the same segment as the commit, as today.

**What holds `.syncCycle`.** A flag in the machine holds no core key, and an input queued behind an unheld key is releasable at once (`Turn.swift:158–166`). So the cycle is a request:
- A cycle starts as a step (`.cycleStart`), which files a `.legacyCycle(id)` request under `.syncCycle` with `Hold.untilWorkerReturns`. `id` is a cycle number the machine counts. `untilRequestCloses` would release the key on the request's deadline, on cancellation or when the key ends (`Values.swift:62–74`), while `beginSync`/`endSync` still run; `untilWorkerReturns` keeps it until `perform` returns.
- Its `perform` awaits the actor's driver, `adapter.runLegacyCycle(id)`: `beginSync`, then the `.legacyCommit(id, …)` query in the same segment as the await's return, then `endSync`. It returns the cycle's outcome: `.committed`, `.stale`, `.busy` or `.notStarted` (a failed `beginSync`, or no read).
- **The ID is checked at both ends.** `.legacyCommit` commits only if `id` is the machine's current cycle; otherwise it returns `.stale` and commits nothing. `.legacyCycleEnded(id, outcome)` acts only on the current cycle. Either way, an accepted `beginSync` gets exactly one `endSync`, called by the driver after the query whatever it answered; a failed `beginSync` gets none.
- **`syncNow` keeps today's boundary:** it returns after `endSync`. The driver resumes `syncNow`'s waiter there, and the cycle's `perform` returns there too: the ordinary cycle doesn't wait for the writer.
- **The backlog retry** is queued behind `.syncCycle`, so it releases after the cycle's worker returns. Its own `perform` keeps today's waits before it sends `syncRequested`: after a busy rejection, 1 ms for the other cycle to reach `endSync`, and always `writer.waitForSyncCycleDrain()`, even when the key was already free.
- The freeze settle's cycle uses the same request and hold, under the same key.

In B3 the driver becomes a request chain (§4).

The legacy flag:
- only a successful `beginSync` owns the keeper's sync flag, and `endSync` runs exactly once after it;
- a `beginSync` that fails or returns no read runs no `endSync`.

**The legacy initial sync** commits through the same pipeline (TA:5536–5595). In B2 it calls `core.query(.initialSyncCommit(read, epoch, view, tools))` synchronously. That query runs `planAndCommit` for the one player and checks the carried epoch against the machine's commit epoch. It keeps today's three behaviours:
- the post-read checks: the session's ticket is still current and the player is still the session's player; the actor checks these before the query, in the same segment, as today;
- the output-gate check, inside the answer;
- on an epoch mismatch, the tickless follow-up (TA:5548): the answer emits `.initialSyncFollowUp(session)`, and `flush` schedules it as today.

Its holds (`initialSync`, `initialSyncAfterRead`) stay on the actor's path, at today's points. The epoch is captured after the first hold with `core.read`, as today.

**Bridges: what the commit decides that the actor still owns. They are outputs.** A value returned by the query would be applied too late: called outside a batch, `TurnActor.query` runs the segment before it returns (`TurnActor.swift:77–83`), so steps queued behind the commit (`.lagTick`, the retry, `.closeSession`'s request) would run before the actor saw it. So the answer emits each decision as an output (`Turn.emit`). The segment loop flushes outputs at the top of every iteration, before it admits a queued input or releases a parked one (`drainProducts` in `runSegment`, `TurnActor.swift:246`, :287–296). So the actor's `flush` applies them, in emission order, before any other step runs. The outputs:
- **`.flipped(session, attempt)`:** the actor marks the join flipped and resumes its waiter. The flip's frame was enqueued on the writer inside the answer, before the output, so `flush` starts the session's inbound drain (`inboundAfterFlip`) after the flip element is in the writer, as today (TA:3729). The drain keeps its output-gate check and the writer-ceiling cleanup (`TransportAdapter+Outbound.swift:28–62`);
- **`.heldEvents(session, frames)` and `.heldEventsDelivered(session)`:** the actor updates its held-event store;
- **`.heldEventsOverflowed(session, generation)`:** the actor runs today's failure path (the close and the join's failure);
- **`.lagClose(session, generation, code)`:** `flush` fences the session and then starts the transport close, in that order, as `endAndCloseSession` does today: inbound closed, outbound ended, then the close with the captured generation. In B2 the machine files no close request, so no effect can launch before the fence; the `syncLagClose`/`syncLagClosed` holds stay on the actor's close path, where they are today. Inside the answer the commit's own frame filtering already skips the session: the machine set its lag phase to `.closing` before it filtered frames (TA:4249, :4298 order);
- **`.fullPlanRequested`:** recorded as today.

The lag decisions are made inside `planAndCommit` against the `MembershipView` plus this commit's flips, so a session flipped by this commit is seen as a member.

**Which keys, in B2.** The machine owns no `.session` keys in B2: membership is the actor's. Every output is emitted for `.land`, which the machine starts at B1 and which stays live until B5's `endAll`. The machine's own keys in B2 are `.land`, `.syncCycle`, `.lagTimer`, `.followUp(n)` and `.freeze`, each started and ended by the machine. Session keys arrive with B3.

**Which actor fields a step reads.** No machine step reads an actor field: the steps see only machine state, the view a query carries, and their inputs. That is what makes `flush` the only place the actor's fields change in response to a commit.

**Bridges the other way: actor writes to state B2 moved.** Each is a named synchronous query at today's call site, in the same segment as today's write. A query outside a step doesn't trap.
- **`.sessionEnded(session)`:** the disconnect discards the session's lag entry at once (TA:1290).
- **`.ticketRenewed(session)`:** the ticket renewal on a rebind *discards* the lag entry (`syncLag.removeValue`, TA:1541); it doesn't move it.
- **`.playerCleared(player, outsideTurn:)`:** clears the per-player sync caches (`syncEngine`'s value part, `perPlayerTables`, the recorder's clear). Two call sites, both outside adapter steps in B2:
  - **disconnect**, after `keeper.leave` returns and behind the last-session recheck (TA:1332), with `outsideTurn: true`;
  - **supersede**, inside the keeper's synchronous admission callback, which also discards each old session's lag entry first (`.sessionEnded`), with `outsideTurn: false` (TA:1884–1907).
- **`.teardown`:** the recoverable teardown's `syncLag.removeAll()` (TA:1577). The #548 row exercises it.
- **`.ack(session, seq)`:** `onSyncAck` updates the lag entry (TA:3381–3396).
- **Merged events.** The append carries what `queueForMergedSend` uses today: the membership stamp, the canonical digest, and its queued / no-recipient result (`PendingEventManager.swift:67–81`, TA:2748–2755, :2826–2848). It is called from the keeper's turn (`enqueueEventSynchronously`), so it has two routes through one machine method, `appendMergedEvent(stamp, digest, body, target) -> QueueResult`:
  - outside an answer, the `.mergedEvent(…)` query;
  - inside the `.syncPhase` answer, the answer calls the method directly, since a query there would trap. The actor-side wrapper picks the route by the borrow flag (read on the actor). B2 has a test that reaches each route.

`initialSyncingPlayers` stays actor-owned through B2: it has four writers (reservation and installation, TA:1662; the ticket-checked removal, :1664; the disconnect clear, :1339; supersede, :1907), and none of them is in the commit.

Each query's writes are machine state; its answer returns what the actor needs back.

**Retry, follow-up and lag timer:**
- the backlog retry is an input queued behind `.syncCycle`, not a task with a 1 ms sleep;
- a failed plan's follow-up is a timer on `.followUp(n)`. Its step files `.followUpSync`, whose `perform` holds `failedPlanFollowUp` and then sends `syncRequested`;
- `.lagTick` is a timer on `.lagTimer` with skip-ahead (rule 18). Its step needs the current bindings, which the actor owns in B2, and no commit query is running. So the step only emits `.lagViewNeeded`. The actor's `flush` (between steps, inside the batch; a query there is allowed, `TurnActor.swift:71–76`) builds a fresh binding view and calls `core.query(.lagTick(view))`, whose answer decides the closes and the sync. The closes are `.lagClose` outputs, applied by the same `flush` pass's later iterations, fence first, as above; the sync is a `.lagSync` request, whose `perform` holds `syncLagTimerSync` before it sends `syncRequested`. The lag timer's apply milestone (the observation tests wait on) is written after the lag query has returned and its closes' fences are applied.

**`syncNow` and `waitForBackgroundSyncsForTesting`:**
- `syncNow` returns where it does today, after `endSync`: legacy after the `.legacyCycleEnded` query, in-turn when the keeper's sync turn has returned;
- `waitForBackgroundSyncsForTesting` counts background work from the moment it is scheduled: a retry scheduled but not yet queued, a follow-up timer armed, a `.followUpSync` or `.lagSync` request open, and the sync each spawns, until that sync has completed and the writer has taken its handoff. It returns when the count is zero, and then rechecks once (a completion can schedule more).

**The holds B2 touches.** Each stays at its semantic point:
- `cycleBeforeEndSync` stays before the legacy driver's `endSync` and before the settle's;
- `failedPlanFollowUp` and `syncLagTimerSync` move into `perform`, as above;
- `syncLagClose` and `syncLagClosed` sit in `.closeSession`'s `perform`, before and after the transport call;
- `initialSync` and `initialSyncAfterRead` stay on the actor's path.

Their users and the harness rows are listed in §6 (Appendix A).

**The tests' waits in B2.** A test that waited on a wall-clock poll for a sync effect waits for the commit's `Commit` value (an observation the answer writes) or for `syncNow`. A timer test steps the test clock, then waits for the timer step's apply milestone, an observation that step writes. The lag files' wall-clock entries leave the baseline in B2.

**Gate:** §3's gate, plus the host A/B at B2's SHA (§5).

## 4. B3–B6: outlines

Each step below gets its own plan PR before its code.

### B3: membership, join, inbound and the initial sync

- **Goal:** one land-wide membership domain, held across each operation's whole chain:
  - join: keeper join → entry read → transport registration → join-sync request;
  - register: entry read → transport registration;
  - leave: keeper leave → its tail.

  The hold passes between links through each completion step (`TurnActor.swift:170–176`; Review confirmed both the normal and the stale form). Queued membership inputs are scoped to a `.membershipEpoch(n)` that the recoverable teardown ends. The flip moves into the commit. B2's flip and held-event bridges and the legacy driver's queries go away. The public changes land here: the required `WithdrawToken`, the `Transport` defaults that ignore the connection generation (#240), `JoinAdmission.refused`, and the D2 stamp.
- **Owner after B3:** the machine, of membership, join, inbound and the initial sync.
- **Gate:** §3's gate.
- **Open before this step's plan:**
  - **Overflow: no core change (Review's answer).** `TurnActor.send` returns `Void` (`TurnActor.swift:26`), so a fallback on `queueFull` can't work. Instead every disconnect goes through a control step (a control input is never refused, `Values.swift:58`), which queues the leave behind `.membership` with `Turn.queue(_:behind:)`. That ignores the queue limit, scopes and tokens, and returns `false` only after `endAll` (`Turn.swift:148–166`). The queueing step doesn't touch the binding; the leave does, when it reaches its place in the FIFO. Pinned inputs count as queued, so they are bounded by a dedup per binding. Define who owns the terminal cleanup.
  - **Scopes and withdrawal** (rev 3 §2.1): the recoverable teardown withdraws the queued membership inputs of its epoch; the host registration carries its own token.
  - **Bounded refusal:** a register or a join refused on `queueFull` is answered and closed, as today.
  - **Cleanup for every link.** For `.readEntrySession`, `.registerWithTransport` and `.requestJoinSync`, define the key, where the router is answered, and the cleanup on a deadline, on a key's end, and on a `request` that returns `nil`. Define the behaviour after `endAll`. Keep today's branches: the join's registration skips the public registration's keeper check (TA:2240–2276), and join sync is requested only for a join that completes in-turn.
  - **#548.** The adapter passes `admitThroughTransport: true` in both modes (TA:2208). The legacy behaviour comes from `refusesResolvedJoin` returning `false` when in-turn sync is off (`TransportAdapter+LandKeeperTransport.swift:38–44`).
    - The fix compensates with a keeper leave, targeted by the ended attempt's session and client (`leave(playerID:clientID:sessionID:)`, `LandKeeper.swift:2451`). Name the result field that tells the late step the keeper inserted a player, including the resolver-error path after the insert (`JoinOutcome` at :1797, :1880).
    - **No keeper recheck in this rewrite.** A recheck before the duplicate-login kick and after its leave is a keeper behaviour change, and it changes the in-turn lifecycle. It belongs with #588/#593's keeper change, which moves `CanJoin` into the apply turn.
    - The harness row is ready for this: since #654 at 20e15dae, it records A's ticket as a note and `join-A` as `recorded(#548)`. The branch's refusal is then comparator differences, not a run failure. The comparator matches one entry per exact difference per cell, so the list has one entry per channel and checkpoint: the note at the live checkpoint, and the changed frames of connection `a` at each checkpoint where they differ. The exact set comes from the branch's run at B3, each entry naming #548. The lifecycle stays `pa = [join, leave, join, leave]`, because the compensating leave runs OnLeave.
    - B0–B2 depend on neither the recheck nor the compensation.
  - **Reverse bridges from B3 to the actor.** The freeze reads the coordinator's epoch (TA:6428, :6500) until B5. The disconnect cancels the actor-owned action work until B4. A binding read covers whether a reply is still eligible, not the cancellation.
  - **Flip timeout.** It goes through the membership queue today (TA:1731–1735). Its queued input survives an epoch withdrawal, so its handler checks the attempt, the binding and the still-unflipped record.
  - **The D2 stamp.** It also covers:
    - the router's undo after admit, and its cleanup when a flip fails (`LandRouter.swift:1101`, :1422);
    - the stop and shutdown leaves;
    - `registerSession`, where the transport compares the expected generation before it changes its player map.
  - **`membershipInputsWaiting`.** Counted adapter-side, at park and at withdraw. The core's aggregate counters don't count withdrawn callers.
  - **Handover witnesses.** Tests for both completion forms, normal and stale, each with a parked successor.
  - **Inbound's two milestones** (rev 3 §2.3), and the `membershipQueued` seam, which only fires when an input parks.
  - **#652 (D2) and #240.** D2's reused-SessionID stale-reply row is re-recorded on `main` before the branch compares it, with its race mutant (the early ticket guard and the send's `ifCurrent` removed) shown red.
  - **The causal quiescence barrier:** a worker's retirement counts as quiet only after the writer has taken its handoff. Each wait pattern gets its mutant run.
  - **The `joinResponse` builder's lifetime:** scoped to the attempt (stored per `SessionID`, consumed at admission, removed on exit, TA:2154–2212); B3 keeps that scope when membership moves.
  - **The barrier's coverage:** an abandoned worker and a timer wake each count until handed off.
  - **The tools after B2's queries go away:** how B3's completion steps reach `CommitTools` and the leave tail's tools (the recorder's clear, `perPlayerTables`), once the actor no longer calls the commit queries.

### B4: actions

- **Goal:** the action-response tasks become `.awaitActionResult` requests under `.session`. D5 decides whether the response becomes an output of the applying turn.
- **Owner after B4:** the machine, of the action state.
- **Gate:** §3's gate.
- **Open:** D5 (#658). The `actionResponse` hold stays in `perform`, after the answer. B3's action-cancellation bridge goes away.

### B5: land failure, the terminal teardown, the freeze's control

- **Goal:**
  - `landFailed` becomes a control input;
  - `.landDestroyed` becomes `endAll`;
  - the freeze's control and its auto-resume move to the machine.
- **Owner after B5:** the machine, of everything.
- **Gate:** §3's gate.
- **Open:**
  - the freeze's `State` box (§2.2);
  - the `debugFreezeAutoResumeStale` retirement. Its replacement test gates the old wake, re-arms, sees `.staleTimer`, then resumes the new timer and waits for `autoResumesApplied`, which is written after the keeper has resumed. It covers 1 test with 2 references; Main approves it after the plan is GO;
  - `.disconnectOverflow` after `endAll`;
  - the freeze witness: the fresh-key mutant (the settle filed under a new key each time) must go red.

### B6: deletion

- **Goal:** delete what's left: the `…Queued` wrappers, unused helpers, and the adapter's last uses of `GenerationTable`, `SingleFlight` and `Lifecycle`.
- **Gate:** §3's gate, and the final host A/B (§5).
- **Stop triggers for #546** (any one stops the rewrite for the maintainer's call): the machine's API takes a coordinator's shape (the actor forwarding most inputs unchanged); the scaffolding (bridges, queries, test hooks) grows as large as the machine; a step's A/B regresses and the cause isn't found in that step.
- **Completion criteria for #546:** every adapter state field is machine state or a listed tool; no `GenerationTable`, `SingleFlight` or `Lifecycle` use left in the adapter; the harness compares every golden cell green or listed, with each list entry naming its issue; the A/B passes; the wall-clock baseline has no adapter entry.

## 5. The performance A/B

The host runs it at B2's SHA (the sync path) and before the merge, on the instruction gate (#517).

**Builds:**
- base is `main` at run time; head is the branch merged with that `main`;
- release builds, both sides in one container from the pinned image, with `swift --version` and the digest recorded;
- ABBA order, one warm-up pair discarded, then 5 pairs, with `SWIFT_DETERMINISTIC_HASHING=1`.

**Cells:**
- #554's five EncodingBenchmark cells (`rows-mp`, `rows-json`, `router-mp`, `rows-mp-100`, `json-control`), with `ENCODING_BENCHMARK_PERF_WINDOW=iteration`;
- plus `nonsync`.

**Judgement:**
- mean `instructions:u` per cell. A cell regresses if it is above base by more than max(0.5 %, 3 × base's spread). Time is reported, not judged;
- the per-message budget is about +100 instructions for the one `core.read`;
- ServerLoadTest's zero-disconnect bar is reported for both sides;
- encoded bytes and the patch and event counts must equal base's.

## 6. Appendix A: hold points

The table from rev 3 §3.1 stands for the holds B2 doesn't touch. Those are reviewed again with each later step's plan. The holds B2 touches are listed in §3.2. Users are counted with helpers included, per Review:
- `cycleBeforeEndSync`: about 20 (InTurnSync 2, and `TransportTestHelpers`' helper in 18 tests);
- `failedPlanFollowUp`: 7 PerPlayerSyncTablesScenario tests through one install, InitialSyncBehindCommit 1, SyncOutputVerifier 1;
- `syncLagTimerSync`: SyncLag 1;
- `syncLagClose`: 6;
- `syncLagClosed`: 5;
- `initialSync`: JoiningAdmission 4, NewestWins 1;
- `initialSyncAfterRead`: InitialSyncBehindCommit 1, TicklessPassOrdinal 1, InitialSyncStaleRead 1.

The neighbours' holds (the router's 14, the manager's 6, the keeper's 15) don't move.

## 7. Decisions for the maintainer

- **D1.** Keep both sync modes on the branch (proposed). This lets every golden cell compare, and keeps the production rollback switch (`IN_TURN_SYNC=false`) working.
- **D2.** #652: allow a reused SessionID, with the binding stamp and generation-aware output in B3 (proposed), or forbid it.
- **D3.** #588: before the recording, or after the merge (proposed). With it goes the keeper's join recheck (§4, B3).
- **D4 (open; B0 waits for it).** Module layering, options (a), (b) and (c) in §2.2.
- **D5 (#658).** An action's response against its turn's diff: ordered by the turn's outputs, or explicitly unordered. Today the response task's window lets a sync go first, in every encoding.

## 8. Risks

- **The per-message `core.read`.** If it costs more than the budget on 6.2.4 (#621), the sync path regresses. The guards are `check-turns-inlinable.sh` and the A/B at B2.
- **The tools outside the machine.** `CommitTools` is passed in and not stored. Its writers are guarded by the borrow assertion, and `perform` can't reach them because it is nonisolated.
- **The B2 bridges.** Each bridge is applied in the commit's own segment. If a bridge is missing for a write the actor still makes, a test of that write fails at B2's SHA.

## 9. Rev 6: what changed

| Change | Where |
|---|---|
| `.syncCycle` held with `untilWorkerReturns`; the ID checked in `.legacyCommit` too; one `endSync` per accepted `beginSync`; `syncNow` after `endSync`; the retry's writer drain | §3.2 |
| `.lagClose` fenced before the close starts, with no close request in B2; B2's keys named (outputs for `.land`); the flip drain's gate check and ceiling cleanup | §3.2 |
| Reverse bridges against the code: rebind discards; supersede's and disconnect's call sites and `outsideTurn`; `initialSyncingPlayers` actor-owned; merged events' fields and two routes | §3.2 |
| B0: the value part listed in full, `SyncEngine(for:)` kept, `TurnInstant` and the core clock for lag, the guard scoped to the actor, the broadcast tables as a tool | §2.1, §2.2, B0 |
| Quiescence from scheduling to the writer's handoff; the lag milestone after its fences; the recorder witness with in-turn sync on; stop triggers, the barrier's coverage and the builder's lifetime in the outlines; `onSyncAck` pointer | §2.3, §3.2, §4 |

## 10. Rev 5: what changed

| Change | Where |
|---|---|
| The public `joinResponse` closure stays on the actor through B2 | §2.2, B0 |
| `AtomicLayoutTable` is a `CommitTools` tool under every option; `SyncEngine` splits | §2.2, B0 |
| The commit's bridge is outputs applied in `flush` before any later step; lag-close fencing; `.lagTick`'s binding view; the inbound drain after the flip | §3.2 |
| Reverse bridges as named queries: session end, player left (the `outsideTurn` split), teardown, ack, rebind, merged events; the initial sync's checks and follow-up | §3.2 |
| `.syncCycle` held by a request; the cycle ID; the retry's writer drain | §3.2 |
| The seven missing rev-3 points and the overflow answer in the open lists; B6's stop conditions | §4 |
| #654's merge as the prerequisite; #548 entries per exact difference; the compiler claim scoped; `Data: PlainData` in Turns | header, §2.1, §2.2, §4 |

## 11. Rev 4: what changed

| Change | Where |
|---|---|
| Split: B0–B2 in full, B3–B6 as outlines (Main) | §3, §4 |
| D4's shared gap: the route to the tools is `CommitTools` in the query; `Data`, `State` and the response closure placed | §2.1, §2.2 |
| MF4's B2 bridges: held-event writes, overflow failures, lag against the commit's flips, disconnect and supersede clears, the legacy initial-sync commit, where the legacy snapshot is taken | §3.2 |
| MF1–MF3 and MF4's B3 part, with the shoulds | §4, the open lists |
| #548 in the harness: the row now records its bug state (#654 at 20e15dae); no keeper recheck in the rewrite | §4, B3 |
| Gate parity: `TYPED_LEAF_VALUES=false` with tables off; the cadence suite's "did run" check per mode; E2E names as the server's `TRANSPORT_ENCODING` values | §3 |
| Recorder mutant: its fixture named; the draft split kept | §2.3 |
| D5 added (#658) | §7 |

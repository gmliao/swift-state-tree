# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 4, plan only, for review.
- **Detail:** B0–B2 in full; B3–B6 as outlines. Each of B3–B6 gets its own plan PR before its code, reviewed against the B0–B2 code that exists by then. Each outline's "open" list carries what the reviews of rev 1–3 raised for that step.
- **Open decisions:** D4 (module layering) is open for the maintainer, and B0 waits for it. D1–D3 and D5 are proposals.

**Issue:** #546.

**Inputs:**
- the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`);
- the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10);
- the stateless extraction (#554).

**Prerequisite:** #555 step 2b (#654: the runner, its goldens and the gate) merged on `main`.

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
- the recorder (through the keeper's synchronous calls, §2.3);
- `outboundWriter` and `outputGate`.

**The route: `CommitTools`, passed in, never stored.**
- `CommitTools` is a struct of the tools' references.
- The actor builds it once, as a `let`.
- It travels in the value that runs the commit: the `.syncPhase` query (the core's `Query` has no constraints, `Machine.swift:18`), and the legacy commit query (§3.2).
- The machine's `planAndCommit(_:tools:)` uses it for the duration of that call and keeps nothing.
- The tools are reached only from code on the adapter's executor. `perform` is `@concurrent nonisolated`, so the compiler refuses an actor-owned non-`Sendable` tool there.

**The "changed only in turns" guard.** Every writer of a tool's mutable state asserts, in debug builds, that it runs inside a step or an answer: `core.borrowStateForTesting < 0` (`TurnCore.swift:84`). That covers writes. Reads on the actor outside a step are synchronous code with no interleaving, so they need no guard.

### 2.2 D4: how other modules' types are stored

`@PlainData` is in `SwiftStateTurns`, which `SwiftStateTreeTransport` doesn't depend on (`Package.swift:85–95`). The machine's state includes other modules' types:
- `SessionID`, `PlayerID`, `ClientID`;
- `StateSnapshot` and `SnapshotValue` (in `SyncEngine`);
- `MessagePackValue` (in `PendingEventManager`);
- `Data`.

The lint refuses a hand-written conformance, and `@PlainData` can't be attached to another module's type.

**Three values go outside the machine under every option:**
- the land's generic `State`, held by `DebugFreezeState<State>`: it stays on the actor until B5 moves the freeze, and then lives in a tool, the freeze's snapshot box;
- the join response that `ExpectedAdmission` stores as a closure (the response builder): the machine stores the response's inputs (request ID, player, slot, encoding), which are plain, and `perform` or the commit builds the response from them;
- the encoders' and the writer's own state, which are tools (§2.1).

**The options for the rest (the maintainer's choice; I don't propose one):**
- **(a)** `SwiftStateTree` and the MessagePack target depend on `SwiftStateTurns`, and annotate their value types. Transport then depends on Turns too. `Data` needs a conformance in `SwiftStateTurns` itself (a core change: one line in its built-in list). This gives the full compile-time check, and puts the turn core under the core DSL module.
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

**Rule 1 (a query from inside a step traps)** is not at risk, because none of these calls the adapter back. The witness is a mutant that makes the recorder's submission call an adapter query. It must trap in `SyncStreamProducerTests` (`Tests/SwiftStateTreeTransportTests`), which drives the adapter's commit with the sync stream recorded. B2 checks that the suite reaches the call in both sync modes, and adds a case for the mode it doesn't reach.

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
  - `ExpectedAdmission` stores the response's inputs instead of the builder closure (§2.2).
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

The query also marks `.syncCycle` in flight. A second query, `.legacyCycleEnded`, clears it after `endSync` returns. In B3 the driver becomes a request chain (§4).

The legacy flag:
- only a successful `beginSync` owns the keeper's sync flag, and `endSync` runs exactly once after it;
- a `beginSync` that fails or returns no read runs no `endSync`.

**The legacy initial sync** commits through the same pipeline (TA:5536–5595). In B2 it calls `core.query(.initialSyncCommit(read, epoch, view, tools))` synchronously. That query runs `planAndCommit` for the one player and checks the carried epoch against the machine's commit epoch. Its holds (`initialSync`, `initialSyncAfterRead`) stay on the actor's path, at today's points. The epoch is captured after the first hold with `core.read`, as today.

**Bridges: what the commit decides that the actor still owns.** Each commit's answer returns a `Commit` value, and the actor applies it in the same synchronous segment, before anything else can run:
- **flips:** the joins this commit flipped. The actor marks them flipped and resumes their waiters;
- **held-event writes:** the events held for joining sessions, and the ones delivered with a flip. The actor updates its held-event store;
- **held-event overflow failures:** the sessions whose held events overflowed. The actor runs today's failure path for each (the close, and the join's failure);
- **lag decisions:** the closes and the full-plan requests. They are decided inside `planAndCommit` against the `MembershipView` plus this commit's flips, so a session flipped by this commit is seen as a member. The closes go out as `.closeSession` requests from the machine, under `.session` keys the machine starts from the view's bindings.

**Bridges the other way: actor writes to state B2 moved.** The actor's disconnect and supersede clear per-player sync caches (TA:1290–1295, :1332–1342). In B2, at those points, the actor calls `core.query(.clearPlayer(player, session))`. It is synchronous and outside any step, so no trap, and it runs in the same segment as today's clear.

**Retry, follow-up and lag timer:**
- the backlog retry is an input queued behind `.syncCycle`, not a task with a 1 ms sleep;
- a failed plan's follow-up is a timer on `.followUp(n)`. Its step files `.followUpSync`, whose `perform` holds `failedPlanFollowUp` and then sends `syncRequested`;
- `.lagTick` is a timer on `.lagTimer` with skip-ahead (rule 18). Its step decides the closes and the sync. The sync is a `.lagSync` request, whose `perform` holds `syncLagTimerSync` before it sends `syncRequested`.

**`syncNow` and `waitForBackgroundSyncsForTesting`:**
- `syncNow` returns where it does today, after `endSync`: legacy after the `.legacyCycleEnded` query, in-turn when the keeper's sync turn has returned;
- `waitForBackgroundSyncsForTesting` waits for the retry and the follow-ups: no input queued behind `.syncCycle`, and no `.followUpSync` or `.lagSync` request open.

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
  - **Overflow.** `TurnActor.send` returns `Void` (`TurnActor.swift:26`), so an entry can't see `queueFull`. The fallback leave goes into the same FIFO at its submission point (`Turn.queue(_:behind:)` from a step), with no early invalidation. Define its dedup per binding, and who owns its terminal cleanup.
  - **Cleanup for every link.** For `.readEntrySession`, `.registerWithTransport` and `.requestJoinSync`, define the key, where the router is answered, and the cleanup on a deadline, on a key's end, and on a `request` that returns `nil`. Define the behaviour after `endAll`. Keep today's branches: the join's registration skips the public registration's keeper check (TA:2240–2276), and join sync is requested only for a join that completes in-turn.
  - **#548.** The adapter passes `admitThroughTransport: true` in both modes (TA:2208). The legacy behaviour comes from `refusesResolvedJoin` returning `false` when in-turn sync is off (`TransportAdapter+LandKeeperTransport.swift:38–44`).
    - The fix compensates with a keeper leave, targeted by the ended attempt's session and client (`leave(playerID:clientID:sessionID:)`, `LandKeeper.swift:2451`). Name the result field that tells the late step the keeper inserted a player, including the resolver-error path after the insert (`JoinOutcome` at :1797, :1880).
    - **No keeper recheck in this rewrite.** A recheck before the duplicate-login kick and after its leave is a keeper behaviour change, and it changes the in-turn lifecycle. It belongs with #588/#593's keeper change, which moves `CanJoin` into the apply turn.
    - The harness row is ready for this: since #654 at 20e15dae, it records A's ticket as a note and `join-A` as `recorded(#548)`, so the branch's refusal is a comparator difference that one `ExpectedDifferences` entry per cell carries. The lifecycle stays `pa = [join, leave, join, leave]`, because the compensating leave runs OnLeave.
  - **Reverse bridges from B3 to the actor.** The freeze reads the coordinator's epoch (TA:6428, :6500) until B5. The disconnect cancels the actor-owned action work until B4. A binding read covers whether a reply is still eligible, not the cancellation.
  - **Flip timeout.** It goes through the membership queue today (TA:1731–1735). Its queued input survives an epoch withdrawal, so its handler checks the attempt, the binding and the still-unflipped record.
  - **The D2 stamp.** It also covers:
    - the router's undo after admit, and its cleanup when a flip fails (`LandRouter.swift:1101`, :1422);
    - the stop and shutdown leaves;
    - `registerSession`, where the transport compares the expected generation before it changes its player map.
  - **`membershipInputsWaiting`.** Counted adapter-side, at park and at withdraw. The core's aggregate counters don't count withdrawn callers.
  - **Handover witnesses.** Tests for both completion forms, normal and stale, each with a parked successor.
  - **Inbound's two milestones** (rev 3 §2.3), and the `membershipQueued` seam, which only fires when an input parks.
  - **#652 (D2) and #240.**

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
  - `.disconnectOverflow` after `endAll`.

### B6: deletion

- **Goal:** delete what's left: the `…Queued` wrappers, unused helpers, and the adapter's last uses of `GenerationTable`, `SingleFlight` and `Lifecycle`.
- **Gate:** §3's gate, and the final host A/B (§5).

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

## 9. Rev 4: what changed

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

# TransportAdapter on the turn core: the rewrite (#546)

**Status:** rev 9, plan only, for review.
- **Detail:** B0–B2 in full; B3–B6 as outlines. Each of B3–B6 gets its own plan PR before its code, reviewed against the B0–B2 code that exists by then. Each outline's "open" list carries what the reviews of rev 1–3 raised for that step.
- **Decided:** D4 = (a), by the maintainer (§2.2), with its rule documented as a B0 deliverable.
- **Decisions in this rev:** the legacy path's removal from live lands (D1, decided): L1 written in full, L2 (2a–2d) a placeholder until its own layout; replay keeps the legacy cycle until #612 (§3.2). The replay-only cycle in B2: (b), decided by consequence. Decision 5 (the phase's emit effects) with every output named.
- **Proposals:** D1–D3 and D5.
- **After GO on B0–B1:** B0–B1 move to a draft code branch; B2's detail is settled against that code.

**Issue:** #546.

**Inputs:**
- the turn core (#551, merged as #608; `Notes/plans/2026-11-18-swift-state-turns-core.md`);
- the differential harness (#555; `Notes/plans/2026-11-19-adapter-differential-harness.md`, rev 10);
- the stateless extraction (#554).

**Prerequisite:** #555 step 2b (#654: the runner, its goldens and the gate), merged on `main` as 6cf87133, with the #548 row as recorded at 20e15dae and ce9db968. The branch is cut after that merge; B3 depends on that row (§4).

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
- **What the compiler checks, and what it doesn't.** `perform` is `@concurrent nonisolated`, so the compiler keeps it away from an actor-owned non-`Sendable` tool. Only two tools are isolated that way: the two table tools, `perPlayerTables` and the broadcast table (`SyncTables.swift:1593`), as §3.4 says. The others are reachable from `perform`: `OutboundWriter` (`@unchecked Sendable`), `outputGate` (a `nonisolated let`) and `EncodingPipeline` (`Sendable`). For those the guard and the review rule below are the check.

**The "changed only in turns" guard, scoped to the actor.** The borrow flag (`core.borrowStateForTesting < 0`, `TurnCore.swift:84`) is the adapter actor's state, so it is read only on the actor: the assertion sits in the actor-side wrappers through which the commit writes a tool (`perPlayerTables`, the broadcast tables, the writer's commit-side enqueue), never inside the tools themselves. A read of the flag from another executor would race, so no tool reads it. Legitimate writers outside an adapter step are listed and not asserted:
- the keeper's synchronous `closeOutputs`, which writes the output gate outside any adapter step (`TransportAdapter+LandKeeperTransport.swift:97–100`);
- the writer's own drain side (its socket task), which isn't a commit write.

The witness for `perform` is the compiler for the two table tools, and for the `Sendable` tools a review rule: no `perform` in B2 names the writer's enqueue, the gate or the pipeline. B2's mutant per wrapper (an actor-side write outside a step) must trap; the in-turn borrow mutant goes inside the adapter's draft production (§3.4).

### 2.2 D4: how other modules' types are stored (decided: option (a))

`@PlainData` is in `SwiftStateTurns`, which `SwiftStateTreeTransport` doesn't depend on today (`Package.swift:85–95`). The machine's state includes other modules' types:
- `SessionID`, `PlayerID`, `ClientID`;
- `StateSnapshot` and `SnapshotValue` (in `SyncEngine`);
- `MessagePackValue`, `EventTarget` and `CanonicalSyncEvent` (stored by `PendingEventManager` beside the MessagePack body, `PendingEventManager.swift:13–25`);
- `Data`.

B0 lists every type the B2 state holds; the macro then refuses any field whose type isn't `PlainData`, so a type missing from this list fails B0's build rather than slipping through.

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

**The maintainer chose (a).** The options, kept for the record:
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

**Each step's gate, run at its SHA (CI parity).** Before L1 the sync mode is a CI axis (on and off); from L1 on there is one mode, and the harness's legacy cells (through the `package` parameter) are the off mode's only coverage until L2 removes them:
- the harness: every golden cell compared, green or listed;
- `swift test` in each sync mode CI runs, and with `USE_SYNC_TABLES=false` together with `TYPED_LEAF_VALUES=false` (the tables-off job's environment);
- the wall-clock cadence suite as CI runs it (`WALL_CLOCK_TESTS=1`, `WallClockCadenceSmokeTests`, no parallel), with its "did run" check, in each mode;
- E2E for each `TRANSPORT_ENCODING`, `json`, `jsonOpcode` and `messagepack`, in each sync mode CI runs;
- the wall-clock baseline lowered for the files the step touched;
- `scripts/pre-push-checks.sh origin/main`.

### 3.1 B0: representations (D4 = (a))

- **Goal:** carry out D4 (a), and make every piece of state B2 moves representable in a `PlainData` machine. No behaviour change.
- **Changes:**
  - the target edges: `SwiftStateTree` and the MessagePack target depend on `SwiftStateTurns`, and Transport does too, directly, in B0 (B0 already stores `TurnInstant`, so the edge can't wait for B1); so does `SwiftStateTreeTransportTests`. Turns uses `@concurrent`, so every consumer now needs Swift 6.2: `swift-tools-version` and the documented floor (README, FAQ, en and zh-TW) move from 6.0 to 6.2. `Package.swift` is a protected path of the differential gate (#654), so these package changes land on `main` first, in their own PR, and B0 takes them from `main`;
  - `@PlainData` at the definition of `SessionID`, `PlayerID`, `ClientID`, `StateSnapshot`, `SnapshotValue`, `MessagePackValue`, `EventTarget`, `CanonicalSyncEvent`, and each further type the build names; `Data: PlainData` in `SwiftStateTurns`;
  - `MembershipCoordinator` (a `final class`, `MembershipCoordinator.swift:22`) stays a class in B0. B2's machine doesn't hold it (membership is the actor's until B3), so its conversion to a value type moves to B3;
  - `SyncEngine` splits into its value part and the layout tool, with `SyncEngine(for:)` kept (§2.2).
  - `SyncLagSession`'s instants become `TurnInstant` (§2.2); the lag clock change itself lands in B2, with the core.
  - `ExpectedAdmission` and its `joinResponse` closure don't change (§2.2).
  - **the rule, documented** (the maintainer's condition for (a)): the turn core's docs already have a plain-data section on `main` (f515e11f, with #664's compiled before/after blocks); B0 updates it in English and zh-TW (`docs/turns/README.md` and `README.zh-TW.md`) rather than adding a new one, and adds a short note where contributors look: AGENTS.md's "Coding Style & Naming Conventions", in English (repository prose), linking to the docs section. It states:
    - a type held in a turn machine's state must be `@PlainData`, declared at the type's definition;
    - a hand-written conformance is refused by `scripts/lint-turns.sh`;
    - a standard-library or Foundation type that isn't plain (such as `ContinuousClock.Instant`) is replaced by a Turns value type (`TurnInstant`), not wrapped by hand.

    With a before/after example, compiled by a test as the turn docs' other blocks are (the docs use a `Room` with a class and a clock instant; the shape is the same):

    ```swift
    // Before: refused. The macro names `lastAckAt`, whose type isn't PlainData.
    @PlainData struct LagEntry {
        var lastAckAt: ContinuousClock.Instant
    }

    // After: the core's value type, read from the core's clock (`turn.now`).
    @PlainData struct LagEntry {
        var lastAckAt: TurnInstant
    }
    ```

    And for a type from another module: `@PlainData public struct SessionID` at its definition, not `extension SessionID: PlainData {}` in the adapter.
- **Owner:** the actor, of everything.
- **Gate:** §3's gate. The goldens must pass unchanged. B0 changes value representations on the sync path (the engine split, `TurnInstant` in lag), so it also gets a host A/B in two cells (the maintainer, 2026-11-19): the default production cell at the top player count, and the ack-heavy cell with lag. The tables-off cell is dropped.

### 3.2 B1 and B2

**Before B1: `TransportAdapter` becomes `package` (its own PR, "E", #673).** B1 makes the adapter conform to `TurnActor` directly. `TurnActor` is `public` (`TurnActor.swift:10`), so a public adapter could conform, but then every witness would be public API: the machine type `M` with its seven associated types (inputs, effects, keys, outputs and the rest), `core`, `perform` and `flush`. The protocol extension's `send` and `query` would be callable on the adapter too, and Swift has no internal conformance. A `package` adapter keeps all of that package-scoped:
- `TransportAdapter`, `LandManager.Container.transportAdapter` and `Container.init` (its parameter is the adapter) drop to `package`. The maintainer approved the removal, with no deprecation (no external users).
- EncodingBenchmark measures the adapter directly. It goes through a public facade in Transport, `TransportAdapterBenchmarkHandle` (its doc comment: benchmark and test support, not an integration surface). The facade covers what the benchmark uses, and each member is listed under Public API in E's PR:
  - the container: the benchmark takes the router's adapter from `container.transportAdapter` (`RouterJoin.swift:247`), so the facade builds a container around a handle's adapter;
  - the wiring: the adapter as the transport's `TransportDelegate` and the keeper's `LandKeeperTransport` (`setDelegate`, `setTransport`). The facade wires the real adapter, with no wrapper hop on the measured path;
  - the sync and event calls the benchmark makes;
  - the `@_spi(Diagnostics)` reads, forwarded under the same SPI: `syncSkipCounts`, `framePrefixCacheCounts`, `effectiveStateUpdateFeatures`, `syncLagAckDiagnostics` and `waitForOutboundDrain`. No new SPI.
- GameDemo builds in the `examples` job and in E2E, so E migrates it in the same PR.
- The tests that import Transport with `@testable` (the two `SyncTablesFrameIdentityTests` included) reach `package` declarations and don't change; no CI job builds them in release.
- The measured path must stay the same: a host A/B, base against the facade, under #517's gate.

**After E, before B1: the legacy sync path is removed from live lands, in two steps (the maintainer, 2026-11-20).** So B1 conforms an adapter with one live sync path, and B2 moves that path into the machine. The removal is breaking, with no deprecation (no external users). "The legacy path" is two layers, and they come out separately:
- **L1, the off mode:** the `IN_TURN_SYNC` switch and the public parameters that select it;
- **L2, the adapter's own cycle on live lands:** `withSyncState` over `keeper.beginSync`/`endSync`. It still runs with in-turn sync on (below), so removing L1 doesn't remove it. Replay keeps it until #612.

**L1: the switch (its own PR to `main`, mechanical).**
- **Goal:** no production configuration can turn in-turn sync off. The adapter's off mode stays reachable only through a `package` parameter, for its remaining users: reevaluation keepers (`LandManager.swift:720` forces it) until #612, and the harness's legacy cells and the tests that pass it explicitly.
- **Sources:**
  - `EnvKeys.Runtime.inTurnSync` and `InTurnSync.isEnabled()` (`InTurnSync.swift:39–45`) are deleted. `TransportAdapter`'s effective setting becomes its `inTurnSync` argument alone (TA:963);
  - `NIOLandHostConfiguration.inTurnSync` (`NIOLandHost.swift:210–254`) is deleted;
  - `LandManager`'s three inits drop their public `inTurnSync:` parameter; a `package` init keeps it for the harness and the tests (`LandManager.swift:246–356`);
  - the keeper doesn't change: it follows the transport (`usesInTurnSync`, `LandKeeper.swift:664`).
- **Tests:**
  - the env-driven off arms go: `.enabled(if: InTurnSync.isEnabled())` traits lose the condition, and `if !InTurnSync.isEnabled()` branches are deleted (GracefulShutdown, WebSocketSessionHandlerInboundBacklog, EventFramePackBytes, JoinPendingInbound, CollidingKeys, ExistentialGap, ActionJobReplayOrder, and the rest of the grep);
  - a fixture read only by the off leg (`HybridEventFrameGoldenTests`' legacy file) is deleted with its arm;
  - tests that pass `inTurnSync: false` explicitly keep it through the `package` init, and keep covering the off mode until L2;
  - the comments in the core tests' doubles that say "whatever `IN_TURN_SYNC` says" are reworded.
- **The harness:** every cell, legacy included, runs as today (the runner passes `cell.sync.inTurnSync` to the `package` init). Every golden stays byte-identical, and that is L1's acceptance test.
- **CI:** the build-and-test job's `in_turn_sync` matrix axis and the E2E job's become one leg, and the in-turn-off test variant #668 adds goes (Code-2's follow-up). `scripts/check-variant-test-selection.sh`'s S6 rule, which checks that axis, is rewritten or removed with its self-tests.
- **Tools and scripts:** `Tools/CLI/src/sync-output-verdict.ts`'s off branch and its test; `IN_TURN_SYNC=true` in `Tools/regenerate-sync-output-goldens.sh`; any measurement script that sets `IN_TURN_SYNC=false`.
- **Docs:** `docs/core/runtime.md` and `.zh-TW.md` (the kill-switch paragraph and the legacy-path notes), the env tables in `docs/transport/README.md` and `.zh-TW.md`, and `AGENTS.md:89`.
- **Gate:** §3's gate in its one-mode form, plus the goldens unchanged. No host A/B: the default path's code doesn't change.

**L2: the adapter's own cycle on live lands (placeholder; laid out in its own plan before it is fixed).** The maintainer wants L2 laid out carefully first. It is a step of its own, after L1 and before B1. Its groups, each to be planned with its call sites, tests and gate:
- **2a. The adapter's own syncs,** which run the cycle with in-turn sync on: the follow-up (TA:3119), the backlog retry (:3137, :3176), the failed plan's delayed follow-up, and the lag timer's sync (:3557). On a live land they become requests for a keeper sync-only turn (`runSyncOnlyTurn`).
- **2b. The public `syncNow()` and `syncBroadcastOnly()`:** about 134 test calls, EncodingBenchmark's measured path (29 calls) and `SwiftStateTreeBenchmarks`. They become "request a sync turn and await it". The benchmark's measured path changes, so this group gets a host A/B. `TransportAdapterBenchmarkHandle` (E) forwards `syncNow`, and also pins two other public entry points this removal touches: `syncStateForNewPlayer` and the join path with `completedInTurn == false` (which `Rejoin.swift` uses). L2's plan, or the legacy-join removal, says what the handle does with each; the handle is the single place they show.
- **2c. The freeze:** the settle (TA:6503) and the resume's replay (:6574).
- **2d. The core tests' doubles:** every keeper whose transport isn't the attached adapter runs the keeper's off path (`usesInTurnSync` is false): the fake `LandKeeperTransport`s of about 15 `SwiftStateTreeTests` suites. They move onto the in-turn path.

**Replay keeps the legacy cycle until #612 (the maintainer, 2026-11-20).** Reevaluation keepers run the off path by design (`LandManager.swift:620–624`, `mode != .live`): the same-land replay adapter and the runner's keeper. Their redesign belongs to #612 (replay on typed inputs fed into the same turn machine; #550 folds into it). So:
- after L2, the legacy cycle (`beginSync`/`endSync`, the keeper's off path, the adapter's off executor) is used by replay only;
- **B2 starts with one live sync path, and the legacy cycle used by replay only;**
- deleting the keeper's off path, `beginSync`/`endSync`, the adapter's off executor, the harness's legacy cells and legacy-only rows (`disconnect-sending-join-response`, `disconnect-sending-initial-sync`, `join-during-sync-cycle`, each retired with its replacement) and B2's decisions 1 and 4 is #612's last step, not a precondition of B2.

**The replay-only cycle in B2: (b), decided by consequence (2026-11-20).** The maintainer's call not to build what #612 deletes settles it (Main; the maintainer may still object). The options were:
- (a) decisions 1 and 4 apply to it as written, with rev 8's must-fix 1–2 on decision 4 still to settle; or
- (b) it stays an actor loop outside the machine, its commit a query (`.legacyCommit`, as in §3.2), with no `.syncCycle` request: today's busy skips and retries are unchanged, for replay only.

*Taken: (b).* Replay isn't on the live path, and #612 replaces it, so (b) builds none of decisions 1 and 4's request machinery only to delete it. It needs the machine to accept a commit query outside any held key, which decision 2's settle commit already does.

**B1: the empty machine.**
- `TurnCore` in the adapter, which conforms to `TurnActor` directly, and the production `TurnClock` over `safeTaskSleep` (core plan §3.4). The dependency itself arrived in B0.
- The machine has no state yet. No behaviour change.
- Gate: §3's gate.

**B2: sync and lag move to the machine.** The machine owns, from B2 on:
- the sync state: `syncSkips`, the backlog flags, `lastSyncSeq`, `planSyncSeq`, `syncEngine`, `pendingEventManager`, `carriedDirtyFields`, the sync-stream sets and `syncPhaseCommits` (the commit epoch);
- the lag state: `syncLag`, `syncLagFullPlanRequested`, and the lag timer on `.lagTimer`;
The actor keeps membership, join, inbound, actions, land failure, and the whole freeze (its settle, its control and its auto-resume) until B5; the settle's commit is a query (§3.3, decision 2).

**Keys in B2:**
- `.syncCycle` for the cycle;
- `.lagTimer` for the lag timer;
- `.followUp(n)` for each failed plan's follow-up: today each runs its own task, and rule 18 allows one timer per key, so they don't coalesce.

**The in-turn commit.** When the keeper's turn calls `runSyncPhaseInTurn(state:events:…)`, the adapter builds a `MembershipView` in the same synchronous segment, and calls `core.query(.syncPhase(read, events, view, tools))`. The view holds the members, the joining sessions that this phase may flip, the held events, each session's lag entry, and what event routing needs (§3.3, decision 3). The answer appends the phase's events, then runs `planAndCommit`.

> **Live lands: superseded by L2. Replay: (b) (§3.2, "The replay-only cycle in B2"): the driver below stays an actor loop with its `.legacyCommit` query; the `.syncCycle` request, the in-flight record and the parked retry are not built.** L2 removes the adapter's own cycle from live lands before B1, so the legacy cycle reaches B2 for replay only. The text from here through the legacy flag's list (the legacy driver, `.syncCycle`'s request, the backlog retry), the cycle parts of "Retry, follow-up and lag timer" and of `syncNow`, and decisions 1 and 4 stay for the record until L2's plan is GO; B2's detail is then rewritten against the one sync path.

**The legacy cycle stays an actor-driven loop in B2, with its commit as a query.** The legacy driver awaits `keeper.beginSync`. In the segment where that await returns, it builds the `MembershipView` and calls `core.query(.legacyCommit(read, view, tools))`. It then awaits `keeper.endSync`. So the membership view is captured at the cycle's ingress, after the keeper's read, in the same segment as the commit, as today.

**What holds `.syncCycle`.** A flag in the machine holds no core key, and an input queued behind an unheld key is releasable at once (`Turn.swift:158–166`). So the cycle is a request:
- A cycle starts as a step (`.cycleStart`), which files a `.legacyCycle(id)` request under `.syncCycle` with `Hold.untilWorkerReturns`. `id` is a cycle number the machine counts. `untilRequestCloses` would release the key on the request's deadline, on cancellation or when the key ends (`Values.swift:62–74`), while `beginSync`/`endSync` still run; `untilWorkerReturns` keeps it until `perform` returns.
- Its `perform` awaits the actor's driver, `adapter.runLegacyCycle(id)`: `beginSync`, then the `.legacyCommit(id, …)` query in the same segment as the await's return, then `endSync`. It returns the cycle's outcome: `.committed`, `.busy` or `.notStarted` (a failed `beginSync`, or no read). A stale commit is unreachable (§3.3, decision 1), so it's no outcome.
- **The ID, a stale commit, a second call and the deadline:** §3.3, decision 1. An accepted `beginSync` gets exactly one `endSync`, called by the driver after the query whatever it answered; a failed `beginSync` gets none.
- **`syncNow` keeps today's boundary:** it returns after `endSync`. The driver resumes `syncNow`'s waiter there, and the cycle's `perform` returns there too: the ordinary cycle doesn't wait for the writer. The handoff is §3.3, decision 4.
- **The backlog retry** is queued behind `.syncCycle`, so it releases after the cycle's worker returns. Its own `perform` keeps today's waits before it sends `syncRequested`: after a busy rejection, 1 ms for the other cycle to reach `endSync`, and always `writer.waitForSyncCycleDrain()`, even when the key was already free. Parking until the worker returns is an intended difference (decision 4).
- The freeze settle stays an actor loop in B2 and doesn't use this request (§3.3, decision 2).

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
- **the emit effects** (decision 5): `.eventHeld`, `.joiningEventsDropped`, `.joinFailed(session, .eventOverflow)`, `.ceilingDropped` and `.syncDeferredByFreeze`;
- **`.heldEventsDelivered(session)`:** the flip delivered the session's held events; the actor clears its held store;
- **`.lagClose(session, generation, code)`:** `flush` fences the session and then starts the transport close, in that order, as `endAndCloseSession` does today: inbound closed, outbound ended, then the close with the captured generation. In B2 the machine files no close request, so no effect can launch before the fence; the `syncLagClose`/`syncLagClosed` holds stay on the actor's close path, where they are today. Inside the answer the commit's own frame filtering already skips the session: the machine set its lag phase to `.closing` before it filtered frames (TA:4249, :4298 order);
- **`.fullPlanRequested`:** recorded as today.

The lag decisions are made inside `planAndCommit` against the `MembershipView` plus this commit's flips, so a session flipped by this commit is seen as a member.

**Which keys, in B2.** The machine owns no `.session` keys in B2: membership is the actor's. Every output is emitted for `.land`, which the machine starts at B1 and which stays live until B5's `endAll`. The machine's own keys in B2 are `.land`, `.syncCycle`, `.lagTimer` and `.followUp(n)`, each started and ended by the machine (`.freeze` arrives with B5). Session keys arrive with B3.

**Which actor fields a step reads.** No machine step reads an actor field: the steps see only machine state, the view a query carries, and their inputs. That is what makes `flush` the only place the actor's fields change in response to a commit.

**Bridges the other way: actor writes to state B2 moved.** Each is a named synchronous query at today's call site, in the same segment as today's write. A query outside a step doesn't trap.
- **`.sessionEnded(session)`:** the disconnect discards the session's lag entry at once (TA:1290).
- **`.ticketRenewed(session)`:** the ticket renewal on a rebind *discards* the lag entry (`syncLag.removeValue`, TA:1541); it doesn't move it.
- **`.playerCleared(player, outsideTurn:)`:** clears the per-player sync caches (`syncEngine`'s value part, `perPlayerTables`, the recorder's clear). Two call sites, both outside adapter steps in B2:
  - **disconnect**, after `keeper.leave` returns and behind the last-session recheck (TA:1332), with `outsideTurn: true`;
  - **supersede**, inside the keeper's synchronous admission callback, which also discards each old session's lag entry first (`.sessionEnded`), with `outsideTurn: false` (TA:1884–1907).
- **`.teardown`:** the recoverable teardown's `syncLag.removeAll()` (TA:1577). The #548 row exercises it.
- **`.ack(session, seq)`:** `onSyncAck` updates the lag entry (TA:3381–3396).
- **Merged events.** The append carries what `queueForMergedSend` uses today: the membership stamp, the canonical digest, and its queued / no-recipient result (`PendingEventManager.swift:67–81`, TA:2748–2755, :2826–2848). One machine method, `appendMergedEvent(stamp, digest, body, target) -> QueueResult`, has two fixed call sites, each known statically (no routing by the borrow flag):
  - the legacy and out-of-phase sends (`sendEvent`, TA:2703) call the `.mergedEvent(…)` query, outside any answer;
  - the in-turn phase's events travel in `.syncPhase`'s value, and its answer calls the method in its prepass (§3.3, decision 5).

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
- `syncLagClose` and `syncLagClosed` stay on the actor's close task, where they are today (B2 files no close request);
- `initialSync` and `initialSyncAfterRead` stay on the actor's path.

Their users and the harness rows are listed in §6 (Appendix A).

**The tests' waits in B2.** A test that waited on a wall-clock poll for a sync effect waits for the commit's `Commit` value (an observation the answer writes) or for `syncNow`. A timer test steps the test clock, then waits for the timer step's apply milestone, an observation that step writes. The lag files' wall-clock entries leave the baseline in B2.

**Gate:** §3's gate, plus the host A/B at B2's SHA (§5).

### 3.3 The B2 decisions

Each is a choice the code can't make for us: a wrong guess changes goldens or records silently. Each has a recommendation.

**Decision 1: a stale `.legacyCommit`, a second call, and the cycle's deadline.** *Live lands: superseded by L2. The replay-only cycle took (b) (§3.2), which doesn't use it. Kept for the record; #612's last step deletes the cycle.*

`beginSync` hands back the read, and the keeper clears its dirty state for it. If the commit were then refused as stale, nothing would re-mark those fields, and the next cycle wouldn't send them.

The options:
- commit a stale cycle's read anyway;
- carry its dirty fields forward (`carriedDirtyFields`);
- show the stale case unreachable and make it a fault.

*Recommended: unreachable, made a fault, with the commit kept.*
- **Why it's unreachable.** `.cycleStart` is the only step that advances the cycle ID. With `untilWorkerReturns`, `.syncCycle` stays held until the driver returns, after `endSync`, whatever happens to the request (deadline or abandonment, `Values.swift:62–74`). A new cycle can't start while the key is held (below), so the driver's ID is always current when its `.legacyCommit` runs.
- **The fault.** `.legacyCommit` asserts the ID in debug builds, and commits in every build. So if the reasoning is ever wrong, a test fails loudly, and production loses no dirty field. That is better than refusing the commit, which would lose data, and simpler than carrying the fields forward for a case that can't happen. `.legacyCycleEnded` keeps its ID check: there a stale value can only drop bookkeeping, never data.

**A second call while the key is held is a busy skip, as today.** `.cycleStart` doesn't wait for `.syncCycle` (its policy names no `waitsFor`). It steps at once and reads the machine's in-flight record, which is set when it files the request and cleared by the driver's `.legacyCycleEnded` query after `endSync` (decision 4). If a cycle is in flight, the step records the skip: the backlog flags, and the coalesced retry queued behind `.syncCycle`. It then answers the caller `.busy` at once. So the off-mode test that awaits the skip before it opens the first cycle's hold (`TransportAdapterInTurnSyncTests.swift:926–939`) doesn't hang.

**The deadline.** Every holding request needs one. An ordinary cycle's deadline is a fixed 10 s, and it's diagnostic only. (The freeze's settle has its own configurable deadline, and doesn't use this request: decision 2.) When it passes, the request is abandoned: the machine counts a diagnostic and logs the overrun. Nothing else changes, because:
- the key stays held until the worker returns;
- `syncNow`'s waiter is resumed by the driver after `endSync`, not by the request;
- the in-flight record is cleared by the driver's `.legacyCycleEnded`, whatever happened to the request; the worker's late result goes through the stale step and only ends the key's hold.

A hung `beginSync` or `endSync` is the keeper's bug, and it shows up as that diagnostic.

**Decision 2: the freeze handshake.**

*Recommended: the whole freeze stays on the actor through B2, the settle included; only its commit goes through the machine.* In rev 6 the settle moved and its control didn't, which needed a handshake between them. Keeping the settle with its control removes the handshake: the three questions keep today's answers, unchanged.
- **A release during a settle.** The release clears the freeze count, and a fresh freeze advances the generation (TA:6368–6373, :6551–6558). The settle checks `debugIsCurrent(generation)` after its last await, and publishes nothing for a released generation (TA:6464–6575, `debugReleaseFreeze`).
- **Ordinary syncs across a release and a refreeze.** `debugDeferSyncIfFrozen` latches them on the actor, before `.cycleStart` is sent. The release replays them, or hands them to a refreeze that happened meanwhile.
- **The one deadline.** It covers the keeper's drain, the writer's backlog wait and the busy retries, in the settle's own loop.

The settle's commit runs `core.query(.settleCommit(read, view, tools))`, in the segment where its `beginSync` returned. It keeps today's details:
- the membership epoch read before the copy;
- the empty-land copy that clears no dirty flags;
- the generation check after `endSync`;
- the follow-up flag for events kept with no periodic sync.

The settle doesn't hold `.syncCycle`. It excludes ordinary cycles the way it does today: the keeper's `beginSync` refuses a second cycle, and the settle retries. An ordinary cycle during a settle gets a busy outcome from `beginSync`.

**Decision 3: merged events while `.syncPhase` holds the machine.**

The answer holds the machine borrowed (`TurnCore.swift:283–288`), so no actor-side code can reach it while the answer runs.

*Recommended: the phase's events travel in the query's value.* In the in-turn path, `runSyncPhaseInTurn` already receives the turn's events (`events: [InTurnServerEvent]`) and appends them itself before the sync, through `enqueueEventSynchronously` (TA:2826–2858). So `.syncPhase(read, events, view, tools)` carries them, and the answer appends them through the machine's `appendMergedEvent` before `planAndCommit`. Nothing else appends during the answer. The legacy and out-of-phase sends (`sendEvent`, TA:2703) use the `.mergedEvent` query, which runs outside any answer.

What moves where:
- **Target resolution** is in the answer, from the view: the player-to-sessions map with each binding's fan-out stamp, and the client-to-session map.
- **The digest outcomes** stay as they are: digested when the stream is recorded, including events-only and backpressured phases. `.lost` ends the land, as today: the answer closes the output gate (a tool) at today's point and answers `.landFailed` (decision 5).
- **Immediate sends** go through the writer, a tool, inside the answer.
- **Held-event writes, join failures, ceiling drops and the freeze deferral** are the named outputs of decision 5.
- **The discard accounting** (TA:4130–4143) is read through a query before the actor invalidates the membership, at today's call site.

Rejected: showing that nothing appends during the answer. That isn't true today, because the phase appends its own events.

**Decision 4: the legacy cycle's handoff.** *Live lands: superseded by L2. The replay-only cycle took (b) (§3.2), which doesn't use it, so rev 8's must-fix 1–2 don't apply. Kept for the record; #612's last step deletes the cycle.*

`.cycleStart` keeps today's order of checks (TA:3146): the writer-backlog check first (a backlogged writer skips the cycle, sets the backlog flags and schedules the coalesced retry), then the in-flight record (busy skip, decision 1), and only then the request.

*Recommended: the driver clears the in-flight record before it resumes `syncNow`'s waiter.* After `endSync` the driver calls `.legacyCycleEnded(id)`, which clears the record (its ID check drops a stale value), then resumes the waiter. So a `syncNow` called right after the previous one returns finds no cycle in flight and is accepted, as today, where `endSync` has already cleared the keeper's flag. It files its request behind `.syncCycle`, which may still be held for the few instructions until the first worker returns.

Why not `Turn.reply(after:)` for the waiter: it also replies when the request is abandoned. A deadline would then resume `syncNow` before `endSync`, which breaks today's boundary.

**The retry's parking is an intended difference.** Today a busy retry sleeps 1 ms, then retries: if the cycle is still in flight it meets it again, counts a second busy skip and schedules itself again, every millisecond while the cycle lasts (#654 holds it explicitly to make its row deterministic). In B2 the retry is queued behind `.syncCycle`, so it runs only after the worker returns. It never meets the same cycle twice, and `syncSkips.busy` counts one skip per rejected request. No golden changes: the only row that holds a cycle across the retry holds the retry too.

**Decision 5: the phase's event prepass.**

Today `runSyncPhaseInTurn` appends the phase's events (TA:2829) before it selects the ready joins (:2870), so an event held for a joining session is in that session's held store when the join is selected.

The options:
- the actor appends the events in a prepass, before it captures the `MembershipView`;
- the answer keeps today's order inside the one query, with query-local state.

*Recommended: the answer keeps today's order, with query-local state that every emit effect updates.* A prepass on the actor would need a second view, or a view captured before the events changed it.

**The query-local state (`PhaseScratch`).** The answer builds it from the view when it starts, and every later step of the same answer reads it, never the view:
- per joining session: its held frames' count and bytes, whether it holds events, and whether it has failed;
- the full candidate list for the flip: every in-turn join that is ready and whose ticket is current, in FIFO order (`readyInTurnJoins` without its `prefix`). The view carries the whole list, and the answer applies the budget after the events, so a join failed by an emit gives its slot to the next candidate, as today;
- `endedSessions`, copied from the actor;
- the freeze flag (`debugFreezeState.count > 0`).

**Every effect an emit can have, its output, and what later steps see.** Today each `enqueueEventSynchronously` can do all of these, and the next emit and the ready selection see each one (TA:1781–1796, :1819–1830, :2727, :2826–2879, :4084–4128, `TransportAdapter+Outbound.swift:28–63`):

| Effect | In the answer (`PhaseScratch` or machine) | Output, applied by `flush` |
|---|---|---|
| A targeted frame held for a joining session | the session's held count and bytes grow | `.eventHeld(session, frame)`: appended to the actor's held store |
| A targeted event a joining session doesn't get (it holds none, or it has failed) | none | `.joiningEventsDropped(count)`: `eventsDroppedForJoiningSessions` and its rate-limited log |
| A held frame that takes the session over the bound | the session's held frames are cleared, and it is marked failed: later emits drop for it instead of holding, and the flip selection skips it | the drop's `.joiningEventsDropped`, then, after the emit (today's `defer`, TA:2727), `.joinFailed(session, .eventOverflow)`: the held store and bytes cleared, the deferred inbound discarded and counted, the record marked failed, the waiter resolved, `inTurnJoinFailures` counted |
| A writer element dropped over the ceiling | the addressed sessions join the scratch's `endedSessions`: later emits and the commit's frame filter skip them | `.ceilingDropped(sessions)`: `endedSessions`, `outboundCeilingDisconnects`, the log, the warn-once, and each session's close |
| Lag filtering of an immediate send | `syncLag` and `syncLagDroppedEvents` are machine state in B2: written in the answer | none |
| The digest and the `.noRecipient` / `.sentAlone` / `.lost` accounting | the sync-stream sets are machine state in B2: written in the answer, events-only and backpressured phases included (the accounting runs in the emit loop, before those checks) | none |
| `.lost` at emit `k` | the answer closes the output gate (a tool) at today's point and answers `.landFailed`; emits after `k` and the sync don't run | none of its own; the outputs of emits `0..<k` stay emitted |
| The freeze deferral (TA:2859), after the writer and backlog checks | the answer answers `.skipped` | `.syncDeferredByFreeze`: sets `deferredSyncNow` on the actor's freeze state |

**The flush order.** Emission order, which is today's order of the writes:
- per emit, in emit order: its holds and drops as the target resolution meets them, its ceiling drops when the writer refuses, then its overflow failures;
- after the events: `.syncDeferredByFreeze`, or the commit's outputs (`.flipped`, `.lagClose`, `.fullPlanRequested`).

**Why applying them after the answer keeps today's behaviour.** The answer reads only `PhaseScratch` and machine state, so it sees each effect at the point it sees it today. Called outside a batch, `TurnActor.query` runs the segment before it returns, and the segment flushes outputs before it admits any input (§3.2's bridges). So the actor's fields are as today's before the keeper sees the phase's result, `.landFailed` included, and before any other actor code runs. The freeze is actor-owned and the keeper's turn is synchronous, so the freeze flag can't change between the view and the flush. A waiter resolved in `flush` instead of inside the emit resumes its caller after the turn in both cases.

**Witnesses, as B2 tests (with the existing row where there is one):**
- an overflow at emit `i`, then emit `i+1` to the same session: dropped and counted, not held; the next candidate takes the budget slot (`LandRouterJoinEventOverflowTests`, `TransportAdapterJoinHeldEventsTests`);
- a ceiling drop at emit `i`: no frame for those sessions from later emits or from the commit;
- `.lost` at emit `k`, after a hold at emit `j < k`: the held frame is in the actor's store when the keeper sees `.landFailed`;
- a frozen land: the in-turn phase defers, and the resume replays it.

The mutant for each: the later step reads that effect's field from the view instead of `PhaseScratch`, which must fail its witness.

### 3.4 Details for the code (B2)

These are settled against B2's code and its tests; each keeps today's behaviour:
- **Coalescing:** today's writer-backlog check and the full-over-broadcast retry coalescing. The driver's waiter on success checks for a follow-up after `endSync`; on failure it submits the failure before it returns (TA:3146–3179, :3237–3287).
- **The writer and the flip handoff:**
  - `endedSessions` filtering and the synchronous writer-ceiling fencing stay where they are;
  - with the gate closed, the commit still marks the join flipped and resolves its waiter, and starts no drain;
  - a ceiling drop ends every addressed session at once (TA:4249–4271, :4298–4315);
  - the held-overflow path stays a join failure, through the router's final-frame close.
- **The lag timer:** its stop and re-arm rules and its single-flight latch (TA:3391–3409, :3508–3557). The latch stays set through the `syncLagTimerSync` hold and is cleared just before the sync's dispatch (TA:3537–3557). The barrier counts it through the timer's wake, an abandonment, the worker's return and the writer's handoff.
- **The guard:**
  - the broadcast table (`SyncTables.swift:1593`) is non-`Sendable`, so the compiler check covers it with `perPlayerTables`;
  - the actor-side event, action and gate writers are listed beside the keeper's `closeOutputs`.
- **The recorder witness.** In-turn, the keeper submits the drafts after the adapter's query has returned (`LandKeeper.swift:4618–4625`), so a mutant on that submission can't witness the borrow trap. The mutant goes on the legacy submission (`submitSyncStream`, inside the legacy commit query) and inside the adapter's draft production.
- **The first sync:** the initial sync's delayed follow-up (`failedPlanFollowUp`) applies to tickless lands only; `isSyncCycle: false`, the initial sync's failure submission, the epoch captured before the keeper's read (TA:5536–5610), and `beginInitialSync(for:)` (TA:1957) as the separate reservation writer of `initialSyncingPlayers`.

## 4. B3–B6: outlines

Each step below gets its own plan PR before its code.

### B3: membership, join, inbound and the initial sync

- **Goal:** one land-wide membership domain, held across each operation's whole chain:
  - join: keeper join → entry read → transport registration → join-sync request;
  - register: entry read → transport registration;
  - leave: keeper leave → its tail.

  The hold passes between links through each completion step (`TurnActor.swift:170–176`; Review confirmed both the normal and the stale form). Queued membership inputs are scoped to a `.membershipEpoch(n)` that the recoverable teardown ends. The flip moves into the commit. B2's flip and held-event bridges and the legacy driver's queries go away. The public changes land here: the required `WithdrawToken`, the `Transport` defaults that ignore the connection generation (#240), `JoinAdmission.refused`, and the D2 stamp.
- **Also in B3:** `MembershipCoordinator` becomes a value type (deferred from B0), when the machine takes membership.
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
    - The harness row is ready for this, in two revisions of #654: 20e15dae records A's ticket as a note and `join-A` as `recorded(#548)`; ce9db968 adds `pa`'s lifecycle as `recordedLifecycle` (#548), so the oracle doesn't judge it. The branch's refusal is then comparator differences, not a run failure. The comparator matches one entry per exact difference per cell, so the list has one entry per channel and checkpoint: the note at the live checkpoint, and the changed frames of connection `a` at each checkpoint where they differ.
    - **`pa`'s lifecycle after the fix is not predicted here.** #654's own comment expects the fix to drop A's `[join, leave]` pair; with a compensating leave that runs OnLeave it would stay `[join, leave, join, leave]`. The oracle allows either. The exact entries, per cell, come from the branch's run at B3, each naming #548 and, for byte comparisons, both digests.
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
  - the freeze, settle included, moves to the machine, with the handshake rev 6 left open (§3.3, decision 2) settled in B5's plan;
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

- **D1 (decided, 2026-11-20).** The legacy sync path is removed from live lands before B1, in two steps: L1 (the switch) and L2 (the adapter's own cycle on live lands), §3.2. The production rollback switch (`IN_TURN_SYNC=false`) goes with L1. Replay keeps the legacy cycle until #612, whose last step deletes it. The replay-only cycle in B2 is (b), an actor loop outside the machine, decided by consequence.
- **D2.** #652: allow a reused SessionID, with the binding stamp and generation-aware output in B3 (proposed), or forbid it.
- **D3.** #588: before the recording, or after the merge (proposed). With it goes the keeper's join recheck (§4, B3).
- **D4 (decided: (a)).** Module layering (§2.2); the rule is documented in B0.
- **D5 (#658).** An action's response against its turn's diff: ordered by the turn's outputs, or explicitly unordered. Today the response task's window lets a sync go first, in every encoding.

## 8. Risks

- **The per-message `core.read`.** If it costs more than the budget on 6.2.4 (#621), the sync path regresses. The guards are `check-turns-inlinable.sh` and the A/B at B2.
- **The tools outside the machine.** `CommitTools` is passed in and not stored. Its writers are guarded by the borrow assertion. The compiler keeps `perform` away from the two table tools only; the writer, the gate and the encoding pipeline are reachable from `perform`, and a review rule keeps them out of it (§2.1).
- **The B2 bridges.** Each bridge is applied in the commit's own segment. If a bridge is missing for a write the actor still makes, a test of that write fails at B2's SHA.

## 9. Rev 9: what changed

| Change | Where |
|---|---|
| The legacy path's removal from live lands (D1 decided): L1, the switch, in full; L2, the adapter's own cycle on live lands, as a placeholder with groups 2a–2d (the adapter's own syncs, the public `syncNow`, the freeze, the core tests' doubles) | §3.2, §3, §7 |
| Replay keeps the legacy cycle until #612, whose last step deletes it; B2 starts with one live sync path and the replay-only cycle; that cycle in B2 is (b), an actor loop outside the machine with its commit as a query, decided by consequence | §3.2, §3.3, §7 |
| The benchmark handle pins `syncStateForNewPlayer` and the `completedInTurn == false` join path: noted where L2 touches them | §3.2 |
| Decision 5: `PhaseScratch`; every emit effect with its named output (`.eventHeld`, `.joiningEventsDropped`, `.joinFailed`, `.ceilingDropped`, `.syncDeferredByFreeze`) and the flush order; `.lost` keeps the earlier emits' outputs; witnesses and mutants | §3.2, §3.3 |
| E's rationale: `TurnActor` is `public`, so a `package` adapter keeps the conformance's witnesses package-scoped; the facade's members (the container, the wiring, the SPI forwards) and GameDemo in E | §3.2 |
| §2.1 and the risks: only the two table tools are compiler-isolated; #548 cites 20e15dae and ce9db968, the exact entries from B3's run; B0's A/B in two cells; the decisions' heading | §2.1, §3.1, §3.3, §4, §8 |

## 10. Rev 8: what changed

| Change | Where |
|---|---|
| E before B1: the adapter and its container field become `package`, the benchmark facade, the host A/B | B1 |
| Decision 4: the legacy cycle's handoff (backlog check first, the in-flight record cleared before the waiter resumes, no `reply(after:)`), the retry's parking as an intended difference | §3.2, §3.3 |
| Decision 5: the phase's events appended in the answer with query-local state, today's order kept; the borrow-flag routing removed | §3.2, §3.3 |
| The ordinary cycle's 10 s deadline is diagnostic only; the lag latch through `syncLagTimerSync`; the initial sync's follow-up tickless only; §2.1 aligned with §3.4 | §2.1, §3.3, §3.4 |
| A release clears the freeze count, a fresh freeze advances the generation; `.stale` dropped from the legacy outcomes | §3.2, §3.3 |
| B0: the docs section updated rather than added; the Turns edges with the 6.2 floor, landing on `main` first; `MembershipCoordinator` moved to B3 | B0, B3 |

## 11. Rev 7: what changed

| Change | Where |
|---|---|
| D4 = (a) (the maintainer): the edges in B0, the type list with `EventTarget` and `CanonicalSyncEvent`, the documented rule with a before/after example | header, §2.2, B0, B1, §7 |
| Decision 1: the stale commit unreachable, a debug fault that still commits; the busy skip kept; the deadline's abandonment changes nothing | §3.3 |
| Decision 2: the freeze stays on the actor through B2, its commit a query | §3.2, §3.3, B5 |
| Decision 3: the phase's events in `.syncPhase`'s value | §3.2, §3.3 |
| Rev 6's shoulds as details for B2's code; the close holds on the actor's close task; `beginInitialSync(for:)` | §3.4, §6 |

## 12. Rev 6: what changed

| Change | Where |
|---|---|
| `.syncCycle` held with `untilWorkerReturns`; the ID checked in `.legacyCommit` too; one `endSync` per accepted `beginSync`; `syncNow` after `endSync`; the retry's writer drain | §3.2 |
| `.lagClose` fenced before the close starts, with no close request in B2; B2's keys named (outputs for `.land`); the flip drain's gate check and ceiling cleanup | §3.2 |
| Reverse bridges against the code: rebind discards; supersede's and disconnect's call sites and `outsideTurn`; `initialSyncingPlayers` actor-owned; merged events' fields and two routes | §3.2 |
| B0: the value part listed in full, `SyncEngine(for:)` kept, `TurnInstant` and the core clock for lag, the guard scoped to the actor, the broadcast tables as a tool | §2.1, §2.2, B0 |
| Quiescence from scheduling to the writer's handoff; the lag milestone after its fences; the recorder witness with in-turn sync on; stop triggers, the barrier's coverage and the builder's lifetime in the outlines; `onSyncAck` pointer | §2.3, §3.2, §4 |

## 13. Rev 5: what changed

| Change | Where |
|---|---|
| The public `joinResponse` closure stays on the actor through B2 | §2.2, B0 |
| `AtomicLayoutTable` is a `CommitTools` tool under every option; `SyncEngine` splits | §2.2, B0 |
| The commit's bridge is outputs applied in `flush` before any later step; lag-close fencing; `.lagTick`'s binding view; the inbound drain after the flip | §3.2 |
| Reverse bridges as named queries: session end, player left (the `outsideTurn` split), teardown, ack, rebind, merged events; the initial sync's checks and follow-up | §3.2 |
| `.syncCycle` held by a request; the cycle ID; the retry's writer drain | §3.2 |
| The seven missing rev-3 points and the overflow answer in the open lists; B6's stop conditions | §4 |
| #654's merge as the prerequisite; #548 entries per exact difference; the compiler claim scoped; `Data: PlainData` in Turns | header, §2.1, §2.2, §4 |

## 14. Rev 4: what changed

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

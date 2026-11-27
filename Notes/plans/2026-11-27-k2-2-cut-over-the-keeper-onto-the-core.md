# K2-2: cut the keeper over onto the turn core (#700)

Revision 2 (2026-11-27): P-K22-3's Linux output quoted (§7). Revision 1: P-K22-1 run, P-K22-2 settled by reading the code; two PRs (K22-Q4); commits 0, 2 and 3 independent of commit 1. Revision 0 was the prep draft. It is based on K2-1's shape in #938 (head 25ec1efb), which is still in review. Each point that depends on Review's verdict on #938 is marked **[#938]**. The parent plan is `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` (here "K2 §n"), whose §6 defines K2-2 and K2-3 as one PR, and whose §16 items 14–18 are left open for K2-2.

## 1. Goal

After K2-2, a live `LandKeeper` runs every input through a `TurnCore<KeeperModel<State>>`. The keeper's own drivers (`withTurn` frames entered from actor methods, the tick and sync loop bodies, the input drain) are gone from the live path. The public API stays unchanged and so does behavior (K2 §6: "a pure cut-over"), except for what K2-Q3 (a) already keeps: a re-entry during a step is refused and ends the land, as #865 does today.

K2-3, in the same PR, deletes the paths K2-2 made unreachable on live keepers and in the replay owner (K2 §6, condition 4).

## 2. What K2-2 starts from

- **K2-1 (#938) [#938].** The machine routes a closed subset: 11 inputs routed, 10 deferred (`KeeperInputRoutes`). The test harness `KeeperCoreHarness` is its only adopter, and the differential (13 tests, 23 cases) compares it with the keeper's path. The keeper builds its core twin with `coreTwinForTesting`. `KeeperSideStore` holds the step's side, bound to its owner, and `withSide` checks the owner's isolation per borrow.
- **K2-1b (§16 item 18, its own PR, not yet written).** It splits `performInitialization` and `drainAfterIdleCheck` into K1b-5 segments on today's keeper and ends CLAUDE.md's #522 exception. K2-2 routes both only after K2-1b merges. If K2-1b is still open when K2-2 is ready, K2-2 waits; it doesn't route those two flows on unsegmented bodies.
- **Deferred inputs and queries at #938:**

  | Input / query | Destination in K2-1 | K2-2 commit (§3) |
  |---|---|---|
  | `.actionResolved` | the action jobs (§16 item 17) | 0 |
  | `.initializeResolved`, `.destroyHandlerResolved`, `.drainFinished` | K2-1b, then K2-2 (item 18) | 1 |
  | `.freeze`, `.resume`, `.awaitResume` | the freeze barrier | 2 |
  | `.awaitInitialized` | the initialization barrier | 2 |
  | `.shutdown` | K2-2 | 1 (it ends in the drain) |
  | `.syncStreamDraft` | K2-2 | 3 |
  | queries `.admitClientEvent`, `.syncTurnNow`, `.syncTurnTicket`, `.settle` | `preconditionFailure("… is not routed yet")` | 2 (the first), 3 (the sync three) |

  Commit 4 then checks that `KeeperInputRoutes.deferred` is empty and the query `answer` has no unrouted arm. That check is the wiring step's precondition: the routed subset must be total.

## 3. Commits

Two PRs (K22-Q4, Main's lean, 2026-11-27): **K2-2a**, commits 0–3, still unwired, so the differential grows with them and the PR builds green on its own, as K2-1 did; **K2-2b**, commits 4–6, the cut-over, reviewable on its own. One commit per step, each building green.

**Commit 1 is blocked on K2-1b**, which waits on the maintainer (#117). Commits 0, 2 and 3 don't depend on it: none of them routes the initialization, the destroy drain or anything that ends in them. Where a commit-2 flow ends in one of those (the stop's drain, an initialization barrier still closed), that part is commit 1's, named below. K2-2a can merge without commit 1; K2-2b needs it, since the wiring needs the routed subset total.

**0. The action jobs on the core** (K2 §16 item 17). The job lane's four keeper-only parts move together:
- the job's task, staged through `side.keeperReference` and installed in `jobTasks`, becomes one `turn.run(.actionJob(…))` per job, and `.actionResolved(seq, token, result)` comes back. Its step checks the job, the entry generation and the sealed token (K2 §4.3);
- the abandonment's `onEnded` release becomes a result input that `perform` returns when the job's task is cancelled; `handleAbandoned` covers a run the core abandons (which one the core calls on a cancelled `run` is read from TurnActor.swift's `run` handling in rev 1, with a test citation, not a probe: the core's own tests pin it);
- **the caller's cancel. `.cancelsCall` alone doesn't match today** (found reading the code for P-K22-2). Today `awaitActionResult`'s cancel handler (LK:2370 at #938's head) sets `callerCancelled` and cancels the job's task synchronously, and `.actionResolved`'s segment then turns a success into `CancellationError` (LK:5963): **the action is not applied**. The core's `.cancelsCall` on a stepped input lets the work go on and only the caller stops waiting (CancellationTests.swift:78, test 24: "the work goes on and its reply finds no waiter"), so the action would be applied. **Proposal:** keep the box. The job's box (the `callerCancelled` flag and the task, Sendable, not plain) rides the `.actionJob` effect and comes back on `.actionResolved`; the model never stores it. The caller's wait is `sendAndWait(.awaitActionResult(seq), cancellation: .cancelsCall)` inside a `withTaskCancellationHandler` whose `onCancel` sets the box's flag and cancels its task, synchronously as today, so a completion that hasn't run yet fails with `CancellationError`. The wait finds its box through a table on `LiveLandTurns` keyed by the sequence (beside the services table), written by `flush` from the intake's output and removed by `.actionResolved`'s output. The differential pins it: a job whose caller cancels before the resolver returns is not applied on either path, and its caller gets `CancellationError`;
- `awaitActionResult`'s `slotWaiters` become `coreSlotReplies`, checked like `coreInputReplies`: empty on the keeper's path (a violation entry, not an assert).

Tests: the differential gets a job case per lane shape (a resolver job that succeeds, throws, and is cancelled by its caller), plus §16 item 10's job example: a step that starts a job and cancels it, so the task observes the cancel and the drain doesn't wait for a full run. K2-1's "core side: a job intake" violation entry goes; the job intake is now routed.

**1. The initialization and the destroy drain** (after K2-1b). `.initialize` and `.destroyHandler` become effects; `.initializeResolved`, `.destroyHandlerResolved` and `.drainFinished` are routed onto K2-1b's segments. The differential reruns K2-1b's hold cases (one per await) on the core path. K2 §16 item 13's remaining part goes here: `teardownWaitsForTheFailingTurn`'s scenario, from the failure through the teardown and the drain, on the core path, with every staged start beginning with a call into the owner (SE-0420). Also here, because they end in these flows: the stop's `.shutdown` (queued leaves first, then the destroy, on tick lands too, #511's follow-up, then the drain), and the initialization barrier's closed case (the waiters recorded by commit 2 are answered by the step that ends the initialization).

**2. The barriers and the freeze.**
- `.awaitInitialized` and `.awaitResume` are `sendAndWait` inputs whose step replies at once when the barrier is open, and otherwise records the caller in a model table answered by the step that opens it (K2 §4.2, "barriers, not holds"). No intake is parked by a hold, so a query can't overtake a parked call. Commit 2 routes `.awaitResume` whole, and `.awaitInitialized`'s open case and its waiter table; the closed case's answer is commit 1's.
- `.freeze` / `.resume` route `debugFreeze` / `debugResume`. This ends #129's hand re-check: the freeze's generation is the step's own read, so the post-await re-check goes.
- `.admitClientEvent`'s answer is decided here (§16 item 17's last sentence): **the proposal** is no value, as today (`Void` in `KeeperAnswer`), since no caller reads a sequence. The plan's `Result<Int64>` is dropped unless Review names a caller.

**3. The sync entries, the admission path and the services table.**
- The queries `.syncTurnNow`, `.syncTurnTicket` and `.settle` are routed; `syncTurnNow` keeps its nested `.skipped` answer through `isStepping` (K2 §4.2 matrix).
- `.syncStreamDraft` (the `submitSyncStream` entry) is routed for its awaited callers (the `.legacyCycle` branch, the disconnect's clear).
- The package admission path `admitJoiningSessionInStep(…, recordsSyncStream:) -> (JoinAdmission, [SyncStreamDraft])` (K2 §4.5) replaces the port's `admitJoiningSession` call in the join step. It must land with the join's step on the core, not after it: otherwise every recorded supersede is refused and ends the land. `SyncStreamLeaveReplayTests.supersedingJoinWithOnJoinRecordsItsClear` (tick and tickless) compares the stream with P-K2-2b's golden, with the refusal count at 0.
- The per-player services table moves to `LiveLandTurns`' storage (K2 §4.5): the 10 write sites become outputs `flush` applies. `KeeperPlayerServicesTests` runs unchanged.
- The binding token: the attached transport rides the inputs that need a port (K2 §4.2), and `setTransport` becomes a step that writes it.

**4. The cut-over: the facade, `KeeperOwner` and the drivers.**
- `LandKeeper` becomes the facade over `enum KeeperOwner { case live(LiveLandTurns), replay(ReplayLandOwner) }` (K2 §3). `LiveLandTurns` is the `TurnActor` that owns the core; the facade and the adapter share its executor. K2-0's `facade` lint rule becomes live with the file that declares `KeeperOwner`.
- Every public and package entry forwards (`live.assumeIsolated { … }`, `await live.…`, or a `switch owner` whose arms forward). The guarded entries of K2 §4.2's matrix read `live.core.isStepping` and refuse with their name.
- The sentinel moves into `KeeperBehavior` as its one reference field (K2 §4.2 (a)), with #773's behavior lint listing it.
- The drivers: the tick and sync loops `send(.tickDue(…))` and `.syncDue(…)`. K2 §4.6 names a loop epoch for a stale `.tickDue`; no such field exists at #938 (`loopEpoch` has no hit). **Proposal:** the loops become core timers here only if #762 has landed; otherwise the loop Task sends, and its epoch is the keeper's existing loop generation (to name in rev 1, after reading the loop code at the PR's base). The pending fold leaves the actor: it rides `.tickDue`, as K2-1 already does on the core path.
- The replay owner keeps today's bodies without a core until #612 (K2 §7.2). Its path needs a replay branch for every step-only check added here (a token or a ticket), or replay skips it; the reevaluation E2E (0 mismatch) and the harness pass catch a divergence.
- The census gets a `live.` group for `LiveLandTurns` (K2 §8). The actor's rows leave as they move; `coreTwinForTesting` and the differential read [#938] are rewritten against the facade, or retired once the keeper's own path is gone (commit 6).

**5. The K2-Q1 docs** (K2 §5): `LandContext.services`' doc; `docs/core/land-dsl.md` and `.zh-TW.md` (constant services and sinks in handlers, outside data through resolvers; a service and a resolver's error hold no keeper reference, from K2 §4.5's audit); runtime.md (both languages) names K2's stops instead of Swift's exclusivity check (K2 §7.2).

**6. K2-3: the deletions.** One commit per path proven unreachable on live keepers and in the replay owner: the actor's `withTurn` drivers, `runInputDrain`, the keeper-side job lane (`jobTasks`, `slotWaiters`, `callerCancelled`), `inputTurnResults` once the results ride the effect (§4 item 15), `coreInputReplies` and `coreSlotReplies` once the keeper's path that keeps them empty is gone, and the differential's twin hook. Each deletion's proof is the K2-2 tests rerun. K9 keeps the deletions that need K3–K7.

## 4. The open items from K2 §16

| Item | K2-2's answer | Depends on |
|---|---|---|
| 14, the frame's isolation on the core | **keep K2-1's shape**: `preconditionOnOwner` at step entry, `withSide` per borrow, and every staged start begins with a call into the owner (§16 item 13's shape). Passing the owner as `isolation:` through `assumeIsolated` makes the frame's own `#isolation` the owner, but a Task staged in the flush closure still doesn't run on it (P-K22-1), so it buys nothing the check doesn't | [#938] if Review asks for a different frame shape |
| 15, the tickless results onto the effect | in commit 0 or 2 (whichever first touches the action replies): `.awaitRecordTaken` and `.recordTaken` carry `[seq: Result<InputOutcome, any Error>]`, the waiters are answered from `.recordTaken`'s step, `inputTurnResults` and `coreInputReplies` go in commit 6 | [#938]: the reply plumbing (a) as merged |
| 16, the input drain's hold and idle waiters | **proposal: drop the hold from the core path.** `.inputDrain` is a test hold; on the core, a test holds the drain by holding its effect (`.awaitRecordTaken`) in the harness's `perform`, which the differential already does (`recordGate`). The idle waiters become a test read of the core (`inputDrainScheduled` false and no drain step pending). The tests that hold `.inputDrain` today are listed in rev 1 with their replacement | Review |
| 17, the action jobs | commit 0, before the wiring | [#938]: `actionTableViolations`' entries as merged |
| 18, init and the destroy drain | K2-1b, then commit 1 | K2-1b's merge |

## 5. Tests and measurement

- K2 §8's list, unchanged: each entry contract, the order test, the barriers, the result slot, cancellation with its mutant, the entry end and the seal; the census's `live.` group; the replay owner holds no `TurnCore` (a `Mirror` test).
- The differential [#938] grows with commits 0–3 (no difference allowed), then becomes the facade's own suite at commit 4: the same cases, one path.
- `KeeperReentryTrapTests` point at K2's stops; the refused entry is a count, so it runs in the normal suite with the `isDebugBuild` gate removed. The core's stop runs one case per process in the cloud.
- Full verification: both test legs, the two example packages, E2E in three encodings and the game E2E with reevaluation (CI and cloud), release and must-not-compile (CI), a mutant per new rule (cloud), and a release run with `-DTURNS_EXCLUSIVITY_CHECKED` (cloud).
- Host A/B after the merge, on the merged SHA (K2 §8): tick actions with and without resolvers, tickless client events; G3 (#760) checked before it is read.

## 6. Questions

| # | Question | For |
|---|---|---|
| K22-Q1 | Item 16: drop the `.inputDrain` hold on the core path (§4)? | Review |
| K22-Q2 | `.admitClientEvent`'s answer: no value, as today (commit 2)? | Review |
| K22-Q3 | The loop drivers: core timers only if #762 is in, else the loop Task sends with the existing loop generation as its epoch (commit 4)? | Review |
| K22-Q4 | One PR for K2-2 + K2-3 (K2 §6), or two: K2-2a (commits 0–3, unwired) and K2-2b (4–6, the cut-over)? Main's lean: two, so the cut-over is reviewable on its own; §3 is written that way | Review |

## 7. Probes

Run on macOS, Apple Swift 6.4.2, `swiftc -swift-version 6`, one-file programs outside the repository. None traps: the checks print instead of asserting.

**P-K22-1 (item 14).** An actor `Owner` whose isolated `submit` calls a synchronous, nonisolated `step`, as the core calls `handle`. The step runs a frame with the K2-1 signature, `run(isolation: isolated (any Actor)? = #isolation, flush:, body)`, (a) with the default and (b) inside `owner.assumeIsolated { iso in run(isolation: iso, …) }`; the flush stages a Task with no capture (b1) and one that captures `iso` (b2); (c), a control, stages a Task capturing `iso` directly in the `assumeIsolated` closure. Each Task prints whether its `#isolation` is the owner. Output:

```
frame #isolation is owner: false
(a) flush: isolation nil statically
frame #isolation is owner: true
(b1) staged Task, no capture: on owner = false
(b2) staged Task capturing iso: on owner = false
(c) Task in the iso-isolated closure, capturing iso: on owner = false
log: ["b2 ran"]
```

So passing `isolation:` changes the frame's own isolation and nothing staged from it: no Task here inherits the owner, the control included. A staged start's work reaches the owner only by calling it (b2's `await iso.note`). §4's item 14 row follows from this. (c) is narrower than SE-0420's capture rule suggests, so no K2-2 design point relies on inheritance either way.

**P-K22-2 (commit 0): settled by reading the code, no probe.** The core's side is pinned by its own test: CancellationTests.swift:78, test 24, `.cancelsCall` after the step, where "the work goes on and its reply finds no waiter". The keeper's side is `awaitActionResult`'s cancel handler and `.actionResolved`'s segment at #938's head (LK:2370, LK:5963). The two differ, and commit 0's caller-cancel bullet keeps the box for that reason. The differential case in commit 0 is the evidence once written.

**P-K22-3 (commit 4): run on Linux only.** Three actors share one executor: the adapter's `unownedExecutor` is the facade's, and the facade's is `LiveLandTurns`'. The adapter calls `facade.assumeIsolated`, and the facade forwards with `live.assumeIsolated`; each level checks the others with `preconditionIsolated`. A wrong executor traps, so the probe ran in a throwaway `swift:6.4.3-noble` container (x86_64, "Swift version 6.4.3 (swift-6.4.3-RELEASE)"), not on macOS. Output, the same plain and with `-O`:

```
$ swiftc -swift-version 6 p_k22_3.swift -o p     # no diagnostics, rc 0
$ ./p
steps: 1 2 3 - one executor, no trap             # exit 0
```

So the three-level chain compiles under Swift 6's checking and runs on one serial executor, which is §3 commit 4's layout. Two-level sharing is already production evidence: the adapter runs on the keeper's executor (TA:113) and calls `keeper.assumeIsolated` (TA:3831). macOS is not run; K2-2b's own suites, on both platforms, are the evidence there.

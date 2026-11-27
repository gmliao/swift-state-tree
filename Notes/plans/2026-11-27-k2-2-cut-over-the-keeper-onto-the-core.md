# K2-2: cut the keeper over onto the turn core (#700)

Revision 0 (2026-11-27), a prep draft. It is based on K2-1's shape in #938 (head 25ec1efb), which is still in review. Each point that depends on Review's verdict on #938 is marked **[#938]**. The parent plan is `Notes/plans/2026-11-25-k2-cut-over-onto-the-turn-core.md` (here "K2 §n"), whose §6 defines K2-2 and K2-3 as one PR, and whose §16 items 14–18 are left open for K2-2.

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
  | `.shutdown` | K2-2 | 2 |
  | `.syncStreamDraft` | K2-2 | 3 |
  | queries `.admitClientEvent`, `.syncTurnNow`, `.syncTurnTicket`, `.settle` | `preconditionFailure("… is not routed yet")` | 2 (the first), 3 (the sync three) |

  Commit 4 then checks that `KeeperInputRoutes.deferred` is empty and the query `answer` has no unrouted arm. That check is the wiring step's precondition: the routed subset must be total.

## 3. Commits

One PR, one commit per step, each building green. Steps 0–3 are still unwired, so the differential grows with them. Step 4 is the cut-over, and steps 5–6 follow it.

**0. The action jobs on the core** (K2 §16 item 17). The job lane's four keeper-only parts move together:
- the job's task, staged through `side.keeperReference` and installed in `jobTasks`, becomes one `turn.run(.actionJob(…))` per job, and `.actionResolved(seq, token, result)` comes back. Its step checks the job, the entry generation and the sealed token (K2 §4.3);
- the abandonment's `onEnded` release becomes a result input that `perform` returns when the job's task is cancelled. `handleAbandoned` covers a run the core abandons (to verify: which of the two the core calls on a cancelled `run`; probe P-K22-2);
- the caller's cancel through the job box (`callerCancelled`) becomes `sendAndWait(_, cancellation: .cancelsCall)`. Per `CallerCancellation`'s doc, a stepped input goes on and only the caller stops waiting with `CancellationError`. That matches today's "the job keeps running, the caller leaves" only if today's caller also gets `CancellationError`; P-K22-2 checks both sides;
- `awaitActionResult`'s `slotWaiters` become `coreSlotReplies`, checked like `coreInputReplies`: empty on the keeper's path (a violation entry, not an assert).

Tests: the differential gets a job case per lane shape (a resolver job that succeeds, throws, and is cancelled by its caller), plus §16 item 10's job example: a step that starts a job and cancels it, so the task observes the cancel and the drain doesn't wait for a full run. K2-1's "core side: a job intake" violation entry goes; the job intake is now routed.

**1. The initialization and the destroy drain** (after K2-1b). `.initialize` and `.destroyHandler` become effects; `.initializeResolved`, `.destroyHandlerResolved` and `.drainFinished` are routed onto K2-1b's segments. The differential reruns K2-1b's hold cases (one per await) on the core path. K2 §16 item 13's remaining part goes here: `teardownWaitsForTheFailingTurn`'s scenario, from the failure through the teardown and the drain, on the core path, with every staged start beginning with a call into the owner (SE-0420).

**2. The barriers, the freeze and the shutdown.**
- `.awaitInitialized` and `.awaitResume` are `sendAndWait` inputs whose step replies at once when the barrier is open, and otherwise records the caller in a model table answered by the step that opens it (K2 §4.2, "barriers, not holds"). No intake is parked by a hold, so a query can't overtake a parked call.
- `.freeze` / `.resume` route `debugFreeze` / `debugResume`. This ends #129's hand re-check: the freeze's generation is the step's own read, so the post-await re-check goes.
- `.shutdown` routes the stop: queued leaves first, then the destroy, on tick lands too (#511's follow-up), then the drain of commit 1.
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
| 14, the frame's isolation on the core | the step passes `LiveLandTurns` as `isolation:` to `KeeperTurnFrame.run`; `preconditionOnOwner` at step entry stays as the check. Probe P-K22-1 shows whether the core's synchronous `step` can pass an actor it is isolated to without a hop | [#938] if Review asks for a different frame shape |
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
| K22-Q4 | One PR for K2-2 + K2-3 (K2 §6), or a smaller first read: commits 0–3 (unwired) as one PR, 4–6 as the next? With commits 0–3 unwired, the split builds green on its own, as K2-1 did | Review, then Main |

## 7. Probes

Not run yet: they need a build, and this revision was written while the build slot was held for other work. Rev 1 quotes their output.
- **P-K22-1** (item 14): a one-file `swiftc` program with a `TurnActor`-shaped actor whose `nonisolated` synchronous step, called under `assumeIsolated`, passes the actor as `isolation:` to an `async` frame function. Question: does it compile without an extra hop, and does `#isolation` inside the frame report the actor.
- **P-K22-2** (commit 0): against `SwiftStateTurns` at main, a `sendAndWait(_, cancellation: .cancelsCall)` whose input steps and starts a `run`; cancel the caller. Question: does the caller get `CancellationError`, does the effect keep running, and does its result input step (not `handleAbandoned`). Then today's keeper: an action with a slow resolver job and a cancelled caller, to compare what the caller gets.
- **P-K22-3** (commit 4): the facade forwarding with `live.assumeIsolated` when the adapter's `unownedExecutor` is the facade's and the facade's is `LiveLandTurns`'. Question: one serial executor for all three, checked by `preconditionIsolated` from each.
